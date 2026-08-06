--- NeoAI 服务层入口
--- @module NeoAI.services
--- 连接 core 与 ui/tools。向上提供简洁 API。

local M = {}

M.chat_service = require("NeoAI.services.chat_service")
M.tool_service = require("NeoAI.services.tool_service")
M.model_service = require("NeoAI.services.model_service")

return M
