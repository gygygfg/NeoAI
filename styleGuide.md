# NeoAI 架构设计指南

> 版本：3.0 | 设计哲学：**隔离、简洁、异步优先、缓存友好**

---

## 一、设计哲学

### 核心原则

1. **环境隔离（Isolation First）**
   - 每次打开对话窗口 → 创建全新的会话上下文，零残留
   - 每次创建子 Agent → 独立沙箱，不继承父 Agent 的任何运行时状态
   - 模块间通过**不可变数据**通信，禁止共享可变全局状态

2. **依赖单向（Unidirectional Dependency）**
   - 依赖层级严格单向：`utils → kernel → core → services → ui/tools`
   - 禁止循环依赖、禁止跨层穿透调用
   - 模块只暴露**接口（Interface）**，隐藏实现细节

3. **异步优先（Async by Default）**
   - 所有 I/O 操作（网络、文件、模型列表获取）均为异步
   - 启动时不阻塞 Neovim，所有外部资源懒加载 + 后台拉取
   - 模型列表从官网 API 异步获取，本地配置仅作缓存和 fallback

4. **可替换性（Replaceability）**
   - 每个模块定义清晰的接口契约，可独立替换实现
   - 不绑定特定 LLM 厂商，适配器层统一抽象

5. **缓存友好（Cache-Friendly Prefix）**
   - 系统提示按有序段（身份 / persona / 工具指引）拼接，逐字节稳定渲染
   - 工具定义按名称字典序输出，相同工具集跨请求逐字节相同
   - 上下文压缩采用「逐字节回放 + 检查点替换」，复用未变前缀缓存

---

## 二、目录结构

```
NeoAI/
├── init.lua                    # 主入口：极薄，仅做 setup + 路由
├── NeoAI.lua                   # 插件根（require 入口）*
├── default_config.lua          # 默认配置（纯数据，零逻辑）
├── styleGuide.md               # 本文件
│
├── kernel/                     # 内核层（最底层，零业务依赖）
│   ├── init.lua               # 内核初始化 + 子模块引用编排
│   ├── events.lua            # 事件常量注册表（domain:verb）
│   ├── event_bus.lua         # 事件总线（基于 Neovim User autocmd）
│   ├── lifecycle.lua          # 生命周期管理（启动/关闭/清理函数）
│   ├── config_store.lua       # 配置存储（merge + validate + watch）
│   └── logger.lua            # 日志
│
├── core/                       # 核心业务层
│   ├── init.lua               # 核心模块编排
│   ├── session/               # 会话管理
│   │   ├── session.lua        # 会话对象（纯净数据结构 + 方法）
│   │   ├── session_store.lua  # 会话持久化（CRUD + JSONL + .bak）
│   │   ├── context_builder.lua# 上下文构建（system 段 + API 消息转换）
│   │   └── compactor.lua      # 上下文压缩（token 压力 + 溢出恢复）
│   │
│   ├── model/                 # 模型管理层
│   │   ├── registry.lua       # 模型注册表（运行时动态更新）
│   │   ├── fetcher.lua       # 模型列表异步获取器（并发 + 重试）
│   │   ├── adapter.lua        # 多提供商协议适配（openai/anthropic/google）
│   │   └── cache.lua         # 模型列表本地缓存
│   │
│   └── agent/                 # Agent 引擎
│       ├── agent.lua           # Agent 对象（每次对话新建实例）
│       ├── runtime.lua         # Agent 运行时（生命周期 + 状态机）
│       ├── request.lua         # 请求构建 + 发送 + 重试
│       ├── stream.lua          # 流式响应处理（tool_calls 增量累积）
│       ├── tool_loop.lua      # 工具调用循环（并行执行 + 护栏）
│       ├── prefix.lua         # 前缀管理与缓存身份指纹
│       ├── guard.lua          # 工具循环护栏（重复调用提醒）
│       └── recovery.lua       # 上下文溢出恢复（压缩后重发）
│
├── services/                   # 服务层（连接 core 与 ui/tools）
│   ├── chat_service.lua       # 聊天服务（前后端桥梁 + 会话同步）
│   ├── tool_service.lua       # 工具服务（审批 + 调度 + 执行）
│   └── model_service.lua      # 模型服务（供 UI 选择/切换模型）
│
├── ui/                         # 表现层
│   ├── init.lua               # UI 编排（审批 UI + 子 Agent 监控）
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
│   │   ├── markdown_view.lua # Markdown 渲染器
│   │   └── fold.lua          # 折叠组件
│   └── keymap.lua            # 按键映射（统一配置入口）
│
├── tools/                      # 工具系统
│   ├── init.lua               # 工具系统入口（加载内置工具）
│   ├── registry.lua           # 工具注册表（注册/查询/别名/审批配置）
│   ├── executor.lua           # 工具执行器
│   ├── validator.lua          # 参数校验
│   ├── packer.lua             # 工具分组打包
│   └── builtin/               # 内置工具（每个文件独立，互不引用）
│       ├── file_ops.lua       # 文件读写/列出/搜索/删除
│       ├── shell.lua          # run_command 命令执行
│       ├── git_ops.lua        # Git 状态/差异/日志/回滚/提交
│       ├── lsp_ops.lua        # LSP 悬停/跳转/诊断/重命名/格式化
│       ├── tree_ops.lua       # treesitter 解析/查询/删除节点
│       ├── log_ops.lua        # 日志读写工具
│       ├── plan.lua           # 子 Agent 创建/监控/取消（含边界审核）
│       ├── plan_mode.lua      # 计划模式（只读工具上下文 + 格式化计划 + 确认转 CHAT）
│       ├── ask_user.lua       # 向用户提问工具（UI seam）
│       ├── todo.lua           # 待办清单（整表替换语义）
│       └── tool_helpers.lua   # define_tool 辅助函数
│
├── utils/                      # 纯工具库（无业务依赖）
│   ├── init.lua
│   ├── async.lua              # 异步原语（Promise/Future/Deferred/Signal）
│   ├── json.lua
│   ├── http.lua               # HTTP 客户端（流式/非流式 + 取消信号）
│   ├── fs.lua                 # 文件系统操作（JSONL + .bak + 修复）
│   └── stringx.lua            # 字符串扩展（uuid/truncate 等）
│
├── tests/                      # 测试（自定义轻量框架，无外部依赖）
│   ├── init.lua               # 测试运行器 + 断言 API
│   ├── test_kernel.lua
│   ├── test_session.lua
│   ├── test_model_registry.lua
│   ├── test_agent.lua
│   ├── test_tools.lua
│   ├── test_services.lua
│   ├── test_integration.lua
│   ├── test_http.lua
│   ├── test_cache_strategy.lua
│   ├── test_overflow.lua
│   ├── test_guard.lua
│   ├── test_todo.lua
│   ├── test_plan_mode.lua
│   ├── test_sub_agent_result.lua
│   ├── test_fold.lua
│   ├── test_tree_ui.lua
│   ├── test_chat_ui.lua
│   └── test_chat_keys.lua
│
├── doc/                        # 设计文档
├── docs/                       # 开发文档
├── autoload/                   # Vim autoload 入口
└── after/plugin/               # 插件加载脚本
```

> `*` 注：`NeoAI.lua` 位于仓库根目录（`runtimepath` 下被 Neovim 解析为 `require("NeoAI")` 的入口之一，与 `init.lua` 互为补充）。

---

## 三、启动流程

```
setup(user_config)
  │
  ▼
config_store.load(user_config)         ← 纯函数：merge + validate，返回不可变配置
  │
  ▼
kernel.bootstrap()                    ← 初始化事件常量、日志、生命周期（注册 VimLeavePre）
  │
  ▼
tools.init()                          ← 同步注册内置工具（仅定义，无 I/O）
  │
  ▼
注册命令 + 全局快捷键（仅此而已）
  │
  ▼
返回（延迟 100ms 后台刷新模型列表，由 lifecycle 触发）
```

**核心变化**：`setup()` 不初始化任何业务模块（core/services/ui）。所有重活在首次使用时按需懒加载；模型列表刷新由 `kernel.lifecycle` 在启动后延迟调度，不阻塞 Neovim。

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
  └── 注册到 runtime state
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
  parent = nil | parent_agent_id,   -- 子 Agent 指向父 Agent
  config = {...},             -- 该 Agent 生效的配置快照（scenario 解析后）
  messages = {...},           -- 该 Agent 的私有消息列表
  tools = {...},              -- 该 Agent 可见的工具子集（name -> def）
  model = "deepseek-v4-pro",  -- 该 Agent 的模型
  signal = abort_signal,      -- 取消信号（替代 stop_requested 全局标志）
  state = "idle|generating|tool_running|aborted|error",
  iterations = 0,             -- 工具循环轮次计数
  usage = { prompt, completion, cache_read, cache_write, ... },
  cache = {
    last_prefix_id = nil,     -- 上一请求前缀缓存身份指纹
    identity_changes = 0,     -- 缓存身份变更次数
    compaction_usage = nil,   -- 最近一次压缩摘要调用的缓存用量
  },
  plan_mode = false,          -- 计划模式状态（per-agent）
  plan = nil,                 -- 计划内容
  guard = nil,                -- 工具循环护栏计数链（挂 agent 上）
}
```

**子 Agent 创建**：

```
主 Agent 决定创建子 Agent（create_sub_agent 工具）
  │
  ▼
agent_runtime.spawn(parent_agent, override)
  │
  ├── 创建全新 Agent 实例（空消息队列、独立信号）
  ├── parent 仅传入：task + 受限工具集（默认只读工具）
  ├── 子 Agent 不继承 parent 的任何消息历史
  ├── 子 Agent 完成后，仅将最终结果回传 parent
  └── 子 Agent dispose → 所有资源彻底释放
```

- 子 Agent 边界审核：`tool_service` 结合 `plan.lua` 校验工具是否在 `allowed_tools` 内、是否达到 `max_tool_calls` 上限。
- 执行模式：`background`（默认，立即返回）或 `foreground`（等待完成）。

### 决策 2：模型列表异步获取

**旧架构问题**：模型名称硬编码在配置文件中，新增/下架模型需手动更新配置。

**新架构**：

```
启动后（vim.schedule 延迟）
  │
  ▼
model_fetcher.prefetch()               ← 后台异步拉取所有已配置提供商的模型列表
  │
  ├── 并发请求各 provider 的 /models 端点
  │   ├── GET https://api.deepseek.com/models
  │   ├── GET https://api.openai.com/v1/models
  │   └── ...
  │
  ├── 成功 → cache.write + registry.update → 触发 MODELS_UPDATED 事件
  ├── 失败 → 使用 cache.lua 中的本地缓存
  └── 无缓存 → 使用 adapter 的静态 fallback 列表
  │
  ▼
UI 层监听 MODELS_UPDATED 事件 → 自动刷新模型选择器
  │
  ▼
用户切换模型 → model_service.set_active(model_id) → 更新当前 Agent 配置
```

**模型注册表接口**：

```lua
model_registry.list(provider?)        -- 获取可用模型（异步返回 Promise，含 fallback 链合并）
model_registry.get(model_id, provider?) -- 获取单个模型详情
model_registry.subscribe(callback)   -- 订阅模型列表变更
model_registry.prefetch(provider?)   -- 手动触发刷新（交给 fetcher）
model_registry.resolve_default(provider) -- 解析 "auto" 为第一个可用模型
model_registry.update(provider, models) -- fetcher 写入新列表并通知
```

**配置变化**：`models` 字段不再要求用户填写，改为可选覆盖：

```lua
providers = {
  deepseek = {
    api_type = "openai",
    base_url = "https://api.deepseek.com",
    api_key = os.getenv("DEEPSEEK_API_KEY"),
    fetch_models = true,              -- 是否自动获取
    -- models_override：仅作人工覆盖/排序，已填则不发起网络请求
    models_override = { "deepseek-reasoner" },
  },
}
```

**多提供商适配**：`core/model/adapter.lua` 统一抽象三种协议（openai/anthropic/google），每家通过 `api_type` 选择适配器。新增厂商只需 `adapter.register(api_type, adapter)`。

### 决策 3：事件常量 + 事件总线分离

事件系统分离为两层：

- **`kernel/events.lua`** — 事件常量注册表。只声明 `domain:verb` 形式的常量（如 `agent:spawn`、`stream:chunk`），所有模块通过引用常量触发/监听，禁止硬编码事件字符串。
- **`kernel/event_bus.lua`** — 事件总线实现。基于 Neovim 原生 `User` autocmd，统一加 `NeoAI:` 前缀避免冲突，同一事件共享 augroup。

```lua
-- 触发
event_bus.emit(events.AGENT_SPAWNED, { parent = parent.id, agent = child })

-- 订阅（返回取消函数）
local unsub = event_bus.on(events.MODELS_UPDATED, function(payload) ... end)
local once   = event_bus.once(events.PLUGIN_SHUTDOWN, function() ... end)

-- 事件名规范化：强制 "domain:verb"，自动加 "NeoAI:" 前缀
```

事件常量（域）分组：Agent 生命周期 / 生成与流式 / 推理 / 消息 / 会话 / 分支树 / 工具 / 待办与计划模式 / 模型 / UI 窗口 / 子 Agent / 配置与生命周期 / 日志 / 上下文压缩。

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
│  kernel/（事件常量 + 事件总线 + 生命周期 + 配置 + 日志）   │
│  utils/（纯函数工具库）                                │
└─────────────────────────────────────────────────────────┘
```

> 注：`tools/` 属工具系统层，其 `builtin/*` 各文件相互独立、互不引用，可被 core（tool_loop）与 services（tool_service）调用；工具定义本身回写 Agent 状态需通过 `ctx.agent` 上下文，保持边界清晰。

**依赖规则**：
- `ui/` → 只允许调用 `services/` 的公开方法
- `services/` → 只允许调用 `core/` 的公开方法 + `kernel/` 事件 + `tools/` 执行
- `core/` → 只允许调用 `kernel/` + `utils/`（agent 子模块间可互相引用）
- `tools/` → 只允许调用 `kernel/` + `utils/`（builtin 独立，互不引用）
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
  ├── 取消正在进行的 HTTP 请求（http 客户端透传 signal）
  ├── 取消待执行的工具调用
  ├── 拒绝未完成的 Promise
  └── 触发 "agent:aborted" 事件

-- 任何异步操作开头检查
if signal:aborted() then return end
```

子 Agent 拥有独立信号（`runtime.spawn` 中 `child.signal = async.create_signal()`），不继承父信号。

### 决策 6：上下文压缩 + 溢出恢复（缓存友好）

解决超长会话触碰模型上下文窗口的问题，对齐 deepseek-harness 的 compaction 策略：

**触发时机**（两条路径）：
1. **压力预检**：`runtime.run` 每步前调 `compactor.maybe_compact`，达到 `threshold_ratio` 时先折叠旧历史。
2. **溢出恢复**：请求返回 `context window exceeded`（400/413/429）时，`recovery.send_stream` 调 `compactor.force_compact` 后重发（每轮请求最多触发一次）。

**压缩策略**：
- 折叠最早的整段消息，保留最近尾部（`retain_ratio`/`retain_min_tokens` 预算）。
- 辅助摘要调用「逐字节回放」系统提示 + 工具 schema + 被折叠区消息，压缩指令作为最后一条 user 消息追加 → 复用热前缀缓存。
- 用带 `<compacted-summary>` 标签的检查点 user 消息**替换**被折叠区间（仅替换，不产生第二份历史副本）。

**前缀身份一致性**（`core/agent/prefix.lua`）：
- 系统提示按有序段拼接（身份 `-100` / persona `0` / 工具指引 `100+`），跨请求逐字节稳定。
- 工具定义按名称字典序输出，相同工具集跨请求逐字节相同。
- 缓存身份指纹（FNV-1a）跨请求比对，身份变更即前缀缓存失效，用于诊断与统计。
- 从 provider usage 解析缓存命中/未命中 token（`prompt_cache_hit_tokens` / `cached_tokens`）。

---

## 五、核心模块职责

### `init.lua` — 主入口

- `setup(config)` — 加载配置 → 内核引导 → 工具系统初始化 → 注册命令/快捷键
- 不初始化 core/services/ui 业务模块
- 首次打开窗口时触发懒加载链
- 注册用户命令：`NeoAIOpen` / `NeoAIChat` / `NeoAITree` / `NeoAIClose` / `NeoAIKeymaps` / `NeoAITest` / `NeoAIChatStatus` / `NeoAIPlan`

### `kernel/events.lua` — 事件常量注册表

- 仅声明 `domain:verb` 事件常量，供统一引用；禁止硬编码字符串。

### `kernel/event_bus.lua` — 事件总线

- 基于 Neovim `User` autocmd 的发布/订阅（`emit` / `on` / `once` / `clear_all`）。
- 事件名自动加 `NeoAI:` 前缀；同事件共享 augroup；回调异常被捕获并记日志。

### `kernel/lifecycle.lua` — 生命周期

- `bootstrap()` — 初始化日志、注册 `VimLeavePre` 清理、延迟调度模型刷新。
- `on_shutdown(fn)` — 注册清理函数（逆序执行）；`shutdown()` 统一执行并触发 `PLUGIN_SHUTDOWN`。

### `kernel/config_store.lua` — 配置存储

- `load(user_config)` — 深度合并 + 校验 + 返回不可变配置表。
- `get(path)` — 按点分路径读取（如 `"ui.window.width"`）。
- `set(path, value)` — 运行时热更新（触发 watch + `CONFIG_CHANGED`）。
- `watch(path, cb)` — 监听配置变更。
- 不再有 merger/validator/state 三个文件的分裂。

### `core/session/session.lua` — 会话对象

- 纯净数据结构，无副作用、无 I/O。
- 字段：`id / parent_id / root_id / created_at / updated_at / model / messages / metadata`。
- `create()` / `serialize()` / `deserialize()` / `add_message()` / `fork()` / `trim_messages()`。
- 不再有 `get_context_and_new_parent` 复杂路径算法——改为显式 `fork()` 操作。

### `core/session/session_store.lua` — 会话持久化

- 追加式 JSONL 存储 + 撕裂行修复 + `.bak` 备份（`_rewrite_all` 先写 `.bak` 再写正式文件，失败回滚）。
- CRUD：`create` / `get` / `update` / `delete`（级联删除子孙）/ `persist` / `save_all`。
- 树查询：`get_children` / `get_roots` / `get_descendants`（BFS）。

### `core/session/context_builder.lua` — 上下文构建

- 从会话/Agent 构建 API 消息数组（system 段 + 消息转换 + 历史截断）。
- `_to_api_message`：带 tool_calls 的 assistant 消息且 content 为空时省略 content 字段（严格兼容 OpenAI/DeepSeek）。
- `estimate_tokens`：字符/4 粗估 token（供压缩压力判断）。
- `build_prefix`：构建压缩回放前缀（字节一致，复用前缀缓存）。

### `core/session/compactor.lua` — 上下文压缩

- `maybe_compact(agent)` — 达到 token 压力阈值时折叠历史（仅空闲时执行）。
- `force_compact(agent)` — 跳过阈值判断，供溢出恢复使用。
- `_select_shadow_range` — 折叠最早整段，保留最近尾部。
- `checkpoint_message(summary)` — 生成 `<compacted-summary>` 检查点消息。

### `core/model/registry.lua` — 模型注册表

- 运行时动态更新；订阅/通知机制；支持手动覆盖 + 自动发现。
- fallback 链：动态 API 结果 → `models_override`/`models` 静态 → adapter 默认列表。

### `core/model/fetcher.lua` — 模型列表获取器

- 异步并发拉取所有 provider 的模型列表。
- 指数退避重试（3 次：1s/2s/4s）。
- 成功 → `cache.write` + `registry.update`；失败 → 缓存 → registry 当前值 → 静态 fallback。

### `core/model/adapter.lua` — 多提供商协议适配

- 统一 openai / anthropic / google 协议的请求构造、流式/非流式响应解析、models 列表解析。
- `get(api_type)` / `register(api_type, adapter)` / `get_fallback_models(provider)` / `can_fetch(provider)`。

### `core/agent/agent.lua` — Agent 对象

- 每次对话创建新实例；持有私有消息队列、工具集、取消信号。
- 状态机：`idle → generating → tool_running → idle`（或 `aborted` / `error`）。
- 消息操作、取消、usage 累加（兼容 openai 两种 usage 形状 + 缓存用量）。

### `core/agent/runtime.lua` — Agent 运行时

- `create(config)` — 创建 Agent（含 scenario 配置解析）。
- `spawn(parent, override)` — 创建子 Agent（全新环境，独立信号）。
- `dispose(agent)` / `abort(agent)` — 销毁/取消。
- `run(agent, content)` — 用户消息 → 压缩预检 → guard 重置 → 生成（含工具循环）。

### `core/agent/request.lua` — 请求构建与发送

- `send`（非流式）/ `send_stream`（流式，强制 `stream=true`）。
- 指数退避重试；`_should_retry`（4xx 不重试）；`is_context_overflow` 溢出判定。

### `core/agent/stream.lua` — 流式响应处理

- 累积分片 tool_calls（OpenAI 格式）为完整 tool_call；同步流式增量到 Agent 消息；推理/内容切换事件。

### `core/agent/tool_loop.lua` — 工具调用循环

- 并行执行工具调用；结果按原始调用顺序写回（API 兼容 + 前缀缓存确定）。
- 轮数上限 1000；护栏提醒注入；空响应收尾说明。

### `core/agent/prefix.lua` — 前缀与缓存身份

- `build_system_prompt` — 有序段渲染系统提示。
- `register_section` / `register_agent_section` — 全局/agent 级提示段注册。
- `prefix_id` — FNV-1a 缓存身份指纹；`verify_cache_identity` — 身份一致性校验；`parse_cache_usage` — 缓存用量解析。

### `core/agent/guard.lua` — 工具循环护栏

- 检测连续重复调用（相同工具 + 相同参数），达阈值注入提醒（observe-and-enrich，不否决）。
- `reset`（用户新输入重置）/ `check_round`（每轮检查）。

### `core/agent/recovery.lua` — 溢出恢复

- `send_stream` — 请求返回溢出错误 → `compactor.force_compact` 后重发；每轮请求最多触发一次。

### `services/chat_service.lua` — 聊天服务

- `send_message(content)` — 发送消息（创建或复用当前 Agent）。
- `attach_window` / `detach_window` — 绑定/解绑窗口（关闭时持久化 + 清理审批）。
- `new_session` / `load_session` — 新建/加载会话（还原计划模式、待办清单）。
- `toggle_plan_mode` / `toggle_auto_mode` / `cycle_mode` / `approve_plan` / `get_mode` / `cancel_generation` / `switch_model` / `get_todos`。

### `services/tool_service.lua` — 工具服务

- `execute(agent, name, args, ...)` — 子 Agent 边界审核 + 计划模式门禁 + 执行。
- `approve_and_execute(...)` — 审批 + 执行（串行单槽位审批队列 + 超时兜底）。
- `clear_approval` / `set_allow_all` / `set_approval_ui` / `has_pending_approval`。

### `services/model_service.lua` — 模型服务

- `list()` — 异步返回所有可用模型（按 provider 分组）。
- `set_active(model_id, provider)` / `get_active()` — 切换/获取当前模型。
- `prefetch(provider)` / `subscribe(cb)` / `start_background_refresh()`。

### `ui/keymap.lua` — 统一按键管理

- 替代旧 `keymap_manager` + 散落在各 window 中的 `set_keymaps`。
- 集中定义所有按键映射；按上下文（global/tree/chat）分组；支持运行时动态注册/注销。

---

## 六、关键流程

### 1. 打开对话窗口

```
用户按快捷键 / 执行命令
  │
  ▼
ui.open_chat()
  │
  ├── ui.init()（注册审批 UI + 子 Agent 监控）
  ├── chat_view.open()
  ├── agent_runtime.create(config)        ← 全新 Agent 实例（懒加载）
  ├── chat_service.attach_window(win_id, agent)
  ├── model_service.prefetch()            ← 后台刷新模型列表
  └── 渲染空聊天界面（树窗口保持打开，可同时浏览会话）
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
  ├── _get_or_create_agent（复用当前 Agent 或新建 Session+Agent）
  ├── runtime.run(agent, content)
  │     │
  │     ├── compactor.maybe_compact（压力预检）
  │     ├── guard.reset（重置护栏计数链）
  │     ├── agent.add_message("user", content)
  │     └── _run_generation
  │           ├── recovery.send_stream（溢出恢复包裹）
  │           ├── request.send_stream()   ← 异步发送（带取消信号）
  │           ├── stream.process()        ← 流式处理
  │           └── tool_loop.run()         ← 如有工具调用
  │
  └── 事件驱动 UI 更新
        agent:on("message:chunk", update_ui)
        agent:on("generation:complete", finalize_ui)
```

### 3. 创建子 Agent

```
主 Agent 调用 create_sub_agent 工具
  │
  ▼
runtime.spawn(parent_agent, {
  task = "搜索并分析相关代码",
  model = "deepseek-v4-flash",         -- 可指定不同模型
  boundaries = { allowed_tools = {...}, max_tool_calls = n },
})
  │
  ├── 创建全新 Agent（空消息队列、独立信号）
  ├── 不继承 parent 的任何消息/状态
  ├── 仅接收 task_description 作为初始输入
  │
  ├── 子 Agent 执行任务（完全独立，默认只读工具集）
  │
  └── 完成后 → 返回结果给 parent → dispose 自身
```

### 4. 模型列表加载

```
启动后（lifecycle vim.schedule）
  │
  ▼
model_fetcher.prefetch()
  │
  ├── 读取 config_store 中所有 providers
  ├── 并发请求每个 provider 的 /models 端点
  │
  ├── 成功 → cache.write + registry.update() → 事件通知 UI
  ├── 部分失败 → 成功的更新，失败的用缓存
  └── 全部失败 → adapter 静态 fallback 列表
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
chat_service.cancel_generation() → agent.abort()
  │
  ├── signal.abort("user_cancelled")
  ├── 取消正在进行的 HTTP 请求
  ├── 拒绝未完成的工具调用
  ├── 清理待审批项（释放串行审批槽位）
  ├── 触发 "agent:aborted" 事件
  └── UI 收到事件 → 更新状态
  │
  ▼
agent.state = "aborted"（下一轮输入前回到 idle）
```

### 6. 上下文压缩

```
（路径 A：步前预检）
runtime.run → compactor.maybe_compact(agent)
  ├── est >= context_window * threshold_ratio？
  └── 是 → _compact（回放 + 摘要 + 检查点替换）

（路径 B：溢出恢复）
request 返回 400/413/429 溢出错误
  ▼
recovery.send_stream 捕获 is_context_overflow
  ▼
compactor.force_compact → 压缩后 attempt() 重发
```

### 7. 窗口关闭

```
用户关闭窗口
  │
  ▼
chat_service.detach_window(win_id)
  │
  ├── _persist_agent（同步消息 + 状态到 session）
  ├── agent.dispose()                    ← 释放 Agent 全部资源
  │     ├── plan_mode.cleanup（注销提示段）
  │     ├── 取消进行中的任务
  │     ├── 清空消息队列
  │     └── 从 runtime registry 移除
  ├── todo.cleanup(session_id)
  ├── tool_service.clear_approval()      ← 释放串行审批槽位
  └── session_store.persist()            ← 持久化会话数据
```

---

## 七、会话数据结构

### 存储格式

采用 **追加式 JSONL**（每行一个 JSON 对象），替代旧的 JSON 数组：

```
sessions.jsonl
─────────────────────────────────────────
{"id":"s1","parent_id":null,"root_id":"s1",...}
{"id":"s2","parent_id":"s1","root_id":"s1",...}
{"id":"s3","parent_id":"s1","root_id":"s1",...}
```

**优势**：
- 追加写入无需解析整个文件
- 天然支持大文件（不一次性加载到内存）
- 崩溃恢复简单（最后一行可能不完整，`fs.repair_jsonl` 截断即可）
- 重写操作先写 `.bak` 再写正式文件，失败自动回滚

### 会话对象

```json
{
  "id": "sess_xxx",
  "parent_id": null,
  "root_id": "sess_xxx",
  "created_at": 1234567890,
  "updated_at": 1234567890,
  "model": "deepseek-v4-pro",
  "messages": [
    {"role": "user", "content": "...", "ts": 1234, "id": "msg_xxx"},
    {"role": "assistant", "content": "...", "reasoning": "...", "ts": 1235}
  ],
  "metadata": {
    "name": "自动命名",
    "tags": [],
    "usage": {"prompt": 24, "completion": 770},
    "todos": [...],
    "plan": {"active": false, "plan": null}
  }
}
```

> `metadata.todos` 与 `metadata.plan` 用于跨会话还原待办清单与计划模式状态。

### 分支策略

不再有复杂的 `get_context_and_new_parent` 路径算法。

```
用户在会话 A 下新建分支
  │
  ▼
session.fork(parent_id, { copy_messages = true })
  │
  ├── 创建新会话 B，parent_id = A，root_id = A.root_id
  ├── 可选：复制 A 的消息历史作为上下文
  ├── B 拥有独立的消息队列
  └── 返回 B 的引用
```

---

## 八、配置参考

（完整默认值见 `default_config.lua`，以下为要点摘要）

```lua
require("NeoAI").setup({
  ai = {
    default_provider = "deepseek",
    default_model = "auto",          -- "auto" = registry 第一个可用模型
    providers = {
      deepseek = { api_type = "openai", base_url = "...", api_key = "...", fetch_models = true },
      openai   = { api_type = "openai", ... },
      anthropic= { api_type = "anthropic", ... },
      google   = { api_type = "google", ... },
      groq / together / openrouter / siliconflow / moonshot / zhipu / baidu / aliyun / stepfun,
      -- 共 13 家内置 provider，均可 models_override 手动覆盖
    },
    model_refresh = { on_startup = true, interval_sec = 3600, timeout_ms = 10000 },
    scenarios = { chat / coding / reasoning / agent = { provider, preset } },
    presets  = {
      fast = { model = "auto", temperature = 0.3, max_tokens = 1024, stream = true },
      balanced = { model = "auto", temperature = 0.7, max_tokens = 4096, stream = true },
      precise = { model = "auto", temperature = 0.2, max_tokens = 8192, stream = true },
      deep_think = { model = "auto", temperature = 0.7, max_tokens = 8192, stream = true },
    },
    reasoning_enabled = true,
    system_prompt = "你是一个AI编程助手...",
    timeout_ms = 60000,
    max_retries = 3,
    context_cache = {            -- 前缀缓存身份一致性 + 上下文压缩
      enabled = true,
      context_window = 64000,
      threshold_ratio = 0.8,
      retain_ratio = 0.16,
      retain_min_tokens = 4096,
      compact_max_tokens = 8192,
      min_shadow_messages = 2,
      include_identity = true,
      identity = "你是一个由 NeoAI 驱动的 AI 编程助手。",
    },
  },

  ui = {
    default_view = "chat",
    window_mode = "tab",
    window = { width = 80, height = 24, border = "rounded" },
    split = { size = 80, direction = "right" },
    colors = { background, border, user_message, ai_message, reasoning, title },
    tree = { foldenable, auto_close_on_select, ... },
  },

  keymaps = {
    global = { toggle_ui, open_chat, open_tree, close_all },
    tree = { quit, select, new_child, new_root, delete_dialog, delete_branch, expand, collapse },
    chat = { insert, quit, send, cancel, toggle_reasoning, switch_model, cycle_mode, tool_approval, approval },
  },

  session = {
    auto_save = true,
    auto_naming = true,
    save_path = vim.fn.stdpath("cache") .. "/NeoAI",
    max_history_per_session = 1000,
    file = "sessions.jsonl",
  },

  tools = {
    enabled = true,
    builtin = true,
    external = {},
    guard = { repeat_tool = { enabled, thresholds = {3,5,8}, messages } },
    todo = { enabled = true },
    plan_mode = { enabled = true, auto_execute_on_approve = true, extra_safe_tools = {}, mutating_tools = {...} },
    approval = {
      mode = "prompt",             -- prompt | auto_allow | strict
      default_auto_allow = false,
      timeout_ms = 60000,
      allowed_directories = {},
      allowed_param_groups = {},
      per_tool = { read_file = { auto_allow = true }, edit_file = { auto_allow = false }, ... },
    },
  },

  log = {
    level = "WARN",
    path = vim.fn.stdpath("cache") .. "/NeoAI/neoai.log",
    max_size = 10485760,
    max_backups = 5,
    format = "[{time}] [{level}] {message}",
    verbose = false,
  },
})
```

---

## 九、错误处理

| 错误类型     | 处理策略                                       |
| ------------ | ---------------------------------------------- |
| 网络错误     | 指数退避重试（1s/2s/4s），3 次后报错          |
| 上下文溢出   | 自动压缩历史后重发（每轮请求最多一次）         |
| 模型不可用   | 自动 fallback 到同 provider 下一个可用模型    |
| 工具执行错误 | 错误结果回传 Agent，Agent 决定重试或放弃      |
| 工具循环卡死 | 轮数上限 1000、审批超时兜底、空响应收尾说明   |
| 重复工具调用 | guard 注入提醒（observe-and-enrich，不否决）  |
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
local events = require("NeoAI.kernel.events")
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
| 状态常量   | UPPER_SNAKE   | `STATES.IDLE`           |
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

-- 重试（指数退避）
async.retry(fn, { retries = 3, delay_ms = 1000, backoff = 2, signal = sig, should_retry = fn })

-- 并发等待全部
async.all({ deferred1, deferred2 })
```

### 事件驱动约定

- 事件名一律通过 `kernel/events.lua` 常量引用，禁止硬编码字符串。
- 触发：`event_bus.emit(events.X, payload)`；订阅：`event_bus.on(events.X, cb)`（返回取消函数）。
- payload 使用 table，跨模块传递时不可变。

---

## 十一、测试策略

**测试框架**：自定义轻量框架（`tests/init.lua`），无外部依赖，headless 可跑。

- 运行方式：`:NeoAITest [suite_name ...]`（空参数运行全部）。
- 断言 API：`eq / ne / not_eq / true_ / false_ / nil_ / not_nil / matches / ok / deep_eq / sleep / throws`。
- 组织方式：`suite(name, fn)` 定义套件，`it(name, fn)` 定义用例，`before_each` 钩子。
- 动态加载：`run_all` 通过 glob 自动加载 `tests/test_*.lua`。

| 层级     | 范围                       | 工具                  |
| -------- | -------------------------- | --------------------- |
| 单元测试 | 纯函数、无 I/O             | 自定义框架            |
| 集成测试 | 模块间协作（mock I/O）     | 自定义框架            |
| UI 测试  | 树/聊天视图交互            | 自定义框架 + nvim     |
| E2E 测试 | 完整流程（真实 API 可选）  | 手动 + 录制回放       |
| 契约测试 | 事件 payload schema 校验   | 自定义断言            |

**测试原则**：
- 不依赖 Neovim 运行时即可测试 `kernel/` 和 `utils/` 的纯逻辑
- Agent 测试使用 mock 的 AbortSignal 和 HTTP 客户端
- 事件测试验证 payload 符合 schema
- 每个模块暴露 `reset()`（测试用）以清理模块级状态

---

## 十二、重构迁移指南

（v2.0 → v3.0 已完成；保留历史决策说明）

### 已完成的重构

| 旧模块                       | 现状                                     |
| ---------------------------- | ---------------------------------------- |
| `core/config/state.lua`      | 协程上下文机制整体废弃，配置并入 config_store |
| `core/config/merger.lua`     | 合并入 `kernel/config_store`             |
| `core/events.lua`            | 拆分：`kernel/events`（常量）+ `kernel/event_bus`（实现） |
| `core/shutdown_flag.lua`     | 替换为 AbortSignal（utils/async）        |
| `core/ai/engine.lua`         | 拆分为 `agent/` 多个文件                 |
| `core/ai/request_handler.lua`| 拆分为 `agent/request` + `agent/stream`  |
| `core/ai/tool_cycle.lua`     | 拆分为 `agent/tool_loop`                 |
| `core/ai/phase_manager.lua`  | 逻辑内聚到 `agent/runtime`               |
| `core/history/*`（5个文件）  | 合并为 `core/session/`（4 个文件）       |
| `tools/approval_state.lua`   | 合并入 `services/tool_service`           |
| `ui/ui_events.lua`           | 事件监听统一在 `services/`               |

### v3.0 新增模块

| 新模块                       | 职责                                     |
| ---------------------------- | ---------------------------------------- |
| `kernel/event_bus.lua`       | 事件总线（Neovim User autocmd 实现）     |
| `core/session/compactor.lua` | 上下文压缩（token 压力 + 溢出恢复）      |
| `core/agent/prefix.lua`      | 前缀管理与缓存身份指纹                   |
| `core/agent/guard.lua`       | 工具循环护栏（重复调用提醒）             |
| `core/agent/recovery.lua`    | 上下文溢出恢复（压缩后重发）             |
| `tools/builtin/tree_ops.lua` | treesitter 解析/查询/删除节点            |
| `tools/builtin/log_ops.lua`  | 日志读写工具                             |
| `tools/builtin/plan.lua`     | 子 Agent 创建/监控/取消（含边界审核）    |
| `tools/builtin/plan_mode.lua`| 计划模式（只读工具上下文 + 格式化计划 + 确认转 CHAT）|
| `tools/builtin/ask_user.lua` | 向用户提问工具（UI seam + vim.ui.input 回退）      |
| `tools/builtin/todo.lua`     | 待办清单（整表替换语义 + 系统提示注入）  |
| `ui/components/fold.lua`     | 折叠组件                                 |

---

## 十三、内置工具清单

| 文件 | 工具 |
| ---- | ---- |
| `file_ops.lua` | `read_file` / `edit_file` / `list_files` / `search_files` / `file_exists` / `create_directory` / `ensure_dir` / `delete_file` / `confirm_file_change` |
| `shell.lua`    | `run_command` |
| `git_ops.lua`  | `git_status` / `git_diff` / `git_log` / `git_commit_detail` / `git_branch` / `git_file_history` / `git_rollback` / `git_auto_commit_config` |
| `lsp_ops.lua`  | `lsp_hover` / `lsp_definition` / `lsp_references` / `lsp_document_symbols` / `lsp_workspace_symbols` / `lsp_diagnostics` / `lsp_client_info` / `lsp_code_action` / `lsp_rename` / `lsp_format` / `lsp_signature_help` / `lsp_completion` / `lsp_type_definition` / `lsp_declaration` / `lsp_implementation` / `lsp_service_info` |
| `tree_ops.lua` | `parse_file` / `get_node_at_position` / `get_node_type` / `get_node_range` / `is_named_node` / `get_parent_node` / `get_child_nodes` / `get_node_code` / `query_tree` / `delete_node` |
| `log_ops.lua`  | `log_message` / `get_log_levels` |
| `plan.lua`     | `create_sub_agent` / `get_sub_agent_status` / `wait_sub_agent` / `cancel_sub_agent` |
| `plan_mode.lua`| `enter_plan_mode`（工具上下文切换为只读/信息 + 提问） |
| `ask_user.lua` | `ask_user` |
| `todo.lua`     | `todo_write` / `todo_read` / `todo_clear` |
