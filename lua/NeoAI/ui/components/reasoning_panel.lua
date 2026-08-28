--- 思考过程面板
--- @module NeoAI.ui.components.reasoning_panel
--- 在独立浮动窗口展示 AI 推理内容，支持实时追加与关闭。

local M = {}

-- ========== 私有状态 ==========

local state = {
  win_id = nil,
  buf = nil,
}

-- ========== 公开 API ==========

--- 打开推理面板
--- @param title string|nil
--- @return number win_id
function M.open(title)
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    return state.win_id
  end
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].filetype = "neoai_reasoning"
  local width = math.min(70, vim.o.columns - 10)
  local height = math.min(5, vim.o.lines - 10)
  state.win_id = vim.api.nvim_open_win(state.buf, false, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = 7,
    style = "minimal",
    border = "rounded",
    title = title or "🤔 思考过程",
    title_pos = "center",
  })
  vim.wo[state.win_id].wrap = true
  -- 思考过程悬浮窗内容禁止折叠：minimal 浮窗会继承全局 foldenable/foldmethod
  -- （如用户的 foldmethod=indent + foldenable），导致推理内容被自动收起而看不到。
  vim.wo[state.win_id].foldenable = false
  vim.wo[state.win_id].foldmethod = "manual"
  vim.wo[state.win_id].foldcolumn = "0"
  return state.win_id
end

--- 显示内容
--- @param content string
function M.show(content)
  M.open()
  if vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, vim.split(content or "", "\n", { plain = true }))
    if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
      vim.api.nvim_win_set_cursor(state.win_id, { vim.api.nvim_buf_line_count(state.buf), 0 })
    end
  end
end

--- 追加内容
--- @param content string
function M.append(content)
  if not content or content == "" then return end
  M.open()
  if not vim.api.nvim_buf_is_valid(state.buf) then return end
  local line_count = vim.api.nvim_buf_line_count(state.buf)
  local lines = vim.split(content, "\n", { plain = true })
  -- 流式分片可能从一行中间开始，先续接已有末行，再追加其余新行。
  lines[1] = vim.api.nvim_buf_get_lines(state.buf, line_count - 1, line_count, false)[1] .. lines[1]
  vim.api.nvim_buf_set_lines(state.buf, line_count - 1, line_count, false, lines)
  -- 光标随新增内容向下移动，窗口到达底部后自然滚动。
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    vim.api.nvim_win_set_cursor(state.win_id, { vim.api.nvim_buf_line_count(state.buf), 0 })
  end
end

--- 关闭面板
function M.close()
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    pcall(vim.api.nvim_win_close, state.win_id, true)
  end
  state.win_id = nil
  state.buf = nil
end

--- 是否打开
--- @return boolean
function M.is_open()
  return state.win_id ~= nil and vim.api.nvim_win_is_valid(state.win_id)
end

--- 重置（测试用）
function M.reset()
  M.close()
end

return M
