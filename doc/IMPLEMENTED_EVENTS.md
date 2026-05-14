# NeoAI 已实现的事件系统

## 概述

NeoAI 已经直接使用 Neovim 原生事件系统为所有关键的异步操作添加了事件触发。以下是已经实现的事件列表。

## 核心事件

### AI 引擎 (`core/ai/ai_engine.lua`)

| 事件 | 数据格式 | 描述 |
|------|----------|------|
| `NeoAI:generation_started` | `{generation_id, formatted_messages}` | AI生成开始 |
| `NeoAI:generation_completed` | `{generation_id, response}` | AI生成完成 |
| `NeoAI:generation_error` | `{generation_id, error_msg}` | AI生成错误 |
| `NeoAI:generation_cancelled` | `{generation_id}` | AI生成取消 |
| `NeoAI:reasoning_content` | `{reasoning_content}` | 推理内容到达 |
| `NeoAI:stream_chunk` | `{generation_id, cleaned_chunk}` | 流式数据块 |
| `NeoAI:stream_started` | `{generation_id, formatted_messages}` | 流式处理开始 |

### 工具编排器 (`core/ai/tool_orchestrator.lua`)

| 事件 | 数据格式 | 描述 |
|------|----------|------|
| `NeoAI:tool_loop_started` | `{current_messages}` | 工具循环开始 |
| `NeoAI:tool_loop_finished` | `{final_result, iteration_count}` | 工具循环结束 |
| `NeoAI:tool_execution_started` | `{tool_call}` | 工具执行开始 |
| `NeoAI:tool_execution_completed` | `{tool_call, formatted_result}` | 工具执行完成 |
| `NeoAI:tool_error` | `{tool_call, error_msg}` | 工具执行错误 |

### 工具执行器 (`tools/tool_executor.lua`)

| 事件 | 数据格式 | 描述 |
|------|----------|------|
| `NeoAI:tool_execution_started` | `{tool_name, args, start_time}` | 工具执行开始 |
| `NeoAI:tool_execution_completed` | `{tool_name, args, result, duration}` | 工具执行完成 |
| `NeoAI:tool_execution_error` | `{tool_name, args, error_msg, duration}` | 工具执行错误 |

### 会话管理器 (`core/session/session_manager.lua`)

| 事件 | 数据格式 | 描述 |
|------|----------|------|
| `NeoAI:session_created` | `{session_id, session}` | 会话创建 |
| `NeoAI:session_reused` | `{session_id, session}` | 会话重用 |

### 消息管理器 (`core/session/message_manager.lua`)

| 事件 | 数据格式 | 描述 |
|------|----------|------|
| `NeoAI:message_added` | `{message_id, message}` | 消息添加 |
| `NeoAI:message_edited` | `{message_id, old_content, new_content}` | 消息编辑 |
| `NeoAI:message_deleted` | `{message_id, message}` | 消息删除 |
| `NeoAI:message_updated` | `{message_id, message}` | 消息更新 |
| `NeoAI:messages_cleared` | `{branch_id, deleted_ids}` | 消息清空 |

### 响应构建器 (`core/ai/response_builder.lua`)

| 事件 | 数据格式 | 描述 |
|------|----------|------|
| `NeoAI:messages_built` | `{messages, history_count}` | 消息构建完成 |

### 聊天处理器 (`ui/handlers/chat_handlers.lua`)

| 事件 | 数据格式 | 描述 |
|------|----------|------|
| `NeoAI:message_sent` | `{session_id, branch_id, original_content, formatted_content, message, window_id, timestamp}` | 消息发送 |
| `NeoAI:formatted_message_sent` | `{session_id, branch_id, original_content, formatted_content, message, window_id, timestamp}` | 格式化消息发送 |

### 窗口管理器 (`ui/window/window_manager.lua`)

| 事件 | 数据格式 | 描述 |
|------|----------|------|
| `NeoAI:{type}_window_opened` | `{window_id, window_type, options}` | 窗口打开 |
| `NeoAI:{type}_window_closed` | `{window_id, window_type}` | 窗口关闭 |

*注：`{type}` 可以是 `chat`, `tree`, `reasoning`, `custom` 等*

### 流式处理器 (`core/ai/stream_processor.lua`)

| 事件 | 数据格式 | 描述 |
|------|----------|------|
| `NeoAI:stream_completed` | `{session_id}` | 流式处理完成 |

## 使用示例

### 监听 AI 生成事件

```lua
-- 监听 AI 生成开始
vim.api.nvim_create_autocmd("User", {
    pattern = "NeoAI:generation_started",
    callback = function(args)
        local generation_id = args.data[1]
        local messages = args.data[2]
        print("AI 生成开始:", generation_id)
    end
})

-- 监听 AI 生成完成
vim.api.nvim_create_autocmd("User", {
    pattern = "NeoAI:generation_completed",
    callback = function(args)
        local generation_id = args.data[1]
        local response = args.data[2]
        print("AI 生成完成:", generation_id)
        print("响应:", string.sub(response, 1, 100))
    end
})
```

### 监听工具执行事件

```lua
-- 监听工具执行
vim.api.nvim_create_autocmd("User", {
    pattern = "NeoAI:tool_execution_started",
    callback = function(args)
        local tool_name = args.data[1]
        local tool_args = args.data[2]
        print("工具执行开始:", tool_name)
    end
})

vim.api.nvim_create_autocmd("User", {
    pattern = "NeoAI:tool_execution_completed",
    callback = function(args)
        local tool_name = args.data[1]
        local result = args.data[3]
        print("工具执行完成:", tool_name)
    end
})
```

### 监听消息事件

```lua
-- 监听消息添加
vim.api.nvim_create_autocmd("User", {
    pattern = "NeoAI:message_added",
    callback = function(args)
        local message_id = args.data[1]
        local message = args.data[2]
        print("新消息:", message_id, message.role, message.content)
    end
})
```

### 监听窗口事件

```lua
-- 监听聊天窗口打开
vim.api.nvim_create_autocmd("User", {
    pattern = "NeoAI:chat_window_opened",
    callback = function(args)
        local window_id = args.data[1]
        print("聊天窗口已打开:", window_id)
    end
})

-- 监听树窗口关闭
vim.api.nvim_create_autocmd("User", {
    pattern = "NeoAI:tree_window_closed",
    callback = function(args)
        local window_id = args.data[1]
        print("树窗口已关闭:", window_id)
    end
})
```

## 事件触发示例

### 在代码中触发事件

```lua
-- 触发 AI 生成开始事件
function start_generation(messages)
    local generation_id = "gen_" .. os.time()
    
    vim.api.nvim_exec_autocmds("User", {
        pattern = "NeoAI:generation_started",
        data = {generation_id, messages}
    })
    
    return generation_id
end

-- 触发工具执行事件
function execute_tool(tool_name, args)
    local start_time = os.time()
    
    vim.api.nvim_exec_autocmds("User", {
        pattern = "NeoAI:tool_execution_started",
        data = {tool_name, args, start_time}
    })
    
    -- ... 执行工具 ...
    
    local end_time = os.time()
    local duration = end_time - start_time
    
    vim.api.nvim_exec_autocmds("User", {
        pattern = "NeoAI:tool_execution_completed",
        data = {tool_name, args, result, duration}
    })
    
    return result
end
```

## 最佳实践

1. **使用事件常量**：从 `NeoAI.core.event_constants` 获取事件名称
2. **及时清理监听器**：不需要时使用 `nvim_del_autocmd` 移除
3. **错误处理**：在事件回调中添加 `pcall` 包装
4. **避免阻塞**：事件回调中不要执行耗时操作
5. **数据格式一致**：使用数组传递数据，保持顺序

## 调试技巧

```lua
-- 监听所有 NeoAI 事件
vim.api.nvim_create_autocmd("User", {
    pattern = "NeoAI:*",
    callback = function(args)
        print("[事件调试]", args.match, "数据:", vim.inspect(args.data))
    end
})

-- 查看已注册的事件监听器
local autocmds = vim.api.nvim_get_autocmds({
    event = "User",
    pattern = "NeoAI:*"
})

for _, autocmd in ipairs(autocmds) do
    print("事件:", autocmd.pattern, "ID:", autocmd.id)
end
```

## 注意事项

1. 所有事件都是 `User` 类型的自动命令
2. 事件数据通过 `args.data` 访问，是一个 Lua 数组
3. 同一个事件可以有多个监听器
4. 监听器按照注册顺序执行
5. 事件触发是同步的，回调会立即执行