# NeoAI 工具执行沙箱（dry-run 与 commit）

> [English](en/sandbox.md) | **中文**

> 对应设计文档《Agent 沙箱 dry-run 与 commit 架构设计 v2.1》。
> 对应源码：`lua/NeoAI/sandbox/*`、`lua/NeoAI/tools/executor.lua`、
> `lua/NeoAI/tools/registry.lua`、`lua/NeoAI/plugins/catalog.lua`。

## 1. 目标

为**整个工具执行系统**套上受约束的执行边界：所有工具调用必须经过控制面
（预检 → 隔离执行 → 冻结候选 → 校验与授权 → CAS 发布 → 发布后核验），
不得绕过沙箱直接改动宿主真实工作区。

核心不变量：

1. dry-run 不构成安全边界；所有预测与真实执行都在受控运行时中。
2. 隔离执行只改可丢弃的私有状态，不写宿主真实工作区、不调真实外部写接口。
3. commit 只发布已冻结、已校验、已授权的候选，不重跑原命令。
4. 硬拒绝不可被人工确认覆盖；未知结果不报告为成功或可重试。
5. 沙箱服务缺失且 `fail_closed=true` 时**拒绝执行**，不静默降级。

## 2. 模块结构

| 模块 | 职责 |
| --- | --- |
| `sandbox/init.lua` | 控制面入口：`init/probe/gate/attach/commit/discard/list/show` |
| `sandbox/control.lua` | 标识/摘要、状态机、幂等键、租约与 fencing token |
| `sandbox/policy.lua` | 规则评估与聚合（DENY > NEEDS_CONFIRMATION > ALLOW）、受限 Lua 规则沙箱 |
| `sandbox/runtime.lua` | 外部隔离后端探测与进程前缀（bwrap 优先，unshare 兜底） |
| `sandbox/candidate.lua` | 私有暂存层、候选冻结、CAS 发布 |
| `sandbox/store.lua` | 候选与发布回执持久化（可查询对账） |
| `sandbox/review.lua` | 异步审批：变更单元队列与 review/apply 状态 |
| `sandbox/impact.lua` | fs/process/network 影响记录与紧凑统计（未知用 null） |
| `sandbox/evidence.lua` | 证据保存、脱敏、分页读取 |
| `sandbox/grant.lua` | 窄范围任务授权（范围/操作/预算/有效期/撤销） |
| `sandbox/envelope.lua` | 裁决信封（decision/severity/stats/asks/evidence） |
| `sandbox/network.lua` | 受控网络网关（默认离线，按声明端点放行） |
| `sandbox/broker.lua` | 外部操作适配器协议（幂等/查询/补偿能力声明与对账） |
| `sandbox/replay.lua` | 策略回放（同规则同事实复现裁决） |
| `sandbox/cgroup.lua` | cgroup v2 资源域（内存/PID/CPU），每次尝试独立域 |
| `sandbox/seccomp.lua` | seccomp 能力探测与 require_seccomp 门禁 |
| `sandbox/cache.lua` | 内容寻址缓存（隔离写入、可清理） |
| `sandbox/fault.lua` | 故障注入（后端/冻结/发布/持久化），用于恢复路径验证 |
| `sandbox/bench.lua` | 控制面关键路径性能基准 |
| `sandbox/tool_spec.lua` | 每个工具的影响类别（effect）与暂存路径声明 |
| `sandbox/wrapper.lua` | 执行门禁：`attach` 附加规格、`gate` 强制过闸门 |

## 3. 强制入口（加载器 + 执行器）

**加载器**是强制点之一：

- `plugins/catalog.lua` 的 `_tool_spec` 依赖 `services.sandbox`，并把沙箱服务传入
  `tools.load_module(mod_name, { sandbox = ... })`。
- `tools/init.lua` 的 `load_module` 对每个工具调用 `sandbox.attach(tool)` 后再注册。
- `tools/registry.lua` 的 `register/update` 统一 `attach`，覆盖 **MCP 动态注册**等
  不经过加载器的工具。
- `tools/executor.lua` 在真正执行前调用 `services.use("services.sandbox").gate(...)`；
  服务缺失且 `fail_closed` 时直接 reject。这是所有执行路径的最终闸门。

`attach` 为工具写入 `__sandboxed = true` 与 `__sandbox_spec = { effect, paths }`。

## 4. 影响类别（effect）

| effect | 含义 | 处理 |
| --- | --- | --- |
| `read` | 只读（read_file/list/search/lsp/tree/git 只读） | 进程内执行，记录只读回执 |
| `in_process` | 进程内状态变更（todo/plan/ask_user/skills 等） | 进程内执行，记录回执 |
| `fs_write` | 写宿主文件系统 | 写入私有暂存层，冻结候选 |
| `process` | 启动外部进程（run_command 等） | 经 `runtime.process_prefix` 隔离执行 |
| `network` | 网络副作用（web_fetch/read_image） | 默认离线，直接硬拒绝 |

未知工具按类别默认归类；仍未知按最保守的 `process` 处理。

## 5. 异步审批与 dry-run/commit

默认采用**异步审批**（`tools.approval.mode = "async"`，设计文档 §15）：AI 的工具调用
**立即在沙箱内执行并冻结候选**，不阻塞等待用户；真实工作区的修改进入待审队列，
由用户异步确认允许哪些文件/配置修改后再 CAS 应用。旧的执行前阻塞审批仅在其他
`approval.mode`（`prompt`/`strict`）下保留。

- 每个效果类候选生成一个**变更单元（change_set）**，含 `change_set_id`、`write_set`、
  `review_state`（`PENDING`/`APPROVED`/`REJECTED`）与 `apply_state`
  （`NOT_REQUESTED`/`APPLYING`/`APPLIED`/`CONFLICT`/`FAILED`）。
- `tools.sandbox.mode = "dry_run"`（默认）：执行后进入待审队列，不写真实工作区。
- `tools.sandbox.mode = "commit"`：任务授权内执行后立即 CAS 发布（窄范围自动应用）。
- 异步确认命令：
  - `:NeoAISandboxReview` — 列出待审修改，选择后应用（`vim.ui.select` 异步选择）。
  - `:NeoAISandboxApprove <id>` / `:NeoAISandboxReject <id>` — 批准（不应用）/ 拒绝并丢弃。
  - `:NeoAISandboxApply <id>` — 批准并应用（CAS 发布）；`:NeoAISandboxApplyAll` 批量应用。
  - `:NeoAISandboxList` / `:NeoAISandboxShow` / `:NeoAISandboxDiscard <digest>` / `:NeoAISandboxCommit <digest>`。
- 选择性应用：`sandbox.apply(id, { files = { ... } })` 只应用指定文件子集（重新冻结组合候选后 CAS）。

### 暂存机制

- **显式路径工具**（`edit_file` / `create_directory` / `ensure_dir` / `delete_file`）：
  门禁把路径参数重写到 `<root>/attempts/<attempt_id>/upper/...` 的私有副本，
  工具只改副本。
- **buffer 写盘工具**（`delete_node` / `lsp_rename` / `lsp_format`）：
  `tool_helpers.persist_buffer` 在沙箱激活时把 `:write!` 重定向到暂存层。
- **外部进程**（`run_command`）：bwrap 后端用 overlayfs 把真实 cwd 作为只读 lower、
  私有 upper 作为可写层，命令看到的项目可读、写入落到 upper，随后冻结为候选
  （相对路径的新建/修改；删除的 whiteout 暂不捕获）。
- 冻结时对比基线生成候选清单（create/modify/delete/mkdir/rmdir + before/after hash）。

## 6. 运行时后端

- `bwrap`（若存在）：`--unshare-all --ro-bind / /` 等，只读 rootfs + 私有 cwd。
- `unshare`（兜底）：`--user --map-root-user --mount --pid --fork --ipc --uts --mount-proc --net`
  （默认离线）。
- 能力探测：`bwrap` / `unshare` / unprivileged userns / cgroup v2 / overlayfs / seccomp。
- 能力缺失时返回明确错误（`SANDBOX_BACKEND_UNAVAILABLE`），**不静默降级**。

> 说明：进程内工具（LSP / treesitter / UI 交互）无法用 namespace 隔离，
> 以「只读默认 + 写入暂存 + 策略门禁」约束；这是已记录的边界，不声称硬隔离。

## 7. 配置

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
      seccomp = { enabled = false, filter_path = "" }, -- 内置 denylist 过滤器；仅 bwrap 后端
      workspace_root = vim.fn.stdpath("cache") .. "/NeoAI/sandbox",
      review = { enabled = true, auto_apply = false }, -- 异步审批：候选进入待审队列
      retention = { candidate_days = 7, max_pending = 20 },
      policy = {
        deny_tools = {},             -- 硬拒绝工具名（确认亦不可覆盖）
        rules = {},                  -- 受限 Lua 规则函数数组
      },
      limits = { wall_ms = 60000, memory_bytes = 0, pids = 0 },
    },
  },
})
```

策略规则在受限环境执行（显式函数白名单，禁 `os/io/debug/load/require`），
并有指令/墙钟预算；规则异常、超时、结构错误统一产生 `DENY`
（`POLICY_EVALUATION_FAILED`）。聚合顺序为 `DENY` 高于 `NEEDS_CONFIRMATION` 高于 `ALLOW`。

## 8. 事件

`SANDBOX_PUBLISH_STARTED` / `SANDBOX_COMMITTED` / `SANDBOX_DISCARDED` /
`SANDBOX_CONFLICT`，以及异步审批 `SANDBOX_REVIEW_ENQUEUED` / `SANDBOX_REVIEW_APPROVED` /
`SANDBOX_REVIEW_REJECTED` / `SANDBOX_APPLIED`，详见 [EVENTS.md](EVENTS.md)。

## 9. 测试

`lua/NeoAI/tests/test_sandbox.lua` 覆盖：加载器强制附加规格、fail-closed、
状态机/幂等/fencing、策略聚合与受限规则、dry-run 不落盘、CAS 发布与冲突、
buffer 写盘重定向、运行时能力探测与隔离进程执行、异步审批入队/应用/拒绝、
run_command overlay 候选捕获。

## 10. 影响、证据、授权与外部操作（阶段二/三）

### 影响与证据

- `impact` 统一记录 fs/process/network，每条标注 `source`/`coverage`/`evidence_id`；
  未知字段用 `null` 表达（禁止以 0 冒充未知）。
- `evidence` 保存过程观测并做秘密字段脱敏（`token`/`secret`/`password` 等 → `[redacted]`），
  支持 `evidence_page({ after_id, limit })` 分页。
- 每次候选冻结会写入一条证据，并在 `review` 项与裁决信封中携带 `evidence_id`。

### 任务授权（grant）

窄范围授权：`scope.paths`（支持 `/**` 递归）、`operations`、`budget.max_files`、`ttl_sec`。
当活跃授权覆盖候选（范围包含全部写路径、操作允许、预算充足）时，候选**自动 CAS 应用**
（等价 `TASK_POLICY_MATCH`）并消费预算；否则进入用户异步审批。撤销即时生效。

```
:NeoAISandboxGrant [path] [ttl_sec] [max_files]   -- 创建窄范围授权
:NeoAISandboxRevoke <grant_id>                    -- 撤销（无参数列出全部）
```

### 受控网络网关

默认离线。`tools.sandbox.network.enabled=true` 且 `allowed_endpoints` 声明后，按应用层
端点（主机模式，支持 `*.example.com`）放行，并受 `budget_bytes` 约束；未声明端点仍拒绝。
L3/L4 五元组不能独立证明应用层身份，故以声明端点为准。

### 外部操作 broker

外部副作用走适配器协议，不套用本地文件发布的原子性/回滚承诺。适配器须声明
`supports_idempotency` / `idempotency_retention` / `supports_query` / `transaction_boundary` /
`compensation_semantics` / `irreversible_effects`。broker 以稳定 `operation_id` 记录意图，
按幂等键去重，并在结果不明时进入 `OUTCOME_UNKNOWN`、由 `reconcile` 查询对账，禁止盲目重放。

### 保留期与指标

`:NeoAISandboxPrune` 按 `retention.candidate_days` 清理已终结（已拒绝/已应用/失败/冲突）的
候选与变更单元；有恢复/对账/已排队引用者不清理。`:NeoAISandboxMetrics` 输出候选/待审/已应用/
已拒绝/冲突计数。

## 11. 阶段四：依赖图、组合发布与回放

- 变更单元可声明 `depends_on`（依赖其它变更单元）；`dependencies(id)` 返回拓扑闭包，
  缺失依赖 → `BLOCKED_DEPENDENCY`。
- `prepare_publication_set(ids)` 计算依赖闭包并**合并成员候选为组合候选**（按路径合并；
  同路径不同内容 → `PATH_CONFLICT`），生成 `publication_intent_hash`（绑定成员版本与
  组合摘要）。此步无发布副作用。
- `apply_set(set)` 对组合候选做 CAS 发布；成功后标记所有成员 `APPLIED` 并写回执。
  选择 B 而未选依赖 A 时不会夹带 A：缺依赖返回 `BLOCKED_DEPENDENCY`。
- 命令：`:NeoAISandboxPublish <id> [id...]`。

### 策略回放

- 效果类裁决会记录为证据（含事实与 `policy.version`）；`replay(evidence_id)` 用同版规则
  与同一事实重放并比对 `decision`/`reason_codes`，返回 `same` 与 `version_mismatch`。
- 命令：`:NeoAISandboxReplay <evidence_id>`。回放默认禁用联网，不重新发送真实外部写请求。

### 证据保留期

`prune()` 按 `retention.candidate_days` 同时清理过期候选/变更单元与观测证据；
裁决记录默认保留以支持策略回放（`evidence.prune(days, { keep_kinds = { "decision" } })`）。

## 12. 阶段五：资源域、seccomp 门禁与缓存

### cgroup v2 资源域

每次外部进程尝试使用独立资源域 `tools.sandbox.limits`（`memory_bytes` / `pids` / `cpu_max`）。
配置了任一限制时，控制面创建 cgroup v2 子域并把进程加入（`join_prefix` 先写 `cgroup.procs`
再 exec），结束/异常时 `cgroup.kill` 并删除子域，确保进程树收敛。**cgroup 不可用但配置了限制时
明确拒绝**（`SANDBOX_CGROUP_UNAVAILABLE`），不静默降级。

### seccomp 基线

内置生成 denylist 过滤器（x86_64/aarch64）：先校验 `AUDIT_ARCH`（不符直接 `KILL_PROCESS`），
再对危险 syscall（`ptrace`/`mount`/`unshare`/`setns`/`bpf`/`kexec_load`/`init_module`/
`io_uring_*`/`open_by_handle_at`/…）返回 `EPERM`，其余 `ALLOW`。经 `bwrap --seccomp FD`
在载荷 exec 前施加（bwrap 特权设置不被过滤）：`runtime` 用 shell 打开过滤器 fd 再 exec bwrap。

- `tools.sandbox.seccomp.enabled=true` 时启用；默认关闭。
- `filter_path` 为空则用内置 denylist 生成到 `<root>/seccomp/baseline-<arch>.bpf`；
  非空则必须存在，否则明确拒绝。
- `require_seccomp=true` 要求外部进程有可用过滤器（且后端为 bwrap），否则返回
  `SANDBOX_SECCOMP_UNAVAILABLE`，不声称已施加。
- 仅 bwrap 后端支持；unshare 后端在启用/要求时明确拒绝。

### 内容寻址缓存

`sandbox/cache.lua` 按内容键（覆盖输入/运行时/规则/事实）缓存依赖或产物；写入方隔离、
原子写，支持 `prune(days)`。授权与撤销状态不可通过旧缓存跳过。

## 13. 阶段六：故障注入、性能基准与 revision 派生

### 故障注入

`sandbox/fault.lua` 在关键点注入可控故障：`backend`（后端不可用）、`freeze`（候选冻结失败）、
`publish`（CAS 发布失败）、`store`（持久化失败）。仅测试/诊断使用，默认不注入。用于验证：
- 发布失败**不产生部分写入**（真实工作区保持原状）；
- 后端不可用时进程被明确拒绝；
- 冻结失败被拒绝且不产生待审变更单元。

### 性能基准

`sandbox/bench.run({ iterations })` 测量策略评估、摘要、尝试签发、信封构建等关键路径，
返回 `{ iterations, total_ms, per_op_ms }`；用于性能回归与容量评估。

### revision 派生（按文件/hunk 拆分）

`review.derive_revision(parent_id, { contents?, paths? })` 基于原候选重新生成组合候选，
形成新 `revision` 并要求**重新审查**；原变更单元标记 `SUPERSEDED`，**不迁移旧批准**。
这是设计文档 §15.3「按文件或 diff hunk 进一步拆分时必须先生成新组合候选、重新验证」的落地路径。

## 14. 阶段边界

阶段一：本地文件最小安全闭环。阶段二：影响/证据分页、任务授权与撤销、裁决信封、
保留期与指标。阶段三：受控网络网关与外部操作 broker。阶段四：依赖图与组合候选、
策略回放、证据保留期。阶段五：cgroup 资源域、seccomp 门禁与内容寻址缓存。
阶段六：故障注入、性能基准与 revision 派生。后续：其他 runtime 后端、seccomp BPF 实际生成、
分布式/多工作区扩展。
