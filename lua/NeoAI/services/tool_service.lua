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
  approval_queue = {}, -- { tool_name, args, ctx, continue_fn }
  approval_showing = false,
  allow_all = {}, -- tool_name -> true
}

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

--- 审批 + 执行
--- @param tool_name string
--- @param args table
--- @param ctx table
--- @param continue_fn function() 返回 Deferred（审批通过后执行）
--- @return Deferred
function M.approve_and_execute(tool_name, args, ctx, continue_fn)
  local d = async.Deferred.new()
  local mode = config_store.get("tools.approval.mode") or "prompt"

  -- auto_allow 模式直接执行
  if mode == "auto_allow" then
    return continue_fn()
  end

  -- 该工具已 allow_all
  if state.allow_all[tool_name] then
    return continue_fn()
  end

  event_bus.emit(events.TOOL_APPROVAL_REQUESTED, { tool_name = tool_name, args = args })

  _show_approval(tool_name, args, function(allowed, reason)
    if allowed then
      event_bus.emit(events.TOOL_APPROVED, { tool_name = tool_name })
      continue_fn():then_(function(r) d:resolve(r) end, function(e) d:reject(e) end)
    else
      event_bus.emit(events.TOOL_APPROVAL_CANCELLED, { tool_name = tool_name, reason = reason })
      d:reject({ kind = "approval", message = reason or "用户拒绝了工具调用: " .. tool_name })
    end
  end, ctx)

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

  local ctx = {
    agent = agent,
    tool_call_id = tool_call_id,
    signal = opts.signal,
    is_sub_agent = opts.is_sub_agent,
    sub_agent_id = opts.sub_agent_id,
    tool_service = M,
    approval_mode = config_store.get("tools.approval.mode") or "prompt",
  }

  return executor.execute(tool_name, args, ctx)
end

--- 拒绝队列中所有待审批工具（窗口关闭/取消）
function M.clear_approval()
  state.approval_queue = {}
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

--- 重置（测试用）
function M.reset()
  state.approval_queue = {}
  state.approval_showing = false
  state.allow_all = {}
end

return M
