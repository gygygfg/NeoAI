--- 工具执行器
--- @module NeoAI.tools.executor
--- 参数规范化 + 校验 + 审批 + 执行（异步）+ 超时。
--- 执行结果统一转为字符串（供 Agent 回传）。

local async = require("NeoAI.utils.async")
local tool_timer = require("NeoAI.utils.timer")
local json = require("NeoAI.utils.json")
local registry = require("NeoAI.tools.registry")
local validator = require("NeoAI.tools.validator")
local config_store = require("NeoAI.kernel.config_store")
local fs = require("NeoAI.utils.fs")

local M = {}

-- ========== 私有函数 ==========

--- 参数别名规范化
--- @param tool_name string
--- @param args table
--- @return table 规范化后的参数
local function _normalize_arguments(tool_name, args)
  if type(args) ~= "table" then
    -- 简单字符串参数：转成 filepath（针对 read_file 等）
    if tool_name == "read_file" or tool_name == "edit_file" or tool_name == "delete_file" then
      return { filepath = tostring(args) }
    end
    return {}
  end
  local normalized = vim.deepcopy(args)
  local aliases = {
    cmd = "command", file = "filepath", files = "filepath",
    start = "start_line", ["end"] = "end_line",
    dir = "dirs", dir_path = "dirs", dirs = "dirs",
    content = "content", new_text = "content", text = "content",
  }
  for k, target in pairs(aliases) do
    if normalized[k] ~= nil and normalized[target] == nil then
      normalized[target] = normalized[k]
      normalized[k] = nil
    end
  end
  return normalized
end

-- 携带路径语义的参数名：进入工具前展开 ~ / $VAR（与内容/文本类参数区分开，
-- 避免把 description/content/query 等误当成路径）。
local PATH_KEYS = { "path", "filepath", "file_path", "dirs", "dir" }

--- 展开参数中路径型字段的 ~ 别名，使 ~/... 等相对主目录的路径可正常读写
--- @param args table
--- @return table
local function _expand_path_args(args)
  if type(args) ~= "table" then return args end
  for _, k in ipairs(PATH_KEYS) do
    if type(args[k]) == "string" then
      args[k] = fs.expand(args[k])
    end
  end
  return args
end

--- 统一执行工具函数
--- 支持三种形式：tool.func(...) / tool.execute(ctx) / 同步或异步回调
--- @param tool table
--- @param args table
--- @param ctx table { agent, tool_call_id, signal, is_sub_agent }
--- @return Deferred resolve(结果)
local function _call_tool(tool, args, ctx)
  local d = async.Deferred.new()
  local done = false
  local function finish(ok, value)
    if done then return end
    done = true
    if ok then
      d:resolve(value)
    else
      d:reject(value)
    end
  end

  local function on_success(result)
    finish(true, result)
  end
  local function on_error(err)
    finish(false, err)
  end

  local ok, err
  if tool.func then
    -- 回调风格：func(args, on_success, on_error)
    local arity = debug.getinfo(tool.func).nparams
    if arity >= 2 then
      ok, err = pcall(tool.func, args, on_success, on_error, ctx)
    else
      ok, err = pcall(tool.func, args, ctx)
      if ok then
        -- 若返回 Deferred
        if type(err) == "table" and err.then_ then
          err:then_(on_success, on_error)
        else
          finish(true, err)
        end
      else
        finish(false, err)
      end
    end
  elseif tool.execute then
    ok, err = pcall(tool.execute, { args = args, ctx = ctx, on_success = on_success, on_error = on_error })
  else
    finish(false, "工具没有可执行的 func")
  end

  if ok == false then
    finish(false, err)
  end

  return d
end

--- 执行工具并基于"活跃时间"做超时。
--- 用可暂停计时器（ctx.timer）替代固定墙钟超时：等待用户审批/提问的暂停期间
--- 不累计耗时、不消耗超时预算。无 ctx.timer 时（直接调用）自建一个。
--- @param tool table
--- @param args table
--- @param ctx table
--- @param timer table 可暂停计时器
--- @return Deferred
local function _execute_tool_raw(tool, args, ctx, timer)
  local timeout = ctx.timeout_ms or tool.timeout or config_store.get("tools.executor.timeout_ms") or 30000
  local wrapped = async.Deferred.new()
  local settled = false
  -- 先设置超时回调再 start：budget<=0 时 start 会同步触发超时，避免回调缺失。
  timer.on_timeout = function()
    if settled then return end
    settled = true
    wrapped:reject({ kind = "timeout", message = "工具执行超时 (" .. tostring(timeout) .. "ms)" })
  end
  timer:start(timeout)
  local d = _call_tool(tool, args, ctx)
  d:then_(function(v)
    if settled then return end
    settled = true
    timer:stop()
    wrapped:resolve(v)
  end, function(e)
    if settled then return end
    settled = true
    timer:stop()
    wrapped:reject(e)
  end)
  return wrapped
end

--- 沙箱门禁包装：所有工具执行必须经控制面。
--- 沙箱服务缺失且 fail_closed 时拒绝执行（不得静默降级，设计文档 §1.1 第 6/7 条）。
--- @param tool table
--- @param args table
--- @param ctx table
--- @param timer table
--- @return Deferred
local function _execute_tool(tool, args, ctx, timer)
  local cfg = config_store.get("tools.sandbox") or {}
  local sandbox = require("NeoAI.kernel.services").use("services.sandbox")
  if not sandbox then
    if cfg.enabled ~= false and cfg.fail_closed ~= false then
      return async.reject({
        kind = "sandbox",
        message = "沙箱服务不可用且 fail_closed=true，拒绝执行工具: " .. tostring(tool and tool.name),
      })
    end
    return _execute_tool_raw(tool, args, ctx, timer)
  end
  -- 兜底附加规格（覆盖动态注册/未走加载器的工具）
  require("NeoAI.sandbox.wrapper").attach(tool)
  local out = async.Deferred.new()
  sandbox.gate(tool, args, ctx, function()
    return _execute_tool_raw(tool, args, ctx, timer)
  end):then_(function(v) out:resolve(v) end, function(e) out:reject(e) end)
  return out
end

-- ========== 公开 API ==========

--- 执行工具
--- @param tool_name string
--- @param raw_args any
--- @param ctx table { agent?, tool_call_id?, signal?, is_sub_agent?, tool_service? }
--- @return Deferred resolve(结果), reject(错误)
function M.execute(tool_name, raw_args, ctx)
  ctx = ctx or {}
  local signal = ctx.signal
  if signal and signal:aborted() then
    return async.reject({ kind = "aborted", message = "工具执行前已取消" })
  end

  -- 名称解析（别名/模糊匹配）
  local resolved = registry.resolve_name(tool_name)
  if not resolved then
    return async.reject({ kind = "tool", message = "工具不存在: " .. tool_name })
  end
  local tool = registry.get(resolved)

  -- 参数规范化：MCP 工具跳过别名改写与路径展开。
  -- 远端工具的 schema 由服务器权威定义，本地 alias（file→filepath 等）会破坏参数名，
  -- 且服务器会校验 arguments 与 inputSchema（未知参数报错）。路径语义也归属服务器。
  local is_mcp = tool and tool.source == "mcp"
  local args = raw_args
  if not is_mcp then
    args = _normalize_arguments(resolved, raw_args)
    -- 展开路径字段的 ~ 别名（~/... ↔ 主目录）
    args = _expand_path_args(args)
  end

  -- schema 校验
  local valid, verr = validator.validate_parameters(tool.parameters, args)
  if not valid then
    return async.reject({ kind = "validation", message = verr })
  end

  -- 审批检查。async 模式（默认）不使用执行前阻塞审批：工具立即在沙箱内执行并冻结
  -- 候选，真实修改进入异步待审队列由用户确认后应用（设计文档 §15）。
  local approval_config = registry.get_approval_config(resolved)
  local mode = ctx.approval_mode or config_store.get("tools.approval.mode") or "async"
  local needs_approval = mode ~= "async"
    and validator.check_approval(resolved, args, approval_config, mode)

  -- 可暂停计时器：tool_loop 在调用前已创建并注入 ctx.timer（用于展示活跃耗时）。
  -- 直接调用（无 tool_loop，如测试）时自建一个，仅用于超时。
  local timer = ctx.timer
  if not timer then
    timer = tool_timer.create()
    ctx.timer = timer
  end

  if needs_approval and not ctx.is_sub_agent then
    if ctx.tool_service then
      -- 交由 tool_service 做审批 UI，审批通过后继续执行。
      -- 计时器只在审批通过后才 start，因此等待审批的时间不计入耗时、也不消耗超时预算。
      return ctx.tool_service.approve_and_execute(resolved, args, ctx, function()
        return _execute_tool(tool, args, ctx, timer)
      end)
    end
  end

  -- 直接执行
  return _execute_tool(tool, args, ctx, timer)
end

--- 结果字符串化
--- @param result any
--- @return string
function M.stringify(result)
  if result == nil then return "" end
  if type(result) == "string" then return result end
  local ok, encoded = pcall(json.encode, result)
  if ok then return encoded end
  return tostring(result)
end

--- 重置（测试用）
function M.reset()
  -- registry 由 registry.reset 处理
end

return M
