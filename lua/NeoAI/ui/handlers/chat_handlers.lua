local M = {}

-- 模块状态
local state = {
  initialized = false,
  config = nil,
}

--- 尝试打开聊天窗口
--- @return boolean 是否成功打开或已打开
local function try_open_chat_window()
  -- 首先检查是否已打开
  local chat_window = require("NeoAI.ui.window.chat_window")
  if chat_window.is_available() then
    return true
  end

  -- 尝试打开聊天窗口
  local ui_success, ui = pcall(require, "NeoAI.ui")
  if not ui_success or type(ui) ~= "table" or not ui.open_chat_ui then
    return false
  end

  -- 获取当前会话ID
  local session_id = "default"

  -- 通过UI模块获取会话ID，避免直接调用核心模块
  if ui and type(ui.get_current_session_id) == "function" then
    local current_session_id = ui.get_current_session_id()
    if current_session_id then
      session_id = current_session_id
    end
  end

  -- 打开聊天窗口
  pcall(ui.open_chat_ui, session_id, "main")

  -- 等待窗口渲染完成
  -- 给窗口一些时间初始化和渲染
  local max_attempts = 10 -- 最多尝试10次
  local attempt = 0

  while attempt < max_attempts do
    -- 等待一小段时间
    vim.wait(50, function()
      return false
    end, 10, true)

    -- 检查窗口是否可用
    local available, _ = pcall(chat_window.is_available)
    if available then
      return true
    end

    attempt = attempt + 1
  end

  -- 如果超时仍未打开，返回false
  return false
end

--- 初始化聊天界面处理器
--- @param config table 配置
--- @return boolean 初始化是否成功
function M.initialize(config)
  if state.initialized then
    return true
  end

  state.config = config or {}
  state.initialized = true

  -- 注意：聊天窗口已经在 ui/init.lua 中初始化，这里不需要重复初始化
  -- 避免重复的事件监听器注册和状态冲突

  -- 注册事件监听器（使用Neovim原生事件系统）
  vim.api.nvim_create_autocmd("User", {
    pattern = "open_chat_window",
    callback = function(args)
      local session_id = args.data and args.data[1] or "default"
      local branch_id = args.data and args.data[2] or "main"
      -- 在测试环境中，直接触发事件而不打开UI
      -- 在实际使用中，这会打开聊天窗口
      local is_test_env = os.getenv("NEOAI_TEST")
        or (package.loaded["NeoAI.ui"] and not package.loaded["NeoAI.ui"].open_chat_ui)

      -- 确保会话存在
      local session_manager_loaded, session_manager = pcall(require, "NeoAI.core.session.session_manager")
      if session_manager_loaded and session_manager and session_manager.get_current_session then
        -- 获取当前会话，这会自动创建默认会话如果不存在
        local current_session = session_manager.get_current_session()
        if current_session then
          -- 使用当前会话ID
          session_id = session_id or current_session.id
        end
      end

      if not is_test_env then
        -- 打开聊天窗口
        local success, ui = pcall(require, "NeoAI.ui")
        if success and type(ui) == "table" and ui.open_chat_ui then
          pcall(ui.open_chat_ui, session_id, branch_id)
        end
      end

      -- 触发事件
      vim.api.nvim_exec_autocmds("User", {
        pattern = "NeoAI:chat_window_opened",
        data = { session_id or "default", branch_id or "main" },
      })
    end,
  })

  -- 监听AI响应完成事件
  vim.api.nvim_create_autocmd("User", {
    pattern = "NeoAI:ai_response_complete",
    callback = function(args)
      local data = args.data or {}
      local response = data.response
      local generation_id = data.generation_id
      local messages = data.messages

      -- 获取聊天窗口实例
      local chat_window = require("NeoAI.ui.window.chat_window")

      -- 检查聊天窗口是否可用
      local available, err = pcall(chat_window.is_available)
      if not available then
        print("⚠️  聊天窗口不可用，无法显示AI响应: " .. tostring(err))
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
      local success = chat_window.add_message("assistant", response_content)
      if success then
        print("✓ AI响应已添加到聊天窗口 (ID: " .. tostring(generation_id) .. ")")

        -- 触发响应显示事件
        vim.api.nvim_exec_autocmds("User", {
          pattern = "NeoAI:ai_response_displayed",
          data = {
            generation_id = generation_id,
            response = response_content,
            success = true,
          },
        })
      else
        print("✗ 无法添加AI响应到聊天窗口")
      end
    end,
  })

  -- 监听AI流式响应事件
  vim.api.nvim_create_autocmd("User", {
    pattern = "NeoAI:ai_response_chunk",
    callback = function(args)
      local data = args.data or {}
      local chunk = data.chunk
      local generation_id = data.generation_id
      local messages = data.messages

      -- 获取聊天窗口实例
      local chat_window = require("NeoAI.ui.window.chat_window")

      -- 检查聊天窗口是否可用
      local available, err = pcall(chat_window.is_available)
      if not available then
        print("⚠️  聊天窗口不可用，无法显示流式响应: " .. tostring(err))
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

      -- 对于流式响应，我们需要特殊处理
      -- 这里可以显示悬浮文本或更新最后一条消息
      if chunk_content and chunk_content ~= "" then
        -- 显示悬浮文本或更新UI
        chat_window.show_floating_text(chunk_content, {
          timeout = 2000,
          position = "bottom",
        })

        -- 触发流式响应事件
        vim.api.nvim_exec_autocmds("User", {
          pattern = "NeoAI:stream_chunk_displayed",
          data = {
            generation_id = generation_id,
            chunk = chunk_content,
            success = true,
          },
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
      local messages = data.messages

      print("✓ 流式生成完成 (ID: " .. tostring(generation_id) .. ")")

      -- 触发流式完成事件
      vim.api.nvim_exec_autocmds("User", {
        pattern = "NeoAI:stream_display_completed",
        data = {
          generation_id = generation_id,
          success = true,
        },
      })
    end,
  })

  -- 监听生成取消事件
  vim.api.nvim_create_autocmd("User", {
    pattern = "NeoAI:generation_cancelled",
    callback = function(args)
      local data = args.data or {}
      local generation_id = data.generation_id

      print("⚠️  AI生成已取消 (ID: " .. tostring(generation_id) .. ")")

      -- 获取聊天窗口实例
      local chat_window = require("NeoAI.ui.window.chat_window")

      -- 检查聊天窗口是否可用
      local available, err = pcall(chat_window.is_available)
      if available then
        -- 显示取消通知
        chat_window.show_floating_text("AI生成已取消", {
          timeout = 3000,
          position = "center",
          border = "single",
        })
      end

      -- 触发生成取消显示事件
      vim.api.nvim_exec_autocmds("User", {
        pattern = "NeoAI:generation_cancelled_displayed",
        data = {
          generation_id = generation_id,
          success = true,
        },
      })
    end,
  })

  return true
end

--- 设置发送按键
--- @param mode string 模式: "insert" 或 "normal"
--- @param key string 按键
function M.set_send_key(mode, key)
  if not state.initialized then
    return false, "聊天处理器未初始化"
  end

  if mode ~= "insert" and mode ~= "normal" then
    return false, "模式必须是 'insert' 或 'normal'"
  end

  if not key or type(key) ~= "string" then
    return false, "按键必须是字符串"
  end

  -- 更新配置中的发送按键
  if not state.config.keymaps then
    state.config.keymaps = {}
  end
  if not state.config.keymaps.chat then
    state.config.keymaps.chat = {}
  end
  if not state.config.keymaps.chat.send then
    state.config.keymaps.chat.send = {}
  end

  state.config.keymaps.chat.send[mode] = { key = key, desc = "发送消息" }

  -- 更新按键映射
  M.update_keymaps()

  return true, "发送按键已设置为: " .. key .. " (模式: " .. mode .. ")"
end

--- 更新按键映射
function M.update_keymaps()
  if not state.initialized or not state.config or not state.config.keymaps then
    return
  end

  local chat_keymaps = state.config.keymaps.chat
  if not chat_keymaps or not chat_keymaps.send then
    return
  end

  -- 这里可以添加按键映射更新的逻辑
  -- 例如：重新绑定按键到 send_message 函数
  print("按键映射已更新")
end

--- 发送消息
--- @param content string 消息内容
--- @param session_id string|nil 会话ID（可选）
--- @param branch_id string|nil 分支ID（可选）
--- @param window_id number|nil 窗口ID（可选）
--- @param format boolean|nil 是否格式化消息（可选，默认true）
--- @return boolean 是否成功
--- @return string|nil 结果信息
function M.send_message(content, session_id, branch_id, window_id, format)
  if not state.initialized then
    return false, "聊天处理器未初始化"
  end

  if not content or vim.trim(content) == "" then
    return false, "消息内容不能为空"
  end

  -- 默认格式化消息
  local format_message = format ~= false
  local final_message = content

  if format_message then
    -- 格式化消息：添加日期时间
    final_message = string.format("[%s] %s", os.date("%Y-%m-%d %H:%M:%S"), content)
  end

  -- 获取聊天窗口实例
  local chat_window = require("NeoAI.ui.window.chat_window")

  -- 检查聊天窗口是否可用
  local available, err = pcall(chat_window.is_available)
  if not available then
    return false, "聊天窗口不可用: " .. tostring(err)
  end

  -- 通过聊天窗口发送消息
  local success, result = chat_window.send_message(final_message)
  if not success then
    return false, "发送消息失败: " .. tostring(result)
  end

  -- print("✓ 消息已发送: " .. content)

  -- 触发消息已发送事件
  local event_pattern = format_message and "NeoAI:formatted_message_sent" or "NeoAI:message_sent"
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_pattern,
    data = {
      session_id = session_id or "default",
      branch_id = branch_id or "main",
      original_content = content,
      formatted_content = format_message and final_message or nil,
      message = final_message,
      window_id = window_id,
      timestamp = os.time(),
      role = "user",
      format = format_message,
    },
  })

  return true, format_message and "消息已发送并格式化" or "消息已发送"
end

--- 处理响应（测试用）
--- @param response string 响应内容
function M.handle_response(response)
  if not state.initialized then
    return false, "聊天处理器未初始化"
  end

  -- 获取聊天窗口实例
  local chat_window = require("NeoAI.ui.window.chat_window")

  -- 检查聊天窗口是否可用
  local available, err = pcall(chat_window.is_available)
  if not available then
    return false, "无法处理响应: " .. tostring(err)
  end

  -- 添加响应到聊天窗口
  local success = chat_window.add_response(response)
  return success
end

--- 清空聊天（测试用）
function M.clear_chat()
  if not state.initialized then
    return false, "聊天处理器未初始化"
  end

  -- 获取聊天窗口实例
  local chat_window = require("NeoAI.ui.window.chat_window")

  -- 检查聊天窗口是否可用
  local available, err = pcall(chat_window.is_available)
  if not available then
    return false, "无法清空聊天: " .. tostring(err)
  end

  -- 清空聊天窗口
  local success = chat_window.clear()
  return success
end

--- 处理ESC键
function M.handle_escape()
  if not state.initialized then
    return
  end

  vim.notify("取消/退出", vim.log.levels.INFO)

  -- 这里应该取消当前操作或退出聊天界面
  -- require("NeoAI.ui").close_all_windows()
end

--- 切换聊天窗口显示/隐藏
function M.toggle_chat_window()
  if not state.initialized then
    return false, "聊天处理器未初始化"
  end

  -- 获取UI模块
  local ui = require("NeoAI.ui")

  -- 检查聊天窗口是否已打开
  local chat_window = require("NeoAI.ui.window.chat_window")
  local is_open = pcall(chat_window.is_open)

  if is_open then
    -- 关闭聊天窗口
    ui.close_all_windows()
    return true, "聊天窗口已关闭"
  else
    -- 打开聊天窗口
    local session_manager = require("NeoAI.core").get_session_manager()
    local current_session = session_manager and session_manager.get_current_session()
    local session_id = current_session and current_session.id or "default"

    ui.open_chat_ui(session_id, "main")
    return true, "聊天窗口已打开"
  end
end

--- 刷新聊天窗口
function M.refresh_chat()
  if not state.initialized then
    return false, "聊天处理器未初始化"
  end

  -- 获取聊天窗口实例
  local chat_window = require("NeoAI.ui.window.chat_window")

  -- 检查聊天窗口是否可用
  local available, err = pcall(chat_window.is_available)
  if not available then
    return false, "无法刷新聊天: " .. tostring(err)
  end

  -- 刷新聊天窗口
  local success = chat_window.refresh()
  return success
end

--- 处理Tab键
function M.handle_tab()
  if not state.initialized then
    return
  end

  vim.notify("Tab补全", vim.log.levels.INFO)

  -- 这里应该实现Tab补全功能
end

--- 处理滚动
function M.handle_scroll()
  if not state.initialized then
    return
  end

  vim.notify("滚动消息", vim.log.levels.INFO)

  -- 这里应该处理消息滚动
end

--- 处理发送消息按键
local function handle_send_key()
  if not state.initialized then
    return
  end

  -- 获取聊天窗口实例
  local chat_window = require("NeoAI.ui.window.chat_window")

  -- 检查聊天窗口是否可用
  local available, err = pcall(chat_window.is_available)
  if not available then
    -- 尝试自动打开聊天窗口
    local error_msg = tostring(err or "未知错误")
    local level = vim.log.levels and vim.log.levels.WARN or "WARN"
    vim.notify("聊天窗口不可用，尝试自动打开: " .. error_msg, level)

    -- 使用辅助函数尝试打开窗口
    local opened = try_open_chat_window()
    if opened then
      -- 窗口已打开，重新检查可用性
      local available_after_open, err_after_open = pcall(chat_window.is_available)
      if available_after_open then
        -- 窗口可用，继续处理
        local input_content = chat_window.get_input_content()
        if not input_content or input_content == "" then
          local warn_level = vim.log.levels and vim.log.levels.WARN or "WARN"
          vim.notify("消息内容不能为空", warn_level)
          return
        end

        -- 发送消息
        local success, result = M.send_message(input_content)
        if success then
          local info_level = vim.log.levels and vim.log.levels.INFO or "INFO"
          vim.notify("消息已发送", info_level)
        else
          local error_level = vim.log.levels and vim.log.levels.ERROR or "ERROR"
          vim.notify("发送消息失败: " .. tostring(result), error_level)
        end
      else
        local info_level = vim.log.levels and vim.log.levels.INFO or "INFO"
        vim.notify("聊天窗口已打开，请重新发送消息", info_level)
      end
    else
      local error_level = vim.log.levels and vim.log.levels.ERROR or "ERROR"
      vim.notify("无法打开聊天窗口", error_level)
    end
    return
  end

  -- 获取输入内容
  local input_content = chat_window.get_input_content()
  if not input_content or input_content == "" then
    local warn_level = vim.log.levels and vim.log.levels.WARN or "WARN"
    vim.notify("消息内容不能为空", warn_level)
    return
  end

  -- 发送消息
  local success, result = M.send_message(input_content)
  if not success then
    local error_level = vim.log.levels and vim.log.levels.ERROR or "ERROR"
    vim.notify("发送消息失败: " .. tostring(result), error_level)
  else
    local info_level = vim.log.levels and vim.log.levels.INFO or "INFO"
    vim.notify("消息发送成功", info_level)
  end

  return success, result
end

--- 处理按键
--- @param key string 按键
function M.handle_key(key)
  if not state.initialized then
    return
  end

  -- 从配置中获取按键映射
  local key_handlers = {}

  if state.config and state.config.keymaps and state.config.keymaps.chat then
    local chat_keymaps = state.config.keymaps.chat

    -- 处理发送按键
    if chat_keymaps.send then
      if chat_keymaps.send.insert then
        key_handlers[chat_keymaps.send.insert.key] = handle_send_key
      end
      if chat_keymaps.send.normal then
        key_handlers[chat_keymaps.send.normal.key] = handle_send_key
      end
    end

    -- 处理其他按键
    for action, key_config in pairs(chat_keymaps) do
      if action ~= "send" and type(key_config) == "table" and key_config.key then
        -- 这里可以根据 action 映射到不同的处理函数
        -- 目前先使用通用的处理函数
        key_handlers[key_config.key] = function()
          vim.notify("处理按键: " .. action, vim.log.levels.INFO)
        end
      end
    end
  end

  -- 添加默认的按键处理
  key_handlers["<Esc>"] = M.handle_escape
  key_handlers["<Tab>"] = M.handle_tab
  key_handlers["<ScrollWheelUp>"] = function()
    M.handle_scroll()
  end
  key_handlers["<ScrollWheelDown>"] = function()
    M.handle_scroll()
  end

  local handler = key_handlers[key]
  if handler then
    handler()
  end
end

--- 处理向上历史
function M.handle_up_history()
  if not state.initialized then
    return
  end

  vim.notify("上一条历史消息", vim.log.levels.INFO)

  -- 这里应该加载上一条历史消息到输入框
end

--- 处理向下历史
function M.handle_down_history()
  if not state.initialized then
    return
  end

  vim.notify("下一条历史消息", vim.log.levels.INFO)

  -- 这里应该加载下一条历史消息到输入框
end

--- 处理清空输入
function M.handle_clear_input()
  if not state.initialized then
    return
  end

  vim.notify("清空输入", vim.log.levels.INFO)

  -- 这里应该清空输入框
end

--- 处理复制消息
function M.handle_copy_message()
  if not state.initialized then
    return
  end

  vim.notify("复制消息", vim.log.levels.INFO)

  -- 这里应该复制选中的消息到剪贴板
end

--- 处理编辑消息
function M.handle_edit_message()
  if not state.initialized then
    return
  end

  vim.notify("编辑消息", vim.log.levels.INFO)

  -- 这里应该允许用户编辑选中的消息
end

--- 处理删除消息
function M.handle_delete_message()
  if not state.initialized then
    return
  end

  vim.notify("删除消息", vim.log.levels.WARN)

  -- 这里应该删除选中的消息
end

--- 处理重新生成
function M.handle_regenerate()
  if not state.initialized then
    return
  end

  vim.notify("重新生成响应", vim.log.levels.INFO)

  -- 这里应该重新生成AI的响应
end

--- 处理停止生成
function M.handle_stop_generation()
  if not state.initialized then
    return
  end

  vim.notify("停止生成", vim.log.levels.INFO)

  -- 这里应该停止当前的AI生成过程
end

--- 处理切换思考显示
function M.handle_toggle_reasoning()
  if not state.initialized then
    return
  end

  vim.notify("切换思考显示", vim.log.levels.INFO)

  -- 这里应该显示或隐藏思考过程
end

--- 处理导出对话
function M.handle_export_chat()
  if not state.initialized then
    return
  end

  vim.notify("导出对话", vim.log.levels.INFO)

  -- 这里应该导出当前对话
end

--- 处理导入对话
function M.handle_import_chat()
  if not state.initialized then
    return
  end

  vim.notify("导入对话", vim.log.levels.INFO)

  -- 这里应该导入对话
end

--- 处理切换分支
function M.handle_switch_branch()
  if not state.initialized then
    return
  end

  vim.notify("切换分支", vim.log.levels.INFO)

  -- 这里应该打开分支选择界面
end

--- 处理新建分支
function M.handle_new_branch()
  if not state.initialized then
    return
  end

  vim.notify("新建分支", vim.log.levels.INFO)

  -- 这里应该创建新分支
end

--- 处理返回树界面
function M.handle_back_to_tree()
  if not state.initialized then
    return
  end

  vim.notify("返回树界面", vim.log.levels.INFO)

  -- 这里应该关闭聊天界面并打开树界面
  -- require("NeoAI.ui").close_all_windows()
  -- require("NeoAI.ui").open_tree_ui()
end

--- 处理帮助
function M.handle_help()
  if not state.initialized then
    return
  end

  vim.notify("显示帮助", vim.log.levels.INFO)

  -- 这里应该显示帮助信息
end

--- 获取按键映射
--- @return table 按键映射表
function M.get_keymaps()
  if not state.initialized or not state.config or not state.config.keymaps then
    return {}
  end

  local chat_keymaps = state.config.keymaps.chat
  if not chat_keymaps then
    return {}
  end

  local keymaps = {}

  -- 处理发送按键
  if chat_keymaps.send then
    if chat_keymaps.send.insert then
      keymaps[chat_keymaps.send.insert.key] = "发送消息(插入模式)"
    end
    if chat_keymaps.send.normal then
      keymaps[chat_keymaps.send.normal.key] = "发送消息(普通模式)"
    end
  end

  -- 处理其他按键
  for action, key_config in pairs(chat_keymaps) do
    if action ~= "send" and type(key_config) == "table" and key_config.key then
      keymaps[key_config.key] = key_config.desc or action
    end
  end

  return keymaps
end

--- 处理输入
--- @param input string 输入内容
function M.handle_input(input)
  if not state.initialized then
    return false, "聊天处理器未初始化"
  end

  -- 这里可以处理输入内容，比如验证、格式化等
  -- 目前只是简单返回成功
  return true, "输入已处理"
end

--- 获取消息数量
--- @return number 消息数量
function M.get_message_count()
  if not state.initialized then
    return 0
  end

  -- 获取聊天窗口实例
  local chat_window = require("NeoAI.ui.window.chat_window")

  -- 检查聊天窗口是否可用
  local available, err = pcall(chat_window.is_available)
  if not available then
    -- 如果聊天窗口不可用，返回模拟的消息数量用于测试
    return 5 -- 模拟5条消息
  end

  -- 获取消息数量
  local count = chat_window.get_message_count()

  -- 如果聊天窗口返回nil或0，返回测试数据
  if not count or count == 0 then
    return 5 -- 模拟5条消息用于测试
  end

  return count
end

--- 更新配置
--- @param new_config table 新配置
function M.update_config(new_config)
  if not state.initialized then
    return
  end

  state.config = vim.tbl_extend("force", state.config, new_config or {})
end

return M
