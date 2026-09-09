--- 思考过程面板
--- @module NeoAI.ui.components.reasoning_panel
--- 在独立浮动窗口展示 AI 推理内容，支持实时追加与关闭。
--- 依托复用组件 float_stream_window；保留 open/show/append/close/is_open/reset API。

local float_window = require("NeoAI.ui.components.float_stream_window")

local M = {}

local FILETYPE = "neoai_reasoning"
local TITLE = "🤔 思考过程"

-- ========== 公开 API ==========

--- 打开推理面板
--- @param title string|nil
--- @return number win_id
function M.open(title)
  return float_window.open(title or TITLE, { filetype = FILETYPE })
end

--- 显示内容
--- @param content string
function M.show(content)
  M.open()
  float_window.set_text(content or "")
end

--- 追加内容
--- @param content string
function M.append(content)
  M.open()
  float_window.append(content)
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
