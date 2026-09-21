--- NeoAI 主入口
--- @module NeoAI
--- 极薄入口：setup() 仅做 配置加载 → 内核引导 → 登记并启动插件。
--- 业务模块一律懒加载，首次使用时才 require；对外通过 kernel.services.use 获取服务。

local kernel = require("NeoAI.kernel")
local config_store = require("NeoAI.kernel.config_store")
local services = require("NeoAI.kernel.services")

-- ========== 私有状态 ==========

local state = {
  loaded = false,
}

local M = {}

-- ========== 公开 API ==========

--- 设置插件配置
--- @param user_config table 用户配置
--- @return table 插件实例
function M.setup(user_config)
  if state.loaded then return M end
  state.loaded = true

  -- 纯函数：合并 + 校验，返回不可变配置
  config_store.load(user_config or {})

  -- Neovim >= 0.13 起由 autoread 自动把外部改动的文件重载进 buffer，
  -- 替代内置工具写盘后的手动缓冲区同步；更早版本走 sync_buffer_from_disk。
  if vim.fn.has("nvim-0.13") == 1 then
    vim.opt.autoread = true
  end

  -- 内核引导：事件常量表、日志、生命周期
  kernel.bootstrap()

  -- 登记并启动内置插件（服务提供方 + 副作用 + 每个内置工具）
  local catalog = require("NeoAI.plugins.catalog")
  local res = catalog.setup()
  if not res.ok then
    require("NeoAI.kernel.logger").error(
      "[NeoAI] 插件启动失败: %s: %s", tostring(res.failed), tostring(res.error))
  end

  -- 关闭时统一卸载插件（释放服务/工具/命令/事件订阅/MCP/UI 注入）
  kernel.lifecycle.on_shutdown(function()
    require("NeoAI.kernel.plugins").stop_all()
  end)

  -- 关闭前先把活跃 Agent 的进行中进度落盘。清理函数逆序执行：此处晚于 stop_all 注册，
  -- 故先于插件卸载运行，保证在 Agent 被销毁（messages 清空）前完成保存。
  kernel.lifecycle.on_shutdown(function()
    local chat = services.use("services.chat_service")
    if chat and chat.persist_active_sessions then
      pcall(chat.persist_active_sessions)
    end
  end)

  return M
end

--- 打开默认界面（懒加载 ui 服务）
function M.open_default()
  local ui = services.use("services.ui")
  if ui then return ui.open_default() end
end

--- 打开聊天界面
function M.open_chat()
  local ui = services.use("services.ui")
  if ui then return ui.open_chat() end
end

--- 打开会话树界面
function M.open_tree()
  local ui = services.use("services.ui")
  if ui then return ui.open_tree() end
end

--- 关闭所有窗口
function M.close_all()
  local ui = services.use("services.ui")
  if ui then return ui.close_all() end
end

--- 获取聊天服务
--- @return table|nil chat_service
function M.get_chat_service()
  return services.use("services.chat_service")
end

--- 获取工具服务
--- @return table|nil tool_service
function M.get_tool_service()
  return services.use("services.tool_service")
end

--- 获取模型服务
--- @return table|nil model_service
function M.get_model_service()
  return services.use("services.model_service")
end

--- 获取状态栏服务，用于 nvim-lualine 集成
--- @return table|nil status_service
function M.get_status_service()
  return services.use("services.status")
end

--- 获取状态栏信息（方便其它插件 / 状态栏消费）
--- @return table|nil 当前 Agent 的用量/缓存/容量信息
function M.get_statusline_info()
  local status = services.use("services.status")
  return status and status.get_info() or nil
end

--- 生成 lualine 状态栏文本
--- @return string
function M.get_statusline()
  local status = services.use("services.status")
  return status and status.component() or ""
end

--- 手动把 NeoAI lualine 扩展注入 lualine（幂等；一般无需手动调用）
--- @return boolean
function M.enable_statusline()
  local status = services.use("services.status")
  return status and status.ensure_lualine_extension() or false
end

return M
