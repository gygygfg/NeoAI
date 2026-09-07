--- 工具服务
--- @module NeoAI.services.tool_service
--- 审批 + 调度 + 执行。Agent 的工具循环通过此服务执行工具。
--- - execute(agent, name, args, tool_call_id, opts)：执行工具
--- - approve_and_execute(...)：审批通过后继续执行
--- - 子 Agent 边界审核 + 工具调用计数

local async = require("NeoAI.utils.async")
local executor = require("NeoAI.tools.executor")
local registry = require("NeoAI.tools.registry")
local config_store = require("NeoAI.kernel.config_store")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")

local M = {}

-- ========== 私有状态 ==========

local state = {
  approval_queue = {}, -- { tool_name, args, ctx, continue_fn, d } 等待审批的条目
  approval_showing = false, -- 串行审批槽位：true 表示当前正有一个弹窗在展示
  current_approval = nil, -- 当前正在审批的条目（已从队列弹出）
  allow_all = {}, -- tool_name -> true
  auto_mode = false, -- AUTO 模式：自动允许所有工具调用（运行期开关）
}

-- ========== 私有函数 ==========

--- 当前生效的审批模式：AUTO 模式优先于配置
--- @return string "prompt" | "auto_allow" | "strict"
local function _current_mode()
  if state.auto_mode then return "auto_allow" end
  return config_store.get("tools.approval.mode") or "prompt"
end

-- ========== 私有函数 ==========

--- 子 Agent 边界审核（通过 plan 模块）
--- @param ctx table
--- @param tool_name string
--- @return boolean, string|nil
local function _review_sub_agent(ctx, tool_name)
  if not ctx.is_sub_agent then return true end
  local sub_agent_id = ctx.sub_agent_id
  if not sub_agent_id then return true end
  local plan = require("NeoAI.tools.builtin.plan")
  local ok, reason = plan.review_tool_call(sub_agent_id, tool_name)
  if ok then
    plan.track_tool_call(sub_agent_id)
  end
  return ok, reason
end

--- 构建审批 UI 内容
--- @param tool_name string
--- @param args table
--- @return string
local function _approval_text(tool_name, args)
  local tool = registry.get(tool_name)
  local desc = tool and tool.description or ""
  local json = require("NeoAI.utils.json")
  local args_str = json.encode(args)
  return string.format(
    "工具: %s\n描述: %s\n参数: %s",
    tool_name, desc, args_str
  )
end

-- ========== 审批 UI（由 ui/components/tool_approval 注入） ==========

local approval_ui = nil

--- 注册审批 UI 实现
--- @param impl table { show(config), hide(), on_select(cb), on_cancel(cb) }
function M.set_approval_ui(impl)
  approval_ui = impl
end

--- 展示审批窗口
--- @param tool_name string
--- @param args table
--- @param decision_cb function(true=allow, false=deny)
--- @param ctx table
local function _show_approval(tool_name, args, decision_cb, ctx)
  local text = _approval_text(tool_name, args)
  if approval_ui and approval_ui.show then
    approval_ui.show({
      text = text,
      tool_name = tool_name,
      args = args,
      on_confirm = function() decision_cb(true) end,
      on_cancel = function(reason) decision_cb(false, reason) end,
      on_confirm_all = function()
        state.allow_all[tool_name] = true
        decision_cb(true)
      end,
    })
  else
    -- 无 UI（headless/测试）：默认允许
    vim.notify("[NeoAI] 工具审批: " .. text, vim.log.levels.WARN)
    decision_cb(true)
  end
end

--- 串行审批队列：一次只展示一个审批弹窗（单槽位）。
--- 工具执行本身并行，但审批必须串行：并发弹窗会互相覆盖，
--- 前一个的 decision_cb 永不触发 → Deferred 永不 settle → 工具循环挂起。
local function _drain_approval_queue()
  if state.approval_showing then return end
  local item = table.remove(state.approval_queue, 1)
  if not item then return end
  state.approval_showing = true
  state.current_approval = item

  local function _settle()
    state.approval_showing = false
    state.current_approval = nil
  end

  -- 弹窗展示（如浮窗创建）失败时不能阻塞工具循环：释放串行槽位并拒绝该条目，
  -- 该工具以错误结果结束、循环继续执行其余工具。否则 approval_showing 残留 true，
  -- 后续审批只入队不弹窗、对应 Deferred 永不 settle，工具循环永久卡死（"完全无响应"）。
  -- 注意：必须是 pcall 包裹，异常不能向上传播中断 _execute_single 的循环。
  local show_ok, show_err = pcall(_show_approval, item.tool_name, item.args, function(allowed, reason)
    local d = item.d
    item.d = nil -- 已决策：审批超时不再作用于本条目（避免杀掉已批准的长耗时执行）
    if d and d:is_pending() then
      if allowed then
        event_bus.emit(events.TOOL_APPROVED, { tool_name = item.tool_name })
        item.continue_fn():then_(function(r) d:resolve(r) end, function(e) d:reject(e) end)
      else
        event_bus.emit(events.TOOL_APPROVAL_CANCELLED, { tool_name = item.tool_name, reason = reason })
        d:reject({ kind = "approval", message = reason or ("用户拒绝了工具调用: " .. item.tool_name) })
      end
    end
    _settle()
    -- 延后到下一个事件循环再弹下一个：审批 UI 的按键回调（如 tool_approval）在
    -- on_confirm() 返回后还会调用 _close()；若这里同步打开下一个弹窗，会被那个
    -- _close() 立即关掉，导致下一个工具的 Deferred 永不 settle，工具循环卡在第一轮。
    vim.schedule(_drain_approval_queue)
  end, item.ctx)
  if not show_ok then
    local d = item.d
    item.d = nil
    if d and d:is_pending() then
      d:reject({ kind = "approval", message = "审批弹窗展示失败: " .. tostring(show_err) })
    end
    _settle()
    vim.schedule(_drain_approval_queue)
    return
  end

  -- 审批超时兜底：弹窗被覆盖/丢失或用户长时间不响应时，拒绝而不是永久挂起，
  -- 否则工具循环会无限等待（表现为"卡住"）。超时后由 _execute_single 转成工具错误结果。
  -- 条目一旦决策（item.d = nil），超时即失效，不干扰已批准工具的执行。
  local timeout_ms = config_store.get("tools.approval.timeout_ms")
  if timeout_ms and timeout_ms > 0 then
    vim.defer_fn(function()
      if not item.d then return end -- 已决策，跳过
      if approval_ui and approval_ui.hide then
        pcall(approval_ui.hide)
      end
      item.d:reject({ kind = "approval", message = "工具审批超时: " .. item.tool_name })
      item.d = nil
      _settle()
      vim.schedule(_drain_approval_queue)
    end, timeout_ms)
  end
end

--- 批准单个待审批条目（绕过审批直接执行工具）
--- @param item table { d, continue_fn }
local function _approve_item(item)
  local d = item.d
  item.d = nil -- 已决策：审批超时不再作用于本条目
  if d and d:is_pending() then
    item.continue_fn():then_(function(r) d:resolve(r) end, function(e) d:reject(e) end)
  end
end

--- AUTO 模式开启时，自动批准所有待审批/排队的工具
local function _approve_all_pending()
  for _, item in ipairs(state.approval_queue) do
    _approve_item(item)
  end
  state.approval_queue = {}
  if state.current_approval then
    if approval_ui and approval_ui.hide then
      pcall(approval_ui.hide)
    end
    _approve_item(state.current_approval)
    state.current_approval = nil
    state.approval_showing = false
    vim.schedule(_drain_approval_queue)
  end
end

--- 审批 + 执行
--- @param tool_name string
--- @param args table
--- @param ctx table
--- @param continue_fn function() 返回 Deferred（审批通过后执行）
--- @return Deferred
function M.approve_and_execute(tool_name, args, ctx, continue_fn)
  local d = async.Deferred.new()
  local mode = _current_mode()

  -- auto_allow 模式直接执行
  if mode == "auto_allow" then
    return continue_fn()
  end

  -- 该工具已 allow_all
  if state.allow_all[tool_name] then
    return continue_fn()
  end

  event_bus.emit(events.TOOL_APPROVAL_REQUESTED, { tool_name = tool_name, args = args })

  -- 入队等待串行审批。工具执行本身并行（tool_loop 并发发起），这里只串行化
  -- "弹窗确认"这一环节：单槽位弹窗一次只展示一个，其余排队，互不覆盖。
  state.approval_queue[#state.approval_queue + 1] = {
    tool_name = tool_name,
    args = args,
    ctx = ctx,
    continue_fn = continue_fn,
    d = d,
  }
  _drain_approval_queue()

  return d
end

-- ========== 公开 API ==========

--- 执行工具（供 Agent tool_loop 调用）
--- @param agent table Agent
--- @param tool_name string
--- @param args table
--- @param tool_call_id string|nil
--- @param opts table { is_sub_agent?, signal?, sub_agent_id? }
--- @return Deferred resolve(结果), reject(错误)
function M.execute(agent, tool_name, args, tool_call_id, opts)
  opts = opts or {}
  -- 子 Agent 边界审核
  local ok, reason = _review_sub_agent(opts, tool_name)
  if not ok then
    return async.reject({ kind = "boundary", message = "[调度 agent 驳回] 工具 '" .. tool_name .. "' 的调用被拒绝。原因: " .. tostring(reason) })
  end

  -- 计划模式门禁：修改类工具在计划模式下直接驳回
  local plan_mode = require("NeoAI.tools.builtin.plan_mode")
  local pallow, preason = plan_mode.check_tool(agent, tool_name)
  if not pallow then
    return async.reject({ kind = "plan_mode", message = preason })
  end

  local ctx = {
    agent = agent,
    tool_call_id = tool_call_id,
    signal = opts.signal,
    is_sub_agent = opts.is_sub_agent,
    sub_agent_id = opts.sub_agent_id,
    tool_service = M,
    approval_mode = _current_mode(),
    timer = opts.timer, -- 可暂停计时器（tool_loop 注入，用于展示活跃耗时并排除等待时间）
  }

  return executor.execute(tool_name, args, ctx)
end

--- 拒绝队列中所有待审批工具（窗口关闭/取消）。
--- 必须 reject 挂起的 Deferred 并释放串行槽位，否则工具循环会永久挂起。
function M.clear_approval()
  if state.current_approval and state.current_approval.d and state.current_approval.d:is_pending() then
    state.current_approval.d:reject({ kind = "approval", message = "审批已取消（窗口关闭）" })
    state.current_approval.d = nil
  end
  for _, item in ipairs(state.approval_queue) do
    if item.d and item.d:is_pending() then
      item.d:reject({ kind = "approval", message = "审批已取消（窗口关闭）" })
    end
  end
  state.approval_queue = {}
  state.current_approval = nil
  state.approval_showing = false
  if approval_ui and approval_ui.hide then
    pcall(approval_ui.hide)
  end
end

--- 是否有待审批
--- @return boolean
function M.has_pending_approval()
  return #state.approval_queue > 0 or state.approval_showing
end

--- 设置某个工具为始终允许（运行期）
--- @param tool_name string
--- @param allow boolean
function M.set_allow_all(tool_name, allow)
  if allow then
    state.allow_all[tool_name] = true
  else
    state.allow_all[tool_name] = nil
  end
end

--- 是否处于 AUTO 模式
--- @return boolean
function M.is_auto_mode()
  return state.auto_mode
end

--- 设置 AUTO 模式（自动允许所有工具调用）。开启时自动批准当前待审批/排队的工具。
--- @param enable boolean
--- @return boolean 切换后的状态
function M.set_auto_mode(enable)
  local active = not not enable
  if active == state.auto_mode then return state.auto_mode end
  state.auto_mode = active
  if active then
    _approve_all_pending()
  end
  event_bus.emit(events.AUTO_MODE_CHANGED, { active = state.auto_mode })
  return state.auto_mode
end

--- 切换 AUTO 模式
--- @return boolean 切换后的状态
function M.toggle_auto_mode()
  return M.set_auto_mode(not state.auto_mode)
end

--- 重置（测试用）
function M.reset()
  state.approval_queue = {}
  state.current_approval = nil
  state.approval_showing = false
  state.allow_all = {}
  state.auto_mode = false
end

return M
