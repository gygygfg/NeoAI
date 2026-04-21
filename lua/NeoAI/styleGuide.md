# 架构设计

NeoAI/
├── init.lua # 主入口文件
├── default_config.lua # 全局配置验证
├── core/ # 核心业务逻辑
│ ├── init.lua # 核心模块入口
│ ├── config/ # 配置管理
│ │ ├── config_manager.lua # 配置管理（合并验证功能）
│ │ └── keymap_manager.lua # 键位配置管理器（新增）
│ ├── session/ # 会话管理
│ │ ├── session_manager.lua # 会话管理器
│ │ ├── branch_manager.lua # 分支管理
│ │ ├── message_manager.lua # 消息管理（合并操作）
│ │ └── data_operations.lua # 数据操作
│ ├── ai/ # AI交互
│ │ ├── ai_engine.lua # AI引擎主入口
│ │ ├── stream_processor.lua # 流式处理器
│ │ ├── reasoning_manager.lua # 思考过程管理
│ │ ├── tool_orchestrator.lua # 工具调用编排器
│ │ └── response_builder.lua # 响应构建器
│ └── events/ # 事件系统
│ └── event_bus.lua # 事件总线（简化）
├── ui/ # 用户界面
│ ├── init.lua # UI模块入口
│ ├── window/ # 窗口管理
│ │ ├── window_manager.lua # 窗口管理器
│ │ ├── window_mode_manager.lua # 窗口模式管理器（新增）
│ │ ├── chat_window.lua # 聊天窗口
│ │ └── tree_window.lua # 树状图窗口
│ ├── components/ # UI组件
│ │ ├── input_handler.lua # 输入处理器
│ │ ├── history_tree.lua # 历史树组件
│ │ └── reasoning_display.lua # 思考过程显示
│ └── handlers/ # 事件处理器
│ ├── tree_handlers.lua # 树界面处理器
│ └── chat_handlers.lua # 聊天界面处理器
├── tools/ # 工具系统（新增）
│ ├── init.lua # 工具模块入口
│ ├── tool_registry.lua # 工具注册表
│ ├── tool_executor.lua # 工具执行器
│ ├── tool_validator.lua # 工具验证器
│ └── builtin/ # 内置工具
│ └── file_tools.lua # 文件工具
└── utils/ # 工具库（精简）
├── init.lua # 工具模块入口
├── common.lua # 常用工具函数
├── text_utils.lua # 文本处理
├── table_utils.lua # 表操作
├── file_utils.lua # 文件操作
└── logger.lua # 日志

# 关键流程说明

1. 启动流程

1. 用户调用
   "setup(config)" →
   "default_config.validate_config()"
1. 初始化核心模块 → 初始化UI模块（传递窗口模式配置） → 初始化工具系统
1. 返回包含
   "open()" 函数的表

窗口模式配置示例：

```lua
require("NeoAI").setup({
  ui = {
    default_ui = "chat",           -- 默认打开聊天界面
    window_mode = "split",          -- 使用分割窗口模式
    window = {
      width = 100,
      height = 30,
      border = "single",
    },
  },
  ai = {
    model = "gpt-4",
    api_key = os.getenv("OPENAI_API_KEY"),
  },
})
```

1. 树界面操作流程

":NeoAIOpen" →
"ui.open_tree_ui()"
回车键 →
"tree_handlers.handle_enter()" → 关闭树界面 → 打开聊天界面
按键映射由
"tree_window.set_keymaps()" 设置

2. 聊天界面消息流程

用户输入 →
"input_handler.handle_input()"
发送消息 →
"chat_handlers.handle_enter()" 或
"handle_ctrl_s()"
AI处理 →
"ai_engine.generate_response()"
流式处理 →
"stream_processor.process_chunk()"
显示结果 →
"chat_window.render_messages()"

3. 工具调用循环流程

模型返回工具调用 →
"tool_orchestrator.execute_tool_loop()"
执行工具 →
"tool_executor.execute()"
重整上下文 →
"response_builder.build_context()"
继续调用模型直到结束

4. 思考过程显示流程

// 开始思考
data: {"choices":[{"delta":{"reasoning_content":"让我"}}]}
data: {"choices":[{"delta":{"reasoning_content":"一步步思考"}}]}

// ... 更多思考内容 ...

// 思考结束，开始输出答案
data: {"choices":[{"delta":{"content":"DeepSeek"}}]}
data: {"choices":[{"delta":{"content":"的思考过程"}}]}

// 流结束
data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

接收到
"reasoning_content" →
"reasoning_manager.start_reasoning()"
打开悬浮窗口 →
"reasoning_display.show()"
流式更新 →
"reasoning_display.append()"
思考结束 →
"reasoning_display.close()" → 转换为折叠文本

5. 窗口模式配置流程

插件启动时 →
"default_config" 读取默认窗口模式配置
用户自定义配置 →
"ui.window_mode" 和 "ui.default_ui" 配置项
窗口管理器初始化 →
"window_manager.initialize()" 接收窗口模式配置
创建窗口时 →
"window_mode_manager.create_window_by_mode()" 根据模式创建窗口
支持三种模式：

- "float": 浮动窗口（默认）
- "tab": 新标签页
- "split": 分割窗口

6. 键位配置流程

插件启动时 →
"keymap_manager.load_default_keymaps()"
用户自定义配置 →
"keymap_manager.set_keymap(context, action, key)"
窗口打开时 →
"window.set_keymaps()" → 调用 "keymap_manager.get_keymap()"
保存配置 →
"keymap_manager.save_keymaps()"
重置键位 →
"keymap_manager.reset_keymap(context, action)"

## 命令和快捷键注册

### 已注册的 Neovim 命令

插件初始化时会自动注册以下命令：

1. **:NeoAIOpen** - 打开 NeoAI 主界面（根据配置选择默认界面）
2. **:NeoAIClose** - 关闭所有 NeoAI 窗口
3. **:NeoAITree** - 打开树界面
4. **:NeoAIChat** - 打开聊天界面
5. **:NeoAIKeymaps** - 显示当前键位配置（在浮动窗口中）

### 全局快捷键

插件会根据配置自动注册以下全局快捷键：

1. **打开树界面** - `<leader>at`（可配置）
2. **打开聊天界面** - `<leader>ac`（可配置）
3. **关闭所有窗口** - `<leader>aq`（可配置）
4. **切换 UI 显示** - `<leader>aa`（可配置）

## 事件系统规范

### 事件命名规范

所有 NeoAI 事件使用 `NeoAI:` 前缀，遵循以下命名约定：

1. **事件类型前缀**：
   - `NeoAI:generation_` - AI 生成相关事件
   - `NeoAI:stream_` - 流式处理事件
   - `NeoAI:reasoning_` - 思考过程事件
   - `NeoAI:tool_` - 工具调用事件
   - `NeoAI:session_` - 会话管理事件
   - `NeoAI:branch_` - 分支管理事件
   - `NeoAI:message_` - 消息管理事件
   - `NeoAI:window_` - 窗口管理事件
   - `NeoAI:config_` - 配置管理事件
   - `NeoAI:backup_` - 备份管理事件
   - `NeoAI:log_` - 日志事件
   - `NeoAI:ai_response_` - AI响应事件

2. **事件动作后缀**：
   - `_started` - 动作开始
   - `_completed` - 动作完成
   - `_error` - 动作错误
   - `_created` - 创建操作
   - `_updated` - 更新操作
   - `_deleted` - 删除操作
   - `_opened` - 打开操作
   - `_closed` - 关闭操作

### 事件触发规范

#### 触发事件

```lua
-- 标准事件触发
vim.api.nvim_exec_autocmds("User", {
  pattern = "NeoAI:message_added",
  data = {message_id, message}
})

-- 带窗口ID的事件
vim.api.nvim_exec_autocmds("User", {
  pattern = "NeoAI:chat_window_opened",
  data = {window_id = window_id}
})
```

#### 监听事件

```lua
-- 创建事件监听器
local autocmd_id = vim.api.nvim_create_autocmd("User", {
  pattern = "NeoAI:message_added",
  callback = function(args)
    local data = args.data
    local message_id, message = data[1], data[2]
    -- 处理事件
  end
})

-- 一次性监听器
local once_listener = vim.api.nvim_create_autocmd("User", {
  pattern = "NeoAI:session_created",
  callback = function(args)
    -- 处理事件
    vim.api.nvim_del_autocmd(once_listener) -- 移除监听器
  end,
  once = true
})
```

### 事件数据规范

事件数据应遵循以下格式：

1. **简单数据**：直接传递值

   ```lua
   data = {session_id, session}
   ```

2. **命名参数**：使用命名参数提高可读性

   ```lua
   data = {window_id = window_id, window_type = "chat"}
   ```

3. **复杂数据**：传递表结构
   ```lua
   data = {
     tool_call = tool_call,
     error_msg = error_msg,
     timestamp = os.time()
   }
   ```

### 事件分类（基于实际实现）

#### 1. AI 生成事件

- `NeoAI:generation_started` - AI生成开始（数据：`{generation_id, formatted_messages}`）
- `NeoAI:generation_completed` - AI生成完成（数据：`{generation_id, response}`）
- `NeoAI:generation_error` - AI生成错误（数据：`{generation_id, error_msg}`）
- `NeoAI:generation_cancelled` - AI生成取消（数据：`{generation_id}`）

#### 2. 流式处理事件

- `NeoAI:stream_chunk` - 流式数据块到达（数据：`{generation_id, cleaned_chunk}`）
- `NeoAI:stream_started` - 流式处理开始（数据：`{generation_id, formatted_messages}`）
- `NeoAI:stream_completed` - 流式处理完成（数据：`{session_id}`）
- `NeoAI:stream_error` - 流式处理错误

#### 3. 推理事件

- `NeoAI:reasoning_content` - 推理内容到达（数据：`{reasoning_content}`）
- `NeoAI:reasoning_started` - 推理开始
- `NeoAI:reasoning_completed` - 推理完成

#### 4. 工具相关事件

- `NeoAI:tool_loop_started` - 工具循环开始（数据：`{current_messages}`）
- `NeoAI:tool_loop_finished` - 工具循环结束（数据：`{final_result, iteration_count}`）
- `NeoAI:tool_execution_started` - 工具执行开始（数据：`{tool_call}` 或 `{tool_name, args, start_time}`）
- `NeoAI:tool_execution_completed` - 工具执行完成（数据：`{tool_call, formatted_result}` 或 `{tool_name, args, result, duration}`）
- `NeoAI:tool_error` - 工具执行错误（数据：`{tool_call, error_msg}` 或 `{tool_name, args, error_msg, duration}`）
- `NeoAI:tool_call_detected` - 工具调用检测到（数据：`{tool_call}`）
- `NeoAI:tool_result_received` - 工具结果接收（数据：`{tool_call, result}`）

#### 5. 会话事件

- `NeoAI:session_created` - 会话创建（数据：`{session_id, session}`）
- `NeoAI:session_reused` - 会话重用（数据：`{session_id, session}`）
- `NeoAI:session_loaded` - 会话加载（数据：`{new_session_id, filepath}`）
- `NeoAI:session_saved` - 会话保存（数据：`{session_id, filepath}`）
- `NeoAI:session_deleted` - 会话删除（数据：`{session_id}`）
- `NeoAI:session_changed` - 会话变更（数据：`{session_id, session}`）

#### 6. 分支事件

- `NeoAI:branch_created` - 分支创建（数据：`{branch_id, branch}`）
- `NeoAI:branch_switched` - 分支切换（数据：`{branch_id, old_branch_id}`）
- `NeoAI:branch_deleted` - 分支删除（数据：`{branch_id}`）

#### 7. 消息事件

- `NeoAI:message_added` - 消息添加（数据：`{message_id, message}`）
- `NeoAI:message_edited` - 消息编辑（数据：`{message_id, old_content, content}`）
- `NeoAI:message_deleted` - 消息删除（数据：`{message_id, message}`）
- `NeoAI:messages_cleared` - 消息清空（数据：`{branch_id, deleted_ids}`）
- `NeoAI:messages_built` - 消息构建完成（数据：`{messages, history_count}`）
- `NeoAI:message_updated` - 消息更新（数据：`{message_id, message}`）
- `NeoAI:message_sent` - 消息发送（数据：`{message, window_id, session_id, timestamp, role}`）
- `NeoAI:formatted_message_sent` - 格式化消息发送（数据：`{original_content, formatted_content, session_id, window_id, timestamp}`）

#### 8. 窗口事件

- `NeoAI:chat_window_opened` - 聊天窗口打开（数据：`{window_id = window_id}`）
- `NeoAI:chat_window_closed` - 聊天窗口关闭（数据：`{window_id = window_id}`）
- `NeoAI:tree_window_opened` - 树窗口打开（数据：`{window_id = window_id}`）
- `NeoAI:tree_window_closed` - 树窗口关闭（数据：`{window_id = window_id}`）
- `NeoAI:window_mode_changed` - 窗口模式变更（数据：`{old_mode, new_mode}`）

#### 9. 配置事件

- `NeoAI:config_loaded` - 配置加载完成（数据：`{config}`）
- `NeoAI:config_changed` - 配置变更（数据：`{old_config, new_config}`）

#### 10. 状态事件

- `NeoAI:plugin_initialized` - 插件初始化完成
- `NeoAI:plugin_shutdown` - 插件关闭

#### 11. 备份事件

- `NeoAI:backup_created` - 备份创建（数据：`{backup_file, session_count}`）
- `NeoAI:backup_restored` - 备份恢复（数据：`{backup_file, restored_session_count}`）

#### 12. 响应构建事件

- `NeoAI:response_built` - 响应构建完成

#### 13. 日志事件

- `NeoAI:log_debug` - 调试日志
- `NeoAI:log_info` - 信息日志
- `NeoAI:log_warn` - 警告日志
- `NeoAI:log_error` - 错误日志
- `NeoAI:ai_response_chunk` - AI响应数据块
- `NeoAI:ai_response_complete` - AI响应完成
- `NeoAI:ai_response_error` - AI响应错误

#### 14. 自定义事件

- `NeoAI:send_message` - 发送消息事件
- `NeoAI:close_window` - 关闭窗口事件

### 事件使用最佳实践

1. **事件解耦**：模块间通过事件通信，避免直接依赖
2. **事件命名一致性**：遵循命名规范，保持一致性
3. **数据最小化**：只传递必要的数据，避免传递大型对象
4. **错误处理**：事件触发应包含错误处理
5. **性能考虑**：避免在热路径中频繁触发事件
6. **清理监听器**：及时清理不再需要的监听器

### 事件调试

```lua
-- 调试所有 NeoAI 事件
vim.api.nvim_create_autocmd("User", {
  pattern = "NeoAI:*",
  callback = function(args)
    print("事件触发:", args.match, "数据:", vim.inspect(args.data))
  end
})

-- 调试特定事件
vim.api.nvim_create_autocmd("User", {
  pattern = "NeoAI:tool_*",
  callback = function(args)
    print("工具事件:", args.match, "数据:", vim.inspect(args.data))
  end
})
```

### 事件系统流程

7. 事件通信流程

模块A触发事件 →
`vim.api.nvim_exec_autocmds("User", {pattern = "NeoAI:event_name", data = data})`
事件总线分发 →
模块B监听事件 →
`vim.api.nvim_create_autocmd("User", {pattern = "NeoAI:event_name", callback = handler})`
执行回调函数 →
更新状态或触发新事件

### 事件依赖关系

- **启动事件链**：`NeoAI:session_created` → `NeoAI:branch_created` → `NeoAI:message_added`
- **AI处理链**：`NeoAI:generation_started` → `NeoAI:stream_started` → `NeoAI:stream_chunk` → `NeoAI:stream_completed`
- **工具调用链**：`NeoAI:tool_loop_started` → `NeoAI:tool_execution_started` → `NeoAI:tool_execution_completed` → `NeoAI:tool_loop_finished`
- **窗口管理链**：`NeoAI:WindowOpened` → `NeoAI:ChatBoxOpened` → `NeoAI:WindowClosed`

### 事件测试规范

```lua
-- 测试事件触发
local triggered = false
local listener = vim.api.nvim_create_autocmd("User", {
  pattern = "NeoAI:test_event",
  callback = function() triggered = true end
})

-- 触发事件
vim.api.nvim_exec_autocmds("User", {pattern = "NeoAI:test_event"})

-- 验证
assert(triggered, "事件未触发")
vim.api.nvim_del_autocmd(listener)
```

### 事件系统的重要性

NeoAI 的事件系统是整个架构的核心通信机制，具有以下重要作用：

1. **模块解耦**：各模块通过事件通信，减少直接依赖
2. **可扩展性**：新功能可以通过监听现有事件轻松集成
3. **可观测性**：事件提供了系统状态的完整视图
4. **调试友好**：事件流可以用于调试和问题诊断
5. **异步协调**：协调复杂的异步操作流程

### 事件命名一致性说明

经过代码审查和更新，事件命名已实现完全一致性：

1. **大小写统一**：所有事件使用蛇形命名法（snake_case），如 `chat_window_opened`、`tool_loop_started`
2. **前缀统一**：所有事件使用完整 `NeoAI:` 前缀
3. **动作词统一**：遵循统一的动作后缀规范（`_started`、`_completed`、`_opened`、`_closed` 等）

**当前状态**：所有事件常量已在 `event_constants.lua` 中集中管理，命名完全一致。

### 事件系统演进建议

1. **创建事件常量模块**：集中管理所有事件名称
2. **添加事件验证**：验证事件数据和格式
3. **实现事件总线**：提供更高级的事件管理功能
4. **添加事件文档生成**：自动生成事件文档
5. **事件性能监控**：监控事件系统的性能指标

### 相关文档

- `docs/EVENTS.md` - 事件系统设计文档
- `docs/IMPLEMENTED_EVENTS.md` - 已实现事件列表
- `docs/NATIVE_EVENTS.md` - 原生事件使用示例
- `examples/native_events.lua` - 事件使用示例代码
