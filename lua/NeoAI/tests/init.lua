--- NeoAI 测试运行器
--- @module 'NeoAI.tests'
--- 轻量自定义测试框架（无外部依赖）。
--- 断言 API：eq/ne/true/false/nil/not_nil/matches/ok
--- 运行器：describe/it，按文件收集，headless 可跑。

local M = {}

-- ========== 测试注册表 ==========

local state = {
  suites = {}, -- { { name, tests = { { name, fn } }, before_each = fn } }
  current_suite = nil,
}

--- 定义测试套件
--- @param name string
--- @param fn function(describe, it, before_each)
function M.suite(name, fn)
  local tests = {}
  local before_each = nil
  state.current_suite = { name = name, tests = tests, before_each = before_each }
  state.suites[#state.suites + 1] = state.current_suite
  local function describe(_) end
  local function it(test_name, test_fn)
    tests[#tests + 1] = { name = test_name, fn = test_fn }
  end
  local function before_each_fn(f)
    before_each = f
    state.current_suite.before_each = f
  end
  fn(describe, it, before_each_fn)
  state.current_suite = nil
end

-- ========== 断言 ==========

local AssertError = {}
AssertError.__index = AssertError

local function _fail(msg)
  error(setmetatable({ message = msg }, AssertError), 2)
end

--- 格式化错误（提取断言消息）
local function _fmt_err(err)
  if type(err) == "table" and err.message then
    return err.message
  end
  return tostring(err)
end

local function _type_str(v)
  if v == nil then return "nil" end
  if type(v) == "table" then
    return "table: " .. vim.inspect(v)
  end
  return string.format("%q (%s)", tostring(v), type(v))
end

local assert_helpers = {}

function assert_helpers.eq(expected, actual, msg)
  if expected ~= actual then
    _fail(string.format("%s期望 %s，实际 %s", msg and (msg .. ": ") or "", _type_str(expected), _type_str(actual)))
  end
  return true
end

function assert_helpers.ne(expected, actual, msg)
  if expected == actual then
    _fail(string.format("%s不应等于 %s", msg and (msg .. ": ") or "", _type_str(actual)))
  end
  return true
end

function assert_helpers.not_eq(expected, actual, msg)
  if expected == actual then
    _fail(string.format("%s期望不相等: %s", msg and (msg .. ": ") or "", _type_str(actual)))
  end
  return true
end

function assert_helpers.true_(value, msg)
  if value ~= true then
    _fail(string.format("%s期望 true，实际 %s", msg and (msg .. ": ") or "", _type_str(value)))
  end
  return true
end

function assert_helpers.false_(value, msg)
  if value ~= false then
    _fail(string.format("%s期望 false，实际 %s", msg and (msg .. ": ") or "", _type_str(value)))
  end
  return true
end

function assert_helpers.nil_(value, msg)
  if value ~= nil then
    _fail(string.format("%s期望 nil，实际 %s", msg and (msg .. ": ") or "", _type_str(value)))
  end
  return true
end

function assert_helpers.not_nil(value, msg)
  if value == nil then
    _fail(string.format("%s期望非 nil", msg or ""))
  end
  return true
end

function assert_helpers.matches(pattern, value, msg)
  if type(value) ~= "string" or not value:match(pattern) then
    _fail(string.format("%s字符串 %s 不匹配模式 %s", msg and (msg .. ": ") or "", _type_str(value), pattern))
  end
  return true
end

function assert_helpers.ok(value, msg)
  if not value then
    _fail(string.format("%s期望为真值", msg or ""))
  end
  return true
end

function assert_helpers.deep_eq(expected, actual, msg)
  local encoded_e = vim.inspect(expected)
  local encoded_a = vim.inspect(actual)
  if encoded_e ~= encoded_a then
    _fail(string.format("%s深比较失败\n期望: %s\n实际: %s", msg and (msg .. "\n") or "", encoded_e, encoded_a))
  end
  return true
end

--- 异步等待
--- @param ms number
--- @return Deferred
function assert_helpers.sleep(ms)
  local async = require("NeoAI.utils.async")
  return async.sleep(ms)
end

--- 等待 Deferred 并传播拒绝/断言异常；异步测试也可直接 return Deferred。
function assert_helpers.await(promise, timeout_ms)
  local settled, value, failure, rejected = false, nil, nil, false
  promise:then_(function(v)
    value, settled = v, true
  end, function(err)
    failure, rejected, settled = err, true, true
  end)
  if not vim.wait(timeout_ms or 10000, function() return settled end, 10) then
    _fail("异步测试等待超时")
  end
  if rejected then error(failure, 0) end
  return value
end

--- 捕获错误
--- @param fn function
--- @return boolean, string
function assert_helpers.throws(fn)
  local ok, err = pcall(fn)
  return ok, err
end

-- ========== 运行器 ==========

local function _run_suite(suite)
  local passed, failed = 0, 0
  local errors = {}
  -- 可选按用例名过滤（子串匹配，逗号分隔多模式），便于隔离复现/跳过危险用例：
  --   NEOAI_TEST_ONLY=<p1,p2>  仅运行名字含任一模式的用例
  --   NEOAI_TEST_SKIP=<p1,p2>  跳过名字含任一模式的用例
  local only = vim.env.NEOAI_TEST_ONLY
  local skip = vim.env.NEOAI_TEST_SKIP
  local function _matches_any(patterns, name)
    for pat in (patterns or ""):gmatch("[^,]+") do
      pat = pat:gsub("^%s+", ""):gsub("%s+$", "")
      if pat ~= "" and name:find(pat, 1, true) then return true end
    end
    return false
  end
  for _, test in ipairs(suite.tests) do
    local selected = true
    if only and only ~= "" and not _matches_any(only, test.name) then selected = false end
    if skip and skip ~= "" and _matches_any(skip, test.name) then selected = false end
    if not selected then
      print("  ↷ " .. test.name)
    else
      local ok, err = xpcall(function()
        if suite.before_each then
          suite.before_each()
        end
        local t = {}
        for k, v in pairs(assert_helpers) do t[k] = v end
        local result = test.fn(t)
        if type(result) == "table" and type(result.then_) == "function" then
          assert_helpers.await(result)
        end
      end, debug.traceback)
      if ok then
        passed = passed + 1
        print(("  ✓ %s"):format(test.name))
      else
        failed = failed + 1
        local err_str = _fmt_err(err)
        errors[#errors + 1] = ("%s :: %s\n%s"):format(suite.name, test.name, err_str)
        print(("  ✗ %s\n    %s"):format(test.name, err_str:gsub("\n", "\n    ")))
      end
    end
  end
  return passed, failed, errors
end

-- ========== 测试环境准备 ==========

--- 安装测试默认配置覆盖，返回恢复函数。
--- 测试默认以 root 运行载荷（run_as.uid=0，显式放弃降权）以保持既有行为：
--- 测试环境通常以 root 运行且工作区文件归 root，非 root 载荷无法写入。非 root 场景的
--- 专项用例自行传入 tools.sandbox.run_as 覆盖。
--- @return function restore 恢复原始 config_store.load
local function _install_test_defaults()
  local config_store = require("NeoAI.kernel.config_store")
  local orig_config_load = config_store.load
  ---@diagnostic disable-next-line: duplicate-set-field
  config_store.load = function(user_config)
    local uc = vim.deepcopy(user_config or {})
    uc.tools = uc.tools or {}
    uc.tools.sandbox = uc.tools.sandbox or {}
    if uc.tools.sandbox.run_as == nil then
      uc.tools.sandbox.run_as = { uid = 0, gid = 0 }
    end
    -- 测试默认关闭内核级观测（eBPF/strace/procfs）：避免每个进程工具都挂 bpftrace，
    -- 保持离线可复现与速度。观测专项用例自行覆盖 tools.sandbox.observe。
    if uc.tools.sandbox.observe == nil then
      uc.tools.sandbox.observe = { enabled = false }
    end
    -- 测试默认同步后处理（进程命令结果在捕获/冻结/结算完成后返回），保持既有断言确定性；
    -- 异步后处理专项用例显式覆盖 tools.sandbox.postprocess="async" 并用 wrapper.await_postprocess 等待。
    if uc.tools.sandbox.postprocess == nil then
      uc.tools.sandbox.postprocess = "sync"
    end
    -- 测试默认关闭嵌套真实 systemd --user：启动较慢且非测试目标（专项用例自行覆盖）。
    uc.tools.sandbox.systemd = uc.tools.sandbox.systemd or {}
    uc.tools.sandbox.systemd.user = uc.tools.sandbox.systemd.user or {}
    if uc.tools.sandbox.systemd.user.enabled == nil then
      uc.tools.sandbox.systemd.user.enabled = false
    end
    -- 测试默认关闭交互式 run_command（默认产品为开启）：PTY 执行会改变普通命令的
    -- 终端语义并旁路常驻沙箱，绝大多数用例以非交互路径为准；交互功能由 test_pty 显式开启覆盖。
    uc.tools.run_command = uc.tools.run_command or {}
    uc.tools.run_command.interactive = uc.tools.run_command.interactive or {}
    if uc.tools.run_command.interactive.enabled == nil then
      uc.tools.run_command.interactive.enabled = false
    end
    -- 测试默认关闭 fuse-overlayfs 整机根兜底：在嵌套容器/VM 上 FUSE 挂载 `/` 会卡死内核并
    -- 触发硬件看门狗整机复位。测试需要的是「overlay 不可用 → bind+seed 降级」行为，不应做
    -- 真实 FUSE 挂载。专项用例可显式覆盖 tools.sandbox.fuse_root_overlay。
    if uc.tools.sandbox.fuse_root_overlay == nil then
      uc.tools.sandbox.fuse_root_overlay = false
    end
    -- 测试默认关闭 Herder 自动安装：测试进程常运行在真实 Herdr pane 内（HERDR_ENV=1），
    -- 否则插件启动会异步把展示增强片段写入用户真实的 ~/.config/herdr/config.toml；
    -- 并行/隔离子进程各自启动一次 → 表现为「nvim 重复安装 herder 配置」的副作用。
    -- herder_install / herder 专项用例需要时显式开启 auto_install。
    uc.herder = uc.herder or {}
    if uc.herder.auto_install == nil then
      uc.herder.auto_install = false
    end
    return orig_config_load(uc)
  end
  pcall(function()
    local cur = config_store.get_all()
    if cur then
      cur.tools = cur.tools or {}
      cur.tools.sandbox = cur.tools.sandbox or {}
      cur.tools.sandbox.run_as = { uid = 0, gid = 0 }
      cur.tools.sandbox.observe = cur.tools.sandbox.observe or { enabled = false }
      cur.tools.sandbox.postprocess = cur.tools.sandbox.postprocess or "sync"
      cur.tools.sandbox.systemd = cur.tools.sandbox.systemd or {}
      cur.tools.sandbox.systemd.user = cur.tools.sandbox.systemd.user or {}
      if cur.tools.sandbox.systemd.user.enabled == nil then
        cur.tools.sandbox.systemd.user.enabled = false
      end
      cur.tools.run_command = cur.tools.run_command or {}
      cur.tools.run_command.interactive = cur.tools.run_command.interactive or {}
      if cur.tools.run_command.interactive.enabled == nil then
        cur.tools.run_command.interactive.enabled = false
      end
      if cur.tools.sandbox.fuse_root_overlay == nil then
        cur.tools.sandbox.fuse_root_overlay = false
      end
      cur.herder = cur.herder or {}
      -- 当前（已合并）配置里默认值为 true，必须强制关闭（不代表用户显式开启）；
      -- 需要自动安装的用例通过 config_store.load({ herder = { auto_install = true } }) 显式开启。
      cur.herder.auto_install = false
      orig_config_load(cur)
    end
  end)
  return function() config_store.load = orig_config_load end
end

--- 动态加载所有 test_*.lua 文件（幂等；require 缓存）。
--- @param all_errors table 收集加载失败消息
--- @return number 加载失败的模块数
local function _load_test_modules(all_errors)
  local src = debug.getinfo(1, "S").source
  local test_dir = src:match("^@(.+)[/\\][^/\\]+$")
  if not test_dir then
    test_dir = "/root/NeoAI/lua/NeoAI/tests"
  end
  local files = vim.fn.glob(test_dir .. "/test_*.lua", false, true)
  local load_failed = 0
  for _, file in ipairs(files) do
    local mod_name = "NeoAI.tests." .. vim.fn.fnamemodify(file, ":t:r")
    if vim.fn.fnamemodify(file, ":t") ~= "init.lua" then
      local suite_count = #state.suites
      local ok, err = pcall(require, mod_name)
      if not ok then
        -- 模块中途抛错时撤销已注册的半成品套件。
        while #state.suites > suite_count do table.remove(state.suites) end
        state.current_suite = nil
        local message = ("加载测试模块 %s 失败: %s"):format(mod_name, tostring(err))
        all_errors[#all_errors + 1] = message
        print("  ✗ " .. message)
        load_failed = load_failed + 1
      end
    end
  end
  return load_failed
end

--- 仅加载测试模块并返回套件清单（不执行用例）。
--- 供并行运行器在专用进程中发现分片单元；返回 [{ name, cases }]。
--- @return table[] 套件数组 { name = string, cases = number }
--- @return table 加载错误列表
function M.list_suites()
  local all_errors = {}
  local restore_defaults = _install_test_defaults()
  local session_store = require("NeoAI.core.session.session_store")
  local real_sessions = {}
  for id, s in pairs(session_store.get_all()) do
    real_sessions[id] = s
  end
  local dir = vim.fn.tempname() .. "-NeoAI-discover"
  local prev = session_store.set_default_path_redirect(dir)
  _load_test_modules(all_errors)
  session_store.set_default_path_redirect(prev)
  session_store.restore(real_sessions)
  vim.fn.delete(dir, "rf")
  restore_defaults()
  local out = {}
  for _, suite in ipairs(state.suites) do
    out[#out + 1] = { name = suite.name, cases = #suite.tests }
  end
  return out, all_errors
end

--- 运行指定套件
--- @param ... string 套件名（可选；空则全部）
--- @return table { passed, failed, errors }
function M.run_all(...)
  local requested = { ... }
  local total_passed, total_failed = 0, 0
  local all_errors = {}

  local restore_defaults = _install_test_defaults()

  -- 会话隔离：防止测试把会话写入真实历史（~/.cache/nvim/NeoAI/sessions.jsonl）。
  -- 测试期间把“默认路径”会话重定向到临时目录，结束后清理并恢复内存中的真实会话。
  -- 每个套件使用独立临时目录：否则前一套件残留的默认路径会话会被后续套件 init()
  -- 重新载入，造成跨套件污染（如 chat_ui 残留影响 tree_ui）。
  local session_store = require("NeoAI.core.session.session_store")
  local real_sessions = {}
  for id, s in pairs(session_store.get_all()) do
    real_sessions[id] = s
  end
  local test_session_dir = vim.fn.tempname() .. "-NeoAI-test"
  local previous_redirect = session_store.set_default_path_redirect(test_session_dir)
  local suite_dirs = {}

  local function _cleanup()
    session_store.set_default_path_redirect(previous_redirect)
    session_store.restore(real_sessions)
    vim.fn.delete(test_session_dir, "rf") -- 清理临时会话目录
    for _, dir in ipairs(suite_dirs) do
      vim.fn.delete(dir, "rf")
    end
  end

  -- 动态加载所有 test_*.lua 文件（幂等）
  total_failed = total_failed + _load_test_modules(all_errors)

  local suites_to_run = {}
  if #requested > 0 then
    for _, name in ipairs(requested) do
      local found = false
      for _, suite in ipairs(state.suites) do
        if suite.name == name then
          found = true
          suites_to_run[#suites_to_run + 1] = suite
        end
      end
      if not found then
        total_failed = total_failed + 1
        all_errors[#all_errors + 1] = "未找到测试套件: " .. name
      end
    end
  else
    suites_to_run = state.suites
  end

  -- 懒加载：默认 setup 只登记占位，这里显式完成两阶段启动，
  -- 保证各套件依赖的服务/工具就绪（与旧行为一致）。
  pcall(function() require("NeoAI").ensure_started_sync(180000) end)

  local ok_run, run_err = xpcall(function()
    print(string.format("\n=== NeoAI 测试 (%d 套件) ===", #suites_to_run))
    for _, suite in ipairs(suites_to_run) do
      print("▶ " .. suite.name)
      -- 每个套件独立重定向目录 + 清空内存会话，杜绝跨套件残留。
      local suite_dir = vim.fn.tempname() .. "-NeoAI-suite"
      suite_dirs[#suite_dirs + 1] = suite_dir
      session_store.set_default_path_redirect(suite_dir)
      session_store.reset()
      -- 每个套件前恢复到一个干净的完整环境，杜绝跨套件污染：
      --   1) 配置重置为测试默认（某些套件直接 config_store.load 改 providers/tools 后未恢复）；
      --   2) 重新启动被 stop_all 的插件（幂等，无操作时几乎零开销）；
      --   3) 重建工具注册表（某些套件 registry.reset 后未恢复，会掏空后续套件的工具集）。
      pcall(function()
        require("NeoAI.kernel.config_store").load({})
        require("NeoAI.kernel.plugins").start_all()
      end)
      pcall(function() require("NeoAI.tools").reload_tools() end)
      local suite_t0 = vim.uv.hrtime()
      local p, f, errs = _run_suite(suite)
      local suite_ms = (vim.uv.hrtime() - suite_t0) / 1e6
      print(("TIMING %s %.1f"):format(suite.name, suite_ms))
      total_passed = total_passed + p
      total_failed = total_failed + f
      for _, e in ipairs(errs) do all_errors[#all_errors + 1] = e end
    end
  end, debug.traceback)
  if not ok_run then
    all_errors[#all_errors + 1] = tostring(run_err)
    total_failed = total_failed + 1
  end

  local ok_cleanup, cleanup_err = pcall(_cleanup)
  restore_defaults()
  if not ok_cleanup then
    all_errors[#all_errors + 1] = "测试清理失败: " .. tostring(cleanup_err)
    total_failed = total_failed + 1
  end

  print(string.format("\n=== 结果: %d 通过, %d 失败 ===", total_passed, total_failed))
  return { passed = total_passed, failed = total_failed, errors = all_errors }
end

-- ========== 隔离子进程运行 ==========
--
-- 为什么隔离：本套件大量用例会直接改写全局运行态（`registry.reset()` / `plugins.stop_all()`
-- / `sandbox.shutdown()` / `config_store.load` 等），而运行器没有 after_each 恢复；若在用户
-- 正在使用的 nvim 进程内运行，会把线上插件宿主/工具注册表清空，且 `NeoAI.is_fully_started()`
-- 仍为 true，懒加载门禁不会重新注册工具 —— 表现为后续请求（如 run_command）工具集为空。
-- 因此 `:NeoAITest` 一律在全新 headless 子进程中运行，绝不触碰当前进程状态。

--- 子进程预置脚本（注入套件名）
--- @param names table 套件名数组
--- @param opts table|nil { mcp_cache_path?: string } 可选：为子进程注入独立 MCP 缓存路径，
---        避免并行 worker 争用同一 `mcp.cache_path`。
--- @return string
function M._isolated_script(names, opts)
  opts = opts or {}
  local quoted = {}
  for _, n in ipairs(names or {}) do
    quoted[#quoted + 1] = string.format("%q", tostring(n))
  end
  local setup = 'require("NeoAI").setup({ log = { level = "ERROR" }, session = { auto_save = false }'
  if opts.mcp_cache_path then
    setup = setup .. ', mcp = { cache_path = ' .. string.format("%q", tostring(opts.mcp_cache_path)) .. " }"
  end
  setup = setup .. " })"
  return table.concat({
    "-- NeoAI 隔离测试子进程（自动生成，勿手改）",
    setup,
    "local names = {" .. table.concat(quoted, ", ") .. "}",
    "-- SIGTERM 兜底：父进程超时/中止（jobstop）时，nvim 在信号下不执行 VimLeavePre，",
    "-- 需显式自清插件（关闭沙箱常驻/PTY 等后代），否则脱离父进程组的后代被 init 收养而残留。",
    "do",
    "  local ok_sig, sig = pcall(vim.uv.new_signal)",
    "  if ok_sig and sig then",
    "    pcall(function()",
    "      sig:start('sigterm', function()",
    "        pcall(function() require('NeoAI.kernel.plugins').stop_all() end)",
    "        pcall(function() io.stdout:flush() end)",
    "        pcall(function() io.stderr:flush() end)",
    "        os.exit(0)",
    "      end)",
    "    end)",
    "  end",
    "end",
    'local r = require("NeoAI.tests").run_all(unpack(names))',
    'print(("SUMMARY passed=%d failed=%d"):format(r.passed, r.failed))',
    "for _, e in ipairs(r.errors or {}) do",
    '  io.stdout:write("ERROR:: " .. tostring(e) .. "\\n")',
    "end",
  }, "\n")
end

--- 定位插件根目录（含 lua/ 的仓库根）；失败返回 nil
--- @return string|nil
function M._plugin_root()
  local src = debug.getinfo(1, "S").source or ""
  local path = src:match("^@(.+)$") or src
  return path:match("^(.*)[/\\]lua[/\\]NeoAI[/\\]tests[/\\]init%.lua$")
end

--- 构造子进程 argv
--- @param root string 插件根目录
--- @param script_path string 预置脚本路径
--- @return table
function M._child_cmd(root, script_path)
  local prog = (vim.v.progpath ~= "" and vim.v.progpath) or "nvim"
  return {
    prog, "--headless", "--clean", "-u", "NONE",
    "--cmd", "set rtp+=" .. root,
    "-c", "luafile " .. vim.fn.fnameescape(script_path),
    "-c", "qa!",
  }
end

--- 解析子进程输出为结果表
--- @param stdout string
--- @param stderr string
--- @param code number|nil
--- @return table { ok, exit_code, passed, failed, errors, output }
function M._parse_child_output(stdout, stderr, code)
  stdout = stdout or ""
  stderr = stderr or ""
  local output = stdout
  if stderr ~= "" then output = output .. "\n" .. stderr end
  -- 按合并流解析：headless nvim 的 print 在部分构建落到 stderr，只扫 stdout 会漏。
  local passed, failed = 0, 0
  for p, f in output:gmatch("SUMMARY passed=(%d+) failed=(%d+)") do
    passed, failed = tonumber(p) or 0, tonumber(f) or 0
  end
  local errors = {}
  for e in output:gmatch("ERROR:: ([^\n]*)") do
    errors[#errors + 1] = e
  end
  return {
    ok = code == 0 and (passed + failed) > 0,
    exit_code = code,
    passed = passed,
    failed = failed,
    errors = errors,
    output = output,
  }
end

-- ========== 子进程进程树清理（超时/中止/退出兜底） ==========
-- 为什么要进程树：worker 内起的沙箱常驻 bwrap / PTY 会话经 --new-session/detach 进入独立
-- 会话，不再是 job 的直系子进程；jobstop 只杀直系进程，脱离父进程组的后代会被 init 收养而
-- 残留。这里按 /proc 父子关系回溯整棵树并强杀。

local active_jobs = {} -- job_id -> pid（在跑子进程，供超时/退出清理）
local leave_registered = false -- VimLeavePre 兜底钩子是否已登记

--- pid 是否存活
--- @param pid number|nil
--- @return boolean
function M._pid_alive(pid)
  if not pid then return false end
  local ok, res = pcall(vim.uv.kill, pid, 0)
  return ok and res ~= nil and res ~= false
end

--- 某 pid 的直接子进程（扫 /proc/<pid>/status 的 PPid 匹配）
--- @param pid number|nil
--- @return number[]
local function _children_of(pid)
  local out = {}
  if not pid then return out end
  local ok, scan = pcall(vim.uv.fs_scandir, "/proc")
  if not ok or not scan then return out end
  while true do
    local name = vim.uv.fs_scandir_next(scan)
    if not name then break end
    local cpid = tonumber(name)
    if cpid then
      local f = io.open("/proc/" .. cpid .. "/status", "r")
      if f then
        local ppid
        for line in f:lines() do
          local p = line:match("^PPid:%s*(%d+)")
          if p then ppid = tonumber(p) break end
        end
        f:close()
        if ppid == pid then out[#out + 1] = cpid end
      end
    end
  end
  return out
end

--- 递归收集某 pid 的全部后代（set：pid -> true）
--- @param pid number|nil
--- @return table<number, boolean>
function M._descendants(pid)
  local res = {}
  if not pid then return res end
  local stack = _children_of(pid)
  while #stack > 0 do
    local p = table.remove(stack)
    if p and not res[p] then
      res[p] = true
      for _, c in ipairs(_children_of(p)) do stack[#stack + 1] = c end
    end
  end
  return res
end

--- 结束某 job/pid 的整个进程树。
--- 顺序：先捕获后代（jobstop 后父子关系可能丢失）→ jobstop（SIGTERM，令 worker 自清）
--- →（非 immediate）宽限 500ms → 对 pid 与后代补 SIGKILL（回收脱离 job 进程组的后代）。
--- @param job number
--- @param pid number|nil
--- @param immediate boolean|nil 为 true 时跳过宽限立即强杀（VimLeavePre 下定时器不触发）
function M._kill_proc_tree(job, pid, immediate)
  local desc = pid and M._descendants(pid) or {}
  pcall(vim.fn.jobstop, job)
  local function hard_kill()
    if M._pid_alive(pid) then pcall(vim.uv.kill, pid, 9) end
    for dpid in pairs(desc) do
      if M._pid_alive(dpid) then pcall(vim.uv.kill, dpid, 9) end
    end
  end
  if immediate then
    hard_kill()
    return
  end
  local timer = vim.uv.new_timer()
  if not timer then
    hard_kill()
    return
  end
  timer:start(500, 0, function()
    timer:stop()
    timer:close()
    hard_kill()
  end)
end

--- 结束某在跑 job 的进程树（查 registry 拿 pid）
--- @param job number
--- @param immediate boolean|nil
function M._kill_job(job, immediate)
  M._kill_proc_tree(job, active_jobs[job], immediate)
end

--- 登记 VimLeavePre 兜底钩子（幂等）：父 nvim 退出时强杀所有在跑子进程树。
local function _install_leave_hook()
  if leave_registered then return end
  leave_registered = true
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("NeoAITestChildLeave", { clear = true }),
    callback = function()
      for job in pairs(active_jobs) do
        pcall(M._kill_proc_tree, job, active_jobs[job], true)
      end
    end,
    desc = "NeoAI: 结束遗留的隔离测试子进程树",
  })
end

--- 登记在跑子进程（供超时与退出兜底清理）
--- @param job number
function M._track_job(job)
  if job and job > 0 then
    active_jobs[job] = vim.fn.jobpid(job)
    _install_leave_hook()
  end
end

--- 注销在跑子进程
--- @param job number
function M._untrack_job(job)
  if job then active_jobs[job] = nil end
end

--- 结束本模块当前所有在跑子进程树（父端退出兜底；幂等）
function M._abort_all()
  for job in pairs(active_jobs) do
    pcall(M._kill_proc_tree, job, active_jobs[job], true)
    active_jobs[job] = nil
  end
end

--- 测试可注入的子进程执行器：fn(cmd, script_path, opts)；须调用 opts.on_done(result)。
local test_spawner = nil

--- 覆盖子进程执行器（测试用）；传 nil 恢复默认
--- @param fn function|nil
function M._set_child_spawner(fn)
  test_spawner = fn
end

--- 默认子进程执行器：jobstart 异步运行，退出后回调（带超时终止）
--- @param cmd table argv
--- @param opts table { on_done, timeout_ms? }
local function _default_child_spawn(cmd, _, opts)
  local stdout, stderr = {}, {}
  local done = false
  local timer = nil
  local job = nil
  job = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if not data then return end
      for _, line in ipairs(data) do
        if line ~= "" then stdout[#stdout + 1] = line end
      end
    end,
    on_stderr = function(_, data)
      if not data then return end
      for _, line in ipairs(data) do
        if line ~= "" then stderr[#stderr + 1] = line end
      end
    end,
    on_exit = function(_, code)
      if done then return end
      done = true
      M._untrack_job(job)
      if timer then pcall(function() timer:stop(); timer:close() end) timer = nil end
      local res = M._parse_child_output(table.concat(stdout, "\n"), table.concat(stderr, "\n"), code)
      opts.on_done(res)
    end,
  })
  if job <= 0 then
    local res = M._parse_child_output("", "无法启动测试子进程（jobstart 失败）", -1)
    opts.on_done(res)
    return
  end
  M._track_job(job)
  local timeout_ms = tonumber(opts.timeout_ms) or 900000
  if timeout_ms > 0 then
    timer = vim.uv.new_timer()
    if timer then
      timer:start(timeout_ms, 0, function()
        if done then return end
        -- 超时：结束整个进程树（worker 收 SIGTERM 后自清插件再退出）。
        M._kill_job(job)
        -- jobstop 触发 on_exit；若未触发则兜底回调
        vim.schedule(function()
          if done then return end
          done = true
          M._untrack_job(job)
          opts.on_done(M._parse_child_output(table.concat(stdout, "\n"), table.concat(stderr, "\n") .. "\n测试超时", -1))
        end)
      end)
    end
  end
end

--- 在隔离子进程中运行测试套件（异步；不触碰当前进程状态）
--- @param names table 套件名数组（空 = 全部）
--- @param opts? { on_done?: fun(result: table), timeout_ms?: number }
function M.run_isolated(names, opts)
  opts = opts or {}
  local on_done = opts.on_done or function() end
  local root = M._plugin_root()
  if not root then
    on_done(M._parse_child_output("", "无法定位插件根目录（tests/init.lua 路径异常）", -1))
    return
  end
  local script_path = vim.fn.tempname() .. "_neoai_test_child.lua"
  local f = io.open(script_path, "w")
  if not f then
    on_done(M._parse_child_output("", "无法写入测试脚本: " .. script_path, -1))
    return
  end
  f:write(M._isolated_script(names or {}))
  f:close()

  local cmd = M._child_cmd(root, script_path)
  local finished = false
  local function finish(res)
    if finished then return end
    finished = true
    pcall(os.remove, script_path)
    on_done(res)
  end
  local runner = test_spawner or _default_child_spawn
  local ok, err = pcall(runner, cmd, script_path, { on_done = finish, timeout_ms = opts.timeout_ms })
  if not ok then
    finish(M._parse_child_output("", "测试子进程执行异常: " .. tostring(err), -1))
  end
end

--- 重置（测试用）
function M.reset()
  state.suites = {}
  state.current_suite = nil
end

return M
