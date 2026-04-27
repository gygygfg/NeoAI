-- 停止工具调用循环工具
-- 当 AI 认为任务已完成时，调用此工具触发循环调用结束
local M = {}

local define_tool = require("NeoAI.tools.builtin.tool_helpers").define_tool
local event_constants = require("NeoAI.core.events.event_constants")

local function _stop_tool_loop(args)
  local reason = args and args.reason or "任务已完成"
  print("[stop_tool] stop_tool_loop 被调用, reason=" .. reason)

  -- 触发停止工具循环事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.TOOL_LOOP_STOP_REQUESTED,
    data = {
      reason = reason,
      timestamp = os.time(),
    },
  })

  print("[stop_tool] stop_tool_loop 完成")
  return string.format("工具调用循环已停止。原因: %s", reason)
end

M.stop_tool_loop = define_tool({
  name = "stop_tool_loop",
  description = "停止工具调用循环。当你认为当前任务已经完成、不再需要继续调用工具时，调用此工具来结束工具调用循环。",
  func = _stop_tool_loop,
  parameters = {
    type = "object",
    properties = {
      reason = {
        type = "string",
        description = "停止工具循环的原因说明，用于日志记录",
      },
    },
    required = {},
  },
  returns = {
    type = "string",
    description = "停止确认信息",
  },
  category = "system",
  permissions = {},
})

function M.get_tools()
  local tools = {}
  for _, v in pairs(M) do
    if type(v) == "table" and v.name and v.func then
      table.insert(tools, v)
    end
  end
  return tools
end

return M
