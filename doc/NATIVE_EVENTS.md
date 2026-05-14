# NeoAI 原生事件系统

## 概述

NeoAI 直接使用 Neovim 原生事件系统，通过 `nvim_exec_autocmds` 触发事件，通过 `nvim_create_autocmd` 监听事件。所有事件都是 `User` 类型的自动命令。

## 事件常量

事件常量定义在 `NeoAI.core.event_constants` 模块中：

```lua
local events = require("NeoAI.core.event_constants")
print(events.GENERATION_STARTED)  -- 输出: "NeoAI:generation_started"
```

## 基本用法

### 触发事件

```lua
-- 触发 AI 生成开始事件
vim.api.nvim_exec_autocmds("User", {
    pattern = "NeoAI:generation_started",
    data = {generation_id, formatted_messages}
})

-- 触发消息添加事件
vim.api.nvim_exec_autocmds("User", {
    pattern = "NeoAI:message_added",
    data = {message_id, message}
})
```

### 监听事件

```lua
-- 监听 AI 生成开始事件
vim.api.nvim_create_autocmd("User", {
    pattern = "NeoAI:generation_started",
    callback = function(args)
        local generation_id = args.data[1]
        local formatted_messages = args.data[2]
        print("AI 生成开始:", generation_id)
    end
})

-- 监听消息添加事件
vim.api.nvim_create_autocmd("User", {
    pattern = "NeoAI:message_added",
    callback = function(args)
        local message_id = args.data[1]
        local message = args.data[2]
        print("新消息:", message_id, message.content)
    end
})
```

## 事件列表

### AI 生成事件
- `NeoAI:generation_started` - AI生成开始
  - 数据: `{generation_id, formatted_messages}`
- `NeoAI:generation_completed` - AI生成完成
  - 数据: `{generation_id, response}`
- `NeoAI:generation_error` - AI生成错误
  - 数据: `{generation_id, error_msg}`
- `NeoAI:generation_cancelled` - AI生成取消

### 流式处理事件
- `NeoAI:stream_chunk` - 流式数据块到达
  - 数据: `{chunk}`
- `NeoAI:stream_started` - 流式处理开始
  - 数据: `{generation_id, formatted_messages}`
- `NeoAI:stream_completed` - 流式处理完成
  - 数据: `{session_id}`
- `NeoAI:stream_error` - 流式处理错误

### 工具相关事件
- `NeoAI:tool_loop_started` - 工具循环开始
  - 数据: `{current_messages}`
- `NeoAI:tool_loop_finished` - 工具循环结束
  - 数据: `{final_result, iteration_count}`
- `NeoAI:tool_execution_started` - 工具执行开始
  - 数据: `{tool_name, args, start_time}`
- `NeoAI:tool_execution_completed` - 工具执行完成
  - 数据: `{tool_name, args, result, duration}`
- `NeoAI:tool_execution_error` - 工具执行错误
  - 数据: `{tool_name, args, error_msg, duration}`

### 会话事件
- `NeoAI:session_created` - 会话创建
  - 数据: `{session_id, session}`
- `NeoAI:session_reused` - 会话重用
  - 数据: `{session_id, session}`

### 消息事件
- `NeoAI:message_added` - 消息添加
  - 数据: `{message_id, message}`
- `NeoAI:message_edited` - 消息编辑
  - 数据: `{message_id, old_content, new_content}`
- `NeoAI:message_deleted` - 消息删除
  - 数据: `{message_id, message}`
- `NeoAI:message_updated` - 消息更新
  - 数据: `{message_id, message}`
- `NeoAI:messages_cleared` - 消息清空
  - 数据: `{branch_id, deleted_ids}`
- `NeoAI:messages_built` - 消息构建完成
  - 数据: `{messages, history_count}`
- `NeoAI:message_sent` - 消息发送
  - 数据: `{session_id, branch_id, original_content, formatted_content, message, window_id, timestamp}`
- `NeoAI:formatted_message_sent` - 格式化消息发送
  - 数据: `{session_id, branch_id, original_content, formatted_content, message, window_id, timestamp}`

### UI 事件
- `NeoAI:chat_window_opened` - 聊天窗口打开
  - 数据: `{window_id, window_type, options}`
- `NeoAI:chat_window_closed` - 聊天窗口关闭
  - 数据: `{window_id, window_type}`

## 高级用法

### 一次性监听器

```lua
local autocmd_id
autocmd_id = vim.api.nvim_create_autocmd("User", {
    pattern = "NeoAI:session_created",
    callback = function(args)
        -- 先移除监听器
        vim.api.nvim_del_autocmd(autocmd_id)
        -- 再处理事件
        local session_id = args.data[1]
        print("第一次会话创建:", session_id)
    end
})
```

### 异步触发事件

```lua
-- 在 vim.schedule 中触发事件，避免阻塞
vim.schedule(function()
    vim.api.nvim_exec_autocmds("User", {
        pattern = "NeoAI:config_changed",
        data = {version = "2.0.0"}
    })
end)
```

### 等待事件

```lua
-- 简单的等待事件实现
function wait_for_event(event_pattern, timeout_ms)
    local event_data = nil
    local event_received = false
    
    local autocmd_id = vim.api.nvim_create_autocmd("User", {
        pattern = event_pattern,
        callback = function(args)
            event_data = args.data
            event_received = true
            vim.api.nvim_del_autocmd(autocmd_id)
        end
    })
    
    local start_time = vim.loop.now()
    timeout_ms = timeout_ms or 5000
    
    while not event_received and (vim.loop.now() - start_time) < timeout_ms do
        vim.wait(10, function() return event_received end)
    end
    
    if not event_received then
        vim.api.nvim_del_autocmd(autocmd_id)
    end
    
    return event_data
end

-- 使用示例
local result = wait_for_event("NeoAI:generation_completed", 3000)
if result then
    print("生成完成:", result[1])
end
```

### 事件组管理

```lua
-- 管理多个相关的事件监听器
local ui_event_listeners = {}

-- 添加监听器
table.insert(ui_event_listeners, vim.api.nvim_create_autocmd("User", {
    pattern = "NeoAI:chat_window_opened",
    callback = function(args) print("聊天窗口打开") end
}))

table.insert(ui_event_listeners, vim.api.nvim_create_autocmd("User", {
    pattern = "NeoAI:chat_window_closed",
    callback = function(args) print("聊天窗口关闭") end
}))

-- 清理所有监听器
function cleanup_ui_listeners()
    for _, id in ipairs(ui_event_listeners) do
        vim.api.nvim_del_autocmd(id)
    end
    ui_event_listeners = {}
end
```

## 在代码中使用

### 触发事件示例

```lua
-- 在 AI 引擎中触发生成开始事件
function M.generate_response(messages, options)
    local generation_id = "gen_" .. os.time()
    
    -- 触发事件
    vim.api.nvim_exec_autocmds("User", {
        pattern = "NeoAI:generation_started",
        data = {generation_id, messages}
    })
    
    -- ... 其他代码 ...
end

-- 在工具执行器中触发工具执行事件
function M.execute(tool_name, args)
    local start_time = os.time()
    
    -- 触发开始事件
    vim.api.nvim_exec_autocmds("User", {
        pattern = "NeoAI:tool_execution_started",
        data = {tool_name, args, start_time}
    })
    
    -- ... 执行工具 ...
    
    local end_time = os.time()
    local duration = end_time - start_time
    
    -- 触发完成事件
    vim.api.nvim_exec_autocmds("User", {
        pattern = "NeoAI:tool_execution_completed",
        data = {tool_name, args, result, duration}
    })
end
```

### 监听事件示例

```lua
-- 插件初始化时注册事件监听器
function M.setup(config)
    -- 监听 AI 生成事件
    vim.api.nvim_create_autocmd("User", {
        pattern = "NeoAI:generation_started",
        callback = function(args)
            local generation_id = args.data[1]
            vim.notify("AI 生成开始: " .. generation_id, vim.log.levels.INFO)
        end
    })
    
    -- 监听工具执行错误
    vim.api.nvim_create_autocmd("User", {
        pattern = "NeoAI:tool_execution_error",
        callback = function(args)
            local tool_name, error_msg = args.data[1], args.data[3]
            vim.notify("工具执行错误: " .. tool_name .. " - " .. error_msg, vim.log.levels.ERROR)
        end
    })
    
    -- 监听窗口事件
    vim.api.nvim_create_autocmd("User", {
        pattern = "NeoAI:chat_window_opened",
        callback = function(args)
            local window_id = args.data[1]
            print("聊天窗口已打开:", window_id)
        end
    })
end
```

## 最佳实践

1. **事件命名规范**：使用 `NeoAI:` 前缀，后跟描述性名称
2. **数据格式**：使用数组传递数据，保持顺序一致
3. **及时清理**：不需要的监听器及时删除
4. **错误处理**：在事件回调中添加错误处理
5. **避免阻塞**：事件回调中不要执行耗时操作
6. **文档化**：为新事件添加文档说明

## 调试事件

### 查看已注册的事件

```lua
-- 查看所有 NeoAI 事件监听器
local autocmds = vim.api.nvim_get_autocmds({
    event = "User",
    pattern = "NeoAI:*"
})

for _, autocmd in ipairs(autocmds) do
    print("事件:", autocmd.pattern, "ID:", autocmd.id)
end
```

### 调试事件触发

```lua
-- 监听所有 NeoAI 事件进行调试
vim.api.nvim_create_autocmd("User", {
    pattern = "NeoAI:*",
    callback = function(args)
        print("事件触发:", args.match, "数据:", vim.inspect(args.data))
    end
})
```

## 注意事项

1. 事件数据通过 `args.data` 访问，是一个数组
2. 事件模式支持通配符，如 `NeoAI:*`
3. 同一个事件可以有多个监听器
4. 监听器按照注册顺序执行
5. 事件触发是同步的，回调会立即执行