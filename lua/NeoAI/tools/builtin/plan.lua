--- 子 Agent 计划与边界审核
--- @module NeoAI.tools.builtin.plan
--- create_sub_agent / get_sub_agent_status / cancel_sub_agent。
--- 子 Agent 独立沙箱，零继承；边界审核由 tool_service 配合。

local async = require("NeoAI.utils.async")
local helpers = require("NeoAI.tools.builtin.tool_helpers")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")
local stringx = require("NeoAI.utils.stringx")

local M = {}

-- ========== 私有状态 ==========

local state = {
  sub_agents = {}, -- id -> { task, boundaries, status, started_at, tool_calls }
}

-- ========== 私有函数 ==========

local function _new_id()
  local t = os.time()
  local n = math.random(1, 2 ^ 31)
  return string.format("sub_%x_%x", t, n)
end

-- ========== 工具定义 ==========

local plan_tools = {}

plan_tools.create_sub_agent = helpers.define_tool(
  "create_sub_agent",
  "创建子 Agent 执行独立子任务。task 必填；mode 可选 'background'（默认，立即返回）或 'foreground'（等待子 Agent 完成后返回完整结果）；boundaries 可选约束（allowed_tools/allowed_directories/max_tool_calls）。",
  {
    type = "object",
    properties = {
      task = { type = "string", description = "子任务描述" },
      model = { type = "string", description = "指定模型（可选）" },
      mode = { type = "string", enum = { "background", "foreground" }, description = "执行模式（默认 background）" },
      boundaries = {
        type = "object",
        description = "边界约束",
        properties = {
          description = { type = "string" },
          allowed_tools = { type = "array", items = { type = "string" } },
          allowed_directories = { type = "array", items = { type = "string" } },
          allowed_commands = { type = "array", items = { type = "string" } },
          max_tool_calls = { type = "integer" },
          max_iterations = { type = "integer" },
        },
      },
      context = { type = "object", description = "额外上下文" },
    },
    required = { "task" },
  },
  function(args, on_success, on_error, ctx)
    local parent_agent = ctx and ctx.agent
    local runtime = require("NeoAI.core.agent.runtime")

    local sub_id = _new_id()
    local sub_agent = runtime.spawn(parent_agent, {
      task = args.task,
      model = args.model,
      scenario = "agent",
    })

    local boundaries = args.boundaries or {}
    state.sub_agents[sub_id] = {
      id = sub_id,
      agent_id = sub_agent.id,
      task = args.task,
      boundaries = boundaries,
      status = "running",
      started_at = os.time(),
      tool_calls = 0,
      context = args.context or {},
    }

    event_bus.emit(events.SUB_AGENT_CREATED, { sub_agent_id = sub_id, task = args.task })

    -- 启动子 Agent 执行
    local tool_service = require("NeoAI.services.tool_service")
    local tools_subset = M._allowed_tools(boundaries.allowed_tools)
    sub_agent.tools = tools_subset

    local function _finish(result)
      local entry = state.sub_agents[sub_id]
      if entry then
        entry.status = "completed"
        entry.result = result
        entry.result_text = (result and result.content) or ""
        event_bus.emit(events.SUB_AGENT_COMPLETED, { sub_agent_id = sub_id })
        event_bus.emit(events.SUB_AGENT_RESULT_READY, { sub_agent_id = sub_id })
      end
    end
    local function _fail(err)
      local entry = state.sub_agents[sub_id]
      if entry then
        entry.status = "error"
        entry.error = err
        entry.result_text = tostring(err and err.message or err)
        event_bus.emit(events.SUB_AGENT_ERROR, { sub_agent_id = sub_id, error = err })
        event_bus.emit(events.SUB_AGENT_RESULT_READY, { sub_agent_id = sub_id })
      end
    end
    runtime.run(sub_agent, args.task):then_(_finish, _fail)

    if args.mode == "foreground" then
      -- 前台模式：等待子 Agent 完成后返回完整结果
      M.wait(sub_id):then_(function(entry)
        on_success(("【子 agent 执行完成】\n子 agent ID: %s\n状态: %s\n\n%s"):format(sub_id, entry.status, entry.result_text or ""))
      end, function(err)
        on_error("子 Agent 执行失败: " .. tostring(err and err.message or err))
      end)
      return
    end

    on_success(("子 Agent 已创建: %s\n任务: %s"):format(sub_id, args.task))
  end,
  { category = "agent", approval = { auto_allow = false }, timeout = -1 }
)

plan_tools.get_sub_agent_status = helpers.define_tool(
  "get_sub_agent_status",
  "查询子 Agent 状态。sub_agent_id 必填。返回状态、任务与执行结果。",
  {
    type = "object",
    properties = { sub_agent_id = { type = "string" } },
    required = { "sub_agent_id" },
  },
  function(args, on_success)
    local entry = state.sub_agents[args.sub_agent_id]
    if not entry then
      on_success("子 Agent 不存在: " .. tostring(args.sub_agent_id))
      return
    end
    local lines = {
      ("状态: %s"):format(entry.status),
      ("任务: %s"):format(entry.task),
      ("工具调用: %d"):format(entry.tool_calls or 0),
    }
    if entry.result_text and entry.result_text ~= "" then
      lines[#lines + 1] = ("结果:\n%s"):format(stringx.truncate(entry.result_text, 2000))
    end
    on_success(table.concat(lines, "\n"))
  end,
  { category = "agent" }
)

plan_tools.wait_sub_agent = helpers.define_tool(
  "wait_sub_agent",
  "等待子 Agent 完成并返回完整结果。sub_agent_id 必填。若已完成则立即返回，否则阻塞直到完成/失败。",
  {
    type = "object",
    properties = { sub_agent_id = { type = "string" } },
    required = { "sub_agent_id" },
  },
  function(args, on_success, on_error)
    M.wait(args.sub_agent_id):then_(function(entry)
      on_success(("【子 agent 执行完成】\n子 agent ID: %s\n状态: %s\n\n%s"):format(
        entry.id, entry.status, entry.result_text or ""))
    end, function(err)
      on_error(tostring(err and err.message or err))
    end)
  end,
  { category = "agent", timeout = -1 }
)

plan_tools.cancel_sub_agent = helpers.define_tool(
  "cancel_sub_agent",
  "取消子 Agent。sub_agent_id 必填。",
  {
    type = "object",
    properties = { sub_agent_id = { type = "string" } },
    required = { "sub_agent_id" },
  },
  function(args, on_success, on_error)
    local entry = state.sub_agents[args.sub_agent_id]
    if not entry then
      on_error("子 Agent 不存在: " .. tostring(args.sub_agent_id))
      return
    end
    local runtime = require("NeoAI.core.agent.runtime")
    local sub = runtime.get(entry.agent_id)
    if sub then
      runtime.abort(sub, "user_cancelled")
    end
    entry.status = "cancelled"
    event_bus.emit(events.SUB_AGENT_UPDATED, { sub_agent_id = args.sub_agent_id, status = "cancelled" })
    on_success("已取消子 Agent: " .. args.sub_agent_id)
  end,
  { category = "agent" }
)

-- ========== 内部接口（供 tool_service 调用） ==========

--- 根据 allowed_tools 构建工具子集
--- @param allowed_tools table|nil
--- @return table name -> tool
function M._allowed_tools(allowed_tools)
  local registry = require("NeoAI.tools.registry")
  local out = {}
  if allowed_tools and #allowed_tools > 0 then
    for _, name in ipairs(allowed_tools) do
      local tool = registry.get(name)
      if tool then out[name] = tool end
    end
  else
    -- 默认子 Agent 只给只读工具
    local default_allow = { "read_file", "list_files", "search_files", "file_exists", "log_message", "get_log_levels", "git_status", "git_diff", "git_log", "lsp_diagnostics", "parse_file", "get_node_code" }
    for _, name in ipairs(default_allow) do
      local tool = registry.get(name)
      if tool then out[name] = tool end
    end
  end
  return out
end

--- 记录子 Agent 工具调用数（供 tool_service）
--- @param sub_agent_id string
function M.track_tool_call(sub_agent_id)
  local entry = state.sub_agents[sub_agent_id]
  if entry then
    entry.tool_calls = (entry.tool_calls or 0) + 1
  end
end

--- 子 Agent 是否达到工具调用上限
--- @param sub_agent_id string
--- @return boolean
function M.maxed_tool_calls(sub_agent_id)
  local entry = state.sub_agents[sub_agent_id]
  if not entry then return false end
  local max = entry.boundaries and entry.boundaries.max_tool_calls
  if not max then return false end
  return (entry.tool_calls or 0) >= max
end

--- 边界审核：工具是否被允许
--- @param sub_agent_id string
--- @param tool_name string
--- @return boolean, string|nil
function M.review_tool_call(sub_agent_id, tool_name)
  local entry = state.sub_agents[sub_agent_id]
  if not entry then return true end
  local boundaries = entry.boundaries or {}
  local allowed = boundaries.allowed_tools
  if allowed and #allowed > 0 then
    local hit = false
    for _, t in ipairs(allowed) do
      if t == tool_name then hit = true break end
    end
    if not hit then
      return false, "[调度 agent 驳回] 工具 '" .. tool_name .. "' 的调用被拒绝。原因: 工具不在允许列表内"
    end
  end
  if M.maxed_tool_calls(sub_agent_id) then
    return false, "[调度 agent 驳回] 已达到最大工具调用次数"
  end
  return true
end

--- 获取子 Agent 摘要（供主 Agent 回传）
--- @param sub_agent_id string
--- @return string
function M.get_summary(sub_agent_id)
  local entry = state.sub_agents[sub_agent_id]
  if not entry then return "子 Agent 不存在" end
  return string.format("【子 agent 执行完成】\n子 agent ID: %s\n状态: %s\n任务: %s", sub_agent_id, entry.status, entry.task)
end

--- 清理子 Agent 状态
--- @param sub_agent_id string
function M.cleanup_sub_agent(sub_agent_id)
  state.sub_agents[sub_agent_id] = nil
end

--- 等待子 Agent 完成（前台阻塞）
--- @param sub_agent_id string
--- @return Deferred resolve(entry), reject(不存在/取消)
function M.wait(sub_agent_id)
  local d = async.Deferred.new()
  local entry = state.sub_agents[sub_agent_id]
  if not entry then
    d:reject({ message = "子 Agent 不存在: " .. tostring(sub_agent_id) })
    return d
  end
  local status = entry.status
  if status == "completed" or status == "error" or status == "cancelled" then
    vim.schedule(function() d:resolve(entry) end)
    return d
  end

  local unsubs = {}
  local function _settle()
    for _, u in ipairs(unsubs) do
      if u then pcall(u) end
    end
    unsubs = {}
    d:resolve(state.sub_agents[sub_agent_id] or entry)
  end

  unsubs[#unsubs + 1] = event_bus.on(events.SUB_AGENT_COMPLETED, function(data)
    if data and data.sub_agent_id == sub_agent_id then _settle() end
  end)
  unsubs[#unsubs + 1] = event_bus.on(events.SUB_AGENT_ERROR, function(data)
    if data and data.sub_agent_id == sub_agent_id then _settle() end
  end)
  unsubs[#unsubs + 1] = event_bus.on(events.SUB_AGENT_UPDATED, function(data)
    if data and data.sub_agent_id == sub_agent_id and data.status == "cancelled" then _settle() end
  end)
  return d
end

--- 测试辅助：直接构造子 Agent 条目
--- @param sub_agent_id string
--- @param allowed_tools table
function M._allow_tools_for_test(sub_agent_id, allowed_tools)
  state.sub_agents[sub_agent_id] = {
    id = sub_agent_id,
    task = "test",
    boundaries = { allowed_tools = allowed_tools, max_tool_calls = 10 },
    status = "running",
    tool_calls = 0,
  }
end

--- 获取工具列表
--- @return table 数组
function M.get_tools()
  local out = {}
  for _, tool in pairs(plan_tools) do
    out[#out + 1] = tool
  end
  return out
end

--- 重置（测试用）
function M.reset()
  state.sub_agents = {}
end

return M
