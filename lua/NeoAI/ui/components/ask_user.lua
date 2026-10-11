--- 向用户提问弹窗（多 Tab / 多选 / 汇总确认）
--- @module 'NeoAI.ui.components.ask_user'
--- 注册到 NeoAI.tools.builtin.ask_user。同一轮的多次提问聚合为一个多 Tab 弹窗：
---   - 顶部 Tab 栏：`[n]✓/○` 标记该题是否已答，当前题高亮；`<Tab>`/`<S-Tab>`（或 `]`/`[`）切题
---   - 题目正文 + 选项：单选显示 `[n]`，多选显示 `[x]/[ ]` 复选框（`multi_select=true`）
---   - `1-9` 单选选择 / 多选切换勾选；`i` / `<CR>` 进入自由输入（vim.ui.input）覆盖本题答案
---   - 全部作答后进入汇总页：列出 `Q → A`，`<CR>`/`y` 提交、`e` 返回编辑、`Esc` 取消
---   - 汇总页提交时若仍有未作答项，提示并跳回首个未作答 Tab
---   - `require_confirm=false` 时跳过汇总页，全部作答后直接提交
--- 焦点门控（focus.gate）：焦点不在 NeoAI 界面时暂存，切回再弹。

local ui_hooks = require("NeoAI.kernel.ui_hooks")
local geometry = require("NeoAI.ui.geometry")
local M = {}

-- ========== 私有状态 ==========

local state = {
  win_id = nil,
  buf = nil,
  batch_id = nil, -- 同一批次重渲染（迟到调用追加 tab）时据此保留已作答状态
  questions = {}, -- { question, options, multi_select }
  picks = {}, -- picks[i] = { [option_index]=true }（单选至多一个）
  free = {}, -- free[i] = 自由输入覆盖文本
  active = 1, -- 当前 tab（1-based）
  mode = "tab", -- "tab" | "summary"
  require_confirm = true,
  on_submit = nil, -- function(answers) answers[i] = 第 i 题最终答案字符串
  on_cancel = nil, -- function(reason)
}

-- 高亮命名空间：选项简介 / 选项描述 / Tab / 未作答各用一组高亮
local HL_NS = vim.api.nvim_create_namespace("neoai_ask_user_hi")

--- 定义高亮组（default=true，不覆盖用户自定义；兼容无外网/无主题环境）
local function _setup_hl()
  vim.api.nvim_set_hl(0, "NeoAIAskUserOptionLabel", { default = true, bold = true })
  vim.api.nvim_set_hl(0, "NeoAIAskUserOptionDesc", { default = true, fg = "#8a8a8a" })
  vim.api.nvim_set_hl(0, "NeoAIAskUserTabActive", { default = true, bold = true, underline = true })
  vim.api.nvim_set_hl(0, "NeoAIAskUserTabAnswered", { default = true, fg = "#9ece6a" })
  vim.api.nvim_set_hl(0, "NeoAIAskUserUnanswered", { default = true, fg = "#e0af68" })
  vim.api.nvim_set_hl(0, "NeoAIAskUserHint", { default = true, fg = "#8a8a8a" })
end

--- 归一化选项：兼容纯字符串或 { label, description } 对象
--- @param opts table 数组，元素为 string 或 { label, description }
--- @return table 数组 { label, description }
local function _normalize_options(opts)
  local out = {}
  for _, o in ipairs(opts or {}) do
    if type(o) == "string" then
      out[#out + 1] = { label = o, description = "" }
    elseif type(o) == "table" then
      local label = type(o.label) == "string" and o.label or (type(o.name) == "string" and o.name or "")
      local desc = type(o.description) == "string" and o.description or (type(o.desc) == "string" and o.desc or "")
      if label ~= "" then out[#out + 1] = { label = label, description = desc } end
    end
  end
  return out
end

-- ========== 私有函数（状态/渲染） ==========

local _render

--- 关闭窗口但保留状态（同批次重渲染用）
local function _close_win()
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    pcall(vim.api.nvim_win_close, state.win_id, true)
  end
  geometry.untrack(state.win_id)
  state.win_id = nil
  state.buf = nil
end

--- 关闭窗口并复位全部状态
local function _close()
  _close_win()
  state.batch_id = nil
  state.questions = {}
  state.picks = {}
  state.free = {}
  state.active = 1
  state.mode = "tab"
  state.require_confirm = true
  state.on_submit = nil
  state.on_cancel = nil
end

--- 第 i 题最终答案（nil = 未作答）；自由输入优先于选项勾选
--- @param i number
--- @return string|nil
local function _answer_of(i)
  local free = state.free[i]
  if type(free) == "string" and free ~= "" then return free end
  local picks = state.picks[i]
  local q = state.questions[i]
  if not picks or not q or not q.options then return nil end
  local labels = {}
  for oi = 1, #q.options do
    if picks[oi] then labels[#labels + 1] = q.options[oi].label end
  end
  if #labels == 0 then return nil end
  if q.multi_select then return table.concat(labels, ", ") end
  return labels[1]
end

--- 是否全部题目已作答
--- @return boolean
local function _all_answered()
  if #state.questions == 0 then return false end
  for i = 1, #state.questions do
    if _answer_of(i) == nil then return false end
  end
  return true
end

--- 首个未作答题号（无则返回 nil）
--- @return number|nil
local function _first_unanswered()
  for i = 1, #state.questions do
    if _answer_of(i) == nil then return i end
  end
  return nil
end

--- 提交并关闭（回调先捕获，防关闭时被清空）
local function _do_submit()
  local answers = {}
  for i = 1, #state.questions do answers[i] = _answer_of(i) end
  local cb = state.on_submit
  _close()
  if cb then cb(answers) end
end

--- 取消整批并关闭
--- @param reason string|nil
local function _cancel(reason)
  local cb = state.on_cancel
  _close()
  if cb then cb(reason or "用户取消") end
end

--- 作答后推进：全部作答则进汇总页（或 require_confirm=false 直接提交），否则重渲染
local function _after_answer()
  if _all_answered() then
    if state.require_confirm == false then
      _do_submit()
    else
      state.mode = "summary"
      _render()
    end
  else
    _render()
  end
end

--- 选择/切换选项
--- @param oi number 选项序号（1-based）
local function _pick(oi)
  local q = state.questions[state.active]
  if not q or not q.options or not q.options[oi] then return end
  local picks = state.picks[state.active]
  if not picks then picks = {}; state.picks[state.active] = picks end
  if q.multi_select then
    picks[oi] = (not picks[oi]) or nil
  else
    state.picks[state.active] = { [oi] = true }
  end
  state.free[state.active] = nil -- 勾选覆盖自由输入
  _after_answer()
end

--- 自由输入覆盖本题答案
local function _free_input()
  local idx = state.active
  local q = state.questions[idx]
  if not q then return end
  vim.ui.input({ prompt = (q.question or "") .. " " }, function(ans)
    if ans == nil then return end
    state.free[idx] = (ans ~= "" and ans or nil)
    _after_answer()
  end)
end

--- 切换 Tab（delta 为 +1/-1，循环）
--- @param delta number
local function _switch_tab(delta)
  local n = #state.questions
  if n == 0 then return end
  state.mode = "tab"
  state.active = ((state.active - 1 + delta) % n) + 1
  _render()
end

--- 汇总页提交：有未作答则提示并跳回首个未作答 Tab
local function _try_submit()
  if not _all_answered() then
    local idx = _first_unanswered()
    if idx then state.active = idx end
    state.mode = "tab"
    _render()
    pcall(vim.notify, "[NeoAI] 仍有题目未作答，请先完成", vim.log.levels.WARN)
    return
  end
  _do_submit()
end

--- 汇总页返回编辑：跳到首个未作答 Tab（全答则留在原 tab）
local function _back_to_edit()
  state.mode = "tab"
  local idx = _first_unanswered()
  if idx then state.active = idx end
  _render()
end

--- 设置快捷键（普通模式 + 插入模式，理由同 tool_approval）
local function _set_keymaps()
  if not state.buf then return end
  local function bind(mode, key, fn)
    if not key or key == "" then return end
    vim.keymap.set(mode, key, fn, { buffer = state.buf })
  end

  if state.mode == "summary" then
    for _, mode in ipairs({ "n", "i" }) do
      bind(mode, "<CR>", _try_submit)
      bind(mode, "y", _try_submit)
      bind(mode, "e", _back_to_edit)
    end
    -- 取消：仅 NORMAL 模式 <Esc>（INSERT 保留退出插入模式原义）
    bind("n", "<Esc>", function() _cancel("用户取消") end)
    return
  end

  for _, mode in ipairs({ "n", "i" }) do
    for i = 1, 9 do
      bind(mode, tostring(i), function() _pick(i) end)
    end
    bind(mode, "<Tab>", function() _switch_tab(1) end)
    bind(mode, "<S-Tab>", function() _switch_tab(-1) end)
    bind(mode, "]", function() _switch_tab(1) end)
    bind(mode, "[", function() _switch_tab(-1) end)
    bind(mode, "i", _free_input)
    bind(mode, "<CR>", _free_input)
  end
  -- 取消：仅 NORMAL 模式 <Esc>（INSERT 保留退出插入模式原义）
  bind("n", "<Esc>", function() _cancel("用户取消") end)
end

--- 构建 buffer 内容（tab 页 / 汇总页）
--- @return table lines
--- @return table highlights { { line, col, end_col, group } }
local function _build_lines()
  local lines = {}
  local hl = {}
  local function push(line)
    lines[#lines + 1] = line
    return #lines - 1 -- 0-based 行号
  end

  if state.mode == "summary" then
    push("【汇总确认】")
    push("")
    for i, q in ipairs(state.questions) do
      push(string.format("  Q%d: %s", i, q.question or ""))
      local ans = _answer_of(i)
      if ans then
        push("      → " .. ans)
      else
        local prefix = "      → "
        local l = push(prefix .. "未作答")
        hl[#hl + 1] = { line = l, col = #prefix, end_col = #prefix + #"未作答", group = "NeoAIAskUserUnanswered" }
      end
    end
    push("")
    push("快捷键: [回车/y] 提交    [e] 返回编辑    [Esc] 取消")
    return lines, hl
  end

  -- Tab 栏
  local bar = ""
  local spans = {}
  for i = 1, #state.questions do
    local mark = _answer_of(i) ~= nil and "✓" or "○"
    local seg = string.format("[%d]%s", i, mark)
    if #bar > 0 then bar = bar .. "  " end
    local col0 = #bar
    bar = bar .. seg
    spans[i] = { col = col0, len = #seg }
  end
  local bar_line = push(bar)
  for i, sp in ipairs(spans) do
    local group
    if i == state.active then
      group = "NeoAIAskUserTabActive"
    elseif _answer_of(i) ~= nil then
      group = "NeoAIAskUserTabAnswered"
    end
    if group then
      hl[#hl + 1] = { line = bar_line, col = sp.col, end_col = sp.col + sp.len, group = group }
    end
  end

  push("")
  local q = state.questions[state.active]
  if q then
    for _, ln in ipairs(vim.split(q.question or "", "\n", { plain = true })) do
      push(ln)
    end
    local options = q.options or {}
    if #options > 0 then
      push("")
      push("选项:")
      for oi, opt in ipairs(options) do
        local box
        if q.multi_select then
          box = (state.picks[state.active] and state.picks[state.active][oi]) and "[x]" or "[ ]"
        else
          box = string.format("[%d]", oi)
        end
        local label_col = #("  " .. box .. " ")
        local l = push(string.format("  %s %s", box, opt.label))
        hl[#hl + 1] = { line = l, col = label_col, end_col = label_col + #opt.label, group = "NeoAIAskUserOptionLabel" }
        if opt.description and opt.description ~= "" then
          local dl = push("        " .. opt.description)
          hl[#hl + 1] = { line = dl, col = 8, end_col = 8 + #opt.description, group = "NeoAIAskUserOptionDesc" }
        end
      end
    end
  end

  push("")
  local hint
  if q and q.multi_select then
    hint = "快捷键: [1-9] 勾选    [Tab/S-Tab] 切题    [i/回车] 自由输入    [Esc] 取消"
  else
    hint = "快捷键: [1-9] 选择    [Tab/S-Tab] 切题    [i/回车] 自由输入    [Esc] 取消"
  end
  local hl_line = push(hint)
  hl[#hl + 1] = { line = hl_line, col = 0, end_col = #hint, group = "NeoAIAskUserHint" }
  return lines, hl
end

--- 确保 buffer/窗口已创建（首次展示或窗口被关闭后重建）
local function _ensure_window()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) and state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    return
  end
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].filetype = "neoai_ask_user"
  local geom_opts = { w_ratio = 0.66, h_ratio = 0.72, fit_h = 12 }
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
    state.buf = nil
    error("无法打开提问弹窗: " .. tostring(wid))
  end
  state.win_id = wid
  geometry.track(state.win_id, geom_opts)
  vim.wo[state.win_id].wrap = true
  -- 提问内容禁止折叠：minimal 浮窗会继承全局 foldenable/foldmethod
  vim.wo[state.win_id].foldenable = false
  vim.wo[state.win_id].foldmethod = "manual"
  vim.wo[state.win_id].foldcolumn = "0"
end

--- 重渲染 buffer（内容 + 高亮 + 快捷键 + 动态高度）
_render = function()
  _ensure_window()
  if state.active < 1 then state.active = 1 end
  if state.active > #state.questions then state.active = math.max(1, #state.questions) end
  _setup_hl()
  local lines, hl = _build_lines()
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(state.buf, HL_NS, 0, -1)
  for _, h in ipairs(hl) do
    pcall(vim.api.nvim_buf_add_highlight, state.buf, HL_NS, h.group, h.line, h.col, h.end_col)
  end
  pcall(vim.api.nvim_win_set_cursor, state.win_id, { 1, 0 })
  pcall(vim.cmd, "stopinsert")
  _set_keymaps()
  -- 动态高度：随内容（题目 + 选项 + 汇总行）自适应，避免截断
  local geom = geometry.compute({ w_ratio = 0.66, h_ratio = 0.72, fit_h = #lines + 4 })
  pcall(vim.api.nvim_win_set_config, state.win_id, {
    relative = "editor",
    width = geom.width,
    height = geom.height,
    col = geom.col,
    row = geom.row,
  })
end

--- 展示（合并同批次 config，保留已作答状态；首次或新批次时复位）
--- @param config table { batch_id, questions, active, mode, require_confirm, on_submit, on_cancel }
local function _present(config)
  config = config or {}
  -- 同批次重渲染（迟到调用追加 tab）：保留窗口/已作答/当前 tab/当前页，避免闪烁与状态丢失
  local same = state.batch_id ~= nil and state.batch_id == config.batch_id
    and state.win_id ~= nil and vim.api.nvim_win_is_valid(state.win_id)
  if not same then
    _close_win()
    state.batch_id = config.batch_id
    state.questions = {}
    state.picks = {}
    state.free = {}
    state.active = config.active or 1
    state.mode = config.mode or "tab"
  end
  state.require_confirm = config.require_confirm ~= false
  state.on_submit = config.on_submit
  state.on_cancel = config.on_cancel

  local questions = config.questions or {}
  for i, q in ipairs(questions) do
    state.questions[i] = {
      question = q.question,
      options = _normalize_options(q.options),
      multi_select = q.multi_select == true,
    }
    if not state.picks[i] then state.picks[i] = {} end
  end
  for i = #questions + 1, #state.questions do
    state.questions[i] = nil
    state.picks[i] = nil
    state.free[i] = nil
  end
  _render()
end

-- ========== 公开 API ==========

--- 展示提问弹窗。焦点不在 NeoAI 界面（用户切到其他窗口）时不立即弹出，暂存并进入等待，
--- 待用户切回 NeoAI 界面时再弹（经 `focus.gate` 统一实现）。提问工具侧仍照常等待回答。
--- @param config table 批次对象（见 tools/builtin/ask_user M.set_ui 注释）
function M.show(config)
  require("NeoAI.ui.focus").gate("ask_user", function() _present(config) end)
end

--- 隐藏提问弹窗（并复位状态）
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

--- 当前展示状态快照（测试用）
--- @return table { mode, active, questions, answers }
function M.get_state()
  local answers = {}
  for i = 1, #state.questions do answers[i] = _answer_of(i) end
  return {
    mode = state.mode,
    active = state.active,
    questions = state.questions,
    answers = answers,
  }
end

return M
