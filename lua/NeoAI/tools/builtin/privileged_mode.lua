--- 高权限模式
--- @module 'NeoAI.tools.builtin.privileged_mode'
--- 高权限模式作为 per-agent 状态（`agent.privileged_mode`），与计划模式互斥。激活时：
--- 1. 网络：沙箱策略强制 `access="allow"`，不再弹窗/不因 deny/offline 拒绝，但仍经
---    host_proxy 记录目标（"不拦截，仅记录"）；
--- 2. 容器：旁路容器门面（不改写 docker→podman、不生成入口桩、不伪装 daemon 错误），
---    docker 可直连宿主 daemon，podman 直接执行；
--- 3. 文件系统仍沿用沙箱既有语义（overlay 暂存/待审），但容器内产生的宿主变更不受此约束。
---
--- 安全约束：
---   * 默认 opt-in（`tools.privileged_mode.enabled=false`）；
---   * 默认仅允许在异步审批（`tools.approval.mode="async"`）下进入；
---   * **不向 AI 暴露切换模式工具**，只能由用户按 `m` / `:NeoAI Privileged` 切换。

local config_store = require("NeoAI.kernel.config_store")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")

local M = {}

-- ========== 私有常量 ==========

--- 高权限模式策略段（运行时上下文快照，注入历史；不改系统提示，避免前缀缓存失效）
local PRIVILEGED_POLICY_TEXT = table.concat({
  "## 高权限模式（PRIVILEGED MODE）",
  "当前处于高权限模式，以下两项限制被显式放宽：",
  "1. 网络访问不拦截：外部与宿主本机目标均直接放行，不再弹出同意窗口；系统仍会记录访问目标（仅记录）。",
  "2. 容器运行时可直接使用：docker / podman / docker-compose 等按原文执行，docker 可连接宿主 daemon。",
  "注意：",
  "- 文件的创建/修改/删除仍按沙箱既有规则进入暂存与待审；但容器内产生的变更由宿主机直接执行，不在候选/审批范围内。",
  "- 该模式由用户显式开启。请避免执行不可逆或高风险操作；如无必要，优先使用只读命令与现有工具。",
}, "\n")

-- ========== 私有函数 ==========

--- 读取配置
--- @return table
local function _cfg()
  return config_store.get("tools.privileged_mode") or {}
end

--- 通知用户（测试/无 UI 环境下静默失败）
--- @param msg string
--- @param level number
local function _notify(msg, level)
  pcall(vim.notify, msg, level, { title = "NeoAI" })
end

--- 是否可以进入高权限模式
--- @return boolean available
--- @return string|nil reason 不可用原因码
function M.available()
  local cfg = _cfg()
  if cfg.enabled ~= true then return false, "PRIVILEGED_MODE_DISABLED" end
  if cfg.require_async_approval ~= false then
    local approval_mode = config_store.get("tools.approval.mode") or "async"
    if approval_mode ~= "async" then
      return false, "PRIVILEGED_MODE_REQUIRES_ASYNC"
    end
  end
  return true
end

-- ========== 公开 API ==========

--- 是否处于高权限模式
--- @param agent table
--- @return boolean
function M.is_active(agent)
  return agent and agent.privileged_mode == true
end

--- 高权限模式策略段文本（供运行时上下文快照复用）
--- @return string
function M.policy_text()
  return PRIVILEGED_POLICY_TEXT
end

--- 进入高权限模式（同时退出计划模式）
--- @param agent table
--- @return boolean ok
--- @return string|nil reason
function M.enter(agent)
  if not agent then return false, "NO_AGENT" end
  local ok, reason = M.available()
  if not ok then return false, reason end
  -- 互斥：先退出计划模式（会触发 PLAN_MODE_CHANGED）。
  local plan_mode = require("NeoAI.tools.builtin.plan_mode")
  if plan_mode.is_active(agent) then plan_mode.exit(agent) end
  agent.privileged_mode = true
  local sandbox_privileged = require("NeoAI.sandbox.privileged")
  sandbox_privileged.mark(agent.id, true)
  sandbox_privileged.set_current(agent.id)
  event_bus.emit(events.PRIVILEGED_MODE_CHANGED, { agent_id = agent.id, active = true })
  _notify("[NeoAI] 高权限模式已开启：网络不拦截（仅记录），可直接使用 docker/podman。",
    vim.log.levels.WARN)
  return true
end

--- 退出高权限模式（转入 CHAT 模式）
--- @param agent table
--- @return boolean
function M.exit(agent)
  if not agent then return false end
  local was_active = agent.privileged_mode == true
  agent.privileged_mode = false
  pcall(function()
    require("NeoAI.sandbox.privileged").mark(agent.id, false)
  end)
  if was_active then
    event_bus.emit(events.PRIVILEGED_MODE_CHANGED, { agent_id = agent.id, active = false })
  end
  return true
end

--- 切换高权限模式
--- @param agent table
--- @return boolean ok
--- @return string|nil reason
function M.toggle(agent)
  if M.is_active(agent) then
    M.exit(agent)
    return false
  end
  return M.enter(agent)
end

--- 恢复高权限模式状态（加载会话时；计划模式优先）
--- @param agent table
--- @param state table|nil { active? }
function M.restore(agent, state)
  if not agent or type(state) ~= "table" or not state.active then return end
  local plan_mode = require("NeoAI.tools.builtin.plan_mode")
  if plan_mode.is_active(agent) then return end
  local ok = M.available()
  if not ok then return end
  agent.privileged_mode = true
  local sandbox_privileged = require("NeoAI.sandbox.privileged")
  sandbox_privileged.mark(agent.id, true)
  sandbox_privileged.set_current(agent.id)
  event_bus.emit(events.PRIVILEGED_MODE_CHANGED, { agent_id = agent.id, active = true })
end

--- 清理 agent 级状态（销毁时）
--- @param agent table
function M.cleanup(agent)
  if not agent then return end
  agent.privileged_mode = false
  pcall(function()
    require("NeoAI.sandbox.privileged").mark(agent.id, false)
  end)
end

--- 重置（测试用）
function M.reset()
  -- 无模块级业务状态；沙箱注册表由 sandbox.privileged.reset() 清理。
end

return M
