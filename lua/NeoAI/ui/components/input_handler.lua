local M = {}

local Events = require("NeoAI.core.events.event_constants")

-- 模块状态
local state = {
  initialized = false,
  config = nil,
  current_mode = "normal", -- 'normal', 'insert', 'visual'
  input_buffer = "",
  cursor_position = 0,
  placeholder_text = "输入消息...", -- 输入框占位文本
  is_sending = false, -- 是否正在发送
  show_placeholder = true, -- 是否显示占位文本
}

--- 初始化输入处理器
--- @param config table 配置
function M.initialize(config)
  if state.initialized then
    return
  end

  state.config = config or {}
  state.initialized = true
end

--- 设置按键映射
function M.setup_keymaps()
  if not state.initialized then
    return
  end

  -- 这里可以设置全局按键映射
  -- 目前是空实现，具体映射在窗口模块中设置
end

--- 处理输入
--- @param key string 按键
function M.handle_input(key)
  if not state.initialized then
    return
  end

  if state.current_mode == "insert" then
    M._handle_insert_input(key)
  else
    M._handle_normal_input(key)
  end
end

--- 发送消息
--- @param content string 消息内容
--- @param window_id string|nil 窗口ID
--- @param session_id string|nil 会话ID
function M.send_message(content, window_id, session_id)
  if not state.initialized then
    return false, "输入处理器未初始化"
  end

  if not content or content == "" then
    return false, "消息内容不能为空"
  end

  print("📢 输入处理器发送消息: " .. content)

  -- 触发聊天输入已准备好事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = Events.CHAT_INPUT_READY,
    data = {
      message = content,
      window_id = window_id,
      session_id = session_id,
      timestamp = os.time(),
    },
  })

  print("✓ 聊天输入事件已触发")
  return true, "消息事件已触发"
end

--- 切换到插入模式
function M.switch_to_insert_mode()
  if not state.initialized then
    return
  end

  state.current_mode = "insert"
  state.show_placeholder = false
end

--- 切换到普通模式
function M.switch_to_normal_mode()
  if not state.initialized then
    return
  end

  state.current_mode = "normal"
  if state.input_buffer == "" then
    state.show_placeholder = true
  end
end

--- 获取当前输入内容
--- @return string 输入内容
function M.get_input_buffer()
  return state.input_buffer
end

--- 清空输入缓冲区
function M.clear_input_buffer()
  state.input_buffer = ""
  state.cursor_position = 0
  state.show_placeholder = true
end

--- 设置占位文本
--- @param text string 占位文本
function M.set_placeholder_text(text)
  state.placeholder_text = text or "输入消息..."
end

--- 获取占位文本
--- @return string 占位文本
function M.get_placeholder_text()
  return state.placeholder_text
end

--- 是否显示占位文本
--- @return boolean 是否显示占位文本
function M.should_show_placeholder()
  return state.show_placeholder
end

--- 处理插入模式输入（内部函数）
--- @param key string 按键
local function _handle_insert_input(key)
  -- 简化实现
  if key == "<Esc>" then
    M.switch_to_normal_mode()
  elseif key == "<CR>" then
    -- 回车键发送消息
    local content = state.input_buffer
    if content and content ~= "" then
      -- 这里需要窗口ID和会话ID，暂时使用默认值
      -- 在实际使用中，应该由调用者传递这些参数
      M.send_message(content, "win_default", "default")
      M.clear_input_buffer()
    end
  elseif key == "<BS>" then
    -- 退格键
    if state.cursor_position > 0 then
      state.input_buffer = state.input_buffer:sub(1, state.cursor_position - 1)
        .. state.input_buffer:sub(state.cursor_position + 1)
      state.cursor_position = state.cursor_position - 1
    end
  else
    -- 普通字符输入
    if #key == 1 then
      state.input_buffer = state.input_buffer:sub(1, state.cursor_position)
        .. key
        .. state.input_buffer:sub(state.cursor_position + 1)
      state.cursor_position = state.cursor_position + 1
    end
  end
end

--- 处理普通模式输入（内部函数）
--- @param key string 按键
local function _handle_normal_input(key)
  if key == "i" or key == "I" or key == "a" or key == "A" then
    M.switch_to_insert_mode()
  end
end

-- 将内部函数暴露给模块
M._handle_insert_input = _handle_insert_input
M._handle_normal_input = _handle_normal_input

return M
