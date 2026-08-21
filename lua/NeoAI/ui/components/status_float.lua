--- 状态悬浮窗
--- @module NeoAI.ui.components.status_float
--- 常驻于聊天窗口右上角的小型悬浮窗，实时显示：模式（计划/对话）、
--- 当前模型、Agent 状态、待办进度。随事件自动刷新，聊天窗口关闭时一并清理。

local config_store = require("NeoAI.kernel.config_store")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")
local stringx = require("NeoAI.utils.stringx")

local M = {}

-- ========== 私有状态 ==========

local state = {
  win_id = nil, -- 悬浮窗 win
  buf = nil, -- 悬浮窗 buffer
  parent = nil, -- 依附的聊天主窗口 win
  unsubs = {},
  augroup = nil,
}

-- ========== 私有函数 ==========

--- 生成悬浮窗内容行
--- @return table 行数组
local function _build_lines()
  local chat_service = require("NeoAI.services.chat_service")
  local agent = chat_service.get_current_agent()
  local plan = chat_service.get_plan_state()
  local todos = chat_service.get_todos()

  local lines = {}
  -- 模式徽标：单一模式循环 CHAT -> PLAN -> AUTO（AUTO 自动允许所有工具）
  local mode = chat_service.get_mode()
  local label = mode == "auto" and "AUTO" or (mode == "plan" and "PLAN" or "CHAT")
  lines[#lines + 1] = "[" .. label .. "]"
  if plan.active then
    if plan.plan and plan.plan ~= "" then
      lines[#lines + 1] = "计划: " .. stringx.truncate(plan.plan:gsub("%s+", " "), 48)
    else
      lines[#lines + 1] = "计划: (未提交)"
    end
  end
  if agent then
    lines[#lines + 1] = "模型: " .. (agent.model or "auto")
    lines[#lines + 1] = "状态: " .. (agent.state or "idle")
  end
  if todos and #todos > 0 then
    local done, active = 0, 0
    for _, it in ipairs(todos) do
      if it.status == "completed" then done = done + 1 end
      if it.status == "in_progress" then active = active + 1 end
    end
    local status = ("任务: %d/%d"):format(done, #todos)
    if active > 0 then status = status .. (" (进行中 %d)"):format(active) end
    lines[#lines + 1] = status
  end
  return lines
end

--- 计算内容最大行宽
--- @param lines table
--- @return number
local function _max_width(lines)
  local w = 0
  for _, l in ipairs(lines) do
    w = math.max(w, vim.fn.strwidth(l))
  end
  return w
end

--- 重新渲染 + 定位
function M.refresh()
  if not state.win_id or not vim.api.nvim_win_is_valid(state.win_id) then return end
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end
  if not state.parent or not vim.api.nvim_win_is_valid(state.parent) then return end

  local lines = _build_lines()
  local width = _max_width(lines) + 2
  local height = #lines
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)

  local parent_cfg = vim.api.nvim_win_get_config(state.win_id)
  parent_cfg.width = width
  parent_cfg.height = height
  parent_cfg.relative = "win"
  parent_cfg.win = state.parent
  parent_cfg.row = 0
  parent_cfg.col = math.max(0, vim.api.nvim_win_get_width(state.parent) - width - 1)
  pcall(vim.api.nvim_win_set_config, state.win_id, parent_cfg)
end

-- ========== 公开 API ==========

--- 在指定聊天主窗口上创建悬浮窗
--- @param parent_win number
function M.attach(parent_win)
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    M.refresh()
    return
  end
  state.parent = parent_win
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].filetype = "neoai_status"
  vim.bo[state.buf].bufhidden = "wipe"
  -- focusable = true 让徽标可点击切换（AUTO 模式）；点击后立即归还焦点到聊天主窗口。
  state.win_id = vim.api.nvim_open_win(state.buf, false, {
    relative = "win",
    win = parent_win,
    row = 0,
    col = 0,
    width = 1,
    height = 1,
    style = "minimal",
    focusable = true,
    noautocmd = true,
    border = "rounded",
    zindex = 200,
  })
  vim.wo[state.win_id].winhighlight = "NormalFloat:NeoAIStatusFloat,FloatBorder:FloatBorder"

  -- 点击徽标循环切换模式（CHAT/PLAN/AUTO）
  vim.keymap.set("n", "<LeftMouse>", function()
    local chat_service = require("NeoAI.services.chat_service")
    local names = { chat = "CHAT", plan = "PLAN", auto = "AUTO" }
    local mode = chat_service.cycle_mode()
    vim.notify("[NeoAI] 模式已切换: " .. (names[mode] or mode), vim.log.levels.INFO)
    -- 归还焦点到聊天主窗口，避免点击后浮窗抢占输入
    if state.parent and vim.api.nvim_win_is_valid(state.parent) then
      pcall(vim.api.nvim_set_current_win, state.parent)
    end
  end, { buffer = state.buf, desc = "NeoAI 切换模式（CHAT/PLAN/AUTO）" })

  -- 事件驱动刷新
  local refresh = function() M.refresh() end
  local subscribe = { events.PLAN_MODE_CHANGED, events.TODO_UPDATED, events.AGENT_STATE_CHANGED,
    events.MODEL_SWITCHED, events.MESSAGE_ADDED, events.GENERATION_STARTED,
    events.GENERATION_COMPLETED, events.GENERATION_ERROR, events.AGENT_ABORTED,
    events.SESSION_LOADED, events.AUTO_MODE_CHANGED }
  for _, ev in ipairs(subscribe) do
    state.unsubs[#state.unsubs + 1] = event_bus.on(ev, refresh)
  end

  -- 编辑器尺寸变化时重新定位
  state.augroup = vim.api.nvim_create_augroup("NeoAIStatusFloat", {})
  vim.api.nvim_create_autocmd("VimResized", {
    group = state.augroup,
    callback = function() M.refresh() end,
  })

  M.refresh()
end

--- 关闭并清理
function M.detach()
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    state.augroup = nil
  end
  for _, unsub in ipairs(state.unsubs) do
    pcall(unsub)
  end
  state.unsubs = {}
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    pcall(vim.api.nvim_win_close, state.win_id, true)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  state.win_id = nil
  state.buf = nil
  state.parent = nil
end

--- 是否已挂载
--- @return boolean
function M.is_attached()
  return state.win_id ~= nil and vim.api.nvim_win_is_valid(state.win_id)
end

return M