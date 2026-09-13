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
| `sandbox/network.lua` | Controlled network gateway (offline by default, declared endpoints only) |
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
| `network` | Network side effects (web_fetch/read_image) | Offline by default, hard deny |

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
- Async confirmation commands:
  - `:NeoAISandboxReview` — list pending changes and apply the selected one (`vim.ui.select`).
  - `:NeoAISandboxApprove <id>` / `:NeoAISandboxReject <id>` — approve (no apply) / reject & discard.
  - `:NeoAISandboxApply <id>` — approve and apply (CAS publish); `:NeoAISandboxApplyAll` applies all.
  - `:NeoAISandboxList` / `:NeoAISandboxShow` / `:NeoAISandboxDiscard <digest>` / `:NeoAISandboxCommit <digest>`.
- Selective apply: `sandbox.apply(id, { files = { ... } })` applies only a subset of files.

### Staging

- **Explicit-path tools** (`edit_file`/`create_directory`/`ensure_dir`/`delete_file`): the
  gate rewrites path args to a private copy under `<root>/attempts/<attempt_id>/upper/...`.
- **Buffer-persist tools** (`delete_node`/`lsp_rename`/`lsp_format`): `tool_helpers.persist_buffer`
  redirects `:write!` to staging while the sandbox is active.
- **External processes** (`run_command`): with the bwrap backend, overlayfs uses the real cwd as a
  read-only lower and a private upper; the command can read the project, writes land in upper and
  are frozen as a candidate (creates/modifies by relative path; deletions/whiteouts are not captured yet).
- Freeze computes a manifest (create/modify/delete/mkdir/rmdir + before/after hashes).

## 6. Runtime backend

- `bwrap` (if present): `--unshare-all --ro-bind / /`, read-only rootfs + private cwd.
- `unshare` (fallback): `--user --map-root-user --mount --pid --fork --ipc --uts --mount-proc --net`
  (offline by default).
- Capability probe: `bwrap`/`unshare`/userns/cgroup v2/overlayfs/seccomp.
- Missing capabilities return a clear error (`SANDBOX_BACKEND_UNAVAILABLE`); no silent downgrade.

> In-process tools (LSP/treesitter/UI) cannot be namespace-isolated; they are constrained by
> "read-only by default + staged writes + policy gate". This is a documented boundary.

## 7. Configuration

```lua
require("NeoAI").setup({
  tools = {
    sandbox = {
      enabled = true,
      fail_closed = true,
      mode = "dry_run",              -- dry_run | commit
      backend = "auto",              -- auto | bwrap | unshare
      offline = true,
      require_seccomp = false,
      seccomp = { enabled = false, filter_path = "" }, -- built-in denylist filter; bwrap backend only
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
and conflict, buffer write redirection, runtime probe and isolated process execution.

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

### Controlled network gateway

Offline by default. With `tools.sandbox.network.enabled=true` and declared `allowed_endpoints`
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

- Enabled with `tools.sandbox.seccomp.enabled=true`; off by default.
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
