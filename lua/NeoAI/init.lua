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
        local error_level = vim.log.levels and vim.log.levels.ERROR or "ERROR"
        vim.notify("[NeoAI] 聊天窗口不可用", error_level)
      end
    else
      error("NeoAI not initialized. Call setup() first.")
    end
  end, {
    desc = "显示NeoAI聊天窗口状态",
  })
end

-- NeoAITestAll 命令：运行所有测试
vim.api.nvim_create_user_command("NeoAITestAll", function()
  M.test()
end, {
  desc = "运行所有NeoAI测试",
})

-- NeoAITest 命令：运行指定测试
vim.api.nvim_create_user_command("NeoAITest", function(opts)
  M.test(opts.args)
end, {
  desc = "运行指定NeoAI测试",
  nargs = 1,
  complete = function()
    local test_module = require("NeoAI.tests")
    local completions = {}
    for name, _ in pairs(test_module.tests) do
      table.insert(completions, name)
    end
    return completions
  end,
})

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

  -- 添加调试信息，标记配置来源
  config._debug_source = "main_init_lua"
  config._debug_timestamp = os.time()

  -- 初始化核心模块（传递整个配置）
  state.core = core.initialize(config)

  -- 初始化UI模块（传递完整配置）
  state.ui = ui.initialize(config)

  -- 初始化工具系统
  state.tools = tools.initialize(config.tools or {})

  state.config = config
  state.initialized = true

  -- 注册Neovim命令
  register_commands()

  -- 注册全局快捷键
  register_global_keymaps()

  local info_level = vim.log.levels and vim.log.levels.INFO or "INFO"
  vim.notify("[NeoAI] 插件已初始化，命令和快捷键已注册", info_level)

  -- 检查是否需要自动运行测试
  if config.test and config.test.auto_test then
    local delay_ms = config.test.delay_ms or 500

    -- 延迟执行测试
    vim.defer_fn(function()
      local info_level = vim.log.levels and vim.log.levels.INFO or "INFO"
      vim.notify("[NeoAI] 开始自动运行测试...", info_level)
      M.test()
    end, delay_ms)
  end

  return M
end

--- 打开NeoAI主界面
function M.open_neoai()
  if not state.initialized then
    error("NeoAI not initialized. Call setup() first.")
  end

  -- 根据配置选择默认打开的界面
  local default_ui = "tree"
  if state.config and state.config.ui and state.config.ui.default_ui then
    default_ui = state.config.ui.default_ui
  end

  if default_ui == "tree" then
    state.ui.open_tree_ui()
  elseif default_ui == "chat" then
    state.ui.open_chat_ui()
  else
    -- 默认回退到树界面
    state.ui.open_tree_ui()
  end
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

--- 获取工具系统
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

--- 运行测试套件
--- @param test_name string|nil 可选：指定运行的测试名称，如果为nil则运行所有测试
function M.test(test_name)
  -- 加载测试模块
  local test_module = require("NeoAI.tests")

  -- 如果指定了测试名称，只运行该测试
  if test_name then
    local test_to_run = test_module.tests[test_name]
    if test_to_run and test_to_run.run then
      print("🚀 运行指定测试: " .. test_name)
      print(string.rep("=", 50))

      local pcall_success, pcall_result = pcall(test_to_run.run)
      if pcall_success then
        -- pcall成功，检查测试函数的返回值
        if type(pcall_result) == "table" and #pcall_result >= 1 then
          local test_success = pcall_result[1]
          local test_message = pcall_result[2] or ""

          if test_success then
            print("✅ " .. test_name .. " 测试通过: " .. test_message)
          else
            print("❌ " .. test_name .. " 测试失败: " .. test_message)
          end
        else
          -- 测试函数没有返回预期的格式
          print("⚠️  " .. test_name .. " 测试返回了意外的格式: " .. type(pcall_result))
          print("❌ " .. test_name .. " 测试失败: 测试函数没有返回正确的格式 {success, message}")
        end
      else
        -- pcall失败，测试函数抛出了异常
        print("❌ " .. test_name .. " 测试失败（异常）: " .. tostring(pcall_result))
      end
    else
      print("⚠️ 未找到测试: " .. test_name)
      print("可用测试:")
      for name, _ in pairs(test_module.tests) do
        print("  - " .. name)
      end
    end
  else
    -- 运行所有测试
    test_module.run_all_tests()
  end
end

return M
