-- 工具定义辅助模块
-- 提供 define_tool() 函数，让工具的定义、描述、参数、实现紧密组织在一起
local M = {}

--- 定义一个工具
--- 将工具的所有信息（名称、描述、参数、实现、分类、权限）集中在一个调用中
--- @param opts table 工具定义选项
--- @return table 工具定义表，可直接用于注册
function M.define_tool(opts)
  vim.validate({
    name = { opts.name, "string" },
    description = { opts.description, "string" },
    func = { opts.func, "function" },
    parameters = { opts.parameters, "table", true },
    category = { opts.category, "string", true },
    returns = { opts.returns, "table", true },
    permissions = { opts.permissions, "table", true },
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
  }
end

return M
