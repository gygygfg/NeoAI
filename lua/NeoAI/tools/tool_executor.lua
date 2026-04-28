-- NeoAI 工具执行器模块（事件驱动回调模式）
-- 所有工具通过回调模式执行，不阻塞主线程
--
-- 回调模式：func(args, on_success, on_error)
-- 同步模式（兼容）：func(args) -> result

local M = {}

local logger = require("NeoAI.utils.logger")
local tool_registry = require("NeoAI.tools.tool_registry")
local tool_validator = require("NeoAI.tools.tool_validator")
local event_constants = require("NeoAI.core.events")
local json = require("NeoAI.utils.json")

local state = {
  initialized = false,
  config = nil,
  execution_history = {},
  max_history_size = 100,
}

-- ========== 辅助函数 ==========

local function resolve_json_args(args)
  if args == nil then
    return args
  end
  if type(args) == "string" then
    local ok, decoded = pcall(json.decode, args)
    if ok and type(decoded) == "table" then
      return resolve_json_args(decoded)
    end
    return args
  end
  if type(args) ~= "table" then
    return args
  end
  local result = {}
  for k, v in pairs(args) do
    if type(v) == "string" then
      local ok, decoded = pcall(json.decode, v)
      result[k] = ok and resolve_json_args(decoded) or v
    elseif type(v) == "table" then
      result[k] = resolve_json_args(v)
    else
      result[k] = v
    end
  end
  return result
end

local function fire_event(pattern, data)
  vim.api.nvim_exec_autocmds("User", { pattern = pattern, data = data })
end

-- ========== 初始化 ==========

function M.initialize(config)
  if state.initialized then
    return
  end
  state.config = config or {}
  state.max_history_size = config.max_history_size or 100
  state.execution_history = {}
  state.initialized = true

  -- 预加载内置工具模块，触发它们的初始化逻辑
  -- file_tools: 无显式初始化，但预加载 file_utils 依赖
  -- neovim_lsp: ensure_lsp_init() + ensure_ts_parsers() 在模块顶层自动执行
  -- neovim_tree: 惰性检查，无需预初始化
  pcall(require, "NeoAI.tools.builtin.file_tools")
  pcall(require, "NeoAI.tools.builtin.neovim_lsp")
end

-- ========== 核心执行 ==========

function M.execute_async(tool_name, args, on_success, on_error)
  if not state.initialized then
    M.initialize({})
  end
  if not tool_name then
    if on_error then
      on_error("工具名称是必需的")
    end
    return
  end

  local start_time = os.time()
  local tool = tool_registry.get(tool_name)

  if not tool then
    local err = "工具不存在: " .. tool_name
    M._record_execution(tool_name, args, nil, err)
    fire_event(
      event_constants.TOOL_EXECUTION_ERROR,
      { tool_name = tool_name, args = args, error_msg = err, duration = 0, session_id = args and args.session_id }
    )
    if on_error then
      on_error(err)
    end
    return
  end

  local resolved_args = resolve_json_args(args)
  local valid, error_msg = M.validate_args(tool, resolved_args)
  if not valid then
    local full_msg = error_msg or "未知错误"
    local example = M._generate_example(tool)
    if example then
      full_msg = full_msg .. "\n\n调用示例:\n" .. example
    end
    M._record_execution(tool_name, args, nil, full_msg)
    fire_event(
      event_constants.TOOL_EXECUTION_ERROR,
      { tool_name = tool_name, args = args, error_msg = full_msg, duration = 0, session_id = args and args.session_id }
    )
    if on_error then
      on_error(full_msg)
    end
    return
  end

  if tool.permissions then
    local has_perm, perm_err = tool_validator.check_permissions(tool)
    if not has_perm then
      local err = perm_err or "无权限"
      M._record_execution(tool_name, args, nil, err)
      fire_event(
        event_constants.TOOL_EXECUTION_ERROR,
        { tool_name = tool_name, args = args, error_msg = err, duration = 0, session_id = args and args.session_id }
      )
      if on_error then
        on_error(err)
      end
      return
    end
  end

  fire_event(event_constants.TOOL_EXECUTION_STARTED, {
    tool_name = tool_name,
    args = args,
    start_time = start_time,
    session_id = args and args.session_id,
  })

  local function on_success_wrapper(result)
    local duration = os.time() - start_time
    local formatted = M.format_result(result)
    -- fire_event 可能被 fast event 上下文调用，用 pcall 保护
    local ok, err = pcall(fire_event, event_constants.TOOL_EXECUTION_COMPLETED, {
      tool_name = tool_name,
      args = args,
      result = formatted,
      duration = duration,
      session_id = args and args.session_id,
    })
    if not ok then
      -- fast event 上下文中 nvim_exec_autocmds 会失败，用 vim.schedule 重试
      vim.schedule(function()
        pcall(fire_event, event_constants.TOOL_EXECUTION_COMPLETED, {
          tool_name = tool_name,
          args = args,
          result = formatted,
          duration = duration,
          session_id = args and args.session_id,
        })
      end)
    end
    M._record_execution(tool_name, args, formatted, nil, duration)
    if on_success then
      on_success(formatted)
    end
  end

  local function on_error_wrapper(err_msg)
    local duration = os.time() - start_time
    local full_err = "工具执行错误: " .. (err_msg or "未知错误")
    local ok, err = pcall(fire_event, event_constants.TOOL_EXECUTION_ERROR, {
      tool_name = tool_name,
      args = args,
      error_msg = full_err,
      duration = duration,
      session_id = args and args.session_id,
    })
    if not ok then
      vim.schedule(function()
        pcall(fire_event, event_constants.TOOL_EXECUTION_ERROR, {
          tool_name = tool_name,
          args = args,
          error_msg = full_err,
          duration = duration,
          session_id = args and args.session_id,
        })
      end)
    end
    M._record_execution(tool_name, args, nil, full_err, duration)
    if on_error then
      on_error(M.handle_error(full_err))
    end
  end

  if tool.async then
    local ok, call_err = pcall(tool.func, resolved_args, on_success_wrapper, on_error_wrapper)
    if not ok then
      on_error_wrapper(tostring(call_err))
    end
  else
    -- 同步工具：通过 vim.schedule 执行，避免阻塞主线程导致停止快捷键无效
    -- 同时检查 stop_requested 状态，支持提前取消
    vim.schedule(function()
      -- 使用 pcall 延迟加载，避免循环依赖（tool_orchestrator 引用了 tool_executor）
      local orc_ok, tool_orc = pcall(require, "NeoAI.core.ai.tool_orchestrator")
      if orc_ok and tool_orc.is_stop_requested() then
        on_error_wrapper("工具执行已取消")
        return
      end
      local ok, result_or_err = pcall(tool.func, resolved_args)
      if orc_ok and tool_orc.is_stop_requested() then
        on_error_wrapper("工具执行已取消")
        return
      end
      if ok then
        on_success_wrapper(result_or_err)
      else
        on_error_wrapper(tostring(result_or_err))
      end
    end)
  end
end

function M.execute(tool_name, args)
  local result, error_msg, done = nil, nil, false
  local timeout_ms = (state.config and state.config.tool_timeout_ms) or 60000

  M.execute_async(tool_name, args, function(res)
    result = res
    done = true
  end, function(err)
    error_msg = err
    done = true
  end)

  -- 使用 vim.wait 但超时时间可配置，且仅在主线程安全时调用
  -- 注意：如果在 vim.schedule 回调中调用此函数，vim.wait 会阻塞事件循环
  -- 建议优先使用 execute_async 进行非阻塞调用
  vim.wait(timeout_ms, function()
    return done
  end, 10)

  if error_msg then
    return setmetatable({ _error = true, message = error_msg }, {
      __tostring = function()
        return error_msg
      end,
    })
  end
  return result
end

function M.batch_execute_async(executions)
  for _, exec in ipairs(executions) do
    M.execute_async(exec[1], exec[2] or {}, exec[3], exec[4])
  end
end

-- ========== 验证 ==========

function M.validate_args(tool, args)
  if not tool then
    return false, "工具定义无效"
  end
  if not tool.parameters then
    return true
  end
  return tool_validator.validate_parameters(tool.parameters, args)
end

-- ========== 格式化 ==========

function M.format_result(result)
  if result == nil then
    return "null"
  end
  local t = type(result)
  if t == "string" then
    return result
  end
  if t == "number" or t == "boolean" then
    return tostring(result)
  end
  if t == "table" then
    local ok, json_str = pcall(vim.json.encode, result)
    if ok then
      return json_str
    end
    return M._table_to_string(result)
  end
  return tostring(result)
end

function M._table_to_string(tbl)
  if not tbl or type(tbl) ~= "table" then
    return "{}"
  end
  local parts = { "{" }
  for k, v in pairs(tbl) do
    local ks = type(k) == "string" and ('"' .. k .. '"') or tostring(k)
    local vs = type(v) == "table" and M._table_to_string(v)
      or (type(v) == "string" and ('"' .. v .. '"') or tostring(v))
    table.insert(parts, "  " .. ks .. ": " .. vs)
  end
  table.insert(parts, "}")
  return table.concat(parts, "\n")
end

-- ========== 错误处理 ==========

function M.handle_error(error_msg)
  local type_map = {
    ["参数"] = "参数错误",
    ["权限"] = "权限错误",
    ["不存在"] = "资源不存在错误",
    ["未找到"] = "资源不存在错误",
    ["超时"] = "超时错误",
    ["网络"] = "网络错误",
    ["内存"] = "内存错误",
  }
  local error_type = "未知错误"
  for pattern, label in pairs(type_map) do
    if string.find(error_msg, pattern) then
      error_type = label
      break
    end
  end
  local detailed = string.format("[%s] %s\n时间: %s", error_type, error_msg, os.date("%Y-%m-%d %H:%M:%S"))
  if state.config and state.config.log_errors then
    M._log_error(detailed)
  end
  return detailed
end

function M._log_error(error_msg)
  local log_file = state.config.error_log_file
    or (vim and vim.fn.stdpath("cache") .. "/neoai_tools_error.log" or "./neoai_tools_error.log")
  local fd = vim.uv.fs_open(log_file, "a", 438)
  if fd then
    local stat = vim.uv.fs_fstat(fd)
    vim.uv.fs_write(fd, error_msg .. "\n\n", stat and stat.size or 0)
    vim.uv.fs_close(fd)
  end
end

-- ========== 历史记录 ==========

function M._record_execution(tool_name, args, result, error_msg, duration)
  table.insert(state.execution_history, {
    tool_name = tool_name,
    args = vim.deepcopy(args),
    result = result,
    error = error_msg,
    success = error_msg == nil,
    timestamp = os.time(),
    duration = duration or 0,
  })
  M.cleanup()
end

function M.cleanup()
  while #state.execution_history > state.max_history_size do
    table.remove(state.execution_history, 1)
  end
end

function M.get_execution_history(limit)
  limit = limit or state.max_history_size
  local start = math.max(1, #state.execution_history - limit + 1)
  local result = {}
  for i = start, #state.execution_history do
    table.insert(result, vim.deepcopy(state.execution_history[i]))
  end
  return result
end

function M.clear_history()
  state.execution_history = {}
end

-- ========== 配置 ==========

function M.update_config(new_config)
  if not state.initialized then
    return
  end
  state.config = vim.tbl_extend("force", state.config, new_config or {})
  state.max_history_size = state.config.max_history_size or state.max_history_size
end

-- ========== 示例生成 ==========

function M._generate_example(tool)
  if not tool or not tool.parameters or not tool.parameters.properties then
    return nil
  end
  local props = tool.parameters.properties
  local required = tool.parameters.required or {}
  local example = {}
  for _, req in ipairs(required) do
    local prop = props[req]
    if prop then
      local type_defaults =
        { string = '"<' .. req .. '>"', number = 0, integer = 0, boolean = false, array = {}, object = {} }
      example[req] = type_defaults[prop.type] or '"<' .. req .. '>"'
    end
  end
  local lines = { tool.name .. "({" }
  for k, v in pairs(example) do
    local special =
      { file = 'file = \'{"filepath": "<文件路径>"}\',', files = 'files = \'[{"filepath": "<文件路径>"}]\',' }
    table.insert(lines, special[k] or ("  " .. k .. " = " .. (type(v) == "string" and v or tostring(v)) .. ","))
  end
  table.insert(lines, "})")
  return table.concat(lines, "\n")
end

return M
