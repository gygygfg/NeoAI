-- 工具调用编排器
-- 负责管理 AI 工具调用的循环执行
--
-- 设计原则：
-- 1. AI 流式生成过程中检测到 tool_calls 立即启动工具（不等待流式结束）
-- 2. 所有工具并行异步执行，各自完成后直接回调 _on_tool_finished
-- 3. 维护一个"正在运行的工具列表"，工具完成后从列表中移除
-- 4. 全部工具完成 + AI 流式生成完成 → 才触发新一轮 AI 生成
--
-- 注意：不通过事件监听器接收工具完成通知。execute_tool_async 中的
--   vim.schedule 回调执行完毕后直接调用 _on_tool_finished，避免事件队列堆积。
local M = {}

local logger = require("NeoAI.utils.logger")
local event_constants = require("NeoAI.core.events.event_constants")
local tool_executor = require("NeoAI.tools.tool_executor")

local state = {
  initialized = false,
  config = nil,
  session_manager = nil,
  tools = {},
  current_iteration = 0,
  stop_requested = false,

  -- 当前这一轮工具循环的元数据
  round = nil,

  -- 正在运行的工具列表：{ [tool_call_id] = { tool_call, generation_id, ... } }
  running_tools = {},

  -- 已完成的工具结果列表
  completed_results = {},
}

-- ========== 模块级一次性事件监听器（初始化时注册，永不删除） ==========
-- 这些监听器在模块加载时注册一次，后续复用，避免反复创建/删除
local _event_listeners_registered = false

--- 注册模块级事件监听器（只执行一次）
local function _register_module_listeners()
  if _event_listeners_registered then
    return
  end
  _event_listeners_registered = true

  -- 注意：tool_orchestrator 不通过事件监听工具完成
  -- execute_tool_async 中的 vim.schedule 回调直接调用 _on_tool_finished
  -- 这里不注册 TOOL_EXECUTION_COMPLETED/ERROR 监听器，避免无用的事件处理开销
end

function M.initialize(options)
  if state.initialized then return M end
  state.config = options.config or {}
  state.session_manager = options.session_manager
  -- 注册模块级监听器（只执行一次）
  _register_module_listeners()
  state.initialized = true
  return M
end

--- 工具完成回调（由 execute_tool_async 的 vim.schedule 回调直接调用）
function M._on_tool_finished(data)
  -- 如果已请求停止，忽略所有工具完成回调
  if state.stop_requested then
    return
  end
  local tool_call_id = data.tool_call_id
  if not tool_call_id then
    if data.tool_call and data.tool_call.id then
      tool_call_id = data.tool_call.id
    end
  end

  local running = nil
  if tool_call_id then
    running = state.running_tools[tool_call_id]
  end

  -- 如果通过 tool_call_id 找不到，尝试通过 tool_name + generation_id 匹配
  if not running then
    local tool_name = data.tool_name
    local gen_id = data.generation_id
    if tool_name and gen_id then
      for id, r in pairs(state.running_tools) do
        if r.tool_name == tool_name and r.generation_id == gen_id then
          running = r
          tool_call_id = id
          break
        end
      end
    end
  end

  if not running then return end

  -- 从运行列表中移除
  state.running_tools[tool_call_id] = nil

  -- 记录结果
  local result = data.result or data.error_msg or ""
  if type(result) ~= "string" then
    if type(result) == "table" then
      local ok, e = pcall(vim.json.encode, result)
      if ok then
        result = e
      else
        local ok2, e2 = pcall(vim.inspect, result)
        result = ok2 and e2 or tostring(result)
      end
    else
      result = tostring(result)
    end
  end
  table.insert(state.completed_results, {
    tool_call = running.tool_call,
    result = result,
  })

  -- 触发 TOOL_EXECUTION_COMPLETED 或 TOOL_EXECUTION_ERROR 事件
  -- 让 UI 能更新悬浮窗状态（将 🔄 改为 ✅ 或 ❌）
  local evt = data.error_msg and event_constants.TOOL_EXECUTION_ERROR or event_constants.TOOL_EXECUTION_COMPLETED
  vim.api.nvim_exec_autocmds("User", {
    pattern = evt,
    data = {
      generation_id = running.generation_id,
      tool_call = running.tool_call,
      tool_name = running.tool_name,
      arguments = running.tool_call["function"] and running.tool_call["function"].arguments,
      session_id = running.session_id,
      window_id = running.window_id,
      result = result,
      error_msg = data.error_msg,
      duration = data.duration or 0,
      tool_call_id = tool_call_id,
    },
  })

  -- 检查是否所有工具都已完成且 AI 生成也已结束
  M._check_round_complete()
end

--- 检查当前轮次是否完成（所有工具完成 + AI 生成完成）
function M._check_round_complete()
  if state.stop_requested then
    return
  end
  local round = state.round
  if not round then return end

  if next(state.running_tools) ~= nil then return end

  if not round.generation_completed then return end

  -- 全部完成！触发下一轮
  local results = state.completed_results
  local callback = round.callback
  local gen_id = round.generation_id
  local sid = round.session_id
  local wid = round.window_id

  -- 清理本轮状态
  state.round = nil
  state.completed_results = {}

  -- 触发 TOOL_LOOP_FINISHED 事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.TOOL_LOOP_FINISHED,
    data = {
      generation_id = gen_id,
      tool_results = results,
      iteration_count = state.current_iteration,
      session_id = sid,
      window_id = wid,
    },
  })

  -- 触发 TOOL_RESULT_RECEIVED 发起新一轮 AI 请求
  if callback then
    callback(true, results)
  end
end

--- 异步执行单个工具
--- 注意：不通过事件监听器通知完成，而是直接在 vim.schedule 回调末尾调用 _on_tool_finished
local function execute_tool_async(params)
  local tool_call = params.tool_call
  local tool_func = tool_call["function"] or tool_call.func
  if not tool_call or not tool_func then return nil end

  local tool_name = tool_func.name
  local arguments_str = tool_func.arguments
  local arguments = {}
  if arguments_str then
    local ok, parsed = pcall(vim.json.decode, arguments_str)
    if ok and parsed then arguments = parsed end
  end

  local tool_call_id = tool_call.id
  if not tool_call_id or tool_call_id == "" then
    tool_call_id = "call_" .. os.time() .. "_" .. math.random(10000, 99999)
    tool_call.id = tool_call_id
  end

  -- 添加到运行中的工具列表
  state.running_tools[tool_call_id] = {
    tool_call = tool_call,
    tool_name = tool_name,
    generation_id = params.generation_id,
    session_id = params.session_id,
    window_id = params.window_id,
    start_time = os.time(),
  }

  -- 触发执行开始事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.TOOL_EXECUTION_STARTED,
    data = {
      generation_id = params.generation_id,
      tool_call = tool_call,
      tool_name = tool_name,
      arguments = arguments,
      session_id = params.session_id,
      window_id = params.window_id,
      start_time = os.time(),
      tool_call_id = tool_call_id,
    },
  })

  -- 预获取工具定义（在 vim.schedule 外部执行，避免回调内部重复 require 和深拷贝）
  local tool_registry = require("NeoAI.tools.tool_registry")
  local tool = tool_registry.get(tool_name)

  -- 直接执行工具函数（不通过 vim.schedule/vim.defer_fn）
  -- 工具函数内部可能调用 vim.wait（如 LSP 工具函数），
  -- vim.wait 在 Neovim 主线程中会处理事件循环，不会导致整个 Neovim 卡死。
  -- 如果通过 vim.defer_fn 执行，vim.wait 会阻塞回调的执行，导致工具状态无法更新。
  -- 使用 vim.schedule 将执行推迟到下一次事件循环迭代，
  -- 确保 execute_tool_loop 能先返回，避免递归调用。
  vim.schedule(function()
    if state.stop_requested or not state.running_tools[tool_call_id] then
      logger.debug("[tool_orchestrator] execute_tool_async: 工具 " .. tool_name .. " 已被取消")
      return
    end
    logger.debug("[tool_orchestrator] execute_tool_async: 开始执行 " .. tool_name .. " (id=" .. tool_call_id .. ")")
    local start_time = os.time()

    -- 使用 pcall 执行工具函数
    -- 工具函数内部可能调用 vim.wait（如 LSP 工具函数），
    -- vim.wait 会处理事件循环，不会导致整个 Neovim 卡死
    local exec_result
    if tool and tool.func then
      local ok, r = pcall(tool.func, arguments)
      if ok then
        exec_result = r
      else
        exec_result = setmetatable({ _error = true, message = tostring(r) }, {
          __tostring = function() return tostring(r) end,
        })
      end
    else
      exec_result = setmetatable({ _error = true, message = "工具不存在: " .. tool_name }, {
        __tostring = function() return "工具不存在: " .. tool_name end,
      })
    end

    logger.debug("[tool_orchestrator] execute_tool_async: 工具执行完成")
    local duration = os.time() - start_time

    local result, error_msg = nil, nil
    if type(exec_result) == "table" and exec_result._error then
      error_msg = tostring(exec_result.message or exec_result)
    else
      result = exec_result
      if type(result) ~= "string" then
        if type(result) == "table" then
          local ok, e = pcall(vim.json.encode, result)
          if ok then
            result = e
          else
            local ok2, e2 = pcall(vim.inspect, result)
            result = ok2 and e2 or tostring(result)
          end
        else
          result = tostring(result)
        end
      end
    end

    -- 直接调用 _on_tool_finished，不通过事件
    M._on_tool_finished({
      tool_call_id = tool_call_id,
      generation_id = params.generation_id,
      tool_name = tool_name,
      tool_call = tool_call,
      result = result,
      error_msg = error_msg,
      duration = duration,
    })
  end, 0)

  return tool_call_id
end

--- 启动一轮工具循环
function M.execute_tool_loop(params, callback)
  if not state.initialized then
    if callback then vim.schedule(function() callback(false, nil, "Tool orchestrator not initialized") end) end
    return
  end
  if not next(state.tools) then
    if callback then vim.schedule(function() callback(true, {}) end) end
    return
  end

  if state.stop_requested then
    if callback then vim.schedule(function() callback(true, {}) end) end
    return
  end

  local tool_calls = params.tool_calls or {}
  if #tool_calls == 0 then
    if callback then vim.schedule(function() callback(true, {}) end) end
    return
  end

  local generation_id = params.generation_id
  local session_id = params.session_id
  local window_id = params.window_id

  -- 如果已有未完成的轮次，将新工具追加到该轮次中
  if state.round and state.round.generation_id == generation_id then
    for _, tc in ipairs(tool_calls) do
      execute_tool_async({
        generation_id = generation_id,
        tool_call = tc,
        session_id = session_id,
        window_id = window_id,
      })
    end
    return
  end

  -- 如果已有其他轮次在执行，先停止
  if state.round then
    M.request_stop()
  end

  state.current_iteration = state.current_iteration + 1
  state.stop_requested = false
  state.completed_results = {}

  -- 触发 TOOL_LOOP_STARTED 事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.TOOL_LOOP_STARTED,
    data = {
      generation_id = generation_id,
      tool_calls = tool_calls,
      session_id = session_id,
      window_id = window_id,
    },
  })

  -- 设置本轮状态
  state.round = {
    generation_id = generation_id,
    session_id = session_id,
    window_id = window_id,
    generation_completed = false,
    callback = callback,
  }

  -- 立即启动所有工具
  for _, tc in ipairs(tool_calls) do
    execute_tool_async({
      generation_id = generation_id,
      tool_call = tc,
      session_id = session_id,
      window_id = window_id,
    })
  end
end

--- 标记 AI 生成已完成
function M.mark_generation_completed(generation_id)
  if state.stop_requested then
    return
  end
  local round = state.round
  if not round then return end
  if round.generation_id ~= generation_id then return end

  round.generation_completed = true
  M._check_round_complete()
end

--- 获取当前正在运行的工具数量
function M.get_running_tool_count()
  local count = 0
  for _ in pairs(state.running_tools) do
    count = count + 1
  end
  return count
end

--- 执行单个工具（同步版本，兼容旧接口）
function M.execute_tool(params)
  local tool_call = params.tool_call
  local tool_func = tool_call["function"] or tool_call.func
  if not tool_call or not tool_func then return nil end

  local tool_name = tool_func.name
  local arguments_str = tool_func.arguments
  local arguments = {}
  if arguments_str then
    local ok, parsed = pcall(vim.json.decode, arguments_str)
    if ok and parsed then arguments = parsed end
  end

  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.TOOL_EXECUTION_STARTED,
    data = { generation_id = params.generation_id, tool_call = tool_call, tool_name = tool_name,
             arguments = arguments, session_id = params.session_id, window_id = params.window_id, start_time = os.time() },
  })

  local result, error_msg = nil, nil
  local start_time = os.time()
  local exec_result = tool_executor.execute(tool_name, arguments)

  if type(exec_result) == "table" and exec_result._error then
    error_msg = tostring(exec_result.message or exec_result)
  else
    result = exec_result
  end

  local duration = os.time() - start_time
  local evt = error_msg and event_constants.TOOL_EXECUTION_ERROR or event_constants.TOOL_EXECUTION_COMPLETED
  local data = { generation_id = params.generation_id, tool_call = tool_call, tool_name = tool_name,
                 arguments = arguments, session_id = params.session_id, window_id = params.window_id, duration = duration }
  if error_msg then data.error_msg = error_msg else data.result = result end
  vim.api.nvim_exec_autocmds("User", { pattern = evt, data = data })

  local final = result or error_msg
  if type(final) ~= "string" then
    if type(final) == "table" then
      local ok, e = pcall(vim.json.encode, final); final = ok and e or vim.inspect(final)
    else final = tostring(final) end
  end
  return final
end

function M.set_tools(tools)
  state.tools = tools or {}
end

function M.request_stop()
  state.stop_requested = true
  state.running_tools = {}

  -- 保存当前 round 的回调，然后清空 round
  local round = state.round
  local completed = state.completed_results
  state.round = nil
  state.completed_results = {}

  -- 如果有活跃的 round，触发回调让 AI 引擎继续
  -- 即使 completed 为空也要触发回调，否则 AI 引擎会卡住
  if round and round.callback then
    vim.schedule(function()
      round.callback(true, completed or {})
    end)
  end
end

function M.is_stop_requested()
  return state.stop_requested
end

function M.reset_stop_requested()
  state.stop_requested = false
end

function M.get_current_iteration()
  return state.current_iteration or 0
end

function M.reset_iteration()
  state.current_iteration = 0
end

function M.get_tools()
  return state.tools
end

function M.is_executing()
  return state.round ~= nil or next(state.running_tools) ~= nil
end

function M.shutdown()
  state.round = nil
  state.running_tools = {}
  state.completed_results = {}
  state.tools = {}
  state.initialized = false
  state.current_iteration = 0
end

return M
