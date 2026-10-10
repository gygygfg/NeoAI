--- 核心能力桥（tools ↔ core 解耦）
--- @module NeoAI.kernel.core_bridge
--- tools/ 层（内置工具、执行器）需要少量核心能力（子 Agent 运行时、提示段注册、附件存储），
--- 但 tools 不得直接依赖 core。由组合根（plugins/catalog）在启动 Agent 服务时注入所需实现；
--- tools 经本桥调用，双方仅依赖 kernel。
---
--- 未注入（测试/未启动）时各 getter 返回 nil，调用方按「能力不可用」降级。
--- 提示段注册（prefix）与附件（attachment）以子模块形式透出，调用方用法与直接 require 一致。

local M = {}

local impl = {}

--- 注入核心能力实现（由组合根设置；传 nil 清除）。
--- @param t table|nil {
---   agent_spawn?: function(parent, opts), agent_get?: function(id),
---   agent_abort?: function(agent, reason), prefix?: table, attachment?: table,
--- }
function M.set(t)
  impl = t or {}
end

--- 派生一个子 Agent（运行时可 spawn 时）。
--- @param parent table
--- @param opts table
--- @return table|nil
function M.agent_spawn(parent, opts)
  if impl.agent_spawn then return impl.agent_spawn(parent, opts) end
  return nil
end

--- 按 id 取 Agent。
--- @param id string
--- @return table|nil
function M.agent_get(id)
  if impl.agent_get then return impl.agent_get(id) end
  return nil
end

--- 驱动一个 Agent 运行一轮（返回 Deferred）。
--- @param agent table
--- @param content string
--- @return any
function M.agent_run(agent, content)
  if impl.agent_run then return impl.agent_run(agent, content) end
  return nil
end

--- 中止一个 Agent（幂等）。
--- @param agent table
--- @param reason string|nil
function M.agent_abort(agent, reason)
  if impl.agent_abort then pcall(impl.agent_abort, agent, reason) end
end

--- 提示段注册模块（core.agent.prefix；可用则返回，否则 nil）。
--- @return table|nil
function M.prefix()
  return impl.prefix
end

--- 附件存储模块（core.attachment.attachment；可用则返回，否则 nil）。
--- @return table|nil
function M.attachment()
  return impl.attachment
end

--- 复位（插件卸载/测试用）。
function M.reset()
  impl = {}
end

return M
