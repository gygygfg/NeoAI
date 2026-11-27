--- 单视图模型（三视图）回归
--- @module 'NeoAI.tests.test_sandbox_single_view'
--- 覆盖：视图路径映射（含非覆盖根回退）、轮换不迁移、物化对视图条目零拷贝、
--- 构建产物目录不捕获、候选预算（条目/字节）、发布保留权限位、崩溃回收器、JVM 代理注入。

local tests = require("NeoAI.tests")

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

local function with_store(fn)
  with_config({
    tools = {
      sandbox = {
        workspace_root = vim.fn.tempname() .. "/sb",
        postprocess = "sync",
        observe = { enabled = false },
        single_view = true,
      },
    },
  }, fn)
end

tests.suite("sandbox_single_view", function(_, it)
  it("视图路径：可写根内映射到 upper，tmpfs 根回退旧暂存", function(t)
    local view = require("NeoAI.sandbox.execution.view")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    with_store(function()
      require("NeoAI.sandbox").reset()
      local cwd = vim.fn.tempname()
      vim.fn.mkdir(cwd .. "/target", "p")
      local prev = vim.fn.getcwd()
      vim.fn.chdir(cwd)
      local base = candidate.process_dir()
      local specs = require("NeoAI.sandbox.execution.wrapper").build_overlay_specs(cwd, base, {})
      candidate.register_view(specs)
      t.true_(view.ready(), "应登记视图可写根")
      local p = cwd .. "/app.lua"
      local mapped = view.path_for(p)
      t.not_nil(mapped, "工作区文件应映射到视图 upper")
      t.matches("/upper/", mapped, "映射路径应位于 upper")
      t.true_(view.is_native(mapped), "映射路径应被识别为视图原生")
      -- tmpfs 会话私有根不映射（命令内由私有 tmpfs 张冠，不能共享）
      t.eq(nil, view.path_for("/tmp/neoai-view-test-" .. vim.fn.getpid() .. ".txt"),
        "私有 tmpfs 根不应映射到视图")
      vim.fn.chdir(prev)
      vim.fn.delete(cwd, "rf")
    end)
  end)

  it("轮换不迁移数据：视图目录稳定、暂存内容原地保留", function(t)
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local control = require("NeoAI.sandbox.execution.control")
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    with_store(function()
      sandbox.reset()
      local dir = vim.fn.tempname()
      fs.ensure_dir(dir)
      local prev = vim.fn.getcwd()
      vim.fn.chdir(dir)
      local a = control.new_attempt("edit_file", {}, {}, { effect = "fs_write" })
      candidate.begin(a, assert(require("NeoAI.sandbox.state.store").root()))
      local p = dir .. "/note.txt"
      fs.write_file(p, "hello\n")
      local staged = candidate.stage_path(a.attempt_id, p)
      t.not_nil(staged, "应得到暂存路径")
      local before = candidate.process_dir()
      fs.write_file(staged, "staged\n")
      local old_sid = candidate.begin_session()
      local new_sid = candidate.rotate_session()
      t.true_(new_sid ~= old_sid, "轮换应推进会话 id")
      t.eq(before, candidate.process_dir(), "单视图下视图目录不随轮换变化")
      t.eq("staged\n", fs.read_file(staged) or "", "轮换后暂存内容应原地保留")
      candidate.cleanup(a.attempt_id)
      vim.fn.chdir(prev)
      vim.fn.delete(dir, "rf")
    end)
  end)

  it("物化：视图原生条目只登记签名，不做拷贝/删除", function(t)
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    with_store(function()
      sandbox.reset()
      local dir = vim.fn.tempname()
      fs.ensure_dir(dir)
      local prev = vim.fn.getcwd()
      vim.fn.chdir(dir)
      local view = require("NeoAI.sandbox.execution.view")
      local base = candidate.process_dir()
      local specs = require("NeoAI.sandbox.execution.wrapper").build_overlay_specs(dir, base, {})
      for _, s in ipairs(specs) do
        s.mode = require("NeoAI.sandbox.execution.runtime").overlay_writable(s.root, s.upper, s.work)
          and "overlay" or "bind"
      end
      candidate.register_view(specs)
      local p = dir .. "/a.txt"
      fs.write_file(p, "base\n")
      local a = require("NeoAI.sandbox.execution.control").new_attempt("edit_file", {}, {}, { effect = "fs_write" })
      candidate.begin(a, assert(require("NeoAI.sandbox.state.store").root()))
      local staged = candidate.stage_path(a.attempt_id, p)
      fs.write_file(staged, "edited\n")
      local conflicts = candidate.materialize_overlay(specs)
      t.eq(0, #conflicts, "物化不应有冲突")
      t.eq("edited\n", fs.read_file(staged) or "", "视图条目内容不应被物化改写")
      t.true_(view.is_native(staged), "暂存路径应就是视图路径")
      candidate.cleanup(a.attempt_id)
      vim.fn.chdir(prev)
      vim.fn.delete(dir, "rf")
    end)
  end)

  it("构建产物目录不进入候选（generated_dirs，含嵌套 build）", function(t)
    with_store(function()
      local runtime = require("NeoAI.sandbox.execution.runtime")
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir .. "/target", "p")
      vim.fn.mkdir(dir .. "/android/app/build", "p")
      local prev = vim.fn.getcwd()
      vim.fn.chdir(dir)
      t.true_(runtime.is_non_capture_path(dir .. "/target/x.o"), "target/ 不应捕获")
      t.true_(runtime.is_non_capture_path(dir .. "/android/app/build/out.apk"), "嵌套 build/ 不应捕获")
      t.true_(not runtime.is_non_capture_path(dir .. "/src/main.c"), "源码应捕获")
      vim.fn.chdir(prev)
      vim.fn.delete(dir, "rf")
    end)
  end)

  it("候选预算：条目数超过 capture_max_files 时截断并留证", function(t)
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local control = require("NeoAI.sandbox.execution.control")
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    with_config({
      tools = { sandbox = {
        workspace_root = vim.fn.tempname() .. "/sb", postprocess = "sync",
        observe = { enabled = false }, capture_max_files = 2, single_view = false,
      } },
    }, function()
      sandbox.reset()
      local dir = vim.fn.tempname()
      fs.ensure_dir(dir)
      local prev = vim.fn.getcwd()
      vim.fn.chdir(dir)
      local a = control.new_attempt("run_command", { command = "x" }, {}, { effect = "process" })
      candidate.begin(a, assert(require("NeoAI.sandbox.state.store").root()))
      for i = 1, 5 do
        local staged = candidate.stage_path(a.attempt_id, dir .. "/f" .. i .. ".txt")
        fs.write_file(staged, "v" .. i .. "\n")
      end
      local cand = candidate.finish(a.attempt_id)
      t.not_nil(cand, "应冻结出候选")
      t.true_(#(cand.files or {}) <= 2, "候选条目应受 capture_max_files 限制")
      candidate.cleanup(a.attempt_id)
      vim.fn.chdir(prev)
      vim.fn.delete(dir, "rf")
    end)
  end)

  it("发布保留权限位：候选未显式改权限时沿用目标 0755（不抹执行位）", function(t)
    local writer = require("NeoAI.sandbox.execution.writer")
    local fs = require("NeoAI.utils.fs")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local p = dir .. "/run.sh"
    fs.write_file(p, "#!/bin/sh\necho old\n")
    vim.uv.fs_chmod(p, 493) -- 0755
    local res = writer.apply("write", p, "#!/bin/sh\necho new\n", { mode = 420, base_mode = 420 })
    t.true_(res.ok, "写入应成功")
    t.eq(493, (vim.uv.fs_stat(p).mode % 4096), "未显式改权限时应保留 0755")
    -- 显式 chmod 候选（mode != base_mode）应生效
    local res2 = writer.apply("write", p, "#!/bin/sh\necho chmod\n", { mode = 420, base_mode = 493 })
    t.true_(res2.ok, "写入应成功")
    t.eq(420, (vim.uv.fs_stat(p).mode % 4096), "显式改权限应生效")
    vim.fn.delete(dir, "rf")
  end)

  it("崩溃回收：reap_dirs 只清超过保留期的目录（dry_run 不删）", function(t)
    local reclaim = require("NeoAI.sandbox.execution.reclaim")
    local dir = vim.fn.stdpath("cache") .. "/NeoAI/sandbox_tests_999999"
    vim.fn.mkdir(dir, "p")
    local old = os.time() - 48 * 3600
    vim.uv.fs_utime(dir, old, old)
    local res = reclaim.reap_dirs({ dry_run = true })
    local hit = false
    for _, p in ipairs(res.removed) do if p == dir then hit = true end end
    t.true_(hit, "超过保留期的测试沙箱应被列为可回收")
    t.true_(vim.fn.isdirectory(dir) == 1, "dry_run 不应真的删除")
    vim.fn.delete(dir, "rf")
  end)

  it("JVM 代理：HTTP 代理同步为 JAVA_TOOL_OPTIONS/MAVEN_OPTS 系统属性", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    with_config({ tools = { sandbox = { network = { record_only = true, java_proxy = true } } } }, function()
      local env = runtime.sandbox_env({})
      t.matches("https%.proxyHost=", tostring(env.JAVA_TOOL_OPTIONS), "应注入 JVM 代理属性")
      t.matches("https%.proxyPort=", tostring(env.JAVA_TOOL_OPTIONS), "应注入 JVM 代理端口")
    end)
    with_config({ tools = { sandbox = { network = { record_only = true, java_proxy = false } } } }, function()
      local env = runtime.sandbox_env({})
      t.true_(not tostring(env.JAVA_TOOL_OPTIONS):find("proxyHost", 1, true), "关闭时不应注入")
    end)
  end)
end)
