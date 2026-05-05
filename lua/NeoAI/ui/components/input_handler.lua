-- 输入处理器（保留兼容，实际输入由 virtual_input 组件处理）
local M = {}
local Events = require("NeoAI.core.events")
local state_manager = require("NeoAI.core.config.state")

local state = {
  initialized = false, config = nil,
  current_mode = "normal", input_buffer = "",
  cursor_position = 0, is_sending = false,
  placeholder_text = "输入消息...", show_placeholder = true,
}

function M.initialize(config)
  if state.initialized then return end
  state.config = config or {}
  state.initialized = true

  -- 注册状态切片
  state_manager.register_slice("input_handler", {
    config = state.config,
    current_mode = "normal",
    input_buffer = "",
    is_sending = false,
  })
end

function M.setup_keymaps() end

function M.handle_input(key)
  if not state.initialized then return end
  if state.current_mode == "insert" then M._handle_insert_input(key) else M._handle_normal_input(key) end
end

function M.send_message(content, window_id, session_id)
  if not state.initialized or not content or content == "" then return false, "消息内容不能为空" end
  vim.api.nvim_exec_autocmds("User", {
    pattern = Events.CHAT_INPUT_READY,
    data = { message = content, window_id = window_id, session_id = session_id, timestamp = os.time() },
  })
  return true, "消息事件已触发"
end

function M.switch_to_insert_mode() state.current_mode = "insert"; state.show_placeholder = false end
function M.switch_to_normal_mode() state.current_mode = "normal"; if state.input_buffer == "" then state.show_placeholder = true end end
function M.get_input_buffer() return state.input_buffer end
function M.clear_input_buffer() state.input_buffer = ""; state.cursor_position = 0; state.show_placeholder = true end
function M.set_placeholder_text(text) state.placeholder_text = text or "输入消息..." end
function M.get_placeholder_text() return state.placeholder_text end
function M.should_show_placeholder() return state.show_placeholder end

function M._handle_insert_input(key)
  if key == "<Esc>" then M.switch_to_normal_mode()
  elseif key == "<CR>" then
    local content = state.input_buffer
    if content and content ~= "" then M.send_message(content, "win_default", "default"); M.clear_input_buffer() end
  elseif key == "<BS>" and state.cursor_position > 0 then
    state.input_buffer = state.input_buffer:sub(1, state.cursor_position - 1) .. state.input_buffer:sub(state.cursor_position + 1)
    state.cursor_position = state.cursor_position - 1
  elseif #key == 1 then
    state.input_buffer = state.input_buffer:sub(1, state.cursor_position) .. key .. state.input_buffer:sub(state.cursor_position + 1)
    state.cursor_position = state.cursor_position + 1
  end
end

function M._handle_normal_input(key)
  if vim.tbl_contains({ "i", "I", "a", "A" }, key) then M.switch_to_insert_mode() end
end

return M
