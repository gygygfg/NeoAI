--- 向用户提问弹窗
--- @module NeoAI.ui.components.ask_user
--- 注册到 NeoAI.tools.builtin.ask_user。显示问题 + 可选选项：
--- 数字键 1-9 直接选择选项；i / 回车进入自由输入（vim.ui.input）；Esc 取消提问。

local ui_hooks = require("NeoAI.kernel.ui_hooks")
local geometry = require("NeoAI.ui.geometry")

local M = {}

-- ========== 私有状态 ==========

local state = {
  win_id = nil,
  buf = nil,
  on_answer = nil,
  on_cancel = nil,
}

-- 高亮命名空间：选项简介 / 选项描述各用一组高亮
local HL_NS = vim.api.nvim_create_namespace("neoai_ask_user_hi")

--- 定义高亮组（default=true，不覆盖用户自定义；兼容无外部依赖）
local function _setup_hl()
  vim.api.nvim_set_hl(0, "NeoAIAskUserOptionLabel", { default = true, bold = true })
  vim.api.nvim_set_hl(0, "NeoAIAskUserOptionDesc", { default = true, fg = "#8a8a8a" })
end

--- 归一化选项：兼容纯字符串或 { label, description } 对象
--- @param opts table 数组，元素为 string 或 { label, description }
--- @return table 数组 { label, description }
local function _normalize_options(opts)
  local out = {}
  for _, o in ipairs(opts or {}) do
    if type(o) == "string" then
      if o ~= "" then out[#out + 1] = { label = o, description = "" } end
    elseif type(o) == "table" then
      local label = type(o.label) == "string" and o.label or ""
      if label == "" and type(o.name) == "string" then label = o.name end
      if label ~= "" then
        local description = type(o.description) == "string" and o.description or ""
        if description == "" and type(o.desc) == "string" then description = o.desc end
        out[#out + 1] = { label = label, description = description }
      end
    end
  end
  return out
end

-- ========== 私有函数 ==========

local function _close()
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    pcall(vim.api.nvim_win_close, state.win_id, true)
  end
  geometry.untrack(state.win_id)
  state.win_id = nil
  state.buf = nil
  state.on_answer = nil
  state.on_cancel = nil
end

--- 自由文本输入（vim.ui.input 原生输入行）
local function _ask_free_text(question)
  vim.ui.input({ prompt = question .. " " }, function(answer)
    if answer == nil then
      -- 用户按 Esc 关闭输入行：视为取消
      local cb = state.on_cancel
      _close()
      if cb then cb("未输入") end
    else
      local cb = state.on_answer
      _close()
      if cb then cb(answer) end
    end
  end)
end

--- 设置快捷键（普通模式 + 插入模式，理由同 tool_approval）
local function _set_keymaps()
  if not state.buf then return end
  local question = state._question or ""

  local function bind(mode, key, fn)
    if not key or key == "" then return end
    vim.keymap.set(mode, key, fn, { buffer = state.buf })
  end

  -- 先捕获回调并关窗，再调用回调（回调可能同步打开下一个弹窗并重写 state.win_id）
  local function close_then(cb, ...)
    local args = { ... }
    local handler = cb
    _close()
    if handler then handler(unpack(args)) end
  end

  -- 自由输入：只关弹窗（展示层），保留 on_answer/on_cancel 直到 vim.ui.input 完成
  local function close_win_only()
    if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
      pcall(vim.api.nvim_win_close, state.win_id, true)
    end
    state.win_id = nil
    state.buf = nil
  end

  for _, mode in ipairs({ "n", "i" }) do
    -- 数字键选择选项（最多 9 个）
    for i = 1, 9 do
      bind(mode, tostring(i), function()
        local opt = state._options and state._options[i]
        if not opt then return end
        close_then(state.on_answer, opt.label or "")
      end)
    end
    -- 自由输入
    bind(mode, "i", function()
      close_win_only()
      _ask_free_text(question)
    end)
    bind(mode, "<CR>", function()
      close_win_only()
      _ask_free_text(question)
    end)
    -- 取消
    bind(mode, "<Esc>", function()
      close_then(state.on_cancel, "用户取消")
    end)
  end
end

-- ========== 公开 API ==========

--- 展示提问弹窗（实际建窗）
--- @param config table { question, options, on_answer, on_cancel }
local function _present(config)
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    _close()
  end
  state.on_answer = config.on_answer
  state.on_cancel = config.on_cancel
  state._question = config.question
  state._options = _normalize_options(config.options)

  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].filetype = "neoai_ask_user"
  local lines = vim.split(config.question or "", "\n", { plain = true })
  -- { line = 0-based, col, len, group }，随内容行构建，set_lines 后统一高亮
  local highlights = {}
  if #state._options > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "选项:"
    for i, opt in ipairs(state._options) do
      local label_line = #lines + 1
      lines[#lines + 1] = string.format("  [%d] %s", i, opt.label)
      local label_col = (#("  [" .. i .. "] ")) -- 0-based：选项简介起始列
      highlights[#highlights + 1] = { line = label_line - 1, col = label_col, len = #opt.label, group = "NeoAIAskUserOptionLabel" }
      if opt.description and opt.description ~= "" then
        local desc_line = #lines + 1
        lines[#lines + 1] = string.format("        %s", opt.description)
        highlights[#highlights + 1] = { line = desc_line - 1, col = 8, len = #opt.description, group = "NeoAIAskUserOptionDesc" }
      end
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "快捷键: [1-9] 选择选项    [i / 回车] 自由输入    [Esc] 取消"
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)

  _setup_hl()
  vim.api.nvim_buf_clear_namespace(state.buf, HL_NS, 0, -1)
  for _, h in ipairs(highlights) do
    pcall(vim.api.nvim_buf_add_highlight, state.buf, HL_NS, h.group, h.line, h.col, h.col + h.len)
  end

  local geom_opts = { w_ratio = 0.66, h_ratio = 0.60, fit_h = #lines + 4 }
  local geom = geometry.compute(geom_opts)
  local ok, wid = pcall(vim.api.nvim_open_win, state.buf, true, {
    relative = "editor",
    width = geom.width,
    height = geom.height,
    col = geom.col,
    row = geom.row,
    style = "minimal",
    border = "rounded",
    title = "❓ 向用户提问",
    title_pos = "center",
  })
  if not ok then
    _close()
    error("无法打开提问弹窗: " .. tostring(wid))
  end
  state.win_id = wid
  geometry.track(state.win_id, geom_opts)
  vim.wo[state.win_id].wrap = true
  -- 提问内容禁止折叠：minimal 浮窗会继承全局 foldenable/foldmethod
  -- （如用户的 foldmethod=indent + foldenable），导致问题/选项被自动收起而看不到。
  vim.wo[state.win_id].foldenable = false
  vim.wo[state.win_id].foldmethod = "manual"
  vim.wo[state.win_id].foldcolumn = "0"
  pcall(vim.cmd, "stopinsert")
  vim.bo[state.buf].modifiable = false
  _set_keymaps()
end

--- 展示提问弹窗。焦点不在 NeoAI 界面（用户切到其他窗口）时不立即弹出，暂存并进入等待，
--- 待用户切回 NeoAI 界面时再弹（经 `focus.gate` 统一实现）。提问工具侧仍照常等待回答。
--- @param config table { question, options, on_answer, on_cancel }
function M.show(config)
  require("NeoAI.ui.focus").gate("ask_user", function() _present(config) end)
end

--- 隐藏提问弹窗
function M.hide()
  require("NeoAI.ui.focus").cancel_gate("ask_user")
  _close()
end

--- 注册到 ask_user 模块（经 kernel.ui_hooks，ui 不直接依赖 tools）
function M.init()
  ui_hooks.set("ask_user", {
    show = M.show,
    hide = M.hide,
  })
end

--- 重置（测试用）：关闭弹窗并解除注册
function M.reset()
  _close()
  require("NeoAI.ui.focus").cancel_gate("ask_user")
  state._question = nil
  state._options = nil
  ui_hooks.clear("ask_user")
end

--- 是否有暂存待展示的提问（测试用）
--- @return boolean
function M.has_deferred()
  return require("NeoAI.ui.focus").has_gate("ask_user")
end

--- 当前弹窗 buffer（测试用）；未弹出时返回 nil
--- @return number|nil
function M.get_buf()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then return state.buf end
  return nil
end

return M
