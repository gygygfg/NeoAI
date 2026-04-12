local M = {}
local backend = require('NeoAI.backend')

M.ui_modes = {
    FLOAT = "float",
    SPLIT = "split",
    TAB = "tab"
}

M.current_mode = M.ui_modes.FLOAT
M.windows = {}
M.buffers = {}
M.is_open = false

-- 通用UI配置
M.config = {
    width = 80,
    height = 20,
    border = "rounded",
    auto_scroll = true,
    show_timestamps = true,
    show_role_icons = true,
    role_icons = {
        user = "👤",
        assistant = "🤖",
        system = "⚙️"
    },
    colors = {
        user_bg = "Normal",
        assistant_bg = "Comment",
        system_bg = "ErrorMsg",
        border = "FloatBorder"
    }
}

-- 渲染消息
function M.render_message(msg)
    local lines = {}
    local icon = M.config.show_role_icons and M.config.role_icons[msg.role] or ""
    local timestamp = M.config.show_timestamps and
        os.date("%H:%M", msg.timestamp) or ""

    local header = string.format("%s %s", icon, msg.role:upper())
    if timestamp ~= "" then
        header = header .. " · " .. timestamp
    end

    if msg.pending then
        header = header .. " (思考中...)"
    end

    table.insert(lines, "╭─ " .. header)

    -- 分割内容为行
    local content_lines = {}
    for line in msg.content:gmatch("[^\r\n]+") do
        table.insert(content_lines, line)
    end

    for i, line in ipairs(content_lines) do
        local prefix = "│ "
        table.insert(lines, prefix .. line)
    end

    table.insert(lines, "╰" .. string.rep("─", 60))
    table.insert(lines, "")  -- 空行分隔

    return lines, msg.role
end

-- 更新聊天显示
function M.update_display()
    if not M.is_open or not backend.current_session then
        return
    end

    local session = backend.sessions[backend.current_session]
    if not session then return end

    local buf = M.buffers.chat
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return
    end

    -- 清除并重新渲染
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})

    local all_lines = {}
    local highlights = {}

    for _, msg in ipairs(session.messages) do
        local msg_lines, role = M.render_message(msg)

        for i, line in ipairs(msg_lines) do
            table.insert(all_lines, line)

            -- 添加高亮
            if i == 1 then  -- 标题行
                local hl_group = M.config.colors[role .. "_bg"] or "Normal"
                table.insert(highlights, {
                    bufnr = buf,
                    ns_id = vim.api.nvim_create_namespace("NeoAI"),
                    line = #all_lines - 1,
                    col_start = 0,
                    col_end = #line,
                    hl_group = hl_group
                })
            end
        end
    end

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, all_lines)

    -- 应用高亮
    for _, hl in ipairs(highlights) do
        vim.api.nvim_buf_add_highlight(hl.bufnr, hl.ns_id, hl.hl_group, hl.line, hl.col_start, hl.col_end)
    end

    -- 自动滚动到底部
    if M.config.auto_scroll and M.windows.chat then
        local last_line = vim.api.nvim_buf_line_count(buf) - 1
        vim.api.nvim_win_set_cursor(M.windows.chat, {last_line + 1, 0})
    end
end

-- 浮动窗口模式
function M.open_float()
    local width = math.min(M.config.width, vim.o.columns - 10)
    local height = math.min(M.config.height, vim.o.lines - 10)
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    -- 创建聊天缓冲区
    M.buffers.chat = vim.api.nvim_create_buf(false, true)
    M.buffers.input = vim.api.nvim_create_buf(false, false)

    -- 浮动窗口
    M.windows.chat = vim.api.nvim_open_win(M.buffers.chat, true, {
        relative = "editor",
        width = width,
        height = height - 3,
        row = row,
        col = col,
        border = M.config.border,
        style = "minimal"
    })

    -- 输入窗口
    M.windows.input = vim.api.nvim_open_win(M.buffers.input, true, {
        relative = "editor",
        width = width,
        height = 3,
        row = row + height - 2,
        col = col,
        border = M.config.border,
        style = "minimal"
    })

    M.setup_buffers()
    M.is_open = true
    M.current_mode = M.ui_modes.FLOAT
end

-- 分割窗口模式
function M.open_split()
    -- 垂直分割
    vim.cmd("vsplit")
    M.windows.chat = vim.api.nvim_get_current_win()
    M.buffers.chat = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(M.windows.chat, M.buffers.chat)

    -- 水平分割输入区
    vim.cmd("split")
    M.windows.input = vim.api.nvim_get_current_win()
    M.buffers.input = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_win_set_buf(M.windows.input, M.buffers.input)

    -- 调整窗口大小
    vim.api.nvim_win_set_height(M.windows.chat, 20)
    vim.api.nvim_win_set_height(M.windows.input, 3)

    M.setup_buffers()
    M.is_open = true
    M.current_mode = M.ui_modes.SPLIT
end

-- 标签页模式
function M.open_tab()
    -- 新标签页
    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()

    -- 垂直分割
    vim.cmd("vsplit")
    M.windows.chat = vim.api.nvim_get_current_win()
    M.buffers.chat = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(M.windows.chat, M.buffers.chat)

    -- 输入窗口
    vim.cmd("split")
    M.windows.input = vim.api.nvim_get_current_win()
    M.buffers.input = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_win_set_buf(M.windows.input, M.buffers.input)

    -- 调整大小
    vim.api.nvim_win_set_height(M.windows.chat, 20)
    vim.api.nvim_win_set_height(M.windows.input, 3)

    -- 设置标签页标题
    vim.api.nvim_tabpage_set_var(tabpage, "NeoAI_tab", true)
    vim.api.nvim_set_option_value("titlestring", "NeoAI", {scope = "local"})

    M.setup_buffers()
    M.is_open = true
    M.current_mode = M.ui_modes.TAB
end

-- 通用缓冲区设置
function M.setup_buffers()
    -- 聊天缓冲区设置
    vim.api.nvim_buf_set_name(M.buffers.chat, "NeoAI://chat")
    vim.api.nvim_set_option_value("filetype", "NeoAI", {buf = M.buffers.chat})
    vim.api.nvim_set_option_value("modifiable", false, {buf = M.buffers.chat})
    vim.api.nvim_set_option_value("buftype", "nofile", {buf = M.buffers.chat})

    -- 输入缓冲区设置
    vim.api.nvim_buf_set_name(M.buffers.input, "NeoAI://input")
    vim.api.nvim_set_option_value("filetype", "text", {buf = M.buffers.input})
    vim.api.nvim_set_option_value("buftype", "prompt", {buf = M.buffers.input})

    -- 输入提示
    vim.fn.prompt_setprompt(M.buffers.input, "输入消息: ")

    -- 输入回调
    vim.fn.prompt_setcallback(M.buffers.input, function(text)
        if text and text ~= "" then
            backend.send_message(backend.current_session, text)
            M.update_display()

            -- 清空输入
            vim.api.nvim_buf_set_lines(M.buffers.input, 0, -1, false, {})
        end
    end)

    -- 快捷键
    M.setup_keymaps()

    -- 初始显示
    M.update_display()
end

-- 设置快捷键
function M.setup_keymaps()
    local function buf_map(bufnr, mode, lhs, rhs, desc)
        vim.keymap.set(mode, lhs, rhs, {
            buffer = bufnr,
            desc = desc,
            noremap = true
        })
    end

    -- 聊天窗口快捷键
    buf_map(M.buffers.chat, 'n', 'e', function()
        local line = vim.api.nvim_win_get_cursor(M.windows.chat)[1]
        vim.print("按 e 编辑消息 (实现中...)")
    end, "编辑消息")

    buf_map(M.buffers.chat, 'n', 'd', function()
        local line = vim.api.nvim_win_get_cursor(M.windows.chat)[1]
        vim.print("按 d 删除消息 (实现中...)")
    end, "删除消息")

    buf_map(M.buffers.chat, 'n', 's', function()
        if backend.current_session then
            backend.export_session(backend.current_session)
            vim.print("会话已导出")
        end
    end, "导出会话")

    buf_map(M.buffers.chat, 'n', 'q', M.close, "关闭聊天")
    buf_map(M.buffers.chat, 'n', '<Esc>', M.close, "关闭聊天")

    -- 输入窗口快捷键
    buf_map(M.buffers.input, 'i', '<C-c>', M.close, "关闭聊天")
    buf_map(M.buffers.input, 'i', '<C-s>', function()
        vim.fn.prompt_setinterrupt(M.buffers.input)
    end, "中断输入")
end

-- 关闭UI
function M.close()
    for _, win in pairs(M.windows) do
        if win and vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end

    for _, buf in pairs(M.buffers) do
        if buf and vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_delete(buf, {force = true})
        end
    end

    M.windows = {}
    M.buffers = {}
    M.is_open = false
end

-- 切换界面模式
function M.switch_mode(mode)
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

    vim.print("切换到 " .. mode .. " 模式")
end

-- 设置配置
function M.setup(config)
    M.config = vim.tbl_deep_extend("force", M.config, config or {})

    -- 监听后端事件
    backend.on('message_added', M.update_display)
    backend.on('message_edited', M.update_display)
    backend.on('ai_replied', M.update_display)
    backend.on('response_received', M.update_display)
end

return M
