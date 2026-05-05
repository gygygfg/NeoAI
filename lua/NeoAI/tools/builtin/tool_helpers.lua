-- 工具定义辅助模块
-- 提供 define_tool() 函数，让工具的定义、描述、参数、实现紧密组织在一起
-- 支持同步和回调两种模式：
--   同步模式：func(args) -> result
--   回调模式：func(args, on_success, on_error) 异步执行后通过回调返回
local M = {}

--- 定义一个工具
--- 将工具的所有信息（名称、描述、参数、实现、分类、权限）集中在一个调用中
---
--- 回调模式约定：
---   工具函数签名：function(args, on_success, on_error)
---     - args: table 工具参数
---     - on_success: function(result) 执行成功时调用
---     - on_error: function(error_msg) 执行失败时调用
---   工具函数内部应使用 vim.uv 异步 I/O 或 vim.schedule / vim.defer_fn 实现异步，
---   并通过 on_success/on_error 返回结果，不阻塞主线程。
---
--- 同步模式（兼容旧接口）：
---   工具函数签名：function(args) -> result
---   直接返回结果，会阻塞主线程。
---
--- @param opts table 工具定义选项
--- @param opts.name string 工具名称
--- @param opts.description string 工具描述
--- @param opts.func function 工具实现函数
--- @param opts.parameters? table 参数的 JSON Schema 定义
--- @param opts.returns? table 返回值描述
--- @param opts.category? string 工具分类
--- @param opts.permissions? table 权限声明
--- @param opts.async? boolean 是否为回调模式（默认 false，即同步模式）
--- @param opts.timeout? number 超时毫秒数，nil 表示使用全局默认，-1 表示无限等待
--- @return table 工具定义表
function M.define_tool(opts)
  vim.validate({
    name = { opts.name, "string" },
    description = { opts.description, "string" },
    func = { opts.func, "function" },
    parameters = { opts.parameters, "table", true },
    category = { opts.category, "string", true },
    returns = { opts.returns, "table", true },
    permissions = { opts.permissions, "table", true },
    async = { opts.async, "boolean", true },
    timeout = { opts.timeout, "number", true },
  })

  return {
    name = opts.name,
    description = opts.description,
    func = opts.func,
    parameters = opts.parameters or {
      type = "object",
      properties = {},
    },
    returns = opts.returns or {
      type = "string",
      description = "执行结果",
    },
    category = opts.category or "uncategorized",
    permissions = opts.permissions or {},
    approval = opts.approval, -- 审批配置（保留 nil 表示使用默认行为）
    async = opts.async or false, -- 标记是否为回调模式
    timeout = opts.timeout, -- 超时毫秒数，nil 使用全局默认，-1 无限等待
  }
end

return M
