-- NeoAI 插件主入口文件
-- 负责初始化后端、UI、命令和快捷键
local backend = require("NeoAI.backend")
local ui = require("NeoAI.ui")
local config = require("NeoAI.config")

local M = {}

--- 检查系统是否安装了 curl
-- @return boolean 如果安装了 curl 返回 true，否则返回 false
function M.check_curl()
  if vim.fn.executable("curl") == 1 then
    return true
  else
    vim.notify("[NeoAI] 不会吧，不会吧，不会有人没装curl吧", vim.log.levels.ERROR)
    vim.notify("[NeoAI] No way, no way, no one hasn't installed curl, right?", vim.log.levels.ERROR)
    return false
  end
end

--- 插件初始化入口
-- @param user_config 用户自定义配置（可选）
function M.setup(user_config)
  -- 1. 接收用户配置
  user_config = user_config or {}

  -- 2. 传给 config.lua 进行验证和合并
  local validated_config, validation_errors = config.validate_and_merge(user_config)

  -- 3. 输出验证警告
  if validation_errors and #validation_errors > 0 then
    for _, error_msg in ipairs(validation_errors) do
      vim.notify("[NeoAI] 配置警告: " .. error_msg, vim.log.levels.WARN)
    end
  end

  -- 检查 curl 是否已安装
  M.check_curl()

  -- 初始化后端（会话管理、数据存储）
  backend.setup(validated_config)

  -- 设置语法高亮
  M.setup_highlights()

  -- 初始化 UI 界面
  ui.setup(validated_config)

  -- 注册 NeoVim 命令和快捷键
  M.setup_commands(validated_config)

  vim.notify("[NeoAI] 插件已加载")
end

--- 设置 NeoAI 相关的语法高亮组
function M.setup_highlights()
  -- 消息区域高亮（默认与普通文本一致）
  vim.api.nvim_set_hl(0, "NeoAIMessages", { default = true, link = "Normal" })
  -- 输入框区域高亮
  vim.api.nvim_set_hl(0, "NeoAIInput", { default = true, link = "Normal" })
end

--- 注册所有 NeoVim 用户命令和快捷键
-- @param final_config 合并后的完整配置
function M.setup_commands(final_config)
  -- 设置全局快捷键
  if final_config.keymaps and final_config.keymaps.chat and final_config.keymaps.chat.global then
    -- 打开聊天窗口
    if final_config.keymaps.chat.global.open then
      vim.keymap.set(
        "n",
        final_config.keymaps.chat.global.open.key,
        "<cmd>NeoAIOpen<CR>",
        { noremap = true, silent = true, desc = "NeoAI: " .. final_config.keymaps.chat.global.open.desc }
      )
    end

    -- 新建会话
    if final_config.keymaps.chat.global.new then
      vim.keymap.set(
        "n",
        final_config.keymaps.chat.global.new.key,
        "<cmd>NeoAINew<CR>",
        { noremap = true, silent = true, desc = "NeoAI: " .. final_config.keymaps.chat.global.new.desc }
      )
    end
  end

  -- NeoAIOpen: 打开聊天窗口，支持模式参数
  vim.api.nvim_create_user_command("NeoAIOpen", function(opts)
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
    nargs = "?", -- 可选参数
    complete = function()
      return { "float", "split", "tab" } -- 自动补全
    end,
  })

  -- NeoAIClose: 关闭聊天窗口
  vim.api.nvim_create_user_command("NeoAIClose", ui.close, {})

  -- NeoAISend: 直接发送消息
  vim.api.nvim_create_user_command("NeoAISend", function(opts)
    if opts.args and opts.args ~= "" then
      backend.send_message(opts.args)
      ui.update_display()
    end
  end, { nargs = "+" })

  -- NeoAINew: 创建新会话
  vim.api.nvim_create_user_command("NeoAINew", function(opts)
    local name = opts.args ~= "" and opts.args or nil
    backend.new_session(name)
    vim.notify("新会话已创建: " .. backend.sessions[backend.current_session].name)
    if ui.is_open then
      ui.update_display()
    end
  end, { nargs = "?" })

  -- NeoAISwitch: 切换到指定 ID 的会话
  vim.api.nvim_create_user_command("NeoAISwitch", function(opts)
    local session_id = tonumber(opts.args)
    if session_id and backend.sessions[session_id] then
      backend.sync_data(backend.current_session)
      backend.current_session = session_id
      vim.notify("切换到会话: " .. backend.sessions[session_id].name)
      if ui.is_open then
        ui.update_display()
      end
    else
      vim.notify("无效的会话ID")
    end
  end, { nargs = 1 })

  -- NeoAIList: 列出所有会话
  vim.api.nvim_create_user_command("NeoAIList", function()
    vim.notify("=== 会话列表 ===")
    for id, session in pairs(backend.sessions) do
      local current = (id == backend.current_session) and " [ 当前]" or ""
      vim.notify(string.format("%d. %s (%d条消息)%s", id, session.name, #session.messages, current))
    end
  end, {})

  -- NeoAIExport: 导出当前会话到 JSON 文件
  vim.api.nvim_create_user_command("NeoAIExport", function(opts)
    if backend.current_session then
      local filepath = opts.args ~= "" and opts.args or nil
      backend.export_session(backend.current_session, filepath)
      vim.notify("会话已导出: " .. (filepath or backend.config_file))
    end
  end, { nargs = "?" })

  -- NeoAIImport: 从 JSON 文件导入会话
  vim.api.nvim_create_user_command("NeoAIImport", function(opts)
    local filepath = opts.args ~= "" and opts.args or nil
    local imported = backend.import_sessions(filepath)
    vim.notify("已导入 " .. #imported .. " 个会话")
  end, { nargs = "?" })

  -- NeoAIMode: 切换 UI 模式
  vim.api.nvim_create_user_command("NeoAIMode", function(opts)
    local mode = opts.args
    if mode == "float" or mode == "split" or mode == "tab" then
      ui.switch_mode(mode)
    else
      vim.notify("可用模式: float, split, tab")
    end
  end, { nargs = 1 })

  -- NeoAITree: 切换会话树视图
  vim.api.nvim_create_user_command("NeoAITree", function()
    ui.toggle_history_tree()
  end, {})

  -- NeoAIStats: 显示当前会话统计信息
  vim.api.nvim_create_user_command("NeoAIStats", function()
    if backend.current_session then
      local stats = backend.get_session_stats(backend.current_session)
      vim.notify("=== 会话统计 ===")
      vim.notify("总消息数: " .. stats.total_messages)
      vim.notify("用户消息: " .. stats.user_messages)
      vim.notify("AI消息: " .. stats.ai_messages)
      vim.notify("可编辑消息: " .. stats.editable_messages)
      vim.notify("持续时间: " .. stats.duration_minutes .. "  分钟")
    end
  end, {})
end

--- 获取后端模块实例
-- @return table 后端模块
function M.get_backend()
  return backend
end

--- 获取 UI 模块实例
-- @return table UI 模块
function M.get_ui()
  return ui
end

return M
