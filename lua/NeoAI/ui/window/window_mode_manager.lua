local M = {}

--- 创建浮动窗口
--- @param options table 窗口选项
--- @return table|nil 窗口信息 {buf, win, id}
function M.create_float_window(options)
    local merged_options = vim.tbl_extend("force", {
        relative = "editor",
        style = "minimal",
        border = "rounded",
        title = "NeoAI",
        title_pos = "center",
        zindex = 50
    }, options or {})

    -- 设置窗口大小和位置
    if not merged_options.width then
        merged_options.width = math.floor(vim.o.columns * 0.8)
    end
    if not merged_options.height then
        merged_options.height = math.floor(vim.o.lines * 0.8)
    end
    if not merged_options.row then
        merged_options.row = math.floor((vim.o.lines - merged_options.height) / 2)
    end
    if not merged_options.col then
        merged_options.col = math.floor((vim.o.columns - merged_options.width) / 2)
    end

    -- 创建缓冲区
    local buf = vim.api.nvim_create_buf(false, true)
    
    -- 创建浮动窗口
    -- 移除 nvim_open_win 不支持的参数
    local win_options = vim.deepcopy(merged_options)
    
    -- nvim_open_win 支持的参数列表
    local valid_params = {
        "relative", "width", "height", "row", "col", "anchor", "win", "bufpos",
        "external", "focusable", "zindex", "style", "border", "title", "title_pos", "noautocmd"
    }
    
    -- 过滤掉不支持的参数
    local filtered_options = {}
    for _, param in ipairs(valid_params) do
        if win_options[param] ~= nil then
            filtered_options[param] = win_options[param]
        end
    end
    
    local win = vim.api.nvim_open_win(buf, true, filtered_options)

    -- 设置窗口选项
    vim.api.nvim_win_set_option(win, "winhl", "Normal:Normal,FloatBorder:FloatBorder")
    vim.api.nvim_win_set_option(win, "winblend", merged_options.winblend or 0)

    -- 设置缓冲区选项
    vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
    vim.api.nvim_buf_set_option(buf, "swapfile", false)
    vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
    vim.api.nvim_buf_set_option(buf, "modifiable", true)
    vim.api.nvim_buf_set_option(buf, "readonly", false)
    
    -- 设置缓冲区名称（临时名称，window_manager 会覆盖）
    vim.api.nvim_buf_set_name(buf, "neoai://float/temp")

    return {
        buf = buf,
        win = win,
        id = "float_" .. tostring(buf) .. "_" .. tostring(win)
    }
end

--- 创建标签页窗口
--- @param options table 窗口选项
--- @return table|nil 窗口信息 {buf, win, id}
function M.create_tab_window(options)
    -- 创建新标签页
    vim.cmd("tabnew")
    
    -- 获取当前窗口和缓冲区
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_get_current_buf()
    
    -- 设置缓冲区选项
    vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
    vim.api.nvim_buf_set_option(buf, "swapfile", false)
    vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
    vim.api.nvim_buf_set_option(buf, "modifiable", true)
    vim.api.nvim_buf_set_option(buf, "readonly", false)
    
    -- 设置缓冲区名称（临时名称，window_manager 会覆盖）
    vim.api.nvim_buf_set_name(buf, "neoai://tab/temp")
    
    -- 设置窗口标题
    if options and options.title then
        vim.api.nvim_set_option_value("titlestring", options.title, { scope = "global" })
    end

    return {
        buf = buf,
        win = win,
        id = "tab_" .. tostring(buf) .. "_" .. tostring(win)
    }
end

--- 创建分割窗口
--- @param options table 窗口选项
--- @return table|nil 窗口信息 {buf, win, id}
function M.create_split_window(options)
    local split_cmd = "vsplit"
    local split_size = nil
    
    -- 根据选项决定分割方向
    if options and options.split_direction then
        if options.split_direction == "horizontal" then
            split_cmd = "split"
        elseif options.split_direction == "vertical" then
            split_cmd = "vsplit"
        end
    end
    
    -- 设置分割大小
    if options and options.split_size then
        split_size = options.split_size
    end
    
    -- 执行分割命令
    if split_size then
        vim.cmd(split_cmd .. " " .. split_size)
    else
        vim.cmd(split_cmd)
    end
    
    -- 获取当前窗口和缓冲区
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_get_current_buf()
    
    -- 创建新缓冲区
    local new_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(win, new_buf)
    
    -- 设置缓冲区选项
    vim.api.nvim_buf_set_option(new_buf, "buftype", "nofile")
    vim.api.nvim_buf_set_option(new_buf, "swapfile", false)
    vim.api.nvim_buf_set_option(new_buf, "bufhidden", "wipe")
    vim.api.nvim_buf_set_option(new_buf, "modifiable", true)
    vim.api.nvim_buf_set_option(new_buf, "readonly", false)
    
    -- 设置缓冲区名称（临时名称，window_manager 会覆盖）
    vim.api.nvim_buf_set_name(new_buf, "neoai://split/temp")

    return {
        buf = new_buf,
        win = win,
        id = "split_" .. tostring(new_buf) .. "_" .. tostring(win)
    }
end

--- 根据模式创建窗口
--- @param mode string 窗口模式 ('float', 'tab', 'split')
--- @param options table 窗口选项
--- @return table|nil 窗口信息 {buf, win, id}
function M.create_window_by_mode(mode, options)
    if mode == "float" then
        return M.create_float_window(options)
    elseif mode == "tab" then
        return M.create_tab_window(options)
    elseif mode == "split" then
        return M.create_split_window(options)
    else
        vim.notify("[NeoAI] 无效的窗口模式: " .. tostring(mode), vim.log.levels.ERROR)
        return nil
    end
end

--- 关闭窗口
--- @param window_info table 窗口信息
function M.close_window(window_info)
    if not window_info then
        return
    end
    
    local id = window_info.id or ""
    
    -- 根据窗口类型关闭
    if id:match("^float_") then
        -- 浮动窗口：关闭窗口并删除缓冲区
        if vim.api.nvim_win_is_valid(window_info.win) then
            vim.api.nvim_win_close(window_info.win, true)
        end
        if vim.api.nvim_buf_is_valid(window_info.buf) then
            vim.api.nvim_buf_delete(window_info.buf, { force = true })
        end
    elseif id:match("^tab_") then
        -- 标签页窗口：关闭标签页
        if vim.api.nvim_win_is_valid(window_info.win) then
            -- 切换到其他标签页再关闭当前标签页
            local tabpage = vim.api.nvim_win_get_tabpage(window_info.win)
            local tabpages = vim.api.nvim_list_tabpages()
            
            if #tabpages > 1 then
                -- 获取标签页编号
                local tabpage_number = vim.api.nvim_tabpage_get_number(tabpage)
                
                if tabpage_number then
                    -- 使用 tabclose 命令关闭指定标签页
                    vim.cmd('tabclose ' .. tabpage_number)
                else
                    -- 如果找不到编号，切换到其他标签页再关闭当前标签页
                    for _, tp in ipairs(tabpages) do
                        if tp ~= tabpage then
                            vim.api.nvim_set_current_tabpage(tp)
                            break
                        end
                    end
                    -- 现在当前标签页是其他标签页，可以安全关闭原标签页
                    vim.cmd('tabclose')
                end
            else
                -- 只有一个标签页，不能关闭
                vim.notify("[NeoAI] 不能关闭最后一个标签页", vim.log.levels.WARN)
            end
        end
    elseif id:match("^split_") then
        -- 分割窗口：关闭窗口
        if vim.api.nvim_win_is_valid(window_info.win) then
            vim.api.nvim_win_close(window_info.win, true)
        end
        if vim.api.nvim_buf_is_valid(window_info.buf) then
            vim.api.nvim_buf_delete(window_info.buf, { force = true })
        end
    end
end

--- 设置窗口内容
--- @param window_info table 窗口信息
--- @param content string|table 内容
--- @param filetype string 文件类型
function M.set_window_content(window_info, content, filetype)
    if not window_info or not window_info.buf then
        return
    end
    
    local buf = window_info.buf
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    
    -- 确保缓冲区可修改
    vim.api.nvim_buf_set_option(buf, "modifiable", true)
    vim.api.nvim_buf_set_option(buf, "readonly", false)
    
    -- 清空缓冲区
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
    
    -- 设置内容
    if type(content) == "table" then
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
    else
        local lines = vim.split(content, "\n")
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    end
    
    -- 设置文件类型
    if filetype then
        vim.api.nvim_buf_set_option(buf, "filetype", filetype)
    end
end

--- 追加窗口内容
--- @param window_info table 窗口信息
--- @param content string 内容
function M.append_window_content(window_info, content)
    if not window_info or not window_info.buf then
        return
    end
    
    local buf = window_info.buf
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    
    local lines = vim.split(content, "\n")
    local line_count = vim.api.nvim_buf_line_count(buf)
    
    vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, lines)
end

--- 聚焦窗口
--- @param window_info table 窗口信息
function M.focus_window(window_info)
    if not window_info or not window_info.win then
        return
    end
    
    if vim.api.nvim_win_is_valid(window_info.win) then
        vim.api.nvim_set_current_win(window_info.win)
    end
end

-- 模块状态
local state = {
    initialized = false,
    config = nil,
    current_mode = "float", -- 默认模式
    available_modes = {"float", "tab", "split"}
}

--- 初始化窗口模式管理器
--- @param config table 配置
function M.initialize(config)
    if state.initialized then
        return
    end

    state.config = config or {}
    state.current_mode = config.default_mode or "float"
    state.initialized = true
end

--- 切换窗口模式
--- @param mode string|nil 目标模式（如果为nil则循环切换）
function M.toggle_mode(mode)
    if not state.initialized then
        return
    end

    if mode then
        -- 切换到指定模式
        if vim.tbl_contains(state.available_modes, mode) then
            state.current_mode = mode
            vim.notify("[NeoAI] 窗口模式切换为: " .. mode, vim.log.levels.INFO)
        else
            vim.notify("[NeoAI] 无效的窗口模式: " .. mode, vim.log.levels.ERROR)
        end
    else
        -- 循环切换模式
        local current_index = 1
        for i, available_mode in ipairs(state.available_modes) do
            if available_mode == state.current_mode then
                current_index = i
                break
            end
        end
        
        local next_index = (current_index % #state.available_modes) + 1
        state.current_mode = state.available_modes[next_index]
        vim.notify("[NeoAI] 窗口模式切换为: " .. state.current_mode, vim.log.levels.INFO)
    end
end

--- 获取当前窗口模式
--- @return string 当前模式
function M.get_current_mode()
    return state.current_mode
end

--- 设置窗口模式
--- @param mode string 窗口模式
function M.set_mode(mode)
    if not state.initialized then
        return
    end

    if vim.tbl_contains(state.available_modes, mode) then
        state.current_mode = mode
        vim.notify("[NeoAI] 窗口模式设置为: " .. mode, vim.log.levels.INFO)
    else
        vim.notify("[NeoAI] 无效的窗口模式: " .. mode, vim.log.levels.ERROR)
    end
end

--- 检查窗口是否有效
--- @param window_info table 窗口信息
--- @return boolean 是否有效
function M.is_window_valid(window_info)
    if not window_info then
        return false
    end
    
    local win_valid = window_info.win and vim.api.nvim_win_is_valid(window_info.win)
    local buf_valid = window_info.buf and vim.api.nvim_buf_is_valid(window_info.buf)
    
    return win_valid and buf_valid
end

return M