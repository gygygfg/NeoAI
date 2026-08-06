--- 日志工具
--- @module NeoAI.tools.builtin.log_ops
--- 供 AI 记录日志消息与查询日志级别。

local helpers = require("NeoAI.tools.builtin.tool_helpers")

local M = {}

local log_tools = {}

log_tools.log_message = helpers.define_tool(
  "log_message",
  "记录一条日志消息。message 必填，level 可选（debug/info/warn/error）。",
  {
    type = "object",
    properties = {
      message = { type = "string", description = "日志内容" },
      level = { type = "string", enum = { "debug", "info", "warn", "error" }, description = "日志级别" },
    },
    required = { "message" },
  },
  function(args, on_success)
    local logger = require("NeoAI.kernel.logger")
    local level = args.level or "info"
    local level_map = {
      debug = logger.debug, info = logger.info, warn = logger.warn, error = logger.error,
    }
    local fn = level_map[level] or logger.info
    fn("[AI 日志] %s", args.message)
    on_success("日志已记录")
  end,
  { category = "log" }
)

log_tools.get_log_levels = helpers.define_tool(
  "get_log_levels",
  "获取可用日志级别。",
  {
    type = "object",
    properties = {},
    required = {},
  },
  function(args, on_success)
    on_success("DEBUG, INFO, WARN, ERROR, FATAL")
  end,
  { category = "log" }
)

--- 获取工具列表
--- @return table 数组
function M.get_tools()
  local out = {}
  for _, tool in pairs(log_tools) do
    out[#out + 1] = tool
  end
  return out
end

return M
