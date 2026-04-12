local M = {}
local backend = require("NeoAI.backend")
local config = require("NeoAI.config")

M.ui_modes = {
  FLOAT = "float",
  SPLIT = "split",
  TAB = "tab",
}

M.current_mode = M.ui_modes.FLOAT
M.windows = {}
M.buffers = {}
M.is_open = false
M.config = nil -- Will be initialized in M.setup()
M.original_tabline = nil
M.original_showtabline = nil
M.input_start_line = nil -- Track where input starts

function M.get_tab_label()
  -- 获取标签页标签，用于tabline显示
  local label = ""
  for n, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
    if tabpage == vim.api.nvim_get_current_tabpage() then
      label = label .. "%#TabLineSel#"
    else
      label = label .. "%#TabLine#"
    end
    label = label .. "%" .. n .. "T "
    
    -- 检查是否是NeoAI标签页
    local wins = vim.api.nvim_tabpage_list_wins(tabpage)
    local has_neoai = false
    for _, win in ipairs(wins) do
      local buf = vim.api.nvim_win_get_buf(win)
      local buf_name = vim.api.nvim_buf_get_name(buf)
      if buf_name:match("^NeoAI") or buf_name:match("NeoAI://") then
        has_neoai = true
        break
      end
    end

    if has_neoai then
      label = label .. "🤖 NeoAI"
    else
      local buflist = vim.fn.tabpagebuflist(tabpage)
      if buflist and #buflist > 0 then
        local bufname = vim.fn.bufname(buflist[1])
        if bufname and bufname ~= "" then
          label = label .. vim.fn.fnamemodify(bufname, ":t")
        else
          label = label .. "[No Name]"
        end
      end
    end
    
    label = label .. " "
  end
  label = label .. "%#TabLine#%T"
  return label
end

function M.get_border_chars()
  -- 获取信息边框字符
  local border = M.config.ui.info_border or "single"
  
  local border_chars = {
    rounded = {
      top_left = "╭",
      top_right = "╮",
      bottom_left = "╰",
      bottom_right = "╯",
      vertical = "│",
      horizontal = "─",
    },
    single = {
      top_left = "┌",
      top_right = "┐",
      bottom_left = "└",
      bottom_right = "┘",
      vertical = "│",
      horizontal = "─",
    },
    double = {
      top_left = "╔",
      top_right = "╗",
      bottom_left = "╚",
      bottom_right = "╝",
      vertical = "║",
      horizontal = "═",
    },
    solid = {
      top_left = "┏",
      top_right = "┓",
      bottom_left = "┗",
      bottom_right = "┛",
      vertical = "┃",
      horizontal = "━",
    },
    none = {
      top_left = "",
      top_right = "",
      bottom_left = "",
      bottom_right = "",
      vertical = "",
      horizontal = "",
    },
  }
  
  return border_chars[border] or border_chars.single
end

function M.get_separator_char()
  -- 获取分割线字符（用于输入框上方的横线）
  local separator = M.config.ui.input_separator or "single"
  
  local separator_chars = {
    single = "─",
    double = "═",
    solid = "━",
    dotted = "┈",
    dashed = "┄",
  }
  
  return separator_chars[separator] or "─"
end

function M.get_message_separator_char()
  -- 获取消息分割线字符（用于消息块内角色标题和内容的分割）
  local separator = M.config.ui.message_separator or "single"
  
  local separator_chars = {
    single = "─",
    double = "═",
    solid = "━",
    dotted = "┈",
    dashed = "┄",
  }
  
  return separator_chars[separator] or "─"
end

function M.render_message(msg)
  -- 渲染消息
  local lines = {}
  local icon = M.config.show_role_icons and M.config.role_icons[msg.role] or ""
  local timestamp = M.config.show_timestamps and os.date("%H:%M", msg.timestamp) or ""

  local header = string.format("%s %s", icon, msg.role:upper())
  if timestamp ~= "" then
    header = header .. " · " .. timestamp
  end

  if msg.pending then
    header = header .. " (思考中...)"
  end

  local chars = M.get_border_chars()
  local msg_sep = M.get_message_separator_char()
  local width = 60
  
  -- 消息标题行
  table.insert(lines, chars.top_left .. chars.horizontal .. " " .. header)
  -- 消息标题下方的分割线
  table.insert(lines, string.rep(msg_sep, width))

  -- 分割内容为行
  local content_lines = {}
  for line in msg.content:gmatch("[^\r\n]+") do
    table.insert(content_lines, line)
  end

  for i, line in ipairs(content_lines) do
    local prefix = chars.vertical .. " "
    table.insert(lines, prefix .. line)
  end

  table.insert(lines, chars.bottom_left .. string.rep(chars.horizontal, width))
  table.insert(lines, "") -- 空行分隔

  return lines, msg.role
end

function M.update_display()
  -- 更新聊天显示
  local buf = M.buffers.main
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  -- 保存光标位置（如果窗口存在）
  local save_cursor = nil
  if M.windows.main and vim.api.nvim_win_is_valid(M.windows.main) then
    save_cursor = vim.api.nvim_win_get_cursor(M.windows.main)
  end

  -- 确保缓冲区可写
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })

  -- 清除并重新渲染
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})

  local all_lines = {}
  local highlights = {}

  -- 检查是否有会话
  if backend.current_session and backend.sessions[backend.current_session] then
    local session = backend.sessions[backend.current_session]
    
    -- 渲染消息
    if session.messages and #session.messages > 0 then
      for _, msg in ipairs(session.messages) do
        local msg_lines, role = M.render_message(msg)
        for i, line in ipairs(msg_lines) do
          table.insert(all_lines, line)
          -- 添加高亮
          if i == 1 then -- 标题行
            local hl_group = M.config.colors[role .. "_bg"] or "Normal"
            table.insert(highlights, {
              bufnr = buf,
              ns_id = vim.api.nvim_create_namespace("NeoAI"),
              line = #all_lines - 1,
              col_start = 0,
              col_end = #line,
              hl_group = hl_group,
            })
          end
        end
      end
    end
  end
  
  -- 如果没有消息或没有会话，显示提示
  if #all_lines == 0 then
    table.insert(all_lines, "")
    table.insert(all_lines, "  欢迎使用 NeoAI!")
    table.insert(all_lines, "  输入消息开始对话")
    table.insert(all_lines, "")
  end

  -- 添加输入提示线（上方始终有一条横线）
  local input_line = "输入消息: "
  local sep_char = M.get_separator_char()
  table.insert(all_lines, "")
  table.insert(all_lines, string.rep(sep_char, 60))
  table.insert(all_lines, input_line)

  -- 记录输入行的起始位置
  M.input_start_line = #all_lines - 1

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, all_lines)

  for _, hl in ipairs(highlights) do
    -- 应用高亮
    vim.api.nvim_buf_add_highlight(hl.bufnr, hl.ns_id, hl.hl_group, hl.line, hl.col_start, hl.col_end)
  end

  -- 恢复光标位置
  if save_cursor and M.windows.main and vim.api.nvim_win_is_valid(M.windows.main) then
    local max_line = vim.api.nvim_buf_line_count(buf)
    if save_cursor[1] <= max_line then
      pcall(vim.api.nvim_win_set_cursor, M.windows.main, save_cursor)
    end
  end

  -- 自动滚动到底部
  if M.windows.main and vim.api.nvim_win_is_valid(M.windows.main) then
    local last_line = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_win_set_cursor(M.windows.main, { last_line, #input_line })
  end
end

function M.create_buffers()
  -- 创建单个缓冲区同时显示聊天内容和输入
  -- 第一个参数: listed=false (不在buffer列表中显示，避免冲突)
  -- 第二个参数: scratch=true (是临时缓冲区)
  M.buffers.main = vim.api.nvim_create_buf(false, true)
  
  -- 添加初始内容，确保窗口不会显示为空
  local initial_lines = {
    "",
    "  欢迎使用 NeoAI!",
    "  输入消息开始对话",
    "",
  }
  vim.api.nvim_buf_set_lines(M.buffers.main, 0, -1, false, initial_lines)
end

function M.setup_windows(win_opts)
  -- 设置主窗口
  M.windows.main = vim.api.nvim_open_win(M.buffers.main, true, win_opts)

  M.setup_buffers()
  M.is_open = true
end

function M.open_float()
  -- 浮动窗口模式
  local width = math.min(M.config.ui.width, vim.o.columns - 10)
  local height = math.min(M.config.ui.height, vim.o.lines - 10)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  -- 确保有活跃的会话
  if not backend.current_session or not backend.sessions[backend.current_session] then
    if #backend.sessions == 0 then
      backend.new_session("默认会话")
    else
      -- 使用第一个可用的会话
      for id, _ in pairs(backend.sessions) do
        backend.current_session = id
        break
      end
    end
  end

  -- 创建缓冲区
  M.create_buffers()

  -- 设置窗口
  M.setup_windows({
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    border = M.config.ui.border,
    style = "minimal",
  })

  M.current_mode = M.ui_modes.FLOAT
end

function M.open_split()
  -- 分割窗口模式
  -- 确保有活跃的会话
  if not backend.current_session or not backend.sessions[backend.current_session] then
    if #backend.sessions == 0 then
      backend.new_session("默认会话")
    else
      -- 使用第一个可用的会话
      for id, _ in pairs(backend.sessions) do
        backend.current_session = id
        break
      end
    end
  end

  -- 创建缓冲区
  M.create_buffers()

  -- 先执行分割命令
  vim.cmd("belowright vsplit")

  -- 获取当前窗口并使用 nvim_open_win 将缓冲区关联到窗口
  local win_opts = {
    relative = "editor",
    width = math.floor(vim.o.columns * 0.4),
    height = M.config.ui.height,
    row = 0,
    col = vim.o.columns - math.floor(vim.o.columns * 0.4),
    style = "minimal",
  }

  -- 使用当前窗口而不是创建新窗口
  M.windows.main = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.windows.main, M.buffers.main)

  -- 设置缓冲区
  M.setup_buffers()
  M.is_open = true
  M.current_mode = M.ui_modes.SPLIT
end

function M.open_tab()
  -- 标签页模式
  -- 确保有活跃的会话
  if not backend.current_session or not backend.sessions[backend.current_session] then
    if #backend.sessions == 0 then
      backend.new_session("默认会话")
    else
      -- 使用第一个可用的会话
      for id, _ in pairs(backend.sessions) do
        backend.current_session = id
        break
      end
    end
  end

  -- 创建缓冲区
  M.create_buffers()

  -- 保存当前标签页
  local original_tabpage = vim.api.nvim_get_current_tabpage()

  -- 新标签页
  vim.cmd("tabnew")
  local tabpage = vim.api.nvim_get_current_tabpage()

  -- 设置主窗口
  M.windows.main = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.windows.main, M.buffers.main)

  -- 保存原始tabline设置
  M.original_tabline = vim.o.tabline
  M.original_showtabline = vim.o.showtabline

  -- 设置tabline显示标签页名称
  vim.o.showtabline = 2
  vim.o.tabline = '%!v:lua.require("NeoAI.ui").get_tab_label()'

  -- 设置缓冲区
  M.setup_buffers()
  M.is_open = true
  M.current_mode = M.ui_modes.TAB
end

function M.setup_buffers()
  -- 主缓冲区设置
  vim.api.nvim_buf_set_name(M.buffers.main, "NeoAI")
  vim.api.nvim_set_option_value("filetype", "NeoAI", { buf = M.buffers.main })
  vim.api.nvim_set_option_value("modifiable", true, { buf = M.buffers.main })
  vim.api.nvim_set_option_value("buftype", "", { buf = M.buffers.main })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = M.buffers.main })

  -- 快捷键
  M.setup_keymaps()

  -- 设置输入处理
  M.setup_input_handling()

  -- 初始显示
  M.update_display()
end

function M.setup_input_handling()
  -- 使用autocmd处理输入行的编辑
  local group = vim.api.nvim_create_augroup("NeoAIInput", { clear = true })

  -- 当窗口进入时，重新设置快捷键（确保焦点在聊天窗口时快捷键生效）
  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    pattern = "*",
    callback = function()
      local current_win = vim.api.nvim_get_current_win()
      if M.windows.main and current_win == M.windows.main then
        -- 焦点在聊天窗口，设置快捷键
        M.setup_keymaps()
      else
        -- 焦点不在聊天窗口，取消注册快捷键
        M.clear_keymaps()
      end
    end,
  })

  -- 当光标进入输入行时，允许编辑
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = M.buffers.main,
    callback = function()
      if M.input_start_line and M.windows.main and vim.api.nvim_win_is_valid(M.windows.main) then
        local cursor = vim.api.nvim_win_get_cursor(M.windows.main)
        local current_line = cursor[1] - 1  -- 0-indexed

        if current_line >= M.input_start_line then
          -- 在输入行，允许编辑
          vim.api.nvim_set_option_value("modifiable", true, { buf = M.buffers.main })
          vim.api.nvim_set_option_value("readonly", false, { buf = M.buffers.main })
        else
          -- 在聊天内容区域，设置为只读
          vim.api.nvim_set_option_value("modifiable", false, { buf = M.buffers.main })
        end
      end
    end,
  })

  -- 当插入模式离开时，保存并发送消息
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = group,
    buffer = M.buffers.main,
    callback = function()
      if M.input_start_line and M.windows.main and vim.api.nvim_win_is_valid(M.windows.main) then
        local cursor = vim.api.nvim_win_get_cursor(M.windows.main)
        local current_line = cursor[1] - 1  -- 0-indexed

        if current_line >= M.input_start_line then
          M.save_and_send()
          return
        end
      end
    end,
  })
end

function M.save_and_send()
  -- 保存并发送输入的消息
  if not M.input_start_line or not M.buffers.main or not vim.api.nvim_buf_is_valid(M.buffers.main) then
    vim.notify("[NeoAI] 错误: 缓冲区无效", vim.log.levels.WARN)
    return
  end

  if not backend.current_session then
    vim.notify("[NeoAI] 错误: 没有活跃的会话", vim.log.levels.WARN)
    return
  end

  -- 获取输入行的内容
  local lines = vim.api.nvim_buf_get_lines(M.buffers.main, M.input_start_line, M.input_start_line + 1, false)
  if #lines == 0 then
    vim.notify("[NeoAI] 警告: 无法读取输入内容", vim.log.levels.WARN)
    return
  end

  local text = lines[1]:gsub("^输入消息: ", "")
  text = vim.trim(text)
  
  if text == "" then
    vim.notify("[NeoAI] 警告: 输入内容为空", vim.log.levels.WARN)
    return
  end

  -- 发送消息
  local success = backend.send_message(text)
  if success then
    vim.notify("[NeoAI] 消息已发送", vim.log.levels.INFO)
  else
    vim.notify("[NeoAI] 错误: 消息发送失败", vim.log.levels.ERROR)
  end
  
  -- 重新渲染显示
  M.update_display()
end

function M.clear_keymaps()
  -- 取消注册快捷键（当焦点不在聊天窗口时）
  -- 清除 buffer-local 快捷键
  if M.buffers.main and vim.api.nvim_buf_is_valid(M.buffers.main) then
    -- 清除所有模式的快捷键
    for _, mode in ipairs({ "n", "i", "v", "x", "s", "o" }) do
      local keymaps = vim.api.nvim_buf_get_keymap(M.buffers.main, mode)
      for _, km in ipairs(keymaps) do
        vim.api.nvim_buf_del_keymap(M.buffers.main, mode, km.lhs)
      end
    end
  end
end

function M.setup_keymaps()
  -- 设置快捷键 - 仅在聊天窗口获得焦点时生效
  local function buf_map(bufnr, mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, {
      buffer = bufnr,
      desc = desc,
      noremap = true,
    })
  end

  -- 检查当前窗口是否是聊天窗口
  if not M.windows.main or not vim.api.nvim_win_is_valid(M.windows.main) then
    return
  end

  -- 主窗口快捷键
  buf_map(M.buffers.main, "n", "e", function()
    local line = vim.api.nvim_win_get_cursor(M.windows.main)[1]
    vim.notify("按 e 编辑消息 (实现中...)")
  end, "编辑消息")

  buf_map(M.buffers.main, "n", "d", function()
    local line = vim.api.nvim_win_get_cursor(M.windows.main)[1]
    vim.notify("按 d 删除消息 (实现中...)")
  end, "删除消息")

  buf_map(M.buffers.main, "n", "s", function()
    if backend.current_session then
      backend.export_session(backend.current_session)
      vim.notify("会话已导出")
    end
  end, "导出会话")

  -- 打开/关闭/新建 (buffer-local)
  buf_map(M.buffers.main, "n", M.config.keymaps.open, "<cmd>NeoAIOpen<CR>", "打开聊天")
  buf_map(M.buffers.main, "n", M.config.keymaps.close, M.close, "关闭聊天")
  buf_map(M.buffers.main, "n", M.config.keymaps.new, "<cmd>NeoAINew<CR>", "新建会话")

  buf_map(M.buffers.main, "n", "q", M.close, "关闭聊天")
  buf_map(M.buffers.main, "n", "<Esc>", M.close, "关闭聊天")

  -- 输入行发送消息 (Enter键 - 插入模式)
  buf_map(M.buffers.main, "i", "<CR>", function()
    local cursor = vim.api.nvim_win_get_cursor(M.windows.main)
    local current_line = cursor[1] - 1  -- 0-indexed

    if M.input_start_line and current_line >= M.input_start_line then
      -- 在输入行按Enter发送消息
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    else
      -- 否则正常插入
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
    end
  end, "发送消息")

  -- 正常模式下回车发送消息
  buf_map(M.buffers.main, "n", M.config.keymaps.normal_mode_send, function()
    if M.input_start_line and M.windows.main and vim.api.nvim_win_is_valid(M.windows.main) then
      local cursor = vim.api.nvim_win_get_cursor(M.windows.main)
      local current_line = cursor[1] - 1  -- 0-indexed

      if current_line >= M.input_start_line then
        -- 在输入行，进入插入模式
        vim.api.nvim_command("startinsert")
      else
        -- 在聊天内容区域，不执行任何操作
        return
      end
    end
  end, "进入编辑模式")

  -- 插入模式下 Ctrl+s 发送消息
  buf_map(M.buffers.main, "i", M.config.keymaps.insert_mode_send, function()
    M.save_and_send()
  end, "发送消息")

  -- Ctrl+C 关闭
  buf_map(M.buffers.main, "i", "<C-c>", M.close, "关闭聊天")
end

function M.close()
  -- 关闭UI
  for _, win in pairs(M.windows) do
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  -- 清除autocmd组
  pcall(vim.api.nvim_del_augroup_by_name, "NeoAIInput")

  for _, buf in pairs(M.buffers) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end

  -- 恢复原始tabline设置
  if M.original_tabline then
    vim.o.tabline = M.original_tabline
  end
  if M.original_showtabline then
    vim.o.showtabline = M.original_showtabline
  end

  M.windows = {}
  M.buffers = {}
  M.is_open = false
  M.input_start_line = nil
end

function M.switch_mode(mode)
  -- 切换界面模式
  if M.is_open then
    M.close()
  end

  if mode == M.ui_modes.FLOAT then
    M.open_float()
  elseif mode == M.ui_modes.SPLIT then
    M.open_split()
  elseif mode == M.ui_modes.TAB then
    M.open_tab()
  end

  vim.notify("切换到 " .. mode .. " 模式")
end

function M.setup(user_config)
  -- 初始化配置：合并默认配置和用户配置
  M.config = vim.tbl_deep_extend("force", config.defaults, user_config or {})

  -- 监听后端事件
  backend.on("message_added", M.update_display)
  backend.on("message_edited", M.update_display)
  backend.on("ai_replied", M.update_display)
  backend.on("response_received", M.update_display)
end

return M
