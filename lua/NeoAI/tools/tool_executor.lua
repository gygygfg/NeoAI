-- NeoAI 工具执行器模块（事件驱动回调模式）
-- 所有工具通过回调模式执行，不阻塞主线程
--
-- 回调模式：func(args, on_success, on_error, on_progress)
--   on_progress(substep_name, status, duration) -- 子步骤进度回调
-- 同步模式（兼容）：func(args) -> result

local M = {}

local logger = require("NeoAI.utils.logger")
local tool_registry = require("NeoAI.tools.tool_registry")
local tool_validator = require("NeoAI.tools.tool_validator")
local event_constants = require("NeoAI.core.events")
local json = require("NeoAI.utils.json")
local approval_handler = require("NeoAI.tools.approval_handler")

local state = {
  initialized = false,
  config = nil,
  execution_history = {},
  max_history_size = 100,
}

-- ========== 工具名称别名映射 ==========
-- 将 AI 输出的简写名称映射为正式工具名称
-- 格式：正式工具名 = { 别名列表 }
local tool_name_aliases = {
  read_file = { "read", "cat", "show", "view" },
  edit_file = { "write", "edit", "modify", "update" },
  list_files = { "list", "ls", "dir" },
  search_files = { "search", "grep", "find", "locate" },
  delete_file = { "delete", "rm", "remove", "unlink" },
  create_directory = { "mkdir", "md", "mkdirp", "mk_dir" },
  ensure_dir = { "ensure_dir" },
  file_exists = { "exists" },
  run_command = { "cmd" },
}

-- ========== 参数别名映射 ==========
-- 将 AI 常用的简写参数名映射到工具定义的标准参数名
-- 统一管理，避免两处重复定义
local param_alias_map = {
  -- 参数别名: 正式工具名 = { 别名列表 }
  command = { "cmd" },
  dirs = { "dir", "dir_path" },
  filepath = { "file", "files", "fp", "path", "filespath" },
  -- 参数名重命名（start/end 统一为 start_line/end_line 以规避 Lua 关键字）
  start_line = { "start" },
  end_line = { "end" },
}

-- 构建别名→正式名的反向查找表
local alias_to_tool_name = {}

-- 构建参数别名→正式名的反向查找表
local alias_to_param_name = {}
for tool_name, aliases in pairs(tool_name_aliases) do
  for _, alias in ipairs(aliases) do
    alias_to_tool_name[alias] = tool_name
  end
end

-- 构建参数别名反向查找表
for std_name, aliases in pairs(param_alias_map) do
  for _, alias in ipairs(aliases) do
    alias_to_param_name[alias] = std_name
  end
end

-- ========== 超时管理 ==========

local timeout_state = {
  timers = {}, -- tool_call_id -> timer
  start_times = {}, -- tool_call_id -> os.time()
  timeout_ms = 30000, -- 默认 30 秒（会被 initialize 中的 config.tool_timeout_ms 覆盖）
  saved_timeouts = {}, -- tool_call_id -> { timeout_ms, on_timeout } 暂停时保存的原始超时信息
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
      -- 只对 JSON 对象/数组字符串（以 { 或 [ 开头）进行解码
      -- 避免将普通字符串（如 "所有22个工具"）误解析为 number
      local trimmed = v:match("^%s*(.-)%s*$") or v
      if trimmed:sub(1, 1) == "{" or trimmed:sub(1, 1) == "[" then
        local ok, decoded = pcall(json.decode, v)
        result[k] = ok and resolve_json_args(decoded) or v
      else
        result[k] = v
      end
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

  -- 从配置读取工具调用超时（默认 30 秒）
  timeout_state.timeout_ms = (config.tool_timeout_ms or 30) * 1000

  -- 初始化 tool_validator（审批检查依赖它）
  local tv = require("NeoAI.tools.tool_validator")
  pcall(tv.initialize, config)

  -- 预加载内置工具模块，触发它们的初始化逻辑
  -- file_tools: 无显式初始化，但预加载 file_utils 依赖
  -- neovim_lsp: ensure_lsp_init() + ensure_ts_parsers() 在模块顶层自动执行
  -- neovim_tree: 惰性检查，无需预初始化
  pcall(require, "NeoAI.tools.builtin.file_tools")
  pcall(require, "NeoAI.tools.builtin.neovim_lsp")

  -- 应用审批配置覆盖
  -- 从合并后的完整配置中读取 tools.approval 并覆盖各工具的 approval 字段
  local tools_init = require("NeoAI.tools")
  local full_config = tools_init.get_full_config()
  if full_config then
    local tr = require("NeoAI.tools.tool_registry")
    pcall(tr.apply_approval_config, full_config)
  end
end

-- ========== 核心执行 ==========

function M.execute_async(tool_name, args, on_success, on_error, on_progress)
  if not state.initialized then
    M.initialize({})
  end

  -- 参数检查
  if not tool_name then
    logger.warn("[tool_executor] execute_async: tool_name 为空")
    if on_error then
      on_error("工具名称是必需的")
    end
    return
  end
  if type(tool_name) ~= "string" then
    logger.warn("[tool_executor] execute_async: tool_name 类型错误，期望 string，实际为 %s", type(tool_name))
    if on_error then
      on_error("工具名称必须是字符串")
    end
    return
  end
  if not on_success then
    logger.warn("[tool_executor] execute_async: 工具 '%s' 的 on_success 回调为空", tool_name)
  end
  if not on_error then
    logger.warn("[tool_executor] execute_async: 工具 '%s' 的 on_error 回调为空", tool_name)
  end

  local start_time = os.time()
  local tool = tool_registry.get(tool_name)

  if not tool then
    -- 假装识别到了工具，返回可用工具列表作为执行结果
    local tp_ok, tp = pcall(require, "NeoAI.tools.tool_pack")
    local available_tools = {}
    if tp_ok then
      available_tools = tp.get_all_tool_names()
    else
      local all_tools = tool_registry.list()
      for _, t in ipairs(all_tools) do
        table.insert(available_tools, t.name)
      end
      table.sort(available_tools)
    end

    local tool_list_str = table.concat(available_tools, ", ")
    local result = string.format(
      "[工具执行结果] 未定义的工具: %s\n\n当前可用工具列表: [%s]\n请从以上列表中选择正确的工具名称重新调用。",
      tool_name,
      tool_list_str
    )
    M._record_execution(tool_name, args, result, nil, 0)
    fire_event(event_constants.TOOL_EXECUTION_COMPLETED, {
      tool_name = tool_name,
      args = args,
      result = result,
      duration = 0,
      session_id = args and (args.session_id or args._session_id),
    })
    if on_success then
      on_success(result)
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
    fire_event(event_constants.TOOL_EXECUTION_ERROR, {
      tool_name = tool_name,
      args = args,
      error_msg = full_msg,
      duration = 0,
      session_id = args and (args.session_id or args._session_id),
    })
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
      fire_event(event_constants.TOOL_EXECUTION_ERROR, {
        tool_name = tool_name,
        args = args,
        error_msg = err,
        duration = 0,
        session_id = args and (args.session_id or args._session_id),
      })
      if on_error then
        on_error(err)
      end
      return
    end
  end

  -- 获取工具所属包名
  local pack_name = nil
  local tp_ok, tp = pcall(require, "NeoAI.tools.tool_pack")
  if tp_ok then
    pack_name = tp.get_pack_for_tool(tool_name)
  end

  -- ===== 工具审批检查 =====
  -- 子 agent 的工具调用跳过审批：已通过 plan_executor.review_tool_call 边界审核
  local resolved_args_check = resolved_args or {}
  local is_sub_agent_call = resolved_args_check._sub_agent_id ~= nil

  local needs_user_approval = false
  if not is_sub_agent_call then
    -- 委托给 approval_handler
    local check_ok, check_result = pcall(tool_validator.check_approval, tool_name, resolved_args, tool_registry)
    needs_user_approval = check_ok and check_result and check_result.auto_allow == false
  end

  if needs_user_approval then
    local session_id = args and (args.session_id or args._session_id) or ""
    approval_handler.enqueue({
      tool_name = tool_name,
      resolved_args = resolved_args,
      raw_args = args,
      on_success = on_success,
      on_error = on_error,
      on_progress = on_progress,
      start_time = start_time,
      pack_name = pack_name,
      session_id = session_id,
    })

    fire_event(event_constants.TOOL_EXECUTION_STARTED, {
      tool_name = tool_name,
      pack_name = pack_name,
      args = args,
      start_time = start_time,
      session_id = session_id,
    })

    -- 注册暂停回调：审批窗口打开时暂停超时，关闭时恢复
    local tool_call_id = args and args._tool_call_id or ("call_" .. os.time() .. "_" .. math.random(10000, 99999))
    local unregister = approval_handler.register_pause_callback(function(is_paused)
      if is_paused then
        -- 暂停超时：停止定时器
        M._clear_timeout(tool_call_id)
      else
        -- 恢复超时：重新设置定时器（用剩余时间）
        local tool_def = tool_registry.get(tool_name)
        local tool_timeout = tool_def and tool_def.timeout
        local timeout_ms
        if tool_timeout == -1 then
          timeout_ms = -1
        elseif tool_timeout ~= nil then
          timeout_ms = tool_timeout
        else
          timeout_ms = timeout_state.timeout_ms
        end
        if timeout_ms and timeout_ms > 0 then
          M._set_timeout(tool_call_id, timeout_ms, function()
            logger.warn("[tool_executor] 工具 '%s' 执行超时 (%dms)", tool_name, timeout_ms)
            if on_error then
              on_error(string.format("工具执行超时（%d 秒）", timeout_ms / 1000))
            end
          end)
        end
      end
    end)

    return
  end

  -- ===== 发射 TOOL_EXECUTION_STARTED 事件 =====
  -- 注意：如果需要用户审批，该事件已在审批检查分支中提前发射
  -- 这里只在非审批路径发射
  fire_event(event_constants.TOOL_EXECUTION_STARTED, {
    tool_name = tool_name,
    pack_name = pack_name,
    args = args,
    start_time = start_time,
    session_id = args and (args.session_id or args._session_id),
  })

  -- 继续执行（提取为单独函数，供审批回调复用）
  M._continue_execution(tool_name, resolved_args, args, on_success, on_error, on_progress, start_time, pack_name)
end

--- 继续执行工具（在审批通过后调用）
--- 提取自 execute_async，供审批回调复用
function M._continue_execution(
  tool_name,
  resolved_args,
  raw_args,
  on_success,
  on_error,
  on_progress,
  start_time,
  pack_name
)
  -- 检查会话是否仍然有效（防止审批通过后会话已超时或取消）
  local session_id = raw_args and (raw_args.session_id or raw_args._session_id) or ""
  if session_id and session_id ~= "" then
    local orc_ok, tool_orc = pcall(require, "NeoAI.core.ai.tool_orchestrator")
    if orc_ok then
      -- 检查会话是否已被 unregister（会话不存在）
      local session_state = tool_orc.get_session_state(session_id)
      if session_state == nil then
        if on_error then
          on_error("工具执行已取消：会话已关闭")
        end
        return
      end
      -- 检查会话是否已请求停止
      if tool_orc.is_stop_requested(session_id) then
        if on_error then
          on_error("工具执行已取消：会话已停止")
        end
        return
      end
    end
  end

  local tool = tool_registry.get(tool_name)
  if not tool then
    if on_error then
      on_error("工具已不存在: " .. tool_name)
    end
    return
  end

  local function on_success_wrapper(result)
    local duration = os.time() - start_time
    local formatted = M.format_result(result)
    local ok, err = pcall(fire_event, event_constants.TOOL_EXECUTION_COMPLETED, {
      tool_name = tool_name,
      pack_name = pack_name,
      args = raw_args,
      result = formatted,
      duration = duration,
      session_id = raw_args and (raw_args.session_id or raw_args._session_id),
    })
    if not ok then
      vim.schedule(function()
        pcall(fire_event, event_constants.TOOL_EXECUTION_COMPLETED, {
          tool_name = tool_name,
          pack_name = pack_name,
          args = raw_args,
          result = formatted,
          duration = duration,
          session_id = raw_args and (raw_args.session_id or raw_args._session_id),
        })
      end)
    end
    M._record_execution(tool_name, raw_args, formatted, nil, duration)
    if on_success then
      on_success(formatted)
    end
  end

  local function on_error_wrapper(err_msg)
    local duration = os.time() - start_time
    local err_str = type(err_msg) == "table" and vim.inspect(err_msg) or tostring(err_msg or "未知错误")
    local full_err = "工具执行错误: " .. err_str
    local ok, err = pcall(fire_event, event_constants.TOOL_EXECUTION_ERROR, {
      tool_name = tool_name,
      pack_name = pack_name,
      args = raw_args,
      error_msg = full_err,
      duration = duration,
      session_id = raw_args and (raw_args.session_id or raw_args._session_id),
    })
    if not ok then
      vim.schedule(function()
        pcall(fire_event, event_constants.TOOL_EXECUTION_ERROR, {
          tool_name = tool_name,
          pack_name = pack_name,
          args = raw_args,
          error_msg = full_err,
          duration = duration,
          session_id = raw_args and (raw_args.session_id or raw_args._session_id),
        })
      end)
    end
    M._record_execution(tool_name, raw_args, nil, full_err, duration)
    if on_error then
      on_error(M.handle_error(full_err))
    end
  end

  local function progress_wrapper(substep_name, status, duration, detail)
    local _tool_name = tool_name
    local _pack_name = pack_name
    local _substep_name = substep_name
    local _status = status
    local _duration = duration or 0
    local _detail = detail
    local _session_id = raw_args and (raw_args.session_id or raw_args._session_id)

    local ok, err = pcall(fire_event, event_constants.TOOL_EXECUTION_SUBSTEP, {
      tool_name = _tool_name,
      pack_name = _pack_name,
      substep_name = _substep_name,
      status = _status,
      duration = _duration,
      detail = _detail,
      session_id = _session_id,
    })
    if not ok then
      vim.schedule(function()
        pcall(fire_event, event_constants.TOOL_EXECUTION_SUBSTEP, {
          tool_name = _tool_name,
          pack_name = _pack_name,
          substep_name = _substep_name,
          status = _status,
          duration = _duration,
          detail = _detail,
          session_id = _session_id,
        })
      end)
    end
    if on_progress then
      local ok2, err2 = pcall(on_progress, _substep_name, _status, _duration, _detail)
      if not ok2 then
        vim.schedule(function()
          pcall(on_progress, _substep_name, _status, _duration, _detail)
        end)
      end
    end
  end

  if tool.async then
    local ok, call_err = pcall(tool.func, resolved_args, on_success_wrapper, on_error_wrapper, progress_wrapper)
    if not ok then
      on_error_wrapper(tostring(call_err))
    end
  else
    vim.schedule(function()
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
  local timeout_ms = timeout_state.timeout_ms
  local elapsed_ms = 0
  local poll_interval_ms = 50
  local paused_during_wait = 0 -- 等待期间累计的暂停时长
  local was_paused = false
  local pause_check_start = nil

  M.execute_async(tool_name, args, function(res)
    result = res
    done = true
  end, function(err)
    error_msg = err
    done = true
  end)

  -- 检测 headless 模式
  -- 使用 vim.api.nvim_list_uis() 是最可靠的检测方式
  -- 在 headless 模式下，nvim_list_uis() 返回空表 {}
  -- 注意：vim.env.NVIM_HEADLESS 可能为 nil，vim.g.colors_name 可能被 colorscheme 插件设置
  local uis = vim.api.nvim_list_uis()
  local is_headless = #uis == 0 or vim.env.NVIM_HEADLESS == "1"

  if is_headless then
    -- headless 模式下使用 vim.wait（能正确处理 vim.schedule 回调）
    -- vim.uv.run('once') 在 headless 模式下无法处理 vim.schedule 回调
    local wait_timeout = timeout_ms + 30000
    vim.wait(wait_timeout, function()
      if done then
        return true
      end
      return false
    end, poll_interval_ms)
    if not done and not error_msg then
      error_msg = string.format("工具执行超时（%d 秒）", timeout_ms / 1000)
    end
  else
    -- 正常模式下使用 vim.wait
    -- 增强版：感知审批暂停，暂停期间不计入超时
    local wait_timeout = timeout_ms + 30000 -- 最多多给 30 秒缓冲
    vim.wait(wait_timeout, function()
      if done then
        return true
      end

      -- 检查审批暂停状态
      if approval_handler.is_paused() then
        if not was_paused then
          was_paused = true
          pause_check_start = vim.loop.hrtime()
        end
        return false
      else
        if was_paused then
          if pause_check_start then
            local pause_ns = vim.loop.hrtime() - pause_check_start
            paused_during_wait = paused_during_wait + pause_ns
          end
          was_paused = false
          pause_check_start = nil
        end
      end

      local now = vim.loop.hrtime()
      if not M._execute_start_time then
        M._execute_start_time = now
      end
      local actual_elapsed_ns = now - M._execute_start_time - paused_during_wait
      elapsed_ms = actual_elapsed_ns / 1000000

      if elapsed_ms >= timeout_ms then
        error_msg = string.format("工具执行超时（%d 秒）", timeout_ms / 1000)
        return true
      end

      return false
    end, poll_interval_ms)
  end

  -- 清理起始时间
  M._execute_start_time = nil

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

-- ========== 审批队列处理 ==========

--- 处理审批队列
-- 审批队列处理已迁移到 approval_handler.lua
-- 保留空函数引用以保持向后兼容
function M._process_approval_queue()
  approval_handler.process_queue()
end

function M._show_approval_dialog(item)
  -- 已迁移到 approval_handler.lua
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

-- ========== 审批队列管理 ==========

--- 清空审批队列（委托给 approval_handler）
function M.clear_approval_queue()
  approval_handler.clear_queue()
end

-- ========== 配置 ==========

function M.update_config(new_config)
  if not state.initialized then
    return
  end
  state.config = vim.tbl_extend("force", state.config, new_config or {})
  state.max_history_size = state.config.max_history_size or state.max_history_size
end

--- 设置工具超时
--- @param tool_call_id string 工具调用 ID
--- @param timeout_ms number 超时毫秒数
--- @param on_timeout function 超时回调
function M._set_timeout(tool_call_id, timeout_ms, on_timeout)
  if timeout_ms <= 0 then
    return
  end
  -- 清除旧定时器
  M._clear_timeout(tool_call_id)
  -- 保存超时信息供 _resume_timeout 使用
  timeout_state.saved_timeouts[tool_call_id] = {
    timeout_ms = timeout_ms,
    on_timeout = on_timeout,
  }
  timeout_state.start_times[tool_call_id] = vim.loop.hrtime()
  timeout_state.timers[tool_call_id] = vim.defer_fn(function()
    timeout_state.timers[tool_call_id] = nil
    timeout_state.start_times[tool_call_id] = nil
    timeout_state.saved_timeouts[tool_call_id] = nil
    if on_timeout then
      pcall(on_timeout)
    end
  end, timeout_ms)
end

--- 清除工具超时
--- @param tool_call_id string 工具调用 ID
function M._clear_timeout(tool_call_id)
  if timeout_state.timers[tool_call_id] then
    local timer = timeout_state.timers[tool_call_id]
    -- vim.defer_fn 返回的是 uv_timer_t 对象
    -- 在 Neovim 0.10+ 中推荐使用 vim.uv 方法
    pcall(function()
      if timer:is_active() then
        timer:stop()
      end
      if not timer:is_closing() then
        timer:close()
      end
    end)
    timeout_state.timers[tool_call_id] = nil
  end
  timeout_state.start_times[tool_call_id] = nil
  timeout_state.saved_timeouts[tool_call_id] = nil
end

--- 暂停工具超时（保留已过去的时间，停止定时器）
--- 用于 shell 交互式命令等待 AI 输入时暂停超时
--- @param tool_call_id string 工具调用 ID
function M._pause_timeout(tool_call_id)
  if not timeout_state.timers[tool_call_id] then
    return
  end
  local timer = timeout_state.timers[tool_call_id]
  pcall(function()
    if timer:is_active() then
      timer:stop()
    end
  end)
end

--- 恢复工具超时（重新启动定时器，使用剩余时间）
--- 用于 shell 交互式命令收到 AI 输入后恢复超时
--- @param tool_call_id string 工具调用 ID
--- @param on_timeout function|nil 超时回调（不传则使用 saved_timeouts 中保存的回调）
function M._resume_timeout(tool_call_id, on_timeout)
  local saved = timeout_state.saved_timeouts[tool_call_id]
  if not saved then
    return
  end
  local start = timeout_state.start_times[tool_call_id]
  if not start then
    return
  end
  -- 关闭旧定时器
  local timer = timeout_state.timers[tool_call_id]
  if timer then
    pcall(function()
      if timer:is_active() then
        timer:stop()
      end
      if not timer:is_closing() then
        timer:close()
      end
    end)
  end
  -- 计算剩余时间
  local now = vim.loop.hrtime()
  local elapsed_ns = now - start
  local elapsed_ms = elapsed_ns / 1e6
  local remaining_ms = saved.timeout_ms - elapsed_ms
  if remaining_ms <= 0 then
    remaining_ms = 1
  end
  -- 使用传入的回调或保存的回调
  local cb = on_timeout or saved.on_timeout
  -- 创建新定时器
  timeout_state.timers[tool_call_id] = vim.defer_fn(function()
    timeout_state.timers[tool_call_id] = nil
    timeout_state.start_times[tool_call_id] = nil
    timeout_state.saved_timeouts[tool_call_id] = nil
    if cb then
      pcall(cb)
    end
  end, remaining_ms)
end

--- 重置工具超时（清除旧超时，设置新超时）
--- 供 run_command 在运行时根据 timeout 参数动态更新超时
--- @param tool_call_id string 工具调用 ID
--- @param timeout_ms number 新的超时毫秒数
--- @param on_timeout function 超时回调
function M._reset_timeout(tool_call_id, timeout_ms, on_timeout)
  if timeout_ms <= 0 then
    return
  end
  -- 清除旧定时器（保留 start_time）
  if timeout_state.timers[tool_call_id] then
    local timer = timeout_state.timers[tool_call_id]
    pcall(function()
      if timer:is_active() then
        timer:stop()
      end
      if not timer:is_closing() then
        timer:close()
      end
    end)
    timeout_state.timers[tool_call_id] = nil
  end
  -- 设置新定时器
  timeout_state.timers[tool_call_id] = vim.defer_fn(function()
    timeout_state.timers[tool_call_id] = nil
    timeout_state.start_times[tool_call_id] = nil
    if on_timeout then
      pcall(on_timeout)
    end
  end, timeout_ms)
end

--- 获取工具已执行时长（毫秒，扣除审批暂停时间）
--- @param tool_call_id string 工具调用 ID
--- @return number 已执行毫秒数
function M._get_elapsed_ms(tool_call_id)
  local start = timeout_state.start_times[tool_call_id]
  if not start then
    return 0
  end
  local now = vim.loop.hrtime()
  local elapsed_ns = now - start
  -- 扣除审批暂停时间
  local paused_sec = approval_handler.get_total_paused_duration()
  local paused_ns = paused_sec * 1000000000
  elapsed_ns = math.max(0, elapsed_ns - paused_ns)
  return elapsed_ns / 1000000
end

-- ========== 参数规范化（从 tool_orchestrator 迁移） ==========

--- 解析并规范化工具参数
--- arguments 已在 http_client 中解析为 Lua table
--- 包含别名映射、简化参数格式转换
--- @param raw_arguments table|string 原始参数
--- @param props table 工具定义的属性名表
--- @param tool_name string 工具名称（仅用于日志）
--- @return table|nil 解析后的参数表，失败返回 nil
function M._parse_nonstandard_arguments(raw_arguments, props, tool_name)
  local arguments = {}
  local lines = {}
  for line in (raw_arguments .. ""):gmatch("[^\n]+") do
    table.insert(lines, line)
  end
  if #lines == 0 then
    return nil
  end

  local parsed_count = 0
  for _, line in ipairs(lines) do
    -- 跳过空行和注释行
    local trimmed = line:match("^%s*(.-)%s*$") or ""
    if trimmed == "" or trimmed:find("^[#/]+") then
      goto continue
    end

    -- 尝试匹配 key: value 或 key = value 格式
    -- 支持值带引号或不带引号
    local k, v = trimmed:match("^([%w_]+)%s*[:=]%s*(.+)$")
    if not k then
      goto continue
    end

    -- 去除值首尾的引号（单引号或双引号）
    v = v:match("^%s*['\"](.-)['\"]%s*$") or v:match("^%s*(.-)%s*$")

    -- 尝试匹配工具定义的属性名（包括别名）
    local matched_key = nil
    if props[k] then
      matched_key = k
    else
      local std_name = param_alias_map[k]
      if std_name and props[std_name] then
        matched_key = std_name
      end
    end

    if matched_key then
      arguments[matched_key] = v
      parsed_count = parsed_count + 1
    end
    ::continue::
  end

  if parsed_count > 0 then
    logger.warn(
      "[tool_executor] _parse_nonstandard_arguments: 工具 '%s' 使用非标准格式解析了 %d 个参数",
      tool_name,
      parsed_count
    )
    return arguments
  end

  return nil
end

--- 规范化工具名称（别名映射）
--- 供 tool_orchestrator 在工具执行前调用
--- @param tool_name string 原始工具名称
--- @return string|nil, boolean 规范化后的工具名称，是否发生变更
function M._normalize_tool_name(tool_name)
  local mapped_name = alias_to_tool_name[tool_name]
  if mapped_name then
    return mapped_name, true
  end
  return tool_name, false
end

--- @param tool_name string 工具名称
--- @param raw_arguments string|table 原始参数
--- @return table, boolean 规范化后的参数，是否发生变更
function M._normalize_arguments(tool_name, raw_arguments)
  if not raw_arguments then
    return {}, false
  end

  local arguments = {}
  local changed = false

  -- ===== 工具名称别名映射（使用模块级反向查找表） =====
  local mapped_name = alias_to_tool_name[tool_name]
  if mapped_name then
    logger.debug("[tool_executor] _normalize_arguments: 工具名称别名映射: '%s' -> '%s'", tool_name, mapped_name)
    tool_name = mapped_name
    changed = true
  end

  -- 获取工具定义（用于后续参数名匹配和格式转换）
  pcall(tool_registry.initialize, {})
  local tool_def = tool_registry.get(tool_name)
  local props = tool_def and tool_def.parameters and tool_def.parameters.properties or {}

  -- ===== 参数解析 =====
  -- arguments 已在 http_client 中解析为 Lua table，直接使用

  if type(raw_arguments) == "table" then
    arguments = vim.deepcopy(raw_arguments)
  elseif type(raw_arguments) == "string" then
    -- 防御性：如果仍为字符串（历史消息），尝试 JSON 解析
    local ok, parsed = pcall(vim.json.decode, raw_arguments)
    if ok and type(parsed) == "table" then
      arguments = parsed
      changed = true
    else
      -- 尝试修复被截断的 JSON
      local fixed = raw_arguments
      local repaired = false
      local ok_check, _ = pcall(vim.json.decode, fixed)
      if not ok_check then
        local ends_with_quote = fixed:match('"$')
        local ends_with_brace = fixed:match("}$")
        if not ends_with_brace and not ends_with_quote then
          fixed = fixed .. '"'
          repaired = true
        end
        if not fixed:match("}$") then
          local open_braces = select(2, fixed:gsub("{", ""))
          local close_braces = select(2, fixed:gsub("}", ""))
          if open_braces > close_braces then
            fixed = fixed .. string.rep("}", open_braces - close_braces)
            repaired = true
          end
        end
      end
      if repaired then
        local ok3, parsed3 = pcall(vim.json.decode, fixed)
        if ok3 and type(parsed3) == "table" then
          logger.warn("[tool_executor] 工具 '%s' 的 arguments JSON 被截断，已修复", tool_name)
          arguments = parsed3
          changed = true
        end
      end
      if not arguments or not next(arguments) then
        arguments = M._parse_nonstandard_arguments(raw_arguments, props, tool_name)
        if arguments and next(arguments) then
          changed = true
        else
          logger.warn(
            "[tool_executor] 工具 '%s' 的 arguments 解析失败: %s",
            tool_name,
            tostring(raw_arguments):sub(1, 300)
          )
          return { _raw = raw_arguments }, false
        end
      end
    end
  else
    return { _raw = tostring(raw_arguments) }, false
  end

  -- ===== 通用参数规范化 =====
  if tool_def and tool_def.parameters and tool_def.parameters.properties then
    -- 1) 参数别名映射
    -- 将 AI 常用的简写参数名映射到工具定义的标准参数名
    -- 即使别名参数也存在于 props 中（如 run_command 同时有 command 和 cmd），
    -- 也优先使用标准名称，确保必需字段验证通过
    -- 注意：跳过数组标准名（filepath/dirs）的别名，这些由步骤2的简化格式转换处理
    local array_standard_names = { filepath = true, dirs = true }
    for arg_name, arg_value in pairs(arguments) do
      local standard_name = alias_to_param_name[arg_name]
      if
        standard_name
        and not array_standard_names[standard_name]
        and props[standard_name]
        and arg_name ~= standard_name
      then
        arguments[standard_name] = arg_value
        arguments[arg_name] = nil
        changed = true
      end
    end

    -- 2) 简化参数格式转换
    -- 当 AI 传入的简化参数名（如 file/files）映射到标准数组参数（filepath）时，
    -- 且该参数在工具定义中不存在、但对应的数组参数存在时，触发简化格式转换
    -- 例如：file="foo.lua" → filepath={{filepath="foo.lua"}}
    for simple_arg, arg_value in pairs(arguments) do
      local standard_name = alias_to_param_name[simple_arg]
      if standard_name and array_standard_names[standard_name] and not props[simple_arg] and props[standard_name] then
        local item = {}
        if standard_name == "filepath" then
          item.filepath = arg_value
          -- 从 arguments 中继承相关字段到 item
          local inherit_fields = { "start_line", "end_line", "content", "append", "parents", "pattern", "recursive" }
          for _, field in ipairs(inherit_fields) do
            if arguments[field] ~= nil then
              item[field] = arguments[field]
              arguments[field] = nil
            end
          end
        elseif standard_name == "dirs" then
          item.dir = arg_value
          local inherit_fields = { "pattern", "recursive" }
          for _, field in ipairs(inherit_fields) do
            if arguments[field] ~= nil then
              item[field] = arguments[field]
              arguments[field] = nil
            end
          end
        end
        arguments[standard_name] = { item }
        arguments[simple_arg] = nil
        changed = true
        break
      end
    end
  end

  return arguments, changed
end

-- ========== 带编排的工具执行 ==========

--- 供 tool_orchestrator 调用的工具执行接口
--- 集中处理参数规范化、超时管理、事件发射
--- @param tool_name string 工具名称
--- @param raw_args string|table 原始参数（来自 AI 响应）
--- @param session_context table 会话上下文 { session_id, window_id, generation_id, tool_call_id, pack_name }
--- @param callbacks table 回调 { on_result(success, result), on_progress(substep_name, status, duration, detail) }
function M.execute_with_orchestrator(tool_name, raw_args, session_context, callbacks)
  callbacks = callbacks or {}
  session_context = session_context or {}

  -- 参数规范化
  local arguments, args_changed = M._normalize_arguments(tool_name, raw_args)

  -- 注入会话上下文
  if session_context.session_id then
    arguments._session_id = session_context.session_id
  end
  if session_context.tool_call_id then
    arguments._tool_call_id = session_context.tool_call_id
  end

  -- 发射 TOOL_EXECUTION_STARTED 事件
  fire_event(event_constants.TOOL_EXECUTION_STARTED, {
    tool_name = tool_name,
    arguments = arguments,
    pack_name = session_context.pack_name,
    session_id = session_context.session_id,
    window_id = session_context.window_id,
    generation_id = session_context.generation_id,
  })

  -- 从工具注册信息读取超时配置
  -- timeout 字段：nil 使用全局默认（30 秒），-1 表示无限等待（如 run_command）
  local tool_call_id = session_context.tool_call_id or ("call_" .. os.time() .. "_" .. math.random(10000, 99999))
  local original_on_result = callbacks.on_result
  local wrapped_on_success, wrapped_on_error

  local tool_def = tool_registry.get(tool_name)
  local tool_timeout = tool_def and tool_def.timeout
  local timeout_ms
  if tool_timeout == -1 then
    timeout_ms = -1 -- 无限等待，不设超时
  elseif tool_timeout ~= nil then
    timeout_ms = tool_timeout -- 工具自定义超时
  else
    timeout_ms = timeout_state.timeout_ms -- 全局默认超时
  end

  if timeout_ms and timeout_ms > 0 then
    M._set_timeout(tool_call_id, timeout_ms, function()
      logger.warn("[tool_executor] 工具 '%s' 执行超时 (%dms)", tool_name, timeout_ms)
      if callbacks.on_result then
        callbacks.on_result(false, string.format("工具执行超时（%d 秒）", timeout_ms / 1000))
      end
    end)

    -- 包装 on_success/on_error 以清除超时
    wrapped_on_success = function(result)
      M._clear_timeout(tool_call_id)
      if original_on_result then
        original_on_result(true, result)
      end
    end
    wrapped_on_error = function(err)
      M._clear_timeout(tool_call_id)
      if original_on_result then
        original_on_result(false, err)
      end
    end
  else
    -- 不设超时（timeout_ms 为 nil 或 -1）
    wrapped_on_success = function(result)
      if original_on_result then
        original_on_result(true, result)
      end
    end
    wrapped_on_error = function(err)
      if original_on_result then
        original_on_result(false, err)
      end
    end
  end

  -- 调用 execute_async
  M.execute_async(tool_name, arguments, wrapped_on_success, wrapped_on_error, callbacks.on_progress)
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
