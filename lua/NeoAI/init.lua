local backend = require("NeoAI.backend")
local ui = require("NeoAI.ui")
local config = require("NeoAI.config")

local M = {}
local final_config = nil

function M.setup(user_config)
  -- 初始化：合并用户配置和默认配置
  user_config = user_config or {}

  -- 使用默认配置作为基础，用户配置会覆盖对应的字段
  final_config = vim.tbl_deep_extend("force", config.defaults, user_config)

  backend.setup({
    -- 后端配置
    config_dir = final_config.background.config_dir,
    config_file = final_config.background.config_file,
  })

  ui.setup({
    -- UI配置
    width = final_config.ui.width,
    height = final_config.ui.height,
    border = final_config.ui.border,
    auto_scroll = final_config.ui.auto_scroll,
    show_timestamps = final_config.ui.show_timestamps,
    show_role_icons = final_config.show_role_icons,
    role_icons = final_config.role_icons,
    colors = final_config.colors,
    keymaps = final_config.keymaps,
  })

  -- 设置命令
  M.setup_commands()

  -- 设置快捷键
  M.setup_keymaps(final_config.keymaps)

  vim.notify("[NeoAI] 插件已加载")
end

function M.setup_commands()
  -- 创建命令
  vim.api.nvim_create_user_command("NeoAIOpen", function(opts)
    -- 打开聊天，使用配置中的默认模式
    local mode = opts.args ~= "" and opts.args or final_config.ui.default_mode

    if mode == "float" then
      ui.open_float()
    elseif mode == "split" then
      ui.open_split()
    elseif mode == "tab" then
      ui.open_tab()
    else
      vim.notify("未知模式: " .. mode .. " (可用: float, split, tab)")
    end
  end, {
    nargs = "?",
    complete = function()
      return { "float", "split", "tab" }
    end,
  })

  -- 关闭聊天
  vim.api.nvim_create_user_command("NeoAIClose", ui.close, {})

  vim.api.nvim_create_user_command("NeoAISend", function(opts)
    -- 发送消息
    if opts.args and opts.args ~= "" then
      backend.send_message(opts.args)
      ui.update_display()
    end
  end, { nargs = "+" })

  vim.api.nvim_create_user_command("NeoAINew", function(opts)
    -- 新建会话
    local name = opts.args ~= "" and opts.args or nil
    backend.new_session(name)
    vim.notify("新会话已创建: " .. backend.sessions[backend.current_session].name)

    if ui.is_open then
      ui.update_display()
    end
  end, { nargs = "?" })

  vim.api.nvim_create_user_command("NeoAISwitch", function(opts)
    -- 切换会话
    local session_id = tonumber(opts.args)
    if session_id and backend.sessions[session_id] then
      backend.current_session = session_id
      vim.notify("切换到会话: " .. backend.sessions[session_id].name)

      if ui.is_open then
        ui.update_display()
      end
    else
      vim.notify("无效的会话ID")
    end
  end, { nargs = 1 })

  vim.api.nvim_create_user_command("NeoAIList", function()
    -- 列出会话
    vim.notify("=== 会话列表 ===")
    for id, session in pairs(backend.sessions) do
      local current = (id == backend.current_session) and " [当前]" or ""
      vim.notify(string.format("%d. %s (%d条消息)%s", id, session.name, #session.messages, current))
    end
  end, {})

  vim.api.nvim_create_user_command("NeoAIExport", function(opts)
    -- 导出会话
    if backend.current_session then
      local filepath = opts.args ~= "" and opts.args or nil
      backend.export_session(backend.current_session, filepath)
      vim.notify("会话已导出: " .. (filepath or backend.config_file))
    end
  end, { nargs = "?" })

  vim.api.nvim_create_user_command("NeoAIImport", function(opts)
    -- 导入会话
    local filepath = opts.args ~= "" and opts.args or nil
    local imported = backend.import_sessions(filepath)
    vim.notify("已导入 " .. #imported .. " 个会话")
  end, { nargs = "?" })

  vim.api.nvim_create_user_command("NeoAIMode", function(opts)
    -- 切换UI模式
    local mode = opts.args
    if mode == "float" or mode == "split" or mode == "tab" then
      ui.switch_mode(mode)
    else
      vim.notify("可用模式: float, split, tab")
    end
  end, { nargs = 1 })

  vim.api.nvim_create_user_command("NeoAIStats", function()
    -- 获取统计
    if backend.current_session then
      local stats = backend.get_session_stats(backend.current_session)
      vim.notify("=== 会话统计 ===")
      vim.notify("总消息数: " .. stats.total_messages)
      vim.notify("用户消息: " .. stats.user_messages)
      vim.notify("AI消息: " .. stats.ai_messages)
      vim.notify("可编辑消息: " .. stats.editable_messages)
      vim.notify("持续时间: " .. stats.duration_minutes .. " 分钟")
    end
  end, {})
end

function M.setup_keymaps(keymaps)
  -- 快捷键设置已移至 ui.lua 中作为 buffer-local 快捷键处理
  -- 不再注册全局快捷键，仅在聊天 buffer 中生效
end

function M.toggle_message_edit(message_id)
  -- 切换消息可编辑状态
  if backend.current_session then
    backend.toggle_editability(backend.current_session, message_id)
  end
end

function M.get_backend()
  -- 获取后端对象（用于扩展）
  return backend
end

function M.get_ui()
  -- 获取UI对象
  return ui
end

function M.get_config()
  -- 获取当前配置
  return {
    backend = {
      config_dir = backend.config_dir,
      config_file = backend.config_file,
    },
    ui = ui.config,
  }
end

return M
