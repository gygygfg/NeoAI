--- 自身内存看门狗
--- @module 'NeoAI.tests.test_self_guard'
--- 覆盖：阈值分级（软/硬边界、Lua 堆）、探测不可用不误伤、回收器执行与失败隔离、
---       hard 触发中止器 + cooldown、allow_start 门禁、注册/注销可逆。
--- 说明：全部通过 `_set_sampler()` 注入伪采样，绝不依赖宿主机真实内存。

local tests = require("NeoAI.tests")

local MIB = 1024 * 1024

--- 构造一份伪采样（默认 4 GB 总量、3 GB RSS）
--- @param over table|nil
--- @return table
local function sample(over)
  local s = {
    rss_bytes = 512 * MIB,
    peak_bytes = 600 * MIB,
    lua_bytes = 8 * MIB,
    mem_total_bytes = 4096 * MIB,
    at = vim.uv.hrtime(),
  }
  for k, v in pairs(over or {}) do s[k] = v end
  return s
end

--- 在指定配置下运行（结束后恢复配置与模块状态）
--- @param overrides table
--- @param fn function
local function with_cfg(overrides, fn)
  local config_store = require("NeoAI.kernel.config_store")
  local guard = require("NeoAI.kernel.self_guard")
  local saved = config_store.get_all()
  local cfg = vim.deepcopy(overrides or {})
  cfg.resources = cfg.resources or {}
  cfg.resources.self_guard = cfg.resources.self_guard or {}
  if cfg.resources.self_guard.notify == nil then cfg.resources.self_guard.notify = false end
  config_store.load(cfg)
  guard.reset()
  local ok, err = pcall(fn)
  guard._set_sampler(nil)
  guard.reset()
  config_store.load(saved)
  guard.reset()
  if not ok then error(err, 0) end
end

tests.suite("self_guard", function(_, it)
  local guard = require("NeoAI.kernel.self_guard")

  it("classify：软/硬阈值边界与 Lua 堆软阈值", function(t)
    local cfg = { soft_mb = 1024, soft_ratio = 0, hard_mb = 2048, hard_ratio = 0, lua_heap_mb = 64 }
    t.eq("ok", guard.classify(sample(), cfg), "512MB 低于软阈值")
    t.eq("soft", guard.classify(sample({ rss_bytes = 1024 * MIB }), cfg), "达到软阈值")
    t.eq("hard", guard.classify(sample({ rss_bytes = 2048 * MIB }), cfg), "达到硬阈值")
    t.eq("soft", guard.classify(sample({ lua_bytes = 64 * MIB }), cfg), "Lua 堆达软阈值")
    t.eq("ok", guard.classify({}, cfg), "空采样视为 ok")
    t.eq("ok", guard.classify(nil, cfg), "nil 采样视为 ok")
  end)

  it("探测不可用（/proc 缺失）一律视为 ok，绝不误伤", function(t)
    with_cfg({ resources = { self_guard = { enabled = true } } }, function()
      guard._set_sampler(function() return nil end)
      local level, snap = guard.check({ force = true })
      t.eq("ok", level)
      t.true_(snap.unavailable == true, "应标记 unavailable")
    end)
  end)

  it("soft：执行已注册回收器 + GC，但不中止回合", function(t)
    with_cfg({ resources = { self_guard = { enabled = true, soft_mb = 256, soft_ratio = 0, hard_mb = 1024, hard_ratio = 0 } } }, function()
      guard._set_sampler(function() return sample({ rss_bytes = 512 * MIB }) end)
      local ran, aborted = 0, false
      local un_reg = guard.register_reclaimer("test", function() ran = ran + 1 end)
      local un_abort = guard.set_abort_handler(function() aborted = true; return true end)
      local level, _, actions = guard.check({ force = true })
      t.eq("soft", level)
      t.eq(1, ran, "回收器应执行一次")
      t.false_(aborted, "soft 不应中止回合")
      t.ok(#actions >= 1)
      un_reg()
      un_abort()
    end)
  end)

  it("hard：回收后仍超限 → 调用中止器并进入 cooldown", function(t)
    with_cfg({ resources = { self_guard = {
      enabled = true, soft_mb = 256, soft_ratio = 0, hard_mb = 512, hard_ratio = 0, cooldown_ms = 60000,
    } } }, function()
      guard._set_sampler(function() return sample({ rss_bytes = 1024 * MIB }) end)
      local calls = 0
      local un_abort = guard.set_abort_handler(function() calls = calls + 1; return true end)
      local level, _, actions, still = guard.check({ force = true })
      t.eq("hard", level)
      t.true_(still, "回收后仍超限")
      t.eq(1, calls, "中止器应被调用一次")
      t.ok(vim.tbl_contains(actions, "abort"))
      t.false_(guard.allow_start(), "cooldown 内拒绝新回合")
      un_abort()
    end)
  end)

  it("中止器缺失也进入 cooldown（宁拒绝也不被 OOM 杀）", function(t)
    with_cfg({ resources = { self_guard = {
      enabled = true, soft_mb = 256, soft_ratio = 0, hard_mb = 512, hard_ratio = 0, cooldown_ms = 60000,
    } } }, function()
      guard._set_sampler(function() return sample({ rss_bytes = 1024 * MIB }) end)
      local _, _, actions, still = guard.check({ force = true })
      t.true_(still)
      t.ok(vim.tbl_contains(actions, "over_limit"), "无中止器时只记录超限，不封锁新回合")
      t.true_(guard.allow_start(), "没有中止在途工作时不进入冷静期")
    end)
  end)

  it("回落 ok 后 cooldown 失效且允许新回合", function(t)
    with_cfg({ resources = { self_guard = {
      enabled = true, soft_mb = 256, soft_ratio = 0, hard_mb = 512, hard_ratio = 0, cooldown_ms = 1,
    } } }, function()
      guard._set_sampler(function() return sample({ rss_bytes = 1024 * MIB }) end)
      guard.check({ force = true })
      guard._set_sampler(function() return sample({ rss_bytes = 64 * MIB }) end)
      vim.wait(20)
      t.eq("ok", guard.level())
      t.true_(guard.allow_start())
    end)
  end)

  it("enabled=false 时 check 为 no-op", function(t)
    with_cfg({ resources = { self_guard = { enabled = false } } }, function()
      guard._set_sampler(function() return sample({ rss_bytes = 8192 * MIB }) end)
      local level, snap = guard.check({ force = true })
      t.eq("ok", level)
      t.true_(snap.disabled == true)
    end)
  end)

  it("回收器抛错被隔离，不影响后续回收器与调用方", function(t)
    with_cfg({ resources = { self_guard = { enabled = true, soft_mb = 128, soft_ratio = 0, hard_mb = 1024, hard_ratio = 0 } } }, function()
      guard._set_sampler(function() return sample({ rss_bytes = 256 * MIB }) end)
      local after = 0
      local un1 = guard.register_reclaimer("boom", function() error("boom") end)
      local un2 = guard.register_reclaimer("ok", function() after = after + 1 end)
      local ok = pcall(function() guard.check({ force = true }) end)
      t.true_(ok, "回收器异常不得冒泡")
      t.eq(1, after)
      un1()
      un2()
    end)
  end)
end)
