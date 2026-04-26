local M = {}
local MODULE_NAME = "NeoAI.ui.window.chat_window"

local window_manager = require("NeoAI.ui.window.window_manager")
local virtual_input = require("NeoAI.ui.components.virtual_input") -- 内联输入模式
local Events = require("NeoAI.core.events.event_constants")

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

  -- 当前场景内使用的模型候选索引（1-based）
  current_model_index = 1,

  -- 最近一次生成的 token 用量信息
  last_usage = nil,
  -- token 用量虚拟文本的 extmark id，用于清理旧虚拟文本
  usage_extmark_id = nil,

  -- 流式渲染状态
  streaming = {
    active = false,
    generation_id = nil,
    message_index = nil, -- 当前正在流式更新的消息索引
    content_buffer = "", -- 累积的流式内容
    reasoning_buffer = "", -- 累积的思考内容
    reasoning_active = false, -- 是否正在输出思考内容
    reasoning_done = false, -- 思考内容是否已完成
  },

  -- 工具调用悬浮显示状态
  tool_display = {
    active = false,
    window_id = nil,
    buffer = "", -- 累积的工具调用内容
    results = {}, -- 所有工具调用结果，用于生成折叠文本
  },
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
    { pattern = Events.WINDOW_OPENING, data = { window_id = window_id, window_type = "chat" } }
  )

  -- 获取缓冲区并设置选项
  local buf = window_manager.get_window_buf(window_id)
  local win_handle = window_manager.get_window_win(window_id)

  if buf then
    -- 设置缓冲区选项
    vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
    -- 确保buffer在:ls中可见但不会产生保存警告
    vim.api.nvim_set_option_value("buflisted", true, { buf = buf })
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
    vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
    vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
    vim.api.nvim_set_option_value("modified", false, { buf = buf })
    -- 设置缓冲区名称，便于识别
    vim.api.nvim_buf_set_name(buf, "neoai://chat/" .. session_id)
  end

  if win_handle then
    -- 设置窗口选项（wrap 和 linebreak 都是窗口本地选项）
    vim.api.nvim_set_option_value("wrap", true, { win = win_handle })
    vim.api.nvim_set_option_value("linebreak", true, { win = win_handle })
    vim.api.nvim_set_option_value("cursorline", true, { win = win_handle })
    -- 折叠相关选项全部是窗口本地选项
    vim.api.nvim_set_option_value("foldmethod", "marker", { win = win_handle })
    vim.api.nvim_set_option_value("foldmarker", "{{{,}}}", { win = win_handle })
    vim.api.nvim_set_option_value("foldlevel", 0, { win = win_handle })
    vim.api.nvim_set_option_value("foldenable", true, { win = win_handle })
  end

  -- 触发窗口打开事件
  vim.api.nvim_exec_autocmds("User", { pattern = Events.WINDOW_OPENED, data = { window_id = window_id } })

  -- 加载消息数据
  M._load_messages(session_id)

  -- 渲染聊天内容
  M.render_chat()

  -- 渲染完成后添加 token 用量信息
  vim.defer_fn(function()
    M._update_usage_virt_text()
  end, 500)

  -- 更新窗口标题显示模型信息
  local model_label = M._get_current_model_label()
  if model_label then
    M.update_title(string.format("NeoAI 聊天 [%s]", model_label))
  end

  -- 触发聊天框打开事件
  vim.api.nvim_exec_autocmds("User", { pattern = Events.CHAT_BOX_OPENED, data = { window_id = window_id } })

  -- 自动获取焦点
  M._focus_window()

  -- 设置按键映射
  M.set_keymaps()

  -- 打开浮动虚拟输入框
  vim.defer_fn(function()
    M._open_float_input()
  end, 100)

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
    state.render_debounce_timer:start(
      100,
      0,
      vim.schedule_wrap(function()
        state.render_debounce_timer:close()
        state.render_debounce_timer = nil
        M._do_render_chat()
      end)
    )
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
      { pattern = Events.DIALOGUE_RENDERING_START, data = { window_id = state.current_window_id } }
    )

    -- 使用异步工作器在后台构建内容
    local async_worker = require("NeoAI.utils.async_worker")

    async_worker.submit_task("render_chat_content", function()
      local content = {}

      -- 添加标题
      table.insert(content, "# NeoAI 聊天")
      table.insert(content, "")
      table.insert(content, string.format("会话: %s", state.current_session_id or "未知"))
      -- 显示当前模型信息
      local model_label = M._get_current_model_label()
      if model_label then
        table.insert(content, string.format("模型: %s", model_label))
      end
      table.insert(content, "---")
      table.insert(content, "")

      -- 添加消息
      if #state.messages == 0 then
        table.insert(content, "暂无消息")
        table.insert(content, "输入消息开始聊天...")
      else
        for _, msg in ipairs(state.messages) do
          local role_prefix = msg.role == "user" and "👤 用户:" or "🤖 AI:"

          -- 检查是否是AI消息且包含思考过程
          local has_reasoning = false
          local reasoning_content = ""
          local main_content = msg.content or ""

          -- 尝试解析消息中的思考过程（如果消息是JSON格式）
          if msg.role == "assistant" and type(msg.content) == "string" then
            local json_ok, parsed = pcall(vim.json.decode, msg.content)
            if json_ok and type(parsed) == "table" then
              if parsed.reasoning_content and parsed.reasoning_content ~= "" then
                has_reasoning = true
                reasoning_content = parsed.reasoning_content
                main_content = parsed.content or ""
              end
            end
          end

          -- 检查是否是工具调用折叠文本
          local is_tool_call = false
          if msg.role == "assistant" and type(msg.content) == "string" then
            local trimmed = vim.trim(msg.content)
            if trimmed:find("^{{{%s*🔧 工具调用") then
              is_tool_call = true
            end
          end

          if is_tool_call then
            -- 工具调用折叠文本：不加 AI 标记，直接显示
            local msg_lines = vim.split(main_content, "\n")
            for _, line in ipairs(msg_lines) do
              table.insert(content, line)
            end
          elseif has_reasoning then
            -- 显示思考过程（使用 Neovim 原生折叠标记）
            -- 折叠标记 {{{ 和 }}} 必须位于行首才能被 foldmethod=marker 识别
            table.insert(content, string.format("%s", role_prefix))
            table.insert(content, "")
            -- 折叠标记在行首，后面的文本是折叠后显示的摘要
            -- 注意：{{{ 必须位于行首，所以前面不能有任何字符
            table.insert(content, "{{{ 🤔 思考过程")

            -- 添加思考内容（缩进显示，4空格缩进使折叠后视觉效果更好）
            local reasoning_lines = vim.split(reasoning_content, "\n")
            for _, line in ipairs(reasoning_lines) do
              table.insert(content, "    " .. line)
            end

            table.insert(content, "}}}")
            table.insert(content, "")

            -- 显示正文内容
            if main_content and main_content ~= "" then
              local main_lines = vim.split(main_content, "\n")
              for _, line in ipairs(main_lines) do
                table.insert(content, line)
              end
            end
          else
            -- 普通消息显示
            local msg_lines = vim.split(main_content, "\n")

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
          end

          table.insert(content, "")
        end
      end

      -- 不添加分隔线和输入提示（由内联输入区域替代）

      return content
    end, function(success, content)
      -- 使用 vim.schedule 确保在主线程执行，避免阻塞
      vim.schedule(function()
        if success and content then
          -- 在设置内容前保存光标所在行号，用于渲染后推算新光标位置
          -- 同时判断光标是否在缓冲区末尾附近（最后5行内）
          -- 注意：这个判断必须在 set_window_content 之前完成，使用旧的总行数
          -- 如果在 set_window_content 之后判断，新内容增加了行数会导致误判
          local saved_cursor_lnum = nil
          local saved_cursor_col = 0
          local cursor_near_end = false
          local win_handle = window_manager.get_window_win(state.current_window_id)
          if win_handle and vim.api.nvim_win_is_valid(win_handle) then
            local cursor = vim.api.nvim_win_get_cursor(win_handle)
            saved_cursor_lnum = cursor[1]
            saved_cursor_col = cursor[2]
            local buf = vim.api.nvim_win_get_buf(win_handle)
            local total_lines = vim.api.nvim_buf_line_count(buf)
            if total_lines - saved_cursor_lnum <= 5 then
              cursor_near_end = true
            end
          end

          -- 设置窗口内容
          window_manager.set_window_content(state.current_window_id, content)

          -- 自动获取焦点
          M._focus_window()

          -- 延迟恢复光标位置并处理滚动，确保在 set_window_content 内部的 zMzx（10ms）之后执行
          -- 将光标恢复和滚动合并到同一个 defer_fn 中，避免时序竞争
          vim.defer_fn(function()
            local win = window_manager.get_window_win(state.current_window_id)
            if not win or not vim.api.nvim_win_is_valid(win) then
              return
            end
            local buf = vim.api.nvim_win_get_buf(win)
            local new_line_count = vim.api.nvim_buf_line_count(buf)

            if saved_cursor_lnum then
              local new_lnum
              if cursor_near_end then
                -- 刷新前光标在最后5行之内，恢复到最末尾
                new_lnum = new_line_count
              else
                -- 不在最后5行之内，恢复到原位置（取较小值避免越界）
                new_lnum = math.min(saved_cursor_lnum, new_line_count)
              end
              -- 获取该行内容，确保列不越界
              local lines = vim.api.nvim_buf_get_lines(buf, new_lnum - 1, new_lnum, false)
              local col = math.min(saved_cursor_col, #(lines[1] or ""))
              pcall(vim.api.nvim_win_set_cursor, win, { new_lnum, col })
            end

            -- 判断是否需要滚动到底部：
            -- 1. 工具调用活跃时（state.tool_display.active），不强制滚动，避免长折叠文本把页面顶到上面
            -- 2. 如果用户光标在末尾附近（最后5行内），自动跟随滚动
            -- 3. 生成完成后的渲染由 GENERATION_COMPLETED 回调统一处理滚动和打开输入框
            local should_scroll = false
            if not state.last_usage and not state.tool_display.active then
              if cursor_near_end then
                should_scroll = true
              end
            end

            if should_scroll then
              M._scroll_to_end_with_offset()

              -- 滚动完成后，再打开浮动虚拟输入框
              -- 流式过程中不打开，避免干扰用户查看输出
              if not state.streaming.active then
                M._open_float_input()
              end
            end
          end, 50)

          -- 触发渲染完成事件
          vim.api.nvim_exec_autocmds(
            "User",
            { pattern = Events.RENDERING_COMPLETE, data = { window_id = state.current_window_id } }
          )

          -- 触发对话渲染完成事件
          vim.api.nvim_exec_autocmds(
            "User",
            { pattern = Events.DIALOGUE_RENDERING_COMPLETE, data = { window_id = state.current_window_id } }
          )
        else
          print("❌ 聊天内容渲染失败")
        end
      end)
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

    -- 不添加分隔线和输入提示（由内联输入区域替代）

    return content
  end, function(success, content)
    if success and content then
      -- 使用vim.schedule确保在合适的时机更新UI
      vim.schedule(function()
        window_manager.set_window_content(state.current_window_id, content)
        -- 自动获取焦点
        M._focus_window()
        -- 仅在非流式状态下打开浮动虚拟输入框
        if not state.streaming.active then
          M._open_float_input()
        end
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
function M.set_keymaps()
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

  -- 从合并后的配置中获取 chat 上下文键位
  local chat_config = (state.config.keymaps or {}).chat or {}
  local keymaps = {
    insert = (chat_config.insert or {}).key or "i",
    quit = (chat_config.quit or {}).key or "q",
    refresh = (chat_config.refresh or {}).key or "r",
    send = (chat_config.send or {}).normal and chat_config.send.normal.key or (chat_config.send or {}).key or "<CR>",
    switch_model = (chat_config.switch_model or {}).key or "m",
    cancel = (chat_config.cancel or {}).key or "<Esc>",
  }

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

    local chat_buf = window_manager.get_window_buf(state.current_window_id)
    if not chat_buf then
      print("⚠️  无法获取聊天窗口缓冲区")
      return
    end

    -- 获取缓冲区最后一行内容
    local lines = vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false)
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

  local function switch_model()
    M.show_model_selector()
  end

  local function cancel_generation()
    vim.api.nvim_exec_autocmds("User", {
      pattern = Events.CANCEL_GENERATION,
      data = {},
    })
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
    elseif key == "switch_model" then
      callback = switch_model
    elseif key == "cancel" then
      callback = cancel_generation
    end

    if callback then
      vim.keymap.set("n", mapping, callback, { buffer = buf, noremap = true, silent = true })
    end
  end

  -- 设置插入模式映射（Esc：取消生成或退出插入模式）
  vim.keymap.set("i", "<Esc>", function()
    vim.api.nvim_exec_autocmds("User", {
      pattern = Events.CANCEL_GENERATION,
      data = {},
    })
    exit_insert_mode()
  end, { buffer = buf, noremap = true, silent = true, desc = "取消生成或退出插入模式" })
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
    pcall(vim.api.nvim_set_current_win, win_handle)
    return true
  end
  return false
end

--- 调整窗口位置（内部函数）
--- 已禁用：用户喜欢屏幕最下方的虚拟输入框
function M._adjust_window_position()
  -- 不执行任何操作，保持窗口在屏幕底部
end

--- 打开浮动虚拟输入框（内部函数）
function M._open_float_input()
  if not state.current_window_id then
    return
  end

  -- 如果已激活，跳过
  if virtual_input.is_active() then
    return
  end

  local win_handle = window_manager.get_window_win(state.current_window_id)
  if not win_handle or not vim.api.nvim_win_is_valid(win_handle) then
    return
  end

  -- 打开浮动虚拟输入框
  virtual_input.open(win_handle, {
    placeholder = "输入消息...",
    on_submit = function(content)
      if content and content ~= "" then
        local chat_handlers_loaded, chat_handlers = pcall(require, "NeoAI.ui.handlers.chat_handlers")
        if chat_handlers_loaded and chat_handlers then
          local success, result = chat_handlers.send_message(
            content,
            state.current_session_id or "default",
            "main",
            state.current_window_id,
            true,
            function(async_success, async_result, async_error)
              if not async_success then
                print("✗ 异步消息发送失败: " .. tostring(async_error or async_result))
                M.show_floating_text("发送消息失败: " .. tostring(async_error or async_result), {
                  timeout = 3000,
                  position = "center",
                  border = "single",
                })
              end
            end
          )
          if not success then
            print("⚠️  启动异步消息发送失败: " .. tostring(result))
            M.show_floating_text("启动发送失败: " .. tostring(result), {
              timeout = 3000,
              position = "center",
              border = "single",
            })
          else
            M.show_floating_text("消息发送中...", { timeout = 1000, position = "bottom" })
          end
        end
      end
    end,
    on_cancel = function() end,
    on_change = function(content) end,
  })
end

--- 显示悬浮文本

--- 加载消息数据（内部函数）
--- @param session_id string 会话ID
function M._load_messages(session_id)
  state.messages = {}
  local ok, hm = pcall(require, "NeoAI.core.history_manager")
  if not ok or not hm.is_initialized() then
    -- 尝试初始化
    local config = state.config or {}
    local save_path = config.session and config.session.save_path
    if not save_path then
      save_path = vim.fn.stdpath("cache") .. "/NeoAI"
    end
    hm.initialize({ config = { save_path = save_path } })
  end
  -- 重新获取
  ok, hm = pcall(require, "NeoAI.core.history_manager")
  if not ok or not hm.is_initialized() then
    return
  end

  local target_id = session_id or hm.get_current_session() and hm.get_current_session().id
  if not target_id then
    return
  end

  -- 使用 get_context_and_new_parent 获取上下文路径
  -- 注意：get_context_and_new_parent 内部使用 get_messages，会解包 JSON 格式的 assistant 消息
  -- 我们需要保留原始 JSON 格式以便渲染思考过程的折叠标记
  -- 加载当前会话的 usage 信息
  local current_session = hm.get_session(target_id)
  if current_session and current_session.usage and next(current_session.usage) then
    state.last_usage = current_session.usage
  else
    state.last_usage = nil
  end

  local context_msgs, _ = hm.get_context_and_new_parent(target_id)
  if #context_msgs > 0 then
    -- 重新从会话中获取原始消息，保留 JSON 格式
    state.messages = M._load_raw_messages(target_id, hm)
    return
  end

  -- 如果上下文为空，直接获取该会话的消息
  -- 同样需要保留原始 JSON 格式
  state.messages = M._load_raw_messages(target_id, hm)
end

--- 从历史管理器加载原始消息（保留 assistant 消息的 JSON 格式）
--- assistant 字段为数组，每个元素展开为一条 assistant 消息
--- @param session_id string 会话ID
--- @param hm table 历史管理器实例
--- @return table 消息列表
function M._load_raw_messages(session_id, hm)
  local messages = {}

  -- 从当前会话向上回溯到根，收集路径上的所有会话ID
  local path_ids = {}
  local current = hm.get_session(session_id)
  if not current then
    return messages
  end
  for _ = 1, 100 do
    table.insert(path_ids, 1, current.id) -- 插入到开头，保持从根到当前顺序
    local parent_id = hm.find_parent_session(current.id)
    if not parent_id then
      break -- 没有父节点，说明已到根
    end
    current = hm.get_session(parent_id)
    if not current then
      break
    end
  end

  -- 按从根到当前的顺序收集消息（保留原始格式）
  for _, pid in ipairs(path_ids) do
    local s = hm.get_session(pid)
    if not s then
      break
    end
    if s.user and s.user ~= "" then
      table.insert(messages, { role = "user", content = s.user })
    end
    local assistant_list = s.assistant
    if type(assistant_list) ~= "table" then
      if assistant_list and assistant_list ~= "" then
        assistant_list = { assistant_list }
      else
        assistant_list = {}
      end
    end
    -- 收集连续的 tool_call 条目，合并为折叠文本块
    local tool_call_buffer = {}
    local function flush_tool_calls()
      if #tool_call_buffer == 0 then
        return
      end
      local folded_text = "{{{ 🔧 工具调用"
      for _, tc in ipairs(tool_call_buffer) do
        local args_str = vim.inspect(tc.arguments or {})
        if #args_str > 100 then
          args_str = args_str:sub(1, 100) .. "..."
        end
        local result_raw = tc.result
        local result_str = ""
        if type(result_raw) == "table" then
          local ok, encoded = pcall(vim.json.encode, result_raw)
          if ok then
            result_str = encoded
          else
            result_str = vim.inspect(result_raw)
          end
        else
          result_str = tostring(result_raw or "")
        end
        if #result_str > 200 then
          result_str = result_str:sub(1, 200) .. "\n    ... [truncated, total " .. #result_str .. " chars]"
        end
        result_str = result_str:gsub("\n", "\n    ")
        folded_text = folded_text .. "\n  🔧 " .. (tc.tool_name or "unknown")
        folded_text = folded_text .. "\n    参数: " .. args_str
        folded_text = folded_text .. "\n    结果: " .. result_str
      end
      folded_text = folded_text .. "\n}}}"
      table.insert(messages, { role = "assistant", content = folded_text })
      tool_call_buffer = {}
    end

    for _, entry in ipairs(assistant_list) do
      local ok, parsed = pcall(vim.json.decode, entry)
      if ok and type(parsed) == "table" and parsed.type == "tool_call" then
        table.insert(tool_call_buffer, parsed)
      else
        flush_tool_calls()
        table.insert(messages, { role = "assistant", content = entry })
      end
    end
    flush_tool_calls()
  end

  return messages
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
    { pattern = Events.WINDOW_CLOSING, data = { window_id = state.current_window_id } }
  )

  -- 触发聊天框关闭事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = Events.CHAT_BOX_CLOSING, data = { window_id = state.current_window_id } }
  )

  -- 关闭浮动虚拟输入框（所有模式下关闭聊天窗口时都关闭输入框）
  if virtual_input.is_active() then
    virtual_input.close()
  end

  window_manager.close_window(state.current_window_id)

  -- 清理自动命令组
  if state.cursor_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.cursor_augroup)
    state.cursor_augroup = nil
  end

  state.current_window_id = nil
  state.current_session_id = nil
  state.messages = {}
  state.last_usage = nil
  state.usage_extmark_id = nil

  -- 触发窗口关闭事件
  vim.api.nvim_exec_autocmds("User", { pattern = Events.WINDOW_CLOSED, data = { window_id = state.current_window_id } })

  -- 触发聊天框关闭完成事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = Events.CHAT_BOX_CLOSED, data = { window_id = state.current_window_id } }
  )
end

--- 在 AI 回复末尾行添加 token 用量虚拟文本
--- 使用 nvim_buf_set_extmark 的 virt_text 特性，不修改缓冲区内容
function M._update_usage_virt_text()
  -- 流式进行中不显示用量信息，等流式完成后的全量重渲染再显示
  if state.streaming.active then
    return
  end
  if not state.current_window_id or not state.last_usage or not next(state.last_usage) then
    return
  end

  local win_handle = window_manager.get_window_win(state.current_window_id)
  if not win_handle or not vim.api.nvim_win_is_valid(win_handle) then
    return
  end

  local buf = vim.api.nvim_win_get_buf(win_handle)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  -- 获取或创建命名空间
  local ns_id = vim.api.nvim_create_namespace("NeoAIUsage")

  -- 清理旧的虚拟文本
  if state.usage_extmark_id then
    pcall(vim.api.nvim_buf_del_extmark, buf, ns_id, state.usage_extmark_id)
    state.usage_extmark_id = nil
  end

  -- 构建用量文本
  local usage = state.last_usage
  if not usage then
    return
  end

  local prompt_tokens = (usage.prompt_tokens or usage.promptTokens or usage.input_tokens or usage.inputTokens) or 0
  local completion_tokens = (
    usage.completion_tokens
    or usage.completionTokens
    or usage.output_tokens
    or usage.outputTokens
  ) or 0
  local total_tokens = (usage.total_tokens or usage.totalTokens) or (prompt_tokens + completion_tokens)

  local reasoning_tokens = 0
  if usage.completion_tokens_details and type(usage.completion_tokens_details) == "table" then
    reasoning_tokens = usage.completion_tokens_details.reasoning_tokens or 0
  end

  local usage_text
  if reasoning_tokens and reasoning_tokens > 0 then
    usage_text = string.format(
      "📊 Token 用量: 输入 %d · 输出 %d (思考 %d) · 总计 %d",
      prompt_tokens,
      completion_tokens,
      reasoning_tokens,
      total_tokens
    )
  else
    usage_text = string.format(
      "📊 Token 用量: 输入 %d · 输出 %d · 总计 %d",
      prompt_tokens,
      completion_tokens,
      total_tokens
    )
  end

  -- 先确保缓冲区可修改，在 AI 回复末尾追加分隔线
  pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = buf })
  pcall(vim.api.nvim_set_option_value, "readonly", false, { buf = buf })

  local line_count = vim.api.nvim_buf_line_count(buf)
  -- 检查最后一行是否已经是分隔线，避免重复追加
  local last_line_content = ""
  if line_count > 0 then
    local lines = vim.api.nvim_buf_get_lines(buf, line_count - 1, line_count, false)
    last_line_content = (lines[1] or ""):match("^%s*(.-)%s*$")
  end

  if last_line_content ~= "─" then
    -- 追加分隔线
    vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, { "─", "" })
    line_count = vim.api.nvim_buf_line_count(buf)
  end

  -- 在分隔线下一行（空行）写入用量文本（直接写入缓冲区，支持自动换行）
  -- 同时用 extmark 的 hl_group 设置整行颜色
  local usage_line = line_count - 1 -- 空行
  vim.api.nvim_buf_set_lines(buf, usage_line, usage_line + 1, false, { usage_text })
  -- 用 extmark 给这一行设置高亮颜色
  state.usage_extmark_id = vim.api.nvim_buf_set_extmark(buf, ns_id, usage_line, 0, {
    hl_group = "Comment",
    hl_eol = true,
  })

  -- 恢复缓冲区状态
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = buf })
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
    -- 空块：兼容旧版本 Neovim
    -- luacheck: ignore
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

--- 发送消息（异步版本）
--- @param message string 消息内容
--- @param callback function|nil 回调函数（可选）
--- @return boolean 是否成功启动异步发送
--- @return string|nil 结果信息
function M.send_message(message, callback)
  if not state.initialized then
    if callback then
      callback(false, "聊天窗口未初始化")
    end
    return false, "聊天窗口未初始化"
  end

  if not message or vim.trim(message) == "" then
    if callback then
      callback(false, "消息内容不能为空")
    end
    return false, "消息内容不能为空"
  end

  -- 使用异步工作器发送消息，避免阻塞界面
  local async_worker = require("NeoAI.utils.async_worker")

  -- 提交异步任务
  local task_id = async_worker.submit_task("send_chat_message_window", function()
    -- 首先添加用户消息
    local success = M.add_message("user", message)
    if not success then
      return false, "无法添加用户消息"
    end

    -- 注意：不再在这里触发NeoAI:message_sent事件
    -- 这个事件现在由chat_handlers统一触发，避免重复触发

    return true, "消息已发送"
  end, function(success, result, error_msg)
    -- 异步任务完成后的回调
    if callback then
      callback(success, result, error_msg)
    end

    if success then
      print("✓ 聊天窗口异步消息发送完成: " .. tostring(result))
    else
      print("✗ 聊天窗口异步消息发送失败: " .. tostring(error_msg or result))
    end
  end)

  return true, "聊天窗口异步消息发送任务已启动 (ID: " .. tostring(task_id) .. ")"
end

--- 添加消息到聊天
--- @param role string 角色 ('user' 或 'assistant')
--- @param content string 消息内容
--- @param opts table|nil 选项（allow_empty: 允许空内容用于流式占位符）
--- @return boolean 是否成功
function M.add_message(role, content, opts)
  if not state.initialized then
    return false
  end

  if role ~= "user" and role ~= "assistant" then
    return false
  end

  opts = opts or {}
  if not opts.allow_empty and (not content or vim.trim(content) == "") then
    return false
  end

  -- 触发消息添加事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = Events.MESSAGE_ADDING, data = { window_id = state.current_window_id, role = role, content = content } }
  )

  table.insert(state.messages, {
    role = role,
    content = content,
    timestamp = os.time(),
  })

  -- 触发消息添加完成事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = Events.MESSAGE_ADDED, data = { window_id = state.current_window_id, role = role, content = content } }
  )

  -- 持久化消息到 session_manager 和 history_manager（除非指定跳过）
  if not opts.skip_persist then
    M._persist_message(role, content)
  end

  -- 如果窗口打开，更新显示（除非指定跳过渲染）
  if state.current_window_id and not opts.skip_render then
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
  local ok, hm = pcall(require, "NeoAI.core.history_manager")
  if not ok or not hm.is_initialized() then
    return
  end
  local session = hm.get_current_session()
  if not session then
    return
  end
  if role == "user" then
    hm.add_round(session.id, content, {})
  elseif role == "assistant" then
    hm.update_last_assistant(session.id, content)
  end

  -- 触发自动保存
  M._trigger_auto_save()
end

--- 更新已持久化的消息
--- @param role string 角色 ('user' 或 'assistant')
--- @param content string 新消息内容
function M._update_persisted_message(role, content)
  local ok, hm = pcall(require, "NeoAI.core.history_manager")
  if not ok or not hm.is_initialized() then
    return
  end
  local session = hm.get_current_session()
  if not session then
    return
  end
  if role == "assistant" then
    hm.update_last_assistant(session.id, content)
  end
end

--- 将光标移动到缓冲区末尾（最新消息位置）
--- 在渲染完成后调用，方便用户查看最新输出
--- 滚动到缓冲区末尾，使最后一行位于窗口底部上方指定行数处
--- float 模式下虚拟输入框是独立浮动窗口，不占用 chat 窗口空间，无需留偏移
--- 其他模式（inline/tab/split）需要留出内联输入区域的空间
--- @param offset number|nil 距离底部的行数偏移，nil 时根据窗口模式自动计算
function M._scroll_to_end_with_offset(offset)
  if offset == nil then
    -- 根据窗口模式动态计算 offset
    local mode = window_manager.get_current_mode()
    if mode == "float" then
      offset = 0 -- float 模式：虚拟输入框独立，不占 chat 窗口空间
    else
      -- 其他模式：内联输入需要留空间，取虚拟输入框行数 + 5 行余量
      local vi = require("NeoAI.ui.components.virtual_input")
      local input_lines = vi.get_input_line_count()
      offset = (input_lines or 3) + 5
    end
  end
  if not state.current_window_id then
    return
  end

  local win_handle = window_manager.get_window_win(state.current_window_id)
  if not win_handle or not vim.api.nvim_win_is_valid(win_handle) then
    return
  end

  local buf = window_manager.get_window_buf(state.current_window_id)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local line_count = vim.api.nvim_buf_line_count(buf)
  if line_count > 0 then
    -- 设置光标到末尾行行尾，Neovim 会自动滚动视图使光标行可见
    local last_line_content = vim.api.nvim_buf_get_lines(buf, line_count - 1, line_count, false)[1] or ""
    local last_col = #last_line_content
    pcall(vim.api.nvim_win_set_cursor, win_handle, { line_count, last_col })

    -- 使用 normal! z 让光标行位于窗口底部（z 命令将当前行移到窗口底部）
    pcall(vim.api.nvim_win_call, win_handle, function()
      vim.cmd("normal! z")
    end)
  end
end

--- 将光标移动到缓冲区末尾（最新消息位置）
--- 在渲染完成后调用，方便用户查看最新输出
function M._move_cursor_to_end()
  M._scroll_to_end_with_offset()
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
    pattern = Events.FLOATING_TEXT_SHOWING,
    data = {
      window_id = state.current_window_id,
      text = text,
    },
  })

  -- 这里可以实现实际的悬浮文本显示逻辑
  -- 例如使用 nvim_open_win 创建浮动窗口

  -- 触发显示悬浮文本完成事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = Events.FLOATING_TEXT_SHOWN,
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
    { pattern = Events.FLOATING_TEXT_CLOSING, data = {
      window_id = state.current_window_id,
    } }
  )

  -- 这里可以实现实际的悬浮文本关闭逻辑

  -- 触发关闭悬浮文本完成事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = Events.FLOATING_TEXT_CLOSED, data = {
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

  -- 监听AI生成开始事件：关闭虚拟输入框
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.GENERATION_STARTED,
    callback = function(args)
      local data = args.data or {}
      local window_id = data.window_id

      -- 检查是否是当前窗口的生成
      if window_id and window_id ~= state.current_window_id then
        return
      end

      -- AI开始生成时关闭浮动输入框
      if virtual_input.is_active() then
        virtual_input.close()
      end
    end,
  })

  -- 监听AI生成完成事件（AI引擎触发的事件）
  -- 流式完成后服务器会重新发送完整正文和token用量，用这个替换当前正文
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.GENERATION_COMPLETED,
    callback = function(args)
      local data = args.data or {}
      local response = data.response
      local window_id = data.window_id
      local session_id = data.session_id
      local reasoning_text = data.reasoning_text
      local usage = data.usage or {}

      -- 检查是否是当前窗口的消息
      if window_id and window_id ~= state.current_window_id then
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

      if not response_content or response_content == "" then
        return
      end

      -- 用完整响应替换流式累积的内容（流式完成后服务器重新发送完整正文）
      local message_index = state.streaming.message_index
      if message_index and state.messages[message_index] then
        local final_content
        if reasoning_text and reasoning_text ~= "" then
          final_content = vim.json.encode({
            reasoning_content = reasoning_text,
            content = response_content,
          })
        else
          final_content = response_content
        end
        state.messages[message_index].content = final_content
        -- 更新 message_manager 中的占位符消息（而不是添加新消息）
        M._update_persisted_message("assistant", final_content)
      else
        -- 检查是否已有工具调用折叠文本（通过 TOOL_LOOP_FINISHED 添加的）
        -- 如果有，说明这是工具调用后的最终 AI 回复，只需更新最后一条消息
        local has_tool_call = false
        for i = #state.messages, 1, -1 do
          local msg = state.messages[i]
          if msg.role == "assistant" and msg.content then
            local trimmed = vim.trim(msg.content)
            if trimmed:find("^{{{%s*🔧 工具调用") then
              has_tool_call = true
              break
            end
          end
        end

        if has_tool_call then
          -- 工具调用场景：不通过 add_message 添加新消息（避免 _persist_message 重复保存）
          -- 直接将 AI 回复追加到 state.messages 末尾
          local final_content
          if reasoning_text and reasoning_text ~= "" then
            final_content = vim.json.encode({
              reasoning_content = reasoning_text,
              content = response_content,
            })
          else
            final_content = response_content
          end
          table.insert(state.messages, {
            role = "assistant",
            content = final_content,
            timestamp = os.time(),
          })
        else
          -- 查找并移除占位符消息
          local placeholder_index = nil
          for i = #state.messages, 1, -1 do
            if state.messages[i].role == "assistant" and state.messages[i].content == "🤖 AI正在思考..." then
              placeholder_index = i
              break
            end
          end
          if placeholder_index then
            table.remove(state.messages, placeholder_index)
          end
          -- 添加完整响应（跳过渲染，由后面的 render_chat 统一处理）
          if reasoning_text and reasoning_text ~= "" then
            local combined = vim.json.encode({
              reasoning_content = reasoning_text,
              content = response_content,
            })
            M.add_message("assistant", combined, { skip_render = true })
          else
            M.add_message("assistant", response_content, { skip_render = true })
          end
        end
      end

      -- 保存 token 用量信息（在渲染之前保存，确保 _update_usage_virt_text 能读取到）
      if usage and next(usage) then
        state.last_usage = usage
      end

      -- 关闭思考过程悬浮窗口
      -- 思考内容已通过全量重渲染以折叠标记格式显示
      local reasoning_display = require("NeoAI.ui.components.reasoning_display")
      if reasoning_display.is_visible() then
        reasoning_display.close()
      end

      -- 重置流式状态
      state.streaming.active = false
      state.streaming.generation_id = nil
      state.streaming.message_index = nil
      state.streaming.content_buffer = ""
      state.streaming.reasoning_buffer = ""
      state.streaming.reasoning_active = false
      state.streaming.reasoning_done = false

      -- 全量重渲染
      M.render_chat()

      -- 渲染完成后，添加 token 用量信息、滚动窗口、打开输入框
      -- 使用单层 defer_fn 减少延迟
      vim.defer_fn(function()
        M._update_usage_virt_text()
        M._scroll_to_end_with_offset()
        M._open_float_input()

        -- 确保光标在浮动输入框并进入插入模式
        local vi = require("NeoAI.ui.components.virtual_input")
        if vi.is_active() then
          vi.focus_and_insert()
        end
      end, 50)
    end,
  })

  -- 监听消息发送事件（用于更新UI状态）
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.MESSAGE_SENT,
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

  -- 流式数据块节流状态
  local stream_throttle = {
    buffer = "",
    timer = nil,
    pending = false,
    interval_ms = 50, -- 每50ms批量处理一次
  }

  -- 监听AI引擎发出的标准流式数据块事件 (NeoAI:stream_chunk)
  -- 这是AI引擎在流式请求中发出的标准事件
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.STREAM_CHUNK,
    callback = function(args)
      local data = args.data or {}
      local chunk = data.chunk
      local generation_id = data.generation_id
      local window_id = data.window_id

      -- 检查是否是当前窗口
      if window_id and window_id ~= state.current_window_id then
        return
      end

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

      if not chunk_content or chunk_content == "" then
        return
      end

      -- 初始化流式状态（如果是新的流式请求）
      if not state.streaming.active or state.streaming.generation_id ~= generation_id then
        state.streaming.active = true
        state.streaming.generation_id = generation_id
        state.streaming.content_buffer = ""
        state.streaming.reasoning_buffer = ""
        state.streaming.reasoning_active = false
        state.streaming.reasoning_done = false

        -- 添加AI占位符消息（允许空内容，跳过首次渲染）
        local success = M.add_message("assistant", "", { allow_empty = true, skip_render = true })
        if success then
          state.streaming.message_index = #state.messages
        end
      end

      -- 检测到正文输出（非思考内容），关闭思考过程悬浮窗口
      -- 思考过程不在此处流式追加，而是等生成完成后通过全量渲染一次性添加折叠文本
      if state.streaming.reasoning_active then
        state.streaming.reasoning_active = false
        state.streaming.reasoning_done = true
        local reasoning_display = require("NeoAI.ui.components.reasoning_display")
        if reasoning_display.is_visible() then
          reasoning_display.close()
        end
      end

      -- 累积内容到状态
      state.streaming.content_buffer = state.streaming.content_buffer .. chunk_content

      -- 节流处理：累积数据块，定时批量刷新到缓冲区
      stream_throttle.buffer = stream_throttle.buffer .. chunk_content

      if not stream_throttle.pending then
        stream_throttle.pending = true
        vim.defer_fn(function()
          local batch = stream_throttle.buffer
          stream_throttle.buffer = ""
          stream_throttle.pending = false

          if batch ~= "" then
            M._append_stream_chunk_to_buffer(batch)
          end
        end, stream_throttle.interval_ms)
      end
    end,
  })

  -- 监听思考内容事件 (NeoAI:reasoning_content)
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.REASONING_CONTENT,
    callback = function(args)
      local data = args.data or {}
      local reasoning_content = data.reasoning_content
      local generation_id = data.generation_id
      local window_id = data.window_id

      -- 检查是否是当前窗口
      if window_id and window_id ~= state.current_window_id then
        return
      end

      if not reasoning_content or reasoning_content == "" then
        return
      end

      -- 初始化流式状态（如果是新的流式请求）
      if not state.streaming.active or state.streaming.generation_id ~= generation_id then
        state.streaming.active = true
        state.streaming.generation_id = generation_id
        state.streaming.content_buffer = ""
        state.streaming.reasoning_buffer = ""
        state.streaming.reasoning_active = true
        state.streaming.reasoning_done = false

        -- 添加AI占位符消息（允许空内容，跳过首次渲染）
        local success = M.add_message("assistant", "", { allow_empty = true, skip_render = true })
        if success then
          state.streaming.message_index = #state.messages
        end

        -- 显示思考过程悬浮窗口
        local reasoning_display = require("NeoAI.ui.components.reasoning_display")
        reasoning_display.show("🤔 AI正在思考...")
      end

      -- 标记思考内容活跃
      state.streaming.reasoning_active = true
      state.streaming.reasoning_buffer = state.streaming.reasoning_buffer .. reasoning_content

      -- 如果工具调用悬浮窗口处于活跃状态，也更新其中的思考内容
      if state.tool_display.active then
        -- 在工具调用悬浮窗口中追加思考内容
        -- 查找 "🤔 思考过程:" 标记，如果存在则更新其内容
        local reasoning_marker = "🤔 思考过程:\n"
        local marker_pos = state.tool_display.buffer:find(reasoning_marker)
        if marker_pos then
          -- 找到思考过程区域，更新内容
          local reasoning_start = marker_pos + #reasoning_marker
          local reasoning_end = state.tool_display.buffer:find("\n\n🔧 工具调用", reasoning_start)
          if not reasoning_end then
            reasoning_end = #state.tool_display.buffer
          end
          -- 截取思考内容的前 200 个字符作为摘要
          local reasoning_summary = state.streaming.reasoning_buffer or ""
          if #reasoning_summary > 200 then
            reasoning_summary = reasoning_summary:sub(1, 200) .. "..."
          end
          -- 重新构建思考内容区域
          local new_reasoning_section = ""
          for _, line in ipairs(vim.split(reasoning_summary, "\n")) do
            new_reasoning_section = new_reasoning_section .. "  " .. line .. "\n"
          end
          -- 替换旧内容
          local before = state.tool_display.buffer:sub(1, reasoning_start - 1)
          local after = state.tool_display.buffer:sub(reasoning_end)
          state.tool_display.buffer = before .. new_reasoning_section .. after
        else
          -- 没有思考过程区域，在工具调用列表前插入
          local tool_marker = "🔧 工具调用中...\n"
          local tool_pos = state.tool_display.buffer:find(tool_marker)
          if tool_pos then
            local reasoning_summary = state.streaming.reasoning_buffer or ""
            if #reasoning_summary > 200 then
              reasoning_summary = reasoning_summary:sub(1, 200) .. "..."
            end
            local new_section = "🤔 思考过程:\n"
            for _, line in ipairs(vim.split(reasoning_summary, "\n")) do
              new_section = new_section .. "  " .. line .. "\n"
            end
            new_section = new_section .. "\n"
            state.tool_display.buffer = new_section .. state.tool_display.buffer
          end
        end
        M._update_tool_display()
      else
        -- 没有工具调用，正常显示在 reasoning_display 悬浮窗口
        local reasoning_display = require("NeoAI.ui.components.reasoning_display")
        reasoning_display.append(reasoning_content)
      end
    end,
  })

  -- 监听旧的 ai_response_chunk 事件（兼容旧的事件流）
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.AI_RESPONSE_CHUNK,
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

      if not chunk_content or chunk_content == "" then
        return
      end

      -- 初始化流式状态（如果是新的流式请求）
      if not state.streaming.active then
        state.streaming.active = true
        state.streaming.generation_id = generation_id
        state.streaming.content_buffer = ""
        state.streaming.reasoning_buffer = ""

        -- 添加AI占位符消息（允许空内容，跳过首次渲染）
        local success = M.add_message("assistant", "", { allow_empty = true, skip_render = true })
        if success then
          state.streaming.message_index = #state.messages
        end
      end

      -- 累积内容
      state.streaming.content_buffer = state.streaming.content_buffer .. chunk_content

      -- 增量渲染
      M._append_stream_chunk_to_buffer(chunk_content)
    end,
  })

  -- 监听流式生成完成事件
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.STREAM_COMPLETED,
    callback = function(args)
      local data = args.data or {}
      local generation_id = data.generation_id
      local full_response = data.full_response
      local reasoning_text = data.reasoning_text
      local window_id = data.window_id

      -- 检查是否是当前窗口的流式请求
      if not state.streaming.active or state.streaming.generation_id ~= generation_id then
        -- 即使流式状态不匹配，也尝试关闭 reasoning_display
        local reasoning_display = require("NeoAI.ui.components.reasoning_display")
        if reasoning_display.is_visible() then
          reasoning_display.close()
        end
        return
      end

      -- 关闭思考过程悬浮窗口
      local reasoning_display = require("NeoAI.ui.components.reasoning_display")
      if reasoning_display.is_visible() then
        reasoning_display.close()
      end

      -- 流式数据已完成，但完整响应和全量渲染由 GENERATION_COMPLETED 事件处理
      -- 这里只做状态清理，不触发全量渲染（避免重复渲染）
      -- 注意：不重置 message_index，保留供 GENERATION_COMPLETED 事件使用
      state.streaming.active = false
      state.streaming.content_buffer = ""
      state.streaming.reasoning_buffer = ""
      state.streaming.reasoning_active = false
      state.streaming.reasoning_done = false
    end,
  })

  -- 监听工具循环开始事件：显示工具调用悬浮窗口（含思考过程）
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.TOOL_LOOP_STARTED,
    callback = function(args)
      local data = args.data or {}
      local window_id = data.window_id
      local tool_calls = data.tool_calls or {}
      local is_reasoning_model = data.is_reasoning_model or false

      -- 检查是否是当前窗口
      if window_id and window_id ~= state.current_window_id then
        return
      end

      if #tool_calls == 0 then
        return
      end

      -- 重置工具调用状态
      state.tool_display.active = true
      state.tool_display.buffer = ""
      state.tool_display.results = {}
      state.tool_display.show_time = vim.loop.now() -- 记录显示开始时间

      -- 构建初始显示内容：包含思考过程和工具调用
      local initial_text = ""

      -- 如果有思考内容，先显示思考过程
      local reasoning_buffer = state.streaming.reasoning_buffer or ""
      if reasoning_buffer ~= "" then
        -- 截取思考内容的前 200 个字符作为摘要
        local reasoning_summary = reasoning_buffer
        if #reasoning_summary > 200 then
          reasoning_summary = reasoning_summary:sub(1, 200) .. "..."
        end
        initial_text = initial_text .. "🤔 思考过程:\n"
        -- 缩进显示思考内容
        for _, line in ipairs(vim.split(reasoning_summary, "\n")) do
          initial_text = initial_text .. "  " .. line .. "\n"
        end
        initial_text = initial_text .. "\n"
      end

      initial_text = initial_text .. "🔧 工具调用中...\n"
      for _, tc in ipairs(tool_calls) do
        local tool_func = tc["function"] or tc.func or {}
        local tool_name = tool_func.name or "unknown"
        initial_text = initial_text .. "  ⏳ " .. tool_name .. "\n"
      end

      state.tool_display.buffer = initial_text

      -- 创建或更新悬浮窗口（根据内容动态调整高度）
      M._show_tool_display()
    end,
  })

  -- 监听单个工具执行开始事件：更新悬浮窗口状态
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.TOOL_EXECUTION_STARTED,
    callback = function(args)
      local data = args.data or {}
      local window_id = data.window_id
      local tool_name = data.tool_name

      -- 检查是否是当前窗口
      if window_id and window_id ~= state.current_window_id then
        return
      end

      if not state.tool_display.active then
        return
      end

      -- 更新悬浮窗口：将 ⏳ 改为 🔄
      -- 转义 tool_name 中的特殊字符（如 _、. 等）
      local escaped_name = tool_name:gsub("([%.%+%-%*%?%[%]%^%$%(%)%%])", "%%%1")
      state.tool_display.buffer =
        state.tool_display.buffer:gsub("  ⏳ " .. escaped_name, "  🔄 " .. tool_name .. " (执行中...)")
      M._update_tool_display()
    end,
  })

  -- 监听单个工具执行完成事件：更新悬浮窗口状态
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.TOOL_EXECUTION_COMPLETED,
    callback = function(args)
      local data = args.data or {}
      local window_id = data.window_id
      local tool_name = data.tool_name
      local arguments = data.arguments or {}
      local result = data.result or ""
      local duration = data.duration or 0

      -- 检查是否是当前窗口
      if window_id and window_id ~= state.current_window_id then
        return
      end

      if not state.tool_display.active then
        return
      end

      -- 保存结果用于生成折叠文本
      table.insert(state.tool_display.results, {
        tool_name = tool_name,
        arguments = arguments,
        result = result,
        duration = duration,
      })

      -- 更新悬浮窗口：将 🔄 改为 ✅
      local escaped_name = tool_name:gsub("([%.%+%-%*%?%[%]%^%$%(%)%%])", "%%%1")

      -- 先尝试替换 🔄 状态
      local replaced = state.tool_display.buffer:gsub(
        "  🔄 " .. escaped_name .. " %(执行中%.%.%.%)",
        "  ✅ " .. tool_name .. " (" .. duration .. "s)"
      )
      if replaced == state.tool_display.buffer then
        -- 如果替换失败，尝试替换 ⏳ 状态
        state.tool_display.buffer =
          state.tool_display.buffer:gsub("  ⏳ " .. escaped_name, "  ✅ " .. tool_name .. " (" .. duration .. "s)")
      else
        state.tool_display.buffer = replaced
      end
      M._update_tool_display()
    end,
  })

  -- 监听工具循环结束事件：关闭悬浮窗口，将工具调用结果转换为折叠文本
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.TOOL_LOOP_FINISHED,
    callback = function(args)
      local data = args.data or {}
      local window_id = data.window_id
      local tool_results = data.tool_results or {}

      -- 检查是否是当前窗口
      if window_id and window_id ~= state.current_window_id then
        return
      end

      if not state.tool_display.active then
        return
      end

      -- 计算悬浮窗已显示时长，确保最小显示1500ms
      local elapsed = vim.loop.now() - (state.tool_display.show_time or 0)
      local min_display_ms = 1500
      local delay = math.max(0, min_display_ms - elapsed)

      if delay > 0 then
        -- 不足最小显示时间，延迟关闭
        vim.defer_fn(function()
          M._close_tool_display()
        end, delay)
      else
        -- 已超过最小显示时间，立即关闭
        M._close_tool_display()
      end

      -- 将工具调用结果转换为折叠文本并添加到消息列表
      -- 注意：跳过持久化（skip_persist=true），因为工具调用数据已由 chat_handlers
      -- 通过 add_tool_result 保存到历史文件。折叠文本只是 UI 显示用的，不需要重复保存。
      if #state.tool_display.results > 0 then
        local folded_text = M._build_tool_folded_text(state.tool_display.results)
        M.add_message("assistant", folded_text, { skip_render = true, skip_persist = true })
      end

      -- 重置工具调用状态
      state.tool_display.active = false
      state.tool_display.buffer = ""
      state.tool_display.results = {}
    end,
  })

  -- 监听生成取消事件
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.GENERATION_CANCELLED,
    callback = function(args)
      local data = args.data or {}
      local generation_id = data.generation_id

      -- 关闭思考过程悬浮窗口
      local reasoning_display = require("NeoAI.ui.components.reasoning_display")
      if reasoning_display.is_visible() then
        reasoning_display.close()
      end

      -- 清理流式状态
      state.streaming.active = false
      state.streaming.content_buffer = ""
      state.streaming.reasoning_buffer = ""
      state.streaming.reasoning_active = false
      state.streaming.reasoning_done = false

      print("⚠️  AI生成已取消 (ID: " .. tostring(generation_id) .. ")")

      -- 显示取消通知
      M.show_floating_text("AI生成已取消", {
        timeout = 3000,
        position = "center",
        border = "single",
      })
    end,
  })

  -- 监听会话重命名事件（自动命名完成后），更新当前 chat buffer 名称
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.SESSION_RENAMED,
    callback = function(args)
      local data = args.data or {}
      local session_id = data.session_id
      local name = data.name

      -- 只处理当前聊天窗口的会话
      if not session_id or session_id ~= state.current_session_id then
        return
      end

      -- 更新 buffer 名称，添加会话名称后缀
      local buf = window_manager.get_window_buf(state.current_window_id)
      if buf and vim.api.nvim_buf_is_valid(buf) then
        local new_name = "neoai://chat/" .. session_id .. " - " .. (name or "")
        pcall(vim.api.nvim_buf_set_name, buf, new_name)
      end
    end,
    desc = "自动命名后更新 chat buffer 名称",
  })
end

--- 获取当前聊天窗口的窗口ID
--- @return string|nil 窗口ID，如果没有打开的窗口则返回nil
function M.get_current_window_id()
  return state.current_window_id
end

--- 获取聊天窗口中的消息
--- @return table 消息列表
function M.get_messages()
  return state.messages or {}
end

--- 设置聊天窗口中的消息
--- @param messages table 消息列表
--- @return boolean 是否成功
function M.set_messages(messages)
  if not messages or type(messages) ~= "table" then
    return false
  end

  state.messages = messages

  -- 如果窗口打开，更新显示
  if state.current_window_id then
    M.render_chat()
  end

  return true
end

--- 更新特定消息
--- @param index number 消息索引（1-based）
--- @param content string 新的消息内容
--- @return boolean 是否成功
function M.update_message(index, content)
  if not state.messages or index < 1 or index > #state.messages then
    return false
  end

  if not content or type(content) ~= "string" then
    return false
  end

  state.messages[index].content = content

  -- 如果窗口打开，更新显示
  if state.current_window_id then
    M.render_chat()
  end

  return true
end

--- 追加流式数据块到缓冲区（增量渲染）
--- 直接将数据块追加到聊天窗口缓冲区末尾，避免全量重渲染
--- @param chunk_content string 数据块内容
--- @param content_type string|nil 内容类型 ("reasoning" 或 "content")
function M._append_stream_chunk_to_buffer(chunk_content, content_type)
  if not state.current_window_id then
    return
  end

  -- 更新消息列表中的累积内容
  local message_index = state.streaming.message_index
  if message_index and state.messages[message_index] then
    local full_content = state.streaming.content_buffer or ""
    local reasoning_text = state.streaming.reasoning_buffer or ""

    if reasoning_text and reasoning_text ~= "" then
      local combined = vim.json.encode({
        reasoning_content = reasoning_text,
        content = full_content,
      })
      state.messages[message_index].content = combined
    else
      state.messages[message_index].content = full_content
    end
  end

  -- 增量追加到缓冲区末尾，避免全量重渲染
  local buf = window_manager.get_window_buf(state.current_window_id)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  -- 确保缓冲区可修改
  pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = buf })
  pcall(vim.api.nvim_set_option_value, "readonly", false, { buf = buf })

  -- 获取当前缓冲区行数
  local line_count = vim.api.nvim_buf_line_count(buf)

  -- 检查数据块是否包含换行符
  local has_newline = chunk_content:find("\n")

  if has_newline then
    -- 数据块包含换行符：按行分割，第一行追加到当前最后一行末尾，其余行作为新行插入
    local lines = vim.split(chunk_content, "\n", { plain = true })
    if #lines > 0 then
      -- 获取当前最后一行内容
      local last_line = ""
      if line_count > 0 then
        local current_lines = vim.api.nvim_buf_get_lines(buf, line_count - 1, line_count, false)
        last_line = current_lines[1] or ""
      end

      -- 第一行追加到当前最后一行末尾
      local first_line = last_line .. (lines[1] or "")

      -- 剩余行作为新行插入（跳过空行）
      local new_lines = { first_line }
      for i = 2, #lines do
        table.insert(new_lines, lines[i] or "")
      end

      -- 替换最后一行并追加剩余行
      if line_count > 0 then
        pcall(vim.api.nvim_buf_set_lines, buf, line_count - 1, line_count, false, new_lines)
      else
        pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, new_lines)
      end
    end
  else
    -- 数据块不包含换行符：直接追加到当前最后一行末尾
    if line_count > 0 then
      local current_lines = vim.api.nvim_buf_get_lines(buf, line_count - 1, line_count, false)
      local last_line = current_lines[1] or ""
      pcall(vim.api.nvim_buf_set_lines, buf, line_count - 1, line_count, false, { last_line .. chunk_content })
    else
      pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, { chunk_content })
    end
  end

  -- 不恢复只读（内联输入模式需要保持可修改）
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = buf })

  -- 检查光标是否在缓冲区末尾附近（最后5行内），如果是则自动跟随滚动
  local win_handle = window_manager.get_window_win(state.current_window_id)
  local should_follow = false
  if win_handle and vim.api.nvim_win_is_valid(win_handle) then
    local cursor = vim.api.nvim_win_get_cursor(win_handle)
    local cursor_line = cursor[1]
    local total_lines = vim.api.nvim_buf_line_count(buf)
    if total_lines - cursor_line <= 5 then
      should_follow = true
    end
  end

  if should_follow then
    -- 滚动使最后一行位于窗口底部上方10行处
    M._scroll_to_end_with_offset()

    -- 将光标移动到最新追加的内容末尾（新行的行尾）
    local new_line_count = vim.api.nvim_buf_line_count(buf)
    if new_line_count > 0 then
      if win_handle and vim.api.nvim_win_is_valid(win_handle) then
        local last_line_content = vim.api.nvim_buf_get_lines(buf, new_line_count - 1, new_line_count, false)[1] or ""
        local last_col = #last_line_content
        pcall(vim.api.nvim_win_set_cursor, win_handle, { new_line_count, last_col })
      end
    end
  end
end

--- 完成流式渲染
--- 将累积的流式内容临时保存到消息列表中，并触发全量重渲染
--- 注意：流式完成后服务器会重新发送完整正文（通过 NeoAI:generation_completed 事件），
--- 所以这里只做临时保存，最终内容由 generation_completed 事件处理替换
function M._finalize_streaming()
  if not state.streaming.active then
    return
  end

  local message_index = state.streaming.message_index
  local full_content = state.streaming.content_buffer or ""
  local reasoning_text = state.streaming.reasoning_buffer or ""

  -- 临时保存累积内容到消息列表（后续会被 generation_completed 的完整响应替换）
  if message_index and state.messages[message_index] then
    if reasoning_text and reasoning_text ~= "" then
      local combined = vim.json.encode({
        reasoning_content = reasoning_text,
        content = full_content,
      })
      state.messages[message_index].content = combined
    else
      state.messages[message_index].content = full_content
    end
  end

  -- 更新已持久化的占位符消息（而不是添加新消息）
  if reasoning_text and reasoning_text ~= "" then
    local combined = vim.json.encode({
      reasoning_content = reasoning_text,
      content = full_content,
    })
    M._update_persisted_message("assistant", combined)
  elseif full_content and full_content ~= "" then
    M._update_persisted_message("assistant", full_content)
  end

  -- 全量重渲染以确保一致性
  M.render_chat()

  -- 注意：不重置 message_index，保留供 generation_completed 事件使用
  -- 重置其他状态
  state.streaming.active = false
  state.streaming.content_buffer = ""
  state.streaming.reasoning_buffer = ""
  state.streaming.reasoning_active = false
  state.streaming.reasoning_done = false
end

--- 显示工具调用悬浮窗口
function M._show_tool_display()
  -- 如果已有窗口，先关闭
  if state.tool_display.window_id then
    M._close_tool_display()
  end

  -- 根据内容动态计算窗口高度
  local content_lines = vim.split(state.tool_display.buffer or "", "\n")
  local dynamic_height = math.max(5, math.min(#content_lines + 2, 20)) -- 最小5行，最大20行

  -- 使用 window_manager 创建浮动窗口
  local win_id = window_manager.create_window("tool_display", {
    title = "🔧 工具调用",
    width = state.config.width and math.min(state.config.width - 4, 80) or 60,
    height = dynamic_height,
    border = "rounded",
    style = "minimal",
    relative = "editor",
    row = 1,
    col = 1,
    zindex = 100,
    window_mode = "float",
  })

  if not win_id then
    return
  end

  state.tool_display.window_id = win_id

  -- 设置窗口内容
  local window_info = window_manager.get_window_info(win_id)
  if window_info and window_info.buf and vim.api.nvim_buf_is_valid(window_info.buf) then
    vim.api.nvim_set_option_value("modifiable", true, { buf = window_info.buf })
    vim.api.nvim_set_option_value("filetype", "markdown", { buf = window_info.buf })

    local lines = vim.split(state.tool_display.buffer or "", "\n")
    vim.api.nvim_buf_set_lines(window_info.buf, 0, -1, false, lines)

    vim.api.nvim_set_option_value("readonly", true, { buf = window_info.buf })
    vim.api.nvim_set_option_value("modifiable", false, { buf = window_info.buf })

    -- 设置按键映射
    vim.keymap.set("n", "q", "<Cmd>lua require('NeoAI.ui.window.chat_window')._close_tool_display()<CR>", {
      buffer = window_info.buf,
      desc = "关闭工具调用窗口",
      silent = true,
      noremap = true,
    })
    vim.keymap.set("n", "<Esc>", "<Cmd>lua require('NeoAI.ui.window.chat_window')._close_tool_display()<CR>", {
      buffer = window_info.buf,
      desc = "关闭工具调用窗口",
      silent = true,
      noremap = true,
    })
  end
end

--- 更新工具调用悬浮窗口内容
function M._update_tool_display()
  if not state.tool_display.window_id then
    return
  end

  local window_info = window_manager.get_window_info(state.tool_display.window_id)
  if not window_info or not window_info.buf or not vim.api.nvim_buf_is_valid(window_info.buf) then
    return
  end

  local buf = window_info.buf
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })

  local lines = vim.split(state.tool_display.buffer or "", "\n")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  vim.api.nvim_set_option_value("readonly", true, { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

--- 关闭工具调用悬浮窗口
function M._close_tool_display()
  if state.tool_display.window_id then
    window_manager.close_window(state.tool_display.window_id)
    state.tool_display.window_id = nil
  end
end

--- 构建工具调用结果的折叠文本
--- @param results table 工具调用结果列表
--- @return string 折叠文本格式的字符串
function M._build_tool_folded_text(results)
  if not results or #results == 0 then
    return ""
  end

  local folded_text = "{{{ 🔧 工具调用"

  for _, r in ipairs(results) do
    local args_str = vim.inspect(r.arguments or {})
    if #args_str > 100 then
      args_str = args_str:sub(1, 100) .. "..."
    end
    local result_raw = r.result
    local result_str = ""
    if type(result_raw) == "table" then
      local ok, encoded = pcall(vim.json.encode, result_raw)
      if ok then
        result_str = encoded
      else
        result_str = vim.inspect(result_raw)
      end
    else
      result_str = tostring(result_raw or "")
    end
    if #result_str > 200 then
      result_str = result_str:sub(1, 200) .. "\n    ... [truncated, total " .. #result_str .. " chars]"
    end
    result_str = result_str:gsub("\n", "\n    ")

    folded_text = folded_text .. "\n  🔧 " .. r.tool_name
    folded_text = folded_text .. "\n    参数: " .. args_str
    folded_text = folded_text .. "\n    结果: " .. result_str
  end

  folded_text = folded_text .. "\n}}}"

  return folded_text
end

--- 获取当前使用的模型标签
--- @return string|nil 模型标签，如 "deepseek/deepseek-chat"
function M._get_current_model_label()
  local default_config = require("NeoAI.default_config")
  local candidates = default_config.get_scenario_candidates("chat")
  local target = candidates[state.current_model_index]
  if target then
    return string.format("%s/%s", target.provider or "?", target.model_name or "?")
  end
  return nil
end

--- 获取当前使用的模型候选索引
--- @return number 当前模型索引（1-based）
function M.get_current_model_index()
  return state.current_model_index or 1
end

--- 显示模型选择器（浮动窗口菜单）
--- 列出当前场景（chat）内所有场景候选，用户选择后切换
function M.show_model_selector()
  if not state.current_window_id then
    return
  end

  local default_config = require("NeoAI.default_config")
  local candidates = default_config.get_scenario_candidates("chat")

  if #candidates == 0 then
    vim.notify("[NeoAI] 没有可用的场景候选（请检查 scenarios.chat 配置）", vim.log.levels.WARN)
    return
  end

  -- 构建选择菜单项
  local items = {}
  for i, c in ipairs(candidates) do
    local indicator = (i == state.current_model_index) and "✓ " or "  "
    table.insert(items, string.format("%s%s/%s", indicator, c.provider or "?", c.model_name or "?"))
  end

  -- 获取当前模型名用于提示
  local current_label = "未知"
  local current = candidates[state.current_model_index]
  if current then
    current_label = string.format("%s/%s", current.provider or "?", current.model_name or "?")
  end

  vim.ui.select(items, {
    prompt = "选择 AI 模型 (当前: " .. current_label .. ")",
    format_item = function(item)
      return item
    end,
  }, function(choice, idx)
    if choice and idx and idx ~= state.current_model_index then
      M.switch_to_model(idx)
    end
  end)
end

--- 切换到当前场景内的指定模型候选
--- @param model_index number 模型候选索引（1-based）
function M.switch_to_model(model_index)
  if not model_index or model_index == state.current_model_index then
    return
  end

  local default_config = require("NeoAI.default_config")
  local candidates = default_config.get_scenario_candidates("chat")

  -- 查找目标模型
  local target = candidates[model_index]
  if not target then
    vim.notify("[NeoAI] 无效的模型索引: " .. tostring(model_index), vim.log.levels.WARN)
    return
  end

  local old_index = state.current_model_index
  state.current_model_index = model_index

  -- 更新聊天窗口标题
  M.update_title(string.format("NeoAI 聊天 [%s/%s]", target.provider or "?", target.model_name or "?"))

  -- 重新渲染聊天内容（标题区域会显示新模型）
  M.render_chat()

  -- 触发模型切换事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = Events.MODEL_SWITCHED,
    data = {
      old_index = old_index,
      new_index = model_index,
      provider = target.provider,
      model_name = target.model_name,
      window_id = state.current_window_id,
    },
  })

  vim.notify(string.format("[NeoAI] 已切换到模型: %s", target.label), vim.log.levels.INFO)
end

return M
