-- 计划流程表工具
-- 当任务比较复杂、需要大量搜索或重试等可能占用大量上下文但又对后续没有太大关系的操作，
-- 可以交给计划流程表来执行。
--
-- 工作机制：
--   1. 主 agent 调用 create_sub_agent 创建一个子 agent
--   2. 子 agent 共享创建前的上下文，但使用独立的系统提示词
--   3. 子 agent 拥有和主 agent 一样的工具调用循环
--   4. 调度 agent 自动创建，审核子 agent 的工具调用是否超出边界
--   5. 子 agent 结束后自动总结执行情况返回主 agent
--
-- 边界检查：
--   调度 agent 会读取子 agent 的每一次工具调用请求，判断是否在允许的范围内。
--   如果超出边界，调度 agent 可以选择驳回并给出理由，或允许执行。
--   边界由主 agent 在创建子 agent 时设置。

local M = {}

local define_tool = require("NeoAI.tools.builtin.tool_helpers").define_tool
local logger = require("NeoAI.utils.logger")

-- ========== 子 agent 监控悬浮窗（延迟加载）
local _sub_agent_monitor = nil
local function get_monitor()
  if not _sub_agent_monitor then
    local ok, mod = pcall(require, "NeoAI.ui.components.sub_agent_monitor")
    if ok then
      _sub_agent_monitor = mod
    end
  end
  return _sub_agent_monitor
end

--- 触发监控悬浮窗刷新
--- 如果窗口不存在，自动创建并显示
--- 带防抖：500ms 内多次调用只会执行最后一次
local _refresh_timer = nil
local function _refresh_monitor()
  local monitor = get_monitor()
  if not monitor then
    return
  end

  -- 防抖：清除之前的定时器
  if _refresh_timer then
    pcall(vim.fn.timer_stop, _refresh_timer)
    _refresh_timer = nil
  end

  -- 延迟 500ms 执行，避免频繁刷新
  _refresh_timer = vim.fn.timer_start(500, function()
    _refresh_timer = nil
    -- 直接调用 show（不在 vim.schedule 中），因为定时器回调已在主线程
    pcall(monitor.show)
  end, { ["repeat"] = 0 })
end

-- ========== 子 agent 会话管理 ==========

local sub_agents = {} -- sub_agent_id -> sub_agent state
local agent_counter = 0

-- ========== 调度 agent 状态管理 ==========

--- 调度 agent 负责审核子 agent 的工具调用是否超出边界
--- 当子 agent 的工具调用被调度 agent 拒绝时，子 agent 会收到驳回理由并可以调整策略

-- ========== 工具定义 ==========

--- 创建子 agent
--- @param args table
---   - task: string - 子 agent 需要完成的任务描述（必填）
---   - boundaries: table - 边界定义（可选），描述子 agent 可以访问的范围
---     - allowed_directories: string[] - 允许访问的目录列表
---     - allowed_files: string[] - 允许操作的文件列表
---     - allowed_commands: string[] - 允许执行的命令模式
---     - allowed_tools: string[] - 允许调用的工具列表
---     - max_tool_calls: number - 最大工具调用次数（默认 30）
---     - max_iterations: number - 最大迭代轮次（默认 10）
---     - description: string - 边界描述文本，供调度 agent 理解
---   - context: table - 额外上下文（可选），传递给子 agent 的额外信息
---   - timeout: number - 超时时间（秒），默认 120 秒
--- @param on_success function
--- @param on_error function
local function _create_sub_agent(args, on_success, on_error)
  if not args or not args.task then
    if on_error then
      on_error("需要 task 参数（子 agent 的任务描述）")
    end
    return
  end

  -- 生成唯一 ID
  agent_counter = agent_counter + 1
  local sub_agent_id = "sub_agent_" .. agent_counter .. "_" .. os.time()

  -- 解析边界
  local boundaries = args.boundaries or {}
  local allowed_tools = boundaries.allowed_tools or nil -- nil 表示不限制
  local max_tool_calls = boundaries.max_tool_calls or 30
  local max_iterations = boundaries.max_iterations or 10
  local timeout_sec = args.timeout or 120

  -- 构建子 agent 状态
  local sub_agent = {
    id = sub_agent_id,
    task = args.task,
    boundaries = boundaries,
    context = args.context or {},
    status = "running", -- running | completed | rejected | timeout | error
    created_at = os.time(),
    timeout_sec = timeout_sec,
    max_tool_calls = max_tool_calls,
    max_iterations = max_iterations,
    tool_call_count = 0,
    iteration_count = 0,
    messages = {}, -- 子 agent 的对话消息
    results = {}, -- 执行结果汇总
    errors = {}, -- 错误记录
    summary = nil, -- 最终执行总结
    -- 调度 agent 相关
    rejected_calls = {}, -- 被调度 agent 驳回的工具调用
    approved_calls = {}, -- 被调度 agent 批准的工具调用
    pending_approval = nil, -- 当前待审批的工具调用
    last_tool_call = nil, -- 最近一次工具调用名称
    -- 回调
    on_complete = nil,
  }

  sub_agents[sub_agent_id] = sub_agent

  -- 启动超时定时器
  local timeout_timer = vim.fn.timer_start(timeout_sec * 1000, function()
    local sa = sub_agents[sub_agent_id]
    if sa and sa.status == "running" then
      sa.status = "timeout"
      sa.summary = string.format("子 agent 执行超时（%d 秒）", timeout_sec)
      _finalize_sub_agent(sub_agent_id)
    end
  end, { ["repeat"] = 0 })

  sub_agent.timeout_timer = timeout_timer

  -- 刷新监控悬浮窗（直接调用，_refresh_monitor 内部会通过 pcall 保护）
  _refresh_monitor()

  -- 返回创建结果
  local result = {
    sub_agent_id = sub_agent_id,
    task = args.task,
    boundaries = boundaries,
    status = "running",
    message = string.format(
      "子 agent [%s] 已创建，任务: %s\n边界: %s\n最大工具调用次数: %d\n超时时间: %d秒",
      sub_agent_id,
      args.task,
      boundaries.description or "（未设置边界描述）",
      max_tool_calls,
      timeout_sec
    ),
  }

  if on_success then
    on_success(result)
  end
end

--- 获取子 agent 执行状态
local function _get_sub_agent_status(args, on_success, on_error)
  if not args or not args.sub_agent_id then
    if on_error then
      on_error("需要 sub_agent_id 参数")
    end
    return
  end

  local sa = sub_agents[args.sub_agent_id]
  if not sa then
    if on_error then
      on_error(string.format("子 agent [%s] 不存在", args.sub_agent_id))
    end
    return
  end

  local result = {
    sub_agent_id = sa.id,
    task = sa.task,
    status = sa.status,
    tool_call_count = sa.tool_call_count,
    iteration_count = sa.iteration_count,
    created_at = sa.created_at,
    running_duration = os.time() - sa.created_at,
    rejected_calls_count = #sa.rejected_calls,
    approved_calls_count = #sa.approved_calls,
    rejected_calls = sa.rejected_calls,
    summary = sa.summary,
    last_tool_call = sa.last_tool_call,
    max_tool_calls = sa.max_tool_calls,
    max_iterations = sa.max_iterations,
  }

  if on_success then
    on_success(result)
  end
end

--- 列出所有子 agent
local function _list_sub_agents(args, on_success, on_error)
  local agents_list = {}
  for id, sa in pairs(sub_agents) do
    table.insert(agents_list, {
      sub_agent_id = id,
      task = sa.task:sub(1, 100), -- 截断长任务描述
      status = sa.status,
      tool_call_count = sa.tool_call_count,
      iteration_count = sa.iteration_count,
      created_at = sa.created_at,
      max_tool_calls = sa.max_tool_calls,
      max_iterations = sa.max_iterations,
      last_tool_call = sa.last_tool_call,
      rejected_calls = sa.rejected_calls,
      summary = sa.summary,
    })
  end
  table.sort(agents_list, function(a, b)
    return a.created_at > b.created_at
  end)

  if on_success then
    on_success({ agents = agents_list, count = #agents_list })
  end
end

-- ========== 子 agent 生命周期管理 ==========

--- 结束子 agent 并生成总结
--- 此函数由调度 agent 或子 agent 自身在完成时调用
--- @param sub_agent_id string
local function _finalize_sub_agent(sub_agent_id)
  local sa = sub_agents[sub_agent_id]
  if not sa then
    return
  end

  -- 停止超时定时器
  if sa.timeout_timer and vim.fn.timer_info(sa.timeout_timer)[1] then
    vim.fn.timer_stop(sa.timeout_timer)
    sa.timeout_timer = nil
  end

  -- 如果还没有总结，生成一个简短的总结
  if not sa.summary then
    sa.summary = _generate_summary(sa)
  end

  sa.status = sa.status or "completed"

  -- 刷新监控悬浮窗
  _refresh_monitor()

  -- 触发完成回调
  if sa.on_complete then
    local cb = sa.on_complete
    sa.on_complete = nil
    pcall(cb, sa)
  end
end

--- 生成子 agent 执行总结
--- @param sa table 子 agent 状态
--- @return string 总结文本
local function _generate_summary(sa)
  local lines = {
    string.format("【子 agent 执行总结】"),
    string.format("ID: %s", sa.id),
    string.format("任务: %s", sa.task),
    string.format("状态: %s", sa.status),
    string.format("执行时长: %d 秒", os.time() - sa.created_at),
    string.format("工具调用次数: %d", sa.tool_call_count),
    string.format("迭代轮次: %d", sa.iteration_count),
  }

  if #sa.approved_calls > 0 then
    lines[#lines + 1] = string.format("已批准的工具调用: %d 次", #sa.approved_calls)
  end

  if #sa.rejected_calls > 0 then
    lines[#lines + 1] = string.format("被驳回的工具调用: %d 次", #sa.rejected_calls)
    for i, rc in ipairs(sa.rejected_calls) do
      if i <= 5 then
        lines[#lines + 1] = string.format("  - 工具: %s, 原因: %s", rc.tool_name or "未知", rc.reason or "无")
      end
    end
    if #sa.rejected_calls > 5 then
      lines[#lines + 1] = string.format("  ... 还有 %d 条被驳回记录", #sa.rejected_calls - 5)
    end
  end

  if #sa.errors > 0 then
    lines[#lines + 1] = string.format("执行错误: %d 次", #sa.errors)
    for i, err in ipairs(sa.errors) do
      if i <= 3 then
        lines[#lines + 1] = string.format("  - %s", err)
      end
    end
  end

  if #sa.results > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "=== 关键结果 ==="
    for i, r in ipairs(sa.results) do
      if i <= 10 then
        local content = r:gsub("\n", " "):sub(1, 200)
        lines[#lines + 1] = string.format("  %d. %s", i, content)
      end
    end
    if #sa.results > 10 then
      lines[#lines + 1] = string.format("  ... 还有 %d 条结果", #sa.results - 10)
    end
  end

  return table.concat(lines, "\n")
end

--- 取消子 agent
local function _cancel_sub_agent(args, on_success, on_error)
  if not args or not args.sub_agent_id then
    if on_error then
      on_error("需要 sub_agent_id 参数")
    end
    return
  end

  local sa = sub_agents[args.sub_agent_id]
  if not sa then
    if on_error then
      on_error(string.format("子 agent [%s] 不存在", args.sub_agent_id))
    end
    return
  end

  if sa.status ~= "running" then
    if on_error then
      on_error(string.format("子 agent [%s] 状态为 %s，无法取消", args.sub_agent_id, sa.status))
    end
    return
  end

  sa.status = "rejected"
  sa.summary = args.reason or "主 agent 手动取消"

  _finalize_sub_agent(args.sub_agent_id)

  if on_success then
    on_success({
      sub_agent_id = args.sub_agent_id,
      status = "rejected",
      reason = sa.summary,
      message = string.format("子 agent [%s] 已取消", args.sub_agent_id),
    })
  end
end

-- ========== 调度 agent 接口 ==========

--- 调度 agent 审核工具调用
--- 当子 agent 发起工具调用时，调度 agent 会检查该调用是否在边界范围内
--- @param sub_agent_id string
--- @param tool_call table 工具调用请求
--- @return boolean, string|nil 是否允许执行，驳回理由
function M.review_tool_call(sub_agent_id, tool_call)
  local sa = sub_agents[sub_agent_id]
  if not sa then
    return false, "子 agent 不存在"
  end

  if sa.status ~= "running" then
    return false, string.format("子 agent 状态为 %s，无法执行工具调用", sa.status)
  end

  local boundaries = sa.boundaries
  local tool_name = tool_call.name or (tool_call["function"] and tool_call["function"].name) or ""

  -- 检查工具限制
  if boundaries.allowed_tools and #boundaries.allowed_tools > 0 then
    local allowed = false
    for _, allowed_tool in ipairs(boundaries.allowed_tools) do
      if tool_name:match(allowed_tool) then
        allowed = true
        break
      end
    end
    if not allowed then
      local reason = string.format("工具 '%s' 不在允许的工具列表中", tool_name)
      table.insert(sa.rejected_calls, {
        tool_name = tool_name,
        reason = reason,
        timestamp = os.time(),
      })
      return false, reason
    end
  end

  -- 检查命令限制（针对 shell 工具）
  if boundaries.allowed_commands and #boundaries.allowed_commands > 0 then
    local args = tool_call.arguments or {}
    local command = args.command or args.cmd or ""
    if command ~= "" then
      local allowed = false
      for _, pattern in ipairs(boundaries.allowed_commands) do
        if command:match(pattern) then
          allowed = true
          break
        end
      end
      if not allowed then
        local reason = string.format("命令 '%s' 不在允许的命令模式中", command)
        table.insert(sa.rejected_calls, {
          tool_name = tool_name,
          reason = reason,
          timestamp = os.time(),
        })
        return false, reason
      end
    end
  end

  -- 检查文件操作限制
  if boundaries.allowed_files and #boundaries.allowed_files > 0 then
    local args = tool_call.arguments or {}
    local filepath = args.filepath or args.path or ""
    if filepath ~= "" then
      local allowed = false
      for _, pattern in ipairs(boundaries.allowed_files) do
        if filepath:match(pattern) then
          allowed = true
          break
        end
      end
      if not allowed then
        local reason = string.format("文件 '%s' 不在允许的文件列表中", filepath)
        table.insert(sa.rejected_calls, {
          tool_name = tool_name,
          reason = reason,
          timestamp = os.time(),
        })
        return false, reason
      end
    end
  end

  -- 检查目录限制
  if boundaries.allowed_directories and #boundaries.allowed_directories > 0 then
    local args = tool_call.arguments or {}
    local cwd = args.cwd or ""
    if cwd ~= "" then
      local allowed = false
      for _, dir in ipairs(boundaries.allowed_directories) do
        if cwd:match(dir) then
          allowed = true
          break
        end
      end
      if not allowed then
        local reason = string.format("目录 '%s' 不在允许的目录列表中", cwd)
        table.insert(sa.rejected_calls, {
          tool_name = tool_name,
          reason = reason,
          timestamp = os.time(),
        })
        return false, reason
      end
    end
  end

  -- 检查工具调用次数限制
  if sa.tool_call_count >= sa.max_tool_calls then
    local reason = string.format("工具调用次数已达上限（%d 次）", sa.max_tool_calls)
    table.insert(sa.rejected_calls, {
      tool_name = tool_name,
      reason = reason,
      timestamp = os.time(),
    })
    return false, reason
  end

  -- 记录已批准的工具调用
  table.insert(sa.approved_calls, {
    tool_name = tool_name,
    timestamp = os.time(),
  })
  sa.tool_call_count = sa.tool_call_count + 1
  sa.last_tool_call = tool_name

  -- 刷新监控
  _refresh_monitor()

  return true, nil
end

--- 记录子 agent 的执行结果
--- @param sub_agent_id string
--- @param result string 执行结果
function M.record_result(sub_agent_id, result)
  local sa = sub_agents[sub_agent_id]
  if not sa then
    return
  end
  table.insert(sa.results, result)
  -- 只保留最近 50 条结果
  if #sa.results > 50 then
    table.remove(sa.results, 1)
  end
  -- 刷新监控
  _refresh_monitor()
end

--- 记录子 agent 的错误
--- @param sub_agent_id string
--- @param error_msg string
function M.record_error(sub_agent_id, error_msg)
  local sa = sub_agents[sub_agent_id]
  if not sa then
    return
  end
  table.insert(sa.errors, error_msg)
  -- 刷新监控
  _refresh_monitor()
end

--- 记录子 agent 的对话消息
--- @param sub_agent_id string
--- @param role string
--- @param content string
function M.record_message(sub_agent_id, role, content)
  local sa = sub_agents[sub_agent_id]
  if not sa then
    return
  end
  table.insert(sa.messages, {
    role = role,
    content = content,
    timestamp = os.time(),
  })
  -- 只保留最近 100 条消息
  if #sa.messages > 100 then
    table.remove(sa.messages, 1)
  end
  -- 刷新监控
  _refresh_monitor()
end

--- 获取子 agent 的完整上下文（供子 agent 初始化时使用）
--- @param sub_agent_id string
--- @return table|nil
function M.get_sub_agent_context(sub_agent_id)
  local sa = sub_agents[sub_agent_id]
  if not sa then
    return nil
  end
  return {
    task = sa.task,
    boundaries = sa.boundaries,
    context = sa.context,
    sub_agent_id = sa.id,
  }
end

--- 检查子 agent 是否应该继续执行
--- @param sub_agent_id string
--- @return boolean
function M.should_continue(sub_agent_id)
  local sa = sub_agents[sub_agent_id]
  if not sa then
    return false
  end
  if sa.status ~= "running" then
    return false
  end
  if sa.iteration_count >= sa.max_iterations then
    sa.status = "completed"
    sa.summary = string.format("达到最大迭代轮次（%d 轮）", sa.max_iterations)
    _finalize_sub_agent(sub_agent_id)
    return false
  end
  sa.iteration_count = sa.iteration_count + 1
  return true
end

--- 获取子 agent 的执行总结
--- @param sub_agent_id string
--- @return string|nil
function M.get_summary(sub_agent_id)
  local sa = sub_agents[sub_agent_id]
  if not sa then
    return nil
  end
  return sa.summary or _generate_summary(sa)
end

--- 清理子 agent（释放资源）
--- @param sub_agent_id string
function M.cleanup_sub_agent(sub_agent_id)
  local sa = sub_agents[sub_agent_id]
  if not sa then
    return
  end

  if sa.timeout_timer and vim.fn.timer_info(sa.timeout_timer)[1] then
    vim.fn.timer_stop(sa.timeout_timer)
  end

  sub_agents[sub_agent_id] = nil
end

--- 清理所有已完成的子 agent
function M.cleanup_completed_agents()
  for id, sa in pairs(sub_agents) do
    if sa.status ~= "running" then
      M.cleanup_sub_agent(id)
    end
  end
end

--- 清理所有子 agent（包括运行中的），用于退出时紧急清理
function M.cleanup_all()
  for id, sa in pairs(sub_agents) do
    -- 停止超时定时器
    if sa.timeout_timer then
      pcall(vim.fn.timer_stop, sa.timeout_timer)
      sa.timeout_timer = nil
    end
    -- 标记为停止
    sa.status = "rejected"
    sa.summary = "系统退出，子 agent 被终止"
  end
  -- 清空所有子 agent 状态
  sub_agents = {}
  agent_counter = 0
end

-- ========== 工具注册 ==========

M.create_sub_agent = define_tool({
  name = "create_sub_agent",
  description = [[创建子 agent 来执行复杂任务。子 agent 拥有独立的工具调用循环，与主 agent 共享创建前的上下文。
子 agent 适合处理以下场景：
- 需要大量搜索或文件读取的任务
- 需要多次重试的操作
- 与主任务关联不大但需要完成的子任务
- 可能产生大量中间输出的操作

子 agent 创建后会立即开始执行。执行过程中，调度 agent 会自动审核子 agent 的工具调用是否超出边界。
子 agent 执行完成后，系统会自动生成执行总结返回给主 agent。

注意：创建子 agent 后，主 agent 可以继续处理其他任务。子 agent 完成后会通过后续消息返回总结。]],
  func = _create_sub_agent,
  async = true,
  parameters = {
    type = "object",
    properties = {
      task = {
        type = "string",
        description = "子 agent 需要完成的任务描述。描述应清晰明确，包含具体的目标、步骤和预期输出。",
      },
      boundaries = {
        type = "object",
        description = "边界定义，描述子 agent 可以访问的范围。设置合理的边界可以防止子 agent 越权操作。",
        properties = {
          allowed_tools = {
            type = "array",
            items = { type = "string" },
            description = "允许调用的工具列表（Lua 模式匹配）。例如：['^read_file$', '^grep_search$', '^run_command$']。不设置表示不限制。",
          },
          allowed_commands = {
            type = "array",
            items = { type = "string" },
            description = "允许执行的命令模式（Lua 模式匹配）。例如：['^git ', '^ls ', '^cat ']。不设置表示不限制。",
          },
          allowed_files = {
            type = "array",
            items = { type = "string" },
            description = "允许操作的文件路径模式（Lua 模式匹配）。例如：['src/']。不设置表示不限制。",
          },
          allowed_directories = {
            type = "array",
            items = { type = "string" },
            description = "允许访问的目录路径模式（Lua 模式匹配）。例如：['/root/NeoAI/']。不设置表示不限制。",
          },
          max_tool_calls = {
            type = "number",
            description = "最大工具调用次数，默认 30",
            default = 30,
          },
          max_iterations = {
            type = "number",
            description = "最大迭代轮次，默认 10",
            default = 10,
          },
          description = {
            type = "string",
            description = "边界描述文本，供调度 agent 理解边界范围。例如：'只允许读取 src/ 目录下的文件'",
          },
        },
      },
      context = {
        type = "object",
        description = "额外上下文信息，传递给子 agent 的额外数据。例如：{ search_keywords = { 'xxx', 'yyy' }, reference_files = { 'file1.lua', 'file2.lua' } }",
      },
      timeout = {
        type = "number",
        description = "超时时间（秒），默认 120 秒。超过此时间子 agent 会自动终止。",
        default = 120,
      },
    },
    required = { "task" },
  },
  returns = {
    type = "object",
    properties = {
      sub_agent_id = { type = "string", description = "子 agent 的唯一 ID" },
      task = { type = "string", description = "子 agent 的任务描述" },
      boundaries = { type = "object", description = "边界定义" },
      status = { type = "string", description = "子 agent 状态" },
      message = { type = "string", description = "创建成功提示" },
    },
    description = "子 agent 创建结果",
  },
  category = "system",
  permissions = { execute = true },
})

M.get_sub_agent_status = define_tool({
  name = "get_sub_agent_status",
  description = "获取子 agent 的执行状态和当前进度。可用于检查子 agent 是否完成、执行了哪些操作、是否有被驳回的调用等。",
  func = _get_sub_agent_status,
  async = true,
  parameters = {
    type = "object",
    properties = {
      sub_agent_id = {
        type = "string",
        description = "子 agent 的唯一 ID",
      },
    },
    required = { "sub_agent_id" },
  },
  returns = {
    type = "object",
    properties = {
      sub_agent_id = { type = "string", description = "子 agent ID" },
      task = { type = "string", description = "任务描述" },
      status = { type = "string", description = "当前状态：running | completed | rejected | timeout | error" },
      tool_call_count = { type = "number", description = "已执行的工具调用次数" },
      iteration_count = { type = "number", description = "已完成的迭代轮次" },
      created_at = { type = "number", description = "创建时间戳" },
      running_duration = { type = "number", description = "已运行时长（秒）" },
      rejected_calls_count = { type = "number", description = "被调度 agent 驳回的调用次数" },
      approved_calls_count = { type = "number", description = "已批准的调用次数" },
      rejected_calls = { type = "array", items = { type = "object" }, description = "被驳回的调用详情" },
      summary = { type = "string", description = "执行总结（完成后才有）" },
      last_tool_call = { type = "string", description = "最近一次工具调用名称" },
      max_tool_calls = { type = "number", description = "最大工具调用次数" },
      max_iterations = { type = "number", description = "最大迭代轮次" },
    },
    description = "子 agent 状态信息",
  },
  category = "system",
  permissions = { execute = true },
})

M.list_sub_agents = define_tool({
  name = "list_sub_agents",
  description = "列出所有子 agent 及其状态。",
  func = _list_sub_agents,
  async = true,
  parameters = {
    type = "object",
    properties = {},
  },
  returns = {
    type = "object",
    properties = {
      agents = {
        type = "array",
        items = {
          type = "object",
          properties = {
            sub_agent_id = { type = "string" },
            task = { type = "string" },
            status = { type = "string" },
            tool_call_count = { type = "number" },
            iteration_count = { type = "number" },
            created_at = { type = "number" },
            max_tool_calls = { type = "number" },
            max_iterations = { type = "number" },
            last_tool_call = { type = "string" },
            rejected_calls = { type = "array", items = { type = "object" } },
            summary = { type = "string" },
          },
        },
      },
      count = { type = "number", description = "子 agent 总数" },
    },
    description = "子 agent 列表",
  },
  category = "system",
  permissions = { execute = true },
})

M.cancel_sub_agent = define_tool({
  name = "cancel_sub_agent",
  description = "取消正在运行的子 agent。取消后子 agent 会立即停止执行，并生成执行总结。",
  func = _cancel_sub_agent,
  async = true,
  parameters = {
    type = "object",
    properties = {
      sub_agent_id = {
        type = "string",
        description = "要取消的子 agent ID",
      },
      reason = {
        type = "string",
        description = "取消原因说明",
      },
    },
    required = { "sub_agent_id" },
  },
  returns = {
    type = "object",
    properties = {
      sub_agent_id = { type = "string", description = "子 agent ID" },
      status = { type = "string", description = "取消后的状态" },
      reason = { type = "string", description = "取消原因" },
      message = { type = "string", description = "取消结果提示" },
    },
    description = "取消结果",
  },
  category = "system",
  permissions = { execute = true },
})

-- ========== 获取工具列表 ==========

--- 获取所有子 agent 数据（同步接口，供监控组件使用）
--- @return table[] 子 agent 数据列表
function M.get_all_agents_data()
  local agents_list = {}
  for id, sa in pairs(sub_agents) do
    table.insert(agents_list, {
      sub_agent_id = id,
      task = sa.task,
      status = sa.status,
      tool_call_count = sa.tool_call_count,
      iteration_count = sa.iteration_count,
      created_at = sa.created_at,
      max_tool_calls = sa.max_tool_calls,
      max_iterations = sa.max_iterations,
      last_tool_call = sa.last_tool_call,
      rejected_calls = sa.rejected_calls,
      summary = sa.summary,
    })
  end
  table.sort(agents_list, function(a, b)
    return a.created_at > b.created_at
  end)
  return agents_list
end

function M.get_tools()
  local tools = {}
  for _, v in pairs(M) do
    if type(v) == "table" and v.name and v.func then
      table.insert(tools, v)
    end
  end
  table.sort(tools, function(a, b)
    return a.name < b.name
  end)
  return tools
end

return M
