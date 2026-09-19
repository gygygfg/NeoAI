--- 接收工具参数面板
--- @module NeoAI.ui.components.tool_args_panel
--- 在独立浮动窗口实时展示模型流式生成的工具调用参数，随分片增量追加（与思考面板一致），
--- 支持关闭。依托复用组件 float_stream_window；保留 open/show/close/is_open/get_content/reset API。
---
--- 接收中的参数是残缺 JSON，逐片累积。此处不做每 tick 的整段解析 / 美化重排，而是把
--- 单个工具调用的**新参数分片**直接 append 到窗口尾部（终端式增长），与 reasoning_panel 一致，
--- 避免大参数（如 write_file 的 content）在接收过程中退化为 O(n²) 的反复重排。
---
--- 增量追加仅适用于「单个工具调用」：增量只往缓冲区尾部追加，而并发多个工具的参数行是
--- 上下排列的，若同时增长会把某工具的增量错位追加到另一工具行上。多工具（或名字变化、
--- 参数被替换等不连续变化）一律回退为整段重建（set_text），保证显示与快照一致。

local float_window = require("NeoAI.ui.components.float_stream_window")

local M = {}

local FILETYPE = "neoai_tool_args"
local TITLE = "🔧 接收参数"
-- 高度上限：接收参数悬浮窗最多 5 行。
local MAX_HEIGHT = 5

-- ========== 私有状态 ==========

-- 上次已追加到窗口的工具调用进度：pos -> { name = 工具名, args = 已追加的原始参数字符串 }。
-- 用于把累积快照差分出「新增分片」，只 append 增量而不整段重排。
local state = {
  seen = {},
}

-- ========== 私有函数 ==========

--- 按快照整段重建展示文本（回退 / 换会话 / 多工具时用）
--- @param tool_calls table 数组 { id, function = { name, arguments } }
--- @return string
local function _rebuild(tool_calls)
  local lines = {}
  for _, tc in ipairs(tool_calls) do
    local fn = tc["function"] or {}
    local name = fn.name or "unknown"
    local args = fn.arguments
    lines[#lines + 1] = "  ⏳ 正在接收参数: " .. name
    if type(args) == "string" and args ~= "" then
      lines[#lines + 1] = "    " .. args
    end
  end
  return table.concat(lines, "\n")
end

--- 依据快照重建 seen 进度表
--- @param tool_calls table
local function _reset_seen(tool_calls)
  local seen = {}
  for i, tc in ipairs(tool_calls) do
    local fn = tc["function"] or {}
    local args = fn.arguments
    seen[i] = {
      name = fn.name or "unknown",
      args = type(args) == "string" and args or "",
    }
  end
  state.seen = seen
end

--- seen 中已记录的位置数
--- @return number
local function _seen_count()
  local n = 0
  for _ in pairs(state.seen) do
    n = n + 1
  end
  return n
end

--- 是否可安全增量追加：上次与本次均为「单个工具调用」，且名字未变、参数前缀延展。
--- 任一条件不满足（多工具、名字变化、参数被替换/重排）即返回 false，回退整段重建。
--- @param tool_calls table
--- @return boolean
local function _can_append_incremental(tool_calls)
  if #tool_calls ~= 1 or _seen_count() ~= 1 then return false end
  local entry = state.seen[1]
  if not entry then return false end
  local fn = tool_calls[1]["function"] or {}
  if (fn.name or "unknown") ~= entry.name then return false end
  local args = fn.arguments
  args = type(args) == "string" and args or ""
  return args:sub(1, #entry.args) == entry.args
end

--- 单工具增量追加：只把参数新增的尾部字符 append 到窗口
--- @param tool_calls table
local function _append_incremental(tool_calls)
  local entry = state.seen[1]
  local args = (tool_calls[1]["function"] or {}).arguments
  args = type(args) == "string" and args or ""
  local new_part = args:sub(#entry.args + 1)
  if new_part == "" then return end
  -- 首次由空参数进入有参数：补一个换行 + 缩进，另起一行；否则直接续接当前行。
  local prefix = (#entry.args == 0) and "\n    " or ""
  float_window.append(prefix .. new_part)
  entry.args = args
end

-- ========== 公开 API ==========

--- 打开面板
--- @param title string|nil
--- @return number win_id
function M.open(title)
  return float_window.open(title or TITLE, { filetype = FILETYPE, max_height = MAX_HEIGHT })
end

--- 展示工具调用参数快照（单工具增量追加；否则整段重建）
--- @param tool_calls table 数组 { id, function = { name, arguments } }
function M.show(tool_calls)
  -- 先判定是否仍是本面板占用的窗口（据 filetype + 已有进度），再 open 设置 filetype
  local continuing = float_window.is_open() and float_window.get_filetype() == FILETYPE
    and next(state.seen) ~= nil
  M.open()
  if not tool_calls or #tool_calls == 0 then
    state.seen = {}
    float_window.set_text("等待工具参数…")
    return
  end
  if continuing and _can_append_incremental(tool_calls) then
    _append_incremental(tool_calls)
    return
  end
  float_window.set_text(_rebuild(tool_calls))
  _reset_seen(tool_calls)
end

--- 面板当前展示的文本（测试用）
--- @return string
function M.get_content()
  return float_window.get_text()
end

--- 关闭面板
function M.close()
  state.seen = {}
  float_window.close()
end

--- 是否打开
--- @return boolean
function M.is_open()
  return float_window.is_open()
end

--- 重置（测试用）
function M.reset()
  state.seen = {}
  float_window.reset()
end

return M
