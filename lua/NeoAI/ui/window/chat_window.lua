local M = {}

local window_manager = require("NeoAI.ui.window.window_manager")
local virtual_input = require("NeoAI.ui.components.virtual_input")

-- 简单的日志函数（临时替代）
local logger = {
    debug = function(msg, ...) 
        if select('#', ...) > 0 then
            msg = string.format(msg, ...)
        end
        vim.notify("[DEBUG] " .. msg, vim.log.levels.DEBUG)
    end,
    info = function(msg, ...) 
        if select('#', ...) > 0 then
            msg = string.format(msg, ...)
        end
        vim.notify("[INFO] " .. msg, vim.log.levels.INFO)
    end,
    warn = function(msg, ...) 
        if select('#', ...) > 0 then
            msg = string.format(msg, ...)
        end
        vim.notify("[WARN] " .. msg, vim.log.levels.WARN)
    end,
    error = function(msg, ...) 
        if select('#', ...) > 0 then
            msg = string.format(msg, ...)
        end
        vim.notify("[ERROR] " .. msg, vim.log.levels.ERROR)
    end
}

-- 模块状态
local state = {
    initialized = false,
    config = nil,
    current_window_id = nil,
    current_session_id = nil,
    current_branch_id = nil,
    message_buffer = {},
    input_buffer = "",
    is_sending = false,          -- 是否正在发送消息
    placeholder_text = "输入消息...",  -- 输入框占位文本
    last_send_time = 0,          -- 上次发送时间
    send_count = 0,              -- 发送消息计数
    virtual_input_active = false, -- 虚拟输入框是否激活
    virtual_input_buf = nil,     -- 虚拟输入缓冲区ID
    virtual_input_win = nil,     -- 虚拟输入窗口ID
    current_ai_response = nil    -- 当前AI流式响应
}

--- 初始化聊天窗口
--- @param config table 配置
function M.initialize(config)
    if state.initialized then
        return
    end

    state.config = config or {}
    
    -- 确保虚拟输入框能访问键位配置
    local virtual_input_config = {
        keymaps = config.keymaps or {}
    }
    
    -- 初始化虚拟输入组件
    virtual_input.initialize(virtual_input_config)
    
    state.initialized = true
end

--- 打开聊天窗口
--- @param session_id string 会话ID
--- @param branch_id string 分支ID
--- @return string|nil 窗口ID
function M.open(session_id, branch_id)
    if not state.initialized then
        error("Chat window not initialized")
    end

    -- 如果已有窗口，先关闭
    if state.current_window_id then
        M.close()
    end

    state.current_session_id = session_id
    state.current_branch_id = branch_id
    state.message_buffer = {}
    state.input_buffer = ""

    -- 创建窗口
    local window_id = window_manager.create_window("chat", {
        title = "NeoAI Chat",
        width = state.config.width or 80,
        height = state.config.height or 20,
        border = state.config.border or "rounded"
    })

    if not window_id then
        return nil
    end

    state.current_window_id = window_id

    -- 加载消息
    M._load_messages()
    
    -- 如果没有消息，添加一条测试消息
    if #state.message_buffer == 0 then
        table.insert(state.message_buffer, {
            role = "assistant",
            content = "欢迎使用 NeoAI！我是您的AI助手，随时为您服务。\n\n您可以：\n1. 输入消息与我对话\n2. 按 i 键打开虚拟输入框\n3. 按 Enter 或 Ctrl+s 发送消息\n4. 按 Esc 关闭窗口",
            metadata = { is_welcome = true }
        })
        vim.notify("已添加欢迎消息", vim.log.levels.INFO)
    end

    -- 渲染消息
    M.render_messages()
    
    -- 验证渲染是否成功
    local buf = window_manager.get_window_buf(window_id)
    if buf and vim.api.nvim_buf_is_valid(buf) then
        local line_count = vim.api.nvim_buf_line_count(buf)
        vim.notify(string.format("聊天窗口已打开，缓冲区行数: %d", line_count), vim.log.levels.INFO)
    else
        vim.notify("警告: 聊天窗口缓冲区无效", vim.log.levels.WARN)
    end

    -- 设置输入区域
    M._setup_input_area()

    -- 注意：键位映射由UI模块在打开窗口后调用set_keymaps()设置
    -- 这里不直接调用，因为需要从核心模块获取键位管理器
    
    -- 启动自动状态检查
    M._init_auto_check()

    return window_id
end

--- 检查聊天窗口是否打开
--- @return boolean 窗口是否打开
function M.is_open()
    return state.current_window_id ~= nil and M.is_window_valid()
end

--- 检查聊天窗口是否可用（打开且未处于发送状态）
--- @return boolean, string|nil 是否可用，错误信息
function M.is_available()
    -- 检查窗口是否打开
    if not M.is_open() then
        return false, "聊天窗口未打开或已关闭"
    end
    
    -- 检查是否正在发送消息
    if state.is_sending then
        return false, "正在发送消息，请稍候"
    end
    
    -- 检查虚拟输入框状态
    if state.virtual_input_active then
        return false, "虚拟输入框已激活"
    end
    
    return true, nil
end

--- 安全执行操作（检查窗口状态后执行）
--- @param action function 要执行的操作
--- @param error_message string 错误消息
function M._safe_execute(action, error_message)
    local available, err = M.is_available()
    if not available then
        vim.notify(error_message or err or "操作失败", vim.log.levels.ERROR)
        return false
    end
    
    return action()
end

--- 显示聊天窗口状态（调试用）
function M.show_status()
    local status = {
        "=== 聊天窗口状态 ===",
        "初始化状态: " .. (state.initialized and "已初始化" or "未初始化"),
        "窗口ID: " .. (state.current_window_id or "无"),
        "窗口有效: " .. (M.is_window_valid() and "是" or "否"),
        "窗口打开: " .. (M.is_open() and "是" or "否"),
        "会话ID: " .. (state.current_session_id or "无"),
        "分支ID: " .. (state.current_branch_id or "无"),
        "正在发送: " .. (state.is_sending and "是" or "否"),
        "虚拟输入激活: " .. (state.virtual_input_active and "是" or "否"),
        "输入内容: '" .. state.input_buffer .. "'",
        "消息数量: " .. #state.message_buffer,
        "发送计数: " .. state.send_count,
        "=== 结束状态 ==="
    }
    
    -- 创建临时缓冲区显示状态
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, status)
    vim.bo[buf].filetype = "markdown"
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    
    local width = math.min(60, vim.o.columns - 10)
    local height = math.min(20, vim.o.lines - 10)
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        col = math.floor((vim.o.columns - width) / 2),
        row = math.floor((vim.o.lines - height) / 2),
        style = "minimal",
        border = "rounded",
        title = "聊天窗口状态",
        title_pos = "center",
    })
    
    -- 设置窗口选项
    vim.wo[win].wrap = true
    vim.wo[win].cursorline = true
end

--- 渲染消息
function M.render_messages()
    -- 首先检查并清理无效窗口状态
    M._check_and_cleanup()
    
    if not M.is_open() then
        return
    end

    local content = {}

    -- 添加标题
    table.insert(content, "=== NeoAI Chat ===")
    table.insert(content, string.format("会话: %s | 分支: %s", 
        state.current_session_id or "无", 
        state.current_branch_id or "无"))
    
    -- 显示发送状态
    if state.is_sending then
        table.insert(content, "🔄 正在发送消息...")
    elseif state.virtual_input_active then
        table.insert(content, "⌨️  正在输入中...")
    else
        table.insert(content, "✅ 就绪")
    end
    
    table.insert(content, "")

    -- 调试信息：显示消息数量
    if #state.message_buffer == 0 then
        table.insert(content, "📭 暂无消息")
        table.insert(content, "")
    else
        table.insert(content, string.format("📨 消息数量: %d", #state.message_buffer))
        table.insert(content, "")
    end

    -- 添加消息
    for _, msg in ipairs(state.message_buffer) do
        local role_icon = msg.role == "user" and "👤" or msg.role == "assistant" and "🤖" or "🛠️"
        local role_label = msg.role:upper()
        
        table.insert(content, string.format("%s [%s]:", role_icon, role_label))
        
        if type(msg.content) == "table" then
            table.insert(content, "  " .. vim.json.encode(msg.content))
        else
            local content_text = msg.content or "[空消息]"
            local lines = vim.split(content_text, "\n")
            for _, line in ipairs(lines) do
                table.insert(content, "  " .. line)
            end
        end
        
        table.insert(content, "")
    end

    -- 添加输入区域
    table.insert(content, "---")
    table.insert(content, "输入消息:")
    
    -- 显示输入框，如果为空则显示占位文本
    local input_display = state.input_buffer
    if input_display == "" then
        input_display = state.placeholder_text
        if state.virtual_input_active then
            table.insert(content, "⌨️  [虚拟输入框已打开]")
        else
            table.insert(content, "> " .. input_display .. " (占位文本)")
        end
    else
        if state.virtual_input_active then
            table.insert(content, "⌨️  " .. input_display .. " [正在编辑]")
        else
            table.insert(content, "> " .. input_display)
        end
    end
    
    -- 添加操作提示
    table.insert(content, "")
    table.insert(content, "操作提示:")
    if state.virtual_input_active then
        table.insert(content, "  • 按 Ctrl+s 发送消息并关闭输入框")
        table.insert(content, "  • 按 Esc 或 Ctrl+c 直接关闭输入框")
        table.insert(content, "  • 按 Ctrl+u 清空输入框")
    else
        table.insert(content, "  • 按 i 或 a 打开虚拟输入框")
        table.insert(content, "  • 按 Enter 或 Ctrl+s 发送消息")
        table.insert(content, "  • 按 Esc 取消/关闭窗口")
        table.insert(content, "  • 按 Ctrl+u 清空输入")
    end
    
    -- 显示统计信息
    if state.send_count > 0 then
        table.insert(content, "")
        table.insert(content, string.format("📊 统计: 已发送 %d 条消息", state.send_count))
    end

    -- 设置窗口内容
    window_manager.set_window_content(state.current_window_id, content)
    
    -- 滚动到底部
    M._scroll_to_bottom()
end

--- 更新输入框
--- @param content string 输入内容
function M.update_input(content)
    state.input_buffer = content or ""
    if M.is_open() then
        M.render_messages()
    end
end

--- 清空输入框
function M.clear_input()
    return M._safe_execute(function()
        -- 如果虚拟输入框激活，清空其内容
        if state.virtual_input_active then
            virtual_input.set_content("")
        end
        
        state.input_buffer = ""
        vim.notify("🗑️ 输入已清空", vim.log.levels.INFO)
        if M.is_open() then
            M.render_messages()
        end
        return true
    end, "无法清空输入")
end

--- 设置按键映射
--- @param keymap_manager table|nil 键位配置管理器
function M.set_keymaps(keymap_manager)
    if not M.is_open() then
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

    -- 获取键位配置
    local keymaps = {}
    
    if keymap_manager then
        -- 从键位配置管理器获取
        local chat_keymaps = keymap_manager.get_context_keymaps("chat")
        if chat_keymaps then
            -- 映射到内部键位名称，使用配置的值或默认值
            keymaps = {
                send = chat_keymaps.send and chat_keymaps.send.key or "<C-s>",
                cancel = chat_keymaps.cancel and chat_keymaps.cancel.key or "<Esc>",
                newline = chat_keymaps.newline and chat_keymaps.newline.key or "<C-CR>",
                clear = chat_keymaps.clear and chat_keymaps.clear.key or "<C-u>",  -- 清空输入
                edit = chat_keymaps.edit and chat_keymaps.edit.key or "e",
                delete = chat_keymaps.delete and chat_keymaps.delete.key or "dd",
                scroll_up = chat_keymaps.scroll_up and chat_keymaps.scroll_up.key or "<C-u>",
                scroll_down = chat_keymaps.scroll_down and chat_keymaps.scroll_down.key or "<C-d>",
                toggle_reasoning = chat_keymaps.toggle_reasoning and chat_keymaps.toggle_reasoning.key or "r"
            }
        else
            keymaps = state.config.keymaps or M._get_default_keymaps()
        end
    else
        keymaps = state.config.keymaps or M._get_default_keymaps()
    end

    -- 发送消息（Ctrl+s）
    vim.api.nvim_buf_set_keymap(buf, "n", keymaps.send, 
        ":lua require('NeoAI.ui.window.chat_window')._handle_send()<CR>", 
        { noremap = true, silent = true, desc = "发送消息" })
    
    -- 发送消息（回车键）
    vim.api.nvim_buf_set_keymap(buf, "n", "<CR>", 
        ":lua require('NeoAI.ui.window.chat_window')._handle_send()<CR>", 
        { noremap = true, silent = true, desc = "发送消息" })

    -- 取消/关闭窗口（已禁用）
    -- vim.api.nvim_buf_set_keymap(buf, "n", keymaps.cancel, 
    --     ":lua require('NeoAI.ui.window.chat_window').safe_close()<CR>", 
    --     { noremap = true, silent = true, desc = "取消生成/关闭窗口" })

    -- 清空输入
    if keymaps.clear then
        vim.api.nvim_buf_set_keymap(buf, "n", keymaps.clear, 
            ":lua require('NeoAI.ui.window.chat_window').clear_input()<CR>", 
            { noremap = true, silent = true, desc = "清空输入" })
    end
    
    -- 编辑消息
    if keymaps.edit then
        vim.api.nvim_buf_set_keymap(buf, "n", keymaps.edit, 
            ":lua require('NeoAI.ui.window.chat_window')._edit_message()<CR>", 
            { noremap = true, silent = true, desc = "编辑消息" })
    end
    
    -- 删除消息
    if keymaps.delete then
        vim.api.nvim_buf_set_keymap(buf, "n", keymaps.delete, 
            ":lua require('NeoAI.ui.window.chat_window')._delete_message()<CR>", 
            { noremap = true, silent = true, desc = "删除消息" })
    end
    
    -- 滚动
    if keymaps.scroll_up then
        vim.api.nvim_buf_set_keymap(buf, "n", keymaps.scroll_up, 
            ":lua require('NeoAI.ui.window.chat_window')._scroll_up()<CR>", 
            { noremap = true, silent = true, desc = "向上滚动" })
    end
    
    if keymaps.scroll_down then
        vim.api.nvim_buf_set_keymap(buf, "n", keymaps.scroll_down, 
            ":lua require('NeoAI.ui.window.chat_window')._scroll_down()<CR>", 
            { noremap = true, silent = true, desc = "向下滚动" })
    end
    
    -- 切换思考过程显示
    if keymaps.toggle_reasoning then
        vim.api.nvim_buf_set_keymap(buf, "n", keymaps.toggle_reasoning, 
            ":lua require('NeoAI.ui.window.chat_window')._toggle_reasoning()<CR>", 
            { noremap = true, silent = true, desc = "切换思考过程显示" })
    end

    -- 输入模式切换
    vim.api.nvim_buf_set_keymap(buf, "n", "i", 
        ":lua require('NeoAI.ui.window.chat_window')._enter_input_mode()<CR>", 
        { noremap = true, silent = true, desc = "进入插入模式" })

    vim.api.nvim_buf_set_keymap(buf, "n", "a", 
        ":lua require('NeoAI.ui.window.chat_window')._enter_input_mode()<CR>", 
        { noremap = true, silent = true, desc = "进入插入模式（行尾）" })
    
    -- 插入模式下发送消息（Ctrl+s）
    vim.api.nvim_buf_set_keymap(buf, "i", keymaps.send, 
        "<Cmd>lua require('NeoAI.ui.window.chat_window')._handle_send()<CR>", 
        { noremap = true, silent = true, desc = "发送消息" })
end

--- 获取默认键位配置
--- @return table 默认键位配置
function M._get_default_keymaps()
    return {
        send = "<C-s>",
        cancel = nil,  -- 已禁用关闭快捷键
        newline = "<C-CR>",
        clear = "<C-u>",
        edit = "e",
        delete = "dd",
        scroll_up = "<C-u>",
        scroll_down = "<C-d>",
        toggle_reasoning = "r"
    }
end

--- 关闭聊天窗口
function M.close()
    if not state.current_window_id then
        return
    end
    
    -- 如果正在发送中，询问确认
    if state.is_sending then
        local confirm = vim.fn.confirm("正在发送消息，确定要关闭窗口吗？", "&Yes\n&No", 2)
        if confirm ~= 1 then  -- 不是Yes
            return
        end
    end
    
    -- 关闭虚拟输入框
    if state.virtual_input_active then
        virtual_input.close()
    end

    window_manager.close_window(state.current_window_id)
    
    -- 重置状态
    M._reset_state()
    
    vim.notify("🗑️ 聊天窗口已关闭", vim.log.levels.INFO)
end

--- 检查窗口是否有效
--- @return boolean 窗口是否有效
function M.is_window_valid()
    if not state.current_window_id then
        return false
    end
    
    -- 检查窗口管理器中的窗口是否有效
    local window_info = window_manager.get_window_info(state.current_window_id)
    if not window_info then
        return false
    end
    
    -- 检查窗口句柄是否有效
    if window_info.win and vim.api.nvim_win_is_valid(window_info.win) then
        return true
    end
    
    return false
end

--- 安全关闭窗口（处理窗口可能已关闭的情况）
function M.safe_close()
    if not state.current_window_id then
        return
    end
    
    -- 检查窗口是否仍然有效
    if not M.is_window_valid() then
        -- 窗口已关闭，只重置状态
        M._reset_state()
        return
    end
    
    -- 窗口仍然有效，正常关闭
    M.close()
end

--- 重置状态（内部使用）
function M._reset_state()
    state.current_window_id = nil
    state.current_session_id = nil
    state.current_branch_id = nil
    state.message_buffer = {}
    state.input_buffer = ""
    state.is_sending = false
    state.virtual_input_active = false
    state.virtual_input_buf = nil
    state.virtual_input_win = nil
end

--- 检查并清理无效窗口状态
function M._check_and_cleanup()
    if state.current_window_id and not M.is_window_valid() then
        logger.warn("检测到无效窗口状态，正在清理")
        M._reset_state()
    end
end

--- 初始化自动状态检查
function M._init_auto_check()
    -- 设置定时器，每5秒检查一次窗口状态
    vim.defer_fn(function()
        if state.current_window_id then
            M._check_and_cleanup()
            -- 重新设置定时器
            M._init_auto_check()
        end
    end, 5000)  -- 5秒
end

--- 添加消息
--- @param role string 角色
--- @param content string|table 内容
function M.add_message(role, content)
    if not role or not content then
        return
    end

    -- 添加到本地缓冲区
    table.insert(state.message_buffer, {
        role = role,
        content = content,
        timestamp = os.time()
    })

    -- 保存到消息管理器（如果有当前分支）
    if state.current_branch_id then
        local ok, message_manager = pcall(require, "NeoAI.core.session.message_manager")
        if ok and message_manager then
            local message_id = message_manager.add_message(state.current_branch_id, role, content, {
                timestamp = os.time(),
                session_id = state.current_session_id
            })
            logger.info(string.format("消息已保存到历史: %s (分支: %s)", message_id, state.current_branch_id))
        else
            logger.warn("无法保存消息到历史: 消息管理器不可用")
        end
    else
        logger.warn("无法保存消息到历史: 当前分支ID为空")
    end

    M.render_messages()
end

--- 设置占位文本
--- @param text string 占位文本
function M.set_placeholder_text(text)
    if text and text ~= "" then
        state.placeholder_text = text
        M.render_messages()
    end
end

--- 获取发送状态
--- @return boolean 是否正在发送
function M.is_sending()
    return state.is_sending
end

--- 获取发送统计
--- @return table 发送统计信息
function M.get_send_stats()
    return {
        send_count = state.send_count,
        last_send_time = state.last_send_time,
        is_sending = state.is_sending
    }
end

--- 重置发送统计
function M.reset_send_stats()
    state.send_count = 0
    state.last_send_time = 0
    state.is_sending = false
    M.render_messages()
end

--- 获取当前输入
--- @return string 当前输入
function M.get_current_input()
    return state.input_buffer
end

--- 获取消息列表
--- @return table 消息列表
function M.get_messages()
    return vim.deepcopy(state.message_buffer)
end

--- 获取消息数量
--- @return number 消息数量
function M.get_message_count()
    return #state.message_buffer
end

--- 清空消息
function M.clear_messages()
    state.message_buffer = {}
    M.render_messages()
end

--- 处理发送消息（内部使用）
function M._handle_send()
    -- 如果正在发送中，忽略
    if state.is_sending then
        vim.notify("正在发送消息，请稍候...", vim.log.levels.WARN)
        return
    end

    -- 如果输入为空，且虚拟输入框未激活，打开虚拟输入框
    if state.input_buffer == "" and not state.virtual_input_active then
        M._enter_input_mode()
        return
    end
    
    -- 如果输入为空且虚拟输入框已激活，只是关闭虚拟输入框
    if state.input_buffer == "" and state.virtual_input_active then
        virtual_input.close()
        state.virtual_input_active = false
        return
    end

    -- 如果虚拟输入框激活，先关闭它
    if state.virtual_input_active then
        virtual_input.close()
        state.virtual_input_active = false
    end
    
    -- 设置发送状态
    state.is_sending = true
    state.last_send_time = os.time()
    
    -- 记录日志
    logger.info("开始发送消息: " .. state.input_buffer)
    
    -- 立即更新界面显示发送状态
    M.render_messages()
    
    -- 添加用户消息
    M.add_message("user", state.input_buffer)
    
    -- 增加发送计数
    state.send_count = state.send_count + 1
    
    -- 显示发送通知
    vim.notify("📤 消息已发送: " .. state.input_buffer, vim.log.levels.INFO)
    
    -- 保存消息内容用于AI处理
    local message_content = state.input_buffer
    
    -- 清空输入
    state.input_buffer = ""
    
    -- 调用AI引擎生成响应
    M._generate_ai_response(message_content)
end

--- 生成AI响应
--- @param user_message string 用户消息
function M._generate_ai_response(user_message)
    -- 获取AI引擎实例
    local ai_engine = require("NeoAI.core.ai.ai_engine")
    
    -- 构建消息列表
    local messages = {
        {
            role = "user",
            content = user_message
        }
    }
    
    -- 添加历史消息（如果有）
    for _, msg in ipairs(state.message_buffer) do
        if msg.role == "user" or msg.role == "assistant" then
            table.insert(messages, {
                role = msg.role,
                content = msg.content
            })
        end
    end
    
    -- 调用AI引擎生成响应
    local generation_id = ai_engine.generate_response(messages, {
        stream = true,
        on_chunk = function(chunk)
            -- 处理流式响应
            M._handle_ai_chunk(chunk)
        end,
        on_complete = function(full_response)
            -- 处理完成
            M._handle_ai_complete(full_response)
        end,
        on_error = function(error_msg)
            -- 处理错误
            M._handle_ai_error(error_msg)
        end
    })
    
    -- 记录生成ID
    logger.info("AI响应生成ID: " .. generation_id)
end

--- 处理AI响应数据块
--- @param chunk string 响应数据块
function M._handle_ai_chunk(chunk)
    if not chunk or chunk == "" then
        return
    end
    
    -- 记录日志
    logger.debug("收到AI响应数据块: " .. chunk)
    
    -- 检查是否已有正在构建的AI响应
    if not state.current_ai_response then
        state.current_ai_response = {
            content = "",
            chunks = {},
            start_time = os.time()
        }
        
        -- 添加AI助手消息占位符
        M.add_message("assistant", "🔄 AI正在思考...")
    end
    
    -- 更新当前AI响应
    state.current_ai_response.content = state.current_ai_response.content .. chunk
    table.insert(state.current_ai_response.chunks, chunk)
    
    -- 更新最后一条消息（AI响应）
    if #state.message_buffer > 0 then
        local last_msg = state.message_buffer[#state.message_buffer]
        if last_msg.role == "assistant" then
            -- 更新消息内容
            last_msg.content = state.current_ai_response.content
            
            -- 计算响应时间
            local response_time = os.time() - state.current_ai_response.start_time
            
            -- 添加状态指示器
            local status_indicator = "🔄"
            if response_time > 5 then
                status_indicator = "⏳"  -- 长时间响应
            end
            
            -- 更新显示
            M.render_messages()
            
            -- 可选：显示进度通知
            if #state.current_ai_response.chunks % 3 == 0 then  -- 每3个数据块显示一次
                vim.notify("📝 AI正在回复... (已接收 " .. #state.current_ai_response.chunks .. " 个数据块)", vim.log.levels.INFO)
            end
        end
    end
end

--- 处理AI响应完成
--- @param full_response string 完整响应
function M._handle_ai_complete(full_response)
    -- 发送完成
    state.is_sending = false
    
    -- 记录日志
    logger.info("AI响应完成: " .. full_response)
    
    -- 如果有正在构建的流式响应，更新它
    if state.current_ai_response then
        -- 计算响应时间
        local response_time = os.time() - state.current_ai_response.start_time
        
        -- 更新最后一条消息（确保使用完整响应）
        if #state.message_buffer > 0 then
            local last_msg = state.message_buffer[#state.message_buffer]
            if last_msg.role == "assistant" then
                last_msg.content = full_response
                
                -- 添加响应时间信息
                local time_info = string.format(" (响应时间: %.1fs)", response_time)
                last_msg.metadata = last_msg.metadata or {}
                last_msg.metadata.response_time = response_time
                last_msg.metadata.chunk_count = #state.current_ai_response.chunks
            end
        end
        
        -- 清理当前AI响应
        state.current_ai_response = nil
    else
        -- 如果没有流式响应，直接添加新消息
        M.add_message("assistant", full_response)
    end
    
    -- 更新界面
    M.render_messages()
    
    -- 显示完成通知
    vim.notify("✅ AI响应完成", vim.log.levels.INFO)
end

--- 处理AI响应错误
--- @param error_msg string 错误信息
function M._handle_ai_error(error_msg)
    -- 发送失败
    state.is_sending = false
    
    -- 记录错误日志
    logger.error("AI响应错误: " .. error_msg)
    
    -- 更新界面
    M.render_messages()
    
    -- 显示错误通知
    vim.notify("❌ AI响应失败: " .. error_msg, vim.log.levels.ERROR)
end

--- 进入输入模式（内部使用）
function M._enter_input_mode()
    -- 使用安全检查
    local available, err = M.is_available()
    if not available then
        vim.notify(err or "无法进入输入模式", vim.log.levels.ERROR)
        return
    end
    
    -- 如果虚拟输入框已激活，直接返回
    if state.virtual_input_active then
        return
    end
    
    -- 获取窗口句柄（数字）
    local window_info = window_manager.get_window_info(state.current_window_id)
    if not window_info or not window_info.win then
        vim.notify("无法获取窗口句柄", vim.log.levels.ERROR)
        return
    end
    
    -- 打开虚拟输入框，传递窗口句柄（数字）
    local success = virtual_input.open(window_info.win, {
        content = state.input_buffer,
        placeholder = state.placeholder_text,
        on_submit = function(content)
            state.input_buffer = content
            state.virtual_input_active = false
            M.render_messages()
            -- 自动发送消息
            M._handle_send()
        end,
        on_cancel = function()
            state.virtual_input_active = false
            -- 取消时不清空输入内容，保留用户输入
            M.render_messages()
        end,
        on_change = function(content)
            state.input_buffer = content
            -- 现在render_messages会检查虚拟输入框状态，不会在激活时修改缓冲区
            M.render_messages()
        end
    })
    
    if success then
        state.virtual_input_active = true
        state.virtual_input_buf = virtual_input.get_buffer_id()
        state.virtual_input_win = virtual_input.get_window_id()
        M.render_messages()
        
        -- 自动获取焦点到虚拟输入框
        vim.defer_fn(function()
            if state.virtual_input_win and vim.api.nvim_win_is_valid(state.virtual_input_win) then
                vim.api.nvim_set_current_win(state.virtual_input_win)
                vim.cmd("startinsert")
            end
        end, 50)
    else
        vim.notify("无法打开虚拟输入框", vim.log.levels.ERROR)
    end
end

--- 设置输入区域（内部使用）
function M._setup_input_area()
    -- 虚拟输入组件已在initialize函数中初始化
    -- 这里不需要重复初始化
end

--- 加载消息（内部使用）
function M._load_messages()
    -- 从会话管理器加载消息
    local ok, session_manager = pcall(require, "NeoAI.core.session.session_manager")
    if not ok then
        state.message_buffer = {}
        vim.notify("无法加载会话管理器: " .. session_manager, vim.log.levels.WARN)
        return
    end
    
    local ok2, message_manager = pcall(require, "NeoAI.core.session.message_manager")
    if not ok2 then
        state.message_buffer = {}
        vim.notify("无法加载消息管理器: " .. message_manager, vim.log.levels.WARN)
        return
    end
    
    -- 确保有当前会话
    local session_id = state.current_session_id
    local branch_id = state.current_branch_id
    
    if not session_id or not branch_id then
        state.message_buffer = {}
        vim.notify("会话ID或分支ID为空", vim.log.levels.WARN)
        return
    end
    
    -- 获取消息
    local messages = message_manager.get_messages(branch_id)
    
    -- 转换为聊天窗口格式
    state.message_buffer = {}
    for _, msg in ipairs(messages) do
        table.insert(state.message_buffer, {
            role = msg.role,
            content = msg.content,
            metadata = msg.metadata
        })
    end
    
    -- 调试信息
    vim.notify(string.format("已加载 %d 条消息 (会话: %s, 分支: %s)", 
        #state.message_buffer, session_id, branch_id), vim.log.levels.INFO)
end

--- 滚动到底部（内部使用）
function M._scroll_to_bottom()
    if not state.current_window_id then
        return
    end

    local win = window_manager.get_window_win(state.current_window_id)
    if not win then
        return
    end

    local buf = window_manager.get_window_buf(state.current_window_id)
    if not buf then
        return
    end

    local line_count = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_win_set_cursor(win, { line_count, 0 })
end

--- 编辑消息（内部使用）
function M._edit_message()
    if not state.current_window_id then
        return
    end
    
    vim.notify("编辑消息功能", vim.log.levels.INFO)
    -- 这里实现编辑消息的逻辑
end

--- 删除消息（内部使用）
function M._delete_message()
    if not state.current_window_id then
        return
    end
    
    vim.notify("删除消息功能", vim.log.levels.INFO)
    -- 这里实现删除消息的逻辑
end

--- 向上滚动（内部使用）
function M._scroll_up()
    if not state.current_window_id then
        return
    end
    
    local win = window_manager.get_window_win(state.current_window_id)
    if not win then
        return
    end
    
    local current_line = vim.api.nvim_win_get_cursor(win)[1]
    if current_line > 1 then
        vim.api.nvim_win_set_cursor(win, { current_line - 1, 0 })
    end
end

--- 向下滚动（内部使用）
function M._scroll_down()
    if not state.current_window_id then
        return
    end
    
    local win = window_manager.get_window_win(state.current_window_id)
    if not win then
        return
    end
    
    local buf = window_manager.get_window_buf(state.current_window_id)
    if not buf then
        return
    end
    
    local line_count = vim.api.nvim_buf_line_count(buf)
    local current_line = vim.api.nvim_win_get_cursor(win)[1]
    if current_line < line_count then
        vim.api.nvim_win_set_cursor(win, { current_line + 1, 0 })
    end
end

--- 切换思考过程显示（内部使用）
function M._toggle_reasoning()
    vim.notify("切换思考过程显示功能", vim.log.levels.INFO)
    -- 这里实现切换思考过程显示的逻辑
end

--- 获取输入内容
--- @return string|nil 输入内容
function M.get_input_content()
    if not state.initialized then
        return nil
    end
    
    -- 如果虚拟输入框激活，从虚拟输入框获取内容
    if state.virtual_input_active then
        return virtual_input.get_content()
    end
    
    return state.input_buffer
end

--- 发送消息
--- @param content string 消息内容
--- @return boolean, string|nil 是否成功，错误信息
function M.send_message(content)
    if not state.initialized then
        return false, "聊天窗口未初始化"
    end
    
    -- 检查窗口是否可用
    local available, err = M.is_available()
    if not available then
        return false, err
    end
    
    -- 验证消息内容
    if not content or content == "" then
        return false, "消息内容不能为空"
    end
    
    -- 设置输入内容
    state.input_buffer = content
    
    -- 调用内部发送处理
    M._handle_send()
    
    return true, "消息已发送"
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
        M.set_keymaps()
        M.render_messages()
    end
end

--- 获取聊天窗口缓冲区句柄
--- @return number|nil 缓冲区句柄
function M.get_bufnr()
    if not state.current_window_id then
        return nil
    end
    
    return window_manager.get_window_buf(state.current_window_id)
end

--- 获取聊天窗口窗口句柄
--- @return number|nil 窗口句柄
function M.get_winid()
    if not state.current_window_id then
        return nil
    end
    
    return window_manager.get_window_win(state.current_window_id)
end

--- 刷新聊天窗口
--- @return boolean 是否成功
function M.refresh()
    if not state.initialized then
        return false
    end
    
    if not state.current_window_id then
        return false
    end
    
    -- 重新渲染消息
    M.render_messages()
    return true
end

return M