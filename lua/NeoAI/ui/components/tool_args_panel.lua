--- 接收工具参数面板
--- @module NeoAI.ui.components.tool_args_panel
--- 在独立浮动窗口实时展示模型流式生成的工具调用参数，支持随分片更新与关闭。
--- 依托复用组件 float_stream_window；保留 open/show/close/is_open/get_content/reset API。

local float_window = require("NeoAI.ui.components.float_stream_window")

local M = {}

local json = require("NeoAI.utils.json")

local FILETYPE = "neoai_tool_args"
local TITLE = "🔧 接收参数"

-- ========== 私有函数 ==========

--- 把累积的工具调用快照格式化为展示文本（多行）
--- @param tool_calls table 数组 { id, function = { name, arguments } }
--- @return string
local function _format_tool_calls(tool_calls)
  if not tool_calls or #tool_calls == 0 then return "等待工具参数…" end
  local lines = {}
  for _, tc in ipairs(tool_calls) do
    local fn = tc["function"] or {}
    local name = fn.name or "unknown"
    local args = fn.arguments
    if type(args) ~= "string" or args == "" then
      lines[#lines + 1] = ("  ⏳ 正在接收参数: %s"):format(name)
    else
      -- 参数仍在流式累积，可能是残缺 JSON：可解析则缩进展示，否则原样展示。
      local decoded = json.decode_or_nil(args)
      local body
      if decoded ~= nil then
        body = json.encode(decoded)
      else
        body = args
      end
      lines[#lines + 1] = ("  ⏳ 正在接收参数: %s"):format(name)
      for _, l in ipairs(vim.split(body, "\n", { plain = true })) do
        lines[#lines + 1] = "    " .. l
      end
    end
  end
  return table.concat(lines, "\n")
end

-- ========== 公开 API ==========

--- 打开面板
--- @param title string|nil
--- @return number win_id
function M.open(title)
  return float_window.open(title or TITLE, { filetype = FILETYPE })
end

--- 展示工具调用参数快照（替换内容）
--- @param tool_calls table 数组 { id, function = { name, arguments } }
function M.show(tool_calls)
  M.open()
  float_window.set_text(_format_tool_calls(tool_calls))
end

--- 面板当前展示的文本（测试用）
--- @return string
function M.get_content()
  return float_window.get_text()
end

--- 关闭面板
function M.close()
  float_window.close()
end

--- 是否打开
--- @return boolean
function M.is_open()
  return float_window.is_open()
end

--- 重置（测试用）
function M.reset()
  float_window.reset()
end

return M
