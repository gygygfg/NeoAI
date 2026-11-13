--- NeoAI UI 层入口
--- @module 'NeoAI.ui'
--- 编排窗口/组件/键位。对外暴露 open/close 等命令入口。

local window_manager = require("NeoAI.ui.window.manager")
local chat_view = require("NeoAI.ui.window.chat_view")
local tree_view = require("NeoAI.ui.window.tree_view")
local config_store = require("NeoAI.kernel.config_store")
local logger = require("NeoAI.kernel.logger")

local M = {}

-- ========== 私有状态 ==========

local state = {
  initialized = false,
}

--- 带日志的惰性初始化：失败时记录原因（避免「审批静默无弹窗」类问题难以定位）。
--- @param name string 组件名
--- @param fn function 初始化函数
local function _try_init(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    logger.warn("[ui] 组件初始化失败 %s: %s", name, tostring(err))
  end
  return ok
end

-- ========== 公开 API ==========

--- 初始化 UI 层（幂等）
--- @return table ui
function M.init()
  if state.initialized then return M end
  state.initialized = true
  -- 隔离 LSP/Copilot：禁止其挂载到 NeoAI 界面 buffer（纯 UI 文本，挂载会空耗 CPU）
  require("NeoAI.ui.lsp_guard").install()
  -- 焦点信号：跟踪「用户是否在看 NeoAI 界面」，供 pty/ask_user 延迟弹窗与审批窗刷新。
  _try_init("focus", function() require("NeoAI.ui.focus").install() end)
  -- 注册审批 UI
  local approval_ui = require("NeoAI.ui.components.tool_approval")
  approval_ui.init()
  -- 注册向用户提问 UI
  require("NeoAI.ui.components.ask_user").init()
  -- 注册密钥告警 UI（真实密钥/非白名单发送时阻塞确认）
  _try_init("secret_alert", function() require("NeoAI.ui.components.secret_alert").init() end)
  -- 注册网络访问同意 UI（沙箱外部命令访问沙箱外目标时阻塞确认）
  _try_init("net_consent", function() require("NeoAI.ui.components.net_consent").init() end)
  -- 注册危险设备访问同意 UI（命令访问 /dev/kvm、/dev/net/tun 等逃逸面设备时阻塞确认）
  _try_init("device_consent", function() require("NeoAI.ui.components.device_consent").init() end)
  -- 注册沙箱策略确认 UI（代理规避等需用户批准的操作，与其它沙箱弹窗一致）
  _try_init("policy_consent", function() require("NeoAI.ui.components.policy_consent").init() end)
  -- 注册审批分流中心（多级页面审批悬浮窗：待修改/工具行为/资源访问/网络请求/越界异常）
  _try_init("sandbox_review", function() require("NeoAI.ui.components.sandbox_review").setup() end)
  -- 启动子 Agent 监控监听
  local sub_agent_dock = require("NeoAI.ui.components.sub_agent_dock")
  sub_agent_dock.init()
  return M
end

--- 打开默认界面（按配置 default_view）
--- @return table
function M.open_default()
  M.init()
  local default_view = config_store.get("ui.default_view") or "chat"
  if default_view == "tree" then
    return M.open_tree()
  end
  return M.open_chat()
end

--- 打开聊天界面
--- @param opts table|nil { session_id?, round?, new_session?, new_window? } 透传给 chat_view.open
---   new_window=true 时在**新标签页**开一个独立聊天实例（唯一 buffer 名）。
--- @return table
function M.open_chat(opts)
  M.init()
  -- 树窗口保持打开，不自动关闭（可同时浏览会话）
  return chat_view.open(opts)
end

--- 打开会话树界面
--- @return table
function M.open_tree()
  M.init()
  -- 聊天窗口保持打开，不自动关闭
  return tree_view.open()
end

--- 关闭所有窗口（含全部聊天实例）
function M.close_all()
  chat_view.close_all()
  tree_view.close()
  window_manager.close_all()
end

--- 是否有窗口
--- @return boolean
function M.has_windows()
  return window_manager.has_windows()
end

--- 显示键位配置
function M.show_keymaps()
  local keymap = require("NeoAI.ui.keymap")
  keymap.show_keymaps()
end

--- 聊天窗口状态
function M.chat_status()
  chat_view.show_status()
end

--- 打开沙箱待审审批界面（供 :NeoAI SandboxReview 命令经 services.ui 调用）
function M.open_sandbox_review()
  M.init()
  require("NeoAI.ui.components.sandbox_review").open()
end

--- 获取聊天视图
--- @return table
function M.get_chat_view()
  return chat_view
end

--- 获取树视图
--- @return table
function M.get_tree_view()
  return tree_view
end

--- 切换默认界面
--- @param mode string "tree"|"chat"
function M.switch_view(mode)
  config_store.set("ui.default_view", mode)
  M.close_all()
  if mode == "tree" then
    M.open_tree()
  else
    M.open_chat()
  end
end

-- ========== 窗口模式（tab / float / split） ==========

--- 支持的窗口模式（对应 `ui.window_mode`）
local WINDOW_MODES = { tab = true, float = true, split = true }

--- 当前生效的窗口模式：有打开的聊天窗口时返回该窗口的生效模式（可能来自运行期
--- `:NeoAI WindowMode` 的实例级覆盖），否则返回配置默认值 `ui.window_mode`。
--- @return string
function M.window_mode()
  if chat_view.has_window() then
    local m = chat_view.get_window_mode()
    if m then return m end
  end
  return config_store.get("ui.window_mode") or "tab"
end

--- 切换**当前聊天窗口**的窗口模式并重建该窗口（不写 `ui.window_mode` 配置）。
--- 语义：
---   * 只影响当前聊天实例（当前 buffer）；其它聊天实例与会话树保持原样，不重建；
---   * 不持久化——新开的聊天窗口（`<leader>ac` / `:NeoAI Chat` / 子 Agent 窗口）与重启后
---     仍按 `ui.window_mode` 配置的默认模式；
---   * Agent 生成中 / 工具执行中**也可切换**：重建窗口时保留 Agent（只解绑窗口），
---     当前回合继续跑，切换只重绘 UI；
---   * 没有打开的聊天窗口时无窗口可切，仅提示到配置里修改默认模式。
--- @param mode string|nil "tab"|"float"|"split"；nil/空 = 只查询当前模式
--- @return string 当前（或切换后）生效的模式
--- @return boolean 是否已重建窗口
function M.set_window_mode(mode)
  local cur = M.window_mode()
  if mode == nil or mode == "" then return cur, false end
  local m = tostring(mode):lower()
  if not WINDOW_MODES[m] then
    vim.notify("[NeoAI] 未知窗口模式: " .. tostring(mode) .. "（可选: tab / float / split）", vim.log.levels.WARN)
    return cur, false
  end
  if not chat_view.has_window() then
    vim.notify(("[NeoAI] 当前没有打开的聊天窗口，默认窗口模式请在配置 ui.window_mode 中修改（当前: %s）")
      :format(cur), vim.log.levels.WARN)
    return cur, false
  end
  local changed, rebuilt = chat_view.set_window_mode(m)
  if not changed then
    vim.notify(("[NeoAI] 当前窗口已是 %s 模式"):format(m), vim.log.levels.INFO)
    return m, false
  end
  if rebuilt then
    vim.notify(("[NeoAI] 当前窗口已切换为 %s 模式（仅本次窗口；新开窗口仍按配置 ui.window_mode）")
      :format(m), vim.log.levels.INFO)
  else
    vim.notify(("[NeoAI] 窗口模式已设为 %s，但窗口重建失败（详见上方错误）"):format(m), vim.log.levels.WARN)
  end
  return m, rebuilt
end

--- 重置（测试用/插件卸载）：关闭窗口并释放 UI 注入与事件监听
function M.reset()
  M.close_all()
  pcall(function() require("NeoAI.ui.geometry").reset() end)
  pcall(function() require("NeoAI.ui.lsp_guard").uninstall() end)
  pcall(function() require("NeoAI.ui.focus").uninstall() end)
  pcall(function() require("NeoAI.ui.components.tool_approval").reset() end)
  pcall(function() require("NeoAI.ui.components.ask_user").reset() end)
  pcall(function() require("NeoAI.ui.components.secret_alert").reset() end)
  pcall(function() require("NeoAI.ui.components.net_consent").reset() end)
  pcall(function() require("NeoAI.ui.components.device_consent").reset() end)
  pcall(function() require("NeoAI.ui.components.policy_consent").reset() end)
  pcall(function() require("NeoAI.ui.components.sub_agent_dock").reset() end)
  pcall(function() require("NeoAI.ui.components.sub_agent_list").reset() end)
  pcall(function() require("NeoAI.ui.components.sandbox_review").reset() end)
  pcall(function() require("NeoAI.ui.components.terminal_window").reset() end)
  state.initialized = false
end

return M
