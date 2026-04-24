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
  current_session_id = nil, -- 当前会话ID
  event_count = 0, -- 事件处理计数
}

--- 初始化UI模块
--- @param config table 完整配置
--- @return table UI模块实例
function M.initialize(config)
  if state.initialized then
    return M
  end

  state.config = config or {}

  -- 延迟加载核心模块（如果存在），但UI模块不应该直接依赖核心模块
  -- 改为通过事件通信，这里只保留必要的接口
  local success, loaded_core = pcall(require, "NeoAI.core")
  if success then
    core = loaded_core
  else
    -- 创建最小化的核心接口，UI模块不应该直接调用核心业务逻辑
    core = {
      -- 只提供UI层需要的接口，不包含业务逻辑
      get_keymap_manager = function()
        -- 键位配置是UI层需要的
        return {
          get_keymaps = function()
            return {}
          end,
        }
      end,
    }
    print("⚠️  核心模块未找到，UI模块使用最小化接口")
  end

  -- 准备窗口管理器配置
  local window_manager_config = state.config.window or {}

  -- 如果配置中有窗口模式，传递给窗口管理器
  if state.config.ui and state.config.ui.window_mode then
    window_manager_config.window_mode = state.config.ui.window_mode
  end

  -- 初始化历史管理器
  local ok, hm = pcall(require, "NeoAI.core.history_manager")
  if ok then
    hm.initialize({
      config = state.config,
      event_bus = nil,
    })
  end

  -- 设置事件处理器
  -- 初始化子模块
  window_manager.initialize(window_manager_config)
  input_handler.initialize(state.config.input or {})
  -- 传递完整配置给 history_tree，确保能访问 session.save_path
  history_tree.initialize(state.config)
  reasoning_display.initialize(state.config.reasoning or {})
  -- 传递完整配置给 tree_window，确保能访问 session.save_path
  tree_window.initialize(state.config)
  -- 传递完整配置给聊天窗口，确保虚拟输入框能访问键位配置
  chat_window.initialize(state.config)

  tree_handlers.initialize(state.config.handlers or {})
  chat_handlers.initialize(state.config.handlers or {})

  -- 注册事件监听器
  M._register_event_listeners()

  state.initialized = true
  return M
end

--- 打开树界面
function M.open_tree_ui()
  if not state.initialized then
    error("UI not initialized")
  end

  -- 获取当前会话ID
  local ok, hm = pcall(require, "NeoAI.core.history_manager")
  local session_id = state.current_session_id
  if (not session_id or session_id == "default") and ok and hm.is_initialized() then
    local current = hm.get_current_session()
    if current then
      session_id = current.id
    end
  end
  if not session_id then
    session_id = "default"
  end

  -- 只关闭已有的聊天窗口，保留树窗口
  if state.windows.chat then
    chat_window.close()
    state.windows.chat = nil
  end

  -- 先创建窗口
  local tree_win_id = window_manager.create_window("tree", {
    title = "NeoAI 会话树",
    width = state.config.width or 60,
    height = state.config.height or 25,
    border = state.config.border or "rounded",
  })

  if tree_win_id then
    -- 打开树窗口，传递窗口ID
    local success = tree_window.open(session_id, tree_win_id)
    if success then
      state.windows.tree = tree_win_id
      state.current_ui_mode = "tree"

      -- 设置树窗口的按键映射
      tree_window.set_keymaps(core.get_keymap_manager())

      -- 聚焦树窗口
      window_manager.focus_window(tree_win_id)

      -- 触发树窗口打开事件
      vim.api.nvim_exec_autocmds("User", {
        pattern = "NeoAI:tree_window_opened",
        data = { session_id, "main" },
      })
    else
      -- 如果打开失败，关闭窗口
      window_manager.close_window(tree_win_id)
      tree_win_id = nil
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

  -- 确保历史管理器已初始化
  local ok, hm = pcall(require, "NeoAI.core.history_manager")
  if ok and not hm.is_initialized() then
    hm.initialize({ config = state.config })
  end

  -- 如果没有传入 session_id（从 :NeoAIOpen 或快捷键直接打开），
  -- 强制创建一个新的根会话，这样每次打开都是全新的根分支
  if not session_id or session_id == "default" then
    if ok and hm.is_initialized() then
      session_id = hm.create_session("聊天会话", true, nil)
    else
      -- 回退：使用当前会话ID
      session_id = state.current_session_id
      if (not session_id or session_id == "default") and ok and hm.is_initialized() then
        local current = hm.get_current_session()
        if current then
          session_id = current.id
        end
      end
      if not session_id then
        session_id = "default"
      end
    end
  end

  if not branch_id then
    branch_id = "main"
  end

  -- 只关闭已有的树窗口，保留聊天窗口
  if state.windows.tree then
    tree_window.close()
    state.windows.tree = nil
  end

  -- 先创建聊天窗口
  local chat_win_id = window_manager.create_window("chat", {
    title = "NeoAI 聊天",
    width = state.config.width or 80,
    height = state.config.height or 20,
    border = state.config.border or "rounded",
  })

  if chat_win_id then
    -- 打开聊天窗口，传递窗口ID
    local success = chat_window.open(session_id, chat_win_id, branch_id)
    if success then
      state.windows.chat = chat_win_id
      state.current_ui_mode = "chat"
      state.current_session_id = session_id -- 更新当前会话ID

      -- 设置聊天窗口的按键映射
      chat_window.set_keymaps(core.get_keymap_manager())

      -- 聚焦聊天窗口
      window_manager.focus_window(chat_win_id)

      -- 触发聊天窗口打开事件
      vim.api.nvim_exec_autocmds("User", {
        pattern = "NeoAI:chat_window_opened",
        data = { session_id, branch_id },
      })
    else
      -- 如果打开失败，关闭窗口
      window_manager.close_window(chat_win_id)
      chat_win_id = nil
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
    chat_window.render_chat()
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

--- 注册事件监听器（内部使用）
function M._register_event_listeners()
  -- 辅助函数：刷新树窗口（如果打开）
  local function refresh_tree_if_open()
    if state.current_ui_mode == "tree" and state.windows.tree then
      tree_window.refresh_tree()
    end
  end

  -- 辅助函数：刷新聊天窗口（如果打开）
  local function refresh_chat_if_open()
    if state.current_ui_mode == "chat" and state.windows.chat then
      chat_window.render_chat()
    end
  end

  -- 监听会话事件
  vim.api.nvim_create_autocmd("User", {
    pattern = "NeoAI:session_created",
    callback = function(args)
      local data = args.data or {}
      state.current_session_id = data.session_id
      if state.current_ui_mode == "chat" and state.windows.chat then
        chat_window.update_title((data.session or {}).name or "新会话")
      end
      refresh_tree_if_open()
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    pattern = "NeoAI:session_loaded",
    callback = function(args)
      local data = args.data or {}
      state.current_session_id = data.new_session_id
      if state.current_ui_mode == "chat" and state.windows.chat then
        chat_window.update_title((data.session or {}).name or "加载的会话")
      end
      refresh_tree_if_open()
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    pattern = "NeoAI:session_deleted",
    callback = function(args)
      local data = args.data or {}
      if state.current_session_id == data.session_id then
        state.current_session_id = nil
      end
      refresh_tree_if_open()
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    pattern = "NeoAI:session_changed",
    callback = function(args)
      local data = args.data or {}
      state.current_session_id = data.session_id
      local session = data.session or {}
      if state.current_ui_mode == "chat" and state.windows.chat then
        chat_window.update_title(session.name or "会话")
        chat_window.render_chat()
      end
      refresh_tree_if_open()
    end,
  })

  -- 监听分支事件
  vim.api.nvim_create_autocmd("User", {
    pattern = "NeoAI:branch_created",
    callback = function()
      refresh_tree_if_open()
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    pattern = "NeoAI:branch_switched",
    callback = function()
      refresh_chat_if_open()
      refresh_tree_if_open()
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    pattern = "NeoAI:branch_deleted",
    callback = function()
      refresh_tree_if_open()
    end,
  })

  -- 监听消息事件
  vim.api.nvim_create_autocmd("User", {
    pattern = "NeoAI:message_added",
    callback = function()
      refresh_chat_if_open()
    end,
  })
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
    M.open_chat_ui(state.current_session_id or "default", state.current_branch_id or "main")
  end
end

--- 处理按键输入
--- 按键映射已由 tree_window.set_keymaps() 和 chat_window.set_keymaps()
--- 通过 keymap_manager 在缓冲区级别注册，此函数仅保留用于兼容
--- @param key string 按键
function M.handle_key_input(key)
  if not state.initialized then
    return
  end

  state.event_count = (state.event_count or 0) + 1

  if not state.current_ui_mode then
    return
  end

  if state.current_ui_mode == "tree" then
    tree_handlers.handle_key(key)
  elseif state.current_ui_mode == "chat" then
    chat_handlers.handle_key(key)
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
      local debug_level = vim.log.levels and vim.log.levels.DEBUG or "DEBUG"
      vim.notify(string.format("无法获取窗口句柄 for %s: %s", window_type, window_id), debug_level)
    end
  end

  return windows
end

--- 获取当前会话ID
--- @return string|nil 当前会话ID
function M.get_current_session_id()
  if not state.initialized then
    return nil
  end

  -- UI层不应该直接调用核心模块的会话管理器
  -- 改为通过状态管理获取会话信息
  return state.current_session_id or "default"
end

--- 更新当前会话ID
--- @param session_id string 会话ID
function M.update_current_session_id(session_id)
  if not state.initialized then
    return
  end

  state.current_session_id = session_id

  -- 触发会话更新事件，通知其他模块
  vim.api.nvim_exec_autocmds("User", {
    pattern = "NeoAI:ui_session_updated",
    data = { session_id = session_id },
  })
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
