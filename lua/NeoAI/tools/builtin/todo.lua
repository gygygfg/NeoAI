--- 待办任务工具
--- @module NeoAI.tools.builtin.todo
--- 对齐 deepseek-harness todo/todo_write：整表替换语义，每次调用提交完整清单。
--- 清单按 session 维度存储，并注册 agent 级系统提示段把当前状态注入每次请求
--- （模型无需显式读取即可感知进度，等价于 harness 的 projection）。

local async = require("NeoAI.utils.async")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")
local helpers = require("NeoAI.tools.builtin.tool_helpers")

local M = {}

-- ========== 私有状态 ==========

local state = {
  todos = {}, -- session_id -> { items = { {content, status} }, updated_at }
  sections = {}, -- session_id -> unregister fn
}

-- ========== 私有函数 ==========

--- 会话键：优先用 session_id，子 Agent 无会话时退回 agent id
--- @param agent table
--- @return string
local function _key(agent)
  return (agent and agent.session_id) or (agent and agent.id) or "default"
end

--- 规范化待办项：trim + 去空 + 状态默认值
--- @param raw table 原始项 { content, status? }
--- @return table|nil 规范项
local function _normalize_item(raw)
  if type(raw) ~= "table" then return nil end
  local content = type(raw.content) == "string" and raw.content:gsub("^%s+", ""):gsub("%s+$", "") or ""
  if content == "" then return nil end
  local status = raw.status or "pending"
  if status ~= "pending" and status ~= "in_progress" and status ~= "completed" and status ~= "cancelled" then
    status = "pending"
  end
  return { content = content, status = status }
end

--- 校验并规范化整表
--- @param todos table 原始数组
--- @return table items, string|nil 错误
local function _normalize_list(todos)
  if type(todos) ~= "table" then
    return nil, "todos 必须是数组"
  end
  local items = {}
  local seen = {}
  local in_progress = 0
  for _, raw in ipairs(todos) do
    local item = _normalize_item(raw)
    if item then
      if seen[item.content] then
        return nil, "待办项内容重复: " .. item.content
      end
      seen[item.content] = true
      if item.status == "in_progress" then in_progress = in_progress + 1 end
      items[#items + 1] = item
    end
  end
  if in_progress > 1 then
    return nil, "同一时刻只能有一个 in_progress 状态的待办项"
  end
  return items, nil
end

--- 渲染待办清单（注入系统提示的文本）
--- @param session_id string
--- @return string
local function _render(session_id)
  local e = state.todos[session_id]
  local items = e and e.items or {}
  if #items == 0 then return "" end
  local lines = { "## 当前任务清单（按需用 todo_write 更新）" }
  local STATUS_MARK = {
    pending = "[ ]",
    in_progress = "[▶]",
    completed = "[x]",
    cancelled = "[-]",
  }
  for _, item in ipairs(items) do
    lines[#lines + 1] = string.format("- %s %s", STATUS_MARK[item.status] or "[ ]", item.content)
  end
  return table.concat(lines, "\n")
end

--- 懒注册 agent 级系统提示段（order=100 工具指引区），一次注册长期生效
--- @param agent table
local function _ensure_section(agent)
  local key = _key(agent)
  if state.sections[key] then return end
  local prefix = require("NeoAI.core.agent.prefix")
  local unreg = prefix.register_agent_section(agent, "deployment:todos", 100, function()
    return _render(key)
  end)
  state.sections[key] = unreg
end

-- ========== 工具定义 ==========

local todo_tools = {}

todo_tools.todo_write = helpers.define_tool(
  "todo_write",
  "整表替换当前任务清单。每次调用提交完整清单（不是增量编辑）。todos 为 {content, status} 数组，status ∈ pending/in_progress/completed/cancelled，默认 pending；同一时刻至多一个 in_progress。",
  {
    type = "object",
    properties = {
      todos = {
        type = "array",
        description = "完整任务清单",
        items = {
          type = "object",
          properties = {
            content = { type = "string", description = "任务内容" },
            status = { type = "string", enum = { "pending", "in_progress", "completed", "cancelled" }, description = "任务状态" },
          },
          required = { "content" },
        },
      },
    },
    required = { "todos" },
  },
  function(args, on_success, on_error, ctx)
    local agent = ctx and ctx.agent
    local items, err = _normalize_list(args.todos)
    if not items then
      on_error("todo_write 参数错误: " .. tostring(err))
      return
    end
    local key = _key(agent)
    state.todos[key] = { items = items, updated_at = os.time() }
    _ensure_section(agent)
    local counts = { pending = 0, in_progress = 0, completed = 0, cancelled = 0 }
    for _, it in ipairs(items) do
      counts[it.status] = (counts[it.status] or 0) + 1
    end
    event_bus.emit(events.TODO_UPDATED, { session_id = key, count = #items, counts = counts })
    on_success(("任务清单已更新：共 %d 项（待办 %d / 进行中 %d / 完成 %d / 取消 %d）"):format(
      #items, counts.pending, counts.in_progress, counts.completed, counts.cancelled))
  end,
  { category = "agent", approval = { auto_allow = true } }
)

todo_tools.todo_read = helpers.define_tool(
  "todo_read",
  "读取当前任务清单。返回完整清单内容与状态。",
  {
    type = "object",
    properties = {},
    required = {},
  },
  function(args, on_success, on_error, ctx)
    local key = _key(ctx and ctx.agent)
    local rendered = _render(key)
    if rendered == "" then
      on_success("当前无任务清单")
      return
    end
    on_success(rendered)
  end,
  { category = "agent", approval = { auto_allow = true } }
)

todo_tools.todo_clear = helpers.define_tool(
  "todo_clear",
  "清空当前任务清单。",
  {
    type = "object",
    properties = {},
    required = {},
  },
  function(args, on_success, on_error, ctx)
    local key = _key(ctx and ctx.agent)
    state.todos[key] = { items = {}, updated_at = os.time() }
    event_bus.emit(events.TODO_UPDATED, { session_id = key, count = 0 })
    on_success("任务清单已清空")
  end,
  { category = "agent", approval = { auto_allow = true } }
)

-- ========== 公开 API ==========

--- 获取指定会话的待办清单
--- @param session_id string
--- @return table|nil items
function M.get(session_id)
  local e = state.todos[session_id]
  if not e or #e.items == 0 then return nil end
  return e.items
end

--- 从持久化元数据恢复清单（加载会话时）
--- @param session_id string
--- @param items table|nil
function M.seed(session_id, items)
  if type(items) ~= "table" or #items == 0 then return end
  state.todos[session_id] = { items = vim.deepcopy(items), updated_at = os.time() }
end

--- 会话被关闭/删除时清理
--- @param session_id string
function M.cleanup(session_id)
  state.todos[session_id] = nil
  if state.sections[session_id] then
    state.sections[session_id]()
    state.sections[session_id] = nil
  end
end

--- 重置（测试用）
function M.reset()
  for _, unreg in pairs(state.sections) do
    if unreg then pcall(unreg) end
  end
  state.todos = {}
  state.sections = {}
end

--- 获取工具列表
--- @return table 数组
function M.get_tools()
  local out = {}
  for _, tool in pairs(todo_tools) do
    out[#out + 1] = tool
  end
  return out
end

return M