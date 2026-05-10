# NeoAI 架构设计指南

## 目录结构

```
NeoAI/
├── init.lua                    # 主入口文件：setup/命令注册/全局快捷键
├── default_config.lua          # 默认配置定义（仅定义，不处理逻辑）
├── styleGuide.md               # 本文件：架构设计文档
│
├── core/                       # 核心业务逻辑
│   ├── init.lua                # 核心模块入口，协调子模块初始化
│   ├── events.lua              # 事件常量定义（统一管理所有事件名）
│   ├── shutdown_flag.lua       # 全局关闭标志（避免退出时死锁）
│   │
│   ├── config/                 # 配置管理
│   │   ├── init.lua            # 配置模块入口（统一导出子模块）
│   │   ├── merger.lua          # 配置合并器（验证→合并→清理，一步完成）
│   │   ├── keymap_manager.lua  # 键位配置管理器
│   │   └── state.lua           # 协程上下文管理器（状态切片功能已移除）
│   │
│   ├── history/                # 历史管理（替代旧 core/history_manager.lua）
│   │   ├── manager.lua         # 会话数据 CRUD 操作、消息管理
│   │   ├── persistence.lua     # 文件序列化/反序列化、写入队列、事务性保存
│   │   ├── cache.lua           # 树结构缓存、列表缓存、round_text 缓存
│   │   ├── saver.lua           # 事件驱动的队列异步写入器（监听 AI 事件自动保存）
│   │   └── message_builder.lua # 消息构建器（会话展平为 role/content 列表）
│   │
│   └── ai/                     # AI 交互
│       ├── init.lua            # AI 模块入口
│       ├── ai_engine.lua       # AI 引擎（事件驱动，协调子模块）
│       ├── chat_service.lua    # 后端聊天服务（前后端分离的后端入口）
│       ├── http_client.lua     # HTTP 客户端（流式/非流式请求）
│       ├── http_utils.lua      # HTTP 工具函数（请求去重、URL 编码等）
│       ├── request_adapter.lua # 请求适配器（多 API 提供商格式转换）
│       ├── request_builder.lua # 请求构建器（构建 API 请求体、格式化消息）
│       ├── response_retry.lua  # 响应重试模块（检测异常并触发重试）
│       ├── session_manager.lua # 工具循环会话管理器（管理工具循环的会话状态）
│       ├── stream_processor.lua# 流式处理器（处理流式数据块、reasoning 节流）
│       ├── generation_handler.lua # 生成完成处理器（usage 累积、消息构建）
│       ├── tool_orchestrator.lua# 工具调用编排器
│       └── sub_agent_engine.lua# 子 agent 引擎（独立 AI 引擎实例）
│
├── ui/                         # 用户界面
│   ├── init.lua                # UI 模块入口，协调窗口/组件/处理器
│   ├── ui_events.lua           # UI 事件监听器（从 ui/init.lua 提取）
│   │
│   ├── window/                 # 窗口管理
│   │   ├── window_manager.lua  # 窗口管理器（float/tab/split 三种模式）
│   │   ├── chat_window.lua     # 聊天窗口
│   │   └── tree_window.lua     # 树状图窗口
│   │
│   ├── components/             # UI 组件
│   │   ├── input_handler.lua   # 输入处理器
│   │   ├── history_tree.lua    # 历史树组件（基于 history/manager）
│   │   ├── reasoning_display.lua# 思考过程显示
│   │   ├── virtual_input.lua   # 虚拟输入框组件
│   │   ├── approval_config_editor.lua # 审批配置编辑器
│   │   └── sub_agent_monitor.lua # 子 agent 状态监控悬浮窗
│   │
│   └── handlers/               # 事件处理器
│       ├── tree_handlers.lua   # 树界面处理器（基于 history/manager）
│       └── chat_handlers.lua   # 聊天界面处理器（通过 chat_service 与后端交互）
│
├── tools/                      # 工具系统
│   ├── init.lua                # 工具模块入口
│   ├── approval_handler.lua    # 工具审批处理器（审批队列管理+UI 渲染）
│   ├── approval_state.lua      # 审批配置共享状态
│   ├── tool_registry.lua       # 工具注册表
│   ├── tool_executor.lua       # 工具执行器
│   ├── tool_validator.lua      # 工具验证器
│   ├── tool_pack.lua           # 工具包管理（按 category 自动分组）
│   │
│   └── builtin/                # 内置工具
│       ├── file_tools.lua      # 文件操作工具
│       ├── general_tools.lua   # 通用工具
│       ├── log_tools.lua       # 日志工具
│       ├── neovim_lsp.lua      # LSP 工具
│       ├── neovim_tree.lua     # 文件树工具
│       ├── shell_tools.lua     # Shell 命令执行工具（伪终端+PID监控）
│       ├── plan_executor.lua   # 执行计划工具
│       └── tool_helpers.lua    # 工具定义辅助模块（define_tool）
│
├── utils/                      # 工具库
│   ├── init.lua                # 工具模块入口（自动加载子模块）
│   ├── common.lua              # 通用工具函数（深拷贝等）
│   ├── table_utils.lua         # 表操作
│   ├── file_utils.lua          # 文件操作
│   ├── logger.lua              # 日志系统
│   ├── json.lua                # JSON 编解码
│   ├── skiplist.lua            # 跳表数据结构
│   ├── async_worker.lua        # 异步工作器（含 thread_utils 内联功能）
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
└── tests/                      # 测试
    ├── init.lua                # 测试入口（断言工具、测试运行器）
    ├── test_config.lua         # 配置测试：default_config, state, config_merger
    ├── test_events_keymaps.lua # 事件和键位测试：event_constants, keymap_manager
    ├── test_history.lua        # 历史测试：history_manager, cache, persistence, saver
    ├── test_http_client.lua    # HTTP 客户端测试（含特殊字符编码测试）
    ├── test_init_modules.lua   # 模块初始化测试
    ├── test_tools.lua          # 工具测试：tool_registry, tool_executor, tool_validator, tool_pack
    ├── test_utils.lua          # 工具库测试：utils_common, utils_logger, utils_json 等
    ├── test_ai_core.lua        # AI 核心测试：ai_engine, chat_service, response_retry
    ├── test_sub_agent.lua      # 子 agent 创建与管理测试
    ├── test_sub_agent_debug.lua# 子 agent 调试测试
    ├── test_integration.lua    # 端到端集成测试
    ├── test_user_data.lua      # 用户数据处理测试
    ├── test_user_data2.lua     # 用户数据处理测试 2
    ├── test_user_data3.lua     # 用户数据处理测试 3
    └── test_tree_connectors.lua# 树连接器测试
```

---

## 启动流程

```
用户调用 setup(config)
    │
    ▼
config_merger.process_config(config)      ← 一步完成：验证 → 合并 → 清理 → 初始化日志
    │
    ▼
core.initialize(config)                   ← 初始化核心模块
  ├── config_module.initialize(config)    ← 配置模块（keymap_manager + merger.set_config）
  ├── ai_engine.initialize()              ← AI 引擎（初始化子模块、注册事件监听）
  ├── history_manager.initialize()        ← 历史管理器（唯一数据源，含 cache/persistence/saver）
  └── chat_service.initialize()           ← 后端聊天服务（前后端分离）
    │
    ▼
ui.initialize(config)                     ← 初始化 UI 模块
  ├── window_manager.initialize()
  ├── input_handler.initialize()
  ├── history_tree.initialize()
  ├── reasoning_display.initialize()
  ├── sub_agent_monitor.initialize()
  ├── tree_window.initialize()
  ├── chat_window.initialize()
  ├── tree_handlers.initialize()
  ├── chat_handlers.initialize()
  └── ui_events.register_listeners()      ← 注册 UI 事件监听
    │
    ▼
tools.initialize(config)                  ← 初始化工具系统（传入完整合并配置）
  ├── tool_registry.initialize()
  ├── tool_executor.initialize()
  ├── tool_validator.initialize()
  ├── vim.schedule → _load_builtin_tools()  ← 延迟加载内置工具（不阻塞初始化）
  │   └── 完成后自动调用 tool_pack.initialize() 刷新工具包分组
  │   └── 重新应用审批配置覆盖
  └── _load_external_tools()              ← 加载外部工具（可选）
    │
    ▼
vim.schedule → ai_engine.set_tools(tools_map)  ← 延迟注入工具注册表到 AI 引擎
    │
    ▼
register_commands()                       ← 注册 :NeoAIOpen 等命令
  ├── :NeoAIOpen                          ← 打开主界面（默认聊天）
  ├── :NeoAIClose                         ← 关闭所有界面
  ├── :NeoAITree                          ← 打开树界面
  ├── :NeoAIChat                          ← 打开聊天界面
  ├── :NeoAIKeymaps                       ← 显示键位配置
  ├── :NeoAIChatStatus                    ← 显示聊天窗口状态
  └── :NeoAITest                          ← 运行测试
    │
    ▼
register_global_keymaps()                 ← 注册全局快捷键
  ├── open_tree                           ← 打开树界面
  ├── open_chat                           ← 打开聊天界面
  ├── close_all                           ← 关闭所有窗口
  └── toggle_ui                           ← 切换 UI 显示
    │
    ▼
_auto_run_tests(config)                   ← 可选：VimEnter 后延迟运行测试
```

**关键变更**：

1. `config_merger.process_config()` 一步完成验证→合并→清理→初始化日志
2. `core/init.lua` 的 `get_config()` 直接返回闭包内的 `_config`，不再通过 state_manager 获取
3. 配置模块初始化时调用 `merger.set_config(config)` 保存完整配置引用，不再使用 state slice 注册
4. 内置工具加载和工具注入 AI 引擎均使用 `vim.schedule` **延迟执行**，不阻塞主初始化流程
5. 退出事件由 `history/manager.lua` 内部的 `VimLeavePre` 统一处理（同步保存），`init.lua` 不再重复注册
6. `config_module.initialize()` 中不再调用 `state.initialize()`（state 的状态切片功能已移除）
7. AI 引擎使用闭包内 `state` 表管理内部状态（`active_generations`, `is_generating` 等），共享数据通过协程上下文传递

---

### 配置示例（多提供商架构）

```lua
require("NeoAI").setup({
  ai = {
    default = "balanced",
    providers = {
      deepseek = {
        api_type = "openai",
        base_url = "https://api.deepseek.com/chat/completions",
        api_key = os.getenv("DEEPSEEK_API_KEY"),
        models = { "deepseek-v4-flash", "deepseek-v4-pro" },
      },
      openai = {
        api_type = "openai",
        base_url = "https://api.openai.com/v1/chat/completions",
        api_key = os.getenv("OPENAI_API_KEY"),
        models = { "gpt-4o", "gpt-4o-mini" },
      },
    },
    scenarios = {
      chat = {
        { provider = "deepseek", model_name = "deepseek-v4-flash", temperature = 0.7 },
      },
      coding = {
        { provider = "deepseek", model_name = "deepseek-v4-pro", temperature = 0.2 },
      },
    },
  },
  ui = {
    default_ui = "tree",
    window_mode = "tab",
    window = { width = 80, height = 20, border = "rounded" },
    split = { size = 80, chat_direction = "right", tree_direction = "right" },
  },
  session = {
    auto_save = true,
    auto_naming = true,
    save_path = vim.fn.stdpath("cache") .. "/NeoAI",
    max_history_per_session = 1000,
  },
})
```

---

## 核心模块职责

### `init.lua` — 主入口

- `setup(user_config)` — 初始化所有模块、注册命令和快捷键
  - 初始化顺序：`config_merger.process_config` → `core.initialize` → `ui.initialize` → `tools.initialize` → 延迟注入工具 → 注册命令 → 注册快捷键 → `_auto_run_tests`
- 提供对外接口：`open_neoai()`, `close_all()`, `get_session_manager()`, `get_ai_engine()`, `get_tools()`, `get_keymap_manager()`
- 注册命令：`:NeoAIOpen`, `:NeoAIClose`, `:NeoAITree`, `:NeoAIChat`, `:NeoAIKeymaps`, `:NeoAIChatStatus`, `:NeoAITest`
- 注册全局快捷键：`open_tree`, `open_chat`, `close_all`, `toggle_ui`（由 `config.keymaps.global` 配置）
- 工具系统初始化后，通过 `vim.schedule` 延迟将工具注册表注入 AI 引擎（`ai_engine.set_tools(tools_map)`）
- 支持 `config.test.auto_test` 自动运行测试（VimEnter 后延迟执行）
- 注册 `BufRead` 自动命令确保 `.log` 和 `sessions.json` 文件编码为 utf-8
- 使用 `config_merger.process_config()` 替代直接调用 `default_config`，`default_config.lua` 只负责定义默认配置
- 退出事件由 `history/manager.lua` 内部的 `VimLeavePre` 统一处理，`init.lua` 不再重复注册

### `default_config.lua` — 默认配置定义

|- 定义 `DEFAULT_CONFIG` 默认配置表（仅定义，不处理逻辑）
|- `get_default_config()` — 返回默认配置的深拷贝
|- 配置结构：
| - `ai.providers` — 多提供商定义（deepseek/openai/anthropic/google/groq/together/openrouter/siliconflow/moonshot/zhipu/baidu/aliyun/stepfun）
| - `ai.scenarios` — 场景预设（naming/chat/reasoning/coding/tools/agent），每个场景可指定多个候选
| - `ui` — UI 配置（含 split 方向、tree 折叠选项）
| - `keymaps` — 键位配置（global/tree/chat 三种上下文）
| - `session` — 会话配置（含 auto_naming）
| - `tools` — 工具配置（含 approval 审批配置、tool_overrides）
| - `log` — 日志配置（级别/路径/格式/大小/备份数）
| - `test` — 测试配置

### `core/config/merger.lua` — 配置合并器

|- 职责：将用户配置与默认配置合并，生成完整配置
|- `process_config(user_config)` — **一步完成**：验证 → 合并 → 清理 → 初始化日志（替代旧的 validate_config + merge_defaults + sanitize_config）
|- `get_preset(scenario)` — 获取指定场景的第一个可用 AI 配置
|- `get_scenario_candidates(scenario)` — 获取指定场景的 AI 候选列表
|- `get_available_models()` — 获取所有可用模型（遍历所有提供商）
|- `set_config(config)` — 保存完整配置引用（供子模块读取）
|- 验证规则：
| - AI 配置：验证 providers 和 scenarios 结构，过滤无效场景名
| - UI 配置：验证 default_ui（tree/chat）、window_mode（float/tab/split）、窗口尺寸
| - 键位配置：验证上下文（global/tree/chat）
| - 日志配置：验证级别/文件大小/备份数/布尔值
| - 会话配置：验证 max_history_per_session 为正数
|- 合并规则：
| - 数字/字符串/布尔值：用户值覆盖默认值
| - 表结构：保留默认表结构，递归合并内部字段
| - 新增字段（默认中没有的）：给出提示但不添加
| - scenarios 特殊处理：合并到默认场景候选的对应字段
| - tools.approval 为 free_form 表，深层合并

### `core/init.lua` — 核心模块入口

|- 初始化 `config_module`（含 keymap_manager + merger.set_config）、`ai_engine`、`history_manager`（新版 history/）、`chat_service`
|- 所有模块间通信通过 Neovim 原生事件系统（`nvim_exec_autocmds`/`nvim_create_autocmd`）
|- 提供 `get_ai_engine()`, `get_keymap_manager()`, `get_history_manager()`, `get_config()`
|- `get_config()` 返回闭包内 `_config` 引用（由 setup 传入的完整合并配置）
|- `get_session_manager()` 保留向后兼容，返回 `nil`

### `core/config/init.lua` — 配置模块入口

|- 统一导出配置相关的子模块
|- `initialize(config)` — 初始化 keymap_manager 并调用 merger.set_config(config) 保存配置

### `core/config/state.lua` — 协程上下文管理器

|- **注意**：状态切片功能已移除，各模块使用自己的闭包 state 表管理内部状态
|- 配置数据通过 `core/init.lua` 的 `get_config()` 读取，不再通过 state_manager 获取
|- 提供**协程上下文**机制：协程安全的闭包上下文隔离（session_id、tools 等），协程内所有模块通过 `get_shared()` 直接读写共享表
|- 提供**事件触发辅助**：封装 Neovim 原生 User 事件，提供一致的触发接口
|- 核心 API：
| - `create_context(data)` — 创建协程上下文（自动绑定到当前协程）
| - `get_shared()` — 获取协程内全局共享表
| - `set_shared(key, value)` — 设置共享值
| - `get_shared_value(key, default)` — 获取共享值
| - `get_current_context()` — 获取当前协程上下文
| - `with_context(ctx, fn)` — 在指定上下文中执行函数
| - `fire_event(event_name, data)` — 触发 Neovim User 事件
|- 协程内推荐共享变量：session_id, generation_id, window_id, model_index, ai_preset, options, messages, accumulated_usage, last_reasoning, stop_requested, user_cancelled

### `core/shutdown_flag.lua` — 全局关闭标志

|- 所有模块通过此模块检查 Neovim 是否正在关闭
|- 在 `VimLeavePre` 中设置标志后，所有 `vim.schedule` 回调应检查此标志并立即返回
|- 避免在退出过程中执行 Neovim API 调用导致卡死
|- `set()`, `is_set()`, `reset()`（测试用）

### `core/events.lua` — 事件常量定义

|- 所有事件统一在此定义，各模块通过引用常量使用，禁止硬编码事件字符串
|- 命名规范：按功能分组，常量名 = 事件用途（大写+下划线）
|- 事件分组：AI 生成、流式处理、推理/思考、工具相关（含审批）、会话、分支、树节点、消息、窗口/UI、渲染、悬浮文本、模型切换、配置、插件状态、备份、响应构建、请求构建、日志、自定义/命令、聊天消息流、历史管理器、UI 内部

### `core/ai/init.lua` — AI 模块入口

|- 统一导出 AI 模块的所有子模块：ai_engine, http_client, request_adapter, tool_orchestrator, chat_service
|- `initialize(options)` — 初始化 chat_service
|- `shutdown()` — 关闭所有 AI 子模块

### `core/ai/ai_engine.lua` — AI 引擎（精简版）

|- **核心职责**：AI 生成流程编排、事件调度、工具管理
|- 请求构建委托给 `request_builder`
|- 流式处理委托给 `stream_processor`
|- 重试逻辑委托给 `response_retry`
|- 工具循环委托给 `tool_orchestrator`
|- HTTP 请求委托给 `http_client`
|- 生成完成处理委托给 `generation_handler`
|- 工具循环会话管理委托给 `session_manager`
|- 子 agent 请求委托给 `sub_agent_engine`
|- 使用闭包内 `state` 表管理内部状态（initialized, is_generating, active_generations 等）
|- 协程上下文：`generate_response()` 创建协程上下文，将共享变量写入 `shared` 表，后续所有子调用通过 `state_manager.get_shared()` 直接访问
|- `set_tools(tools)` — 将工具注册表注入 AI 引擎，同时注册到 tool_registry 并更新 request_builder 的工具定义
|- `cancel_generation()` — 取消当前生成，设置 shared 表的 stop_requested/user_cancelled 标志，取消所有 HTTP 请求
|- 幂等保护：`_cancel_processed` 标志防止多次按停止键时重复触发取消事件

### `core/ai/chat_service.lua` — 后端聊天服务

|- **前后端分离架构中的后端服务层**
|- 前端（chat_window.lua, chat_handlers.lua）通过此模块与 AI 引擎交互
|- 职责：
| 1. 统一的消息发送/响应接口（`send_message()`）
| 2. 会话管理（创建、切换、删除）
| 3. 消息历史管理（读写、上下文构建、原始消息获取）
| 4. AI 生成请求调度（调用 ai_engine.generate_response）
| 5. 事件分发（向后端模块广播事件，不直接通知 UI）
|- `send_message(params)` 封装完整流程：获取/创建会话 → 构建上下文 → 调用 AI 引擎 → 通过事件通知前端
|- `cancel_generation()` — 直接取消 HTTP 请求并设置停止标志，然后触发取消事件
|- 使用闭包内 `state` 表管理状态（initialized, pending_user_messages）

### `core/ai/http_utils.lua` — HTTP 工具函数

|- 从 `http_client.lua` 提取的公共函数
|- 请求去重：基于 generation_id + suffix 的哈希比对，TTL 3 秒
|- URL 编码/解码
|- JSON 处理辅助

### `core/ai/request_builder.lua` — 请求构建器

|- 构建 AI API 请求体
|- 格式化消息（role/content 列表）
|- 构建工具结果消息
|- 使用闭包内变量管理 tool_definitions 和 first_request 状态
|- tool_call_counter 是模块内部计数器，保留在闭包内

### `core/ai/stream_processor.lua` — 流式处理器

|- 创建流式处理器实例
|- 处理流式数据块
|- 管理 reasoning 节流（80ms 间隔，避免高频事件触发）
|- 过滤有效工具调用

### `core/ai/generation_handler.lua` — 生成完成处理器

|- 从 `ai_engine.lua` 提取，减轻其负担
|- 累积 usage 信息（支持多种字段名：prompt_tokens/promptTokens/input_tokens 等）
|- 消息构建
|- 事件触发

### `core/ai/session_manager.lua` — 工具循环会话管理器

|- 从 `tool_orchestrator.lua` 提取，减轻其负担
|- 创建会话状态对象（session_id, window_id, generation_id, phase 等）
|- 会话状态注册、查询、清理
|- `sync_stop_from_shared()` — 从 shared 表同步 stop_requested 到会话状态

### `core/ai/sub_agent_engine.lua` — 子 agent 引擎

|- 独立的 AI 引擎实例，用于执行子 agent 任务
|- 拥有独立的会话管理、工具调用循环和状态管理
|- 通过事件系统与主 agent 通信

### `core/ai/response_retry.lua` — 响应重试模块

|- 检测 AI 响应异常（内容重复/截断/空响应）并触发重试
|- 支持指数退避策略：1s, 2s, 4s, 8s, 16s
|- `max_retries = 5`
|- `is_summary_content(content)` — 判断 AI 返回的内容是否为总结性质（含总结类关键词时视为正常结束）
|- `is_repeated_content(content)` — 检测内容重复
|- `is_truncated_content(content)` — 检测内容截断
|- `detect_abnormal_response(content, tool_calls, opts)` — 统一异常检测入口

### `core/history/` — 新版历史管理（替代旧 `core/history_manager.lua`）

**拆分原则**：将旧版单一 `history_manager.lua` 拆分为五个职责清晰的子模块：

| 模块                  | 职责                                  | 关键方法                                                                                                 |
| --------------------- | ------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `manager.lua`         | 会话 CRUD、消息管理、树结构生成       | `create_session`, `get_session`, `delete_session`, `add_round`, `get_tree`, `get_context_and_new_parent` |
| `persistence.lua`     | 文件序列化/反序列化、写入队列         | `serialize`, `deserialize`, `enqueue_write`, `flush`                                                     |
| `cache.lua`           | 树结构缓存、列表缓存、round_text 缓存 | `invalidate_all`, `invalidate_round_text`, `get_cached_tree`, `get_cached_list`                          |
| `saver.lua`           | 事件驱动的队列异步写入                | 监听 `GENERATION_COMPLETED` 等事件，自动触发保存                                                         |
| `message_builder.lua` | 消息展平、round text 构建             | `session_to_messages`, `build_round_text`, `build_context_messages`                                      |

**数据流**：

```
manager (CRUD) → cache (缓存) → persistence (序列化+文件写入)
     ↑                                  ↓
   saver (监听事件) ←──────────── persistence (文件读取→反序列化→manager)
```

### `core/history/manager.lua` — 历史管理器（新版，唯一数据源）

- 使用 JSON 数组文件存储，文件格式：`[\n{...},\n{...}\n]`
- 初始创建空文件内容为 `[\n]`
- 添加会话时覆写最后一行 `]` 为 `,新内容\n]`
- 持久化委托给 `history_persistence` 模块
- 缓存委托给 `history_cache` 模块
- 会话保存委托给 `history_saver` 模块（事件驱动、队列异步写入）
- 消息展平委托给 `message_builder` 模块
- 使用闭包内 `state` 表管理状态（sessions, current_session_id 等）

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
- `get_messages(session_id)` — 展平为 role/content 列表（委托给 message_builder）
- `get_root_sessions()` — 获取所有根会话
- `get_tree()` — 获取树结构（先遍历根会话，再递归子会话）
- `get_context_and_new_parent(session_id)` — 沿子会话链捋上下文
- `find_parent_session(session_id)` — 查找某个会话的父会话ID
- `cleanup_orphans()` — 清理未被引用的子会话
- `rename_session(session_id, new_name)` — 重命名会话
- `has_file_changed()` — 检查文件是否有外部变更
- `reload_from_file()` — 从文件重新加载会话

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

### `core/history/persistence.lua` — 历史持久化模块

|- 文件序列化/反序列化
|- 写入队列（FIFO），保证原子性和实时保存
|- 使用 `async_worker` 的任务队列
|- 防抖机制：300ms 内合并多次写入
|- `serialize(sessions)` — 序列化所有会话为 JSON 字符串
|- `deserialize()` — 从文件读取并反序列化
|- `enqueue_write(type, data, callback)` — 将写入任务加入队列
|- `flush()` — 强制刷新所有待处理写入

### `core/history/cache.lua` — 历史缓存模块

|- 树结构缓存、列表缓存、round_text 缓存
|- 缓存失效由 `history_manager` 在数据变更时通知
|- `invalidate_all()` — 标记所有缓存为脏
|- `invalidate_round_text(session_id)` — 清除指定会话的 round_text 缓存
|- `get_cached_tree()` / `get_cached_list()` — 获取缓存（脏时自动重建）

### `core/history/saver.lua` — 会话历史保存器

|- 通过事件监听收集会话数据，使用队列与异步写入保证原子性
|- 监听的事件：
| - `GENERATION_COMPLETED`: AI 生成完成（含本轮 AI 数据）
| - `TOOL_EXECUTION_COMPLETED`: 工具执行完成
| - `TOOL_EXECUTION_ERROR`: 工具执行出错
| - `USER_MESSAGE_SENT`: 用户消息已发送
|- 按会话分组去重合并，300ms 防抖
|- 批量刷新定时器，定时处理队列中的保存任务

### `core/history/message_builder.lua` — 消息构建器

|- 从 `history/manager.lua` 提取，减轻其负担
|- `session_to_messages(session)` — 将单个会话的消息展平为 role/content 列表
|- `build_round_text(session)` — 构建树节点显示的轮次预览文本
|- `build_context_messages(session_ids)` — 从多个会话构建上下文消息列表

### `core/session/` — 旧版会话管理（已删除）

- 旧版 `session_manager.lua`, `branch_manager.lua`, `message_manager.lua`, `data_operations.lua`, `tree_manager.lua` 已全部删除
- 新代码统一使用 `core/history/manager.lua` 作为唯一数据源
- 树结构由 `manager.get_tree()` 直接生成

### `tools/approval_handler.lua` — 工具审批处理器（含 UI）

|- 从 `tool_executor.lua` 提取，减轻其负担
|- **合并了原 `ui/components/tool_approval.lua` 的 UI 渲染逻辑**，审批窗口的创建、渲染、按键映射内聚于此
|- 管理工具调用的审批队列
|- 显示审批对话框（含工具选择、模糊匹配过滤）
|- 处理审批结果（确认、确认所有、取消、取消并说明原因）
|- 审批流程（三级条件，平级评估）：
| 1. 允许所有：用户已选择"允许所有"，覆盖其他条件
| 2. 路径安全 AND 参数安全：路径和参数都在允许列表内时自动通过
| 3. 路径或参数不安全：需要用户审批确认
|- `enqueue(item)` — 将工具加入审批队列
|- `process_queue()` — 处理审批队列
|- `set_allow_all(tool_name)` / `is_allow_all(tool_name)` — 管理"允许所有"标记
|- 暂停/恢复机制：`pause_timer()` / `resume_timer()`，审批窗口打开时暂停超时计时

### `tools/approval_state.lua` — 审批配置共享状态

|- 所有模块通过此模块读写同一份审批配置
|- 使用模块级表，不依赖协程上下文
|- 提供 `set_tool_config()`, `get_tool_config()`, `get_all_tool_configs()` 等 API

### `tools/tool_pack.lua` — 工具包管理模块

|- 从 `builtin/*.lua` 模块动态扫描工具定义，根据工具的 `category` 字段自动分组
|- 工具包定义：`pack_name`, `display_name`, `icon`, `tools`, `order`
|- 分类配置：
| - `file` → "文件操作" 📁 (order 1)
| - `lsp` → "代码分析" 🔍 (order 2)
| - `treesitter` → "语法分析" 🌳 (order 3)
| - `log` → "日志" 📝 (order 4)
| - `system` → "系统" ⚙️ (order 5)
| - `plan` → "执行计划" 📋 (order 6)
| - `uncategorized` → "工具调用" 🔧 (order 99)
|- 内置工具加载完成后自动刷新工具包分组（`tool_pack.initialize()`）

### `ui/ui_events.lua` — UI 事件监听器

|- 从 `ui/init.lua` 提取，减轻其负担
|- 管理 UI 模块的事件监听
|- `register_listeners(state, callbacks)` — 注册 UI 事件监听（SESSION_CREATED, SESSION_LOADED, SESSION_DELETED, SESSION_CHANGED, BRANCH_CREATED, BRANCH_DELETED, BRANCH_SWITCHED, MESSAGE_ADDED, ROUND_ADDED, SESSION_RENAMED 等）

### `ui/components/approval_config_editor.lua` — 审批配置编辑器

|- 从 `chat_window.lua` 分离，负责展示和修改工具的运行时审批配置
|- 使用 `vim.ui.select` 进行交互
|- 支持修改：behavior（auto_approve / require_user）、allowed_directories、allowed_param_groups
|- 修改结果通过 `approval_state.set_tool_config()` 保存

### `ui/components/sub_agent_monitor.lua` — 子 agent 监控悬浮窗

|- 实时显示所有子 agent 的执行状态、进度、工具调用等信息
|- 支持状态图标：⏳ 运行中、✅ 完成、⛔ 拒绝、⌛ 超时、❌ 错误

---

## 关键流程

### 1. 树界面操作流程

```
:NeoAIOpen
    │
    ▼
ui.open_tree_ui()
    │
    ├── 检查文件是否有变化 → 有则 reload_from_file()
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

树界面按键（由 `tree_window.set_keymaps()` 设置，通过 `keymap_manager` 配置）：

- `<CR>` — 选择会话 → `tree_handlers.handle_enter()` → 打开聊天
- `n` — 在当前会话下新建子会话（分支）：
  1. 获取当前光标选中的会话
  2. 在选中会话下创建新子会话（自动添加到父会话的 `child_ids`）
  3. 跳转到聊天界面
  4. 聊天界面自动加载从根到选中会话的整条路径作为上文（选中会话作为最后一轮上文）
- `N` — 新建根会话
- `d` — 删除对话（单个会话）
- `D` — 删除分支（递归删除子会话）
- `o` — 展开节点
- `O` — 折叠节点

### 2. 聊天界面消息流程（前后端分离）

```
用户输入
    │
    ▼
input_handler.handle_input()                   ← 处理用户输入
    │
    ▼
chat_handlers.send_message(content)            ← 前端发送消息
    │
    ├── 管理待写入队列（pending_user_messages）
    ├── chat_window.add_message("user", ...)    ← 更新UI
    │
    ▼
chat_service.send_message(params)              ← 后端统一入口
    │
    ├── history_manager.get_or_create_current_session()
    ├── history_manager.get_context_and_new_parent()  ← 获取上下文路径
    ├── 如果当前会话已有内容 → 创建新分支会话
    ├── 保存用户消息到 pending 队列
    ├── 构建上下文消息列表
    │
    ▼
ai_engine.generate_response(messages, params)  ← AI 引擎生成
    │
    ▼
AI响应完成后（GENERATION_COMPLETED 事件）：
    ├── chat_handlers._handle_response_complete()  ← 前端监听事件
    │   ├── 将用户消息和AI回复一起写入历史文件
    │   └── 自动触发防抖保存（由 history/saver.lua 处理，300ms）
    └── chat_window 更新 UI 显示
```

**前后端职责划分**：

- **前端**（`chat_handlers.lua`）：管理待写入队列、更新 UI、监听结果事件写入历史
- **后端**（`chat_service.lua`）：会话管理、上下文构建、AI 生成调度
- **通信方式**：前端调用 `chat_service.send_message()`，后端通过 `GENERATION_COMPLETED` 事件通知前端
- **持久化**：由 `history/saver.lua` 通过事件驱动自动完成，前端无需手动调用保存

聊天界面按键（由 `chat_window.set_keymaps()` 设置，通过 `keymap_manager` 配置）：

- `i` — 进入插入模式
- `q` — 关闭聊天窗口
- `r` — 刷新聊天窗口
- `<CR>`（普通模式） / `<C-s>`（插入模式） — 发送消息
- `<Esc>` — 取消生成
- `e` — 编辑消息
- `dd` — 删除消息
- `<C-u>` — 向上滚动
- `<C-d>` — 向下滚动
- `r` — 切换思考过程显示
- `m` — 切换模型
- `<CR>` — 新建行
- `<C-u>` — 清空输入
- `<C-a>` — 工具审批

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
    ├── 创建协程上下文（写入 shared 表：session_id, generation_id 等）
    ├── request_builder.format_messages()      ← 格式化消息
    ├── request_builder.build_request()        ← 构建请求体（含工具信息）
    ├── 触发 NeoAI:generation_started
    │
    ▼
    ├── 流式模式 (request.stream == true)
    │   ├── 触发 NeoAI:stream_started
    │   ├── stream_processor.create_processor()
    │   ├── http_client.send_stream_request()
    │   │   ├── on_chunk → _handle_stream_chunk()
    │   │   │   ├── stream_processor.process_chunk()
    │   │   │   ├── 触发 NeoAI:reasoning_content (思考内容，80ms 节流)
    │   │   │   ├── 触发 NeoAI:stream_chunk (普通内容)
    │   │   │   └── 触发 NeoAI:tool_call_detected (工具调用)
    │   │   └── on_complete → _handle_stream_end()
    │   │       ├── 检测异常响应（response_retry.detect_abnormal_response）
    │   │       ├── 如有工具调用 → tool_orchestrator.start_async_loop()
    │   │       ├── 否则触发 NeoAI:stream_completed
    │   │       └── _finalize_generation()
    │   └── on_error → 重试或触发错误事件
    │
    └── 非流式模式
        ├── http_client.send_request()
        ├── handle_ai_response()
        │   ├── 提取 content / reasoning_content / tool_calls
        │   ├── 检测异常响应
        │   ├── 如有工具调用 → tool_orchestrator.start_async_loop()
        │   └── _finalize_generation()
        └── 错误处理 → 重试或触发错误事件
```

### 4. 工具调用循环

```
模型返回 tool_calls
    │
    ▼
tool_orchestrator.start_async_loop()
    │
    ├── 触发 NeoAI:tool_loop_started
    │
    ▼
对每个 tool_call:
    ├── 审批检查（如启用审批模式）
    │   ├── approval_handler.process_queue()
    │   ├── 显示审批对话框（确认/确认所有/取消/取消并说明）
    │   └── 通过后继续执行
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
    ├── 清理重复 tool 消息
    ├── 如 is_final_round → 清理末尾 tool_calls 避免 API 报错
    ├── 更新 shared 表中的数据
    ├── 构建请求（如 is_final_round 则移除 tools/tool_choice）
    └── 继续 generate_response()  ← 再次调用模型
```

### 5. 思考过程显示流程

```
接收到 reasoning_content
    │
    ▼
reasoning_display.show()                      ← 打开悬浮窗口
    │
    ▼
流式更新 reasoning_content（80ms 节流）
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

### 8. 工具审批

工具审批由 `approval_handler.lua` 统一管理（含 UI 渲染）：

- 用户按 `<C-a>` 打开审批悬浮窗
- 显示当前待审批工具的详细信息（工具名称、参数、路径）
- 支持操作：确认一次（`<CR>`）、确认所有（`A`）、取消（`<Esc>`）、取消并说明原因（`C`）
- 配置文件支持 `tools.approval.tool_overrides` 预设各工具的审批行为
- `approval_config_editor.lua` 提供运行时修改审批配置的交互界面
- 审批配置通过 `approval_state.lua` 在所有模块间共享

### 9. 子 agent 监控

`sub_agent_monitor.lua` 组件提供子 agent 状态监控：

- 实时显示所有子 agent 的执行状态、进度
- 状态图标：⏳ 运行中、✅ 完成、⛔ 拒绝、⌛ 超时、❌ 错误
- 定时自动刷新显示内容

### 10. 会话持久化

```
保存流程（由 history/saver.lua 事件驱动）：
    GENERATION_COMPLETED / TOOL_EXECUTION_COMPLETED 等事件
        │
        ▼
    saver 监听事件 → 加入保存队列（按会话分组，300ms 防抖）
        │
        ▼
    persistence.enqueue_write("update", data)  ← 写入队列（FIFO）
        │
        ▼
    async_worker 处理写入任务
        │
        ▼
    序列化为 JSON 数组文件：
        [
        {session_1_json},
        {session_2_json},
        ]
        │
        ▼
    最后一行始终是 "]"

加载流程：
    history_manager._load()
        │
        ▼
    persistence.deserialize()
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
- **工具审批链**：`NeoAI:tool_approved` → `NeoAI:tool_approval_config_changed`
- **窗口管理链**：`NeoAI:chat_window_opened` → `NeoAI:chat_window_closed`

### 协程上下文通信

除了事件机制，AI 生成流程中的模块间通信还通过**协程上下文**实现：

```lua
-- 在 ai_engine.generate_response() 中创建上下文
local ctx = state_manager.create_context({
  session_id = session_id,
  generation_id = generation_id,
  window_id = window_id,
  model_index = model_index,
  ai_preset = ai_preset,
  options = options,
  messages = messages,
})

-- 写入 shared 表
local shared = ctx:shared()
shared.session_id = session_id
shared.generation_id = generation_id
-- ...

-- 在协程上下文中执行请求
state_manager.with_context(ctx, function()
  -- 子模块（http_client, stream_processor, tool_orchestrator 等）
  -- 通过 state_manager.get_shared() 直接访问共享变量
  local shared = state_manager.get_shared()
  local sid = shared.session_id
  local gen_id = shared.generation_id
end)
```

---

## 配置项参考

### AI 配置 (`config.ai`)

```lua
{
  default = "balanced",             -- 默认使用的预设名称
  providers = {                     -- 多提供商定义
    deepseek = {
      api_type = "openai",
      base_url = "https://api.deepseek.com/chat/completions",
      api_key = os.getenv("DEEPSEEK_API_KEY") or "",
      models = { "deepseek-v4-flash", "deepseek-v4-pro" },
    },
    openai = {
      api_type = "openai",
      base_url = "https://api.openai.com/v1/chat/completions",
      api_key = os.getenv("OPENAI_API_KEY") or "",
      models = { "gpt-4o", "gpt-4o-mini" },
    },
    -- 还支持: anthropic, google, groq, together, openrouter,
    -- siliconflow, moonshot, zhipu, baidu, aliyun, stepfun
  },
  scenarios = {                     -- 场景预设
    naming = {                      -- 窗口命名：快速低延迟
      { provider = "deepseek", model_name = "deepseek-chat",
        temperature = 0.3, max_tokens = 50, stream = false, timeout = 15000 },
    },
    chat = {                        -- 聊天：平衡速度与质量
      { provider = "deepseek", model_name = "deepseek-v4-flash",
        temperature = 0.7, max_tokens = 4096, stream = true, timeout = 60000 },
    },
    reasoning = {                   -- 思考：深度推理
      { provider = "deepseek", model_name = "deepseek-v4-pro",
        temperature = 0.7, max_tokens = 8192, stream = true, timeout = 120000 },
    },
    coding = {                      -- 编码：高质量代码
      { provider = "deepseek", model_name = "deepseek-v4-pro",
        temperature = 0.2, max_tokens = 8192, stream = true, timeout = 120000 },
    },
    tools = {                       -- 工具执行：快速响应
      { provider = "deepseek", model_name = "deepseek-v4-flash",
        temperature = 0.3, max_tokens = 1024, stream = true, timeout = 30000 },
    },
    agent = {                       -- 子 agent
      { provider = "deepseek", model_name = "deepseek-v4-pro",
        temperature = 0.7, max_tokens = 4096, stream = true, timeout = 60000 },
    },
  },
  stream = true,                    -- 全局默认：流式响应
  timeout = 60000,                  -- 全局默认：超时时间（毫秒）
  reasoning_enabled = true,         -- 是否启用深度思考模式
  system_prompt = "你是一个AI编程助手...", -- 全局默认：系统提示词
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
  split = {                         -- 分割窗口配置
    size = 80,                      -- 分割大小（列数或百分比）
    chat_direction = "right",       -- chat 窗口分割方向
    tree_direction = "right",       -- tree 窗口分割方向
  },
  tree = {                          -- 树窗口配置
    foldenable = false,
    foldmethod = "manual",
    foldcolumn = "0",
    foldlevel = 99,
  },
}
```

### 会话配置 (`config.session`)

```lua
{
  auto_save = true,                                         -- 自动保存
  auto_naming = true,                                       -- 自动命名会话
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
  approval = {                      -- 工具审批配置
    default_auto_allow = false,     -- 默认是否自动允许
    allowed_directories = {},       -- 默认允许的目录列表
    allowed_param_groups = {},      -- 默认允许的参数组
    tool_overrides = {              -- 各工具单独审批配置覆盖
      read_file = { auto_allow = true },
      edit_file = { auto_allow = false },
      run_command = {
        auto_allow = false,
        allowed_directories = { "./" },
        allowed_param_groups = { "ls", "find", "grep" },
      },
      -- ... 更多工具覆盖
    },
  },
}
```

### 日志配置 (`config.log`)

```lua
{
  level = "WARN",                   -- 日志级别: DEBUG, INFO, WARN, ERROR, FATAL
  output_path = "/path/to/neoai.log", -- 输出文件路径
  format = "[{time}] [{level}] {message}", -- 日志格式模板
  max_file_size = 10485760,         -- 最大文件大小（字节），默认 10MB
  max_backups = 5,                  -- 最大备份文件数量
  verbose = false,                  -- 是否启用详细输出
  print_debug = false,              -- 是否启用调试打印到控制台
}
```

### 测试配置 (`config.test`)

```lua
{
  auto_test = false,                -- 是否在 VimEnter 后自动运行测试
  delay_ms = 1500,                  -- 延迟时间（毫秒）
}
```

---

## 错误处理

| 错误类型     | 触发事件                     | 处理方式                               |
| ------------ | ---------------------------- | -------------------------------------- |
| 请求错误     | `NeoAI:generation_error`     | 最多重试 3 次，间隔 1 秒               |
| 流式错误     | `NeoAI:stream_error`         | 最多重试 3 次                          |
| 工具执行错误 | `NeoAI:tool_execution_error` | 返回错误结果给模型                     |
| 网络错误     | `NeoAI:generation_error`     | 自动重试                               |
| 响应异常     | `NeoAI:generation_error`     | 指数退避重试（由 response_retry 处理） |

---

## 设计原则

1. **事件驱动**：模块间通过 Neovim 原生事件系统（`nvim_exec_autocmds`/`nvim_create_autocmd`）通信，避免直接依赖
2. **职责单一**：每个模块只负责一个领域的功能，AI 引擎已拆分为 ai_engine/http_utils/request_builder/stream_processor/generation_handler/session_manager/sub_agent_engine 等子模块
3. **配置集中**：所有配置在 `default_config.lua` 中定义，`core/config/merger.lua` 的 `process_config()` 一步完成验证→合并→清理→初始化日志
4. **闭包状态隔离**：每个模块使用自己的闭包 `state` 表管理内部状态，不再依赖全局状态切片。协程内通过 `state_manager.create_context()` 的 shared 表共享临时数据
5. **前后端分离**：`core/ai/chat_service.lua` 作为统一后端入口，前端只调用 chat_service 的公开方法，不直接调用 ai_engine 或 history_manager
6. **防抖持久化**：会话数据使用 `history/saver.lua` 的 300ms 防抖保存（事件驱动），按会话分组去重合并
7. **单一数据源**：`core/history/manager.lua` 是唯一的会话数据源，旧版 `session_manager` 已删除
8. **安全调用**：跨模块依赖使用 `pcall` 保护
9. **延迟加载**：内置工具和工具注入 AI 引擎使用 `vim.schedule` 延迟执行，不阻塞主初始化流程；内置工具加载完成后自动刷新 tool_pack 分组并重新应用审批配置
10. **退出安全**：`core/shutdown_flag.lua` 统一管理关闭标志，避免退出时死锁
11. **职责拆分**：历史管理拆分为 manager/cache/persistence/saver/message_builder 五个子模块，各司其职
12. **多提供商架构**：AI 配置支持多提供商（deepseek/openai/anthropic/google 等），通过场景预设（scenarios）按用途分配不同模型
13. **配置合并器**：`core/config/merger.lua` 承担配置处理职责，`default_config.lua` 仅定义默认值，职责分离
14. **协程上下文隔离**：AI 生成流程使用协程上下文（`state_manager.create_context`）隔离共享状态，协程内模块通过 `get_shared()` 直接访问，无需函数参数传递
15. **审批集中化**：工具审批功能（含 UI 渲染）集中在 `approval_handler.lua`，审批配置状态通过 `approval_state.lua` 在所有模块间共享，`approval_config_editor.lua` 提供运行时修改能力
16. **幂等取消**：`cancel_generation()` 使用 `_cancel_processed` 标志防止多次触发，避免按多次停止键时重复执行取消逻辑

---

## 代码风格约定

### 1. 模块结构

每个 Lua 模块遵循统一的组织结构：

```lua
--- 模块描述（LuaDoc 风格）
--- 职责：xxx

local M = {}

local xxx = require("NeoAI.module.xxx")  -- 依赖导入（按文件名排序）

-- ========== 闭包内私有状态 ==========
local state = {
  initialized = false,
  -- 其他状态字段
}

-- ========== 辅助函数 ==========

local function _helper_func(...)
  -- ...
end

-- ========== 初始化 ==========

function M.initialize(options)
  if state.initialized then return M end  -- 幂等保护
  -- ...
end

-- ========== 公共 API ==========

function M.public_func(...)
  -- ...
end

return M
```

**规则**：

- 文件顶部使用 `---` LuaDoc 注释描述模块职责
- `local M =` 作为公共接口表
- `require` 按模块名称字母顺序排列
- 使用 `-- ========== 区域标题 ==========` 划分代码区域（等号数量与标题等长）
- 私有状态放在模块级闭包变量中（`local state`，`local _xxx`）
- 私有函数以下划线 `_` 或 `local function` 标识
- 结尾 `return M`

### 2. 命名规范

| 类别           | 规范                 | 示例                                     |
| -------------- | -------------------- | ---------------------------------------- |
| 模块公共接口表 | `M`                  | `local M =`                              |
| 公共函数       | 驼峰式               | `function M.generate_response()`         |
| 私有函数       | 下划线前缀 + 驼峰    | `local function _handle_stream_chunk()`  |
| 局部变量       | snake_case           | `local session_id`, `local tool_name`    |
| 全局常量       | 大写+下划线          | `LOG_LEVELS`, `VALID_ENUMS`              |
| 事件常量       | 大写+下划线          | `GENERATION_STARTED`, `STREAM_CHUNK`     |
| 事件名模式串   | `NeoAI:xxx_xxx`      | `"NeoAI:generation_started"`             |
| 闭包状态表     | `state`              | `local state = { initialized = false }`  |
| 模块级私有变量 | `_` 前缀             | `local _tools =`, `local _config = nil`  |
| 布尔查询函数   | `is_xxx` / `has_xxx` | `is_initialized()`, `has_file_changed()` |

### 3. LuaDoc 注释规范

使用 emmyLua 风格的 `---` 注释，以下是标准格式：

```lua
--- 函数描述（简短说明功能）
--- @param param1 type 参数1说明
--- @param param2 type|nil 可选参数说明
--- @return type 返回值说明
function M.some_function(param1, param2)
  -- ...
end
```

**规则**：

- 公共函数必须有 LuaDoc 注释
- 参数类型使用 Lua 类型名（`string`, `number`, `boolean`, `table`, `function`, `nil`）
- 复合类型用 `|` 分隔：`string|nil`
- 表类型可标注字段：`table { key = type, ... }`
- 私有函数可根据复杂程度选择性添加 LuaDoc
- 内部辅助函数使用 `--` 单行注释

### 4. 注释风格

```lua
-- 文件顶部：模块功能描述
--- NeoAI 核心模块入口
--- 职责：初始化并统一导出核心子模块

-- 区域分隔：等号数量与标题等长
-- ========== 初始化 ==========
-- ========== 公共 API ==========
-- ========== 会话 CRUD ==========

-- 代码行内注释：描述逻辑意图
local warn_level = vim.log.levels and vim.log.levels.WARN or "WARN"  -- 兼容性保护

-- 重要注释：使用 --- 突出
--- 注意：状态切片功能已移除，各模块使用自己的闭包 state 表管理内部状态

-- TODO/FIXME 标记
-- TODO: 后续需要优化性能
-- FIXME: 此处存在边界情况未处理
```

### 5. 模块初始化模式

所有需要初始化的模块遵循统一模式：

```lua
local state = { initialized = false, config = nil }

function M.initialize(options)
  if state.initialized then return M end  -- 幂等保护
  state.config = options or {}
  -- 初始化逻辑
  state.initialized = true
  return M
end

-- 守卫函数（可选）
local function guard()
  if not state.initialized then
    error("模块未初始化，请先调用 M.initialize()")
  end
end
```

### 6. 错误处理

```lua
-- 跨模块调用使用 pcall 保护
local ok, result = pcall(require, "NeoAI.some.module")
if not ok then
  logger.error("加载失败: " .. tostring(result))
  return fallback_value
end

-- 用户通知使用 vim.notify
vim.notify("[NeoAI] 消息内容", vim.log.levels.WARN)

-- 日志记录
logger.info("格式化消息: %s %d", string_var, num_var)
logger.debug("[模块名] 调试信息")
logger.error("错误信息: " .. tostring(err))
```

### 7. 工具模块约定

每个内置工具模块遵循的约定：

```lua
-- 文件顶部描述
-- Lua xxx 工具模块
-- 工具函数签名：func(args, on_success, on_error)

local M = {}

local define_tool = require("NeoAI.tools.builtin.tool_helpers").define_tool

-- 工具定义
function M.get_tools()
  return {
    define_tool({
      name = "tool_name",
      description = "工具描述",
      category = "file",  -- 分类：file/lsp/treesitter/log/system/plan
      parameters = {
        type = "object",
        properties = {
          param1 = { type = "string", description = "参数描述" },
        },
        required = { "param1" },
      },
      func = function(args, on_success, on_error)
        -- 异步实现，通过回调返回结果
      end,
      approval = {
        auto_allow = true,  -- true=自动允许，false=需用户审批
      },
    }),
  }
end

return M
```

### 8. 事件定义与使用

```lua
-- core/events.lua 中统一定义
local M = {}
M.GENERATION_STARTED = "NeoAI:generation_started"
-- 使用位置注释：-- 使用位置: ai_engine.lua, chat_window.lua

-- 触发事件
vim.api.nvim_exec_autocmds("User", {
  pattern = Events.GENERATION_STARTED,
  data = { session_id = sid, generation_id = gid },
})

-- 或使用辅助函数
state_manager.fire_event(Events.GENERATION_STARTED, { session_id = sid })

-- 监听事件
vim.api.nvim_create_autocmd("User", {
  pattern = Events.STREAM_CHUNK,
  callback = function(args)
    local data = args.data
    -- 处理事件
  end,
})
```

### 9. 文件与目录命名

| 类别         | 规范         | 示例                                 |
| ------------ | ------------ | ------------------------------------ |
| 文件名       | snake_case   | `ai_engine.lua`, `tool_registry.lua` |
| 目录名       | 小写英文     | `core/`, `tools/`, `builtin/`        |
| 测试文件     | `test_` 前缀 | `test_ai_core.lua`, `test_tools.lua` |
| 内置工具模块 | 语义化名称   | `file_tools.lua`, `shell_tools.lua`  |
| 配置文件     | 全小写       | `default_config.lua`                 |

### 10. 异步回调模式

工具和 I/O 操作使用回调模式，不阻塞主线程：

```lua
-- 异步工具函数签名
-- func(args, on_success, on_error)

local function my_tool(args, on_success, on_error)
  vim.uv.fs_open(filepath, "r", 438, function(open_err, fd)
    if open_err then
      if on_error then on_error(open_err) end
      return
    end
    -- 异步操作
    if on_success then on_success(result) end
  end)
end
```

### 11. 模块间依赖原则

```
init.lua
  ├── core/           ← 核心业务逻辑，不依赖 UI/tools
  ├── ui/             ← UI 层，可依赖 core（通过 chat_service 间接）
  ├── tools/          ← 工具系统，可依赖 core（通过 history_manager）
  └── utils/          ← 工具库，不依赖任何其他模块
```

- `core/` 模块**不依赖** `ui/` 或 `tools/`
- `ui/` 模块通过 `core/ai/chat_service` 与后端交互，不直接调用 `ai_engine` 或 `history_manager`
- `tools/` 模块通过 `tool_registry` 注册，通过 `tool_executor` 执行
- `utils/` 为纯工具函数，**不依赖**项目其他模块
- 跨模块依赖统一使用 `pcall` 保护，避免加载失败导致崩溃

### 12. 常用代码模式速查

| 模式         | 代码                                                                       |
| ------------ | -------------------------------------------------------------------------- |
| 幂等初始化   | `if state.initialized then return M end`                                   |
| 守卫检查     | `if not state.initialized then error("...") end`                           |
| 空表判断     | `if next(t) == nil then`                                                   |
| 深拷贝       | `vim.deepcopy(obj)`                                                        |
| 表合并       | `vim.tbl_extend("force", default, user)`                                   |
| 安全事件触发 | `pcall(vim.api.nvim_exec_autocmds, "User", { pattern = ..., data = ... })` |
| 延迟执行     | `vim.schedule(function() ... end)`                                         |
| 字符串格式化 | `string.format("值: %s, 数量: %d", str, num)`                              |
| 模块 require | `local xxx = require("NeoAI.模块路径")`                                    |
| 类型检查保护 | `vim.log.levels and vim.log.levels.WARN or "WARN"`                         |

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

**注意**：`assistant` 字段存储的是 JSON 字符串数组，每个元素是一轮 AI 回复（包含 `content` 和 `reasoning_content`）。支持工具调用时的多轮对话。`get_messages()` 委托给 `message_builder.session_to_messages()`，自动解析每个 JSON 元素并提取 `content` 字段作为消息内容。

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
- 树节点显示轮次预览（`message_builder.build_round_text()` 生成，用户消息和AI回复的前 20 个字符）
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

---

_Last updated: 2026-06-16_
