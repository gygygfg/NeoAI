--- NeoAI AI 模块入口
--- 统一导出 AI 模块的所有子模块

local M = {}

M.ai_engine = require("NeoAI.core.ai.ai_engine")
M.http_client = require("NeoAI.core.ai.http_client")
M.request_adapter = require("NeoAI.core.ai.request_adapter")
M.tool_orchestrator = require("NeoAI.core.ai.tool_orchestrator")
M.chat_service = require("NeoAI.core.ai.chat_service")

--- 初始化所有 AI 子模块
--- @param options table 配置选项
function M.initialize(options)
  M.chat_service.initialize(options)
end

--- 关闭所有 AI 子模块
function M.shutdown()
  M.chat_service.shutdown()
end

return M
