--- 输入框
--- @module NeoAI.ui.components.input_box
--- 聊天窗口底部的输入框。管理输入 buffer、提交、键位。

local config_store = require("NeoAI.kernel.config_store")

local M = {}

-- ========== 私有状态 ==========

local state = {
  buf = nil, -- 输入 buffer
  win_id = nil, -- 输入窗口
  on_submit = nil,
  on_cancel = nil,
  on_quit = nil,
  submitting = false,
  unsubs = {},
  chat_actions = nil, -- 主界面同步过来的 chat 上下文 actions
  cmp_aucmd_id = nil, -- 开启 nvim-cmp 的 InsertEnter 自动命令句柄（便于清理）
}

-- ========== 私有函数 ==========

--- 获取输入内容（去掉可能的 "> " 提示前缀）
local function _get_content()
  local lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
  local content = table.concat(lines, "\n")
  content = content:gsub("^>%s*", ""):gsub("%s+$", "")
  return content
end

--- 设置输入内容（prompt 前缀由 prompt_setprompt 负责显示）
local function _set_content(content)
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, { content })
end

--- 让 nvim-cmp 在输入框（prompt buffer）中生效，以支持路径补全。
--- nvim-cmp 默认的 enabled 判定会排除 buftype=prompt 的 buffer（见 cmp/config/default.lua），
--- 这里是输入框无法触发补全的根因；此处仅针对 neoai_input 这个 filetype 单独放开开关。
--- 只放开 enabled、不覆盖 sources：沿用用户全局配置里的 path/buffer 等补全源。
--- @return boolean 是否已成功启用
local function _enable_cmp_for_input()
  local ok, cmp = pcall(require, "cmp")
  if not ok then
    return false
  end
  cmp.setup.filetype("neoai_input", {
    enabled = function()
      return true
    end,
  })
  return true
end

--- 在输入 buffer 上注册补全启用逻辑。
--- 用户可能未安装 nvim-cmp（此时应无副作用），或 cmp 在其配置里于首次 InsertEnter 才被加载；
--- 故用 pcall 静默失败 + 延迟调度，确保在 cmp 真正加载并配置后仍对本 buffer 生效。
local function _setup_cmp_completion()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  -- 复用同一个 buffer 时避免重复注册自动命令
  if state.cmp_aucmd_id then
    pcall(vim.api.nvim_del_autocmd, state.cmp_aucmd_id)
    state.cmp_aucmd_id = nil
  end
  -- 立即尝试一次：若 cmp 尚未加载则静默失败
  _enable_cmp_for_input()
  -- 注册插入触发：延迟到当前事件循环末尾再执行，
  -- 等待用户「首次 InsertEnter 才 require('cmp')」的 once 自动命令先跑完。
  state.cmp_aucmd_id = vim.api.nvim_create_autocmd("InsertEnter", {
    buffer = state.buf,
    callback = function()
      vim.schedule(_enable_cmp_for_input)
    end,
  })
end

--- 绑定输入框键位
local function _set_keymaps()
  if not state.buf then
    return
  end
  local keymaps = config_store.get("keymaps.chat") or {}
  local send_conf = keymaps.send or {}
  local k_send_insert = send_conf.insert and send_conf.insert.key or "<C-s>"
  local k_send_normal = send_conf.normal and send_conf.normal.key or "<CR>"
  local k_cancel = keymaps.cancel and keymaps.cancel.key or "<Esc>"

  -- 同步主界面的 chat 上下文按键（普通模式）：
  -- quit/cancel/toggle_reasoning/switch_model/cycle_mode/tool_approval 与主界面一致，
  -- 让 m / <C-a> / m / r / q / <Esc> 等在输入框内同样可用。
  local keymap_mod = require("NeoAI.ui.keymap")
  if state.chat_actions then
    -- 排除 send/insert：这两个在输入框内有不同语义，下面单独绑定。
    local shared = {}
    for action, handler in pairs(state.chat_actions) do
      if action ~= "send" and action ~= "insert" then
        shared[action] = handler
      end
    end
    keymap_mod.register_context("chat", shared, state.buf)
  end

  -- 插入模式：发送键（<C-s>）；回车 = 换行（不发送）
  vim.keymap.set("i", k_send_insert, function()
    if state.submitting then
      return
    end
    local content = _get_content()
    if content == "" then
      return
    end
    M.submit(content)
  end, { buffer = state.buf, desc = "NeoAI 发送" })

  -- 插入模式：回车换行（多行输入），不发送。
  -- 直接把换行符插到光标处（buf 为 prompt 缓冲时 <CR> 默认触发 prompt 回调，这里覆盖为换行）。
  vim.keymap.set("i", "<CR>", function()
    local win = state.win_id
    if not win or not vim.api.nvim_win_is_valid(win) then
      win = 0
    end
    local cur = vim.api.nvim_win_get_cursor(win)
    local line = cur[1]
    local col = cur[2]
    -- 取当前行完整文本，在 col 处拆成两行
    local current_lines = vim.api.nvim_buf_get_lines(state.buf, line - 1, line, false)
    local text = current_lines[1] or ""
    -- nvim_win_get_cursor 的 col 已是该行的字节下标，直接按字节切分。
    -- 不要再调 byteidx：它把 col 当作「字符序号」，多字节文本下两者不一致，
    -- 当 col 超过字符数时 byteidx 返回 -1，text:sub(1,-1) 与 text:sub(0) 会把
    -- 整行内容复制一遍（回车后上一行内容被复制到新行）。
    col = math.max(0, math.min(col, #text))
    local head = text:sub(1, col)
    local tail = text:sub(col + 1)
    vim.api.nvim_buf_set_lines(state.buf, line - 1, line, false, { head, tail })
    if win ~= 0 then
      vim.api.nvim_win_set_cursor(win, { line + 1, 0 })
    end
  end, { buffer = state.buf, desc = "NeoAI 换行" })

  vim.keymap.set("i", k_cancel, function()
    if state.submitting and state.on_cancel then
      state.on_cancel()
    else
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k_cancel, true, false, true), "n", false)
    end
  end, { buffer = state.buf, desc = "NeoAI 取消/退出插入" })

  -- 普通模式：发送（回车）
  vim.keymap.set("n", k_send_normal, function()
    if state.submitting then
      return
    end
    local content = _get_content()
    if content == "" then
      vim.api.nvim_feedkeys("i", "n", false)
      return
    end
    M.submit(content)
  end, { buffer = state.buf, desc = "NeoAI 发送" })

  -- 普通模式：进入插入模式（i/a 末尾追加）
  vim.keymap.set("n", "i", function()
    vim.api.nvim_feedkeys("A", "n", false)
  end, { buffer = state.buf, desc = "NeoAI 输入" })
  vim.keymap.set("n", "a", function()
    vim.api.nvim_feedkeys("A", "n", false)
  end, { buffer = state.buf, desc = "NeoAI 输入" })
end

-- ========== 公开 API ==========

--- 创建输入框
--- @param opts table { on_submit?, on_cancel?, buf?, win_id?, chat_actions? }
--- @return table { buf, win_id }
function M.create(opts)
  opts = opts or {}
  state.on_submit = opts.on_submit
  state.on_cancel = opts.on_cancel
  state.on_quit = opts.on_quit
  state.chat_actions = opts.chat_actions

  state.buf = opts.buf or vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].buftype = "prompt"
  -- bufhidden=hide 而非 wipe：用户把输入窗口切到别的 buffer 时输入 buffer 必须存活，
  -- 否则 focus() 无法把输入 buffer 绑回窗口，feedkeys("A") 会把输入写进错误的 buffer。
  vim.bo[state.buf].bufhidden = "hide"
  vim.bo[state.buf].modifiable = true
  vim.bo[state.buf].filetype = "neoai_input"
  -- 用 nvim 原生 prompt 显示 "> " 前缀（避免默认 "% " 与手动前缀叠加）
  vim.fn.prompt_setprompt(state.buf, "> ")
  -- 不再用 prompt_setcallback 把「回车」绑定为发送：insert 模式回车=换行、normal 模式回车=发送，
  -- 由 _set_keymaps 里的 <CR> 映射负责，避免终端里 insert 回车误发送。
  _set_content("")
  state.win_id = opts.win_id
  _set_keymaps()
  -- 启用 nvim-cmp 路径补全（不改变 prompt buffer 行为，无 cmp 时无副作用）
  _setup_cmp_completion()
  return { buf = state.buf, win_id = state.win_id }
end

--- 绑定到已存在的窗口（用于 split 布局）
--- @param win_id number
function M.attach_window(win_id)
  state.win_id = win_id
  if win_id and vim.api.nvim_win_is_valid(win_id) then
    vim.api.nvim_win_set_buf(win_id, state.buf)
  end
end

--- 获取输入 buffer
--- @return number|nil
function M.get_buf()
  return state.buf
end

--- 获取输入窗口
--- @return number|nil
function M.get_win()
  return state.win_id
end

--- 获取提交回调（测试用；等价于「发送」动作，触发一次提交）
--- @return function|nil
function M.get_enter_callback()
  return function()
    if state.submitting then
      return false
    end
    local content = _get_content()
    if content == "" then
      return false
    end
    return M.submit(content)
  end
end

--- 聚焦输入框并进入插入模式
--- @return boolean 是否成功聚焦
function M.focus()
  if not state.win_id or not vim.api.nvim_win_is_valid(state.win_id) then
    return false
  end
  -- 焦点可能已跳到别的 buffer（用户切换/替换了输入窗口的 buffer）。
  -- 先把输入 buffer 绑回输入窗口，再进入插入模式；否则 feedkeys("A") 会在
  -- 当前显示的 buffer（可能是用户编辑的文件）末尾追加并进入插入模式，
  -- 之后的输入都会写进错误的 buffer。
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    local shown = vim.api.nvim_win_get_buf(state.win_id)
    if shown ~= state.buf then
      vim.api.nvim_win_set_buf(state.win_id, state.buf)
    end
  end
  vim.api.nvim_set_current_win(state.win_id)
  vim.api.nvim_feedkeys("A", "n", false)
  return true
end

--- 设置提交回调
--- @param fn function(content)
function M.set_on_submit(fn)
  state.on_submit = fn
end

--- 设置取消回调
--- @param fn function()
function M.set_on_cancel(fn)
  state.on_cancel = fn
end

--- 提交
--- @param content string|nil 可选，直接传入内容
--- @return boolean 是否已提交
function M.submit(content)
  if state.submitting then
    return false
  end
  content = content or _get_content()
  content = content:gsub("^>%s*", ""):gsub("%s+$", "")
  if content == "" then
    return false
  end
  state.submitting = true
  if state.on_submit then
    state.on_submit(content)
  end
  return true
end

--- 提交完成（发送完成后重置输入框）
function M.on_submitted()
  state.submitting = false
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    _set_content("")
  end
end

--- 取消输入
function M.cancel()
  if state.submitting and state.on_cancel then
    state.on_cancel()
  end
end

--- 清空输入
function M.clear()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    _set_content("")
  end
end

--- 重置（测试用）
function M.reset()
  for _, unsub in ipairs(state.unsubs) do
    unsub()
  end
  state.unsubs = {}
  if state.cmp_aucmd_id then
    pcall(vim.api.nvim_del_autocmd, state.cmp_aucmd_id)
    state.cmp_aucmd_id = nil
  end
  state.buf = nil
  state.win_id = nil
  state.on_submit = nil
  state.on_cancel = nil
  state.on_quit = nil
  state.chat_actions = nil
  state.submitting = false
end

return M
