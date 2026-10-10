--- 沙箱运维：run_command 一致性/保留期清理/加固收尾/审批条目
--- @module 'NeoAI.tests.test_sandbox_ops'
--- 由原 test_sandbox.lua 按用例分片而来（43 个用例，彼此独立、无跨用例共享状态）。

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


tests.suite("sandbox_ops", function(_, it)
  it("run_command：命令删除沙箱-only 文件后不被旧候选复活", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local runtime = require("NeoAI.sandbox.execution.runtime")
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
    local impact = require("NeoAI.sandbox.observe.impact")
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
      local evidence = require("NeoAI.sandbox.review.evidence")
      local id = evidence.add("test", { token = "secret", nested = { password = "x", ok = 1 } }, { tool = "t" })
      local rec = assert(evidence.get(id))
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
      require("NeoAI.tools").execute("edit_file", { file_path = p, mode = "write", content = "v2\n", description = "t" }, {})
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
      require("NeoAI.tools").execute("edit_file", { file_path = p, mode = "write", content = "v2\n", description = "t" }, {})
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
    local policy = require("NeoAI.sandbox.review.policy")
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
    local envelope = require("NeoAI.sandbox.observe.envelope")
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
      require("NeoAI.tools").execute("edit_file", { file_path = p, mode = "write", content = "v2\n", description = "t" }, {})
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
    local policy = require("NeoAI.sandbox.review.policy")
    local network = require("NeoAI.sandbox.net.network")
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
    local evidence = require("NeoAI.sandbox.review.evidence")
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
    local broker = require("NeoAI.sandbox.net.broker")
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
    local review = require("NeoAI.sandbox.review.review")
    local store = require("NeoAI.sandbox.state.store")
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
        tools.execute("edit_file", { file_path = p, mode = "write", content = content, description = "t" }, {})
          :then_(function() cb() end, function(e) t.true_(false, tostring(e and e.message or e)); cb() end)
      end
      local done = false
      run(p1, "a2\n", function()
        run(p2, "b2\n", function()
          for _, rev_item in ipairs(sandbox.list_reviews({ review_state = "PENDING" })) do
            pending = pending + 1; ids[#ids + 1] = rev_item.change_set_id
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
    local review = require("NeoAI.sandbox.review.review")
    local store = require("NeoAI.sandbox.state.store")
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
    local policy = require("NeoAI.sandbox.review.policy")
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
      local evidence = require("NeoAI.sandbox.review.evidence")
      local obs = evidence.add("observation", { x = 1 }, {})
      local dec = evidence.add("decision", { facts = {}, verdict = { decision = "ALLOW" } }, {})
      local removed = evidence.prune(-1)
      t.true_(removed >= 1, "应清理过期观测证据")
      t.eq(nil, evidence.get(obs))
      t.not_nil(evidence.get(dec), "裁决记录默认保留供回放")
    end)
  end)

  it("cgroup：资源域创建、限制写入与释放", function(t)
    local cgroup = require("NeoAI.sandbox.execution.cgroup")
    local caps = cgroup.probe()
    if not caps.available then return end
    local h = assert(cgroup.prepare("test_attempt_cg", { pids = 4, memory_bytes = 64 * 1024 * 1024 }))
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

  it("cgroup：probe 按配置的 cgroup_base 探测（不硬编码 /sys/fs/cgroup）", function(t)
    local cgroup = require("NeoAI.sandbox.execution.cgroup")
    with_config({ tools = { sandbox = { limits = { cgroup_base = "/nonexistent/neoai-cgroup" } } } }, function()
      local caps = cgroup.probe()
      t.eq("/nonexistent/neoai-cgroup", caps.base, "caps.base 应为配置值")
      t.false_(caps.available, "配置的 cgroup_base 不存在时不应报告可用")
    end)
    cgroup.probe() -- 恢复真实 caps 缓存
  end)

  it("systemd 外观：PID1 显示 systemd 且 /run/systemd/system 存在", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local done = false
      require("NeoAI.tools").execute("run_command", {
        command = "cat /proc/1/comm; test -d /run/systemd/system && echo BOOTED || echo NOBOOT; "
          .. "ps -p 1 -o comm= 2>/dev/null",
        description = "t",
      }, {}):then_(function(r)
        local text = tostring(r)
        t.matches("systemd", text, "PID1 应显示为 systemd（实际：" .. text .. "）")
        t.matches("BOOTED", text, "/run/systemd/system 应存在")
        done = true
      end, function(e) t.true_(false, "不应失败: " .. tostring(e and e.message or e)); done = true end)
      t.true_(vim.wait(20000, function() return done end), "run_command 应完成")
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
  end)

  it("systemd 外观：门面关闭时不伪装 PID1", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    with_config({
      tools = {
        approval = { mode = "async" },
        sandbox = { mode = "dry_run", review = { enabled = true }, systemd = { enabled = false } },
      },
    }, function()
      sandbox.reset()
      local done = false
      require("NeoAI.tools").execute("run_command", {
        command = "cat /proc/1/comm", description = "t",
      }, {}):then_(function(r)
        t.false_(tostring(r):find("systemd", 1, true) ~= nil, "门面关闭时不应伪装为 systemd")
        done = true
      end, function(e) t.true_(false, "不应失败: " .. tostring(e and e.message or e)); done = true end)
      t.true_(vim.wait(20000, function() return done end), "run_command 应完成")
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
  end)

  it("cgroup：进程受 PID 上限约束", function(t)
    local cgroup = require("NeoAI.sandbox.execution.cgroup")
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
    local runtime = require("NeoAI.sandbox.execution.runtime")
    local seccomp = require("NeoAI.sandbox.execution.seccomp")
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
    local seccomp = require("NeoAI.sandbox.execution.seccomp")
    t.not_nil(seccomp.build_filter("x86_64"), "应能生成 x86_64 过滤器")
    t.not_nil(seccomp.build_filter("aarch64"), "应能生成 aarch64 过滤器")
    if require("NeoAI.sandbox.execution.runtime").backend() ~= "bwrap" then return end
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
    local runtime = require("NeoAI.sandbox.execution.runtime")
    local seccomp = require("NeoAI.sandbox.execution.seccomp")
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
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" or vim.fn.executable("python3") ~= 1 then return end
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", seccomp = { enabled = true } } } }, function()
      sandbox.reset()
      require("NeoAI.sandbox.execution.seccomp").reset()
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
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" or vim.fn.executable("python3") ~= 1 then return end
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", seccomp = { enabled = true } } } }, function()
      sandbox.reset()
      require("NeoAI.sandbox.execution.seccomp").reset()
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
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local sandbox = require("NeoAI.sandbox")
    local store = require("NeoAI.sandbox.state.store")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run" } } }, function()
      sandbox.reset()
      local done = false
      require("NeoAI.tools").execute("read_file",
        { file_path = "/proc/self/mountinfo", description = "t" }, {}):then_(function(r)
        local s = tostring(r)
        t.true_(not s:find("/.cache-", 1, true), "不应泄露 overlay 私有基目录，实际: " .. s)
        if store.root() and store.root() ~= "" then
          t.true_(not s:find(store.root() or "", 1, true), "不应泄露沙箱存储根")
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

  it("加固：默认最小权限（cap-drop ALL + 基线 CAP_DAC_OVERRIDE + 收敛主机全局能力）+ seccomp；可显式放宽", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local sandbox = require("NeoAI.sandbox")
    -- 默认：cap-drop ALL + 基线 CAP_DAC_OVERRIDE，收敛主机全局能力；seccomp 生效。
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
      -- 基线：CAP_DAC_OVERRIDE（bit1=0x2）+ CAP_SETGID（bit6=0x40）+ CAP_SETUID（bit7=0x80）= 0xc2。
      -- DAC_OVERRIDE 使 root 载荷可访问他人属主 0700 目录；SETUID/SETGID 供沙箱内降权（PG 等）；
      -- 其余能力仍丢弃。
      t.matches("CapEff:%s*0*[cC]2\n", out, "默认应仅持有 DAC_OVERRIDE + SETUID/SETGID")
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
      t.true_(assert(out):find("CapEff:%s*0*[1-9a-f]") ~= nil, "cap_add={ALL} 应持有完整 root 能力")
      t.matches("Seccomp:%s*2", out, "应加载 seccomp 过滤器")
    end)
    -- 前缀级（最小权限模式下）：含包管理器的命令（含链式）按需加回窄能力；普通命令不加回。
    local privilege = require("NeoAI.sandbox.execution.privilege")
    local spec = { effect = "process" }
    local function prefix_for(cmd)
      local req = privilege.classify("run_command", { command = cmd }, spec)
      local r = privilege.resolve(req.tier, req)
      t.true_(r.ok, "应可解析: " .. cmd)
      return table.concat(assert(runtime.process_prefix({ cwd = "/tmp", privileges = r.privileges })), " ")
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
      t.true_(plain:find("--cap-add CAP_DAC_OVERRIDE", 1, true) ~= nil,
        "普通命令应基线加回 CAP_DAC_OVERRIDE（访问他人属主 0700 目录）")
      t.true_(plain:find("--cap-add CAP_CHOWN", 1, true) == nil, "普通命令不应加回 CAP_CHOWN")
    end)
  end)

  it("cache：内容寻址读写与清理", function(t)
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { sandbox = { workspace_root = vim.fn.tempname() } } }, function()
      sandbox.reset()
      local cache = require("NeoAI.sandbox.state.cache")
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
      require("NeoAI.tools").execute("edit_file", { file_path = p, mode = "write", content = "v2\n", description = "t" }, {})
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
      require("NeoAI.tools").execute("edit_file", { file_path = p, mode = "write", content = "v2\n", description = "t" }, {})
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
      require("NeoAI.tools").execute("edit_file", { file_path = p, mode = "write", content = "v2\n", description = "t" }, {})
        :then_(function()
          local parent = sandbox.list_reviews({ review_state = "PENDING" })[1]
          sandbox.approve(parent.change_set_id) -- 旧版已批准但未应用
          local child = sandbox.derive_revision(parent.change_set_id, { contents = { [p] = "v3\n" } })
          t.not_nil(child, "应派生出新 revision")
          assert(child)
          t.eq(2, child.revision)
          t.eq(parent.change_set_id, child.supersedes)
          -- 原变更单元应标记 SUPERSEDED（不迁移旧批准）
          local parent_state
          for _, rev_item in ipairs(sandbox.list_reviews()) do
            if rev_item.change_set_id == parent.change_set_id then parent_state = rev_item.review_state end
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
    local runtime = require("NeoAI.sandbox.execution.runtime")
    local store = require("NeoAI.sandbox.state.store")
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
    local runtime = require("NeoAI.sandbox.execution.runtime")
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
        return tools.execute("read_file", { file_path = dir .. "/sub/a.txt", description = "t" }, {})
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

  it("发布：递归删除先删子项再 rmdir 父目录（避免非空 rmdir 失败）", function(t)
    local fs = require("NeoAI.utils.fs")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local root = fs.canonical(vim.fn.tempname())
    fs.ensure_dir(root .. "/pip")
    fs.write_file(root .. "/pip/a.txt", "x")
    fs.write_file(root .. "/pip/b.txt", "y")
    local function sha(p) return "sha256:" .. vim.fn.sha256(fs.read_file(p)) end
    local res = candidate.publish({
      candidate_digest = "sha256:rmtree",
      files = {
        -- 故意按路径升序（父目录在前），模拟 finish 的排序结果：
        -- 修复前会先对非空父目录 rmdir 而整单元 WRITE_FAILED。
        { path = root .. "/pip", action = "rmdir", base_exists = true, base_type = "directory" },
        { path = root .. "/pip/a.txt", action = "delete", base_exists = true, base_type = "file",
          before_hash = sha(root .. "/pip/a.txt") },
        { path = root .. "/pip/b.txt", action = "delete", base_exists = true, base_type = "file",
          before_hash = sha(root .. "/pip/b.txt") },
      },
    })
    t.true_(res.ok, "递归删除应成功: " .. tostring(res.reason))
    t.false_(fs.exists(root .. "/pip"), "父目录应被删除")
    vim.fn.delete(root, "rf")
  end)

  it("加固：发布前重规范化路径，拒绝 `..` 穿越与遮蔽目标", function(t)
    local fs = require("NeoAI.utils.fs")
    local candidate = require("NeoAI.sandbox.execution.candidate")
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
    local risk = require("NeoAI.sandbox.review.risk")
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
    local policy = require("NeoAI.sandbox.review.policy")
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
    local seccomp = require("NeoAI.sandbox.execution.seccomp")
    local function has_x32_guard(arch)
      local f = seccomp.build_filter(arch)
      -- BPF_JSET_K(0x45) jt=0 jf=1 k=0x40000000（小端）
      return f ~= nil and f:find(string.char(0x45, 0, 0, 1, 0, 0, 0, 0x40), 1, true) ~= nil
    end
    t.true_(has_x32_guard("x86_64"), "x86_64 应拦截带 __X32_SYSCALL_BIT 的 syscall 号")
    t.false_(has_x32_guard("aarch64"), "aarch64 无 x32 ABI")
  end)

  it("加固：候选存储目录权限收紧为 0700", function(t)
    local store = require("NeoAI.sandbox.state.store")
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
    local review = require("NeoAI.sandbox.review.review")
    local store = require("NeoAI.sandbox.state.store")
    with_config({ tools = { sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      -- 1) 候选缺失：不入库候选，应用应失败但条目回退为待审
      local missing = {
        candidate_digest = "sha256:missing", created_at = os.time(), effect = "fs_write",
        files = { { path = "/tmp/neoai_missing.txt", action = "create", after_hash = "h", content = "x" } },
      }
      local item = assert(review.enqueue(missing, { id = "cs_keep_missing", tool = "edit_file" }))
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
      local it2 = assert(review.enqueue(cand, { id = "cs_keep_conflict", tool = "edit_file" }))
      local res2 = review.apply(it2.change_set_id, { auto_approve = true })
      t.false_(res2.ok, "基线变化时应用应冲突")
      t.eq("CONFLICT", res2.state)
      local pending2 = sandbox.list_reviews({ review_state = "PENDING" })
      t.eq(2, #pending2, "冲突后条目仍应在待审队列中")
      fs.delete_file(p)
    end)
  end)

  it("发布：rmdir/delete 目标已不存在时幂等成功", function(t)
    local fs = require("NeoAI.utils.fs")
    local writer = require("NeoAI.sandbox.execution.writer")
    local root = fs.canonical(vim.fn.tempname())
    fs.ensure_dir(root)
    local r1 = writer.apply("rmdir", root .. "/gone", nil, {})
    t.true_(r1.ok, "rmdir 不存在的目录应成功: " .. tostring(r1.err or r1.reason))
    local r2 = writer.apply("delete", root .. "/nofile.txt", nil, {})
    t.true_(r2.ok, "delete 不存在的文件应成功: " .. tostring(r2.err or r2.reason))
    fs.delete_file(root)
  end)

  it("发布：非原子整包部分写入失败仅失败该文件，其余照常应用", function(t)
    local fs = require("NeoAI.utils.fs")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local root = fs.canonical(vim.fn.tempname())
    fs.ensure_dir(root)
    -- blocker 是普通文件；向其下方写子文件必然失败（无法在文件下建目录）。
    local blocker = root .. "/blocker"
    fs.write_file(blocker, "x")
    local ok_file = root .. "/ok.txt"
    local bad_path = blocker .. "/child.txt"
    local res = candidate.publish({
      candidate_digest = "sha256:partial_test",
      files = {
        { path = bad_path, action = "create", content = "bad\n" },
        { path = ok_file, action = "create", content = "ok\n" },
      },
    })
    t.eq("PARTIAL", res.state, "应报告部分应用: " .. tostring(res.reason))
    t.false_(res.ok, "部分应用 ok 应为 false")
    t.eq(1, #(res.applied or {}), "应有一个文件应用成功")
    t.eq(ok_file, res.applied[1], "成功文件应为 ok_file")
    t.eq(1, #(res.failed or {}), "应有一个文件失败")
    t.eq(bad_path, res.failed[1].path, "失败文件应为 bad_path")
    t.true_(fs.exists(ok_file), "ok_file 应已落盘")

    -- 原子整组（如 git）：任一失败即整体失败，不写入其他文件。
    local nf = root .. "/never.txt"
    local res2 = candidate.publish({
      candidate_digest = "sha256:atomic_test",
      files = {
        { path = bad_path, action = "create", content = "bad\n" },
        { path = nf, action = "create", content = "no\n" },
      },
    }, { atomic = true })
    t.eq("FAILED", res2.state, "原子组应整体失败")
    t.false_(fs.exists(nf), "原子组失败时不应写入其他文件")

    fs.delete_file(blocker)
    fs.delete_file(ok_file)
    fs.delete_file(root)
  end)
end)
