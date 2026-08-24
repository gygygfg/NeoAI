--- 聊天视图
--- @module NeoAI.ui.window.chat_view
--- 聊天窗口渲染与交互。绑定事件，流式更新。
--- 布局：主消息区（上） + 输入框（下，split）。

local window_manager = require("NeoAI.ui.window.manager")
local message_list = require("NeoAI.ui.components.message_list")
local input_box = require("NeoAI.ui.components.input_box")
local model_picker = require("NeoAI.ui.components.model_picker")
local reasoning_panel = require("NeoAI.ui.components.reasoning_panel")
local status_float = require("NeoAI.ui.components.status_float")
local fold = require("NeoAI.ui.components.fold")
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
}

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

--- 渲染全部消息
local function _render()
  -- 不跟随（用户回看上方内容）时记录已展开的折叠块，重写 buffer 后恢复其展开状态，
  -- 避免把用户正在查看的内容重新折叠起来。
  local open_folds = {}
  if not state.following then
    open_folds = _open_fold_start_lines()
  end
  local messages = chat_service.get_messages()
  message_list.render(state.buf, messages)
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    vim.api.nvim_win_call(state.win_id, function()
      -- 每次重写 buffer 后，expr 折叠并不会自动重算（带 UI 会话里 nvim_buf_set_lines
      -- 不触发 foldexpr 求值，导致 foldlevel 全为 0、折叠失效）。先 zx 强制按 foldexpr
      -- 重算折叠。光标跟随（底部）时 zM 全部收起（zc 只对光标处的折叠生效，其它位置会报 E490）；
      -- 光标不跟随（用户正在回看上方内容）时只重算、不收起，并把重写前已展开的折叠重新展开，
      -- 保留用户当前查看的折叠状态（zx 会保留手动开合的折叠状态，但整块 buffer 重写会丢失它）。
      if state.following then
        vim.cmd("silent! normal! zxzM")
      else
        vim.cmd("silent! normal! zx")
        -- 记录光标位置，重开折叠后恢复：不跟随说明用户正在回看上方，不能被拽走。
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
end

-- 渲染合并：流式分片 / 工具事件在同一个事件循环 tick 内可能连续触发多次，
-- 每次都同步全量重渲染 + zxzM 折叠重算会占满主线程，第二/多轮（历史消息更多）
-- 时尤其明显，表现为"主界面卡住"。这里把渲染延后到本 tick 结束，合并为一次。
local render_scheduled = false
local render_pending_follow = false
local render_flushed = false

--- 执行一次实际渲染（由调度回调或 flush 调用）
local function _do_render()
  render_scheduled = false
  render_flushed = true
  _render()
  if render_pending_follow then
    _scroll_to_end()
  end
end

--- 调度一次渲染（合并同一 tick 内的多次更新）
local function _schedule_render()
  if render_scheduled then return end
  render_scheduled = true
  render_flushed = false
  -- 在渲染前判断是否跟随（_render 内 zxzM 会把光标从收起的折叠块内拽到折叠首行，
  -- 渲染后再判断会导致跟随失效），把决定缓存在调度时，并同步给 state.following
  -- （不跟随时用于抑制思考悬浮窗弹出与折叠收起）。
  render_pending_follow = _cursor_within_follow_margin()
  state.following = render_pending_follow
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
  _schedule_render()
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

--- @param payload table
local function _on_generation_finished(payload)
  _close_reasoning_panel(payload)
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
  if payload and payload.agent_id == state.agent_id then
    _focus_input_insert()
  end
end

--- 提交输入
--- @param content string
local function _on_submit(content)
  input_box.on_submitted()
  -- 发送后切回主窗口并进入普通模式：生成期间可随时滚动查看流式输出
  _focus_main_normal()
  chat_service.send_message(content):catch(function(e)
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
      vim.notify("[NeoAI] 模式已切换: " .. (names[mode] or mode), vim.log.levels.INFO)
      _render()
    end,
    approve_plan = function()
      local function report(result)
        if result and result.approved then
          vim.notify(("[NeoAI] 计划已确认，已转入 CHAT 模式，任务清单 %d 项"):format(result.todo_count or 0), vim.log.levels.INFO)
        else
          vim.notify("[NeoAI] 确认计划失败: " .. tostring(result and result.error or "未知错误"), vim.log.levels.WARN)
        end
        _render()
      end
      local result = chat_service.approve_plan()
      if result and result.then_ then
        result:then_(report, function(err)
          vim.notify("[NeoAI] 确认计划失败: " .. tostring(err and err.message or err), vim.log.levels.WARN)
          _render()
        end)
      else
        report(result)
      end
    end,
    tool_approval = function()
      require("NeoAI.ui.components.tool_approval").init()
    end,
  }
end

--- 创建输入区（主窗口下方 split，高度 3）
local function _create_input_area()
  -- 在当前主窗口下方水平分割
  local win
  vim.api.nvim_win_call(state.win_id, function()
    vim.cmd("belowright split")
    win = vim.api.nvim_get_current_win()
  end)
  vim.api.nvim_win_set_height(win, 3)
  input_box.create({
    on_submit = _on_submit,
    on_cancel = _on_cancel,
    on_quit = function() M.close() end,
    -- 同步主界面的 chat 上下文按键到输入框（quit/cancel/toggle_reasoning/switch_model/cycle_mode/tool_approval）
    chat_actions = _build_chat_actions(),
  })
  input_box.attach_window(win)
  vim.wo[win].winfixheight = true
  vim.wo[win].wrap = false
  state.input_win_id = win
  return win
end

--- 设置键位（主窗口）
local function _set_keymaps()
  local keymap = require("NeoAI.ui.keymap")
  keymap.register_context("chat", _build_chat_actions(), state.buf)
  -- 主窗口 j/k 滚动
  vim.keymap.set("n", "j", function() _scroll(1) end, { buffer = state.buf })
  vim.keymap.set("n", "k", function() _scroll(-1) end, { buffer = state.buf })
end

--- 主窗口滚动
local function _scroll(delta)
  if not state.win_id or not vim.api.nvim_win_is_valid(state.win_id) then return end
  local cur = vim.api.nvim_win_get_cursor(state.win_id)
  local total = vim.api.nvim_buf_line_count(state.buf)
  local new_line = math.max(1, math.min(total, cur[1] + delta))
  vim.api.nvim_win_set_cursor(state.win_id, { new_line, cur[2] })
end

-- ========== 公开 API ==========

--- 打开聊天窗口
--- @param opts table|nil { session_id? }
--- @return table { win_id, buf }
function M.open(opts)
  opts = opts or {}
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    if opts.session_id and opts.session_id ~= chat_service.get_current_session_id() then
      -- Tree selection must replace the active conversation, not reuse its buffer.
      chat_service.detach_window(state.win_id)
      local agent = chat_service.load_session(opts.session_id)
      state.agent_id = agent.id
      chat_service.attach_window(state.win_id, agent)
      reasoning_panel.close()
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
    status_float.attach(state.win_id)
    return { win_id = state.win_id, buf = state.buf }
  end

  local created = window_manager.create("chat", { title = "NeoAI Chat" })
  state.win_id = created.win_id
  state.buf = created.buf
  state.following = true
  vim.bo[state.buf].modifiable = true
  vim.wo[state.win_id].wrap = true
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
  -- 常驻状态悬浮窗（模式/模型/状态/待办）
  status_float.attach(state.win_id)

  -- 获取/创建 Agent（若有 session_id 则加载已有会话）
  local agent
  if opts.session_id then
    agent = chat_service.load_session(opts.session_id)
  else
    agent = chat_service.new_session({})
  end
  state.agent_id = agent.id
  chat_service.attach_window(state.win_id, agent)

  _render()
  _set_keymaps()
  _create_input_area()
  input_box.focus()

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
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.GENERATION_COMPLETED, _on_agent_end)
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.GENERATION_ERROR, _on_agent_end)
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.AGENT_ABORTED, _on_agent_end)

  return { win_id = state.win_id, buf = state.buf }
end

--- 关闭聊天窗口
function M.close()
  _stop_tool_tick()
  fold.clear_timing()
  reasoning_panel.close()
  -- 清理缓存中的推理分片与待调度渲染，避免窗口重开后残留
  reasoning_pending = ""
  reasoning_flush_scheduled = false
  reasoning_cancelled = true
  render_scheduled = false
  status_float.detach()
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
  vim.notify(
    string.format("[NeoAI] Agent: %s | 状态: %s | 消息: %d | 模型: %s",
      agent.id, agent.state, #agent.messages, agent.model or "auto"),
    vim.log.levels.INFO
  )
end

--- 重置（测试用）
function M.reset()
  M.close()
end

return M
