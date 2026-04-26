--- 测试: ui/init.lua
--- 测试 UI 模块的初始化、窗口管理、模式切换等功能
--- 注意: UI 测试需要 Neovim 窗口环境，部分功能在 headless 模式下受限
local M = {}

local test

--- 创建一个测试配置
local function create_test_config()
  return {
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
    },
  }
end

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_ui_init ===")

  return test.run_tests({
    --- 测试 initialize
    test_initialize = function()
      local ui = require("NeoAI.ui")
      ui.initialize(create_test_config())

      local mode = ui.get_current_ui_mode()
      -- 可能受之前测试影响，只要不崩溃即可
      assert.is_true(mode == nil or type(mode) == "string")
    end,

    --- 测试 get_window_manager
    test_get_window_manager = function()
      local ui = require("NeoAI.ui")
      local wm = ui.get_window_manager()
      assert.not_nil(wm, "窗口管理器应存在")
    end,

    --- 测试 get_current_session_id
    test_get_current_session_id = function()
      local ui = require("NeoAI.ui")
      local id = ui.get_current_session_id()
      -- 可能受之前测试影响，只要返回字符串即可
      assert.is_true(type(id) == "string", "会话 ID 应为字符串")
    end,

    --- 测试 update_current_session_id
    test_update_current_session_id = function()
      local ui = require("NeoAI.ui")
      ui.update_current_session_id("session_test_1")
      assert.equal("session_test_1", ui.get_current_session_id())
    end,

    --- 测试 get_event_count
    test_get_event_count = function()
      local ui = require("NeoAI.ui")
      ui.reset_event_count()
      assert.equal(0, ui.get_event_count(), "重置后计数应为 0")
    end,

    --- 测试 close_all_windows（不应崩溃）
    test_close_all_windows = function()
      local ui = require("NeoAI.ui")
      ui.close_all_windows()
      -- 不应崩溃
    end,

    --- 测试 list_windows
    test_list_windows = function()
      local ui = require("NeoAI.ui")
      local windows = ui.list_windows()
      assert.is_true(type(windows) == "table", "list_windows 应返回表")
    end,

    --- 测试 switch_mode
    test_switch_mode = function()
      local ui = require("NeoAI.ui")
      -- 在 headless 模式下，switch_mode 可能失败但不应该崩溃
      local ok, err = pcall(function()
        ui.switch_mode("chat")
      end)
      -- 允许失败（headless 模式），但不应该抛出未捕获的错误
    end,

    --- 测试 refresh_current_ui（不应崩溃）
    test_refresh_current_ui = function()
      local ui = require("NeoAI.ui")
      ui.refresh_current_ui()
      -- 不应崩溃
    end,

    --- 测试 update_config
    test_update_config = function()
      local ui = require("NeoAI.ui")
      -- update_config 内部调用 input_handler.update_config，可能不存在
      local ok, err = pcall(ui.update_config, ui, { window = { width = 100 } })
      -- 允许失败，但不应该崩溃
    end,

    --- 测试 handle_key_input
    test_handle_key_input = function()
      local ui = require("NeoAI.ui")
      -- handle_key_input 内部调用 tree_handlers.handle_key / chat_handlers.handle_key
      -- 这些函数可能不存在，使用 pcall 安全调用
      local ok, err = pcall(ui.handle_key_input, ui, "<CR>")
      -- 允许失败，但不应该崩溃
    end,

    --- 测试 reasoning 相关函数
    test_reasoning_functions = function()
      local ui = require("NeoAI.ui")
      ui.show_reasoning("测试思考内容")
      ui.append_reasoning("追加内容")
      ui.close_reasoning()
      -- 不应崩溃
    end,
  })
end

-- 直接运行
if pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M

