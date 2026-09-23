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

--- 定位命中真实密钥的消息，返回可读来源描述（供告警弹窗标明「哪个命令/消息获取到」）。
--- @param messages table wire 消息数组
--- @param secret string 命中的真实密钥
--- @return string|nil
local function _find_leak_source(messages, secret)
  if type(messages) ~= "table" or type(secret) ~= "string" or secret == "" then return nil end
  local function contains(v)
    if type(v) == "string" then return v:find(secret, 1, true) ~= nil end
    if type(v) == "table" then
      for k, x in pairs(v) do
        if contains(x) then return true end
        if type(k) == "string" and k:find(secret, 1, true) then return true end
      end
    end
    return false
  end
  for i, m in ipairs(messages) do
    if contains(m) then
      local role = type(m) == "table" and m.role or "?"
      local tool = type(m) == "table" and (m.tool_name or m.name) or nil
      local desc = "AI 上下文第 " .. i .. " 条消息（" .. tostring(role) .. "）"
      if tool then desc = desc .. "，工具 " .. tostring(tool) end
      return desc
    end
  end
  return nil
end

--- 请求前守卫 AI 可见上下文：其中出现映射表中已知的**原始密钥**时，说明沙箱的假密钥遮蔽
--- 被绕过（沙箱上下文被突破）→ 弹窗请用户确认：确认后继续（可选替换为假密钥），否则停止 Agent。
--- 假密钥（已知遮蔽值）不算命中；**来自环境变量的密钥值也不算命中**。
--- 无 UI（headless）时失败关闭（停止 Agent）。
--- @param agent table
--- @param messages table wire 消息数组（即将发送给模型）
--- @return boolean|Deferred true=安全；false,err=停止；Deferred=待用户确认
local function _guard_secret_context(agent, messages)
  local sandbox = services.use("services.sandbox")
  local secret = sandbox and sandbox.secret
  if not secret or not secret.context_leak then return true end
  -- 增量：仅扫描**新增上下文/工具调用**（append-only 视图）；压缩替换历史时回退全量。
  local leaked
  if secret.context_leak_from and agent then
    local cursor = tonumber(agent._secret_guard_cursor) or 0
    local replaced = (agent.compaction and tonumber(agent.compaction.replaced)) or 0
    local last_replaced = tonumber(agent._secret_guard_replaced) or 0
    local append_only = cursor > 0 and #messages >= cursor and replaced == last_replaced
    if append_only then
      leaked = secret.context_leak_from(messages, cursor + 1)
    else
      leaked = secret.context_leak(messages)
    end
    agent._secret_guard_cursor = #messages
    agent._secret_guard_replaced = replaced
  else
    leaked = secret.context_leak(messages)
  end
  if not leaked then return true end
  secret.trace("context_blocked", { tool = "request", agent_id = agent and agent.id })
  local err = { kind = "secret", message = "SANDBOX_SECRET_BLOCKED: AI 上下文包含原始密钥，已终止 Agent" }
  local function stop()
    if agent then
      pcall(function() require("NeoAI.core.agent.runtime").abort(agent, "secret_exposure") end)
    end
    pcall(function()
      require("NeoAI.kernel.event_bus").emit(require("NeoAI.kernel.events").SANDBOX_SECRET_BLOCKED, {
        tool = "request", agent_id = agent and agent.id, scope = "ai_context",
      })
    end)
    pcall(vim.notify,
      "[NeoAI] AI 上下文中出现原始密钥（沙箱上下文被突破），已停止 Agent",
      vim.log.levels.ERROR)
    return false, err
  end
  -- 弹窗展示信息：来源消息 + 命中的真实密钥 + 将替换使用的假密钥。
  local source = _find_leak_source(messages, leaked)
  local fake = secret.fake_for and secret.fake_for(leaked) or nil
  local alert = require("NeoAI.sandbox.secret_alert")
  if not alert.available() then return stop() end
  return alert.request({
    kind = "context", agent = agent, command = source,
    secret = leaked, secret_preview = tostring(leaked):sub(1, 6) .. "…", fake = fake,
  }):then_(function(decision)
    if decision == "stop" then return stop() end
    if decision == "fake" and fake then
      -- 替换为假密钥并继续：脱去 wire 消息与历史消息中的真实密钥，避免后续轮次再次泄漏。
      pcall(function() secret.replace_value(messages, leaked, fake) end)
      if agent and type(agent.messages) == "table" then
        pcall(function() secret.replace_value(agent.messages, leaked, fake) end)
      end
      pcall(function()
        require("NeoAI.sandbox.secret_flow").record("context", { fake = fake, command = source })
      end)
    end
    pcall(function()
      require("NeoAI.kernel.event_bus").emit(require("NeoAI.kernel.events").SANDBOX_SECRET_ALERT, {
        tool = "request", agent_id = agent and agent.id, scope = "ai_context", decision = decision,
      })
    end)
    return true
  end)
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
    local function proceed()
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
    -- 请求前守卫：AI 可见上下文含原始密钥（假密钥遮蔽被绕过）→ 弹窗确认 / 停止 Agent。
    local guard, guard_err = _guard_secret_context(agent, messages)
    if guard == true then return proceed() end
    if guard == false then return async.reject(guard_err) end
    if type(guard) == "table" and guard.then_ then
      return guard:then_(function() return proceed() end)
    end
    return proceed()
  end

  return attempt()
end

--- 测试用：AI 上下文密钥守卫
M._guard_secret_context = _guard_secret_context

return M
