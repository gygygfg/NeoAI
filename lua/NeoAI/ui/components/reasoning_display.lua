local M = {}

local window_manager = require("NeoAI.ui.window.window_manager")

-- 模块状态
local state = {
    initialized = false,
    config = nil,
    current_window_id = nil,
    content_buffer = "",
    is_visible = false,
    position = { x = 0, y = 0 }
}

--- 初始化思考过程显示组件
--- @param config table 配置
function M.initialize(config)
    if state.initialized then
        return
    end

    state.config = config or {}
    state.initialized = true
end

--- 显示思考过程
--- @param content string 思考内容
function M.show(content)
    if not state.initialized then
        return
    end

    -- 如果已有窗口，先关闭
    if state.current_window_id then
        M.close()
    end

    state.content_buffer = content or ""
    state.is_visible = true

    -- 创建窗口
    local window_id = window_manager.create_window("reasoning", {
        title = "NeoAI 思考过程",
        width = state.config.width or 60,
        height = state.config.height or 15,
        border = state.config.border or "rounded",
        style = "minimal",
        relative = "editor",
        row = state.position.y or 1,
        col = state.position.x or 1,
        zindex = 100
    })

    if not window_id then
        return
    end

    state.current_window_id = window_id

    -- 设置窗口内容
    M._update_window_content()

    -- 设置按键映射
    M._setup_keymaps()

    return window_id
end

--- 追加思考内容
--- @param content string 思考内容
function M.append(content)
    if not state.initialized then
        return
    end

    if not state.is_visible or not state.current_window_id then
        -- 如果窗口不可见，先显示
        M.show(content)
        return
    end

    state.content_buffer = state.content_buffer .. content
    M._update_window_content()
end

--- 关闭显示
function M.close()
    if not state.initialized then
        return
    end

    if state.current_window_id then
        window_manager.close_window(state.current_window_id)
        state.current_window_id = nil
    end

    state.content_buffer = ""
    state.is_visible = false
end

--- 是否可见
--- @return boolean 是否可见
function M.is_visible()
    return state.is_visible
end

--- 设置位置
--- @param x number X坐标
--- @param y number Y坐标
function M.set_position(x, y)
    if not state.initialized then
        return
    end

    state.position = { x = x, y = y }

    -- 如果窗口打开，更新位置
    if state.current_window_id then
        window_manager.update_window_options(state.current_window_id, {
            row = y,
            col = x
        })
    end
end

--- 获取位置
--- @return table 位置 {x, y}
function M.get_position()
    return vim.deepcopy(state.position)
end

--- 获取内容
--- @return string 思考内容
function M.get_content()
    return state.content_buffer
end

--- 清空内容
function M.clear_content()
    state.content_buffer = ""
    
    if state.current_window_id then
        M._update_window_content()
    end
end

--- 更新窗口内容（内部使用）
function M._update_window_content()
    if not state.current_window_id then
        return
    end

    local lines = {}
    
    -- 添加标题
    table.insert(lines, "=== 思考过程 ===")
    table.insert(lines, "")
    
    -- 添加内容
    if state.content_buffer == "" then
        table.insert(lines, "思考中...")
    else
        local content_lines = vim.split(state.content_buffer, "\n")
        for _, line in ipairs(content_lines) do
            table.insert(lines, "  " .. line)
        end
    end
    
    table.insert(lines, "")
    table.insert(lines, "---")
    table.insert(lines, "按 q 关闭，按 s 保存")

    window_manager.set_window_content(state.current_window_id, lines)
end

--- 设置按键映射（内部使用）
function M._setup_keymaps()
    if not state.current_window_id then
        return
    end

    local buf = window_manager.get_window_buf(state.current_window_id)
    if not buf then
        return
    end

    -- 清除现有映射
    local existing_maps = vim.api.nvim_buf_get_keymap(buf, "n")
    for _, map in ipairs(existing_maps) do
        vim.api.nvim_buf_del_keymap(buf, "n", map.lhs)
    end

    -- 设置新映射
    local keymaps = state.config.keymaps or {
        close = "q",
        save = "s",
        copy = "y",
        clear = "c"
    }

    -- 关闭窗口
    vim.api.nvim_buf_set_keymap(buf, "n", keymaps.close, 
        ":lua require('NeoAI.ui.components.reasoning_display').close()<CR>", 
        { noremap = true, silent = true })

    -- 保存内容
    if keymaps.save then
        vim.api.nvim_buf_set_keymap(buf, "n", keymaps.save, 
            ":lua require('NeoAI.ui.components.reasoning_display')._save_content()<CR>", 
            { noremap = true, silent = true })
    end

    -- 复制内容
    if keymaps.copy then
        vim.api.nvim_buf_set_keymap(buf, "n", keymaps.copy, 
            ":lua require('NeoAI.ui.components.reasoning_display')._copy_content()<CR>", 
            { noremap = true, silent = true })
    end

    -- 清空内容
    if keymaps.clear then
        vim.api.nvim_buf_set_keymap(buf, "n", keymaps.clear, 
            ":lua require('NeoAI.ui.components.reasoning_display').clear_content()<CR>", 
            { noremap = true, silent = true })
    end

    -- 退出键也关闭窗口
    vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", 
        ":lua require('NeoAI.ui.components.reasoning_display').close()<CR>", 
        { noremap = true, silent = true })
end

--- 保存内容（内部使用）
function M._save_content()
    if not state.initialized or state.content_buffer == "" then
        return
    end

    -- 这里应该实现保存逻辑
    -- 目前只是记录日志
    vim.notify("保存思考内容 (" .. #state.content_buffer .. " 字符)", vim.log.levels.INFO)
end

--- 复制内容（内部使用）
function M._copy_content()
    if not state.initialized or state.content_buffer == "" then
        return
    end

    -- 复制到系统剪贴板
    vim.fn.setreg("+", state.content_buffer)
    vim.notify("思考内容已复制到剪贴板", vim.log.levels.INFO)
end

--- 获取窗口ID
--- @return string|nil 窗口ID
function M.get_window_id()
    return state.current_window_id
end

--- 调整大小
--- @param width number 宽度
--- @param height number 高度
function M.resize(width, height)
    if not state.initialized or not state.current_window_id then
        return
    end

    window_manager.update_window_options(state.current_window_id, {
        width = width,
        height = height
    })
end

--- 移动窗口
--- @param direction string 方向 ('up', 'down', 'left', 'right')
--- @param amount number 移动量
function M.move(direction, amount)
    if not state.initialized or not state.current_window_id then
        return
    end

    amount = amount or 5
    local new_position = vim.deepcopy(state.position)

    if direction == "up" then
        new_position.y = math.max(1, new_position.y - amount)
    elseif direction == "down" then
        new_position.y = new_position.y + amount
    elseif direction == "left" then
        new_position.x = math.max(1, new_position.x - amount)
    elseif direction == "right" then
        new_position.x = new_position.x + amount
    end

    M.set_position(new_position.x, new_position.y)
end

--- 切换可见性
function M.toggle()
    if not state.initialized then
        return
    end

    if state.is_visible then
        M.close()
    else
        M.show(state.content_buffer)
    end
end

--- 更新配置
--- @param new_config table 新配置
function M.update_config(new_config)
    if not state.initialized then
        return
    end

    state.config = vim.tbl_extend("force", state.config, new_config or {})
    
    -- 如果窗口打开，重新设置按键映射
    if state.current_window_id then
        M._setup_keymaps()
        M._update_window_content()
    end
end

return M