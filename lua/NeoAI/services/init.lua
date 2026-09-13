--- NeoAI 服务层入口
--- @module NeoAI.services
--- 兼容旧用法：M.chat_service / M.tool_service / M.model_service 等经
--- kernel.services.use 动态解析当前实现；服务被禁用/替换时不会回退默认模块。

local services = require("NeoAI.kernel.services")

local M = setmetatable({}, {
  __index = function(_, key)
    return services.use("services." .. key)
  end,
})

return M
