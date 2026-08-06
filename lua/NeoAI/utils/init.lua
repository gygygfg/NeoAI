--- NeoAI utils 工具库入口
--- @module NeoAI.utils
--- 纯工具模块，无业务依赖。

local M = {
  async = require("NeoAI.utils.async"),
  json = require("NeoAI.utils.json"),
  http = require("NeoAI.utils.http"),
  fs = require("NeoAI.utils.fs"),
  stringx = require("NeoAI.utils.stringx"),
}

--- 深拷贝（委托 vim.deepcopy）
--- @param t table
--- @return table
function M.deepcopy(t)
  return vim.deepcopy(t)
end

return M
