# NeoAI 架构设计指南

## 目录结构

```
NeoAI/
├── init.lua                    # 主入口文件：setup/命令注册/全局快捷键
├── default_config.lua          # 默认配置定义、验证、合并、清理
├── styleGuide.md               # 本文件：架构设计文档
│
├── core/                       # 核心业务逻辑
│   ├── init.lua                # 核心模块入口，协调子模块初始化
│   ├── history_manager.lua     # 历史管理器（基于跳表，按时间排序会话）
│   │
│   ├── config/
│   │   └── keymap_manager.lua  # 键位配置管理器
│   │
│   ├── session/                # 会话管理
│   │   ├── session_manager.lua # 会话管理器（CRUD、持久化、防抖保存）
│   │   ├── branch_manager.lua  # 分支管理
│   │   ├── message_manager.lua # 消息管理
│   │   ├── data_operations.lua # 数据操作工具
│   │   └── tree_manager.lua    # 树形结构管理器（虚拟根节点 + 会话树）
│   │
│   ├── ai/                     # AI 交互
│   │   ├── ai_engine.lua       # AI 引擎主入口（事件驱动，协调子模块）
│   │   ├── http_client.lua     # HTTP 客户端（流式/非流式请求）
│   │   ├── request_builder.lua # 请求构建器（格式化消息、添加工具信息）
│   │   ├── response_builder.lua# 响应构建器（异步处理、上下文构建）
│   │   ├── stream_processor.lua# 流式处理器（解析 SSE 数据块）
│   │   ├── reasoning_manager.lua# 思考过程管理
│   │   └── tool_orchestrator.lua# 工具调用编排器
│   │
│   └── events/
│       └── event_constants.lua # 事件常量定义（统一管理所有事件名）
│
├── ui/                         # 用户界面
│   ├── init.lua                # UI 模块入口，协调窗口/组件/处理器
│   │
│   ├── window/                 # 窗口管理
│   │   ├── window_manager.lua  # 窗口管理器（float/tab/split 三种模式）
│   │   ├── chat_window.lua     # 聊天窗口
│   │   └── tree_window.lua     # 树状图窗口
│   │
│   ├── components/             # UI 组件
│   │   ├── input_handler.lua   # 输入处理器
│   │   ├── history_tree.lua    # 历史树组件
│   │   ├── reasoning_display.lua# 思考过程显示
│   │   └── virtual_input.lua   # 虚拟输入框组件
│   │
│   └── handlers/               # 事件处理器
│       ├── tree_handlers.lua   # 树界面处理器
│       └── chat_handlers.lua   # 聊天界面处理器
│
├── tools/                      # 工具系统
│   ├── init.lua                # 工具模块入口
│   ├── tool_registry.lua       # 工具注册表
│   ├── tool_executor.lua       # 工具执行器
│   ├── tool_validator.lua      # 工具验证器
│   ├── tool_history_manager.lua# 工具历史管理器
│   │
│   └── builtin/                # 内置工具
│       ├── file_tools.lua      # 文件操作工具
│       ├── file_utils_tools.lua# 文件工具函数
│       ├── general_tools.lua   # 通用工具
│       └── log_tools.lua       # 日志工具
│
├── utils/                      # 工具库
│   ├── init.lua                # 工具模块入口（自动加载所有子模块）
│   ├── common.lua              # 通用工具函数（深拷贝等）
│   ├── text_utils.lua          # 文本处理
│   ├── table_utils.lua         # 表操作
│   ├── file_utils.lua          # 文件操作
│   ├── logger.lua              # 日志系统
│   ├── json.lua                # JSON 编解码
│   ├── skiplist.lua            # 跳表数据结构
│   ├── async_worker.lua        # 异步工作器
│   ├── debug_utils.lua         # 调试工具
│   ├── session_helper.lua      # 会话辅助函数
│   ├── thread_utils.lua        # 线程工具
│   └── tool_registry.lua       # 工具注册表（utils 层）
│
├── examples/                   # 示例代码
│   ├── debug_example.lua
│   ├── multithread_optimization.lua
│   ├── native_events.lua
│   ├── thread_usage.lua
│   ├── threaded_test_demo.lua
│   └── ui_multithread_example.lua
│
├── docs/                       # 文档
│   ├── AI_RESPONSE_FLOW.md
│   ├── EVENTS.md
│   ├── IMPLEMENTED_EVENTS.md
│   ├── NATIVE_EVENTS.md
│   ├── chat_enhanced_usage.md
│   ├── threaded_testing.md
│   └── ui_multithread_optimization.md
│
└── tests/                      # 测试数据
    └── deepseek_responses/
        ├── reasoning_non_stream_20260419_231549.json
        ├── reasoning_streaming_20260419_231549.json
        └── streaming_no_reasoning_20260419_231549.json
```

---

## 启动流程

```
用户调用 setup(config)
    │
    ▼
default_config.validate_config(config)    ← 验证用户配置合法性
default_config.merge_defaults(config)     ← 合并默认配置
default_config.sanitize_config(config)    ← 清理/补全配置（创建目录等）
    │
    ▼
core.initialize(config)                   ← 初始化核心模块
  ├── keymap_manager.initialize()         ← 键位配置
  ├── session_manager.initialize()        ← 会话管理
  ├── ai_engine.initialize()              ← AI 引擎
  └── history_manager.initialize()        ← 历史管理器
    │
    ▼
ui.initialize(config)                     ← 初始化 UI 模块
  ├── window_manager.initialize()         ← 窗口管理器
  ├── input_handler.initialize()
  ├── history_tree.initialize()
  ├── reasoning_display.initialize()
  ├── tree_window.initialize()
  ├── chat_window.initialize()
  ├── tree_handlers.initialize()
  └── chat_handlers.initialize()
    │
    ▼
tools.initialize(config.tools)            ← 初始化工具系统
  ├── tool_registry.initialize()
  ├── tool_executor.initialize()
  ├── tool_validator.initialize()
  ├── tool_history_manager.initialize()
  └── _load_builtin_tools()               ← 加载内置工具
    │
    ▼
register_commands()                       ← 注册 :NeoAIOpen 等命令
register_global_keymaps()                 ← 注册全局快捷键
    │
    ▼
async_worker.initialize()                 ← 初始化异步工作器
```

### 配置示例

```lua
require("NeoAI").setup({
  ui = {
    default_ui = "chat",           -- 默认打开界面: "tree" | "chat"
    window_mode = "split",          -- 窗口模式: "float" | "tab" | "split"
    window = {
      width = 100,
      height = 30,
      border = "single",
    },
  },
  ai = {
    model = "deepseek-reasoner",
    api_key = os.getenv("DEEPSEEK_API_KEY"),
    base_url = "https://api.deepseek.com/chat/completions",
    temperature = 0.7,
    max_tokens = 4096,
    stream = true,
    timeout = 60000,
  },
  session = {
    auto_save = true,
    save_path = vim.fn.stdpath("cache") .. "/NeoAI",
    max_history_per_session = 1000,
  },
})
```

---

## 核心模块职责

### `init.lua` — 主入口

- 维护插件全局状态（`state` 表）
- `setup(user_config)` — 初始化所有模块、注册命令和快捷键
- 提供对外接口：`open_neoai()`, `close_all()`, `get_session_manager()`, `get_ai_engine()`, `get_tools()`, `get_keymap_manager()`
- 注册命令：`:NeoAIOpen`, `:NeoAIClose`, `:NeoAITree`, `:NeoAIChat`, `:NeoAIKeymaps`, `:NeoAIChatStatus`

### `default_config.lua` — 配置管理

- 定义 `DEFAULT_CONFIG` 默认配置表
- `validate_config(config)` — 验证用户配置合法性
- `merge_defaults(config)` — 深度合并用户配置与默认配置
- `sanitize_config(config)` — 清理配置（创建保存目录等）
- `get(key)`, `set(key, value)` — 点号路径配置存取
- `validate()` — 完整配置验证
- `export()`, `import()` — 配置导入导出

### `core/init.lua` — 核心模块入口

- 初始化 `keymap_manager`, `session_manager`, `ai_engine`, `history_manager`
- 提供 `get_session_manager()`, `get_ai_engine()`, `get_keymap_manager()`, `get_history_manager()`, `get_config_manager()`

### `core/session/session_manager.lua` — 会话管理器

- 会话 CRUD：`create_session()`, `get_session()`, `delete_session()`, `list_sessions()`
- 当前会话管理：`get_current_session()`, `set_current_session()`
- 自动保存：防抖 500ms 保存到 `sessions.json`
- 加载时兼容新旧两种格式
- 与 `tree_manager` 双向同步

### `core/session/tree_manager.lua` — 树形结构管理器

- 维护虚拟根节点 `virtual_root`，所有会话作为其子节点
- 节点类型：`root_branch`, `sub_branch`, `session`, `conversation_round`, `message`
- 对话轮次（`conversation_round`）将问答摘要显示在一行，不创建子消息节点
- 树数据持久化到 `sessions.json` 的 `_tree_graph` 字段
- `sync_from_session_manager()` — 从会话管理器同步数据

### `core/ai/ai_engine.lua` — AI 引擎

- 事件驱动：监听 `NeoAI:send_message` 事件
- 支持流式和非流式两种请求模式
- 重试机制：最多 3 次，间隔 1 秒
- 协调子模块：`request_builder`, `response_builder`, `stream_processor`, `reasoning_manager`, `tool_orchestrator`, `http_client`
- 提供子模块功能接口（代理模式）

### `core/ai/http_client.lua` — HTTP 客户端

- 真正的 HTTP API 调用（非模拟）
- 支持流式（SSE）和非流式请求
- 请求取消支持

### `core/events/event_constants.lua` — 事件常量

所有事件名统一管理，按类别分组：

| 类别 | 事件 | 说明 |
|------|------|------|
| AI 生成 | `NeoAI:generation_started/completed/error/cancelled` | 生成生命周期 |
| 流式 | `NeoAI:stream_started/chunk/completed/error` | 流式数据处理 |
| 推理 | `NeoAI:reasoning_started/content/completed` | 思考过程 |
| 工具 | `NeoAI:tool_loop_started/finished`, `tool_execution_started/completed/error`, `tool_call_detected`, `tool_result_received` | 工具调用 |
| 会话 | `NeoAI:session_created/reused/loaded/saved/deleted/changed` | 会话生命周期 |
| 分支 | `NeoAI:branch_created/switched/deleted` | 分支管理 |
| 消息 | `NeoAI:message_added/edited/deleted/updated/sent`, `messages_cleared/built` | 消息操作 |
| UI | `NeoAI:chat_window_opened/closed`, `tree_window_opened/closed`, `window_mode_changed` | 窗口管理 |
| 配置 | `NeoAI:config_loaded/changed` | 配置变更 |
| 状态 | `NeoAI:plugin_initialized/shutdown` | 插件生命周期 |
| 聊天流 | `NeoAI:user_message_ready/sending/sent`, `ai_response_ready/received`, `chat_input_ready` | 消息流解耦 |

---

## 关键流程

### 1. 树界面操作流程

```
:NeoAIOpen
    │
    ▼
ui.open_tree_ui()
    │
    ▼
window_manager.create_window("tree", {...})   ← 创建浮动/标签/分割窗口
    │
    ▼
tree_window.open(session_id, tree_win_id)     ← 打开树窗口
    │
    ▼
tree_window.set_keymaps(keymap_manager)       ← 设置按键映射
    │
    ▼
触发 NeoAI:tree_window_opened 事件
```

树界面按键（由 `tree_window.set_keymaps()` 设置）：
- `<CR>` — 选择节点/分支 → `tree_handlers.handle_enter()` → 关闭树 → 打开聊天
- `n` — 新建子分支
- `N` — 新建根分支
- `d` — 删除对话
- `D` — 删除分支
- `o` — 展开节点
- `O` — 折叠节点

### 2. 聊天界面消息流程

```
用户输入
    │
    ▼
input_handler.handle_input()                   ← 处理用户输入
    │
    ▼
chat_handlers.handle_enter() / handle_ctrl_s() ← 发送消息
    │
    ▼
触发 NeoAI:send_message 事件
    │
    ▼
ai_engine.handle_send_message(data)            ← AI 引擎接收
    │
    ▼
ai_engine.generate_response(messages, params)  ← 开始生成
```

聊天界面按键（由 `chat_window.set_keymaps()` 设置）：
- `<CR>` — 发送消息
- `<Esc>` — 取消生成
- `e` — 编辑消息
- `dd` — 删除消息
- `<C-u>` — 向上滚动
- `<C-d>` — 向下滚动
- `r` — 切换思考过程显示
- `<C-CR>` — 新建行
- `<C-u>` — 清空输入

### 3. AI 处理流程

```
NeoAI:send_message 事件
    │
    ▼
ai_engine.handle_send_message(data)
    │
    ├── 从会话管理器获取消息历史
    ├── 添加用户消息
    ├── 触发 NeoAI:user_message_sent
    │
    ▼
ai_engine.generate_response(messages, params)
    │
    ├── request_builder.format_messages()      ← 格式化消息
    ├── request_builder.build_request()        ← 构建请求体（含工具信息）
    ├── 触发 NeoAI:generation_started
    │
    ▼
    ├── 流式模式 (request.stream == true)
    │   ├── 触发 NeoAI:stream_started
    │   ├── stream_processor.start_stream()
    │   ├── http_client.send_stream_request()
    │   │   ├── on_chunk → _handle_stream_chunk()
    │   │   │   ├── stream_processor.process_chunk()
    │   │   │   ├── 触发 NeoAI:reasoning_content (思考内容)
    │   │   │   ├── 触发 NeoAI:stream_chunk (普通内容)
    │   │   │   └── 触发 NeoAI:tool_call_detected (工具调用)
    │   │   └── on_complete → _handle_stream_end()
    │   │       ├── 触发 NeoAI:stream_completed
    │   │       └── _finalize_generation()
    │   └── on_error → 重试或触发错误事件
    │
    └── 非流式模式
        ├── http_client.send_request()
        ├── handle_ai_response()
        │   ├── 提取 content / reasoning_content / tool_calls
        │   ├── 如有工具调用 → tool_orchestrator.execute_tool_loop()
        │   └── _finalize_generation()
        └── 错误处理 → 重试或触发错误事件
```

### 4. 工具调用循环

```
模型返回 tool_calls
    │
    ▼
tool_orchestrator.execute_tool_loop()
    │
    ├── 触发 NeoAI:tool_loop_started
    │
    ▼
对每个 tool_call:
    ├── tool_executor.execute(tool_name, args)
    ├── 触发 NeoAI:tool_execution_started
    ├── 触发 NeoAI:tool_execution_completed
    │
    ▼
收集所有工具结果
    │
    ▼
触发 NeoAI:tool_result_received
    │
    ▼
ai_engine.handle_tool_result(data)
    │
    ├── 添加工具结果到消息历史
    └── 继续 generate_response()  ← 再次调用模型
```

### 5. 思考过程显示流程

```
接收到 reasoning_content
    │
    ▼
reasoning_manager.start_reasoning()
    │
    ▼
reasoning_display.show()                      ← 打开悬浮窗口
    │
    ▼
流式更新 reasoning_content
    │
    ▼
reasoning_display.append(content)             ← 追加内容
    │
    ▼
思考结束
    │
    ▼
reasoning_display.close()                     ← 关闭窗口，转换为折叠文本
```

### 6. 窗口模式

支持三种窗口模式，由 `ui.window_mode` 配置：

| 模式 | 创建方式 | 关闭方式 | 适用场景 |
|------|----------|----------|----------|
| `float` | `nvim_open_win` 浮动窗口 | `nvim_win_close` | 临时交互 |
| `tab` | `tabnew` 新标签页 | `tabclose` | 长时间工作 |
| `split` | `vsplit`/`split` 分割 | `nvim_win_close` | 并排查看 |

### 7. 虚拟输入框

`virtual_input.lua` 组件提供独立的输入界面：

- 在聊天窗口底部创建浮动输入框
- 支持占位符虚拟文本
- 按键映射可配置（从 `keymap_manager` 获取）
- 窗口大小变化时自动调整位置
- 提交后清空内容但不关闭输入框

### 8. 会话持久化

```
保存（防抖 500ms）：
    session_manager._save_sessions()
        │
        ▼
    构建 sessions_json_data（按 session_N 编号索引）
        │
        ▼
    写入 sessions.json
        │
        ▼
    tree_manager._save_tree_data()
        │
        ▼
    读取 sessions.json → 写入 _tree_graph 字段

加载：
    session_manager._load_sessions()
        │
        ▼
    读取 sessions.json
        │
        ├── 恢复会话数据到 sessions 表
        ├── 恢复消息到 message_manager
        └── 同步到 tree_manager
```

---

## 事件通信机制

所有模块间通信通过 Neovim 原生事件系统实现：

```lua
-- 触发事件
vim.api.nvim_exec_autocmds("User", {
  pattern = "NeoAI:event_name",
  data = { key = value, ... }
})

-- 监听事件
vim.api.nvim_create_autocmd("User", {
  pattern = "NeoAI:event_name",
  callback = function(args)
    local data = args.data
    -- 处理事件
  end
})
```

### 事件依赖链

- **启动链**：`NeoAI:session_created` → `NeoAI:branch_created` → `NeoAI:message_added`
- **AI 处理链**：`NeoAI:generation_started` → `NeoAI:stream_started` → `NeoAI:stream_chunk` → `NeoAI:stream_completed` → `NeoAI:generation_completed`
- **工具调用链**：`NeoAI:tool_loop_started` → `NeoAI:tool_execution_started` → `NeoAI:tool_execution_completed` → `NeoAI:tool_loop_finished`
- **窗口管理链**：`NeoAI:chat_window_opened` → `NeoAI:chat_window_closed`

---

## 配置项参考

### AI 配置 (`config.ai`)

```lua
{
  base_url = "https://api.deepseek.com/chat/completions",  -- API 地址
  api_key = "",                                             -- API 密钥（从环境变量读取）
  model = "deepseek-reasoner",                              -- 模型名称
  temperature = 0.7,                                        -- 温度 (0-2)
  max_tokens = 4096,                                        -- 最大 Token 数
  stream = true,                                            -- 是否流式响应
  timeout = 60000,                                          -- 超时时间（毫秒）
  system_prompt = "你是一个AI编程助手...",                   -- 系统提示词
}
```

### UI 配置 (`config.ui`)

```lua
{
  default_ui = "tree",              -- 默认界面: "tree" | "chat"
  window_mode = "tab",              -- 窗口模式: "float" | "tab" | "split"
  window = {
    width = 80,
    height = 20,
    border = "rounded",
  },
  colors = {
    background = "Normal",
    border = "FloatBorder",
    text = "Normal",
  },
}
```

### 会话配置 (`config.session`)

```lua
{
  auto_save = true,                                         -- 自动保存
  save_path = vim.fn.stdpath("cache") .. "/NeoAI",          -- 保存路径
  max_history_per_session = 1000,                           -- 每会话最大历史数
}
```

### 工具配置 (`config.tools`)

```lua
{
  enabled = true,                   -- 是否启用工具系统
  builtin = true,                   -- 是否加载内置工具
  external = {},                    -- 外部工具列表
}
```

---

## 错误处理

| 错误类型 | 触发事件 | 处理方式 |
|----------|----------|----------|
| 请求错误 | `NeoAI:generation_error` | 最多重试 3 次，间隔 1 秒 |
| 流式错误 | `NeoAI:stream_error` | 最多重试 3 次 |
| 工具执行错误 | `NeoAI:tool_execution_error` | 返回错误结果给模型 |
| 网络错误 | `NeoAI:generation_error` | 自动重试 |

---

## 设计原则

1. **事件驱动**：模块间通过 Neovim 原生事件通信，避免直接依赖
2. **职责单一**：每个模块只负责一个领域的功能
3. **配置集中**：所有配置在 `default_config.lua` 中统一管理
4. **防抖持久化**：会话和树数据使用 500ms 防抖保存
5. **向后兼容**：会话加载兼容新旧两种文件格式
6. **安全调用**：跨模块依赖使用 `pcall` 保护
