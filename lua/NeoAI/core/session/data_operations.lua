local M = {}

local file_utils = require("NeoAI.utils.file_utils")
local branch_manager = require("NeoAI.core.session.branch_manager")
local message_manager = require("NeoAI.core.session.message_manager")

-- 模块状态
local state = {
    initialized = false,
    event_bus = nil,
    config = nil
}

--- 初始化数据操作模块
--- @param options table 选项
function M.initialize(options)
    if state.initialized then
        return
    end

    state.event_bus = options.event_bus
    state.config = options.config or {}
    state.initialized = true
end

--- 导出会话
--- @param session_id string 会话ID
--- @param format string 格式（json/markdown）
--- @return string 导出的数据
function M.export_session(session_id, format)
    if not state.initialized then
        error("Data operations not initialized")
    end

    format = format or "json"

    -- 获取会话管理器
    local session_manager = require("NeoAI.core.session.session_manager")
    local session = session_manager.get_session(session_id)
    if not session then
        error("Session not found: " .. session_id)
    end

    -- 直接使用导入的分支管理器和消息管理器模块

    -- 构建导出数据
    local export_data = {
        session = session,
        branches = {},
        messages = {}
    }

    -- 收集分支数据
    for branch_id, _ in pairs(session.branches) do
        local branch = branch_manager.get_branch(branch_id)
        if branch then
            export_data.branches[branch_id] = branch

            -- 收集消息数据
            local messages = message_manager.get_messages(branch_id)
            for _, msg in ipairs(messages) do
                export_data.messages[msg.id] = msg
            end
        end
    end

    -- 根据格式转换
    if format == "json" then
        return vim.json.encode(export_data)
    elseif format == "markdown" then
        return M._export_to_markdown(export_data)
    else
        error("Unsupported format: " .. format)
    end
end

--- 导入会话
--- @param data string 导入的数据
--- @param format string 格式（json/markdown）
--- @return string 会话ID
function M.import_session(data, format)
    if not state.initialized then
        error("Data operations not initialized")
    end

    format = format or "json"

    local import_data
    if format == "json" then
        import_data = vim.json.decode(data)
    else
        error("Unsupported format for import: " .. format)
    end

    if not import_data or not import_data.session then
        error("Invalid import data")
    end

    -- 获取会话管理器
    local session_manager = require("NeoAI.core.session.session_manager")
    local branch_manager = session_manager.get_branch_manager()
    local message_manager = session_manager.get_message_manager()

    -- 创建新会话
    local session_id = session_manager.create_session(import_data.session.name .. " (imported)")

    -- 导入分支和消息
    for branch_id, branch_data in pairs(import_data.branches or {}) do
        -- 创建分支
        local new_branch_id = branch_manager.create_branch(branch_data.parent_id, branch_data.name)

        -- 导入消息
        for msg_id, msg_data in pairs(import_data.messages or {}) do
            if msg_data.branch_id == branch_id then
                message_manager.add_message(
                    new_branch_id,
                    msg_data.role,
                    msg_data.content,
                    msg_data.metadata
                )
            end
        end
    end

    return session_id
end

--- 备份会话
function M.backup_sessions()
    if not state.initialized then
        error("Data operations not initialized")
    end

    if not state.config.save_path then
        error("Backup path not configured")
    end

    -- 获取会话管理器
    local session_manager = require("NeoAI.core.session.session_manager")
    local sessions = session_manager.list_sessions()

    local backup_data = {
        timestamp = os.time(),
        sessions = {}
    }

    -- 导出所有会话
    for _, session_info in ipairs(sessions) do
        local session_data = M.export_session(session_info.id, "json")
        backup_data.sessions[session_info.id] = {
            info = session_info,
            data = session_data
        }
    end

    -- 保存备份文件
    local backup_dir = state.config.save_path .. "/backups"
    file_utils.mkdir(backup_dir)

    local backup_file = backup_dir .. "/backup_" .. os.date("%Y%m%d_%H%M%S") .. ".json"
    file_utils.write_file(backup_file, vim.json.encode(backup_data))

    -- 触发事件
    if state.event_bus then
        state.event_bus.emit("backup_created", backup_file, #sessions)
    end

    return backup_file
end

--- 恢复备份
--- @param backup_id string 备份ID或文件路径
--- @return table 恢复的会话列表
function M.restore_backup(backup_id)
    if not state.initialized then
        error("Data operations not initialized")
    end

    -- 读取备份文件
    local backup_file = backup_id
    if not file_utils.exists(backup_file) then
        -- 尝试在备份目录中查找
        local backup_dir = state.config.save_path .. "/backups"
        backup_file = backup_dir .. "/" .. backup_id
        if not file_utils.exists(backup_file) then
            error("Backup not found: " .. backup_id)
        end
    end

    local backup_content = file_utils.read_file(backup_file)
    local backup_data = vim.json.decode(backup_content)

    if not backup_data or not backup_data.sessions then
        error("Invalid backup file")
    end

    local restored_sessions = {}

    -- 恢复每个会话
    for session_id, session_backup in pairs(backup_data.sessions) do
        local new_session_id = M.import_session(session_backup.data, "json")
        table.insert(restored_sessions, {
            original_id = session_id,
            new_id = new_session_id,
            name = session_backup.info.name
        })
    end

    -- 触发事件
    if state.event_bus then
        state.event_bus.emit("backup_restored", backup_file, #restored_sessions)
    end

    return restored_sessions
end

--- 导出为Markdown（内部使用）
--- @param export_data table 导出数据
--- @return string Markdown格式
function M._export_to_markdown(export_data)
    local lines = {}

    -- 会话标题
    table.insert(lines, "# " .. export_data.session.name)
    table.insert(lines, "")
    table.insert(lines, "**Created:** " .. os.date("%Y-%m-%d %H:%M:%S", export_data.session.created_at))
    table.insert(lines, "**Updated:** " .. os.date("%Y-%m-%d %H:%M:%S", export_data.session.updated_at))
    table.insert(lines, "")

    -- 分支和消息
    for branch_id, branch in pairs(export_data.branches) do
        table.insert(lines, "## " .. branch.name)
        table.insert(lines, "")

        local branch_messages = {}
        for _, msg in pairs(export_data.messages) do
            if msg.branch_id == branch_id then
                table.insert(branch_messages, msg)
            end
        end

        -- 按时间排序
        table.sort(branch_messages, function(a, b)
            return a.created_at < b.created_at
        end)

        -- 输出消息
        for _, msg in ipairs(branch_messages) do
            local role_icon = msg.role == "user" and "👤" or msg.role == "assistant" and "🤖" or "🛠️"
            table.insert(lines, "### " .. role_icon .. " " .. msg.role:upper())
            table.insert(lines, "")
            
            if type(msg.content) == "table" then
                table.insert(lines, "```json")
                table.insert(lines, vim.json.encode(msg.content))
                table.insert(lines, "```")
            else
                table.insert(lines, msg.content)
            end
            
            table.insert(lines, "")
            table.insert(lines, "---")
            table.insert(lines, "")
        end
    end

    return table.concat(lines, "\n")
end

--- 保存会话到文件
--- @param session_id string 会话ID
--- @param filepath string 文件路径
--- @return boolean 是否保存成功
function M.save_session(session_id, filepath)
    if not state.initialized then
        error("Data operations not initialized")
    end
    
    local export_data = M.export_session(session_id, "json")
    if not export_data then
        return false
    end
    
    filepath = filepath or state.config.save_path .. "/" .. session_id .. ".json"
    
    -- 确保目录存在
    local dir = filepath:match("(.*)/")
    if dir then
        file_utils.mkdir(dir)
    end
    
    local success = file_utils.write_file(filepath, vim.json.encode(export_data))
    
    if success and state.event_bus then
        state.event_bus.emit("session_saved", session_id, filepath)
    end
    
    return success
end

--- 从文件加载会话
--- @param filepath string 文件路径
--- @return string|nil 新会话ID
function M.load_session(filepath)
    if not state.initialized then
        error("Data operations not initialized")
    end
    
    if not file_utils.exists(filepath) then
        error("File not found: " .. filepath)
    end
    
    local content = file_utils.read_file(filepath)
    if not content then
        error("Failed to read file: " .. filepath)
    end
    
    local import_data = vim.json.decode(content)
    if not import_data then
        error("Invalid JSON in file: " .. filepath)
    end
    
    local new_session_id = M.import_session(import_data, "json")
    
    if new_session_id and state.event_bus then
        state.event_bus.emit("session_loaded", new_session_id, filepath)
    end
    
    return new_session_id
end

return M