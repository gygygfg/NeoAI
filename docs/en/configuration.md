# NeoAI Configuration System (v3.0)

> [中文](../configuration.md) | **English**

> Configuration is provided as immutable defaults by `default_config.lua` (pure data, zero logic),
> merged and read by `kernel/config_store.lua` (merge + validate + get + watch),
> and the kernel bootstrap is handled by `kernel/lifecycle.lua` (bootstrap/shutdown).
> Corresponding source: `lua/NeoAI/default_config.lua`, `lua/NeoAI/kernel/config_store.lua`.

## 1. Configuration Storage (kernel/config_store.lua)

Replaces the old `merger.lua` + `state.lua` hybrid and manages no business state.

| API | Description |
| --- | --- |
| `load(user_config)` | Deep-merges user overrides onto default → validate → produce immutable config; emits `CONFIG_LOADED`. |
| `get(path, default)` | Reads by dot-separated path (e.g. `ui.window.width`). |
| `get_all()` | Returns the complete configuration. |
| `watch(path, cb)` | Watches config changes (path-prefix match) and returns an unsubscribe function. |
| `set(path, value)` | Hot-updates at runtime, emitting `watch` + `CONFIG_CHANGED`. |
| `reset()` | Reset (for tests). |

`load` validation logic: checks `ai.default_provider`, the `base_url` of each provider in `ai.providers`,
and the `ai.modes` structure, collecting errors and logging them (without blocking).

## 2. Configuration Structure

See `lua/NeoAI/default_config.lua` for the full configuration. The main sections are below.

### 2.1 `ai`

| Key | Default | Description |
| --- | --- | --- |
| `default_provider` | `"deepseek"` | Default provider |
| `default_model` | `"auto"` | "auto" = resolve the default model via the registry |
| `providers` | 13+ providers | Provider definitions: `api_type` (openai/anthropic/google), `base_url`, `api_key`, `fetch_models`, `models_override` |
| `model_refresh` | `{on_startup=true, interval_sec=3600, timeout_ms=10000}` | Model list refresh |
| `modes` | `{chat, plan, auto}` | Per mode → `{provider, model, temperature, stream}` (optional `max_tokens`); applied when entering that mode. If `max_tokens` is not configured, nothing is sent |
| `truncation` | `{enabled=true, max_continues=3}` | Auto-continues when output is truncated with no tool call (the prompt is not stored), and writes a visible notice once the limit is exceeded |
| `reasoning_enabled` | `true` | Enables deep thinking (reasoning_content) |
| `system_prompt` | Default Chinese prompt | persona section |
| `timeout_ms` | `60000` | Request timeout |
| `max_retries` | `3` | Number of request retries |
| `attachments` | See below | Multimodal image configuration |
| `model_policy` | See below | Automatic per-model selection: capability table + vendor dialect + explicit cache |
| `context_cache` | See below | Prefix-cache identity + automatic context compaction |

**attachments (multimodal)**:

```lua
attachments = {
  enabled = true,               -- Master switch for multimodal
  path = ".../NeoAI/attachments", -- Content-addressed attachment storage directory
  vision_models = { "deepseek-v4-flash-vision-exp", "deepseek-vl" },
  vision_model_heuristics = { "vision", "-vl", "4o", "gemini" },
  media_types = { "image/png", "image/jpeg", "image/webp", "image/gif" },
  limits = { maxImageBytes=20MB, maxImagesPerMessage=16, maxMessageImageBytes=40MB,
             maxImagePixels=50M, maxImageDimension=8000 },
  request_image = { maxPixels=640000, maxBytes=1MB, maxImagesPerRequest=8,
                    maxRequestBytes=20MB, maxRequestImages=600 },
}
```

**model_policy (automatic per-model selection)**:

```lua
model_policy = {
  enabled = true,                 -- Master switch
  explicit_cache = {
    enabled = true,               -- Master switch for explicit caching
    openai = false,               -- OpenAI explicit breakpoints are disabled by default
    -- anthropic = true, gemini = true,  -- Per-mechanism switches (default to following the master switch)
  },
  overrides = {                   -- Capability overrides (key = model id or provider name)
    -- ["deepseek-v4-flash"] = { window = 131072, max_output = 8192 },
  },
  dialects = {                    -- Dialect overrides (key = provider name or model id)
    -- ["my-provider"] = { max_tokens_field = "max_completion_tokens", reasoning_kind = "effort" },
  },
}
```

The capability table provides the context window, max output, cache mechanism (`openai`/`anthropic`/`gemini`),
the minimum cacheable tokens, explicit-cache TTL/breakpoint limits, and character/token coefficients; the dialect
table provides provider/model request parameter names, reasoning parameter shapes, auth headers, and
usage fields. See [model_policy.md](model_policy.md) for details.

**Live value retrieval**: the context window / max output are preferably fetched **live** from each vendor's
`/models` endpoint (Google's `inputTokenLimit`/`outputTokenLimit`, OpenRouter's
`context_length`/`top_provider.max_completion_tokens`, Groq's `context_window`, etc.); only when that fails does
it fall back to the built-in table. Value precedence: **user `overrides` → live metadata →
built-in pattern → `api_type` default → fallback** (`caps.source` records the source).
`max_tokens` sending policy: only explicitly configured values (via `opts.max_tokens` or `modes.*.max_tokens`) are
sent; if not configured, it is **not sent**, and the model/vendor default max output applies (live values /
`overrides.max_output` are no longer sent automatically, and are used only for capping and capacity display);
Anthropic `max_tokens` is required, and falls back to the capability table's `max_output`.

**context_cache (prefix caching + compaction)**:

```lua
context_cache = {
  enabled = true,
  context_window = 64000,       -- Context window fallback: an explicit non-default user value wins, otherwise it is derived from the model capability table
  threshold_ratio = 0.8,        -- Reaching this ratio triggers background async compaction (non-blocking, no window; explicit-cache models use a more conservative value)
  retain_ratio = 0.16,          -- Proportion of recent history retained for overflow recovery (regular compaction folds round 1 through the second-to-last round)
  retain_min_tokens = 4096,     -- Lower bound for the retained tail during overflow recovery
  compact_max_tokens = 8192,    -- Max output for the compaction summary
  min_shadow_messages = 2,      -- Minimum messages to collapse during overflow recovery (regular compaction uses the round range)
  compaction_retries = 1,       -- Retries when still above the threshold (regular compaction stops when no new messages are foldable)
  prune_enabled = true,         -- Perform model-agnostic tool-result pruning before summarization
  prune_threshold_chars = 8192, -- Only tool results whose text code points exceed this value are pruned
  prune_head_chars = 4096,      -- Number of head code points kept when pruning
  prune_tail_chars = 1024,      -- Number of tail code points kept when pruning
  include_identity = true,      -- Whether the system prompt includes the fixed identity section (order position -100)
  identity = "You are an AI programming assistant powered by NeoAI.",
}
```

> **Compaction behavior**: regular (threshold-triggered) compaction runs **asynchronously in the background and non-blocking** — it folds round 1
> through the second-to-last round (keeping the last round intact) and, once the summary completes, writes a **compaction overlay** (`agent.compaction`).
> Subsequent requests and further compactions use the compacted replacement, while chat rendering and session persistence keep the **original context**
> (the overlay is persisted in `session.metadata.compaction` and survives a restart). Compaction opens **no floating window**. Context-overflow
> recovery (`force_compact`) still blocks and awaits, and uses `retain_ratio`/`retain_min_tokens`/`min_shadow_messages` for a maximal reduction.

### 2.2 `ui`

| Key | Default | Description |
| --- | --- | --- |
| `default_view` | `"chat"` | Default view (chat/tree) |
| `window_mode` | `"tab"` | Window mode (float/tab/split) |
| `window` | `{width=80, height=24, border="rounded"}` | float window |
| `split` | `{size=80, direction="right"}` | split window |
| `colors` | Per-segment highlights | User/AI/reasoning/title colors |
| `tree` | `{foldenable=false, ...auto_close_on_select=true}` | Session tree folding/auto-close |
| `input_box` | `{idle_height=1, min_height=5, max_ratio=0.8}` | Input box height (idle/focused/growth cap) |
| `chat` | `{mousescroll_max_blank=3, incremental=true}` | Max blank lines allowed below the last line when the wheel reaches the bottom (0 = strictly bottom-aligned); `incremental` enables incremental refresh (re-render only changed message blocks and write only the diff lines). Set to `false` to fall back to a full buffer rewrite |
| `render` | `{threaded=true}` | Offload CPU-intensive computation (e.g. codepoint counting/slicing for tool-result pruning) to the `utils.work` thread pool so MB-scale tool results never block the main thread. Set to `false` (or when the pool is unavailable) to fall back to synchronous main-thread computation (equivalent behavior, just slower) |
| `trajectory` | `{log_dir=".../NeoAI/logs"}` | Log directory for the trajectory display mode |
| `statusline` | `{enabled=true, winbar=true, parts={mode,model,usage,cache,capacity,sandbox}, separator=" ", colors=...}` | lualine statusline; the `sandbox` part shows `待审N` when pending reviews > 0 (`N` is the total number of pending **files**, since the approval unit is a single file), linked to the prominent `NeoAISandboxPending` highlight group by default (bold yellow, override via `colors.sandbox`); when the pending queue contains an **L3 (high-risk)** item, the part appends `⚠危险` and switches to the red `NeoAISandboxDanger` group (override via `colors.sandbox_danger`); when **outside-workspace traces** exist, the part appends `越界N` (`N` = distinct file count; both shown side by side, e.g. `待审2 越界3`) |

### 2.3 `keymaps`

| Section | Description |
| --- | --- |
| `global` | `toggle_ui`(<leader>aa), `open_chat`(<leader>ac), `open_tree`(<leader>at), `close_all`(<leader>aq) |
| `tree` | `quit`(q), `select`(<CR>), `new_child`(n), `new_root`(N), `delete_dialog`(d, delete selected round), `delete_branch`(D, delete owning session and all descendants), `expand`(o), `collapse`(O) |
| `chat` | `insert`(i), `quit`(q), `send`, `cancel`(<Esc>), `toggle_reasoning`(r), `switch_model`(M), `cycle_mode`(m), `cycle_display`(<C-t>/T), `reload_display`(<F5>), `tool_approval`(<C-a>), `sandbox_review`(<leader>ap, view and apply pending sandbox changes), `approval.*` |

### 2.4 `session`

```lua
session = {
  auto_save = true,
  auto_naming = true,
  save_path = ".../NeoAI",
  max_history_per_session = 1000,
  file = "sessions.jsonl",   -- Append-only JSONL
}
```

### 2.5 `tools`

| Key | Default | Description |
| --- | --- | --- |
| `enabled` | `true` | Master switch for the tool system |
| `builtin` | `true` | Load built-in tools |
| `external` | `{}` | External tools |
| `read_file` | `{outline_threshold_chars=500, outline_max_nodes=200, outline_max_depth=4, outline_preview_lines=50, max_read_bytes=5242880}` | read_file large-file protection: when no line range is specified and the threshold is exceeded, return a syntax-tree outline (or a truncated preview if no parser is available); files over `max_read_bytes` are never fully read (preview only) to avoid OOM |
| `search_files` | `{max_file_bytes=8388608}` | Per-file scan cap (bytes) during search; larger files and binaries (containing NUL) are skipped to avoid OOM |
| `run_command` | `{max_output_bytes=16777216, max_wall_ms=0}` | Combined stdout/stderr cap (bytes): beyond it the command is truncated and terminated, so huge outputs cannot freeze the main thread with line-by-line processing; 0 = unlimited. `max_wall_ms>0` is a wall-clock safety net: the command may run at most that many milliseconds (also bounding `timeout_ms=-1` "unlimited" commands) and is then truly killed via the sandbox resource domain; 0 = unlimited |
| `lsp` | `{timeout_ms=10000, attach_timeout_ms=3000}` | LSP request timeout (fail fast when the server does not respond); `attach_timeout_ms` is how long to wait for a client to attach: when a background-loaded buffer or a starting/restarting server has no client yet, `lsp_diagnostics` waits for it instead of failing immediately with "no LSP client" |
| `guard.repeat_tool` | `{enabled=true, thresholds={3,5,8}, messages=...}` | Reminder for consecutive repeated tool calls |
| `todo.enabled` | `true` | Todo tool + system prompt injection |
| `web_fetch` | See below (`enabled=false` by default) | Web fetch: render dynamic pages in a headless browser and convert to Markdown |
| `plan_mode` | `{enabled=true, auto_execute_on_approve=true, extra_safe_tools={}, mutating_tools=...}` | Plan mode |
| `approval` | See below | Tool approval |
| `sandbox` | See below | Tool execution sandbox (dry-run/commit, isolation backend, policy) |

**approval (tool approval)**:

```lua
approval = {
  mode = "async",              -- async (default: execute immediately in sandbox, confirm apply later) | prompt | auto_allow | strict
  default_auto_allow = false,
  timeout_ms = 60000,          -- Approval dialog timeout (prevents hanging forever)
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

> **Approval decisions** (the pre-execution dialog rule, used only when `mode` is `prompt`/`strict`; the default
> `async` does not take this path — the sandbox risk level `sandbox.approval` decides whether an item is pending review):
> `mode=auto_allow` → no approval; `mode=strict` → always approve;
> a tool with `auto_allow=true` → no approval; a path inside an allowed directory + the command's first word in an
> allowed parameter group → no approval.
> `allowed_directories` is the **global workspace allowlist** (applies to every tool and **includes all of its
> subdirectories**); tool-level and `per_tool` entries are **unioned** with it (append-only, never overriding).
> File tools are judged by path alone (the command allowlist does not apply when there is no command argument),
> so once the workspace directory is configured its subdirectories need no per-file approval.

**sandbox (tool execution sandbox)**:

```lua
sandbox = {
  enabled = true,                  -- Master switch
  fail_closed = true,              -- Reject execution when the sandbox service is missing/disabled (no silent downgrade)
  -- Every child process a tool spawns internally (run_command/git/curl/node/MCP server, ...) is created
  -- inside the sandbox namespace; the tool's own cache/temp dirs are exposed read-write, shared root
  -- stdpath('cache')/NeoAI/shared (same path on host and sandbox).
  mode = "dry_run",                -- dry_run (default, only freezes candidates) | commit (CAS publish after authorization)
  postprocess = "async",           -- Process-command post-processing mode: async (default) = return the result to the main loop as soon as the process exits, while overlay capture/candidate freeze/staging merge/persist/settle run in the background (the FIFO slot is held until the background chain finishes so the next command sees consistent staging; subsequent read/write tools wait for in-flight post-processing); sync = wait for post-processing before returning (deterministic; tests inject this)
  shutdown_timeout_ms = 3000,      -- Max time (ms) to wait for background post-processing and staging migration on exit/close (`:qall`, plugin hot reload); the wait is abandoned on timeout so quitting never hangs; 0 = don't wait (the last unfinished freeze/pending enqueue may be lost)
  backend = "auto",                -- auto | bwrap | unshare
  offline = false,                 -- Network allowed by default (recorded only, not blocked); true hard-denies network and isolates process networking
  require_seccomp = true,          -- Reject external execution when seccomp is unavailable (default on, fail-closed)
  seccomp = { enabled = true, filter_path = "" }, -- seccomp baseline (built-in denylist; default on; bwrap only)
  cap_add = {},                    -- Least privilege by default (`--cap-drop ALL`); capabilities are added back narrowly per command (package installs via packages.cap_add). Set { "ALL" } only for debugging
  -- Payload identity (least privilege): sandboxed processes run as a non-root user by default.
  -- Payload identity: runs as root by default (uid=0) so the AI can use host toolchains inside the
  --   sandbox (/root nvm/cargo/go etc. are 0700 and untraversable by non-root) and package managers
  --   (dpkg hard-checks euid==0). All writes still go to the overlay staging layer and freeze as
  --   candidates; the real disk is unaffected. Isolation comes from namespaces + whole-root overlay
  --   + seccomp + masking.
  --   * NeoAI launched as non-root: a user namespace maps the current user to **guest root inside
  --     the sandbox** (euid=0, effective only within the namespace; host identity stays the current
  --     non-root user); this setting is ignored. Operations that genuinely need host root are frozen
  --     for review and run via `sudo` after approval.
  --   * NeoAI launched as root: uid=0 is the default (no drop); set a dedicated non-root uid (e.g.
  --     nobody 65534) to harden — the plugin runs `setpriv` to drop the payload to that uid, keeping
  --     the configured narrow capabilities as ambient. Then /root is untraversable, so place the
  --     workspace / `workspace_root` where that uid can traverse (not under a 0700 /root).
  run_as = { uid = 0, gid = 0 },
  cap_drop = {                     -- Host-global capability narrowing: dropped even when cap_add contains ALL (network/clock/modules/raw I/O/boot/MAC/audit)
    "CAP_NET_ADMIN", "CAP_SYS_TIME", "CAP_SYS_MODULE", "CAP_SYS_RAWIO",
    "CAP_SYS_BOOT", "CAP_MAC_ADMIN", "CAP_MAC_OVERRIDE", "CAP_AUDIT_CONTROL",
  },
  max_file_bytes = 8 * 1024 * 1024, -- Max bytes per file embedded in a candidate; larger files are copied to a blob (candidate stores only the blob path + stat signature) and published/materialized by file copy, so huge files cannot block the main thread via JSON; 0 = unlimited (embed all)
  work_chunk_files = 128, -- Candidate files per worker task: freeze/hash/secret-scan are chunked and dispatched to the thread pool (multi-core) to avoid single-core serialization on many files; 0/default = 128
  work_parallelism = 4, -- Max chunk jobs submitted concurrently per batch (default 4, matching the libuv pool): prevents hundreds of chunk jobs from flooding the queue and starving UI-critical jobs (redaction/secret tokenization/disk writes); 0/default = 4
  -- Read surface (on by default): when true the whole host root is exposed as a **writable overlay**
  -- (lower `/`, session-private upper/work; mounted as-is, any path under the root is writable). All
  -- writes go to the upper staging layer and freeze as candidates, leaving the host disk untouched;
  -- only the important config files/credentials in `mask_paths` (~/.ssh, ~/.aws, /etc/shadow,
  -- sudoers, docker.sock, ...) plus the sandbox's own storage are masked; `mask_dirs` (home/root
  -- sibling dirs) are no longer mount-masked, but accessing user dirs outside cwd is **traced**
  -- (evidence + `sandbox:outside_access` event) and shown in the `:NeoAISandboxReview` window under
  -- "越界访问留痕" (non-blocking, still allowed). When the overlay is unavailable it falls back to a
  -- read-only root (overlay_fail_closed decides whether to degrade). When false, falls back to the
  -- minimal read-only allowlist below.
  read_all = true,
  -- Minimal read-only system set (allowlist, only when read_all=false): only these host
  -- roots/subtrees/files are exposed read-only to external commands; unlisted paths do not exist
  -- inside the sandbox. `/usr` is not exposed as a whole (avoids leaking /usr/local/go_workspace,
  -- /usr/src, etc.), but `/usr/share` and `/var/lib` are exposed read-only as a whole so run_command
  -- can read runtime shared data (nodejs/dotnet/java/git-core/terminfo, ...) and the host package DB
  -- (dpkg/apt/rpm, ...); dangerous/sensitive subpaths are still masked by mask_paths (e.g.
  -- /var/lib/docker). /lib*, /bin, /sbin are loader symlink roots and must stay. Supports `*` globs;
  -- missing entries are skipped.
  readonly_roots = {
    "/lib", "/lib32", "/lib64", "/libx32", "/bin", "/sbin",
    "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/lib32", "/usr/lib64", "/usr/libx32",
    "/usr/libexec", "/usr/include",
    "/usr/share",                  -- runtime shared data (nodejs/dotnet/java/git-core/terminfo, ...)
    "/usr/local/bin", "/usr/local/sbin", "/usr/local/lib", "/usr/local/libexec", "/usr/local/include", "/usr/local/go",
    "/var/lib",                    -- host package DB (dpkg/apt/rpm, ...); dangerous subpaths still masked
  },
  readonly_paths = { "/etc/ld.so.cache", "/etc/passwd", "/etc/group", "/etc/nsswitch.conf",
    "/etc/hosts", "/etc/ssl", "/etc/alternatives", "/etc/localtime",
    "/etc/os-release", "/etc/terminfo", "/etc/profile", "/etc/security", "/etc/pam.d" },
  expose_paths = {},               -- Host runtime passthrough (opt-in): these host paths are exposed read-only after masking/tmpfs and prepended to the sandbox PATH so run_command can invoke host toolchains (e.g. nvim/lua/luajit/mason). Only expose trusted read-only tool dirs
  expose_path_env = true,          -- Whether to prepend expose_paths dirs to the sandbox PATH (false = mount only)
  expose_tool_paths = false,       -- Auto-expose host PATH tool dirs (opt-in): read-only-expose existing, non-credential/system PATH bin dirs and prepend them to the sandbox PATH so toolchains under $HOME (node/npm/fd/go) work (widens the read surface)
  appimage_extract_and_run = true, -- AppImage support (on by default): when running an AppImage in the sandbox, inject APPIMAGE_EXTRACT_AND_RUN=1 so it extracts into the session-private /tmp (the sandbox blocks mount and exposes no /dev/fuse, so FUSE mounting is unavailable); non-AppImage programs ignore the variable. Set false to disable
  resolv_conf = "sanitize",        -- /etc/resolv.conf: sanitize (default, nameservers only) | hide | passthrough
  tmpfs_roots = { "/tmp", "/var/tmp" }, -- per-session private temporary roots (never an overlay lower; destroyed on exit)
  ephemeral_roots = { "/tmp", "/var/tmp" }, -- ephemeral candidate roots (excluding the cwd subtree): file writes under these roots are session-private, discarded when nvim exits, and produce no pending candidate / no publish / no approval popup; `{}` disables
  tmp_private_base = "host",       -- location of the private temp dir: host (default: hidden subdir under the host root, e.g. /tmp/.cache-<tag>/<session>, namespace-bound back onto the root to isolate the AI) | session (old behavior: under the session process dir)
  hide_proc_paths = { "/proc/cmdline", "/proc/version" }, -- overridden with an empty file; hides host kernel cmdline/version (dangerous global sysctls are mandatory and can only grow)
  mask_paths = {                   -- Mask host-sensitive paths (dirs -> tmpfs; files/sockets -> /dev/null)
    "/run/docker.sock", "/var/run/docker.sock", "/var/lib/docker", "/var/lib/containerd",
    "/root/.config/herdr", "/etc/1panel", "/run/dbus", "/run/systemd",
    "/root/.ssh", "/root/.aws", "/root/.gnupg", "/root/.kube", "/root/.cache/keyring-*",
    -- Git credentials and signing keys (SSH/GPG/credential store/netrc/gh token), incl. non-root homes
    "/root/.git-credentials", "/root/.config/git/credentials", "/root/.git-credential-cache", "/root/.config/gh",
    "/home/*/.ssh", "/home/*/.gnupg", "/home/*/.netrc", "/home/*/.git-credentials",
    "/home/*/.config/git/credentials", "/home/*/.config/gh", "/home/*/.docker/config.json",
    "/etc/shadow", "/etc/gshadow", "/etc/sudoers", "/etc/machine-id", "/etc/ssh",
    "/var/log", "/var/spool/cron", "/etc/crontab",
    "/root/.bash_history", "/root/.zsh_history", "/root/.python_history", "/root/.wget-hsts",
  },
  -- Masked directories (on by default): the user home containing cwd is exposed read-only and its
  -- other entries masked; hits request approval.
  mask_dirs_enabled = true,        -- master switch
  mask_dirs = { "/home", "/root" }, -- masked dirs (supports * globs)
  mask_dirs_approval = true,       -- request approval on masked hits (reuses tool approval UI)
  -- Kernel-level behavior observation (eBPF/strace/procfs): decides "outside-workspace access" and
  -- "secret-file access" from actual syscalls, replacing/augmenting command-string heuristics;
  -- events are attributed precisely to the attempt cgroup.
  -- Backend priority auto: ebpf (bpftrace, needs root) -> strace (command prefix) -> procfs
  -- (/proc/<pid>/fd). When none is available it falls back to command parsing; tools still run.
  observe = {
    enabled = true,   -- master switch (off = command-string heuristic only)
    backend = "auto", -- "auto" | "ebpf" | "strace" | "procfs" | "heuristic"
    poll_ms = 200,    -- procfs/strace poll interval (ms)
    notify = true,    -- at startup: notify when eBPF is unavailable/not installed, or strace fallback is missing
    -- Probe attach wait (ms): 0 (default) = do not block the command; bpftrace attaches
    -- asynchronously (best-effort — early accesses may be missed and fall back to command
    -- heuristics), avoiding a fixed ~0.5s wait per command. A positive value waits bounded
    -- before running the command: fuller observation at a fixed per-command cost.
    wait_ready_ms = 0,
    -- Observation prewarm (on by default): after a process command returns, in the gap while the
    -- AI generates the next turn, pre-create the next attempt's cgroup and attach the eBPF probe
    -- in the background, overlapping the ~0.5s attach with AI output; the next process command
    -- reuses the already-attached probe. eBPF backend only (strace/procfs start cheaply).
    prewarm = true,
    prewarm_ttl_ms = 90000, -- prewarm TTL (ms): reclaimed if not reused within it
  },
  -- Diagnostics (off by default): enable when investigating 137 / OOM / resource-domain kills.
  -- Records to the NeoAI log only; never changes execution or model-visible results. Pair with
  -- `:NeoAISandboxDiag` to inspect host/container limits and load.
  diagnostics = {
    enabled = false,          -- master switch
    log_kill_caller = false,  -- cgroup.kill caller traceback (who killed the process tree)
    dump_cgroup_events = false, -- dump resource-domain memory/pids events at command end (OOM attribution)
  },
  -- Long-lived services (service_* tools): background processes survive across tool calls until
  -- explicitly stopped / session end. Each service uses its own overlay attempt: at start the
  -- workspace staging is materialized into the service view (one-way snapshot); at stop its changes
  -- are captured and merged back into workspace staging (boundary sync, not live sharing) and queued
  -- for async review. A resource domain is created per service; stop first sends SIGTERM to the
  -- payload and waits for a graceful exit, then cgroup.kill terminates the whole tree on timeout.
  service = {
    enabled = true,          -- register the service_* tools
    max_services = 16,       -- max concurrently alive services
    max_log_bytes = 262144,  -- per-service log ring-buffer cap (bytes)
    stop_timeout_ms = 5000,  -- max wait for graceful exit (SIGTERM first) before SIGKILL
    auto_background = true,  -- promote run_command &/nohup/setsid to a long-lived service (survives calls)
  },
  -- systemctl facade (option A): standalone `systemctl`/`journalctl` calls from the AI are routed
  -- to in-sandbox long-lived services (reusing sandbox.service); the host systemd is never called
  -- and the host is never modified. Supports simple/exec/oneshot and Requires/Wants/After/Before
  -- dependencies; Type=notify/forking/dbus and socket/timer units fail explicitly; verbs the facade
  -- does not handle fall back to the existing T2/hostop proposal path.
  systemd = {
    enabled = true,          -- master switch
    mode = "facade",         -- facade (default): handled inside the sandbox
    max_deps = 32,           -- per-call dependency-closure cap (guards against cycles/huge graphs)
    unit_roots = {           -- unit-file search dirs (sandbox staging copy first, then real file)
      "/etc/systemd/system", "/run/systemd/system",
      "/usr/lib/systemd/system", "/lib/systemd/system",
    },
  },
  network = {
    enabled = false, allowed_endpoints = {}, budget_bytes = 0, -- controlled network gateway
    -- Intercept access to the host itself (loopback/host NIC IPs/link-local/cloud metadata; on by
    -- default): injects HTTP(S)_PROXY/ALL_PROXY pointing at the host-side Lua filtering proxy —
    -- host-local targets are blocked, external targets allowed and recorded. Application-layer
    -- boundary: raw TCP that ignores the proxy can bypass it (see docs/en/sandbox.md §6.1).
    host_local_block = true,
    host_local_proxy_port = 0,       -- host filtering proxy port (0 = random loopback port)
    -- Proxy policy for sandbox external commands: strip (default: do not pass host proxies into the
    -- sandbox; e.g. mihomo only proxies opencode itself, avoiding an unreachable host
    -- HTTPS_PROXY=127.0.0.1:7890 breaking pip/npm) | passthrough (keep host proxies) |
    -- table { http, https, all, no_proxy } (explicit; unlisted proxy vars are cleared).
    -- Note: when host_local_block is on, the injected filtering-proxy vars take precedence over strip.
    proxy = "strip",
    -- Isolated netns + host gateway (opt-in): the sandbox process enters a private network
    -- namespace and can only reach the host gateway; the gateway first runs a TCP connect probe on
    -- the target host:port (so host listening ports are discoverable), but never relays real service
    -- data — it returns the interception reason (JSON) to the client. Only host-local addresses may
    -- be probed. Requires root and `ip`.
    gateway = { enabled = false, probe_timeout_ms = 1000, max_probes = 4096 },
    -- CN/restricted-network mirrors (empty = inherit system behavior); sandbox external commands only,
    -- injected via environment variables:
    --   pip   -> PIP_INDEX_URL + PIP_TRUSTED_HOST (e.g. "https://pypi.tuna.tsinghua.edu.cn/simple")
    --   npm   -> npm_config_registry (e.g. "https://registry.npmmirror.com/")
    --   maven -> generates settings.xml (mirror all repositories), pointed to via MAVEN_OPTS -s
    mirrors = { pip = "", npm = "", maven = "" },
  },
  -- Privilege tiers and auto-escalation: commands run at T0 least privilege by default
  -- (network allowed by default with host-local access intercepted); escalation is auto-requested
  -- at ALL tiers (T0→T1→T2 up to max_tier) and re-run in isolation, logging evidence/events/audit.
  privilege = {
    enabled = true, auto_escalate = true, max_tier = 2, record = true,
    tiers = {                       -- per-tier network/extra caps/mounts/unmask/review strictness
      [0] = { name = "minimal", review = "auto", network = true, cap_add = {}, mounts = {}, unmask = {} }, -- least privilege: non-root payload, cap-drop ALL. network allowed (recorded); host-local intercepted via host_proxy
      [1] = { name = "elevated", review = "auto", network = true, cap_add = {}, mounts = {}, unmask = {} }, -- docker.sock is unmasked only for docker commands
      [2] = { name = "privileged", review = "approve", network = true, userns = true, cap_add = { "ALL" }, mounts = {}, unmask = {} }, -- full caps inside the nested userns (scoped); seccomp still applies
    },
    -- System-administration commands (useradd/chown/passwd, ...): on a match, narrowly add back
    -- capabilities and lift account-database masking so `useradd`/`usermod`/`groupadd`/`chown`/
    -- `passwd` work in the sandbox (under least privilege they fail for lack of
    -- CHOWN/SETUID/SETGID/DAC_OVERRIDE and because the account DB is masked). Writes still go to
    -- the overlay stage, so the real account DB/filesystem is untouched; ordinary commands keep
    -- least privilege and the account DB stays masked (no password-hash exposure).
    sysadmin = {
      cap_add = { "CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_DAC_READ_SEARCH", "CAP_FOWNER", "CAP_SETUID", "CAP_SETGID", "CAP_SETFCAP", "CAP_FSETID", "CAP_SYS_CHROOT", "CAP_KILL" },
      unmask = { "/etc/passwd", "/etc/group", "/etc/shadow", "/etc/shadow-", "/etc/gshadow", "/etc/gshadow-", "/etc/subuid", "/etc/subgid", "/etc/subuid-", "/etc/subgid-" },
    },
    classify = {                    -- command classification (bins = exact binary; bin+subs = binary + subcommand)
      { tier = 2, name = "privileged", bins = { "sudo", "mount", "modprobe", "iptables", "systemctl", "unshare", "nsenter" } },
      { tier = 1, name = "docker", bins = { "docker", "docker-compose", "nerdctl" } }, -- daemon-backed: controlled socket
      { tier = 1, name = "container", bins = { "podman", "podman-compose", "buildah", "skopeo" } }, -- daemonless: can share the sandbox namespace
      { tier = 1, name = "network", bins = { "curl", "wget", "ssh", "rsync", "ping", "socat" } },
      { tier = 1, name = "network", bin = "git", subs = { "push", "pull", "fetch", "clone" } },
      { tier = 1, name = "sysadmin", bins = { "useradd", "usermod", "userdel", "adduser", "deluser", "groupadd", "groupmod", "groupdel", "addgroup", "delgroup", "passwd", "chpasswd", "chage", "chfn", "chsh", "chown", "chgrp", "setfacl" } }, -- system administration: narrow caps + account-DB unmask
      { tier = 1, name = "package", bins = { "apt", "apt-get", "dnf", "yum", "pacman", "apk", "brew" } }, -- package install: extra rules
    },
  },
  -- Container facade: docker/nerdctl need a host daemon, so the default is off (explicitly reported as
  -- "unsupported in the sandbox", never touching the host). Set to controlled with a socket (rootless /
  -- socket-proxy / dind) to allow a controlled socket explicitly.
  docker = { mode = "off", socket = "" }, -- off | controlled
  -- Container facade: daemonless runtimes (podman/buildah) get --net/pid/ipc/uts=host to share the
  -- sandbox namespace and run containers inside the sandbox; docker/docker-compose are rewritten to
  -- podman/podman-compose inside the sandbox by default (docker_to_podman=false rejects them); nerdctl
  -- is rejected by default.
  container = { enabled = true, share_namespace = true, prefer = "podman", docker_to_podman = true },
  -- Store base root: each process is isolated under <workspace_root>/instances/<pid>_<ts>; pending queue/candidates are not shared across sessions.
  workspace_root = vim.fn.stdpath("cache") .. "/NeoAI/sandbox",
  -- Sandbox staging backend (process overlay upper/work, per-session private /tmp, LSP overlay, ...):
  --   "disk" (default) = a hidden featureless dir on disk (prefers /var/tmp, falls back to the nvim cache dir);
  --   "shm" = /dev/shm (RAM, faster but memory-hungry); an absolute path = use that dir as the base.
  staging_backend = "disk",
  session_shell = true,            -- persist shell state (export/cd) across run_command within a session (bwrap only)
  process_roots = {},              -- extra writable roots (only when read_all=false or the whole-root overlay is unavailable; overlaid, default cwd only, auto-added). With read_all=true (default) the whole root is already a writable overlay, so this is unnecessary. /tmp, /var/tmp belong to tmpfs_roots; add explicitly if needed
  overlay_fail_closed = true,      -- reject process tools when overlay is unavailable (no private-cwd downgrade); set false to allow degraded execution
  -- Async review: candidates enter a pending queue. session_auto_approve auto-applies L0/L1.
  -- l3_warning: high-risk items require second confirmation (AI consequence warning + auto diff; apply only after re-confirming).
  --   L3 (critical) always triggers; with package_confirm=true, L2 package/sensitive installs (apt-key,
  --   gpg --import, repo changes, etc.) also trigger; safe installs (L1) still need one confirmation.
  --   The confirm window title is level-aware and the key hint is highlighted; dropped masked/volatile
  --   files are reported in the warning block as "N will be skipped".
  -- ai_audit: press `a` (configurable key) in the review UI to hand the user messages + structured
  --           text of risk-graded pending changes to the model, which returns a ≤50-char note for
  --           **every** item (file / host command) starting with a safe/unsafe verdict (rendered
  --           under the line; high-risk changes come first and are never omitted; items the model
  --           misses are marked "needs manual confirmation"; the top shows an overall verdict; never
  --           posted to chat). auto=true runs the audit automatically when the review UI opens
  --           (default off; re-audits when the pending set changes). Global concurrency cap
  --           max_concurrent (default 10; excess in-flight requests queue FIFO) avoids a request
  --           storm when auto fires frequently.
  review = { enabled = true, auto_apply = false, session_auto_approve = false,
             l3_warning = { enabled = true, package_confirm = true, max_tokens = 256, timeout_ms = 15000 },
             ai_audit = { enabled = true, auto = false, key = "a", max_concurrent = 10,
                          max_diff_chars = 8000, max_user_chars = 4000, max_total_chars = 60000,
                          max_tokens = 2048, timeout_ms = 30000 } },
  -- Approval graded by security level (L0-L3): action auto/record/review/block; default "review".
  approval = { default = "review", levels = {} },
  -- Risk grading (sandbox/risk.lua): when grading a command result, only the first/last
  -- result_scan_bytes bytes of stdout/stderr are scanned, so large outputs from `timeout=-1`
  -- commands (hundreds of MB) cannot freeze the UI with a full main-thread lowercase + pattern
  -- scan; 0 = unlimited.
  risk = { result_scan_bytes = 262144 },
  -- Static scan of indirect script execution: when a command delegates to a script/interpreter
  -- (`bash deploy.sh`, `python setup.py`, `node x.js`, `./run.sh`, `bash -c '…'`), the script is
  -- read before execution (preferring the sandbox staging copy) and its shell body plus embedded
  -- shell calls in high-level languages (Python/Node/Ruby/Perl/PHP) are folded into danger
  -- detection and privilege classification: destructive/kernel commands inside scripts are hard
  -- denied; other hits, or opaque cases (eval, base64|sh, dynamic `-c "$VAR"`, unreadable content),
  -- raise the level and force review (never auto-applied). max_* bound recursion/reads.
  script_scan = { enabled = true, max_depth = 3, max_files = 8, max_bytes = 262144 },
  -- Extra rules for package installs: review (default, forced review, not auto-approved) | allow | deny.
  -- `managers` also identifies the package manager: install candidates are grouped per install
  -- command into one approval unit (approve the whole package from the header line).
  -- Detection skips wrappers (sudo/doas/env/bash -c/for…do) so an install is not missed and
  -- escalated to L3.
  -- `roots` = package-install writable overlay staging roots so apt/pip/npm can write
  -- indexes/caches/metadata and install targets (`/usr` covers /usr/bin, /usr/games, …;
  -- `/var` covers dpkg/apt state, man caches, …); writes freeze as candidates and the real disk
  -- is unchanged. `cap_add` = narrow capabilities added back for package installs when the global
  -- cap_add is narrowed (e.g. {}); granted only when the whole command is package managers; no
  -- CAP_MKNOD — device nodes are hard-blocked by the seccomp baseline, FIFOs unaffected.
  packages = {
    mode = "review", -- review (safe installs need confirmation but cap at moderate L1; sensitive installs touching repos/keys stay L2) | allow | deny
    managers = { "apt", "apt-get", "pip", "pip3", "uv", "conda", "npm", "npx", "pnpm", "yarn", "go", "cargo", "gem", "composer" }, -- package-manager names (command recognition); path signatures via privilege.package_path_manager; sensitive-install detection via privilege.package_sensitive
    roots = { "/usr", "/var", "/etc", "~/.cache", "~/.npm", "~/.nvm", "~/.cargo", "~/.rustup", "~/go", "~/.local" }, -- package-install writable roots (overlay staging). /etc lets dpkg postinst write /etc/ld.so.cache etc.; sensitive entries stay masked by mask_paths
    volatile_paths = { "/var/lib/apt/lists", "/var/cache/apt", "/var/cache/dnf", "/var/cache/yum", "/var/cache/pacman/pkg", "/var/cache/apk", "~/.cache/pip", "~/.cache/uv", "~/.npm/_cacache", "~/.cache/yarn", "~/.cargo/registry/cache", "~/.cache/go-build" }, -- volatile package indexes/caches: skipped when freezing a candidate (not queued, not published) so an apt-update baseline change cannot fail the whole install with BASELINE_CHANGED; the install is unaffected (dpkg/status, package files still apply); {} disables. Do not add state files like /var/lib/dpkg/status
    cap_add = { "CAP_DAC_OVERRIDE", "CAP_CHOWN", "CAP_SETUID", "CAP_SETGID", "CAP_FOWNER" },
    apt_sandbox_user = "root", -- apt family: injects APT::Sandbox::User (default "root" disables apt's own `_apt` privilege drop, avoiding setgroups EPERM in nested userns/restricted containers that makes apt update/install fail); "_apt" or empty keeps apt defaults
  },
  lsp_overlay = { enabled = true }, -- AI-only sandboxed LSP: servers cloned by the AI lsp_* tools read staged content (on by default, bwrap+overlay only; falls back to editor clients when unavailable)
  secrets = { enabled = true, min_length = 20, max_length = 200, min_entropy = 3.5, min_distinct = 8, exclude_pure_hex = true, entropy_requires_context = true, entropy_secret_paths_only = true, generated_scan_max_bytes = 2097152, generated_scan_max_files = 200, tokenize_env = true, extra_rules = {}, allowlist = {} }, -- Secret/sensitive guard: entropy + named rules (private-key blocks/AKIA/ghp_/sk-/JWT/Bearer…) + token mapping; env values whose names contain KEY/TOKEN/SECRET/PASSWORD/CREDENTIAL are force-tokenized; bare entropy runs require a -/_ separator and must not be a code identifier (snake_case function/constant names) or a sensitive-name context (narrowed scope to avoid corrupting integrity/build hashes/traceback function names/path components); non-sensitive-named env values containing / are redacted by named rules only (never breaking PATH/LD_LIBRARY_PATH); with entropy_secret_paths_only=true the full-text entropy scan runs only on suspected secret files (~/.ssh, ~/.bashrc, /etc/*, etc. per secret.is_secret_path), other files use named rules only; generated_scan_max_bytes/generated_scan_max_files bound the AI-generated high-entropy detection (detect_generated) scan budget so large candidates do not stall the main thread file-by-file (0 = unlimited)
  retention = { candidate_days = 7, max_pending = 20 },
  policy = {
    version = "1",                 -- policy version (for audit replay; bump when rules change)
    deny_tools = {},               -- Hard-denied tool names (cannot be overridden by confirmation)
    rules = {},                    -- Restricted Lua rule functions returning { decision, reason_codes }
  },
  -- Resource limits (cgroup v2): dynamic=true by default, deriving CPU/memory/PID caps from host
  -- resources so a sandboxed command cannot starve the machine; explicit static values (>0) win.
  -- All concurrent attempts share a parent domain: cpu_global_max is the total concurrent CPU
  -- budget (default nproc-1), cpu_cores_max is the per-task quota.
  -- With fail_closed=false, an unavailable cgroup is skipped rather than blocking execution.
  -- disk_bytes: sandbox staging disk cap (bytes; 0 = unlimited). It totals the staging base
  -- (process overlay/private tmp) plus the sandbox store root (candidates/review/evidence/service
  -- overlay); when exceeded, write/process tools are rejected (usage is measured async and cached,
  -- never blocking command start).
  limits = { wall_ms = 60000, dynamic = true, memory_ratio = 0.5, memory_max_bytes = 0,
    cpu_cores_max = 4, cpu_global_max = 0, pids_max = 2048, memory_bytes = 0, pids = 0, cpu_max = 0,
    cpu_affinity = "auto", -- sandbox CPU affinity: auto=pins to cores other than nvim's current CPU (so it does not compete with nvim); off/false=no pinning; "2,3"/"2-3"=explicit cpuset (needs taskset)
    cgroup_base = "/sys/fs/cgroup", fail_closed = false,
    disk_bytes = 64 * 1024 * 1024 * 1024 }, -- 64 GiB (0 = unlimited)
  seccomp_filter_path = "",        -- optional: compiled seccomp BPF filter (with require_seccomp)
}
```

> Every tool call goes through the control plane: preflight → isolated execution → freeze candidate →
> CAS publish. The default `dry_run` does not write the real workspace; candidates enter an async
> review queue — use `:NeoAISandboxReview` to view/apply, or
> `:NeoAISandboxApprove/Reject/Apply <change_set_id>`; `:NeoAISandboxList/Show/Discard/Caps` manage
> candidates and inspect runtime capabilities. Rules run in a restricted environment with
> instruction/wall-clock budgets; rule errors produce `DENY`. See [sandbox.md](sandbox.md).

**web_fetch (web fetch, disabled by default)**:

```lua
web_fetch = {
  enabled = false,                 -- Master switch (off by default; only then is the tool registered / deps installed / fetching allowed)
  auto_install = true,             -- After enabling, install deps in the background; false installs on first call
  engine = "chromium",             -- Browser engine: chromium | firefox | webkit
  format = "markdown",             -- Default output format: markdown | text (body only, no raw HTML)
  timeout_ms = 45000,              -- Total fetch timeout (ms, incl. browser startup); <=0 uses nav_timeout_ms + 15s
  nav_timeout_ms = 30000,          -- Page navigation/wait timeout (ms)
  max_bytes = 2 * 1024 * 1024,     -- Max content returned per call (bytes, truncated beyond)
  install_timeout_ms = 600000,     -- Dependency install timeout (ms; first browser download can take a while)
  node_path = "",                  -- Custom node binary path (empty = node from PATH)
  install_os_deps = false,         -- Also install OS deps for the browser (needs root/sudo; rarely necessary)
  -- Download/proxy control for restricted networks (CN mirrors / broken proxy); all empty = inherit system behavior
  npm_registry = "",               -- npm registry; empty = system npm config. CN: "https://registry.npmmirror.com/"
  playwright_download_host = "",   -- Browser download base URL; empty = official CDN. CN: "https://registry.npmmirror.com/-/binary/playwright"
  http_proxy = "",                 -- Explicit HTTP proxy for install/render; empty = do not override inherited value
  https_proxy = "",                -- Explicit HTTPS proxy for install/render; empty = do not override inherited value
  ignore_system_proxy = false,     -- true = clear inherited proxy vars during install/render (for a broken local proxy)
  -- Injection script dir (extend/override built-ins; same-named user scripts win)
  -- Built-ins: clean (generic denoise), readability (article extraction)
  scripts_dir = vim.fn.stdpath("config") .. "/NeoAI/web_fetch/scripts",
  cache = {
    enabled = true,                -- Result cache switch
    ttl_sec = 3600,                -- Cache TTL (seconds); <=0 means no expiry
    max_entries = 200,             -- Max number of cached entries
    max_bytes = 500 * 1024 * 1024, -- Max total cache size (bytes, default 500MB; evicts oldest first)
  },
},
```

> **Runtime behavior**: while disabled there are zero side effects (no tool registration, no dependency install);
> once enabled, deps are installed into the cache dir (`stdpath('cache')/NeoAI/web_fetch`) and browsers are kept in the
> same dir's `browsers/` — **the system environment is never modified**. **Dependency/browser installation runs on the
> host, outside the sandbox**: the install artifacts (`node_modules`, a browser engine that can be hundreds of MB) would
> otherwise enter the sandbox overlay and be re-captured by every `run_command`; rendering still runs inside the sandbox
> (browsers are read-only visible from the host). If `node`/`npm` is missing it does not invoke a
> system package manager, but returns an actionable error. `approval.per_tool.web_fetch = { auto_allow = true }` (auto-allowed
> by default). Pipeline: Lua orchestrates → bash installs deps → Node/Playwright renders and injects JS → final DOM →
> turndown converts to Markdown.

### 2.6 `herder`

```lua
herder = {
  enabled = true,          -- Whether to enable reporting (also requires HERDR_ENV=1 to take effect)
  source = "custom:neoai", -- Stable and globally unique lifecycle authority identifier
  agent = "neoai",         -- Agent name (used for identification on the Herder side)
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
  servers = { /* see docs/mcp.md */ },
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
  builtin = true,                 -- false = register no builtin plugins
  disabled = { "ui", "services.mcp" }, -- disabled plugin/service ids (incl. dependency closure)
  entries = {
    ["tool.shell"] = false,        -- disable a plugin
    ["services.model_service"] = { module = "my_model_provider" }, -- replace implementation
  },
}
```

- Disabled plugins and their downstream dependents are removed together; `entries[id] = false` disables.
- `entries[id] = { module = "..." }` replaces a service/tool implementation (must be `require`-able with the same interface).
- See [plugins.md](plugins.md) for the plugin protocol, cleanup, replacement and testing requirements.

## 3. Plan Mode (tools/plan_mode)

Plan mode is a **per-agent state** (`agent.plan_mode`); when active:

1. **Injects the plan-policy system prompt section** (`deployment:plan_policy`, order=100): requires a clear, formatted modification plan as output.
2. **Keeps only read-only/informational tools in the tool context, plus `run_command` (read-only research) + `ask_user`** (the `PLAN_SAFE_TOOLS` allowlist + `PLAN_EXTRA_TOOLS`), exposing no mutating tools and **no mode-switching tool to the AI**.
3. **Tightens the execution-time gate accordingly** (`plan_mode.check_tool`): in plan mode, any tool outside the visible set is rejected.

**Plan confirmation**: after the AI emits the plan the turn ends; the user confirms by running `:NeoAIApprovePlan` (or toggling the mode manually);
`chat_service.approve_plan` then parses the plan into a task list (todo) → exits plan mode (switching to CHAT)
→ automatically starts execution according to `auto_execute_on_approve` (enabled by default).

The state is persisted in `session.metadata.plan` and restored when the session is resumed (`plan_mode.restore`).

## 4. Related Documentation

- [README configuration section](../../README.en.md): full configuration example.
- [tool_system.md](tool_system.md): runtime behavior of the `tools.*` tool/approval configuration.
- [ai_engine.md](ai_engine.md): engine-side behavior of `ai.context_cache` / `ai.reasoning_enabled`.
- [model_policy.md](model_policy.md): automatic per-model selection (protocol dialect / capability table / explicit cache).
- [plugins.md](plugins.md): plugin system, service locator and default composition.
