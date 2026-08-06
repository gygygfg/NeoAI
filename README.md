# NeoAI

> 🧠 **NeoAI** — 一款功能强大的 Neovim AI 编程助手插件，集成多模型 AI 对话、文件操作、代码分析和 Shell 命令执行等能力，支持树形会话管理和子 Agent 协作。

---

## ✨ 特性

- **多 AI 提供商支持** — 内置 DeepSeek、OpenAI、Anthropic、Google Gemini、Groq、Together AI、OpenRouter、SiliconFlow、月之暗面、智谱、百度、阿里云、阶跃星辰等 13+ 家 AI 服务商
  - (钞能力有限，只测试了DeepSeek)
- **场景化模型配置** — 按场景（聊天、编程、思考、工具执行、子 Agent、窗口命名）分配不同的 AI 模型和参数
- **流式响应** — 实时流式显示 AI 生成内容，支持推理过程（reasoning）展示
- **树形会话管理** — 基于分支树管理多个对话会话，支持分支创建、切换、删除
- **丰富的内置工具** — AI 可调用文件操作、代码分析、LSP、Shell 命令等 40+ 工具
- **工具审批系统** — 细粒度的工具执行权限控制，支持自动允许/手动审批/参数级别白名单
- **子 Agent 系统** — AI 可创建子 Agent 并行执行子任务，支持边界审核
- **前后端分离架构** — 事件驱动的异步架构，UI 与业务逻辑解耦
- **高度可配置** — 完整的键位绑定、UI 布局、日志级别等自定义配置
- **纯lua编写** — 无需安装额外的依赖
- **⚠️⚠️⚠️使用curl发送请求** 环境变量内没有curl可能无法发送请求

---

## 📦 安装

### 使用 lazy.nvim

```lua
{
  "gygygfg/NeoAI",
  config = function()
    require("NeoAI").setup({
      -- 可选配置，见下方"配置"章节
    })
  end,
}
```

### 使用 packer.nvim

```lua
use {
  "gygygfg/NeoAI",
  config = function()
    require("NeoAI").setup({})
  end,
}
```

### 使用 vim.pack

```lua

vim.pack.add({ gh("gygygfg/Neoai") })

require("NeoAI").setup({})

```

---

## 🚀 快速开始

### 1. 设置 API Key

在环境变量中设置你的 AI 提供商 API Key：

```bash
export DEEPSEEK_API_KEY="your-api-key"
# 或
export OPENAI_API_KEY="your-api-key"
# 或
export ANTHROPIC_API_KEY="your-api-key"
```

### 2. 初始化插件

```lua
require("NeoAI").setup({
  ai = {
    default_provider = "deepseek",
    providers = {
      deepseek = {
        api_key = os.getenv("DEEPSEEK_API_KEY"),
      },
    },
  },
})
```

### 3. 使用命令

| 命令               | 描述                                             |
| ------------------ | ------------------------------------------------ |
| `:NeoAIOpen`       | 打开 NeoAI 主界面                                |
| `:NeoAIChat`       | 打开聊天界面                                     |
| `:NeoAITree`       | 打开会话树界面                                   |
| `:NeoAIClose`      | 关闭所有 NeoAI 窗口                              |
| `:NeoAIKeymaps`    | 显示当前键位配置                                 |
| `:NeoAITest`       | 运行测试（不带参数运行全部，带参数运行指定测试） |
| `:NeoAIChatStatus` | 显示聊天窗口状态                                 |

### 4. 默认快捷键

| 快捷键       | 描述           |
| ------------ | -------------- |
| `<leader>aa` | 切换 UI 显示   |
| `<leader>ac` | 打开聊天界面   |
| `<leader>at` | 打开会话树界面 |
| `<leader>aq` | 关闭所有窗口   |

---

## ⚙️ 配置

<details>
<summary>点击展开完整配置结构</summary>

```lua
require("NeoAI").setup({
  -- ===== AI 配置 =====
  ai = {
    default_provider = "deepseek",       -- 默认提供商
    default_model = "auto",              -- "auto" = 使用 registry 第一个可用模型

    -- 提供商定义（13+ 家 AI 服务商）
    providers = {
      deepseek = {
        api_type = "openai",             -- API 类型：openai / anthropic / google
        base_url = "https://api.deepseek.com",
        api_key = os.getenv("DEEPSEEK_API_KEY"),
        fetch_models = true,             -- 是否自动获取模型列表（异步后台拉取）
        models_override = nil,           -- 可选：手动指定模型（覆盖 API 结果）
      },
      openai = {
        api_type = "openai",
        base_url = "https://api.openai.com/v1",
        api_key = os.getenv("OPENAI_API_KEY"),
        fetch_models = true,
      },
      -- 更多提供商：anthropic, google, groq, together, openrouter, siliconflow,
      -- moonshot, zhipu, baidu, aliyun, stepfun
    },

    model_refresh = {
      on_startup = true,                 -- 启动后自动获取模型列表
      interval_sec = 3600,               -- 定期刷新（0 = 禁用）
      timeout_ms = 10000,                -- 单次请求超时
    },

    -- 场景化模型配置（每个场景用 provider + preset 组合）
    scenarios = {
      chat      = { provider = "deepseek", preset = "balanced" },
      coding    = { provider = "deepseek", preset = "precise" },
      reasoning = { provider = "deepseek", preset = "deep_think" },
      agent     = { provider = "deepseek", preset = "balanced" },
    },

    -- 预设（温度/token/流式组合）
    presets = {
      fast      = { model = "auto", temperature = 0.3, max_tokens = 1024, stream = true },
      balanced  = { model = "auto", temperature = 0.7, max_tokens = 4096, stream = true },
      precise   = { model = "auto", temperature = 0.2, max_tokens = 8192, stream = true },
      deep_think= { model = "auto", temperature = 0.7, max_tokens = 8192, stream = true },
    },

    reasoning_enabled = true,            -- 启用深度思考模式
    system_prompt = "你是一个AI编程助手，帮助用户解决编程问题。",
    timeout_ms = 60000,                  -- 请求超时
    max_retries = 3,                     -- 请求重试次数
  },

  -- ===== UI 配置 =====
  ui = {
    default_view = "chat",               -- 默认界面：tree / chat
    window_mode = "tab",                 -- 窗口模式：float / tab / split
    window = { width = 80, height = 24, border = "rounded" },
    split = { size = 80, direction = "right" },
  },

  -- ===== 键位配置 =====
  keymaps = {
    global = {
      toggle_ui = { key = "<leader>aa", desc = "切换UI显示" },
      open_chat = { key = "<leader>ac", desc = "打开聊天界面" },
      open_tree = { key = "<leader>at", desc = "打开树界面" },
      close_all = { key = "<leader>aq", desc = "关闭所有窗口" },
    },
    tree = {
      select = { key = "<CR>", desc = "选择节点/分支" },
      new_child = { key = "n", desc = "新建子分支" },
      new_root = { key = "N", desc = "新建根分支" },
      delete_dialog = { key = "d", desc = "删除对话" },
      delete_branch = { key = "D", desc = "删除分支" },
    },
    chat = {
      insert = { key = "i", desc = "进入插入模式" },
      quit = { key = "q", desc = "关闭聊天窗口" },
      send = { insert = { key = "<C-s>" }, normal = { key = "<CR>" } },
      cancel = { key = "<Esc>", desc = "取消生成" },
      switch_model = { key = "m", desc = "切换模型" },
      toggle_reasoning = { key = "r", desc = "切换思考过程显示" },
      approval = {
        confirm = { key = "<CR>", desc = "允许一次" },
        confirm_all = { key = "A", desc = "允许所有" },
        cancel = { key = "<Esc>", desc = "取消" },
        cancel_with_reason = { key = "C", desc = "取消并说明" },
      },
    },
  },

  -- ===== 会话配置 =====
  session = {
    auto_save = true,
    auto_naming = true,
    save_path = vim.fn.stdpath("cache") .. "/NeoAI",
    max_history_per_session = 1000,
    file = "sessions.jsonl",             -- 追加式 JSONL 存储
  },

  -- ===== 工具配置 =====
  tools = {
    enabled = true,
    builtin = true,
    external = {},
    approval = {
      mode = "prompt",                   -- prompt | auto_allow | strict
      default_auto_allow = false,
      allowed_directories = {},
      allowed_param_groups = {},
      per_tool = {
        read_file      = { auto_allow = true },
        edit_file      = { auto_allow = false },
        list_files     = { auto_allow = true },
        search_files   = { auto_allow = true },
        delete_file    = { auto_allow = false },
        run_command    = { auto_allow = false, allowed_directories = { "./" }, allowed_param_groups = { "ls", "grep" } },
        create_sub_agent = { auto_allow = false },
        -- 更多工具审批配置...
      },
    },
  },

  -- ===== 日志配置 =====
  log = {
    level = "WARN",                      -- DEBUG / INFO / WARN / ERROR / FATAL
    path = vim.fn.stdpath("cache") .. "/NeoAI/neoai.log",
    max_size = 10485760,
    max_backups = 5,
  },
})
```

</details>

---

## 🧰 内置工具

NeoAI 内置了 40+ 工具，AI 可在对话中自动调用，涵盖以下类别：

### 📁 文件操作工具 (默认不更改代码的都自动允许)

| 工具名             | 描述             | 默认审批    |
| ------------------ | ---------------- | ----------- |
| `read_file`        | 读取文件内容     | ✅ 自动允许 |
| `edit_file`        | 编辑文件内容     | ❌ 需审批   |
| `list_files`       | 列出目录文件     | ✅ 自动允许 |
| `search_files`     | 搜索文件内容     | ✅ 自动允许 |
| `create_directory` | 创建目录         | ❌ 需审批   |
| `ensure_dir`       | 确保目录存在     | ❌ 需审批   |
| `delete_file`      | 删除文件         | ❌ 需审批   |
| `file_exists`      | 检查文件是否存在 | ✅ 自动允许 |

### 🌳 代码分析工具（Tree-sitter）Neovim >= 0.6 原生支持

| 工具名                 | 描述               | 默认审批    |
| ---------------------- | ------------------ | ----------- |
| `parse_file`           | 解析文件语法树     | ✅ 自动允许 |
| `query_tree`           | 查询语法树节点     | ✅ 自动允许 |
| `get_node_at_position` | 获取指定位置节点   | ✅ 自动允许 |
| `get_node_type`        | 获取节点类型       | ✅ 自动允许 |
| `get_node_range`       | 获取节点范围       | ✅ 自动允许 |
| `is_named_node`        | 检查是否为命名节点 | ✅ 自动允许 |
| `get_parent_node`      | 获取父节点         | ✅ 自动允许 |
| `get_child_nodes`      | 获取子节点列表     | ✅ 自动允许 |
| `get_node_code`        | 获取节点源代码     | ✅ 自动允许 |
| `delete_node`          | 删除语法树节点     | ❌ 需审批   |

### 🔧 LSP 工具 Neovim >= 0.12 原生支持

| 工具名                  | 描述                | 默认审批    |
| ----------------------- | ------------------- | ----------- |
| `lsp_hover`             | 获取悬停信息        | ✅ 自动允许 |
| `lsp_definition`        | 获取定义位置        | ✅ 自动允许 |
| `lsp_references`        | 获取引用位置        | ✅ 自动允许 |
| `lsp_implementation`    | 获取实现位置        | ✅ 自动允许 |
| `lsp_declaration`       | 获取声明位置        | ✅ 自动允许 |
| `lsp_document_symbols`  | 获取文档符号        | ✅ 自动允许 |
| `lsp_workspace_symbols` | 搜索工作区符号      | ✅ 自动允许 |
| `lsp_code_action`       | 获取代码操作建议    | ✅ 自动允许 |
| `lsp_rename`            | 重命名符号          | ❌ 需审批   |
| `lsp_format`            | 格式化代码          | ❌ 需审批   |
| `lsp_diagnostics`       | 获取诊断信息        | ✅ 自动允许 |
| `lsp_client_info`       | 获取 LSP 客户端信息 | ✅ 自动允许 |
| `lsp_signature_help`    | 获取函数签名        | ✅ 自动允许 |
| `lsp_completion`        | 获取补全建议        | ✅ 自动允许 |
| `lsp_type_definition`   | 获取类型定义        | ✅ 自动允许 |
| `lsp_service_info`      | 获取 LSP 服务信息   | ✅ 自动允许 |

### 💻 Shell 工具 支持交互式shell 由AI自动填写

| 工具名        | 描述                      | 默认审批                    |
| ------------- | ------------------------- | --------------------------- |
| `run_command` | 执行 Shell 命令（伪终端） | ❌ 需审批（支持参数白名单） |

### 🤖 子 Agent 工具

| 工具名                 | 描述                    | 默认审批    |
| ---------------------- | ----------------------- | ----------- |
| `create_sub_agent`     | 创建子 Agent 执行子任务 | ❌ 需审批   |
| `get_sub_agent_status` | 查询子 Agent 状态       | ✅ 自动允许 |
| `cancel_sub_agent`     | 取消子 Agent            | ✅ 自动允许 |

### 🪵 日志工具

| 工具名           | 描述             | 默认审批    |
| ---------------- | ---------------- | ----------- |
| `log_message`    | 记录日志消息     | ✅ 自动允许 |
| `get_log_levels` | 获取可用日志级别 | ✅ 自动允许 |

---

## 🏗️ 架构

基于 v2.0 架构指南（见 [styleGuide.md](styleGuide.md)），遵循**隔离、简洁、异步优先**设计哲学。

```
NeoAI/
├── init.lua                    # 主入口：极薄，仅 setup + 命令/快捷键注册，业务懒加载
├── default_config.lua          # 默认配置（纯数据，零逻辑）
│
├── kernel/                     # 内核层（最底层，零业务依赖）
│   ├── events.lua             # 事件常量注册表（domain:verb 命名）
│   ├── event_bus.lua          # 事件总线（发布/订阅）
│   ├── config_store.lua       # 配置存储（merge + validate + get + watch）
│   ├── logger.lua             # 分级日志（文件输出 + 轮转）
│   └── lifecycle.lua          # 生命周期（bootstrap/shutdown）
│
├── core/                       # 核心业务层
│   ├── session/               # 会话管理
│   │   ├── session.lua        # 会话对象（纯净数据 + fork 分支）
│   │   ├── session_store.lua  # 会话持久化（追加式 JSONL）
│   │   └── context_builder.lua# 上下文构建
│   ├── model/                 # 模型管理
│   │   ├── registry.lua       # 模型注册表（运行时动态更新）
│   │   ├── fetcher.lua        # 模型列表异步获取器（指数退避重试）
│   │   ├── adapter.lua        # 多提供商协议适配（openai/anthropic/google）
│   │   └── cache.lua          # 模型列表本地缓存
│   └── agent/                 # Agent 引擎
│       ├── agent.lua          # Agent 对象（每次对话全新实例 + AbortSignal）
│       ├── runtime.lua        # Agent 运行时（create/spawn/dispose/abort）
│       ├── request.lua        # 请求构建 + 发送 + 重试
│       ├── stream.lua         # 流式响应处理（SSE 解析）
│       └── tool_loop.lua      # 工具调用循环
│
├── services/                   # 服务层（连接 core 与 ui/tools）
│   ├── chat_service.lua       # 聊天服务（send/attach/detach）
│   ├── tool_service.lua       # 工具服务（审批 + 调度 + 执行）
│   └── model_service.lua      # 模型服务（list/set_active/prefetch）
│
├── ui/                         # 表现层
│   ├── window/                # 窗口管理（float/tab/split）
│   │   ├── manager.lua        # 窗口管理器
│   │   ├── chat_view.lua      # 聊天视图
│   │   └── tree_view.lua      # 会话树视图
│   ├── components/            # 可复用组件
│   │   ├── input_box.lua      # 输入框
│   │   ├── message_list.lua   # 消息列表渲染
│   │   ├── reasoning_panel.lua# 思考过程面板
│   │   ├── model_picker.lua   # 模型选择器（异步加载）
│   │   ├── tool_approval.lua  # 工具审批弹窗
│   │   ├── sub_agent_dock.lua # 子 Agent 监控
│   │   └── markdown_view.lua  # Markdown 渲染器
│   └── keymap.lua             # 按键映射（统一管理）
│
├── tools/                      # 工具系统
│   ├── registry.lua           # 工具注册表
│   ├── executor.lua           # 工具执行器（别名/审批/超时）
│   ├── validator.lua          # 参数校验 + 审批决策
│   ├── packer.lua             # 工具分组打包
│   └── builtin/               # 内置工具
│       ├── file_ops.lua       # 文件操作 + confirm_file_change
│       ├── shell.lua          # Shell 命令
│       ├── git_ops.lua        # Git 操作
│       ├── lsp_ops.lua        # LSP 工具
│       ├── tree_ops.lua       # Tree-sitter 工具
│       ├── log_ops.lua        # 日志工具
│       ├── plan.lua           # 子 Agent + 边界审核
│       └── tool_helpers.lua   # 工具定义辅助
│
├── utils/                      # 纯工具库（零业务依赖）
│   ├── async.lua             # Promise/Deferred/AbortSignal/retry
│   ├── json.lua              # JSON 编解码
│   ├── http.lua              # 异步 HTTP 客户端（curl jobstart，流式 SSE）
│   ├── fs.lua                # 文件操作（JSONL）
│   └── stringx.lua           # 字符串扩展
│
└── tests/                      # 测试（自定义运行器，:NeoAITest）
    ├── init.lua               # 断言 + 运行器
    ├── test_kernel.lua        # 内核层
    ├── test_session.lua       # 会话层
    ├── test_model_registry.lua# 模型层
    ├── test_agent.lua         # Agent 层
    ├── test_tools.lua         # 工具层
    ├── test_services.lua      # 服务层
    └── test_integration.lua   # 集成测试（mock server）
```

### 设计要点

- **环境隔离**：每次打开对话窗口 → 全新 Agent 实例（空消息队列 + 独立 AbortSignal），零残留
- **子 Agent 沙箱**：`runtime.spawn()` 创建全新环境，不继承父 Agent 的任何消息/状态
- **依赖单向**：`utils → kernel → core → services → ui/tools`，禁止跨层穿透
- **异步优先**：所有 I/O 异步，启动不阻塞 Neovim，模型列表后台拉取
- **取消信号**：AbortSignal 级联传播（HTTP 请求 + 工具调用），替代全局标志
- **事件驱动**：`event_bus` 基于 nvim autocmd 发布/订阅，事件名 `domain:verb`

---

## 📡 事件系统

NeoAI 基于 Neovim 原生 `User` 自动命令实现事件驱动架构，共定义了 60+ 事件：

| 事件类别     | 数量 | 说明                               |
| ------------ | ---- | ---------------------------------- |
| AI 生成事件  | 6    | 生成开始、完成、错误、取消、重试   |
| 流式处理事件 | 4    | 流式开始、数据块、完成、错误       |
| 推理事件     | 3    | 推理开始、内容到达、完成           |
| 工具相关事件 | 12   | 工具循环、执行、审批、调用检测     |
| 会话事件     | 7    | 创建、复用、加载、保存、删除、切换 |
| 分支事件     | 3    | 分支创建、切换、删除               |
| 消息事件     | 9    | 添加、编辑、删除、发送、清空       |
| 窗口/UI 事件 | 12+  | 打开、关闭、渲染、模式切换         |

所有事件常量定义在 `NeoAI.core.events` 模块中，详见 [docs/EVENTS.md](docs/EVENTS.md)。

---

## 🧪 测试

运行所有测试：

```vim
:NeoAITest
```

运行指定测试：

```vim
:NeoAITest flow_config flow_tools
```

---

## 📄 相关文档

| 文档                                                                       | 说明             |
| -------------------------------------------------------------------------- | ---------------- |
| [styleGuide.md](styleGuide.md)                                             | 架构设计指南     |
| [docs/EVENTS.md](docs/EVENTS.md)                                           | 事件系统文档     |
| [docs/IMPLEMENTED_EVENTS.md](docs/IMPLEMENTED_EVENTS.md)                   | 已实现事件列表   |
| [docs/NATIVE_EVENTS.md](docs/NATIVE_EVENTS.md)                             | 原生事件文档     |
| [docs/AI_RESPONSE_FLOW.md](docs/AI_RESPONSE_FLOW.md)                       | AI 响应流程      |
| [docs/chat_enhanced_usage.md](docs/chat_enhanced_usage.md)                 | 聊天增强使用指南 |
| [docs/ui_multithread_optimization.md](docs/ui_multithread_optimization.md) | UI 多线程优化    |
| [docs/threaded_testing.md](docs/threaded_testing.md)                       | 线程测试文档     |

---

## 🔧 开发

### 添加新工具

1. 在 `tools/builtin/` 下创建新文件
2. 使用 `define_tool` 辅助函数定义工具
3. 实现 `get_tools()` 函数返回工具定义列表
4. 重启 Neovim 或调用 `:lua require("NeoAI.tools").reload_tools()`

### 添加新 AI 提供商

1. 在配置的 `ai.providers` 中添加新提供商
2. 如有特殊 API 格式，在 `request_adapter.lua` 中注册适配器

### 运行测试

```vim
:NeoAITest           " 运行所有测试
:NeoAITest flow_tools  " 运行指定测试
```

---

## 📝 许可证

[MIT](LICENSE)
