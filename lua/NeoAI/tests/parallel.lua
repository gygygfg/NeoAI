--- NeoAI 并行测试运行器
--- @module NeoAI.tests.parallel
--- 把全部测试套件按均衡策略分片到多个隔离 headless 子进程并发执行，聚合 passed/failed/errors。
---
--- 为什么按「文件（套件）」分片：各测试文件固定监听端口互不重复、文件内固定临时路径仅自用，
--- 文件级分片天然无跨进程冲突；每个 worker 是独立 nvim，互不共享注册表/沙箱/会话状态。
---
--- 分片权重优先采用历史实测耗时（`.neoai_test_timings.json`），无缓存时按用例数估算，
--- 采用 LPT 贪心使各 worker 负载尽量均衡。子进程统一注入独立 `mcp.cache_path` 避免争用。

local tests = require("NeoAI.tests")

local M = {}

-- ========== 配置常量 ==========

local DEFAULT_MAX_WORKERS = 8
local DEFAULT_TIMEOUT_MS = 900000 -- 单分片 15 分钟
local DEFAULT_DISCOVERY_TIMEOUT_MS = 120000
local TIMINGS_FILE = ".neoai_test_timings.json"

-- 默认视为「资源重/时序敏感、需串行」的套件名模式：sandbox* 启动 bwrap/unshare/cgroup 与常驻
-- 进程，并发会互相争抢内存/CPU（137/SIGKILL、超时）；pty 依赖 PTY 交互时序，并发下易 flaky。
-- 这些套件单独串行执行，其余并行。
local SERIAL_PATTERNS = { "^sandbox", "^pty$" }

-- ========== 私有状态 ==========

local spawner = nil -- 可注入的子进程执行器：fn(req, opts)；测试用
local active_jobs = {} -- job_id -> pid（在跑 worker，供超时/退出时做进程树清理）
local leave_registered = false -- VimLeavePre 兜底钩子是否已登记

-- ========== 私有工具函数 ==========

--- 结束某 worker 及其整个进程树（底层委托 tests._kill_proc_tree 复用同一实现）。
--- @param job number
--- @param immediate boolean|nil
local function _kill_tree(job, immediate)
  local pid = active_jobs[job]
  active_jobs[job] = nil
  if tests._kill_proc_tree then
    tests._kill_proc_tree(job, pid, immediate)
  else
    pcall(vim.fn.jobstop, job)
  end
end

--- 登记 VimLeavePre 兜底钩子（幂等）：父 nvim 退出时强杀所有在跑 worker 的进程树。
local function _install_leave_hook()
  if leave_registered then return end
  leave_registered = true
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("NeoAITestWorkersLeave", { clear = true }),
    callback = function()
      for job in pairs(active_jobs) do
        pcall(_kill_tree, job, true)
      end
    end,
    desc = "NeoAI: 结束遗留的并行测试 worker 进程树",
  })
end

-- ========== 私有工具函数 ==========

--- 本机 CPU 数（用于默认 worker 数）
--- @return number
local function _cpu_count()
  local ok, cpus = pcall(vim.uv.cpus)
  if ok and type(cpus) == "table" and #cpus > 0 then
    return #cpus
  end
  local out = vim.fn.system("nproc")
  local n = tonumber((out or ""):match("%d+"))
  return n or 4
end

--- 解析 worker 数：opts.workers > NEOAI_TEST_WORKERS > min(nproc, 8)
--- @param opts table
--- @return number
local function _resolve_workers(opts)
  local n = tonumber(opts and opts.workers)
  if not n or n < 1 then
    n = tonumber(vim.env.NEOAI_TEST_WORKERS)
  end
  if not n or n < 1 then
    n = math.min(_cpu_count(), DEFAULT_MAX_WORKERS)
  end
  return math.max(1, math.floor(n))
end

--- 耗时缓存文件路径（默认仓库根，CI 可跨运行复用）
--- @param opts table
--- @return string
local function _timings_path(opts)
  if opts and opts.timings_path then return opts.timings_path end
  local root = tests._plugin_root()
  if root then return root .. "/" .. TIMINGS_FILE end
  return vim.fn.stdpath("cache") .. "/NeoAI_test_timings.json"
end

--- 读取耗时缓存
--- @param path string
--- @return table name -> ms
local function _load_timings(path)
  local f = io.open(path, "r")
  if not f then return {} end
  local content = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" then return {} end
  local out = {}
  for k, v in pairs(data) do
    if type(k) == "string" and tonumber(v) then out[k] = tonumber(v) end
  end
  return out
end

--- 写入耗时缓存（四舍五入为整数毫秒）
--- @param path string
--- @param timings table name -> ms
local function _save_timings(path, timings)
  local out = {}
  for k, v in pairs(timings or {}) do
    if type(k) == "string" and tonumber(v) then out[k] = math.floor(tonumber(v) + 0.5) end
  end
  local ok, encoded = pcall(vim.json.encode, out)
  if not ok then return end
  local f = io.open(path, "w")
  if not f then return end
  f:write(encoded)
  f:close()
end

--- 解析子进程输出中的套件耗时行：`TIMING <name> <ms>`
--- @param output string|nil
--- @return table name -> ms
local function _parse_timings(output)
  local out = {}
  for name, ms in (output or ""):gmatch("TIMING (%S+) ([%d%.]+)") do
    out[name] = tonumber(ms)
  end
  return out
end

--- 解析清单子进程输出：`SUITE <name> <cases>` 与 `LOADFAIL:: <msg>`
--- @param output string|nil
--- @return table[] suites, string[] load_errors
local function _parse_manifest(output)
  local suites = {}
  for name, cases in (output or ""):gmatch("SUITE (%S+) (%d+)") do
    suites[#suites + 1] = { name = name, cases = tonumber(cases) or 0 }
  end
  local load_errors = {}
  for msg in (output or ""):gmatch("LOADFAIL:: ([^\n]*)") do
    load_errors[#load_errors + 1] = msg
  end
  return suites, load_errors
end

--- 判断套件是否走串行通道（资源重）。
--- @param name string
--- @param opts table
--- @return boolean
local function _is_serial(name, opts)
  local pats = opts.serial_suites
  if pats == nil then pats = SERIAL_PATTERNS end
  if type(pats) == "function" then return pats(name) == true end
  for _, pat in ipairs(pats) do
    if tostring(name):find(pat) then return true end
  end
  return false
end

-- ========== 子进程执行器 ==========

--- 写入临时子进程脚本
--- @param content string
--- @return string|nil
local function _write_script(content)
  local path = vim.fn.tempname() .. "_neoai_test_parallel.lua"
  local f = io.open(path, "w")
  if not f then return nil end
  f:write(content)
  f:close()
  return path
end

--- 默认执行器：jobstart 异步运行，退出/超时后回调 opts.on_done(res)
--- @param req table { script = string }
--- @param opts table { on_done = fun(res), timeout_ms? = number }
local function _default_spawn(req, opts)
  local root = tests._plugin_root()
  if not root then
    opts.on_done(tests._parse_child_output("", "无法定位插件根目录（tests/init.lua 路径异常）", -1))
    return
  end
  local script_path = _write_script(req.script)
  if not script_path then
    opts.on_done(tests._parse_child_output("", "无法写入测试脚本", -1))
    return
  end
  local cmd = tests._child_cmd(root, script_path)
  local stdout, stderr = {}, {}
  local done = false
  local timer = nil
  local job = nil
  local function finish(code)
    if done then return end
    done = true
    if job then active_jobs[job] = nil end
    if timer then
      pcall(function() timer:stop(); timer:close() end)
      timer = nil
    end
    pcall(os.remove, script_path)
    opts.on_done(tests._parse_child_output(table.concat(stdout, "\n"), table.concat(stderr, "\n"), code))
  end
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
      finish(code)
    end,
  })
  if job <= 0 then
    finish(-1)
    return
  end
  active_jobs[job] = vim.fn.jobpid(job)
  _install_leave_hook()
  local timeout_ms = tonumber(opts.timeout_ms) or DEFAULT_TIMEOUT_MS
  if timeout_ms > 0 then
    timer = vim.uv.new_timer()
    if timer then
      timer:start(timeout_ms, 0, function()
        if done then return end
        -- 超时：结束整个进程树（含脱离 job 进程组的沙箱常驻/PTY 后代），
        -- worker 收到 SIGTERM 后自清插件再退出（见 _isolated_script 注入的 SIGTERM 处理器）。
        _kill_tree(job)
        vim.schedule(function()
          if done then return end
          stderr[#stderr + 1] = "测试分片超时（>" .. timeout_ms .. "ms）"
          finish(-1)
        end)
      end)
    end
  end
end

--- 覆盖子进程执行器（测试用）；传 nil 恢复默认
--- @param fn function|nil
function M._set_spawner(fn)
  spawner = fn
end

--- 当前执行器解析：显式注入 > 默认
--- @return function
local function _spawner()
  return spawner or _default_spawn
end

-- ========== 分片 ==========

--- LPT 贪心分片：把套件按权重降序分配到当前负载最小的分片。
--- 纯函数，便于单测；权重单位不限（ms 或用例数均可）。
--- @param suites table[] { name, cases }
--- @param workers number
--- @param weights table|nil name -> number（缺省用 cases）
--- @return table[] bins，长度 workers，元素为套件数组
--- @return number[] loads 各分片估算负载
function M.shard(suites, workers, weights)
  workers = math.max(1, math.floor(tonumber(workers) or 1))
  weights = weights or {}
  local bins, loads = {}, {}
  for i = 1, workers do
    bins[i] = {}
    loads[i] = 0
  end
  local indexed = {}
  for _, s in ipairs(suites or {}) do
    local w = tonumber(weights[s.name]) or tonumber(s.cases) or 1
    if w <= 0 then w = 1 end
    indexed[#indexed + 1] = { suite = s, weight = w }
  end
  -- 权重降序；同权重按名字稳定排序，保证结果可复现。
  table.sort(indexed, function(a, b)
    if a.weight ~= b.weight then return a.weight > b.weight end
    return a.suite.name < b.suite.name
  end)
  for _, item in ipairs(indexed) do
    local target = 1
    for i = 2, workers do
      if loads[i] < loads[target] then target = i end
    end
    bins[target][#bins[target] + 1] = item.suite
    loads[target] = loads[target] + item.weight
  end
  -- 分片内按名字排序，便于报告稳定。
  for i = 1, workers do
    table.sort(bins[i], function(a, b) return a.name < b.name end)
  end
  return bins, loads
end

-- ========== 发现阶段 ==========

--- 在专用子进程中加载测试模块，发现套件清单（不污染当前进程）。
--- @param opts table
--- @return table { suites?, load_errors?, error? }
function M._discover(opts)
  opts = opts or {}
  local script = table.concat({
    "-- NeoAI 套件清单发现子进程（自动生成，勿手改）",
    'require("NeoAI").setup({ log = { level = "ERROR" }, session = { auto_save = false } })',
    'local suites, errs = require("NeoAI.tests").list_suites()',
    "for _, s in ipairs(suites) do",
    '  print(("SUITE %s %d"):format(s.name, s.cases))',
    "end",
    "for _, e in ipairs(errs or {}) do",
    '  io.stdout:write("LOADFAIL:: " .. tostring(e) .. "\\n")',
    "end",
  }, "\n")
  local timeout_ms = tonumber(opts.discovery_timeout_ms) or DEFAULT_DISCOVERY_TIMEOUT_MS
  local done, res = false, nil
  _spawner()({ script = script }, {
    timeout_ms = timeout_ms,
    on_done = function(r) done, res = true, r end,
  })
  if not done then
    vim.wait(timeout_ms + 5000, function() return done end, 10)
  end
  if not res then
    return { error = "套件清单发现超时" }
  end
  local suites, load_errors = _parse_manifest(res.output or "")
  if #suites == 0 then
    return { error = "未发现任何测试套件（清单为空）" }
  end
  return { suites = suites, load_errors = load_errors }
end

-- ========== 报告 ==========

--- 打印并行结果报告；有失败时附带失败分片输出。
--- @param agg table
--- @param opts table
local function _print_report(agg, opts)
  print(("\n=== NeoAI 并行测试（%d 分片 / %d worker，%.1fs） ===")
    :format(#agg.shards, agg.workers, agg.elapsed_ms / 1000))
  for i = 1, #agg.shards do
    local sh = agg.shards[i]
    if sh then
      local mark = sh.failed > 0 and "✗" or "✓"
      print(("  %s [%d] %6.1fs  %d 通过 / %d 失败  (%s)")
        :format(mark, sh.index, sh.elapsed_ms / 1000, sh.passed, sh.failed,
          table.concat(sh.names, ", ")))
    end
  end
  print(("SUMMARY passed=%d failed=%d"):format(agg.passed, agg.failed))
  if agg.failed > 0 or opts.verbose then
    for i = 1, #agg.shards do
      local sh = agg.shards[i]
      if sh and (sh.failed > 0 or not sh.produced) then
        print(("\n--- 分片 #%d 输出 ---"):format(sh.index))
        print(sh.output or "")
      end
    end
  end
end

-- ========== 主入口 ==========

--- 并行运行测试套件。
--- @param opts table|nil {
---   workers?: number,             worker 数（默认 min(nproc,8)，可用 NEOAI_TEST_WORKERS 覆盖）
---   suites?: string[],            仅运行指定套件名（默认全部）
---   timeout_ms?: number,          单分片超时（默认 15 分钟）
---   total_timeout_ms?: number,    wait=true 时总超时
---   discovery_timeout_ms?: number,
---   timings_path?: string,        耗时缓存路径
---   wait?: boolean,               是否阻塞等待（默认 true；交互式调用传 false）
---   on_done?: fun(result),        完成回调
---   verbose?: boolean,            打印所有分片输出
--- }
--- @return table { passed, failed, errors, shards, workers, elapsed_ms }
function M.run(opts)
  opts = opts or {}
  local workers = _resolve_workers(opts)
  local timeout_ms = tonumber(opts.timeout_ms) or DEFAULT_TIMEOUT_MS
  local timings_path = _timings_path(opts)
  local timings = _load_timings(timings_path)
  local t_start = vim.uv.hrtime()

  local agg = {
    passed = 0,
    failed = 0,
    errors = {},
    shards = {},
    workers = workers,
    elapsed_ms = 0,
  }

  local finished = false

  local function finish()
    finished = true
    agg.elapsed_ms = (vim.uv.hrtime() - t_start) / 1e6
    -- 合并各分片实测耗时并落盘，供下次 LPT 分片自均衡。
    for _, sh in ipairs(agg.shards) do
      for name, ms in pairs(sh.timings or {}) do
        timings[name] = ms
      end
    end
    _save_timings(timings_path, timings)
    _print_report(agg, opts)
    if opts.on_done then opts.on_done(agg) end
  end

  -- 1) 发现套件清单（专用子进程，避免污染当前进程）
  local discovery = M._discover(opts)
  if discovery.error then
    agg.failed = 1
    agg.errors[#agg.errors + 1] = discovery.error
    finish()
    return agg
  end

  local suites = discovery.suites
  if discovery.load_errors and #discovery.load_errors > 0 then
    for _, e in ipairs(discovery.load_errors) do
      agg.errors[#agg.errors + 1] = e
    end
    agg.failed = agg.failed + #discovery.load_errors
  end

  -- 2) 过滤 + 分片
  if opts.suites and #opts.suites > 0 then
    local wanted = {}
    for _, n in ipairs(opts.suites) do wanted[n] = true end
    local filtered = {}
    for _, s in ipairs(suites) do
      if wanted[s.name] then filtered[#filtered + 1] = s end
    end
    suites = filtered
  end
  if #suites == 0 then
    agg.failed = agg.failed + 1
    agg.errors[#agg.errors + 1] = "没有匹配的测试套件"
    finish()
    return agg
  end
  -- 2b) 分流：资源重的套件（默认 sandbox*）走串行通道，其余按 LPT 并行分片
  local parallel_suites, serial_suites = {}, {}
  for _, s in ipairs(suites) do
    if _is_serial(s.name, opts) then
      serial_suites[#serial_suites + 1] = s
    else
      parallel_suites[#parallel_suites + 1] = s
    end
  end
  workers = math.min(workers, math.max(1, #parallel_suites))
  agg.workers = workers
  local bins = {}
  if #parallel_suites > 0 then
    bins = M.shard(parallel_suites, workers, timings)
  end

  -- 3) 组装并行分片（去掉空档并顺延 sid，避免 agg.shards 出现空洞）
  local pending = {}
  for _, bin in ipairs(bins) do
    local names = {}
    for _, s in ipairs(bin) do names[#names + 1] = s.name end
    if #names > 0 then
      pending[#pending + 1] = { sid = #pending + 1, names = names }
    end
  end

  -- 记录一个已完成的子进程结果（并行/串行共用）
  local function record_shard(sid, names, started_ns, res)
    local ms = (vim.uv.hrtime() - started_ns) / 1e6
    local produced = (res.passed + res.failed) > 0
    local shard = {
      index = sid,
      names = names,
      passed = res.passed or 0,
      failed = res.failed or 0,
      produced = produced,
      exit_code = res.exit_code,
      elapsed_ms = ms,
      output = res.output or "",
      timings = _parse_timings(res.output),
    }
    if not produced then
      shard.failed = shard.failed + 1
      agg.errors[#agg.errors + 1] = ("分片 #%d 异常退出（code=%s）: %s")
        :format(sid, tostring(res.exit_code), table.concat(names, ","))
    end
    agg.passed = agg.passed + shard.passed
    agg.failed = agg.failed + shard.failed
    for _, e in ipairs(res.errors or {}) do agg.errors[#agg.errors + 1] = e end
    agg.shards[sid] = shard
  end

  -- 串行阶段：逐个跑资源重套件（不与其他 worker 并发，避免 137/SIGKILL 与超时）
  local serial_pos = 0
  local function start_next_serial()
    serial_pos = serial_pos + 1
    if serial_pos > #serial_suites then
      finish()
      return
    end
    local s = serial_suites[serial_pos]
    local sid = #pending + serial_pos
    local cache_path = vim.fn.tempname() .. "_neoai_mcp_cache.json"
    local script = tests._isolated_script({ s.name }, { mcp_cache_path = cache_path })
    local started = vim.uv.hrtime()
    _spawner()({ script = script, names = { s.name }, index = sid, serial = true }, {
      timeout_ms = timeout_ms,
      on_done = function(res)
        record_shard(sid, { s.name }, started, res)
        start_next_serial()
      end,
    })
  end

  local remaining = #pending
  local function after_parallel()
    if #serial_suites > 0 then
      start_next_serial()
    else
      finish()
    end
  end

  if remaining > 0 then
    for _, p in ipairs(pending) do
      local cache_path = vim.fn.tempname() .. "_neoai_mcp_cache.json"
      local script = tests._isolated_script(p.names, { mcp_cache_path = cache_path })
      local started = vim.uv.hrtime()
      _spawner()({ script = script, names = p.names, index = p.sid }, {
        timeout_ms = timeout_ms,
        on_done = function(res)
          record_shard(p.sid, p.names, started, res)
          remaining = remaining - 1
          if remaining == 0 then after_parallel() end
        end,
      })
    end
  else
    after_parallel()
  end

  if opts.wait ~= false then
    local total_timeout_ms = tonumber(opts.total_timeout_ms)
      or (timeout_ms * (#serial_suites + 1) + 120000)
    vim.wait(total_timeout_ms, function() return finished end, 20)
  end
  return agg
end

--- 结束所有在跑 worker 的进程树（父端退出/中止时兜底；幂等）。
function M._abort_all()
  for job in pairs(active_jobs) do
    pcall(_kill_tree, job, true)
  end
end

--- 重置注入状态（测试用）
function M.reset()
  spawner = nil
end

return M
