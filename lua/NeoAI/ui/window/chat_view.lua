--- 聊天视图
--- @module NeoAI.ui.window.chat_view
--- 聊天窗口渲染与交互。绑定事件，流式更新。
--- 布局：主消息区（上） + 输入框（下，split）。

local window_manager = require("NeoAI.ui.window.manager")
local config_store = require("NeoAI.kernel.config_store")
local message_list = require("NeoAI.ui.components.message_list")
local input_box = require("NeoAI.ui.components.input_box")
local model_picker = require("NeoAI.ui.components.model_picker")
local reasoning_panel = require("NeoAI.ui.components.reasoning_panel")
local tool_args_panel = require("NeoAI.ui.components.tool_args_panel")
local float_stream_window = require("NeoAI.ui.components.float_stream_window")
local fold = require("NeoAI.ui.components.fold")
local display_modes = require("NeoAI.ui.components.display_modes")
local chat_service = require("NeoAI.services.chat_service")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")

local M = {}

-- 折叠占位文本统一由 NeoAI.ui.components.fold 提供（推理 / 工具调用 / 工具结果共用同一份实现）。

-- ========== 私有状态 ==========

local state = {
  win_id = nil, -- 主窗口
  buf = nil, -- 主 buffer（消息列表）
  input_win_id = nil, -- 输入窗口
  unsubs = {},
  agent_id = nil,
  tool_tick = nil, -- 工具执行中折叠文本定时刷新句柄
  following = true, -- 流式更新时光标是否跟随（不跟随时不弹思考悬浮窗、不重新折叠已有折叠）
  collapsed = false, -- 聊天窗口进入后台后是否已收起（输入框）
  focus_augroup = nil, -- 焦点追踪自动命令组（WinEnter/BufEnter）
  input_resize_augroup = nil, -- 输入框随内容增高自动命令组
  resize_augroup = nil, -- 窗口大小变化时重排表格自动命令组（VimResized）
  last_table_width = nil, -- 上次渲染表格所用宽度（resize 后宽度变化才重排）
}

-- 输入框高度：光标在主界面 → idle_height；光标在输入框 → min_height 起步，随内容行数增长，上限为主窗口高度的 max_ratio。
local function _input_box_cfg()
  return config_store.get("ui.input_box") or {}
end
local function _input_idle_height()
  return math.max(1, _input_box_cfg().idle_height or 1)
end

-- 输入框非模块级函数，但 _create_input_area（在下方定义）会引用，需提前声明。
local _register_input_resize

-- ========== 私有函数 ==========

-- 流式更新跟随滚动的触发范围：光标处于 buffer 最后 5 行内才跟随到底部，
-- 否则用户正在回看上方内容，不动光标。
local FOLLOW_MARGIN = 5

--- 光标是否位于 buffer 最后 5 行内
--- @return boolean
local function _cursor_within_follow_margin()
  if not state.win_id or not vim.api.nvim_win_is_valid(state.win_id) then return true end
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return true end
  local cur = vim.api.nvim_win_get_cursor(state.win_id)
  local line_count = vim.api.nvim_buf_line_count(state.buf)
  -- 最后 5 行 = line_count-4 .. line_count；光标只在这些行内才自动跟随
  return cur[1] >= math.max(1, line_count - (FOLLOW_MARGIN - 1))
end

--- 当前处于展开状态的折叠块首行行号集合（供不跟随时重写 buffer 后恢复展开状态）。
--- 仅当整块 buffer 重写会让手动开合状态丢失时使用；按折叠首行行号记录，
--- 流式更新内容追加在底部，上方已展开折叠的行号保持稳定。
--- @return table 行号数组
local function _open_fold_start_lines()
  local starts = {}
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return starts end
  local total = vim.api.nvim_buf_line_count(state.buf)
  local prev_level = 0
  for ln = 1, total do
    local lvl = vim.fn.foldlevel(ln)
    if lvl > 0 and prev_level == 0 then
      if vim.fn.foldclosed(ln) == -1 then
        starts[#starts + 1] = ln
      end
    end
    prev_level = lvl
  end
  return starts
end

--- 当前聊天窗口对应的表格宽度上限：随窗口宽度自适应（窄窗收表、宽窗放表）。
--- 无有效聊天窗口时返回 nil（表格用默认单列上限）。
--- @return number|nil
local function _current_table_width()
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    local ok, w = pcall(vim.api.nvim_win_get_width, state.win_id)
    if ok and w and w > 0 then
      return math.max(20, w - 2)
    end
  end
  return nil
end

--- 渲染全部消息
--- @param keep_view boolean|nil 仅刷新折叠文本（如工具耗时更新）时传 true：
--- 无论光标是否在跟随区，都记录并恢复已展开的折叠块与光标/视口，避免把正在查看的地方拽走。
local function _render(keep_view)
  -- 不跟随（用户回看上方内容）或仅刷新折叠文本时记录已展开的折叠块，
  -- 重写 buffer 后恢复其展开状态，避免把用户正在查看的内容重新折叠起来。
  local open_folds = {}
  if not state.following or keep_view then
    open_folds = _open_fold_start_lines()
  end
  local messages = chat_service.get_messages()
  -- 还在生成（agent 忙碌 / 暂存队列非空）时，仅对末尾消息做流式渲染：
  -- 表格在生成期间原样输出，生成结束后才做对齐填充，避免列宽随流式跳动。
  -- table_width 随聊天窗口宽度自适应：窄窗把表收紧（更多折行），宽窗放宽表，避免整表超出屏幕。
  local render_opts = { streaming = chat_service.has_pending_work() }
  state.last_table_width = _current_table_width()
  if state.last_table_width then
    render_opts.table_width = state.last_table_width
  end
  message_list.render(state.buf, messages, render_opts)
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    vim.api.nvim_win_call(state.win_id, function()
      -- 每次重写 buffer 后，expr 折叠并不会自动重算（带 UI 会话里 nvim_buf_set_lines
      -- 不触发 foldexpr 求值，导致 foldlevel 全为 0、折叠失效）。先 zx 强制按 foldexpr
      -- 重算折叠。光标跟随（底部）且非仅刷新折叠文本时 zM 全部收起（zc 只对光标处的折叠生效，
      -- 其它位置会报 E490）；其余情况（光标不跟随——用户回看上方、或仅刷新折叠文本）只重算、
      -- 不收起，并把重写前已展开的折叠重新展开，保留用户当前查看的折叠状态
      -- （zx 会保留手动开合的折叠状态，但整块 buffer 重写会丢失它）。
      if state.following and not keep_view then
        vim.cmd("silent! normal! zxzM")
      else
        vim.cmd("silent! normal! zx")
        -- 记录光标位置，重开折叠后恢复：不能让用户正在查看的位置被拽走。
        local cur = vim.api.nvim_win_get_cursor(state.win_id)
        for _, ln in ipairs(open_folds) do
          if vim.fn.foldclosed(ln) ~= -1 then
            pcall(vim.api.nvim_win_set_cursor, state.win_id, { math.max(1, ln), 0 })
            vim.cmd("silent! normal! zo")
          end
        end
        pcall(vim.api.nvim_win_set_cursor, state.win_id, cur)
      end
    end)
  end
end

--- 刷新/滚动到底部
--- 仅在聊天窗口当前显示聊天 buffer 时移动光标：用户把窗口切到别的 buffer
--- （:bnext 等）后，聊天内容照常写入 state.buf，但光标属于其它 buffer，
--- 用 state.buf 的行号设置光标会越界抛错。
local function _scroll_to_end()
  if not state.win_id or not vim.api.nvim_win_is_valid(state.win_id) then return end
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end
  if vim.api.nvim_win_get_buf(state.win_id) ~= state.buf then return end
  local line_count = vim.api.nvim_buf_line_count(state.buf)
  vim.api.nvim_win_set_cursor(state.win_id, { math.max(1, line_count), 0 })
  -- 光标落在被折叠的行上时，nvim 会把可视光标放在折叠首行而非窗口底部，
  -- 在跟随模式下 _render 里 zM 收起整个 buffer 后光标因此被"拽到窗口上面"
  -- （winline 变成接近 1）。这里在折叠后的状态下用 zb 把光标行平移到窗口底部，
  -- 光标逻辑行仍停留在最后一行，仅滚动窗口，从而保持跟随到最底部。
  vim.api.nvim_win_call(state.win_id, function()
    vim.cmd("silent! normal! zb")
  end)
end

-- 渲染合并：流式分片 / 工具事件在同一个事件循环 tick 内可能连续触发多次，
-- 每次都同步全量重渲染 + zxzM 折叠重算会占满主线程，第二/多轮（历史消息更多）
-- 时尤其明显，表现为"主界面卡住"。这里把渲染延后到本 tick 结束，合并为一次。
local render_scheduled = false
local render_pending_follow = false
local render_pending_keep_view = false
local render_flushed = false

--- 执行一次实际渲染（由调度回调或 flush 调用）
local function _do_render()
  render_scheduled = false
  render_flushed = true
  local keep_view = render_pending_keep_view
  render_pending_keep_view = false
  _render(keep_view)
  -- 仅跟随且非保持视图时才滚动到底部：保持视图（如工具耗时刷新）时不动视口。
  if render_pending_follow and not keep_view then
    _scroll_to_end()
  end
end

--- 调度一次渲染（合并同一 tick 内的多次更新）
--- @param keep_view boolean|nil 仅刷新折叠文本（不滚动、不改变光标/视口）
local function _schedule_render(keep_view)
  if render_scheduled then return end
  render_scheduled = true
  render_flushed = false
  -- 在渲染前判断是否跟随（_render 内 zxzM 会把光标从收起的折叠块内拽到折叠首行，
  -- 渲染后再判断会导致跟随失效），把决定缓存在调度时，并同步给 state.following
  -- （不跟随时用于抑制思考悬浮窗弹出与折叠收起）。
  render_pending_follow = _cursor_within_follow_margin()
  state.following = render_pending_follow
  render_pending_keep_view = keep_view == true
  vim.schedule(function()
    if render_flushed then
      -- 已被 flush 同步执行过，跳过以避免重复渲染
      render_scheduled = false
      return
    end
    _do_render()
  end)
end

-- 推理分片批量：推理 token 高频到达时，逐片 nvim_buf_set_lines / set_cursor 会
-- 反复唤醒 UI 重绘，把主线程占满。这里把同一 tick 内的分片拼起来，合并为一次追加。
local reasoning_pending = ""
local reasoning_flush_scheduled = false
-- 推理已终止（正文开始/推理结束）：已排队的冲刷回调应作废，避免重新打开悬浮窗。
local reasoning_cancelled = false

-- 工具参数分片批量：与推理一致，把同一 tick 内的参数快照合并为一次窗口刷新。
local tool_args_pending = ""
local tool_args_flush_scheduled = false
-- 参数流已终止（参数结束/窗口关闭）：已排队的冲刷回调应作废，避免重新打开悬浮窗。
local tool_args_cancelled = true

--- 取消未冲刷的工具参数分片（参数结束 / 窗口关闭时调用）
local function _cancel_pending_tool_args()
  tool_args_pending = ""
  tool_args_cancelled = true
end

--- 把缓存的工具参数快照一次性刷到悬浮窗
local function _flush_tool_args()
  tool_args_flush_scheduled = false
  if tool_args_cancelled then
    tool_args_cancelled = false
    return
  end
  if tool_args_pending == "" then return end
  -- 冲刷时若光标已不跟随，作废本次冲刷：不重新弹出接收参数悬浮窗，避免干扰当前查看。
  if not _cursor_within_follow_margin() then
    tool_args_pending = ""
    return
  end
  local tool_calls = tool_args_pending
  tool_args_pending = ""
  tool_args_panel.show(tool_calls)
end

--- 取消未冲刷的推理分片（正文开始 / 推理结束 / 窗口关闭时调用）
local function _cancel_pending_reasoning()
  reasoning_pending = ""
  reasoning_cancelled = true
end

--- 把缓存的推理分片一次性追加到悬浮窗
local function _flush_reasoning()
  reasoning_flush_scheduled = false
  if reasoning_cancelled then
    reasoning_cancelled = false
    return
  end
  if reasoning_pending == "" then return end
  -- 冲刷时若光标已不跟随（用户回看上方内容 / 切走），作废本次冲刷：
  -- 不重新弹出思考悬浮窗，避免干扰用户当前查看的位置。
  if not _cursor_within_follow_margin() then
    reasoning_pending = ""
    return
  end
  local chunk = reasoning_pending
  reasoning_pending = ""
  reasoning_panel.append(chunk)
end

-- 上下文压缩 / 计划蒸馏分片批处理：与推理分片一致，压缩 / 蒸馏期间实时把接收到的
-- 摘要（推理 + 正文）合并为一次窗口刷新，避免界面"看起来卡住"。
local ctxop_pending = ""
local ctxop_flush_scheduled = false
-- 上下文操作已终止（完成 / 正文开始 / 窗口关闭）：已排队的冲刷回调应作废。
local ctxop_cancelled = true
-- 当前上下文操作类型（决定悬浮窗标题）："compaction" | "distill"
local ctxop_kind = "compaction"

--- 取消未冲刷的上下文操作分片（完成 / 正文开始 / 窗口关闭时调用）
local function _cancel_ctxop()
  ctxop_pending = ""
  ctxop_cancelled = true
end

--- 按当前类型打开上下文操作悬浮窗
local function _open_ctxop_window()
  local title = "🧬 上下文压缩"
  if ctxop_kind == "distill" then title = "🧬 计划蒸馏" end
  float_stream_window.open(title, { filetype = "neoai_context_op" })
end

--- 把接收到的推理 + 正文格式化为展示文本
--- @param reasoning string|nil
--- @param content string|nil
--- @return string
local function _format_ctxop(reasoning, content)
  local parts = {}
  if reasoning and reasoning ~= "" then
    parts[#parts + 1] = "🧠 思考中…\n" .. reasoning
  end
  if content and content ~= "" then
    parts[#parts + 1] = content
  end
  return table.concat(parts, "\n\n")
end

--- 把缓存的上下文操作分片一次性刷到悬浮窗
local function _flush_ctxop()
  ctxop_flush_scheduled = false
  if ctxop_cancelled then
    ctxop_cancelled = false
    return
  end
  if ctxop_pending == "" then return end
  -- 冲刷时若光标已不跟随（用户回看上方内容 / 切走），作废本次冲刷：
  -- 不弹出上下文操作悬浮窗，避免干扰用户当前查看的位置。
  if not _cursor_within_follow_margin() then
    ctxop_pending = ""
    return
  end
  local text = ctxop_pending
  ctxop_pending = ""
  _open_ctxop_window()
  float_stream_window.set_text(text)
end

--- 流式更新当前消息
--- @param payload table
local function _on_message_updated(payload)
  if not payload or not payload.agent_id then return end
  if payload.agent_id ~= state.agent_id then return end
  if payload.message and payload.message.content ~= "" then
    -- 正文开始：取消尚未冲刷的推理分片并关闭悬浮窗。若不取消，已 vim.schedule 的
    -- _flush_reasoning 稍后还会把残留分片 append 上去、把已关闭的悬浮窗重新打开。
    _cancel_pending_reasoning()
    reasoning_panel.close()
    -- 正文开始说明生成已在恢复，关闭上下文压缩 / 蒸馏悬浮窗。
    _cancel_ctxop()
    float_stream_window.close()
  end
  -- 渲染延后到本 tick 结束并合并：同一 tick 内多次分片/事件只渲染一次，
  -- 避免每个分片都全量重渲染 + zxzM 折叠重算（多轮历史消息时尤其卡主界面）。
  -- 跟随判断在调度时缓存（见 _schedule_render 注释）。
  _schedule_render()
end

--- 同步执行待处理的渲染与推理分片（测试用：事件流在真实环境走 schedule，
--- 单测在事件循环外发射事件后需要手动冲刷才能断言 buffer 内容）
function M.flush()
  if reasoning_flush_scheduled then
    _flush_reasoning()
  end
  if tool_args_flush_scheduled then
    _flush_tool_args()
  end
  if ctxop_flush_scheduled then
    _flush_ctxop()
  end
  if render_scheduled and not render_flushed then
    _do_render()
  end
end

--- 实时显示当前 Agent 的推理；正文开始或推理结束后会自动关闭。
--- 光标不跟随（用户回看上方内容）时不弹出思考悬浮窗，仅照常渲染到聊天 buffer。
--- @param payload table
local function _on_reasoning_chunk(payload)
  if not payload or payload.agent_id ~= state.agent_id then return end
  if payload.chunk then
    -- 新一轮推理（如工具循环第二/多轮 turn）会重新发射分片：重置取消标记，
    -- 允许后续分片正常冲刷到悬浮窗。
    reasoning_cancelled = false
    -- 光标不跟随时抑制思考悬浮窗：既不缓存分片也不调度冲刷，避免弹出悬浮窗干扰查看。
    -- 用实时光标位置判断（而非缓存的 state.following），用户切回底部后下一分片即可恢复。
    if not _cursor_within_follow_margin() then return end
    reasoning_pending = reasoning_pending .. payload.chunk
    if not reasoning_flush_scheduled then
      reasoning_flush_scheduled = true
      vim.schedule(_flush_reasoning)
    end
  else
    if not _cursor_within_follow_margin() then return end
    reasoning_panel.show(payload.reasoning)
  end
end

-- ========== 工具执行计时（折叠文本显示执行时间） ==========

-- 工具执行期间每秒重渲染一次，让折叠文本中的耗时实时跳动；
-- 无执行中的工具后停止（fold.has_running() 为 false）。
local TOOL_TICK_MS = 1000

local function _stop_tool_tick()
  if state.tool_tick then
    vim.fn.timer_stop(state.tool_tick)
    state.tool_tick = nil
  end
end

local function _tool_tick()
  state.tool_tick = nil
  if not M.has_window() then return end
  -- 仅刷新折叠文本（工具耗时），保持已展开折叠与光标/视口不变，避免打断用户查看。
  _schedule_render(true)
  if fold.has_running() then
    state.tool_tick = vim.fn.timer_start(TOOL_TICK_MS, _tool_tick, vim.empty_dict())
  end
end

local function _schedule_tool_tick()
  if state.tool_tick then return end
  state.tool_tick = vim.fn.timer_start(TOOL_TICK_MS, _tool_tick, vim.empty_dict())
end

--- 工具开始执行：记录开始时间并启动折叠文本耗时刷新
--- @param payload table
local function _on_tool_started(payload)
  if not payload or payload.agent_id ~= state.agent_id then return end
  if payload.tool_call_id then
    fold.record_start(payload.tool_call_id)
  end
  _schedule_render()
  _schedule_tool_tick()
end

--- 工具执行结束：记录总耗时与状态；全部结束后停止刷新
--- @param payload table
local function _on_tool_finished(payload)
  if not payload or payload.agent_id ~= state.agent_id then return end
  if payload.tool_call_id then
    -- 每个工具完成即各自更新状态（结果消息要等整批 async.all 落库，这里先记下）
    local status = payload.error ~= nil and "failure" or "success"
    fold.record_end(payload.tool_call_id, payload.duration_ms, status)
  end
  _schedule_render()
  if not fold.has_running() then
    _stop_tool_tick()
  end
end

--- @param payload table
local function _close_reasoning_panel(payload)
  if not payload or payload.agent_id ~= state.agent_id then return end
  -- 推理结束：取消尚未冲刷的分片（避免已排队的 flush 回调重新打开悬浮窗），再关闭。
  _cancel_pending_reasoning()
  reasoning_panel.close()
end

--- 工具参数流分片：打开/更新"接收参数"悬浮窗（与思考过程悬浮窗一致，光标不跟随时不弹）
--- @param payload table { agent_id, tool_calls }
local function _on_tool_arg_chunk(payload)
  if not payload or payload.agent_id ~= state.agent_id then return end
  if not payload.tool_calls or #payload.tool_calls == 0 then return end
  tool_args_cancelled = false
  -- 光标不跟随时抑制接收参数悬浮窗，避免弹出悬浮窗干扰用户查看。
  if not _cursor_within_follow_margin() then return end
  -- 参数接收阶段收起思考过程悬浮窗（含作废其已排队的冲刷），避免两窗重叠遮挡。
  _close_reasoning_panel(payload)
  tool_args_pending = payload.tool_calls
  if not tool_args_flush_scheduled then
    tool_args_flush_scheduled = true
    vim.schedule(_flush_tool_args)
  end
end

--- 工具参数流结束：关闭接收参数悬浮窗
--- @param payload table
local function _close_tool_args_panel(payload)
  if not payload or payload.agent_id ~= state.agent_id then return end
  _cancel_pending_tool_args()
  tool_args_panel.close()
end

-- ========== 上下文压缩 / 计划蒸馏悬浮窗 ==========

--- 上下文操作开始：打开悬浮窗并准备接收分片（光标不跟随时不弹）
--- @param payload table
--- @param kind string "compaction" | "distill"
local function _on_ctxop_started(payload, kind)
  if not payload or payload.agent_id ~= state.agent_id then return end
  ctxop_cancelled = false
  ctxop_kind = kind or "compaction"
  -- 光标不跟随时抑制悬浮窗：既不缓存分片也不调度冲刷，避免弹出悬浮窗干扰查看。
  if not _cursor_within_follow_margin() then return end
  local placeholder = kind == "distill" and "正在计划蒸馏…" or "正在压缩上下文…"
  ctxop_pending = placeholder
  if not ctxop_flush_scheduled then
    ctxop_flush_scheduled = true
    vim.schedule(_flush_ctxop)
  end
end

--- 上下文操作分片：更新悬浮窗内容
--- @param payload table { agent_id, reasoning, content }
local function _on_ctxop_chunk(payload)
  if not payload or payload.agent_id ~= state.agent_id then return end
  ctxop_cancelled = false
  if not _cursor_within_follow_margin() then return end
  ctxop_pending = _format_ctxop(payload.reasoning, payload.content)
  if not ctxop_flush_scheduled then
    ctxop_flush_scheduled = true
    vim.schedule(_flush_ctxop)
  end
end

--- 上下文操作结束：关闭悬浮窗
--- @param payload table
local function _close_ctxop_panel(payload)
  if not payload or payload.agent_id ~= state.agent_id then return end
  _cancel_ctxop()
  float_stream_window.close()
end

--- @param payload table
local function _on_compaction_started(payload)
  _on_ctxop_started(payload, "compaction")
end

--- @param payload table
local function _on_distill_started(payload)
  _on_ctxop_started(payload, "distill")
end

--- @param payload table
local function _on_generation_finished(payload)
  _close_reasoning_panel(payload)
  _close_tool_args_panel(payload)
  _close_ctxop_panel(payload)
  _on_message_updated(payload)
end

--- 焦点移到主窗口（消息区）并进入普通模式，方便边生成边浏览/滚动
local function _focus_main_normal()
  if not state.win_id or not vim.api.nvim_win_is_valid(state.win_id) then return end
  -- 窗口可能被切到别的 buffer（例如用户 :bnext 在聊天窗口里查看其他文件），
  -- 先把聊天 buffer 绑回聊天窗口：焦点回到聊天消息区时，后续按键/输入都作用于聊天 buffer。
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    local shown = vim.api.nvim_win_get_buf(state.win_id)
    if shown ~= state.buf then
      vim.api.nvim_win_set_buf(state.win_id, state.buf)
    end
  end
  vim.api.nvim_set_current_win(state.win_id)
  vim.cmd("stopinsert")
end

--- 焦点移到输入框并进入插入模式（Agent 结束后回到输入位）
local function _focus_input_insert()
  if not state.input_win_id or not vim.api.nvim_win_is_valid(state.input_win_id) then return end
  input_box.focus()
end

--- Agent 结束（完成 / 出错 / 取消）：渲染最终状态并回到输入框
--- @param payload table
local function _on_agent_end(payload)
  _on_generation_finished(payload)
  -- 仅主 Agent 结束才把光标移回输入框：子 Agent 完成/失败/取消也会携带
  -- 自己的 agent_id 发射 GENERATION_COMPLETED 等事件，不能触发主界面的焦点动作。
  -- 且仅在当前 Agent 真正完成（空闲且暂存队列为空）时才移回输入框；
  -- 若仍有工作（正忙/暂存消息正逐条刷新、继续生成），保持光标在主窗口观看流式输出，
  -- 避免每个刷新 turn 都触发一次进入插入模式。
  if payload and payload.agent_id == state.agent_id and not chat_service.has_pending_work() then
    _focus_input_insert()
  end
end

--- 提交输入
--- @param content string
local function _on_submit(content)
  input_box.on_submitted()
  -- 发送后切回主窗口并进入普通模式：生成期间可随时滚动查看流式输出
  _focus_main_normal()
  -- 发送后光标直接跳到主界面最下端：用户刚发送的消息位于末尾，
  -- 让光标贴在最后一行（并触发后续流式的"跟随"判定：光标在最后 5 行内即自动跟随）。
  _scroll_to_end()
  chat_service.send_message(content):catch(function(e)
    if e and (e.kind == "aborted" or e.kind == "cancelled") then
      -- 用户手动取消（ESC）是正常停止，不是发送失败，不弹错误提示。
      return
    end
    local msg = tostring(e.message or e)
    if type(e.body) == "string" and e.body ~= "" then
      msg = msg .. "\n" .. e.body
    end
    vim.notify("[NeoAI] 发送失败: " .. msg, vim.log.levels.ERROR)
    input_box.on_submitted()
  end)
end

--- 取消生成
local function _on_cancel()
  chat_service.cancel_generation()
end

--- 切换模型
local function _switch_model()
  model_picker.open(function(model_id, provider)
    chat_service.switch_model(model_id)
    vim.notify("[NeoAI] 已切换模型: " .. model_id, vim.log.levels.INFO)
  end)
end

--- 构建显示模式插件的宿主 API（chat_view.open 时注入 display_modes）
--- @return table
local function _build_host()
  return {
    get_buf = function() return state.buf end,
    get_messages = function() return chat_service.get_messages() end,
    set_foldexpr = function(fn) fold.set_foldexpr_override(fn) end,
    set_foldtext = function(fn) fold.set_foldtext_override(fn) end,
    refresh = function() M.refresh() end,
  }
end

--- 构建 buffer 无关的 chat 上下文 actions（主界面与输入框共用）。
--- send/insert 在主界面语义为「聚焦输入框」，输入框内会单独覆盖为发送/进入插入。
--- @return table action -> handler
local function _build_chat_actions()
  return {
    quit = function() M.close() end,
    cancel = _on_cancel,
    toggle_reasoning = function()
      message_list.toggle_reasoning()
      _render()
    end,
    switch_model = _switch_model,
    insert = function() input_box.focus() end,
    send = function() input_box.focus() end,
    cycle_mode = function()
      local names = { chat = "CHAT", plan = "PLAN", auto = "AUTO" }
      local mode = chat_service.cycle_mode()
      local suffix = chat_service.has_pending_mode() and "（将在本轮生成结束后生效）" or ""
      vim.notify("[NeoAI] 模式已切换: " .. (names[mode] or mode) .. suffix, vim.log.levels.INFO)
      _render()
    end,
    cycle_display = function()
      local plugin = display_modes.cycle()
      if plugin then
        vim.notify("[NeoAI] 显示模式已切换: " .. (plugin.label or plugin.name), vim.log.levels.INFO)
      end
    end,
    reload_display = function()
      local name = display_modes.get_current_name()
      if not name then
        vim.notify("[NeoAI] 无当前显示模式可重载", vim.log.levels.WARN)
        return
      end
      local plugin = display_modes.reload(name)
      if plugin then
        vim.notify("[NeoAI] 显示模式已热重载: " .. (plugin.label or plugin.name), vim.log.levels.INFO)
      end
    end,
    tool_approval = function()
      require("NeoAI.ui.components.tool_approval").init()
    end,
  }
end

--- 在主窗口下方创建输入 split 窗口（不 touch input_box 的状态，仅建窗口+接管 buffer）
--- @return number win_id
local function _create_input_window()
  -- 在当前主窗口下方水平分割
  local win
  vim.api.nvim_win_call(state.win_id, function()
    vim.cmd("belowright split")
    win = vim.api.nvim_get_current_win()
  end)
  vim.api.nvim_win_set_height(win, _input_idle_height())
  vim.wo[win].winfixheight = true
  vim.wo[win].wrap = false
  -- 抑制折叠：输入窗口由 :belowright split 从聊天主窗口分裂而来，会继承其
  -- foldmethod=expr / foldexpr / foldtext。用户在输入框输入多行缩进内容时，
  -- 缩进行会被 NeoAI 的 expr 折叠误判为"推理块"并收成「🤔 思考过程」折叠，
  -- 导致输入内容看似被折叠。输入框是纯文本输入区，始终禁用折叠。
  vim.wo[win].foldenable = false
  vim.wo[win].foldmethod = "manual"
  return win
end

--- 创建输入区（主窗口下方 split，高度 3）
--- @param fresh boolean|nil true=首次/重开（input_box.create 新建 buffer+键位）；false=收起后恢复（复用已有输入 buffer）
local function _create_input_area(fresh)
  local win = _create_input_window()
  if fresh then
    input_box.create({
      on_submit = _on_submit,
      on_cancel = _on_cancel,
      on_quit = function() M.close() end,
      -- 同步主界面的 chat 上下文按键到输入框（quit/cancel/toggle_reasoning/switch_model/cycle_mode/tool_approval）
      chat_actions = _build_chat_actions(),
    })
    -- 输入框随内容增高：注册文本/光标变化时重算高度
    _register_input_resize()
  end
  input_box.attach_window(win)
  state.input_win_id = win
  return win
end

-- ========== 输入框高度（焦点 + 内容自适应） ==========

--- 计算输入框最大可用高度：主窗口+输入框总高度的 max_ratio，不小于输入框最小高度。
--- 以「主窗口高度 + 输入窗口高度」为基准（两者之和在 split 内恒定），
--- 避免输入框增高挤占主窗口导致基准随之缩小、产生反复回落振荡。
--- @return number
local function _input_max_height()
  local min_h = _input_box_cfg().min_height or 5
  if not state.win_id or not vim.api.nvim_win_is_valid(state.win_id) then
    return min_h
  end
  local ratio = tonumber(_input_box_cfg().max_ratio) or 0.8
  local total = vim.api.nvim_win_get_height(state.win_id)
  if state.input_win_id and vim.api.nvim_win_is_valid(state.input_win_id) then
    total = total + vim.api.nvim_win_get_height(state.input_win_id)
  end
  return math.max(min_h, math.floor(total * ratio))
end

--- 按输入内容计算输入框目标高度：至少 min_height 行，随内容行数增长，上限为主窗口高度的 max_ratio。
--- 输入窗口 wrap=false，每个逻辑行即一个视觉行，直接用 buffer 行数。
--- @return number
local function _compute_input_height()
  local min_h = _input_box_cfg().min_height or 5
  local input_buf = input_box.get_buf()
  local lines = 1
  if input_buf and vim.api.nvim_buf_is_valid(input_buf) then
    lines = vim.api.nvim_buf_line_count(input_buf)
  end
  return math.max(min_h, math.min(lines, _input_max_height()))
end

--- 设置输入窗口高度（winfixheight 不影响程序化调整）
--- @param h number
local function _set_input_height(h)
  if not state.input_win_id or not vim.api.nvim_win_is_valid(state.input_win_id) then return end
  vim.api.nvim_win_set_height(state.input_win_id, math.max(1, h))
end

--- 按当前焦点窗口同步输入框高度：输入窗口聚焦 → 随内容增高；主窗口聚焦 → 收起为 1 行。
local function _resize_input_for_focus()
  if not state.input_win_id or not vim.api.nvim_win_is_valid(state.input_win_id) then return end
  local cur_win = vim.api.nvim_get_current_win()
  if cur_win == state.input_win_id then
    _set_input_height(_compute_input_height())
  elseif cur_win == state.win_id then
    _set_input_height(_input_idle_height())
  end
end

--- 注册输入框随内容增高命令（输入窗口聚焦时根据内容行数重算高度）。
_register_input_resize = function()
  if state.input_resize_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.input_resize_augroup)
  end
  local input_buf = input_box.get_buf()
  if not input_buf or not vim.api.nvim_buf_is_valid(input_buf) then return end
  state.input_resize_augroup = vim.api.nvim_create_augroup("NeoAIInputHeight", { clear = true })
  for _, ev in ipairs({ "TextChanged", "TextChangedI", "InsertLeave", "CursorMoved", "CursorMovedI" }) do
    vim.api.nvim_create_autocmd(ev, {
      group = state.input_resize_augroup,
      buffer = input_buf,
      callback = function()
        if vim.api.nvim_get_current_win() == state.input_win_id then
          _set_input_height(_compute_input_height())
        end
      end,
    })
  end
end

--- 清理输入框增高命令
local function _clear_input_resize()
  if state.input_resize_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.input_resize_augroup)
    state.input_resize_augroup = nil
  end
end

-- ========== 后台收起 / 恢复（焦点追踪） ==========

--- 判断窗口是否属于聊天界面（主窗口 / 输入窗口 / 任一 neoai-* 浮窗）。
--- 以「窗口当前显示的 buffer」为准而非窗口句柄：主窗口被 :bnext 切到别的文件后不算聊天界面，
--- 否则恢复时会把状态浮窗重新盖在用户正在看的文件上。
--- @param win number|nil
--- @return boolean
local function _is_chat_affiliated(win)
  if not win or not vim.api.nvim_win_is_valid(win) then return false end
  local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
  if not ok or not buf or not vim.api.nvim_buf_is_valid(buf) then return false end
  if state.buf and buf == state.buf then return true end
  if vim.bo[buf] and vim.bo[buf].filetype:sub(1, 5) == "neoai" then return true end
  return false
end

--- 收起绑定的输入框（聊天窗口进入后台 / 主窗口被切到别的 buffer）
local function _collapse_aux()
  if state.collapsed then return end
  state.collapsed = true
  if state.input_win_id and vim.api.nvim_win_is_valid(state.input_win_id) then
    pcall(vim.api.nvim_win_close, state.input_win_id, true)
  end
  state.input_win_id = nil
end

--- 恢复收起前的输入框（回到聊天界面）。输入 buffer 内容保留（bufhidden=hide）。
local function _restore_aux()
  if not state.collapsed then return end
  state.collapsed = false
  if not state.win_id or not vim.api.nvim_win_is_valid(state.win_id) then return end
  if not state.input_win_id or not vim.api.nvim_win_is_valid(state.input_win_id) then
    _create_input_area(false)
  end
end

--- WinEnter：焦点进入某窗口时同步收起/恢复并按焦点调整输入框高度（in insert 与否无关）。
local function _on_win_enter()
  if not M.has_window() then return end
  local cur_win = vim.api.nvim_get_current_win()
  if _is_chat_affiliated(cur_win) then
    _restore_aux()
    _resize_input_for_focus()
  else
    _collapse_aux()
  end
end

--- BufEnter：主聊天窗口里 :bnext/:bprev 切换 buffer 时同步收起/恢复。
--- 只在主窗口（state.win_id）当前显示的 buffer 变化时动作，避免输入窗口/浮窗的 BufEnter 误触发。
local function _on_buf_enter()
  if not M.has_window() then return end
  if not state.win_id or not vim.api.nvim_win_is_valid(state.win_id) then return end
  if vim.api.nvim_get_current_win() ~= state.win_id then return end
  local shown = vim.api.nvim_win_get_buf(state.win_id)
  if state.buf and shown == state.buf then
    _restore_aux()
    _set_input_height(_input_idle_height())
  else
    _collapse_aux()
  end
end

--- 注册焦点追踪自动命令（每次打开聊天窗口时创建，关闭时清理）
-- ========== 轨迹模式保存能力（随显示模式启停） ==========

--- 仅轨迹模式可保存（:w 走 BufWriteCmd 弹窗落盘）；其它模式把主消息 buffer 恢复为 nofile，
--- 让 `:w` 报原生 E382。随显示模式切换自动同步（含打开窗口时的初始状态）。
--- 输入框恒为 nofile（见 input_box.create），不参与 acwrite：避免命名暂存 buffer 触发 E37/E162。
local function _sync_trajectory_save()
  local trajectory = require("NeoAI.ui.components.display_modes.trajectory")
  local active = display_modes.get_current_name() == "trajectory"
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end
  if active then
    trajectory.install_save_hook(state.buf)
  else
    trajectory.remove_save_hook(state.buf)
  end
  -- 确保输入框保持 nofile（若曾因旧逻辑被改为 acwrite，这里兜底恢复）
  local input_buf = input_box.get_buf()
  if input_buf and vim.api.nvim_buf_is_valid(input_buf) then
    trajectory.remove_save_hook(input_buf)
  end
end

--- 显示模式变化：同步轨迹保存能力
--- @param payload table
local function _on_display_mode_changed(payload) -- luacheck: ignore payload
  _sync_trajectory_save()
end

local function _register_focus_tracking()
  if state.focus_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.focus_augroup)
  end
  state.focus_augroup = vim.api.nvim_create_augroup("NeoAIChatFocus", { clear = true })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = state.focus_augroup,
    callback = _on_win_enter,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = state.focus_augroup,
    callback = _on_buf_enter,
  })
end

--- 清理焦点追踪自动命令
local function _clear_focus_tracking()
  if state.focus_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.focus_augroup)
    state.focus_augroup = nil
  end
end

--- 注册窗口大小变化重排：VimResized 后若聊天窗口表格宽度变化，保持视图重写 buffer，
--- 让表格列宽/折行随窗口自适应（避免调整窗口后表格仍停留在旧宽度）。
local function _register_resize_reflow()
  if state.resize_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.resize_augroup)
  end
  state.resize_augroup = vim.api.nvim_create_augroup("NeoAIChatResize", { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = state.resize_augroup,
    callback = function()
      -- 仅聊天窗口打开时才重排；宽度未变（如仅高度拖动）则跳过，避免无谓整表重写
      local tw = _current_table_width()
      if tw and tw ~= state.last_table_width then
        _schedule_render(true)
      end
    end,
  })
end

--- 清理窗口大小重排自动命令
local function _clear_resize_reflow()
  if state.resize_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.resize_augroup)
    state.resize_augroup = nil
  end
  state.last_table_width = nil
end

--- 主窗口滚动（前向声明：_set_keymaps 先于此定义即引用，须声明为局部变量）
local _scroll

--- 设置键位（主窗口）
local function _set_keymaps()
  local keymap = require("NeoAI.ui.keymap")
  keymap.register_context("chat", _build_chat_actions(), state.buf)
  -- 主窗口 j/k 滚动
  vim.keymap.set("n", "j", function() _scroll(1) end, { buffer = state.buf })
  vim.keymap.set("n", "k", function() _scroll(-1) end, { buffer = state.buf })
  -- 鼠标滚轮：走 _scroll（光标被钳制在 [1, 行数]），视口不会越过 buffer 末尾。
  -- 默认滚轮只滚视口不动光标，会把末行上方留白（下方出现 ~），这里改为移动光标。
  -- 步长取用户 'mousescroll' 的 ver 值（默认 3）。
  local function _wheel_step()
    local s = vim.o.mousescroll or ""
    local _, e = s:find("ver:")
    local digits = e and s:sub(e + 1):match("^[0-9]+")
    return math.max(1, tonumber(digits or "") or 3)
  end
  vim.keymap.set("n", "<ScrollWheelUp>", function() _scroll(-_wheel_step()) end, { buffer = state.buf })
  vim.keymap.set("n", "<ScrollWheelDown>", function() _scroll(_wheel_step()) end, { buffer = state.buf })
end

--- 主窗口滚动
_scroll = function(delta)
  if not state.win_id or not vim.api.nvim_win_is_valid(state.win_id) then return end
  local cur = vim.api.nvim_win_get_cursor(state.win_id)
  local total = vim.api.nvim_buf_line_count(state.buf)
  local new_line = math.max(1, math.min(total, cur[1] + delta))
  vim.api.nvim_win_set_cursor(state.win_id, { new_line, cur[2] })
end

-- ========== 公开 API ==========

--- 打开聊天窗口
--- @param opts table|nil { session_id?, round? }
--- @return table { win_id, buf }
function M.open(opts)
  opts = opts or {}
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    if opts.session_id and opts.session_id ~= chat_service.get_current_session_id() then
      -- Tree selection must replace the active conversation, not reuse its buffer.
      chat_service.detach_window(state.win_id)
      local agent = chat_service.load_session(opts.session_id, { round = opts.round })
      state.agent_id = agent.id
      chat_service.attach_window(state.win_id, agent)
      reasoning_panel.close()
      _cancel_ctxop()
      float_stream_window.close()
      _render()
      _scroll_to_end()
    end
    -- 再次打开/从会话树选择时也可能遇到聊天窗口已被切到别的 buffer 的情况，
    -- 先恢复聊天 buffer 再聚焦，确保看到的是当前会话内容。
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
      local shown = vim.api.nvim_win_get_buf(state.win_id)
      if shown ~= state.buf then
        vim.api.nvim_win_set_buf(state.win_id, state.buf)
      end
    end
    vim.api.nvim_set_current_win(state.win_id)
    return { win_id = state.win_id, buf = state.buf }
  end

  local created = window_manager.create("chat", { title = "NeoAI Chat" })
  state.win_id = created.win_id
  state.buf = created.buf
  state.following = true
  vim.bo[state.buf].modifiable = true
  vim.wo[state.win_id].wrap = true
  -- 聊天窗口滚动行为固定为"贴底"：关闭本窗口的 scrolloff，避免用户全局 scrolloff
  -- 让跟随滚动的 zb 停在离底部数行处，而非真正贴到窗口底部。
  vim.wo[state.win_id].scrolloff = 0
  -- 推理正文与工具内容由 message_list 缩进两个空格，标题保持可见。
  -- 用 expr 折叠（components.fold.foldexpr）：推理 / 每个工具块（调用+结果）
  -- 各自独立成折叠，块与块之间无需分隔行（indent 折叠需要分隔行才能拆开相邻块）。
  -- 显式开启 foldenable，避免继承用户全局 foldenable=false 导致无法折叠
  -- foldexpr 用全局函数引用而非 v:lua.require'...'：后者在带 UI 的会话里求值会
  -- 失败导致 foldlevel 全部为 0（折叠失效），全局函数则稳定可用。
  local fold_mod = require("NeoAI.ui.components.fold")
  _G.NeoAIFoldExpr = fold_mod.foldexpr
  vim.wo[state.win_id].foldmethod = "expr"
  vim.wo[state.win_id].foldexpr = "v:lua.NeoAIFoldExpr()"
  vim.wo[state.win_id].foldtext = "v:lua.require'NeoAI.ui.components.fold'.foldtext()"
  vim.bo[state.buf].shiftwidth = 2
  vim.wo[state.win_id].foldenable = true
  vim.wo[state.win_id].foldlevel = 0
  -- 允许单行折叠被收起（如单行推理、结果未到达的单行工具调用），
  -- 否则 foldminlines=1 会让单行折叠无法 zM 关闭。
  vim.wo[state.win_id].foldminlines = 0
  -- 获取/创建 Agent（若有 session_id 则加载已有会话）
  local agent
  if opts.session_id then
    agent = chat_service.load_session(opts.session_id, { round = opts.round })
  else
    agent = chat_service.new_session({})
  end
  state.agent_id = agent.id
  chat_service.attach_window(state.win_id, agent)

  -- 显示模式插件：注入宿主 API，激活默认（或上次）显示模式。
  -- force=true 让插件用当前 host 重新执行 load（窗口重开后引用的是新的 buf/窗口）。
  display_modes.attach(_build_host())
  display_modes.activate(display_modes.get_current_name() or "chat", { force = true })

  _render()
  -- 先把主界面光标放到消息最底部，再聚焦输入框，
  -- 否则用户切回主界面时光标停留在折叠收起处（通常在第 1 行）。
  _scroll_to_end()
  _set_keymaps()
  -- 首次打开：新建输入 buffer + 键位（fresh 显式传 true）
  _create_input_area(true)
  input_box.focus()
  -- 打开即聚焦输入框：显式按内容适配初始高度（此时焦点追踪尚未注册，WinEnter 不会触发）
  _set_input_height(_compute_input_height())
  -- 焦点追踪：焦点离开聊天窗口或主窗口被切到别的 buffer 时收起输入框，回到聊天时恢复
  state.collapsed = false
  _register_focus_tracking()
  _register_resize_reflow()

  -- 订阅事件
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.MESSAGE_ADDED, _on_message_updated)
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.MESSAGE_UPDATED, _on_message_updated)
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.STREAM_CHUNK, _on_message_updated)
  -- 工具调用/结果到达时立即重绘，让用户及时看到 AI 调用了什么工具
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.TOOL_CALL_DETECTED, _on_message_updated)
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.TOOL_RESULT_RECEIVED, _on_message_updated)
  -- 工具执行计时：开始/结束记录耗时并刷新折叠文本
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.TOOL_EXECUTION_STARTED, _on_tool_started)
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.TOOL_EXECUTION_COMPLETED, _on_tool_finished)
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.TOOL_EXECUTION_ERROR, _on_tool_finished)
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.REASONING_CHUNK, _on_reasoning_chunk)
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.REASONING_COMPLETED, _close_reasoning_panel)
  -- 工具参数流式接收：像思考过程悬浮窗一样实时打开"接收参数"悬浮窗
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.TOOL_ARG_CHUNK, _on_tool_arg_chunk)
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.TOOL_ARG_COMPLETED, _close_tool_args_panel)
  -- 上下文压缩 / 计划蒸馏期间实时展示接收到的摘要（推理 + 正文）
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.COMPACTION_STARTED, _on_compaction_started)
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.COMPACTION_CHUNK, _on_ctxop_chunk)
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.COMPACTION_COMPLETED, _close_ctxop_panel)
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.PLAN_DISTILL_STARTED, _on_distill_started)
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.PLAN_DISTILL_CHUNK, _on_ctxop_chunk)
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.PLAN_DISTILLED, _close_ctxop_panel)
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.GENERATION_COMPLETED, _on_agent_end)
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.GENERATION_ERROR, _on_agent_end)
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.AGENT_ABORTED, _on_agent_end)
  -- 轨迹模式保存随显示模式启停
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.DISPLAY_MODE_CHANGED, _on_display_mode_changed)
  -- 打开窗口时按当前显示模式同步一次（activate 的 DISPLAY_MODE_CHANGED 在订阅前已发出）
  _sync_trajectory_save()

  -- 打开聊天窗口时懒注入 lualine 扩展：此阶段用户启动配置已执行、lualine 已可用，
  -- 避免因 lualine 懒加载 / setup 顺序导致扩展注册不到。
  require("NeoAI.services.status").ensure_lualine_extension()

  return { win_id = state.win_id, buf = state.buf }
end

--- 关闭聊天窗口
function M.close()
  _stop_tool_tick()
  fold.clear_timing()
  reasoning_panel.close()
  tool_args_panel.close()
  _cancel_ctxop()
  float_stream_window.close()
  -- 卸载当前显示模式插件（还原折叠覆盖）
  display_modes.detach()
  -- 清理缓存中的推理分片与待调度渲染，避免窗口重开后残留
  reasoning_pending = ""
  reasoning_flush_scheduled = false
  reasoning_cancelled = true
  tool_args_pending = ""
  tool_args_flush_scheduled = false
  tool_args_cancelled = true
  ctxop_pending = ""
  ctxop_flush_scheduled = false
  ctxop_cancelled = true
  render_scheduled = false
  if state.input_win_id and vim.api.nvim_win_is_valid(state.input_win_id) then
    pcall(vim.api.nvim_win_close, state.input_win_id, true)
  end
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    chat_service.detach_window(state.win_id)
    window_manager.close(state.win_id)
  end
  -- 清理 buffer，避免重复打开后 :ls 出现多个同名残留
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  for _, unsub in ipairs(state.unsubs) do
    unsub()
  end
  state.unsubs = {}
  _clear_focus_tracking()
  _clear_input_resize()
  _clear_resize_reflow()
  state.collapsed = false
  state.win_id = nil
  state.buf = nil
  state.input_win_id = nil
  state.agent_id = nil
  state.following = true
end

--- 是否有打开的窗口
--- @return boolean
function M.has_window()
  return state.win_id ~= nil and vim.api.nvim_win_is_valid(state.win_id)
end

--- 刷新聊天窗口
function M.refresh()
  if not state.buf then return end
  _render()
end

--- 显示状态
function M.show_status()
  local agent = chat_service.get_current_agent()
  if not agent then
    vim.notify("[NeoAI] 无当前 Agent", vim.log.levels.WARN)
    return
  end
  local mode = display_modes.get_current()
  local mode_str = mode and (mode.label or mode.name) or "对话"
  vim.notify(
    string.format("[NeoAI] Agent: %s | 状态: %s | 消息: %d | 模型: %s | 显示: %s",
      agent.id, agent.state, #agent.messages, agent.model or "auto", mode_str),
    vim.log.levels.INFO
  )
end

--- 循环切换显示模式
--- @return table|nil 新激活的显示模式插件
function M.cycle_display()
  return display_modes.cycle()
end

--- 激活指定显示模式
--- @param name string 模式名（chat / trajectory / 自定义注册的模式）
--- @return table|nil
function M.set_display(name)
  return display_modes.activate(name)
end

--- 热重载显示模式插件（缺省重载当前激活的模式）
--- @param name string|nil
--- @return table|nil
function M.reload_display(name)
  return display_modes.reload(name)
end

--- 重置（测试用）
function M.reset()
  M.close()
end

return M
