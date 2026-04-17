local M = {}

-- 模块状态
local state = {
    initialized = false,
    config = nil,
    current_mode = "normal", -- 'normal', 'insert', 'visual'
    input_buffer = "",
    cursor_position = 0,
    placeholder_text = "输入消息...",  -- 输入框占位文本
    is_sending = false,          -- 是否正在发送
    show_placeholder = true      -- 是否显示占位文本
}

--- 初始化输入处理器
--- @param config table 配置
function M.initialize(config)
    if state.initialized then
        return
    end

    state.config = config or {}
    state.initialized = true
end

--- 设置按键映射
function M.setup_keymaps()
    if not state.initialized then
        return
    end

    -- 这里可以设置全局按键映射
    -- 目前是空实现，具体映射在窗口模块中设置
end

--- 处理输入
--- @param key string 按键
function M.handle_input(key)
    if not state.initialized then
        return
    end

    if state.current_mode == "insert" then
        M._handle_insert_input(key)
    else
        M._handle_normal_input(key)
    end
end

--- 发送消息
--- @param content string 消息内容
function M.send_message(content)
    if not state.initialized then
        return
    end

    if not content or content == "" then
        vim.notify("消息内容不能为空", vim.log.levels.WARN)
        return
    end
    
    -- 如果正在发送中，忽略
    if state.is_sending then
        vim.notify("正在发送消息，请稍候...", vim.log.levels.WARN)
        return
    end

    -- 设置发送状态
    state.is_sending = true
    
    -- 这里应该触发发送消息事件
    vim.notify("📤 发送消息: " .. content, vim.log.levels.INFO)
    
    -- 清空输入缓冲区
    state.input_buffer = ""
    state.cursor_position = 0
    state.show_placeholder = true
    
    -- 模拟发送延迟
    vim.defer_fn(function()
        state.is_sending = false
        vim.notify("✅ 消息发送完成", vim.log.levels.INFO)
    end, 1000)
end

--- 编辑消息
--- @param msg_id string 消息ID
function M.edit_message(msg_id)
    if not state.initialized then
        return
    end

    -- 这里应该加载消息内容到输入缓冲区
    -- 目前只是记录日志
    vim.notify("编辑消息: " .. msg_id, vim.log.levels.INFO)
end

--- 设置模式
--- @param mode string 模式 ('normal', 'insert', 'visual')
function M.set_mode(mode)
    if not state.initialized then
        return
    end

    local valid_modes = { "normal", "insert", "visual" }
    if not vim.tbl_contains(valid_modes, mode) then
        return
    end

    local old_mode = state.current_mode
    state.current_mode = mode

    -- 触发模式变更事件
    vim.notify("模式变更: " .. old_mode .. " -> " .. mode, vim.log.levels.INFO)
end

--- 获取当前模式
--- @return string 当前模式
function M.get_current_mode()
    return state.current_mode
end

--- 获取输入缓冲区
--- @return string 输入缓冲区内容
function M.get_input_buffer()
    return state.input_buffer
end

--- 获取显示文本（包含占位文本）
--- @return string 显示文本
function M.get_display_text()
    if state.input_buffer == "" and state.show_placeholder then
        return state.placeholder_text
    end
    return state.input_buffer
end

--- 设置占位文本
--- @param text string 占位文本
function M.set_placeholder_text(text)
    if text and text ~= "" then
        state.placeholder_text = text
    end
end

--- 获取发送状态
--- @return boolean 是否正在发送
function M.is_sending()
    return state.is_sending
end

--- 开始输入（隐藏占位文本）
function M.start_input()
    state.show_placeholder = false
end

--- 结束输入（显示占位文本）
function M.end_input()
    if state.input_buffer == "" then
        state.show_placeholder = true
    end
end

--- 获取光标位置
--- @return number 光标位置
function M.get_cursor_position()
    return state.cursor_position
end

--- 清空输入缓冲区
function M.clear_input_buffer()
    state.input_buffer = ""
    state.cursor_position = 0
    state.show_placeholder = true
end

--- 清空输入（clear_input_buffer的别名）
function M.clear_input()
    return M.clear_input_buffer()
end

--- 处理插入模式输入（内部使用）
--- @param key string 按键
function M._handle_insert_input(key)
    if key == "<Esc>" then
        -- 退出插入模式
        M.set_mode("normal")
        M.end_input()
        return
    elseif key == "<CR>" then
        -- 发送消息
        M.send_message(state.input_buffer)
        return
    elseif key == "<BS>" then
        -- 退格键
        if state.cursor_position > 0 then
            state.input_buffer = state.input_buffer:sub(1, state.cursor_position - 1) .. 
                                state.input_buffer:sub(state.cursor_position + 1)
            state.cursor_position = state.cursor_position - 1
            
            -- 如果输入为空，显示占位文本
            if state.input_buffer == "" then
                state.show_placeholder = true
            end
        end
    elseif key == "<Del>" then
        -- 删除键
        if state.cursor_position < #state.input_buffer then
            state.input_buffer = state.input_buffer:sub(1, state.cursor_position) .. 
                                state.input_buffer:sub(state.cursor_position + 2)
            
            -- 如果输入为空，显示占位文本
            if state.input_buffer == "" then
                state.show_placeholder = true
            end
        end
    elseif key == "<Left>" then
        -- 左箭头
        if state.cursor_position > 0 then
            state.cursor_position = state.cursor_position - 1
        end
    elseif key == "<Right>" then
        -- 右箭头
        if state.cursor_position < #state.input_buffer then
            state.cursor_position = state.cursor_position + 1
        end
    elseif key == "<Home>" then
        -- Home键
        state.cursor_position = 0
    elseif key == "<End>" then
        -- End键
        state.cursor_position = #state.input_buffer
    elseif #key == 1 then
        -- 普通字符
        -- 如果是第一次输入，隐藏占位文本
        if state.show_placeholder then
            state.input_buffer = ""
            state.cursor_position = 0
            state.show_placeholder = false
        end
        
        state.input_buffer = state.input_buffer:sub(1, state.cursor_position) .. 
                            key .. state.input_buffer:sub(state.cursor_position + 1)
        state.cursor_position = state.cursor_position + 1
    end
end

--- 处理普通模式输入（内部使用）
--- @param key string 按键
function M._handle_normal_input(key)
    if key == "i" or key == "a" then
        -- 进入插入模式
        M.set_mode("insert")
        M.start_input()
    elseif key == "v" then
        -- 进入可视模式
        M.set_mode("visual")
    elseif key == ":" then
        -- 命令模式
        M._handle_command_mode()
    elseif key == "/" then
        -- 搜索模式
        M._handle_search_mode()
    end
end

--- 处理命令模式（内部使用）
function M._handle_command_mode()
    vim.notify("进入命令模式", vim.log.levels.INFO)
    -- 这里应该打开命令输入
end

--- 处理搜索模式（内部使用）
function M._handle_search_mode()
    vim.notify("进入搜索模式", vim.log.levels.INFO)
    -- 这里应该打开搜索输入
end

--- 更新配置
--- @param new_config table 新配置
function M.update_config(new_config)
    if not state.initialized then
        return
    end

    state.config = vim.tbl_extend("force", state.config, new_config or {})
end

return M