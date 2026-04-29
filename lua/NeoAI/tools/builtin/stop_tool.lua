-- 停止工具调用循环工具（回调模式）
-- 当 AI 认为任务已完成时，调用此工具触发循环调用结束
-- 工具函数签名：func(args, on_success, on_error)
--
-- 修复：同时取消正在进行的 AI 请求，防止循环卡死
local M = {}

local define_tool = require("NeoAI.tools.builtin.tool_helpers").define_tool
local event_constants = require("NeoAI.core.events")

local function _stop_tool_loop(args, on_success, on_error)
  local reason = args and args.reason or "任务已完成"

  -- 取消正在进行的 AI 请求，避免总结轮次与旧请求冲突
  local ok, ai_engine = pcall(require, "NeoAI.core.ai.ai_engine")
  if ok and ai_engine and ai_engine.cancel_generation then
    ai_engine.cancel_generation()
  end

  -- 触发 TOOL_LOOP_STOP_REQUESTED 事件，通知 tool_orchestrator 停止循环并进入总结
  -- 使用 vim.schedule 确保不在 fast event 上下文中触发
  vim.schedule(function()
    pcall(vim.api.nvim_exec_autocmds, "User", {
      pattern = event_constants.TOOL_LOOP_STOP_REQUESTED,
      data = { reason = reason },
    })
  end)

  if on_success then
    on_success(string.format("工具调用循环已停止。原因: %s", reason))
  end
end

M.stop_tool_loop = define_tool({
  name = "stop_tool_loop",
  description = "停止工具调用循环。当你认为当前任务已经完成、不再需要继续调用工具时，调用此工具来结束工具调用循环。",
  func = _stop_tool_loop,
  async = true,
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
