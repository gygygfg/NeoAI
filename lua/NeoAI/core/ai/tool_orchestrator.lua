-- 工具调用编排器
-- 负责管理 AI 工具调用的循环执行
local M = {}

local logger = require("NeoAI.utils.logger")
local event_constants = require("NeoAI.core.events.event_constants")

local state = {
  initialized = false,
  config = nil,
  session_manager = nil,
  tools = {},
  current_iteration = 0,
  stop_requested = false,
}

function M.initialize(options)
  if state.initialized then return M end
  state.config = options.config or {}
  state.session_manager = options.session_manager
  state.initialized = true
  return M
end

--- 执行工具调用循环
function M.execute_tool_loop(params)
  if not state.initialized then error("Tool orchestrator not initialized") end
  if not next(state.tools) then return nil end

  local tool_calls = params.tool_calls or {}
  if #tool_calls == 0 then return nil end

  local generation_id = params.generation_id
  local session_id = params.session_id
  local window_id = params.window_id
  local options = params.options or {}
  state.stop_requested = false
  local tool_results = {}

  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.TOOL_LOOP_STARTED,
    data = { generation_id = generation_id, tool_calls = tool_calls, session_id = session_id, window_id = window_id },
  })

  for i, tool_call in ipairs(tool_calls) do
    state.current_iteration = state.current_iteration + 1
    if state.stop_requested then break end

    local result = M.execute_tool({
      generation_id = generation_id, tool_call = tool_call,
      session_id = session_id, window_id = window_id,
    })
    if result then
      table.insert(tool_results, { tool_call = tool_call, result = result })
    end
  end

  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.TOOL_LOOP_FINISHED,
    data = { generation_id = generation_id, tool_results = tool_results,
             iteration_count = state.current_iteration, session_id = session_id, window_id = window_id },
  })
  return tool_results
end

--- 执行单个工具
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

  local tool_def = state.tools[tool_name]
  local result, error_msg = nil, nil
  local start_time = os.time()

  if tool_def and tool_def.func then
    local success, r = pcall(tool_def.func, arguments)
    if success then result = r else error_msg = tostring(r) end
  else
    error_msg = "Tool not found: " .. tool_name
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

function M.shutdown()
  state.tools = {}; state.initialized = false; state.current_iteration = 0
end

return M
