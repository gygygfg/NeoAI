--- 向用户提问工具
--- @module 'NeoAI.tools.builtin.ask_user'
--- AI 在生成过程中暂停并向用户提问，等待用户回答后把答案作为工具结果回传。
--- 计划模式下该工具是少数被允许的工具之一（用于澄清需求）。
--- 同一轮（同 agent 且同 agent._round_seq）内的多次调用会被聚合为**一个多 Tab 弹窗**统一作答；
--- 跨轮调用分别成批、串行展示（不直接失败）。
--- UI 经 M.set_ui 注入（ui/components/ask_user 在 UI 初始化时注册）；
--- 未注册 UI 时回退到 vim.ui.input（多题按题顺序逐个询问），仍不可用则报错（不阻塞工具循环）。

local helpers = require("NeoAI.tools.builtin.tool_helpers")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")
local ui_hooks = require("NeoAI.kernel.ui_hooks")

local M = {}

-- ========== 私有状态 ==========

-- 提问 UI 经 kernel.ui_hooks 注册（ui/components/ask_user 注入），tools 不直接依赖 ui。
local UI_HOOK = "ask_user"

-- 同轮聚合：token = agent.id .. "#" .. round_seq。
-- 同一 token 的多次调用并入同一批次（batch）；不同 token 的批次串行展示（UI 是单窗口）。
local batches = {} -- token -> batch
local batch_order = {} -- 批次创建顺序（token 列表；保证 _flush 与展示的确定性）
local pending = {} -- 已就绪待展示的批次（FIFO）
local current = nil -- 当前展示中的批次
local seq = 0 -- 无 agent.id 时的唯一 token 兜底计数
local DEFAULT_DEBOUNCE_MS = 25 -- 覆盖同轮兄弟调用到达时序的去抖窗口

-- ========== 私有辅助（配置读取） ==========

--- 读取 ui.ask_user 配置（失败回退空表）
--- @return table
local function _ui_cfg()
  local ok, cfg = pcall(function()
    return require("NeoAI.kernel.config_store").get("ui.ask_user")
  end)
  if ok and type(cfg) == "table" then return cfg end
  return {}
end

--- 去抖窗口毫秒数（ui.ask_user.batch_debounce_ms）
--- @return number
local function _debounce_ms()
  local n = tonumber(_ui_cfg().batch_debounce_ms)
  if n and n >= 0 then return math.floor(n) end
  return DEFAULT_DEBOUNCE_MS
end

--- 是否要求汇总页二次确认（ui.ask_user.require_confirm，缺省 true）
--- @return boolean
local function _require_confirm()
  local v = _ui_cfg().require_confirm
  if v == nil then return true end
  return v ~= false
end

-- ========== 私有辅助（批次调度） ==========

-- 前置声明（闭包互引）
local _drain
local _activate_batch
local _present_batch
local _submit_batch
local _cancel_batch
local _fallback_batch

--- 聚合令牌：同一轮并行派发的多次调用共享 agent._round_seq。
--- 缺 agent.id 时退化为唯一 token（不聚合），避免误合并。
--- @param ctx table|nil
--- @return string
local function _token(ctx)
  local agent = ctx and ctx.agent
  local id = agent and agent.id
  if id == nil or id == "" then
    seq = seq + 1
    return "__anon_" .. tostring(seq)
  end
  return tostring(id) .. "#" .. tostring((agent and agent._round_seq) or 0)
end

--- 终结一个 invocation：逐项上报 answered 事件、恢复计时器、解绑信号、回传结果。
--- @param inv table 提问对象
--- @param ok boolean 是否成功
--- @param result any 成功时答案 / 失败时错误表
local function _settle_inv(inv, ok, result)
  if inv.settled then return end
  inv.settled = true
  if inv.waiting_started then
    event_bus.emit(events.ASK_USER_ANSWERED, { agent_id = inv.agent_id })
  end
  if inv.timer and inv.timer.resume then pcall(inv.timer.resume, inv.timer) end
  if inv.unsub then
    pcall(inv.unsub)
    inv.unsub = nil
  end
  if ok then
    inv.on_success(result)
  else
    inv.on_error(result)
  end
end

--- 终结一个批次：停去抖、从索引与队列移除、释放 current，必要时展示下一个批次。
--- @param batch table
--- @param allow_next boolean 是否继续展示队首（用户回答/取消后 true；Agent 中止时不新开）
local function _settle_batch(batch, allow_next)
  if batch.settled then return end
  batch.settled = true
  if batch.debounce then
    pcall(batch.debounce.stop, batch.debounce)
    pcall(batch.debounce.close, batch.debounce)
    batch.debounce = nil
  end
  if batch.token and batches[batch.token] == batch then batches[batch.token] = nil end
  for i = #batch_order, 1, -1 do
    if batch_order[i] == batch.token then table.remove(batch_order, i) end
  end
  for i = #pending, 1, -1 do
    if pending[i] == batch then table.remove(pending, i) end
  end
  if current == batch then current = nil end
  if allow_next then _drain() end
end

--- 入队一个就绪批次（去抖到期后调用）
--- @param batch table
local function _enqueue_batch(batch)
  if batch.settled or batch.queued then return end
  batch.queued = true
  pending[#pending + 1] = batch
  _drain()
end

--- 若当前无展示中的批次，弹出队首批次
_drain = function()
  while not current do
    local batch = table.remove(pending, 1)
    if not batch then return end
    batch.queued = false
    if not batch.settled then
      current = batch
      _activate_batch(batch)
    end
  end
end

--- 开始展示一个批次：逐项上报 waiting 事件并暂停计时器，然后交给 UI（或回退）
--- @param batch table
_activate_batch = function(batch)
  if batch.settled or batch.waiting_started then return end
  batch.waiting_started = true
  for _, inv in ipairs(batch.invs) do
    if not inv.settled then
      inv.waiting_started = true
      event_bus.emit(events.ASK_USER_WAITING, { agent_id = inv.agent_id })
      -- 真正开始等待用户前暂停计时器：等待时间不累计活跃耗时、不消耗超时预算。
      if inv.timer and inv.timer.pause then pcall(inv.timer.pause, inv.timer) end
    end
  end
  _present_batch(batch)
end

--- 构造批次 config 并交给 UI；未注册 UI 时回退逐个询问
--- @param batch table
_present_batch = function(batch)
  local ui = ui_hooks.get(UI_HOOK)
  if not ui or not ui.show then
    _fallback_batch(batch)
    return
  end
  local questions = {}
  for i, inv in ipairs(batch.invs) do
    questions[i] = {
      question = inv.question,
      options = inv.options,
      multi_select = inv.multi_select,
      answered = inv.answered == true,
      answer = inv.answer,
    }
  end
  local config = {
    batch_id = batch.token,
    questions = questions,
    active = 1,
    mode = "tab",
    require_confirm = _require_confirm(),
    on_submit = function(answers) _submit_batch(batch, answers) end,
    on_cancel = function(reason) _cancel_batch(batch, reason) end,
  }
  local ok, err = pcall(ui.show, config)
  if not ok then
    for _, inv in ipairs(batch.invs) do
      _settle_inv(inv, false, { kind = "ui", message = "提问界面打开失败: " .. tostring(err) })
    end
    _settle_batch(batch, true)
  end
end

--- 提交批次：逐项回传该题答案并结算
--- @param batch table
--- @param answers table 数组，answers[i] 为第 i 题答案（字符串或 label 数组）
_submit_batch = function(batch, answers)
  if batch.settled then return end
  for i, inv in ipairs(batch.invs) do
    local ans = answers and answers[i]
    if type(ans) == "table" then ans = table.concat(ans, ", ") end
    if ans == nil or ans == "" then
      _settle_inv(inv, false, { kind = "cancelled", message = "用户未作答（已跳过提问）" })
    else
      _settle_inv(inv, true, ("用户回答: %s"):format(tostring(ans)))
    end
  end
  _settle_batch(batch, true)
end

--- 取消整批（用户主动取消）
--- @param batch table
--- @param reason string|nil
_cancel_batch = function(batch, reason)
  if batch.settled then return end
  for _, inv in ipairs(batch.invs) do
    _settle_inv(inv, false, { kind = "cancelled", message = "用户取消了提问: " .. tostring(reason or "取消") })
  end
  _settle_batch(batch, true)
end

--- 中止整批（Agent 中止信号）：关闭 UI 并逐项报错，不再展示下一批
--- @param batch table
--- @param reason string|nil
local function _abort_batch(batch, reason)
  if batch.settled then return end
  if batch.waiting_started then
    local ui = ui_hooks.get(UI_HOOK)
    if ui and ui.hide then pcall(ui.hide) end
  end
  for _, inv in ipairs(batch.invs) do
    _settle_inv(inv, false, { kind = "aborted", message = "提问被取消（" .. tostring(reason or "aborted") .. "）" })
  end
  _settle_batch(batch, false)
end

--- 无 UI 回退：按题顺序逐个 vim.ui.input 询问（多题不失败）
--- @param batch table
_fallback_batch = function(batch)
  local answers = {}
  local i = 0
  local function step()
    i = i + 1
    local inv = batch.invs[i]
    if not inv then
      _submit_batch(batch, answers)
      return
    end
    if inv.settled then
      step()
      return
    end
    local ok, err = pcall(vim.ui.input, { prompt = inv.question .. " " }, function(ans)
      if ans ~= nil and ans ~= "" then answers[i] = ans end
      step()
    end)
    if not ok then
      for _, v in ipairs(batch.invs) do
        _settle_inv(v, false, {
          kind = "ui",
          message = "无法向用户提问（未注册提问 UI 且 vim.ui.input 不可用）: " .. tostring(err),
        })
      end
      _settle_batch(batch, true)
    end
  end
  step()
end

--- 登记一个 invocation 到其同轮批次（新建批次时启动去抖）
--- @param inv table
--- @param token string
local function _enqueue_inv(inv, token)
  local batch = batches[token]
  if not batch or batch.settled then
    batch = { token = token, invs = {}, settled = false, waiting_started = false, queued = false }
    batches[token] = batch
    batch_order[#batch_order + 1] = token
    local ms = _debounce_ms()
    local timer = vim.uv.new_timer()
    batch.debounce = timer
    timer:start(ms, 0, vim.schedule_wrap(function()
      if batch.debounce then
        pcall(batch.debounce.stop, batch.debounce)
        pcall(batch.debounce.close, batch.debounce)
        batch.debounce = nil
      end
      if batch.settled then return end
      _enqueue_batch(batch)
    end))
  end
  batch.invs[#batch.invs + 1] = inv
  inv.batch = batch
  -- 已展示后到达的同 token 迟到调用：追加 tab 并重渲染（保留 UI 侧已作答状态）
  if batch.waiting_started then
    _present_batch(batch)
  end
end

-- ========== 工具定义 ==========

local ask_user_tools = {}

ask_user_tools.ask_user = helpers.define_tool(
  "ask_user",
  "向用户提问并等待回答（澄清需求/确认意图/缺关键信息时）。question 必填；options 可选（供快速选择）。"
    .. "同一轮的多次提问会合并为一个多 Tab 弹窗统一作答。",
  {
    type = "object",
    properties = {
      question = { type = "string", description = "要向用户提出的问题" },
      multi_select = {
        type = "boolean",
        description = "可选：该题是否允许多选（默认 false）。为 true 时用户可勾选多个选项，答案以 \", \" 连接各选中 label。",
      },
      options = {
        type = "array",
        description = "可选：供用户快速选择的选项。每个选项可以是字符串，或对象 { label（选项简介，简短标签）, description（选项描述，可选，更详细说明） }。用户可直接选序号或输入自由回答。",
        items = {
          oneOf = {
            { type = "string", description = "纯字符串选项，该字符串即选项简介" },
            {
              type = "object",
              description = "带简介与描述的选项",
              properties = {
                label = { type = "string", description = "选项简介（简短标签，展示给用户并作为选中的答案）" },
                description = { type = "string", description = "选项描述（可选，更详细说明该选项的意图/影响）" },
              },
              required = { "label" },
            },
          },
        },
      },
    },
    required = { "question" },
  },
  function(args, on_success, on_error, ctx)
    local question = type(args.question) == "string" and args.question:gsub("%s+$", "") or ""
    if question == "" then
      on_error("ask_user 缺少必填参数 question")
      return
    end
    local options = {}
    if type(args.options) == "table" then
      for _, o in ipairs(args.options) do
        if type(o) == "string" then
          if o ~= "" then options[#options + 1] = { label = o, description = "" } end
        elseif type(o) == "table" then
          local label = type(o.label) == "string" and o.label:gsub("%s+$", "") or ""
          if label == "" and type(o.name) == "string" then label = o.name:gsub("%s+$", "") end
          if label ~= "" then
            local description = type(o.description) == "string" and o.description or ""
            if description == "" and type(o.desc) == "string" then description = o.desc end
            options[#options + 1] = { label = label, description = description }
          end
        end
      end
    end

    local agent = ctx and ctx.agent
    local inv = {
      question = question,
      options = options,
      multi_select = args.multi_select == true,
      agent_id = agent and agent.id,
      on_success = on_success,
      on_error = on_error,
      timer = ctx and ctx.timer,
      settled = false,
      waiting_started = false,
      answered = false,
      answer = nil,
      unsub = nil,
    }

    -- Agent 中止时终止整批（关闭 UI + 逐项拒绝）；同一 signal 的首个中止即收敛。
    local signal = ctx and ctx.signal
    if signal and signal.subscribe then
      inv.unsub = signal:subscribe(function(reason)
        _abort_batch(inv.batch, reason)
      end)
    end

    -- 同轮聚合：同一 token 的调用并入同一批次（去抖窗口内），跨轮分别成批串行展示。
    _enqueue_inv(inv, _token(ctx))
  end,
  { category = "agent", approval = { auto_allow = true }, timeout = 300000 }
)

-- ========== 公开 API ==========

--- 注册提问 UI 实现（经 kernel.ui_hooks；tools 不直接依赖 ui）
--- @param impl table { show(config), hide() }
---   show(config): config = {
---     batch_id = string,                                  -- 同轮聚合令牌（重渲染时保持 UI 状态）
---     questions = { { question, options, multi_select, answered, answer } },
---     active = number,                                    -- 初始激活 tab（1-based）
---     mode = "tab"|"summary",                             -- 初始展示页
---     require_confirm = boolean,                          -- 是否要求汇总页二次确认
---     on_submit = function(answers) end,                  -- answers[i] = 第 i 题最终答案字符串
---     on_cancel = function(reason) end,
---   }
function M.set_ui(impl)
  ui_hooks.set(UI_HOOK, impl)
end

--- 获取当前提问 UI（测试用）
--- @return table|nil
function M.get_ui()
  return ui_hooks.get(UI_HOOK)
end

--- 立即触发所有去抖中的批次（测试用，避免等待真实去抖窗口）
function M._flush()
  local list = {}
  for _, token in ipairs(batch_order) do
    local batch = batches[token]
    if batch and not batch.settled then list[#list + 1] = batch end
  end
  for _, batch in ipairs(list) do
    if batch.debounce then
      pcall(batch.debounce.stop, batch.debounce)
      pcall(batch.debounce.close, batch.debounce)
      batch.debounce = nil
    end
    _enqueue_batch(batch)
  end
  _drain()
end

--- 重置（测试用）
function M.reset()
  for _, batch in pairs(batches) do
    if batch.debounce then
      pcall(batch.debounce.stop, batch.debounce)
      pcall(batch.debounce.close, batch.debounce)
      batch.debounce = nil
    end
    for _, inv in ipairs(batch.invs) do
      if inv.unsub then
        pcall(inv.unsub)
        inv.unsub = nil
      end
    end
  end
  batches = {}
  batch_order = {}
  pending = {}
  current = nil
  ui_hooks.clear(UI_HOOK)
end

--- 获取工具列表
--- @return table 数组
function M.get_tools()
  local out = {}
  for _, tool in pairs(ask_user_tools) do
    out[#out + 1] = tool
  end
  return out
end

return M
