--- NeoAI 内核层入口
--- @module NeoAI.kernel
--- 依赖：utils（事件总线/日志/配置/生命周期）。
--- 任何业务模块（core/services/ui/tools）都只依赖本层 + utils。

local M = {}

local state = { bootstrapped = false }

--- 内核引导
--- @return table kernel
function M.bootstrap()
  if state.bootstrapped then return M end
  state.bootstrapped = true
  require("NeoAI.kernel.lifecycle").bootstrap()
  return M
end

--- 内核模块引用
M.events = require("NeoAI.kernel.events")
M.event_bus = require("NeoAI.kernel.event_bus")
M.logger = require("NeoAI.kernel.logger")
M.config_store = require("NeoAI.kernel.config_store")
M.lifecycle = require("NeoAI.kernel.lifecycle")
M.services = require("NeoAI.kernel.services")
M.plugins = require("NeoAI.kernel.plugins")

return M
