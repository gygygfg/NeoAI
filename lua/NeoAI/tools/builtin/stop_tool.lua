-- 停止工具调用循环工具（回调模式）
-- 当 AI 认为任务已完成时，调用此工具触发循环调用结束
-- 工具函数签名：func(args, on_success, on_error)
--
-- 注意：不调用 ai_engine.cancel_generation()，因为该函数会设置 user_cancelled=true
-- 导致 _on_tools_complete 跳过总结轮次，造成卡死。
-- 只需设置 stop_requested 标志并清理 HTTP 请求即可。
local M = {}

local define_tool = require("NeoAI.tools.builtin.tool_helpers").define_tool
local event_constants = require("NeoAI.core.events")

local function _stop_tool_loop(args, on_success, on_error)
  local reason = args and args.reason or "任务已完成"
  local generate_summary = true
  if args and args.generate_summary ~= nil then
    generate_summary = args.generate_summary
  end

  -- 取消正在进行的 HTTP 请求（不调用 cancel_generation，避免设置 user_cancelled）
  local ok, http_client = pcall(require, "NeoAI.core.ai.http_client")
  if ok and http_client and http_client.cancel_all_requests then
    http_client.cancel_all_requests()
  end

  -- 同步触发 TOOL_LOOP_STOP_REQUESTED 事件，确保 stop_requested 标志
  -- 在 on_success 回调（_on_tools_complete）之前被设置
  -- 注意：此工具本身在异步回调中执行，不在 fast event 上下文中，可以安全同步触发
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = event_constants.TOOL_LOOP_STOP_REQUESTED,
    data = { reason = reason, generate_summary = generate_summary },
  })

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
      generate_summary = {
        type = "boolean",
        description = "是否生成总结，默认为 true。设为 false 时直接结束工具循环并显示用量信息，不生成 AI 总结",
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
