--- 沙箱专项测试
--- @module NeoAI.tests.test_sandbox
--- 覆盖：加载器强制附加规格、fail-closed、状态机/幂等/fencing、策略聚合、
--- dry-run 不改真实工作区、CAS 发布与冲突、运行时能力探测与进程隔离。

local tests = require("NeoAI.tests")

--- 保存/恢复全局配置
local function with_config(overrides, fn)
  local config_store = require("NeoAI.kernel.config_store")
  local saved = config_store.get_all()
  config_store.load(overrides)
  local ok, err = pcall(fn)
  config_store.load(saved)
  if not ok then error(err, 0) end
end

local function trim(s)
  return (tostring(s or ""):gsub("%s+$", ""))
end

tests.suite("sandbox", function(_, it)
  it("加载器为所有已注册工具附加沙箱规格", function(t)
    local registry = require("NeoAI.tools.registry")
    local missing = {}
    for _, tool in ipairs(registry.list()) do
      if not tool.__sandboxed then missing[#missing + 1] = tool.name end
    end
    t.eq(0, #missing, "未附加规格的工具: " .. table.concat(missing, ","))
    t.eq("fs_write", registry.get("edit_file").__sandbox_spec.effect)
    t.eq("process", registry.get("run_command").__sandbox_spec.effect)
    t.eq("read", registry.get("read_file").__sandbox_spec.effect)
    t.eq("in_process", registry.get("todo_write").__sandbox_spec.effect)
  end)

  it("沙箱服务缺失且 fail_closed 时拒绝执行（不静默降级）", function(t)
    local services = require("NeoAI.kernel.services")
    local saved = services.use("services.sandbox")
    t.not_nil(saved, "默认应已提供 services.sandbox")
    services.revoke("services.sandbox")
    with_config({ tools = { approval = { mode = "auto_allow" }, sandbox = { enabled = true, fail_closed = true } } }, function()
      local done = false
      require("NeoAI.tools").execute("read_file", { filepath = "/tmp/x", description = "t" }, {})
        :then_(function() done = true; t.true_(false, "应 fail-closed") end, function(e)
          t.matches("沙箱", tostring(e and e.message or e))
          done = true
        end)
      t.true_(vim.wait(2000, function() return done end), "应快速拒绝")
    end)
    services.provide("services.sandbox", saved)
  end)

  it("控制面：幂等键、状态迁移与 fencing", function(t)
    local control = require("NeoAI.sandbox.control")
    control.reset()
    t.true_(control.claim_idempotency("k1", "h1"))
    t.true_(control.claim_idempotency("k1", "h1"), "同键同请求应放行")
    local ok, reason = control.claim_idempotency("k1", "h2")
    t.false_(ok, "同键不同请求应拒绝")
    t.matches("IDEMPOTENCY", reason)

    local attempt = control.new_attempt("edit_file", {}, {}, { effect = "fs_write" })
    t.eq("RECEIVED", attempt.state)
    t.true_(control.transition(attempt, "PARSED"))
    t.false_(control.transition(attempt, "COMMITTED"), "非法迁移应失败")
    t.eq("PARSED", attempt.state)

    local token = control.acquire_lease(attempt.command_id, 60)
    t.true_(control.check_lease(attempt.command_id, token))
    control.acquire_lease(attempt.command_id, 60)
    local ok2, r2 = control.check_lease(attempt.command_id, token)
    t.false_(ok2, "旧 fencing token 应被拒绝")
    t.matches("STALE", r2)
    control.release_lease(attempt.command_id)
  end)

  it("策略：硬拒绝高于确认，网络默认离线拒绝", function(t)
    local policy = require("NeoAI.sandbox.policy")
    with_config({ tools = { sandbox = { offline = true, policy = { deny_tools = { "run_command" } } } } }, function()
      local v = policy.evaluate({ tool = "run_command", effect = "process" })
      t.eq("DENY", v.decision)
      t.true_(vim.tbl_contains(v.reason_codes, "TOOL_HARD_DENIED"))
      local v2 = policy.evaluate({ tool = "web_fetch", effect = "network" })
      t.eq("DENY", v2.decision)
      t.true_(vim.tbl_contains(v2.reason_codes, "NETWORK_NOT_DECLARED"))
    end)
  end)

  it("策略：规则异常统一产生 DENY（POLICY_EVALUATION_FAILED）", function(t)
    local policy = require("NeoAI.sandbox.policy")
    with_config({ tools = { sandbox = { policy = { rules = { function() error("boom") end } } } } }, function()
      local v = policy.evaluate({ tool = "x", effect = "read" })
      t.eq("DENY", v.decision)
      t.true_(vim.tbl_contains(v.reason_codes, "POLICY_EVALUATION_FAILED"))
    end)
  end)

  it("策略：死循环规则有界终止并 DENY", function(t)
    local policy = require("NeoAI.sandbox.policy")
    policy.set_limits({ instruction_budget = 1000 })
    with_config({ tools = { sandbox = { policy = { rules = { function() while true do end end } } } } }, function()
      local v = policy.evaluate({ tool = "x", effect = "read" })
      t.eq("DENY", v.decision)
    end)
    policy.reset()
  end)

  it("dry_run：不写真实工作区，冻结候选后可 CAS 发布", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "auto_allow" }, sandbox = { mode = "dry_run" } } }, function()
      sandbox.reset()
      local p = vim.fn.tempname() .. ".txt"
      fs.write_file(p, "base\n")
      local done = false
      require("NeoAI.tools").execute("edit_file", {
        filepath = p, mode = "write", content = "next\n", description = "t",
      }, {}):then_(function(r)
        t.matches("沙箱", r, "结果应提示已暂存为候选")
        t.eq("base", trim(fs.read_file(p)), "dry_run 不应改真实工作区")
        local list = sandbox.list()
        t.eq(1, #list, "应有一个待处理候选")
        local res = sandbox.commit(list[1].candidate_digest)
        t.true_(res.ok, tostring(res.reason))
        t.eq("next", trim(fs.read_file(p)), "commit 后应写入真实工作区")
        fs.delete_file(p)
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(3000, function() return done end), "edit_file 应完成")
    end)
  end)

  it("commit：基线被他人修改后 CAS 失败（CONFLICT），不覆盖", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "auto_allow" }, sandbox = { mode = "dry_run" } } }, function()
      sandbox.reset()
      local p = vim.fn.tempname() .. ".txt"
      fs.write_file(p, "base\n")
      local done = false
      require("NeoAI.tools").execute("edit_file", {
        filepath = p, mode = "write", content = "agent\n", description = "t",
      }, {}):then_(function()
        -- 模拟发布前他人修改真实工作区
        fs.write_file(p, "human\n")
        local cand = sandbox.list()[1]
        local res = sandbox.commit(cand.candidate_digest)
        t.false_(res.ok, "基线变化应 CAS 失败")
        t.eq("CONFLICT", res.state)
        t.eq("human", trim(fs.read_file(p)), "不得覆盖他人修改")
        fs.delete_file(p)
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(3000, function() return done end), "edit_file 应完成")
    end)
  end)

  it("buffer 写盘工具 dry_run 不落真实磁盘", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "auto_allow" }, sandbox = { mode = "dry_run" } } }, function()
      sandbox.reset()
      local p = vim.fn.tempname() .. ".lua"
      fs.write_file(p, "local keep = 1\nlocal remove = 2\n")
      local done = false
      require("NeoAI.tools").execute("delete_node", {
        filepath = p, line = 2, col = 1, description = "t",
      }, {}):then_(function()
        t.matches("remove", fs.read_file(p) or "", "dry_run 下真实文件不应被删除节点")
        local list = sandbox.list()
        t.eq(1, #list, "应冻结候选")
        fs.delete_file(p)
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(3000, function() return done end), "delete_node 应完成")
    end)
  end)

  it("运行时：能力探测与隔离进程执行", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    local caps = runtime.probe()
    t.true_(caps.bwrap or caps.unshare, "应至少有一种隔离工具")
    local backend = runtime.backend()
    t.not_nil(backend, "auto 应选出一个可用后端")
    if backend then
      local done = false
      runtime.run({ "sh", "-c", "echo isolated-ok" }, { timeout_ms = 5000 }):then_(function(r)
        t.eq(0, r.code, "隔离命令应成功: " .. tostring(r.stderr))
        t.matches("isolated%-ok", r.stdout or "")
        done = true
      end, function(e)
        t.true_(false, "隔离执行不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(8000, function() return done end), "隔离进程应完成")
    end
  end)

  it("runtime：后端可用时构造前缀，不可用时返回明确错误", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    local prefix, err = runtime.process_prefix({})
    if runtime.backend() == nil then
      t.nil_(prefix)
      t.matches("SANDBOX_BACKEND_UNAVAILABLE", tostring(err))
    else
      t.not_nil(prefix, "有后端时应能构造前缀")
      t.eq("table", type(prefix))
      t.eq(nil, err)
    end
  end)

  it("异步审批：执行不阻塞，产出待审变更单元并可应用", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local tool_service = require("NeoAI.services.tool_service")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      tool_service.reset()
      -- 审批 UI 不应被调用（async 模式不使用执行前阻塞审批）
      local shown = false
      tool_service.set_approval_ui({ show = function() shown = true end, hide = function() end })
      local p = vim.fn.tempname() .. ".txt"
      fs.write_file(p, "ORIG\n")
      local done = false
      require("NeoAI.tools").execute("edit_file", {
        filepath = p, mode = "write", content = "NEW\n", description = "t",
      }, {}):then_(function(r)
        t.false_(shown, "async 模式不应弹执行前审批窗")
        t.matches("等待异步确认", r, "结果应提示进入异步待审")
        t.eq("ORIG", trim(fs.read_file(p)), "执行后真实工作区不应被修改")
        local items = sandbox.list_reviews({ review_state = "PENDING" })
        t.eq(1, #items, "应有一个待审变更单元")
        t.true_(vim.tbl_contains(items[1].write_set, p), "write_set 应含目标文件")
        local res = sandbox.apply(items[1].change_set_id, { auto_approve = true })
        t.true_(res.ok, tostring(res.reason))
        t.eq("NEW", trim(fs.read_file(p)), "应用后应写入真实工作区")
        fs.delete_file(p)
        tool_service.set_approval_ui(nil)
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(3000, function() return done end), "edit_file 应完成")
    end)
  end)

  it("异步审批：拒绝不应用并丢弃候选", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local p = vim.fn.tempname() .. ".txt"
      fs.write_file(p, "KEEP\n")
      local done = false
      require("NeoAI.tools").execute("edit_file", {
        filepath = p, mode = "write", content = "DROP\n", description = "t",
      }, {}):then_(function()
        local item = sandbox.list_reviews({ review_state = "PENDING" })[1]
        t.not_nil(item)
        sandbox.reject(item.change_set_id, "no")
        t.eq("KEEP", trim(fs.read_file(p)), "拒绝后真实文件不应改变")
        local after = sandbox.list_reviews()[1]
        t.eq("REJECTED", after.review_state)
        local res = sandbox.apply(item.change_set_id, {})
        t.false_(res.ok, "已拒绝的变更单元不应可应用")
        fs.delete_file(p)
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(3000, function() return done end), "edit_file 应完成")
    end)
  end)

  it("选择性应用：只应用候选中的指定文件", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local done = false
      require("NeoAI.tools").execute("run_command", {
        command = "echo A > a.txt; echo B > b.txt", description = "t",
      }, {}):then_(function()
        local item = sandbox.list_reviews({ review_state = "PENDING" })[1]
        t.not_nil(item)
        t.eq(2, #item.write_set)
        local res = sandbox.apply(item.change_set_id, { auto_approve = true, files = { dir .. "/a.txt" } })
        t.true_(res.ok, tostring(res.reason))
        t.true_(fs.exists(dir .. "/a.txt"), "选中的文件应被应用")
        t.false_(fs.exists(dir .. "/b.txt"), "未选中的文件不应被应用")
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(10000, function() return done end), "run_command 应完成")
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
  end)

  it("run_command：文件改动在 overlay 私有层冻结为候选", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end -- overlay 仅 bwrap 后端
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    fs.write_file(dir .. "/existing.txt", "hello\n")
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local done = false
      require("NeoAI.tools").execute("run_command", {
        command = "cat existing.txt > copy.txt; echo appended >> existing.txt", description = "t",
      }, {}):then_(function()
        t.false_(fs.exists(dir .. "/copy.txt"), "命令写入不应落到真实工作区")
        t.eq("hello", trim(fs.read_file(dir .. "/existing.txt")), "真实文件不应被命令修改")
        local items = sandbox.list_reviews({ review_state = "PENDING" })
        t.eq(1, #items, "命令的文件改动应冻结为一个候选")
        t.eq(2, #items[1].write_set, "应包含新建与修改两个文件")
        local res = sandbox.apply(items[1].change_set_id, { auto_approve = true })
        t.true_(res.ok, tostring(res.reason))
        t.true_(fs.exists(dir .. "/copy.txt"), "应用后新文件应存在")
        t.matches("appended", fs.read_file(dir .. "/existing.txt") or "", "应用后修改应生效")
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(10000, function() return done end), "run_command 应完成")
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
  end)

  it("影响模型：fs/process 记录与统计（未知用 null）", function(t)
    local impact = require("NeoAI.sandbox.impact")
    local cand = { files = {
      { action = "create", path = "/a", after_hash = "h1" },
      { action = "modify", path = "/b", before_hash = "h0", after_hash = "h2" },
      { action = "delete", path = "/c", before_hash = "h3" },
    } }
    local fs_impacts = impact.from_candidate(cand, { command_id = "cmd" })
    t.eq(3, #fs_impacts)
    local stats = impact.stats(fs_impacts)
    t.eq(1, stats.fs.observed_creates)
    t.eq(1, stats.fs.observed_writes)
    t.eq(1, stats.fs.observed_deletes)
    t.eq(nil, stats.network.observed_tx_bytes, "未知字节数应为 null 而非 0")
    local proc = impact.process({ command = "ls", code = 0 })
    t.eq("process", proc.type)
    t.eq(0, proc.exit_code)
  end)

  it("证据：秘密字段脱敏且可分页读取", function(t)
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { sandbox = { workspace_root = vim.fn.tempname() } } }, function()
      sandbox.reset()
      local evidence = require("NeoAI.sandbox.evidence")
      local id = evidence.add("test", { token = "secret", nested = { password = "x", ok = 1 } }, { tool = "t" })
      local rec = evidence.get(id)
      t.eq("[redacted]", rec.payload.token, "token 应脱敏")
      t.eq("[redacted]", rec.payload.nested.password, "嵌套 password 应脱敏")
      t.eq(1, rec.payload.nested.ok)
      evidence.add("test", { a = 1 }, {})
      evidence.add("test", { a = 2 }, {})
      local page1 = evidence.page({ limit = 2 })
      t.eq(2, #page1.items)
      t.not_nil(page1.next_cursor, "应有下一页游标")
      local page2 = evidence.page({ limit = 2, after_id = page1.next_cursor })
      t.true_(#page2.items >= 1)
    end)
  end)

  it("任务授权：覆盖候选时自动应用并消费预算", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      sandbox.create_grant({ scope = { paths = { dir } }, operations = { "fs_write" }, budget = { max_files = 5 } })
      local p = dir .. "/f.txt"
      fs.write_file(p, "v1\n")
      local done = false
      require("NeoAI.tools").execute("edit_file", { filepath = p, mode = "write", content = "v2\n", description = "t" }, {})
        :then_(function()
          t.eq("v2", trim(fs.read_file(p)), "有覆盖授权时应自动应用")
          t.eq(0, #sandbox.list_reviews({ review_state = "PENDING" }), "不应进入待审队列")
          local g = sandbox.list_grants({ active_only = true })[1]
          t.eq(1, g.usage.files, "应消费预算")
          done = true
        end, function(e) t.true_(false, tostring(e and e.message or e)); done = true end)
      t.true_(vim.wait(3000, function() return done end), "edit_file 应完成")
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("任务授权：范围外不覆盖 → 进入待审", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      sandbox.create_grant({ scope = { paths = { "/some/other/place" } }, operations = { "fs_write" } })
      local p = dir .. "/f.txt"
      fs.write_file(p, "v1\n")
      local done = false
      require("NeoAI.tools").execute("edit_file", { filepath = p, mode = "write", content = "v2\n", description = "t" }, {})
        :then_(function()
          t.eq("v1", trim(fs.read_file(p)), "范围外不应自动应用")
          t.eq(1, #sandbox.list_reviews({ review_state = "PENDING" }), "应进入待审")
          done = true
        end, function(e) t.true_(false, tostring(e and e.message or e)); done = true end)
      t.true_(vim.wait(3000, function() return done end), "edit_file 应完成")
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("策略约束聚合：预算取更小值", function(t)
    local policy = require("NeoAI.sandbox.policy")
    with_config({ tools = { sandbox = { policy = { rules = {
      function() return { decision = "ALLOW", constraints = { max_files = 5 } } end,
      function() return { decision = "ALLOW", constraints = { max_files = 3 } } end,
    } } } } }, function()
      local v = policy.evaluate({ tool = "x", effect = "read" })
      t.eq("ALLOW", v.decision)
      t.eq(3, v.constraints.max_files, "预算应取更小值（更严格）")
    end)
  end)

  it("裁决信封：枚举校验与截断", function(t)
    local envelope = require("NeoAI.sandbox.envelope")
    local asks = {}
    for i = 1, 7 do asks[i] = { id = "ask_" .. i } end
    local env = envelope.build({
      command_id = "cmd", state = "AWAITING_PUBLICATION_AUTH",
      decision = "BOGUS", severity = "NOPE",
      candidate_digest = "sha256:x", asks = asks,
      evidence = { "e1", "e2" }, stats = { fs = { observed_creates = 1 } },
    })
    t.eq("NEEDS_CONFIRMATION", env.decision, "非法 decision 应回退")
    t.eq("LOW", env.severity, "非法 severity 应回退")
    t.eq(5, #env.asks, "asks 应截断到 5 条")
    t.eq(7, env.asks_total)
    t.true_(env.truncated)
    t.matches("decision=", envelope.to_text(env))
  end)

  it("保留期清理与指标", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", retention = { candidate_days = -1 }, review = { enabled = true } } } }, function()
      sandbox.reset()
      local p = vim.fn.tempname() .. ".txt"
      fs.write_file(p, "v1\n")
      local done = false
      require("NeoAI.tools").execute("edit_file", { filepath = p, mode = "write", content = "v2\n", description = "t" }, {})
        :then_(function()
          local item = sandbox.list_reviews({ review_state = "PENDING" })[1]
          sandbox.reject(item.change_set_id)
          local m = sandbox.metrics()
          t.eq(1, m.rejected)
          local res = sandbox.prune()
          t.true_(res.removed_reviews >= 1, "应清理过期已拒绝变更单元")
          fs.delete_file(p)
          done = true
        end, function(e) t.true_(false, tostring(e and e.message or e)); done = true end)
      t.true_(vim.wait(3000, function() return done end), "edit_file 应完成")
    end)
  end)

  it("受控网络网关：默认拒绝，声明端点后按应用层校验", function(t)
    local policy = require("NeoAI.sandbox.policy")
    local network = require("NeoAI.sandbox.network")
    -- 默认离线：拒绝
    with_config({ tools = { sandbox = { offline = true } } }, function()
      local v = policy.evaluate({ tool = "web_fetch", effect = "network", args = { url = "https://api.example.com/x" } })
      t.eq("DENY", v.decision)
      t.true_(vim.tbl_contains(v.reason_codes, "NETWORK_NOT_DECLARED"))
    end)
    -- 受控联网：仅声明端点放行
    with_config({ tools = { sandbox = { offline = false, network = { enabled = true, allowed_endpoints = { "*.example.com" } } } } }, function()
      network.reset()
      t.true_(network.authorize("https://api.example.com/x"))
      t.false_(network.authorize("https://evil.com/x"))
      local v = policy.evaluate({ tool = "web_fetch", effect = "network", args = { url = "https://evil.com/x" } })
      t.eq("DENY", v.decision)
      t.true_(vim.tbl_contains(v.reason_codes, "ENDPOINT_NOT_ALLOWED: https://evil.com/x"))
    end)
  end)

  it("broker：能力声明、幂等与对账", function(t)
    local broker = require("NeoAI.sandbox.broker")
    broker.reset()
    local calls = 0
    broker.register({
      id = "test_adapter",
      supports_idempotency = true,
      supports_query = true,
      transaction_boundary = true,
      irreversible_effects = false,
      invoke = function(op, params) calls = calls + 1; return { op = op, value = params.value } end,
      query = function() return true end,
    })
    local listed = broker.list()
    t.eq(1, #listed)
    t.true_(listed[1].capabilities.supports_idempotency)
    t.false_(listed[1].capabilities.irreversible_effects)

    local r1 = broker.invoke("test_adapter", "write", { value = 1 }, { idempotency_key = "k1" })
    t.true_(r1.ok)
    t.eq(1, calls)
    local r2 = broker.invoke("test_adapter", "write", { value = 1 }, { idempotency_key = "k1" })
    t.true_(r2.ok, "同键同请求应复用结果")
    t.eq(1, calls, "不应重复调用远端")
    local r3 = broker.invoke("test_adapter", "write", { value = 2 }, { idempotency_key = "k1" })
    t.false_(r3.ok, "同键不同请求应拒绝")
    t.matches("IDEMPOTENCY", r3.reason)

    local rec = broker.reconcile(r1.operation_id)
    t.true_(rec.ok)
    t.eq("SUCCEEDED", rec.state)

    -- 不可查询的适配器：结果不明进入 OUTCOME_UNKNOWN
    broker.register({ id = "no_query", invoke = function() return { outcome_unknown = true } end })
    local ru = broker.invoke("no_query", "do", {}, {})
    t.false_(ru.ok)
    t.eq("OUTCOME_UNKNOWN", ru.state)
  end)

  it("依赖图：闭包拓扑序与缺失依赖阻塞", function(t)
    local sandbox = require("NeoAI.sandbox")
    local review = require("NeoAI.sandbox.review")
    local store = require("NeoAI.sandbox.store")
    with_config({ tools = { sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local function cand(digest, path, content)
        return { candidate_digest = digest, effect = "fs_write", created_at = os.time(),
          files = { { path = path, action = "create", after_hash = "h" .. digest, content = content, base_exists = false } } }
      end
      local cA = cand("sha256:A", "/tmp/dep_a", "A")
      local cB = cand("sha256:B", "/tmp/dep_b", "B")
      store.write_candidate(cA); store.write_candidate(cB)
      review.enqueue(cA, { id = "csA" })
      review.enqueue(cB, { id = "csB", depends_on = { "csA" } })
      local deps = review.dependencies("csB")
      t.deep_eq({ "csA", "csB" }, deps.order, "依赖应排在被依赖者之后")
      t.eq(0, #deps.missing)
      -- 缺失依赖 → BLOCKED_DEPENDENCY
      store.write_candidate(cand("sha256:C", "/tmp/dep_c", "C"))
      review.enqueue(cand("sha256:C", "/tmp/dep_c", "C"), { id = "csC", depends_on = { "nope" } })
      local d3 = review.dependencies("csC")
      t.true_(#d3.missing >= 1)
      local set = review.prepare_publication_set({ "csC" })
      t.eq("BLOCKED_DEPENDENCY", set.state)
    end)
  end)

  it("组合发布集合：合并多候选并 CAS 应用", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local dir = vim.fn.tempname()
      fs.ensure_dir(dir)
      local p1, p2 = dir .. "/a.txt", dir .. "/b.txt"
      fs.write_file(p1, "a1\n"); fs.write_file(p2, "b1\n")
      local tools = require("NeoAI.tools")
      local pending = 0
      local ids = {}
      local function run(p, content, cb)
        tools.execute("edit_file", { filepath = p, mode = "write", content = content, description = "t" }, {})
          :then_(function() cb() end, function(e) t.true_(false, tostring(e and e.message or e)); cb() end)
      end
      local done = false
      run(p1, "a2\n", function()
        run(p2, "b2\n", function()
          for _, it in ipairs(sandbox.list_reviews({ review_state = "PENDING" })) do
            pending = pending + 1; ids[#ids + 1] = it.change_set_id
          end
          t.eq(2, pending, "应有两个待审变更单元")
          local set = sandbox.prepare_publication_set(ids)
          t.eq("READY", set.state)
          t.eq(2, #set.candidate.files, "组合候选应含两个文件")
          t.not_nil(set.publication_intent_hash)
          local res = sandbox.apply_set(set)
          t.true_(res.ok, tostring(res.reason))
          t.eq("a2", trim(fs.read_file(p1)))
          t.eq("b2", trim(fs.read_file(p2)))
          done = true
        end)
      end)
      t.true_(vim.wait(5000, function() return done end), "组合发布应完成")
      vim.fn.delete(dir, "rf")
    end)
  end)

  it("组合发布集合：同路径冲突拒绝", function(t)
    local sandbox = require("NeoAI.sandbox")
    local review = require("NeoAI.sandbox.review")
    local store = require("NeoAI.sandbox.store")
    with_config({ tools = { sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local function cand(digest, content)
        return { candidate_digest = digest, effect = "fs_write", created_at = os.time(),
          files = { { path = "/tmp/conflict_same", action = "modify", after_hash = "h" .. digest, content = content, before_hash = "base" } } }
      end
      local c1, c2 = cand("sha256:X", "X"), cand("sha256:Y", "Y")
      store.write_candidate(c1); store.write_candidate(c2)
      review.enqueue(c1, { id = "cx1" })
      review.enqueue(c2, { id = "cx2" })
      local set = review.prepare_publication_set({ "cx1", "cx2" })
      t.eq("CONFLICT", set.state)
      t.true_(#set.conflicts >= 1)
      t.eq("PATH_CONFLICT", set.conflicts[1].reason)
    end)
  end)

  it("策略回放：同事实同规则裁决可复现", function(t)
    local sandbox = require("NeoAI.sandbox")
    local policy = require("NeoAI.sandbox.policy")
    with_config({ tools = { sandbox = { policy = { version = "1", deny_tools = { "run_command" } } } } }, function()
      sandbox.reset()
      local facts = { tool = "run_command", effect = "process" }
      local verdict = policy.evaluate(facts)
      t.eq("DENY", verdict.decision)
      local eid = sandbox.record_decision(facts, verdict, {})
      local res = sandbox.replay(eid)
      t.true_(res.ok)
      t.true_(res.same, "回放应产生相同裁决")
      t.eq("DENY", res.actual.decision)
      t.false_(res.version_mismatch)
    end)
  end)

  it("证据保留期清理：默认保留裁决记录", function(t)
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { sandbox = { workspace_root = vim.fn.tempname() } } }, function()
      sandbox.reset()
      local evidence = require("NeoAI.sandbox.evidence")
      local obs = evidence.add("observation", { x = 1 }, {})
      local dec = evidence.add("decision", { facts = {}, verdict = { decision = "ALLOW" } }, {})
      local removed = evidence.prune(-1)
      t.true_(removed >= 1, "应清理过期观测证据")
      t.eq(nil, evidence.get(obs))
      t.not_nil(evidence.get(dec), "裁决记录默认保留供回放")
    end)
  end)

  it("cgroup：资源域创建、限制写入与释放", function(t)
    local cgroup = require("NeoAI.sandbox.cgroup")
    local caps = cgroup.probe()
    if not caps.available then return end
    local h = cgroup.prepare("test_attempt_cg", { pids = 4, memory_bytes = 64 * 1024 * 1024 })
    t.not_nil(h, "应能创建资源域")
    t.eq(1, vim.fn.isdirectory(h.path), "资源域目录应存在")
    local pids = vim.fn.readfile(h.path .. "/pids.max")
    t.eq("4", pids[1] and pids[1]:gsub("%s", "") or "")
    local mem = vim.fn.readfile(h.path .. "/memory.max")
    t.eq(tostring(64 * 1024 * 1024), mem[1] and mem[1]:gsub("%s", "") or "")
    t.eq("table", type(cgroup.join_prefix(h)))
    cgroup.release(h)
    t.eq(0, vim.fn.isdirectory(h.path), "释放后资源域目录应删除")
  end)

  it("cgroup：进程受 PID 上限约束", function(t)
    local cgroup = require("NeoAI.sandbox.cgroup")
    if not cgroup.probe().available then return end
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", limits = { pids = 8 } } } }, function()
      local sandbox = require("NeoAI.sandbox")
      sandbox.reset()
      local done = false
      require("NeoAI.tools").execute("run_command", {
        command = "for i in $(seq 1 50); do sleep 5 & done; echo forked", description = "t",
      }, {}):then_(function(r)
        t.matches("[Ff]ork", tostring(r), "PID 上限应阻止超额 fork")
        done = true
      end, function(e) t.true_(false, tostring(e and e.message or e)); done = true end)
      t.true_(vim.wait(10000, function() return done end), "命令应完成")
    end)
  end)

  it("seccomp：显式缺失过滤器时 require_seccomp 拒绝", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    local seccomp = require("NeoAI.sandbox.seccomp")
    seccomp.reset()
    with_config({ tools = { sandbox = { require_seccomp = true, seccomp = { filter_path = "/nonexistent/x.bpf" } } } }, function()
      local ok, err = runtime.check_available()
      t.false_(ok, "显式过滤器缺失时应拒绝")
      t.matches("SECCOMP", tostring(err))
    end)
    local filter = vim.fn.tempname()
    vim.fn.writefile({ "dummy" }, filter)
    with_config({ tools = { sandbox = { require_seccomp = true, seccomp = { filter_path = filter } } } }, function()
      seccomp.reset()
      t.true_(seccomp.available(), "提供过滤器文件后应可用")
      t.true_(runtime.check_available())
    end)
    vim.fn.delete(filter)
  end)

  it("seccomp：内置过滤器生成且被 bwrap 施加", function(t)
    local seccomp = require("NeoAI.sandbox.seccomp")
    t.not_nil(seccomp.build_filter("x86_64"), "应能生成 x86_64 过滤器")
    t.not_nil(seccomp.build_filter("aarch64"), "应能生成 aarch64 过滤器")
    if require("NeoAI.sandbox.runtime").backend() ~= "bwrap" then return end
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", seccomp = { enabled = true } } } }, function()
      local sandbox = require("NeoAI.sandbox")
      sandbox.reset()
      seccomp.reset()
      local done = false
      -- 过滤器已加载：Seccomp 模式应为 2（FILTER）
      require("NeoAI.tools").execute("run_command", {
        command = "grep Seccomp /proc/self/status", description = "t",
      }, {}):then_(function(r)
        t.matches("Seccomp:%s*2", tostring(r), "沙箱进程应加载 seccomp 过滤器")
        -- 被禁 syscall 返回 EPERM
        local done2 = false
        require("NeoAI.tools").execute("run_command", {
          command = "unshare -Ur true 2>&1", description = "t",
        }, {}):then_(function(r2)
          t.matches("not permitted", tostring(r2), "unshare 应被 seccomp 拒绝")
          done2 = true
        end, function(e) t.true_(false, tostring(e and e.message or e)); done2 = true end)
        t.true_(vim.wait(8000, function() return done2 end), "被禁 syscall 测试应完成")
        done = true
      end, function(e) t.true_(false, tostring(e and e.message or e)); done = true end)
      t.true_(vim.wait(8000, function() return done end), "seccomp 模式检查应完成")
    end)
  end)

  it("cache：内容寻址读写与清理", function(t)
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { sandbox = { workspace_root = vim.fn.tempname() } } }, function()
      sandbox.reset()
      local cache = require("NeoAI.sandbox.cache")
      local k1 = cache.key({ a = 1, b = { 2, 3 } })
      local k2 = cache.key({ b = { 2, 3 }, a = 1 })
      t.eq(k1, k2, "键应对字段顺序稳定")
      t.false_(cache.has(k1))
      t.true_(cache.put(k1, "content-1"))
      t.true_(cache.has(k1))
      t.eq("content-1", cache.get(k1))
      t.true_(#cache.list() >= 1)
      local removed = cache.prune(-1)
      t.true_(removed >= 1, "应清理过期缓存")
      t.false_(cache.has(k1))
    end)
  end)

  it("故障注入：发布失败不产生部分写入", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "commit" } } }, function()
      sandbox.reset()
      local p = vim.fn.tempname() .. ".txt"
      fs.write_file(p, "v1\n")
      sandbox.fault.set("publish", 1)
      local done = false
      require("NeoAI.tools").execute("edit_file", { filepath = p, mode = "write", content = "v2\n", description = "t" }, {})
        :then_(function() t.true_(false, "注入发布失败时不应成功"); done = true end, function(e)
          t.matches("注入的发布失败", tostring(e and e.message or e))
          t.eq("v1", trim(fs.read_file(p)), "发布失败不应写入真实工作区")
          done = true
        end)
      t.true_(vim.wait(3000, function() return done end), "应快速失败")
      t.true_(#sandbox.fault.history() >= 1, "注入应被记录")
      fs.delete_file(p)
    end)
  end)

  it("故障注入：后端不可用时进程被拒绝", function(t)
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run" } } }, function()
      sandbox.reset()
      sandbox.fault.set("backend", 1)
      local done = false
      require("NeoAI.tools").execute("run_command", { command = "echo x", description = "t" }, {})
        :then_(function() t.true_(false, "注入后端不可用时不应成功"); done = true end, function(e)
          t.matches("SANDBOX_BACKEND_UNAVAILABLE", tostring(e and e.message or e))
          done = true
        end)
      t.true_(vim.wait(3000, function() return done end), "应快速失败")
    end)
  end)

  it("故障注入：候选冻结失败被拒绝", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run" } } }, function()
      sandbox.reset()
      local p = vim.fn.tempname() .. ".txt"
      fs.write_file(p, "v1\n")
      sandbox.fault.set("freeze", 1)
      local done = false
      require("NeoAI.tools").execute("edit_file", { filepath = p, mode = "write", content = "v2\n", description = "t" }, {})
        :then_(function() t.true_(false, "冻结失败不应成功"); done = true end, function(e)
          t.matches("冻结失败", tostring(e and e.message or e))
          t.eq(0, #sandbox.list_reviews({ review_state = "PENDING" }), "不应产生待审变更单元")
          done = true
        end)
      t.true_(vim.wait(3000, function() return done end), "应快速失败")
      fs.delete_file(p)
    end)
  end)

  it("性能基准：关键路径可测量", function(t)
    local sandbox = require("NeoAI.sandbox")
    local results = sandbox.bench.run({ iterations = 50 })
    for _, name in ipairs({ "policy_eval", "digest", "new_attempt", "envelope_build" }) do
      t.not_nil(results[name], name .. " 应有结果")
      t.eq(50, results[name].iterations)
      t.true_(results[name].total_ms >= 0)
      t.true_(results[name].per_op_ms >= 0)
    end
  end)

  it("派生 revision：按内容拆分后重新审查且不迁移旧批准", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local p = vim.fn.tempname() .. ".txt"
      fs.write_file(p, "v1\n")
      local done = false
      require("NeoAI.tools").execute("edit_file", { filepath = p, mode = "write", content = "v2\n", description = "t" }, {})
        :then_(function()
          local parent = sandbox.list_reviews({ review_state = "PENDING" })[1]
          sandbox.approve(parent.change_set_id) -- 旧版已批准但未应用
          local child = sandbox.derive_revision(parent.change_set_id, { contents = { [p] = "v3\n" } })
          t.not_nil(child, "应派生出新 revision")
          t.eq(2, child.revision)
          t.eq(parent.change_set_id, child.supersedes)
          -- 原变更单元应标记 SUPERSEDED（不迁移旧批准）
          local parent_state
          for _, it in ipairs(sandbox.list_reviews()) do
            if it.change_set_id == parent.change_set_id then parent_state = it.review_state end
          end
          t.eq("SUPERSEDED", parent_state, "原变更单元应标记 SUPERSEDED")
          local res = sandbox.apply(child.change_set_id, { auto_approve = true })
          t.true_(res.ok, tostring(res.reason))
          t.eq("v3", trim(fs.read_file(p)), "应用派生版本应写入新内容")
          fs.delete_file(p)
          done = true
        end, function(e) t.true_(false, tostring(e and e.message or e)); done = true end)
      t.true_(vim.wait(3000, function() return done end), "edit_file 应完成")
    end)
  end)
end)
