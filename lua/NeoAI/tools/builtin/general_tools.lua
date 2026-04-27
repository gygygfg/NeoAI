-- Lua通用工具模块
-- 提供表格操作、字符串处理等常用工具函数
-- 每个工具的定义（名称、描述、参数、实现）集中在一起，方便修改
local M = {}

local define_tool = require("NeoAI.tools.builtin.tool_helpers").define_tool

-- get_tools() - 返回所有工具列表供注册
function M.get_tools()
  local tools = {}
  for _, v in pairs(M) do
    if type(v) == "table" and v.name and v.func then
      table.insert(tools, v)
    end
  end
  table.sort(tools, function(a, b)
    return a.name < b.name
  end)
  return tools
end

return M
