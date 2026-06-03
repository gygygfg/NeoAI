--- NeoAI 流程测试入口
--- 所有测试均为「流程测试」（Flow Test）：按真实调用链路测试模块协作，
--- 验证数据在模块间流转的正确性，不测试孤立的单元函数。
---
--- 用法:
---   :NeoAITest
---   或指定流程:
---   :NeoAITest flow_utils flow_config flow_tools flow_core flow_events flow_keymaps flow_full
---
--- 流程测试覆盖的调用链：
---   flow_utils     → common → table_utils → file_utils → json → logger → async_worker
---   flow_config    → default_config → merger → state → keymap_manager
---   flow_tools     → approval_state → tool_registry → tool_validator → tool_pack → tools.init
---   flow_core      → shutdown_flag → events → history.manager → core.init
---   flow_events    → 事件定义完整性 → 事件触发/监听 → 跨模块事件协作
---   flow_keymaps   → keymap_manager 完整生命周期（init→get→set→reset→export→save）
---   flow_full      → 端到端：setup → 工具注册 → 配置查询 → 事件触发 → 清理

local M = {}

--- 获取当前 Neovim 实例中已加载的 NeoAI 配置
function M.get_merged_config()
  local ok, core = pcall(require, "NeoAI.core")
  if ok then
    local config_ok, config = pcall(core.get_config, core)
    if config_ok and config then
      return config
    end
  end
  local default_config = require("NeoAI.default_config")
  return default_config.get_default_config()
end

--- 运行所有流程测试（或指定测试）
--- @param ... string|nil 要运行的测试名称列表（不带 test_flow_ 前缀，如 "utils"）
function M.run_all(...)
  local all_tests = {
    "test_flow_utils",    -- common → table_utils → file_utils → json → logger → async_worker
    "test_flow_config",   -- default_config → merger → state → keymap_manager
    "test_flow_tools",    -- approval_state → tool_registry → tool_validator → tool_pack → tools.init
    "test_flow_core",     -- shutdown_flag → events → history.manager → core.init
    "test_flow_events",   -- 事件定义完整性 → 事件触发/监听 → 跨模块事件协作
    "test_flow_keymaps",  -- keymap_manager 完整生命周期
    "test_flow_full",     -- 端到端集成流程
  }

  local tests
  if select("#", ...) > 0 then
    tests = {}
    for i = 1, select("#", ...) do
      local name = select(i, ...)
      if not name:match("^test_flow_") then
        name = "test_flow_" .. name
      end
      table.insert(tests, name)
    end
  else
    tests = all_tests
  end

  package.loaded["NeoAI.tests"] = M

  -- 日志设置
  local logger = require("NeoAI.utils.logger")
  local config = M.get_merged_config()
  local log_path = (config and config.log and config.log.output_path) or "/root/NeoAI/lua/NeoAI/neoai.log"
  local log_level = (config and config.log and config.log.level) or "DEBUG"
  _G._NEOAI_TEST_LOG_PATH = log_path
  _G._NEOAI_TEST_LOG_LEVEL = log_level
  logger.set_output(log_path)
  logger.set_level(log_level)
  M._logger = logger

  _G._NEOAI_TEST_RUNNING = true

  local results = { passed = 0, failed = 0, errors = {} }
  local info = debug.getinfo(1, "S")
  local base_dir = info.source:match("^@?(.*/)") or "."

  local uis = vim.api.nvim_list_uis()
  local is_headless = #uis == 0
  if vim.env.NVIM_HEADLESS then
    is_headless = true
  end

  for _, name in ipairs(tests) do
    -- 每个测试文件运行前恢复 logger
    local pre_logger = require("NeoAI.utils.logger")
    pre_logger.initialize({ max_file_size = 10485760, max_backups = 5 })
    pre_logger.set_output(nil)
    pre_logger.set_output(_G._NEOAI_TEST_LOG_PATH or log_path)
    pre_logger.set_level(_G._NEOAI_TEST_LOG_LEVEL or log_level)
    M._logger = pre_logger

    local ok, err = pcall(function()
      local filepath = base_dir .. "/" .. name .. ".lua"
      local test_mod = dofile(filepath)
      if test_mod and test_mod.run then
        local r = test_mod.run(M)
        if r then
          results.passed = results.passed + (r.passed or 0)
          results.failed = results.failed + (r.failed or 0)
          if r.errors then
            for _, e in ipairs(r.errors) do
              table.insert(results.errors, "[" .. name:gsub("test_flow_", "") .. "] " .. e)
            end
          end
        end
      end
    end)
    if not ok then
      results.failed = results.failed + 1
      table.insert(results.errors, "[" .. name:gsub("test_flow_", "flow_") .. "] load: " .. tostring(err))
    end

    -- 恢复 logger
    local current_logger = require("NeoAI.utils.logger")
    local restore_path = _G._NEOAI_TEST_LOG_PATH or log_path
    local restore_level = _G._NEOAI_TEST_LOG_LEVEL or log_level
    current_logger.set_output(nil)
    current_logger.set_output(restore_path)
    current_logger.set_level(restore_level)
    M._logger = current_logger
    current_logger.debug(string.format("[流程测试] %s 完成", name))

    if is_headless then
      vim.wait(10, function() return false end)
    end
  end

  -- 汇总
  local summary_logger = require("NeoAI.utils.logger")
  local summary = string.format("流程测试结果: %d 通过, %d 失败", results.passed, results.failed)
  summary_logger.info(summary)
  if #results.errors > 0 then
    local error_msgs = {}
    for _, e in ipairs(results.errors) do
      table.insert(error_msgs, e)
    end
    summary_logger.warn("失败的流程测试:\n  " .. table.concat(error_msgs, "\n  "))
  end

  return results
end

-- ============================================================
-- 流程测试专用断言工具
-- ============================================================
M.assert = {
  equal = function(expected, actual, msg)
    if expected ~= actual then
      error(string.format("断言失败: %s\n  期望: %s\n  实际: %s",
        msg or "值不相等", vim.inspect(expected), vim.inspect(actual)))
    end
  end,

  not_equal = function(expected, actual, msg)
    if expected == actual then
      error(string.format("断言失败: %s\n  期望不等于: %s",
        msg or "值不应相等", vim.inspect(expected)))
    end
  end,

  is_true = function(value, msg)
    if not value then
      error(string.format("断言失败: %s\n  期望为真, 实际为: %s",
        msg or "值应为真", vim.inspect(value)))
    end
  end,

  is_false = function(value, msg)
    if value then
      error(string.format("断言失败: %s\n  期望为假, 实际为: %s",
        msg or "值应为假", vim.inspect(value)))
    end
  end,

  is_nil = function(value, msg)
    if value ~= nil then
      error(string.format("断言失败: %s\n  期望为 nil, 实际为: %s",
        msg or "值应为 nil", vim.inspect(value)))
    end
  end,

  not_nil = function(value, msg)
    if value == nil then
      error(string.format("断言失败: %s\n  值不应为 nil", msg or "值不应为 nil"))
    end
  end,

  has_key = function(tbl, key, msg)
    if tbl == nil or tbl[key] == nil then
      error(string.format("断言失败: %s\n  表不包含键: %s", msg or "表应包含键", tostring(key)))
    end
  end,

  contains = function(tbl, value, msg)
    if type(tbl) ~= "table" then
      error(string.format("断言失败: %s\n  期望为表, 实际为: %s", msg or "值应为表", type(tbl)))
    end
    for _, v in ipairs(tbl) do
      if v == value then return end
    end
    error(string.format("断言失败: %s\n  表不包含值: %s", msg or "表应包含值", vim.inspect(value)))
  end,

  assert_error = function(fn, expected_msg, msg)
    local ok, err = pcall(fn)
    if ok then
      error(string.format("断言失败: %s\n  期望抛出错误, 但未抛出", msg or "应抛出错误"))
    end
    if expected_msg and not string.find(tostring(err), expected_msg, 1, true) then
      error(string.format("断言失败: %s\n  期望错误包含: %s\n  实际错误: %s",
        msg or "错误消息不匹配", expected_msg, tostring(err)))
    end
  end,

  -- 流程测试专用：断言类型
  type_eq = function(expected_type, value, msg)
    local actual = type(value)
    if actual ~= expected_type then
      error(string.format("断言失败: %s\n  期望类型: %s\n  实际类型: %s",
        msg or "类型不匹配", expected_type, actual))
    end
  end,
}

--- 运行单个测试函数
function M.test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    M._logger.info(string.format("  ✓ %s", name))
    return true
  else
    M._logger.error(string.format("  ✗ %s: %s", name, tostring(err)))
    return false
  end
end

--- 运行一组流程测试
function M.run_tests(tests)
  local results = { passed = 0, failed = 0, errors = {} }
  local ordered_tests = {}
  if type(tests[1]) == "table" then
    -- 带 name/fn 结构的表
    ordered_tests = tests
  else
    local names = {}
    for name, _ in pairs(tests) do
      table.insert(names, name)
    end
    table.sort(names)
    for _, name in ipairs(names) do
      table.insert(ordered_tests, { name = name, fn = tests[name] })
    end
  end
  for _, test_item in ipairs(ordered_tests) do
    local name = test_item.name or "unnamed"
    local fn = test_item.fn or test_item
    if M.test(name, fn) then
      results.passed = results.passed + 1
    else
      results.failed = results.failed + 1
      table.insert(results.errors, name)
    end
  end
  return results
end

return M
