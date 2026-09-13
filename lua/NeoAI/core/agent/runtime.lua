--- Agent 运行时
--- @module NeoAI.core.agent.runtime
--- 创建/派生/销毁 Agent，编排生成流程。
--- - create(config)：全新 Agent 实例
--- - spawn(parent, override)：创建子 Agent（全新环境，零继承）
--- - dispose(agent)：销毁，释放资源
--- - abort(agent)：取消
--- - run(agent, content)：用户消息 → 生成（含工具循环）

local agent_mod = require("NeoAI.core.agent.agent")
local async = require("NeoAI.utils.async")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")
local config_store = require("NeoAI.kernel.config_store")
local services = require("NeoAI.kernel.services")

local M = {}

-- ========== 私有状态 ==========

local state = {
  agents = {}, -- agent_id -> agent
  sessions = {}, -- session_id -> agent_id
}

-- ========== 私有函数 ==========

--- 解析 agent 的模式配置
--- 按当前会话模式（chat/plan/auto）从 ai.modes 取 provider/model/temperature/etc.，
--- 再叠加用户级覆盖，最后把 "auto" 模型解析为 registry 默认模型。
--- @param config table 用户/系统配置（覆盖层）
--- @param mode string|nil "chat" | "plan" | "auto"
--- @return table agent_config
local function _resolve_agent_config(config, mode)
  mode = mode or "chat"
  local modes = config_store.get("ai.modes") or {}
  local mc = modes[mode] or {}
  local agent_config = {
    provider = mc.provider or config_store.get("ai.default_provider"),
    model = mc.model,
    temperature = mc.temperature ~= nil and mc.temperature or 0.7,
    -- 未配置即 nil：请求不发送 max_tokens，由模型/厂商默认最大输出决定。
    max_tokens = mc.max_tokens,
    stream = mc.stream ~= nil and mc.stream or true,
    system_prompt = config_store.get("ai.system_prompt"),
  }
  -- 用户级覆盖
  if config then
    if config.provider then agent_config.provider = config.provider end
    if config.model then agent_config.model = config.model end
    if config.temperature ~= nil then agent_config.temperature = config.temperature end
    if config.max_tokens then agent_config.max_tokens = config.max_tokens end
    if config.stream ~= nil then agent_config.stream = config.stream end
  end
  -- 从 registry 解析 "auto"
  if agent_config.model == "auto" or not agent_config.model then
    local registry = require("NeoAI.core.model.registry")
    agent_config.model = registry.resolve_default(agent_config.provider)
  end
  return agent_config
end

--- 加载 Agent 可见的工具子集
--- @param agent table
--- @param tools table name -> def
function M._bind_tools(agent, tools)
  agent.tools = tools or {}
end

--- 发送生成请求（含工具循环决策）
--- @param agent table
--- @param opts table { tools?=tool_service 提供的工具表 }
--- @return Deferred resolve(最终响应)
local function _run_generation(agent, opts)
  local stream_mod = require("NeoAI.core.agent.stream")
  local tool_service = services.use("services.tool_service")
  local recovery = require("NeoAI.core.agent.recovery")

  local proc = stream_mod.create(agent)
  agent._overflow_recovered = false
  agent:set_state("generating")
  event_bus.emit(events.GENERATION_STARTED, { agent_id = agent.id })

  local function _finish_idle(message)
    -- 先释放生成占用令牌、再回到 idle：保证 AGENT_STATE_CHANGED 触发的 pending 刷新
    -- 能在同一 tick 看到 agent 已空闲并立即启动下一条消息，而不是被本轮的 claim 挡住。
    agent._turn_claim = nil
    agent:set_state("idle")
    -- 上下文压力提示（状态栏变色 + notify；同一级别去重）
    pcall(function()
      local status = services.use("services.status")
      if status then status.check_pressure(agent) end
    end)
    event_bus.emit(events.GENERATION_COMPLETED, { agent_id = agent.id, message = message })
    return message
  end

  local function _run()
    local start_ms = vim.uv.hrtime() / 1e6
    local first_chunk_ms = nil
    return recovery.send_stream(agent, {
      agent_config = agent.config,
      model = agent.model,
      signal = agent.signal,
    }, function(chunk)
      if chunk and first_chunk_ms == nil then
        first_chunk_ms = vim.uv.hrtime() / 1e6
        local logger = require("NeoAI.kernel.logger")
        logger.warn("[runtime] 首 token 延迟 %dms", math.floor(first_chunk_ms - start_ms))
      end
      if chunk then proc.process(chunk) end
    end):then_(function(response)
      -- 内容已由 on_chunk 增量写入 agent，这里仅终结工具调用
      if response.usage then agent:add_usage(response.usage) end
      local tool_calls = proc.finish()

      -- 附加本轮原始请求/响应元数据（轨迹显示用；不进入模型上下文）
      local request = require("NeoAI.core.agent.request")
      agent:attach_round(request.build_round_meta(response, {
        ttft_ms = first_chunk_ms and (first_chunk_ms - start_ms) or nil,
        total_ms = vim.uv.hrtime() / 1e6 - start_ms,
      }))

      -- 首轮响应即使无工具调用，也可能因输出被截断（finish_reason=length）而中断：
      -- 先交给 tool_loop 的截断续写逻辑（附加"继续"提示重发，提示不落库），
      -- 续写出工具调用则进入工具循环，否则按可见内容/截断/空响应收尾。
      local tool_loop = require("NeoAI.core.agent.tool_loop")
      return tool_loop._drain_truncation(agent, { next_calls = tool_calls, response = response })
        :then_(function(result)
          local calls = result.next_calls
          if calls and #calls > 0 then
            if not tool_service then
              return async.reject({ kind = "service", message = "工具服务未启用，无法执行工具调用" })
            end
            return tool_loop.run(agent, calls, tool_service, {}):then_(function()
              return _finish_idle(agent.messages[#agent.messages])
            end)
          end

          -- 无工具调用且模型也没返回任何内容（空响应）：写一条可见说明，避免聊天里
          -- 只看到用户消息却没有任何回复、看起来像"卡住"。截断未续写成功时优先提示截断。
          local last = agent.messages[#agent.messages]
          local has_visible_content = last and last.role == "assistant"
            and ((last.content and last.content ~= "") or (last.reasoning and last.reasoning ~= ""))
          if tool_loop.is_truncated(result.response and result.response.finish_reason) then
            agent:add_message("assistant", tool_loop.TRUNCATED_MESSAGE)
          elseif not has_visible_content then
            agent:add_message("assistant", tool_loop.EMPTY_RESPONSE_MESSAGE)
          end

          return _finish_idle(response)
        end)
    end, function(err)
      -- 用户取消（ESC）：正常停止而非错误。错误回调在 abort 时也会被触发，
      -- 若按普通错误处理会把状态覆盖为 error、并发 GENERATION_ERROR，
      -- 导致聊天界面弹"发送失败"提示。这里屏蔽并转为 benign 取消信号；
      -- 同时把状态复位为 idle，否则 `_run_generation` 已置的 "generating"
      -- （或 abort 的 "aborted"）会让同一 Agent 在取消后继续发送时卡在 busy。
      local is_cancel = err and (err.kind == "aborted" or err.kind == "cancelled")
      -- 所有结束路径都释放生成占用令牌（_run_generation 内已置 _turn_claim），
      -- 否则 Agent 会永久停留在"忙碌"，后续发送被吞进 pending_queue 且永不刷新。
      agent._turn_claim = nil
      if is_cancel then
        agent:set_state("idle")
        return async.reject({ kind = "cancelled", message = err.message or "已取消" })
      end
      agent:set_state("error")
      event_bus.emit(events.GENERATION_ERROR, { agent_id = agent.id, error = err })
      return async.reject(err)
    end)
  end

  return _run()
end

-- ========== 公开 API ==========

--- 应用某模式的模型配置到已有 Agent（模式切换时调用）。
--- 提供者/模型/温度/max_tokens/流式随 modes 变化；系统提示等全局项不改。
--- @param agent table
--- @param mode string "chat" | "plan" | "auto"
--- @return table Agent
function M.apply_mode(agent, mode)
  if not agent then return nil end
  local cfg = _resolve_agent_config(nil, mode or "chat")
  agent.model = cfg.model
  agent.config.provider = cfg.provider
  agent.config.temperature = cfg.temperature
  agent.config.max_tokens = cfg.max_tokens
  agent.config.stream = cfg.stream
  event_bus.emit(events.MODEL_SWITCHED, { agent_id = agent.id, model = agent.model, mode = mode })
  return agent
end

--- 创建 Agent
--- @param opts table { config?, mode?, session_id?, model?, tools? }
--- @return table Agent
function M.create(opts)
  opts = opts or {}
  local agent_config = _resolve_agent_config(opts.config, opts.mode or opts.scenario or "chat")
  local agent = agent_mod.create({
    session_id = opts.session_id,
    config = agent_config,
    model = opts.model or agent_config.model,
    tools = opts.tools or {},
  })
  state.agents[agent.id] = agent
  if opts.session_id then
    state.sessions[opts.session_id] = agent.id
  end
  event_bus.emit(events.AGENT_CREATED, { agent = agent })
  return agent
end

--- 派生子 Agent（全新环境，零继承）
--- @param parent table Agent
--- @param override table { task?, tools?, model?, scenario? }
--- @return table 子 Agent
function M.spawn(parent, override)
  override = override or {}
  local child = agent_mod.create({
    session_id = nil,
    parent = parent.id,
    config = vim.deepcopy(parent.config),
    model = override.model or parent.model,
    tools = override.tools or {},
  })
  -- 子 Agent 拥有独立信号（不继承父信号）
  child.signal = async.create_signal()
  state.agents[child.id] = child
  event_bus.emit(events.AGENT_SPAWNED, { parent = parent.id, agent = child })
  if override.task then
    child.task = override.task
  end
  return child
end

--- 销毁 Agent，释放资源
--- @param agent table
function M.dispose(agent)
  if not agent then return end
  -- 释放该会话模型对应的显式缓存资源（Gemini cachedContents 等）
  pcall(function()
    require("NeoAI.core.model.prompt_cache").dispose(
      agent.config and agent.config.provider, agent.model)
  end)
  local plan_mode = require("NeoAI.tools.builtin.plan_mode")
  plan_mode.cleanup(agent)
  agent_mod.dispose(agent)
  state.agents[agent.id] = nil
  if agent.session_id then
    state.sessions[agent.session_id] = nil
  end
end

--- 取消 Agent
--- @param agent table
--- @param reason string|nil
--- @return table Agent
function M.abort(agent, reason)
  return agent_mod.abort(agent, reason)
end

--- 运行 Agent：添加用户消息并生成
--- @param agent table
--- @param content string
--- @return Deferred resolve(响应)
function M.run(agent, content)
  -- 原子占用生成槽位：状态在 maybe_compact / 异步链中才置为 generating，若仅靠 state
  -- 判断（chat_service._is_busy 与这里此前都只看 state），同一 tick 内连续两次 send
  -- （模式切换、approve_plan 自动执行后立即发送等场景常触发）都会判为 idle 并并行
  -- 启动两个 _run_generation：两个流写入同一条 assistant 消息、互相争夺 agent.state，
  -- 表现为回复合并/错乱，或把状态卡在 busy 导致后续消息被吞进 pending_queue 永不刷新
  -- （"发出但无响应"）。用同步令牌 _turn_claim 在进入前标记忙碌，重复调用直接拒绝/入队。
  if agent._turn_claim or agent_mod.is_busy(agent) then
    return async.reject({ kind = "busy", message = "Agent 正忙" })
  end
  local claim_id = (agent._claim_seq or 0) + 1
  agent._claim_seq = claim_id
  agent._turn_claim = claim_id
  -- 上一次生成被取消（ESC）后，取消信号永久处于 aborted：若不重置，新一轮
  -- request.send_stream 会因信号已取消而立即失败（"operation aborted"），
  -- 表现为"停止后继续发送报错"。这里在开启新一步前检测并重置为全新信号。
  if agent.signal:aborted() then
    agent.signal = async.create_signal()
  end
  -- 新一步之前先做上下文压缩检查（对齐 deepseek-harness 的 pre-step 压力检查）：
  -- 已到达压力阈值则先折叠旧历史，再派生请求，复用未变的前缀缓存。
  local compactor = require("NeoAI.core.session.compactor")
  return compactor.maybe_compact(agent):then_(function()
    -- 压缩后仍有压力则先提示（超限时让用户知道下一轮可能溢出/被压缩）
    pcall(function()
      local status = services.use("services.status")
      if status then status.check_pressure(agent) end
    end)
    -- 用户新输入重置工具循环护栏计数链与截断续写计数
    local guard = require("NeoAI.core.agent.guard")
    guard.reset(agent)
    agent._truncation_continues = nil
    -- 易变运行态（todos/计划模式）以运行时上下文快照追加进历史：
    -- 系统提示保持逐字节稳定，前缀缓存不因它们变化而失效。
    require("NeoAI.core.session.runtime_context").ensure(agent)
    agent_mod.add_message(agent, "user", content)
    event_bus.emit(events.MESSAGE_SENT, { agent_id = agent.id, content = content })
    return _run_generation(agent, {})
  end):finally(function()
    -- 兜底释放：仅在令牌仍属本轮时清除，避免误清掉 AGENT_STATE_CHANGED 刷新
    -- 链同步启动的下一轮（_finish_idle 已在置 idle 前清掉本轮的令牌，此分支通常
    -- 只在异常路径（如工具循环被取消且未走 _finish_idle）触发）。
    if agent._turn_claim == claim_id then
      agent._turn_claim = nil
    end
  end)
end

--- 获取 Agent
--- @param agent_id string
--- @return table|nil
function M.get(agent_id)
  return state.agents[agent_id]
end

--- 按 session_id 获取 Agent
--- @param session_id string
--- @return table|nil
function M.get_by_session(session_id)
  local agent_id = state.sessions[session_id]
  if not agent_id then return nil end
  return state.agents[agent_id]
end

--- 获取所有 Agent
--- @return table
function M.get_all()
  return state.agents
end

--- 重置（测试用）
function M.reset()
  for _, agent in pairs(state.agents) do
    agent_mod.dispose(agent)
  end
  state.agents = {}
  state.sessions = {}
end

return M
