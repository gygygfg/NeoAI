--- 子 Agent 监控面板
--- @module NeoAI.ui.components.sub_agent_dock
--- 展示子 Agent 的运行状态。

local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")

local M = {}

-- ========== 私有状态 ==========

local state = {
  win_id = nil,
  buf = nil,
  agents = {}, -- id -> { task, status, updated_at }
  unsub = nil,
  unsubs = {},
}

-- ========== 私有函数 ==========

local function _render()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end
  local lines = { "🛠 子 Agent 监控", "" }
  if next(state.agents) == nil then
    lines[#lines + 1] = "（无运行中的子 Agent）"
  else
    for id, a in pairs(state.agents) do
      local status_icon = a.status == "completed" and "✅" or (a.status == "error" and "❌" or "⏳")
      lines[#lines + 1] = string.format("%s %s  %s  %s", status_icon, id, a.status, a.task or "")
    end
  end
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
end

-- ========== 公开 API ==========

--- 打开子 Agent 监控面板
--- @return number win_id
function M.open()
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    return state.win_id
  end
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].filetype = "neoai_subagents"
  local width = math.min(60, vim.o.columns - 10)
  local height = math.min(12, vim.o.lines - 10)
  state.win_id = vim.api.nvim_open_win(state.buf, false, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = vim.o.lines - height - 2,
    style = "minimal",
    border = "rounded",
    title = "子 Agent",
    title_pos = "center",
  })
  _render()
  return state.win_id
end

--- 关闭面板
function M.close()
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    pcall(vim.api.nvim_win_close, state.win_id, true)
  end
  state.win_id = nil
  state.buf = nil
end

--- 启动事件监听
function M.init()
  if state.unsub then return end
  state.unsub = true
  state.unsubs = {
    event_bus.on(events.SUB_AGENT_CREATED, function(data)
      state.agents[data.sub_agent_id] = { task = data.task, status = "running" }
      _render()
    end),
    event_bus.on(events.SUB_AGENT_COMPLETED, function(data)
      local a = state.agents[data.sub_agent_id]
      if a then a.status = "completed" end
      _render()
    end),
    event_bus.on(events.SUB_AGENT_ERROR, function(data)
      local a = state.agents[data.sub_agent_id]
      if a then a.status = "error" end
      _render()
    end),
  }
end

--- 重置（测试用）
function M.reset()
  for _, u in ipairs(state.unsubs or {}) do
    if u then pcall(u) end
  end
  state.unsubs = {}
  state.unsub = nil
  state.agents = {}
  M.close()
end

return M
