--- NeoAI 并行测试运行器（薄门面）
--- @module 'NeoAI.tests.parallel'
--- 把全部测试套件按「双 lane 有界并发」策略分派到多个隔离 headless 子进程执行，聚合结果。
---
--- 为什么按「文件（套件）」分片：各测试文件固定监听端口互不重复、文件内固定临时路径仅自用，
--- 文件级分片天然无跨进程冲突；每个 worker 是独立 nvim，互不共享注册表/沙箱/会话状态。
---
--- 两条 lane（重叠执行，任一子进程结束即回填）：
---   * light：非资源重套件，按历史实测耗时 LPT 分片成 W 个进程（多套件/进程）；
---   * heavy：资源重/时序敏感套件（sandbox*/pty），一套件一子进程，受 heavy 并发上限 H 约束，
---     按耗时降序 LPT 排队。约束 #light≤W、#heavy≤H、W+H≤核数。
---
--- 职责拆分到 `NeoAI.tests.runner.*` 子模块：
---   config（常量/并发解析）、timings（耗时缓存）、shard（LPT/清单解析）、
---   spawn（子进程执行：输出落盘 + sidecar）、scheduler（有界并发池）、report（聚合与报告）。
--- 本文件保留对外签名与语义：run/shard/_discover/_set_spawner/reset/_abort_all。

local tests = require("NeoAI.tests")
local config = require("NeoAI.tests.runner.config")
local timings_mod = require("NeoAI.tests.runner.timings")
local shard_mod = require("NeoAI.tests.runner.shard")
local spawn = require("NeoAI.tests.runner.spawn")
local scheduler = require("NeoAI.tests.runner.scheduler")
local report = require("NeoAI.tests.runner.report")

local M = {}

local DEFAULT_TIMEOUT_MS = config.DEFAULT_TIMEOUT_MS
local DEFAULT_DISCOVERY_TIMEOUT_MS = config.DEFAULT_DISCOVERY_TIMEOUT_MS

-- ========== 分片 ==========

--- LPT 贪心分片（委托 runner.shard，保持对外签名）。
--- @param suites table[] { name, cases }
--- @param workers number
--- @param weights table|nil name -> number（缺省用 cases）
--- @return table[] bins
--- @return number[] loads
function M.shard(suites, workers, weights)
  return shard_mod.shard(suites, workers, weights)
end

-- ========== 发现阶段 ==========

--- 在专用子进程中加载测试模块，发现套件清单（不污染当前进程）。
--- 清单含 name→module 映射，供 worker 按分片只加载本分片文件。
--- @param opts table
--- @return table { suites?, load_errors?, error? }
function M._discover(opts)
  opts = opts or {}
  local script = table.concat({
    "-- NeoAI 套件清单发现子进程（自动生成，勿手改）",
    'require("NeoAI").setup({ log = { level = "ERROR" }, session = { auto_save = false } })',
    'local suites, errs = require("NeoAI.tests").list_suites()',
    "for _, s in ipairs(suites) do",
    '  print(("SUITE %s %d %s"):format(s.name, s.cases, s.module or ""))',
    "end",
    "for _, e in ipairs(errs or {}) do",
    '  io.stdout:write("LOADFAIL:: " .. tostring(e) .. "\\n")',
    "end",
  }, "\n")
  local timeout_ms = tonumber(opts.discovery_timeout_ms) or DEFAULT_DISCOVERY_TIMEOUT_MS
  local done, res = false, nil
  local log_path = vim.fn.tempname() .. "_neoai_discover.log"
  spawn.get()({ script = script, log_path = log_path }, {
    timeout_ms = timeout_ms,
    on_done = function(r) done, res = true, r end,
  })
  if not done then
    vim.wait(timeout_ms + 5000, function() return done end, 10)
  end
  if not res then
    return { error = "套件清单发现超时" }
  end
  -- 清单：优先用输出；若执行器已把输出落盘（默认路径），懒读日志。
  local output = res.output
  if (not output or output == "") and res.log_path then
    output = report.read_tail(res.log_path, 100000, 8 * 1024 * 1024) or ""
  end
  local suites, load_errors = shard_mod.parse_manifest(output or "")
  if #suites == 0 then
    return { error = "未发现任何测试套件（清单为空）" }
  end
  return { suites = suites, load_errors = load_errors }
end

-- ========== 主入口 ==========

--- 组装一个执行单元（lane 项）的子进程请求。
--- @param unit table { sid, kind, names, modules }
--- @param timeout_ms number
--- @return table
local function _make_req(unit, timeout_ms)
  local cache_path = vim.fn.tempname() .. "_neoai_mcp_cache.json"
  local result_path = vim.fn.tempname() .. ("_neoai_result_%d.json"):format(unit.sid)
  local log_path = vim.fn.tempname() .. ("_neoai_shard_%d.log"):format(unit.sid)
  local script = tests._isolated_script(unit.names, {
    mcp_cache_path = cache_path,
    modules = unit.modules,
    result_path = result_path,
  })
  return {
    script = script,
    names = unit.names,
    index = unit.sid,
    kind = unit.kind,
    serial = unit.kind == "heavy",
    timeout_ms = timeout_ms,
    result_path = result_path,
    log_path = log_path,
  }
end

--- 并行运行测试套件。
--- @param opts table|nil {
---   workers?: number,             light 通道 worker 数（默认 min(nproc,8)，NEOAI_TEST_WORKERS 覆盖）
---   heavy_workers?: number,       heavy 通道并发上限（默认 2，NEOAI_TEST_HEAVY_WORKERS 覆盖；=1 回退串行）
---   suites?: string[],            仅运行指定套件名（默认全部）
---   timeout_ms?: number,          单分片超时（默认 15 分钟）
---   total_timeout_ms?: number,    wait=true 时总超时
---   discovery_timeout_ms?: number,
---   timings_path?: string,        耗时缓存路径
---   serial_suites?: table|function, 覆盖 heavy 判定（模式数组或判定函数）
---   wait?: boolean,               是否阻塞等待（默认 true；交互式调用传 false）
---   on_done?: fun(result),        完成回调
---   verbose?: boolean,            打印所有分片输出
--- }
--- @return table { passed, failed, errors, shards, workers, heavy_workers, elapsed_ms }
function M.run(opts)
  opts = opts or {}
  local timeout_ms = tonumber(opts.timeout_ms) or DEFAULT_TIMEOUT_MS
  local timings_path = timings_mod.path(opts)
  local timings = timings_mod.load(timings_path)
  local t_start = vim.uv.hrtime()

  local agg = {
    passed = 0,
    failed = 0,
    errors = {},
    shards = {},
    workers = 0,
    heavy_workers = 0,
    elapsed_ms = 0,
  }
  local finished = false

  local function finish()
    if finished then return end
    finished = true
    agg.elapsed_ms = (vim.uv.hrtime() - t_start) / 1e6
    -- 合并各分片实测耗时并落盘，供下次 LPT 分片自均衡。
    for _, sh in pairs(agg.shards) do
      for name, ms in pairs(sh.timings or {}) do
        timings[name] = ms
      end
    end
    timings_mod.save(timings_path, timings)
    report.print(agg, opts)
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

  -- 2) 过滤
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

  -- 3) 分道：heavy（资源重）vs light
  local light, heavy = {}, {}
  for _, s in ipairs(suites) do
    if config.is_serial(s.name, opts) then
      heavy[#heavy + 1] = s
    else
      light[#light + 1] = s
    end
  end

  -- 4) 并发解析：light W，heavy H（W+H≤核数），并以单元数钳制
  local light_workers = math.min(config.resolve_workers(opts), math.max(1, #light))
  if #light == 0 then light_workers = 0 end
  local heavy_workers = config.resolve_heavy_workers(opts, math.max(1, light_workers))
  if #heavy > 0 then
    heavy_workers = math.min(heavy_workers, #heavy)
  else
    heavy_workers = 0
  end
  agg.workers = light_workers
  agg.heavy_workers = heavy_workers

  -- 5) 组装单元：light = LPT 分片；heavy = 一套件一进程（按耗时降序排队）
  local sid = 0
  local light_units = {}
  if #light > 0 then
    local bins = shard_mod.shard(light, light_workers, timings)
    for _, bin in ipairs(bins) do
      if #bin > 0 then
        sid = sid + 1
        local names, modules = {}, {}
        for _, s in ipairs(bin) do
          names[#names + 1] = s.name
          modules[#modules + 1] = s.module
        end
        light_units[#light_units + 1] = {
          sid = sid,
          kind = "light",
          names = names,
          -- 任一缺失 module（旧清单/无映射）→ nil 表示加载全部（兼容）.
          modules = (#modules == #names) and modules or nil,
        }
      end
    end
  end
  local heavy_units = {}
  for _, s in ipairs(heavy) do
    sid = sid + 1
    heavy_units[#heavy_units + 1] = {
      sid = sid,
      kind = "heavy",
      names = { s.name },
      modules = s.module and { s.module } or nil,
    }
  end
  -- heavy 按耗时降序 LPT 排队（未知权重按用例数）
  table.sort(heavy_units, function(a, b)
    local wa = tonumber(timings[a.names[1]]) or 1
    local wb = tonumber(timings[b.names[1]]) or 1
    if wa ~= wb then return wa > wb end
    return a.names[1] < b.names[1]
  end)

  -- 6) 双 lane 有界并发执行（light 池 W 路 + heavy 池 H 路，重叠，任一结束即回填）
  local function start_unit(unit, done)
    local req = _make_req(unit, timeout_ms)
    local started = vim.uv.hrtime()
    spawn.get()(req, {
      timeout_ms = timeout_ms,
      on_done = function(res)
        report.record(agg, unit.sid, unit.names, started, res)
        done()
      end,
    })
  end

  scheduler.run_dual(light_units, heavy_units, light_workers, heavy_workers, start_unit, finish)

  if opts.wait ~= false then
    local total_timeout_ms = tonumber(opts.total_timeout_ms)
      or (timeout_ms * (heavy_workers + 1) + 120000)
    vim.wait(total_timeout_ms, function() return finished end, 20)
  end
  return agg
end

-- ========== 生命周期 / 注入 ==========

--- 覆盖子进程执行器（测试用）；传 nil 恢复默认
--- @param fn function|nil
function M._set_spawner(fn)
  spawn.set_spawner(fn)
end

--- 重置注入状态（测试用）
function M.reset()
  spawn.reset()
end

--- 结束所有在跑 worker 的进程树（父端退出/中止时兜底；幂等）。
function M._abort_all()
  spawn.abort_all()
end

return M
