--- NeoAI 主入口
--- 职责：注册命令和快捷键，所有子模块懒加载到首次使用时
--- 闭包内私有状态：_lazy（懒加载状态），_config（合并后的完整配置）

-- ========== Neovim 版本兼容 polyfill（最早加载） ==========
-- vim.tbl_count / vim.tbl_contains 在 Neovim 0.10+ 引入
if vim.tbl_count == nil then
  vim.tbl_count = function(t)
    if type(t) ~= "table" then return 0 end
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
  end
end
if vim.tbl_contains == nil then
  vim.tbl_contains = function(t, value)
    if type(t) ~= "table" then return false end
    for _, v in pairs(t) do
      if v == value then return true end
    end
    return false
  end
end

-- ========== 闭包内私有状态 ==========
local _config  -- 合并后的完整配置
local _lazy = {
  core_initialized = false,
  ui_initialized = false,
  tools_initialized = false,
}

-- 模块引用缓存，避免 VimLeave 时重新 require 导致卡顿
local _async_orch_ref
local _tp_ref

-- ========== 公共接口 ==========
local M = {}

-- ========== 懒加载初始化 ==========

--- 确保核心模块已初始化
local function ensure_core()
  if _lazy.core_initialized then return end
  _lazy.core_initialized = true
  local core = require("NeoAI.core")
  core.initialize(_config)
end

--- 确保 UI 模块已初始化
local function ensure_ui()
  if _lazy.ui_initialized then return end
  _lazy.ui_initialized = true
  local ui = require("NeoAI.ui")
  ui.initialize(_config)
end

--- 延迟将工具注册表注入 tool_cycle 和 request_handler
local function defer_inject_tools()
  vim.defer_fn(function()
    local tools = require("NeoAI.tools")
    local tool_cycle = require("NeoAI.core.ai.tool_cycle")
    local request_handler = require("NeoAI.core.ai.request_handler")
    local registered_tools = tools.get_tools()
    local tools_map = {}
    local tool_defs = {}
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
      local tf = { name = tool_def.name, description = tool_def.description or ("执行 " .. tool_def.name .. " 操作") }
      local params = tool_def.parameters
      if params and type(params) == "table" then
        local has_props = false
        if params.properties then
          for _, _ in pairs(params.properties) do
            has_props = true
            break
          end
        end
        if has_props then
          local cp = { type = params.type or "object", properties = params.properties }
          if params.required and type(params.required) == "table" and #params.required > 0 then
            cp.required = params.required
          end
          tf.parameters = cp
        end
      end
      table.insert(tool_defs, { type = "function", ["function"] = tf })
    end
    tool_cycle.set_tools(tools_map)
    request_handler.set_tool_definitions(tool_defs)
  end, 50)
end

--- 确保工具系统已初始化
local function ensure_tools()
  if _lazy.tools_initialized then return end
  _lazy.tools_initialized = true
  local tools = require("NeoAI.tools")
  tools.initialize(_config)
  -- 工具注册完成后，延迟注入到 tool_cycle 和 request_handler
  defer_inject_tools()
end

--- 确保所有模块已初始化（首次打开界面时调用）
local function ensure_all()
  ensure_core()
  ensure_ui()
  ensure_tools()
end

-- ========== 注册命令 ==========

local function register_commands()
  vim.api.nvim_create_user_command("NeoAIOpen", function()
    M.open_neoai()
  end, { desc = "打开NeoAI主界面" })

  vim.api.nvim_create_user_command("NeoAIClose", function()
    M.close_all()
  end, { desc = "关闭所有NeoAI窗口" })

  vim.api.nvim_create_user_command("NeoAITree", function()
    ensure_all()
    local ui = require("NeoAI.ui")
    ui.open_tree_ui()
  end, { desc = "打开NeoAI树界面" })

  vim.api.nvim_create_user_command("NeoAIChat", function()
    ensure_all()
    local ui = require("NeoAI.ui")
    ui.open_chat_ui()
  end, { desc = "打开NeoAI聊天界面" })

  vim.api.nvim_create_user_command("NeoAIKeymaps", function()
    ensure_core()
    local core = require("NeoAI.core")
    local keymap_manager = core.get_keymap_manager()
    if keymap_manager then
      local formatted = keymap_manager.export_formatted()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(formatted, "\n", { plain = true }))
      vim.bo[buf].filetype = "markdown"
      vim.bo[buf].buftype = "nofile"
      vim.bo[buf].bufhidden = "wipe"
      local width = math.min(80, vim.o.columns - 10)
      local height = math.min(30, vim.o.lines - 10)
      local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor", width = width, height = height,
        col = math.floor((vim.o.columns - width) / 2),
        row = math.floor((vim.o.lines - height) / 2),
        style = "minimal", border = "rounded",
        title = "NeoAI 键位配置", title_pos = "center",
      })
      vim.wo[win].wrap = true
      vim.wo[win].cursorline = true
    else
      vim.notify("[NeoAI] 键位管理器不可用", vim.log.levels.ERROR)
    end
  end, { desc = "显示NeoAI键位配置" })

  vim.api.nvim_create_user_command("NeoAITest", function(opts)
    local ok, tests = pcall(require, "NeoAI.tests")
    if not ok then
      vim.notify("[NeoAI] 测试模块加载失败: " .. tostring(tests), vim.log.levels.ERROR)
      return
    end
    local args = opts.args
    local results
    if args and args ~= "" then
      local tests_to_run = {}
      for arg in args:gmatch("%S+") do table.insert(tests_to_run, arg) end
      results = tests.run_all(table.unpack(tests_to_run))
    else
      results = tests.run_all()
    end
    vim.notify(string.format("测试结果: %d 通过, %d 失败", results.passed, results.failed), vim.log.levels.INFO)
    if #results.errors > 0 then
      local error_msgs = {}
      for _, e in ipairs(results.errors) do table.insert(error_msgs, e) end
      vim.notify("失败的测试:\n  " .. table.concat(error_msgs, "\n  "), vim.log.levels.WARN)
    end
  end, { nargs = "*", desc = "运行 NeoAI 测试（不带参数运行全部，带参数运行指定测试）" })

  vim.api.nvim_create_user_command("NeoAIChatStatus", function()
    ensure_all()
    local ui = require("NeoAI.ui")
    local chat_window = ui.get_chat_window()
    if chat_window and chat_window.show_status then
      chat_window.show_status()
    else
      vim.notify("[NeoAI] 聊天窗口状态不可用", vim.log.levels.WARN)
    end
  end, { desc = "显示NeoAI聊天窗口状态" })
end

-- ========== 注册全局快捷键 ==========

local function register_global_keymaps()
  local config = _config or {}
  local global_keymaps = config.keymaps and config.keymaps.global
  if not global_keymaps then return end

  for action, key_config in pairs(global_keymaps) do
    if key_config and key_config.key then
      local key = key_config.key
      local desc = key_config.desc or ("[NeoAI] " .. action)

      if action == "open_tree" then
        vim.keymap.set("n", key, function()
          ensure_all()
          local ui = require("NeoAI.ui")
          ui.open_tree_ui()
        end, { desc = desc })
      elseif action == "open_chat" then
        vim.keymap.set("n", key, function()
          ensure_all()
          local ui = require("NeoAI.ui")
          ui.open_chat_ui()
        end, { desc = desc })
      elseif action == "close_all" then
        vim.keymap.set("n", key, function()
          if _lazy.ui_initialized then
            local ui = require("NeoAI.ui")
            ui.close_all_windows()
          end
        end, { desc = desc })
      elseif action == "toggle_ui" then
        vim.keymap.set("n", key, function()
          if _lazy.ui_initialized then
            local ui = require("NeoAI.ui")
            local windows = ui.list_windows()
            if windows and #windows > 0 then
              ui.close_all_windows()
            else
              ensure_all()
              local ui2 = require("NeoAI.ui")
              ui2.open_tree_ui()
            end
          else
            ensure_all()
            local ui2 = require("NeoAI.ui")
            ui2.open_tree_ui()
          end
        end, { desc = desc })
      end
    end
  end
end

-- ========== 公共 API ==========

--- 设置插件配置
--- @param user_config table 用户配置
--- @return table 插件实例
function M.setup(user_config)
  if _lazy.core_initialized then return M end

  -- 处理配置（仅此步骤同步执行，其余模块懒加载）
  local config_merger = require("NeoAI.core.config.merger")
  _config = config_merger.process_config(user_config)

  -- 缓存模块引用，避免 VimLeave 时重新 require 导致卡顿
  local ok_async, async_orch = pcall(require, "NeoAI.core.ai.async_orchestrator")
  if ok_async then _async_orch_ref = async_orch end
  local ok_tp, tp = pcall(require, "NeoAI.core.ai.thread_pool")
  if ok_tp then _tp_ref = tp end

  -- 注册命令和快捷键（轻量操作）
  register_commands()
  register_global_keymaps()

  -- VimLeave 清理
  vim.api.nvim_create_autocmd("VimLeave", {
    group = vim.api.nvim_create_augroup("NeoAICleanup", { clear = true }),
    callback = function()
      if _async_orch_ref then pcall(_async_orch_ref.shutdown) end
      if _tp_ref then pcall(_tp_ref.shutdown) end
    end,
    desc = "NeoAI: 清理所有跨实例锁和临时目录",
  })

  -- 注册文件编码自动命令
  vim.api.nvim_create_autocmd("BufRead", {
    pattern = { "*.log", "sessions.json" },
    group = vim.api.nvim_create_augroup("NeoAIEncoding", { clear = true }),
    callback = function()
      vim.bo.fileencoding = "utf-8"
    end,
  })

  vim.notify("[NeoAI] 插件已注册（模块将在首次使用时加载）", vim.log.levels.INFO)

  return M
end

--- 打开NeoAI主界面
function M.open_neoai()
  ensure_all()
  local ui = require("NeoAI.ui")
  ui.open_chat_ui()
end

--- 关闭所有界面
function M.close_all()
  if _lazy.ui_initialized then
    local ui = require("NeoAI.ui")
    ui.close_all_windows()
  end
end

--- 获取会话管理器
function M.get_session_manager()
  ensure_core()
  local core = require("NeoAI.core")
  return core.get_session_manager()
end

--- 获取AI引擎
function M.get_ai_engine()
  ensure_core()
  local core = require("NeoAI.core")
  return core.get_engine()
end

--- 获取工具系统
function M.get_tools()
  ensure_tools()
  local tools = require("NeoAI.tools")
  return tools
end

--- 获取键位配置管理器
function M.get_keymap_manager()
  ensure_core()
  local core = require("NeoAI.core")
  return core.get_keymap_manager()
end

return M
