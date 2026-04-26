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
│   ├── history_manager.lua     # 历史管理器（JSON数组存储，树形会话结构）
│   │
|   ├── state.lua               # 统一状态管理器（集中管理共享状态）
|   │
│   ├── config/
│   │   └── keymap_manager.lua  # 键位配置管理器
│   │
│   ├── session/                # 旧版会话管理（已废弃，保留向后兼容）
│   │   ├── session_manager.lua # 会话管理器
│   │   ├── branch_manager.lua  # 分支管理
│   │   ├── message_manager.lua # 消息管理
│   │   ├── data_operations.lua # 数据操作工具
│   │   └── tree_manager.lua    # 树形结构管理器
│   │
│   ├── ai/                     # AI 交互
│   │   ├── ai_engine.lua       # AI 引擎主入口（事件驱动，协调子模块）
│   │   ├── http_client.lua     # HTTP 客户端（流式/非流式请求）
│   │   ├── request_adapter.lua # 请求适配器（多 API 提供商格式转换）
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
│   │   ├── history_tree.lua    # 历史树组件（基于 history_manager）
│   │   ├── reasoning_display.lua# 思考过程显示
│   │   └── virtual_input.lua   # 虚拟输入框组件
│   │
│   └── handlers/               # 事件处理器
│       ├── tree_handlers.lua   # 树界面处理器（基于 history_manager）
│       └── chat_handlers.lua   # 聊天界面处理器（基于 history_manager）
│
├── tools/                      # 工具系统
│   ├── init.lua                # 工具模块入口
│   ├── tool_registry.lua       # 工具注册表
│   ├── tool_executor.lua       # 工具执行器
│   ├── tool_validator.lua      # 工具验证器
│   │
│   └── builtin/                # 内置工具
│       ├── file_tools.lua      # 文件操作工具
│       ├── general_tools.lua   # 通用工具
│       ├── log_tools.lua       # 日志工具
│       └── tool_helpers.lua    # 工具定义辅助模块（define_tool）
│
├── utils/                      # 工具库
│   ├── init.lua                # 工具模块入口（自动加载 5 个子模块）
│   ├── common.lua              # 通用工具函数（深拷贝等）
│   ├── table_utils.lua         # 表操作
│   ├── file_utils.lua          # 文件操作
│   ├── logger.lua              # 日志系统
│   ├── json.lua                # JSON 编解码
│   ├── skiplist.lua            # 跳表数据结构
│   ├── async_worker.lua        # 异步工作器
│   └── thread_utils.lua        # 线程工具
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
default_config.process_config(config)     ← 一步完成：验证 → 合并 → 清理 → 初始化
    │
    ▼
core.initialize(config)                   ← 初始化核心模块
  ├── state_manager.initialize(config)    ← 统一状态管理器
  ├── keymap_manager.initialize()         ← 键位配置
  ├── ai_engine.initialize()              ← AI 引擎
  └── history_manager.initialize()        ← 历史管理器（唯一数据源）
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
  ├── _load_builtin_tools()               ← 加载内置工具
  └── _load_external_tools()              ← 加载外部工具（可选）
    │
    ▼
ai_engine.set_tools(tools_map)           ← 将工具注册表注入 AI 引擎
    │
    ▼
async_worker.initialize()               ← 初始化异步工作器
    │
    ▼
register_commands()                       ← 注册 :NeoAIOpen 等命令
  ├── :NeoAIOpen                          ← 打开主界面
  ├── :NeoAIClose                         ← 关闭所有界面
  ├── :NeoAITree                          ← 打开树界面
  ├── :NeoAIChat                          ← 打开聊天界面
  ├── :NeoAIKeymaps                       ← 显示键位配置
  └── :NeoAIChatStatus                    ← 显示聊天窗口状态
    │
    ▼
register_global_keymaps()                 ← 注册全局快捷键
  ├── open_tree                           ← 打开树界面
  ├── open_chat                           ← 打开聊天界面
  ├── close_all                           ← 关闭所有窗口
  └── toggle_ui                           ← 切换 UI 显示
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
  - 初始化顺序：`default_config` → `core` → `ui` → `tools` → 工具注入 AI 引擎 → `async_worker` → 注册命令 → 注册快捷键
- 提供对外接口：`open_neoai()`, `close_all()`, `get_session_manager()`, `get_ai_engine()`, `get_tools()`, `get_keymap_manager()`
- 注册命令：`:NeoAIOpen`, `:NeoAIClose`, `:NeoAITree`, `:NeoAIChat`, `:NeoAIKeymaps`, `:NeoAIChatStatus`
- 注册全局快捷键：`open_tree`, `open_chat`, `close_all`, `toggle_ui`（由 `config.keymaps.global` 配置）
- 工具系统初始化后，将工具注册表注入 AI 引擎（`ai_engine.set_tools(tools_map)`），使工具定义能注入到请求中

### `default_config.lua` — 配置管理

|- 定义 `DEFAULT_CONFIG` 默认配置表
|- `process_config(config)` — **一步完成**：验证 → 合并 → 清理 → 初始化（替代旧的 validate_config + merge_defaults + sanitize_config）
|- `get(key)`, `set(key, value)` — 点号路径配置存取
|- `validate()` — 完整配置验证
|- `export()`, `import()` — 配置导入导出
|- `get_preset(scenario)` / `get_scenario_candidates(scenario)` — 获取场景 AI 配置
|- `get_available_models()` / `get_available_scenarios()` — 获取可用模型/场景列表

### `core/init.lua` — 核心模块入口

|- 初始化 `keymap_manager`, `ai_engine`, `history_manager`（旧版 `session_manager` 已废弃）
|- 所有模块间通信通过 Neovim 原生事件系统（`nvim_exec_autocmds`/`nvim_create_autocmd`）
|- 提供 `get_ai_engine()`, `get_keymap_manager()`, `get_history_manager()`, `get_config()`
|- `get_config()` 通过 `state_manager.get_config()` 获取配置，不再维护独立配置引用
|- `get_session_manager()` 保留向后兼容，返回 `nil`

### `core/state.lua` — 统一状态管理器

|- 集中管理所有模块的共享状态，消除分散在各 `init.lua` 中的重复 `state` 表
|- `initialize(config)` — 初始化状态，保存配置引用
|- `get_config()` — 获取完整配置
|- `get_config_value(key, default)` — 点号路径配置存取
|- `is_initialized()` — 检查是否已初始化
|- 各模块通过 `state_manager.get_config()` 获取配置，不再各自维护 `state.config`

### `core/history_manager.lua` — 历史管理器（新版，唯一数据源）

- 使用 JSON 数组文件存储，文件格式：`[\n{...},\n{...}\n]`
- 初始创建空文件内容为 `[\n]`
- 添加会话时覆写最后一行 `]` 为 `,新内容\n]`

**会话对象结构**（扁平结构，一轮对话一个会话，无 `rounds` 数组）：

```json
{
  "id": "session_1",
  "name": "会话名称",
  "created_at": 1234567890,
  "updated_at": 1234567890,
  "is_root": true,
  "child_ids": ["session_2", "session_3"],
  "user": "用户消息",
  "assistant": ["{\"content\":\"AI回复\",\"reasoning_content\":\"思考文本\"}"],
  "timestamp": 1234567890,
  "usage": {
    "prompt_tokens": 24,
    "completion_tokens": 770,
    "total_tokens": 794
  }
}
```

**字段说明**：

- `user` — 用户消息文本
- `assistant` — AI 回复的 JSON 字符串数组，每个元素是一轮 AI 回复，包含 `content`（回复内容）和 `reasoning_content`（深度思考文本）。支持工具调用时的多轮对话
- `timestamp` — 本轮对话的时间戳
- `usage` — token 用量统计（从流式响应结束时的 `data.usage` 提取）

**关键方法**：

- `create_session(name, is_root, parent_id)` — 创建会话（根/子），自动将新会话ID添加到父会话的 `child_ids`
- `get_session(session_id)` / `get_current_session()` — 获取会话
- `set_current_session(session_id)` — 设置当前会话
- `delete_session(session_id)` — 删除会话（递归删除子会话）
- `add_round(session_id, user_msg, assistant_msg, usage)` — 添加一轮对话（直接设置 `user`/`assistant`/`timestamp`/`usage`），`assistant` 为数组
- `update_last_assistant(session_id, content)` — 流式更新当前会话的AI回复（追加到 assistant 数组末尾）
- `add_assistant_entry(session_id, assistant_entry)` — 追加一轮 assistant 回复到数组末尾（用于工具调用时的多轮对话）
- `update_usage(session_id, usage)` — 更新当前会话的 token 用量
- `get_messages(session_id)` — 展平为 role/content 列表（自动解析 assistant 数组）
- `get_root_sessions()` — 获取所有根会话
- `get_tree()` — 获取树结构（先遍历根会话，再递归子会话）
- `get_context_and_new_parent(session_id)` — 沿子会话链捋上下文
- `find_parent_session(session_id)` — 查找某个会话的父会话ID
- `cleanup_orphans()` — 清理未被引用的子会话
- `rename_session(session_id, new_name)` — 重命名会话

**树结构生成规则**（`get_tree()`）：

1. 先调用 `cleanup_orphans()` 清理孤儿
2. 遍历所有 `is_root=true` 的会话
3. 对每个会话递归构建子节点
4. 如果某会话有多个子会话，自动生成虚拟分支节点（`__branch_xxx`，`is_virtual=true`，不存文件）
5. 如果只有一个子会话，直接作为子节点

**上下文路径规则**（`get_context_and_new_parent()`）：

1. 从当前会话开始
2. 如果无子会话 → 当前会话的消息作为上文，在此新开子会话
3. 如果只有一个子会话 → 继续往下捋
4. 如果有多个子会话 → 当前会话的消息作为上文，在此新开子会话

### `core/session/session_manager.lua` — 旧版会话管理器（已废弃）

- 保留向后兼容，新代码应使用 `history_manager`
- 旧版数据格式：`{ "1": { id: 1, messages: [...], branches: {...}, current_branch_id: "..." } }`
- 新版数据格式：`[{ id: "session_1", is_root: true, child_ids: [...], rounds: [...] }]`
- 已移除 `event_bus` 兼容层，子模块初始化不再传递 `event_bus` 参数

### `core/session/tree_manager.lua` — 旧版树形结构管理器（已废弃）

- 保留向后兼容
- 新版树结构由 `history_manager.get_tree()` 直接生成
- 已移除 `event_bus` 兼容层

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

- `<CR>` — 选择会话 → `tree_handlers.handle_enter()` → 打开聊天
- `n` — 在当前会话下新建子会话（分支）：
  1. 获取当前光标选中的会话
  2. 在选中会话下创建新子会话（自动添加到父会话的 `child_ids`）
  3. 跳转到聊天界面
  4. 聊天界面自动加载从根到选中会话的整条路径作为上文（选中会话作为最后一轮上文）
- `N` — 新建根会话
- `d` — 删除当前会话
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
chat_handlers.send_message(content)            ← 发送消息
    │
    ├── history_manager.get_or_create_current_session()
    ├── history_manager.get_context_and_new_parent()  ← 获取上下文路径
    ├── 如果当前会话已有内容 → 创建新会话
    │   ├── 查找当前会话的父会话（find_parent_session）
    │   ├── 新会话挂在父会话下（和当前会话同级），实现同级分支
    │   └── 如果当前会话是根会话，新会话挂在当前会话下
    ├── 保存用户消息到 pending 队列（等待AI响应完成后一次性写入）
    ├── chat_window.add_message("user", ...)    ← 更新UI
    │
    ▼
触发 NeoAI:message_sent 事件
    │
    ▼
chat_handlers._trigger_ai_response()           ← 自动触发AI响应
    │
    ▼
ai_engine.generate_response(messages, params)  ← 开始生成
    │
    ▼
AI响应完成后：
    ├── 将用户消息和AI回复一起写入历史文件
    │   ├── assistant 字段为数组，每个元素是一轮 AI 回复
    │   ├── 支持工具调用时的多轮对话（通过 add_assistant_entry 追加）
    │   └── 自动触发防抖保存（500ms）
    └── 更新聊天界面显示
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
    ├── 从 history_manager 获取消息历史
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

| 模式    | 创建方式                 | 关闭方式         | 适用场景   |
| ------- | ------------------------ | ---------------- | ---------- |
| `float` | `nvim_open_win` 浮动窗口 | `nvim_win_close` | 临时交互   |
| `tab`   | `tabnew` 新标签页        | `tabclose`       | 长时间工作 |
| `split` | `vsplit`/`split` 分割    | `nvim_win_close` | 并排查看   |

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
    history_manager._save()
        │
        ▼
    收集所有会话为数组，按 created_at 排序
        │
        ▼
    逐行写入 JSON 数组文件：
        [
        {session_1_json},
        {session_2_json},
        ]
        │
        ▼
    最后一行始终是 "]"

加载：
    history_manager._load()
        │
        ▼
    读取 sessions.json
        │
        ├── 空文件或 "[]" → 空会话列表
        ├── 解析 JSON 数组
        └── 转换为 id → session 映射

孤儿清理：
    history_manager.cleanup_orphans()
        │
        ▼
    从所有根会话出发，标记所有可达会话
        │
        ▼
    删除未被标记的会话
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

- **启动链**：`NeoAI:session_created` → `NeoAI:round_added`
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

| 错误类型     | 触发事件                     | 处理方式                 |
| ------------ | ---------------------------- | ------------------------ |
| 请求错误     | `NeoAI:generation_error`     | 最多重试 3 次，间隔 1 秒 |
| 流式错误     | `NeoAI:stream_error`         | 最多重试 3 次            |
| 工具执行错误 | `NeoAI:tool_execution_error` | 返回错误结果给模型       |
| 网络错误     | `NeoAI:generation_error`     | 自动重试                 |

---

## 设计原则

1. **事件驱动**：模块间通过 Neovim 原生事件系统（`nvim_exec_autocmds`/`nvim_create_autocmd`）通信，避免直接依赖，已移除旧 `event_bus` 兼容层
2. **职责单一**：每个模块只负责一个领域的功能
3. **配置集中**：所有配置在 `default_config.lua` 中统一管理，`process_config()` 一步完成验证→合并→清理→初始化
4. **状态统一**：`core/state.lua` 集中管理共享状态，各模块不再维护独立 `state` 表
5. **防抖持久化**：会话数据使用 500ms 防抖保存
6. **单一数据源**：`history_manager` 是唯一的会话数据源，旧版 `session_manager` 保留向后兼容
7. **安全调用**：跨模块依赖使用 `pcall` 保护

---

## 会话数据结构详解

### JSON 文件格式

文件 `sessions.json` 是一个 JSON 数组，每个元素是一个扁平会话（一轮对话一个会话）：

```json
[
  {
    "id": "session_1",
    "name": "根会话",
    "created_at": 1234567890,
    "updated_at": 1234567890,
    "is_root": true,
    "child_ids": ["session_2"],
    "user": "你好",
    "assistant": [
      "{\"content\":\"你好！有什么可以帮助你的？\",\"reasoning_content\":\"思考文本\"}"
    ],
    "timestamp": 1234567890,
    "usage": {
      "prompt_tokens": 24,
      "completion_tokens": 770,
      "total_tokens": 794
    }
  },
  {
    "id": "session_2",
    "name": "子会话-根会话",
    "created_at": 1234567891,
    "updated_at": 1234567891,
    "is_root": false,
    "child_ids": [],
    "user": "",
    "assistant": [],
    "timestamp": null,
    "usage": {}
  }
]
```

**注意**：`assistant` 字段存储的是 JSON 字符串数组，每个元素是一轮 AI 回复（包含 `content` 和 `reasoning_content`）。支持工具调用时的多轮对话。`get_messages()` 会自动解析每个 JSON 元素并提取 `content` 字段作为消息内容。

### 树渲染规则

`history_manager.get_tree()` 返回的树结构（每个节点代表一轮对话）：

```
=== NeoAI 会话树 ===

📂 聊天会话
│  ├─ 👤你好 | 🤖你好！有什么可以帮你的吗？无…
│  📂 聊天会话
│  │  └─ 👤给我讲一个笑话… | 🤖为什么程序…
│  └─ 👤给我讲一个故事…
📂 聊天会话
   └─ 👤你是谁 | 🤖你好！我是 Claud…

```

**渲染规则**（由 `history_tree.lua` 实现）：

- `get_tree()` 返回**原始树结构**，不创建虚拟节点
  - 每个节点包含：`id`, `session_id`, `name`, `round_text`, `children`
  - 递归构建：从根会话开始，遍历 `child_ids` 递归添加子节点
- 树节点显示轮次预览（`build_round_text()` 生成，用户消息和AI回复的前 20 个字符）
- 虚拟分支节点（`__branch_xxx`，`is_virtual=true`）由 UI 层 `history_tree.lua` 在渲染时创建，不存文件

### 上下文路径规则

`get_context_and_new_parent(session_id)` 的实现逻辑：

```
选中会话 A
  │
  ├── 第一步：从 A 向上回溯到根，收集路径上所有会话的消息
  │   （按从根到 A 的顺序，作为上下文消息列表）
  │
  ├── 第二步：从 A 沿子会话链向下走，确定新会话的挂载点
  │   ├── A 无子会话（链尾）→ A 本身作为 new_parent_id
  │   ├── A 有唯一子会话 B → 继续沿链向下
  │   │   ├── B 无子会话（链尾）→ B 作为 new_parent_id
  │   │   ├── B 有唯一子会话 C → 继续...
  │   │   └── B 有多个子会话（分支点）→ B 作为 new_parent_id
  │   └── A 有多个子会话（分支点）→ A 本身作为 new_parent_id
  │
  └── 返回：context_msgs（从根到 A 的所有消息）, new_parent_id（挂载点）
```

**关键区别**：

- 上下文消息**从根到选中会话**整条路径收集，而非仅选中会话本身
- 新会话挂载点**沿子会话链向下**寻找链尾或分支点，而非在选中会话下直接创建
