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
| `trace` | `{capture=true, max_rounds=8}` | 轨迹/诊断用 wire 数据（原始请求体 + SSE 分片）的内存保留策略：只保留最近 `max_rounds` 轮完整数据，更早轮降级为轻量摘要（`capture=false` 完全不保留）。避免长工具循环内存膨胀 |
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
  threshold_ratio = 0.8,        -- 达到该比例触发后台异步压缩（不阻塞、不弹窗；显式缓存模型自动取更保守值）
  retain_ratio = 0.16,          -- 保留的最近历史比例（单轮长循环回退/溢出恢复用；常规压缩折叠第一轮至倒数第二轮）
  retain_min_tokens = 4096,     -- 尾部保留下限（单轮长循环回退/溢出恢复用）
  compact_max_tokens = 8192,    -- 压缩摘要输出上限
  min_shadow_messages = 2,      -- 至少折叠多少条（溢出恢复/单轮回退；常规压缩按轮次范围）
  compaction_retries = 1,       -- 摘要后仍高于阈值的重试次数（常规压缩无新可折叠消息时停止）
  prune_enabled = true,         -- 摘要前先做模型无关的工具结果裁剪
  prune_threshold_chars = 8192, -- 文本码点超过该值的工具结果才裁剪
  prune_head_chars = 4096,      -- 裁剪保留的头部码点数
  prune_tail_chars = 1024,      -- 裁剪保留的尾部码点数
  include_identity = true,      -- 系统提示是否含固定身份段（-100 顺序位）
  identity = "你是一个由 NeoAI 驱动的 AI 编程助手。",
}
```

> **压缩行为**：常规（阈值触发）压缩在后台**异步非阻塞**执行——折叠第一轮至倒数第二轮（保留最后一轮完整）；
> 当没有更早的用户轮次可折叠（单轮长工具循环）时，回退为按 `retain_ratio`/`retain_min_tokens` 的平衡头部缩减，
> 折叠本回合较早轮次、保留最近尾部（切点保持 tool_calls 与结果的配对）。
> 摘要完成后写入**压缩覆盖层**（`agent.compaction`），后续请求与再次压缩都使用压缩后的替换；聊天渲染与会话持久化
> 仍是**原始上下文**（覆盖层随会话持久化于 `session.metadata.compaction`，重开后继续生效）。压缩**不弹悬浮窗**。
> 上下文溢出恢复（`force_compact`）仍为阻塞等待，并按 `retain_ratio`/`retain_min_tokens`/`min_shadow_messages` 做最大化缩减。

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
| `chat` | `{mousescroll_max_blank=3, incremental=true}` | 鼠标滚轮滚到底时末行下方允许的最大空白行数（0=严格贴底）；`incremental` 开启增量刷新（只重渲染变化的消息块且只写差异行），设为 `false` 降级回整 buffer 全量重写 |
| `trajectory` | `{log_dir=".../NeoAI/logs"}` | 轨迹显示模式的日志保存目录 |
| `statusline` | `{enabled=true, winbar=true, parts={mode,model,usage,cache,capacity,sandbox}, separator=" ", colors=...}` | lualine 状态栏；`sandbox` 段在沙箱待审数 > 0 时显示 `待审N`（`N` 为待审**文件**总数，审批单位为单个文件），默认链接醒目高亮组 `NeoAISandboxPending`（黄底加粗，可在 `colors.sandbox` 覆盖）；待审队列含 **L3（高危）** 时该段追加 `⚠危险` 并切换为红色危险高亮组 `NeoAISandboxDanger`（可在 `colors.sandbox_danger` 覆盖）；存在**越界访问留痕**时该段追加 `越界N`（`N` 为去重文件数，两者都有时并列显示，如 `待审2 越界3`） |

### 2.3 `keymaps`

| 分区 | 说明 |
| --- | --- |
| `global` | `toggle_ui`(<leader>aa)、`open_chat`(<leader>ac)、`open_tree`(<leader>at)、`close_all`(<leader>aq) |
| `tree` | `quit`(q)、`select`(<CR>)、`new_child`(n)、`new_root`(N)、`delete_dialog`(d，删除当前轮次)、`delete_branch`(D，删除所属会话及全部子分支)、`expand`(o)、`collapse`(O) |
| `chat` | `insert`(i)、`quit`(q)、`send`、`cancel`(<Esc>)、`toggle_reasoning`(r)、`switch_model`(M)、`cycle_mode`(m)、`cycle_display`(<C-t>/T)、`reload_display`(<F5>)、`tool_approval`(<C-a>)、`sandbox_review`(<leader>ap，查看并应用待审的沙箱修改)、`approval.*` |

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
| `read_file` | `{outline_threshold_chars=500, outline_max_nodes=200, outline_max_depth=4, outline_preview_lines=50, max_read_bytes=5242880}` | read_file 大文件保护：未指定行范围且超阈值时返回语法树大纲（无解析器则截断预览）；超过 `max_read_bytes` 则拒绝整读并只给预览，避免 OOM |
| `search_files` | `{max_file_bytes=8388608}` | 搜索时单文件扫描上限（字节），超过则跳过；二进制文件（含 NUL）跳过，避免大文件 OOM |
| `run_command` | `{max_output_bytes=16777216, max_wall_ms=0}` | 命令 stdout/stderr 合计上限（字节）：超出则截断并终止命令，避免超大输出逐行处理冻结主线程；0 = 不限制。`max_wall_ms>0` 为墙钟安全网：命令最长运行该毫秒数（同样约束 `timeout_ms=-1` 的「不限」命令），到时经沙箱资源域真正终止进程树；0 = 不限制 |
| `lsp` | `{timeout_ms=10000, attach_timeout_ms=3000}` | LSP 请求超时（服务器无响应快速失败）；`attach_timeout_ms` 为等待客户端附加的超时：后台加载 buffer / 服务器启动或重启期间客户端尚未附加时，`lsp_diagnostics` 等待其就绪再取诊断，而非立即报「无 LSP 客户端」 |
| `guard.repeat_tool` | `{enabled=true, thresholds={3,5,8}, messages=...}` | 连续重复工具调用提醒 |
| `todo.enabled` | `true` | 待办工具 + 系统提示注入 |
| `web_fetch` | 见下（默认 `enabled=false`） | 网页抓取：无头浏览器渲染动态页面并转 Markdown |
| `plan_mode` | `{enabled=true, auto_execute_on_approve=true, extra_safe_tools={}, mutating_tools=...}` | 计划模式 |
| `approval` | 见下 | 工具审批 |
| `sandbox` | 见下 | 工具执行沙箱（dry-run/commit、隔离后端、策略） |

**approval（工具审批）**：

```lua
approval = {
  mode = "async",              -- async（默认，异步审批：立即沙箱执行，事后确认应用）| prompt | auto_allow | strict
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

> **审批决策**（仅 `mode` 为 `prompt`/`strict` 时的执行前弹窗判定；默认 `async` 不经此路径，
> 由沙箱风险分级 `sandbox.approval` 决定是否待审）：`mode=auto_allow` → 不审批；`mode=strict` → 必审批；
> 工具 `auto_allow=true` → 不审批；路径落允许目录 + 命令首词落参数组 → 不审批。
> `allowed_directories` 为**全局工作区允许目录**（对所有工具生效，且**包含其所有子目录**）；
> 工具自身与 `per_tool` 的条目与之**并集**合并，只追加不覆盖。文件类工具只按路径判定
> （无命令参数时不要求命令白名单），故配置工作区目录后其子目录无需逐个审批。

**sandbox（工具执行沙箱）**：

```lua
sandbox = {
  enabled = true,                  -- 总开关
  fail_closed = true,              -- 沙箱服务缺失/禁用时拒绝执行（不静默降级）
  -- 所有工具内部 spawn 的子进程（run_command/git/curl/node/MCP server 等）统一在沙箱命名空间内
  -- 创建；工具自身缓存/临时目录经可写绑定暴露，共享根 stdpath('cache')/NeoAI/shared（宿主与沙箱同路径）。
  mode = "dry_run",                -- dry_run（默认，仅冻结候选）| commit（授权后立即 CAS 发布）
  postprocess = "async",           -- 进程命令后处理模式：async（默认）= 命令进程退出后立即返回结果给主循环，overlay 捕获/候选冻结/暂存合并/落盘/结算在后台完成（FIFO 槽位保持到后台完成，保证下一命令看到一致暂存；后续读写工具会等待在途后处理）；sync = 等待后处理完成后再返回（确定性，测试默认）
  shutdown_timeout_ms = 3000,      -- 退出/关闭（`:qall`、插件热重载）时等待后台后处理与暂存迁移完成的最长时间（ms）；超时即放弃等待，避免卡住退出；0 = 不等待（可能丢失最后一笔未完成的冻结/待审入队）
  backend = "auto",                -- auto | bwrap | unshare
  offline = false,                 -- 网络默认放行（仅记录，不拦截）；true 时硬拒绝网络并隔离进程网络
  require_seccomp = true,          -- 缺少 seccomp 能力时是否拒绝外部执行（默认开，fail-closed）
  seccomp = { enabled = true, filter_path = "" }, -- seccomp 基线（内置 denylist；默认开；仅 bwrap）
  cap_add = {},                    -- 全局额外 capability（默认空）；档位基线另加回 CAP_DAC_OVERRIDE + CAP_SETUID/CAP_SETGID（沙箱内降权，见 privilege.tiers），包安装/系统管理再按需加回。仅调试时才设 { "ALL" }
  -- 载荷运行身份：默认以 root 运行（uid=0），使 AI 能在沙箱内使用宿主工具链（/root 下的
  --   nvm/cargo/go 等 0700 目录非 root 不可遍历）与包管理（dpkg 硬检查 euid==0）。所有写入仍
  --   全部进入 overlay 暂存并冻结为候选，真实磁盘不受影响；隔离由命名空间 + 整机根 overlay +
  --   seccomp + 遮蔽保证。
  --   * 非 root 启动 NeoAI：用 user namespace 把当前用户映射为**沙箱内 guest root**（euid=0，
  --     仅命名空间内有效；宿主仍是当前非 root 用户），本项被忽略。真正需要宿主 root 的操作
  --     冻结为待审，用户批准后经 `sudo` 执行。
  --   * root 启动 NeoAI：uid=0 为默认（不降权）；设为专用非 root uid（如 nobody 65534）可加固，
  --     插件先用 `setpriv` 把载荷降为该 uid，配置的窄能力以 ambient 形式保留。此时 /root 不可
  --     遍历，工作区/`workspace_root` 须放在可被其遍历的位置（勿放 0700 的 /root 下）。
  --   载荷非 root（非 root 启动或 uid!=0）且命令因权限不足失败时，会显式冻结 ROOT_REQUIRED
  --     主机操作提案（审批后以 root/sudo 在宿主 replay），不静默失败/提权（见 sandbox.md §17）。
  run_as = { uid = 0, gid = 0 },
  cap_drop = {                     -- 主机全局能力收敛：即便 cap_add 含 ALL 也逐项丢弃（网络栈/时钟/内核模块/裸 I/O/重启/MAC/审计）
    "CAP_NET_ADMIN", "CAP_SYS_TIME", "CAP_SYS_MODULE", "CAP_SYS_RAWIO",
    "CAP_SYS_BOOT", "CAP_MAC_ADMIN", "CAP_MAC_OVERRIDE", "CAP_AUDIT_CONTROL",
  },
  max_file_bytes = 8 * 1024 * 1024, -- 单文件内容内嵌候选上限（字节）；超过则内容复制为 blob（候选只记 blob 路径 + stat 签名），发布/物化按文件复制，防大文件嵌入 JSON 阻塞主线程；0 = 不限制（全部内嵌）
  work_chunk_files = 128, -- 每个工作线程任务的候选文件数：冻结/哈希/密钥扫描按此分块并发投递到线程池（多核），防大量文件时单核串行；0/缺省 = 128
  work_parallelism = 4, -- 每批并发提交到线程池的 chunk 数上限（默认 4，与 libuv 线程池一致）：避免一次性排入数百个 chunk job，使脱敏/密钥 token 化/落盘等 UI 关键 job 不必排在队尾；0/缺省 = 4
  -- 读取面（默认开）：true 时整机根以**可写 overlay** 方式暴露——以 `/` 为只读 lower、会话私有
  -- upper/work 为可写层（原样挂载、根内任意路径可写），所有写入进 upper 暂存并冻结为候选，
  -- 宿主盘不受影响；仅遮蔽 mask_paths 中的重要配置文件/凭据（~/.ssh、~/.aws、/etc/shadow、
  -- sudoers、docker.sock 等）与沙箱自身存储；mask_dirs（home/root 兄弟目录）不再挂载遮蔽，但
  -- 访问 cwd 之外的用户目录会**留痕**（evidence + `sandbox:outside_access` 事件）并在审批悬浮窗
  -- `:NeoAISandboxReview` 的「越界访问留痕」区展示（非阻塞，仍放行）。overlay 不可用时退回只读根
  -- （overlay_fail_closed 决定是否降级）。false 时退回下面的最小只读白名单。
  read_all = true,
  -- 最小只读系统集（白名单，仅在 read_all=false 时生效）：仅这些宿主根/子树/文件以只读方式
  -- 暴露给外部命令；未列出的路径在沙箱内不存在。不整目录暴露 /usr（避免泄露
  -- /usr/local/go_workspace、/usr/src 等），但整目录只读暴露 /usr/share 与 /var/lib，使
  -- run_command 能读取运行时共享数据（nodejs/dotnet/java/git-core/terminfo 等）与宿主包数据库
  -- （dpkg/apt/rpm 等）；危险/敏感子路径仍由 mask_paths 遮蔽（如 /var/lib/docker）。
  -- /lib*、/bin、/sbin 为加载器符号链接根，必须保留。支持 `*` 通配，不存在的条目跳过。
  readonly_roots = {
    "/lib", "/lib32", "/lib64", "/libx32", "/bin", "/sbin",
    "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/lib32", "/usr/lib64", "/usr/libx32",
    "/usr/libexec", "/usr/include",
    "/usr/share",                  -- 运行时共享数据（nodejs/dotnet/java/git-core/terminfo 等）
    "/usr/local/bin", "/usr/local/sbin", "/usr/local/lib", "/usr/local/libexec", "/usr/local/include", "/usr/local/go",
    "/var/lib",                    -- 宿主包数据库（dpkg/apt/rpm 等）；危险子路径仍由 mask_paths 遮蔽
    -- 语言运行时/虚拟环境解释器（uv/pyenv/virtualenv）：venv 的 bin/python 常是指向这些目录的
    -- 符号链接；read_all=false 时若不暴露，激活 venv 后 python 会变成悬空链接（command not found）
    "/usr/share/pyenv", "~/.pyenv", "~/.local/share/uv/python", "~/.local/share/virtualenvs",
    "~/.virtualenvs", "~/.local/bin", "~/.nvm", "~/.cargo", "~/.rustup",
  },
  readonly_paths = { "/etc/ld.so.cache", "/etc/passwd", "/etc/group", "/etc/nsswitch.conf",
    "/etc/hosts", "/etc/ssl", "/etc/alternatives", "/etc/localtime",
    "/etc/os-release", "/etc/terminfo", "/etc/profile", "/etc/security", "/etc/pam.d" },
  expose_paths = {},               -- 宿主运行时直通（opt-in）：这些宿主路径在遮蔽/临时根之后只读暴露，并前置到沙箱 PATH，使 run_command 能调用宿主工具链（如 nvim/lua/luajit/mason）。仅暴露可信只读工具目录
  expose_path_env = true,          -- 是否把 expose_paths 目录前置到沙箱 PATH（false 仅挂载不改 PATH）
  expose_tool_paths = false,       -- 自动直通宿主 PATH 中的工具目录（opt-in）：把宿主 PATH 里存在且非凭据/系统目录的 bin 目录只读暴露并前置到沙箱 PATH，使 node/npm/fd/go 等装在 $HOME 下的工具链可用（会扩大读取面）
  appimage_extract_and_run = true, -- AppImage 支持（默认开）：沙箱内运行 AppImage 时注入 APPIMAGE_EXTRACT_AND_RUN=1，解包到会话私有 /tmp 运行（沙箱按设计拦截 mount/不暴露 /dev/fuse，无法 FUSE 挂载）；非 AppImage 程序忽略该变量。false 关闭
  resolv_conf = "sanitize",        -- /etc/resolv.conf：sanitize（默认，仅 nameserver）| hide | passthrough
  tmpfs_roots = { "/tmp", "/var/tmp", "/run" }, -- 每会话私有临时根（不作为 overlay lower；退出即销毁）。/run（含 /var/run）默认纳入，使 dpkg postinst 的 adduser 锁文件、/var/run/postgresql 可写；宿主 /run 敏感项仍由 mask_paths 遮蔽
  ephemeral_roots = { "/tmp", "/var/tmp" }, -- 临时候选根（cwd 子树除外）：这些根下的文件写入为会话私有、nvim 退出即丢弃，不产生待审候选/不发布/不弹审批悬浮窗；`{}` 关闭
  tmp_private_base = "host",       -- 临时根私有目录位置：host（默认，宿主根下隐藏子目录 /tmp/.cache-<tag>/<session>，命名空间映射回该根，隔离 AI）| session（旧行为：建在会话进程目录）
  hide_proc_paths = { "/proc/cmdline", "/proc/version" }, -- 以空文件覆盖，隐藏宿主内核命令行/版本（危险全局 sysctl 为常驻强制遮蔽，只增不减）
  mask_paths = {                   -- 遮蔽宿主敏感路径（目录 tmpfs / 文件·socket 用 /dev/null 覆盖）
    "/run/docker.sock", "/var/run/docker.sock", "/var/lib/docker", "/var/lib/containerd",
    "/root/.config/herdr", "/etc/1panel", "/run/dbus", "/run/systemd",
    "/root/.ssh", "/root/.aws", "/root/.gnupg", "/root/.kube", "/root/.cache/keyring-*",
    -- Git 凭据与签名密钥（SSH/GPG/credential store/netrc/gh token），含非 root home
    "/root/.git-credentials", "/root/.config/git/credentials", "/root/.git-credential-cache", "/root/.config/gh",
    "/home/*/.ssh", "/home/*/.gnupg", "/home/*/.netrc", "/home/*/.git-credentials",
    "/home/*/.config/git/credentials", "/home/*/.config/gh", "/home/*/.docker/config.json",
    "/etc/shadow", "/etc/gshadow", "/etc/sudoers", "/etc/machine-id", "/etc/ssh",
    "/var/log", "/var/spool/cron", "/etc/crontab",
    "/root/.bash_history", "/root/.zsh_history", "/root/.python_history", "/root/.wget-hsts",
  },
  -- 遮蔽目录（默认开启）：cwd 所在用户 home 只读暴露并遮蔽其余条目；命中时弹窗审批。
  mask_dirs_enabled = true,        -- 总开关
  mask_dirs = { "/home", "/root" }, -- 遮蔽目录列表（支持 * 通配）
  mask_dirs_approval = true,       -- 命中遮蔽目录时弹窗审批（复用工具审批 UI）
  -- 内核级行为观测（eBPF/strace/procfs）：以实际 syscall 判定「越界访问」与「密钥文件访问」，
  -- 替代/补充命令字符串解析启发式；事件按 attempt cgroup 精确归属。
  -- 后端优先级 auto：ebpf（bpftrace，需 root）→ strace（命令前缀包裹）→ procfs（/proc/<pid>/fd）。
  -- 均不可用时自动回退命令解析启发式，不阻断工具执行。
  observe = {
    enabled = true,   -- 总开关（关闭后直接使用命令解析启发式）
    backend = "auto", -- "auto" | "ebpf" | "strace" | "procfs" | "heuristic"
    poll_ms = 200,    -- procfs/strace 轮询间隔（毫秒）
    notify = true,    -- 启动时探测：eBPF 内核不可用/未安装、或回退 strace 且未安装时 notify
    -- 探针挂载等待（毫秒）：0（默认）= 不阻塞命令，bpftrace 异步挂载（best-effort，早期访问
    -- 可能漏观测，由命令解析启发式兜底），避免每条命令固定等待约 0.5s；设为正值则在命令执行
    -- 前有界等待，观测更全但每条命令固定增加该等待。
    wait_ready_ms = 0,
    -- 观测预热（默认开）：进程命令返回后，在 AI 生成下一轮的间隙后台预创建下一个 attempt 的
    -- cgroup 并挂载 eBPF 探针，使约 0.5s 的挂载与 AI 输出重叠；下一条进程命令直接复用已挂载
    -- 探针。仅 eBPF 后端生效（strace/procfs 启动廉价）。
    prewarm = true,
    prewarm_ttl_ms = 90000, -- 预热有效期（毫秒）：超时未被复用则回收
  },
  -- 写日志增量捕获（默认 "auto"）：用 eBPF 观测到的「本轮写入/删除路径」驱动 capture，只处理
  -- 这些路径，不再全量遍历会话累积的 overlay upper（消除「缓存文件大量、多轮读写卡顿」）。
  -- 仅在观测可信时生效（eBPF + 命令前就绪 + 已排空 + 全绝对路径 + 日志非空）；否则回退全量遍历。
  -- 设为 "off" 关闭。注意：事件按 cgroup 归属，背靠背无间隔的命令可能整体漏事件 → 空日志回退。
  journal_capture = "auto",
  -- 诊断埋点（默认关）：排查 137 / OOM / 资源域终止时开启，仅在 NeoAI 日志记录，
  -- 不改变执行行为、不写入模型可见结果。配合 `:NeoAISandboxDiag` 查看宿主/容器限制与负载。
  diagnostics = {
    enabled = false,          -- 总开关（开启后另记录 [sandbox-profile] 分段耗时：gate:<tool> 端到端 + settle 冻结/结算）
    log_kill_caller = false,  -- cgroup.kill 调用方堆栈（定位谁终止了进程树）
    dump_cgroup_events = false, -- 命令结束时 dump 资源域 memory/pids 事件（OOM 归因）
  },
  -- 会话级常驻沙箱实例：开启后 run_command 的命令在同一 mount+pid 命名空间内执行，
  -- 后台进程（&/nohup/setsid）跨工具调用存活（接近普通 bash）。独立 overlay 基目录与会话级
  -- 资源域；AI 编辑经命名空间内物化写回，命令改动仍按次冻结为候选。overlay 不可用 / T2 档位
  -- / 启动失败时自动回退一次性进程路径。仅适用于 T0 的 run_command。
  resident = {
    enabled = true, -- 会话级常驻沙箱实例（run_command 后台进程跨调用存活）；不适用时自动回退
    -- 物化单文件内嵌上限（字节）：超过则宿主侧复制进收件箱、服务器在命名空间内按文件复制
    -- （只发小帧），避免大文件内容经常驻 stdin 传输（bash 逐字节 read 打满 CPU）。
    -- 0 = 回退 tools.sandbox.max_file_bytes。
    max_embed_bytes = 262144,
  },
  -- 内部长驻服务（sandbox.service）：不再注册 service_* 工具（AI 不可见），仅由 systemctl
  -- 门面复用在沙箱内启停单元进程（独立 overlay + 资源域，停止时捕获改动为候选）。
  service = {
    enabled = true,          -- 内部能力总开关
    max_services = 16,       -- 同时存活的服务数上限
    max_log_bytes = 262144,  -- 单服务日志环形缓冲上限（字节）
    stop_timeout_ms = 5000,  -- 停止时先发 SIGTERM 等待优雅退出的上限（超时 SIGKILL）
    auto_background = true,  -- 保留常量（旧后台门面已移除，不再触发）
  },
  -- systemctl 门面（方案 A）：解析/实现全在 Lua（sandbox/systemd），沙箱内
  -- /usr/bin/systemctl、/usr/bin/journalctl 为极薄入口（bash 文件 IPC 客户端），把 argv 转发
  -- 给宿主门面并按真实 stdout/stderr/退出码返回。独立调用由门禁直接路由，脚本/管道调用经入口
  -- 走同一门面；不调用宿主 systemd、也不修改宿主机。支持 simple/exec/oneshot 与
  -- Requires/Wants/After/Before 依赖；Type=notify/forking/dbus、socket/timer 等语义明确报错；
  -- 门面不处理的动词回退 T2/hostop 提案路径。
  systemd = {
    enabled = true,          -- 总开关
    mode = "facade",         -- facade（默认）：沙箱内处理
    max_deps = 32,           -- 单次调用的依赖闭包上限（防依赖环/超大图）
    unit_roots = {           -- 单元文件搜索目录（优先沙箱暂存副本，再读真实文件）
      "/etc/systemd/system", "/run/systemd/system",
      "/usr/lib/systemd/system", "/lib/systemd/system",
    },
    -- 伪造 systemd --user 解析器：`systemctl --user` 由门面解析用户单元根并处理简单
    -- start/stop/is-active/status/show/cat/list-units/daemon-reload 与 enable/disable（软链暂存）。
    -- 不启动真实 systemd/dbus（临时沙箱环境更稳定）。默认开启；enabled=false 时 `--user` 报错。
    user = { enabled = true },
    -- 用户单元文件搜索目录（优先沙箱暂存副本，再读真实文件）。缺省见下。
    -- user_unit_roots = { "~/.config/systemd/user", "/etc/systemd/user", "/usr/lib/systemd/user" },
    -- 系统级 systemctl enable/disable：解析 [Install] WantedBy/RequiredBy，把软链变更暂存为
    -- 待审候选，审批后应用；不落宿主机。默认开启。
    stage_install = true,
    -- 维护脚本兼容桩（默认开）：包安装的 dpkg/apt postinst 会调用
    -- invoke-rc.d/deb-systemd-invoke/systemctl；沙箱 PID1 非 systemd、无系统 dbus，直接调用宿主
    -- systemctl 会连接总线失败。为包安装命令额外注入 policy-rc.d（拒绝服务动作，退出 101），
    -- 使包安装成功、服务不真正启动（沙箱内手动前台运行）。systemctl/journalctl 入口本身由
    -- enabled 控制、对所有命令生效，与此开关无关。
    maintscript_stubs = true,
  },
  network = {
    enabled = false, allowed_endpoints = {}, budget_bytes = 0, -- 受控网络网关
    -- 拦截向宿主本机（回环/宿主网卡 IP/链路本地/云元数据）的访问（默认开）：注入
    -- HTTP(S)_PROXY/ALL_PROXY 指向宿主侧 Lua 过滤代理，本机目标拦截、外部放行并记录。
    -- 应用层边界：不认代理的裸 TCP 可绕过（详见 docs/sandbox.md §6.1）。
    host_local_block = true,
    block_proxy_evasion = true,      -- host_local_block 生效时拒绝显式清除/绕过代理的命令（unset *proxy、env -u、--noproxy、--proxy ""），防止过滤失效直达宿主本机
    host_local_proxy_port = 0,       -- 宿主过滤代理端口（0 = 自动分配 loopback 随机端口）
    allow_localhost_ports = {},      -- 本机端口白名单（默认空=全拦）：仅放行「回环地址 + 这些端口」的本机访问（如沙箱内服务自测 5432/6379）；宿主网卡 IP/链路本地/云元数据永不放行。沙箱内命令启动的临时监听端口会按 cgroup 归属自动登记免权限，无需在此列出
    -- 沙箱网络访问策略：沙箱内部创建的进程/端口（回环 + allow_localhost_ports + 服务端口登记表）
    -- 在沙箱内访问免权限；访问沙箱外（宿主本机其他端口、宿主网卡、外部主机）按此策略处理：
    --   "ask"（默认）= 弹窗请求用户同意（headless/无 UI 时失败关闭）；
    --   "allow"       = 直接放行并记录（旧行为）；
    --   "deny"        = 直接拒绝。
    access = "ask",
    -- 沙箱外部命令代理策略：strip（默认，不把宿主代理传入沙箱，如 mihomo 只代理 opencode 自身，
    -- 避免宿主 HTTPS_PROXY=127.0.0.1:7890 在沙箱内不可达导致 pip/npm 失败）| passthrough（沿用宿主）|
    -- table { http, https, all, no_proxy }（显式设置；未列出的代理变量清除）。
    -- 注意：host_local_block 开启时会注入指向宿主过滤代理的变量，此时 strip 不生效。
    proxy = "strip",
    -- 独立 netns + 宿主网关（opt-in）：沙箱进程进入隔离网络命名空间，只能到达宿主网关；
    -- 网关对目标 host:port 先做 TCP connect 探针（可探测宿主哪些端口在监听），但不回传真实
    -- 服务数据，而是把拦截原因（JSON）返回给客户端。仅允许探测宿主本机地址。需 root 与 ip。
    gateway = { enabled = false, probe_timeout_ms = 1000, max_probes = 4096 },
    -- 国内/受限网络镜像（默认空 = 沿用系统）：仅对沙箱外部命令生效，经环境变量注入。
    --   pip   → PIP_INDEX_URL + PIP_TRUSTED_HOST（如 "https://pypi.tuna.tsinghua.edu.cn/simple"）
    --   npm   → npm_config_registry（如 "https://registry.npmmirror.com/"）
    --   maven → 生成 settings.xml（镜像全部仓库）经 MAVEN_OPTS -s 指向
    --   apk   → 按原版本路径重写 /etc/apk/repositories（Alpine/musl，如 "https://mirrors.tuna.tsinghua.edu.cn/alpine"）
    --   go    → GOPROXY（如 "https://goproxy.cn,direct"）
    --   rustup→ RUSTUP_DIST_SERVER / RUSTUP_UPDATE_ROOT（如 "https://mirrors.tuna.tsinghua.edu.cn/rustup"）
    mirrors = { pip = "", npm = "", maven = "", apk = "", go = "", rustup = "" },
  },
  -- 权限档位与自动提权：命令默认 T0 最小权限（cap-drop ALL + 基线 CAP_DAC_OVERRIDE + CAP_SETUID/CAP_SETGID、网络默认放行并拦截本机）。
  -- 权限/网络失败时**全档位**自动升级（T0→T1→T2，直到 max_tier）并在隔离内重跑，每步写证据/事件/审计。
  privilege = {
    enabled = true, auto_escalate = true, max_tier = 2, record = true,
    tiers = {                       -- 各档位的网络/额外 cap/挂载/解除遮蔽/审查严格度
      [0] = { name = "minimal", review = "auto", network = true, cap_add = { "CAP_DAC_OVERRIDE", "CAP_SETUID", "CAP_SETGID" }, mounts = {}, unmask = {} }, -- 默认最小权限：cap-drop ALL + 基线 CAP_DAC_OVERRIDE（root 载荷访问他人属主 0700 目录）+ CAP_SETUID/SETGID（沙箱内降权到非 root，供 PostgreSQL 等拒绝 root 的服务/runuser/setpriv）。默认放行网络（仅记录）；本机访问经 host_proxy 拦截
      [1] = { name = "elevated", review = "auto", network = true, cap_add = { "CAP_DAC_OVERRIDE", "CAP_SETUID", "CAP_SETGID" }, mounts = {}, unmask = {} }, -- docker.sock 仅 docker 命令按需解除遮蔽
      [2] = { name = "privileged", review = "approve", network = true, userns = true, cap_add = { "ALL" }, mounts = {}, unmask = {} }, -- 嵌套 userns 内完整能力（作用域受限）；seccomp 仍生效
    },
    -- 系统管理命令（useradd/chown/passwd 等）：命中即按需加回窄能力并解除账户库遮蔽，
    -- 使 `useradd`/`usermod`/`groupadd`/`chown`/`passwd` 在沙箱内可用（默认最小权限下会因
    -- 缺少 CHOWN/SETUID/SETGID/DAC_OVERRIDE 及账户库被遮蔽而失败）。写入仍进 overlay 暂存，
    -- 真实账户库/文件系统不受影响；普通命令仍最小权限、账户库仍遮蔽（不泄露口令哈希）。
    -- 系统管理命令 + 降权包装器（sudo/doas/su/runuser/setpriv）：命中即按需加回窄能力并解除
    -- 账户库/sudoers 遮蔽，使 `sudo -u <user>`/`runuser -u <user>`/`setpriv` 可在沙箱内降权。
    sysadmin = {
      cap_add = { "CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_DAC_READ_SEARCH", "CAP_FOWNER", "CAP_SETUID", "CAP_SETGID", "CAP_SETFCAP", "CAP_FSETID", "CAP_SYS_CHROOT", "CAP_KILL" },
      unmask = { "/etc/passwd", "/etc/group", "/etc/shadow", "/etc/shadow-", "/etc/gshadow", "/etc/gshadow-", "/etc/subuid", "/etc/subgid", "/etc/subuid-", "/etc/subgid-", "/etc/sudoers", "/etc/sudoers.d" },
    },
    classify = {                    -- 命令分类规则（bins 精确可执行名；bin+subs 可执行名+子命令）
      -- 注：sudo/doas 不在此列——它们是降权包装器，分类时被跳过、由被包裹命令决定档位
      -- （`sudo mount` 仍为 T2）；其降权需求按 sysadmin 处理（见上）。
      { tier = 2, name = "privileged", bins = { "mount", "modprobe", "iptables", "systemctl", "unshare", "nsenter" } },
      { tier = 1, name = "docker", bins = { "docker", "docker-compose", "nerdctl" } }, -- 有守护进程：受控 socket
      { tier = 1, name = "container", bins = { "podman", "podman-compose", "buildah", "skopeo" } }, -- 无守护进程：可与沙箱同 namespace
      { tier = 1, name = "network", bins = { "curl", "wget", "ssh", "rsync", "ping", "socat" } },
      { tier = 1, name = "network", bin = "git", subs = { "push", "pull", "fetch", "clone" } },
      { tier = 1, name = "sysadmin", bins = { "useradd", "usermod", "userdel", "adduser", "deluser", "groupadd", "groupmod", "groupdel", "addgroup", "delgroup", "passwd", "chpasswd", "chage", "chfn", "chsh", "chown", "chgrp", "setfacl" } }, -- 系统管理：窄能力 + 账户库解除遮蔽
      { tier = 1, name = "package", bins = { "apt", "apt-get", "dnf", "yum", "pacman", "apk", "brew" } }, -- 包安装：额外规则
    },
  },
  -- 容器门面：docker/nerdctl 依赖宿主守护进程，默认 off（明确报错「沙箱环境不支持」，不碰宿主）。
  -- 需要时显式设为 controlled 并给出受控 socket（rootless / socket-proxy / dind）。
  docker = { mode = "off", socket = "" }, -- off | controlled
  -- 容器门面：podman/buildah 无守护进程运行时注入 --net/pid/ipc/uts=host，与沙箱同 namespace，
  -- 容器在沙箱内运行；docker/docker-compose 默认改写为 podman/podman-compose 在沙箱内执行
  -- （docker_to_podman=false 则直接拒绝）；nerdctl 默认拒绝（见上）。
  container = { enabled = true, share_namespace = true, prefer = "podman", docker_to_podman = true },
  -- 存储基根：每进程实例隔离在 <workspace_root>/instances/<pid>_<ts>，待审队列/候选跨会话互不可见。
  workspace_root = vim.fn.stdpath("cache") .. "/NeoAI/sandbox",
  -- 沙箱暂存后端（进程 overlay upper/work、每会话私有 /tmp、LSP overlay 等）：
  --   "disk"（默认）= 磁盘（优先 /var/tmp，退回 nvim 缓存目录）下的无特征隐藏目录；
  --   "shm" = /dev/shm（内存，更快但占内存）；绝对路径 = 以该目录为基。
  staging_backend = "disk",
  session_shell = true,            -- run_command 会话内保留 shell 状态（export/cd 跨命令生效；仅 bwrap）
  process_roots = {},              -- 额外可写根（仅 read_all=false 或整机 overlay 不可用时生效；overlay 覆盖，默认仅 cwd 自动补入）。read_all=true（默认）时整机根已是可写 overlay，本项不再需要。/tmp、/var/tmp 属 tmpfs_roots；按需显式加回
  overlay_fail_closed = true,      -- overlay 不可用时拒绝 process 工具（不降级为私有 cwd）；false 才允许降级运行
  staging_uncovered = "reject",    -- 有未发布暂存但本次命令无 overlay 可写层时："reject"（默认，fail-closed）| "warn"（降级执行并在结果附提示，便于临时绕过偶发失败）
  degraded_seed = false,           -- 无 overlay 播种视图：true 时把可写根真实内容复制进会话私有 bind 目录，使降级/嵌套 userns 视图也能看到真实文件（写入仍落私有副本并冻结为候选；真实盘只读）。默认 false；容器/无 overlay 环境可开启，配合 overlay_fail_closed=false
  degraded_seed_max_bytes = 2 * 1024 * 1024 * 1024, -- 播种字节上限（0=不限）；超限放弃播种并回退 fail-closed（避免复制超大工作区）
  -- 异步审批：候选进入待审队列，用户确认后应用。session_auto_approve 开启后 L0/L1 自动应用。
  -- l3_warning：高危条目二次确认（AI 生成后果警告 + 自动打开 diff，需再次确认才应用）。
  --   L3（critical）恒触发；package_confirm=true 时 L2 包安装/敏感安装（apt-key、gpg --import、
  --   改软件源等）也触发；安全安装（L1）仍只需一次确认。确认窗标题按级别区分并高亮按键提示，
  --   若冻结时剔除了遮蔽/易变缓存文件会在警告区提示「将跳过 N 个」。
  -- ai_audit：待审界面按 `a`（可配置 key）把用户消息 + 分级的待审变更结构化文本交给模型，
  --           **逐条**（每个文件/主机命令）生成 ≤50 字、以「安全/不安全」开头的暗灰补充说明
  --           （显示在文件行下方，高危变更优先且不得省略；模型漏答的条目标注「请人工确认」，
  --           顶部先给出整体安全/不安全结论，不进入聊天界面）。auto=true 时打开待审界面自动
  --           发起审计（默认关闭；集合变化时自动重审）。全局并发上限 max_concurrent（默认 10，
  --           在途请求超出即排队 FIFO），避免 auto 频繁触发时请求风暴。
  review = { enabled = true, auto_apply = false, session_auto_approve = false,
             l3_warning = { enabled = true, package_confirm = true, max_tokens = 256, timeout_ms = 15000 },
             ai_audit = { enabled = true, auto = false, key = "a", max_concurrent = 10,
                          max_diff_chars = 8000, max_user_chars = 4000, max_total_chars = 60000,
                          max_tokens = 2048, timeout_ms = 30000 } },
  -- 审批按安全级别分级（L0-L3）：动作 auto/record/review/block；默认 default="review"。
  approval = { default = "review", levels = {} },
  -- 风险分级（sandbox/risk.lua）：命令结果判定级别时仅扫描 stdout/stderr 首/尾各
  -- result_scan_bytes 字节，避免 `timeout=-1` 的大输出（可达数百 MB）在主线程全量
  -- lower + 模式匹配而冻结界面；0 = 不限制。
  risk = { result_scan_bytes = 262144 },
  -- 脚本间接执行静态扫描：`bash deploy.sh`、`python setup.py`、`node x.js`、`./run.sh`、
  -- `bash -c '…'` 等委托给脚本/解释器时，执行前读取脚本内容（优先沙箱暂存副本）并提取
  -- Shell 正文与高级语言（Python/Node/Ruby/Perl/PHP）内嵌 shell 调用，折叠进危险识别与权限
  -- 分类：脚本内破坏性/内核命令硬拒绝，其余命中或不透明（eval、base64|sh、动态 `-c "$VAR"`、
  -- 读不到内容等）提升级别并强制复核（不自动应用）。max_* 为递归/读取上限。
  script_scan = { enabled = true, max_depth = 3, max_files = 8, max_bytes = 262144 },
  -- 安装包（apt/pip/npm 等）额外规则：review（默认，强制待审，不随自动审批放行）| allow | deny。
  -- managers 也用于识别包管理器：包安装候选按「安装命令」合并为一个审批单元（头行整包一次应用）。
  -- 识别会跳过 sudo/doas/env/bash -c/for…do 等包装器，避免漏判包安装而误升 L3。
  -- roots = 包安装可写 overlay 暂存根：使 apt/pip/npm 等能写索引/缓存/元数据与安装目标
  --         （/usr 覆盖 /usr/bin、/usr/games 等；/var 覆盖 dpkg/apt 状态、man 缓存等），
  --         写入冻结为候选，真实盘不变。
  -- cap_add = 当全局 cap_add 收窄（如 {}）时，包安装按需加回的窄 capability（仅整条命令均为
  --           包管理器时授予；不含 CAP_MKNOD，设备节点由 seccomp 基线硬拦，FIFO 不受影响）。
  packages = {
    mode = "review", -- review（安全安装仅需确认、风险封顶中危 L1；改动软件源/密钥的敏感安装保留 L2）| allow（放行）| deny（拒绝）
    managers = { "apt", "apt-get", "pip", "pip3", "uv", "conda", "npm", "npx", "pnpm", "yarn", "go", "cargo", "gem", "composer" }, -- 包管理器名单（命令识别）；改动路径特征见 privilege.package_path_manager；敏感安装判定见 privilege.package_sensitive
    roots = { "/usr", "/var", "/etc", "~/.cache", "~/.npm", "~/.nvm", "~/.cargo", "~/.rustup", "~/go", "~/.local" }, -- 包安装可写根（overlay 暂存）。/etc 供 dpkg postinst 写 /etc/ld.so.cache 等；敏感条目仍由 mask_paths 遮蔽
    volatile_paths = { "/var/lib/apt/lists", "/var/cache/apt", "/var/cache/dnf", "/var/cache/yum", "/var/cache/pacman/pkg", "/var/cache/apk", "~/.cache/pip", "~/.cache/uv", "~/.npm/_cacache", "~/.cache/yarn", "~/.cargo/registry/cache", "~/.cache/go-build" }, -- 易变包索引/缓存：冻结候选时跳过（不待审、不发布），避免 apt update 后基线变化触发 BASELINE_CHANGED 使整个安装失败；不影响安装效果（dpkg/status、包文件仍应用）；{} 关闭。勿放 /var/lib/dpkg/status 等状态文件
    cap_add = { "CAP_DAC_OVERRIDE", "CAP_CHOWN", "CAP_SETUID", "CAP_SETGID", "CAP_FOWNER" },
    unmask = { "/etc/passwd", "/etc/group", "/etc/shadow", "/etc/shadow-", "/etc/gshadow", "/etc/gshadow-" }, -- 包安装期间解除账户库遮蔽：dpkg postinst 的 adduser/useradd/su 子进程需读写账户库；写入仍进 overlay 暂存、需审批发布
    apt_sandbox_user = "root", -- apt 系列：注入 APT::Sandbox::User（默认 "root" 关闭 apt 自身的 `_apt` 降权，避免嵌套 userns/受限容器中 setgroups EPERM 使 apt update/install 失败）；"_apt" 或空串保留 apt 默认行为
  },
  lsp_overlay = { enabled = true }, -- AI 专用沙箱 LSP：AI 的 lsp_* 工具克隆的 server 读暂存内容（默认开，仅 bwrap+overlay；不可用时回退编辑器客户端）
  secrets = { enabled = true, min_length = 20, max_length = 200, min_entropy = 3.5, min_distinct = 8, exclude_pure_hex = true, entropy_requires_context = true, entropy_secret_paths_only = true, generated_scan_max_bytes = 2097152, generated_scan_max_files = 200, tokenize_env = true, binary_fake = true, disclose_fakes = false, flow_tracking = true, alert = { enabled = true, timeout_ms = 0 }, trusted_services = {}, auto_trust_providers = true, extra_rules = {}, allowlist = {} }, -- 密钥/敏感信息防护：熵检测 + 具名规则（私钥块/AKIA/ghp_/sk-/JWT/Bearer…）+ **格式保真假密钥**（同长度/同字符类/熵不低于原始；进程内映射表不落盘）；env 名含 KEY/TOKEN/SECRET/PASSWORD/CREDENTIAL 的值无视熵强制假化；裸熵串须含 -/_ 且非代码标识符（snake_case 函数/常量名）或处于敏感名上下文；非敏感名且值含 / 的环境变量只按具名规则处理（不破坏 PATH/LD_LIBRARY_PATH 等）；entropy_secret_paths_only=true 时全文熵扫描仅对疑似密钥文件执行。**假密钥**出现在工具参数/AI 上下文时警告用户（不阻断）；**真实密钥**出现时立即停止 Agent 并弹窗，用户确认后才继续（headless 无 UI 时失败关闭）。binary_fake=true 时敏感二进制密钥文件（.p12/.pfx/keystore/raw key）被读取/暂存时用同长度随机字节假化（base64 标记传输，落盘/执行时精确还原）。flow_tracking=true 时记录假密钥来源与所有流经点（工具/命令/环境变量/落盘），命令/脚本加密等不可逆变换产生的派生文件标记「不透明派生」并在发布前强制人工确认。trusted_services 为出网白名单（精确主机/`*.suffix`/IP/CIDR）：向白名单发送密钥不弹窗也不警告；auto_trust_providers=true 时已配置的模型供应商 base_url 主机自动信任；disclose_fakes=true 时向 AI 披露「这是假密钥」（默认不披露以保持格式保真）
  retention = { candidate_days = 7, max_pending = 20 },
  policy = {
    version = "1",                 -- 策略版本（用于审计回放；规则变更时递增）
    deny_tools = {},               -- 硬拒绝工具名（用户确认亦不可覆盖）
    rules = {},                    -- 受限 Lua 规则函数数组：返回 { decision, reason_codes }
  },
  -- 资源限制（cgroup v2）：默认 dynamic=true，按宿主资源动态推导 CPU/内存/PID 上限，
  -- 防止沙箱内命令吃满整机卡死；静态值 >0 时优先。容器内还会读当前 cgroup 的实际配额
  -- （/proc/self/cgroup 沿父链的 memory.max/cpu.max）并取 min，避免按宿主高估。
  -- 所有并发任务挂在共享父域下，cpu_global_max 为并发 CPU 总预算（默认 核数-1），
  -- cpu_cores_max 为单任务配额。fail_closed=false 时 cgroup 不可用则跳过。
  -- delegate_cgroup：在沙箱内把「委派的会话 cgroup 子树」以可写方式挂到 /sys/fs/cgroup，
  -- 使 AI/服务可创建子 cgroup 并写 memory.max/cpu.max（cgroup v2 写隔离）；仅限该子树，
  -- 不污染宿主其它 cgroup；网关模式（ip netns exec）下自动跳过。
  -- disk_bytes：沙箱暂存磁盘上限（字节；0=不限）。统计暂存基目录（进程 overlay/私有 tmp）
  -- 与沙箱存储根（候选/待审/证据/服务 overlay）总占用；超限时拒绝写类/进程工具（用量异步
  -- 统计并缓存，不阻塞命令开始）。
  limits = { wall_ms = 60000, dynamic = true, memory_ratio = 0.75, memory_max_bytes = 0,
    cpu_cores_max = 8, cpu_global_max = 0, pids_max = 8192, memory_bytes = 0, pids = 0, cpu_max = 0,
    cpu_affinity = "auto", -- 沙箱 CPU 亲和性：auto=绑定到 nvim 当前 CPU 之外的核（避免挤占 nvim）；off/ false=不绑定；"2,3"/"2-3"=显式 cpuset（需 taskset）
    cgroup_base = "/sys/fs/cgroup", fail_closed = false, delegate_cgroup = true,
    disk_bytes = 64 * 1024 * 1024 * 1024 }, -- 64 GiB（0 = 不限）
  seccomp_filter_path = "",        -- 可选：编译后 seccomp BPF 过滤器（配合 require_seccomp）
}
```

> 所有工具执行经控制面：预检 → 隔离执行 → 冻结候选 → CAS 发布。默认 `dry_run` 不写真实
> 工作区，候选进入异步待审队列，用 `:NeoAISandboxReview` 查看并应用，或
> `:NeoAISandboxApprove/Reject/Apply <change_set_id>`；`:NeoAISandboxList/Show/Discard/Caps`
> 管理候选与查看运行时能力。策略规则在受限环境执行并有指令/墙钟预算；规则异常统一 DENY。
> 详见 [sandbox.md](sandbox.md)。

**web_fetch（网页抓取，默认不启用）**：

```lua
web_fetch = {
  enabled = false,                 -- 总开关（默认关闭；开启后才会注册工具/安装依赖/抓取）
  auto_install = true,             -- 启用后在后台自动检查/安装依赖；false 则首次调用时按需安装
  engine = "chromium",             -- 浏览器引擎：chromium | firefox | webkit
  format = "markdown",             -- 默认输出格式：markdown | text（只输出正文，不含原始 HTML）
  timeout_ms = 45000,              -- 单次抓取总超时（ms，含启动浏览器）；<=0 时用 nav_timeout_ms + 15s
  nav_timeout_ms = 30000,          -- 页面导航/等待超时（ms）
  max_bytes = 2 * 1024 * 1024,     -- 单次返回内容上限（字节，超出截断）
  install_timeout_ms = 600000,     -- 依赖安装超时（ms，首次下载浏览器内核可能较久）
  node_path = "",                  -- 自定义 node 可执行文件路径（空则用 PATH 中的 node）
  install_os_deps = false,         -- 安装浏览器时是否附带系统依赖（需 root/sudo，一般无需）
  -- 受限网络（国内镜像 / 代理异常）下的下载与代理控制；默认全空 = 沿用系统行为
  npm_registry = "",               -- npm 源；空则用系统 npm 配置。国内可设 "https://registry.npmmirror.com/"
  playwright_download_host = "",   -- 浏览器内核下载基址；空则用官方 CDN。国内可设 "https://registry.npmmirror.com/-/binary/playwright"
  http_proxy = "",                 -- 安装/渲染时显式设置的 HTTP 代理；空则不覆盖继承值
  https_proxy = "",                -- 安装/渲染时显式设置的 HTTPS 代理；空则不覆盖继承值
  ignore_system_proxy = false,     -- true = 安装/渲染时清空继承的代理变量（应对本机代理损坏/不可用）
  -- 注入脚本目录（可扩展/覆盖内置脚本；同名用户脚本优先）
  -- 内置脚本：clean（通用去噪）、readability（正文提取）
  scripts_dir = vim.fn.stdpath("config") .. "/NeoAI/web_fetch/scripts",
  cache = {
    enabled = true,                -- 结果缓存开关
    ttl_sec = 3600,                -- 缓存有效期（秒）；<=0 表示不过期
    max_entries = 200,             -- 缓存条目数上限
    max_bytes = 500 * 1024 * 1024, -- 缓存总大小上限（字节，默认 500MB；超出按最旧优先淘汰）
  },
},
```

> **运行时行为**：禁用时零副作用（不注册工具、不安装依赖）；启用后依赖装到缓存目录
> （`stdpath('cache')/NeoAI/web_fetch`）并使用同一目录下的 `browsers/`，**不改动系统环境**。
> **依赖与浏览器内核的安装在宿主直接执行、不经沙箱**：安装产物（`node_modules`、可达数百 MB
> 的内核）若进入沙箱 overlay 会被每条 `run_command` 反复捕获；渲染仍在沙箱内执行（浏览器从
> 宿主只读可见）。
> 若 `node`/`npm` 缺失，不自动调用系统包管理器，而是返回可操作的错误提示。
> `approval.per_tool.web_fetch = { auto_allow = true }`（默认自动放行）。
> 管线：Lua 编排 → bash 装依赖 → Node/Playwright 渲染并注入 JS → 取 DOM → turndown 转 Markdown。

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

### 2.10 `plugins`

```lua
plugins = {
  builtin = true,                 -- false = 不登记任何内置插件（宿主自管）
  disabled = { "ui", "services.mcp" }, -- 禁用的插件/服务 id（含依赖闭包）
  entries = {
    ["tool.shell"] = false,        -- 禁用某插件
    ["services.model_service"] = { module = "my_model_provider" }, -- 替换实现模块
  },
}
```

- `disabled` 中的插件及其下游依赖会被一并移除；`entries[id] = false` 等价禁用。
- `entries[id] = { module = "..." }` 替换服务/工具实现（模块需可 `require`，接口一致）。
- 插件协议、清理、替换与测试要求详见 [plugins.md](plugins.md)。

## 3. 计划模式（tools/plan_mode）

计划模式作为 **per-agent 状态**（`agent.plan_mode`），激活时：

1. **注入 plan-policy 系统提示段**（`deployment:plan_policy`，order=100）：要求输出清晰、格式化的修改计划。
2. **工具上下文只保留只读/信息查询工具 + `run_command`（只读调研）+ `ask_user`**（`PLAN_SAFE_TOOLS` 白名单 + `PLAN_EXTRA_TOOLS`），不暴露任何修改类工具，也**不向 AI 提供切换模式的工具**。
3. **执行期门禁同步收紧**（`plan_mode.check_tool`）：计划模式下调用可见集之外的任何工具都会被驳回。

**计划确认**：AI 输出计划后本轮结束，由用户执行 `:NeoAIApprovePlan`（或手动切换模式）确认，
经 `chat_service.approve_plan` 解析计划为任务清单（todo）→ 退出计划模式（转入 CHAT）
→ 按 `auto_execute_on_approve`（默认开启）自动开始执行。

状态持久化在 `session.metadata.plan`，恢复会话时还原（`plan_mode.restore`）。

## 4. 相关文档

- [README 配置章节](../README.md)：完整配置示例。
- [tool_system.md](tool_system.md)：`tools.*` 工具/审批配置的运行时行为。
- [ai_engine.md](ai_engine.md)：`ai.context_cache` / `ai.reasoning_enabled` 的引擎侧行为。
- [model_policy.md](model_policy.md)：按模型自动选择（协议方言 / 能力表 / 显式缓存）。
- [plugins.md](plugins.md)：插件系统、服务定位器与默认组合。
