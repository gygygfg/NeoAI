--- 输入框
--- @module 'NeoAI.ui.components.input_box'
--- 聊天窗口底部的输入框。管理输入 buffer、提交、键位。

local config_store = require("NeoAI.kernel.config_store")

-- 多实例：每个聊天实例持有**独立**输入框（各自 buffer/窗口/回调）。由 _make() 闭包工厂构造；
-- 模块表是「当前输入框」代理（缺省作用于最近创建/聚焦的实例），保持既有 API 与测试兼容。
local _current = nil

--- 构造一个独立输入框实例。
--- @return table
local function _make()
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
  prompt_ns = nil, -- 渲染 "> " 前缀的 extmark 命名空间
  prompt_extmark_id = nil, -- "> " 前缀 extmark id
}

-- ========== 私有函数 ==========

--- 渲染不可编辑的 "> " 提示前缀（用 virt_text inline 在行首显示，内容区保持"纯输入"）。
--- 之前用 buftype=prompt 实现，但因 prompt buffer 与 nvim-cmp 冲突（默认 enabled 排除
--- prompt buffer）导致插入补全失效，改回普通 buffer + virt_text 前缀。
local function _render_prompt_prefix()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end
  state.prompt_ns = state.prompt_ns or vim.api.nvim_create_namespace("neoai_input_prompt")
  if state.prompt_extmark_id then
    pcall(vim.api.nvim_buf_del_extmark, state.buf, state.prompt_ns, state.prompt_extmark_id)
    state.prompt_extmark_id = nil
  end
  state.prompt_extmark_id = vim.api.nvim_buf_set_extmark(state.buf, state.prompt_ns, 0, 0, {
    virt_text = { { "> ", "Comment" } },
    virt_text_pos = "inline",
  })
end

--- 获取输入内容（去掉可能残留的 "> " 提示前缀）
local function _get_content()
  local lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
  local content = table.concat(lines, "\n")
  content = content:gsub("^>%s*", ""):gsub("%s+$", "")
  return content
end

--- 设置输入内容（"> " 前缀由 virt_text 显示，不在内容区）
local function _set_content(content)
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, { content })
end

--- 让 nvim-cmp 在输入框中生效，以支持路径/关键字补全。
--- nvim-cmp 的 filetype 配置会覆盖全局 enabled（见 config.lua 的 merge 顺序：filetype 后于全局合并），
--- 此处仅针对 neoai_input 这个 filetype 单独放开开关；不覆盖 sources，沿用用户全局配置里的
--- path/buffer 等补全源。
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

--- 放开 nvim-cmp 并让其对 filetype 的配置在检测到 buffer 时生效。
--- nvim-cmp 的 config.filetypes 是按 filetype 读取的，为保险起见在成功配置后重新赋值一遍
--- 同样的 filetype（NeoVim 对同值赋值也会触发 FileType 事件），以确保任何依赖 FileType 事件
--- 的路径（如用户首启 InsertEnter 才加载 cmp 的懒加载场景）也都把 enabled 放开。
--- @return boolean 是否已成功放开
local function _apply_cmp_for_input()
  local enabled = _enable_cmp_for_input()
  if enabled and state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.bo[state.buf].filetype = "neoai_input"
  end
  return enabled
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
  _apply_cmp_for_input()
  -- 注册插入触发：延迟到当前事件循环末尾再执行，
  -- 等待用户「首次 InsertEnter 才 require('cmp')」的 once 自动命令先跑完。
  state.cmp_aucmd_id = vim.api.nvim_create_autocmd("InsertEnter", {
    buffer = state.buf,
    callback = function()
      vim.schedule(_apply_cmp_for_input)
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
  -- 直接把换行符插到光标处（<CR> 在插入模式=换行，不发送）。
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

  -- 普通模式：不覆盖 i / a，交回 Vim 原生语义（i 在光标前插入、a 在光标后插入），
  -- 使输入框与普通 buffer 完全一致。
  -- 历史问题：此前把 i / a 都重映射为 feedkeys("A")（行尾追加），导致输入框内
  -- 按 i / a 无法在光标处插入、一律跳到行尾，与普通 buffer 行为不一致。
  -- 需要「到行尾追加」请直接使用原生 A。
end

-- ========== 公开 API ==========

--- 创建输入框
--- @param opts table { on_submit?, on_cancel?, on_quit?, buf?, win_id?, chat_actions?, name? }
--- @return table { buf, win_id }
function M.create(opts)
  opts = opts or {}
  state.on_submit = opts.on_submit
  state.on_cancel = opts.on_cancel
  state.on_quit = opts.on_quit
  state.chat_actions = opts.chat_actions

  state.buf = opts.buf or vim.api.nvim_create_buf(false, true)
  -- 给输入 buffer 一个稳定名字，便于会话恢复（:mksession）后识别/清理残留，并在 :ls 中可辨识。
  -- 多实例下由调用方经 `opts.name` 传入**唯一**名（`NeoAI Input` / `NeoAI Input 2`…），
  -- 避免第二个实例改名重名失败、退化为无名 buffer。nofile + buftype 下改名不触发 E37/E162。
  -- pcall 容错：极端情况下重名（如上次会话遗留的孤儿 buffer）失败也不影响输入功能。
  pcall(vim.api.nvim_buf_set_name, state.buf, opts.name or "NeoAI Input")
  -- 注意：不设置 buftype=prompt。之前用 prompt buffer 是为了显示 "> " 前缀，但 prompt buffer
  -- 与 nvim-cmp 存在冲突（nvim-cmp 默认 enabled 排除 buftype=prompt，导致插入补全不生效；
  -- 且 prompt 回车回调与插件自定义 <CR> 语义冲突）。这里改成普通可编辑 buffer，用 virt_text
  -- extmark 渲染不可编辑的 "> " 前缀，内容区保持纯文本，nvim-cmp 可正常解析/补全。
  -- bufhidden=hide 而非 wipe：用户把输入窗口切到别的 buffer 时输入 buffer 必须存活，
  -- 否则 focus() 无法把输入 buffer 绑回窗口，feedkeys("A") 会把输入写进错误的 buffer。
  -- buftype=nofile：纯 UI 暂存 buffer；仅 nofile 能保证退出/切走时不触发 E37/E162
  -- "No write since last change"（acwrite/普通 buftype 会把已命名的暂存 buffer 当作未保存文件）。
  -- nofile 仍可编辑，不影响输入与 nvim-cmp。
  vim.bo[state.buf].bufhidden = "hide"
  vim.bo[state.buf].buftype = "nofile"
  vim.bo[state.buf].modifiable = true
  vim.bo[state.buf].filetype = "neoai_input"
  -- 不可编辑的 "> " 提示前缀（inline 把真实内容向右推，内容区不含 "> ")
  _render_prompt_prefix()
  _set_content("")
  state.win_id = opts.win_id
  _set_keymaps()
  -- 启用 nvim-cmp 插入补全（普通 buffer 不再被默认 enabled 排除，无 cmp 时无副作用）
  _setup_cmp_completion()
  return { buf = state.buf, win_id = state.win_id }
end

--- 绑定到已存在的窗口（用于 split 布局）
--- 用 'winfixbuf' 锁住输入窗口，作为**低层兜底**：输入 buffer 是无名 nofile 暂存 buffer，
--- 用户在此窗口执行 :e <file> / :bnext 等会**复用该窗口的 buffer**、把输入 buffer 变成一个
--- 命名文件 buffer（buftype 变空），之后输入就会落进用户文件、且 :wq 会误保存。
--- 开启 winfixbuf 后，此类切换会抛 E1513（Cannot switch buffer. 'winfixbuf' is enabled），
--- 保持输入 buffer 不变。Neovim 0.10+ 才有该选项，旧版本 pcall 静默跳过。
--- 注意：正常用户在输入框敲 :e / :bnext 时，**更高层**的 chat_view 已用 CmdlineLeave
--- （_on_input_cmdline_leave）拦截并改在新标签页打开，不会把 E1513 抛给用户；
--- winfixbuf 只兜住不触发 Cmdline 事件的路径（插件直接 nvim_win_set_buf / <Cmd> 等）。
--- 顺序：先临时关闭 winfixbuf（否则 set_buf 自身也会被 E1513 拦下）→ 绑定输入 buffer → 重新开启。
--- @param win_id number
function M.attach_window(win_id)
  state.win_id = win_id
  if win_id and vim.api.nvim_win_is_valid(win_id) then
    if vim.fn.exists("&winfixbuf") == 1 then
      pcall(function() vim.wo[win_id].winfixbuf = false end)
    end
    vim.api.nvim_win_set_buf(win_id, state.buf)
    if vim.fn.exists("&winfixbuf") == 1 then
      pcall(function() vim.wo[win_id].winfixbuf = true end)
    end
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
      -- winfixbuf 已开启时 set_buf 会抛 E1513（正常情况不会走到这里，因为 winfixbuf 阻止了
      -- 输入窗切到别的 buffer）；兜底临时关闭再绑定，确保焦点/输入落在正确的 buffer 上。
      local fix = vim.fn.exists("&winfixbuf") == 1
      if fix then pcall(function() vim.wo[state.win_id].winfixbuf = false end) end
      pcall(vim.api.nvim_win_set_buf, state.win_id, state.buf)
      if fix then pcall(function() vim.wo[state.win_id].winfixbuf = true end) end
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

--- 销毁输入框：删除输入 buffer 并清空状态（比 reset 更进一步）。
--- 用于聊天窗口关闭这类「真正结束」场景，避免 nofile 命名 buffer 泄漏到 :ls / 会话恢复。
--- 单纯收起（collapsed）不要调用本函数——收起必须保留 buffer 内容。
function M.destroy()
  local buf = state.buf
  if buf and vim.api.nvim_buf_is_valid(buf) then
    -- 若仍被某窗口显示：先解锁 winfixbuf 并切到临时 buffer，避免删除时连带关闭窗口。
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
        if vim.fn.exists("&winfixbuf") == 1 then
          pcall(function() vim.wo[win].winfixbuf = false end)
        end
        local tmp = vim.api.nvim_create_buf(false, true)
        pcall(vim.api.nvim_win_set_buf, win, tmp)
        pcall(vim.api.nvim_buf_delete, tmp, { force = true })
      end
    end
  end
  M.reset()
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
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
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) and state.prompt_ns and state.prompt_extmark_id then
    pcall(vim.api.nvim_buf_del_extmark, state.buf, state.prompt_ns, state.prompt_extmark_id)
  end
  state.prompt_extmark_id = nil
  state.buf = nil
  state.win_id = nil
  state.on_submit = nil
  state.on_cancel = nil
  state.on_quit = nil
  state.chat_actions = nil
  state.submitting = false
end

  return M
end

-- ========== 模块级：当前输入框代理（兼容既有调用 / 测试） ==========

local M = {}

--- 新建一个独立输入框实例，并设为「当前」。
--- @return table
function M.new()
  local inst = _make()
  _current = inst
  return inst
end

--- 直接指定「当前」输入框实例（由聚焦聊天实例调用）。
--- @param inst table
function M._set_current(inst)
  if inst then _current = inst end
end

--- 获取当前输入框实例（缺省惰性建一个默认实例，兼容不涉及多实例的既有调用/测试）。
--- @return table
local function _cur()
  if not _current then _current = _make() end
  return _current
end

--- 获取当前输入框实例。
--- @return table|nil
function M._instance()
  return _current
end

-- 透传方法：作用于「当前」输入框实例（无则惰性建默认实例，保持既有 API 与测试兼容）。
for _, name in ipairs({
  "create", "attach_window", "get_buf", "get_win", "get_enter_callback",
  "focus", "set_on_submit", "set_on_cancel", "submit", "on_submitted",
  "cancel", "clear", "destroy", "reset",
}) do
  M[name] = function(...)
    local cur = _cur()
    if cur and type(cur[name]) == "function" then return cur[name](...) end
  end
end

return M
