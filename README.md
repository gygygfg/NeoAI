# NeoAI

> [English](README.en.md) | **中文**

> 🧠 **NeoAI** — 一款功能强大的 Neovim AI 编程助手插件，集成多模型 AI 对话、文件操作、代码分析和 Shell 命令执行等能力，支持树形会话管理和子 Agent 协作。

---

## ✨ 特性

- **多 AI 提供商支持** — 内置 DeepSeek、OpenAI、Anthropic、Google Gemini、Groq、Together AI、OpenRouter、SiliconFlow、月之暗面、智谱、百度、阿里云、阶跃星辰等 13+ 家 AI 服务商
  - (钞能力有限，只测试了DeepSeek)
- **按模型自动选择** — 请求参数格式与缓存命中计算方案随模型自动适配：协议族编解码（OpenAI/Anthropic/Gemini 消息·工具·图像）+ 厂商方言（`max_tokens`/`max_completion_tokens`、`reasoning_effort`/`thinking`/`enable_thinking` 等）+ 模型能力表（上下文窗口/输出上限/缓存机制）+ 显式缓存（Anthropic 断点 / OpenAI explicit / Gemini `cachedContents`，失败自动降级为隐式），未知模型安全回退（见 [docs/model_policy.md](docs/model_policy.md)）
- **场景化模型配置** — 按场景（聊天、编程、思考、工具执行、子 Agent、窗口命名）分配不同的 AI 模型和参数
- **流式响应** — 实时流式显示 AI 生成内容，支持推理过程（reasoning）展示
- **树形会话管理** — 基于分支树管理多个对话会话，支持分支创建、切换、删除
- **丰富的内置工具** — AI 可调用文件操作、代码分析、LSP、Shell 命令等 40+ 工具
- **工具审批系统** — 细粒度的工具执行权限控制，支持自动允许/手动审批/参数级别白名单
- **计划模式（PLAN）与计划蒸馏** — 按 `m` 或 `:NeoAIPlan` 切换，工具上下文只保留只读/信息查询 + `ask_user` + `exit_plan_mode`（不暴露任何修改类工具）；AI 调研澄清后输出格式化修改计划，调用 `exit_plan_mode` 经用户确认后转入 CHAT 并按任务清单自动执行，并把计划阶段调研上下文**蒸馏**为检查点替换压缩
- **流式上下文压缩** — 接近上下文阈值时自动折叠旧历史、以检查点**替换**（非追加）被折叠区间，保持前缀缓存可复用；除回合边界外，**工具循环每轮发送前也会做压力检查**（工具结果已回写、下一轮请求前），长循环逐轮收敛；溢出时自动压缩后重试；压缩/计划蒸馏过程以悬浮窗实时展示推理与正文
- **子 Agent 系统** — AI 可创建子 Agent 并行执行子任务，支持边界审核
- **前后端分离架构** — 事件驱动的异步架构，UI 与业务逻辑解耦
- **高度可配置** — 完整的键位绑定、UI 布局、日志级别等自定义配置
- **纯lua编写** — 无需安装额外的依赖
- **⚠️⚠️⚠️使用curl发送请求** 环境变量内没有curl可能无法发送请求
- **待发消息队列** — Agent 正忙时发送的消息自动暂存，状态栏出现 `待发N` 徽标提醒，消息真正发送后徽标消失
- **多模态图像** — `read_image` 工具读入 PNG/JPEG/WebP/GIF 并注入多模态模型（内容寻址附件存储 + 请求期像素/字节预算 offload，模型不支持图像时自动降级为文本）
- **网页抓取（web_fetch）** — 把动态网页（React/Vue/SPA）在无头浏览器中渲染、注入 JS 后取最终 DOM，再用通用转换器转成 Markdown 供模型阅读；**默认不启用**，开启后在缓存目录自动检查并安装依赖，结果按 URL 缓存（默认上限 500MB）
- **lualine 状态栏集成** — 在聊天窗口中用 `nvim-lualine` 实时展示大模型用量、缓存命中率与上下文容量（模型/用量/缓存/容量等段可自定义）
- **Herder 状态上报** — 在 Herder pane 内实时上报 Agent 作态（working/idle/blocked），多会话自动聚合，带严格递增 `--seq` 防并发回退
- **工具参数接收面板** — 模型流式生成工具调用参数时实时打开「接收参数」悬浮窗（`tool_args_panel`），随分片增量追加、参数结束后自动关闭，与思考过程悬浮窗一致
- **MCP 支持** — 通过 stdio / Streamable HTTP 连接外部 MCP 服务器，把远端 `tools`/`resources`/`prompts` 注册进工具系统（含预缓存 + 失败驱动的动态刷新，见 [docs/mcp.md](docs/mcp.md)）
- **Skills 支持** — 扫描 SKILL.md 技能目录，把可用技能列表注入系统提示，模型用 `load_skill` 装载技能正文（Claude/opencode 风格，见 [docs/skills.md](docs/skills.md)）
- **工具执行沙箱** — 所有工具执行经控制面（预检 → 隔离执行 → 冻结候选 → CAS 发布）；默认异步审批：AI 的修改立即在沙箱内执行并冻结候选，真实工作区改动进入待审队列（聊天窗口状态栏显示醒目的 `待审N` 徽标），用户用 `:NeoAISandboxReview` 或聊天窗口内 `<leader>ap` 键异步确认后应用（审批单位为单个文件）；外部进程经 bwrap/unshare 隔离；命令可写整个文件系统（改动进暂存/候选）、会话内 shell 状态（export/cd）保留；载荷默认 `--cap-drop ALL` + seccomp 基线，并遮蔽 `docker.sock`、宿主凭据等敏感路径（纵深防御）；**权限档位**：命令默认最小权限运行（默认隔离网络），权限不足自动发起升级——T1（网络/受控 docker）隔离内自动执行并留痕，T2（cap/宿主操作）在嵌套 userns 内执行、主机效果冻结为提案异步审批；受控 docker 指向外部受控 socket（rootless/proxy/dind），不绑定宿主 socket（见 [docs/sandbox.md](docs/sandbox.md)）

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
| `:NeoAIReloadAll`  | 热重载整个 NeoAI 插件（先做隔离预检，失败则取消）  |
| `:NeoAIPlan`       | 切换计划模式（工具上下文只保留只读/信息查询 + 提问）|
| `:NeoAIAuto`       | 切换 AUTO 模式（自动允许所有工具调用）             |
| `:NeoAIApprovePlan`| 确认计划并转入 CHAT 模式按任务清单执行             |
| `:NeoAISandboxCommit`| 应用沙箱候选到真实工作区（CAS 发布，参数为候选摘要）|
| `:NeoAISandboxReview`| 列出待审修改并选择应用（异步审批）              |
| `:NeoAISandboxApprove` / `:NeoAISandboxReject` | 批准（不应用）/ 拒绝并丢弃变更单元 |
| `:NeoAISandboxApply` / `:NeoAISandboxApplyAll` | 批准并应用单个 / 全部待审变更单元 |
| `:NeoAISandboxGrant` / `:NeoAISandboxRevoke` | 创建窄范围任务授权 / 撤销授权 |
| `:NeoAISandboxPrune` / `:NeoAISandboxMetrics` | 清理过期候选 / 显示沙箱指标 |
| `:NeoAISandboxPublish` / `:NeoAISandboxReplay` | 组合发布多个变更单元 / 回放策略裁决 |
| `:NeoAISandboxList` / `:NeoAISandboxShow` | 列出/查看待处理沙箱候选 |
| `:NeoAISandboxDiscard`| 丢弃沙箱候选（参数为候选摘要）                  |
| `:NeoAISandboxCaps`| 显示沙箱运行时能力探测结果                        |
| `:NeoAIStatusline` | 预览当前 lualine 状态栏组件内容                    |

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
    -- 进入某模式时应用其 provider/model/temperature/stream，缺省回退 ai.default_provider。
    -- max_tokens 缺省不配置：请求不发送该参数，由模型/厂商默认最大输出决定；仅显式配置时才下发。
    modes = {
      chat = { provider = "deepseek", model = "auto", temperature = 0.7, stream = true },
      plan = { provider = "deepseek", model = "auto", temperature = 0.3, stream = true },
      auto = { provider = "deepseek", model = "auto", temperature = 0.7, stream = true },
    },

    -- 输出被截断（finish_reason=length/max_tokens/MAX_TOKENS）且无工具调用时自动续写：
    -- 续写提示只进请求、不落库；达到次数上限仍截断则写可见提示（见 docs/ai_engine.md 4.5）。
    truncation = { enabled = true, max_continues = 3 },

    reasoning_enabled = true,            -- 启用深度思考模式
    system_prompt = "你是一个AI编程助手，帮助用户解决编程问题。",
    timeout_ms = 60000,                  -- 请求超时
    max_retries = 3,                     -- 请求重试次数

    -- 按模型自动选择：能力表 + 厂商方言 + 显式缓存（见 docs/model_policy.md）
    model_policy = {
      enabled = true,                    -- 总开关（关闭后仅保留三协议基础编解码）
      explicit_cache = {
        enabled = true,                  -- 显式缓存总开关
        openai = false,                  -- OpenAI 显式断点默认关闭（隐式缓存已足够）
        -- anthropic = true, gemini = true, -- 分机制开关（缺省跟随总开关）
      },
      -- overrides = {                    -- 能力覆盖（key = 模型 id 或 provider 名）
      --   ["deepseek-v4-flash"] = { window = 131072, max_output = 8192 },
      -- },
      -- dialects = {                     -- 方言覆盖（key = provider 名 或 模型 id）
      --   ["my-provider"] = { max_tokens_field = "max_completion_tokens", reasoning_kind = "effort" },
      -- },
    },

    -- 前缀缓存身份一致性 + 自动上下文压缩
    context_cache = {
      enabled = true,                    -- 启用身份一致 + 自动压缩
      context_window = 64000,            -- 兜底窗口：用户显式非默认值优先，否则按模型能力表推导
      threshold_ratio = 0.8,             -- 达到该比例触发压缩
      warn_ratio = 0.85,                 -- 接近上限时状态栏变色提示
      retain_ratio = 0.16,               -- 保留的最近历史比例
      retain_min_tokens = 4096,          -- 尾部保留下限（token）
      compact_max_tokens = 8192,         -- 压缩摘要输出上限
      min_shadow_messages = 2,           -- 至少折叠多少条才值得压缩
      compaction_retries = 1,            -- 摘要后仍高于阈值的重试次数
      prune_enabled = true,              -- 摘要前先做模型无关的工具结果裁剪
      prune_threshold_chars = 8192,      -- 文本码点超过该值的工具结果才裁剪
      prune_head_chars = 4096,           -- 裁剪保留的头部码点数
      prune_tail_chars = 1024,           -- 裁剪保留的尾部码点数
      include_identity = true,           -- 系统提示是否含固定身份段（-100 顺序位）
      identity = "你是一个由 NeoAI 驱动的 AI 编程助手。",
    },
  },

  -- ===== UI 配置 =====
  ui = {
    default_view = "chat",               -- 默认界面：tree / chat
    window_mode = "tab",                 -- 窗口模式：float / tab / split
    window = { width = 80, height = 24, border = "rounded" },
    split = { size = 80, direction = "right" },
    colors = {                           -- 各元素链接的高亮组
      background = "Normal", border = "FloatBorder",
      user_message = "Comment", ai_message = "Normal",
      reasoning = "Type", title = "Title",
    },
    tree = {
      foldenable = false, foldmethod = "manual", foldcolumn = "0", foldlevel = 99,
      auto_close_on_select = true,       -- 从树选择会话打开聊天后自动关闭树窗口
    },
    input_box = {
      idle_height = 1,                   -- 光标在主聊天区域时输入框高度
      min_height = 5,                    -- 光标在输入框内时的最小高度（起始）
      max_ratio = 0.8,                   -- 随内容增长的上限（主窗口高度占比）
    },
    trajectory = {
      log_dir = vim.fn.stdpath("cache") .. "/NeoAI/logs", -- 轨迹日志保存目录
    },
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
      quit = { key = "q", desc = "关闭会话树" },
      select = { key = "<CR>", desc = "选择节点/分支" },
      new_child = { key = "n", desc = "新建子分支" },
      new_root = { key = "N", desc = "新建根分支" },
      delete_dialog = { key = "d", desc = "删除对话" },
      delete_branch = { key = "D", desc = "删除分支" },
      expand = { key = "o", desc = "展开节点" },
      collapse = { key = "O", desc = "折叠节点" },
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
      tool_approval = { key = "<C-a>", desc = "工具审批" },
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
    read_file = {
      outline_threshold_chars = 500,   -- 无行范围时超此字符数改返回语法树大纲
      outline_max_nodes = 200,         -- 大纲最多输出的节点数
      outline_max_depth = 4,           -- 大纲最大递归深度
      outline_preview_lines = 50,      -- 无解析器时的预览行数
    },
    lsp = {
      timeout_ms = 10000,                -- LSP 请求超时（服务器无响应快速失败）
    },
    guard = {
      repeat_tool = {
        enabled = true,                  -- 检测连续重复工具调用并注入提醒
        thresholds = { 3, 5, 8 },        -- 递增提醒阈值
        messages = { [3] = "...", [5] = "...", [8] = "..." },
      },
    },
    todo = {
      enabled = true,                    -- 待办清单工具 + 系统提示注入
    },
    plan_mode = {
      enabled = true,                    -- 计划模式
      auto_execute_on_approve = true,    -- 计划确认后自动转入 CHAT 并按清单执行
      distill_on_execute = true,         -- 计划阶段调研上下文蒸馏为检查点替换压缩
      extra_safe_tools = {},             -- 计划模式白名单扩展
      -- mutating_tools = { ... },       -- 修改类工具（计划模式可见集已覆盖此语义）
    },
    approval = {
      mode = "prompt",                   -- prompt | auto_allow | strict
      default_auto_allow = false,
      timeout_ms = 60000,                -- 审批弹窗超时（防永久挂起）
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

  -- ===== MCP（Model Context Protocol）=====
  mcp = {
    enabled = true,                      -- 是否启用 MCP 客户端
    timeout_ms = 60000,                  -- 单次 JSON-RPC 请求超时
    connect_timeout_ms = 20000,          -- 连接/握手超时
    reconnect = true,                    -- 连接失败/断开后重连
    cache_path = vim.fn.stdpath("cache") .. "/NeoAI/mcp_cache.json", -- 工具描述预缓存
    servers = {
      -- [name] = {
      --   transport = "stdio" | "http",
      --   -- stdio：
      --   command = "npx",
      --   args = { "-y", "@modelcontextprotocol/server-filesystem", vim.fn.getcwd() },
      --   env = {},
      --   -- http：
      --   url = "https://example.com/mcp",
      --   headers = { ["Authorization"] = "Bearer ..." },
      --   -- 通用：
      --   expose = { tools = true, resources = true, prompts = true },
      --   approval = { auto_allow = false },  -- 默认需审批（远端工具不可信）
      --   plan_safe = false,                   -- 计划模式下是否放行
      -- }
    },
    resources = { max_result_bytes = 100 * 1024 },
  },

  -- ===== Skills（技能目录 + SKILL.md）=====
  skills = {
    enabled = true,
    paths = {
      vim.fn.stdpath("config") .. "/skills",
      vim.fn.stdpath("data") .. "/neoai/skills",
      ".neoai/skills",
      ".claude/skills",
    },
    max_skills_in_prompt = 20,           -- 系统提示列出技能数上限
    max_skill_bytes = 64 * 1024,         -- load_skill 单技能内容上限
    inject_mode = "list",                -- list | full | none
    persist_loaded = false,              -- load_skill 是否注册 agent 级提示段常驻
    register_tools = true,               -- 注册 list_skills / load_skill
  },

  -- ===== Herder 终端状态信号 =====
  herder = {
    enabled = true,                      -- 是否启用上报（还需 HERDR_ENV=1 才生效；非 Herder 环境为 no-op）
    source = "custom:neoai",             -- 稳定且全局唯一的生命周期权威标识
    agent = "neoai",                     -- agent 名称（Herder 侧识别用）
  },

  -- ===== 插件系统（可替换服务 / 禁用副作用）=====
  plugins = {
    builtin = true,                      -- false = 不登记内置插件（宿主自管）
    disabled = {},                       -- 禁用的插件/服务 id，如 { "ui", "services.mcp" }
    entries = {
      -- ["tool.shell"] = false,                                  -- 禁用某插件
      -- ["services.model_service"] = { module = "my_model_provider" }, -- 替换实现
    },
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
| `read_file`        | 读取文件内容（大文件默认返回语法树大纲/预览，见下） | ✅ 自动允许 |
| `edit_file`        | 编辑文件内容     | ❌ 需审批   |
| `list_files`       | 列出目录文件     | ✅ 自动允许 |
| `search_files`     | 搜索文件内容     | ✅ 自动允许 |
| `create_directory` | 创建目录         | ❌ 需审批   |
| `ensure_dir`       | 确保目录存在     | ❌ 需审批   |
| `delete_file`      | 删除文件         | ❌ 需审批   |
| `file_exists`      | 检查文件是否存在 | ✅ 自动允许 |
| `read_image`       | 读取图像文件，把图像注入多模态模型 | ✅ 自动允许 |

> **`read_file` 大文件保护**：未指定 `start_line`/`end_line` 且文件超过阈值（默认 500 字符）时，
> 不返回全文，而返回该文件的 **tree-sitter 语法树节点大纲**（该文件类型无解析器时为前若干行预览），
> 避免 AI 一次性读取过大文件耗尽上下文；此时请改用 `start_line`/`end_line` 读取所需区间。
> 阈值与上限可用 `tools.read_file` 配置。

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
| `exit_plan_mode`  | 用户确认后解析计划为 todo 并转入 CHAT 执行      | ⚠️ 需审批   |

### 💬 向用户提问

| 工具名     | 描述                                     | 默认审批    |
| ---------- | ---------------------------------------- | ----------- |
| `ask_user` | 暂停生成并向用户提问，回答回传为工具结果 | ✅ 自动允许 |

> **计划模式（PLAN MODE）**：激活时工具上下文**只包含只读/信息查询工具、`ask_user` 与 `exit_plan_mode`**，
> 不暴露任何修改类工具（编辑/删除/创建/写命令/git 回滚等）；执行期门禁同步收紧，
> 调用可见集之外的任何工具都会被驳回。AI 在此模式下调研、提问澄清，
> 并输出**清晰、格式化的修改计划**（目标与背景 / 改动清单 / 实施步骤 / 验证与回滚）。
> 计划完成后 AI 调用 `exit_plan_mode`（弹出审批窗口由用户确认），
> 用户确认后**直接转入 CHAT 模式**，系统把计划解析为任务清单（todo），
> 并按 `tools.plan_mode.auto_execute_on_approve`（默认开启）自动开始执行。
> 也可手动执行 `:NeoAIApprovePlan` 完成同样的确认。
> 生成过程中按 `m` / `:NeoAIPlan` / `:NeoAIAuto` 切换模式会**延迟到当前回合结束后生效**，
> 不会中途改变工具集 / 系统策略 / 模型而打断正在进行的生成。

### 🪵 日志工具

| 工具名           | 描述             | 默认审批    |
| ---------------- | ---------------- | ----------- |
| `log_message`    | 记录日志消息     | ✅ 自动允许 |
| `get_log_levels` | 获取可用日志级别 | ✅ 自动允许 |

### 🔁 系统工具

| 工具名       | 描述                                          | 默认审批      |
| ------------ | --------------------------------------------- | ------------- |
| `reload_all` | 热重载整个 NeoAI 插件（含隔离子进程预检）     | ⚠️ 需审批      |

> **插件热重载（隔离且安全）**：`reload_all` 工具与 `:NeoAIReloadAll` 命令无需重启 nvim 即可
> 重载整个 NeoAI 插件（源码改动即时生效）。为避免半加载状态破坏当前会话，采用两阶段策略：
> 1. **隔离子进程预检**：先启动一个全新 headless nvim（`--clean -u NONE` + rtp=插件根目录），
>    加载插件并做冒烟校验（核心模块可 require、工具可注册）。任何错误都只留在子进程内，
>    对当前会话零影响；失败时返回错误并取消重载，绝不进入第二阶段。
> 2. **受控的进程内重载**：仅在预检通过后，才清理 `NeoAI.*` 的 require 缓存、重新执行 `setup`，
>    重建工具 / 技能 / MCP 与聊天界面，尽量保留当前会话。重载本身以 `pcall` 包裹，
>    失败时按 require 缓存快照尽力回滚。

### 🔌 MCP 工具（远端服务器，按需启用）

`mcp.servers.<name>` 配置的服务器会把其能力注册为工具，命名 `mcp__<server>__<tool>`。
远端 `tools/list` → 每个远端工具一个 NeoAI 工具；`resources`/`prompts` → 每服务器各一个浏览工具。

| 工具名（示例，`server`=配置名） | 描述 | 默认审批 |
| ------------------------------ | ---- | -------- |
| `mcp__<server>__<远端工具>`   | 调用 MCP 服务器的远端工具 | ❌ 需审批（`approval.auto_allow`） |
| `mcp__<server>__list_resources` | 列出服务器资源（只读） | ✅ 自动允许 |
| `mcp__<server>__read_resource`  | 读取指定资源（只读） | ❌ 需审批 |
| `mcp__<server>__list_prompts`   | 列出提示模板（只读） | ✅ 自动允许 |
| `mcp__<server>__get_prompt`     | 获取提示模板内容 | ❌ 需审批 |

> **工具时序**：启动时先从 `mcp_cache.json` 预缓存注册（连接前可见）；连接/变更通知后动态刷新；
> 因参数 schema 变化导致远端调用失败时标记 stale，下一轮发送前自动刷新并重绑定工具定义
> （模型按最新 schema 重试）。详见 [docs/mcp.md](docs/mcp.md)。

### 🧩 技能工具（Skills）

| 工具名         | 描述                           | 默认审批    |
| -------------- | ------------------------------ | ----------- |
| `list_skills`  | 列出可用技能                   | ✅ 自动允许 |
| `load_skill`   | 装载某技能正文给模型（SKILL.md）| ✅ 自动允许 |

> 系统提示会注入「可用技能」清单（`skills.inject_mode`），模型可 `load_skill` 装载正文。
> 详见 [docs/skills.md](docs/skills.md)。

### 🌐 网页抓取工具（默认不启用）

| 工具名      | 描述 | 默认审批 |
| ----------- | ---- | -------- |
| `web_fetch` | 抓取网页并渲染为可读内容（Markdown/纯文本，只输出正文、不含原始 HTML）；对动态网页在无头浏览器执行 JS 后取最终 DOM | ✅ 自动允许 |

**管线**：Neovim（Lua 只做编排）→ bash 检查/安装依赖 → Node + Playwright 渲染并注入 JS → 取最终 DOM → turndown 转 Markdown → 回传（可选落缓存）。Lua 不自行解析动态页面。

- **默认关闭**：需在配置里设 `tools.web_fetch.enabled = true`；关闭时不会注册工具，也不会安装任何依赖。
- **依赖自动安装**：启用后在**缓存目录**（`stdpath('cache')/NeoAI/web_fetch`）用 bash 检查并安装 Node 依赖（`playwright` / `turndown` / `@mozilla/readability`）与浏览器内核（下载到该目录下的 `browsers/`），无需 root、不动系统环境。`auto_install = true`（默认）时后台异步安装，首次调用会等待其完成。
- **不自动装系统 Node**：若 `node`/`npm` 缺失，返回可操作的错误提示（不会擅自调用系统包管理器）。
- **受限网络（国内镜像 / 代理异常）**：`tools.web_fetch` 新增 `npm_registry`（npm 源）、`playwright_download_host`（浏览器内核下载基址）、`http_proxy` / `https_proxy`（显式代理）、`ignore_system_proxy`（安装/渲染时清空继承的代理变量）五个可选键，默认全空 = 完全沿用系统行为。国内环境推荐：`npm_registry = "https://registry.npmmirror.com/"`、`playwright_download_host = "https://registry.npmmirror.com/-/binary/playwright"`；若本机代理损坏导致下载失败，可设 `ignore_system_proxy = true` 直连。
- **注入脚本目录**：内置脚本位于插件 `assets/web_fetch/scripts/`（`clean` 通用去噪、`readability` 正文提取）；用户可在 `tools.web_fetch.scripts_dir`（默认 `stdpath('config')/NeoAI/web_fetch/scripts`）放置同名脚本**覆盖**内置，或用 `script` 参数选择。
- **缓存**：结果按 URL + 参数缓存，带 TTL / 条数 / **总容量上限（默认 500MB）**，超出按最旧优先淘汰；单条超过总容量时不缓存。
- **参数**：`url`（必填）、`selector`、`wait_selector`、`wait_ms`、`script`、`format`（`markdown`/`text`）、`force_refresh`。
- **输出格式**：恒为 Markdown 或纯文本，不返回原始 HTML；转换前会剥离 `<style>`/`<script>` 等噪声，避免 CSS 混入正文。
- **图片处理**：正文中的图片**不写入 Markdown**（避免 base64 膨胀）；会转存到临时目录（`mktemp -d` 创建，形如 `/tmp/neoai_web_fetch.XXXXXX/`），正文原位保留 `[image: 路径]` 占位符，可按需用 `read_image` 查看；**退出 Neovim 时自动删除**该目录。可用 `max_images` / `max_image_bytes` / `image_timeout_ms` 控制上限。

```lua
require("NeoAI").setup({
  tools = {
    web_fetch = {
      enabled = true,            -- 默认 false
      engine = "chromium",       -- chromium | firefox | webkit
      script = "clean",          -- 内置 clean / readability
      cache = { max_bytes = 500 * 1024 * 1024 },
    },
  },
})
```

> 依赖：`node`（>=18）与 `npm` 需在 `PATH` 中（可用 `tools.web_fetch.node_path` 指定 node 路径）。
> 首次启用会下载浏览器内核，请确保网络通畅。

---

## 🏗️ 架构

基于 v3.0 架构指南（见 [styleGuide.md](styleGuide.md)），遵循**隔离、简洁、异步优先**设计哲学。

```
NeoAI/
├── init.lua                    # 主入口：极薄，仅 setup + 命令/快捷键注册，业务懒加载
├── default_config.lua          # 默认配置（纯数据，零逻辑）
│
├── assets/                     # 随插件分发的内置资源
│   └── web_fetch/              # 网页抓取运行时（拷到缓存目录）
│       ├── render_url.js       # Playwright 渲染器（注入 JS + turndown 转 MD）
│       ├── package.json        # Node 依赖清单（playwright/turndown/readability）
│       └── scripts/            # 内置注入脚本（clean / readability）
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
│   │   ├── session_store.lua  # 会话持久化（追加式 JSONL + 撕裂行修复）
│   │   ├── context_builder.lua# 上下文构建（system 渲染 + 工具调用协议）
│   │   ├── tool_result_pruner.lua # 工具结果裁剪（摘要前头/标记/尾裁剪）
│   │   ├── compactor.lua      # 上下文压缩（配对安全切分 + 检查点替换 + 辅助摘要）
│   │   ├── plan_distill.lua   # 计划阶段蒸馏（调研上下文→8 段检查点）
│   │   └── runtime_context.lua# 运行时上下文（环境/时间等注入）
│   ├── model/                 # 模型管理
│   │   ├── registry.lua       # 模型注册表（运行时动态更新 + 实时元数据）
│   │   ├── fetcher.lua        # 模型列表异步获取器（指数退避重试）
│   │   ├── adapter.lua        # 协议编解码（openai/anthropic/google）
│   │   ├── profiles.lua       # 厂商/模型方言（参数名/推理形态/鉴权头）
│   │   ├── capabilities.lua   # 模型能力表（窗口/输出/缓存机制/字符系数）
│   │   ├── prompt_cache.lua   # 显式缓存（Anthropic 断点/OpenAI explicit/Gemini cachedContents）
│   │   ├── content.lua        # 多模态消息物化（图像引用→协议中立块）
│   │   └── cache.lua          # 模型列表本地缓存
│   ├── attachment/            # 附件（多模态图像）
│   │   └── attachment.lua     # 内容寻址附件存储 + 门禁（vision 支持/类型/上限）
│   └── agent/                 # Agent 引擎
│       ├── agent.lua          # Agent 对象（每次对话全新实例 + AbortSignal）
│       ├── runtime.lua        # Agent 运行时（create/spawn/dispose/abort）
│       ├── request.lua        # 请求构建 + 发送 + 重试
│       ├── stream.lua         # 流式响应处理（SSE 解析 + 工具参数累积）
│       ├── tool_loop.lua      # 工具调用循环
│       ├── prefix.lua         # 前缀缓存身份一致性（系统提示有序段 + 工具典序）
│       ├── guard.lua          # 工具循环护栏（连续重复调用提醒）
│       └── recovery.lua       # 上下文溢出恢复（压缩后重发）
│
├── services/                   # 服务层（连接 core 与 ui/tools）
│   ├── chat_service.lua       # 聊天服务（send/attach/detach/approve_plan/cycle_mode）
│   ├── tool_service.lua       # 工具服务（审批 + 调度 + 执行，串行审批队列）
│   ├── model_service.lua      # 模型服务（list/set_active/prefetch）
│   ├── status.lua             # 状态栏服务（lualine 集成，段拼接 + 高亮）
│   ├── herder.lua             # Herder 终端状态上报（working/idle/blocked）
│   ├── skills.lua             # Skills 服务（SKILL.md 扫描 + frontmatter 解析 + 索引）
│   └── mcp/                   # MCP 服务（客户端 + 传输 + 缓存 + 工具桥接）
│       ├── client.lua         # JSON-RPC 2.0 客户端（id 关联/超时/通知/取消）
│       ├── transports.lua     # 传输层（stdio / Streamable HTTP）
│       ├── cache.lua          # 工具/资源/提示预缓存 + pending/stale 状态
│       └── init.lua           # 管理器（连接/注册/动态刷新/失败驱动 stale）
│
├── ui/                         # 表现层
│   ├── init.lua               # UI 入口（注册审批/提问/子Agent UI；open_*/close_all）
│   ├── window/                # 窗口管理（float/tab/split）
│   │   ├── manager.lua        # 窗口管理器
│   │   ├── chat_view.lua      # 聊天视图（事件/流式/折叠/悬浮窗/显示模式宿主）
│   │   └── tree_view.lua      # 会话树视图
│   ├── components/            # 可复用组件
│   │   ├── input_box.lua      # 输入框
│   │   ├── message_list.lua   # 消息列表渲染
│   │   ├── reasoning_panel.lua# 思考过程面板
│   │   ├── tool_args_panel.lua# 工具参数接收悬浮窗（流式）
│   │   ├── float_stream_window.lua # 复用流式悬浮窗（思考/参数/压缩/蒸馏共享）
│   │   ├── model_picker.lua   # 模型选择器（异步加载）
│   │   ├── tool_approval.lua  # 工具审批弹窗
│   │   ├── ask_user.lua       # 向用户提问弹窗
│   │   ├── sub_agent_dock.lua # 子 Agent 监控
│   │   ├── fold.lua           # 折叠（推理/工具调用/结果共享）
│   │   ├── display_modes/     # 显示模式插件（chat/trajectory）
│   │   └── markdown_view.lua  # Markdown 渲染器
│   └── keymap.lua             # 按键映射（统一管理）
│
├── tools/                      # 工具系统
│   ├── init.lua               # 工具系统入口（init/get_tools/execute/reload_tools）
│   ├── registry.lua           # 工具注册表
│   ├── executor.lua           # 工具执行器（别名/审批/超时）
│   ├── validator.lua          # 参数校验 + 审批决策
│   ├── packer.lua             # 工具分组打包
│   ├── environment.lua        # 工具环境探测（workspace/git，不可用则禁用）
│   └── builtin/               # 内置工具
│       ├── file_ops.lua       # 文件操作 + confirm_file_change
│       ├── shell.lua          # Shell 命令
│       ├── git_ops.lua        # Git 操作
│       ├── lsp_ops.lua        # LSP 工具
│       ├── tree_ops.lua       # Tree-sitter 工具
│       ├── log_ops.lua        # 日志工具
│       ├── plan.lua           # 子 Agent + 边界审核
│       ├── todo.lua           # 待办清单（todo_write/read/clear + 提示段）
│       ├── plan_mode.lua      # 计划模式（enter_plan_mode/exit_plan_mode + 工具过滤/门禁）
│       ├── ask_user.lua       # 向用户提问
│       ├── read_image.lua     # 图像读取（多模态）
│       ├── web_fetch.lua      # 网页抓取（无头浏览器渲染 + 注入 JS + 转 Markdown，默认不启用）
│       ├── skills.lua         # 技能工具（list_skills/load_skill + 提示段）
│       └── tool_helpers.lua   # 工具定义辅助
│
├── sandbox/                    # 工具执行沙箱控制面（dry-run/commit）
│   ├── init.lua              # 入口（gate/attach/commit/discard/list/probe）
│   ├── control.lua           # 状态机/幂等/fencing
│   ├── policy.lua            # 规则评估聚合 + 受限 Lua 规则沙箱
│   ├── runtime.lua           # bwrap/unshare 后端探测与进程前缀
│   ├── candidate.lua         # 私有暂存/冻结/CAS 发布
│   ├── store.lua             # 候选与回执持久化
│   ├── review.lua            # 异步审批变更单元队列
│   ├── impact.lua            # fs/process/network 影响记录
│   ├── evidence.lua          # 证据保存/脱敏/分页
│   ├── grant.lua             # 窄范围任务授权
│   ├── envelope.lua          # 裁决信封
│   ├── network.lua           # 受控网络网关
│   ├── broker.lua            # 外部操作 broker
│   ├── replay.lua            # 策略回放
│   ├── cgroup.lua            # cgroup v2 资源域
│   ├── seccomp.lua           # seccomp 能力探测/门禁
│   ├── cache.lua             # 内容寻址缓存
│   ├── fault.lua             # 故障注入
│   ├── bench.lua             # 性能基准
│   ├── tool_spec.lua         # 工具影响类别声明
│   └── wrapper.lua           # 执行门禁
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
└── tests/                      # 测试（自定义运行器，:NeoAITest；共 45 个 test_*.lua）
    ├── init.lua               # 断言 + 运行器
    ├── test_kernel.lua        # 内核（config_store/event_bus/events/lifecycle）
    ├── test_session.lua       # 会话（session/store/context_builder/compactor）
    ├── test_tool_result_pruner.lua # 工具结果裁剪
    ├── test_agent.lua         # Agent（agent/runtime）
    ├── test_guard.lua         # 工具循环护栏
    ├── test_overflow.lua      # 上下文溢出恢复（配对安全切分 + 裁剪）
    ├── test_cache_strategy.lua# 前缀缓存策略
    ├── test_cache_usage.lua   # 缓存命中用量统计
    ├── test_prompt_cache.lua  # 显式缓存
    ├── test_model_registry.lua# 模型注册表
    ├── test_model_capabilities.lua # 模型能力表
    ├── test_model_profiles.lua# 厂商/模型方言
    ├── test_model_metadata.lua# 实时模型元数据
    ├── test_protocol_adapter.lua # 协议编解码
    ├── test_model_picker.lua  # 模型选择器
    ├── test_modes.lua         # 模式（CHAT/PLAN/AUTO）
    ├── test_multimodal.lua    # 多模态图像
    ├── test_runtime_context.lua # 运行时上下文
    ├── test_tools.lua         # 工具系统
    ├── test_tool_pending.lua  # 工具待发/暂存
    ├── test_pending_queue.lua # 待发消息队列
    ├── test_services.lua      # 服务层（chat/tool/model/status）
    ├── test_status.lua        # 状态栏服务
    ├── test_herder.lua        # Herder 状态上报
    ├── test_ask_user.lua      # 向用户提问
    ├── test_plan_mode.lua     # 计划模式
    ├── test_plan_distill.lua  # 计划蒸馏
    ├── test_todo.lua          # 待办清单
    ├── test_sub_agent_result.lua # 子 Agent 结果
    ├── test_skills.lua        # Skills（frontmatter/发现/装载）
    ├── test_mcp_client.lua    # MCP JSON-RPC 客户端
    ├── test_mcp_transport.lua # MCP 传输层（stdio/HTTP）
    ├── test_mcp_bridge.lua    # MCP 管理器桥接（init→注册→调用）
    ├── test_chat_ui.lua       # 聊天 UI
    ├── test_tree_ui.lua       # 会话树 UI
    ├── test_chat_keys.lua     # 聊天键位
    ├── test_display_modes.lua # 显示模式插件
    ├── test_fold.lua          # 折叠
    ├── test_markdown.lua      # Markdown 渲染
    ├── test_timer.lua         # 可暂停计时器
    ├── test_http.lua          # HTTP 客户端
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
| 消息             | 7    | 添加、更新、编辑、删除、发送、入队、清空 |
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
| MCP              | 5    | 连接、就绪、错误、断开、工具更新   |
| Skills           | 1    | 技能索引热重载                     |
| 日志/上下文压缩  | 4    | 日志消息、压缩开始、压缩分片、压缩完成 |
| 计划蒸馏         | 3    | 蒸馏开始、分片到达、完成           |

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
| [styleGuide.en.md](styleGuide.en.md)                                       | 架构设计指南（英文版） |
| [docs/EVENTS.md](docs/EVENTS.md)                                           | 事件系统文档（唯一权威） |
| [docs/overview.md](docs/overview.md)                                       | 插件总览         |
| [docs/ai_engine.md](docs/ai_engine.md)                                     | Agent 引擎       |
| [docs/model_policy.md](docs/model_policy.md)                               | 按模型自动选择（协议方言/能力表/显式缓存） |
| [docs/tool_system.md](docs/tool_system.md)                                 | 工具系统         |
| [docs/sandbox.md](docs/sandbox.md)                                         | 工具执行沙箱（dry-run/commit、隔离后端、策略） |
| [docs/ui_system.md](docs/ui_system.md)                                     | UI 系统          |
| [docs/sub_agent_system.md](docs/sub_agent_system.md)                       | 子 Agent 系统    |
| [docs/history_manager.md](docs/history_manager.md)                         | 会话系统（分支/持久化/压缩） |
| [docs/configuration.md](docs/configuration.md)                             | 配置系统         |
| [docs/plugins.md](docs/plugins.md)                                         | 插件系统（服务定位器/宿主/清理/替换） |
| [docs/chat_enhanced_usage.md](docs/chat_enhanced_usage.md)                 | 聊天增强使用指南 |
| [docs/mcp.md](docs/mcp.md)                                                 | MCP 支持（传输/工具/时序） |
| [docs/skills.md](docs/skills.md)                                           | Skills 支持（SKILL.md + load_skill） |
| [docs/utils.md](docs/utils.md)                                             | Utils 工具库（async/http/fs/work/timer） |
| [docs/shutdown_flow.md](docs/shutdown_flow.md)                             | 生命周期与关闭流程 |
| [docs/testing.md](docs/testing.md)                                         | 测试指南         |
| [docs/en/](docs/en/)                                                       | 以上文档的英文版（English mirror） |

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
