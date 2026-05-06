--- 子 agent 状态监控悬浮窗
--- 实时显示所有子 agent 的执行状态、进度、工具调用等信息
local M = {}

local logger = require("NeoAI.utils.logger")
local window_manager = require("NeoAI.ui.window.window_manager")

local state = {
  initialized = false,
  config = {},
  window_id = nil,
  is_visible = false,
  -- 关联的 sub_agent_ids -> 显示信息缓存
  monitored_agents = {},
  -- 定时刷新 timer
  refresh_timer = nil,
  -- 上次渲染的内容 hash，避免无意义刷新
  last_content_hash = nil,
}

local function buf_valid(buf) return buf and vim.api.nvim_buf_is_valid(buf) end
local function win_valid(win) return win and vim.api.nvim_win_is_valid(win) end

--- 初始化
function M.initialize(config)
  if state.initialized then return end
  state.config = config or {}
  state.initialized = true
end

--- 生成子 agent 状态行
local function _format_agent_line(sa)
  local status_icons = {
    running = "⏳",
    completed = "✅",
    rejected = "⛔",
    timeout = "⌛",
    error = "❌",
  }
  local icon = status_icons[sa.status] or "❓"
  local task_short = sa.task:len() > 40 and sa.task:sub(1, 40) .. "…" or sa.task
  local info = string.format("%s %s", icon, task_short)
  if sa.status == "running" then
    local calls = sa.tool_call_count or 0
    local iters = sa.iteration_count or 0
    local max_calls = sa.max_tool_calls or 30
    local max_iters = sa.max_iterations or 10
    info = info .. string.format(" [调用:%d/%d 轮:%d/%d]", calls, max_calls, iters, max_iters)
  end
  if sa.status == "completed" or sa.status == "rejected" or sa.status == "timeout" then
    local duration = (sa.created_at and os.time() - sa.created_at) or 0
    info = info .. string.format(" (%ds)", duration)
  end
  return info
end

--- 生成完整的内容行
local function _build_content(agents_data)
  local lines = {}
  table.insert(lines, "=== 🤖 子 Agent 监控 ===")
  table.insert(lines, "")

  if not agents_data or #agents_data == 0 then
    table.insert(lines, "  暂无活跃子 agent")
    table.insert(lines, "")
    table.insert(lines, "---")
    table.insert(lines, "按 q / <Esc> 关闭")
    return lines
  end

  -- 按创建时间排序（最新的在前）
  table.sort(agents_data, function(a, b)
    return (a.created_at or 0) > (b.created_at or 0)
  end)

  for i, sa in ipairs(agents_data) do
    local line = _format_agent_line(sa)
    table.insert(lines, line)

    -- 运行中的 agent 显示更多详情
    if sa.status == "running" then
      if sa.last_tool_call then
        local tool_short = sa.last_tool_call:len() > 50 and sa.last_tool_call:sub(1, 50) .. "…" or sa.last_tool_call
        table.insert(lines, string.format("  └─ 最近调用: %s", tool_short))
      end
      if #sa.rejected_calls > 0 then
        table.insert(lines, string.format("  └─ 被驳回: %d 次", #sa.rejected_calls))
      end
    end

    -- 已完成/出错的显示总结摘要
    if sa.summary and (sa.status == "completed" or sa.status == "error" or sa.status == "rejected" or sa.status == "timeout") then
      local summary_short = sa.summary:gsub("\n", " "):sub(1, 60)
      table.insert(lines, string.format("  └─ %s", summary_short))
    end

    if i < #agents_data then
      table.insert(lines, "")
    end
  end

  table.insert(lines, "")
  table.insert(lines, "---")
  table.insert(lines, "按 q / <Esc> 关闭 | 自动刷新中")

  return lines
end

--- 计算内容 hash 用于去重
local function _content_hash(lines)
  return vim.fn.sha256(table.concat(lines, "\n"))
end

--- 渲染窗口内容（必须在主线程调用）
--- 如果窗口不存在，自动创建
local function _render()
  -- 如果窗口不存在，自动创建
  if not state.window_id then
    _create_window()
    if not state.window_id then return end
  end

  -- 从 plan_executor 获取最新的 agent 数据（使用同步接口）
  local ok, plan_executor = pcall(require, "NeoAI.tools.builtin.plan_executor")
  if not ok then return end

  local enriched = {}
  if plan_executor.get_all_agents_data then
    enriched = plan_executor.get_all_agents_data()
  end

  local lines = _build_content(enriched)

  local wi = window_manager.get_window_info(state.window_id)
  if not wi or not buf_valid(wi.buf) or not win_valid(wi.win) then
    state.window_id = nil
    state.is_visible = false
    return
  end

  local buf = wi.buf
  pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = buf })
  pcall(vim.api.nvim_set_option_value, "readonly", false, { buf = buf })
  pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines)
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = buf })

  -- 滚动到顶部
  pcall(vim.api.nvim_win_set_cursor, wi.win, { 1, 0 })
end

--- 安全渲染：通过 vim.schedule 将渲染调度到主线程执行
function M._safe_render()
  vim.schedule(function()
    _render()
  end)
end

--- 创建监控窗口
local function _create_window()
  if state.window_id then return end

  -- 计算窗口尺寸
  local editor_width = vim.o.columns
  local editor_height = vim.o.lines
  local win_width = math.min(80, math.floor(editor_width * 0.6))
  local win_height = math.min(20, math.floor(editor_height * 0.4))

  state.window_id = window_manager.create_window("tool_display", {
    title = "🤖 子 Agent 监控",
    width = win_width,
    height = win_height,
    border = "rounded",
    style = "minimal",
    relative = "editor",
    row = math.floor((editor_height - win_height) / 2),
    col = math.floor((editor_width - win_width) / 2),
    zindex = 150,
    window_mode = "float",
  })

  if not state.window_id then
    logger.error("[sub_agent_monitor] 创建监控窗口失败")
    return
  end

  state.is_visible = true

  -- 设置按键映射
  local wi = window_manager.get_window_info(state.window_id)
  if wi and buf_valid(wi.buf) then
    local buf = wi.buf
    local function close()
      M.close()
    end
    vim.keymap.set("n", "q", close, { buffer = buf, silent = true, noremap = true, desc = "关闭监控" })
    vim.keymap.set("n", "<Esc>", close, { buffer = buf, silent = true, noremap = true, desc = "关闭监控" })
  end

  -- 启动定时刷新（每 1 秒刷新一次）
  if state.refresh_timer then
    vim.fn.timer_stop(state.refresh_timer)
  end
  state.refresh_timer = vim.fn.timer_start(1000, function()
    if not state.window_id then
      if state.refresh_timer then
        vim.fn.timer_stop(state.refresh_timer)
        state.refresh_timer = nil
      end
      return
    end
    _safe_render()
  end, { ["repeat"] = -1 })
end

--- 显示监控悬浮窗
function M.show()
  if not state.initialized then return end

  -- 如果窗口已存在，直接刷新
  if state.window_id then
    _render()
    return
  end

  -- 创建窗口
  _create_window()

  -- 渲染内容
  if state.window_id then
    _render()
  end
end

--- 关闭监控悬浮窗
function M.close()
  if state.refresh_timer then
    vim.fn.timer_stop(state.refresh_timer)
    state.refresh_timer = nil
  end

  if state.window_id then
    window_manager.close_window(state.window_id)
    state.window_id = nil
  end

  state.is_visible = false
  state.last_content_hash = nil
end

--- 切换显示/隐藏
function M.toggle()
  if state.is_visible then
    M.close()
  else
    M.show()
  end
end

--- 获取是否可见
function M.is_visible()
  return state.is_visible
end

return M
