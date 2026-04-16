local M = {}

-- 模块状态
local state = {
    initialized = false,
    config = nil
}

--- 初始化聊天界面处理器
--- @param config table 配置
function M.initialize(config)
    if state.initialized then
        return
    end

    state.config = config or {}
    state.initialized = true
end

--- 处理回车（发送消息）
function M.handle_enter()
    if not state.initialized then
        return
    end

    vim.notify("发送消息", vim.log.levels.INFO)
    
    -- 这里应该获取当前输入内容并发送
    -- 然后清空输入框
end

--- 处理Ctrl+S（发送消息）
function M.handle_ctrl_s()
    if not state.initialized then
        return
    end

    vim.notify("发送消息 (Ctrl+S)", vim.log.levels.INFO)
    
    -- 与回车键功能相同
    M.handle_enter()
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

--- 更新配置
--- @param new_config table 新配置
function M.update_config(new_config)
    if not state.initialized then
        return
    end

    state.config = vim.tbl_extend("force", state.config, new_config or {})
end

return M