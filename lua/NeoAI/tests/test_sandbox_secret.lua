--- 沙箱密钥与 IO：密钥防护 token 化/存储异步/工作线程/越界留痕
--- @module 'NeoAI.tests.test_sandbox_secret'
--- 由原 test_sandbox.lua 按用例分片而来（42 个用例，彼此独立、无跨用例共享状态）。

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


tests.suite("sandbox_secret", function(_, it)
  it("密钥防护：敏感环境变量名出现只提级待审（不终止，带警告）", function(t)
    local secret = require("NeoAI.sandbox.secret.secret")
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    secret.reset()
    with_config({ tools = { sandbox = { ephemeral_roots = {} } } }, function()
    local code = 'local api_key = os.getenv("GIT_COMMIT_AI_API_KEY")\n'
    local p = vim.fn.tempname() .. ".lua"
    local ctx = {}
    local done = false
    require("NeoAI.tools").execute("edit_file", {
      file_path = p, mode = "write", content = code, description = "t",
    }, ctx):then_(function() done = true end, function() done = true end)
    t.true_(vim.wait(10000, function() return done end), "edit_file 应完成")
    t.eq(true, ctx.secret_operation, "应提级（secret_operation），而非终止")
    t.true_(vim.tbl_contains(ctx.secret_names or {}, "GIT_COMMIT_AI_API_KEY"), "应记录敏感环境变量名")
    local found
    for _, rev_item in ipairs(sandbox.list_reviews({ review_state = "PENDING" }) or {}) do
      for _, f in ipairs(rev_item.files or {}) do if f.path == p then found = rev_item end end
    end
    t.not_nil(found, "应产生待审变更单元")
    t.true_(found.secret_warning and (found.secret_warning.count or 0) > 0, "待审项应带密钥警告")
    t.true_(#(found.secret_warning.names or {}) > 0, "警告应含敏感环境变量名")
    fs.delete_file(p)
    secret.reset()
    end)
  end)

  it("密钥防护：环境变量 token 化注入可观测信号且可整体关闭", function(t)
    local secret = require("NeoAI.sandbox.secret.secret")
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

  it("密钥防护：AI 读取到 KEY 时按配置披露假密钥说明（默认不披露）", function(t)
    local secret = require("NeoAI.sandbox.secret.secret")
    local fs = require("NeoAI.utils.fs")
    secret.reset()
    local fake = "sk-Ab3xY9pQ2mNv7Kd4Lw8Zr1Tg6Hs5"
    local path = vim.fn.tempname()
    fs.write_file(path, "API_KEY=" .. fake .. "\n")
    local function read(t2)
      local done = false
      require("NeoAI.tools").execute("read_file", { file_path = path, description = "t" }, {}):then_(function(r)
        t2(tostring(r))
        done = true
      end, function(e)
        t2("ERR:" .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(5000, function() return done end), "应完成")
    end
    -- 默认不披露：结果只含假密钥，无说明
    read(function(s)
      t.true_(s:find(fake, 1, true) == nil, "不应回传真实密钥")
      t.true_(secret.has_token(s), "应回传假密钥")
      t.true_(s:find("格式保真假密钥", 1, true) == nil, "默认不应披露")
    end)
    -- 开启披露：附带说明
    with_config({ tools = { sandbox = { secrets = { disclose_fakes = true } } } }, function()
      read(function(s)
        t.matches("格式保真假密钥", s, "开启后应附加说明")
        t.matches("仅对 AI 不可见", s, "说明应含不可见语义")
        t.matches("自动替换回真实密钥", s, "说明应含自动还原语义")
      end)
    end)
    vim.fn.delete(path)
    secret.reset()
  end)

  it("运行时：expose_paths 在遮蔽之后只读暴露并前置到 PATH", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local fs = require("NeoAI.utils.fs")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    with_config({ tools = { sandbox = { expose_paths = { dir } } } }, function()
      local prefix = assert(runtime.process_prefix({ cwd = "/tmp" }))
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
    local runtime = require("NeoAI.sandbox.execution.runtime")
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
        file_path = root .. "/a.txt", mode = "write", content = "changed\n", description = "t",
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

  it("运行时：overlay 不可用时降级执行（播种真实内容，不拒绝）", function(t)
    local fs = require("NeoAI.utils.fs")
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    fs.write_file(dir .. "/real.txt", "REAL\n")
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "async" }, sandbox = {
      mode = "dry_run", review = { enabled = true }, degraded_seed = true,
    } } }, function()
      sandbox.reset()
      -- 模拟容器内 userns 限制：粗粒度能力与真实可写实测均失败。
      runtime.probe().overlayfs = false
      local saved_writable = runtime.overlay_writable
      ---@diagnostic disable-next-line: duplicate-set-field
      ---@diagnostic disable-next-line: duplicate-set-field
    runtime.overlay_writable = function() return false end
      t.false_(runtime.overlay_available(), "overlay 应被判定为不可用")
      local done, result, rejected = false, nil, nil
      local ctx = {}
      require("NeoAI.tools").execute("run_command", { command = "cat real.txt", description = "t" }, ctx)
        :then_(function(r) result = r; done = true end, function(e) rejected = e; done = true end)
      t.true_(vim.wait(15000, function() return done end), "run_command 应完成")
      runtime.overlay_writable = saved_writable
      t.nil_(rejected, "overlay 不可用时应降级执行而非拒绝: " .. tostring(rejected and rejected.message))
      t.matches("REAL", tostring(result), "播种视图应能看到真实磁盘文件")
      -- 降级/只读字样不进入模型可见结果（真实原因仅 UI）。
      t.true_(not tostring(result):find("只读", 1, true) and not tostring(result):find("降级模式", 1, true),
        "模型可见结果不应暴露只读/降级")
      t.true_(fs.exists(dir .. "/real.txt"), "真实文件不应被改动")
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
    runtime.reset()
  end)

  it("运行时：显式允许时 overlay 不可用降级为私有可写 cwd", function(t)
    local fs = require("NeoAI.utils.fs")
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    fs.write_file(dir .. "/real.txt", "REAL\n")
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "async" }, sandbox = {
      mode = "dry_run", review = { enabled = true },
      degraded_seed = false,
    } } }, function()
      sandbox.reset()
      -- 模拟容器内 userns 限制：粗粒度能力与真实可写实测均失败。
      runtime.probe().overlayfs = false
      local saved_writable = runtime.overlay_writable
      ---@diagnostic disable-next-line: duplicate-set-field
      ---@diagnostic disable-next-line: duplicate-set-field
    runtime.overlay_writable = function() return false end
      t.false_(runtime.overlay_available(), "overlay 应被判定为不可用")
      local done = false
      local ctx = {}
      require("NeoAI.tools").execute("run_command", { command = "ls", description = "t" }, ctx):then_(function(r)
        t.true_(not tostring(r):find("real.txt", 1, true), "降级 cwd 应为私有目录，不暴露真实项目文件")
        -- 降级/只读状态对模型不可见：不写入模型可见结果（成功降级执行不附加 UI 提示）。
        t.true_(not tostring(r):find("降级", 1, true), "降级字样不应写入模型可见结果")
        t.true_(fs.exists(dir .. "/real.txt"), "真实文件不应被改动")
        done = true
      end, function(e)
        t.true_(false, "显式允许降级时命令仍应可执行: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(10000, function() return done end), "run_command 应完成")
      runtime.overlay_writable = saved_writable
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
    runtime.reset()
  end)

  it("运行时：overlay 可用时普通命令不触发降级提示", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local fs = require("NeoAI.utils.fs")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local candidate = require("NeoAI.sandbox.execution.candidate")
      local wrapper = require("NeoAI.sandbox.execution.wrapper")
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
    local runtime = require("NeoAI.sandbox.execution.runtime")
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
      require("NeoAI.tools").execute("run_command", { command = "unshare -m true", description = "t" }, ctx):then_(function(r)
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
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    runtime.reset()
    runtime.probe()
    runtime.capabilities().overlayfs = true -- 模拟粗粒度探测假阳性
    local orig = runtime.overlay_writable
    ---@diagnostic disable-next-line: duplicate-set-field
    runtime.overlay_writable = function() return false end
    local prefix, err = assert(runtime.process_prefix({
      cwd = "/tmp", upper = "/tmp/neoai_ovl_u", work = "/tmp/neoai_ovl_w",
      fallback_cwd = "/tmp/neoai_ovl_f",
    }))
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
        file_path = p, mode = "write", content = "NEW\n", description = "t",
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
        ---@diagnostic disable-next-line: param-type-mismatch
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
        file_path = p, mode = "write", content = "DROP\n", description = "t",
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
    local review = require("NeoAI.sandbox.review.review")
    local store = require("NeoAI.sandbox.state.store")
    with_config({ tools = { sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local cand = {
        candidate_digest = "sha256:discardme", created_at = os.time(), effect = "fs_write",
        files = { { path = "/tmp/neoai_discard.txt", action = "create", after_hash = "h", content = "x" } },
      }
      store.write_candidate(cand)
      local item = assert(review.enqueue(cand, { tool = "run_command" }))
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
    local review = require("NeoAI.sandbox.review.review")
    local store = require("NeoAI.sandbox.state.store")
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
      local i2 = assert(review.enqueue(mk(), { id = "cs_shared_2", tool = "edit_file" }))
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
    local review = require("NeoAI.sandbox.review.review")
    local store = require("NeoAI.sandbox.state.store")
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
      local item = assert(review.enqueue(cand, { tool = "edit_file" }))
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
    local review = require("NeoAI.sandbox.review.review")
    local store = require("NeoAI.sandbox.state.store")
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
    local review = require("NeoAI.sandbox.review.review")
    local store = require("NeoAI.sandbox.state.store")
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
    local review = require("NeoAI.sandbox.review.review")
    local store = require("NeoAI.sandbox.state.store")
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
      local it1 = assert(review.enqueue(mk("sha256:pk1", "/var/lib/apt/lists/a"), meta))
      local it2 = assert(review.enqueue(mk("sha256:pk2", "/var/lib/apt/lists/b"), meta))
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
    local runtime = require("NeoAI.sandbox.execution.runtime")
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

  it("run_command：async 后处理——结果先返回，后台完成冻结/入队", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end -- overlay 仅 bwrap 后端
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    with_config({ tools = { approval = { mode = "auto_allow" },
      sandbox = { mode = "dry_run", review = { enabled = true }, postprocess = "async" } } }, function()
      sandbox.reset()
      local done, result = false, nil
      require("NeoAI.tools").execute("run_command",
        { command = "echo hi > made.txt", description = "t" }, {})
        :then_(function(r) result = r; done = true end, function(e) result = e; done = true end)
      t.true_(vim.wait(15000, function() return done end), "run_command 应返回结果")
      t.not_nil(result, "应先返回结果（不等后处理）")
      -- 结果返回后立即读取命令创建的文件：read 工具应等待后台合并完成，看到一致视图。
      local rd, rv = false, nil
      require("NeoAI.tools").execute("read_file",
        { file_path = dir .. "/made.txt", description = "r" }, {})
        :then_(function(r) rv = tostring(r); rd = true end,
          function(e) rv = "ERR:" .. tostring(e and e.message or e); rd = true end)
      t.true_(vim.wait(60000, function() return rd end), "read_file 应完成")
      t.matches("hi", rv or "", "read 应看到命令创建的文件内容")
      -- 后台后处理（捕获/冻结/合并/入队）应最终完成
      t.true_(sandbox.await_postprocess(30000), "后台后处理应完成")
      local items = sandbox.list_reviews({ review_state = "PENDING" })
      t.eq(1, #items, "后台应完成冻结并产生待审候选")
      t.matches("made.txt", items[1].write_set[1] or "", "待审应含命令创建的文件")
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
  end)

  it("run_command：只读命令不重复捕获已暂存编辑（不取代/回滚）", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local runtime = require("NeoAI.sandbox.execution.runtime")
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
          { file_path = dir .. "/a.txt", description = "t", mode = "write", content = "changed\n" }, {}):then_(ok, err)
      end)
      run("read-only run_command", function(ok, err)
        require("NeoAI.tools").execute("run_command",
          { command = "ls -la; cat a.txt >/dev/null", description = "t" }, {}):then_(ok, err)
      end)
      local items = sandbox.list_reviews({ review_state = "PENDING" })
      t.eq(1, #items, "只读命令不应额外产生候选")
      t.eq("edit_file", items[1].tool, "待审项应仍为 edit_file 候选（未被只读命令取代）")
      local staged = assert(candidate.read_path(dir .. "/a.txt"))
      t.not_nil(staged, "暂存副本应仍存在")
      t.matches("changed", fs.read_file(staged) or "", "暂存内容应保留编辑结果（未被回滚）")
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
  end)

  it("捕获：物化后未改动的暂存文件不产生候选（工作线程跳过、主线程不逐文件读）", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local control = require("NeoAI.sandbox.execution.control")
    local store = require("NeoAI.sandbox.state.store")
    local dir = fs.canonical(vim.fn.tempname())
    with_config({ tools = { sandbox = { workspace_root = vim.fn.tempname() .. "/sb" } } }, function()
      sandbox.reset()
      fs.ensure_dir(dir)
      local a = control.new_attempt("run_command", {}, {}, { effect = "process" })
      candidate.begin(a, assert(store.root()))
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
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local control = require("NeoAI.sandbox.execution.control")
    local store = require("NeoAI.sandbox.state.store")
    local config_store = require("NeoAI.kernel.config_store")
    local dir = fs.canonical(vim.fn.tempname())
    with_config({ tools = { sandbox = { workspace_root = vim.fn.tempname() .. "/sb" } } }, function()
      sandbox.reset()
      fs.ensure_dir(dir)
      local function build()
        local a = control.new_attempt("edit_file", {}, {}, { effect = "fs_write" })
        candidate.begin(a, assert(store.root()))
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

  it("冻结：剔除有效遮蔽与易变包缓存文件（避免整单元发布失败）", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local control = require("NeoAI.sandbox.execution.control")
    local store = require("NeoAI.sandbox.state.store")
    local dir = fs.canonical(vim.fn.tempname())
    fs.ensure_dir(dir)
    local masked = dir .. "/masked.env"
    local unmasked = dir .. "/allowed.env"
    local volatile_dir = dir .. "/apt/lists"
    fs.ensure_dir(volatile_dir)
    local volatile_file = volatile_dir .. "/Packages"
    local normal = dir .. "/normal.txt"
    with_config({
      tools = { sandbox = {
        workspace_root = vim.fn.tempname() .. "/sb",
        mask_paths = { masked, unmasked },
        packages = { volatile_paths = { volatile_dir } },
      } },
    }, function()
      sandbox.reset()
      local a = control.new_attempt("run_command", {}, {}, { effect = "process" })
      a.package = true
      a.effective_unmask = { unmasked }
      candidate.begin(a, assert(store.root()))
      local function stage(p, content)
        local staged = candidate.stage_path(a.attempt_id, p)
        fs.write_file(staged, content)
      end
      stage(masked, "secret\n")
      stage(unmasked, "allowed\n")
      stage(volatile_file, "index\n")
      stage(normal, "ok\n")
      local cand = candidate.finish(a.attempt_id)
      local paths = {}
      for _, f in ipairs(cand.files) do paths[f.path] = true end
      t.nil_(paths[masked], "遮蔽文件应被剔除")
      t.nil_(paths[volatile_file], "易变包缓存应被剔除")
      t.not_nil(paths[normal], "普通文件应保留")
      t.not_nil(paths[unmasked], "被 unmask 放行的遮蔽文件应保留")
      t.not_nil(cand.dropped, "应记录剔除信息")
      t.eq(1, cand.dropped.masked, "应记录剔除的遮蔽文件数")
      t.eq(1, cand.dropped.volatile, "应记录剔除的易变缓存数")
      candidate.cleanup(a.attempt_id)
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("物化：未改动的暂存文件重复物化跳过写入（不重读/重写）", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local control = require("NeoAI.sandbox.execution.control")
    local store = require("NeoAI.sandbox.state.store")
    local dir = fs.canonical(vim.fn.tempname())
    with_config({ tools = { sandbox = { workspace_root = vim.fn.tempname() .. "/sb" } } }, function()
      sandbox.reset()
      fs.ensure_dir(dir)
      local a = control.new_attempt("run_command", {}, {}, { effect = "process" })
      candidate.begin(a, assert(store.root()))
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
      ---@diagnostic disable-next-line: duplicate-set-field
      fs.write_file_atomic = function(...) calls = calls + 1; return orig(...) end
      candidate.materialize_overlay(specs)
      fs.write_file_atomic = orig
      t.eq(0, calls, "未改动文件重复物化不应重写")
      -- 改动一个暂存文件后应只重写该文件（经 stage_path 模拟真实编辑：递增暂存版本）
      local staged = candidate.stage_path(a.attempt_id, dir .. "/f1.txt")
      fs.write_file(staged, "staged 1 v2\n")
      local orig2 = fs.write_file_atomic
      local calls2 = 0
      ---@diagnostic disable-next-line: duplicate-set-field
      fs.write_file_atomic = function(...) calls2 = calls2 + 1; return orig2(...) end
      candidate.materialize_overlay(specs)
      fs.write_file_atomic = orig2
      t.eq(1, calls2, "仅改动的暂存文件应重写")
      candidate.cleanup(a.attempt_id)
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("物化：未改动项重复物化不 fs_stat（按暂存版本跳过，避免暂存上万文件时主线程卡顿）", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local control = require("NeoAI.sandbox.execution.control")
    local store = require("NeoAI.sandbox.state.store")
    with_config({ tools = { sandbox = { workspace_root = vim.fn.tempname() .. "/sb" } } }, function()
      sandbox.reset()
      local dir = fs.canonical(vim.fn.tempname())
      fs.ensure_dir(dir)
      local a = control.new_attempt("run_command", {}, {}, { effect = "process" })
      candidate.begin(a, assert(store.root()))
      local files = {}
      for i = 1, 20 do
        local p = dir .. "/f" .. i .. ".txt"
        fs.write_file(p, "base " .. i .. "\n")
        files[#files + 1] = {
          path = p, action = "modify", content = "staged " .. i .. "\n",
          before_hash = "sha256:b" .. i, after_hash = "sha256:s" .. i, mode = 420,
        }
      end
      candidate.merge_candidate({ files = files })
      local base = vim.fn.tempname()
      local upper, work = base .. "/upper", base .. "/work"
      fs.ensure_dir(upper); fs.ensure_dir(work)
      local specs = { { root = dir, upper = upper, work = work, mode = "overlay" } }
      candidate.materialize_overlay(specs) -- 冷：写入全部
      -- 热：版本全部未变，应完全跳过——不 stat/读/写任何暂存或目标文件。
      local orig_stat = vim.uv.fs_stat
      local stat_calls = 0
      vim.uv.fs_stat = function(...) stat_calls = stat_calls + 1; return orig_stat(...) end
      candidate.materialize_overlay(specs)
      vim.uv.fs_stat = orig_stat
      t.eq(0, stat_calls, "未改动项重复物化不应 fs_stat（按版本跳过）")
      candidate.cleanup(a.attempt_id)
      vim.fn.delete(dir, "rf")
      vim.fn.delete(base, "rf")
    end)
  end)

  it("物化：命令捕获来源（fresh）跳过冗余回写", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local control = require("NeoAI.sandbox.execution.control")
    local store = require("NeoAI.sandbox.state.store")
    local dir = fs.canonical(vim.fn.tempname())
    with_config({ tools = { sandbox = { workspace_root = vim.fn.tempname() .. "/sb" } } }, function()
      sandbox.reset()
      fs.ensure_dir(dir)
      local a = control.new_attempt("run_command", {}, {}, { effect = "process" })
      candidate.begin(a, assert(store.root()))
      local base = vim.fn.tempname()
      local upper, work = base .. "/upper", base .. "/work"
      fs.ensure_dir(upper); fs.ensure_dir(work)
      -- 命令把内容写进 overlay dest，capture 冻结候选，merge 登记暂存并标记 fresh
      fs.write_file(upper .. "/f.txt", "cmd content\n")
      local cand = {
        candidate_digest = "sha256:fresh1",
        files = { {
          path = dir .. "/f.txt", action = "create", content = "cmd content\n",
          after_hash = "sha256:x", mode = 420,
        } },
      }
      candidate.merge_candidate(cand, { from_command = true })
      local specs = { { root = dir, upper = upper, work = work, mode = "overlay" } }
      local orig = fs.write_file_atomic
      local calls = 0
      ---@diagnostic disable-next-line: duplicate-set-field
      fs.write_file_atomic = function(...) calls = calls + 1; return orig(...) end
      candidate.materialize_overlay(specs)
      candidate.materialize_overlay(specs)
      fs.write_file_atomic = orig
      t.eq(0, calls, "fresh 条目不应被 detokenize 回写 overlay")
      -- 暂存副本被编辑（经 stage_path，版本变化）后应恢复回写
      local staged = candidate.stage_path(a.attempt_id, dir .. "/f.txt")
      fs.write_file(staged, "edited\n")
      local orig2 = fs.write_file_atomic
      local calls2 = 0
      ---@diagnostic disable-next-line: duplicate-set-field
      fs.write_file_atomic = function(...) calls2 = calls2 + 1; return orig2(...) end
      candidate.materialize_overlay(specs)
      fs.write_file_atomic = orig2
      t.eq(1, calls2, "暂存副本被编辑后应回写 overlay")
      candidate.cleanup(a.attempt_id)
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("包/生成内容：merge 跳过密钥 token 化", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local control = require("NeoAI.sandbox.execution.control")
    local store = require("NeoAI.sandbox.state.store")
    local dir = fs.canonical(vim.fn.tempname())
    with_config({ tools = { sandbox = { workspace_root = vim.fn.tempname() .. "/sb" } } }, function()
      sandbox.reset()
      fs.ensure_dir(dir)
      local secret_text = "AWS_ACCESS_KEY=AKIAIOSFODNN7EXAMPLE\n"
      local a1 = control.new_attempt("run_command", {}, {}, { effect = "process" })
      candidate.begin(a1, assert(store.root()))
      candidate.merge_candidate({
        files = { { path = dir .. "/a.txt", action = "create", content = secret_text, mode = 420 } },
      })
      t.true_(require("NeoAI.sandbox.secret.secret").has_token(fs.read_file(assert(candidate.read_path(dir .. "/a.txt"))) or ""),
        "非包内容应假化")
      candidate.cleanup(a1.attempt_id)
      local a2 = control.new_attempt("run_command", {}, {}, { effect = "process" })
      candidate.begin(a2, assert(store.root()))
      candidate.merge_candidate({
        files = { { path = dir .. "/b.txt", action = "create", content = secret_text, mode = 420 } },
      }, { package = true })
      t.eq(secret_text, fs.read_file(assert(candidate.read_path(dir .. "/b.txt"))) or "",
        "包内容不应 token 化（与结算阶段跳过密钥检测一致）")
      candidate.cleanup(a2.attempt_id)
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("二进制内容：merge/stage 不做密钥 token 化（不当文本处理）", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local control = require("NeoAI.sandbox.execution.control")
    local store = require("NeoAI.sandbox.state.store")
    local dir = fs.canonical(vim.fn.tempname())
    with_config({ tools = { sandbox = { workspace_root = vim.fn.tempname() .. "/sb" } } }, function()
      sandbox.reset()
      fs.ensure_dir(dir)
      -- 含 NUL 与非法 UTF-8 的二进制（模拟 OpenPGP keyring）
      local bin = "\x99\x01\x0d\x04\x63\x17\x2e\xcf\x98\x1f\x06\x7d\xff\xfe\x00\x80"
      local a = control.new_attempt("run_command", {}, {}, { effect = "process" })
      candidate.begin(a, assert(store.root()))
      candidate.merge_candidate({
        files = { { path = dir .. "/key.gpg", action = "create", content = bin, mode = 420 } },
      })
      t.eq(bin, fs.read_file(assert(candidate.read_path(dir .. "/key.gpg"))) or "",
        "二进制内容不应被 token 化（逐字节保留）")
      candidate.cleanup(a.attempt_id)
      -- stage_path（_base_entry）同样跳过 token 化
      local real = dir .. "/real.gpg"
      fs.write_file(real, bin)
      local a2 = control.new_attempt("edit_file", {}, {}, { effect = "fs_write" })
      candidate.begin(a2, assert(store.root()))
      local staged = assert(candidate.stage_path(a2.attempt_id, real))
      t.eq(bin, fs.read_file(staged) or "", "stage 的二进制副本应逐字节一致")
      candidate.cleanup(a2.attempt_id)
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("merge_candidate_async：写后回传签名使 fresh 跳过物化回写", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local control = require("NeoAI.sandbox.execution.control")
    local store = require("NeoAI.sandbox.state.store")
    local dir = fs.canonical(vim.fn.tempname())
    with_config({ tools = { sandbox = { workspace_root = vim.fn.tempname() .. "/sb" } } }, function()
      sandbox.reset()
      fs.ensure_dir(dir)
      local a = control.new_attempt("run_command", {}, {}, { effect = "process" })
      candidate.begin(a, assert(store.root()))
      local base = vim.fn.tempname()
      local upper, work = base .. "/upper", base .. "/work"
      fs.ensure_dir(upper); fs.ensure_dir(work)
      local cand = {
        candidate_digest = "sha256:asyncfresh",
        files = { { path = dir .. "/f.txt", action = "create", content = "cmd content\n", mode = 420 } },
      }
      local ok, err = pcall(function()
        t.await(candidate.merge_candidate_async(cand, { from_command = true }))
      end)
      if not ok then error(err, 0) end
      -- 模拟 capture 已把命令内容写入 overlay dest：fresh 标记应使物化跳过回写。
      fs.write_file(upper .. "/f.txt", "cmd content\n")
      local specs = { { root = dir, upper = upper, work = work, mode = "overlay" } }
      local orig = fs.write_file_atomic
      local calls = 0
      ---@diagnostic disable-next-line: duplicate-set-field
      fs.write_file_atomic = function(...) calls = calls + 1; return orig(...) end
      candidate.materialize_overlay(specs)
      fs.write_file_atomic = orig
      t.eq(0, calls, "fresh_ssig 正确时物化不应回写 overlay")
      candidate.cleanup(a.attempt_id)
      vim.fn.delete(base, "rf")
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("merge_candidate_async：分块写入（work_chunk_files<文件数）内容完整且 fresh 签名可用", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local control = require("NeoAI.sandbox.execution.control")
    local store = require("NeoAI.sandbox.state.store")
    local config_store = require("NeoAI.kernel.config_store")
    local dir = fs.canonical(vim.fn.tempname())
    with_config({ tools = { sandbox = { workspace_root = vim.fn.tempname() .. "/sb" } } }, function()
      sandbox.reset()
      local saved_chunk = config_store.get("tools.sandbox.work_chunk_files")
      -- 强制分块：文件数 > chunk，覆盖跨块签名聚合与目录创建。
      config_store.set("tools.sandbox.work_chunk_files", 2)
      fs.ensure_dir(dir)
      local a = control.new_attempt("run_command", {}, {}, { effect = "process" })
      candidate.begin(a, assert(store.root()))
      local base = vim.fn.tempname()
      local upper, work = base .. "/upper", base .. "/work"
      fs.ensure_dir(upper); fs.ensure_dir(work)
      local N = 7
      local files = {}
      for i = 1, N do
        files[#files + 1] = {
          path = dir .. "/d" .. i .. "/nested/f" .. i .. ".txt",
          action = "create", content = "content " .. i .. "\n", mode = 420,
        }
      end
      local cand = { candidate_digest = "sha256:chunkmerge", files = files }
      local ok, err = pcall(function()
        t.await(candidate.merge_candidate_async(cand, { from_command = true }))
      end)
      if not ok then error(err, 0) end
      -- 跨块写入的每个文件都应落到暂存且内容完整（目录需已递归创建）。
      for i = 1, N do
        local staged = assert(candidate.read_path(files[i].path))
        t.not_nil(staged, "应可解析暂存路径: " .. files[i].path)
        t.eq("content " .. i .. "\n", fs.read_file(staged) or "", "分块写入内容应完整")
      end
      -- 模拟命令已把相同内容写入 overlay：跨块回传的 fresh 签名应使物化跳过全部回写。
      for i = 1, N do
        local rel = files[i].path:sub(#dir + 2)
        fs.ensure_dir(vim.fn.fnamemodify(upper .. "/" .. rel, ":h"))
        fs.write_file(upper .. "/" .. rel, "content " .. i .. "\n")
      end
      local specs = { { root = dir, upper = upper, work = work, mode = "overlay" } }
      local orig = fs.write_file_atomic
      local calls = 0
      ---@diagnostic disable-next-line: duplicate-set-field
      fs.write_file_atomic = function(...) calls = calls + 1; return orig(...) end
      candidate.materialize_overlay(specs)
      fs.write_file_atomic = orig
      t.eq(0, calls, "跨块回传的 fresh_ssig 应覆盖全部文件（物化不回写）")
      candidate.cleanup(a.attempt_id)
      config_store.set("tools.sandbox.work_chunk_files", saved_chunk or 128)
      vim.fn.delete(base, "rf")
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("待审项落盘剥离文件内容（避免重复编码大候选）", function(t)
    local sandbox = require("NeoAI.sandbox")
    local review = require("NeoAI.sandbox.review.review")
    local store = require("NeoAI.sandbox.state.store")
    with_config({ tools = { sandbox = { workspace_root = vim.fn.tempname() .. "/sb" } } }, function()
      sandbox.reset()
      local cand = {
        candidate_digest = "sha256:persist1",
        files = { { path = "/tmp/x.txt", action = "create", content = "hello world", mode = 420 } },
      }
      store.write_candidate(cand)
      local item = assert(review.enqueue(cand, { tool = "run_command" }))
      t.not_nil(item, "应入队")
      -- 内存条目同样剥离 content（否则暂存大量文件时内存翻倍）；按需经 content_for 读取。
      t.nil_(item.files[1].content, "内存项也应剥离内容")
      t.eq("hello world", review.content_for(item.change_set_id, "/tmp/x.txt"), "应可按需读取内容")
      local on_disk = assert(store.read_review(item.change_set_id))
      t.not_nil(on_disk, "应可读回")
      t.nil_(on_disk.files[1].content, "落盘项不应含内容")
    end)
  end)

  it("run_command：输出超上限时截断并终止（防大输出冻结）", function(t)
    local tools = require("NeoAI.tools")
    local config_store = require("NeoAI.kernel.config_store")
    local saved = config_store.get("tools.run_command.max_output_bytes")
    config_store.set("tools.run_command.max_output_bytes", 4096)
    local err
    local ok = pcall(function()
      local done, result = false, nil
      tools.execute("run_command", { command = "seq 1 100000", description = "t" }, {}):then_(function(r)
        done = true; result = r
      end, function(e) done = true; err = e end)
      t.true_(vim.wait(30000, function() return done end), "命令应完成")
      t.true_(type(result) == "string", "应返回字符串结果")
      t.matches("截断", result, "应标注输出截断")
      t.true_(#result < 100000, "结果应被截断（不会包含全部 10 万行）")
    end)
    config_store.set("tools.run_command.max_output_bytes", saved)
    if not ok then error(err, 0) end
  end)

  it("run_command：删除冻结为 delete 候选且不删真实文件", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local runtime = require("NeoAI.sandbox.execution.runtime")
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
      t.true_(vim.wait(30000, function() return done end), "run_command 应完成")
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
  end)

  it("run_command：尝试目录被清理且无残留（overlay work 可移除）", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local runtime = require("NeoAI.sandbox.execution.runtime")
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
    local writer = require("NeoAI.sandbox.execution.writer")
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

  it("落盘：二进制内容经 writer 无损写入（不当文本处理）", function(t)
    local writer = require("NeoAI.sandbox.execution.writer")
    local fs = require("NeoAI.utils.fs")
    local dir = fs.canonical(vim.fn.tempname())
    fs.ensure_dir(dir)
    local p = dir .. "/key.gpg"
    local bin = "\x99\x01\x0d\x04\x63\x17\x2e\xff\xfe\x00\x80\xc0"
    local res = writer.apply("write", p, bin, { mode = 420 })
    t.true_(res.ok, "应写入成功")
    t.eq(bin, fs.read_file(p) or "", "二进制内容应逐字节一致（不被当文本处理）")
    fs.delete_file(p)
    vim.fn.delete(dir, "rf")
  end)

  it("run_command：命令创建的文件保留可执行位（物化/发布）", function(t)
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

  it("无 overlay（bind 视图）：命令创建的可执行位跨命令保留并发布", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    local saved_avail, saved_writable = runtime.overlay_available, runtime.overlay_writable
    ---@diagnostic disable-next-line: duplicate-set-field
    runtime.overlay_available = function() return false end
    ---@diagnostic disable-next-line: duplicate-set-field
    runtime.overlay_writable = function() return false end
    local ok, err = pcall(function()
      with_config({ tools = { approval = { mode = "async" }, sandbox = {
        mode = "dry_run", review = { enabled = true },
        staging_uncovered = "warn",
      } } }, function()
        sandbox.reset()
        local tools = require("NeoAI.tools")
        local done = false
        tools.execute("run_command", {
          command = "printf '#!/bin/sh\\necho hi\\n' > mk.sh && chmod +x mk.sh", description = "t",
        }, {}):then_(function()
          return tools.execute("run_command",
            { command = "test -x mk.sh && echo EXEC || echo NOEXEC", description = "t" }, {})
        end):then_(function(r)
          t.matches("EXEC", tostring(r), "bind 视图下命令创建的可执行脚本应保持 +x")
          for _, item in ipairs(sandbox.list_reviews({ review_state = "PENDING" })) do
            for _, f in ipairs(item.files or {}) do
              if f.path == dir .. "/mk.sh" then
                sandbox.apply(item.change_set_id, { auto_approve = true })
              end
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
    end)
    runtime.overlay_available, runtime.overlay_writable = saved_avail, saved_writable
    vim.fn.chdir(prev)
    sandbox.reset()
    vim.fn.delete(dir, "rf")
    if not ok then error(err, 0) end
  end)

  it("run_command：仅 chmod 已存在文件时保留可执行位（发布）", function(t)
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
      local function apply_all()
        for _, item in ipairs(sandbox.list_reviews({ review_state = "PENDING" })) do
          sandbox.apply(item.change_set_id, { auto_approve = true })
        end
      end
      local done = false
      tools.execute("run_command", {
        command = "printf '#!/bin/sh\\necho hi\\n' > mk.sh", description = "t",
      }, {}):then_(function()
        apply_all()
        local st = vim.uv.fs_stat(dir .. "/mk.sh")
        t.not_nil(st, "前置条件：mk.sh 应已发布")
        t.eq(420, st.mode % 512, "前置条件：发布后应为 0644")
        -- 第二条命令只改权限、不改内容：应仍产生候选并发布 +x
        return tools.execute("run_command", { command = "chmod +x mk.sh", description = "t" }, {})
      end):then_(function()
        apply_all()
        local st = vim.uv.fs_stat(dir .. "/mk.sh")
        local perm = st and (st.mode % 512) or 0
        t.true_(math.floor(perm / 64) % 2 == 1, "仅 chmod 后发布应保留可执行位（实际 perm=" .. tostring(perm) .. "）")
        done = true
      end, function(e) t.true_(false, "不应失败: " .. tostring(e and e.message or e)); done = true end)
      t.true_(vim.wait(20000, function() return done end), "run_command 应完成")
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
  end)

  it("run_command：物化后仅 chmod 未发布文件也产生权限候选", function(t)
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
      -- 第一条命令创建文件（0644）但不发布；第二条命令只 chmod +x（内容未变）。
      tools.execute("run_command", {
        command = "printf '#!/bin/sh\\necho hi\\n' > mk.sh", description = "t",
      }, {}):then_(function()
        return tools.execute("run_command", { command = "chmod +x mk.sh", description = "t" }, {})
      end):then_(function()
        local found = false
        for _, item in ipairs(sandbox.list_reviews({ review_state = "PENDING" })) do
          for _, f in ipairs(item.files or {}) do
            if f.path == dir .. "/mk.sh" and f.mode and math.floor(f.mode / 64) % 2 == 1 then found = true end
          end
        end
        t.true_(found, "未发布文件被 chmod 后应产生含可执行位的候选")
        done = true
      end, function(e) t.true_(false, "不应失败: " .. tostring(e and e.message or e)); done = true end)
      t.true_(vim.wait(20000, function() return done end), "run_command 应完成")
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
  end)

  it("密钥告警：非凭据/编辑器状态文件不计入密钥操作", function(t)
    local secret = require("NeoAI.sandbox.secret.secret")
    secret.reset()
    local tok = secret.tokenize("DASHSCOPE_API_KEY=verysecretvalue1234567890abcdef")
    t.true_(type(tok) == "string" and tok ~= "", "应产生 token 化文本")
    t.nil_(secret.warn_for_files({
      { path = "/root/.local/state/nvim/shada/main.shada", content = tok },
    }), "非凭据/编辑器状态文件不应计入密钥操作")
    t.not_nil(secret.warn_for_files({
      { path = "/root/.ssh/config", content = tok },
    }), "凭据文件应计入密钥操作")
    secret.reset()
  end)

end)
