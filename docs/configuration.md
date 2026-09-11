# NeoAI 配置系统（v3.0）

> [English](en/configuration.md) | **中文**

> 配置由 `default_config.lua`（纯数据、零逻辑）提供不可变默认值，
> `kernel/config_store.lua`（merge + validate + get + watch）管理合并与读取，
> `kernel/lifecycle.lua`（bootstrap/shutdown）负责内核引导。
> 对应源码：`lua/NeoAI/default_config.lua`、`lua/NeoAI/kernel/config_store.lua`。

## 1. 配置存储（kernel/config_store.lua）

替代旧 `merger.lua` + `state.lua` 混合体，不管理任何业务状态。

| API | 说明 |
| --- | --- |
| `load(user_config)` | 深合并 user 覆盖 default → 校验 → 生成不可变配置；触发 `CONFIG_LOADED`。 |
| `get(path, default)` | 按点分路径读取（如 `ui.window.width`）。 |
| `get_all()` | 获取完整配置。 |
| `watch(path, cb)` | 监听配置变更（路径前缀匹配），返回取消函数。 |
| `set(path, value)` | 运行时热更新，触发 `watch` + `CONFIG_CHANGED`。 |
| `reset()` | 重置（测试用）。 |

`load` 的校验逻辑：检查 `ai.default_provider`、`ai.providers` 各 provider 的 `base_url`、
`ai.modes` 结构，收集错误并记日志（不阻断）。

## 2. 配置结构

完整配置见 `lua/NeoAI/default_config.lua`。主要分区如下。

### 2.1 `ai`

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `default_provider` | `"deepseek"` | 默认提供商 |
| `default_model` | `"auto"` | "auto" = 使用 registry 解析默认模型 |
| `providers` | 13+ 家 | provider 定义：`api_type`（openai/anthropic/google）、`base_url`、`api_key`、`fetch_models`、`models_override` |
| `model_refresh` | `{on_startup=true, interval_sec=3600, timeout_ms=10000}` | 模型列表刷新 |
| `modes` | `{chat, plan, auto}` | 按模式 → `{provider, model, temperature, stream}`（可选 `max_tokens`）；进入该模式时应用。`max_tokens` 缺省不配置即不发送 |
| `truncation` | `{enabled=true, max_continues=3}` | 输出被截断且无工具调用时自动续写（提示不落库），超限写可见提示 |
| `reasoning_enabled` | `true` | 启用深度思考（reasoning_content） |
| `system_prompt` | 默认中文提示 | persona 段 |
| `timeout_ms` | `60000` | 请求超时 |
| `max_retries` | `3` | 请求重试次数 |
| `attachments` | 见下 | 多模态图像配置 |
| `model_policy` | 见下 | 按模型自动选择：能力表 + 厂商方言 + 显式缓存 |
| `context_cache` | 见下 | 前缀缓存身份 + 自动上下文压缩 |

**attachments（多模态）**：

```lua
attachments = {
  enabled = true,               -- 多模态总开关
  path = ".../NeoAI/attachments", -- 内容寻址附件存储目录
  vision_models = { "deepseek-v4-flash-vision-exp", "deepseek-vl" },
  vision_model_heuristics = { "vision", "-vl", "4o", "gemini" },
  media_types = { "image/png", "image/jpeg", "image/webp", "image/gif" },
  limits = { maxImageBytes=20MB, maxImagesPerMessage=16, maxMessageImageBytes=40MB,
             maxImagePixels=50M, maxImageDimension=8000 },
  request_image = { maxPixels=640000, maxBytes=1MB, maxImagesPerRequest=8,
                    maxRequestBytes=20MB, maxRequestImages=600 },
}
```

**model_policy（按模型自动选择）**：

```lua
model_policy = {
  enabled = true,                 -- 总开关
  explicit_cache = {
    enabled = true,               -- 显式缓存总开关
    openai = false,               -- OpenAI 显式断点默认关闭
    -- anthropic = true, gemini = true,  -- 分机制开关（缺省跟随总开关）
  },
  overrides = {                   -- 能力覆盖（key = 模型 id 或 provider 名）
    -- ["deepseek-v4-flash"] = { window = 131072, max_output = 8192 },
  },
  dialects = {                    -- 方言覆盖（key = provider 名 或 模型 id）
    -- ["my-provider"] = { max_tokens_field = "max_completion_tokens", reasoning_kind = "effort" },
  },
}
```

能力表提供上下文窗口、最大输出、缓存机制（`openai`/`anthropic`/`gemini`）、最小可缓存 token、
显式缓存 TTL/断点上限、字符/token 系数；方言表提供商/模型请求参数名、推理参数形态、鉴权头与
usage 字段。详见 [model_policy.md](model_policy.md)。

**数值实时获取**：上下文窗口 / 最大输出优先从各家 `/models` 端点**实时获取**（Google 的
`inputTokenLimit`/`outputTokenLimit`、OpenRouter 的 `context_length`/`top_provider.max_completion_tokens`、
Groq 等的 `context_window`）；拿不到才回退内置表。数值优先级：**用户 `overrides` → 实时元数据 →
内置 pattern → `api_type` 默认 → 兜底**（`caps.source` 标注来源）。
`max_tokens` 发送策略：仅用户显式配置（`opts.max_tokens` 或 `modes.*.max_tokens`）才发送；
未配置则**不发送**，由模型/厂商默认最大输出决定（实时/`overrides.max_output` 不再自动发送，
仅用于收敛与容量显示）；Anthropic `max_tokens` 必填，用能力表 `max_output` 兜底。

**context_cache（前缀缓存 + 压缩）**：

```lua
context_cache = {
  enabled = true,
  context_window = 64000,       -- 上下文窗口兜底值：用户显式非默认值优先，否则按模型能力表推导
  threshold_ratio = 0.8,        -- 达到该比例触发压缩（显式缓存模型自动取更保守值）
  retain_ratio = 0.16,          -- 保留的最近历史比例
  retain_min_tokens = 4096,     -- 尾部保留下限
  compact_max_tokens = 8192,    -- 压缩摘要输出上限
  min_shadow_messages = 2,      -- 至少折叠多少条才值得压缩
  compaction_retries = 1,       -- 摘要后仍高于阈值的重试次数
  prune_enabled = true,         -- 摘要前先做模型无关的工具结果裁剪
  prune_threshold_chars = 8192, -- 文本码点超过该值的工具结果才裁剪
  prune_head_chars = 4096,      -- 裁剪保留的头部码点数
  prune_tail_chars = 1024,      -- 裁剪保留的尾部码点数
  include_identity = true,      -- 系统提示是否含固定身份段（-100 顺序位）
  identity = "你是一个由 NeoAI 驱动的 AI 编程助手。",
}
```

### 2.2 `ui`

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `default_view` | `"chat"` | 默认界面（chat/tree） |
| `window_mode` | `"tab"` | 窗口模式（float/tab/split） |
| `window` | `{width=80, height=24, border="rounded"}` | float 窗口 |
| `split` | `{size=80, direction="right"}` | split 窗口 |
| `colors` | 各段高亮 | 用户/AI/推理/标题色 |
| `tree` | `{foldenable=false, ...auto_close_on_select=true}` | 会话树折叠/自动关闭 |
| `input_box` | `{idle_height=1, min_height=5, max_ratio=0.8}` | 输入框高度（空闲/聚焦/增长上限） |
| `trajectory` | `{log_dir=".../NeoAI/logs"}` | 轨迹显示模式的日志保存目录 |
| `statusline` | `{enabled=true, winbar=true, parts={mode,model,usage,cache,capacity}, separator=" ", colors=...}` | lualine 状态栏 |

### 2.3 `keymaps`

| 分区 | 说明 |
| --- | --- |
| `global` | `toggle_ui`(<leader>aa)、`open_chat`(<leader>ac)、`open_tree`(<leader>at)、`close_all`(<leader>aq) |
| `tree` | `quit`(q)、`select`(<CR>)、`new_child`(n)、`new_root`(N)、`delete_dialog`(d)、`delete_branch`(D)、`expand`(o)、`collapse`(O) |
| `chat` | `insert`(i)、`quit`(q)、`send`、`cancel`(<Esc>)、`toggle_reasoning`(r)、`switch_model`(M)、`cycle_mode`(m)、`cycle_display`(<C-t>/T)、`reload_display`(<F5>)、`tool_approval`(<C-a>)、`approval.*` |

### 2.4 `session`

```lua
session = {
  auto_save = true,
  auto_naming = true,
  save_path = ".../NeoAI",
  max_history_per_session = 1000,
  file = "sessions.jsonl",   -- 追加式 JSONL
}
```

### 2.5 `tools`

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `enabled` | `true` | 工具系统总开关 |
| `builtin` | `true` | 加载内置工具 |
| `external` | `{}` | 外部工具 |
| `read_file` | `{outline_threshold_chars=500, outline_max_nodes=200, outline_max_depth=4, outline_preview_lines=50}` | read_file 大文件保护：未指定行范围且超阈值时返回语法树大纲（无解析器则截断预览） |
| `lsp` | `{timeout_ms=10000}` | LSP 请求超时（服务器无响应快速失败） |
| `guard.repeat_tool` | `{enabled=true, thresholds={3,5,8}, messages=...}` | 连续重复工具调用提醒 |
| `todo.enabled` | `true` | 待办工具 + 系统提示注入 |
| `plan_mode` | `{enabled=true, auto_execute_on_approve=true, extra_safe_tools={}, mutating_tools=...}` | 计划模式 |
| `approval` | 见下 | 工具审批 |

**approval（工具审批）**：

```lua
approval = {
  mode = "prompt",             -- prompt | auto_allow | strict
  default_auto_allow = false,
  timeout_ms = 60000,          -- 审批弹窗超时（防永久挂起）
  allowed_directories = {},
  allowed_param_groups = {},
  per_tool = {
    read_file      = { auto_allow = true },
    edit_file      = { auto_allow = false },
    list_files     = { auto_allow = true },
    search_files   = { auto_allow = true },
    file_exists    = { auto_allow = true },
    create_directory= { auto_allow = false },
    ensure_dir     = { auto_allow = false },
    delete_file    = { auto_allow = false },
    run_command    = { auto_allow = false, allowed_directories = { "./" },
                       allowed_param_groups = { "ls", "wc", "find", "grep", "pwd" } },
    create_sub_agent    = { auto_allow = false },
    get_sub_agent_status= { auto_allow = true },
    cancel_sub_agent    = { auto_allow = true },
    git_diff / git_log / git_status / git_commit_detail /
    git_file_history / git_branch / git_auto_commit_config = { auto_allow = true },
    git_rollback = { auto_allow = false },
    log_message / get_log_levels = { auto_allow = true },
    lsp_rename / lsp_format / delete_node = { auto_allow = false },
  },
}
```

> **审批决策**：`mode=auto_allow` → 不审批；`mode=strict` → 必审批；
> 工具 `auto_allow=true` → 不审批；路径落允许目录 + 命令首词落参数组 → 不审批。

### 2.6 `herder`

```lua
herder = {
  enabled = true,          -- 是否启用上报（还需 HERDR_ENV=1 才真正生效）
  source = "custom:neoai", -- 稳定且全局唯一的生命周期权威标识
  agent = "neoai",         -- agent 名称（Herder 侧识别用）
}
```

### 2.7 `log`

```lua
log = {
  level = "WARN",
  path = ".../NeoAI/neoai.log",
  max_size = 10485760,
  max_backups = 5,
  format = "[{time}] [{level}] {message}",
  verbose = false,
}
```

### 2.8 `mcp`

```lua
mcp = {
  enabled = true,
  timeout_ms = 60000,
  connect_timeout_ms = 20000,
  reconnect = true,
  cache_path = ".../NeoAI/mcp_cache.json",
  servers = { /* 见 docs/mcp.md */ },
  resources = { max_result_bytes = 100 * 1024 },
}
```

### 2.9 `skills`

```lua
skills = {
  enabled = true,
  paths = { vim.fn.stdpath("config") .. "/skills", ".neoai/skills", ".claude/skills" },
  max_skills_in_prompt = 20,
  max_skill_bytes = 64 * 1024,
  inject_mode = "list",       -- list | full | none
  persist_loaded = false,
  register_tools = true,
}
```

## 3. 计划模式（tools/plan_mode）

计划模式作为 **per-agent 状态**（`agent.plan_mode`），激活时：

1. **注入 plan-policy 系统提示段**（`deployment:plan_policy`，order=100）：要求输出清晰、格式化的修改计划。
2. **工具上下文只保留只读/信息查询工具 + `ask_user` + `exit_plan_mode`**（`PLAN_SAFE_TOOLS` 白名单），不暴露任何修改类工具。
3. **执行期门禁同步收紧**（`plan_mode.check_tool`）：计划模式下调用可见集之外的任何工具都会被驳回。

**计划确认**：AI 调用 `exit_plan_mode`（审批弹窗由用户确认）或用户执行 `:NeoAIApprovePlan`，
经 `chat_service.approve_plan` 解析计划为任务清单（todo）→ 退出计划模式（转入 CHAT）
→ 按 `auto_execute_on_approve`（默认开启）自动开始执行。

状态持久化在 `session.metadata.plan`，恢复会话时还原（`plan_mode.restore`）。

## 4. 相关文档

- [README 配置章节](../README.md)：完整配置示例。
- [tool_system.md](tool_system.md)：`tools.*` 工具/审批配置的运行时行为。
- [ai_engine.md](ai_engine.md)：`ai.context_cache` / `ai.reasoning_enabled` 的引擎侧行为。
- [model_policy.md](model_policy.md)：按模型自动选择（协议方言 / 能力表 / 显式缓存）。
