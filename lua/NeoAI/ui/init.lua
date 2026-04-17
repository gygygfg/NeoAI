local M = {}

local window_manager = require("NeoAI.ui.window.window_manager")
local chat_window = require("NeoAI.ui.window.chat_window")
local tree_window = require("NeoAI.ui.window.tree_window")
local input_handler = require("NeoAI.ui.components.input_handler")
local history_tree = require("NeoAI.ui.components.history_tree")
local reasoning_display = require("NeoAI.ui.components.reasoning_display")
local tree_handlers = require("NeoAI.ui.handlers.tree_handlers")
local chat_handlers = require("NeoAI.ui.handlers.chat_handlers")

-- 核心模块引用（延迟加载）
local core

-- 模块状态
local state = {
  initialized = false,
  config = nil,
  windows = {},
  current_ui_mode = nil, -- 'tree' 或 'chat'
  event_count = 0,       -- 事件处理计数
  event_bus = nil,       -- 事件总线引用
}

--- 初始化UI模块
--- @param config table 完整配置
--- @return table UI模块实例
function M.initialize(config)
  if state.initialized then
    return M
  end

  state.config = config or {}

  -- 延迟加载核心模块（如果存在）
  local success, loaded_core = pcall(require, "NeoAI.core")
  if success then
    core = loaded_core
  else
    -- 创建模拟核心模块用于测试
    core = {
      get_session_manager = function()
        return {
          get_current_session = function()
            return { id = "test_session" }
          end
        }
      end,
      get_keymap_manager = function()
        return {
          get_keymaps = function()
            return {}
          end
        }
      end,
      get_event_bus = function()
        -- 返回一个模拟的事件总线
        return {
          on = function(event, callback)
            -- 模拟事件监听
          end,
          emit = function(event, ...)
            -- 模拟事件触发
          end
        }
      end
    }
    print("⚠️  核心模块未找到，使用模拟模块进行测试")
  end

  -- 准备窗口管理器配置
  local window_manager_config = state.config.window or {}

  -- 如果配置中有窗口模式，传递给窗口管理器
  if state.config.ui and state.config.ui.window_mode then
    window_manager_config.window_mode = state.config.ui.window_mode
  end

  -- 初始化子模块
  window_manager.initialize(window_manager_config)
  input_handler.initialize(state.config.input or {})
  history_tree.initialize(state.config.tree or {})
  reasoning_display.initialize(state.config.reasoning or {})
  tree_window.initialize(state.config.tree_window or {})
  -- 传递完整配置给聊天窗口，确保虚拟输入框能访问键位配置
  chat_window.initialize(state.config)

  -- 设置事件处理器
  -- 从核心模块获取事件总线
  local event_bus = nil
  if core and core.get_event_bus then
    event_bus = core.get_event_bus()
  end
  
  -- 保存事件总线引用
  state.event_bus = event_bus
  
  tree_handlers.initialize(event_bus, state.config.handlers or {})
  chat_handlers.initialize(event_bus, state.config.handlers or {})

  state.initialized = true
  return M
end

--- 打开树界面
function M.open_tree_ui()
  if not state.initialized then
    error("UI not initialized")
  end

  -- 获取当前会话ID
  local session_manager = core.get_session_manager()
  local current_session = session_manager and session_manager.get_current_session()
  local session_id = current_session and current_session.id or "default"

  -- 关闭现有窗口
  M.close_all_windows()

  -- 打开树窗口
  local tree_win_id = tree_window.open(session_id)
  if tree_win_id then
    state.windows.tree = tree_win_id
    state.current_ui_mode = "tree"

    -- 设置树窗口的按键映射
    tree_window.set_keymaps(core.get_keymap_manager())

    -- 聚焦树窗口
    window_manager.focus_window(tree_win_id)
    
    -- 触发树窗口打开事件
    if state.event_bus and state.event_bus.emit then
      state.event_bus.emit("tree_window_opened", session_id, "main")
    end
  end
end

--- 打开聊天界面
--- @param session_id string 会话ID
--- @param branch_id string 分支ID
function M.open_chat_ui(session_id, branch_id)
  if not state.initialized then
    error("UI not initialized")
  end

  -- 如果没有提供参数，使用默认值
  if not session_id then
    local session_manager = core.get_session_manager()
    local current_session = session_manager and session_manager.get_current_session()
    session_id = current_session and current_session.id or "default"
  end

  if not branch_id then
    branch_id = "main"
  end

  -- 关闭现有窗口
  M.close_all_windows()

  -- 打开聊天窗口
  local chat_win_id = chat_window.open(session_id, branch_id)
  if chat_win_id then
    state.windows.chat = chat_win_id
    state.current_ui_mode = "chat"

    -- 设置聊天窗口的按键映射
    chat_window.set_keymaps(core.get_keymap_manager())

    -- 聚焦聊天窗口
    window_manager.focus_window(chat_win_id)
    
    -- 触发聊天窗口打开事件
    if state.event_bus and state.event_bus.emit then
      state.event_bus.emit("chat_window_opened", session_id, branch_id)
    end
  end
end

--- 关闭所有窗口
function M.close_all_windows()
  if not state.initialized then
    return
  end

  -- 关闭所有窗口
  window_manager.close_all()

  -- 清空状态
  state.windows = {}
  state.current_ui_mode = nil
end

--- 获取当前UI模式
--- @return string|nil 当前UI模式
function M.get_current_ui_mode()
  return state.current_ui_mode
end

--- 获取窗口管理器
--- @return table 窗口管理器
function M.get_window_manager()
  return window_manager
end

--- 获取聊天窗口
--- @return table|nil 聊天窗口
function M.get_chat_window()
  if state.windows.chat then
    return chat_window
  end
  return nil
end

--- 获取树窗口
--- @return table|nil 树窗口
function M.get_tree_window()
  if state.windows.tree then
    return tree_window
  end
  return nil
end

--- 刷新当前界面
function M.refresh_current_ui()
  if not state.current_ui_mode then
    return
  end

  if state.current_ui_mode == "tree" and state.windows.tree then
    tree_window.refresh_tree()
  elseif state.current_ui_mode == "chat" and state.windows.chat then
    chat_window.render_messages()
  end
end

--- 显示思考过程
--- @param content string 思考内容
function M.show_reasoning(content)
  if not state.initialized then
    return
  end

  reasoning_display.show(content)
end

--- 追加思考内容
--- @param content string 思考内容
function M.append_reasoning(content)
  if not state.initialized then
    return
  end

  reasoning_display.append(content)
end

--- 关闭思考显示
function M.close_reasoning()
  if not state.initialized then
    return
  end

  reasoning_display.close()
end

--- 切换界面模式
--- @param mode string 模式 ('tree' 或 'chat')
function M.switch_mode(mode)
  if not state.initialized then
    return
  end

  if mode == "tree" then
    M.open_tree_ui()
  elseif mode == "chat" then
    -- 需要会话和分支信息，这里使用当前或默认值
    M.open_chat_ui()
  end
end

--- 处理按键输入
--- @param key string 按键
function M.handle_key_input(key)
  if not state.initialized then
    return
  end

  -- 增加事件计数
  state.event_count = (state.event_count or 0) + 1
  
  -- 记录事件处理
  print(string.format("UI事件处理: 按键=%s, 计数=%d", key, state.event_count))
  
  -- 如果没有当前UI模式，只记录事件但不处理
  if not state.current_ui_mode then
    print("⚠️  没有当前UI模式，仅记录事件")
    return
  end
  
  -- 避免无限递归，直接调用处理器而不通过handle_key_input
  if state.current_ui_mode == "tree" then
    -- 直接调用树形视图处理器的内部处理逻辑
    if key == "<CR>" then
      tree_handlers.handle_enter()
    elseif key == "n" then
      tree_handlers.handle_n()
    elseif key == "N" then
      tree_handlers.handle_N()
    elseif key == "d" then
      tree_handlers.handle_d()
    elseif key == "D" then
      tree_handlers.handle_D()
    elseif key == "r" then
      tree_handlers.handle_refresh()
    elseif key == "k" then
      tree_handlers.handle_up()
    elseif key == "j" then
      tree_handlers.handle_down()
    elseif key == "h" then
      tree_handlers.handle_left()
    elseif key == "l" then
      tree_handlers.handle_right()
    end
  elseif state.current_ui_mode == "chat" then
    -- 直接调用聊天处理器的内部处理逻辑
    if key == "<CR>" then
      chat_handlers.handle_enter()
    elseif key == "<C-s>" then
      chat_handlers.handle_ctrl_s()
    elseif key == "<Esc>" then
      chat_handlers.handle_escape()
    elseif key == "<Tab>" then
      chat_handlers.handle_tab()
    elseif key == "r" then
      chat_handlers.handle_regenerate()
    elseif key == "<C-c>" then
      chat_handlers.handle_stop_generation()
    elseif key == "t" then
      chat_handlers.handle_toggle_reasoning()
    end
  end
end

--- 更新配置
--- @param new_config table 新配置
function M.update_config(new_config)
  if not state.initialized then
    return
  end

  state.config = vim.tbl_extend("force", state.config, new_config or {})

  -- 更新子模块配置
  local window_manager_config = state.config.window or {}
  -- 如果配置中有窗口模式，传递给窗口管理器
  if state.config.window_mode then
    window_manager_config.window_mode = state.config.window_mode
  end
  window_manager.update_config(window_manager_config)
  input_handler.update_config(state.config.input or {})

  -- 刷新当前界面
  M.refresh_current_ui()
end

--- 列出所有窗口
--- @return table 窗口列表
function M.list_windows()
  if not state.initialized then
    return {}
  end

  local windows = {}
  for window_type, window_id in pairs(state.windows) do
    -- 通过 window_manager 获取实际的窗口句柄
    local win_handle = window_manager.get_window_win(window_id)
    if win_handle and vim.api.nvim_win_is_valid(win_handle) then
      table.insert(windows, win_handle)
    elseif window_id then
      -- 如果无法获取窗口句柄，记录调试信息
      vim.notify(string.format("无法获取窗口句柄 for %s: %s", window_type, window_id), vim.log.levels.DEBUG)
    end
  end
  return windows
end

--- 获取事件处理计数
--- @return number 事件处理数量
function M.get_event_count()
  return state.event_count or 0
end

--- 重置事件计数
function M.reset_event_count()
  state.event_count = 0
end

return M

