--- 工具调用循环
--- @module 'NeoAI.core.agent.tool_loop'
--- Agent 的工具调用循环：执行工具 → 请求 AI 继续 → 直到无工具调用。
--- 每轮创建持久流处理器累积 tool_calls 增量。
--- 工具执行经 tool_service（审批 + 调度 + 执行）。
--- 工具调用并行执行；审批在 tool_service 内串行化（单槽位弹窗互不覆盖）。
--- 每轮发送前在轮边界做上下文压力检查（allow_busy 压缩）：上一轮工具结果已回写、
--- 下一轮请求尚未发出，此时折叠历史安全；长循环因此可逐轮收敛，不耗尽上下文。
--- 等工具期间收到新消息（用户/系统/子 Agent）时，已真正开始执行的工具转为后台，
--- 插入「工具已在后台执行，ID：...」说明后立即处理新消息；后台工具完成后把结果追加到
--- 上下文末尾并继续循环；后台未清空时循环不结束。

local async = require("NeoAI.utils.async")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")
local stream_mod = require("NeoAI.core.agent.stream")
local config_store = require("NeoAI.kernel.config_store")
local services = require("NeoAI.kernel.services")

local M = {}

-- ========== 私有常量 ==========

local MAX_ROUNDS = 1000

-- 轮末用户消息注入器：由 chat_service 注册（避免 core→service 反向依赖）。
-- 工具循环每轮结束（工具结果记录完、下次模型调用之前）调用它，把用户在
-- agent 忙碌期间发送、被 pending_queue 暂存的消息插入对话，让下一轮模型看到
-- 这条用户消息，而不是等整个工具循环彻底结束后才插入。
local inject_user = nil

-- 暂存消息探测器：由 chat_service 注册（返回 boolean）。工具循环在启动一批工具
-- 之前用它判断「上一次模型生成期间是否已有消息排队」；若有且本批工具已全部真正
-- 开始执行，则不等工具完成，立即把消息注入并把这批工具转为后台。
local pending_probe = nil

-- 轮前刷新钩子：由 chat_service/mcp 注册（避免 core→service 反向依赖）。
-- 工具循环每轮发送请求（_send_round）之前调用，返回 Deferred。用于在下一轮模型
-- 请求前刷新「因 schema 变化而 stale」的 MCP 工具定义并重绑定 agent.tools，
-- 使下一 Turn 模型看到最新工具签名（失败驱动的时序保证）。
local pre_round_refresh = nil

-- 轮末持久化钩子：由 chat_service 注册（避免 core→service 反向依赖）。
-- 工具循环每轮工具结果落库、运行时上下文刷新后调用，把本回合新增消息增量写入会话存储，
-- 使长循环中途意外退出也能保留已完成进度，而不是等整个循环结束才由调用方统一保存。
local round_persist = nil

-- 达到轮数上限时写入 agent 消息队列的停止说明（chat 界面经 MESSAGE_ADDED 直接可见）
local LOOP_LIMIT_MESSAGE = "⚠️ 工具循环达到最大轮数限制（" .. tostring(MAX_ROUNDS) .. "），已停止继续执行。"

-- 工具执行完毕后模型未返回内容时的收尾说明：避免循环静默结束、聊天看起来"卡住"
local EMPTY_RESPONSE_MESSAGE = "⚠️ 工具已执行完毕，但模型未返回后续内容，本轮生成到此结束。"

-- 工具被取消/中止时写入的显式结果：避免留下孤立 tool_calls，使后续请求被合成
-- 「Tool result unavailable」而让模型误以为调用结果未知。
local CANCELLED_RESULT_MESSAGE =
  "Tool call cancelled: the agent was stopped before this call completed. "
  .. "No side effects should be assumed; re-run the tool if its result is still needed."

-- 后台化说明：工具循环等待工具期间收到新消息时，把在途工具转为后台执行，并在
-- 上下文末尾插入这条系统说明把 ID 告知模型；随后插入新消息并立即发起下一轮。
local BACKGROUND_NOTE_PREFIX = "工具已在后台执行，ID："
local BACKGROUND_NOTE_SUFFIX =
  "。它们的返回信息会在完成后追加到对话末尾；请继续处理下面的消息。"

-- 后台工具完成/取消时追加到上下文末尾的结果消息（role=system, system_update=true）。
local BACKGROUND_RESULT_HEADER_FMT = "后台工具已完成（ID：%s，工具：%s）。返回结果："
local BACKGROUND_CANCELLED_FMT = "后台工具已取消（ID：%s，工具：%s）。"

-- 请求构建时给「已后台化但尚无真实 tool 结果」的调用补的稳定占位结果。
-- 文本必须跨请求逐字节稳定（只含 id），避免改写历史前缀、破坏 provider 前缀缓存。
local BACKGROUND_PENDING_RESULT_FMT =
  "工具已在后台执行（ID：%s）。该工具的返回信息将作为后续消息追加到对话末尾。"

--- 供 runtime 在无工具调用的空响应场景复用同一文案
M.EMPTY_RESPONSE_MESSAGE = EMPTY_RESPONSE_MESSAGE

-- 截断续写：模型输出被输出上限截断（finish_reason=length/max_tokens/MAX_TOKENS）且本轮无
-- 工具调用时，自动附加一条"继续"提示重发，直到获得正文/工具调用或达到次数上限，避免循环
-- 静默退出。提示经 extra_user 只进请求 wire、不落库，续写内容追加进同一条 assistant 消息。
local DEFAULT_MAX_CONTINUES = 3
local CONTINUE_NUDGE = "请从中断处继续输出，不要重复已输出的内容。"
local TRUNCATED_MESSAGE = "⚠️ 模型输出达到长度上限被截断，已尝试自动续写仍未完成，本轮生成到此结束。"
M.TRUNCATED_MESSAGE = TRUNCATED_MESSAGE

-- 各协议/厂商的截断 finish_reason（归一化小写）：OpenAI/DeepSeek "length"、Anthropic
-- "max_tokens"、Gemini "MAX_TOKENS"。
local TRUNCATED_REASONS = {
  length = true,
  max_tokens = true,
  max_output_tokens = true,
  maxtokens = true,
}

--- 是否为输出被截断的 finish_reason
--- @param finish_reason string|nil
--- @return boolean
local function _is_truncated(finish_reason)
  if not finish_reason then return false end
  return TRUNCATED_REASONS[tostring(finish_reason):lower()] == true
end

M.is_truncated = _is_truncated

--- 是否还能继续自动续写（受 ai.truncation.enabled / max_continues 约束）
--- @param agent table
--- @return boolean
local function _can_continue(agent)
  local cfg = config_store.get("ai.truncation") or {}
  if cfg.enabled == false then return false end
  local max = tonumber(cfg.max_continues) or DEFAULT_MAX_CONTINUES
  return (agent._truncation_continues or 0) < max
end

--- 记一次续写并返回续写提示文本
--- @param agent table
--- @return string
local function _begin_continue(agent)
  agent._truncation_continues = (agent._truncation_continues or 0) + 1
  local cfg = config_store.get("ai.truncation") or {}
  return cfg.nudge or CONTINUE_NUDGE
end

-- ========== 私有函数 ==========

--- 解析 tool_call 的 arguments JSON
--- @param arguments string
--- @return table
local function _parse_arguments(arguments)
  local json = require("NeoAI.utils.json")
  local decoded, _ = json.decode_or_nil(arguments or "{}")
  if decoded == nil then
    local repaired = (arguments or ""):gsub("%s+", " ")
    if repaired:sub(1, 1) ~= "{" then repaired = "{" .. repaired end
    if repaired:sub(-1) ~= "}" then repaired = repaired .. "}" end
    decoded, _ = json.decode_or_nil(repaired)
  end
  if decoded == nil then return {} end
  return decoded
end

--- 单个工具调用执行
--- 只负责执行并返回结果，不直接写入 agent 消息队列：并行执行时结果按完成顺序
--- 返回，写入由调用方统一按工具调用原始顺序进行（乱序 tool 消息可能被严格兼容
--- 的 API 拒绝，也会破坏前缀缓存确定性）。
--- @param agent table
--- @param tool_call table
--- @param tool_service table
--- @param opts table { is_sub_agent? }
--- @param exec_opts table|nil 调用方预建的执行选项（含 timer；batch 可改 skip_live_result）
--- @return Deferred resolve({ tool_call_id, name, result_str })
local function _execute_single(agent, tool_call, tool_service, opts, exec_opts)
  local fn = tool_call["function"]
  local name = fn and fn.name or "unknown"
  local args = _parse_arguments(fn and fn.arguments or "{}")
  local logger = require("NeoAI.kernel.logger")
  -- 可暂停计时器：从工具真正开始执行（审批通过 / 直接执行）才计时，
  -- 等待用户审批或 ask_user 回答期间暂停，耗时与超时均不含等待时间。
  -- 计时器由调用方（工具循环 batch）创建并持有，用于判断「工具是否已真正开始执行」：
  -- 未开始（等待审批）或暂停（等待 ask_user/同意窗）时不能把该批工具转为后台。
  local timer = (exec_opts and exec_opts.timer) or require("NeoAI.utils.timer").create()
  exec_opts = exec_opts or vim.tbl_extend("force", {}, opts or {}, { timer = timer })
  exec_opts.timer = timer
  -- 取消信号：ESC/abort 时传播到工具执行层，使 run_command/工具子进程/常驻沙箱能真正
  -- 终止运行中的进程（shell/exec/resident 均订阅 signal），而不是等工具自然结束。
  if exec_opts.signal == nil then exec_opts.signal = agent.signal end
  exec_opts.ui_notice = nil -- 由 tool_service 在执行后回填（仅 UI 展示，不进入模型上下文）
  logger.warn("[tool_loop] 执行工具 %s round=%s", name, tostring(agent._round_seq or ""))

  -- 以原对象（含元表）注册到 kernel 实时指标桥：事件经 nvim_exec_autocmds 深拷贝会丢失元表/方法，
  -- 计时器无法随事件传播。core 只依赖 kernel（不反向依赖 ui），由 ui 的折叠渲染从同一桥读取实时值。
  require("NeoAI.kernel.live_metrics").set(tool_call.id, timer)

  event_bus.emit(events.TOOL_EXECUTION_STARTED, {
    agent_id = agent.id, name = name, args = args, tool_call_id = tool_call.id,
  })

  return tool_service.execute(agent, name, args, tool_call.id, exec_opts):then_(function(result)
    local duration_ms = timer:elapsed()
    logger.warn("[tool_loop] 工具完成 %s 耗时 %dms", name, math.floor(duration_ms))
    local result_str = result
    if type(result) ~= "string" then
      local json = require("NeoAI.utils.json")
      result_str = json.encode(result)
    end
    -- 不携带完整结果：事件 data 会被 nvim_exec_autocmds 深拷贝，而订阅方（UI）只读
    -- tool_call_id/耗时；结果内容从 agent 消息队列读取渲染。
    event_bus.emit(events.TOOL_EXECUTION_COMPLETED, {
      agent_id = agent.id, name = name,
      tool_call_id = tool_call.id, duration_ms = duration_ms,
    })
    require("NeoAI.kernel.live_metrics").clear(tool_call.id)
    -- 运行期结果发布：并发工具的结果按原始顺序统一落库，若等全部完成才写，先完成的工具
    -- 在界面上就一直看不到结果（一个慢工具拖住全部）。这里完成即发布，UI 对尚未配对的
    -- 结果消息用它渲染；正式落库后由下面的 clear_result 回收。
    -- 已后台化的工具不发布：它的返回信息稍后作为末尾 system 消息追加，避免在调用处闪一下
    -- 后又消失（或在原工具块与末尾结果块重复展示）。
    if not exec_opts.skip_live_result then
      pcall(function()
        require("NeoAI.kernel.live_metrics").set_result(tool_call.id, {
          content = result_str,
          duration_ms = duration_ms,
          notice = exec_opts.ui_notice,
          secret_paths = exec_opts.observed_secret_paths,
        })
      end)
    end
    return { tool_call_id = tool_call.id, name = name, result_str = result_str, duration_ms = duration_ms,
      notice = exec_opts.ui_notice, secret_paths = exec_opts.observed_secret_paths }
  end, function(err)
    local duration_ms = timer:elapsed()
    local log = require("NeoAI.kernel.logger")
    log.warn("[tool_loop] 工具失败 %s 耗时 %dms err=%s", name, math.floor(duration_ms), tostring(err and err.message or err))
    local json = require("NeoAI.utils.json")
    local err_msg = type(err) == "table" and (err.message or json.encode(err)) or tostring(err)
    local result_str = json.encode({ error = err_msg, tool = name })
    event_bus.emit(events.TOOL_EXECUTION_ERROR, {
      agent_id = agent.id, name = name, error = err_msg,
      tool_call_id = tool_call.id, duration_ms = duration_ms,
    })
    require("NeoAI.kernel.live_metrics").clear(tool_call.id)
    -- 失败也立即发布结果，理由同成功分支（并发工具不互相拖累）。后台化工具不发布。
    if not exec_opts.skip_live_result then
      pcall(function()
        require("NeoAI.kernel.live_metrics").set_result(tool_call.id, {
          content = result_str,
          duration_ms = duration_ms,
          notice = exec_opts.ui_notice,
          secret_paths = exec_opts.observed_secret_paths,
        })
      end)
    end
    return { tool_call_id = tool_call.id, name = name, result_str = result_str, duration_ms = duration_ms,
      notice = exec_opts.ui_notice, secret_paths = exec_opts.observed_secret_paths }
  end)
end

--- 从 Agent 提取工具定义（供请求使用）
--- 工具按名称字典序输出：确定性 → 相同工具集跨请求逐字节相同，前缀缓存友好。
--- 空 properties 不输出该字段：JSON 中空 Lua 表会编码为 []，DeepSeek 拒绝 [] schema。
--- 拼接工具上下文前先做环境探测：无法获取 workspace/git 目录时禁用相关工具
--- （tools.environment.filter_tools），避免向模型暴露必然失败的调用。
--- @param agent table
--- @return table 数组
function M._tool_definitions(agent)
  -- 自动挂载（每次请求）：主 Agent 的工具集始终与注册表保持一致。修复「Agent 创建早于
  -- 工具懒加载完成」导致的工具集缺失——否则首轮请求会以空工具集发出，且工具循环不触发、
  -- 永远不再刷新。子 Agent（agent.parent 非空）的工具子集由 spawn 显式指定，绝不刷新。
  do
    -- 仅对「由注册表托管工具集」的主 Agent（chat_service 绑定，打 _tools_from_registry 标记）刷新；
    -- 合成/受限 Agent（单元测试、子 Agent）不刷新，避免越权或破坏隔离。
    if agent and not agent.parent and agent._tools_from_registry and not agent._sub_agent_session then
      local registry = require("NeoAI.tools.registry")
      if registry.count() > 0 then
        agent.tools = registry.list_as_map()
      else
        -- 注册表仍为空（阶段 2 尚未加载）：触发全量启动，本轮先按现有工具集发送。
        -- 诊断：若 `is_fully_started()` 已为 true 却无任何工具，说明运行态被外部改写过
        -- （历史上 `:NeoAI Test` 同进程运行会 reset registry / stop plugins）；此时发出的
        -- 请求会缺失 run_command 等全部内置工具。:NeoAI Test 现已隔离到子进程，此告警用于
        -- 暴露其它同类不一致，避免再次静默退化。
        pcall(function()
          local NeoAI = require("NeoAI")
          if type(NeoAI.is_fully_started) == "function" and NeoAI.is_fully_started() then
            require("NeoAI.kernel.logger").warn(
              "[tool_loop] 主 Agent 工具集为空且已 fully_started（运行态不一致？）；本轮将缺失全部内置工具")
          end
          if type(NeoAI.ensure_fully_started) == "function" then
            NeoAI.ensure_fully_started(function() end)
          end
        end)
      end
    end
  end
  local environment = require("NeoAI.tools.environment")
  local tools = environment.filter_tools(agent.tools or {}, agent)
  -- 计划模式：工具上下文只保留只读/信息查询 + ask_user（不暴露任何修改类工具）
  local plan_mode = require("NeoAI.tools.builtin.plan_mode")
  tools = plan_mode.apply_tool_filter(agent, tools)
  local names = {}
  for name in pairs(tools) do
    names[#names + 1] = name
  end
  table.sort(names)
  local out = {}
  for _, name in ipairs(names) do
    local tool = tools[name]
    local tf = { name = name, description = tool.description or ("执行 " .. name) }
    local params = tool.parameters
    if params then
      local cp = { type = params.type or "object" }
      if params.properties and next(params.properties) then
        cp.properties = params.properties
      end
      if params.required and #params.required > 0 then
        cp.required = params.required
      end
      tf.parameters = cp
    end
    out[#out + 1] = { type = "function", ["function"] = tf }
  end
  return out
end

-- 前向声明：_send_round 需在定义前引用 _do_send_round（Lua 局部作用域限制，
-- 前向引用会绕过局部声明而解析到 global nil）。故先声明后赋函数体。
local _do_send_round

--- 发送一次请求（带持久流处理器 + 溢出恢复）
--- 轮边界压力检查：上一轮工具结果已回写、下一轮请求尚未发出，此时做上下文压缩是
--- 安全的（无并发写入）。长工具循环会在此逐轮累积压缩，避免耗尽上下文后撞溢出。
--- 顺序：轮边界压缩 → 轮前刷新（MCP stale schema）→ 实际发送。
--- @param agent table
--- @param opts table|nil { extra_user? = string } extra_user 仅注入请求 wire（截断续写提示）
--- @return Deferred resolve({ next_calls = table|nil, response = table })
local function _send_round(agent, opts)
  -- 轮前刷新：若 MCP 工具因 schema 变化被标记 stale，先刷新定义并重绑定 agent.tools，
  -- 确保下一轮模型看到的工具签名与服务器一致（失败驱动的时序保证）。
  local function _refresh_then_send()
    local refresh_d = M.pre_round_refresh(agent)
    if refresh_d then
      return refresh_d:then_(function() return _do_send_round(agent, opts) end)
    end
    return _do_send_round(agent, opts)
  end
  -- 轮边界压缩：allow_busy=true 放宽 idle 要求（此刻状态为 generating，且即将发送请求）。
  -- 历史条数即将超限（窗口将滑动）时**等待压缩完成**，本轮直接使用「检查点 + 尾部」；
  -- 裸截断会改写请求前缀、使 provider 前缀缓存全量失效。其余情况（token 压力）仍走后台
  -- 异步压缩，不阻塞本轮发送；失败/无可折叠内容均为 no-op，不影响循环。
  local compactor = require("NeoAI.core.session.compactor")
  local function _send_after_compact()
    pcall(function()
      local status = services.use("services.status")
      if status then status.check_pressure(agent) end
    end)
    return _refresh_then_send()
  end
  if compactor.history_overflow(agent) then
    return compactor.maybe_compact(agent, { allow_busy = true })
      :then_(_send_after_compact, _send_after_compact)
  end
  compactor.start_background(agent, { allow_busy = true })
  return _send_after_compact()
end

--- 实际发送一轮请求
--- @param agent table
--- @param opts table|nil { extra_user? = string }
--- @return Deferred
_do_send_round = function(agent, opts)
  opts = opts or {}
  local recovery = require("NeoAI.core.agent.recovery")
  local proc = stream_mod.create(agent)
  local start_ms = vim.uv.hrtime() / 1e6
  local first_chunk_ms = nil
  agent._round_seq = (agent._round_seq or 0) + 1
  local round_seq = agent._round_seq
  return recovery.send_stream(agent, {
    agent_config = agent.config,
    model = agent.model,
    signal = agent.signal,
    extra_user = opts.extra_user,
  }, function(chunk)
    if chunk and first_chunk_ms == nil then
      first_chunk_ms = vim.uv.hrtime() / 1e6
      local logger = require("NeoAI.kernel.logger")
      logger.warn("[tool_loop] 本轮首 token 延迟 %dms round=%d", math.floor(first_chunk_ms - start_ms), round_seq)
    end
    if chunk then proc.process(chunk) end
  end):then_(function(response)
    -- 内容已由 on_chunk 增量写入 agent，这里仅终结工具调用
    if response.usage then agent:add_usage(response.usage) end
    local next_calls = proc.finish()
    -- 附加本轮原始请求/响应元数据（轨迹显示用；不进入模型上下文）
    local request = require("NeoAI.core.agent.request")
    agent:attach_round(request.build_round_meta(response, {
      ttft_ms = first_chunk_ms and (first_chunk_ms - start_ms) or nil,
      total_ms = vim.uv.hrtime() / 1e6 - start_ms,
    }))
    return { next_calls = next_calls, response = response }
  end)
end

--- 截断续写递归（不含预算重置；预算以「一次截断响应」为单位）
--- @param agent table
--- @param result table { next_calls, response }
--- @return Deferred resolve(result)
local function _drain(agent, result)
  local calls = result and result.next_calls
  if calls and #calls > 0 then return async.resolve(result) end
  if not _is_truncated(result and result.response and result.response.finish_reason) then
    return async.resolve(result)
  end
  if not _can_continue(agent) then
    return async.resolve(result)
  end
  local nudge = _begin_continue(agent)
  local logger = require("NeoAI.kernel.logger")
  logger.warn("[tool_loop] 输出被截断，自动续写第 %d 次", agent._truncation_continues)
  return _send_round(agent, { extra_user = nudge }):then_(function(next_result)
    return _drain(agent, next_result)
  end)
end

--- 处理"无工具调用但输出被截断"：自动附加续写提示重发，直到获得工具调用/正文或达到上限。
--- 续写提示经 extra_user 只进请求 wire、不落库；续写内容追加进同一条 assistant 消息
--- （append_content 作用于最后一条 assistant）。每个截断响应独立预算（进入时重置计数）。
--- @param agent table
--- @param result table { next_calls, response }
--- @return Deferred resolve(result)
function M._drain_truncation(agent, result)
  agent._truncation_continues = 0
  return _drain(agent, result)
end

-- ========== 公开 API ==========

--- 注册轮末用户消息注入器（由 chat_service 调用；nil 清除）
--- @param fn function(agent)|nil
function M.set_inject_user(fn)
  inject_user = fn
end

--- 注册暂存消息探测器（由 chat_service 调用；nil 清除）。
--- @param fn function(agent) -> boolean|nil
function M.set_pending_probe(fn)
  pending_probe = fn
end

--- 是否存在暂存消息（供工具循环决定是否立即后台化）。
--- @param agent table
--- @return boolean
function M.has_pending(agent)
  if not pending_probe then return false end
  local ok, res = pcall(pending_probe, agent)
  return ok and res == true
end

--- 注册轮前刷新钩子（由 chat_service/mcp 调用；nil 清除）
--- @param fn function(agent) -> Deferred|nil
function M.set_pre_round_refresh(fn)
  pre_round_refresh = fn
end

--- 注册轮末持久化钩子（由 chat_service 调用；nil 清除）。
--- 每轮工具结果落库后调用，用于把本回合进度增量落盘（长循环中途意外退出不丢进度）。
--- @param fn function(agent)|nil
function M.set_round_persist(fn)
  round_persist = fn
end

--- 在轮末触发一次 pending 注入（工具循环每轮结束调用；也可手动复用）
--- @param agent table
--- @return number 本次注入的消息条数
function M.inject_pending(agent)
  if not inject_user then return 0 end
  local ok, n = pcall(inject_user, agent)
  if not ok then
    require("NeoAI.kernel.logger").warn("[tool_loop] 注入暂存消息失败: %s", tostring(n))
    return 0
  end
  return tonumber(n) or 0
end

--- 在轮前触发一次刷新钩子（工具循环每轮发送前调用；返回 Deferred）
--- @param agent table
--- @return Deferred|nil
function M.pre_round_refresh(agent)
  if pre_round_refresh then return pre_round_refresh(agent) end
  return nil
end

--- 为一轮中尚未记录结果的工具调用补写「已取消」结果，保持 assistant.tool_calls 与
--- tool 消息一一对应。否则历史中会留下孤立 tool_calls，下一轮请求被合成
--- 「Tool result unavailable」，模型无法区分「结果未知」与「用户主动取消」。
--- @param agent table
--- @param calls table 工具调用数组
--- @param settled_ids table|nil id -> true（已有结果的调用不再补写）
local function _settle_cancelled_calls(agent, calls, settled_ids)
  for _, tc in ipairs(calls or {}) do
    if not (settled_ids and settled_ids[tc.id]) then
      local name = tc["function"] and tc["function"].name or "unknown"
      agent:add_tool_result(tc.id, name, CANCELLED_RESULT_MESSAGE)
    end
  end
end

--- 运行工具循环
--- 在等待工具期间收到新消息时，不等工具全部完成：把已真正开始执行的工具转为后台，
--- 插入后台说明 + 新消息并立即继续；后台工具完成后把结果追加到对话末尾；后台未清空
--- 前循环不结束。
--- @param agent table Agent
--- @param tool_calls table 首轮工具调用
--- @param tool_service table services.tool_service
--- @param opts table { is_sub_agent? }
--- @return Deferred resolve({ response = table, rounds = number })
function M.run(agent, tool_calls, tool_service, opts)
  opts = opts or {}
  local current_calls = tool_calls
  local rounds = 0
  local state = "idle" -- idle | batch | round | wait_bg | done
  local batch = nil
  local bg = {} -- tool_call_id -> { name = string }
  local bg_order = {} -- 后台化顺序（取消结果按此顺序追加，历史确定）
  local bg_count = 0
  local bg_waiters = {}
  local queued = {} -- { res = table, cancelled = boolean }
  local run_done = false
  local unsub_input = nil
  local unsub_abort = nil
  local out = async.Deferred.new()

  -- 前向声明（_round ↔ _step ↔ _run_batch 互引）
  local _step
  local _run_batch
  local _detach_batch
  local _finish_batch
  local _maybe_detach

  local function _bg_empty()
    return bg_count == 0
  end

  local function _wake_bg(reason)
    if #bg_waiters == 0 then return end
    local waiters = bg_waiters
    bg_waiters = {}
    for _, d in ipairs(waiters) do d:resolve(reason) end
  end

  local function _wait_bg()
    if _bg_empty() then return async.resolve("done") end
    local d = async.Deferred.new()
    bg_waiters[#bg_waiters + 1] = d
    return d
  end

  local function _bg_done(id)
    if bg[id] then
      bg[id] = nil
      bg_count = math.max(0, bg_count - 1)
    end
    -- 每个后台工具完成都唤醒等待者：立即把该结果追加到末尾并发起下一轮，
    -- 不等待其余后台工具（它们完成时会再次唤醒）。
    _wake_bg("result")
  end

  local function _clear_live_result(id)
    pcall(function() require("NeoAI.kernel.live_metrics").clear_result(id) end)
  end

  local function _record_foreground_result(res)
    if not res then return end
    agent:add_tool_result(res.tool_call_id, res.name, res.result_str, {
      duration_ms = res.duration_ms, notice = res.notice, secret_paths = res.secret_paths,
    })
    _clear_live_result(res.tool_call_id)
  end

  --- 按原始调用顺序记录本批结果；`fill_cancelled=true` 时为缺失调用补写取消结果。
  --- 取消/异常路径也必须保持 tool 消息顺序与 assistant.tool_calls 一致（否则 UI 会按位置错配）。
  --- @param b table|nil
  --- @param results table|nil async.all 的结果数组（原始调用顺序）
  --- @param fill_cancelled boolean|nil
  --- @return table id -> true（已记录结果的调用）
  local function _record_batch_results(b, results, fill_cancelled)
    local ids = {}
    if not b then return ids end
    local by_id = {}
    for _, res in ipairs(results or {}) do
      if res and res.tool_call_id then by_id[res.tool_call_id] = res end
    end
    for i, tc in ipairs(b.calls) do
      local res = by_id[tc.id] or (b.results and b.results[i])
      if not res and fill_cancelled then
        res = {
          tool_call_id = tc.id,
          name = tc["function"] and tc["function"].name or "unknown",
          result_str = CANCELLED_RESULT_MESSAGE,
        }
      end
      if res then
        ids[tc.id] = true
        _record_foreground_result(res)
      end
    end
    return ids
  end

  --- 后台工具结果追加到上下文末尾（system 消息，不伪装成乱序 tool 结果）。
  --- @param res table { tool_call_id, name, result_str, duration_ms?, notice?, secret_paths? }
  --- @param cancelled boolean|nil
  local function _append_background_result(res, cancelled)
    if not res then return end
    local id = res.tool_call_id
    local name = res.name or "unknown"
    local text
    if cancelled then
      text = BACKGROUND_CANCELLED_FMT:format(tostring(id), tostring(name))
    else
      text = BACKGROUND_RESULT_HEADER_FMT:format(tostring(id), tostring(name))
        .. "\n" .. tostring(res.result_str or "")
    end
    agent:add_message("system", text, {
      system_update = true,
      background_result = true,
      background_tool_call_id = id,
      background_body = cancelled and "" or (res.result_str or ""),
      background_cancelled = cancelled and true or nil,
      tool_name = name,
      duration_ms = res.duration_ms,
      notice = res.notice,
      secret_paths = res.secret_paths,
    })
    _clear_live_result(id)
  end

  local function _queue_background(res, cancelled)
    if not res then return end
    queued[#queued + 1] = { res = res, cancelled = cancelled and true or false }
  end

  local function _flush_background()
    if #queued == 0 then return 0 end
    local n = #queued
    for _, item in ipairs(queued) do
      _append_background_result(item.res, item.cancelled)
    end
    queued = {}
    return n
  end

  local function _boundary_commit()
    require("NeoAI.core.session.runtime_context").ensure(agent)
    if round_persist then pcall(round_persist, agent) end
  end

  local function _settled_ids(b)
    local ids = {}
    for _, res in pairs((b and b.results) or {}) do
      if res and res.tool_call_id then ids[res.tool_call_id] = true end
    end
    return ids
  end

  local function _cancel_background_all()
    if bg_count == 0 then
      bg_order = {}
      return
    end
    for _, id in ipairs(bg_order) do
      local info = bg[id]
      if info then
        _append_background_result({
          tool_call_id = id,
          name = info.name or "unknown",
          result_str = "",
        }, true)
      end
    end
    bg = {}
    bg_order = {}
    bg_count = 0
  end

  -- 当前 batch 是否所有未完成工具都已真正开始执行（timer.running）。
  -- 只要有一个未完成工具在等待审批 / ask_user / 同意窗（timer 未 running 且未 settled），
  -- 整批先不转后台（消息继续暂存），等它 start/resume 时由 timer.on_active 再次尝试。
  local function _can_detach(b)
    if not b or b.detached or b.detaching then return false end
    local unsettled, running = 0, 0
    for i = 1, #b.calls do
      if not b.results[i] then
        unsettled = unsettled + 1
        local timer = b.timers[i]
        if timer and timer.running then
          running = running + 1
        else
          return false -- 存在等待交互 / 尚未开始的工具
        end
      end
    end
    return unsettled > 0 and running == unsettled
  end

  _maybe_detach = function()
    if run_done or state ~= "batch" then return end
    local b = batch
    if not _can_detach(b) then return end
    if not M.has_pending(agent) then return end
    b.detaching = true
    if b.detach_d then b.detach_d:resolve("detach") end
  end

  local function _finalize()
    if run_done then return end
    run_done = true
    state = "done"
    if unsub_input then pcall(unsub_input); unsub_input = nil end
    if unsub_abort then pcall(unsub_abort); unsub_abort = nil end
    _wake_bg("done")
    batch = nil
  end

  local function _round()
    if agent.signal:aborted() then
      return async.reject({ kind = "aborted", message = "工具循环被取消" })
    end
    rounds = rounds + 1
    if rounds > MAX_ROUNDS then
      _cancel_background_all()
      agent:add_message("assistant", LOOP_LIMIT_MESSAGE)
      event_bus.emit(events.TOOL_LOOP_LIMIT_REACHED, { agent_id = agent.id, rounds = rounds })
      return async.resolve({ response = agent.messages[#agent.messages], rounds = rounds, stopped = true })
    end
    state = "round"
    agent:set_state("generating")
    return _send_round(agent):then_(function(result)
      return M._drain_truncation(agent, result)
    end):then_(function(final_result)
      current_calls = final_result.next_calls
      if not current_calls or #current_calls == 0 then
        local last = agent.messages[#agent.messages]
        if _is_truncated(final_result.response and final_result.response.finish_reason) then
          agent:add_message("assistant", TRUNCATED_MESSAGE)
        elseif last and last.role == "tool" then
          agent:add_message("assistant", EMPTY_RESPONSE_MESSAGE)
        end
      end
      return _step()
    end)
  end

  local function _background_note(ids)
    local parts = {}
    for _, id in ipairs(ids) do parts[#parts + 1] = tostring(id) end
    return BACKGROUND_NOTE_PREFIX .. table.concat(parts, ", ") .. BACKGROUND_NOTE_SUFFIX
  end

  local function _mark_background(b)
    local last = agent.messages[#agent.messages]
    if not (last and last.role == "assistant" and last.tool_calls) then return end
    last.background_tool_ids = last.background_tool_ids or {}
    -- 整批都打标记：已完成的前台结果会作为“后台结果”消息追加，请求构建时同一批的每个
    -- call 都必须用稳定的后台占位结果（而不是 unavailable），否则协议/语义不一致。
    for _, tc in ipairs(b.calls) do
      if tc.id then last.background_tool_ids[tc.id] = true end
    end
  end

  _detach_batch = function(b)
    if agent.signal:aborted() then
      _record_batch_results(b, nil, true)
      return async.reject({ kind = "aborted", message = "工具循环被取消" })
    end
    b.detached = true
    b.detaching = true
    current_calls = nil

    local pending_ids = {}
    for i, tc in ipairs(b.calls) do
      if b.results[i] == nil then
        pending_ids[#pending_ids + 1] = tc.id
        if not bg[tc.id] then bg_order[#bg_order + 1] = tc.id end
        bg[tc.id] = { name = tc["function"] and tc["function"].name or "unknown" }
        bg_count = bg_count + 1
        -- 后台工具的结果只作为末尾 system 消息出现，不再向 live_metrics 发布“调用处结果”。
        if b.exec_opts[i] then b.exec_opts[i].skip_live_result = true end
      end
    end
    _mark_background(b)
    if #pending_ids > 0 then
      agent:add_message("system", _background_note(pending_ids), {
        system_update = true,
        background_note = true,
      })
    end

    local guard = require("NeoAI.core.agent.guard")
    local guard_cfg = config_store.get("tools.guard.repeat_tool") or {}
    local reminder = guard.check_round(agent, b.calls, guard_cfg)
    if reminder then
      agent:add_message("user", reminder, { mid_turn = true })
      event_bus.emit(events.TOOL_LOOP_GUARD_REMINDER, {
        agent_id = agent.id, repeats = agent.guard and agent.guard.repeats,
      })
    end

    -- 立即注入新消息（紧跟在后台说明之后），不等后台工具。
    M.inject_pending(agent)
    -- 转后台前已经完成的前台工具：结果追加到对话末尾（在新消息之后）。
    for i = 1, #b.calls do
      local res = b.results[i]
      if res and not res._background_queued then
        res._background_queued = true
        _queue_background(res, false)
      end
    end
    _flush_background()

    _boundary_commit()
    agent:set_state("generating")
    event_bus.emit(events.TOOL_LOOP_FINISHED, { agent_id = agent.id, rounds = rounds })
    batch = nil
    return _round()
  end

  _finish_batch = function(b, results)
    current_calls = nil
    _record_batch_results(b, results, true)
    -- 本批执行期间完成的后台结果：追加到末尾。
    _flush_background()
    if agent.signal:aborted() then
      -- 已完成的结果与缺失调用的取消结果都已按原始顺序落库；直接终止本轮。
      return async.reject({ kind = "aborted", message = "工具循环被取消" })
    end

    local guard = require("NeoAI.core.agent.guard")
    local guard_cfg = config_store.get("tools.guard.repeat_tool") or {}
    local reminder = guard.check_round(agent, b.calls, guard_cfg)
    if reminder then
      agent:add_message("user", reminder, { mid_turn = true })
      event_bus.emit(events.TOOL_LOOP_GUARD_REMINDER, {
        agent_id = agent.id, repeats = agent.guard and agent.guard.repeats,
      })
    end

    M.inject_pending(agent)
    _boundary_commit()
    agent:set_state("generating")
    event_bus.emit(events.TOOL_LOOP_FINISHED, { agent_id = agent.id, rounds = rounds })
    batch = nil
    return _round()
  end

  _run_batch = function(calls)
    state = "batch"
    agent:set_state("tool_running")
    event_bus.emit(events.TOOL_LOOP_STARTED, { agent_id = agent.id, tool_calls = calls })

    local b = {
      calls = calls,
      results = {},
      timers = {},
      exec_opts = {},
      detached = false,
      detaching = false,
      detach_d = async.Deferred.new(),
    }
    batch = b

    local promises = {}
    for i, tc in ipairs(calls) do
      local timer = require("NeoAI.utils.timer").create()
      -- 交互结束、工具真正开始/恢复执行时，若已有消息在暂存且本批全部工具都已 running，
      -- 立即转后台（不把一个已排队消息拖到整批工具结束）。
      timer.on_active = _maybe_detach
      local exec_opts = vim.tbl_extend("force", {}, opts, { timer = timer })
      b.timers[i] = timer
      b.exec_opts[i] = exec_opts
      local p = _execute_single(agent, tc, tool_service, opts, exec_opts)
      promises[i] = p
      p:then_(function(res)
        if run_done then return end
        b.results[i] = res
        if b.detached then
          _queue_background(res, false)
          _bg_done(tc.id)
        end
      end, function(err)
        if run_done then return end
        local msg = type(err) == "table" and (err.message or "tool error") or tostring(err)
        local res = {
          tool_call_id = tc.id,
          name = tc["function"] and tc["function"].name or "unknown",
          result_str = require("NeoAI.utils.json").encode({ error = msg }),
          duration_ms = timer:elapsed(),
        }
        b.results[i] = res
        if b.detached then
          _queue_background(res, false)
          _bg_done(tc.id)
        end
      end)
    end

    local all_d = async.all(promises):then_(function(results)
      return { kind = "all", results = results }
    end)
    local detach_d = b.detach_d:then_(function(reason)
      return { kind = "detach", reason = reason }
    end)

    -- 模型生成期间已排队的消息：batch 一启动就尝试转后台（若工具已全部开始执行）。
    _maybe_detach()

    return async.race({ all_d, detach_d }):then_(function(winner)
      if agent.signal:aborted() then
        _record_batch_results(b, winner and winner.results, true)
        return async.reject({ kind = "aborted", message = "工具循环被取消" })
      end
      if winner and winner.kind == "detach" then
        return _detach_batch(b)
      end
      return _finish_batch(b, winner and winner.results or {})
    end, function(err)
      -- 本轮工具并发执行被取消/异常：按原始调用顺序记录已完成结果 + 取消结果。
      _record_batch_results(b, nil, true)
      return async.reject(err)
    end)
  end

  _step = function()
    if agent.signal:aborted() then
      local settled = batch and _settled_ids(batch) or {}
      if current_calls then _settle_cancelled_calls(agent, current_calls, settled) end
      return async.reject({ kind = "aborted", message = "工具循环被取消" })
    end
    if current_calls and #current_calls > 0 then
      return _run_batch(current_calls)
    end

    -- 无当前工具调用：先追加后台结果、再注入新消息；任一发生都要再发一轮让模型感知。
    local flushed = _flush_background()
    local injected = M.inject_pending(agent)
    if flushed > 0 or injected > 0 then
      _boundary_commit()
      return _round()
    end
    if not _bg_empty() then
      state = "wait_bg"
      agent:set_state("tool_running")
      return _wait_bg():then_(function() return _step() end)
    end

    state = "done"
    _finalize()
    return async.resolve({ response = agent.messages[#agent.messages], rounds = rounds })
  end

  -- 消息事件：batch 中尝试转后台；wait_bg 中唤醒（消息由 _step 注入）。
  unsub_input = event_bus.on(events.MESSAGE_QUEUED, function(data)
    if run_done or not data or data.agent_id ~= agent.id then return end
    if state == "batch" then
      _maybe_detach()
    elseif state == "wait_bg" then
      _wake_bg("input")
    end
    -- state == "round"：当前 assistant 正在流式写入，不能中途插入；本轮结束后注入。
  end)

  unsub_abort = agent.signal:subscribe(function()
    if run_done then return end
    if batch and batch.detach_d then batch.detach_d:resolve("abort") end
    _wake_bg("abort")
  end)

  _step():then_(function(value)
    _finalize()
    out:resolve(value)
  end, function(err)
    -- 失败/取消：为仍未完成的后台工具追加取消结果，保持历史可解释；随后清理订阅。
    _cancel_background_all()
    _finalize()
    out:reject(err)
  end)
  return out
end

return M
