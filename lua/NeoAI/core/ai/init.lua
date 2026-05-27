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

-- 延迟加载：所有子模块在首次访问或 initialize() 时按需加载
-- 避免 require("NeoAI.core.ai") 时立即加载所有子模块破坏外层懒加载
local _loaded = {}

local function _lazy_get(key, mod_path)
  if not _loaded[key] then
    _loaded[key] = require(mod_path)
  end
  return _loaded[key]
end

function M.__index(m, key)
  local mod_map = {
    engine = "NeoAI.core.ai.engine",
    http_utils = "NeoAI.utils.http_utils",
    request_handler = "NeoAI.core.ai.request_handler",
    tool_cycle = "NeoAI.core.ai.tool_cycle",
    sub_agent_engine = "NeoAI.core.ai.sub_agent_engine",
    chat_service = "NeoAI.core.ai.chat_service",
    thread_pool = "NeoAI.core.ai.thread_pool",
    async_orchestrator = "NeoAI.core.ai.async_orchestrator",
  }
  local path = mod_map[key]
  if path then
    return _lazy_get(key, path)
  end
  return nil
end

setmetatable(M, M)

--- 初始化所有 AI 子模块
--- @param options table 配置选项
function M.initialize(options)
  _lazy_get("chat_service", "NeoAI.core.ai.chat_service").initialize(options)
  -- 初始化线程池和异步编排器（pre-warm）
  _lazy_get("thread_pool", "NeoAI.core.ai.thread_pool").initialize(options or {})
  _lazy_get("async_orchestrator", "NeoAI.core.ai.async_orchestrator").initialize(options or {})
end

--- 关闭所有 AI 子模块
function M.shutdown()
  if _loaded.chat_service then pcall(_loaded.chat_service.shutdown) end
  if _loaded.async_orchestrator then pcall(_loaded.async_orchestrator.shutdown) end
  if _loaded.thread_pool then pcall(_loaded.thread_pool.cancel_all) end
end

return M
