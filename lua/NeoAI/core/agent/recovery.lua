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
local services = require("NeoAI.kernel.services")

local M = {}

--- 请求前守卫 AI 可见上下文：其中出现映射表中已知的**原始密钥**时，说明沙箱的 token 化
--- 被绕过（沙箱上下文被突破）→ 终止整个 Agent。token（`NEOKEY_*`，即 KEY 环境变量操作）
--- 不算命中，只由执行器提级审批，不终止。
--- 沙箱服务不可用/密钥防护关闭时跳过（不改变行为）。
--- @param agent table
--- @param messages table wire 消息数组（即将发送给模型）
--- @return boolean ok
--- @return table|nil err
local function _guard_secret_context(agent, messages)
  local sandbox = services.use("services.sandbox")
  local secret = sandbox and sandbox.secret
  if not secret or not secret.context_leak then return true end
  local leaked = secret.context_leak(messages)
  if not leaked then return true end
  secret.trace("context_blocked", { tool = "request", agent_id = agent and agent.id })
  if agent then
    pcall(function() require("NeoAI.core.agent.runtime").abort(agent, "secret_exposure") end)
  end
  pcall(function()
    require("NeoAI.kernel.event_bus").emit(require("NeoAI.kernel.events").SANDBOX_SECRET_BLOCKED, {
      tool = "request", agent_id = agent and agent.id, scope = "ai_context",
    })
  end)
  pcall(vim.notify,
    "[NeoAI] AI 上下文中出现原始密钥（沙箱上下文被突破），已终止 Agent",
    vim.log.levels.ERROR)
  return false, { kind = "secret", message = "SANDBOX_SECRET_BLOCKED: AI 上下文包含原始密钥，已终止 Agent" }
end

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
    -- 请求前守卫：AI 可见上下文含原始密钥（token 化被绕过）→ 终止 Agent。
    local ok_guard, guard_err = _guard_secret_context(agent, messages)
    if not ok_guard then return async.reject(guard_err) end
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

--- 测试用：AI 上下文密钥守卫
M._guard_secret_context = _guard_secret_context

return M
