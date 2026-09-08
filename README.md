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
- **多模态图像** — `read_image` 工具读入 PNG/JPEG/WebP/GIF 并注入多模态模型（内容寻址附件存储 + 请求期像素/字节预算 offload，模型不支持图像时自动降级为文本）
- **lualine 状态栏集成** — 在聊天窗口中用 `nvim-lualine` 实时展示大模型用量、缓存命中率与上下文容量（模型/用量/缓存/容量等段可自定义）
- **Herder 状态上报** — 在 Herder pane 内实时上报 Agent 作态（working/idle/blocked），多会话自动聚合，带严格递增 `--seq` 防并发回退
- **工具参数接收面板** — 模型流式生成工具调用参数时实时打开「接收参数」悬浮窗（`tool_args_panel`），随分片更新、参数结束后自动关闭，与思考过程悬浮窗一致

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
| `:NeoAICycleDisplay`| 循环切换聊天显示模式（对话/轨迹）                  |
| `:NeoAIReloadDisplay`| 热重载显示模式插件（缺省重载当前模式）            |
| `:NeoAIPlan`       | 切换计划模式（工具上下文只保留只读/信息查询 + 提问）|
| `:NeoAIAuto`       | 切换 AUTO 模式（自动允许所有工具调用）             |
| `:NeoAIApprovePlan`| 确认计划并转入 CHAT 模式按任务清单执行             |

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

    -- 按模式（CHAT / PLAN / AUTO）分别配置提供商与模型参数；
    -- 进入某模式时应用其 provider/model/temperature/max_tokens/stream，缺省回退 ai.default_provider。
    modes = {
      chat = { provider = "deepseek", model = "auto", temperature = 0.7, max_tokens = 4096, stream = true },
      plan = { provider = "deepseek", model = "auto", temperature = 0.3, max_tokens = 8192, stream = true },
      auto = { provider = "deepseek", model = "auto", temperature = 0.7, max_tokens = 8192, stream = true },
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
      switch_model = { key = "M", desc = "切换模型" },
      toggle_reasoning = { key = "r", desc = "切换思考过程显示" },
      cycle_mode = { key = "m", desc = "循环切换模式（CHAT/PLAN/AUTO）" },
      cycle_display = {
        insert = { key = "<C-t>", desc = "循环切换显示模式（对话/轨迹）" },
        normal = { key = "T", desc = "循环切换显示模式（对话/轨迹）" },
      },
      reload_display = { key = "<F5>", desc = "热重载当前显示模式插件" },
      approve_plan = { key = "P", desc = "确认计划并转入 CHAT 执行" },
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

  -- ===== Herder 终端状态信号 =====
  herder = {
    enabled = true,                      -- 是否启用上报（还需 HERDR_ENV=1 才生效；非 Herder 环境为 no-op）
    source = "custom:neoai",             -- 稳定且全局唯一的生命周期权威标识
    agent = "neoai",                     -- agent 名称（Herder 侧识别用）
  },
})
```

### 多模态（视觉）配置

NeoAI 支持把图像注入多模态模型：

```lua
ai = {
  -- ...其余配置...
  attachments = {
    enabled = true, -- 多模态总开关
    path = vim.fn.stdpath("cache") .. "/NeoAI/attachments", -- 内容寻址附件存储目录
    vision_models = {
      "deepseek-v4-flash-vision-exp", -- 声明支持图像输入的模型 id 或 provider:model
    },
    vision_model_heuristics = { "vision", "-vl", "4o", "gemini" }, -- 按 id 子串自动识别视觉模型
    media_types = { "image/png", "image/jpeg", "image/webp", "image/gif" },
    limits = {
      max_image_bytes = 20 * 1024 * 1024,
      max_images_per_message = 16,
      max_message_image_bytes = 40 * 1024 * 1024,
      max_image_pixels = 50000000,
      max_image_dimension = 8000,
    },
    request_image = {
      max_pixels = 640000, -- 单请求图像像素预算
      max_bytes = 1024 * 1024, -- 单请求图像编码字节上限
      max_images_per_request = 8, -- 单请求最多保留图像（超出丢最旧）
      max_request_bytes = 20 * 1024 * 1024,
    },
  },
}
```

> 图像内容寻址存储于 `attachments.path`，会话消息只保存不可变引用；发送请求时才解析为
> `image_url`（data URL）按模型 route 的像素/字节预算注入，超限的**最旧**图像被替换为
> 文本占位。模型不支持图像时自动降级，不阻塞调用。

### lualine 状态栏集成

NeoAI 会把当前 Agent 的大模型用量、缓存命中率、上下文容量等信息暴露给 `nvim-lualine`。
支持两种方式：

**方式一：自动（推荐）** — 无需任何配置。只要检测到 nvim-lualine，NeoAI 会自动把
`neoai` 扩展注入其配置：lualine 处于 `setup()` 之后时在 `NeoAI.setup()` 注入，
否则延迟到聊天窗口打开时注入（此时 lualine 必然已可用）。

**方式二：手动扩展** — 在 lualine 配置里显式声明（功能相同，适合喜欢显式配置的人）：

```lua
require("lualine").setup({
  extensions = { "neoai" },
  -- ...其余 lualine 配置
})
```

扩展在聊天窗口（`filetype` 为 `neoai` / `neoai_input` / `neoai_status`）自动用 NeoAI
状态栏替换默认状态栏；对扩展代码的改动需重新执行一次 setup 或重启生效。

**方式三：手动组件** — 保留自己的状态栏，只把 NeoAI 信息作为一段塞进任意 section：

```lua
require("lualine").setup({
  sections = {
    lualine_c = {
      { function() return require("NeoAI.services.status").component() end },
    },
  },
})
```

> 若自动注入因启动顺序没生效，可手动调用 `NeoAI.enable_statusline()` 或
> `require("NeoAI.services.status").ensure_lualine_extension()`。

只接管聊天**主消息窗口**（`filetype == neoai`），输入框等其它窗口保留你自己
的 lualine，不被污染。展示刻意简洁，干净分行、无重复、无成片截断：

- **第 1 行（winbar）** 身份：`[模式] 模型 状态`
- **第 2 行（statusline）** 指标：`↑prompt ↓completion 缓存命中x% 剩余容量y% 待发N`

> `待发N`：Agent 正忙（generating / tool_running / 生成槽被占用）时你发送的消息会先暂存，
> 状态栏出现该徽标提醒；消息真正发送后徽标自动消失（计数归零不渲染）。

各段默认链接到**鲜艳的 nvim 高亮组**（`Title`/`Type`/`Number`/`String`/`Statement`/`Function`/`Keyword`），
active 与 inactive 一致，杜绝无焦点时整行变灰（虚化）。

关于多行：单独的 `statusline` 只能占一行（Vim 原生不支持换行）。NeoAI 用主消息窗口
的 `winbar` 作为第二行，从而得到干净的两行；其余窗口保持单行。若只想一行，设 `ui.statusline.winbar = false`。

```lua
require("NeoAI").setup({
  ui = {
    statusline = {
      enabled = true,                                   -- false → 组件返回空串
      winbar = true,                                    -- 主聊天窗口顶部第二行（模式/模型/状态）
      parts = { "mode", "model", "usage", "cache", "capacity" }, -- component() 拼接的段顺序
      separator = " ",                                  -- 段间分隔符
      colors = {                                        -- 各段链接的高亮组（去掉灰暗配色）
        mode = "Title",        display = "Keyword",
        model = "Type",        usage = "Number",
        cache = "String",      capacity = "Statement",
        state = "Function",    brand = "Title",
      },
    },
  },
})
```

相关公开 API：

- `NeoAI.get_statusline_info()` — 返回当前 Agent 的用量/缓存/容量结构化数据
- `NeoAI.get_statusline()` — 返回状态栏文本
- `require("NeoAI.services.status").segment(name)` — 单个段文本（mode/model/usage/cache/capacity/state/display/pending）
- `require("NeoAI.services.chat_service").pending_count()` — 当前 Agent 正忙时暂存的待发消息数
- `:NeoAIStatusline` — 预览当前状态栏组件内容

### Herder 终端状态集成

NeoAI 可以在 **Herder** 管理的 pane 内向 Herder 上报 AI Agent 的真实作态（`working` / `idle` / `blocked`），
让 Herder 侧边栏实时反映 Agent 状态，而不是靠屏幕输出启发式猜测。本集成只负责**信号生成端**——
把 NeoAI 的 Agent 生命周期翻译成 Herder 语义并上报；Herder 侧的识别/解析由 Herder 自身处理。

**生效条件**（缺一不可）：

1. 运行在 Herder 注入环境的 pane 内（存在环境变量 `HERDR_ENV=1`、`HERDR_PANE_ID`、`HERDER_BIN_PATH`）；
2. `herder.enabled = true`（默认开启）。

非 Herder 环境下本模块完全 no-op：不订阅事件、不产生任何副作用。

**状态映射**：

| NeoAI Agent 状态 | Herder 上报 |
|---|---|
| `generating` / `tool_running` | `working` |
| 工具审批等待 / `ask_user` 等待用户回答 | `blocked` |
| `idle` / `aborted` / `error` | `idle` |

**多会话聚合**：单个 Neovim pane 内可能有多个 AI 会话（含子 Agent），NeoAI 聚合成一个固定的
`source`（默认 `custom:neoai`）统一上报，聚合优先级为 `blocked > working > idle`。所有上报带
严格递增的 `--seq`，令 Herder 忽略同一 `source` 的旧包，避免并发/异步回调导致状态回退。

**上报流程示例**：

```
# 用户发送消息，Agent 进入生成
herdr pane report-agent w1:p1 --source custom:neoai --agent neoai --state working --seq 1
# 工具需要审批 / 向用户提问等待回答（阻塞）
herdr pane report-agent w1:p1 --source custom:neoai --agent neoai --state blocked --seq 2
# 审批通过、仍在生成
herdr pane report-agent w1:p1 --source custom:neoai --agent neoai --state working --seq 3
# 本轮生成完成、等待输入
herdr pane report-agent w1:p1 --source custom:neoai --agent neoai --state idle --seq 4
# 关闭聊天窗口、最后一个 Agent 销毁（释放生命周期权威）
herdr pane release-agent w1:p1 --source custom:neoai --agent neoai --seq 5
```

**配置**：

```lua
require("NeoAI").setup({
  herder = {
    enabled = true,           -- 是否启用上报（还需 HERDR_ENV=1 才真正生效）
    source = "custom:neoai",  -- 稳定且全局唯一的生命周期权威标识
    agent = "neoai",          -- agent 名称（Herder 侧识别用）
  },
})
```

> 诊断：在 Herder pane 内用 `herdr agent explain <pane-id>` 可查看当前 Agent 状态来源与最近上报。

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
| `read_image`       | 读取图像文件，把图像注入多模态模型 | ✅ 自动允许 |

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

| 工具名        | 描述               | 默认审批                    |
| ------------- | ------------------ | --------------------------- |
| `run_command` | 执行 Shell 命令（非交互，异步 jobstart） | ❌ 需审批（支持参数白名单 `ls`/`wc`/`find`/`grep`/`pwd`） |

### 🔄 Git 工具

| 工具名                  | 描述                     | 默认审批    |
| ----------------------- | ------------------------ | ----------- |
| `git_status`            | 查看 git 状态（--short） | ✅ 自动允许 |
| `git_diff`              | 查看未提交改动           | ✅ 自动允许 |
| `git_log`               | 查看提交历史             | ✅ 自动允许 |
| `git_commit_detail`     | 查看某次提交详情         | ✅ 自动允许 |
| `git_branch`            | 查看分支列表（-a）       | ✅ 自动允许 |
| `git_file_history`      | 查看文件历史             | ✅ 自动允许 |
| `git_rollback`          | 回滚文件到指定提交       | ❌ 需审批   |
| `git_auto_commit_config`| 查看/设置自动提交配置    | ✅ 自动允许 |

### 🤖 子 Agent 工具

| 工具名                 | 描述                                                      | 默认审批    |
| ---------------------- | --------------------------------------------------------- | ----------- |
| `create_sub_agent`     | 创建子 Agent 执行子任务（支持 `foreground` 前台等待结果；`mode` 可选，`boundaries` 可选约束） | ❌ 需审批   |
| `wait_sub_agent`       | 等待子 Agent 完成并返回完整结果（若已完成则立即返回）     | ❌ 需审批   |
| `get_sub_agent_status` | 查询子 Agent 状态与结果                                   | ✅ 自动允许 |
| `cancel_sub_agent`     | 取消子 Agent                                              | ✅ 自动允许 |

### 📋 待办与计划

| 工具名            | 描述                                           | 默认审批    |
| ----------------- | ---------------------------------------------- | ----------- |
| `todo_write`      | 整表替换任务清单（自动注入系统提示）           | ✅ 自动允许 |
| `todo_read`       | 读取当前任务清单                               | ✅ 自动允许 |
| `todo_clear`      | 清空任务清单                                   | ✅ 自动允许 |
| `enter_plan_mode` | 进入计划模式（工具上下文切换为只读/信息 + 提问）| ✅ 自动允许 |

### 💬 向用户提问

| 工具名     | 描述                                     | 默认审批    |
| ---------- | ---------------------------------------- | ----------- |
| `ask_user` | 暂停生成并向用户提问，回答回传为工具结果 | ✅ 自动允许 |

> **计划模式（PLAN MODE）**：激活时工具上下文**只包含只读/信息查询工具与 `ask_user`**，
> 不暴露任何修改类工具（编辑/删除/创建/写命令/git 回滚等）；执行期门禁同步收紧，
> 调用可见集之外的任何工具都会被驳回。AI 在此模式下调研、提问澄清，
> 并输出**清晰、格式化的修改计划**（目标与背景 / 改动清单 / 实施步骤 / 验证与回滚）。
> 计划经用户确认（聊天窗口按 `P` 或执行 `:NeoAIApprovePlan`）后，
> **直接转入 CHAT 模式**，系统把计划解析为任务清单（todo），
> 并按 `tools.plan_mode.auto_execute_on_approve`（默认开启）自动开始执行。

### 🪵 日志工具

| 工具名           | 描述             | 默认审批    |
| ---------------- | ---------------- | ----------- |
| `log_message`    | 记录日志消息     | ✅ 自动允许 |
| `get_log_levels` | 获取可用日志级别 | ✅ 自动允许 |

---

## 🏗️ 架构

基于 v3.0 架构指南（见 [styleGuide.md](styleGuide.md)），遵循**隔离、简洁、异步优先**设计哲学。

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
│   │   ├── content.lua        # 多模态消息物化（图像引用→wire part）
│   │   └── cache.lua          # 模型列表本地缓存
│   ├── attachment/            # 附件（多模态图像）
│   │   └── attachment.lua     # 内容寻址附件存储 + 门禁（vision 支持/类型/上限）
│   └── agent/                 # Agent 引擎
│       ├── agent.lua          # Agent 对象（每次对话全新实例 + AbortSignal）
│       ├── runtime.lua        # Agent 运行时（create/spawn/dispose/abort）
│       ├── request.lua        # 请求构建 + 发送 + 重试
│       ├── stream.lua         # 流式响应处理（SSE 解析）
│       └── tool_loop.lua      # 工具调用循环
│
├── services/                   # 服务层（连接 core 与 ui/tools）
│   ├── chat_service.lua       # 聊天服务（send/attach/detach/approve_plan/cycle_mode）
│   ├── tool_service.lua       # 工具服务（审批 + 调度 + 执行，串行审批队列）
│   ├── model_service.lua      # 模型服务（list/set_active/prefetch）
│   ├── status.lua             # 状态栏服务（lualine 集成，段拼接 + 高亮）
│   └── herder.lua             # Herder 终端状态上报（working/idle/blocked）
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
│   ├── work.lua              # 线程池（阻塞式文件 I/O / 图像解码在线程池执行）
│   ├── timer.lua             # 可暂停计时器（工具活跃耗时，剔除等待时间）
│   ├── image.lua             # 图像类型检测/媒体类型
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

NeoAI 基于 Neovim 原生 `User` 自动命令实现事件驱动架构，事件常量定义在 `NeoAI.kernel.events` 模块（事件总线为 `NeoAI.kernel.event_bus`，触发时自动加 `NeoAI:` 前缀）。按分区统计如下：

| 事件分区         | 数量 | 说明                               |
| ---------------- | ---- | ---------------------------------- |
| Agent 生命周期   | 5    | 创建、派生、销毁、中止、状态变更   |
| 生成/流式        | 8    | 生成开始、完成、错误、取消、流式   |
| 推理             | 3    | 推理开始、内容到达、完成           |
| 消息             | 6    | 添加、更新、编辑、删除、发送、清空 |
| 会话             | 7    | 创建、加载、保存、删除、切换、重命名、分支 |
| 分支/树          | 3    | 分支创建、删除、树刷新             |
| 工具             | 13   | 工具循环、执行、审批、调用检测、护栏 |
| 用户提问         | 2    | 等待用户回答开始、回答/取消结束    |
| 工具参数接收     | 2    | `tool:arg_chunk` / `tool:arg_completed` |
| 待办/计划模式    | 2    | 待办更新、计划模式变更             |
| 模型             | 4    | 模型更新、切换、刷新开始、刷新失败 |
| UI/窗口          | 5    | 打开、关闭、刷新、模式、显示模式   |
| 子 Agent         | 5    | 创建、更新、完成、错误、结果就绪   |
| 配置/生命周期    | 4    | 配置加载、变更、初始化、关闭       |
| 日志/上下文压缩  | 3    | 日志消息、压缩开始、压缩完成       |

详见 [docs/EVENTS.md](docs/EVENTS.md)（唯一权威事件文档）。

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
| [docs/EVENTS.md](docs/EVENTS.md)                                           | 事件系统文档（唯一权威） |
| [docs/overview.md](docs/overview.md)                                       | 插件总览         |
| [docs/ai_engine.md](docs/ai_engine.md)                                     | Agent 引擎       |
| [docs/tool_system.md](docs/tool_system.md)                                 | 工具系统         |
| [docs/ui_system.md](docs/ui_system.md)                                     | UI 系统          |
| [docs/sub_agent_system.md](docs/sub_agent_system.md)                       | 子 Agent 系统    |
| [docs/configuration.md](docs/configuration.md)                             | 配置系统         |
| [docs/chat_enhanced_usage.md](docs/chat_enhanced_usage.md)                 | 聊天增强使用指南 |

---

## 🔧 开发

### 添加新工具

1. 在 `tools/builtin/` 下创建新文件
2. 使用 `define_tool` 辅助函数定义工具
3. 实现 `get_tools()` 函数返回工具定义列表
4. 重启 Neovim 或调用 `:lua require("NeoAI.tools").reload_tools()`

### 添加新 AI 提供商

1. 在配置的 `ai.providers` 中添加新提供商
2. 如有特殊 API 格式，在 `core/model/adapter.lua` 中注册适配器

### 运行测试

```vim
:NeoAITest           " 运行所有测试
:NeoAITest flow_tools  " 运行指定测试
```

---

## 📝 许可证

[MIT](LICENSE)
