--- 沙箱核心：加载器规格/策略/fail-closed/状态机/工作区映射/不可见性/git 守卫
--- @module NeoAI.tests.test_sandbox_core
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


tests.suite("sandbox_core", function(_, it)
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
      require("NeoAI.tools").execute("read_file", { file_path = "/tmp/x", description = "t" }, {})
        :then_(function() done = true; t.true_(false, "应 fail-closed") end, function(e)
          t.matches("沙箱", tostring(e and e.message or e))
          done = true
        end)
      t.true_(vim.wait(2000, function() return done end), "应快速拒绝")
    end)
    services.provide("services.sandbox", saved)
  end)

  it("控制面：幂等键、状态迁移与 fencing", function(t)
    local control = require("NeoAI.sandbox.execution.control")
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
    local policy = require("NeoAI.sandbox.review.policy")
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
    local policy = require("NeoAI.sandbox.review.policy")
    with_config({ tools = { sandbox = { policy = { rules = { function() error("boom") end } } } } }, function()
      local v = policy.evaluate({ tool = "x", effect = "read" })
      t.eq("DENY", v.decision)
      t.true_(vim.tbl_contains(v.reason_codes, "POLICY_EVALUATION_FAILED"))
    end)
  end)

  it("策略：死循环规则有界终止并 DENY", function(t)
    local policy = require("NeoAI.sandbox.review.policy")
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
        file_path = p, mode = "write", content = "next\n", description = "t",
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
        file_path = p, edits = { { old_text = "A", new_text = "X" } }, description = "t",
      }, {}):then_(function(r)
        r1 = r
        return tools.execute("read_file", { file_path = p, description = "t" }, {})
      end):then_(function(rr)
        read_back = rr
        return tools.execute("edit_file", {
          file_path = p, edits = { { old_text = "B", new_text = "Y" } }, description = "t",
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
        -- 内存条目落盘后已剥离 content：按需经 content_for 从候选读取。
        t.eq("X Y\n", sandbox.content_for(items[1].change_set_id, p), "候选内容应为叠加后的 X Y")
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
        file_path = p, mode = "write", content = "v1\n", description = "t",
      }, {}):then_(function()
        return tools.execute("edit_file", {
          file_path = p, mode = "write", content = "v2\n", description = "t",
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
        file_path = p_mod, mode = "write", content = "staged unique content\n", description = "t",
      }, {}):then_(function()
        return tools.execute("edit_file", {
          file_path = p_new, mode = "write", content = "brand new\n", description = "t",
        }, {})
      end):then_(function()
        return tools.execute("delete_file", { file_path = p_del, description = "t" }, {})
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
        return tools.execute("file_exists", { file_path = p_del, description = "t" }, {})
      end):then_(function(r)
        t.eq("false", tostring(r), "已删除文件 file_exists 应为 false")
        return tools.execute("file_exists", { file_path = p_new, description = "t" }, {})
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

  it("只读工具合并视图：符号链接路径与真实路径一致（不落回真实视图）", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local link = dir .. "-link"
    vim.uv.fs_symlink(dir, link)
    local p = dir .. "/mod.txt"
    fs.write_file(p, "old content here\n")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local tools = require("NeoAI.tools")
      local done = false
      tools.execute("edit_file", { file_path = p, mode = "write", content = "staged marker here\n", description = "t" }, {})
        :then_(function()
          return tools.execute("search_files", { path = link, query = "staged marker", description = "t" }, {})
        end):then_(function(r)
          t.matches("staged marker", tostring(r), "经符号链接路径搜索应命中暂存内容")
          return tools.execute("search_files", { path = link, query = "old content", description = "t" }, {})
        end):then_(function(r)
          t.true_(not tostring(r):find("old content", 1, true),
            "暂存覆盖后旧内容不应再被搜到（符号链接路径）: " .. tostring(r))
          return tools.execute("list_files", { path = link, description = "t" }, {})
        end):then_(function(r)
          t.matches("mod%.txt", tostring(r), "符号链接路径列举应包含文件")
          return tools.execute("file_exists", { file_path = link .. "/mod.txt", description = "t" }, {})
        end):then_(function(r)
          t.eq("true", tostring(r), "符号链接路径 file_exists 应为 true")
          done = true
        end, function(e)
          t.true_(false, "不应失败: " .. tostring(e and e.message or e)); done = true
        end)
      t.true_(vim.wait(5000, function() return done end), "应完成")
    end)
    pcall(vim.fn.delete, link)
    vim.fn.delete(dir, "rf")
  end)

  it("只读工具合并视图：暂存删除的目录下真实文件不再被 search_files 命中", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir .. "/sub")
    fs.write_file(dir .. "/sub/a.txt", "deleted-dir-unique-marker\n")
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local tools = require("NeoAI.tools")
      local done = false
      tools.execute("run_command", { command = "rm -rf sub", description = "t" }, {})
        :then_(function()
          return tools.execute("search_files", { path = dir, query = "deleted-dir-unique-marker", description = "t" }, {})
        end):then_(function(r)
          t.true_(not tostring(r):find("deleted%-dir%-unique%-marker"),
            "暂存删除目录下的真实文件不应被搜到: " .. tostring(r))
          done = true
        end, function(e)
          t.true_(false, "不应失败: " .. tostring(e and e.message or e)); done = true
        end)
      t.true_(vim.wait(20000, function() return done end), "应完成")
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
  end)

  it("只读工具合并视图：暂存删除的文件 read_file 不返回真实内容", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local p = dir .. "/del.txt"
    fs.write_file(p, "real-secret-content\n")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local tools = require("NeoAI.tools")
      local done = false
      tools.execute("delete_file", { file_path = p, description = "t" }, {}):then_(function()
        return tools.execute("read_file", { file_path = p, description = "t" }, {})
      end):then_(function(r)
        t.true_(not tostring(r):find("real-secret-content", 1, true),
          "暂存删除后 read_file 不应返回真实内容")
        done = true
      end, function(e)
        -- 删除态读取失败（读不到）也是可接受结果：只要不泄露真实内容。
        t.true_(not tostring(e and e.message or e):find("real-secret-content", 1, true),
          "删除态错误不应泄露真实内容")
        done = true
      end)
      t.true_(vim.wait(5000, function() return done end), "应完成")
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("一致性：run_command 写入对 search_files/read_file 可见（命令视图与 grep 一致）", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    fs.write_file(dir .. "/f.txt", "base-line\n")
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local tools = require("NeoAI.tools")
      local done = false
      tools.execute("run_command", {
        command = "printf 'cmd-unique-line\\n' >> f.txt", description = "t",
      }, {}):then_(function()
        return tools.execute("search_files", { path = dir, query = "cmd-unique-line", description = "t" }, {})
      end):then_(function(r)
        t.matches("cmd%-unique%-line", tostring(r), "search_files 应命中命令写入的内容")
        return tools.execute("read_file", { file_path = dir .. "/f.txt", description = "t" }, {})
      end):then_(function(r)
        t.matches("cmd%-unique%-line", tostring(r), "read_file 应读到命令写入的内容")
        t.eq("base-line\n", fs.read_file(dir .. "/f.txt") or "", "真实文件不应被命令改动（dry_run）")
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e)); done = true
      end)
      t.true_(vim.wait(20000, function() return done end), "应完成")
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
  end)

  it("git 变更守卫：run_command 中的 git 变更子命令被拒绝（改走专用 git 工具）", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local done, err = false, nil
      require("NeoAI.tools").execute("run_command", {
        command = "git add . && git commit -m x", description = "t",
      }, {}):then_(function() done = true end, function(e) err = e; done = true end)
      t.true_(vim.wait(5000, function() return done end), "应完成")
      t.matches("SANDBOX_GIT_MUTATION_VIA_COMMAND", tostring(err and err.message or err),
        "git 变更子命令应被拒绝: " .. tostring(err and err.message or err))
    end)
    sandbox.reset()
  end)

  it("git 守卫：识别变更子命令、放行只读子命令", function(t)
    local g = require("NeoAI.sandbox.observe.git_guard")
    t.eq("add", g.mutating("git add ."))
    t.eq("commit", g.mutating("cd x && git -C /repo commit -m hi"))
    t.eq("stash", g.mutating("git stash push -u"))
    t.eq("reset", g.mutating("git -c foo=bar reset --hard"))
    -- `git stash` 的只读子动作（list/show）放行；其余动作仍拦
    t.nil_(g.mutating("git stash list"), "stash list 应放行")
    t.nil_(g.mutating("git stash show"), "stash show 应放行")
    t.nil_(g.mutating("git stash list --oneline"), "stash list 带选项应放行")
    t.nil_(g.mutating("git stash show -p stash@{0}"), "stash show -p 应放行")
    t.eq("stash", g.mutating("git stash"), "裸 stash 应拦")
    t.eq("stash", g.mutating("git stash -u"), "stash -u 应拦")
    t.eq("stash", g.mutating("git stash pop"), "stash pop 应拦")
    t.eq("stash", g.mutating("git stash apply"), "stash apply 应拦")
    t.eq("stash", g.mutating("git stash drop"), "stash drop 应拦")
    t.eq("stash", g.mutating("git stash clear"), "stash clear 应拦")
    t.eq("stash", g.mutating("echo hi && git stash pop"), "命令链中的 stash pop 应拦")
    t.nil_(g.mutating("git status"), "status 应放行")
    t.nil_(g.mutating("git log --oneline"), "log 应放行")
    t.nil_(g.mutating("echo hello"), "非 git 应放行")
    -- clone/init 新建仓库（供 pyenv/nvm 等安装脚本），放行；其余变更仍拦
    t.nil_(g.mutating("git clone https://github.com/o/r.git"), "clone 应放行")
    t.nil_(g.mutating("git -C /opt/pyenv init"), "init 应放行")
    t.eq("commit", g.mutating("git clone x && git commit -m y"), "clone 后接 commit 仍应拦 commit")
    local rt = require("NeoAI.sandbox.execution.runtime")
    t.true_(rt.is_git_internal("/a/.git/index"))
    t.true_(rt.is_git_internal("/repo/vendor/x/.git"))
    t.false_(rt.is_git_internal("/a/b.lua"))
  end)

  it("git 路径分类：对象/指针/瞬态/配置", function(t)
    local rt = require("NeoAI.sandbox.execution.runtime")
    t.eq("object", rt.git_path_class("/repo/.git/objects/ab/cdef"))
    t.eq("pointer", rt.git_path_class("/repo/.git/index"))
    t.eq("pointer", rt.git_path_class("/repo/.git/HEAD"))
    t.eq("pointer", rt.git_path_class("/repo/.git/refs/heads/main"))
    t.eq("pointer", rt.git_path_class("/repo/.git/logs/refs/stash"))
    t.eq("transient", rt.git_path_class("/repo/.git/index.lock"))
    t.eq("transient", rt.git_path_class("/repo/.git/gc.log"))
    t.eq("other", rt.git_path_class("/repo/.git/config"))
    t.nil_(rt.git_path_class("/repo/a.lua"))
  end)

  it("git 变更：沙箱内执行，.git 改动原子暂存进审批悬浮窗（dry_run 不改真实 .git）", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    if vim.fn.executable("git") ~= 1 then return end
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    fs.write_file(dir .. "/a.txt", "hello\n")
    vim.fn.system({ "git", "-C", dir, "init", "-q" })
    vim.fn.system({ "git", "-C", dir, "config", "user.email", "t@t" })
    vim.fn.system({ "git", "-C", dir, "config", "user.name", "t" })
    local index_before = fs.read_file(dir .. "/.git/index") or ""
    t.eq("process", require("NeoAI.sandbox.execution.tool_spec").get("git_add").effect,
      "git_add 应在沙箱内执行（process）")
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local done = false
      require("NeoAI.tools").execute("git_add", { all = true, description = "t" }, {})
        :then_(function() done = true end, function() done = true end)
      t.true_(vim.wait(20000, function() return done end), "应完成")
      -- 待审队列中应出现该 git 变更，且包含 .git/index（指针）与对象（object）。
      local found_index, found_object = false, false
      for _, item in ipairs(sandbox.list_reviews({ review_state = "PENDING" })) do
        for _, f in ipairs(item.files or {}) do
          local gc = require("NeoAI.sandbox.execution.runtime").git_path_class(f.path)
          if gc == "pointer" and f.path:match("/%.git/index$") then found_index = true end
          if gc == "object" then found_object = true end
        end
      end
      t.true_(found_index, "待审候选应包含 .git/index")
      t.true_(found_object, "待审候选应包含 git 对象")
      -- dry_run：真实 .git 不应被改动。
      t.eq(index_before, fs.read_file(dir .. "/.git/index") or "", "真实 .git/index 不应被改动")
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
  end)

  it("git 变更：git_add 未应用即被 git_commit 取代，应用 commit 不悬空（回归）", function(t)
    -- 回归：git_add 候选被 git_commit 整组取代（对象随旧候选丢弃），但 commit 的 index 仍引用
    -- git_add 产生的 blob。若捕获从暂存物化的对象时走 ws_skip 漏登记，发布闸门会以
    -- GIT_REFERENTIAL_INTEGRITY 拒绝整单（用户报告的应用失败）。
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    if vim.fn.executable("git") ~= 1 then return end
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    fs.write_file(dir .. "/a.txt", "hello\n")
    vim.fn.system({ "git", "-C", dir, "init", "-q" })
    vim.fn.system({ "git", "-C", dir, "config", "user.email", "t@t" })
    vim.fn.system({ "git", "-C", dir, "config", "user.name", "t" })
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local function run(tool, args)
        local done = false
        require("NeoAI.tools").execute(tool, args, {}):then_(function() done = true end, function() done = true end)
        t.true_(vim.wait(30000, function() return done end, 50), tool .. " 应完成")
        t.true_(vim.wait(30000, function() return not sandbox.postprocess_pending() end, 50), "后处理应完成")
      end
      -- git_add 只入待审、不应用；git_commit 整组取代 git_add（其对象随之被丢弃）。
      run("git_add", { all = true, description = "t" })
      run("git_commit", { message = "c1", description = "t" })
      local applied = false
      for _, item in ipairs(sandbox.list_reviews({ review_state = "PENDING" })) do
        if item.tool == "git_commit" then
          local res = sandbox.apply(item.change_set_id, { auto_approve = true })
          t.true_(res.ok, "应用 git_commit 应成功: " .. tostring(res and res.reason))
          t.eq("COMMITTED", res.state, "应提交成功")
          applied = true
        end
      end
      t.true_(applied, "应存在待审的 git_commit")
      -- 真实 .git 应保持一致：fsck 不报告缺失对象/无法读取。
      local out = vim.fn.system({ "git", "-C", dir, "fsck", "--no-progress", "--strict" })
      t.true_(out:find("missing") == nil, "fsck 不应报告 missing: " .. tostring(out))
      t.true_(out:find("unable to read") == nil, "fsck 不应报告 unable to read: " .. tostring(out))
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
  end)

  it("git 原子发布顺序：对象先于指针（对象已存在时幂等跳过）", function(t)
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local dir = vim.fn.tempname()
    require("NeoAI.utils.fs").ensure_dir(dir .. "/.git/objects/ab")
    -- 构造一个候选：先列出指针，后列出对象；发布排序应把对象排到前面。
    local cand = {
      files = {
        { path = dir .. "/.git/index", action = "create", content = "idx" },
        { path = dir .. "/.git/objects/ab/cd", action = "create", content = "obj" },
      },
    }
    local order = {}
    -- 通过 monkeypatch writer 捕获应用顺序，避免真实写盘失败。
    local writer = require("NeoAI.sandbox.execution.writer")
    local orig_apply = writer.apply
    writer.apply = function(action, path, content, opts)
      order[#order + 1] = path
      return { ok = true, state = "COMMITTED" }
    end
    local res = candidate.publish(cand)
    writer.apply = orig_apply
    t.true_(res.ok, "发布应成功: " .. tostring(res.reason))
    t.true_(#order >= 2, "应有两次写入")
    t.matches("objects", order[1] or "", "对象应先于指针写入")
    t.matches("index", order[#order] or "", "指针应后写入")
    vim.fn.delete(dir, "rf")
  end)

  it("git 发布闸门：指针引用的对象缺失时 fail-closed（防悬空引用）", function(t)
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local dir = vim.fn.tempname()
    require("NeoAI.utils.fs").ensure_dir(dir .. "/.git")
    -- HEAD 指向不存在的 commit → 发布前闸门拒绝（不触发任何写盘）。
    local res = candidate.publish({
      files = {
        { path = dir .. "/.git/HEAD", action = "create", content = string.rep("d", 40) .. "\n" },
      },
    })
    t.eq(false, res.ok, "指针引用缺失对象时应拒绝发布")
    t.eq("FAILED", res.state)
    t.matches("GIT_REFERENTIAL_INTEGRITY", res.reason or "", "应给出完整性拒绝原因")
    -- refs 指向不存在的对象 → 同样拒绝。
    local res_ref = candidate.publish({
      files = {
        { path = dir .. "/.git/refs/heads/newbranch", action = "create",
          content = string.rep("f", 40) .. "\n" },
      },
    })
    t.eq(false, res_ref.ok, "ref 指向缺失对象时应拒绝发布")
    t.matches("GIT_REFERENTIAL_INTEGRITY", res_ref.reason or "", "应给出完整性拒绝原因")
    -- 对照：候选自带被引用对象 → 闸门放行（写盘经 writer 拦截）。
    local oid = string.rep("a", 40)
    local writer = require("NeoAI.sandbox.execution.writer")
    local orig_apply = writer.apply
    local applied = {}
    writer.apply = function(action, path, content, opts)
      applied[#applied + 1] = path
      return { ok = true, state = "COMMITTED" }
    end
    local ok = candidate.publish({
      files = {
        { path = dir .. "/.git/HEAD", action = "create", content = oid .. "\n" },
        { path = dir .. "/.git/objects/aa/" .. string.rep("a", 38), action = "create", content = "obj" },
      },
    })
    writer.apply = orig_apply
    t.true_(ok.ok, "候选自带被引用对象时应放行: " .. tostring(ok.reason))
    t.true_(#applied >= 2, "应写入对象与指针")
    t.matches("objects", applied[1] or "", "对象应先于指针写入")
    vim.fn.delete(dir, "rf")
  end)

  it("一致性：命令还原暂存编辑后同步视图（不残留待审候选，不被旧暂存回滚）", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local real = dir .. "/f.txt"
    fs.write_file(real, "base\n")
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local tools = require("NeoAI.tools")
      local done = false
      tools.execute("edit_file", {
        filepath = real, mode = "write", content = "staged-edit\n", description = "t",
      }, {}):then_(function()
        -- 非 git 命令把文件还原为真实基线（等价于命令撤销暂存编辑）。
        return tools.execute("run_command", { command = "printf 'base\\n' > f.txt", description = "t" }, {})
      end):then_(function()
        -- 再跑一条空命令触发物化：若 view 未同步，旧暂存会被重新物化回工作区。
        return tools.execute("run_command", { command = "true", description = "t" }, {})
      end):then_(function()
        return tools.execute("read_file", { filepath = real, description = "t" }, {})
      end):then_(function(r)
        local s = tostring(r)
        t.matches("base", s, "命令还原后应读到 base: " .. s)
        t.true_(not s:find("staged%-edit"), "不应被旧暂存内容回滚: " .. s)
        for _, item in ipairs(sandbox.list_reviews({ review_state = "PENDING" })) do
          for _, f in ipairs(item.files or {}) do
            t.ne(f.path, real, "还原后不应残留该路径的待审候选")
          end
        end
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e)); done = true
      end)
      t.true_(vim.wait(20000, function() return done end), "应完成")
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
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
        file_path = p, mode = "write", content = "local staged_marker = 1\n", description = "t",
      }, {}):then_(function()
        return tools.execute("get_node_code", { file_path = p, line = 1, col = 8, description = "t" }, {})
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
        file_path = p, mode = "write", content = "local a = 1\nlocal b = 2\n", description = "t",
      }, {}):then_(function()
        return tools.execute("delete_node", { file_path = p, line = 2, col = 1, description = "t" }, {})
      end):then_(function()
        return tools.execute("read_file", { file_path = p, description = "t" }, {})
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
      tools.execute("edit_file", { file_path = p, mode = "append", content = "appended\n", description = "t" }, {})
        :then_(function()
          return tools.execute("read_file", { file_path = p, description = "t" }, {})
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
        file_path = p, mode = "write", content = "hi\n", description = "t",
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

  it("run_command：/tmp 内容在同一会话内跨命令保留", function(t)
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
      local tag = "neoai_tmp_" .. tostring(vim.uv.hrtime())
      tools.execute("run_command",
        { command = "mkdir -p /tmp/" .. tag .. " && echo hi > /tmp/" .. tag .. "/a.txt", description = "t" }, {})
        :then_(function()
          return tools.execute("run_command",
            { command = "cat /tmp/" .. tag .. "/a.txt", description = "t" }, {})
        end):then_(function(r)
          t.matches("hi", tostring(r), "/tmp 内容应在同一会话内跨命令可见")
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
    local runtime = require("NeoAI.sandbox.execution.runtime")
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
      tools.execute("edit_file", { file_path = dir .. "/f.txt", mode = "write", content = "edited\n", description = "t" }, {})
        :then_(function()
          return tools.execute("run_command", { command = "cat f.txt", description = "t" }, {})
        end):then_(function(r)
          t.matches("edited", tostring(r), "run_command 应读到 edit_file 的暂存改动")
          -- 2) run_command 追加 → read_file 应读到叠加后的内容
          return tools.execute("run_command", { command = "echo fromcmd >> f.txt", description = "t" }, {})
        end):then_(function()
          return tools.execute("read_file", { file_path = dir .. "/f.txt", description = "t" }, {})
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

  it("暂存覆盖：staged_overlay_roots 补齐工作区外暂存路径的覆盖根", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    sandbox.reset()
    local cwd = vim.fn.tempname()
    local outside = vim.fn.tempname()
    fs.ensure_dir(cwd)
    fs.ensure_dir(outside)
    local real = outside .. "/a.txt"
    fs.write_file(real, "base\n")
    with_config({
      tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", read_all = false, review = { enabled = true } } },
    }, function()
      local done = false
      require("NeoAI.tools").execute(
        "edit_file", { file_path = real, mode = "write", content = "edited\n", description = "t" }, {})
        :then_(function()
          -- 已暂存但不在已知根（cwd）内 → 补其所在目录
          local roots = candidate.staged_overlay_roots({ cwd })
          t.eq(1, #roots, "应补一个覆盖根")
          t.eq(fs.canonical(outside), roots[1], "覆盖根应为暂存文件所在目录")
          -- 被已知根覆盖时不返回
          t.eq(0, #candidate.staged_overlay_roots({ cwd, outside }), "已覆盖则不再补根")
          -- 纳入 overlay 规格后，规格覆盖该暂存文件（命令视图与只读视图一致）
          local wrapper = require("NeoAI.sandbox.execution.wrapper")
          local specs = wrapper.build_overlay_specs(cwd, candidate.process_dir(), roots)
          local covered = false
          local creal = fs.canonical(real)
          for _, s in ipairs(specs) do
            local r = s.root
            if r == "/" or creal == r or creal:sub(1, #r + 1) == r .. "/" then covered = true end
          end
          t.true_(covered, "overlay 规格应覆盖暂存文件")
          done = true
        end, function(e)
          t.true_(false, "edit_file 不应失败: " .. tostring(e and e.message or e))
          done = true
        end)
      t.true_(vim.wait(10000, function() return done end), "应完成")
    end)
    sandbox.reset()
    vim.fn.delete(cwd, "rf")
    vim.fn.delete(outside, "rf")
  end)

  it("暂存一致性：has_staged 反映未发布的实质改动", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    fs.write_file(dir .. "/f.txt", "base\n")
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      t.false_(candidate.has_staged(), "初始无暂存")
      local done = false
      local tools = require("NeoAI.tools")
      tools.execute("edit_file",
        { file_path = dir .. "/f.txt", mode = "write", content = "base\n", description = "noop" }, {})
        :then_(function()
          t.false_(candidate.has_staged(), "空操作不应视为未发布改动")
          return tools.execute("edit_file",
            { file_path = dir .. "/f.txt", mode = "write", content = "edited\n", description = "t" }, {})
        end):then_(function()
          t.true_(candidate.has_staged(), "实质改动应视为未发布")
          candidate.invalidate(dir .. "/f.txt")
          t.false_(candidate.has_staged(), "失效后不应再有暂存")
          done = true
        end, function(e)
          t.true_(false, "不应失败: " .. tostring(e and e.message or e))
          done = true
        end)
      t.true_(vim.wait(10000, function() return done end), "应完成")
    end)
    vim.fn.chdir(prev)
    sandbox.reset()
    vim.fn.delete(dir, "rf")
  end)

  it("无 overlay 且有暂存：staging_uncovered=warn 时降级执行并附提示", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    fs.write_file(dir .. "/f.txt", "base\n")
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    with_config({ tools = { approval = { mode = "async" }, sandbox = {
      mode = "dry_run", review = { enabled = true }, staging_uncovered = "warn",
    } } }, function()
      sandbox.reset()
      local done = false
      local tools = require("NeoAI.tools")
      tools.execute("edit_file",
        { file_path = dir .. "/f.txt", mode = "write", content = "edited\n", description = "t" }, {})
        :then_(function()
          local saved_avail, saved_writable = runtime.overlay_available, runtime.overlay_writable
          runtime.overlay_available = function() return false end
          runtime.overlay_writable = function() return false end
          local ok, err, ctx = nil, nil, {}
          tools.execute("run_command", { command = "echo hi", description = "t" }, ctx)
            :then_(function() ok = true end, function(e) err = e end)
          t.true_(vim.wait(15000, function() return ok or err end), "命令应返回")
          runtime.overlay_available, runtime.overlay_writable = saved_avail, saved_writable
          t.true_(ok == true, "warn 模式应降级执行而非拒绝: " .. tostring(err and err.message or err))
          -- 降级提示不再出现（用户侧也不提示）。
          t.true_(not tostring(ctx.ui_notice):find("降级", 1, true), "不应再附加降级提示")
          done = true
        end, function(e)
          t.true_(false, "edit_file 不应失败: " .. tostring(e and e.message or e))
          done = true
        end)
      t.true_(vim.wait(20000, function() return done end), "应完成")
    end)
    vim.fn.chdir(prev)
    sandbox.reset()
    vim.fn.delete(dir, "rf")
  end)

  it("无 overlay 时禁止降级：存在未发布暂存改动则拒绝命令", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    fs.write_file(dir .. "/f.txt", "base\n")
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    with_config({ tools = { approval = { mode = "async" }, sandbox = {
      mode = "dry_run", review = { enabled = true },
      degraded_seed = false,
    } } }, function()
      sandbox.reset()
      local done = false
      local tools = require("NeoAI.tools")
      tools.execute("edit_file",
        { file_path = dir .. "/f.txt", mode = "write", content = "edited\n", description = "t" }, {})
        :then_(function()
          -- 模拟 overlay 不可用（降级 / 嵌套 userns 无 overlay）
          local saved_avail, saved_writable = runtime.overlay_available, runtime.overlay_writable
          runtime.overlay_available = function() return false end
          runtime.overlay_writable = function() return false end
          local ok, err, ctx = nil, nil, {}
          tools.execute("run_command", { command = "cat f.txt", description = "t" }, ctx)
            :then_(function() ok = true end, function(e) err = e end)
          t.true_(vim.wait(15000, function() return ok or err end), "命令应返回")
          runtime.overlay_available, runtime.overlay_writable = saved_avail, saved_writable
          t.true_(err ~= nil, "无 overlay 且有暂存时应拒绝命令（不降级）")
          -- 真实原因（overlay/暂存分裂）仅对用户可见，模型可见文案中性（不暴露沙箱状态）。
          t.true_(not tostring(err and err.message):find("SANDBOX", 1, true), "模型可见错误不应暴露沙箱原因")
          t.matches("SANDBOX_STAGING_UNCOVERED", tostring(ctx.ui_notice), "真实原因应仅在 UI 提示中")
          done = true
        end, function(e)
          t.true_(false, "edit_file 不应失败: " .. tostring(e and e.message or e))
          done = true
        end)
      t.true_(vim.wait(20000, function() return done end), "应完成")
    end)
    vim.fn.chdir(prev)
    sandbox.reset()
    vim.fn.delete(dir, "rf")
  end)

  it("沙箱不可见：run_command 反映暂存的新建与删除", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local runtime = require("NeoAI.sandbox.execution.runtime")
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
        file_path = dir .. "/new.txt", mode = "write", content = "created\n", description = "t",
      }, {}):then_(function()
        return tools.execute("delete_file", { file_path = dir .. "/del.txt", description = "t" }, {})
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
    local runtime = require("NeoAI.sandbox.execution.runtime")
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
          return tools.execute("read_file", { file_path = target, description = "t" }, {})
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
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local control = require("NeoAI.sandbox.execution.control")
    local store = require("NeoAI.sandbox.state.store")
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

  it("沙箱会话：轮换前等待在途后台后处理（避免 merge 暂存未写完被误判删除）", function(t)
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local wrapper = require("NeoAI.sandbox.execution.wrapper")
    local async = require("NeoAI.utils.async")
    with_config({ tools = { sandbox = { workspace_root = vim.fn.tempname() .. "/sb" } } }, function()
      sandbox.reset()
      candidate.begin_session()
      -- 模拟在途后处理（merge 暂存写入未完成）：注册一个待 resolve 的 Deferred。
      local def = async.Deferred.new()
      wrapper._set_postprocess_pending(def)
      local resolved = false
      vim.defer_fn(function() resolved = true; def:resolve(true) end, 60)
      candidate.rotate_session()
      t.true_(resolved, "轮换应等待在途后处理完成（否则暂存副本会被误判删除并物化成 whiteout）")
      wrapper._reset_postprocess()
      sandbox.reset()
    end)
  end)

  it("沙箱会话：目录暂存跨轮换保留为目录（不被误判删除）", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local control = require("NeoAI.sandbox.execution.control")
    local store = require("NeoAI.sandbox.state.store")
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
        file_path = dir, mode = "write", content = "oops\n", description = "t",
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
      require("NeoAI.tools").execute("create_directory", { file_path = newdir, description = "t" }, {}):then_(function()
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
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local control = require("NeoAI.sandbox.execution.control")
    local store = require("NeoAI.sandbox.state.store")
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
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local control = require("NeoAI.sandbox.execution.control")
    local store = require("NeoAI.sandbox.state.store")
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

end)
