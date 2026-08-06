# NeoAI 架构设计指南

> 版本：2.0 | 设计哲学：**隔离、简洁、异步优先**

---

## 一、设计哲学

### 核心原则

1. **环境隔离（Isolation First）**
   - 每次打开对话窗口 → 创建全新的会话上下文，零残留
   - 每次创建子 Agent → 独立沙箱，不继承父 Agent 的任何运行时状态
   - 模块间通过**不可变数据**通信，禁止共享可变全局状态

2. **依赖单向（Unidirectional Dependency）**
   - 依赖层级严格单向：`utils → core → services → ui/tools`
   - 禁止循环依赖、禁止跨层穿透调用
   - 模块只暴露**接口（Interface）**，隐藏实现细节

3. **异步优先（Async by Default）**
   - 所有 I/O 操作（网络、文件、模型列表获取）均为异步
   - 启动时不阻塞 Neovim，所有外部资源懒加载 + 后台拉取
   - 模型列表从官网 API 异步获取，本地配置仅作缓存和 fallback

4. **可替换性（Replaceability）**
   - 每个模块定义清晰的接口契约，可独立替换实现
   - 不绑定特定 LLM 厂商，适配器层统一抽象

---

## 二、目录结构

```
NeoAI/
├── init.lua                    # 主入口：极薄，仅做 setup + 路由
├── default_config.lua          # 默认配置（纯数据，零逻辑）
├── styleGuide.md               # 本文件
│
├── kernel/                     # 内核层（最底层，零业务依赖）
│   ├── init.lua               # 内核初始化
│   ├── events.lua            # 事件常量注册表
│   ├── lifecycle.lua          # 生命周期管理（启动/关闭/信号）
│   ├── config_store.lua       # 配置存储（替代 merger + state 混合体）
│   └── logger.lua            # 日志（从 utils 提升至此）
│
├── core/                       # 核心业务层
│   ├── init.lua               # 核心模块编排
│   ├── session/               # 会话管理
│   │   ├── session.lua        # 会话对象（纯净数据结构 + 方法）
│   │   ├── session_store.lua  # 会话持久化（CRUD + 序列化）
│   │   └── context_builder.lua# 上下文构建（替代 get_context_and_new_parent）
│   │
│   ├── model/                 # 模型管理层（新增，核心重构点）
│   │   ├── registry.lua       # 模型注册表（运行时动态更新）
│   │   ├── fetcher.lua       # 模型列表异步获取器
│   │   ├── adapter.lua        # 多提供商协议适配
│   │   └── cache.lua         # 模型列表本地缓存
│   │
│   └── agent/                 # Agent 引擎
│       ├── agent.lua           # Agent 对象（每次对话新建实例）
│       ├── runtime.lua         # Agent 运行时（生命周期 + 状态机）
│       ├── request.lua         # 请求构建 + 发送 + 重试
│       ├── stream.lua          # 流式响应处理
│       └── tool_loop.lua      # 工具调用循环
│
├── services/                   # 服务层（连接 core 与 ui/tools）
│   ├── chat_service.lua       # 聊天服务（前后端桥梁）
│   ├── tool_service.lua       # 工具服务（审批 + 调度 + 执行）
│   └── model_service.lua      # 模型服务（供 UI 选择/切换模型）
│
├── ui/                         # 表现层
│   ├── init.lua               # UI 编排
│   ├── window/                # 窗口管理
│   │   ├── manager.lua        # 窗口管理器（float/tab/split）
│   │   ├── chat_view.lua     # 聊天视图
│   │   └── tree_view.lua     # 会话树视图
│   ├── components/            # 可复用组件
│   │   ├── input_box.lua     # 输入框
│   │   ├── message_list.lua  # 消息列表渲染
│   │   ├── reasoning_panel.lua# 思考过程面板
│   │   ├── model_picker.lua  # 模型选择器（异步加载列表）
│   │   ├── tool_approval.lua # 工具审批弹窗
│   │   ├── sub_agent_dock.lua# 子 Agent 监控面板
│   │   └── markdown_view.lua # Markdown 渲染器
│   └── keymap.lua            # 按键映射（统一配置入口）
│
├── tools/                      # 工具系统
│   ├── init.lua               # 工具系统入口
│   ├── registry.lua           # 工具注册表
│   ├── executor.lua           # 工具执行器
│   ├── validator.lua          # 参数校验
│   ├── packer.lua             # 工具分组打包
│   └── builtin/               # 内置工具（每个文件独立，互不引用）
│       ├── file_ops.lua
│       ├── shell.lua
│       ├── git_ops.lua
│       ├── lsp_ops.lua
│       ├── plan.lua
│       └── tool_helpers.lua
│
├── utils/                      # 纯工具库（无业务依赖）
│   ├── init.lua
│   ├── async.lua              # 异步原语（Promise/Future/Deferred）
│   ├── json.lua
│   ├── http.lua               # HTTP 客户端（替代散落的 curl 调用）
│   ├── fs.lua                 # 文件系统操作
│   └── stringx.lua            # 字符串扩展
│
├── docs/
└── tests/
    ├── init.lua
    ├── test_kernel.lua
    ├── test_session.lua
    ├── test_model_registry.lua
    ├── test_agent.lua
    ├── test_tools.lua
    ├── test_services.lua
    └── test_integration.lua
```

---

## 三、启动流程

```
setup(user_config)
  │
  ▼
config_store.load(user_config)         ← 纯函数：merge + validate，返回不可变配置
  │
  ▼
kernel.bootstrap()                    ← 初始化事件常量表、日志、生命周期
  │
  ▼
注册命令 + 全局快捷键（仅此而已）
  │
  ▼
返回
```

**核心变化**：`setup()` 不再初始化任何业务模块。所有重活在首次使用时按需懒加载。

---

## 四、关键架构决策

### 决策 1：每次对话 = 全新 Agent 实例

**旧架构问题**：协程上下文、闭包 state、shared 表、active_generations……
层层嵌套，状态泄漏风险极高，取消/重试逻辑脆弱。

**新架构**：

```
打开对话窗口
  │
  ▼
agent_runtime.create(config)           ← 创建全新 Agent 实例
  │
  ├── 分配唯一 agent_id
  ├── 创建独立消息队列（空）
  ├── 绑定独立工具作用域
  ├── 绑定独立取消信号（AbortSignal）
  └── 注册到 session_store
  │
  ▼
agent 生命周期 = 窗口生命周期
  │
  ├── 窗口关闭 → agent.dispose() → 释放所有资源
  ├── 用户取消 → agent.abort() → 取消信号传播到 HTTP + 工具
  └── 正常结束 → agent.idle() → 等待下一次输入
```

**Agent 实例结构**：

```lua
-- 每个 Agent 是一个独立的闭包环境
-- 不存在全局 is_generating、active_generations 等共享状态
{
  id = "agent_xxx",
  session_id = "session_xxx",
  config = {...},            -- 该 Agent 生效的配置快照
  messages = {...},          -- 该 Agent 的消息列表（私有）
  tools = {...},              -- 该 Agent 可见的工具子集
  signal = abort_signal,      -- 取消信号（替代 stop_requested 全局标志）
  state = "idle|generating|tool_running|aborted|error",
  parent = nil | parent_agent_id,  -- 子 Agent 指向父 Agent
}
```

**子 Agent 创建**：

```
主 Agent 决定创建子 Agent
  │
  ▼
agent_runtime.spawn(parent_agent, config_override)
  │
  ├── 创建全新 Agent 实例（空消息队列、独立信号）
  ├── parent 仅传入：task_description + 受限工具集
  ├── 子 Agent 不继承 parent 的任何消息历史
  ├── 子 Agent 完成后，仅将最终结果回传 parent
  └── 子 Agent dispose → 所有资源彻底释放
```

### 决策 2：模型列表异步获取

**旧架构问题**：模型名称硬编码在配置文件中，新增/下架模型需手动更新配置。

**新架构**：

```
启动后（vim.schedule 延迟 100ms）
  │
  ▼
model_fetcher.start()                   ← 后台异步拉取所有已配置提供商的模型列表
  │
  ├── 并发请求各 provider 的 /models 端点
  │   ├── GET https://api.deepseek.com/models
  │   ├── GET https://api.openai.com/v1/models
  │   └── ...
  │
  ├── 成功 → registry.update(provider, models) → 触发 MODELS_UPDATED 事件
  ├── 失败 → 使用 cache.lua 中的本地缓存
  └── 无缓存 → 使用 default_config 中的静态列表作为 fallback
  │
  ▼
UI 层监听 MODELS_UPDATED 事件 → 自动刷新模型选择器
  │
  ▼
用户切换模型 → model_service.set_active(model_id) → 更新当前 Agent 配置
```

**模型注册表接口**：

```lua
model_registry.list(provider?)        -- 获取可用模型（异步返回 Promise）
model_registry.get(model_id)         -- 获取单个模型详情
model_registry.subscribe(callback)   -- 订阅模型列表变更
model_registry.prefetch()           -- 手动触发刷新
```

**配置变化**：`models` 字段不再要求用户填写，改为可选覆盖：

```lua
providers = {
  deepseek = {
    api_type = "openai",
    base_url = "https://api.deepseek.com",
    api_key = os.getenv("DEEPSEEK_API_KEY"),
    -- models 字段可选：不填则自动从 /models 端点获取
    models_override = { "deepseek-reasoner" },  -- 仅作人工覆盖/排序
  },
}
```

### 决策 4：依赖关系扁平化

**旧架构依赖图**（简化）：

```
ui ──→ chat_service ──→ engine ──→ request_handler ──→ http_client
  │         │               │            │
  │         │               └──→ tool_cycle ──→ approval_handler ──→ approval_state
  │         │                              │
  │         └──→ history_manager ──→ cache/persistence/saver/message_builder
  │                                    │
  └──→ keymap_manager ←── config_merger ←── default_config
                                          │
                                     shutdown_flag
                                     state_manager（协程上下文）
```

**问题**：`history_manager` 被至少 5 个模块直接引用，`state_manager` 的协程上下文在 8 个模块中穿插，`tool_cycle` 同时被 `engine` 和 `sub_agent_engine` 调用。

**新架构依赖图**：

```
┌─────────────────────────────────────────────────────────┐
│                      ui/                               │
│  window/ + components/ + keymap.lua                    │
│  仅依赖 services/ 的接口，不直接接触 core/             │
└──────────────────┬──────────────────────────────────────┘
                   │ 调用 service 接口
                   ▼
┌─────────────────────────────────────────────────────────┐
│                   services/                            │
│  chat_service │ tool_service │ model_service           │
│  编排 core/ 模块，向上提供简洁 API                     │
└──────────────────┬──────────────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────────────┐
│                      core/                             │
│  session/（数据）│ model/（模型）│ agent/（引擎）     │
│  各子模块仅依赖 kernel/ + utils/                      │
└──────────────────┬──────────────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────────────┐
│  kernel/（事件常量注册表 + 生命周期 + 配置 + 日志）         │
│  utils/（纯函数工具库）                                │
└─────────────────────────────────────────────────────────┘
```

**依赖规则**：
- `ui/` → 只允许调用 `services/` 的公开方法
- `services/` → 只允许调用 `core/` 的公开方法 + `kernel/` 事件
- `core/` → 只允许调用 `kernel/` + `utils/`
- `kernel/` → 只允许调用 `utils/`
- `utils/` → 不依赖任何项目模块
- 禁止反向依赖、禁止跨层穿透、禁止同级循环引用

### 决策 5：取消信号替代全局标志

**旧架构**：`shutdown_flag.is_set()` 散布在 20+ 个回调中，`_cancel_processed` 幂等标志，`stop_requested` 共享变量……

**新架构**：AbortSignal 模式（借鉴 Web API）。

```lua
-- utils/async.lua
local signal = async.create_signal()

-- Agent 创建时绑定信号
agent.signal = signal

-- 取消时：单次调用，级联传播
signal.abort("user_cancelled")
  ├── 取消正在进行的 HTTP 请求
  ├── 取消待执行的工具调用
  ├── 拒绝未完成的 Promise
  └── 触发 "agent:aborted" 事件

-- 任何异步操作开头检查
if signal:aborted() then return end
```

---

## 五、核心模块职责

### `init.lua` — 主入口

- `setup(config)` — 唯一职责：加载配置 + 注册命令/快捷键
- 不初始化任何业务模块
- 首次打开窗口时触发懒加载链

### `kernel/events.lua` — 事件常量注册表

- 仅注册事件常量用作统一使用

### `kernel/config_store.lua` — 配置存储

- `load(user_config)` — 合并 + 校验 + 返回不可变配置表
- `get(path)` — 按点分路径读取配置（如 `"ui.window.width"`）
- `watch(path, callback)` — 监听配置变更
- 不再有 merger/validator/state 三个文件的分裂

### `core/session/session.lua` — 会话对象

- 纯净数据结构，无副作用
- `create()`, `serialize()`, `deserialize()`
- 不再有 `get_context_and_new_parent` 这种复杂路径算法——改为显式 `fork()` 操作

### `core/model/registry.lua` — 模型注册表

- 运行时动态更新
- 订阅/通知机制
- 支持手动覆盖 + 自动发现

### `core/model/fetcher.lua` — 模型列表获取器

- 异步并发拉取所有 provider 的模型列表
- 指数退避重试（3 次：1s/2s/4s）
- 结果写入 cache + 触发 registry 更新

### `core/agent/agent.lua` — Agent 对象

- 每次对话创建新实例
- 持有私有消息队列、工具集、取消信号
- 状态机：`idle → generating → tool_running → idle`

### `core/agent/runtime.lua` — Agent 运行时

- `create(config)` — 创建 Agent
- `spawn(parent, override)` — 创建子 Agent（全新环境）
- `dispose(agent)` — 销毁 Agent，释放所有资源
- `abort(agent)` — 取消 Agent 当前任务

### `services/chat_service.lua` — 聊天服务

- `send_message(content)` — 发送消息（创建或复用当前 Agent）
- `attach_window(win_id)` — 绑定窗口到 Agent
- `detach_window(win_id)` — 解绑（窗口关闭时调用）
- 不再管理 pending 队列、不再直接操作 history_manager

### `services/model_service.lua` — 模型服务

- `list()` — 返回所有可用模型（异步）
- `set_active(model_id)` — 切换当前 Agent 的模型
- `prefetch()` — 手动刷新模型列表
- 供 UI 的 model_picker 调用

### `ui/keymap.lua` — 统一按键管理

- 替代旧 `keymap_manager` + 散落在各 window 中的 `set_keymaps`
- 集中定义所有按键映射
- 按上下文（global/tree/chat/input）分组
- 支持运行时动态注册/注销

---

## 六、关键流程

### 1. 打开对话窗口

```
用户按快捷键 / 执行命令
  │
  ▼
ui.window.manager.open("chat")
  │
  ├── 创建窗口（float/tab/split）
  ├── agent_runtime.create(config)        ← 全新 Agent 实例
  ├── chat_service.attach_window(win_id, agent)
  ├── model_service.prefetch()            ← 后台刷新模型列表
  └── 渲染空聊天界面
```

### 2. 发送消息

```
用户在输入框按 Enter
  │
  ▼
input_box.submit(content)
  │
  ▼
chat_service.send_message(content)
  │
  ├── agent.add_message("user", content)
  ├── agent.run()                         ← 启动生成
  │     │
  │     ├── request.build()               ← 构建请求体
  │     ├── request.send()                ← 异步发送（带取消信号）
  │     ├── stream.process()              ← 流式处理
  │     └── tool_loop.run()               ← 如有工具调用
  │
  └── 事件驱动 UI 更新
        agent:on("message:chunk", update_ui)
        agent:on("generation:complete", finalize_ui)
```

### 3. 创建子 Agent

```
主 Agent 决定需要子 Agent（工具调用或主动 spawn）
  │
  ▼
agent_runtime.spawn(parent_agent, {
  task = "搜索并分析相关代码",
  tools = { "read_file", "grep" },    -- 受限工具集
  model = "deepseek-v4-flash",         -- 可指定不同模型
})
  │
  ├── 创建全新 Agent（空消息队列、独立信号）
  ├── 不继承 parent 的任何消息/状态
  ├── 仅接收 task_description 作为初始输入
  │
  ├── 子 Agent 执行任务（完全独立）
  │
  └── 完成后 → 返回结果给 parent → dispose 自身
```

### 4. 模型列表加载

```
启动后 100ms（vim.schedule）
  │
  ▼
model_fetcher.prefetch()
  │
  ├── 读取 config_store 中所有 providers
  ├── 并发请求每个 provider 的 /models 端点
  │
  ├── 成功 → registry.update() → 事件通知 UI
  ├── 部分失败 → 成功的更新，失败的用缓存
  └── 全部失败 → 使用 default_config 静态列表
  │
  ▼
model_picker 打开时
  │
  ├── 优先展示 registry 中的实时列表
  ├── 标注每个模型的状态（available/unknown/deprecated）
  └── 用户选择后 → model_service.set_active()
```

### 5. 取消生成

```
用户按 Esc
  │
  ▼
agent.abort()
  │
  ├── signal.abort("user_cancelled")
  ├── 取消正在进行的 HTTP 请求
  ├── 拒绝未完成的工具调用
  ├── 触发 "agent:aborted" 事件
  └── UI 收到事件 → 更新状态
  │
  ▼
agent.state = "idle"                    ← 可立即接受新输入
```

### 6. 窗口关闭

```
用户关闭窗口
  │
  ▼
chat_service.detach_window(win_id)
  │
  ├── agent.dispose()                    ← 释放 Agent 全部资源
  │     ├── 取消进行中的任务
  │     ├── 清空消息队列
  │     ├── 关闭工具连接
  │     └── 从 registry 移除
  │
  └── session_store.persist()            ← 持久化会话数据
```

---

## 七、会话数据结构

### 存储格式

采用 **追加式 JSONL**（每行一个 JSON 对象），替代旧的 JSON 数组：

```
sessions.jsonl
─────────────────────────────────────────
{"id":"s1","parent":null,"created":1234,...}
{"id":"s2","parent":"s1","created":1235,...}
{"id":"s3","parent":"s1","created":1236,...}
```

**优势**：
- 追加写入无需解析整个文件
- 天然支持大文件（不一次性加载到内存）
- 崩溃恢复简单（最后一行可能不完整，截断即可）

### 会话对象

```json
{
  "id": "sess_xxx",
  "parent_id": null,
  "root_id": "sess_xxx",
  "created_at": 1234567890,
  "updated_at": 1234567890,
  "model": "deepseek-v4-flash",
  "messages": [
    {"role": "user", "content": "...", "ts": 1234},
    {"role": "assistant", "content": "...", "reasoning": "...", "ts": 1235}
  ],
  "metadata": {
    "name": "自动命名",
    "tags": [],
    "usage": {"prompt": 24, "completion": 770}
  }
}
```

### 分支策略

不再有复杂的 `get_context_and_new_parent` 路径算法。

```
用户在会话 A 下新建分支
  │
  ▼
session.fork(parent_id, { copy_messages = true })
  │
  ├── 创建新会话 B，parent_id = A
  ├── 可选：复制 A 的消息历史作为上下文
  ├── B 拥有独立的消息队列
  └── 返回 B 的引用
```

---

## 八、配置参考

```lua
require("NeoAI").setup({
  -- AI 配置
  ai = {
    default_provider = "deepseek",
    default_model = "auto",          -- "auto" = 使用 registry 第一个可用模型
    providers = {
      deepseek = {
        api_type = "openai",
        base_url = "https://api.deepseek.com",
        api_key = os.getenv("DEEPSEEK_API_KEY"),
        fetch_models = true,           -- 是否自动获取模型列表
        models_override = nil,         -- 可选：手动指定模型列表（覆盖 API 结果）
      },
      openai = {
        api_type = "openai",
        base_url = "https://api.openai.com/v1",
        api_key = os.getenv("OPENAI_API_KEY"),
        fetch_models = true,
      },
    },
    model_refresh = {
      on_startup = true,              -- 启动时自动获取
      interval_sec = 3600,            -- 定期刷新（0 = 禁用）
      timeout_ms = 10000,             -- 单次请求超时
    },
    scenarios = {
      chat      = { provider = "deepseek", preset = "balanced" },
      coding    = { provider = "deepseek", preset = "precise" },
      reasoning = { provider = "deepseek", preset = "deep_think" },
      agent     = { provider = "deepseek", preset = "balanced" },
    },
  },

  -- UI 配置
  ui = {
    default_view = "chat",
    window_mode = "tab",
    window = { width = 80, height = 20, border = "rounded" },
    split = { size = 80, direction = "right" },
  },

  -- 工具配置
  tools = {
    enabled = true,
    builtin = true,
    approval = {
      mode = "prompt",                 -- prompt | auto_allow | strict
      per_tool = {},                   -- 各工具审批覆盖
    },
  },

  -- 日志配置
  log = {
    level = "warn",
    path = vim.fn.stdpath("cache") .. "/NeoAI/neoai.log",
    max_size = 10485760,
    max_backups = 5,
  },
})
```

---

## 九、错误处理

| 错误类型     | 处理策略                                       |
| ------------ | ---------------------------------------------- |
| 网络错误     | 指数退避重试（1s/2s/4s），3 次后报错          |
| 模型不可用   | 自动 fallback 到同 provider 下一个可用模型    |
| 工具执行错误 | 错误结果回传 Agent，Agent 决定重试或放弃      |
| 配置错误     | 启动时一次性报告所有错误，降级到默认值         |
| 取消操作     | AbortSignal 级联传播，所有等待中的操作立即退出 |
| 序列化失败   | 写入 .bak 文件，不丢失已有数据                |

---

## 十、代码风格

### 模块模板

```lua
--- 模块一句话描述
--- @module NeoAI.module_name

local M = {}
local event_bus = require("NeoAI.kernel.event_bus")
local async = require("NeoAI.utils.async")

-- ========== 私有状态 ==========

local state = { initialized = false }

-- ========== 私有函数 ==========

local function _internal_helper() end

-- ========== 公开 API ==========

function M.init(config)
  if state.initialized then return M end
  state.initialized = true
  return M
end

return M
```

### 命名规范

| 类型       | 规范          | 示例                    |
| ---------- | ------------- | ----------------------- |
| 模块导出   | `M`           | `local M = {}`          |
| 公共函数   | camelCase     | `M.sendMessage()`       |
| 私有函数   | `_camelCase`  | `local _buildReq`       |
| 局部变量   | snake_case    | `local agent_id`        |
| 常量       | UPPER_SNAKE   | `MAX_RETRIES`           |
| 事件名     | `domain:verb` | `"agent:spawn"`         |
| 布尔函数   | `is/has/can`  | `isActive()`, `hasTool()`|

### 异步模式

```lua
-- 使用 Promise 风格替代裸回调
async.new(function(resolve, reject)
  http.get(url, function(err, data)
    if err then reject(err) else resolve(data) end
  end)
end)
  :then_(function(data) ... end)
  :catch(function(err) ... end)
  :finally(function() ... end)
```

---

## 十一、测试策略

| 层级     | 范围                       | 工具                  |
| -------- | -------------------------- | --------------------- |
| 单元测试 | 纯函数、无 I/O             | busted / plenary-test |
| 集成测试 | 模块间协作（mock I/O）     | plenary-test          |
| E2E 测试 | 完整流程（真实 API 可选）  | 手动 + 录制回放       |
| 契约测试 | 事件 payload schema 校验   | 自定义断言            |

**测试原则**：
- 不依赖 Neovim 运行时即可测试 `kernel/` 和 `utils/`
- Agent 测试使用 mock 的 AbortSignal 和 HTTP 客户端
- 事件测试验证 payload 符合 schema

---

## 十二、重构迁移指南

### 删除清单

| 旧模块                       | 原因                       |
| ---------------------------- | -------------------------- |
| `core/config/state.lua`      | 协程上下文机制整体废弃     |
| `core/config/merger.lua`     | 合并入 `kernel/config_store` |
| `core/events.lua`            | 替换为 `kernel/event_bus`  |
| `core/shutdown_flag.lua`     | 替换为 AbortSignal         |
| `core/ai/engine.lua`         | 拆分为 `agent/` 多个文件   |
| `core/ai/request_handler.lua` | 拆分为 `agent/request` + `agent/stream` |
| `core/ai/tool_cycle.lua`     | 拆分为 `agent/tool_loop`   |
| `core/ai/phase_manager.lua`  | 逻辑内聚到 `agent/runtime` |
| `core/history/*`（5个文件）  | 合并为 `core/session/`（2-3个文件） |
| `tools/approval_state.lua`   | 合并入 `services/tool_service` |
| `ui/ui_events.lua`           | 事件监听统一在 `services/` |
