--- 接收工具参数面板
--- @module NeoAI.ui.components.tool_args_panel
--- 在独立浮动窗口实时展示模型流式生成的工具调用参数，支持随分片更新与关闭，
--- 与思考过程悬浮窗（reasoning_panel）行为一致。

local M = {}

local json = require("NeoAI.utils.json")

-- ========== 私有状态 ==========

local state = {
  win_id = nil,
  buf = nil,
}

-- ========== 私有函数 ==========

--- 把累积的工具调用快照格式化为展示文本（多行）
--- @param tool_calls table 数组 { id, function = { name, arguments } }
--- @return string
local function _format_tool_calls(tool_calls)
  if not tool_calls or #tool_calls == 0 then return "等待工具参数…" end
  local lines = {}
  for _, tc in ipairs(tool_calls) do
    local fn = tc["function"] or {}
    local name = fn.name or "unknown"
    local args = fn.arguments
    if type(args) ~= "string" or args == "" then
      lines[#lines + 1] = ("  ⏳ 正在接收参数: %s"):format(name)
    else
      -- 参数仍在流式累积，可能是残缺 JSON：可解析则缩进展示，否则原样展示。
      local decoded = json.decode_or_nil(args)
      local body
      if decoded ~= nil then
        body = json.encode(decoded)
      else
        body = args
      end
      lines[#lines + 1] = ("  ⏳ 正在接收参数: %s"):format(name)
      for _, l in ipairs(vim.split(body, "\n", { plain = true })) do
        lines[#lines + 1] = "    " .. l
      end
    end
  end
  return table.concat(lines, "\n")
end

-- ========== 公开 API ==========

--- 打开面板
--- @param title string|nil
--- @return number win_id
function M.open(title)
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    return state.win_id
  end
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].filetype = "neoai_tool_args"
  local width = math.min(70, vim.o.columns - 10)
  local height = math.min(6, vim.o.lines - 10)
  state.win_id = vim.api.nvim_open_win(state.buf, false, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = 2,
    style = "minimal",
    border = "rounded",
    title = title or "🔧 接收参数",
    title_pos = "center",
  })
  vim.wo[state.win_id].wrap = true
  -- 参数接收悬浮窗内容禁止折叠：minimal 浮窗会继承全局 foldenable/foldmethod，
  -- 导致参数内容被自动收起而看不到。
  vim.wo[state.win_id].foldenable = false
  vim.wo[state.win_id].foldmethod = "manual"
  vim.wo[state.win_id].foldcolumn = "0"
  return state.win_id
end

--- 展示工具调用参数快照（替换内容）
--- @param tool_calls table 数组 { id, function = { name, arguments } }
function M.show(tool_calls)
  M.open()
  if not vim.api.nvim_buf_is_valid(state.buf) then return end
  local content = _format_tool_calls(tool_calls)
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, vim.split(content, "\n", { plain = true }))
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    vim.api.nvim_win_set_cursor(state.win_id, { vim.api.nvim_buf_line_count(state.buf), 0 })
  end
end

--- 面板当前展示的文本（测试用）
--- @return string
function M.get_content()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return "" end
  return table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
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
