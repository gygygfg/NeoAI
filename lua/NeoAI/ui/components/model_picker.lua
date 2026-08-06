--- 模型选择器
--- @module NeoAI.ui.components.model_picker
--- 异步加载模型列表并弹出选择窗口。

local model_service = require("NeoAI.services.model_service")

local M = {}

-- ========== 私有状态 ==========

local state = {
  win_id = nil,
  buf = nil,
  models = {}, -- { { provider, id } }
}

-- ========== 公开 API ==========

--- 打开模型选择器
--- @param on_select function(model_id, provider)
function M.open(on_select)
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    return
  end
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].filetype = "neoai_model_picker"
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, { "加载模型列表..." })

  local width = math.min(60, vim.o.columns - 10)
  local height = math.min(20, vim.o.lines - 10)
  state.win_id = vim.api.nvim_open_win(state.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = "🤖 选择模型",
    title_pos = "center",
  })

  -- 加载模型
  model_service.list():then_(function(groups)
    local lines = {}
    state.models = {}
    for _, group in ipairs(groups) do
      lines[#lines + 1] = "── " .. group.provider .. " ──"
      for _, m in ipairs(group.models) do
        state.models[#state.models + 1] = { provider = group.provider, id = m.id }
        lines[#lines + 1] = string.format("%d. %s", #state.models, m.id)
      end
    end
    if vim.api.nvim_buf_is_valid(state.buf) then
      vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
    end
  end):catch(function(e)
    if vim.api.nvim_buf_is_valid(state.buf) then
      vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, { "加载模型失败: " .. tostring(e.message or e) })
    end
  end)

  -- 快捷键
  vim.keymap.set("n", "q", function() M.close() end, { buffer = state.buf })
  vim.keymap.set("n", "<Esc>", function() M.close() end, { buffer = state.buf })
  vim.keymap.set("n", "<CR>", function()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local idx = cursor[1]
    local item = state.models[idx]
    if item then
      on_select(item.id, item.provider)
    end
    M.close()
  end, { buffer = state.buf })
end

--- 关闭选择器
function M.close()
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    pcall(vim.api.nvim_win_close, state.win_id, true)
  end
  state.win_id = nil
  state.buf = nil
  state.models = {}
end

--- 重置（测试用）
function M.reset()
  M.close()
end

return M
