-- 文件修改确认工具
-- AI 在预览文件修改结果后，通过此工具确认执行、放弃修改或覆盖参数重试
-- 此工具不通过常规工具注册，由 tool_executor 在需要时动态注入

local M = {}

local _CONFIRM_TOOL_NAME = "confirm_file_change"

--- confirm_file_change 的工具定义（OpenAI 格式）
function M.get_tool_definition()
  return {
    type = "function",
    ["function"] = {
      name = _CONFIRM_TOOL_NAME,
      description = [[处理文件修改的最终决定。当工具执行涉及文件写入操作时，AI 会先看到模拟的修改结果（修改点附近 ±10 行的内容），然后需要调用此工具来决定如何处理。

选项说明（三选一）：
1. 确认执行：设置 action="confirm"，进入用户审批流程
2. 放弃修改：设置 action="abandon"，不再尝试修改此文件
3. 覆盖参数重试：设置 action="retry"，同时传入修正后的 arguments 重新执行

注意：action="retry" 最多可重试 3 次，超过后将自动放弃。]],
      strict = true,
      parameters = {
        type = "object",
        properties = {
          action = {
            type = "string",
            description = [[操作类型：
- "confirm": 确认执行修改，进入用户审批流程
- "abandon": 放弃修改，不再尝试
- "retry": 覆盖参数后重试（需同时传入 arguments）]],
            enum = { "confirm", "abandon", "retry" },
          },
          reason = {
            type = "string",
            description = "操作原因说明（必填）",
          },
          arguments = {
            type = "object",
            description = "仅当 action='retry' 时必填。修正后的参数，key-value 格式。例如修正文件路径、修改内容等。",
            additionalProperties = true,
          },
        },
        required = { "action", "reason" },
        additionalProperties = false,
      },
    },
  }
end

function M.get_tool_name()
  return _CONFIRM_TOOL_NAME
end

return M
