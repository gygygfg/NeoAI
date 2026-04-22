local M = {}
local MODULE_NAME = "NeoAI.ui.window.chat_window"

local window_manager = require("NeoAI.ui.window.window_manager")
local virtual_input = require("NeoAI.ui.components.virtual_input")

-- 模块状态
local state = {
  initialized = false,
  config = nil,
  current_window_id = nil, -- 当前聊天窗口的窗口ID
  current_session_id = nil, -- 当前聊天窗口关联的会话ID
  messages = {},
  cursor_augroup = nil, -- 光标移动自动命令组
  last_render_time = 0, -- 上次渲染时间
  render_debounce_timer = nil, -- 防抖定时器
}

--- 初始化聊天窗口
--- @param config table 配置
function M.initialize(config)
  if state.initialized then
    return
  end
  state.config = config or {}
  state.initialized = true

  -- 初始化虚拟输入组件
  virtual_input.initialize(config)

  -- 注册AI响应事件监听器
  M._setup_event_listeners()
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

  -- 获取缓冲区并设置选项
  local buf = window_manager.get_window_buf(window_id)
  local win_handle = window_manager.get_window_win(window_id)

  if buf then
    -- 设置缓冲区选项
    vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
  end

  if win_handle then
    -- 设置窗口选项（wrap 和 linebreak 都是窗口本地选项）
    vim.api.nvim_set_option_value("wrap", true, { win = win_handle })
    vim.api.nvim_set_option_value("linebreak", true, { win = win_handle })
    vim.api.nvim_set_option_value("cursorline", true, { win = win_handle })
  end

  -- 触发窗口打开事件
  vim.api.nvim_exec_autocmds("User", { pattern = "NeoAI:window_opened", data = { window_id = window_id } })

  -- 加载消息数据
  M._load_messages(session_id)

  -- 渲染聊天内容
  M.render_chat()

  -- 触发聊天框打开事件
  vim.api.nvim_exec_autocmds("User", { pattern = "NeoAI:chat_box_opened", data = { window_id = window_id } })

  -- 调整窗口位置，确保不在屏幕最下方
  M._adjust_window_position()

  -- 自动获取焦点
  M._focus_window()

  -- 自动打开虚拟输入框
  vim.defer_fn(function()
    M._open_virtual_input()
  end, 100) -- 延迟100ms，确保窗口完全打开

  return true
end

--- 渲染聊天内容
function M.render_chat()
  if not state.current_window_id then
    return
  end

  -- 防抖处理：避免频繁渲染
  local now = vim.loop.now()
  if now - state.last_render_time < 100 then -- 100毫秒内不重复渲染
    -- 取消之前的定时器
    if state.render_debounce_timer then
      state.render_debounce_timer:stop()
      state.render_debounce_timer:close()
      state.render_debounce_timer = nil
    end
    
    -- 设置新的定时器
    state.render_debounce_timer = vim.loop.new_timer()
    state.render_debounce_timer:start(100, 0, vim.schedule_wrap(function()
      state.render_debounce_timer:close()
      state.render_debounce_timer = nil
      M._do_render_chat()
    end))
    return
  end
  
  state.last_render_time = now
  M._do_render_chat()
end

--- 实际执行渲染聊天内容
function M._do_render_chat()
  if not state.current_window_id then
    return
  end

  -- 使用异步渲染，避免阻塞主线程
  vim.schedule(function()
    -- 触发开始渲染对话事件
    vim.api.nvim_exec_autocmds(
      "User",
      { pattern = "NeoAI:dialogue_rendering_start", data = { window_id = state.current_window_id } }
    )

    -- 使用异步工作器在后台构建内容
    local async_worker = require("NeoAI.utils.async_worker")

    async_worker.submit_task("render_chat_content", function()
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

          -- 处理消息内容中的换行符
          local msg_lines = vim.split(msg.content or "", "\n")

          -- 添加第一行（带角色前缀）
          if #msg_lines > 0 then
            table.insert(content, string.format("%s %s", role_prefix, msg_lines[1]))

            -- 添加剩余的行（不带角色前缀）
            for i = 2, #msg_lines do
              table.insert(content, string.format("    %s", msg_lines[i]))
            end
          else
            table.insert(content, string.format("%s", role_prefix))
          end

          table.insert(content, "")
        end
      end

      -- 添加分隔线和输入提示
      table.insert(content, "---")
      table.insert(content, "按 'i' 进入插入模式输入消息")
      table.insert(content, "按 'q' 退出聊天窗口")

      return content
    end, function(success, content)
      if success and content then
        -- 设置窗口内容
        window_manager.set_window_content(state.current_window_id, content)

        -- 调整窗口位置，确保不在屏幕最下方
        M._adjust_window_position()

        -- 自动获取焦点
        M._focus_window()

        -- 注意：虚拟输入框已经在 open() 函数中打开，这里不需要重复打开

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
      else
        print("❌ 聊天内容渲染失败")
      end
    end)
  end)
end

--- 异步渲染聊天内容（非阻塞版本）
--- @param callback function|nil 回调函数
function M.render_chat_async(callback)
  if not state.current_window_id then
    if callback then
      callback(false, "没有活动的聊天窗口")
    end
    return
  end

  -- 使用异步工作器
  local async_worker = require("NeoAI.utils.async_worker")

  async_worker.submit_task("render_chat_async", function()
    -- 在后台线程中构建内容
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

    return content
  end, function(success, content)
    if success and content then
      -- 使用vim.schedule确保在合适的时机更新UI
      vim.schedule(function()
        window_manager.set_window_content(state.current_window_id, content)
        -- 调整窗口位置，确保不在屏幕最下方
        M._adjust_window_position()
        -- 自动获取焦点
        M._focus_window()
        -- 打开虚拟输入框
        vim.defer_fn(function()
          M._open_virtual_input()
        end, 50)
      end)

      if callback then
        callback(true, "聊天内容渲染完成")
      end
    else
      if callback then
        callback(false, "聊天内容渲染失败")
      end
    end
  end)
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
    if not state.current_window_id then
      print("⚠️  聊天窗口未打开")
      return
    end

    local buf = window_manager.get_window_buf(state.current_window_id)
    if not buf then
      print("⚠️  无法获取聊天窗口缓冲区")
      return
    end

    -- 获取缓冲区最后一行内容
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local last_line = lines[#lines] or ""

    -- 如果最后一行不是空行，发送消息
    if vim.trim(last_line) ~= "" then
      M.send_message(last_line)
    else
      print("⚠️  消息内容不能为空")
    end
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

--- 获取窗口焦点（内部函数）
function M._focus_window()
  if not state.current_window_id then
    return
  end

  local win_handle = window_manager.get_window_win(state.current_window_id)
  if win_handle and vim.api.nvim_win_is_valid(win_handle) then
    vim.api.nvim_set_current_win(win_handle)
    return true
  end
  return false
end

--- 调整窗口位置（内部函数）
--- 确保窗口不在屏幕最下方
function M._adjust_window_position()
  if not state.current_window_id then
    return
  end

  local win_handle = window_manager.get_window_win(state.current_window_id)
  if not win_handle or not vim.api.nvim_win_is_valid(win_handle) then
    return
  end

  -- 获取窗口配置
  local win_config = vim.api.nvim_win_get_config(win_handle)
  if not win_config or win_config.relative == "" then
    -- 不是浮动窗口，不需要调整
    return
  end

  -- 获取屏幕尺寸
  local screen_height = vim.o.lines
  local screen_width = vim.o.columns

  -- 获取窗口尺寸
  local win_height = win_config.height or 20
  local win_width = win_config.width or 80

  -- 获取当前位置
  local current_row = win_config.row or 0

  -- 检查窗口是否在屏幕底部（距离底部小于10%）
  local bottom_threshold = screen_height * 0.9
  if current_row + win_height > bottom_threshold then
    -- 调整位置到屏幕中央偏上
    local new_row = math.floor(screen_height * 0.2)
    local new_col = math.floor((screen_width - win_width) / 2)

    -- 更新窗口位置
    win_config.row = new_row
    win_config.col = new_col

    -- 应用新的窗口配置
    vim.api.nvim_win_set_config(win_handle, win_config)

    print("📊 调整聊天窗口位置到屏幕中央偏上")
  end
end

--- 打开虚拟输入框（内部函数）
function M._open_virtual_input()
  if not state.current_window_id then
    return false
  end

  local win_handle = window_manager.get_window_win(state.current_window_id)
  if not win_handle or not vim.api.nvim_win_is_valid(win_handle) then
    return false
  end

  -- 检查虚拟输入框是否已经打开
  local virtual_input = require("NeoAI.ui.components.virtual_input")
  if virtual_input.is_active() then
    print("⚠️  虚拟输入框已经打开，跳过重复打开")
    return true
  end

  -- 打开虚拟输入框
  local success = virtual_input.open(win_handle, {
    placeholder = "输入消息...",
    on_submit = function(content)
      -- 当用户提交消息时，通过聊天处理器发送消息
      if content and content ~= "" then
        -- 获取聊天处理器
        local chat_handlers_loaded, chat_handlers = pcall(require, "NeoAI.ui.handlers.chat_handlers")
        if chat_handlers_loaded and chat_handlers then
          -- 调用新的 send_message 函数
          local success, result = chat_handlers.send_message(
            content,
            state.current_session_id or "default",
            "main",
            state.current_window_id,
            true -- 格式化消息
          )

          if not success then
            print("⚠️  发送消息失败: " .. tostring(result))
          end
        else
          print("⚠️  无法加载聊天处理器")
        end
      end
    end,
    on_cancel = function()
      -- 当用户取消时，不执行任何操作
      -- 虚拟输入框保持打开状态
    end,
    on_change = function(content)
      -- 可以在这里处理内容变化
      -- print("内容变化:", content)
    end,
  })

  if success then
    print("📝 虚拟输入框已打开")
    return true
  else
    print("⚠️  无法打开虚拟输入框")
    return false
  end
end

--- 加载消息数据（内部函数）
--- @param session_id string 会话ID
function M._load_messages(session_id)
  -- 这里应该从会话管理器加载消息数据
  -- 目前保持空数据
  state.messages = {}
end

--- 异步加载消息数据（内部函数）
--- @param session_id string 会话ID
--- @param callback function 回调函数
function M._load_messages_async(session_id, callback)
  -- 使用异步工作器
  local async_worker = require("NeoAI.utils.async_worker")

  async_worker.submit_task("load_chat_messages", function()
    -- 在后台线程中加载消息数据
    -- 这里应该从会话管理器加载消息数据
    -- 目前保持空数据
    local messages = {}

    return messages
  end, function(success, messages, error_msg)
    if callback then
      if success then
        callback(messages)
      else
        -- 如果异步失败，回退到同步版本
        M._load_messages(session_id)
        callback(state.messages)
      end
    end
  end)
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

  -- 关闭虚拟输入框（只在聊天界面关闭时才关闭，使用force模式）
  virtual_input.close("force")

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
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = "NeoAI:window_closed", data = { window_id = state.current_window_id } }
  )

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

--- 更新聊天窗口标题
--- @param title string 新标题
function M.update_title(title)
  if not state.current_window_id then
    return
  end

  local win_handle = window_manager.get_window_win(state.current_window_id)
  if not win_handle or not vim.api.nvim_win_is_valid(win_handle) then
    return
  end

  -- 更新浮动窗口标题（Neovim 0.9+ 支持通过 nvim_win_set_config 更新 title）
  local ok, err = pcall(vim.api.nvim_win_set_config, win_handle, { title = title })
  if not ok then
    -- 如果 nvim_win_set_config 不支持 title 参数（旧版本 Neovim），静默忽略
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

--- 检查聊天窗口是否可用（兼容旧版本）
--- @return boolean 是否可用
function M.is_available()
  return M.is_open()
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

  -- 触发统一的消息发送事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = "NeoAI:message_sent",
    data = {
      message = message,
      window_id = state.current_window_id,
      session_id = state.current_session_id,
      timestamp = os.time(),
      role = "user",
    },
  })

  -- print("✓ 用户消息已发送，等待AI响应...")

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

  -- 持久化消息到 session_manager 和 history_manager
  M._persist_message(role, content)

  -- 如果窗口打开，更新显示
  if state.current_window_id then
    M.render_chat()
  end

  return true
end

--- 触发自动保存（内部函数）
function M._trigger_auto_save()
  -- 直接调用会话管理器的内部保存函数
  local session_mgr_loaded, session_mgr = pcall(require, "NeoAI.core.session.session_manager")
  if session_mgr_loaded and session_mgr then
    -- 使用pcall安全调用内部函数
    pcall(function()
      -- 检查是否有保存函数
      if session_mgr._save_sessions then
        session_mgr._save_sessions()
      end
    end)
  end
  
  -- 同时触发历史管理器的保存
  local history_mgr_loaded, history_mgr = pcall(require, "NeoAI.core.history_manager")
  if history_mgr_loaded and history_mgr then
    pcall(function()
      -- 检查历史管理器是否有保存函数
      if history_mgr.save_sessions then
        history_mgr.save_sessions()
      elseif history_mgr._save_sessions then
        history_mgr._save_sessions()
      end
    end)
  end
end

--- 持久化消息到存储系统（内部函数）
--- @param role string 角色 ('user' 或 'assistant')
--- @param content string 消息内容
function M._persist_message(role, content)
  -- 保存到 session_manager 的 message_manager
  local session_mgr_loaded, session_mgr = pcall(require, "NeoAI.core.session.session_manager")
  if session_mgr_loaded and session_mgr and session_mgr.is_initialized and session_mgr.is_initialized() then
    local current_session = session_mgr.get_current_session()
    if current_session and current_session.current_branch then
      local msg_mgr = session_mgr.get_message_manager()
      if msg_mgr then
        pcall(msg_mgr.add_message, msg_mgr, current_session.current_branch, role, content, {
          timestamp = os.time(),
          window_id = state.current_window_id,
        })
      end
    end
  end

  -- 同步到 tree_manager，确保树视图能显示新消息
  local tree_mgr_loaded, tree_mgr = pcall(require, "NeoAI.core.session.tree_manager")
  if tree_mgr_loaded and tree_mgr and tree_mgr.is_initialized and tree_mgr.is_initialized() then
    pcall(tree_mgr.sync_from_session_manager)
  end

  -- 保存到 history_manager
  local history_mgr_loaded, history_mgr = pcall(require, "NeoAI.core.history_manager")
  if history_mgr_loaded and history_mgr then
    local current_session = history_mgr.get_current_session()
    if not current_session then
      pcall(history_mgr.create_session, "聊天会话")
    end
    pcall(history_mgr.add_message, role, content, {
      timestamp = os.time(),
      window_id = state.current_window_id,
    })
  end
  
  -- 触发自动保存
  M._trigger_auto_save()
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

--- 设置事件监听器（内部函数）
function M._setup_event_listeners()
  -- 注意：AI响应完成事件现在由聊天处理器（chat_handlers.lua）处理
  -- 以实现前后端分离，避免重复添加AI响应

  -- 监听AI响应已准备好事件（新的事件系统）

  -- 监听AI响应已准备好事件（新的事件系统）
  vim.api.nvim_create_autocmd("User", {
    pattern = "NeoAI:ai_response_ready",
    callback = function(args)
      print("📢 收到AI响应已准备好事件")
      local data = args.data or {}
      local response = data.response
      local window_id = data.window_id
      local session_id = data.session_id

      -- 检查是否是当前窗口的消息
      if window_id and window_id ~= state.current_window_id then
        print("⚠️  响应不是给当前窗口的，忽略")
        return
      end

      -- 提取响应内容
      local response_content = ""
      if type(response) == "string" then
        response_content = response
      elseif type(response) == "table" and response.content then
        response_content = response.content
      elseif type(response) == "table" and response.text then
        response_content = response.text
      else
        response_content = tostring(response)
      end

      -- 添加AI响应到聊天窗口
      if response_content and response_content ~= "" then
        print("➕ 添加AI响应到聊天窗口 (新事件系统)...")
        local success = M.add_message("assistant", response_content)
        if success then
          print("✓ AI响应已添加到聊天窗口")
          -- 重新渲染聊天窗口
          M.render_chat()
        else
          print("✗ 添加AI响应失败")
        end
      else
        print("⚠️  响应内容为空，无法添加")
      end
    end,
  })

  -- 监听消息发送事件（用于更新UI状态）
  vim.api.nvim_create_autocmd("User", {
    pattern = "NeoAI:message_sent",
    callback = function(args)
      -- print("📢 收到消息发送事件")
      local data = args.data or {}
      local message = data.message
      local window_id = data.window_id
      local session_id = data.session_id
      local role = data.role or "user"

      -- 检查是否是当前窗口的消息
      if window_id and window_id ~= state.current_window_id then
        print("⚠️  消息不是给当前窗口的，忽略")
        return
      end

      -- print("✓ " .. role .. "消息已发送: " .. (message or ""))
    end,
  })

  -- 监听AI流式响应事件
  vim.api.nvim_create_autocmd("User", {
    pattern = "NeoAI:ai_response_chunk",
    callback = function(args)
      local data = args.data or {}
      local chunk = data.chunk
      local generation_id = data.generation_id

      -- 提取块内容
      local chunk_content = ""
      if type(chunk) == "string" then
        chunk_content = chunk
      elseif type(chunk) == "table" and chunk.content then
        chunk_content = chunk.content
      elseif type(chunk) == "table" and chunk.text then
        chunk_content = chunk.text
      elseif type(chunk) == "table" and chunk.delta then
        chunk_content = chunk.delta
      else
        chunk_content = tostring(chunk)
      end

      -- 对于流式响应，我们可以更新最后一条消息或显示进度
      if chunk_content and chunk_content ~= "" then
        -- 这里可以显示悬浮文本或更新最后一条消息
        M.show_floating_text("AI正在思考... " .. chunk_content, {
          timeout = 2000,
          position = "bottom",
        })
      end
    end,
  })

  -- 监听流式生成完成事件
  vim.api.nvim_create_autocmd("User", {
    pattern = "NeoAI:stream_completed",
    callback = function(args)
      local data = args.data or {}
      local generation_id = data.generation_id

      print("✓ 流式生成完成 (ID: " .. tostring(generation_id) .. ")")

      -- 关闭悬浮文本
      M.close_floating_text()
    end,
  })

  -- 监听生成取消事件
  vim.api.nvim_create_autocmd("User", {
    pattern = "NeoAI:generation_cancelled",
    callback = function(args)
      local data = args.data or {}
      local generation_id = data.generation_id

      print("⚠️  AI生成已取消 (ID: " .. tostring(generation_id) .. ")")

      -- 显示取消通知
      M.show_floating_text("AI生成已取消", {
        timeout = 3000,
        position = "center",
        border = "single",
      })
    end,
  })
end

return M
