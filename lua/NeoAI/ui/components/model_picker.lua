--- 模型选择器
--- @module NeoAI.ui.components.model_picker
--- 异步加载模型列表并弹出选择窗口。
--- - 无 api_key 的提供商不展示
--- - 按提供商分组折叠（expr 折叠，默认展开，可用 zc/za/zo 折叠/展开）
--- - 回车在模型行上选择正确模型；在提供商头行上切换折叠

local services = require("NeoAI.kernel.services")
local config_store = require("NeoAI.kernel.config_store")

local M = {}

-- ========== 私有状态 ==========

local state = {
  win_id = nil,
  buf = nil,
  on_select = nil,
  line_to_model = {}, -- buffer 行号 -> { provider, id }
  first_model_line = nil, -- 第一个模型行号（打开时定位光标）
  has_providers = false,
}

-- ========== 私有函数 ==========

--- 读取提供商配置中的 api_key（兼容字符串与取回函数）
--- @param provider table|nil
--- @return string
local function _get_api_key(provider)
  if not provider then return "" end
  local k = provider.api_key
  if type(k) == "function" then
    local ok, v = pcall(k)
    if not ok then return "" end
    return v or ""
  end
  return k or ""
end

--- 提供商是否配置了可用 api_key
--- @param provider_name string
--- @return boolean
local function _has_api_key(provider_name)
  local provider = (config_store.get("ai.providers") or {})[provider_name]
  return _get_api_key(provider) ~= ""
end

--- 将分组模型构建为展示行（纯函数，测试用）。
--- 过滤无 api_key 的提供商与无模型的组：
--- - 头行：提供商名（不进 line_to_model）
--- - 模型行：缩进 2 格的模型 id（进 line_to_model）
--- @param groups table { { provider, models = {...} } }
--- @return table { lines, line_to_model, first_model_line, providers }
local function _build_lines(groups)
  local lines = {}
  local line_to_model = {}
  local providers = {}
  local first_model_line = nil
  for _, group in ipairs(groups or {}) do
    if _has_api_key(group.provider) and group.models and #group.models > 0 then
      providers[#providers + 1] = group.provider
      lines[#lines + 1] = group.provider
      for _, m in ipairs(group.models) do
        local ln = #lines + 1
        if not first_model_line then first_model_line = ln end
        line_to_model[ln] = { provider = group.provider, id = m.id }
        lines[#lines + 1] = "  " .. m.id
      end
    end
  end
  return {
    lines = lines,
    line_to_model = line_to_model,
    first_model_line = first_model_line,
    providers = providers,
  }
end

--- 切换当前行所在的折叠（在提供商头行上按回车）
local function _toggle_fold()
  vim.cmd("normal! za")
end

--- 进入选择（在模型行上按回车）
local function _select()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local ln = cursor[1]
  local item = state.line_to_model[ln]
  if not item then
    _toggle_fold()
    return
  end
  local cb = state.on_select
  M.close()
  if cb then
    cb(item.id, item.provider)
  end
end

--- 配置按提供商折叠（expr：头行开折叠，模型行在折叠内）
local function _setup_folds()
  vim.wo[state.win_id].foldenable = true
  vim.wo[state.win_id].foldmethod = "expr"
  vim.wo[state.win_id].foldcolumn = "1"
  vim.wo[state.win_id].foldlevel = 99 -- 默认展开，模型可直接回车选择
  vim.wo[state.win_id].foldexpr = "v:lua.NeoAIModelPickerFoldExpr()"
  vim.wo[state.win_id].foldtext = "v:lua.NeoAIModelPickerFoldText()"
  -- 让新写入的折叠立即按 foldlevel 求值
  vim.cmd("silent! normal! zx")
end

-- 折叠求值回调：头行开折叠（>1），模型行在折叠内（1）。
-- 用全局函数引用（而非 v:lua.require'...'），带 UI 的会话里求值更稳定，与 chat_view 一致。
_G.NeoAIModelPickerFoldExpr = function()
  local ln = vim.v.lnum
  local text = vim.fn.getline(ln)
  if text == "" then return "0" end
  if text:sub(1, 1) == " " then return "1" end
  return ">1"
end

_G.NeoAIModelPickerFoldText = function()
  local first = vim.fn.getline(vim.v.foldstart)
  local count = vim.v.foldend - vim.v.foldstart
  return string.format("▸ %s (%d)", first, count)
end

-- ========== 公开 API ==========

--- 打开模型选择器
--- @param on_select function(model_id, provider)
function M.open(on_select)
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    return
  end
  state.buf = vim.api.nvim_create_buf(false, true)
  state.on_select = on_select
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
  local model_service = services.use("services.model_service")
  if not model_service then
    if vim.api.nvim_buf_is_valid(state.buf) then
      vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, { "模型服务未启用" })
    end
  else
    model_service.list():then_(function(groups)
      local data = _build_lines(groups)
      state.line_to_model = data.line_to_model
      state.first_model_line = data.first_model_line
      state.has_providers = #data.providers > 0

      local lines = data.lines
      if #lines == 0 then
        lines = { "未找到配置 api_key 的提供商" }
      end
      if vim.api.nvim_buf_is_valid(state.buf) then
        vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
      end

      -- 有模型时才开启按提供商折叠
      if state.has_providers and state.first_model_line then
        _setup_folds()
        vim.api.nvim_win_set_cursor(state.win_id, { state.first_model_line, 0 })
      end
    end):catch(function(e)
      if vim.api.nvim_buf_is_valid(state.buf) then
        vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, { "加载模型失败: " .. tostring(e.message or e) })
      end
    end)
  end

  -- 快捷键
  vim.keymap.set("n", "q", function() M.close() end, { buffer = state.buf })
  vim.keymap.set("n", "<Esc>", function() M.close() end, { buffer = state.buf })
  vim.keymap.set("n", "<CR>", _select, { buffer = state.buf })
end

--- 关闭选择器
function M.close()
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    pcall(vim.api.nvim_win_close, state.win_id, true)
  end
  state.win_id = nil
  state.buf = nil
  state.on_select = nil
  state.line_to_model = {}
  state.first_model_line = nil
  state.has_providers = false
end

--- 构建展示数据（纯函数，测试用）
--- @param groups table
--- @return table
function M.build_lines(groups)
  return _build_lines(groups)
end

--- 获取当前 buffer（测试用）
--- @return number|nil
function M.get_buf()
  return state.buf
end

--- 重置（测试用）
function M.reset()
  M.close()
end

return M
