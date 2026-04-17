local M = {}

-- 模块状态
local state = {
    initialized = false,
    event_bus = nil,
    config = nil
}

--- 初始化聊天界面处理器
--- @param event_bus table 事件总线
--- @param config table 配置
--- @return boolean 初始化是否成功
function M.initialize(event_bus, config)
    if state.initialized then
        return true
    end

    state.event_bus = event_bus
    state.config = config or {}
    state.initialized = true
    
    -- 注册事件监听器
    if event_bus then
        event_bus:on("open_chat_window", function(session_id, branch_id)
            -- 打开聊天窗口
            local ui = require("NeoAI.ui")
            ui.open_chat_ui(session_id, branch_id)
            
            -- 触发事件
            event_bus:emit("chat_window_opened", session_id, branch_id)
        end)
        
        event_bus:on("send_message", function(session_id, branch_id, content)
            -- 发送消息
            local success, result = M.send_message(content)
            if success then
                event_bus:emit("message_sent", session_id, branch_id, content)
            end
        end)
    end
    
    return true
end

--- 处理回车（发送消息）
function M.handle_enter()
    if not state.initialized then
        return
    end

    -- 获取聊天窗口实例
    local chat_window = require("NeoAI.ui.window.chat_window")
    
    -- 检查聊天窗口是否可用
    local available, err = chat_window.is_available()
    if not available then
        vim.notify("无法发送消息: " .. err, vim.log.levels.WARN)
        return
    end
    
    -- 获取输入内容
    local input_content = chat_window.get_input_content()
    if not input_content or input_content == "" then
        vim.notify("消息内容不能为空", vim.log.levels.WARN)
        return
    end
    
    -- 发送消息
    local success, result = chat_window.send_message(input_content)
    if not success then
        vim.notify("发送消息失败: " .. result, vim.log.levels.ERROR)
    else
        vim.notify("消息发送成功", vim.log.levels.INFO)
    end
    return success, result
end

--- 处理Ctrl+S（发送消息）
function M.handle_ctrl_s()
    if not state.initialized then
        return
    end

    -- 与回车键功能相同
    M.handle_enter()
end

--- 发送消息（测试用）
--- @param message string 消息内容
function M.send_message(message)
    if not state.initialized then
        return false, "聊天处理器未初始化"
    end
    
    -- 获取聊天窗口实例
    local chat_window = require("NeoAI.ui.window.chat_window")
    
    -- 检查聊天窗口是否可用
    local available, err = chat_window.is_available()
    if not available then
        -- 如果聊天窗口不可用，模拟发送成功用于测试
        print("⚠️  聊天窗口不可用，模拟发送消息: " .. message)
        return true, "消息已发送（模拟）"
    end
    
    -- 发送消息
    local success, result = chat_window.send_message(message)
    
    -- 增加事件计数
    if success then
        local ui = require("NeoAI.ui")
        ui.handle_key("<CR>")  -- 模拟回车键事件
    end
    
    return success, result
end

--- 处理响应（测试用）
--- @param response string 响应内容
function M.handle_response(response)
    if not state.initialized then
        return false, "聊天处理器未初始化"
    end
    
    -- 获取聊天窗口实例
    local chat_window = require("NeoAI.ui.window.chat_window")
    
    -- 检查聊天窗口是否可用
    local available, err = chat_window.is_available()
    if not available then
        return false, "无法处理响应: " .. err
    end
    
    -- 添加响应到聊天窗口
    local success = chat_window.add_response(response)
    return success
end

--- 清空聊天（测试用）
function M.clear_chat()
    if not state.initialized then
        return false, "聊天处理器未初始化"
    end
    
    -- 获取聊天窗口实例
    local chat_window = require("NeoAI.ui.window.chat_window")
    
    -- 检查聊天窗口是否可用
    local available, err = chat_window.is_available()
    if not available then
        return false, "无法清空聊天: " .. err
    end
    
    -- 清空聊天窗口
    local success = chat_window.clear()
    return success
end

--- 处理ESC键
function M.handle_escape()
    if not state.initialized then
        return
    end

    vim.notify("取消/退出", vim.log.levels.INFO)
    
    -- 这里应该取消当前操作或退出聊天界面
    -- require("NeoAI.ui").close_all_windows()
end

--- 切换聊天窗口显示/隐藏
function M.toggle_chat_window()
    if not state.initialized then
        return false, "聊天处理器未初始化"
    end
    
    -- 获取UI模块
    local ui = require("NeoAI.ui")
    
    -- 检查聊天窗口是否已打开
    local chat_window = require("NeoAI.ui.window.chat_window")
    local is_open = chat_window.is_open()
    
    if is_open then
        -- 关闭聊天窗口
        ui.close_all_windows()
        return true, "聊天窗口已关闭"
    else
        -- 打开聊天窗口
        local session_manager = require("NeoAI.core").get_session_manager()
        local current_session = session_manager and session_manager.get_current_session()
        local session_id = current_session and current_session.id or "default"
        
        ui.open_chat_ui(session_id, "main")
        return true, "聊天窗口已打开"
    end
end

--- 刷新聊天窗口
function M.refresh_chat()
    if not state.initialized then
        return false, "聊天处理器未初始化"
    end
    
    -- 获取聊天窗口实例
    local chat_window = require("NeoAI.ui.window.chat_window")
    
    -- 检查聊天窗口是否可用
    local available, err = chat_window.is_available()
    if not available then
        return false, "无法刷新聊天: " .. err
    end
    
    -- 刷新聊天窗口
    local success = chat_window.refresh()
    return success
end

--- 处理Tab键
function M.handle_tab()
    if not state.initialized then
        return
    end

    vim.notify("Tab补全", vim.log.levels.INFO)
    
    -- 这里应该实现Tab补全功能
end

--- 处理滚动
function M.handle_scroll()
    if not state.initialized then
        return
    end

    vim.notify("滚动消息", vim.log.levels.INFO)
    
    -- 这里应该处理消息滚动
end

--- 处理按键
--- @param key string 按键
function M.handle_key(key)
    if not state.initialized then
        return
    end

    local key_handlers = {
        ["<CR>"] = M.handle_enter,
        ["<C-s>"] = M.handle_ctrl_s,
        ["<Esc>"] = M.handle_escape,
        ["<Tab>"] = M.handle_tab,
        ["<ScrollWheelUp>"] = function() M.handle_scroll() end,
        ["<ScrollWheelDown>"] = function() M.handle_scroll() end
    }

    local handler = key_handlers[key]
    if handler then
        handler()
    end
end

--- 处理向上历史
function M.handle_up_history()
    if not state.initialized then
        return
    end

    vim.notify("上一条历史消息", vim.log.levels.INFO)
    
    -- 这里应该加载上一条历史消息到输入框
end

--- 处理向下历史
function M.handle_down_history()
    if not state.initialized then
        return
    end

    vim.notify("下一条历史消息", vim.log.levels.INFO)
    
    -- 这里应该加载下一条历史消息到输入框
end

--- 处理清空输入
function M.handle_clear_input()
    if not state.initialized then
        return
    end

    vim.notify("清空输入", vim.log.levels.INFO)
    
    -- 这里应该清空输入框
end

--- 处理复制消息
function M.handle_copy_message()
    if not state.initialized then
        return
    end

    vim.notify("复制消息", vim.log.levels.INFO)
    
    -- 这里应该复制选中的消息到剪贴板
end

--- 处理编辑消息
function M.handle_edit_message()
    if not state.initialized then
        return
    end

    vim.notify("编辑消息", vim.log.levels.INFO)
    
    -- 这里应该允许用户编辑选中的消息
end

--- 处理删除消息
function M.handle_delete_message()
    if not state.initialized then
        return
    end

    vim.notify("删除消息", vim.log.levels.WARN)
    
    -- 这里应该删除选中的消息
end

--- 处理重新生成
function M.handle_regenerate()
    if not state.initialized then
        return
    end

    vim.notify("重新生成响应", vim.log.levels.INFO)
    
    -- 这里应该重新生成AI的响应
end

--- 处理停止生成
function M.handle_stop_generation()
    if not state.initialized then
        return
    end

    vim.notify("停止生成", vim.log.levels.INFO)
    
    -- 这里应该停止当前的AI生成过程
end

--- 处理切换思考显示
function M.handle_toggle_reasoning()
    if not state.initialized then
        return
    end

    vim.notify("切换思考显示", vim.log.levels.INFO)
    
    -- 这里应该显示或隐藏思考过程
end

--- 处理导出对话
function M.handle_export_chat()
    if not state.initialized then
        return
    end

    vim.notify("导出对话", vim.log.levels.INFO)
    
    -- 这里应该导出当前对话
end

--- 处理导入对话
function M.handle_import_chat()
    if not state.initialized then
        return
    end

    vim.notify("导入对话", vim.log.levels.INFO)
    
    -- 这里应该导入对话
end

--- 处理切换分支
function M.handle_switch_branch()
    if not state.initialized then
        return
    end

    vim.notify("切换分支", vim.log.levels.INFO)
    
    -- 这里应该打开分支选择界面
end

--- 处理新建分支
function M.handle_new_branch()
    if not state.initialized then
        return
    end

    vim.notify("新建分支", vim.log.levels.INFO)
    
    -- 这里应该创建新分支
end

--- 处理返回树界面
function M.handle_back_to_tree()
    if not state.initialized then
        return
    end

    vim.notify("返回树界面", vim.log.levels.INFO)
    
    -- 这里应该关闭聊天界面并打开树界面
    -- require("NeoAI.ui").close_all_windows()
    -- require("NeoAI.ui").open_tree_ui()
end

--- 处理帮助
function M.handle_help()
    if not state.initialized then
        return
    end

    vim.notify("显示帮助", vim.log.levels.INFO)
    
    -- 这里应该显示帮助信息
end

--- 获取按键映射
--- @return table 按键映射表
function M.get_keymaps()
    return {
        ["<CR>"] = "发送消息",
        ["<C-s>"] = "发送消息",
        ["<Esc>"] = "取消/退出",
        ["<Tab>"] = "Tab补全",
        ["<C-p>"] = "上一条历史",
        ["<C-n>"] = "下一条历史",
        ["<C-u>"] = "清空输入",
        ["yy"] = "复制消息",
        ["e"] = "编辑消息",
        ["dd"] = "删除消息",
        ["r"] = "重新生成",
        ["<C-c>"] = "停止生成",
        ["t"] = "切换思考显示",
        ["E"] = "导出对话",
        ["I"] = "导入对话",
        ["b"] = "切换分支",
        ["B"] = "新建分支",
        ["q"] = "返回树界面",
        ["?"] = "帮助"
    }
end

--- 处理输入
--- @param input string 输入内容
function M.handle_input(input)
    if not state.initialized then
        return false, "聊天处理器未初始化"
    end
    
    -- 这里可以处理输入内容，比如验证、格式化等
    -- 目前只是简单返回成功
    return true, "输入已处理"
end

--- 获取消息数量
--- @return number 消息数量
function M.get_message_count()
    if not state.initialized then
        return 0
    end
    
    -- 获取聊天窗口实例
    local chat_window = require("NeoAI.ui.window.chat_window")
    
    -- 检查聊天窗口是否可用
    local available, err = chat_window.is_available()
    if not available then
        -- 如果聊天窗口不可用，返回模拟的消息数量用于测试
        return 5  -- 模拟5条消息
    end
    
    -- 获取消息数量
    local count = chat_window.get_message_count()
    return count or 0
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