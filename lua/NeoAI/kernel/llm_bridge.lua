--- LLM 调用桥（sandbox ↔ core 解耦）
--- @module NeoAI.kernel.llm_bridge
--- 沙箱侧（如审批 AI 审计 ai_audit、L3 警示 l3_warning）需要调用一次模型补全，
--- 而底层发送能力属 core（`core.agent.request`）。为避免 sandbox 直接依赖 core，由组合根
--- （plugins/catalog）在启动沙箱服务时把发送函数注入本桥；sandbox 经本桥调用，双方仅依赖 kernel。
---
--- 未注入（core 不可用/沙箱被禁用）时 `send()` 返回 nil，调用方按「模型不可用」降级。

local M = {}

local caller = nil

--- 注入发送实现（由组合根设置）。
--- @param fn function(messages: table, opts: table) -> Deferred|nil
function M.set_caller(fn)
  caller = fn
end

--- 是否已注入发送实现。
--- @return boolean
function M.available()
  return caller ~= nil
end

--- 发送一次补全请求；未注入返回 nil。
--- @param messages table
--- @param opts table
--- @return Deferred|nil
function M.send(messages, opts)
  if not caller then return nil end
  return caller(messages, opts)
end

--- 复位（插件卸载/测试用）。
function M.reset()
  caller = nil
end

return M
