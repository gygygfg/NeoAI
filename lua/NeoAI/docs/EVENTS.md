# NeoAI 事件系统文档

## 概述

NeoAI 使用 Neovim 原生事件系统 (`nvim_exec_autocmds`) 来实现异步事件通信。所有事件都通过 `User` 自动命令触发，模式为 `NeoAI:*`。

## 事件常量

所有事件常量定义在 `NeoAI.core.events` 模块中：

```lua
local events = require("NeoAI.core.events")
print(events.EVENTS.GENERATION_STARTED)  -- 输出: "NeoAI:generation_started"
```

## 事件列表

### AI 生成事件
- `GENERATION_STARTED` - AI生成开始
  - 数据: `{generation_id, formatted_messages}`
- `GENERATION_COMPLETED` - AI生成完成
  - 数据: `{generation_id, response}`
- `GENERATION_ERROR` - AI生成错误
  - 数据: `{generation_id, error_msg}`
- `GENERATION_CANCELLED` - AI生成取消

### 流式处理事件
- `STREAM_CHUNK` - 流式数据块到达
  - 数据: `{chunk}`
- `STREAM_STARTED` - 流式处理开始
  - 数据: `{generation_id, formatted_messages}`
- `STREAM_COMPLETED` - 流式处理完成
  - 数据: `{session_id}`
- `STREAM_ERROR` - 流式处理错误

### 推理事件
- `REASONING_CONTENT` - 推理内容到达
  - 数据: `{reasoning_content}`
- `REASONING_STARTED` - 推理开始
- `REASONING_COMPLETED` - 推理完成

### 工具相关事件
- `TOOL_LOOP_STARTED` - 工具循环开始
  - 数据: `{current_messages}`
- `TOOL_LOOP_FINISHED` - 工具循环结束
  - 数据: `{final_result, iteration_count}`
- `TOOL_EXECUTION_STARTED` - 工具执行开始
  - 数据: `{tool_name, args, start_time}`
- `TOOL_EXECUTION_COMPLETED` - 工具执行完成
  - 数据: `{tool_name, args, result, duration}`
- `TOOL_EXECUTION_ERROR` - 工具执行错误
  - 数据: `{tool_name, args, error_msg, duration}`
- `TOOL_CALL_DETECTED` - 检测到工具调用
- `TOOL_RESULT_RECEIVED` - 收到工具结果

### 会话事件
- `SESSION_CREATED` - 会话创建
  - 数据: `{session_id, session}`
- `SESSION_REUSED` - 会话重用
  - 数据: `{session_id, session}`
- `SESSION_LOADED` - 会话加载
- `SESSION_SAVED` - 会话保存
- `SESSION_DELETED` - 会话删除
- `SESSION_CHANGED` - 会话变更

### 分支事件
- `BRANCH_CREATED` - 分支创建
- `BRANCH_SWITCHED` - 分支切换
- `BRANCH_DELETED` - 分支删除

### 消息事件
- `MESSAGE_ADDED` - 消息添加
  - 数据: `{message_id, message}`
- `MESSAGE_EDITED` - 消息编辑
  - 数据: `{message_id, old_content, new_content}`
- `MESSAGE_DELETED` - 消息删除
  - 数据: `{message_id, message}`
- `MESSAGES_CLEARED` - 消息清空
  - 数据: `{branch_id, deleted_ids}`
- `MESSAGES_BUILT` - 消息构建完成
  - 数据: `{messages, history_count}`
- `MESSAGE_SENT` - 消息发送
  - 数据: `{session_id, branch_id, original_content, formatted_content, message, window_id, timestamp}`
- `FORMATTED_MESSAGE_SENT` - 格式化消息发送
  - 数据: `{session_id, branch_id, original_content, formatted_content, message, window_id, timestamp}`

### UI 事件
- `CHAT_WINDOW_OPENED` - 聊天窗口打开
  - 数据: `{window_id, window_type, options}`
- `CHAT_WINDOW_CLOSED` - 聊天窗口关闭
  - 数据: `{window_id, window_type}`
- `TREE_WINDOW_OPENED` - 树窗口打开
- `TREE_WINDOW_CLOSED` - 树窗口关闭
- `WINDOW_MODE_CHANGED` - 窗口模式变更

### 配置事件
- `CONFIG_LOADED` - 配置加载
- `CONFIG_CHANGED` - 配置变更

### 状态事件
- `PLUGIN_INITIALIZED` - 插件初始化
- `PLUGIN_SHUTDOWN` - 插件关闭

## 使用方法

### 基本使用

```lua
local events = require("NeoAI.core.events")

-- 监听事件
local listener_id = events.on(events.EVENTS.MESSAGE_ADDED, function(data)
    local message_id, message = data[1], data[2]
    print("新消息:", message_id, message.content)
end)

-- 触发事件
events.trigger(events.EVENTS.MESSAGE_ADDED, {"msg_123", {id="msg_123", content="Hello"}})

-- 移除监听器
events.off(listener_id)
```

### 高级用法

```lua
-- 一次性监听器
events.once(events.EVENTS.SESSION_CREATED, function(data)
    print("第一次会话创建:", data[1])
end)

-- 等待事件（带超时）
local result = events.wait(events.EVENTS.GENERATION_COMPLETED, 5000) -- 5秒超时
if result then
    print("生成完成:", result[1])
else
    print("等待超时")
end

-- 异步触发事件
events.trigger_async(events.EVENTS.CONFIG_CHANGED, {version="2.0"})

-- 批量触发事件
events.trigger_batch({
    {name = events.EVENTS.PLUGIN_INITIALIZED, data = {timestamp = os.time()}},
    {name = events.EVENTS.CONFIG_LOADED, data = {config = "default"}}
})

-- 事件组管理
local group = events.create_group("my_group")
group:on(events.EVENTS.CHAT_WINDOW_OPENED, function(data) print("窗口打开") end)
group:on(events.EVENTS.CHAT_WINDOW_CLOSED, function(data) print("窗口关闭") end)
group:clear() -- 清理组内所有监听器
```

### 检查事件状态

```lua
-- 检查事件是否已注册
local is_registered = events.is_registered(events.EVENTS.GENERATION_STARTED)

-- 获取监听器数量
local count = events.listener_count(events.EVENTS.GENERATION_STARTED)

-- 清理所有事件监听器
events.clear_all() -- 清理所有事件
events.clear_all("NeoAI:generation_*") -- 清理特定模式的事件
```

## 在插件开发中使用

### 扩展事件系统

```lua
-- 在你的插件模块中
local M = {}

function M.doSomething()
    -- ... 执行操作 ...
    
    -- 触发自定义事件
    vim.api.nvim_exec_autocmds("User", {
        pattern = "NeoAI:my_plugin_event",
        data = {result = "success", timestamp = os.time()}
    })
end

-- 或者使用事件系统模块
local events = require("NeoAI.core.events")
function M.doSomethingElse()
    events.trigger("NeoAI:my_plugin_event", {action = "completed"})
end

return M
```

### 响应系统事件

```lua
-- 监听系统事件并做出响应
local events = require("NeoAI.core.events")

-- 当AI生成开始时，显示通知
events.on(events.EVENTS.GENERATION_STARTED, function(data)
    vim.notify("AI生成开始...", vim.log.levels.INFO)
end)

-- 当工具执行错误时，记录日志
events.on(events.EVENTS.TOOL_EXECUTION_ERROR, function(data)
    local tool_name, args, error_msg = data[1], data[2], data[3]
    print(string.format("工具 %s 执行错误: %s", tool_name, error_msg))
end)
```

## 最佳实践

1. **及时清理监听器**：避免内存泄漏，在不需要时移除监听器
2. **使用事件组**：管理相关事件的监听器
3. **避免阻塞**：事件回调中不要执行耗时操作
4. **错误处理**：在事件回调中添加错误处理
5. **文档化**：为自定义事件添加文档说明

## 故障排除

### 事件未触发
1. 检查事件名称是否正确
2. 确保事件在正确的时间点触发
3. 检查是否有其他代码移除了监听器

### 内存泄漏
1. 使用事件组管理相关监听器
2. 在插件卸载时清理所有监听器
3. 使用一次性监听器处理临时需求

### 性能问题
1. 避免在事件回调中执行复杂计算
2. 减少不必要的事件监听
3. 使用 `trigger_async` 避免阻塞主线程

## 示例代码

更多示例请参考 `NeoAI/examples/event_usage.lua`。