--- 子进程总管理（supervisor）
--- @module 'NeoAI.tests.test_supervisor'
--- 覆盖：登记/注销、状态迁移、退避计数、熔断打开与复位、心跳只观测自报进程、
---       外部进程心跳失活计崩溃、启动适配器失败隔离、状态事件。
--- 说明：不拉起真实子进程（用注入的 probe/start/stop），确保离线可复现。

local tests = require("NeoAI.tests")

--- 在指定配置下运行（结束后恢复配置与模块状态）
--- @param overrides table
--- @param fn function
local function with_cfg(overrides, fn)
  local config_store = require("NeoAI.kernel.config_store")
  local sup = require("NeoAI.kernel.supervisor")
  local saved = config_store.get_all()
  config_store.load(overrides or {})
  sup.reset()
  local ok, err = pcall(fn)
  sup.reset()
  config_store.load(saved)
  sup.reset()
  if not ok then error(err, 0) end
end

local function base_cfg(over)
  local cfg = {
    resources = {
      supervisor = {
        enabled = true,
        heartbeat_ms = 0,
        max_restarts = 3,
        breaker_threshold = 3,
        breaker_window_ms = 60000,
        notify = false,
      },
      -- 动态内存限额依赖压力模块的可用内存采样（测试默认会关掉压力自适应）。
      pressure = { enabled = true, sample_ttl_ms = 0 },
    },
  }
  for k, v in pairs(over or {}) do
    if k == "pressure" then
      for pk, pv in pairs(v) do cfg.resources.pressure[pk] = pv end
    else
      cfg.resources.supervisor[k] = v
    end
  end
  return cfg
end

tests.suite("supervisor", function(_, it)
  local sup = require("NeoAI.kernel.supervisor")

  it("登记 / 运行态 / 注销", function(t)
    with_cfg(base_cfg(), function()
      local id = sup.register({ id = "fake.a", kind = "fake" })
      t.eq("fake.a", id)
      t.eq("stopped", sup.state("fake.a").state)
      sup.mark_running("fake.a", 4242)
      local st = sup.state("fake.a")
      t.eq("running", st.state)
      t.eq(4242, st.pid)
      sup.unregister("fake.a")
      t.nil_(sup.state("fake.a"))
      t.eq("fake.a", id)
    end)
  end)

  it("崩溃上报：先返回 restart，达到阈值后熔断返回 stop", function(t)
    with_cfg(base_cfg(), function()
      sup.register({ id = "fake.b", kind = "fake" })
      sup.mark_running("fake.b", 111)
      t.eq("restart", sup.report_crash("fake.b", "boom1"))
      t.eq("restart", sup.report_crash("fake.b", "boom2"))
      t.eq("stop", sup.report_crash("fake.b", "boom3"), "第三次达到 breaker_threshold")
      local st = sup.state("fake.b")
      t.true_(st.breaker_open, "应打开熔断")
      t.eq("failed", st.state)
      t.true_(sup.degraded(), "应有降级标记")
      -- 熔断后再上报仍然 stop（不会自动恢复）
      t.eq("stop", sup.report_crash("fake.b", "boom4"))
      -- 复位后可重新启动
      sup.reset_breaker("fake.b")
      t.false_(sup.state("fake.b").breaker_open)
      t.false_(sup.degraded())
    end)
  end)

  it("未登记的 id 上报崩溃不干预（返回 restart）", function(t)
    with_cfg(base_cfg(), function()
      t.eq("restart", sup.report_crash("nope", "x"))
    end)
  end)

  it("心跳：自报进程只收敛状态，不重复计崩溃", function(t)
    with_cfg(base_cfg(), function()
      local alive = true
      sup.register({
        id = "fake.self", kind = "fake", self_report = true,
        probe = function() return alive end,
      })
      sup.heartbeat_once()
      t.eq("running", sup.state("fake.self").state, "首次探测存活即运行")
      alive = false
      sup.heartbeat_once()
      local st = sup.state("fake.self")
      t.eq(0, st.crashes, "自报进程心跳不记崩溃")
      t.eq("stopped", st.state)
    end)
  end)

  it("心跳：外部进程失活即计一次崩溃", function(t)
    with_cfg(base_cfg(), function()
      local alive = true
      sup.register({ id = "fake.ext", kind = "fake", probe = function() return alive end })
      sup.heartbeat_once()
      t.eq("running", sup.state("fake.ext").state)
      alive = false
      sup.heartbeat_once()
      t.eq(1, sup.state("fake.ext").crashes, "外部失活应计崩溃")
      t.eq("restarting", sup.state("fake.ext").state)
    end)
  end)

  it("ensure：启动适配器成功标记运行；失败只返回错误不抛", function(t)
    with_cfg(base_cfg(), function()
      sup.register({ id = "fake.ok", kind = "fake", start = function() return true end })
      local ok, err = sup.ensure("fake.ok")
      t.true_(ok)
      t.nil_(err)
      t.eq("running", sup.state("fake.ok").state)

      sup.register({ id = "fake.bad", kind = "fake", start = function() error("nope") end })
      local ok2 = pcall(function()
        local r = sup.ensure("fake.bad")
        t.false_(r)
      end)
      t.true_(ok2, "适配器异常不得冒泡")
      t.eq("stopped", sup.state("fake.bad").state)
    end)
  end)

  it("stop 调用适配器且失败被隔离", function(t)
    with_cfg(base_cfg(), function()
      local stopped = 0
      sup.register({ id = "fake.s", kind = "fake", stop = function() stopped = stopped + 1 end })
      sup.mark_running("fake.s", 1)
      t.true_(sup.stop("fake.s"))
      t.eq(1, stopped)
      t.eq("stopped", sup.state("fake.s").state)

      sup.register({ id = "fake.s2", kind = "fake", stop = function() error("bad stop") end })
      local ok = pcall(function() sup.stop("fake.s2") end)
      t.true_(ok, "stop 异常不得冒泡")
    end)
  end)

  it("限额：未配置上限时不写 cgroup（返回 true 且不影响启动）", function(t)
    with_cfg(base_cfg(), function()
      sup.register({ id = "fake.l", kind = "fake" })
      local ok = sup.apply_limits("fake.l", 12345)
      t.true_(ok, "无上限配置应直接放行")
    end)
  end)

  it("动态内存上限：按剩余内存 × 比例计算，并受下限/绝对上限/预留约束", function(t)
    local pressure = require("NeoAI.kernel.pressure")
    local MIB = 1024 * 1024
    --- 注入可用内存并刷新压力缓存
    local function avail(bytes, level)
      pressure._set_sampler(function()
        return {
          mem_total_bytes = 8 * 1024 * MIB,
          mem_available_bytes = bytes,
          swap_total_bytes = 1024 * MIB,
          psi_memory_avg10 = 0, psi_cpu_avg10 = 0, load1 = 0, cores = 4,
        }
      end)
      pressure.reset()
      local config_store = require("NeoAI.kernel.config_store")
      config_store.set("resources.pressure.simulate", level or "ok")
      pressure.reset()
    end
    with_cfg(base_cfg({ memory_auto = true, memory_ratio = 0.5,
      memory_min_bytes = 128 * MIB, memory_reserve_bytes = 256 * MIB, memory_max_bytes = 0,
      -- 测试默认关闭压力自适应；动态限额依赖可用内存采样，故显式开启并注入伪采样。
    }), function()
      sup.register({ id = "dyn", kind = "dyn", limits = { dynamic = true } })
      avail(4 * 1024 * MIB)
      t.eq(2 * 1024 * MIB, sup.limit_for("dyn"), "4GB 可用 × 0.5 = 2GB")
      -- 预留约束：可用 512MB 时上限不得超过 512−256=256MB
      avail(512 * MIB)
      t.eq(256 * MIB, sup.limit_for("dyn"), "扣除预留后封顶")
      -- 下限约束：可用极低时至少给 64MB（避免一启动就被回收）
      avail(32 * MIB)
      local low = sup.limit_for("dyn")
      t.ok(low and low >= 64 * MIB, "极低可用内存时保底 64MB")
      -- 压力等级联动：warn ×0.75、critical ×0.5（在可用内存充足时只体现比例缩放）
      avail(4 * 1024 * MIB, "warn")
      t.eq(math.floor(2 * 1024 * MIB * 0.75), sup.limit_for("dyn"), "warn 级比例 ×0.75")
      avail(4 * 1024 * MIB, "critical")
      t.eq(math.floor(2 * 1024 * MIB * 0.5), sup.limit_for("dyn"), "critical 级比例 ×0.5")
    end)
    with_cfg(base_cfg({ memory_auto = false, memory_max_bytes = 512 * MIB }), function()
      sup.register({ id = "dyn2", kind = "dyn2", limits = { dynamic = true } })
      avail(4 * 1024 * MIB)
      t.eq(512 * MIB, sup.limit_for("dyn2"), "关闭动态后使用固定值")
    end)
    with_cfg(base_cfg({ memory_auto = true, memory_ratio = 0.5,
      memory_min_bytes = 64 * MIB, memory_reserve_bytes = 0, memory_max_bytes = 1024 * MIB }), function()
      sup.register({ id = "dyn3", kind = "dyn3", limits = { dynamic = true } })
      avail(8 * 1024 * MIB)
      t.eq(1024 * MIB, sup.limit_for("dyn3"), "绝对上限封顶")
    end)
    pressure._set_sampler(nil)
    pressure.reset()
  end)

  it("动态内存上限：非动态进程只用显式值；无限制时返回 nil", function(t)
    with_cfg(base_cfg({ memory_max_bytes = 0 }), function()
      sup.register({ id = "plain", kind = "plain" })
      t.nil_(sup.limit_for("plain"), "未声明动态且无固定值 → 不限制")
      sup.register({ id = "fixed", kind = "fixed", limits = { memory_bytes = 128 * 1024 * 1024 } })
      t.eq(128 * 1024 * 1024, sup.limit_for("fixed"))
    end)
  end)

  it("refresh_limits：收紧立即生效，放宽需超过 20%", function(t)
    local pressure = require("NeoAI.kernel.pressure")
    local MIB = 1024 * 1024
    local function avail(bytes)
      pressure._set_sampler(function()
        return {
          mem_total_bytes = 8 * 1024 * MIB, mem_available_bytes = bytes,
          swap_total_bytes = 1024 * MIB, psi_memory_avg10 = 0, psi_cpu_avg10 = 0,
          load1 = 0, cores = 4,
        }
      end)
      local config_store = require("NeoAI.kernel.config_store")
      config_store.set("resources.pressure.simulate", "ok")
      pressure.reset()
    end
    with_cfg(base_cfg({ memory_auto = true, memory_ratio = 0.5,
      memory_min_bytes = 64 * MIB, memory_reserve_bytes = 0 }), function()
      sup.register({ id = "dyn4", kind = "dyn4", limits = { dynamic = true } })
      avail(4 * 1024 * MIB)
      t.ok(sup.refresh_limits() >= 1, "首次应写入上限")
      local first = sup.state("dyn4").memory_limit
      t.eq(2 * 1024 * MIB, first)
      -- 放宽 10%：不应更新（避免抖动）
      avail(math.floor(4.4 * 1024 * MIB))
      sup.refresh_limits()
      t.eq(first, sup.state("dyn4").memory_limit, "小幅放宽不更新")
      -- 收紧：立即更新
      avail(1024 * MIB)
      sup.refresh_limits()
      t.eq(512 * MIB, sup.state("dyn4").memory_limit, "收紧立即生效")
      -- 大幅放宽（>20%）：更新
      avail(8 * 1024 * MIB)
      sup.refresh_limits()
      t.eq(4 * 1024 * MIB, sup.state("dyn4").memory_limit, "明显放宽后更新")
    end)
    pressure._set_sampler(nil)
    pressure.reset()
  end)

  it("refresh_limits：有 cgroup 句柄时在线更新 limit_path/memory.max", function(t)
    local pressure = require("NeoAI.kernel.pressure")
    local fs = require("NeoAI.utils.fs")
    local MIB = 1024 * 1024
    local function avail(bytes)
      pressure._set_sampler(function()
        return {
          mem_total_bytes = 8 * 1024 * MIB, mem_available_bytes = bytes,
          swap_total_bytes = 1024 * MIB, psi_memory_avg10 = 0, psi_cpu_avg10 = 0,
          load1 = 0, cores = 4,
        }
      end)
      require("NeoAI.kernel.config_store").set("resources.pressure.simulate", "ok")
      pressure.reset()
    end
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local lim_file = dir .. "/memory.max"
    fs.write_file(lim_file, "0")
    with_cfg(base_cfg({ memory_auto = true, memory_ratio = 0.5,
      memory_min_bytes = 64 * MIB, memory_reserve_bytes = 0 }), function()
      sup.register({ id = "dyn5", kind = "dyn5", limits = { dynamic = true } })
      sup._set_handle("dyn5", { limit_path = dir, path = dir })
      avail(4 * 1024 * MIB)
      sup.refresh_limits()
      t.eq(tostring(2 * 1024 * MIB), fs.read_file(lim_file), "首次写入动态上限")
      avail(1024 * MIB)
      sup.refresh_limits()
      t.eq(tostring(512 * MIB), fs.read_file(lim_file), "内存下降时在线收紧 cgroup")
      t.eq(sup.limit_path_for("dyn5"), lim_file)
    end)
    pressure._set_sampler(nil)
    pressure.reset()
    pcall(vim.fn.delete, dir, "rf")
  end)

  it("process:state 事件随状态迁移触发", function(t)
    with_cfg(base_cfg(), function()
      local event_bus = require("NeoAI.kernel.event_bus")
      local events = require("NeoAI.kernel.events")
      local seen = {}
      local un = event_bus.on(events.PROCESS_STATE, function(p)
        if p and p.id == "fake.evt" then seen[#seen + 1] = p.state end
      end)
      sup.register({ id = "fake.evt", kind = "fake" })
      sup.mark_running("fake.evt", 1)
      sup.report_crash("fake.evt", "x")
      un()
      t.ok(#seen >= 2, "至少 running + restarting 两次事件")
    end)
  end)
end)
