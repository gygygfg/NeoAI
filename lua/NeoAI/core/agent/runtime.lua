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

local M = {}

-- ========== 私有状态 ==========

local state = {
  agents = {}, -- agent_id -> agent
  sessions = {}, -- session_id -> agent_id
}

-- ========== 私有函数 ==========

--- 解析 agent 的场景配置
--- @param config table 用户/系统配置
--- @param scenario string|nil
--- @return table agent_config
local function _resolve_agent_config(config, scenario)
  scenario = scenario or "chat"
  local agent_config = {
    provider = config_store.get("ai.default_provider"),
    model = nil,
    temperature = 0.7,
    max_tokens = 4096,
    stream = true,
    system_prompt = config_store.get("ai.system_prompt"),
  }
  local scenarios = config_store.get("ai.scenarios") or {}
  local sc = scenarios[scenario]
  if sc then
    if sc.provider then agent_config.provider = sc.provider end
    if sc.preset then
      local presets = config_store.get("ai.presets") or {}
      local preset = presets[sc.preset]
      if preset then
        if preset.model then agent_config.model = preset.model end
        if preset.temperature ~= nil then agent_config.temperature = preset.temperature end
        if preset.max_tokens then agent_config.max_tokens = preset.max_tokens end
        if preset.stream ~= nil then agent_config.stream = preset.stream end
      end
    end
  end
  -- 用户级覆盖
  if config then
    if config.provider then agent_config.provider = config.provider end
    if config.model then agent_config.model = config.model end
    if config.temperature ~= nil then agent_config.temperature = config.temperature end
    if config.max_tokens then agent_config.max_tokens = config.max_tokens end
    if config.stream ~= nil then agent_config.stream = config.stream end
  end
  -- 从 registry 解析 "auto"
  if agent_config.model == "auto" then
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
  local tool_service = require("NeoAI.services.tool_service")
  local recovery = require("NeoAI.core.agent.recovery")

  local proc = stream_mod.create(agent)
  agent._overflow_recovered = false
  agent:set_state("generating")
  event_bus.emit(events.GENERATION_STARTED, { agent_id = agent.id })

  local function _finish_idle(message)
    agent:set_state("idle")
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

      if tool_calls and #tool_calls > 0 then
        local tool_loop = require("NeoAI.core.agent.tool_loop")
        return tool_loop.run(agent, tool_calls, tool_service, {}):then_(function()
          return _finish_idle(agent.messages[#agent.messages])
        end)
      end

      -- 无工具调用但模型也没返回任何内容（空响应）：写一条可见说明，避免聊天里
      -- 只看到用户消息却没有任何回复、看起来像"卡住"。
      local last = agent.messages[#agent.messages]
      local has_visible_content = last and last.role == "assistant"
        and ((last.content and last.content ~= "") or (last.reasoning and last.reasoning ~= ""))
      if not has_visible_content then
        local tool_loop = require("NeoAI.core.agent.tool_loop")
        agent:add_message("assistant", tool_loop.EMPTY_RESPONSE_MESSAGE)
      end

      return _finish_idle(response)
    end, function(err)
      agent:set_state("error")
      event_bus.emit(events.GENERATION_ERROR, { agent_id = agent.id, error = err })
      return async.reject(err)
    end)
  end

  return _run()
end

-- ========== 公开 API ==========

--- 创建 Agent
--- @param opts table { config?, scenario?, session_id?, model?, tools? }
--- @return table Agent
function M.create(opts)
  opts = opts or {}
  local agent_config = _resolve_agent_config(opts.config, opts.scenario or "chat")
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
  if agent_mod.is_busy(agent) then
    return async.reject({ kind = "busy", message = "Agent 正忙" })
  end
  -- 新一步之前先做上下文压缩检查（对齐 deepseek-harness 的 pre-step 压力检查）：
  -- 已到达压力阈值则先折叠旧历史，再派生请求，复用未变的前缀缓存。
  local compactor = require("NeoAI.core.session.compactor")
  return compactor.maybe_compact(agent):then_(function()
    -- 用户新输入重置工具循环护栏计数链
    local guard = require("NeoAI.core.agent.guard")
    guard.reset(agent)
    agent_mod.add_message(agent, "user", content)
    event_bus.emit(events.MESSAGE_SENT, { agent_id = agent.id, content = content })
    return _run_generation(agent, {})
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
