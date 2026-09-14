# NeoAI Tool Execution Sandbox (dry-run & commit)

> **English** | [中文](../sandbox.md)

> Implements the *Agent Sandbox dry-run & commit Architecture v2.1* design.
> Source: `lua/NeoAI/sandbox/*`, `lua/NeoAI/tools/executor.lua`,
> `lua/NeoAI/tools/registry.lua`, `lua/NeoAI/plugins/catalog.lua`.

## 1. Goal

Put every tool execution behind a controlled execution boundary:
preflight → isolated execution → freeze candidate → validate/authorize →
CAS publish → post-verify. No tool may bypass the sandbox and touch the real workspace.

Invariants:

1. dry-run is not a security boundary; all execution runs in the controlled runtime.
2. Isolated execution only mutates discardable private state.
3. `commit` publishes a frozen, validated, authorized candidate; it never re-runs the command.
4. Hard denies cannot be overridden by human confirmation; unknown outcomes are not success.
5. When the sandbox service is missing and `fail_closed=true`, execution is **rejected**
   rather than silently downgraded.

## 2. Modules

| Module | Responsibility |
| --- | --- |
| `sandbox/init.lua` | Control-plane facade: `init/probe/gate/attach/commit/discard/list/show` |
| `sandbox/control.lua` | IDs/digests, state machine, idempotency keys, leases, fencing tokens |
| `sandbox/policy.lua` | Rule evaluation/aggregation (`DENY > NEEDS_CONFIRMATION > ALLOW`) and a restricted Lua rule sandbox |
| `sandbox/runtime.lua` | External backend probe and process prefix (bwrap preferred, unshare fallback) |
| `sandbox/candidate.lua` | Private staging, candidate freeze, CAS publish |
| `sandbox/store.lua` | Candidate/receipt persistence (queryable reconciliation) |
| `sandbox/review.lua` | Async review: change-set queue and review/apply states |
| `sandbox/impact.lua` | fs/process/network impact records and compact stats (unknown = null) |
| `sandbox/evidence.lua` | Evidence storage, redaction, paging |
| `sandbox/grant.lua` | Narrow task grants (scope/operations/budget/ttl/revocation) |
| `sandbox/envelope.lua` | Decision envelope (decision/severity/stats/asks/evidence) |
| `sandbox/network.lua` | Controlled network gateway (allowed by default; declared endpoints when enabled) |
| `sandbox/broker.lua` | External-operation adapter protocol (idempotency/query/compensation capability declarations and reconcile) |
| `sandbox/replay.lua` | Policy replay (reproduce a decision from the same rules and facts) |
| `sandbox/cgroup.lua` | cgroup v2 resource domain (memory/PID/CPU), one per attempt |
| `sandbox/seccomp.lua` | seccomp capability probe and require_seccomp gate |
| `sandbox/cache.lua` | Content-addressed cache (isolated writes, prunable) |
| `sandbox/fault.lua` | Fault injection (backend/freeze/publish/store) for recovery-path verification |
| `sandbox/bench.lua` | Control-plane critical-path performance benchmarks |
| `sandbox/tool_spec.lua` | Per-tool effect class and staged path declaration |
| `sandbox/wrapper.lua` | Enforcement gate: `attach` specs, `gate` all executions |

## 3. Enforcement points (loader + executor)

- `plugins/catalog.lua` `_tool_spec` depends on `services.sandbox` and passes it to
  `tools.load_module(mod_name, { sandbox = ... })`.
- `tools/init.lua` `load_module` calls `sandbox.attach(tool)` before registering.
- `tools/registry.lua` `register/update` attach specs uniformly, covering MCP tools
  registered dynamically without the loader.
- `tools/executor.lua` calls `services.use("services.sandbox").gate(...)` before the
  real call; missing service + `fail_closed` rejects. This is the final gate for all paths.

`attach` writes `__sandboxed = true` and `__sandbox_spec = { effect, paths }`.

## 4. Effect classes

| effect | Meaning | Handling |
| --- | --- | --- |
| `read` | Read-only (read/list/search/lsp/tree/git reads) | In-process, read-only receipt |
| `in_process` | In-process state changes (todo/plan/ask_user/skills) | In-process, receipt |
| `fs_write` | Host filesystem writes | Write to private staging, freeze candidate |
| `process` | External process (run_command, etc.) | Isolated via `runtime.process_prefix` |
| `network` | Network side effects (web_fetch/read_image) | Allowed by default and recorded (not blocked); only `offline=true` denies |

Unknown tools fall back to category defaults; still unknown is treated conservatively as `process`.

## 5. Async review, dry-run and commit

The default is **asynchronous review** (`tools.approval.mode = "async"`, design §15): AI tool
calls **execute immediately inside the sandbox and freeze a candidate** without blocking on the
user; real workspace modifications enter a review queue, and the user asynchronously confirms
which files/config changes to allow before CAS apply. The legacy blocking pre-execution approval
is only kept for other `approval.mode` values (`prompt`/`strict`).

- Each effectful candidate produces a **change set** with `change_set_id`, `write_set`,
  `review_state` (`PENDING`/`APPROVED`/`REJECTED`) and `apply_state`
  (`NOT_REQUESTED`/`APPLYING`/`APPLIED`/`CONFLICT`/`FAILED`).
- `tools.sandbox.mode = "dry_run"` (default): enqueue for review, never write the real workspace.
- `tools.sandbox.mode = "commit"`: CAS publish immediately within a task grant.
- **Model visibility**: the tool result is returned to the model **unchanged**, with no
  "staged/awaiting review" note, so the AI believes the change completed. Pending state is
  surfaced to the user only via a **prominent statusline badge** (the `sandbox` part shows a
  bold yellow `待审N` only when pending reviews > 0, see [configuration.md](configuration.md)).
- Async confirmation commands:
  - `:NeoAISandboxReview` — open the review UI (`ui/components/sandbox_review.lua`), which
    highlights files by path level — **workspace=green, user directory=yellow, system=red** —
    with a yellow `待审` state label. **The approval unit is a single file**: `<CR>` applies only
    the file under the cursor, `d` rejects only that file (remaining files stay pending),
    `r` refreshes, `q`/`<Esc>` closes; the header line is informational only and is not
    approvable. Inside the chat main window press `<leader>ap` to trigger it
    (`keymaps.chat.sandbox_review`).
  - `:NeoAISandboxApprove <id>` / `:NeoAISandboxReject <id>` — approve (no apply) / reject & discard.
  - `:NeoAISandboxApply <id>` — approve and apply (CAS publish); `:NeoAISandboxApplyAll` applies all.
  - `:NeoAISandboxList` / `:NeoAISandboxShow` / `:NeoAISandboxDiscard <digest>` / `:NeoAISandboxCommit <digest>`.
    Discarding a candidate also marks any `PENDING` change sets referencing it as `REJECTED`
    (`review.discard_by_digest`); otherwise reopening the chat/review UI would show a stale
    pending item whose candidate no longer exists and cannot be applied.
- Selective apply: `sandbox.apply(id, { files = { ... } })` applies only a subset of files
  (re-freezing the composed candidate before CAS); unselected files remain queued as a new
  pending change set so the user can confirm them one by one. `sandbox.reject_file(id, path)`
  rejects a single file.
- **Same-file supersede**: when the same file is edited again (a new candidate is enqueued) or
  published directly, older `PENDING` change sets covering that path are marked `SUPERSEDED` and
  their candidates discarded, so the queue keeps only the latest version
  (`review.supersede_by_paths`).

### Staging

- **Explicit-path tools** (`edit_file`/`create_directory`/`ensure_dir`/`delete_file`): the
  gate rewrites path args to a private copy under `<root>/workspace/<hash>`. The workspace keeps a
  **persistent mapping** (real path → staged copy):
  - Editing the same file repeatedly always starts from the latest sandbox content (not a fresh copy
    of the real file), so successive edits compose; the copy is refreshed only when the real file
    changes externally (hash mismatch).
  - Staged paths in tool results are **rewritten back to the real paths**, so the model only sees
    real workspace paths.
  - Applying or rejecting a candidate invalidates its staged copy, so later edits re-baseline on the
    real file.
- **Read-tool consistency**: when a workspace staged copy exists,
  - `read_file`/`file_exists` read the staged copy (deleted files are unreadable / return false), so
    the AI sees its own unpublished changes; staged paths in the returned content are **rewritten
    back to the real paths**, keeping the sandbox invisible to the AI.
  - `list_files`/`search_files` overlay the staged view: unpublished new/modified files are visible,
    deleted files are hidden, and results always use real paths (directories are not wholesale
    mapped, to avoid losing real files). Entire directory trees created inside the sandbox
    (`run_command`/`create_directory`, not yet on real disk) are synthesized as well: `list_files`
    fills in parent-directory entries and `file_exists` returns true for ancestor directories, so
    the AI never sees the inconsistent "files created but directory missing" view that would tempt
    it to bypass the sandbox.
  - Treesitter tools (`parse_file`/`query_tree`/`get_node_*`) read the staged copy: staged paths
    **keep the real basename (and extension)**, so filetype/parsers work; write tools such as
    `delete_node` modify the same staged copy and persist back to it (no double staging).
  - LSP tools read real content by default; with `tools.sandbox.lsp_overlay.enabled = true` the LSP
    server process is placed in a bwrap + overlay (see below), so its disk reads see staged content.
    LSP write tools (`lsp_rename`/`lsp_format`) always redirect their disk write to staging via
    `persist_buffer`.
- **Buffer-persist tools** (`delete_node`/`lsp_rename`/`lsp_format`): `tool_helpers.persist_buffer`
  redirects `:write!` to staging while the sandbox is active.
- **External processes** (`run_command`): with the bwrap backend, a set of **writable roots**
  (`tools.sandbox.process_roots`; default is only cwd, auto-added if not covered) are overlaid: the
  real root is the read-only lower, a session upper is the writable layer. The command can read real
  content under these roots, and creates/modifies/deletes at **any path** below them land in upper and
  are frozen as a candidate (deletions recognized via whiteout device nodes as `delete`/`rmdir`).
  - `/tmp` and `/var/tmp` are **per-session private temporary roots** (`tools.sandbox.tmpfs_roots`):
    bound to a session-private directory (mode 1777, on a tmpfs such as `/dev/shm`), **never** used as
    an overlay read-only lower, and destroyed on exit/session rotation. Writes to `/tmp` are scratch
    and are not frozen as candidates, eliminating cross-session residue and host `/tmp` leakage.
  - Broad directories such as `/root`, `/home`, `/etc` are no longer overlaid by default, so host
    home/accounts/config are not exposed as read-only lowers; add them back explicitly to
    `process_roots` if needed, and tighten `mask_paths` accordingly.
  - The writable layer is **session-shared**: all commands in the same agent loop share it (command N
    sees command N-1's writes); on agentEnd the session rotates and it is cleaned with the session
    directory (changes already frozen as candidates).
  - **Bidirectional**: before a command the workspace staged content is materialized into the writable
    layer (the command sees `edit_file`'s unpublished edits and new files; deletions are represented as
    whiteouts); after it the changes are merged back into the workspace staging map (`read_file`/
    `edit_file` see the command's changes and keep composing).
  - The overlay base is generated by `sandbox.conceal` with a **featureless name**
    (`/dev/shm/.cache-<tag>`, no `NeoAI`/`sandbox` substring; must be outside the writable roots,
    otherwise upper-under-lower yields kernel `EINVAL`); falls back to the sandbox root when
    `/dev/shm` is absent.
  - **The sandbox's own store is hidden from commands**: the sandbox root
    (`tools.sandbox.workspace_root`, default `stdpath("cache")/NeoAI/sandbox`) is masked with an empty
    `tmpfs` inside the namespace, so a command cannot read or tamper with candidates, sessions,
    receipts and other internal state (prevents information leaks and escape).
- **Session-level shell state** (`tools.sandbox.session_shell`, on by default, bwrap only): each
  `run_command` is still an independent process/shell, but the session directory is bind-mounted to a
  fixed in-sandbox path and the wrapper saves/loads `cwd` + exported variables around every command,
  so `export FOO=...` / `cd /usr` persist across commands within the same agent loop; the state resets
  after the agentEnd session rotation (new sandbox).
- Freeze computes a manifest (create/modify/delete/mkdir/rmdir + before/after hashes).
- **Session scope**: the staging map is bound to a "sandbox session" — all tool calls within the
  same agent loop (generation) share one session, so edits compose; on
  `GENERATION_COMPLETED`/`GENERATION_ERROR`/`GENERATION_CANCELLED`/`AGENT_ABORTED` (agentEnd) the
  session rotates: the new session uses a new staging directory but **migrates the current staged
  content**, so unpublished file modifications stay consistent across loops (still readable/editable).
  Driven by the `sandbox.session` side-effect plugin subscribing to lifecycle events
  (`sandbox.watch_sessions`).
- **No path leaks**: staged paths in both success results and error messages are rewritten back to the
  real workspace paths (including read-only tools failing to read a deleted staged copy), so the model
  never sees sandbox-internal paths.
- **Hot-reload consistency**: `sandbox.shutdown()` clears the staging directory while the pending queue
  stays on disk; the next `sandbox.init()` **re-materializes** pending candidates into the new session's
  staging layer (`_rehydrate_pending`), so read tools see the same view as the review queue after a
  reload/reopen.

### LSP Mount-Namespace Overlay (opt-in)

- Switch: `tools.sandbox.lsp_overlay.enabled` (default false). Effective only with the `bwrap`
  backend and when the workspace root is overlay-mountable; otherwise it is skipped and LSP works
  as usual.
- Mechanism: wraps `vim.lsp.rpc.start`, turning the server command into
  `bwrap --unshare-all <minimal read-only system set> … --overlay-src <workspace> --overlay <upper> <work> <workspace> --chdir <workspace> <original cmd>`;
  the lower is the real workspace (read-only) and the upper is the sandbox's private writable layer.
  The server sees a merged view of "real files + staged changes" at the real paths. It uses the same
  minimal read-only system set as `run_command` (see §6), not `--ro-bind / /`.
- Consistency refresh: before every LSP tool call and at server start, `sandbox.lsp.refresh()`
  re-materializes the upper from the current workspace staging (wipe then write), so the server
  immediately sees the latest unpublished changes.
- Isolation & caches: LSP cache/state dirs (`stdpath(cache|data|state)`, `~/.cache`, `~/.local/*`)
  are rw-bound straight to the host, so caches never enter the overlay or the review queue; overlay
  uppers are sharded by workspace hash (no cross-project bleed) under
  `/dev/shm/.cache-<tag>/lsp/<hash>`.
- Lifecycle: the `sandbox.lsp` plugin installs/uninstalls the wrapper and restores the original
  `vim.lsp.rpc.start` on unload.

## 6. Runtime backend

- `bwrap` (if present): minimal read-only system set + multi-root overlay, with concealment args such
  as `--as-pid-1` (see §15). As root it prefers explicit no-user-namespace isolation flags, otherwise
  it uses `--unshare-all`.
  - **When overlay is usable**: each writable root (`process_roots`) uses real content as the
    read-only lower and a session upper as the writable layer, so the command sees real content and
    writes are captured.
  - **When overlay is not usable**: a private session directory is `--bind`-mounted over the root
    (namespace isolation and read-only rootfs are kept), instead of failing every `process` tool.
  - **Network allowed by default**: with a userns, `--share-net` after `--unshare-all`; without a
    userns the network is shared and only `offline=true` isolates it (`--unshare-net`).
- `unshare` (fallback): `--user --map-root-user --mount --pid --fork --ipc --uts --mount-proc`
  (shares network by default; adds `--net` when `offline=true`).
- Capability probe: `bwrap`/`unshare`/userns/cgroup v2/overlayfs/seccomp.
  - `bwrap` and `overlayfs` are **functionally probed** (actually launching bwrap / actually
    mounting overlay), not just detected from the binary or `/proc/filesystems`: when the host `/`
    superblock belongs to the init userns (e.g. inside a container), overlay returns `EINVAL` in a
    fresh userns, so a kernel-support-only check gives a false positive.
  - The capability probe is only a **coarse gate**; when building the process prefix, overlay is
    probed again with the **real execution paths** (lower = real cwd, upper/work = private layer),
    cached by `(dev_lower, dev_upper)`. A probe using same-source temp dirs can be a false positive
    when the real paths span mounts/userns, so a failed real-path probe downgrades to a `--bind`
    private cwd, ensuring `run_command` never hard-fails on an overlay mount error.
- A completely unavailable backend returns a clear error (`SANDBOX_BACKEND_UNAVAILABLE`); no silent
  downgrade. Overlay being individually unavailable is a degradable capability and continues with
  the private-cwd scheme above.

> In-process tools (LSP/treesitter/UI) cannot be namespace-isolated; they are constrained by
> "read-only by default + staged writes + policy gate". This is a documented boundary.

### Privilege reduction and host-sensitive path masking (on by default)

Namespace isolation alone is not enough to stop escape when a root payload keeps all
capabilities and can reach host sockets. `runtime` applies the following defense-in-depth
to the bwrap prefix by default:

- **Drop all capabilities**: `--cap-drop ALL` (add specific ones back via
  `tools.sandbox.cap_add`). The payload no longer holds `CAP_SYS_ADMIN`/`CAP_SYS_MODULE`/
  `CAP_SYS_PTRACE`, so `mount`, module loading, writing `/proc/sys/kernel/core_pattern`
  and `ptrace` are rejected by the kernel (verified `CapEff=0`).
- **seccomp baseline on by default** (see §12): even if a capability-related kernel flaw
  appears, the denylist still blocks `mount`/`unshare`/`setns`/`bpf`/`init_module` etc.
- **Mask host-sensitive paths** (`tools.sandbox.mask_paths`, secure defaults): directories
  are masked with an empty `tmpfs`, files/sockets with `/dev/null` (a socket becomes a
  character device, so `connect` fails). Defaults cover `/var/run/docker.sock`
  (equivalent to host root, the classic escape entry), `/var/lib/docker`, containerd/podman
  data, orchestrator (herdr) / panel (1panel) / D-Bus / systemd control channels, and host
  credentials such as `/root/.ssh`, `/root/.aws`, `/root/.gnupg`, `/root/.kube`, keyrings, plus
  read-surface leaks such as `/etc/shadow`, `/etc/gshadow`, `/etc/sudoers`, `/etc/machine-id`,
  `/etc/ssh`, `/var/log`, `/var/spool/cron` and root shell history.
  Masks are mounted after the writable-root overlays so they take effect.
- **Minimal read-only system set (allowlist, on by default)**: no more `--ro-bind / /`, and `/usr`
  is **no longer exposed as a whole** (when the host root partition sits on the same disk, that leaks
  the `/usr/share/doc` package database, `/usr/local/go_workspace`, `/usr/src`, etc.). Only
  `tools.sandbox.readonly_roots` (by default the `/usr` runtime subtrees
  `bin`/`sbin`/`lib*`/`libexec`/`include`, `share/{terminfo,locale,zoneinfo,ca-certificates,misc,…}`,
  `local/{bin,sbin,lib,libexec,include}`, plus the `/lib*`, `/bin`, `/sbin` loader symlink roots) and
  `tools.sandbox.readonly_paths` (default required `/etc` files: `ld.so.cache`/`passwd`/`group`/
  `nsswitch.conf`/`ssl`/`alternatives`/`profile` etc.) are exposed read-only.
  Unlisted host paths **do not exist** in the sandbox: `/var/log`, `/etc/shadow`, `/opt`, `/srv`,
  `/mnt`, `/media`, `/boot`, `/usr/share/doc`, `/usr/src`, `/usr/local/go_workspace` etc. are
  unreachable by default.
  `/etc/passwd` and `/etc/group` remain as standard read-only runtime files (world-readable on
  Unix; they expose account names, not password hashes). Narrow the allowlist further for a smaller
  read surface, or add paths back explicitly (and update `mask_paths`).
  The same read surface is used by the LSP namespace overlay (see §5).
- **`/etc/resolv.conf` sanitization** (`tools.sandbox.resolv_conf`, default `sanitize`): keeps only
  `nameserver` lines and strips `search`/`domain`/`options`, so host LAN/Tailscale domains are not
  leaked; can be set to `hide` (not exposed) or `passthrough` (raw host file).
- **`/proc` leak hiding** (`tools.sandbox.hide_proc_paths`, default `/proc/cmdline`, `/proc/version`):
  procfs is globally visible (not isolated by the pid namespace); these are overridden read-only with
  an empty file, hiding the host kernel command line (`root=UUID`, `crashkernel`) and version.
- **Masked directories (`tools.sandbox.mask_dirs`, on by default)**: when cwd is under a masked
  directory (default `/home`, `/root`), only the user home containing cwd is exposed read-only
  (for `/home`, the first-level user dir; for others, the dir itself), and siblings along the cwd
  ancestor chain are masked (including hidden files/dirs); the cwd subtree is exempt, and when cwd
  is the scope itself its hidden children (credential dotfiles) are masked. Other users' homes are
  not in the allowlist and are unreachable. Master switch `mask_dirs_enabled` (on by default).
  - **Approval**: when a tool argument hits a masked entry, approval is requested even in `async`
    mode (reusing `tool_service` / `ui/components/tool_approval`); once approved, the masked entry
    is unmasked for that call only (`ctx.sandbox_unmask` → runtime unmask); denial aborts the call.
  - **In-process fail-closed**: `read`/`fs_write` in-process tools are not constrained by mount
    masking; with no approval UI (headless/sub-agent) they are rejected rather than silently
    allowed. `process` tools are hard-masked by the mount.
  - With `mask_dirs_approval = false`, hits are hard-masked without a popup.

> **Residual risk (user namespace)**: when NeoAI runs as root, `bwrap` can only map the
> caller's uid 1:1 (`uid_map 0 0`); it cannot truly remap uids from inside the plugin, and
> `conceal` deliberately avoids creating a userns under root to hide fingerprints. After
> dropping all capabilities and enabling seccomp, the 1:1 mapping is no longer directly
> exploitable for privilege escalation, but reading unmasked root files is still governed by
> file permissions. **The complete fix is to enable `userns-remap` / rootless at the container
> runtime layer** so container root maps to a high host uid — a deployment-side setting,
> outside this plugin.

## 7. Configuration

```lua
require("NeoAI").setup({
  tools = {
    sandbox = {
      enabled = true,
      fail_closed = true,
      mode = "dry_run",              -- dry_run | commit
      backend = "auto",              -- auto | bwrap | unshare
      offline = false,               -- network allowed by default (recorded only)
      require_seccomp = true,        -- reject external execution when seccomp is unavailable (default on, fail-closed)
      cap_add = {},                  -- capabilities to add back; empty (default) = --cap-drop ALL
      -- Minimal read-only system set (allowlist): only /usr runtime subtrees, not the whole dir.
      readonly_roots = {
        "/lib", "/lib32", "/lib64", "/libx32", "/bin", "/sbin", -- loader/binary symlink roots (required)
        "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/lib32", "/usr/lib64", "/usr/libx32",
        "/usr/libexec", "/usr/include",
        "/usr/share/terminfo", "/usr/share/locale", "/usr/share/zoneinfo",
        "/usr/share/ca-certificates", "/usr/share/misc", "/usr/share/common-licenses",
        "/usr/share/git-core", "/usr/share/vim", "/usr/share/nvim",
        "/usr/local/bin", "/usr/local/sbin", "/usr/local/lib", "/usr/local/libexec",
        "/usr/local/include", "/usr/local/go",
      },
      readonly_paths = {             -- minimal /etc allowlist (supports * globs)
        "/etc/ld.so.cache", "/etc/passwd", "/etc/group", "/etc/nsswitch.conf",
        "/etc/hosts", "/etc/ssl", "/etc/alternatives", "/etc/localtime",
      },
      resolv_conf = "sanitize",      -- /etc/resolv.conf: sanitize (default, nameservers only) | hide | passthrough
      tmpfs_roots = { "/tmp", "/var/tmp" }, -- per-session private tmpfs (never an overlay lower; destroyed on exit)
      hide_proc_paths = { "/proc/cmdline", "/proc/version" }, -- overridden with an empty file; hides host kernel info
      mask_paths = {                 -- mask host-sensitive paths (dirs tmpfs / files·sockets /dev/null)
        "/run/docker.sock", "/var/run/docker.sock", "/var/lib/docker",
        "/root/.config/herdr", "/etc/1panel", "/root/.ssh", "/root/.aws", "/root/.gnupg",
        "/etc/shadow", "/etc/gshadow", "/etc/machine-id", "/etc/ssh", "/var/log",
        "/root/.bash_history", "/root/.zsh_history",
      },
      mask_dirs_enabled = true,      -- masked-directories master switch (on by default)
      mask_dirs = { "/home", "/root" }, -- masked dirs (cwd scope exposed read-only, other entries masked)
      mask_dirs_approval = true,     -- request approval on masked hits (reuses tool approval UI)
      process_roots = {},            -- run_command writable roots (default cwd only, auto-added; add more explicitly)
      seccomp = { enabled = true, filter_path = "" }, -- built-in denylist filter; bwrap backend only
      workspace_root = vim.fn.stdpath("cache") .. "/NeoAI/sandbox",
      review = { enabled = true, auto_apply = false }, -- async review: candidates enter a pending queue
      retention = { candidate_days = 7, max_pending = 20 },
      policy = { deny_tools = {}, rules = {} },
      limits = { wall_ms = 60000, memory_bytes = 0, pids = 0 },
    },
  },
})
```

Rules run in a restricted environment (explicit function allowlist; no `os/io/debug/load/require`)
with instruction/wall-clock budgets. Rule errors/timeouts/invalid results produce `DENY`
(`POLICY_EVALUATION_FAILED`). Aggregation is `DENY > NEEDS_CONFIRMATION > ALLOW`.

## 8. Events

`SANDBOX_PUBLISH_STARTED` / `SANDBOX_COMMITTED` / `SANDBOX_DISCARDED` / `SANDBOX_CONFLICT`,
plus async review `SANDBOX_REVIEW_ENQUEUED` / `SANDBOX_REVIEW_APPROVED` /
`SANDBOX_REVIEW_REJECTED` / `SANDBOX_APPLIED`, see [EVENTS.md](EVENTS.md).

## 9. Tests

`lua/NeoAI/tests/test_sandbox.lua` covers loader attachment, fail-closed, state machine/
idempotency/fencing, policy aggregation and restricted rules, dry-run no-write, CAS publish
and conflict, buffer write redirection, runtime probe and isolated process execution,
`run_command` overlay candidate capture (including deletion whiteout capture and attempt-dir cleanup).

## 10. Impact, evidence, grants and external operations (phases 2/3)

### Impact & evidence

- `impact` records fs/process/network with `source`/`coverage`/`evidence_id`; unknown fields are
  `null` (never 0 masquerading as unknown).
- `evidence` stores observations with secret-field redaction (`token`/`secret`/`password` → `[redacted]`)
  and supports `evidence_page({ after_id, limit })`.
- Each frozen candidate writes an evidence record referenced by the review item and decision envelope.

### Task grants

Narrow grants: `scope.paths` (supports `/**`), `operations`, `budget.max_files`, `ttl_sec`. When an
active grant covers a candidate (all write paths in scope, operation allowed, budget sufficient),
the candidate is **auto-applied via CAS** (equivalent to `TASK_POLICY_MATCH`) and consumes budget;
otherwise it enters async user review. Revocation is immediate.

```
:NeoAISandboxGrant [path] [ttl_sec] [max_files]   -- create a narrow grant
:NeoAISandboxRevoke <grant_id>                    -- revoke (no args lists all)
```

### Network (allowed by default + recorded)

Network is **not blocked by default** (`tools.sandbox.offline=false`): network tools
(`web_fetch`/`read_image`) execute normally and their endpoint is recorded in evidence
(kind=`network`) and the policy replay log; `run_command` processes share the host network
(bwrap `--share-net`).
- `tools.sandbox.offline=true`: hard-deny network tools (`NETWORK_OFFLINE`) and isolate process
  networking (no `--share-net`; unshare backend adds `--net`).
- Optional stricter mode: with `tools.sandbox.network.enabled=true` and declared `allowed_endpoints`
(host patterns, `*.example.com` supported), requests are allowed by application endpoint and bounded
by `budget_bytes`; undeclared endpoints are denied. L3/L4 tuples cannot prove application identity,
so declared endpoints are authoritative.

### External-operation broker

External side effects use an adapter protocol and do not inherit local file-publish atomicity/rollback
guarantees. Adapters declare `supports_idempotency` / `idempotency_retention` / `supports_query` /
`transaction_boundary` / `compensation_semantics` / `irreversible_effects`. The broker records intent
with a stable `operation_id`, deduplicates by idempotency key, and enters `OUTCOME_UNKNOWN` for
inconclusive results (resolved via `reconcile`, never blindly replayed).

### Retention & metrics

`:NeoAISandboxPrune` removes terminal (rejected/applied/failed/conflict) candidates and change sets
past `retention.candidate_days`; items referenced by recovery/reconcile/queued apply are kept.
`:NeoAISandboxMetrics` reports candidate/pending/applied/rejected/conflict counts.

## 11. Phase 4: dependency graph, composed publication and replay

- Change sets may declare `depends_on`; `dependencies(id)` returns the topological closure, and a
  missing dependency yields `BLOCKED_DEPENDENCY`.
- `prepare_publication_set(ids)` computes the dependency closure and **merges member candidates into
  a composed candidate** (by path; same path with different content → `PATH_CONFLICT`), producing a
  `publication_intent_hash` bound to member revisions and the composed digest. No publish side effects.
- `apply_set(set)` CAS-publishes the composed candidate; on success all members are marked `APPLIED`
  and a receipt is written. Selecting B without its dependency A never smuggles A in.
- Command: `:NeoAISandboxPublish <id> [id...]`.

### Policy replay

- Effectful decisions are recorded as evidence (facts + `policy.version`); `replay(evidence_id)`
  re-evaluates with the same rules and facts and compares `decision`/`reason_codes`, returning `same`
  and `version_mismatch`.
- Command: `:NeoAISandboxReplay <evidence_id>`. Replay is offline by default and never re-sends real
  external write requests.

### Evidence retention

`prune()` removes expired candidates/change sets and observation evidence per `retention.candidate_days`;
decision records are kept by default for policy replay (`evidence.prune(days, { keep_kinds = { "decision" } })`).

## 12. Phase 5: resource domains, seccomp gate and cache

### cgroup v2 resource domain

Each external process attempt gets its own resource domain from `tools.sandbox.limits`
(`memory_bytes` / `pids` / `cpu_max`). When any limit is set, the control plane creates a cgroup v2
child and joins the process (`join_prefix` writes `cgroup.procs` before exec); on completion/error it
`cgroup.kill`s and removes the child so the process tree converges. **If cgroup is unavailable while
limits are configured, execution is rejected** (`SANDBOX_CGROUP_UNAVAILABLE`) — no silent downgrade.

### seccomp baseline

A built-in denylist filter is generated (x86_64/aarch64): first validate `AUDIT_ARCH`
(mismatch → `KILL_PROCESS`), then return `EPERM` for dangerous syscalls
(`ptrace`/`mount`/`unshare`/`setns`/`bpf`/`kexec_load`/`init_module`/`io_uring_*`/
`open_by_handle_at`/…), `ALLOW` otherwise. It is applied via `bwrap --seccomp FD` before the payload
execs (bwrap's privileged setup is unfiltered): `runtime` opens the filter fd in a shell, then execs bwrap.

- Enabled with `tools.sandbox.seccomp.enabled=true`; **on by default** (defense in depth together
  with `--cap-drop ALL`).
- Empty `filter_path` generates the built-in denylist to `<root>/seccomp/baseline-<arch>.bpf`;
  a non-empty path must exist or execution is rejected.
- `require_seccomp=true` requires a usable filter (and the bwrap backend); otherwise
  `SANDBOX_SECCOMP_UNAVAILABLE` is returned and no seccomp baseline is claimed.
- bwrap backend only; the unshare backend rejects when seccomp is enabled/required.

### Content-addressed cache

`sandbox/cache.lua` caches dependencies/artifacts by a content key covering inputs/runtime/rules/facts;
writes are isolated and atomic, with `prune(days)`. Authorization/revocation state cannot be bypassed
via stale cache.

## 13. Phase 6: fault injection, benchmarks and revision derivation

### Fault injection

`sandbox/fault.lua` injects controllable faults at key points: `backend` (backend unavailable),
`freeze` (candidate freeze failure), `publish` (CAS publish failure), `store` (persistence failure).
Test/diagnostic only; nothing is injected by default. It verifies:
- publish failure produces **no partial write** (the real workspace is untouched);
- processes are explicitly rejected when the backend is unavailable;
- freeze failure is rejected and no pending change set is produced.

### Performance benchmarks

`sandbox/bench.run({ iterations })` measures policy evaluation, digests, attempt issuance and envelope
building, returning `{ iterations, total_ms, per_op_ms }` for performance regression and capacity checks.

### Revision derivation (file/hunk split)

`review.derive_revision(parent_id, { contents?, paths? })` regenerates a composed candidate from the
parent, forming a new `revision` that requires **re-review**; the parent is marked `SUPERSEDED` and old
approvals are **not** migrated. This implements §15.3 ("splitting by file or diff hunk requires a new
composed candidate, re-validation and user review").

## 14. Phase boundary

Phase 1: minimal local-file safe loop. Phase 2: impact/evidence paging, task grants, decision envelope,
retention/metrics. Phase 3: controlled network gateway and external-operation broker. Phase 4:
dependency graph and composed candidates, policy replay, evidence retention. Phase 5: cgroup resource
domains, seccomp gate and content-addressed cache. Phase 6: fault injection, benchmarks and revision
derivation. Later: additional runtime backends, actual seccomp BPF generation, distributed/multi-workspace
extensions.

## 15. Sandbox concealment (conceal, always on)

`sandbox/conceal.lua` reduces the AI's ability to tell, via external commands, that it is inside a
sandbox. It is **always on, with no config switch**. It only raises the detection bar; it does not
claim to make the sandbox undetectable. Inherent traces (namespace inodes, capability bits, the
host's own container info) cannot be erased without breaking isolation.

### Process-level de-fingerprinting (`sandbox.runtime`)

- **PID 1 is not bwrap**: the bwrap prefix adds `--as-pid-1`, so the payload itself becomes PID 1 and
  the process table no longer shows `bwrap --unshare-all …`. A command's `ps` / `/proc/1/cmdline`
  only sees an ordinary shell.
- **No user namespace as root**: when running as root and bwrap can isolate without a userns, explicit
  `--unshare-pid/ipc/uts/cgroup` replace `--unshare-all`, so there is no `uid_map 0 0 1` and no
  separate `ns/user` (non-root falls back to the userns-based isolation). Without a userns the network
  is shared by default; only `offline=true` adds `--unshare-net`.
- **Featureless names**: the overlay private-layer base is `/dev/shm/.cache-<tag>` and the session
  shell-state mount is `/tmp/.s-<tag>` (tag derived from cache dir + pid, stable across hot reload);
  the session wrapper's variables/files are renamed so PID 1's command line shows no sandbox-specific
  identifier.

### Command-output redaction (`shell.redact`)

Before returning stdout/stderr to the model, `run_command` runs `conceal.redact()`, which strips:

- overlay mount options' real paths `lowerdir=`/`upperdir=`/`workdir=` and `userxattr`/`uuid=on`;
- mount type `overlay` → `tmpfs` (mountinfo / mounts / mount formats);
- the `bwrap` process/tool name; self-identifiers such as `NeoAI-sandbox`, `neoai_session`, `__neoai`;
- the dynamic paths and basenames of the overlay base / session mount;
- outer-container path clues (`/var/lib/containerd/...`, `docker/rootfs/overlayfs/...`).

Redaction is a **best-effort text layer**: a model can bypass it with encoding/indirection (e.g.
`base64`) or read unfiltered system interfaces (`/proc/filesystems` still lists kernel overlay
support). Tests live in the "concealment" cases of `tests/test_sandbox.lua`.

## 16. Secret guard (secrets, always on)

`sandbox/secret.lua` ensures the AI can neither see nor use real secrets: entropy-based detection,
encryption into a random token on the way into the sandbox, decryption only when committing to the
real workspace; token operations are traced and warned about in the review UI; when a **raw secret**
appears in tool arguments it is hard-blocked and the whole agent is aborted immediately.

### Detection (entropy + charset heuristics)

- Candidate: length in `[min_length, max_length]`, contains letters and digits, distinct chars
  `≥ min_distinct`, Shannon entropy `≥ min_entropy` (defaults 20/200/8/3.5).
- Pure lowercase hex is excluded by default (`exclude_pure_hex`) so git SHAs / sha256 / md5 are not
  treated as secrets; the cost is that pure-lowercase-hex keys are not covered.
- **Environment variables are force-tokenized by name**: `sanitized_env()` replaces the value of any
  variable whose name (matched per `_`-separated segment) contains `KEY`/`TOKEN`/`SECRET`/`PASSWORD`/
  `CREDENTIAL` **regardless of entropy**, covering pure-hex keys like `GLM_API_KEY=dfe946…` that
  escape entropy detection. The over-broad `AUTH` is deliberately excluded to avoid false positives
  on path variables such as `SSH_AUTH_SOCK`.
- `allowlist` adds further Lua-pattern exclusions. See `tools.sandbox.secrets` in
  [configuration.md](configuration.md).

### Encryption mapping and lifecycle

- Each real secret gets a random token (`NEOKEY_<hex>`); the mapping is **in-memory only**, never
  persisted.
- **Encrypt on the way in**: tool results (before returning to the model), the workspace staged view
  (`candidate._base_entry` / `merge_candidate`), and `run_command`'s **environment variables**
  (high-entropy values, and values of secret-named variables, become tokens, so commands receive a
  token, not the real key) are all tokenized.
- **Decrypt on the way out**: only at commit / CAS publish, writing to real files
  (`candidate.publish`). If the mapping is missing (e.g. after a hot reload) publishing is
  **refused** (`SECRET_UNRESOLVED`) — a token is never written into a real file.
- Because the staged view is tokenized, `base_hash` (real baseline, used for CAS conflict detection)
  and `view_base_hash` (tokenized baseline, used for change detection) are tracked separately, keeping
  read-only tools and edits consistent.

### Tracing and warnings

- Every newly detected secret and every token used in tool arguments writes a `kind="secret"` evidence
  record.
- When a candidate's content involves a token, the review change-set carries `secret_warning` and
  `NeoAISandboxReview` shows a red `⚠ 密钥操作×N` marker.
- Events: `SANDBOX_SECRET_DETECTED` / `SANDBOX_SECRET_TRACED` / `SANDBOX_SECRET_BLOCKED`.

### Raw-secret hard block

When a **raw secret** known to the mapping table appears in tool arguments (deep scan):

1. the tool call is rejected (`SANDBOX_SECRET_BLOCKED`);
2. `core.agent.runtime.abort(agent, "secret_exposure")` **immediately aborts the whole agent**;
3. a `SANDBOX_SECRET_BLOCKED` event is emitted and the user is notified via `vim.notify`.

> Boundaries: entropy detection is heuristic, so long non-hex random strings can be false positives;
> since tokens round-trip losslessly at commit, a false positive does not change the final written
> content, it only adds tracing noise. The mapping is not persisted, so uncommitted tokens after a hot
> reload cannot be resolved and the candidate is refused at publish (fail-closed). Pure lowercase hex
> keys, and commands that read a real file and use the secret within the same command (without going
> through the model), are out of scope.

## 17. Privilege tiers and auto-escalation

By default every external command runs with **least privilege**; when it lacks privilege the
sandbox **automatically requests an escalation** (recorded, never silent) and tightens review
per tier. Core modules: `sandbox/privilege.lua` (classify/resolve/record) and
`sandbox/hostop.lua` (T2 host-effect proposals).

### Tiers

| Tier | Name | Use | Isolation | Review |
|---|---|---|---|---|
| **T0** | minimal | normal commands | cap-drop ALL + seccomp + masks + **network isolated by default** | no per-command review; fs changes enter the pending queue |
| **T1** | elevated | network access, controlled docker | runs isolated, network allowed | auto-authorized, recorded; fs changes enter the pending queue |
| **T2** | privileged | cap_add, host sockets, host mounts | runs inside a **nested userns** (caps scoped, cannot reach the host) | host effects frozen as a **proposal**, replayed after async approval |

- Classification: `privilege.classify()` parses the command; `docker/podman`→T1,
  `curl/git push/pip/npm`→T1 network, `sudo/mount/modprobe/iptables/systemctl`→T2; compound
  commands take the highest tier. Rules live in `tools.sandbox.privilege.classify`.
- Max tier: `tools.sandbox.privilege.max_tier` (default 2); exceeding it is hard-denied by policy
  (`PRIVILEGE_TIER_EXCEEDS_MAX`).
- Auto-escalation: when a T0 command fails with a privilege/network pattern (`operation not
  permitted`, `could not resolve host`, `cannot connect to the docker daemon`, …), it is
  automatically re-run at the required tier inside isolation, records a `kind="privilege"`
  evidence entry and emits `SANDBOX_PRIVILEGE_ESCALATION_REQUESTED`. Disable via
  `auto_escalate=false`.
- Recording: every tier decision/escalation is recorded (`record=true` by default).

### Controlled docker (external controlled socket)

The sandbox **never binds the host `/var/run/docker.sock`** (masked by default). With
`tools.sandbox.docker.mode="controlled"`, T1 binds the socket at `docker.socket` into the sandbox
at `/var/run/docker.sock` and injects `DOCKER_HOST=unix:///var/run/docker.sock`. The controlled
socket is provided by the deployment:

```bash
# 1) rootless dockerd (recommended: container root != host root)
dockerd-rootless-setuptool.sh install
#   tools.sandbox.docker.socket = "/run/user/1000/docker.sock"

# 2) docker-socket-proxy (API allowlist over the host socket)
docker run -d --name neoai-docker-proxy \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -e CONTAINERS=1 -e IMAGES=1 -e EXEC=0 -e POST=0 -e VOLUMES=0 \
  -p 127.0.0.1:2375:2375 tecnativa/docker-socket-proxy

# 3) DinD sidecar (separate daemon, isolated from the host)
```

`mode="off"` disables docker; `mode="host"` is allowed only at T2 and its host effects require
async approval.

### T2 host-effect proposals

T2 commands run inside a nested userns (`--unshare-all` + optional `--cap-add`, caps scoped to
that userns), so they **cannot directly affect the host**. Their host effects are frozen by
`hostop.freeze()` as proposals shown in `:NeoAISandboxReview` (with the command and a `[T2]`
badge); after the user approves, `review.apply` replays the command on the host and writes a
receipt (`SANDBOX_HOST_OP_APPLIED`); rejecting never executes it (`SANDBOX_HOST_OP_REJECTED`).
The tool call never blocks.

> Boundary: inside a nested userns T2 cannot use overlay (host `/` superblock in the init userns
> returns `EINVAL`), so it degrades to "read-only root + private cwd" and captures changes only in
> the cwd; arbitrary-path host effects are handled as proposals.

### Configuration

See `tools.sandbox.privilege` and `tools.sandbox.docker` in [configuration.md](configuration.md).
