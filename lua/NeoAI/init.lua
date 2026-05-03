--- NeoAI 主入口
--- 职责：初始化所有模块、注册命令和快捷键
--- 闭包内私有状态：core_ref, ui_ref, tools_ref（初始化后赋值）

local logger = require("NeoAI.utils.logger")
local config_merger = require("NeoAI.core.config.merger")
local core = require("NeoAI.core")
local ui = require("NeoAI.ui")
local tools = require("NeoAI.tools")
local state_manager = require("NeoAI.core.config.state")

-- ========== 闭包内私有状态 ==========
local core_ref
local ui_ref
local tools_ref

-- ========== 公共接口 ==========
local M = {}

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
    if ui_ref then
      ui_ref.open_tree_ui()
    else
      error("NeoAI not initialized. Call setup() first.")
    end
  end, {
    desc = "打开NeoAI树界面",
  })

  -- NeoAIChat 命令：打开聊天界面
  vim.api.nvim_create_user_command("NeoAIChat", function()
    if ui_ref then
      ui_ref.open_chat_ui()
    else
      error("NeoAI not initialized. Call setup() first.")
    end
  end, {
    desc = "打开NeoAI聊天界面",
  })

  -- NeoAIKeymaps 命令：显示当前键位配置
  vim.api.nvim_create_user_command("NeoAIKeymaps", function()
    if core_ref then
      local keymap_manager = core_ref.get_keymap_manager()
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
    if ui_ref then
      local chat_window = ui_ref.get_chat_window()
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
  local config = state_manager.get_config()
  if not config or not config.keymaps then
    return
  end

  local global_keymaps = config.keymaps.global
  if not global_keymaps then
    return
  end

  -- 获取键位管理器
  if not core_ref then
    local warn_level = vim.log.levels and vim.log.levels.WARN or "WARN"
    vim.notify("[NeoAI] 核心模块未初始化，无法注册快捷键", warn_level)
    return
  end

  local keymap_manager = core_ref.get_keymap_manager()
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
          if ui_ref then ui_ref.open_tree_ui() end
        end, { desc = desc })
      elseif action == "open_chat" then
        vim.keymap.set("n", key, function()
          if ui_ref then ui_ref.open_chat_ui() end
        end, { desc = desc })
      elseif action == "close_all" then
        vim.keymap.set("n", key, function()
          if ui_ref then ui_ref.close_all_windows() end
        end, { desc = desc })
      elseif action == "toggle_ui" then
        vim.keymap.set("n", key, function()
          if ui_ref then
            local windows = ui_ref.list_windows()
            if windows and #windows > 0 then
              ui_ref.close_all_windows()
            else
              ui_ref.open_tree_ui()
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
  if state_manager.is_initialized() then
    return M
  end

  -- 处理配置：验证 → 合并 → 清理，一步完成
  local config = config_merger.process_config(user_config)

  -- 初始化统一状态管理器
  state_manager.initialize(config)

  -- 初始化核心模块
  core_ref = core.initialize(config)

  -- 初始化UI模块
  ui_ref = ui.initialize(config)

  -- 初始化工具系统
  tools_ref = tools.initialize(config.tools or {})

  -- 延迟将工具注册表注入 AI 引擎（等异步加载的内置工具完成后）
  vim.schedule(function()
    local ai_engine = core_ref.get_ai_engine()
    if ai_engine and ai_engine.set_tools then
      local registered_tools = tools_ref.get_tools()
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
  end)

  -- 注册命令和快捷键
  register_commands()
  register_global_keymaps()

  -- 退出事件由 history_manager 内部的 VimLeavePre 统一处理（同步保存）
  -- 不要在 init.lua 中重复注册，避免退出时多次保存导致死锁
  -- 同时避免在退出过程中调用 cancel_generation（会尝试取消 HTTP 请求和触发事件）

  -- 注册文件编码自动命令
  vim.api.nvim_create_autocmd("BufRead", {
    pattern = { "*.log", "sessions.json" },
    group = vim.api.nvim_create_augroup("NeoAIEncoding", { clear = true }),
    callback = function()
      vim.bo.fileencoding = "utf-8"
    end,
  })

  -- 自动运行测试
  M._auto_run_tests(config)

  local info_level = vim.log.levels and vim.log.levels.INFO or "INFO"
  vim.notify("[NeoAI] 插件已初始化，命令和快捷键已注册", info_level)

  return M
end

--- 打开NeoAI主界面
function M.open_neoai()
  if not state_manager.is_initialized() then
    error("NeoAI not initialized. Call setup() first.")
  end
  ui_ref.open_chat_ui()
end

--- 关闭所有界面
function M.close_all()
  if ui_ref then
    ui_ref.close_all_windows()
  end
end

--- 获取会话管理器
function M.get_session_manager()
  if not core_ref then error("Core not initialized") end
  return core_ref.get_session_manager()
end

--- 获取AI引擎
function M.get_ai_engine()
  if not core_ref then error("Core not initialized") end
  return core_ref.get_ai_engine()
end

--- 获取工具系统
function M.get_tools()
  if not tools_ref then error("Tools not initialized") end
  return tools_ref
end

--- 获取键位配置管理器
function M.get_keymap_manager()
  if not core_ref then error("Core not initialized") end
  return core_ref.get_keymap_manager()
end

--- 自动运行测试（内部使用）
--- 根据配置在 VimEnter 后延迟执行所有测试
--- @param config table 完整配置
function M._auto_run_tests(config)
  local test_config = config and config.test
  if not test_config or not test_config.auto_test then
    return
  end

  local delay_ms = test_config.delay_ms or 1500

  -- 注册 VimEnter 自动命令，延迟后运行测试
  vim.api.nvim_create_autocmd("VimEnter", {
    once = true,
    callback = function()
      vim.defer_fn(function()
        local ok, tests = pcall(require, "NeoAI.tests")
        if not ok then
          vim.notify("[NeoAI] 测试模块未找到，跳过自动测试", vim.log.levels.WARN)
          return
        end

        vim.notify("[NeoAI] 开始自动运行测试...", vim.log.levels.INFO)
        local results = tests.run_all()

        local msg = string.format(
          "[NeoAI] 测试完成: %d 通过, %d 失败",
          results.passed or 0,
          results.failed or 0
        )
        if results.failed and results.failed > 0 then
          vim.notify(msg, vim.log.levels.WARN)
          for _, err in ipairs(results.errors or {}) do
            vim.notify("  " .. err, vim.log.levels.WARN)
          end
        else
          vim.notify(msg, vim.log.levels.INFO)
        end
      end, delay_ms)
    end,
  })
end

return M
