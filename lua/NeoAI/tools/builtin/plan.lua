--- 子 Agent 工具
--- @module 'NeoAI.tools.builtin.plan'
--- 主 Agent 的调度类工具：create_sub_agent / get_sub_agent_status / cancel_sub_agent /
--- send_sub_agent_message。全部委托 core.agent.sub_agent（经 kernel.core_bridge 访问）。
--- 不提供等待工具：子 Agent 自然结束后由管理器把正文回传给主 Agent。
--- 子 Agent 工具子集在此构建（用 registry），并排除调度类工具（避免无限递归）。

local helpers = require("NeoAI.tools.builtin.tool_helpers")

local M = {}

-- ========== 私有常量 ==========

-- 调度类工具：子 Agent 永不获得（避免无限递归派生 / 越权调度）
local AGENT_TOOLS = {
  create_sub_agent = true,
  get_sub_agent_status = true,
  cancel_sub_agent = true,
  send_sub_agent_message = true,
  wait_sub_agent = true,
}

-- ========== 私有函数 ==========

--- 取子 Agent 管理器（未启动时为 nil）
--- @return table|nil
local function _manager()
  local bridge = require("NeoAI.kernel.core_bridge")
  return bridge.sub_agent and bridge.sub_agent()
end

--- 构建子 Agent 可见工具子集：默认**主 Agent 的全部工具**，仅排除「Agent 类」工具
--- （category == "agent"，含调度类 create/get/cancel/send、enter_plan_mode、ask_user、todo_*）。
--- 显式给 boundaries.allowed_tools 时以其为准（同样排除 Agent 类工具）。
--- @param allowed_tools table|nil
--- @return table name -> def
local function _build_tools(allowed_tools)
  local registry = require("NeoAI.tools.registry")
  local manager = _manager()
  local dispatch = (manager and manager.agent_tool_names and manager.agent_tool_names()) or AGENT_TOOLS
  local function _excluded(name, tool)
    if dispatch[name] then return true end
    return tool ~= nil and tool.category == "agent"
  end
  local out = {}
  if allowed_tools and #allowed_tools > 0 then
    for _, name in ipairs(allowed_tools) do
      local tool = registry.get(name)
      if tool and not _excluded(name, tool) then out[name] = tool end
    end
  else
    out = registry.list_as_map()
    for name, tool in pairs(out) do
      if _excluded(name, tool) then out[name] = nil end
    end
  end
  return out
end

-- ========== 工具定义 ==========

local plan_tools = {}

plan_tools.create_sub_agent = helpers.define_tool(
  "create_sub_agent",
  "创建子 Agent 执行独立子任务（后台运行，立即返回）。"
    .. "创建后**无需等待或轮询**：子 Agent 循环结束后会把最终正文自动作为一条新消息回传给你，"
    .. "请直接结束本轮或继续其它工作，切勿反复调用 get_sub_agent_status 查询进度。"
    .. "参数：task 必填；name 可选（简短显示名）；model 可选；boundaries 可选（allowed_tools/allowed_directories/max_tool_calls 等约束）。",
  {
    type = "object",
    properties = {
      task = { type = "string", description = "子任务描述" },
      name = { type = "string", description = "子 Agent 简短显示名（可选）" },
      model = { type = "string", description = "指定模型（可选）" },
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
    local manager = _manager()
    if not manager then
      on_error("子 Agent 运行时不可用")
      return
    end
    local boundaries = args.boundaries or {}
    local entry, err = manager.create(parent_agent, {
      task = args.task,
      name = args.name,
      model = args.model,
      boundaries = boundaries,
      tools = _build_tools(boundaries.allowed_tools),
      context = args.context,
    })
    if not entry then
      on_error("创建子 Agent 失败: " .. tostring(err))
      return
    end
    on_success(("子 Agent 已创建: %s（%s）\n任务: %s\n请勿轮询等待：完成后其最终正文会自动作为一条新消息回传给你。"):format(
      entry.id, entry.name or "", args.task))
  end,
  { category = "agent", approval = { auto_allow = false }, timeout = -1 }
)

plan_tools.get_sub_agent_status = helpers.define_tool(
  "get_sub_agent_status",
  "查询子 Agent 状态与结果。**正常流程无需调用**：子 Agent 完成后其最终正文会自动回传给你。"
    .. "仅在需要确认某个子 Agent 是否仍在运行（例如长时间无回传、怀疑卡住）时使用。sub_agent_id 必填。",
  {
    type = "object",
    properties = { sub_agent_id = { type = "string" } },
    required = { "sub_agent_id" },
  },
  function(args, on_success)
    local manager = _manager()
    local entry = manager and manager.get(args.sub_agent_id)
    if not entry then
      on_success("子 Agent 不存在: " .. tostring(args.sub_agent_id))
      return
    end
    local lines = {
      ("名称: %s"):format(entry.name or ""),
      ("状态: %s"):format(entry.status),
      ("任务: %s"):format(entry.task),
      ("工具调用: %d"):format(entry.tool_calls or 0),
    }
    if entry.result_text and entry.result_text ~= "" then
      lines[#lines + 1] = ("结果:\n%s"):format(entry.result_text)
    end
    on_success(table.concat(lines, "\n"))
  end,
  { category = "agent" }
)

plan_tools.cancel_sub_agent = helpers.define_tool(
  "cancel_sub_agent",
  "终止（取消）一个正在运行的子 Agent。sub_agent_id 必填。",
  {
    type = "object",
    properties = { sub_agent_id = { type = "string" } },
    required = { "sub_agent_id" },
  },
  function(args, on_success, on_error)
    local manager = _manager()
    if not manager then
      on_error("子 Agent 运行时不可用")
      return
    end
    local ok, err = manager.cancel(args.sub_agent_id)
    if not ok then
      on_error(tostring(err))
      return
    end
    on_success("已终止子 Agent: " .. args.sub_agent_id)
  end,
  { category = "agent" }
)

plan_tools.send_sub_agent_message = helpers.define_tool(
  "send_sub_agent_message",
  "向子 Agent 发送一条消息（补充指令/追问）。运行中会在其下一轮注入；已完成会据此续跑一轮。"
    .. "sub_agent_id 与 message 必填。",
  {
    type = "object",
    properties = {
      sub_agent_id = { type = "string" },
      message = { type = "string" },
    },
    required = { "sub_agent_id", "message" },
  },
  function(args, on_success, on_error)
    local manager = _manager()
    if not manager then
      on_error("子 Agent 运行时不可用")
      return
    end
    local ok, err = manager.send(args.sub_agent_id, args.message)
    if not ok then
      on_error(tostring(err))
      return
    end
    on_success("已向子 Agent " .. args.sub_agent_id .. " 发送消息。")
  end,
  { category = "agent" }
)

-- ========== 内部接口（供 tool_service / 测试） ==========

--- 获取工具列表
--- @return table 数组
function M.get_tools()
  local out = {}
  for _, tool in pairs(plan_tools) do
    out[#out + 1] = tool
  end
  return out
end

--- 根据 allowed_tools 构建工具子集（供测试/兼容）
--- @param allowed_tools table|nil
--- @return table name -> tool
function M._allowed_tools(allowed_tools)
  return _build_tools(allowed_tools)
end

--- 重置（测试用）：转调子 Agent 管理器
function M.reset()
  local manager = _manager()
  if manager and manager.reset then manager.reset() end
end

return M
