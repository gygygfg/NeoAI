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
  threshold_ratio = 0.8,        -- 达到该比例触发后台异步压缩（不阻塞、不弹窗；显式缓存模型自动取更保守值）
  retain_ratio = 0.16,          -- 溢出恢复时保留的最近历史比例（常规压缩折叠第一轮至倒数第二轮）
  retain_min_tokens = 4096,     -- 溢出恢复的尾部保留下限
  compact_max_tokens = 8192,    -- 压缩摘要输出上限
  min_shadow_messages = 2,      -- 溢出恢复至少折叠多少条（常规压缩按轮次范围）
  compaction_retries = 1,       -- 摘要后仍高于阈值的重试次数（常规压缩无新可折叠消息时停止）
  prune_enabled = true,         -- 摘要前先做模型无关的工具结果裁剪
  prune_threshold_chars = 8192, -- 文本码点超过该值的工具结果才裁剪
  prune_head_chars = 4096,      -- 裁剪保留的头部码点数
  prune_tail_chars = 1024,      -- 裁剪保留的尾部码点数
  include_identity = true,      -- 系统提示是否含固定身份段（-100 顺序位）
  identity = "你是一个由 NeoAI 驱动的 AI 编程助手。",
}
```

> **压缩行为**：常规（阈值触发）压缩在后台**异步非阻塞**执行——折叠第一轮至倒数第二轮（保留最后一轮完整），
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
| `render` | `{threaded=true}` | 把 CPU 密集计算（如工具结果裁剪的码点统计/切片）分配到 `utils.work` 线程池，避免 MB 级工具结果阻塞主线程；设为 `false` 或线程池不可用时自动回退主线程同步计算（行为等价，仅慢） |
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
| `lsp` | `{timeout_ms=10000}` | LSP 请求超时（服务器无响应快速失败） |
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

> **审批决策**：`mode=auto_allow` → 不审批；`mode=strict` → 必审批；
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
  backend = "auto",                -- auto | bwrap | unshare
  offline = false,                 -- 网络默认放行（仅记录，不拦截）；true 时硬拒绝网络并隔离进程网络
  require_seccomp = true,          -- 缺少 seccomp 能力时是否拒绝外部执行（默认开，fail-closed）
  seccomp = { enabled = true, filter_path = "" }, -- seccomp 基线（内置 denylist；默认开；仅 bwrap）
  cap_add = {},                    -- 默认最小权限（`--cap-drop ALL`）；按命令窄范围加回（包安装经 packages.cap_add）。仅调试时才设 { "ALL" }
  -- 载荷运行身份：默认以 root 运行（uid=0），使 AI 能在沙箱内使用宿主工具链（/root 下的
  --   nvm/cargo/go 等 0700 目录非 root 不可遍历）与包管理（dpkg 硬检查 euid==0）。所有写入仍
  --   全部进入 overlay 暂存并冻结为候选，真实磁盘只读；隔离由命名空间 + 只读根 + overlay +
  --   seccomp + 遮蔽保证。
  --   * 非 root 启动 NeoAI：用 user namespace 把当前用户映射为**沙箱内 guest root**（euid=0，
  --     仅命名空间内有效；宿主仍是当前非 root 用户），本项被忽略。真正需要宿主 root 的操作
  --     冻结为待审，用户批准后经 `sudo` 执行。
  --   * root 启动 NeoAI：uid=0 为默认（不降权）；设为专用非 root uid（如 nobody 65534）可加固，
  --     插件先用 `setpriv` 把载荷降为该 uid，配置的窄能力以 ambient 形式保留。此时 /root 不可
  --     遍历，工作区/`workspace_root` 须放在可被其遍历的位置（勿放 0700 的 /root 下）。
  run_as = { uid = 0, gid = 0 },
  cap_drop = {                     -- 主机全局能力收敛：即便 cap_add 含 ALL 也逐项丢弃（网络栈/时钟/内核模块/裸 I/O/重启/MAC/审计）
    "CAP_NET_ADMIN", "CAP_SYS_TIME", "CAP_SYS_MODULE", "CAP_SYS_RAWIO",
    "CAP_SYS_BOOT", "CAP_MAC_ADMIN", "CAP_MAC_OVERRIDE", "CAP_AUDIT_CONTROL",
  },
  max_file_bytes = 8 * 1024 * 1024, -- 单文件纳入候选上限（字节）；超过不纳入候选，防 apt/pkgcache.bin 等大缓存阻塞主线程；0 = 不限制
  -- 读取面（默认开）：true 时整机根以只读方式暴露（`--ro-bind / /`），仅遮蔽 mask_paths 中的
  -- 重要配置文件/凭据（~/.ssh、~/.aws、/etc/shadow、sudoers、docker.sock 等）与沙箱自身存储；
  -- mask_dirs（home/root 兄弟目录）不再挂载遮蔽，但访问 cwd 之外的用户目录会**留痕**
  -- （evidence + `sandbox:outside_access` 事件）并在审批悬浮窗 `:NeoAISandboxReview` 的
  -- 「越界访问留痕」区展示（非阻塞，仍放行）。false 时退回下面的最小只读白名单。
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
  },
  readonly_paths = { "/etc/ld.so.cache", "/etc/passwd", "/etc/group", "/etc/nsswitch.conf",
    "/etc/hosts", "/etc/ssl", "/etc/alternatives", "/etc/localtime",
    "/etc/os-release", "/etc/terminfo", "/etc/profile", "/etc/security", "/etc/pam.d" },
  expose_paths = {},               -- 宿主运行时直通（opt-in）：这些宿主路径在遮蔽/临时根之后只读暴露，并前置到沙箱 PATH，使 run_command 能调用宿主工具链（如 nvim/lua/luajit/mason）。仅暴露可信只读工具目录
  expose_path_env = true,          -- 是否把 expose_paths 目录前置到沙箱 PATH（false 仅挂载不改 PATH）
  expose_tool_paths = false,       -- 自动直通宿主 PATH 中的工具目录（opt-in）：把宿主 PATH 里存在且非凭据/系统目录的 bin 目录只读暴露并前置到沙箱 PATH，使 node/npm/fd/go 等装在 $HOME 下的工具链可用（会扩大读取面）
  appimage_extract_and_run = true, -- AppImage 支持（默认开）：沙箱内运行 AppImage 时注入 APPIMAGE_EXTRACT_AND_RUN=1，解包到会话私有 /tmp 运行（沙箱按设计拦截 mount/不暴露 /dev/fuse，无法 FUSE 挂载）；非 AppImage 程序忽略该变量。false 关闭
  resolv_conf = "sanitize",        -- /etc/resolv.conf：sanitize（默认，仅 nameserver）| hide | passthrough
  tmpfs_roots = { "/tmp", "/var/tmp" }, -- 每会话私有临时根（不作为 overlay lower；退出即销毁）
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
  network = {
    enabled = false, allowed_endpoints = {}, budget_bytes = 0, -- 受控网络网关
    -- 拦截向宿主本机（回环/宿主网卡 IP/链路本地/云元数据）的访问（默认开）：注入
    -- HTTP(S)_PROXY/ALL_PROXY 指向宿主侧 Lua 过滤代理，本机目标拦截、外部放行并记录。
    -- 应用层边界：不认代理的裸 TCP 可绕过（详见 docs/sandbox.md §6.1）。
    host_local_block = true,
    host_local_proxy_port = 0,       -- 宿主过滤代理端口（0 = 自动分配 loopback 随机端口）
    -- 沙箱外部命令代理策略：strip（默认，不把宿主代理传入沙箱，如 mihomo 只代理 opencode 自身，
    -- 避免宿主 HTTPS_PROXY=127.0.0.1:7890 在沙箱内不可达导致 pip/npm 失败）| passthrough（沿用宿主）|
    -- table { http, https, all, no_proxy }（显式设置；未列出的代理变量清除）。
    -- 注意：host_local_block 开启时会注入指向宿主过滤代理的变量，此时 strip 不生效。
    proxy = "strip",
    -- 独立 netns + 宿主网关（opt-in）：沙箱进程进入隔离网络命名空间，只能到达宿主网关；
    -- 网关对目标 host:port 先做 TCP connect 探针（可探测宿主哪些端口在监听），但不回传真实
    -- 服务数据，而是把拦截原因（JSON）返回给客户端。仅允许探测宿主本机地址。需 root 与 ip。
    gateway = { enabled = false, probe_timeout_ms = 1000, max_probes = 4096 },
  },
  -- 权限档位与自动提权：命令默认 T0 最小权限（非 root 载荷、cap-drop ALL、网络默认放行并拦截本机）。
  -- 权限/网络失败时**全档位**自动升级（T0→T1→T2，直到 max_tier）并在隔离内重跑，每步写证据/事件/审计。
  privilege = {
    enabled = true, auto_escalate = true, max_tier = 2, record = true,
    tiers = {                       -- 各档位的网络/额外 cap/挂载/解除遮蔽/审查严格度
      [0] = { name = "minimal", review = "auto", network = true, cap_add = {}, mounts = {}, unmask = {} }, -- 默认最小权限：非 root 载荷、cap-drop ALL。默认放行网络（仅记录）；本机访问经 host_proxy 拦截
      [1] = { name = "elevated", review = "auto", network = true, cap_add = {}, mounts = {}, unmask = {} }, -- docker.sock 仅 docker 命令按需解除遮蔽
      [2] = { name = "privileged", review = "approve", network = true, userns = true, cap_add = { "ALL" }, mounts = {}, unmask = {} }, -- 嵌套 userns 内完整能力（作用域受限）；seccomp 仍生效
    },
    classify = {                    -- 命令分类规则（bins 精确可执行名；bin+subs 可执行名+子命令）
      { tier = 2, name = "privileged", bins = { "sudo", "mount", "modprobe", "iptables", "systemctl", "unshare", "nsenter" } },
      { tier = 1, name = "docker", bins = { "docker", "docker-compose", "nerdctl" } }, -- 有守护进程：受控 socket
      { tier = 1, name = "container", bins = { "podman", "podman-compose", "buildah", "skopeo" } }, -- 无守护进程：可与沙箱同 namespace
      { tier = 1, name = "network", bins = { "curl", "wget", "ssh", "rsync", "ping", "socat" } },
      { tier = 1, name = "network", bin = "git", subs = { "push", "pull", "fetch", "clone" } },
      { tier = 1, name = "package", bins = { "apt", "apt-get", "dnf", "yum", "pacman", "apk", "brew" } }, -- 包安装：额外规则
    },
  },
  -- 受控 docker：不绑定宿主 /var/run/docker.sock；controlled 指向外部受控 socket。
  docker = { mode = "controlled", socket = "/run/neoai-docker/docker.sock" }, -- off | controlled | host
  -- 容器受控运行：podman 等无守护进程运行时注入 --net/pid/ipc/uts=host，与沙箱同 namespace；
  -- docker 依赖外部 daemon，无法共享，保持受控 socket 并记录原因。
  container = { enabled = true, share_namespace = true, prefer = "podman" },
  -- 存储基根：每进程实例隔离在 <workspace_root>/instances/<pid>_<ts>，待审队列/候选跨会话互不可见。
  workspace_root = vim.fn.stdpath("cache") .. "/NeoAI/sandbox",
  session_shell = true,            -- run_command 会话内保留 shell 状态（export/cd 跨命令生效；仅 bwrap）
  process_roots = {},              -- run_command 可写根（overlay 覆盖；默认仅 cwd 自动补入）。/tmp、/var/tmp 属 tmpfs_roots；避免把宿主 /root、/home、/etc 等作为只读 lower 暴露；按需显式加回
  overlay_fail_closed = true,      -- overlay 不可用时拒绝 process 工具（不降级为私有 cwd）；false 才允许降级运行
  -- 异步审批：候选进入待审队列，用户确认后应用。session_auto_approve 开启后 L0/L1 自动应用。
  -- l3_warning：L3（critical）条目二次确认（AI 生成后果警告 + 自动打开 diff，需再次确认才应用）。
  -- ai_audit：待审界面按 `a`（可配置 key）把用户消息 + 分级的待审变更结构化文本交给模型，
  --           **逐条**（每个文件/主机命令）生成 ≤50 字、以「安全/不安全」开头的暗灰补充说明
  --           （显示在文件行下方，高危变更优先且不得省略；模型漏答的条目标注「请人工确认」，
  --           顶部先给出整体安全/不安全结论，不进入聊天界面）。auto=true 时打开待审界面自动
  --           发起审计（默认关闭；集合变化时自动重审）。全局并发上限 max_concurrent（默认 10，
  --           在途请求超出即排队 FIFO），避免 auto 频繁触发时请求风暴。
  review = { enabled = true, auto_apply = false, session_auto_approve = false,
             l3_warning = { enabled = true, max_tokens = 256, timeout_ms = 15000 },
             ai_audit = { enabled = true, auto = false, key = "a", max_concurrent = 10,
                          max_diff_chars = 8000, max_user_chars = 4000, max_total_chars = 60000,
                          max_tokens = 2048, timeout_ms = 30000 } },
  -- 审批按安全级别分级（L0-L3）：动作 auto/record/review/block；默认 default="review"。
  approval = { default = "review", levels = {} },
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
    cap_add = { "CAP_DAC_OVERRIDE", "CAP_CHOWN", "CAP_SETUID", "CAP_SETGID", "CAP_FOWNER" },
  },
  lsp_overlay = { enabled = true }, -- AI 专用沙箱 LSP：AI 的 lsp_* 工具克隆的 server 读暂存内容（默认开，仅 bwrap+overlay；不可用时回退编辑器客户端）
  secrets = { enabled = true, min_length = 20, max_length = 200, min_entropy = 3.5, min_distinct = 8, exclude_pure_hex = true, entropy_requires_context = true, entropy_secret_paths_only = true, tokenize_env = true, extra_rules = {}, allowlist = {} }, -- 密钥/敏感信息防护：熵检测 + 具名规则（私钥块/AKIA/ghp_/sk-/JWT/Bearer…）+ token 加密映射；env 名含 KEY/TOKEN/SECRET/PASSWORD/CREDENTIAL 的值无视熵强制 token 化；裸熵串须含 -/_ 且非代码标识符（snake_case 函数/常量名）或处于敏感名上下文（缩小认定范围，避免误伤 integrity/构建哈希/回溯函数名/路径分量）；非敏感名且值含 / 的环境变量只按具名规则脱敏（不破坏 PATH/LD_LIBRARY_PATH 等）；entropy_secret_paths_only=true 时全文熵扫描仅对疑似密钥文件（~/.ssh、~/.bashrc、/etc/* 等，见 secret.is_secret_path）执行，普通文件只走具名规则
  retention = { candidate_days = 7, max_pending = 20 },
  policy = {
    version = "1",                 -- 策略版本（用于审计回放；规则变更时递增）
    deny_tools = {},               -- 硬拒绝工具名（用户确认亦不可覆盖）
    rules = {},                    -- 受限 Lua 规则函数数组：返回 { decision, reason_codes }
  },
  -- 资源限制（cgroup v2）：默认 dynamic=true，按宿主资源动态推导 CPU/内存/PID 上限，
  -- 防止沙箱内命令吃满整机卡死；静态值 >0 时优先。所有并发任务挂在共享父域下，
  -- cpu_global_max 为并发 CPU 总预算（默认 核数-1），cpu_cores_max 为单任务配额。
  -- fail_closed=false 时 cgroup 不可用则跳过。
  limits = { wall_ms = 60000, dynamic = true, memory_ratio = 0.5, memory_max_bytes = 0,
    cpu_cores_max = 4, cpu_global_max = 0, pids_max = 2048, memory_bytes = 0, pids = 0, cpu_max = 0,
    cpu_affinity = "auto", -- 沙箱 CPU 亲和性：auto=绑定到 nvim 当前 CPU 之外的核（避免挤占 nvim）；off/ false=不绑定；"2,3"/"2-3"=显式 cpuset（需 taskset）
    cgroup_base = "/sys/fs/cgroup", fail_closed = false },
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
