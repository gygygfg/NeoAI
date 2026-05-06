--- NeoAI 生成完成处理器
--- 职责：处理 AI 生成完成的收尾工作（usage 累积、消息构建、事件触发）
--- 从 ai_engine.lua 提取，减轻其负担

local logger = require("NeoAI.utils.logger")
local event_constants = require("NeoAI.core.events")

local M = {}

--- 累积 usage 信息
--- @param accumulated table 累积的 usage
--- @param current_usage table 当前轮次的 usage
--- @return table 更新后的累积 usage
function M.accumulate_usage(accumulated, current_usage)
  if not current_usage or not next(current_usage) then
    return accumulated or {}
  end
  local acc = vim.deepcopy(accumulated or {})
  local function add(key, src_keys)
    for _, sk in ipairs(src_keys) do
      local v = current_usage[sk]
      if v and type(v) == "number" then
        acc[key] = (acc[key] or 0) + v
        break
      end
    end
  end
  add("prompt_tokens", { "prompt_tokens", "promptTokens", "input_tokens", "inputTokens" })
  add("completion_tokens", { "completion_tokens", "completionTokens", "output_tokens", "outputTokens" })
  add("total_tokens", { "total_tokens", "totalTokens" })

  if current_usage.completion_tokens_details and type(current_usage.completion_tokens_details) == "table" then
    local rt = current_usage.completion_tokens_details.reasoning_tokens or 0
    if not acc.completion_tokens_details then
      acc.completion_tokens_details = {}
    end
    acc.completion_tokens_details.reasoning_tokens = (acc.completion_tokens_details.reasoning_tokens or 0) + rt
  end
  return acc
end

--- 构建 assistant 消息
--- @param content string 响应内容
--- @param reasoning_text string|nil 思考内容
--- @param window_id number|nil 窗口ID
--- @param tool_calls table|nil 工具调用列表
--- @return table
function M.build_assistant_message(content, reasoning_text, window_id, tool_calls)
  local msg = {
    role = "assistant",
    content = content or "",
    timestamp = os.time(),
  }
  if window_id then msg.window_id = window_id end
  if reasoning_text and reasoning_text ~= "" then
    msg.reasoning_content = reasoning_text
  end
  if tool_calls and #tool_calls > 0 then
    msg.tool_calls = tool_calls
  end
  return msg
end

--- 触发生成完成事件
--- @param params table { generation_id, response, reasoning_text, usage, session_id, window_id, duration }
function M.fire_generation_completed(params)
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.GENERATION_COMPLETED,
    data = {
      generation_id = params.generation_id,
      response = params.response or "",
      reasoning_text = params.reasoning_text or "",
      usage = params.usage or {},
      session_id = params.session_id,
      window_id = params.window_id,
      duration = params.duration or 0,
    },
  })
end

--- 触发生成错误事件
--- @param params table { generation_id, error_msg, session_id, window_id }
function M.fire_generation_error(params)
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.GENERATION_ERROR,
    data = {
      generation_id = params.generation_id,
      error_msg = params.error_msg,
      session_id = params.session_id,
      window_id = params.window_id,
    },
  })
end

--- 触发生成取消事件
--- @param params table { generation_id, session_id, window_id, usage }
function M.fire_generation_cancelled(params)
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.GENERATION_CANCELLED,
    data = {
      generation_id = params.generation_id,
      session_id = params.session_id,
      window_id = params.window_id,
      usage = params.usage or {},
    },
  })
end

--- 触发重试事件
--- @param params table { generation_id, retry_count, max_retries, reason, session_id, window_id }
function M.fire_generation_retrying(params)
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.GENERATION_RETRYING,
    data = {
      generation_id = params.generation_id,
      retry_count = params.retry_count,
      max_retries = params.max_retries,
      reason = params.reason,
      session_id = params.session_id,
      window_id = params.window_id,
    },
  })
end

--- 清理工具模块的延迟清理
function M.flush_lsp_cleanups()
  local ok, lsp = pcall(require, "NeoAI.tools.builtin.neovim_lsp")
  if ok and lsp and lsp.flush_deferred_cleanups then
    lsp.flush_deferred_cleanups()
  end
end

--- 保存历史（pcall 保护）
function M.save_history()
  local hm_ok, hm = pcall(require, "NeoAI.core.history.manager")
  if hm_ok and hm and hm._save then
    hm._save()
  end
end

return M
