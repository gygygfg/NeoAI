local M = {}

local logger = require("NeoAI.utils.logger")
local window_manager = require("NeoAI.ui.window.window_manager")
local chat_window = require("NeoAI.ui.window.chat_window")
local tree_window = require("NeoAI.ui.window.tree_window")
local input_handler = require("NeoAI.ui.components.input_handler")
local history_tree = require("NeoAI.ui.components.history_tree")
local reasoning_display = require("NeoAI.ui.components.reasoning_display")
local tree_handlers = require("NeoAI.ui.handlers.tree_handlers")
local chat_handlers = require("NeoAI.ui.handlers.chat_handlers")
local Events = require("NeoAI.core.events")
local state_manager = require("NeoAI.core.config.state")

local state = {
  initialized = false, windows = {}, current_ui_mode = nil,
  current_session_id = nil, event_count = 0,
}

-- ========== 辅助 ==========

local function get_hm()
  local ok, hm = pcall(require, "NeoAI.core.history_manager")
  return ok and hm or nil
end

local function resolve_session_id(session_id)
  if session_id and session_id ~= "default" then return session_id end
  local hm = get_hm()
  if hm and hm.is_initialized() then
    local current = hm.get_current_session()
    if current then return current.id end
  end
  return "default"
end

local function open_window(window_type, session_id, branch_id)
  local config = state_manager.get_config()
  local win_type_map = { tree = "tree", chat = "chat" }
  local titles = { tree = "NeoAI 会话树", chat = "NeoAI 聊天" }

  -- 关闭对立的窗口
  local other = window_type == "chat" and "tree" or "chat"
  if state.windows[other] then
    if other == "chat" then chat_window.close() else tree_window.close() end
    state.windows[other] = nil
  end

  local win_id = window_manager.create_window(window_type, {
    title = titles[window_type],
    width = config.width or (window_type == "chat" and 80 or 60),
    height = config.height or (window_type == "chat" and 20 or 25),
    border = config.border or "rounded",
  })

  if not win_id then return false end

  local open_fn = window_type == "chat" and chat_window.open or tree_window.open
  local success = open_fn(session_id, win_id, branch_id)
  if not success then
    window_manager.close_window(win_id)
    return false
  end

  state.windows[window_type] = win_id
  state.current_ui_mode = window_type
  if window_type == "chat" then state.current_session_id = session_id end

  local set_keymaps = window_type == "chat" and chat_window.set_keymaps or tree_window.set_keymaps
  set_keymaps()
  window_manager.focus_window(win_id)

  local event = window_type == "chat" and Events.CHAT_WINDOW_OPENED or Events.TREE_WINDOW_OPENED
  vim.api.nvim_exec_autocmds("User", { pattern = event, data = { session_id, branch_id or "main" } })
  return true
end

-- ========== 初始化 ==========

function M.initialize(config)
  if state.initialized then return M end
  local window_config = vim.deepcopy(config.window or {})
  if config.ui and config.ui.window_mode then window_config.window_mode = config.ui.window_mode end

  window_manager.initialize(window_config)
  input_handler.initialize(config.input or {})
  history_tree.initialize(config)
  reasoning_display.initialize(config.reasoning or {})
  tree_window.initialize(config)
  chat_window.initialize(config)
  tree_handlers.initialize(config)
  chat_handlers.initialize(config.handlers or {})
  M._register_event_listeners()
  state.initialized = true
  return M
end

-- ========== UI 打开 ==========

function M.open_tree_ui()
  if not state.initialized then error("UI not initialized") end
  local session_id = resolve_session_id(state.current_session_id)
  open_window("tree", session_id)
end

function M.open_chat_ui(session_id, branch_id)
  if not state.initialized then error("UI not initialized") end
  local hm = get_hm()
  if (not session_id or session_id == "default") and hm and hm.is_initialized() then
    session_id = hm.create_session("聊天会话", true, nil)
  end
  session_id = session_id or state.current_session_id or "default"
  open_window("chat", session_id, branch_id or "main")
end

-- ========== 窗口管理 ==========

function M.close_all_windows()
  if not state.initialized then return end
  window_manager.close_all()
  state.windows = {}
  state.current_ui_mode = nil
end

function M.get_current_ui_mode() return state.current_ui_mode end
function M.get_window_manager() return window_manager end

function M.get_chat_window()
  return state.windows.chat and chat_window or nil
end

function M.get_tree_window()
  return state.windows.tree and tree_window or nil
end

function M.refresh_current_ui()
  if state.current_ui_mode == "tree" and state.windows.tree then
    tree_window.refresh_tree()
  elseif state.current_ui_mode == "chat" and state.windows.chat then
    chat_window.render_chat()
  end
end

-- ========== Reasoning ==========

function M.show_reasoning(content)
  if state.initialized then reasoning_display.show(content) end
end

function M.append_reasoning(content)
  if state.initialized then reasoning_display.append(content) end
end

function M.close_reasoning()
  if state.initialized then reasoning_display.close() end
end

-- ========== 事件监听 ==========

function M._register_event_listeners()
  local function refresh_tree()
    if state.current_ui_mode == "tree" and state.windows.tree then tree_window.refresh_tree() end
  end
  local function refresh_chat()
    if state.current_ui_mode == "chat" and state.windows.chat then chat_window.render_chat() end
  end

  vim.api.nvim_create_autocmd("User", {
    pattern = Events.SESSION_CREATED,
    callback = function(args)
      local data = args.data or {}
      state.current_session_id = data.session_id
      if state.current_ui_mode == "chat" and state.windows.chat then
        chat_window.update_title((data.session or {}).name or "新会话")
      end
      refresh_tree()
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    pattern = Events.SESSION_LOADED,
    callback = function(args)
      local data = args.data or {}
      state.current_session_id = data.new_session_id
      if state.current_ui_mode == "chat" and state.windows.chat then
        chat_window.update_title((data.session or {}).name or "加载的会话")
      end
      refresh_tree()
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    pattern = Events.SESSION_DELETED,
    callback = function(args)
      if state.current_session_id == (args.data or {}).session_id then
        state.current_session_id = nil
      end
      refresh_tree()
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    pattern = Events.SESSION_CHANGED,
    callback = function(args)
      local data = args.data or {}
      state.current_session_id = data.session_id
      local session = data.session or {}
      if state.current_ui_mode == "chat" and state.windows.chat then
        chat_window.update_title(session.name or "会话")
        chat_window.render_chat()
      end
      refresh_tree()
    end,
  })

  for _, event in ipairs({ Events.BRANCH_CREATED, Events.BRANCH_DELETED }) do
    vim.api.nvim_create_autocmd("User", { pattern = event, callback = refresh_tree })
  end

  vim.api.nvim_create_autocmd("User", {
    pattern = Events.BRANCH_SWITCHED,
    callback = function() refresh_chat(); refresh_tree() end,
  })

  vim.api.nvim_create_autocmd("User", {
    pattern = Events.MESSAGE_ADDED,
    callback = refresh_chat,
  })
end

-- ========== 模式切换 ==========

function M.switch_mode(mode)
  if not state.initialized then return end
  if mode == "tree" then
    M.open_tree_ui()
  elseif mode == "chat" then
    M.open_chat_ui(state.current_session_id or "default", "main")
  end
end

function M.handle_key_input(key)
  if not state.initialized or not state.current_ui_mode then return end
  state.event_count = state.event_count + 1
  if state.current_ui_mode == "tree" then
    tree_handlers.handle_key(key)
  elseif state.current_ui_mode == "chat" then
    chat_handlers.handle_key(key)
  end
end

-- ========== 配置 ==========

function M.update_config(new_config)
  if not state.initialized then return end
  local config = state_manager.get_config()
  local merged = vim.tbl_extend("force", config, new_config or {})
  local window_config = merged.window or {}
  if merged.window_mode then window_config.window_mode = merged.window_mode end
  window_manager.update_config(window_config)
  input_handler.update_config(merged.input or {})
  M.refresh_current_ui()
end

-- ========== 窗口列表 ==========

function M.list_windows()
  if not state.initialized then return {} end
  local windows = {}
  for window_type, window_id in pairs(state.windows) do
    local win_handle = window_manager.get_window_win(window_id)
    if win_handle and vim.api.nvim_win_is_valid(win_handle) then
      table.insert(windows, win_handle)
    elseif window_id then
      vim.notify(string.format("无法获取窗口句柄 for %s: %s", window_type, window_id), vim.log.levels.DEBUG)
    end
  end
  return windows
end

-- ========== 会话 ID ==========

function M.get_current_session_id()
  return state.current_session_id or "default"
end

function M.update_current_session_id(session_id)
  if not state.initialized then return end
  state.current_session_id = session_id
  vim.api.nvim_exec_autocmds("User", {
    pattern = Events.UI_SESSION_UPDATED,
    data = { session_id = session_id },
  })
end

-- ========== 事件计数 ==========

function M.get_event_count() return state.event_count or 0 end
function M.reset_event_count() state.event_count = 0 end

return M
