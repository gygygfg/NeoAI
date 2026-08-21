--- 计划模式
--- @module NeoAI.tools.builtin.plan_mode
--- 对齐 deepseek-harness plan：计划模式作为 per-agent 状态（logged），
--- 激活时：注入 plan-policy 系统提示段 + 屏蔽所有修改类工具 + 提供 present_plan 收尾。
--- 状态持久化在 session.metadata.plan（chat_service 同步），恢复会话时还原。

local async = require("NeoAI.utils.async")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")
local helpers = require("NeoAI.tools.builtin.tool_helpers")
local config_store = require("NeoAI.kernel.config_store")

local M = {}

-- ========== 私有常量 ==========

--- 计划模式策略段（注入系统提示，order=100 工具指引区）
local PLAN_POLICY_TEXT = table.concat({
  "## 计划模式（PLAN MODE）",
  "当前处于计划模式：只允许分析、调研与制定计划，禁止执行任何修改性操作",
  "（编辑文件、删除、创建目录、执行写命令、重命名/格式化、删除节点、git 回滚等）。",
  "你的输出应是清晰、可评审的计划，而不是直接改动。",
  "完成后调用 present_plan 展示计划并请求用户确认。",
}, "\n")

--- 修改类工具（计划模式下被屏蔽）
local DEFAULT_MUTATING_TOOLS = {
  "edit_file", "delete_file", "create_directory", "ensure_dir", "delete_node",
  "lsp_rename", "lsp_format", "git_rollback", "confirm_file_change",
}

-- ========== 私有函数 ==========

--- 读取配置
--- @return table
local function _cfg()
  return config_store.get("tools.plan_mode") or {}
end

--- 注册/注销 plan-policy 提示段
--- @param agent table
--- @param active boolean
local function _apply_section(agent, active)
  if not agent then return end
  if active then
    if agent._plan_section then return end
    local prefix = require("NeoAI.core.agent.prefix")
    agent._plan_section = prefix.register_agent_section(agent, "deployment:plan_policy", 100, PLAN_POLICY_TEXT)
  else
    if agent._plan_section then
      pcall(agent._plan_section)
      agent._plan_section = nil
    end
  end
end

-- ========== 公开 API ==========

--- 是否处于计划模式
--- @param agent table
--- @return boolean
function M.is_active(agent)
  return agent and agent.plan_mode == true
end

--- 进入计划模式
--- @param agent table
--- @return boolean 是否成功
function M.enter(agent)
  if not agent then return false end
  agent.plan_mode = true
  _apply_section(agent, true)
  event_bus.emit(events.PLAN_MODE_CHANGED, { agent_id = agent.id, active = true })
  return true
end

--- 退出计划模式
--- @param agent table
--- @return boolean
function M.exit(agent)
  if not agent then return false end
  agent.plan_mode = false
  _apply_section(agent, false)
  event_bus.emit(events.PLAN_MODE_CHANGED, { agent_id = agent.id, active = false })
  return true
end

--- 切换计划模式
--- @param agent table
--- @return boolean 切换后的状态
function M.toggle(agent)
  if M.is_active(agent) then
    M.exit(agent)
    return false
  end
  M.enter(agent)
  return true
end

--- 恢复计划模式状态（加载会话时）
--- @param agent table
--- @param state table|nil { active?, plan? }
function M.restore(agent, state)
  if not agent or not state then return end
  agent.plan = state.plan
  if state.active then
    agent.plan_mode = true
    _apply_section(agent, true)
  end
end

--- 指定工具是否属于修改类（计划模式下被屏蔽）
--- @param tool_name string
--- @return boolean
function M.is_mutating(tool_name)
  local cfg = _cfg()
  local list = cfg.mutating_tools or DEFAULT_MUTATING_TOOLS
  for _, t in ipairs(list) do
    if t == tool_name then return true end
  end
  return false
end

--- 校验工具调用是否被计划模式阻止
--- @param agent table
--- @param tool_name string
--- @return boolean allowed, string|nil reason
function M.check_tool(agent, tool_name)
  if not M.is_active(agent) then return true end
  if M.is_mutating(tool_name) then
    return false, "[计划模式] 工具 '" .. tool_name .. "' 为修改操作，计划模式下禁止执行。请先调用 present_plan 提交计划并退出计划模式。"
  end
  return true
end

--- 清理 agent 级状态（销毁时）
--- @param agent table
function M.cleanup(agent)
  if agent and agent._plan_section then
    pcall(agent._plan_section)
    agent._plan_section = nil
  end
end

-- ========== 工具定义 ==========

local plan_mode_tools = {}

plan_mode_tools.enter_plan_mode = helpers.define_tool(
  "enter_plan_mode",
  "进入计划模式：停止一切修改性操作，只分析、调研并制定计划。多步骤任务应先调用本工具。",
  {
    type = "object",
    properties = {},
    required = {},
  },
  function(args, on_success, on_error, ctx)
    local agent = ctx and ctx.agent
    if not agent then
      on_error("缺少 agent 上下文")
      return
    end
    M.enter(agent)
    on_success("已进入计划模式。请分析任务并制定计划，完成后再调用 present_plan 提交计划。")
  end,
  { category = "agent", approval = { auto_allow = true } }
)

plan_mode_tools.set_plan = helpers.define_tool(
  "set_plan",
  "记录/更新当前计划内容（仅文本，不触发任何修改）。plan 必填。",
  {
    type = "object",
    properties = {
      plan = { type = "string", description = "计划内容（Markdown）" },
    },
    required = { "plan" },
  },
  function(args, on_success, on_error, ctx)
    local agent = ctx and ctx.agent
    if not agent then
      on_error("缺少 agent 上下文")
      return
    end
    agent.plan = args.plan or ""
    event_bus.emit(events.PLAN_MODE_CHANGED, { agent_id = agent.id, active = M.is_active(agent) })
    on_success("计划已记录")
  end,
  { category = "agent", approval = { auto_allow = true } }
)

plan_mode_tools.present_plan = helpers.define_tool(
  "present_plan",
  "提交计划并退出计划模式。plan 为计划内容；approved=true 表示用户已确认可开始执行，approved=false 表示用户要求继续修改计划（保持计划模式）。",
  {
    type = "object",
    properties = {
      plan = { type = "string", description = "最终计划内容（Markdown）" },
      approved = { type = "boolean", description = "是否已获用户批准" },
    },
    required = {},
  },
  function(args, on_success, on_error, ctx)
    local agent = ctx and ctx.agent
    if not agent then
      on_error("缺少 agent 上下文")
      return
    end
    if args.plan then agent.plan = args.plan end
    if args.approved then
      M.exit(agent)
      on_success(("计划已获批准，已退出计划模式，可以开始执行。\n\n%s"):format(agent.plan or ""))
    else
      on_success(("计划已提交待审（仍处于计划模式）。\n\n%s"):format(agent.plan or ""))
    end
  end,
  { category = "agent", approval = { auto_allow = true } }
)

plan_mode_tools.exit_plan_mode = helpers.define_tool(
  "exit_plan_mode",
  "直接退出计划模式，不提交计划。",
  {
    type = "object",
    properties = {},
    required = {},
  },
  function(args, on_success, on_error, ctx)
    local agent = ctx and ctx.agent
    if not agent then
      on_error("缺少 agent 上下文")
      return
    end
    M.exit(agent)
    on_success("已退出计划模式")
  end,
  { category = "agent", approval = { auto_allow = true } }
)

-- ========== 测试辅助 ==========

--- 重置（测试用）
function M.reset()
  -- 无模块级状态；状态挂在 agent 上
end

--- 获取工具列表
--- @return table 数组
function M.get_tools()
  local out = {}
  for _, tool in pairs(plan_mode_tools) do
    out[#out + 1] = tool
  end
  return out
end

return M