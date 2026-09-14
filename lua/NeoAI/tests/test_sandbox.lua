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

  it("加固：前缀丢弃全部 capability 并按类型遮蔽敏感路径", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local fs = require("NeoAI.utils.fs")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local file = dir .. "/secret.sock"
    fs.write_file(file, "")
    with_config({ tools = { sandbox = { mask_paths = { dir, file } } } }, function()
      local prefix = runtime.process_prefix({ cwd = "/tmp" })
      t.not_nil(prefix, "应能构造前缀")
      local joined = table.concat(prefix, " ")
      t.true_(joined:find("--cap-drop ALL", 1, true) ~= nil, "应丢弃全部 capability")
      t.true_(joined:find("--tmpfs " .. dir, 1, true) ~= nil, "目录应以空 tmpfs 遮蔽")
      t.true_(joined:find("--bind /dev/null " .. file, 1, true) ~= nil, "文件/socket 应以 /dev/null 遮蔽")
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("加固：只读白名单可配置且跳过不存在项", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    local fs = require("NeoAI.utils.fs")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local file = dir .. "/keep.conf"
    fs.write_file(file, "x")
    with_config({ tools = { sandbox = {
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

  it("加固：/usr 子树白名单收敛读取面（不整目录暴露）", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local prefix = runtime.process_prefix({ cwd = "/tmp" })
    t.not_nil(prefix, "应能构造前缀")
    local joined = table.concat(prefix, " ")
    t.true_(joined:find("--ro-bind / /", 1, true) == nil, "不应再整机只读根")
    t.true_(joined:find("--ro-bind /usr /usr ", 1, true) == nil, "不应整目录暴露 /usr")
    t.true_(joined:find("--ro-bind /usr/bin /usr/bin", 1, true) ~= nil, "应白名单暴露 /usr/bin")
    t.true_(joined:find("--ro-bind /usr/lib /usr/lib", 1, true) ~= nil, "应白名单暴露 /usr/lib")
    local cmd = {}
    for _, v in ipairs(prefix) do cmd[#cmd + 1] = v end
    for _, v in ipairs({ "/bin/sh", "-c",
      "if [ -e /home ]; then echo LEAK_HOME; fi; "
      .. "if [ -s /etc/shadow ]; then echo LEAK_SHADOW; fi; "
      .. "if [ -s /etc/machine-id ]; then echo LEAK_MACHINEID; fi; "
      .. "if [ -n \"$(ls -A /var/log 2>/dev/null)\" ]; then echo LEAK_VARLOG; fi; "
      .. "if [ -e /usr/share/doc ]; then echo LEAK_DOC; fi; "
      .. "if [ -e /usr/local/go_workspace ]; then echo LEAK_GOWORKSPACE; fi; "
      .. "if [ -e /usr/src ]; then echo LEAK_USRSRC; fi; "
      .. "echo READ_CONVERGED",
    }) do cmd[#cmd + 1] = v end
    local out = vim.fn.system(cmd)
    t.true_(out:find("READ_CONVERGED", 1, true) ~= nil, "命令应完成，实际: " .. tostring(out))
    t.true_(out:find("LEAK_", 1, true) == nil, "不应泄露宿主敏感路径，实际: " .. tostring(out))
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
    with_config({ tools = { sandbox = { mask_dirs_enabled = true, mask_dirs = { "/home", "/root" } } } }, function()
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
    with_config({ tools = { sandbox = { mask_dirs_enabled = false } } }, function()
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
      mask_dirs_enabled = true, mask_dirs = { "/root" }, mask_dirs_approval = true,
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
      require("NeoAI.tools").execute("run_command", { command = "sudo id", description = "t" }, {})
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

  it("运行时：overlay 不可用时降级为私有可写 cwd 且命令仍可执行", function(t)
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
      local done = false
      require("NeoAI.tools").execute("run_command", { command = "ls", description = "t" }, {}):then_(function(r)
        t.true_(not tostring(r):find("real.txt", 1, true), "降级 cwd 应为私有目录，不暴露真实项目文件")
        t.matches("降级模式", tostring(r), "降级视图应在结果中标注提示")
        t.true_(fs.exists(dir .. "/real.txt"), "真实文件不应被改动")
        done = true
      end, function(e)
        t.true_(false, "overlay 不可用时命令仍应可执行: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(10000, function() return done end), "run_command 应完成")
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
    local orig = runtime.overlay_mountable
    runtime.overlay_mountable = function() return false end
    local prefix, err = runtime.process_prefix({
      cwd = "/tmp", upper = "/tmp/neoai_ovl_u", work = "/tmp/neoai_ovl_w",
      fallback_cwd = "/tmp/neoai_ovl_f",
    })
    runtime.overlay_mountable = orig
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

  it("加固：沙箱进程不持有 capability 且 seccomp 生效", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local sandbox = require("NeoAI.sandbox")
    with_config({
      tools = {
        approval = { mode = "async" },
        sandbox = { mode = "dry_run", review = { enabled = true }, seccomp = { enabled = true } },
      },
    }, function()
      sandbox.reset()
      local done = false
      require("NeoAI.tools").execute("run_command", {
        command = "grep -E 'CapEff|Seccomp:' /proc/self/status",
        description = "t",
      }, {}):then_(function(r)
        local s = tostring(r)
        t.matches("CapEff:%s*0+", s, "载荷不应持有任何 capability")
        t.matches("Seccomp:%s*2", s, "应加载 seccomp 过滤器")
        done = true
      end, function(e) t.true_(false, tostring(e and e.message or e)); done = true end)
      t.true_(vim.wait(8000, function() return done end), "命令应完成")
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
end)
