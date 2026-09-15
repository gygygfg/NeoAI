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
| `sandbox/observe.lua` | Impact records (fs/process/network, unknown = null) and decision envelope (decision/severity/stats/asks/evidence); merges former `impact`+`envelope` (old files are compat shims) |
| `sandbox/evidence.lua` | Evidence storage, redaction, paging |
| `sandbox/grant.lua` | Narrow task grants (scope/operations/budget/ttl/revocation) |
| `sandbox/writer.lua` | Publish writer: tries non-root first, `NEEDS_ROOT` on permission error, then root/`sudo`(tty) after approval |
| `sandbox/network.lua` | Controlled network gateway (allowed by default; declared endpoints when enabled) |
| `sandbox/broker.lua` | External-operation adapter protocol (idempotency/query/compensation capability declarations and reconcile) |
| `sandbox/replay.lua` | Policy replay (reproduce a decision from the same rules and facts) |
| `sandbox/cgroup.lua` | cgroup v2 resource domain (memory/PID/CPU), one per attempt |
| `sandbox/seccomp.lua` | seccomp capability probe and require_seccomp gate |
| `sandbox/cache.lua` | Content-addressed cache (isolated writes, prunable) |
| `sandbox/diag.lua` | Fault injection (backend/freeze/publish/store) and critical-path benchmarks; merges former `fault`+`bench` (old files are compat shims) |
| `sandbox/tool_spec.lua` | Per-tool effect class and staged path declaration |
| `sandbox/wrapper.lua` | Enforcement gate: `attach` specs, `gate` all executions |
| `sandbox/risk.lua` | Security-level assessment (L0-L3), graded approval action, result grading |
| `sandbox/audit.lua` | AI read/call behavior monitoring, risk score and anomaly events |
| `sandbox/container.lua` | Controlled container runtimes: same namespace as sandbox (podman) or controlled socket (docker) |

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
    with a yellow `待审` state label, and shows a **high/medium/low** risk grade (`[L0]低危` …
    `[L2]/[L3]高危`) plus risk reasons. **The header line approves the whole change set**
    (`<CR>` applies every file in it), while a **file line approves a single file**
    (`<CR>` applies only the file under the cursor); `d` rejects that file (on the header, the
    whole unit), `i` temporarily closes the review window and opens a **diff preview** of that
    item (`q`/`<Esc>` closes it and returns to the review window with the cursor restored),
    `r` refreshes, `q`/`<Esc>` closes. Inside the chat main window press `<leader>ap` to trigger
    it (`keymaps.chat.sandbox_review`).
    - **Package installs are grouped per install command**: candidates produced by npm/pip/apt
      package installs are labelled on the header as `包安装 <manager>: <packages>`
      (`privilege.package_info`) and **merged into a single approval unit by the install-command
      key `package_key` (`<manager>:<packages>`)** — multiple candidates from the same install
      command (indexes, metadata, package files) appear as one entry in the review queue and are
      approved as one unit (`<CR>` applies all files) without per-file confirmation; `files` still
      allows applying only a subset. Detection skips wrappers such as `sudo`/`doas`/`env`/
      `bash -c`/`for …; do …` so a package install is not missed and escalated to L3.
    - **Writable roots and capabilities for package installs**: package install commands
      (any segment matching a package manager, `req.package`) automatically add the
      package-manager state dirs (`tools.sandbox.packages.roots`: `/var/lib/apt`,
      `/var/cache/apt`, `/var/lib/dpkg`, `/usr/local`, `~/.cache`, `~/.npm`, …) as writable
      roots staged via overlay, so `apt update`/`apt install`/`pip install`/`npm install` can
      write indexes/caches/metadata and those writes are frozen as candidates too. The
      on-demand capability grant (`req.package_all`) requires the **whole command** to be
      package managers (or benign companions such as `tee`; `apt update 2>&1 | tee log`
      still qualifies) — mixed commands (e.g. `apt update && cat /x`) get nothing, so `cat`
      cannot inherit `CAP_DAC_OVERRIDE`. Because `--cap-drop ALL` removes `CAP_DAC_OVERRIDE`
      (root cannot even write `_apt`-owned 0700 dirs), pure package installs add back the
      narrow capabilities listed in `tools.sandbox.packages.cap_add`
      (`CAP_DAC_OVERRIDE`/`CAP_CHOWN`/`CAP_SETUID`, …; **no `CAP_MKNOD`** — device nodes are
      hard-blocked by the seccomp baseline, see §6); the process still runs under the
      mount/pid namespace + seccomp + read-only root + masking + overlay staging.
    - **Oversized files are not captured** (`tools.sandbox.max_file_bytes`, default 8 MiB): files
      above the cap are still written to the overlay private layer (never the real disk) but are
      excluded from candidates/review/publish, so apt's `pkgcache.bin`, cache archives and image
      layers cannot be embedded into candidate JSON and block the main thread / fill the disk.
    - **Staged content is persistent**: `PENDING` and `APPROVED` (not yet applied) candidates are
      **re-materialized** from disk by `_rehydrate_pending` after a reload/restart, so large
      staged content such as package installs stays readable until applied or rejected and is not
      destroyed by session rotation/exit.
    - **L3 second confirmation** (`tools.sandbox.review.l3_warning.enabled`, on by default):
      for items with `risk_level=3`, the first `<CR>` does **not** apply directly. Instead the
      model (`sandbox/l3_warning.lua` via `core/agent/request`) generates a short consequence
      warning and the item's **diff** opens automatically with the warning shown at the top
      (a placeholder is shown while generating). Press `<CR>` again inside the diff to actually
      apply, or `q`/`<Esc>` to cancel and return. When the model is unavailable, times out, or no
      provider is configured, it falls back to a deterministic rule-based warning built from
      `risk_reasons`/paths and does not block the flow.
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
- **Re-validation before publish (defense in depth)**: `candidate.publish` re-canonicalizes every
  file path — if the resolved result differs from the recorded path (`..`/symlink introduced or
  swapped, e.g. a tampered on-disk candidate) it returns `CONFLICT/PATH_CHANGED`; if it hits a
  host-sensitive masked path (`is_masked_path`) it returns `FAILED/SANDBOX_MASKED_TARGET`. Even a
  locally-rewritten candidate cannot write to an unvalidated real location.
- **Same-file supersede**: when the same file is edited again (a new candidate is enqueued) or
  published directly, older `PENDING` change sets covering that path are marked `SUPERSEDED` and
  their candidates discarded, so the queue keeps only the latest version
  (`review.supersede_by_paths`).

### Staging

- **Explicit-path tools** (`edit_file`/`create_directory`/`ensure_dir`/`delete_file`): the
  gate rewrites path args to a private copy under `<root>/workspace/<hash>`. Paths are
  **fully canonicalized before staging** (`utils.fs.canonical`: expand `~`, make absolute, resolve
  symlinks and collapse `..`) so the staging key, risk grading, review display and publish target
  all use the same real path — otherwise `x/../../../etc/cron.d/pwn` (when `x` does not exist,
  `fnamemodify(:p)` does not collapse `..`) is shown as an in-workspace L0 green entry but written
  outside the workspace by the kernel at publish time. The workspace keeps a
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
  - LSP tools share the same staged view as `run_command`/git readers:
    `tools.sandbox.lsp_overlay.enabled` is on by default; the LSP server process is placed in a
    bwrap + overlay (see below), so its disk reads see staged content (no longer the real disk). When
    overlay is unavailable it is skipped, leaving LSP unaffected. LSP write tools
    (`lsp_rename`/`lsp_format`) always redirect their disk write to staging via `persist_buffer`.
  - **git read tools (`git_status` / `git_diff` / `git_log` / `git_branch` / `git_file_history` /
    `git_commit_detail`)**: executed inside the sandbox namespace (the same overlay as `run_command`),
    so disk reads see the **staged content**, not the real working tree. They run with
    `GIT_OPTIONAL_LOCKS=0` to avoid writing the index and are treated as read-only process tools that
    **do not capture candidates** or enter the review queue. The real working tree is never modified by
    git reads. (`git_rollback` is a write and still runs on the host under approval.)
- **Buffer-persist tools** (`delete_node`/`lsp_rename`/`lsp_format`): `tool_helpers.persist_buffer`
  redirects `:write!` to staging while the sandbox is active.
- **External processes** (`run_command`): with the bwrap backend, a set of **writable roots**
  (`tools.sandbox.process_roots`; default is only cwd, auto-added if not covered) are overlaid: the
  real root is the read-only lower, a session upper is the writable layer. The command can read real
  content under these roots, and creates/modifies/deletes at **any path** below them land in upper and
  are frozen as a candidate (deletions recognized via whiteout device nodes as `delete`/`rmdir`).
  - `/tmp` and `/var/tmp` are **per-session private temporary roots** (`tools.sandbox.tmpfs_roots`):
    by default (`tmp_private_base="host"`) a hidden temporary subdirectory is created under the host
    root (e.g. `/tmp/.cache-<tag>/<session>`, mode 1777) and **namespace-bound back onto that root** —
    the sandbox `/tmp` is exactly this session-private subdirectory, and the real host `/tmp` contents
    are invisible to the AI (AI isolation). It is **never** used as an overlay read-only lower, and is
    destroyed on exit/session rotation. Writes to `/tmp` are scratch and are not frozen as candidates,
    eliminating cross-session residue and host `/tmp` leakage. Set `tmp_private_base="session"` to
    restore the old behavior (directory under the session process dir, e.g. `/dev/shm`).
  - **Ephemeral candidate roots (`tools.sandbox.ephemeral_roots`, defaults to `tmpfs_roots`)**:
    file writes under these roots (**excluding the cwd subtree**) are **session-private and discarded
    when nvim exits** — they produce no pending candidate, no CAS publish, and no approval popup (the
    content stays only in the staging layer for consistent reads within the session). This applies to
    both in-process tools (`edit_file`/`create_directory`, which write the host directly) and external
    commands, so `/tmp` scratch is not repeatedly surfaced as a pending change. Set
    `ephemeral_roots = {}` to disable (then `/tmp` goes through normal review/approval).
  - Broad directories such as `/root`, `/home`, `/etc` are no longer overlaid by default, so host
    home/accounts/config are not exposed as read-only lowers; add them back explicitly to
    `process_roots` if needed, and tighten `mask_paths` accordingly.
  - The writable layer is **session-shared**: all commands in the same agent loop share it (command N
    sees command N-1's writes); on agentEnd the session rotates and it is cleaned with the session
    directory (changes already frozen as candidates).
  - **Bidirectional**: before a command the workspace staged content is materialized into the writable
    layer (the command sees `edit_file`'s unpublished edits and new files; deletions are represented as
    whiteouts); after it the changes are merged back into the workspace staging map (`read_file`/
    `edit_file` see the command's changes and keep composing). Capture records **only files the command
    actually changed**: materialized files whose content equals the current workspace staging (or that
    are already marked deleted) produce no candidate, so a read-only command (`ls`/`cat`/`git status`,
    …) cannot re-capture the AI's staged edit as a `run_command` candidate and supersede the original
    `edit_file` candidate — otherwise rejecting that read-only command would invalidate the staged edit,
    i.e. an "approved change rolled back".
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
- **Hot-reload consistency**: `sandbox.shutdown()` clears the staging directory while the review queue
  and candidates stay on disk; the next `sandbox.init()` **re-materializes** both pending (`PENDING`)
  and approved-but-unapplied (`APPROVED`/`NOT_REQUESTED`) candidates into the new session's
  staging layer (`_rehydrate_pending`), so read tools see the same view as the review queue after a
  reload/reopen.

### LSP Mount-Namespace Overlay (on by default)

- Switch: `tools.sandbox.lsp_overlay.enabled` (default true). Effective only with the `bwrap`
  backend and when the workspace root is overlay-mountable; otherwise it is skipped and LSP works
  as usual. Set to false to disable (LSP then reads the real disk).
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
  `/dev/shm/.cache-<tag>/lsp/<hash>`. After the rw binds, the same `mask_paths` as `run_command` are
  applied (e.g. `~/.local/share/keyrings`, `~/.cache/keyring-*`), so keyrings/credentials are not
  exposed to the LSP server via cache dirs.
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
    In this mode the command sees a session-private view (staged changes only), which may not include
    other real-disk files; `run_command` results carry a "degraded mode" notice
    (`ctx.sandbox_degraded`) plus the **degraded reason** (`ctx.sandbox_degraded_reason`) so
    "cannot see it" is not misread as "file missing / change did not take effect".
  - **Diagnosing the degraded reason**: `:NeoAISandboxCaps` prints `overlay=ready` or
    `overlay=unavailable(<reason>)`; `runtime.overlay_diagnosis()` probes with the real execution
    paths (cwd + sandbox overlay base dir) and returns `{ available, reason, flags, userns }`.
    Common causes: host `/` owned by the init userns while running with a userns (overlay EINVAL),
    lower/upper on different mounts or userns ownership, or an upper filesystem that does not support
    overlay upper/work (e.g. tmpfs without xattr, fuse, network filesystems).
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
capabilities and can reach host sockets. `runtime` therefore applies the following
defense-in-depth to the bwrap prefix by default (capabilities stay full for compatibility, while
host-global capabilities are narrowed via `cap_drop`):

- **Close inherited fds (anti-chroot-escape)**: before starting the payload, all inherited fds
  except 0/1/2 are closed. Otherwise a **directory fd** held by a host process (e.g. the AppImage
  runtime's `/tmp/.mount_*`) is inherited into the sandbox and the AI can `openat(dir_fd, "..")`
  its way back to host `/`, bypassing the chroot/namespace. See `runtime._wrap_close_fds`: it
  prefers `bash` (supports multi-digit fds), falls back to `python3`'s `os.closerange`, then to
  `sh` (dash only supports single-digit fds — best effort). `run_command`, `runtime.run` and the
  LSP namespace overlay all go through this wrapper.
- **Full capabilities by default + host-global capability narrowing (`cap_drop`)**: by default
  `cap_add = { "ALL" }` and `--cap-drop ALL` is **not** applied — node/python/apt/dpkg/pip and
  any other operation run with full root capabilities. At the same time, the capabilities that
  can **modify host-global state** are dropped one by one per `cap_drop` (default
  `CAP_NET_ADMIN`/`CAP_SYS_TIME`/`CAP_SYS_MODULE`/`CAP_SYS_RAWIO`/`CAP_SYS_BOOT`/
  `CAP_MAC_ADMIN`/`CAP_MAC_OVERRIDE`/`CAP_AUDIT_CONTROL`), so netlink route/firewall changes,
  clock changes, module loading, raw port I/O, reboot and MAC/audit changes are denied with
  `EPERM`; none of them are needed by dev/package workflows. Capabilities explicitly listed in
  `cap_add` are not dropped. Host **filesystem** immutability does not rely on capabilities but
  on namespaces + read-only root + overlay staging (writes are frozen as candidates). For minimal
  privileges set `cap_add = {}` (`--cap-drop ALL`); pure package-install commands then add back
  `CAP_DAC_OVERRIDE`/`CAP_CHOWN`/`CAP_SETUID`, … per `packages.cap_add`, while mixed commands
  (`apt update && cat /x`) get nothing. The sandbox already
  runs as root, so a leading `sudo`/`doas` (and its common boolean flags) is **stripped**
  (`sudo apt update` → `apt update`); otherwise `sudo` fails with `setresuid` EINVAL under the
  nested userns and a masked `/etc/sudoers`. Forms that change user/login (`-u/-g/-i/-s`, …)
  are left as-is.
  **Note**: capabilities are irrelevant to writing global sysctls such as
  `/proc/sys/kernel/core_pattern` and `modprobe` — these are not namespaced, and their write
  permission is decided by **DAC** (`euid == global root uid`). When the sandbox runs as root
  without a userns, `euid` is the global root, so the write succeeds under any capability
  configuration, forming a coredump/modprobe escalation primitive (host-global kernel state). It is
  therefore closed by the "mandatory dangerous sysctl masking" below, not by capabilities/seccomp.
- **Whole `/proc/sys` read-only bind (always on, root-cause fix)**: after `--proc /proc`,
  `--ro-bind /proc/sys /proc/sys` closes the write surface of **all** non-namespaced global
  sysctls in one shot. Audit found that before the fix `randomize_va_space`/`pid_max`/
  `kptr_restrict`/`dmesg_restrict`/`net.ipv4.ip_forward`/`net.ipv4.conf.all.forwarding`/
  `vm.swappiness`/`vm.max_map_count`/`vm.overcommit_memory`/`fs.protected_hardlinks` were all
  **WRITABLE** (`--cap-drop ALL` does not stop it — write permission is decided by DAC
  `euid==global root uid`; under a shared netns `net.*` even mutates the host network); after the
  fix they are all `EROFS` while reads keep working.
- **Mandatory masking of dangerous / info-leaking proc files (always on, not user-removable)**:
  `runtime.MANDATORY_PROC_MASKS` are overridden read-only with an empty file (reads empty,
  writes `EROFS`): `/proc/sys/kernel/{core_pattern,modprobe,hotplug,uevent_helper,
  kexec_load_disabled,sysrq,panic,panic_on_oops,perf_event_paranoid,unprivileged_bpf_disabled,
  unprivileged_userns_clone}` and `/proc/sys/vm/{drop_caches,compact_memory}`, plus the
  non-`/proc/sys` files `/proc/sysrq-trigger` (magic sysrq trigger), `/proc/kcore` (kernel memory
  read), `/proc/modules` and `/proc/kallsyms`, plus the kernel info-leak surfaces the audit found
  readable: `/proc/vmallocinfo` (exposes kernel virtual addresses, bypassing `kptr_restrict`),
  `/proc/timer_list`, `/proc/slabinfo`, `/proc/interrupts`, `/proc/softirqs`, `/proc/buddyinfo`,
  `/proc/zoneinfo`, `/proc/pagetypeinfo`, `/proc/keys`, `/proc/sched_debug`, `/proc/iomem`,
  `/proc/ioports`. The user `hide_proc_paths`
  list can only **add**, never remove mandatory entries. The `unshare` fallback cannot
  bind-mount, so it is **fail-closed** for `process` effects (`SANDBOX_SYSCTL_MASK_UNAVAILABLE`)
  rather than degrading silently.
- **seccomp baseline on by default** (see §12): even if a capability-related kernel flaw
  appears, the denylist still blocks `mount`/`unshare`/`setns`/`bpf`/`init_module` etc.
- **Mask host-sensitive paths** (`tools.sandbox.mask_paths`, secure defaults): directories
  are masked with an empty `tmpfs`, files/sockets with `/dev/null` (a socket becomes a
  character device, so `connect` fails). Defaults cover `/var/run/docker.sock`
  (equivalent to host root, the classic escape entry), `/var/lib/docker`, containerd/podman
  data, orchestrator (herdr) / panel (1panel) / D-Bus / systemd control channels, and host
  credentials such as `/root/.ssh`, `/root/.aws`, `/root/.gnupg`, `/root/.kube`, keyrings,
  **Git credentials and signing keys** (`~/.git-credentials`, `~/.config/git/credentials`,
  `~/.git-credential-cache`, `~/.netrc`, `~/.ssh`, `~/.gnupg`, `~/.config/gh`, for both root and
  `/home/*` users), plus
  read-surface leaks such as `/etc/shadow`, `/etc/gshadow`, `/etc/sudoers`, `/etc/machine-id`,
  `/etc/ssh`, `/var/log`, `/var/spool/cron` and root shell history.
  Masks are mounted after the writable-root overlays so they take effect.
  In-process `read`/`fs_write` tools do not go through a namespace, so mount masking does not apply;
  the executor additionally queries `runtime.is_masked_path` for path arguments and **hard-rejects**
  hits (`路径位于宿主敏感遮蔽路径`, no approval), covering `read_file`/`search_files`/`edit_file`
  and other tools that read the host directly.
- **Read surface: whole host read-only (`read_all`, on by default)**: by default the host root is
  exposed **read-only** as a whole (`--ro-bind / /`), masking only the important config
  files/credentials in `mask_paths` (see above) plus the sandbox's own storage — i.e. "everything is
  readable except important config files", so `/opt`, `/srv`, other project dirs, … are readable.
  `mask_dirs` (`/home`, `/root` sibling dirs) are no longer mount-masked.
  - **Outside-workspace tracing (non-blocking)**: accessing user working dirs outside `cwd` (under
    home/root) records evidence (kind=observation), emits a `sandbox:outside_access` event, and is
    shown in the `:NeoAISandboxReview` window under "越界访问留痕"; the read is still allowed, not
    blocked. Dedup is by `(tool, path)`; in-process read tools are judged by their path args and
    `run_command` heuristically by absolute paths in the command string; system paths (`/usr`,
    `/etc`, …) are not traced to avoid noise.
  - **`read_all = false` (fall back to the minimal allowlist)**: no whole-root bind, and `/usr`
    is **not exposed as a whole** (avoids leaking `/usr/local/go_workspace`, `/usr/src`, etc.). Via
    `tools.sandbox.readonly_roots` it exposes the `/usr` runtime subtrees
    `bin`/`sbin`/`lib*`/`libexec`/`include`, `local/{bin,sbin,lib,libexec,include}`, plus the
    `/lib*`, `/bin`, `/sbin` loader symlink roots. It also exposes the whole `/usr/share` and
    `/var/lib` read-only (runtime resources nodejs/dotnet/java/git-core/terminfo, host package
    databases dpkg/apt/rpm, …). `tools.sandbox.readonly_paths` (default required `/etc` files:
    `ld.so.cache`/`passwd`/`group`/`nsswitch.conf`/`ssl`/`alternatives`/`profile` etc.) is exposed
    read-only. Unlisted host paths **do not exist** in the sandbox. `/etc/passwd` and `/etc/group`
    remain as standard read-only runtime files (world-readable on Unix; they expose account names,
    not password hashes).
  In both modes dangerous/sensitive subpaths are still masked by `mask_paths` (e.g.
  `/var/lib/docker`, `/var/lib/containerd`; add `/usr/share/doc|man|info` to `mask_paths` to hide the
  software inventory). The same read surface is used by the LSP namespace overlay (see §5).
- **Tool child processes go through the sandbox (`NeoAI.sandbox.exec`)**: every child process a tool
  spawns internally (the `run_command` shell, `git` operations, `read_image`'s curl download,
  `web_fetch`'s bash/node rendering and dependency install, MCP stdio servers, …) is created inside
  the bwrap namespace rather than on the host. These helper processes do not freeze candidates (they
  only write the tool's own cache/temp dirs); `rw_binds` exposes the tool's own dirs read-write (host
  and sandbox see the same path) and `ro_binds` exposes the command's directory read-only, while the
  rest of the read surface keeps the minimal allowlist and host-sensitive masking. Tool temp/download
  dirs live under the shared root `stdpath('cache')/NeoAI/shared` (outside the sandbox store, same
  path on host and sandbox, avoiding exposing the host `/tmp`). When the backend is unavailable or the
  sandbox is disabled, `tools.sandbox.fail_closed` decides: `true` rejects execution (default),
  otherwise it falls back to the host (no silent read-surface downgrade).
- **Host runtime passthrough (`tools.sandbox.expose_paths`, opt-in, empty by default)**: these host
  paths are exposed read-only **after** masking/tmpfs and their directories are prepended to the
  sandbox `PATH` (`expose_path_env`), so `run_command` can invoke host toolchains (e.g. the appimage
  `nvim` under `/tmp/.mount_*`, `lua`/`luajit`, binaries under `~/.local/share/nvim/mason`). Empty by
  default to keep the read surface minimal; only expose trusted read-only tool dirs, **never
  credential/secret dirs**. This widens the sandbox read surface and is an explicit opt-in.
  - **Auto tool-dir passthrough** (`tools.sandbox.expose_tool_paths`, default off): when enabled,
    existing, non-credential/system host `PATH` bin dirs (skipping `/etc`, `/var`, `~/.ssh`, …) are
    exposed read-only and prepended to the sandbox `PATH`, so toolchains installed under `$HOME`
    (`node`/`npm`/`fd`/`go`) become usable inside the sandbox (otherwise they are "missing" because
    they are not mounted, and only tools under whitelisted dirs like `/usr` work).
- **Proxy policy (`tools.sandbox.network.proxy`, default `strip`)**: by default host proxies are
  **not** passed into the sandbox (e.g. mihomo only proxies opencode itself), avoiding an unreachable
  host `HTTPS_PROXY=127.0.0.1:7890` making `pip`/`npm` fail with `Connection refused`. `strip` unsets
  proxy vars before external commands (covering `run_command` and `runtime.run`); `passthrough` keeps
  host proxies; or set `{ http, https, all, no_proxy }` explicitly (unlisted proxy vars are cleared).
- **`/etc/resolv.conf` sanitization** (`tools.sandbox.resolv_conf`, default `sanitize`): keeps only
  `nameserver` lines and strips `search`/`domain`/`options`, so host LAN/Tailscale domains are not
  leaked; can be set to `hide` (not exposed) or `passthrough` (raw host file).
- **`/proc` leak hiding** (`tools.sandbox.hide_proc_paths`, default `/proc/cmdline`, `/proc/version`):
  procfs is globally visible (not isolated by the pid namespace); these are overridden read-only with
  an empty file, hiding the host kernel command line (`root=UUID`, `crashkernel`) and version. It
  shares the same read-only override mechanism as the mandatory dangerous-sysctl masking above;
  user config can only **add**, never remove.
- **Host-local access interception (`tools.sandbox.network.host_local_block`, on by default)**: see §6.1.
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
    allowed. `process` tools are hard-masked by the mount. Hits on `mask_paths` (host-sensitive
    paths / sandbox storage) are **always hard-rejected**, even with an approval UI; only masked
    directories (`mask_dirs`) go through approval. Before matching, the path is **canonicalized**
    (expand `~`, make absolute, and resolve symlinks including `/proc/<pid>/root`,
    `/proc/<pid>/cwd`, `/proc/<pid>/fd`, and dangling symlinks); otherwise
    `read_file /proc/self/root/etc/shadow` or a workspace symlink to host credentials would bypass
    `mask_paths`/`mask_dirs`. When a path hits both `mask_paths` and `mask_dirs`, the
    `mask_paths` hard rejection wins (a soft hit must not allow it through).
  - With `mask_dirs_approval = false`, hits are hard-masked without a popup.

> **Residual risk (user namespace)**: when NeoAI runs as root, `bwrap` can only map the
> caller's uid 1:1 (`uid_map 0 0`); it cannot truly remap uids from inside the plugin, and
> `conceal` deliberately avoids creating a userns under root to hide fingerprints. With full
> capabilities by default, the payload is host root inside the namespace: **filesystem
> modification** is closed by namespaces + read-only root + overlay staging + masking +
> approval, and **host-global state modification** is closed by `cap_drop` (network/clock/
> modules/raw I/O/boot/MAC/audit) plus seccomp (device nodes, clock, port I/O,
> mount/unshare/bpf/… barriers); `CAP_DAC_OVERRIDE` can still **read** 0600 files outside the
> mask list (information disclosure, not modification). Set `cap_add = {}` to narrow further to
> minimal privileges. **The complete fix is to enable `userns-remap` / rootless at the container
> runtime layer** so container root maps to a high host uid — a deployment-side setting,
> outside this plugin.

### 6.1 Host-local access interception (`tools.sandbox.network.host_local_block`, on by default)

The overall network policy is **allow + record** (`offline=false`), but access **to the host
itself** is intercepted by default, preventing the AI from reaching host services via external
commands (SSRF, e.g. host admin panels, internal ports, cloud metadata):

- **Mechanism**: sandbox external commands get `HTTP_PROXY`/`HTTPS_PROXY` (HTTP proxy) and
  `ALL_PROXY` (`socks5h://`) pointing at the host-side pure-Lua filtering proxy
  `sandbox/host_proxy.lua` (listening on a random `127.0.0.1` port; pin it with
  `host_local_proxy_port`). The proxy supports **HTTP CONNECT + absolute form + SOCKS5**: targets
  hitting the host-local set (`127/8`, `::1`, host NIC IPs, `169.254/16`, `fe80::/10`,
  `169.254.169.254`) are denied and recorded; other external targets are forwarded bidirectionally
  and recorded. **Targets are resolved exactly once**: canonicalized to IPs via `getaddrinfo`
  (normalizing octal/hex/short-form IPv4, fully-expanded IPv6, IPv4-mapped `::ffff:127.0.0.1`),
  checked numerically against the host-local set, then **connected using the same validated IPs** —
  avoiding both "literal string compare vs. kernel parse" mismatches and DNS-rebinding by a second
  resolution. Unresolvable targets fail closed (treated as host-local). Records are returned via the
  `run_command` result summary and stored as `network` evidence.
- **T0 allows network by default**: `tools.sandbox.privilege.tiers[0].network = true`, so T0 no
  longer passes `--unshare-net`; `offline=true` still hard-isolates (taking precedence over tiers).
- **Boundary (important)**: this is **application-layer** filtering. **Raw TCP that ignores the
  proxy** (`nc`/`ssh`/database clients, tools ignoring proxy env) can connect directly to the host
  under a shared netns and is not covered. Hard-interception of raw TCP requires either root +
  iptables/nft (destination-based filtering) or rootless `slirp4netns`/`passt` (native userspace
  network stacks, not installed here) — this plugin does not add those dependencies. So this is a
  **non-hard boundary**; see the `sandbox/host_proxy.lua` module header.
- **Residual information leak (inherent to a shared netns)**: because T0 shares the host network
  namespace, `/proc/net/tcp`, `/proc/net/unix` (host connection/Unix-socket tables) and
  `ip addr`/`ip route` (netlink, host topology) are visible to the sandbox. `/proc/net` is a
  `self/net` symlink and cannot be masked by a mount; netlink also bypasses mounts. Only an
  isolated netns removes it, which conflicts with "network allowed", so it is recorded as a known
  boundary (connections are still constrained by the proxy and host-local interception; what leaks
  is metadata).
- **Abstract-namespace Unix sockets (residual)**: path masking only covers filesystem sockets
  (e.g. `/var/run/docker.sock` becomes a character device); **abstract-namespace sockets
  (`@name`, no filesystem path) are not masked** and can be connected to under a shared netns.
  Like raw TCP, this is a residual boundary application-layer filtering cannot cover (the audit
  confirmed `AF_UNIX` connect is reachable and abstract-socket entries are visible).
- **Host metadata leaks (global procfs entries, residual)**: `/proc/loadavg`, `/proc/pressure/*`,
  `/proc/cpuinfo`, `/proc/bus/{pci,input}`, `/proc/schedstat` etc. are global procfs entries that
  expose host load/process count/hardware info; the new uts ns **inherits the host hostname**
  (`hostname` shows it). Low-severity info leaks; can be added to `MANDATORY_PROC_MASKS` if needed
  (at the cost of the corresponding tools).
- **setuid binaries (residual, neutralized by NNP)**: host setuid programs are visible
  (`mount`/`passwd`/`ssh-keysign`/`fusermount3`/`chrome-sandbox` etc.), but `NoNewPrivs=1` makes
  setuid/file-capabilities ignored, and `mount`/`clone(CLONE_NEWUSER)` are seccomp-blocked while
  `/dev/fuse` is absent — so they cannot be used to escalate.
- **Mutually exclusive with the isolated-netns gateway (`network.gateway`)**: when the gateway is
  enabled it provides the proxy and this interception steps aside.

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
      cap_add = { "ALL" },           -- full root capabilities by default (namespaces/read-only/overlay/seccomp keep the host unmodified); {} = minimal
      cap_drop = {                   -- host-global capability narrowing (dropped even when cap_add contains ALL)
        "CAP_NET_ADMIN", "CAP_SYS_TIME", "CAP_SYS_MODULE", "CAP_SYS_RAWIO",
        "CAP_SYS_BOOT", "CAP_MAC_ADMIN", "CAP_MAC_OVERRIDE", "CAP_AUDIT_CONTROL",
      },
      -- Minimal read-only system set (allowlist): /usr is not whole-exposed, but /usr/share and /var/lib are read-only.
      readonly_roots = {
        "/lib", "/lib32", "/lib64", "/libx32", "/bin", "/sbin", -- loader/binary symlink roots (required)
        "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/lib32", "/usr/lib64", "/usr/libx32",
        "/usr/libexec", "/usr/include",
        "/usr/share",                -- runtime shared data (nodejs/dotnet/java/git-core/terminfo, ...)
        "/usr/local/bin", "/usr/local/sbin", "/usr/local/lib", "/usr/local/libexec",
        "/usr/local/include", "/usr/local/go",
        "/var/lib",                  -- host package DB (dpkg/apt/rpm, ...); dangerous subpaths still masked
      },
      readonly_paths = {             -- minimal /etc allowlist (supports * globs)
        "/etc/ld.so.cache", "/etc/passwd", "/etc/group", "/etc/nsswitch.conf",
        "/etc/hosts", "/etc/ssl", "/etc/alternatives", "/etc/localtime",
      },
      expose_paths = {},             -- host runtime passthrough (opt-in): expose read-only after masking and prepend to PATH
      expose_path_env = true,        -- whether to prepend expose_paths dirs to the sandbox PATH
      expose_tool_paths = false,     -- auto-expose host PATH tool dirs (opt-in; makes $HOME node/npm/fd/go usable)
      resolv_conf = "sanitize",      -- /etc/resolv.conf: sanitize (default, nameservers only) | hide | passthrough
      tmpfs_roots = { "/tmp", "/var/tmp" }, -- per-session private temporary roots (never an overlay lower; destroyed on exit)
      ephemeral_roots = { "/tmp", "/var/tmp" }, -- ephemeral candidate roots (excluding cwd subtree): session-private writes, no pending/approval
      tmp_private_base = "host",     -- host (default: hidden subdir under the host root, namespace-bound back) | session
      hide_proc_paths = { "/proc/cmdline", "/proc/version" }, -- additional hides (mandatory sysctl list can only grow)
      mask_paths = {                 -- mask host-sensitive paths (dirs tmpfs / files·sockets /dev/null)
        "/run/docker.sock", "/var/run/docker.sock", "/var/lib/docker",
        "/root/.config/herdr", "/etc/1panel", "/root/.ssh", "/root/.aws", "/root/.gnupg",
        "/root/.git-credentials", "/root/.config/git/credentials", "/root/.config/gh",
        "/home/*/.ssh", "/home/*/.gnupg", "/home/*/.git-credentials", "/home/*/.config/gh",
        "/etc/shadow", "/etc/gshadow", "/etc/machine-id", "/etc/ssh", "/var/log",
        "/root/.bash_history", "/root/.zsh_history",
      },
      mask_dirs_enabled = true,      -- masked-directories master switch (on by default)
      mask_dirs = { "/home", "/root" }, -- masked dirs (cwd scope exposed read-only, other entries masked)
      mask_dirs_approval = true,     -- request approval on masked hits (reuses tool approval UI)
      process_roots = {},            -- run_command writable roots (default cwd only, auto-added; add more explicitly)
      network = {
        host_local_block = true,     -- intercept host-local access (application-layer; raw TCP not covered, see §6.1)
        host_local_proxy_port = 0,   -- host filtering proxy port (0 = random loopback port)
        proxy = "strip",             -- strip | passthrough | { http, https, all, no_proxy }
      },
      seccomp = { enabled = true, filter_path = "" }, -- built-in denylist filter; bwrap backend only
      workspace_root = vim.fn.stdpath("cache") .. "/NeoAI/sandbox",
      review = { enabled = true, auto_apply = false }, -- async review: candidates enter a pending queue
      retention = { candidate_days = 7, max_pending = 20 },
      policy = { deny_tools = {}, rules = {} },
      limits = { wall_ms = 60000, dynamic = true, memory_ratio = 0.5, cpu_cores_max = 4, pids_max = 2048 },
    },
  },
})
```

Rules run in a restricted environment: `setfenv` replaces the rule's **global environment** with an
explicit allowlist (`string`/`table`/`math`/`ipairs`/`pairs`/`type`/`tostring`/`tonumber`/`facts`),
so `os`/`io`/`debug`/`require`/`load`/`pcall` are unreachable (`pcall` is deliberately excluded so a
rule cannot swallow the budget hook's abort error); if `setfenv` is unavailable or fails the rule is
rejected fail-closed. Instruction/wall-clock budgets still apply. Rule errors/timeouts/invalid
results produce `DENY` (`POLICY_EVALUATION_FAILED`). Aggregation is `DENY > NEEDS_CONFIRMATION > ALLOW`.
> Residual: a rule that captured a global via upvalue (e.g. `local os = os`) cannot be reclaimed by
> `setfenv` — only source rules from trusted origins.

## 8. Events

`SANDBOX_PUBLISH_STARTED` / `SANDBOX_COMMITTED` / `SANDBOX_DISCARDED` / `SANDBOX_CONFLICT`,
plus async review `SANDBOX_REVIEW_ENQUEUED` / `SANDBOX_REVIEW_APPROVED` /
`SANDBOX_REVIEW_REJECTED` / `SANDBOX_APPLIED`, see [EVENTS.md](EVENTS.md).

## 9. Tests

`lua/NeoAI/tests/test_sandbox.lua` covers loader attachment, fail-closed, state machine/
idempotency/fencing, policy aggregation and restricted rules, dry-run no-write, CAS publish
and conflict, buffer write redirection, runtime probe and isolated process execution,
`run_command` overlay candidate capture (including deletion whiteout capture and attempt-dir cleanup),
in-process `mask_paths` hard-rejection, and name-forced secret tokenization (text layer), plus
security-hardening regressions: pre-publish path re-canonicalization (rejecting `..` traversal /
masked targets), risk-grading and review-UI path resolution, restricted-rule environment isolation
(`os`/`pcall` unreachable), seccomp x32-bit interception, and `0700` candidate-store permissions.

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

### Isolated netns + host gateway (`network.gateway`, opt-in)

With `tools.sandbox.network.gateway.enabled=true`, the sandbox process enters a **private network
namespace** (`ip netns exec <ns> bwrap …`; bwrap no longer unshares net) and can only reach the host
gateway. The gateway first runs a TCP connect **probe** on the target `host:port` (so host listening
ports are discoverable), then **never relays real service data** and returns the interception reason
(JSON) to the client:

- open port: `HTTP 403` + `{"open":true,"reason":"port_open_but_service_access_blocked_…"}`;
- closed port: `HTTP 502` + `{"open":false,"reason":"port_not_open:…"}`;
- non-host-local address: `HTTP 403` + `only_host_local_addresses_allowed`.

Implemented as a host-side HTTP proxy (`sandbox/gateway.lua`, pure Lua/vim.uv); `run_command` injects
`HTTP(S)_PROXY` pointing at the gateway, so proxy-aware tools (`curl`/`wget`/`git`/`nmap --proxies`)
can probe and receive the reason; raw direct TCP (not via a proxy) cannot reach the host in the
isolated netns and thus does not work. The `run_command` result is annotated with this command's probe
summary (open/closed ports + reason) for the AI.

Orchestration (`sandbox/net_gateway.lua`): creates a veth pair and netns, sets the default route to
the gateway, and inserts a host-firewall (e.g. ufw) inbound allow rule **scoped to that veth and
limited to the gateway's destination address and port** (`-i <veth> -d <gw_ip> -p tcp --dport
<gateway port>`, not a blanket per-interface allow — otherwise the netns could reach arbitrary
non-loopback host services), plus a `-i <veth> -j DROP` FORWARD drop rule (so that with host
`ip_forward=1` the netns cannot reach the LAN/internet via host forwarding); both removed on
teardown. Resources are cleaned up on session/plugin unload. Requires root and `ip`;
when unavailable it fails closed with an explicit `GATEWAY_*` error.

> Note: true transparent interception (any raw TCP can scan ports while services are blocked) needs
> `TPROXY` + `SO_ORIGINAL_DST`, which pure Lua cannot do (it needs a small native helper); the current
> proxy-gateway covers proxy-aware tools.

### Hint when the AI reads a key

When a tool result is tokenized (the AI read a `NEOKEY_*`), `tools/executor` appends: "`NEOKEY_*` is a
sandbox secret token — invisible only to the AI; on network send / file write it is automatically
restored to the real key and does not change program behavior." This prevents the AI from mistaking a
token for the real key or misjudging the key as invalid. For env vars there is also the
`NEOAI_TOKENIZED_ENV` marker (see the secret-guard section).

### External-operation broker

External side effects use an adapter protocol and do not inherit local file-publish atomicity/rollback
guarantees. Adapters declare `supports_idempotency` / `idempotency_retention` / `supports_query` /
`transaction_boundary` / `compensation_semantics` / `irreversible_effects`. The broker records intent
with a stable `operation_id`, deduplicates by idempotency key, and enters `OUTCOME_UNKNOWN` for
inconclusive results (resolved via `reconcile`, never blindly replayed).

### Retention & metrics

`:NeoAISandboxPrune` removes terminal (rejected/applied/failed/conflict) candidates and change sets
past `retention.candidate_days`; items referenced by recovery/reconcile/queued apply are kept.
`:NeoAISandboxMetrics` reports candidate/pending/applied/rejected/conflict counts. The store root
and its subdirectories (`candidates`/`reviews`/`evidence`/`receipts`/`host_ops`) are chmodded to
`0700` so other local users cannot enumerate/read unpublished content or command details.
> Boundary: a same-uid local process can read/write these files (equivalent to any of the user's
> other files) and is outside this plugin's protection scope; the publish-side path re-validation
> and mask hard-deny still stop a tampered candidate from being written to sensitive locations.

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

Each external process attempt gets its own resource domain from `tools.sandbox.limits`. By default
`dynamic = true` derives caps from host resources — memory = `MemTotal * memory_ratio` (default 0.5,
bounded by `memory_max_bytes`), CPU = `min(nproc, cpu_cores_max)` cores (default 4), PIDs =
`pids_max` (default 2048); explicit static `memory_bytes`/`pids`/`cpu_max` (>0) win over the derived
values. The control plane creates a cgroup v2 child and joins the process (`join_prefix` writes
`cgroup.procs` before exec); on completion/error it `cgroup.kill`s and removes the child so the
process tree converges. When cgroup is unavailable it **skips the limits with a warning** (no
blocking); set `limits.fail_closed = true` to reject execution instead
(`SANDBOX_CGROUP_UNAVAILABLE`) — no silent downgrade.

### seccomp baseline

A built-in denylist filter is generated (x86_64/aarch64): first validate `AUDIT_ARCH`
(mismatch → `KILL_PROCESS`), then return `EPERM` for dangerous syscalls
(`ptrace`/`mount`/`unshare`/`setns`/`bpf`/`kexec_load`/`init_module`/`io_uring_*`/
`open_by_handle_at`/the new mount API `open_tree`/`move_mount`/`fsopen`/`fsconfig`/`fsmount`/
`fspick`/`mount_setattr`/…), `ALLOW` otherwise. It is applied via `bwrap --seccomp FD` before the
payload execs (bwrap's privileged setup is unfiltered): `runtime` opens the filter fd in a shell,
then execs bwrap.

- **`clone`/`clone3` namespace filtering (audit hardening)**: `unshare`/`setns` are blocked, but
  `clone`/`clone3` with `CLONE_NEWUSER` etc. can create a **nested userns**, bypassing the unshare
  block. The filter checks `clone`'s `args[0] & (NEWUSER|NEWNS|NEWPID|NEWNET|NEWIPC|NEWUTS|
  NEWCGROUP)` and returns `EPERM` on a hit; `clone3`'s flags live behind a pointer that classic
  seccomp cannot dereference, so it returns `ENOSYS` to make glibc fall back to `clone` (which is
  then flag-filtered), avoiding a hard `EPERM` that would break thread creation.
- **`socket` address-family allowlist (audit hardening)**: only `AF_UNIX`/`AF_INET`/`AF_INET6`/
  `AF_NETLINK` are allowed; all other families (`AF_PACKET`/`AF_VSOCK`/`AF_ALG`/`AF_XDP`/
  `AF_TIPC`/…) return `EPERM`. In particular **`AF_VSOCK` is not isolated by the network
  namespace and does not go through the proxy**, so it can reach host vsock services (the audit
  created one and connected to the host CID) — a host communication channel independent of the
  netns, which must be blocked by address family.
- **x32 ABI-bit interception (audit hardening)**: on x86_64, an x32 process reports the same
  `seccomp_data.arch` but its syscall number carries `__X32_SYSCALL_BIT` (`0x40000000`). Without
  masking, every exact `JEQ` in the denylist misses → the whole filter is bypassed
  (`syscall(165 | 0x40000000, …)` still reaches `sys_mount`/`mknod`). After loading `nr` the filter
  does `JSET 0x40000000` → `KILL_PROCESS`, before any number comparison (x86_64 only).
- **`mknod`/`mknodat` device-node barrier (audit hardening)**: a `mode` containing
  `S_IFCHR`/`S_IFBLK` returns `EPERM`, closing the "create a device node → `open` reaches the
  real device → raw disk read" escape (device nodes bypass overlayfs; staging/masking/approval
  are all ineffective against `open` on a device node). FIFOs (`mkfifo`) and regular files are
  unaffected; the barrier holds even when `CAP_MKNOD` is present (e.g. the default
  `cap_add = { "ALL" }`) — defense in depth.
- **Host-global state syscall barrier (seccomp, defense in depth)**: `adjtimex`/`settimeofday`/
  `clock_settime`/`clock_adjtime` (host clock) and `iopl`/`ioperm` (raw port I/O, x86) return
  `EPERM`, backing up `cap_drop` (`CAP_SYS_TIME`/`CAP_SYS_RAWIO`); `mount`/`unshare`/`setns`/
  `bpf`/`init_module`/`kexec_load`/`reboot` are in the denylist too.
- Enabled with `tools.sandbox.seccomp.enabled=true`; **on by default** (defense in depth).
- Empty `filter_path` generates the built-in denylist to `<root>/seccomp/baseline-v5-<arch>.bpf`
  (versioned filename so content changes rebuild it);
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

Before returning stdout/stderr to the model, `run_command` runs `conceal.redact()`; **in-process
`read` tools reading `/proc/*` are redacted too** (the audit found `read_file /proc/self/mountinfo`
previously returned raw overlay paths, bypassing shell-output redaction; `wrapper.gate` now calls
`conceal.redact` on `/proc` read results). It strips:

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
real workspace. **Encrypted keys (tokens) and sensitive env-var names** are only traced and
**escalated** in the review floating window (classified as a secret operation — L2 inside the
workspace / L3 outside, forced review,
`⚠ 密钥操作`) and **do not abort the agent**; only when a **raw secret** (the unencrypted real value)
appears in **tool arguments** or in the **AI-visible context** (the wire messages about to be sent to
the model) is it hard-blocked and the whole agent aborted immediately — the latter means tokenization
was bypassed (the sandbox context was broken). Note: detection understands code semantics, so
expressions like `api_key = os.getenv("..._API_KEY")` are not treated as raw secrets.

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
- **Text is force-tokenized by name too**: `tokenize()` (tool results / staged content) replaces the
  value in `NAME=value`, `NAME="value"` and `"NAME": "value"` when `NAME` matches the same sensitive
  name rule, regardless of entropy. This closes two entropy blind spots: pure-lowercase-hex segments
  (dropped by `exclude_pure_hex`) and dotted multi-segment keys (split by `RUN_PAT` into
  non-candidates), e.g. `GLM_API_KEY=dfe946….rwbWDAf…` in `/proc/self/environ`. The value charset is
  deliberately narrow to avoid swallowing across entries.
- `allowlist` adds further Lua-pattern exclusions. See `tools.sandbox.secrets` in
  [configuration.md](configuration.md).

### Observability of env tokenization

Inside the sandbox, sensitive environment variables are **tokens (`NEOKEY_<hex>`), not the real
keys**, diverging from the host. To avoid mistaking a token for a real credential (e.g. `curl` with
`$DEEPSEEK_API_KEY` returning `401 api key invalid` when the key was actually replaced):

- Whenever env tokenization occurs, the sandbox process environment gets a marker variable
  `NEOAI_TOKENIZED_ENV=<comma-separated names>`, visible via `env` / `printenv`, so it is clear the
  value was substituted by the sandbox.
- To inspect real env vars (debugging / trusted local runtime), set
  `tools.sandbox.secrets.tokenize_env = false` to disable env tokenization entirely; tool results and
  staged content are still protected. **This weakens isolation — use only temporarily in trusted
  environments.**

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

- Every newly detected secret, every token used in tool arguments, and every sensitive env-var name
  occurrence writes a `kind="secret"` evidence record.
- A token used in tool arguments or a sensitive env-var name (all-uppercase, containing a
  `KEY`/`TOKEN`/`SECRET`/`PASSWORD`/`CREDENTIAL` segment, length ≥ 6, e.g. `GIT_COMMIT_AI_API_KEY`)
  sets `ctx.secret_operation`, so the candidate is classified as a secret operation (L2 inside the
  workspace / L3 outside) and
  **forced into review** (`auto=false`) — the agent is **not** aborted.
- When a candidate's content involves a token, or the call hit a sensitive env-var name, the review
  change-set carries `secret_warning` and the `NeoAISandboxReview` floating window shows a red
  `⚠ 密钥操作×N` marker (including the env-var names).
- Events: `SANDBOX_SECRET_DETECTED` / `SANDBOX_SECRET_TRACED` / `SANDBOX_SECRET_BLOCKED`.

### Raw-secret hard block (tool arguments and AI context)

When a **raw secret** known to the mapping table appears in **either** location, the whole agent is
aborted:

1. **tool arguments** (deep scan, outbound): the tool call is rejected (`SANDBOX_SECRET_BLOCKED`);
2. **AI-visible context** (pre-request scan of the wire messages `core/agent/recovery` is about to
   send): tokenization was bypassed (the sandbox context was broken), so the round is rejected.

Both paths call `core.agent.runtime.abort(agent, "secret_exposure")` to **immediately abort the whole
agent**, emit a `SANDBOX_SECRET_BLOCKED` event and notify the user via `vim.notify`. Tokens
(`NEOKEY_*`) never trigger an abort, only review escalation.

> Boundaries: entropy detection is heuristic, so long non-hex random strings can be false positives;
> since tokens round-trip losslessly at commit, a false positive does not change the final written
> content, it only adds tracing noise. The mapping is not persisted, so uncommitted tokens after a hot
> reload cannot be resolved and the candidate is refused at publish (fail-closed). Pure lowercase hex
> keys, and commands that read a real file and use the secret within the same command (without going
> through the model), are out of scope.

### 16.1 High-entropy content generated by the AI (watch generated keys too)

Besides host secrets entering the sandbox, key-like high-entropy content the **AI itself generates**
inside the sandbox is watched too: `secret.detect_generated(files)` runs entropy/named-rule detection
directly on candidate file contents (complementing `warn_for_files`, which only recognizes already
tokenized host secrets). On a hit (generated private-key block, random token, API key, …) it:

- writes a `kind="secret"` evidence record (`event="generated_high_entropy"`);
- emits `SANDBOX_SECRET_DETECTED` (`source="generated"`) and `audit.observe`
  (`GENERATED_HIGH_ENTROPY`);
- escalates the candidate as a secret operation and **forces it into review** (`⚠ 密钥操作`), without
  aborting the agent.

`NEOKEY_*` tokens (the encrypted form of host secrets) are not counted as generated; they are handled
by `warn_for_files`. Generated keys in command output / tool arguments go through the existing
tokenization path (`tokenize_result`/`tokenize_args`).

### 16.2 Local SSH service access forbidden

Sandboxed processes may not use the host's SSH service (ssh-agent / sshd):

- **Agent/sshd paths masked** (`mask_paths` defaults): `/run/sshd`, `/run/sshd.pid`,
  `/run/ssh-agent.socket`, `/run/user/*/keyring*`, `/run/user/*/ssh*`, `/run/user/*/gnupg*`,
  `/tmp/ssh-*`, `~/.ssh`, `~/.ssh-agent`, etc. (agent sockets become character devices, so `connect`
  fails).
- **Environment cleared**: external commands are prefixed with `unset SSH_AUTH_SOCK SSH_AGENT_PID`
  (`runtime.proxy_unset_snippet` always emits it), so `ssh`/`git` cannot authenticate via the host
  agent.
- **Command-level hard reject**: `wrapper` rejects `ssh`/`scp`/`sftp`/`sshpass` or `ssh://` targeting
  the local machine (`localhost`/`127.`/`::1`/`0.0.0.0`/`169.254.`) with `SSH_LOCAL_SERVICE_DENIED`,
  recording evidence/event (raw TCP bypasses the proxy under a shared netns, so a command-level gate
  is required). Remote `ssh` is unaffected.
- Classification: `sshd`/`ssh-agent`/`ssh-add`/`ssh-keysign`/`gpg-agent` are T2 privileged (host
  effects require approval).

## 17. Privilege tiers and auto-escalation

By default every external command runs with **least privilege**; when it lacks privilege the
sandbox **automatically requests an escalation** (recorded, never silent) and tightens review
per tier. Core modules: `sandbox/privilege.lua` (classify/resolve/record) and
`sandbox/hostop.lua` (T2 host-effect proposals).

### Tiers

| Tier | Name | Use | Isolation | Review |
|---|---|---|---|---|
| **T0** | minimal | normal commands | full capabilities by default (`cap_add={ALL}`) minus host-global capabilities (`cap_drop`: network/clock/modules/raw I/O/boot/MAC/audit) + seccomp (incl. device-node barrier) + masks + **network allowed by default (host-local intercepted via host_proxy, see §6.1)** | no per-command review; fs changes enter the pending queue |
| **T1** | elevated | network access, controlled docker, package installs | runs isolated, network allowed; when `cap_add` is narrowed, package installs (whole command being package managers) get narrow caps via `packages.cap_add`; docker.sock is unmasked only for docker commands | auto-authorized, recorded; fs changes enter the pending queue |
| **T2** | privileged | cap_add, host sockets, host mounts | runs inside a **nested userns** with full capabilities (caps scoped to the userns, cannot reach the host; the seccomp baseline still applies) | host effects frozen as a **proposal**, replayed after async approval |

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

### 17.1 Non-root payload, overlay write probing and write escalation

**Non-root by default** (`tools.sandbox.run_as`): sandboxed processes run as a non-root user with
`--cap-drop ALL` (least privilege). When NeoAI is launched as non-root the current uid is used and
`--unshare-user --uid/--gid` switches to it inside the user namespace. When launched as root the
configured dedicated non-root uid is used (default nobody 65534): **bwrap itself still runs as root**
(so it can create mountpoints and mount overlay under 0700 dirs such as `/root`), and only the
**payload** is dropped via `setpriv --reuid/--regid` — the payload is non-root both on the host and
inside the namespace, with no capabilities (NoNewPrivs set by bwrap prevents setuid/file-cap
elevation). Do not use `bwrap --uid N` (as root it maps guest N to host root, i.e. a root disguise).
Writable sandbox dirs (overlay upper/work, staging, session) are chowned to that uid.
> Boundary: a non-root payload's **absolute-path** access to 0700 dirs (e.g. `/root`) is still
> limited by DAC (`cwd`/relative paths work); when launching as root, place the workspace /
> `workspace_root` where that uid can traverse (e.g. `/home/<user>`).

**Overlay write probing**: `runtime.overlay_writable(lower, upper, work)` probes a real
write-read-delete with the real execution path and payload uid, cached by
`(lower, upper.dev, uid, gid)`. Mount success does not imply writability (non-root plus upper
ownership/DAC can yield EROFS/EACCES), so overlay is used only when it both mounts **and** writes;
otherwise it degrades to a bind-mounted private writable dir. Diagnose via `:NeoAISandboxCaps` /
`runtime.overlay_diagnosis()`.

**All writes staged + privilege-first publish**: command writes always go to the overlay/staging
(never the real disk). The actual publish (CAS) goes through `sandbox/writer.lua`: it first attempts
as the non-root payload (the root process drops via `setpriv`), yielding `writer=nonroot`; on a
permission error (EACCES/EPERM/EROFS) it returns `NEEDS_ROOT`, and `review.apply` marks
`apply_state=NEEDS_ROOT` and queues it in `:NeoAISandboxReview` (no auto-escalation). After the user
confirms (`allow_root=true`), the plugin writes as root if it is root, otherwise via `sudo`
(inheriting the tty); the receipt records `writer`/`escalated`. The baseline is re-verified before the
escalated write (TOCTOU).

**All-tier auto-escalation**: on a permission/network failure (`operation not permitted` /
`permission denied` / `read-only file system` / network unreachable, etc.) **any** tier can escalate
(T0→T1→T2 up to `privilege.max_tier`) and re-run in isolation; each step writes a `privilege`
evidence record, emits `SANDBOX_PRIVILEGE_ESCALATION_REQUESTED` and `audit.observe`s it — never
silently.

## 18. Security grading, controlled containers and behavior audit

### 18.1 Approval graded by security level (`sandbox/risk.lua`)

Every effectful call is graded L0-L3 and shown in the review UI with a colored `[L0]`-`[L3]`
badge, recorded as evidence (`kind="risk"`) and emitted as `SANDBOX_RISK_ASSESSED`:

| Level | Meaning | Triggers (max wins) |
| --- | --- | --- |
| L0 low | Routine, reversible, inside workspace | Workspace writes, reads |
| L1 moderate | Network, package install, T1 | Network, `apt/pip/npm…`, T1 |
| L2 high | User/system path write, T2, dangerous command, **secret op inside workspace** | `~`/system path writes, T2, `chmod -R 777`, `systemctl`, in-workspace secret op |
| L3 critical | **Secret op outside workspace**, host effect, destructive command | Out-of-workspace secret op, host ops, `rm -rf /`, `curl … | sh` |

`risk.action(level, opts)` returns `auto` / `record` / `review` (async, non-blocking) / `block`.
The default is `default="review"` (unchanged semantics); override per level via
`tools.sandbox.approval.levels`.

- **Dedicated package-manager detection + L2 cap**: `apt`/`apt-get`/`dnf`/`pacman`/`pip`/`pipx`/
  `uv`/`poetry`/`conda`/`mamba`/`npm`/`npx`/`pnpm`/`yarn`/`bun`/`cargo`/`go`/`gem`/`composer` etc.
  (`tools.sandbox.packages.managers`) are uniformly recognised as package installs (T1 + network +
  writable package state roots + root capabilities). Additionally, **changed-path signatures**
  (`privilege.package_path_manager`) recognise `node_modules`, `site-packages`/`dist-packages`,
  `/var/lib/apt`, `/var/lib/dpkg`, `~/.cargo`, `~/.npm`, `conda/pkgs`, `/var/lib/gems`, … as
  "modified by a package manager". Package installs are high-risk but not critical: their state
  files live outside the workspace and often contain high-entropy GPG signatures/hashes, so they
  must not be escalated to L3 by "outside-workspace write / secret false positive"
  (`risk.classify` caps `package` at L2 and skips secret detection for package state files); L3 is
  kept only when the command itself matches a destructive pattern (`rm -rf /`, `mkfs`,
  `curl … | sh`, …).

- **Write protection first**: file changes always go through the staging layer, so **process
  privilege escalation is record-only** (evidence + `SANDBOX_PRIVILEGE_RECORDED` + audit) for later
  anomaly analysis, not a blocking gate. T2 host effects are still frozen as proposals (§17).
- **Pause only when necessary**: in the default async mode the agent is never paused; only actions
  that truly need human judgement (masked-dir hits, `block` level) block or are rejected.

### 18.2 Security level from command execution results

After an external command, `risk.from_result({code,stdout,stderr})` parses result signals
(permission denied → L2, network failure → L1, package changes → L1, destructive output → L3),
takes the max with the pre-call grade, records evidence and drives auto-escalation detection (§17).
Read-only process tools record result grading too.

### 18.3 Controlled container runtimes (`sandbox/container.lua`)

When the AI invokes a container runtime, the sandbox tries to keep the container in the **same
namespace** as the sandbox:

- **Daemonless runtimes** (`podman`/`buildah`): the CLI runs inside the sandbox and the container is
  its child; the command is rewritten to inject `--net=host --pid=host --ipc=host --uts=host`, so the
  container reuses the sandbox's pid/net/ipc/uts namespaces and is confined by the sandbox boundary
  (`tools.sandbox.container.share_namespace`, default on).
- **Daemon-backed runtimes** (`docker`/`nerdctl`): containers are created by the host-side daemon and
  cannot reuse the sandbox namespace; the controlled-socket scheme is kept (§17) and the reason
  `DOCKER_NAMESPACE_NOT_SHARABLE` is recorded.

The plan is stored as `kind="container"` evidence and emits `SANDBOX_CONTAINER_PLANNED`.

### 18.4 Auto-approval for new sessions (default off)

`tools.sandbox.review.session_auto_approve` (default false): when on, L0/L1 risks auto-apply while
L2+ and packages/secrets still require review. This lets even a local model manage agent behavior
under write protection. Toggle at runtime with `:NeoAISandboxAutoApprove [on|off|status]`.

### 18.5 Extra rules for package installs

Package installs (`apt/pip/npm/go/cargo/gem/composer…`) are classified as `package` (T1, network).
`tools.sandbox.packages.mode`: `review` (default, forced review, **not auto-approved by session
auto-approval**), `allow`, or `deny`. Their writes still go through staging.

### 18.6 Full sensitive-info redaction and behavior audit

- **Named sensitive rules** (`sandbox/secret.lua` `rules`/`extra_rules`): beyond entropy, Lua
  patterns detect private-key blocks, `AKIA…`, `ghp_…`, `sk-…`, `xox…`, JWT, `Bearer`/`Basic`, etc.,
  tokenizing them (losslessly restorable) and recording traces. `secret.redact()` offers destructive
  redaction for logs/evidence and emits `SANDBOX_SENSITIVE_REDACTED`.
- **Behavior audit** (`sandbox/audit.lua`): records read/call/process/network/secret/privilege/
  container/package observations, accumulating a weighted risk score and anomaly count;
  `:NeoAISandboxAudit` shows the summary. High-risk observations emit `SANDBOX_AUDIT_ANOMALY`.

### 18.7 Commands and events

- Commands: `:NeoAISandboxAudit`, `:NeoAISandboxAutoApprove [on|off|status]`.
- Events: `SANDBOX_RISK_ASSESSED` / `SANDBOX_RISK_BLOCKED` / `SANDBOX_AUDIT_OBSERVED` /
  `SANDBOX_AUDIT_ANOMALY` / `SANDBOX_CONTAINER_PLANNED` / `SANDBOX_SENSITIVE_REDACTED`.
- Tests: `lua/NeoAI/tests/test_sandbox_governance.lua`.
