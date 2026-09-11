--- 请求恢复
--- @module NeoAI.core.agent.recovery
--- 上下文溢出恢复：请求返回 context window exceeded 时自动压缩历史后重发。
--- 对齐 deepseek-harness compaction 的 request-error 触发路径：
--- 溢出不是直接报错结束，而是先压缩（复用前缀缓存）再重试。
---
--- 本模块被回合首轮（runtime._run_generation）与工具循环每一轮（tool_loop._send_round）
--- 共同复用。压缩固定以 allow_busy=true 调用：请求已因溢出失败，此刻 agent 处于
--- generating/tool_running（仍非 idle），但无并发写入，可安全折叠历史后重试。

local async = require("NeoAI.utils.async")

local M = {}

--- 带溢出恢复的流式发送
--- 每轮请求最多触发一次压缩恢复；成功后重置标志，允许后续轮次再次恢复。
--- @param agent table
--- @param opts table { agent_config, model, signal } 透传给 request.send_stream
--- @param on_chunk function|nil
--- @return Deferred resolve(request.send_stream 的结果)
function M.send_stream(agent, opts, on_chunk)
  local request = require("NeoAI.core.agent.request")
  local context_builder = require("NeoAI.core.session.context_builder")
  local prefix = require("NeoAI.core.agent.prefix")

  local function attempt()
    -- extra_user：仅注入请求 wire（如截断续写提示），不写入 agent 消息队列。
    local messages = context_builder.build_from_agent(agent, { extra_user = opts.extra_user })
    local tool_defs = nil
    if agent.tools then
      tool_defs = require("NeoAI.core.agent.tool_loop")._tool_definitions(agent)
    end
    prefix.verify_cache_identity(agent, messages, tool_defs)

    return request.send_stream(messages, {
      agent_config = opts.agent_config or agent.config,
      model = opts.model or agent.model,
      tools = tool_defs,
      signal = opts.signal or agent.signal,
    }, on_chunk):then_(function(response)
      -- 成功：重置恢复标志，允许后续溢出再次恢复
      agent._overflow_recovered = false
      return response
    end, function(err)
      if not agent._overflow_recovered and request.is_context_overflow(err) then
        agent._overflow_recovered = true
        local compactor = require("NeoAI.core.session.compactor")
        -- allow_busy=true：允许在工具循环中途（generating/tool_running）压缩，
        -- 否则长循环耗尽上下文时压缩会被 idle 守卫拒绝、溢出错误直接抛出。
        return compactor.force_compact(agent, { allow_busy = true }):then_(function(compacted)
          if compacted then
            return attempt()
          end
          -- 无可折叠内容：原样抛回溢出错误
          return async.reject(err)
        end, function()
          return async.reject(err)
        end)
      end
      return async.reject(err)
    end)
  end

  return attempt()
end

return M