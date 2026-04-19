local M = {}
local MODULE_NAME = "NeoAI.ui.window.chat_window"

local window_manager = require("NeoAI.ui.window.window_manager")

-- 模块状态
local state = {
  initialized = false,
  config = nil,
  current_window_id = nil, -- 当前聊天窗口的窗口ID
  current_session_id = nil, -- 当前聊天窗口关联的会话ID
  messages = {},
  cursor_augroup = nil, -- 光标移动自动命令组
}

--- 初始化聊天窗口
--- @param config table 配置
function M.initialize(config)
  if state.initialized then
    return
  end
  state.config = config or {}
  state.initialized = true
end

--- 打开聊天窗口
--- @param session_id string 会话ID
--- @param window_id string 窗口ID（必须由调用者通过 window_manager 创建）
--- @param branch_id string 分支ID（可选，仅用于兼容旧版本）
--- @return boolean 是否成功
function M.open(session_id, window_id, branch_id)
  if not state.initialized then
    error("Chat window not initialized")
  end

  -- 检查 window_id 参数
  if not window_id or type(window_id) ~= "string" then
    error("window_id parameter is required and must be a string")
  end

  -- 验证窗口ID格式
  if not window_id:match("^win_") then
    error("Invalid window_id format. Must start with 'win_'")
  end

  -- 如果已有窗口，先关闭
  if state.current_window_id then
    M.close()
  end

  -- 处理旧版本兼容：如果第二个参数是branch_id而不是window_id
  if branch_id and type(branch_id) == "string" and branch_id:match("^win_") then
    -- 旧版本调用方式：open(session_id, window_id)
    window_id = branch_id
    branch_id = "main"
  end

  state.current_window_id = window_id
  state.current_session_id = session_id
  state.messages = {}

  -- 触发窗口打开事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = "NeoAI:window_opening", data = { window_id = window_id, window_type = "chat" } }
  )
  state.current_session_id = session_id
  state.messages = {}

  -- 获取缓冲区并设置选项
  local buf = window_manager.get_window_buf(window_id)
  if buf then
    -- 设置缓冲区选项
    vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
    vim.api.nvim_set_option_value("wrap", true, { buf = buf })
    vim.api.nvim_set_option_value("linebreak", true, { buf = buf })
    local win_handle = window_manager.get_window_win(window_id)
    if win_handle then
      vim.api.nvim_set_option_value("cursorline", true, { win = win_handle })
    end
  end

  -- 触发窗口打开事件
  vim.api.nvim_exec_autocmds("User", { pattern = "NeoAI:window_opened", data = { window_id = window_id } })

  -- 加载消息数据
  M._load_messages(session_id)

  -- 渲染聊天内容
  M.render_chat()

  -- 触发聊天框打开事件
  vim.api.nvim_exec_autocmds("User", { pattern = "NeoAI:chat_box_opened", data = { window_id = window_id } })

  return true
end

--- 渲染聊天内容
function M.render_chat()
  if not state.current_window_id then
    return
  end

  -- 触发开始渲染对话事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = "NeoAI:dialogue_rendering_start", data = { window_id = state.current_window_id } }
  )

  local content = {}

  -- 添加标题
  table.insert(content, "# NeoAI 聊天")
  table.insert(content, "")
  table.insert(content, string.format("会话: %s", state.current_session_id or "未知"))
  table.insert(content, "---")
  table.insert(content, "")

  -- 添加消息
  if #state.messages == 0 then
    table.insert(content, "暂无消息")
    table.insert(content, "输入消息开始聊天...")
  else
    for _, msg in ipairs(state.messages) do
      local role_prefix = msg.role == "user" and "👤 用户:" or "🤖 AI:"
      table.insert(content, string.format("%s %s", role_prefix, msg.content))
      table.insert(content, "")
    end
  end

  -- 添加分隔线和输入提示
  table.insert(content, "---")
  table.insert(content, "按 'i' 进入插入模式输入消息")
  table.insert(content, "按 'q' 退出聊天窗口")

  -- 设置窗口内容
  window_manager.set_window_content(state.current_window_id, content)

  -- 触发渲染完成事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = "NeoAI:rendering_complete", data = { window_id = state.current_window_id } }
  )

  -- 触发对话渲染完成事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = "NeoAI:dialogue_rendering_complete", data = { window_id = state.current_window_id } }
  )
end

--- 刷新聊天窗口
function M.refresh_chat()
  if not state.current_window_id then
    return
  end

  -- 重新加载数据
  M._load_messages(state.current_session_id)

  -- 重新渲染
  M.render_chat()
end

--- 设置按键映射
--- @param keymap_manager table|nil 键位配置管理器
function M.set_keymaps(keymap_manager)
  if not state.current_window_id then
    return
  end

  local buf = window_manager.get_window_buf(state.current_window_id)
  if not buf then
    return
  end

  -- 清除现有映射
  local existing_maps = vim.api.nvim_buf_get_keymap(buf, "n")
  for _, map in ipairs(existing_maps) do
    vim.api.nvim_buf_del_keymap(buf, "n", map.lhs)
  end

  -- 获取键位配置
  local keymaps = {}

  if keymap_manager then
    -- 从键位配置管理器获取
    local chat_keymaps = keymap_manager.get_context_keymaps("chat")
    if chat_keymaps then
      -- 映射到内部键位名称，使用配置的值或默认值
      keymaps = {
        insert = chat_keymaps.insert and chat_keymaps.insert.key or "i",
        quit = chat_keymaps.quit and chat_keymaps.quit.key or "q",
        refresh = chat_keymaps.refresh and chat_keymaps.refresh.key or "r",
        send = chat_keymaps.send and chat_keymaps.send.key or "<CR>",
      }
    else
      keymaps = state.config.keymaps or M._get_default_keymaps()
    end
  else
    keymaps = state.config.keymaps or M._get_default_keymaps()
  end

  -- 使用闭包创建局部函数引用，避免每次按键都调用 require
  -- 这些函数形成闭包，可以访问外部作用域的 M 模块
  -- 使用 vim.keymap.set() 直接传递函数，性能更好且消除 LSP 警告
  local function enter_insert_mode()
    M._enter_insert_mode()
  end

  local function close_window()
    M.close()
  end

  local function refresh_chat_window()
    M.refresh_chat()
  end

  local function send_message()
    M._send_message()
  end

  local function exit_insert_mode()
    M._exit_insert_mode()
  end

  -- 设置按键映射（使用 vim.keymap.set 直接传递函数）
  for key, mapping in pairs(keymaps) do
    local callback = nil
    if key == "insert" then
      callback = enter_insert_mode
    elseif key == "quit" then
      callback = close_window
    elseif key == "refresh" then
      callback = refresh_chat_window
    elseif key == "send" then
      callback = send_message
    end

    if callback then
      vim.keymap.set("n", mapping, callback, { buffer = buf, noremap = true, silent = true })
    end
  end

  -- 设置插入模式映射
  vim.keymap.set("i", "<Esc>", exit_insert_mode, { buffer = buf, noremap = true, silent = true })
end

--- 获取默认键位配置
--- @return table 默认键位配置
function M._get_default_keymaps()
  return {
    insert = "i",
    quit = "q",
    refresh = "r",
    send = "<CR>",
  }
end

--- 进入插入模式（内部函数）
function M._enter_insert_mode()
  if not state.current_window_id then
    return
  end

  local win_handle = window_manager.get_window_win(state.current_window_id)
  if win_handle and vim.api.nvim_win_is_valid(win_handle) then
    vim.api.nvim_set_current_win(win_handle)
    vim.api.nvim_command("startinsert")
  end
end

--- 退出插入模式（内部函数）
function M._exit_insert_mode()
  if not state.current_window_id then
    return
  end

  local win_handle = window_manager.get_window_win(state.current_window_id)
  if win_handle and vim.api.nvim_win_is_valid(win_handle) then
    vim.api.nvim_command("stopinsert")
  end
end

--- 发送消息（内部函数）
function M._send_message()
  if not state.current_window_id then
    return
  end

  local buf = window_manager.get_window_buf(state.current_window_id)
  if not buf then
    return
  end

  -- 获取当前行内容
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local last_line = lines[#lines] or ""

  -- 如果最后一行不是空行，处理消息
  if vim.trim(last_line) ~= "" then
    -- 触发聊天框发送事件
    vim.api.nvim_exec_autocmds(
      "User",
      { pattern = "NeoAI:chat_box_sending", data = { window_id = state.current_window_id, message = last_line } }
    )

    -- 添加用户消息到聊天记录
    table.insert(state.messages, {
      role = "user",
      content = last_line,
      timestamp = os.time(),
    })

    -- 触发聊天框发送完成事件
    vim.api.nvim_exec_autocmds(
      "User",
      { pattern = "NeoAI:chat_box_sent", data = { window_id = state.current_window_id, message = last_line } }
    )

    -- 重新渲染聊天以显示用户消息
    M.render_chat()

    -- 调用聊天处理器发送消息，触发AI响应
    local chat_handlers_loaded, chat_handlers = pcall(require, "NeoAI.ui.handlers.chat_handlers")
    if chat_handlers_loaded and type(chat_handlers) == "table" and chat_handlers.send_message then
      -- 异步调用发送消息，避免阻塞UI
      vim.defer_fn(function()
        local success, result = chat_handlers.send_message(last_line)
        if not success then
          print("⚠️  发送消息失败: " .. tostring(result))
          
          -- 显示错误消息
          M.show_floating_text("发送消息失败: " .. tostring(result), {
            timeout = 3000,
            position = "center",
            border = "single",
          })
        else
          print("✓ 消息已发送到AI引擎: " .. tostring(result))
        end
      end, 10)
    else
      print("⚠️  聊天处理器未加载，无法发送消息到AI引擎")
      
      -- 模拟AI响应作为后备
      vim.defer_fn(function()
        local simulated_response = "聊天处理器未加载，这是模拟AI响应。"
        local success = M.add_message("assistant", simulated_response)
        if success then
          print("✓ 模拟AI响应已添加")
        end
      end, 1000)
    end
  end
end

--- 加载消息数据（内部函数）
--- @param session_id string 会话ID
function M._load_messages(session_id)
  -- 这里应该从会话管理器加载消息数据
  -- 目前使用模拟数据
  state.messages = {
    {
      role = "user",
      content = "你好，请帮我写一个Lua函数",
      timestamp = os.time() - 3600,
    },
    {
      role = "assistant",
      content = '当然！这是一个简单的Lua函数示例:\n\n```lua\nfunction greet(name)\n  return "Hello, " .. name .. "!"\nend\n```',
      timestamp = os.time() - 3590,
    },
    {
      role = "user",
      content = "谢谢，这个函数很好用",
      timestamp = os.time() - 1800,
    },
    {
      role = "assistant",
      content = "不客气！如果你需要更多帮助，请随时告诉我。",
      timestamp = os.time() - 1790,
    },
  }
end

--- 关闭聊天窗口
function M.close()
  if not state.current_window_id then
    return
  end

  -- 检查聊天框是否真的打开
  local win_handle = window_manager.get_window_win(state.current_window_id)
  if not win_handle or not vim.api.nvim_win_is_valid(win_handle) then
    -- 窗口已关闭，清理状态但不触发事件
    state.current_window_id = nil
    state.current_session_id = nil
    state.messages = {}
    return
  end

  -- 触发窗口关闭前事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = "NeoAI:window_closing", data = { window_id = state.current_window_id } }
  )

  -- 触发聊天框关闭事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = "NeoAI:chat_box_closing", data = { window_id = state.current_window_id } }
  )

  window_manager.close_window(state.current_window_id)

  -- 清理自动命令组
  if state.cursor_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.cursor_augroup)
    state.cursor_augroup = nil
  end

  state.current_window_id = nil
  state.current_session_id = nil
  state.messages = {}

  -- 触发窗口关闭事件
  vim.api.nvim_exec_autocmds("User", { pattern = "NeoAI:window_closed", data = { window_id = state.current_window_id } })

  -- 触发聊天框关闭完成事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = "NeoAI:chat_box_closed", data = { window_id = state.current_window_id } }
  )
end

--- 更新配置
--- @param new_config table 新配置
function M.update_config(new_config)
  if not state.initialized then
    return
  end

  state.config = vim.tbl_extend("force", state.config, new_config or {})

  -- 如果窗口打开，重新设置按键映射
  if state.current_window_id then
    M.set_keymaps()
    M.render_chat()
  end
end

--- 刷新聊天窗口
--- @return boolean 是否成功
function M.refresh()
  if not state.initialized then
    return false
  end

  if not state.current_window_id then
    return false
  end

  -- 重新渲染聊天
  M.render_chat()
  return true
end

--- 检查聊天窗口是否已打开
--- @return boolean 是否已打开
function M.is_open()
  if not state.initialized then
    return false
  end

  return state.current_window_id ~= nil
end

--- 发送消息（公共接口）
--- @param message string 消息内容
--- @return boolean 是否成功
--- @return string|nil 结果信息
function M.send_message(message)
  if not state.initialized then
    return false, "聊天窗口未初始化"
  end

  if not message or vim.trim(message) == "" then
    return false, "消息内容不能为空"
  end

  -- 首先添加用户消息
  local success = M.add_message("user", message)
  if not success then
    return false, "无法添加用户消息"
  end
  
  -- 调用内部发送消息函数（这会触发AI响应）
  M._send_message()
  
  return true, "消息已发送"
end

--- 添加消息到聊天
--- @param role string 角色 ('user' 或 'assistant')
--- @param content string 消息内容
--- @return boolean 是否成功
function M.add_message(role, content)
  if not state.initialized then
    return false
  end

  if role ~= "user" and role ~= "assistant" then
    return false
  end

  if not content or vim.trim(content) == "" then
    return false
  end

  -- 触发消息添加事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = "NeoAI:message_adding", data = { window_id = state.current_window_id, role = role, content = content } }
  )

  table.insert(state.messages, {
    role = role,
    content = content,
    timestamp = os.time(),
  })

  -- 触发消息添加完成事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = "NeoAI:message_added", data = { window_id = state.current_window_id, role = role, content = content } }
  )

  -- 如果窗口打开，更新显示
  if state.current_window_id then
    M.render_chat()
  end

  return true
end

--- 显示悬浮文本
--- @param text string 要显示的文本
--- @param opts table|nil 选项
function M.show_floating_text(text, opts)
  if not state.current_window_id then
    return false
  end

  opts = opts or {}
  local win_handle = window_manager.get_window_win(state.current_window_id)

  if not win_handle or not vim.api.nvim_win_is_valid(win_handle) then
    return false
  end

  -- 触发显示悬浮文本事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = "NeoAI:floating_text_showing",
    data = {
      window_id = state.current_window_id,
      text = text,
    },
  })

  -- 这里可以实现实际的悬浮文本显示逻辑
  -- 例如使用 nvim_open_win 创建浮动窗口

  -- 触发显示悬浮文本完成事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = "NeoAI:floating_text_shown",
    data = {
      window_id = state.current_window_id,
      text = text,
    },
  })

  return true
end

--- 关闭悬浮文本
function M.close_floating_text()
  if not state.current_window_id then
    return false
  end

  -- 触发关闭悬浮文本事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = "NeoAI:floating_text_closing", data = {
      window_id = state.current_window_id,
    } }
  )

  -- 这里可以实现实际的悬浮文本关闭逻辑

  -- 触发关闭悬浮文本完成事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = "NeoAI:floating_text_closed", data = {
      window_id = state.current_window_id,
    } }
  )

  return true
end

return M
