--- 工具执行器
--- @module NeoAI.tools.executor
--- 参数规范化 + 校验 + 审批 + 执行（异步）+ 超时。
--- 执行结果统一转为字符串（供 Agent 回传）。

local async = require("NeoAI.utils.async")
local json = require("NeoAI.utils.json")
local registry = require("NeoAI.tools.registry")
local validator = require("NeoAI.tools.validator")
local config_store = require("NeoAI.kernel.config_store")

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

--- 超时包装
--- @param d Deferred
--- @param timeout_ms number|nil -1 = 无超时
--- @return Deferred
local function _with_timeout(d, timeout_ms)
  if not timeout_ms or timeout_ms < 0 then return d end
  local wrapped = async.Deferred.new()
  local settled = false
  vim.defer_fn(function()
    if not settled then
      settled = true
      wrapped:reject({ kind = "timeout", message = "工具执行超时 (" .. tostring(timeout_ms) .. "ms)" })
    end
  end, timeout_ms)
  d:then_(function(v)
    if settled then return end
    settled = true
    wrapped:resolve(v)
  end, function(e)
    if settled then return end
    settled = true
    wrapped:reject(e)
  end)
  return wrapped
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

  -- 参数规范化
  local args = _normalize_arguments(resolved, raw_args)

  -- schema 校验
  local valid, verr = validator.validate_parameters(tool.parameters, args)
  if not valid then
    return async.reject({ kind = "validation", message = verr })
  end

  -- 审批检查
  local approval_config = registry.get_approval_config(resolved)
  local mode = ctx.approval_mode or config_store.get("tools.approval.mode") or "prompt"
  local needs_approval = validator.check_approval(resolved, args, approval_config, mode)

  if needs_approval and not ctx.is_sub_agent then
    if ctx.tool_service then
      -- 交由 tool_service 做审批 UI，审批通过后继续执行
      return ctx.tool_service.approve_and_execute(resolved, args, ctx, function()
        local d = _call_tool(tool, args, ctx)
        local timeout = ctx.timeout_ms or tool.timeout or config_store.get("tools.executor.timeout_ms") or 30000
        return _with_timeout(d, timeout)
      end)
    end
  end

  -- 直接执行
  local d = _call_tool(tool, args, ctx)
  local timeout = ctx.timeout_ms or tool.timeout or config_store.get("tools.executor.timeout_ms") or 30000
  return _with_timeout(d, timeout)
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
