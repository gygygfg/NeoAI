--- 资源压力自适应层
--- @module 'NeoAI.tests.test_pressure'
--- 覆盖：分级阈值边界、探测失败不误降级、TTL 缓存与 reset、simulate 强制档位。
--- 说明：所有用例都通过 `pressure._set_sampler()` 注入伪采样，绝不依赖运行测试的宿主
--- 当前内存/负载（否则低内存 CI 机会产生不可复现的随机失败）。

local tests = require("NeoAI.tests")

local MIB = 1024 * 1024

--- 构造一份伪采样（默认 1 GB 总量、900 MB 可用 → ok）
--- @param over table|nil
--- @return table
local function sample(over)
  local s = {
    mem_total_bytes = 1024 * MIB,
    mem_available_bytes = 900 * MIB,
    swap_total_bytes = 2048 * MIB,
    psi_memory_avg10 = 0,
    psi_cpu_avg10 = 0,
    load1 = 0,
    cores = 4,
  }
  for k, v in pairs(over or {}) do s[k] = v end
  return s
end

--- 在指定配置下运行 fn，结束后恢复配置并清理 pressure 缓存
--- @param overrides table
--- @param fn function
local function with_cfg(overrides, fn)
  local config_store = require("NeoAI.kernel.config_store")
  local pressure = require("NeoAI.kernel.pressure")
  local saved = config_store.get_all()
  config_store.load(overrides or {})
  pressure.reset()
  local ok, err = pcall(fn)
  pressure._set_sampler(nil)
  pressure.reset()
  config_store.load(saved)
  pressure.reset()
  if not ok then error(err, 0) end
end

tests.suite("pressure", function(_, it)
  local pressure = require("NeoAI.kernel.pressure")

  it("classify：ok / warn / critical 三级内存阈值边界", function(t)
    local cfg = {}
    -- 900 MB / 1024 MB 可用 → ok
    t.eq("ok", pressure.classify(sample(), cfg))
    -- 跌破 warn 的绝对下限（256 MB）与比例下限（15% = 153 MB）中的较高者
    t.eq("warn", pressure.classify(sample({ mem_available_bytes = 200 * MIB }), cfg))
    -- 比例优先：8 GB 机器上 1000 MB 可用（15% = 1.2 GB）仍是 warn
    t.eq("warn", pressure.classify(sample({
      mem_total_bytes = 8192 * MIB,
      mem_available_bytes = 1000 * MIB,
    }), cfg))
    -- 跌破 critical 绝对下限（96 MB）
    t.eq("critical", pressure.classify(sample({ mem_available_bytes = 90 * MIB }), cfg))
    -- 比例优先：8 GB 机器上 300 MB 可用（5% = 410 MB）已是 critical
    t.eq("critical", pressure.classify(sample({
      mem_total_bytes = 8192 * MIB,
      mem_available_bytes = 300 * MIB,
    }), cfg))
  end)

  it("classify：无 swap 时可用内存低于 8% 直接判为 critical", function(t)
    -- 8 GB 机器、500 MB 可用：有 swap 缺缓冲 → warn（未跌破 5% = 410 MB 的 critical 线）
    local base = { mem_total_bytes = 8192 * MIB, mem_available_bytes = 500 * MIB }
    t.eq("warn", pressure.classify(sample(base), {}))
    -- 同样可用内存但无 swap（8% = 655 MB）：缺缓冲会直接 OOM/抖动 → critical
    t.eq("critical", pressure.classify(sample({
      mem_total_bytes = 8192 * MIB,
      mem_available_bytes = 500 * MIB,
      swap_total_bytes = 0,
    }), {}))
    -- 无 swap 但可用内存充裕 → ok
    t.eq("ok", pressure.classify(sample({ swap_total_bytes = 0 }), {}))
  end)

  it("classify：PSI 内存停顿与每核负载触发 warn / critical", function(t)
    -- PSI 达到 critical 阈值（默认 40）
    t.eq("critical", pressure.classify(sample({ psi_memory_avg10 = 45 }), {}))
    -- PSI 达到 warn 阈值（默认 10）
    t.eq("warn", pressure.classify(sample({ psi_memory_avg10 = 12 }), {}))
    -- PSI 未达阈值 → 不影响
    t.eq("ok", pressure.classify(sample({ psi_memory_avg10 = 3 }), {}))
    -- 每核负载 ≥ 2：4 核 load1=8
    t.eq("warn", pressure.classify(sample({ load1 = 8, cores = 4 }), {}))
    t.eq("ok", pressure.classify(sample({ load1 = 7.9, cores = 4 }), {}))
  end)

  it("classify：探测不到 /proc 或无 MemTotal 时视为 ok，绝不误降级", function(t)
    t.eq("ok", pressure.classify(nil, {}))
    t.eq("ok", pressure.classify({}, {}))
    t.eq("ok", pressure.classify({ mem_total_bytes = 0, mem_available_bytes = 0 }, {}))
  end)

  it("MemAvailable 缺失时回退 MemFree + Buffers + Cached", function(t)
    t.eq(300 * MIB, pressure._meminfo_available({
      MemTotal = 1024 * MIB, MemFree = 100 * MIB, Buffers = 50 * MIB, Cached = 150 * MIB,
    }))
    -- 有 MemAvailable 时优先用它（不回退）
    t.eq(500 * MIB, pressure._meminfo_available({
      MemTotal = 1024 * MIB, MemAvailable = 500 * MIB, MemFree = 1, Buffers = 1, Cached = 1,
    }))
    -- 全缺失不报错
    t.eq(0, pressure._meminfo_available({}))
    t.eq(0, pressure._meminfo_available(nil))
  end)

  it("snapshot 按 sample_ttl_ms 缓存，不重复采样；reset 清缓存", function(t)
    local calls = 0
    with_cfg({ resources = { pressure = { enabled = true, sample_ttl_ms = 60000, notify = false } } }, function()
      pressure._set_sampler(function()
        calls = calls + 1
        return sample()
      end)
      pressure.reset()
      local first = pressure.snapshot()
      t.eq("ok", first.level)
      t.eq(1, calls, "首次 snapshot 应采样一次")
      -- TTL 内多次读取不应再次采样
      for _ = 1, 5 do pressure.level() end
      t.eq(1, calls, "TTL 内不得重复采样")
      -- reset 后重新采样
      pressure.reset()
      pressure.snapshot()
      t.eq(2, calls, "reset 后应重新采样")
    end)
  end)

  it("enabled=false 时恒为 ok、不采样、不阻止观测", function(t)
    local calls = 0
    with_cfg({ resources = { pressure = { enabled = false } } }, function()
      pressure._set_sampler(function()
        calls = calls + 1
        return sample({ mem_available_bytes = 1 * MIB })
      end)
      pressure.reset()
      t.eq("ok", pressure.level(), "关闭后不得降级")
      t.eq(0, calls, "关闭后不应采样")
      t.eq(true, pressure.observation_allowed(), "关闭后观测恒允许")
      t.eq(nil, pressure.sandbox_memory_cap(), "关闭后不封顶沙箱内存")
    end)
  end)

  it("simulate 可强制 warn / critical，无需真实施压", function(t)
    with_cfg({
      resources = { pressure = { enabled = true, sample_ttl_ms = 5, notify = false, simulate = "warn" } },
    }, function()
      pressure._set_sampler(function() return sample() end)
      pressure.reset()
      t.eq("warn", pressure.level(), "simulate=warn 应覆盖真实采样")
      t.eq(true, pressure.at_least("warn"))
      t.eq(false, pressure.at_least("critical"))
    end)
    with_cfg({
      resources = { pressure = { enabled = true, sample_ttl_ms = 5, notify = false, simulate = "critical" } },
    }, function()
      pressure._set_sampler(function() return sample() end)
      pressure.reset()
      t.eq("critical", pressure.level(), "simulate=critical 应覆盖真实采样")
      t.eq(true, pressure.at_least("warn"))
      t.eq(true, pressure.at_least("critical"))
    end)
    -- 非法值忽略，回到真实采样
    with_cfg({
      resources = { pressure = { enabled = true, sample_ttl_ms = 5, notify = false, simulate = "bogus" } },
    }, function()
      pressure._set_sampler(function() return sample() end)
      pressure.reset()
      t.eq("ok", pressure.level(), "非法 simulate 应忽略")
    end)
  end)

  it("scaled_ms 按等级放大间隔（ok ×1 / warn ×2 / critical ×4）", function(t)
    with_cfg({ resources = { pressure = { enabled = true, sample_ttl_ms = 5, notify = false } } }, function()
      pressure._set_sampler(function() return sample() end)
      pressure.reset()
      t.eq(80, pressure.scaled_ms(80), "ok 级不放大")
    end)
    with_cfg({
      resources = { pressure = { enabled = true, sample_ttl_ms = 5, notify = false, simulate = "warn" } },
    }, function()
      pressure._set_sampler(function() return sample() end)
      pressure.reset()
      t.eq(160, pressure.scaled_ms(80), "warn 级 ×2")
      t.eq(100, pressure.scaled_ms(50), "warn 级 ×2")
    end)
    with_cfg({
      resources = { pressure = { enabled = true, sample_ttl_ms = 5, notify = false, simulate = "critical" } },
    }, function()
      pressure._set_sampler(function() return sample() end)
      pressure.reset()
      t.eq(320, pressure.scaled_ms(80), "critical 级 ×4")
      -- 基线异常值被夹到 1
      t.eq(4, pressure.scaled_ms(0), "critical 级对 0 基线取 1×4")
    end)
  end)

  it("等级变化发布 RESOURCE_PRESSURE 事件，且仅首次进入 critical 提示一次", function(t)
    local events = require("NeoAI.kernel.events")
    t.eq("resource:pressure", events.RESOURCE_PRESSURE)
    local got = {}
    local un = pressure.on_change(function(level, prev) got[#got + 1] = { level = level, prev = prev } end)
    local notified = {}
    local orig_notify = vim.notify
    -- notify 经 vim.schedule 异步投递，这里替换后手动 vim.wait 冲刷
    vim.notify = function(msg, lvl) notified[#notified + 1] = { msg = msg, lvl = lvl } end
    local avail = 900 * MIB
    -- ttl=0：每次 snapshot 都重新采样，无需 reset（reset 会清掉 prev，掩盖变更检测）
    with_cfg({ resources = { pressure = { enabled = true, sample_ttl_ms = 0, notify = true } } }, function()
      pressure._set_sampler(function() return sample({ mem_available_bytes = avail }) end)
      pressure.reset()
      pressure.snapshot() -- ok（首次发布，prev=nil）
      t.eq(1, #got, "首次快照应发布一次")
      t.eq("ok", got[1].level)
      -- 进入 critical
      avail = 40 * MIB
      pressure.snapshot()
      t.eq("critical", got[#got].level, "应发布 critical 变化")
      t.eq("ok", got[#got].prev, "prev 应为 ok")
      vim.wait(300, function() return #notified > 0 end, 10)
      t.eq(1, #notified, "首次进入 critical 应提示一次")
      -- 持续 critical：不重复提示
      pressure.snapshot()
      vim.wait(100, function() return false end, 10)
      t.eq(1, #notified, "持续 critical 不应重复提示")
      -- 恢复 ok 后再进 critical：可再提示一次
      avail = 900 * MIB
      pressure.snapshot()
      t.eq("ok", got[#got].level, "应发布恢复事件")
      avail = 40 * MIB
      pressure.snapshot()
      vim.wait(300, function() return #notified > 1 end, 10)
      t.eq(2, #notified, "恢复后再次进入 critical 应再次提示")
    end)
    vim.notify = orig_notify
    un()
  end)

  it("sandbox_memory_cap：ok 不封顶，warn/critical 按可用内存折算", function(t)
    -- ok：不封顶（保留充裕环境下的全力发挥）
    with_cfg({ resources = { pressure = { enabled = true, sample_ttl_ms = 0, notify = false } } }, function()
      pressure._set_sampler(function() return sample() end)
      pressure.reset()
      t.eq(nil, pressure.sandbox_memory_cap(), "ok 级不封顶")
    end)
    -- warn：可用内存 × 0.6
    with_cfg({
      resources = {
        pressure = { enabled = true, sample_ttl_ms = 0, notify = false, simulate = "warn" },
      },
    }, function()
      pressure._set_sampler(function() return sample({ mem_available_bytes = 200 * MIB }) end)
      pressure.reset()
      local cap, lvl = pressure.sandbox_memory_cap()
      t.eq("warn", lvl)
      t.eq(math.floor(200 * MIB * 0.6), cap, "warn 级 = 可用内存 × 0.6")
    end)
    -- critical：可用内存 × 0.4
    with_cfg({
      resources = {
        pressure = { enabled = true, sample_ttl_ms = 0, notify = false, simulate = "critical" },
      },
    }, function()
      pressure._set_sampler(function() return sample({ mem_available_bytes = 200 * MIB }) end)
      pressure.reset()
      local cap = pressure.sandbox_memory_cap()
      t.eq(math.floor(200 * MIB * 0.4), cap, "critical 级 = 可用内存 × 0.4")
    end)
    -- 单点关闭：degrade.sandbox_memory=false 时永不封顶
    with_cfg({
      resources = {
        pressure = {
          enabled = true, sample_ttl_ms = 0, notify = false, simulate = "critical",
          degrade = { sandbox_memory = false },
        },
      },
    }, function()
      pressure._set_sampler(function() return sample({ mem_available_bytes = 200 * MIB }) end)
      pressure.reset()
      t.eq(nil, pressure.sandbox_memory_cap(), "单点关闭后不封顶")
    end)
  end)

  it("cgroup.resolve_limits：动态内存上限受 MemAvailable 封顶（原有 total×ratio 不再放大）", function(t)
    local cgroup = require("NeoAI.sandbox.execution.cgroup")
    if not cgroup.probe().available then return end -- 无 cgroup v2 的环境跳过
    -- ok 级：沿用 total × memory_ratio
    with_cfg({ resources = { pressure = { enabled = true, sample_ttl_ms = 0, notify = false } } }, function()
      pressure._set_sampler(function() return sample() end)
      pressure.reset()
      local lim = cgroup.resolve_limits()
      t.true_((lim.memory_bytes or 0) > 0, "ok 级仍应有内存上限")
    end)
    -- critical 级：上限被压缩到 MemAvailable × 0.4
    with_cfg({
      resources = {
        pressure = { enabled = true, sample_ttl_ms = 0, notify = false, simulate = "critical" },
      },
    }, function()
      local avail = 200 * MIB
      pressure._set_sampler(function() return sample({ mem_available_bytes = avail }) end)
      pressure.reset()
      local lim = cgroup.resolve_limits()
      local expect = math.floor(avail * 0.4)
      t.true_((lim.memory_bytes or 0) > 0, "封顶后仍应为正数（避免「不限制」）")
      t.true_(lim.memory_bytes <= expect, "critical 级 memory_bytes 应 <= MemAvailable×0.4")
    end)
  end)

  it("work.io_threads：I/O 并发下限 4，绝不退化为单线程（2 核宿主的关键回归）", function(t)
    local work = require("NeoAI.utils.work")
    local host = require("NeoAI.utils.host")
    local n = work.io_threads()
    t.true_(n >= 4, "I/O 并发不得低于 libuv 默认 4（2 核机上 core_budget 会算出 1）")
    t.true_(n <= 16, "I/O 并发上限 16，避免线程过多争抢内存与调度")
    -- 关键：与 CPU 预算解耦。CPU 预算可为 1，但 I/O 并发必须仍 >= 4。
    t.true_(host.core_budget() >= 1, "CPU 预算至少 1")
    if host.core_budget() <= 1 then
      t.true_(work.io_threads() >= 4, "CPU 预算为 1 时 I/O 并发仍须 >= 4（不得随 CPU 预算退化）")
    end
    -- parallelism 同样不得低于 2（压到 1 会让 I/O 完全串行、工具卡到超时）
    t.true_(work.parallelism() >= 2, "批并发保底 2")
  end)

  it("work.parallelism：ok=池大小、warn=⌈n/2⌉、critical=⌈n/4⌉（保底 2）", function(t)
    local work = require("NeoAI.utils.work")
    -- 即时计算基线（不预先缓存）：Android 等宿主的可在线核数会随热插拔波动，
    -- 缓存一份会在用例中途失效造成假失败。
    local function base_now()
      local n = work.io_threads()
      local pool = tonumber(vim.env.UV_THREADPOOL_SIZE)
      if pool and pool > 0 and n > pool then n = pool end
      return n
    end
    with_cfg({ resources = { pressure = { enabled = true, sample_ttl_ms = 0, notify = false } } }, function()
      pressure._set_sampler(function() return sample() end)
      pressure.reset()
      t.eq(base_now(), work.parallelism(), "ok 级不收敛")
    end)
    with_cfg({
      resources = { pressure = { enabled = true, sample_ttl_ms = 0, notify = false, simulate = "warn" } },
    }, function()
      pressure._set_sampler(function() return sample() end)
      pressure.reset()
      local expect = math.max(2, math.ceil(base_now() / 2))
      t.eq(expect, work.parallelism(), "warn 级减半")
    end)
    with_cfg({
      resources = { pressure = { enabled = true, sample_ttl_ms = 0, notify = false, simulate = "critical" } },
    }, function()
      pressure._set_sampler(function() return sample() end)
      pressure.reset()
      local expect = math.max(2, math.ceil(base_now() / 4))
      t.eq(expect, work.parallelism(), "critical 级降到 1/4，但保底 2（不得退化为串行）")
      t.true_(work.parallelism() >= 2, "critical 也不得压到 1")
    end)
    -- 单点关闭后回到原值
    with_cfg({
      resources = {
        pressure = {
          enabled = true, sample_ttl_ms = 0, notify = false, simulate = "critical",
          degrade = { thread_pool = false },
        },
      },
    }, function()
      pressure._set_sampler(function() return sample() end)
      pressure.reset()
      t.eq(base_now(), work.parallelism(), "单点关闭后不收敛")
    end)
  end)

  it("observer.observation_allowed 与 start/start_devwatch 早退；强制层不随之降级", function(t)
    local observer = require("NeoAI.sandbox.observe.observer")
    -- 记录强制层判定（安全层），下降级前后必须完全一致
    local function enforce_snapshot()
      return {
        backstop = observer.backstop_available(),
        backend = (observer.backend()),
      }
    end
    with_cfg({ resources = { pressure = { enabled = true, sample_ttl_ms = 0, notify = false } } }, function()
      pressure._set_sampler(function() return sample() end)
      pressure.reset()
      local allowed, reason = observer.observation_allowed()
      t.eq(true, allowed, "ok 级应允许观测")
      t.eq(nil, reason)
    end)
    local before
    with_cfg({ resources = { pressure = { enabled = true, sample_ttl_ms = 0, notify = false } } }, function()
      pressure._set_sampler(function() return sample() end)
      pressure.reset()
      before = enforce_snapshot()
    end)
    with_cfg({
      resources = { pressure = { enabled = true, sample_ttl_ms = 0, notify = false, simulate = "critical" } },
    }, function()
      pressure._set_sampler(function() return sample() end)
      pressure.reset()
      local allowed, reason = observer.observation_allowed()
      t.eq(false, allowed, "critical 级应关闭观测")
      t.eq("pressure:critical", reason)
      -- M.start 按既有 nil 容错早退
      local h, err = observer.start({ cgroup_id = 1, on_event = function() end })
      t.eq(nil, h, "critical 级 start 应返回 nil")
      t.eq("OBSERVE_DEGRADED_PRESSURE", err)
      -- start_devwatch 同样早退（先满足 backend=ebpf 前置，确认是压力门控而非后端缺失）
      local orig_backend = observer.backend
      observer.backend = function() return "ebpf" end
      local dh, derr = observer.start_devwatch({ cgroup_id = 1, on_event = function() end })
      observer.backend = orig_backend
      t.eq(nil, dh, "critical 级 devwatch 应返回 nil")
      t.eq("OBSERVE_DEGRADED_PRESSURE", derr)
      -- **安全强制层不降级**：backstop_available / backend 选路与压力无关
      local after = enforce_snapshot()
      t.eq(before.backstop, after.backstop, "security：eBPF 行为兜底可用性不得随资源压力变化")
      t.eq(before.backend, after.backend, "security：观测后端选路不得随资源压力变化")
    end)
    -- 单点关闭：degrade.observe_kernel=false 时 critical 仍允许观测
    with_cfg({
      resources = {
        pressure = {
          enabled = true, sample_ttl_ms = 0, notify = false, simulate = "critical",
          degrade = { observe_kernel = false },
        },
      },
    }, function()
      pressure._set_sampler(function() return sample() end)
      pressure.reset()
      t.eq(true, observer.observation_allowed(), "单点关闭后 critical 仍允许观测")
    end)
  end)

  it("_prewarm_observer 在 warn 及以上不建 cgroup、不挂探针", function(t)
    local wrapper = require("NeoAI.sandbox.execution.wrapper")
    local cgroup = require("NeoAI.sandbox.execution.cgroup")
    if not cgroup.probe().available then return end
    local observer = require("NeoAI.sandbox.observe.observer")
    wrapper.clear_prewarm()
    -- 伪 eBPF 后端：只验证「是否被调用」，不依赖真实 bpftrace
    local started = 0
    local orig_backend, orig_available, orig_start = observer.backend, observer.available, observer.start
    observer.backend = function() return "ebpf" end
    observer.available = function() return true, "ebpf" end
    observer.start = function()
      started = started + 1
      return { backend = "ebpf", ready = false, stop = function() end }
    end
    -- ok 级：应预热
    with_cfg({
      resources = { pressure = { enabled = true, sample_ttl_ms = 0, notify = false } },
      tools = { sandbox = { observe = { enabled = true, prewarm = true, prewarm_ttl_ms = 60000 } } },
    }, function()
      pressure._set_sampler(function() return sample() end)
      pressure.reset()
      wrapper._prewarm_observer()
      t.eq(true, wrapper.prewarm_info().active, "ok 级应建立预热 cgroup")
      t.eq(1, started, "ok 级应启动一次探针")
      wrapper.clear_prewarm()
    end)
    -- warn / critical 级：不预热
    for _, lvl in ipairs({ "warn", "critical" }) do
      started = 0
      with_cfg({
        resources = {
          pressure = { enabled = true, sample_ttl_ms = 0, notify = false, simulate = lvl },
        },
        tools = { sandbox = { observe = { enabled = true, prewarm = true, prewarm_ttl_ms = 60000 } } },
      }, function()
        pressure._set_sampler(function() return sample() end)
        pressure.reset()
        wrapper._prewarm_observer()
        t.eq(false, wrapper.prewarm_info().active, lvl .. " 级不应建立预热 cgroup")
        t.eq(0, started, lvl .. " 级不应启动探针")
      end)
    end
    -- 单点关闭：degrade.observe_prewarm=false 时 warn 级仍预热
    with_cfg({
      resources = {
        pressure = {
          enabled = true, sample_ttl_ms = 0, notify = false, simulate = "warn",
          degrade = { observe_prewarm = false },
        },
      },
      tools = { sandbox = { observe = { enabled = true, prewarm = true, prewarm_ttl_ms = 60000 } } },
    }, function()
      pressure._set_sampler(function() return sample() end)
      pressure.reset()
      started = 0
      wrapper._prewarm_observer()
      t.eq(true, wrapper.prewarm_info().active, "单点关闭后 warn 级仍应预热")
      wrapper.clear_prewarm()
    end)
    observer.backend, observer.available, observer.start = orig_backend, orig_available, orig_start
    wrapper.clear_prewarm()
  end)
end)
