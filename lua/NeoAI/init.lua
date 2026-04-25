local M = {}

-- 全局配置
local default_config = require("NeoAI.default_config")
local core = require("NeoAI.core")
local ui = require("NeoAI.ui")
local tools = require("NeoAI.tools")

-- 插件状态
local state = {
  initialized = false,
  config = nil,
  core = nil,
  ui = nil,
  tools = nil,
}

-- 内部函数：注册Neovim命令
local function register_commands()
  -- NeoAIOpen 命令：打开NeoAI主界面
  vim.api.nvim_create_user_command("NeoAIOpen", function()
    M.open_neoai()
  end, {
    desc = "打开NeoAI主界面",
  })

  -- NeoAIClose 命令：关闭所有界面
  vim.api.nvim_create_user_command("NeoAIClose", function()
    M.close_all()
  end, {
    desc = "关闭所有NeoAI窗口",
  })

  -- NeoAITree 命令：打开树界面
  vim.api.nvim_create_user_command("NeoAITree", function()
    if state.ui then
      state.ui.open_tree_ui()
    else
      error("NeoAI not initialized. Call setup() first.")
    end
  end, {
    desc = "打开NeoAI树界面",
  })

  -- NeoAIChat 命令：打开聊天界面
  vim.api.nvim_create_user_command("NeoAIChat", function()
    if state.ui then
      state.ui.open_chat_ui()
    else
      error("NeoAI not initialized. Call setup() first.")
    end
  end, {
    desc = "打开NeoAI聊天界面",
  })

  -- NeoAIKeymaps 命令：显示当前键位配置
  vim.api.nvim_create_user_command("NeoAIKeymaps", function()
    if state.core then
      local keymap_manager = state.core.get_keymap_manager()
      if keymap_manager then
        local formatted = keymap_manager.export_formatted()
        -- 创建临时缓冲区显示键位配置
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(formatted, "\n", { plain = true }))
        vim.bo[buf].filetype = "markdown"
        vim.bo[buf].buftype = "nofile"
        vim.bo[buf].bufhidden = "wipe"

        local width = math.min(80, vim.o.columns - 10)
        local height = math.min(30, vim.o.lines - 10)
        local win = vim.api.nvim_open_win(buf, true, {
          relative = "editor",
          width = width,
          height = height,
          col = math.floor((vim.o.columns - width) / 2),
          row = math.floor((vim.o.lines - height) / 2),
          style = "minimal",
          border = "rounded",
          title = "NeoAI 键位配置",
          title_pos = "center",
        })

        -- 设置窗口选项
        vim.wo[win].wrap = true
        vim.wo[win].cursorline = true
      else
        vim.notify("[NeoAI] 键位管理器不可用", vim.log.levels.ERROR)
      end
    else
      error("NeoAI not initialized. Call setup() first.")
    end
  end, {
    desc = "显示NeoAI键位配置",
  })

  -- NeoAIChatStatus 命令：显示聊天窗口状态
  vim.api.nvim_create_user_command("NeoAIChatStatus", function()
    if state.ui then
      local chat_window = state.ui.get_chat_window()
      if chat_window and chat_window.show_status then
        chat_window.show_status()
      else
        vim.notify("[NeoAI] 聊天窗口状态不可用", vim.log.levels.WARN)
      end
    else
      error("NeoAI not initialized. Call setup() first.")
    end
  end, {
    desc = "显示NeoAI聊天窗口状态",
  })
end

-- 内部函数：注册全局快捷键
local function register_global_keymaps()
  if not state.config or not state.config.keymaps then
    return
  end

  local global_keymaps = state.config.keymaps.global
  if not global_keymaps then
    return
  end

  -- 安全检查：确保核心模块已初始化
  if not state.core then
    local warn_level = vim.log.levels and vim.log.levels.WARN or "WARN"
    vim.notify("[NeoAI] 核心模块未初始化，无法注册快捷键", warn_level)
    return
  end

  -- 获取键位管理器
  local keymap_manager = state.core.get_keymap_manager()
  if not keymap_manager then
    local warn_level = vim.log.levels and vim.log.levels.WARN or "WARN"
    vim.notify("[NeoAI] 无法获取键位管理器", warn_level)
    return
  end

  -- 注册全局快捷键
  for action, key_config in pairs(global_keymaps) do
    if key_config and key_config.key then
      local key = key_config.key
      local desc = key_config.desc or ("[NeoAI] " .. action)

      -- 根据动作注册不同的功能
      if action == "open_tree" then
        vim.keymap.set("n", key, function()
          if state.ui then
            state.ui.open_tree_ui()
          end
        end, { desc = desc })
      elseif action == "open_chat" then
        vim.keymap.set("n", key, function()
          if state.ui then
            state.ui.open_chat_ui()
          end
        end, { desc = desc })
      elseif action == "close_all" then
        vim.keymap.set("n", key, function()
          if state.ui then
            state.ui.close_all_windows()
          end
        end, { desc = desc })
      elseif action == "toggle_ui" then
        vim.keymap.set("n", key, function()
          -- 切换UI显示：如果当前有窗口打开则关闭，否则打开树界面
          if state.ui then
            local windows = state.ui.list_windows()
            if windows and #windows > 0 then
              state.ui.close_all_windows()
            else
              state.ui.open_tree_ui()
            end
          end
        end, { desc = desc })
      end
    end
  end
end

--- 设置插件配置
--- @param user_config table 用户配置
--- @return table 插件实例
function M.setup(user_config)
  if state.initialized then
    return M
  end

  -- 验证和合并配置
  local config = default_config.validate_config(user_config)
  config = default_config.merge_defaults(config)
  config = default_config.sanitize_config(config)

  -- 同步配置到 default_config 模块，确保 get_preset/get_scenario_candidates 使用合并后的配置
  default_config.initialize(config)

  -- 添加调试信息，标记配置来源
  config._debug_source = "main_init_lua"
  config._debug_timestamp = os.time()

  -- 初始化核心模块（传递整个配置）
  state.core = core.initialize(config)

  -- 初始化UI模块（传递完整配置）
  state.ui = ui.initialize(config)

  -- 初始化工具系统
  state.tools = tools.initialize(config.tools or {})

  -- 将工具注册表中的工具传递给 AI 引擎，使工具定义能注入到请求中
  local ai_engine = state.core.get_ai_engine()
  if ai_engine and ai_engine.set_tools then
    local registered_tools = state.tools.get_tools()
    -- 将工具列表转换为 { tool_name = { func = ..., description = ..., parameters = ... } } 格式
    local tools_map = {}
    for _, tool_def in ipairs(registered_tools) do
      tools_map[tool_def.name] = {
        func = tool_def.func,
        description = tool_def.description or "",
        parameters = tool_def.parameters or {
          type = "object",
          properties = {},
          required = {},
        },
      }
    end
    ai_engine.set_tools(tools_map)
  end

  state.config = config
  state.initialized = true

  -- 初始化异步工作器
  local async_worker = require("NeoAI.utils.async_worker")
  async_worker.initialize()

  -- 注册Neovim命令
  register_commands()

  -- 注册全局快捷键
  register_global_keymaps()

  local info_level = vim.log.levels and vim.log.levels.INFO or "INFO"
  vim.notify("[NeoAI] 插件已初始化，命令和快捷键已注册", info_level)

  return M
end

--- 打开NeoAI主界面
function M.open_neoai()
  if not state.initialized then
    error("NeoAI not initialized. Call setup() first.")
  end

  -- 直接打开聊天界面，每次打开都会创建新的根会话
  -- 不传 session_id 参数，由 open_chat_ui 自动创建新根会话
  state.ui.open_chat_ui()
end

--- 关闭所有界面
function M.close_all()
  if state.ui then
    state.ui.close_all_windows()
  end
end

--- 获取会话管理器
--- @return table 会话管理器
function M.get_session_manager()
  if not state.core then
    error("Core not initialized")
  end

  return state.core.get_session_manager()
end

--- 获取AI引擎
--- @return table AI引擎
function M.get_ai_engine()
  if not state.core then
    error("Core not initialized")
  end

  return state.core.get_ai_engine()
end

-- 获取工具系统
--- @return table 工具系统
function M.get_tools()
  if not state.tools then
    error("Tools not initialized")
  end

  return state.tools
end

--- 获取键位配置管理器
--- @return table 键位配置管理器
function M.get_keymap_manager()
  if not state.core then
    error("Core not initialized")
  end

  return state.core.get_keymap_manager()
end

return M
