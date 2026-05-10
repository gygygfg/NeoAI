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

vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    require("NeoAI").setup({})
  end,
})

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
    default = "balanced",
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
    default = "balanced",                   -- 默认预设名称

    -- 提供商定义（支持 13+ 家 AI 服务商）
    providers = {
      deepseek = {
        api_type = "openai",                -- API 类型：openai / anthropic / google
        base_url = "https://api.deepseek.com/chat/completions",
        api_key = os.getenv("DEEPSEEK_API_KEY"),
        models = { "deepseek-v4-flash", "deepseek-v4-pro" },
      },
      openai = {
        api_type = "openai",
        base_url = "https://api.openai.com/v1/chat/completions",
        api_key = os.getenv("OPENAI_API_KEY"),
        models = { "gpt-4o", "gpt-4o-mini", "gpt-4-turbo" },
      },
      anthropic = {
        api_type = "anthropic",
        base_url = "https://api.anthropic.com/v1/messages",
        api_key = os.getenv("ANTHROPIC_API_KEY"),
        models = { "claude-sonnet-4-20250514", "claude-3-5-sonnet-20241022" },
      },
      -- 更多提供商：google, groq, together, openrouter, siliconflow,
      -- moonshot, zhipu, baidu, aliyun, stepfun
    },

    -- 场景化模型配置
    scenarios = {
      naming    = { { provider = "deepseek", model_name = "deepseek-v4-flash", temperature = 0.3 } },
      chat      = { { provider = "deepseek", model_name = "deepseek-v4-flash", temperature = 0.7 } },
      reasoning = { { provider = "deepseek", model_name = "deepseek-v4-pro",  temperature = 0.7 } },
      coding    = { { provider = "deepseek", model_name = "deepseek-v4-pro",  temperature = 0.2 } },
      tools     = { { provider = "deepseek", model_name = "deepseek-v4-flash", temperature = 0.3 } },
      agent     = { { provider = "deepseek", model_name = "deepseek-v4-pro",  temperature = 0.7 } },
    },

    reasoning_enabled = true,               -- 启用深度思考模式
    system_prompt = "你是一个AI编程助手，帮助用户解决编程问题。",
  },

  -- ===== UI 配置 =====
  ui = {
    default_ui = "tree",                    -- 默认界面：tree / chat
    window_mode = "tab",                    -- 窗口模式：float / tab / split
    window = {
      width = 80,
      height = 20,
      border = "rounded",
    },
    split = {
      size = 80,
      chat_direction = "right",
      tree_direction = "right",
    },
  },

  -- ===== 键位配置 =====
  keymaps = {
    global = {
      open_tree = { key = "<leader>at", desc = "打开树界面" },
      open_chat = { key = "<leader>ac", desc = "打开聊天界面" },
      close_all = { key = "<leader>aq", desc = "关闭所有窗口" },
      toggle_ui = { key = "<leader>aa", desc = "切换UI显示" },
    },
    tree = {
      select        = { key = "<CR>", desc = "选择节点/分支" },
      new_child     = { key = "n",    desc = "新建子分支" },
      new_root      = { key = "N",    desc = "新建根分支" },
      delete_dialog = { key = "d",    desc = "删除对话" },
      delete_branch = { key = "D",    desc = "删除分支" },
    },
    chat = {
      insert          = { key = "i",       desc = "进入插入模式" },
      quit            = { key = "q",       desc = "关闭聊天窗口" },
      send            = { insert = { key = "<C-s>" }, normal = { key = "<CR>" } },
      cancel          = { key = "<Esc>",   desc = "取消生成" },
      switch_model    = { key = "m",       desc = "切换模型" },
      toggle_reasoning= { key = "r",       desc = "切换思考过程显示" },
      tool_approval   = { key = "<C-a>",   desc = "工具审批" },
      approval = {
        confirm            = { key = "<CR>", desc = "允许一次" },
        confirm_all        = { key = "A",    desc = "允许所有" },
        cancel             = { key = "<Esc>",desc = "取消" },
        cancel_with_reason = { key = "C",    desc = "取消并说明" },
      },
    },
  },

  -- ===== 会话配置 =====
  session = {
    auto_save = true,
    auto_naming = true,
    save_path = vim.fn.stdpath("cache") .. "/NeoAI",
    max_history_per_session = 1000,
  },

  -- ===== 工具配置 =====
  tools = {
    enabled = true,
    builtin = true,
    approval = {
      default_auto_allow = false,
      tool_overrides = {
        read_file      = { auto_allow = true },
        edit_file      = { auto_allow = false },
        list_files     = { auto_allow = true },
        search_files   = { auto_allow = true },
        delete_file    = { auto_allow = false },
        run_command    = { auto_allow = false },
        create_sub_agent = { auto_allow = false },
        -- 更多工具审批配置...
      },
    },
  },

  -- ===== 日志配置 =====
  log = {
    level = "WARN",       -- DEBUG / INFO / WARN / ERROR / FATAL
    max_file_size = 10485760,
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

```
NeoAI/
├── init.lua                 # 主入口：setup / 命令注册 / 全局快捷键
├── default_config.lua       # 默认配置定义
│
├── core/                    # 核心业务逻辑
│   ├── init.lua             # 核心模块入口
│   ├── events.lua           # 事件常量定义（60+ 事件）
│   ├── shutdown_flag.lua    # 全局关闭标志
│   │
│   ├── config/              # 配置管理
│   │   ├── init.lua         # 配置模块入口
│   │   ├── merger.lua       # 配置合并器（验证→合并→清理→日志初始化）
│   │   ├── keymap_manager.lua # 键位配置管理器
│   │   └── state.lua        # 协程上下文管理器
│   │
│   ├── history/             # 历史管理
│   │   ├── manager.lua      # 会话 CRUD、消息管理
│   │   ├── persistence.lua  # 文件序列化/事务性保存
│   │   ├── cache.lua        # 树结构/列表缓存
│   │   ├── saver.lua        # 事件驱动的异步写入器
│   │   └── message_builder.lua # 消息构建器
│   │
│   └── ai/                  # AI 交互
│       ├── init.lua         # AI 模块入口
│       ├── ai_engine.lua    # AI 引擎（主编排器）
│       ├── chat_service.lua # 后端聊天服务
│       ├── http_client.lua  # HTTP 客户端（流式/非流式）
│       ├── request_adapter.lua # 多 API 格式转换适配器
│       ├── request_builder.lua # 请求构建器
│       ├── stream_processor.lua # 流式数据处理器
│       ├── tool_orchestrator.lua # 工具调用编排器
│       ├── sub_agent_engine.lua # 子 Agent 引擎
│       ├── response_retry.lua   # 响应重试模块
│       ├── generation_handler.lua # 生成完成处理器
│       └── session_manager.lua # 工具循环会话管理
│
├── ui/                      # 用户界面
│   ├── init.lua             # UI 模块入口
│   ├── ui_events.lua        # UI 事件监听器
│   ├── window/
│   │   ├── window_manager.lua # 窗口管理器（float/tab/split）
│   │   ├── chat_window.lua    # 聊天窗口
│   │   └── tree_window.lua    # 会话树窗口
│   ├── components/
│   │   ├── input_handler.lua    # 输入处理器
│   │   ├── history_tree.lua     # 历史树组件
│   │   ├── reasoning_display.lua # 推理过程显示
│   │   ├── virtual_input.lua    # 虚拟输入框
│   │   ├── approval_config_editor.lua # 审批配置编辑器
│   │   ├── sub_agent_monitor.lua  # 子 Agent 监控
│   │   ├── pty_terminal.lua      # 伪终端组件
│   │   ├── tool_display.lua      # 工具调用展示
│   │   └── history_tree.lua      # 历史树
│   └── handlers/
│       ├── tree_handlers.lua  # 树界面事件处理器
│       └── chat_handlers.lua  # 聊天界面事件处理器
│
├── tools/                   # 工具系统
│   ├── init.lua             # 工具模块入口
│   ├── tool_registry.lua    # 工具注册表
│   ├── tool_executor.lua    # 工具执行器
│   ├── tool_validator.lua   # 工具验证器
│   ├── tool_pack.lua        # 工具包管理（按类别分组）
│   ├── approval_handler.lua # 工具审批处理器
│   ├── approval_state.lua   # 审批共享状态
│   └── builtin/             # 内置工具
│       ├── file_tools.lua      # 文件操作工具
│       ├── shell_tools.lua     # Shell 命令（伪终端+PID监控）
│       ├── neovim_tree.lua     # Tree-sitter 语法树工具
│       ├── neovim_lsp.lua      # LSP 工具
│       ├── general_tools.lua   # 通用工具
│       ├── log_tools.lua       # 日志工具
│       ├── plan_executor.lua   # 执行计划/边界审核
│       └── tool_helpers.lua    # 工具定义辅助函数
│
├── utils/                   # 工具库
│   ├── init.lua             # 工具模块入口
│   ├── logger.lua           # 日志系统
│   ├── json.lua             # JSON 编解码
│   ├── file_utils.lua       # 文件操作
│   ├── http_utils.lua       # HTTP 工具函数
│   ├── table_utils.lua      # 表操作
│   ├── common.lua           # 通用函数（深拷贝等）
│   ├── async_worker.lua     # 异步工作器
│   └── skiplist.lua         # 跳表数据结构
│
├── tests/                   # 测试
│   ├── init.lua             # 测试入口（断言工具、测试运行器）
│   ├── test_config.lua      # 配置测试
│   ├── test_ai_core.lua     # AI 核心测试
│   ├── test_tools.lua       # 工具系统测试
│   ├── test_history.lua     # 历史管理测试
│   ├── test_sub_agent.lua   # 子 Agent 测试
│   ├── test_integration.lua # 端到端集成测试
│   └── ...                  # 更多测试
│
├── docs/                    # 文档
│   ├── EVENTS.md             # 事件系统文档
│   ├── AI_RESPONSE_FLOW.md   # AI 响应流程
│   ├── chat_enhanced_usage.md # 聊天增强使用指南
│   ├── ui_multithread_optimization.md # UI 多线程优化
│   └── ...
│
├── styleGuide.md            # 架构设计指南
└── README.md                # 本文件
```

### 启动流程

```
用户调用 setup(config)
    │
    ▼
config_merger.process_config(config)  ← 验证→合并→清理→日志初始化
    │
    ▼
core.initialize(config)               ← 初始化AI引擎、历史管理器、聊天服务
    │
    ▼
ui.initialize(config)                 ← 初始化窗口管理器、各UI组件
    │
    ▼
tools.initialize(config)              ← 初始化工具注册表、执行器、验证器
    │
    ▼
vim.schedule → 延迟加载内置工具       ← 异步注册 file_tools, shell_tools 等
    │
    ▼
注入工具到 AI 引擎                    ← AI 可调用所有已注册工具
    │
    ▼
注册命令和快捷键                      ← :NeoAIChat, :NeoAITree 等
```

### 架构设计要点

- **事件驱动** — 所有模块通过 `nvim_exec_autocmds(User)` 通信，不直接耦合
- **闭包内私有状态** — 各模块使用闭包变量维护私有状态，不暴露内部实现
- **回调模式** — 工具函数采用 `func(args, on_success, on_error)` 异步回调模式
- **配置合并** — 用户配置与默认配置通过 `config_merger` 深度合并
- **前后端分离** — `chat_service` 作为后端入口，`chat_handlers` 和 `chat_window` 作为前端

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
:NeoAITest test_config test_tools
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
:NeoAITest test_tools " 运行指定测试
```

---

## 📝 许可证

[MIT](LICENSE)
