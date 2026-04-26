-- 工具定义辅助模块
-- 提供 define_tool() 函数，让工具的定义、描述、参数、实现紧密组织在一起
local M = {}

--- 定义一个工具
--- 将工具的所有信息（名称、描述、参数、实现、分类、权限）集中在一个调用中
---
--- 每个工具的定义包含以下字段：
--- - name: 工具的唯一标识名称，用于在 AI 调用时引用
--- - description: 工具的功能描述，AI 根据此描述决定是否调用该工具
--- - func: 工具的实际实现函数，接收参数表并返回结果
--- - parameters: 工具的 JSON Schema 参数定义，描述工具接受的输入
--- - returns: 工具返回值的描述，帮助 AI 理解返回结果的结构
--- - category: 工具的分类标签，用于组织和过滤
--- - permissions: 工具的权限声明，控制工具能访问的资源
---
--- 使用示例：
--- <code>
--- define_tool({
---   name = "read_file",
---   description = "读取指定文件的内容",
---   func = function(args) return io.open(args.path):read("*a") end,
---   parameters = {
---     type = "object",
---     properties = {
---       path = { type = "string", description = "文件路径" },
---     },
---     required = { "path" },
---   },
---   returns = { type = "string", description = "文件内容" },
---   category = "file",
---   permissions = { read = true },
--- })
--- </code>
---
--- @param opts table 工具定义选项，包含以下字段：
--- @param opts.name string 工具名称，必须唯一，用于 AI 识别和调用
--- @param opts.description string 工具描述，用自然语言说明工具的用途和适用场景
--- @param opts.func function 工具实现函数，签名：function(args: table) -> any
--- @param opts.parameters? table 参数的 JSON Schema 定义，描述工具接受的输入参数
---   格式：{ type = "object", properties = { ... }, required = { ... } }
---   每个属性字段：{ type = "string"|"number"|"boolean"|"array"|"object", description = "...", default = ... }
--- @param opts.returns? table 返回值的描述，帮助 AI 理解返回结果
---   格式：{ type = "string"|"array"|"object"|"boolean"|"number", description = "...", items = { ... } }
--- @param opts.category? string 工具分类，用于组织工具列表，如 "file"、"code"、"search" 等
--- @param opts.permissions? table 权限声明，控制工具能访问的资源
---   格式：{ read = true, write = true, execute = true }
---
--- @return table 工具定义表，包含以下字段：
--- @return string return.name 工具名称
--- @return string return.description 工具描述
--- @return function return.func 工具实现函数
--- @return table return.parameters 参数定义（JSON Schema）
--- @return table return.returns 返回值描述
--- @return string return.category 工具分类
--- @return table return.permissions 权限声明
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
