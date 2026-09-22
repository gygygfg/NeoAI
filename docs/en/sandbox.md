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
| `sandbox/disk.lua` | Sandbox staging disk usage measurement and cap gate (async cached; rejects write/process tools when over) |
| `sandbox/background.lua` | Background-command detection (`&`/nohup/setsid) for gate promotion to a long-lived service |
| `sandbox/seccomp.lua` | seccomp capability probe and require_seccomp gate |
| `sandbox/cache.lua` | Content-addressed cache (isolated writes, prunable) |
| `sandbox/diag.lua` | Fault injection (backend/freeze/publish/store) and critical-path benchmarks; merges former `fault`+`bench` (old files are compat shims) |
| `sandbox/tool_spec.lua` | Per-tool effect class and staged path declaration |
| `sandbox/wrapper.lua` | Enforcement gate: `attach` specs, `gate` all executions |
| `sandbox/risk.lua` | Security-level assessment (L0-L3), graded approval action, result grading |
| `sandbox/script_scan.lua` | Static scan of indirect script execution (shell bodies + embedded shell in high-level languages, recursion, opaque detection) |
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
- **The review queue is authoritative in memory**: historical change sets are hydrated from disk
  on first access; afterwards `list` / `pending_summary` read memory only instead of rescanning the
  whole `reviews/` directory on every call. Otherwise, once pending reviews pile up into the
  hundreds/thousands, `supersede_by_paths` (every tool call) and statusline badge refreshes degrade
  into O(n²) disk scans that saturate the main thread. Statusline refreshes
  (`services.status`) are also coalesced per tick so hundreds of events in one tick cause a single
  redraw rather than hundreds. Candidate deletion during supersede/merge uses a **batch delete**
  (`_discard_candidates` counts references once, then deletes each), instead of one full-table
  reference scan per superseded item (avoiding O(n²) when superseding many same-path items).
- **Capture/materialize with many staged files does not saturate the main thread** (regression:
  after staging tens/hundreds of files, `run_command` completion stalls):
  - **Unchanged detection runs on the worker (by signature, no re-hashing)**: `materialize_overlay`
    records the mtime/size signature (`dsig`) of the bytes it wrote; `capture_overlay` walks the
    overlay in the thread pool and compares the signature first, **skipping unchanged materialized
    files outright** (no file read, no pure-Lua SHA); only files whose signature changed become
    candidates. Previously every materialized file was read whole and pure-Lua SHA-256 hashed at the
    end of every command, which pinned a single `libuv-worker` core and stalled `run_command` once
    thousands of files were staged. Deletion reconciliation (a sandbox-only file removed by the
    command) is also done on the worker.
  - **Chunked parallel freeze/capture/secret scan/staging write**: `finish_async`,
    `capture_overlay_async` base hashing, batch secret tokenization, candidate secret analysis, and
    the staged-copy writes in `merge_candidate_async` all dispatch in chunks of
    `tools.sandbox.work_chunk_files` (default 128) to the thread pool; tokenization unifies
    equivalent tokens for the same secret across chunks to a canonical token (so `detokenize`
    round-trips). This uses multiple cores on workloads such as npm/cargo that produce tens of
    thousands of files, instead of single-core serialization. Each staging-write chunk is encoded
    lazily inside `work.batched`'s start callback, overlapping with the previous group's writes; the
    worker caches directories to avoid repeating `fs_mkdir` for every path segment per file.
  - **Command-captured files skip redundant materialization**: the command already wrote the
    content into the overlay (the capture source is `dest`), so `merge` only registers the staging
    copy and marks it `fresh`; the next materialization skips the detokenize write-back (invalidated
    if the staging copy is later edited), avoiding rewriting every changed file on each command.
  - **Package/generated content skips secret scanning**: when the command is classified as a package
    install, or candidate paths hit package directories (`/site-packages/`, `/node_modules/`,
    `~/.cargo/`, ... via `privilege.package_path_manager`), secret tokenization and generated
    high-entropy analysis are skipped (consistent with `is_pkg` at settlement). This avoids
    per-file full-text scanning of venv/dependency trees (measured: post-processing after
    `python -m venv` drops from ~3s to ~0.3s).
  - **Review items do not duplicate content on disk**: candidate content is already persisted with
    the candidate, so the review item strips `files[].content` when persisted (rehydrated items read
    it from the candidate by `candidate_digest`), avoiding a second main-thread JSON encode of large
    candidates.
  - **Result risk scan is windowed**: `risk.from_result` only scans the first/last
    `tools.sandbox.risk.result_scan_bytes` (default 256 KiB) bytes of output, so large `timeout=-1`
    outputs cannot freeze the UI with a full main-thread lowercase + pattern scan.
  - **Write-journal incremental capture** (`tools.sandbox.journal_capture`, default auto): drives
    capture from the eBPF-observed write/delete paths of this command, **processing only those paths**
    (`_capture_worker` path-driven branch) instead of walking the whole session-accumulated overlay
    upper; `_encode_expected`/`_encode_ws` also encode incrementally by these paths. Effective only
    when observation is trusted (eBPF + ready before the command + drained + all absolute paths +
    non-empty journal), otherwise it falls back to a full walk (correctness first). Measured: with
    3000 accumulated files and a single-file write, capture drops from ~10ms to <1ms.
  - **Materialize skips unchanged entries by staged version**: each staged entry carries a version
    that is bumped on edit/merge/delete; materialization records the version last written per
    overlay/bind base and **fully skips** an entry whose version matches (no `fs_stat`, no read, no
    write). Previously every `run_command` start iterated all staged entries and did two `fs_stat`s
    plus string formatting per entry, which was the main-thread stall at command startup once
    thousands of files were staged; unchanged entries now cost only a version comparison. When the
    staged copy and target (mtime/size/mode) are both unchanged it also avoids re-read + detokenize +
    write. Only when the upper is externally cleared (e.g. `_wipe_upper` before an LSP overlay
    refresh) is `materialize_overlay(specs, { force = true })` used to force a full rewrite.
  - **No fsync for overlay scratch**: the per-session overlay upper is ephemeral scratch (rotated on
    agentEnd), so `write_file_atomic(..., { sync = false })` drops the per-file fsync; real workspace
    publishing still fsyncs for durability.
  - **Evidence carries no file content**: `evidence.add("fs", ...)` stores only the impact manifest
    (path/action/hash) and caps the file-entry count, avoiding another huge JSON encode for large
    candidates.
  - **Generated high-entropy detection is budgeted**: `detect_generated` is bounded by
    `tools.sandbox.secrets.generated_scan_max_bytes` / `generated_scan_max_files` so a large
    candidate is not scanned file-by-file full-text.
  - **Settle is asynchronous**: candidate/review/snapshot **file writes** run on the thread pool
    (`store.write_candidate_async` / `write_review_async` / `write_snapshot_async`, per-path
    serialized write-behind), and secret analysis (NEOKEY warnings + generated high-entropy) also
    runs on the worker (`secret.analyze_files_async`); the main thread only does JSON encoding and
    aggregation. Candidates rewritten by merge / content-split / selective-apply reordering, and
    snapshots (which carry original file content for save/undo-save), no longer encode + fsync
    synchronously on the main thread. An in-memory cache makes a just-written item immediately
    readable; it is dropped once flushed (bounded memory). `sandbox.shutdown` / `store.reset` call
    `store.flush()` first, so shutdown and reset lose no data and are not polluted by late writes.
  - **JSON encoding no longer deep-scans the main thread**: `json.encode_fast` uses `vim.json`
    (C implementation) directly, skipping the pure-Lua whole-table UTF-8 deep scan in
    `_sanitize_value` (the main freeze source for large candidates). Before persisting, a C-level
    `string.find("[\128-\255]")` check lets **pure-ASCII output (the common case) skip** thread-pool
    UTF-8 validation entirely; only output containing non-ASCII bytes is validated on the thread
    pool, and only invalid output falls back to `json.encode` (sanitize + re-encode). This avoids a
    1M-entry candidate/review JSON (~230MB) byte-by-byte scan occupying 10–30s of the thread pool
    and starving capture/finish/tokenize. Candidate/review/snapshot persistence all use this path.
  - **Merge writes are chunked and parallel**: `merge_candidate_async` splits tokenized staged
    copies into `work_chunk_files` chunks and writes them (including mkdir/chmod) concurrently on the
    thread pool; each chunk is encoded lazily and overlaps the previous group's writes. The main
    thread only registers mappings and `fresh` signatures, so thousands/millions of files are no
    longer written single-threaded.
  - **Capture workspace-consistency check runs in the worker**: `_capture_worker` receives the
    workspace staging map and compares, in-thread, whether a command change merely reproduces a
    staged edit; the main thread no longer re-reads two contents per changed file.
  - **Batched chunk-job submission**: `work.batched` keeps at most
    `tools.sandbox.work_parallelism` (default 4, matching the libuv pool) in flight per batch, so
    hundreds of chunk jobs cannot flood the queue and starve later UI-critical jobs
    (redaction / secret tokenization / disk writes).
  - **Session rotation migration runs on the thread pool**: `rotate_session` hands the file copies
    (including directories) to a worker; staged access waits via `_await_rotation` for the
    migration to finish (usually already done, so the wait is 0). At agentEnd, long sessions with
    many unpublished changes no longer copy file-by-file on the main thread.
  - **Incremental pending index**: `review._pending_items` caches PENDING items (sorted by
    created_at); `supersede_by_paths` / package merging no longer filter + sort **all** change
    units (including terminal ones) on every call; any write invalidates the cache.
  - **Settlement main-thread hotspots batched / single-pass (10k staged-file regression)**:
    - `risk.classify`'s `path_level` no longer re-canonicalizes `cwd`/`~` per path (cached by cwd)
      and walks `facts.paths` only once (also deriving "write outside workspace" for secret
      grading), eliminating tens of thousands of Vimscript round-trips.
    - `secret._merge_chunk_results` rewrites outputs **single-pass** over the token pattern
      (previously one full-text `gsub` per remap entry, roughly quadratic within a chunk).
    - `review.apply_all` discards candidates via a **batched reconciliation**
      (`_defer_discard` + `_discard_candidates`) instead of a full-table reference scan per item
      (avoiding O(n²)).
    - `privilege.package_path_manager` scans each candidate only once (cached per attempt),
      replacing the three duplicate full scans in secret analysis / merge / settlement.
    - `wrapper._rewrite_value` uses a staging-root prefix guard: when a result string contains no
      staged path it skips the per-entry `gsub` entirely (previously O(strings × staged files)).
    - `candidate.capture_overlay_async` scopes the workspace staging encoding to the **capture
      root**; `_capture_entry` reads the per-file size cap once outside the loop.
    - `candidate.merge_candidate_async` returns post-write signatures (`fresh_ssig`) from the
      worker, so the main thread no longer `fs_stat`s every staged file.
  - **Cancel/timeout/output-truncation truly kill the process tree**: the bwrap payload runs in
    its own PID namespace, so `jobstop` only kills the outer bwrap. The gate exposes `cgroup.kill`
    via `ctx.sandbox_kill`; `run_command` / tool subprocesses precisely kill the whole resource
    domain on cancel, timeout, or output truncation (falling back to `jobstop` when no cgroup).
  - **Wall-clock safety net**: `tools.run_command.max_wall_ms` (default 0 = unlimited) > 0 bounds
    every command (including `timeout_ms=-1` "unlimited" ones); on expiry the resource domain is
    killed, so long tasks cannot occupy resources forever or leave the tool never returning.
  - **Benchmark**: `require("NeoAI.sandbox.diag").bench_capture({ files = N })` returns
    materialize cold/warm and capture main-thread timings for regression comparison (resets the
    sandbox; diagnostic only).
- **Model visibility**: the tool result is returned to the model **unchanged**, with no
  "staged/awaiting review" note, so the AI believes the change completed. Pending state is
  surfaced to the user only via a **prominent statusline badge** (the `sandbox` part shows a
  bold yellow `待审N` only when pending reviews > 0, see [configuration.md](configuration.md)).
- Async confirmation commands:
  - `:NeoAISandboxReview` — open the review UI (`ui/components/sandbox_review.lua`), which
    highlights files by path level — **workspace=green, user directory=yellow, system=red** —
    with the `待审` state label **colored by security level** (L0 gray / L1 yellow / L2 orange / L3 red),
    and shows a **high/medium/low** risk grade (`[L0]低危` …
    `[L2]/[L3]高危`) plus risk reasons (duplicate categories are **merged and counted**, e.g.
    `SYSTEM_PATH_WRITE×2797`, so package installs do not flood the view per file; `sandbox/risk.lua`
    already dedupes by category at the source). Risk badges are colored **L0 gray / L1·L2 yellow /
    L3 red** — only L3 uses the red danger highlight. Items are **sectioned into "unapplied" and
    "applied"**: pending (unapplied) changes come first, already-published (snapshotted, revertible)
    changes after. **The header line approves the whole change set**
    (`<CR>` applies every file in it), while a **file line approves a single file**
    (`<CR>` applies only the file under the cursor); `A` **approves every workspace change in one
    key** (applies workspace-scoped pending files at file granularity; files outside the workspace and
    host-operation proposals stay pending for individual review, and root-requiring items prompt for
    per-item escalation). Batch application **yields to the main loop between items** (each change set
    is followed by `vim.defer_fn` back to the event loop, with `应用中 i/N` progress in the title) and
    reuses a batch session (`sandbox.begin_batch`/`end_batch`) to reconcile candidate deletion once,
    avoiding a synchronous for-loop + per-item O(n) full scan + per-file writes freezing the UI
    ("approving too many at once hangs"); pressing `A` again while running is refused; `d` rejects that file (on the header, the
    whole unit), `i` temporarily closes the review window and opens a **diff preview** of that
    item (`q`/`<Esc>` closes it and returns to the review window with the cursor restored); on an
    **out-of-bounds access trace** line, `i` opens the **access details** for that path (each access's
    tool / kind / command / time; not an approval target),
    `u` **undoes/redoes the save**, `q`/`<Esc>` closes. **While open, the window subscribes to sandbox
    broadcast events and refreshes automatically** (enqueue/apply/reject/revert, out-of-bounds traces,
    host operations; multiple events in the same tick are coalesced into one redraw) — no manual
    refresh. **The "applied" section is
    collapsed by default** (whole section collapsed via `za`/`zo`, then each item collapsed again);
    **a pending item shows its header line with the rest folded** (the header — tool / risk badge /
    file count / `待审` — stays visible and is the whole-unit approval entry; the secret warning, risk
    reasons, git hint and file list start collapsed, `za`/`zo` expands), avoiding a flood from package
    installs or git operations with up to thousands of files; the out-of-bounds trace section does not
    fold. Inside the chat main window
    press `<leader>ap` to trigger it (`keymaps.chat.sandbox_review`).
    - **Show saved / undo save**: applying (saving) keeps a **snapshot of the original file** (its
      content before the apply). The review window's "已应用（已保存/已撤销，u 撤销/重做保存）" section lists
      changes already published to the real workspace; pressing `u` on an item **swaps** the real file
      with the snapshot — saved → undone (rolls back to the pre-apply content), undone → saved again,
      toggling repeatedly. A CAS check runs before the swap: if the real file was changed externally
      (hash mismatch) the operation is refused with `CONFLICT`, never overwriting user edits. Snapshots
      live in the per-process instance store (`snapshots/`) and are reclaimed with the instance dir.
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
      package-install writable roots (`tools.sandbox.packages.roots`: `/usr`, `/var`, `/etc`,
      `~/.cache`, `~/.npm`, `~/.nvm`, `~/.cargo`, `~/.rustup`, `~/go`, `~/.local`, …) as writable
      roots staged via overlay, so `apt update`/`apt install`/`pip install`/`npm install`/`nvm
      install` can write indexes/caches/metadata **and install targets** (`/usr` covers `/usr/bin`,
      `/usr/games`, …; `/var` covers dpkg/apt state, man caches, …; `/etc` covers dpkg postinst
      config writes such as libc-bin refreshing `/etc/ld.so.cache` — under a read-only root these
      fail with `Read-only file system` and leave dpkg with a non-zero exit code); those writes are
      frozen as candidates too and the real disk is unchanged. Sensitive `/etc` entries
      (shadow/sudoers/ssh/cron, …) remain masked by `mask_paths`. The
      on-demand capability grant (`req.package`: granted when **any segment** matches a package
      manager) adds back the narrow capabilities listed in `tools.sandbox.packages.cap_add` —
      chained commands such as `apt-get install …; echo; tail` qualify too (otherwise apt cannot
      chown/setuid to `_apt` and fails). Writes still all go through overlay staging and sensitive
      paths are protected by mask mounts, so a mixed command inheriting narrow caps does not widen
      the host surface. Because `--cap-drop ALL` removes `CAP_DAC_OVERRIDE`
      (root cannot even write `_apt`-owned 0700 dirs), package installs add back
      `CAP_DAC_OVERRIDE`/`CAP_CHOWN`/`CAP_SETUID`, … (**no `CAP_MKNOD`** — device nodes are
      hard-blocked by the seccomp baseline, see §6); if the payload is dropped to a dedicated
      non-root uid these narrow caps are preserved as **ambient**, otherwise changing the uid
      clears them and package-install locks fail. The process still runs under the
      mount/pid namespace + seccomp + whole-root overlay + masking + staging.
    - **Oversized files are captured as blobs** (`tools.sandbox.max_file_bytes`, default 8 MiB):
      files above the cap do not embed their content in candidate JSON; the staged copy is copied
      into the sandbox store's `blobs/` directory and the candidate entry records only the `blob`
      path plus a **stat signature** (`sig:mtime:size`). Publish/materialize/staging-merge then
      **copy the file** (kernel `copyfile`, never read into Lua memory), so libraries like torch's
      `libtorch_python.so` (tens to hundreds of MB) land intact instead of leaving an incomplete
      venv after a package install. Oversized files get **no base content hash** (they never enter
      the base-hash list); publish CAS uses the stat signature. Blobs live under the instance store
      and are cleaned by `store.reset` / instance GC. Undo snapshots of edited large files remain
      bounded by the cap (see "Undo save").
    - **The same file is never processed twice (capture signature cache)**: every async capture
      records the **target signature** (mtime/size) of each overlay entry it processed (file /
      delete / oversized) in that upper's expected map; the next capture compares signatures
      **inside the worker** and skips unchanged entries entirely — no record emitted, no base hash,
      no main-thread work. Only genuinely changed (or externally modified) files are reprocessed.
      Previously every `run_command` re-read and pure-Lua-hashed the same captured files (including
      hundreds of MB of chromium/npm caches), showing up as a long stall after the command
      completed; the map is cleared on session rotation.
    - **Chunked parallel freeze** (`tools.sandbox.work_chunk_files`, default 128): `finish_async`,
      batch secret tokenization and staged-copy writes in `merge_candidate_async` dispatch in chunks
      of this many files concurrently to the thread pool, using multiple cores instead of
      single-core serialization on many-file workloads.
    - **Staged content is persistent**: `PENDING` and `APPROVED` (not yet applied) candidates are
      **re-materialized** from disk by `_rehydrate_pending` after a reload/restart, so large
      staged content such as package installs stays readable until applied or rejected and is not
      destroyed by session rotation/exit.
    - **Per-nvim-process isolation**: each nvim process uses its own instance store root
      `<workspace_root>/instances/<pid>_<started_at>`; the pending queue, candidates, receipts and
      evidence are **not shared** across processes — with two sessions open, neither sees the other's
      approvals, and closing one only cleans up its own staging without disturbing a running agent in
      another. Within a process a hot reload keeps the same instance id, so that instance's pending
      queue and staged candidates survive; instance directories left by dead processes are reclaimed
      asynchronously by `sandbox.instance.gc` after the next start (never blocking startup).
    - **High-risk second confirmation** (`tools.sandbox.review.l3_warning.enabled`, on by default):
      for items with `risk_level=3`, and for **L2 package/sensitive installs** (`package_confirm`,
      on by default; e.g. `apt-key`, `gpg --import`, repo changes), the first `<CR>` does **not**
      apply directly. Instead the model (`sandbox/l3_warning.lua` via `core/agent/request`) generates
      a short consequence warning and the item's **diff** opens automatically with the warning shown
      at the top (a placeholder is shown while generating). The confirm window title is level-aware
      (`⚠ L2 high-risk · Confirm apply` / `⚠ L3 critical · Confirm apply`) and the key-hint line is
      highlighted; when files were dropped at freeze time the warning block appends
      `ℹ N masked/cache files will be skipped (not written to host)`. Press `<CR>` again inside the
      diff to actually apply, or `q`/`<Esc>` to cancel and return. When the model is unavailable,
      times out, or no provider is configured, it falls back to a deterministic rule-based warning
      built from `risk_reasons`/paths and does not block the flow. Safe installs (L1) still need only
      one confirmation.
    - **AI audit** (`tools.sandbox.review.ai_audit`, on by default, press `a` in the review UI;
      `key` is configurable): builds a **structured text** from the source session's **user
      messages** (excluding runtime-context snapshots and compaction checkpoints) plus the
      **risk-graded pending changes/modifications** (`sandbox/ai_audit.lua`: change-set id, tool,
      privilege tier, risk level and reasons, secret/package/command info, per-file diffs) and asks
      the model for **one ≤50-character Chinese risk note per file (or host-op command)**. Each
      note **leads with a safe/unsafe verdict** — it must start with `安全` or `不安全`, followed by
      the main reason. Notes are rendered as **dark-gray supplementary lines directly under the
      corresponding file line** (the model outputs `<path or command> => <安全|不安全>：<note>` per
      line; `parse_notes` parses and truncates to 50 chars, with a whole-output fallback when the
      format is not followed); the window top first renders an **overall verdict**
      (`ai_audit.verdict`: any note judged unsafe → red `不安全`, otherwise green `安全`). Pending
      changes are **fed to the model highest-risk first**, and high-risk (L2/L3) changes are never
      omitted, so their notes survive total-length/output truncation. **Every item is audited**: an
      item the model misses is marked with a red "（AI 未给出说明，请人工确认）" under its line. A short
      dark-gray status line at the top shows generating/failure. The audit **never posts to the chat UI and never
      applies or rejects** any change; the user remains in control via the review UI. The review
      window has soft wrapping on by default (`wrap`/`linebreak`). Diffs / user messages / total text
      are truncated by `max_diff_chars` / `max_user_chars` / `max_total_chars`, and output/timeout are
      bounded by `max_tokens` / `timeout_ms`; with `enabled=false` the key is not registered. The
      global concurrency cap `max_concurrent` (default 10) queues excess in-flight audit requests
      FIFO, avoiding a request storm when auto fires frequently.
      **Auto audit** (`ai_audit.auto`, default `false`): when enabled, opening the review UI runs the
      audit automatically and re-audits when the pending set changes; `key` (default `a`) still
      triggers it manually.
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
- **Unpublishable files dropped at freeze**: before building the candidate, `candidate.finish`
  drops two kinds of files so a single one cannot fail the **whole** change set (e.g. a package
  install rolling back because an apt index baseline changed):
  1. **effectively masked paths** — decided via the attempt's `effective_unmask` (tier escalation +
     approval unmask + writable roots); paths lifted by unmask are kept;
  2. **volatile package indexes/caches** — `tools.sandbox.packages.volatile_paths` (defaults include
     `/var/lib/apt/lists`, `/var/cache/apt`), applied only to package candidates. These are
     regenerated by the package manager at any time, so their baseline usually changed by apply time
     and would trigger `CONFLICT/BASELINE_CHANGED`; dropping them does not affect the install
     (`/var/lib/dpkg/status`, package files, etc. still apply) and the host can rebuild indexes with
     `apt update`.
  The dropped count is recorded on the candidate's `dropped` field and surfaced in the review UI;
  the publish-time masked hard reject remains as defense in depth.
- **Same-file supersede**: when the same file is edited again (a new candidate is enqueued) or
  published directly, older `PENDING` change sets covering that path are marked `SUPERSEDED` and
  their candidates discarded, so the queue keeps only the latest version
  (`review.supersede_by_paths`).

### Static scan of indirect script execution (`tools.sandbox.script_scan`, on by default)

When a command delegates execution to a script/interpreter, the command string itself hides the
real operations (`bash deploy.sh`, `python setup.py`, `node x.js`, `./run.sh`, `bash -c '…'`,
`python -c '…'`). Before execution, `sandbox/script_scan.lua`:

- detects interpreter invocations and directly-executable scripts (language from the shebang),
  including `source`/`.` references;
- reads the script content (**preferring the sandbox staging copy**, so scripts created/modified by
  the AI in this session are scanned too; host-sensitive masked paths are not read and are marked
  opaque instead);
- reads **regular files only**: character/block devices, FIFOs and sockets pass `filereadable()` yet
  `read("*a")` would block or yield unbounded content (e.g. `head -c … /dev/urandom | base64` used to
  read the device until timeout, stalling a single command for seconds with OOM risk), so they are
  treated as unreadable and marked opaque; shebang detection reads only a bounded head;
- for shell scripts takes the comment-stripped body; for Python/Node/Ruby/Perl/PHP extracts the
  string literals of shell calls (`os.system`/`subprocess.*`/`child_process.exec`/`system`/
  backticks/`%x{}` …);
- recursively scans referenced scripts (bounded by `max_depth`/`max_files`/`max_bytes`, cycle-safe).

The folded `effective` text feeds `risk.deny_reason` (hard deny), `privilege.classify` (tier/package
detection) and `risk.classify` (security level), so `pip install`, `sudo modprobe` or
`mkfs.ext4 /dev/sdb1` inside `bash deploy.sh` are no longer missed:

- device-level/kernel commands inside scripts are **hard denied** (same rule as direct commands);
  pure file modifications such as `rm`/`rm -rf` are not hard-denied (the read-only root + overlay
  staging already protect the host) — their effects freeze as candidates pending review;
- other hits (package installs, `systemctl`, `chmod -R 777`, …) raise the level and **force
  review** — never auto-applied via `mode=commit`, task grants or session auto-approval;
- indirect execution that cannot be statically resolved (`eval`, `base64 -d | sh`, `curl … | sh`,
  `python -m`, dynamic `-c "$VAR"`, unreadable/oversized scripts) is marked **opaque**, raised to L1
  (`OPAQUE_SCRIPT_EXECUTION`) and forced into review.

> This module is **static** analysis only. It does not trace at runtime: the sandbox seccomp
> baseline blocks `ptrace`/`bpf`/`process_vm_*`, so `strace`/eBPF are unavailable inside, and shims
> (`LD_PRELOAD`/PATH wrappers) are trivially bypassable by the AI. The robust dynamic signal is
> **effect observation** (overlay-captured real file changes, network targets, package-path
> detection), which complements this static scan.

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
    it to bypass the sandbox. Merge matching is normalized via `utils.fs.canonical` (symlink
    resolution, `..` folding), the **same key normalization as staging**, so accessing a file
    through a symlink/`..` path never falls back to the real view; `search_files` also drops all real
    results under a **staged-deleted directory**, so grep and `git_diff` (overlay view) cannot
    contradict each other.
  - Treesitter tools (`parse_file`/`query_tree`/`get_node_*`) read the staged copy: staged paths
    **keep the real basename (and extension)**, so filetype/parsers work; write tools such as
    `delete_node` modify the same staged copy and persist back to it (no double staging).
  - LSP tools share the same staged view as `run_command`/git readers:
    `tools.sandbox.lsp_overlay.enabled` is on by default; the AI-cloned LSP server process is placed
    in a bwrap + overlay (see below), so its disk reads see staged content (no longer the real disk).
    Before the clone is used, the **staged content** is pushed to it as a `didChange` (correcting the
    document text **without touching the user buffer**), so LSP and file tools agree on the same path.
    When a file has unpublished staged changes but the sandbox clone is unavailable, falling back to
    editor clients is **refused** (an explicit "sandbox LSP unavailable" is returned instead of
    silently reading the real view). LSP write tools (`lsp_rename`/`lsp_format`) always redirect their
    disk write to staging via `persist_buffer`.
  - **git read tools (`git_status` / `git_diff` / `git_log` / `git_branch` / `git_file_history` /
    `git_commit_detail`)**: executed inside the sandbox namespace (the same overlay as `run_command`),
    so disk reads see the **staged content**, not the real working tree. They run with
    `GIT_OPTIONAL_LOCKS=0` to avoid writing the index and are treated as read-only process tools that
    **do not capture candidates** or enter the review queue. The real working tree is never modified by
    git reads.
  - **`.git` changes are staged atomically into the review window**: `.git` is a tightly coupled
    "index ↔ object store ↔ refs" database — the index only records blob hashes while the actual data
    lives in `.git/objects/**`. Staging/publishing its files in arbitrary order could "save the index
    but lose the objects", producing dangling references (`fatal: unable to read <blob>`, i.e. a
    corrupted git index). So `.git` is handled with **atomic classification + ordered application**:
    - Freeze classifies each path via `runtime.git_path_class`: `object` (`.git/objects/**`,
      content-addressed, immutable, additive), `pointer` (index/HEAD/refs/logs/packed-refs, …),
      `transient` (`*.lock`/`gc.log`) and `other` (config/hooks/info). `transient`/`other` and
      **object deletions** (gc/prune pruning) are never candidates.
    - Application order is fixed to **objects → normal files → pointers** (`_apply_order`): any index/ref
      written references objects that already exist, so nothing dangles; objects already present are
      skipped idempotently by content address (no CAS). Hence the `.git` changes of `git_add` /
      `git_commit` / `git_stash` / `git_restore` / `git_rollback` enter the review window together with
      the worktree changes and are applied atomically on confirmation (`SANDBOX_GIT_INTERNAL` only
      backstops transient/config targets).
    - These git mutation tools run **inside the sandbox** (`effect=process`, seeing the staged
      worktree); their changes freeze as candidates and dry_run does not touch the real `.git`.
      git **mutation** subcommands inside `run_command` are refused by a guard
      (`SANDBOX_GIT_MUTATION_VIA_COMMAND`, `sandbox/git_guard.lua`) and must use those dedicated tools.
    - **The review window presents the operation as one group**: candidates touching `.git`
      objects/pointers are tagged as an atomic group (`atomic_group="git"` in `review`) and rendered
      as "git operation · N files · atomic group"; the header and every file line map to the **whole
      group** — `<CR>` approves and `d` discards the entire group, with per-file selective
      apply/discard forbidden (`apply`/`reject_file` also force the whole group), so an index or an
      object can never be written alone and corrupt the repository.
    - File-writing tools (`edit_file`, …) targeting `.git` are still refused outright (the AI should
      not edit repository internals directly).
- **Buffer-persist tools** (`delete_node`/`lsp_rename`/`lsp_format`): `tool_helpers.persist_buffer`
  redirects `:write!` to staging while the sandbox is active. **Reads never write back**: a buffer is
  saved only when a write tool explicitly modified it (`mark_edited`); read-only paths such as
  `ensure_buffer` loading and `sync_buffer_from_disk` **never trigger a save** — otherwise "nvim read
  it, then re-saved it" would re-encode the file as text and corrupt it. **Binary files** (NUL, or a
  high ratio of non-printable control bytes) are **never loaded into a text buffer and never written
  back** (`ensure_buffer` returns nil, `persist_buffer` returns `BINARY_SKIP`), so OpenPGP keyrings
  and the like are not damaged by U+FFFD replacement.
- **External processes** (`run_command`): with the bwrap backend, a set of **writable roots**
  (`tools.sandbox.process_roots`; default is only cwd, auto-added if not covered) are overlaid: the
  real root is the read-only lower, a session upper is the writable layer. The command can read real
  content under these roots, and creates/modifies/deletes at **any path** below them land in upper and
  are frozen as a candidate (deletions recognized via whiteout device nodes as `delete`/`rmdir`).
  - **Process commands run in parallel**: the gate for `effect="process"` tools (`run_command`, git
    read tools, …) splits locks by phase: the **setup phase** (`candidate.begin`/materialize/
    `resident.ensure`/prefix build) is serialized (avoids duplicate resident startup and interleaved
    materialization); **command execution** is concurrent (the resident command server multiplexes by
    id; one-shot processes each use their own attempt); **capture/freeze/merge/settle** is serialized
    (`_serialize_capture`, avoids overwriting each other's captures). The shared session state
    (overlay materialization/capture, staging map) is not concurrency-safe, so it is not made fully
    concurrent; concurrent commands' changes are attributed by **completion order** (the
    `state.materialized` destination signature makes a later capture process only not-yet-captured
    changes, so changes are neither lost nor duplicated). `read`/`fs_write`/`in_process`/`network`
    tools do not occupy the process slot.
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
  - **Every staged path is covered (no cross-root divergence)**: besides configured roots and cwd, the
    command's writable roots automatically include **the directory of every staged file**
    (`candidate.staged_overlay_roots`, nearest existing ancestor; paths already covered by a known root
    are skipped and returned roots never nest). Otherwise a staged edit outside the workspace is not
    materialized and the command reads the real disk — diverging from `read_file`/`list_files`'s staged
    view (one path, two contents) and bypassing staging to read/write real files. Long-lived services
    and tool subprocesses (`sandbox.exec`) are covered the same way.
  - **No degradation without an overlay**: when a command would run with **no overlay writable layer**
    (overlay unavailable and degraded to bind, or T2 nested userns with no overlay) and there is an
    **unpublished substantive staged change** (`candidate.has_staged`), execution is rejected with
    `SANDBOX_STAGING_UNCOVERED` — the command would only see the real disk, diverging from the read-only
    tools' staged view and bypassing staging. This tightens the existing `overlay_fail_closed` (which
    only rejected non-userns degradation): **with staging present, userns is not allowed either**.
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
    The reverse case (a command **reverts** the AI's staged edit, e.g. `git checkout -- <file>`) has a
    result equal to the real baseline, so it makes no net change to the real disk and yields no publish
    candidate; it is recorded separately as `view_files` to sync the staging view and supersede the
    path's pending candidate — otherwise the next materialization would overwrite the command result
    with the stale staged content, i.e. a "command write rolled back".
  - **Materialize type conflicts error out**: when a staged file's target is a **real directory** on the
    real disk/overlay (or vice versa), materialization would corrupt view consistency, so
    `SANDBOX_MATERIALIZE_TYPE_CONFLICT` is returned and execution is refused (`run_command`, tool
    subprocesses, long-lived services and the LSP overlay alike) instead of being skipped silently.
    The check uses `lstat` to inspect the path's own type: a symlink pointing to a directory (e.g. a
    venv's `lib64 -> lib`) is not a directory, can be safely unlinked and recreated, and is not a false
    conflict.
  - **File permissions are preserved**: candidates record the file mode and re-apply it when
    materializing into the overlay and when CAS-publishing (`write_file_atomic`'s `mkstemp` defaults to
    0600 and would strip the executable bit, breaking `venv/bin` scripts); new files use the ordinary
    0644 default, never a forced 0600.
  - **Directory consistency**: staged directories (`create_directory`/`ensure_dir`/`run_command`-created
    dirs) must be detected with `isdirectory`, never `fs.exists` (which is based on `filereadable` and
    is always false for directories). Otherwise session rotation would misread them as a missing staged
    copy, mark them deleted and materialize a whiteout, turning the directory into a device node/file
    in the sandbox view (`ls dir/: Not a directory`). File-writing tools (`edit_file` etc.) also reject
    directory targets (`SANDBOX_TARGET_IS_DIR`), and materialization guards against a file overwriting a
    directory; directories created by `create_directory` are materialized before command execution so
    `run_command` can see them.
  - **Deletion reconciliation**: when a command deletes a "sandbox-only" file (one that does not exist
    on the real disk and was produced only by an earlier command or staging), overlayfs creates no
    whiteout and the capture walk over the upper sees no entry. After capture, the wrapper reconciles
    against the paths this materialization wrote: gone from the upper **and** absent on the real disk →
    mark the workspace entry deleted and supersede the stale pending candidate for that path (net
    effect "no change"), so the next materialization cannot "resurrect" the old content (the symptom
    being a stale file, e.g. a command output `.out`, still readable after deletion).
  - The overlay base is generated by `sandbox.conceal` with a **featureless name**
    (`/dev/shm/.cache-<tag>`, no `NeoAI`/`sandbox` substring; must be outside the writable roots,
    otherwise upper-under-lower yields kernel `EINVAL`); falls back to the sandbox root when
    `/dev/shm` is absent.
  - **The sandbox's own store is hidden from commands**: the sandbox store base root
    (`tools.sandbox.workspace_root`, default `stdpath("cache")/NeoAI/sandbox`) and its `instances/`
    container are masked with an empty `tmpfs` inside the namespace, so a command cannot read or
    tamper with candidates, sessions, receipts and other internal state, nor enumerate another
    concurrent instance's pending content (prevents information leaks and escape).
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
  - **Rotation atomicity**: rotation does **not** immediately delete the old session directory.
    It is queued and cleaned up asynchronously in the thread pool once **no command is in flight**.
    The old session directory is the `--bind` mount source of running commands; deleting it
    immediately makes the mounted path suddenly `ENOENT`, which shows up as intermittent
    `cd: can't cd to ...` (a staging-filesystem atomicity/race).
  - **Only the main agent rotates**: sub-agents / auxiliary generations emit the same
    `GENERATION_*` events; while the current main agent is still busy, another agent's completion
    does not rotate, so the staging directory still in use by the main loop is never removed.
  - Staged content materialization (`materialize_overlay`) uses **same-directory temp file +
    atomic rename**, so commands running in parallel never read a half-written/missing file.
- **No path leaks**: staged paths in both success results and error messages are rewritten back to the
  real workspace paths (including read-only tools failing to read a deleted staged copy), so the model
  never sees sandbox-internal paths.
- **Hot-reload consistency**: `sandbox.shutdown()` clears the staging directory while the review queue
  and candidates stay on disk; the next `sandbox.init()` **re-materializes** both pending (`PENDING`)
  and approved-but-unapplied (`APPROVED`/`NOT_REQUESTED`) candidates into the new session's
  staging layer (`_rehydrate_pending`), so read tools see the same view as the review queue after a
  reload/reopen.

### Session-resident sandbox instance (`resident`, background processes)

- **Background**: with the resident instance off (`resident.enabled=false`), every one-shot command
  runs in its own pid namespace + cgroup, and on completion `cgroup.release` → `cgroup.kill`
  terminates the whole process tree; background processes do not survive across tool calls.
- **Resident instance**: with `tools.sandbox.resident.enabled=true` (default), `run_command` process
  commands in a sandbox session share one **long-lived bwrap instance** that runs a **command server**
  (bash reading requests from stdin) inside one persistent mount+pid+net+ipc+uts+cgroup namespace.
  Commands execute inside the server, so `&`/nohup/setsid background processes **survive across tool
  calls** and `ps`/`kill` see them within the session — close to normal bash (`sandbox/resident.lua`).
- **Concurrent execution**: the command server **multiplexes by request id** — each command runs
  independently under `setsid` in the background with output written to its own file, and on
  completion emits a `BEGIN/content/END` block atomically under `flock`; the client demultiplexes by
  id, so multiple commands in one instance **truly run in parallel** with non-interleaved output.
  Timeouts/cancellation are terminated inside the namespace by the server (per command process group;
  the host cannot `kill` a sandbox pid), and a terminated command still returns the partial output
  produced before termination. The setup/capture phases remain serialized (see "Process commands run
  in parallel").
- **Why a command server instead of nsenter**: bwrap's root view is applied by `chroot`/`pivot_root`
  on the **process** (`fs_struct`), not the mount namespace; an external `nsenter -m` only enters the
  mount table and cannot get that root, so exec fails with `No such file or directory`. The server
  executes commands **inside** the namespace and naturally has the correct root view.
- **Dedicated overlay**: the resident instance uses its own overlay base (`<proc_dir>/resident`), so it
  never competes with the one-shot process uppers (`<proc_dir>/<enc_root>`) — the same upper cannot be
  mounted twice. They sync through the candidate staging layer. The first start materializes workspace
  staging **before** mounting (host-side writes are safe); later AI edits are written back **inside the
  namespace** by `resident.materialize()` (writes go through the overlay mount, avoiding overlayfs'
  "host-side upper changes while mounted are undefined"). After a command the gate captures changes by
  **reading** the upper host-side.
- **Resource domain**: session-level cgroup; commands are children of the server (already in the
  domain) and inherit it. Timeout/cancel kills only the current command's process group (`setsid`),
  not the resident instance or other background processes.
- **Fallback**: overlay unavailable, nested userns (T2) tier, privilege-tier escalation, or
  startup/health-check failure automatically falls back to the one-shot process path (no silent
  failure). Privilege tiers cannot be changed in place, so a tier escalation rebuilds the resident
  instance (its background processes are terminated).
- **Lifecycle**: `sandbox.shutdown()` (`:qall` / hot reload / plugin unload), session rotation
  (agentEnd) and `sandbox.reset()` stop the resident instance (terminating everything in its namespace).
- **Config**: `tools.sandbox.resident = { enabled }` (default `true`).

### Internal long-lived services (`sandbox.service`, no AI tools)

- **Invisible to the AI**: `service_start`/`service_logs`/`service_status`/`service_stop` are no longer
  registered as tools. Background processes are carried by the resident instance above; the AI manages
  them with plain shell commands (`ps`/`kill`/redirect logs).
- **Internal reuse**: `sandbox/service.lua` is kept as an internal capability for the systemctl facade
  (`sandbox/systemd`) to start/stop unit processes in-sandbox (own overlay + resource domain; changes
  captured as candidates on stop).
- **Isolation / boundary sync / graceful stop**: as before — own overlay attempt, one-way staging
  materialization at start, capture-and-merge into staging at stop with async review (reusing
  `wrapper.settle_exec_candidate`); `cgroup.term` graceful stop then `cgroup.kill` as the fallback.
- **Config**: `tools.sandbox.service = { enabled, max_services, max_log_bytes, stop_timeout_ms }`.
  `auto_background` and the `SANDBOX_BACKGROUND_ROUTED` event are retained as constants but no longer
  emitted (the old background facade was removed).

### systemctl facade (`tools.sandbox.systemd`, option A)

**Background**: the AI often validates a service with `systemctl start/restart <unit>`. The host
systemd control channels are masked by default (`/run/dbus`, `/run/systemd`), so `systemctl` inside
the sandbox always fails; the default T2 path freezes the host effect as a hostop proposal and
replays it on the host. This facade completes **standalone** `systemctl`/`journalctl` calls inside
the sandbox: the service process runs in the sandbox namespace (reusing `sandbox.service`'s own
overlay + cgroup) and its writes are frozen as candidates on stop — the **host systemd is never
called and the host is never modified**.

- **Interception**: `sandbox/systemd.lua`'s `parse_command` only recognizes **standalone calls**
  (skipping `sudo`/`doas`/`env` prefixes; compound commands `a && systemctl …`, pipelines and calls
  inside scripts are not intercepted). The gate calls `wrapper._maybe_systemd` in the
  `effect="process"` branch, next to `container.plan`.
- **Support matrix**:
  - Verbs: `start`/`stop`/`restart`/`status`/`is-active`/`is-enabled`/`is-system-running`/
    `is-failed`/`show`/`cat`/`daemon-reload`/`list-units`/`list-unit-files`; unit-less `status`
    synthesizes a system overview (`State: running`), `is-system-running` always returns `running`,
    `is-failed` always returns `active` (no failed units in the sandbox), so environment probes do
    not reveal a "non-systemd environment".
  - Types: `Type=simple` (default)/`exec` as long-lived services; `oneshot` runs to completion.
  - Dependencies: `Requires`/`Wants` pulled recursively, `After`/`Before` topologically ordered
    (bounded by `max_deps`).
  - Unit files are read from the **sandbox staging copy first** (units created/edited by the AI via
    `edit_file`/`run_command` are visible).
- **Explicitly rejected (no host fallback, no hostop)**: `Type=notify`/`notify-reload`/`forking`/
  `dbus`/`idle`, `.socket`/`.timer` units, `User=`/`Group=`, systemd specifiers (`%n` …),
  `Requisite`/`BindsTo`/`PartOf`; verbs `enable`/`disable`/`mask`/`reload`/`kill` etc., plus host
  power/kernel-state operations `poweroff`/`reboot`/`halt`/`kexec`/`suspend`. Returns
  "unsupported in the sandbox environment" and emits `SANDBOX_SYSTEMD_UNSUPPORTED`.
- **Hostop fallback**: verbs the facade does not handle (e.g. `isolate`) or options targeting
  another host/root (`-H`/`--host`/`--root` …) are not intercepted and fall back to the existing
  T2/hostop proposal path (host replay after approval).
- **Audit**: a facade hit records a `kind="privilege"` evidence entry and emits
  `SANDBOX_SYSTEMD_ROUTED`; output is redacted via `conceal` (no sandbox fingerprints).
- **Environment appearance (indistinguishable)**: when the facade is enabled (`systemd.enabled`,
  default), the process sandbox additionally creates the `sd_booted()` marker
  `/run/systemd/system` and disguises PID1 as `systemd` (overriding
  `/proc/1/comm|cmdline|stat|status`), so probes such as `cat /proc/1/comm` and
  `ps -p 1 -o comm=` cannot tell the sandbox apart from a real systemd host. The disguise only
  applies under PID-namespace isolation (`--as-pid-1`, PID1 is the payload); in `no_pid_ns`
  scenarios (LSP) PID1 is the host init and is not disguised. When the facade is disabled, no
  marker is created and PID1 is not disguised (`/run/systemd` stays masked). Limits: D-Bus / the
  real systemd control channel remain unavailable, and deep probes (`systemd-analyze`, `sd_bus`)
  may still detect it.
- **Config**: `tools.sandbox.systemd = { enabled, mode="facade", max_deps, unit_roots, stage_install }`.
- **enable/disable symlink staging**: with `stage_install` (on by default), system-level
  `systemctl enable/disable` is no longer rejected: the facade parses the unit's `[Install]
  WantedBy/RequiredBy` and stages the symlink changes (enable creates
  `/etc/systemd/system/<target>.wants/<unit>`, disable removes it) as review candidates via
  `candidate.stage_link` / `stage_delete`, applied after approval; nothing lands on the host.
  User-level `systemctl --user enable/disable` is executed by the nested real systemd and its
  symlinks are likewise captured as candidates (see "Nested real systemd --user").
- **Known limits**: template/instance units (`foo@bar.service`) are unsupported; `[Install] Also=` is
  not expanded yet.

### Nested real systemd --user (`tools.sandbox.systemd.user`)

**Background**: the facade simulates systemd with in-sandbox long-lived services and has limited
fidelity. When enabled, the session-resident sandbox instance starts a **real `systemd --user`**
instance, so the AI's `systemctl --user ...` hits real systemd semantics
(`daemon-reload`/`start`/`stop`/`status`/`list-units`/`is-active` …), and no change lands on the host.

- **Boot**: before entering its read loop, the resident command server runs an idempotent boot snippet:
  `mkdir /run/systemd/system` (satisfies `sd_booted()`), a private `XDG_RUNTIME_DIR=/run/neoai-user`
  (mode 0700), a private session `dbus-daemon`, then `systemd --user`, waiting for
  `$XDG_RUNTIME_DIR/systemd/private`. `XDG_RUNTIME_DIR`/`DBUS_SESSION_BUS_ADDRESS` are injected into
  the resident instance so later commands inherit them.
- **Delegated cgroup**: `cgroup.prepare_delegated` creates a **process-free** child domain under the
  shared `neoai` parent and delegates controllers; the sandbox binds it writable at `/sys/fs/cgroup`.
  systemd can only create/move cgroups inside that subtree (`<base>/neoai/neoai_deleg_sd_<session>`),
  never touching other host cgroups; on release it `cgroup.kill`s and recursively removes it. This is
  systemd's standard delegation model, avoiding "host cgroup fully writable".
- **Staging & isolation**: unit files live in `$HOME/.config/systemd/user` (workspace overlay) and are
  frozen as candidates per call; runtime state is in the private tmpfs; service processes run in the
  sandbox namespace. Host `/root/.config/systemd/user` and host cgroups are untouched.
- **enable/disable symlink staging**: `systemctl --user enable/disable` is executed by the real user
  manager; the `.wants/*.service` symlinks it creates in the overlay are captured as **symlink
  candidates** (candidate file entries gained a `link` field) and enter review together with the unit
  file. On approval, publishing creates the real symlink via the writer's `symlink` action (CAS
  validates the baseline with `lstat`/`readlink`). `disable` removing a symlink becomes a delete
  candidate.
- **Facade cooperation**: `systemd.parse_command` marks `--user` as `route="native"` and does not
  intercept it; `privilege.classify` treats `systemctl --user`/`journalctl --user` as minimal (T0).
  If `resident` and `systemd.user` are not both enabled, the facade returns a clear message (no silent
  failure).
- **Config**: `tools.sandbox.systemd.user = { enabled }` (off by default; requires
  `tools.sandbox.resident.enabled`).

### 137 / OOM attribution and diagnostics (`tools.sandbox.diagnostics`)

- **Exit code 137 = SIGKILL**: there are two sources — `cgroup.kill` (called by the gate on command
  timeout/cancel/output truncation via `ctx.sandbox_kill`) or OOM (resource-domain `memory.max` or a
  host/container memory shortage).
- **Attribution**: when a command ends with 137, `run_command` reads that resource domain's
  `memory.events` (`oom_kill` / `oom_group_kill`): a hit reports "suspected memory-limit OOM",
  otherwise "forcibly terminated (137/SIGKILL)" with a hint to enable diagnostics. With
  `tools.sandbox.diagnostics.enabled=true`, `cgroup.kill` records the caller traceback and command
  end records resource-domain memory/pids events (log only, no behavior change).
- **Diagnostics command**: `:NeoAISandboxDiag` prints host/container cgroup limits (`memory.max` /
  `memory.events` / `pids.max`), load, PID1 (systemd detection) and resolved sandbox limits, to tell
  "sandbox resource domain" apart from "host container OOM".
- **Environment-mismatch hint**: when command output matches `System has not been booted with
  systemd` / `Failed to connect to bus`, etc., the result appends a hint: "this environment has no
  systemd; systemctl/service is unavailable — run a foreground command directly".

### Network mirrors (`tools.sandbox.network.mirrors`)

- For restricted networks, mirrors can be configured (empty = inherit system behavior): `pip` →
  `PIP_INDEX_URL` + `PIP_TRUSTED_HOST`; `npm` → `npm_config_registry`; `maven` → generates a
  `settings.xml` (mirroring all repositories), read-only binds it into the session-private `/tmp` and
  points `MAVEN_OPTS -s` at it. Only applies to sandbox external commands, still subject to
  proxy/`host_local_block` filtering (external targets allowed and recorded).

### AI-only Sandboxed LSP (on by default)

- Switch: `tools.sandbox.lsp_overlay.enabled` (default true). Effective only with the `bwrap`
  backend and when the workspace root is overlay-mountable. With no unpublished staging it is skipped
  and the AI tools fall back to editor clients, working as usual; **with staging present, falling back
  is refused** (it would read the real view and diverge from the file tools) and the tool reports
  "sandbox LSP unavailable". Set to false to disable (AI tools then read the real disk).
- Scope: **only the AI `lsp_*` tools are affected.** `vim.lsp.rpc.start` is no longer wrapped
  globally, so the editor's own LSP processes keep reading/writing the real disk; when an AI tool
  runs, it lazily clones the matching editor server (client name suffixed with `@neoai-sandbox`) and
  only that clone enters the sandbox mount namespace and staging layer.
- Mechanism: the clone's server command reuses **`runtime.process_prefix`** (the **same namespace
  construction as `run_command`**: same read surface, overlay/masking, seccomp and capability
  tightening), and its overlay specs reuse `wrapper.build_overlay_specs`. The lower is the real root
  and the upper is the sandbox's private writable layer. Therefore an LSP launched via `run_command`
  (e.g. `pyright`, `pylsp`, `npx tsserver`) and the `lsp_*` tools see the **exact same** sandbox view
  (same real path, same staged content).
  - **PID namespace is not unshared** (`process_prefix` with `no_pid_ns=true`, which also drops
    `--as-pid-1`): Node-based servers (copilot/pyright, …) **exit (exit 1) right after startup** under
    `--unshare-pid`. The file view (mount/overlay/masking) is unaffected and still matches
    `run_command`; only PID isolation is given up.
- Diagnostics: the clone's `textDocument/publishDiagnostics` does not leak into the editor;
  `lsp_diagnostics` prefers pull diagnostics (`textDocument/diagnostic`) from the clone (reflecting
  staged content) and falls back to editor diagnostics when the server does not support it.
- Consistency refresh: before every LSP tool call and at clone start, `sandbox.lsp.refresh()`
  re-materializes the upper from the current workspace staging (wipe then write), so the clone
  immediately sees the latest unpublished changes.
- Isolation & caches: the clone's cache/state dirs (`stdpath(cache|data|state)`, `~/.cache`,
  `~/.local/*`, `~/.npm`, and **XDG_CONFIG_HOME (default `~/.config`)**) are rw-bound straight to the
  host, so caches/state never enter the overlay or the review queue. `~/.config` must be writable:
  otherwise a server opening its state DB (e.g. copilot's `~/.config/github-copilot/auth.db`) reports
  `attempt to write a readonly database` and exits (exit 1). Overlay uppers are sharded by workspace
  hash (no cross-project bleed) under `/dev/shm/.cache-<tag>/lsp/<hash>`. After the rw binds, the same
  `mask_paths` as `run_command` are applied (e.g. `~/.config/gh`, `~/.config/gcloud`,
  `~/.config/git/credentials`, `~/.local/share/keyrings`, `~/.cache/keyring-*`), so credentials are not
  exposed to the clone via config/cache dirs.
- Lifecycle: clones are started and cached on demand by `sandbox.lsp.clients_for` /
  `client_supporting`, and stopped by `stop_all()`. No global hook is registered, so unload/disable
  never affects the editor LSP.

## 6. Runtime backend

- `bwrap` (if present): minimal read-only system set + multi-root overlay, with concealment args such
  as `--as-pid-1` (see §15). As root it prefers explicit no-user-namespace isolation flags, otherwise
  it uses `--unshare-all`.
  - **When overlay is usable**: each writable root (`process_roots`) uses real content as the
    read-only lower and a session upper as the writable layer, so the command sees real content and
    writes are captured.
  - **When overlay is not usable (fail-closed by default)**: no downgrade — `process` tools are
    rejected with `SANDBOX_OVERLAY_UNAVAILABLE` (including the reason), so commands never silently
    run in a private view that cannot see real-disk files (which would misread "cannot see it" as
    "file missing / change did not take effect"). Set `tools.sandbox.overlay_fail_closed = false` to
    explicitly allow degraded mode: a private session directory is then `--bind`-mounted over the
    root (namespace isolation and read-only rootfs are kept); the command sees a session-private view
    (staged changes only) and `run_command` shows a "degraded mode" notice **to the user only**
    (`ctx.sandbox_degraded` → the tool result's UI-only metadata `notice`, with
    `ctx.sandbox_degraded_reason`), **never in the model-visible result**, so "cannot see it" is not
    misread as "file missing / change did not take effect" and the model cannot infer the sandbox
    state.
  - **T2 privileged tier (nested userns)**: it has no overlay by design and freezes host effects as
    proposals, so it is **not a "degraded" mode**. It is marked separately via `ctx.sandbox_userns`,
    and `run_command` shows a **tier-specific notice** ("running in the T2 privileged tier inside a
    nested namespace … host effects will be frozen as proposals for review") **to the user only**,
    instead of the "overlay unavailable" degraded warning, to avoid misleading the user.
  - **Diagnosing the degraded reason**: `:NeoAISandboxCaps` prints `overlay=ready` or
    `overlay=unavailable(<reason>)`; `runtime.overlay_diagnosis()` probes the real execution paths
    (cwd + sandbox overlay base dir) for **writability** (mount + write probe, matching the real
    gate) and returns `{ available, reason, flags, userns }`. `runtime.overlay_reason()` returns
    `OVERLAY_NOT_WRITABLE(...)` when overlay can be mounted but the payload cannot write into it,
    instead of an empty reason from checking mountability alone.
    Common causes: host `/` owned by the init userns while running with a userns (overlay EINVAL),
    lower/upper on different mounts or userns ownership, an upper filesystem that does not support
    overlay upper/work (e.g. tmpfs without xattr, fuse, network filesystems), or upper/work
    permissions/ownership not matching the payload identity.
  - **Network allowed by default**: with a userns, `--share-net` after `--unshare-all`; without a
    userns the network is shared and only `offline=true` isolates it (`--unshare-net`).
- `unshare` (fallback): `--user --map-root-user --mount --pid --fork --ipc --uts --mount-proc`
  (shares network by default; adds `--net` when `offline=true`).
- Capability probe: `bwrap`/`unshare`/userns/cgroup v2/overlayfs/seccomp.
  - **Lazy**: `sandbox.init()` does not probe synchronously at plugin startup (probing actually
    launches bwrap / mounts overlay, which slows down opening a new nvim when the host is busy); the
    probe runs on first real need (`runtime.capabilities()` / building a process prefix) and is then
    cached for the process.
  - `bwrap` and `overlayfs` are **functionally probed** (actually launching bwrap / actually
    mounting overlay), not just detected from the binary or `/proc/filesystems`: when the host `/`
    superblock belongs to the init userns (e.g. inside a container), overlay returns `EINVAL` in a
    fresh userns, so a kernel-support-only check gives a false positive.
  - The capability probe is only a **coarse gate**; when building the process prefix, overlay is
    probed again with the **real execution paths** (lower = real cwd, upper/work = private layer),
    cached by `(dev_lower, dev_upper)`. A probe using same-source temp dirs can be a false positive
    when the real paths span mounts/userns, so a failed real-path probe follows the fail-closed
    policy above (rejected by default; neither a hard failure nor a silent downgrade).
- A completely unavailable backend returns a clear error (`SANDBOX_BACKEND_UNAVAILABLE`); no silent
  downgrade. Overlay being individually unavailable is fail-closed by default
  (`SANDBOX_OVERLAY_UNAVAILABLE`); only `tools.sandbox.overlay_fail_closed = false` falls back to
  the private cwd.

> In-process tools (LSP/treesitter/UI) cannot be namespace-isolated; they are constrained by
> "read-only by default + staged writes + policy gate". This is a documented boundary.

### Privilege reduction and host-sensitive path masking (on by default)

Namespace isolation alone is not enough to stop escape when a root payload keeps all
capabilities and can reach host sockets. `runtime` therefore applies the following
defense-in-depth to the bwrap prefix by default (`--cap-drop ALL` plus the tier baseline
`CAP_DAC_OVERRIDE`, while host-global capabilities are narrowed via `cap_drop`):

- **Close inherited fds (anti-chroot-escape)**: before starting the payload, all inherited fds
  except 0/1/2 are closed. Otherwise a **directory fd** held by a host process (e.g. the AppImage
  runtime's `/tmp/.mount_*`) is inherited into the sandbox and the AI can `openat(dir_fd, "..")`
  its way back to host `/`, bypassing the chroot/namespace. See `runtime._wrap_close_fds`: it
  prefers `bash` (supports multi-digit fds), falls back to `python3`'s `os.closerange`, then to
  `sh` (dash only supports single-digit fds — best effort). `run_command`, `runtime.run` and the
  LSP namespace overlay all go through this wrapper.
- **Least privilege + tier baseline + narrow per-command add-back + host-global capability
  narrowing (`cap_drop`)**: by default `--cap-drop ALL` plus the tier baseline
  `CAP_DAC_OVERRIDE` (T0/T1 `tiers[n].cap_add`), so a root payload can bypass DAC to reach
  0700 directories owned by other uids (e.g. `_apt`'s `/var/cache/apt/archives/partial`). The
  needed capabilities are added back **narrowly per command** — package-install commands
  (including chained ones like `apt-get install …; echo; tail`) via `packages.cap_add`,
  system-administration commands (`useradd`/`chown`/`passwd`, …; `req.sysadmin`) via
  `privilege.sysadmin.cap_add`, which also lifts account-DB masking; ordinary commands keep only
  the baseline. At the same time, the capabilities that
  can **modify host-global state** are dropped one by one per `cap_drop` (default
  `CAP_NET_ADMIN`/`CAP_SYS_TIME`/`CAP_SYS_MODULE`/`CAP_SYS_RAWIO`/`CAP_SYS_BOOT`/
  `CAP_MAC_ADMIN`/`CAP_MAC_OVERRIDE`/`CAP_AUDIT_CONTROL`), so netlink route/firewall changes,
  clock changes, module loading, raw port I/O, reboot and MAC/audit changes are denied with
  `EPERM`; none of them are needed by dev/package workflows. Capabilities explicitly listed in
  `cap_add` are not dropped. Host **filesystem** immutability does not rely on capabilities but
  on namespaces + whole-root overlay staging (writes are frozen as candidates). For full
  capabilities (not recommended) set `cap_add = { "ALL" }`. The sandbox already
  runs as root, so `sudo`/`doas` (and their options) is **stripped** (`sudo apt update` →
  `apt update`); otherwise `sudo` fails with `setresuid` EINVAL under the nested userns and a
  masked `/etc/sudoers` (`PERM_SUDOERS`). Stripping is applied **per command segment** (split on
  unquoted `;`/`&`/`|`/`&&`/`||`/newline), so `a && sudo b`, multi-line scripts,
  `sudo -u user cmd`, `sudo -i`, … no longer error; separators inside quotes/escapes are not
  split and the rest of the command (including whitespace inside quotes) is preserved.
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
- **Read surface: whole-root writable overlay (`read_all`, on by default)**: by default the host root
  is mounted as an overlay with `/` as the read-only lower and a session-private upper/work as the
  writable layer — the sandbox root filesystem is **writable as-is** (any path, no more
  `Read-only file system`). All writes go to the upper staging layer and are frozen as candidates
  after the command, leaving the host disk untouched. Only the important config files/credentials in
  `mask_paths` (see above) plus the sandbox's own storage are masked — i.e. "everything is
  readable/writable except important config files", so `/opt`, `/srv`, other project dirs, … are
  writable. `mask_dirs` (`/home`, `/root` sibling dirs) are no longer mount-masked. When the overlay
  is unavailable it falls back to a read-only root (`overlay_fail_closed` decides whether to degrade).
  - **Outside-workspace tracing (non-blocking)**: accessing user working dirs outside `cwd` (under
    home/root) records evidence (kind=observation), emits a `sandbox:outside_access` event, and is
    shown in the `:NeoAISandboxReview` window under "越界访问留痕"; the read is still allowed, not
    blocked. In that view traces are **merged by file path** (multiple tools for the same path collapse
    into one line `[tool1, tool2] path`) and **sorted by path ascending**; the statusline `sandbox`
    part also shows `越界N` when traces exist (`N` = distinct file count), in addition to pending
    changes. Dedup is by `(tool, path)`. By default the source is **kernel-level behavior
    observation** (`tools.sandbox.observe`; backends `ebpf` (bpftrace) → `strace` → `procfs`),
    attributed precisely to the attempt cgroup and watching real `openat/open` calls instead of
    parsing command strings; when none is available it falls back to command-string heuristics
    (in-process read tools by path args, `run_command` by absolute paths in the command string).
    System paths (`/usr`, `/etc`, …) and the **sandbox's own storage** (store root / instance dir / overlay
    base / runtime private dir, e.g. `<store.root>/seccomp/baseline-v5-*.bpf`) are not traced to avoid
    noise — observation is cgroup-attributed, so it also captures the wrapper re-opening the seccomp
    filter and overlay upper/work accesses; without this exclusion every external command would leave a
    spurious "outside-workspace" record. **The observation hot path is
    bounded**: builds/tests repeatedly open the same set of files (events can reach millions), so
    paths are **deduped** (each path processed once per attempt; the set has a bounded cap);
    `outside_workspace` first does a **pure string prefix pre-filter** against mask dirs and only
    canonicalizes (symlink resolution via `vim.fn.resolve`, an expensive syscall) for candidates,
    caching the mask-dir list by config reference; outside-access evidence is written via
    **async write-behind** (`evidence.add_async`) instead of a synchronous per-record disk write on
    the main thread.
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
- **AppImage support (`tools.sandbox.appimage_extract_and_run`, on by default)**: the sandbox by
  design blocks `mount`/the new mount API and exposes no `/dev/fuse`, so an AppImage cannot run via a
  FUSE mount. When enabled, sandbox processes get `APPIMAGE_EXTRACT_AND_RUN=1`, so the AppImage runtime
  extracts into the session-private `/tmp` (writes to a temporary root produce no pending candidate)
  and runs — **without widening any privilege**; non-AppImage programs ignore the variable. Set
  `false` to disable.
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
> `conceal` deliberately avoids creating a userns under root to hide fingerprints. With the
> default root payload (plus the tier baseline `CAP_DAC_OVERRIDE`), the payload is host root inside
> the namespace: **filesystem modification** is closed by namespaces + whole-root overlay staging +
> masking + approval, and **host-global state modification** is closed by `cap_drop` (network/clock/
> modules/raw I/O/boot/MAC/audit) plus seccomp (device nodes, clock, port I/O,
> mount/unshare/bpf/… barriers); `CAP_DAC_OVERRIDE` can still **read** 0600 files outside the
> mask list (information disclosure, not modification). Set `cap_add = {}` together with tier
> `tiers[n].cap_add = {}` to narrow further to minimal privileges. **The complete fix is to enable
> `userns-remap` / rootless at the container runtime layer** so container root maps to a high host
> uid — a deployment-side setting, outside this plugin.

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
  resolution. Unresolvable targets fail closed (treated as host-local). Resolution runs
  **asynchronously via callback-style `getaddrinfo` (libuv thread pool)** so it never blocks the main
  thread — otherwise concurrent networked commands like `uv pip install` would freeze the UI on a
  synchronous DNS lookup per request. Records are returned via the `run_command` result summary and
  stored as `network` evidence.
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
      cap_add = {},                  -- global extra capabilities (default empty); tier baseline adds CAP_DAC_OVERRIDE, package installs add more on demand
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
      appimage_extract_and_run = true, -- AppImage: inject APPIMAGE_EXTRACT_AND_RUN=1 to run extracted (no /dev/fuse, cannot mount)
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
      workspace_root = vim.fn.stdpath("cache") .. "/NeoAI/sandbox", -- base root; each process is isolated under <root>/instances/<pid>_<ts>
      review = { enabled = true, auto_apply = false }, -- async review: candidates enter a pending queue
      retention = { candidate_days = 7, max_pending = 20 },
      policy = { deny_tools = {}, rules = {} },
      limits = { wall_ms = 60000, dynamic = true, memory_ratio = 0.5, cpu_cores_max = 4, cpu_global_max = 0, pids_max = 2048 },
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
sandbox secret token — the real key has been masked by the sandbox, invisible only to the AI; it does
**not mean the program errored and does not affect actual program execution** (it is automatically
restored to the real key on file write). The sandbox only masks secret-shaped high-entropy runs;
paths, function names and build hashes are left intact." For env vars there is also the
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
values.

All concurrent attempts share a parent domain `neoai`: the parent's `cpu.max` is the global budget
`cpu_global_max` (default `max(1, nproc-1)`, reserving one core for nvim/UI), and each child's
`cpu.max` is `min(cpu_cores_max, global budget)`. The sum of concurrent per-task quotas therefore
never exceeds the host's available cores (no oversubscription where each task gets N cores and the
total far exceeds the core count, saturating the machine and stalling the chat UI), while a single
task is still subdivided by `cpu_cores_max`.

The control plane creates a cgroup v2 child and joins the process (`join_prefix` writes
`cgroup.procs` before exec); on completion/error it `cgroup.kill`s and removes the child so the
process tree converges. When cgroup is unavailable it **skips the limits with a warning** (no
blocking); set `limits.fail_closed = true` to reject execution instead
(`SANDBOX_CGROUP_UNAVAILABLE`) — no silent downgrade.

**CPU affinity** (`limits.cpu_affinity`, default `"auto"`): sandbox processes are pinned via
`taskset -c` to cores **other than nvim's current CPU**, so they do not compete with nvim for the
same core; on a single-core host or without `taskset` it is skipped. Set `"off"`/`false` to disable,
or `"2,3"`/`"2-3"` for an explicit cpuset. Affinity is applied before bwrap (`_prepend_affinity`) and
covers the whole sandbox process tree; it stacks with the cgroup `cpu.max` quota.

### Staging backend and disk cap

**Staging backend** (`tools.sandbox.staging_backend`, default `"disk"`): the process overlay
upper/work, the per-session private tmp roots (/tmp, ...), and the LSP overlay are staged on **disk**
by default (a hidden featureless dir, preferring `/var/tmp`, falling back to the nvim cache dir) so
that "lots of files staged in memory" (`/dev/shm`) is avoided. Set `"shm"` to go back to `/dev/shm`
(faster but memory-hungry), or give an absolute path to use as the base. `conceal.base_host` is the
single locator for that base.

**Disk cap** (`tools.sandbox.limits.disk_bytes`, default `64 GiB`, `0` = unlimited): it totals the
staging base (process overlay / private tmp) plus the sandbox store root (candidates/review/evidence/
service overlay), and rejects write/process tools when exceeded (`SANDBOX_DISK_LIMIT_EXCEEDED`) so
staging cannot fill the host disk. Usage is recursively measured on a **worker thread and cached**
(TTL 5s); the gate only reads the cache and never runs a synchronous `du` at command start, passing
through while the measurement is not ready. See the `disk` field of `:NeoAISandboxDiag`. When over the
cap, apply/reject pending candidates (`:NeoAISandboxReview`), prune expired ones (`:NeoAISandboxPrune`),
or raise the cap.

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
expressions like `api_key = os.getenv("..._API_KEY")` are not treated as raw secrets; an assignment
whose right-hand side is a **sensitive env-var name reference** (e.g. `api_key=DASHSCOPE_API_KEY`,
`PASSWORD=MY_SECRET_TOKEN`) is likewise not registered — the name is only a reference, and
registering it would make any later ordinary code/doc that mentions the name look like a leak.
**Sensitive env-var names (all-uppercase, with a sensitive segment) are monitor-only**: traced and
escalated to review, never hard-blocked/aborted.

**Env-var secret values are soft-handled**: `sanitized_env` registers the real value of a sensitive
env var as an "env-var secret" (`secret.is_env_secret`). Such values are **fallback plaintext-
tokenized** in AI-visible output — even a bare value (pure hex / no named prefix) that is not in a
`NAME=value` assignment context and whose file does not trigger entropy scanning is replaced with a
token; and they **never trigger the context hard block** (`context_leak` skips env-var secrets).
That is, "key env vars are only tokenized/warned about, never abort the agent". Raw secrets that are
not env-var values (matched by a named rule or registered as high entropy) are still hard-blocked.

**Binary content is never treated as text (lossless)**: when staging/freezing, only **text** content
(valid UTF-8, no NUL) is secret-tokenized; binary files (OpenPGP keyrings, images, executables, …)
**skip tokenization** and are preserved byte-for-byte. Candidate/review/snapshot JSON persistence
now uses a **lossless codec** (`json.encode_lossless`: invalid-UTF-8 strings are stored as a base64
sentinel table and restored by `decode_lossless`), instead of sanitizing invalid bytes to U+FFFD
(`EF BF BD`) — that sanitization corrupted binary keyring contents during the
"second confirmation → apply" path (the file could no longer be parsed by `sqv`/gpg). Encoding of
ordinary text is byte-identical to before.

> **Chat highlights the command that obtained/used a secret**: when rendering a tool block, its
> **arguments** and **result** (model context) are scanned; on a sandbox token (`NEOKEY_*`) or a raw
> secret matched by a **named rule**, a **warning** (highlighted with
> `NeoAISecretWarning`, red bold underline) is appended **outside** the tool fold block, formatted
> **one item per line** (no comma-joined lists): first line `⚠ 密钥：<tool> <obtained/used>`, the
> command on its own line, then the matched key files / types / env vars each on its own line. The
> warning **clearly distinguishes the two cases**: `⚠ 密钥：<tool> 获取了密钥（…）` (obtained — the result or
> kernel observation read secret **content**, i.e. a token or a named-rule credential; a result that
> merely mentions a **sensitive env-var name**, e.g. `read_file` reading
> `DASHSCOPE_API_KEY = os.getenv(...)`, does **not** count as "obtained" and does **not** warn — the
> name is only a reference, so no key content was read) and `⚠ 密钥：<tool> 使用了密钥（…）` (used —
> arguments carry a secret value/token/sensitive env name, or a use-type command such as
> `ssh -i`/`curl`/`gpg` references a secret file); when both hold it says "获取并使用了密钥". **Merely listing/viewing
> secret files does not warn**: listing-only commands (`ls`/`find`/`stat`) and tools
> (`list_files`/`search_files`/`file_exists`) do not constitute a read or use, and a read-type command
> that references a secret path but returns no secret content does not trigger either (avoiding false
> positives). **Warnings use a strict path set** (`secret.is_sensitive_path`): only real credential
> files (`~/.ssh`/`~/.aws`/`~/.kube`/`.env`/`id_rsa`/`*.pem`/`*.key`/`/etc/shadow`/`/etc/ssh`/
> `trusted.gpg`/keyring…) count; non-secret files opened by ordinary commands (`/etc/ld.so.cache`,
> `/etc/nsswitch.conf`, `/etc/passwd`, `/etc/group`, `/etc/os-release`, `/etc/localtime`, `*.env` such
> as `go.env`, `.npmrc`, `.bash_history`/`.python_history`, **public CA bundles/trust stores**
> (`cacert.pem`/`ca-bundle.pem`/`chain.pem`/`fullchain.pem`/`roots.pem` etc., and certificates under
> `/certifi/`, `/ca-certificates/`, `/ssl/certs/`, `/usr/lib/ssl/`, `/usr/share/ca-certificates/` —
> e.g. Debian/Ubuntu's `/usr/lib/ssl/cert.pem`, `/etc/ssl/certs/ca-certificates.crt`, RHEL's
> `ca-bundle.crt`, pip's vendored `.../pip/_vendor/certifi/cacert.pem`) and **third-party package
> caches/vendored source trees** (`~/.cargo/registry/`, `node_modules/`,
> `site-packages/`/`dist-packages/`, `go/pkg/mod/`, `~/.rustup/`, `~/.gradle/caches/`,
> `~/.m2/repository/` etc. — their `*.pem`/`*.key`/`*.p12` are dependency-shipped **test
> fixtures/sample certificates** such as the `openssl` crate's `test/*.pem` or `tokio-native-tls`'s
> `tests/identity.p12`, opened in bulk by `cargo check`/`pip install`) are ignored, so `uname` /
> `cat /etc/os-release` / `python -m venv && pip install` / `cargo check` are not misreported as
> "obtained a secret". Detail fallback order: observed
> secret file → secret file in arguments → secret type (named rule) → sensitive env name → generic hint.
> **Failed results** (such as the `SANDBOX_SECRET_BLOCKED` error object returned by the hard secret
> block) are not treated as "content that was read" for this decision, and `scan_names` excludes
> `SANDBOX_SECRET_*` internal event identifiers, so the internal identifier is not misread as a
> sensitive env name and rendered as a meaningless `key env var: SANDBOX_SECRET_BLOCKED` warning.
> The fold title stays clean (no `⚠ 密钥` suffix), and the standalone highlighted warning line
> remains visible while collapsed. For a tool call that contains a secret, its **arguments and result are
> shown in full (no truncation)** and the matched secret values (`NEOKEY_*` tokens / raw secrets matched
> by named rules) are highlighted inline with the same group; the trajectory display mode appends the same
> text marker to the tool line and highlights inline as well. See `ui/components/message_list.lua`,
> `ui/components/fold.lua`.
>
> **Observation first (eBPF/strace/procfs)**: by default `tools.sandbox.observe` watches the secret
> files a sandboxed process actually opens (`openat/open`, attributed precisely to the attempt cgroup)
> at the kernel level; a hit raises the warning on the matching tool block and points at the **file
> actually accessed**, taking precedence over command/argument parsing. Only when no observation
> backend is available does it fall back to the content-scan heuristics above. Entropy detection runs
> only on **newly added context and tool calls** (the pre-request guard uses the incremental
> `secret.context_leak_from`, falling back to a full scan only when compaction replaces history), never
> re-scanning the whole history every round.
>
> **Event parsing runs on the thread pool**: the per-line parse of eBPF output (bpftrace `openat`
> lines) and of the strace trace file both run on `utils.work` worker threads (split lines, keep only
> file events, dedupe by path); the main thread only classifies the reduced, deduped path set for
> tracing/secret hits — builds/tests producing millions of events no longer saturate the main thread
> (previously every event did a `vim.fn.resolve` canonicalization; the strace backend even parsed
> every line in pure Lua on the main thread). strace polling is now bounded-concurrent: while the
> previous parse is in flight the next tick is skipped, and it resumes from the new offset once done;
> `stop` still flushes the remainder synchronously so events are dispatched before the command ends.
>
> **Async process post-processing** (`tools.sandbox.postprocess="async"`, default): as soon as the
> command process exits the result is returned to the main loop immediately; overlay capture,
> candidate freeze, staging merge, persistence and settlement complete on a background chain. The
> capture/settle slot (`_serialize_capture`) is held until the background chain finishes so staging
> merges stay ordered; subsequent non-process (read/write) tools also wait for in-flight
> post-processing before running (so they never read staging that has not been merged yet). With
> concurrent process commands the setup phase is serialized (`_serialize_setup`) while **command
> execution is concurrent** (resident multiplexing), see "Process commands run in parallel".
> `sandbox.await_postprocess()` waits for the in-flight chain before shutdown/reset, so freeze and
> review enqueue are not lost. On exit/close the wait is bounded by
> `tools.sandbox.shutdown_timeout_ms` (default 3s), so `:qall` / hot reload are never blocked for a
> long time when post-processing is stuck (on timeout the last unfinished freeze/enqueue is dropped).
> Set `"sync"` to restore "wait for post-processing before returning" (tests inject this by default
> for determinism).
>
> **Startup probe**: on plugin start the backends are probed (eBPF checks the `bpftrace` binary, root,
> tracefs and kernel BTF; then strace/procfs). When eBPF is unavailable/not installed, or when falling
> back to strace and strace is not installed, `vim.notify` reports it (disable via
> `tools.sandbox.observe.notify=false`).
>
> **Non-blocking attach**: by default the eBPF probe attach does **not block the command**
> (`tools.sandbox.observe.wait_ready_ms=0`). Attaching bpftrace takes ~0.5s and previously every
> process command waited bounded before running (up to 800ms), a perceivable fixed stall. The probe now
> attaches asynchronously and the command starts immediately; accesses before attach may be missed
> (command-string heuristics fall back). Set `wait_ready_ms` to a positive value for a bounded wait with
> fuller observation, at a fixed per-command cost.
>
> **Observation prewarm** (`tools.sandbox.observe.prewarm=true`, on by default): after a process command
> returns, in the gap **while the AI generates the next turn**, the next attempt's cgroup is pre-created
> and the eBPF probe attached in the background, overlapping the ~0.5s attach with AI output. The next
> process command reuses the **already-attached** cgroup + probe (the event dispatch target is pointed at
> this attempt on reuse), with no attach wait. If not reused within the TTL (90s by default,
> `prewarm_ttl_ms`) the probe and cgroup are reclaimed. eBPF backend only (strace/procfs start cheaply).
>
> **Capability / overlay probe prewarm** (`runtime.warm`): at the start of a process command the
> bwrap/overlay capability is probed synchronously (a functional test that spawns bwrap, ~100ms), so the
> first command can feel blocked. After sandbox `init()`, at an idle moment during startup (delayed 200ms,
> once per process) `runtime.probe` / `cgroup.probe` are run ahead of time and `overlay_writable` is
> prewarmed for both the process overlay base and the sandbox store base, so the first `run_command` and
> the first long-lived service hit the cache and do not block the main thread at command start.

### Detection (entropy + charset heuristics)

- Candidate: length in `[min_length, max_length]`, contains letters and digits, distinct chars
  `≥ min_distinct`, Shannon entropy `≥ min_entropy` (defaults 20/200/8/3.5).
- Pure lowercase hex is excluded by default (`exclude_pure_hex`) so git SHAs / sha256 / md5 are not
  treated as secrets; the cost is that pure-lowercase-hex keys are not covered.
- **Narrowed scope** (`entropy_requires_context`, on by default): a bare high-entropy run is a secret
  only if it has **key form** (contains a `-`/`_` separator) **and is not a code identifier/package
  name** (`-`/`_`-separated segments that are each "letters+digits" or pure digits, such as
  `create_urllib3_context`, `HTTP_SSL_CONTEXT_V2_API`, `openjdk-21-jdk-headless`, `libssl-dev`,
  `python3.11-minimal`),
  or sits in a **sensitive name-assignment context** (`KEY=`/`TOKEN:`/`PASSWORD=` …); plain
  alphanumeric/base64 runs (SRI `integrity`, content hashes, build-artifact digests) are no longer
  tokenized. Algorithm-prefixed digests (`sha512-`/`sha256-`/`md5-`/`blake2-` …) and **path
  components** (runs adjacent to `/`, e.g. `/opt/build_0abc…/lib`) are excluded as well, so
  `package-lock.json` integrity, `python -m build` sources, and Python traceback function names or
  paths in tool output are not corrupted/misread. Set to `false` to restore the old "any high-entropy
  run is a secret" behavior.
- **Only suspected secret files get the entropy scan** (`entropy_secret_paths_only`, on by default):
  the full-text entropy scan runs only on content whose path matches a **suspected secret file**, so
  ordinary files and tool output skip the expensive per-character entropy computation. The check is
  `sandbox.secret.is_secret_path`, covering `~/.ssh/`, `~/.aws/`, `~/.gnupg/`, `~/.config/gcloud`,
  `~/.kube/`, `~/.docker/config.json`, `.env`, `id_rsa`/`*.pem`/`*.key`/`*.p12`, shell startup files
  and histories (`~/.bashrc`/`~/.zshrc`/`~/.profile`, `~/.bash_history`/`~/.zsh_history`, …), and
  system-sensitive configs such as `/etc/*`. **Named rules (private-key blocks/AKIA/ghp_/sk-/JWT/
  Bearer…) and sensitive name-assignment detection still apply to all content.** Set to `false` to
  restore the old "entropy-scan everything" behavior.
  The gate uses the **wide** predicate for **explicit targets** (tool path arguments / paths in the
  command string) and the **strict** predicate (`secret.is_sensitive_path`) for **kernel-observed
  paths** — ordinary commands like `dpkg -l`/`ss`/`python` incidentally open wide matches such as
  `/etc/ld.so.cache` or `/etc/nsswitch.conf`, and enabling the entropy scan from those would
  mis-tokenize package names in the output.
- **Environment variables are force-tokenized by name**: `sanitized_env()` replaces the value of any
  variable whose name (matched per `_`-separated segment) contains `KEY`/`TOKEN`/`SECRET`/`PASSWORD`/
  `CREDENTIAL` **regardless of entropy**, covering pure-hex keys like `GLM_API_KEY=dfe946…` that
  escape entropy detection. The over-broad `AUTH` is deliberately excluded to avoid false positives
  on path variables such as `SSH_AUTH_SOCK`. A non-sensitive-named variable whose value contains `/`
  (a path or URL such as PATH/LD_LIBRARY_PATH/PYTHONPATH/SSL_CERT_FILE) is run through **named rules
  only, not generic entropy tokenization**, so path segments are never tokenized and tools like
  pip/ssl can still find their libraries and modules.
- **Text is force-tokenized by name too**: `tokenize()` (tool results / staged content) replaces the
  value in `NAME=value`, `NAME="value"` and `"NAME": "value"` when `NAME` matches the same sensitive
  name rule **and the value looks like a credential**, regardless of entropy. This closes two entropy
  blind spots: pure-lowercase-hex segments (dropped by `exclude_pure_hex`) and dotted multi-segment
  keys (split by `RUN_PAT` into non-candidates), e.g. `GLM_API_KEY=dfe946….rwbWDAf…` in
  `/proc/self/environ`. The value charset is deliberately narrow to avoid swallowing across entries.
  **Value-shape check**: a value shorter than 4 chars, an ordinary word (`bar`), a single character
  (`.`), a plain filename (`pyproject.toml`), or a path/URL (`/root/...`) is not registered as a
  credential — otherwise `'password': 'bar'`, `key_separator = "."` and
  `CONFIGFILE_KEY = 'pyproject.toml'` in source code would be wrongly registered as "raw secrets",
  polluting the map and making later commands/context containing that fragment false-positive on
  `find_real_secret` substring matching.
- `allowlist` adds further Lua-pattern exclusions. See `tools.sandbox.secrets` in
  [configuration.md](configuration.md).

### Env vars: the sandbox process gets real values, the AI only sees tokens

`sanitized_env()` produces the tokenized overrides (for logs/audit and the AI-visible surface);
`sandbox_env()` restores real secrets when constructing the sandbox process environment —
**token→real replacement is allowed only for sandbox-internal processes**. Therefore:

- Programs inside the sandbox (`curl`/`pip`/`python` …) use the **real secret** and do not fail
  (401 / build errors) because of masking.
- Command output is re-tokenized before it returns to the model, so the AI still only sees
  `NEOKEY_<hex>`; `NEOAI_TOKENIZED_ENV` lists the masked variable names so it is clear which values
  are tokens in the AI-visible output.
- To disable env tokenization entirely (debugging / trusted local runtime), set
  `tools.sandbox.secrets.tokenize_env = false`; tool results and staged content are still protected.
  **This weakens isolation — use only temporarily in trusted environments.**

### Encryption mapping and lifecycle

- Each real secret gets a random token (`NEOKEY_<hex>`); the mapping is **in-memory only**, never
  persisted.
- **Encrypt on the way in**: tool results (before returning to the model), the workspace staged view
  (`candidate._base_entry` / `merge_candidate`) and `run_command`'s **environment variables** are all
  tokenized, for the AI / log / review-UI surface.
- **token→real replacement only for sandbox-internal processes**: `sandbox_env()` restores env vars,
  the gate restores command arguments (`ctx.sandbox_command`; exec tools restore argv), and
  `materialize_overlay` restores files materialized into the command-visible overlay, so programs such
  as `pip` / `python -m build` / `curl` run normally. The AI context, logs, evidence and review UI
  still only see tokens (command output is re-tokenized before it is returned).
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

> **Env-var names are not raw secrets**: the mapping registers **credential values** only, never a
> sensitive env-var name itself. An assignment whose RHS is a name reference
> (`api_key=DASHSCOPE_API_KEY`) is not registered; and even if a name-shaped value was registered by
> legacy state, `find_real_secret` skips all-uppercase identifier forms. So a name such as
> `DASHSCOPE_API_KEY` / `GIT_COMMIT_AI_API_KEY` appearing in tool arguments or AI context is
> **monitor-only** (`scan_names` trace + review escalation) and **never aborts the agent**.

> Boundaries: entropy detection is heuristic; with the default context narrowing
> (`entropy_requires_context`), separator-free, context-free plain alphanumeric/base64 runs are no
> longer treated as secrets — this removes integrity/build-hash false positives, at the cost of
> missing prefix-free, context-free pure-base64 keys (e.g. an AWS secret key). Since tokens round-trip
> losslessly at commit, a false positive does not change the final written content, it only adds
> tracing noise. The mapping is not persisted, so uncommitted tokens after a hot reload cannot be
> resolved and the candidate is refused at publish (fail-closed). Pure lowercase hex keys, and
> commands that read a real file and use the secret within the same command (without going through the
> model), are out of scope.

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
| **T0** | minimal | normal commands | `--cap-drop ALL` + tier baseline `CAP_DAC_OVERRIDE`, added back **narrowly** per command (package installs via `packages.cap_add`, system administration via `privilege.sysadmin.cap_add`) + host-global capability narrowing (`cap_drop`: network/clock/modules/raw I/O/boot/MAC/audit) + seccomp (incl. device-node barrier) + masks + **network allowed by default (host-local intercepted via host_proxy, see §6.1)** | no per-command review; fs changes enter the pending queue |
| **T1** | elevated | network access, controlled docker, package installs, system administration | runs isolated, network allowed; tier baseline `CAP_DAC_OVERRIDE`; commands containing a package manager (`req.package`, incl. chained) get narrow caps via `packages.cap_add`; system-administration commands (`useradd`/`chown`/`passwd`, …; `req.sysadmin`) get narrow caps via `privilege.sysadmin.cap_add` and lift account-DB masking; docker.sock is unmasked only for docker commands | auto-authorized, recorded; fs changes enter the pending queue |
| **T2** | privileged | cap_add, host sockets, host mounts | runs inside a **nested userns** with full capabilities (caps scoped to the userns, cannot reach the host; the seccomp baseline still applies) | host effects frozen as a **proposal**, replayed after async approval |

- Classification: `privilege.classify()` parses the command; `docker/podman`→T1,
  `curl/git push/pip/npm`→T1 network, `useradd/usermod/groupadd/chown/chgrp/passwd` and similar→T1
  system administration (`req.sysadmin`: adds `privilege.sysadmin.cap_add` and lifts account-DB
  masking), `sudo/mount/modprobe/iptables/systemctl`→T2; compound commands take the highest tier.
  Rules live in `tools.sandbox.privilege.classify`.
  - **Read-only `mount` is not privileged**: bare `mount`, `mount -l`, `mount --show-labels`,
    `mount -t ext4`, and listing pipes like `mount | grep` / `findmnt` only read the mount table
    and run at T0; only `mount` with a positional device/mountpoint or a mutating option
    (`-a`/`-o`/`--bind`/`--remount`/`--move`/`--make-*`, …) is T2.
- Max tier: `tools.sandbox.privilege.max_tier` (default 2); exceeding it is hard-denied by policy
  (`PRIVILEGE_TIER_EXCEEDS_MAX`).
- **Payload identity (root by default)**: `run_as.uid=0` runs the payload as root so host toolchains
  and package managers work inside the sandbox; all writes still go to overlay staging. Setting a
  dedicated non-root uid (e.g. `nobody` 65534) hardens it: for non-userns tiers `setpriv` drops the
  payload to that uid (configured narrow caps preserved as ambient). Under T2 (nested userns) that
  uid is unmapped in the new userns, so `setpriv` would fail with `setresuid: Invalid argument`; T2
  therefore does **not** append `setpriv` and the payload runs as userns root (caps scoped to the
  userns, cannot reach the host). A non-root NeoAI launch maps the current user to guest root inside
  a userns; host-root operations are frozen for review and run via `sudo` after approval.
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

`mode="off"` (**default**): the container facade rejects docker/nerdctl outright, returning "docker
is unsupported in the sandbox — use podman", never touching the host and never falling back to hostop
(see §18.3). `mode="controlled"`: with an explicit controlled socket, it is bound into the sandbox as
above (containers are created by the controlled daemon, an explicit deployment choice). `mode="host"`
is no longer allowed by the container facade (it touches the host); run it manually on the host if
needed.

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
>
> **Package installs are never frozen as host proposals**: even when a package-manager command
> (`apt`/`pip`/`pipx`/`npm`, …, `req.package`) fails inside the sandbox on a read-only/permission
> error and matches an escalation signal, it is **not escalated to T2 and no host proposal is
> frozen** — a sandbox failure stays a failure and never falls back to a host install
> (`hostop.freeze` refuses to freeze; `hostop.replay` refuses legacy proposals as a backstop).
> Installs must complete inside the overlay staging via the package-manager writable roots
> (see §5, §17).

### Configuration

See `tools.sandbox.privilege` and `tools.sandbox.docker` in [configuration.md](configuration.md).

### 17.1 Non-root payload, overlay write probing and write escalation

**Root by default** (`tools.sandbox.run_as.uid=0`): the sandbox payload runs as root so the AI can
use host toolchains inside the sandbox (nvm/cargo/go under `/root` are 0700, untraversable by
non-root) and package managers (`dpkg` hard-checks `euid==0`; capabilities alone are not enough).
**All writes still go to the overlay staging layer and freeze as candidates; the real disk is
unaffected.** Host immutability is guaranteed by namespaces + whole-root overlay + masking +
`/proc/sys` read-only binds + seccomp, not by running non-root.

**Non-root launch = guest root inside the sandbox**: when NeoAI is launched as a non-root user, a
**user namespace** maps the current user to root inside the sandbox (`--unshare-user --uid 0 --gid 0`)
— `euid=0` inside so toolchains/package managers work, while the host identity stays the current
non-root user and all writes are still staged. Operations that genuinely need **host root** (writing
system paths, `systemctl`, …) cannot be satisfied inside the sandbox: they are frozen for review and,
after the user confirms in the review UI, run via `writer`/`hostop` with `sudo` (inheriting the tty,
possibly prompting for a password).

**Optional hardening (drop to a dedicated non-root uid)**: setting `run_as = { uid = 65534, ... }`
makes the non-root launch use the current uid and, for root launches, have **bwrap still run as root**
(so it can create mountpoints and mount overlay under 0700 dirs such as `/root`), dropping only the
**payload** via `setpriv --reuid/--regid`; the configured narrow capabilities (e.g. `packages.cap_add`)
are preserved as **ambient** caps, otherwise dropping the uid clears permitted/effective and package
installs cannot acquire locks. Do not use `bwrap --uid N` (as root it maps guest N to host root, i.e.
a root disguise). Writable sandbox dirs (overlay upper/work, staging, session) are chowned to that uid.
> Boundary: a non-root payload's **absolute-path** access to 0700 dirs (e.g. `/root`) is limited by
> DAC and `dpkg` fails because `euid!=0`; place the workspace / `workspace_root` and toolchains where
> that uid can traverse (e.g. `/home/<user>`).

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

**Explicit root request when root is missing**: when the payload is **non-root** (NeoAI started as a
non-root user, or `tools.sandbox.run_as.uid != 0`) and a command fails on a permission error (result
matches `PERMISSION_DENIED`), besides auto-escalation an explicit **`ROOT_REQUIRED` host-op
proposal** is frozen (`hostop`, entering the `:NeoAISandboxReview` pending queue + statusline badge);
after the user approves, the command is replayed on the host with root/`sudo` (inheriting the tty).
It never fails silently and never escalates silently; when root is available (`run_as.uid = 0`) no
such request is generated (to avoid false positives). Package installs are excluded (`hostop`
refuses package installs — never install on the host).

## 18. Security grading, controlled containers and behavior audit

### 18.1 Approval graded by security level (`sandbox/risk.lua`)

Every effectful call is graded L0-L3 and shown in the review UI with a colored `[L0]`-`[L3]`
badge, recorded as evidence (`kind="risk"`) and emitted as `SANDBOX_RISK_ASSESSED`:

| Level | Meaning | Triggers (max wins) |
| --- | --- | --- |
| L0 low | Routine, reversible, inside workspace | Workspace writes, reads |
| L1 moderate | Network, package install, T1 | Network, `apt/pip/npm…`, T1 |
| L2 high | User/system path write, T2, dangerous command, **secret op inside workspace** | `~`/system path writes, T2, `chmod -R 777`, `systemctl`, in-workspace secret op |
| L3 critical | **Secret op outside workspace**, host effect, destructive command | Out-of-workspace secret op, host ops, `mkfs`, `dd of=/dev/*`, `curl … | sh` |

`risk.action(level, opts)` returns `auto` / `record` / `review` (async, non-blocking) / `block`.
The default is `default="review"` (unchanged semantics); override per level via
`tools.sandbox.approval.levels`.

- **Kernel/dangerous commands are hard-denied** (`risk.deny_reason`): in the default async mode,
  ordinary commands (`python`/`node`/`go`/`rust`/`apt`/`pip`/`npm`, incl. T1/T2) **run immediately
  inside the sandbox without approval** and all writes freeze as candidates; only the following are
  **rejected without execution**: kernel module/state (`modprobe`/`insmod`/`rmmod`/`kmod`/`modinfo`/
  `sysctl`/`kexec`/`reboot`/`shutdown`/`poweroff`/`halt`/`bpf`/`perf`), `setcap`, kernel firewall
  (`iptables`/`ip6tables`/`nft`/`arptables`/`ebtables`), `swapon`/`swapoff`, and destructive
  patterns that **bypass the file staging layer** (`mkfs`, `dd of=/dev/*`, `> /dev/sd*`, fork
  bombs, `curl … | sh`). Pure file modifications such as `rm`/`rm -rf` are **not** in the hard-deny
  list: the read-only root + overlay staging already protect the host, and their deletions freeze as
  candidates pending review (see §5 staging). When a segment starts
  with a wrapper (`sudo`/`doas`/`env`/`bash -c`, …) the real command is identified beneath it.
  `mount`/`umount` remain T2 host operations (frozen as proposals, `sudo` replay after approval),
  and `mknod`/`unshare` etc. are handled by the seccomp baseline and namespace isolation rather than
  this hard-deny list.

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
  kept only when the command itself matches a device-level destructive pattern (`mkfs`,
  `dd of=/dev/*`, `curl … | sh`, …).
  - **Relaxed risk/prompt** (`privilege.package_sensitive`): a **safe install** (no third-party repo
    or key change, e.g. a plain `apt/pip/npm install`) is not escalated to L2 by writing system paths
    such as `/usr`/`/var`/`/etc` — it is **capped at moderate (L1)** and does not trigger secret false
    positives. A **sensitive install** (`add-apt-repository`/`sources.list`/`--add-repo`/
    `--index-url`/`npm --registry`, or `apt-key`/`trusted.gpg`/`keyring`/`gpg --import`/`rpm --import`
    changing a third-party repo or key/trust chain) keeps the L2 high rating and is labelled
    `⚠ 涉及软件源/密钥` on the review header. The relaxation only affects **risk and prompts**: package
    writes still go through staging and require user confirmation, never auto-applying.
  - **apt privilege drop disabled** (`packages.apt_sandbox_user`, default `"root"`): as root, apt
    drops downloads/verification to the `_apt` user (`setgroups` + `setuid/setgid`); in a nested user
    namespace / restricted container `setgroups` returns EPERM, so `apt-get update`/`install` fail
    with `setgroups failed - Operation not permitted`. The sandbox is already namespace + overlay
    staging isolated and the payload runs as root, so by default a read-only apt config fragment is
    bound in and `APT_CONFIG` points at it, setting `APT::Sandbox::User "root"` to disable that drop.
    Set `"_apt"` or an empty string to keep apt's default behaviour.
  - **Interpreter module form**: `python3 -m pip install …` is also recognised as a package install
    (the module after `-m` is the manager). For package-install commands the sandbox injects
    `PIP_BREAK_SYSTEM_PACKAGES=1`/`PIP_ROOT_USER_ACTION=ignore`, bypassing Debian/Ubuntu's PEP 668
    (`externally-managed`) restriction — every write still goes through the overlay staging and
    freezes as a candidate, never touching the host.
  - **Installed artifacts are visible across commands**: package writable roots that have staged
    changes (e.g. `/usr`, `~/.local`) are automatically added to later commands' writable layer, so a
    subsequent `python -m build` can see the package just installed (non-package commands otherwise
    only cover the cwd).
  - **Volatile indexes/caches skipped** (`packages.volatile_paths`, non-empty by default):
    `apt update`/`pip`/`npm` etc. rewrite package indexes and caches (e.g. `/var/lib/apt/lists`).
    Their baseline usually changed by apply time, so the whole install would fail with
    `BASELINE_CHANGED`. These paths are skipped when freezing the candidate (not enqueued, not
    CAS-published); the install is unaffected (package files, `/var/lib/dpkg/status`, etc. still
    apply) and the host rebuilds indexes on its own. Set to `{}` to disable skipping (old behavior).

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

### 18.3 Container facade (`sandbox/container.lua`)

When the AI invokes a container runtime, it is managed **inside the sandbox and never changes the
host**. The facade (`container.facade`) intercepts the command in the `effect="process"` branch:

- **Daemonless runtimes** (`podman`/`buildah`): supported. The CLI runs inside the sandbox and the
  container is its child; the command is rewritten to inject
  `--net=host --pid=host --ipc=host --uts=host`, so the container reuses the sandbox's
  pid/net/ipc/uts namespaces and is confined by the sandbox boundary; writes go into the overlay
  staging (`tools.sandbox.container.share_namespace`, default on).
- **docker / docker-compose**: by default they are **rewritten to `podman` / `podman-compose`** and run
  inside the sandbox (`tools.sandbox.container.docker_to_podman`, default on) — podman is daemonless,
  so containers follow the sandbox namespaces and writes go into the overlay, **never touching the
  host**. When podman is absent, the call is **explicitly rejected** (`CONTAINER_PODMAN_UNAVAILABLE`,
  suggesting installing podman), with **no hostop fallback**.
- **nerdctl / daemon-backed runtimes**: containers are created by the host-side daemon, so by default
  they are **explicitly rejected** (`CONTAINER_REQUIRES_HOST_DAEMON`; **no host fallback and no
  hostop**). Only when `tools.sandbox.docker.mode="controlled"` and `socket` exist is a controlled
  socket allowed (rootless / socket-proxy / dind, see §17; an explicit config wins over rewriting).
- **Remote/connection options** (`--remote`/`-r`/`-H`/`--host`/`--connection`/`--url`) and **host VM
  subcommands** (`podman machine`) are explicitly rejected (`CONTAINER_REMOTE_UNSUPPORTED` /
  `CONTAINER_SUBCOMMAND_UNSUPPORTED`).
- The facade only recognizes **standalone calls** (skipping `sudo`/`env` prefixes); container calls
  inside compound commands are not intercepted.

A controlled plan is stored as `kind="container"` evidence and emits `SANDBOX_CONTAINER_PLANNED`;
rejected calls emit `SANDBOX_CONTAINER_UNSUPPORTED` and are audited. Config:
`tools.sandbox.container` (`enabled`/`share_namespace`) and `tools.sandbox.docker`
(`mode="off"|"controlled"`, `socket`).

### 18.4 Auto-approval for new sessions (default off)

`tools.sandbox.review.session_auto_approve` (default false): when on, L0/L1 risks auto-apply while
L2+ and packages/secrets still require review. This lets even a local model manage agent behavior
under write protection. Toggle at runtime with `:NeoAISandboxAutoApprove [on|off|status]`.

### 18.5 Extra rules for package installs

Package installs (`apt/pip/npm/go/cargo/gem/composer…`) are classified as `package` (T1, network).
`tools.sandbox.packages.mode`: `review` (default, forced review, **not auto-approved by session
auto-approval**), `allow`, or `deny`. Their writes still go through staging.
After the relaxation, safe installs need only one confirmation (risk capped at moderate) while
sensitive installs (third-party repo/key changes) keep the high-risk label and go through
"AI warns of consequences → second confirmation" (`review.l3_warning.package_confirm`, on by
default); neither auto-applies. Volatile indexes/caches (`packages.volatile_paths`) are skipped at
freeze time to avoid whole-unit publish conflicts.

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
  `SANDBOX_AUDIT_ANOMALY` / `SANDBOX_CONTAINER_PLANNED` / `SANDBOX_CONTAINER_UNSUPPORTED` /
  `SANDBOX_SYSTEMD_ROUTED` / `SANDBOX_SYSTEMD_UNSUPPORTED` / `SANDBOX_SENSITIVE_REDACTED`.
- Tests: `lua/NeoAI/tests/test_sandbox_governance.lua`.

### 18.8 Common sandbox limitations and workarounds

- **`/run` is writable** (default): `/run` (and `/var/run`) is a per-session private writable root
  (`tmpfs_roots`), so dpkg postinst can create the `adduser` lock file (`/run/adduser`) and
  `/var/run/postgresql`; sensitive host `/run` entries (dbus/sshd/docker.sock, ...) stay masked by
  `mask_paths`.
- **dpkg installs**: `dpkg`/`dpkg-deb`/`update-alternatives`/`ldconfig`/`debconf` are classified as
  package installs, regaining `packages.cap_add` (incl. `CAP_CHOWN`) and unmasking the account DB via
  `packages.unmask`, so postinst `adduser`/`chown`/`su - <svc>` work (writes still go to the overlay
  staging and require approval to publish).
- **`/var/cache/apt` and other foreign-owner dirs**: the payload runs as root and the T0/T1 baseline
  includes `CAP_DAC_OVERRIDE`, so it can bypass DAC to reach 0700 directories owned by other uids
  (e.g. `_apt`'s `/var/cache/apt/archives/partial`); without that capability ordinary commands get
  `Permission denied` (package-install commands also get `packages.cap_add` and are unaffected). For
  stricter least privilege, remove it in `tools.sandbox.privilege.tiers[n].cap_add` (and accept the
  resulting limits).
- **Overlay lower `chown`**: even with `CAP_CHOWN`, overlayfs may return `EPERM` for `chown` on a
  **merged directory** on some kernels (copy-up needed). This is a kernel limitation; postinst
  scripts usually tolerate it (`|| true`).
- **`git clone`/`git init`**: allowed (they create a new repository; `.git` is captured atomically by
  `git_path_class`); `commit/checkout/fetch/pull/push/add/reset/...` remain blocked and must use the
  dedicated git tools.
- **Localhost port allowlist**: all host-local targets are blocked by default; to self-test a service
  started inside the sandbox set `tools.sandbox.network.allow_localhost_ports = { 5432, 6379 }`
  (only **loopback + listed ports**; host NIC IPs / link-local / cloud metadata are never allowed).
- **`grpcurl` etc. not in distro repos**: not a sandbox limitation; install via the language ecosystem
  (e.g. `go install github.com/fullstorydev/grpcurl/cmd/grpcurl@latest`, via the Go proxy).
- **`SANDBOX_STAGING_UNCOVERED`**: when unpublished staged changes exist but the command has no
  writable overlay layer, execution is rejected by default; apply/discard the staged changes first, or
  set `tools.sandbox.staging_uncovered = "warn"` to run degraded (with a notice).
- **Locating fixed overhead**: with `tools.sandbox.diagnostics.enabled = true`, logs record
  `[sandbox-profile] gate:<tool>` end-to-end time and `settle` (risk grading/enqueue/publish) time, to
  tell slow execution from slow freeze/settle.
