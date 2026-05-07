--- NeoAI 测试入口
--- 通过主 init.lua 导入，拿到合并后的测试配置
--- 用法:
---   :NeoAITest
---
--- 或运行单个测试文件:
---   :NeoAITest test_default_config

local M = {}

-- 测试配置（合并到默认配置上）
M.test_config = {
  ui = {
    default_ui = "chat",
    window_mode = "float",
    window = {
      width = 60,
      height = 15,
      border = "none",
    },
  },
  session = {
    auto_save = false,
    auto_naming = false,
    save_path = "/tmp/neoai_test_sessions",
    max_history_per_session = 50,
  },
  tools = {
    enabled = false,
    builtin = false,
  },
  keymaps = {
    global = {
      open_tree = { key = "<leader>tt", desc = "测试打开树" },
      open_chat = { key = "<leader>cc", desc = "测试打开聊天" },
    },
  },
  log = {
    -- 日志级别: 'DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL'
    level = "DEBUG",
    -- 输出文件路径（可选，默认输出到文件，避免 print 阻塞消息区域）
    output_path = "/root/NeoAI/pack/plugins/start/NeoAI/lua/NeoAI/neoai.log",
    -- 日志格式模板
    format = "[{time}] [{level}] {message}",
    -- 最大文件大小（字节），默认 10MB
    max_file_size = 10485760,
    -- 最大备份文件数量
    max_backups = 5,
    -- 是否启用详细输出（verbose 模式）
    verbose = true,
    -- 是否启用调试打印到控制台
    print_debug = false,
  },
}

--- 获取合并后的完整配置
--- 先加载主 init.lua 的 setup 流程，再覆盖测试配置
--- @return table 合并后的完整配置
function M.get_merged_config()
  -- 加载主模块
  local ok, neoai = pcall(require, "NeoAI")
  if not ok then
    -- 如果主模块加载失败（如无 Neovim 环境），直接使用 default_config
    local default_config = require("NeoAI.default_config")
    return default_config.process_config(M.test_config)
  end

  -- 调用主模块的 setup（会合并配置）
  neoai.setup(M.test_config)

  -- 获取合并后的配置
  local state = require("NeoAI.core.config.state")
  return state.get_state("config", "data")
end

--- 运行所有测试（或指定测试）
--- @param ... string|nil 要运行的测试名称列表（不带 test_ 前缀，如 "config"）
function M.run_all(...)
  local all_tests = {
    "test_init_modules", -- 合并: config_init, core_init, ai_init, ui_init, tools_init, utils_init, main_init
    "test_config", -- 合并: default_config, state, config_merger
    "test_history", -- 合并: history_manager, history_cache, history_persistence, history_saver
    "test_tools", -- 合并: tool_registry, tool_executor, tool_validator, tool_pack
    "test_utils", -- 合并: utils_common, utils_logger, utils_json, utils_table_utils, utils_file_utils, async_worker
    "test_events_keymaps", -- 合并: event_constants, keymap_manager
    "test_ai_core", -- 合并: ai_engine, chat_service, response_retry
    "test_http_client", -- 包含特殊字符编码测试
    "test_sub_agent", -- 子 agent 创建与管理测试
    "test_integration", -- 端到端集成测试：完整 setup、真实 HTTP 请求、工具循环、命令注册
  }

  -- 如果传入了指定测试名称，只运行这些
  local tests
  if select("#", ...) > 0 then
    tests = {}
    for i = 1, select("#", ...) do
      local name = select(i, ...)
      -- 自动补全 test_ 前缀
      if not name:match("^test_") then
        name = "test_" .. name
      end
      table.insert(tests, name)
    end
  else
    tests = all_tests
  end

  -- 确保 package.loaded 中已有本模块引用，避免测试文件内部
  -- require("NeoAI.tests") 导致循环依赖
  package.loaded["NeoAI.tests"] = M

  -- 保存 logger 到模块，供 M.test 使用
  local logger = require("NeoAI.utils.logger")
  M._logger = logger

  -- 设置全局标志，禁止测试文件的自动运行代码执行
  _G._NEOAI_TEST_RUNNING = true

  local results = { passed = 0, failed = 0, errors = {} }

  -- 获取当前脚本所在目录
  local info = debug.getinfo(1, "S")
  local base_dir = info.source:match("^@?(.*/)") or "."

  -- 检测是否为 headless 模式
  -- 使用 vim.api.nvim_list_uis() 是最可靠的检测方式
  -- 在 headless 模式下，nvim_list_uis() 返回空表 {}
  -- 注意：colors_name 可能被 colorscheme 插件设置，不能作为 headless 检测依据
  local uis = vim.api.nvim_list_uis()
  local is_headless = #uis == 0
  if vim.env.NVIM_HEADLESS then
    is_headless = true
  end

  for _, name in ipairs(tests) do
    -- 注意：不清理 NeoAI 模块缓存，因为测试文件依赖模块的初始化状态。
    -- 每个测试文件通过 _test_reset() 自行管理内部状态。
    local ok, err = pcall(function()
      -- 使用 dofile 避免 require 的循环依赖
      local filepath = base_dir .. "/" .. name .. ".lua"
      local test_mod = dofile(filepath)
      if test_mod and test_mod.run then
        -- 传入 M 作为 test_module，避免测试文件内部调用 require("NeoAI.tests") 导致循环依赖
        local r = test_mod.run(M)
        if r then
          results.passed = results.passed + (r.passed or 0)
          results.failed = results.failed + (r.failed or 0)
          if r.errors then
            for _, e in ipairs(r.errors) do
              table.insert(results.errors, "[" .. name .. "] " .. e)
            end
          end
        end
      end
    end)
    if not ok then
      results.failed = results.failed + 1
      table.insert(results.errors, "[" .. name .. "] " .. tostring(err))
    end

    -- 每个测试文件运行后，强制处理一次事件循环，避免 vim.schedule 回调堆积
    -- 在 headless 模式下尤其重要
    if is_headless then
      vim.wait(10, function()
        return false
      end)
    end
  end

  return results
end

--- 简单的断言工具
M.assert = {
  --- 断言相等
  --- @param expected any
  --- @param actual any
  --- @param msg string|nil
  equal = function(expected, actual, msg)
    if expected ~= actual then
      error(
        string.format(
          "断言失败: %s\n  期望: %s\n  实际: %s",
          msg or "值不相等",
          vim.inspect(expected),
          vim.inspect(actual)
        )
      )
    end
  end,

  --- 断言不相等
  not_equal = function(expected, actual, msg)
    if expected == actual then
      error(string.format("断言失败: %s\n  期望不等于: %s", msg or "值不应相等", vim.inspect(expected)))
    end
  end,

  --- 断言为真
  is_true = function(value, msg)
    if not value then
      error(string.format("断言失败: %s\n  期望为真, 实际为假", msg or "值应为真"))
    end
  end,

  --- 断言为假
  is_false = function(value, msg)
    if value then
      error(string.format("断言失败: %s\n  期望为假, 实际为真", msg or "值应为假"))
    end
  end,

  --- 断言为 nil
  is_nil = function(value, msg)
    if value ~= nil then
      error(
        string.format("断言失败: %s\n  期望为 nil, 实际为 %s", msg or "值应为 nil", vim.inspect(value))
      )
    end
  end,

  --- 断言不为 nil
  not_nil = function(value, msg)
    if value == nil then
      error(string.format("断言失败: %s\n  值不应为 nil", msg or "值不应为 nil"))
    end
  end,

  --- 断言表包含键
  has_key = function(tbl, key, msg)
    if tbl == nil or tbl[key] == nil then
      error(string.format("断言失败: %s\n  表不包含键: %s", msg or "表应包含键", tostring(key)))
    end
  end,

  --- 断言表包含值
  contains = function(tbl, value, msg)
    if type(tbl) ~= "table" then
      error(string.format("断言失败: %s\n  期望为表, 实际为 %s", msg or "值应为表", type(tbl)))
    end
    for _, v in ipairs(tbl) do
      if v == value then
        return
      end
    end
    error(string.format("断言失败: %s\n  表不包含值: %s", msg or "表应包含值", vim.inspect(value)))
  end,

  --- 断言抛出错误
  assert_error = function(fn, expected_msg, msg)
    local ok, err = pcall(fn)
    if ok then
      error(string.format("断言失败: %s\n  期望抛出错误, 但未抛出", msg or "应抛出错误"))
    end
    if expected_msg and not string.find(tostring(err), expected_msg, 1, true) then
      error(
        string.format(
          "断言失败: %s\n  期望错误包含: %s\n  实际错误: %s",
          msg or "错误消息不匹配",
          expected_msg,
          tostring(err)
        )
      )
    end
  end,
}

--- 运行单个测试函数并返回结果
--- @param name string 测试名称
--- @param fn function 测试函数
--- @return boolean 是否通过
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

--- 运行一组测试
--- @param tests table { name = function, ... }
--- @return table { passed, failed, errors }
function M.run_tests(tests)
  local results = { passed = 0, failed = 0, errors = {} }
  -- 使用数组格式（按定义顺序执行）或字典格式（按名称排序）
  local ordered_tests = {}
  if #tests > 0 then
    -- 数组格式：{ { name = "test_name", fn = function() end }, ... }
    for _, item in ipairs(tests) do
      table.insert(ordered_tests, item)
    end
  else
    -- 字典格式：{ test_name = function() end, ... }
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
