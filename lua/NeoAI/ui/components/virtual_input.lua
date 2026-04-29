local M = {}

-- 模块状态
local state = {
  initialized = false,
  config = nil,
  active = false,
  mode = nil, -- "inline" 或 "float"
  buf = nil, -- 聊天 buffer（内联模式）
  float_buf = nil, -- 浮动输入框 buffer
  float_win = nil, -- 浮动输入框窗口
  parent_win = nil, -- 父窗口句柄
  placeholder = "输入消息...",
  on_submit = nil,
  on_cancel = nil,
  on_change = nil,
  ns_id = nil, -- extmark 命名空间
  placeholder_extmark_id = nil, -- 占位符 extmark id
  input_start_line = 0, -- 输入区域起始行号
  input_line_count = 3, -- 输入区域行数
  _updating = false, -- 防抖标志
}

--- 初始化
function M.initialize(config)
  if state.initialized then
    return
  end
  state.config = config or {}
  state.ns_id = vim.api.nvim_create_namespace("NeoAI_InlineInput")
  state.initialized = true
end

--- 激活内联输入模式
--- @param buf number 聊天 buffer
--- @param opts table 选项
function M.activate(buf, opts)
  if not state.initialized then
    return false
  end
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end

  -- 如果已激活，先清理
  if state.active then
    M.deactivate()
  end

  state.buf = buf
  state.placeholder = opts.placeholder or "输入消息..."
  state.on_submit = opts.on_submit
  state.on_cancel = opts.on_cancel
  state.on_change = opts.on_change
  state.input_line_count = opts.input_line_count or 3
  state.active = true

  -- 设置 buffer 为可修改
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_set_option_value("readonly", false, { buf = buf })

  -- 确保末尾有足够的空行作为输入区域
  M._ensure_input_lines()

  -- 设置占位符 extmark
  M._update_placeholder()

  -- 设置按键映射
  M._setup_keymaps()

  -- 监听内容变化
  M._setup_listeners()

  return true
end

--- 打开浮动虚拟输入框
--- @param parent_win number 父窗口句柄
--- @param opts table 选项
--- @return boolean 是否成功
function M.open(parent_win, opts)
  if not state.initialized then
    return false
  end
  if not parent_win or not vim.api.nvim_win_is_valid(parent_win) then
    return false
  end

  -- 如果已激活，先关闭
  if state.active then
    M.close()
  end

  opts = opts or {}
  state.placeholder = opts.placeholder or "输入消息..."
  state.on_submit = opts.on_submit
  state.on_cancel = opts.on_cancel
  state.on_change = opts.on_change
  state.parent_win = parent_win
  state.mode = "float"
  state.input_line_count = math.max(3, 1)

  -- 创建独立的浮动输入框 buffer
  state.float_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("filetype", "NeoAIInput", { buf = state.float_buf })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = state.float_buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = state.float_buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = state.float_buf })
  vim.api.nvim_set_option_value("modified", false, { buf = state.float_buf })

  -- 阻止 LSP 附加到浮动输入框
  local wm = require("NeoAI.ui.window.window_manager")
  wm.block_lsp_for_buffer(state.float_buf, "浮动输入框")

  -- 设置提示符
  vim.api.nvim_buf_set_lines(state.float_buf, 0, -1, false, { "> " })

  -- 获取父窗口位置信息
  local parent_config = vim.api.nvim_win_get_config(parent_win)
  local parent_width = parent_config.width or 80
  local parent_col = parent_config.col or 0
  local parent_row = parent_config.row or 0
  local parent_height = parent_config.height or 20
  local screen_height = vim.o.lines

  -- 输入框高度：固定 5 行
  local input_height = 5
  local input_width = parent_width

  -- 计算 chat 窗口底部到屏幕底部的剩余空间
  -- nvim_win_get_config 返回的 row 是窗口左上角（含 border），0-based
  -- height 是内容区域高度（不含 border）
  -- chat 窗口底部（含 border）= parent_row + parent_height + 1
  -- screen_height (vim.o.lines) 是 1-based，转 0-based 需减 1
  -- 剩余空间 = 屏幕最后一行(0-based) - chat 窗口底部(含 border)
  -- 输入框放在 chat 窗口正下方（紧贴 border），需要 input_height + 2 行（含自身 border）
  local chat_bottom = parent_row + parent_height + 1
  local space_below = (screen_height - 1) - chat_bottom

  -- 输入框总高度（含 border）= input_height + 2
  local input_total_height = input_height + 2

  -- 如果底部空间不足，抬升 chat 窗口
  local adjusted_parent_row = parent_row
  if space_below < input_total_height then
    local lift = input_total_height - space_below
    adjusted_parent_row = math.max(0, parent_row - lift)

    -- 保存原始配置，关闭时恢复
    state._saved_parent_config = {
      row = parent_row,
    }

    -- 抬升 chat 窗口
    parent_config.row = adjusted_parent_row
    pcall(vim.api.nvim_win_set_config, parent_win, parent_config)
  end

  -- 输入框位置：紧贴 chat 窗口底部 border 下方
  -- row 是输入框左上角（含 border），放在 chat 窗口 border 正下方
  local row = adjusted_parent_row + parent_height + 2
  local col = parent_col

  -- 确保输入框整体不超出屏幕底部
  -- 输入框底部（含 border）= row + input_height + 1
  local input_bottom = row + input_height + 1
  if input_bottom > screen_height - 1 then
    row = math.max(0, (screen_height - 1) - (input_height + 1))
  end

  -- 创建浮动窗口
  state.float_win = vim.api.nvim_open_win(state.float_buf, true, {
    relative = "editor",
    width = input_width,
    height = input_height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " 输入 ",
    title_pos = "center",
    noautocmd = true,
  })

  -- 注册到 window_manager，以便切换 buffer 时自动隐藏/显示
  local ok, wm = pcall(require, "NeoAI.ui.window.window_manager")
  if ok and wm and wm.register_float_window then
    local parent_buf = vim.api.nvim_win_get_buf(parent_win)
    wm.register_float_window(parent_buf, state.float_win, state.float_buf)
  end

  -- 设置自动命令：当在浮动输入框执行 Ex 命令时，自动将焦点切回 chat 主窗口
  -- 避免 :q / :e / :b 等命令在浮动输入框的 buffer 上执行
  local float_augroup = "NeoAIFloatInputCmd_" .. tostring(state.float_buf)
  pcall(vim.api.nvim_del_augroup_by_name, float_augroup)
  local group = vim.api.nvim_create_augroup(float_augroup, { clear = true })
  vim.api.nvim_create_autocmd("CmdlineEnter", {
    group = group,
    buffer = state.float_buf,
    callback = function()
      -- 将焦点切回 chat 主窗口，使 Ex 命令在 chat 窗口的 buffer 上执行
      if state.parent_win and vim.api.nvim_win_is_valid(state.parent_win) then
        pcall(vim.api.nvim_set_current_win, state.parent_win)
      end
    end,
    desc = "浮动输入框执行命令时切回 chat 主窗口",
  })

  -- 将浮动窗口光标定位到第一行（> 提示符后面）
  pcall(vim.api.nvim_win_set_cursor, state.float_win, { 1, 2 })

  -- 设置窗口选项
  vim.api.nvim_set_option_value("wrap", true, { win = state.float_win })
  vim.api.nvim_set_option_value("cursorline", true, { win = state.float_win })
  vim.api.nvim_set_option_value("showmode", false, { scope = "local" })

  -- 设置按键映射
  M._setup_float_keymaps()

  -- 延迟聚焦到输入框，确保在 _do_render_chat 的异步回调（set_window_content、_focus_window 等）执行完后才设置焦点
  -- 避免被 _do_render_chat 中的操作抢走焦点
  vim.defer_fn(function()
    if state.float_win and vim.api.nvim_win_is_valid(state.float_win) then
      pcall(function()
        vim.api.nvim_set_current_win(state.float_win)
        vim.api.nvim_win_set_cursor(state.float_win, { 1, 2 })
        vim.cmd("startinsert!")
      end)
    end
  end, 10)

  state.active = true
  return true
end

--- 关闭浮动虚拟输入框
function M.close(force)
  if not state.active then
    return
  end

  -- 清理 CmdlineEnter 自动命令
  if state.float_buf then
    local float_augroup = "NeoAIFloatInputCmd_" .. tostring(state.float_buf)
    pcall(vim.api.nvim_del_augroup_by_name, float_augroup)
  end

  -- 从 window_manager 注销（无需额外操作，后续会直接清理）
  pcall(require, "NeoAI.ui.window.window_manager")

  -- 关闭浮动窗口
  if state.float_win and vim.api.nvim_win_is_valid(state.float_win) then
    pcall(vim.api.nvim_win_close, state.float_win, true)
  end
  state.float_win = nil

  -- 清理独立 buffer
  if state.float_buf and vim.api.nvim_buf_is_valid(state.float_buf) then
    pcall(vim.api.nvim_buf_delete, state.float_buf, { force = true })
  end
  state.float_buf = nil

  -- 恢复父窗口位置（如果之前抬升过）
  if state._saved_parent_config and state.parent_win and vim.api.nvim_win_is_valid(state.parent_win) then
    local parent_config = vim.api.nvim_win_get_config(state.parent_win)
    parent_config.row = state._saved_parent_config.row
    pcall(vim.api.nvim_win_set_config, state.parent_win, parent_config)
    state._saved_parent_config = nil
  end

  -- 先将焦点移回父窗口（chat 窗口），然后再退出插入模式
  -- 顺序很重要：先切窗口确保 stopinsert 在正确的上下文中执行
  if state.parent_win and vim.api.nvim_win_is_valid(state.parent_win) then
    pcall(vim.api.nvim_set_current_win, state.parent_win)
  end

  -- 切换到 NORMAL 模式（在父窗口上下文中执行，确保正确退出）
  pcall(function()
    vim.cmd.stopinsert()
  end)

  state.active = false
  state.parent_win = nil
  state.mode = nil
end

--- 停用输入模式（兼容旧接口）
function M.deactivate()
  if state.mode == "float" then
    M.close()
    return
  end
  if not state.active then
    return
  end

  -- 清理 extmark
  if state.ns_id and state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_clear_namespace(state.buf, state.ns_id, 0, -1)
  end

  -- 清理按键映射
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_del_keymap, state.buf, "n", "<CR>")
    pcall(vim.api.nvim_buf_del_keymap, state.buf, "i", "<CR>")
    pcall(vim.api.nvim_buf_del_keymap, state.buf, "i", "<Esc>")
    pcall(vim.api.nvim_buf_del_keymap, state.buf, "n", "<Esc>")
    pcall(vim.api.nvim_buf_del_keymap, state.buf, "i", "<C-c>")
    pcall(vim.api.nvim_buf_del_keymap, state.buf, "i", "<C-u>")
  end

  state.active = false
  state.buf = nil
  state.placeholder_extmark_id = nil
  state.input_start_line = 0
end

--- 确保末尾有足够的空行
function M._ensure_input_lines()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end

  local line_count = vim.api.nvim_buf_line_count(state.buf)
  local needed = state.input_line_count

  -- 检查末尾是否有足够的空行
  local empty_lines = 0
  for i = math.max(1, line_count - needed + 1), line_count do
    local lines = vim.api.nvim_buf_get_lines(state.buf, i - 1, i, false)
    if lines[1] == "" then
      empty_lines = empty_lines + 1
    else
      empty_lines = 0
    end
  end

  -- 如果末尾空行不足，追加空行
  if empty_lines < needed then
    local add_count = needed - empty_lines
    local new_lines = {}
    for _ = 1, add_count do
      table.insert(new_lines, "")
    end
    vim.api.nvim_buf_set_lines(state.buf, line_count, line_count, false, new_lines)
  end

  -- 记录输入区域起始行
  local new_line_count = vim.api.nvim_buf_line_count(state.buf)
  state.input_start_line = new_line_count - state.input_line_count + 1
end

--- 更新占位符 extmark
function M._update_placeholder()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end

  -- 清除旧的占位符
  if state.placeholder_extmark_id then
    vim.api.nvim_buf_del_extmark(state.buf, state.ns_id, state.placeholder_extmark_id)
    state.placeholder_extmark_id = nil
  end

  -- 检查输入区域第一行是否为空
  local line_count = vim.api.nvim_buf_line_count(state.buf)
  local input_start = math.max(1, line_count - state.input_line_count + 1)
  local lines = vim.api.nvim_buf_get_lines(state.buf, input_start - 1, input_start, false)
  local first_input_line = lines[1] or ""

  if first_input_line == "" then
    -- 显示占位符
    state.placeholder_extmark_id = vim.api.nvim_buf_set_extmark(state.buf, state.ns_id, input_start - 1, 0, {
      virt_text = { { state.placeholder, "Comment" } },
      virt_text_pos = "overlay",
      hl_mode = "combine",
      priority = 100,
    })
  end
end

--- 获取输入内容（输入区域所有行合并）
function M.get_content()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return ""
  end

  local line_count = vim.api.nvim_buf_line_count(state.buf)
  local input_start = math.max(1, line_count - state.input_line_count + 1)
  local lines = vim.api.nvim_buf_get_lines(state.buf, input_start - 1, line_count, false)

  -- 合并所有非空行，用换行符连接
  local parts = {}
  for _, line in ipairs(lines) do
    table.insert(parts, line)
  end

  -- 去除末尾空行
  while #parts > 0 and parts[#parts] == "" do
    table.insert(parts, "")
    break
  end

  local content = table.concat(parts, "\n")
  return vim.trim(content)
end

--- 清空输入区域
function M.clear()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end

  local line_count = vim.api.nvim_buf_line_count(state.buf)
  local input_start = math.max(1, line_count - state.input_line_count + 1)

  -- 将输入区域行置空
  local empty_lines = {}
  for _ = 1, state.input_line_count do
    table.insert(empty_lines, "")
  end
  vim.api.nvim_buf_set_lines(state.buf, input_start - 1, line_count, false, empty_lines)

  -- 更新占位符
  M._update_placeholder()
end

--- 提交输入
function M.submit()
  if not state.active then
    return
  end

  local content = M.get_content()
  if content == "" then
    return
  end

  -- 调用提交回调
  if state.on_submit and type(state.on_submit) == "function" then
    state.on_submit(content)
  end

  -- 清空输入区域
  M.clear()
end

--- 取消输入
function M.cancel()
  if not state.active then
    return
  end
  if state.on_cancel and type(state.on_cancel) == "function" then
    state.on_cancel()
  end
end

--- 设置浮动输入框按键映射
function M._setup_float_keymaps()
  if not state.float_buf or not vim.api.nvim_buf_is_valid(state.float_buf) then
    return
  end
  local buf = state.float_buf

  -- 发送消息（Enter）
  vim.keymap.set("i", "<CR>", function()
    M._submit_float()
  end, { buffer = buf, noremap = true, silent = true, desc = "发送消息" })

  vim.keymap.set("n", "<CR>", function()
    M._submit_float()
  end, { buffer = buf, noremap = true, silent = true, desc = "发送消息" })

  -- Esc：退出插入模式回到 normal 模式（不关闭输入框）
  vim.keymap.set("i", "<Esc>", function()
    vim.cmd("stopinsert")
  end, { buffer = buf, noremap = true, silent = true, desc = "退出插入模式" })

  -- i 在 normal 模式下进入插入模式
  vim.keymap.set("n", "i", function()
    if state.float_win and vim.api.nvim_win_is_valid(state.float_win) then
      pcall(vim.api.nvim_set_current_win, state.float_win)
      -- 将光标定位到 > 后面
      pcall(vim.api.nvim_win_set_cursor, state.float_win, { 1, 2 })
      vim.cmd("startinsert!")
    end
  end, { buffer = buf, noremap = true, silent = true, desc = "进入插入模式" })

  -- 清空输入
  vim.keymap.set("i", "<C-u>", function()
    if not buf then
      return
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "> " })
    -- 重置光标位置到行首
    vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), { 1, 2 })
  end, { buffer = buf, noremap = true, silent = true, desc = "清空输入" })

  -- 在浮动输入框的 normal 模式下也绑定 chat 窗口的快捷键
  -- 这样用户在输入框里按 q/r/m 等键也能操作聊天窗口
  if buf then
    M._bind_chat_keymaps_to_float(buf)
  end
end

--- 将 chat 窗口的快捷键绑定到浮动输入框的 normal 模式
--- 这样光标在输入框里时，按 q/r/m 等键也能操作聊天窗口
--- @param buf number 浮动输入框 buffer
function M._bind_chat_keymaps_to_float(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  -- 获取 chat 窗口模块
  local ok, chat_window = pcall(require, "NeoAI.ui.window.chat_window")
  if not ok or not chat_window then
    return
  end

  -- 从 chat 窗口配置中获取快捷键
  local chat_config = (state.config or {}).keymaps and state.config.keymaps.chat or {}

  -- 定义需要绑定的快捷键及其对应的操作
  local bindings = {
    {
      key = (chat_config.quit or {}).key or "q",
      action = function()
        chat_window.close()
      end,
    },
    {
      key = (chat_config.refresh or {}).key or "r",
      action = function()
        chat_window.refresh_chat()
      end,
    },
    {
      key = (chat_config.switch_model or {}).key or "m",
      action = function()
        chat_window.show_model_selector()
      end,
    },
  }

  -- 绑定快捷键到浮动输入框的 normal 模式
  for _, binding in ipairs(bindings) do
    vim.keymap.set("n", binding.key, function()
      -- 先关闭浮动输入框，再执行 chat 窗口操作
      -- 注意：有些操作（如 close）内部会关闭输入框，所以先检查
      if binding.key ~= "q" then
        M.close()
      end
      binding.action()
    end, { buffer = buf, noremap = true, silent = true, desc = "Chat: " .. tostring(binding.key) })
  end
end

--- 提交浮动输入框内容
function M._submit_float()
  if not state.active or not state.float_buf or not vim.api.nvim_buf_is_valid(state.float_buf) then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(state.float_buf, 0, -1, false)
  local content = table.concat(lines, "\n")

  -- 去掉输入提示符前缀
  content = content:gsub("^> ", "")
  content = vim.trim(content)

  if content == "" then
    return
  end

  -- 调用提交回调
  if state.on_submit and type(state.on_submit) == "function" then
    state.on_submit(content)
  end

  -- 清空输入并恢复提示符
  if state.float_buf and vim.api.nvim_buf_is_valid(state.float_buf) then
    vim.api.nvim_buf_set_lines(state.float_buf, 0, -1, false, { "> " })
  end

  -- 重新聚焦输入框
  if state.float_win and vim.api.nvim_win_is_valid(state.float_win) then
    pcall(vim.api.nvim_set_current_win, state.float_win)
    -- 将光标定位到 >  后面
    pcall(vim.api.nvim_win_set_cursor, state.float_win, { 1, 2 })
    vim.cmd("startinsert!")
  end
end

--- 设置内联按键映射
function M._setup_keymaps()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  local buf = state.buf

  -- 获取键位配置
  local keymaps = M._get_keymaps()

  -- 发送消息（Enter 键）- 仅在输入区域行按下时发送
  vim.keymap.set("n", "<CR>", function()
    -- 检查光标是否在输入区域
    if M._cursor_in_input_area() then
      M.submit()
    else
      -- 不在输入区域，执行默认行为（如果有）
      vim.cmd("normal! j")
    end
  end, { buffer = buf, noremap = true, silent = true, desc = "发送消息" })

  vim.keymap.set("i", "<CR>", function()
    if M._cursor_in_input_area() then
      M.submit()
    else
      -- 不在输入区域，插入换行
      vim.api.nvim_put({ "" }, "c", false, true)
    end
  end, { buffer = buf, noremap = true, silent = true, desc = "发送消息" })

  -- 退出插入模式或取消生成
  local Events = require("NeoAI.core.events")
  vim.keymap.set("i", "<Esc>", function()
    vim.api.nvim_exec_autocmds("User", {
      pattern = Events.CANCEL_GENERATION,
      data = {},
    })
    vim.cmd("stopinsert")
    M._update_placeholder()
  end, { buffer = buf, noremap = true, silent = true, desc = "取消生成或退出插入模式" })

  -- 取消输入
  vim.keymap.set("i", "<C-c>", function()
    M.cancel()
  end, { buffer = buf, noremap = true, silent = true, desc = "取消输入" })

  -- 清空输入
  vim.keymap.set("i", "<C-u>", function()
    M.clear()
  end, { buffer = buf, noremap = true, silent = true, desc = "清空输入" })
end

--- 检查光标是否在输入区域
function M._cursor_in_input_area()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return false
  end

  local line_count = vim.api.nvim_buf_line_count(state.buf)
  local input_start = math.max(1, line_count - state.input_line_count + 1)

  local cursor = vim.api.nvim_win_get_cursor(0)
  local cursor_line = cursor[1]

  return cursor_line >= input_start
end

--- 设置内容变化监听器
function M._setup_listeners()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end

  vim.api.nvim_buf_attach(state.buf, false, {
    on_lines = function(_, _, first_line, last_line, _, _, _)
      if state._updating then
        return
      end
      state._updating = true

      vim.schedule(function()
        -- 更新占位符
        M._update_placeholder()

        -- 触发变化回调
        if state.on_change and type(state.on_change) == "function" then
          state.on_change(M.get_content())
        end

        state._updating = false
      end)
    end,
  })
end

--- 获取键位配置
function M._get_keymaps()
  local default_keymaps = {
    normal_mode = "<CR>",
    submit = "<C-s>",
    cancel = "<Esc>",
    clear = "<C-u>",
  }

  if state.config and state.config.keymaps and state.config.keymaps.chat then
    local chat_keymaps = state.config.keymaps.chat
    local result = {}
    if chat_keymaps.send then
      if chat_keymaps.send.insert then
        result.normal_mode = chat_keymaps.send.insert.key
      end
      if chat_keymaps.send.normal then
        result.submit = chat_keymaps.send.normal.key
      end
    end
    if chat_keymaps.cancel then
      result.cancel = chat_keymaps.cancel.key
    end
    if chat_keymaps.clear then
      result.clear = chat_keymaps.clear.key
    end
    for internal_name, default_key in pairs(default_keymaps) do
      if not result[internal_name] then
        result[internal_name] = default_key
      end
    end
    return result
  end

  return default_keymaps
end

--- 聚焦浮动输入框并进入插入模式
--- 在 AI 生成完成后调用，确保光标回到输入框
function M.focus_and_insert()
  if not state.active or state.mode ~= "float" then
    return
  end
  if not state.float_win or not vim.api.nvim_win_is_valid(state.float_win) then
    return
  end

  -- 延迟聚焦，确保在异步回调（如 _do_render_chat 的 set_window_content）执行完后才设置焦点
  vim.defer_fn(function()
    if not state.float_win or not vim.api.nvim_win_is_valid(state.float_win) then
      return
    end
    pcall(vim.api.nvim_set_current_win, state.float_win)
    pcall(vim.api.nvim_win_set_cursor, state.float_win, { 1, 2 })
    vim.cmd("startinsert!")
  end, 10)
end

--- 是否激活
function M.is_active()
  return state.active
end

--- 获取输入区域起始行
function M.get_input_start_line()
  return state.input_start_line
end

--- 获取输入区域行数
function M.get_input_line_count()
  return state.input_line_count
end

--- 重新定位浮动输入框（窗口大小变化时调用）
function M.reposition()
  if not state.active or state.mode ~= "float" then
    return
  end
  if not state.float_win or not vim.api.nvim_win_is_valid(state.float_win) then
    return
  end
  if not state.parent_win or not vim.api.nvim_win_is_valid(state.parent_win) then
    return
  end

  local parent_config = vim.api.nvim_win_get_config(state.parent_win)
  local parent_width = parent_config.width or 80
  local parent_col = parent_config.col or 0
  local parent_row = parent_config.row or 0
  local parent_height = parent_config.height or 20
  local screen_height = vim.o.lines

  local input_height = 5
  local input_width = parent_width

  local chat_bottom = parent_row + parent_height + 1
  local space_below = (screen_height - 1) - chat_bottom
  local input_total_height = input_height + 2

  -- 如果底部空间不足，抬升 chat 窗口
  local adjusted_parent_row = parent_row
  if space_below < input_total_height then
    local lift = input_total_height - space_below
    adjusted_parent_row = math.max(0, parent_row - lift)
    parent_config.row = adjusted_parent_row
    pcall(vim.api.nvim_win_set_config, state.parent_win, parent_config)
  end

  -- 输入框位置：紧贴 chat 窗口底部 border 下方
  local row = adjusted_parent_row + parent_height + 2
  local col = parent_col

  -- 确保输入框整体不超出屏幕底部
  local input_bottom = row + input_height + 1
  if input_bottom > screen_height - 1 then
    row = math.max(0, (screen_height - 1) - (input_height + 1))
  end

  local config = vim.api.nvim_win_get_config(state.float_win)
  config.row = row
  config.col = col
  config.width = input_width
  config.height = input_height
  pcall(vim.api.nvim_win_set_config, state.float_win, config)
end

return M
