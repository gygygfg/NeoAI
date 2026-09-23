--- 交互式终端控制工具
--- @module NeoAI.tools.builtin.terminal
--- 在交互式命令等待输入时注入文本 / 按键 / 结束进程（供自定义判官或手动/程序化调用）。
--- 默认判官已改为单轮大模型请求直接注入，不再需要这些工具；保留以支持替换判官与手动场景。
--- 仅操作已存在的 PTY 会话（effect=in_process，不新起进程）。

local helpers = require("NeoAI.tools.builtin.tool_helpers")

local M = {}

-- ========== 私有函数 ==========

--- 取当前会话（判决上下文优先，其次唯一会话）
--- @return table|nil session
--- @return table|nil pty 服务
local function _session()
  local pty = require("NeoAI.kernel.services").use("services.pty")
  if not pty then return nil, nil end
  return pty.active(), pty
end

-- ========== 工具定义 ==========

local terminal_tools = {}

terminal_tools.terminal_send_text = helpers.define_tool(
  "terminal_send_text",
  "【交互式终端】向正在等待输入的命令会话输入一行文本并回车。"
    .. "【目标】为交互式命令（run_command，处于等待输入状态）提供一行答案（y/n、选项、普通文本）。"
    .. "【如何操作】text 必填；仅当确实存在等待输入的会话时有效。正常由系统判官自动调用，"
    .. "模型一般无需手动调用，除非需要精确控制某次输入。",
  {
    type = "object",
    properties = { text = { type = "string", description = "要输入的一行文本（会自动补回车）" } },
    required = { "text" },
  },
  function(args, on_success, on_error)
    local session, pty = _session()
    if not session then
      on_error("没有正在等待输入的交互式命令会话")
      return
    end
    local ok = pty.send_text(session.id, args.text or "")
    if not ok then
      on_error("写入终端失败")
      return
    end
    on_success("已输入: " .. tostring(args.text))
  end,
  { category = "system" }
)

terminal_tools.terminal_send_keys = helpers.define_tool(
  "terminal_send_keys",
  "【交互式终端】向正在等待输入的命令会话发送按键序列（如 Enter / Tab / Escape / Up / Down / Ctrl-C）。"
    .. "【目标】在不适合整行文本时按“键”驱动交互（移动/选择/中断）。"
    .. "【如何操作】keys 为按键名数组，例如 {\"Ctrl-C\"}、{\"Up\"}、{\"Tab\",\"y\",\"Enter\"}；"
    .. "仅当存在等待输入的会话时有效。正常由系统判官自动调用，模型一般无需手动调用。",
  {
    type = "object",
    properties = {
      keys = {
        type = "array",
        items = { type = "string" },
        description = "按键名数组，如 {\"Ctrl-C\"}、{\"Up\"}、{\"Tab\",\"y\",\"Enter\"}",
      },
    },
    required = { "keys" },
  },
  function(args, on_success, on_error)
    local session, pty = _session()
    if not session then
      on_error("没有正在等待输入的交互式命令会话")
      return
    end
    local keys = args.keys
    if type(keys) == "string" then keys = { keys } end
    if type(keys) ~= "table" or #keys == 0 then
      on_error("keys 必须是非空字符串数组")
      return
    end
    local ok = pty.send_keys(session.id, keys)
    if not ok then
      on_error("发送按键失败（按键名无法识别）")
      return
    end
    on_success("已发送按键: " .. table.concat(keys, " "))
  end,
  { category = "system" }
)

terminal_tools.terminal_kill = helpers.define_tool(
  "terminal_kill",
  "【交互式终端】结束正在等待输入的命令进程。"
    .. "【目标】命令已失败、卡死或无需继续时终止它，避免占用 timeout。"
    .. "【如何操作】无参数；仅当存在活动会话时有效。正常由系统判官自动调用，模型一般无需手动调用。",
  { type = "object", properties = {} },
  function(_, on_success, on_error)
    local session, pty = _session()
    if not session then
      on_error("没有正在运行的交互式命令会话")
      return
    end
    pty.kill(session.id, "judge_kill")
    on_success("已结束交互式命令会话")
  end,
  { category = "system" }
)

-- ========== 公开 API ==========

--- 获取工具列表（仅在交互式 run_command 开启时暴露，避免无谓的工具面噪音）
--- @return table 数组
function M.get_tools()
  local cfg = require("NeoAI.kernel.config_store").get("tools.run_command.interactive") or {}
  if not cfg.enabled or (cfg.engine or "auto") == "off" then return {} end
  local out = {}
  for _, tool in pairs(terminal_tools) do
    out[#out + 1] = tool
  end
  return out
end

--- 重置（测试用）
function M.reset() end

return M
