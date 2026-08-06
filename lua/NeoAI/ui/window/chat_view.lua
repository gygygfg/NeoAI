--- 聊天视图
--- @module NeoAI.ui.window.chat_view
--- 聊天窗口渲染与交互。绑定事件，流式更新。
--- 布局：主消息区（上） + 输入框（下，split）。

local window_manager = require("NeoAI.ui.window.manager")
local message_list = require("NeoAI.ui.components.message_list")
local input_box = require("NeoAI.ui.components.input_box")
local model_picker = require("NeoAI.ui.components.model_picker")
local reasoning_panel = require("NeoAI.ui.components.reasoning_panel")
local chat_service = require("NeoAI.services.chat_service")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")

local M = {}

--- 推理折叠的单行占位文本
--- @return string
function M.foldtext()
  local count = vim.v.foldend - vim.v.foldstart + 1
  return string.format("  🤔 思考过程 %d 行", count)
end

-- ========== 私有状态 ==========

local state = {
  win_id = nil, -- 主窗口
  buf = nil, -- 主 buffer（消息列表）
  input_win_id = nil, -- 输入窗口
  unsubs = {},
  agent_id = nil,
}

-- ========== 私有函数 ==========

--- 渲染全部消息
local function _render()
  local messages = chat_service.get_messages()
  message_list.render(state.buf, messages)
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    vim.api.nvim_win_call(state.win_id, function()
      -- Close every reasoning fold after replacing buffer content. `zc` only works
      -- at a fold cursor position and raises E490 when the cursor is elsewhere.
      vim.cmd("silent! normal! zM")
    end)
  end
end

--- 刷新/滚动到底部
local function _scroll_to_end()
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    local line_count = vim.api.nvim_buf_line_count(state.buf)
    vim.api.nvim_win_set_cursor(state.win_id, { math.max(1, line_count), 0 })
  end
end

--- 流式更新当前消息
--- @param payload table
local function _on_message_updated(payload)
  if not payload or not payload.agent_id then return end
  if payload.agent_id ~= state.agent_id then return end
  if payload.message and payload.message.content ~= "" then
    reasoning_panel.close()
  end
  _render()
  _scroll_to_end()
end

--- 实时显示当前 Agent 的推理；正文开始或推理结束后会自动关闭。
--- @param payload table
local function _on_reasoning_chunk(payload)
  if not payload or payload.agent_id ~= state.agent_id then return end
  if payload.chunk then
    reasoning_panel.append(payload.chunk)
  else
    reasoning_panel.show(payload.reasoning)
  end
end

--- @param payload table
local function _close_reasoning_panel(payload)
  if not payload or payload.agent_id ~= state.agent_id then return end
  reasoning_panel.close()
end

--- @param payload table
local function _on_generation_finished(payload)
  _close_reasoning_panel(payload)
  _on_message_updated(payload)
end

--- 提交输入
--- @param content string
local function _on_submit(content)
  input_box.on_submitted()
  chat_service.send_message(content):catch(function(e)
    vim.notify("[NeoAI] 发送失败: " .. tostring(e.message or e), vim.log.levels.ERROR)
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
  local actions = {
    quit = function() M.close() end,
    cancel = _on_cancel,
    toggle_reasoning = function()
      message_list.toggle_reasoning()
      _render()
    end,
    switch_model = _switch_model,
    insert = function() input_box.focus() end,
    send = function() input_box.focus() end,
    tool_approval = function()
      local approval_ui = require("NeoAI.ui.components.tool_approval")
      approval_ui.init()
    end,
  }
  keymap.register_context("chat", actions, state.buf)
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
    vim.api.nvim_set_current_win(state.win_id)
    return { win_id = state.win_id, buf = state.buf }
  end

  local created = window_manager.create("chat", { title = "NeoAI Chat" })
  state.win_id = created.win_id
  state.buf = created.buf
  vim.bo[state.buf].modifiable = true
  vim.wo[state.win_id].wrap = true
  -- 推理正文由 message_list 缩进两个空格，标题保持可见。
  -- 显式开启 foldenable，避免继承用户全局 foldenable=false 导致无法折叠
  vim.wo[state.win_id].foldmethod = "indent"
  vim.wo[state.win_id].foldtext = "v:lua.require'NeoAI.ui.window.chat_view'.foldtext()"
  vim.bo[state.buf].shiftwidth = 2
  vim.wo[state.win_id].foldenable = true
  vim.wo[state.win_id].foldlevel = 0

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
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.REASONING_CHUNK, _on_reasoning_chunk)
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.REASONING_COMPLETED, _close_reasoning_panel)
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.GENERATION_COMPLETED, _on_generation_finished)
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.GENERATION_ERROR, _on_generation_finished)
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.AGENT_ABORTED, _close_reasoning_panel)

  return { win_id = state.win_id, buf = state.buf }
end

--- 关闭聊天窗口
function M.close()
  reasoning_panel.close()
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
