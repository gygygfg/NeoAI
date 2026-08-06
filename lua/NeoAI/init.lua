--- NeoAI 主入口
--- @module NeoAI
--- 极薄入口：setup() 仅做 配置加载 → 内核引导 → 注册命令/快捷键。
--- 业务模块一律懒加载，首次使用时才 require。

local kernel = require("NeoAI.kernel")
local config_store = require("NeoAI.kernel.config_store")

-- ========== 私有状态 ==========

local state = {
  loaded = false,
}

local M = {}

-- ========== 私有函数 ==========

--- 注册 Neovim 用户命令（全部懒加载业务模块）
local function _register_commands()
  vim.api.nvim_create_user_command("NeoAIOpen", function()
    require("NeoAI.ui").open_default()
  end, { desc = "打开 NeoAI 默认界面", force = true })

  vim.api.nvim_create_user_command("NeoAIChat", function()
    require("NeoAI.ui").open_chat()
  end, { desc = "打开 NeoAI 聊天界面", force = true })

  vim.api.nvim_create_user_command("NeoAITree", function()
    require("NeoAI.ui").open_tree()
  end, { desc = "打开 NeoAI 会话树界面", force = true })

  vim.api.nvim_create_user_command("NeoAIClose", function()
    require("NeoAI.ui").close_all()
  end, { desc = "关闭所有 NeoAI 窗口", force = true })

  vim.api.nvim_create_user_command("NeoAIKeymaps", function()
    require("NeoAI.ui").show_keymaps()
  end, { desc = "显示 NeoAI 当前键位配置", force = true })

  vim.api.nvim_create_user_command("NeoAITest", function(opts)
    local ok, tests = pcall(require, "NeoAI.tests")
    if not ok then
      vim.notify("[NeoAI] 测试模块加载失败: " .. tostring(tests), vim.log.levels.ERROR)
      return
    end
    local args = opts.args or ""
    local names = {}
    for arg in args:gmatch("%S+") do
      table.insert(names, arg)
    end
    local results = tests.run_all(unpack(names))
    vim.notify(string.format("测试结果: %d 通过, %d 失败", results.passed, results.failed), vim.log.levels.INFO)
    if #results.errors > 0 then
      vim.notify("失败测试:\n  " .. table.concat(results.errors, "\n  "), vim.log.levels.WARN)
    end
  end, { nargs = "*", desc = "运行 NeoAI 测试", force = true })

  vim.api.nvim_create_user_command("NeoAIChatStatus", function()
    require("NeoAI.ui").chat_status()
  end, { desc = "显示 NeoAI 聊天窗口状态", force = true })
end

--- 注册全局快捷键（从 config_store 读取）
local function _register_global_keymaps()
  local keymaps = config_store.get("keymaps.global") or {}
  for action, conf in pairs(keymaps) do
    if conf and conf.key then
      local fn
      if action == "open_chat" then
        fn = function() M.open_chat() end
      elseif action == "open_tree" then
        fn = function() M.open_tree() end
      elseif action == "close_all" then
        fn = function() M.close_all() end
      elseif action == "toggle_ui" then
        fn = function()
          local ui = require("NeoAI.ui")
          if ui.has_windows() then ui.close_all() else ui.open_tree() end
        end
      end
      if fn then
        vim.keymap.set("n", conf.key, fn, { desc = conf.desc or ("NeoAI " .. action) })
      end
    end
  end
end

-- ========== 公开 API ==========

--- 设置插件配置
--- @param user_config table 用户配置
--- @return table 插件实例
function M.setup(user_config)
  if state.loaded then return M end
  state.loaded = true

  -- 纯函数：合并 + 校验，返回不可变配置
  config_store.load(user_config or {})

  -- 内核引导：事件常量表、日志、生命周期
  kernel.bootstrap()

  -- 注册命令 + 全局快捷键（仅此而已）
  _register_commands()
  _register_global_keymaps()

  return M
end

--- 打开默认界面（懒加载 ui）
function M.open_default()
  return require("NeoAI.ui").open_default()
end

--- 打开聊天界面
function M.open_chat()
  return require("NeoAI.ui").open_chat()
end

--- 打开会话树界面
function M.open_tree()
  return require("NeoAI.ui").open_tree()
end

--- 关闭所有窗口
function M.close_all()
  return require("NeoAI.ui").close_all()
end

--- 获取聊天服务（懒加载）
--- @return table chat_service
function M.get_chat_service()
  return require("NeoAI.services.chat_service")
end

--- 获取工具服务（懒加载）
--- @return table tool_service
function M.get_tool_service()
  return require("NeoAI.services.tool_service")
end

--- 获取模型服务（懒加载）
--- @return table model_service
function M.get_model_service()
  return require("NeoAI.services.model_service")
end

return M
