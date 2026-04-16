local M = {}

-- 模块状态
local state = {
    initialized = false,
    config = nil,
    active = false,
    buffer_id = nil,
    window_id = nil,
    parent_window_id = nil,
    content = "",
    placeholder = "输入消息...",
    cursor_position = 0,
    on_submit = nil,
    on_cancel = nil,
    on_change = nil
}

--- 初始化虚拟输入组件
--- @param config table 配置
function M.initialize(config)
    if state.initialized then
        return
    end

    state.config = config or {}
    state.initialized = true
end

--- 打开虚拟输入框
--- @param parent_window_id number 父窗口ID
--- @param options table 选项
--- @return boolean 是否成功
function M.open(parent_window_id, options)
    if not state.initialized then
        return false
    end

    if state.active then
        M.close()
    end

    state.parent_window_id = parent_window_id
    state.content = options.content or ""
    state.placeholder = options.placeholder or "输入消息..."
    state.on_submit = options.on_submit
    state.on_cancel = options.on_cancel
    state.on_change = options.on_change
    state.cursor_position = #state.content

    -- 检查父窗口是否有效
    if not parent_window_id then
        vim.notify("无效的父窗口ID: 参数为空", vim.log.levels.ERROR)
        return false
    end
    
    -- 记录调试信息
    local parent_type = type(parent_window_id)
    local parent_value = tostring(parent_window_id)
    
    -- 验证窗口句柄类型
    if parent_type ~= "number" then
        vim.notify(string.format("无效的父窗口ID类型: 期望数字，实际为 %s (值: %s)", parent_type, parent_value), vim.log.levels.ERROR)
        return false
    end

    -- 验证窗口是否存在
    local ok, win_exists = pcall(function()
        return vim.api.nvim_win_is_valid(parent_window_id)
    end)
    
    if not ok then
        vim.notify(string.format("检查窗口有效性时出错: %s", tostring(win_exists)), vim.log.levels.ERROR)
        return false
    end
    
    if not win_exists then
        vim.notify(string.format("父窗口不存在或已关闭 (窗口ID: %d)", parent_window_id), vim.log.levels.ERROR)
        return false
    end

    -- 获取父窗口信息
    local parent_buf = vim.api.nvim_win_get_buf(parent_window_id)
    local parent_win_config = vim.api.nvim_win_get_config(parent_window_id)

    -- 创建虚拟输入缓冲区
    state.buffer_id = vim.api.nvim_create_buf(false, true)
    if not state.buffer_id then
        return false
    end

    -- 设置缓冲区选项
    vim.api.nvim_buf_set_option(state.buffer_id, "buftype", "prompt")
    vim.api.nvim_buf_set_option(state.buffer_id, "bufhidden", "wipe")
    vim.api.nvim_buf_set_option(state.buffer_id, "swapfile", false)
    vim.api.nvim_buf_set_option(state.buffer_id, "filetype", "markdown")

    -- 设置缓冲区内容
    if state.content == "" then
        vim.api.nvim_buf_set_lines(state.buffer_id, 0, -1, false, {state.placeholder})
        vim.api.nvim_buf_add_highlight(state.buffer_id, -1, "Comment", 0, 0, -1)
    else
        vim.api.nvim_buf_set_lines(state.buffer_id, 0, -1, false, {state.content})
    end

    -- 计算输入框位置（在父窗口底部）
    local parent_height = vim.api.nvim_win_get_height(parent_window_id)
    local input_height = 3  -- 输入框高度

    -- 创建输入窗口
    state.window_id = vim.api.nvim_open_win(state.buffer_id, true, {
        relative = "win",
        win = parent_window_id,
        width = vim.api.nvim_win_get_width(parent_window_id) - 4,
        height = input_height,
        row = parent_height - input_height - 1,
        col = 2,
        style = "minimal",
        border = "rounded",
        focusable = true
    })

    if not state.window_id then
        vim.api.nvim_buf_delete(state.buffer_id, {force = true})
        return false
    end

    -- 设置窗口选项
    vim.api.nvim_win_set_option(state.window_id, "winhl", "Normal:NormalFloat")
    vim.api.nvim_win_set_option(state.window_id, "wrap", true)

    -- 设置按键映射
    M._setup_keymaps()

    -- 设置光标位置
    vim.api.nvim_win_set_cursor(state.window_id, {1, state.cursor_position})

    -- 激活状态
    state.active = true

    -- 进入插入模式
    vim.api.nvim_set_current_win(state.window_id)
    vim.cmd("startinsert!")

    return true
end

--- 关闭虚拟输入框
function M.close()
    if not state.active then
        return
    end

    -- 保存内容
    local lines = vim.api.nvim_buf_get_lines(state.buffer_id, 0, -1, false)
    if #lines > 0 then
        state.content = lines[1]
        if state.content == state.placeholder then
            state.content = ""
        end
    end

    -- 关闭窗口
    if state.window_id and vim.api.nvim_win_is_valid(state.window_id) then
        vim.api.nvim_win_close(state.window_id, true)
    end

    -- 删除缓冲区
    if state.buffer_id and vim.api.nvim_buf_is_valid(state.buffer_id) then
        vim.api.nvim_buf_delete(state.buffer_id, {force = true})
    end

    -- 重置状态
    state.active = false
    state.buffer_id = nil
    state.window_id = nil

    -- 返回焦点到父窗口
    if state.parent_window_id and vim.api.nvim_win_is_valid(state.parent_window_id) then
        vim.api.nvim_set_current_win(state.parent_window_id)
    end
end

--- 提交输入内容
function M.submit()
    if not state.active then
        return
    end

    -- 获取内容
    local lines = vim.api.nvim_buf_get_lines(state.buffer_id, 0, -1, false)
    local content = ""
    if #lines > 0 then
        content = lines[1]
        if content == state.placeholder then
            content = ""
        end
    end

    -- 调用提交回调
    if state.on_submit and content ~= "" then
        state.on_submit(content)
    end

    -- 关闭输入框
    M.close()
end

--- 回到正常模式（不关闭输入框）
function M.enter_normal_mode()
    if not state.active then
        return
    end

    -- 保存当前内容
    local lines = vim.api.nvim_buf_get_lines(state.buffer_id, 0, -1, false)
    if #lines > 0 then
        state.content = lines[1]
        if state.content == state.placeholder then
            state.content = ""
        end
    end

    -- 退出插入模式，进入普通模式
    vim.cmd("stopinsert")
    
    -- 通知内容变化（如果有回调）
    if state.on_change then
        state.on_change(state.content)
    end
end

--- 取消输入
function M.cancel()
    if not state.active then
        return
    end

    -- 调用取消回调
    if state.on_cancel then
        state.on_cancel()
    end

    -- 关闭输入框
    M.close()
end

--- 获取当前内容
--- @return string 输入内容
function M.get_content()
    if state.active and state.buffer_id then
        local lines = vim.api.nvim_buf_get_lines(state.buffer_id, 0, -1, false)
        if #lines > 0 then
            local content = lines[1]
            if content == state.placeholder then
                return ""
            end
            return content
        end
    end
    return state.content
end

--- 设置内容
--- @param content string 内容
function M.set_content(content)
    state.content = content or ""
    
    if state.active and state.buffer_id then
        if state.content == "" then
            vim.api.nvim_buf_set_lines(state.buffer_id, 0, -1, false, {state.placeholder})
            vim.api.nvim_buf_add_highlight(state.buffer_id, -1, "Comment", 0, 0, -1)
        else
            vim.api.nvim_buf_set_lines(state.buffer_id, 0, -1, false, {state.content})
        end
    end
end

--- 设置占位文本
--- @param placeholder string 占位文本
function M.set_placeholder(placeholder)
    state.placeholder = placeholder or "输入消息..."
end

--- 是否激活
--- @return boolean 是否激活
function M.is_active()
    return state.active
end

--- 获取缓冲区ID
--- @return number|nil 缓冲区ID
function M.get_buffer_id()
    return state.buffer_id
end

--- 获取窗口ID
--- @return number|nil 窗口ID
function M.get_window_id()
    return state.window_id
end

--- 获取虚拟输入框键位配置
--- @return table 键位配置
function M._get_keymaps()
    local default_keymaps = {
        normal_mode = "<Esc>",      -- 回到正常模式
        submit = "<CR>",           -- 发送消息
        cancel = "<C-c>",          -- 取消输入框
        clear = "<C-u>"            -- 清空输入
    }
    
    -- 从配置中获取键位
    if state.config and state.config.ui and state.config.ui.keymaps and state.config.ui.keymaps.virtual_input then
        local config_keymaps = state.config.ui.keymaps.virtual_input
        local result = {}
        
        -- 映射配置键位到内部键位名称
        for internal_name, default_key in pairs(default_keymaps) do
            if config_keymaps[internal_name] and config_keymaps[internal_name].key then
                result[internal_name] = config_keymaps[internal_name].key
            else
                result[internal_name] = default_key
            end
        end
        
        return result
    end
    
    return default_keymaps
end

--- 设置按键映射（内部使用）
function M._setup_keymaps()
    if not state.buffer_id then
        return
    end
    
    -- 获取键位配置
    local keymaps = M._get_keymaps()

    -- 清除现有映射
    local existing_maps = vim.api.nvim_buf_get_keymap(state.buffer_id, "i")
    for _, map in ipairs(existing_maps) do
        vim.api.nvim_buf_del_keymap(state.buffer_id, "i", map.lhs)
    end
    
    -- 也清除普通模式映射
    local existing_nmaps = vim.api.nvim_buf_get_keymap(state.buffer_id, "n")
    for _, map in ipairs(existing_nmaps) do
        vim.api.nvim_buf_del_keymap(state.buffer_id, "n", map.lhs)
    end

    -- 获取键位配置
    local keymaps = M._get_keymaps()
    
    -- 提交（Enter）
    if keymaps.submit then
        vim.api.nvim_buf_set_keymap(state.buffer_id, "i", keymaps.submit, 
            "<Cmd>lua require('NeoAI.ui.components.virtual_input').submit()<CR>", 
            { noremap = true, silent = true, desc = "发送消息" })
    end
    
    -- 回到正常模式（ESC）
    if keymaps.normal_mode then
        vim.api.nvim_buf_set_keymap(state.buffer_id, "i", keymaps.normal_mode, 
            "<Cmd>lua require('NeoAI.ui.components.virtual_input').enter_normal_mode()<CR>", 
            { noremap = true, silent = true, desc = "回到正常模式" })
        
        -- 普通模式下也映射ESC键
        vim.api.nvim_buf_set_keymap(state.buffer_id, "n", keymaps.normal_mode, 
            "<Cmd>lua require('NeoAI.ui.components.virtual_input').enter_normal_mode()<CR>", 
            { noremap = true, silent = true, desc = "回到正常模式" })
    end
    
    -- 回到正常模式（Ctrl+c）
    if keymaps.cancel then
        vim.api.nvim_buf_set_keymap(state.buffer_id, "i", keymaps.cancel, 
            "<Cmd>lua require('NeoAI.ui.components.virtual_input').enter_normal_mode()<CR>", 
            { noremap = true, silent = true, desc = "回到正常模式" })
    end
    
    -- 清空输入（Ctrl+u）
    if keymaps.clear then
        vim.api.nvim_buf_set_keymap(state.buffer_id, "i", keymaps.clear, 
            "<Cmd>lua require('NeoAI.ui.components.virtual_input').set_content('')<CR>", 
            { noremap = true, silent = true, desc = "清空输入" })
    end

    -- 内容变化时触发回调
    vim.api.nvim_buf_attach(state.buffer_id, false, {
        on_lines = function(_, _, _, _, _, _, _)
            if state.on_change then
                local content = M.get_content()
                -- 使用vim.defer_fn延迟执行，避免在on_lines回调上下文中执行可能改变窗口的操作
                vim.defer_fn(function()
                    state.on_change(content)
                end, 0)
            end
        end
    })
end

return M