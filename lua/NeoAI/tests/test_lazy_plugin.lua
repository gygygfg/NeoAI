--- 懒加载占位插件（plugins.builtin.lazy）专项测试
--- @module NeoAI.tests.test_lazy_plugin
--- 覆盖占位命令注册/清理契约与阶段分派（不触发真实命令）。
local tests = require("NeoAI.tests")

tests.suite("lazy_plugin", function(_, it)
  local lazy = require("NeoAI.plugins.builtin.lazy")
  local commands = require("NeoAI.plugins.builtin.commands")

  local function exists(name)
    return vim.fn.exists(":" .. name) == 2
  end

  local function api(overrides)
    local base = {
      ensure_phase1 = function(cb) cb(true) end,
      ensure_started = function(cb) cb(true) end,
      is_started = function() return false end,
    }
    for k, v in pairs(overrides or {}) do base[k] = v end
    return base
  end

  it("register 注册全部占位命令，cleanup 未启动时删除", function(t)
    local cleanup = lazy.register(api())
    for _, n in ipairs(commands.NAMES) do t.true_(exists(n), n .. " 占位命令应存在") end
    cleanup()
    for _, n in ipairs(commands.NAMES) do t.false_(exists(n), n .. " 占位命令应被删除") end
    commands.start() -- 恢复真实命令供后续用例/套件
  end)

  it("cleanup 在已启动时不删除（避免误删真实命令）", function(t)
    local cleanup = lazy.register(api({ is_started = function() return true end }))
    cleanup()
    t.true_(exists("NeoAIOpen"), "已启动时不应删除命令")
    commands.start()
  end)

  it("分派：阶段 1 命令走 ensure_phase1，其余走 ensure_started", function(t)
    local phase1, full = 0, 0
    local cleanup = lazy.register(api({
      -- cb(false)：占位回调查知启动失败，仅记录不转发真实命令
      ensure_phase1 = function(cb) phase1 = phase1 + 1; cb(false) end,
      ensure_started = function(cb) full = full + 1; cb(false) end,
    }))
    pcall(vim.cmd, "NeoAIOpen")           -- PHASE1
    pcall(vim.cmd, "NeoAISandboxCaps")    -- 需全量启动
    cleanup()
    commands.start()
    t.eq(1, phase1, "NeoAIOpen 应走阶段 1")
    t.eq(1, full, "NeoAISandboxCaps 应走全量启动")
  end)
end)
