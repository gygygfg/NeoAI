--- 思考过程面板
--- @module NeoAI.ui.components.reasoning_panel
--- 在独立浮动窗口展示 AI 推理内容，支持实时追加与关闭。
--- 依托复用组件 float_stream_window；保留 open/show/append/close/is_open/reset API。

local float_module = require("NeoAI.ui.components.float_stream_window")

local FILETYPE = "neoai_reasoning"
local TITLE = "🤔 思考过程"
-- 高度上限：思考过程悬浮窗最多 5 行。
local MAX_HEIGHT = 5

-- 多实例：每个聊天实例持有独立的面板（绑定其独立悬浮窗）。见 _make(float_win)。
--- @param float_win table|nil 绑定的悬浮窗实例（缺省自建一个）
--- @return table
local function _make(float_win)
  local M = {}
  local float_window = float_win or float_module.new()

  --- 打开推理面板
  --- @param title string|nil
  --- @return number win_id
  function M.open(title)
    return float_window.open(title or TITLE, { filetype = FILETYPE, max_height = MAX_HEIGHT })
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

  --- 绑定的悬浮窗实例
  --- @return table
  function M._float() return float_window end

  --- 重置（测试用）
  function M.reset()
    float_window.reset()
  end

  return M
end

-- ========== 模块级：当前面板代理（兼容既有调用 / 测试） ==========

local M = {}
local _current = nil

--- 新建一个独立面板实例，并设为「当前」。
--- @param float_win table|nil 绑定的悬浮窗实例
--- @return table
function M.new(float_win)
  local inst = _make(float_win)
  _current = inst
  return inst
end

--- 直接指定「当前」面板实例。
--- @param inst table
function M._set_current(inst)
  if inst then _current = inst end
end

local function _cur()
  if not _current then _current = _make() end
  return _current
end

for _, name in ipairs({ "open", "show", "append", "close", "is_open", "reset" }) do
  M[name] = function(...)
    local cur = _cur()
    if cur and type(cur[name]) == "function" then return cur[name](...) end
  end
end

return M
