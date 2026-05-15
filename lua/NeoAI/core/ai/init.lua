--- NeoAI AI 模块入口
--- 统一导出 AI 模块的所有子模块
---
--- 模块分类：
---   engine          - AI 引擎核心：生成流程编排、事件调度、流式/非流式请求、错误处理
---   request_handler - 请求处理器：请求构建（Builder）、API 适配（Adapter）、响应重试（Retry）
---   tool_cycle      - 工具循环引擎：管理主 agent 和子 agent 的工具调用循环执行
---   sub_agent_engine- 子 agent 管理器：子 agent 生命周期、工具调用边界审核、系统提示词构建
---   chat_service    - 聊天服务：会话管理、消息历史、AI 生成请求调度、自动命名会话
---
--- 职责边界：
---   engine          - 只做生成编排，不管理工具、不处理会话命名
---   request_handler - 统一管理请求构建、API 适配、异常检测与重试
---   tool_cycle      - 只做工具循环，模糊匹配和单次工具请求委托给 tool_executor
---   chat_service    - 会话管理入口，自动命名从 engine 移入

local M = {}

M.engine = require("NeoAI.core.ai.engine")
M.http_utils = require("NeoAI.utils.http_utils")
M.request_handler = require("NeoAI.core.ai.request_handler")
M.tool_cycle = require("NeoAI.core.ai.tool_cycle")
M.sub_agent_engine = require("NeoAI.core.ai.sub_agent_engine")
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
