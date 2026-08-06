--- 工具定义辅助函数
--- @module NeoAI.tools.builtin.tool_helpers
--- 提供 define_tool 便捷构造器，供各内置工具模块使用。

local M = {}

--- 构造工具定义
--- @param name string
--- @param description string
--- @param params table|nil parameters schema
--- @param func function(args, on_success, on_error, ctx)
--- @param opts table|nil { category?, approval?, timeout? }
--- @return table 工具定义
function M.define_tool(name, description, params, func, opts)
  opts = opts or {}
  return {
    name = name,
    description = description,
    parameters = params or {
      type = "object",
      properties = {},
      required = {},
    },
    func = func,
    category = opts.category or "other",
    approval = opts.approval or {},
    timeout = opts.timeout,
  }
end

--- 快捷：异步回调工具定义
--- @param name string
--- @param description string
--- @param params table|nil
--- @param handler function(args, on_success, on_error, ctx)
--- @param opts table|nil
--- @return table
function M.define_async_tool(name, description, params, handler, opts)
  return M.define_tool(name, description, params, handler, opts)
end

--- 工具结果包装（统一格式）
--- @param content string|table
--- @param opts table|nil { error? }
--- @return table
function M.ok(content, opts)
  opts = opts or {}
  if opts.error then
    return { success = false, error = tostring(content) }
  end
  return { success = true, result = content }
end

--- 错误结果包装
--- @param err string
--- @return table
function M.error(err)
  return { success = false, error = tostring(err) }
end

--- 校验必填字符串参数
--- @param args table
--- @param key string
--- @param tool_name string
--- @return string|nil, string|nil
function M.require_string(args, key, tool_name)
  local v = args and args[key]
  if type(v) ~= "string" or v == "" then
    return nil, string.format("%s 缺少必填字符串参数 %s", tool_name, key)
  end
  return v, nil
end

return M
