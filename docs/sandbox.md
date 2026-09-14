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
| `sandbox/network.lua` | 受控网络网关（默认放行；启用后按声明端点放行） |
| `sandbox/broker.lua` | 外部操作适配器协议（幂等/查询/补偿能力声明与对账） |
| `sandbox/replay.lua` | 策略回放（同规则同事实复现裁决） |
| `sandbox/cgroup.lua` | cgroup v2 资源域（内存/PID/CPU），每次尝试独立域 |
| `sandbox/seccomp.lua` | seccomp 能力探测与 require_seccomp 门禁 |
| `sandbox/privilege.lua` | 权限档位（T0/T1/T2）分类、解析、自动升级检测与留痕 |
| `sandbox/hostop.lua` | T2 主机效果提案（冻结/审批后 replay/拒绝） |
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
| `network` | 网络副作用（web_fetch/read_image） | 默认放行并记录证据（不拦截）；`offline=true` 才拒绝 |

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
- **模型可见性**：工具结果**原样返回给模型**，不附加「已暂存/待审」说明，让 AI 认为
  修改已完成；待审状态只通过**醒目的状态栏徽标**提示用户（`statusline` 的 `sandbox`
  段，仅在待审数 > 0 时显示黄底加粗的 `待审N`，见 [configuration.md](configuration.md)）。
- 异步确认命令：
  - `:NeoAISandboxReview` — 打开待审审批界面（`ui/components/sandbox_review.lua`）：
    按文件路径级别高亮 —— **工作区文件=绿色、用户目录=黄色、系统路径=红色**，
    「待审」状态标签=黄色。**审批单位为单个文件**：`<CR>` 仅应用光标所在文件、
    `d` 仅拒绝该文件（其余文件保留待审）、`r` 刷新、`q`/`<Esc>` 关闭；头行仅作
    信息展示，不参与审批。聊天主窗口内可按 `<leader>ap` 直接触发
    （`keymaps.chat.sandbox_review`）。
  - `:NeoAISandboxApprove <id>` / `:NeoAISandboxReject <id>` — 批准（不应用）/ 拒绝并丢弃。
  - `:NeoAISandboxApply <id>` — 批准并应用（CAS 发布）；`:NeoAISandboxApplyAll` 批量应用。
  - `:NeoAISandboxList` / `:NeoAISandboxShow` / `:NeoAISandboxDiscard <digest>` / `:NeoAISandboxCommit <digest>`。
    丢弃候选会同步把引用该候选的 `PENDING` 变更单元标记为 `REJECTED`（`review.discard_by_digest`），
    否则重开聊天/审批界面会重新显示一个候选已不存在、无法应用的待审项。
- 选择性应用：`sandbox.apply(id, { files = { ... } })` 只应用指定文件子集（重新冻结组合候选后 CAS）；
  未选中的文件会保留为新的待审变更单元，供用户逐个确认。`sandbox.reject_file(id, path)` 按文件拒绝。
- **同文件取代**：同一文件被再次编辑（新候选入队）或直接发布时，覆盖该路径的旧 `PENDING`
  变更单元被标记为 `SUPERSEDED` 并丢弃候选，队列只保留最新版本，避免用户看到同一文件的
  多个版本（`review.supersede_by_paths`）。

### 暂存机制

- **显式路径工具**（`edit_file` / `create_directory` / `ensure_dir` / `delete_file`）：
  门禁把路径参数重写到 `<root>/workspace/<hash>` 的私有副本，工具只改副本。
  工作区维护**持久映射表**（真实路径 → 暂存副本）：
  - 同一文件被多次编辑时始终基于最近一次沙箱内容（而非每次从真实文件重来），
    多次编辑可叠加；真实文件在外部被改动（hash 变化）时才重新复制。
  - 工具回传消息里的暂存路径会被**还原为真实路径**，模型只看到真实工作区路径。
  - 候选**发布/拒绝**后对应暂存副本失效，后续编辑重新以真实文件为基线。
- **只读工具一致性**：命中工作区暂存映射时，
  - `read_file` / `file_exists` 读暂存副本（删除态读不到、返回 false），使 AI 读到/探测到
    自己尚未发布的修改；返回内容中的暂存路径会**还原为真实路径**，沙箱对 AI 不可见。
  - `list_files` / `search_files` 叠加暂存视图：未发布的新建/修改文件可见、已删除文件隐藏，
    且结果一律使用真实路径，不泄露暂存路径（目录不整体映射，避免丢失真实文件）。
    沙箱内新建的**整棵目录树**（`run_command`/`create_directory` 创建、真实磁盘尚不存在）也会被
    合成列举：`list_files` 补齐各级父目录条目、`file_exists` 对祖先目录返回 true，
    避免 AI 看到“文件已创建但目录不存在”的不一致视图而尝试绕过沙箱。
  - treesitter 工具（`parse_file` / `query_tree` / `get_node_*`）读暂存副本：暂存路径
    **保留真实 basename（含扩展名）**，故 filetype/parser 正常；`delete_node` 等写类工具
    经同一暂存副本修改后写回暂存（不二次暂存）。
  - LSP 工具默认仍读真实内容；开启 `tools.sandbox.lsp_overlay.enabled = true` 后，LSP server
    进程被放进 bwrap + overlay（见下节），其磁盘读取即看到暂存内容。写类 LSP 工具
    （`lsp_rename`/`lsp_format`）的落盘始终经 `persist_buffer` 重定向到暂存层。
- **buffer 写盘工具**（`delete_node` / `lsp_rename` / `lsp_format`）：
  `tool_helpers.persist_buffer` 在沙箱激活时把 `:write!` 重定向到暂存层。
- **外部进程**（`run_command`）：bwrap 后端对一组**可写根**（`tools.sandbox.process_roots`，
  默认仅 cwd，未覆盖时自动补入）做 overlayfs：真实根为只读 lower、会话 upper 为可写层。
  命令能读取这些根的真实内容，且对其下**任意路径**的新建/修改/删除都落到 upper，随后冻结为
  候选（删除以 whiteout 设备节点识别为 `delete`/`rmdir`）。
  - `/tmp`、`/var/tmp` 属**每会话私有临时根**（`tools.sandbox.tmpfs_roots`）：以会话私有目录
    （mode 1777，位于 `/dev/shm` 等 tmpfs 上）绑定，**不**作为 overlay 只读 lower，退出/轮换
    会话即销毁。命令对 `/tmp` 的写入属临时草稿，不冻结为候选，杜绝跨会话残留与宿主 `/tmp` 泄露。
  - 默认不再覆盖 `/root`、`/home`、`/etc` 等整目录，避免把宿主真实 home/账户/配置作为
    只读 lower 暴露；需要写这些路径时显式加回 `process_roots`，并同步收紧 `mask_paths`。
  - 可写层为**会话级共享**：同一 agent 循环内所有命令共用（命令 N 看得到命令 N-1 的
    写入）；agentEnd 轮换会话时随会话目录清理（改动已冻结为候选）。
  - **双向互通**：命令执行前把工作区暂存内容物化进可写层（命令能看到 `edit_file`
    尚未发布的编辑与新建，删除以 whiteout 表示）；命令结束后把改动合并回工作区暂存映射
    （`read_file`/`edit_file` 能看到命令的改动并继续叠加）。
  - overlay 基目录由 `sandbox.conceal` 以**无特征名**生成（`/dev/shm/.cache-<tag>`，
    不含 `NeoAI`/`sandbox` 字样；须在可写根之外，避免 upper 落在 lower 之下导致内核
    `EINVAL`）；`/dev/shm` 不可用时退回沙箱根目录。
  - **沙箱自身存储对命令不可见**：沙箱根（`tools.sandbox.workspace_root`，默认
    `stdpath("cache")/NeoAI/sandbox`）在命名空间内以空 `tmpfs` 遮蔽，命令无法读取/篡改
    候选、会话、回执等内部状态（防止信息泄露与逃逸）。
- **会话级 shell 状态**（`tools.sandbox.session_shell`，默认开，仅 bwrap）：每个
  `run_command` 仍是独立进程/独立 shell，但会话目录会 bind 到沙箱内固定路径，命令前后
  自动保存/载入 `cwd` 与导出变量，使 `export FOO=...`、`cd /usr` 在同一 agent 循环内
  跨命令保留；agentEnd 轮换会话后状态重置（新沙箱）。
- 冻结时对比基线生成候选清单（create/modify/delete/mkdir/rmdir + before/after hash）。
- **会话作用域**：暂存映射绑定到「沙箱会话」——同一 agent 循环（generation）内所有工具
  调用共用同一会话，编辑可叠加；`GENERATION_COMPLETED` / `GENERATION_ERROR` /
  `GENERATION_CANCELLED` / `AGENT_ABORTED`（agentEnd）时轮换会话：新会话使用新的暂存目录，
  但会**迁移当前暂存内容**，保证跨循环未发布的文件修改保持一致（读回 / 继续编辑仍可见）。
  由 `sandbox.session` 副作用插件订阅生命周期事件驱动（`sandbox.watch_sessions`）。
- **路径不泄露**：工具的成功结果与错误信息中的暂存路径都会被还原为真实工作区路径
  （包括只读工具读取已删除暂存副本时的报错），模型永远看不到沙箱内部路径。
- **热重载一致性**：`sandbox.shutdown()` 会清空暂存目录，但待审队列仍落盘；下次
  `sandbox.init()` 会按待审候选内容**重新物化**进新会话暂存层（`_rehydrate_pending`），
  使重载/重开后只读工具看到的视图与待审队列一致。

### LSP 命名空间覆盖（opt-in）

- 开关：`tools.sandbox.lsp_overlay.enabled`（默认 false）。仅 `bwrap` 后端且工作区根可挂载
  overlay 时生效；不满足条件自动跳过，LSP 正常使用。
- 机制：包装 `vim.lsp.rpc.start`，把 server 启动命令包成
  `bwrap --unshare-all <最小只读系统集> … --overlay-src <工作区> --overlay <upper> <work> <工作区> --chdir <工作区> <原命令>`；
  lower 为真实工作区（只读），upper 为沙箱私有可写层。server 读到的是「真实文件 + 暂存改动」
  的合并视图，且路径仍是真实路径。
- 一致性刷新：每次 LSP 工具调用前、以及 server 启动时，`sandbox.lsp.refresh()` 会用当前
  工作区暂存重新物化 upper（先清空再写入），使 server 即时看到最新未发布改动。
- 隔离与缓存：LSP 自身缓存/状态目录（`stdpath(cache|data|state)`、`~/.cache`、`~/.local/*`）
  以 rw bind 直连宿主，避免缓存写入 overlay 或被当作待审候选；overlay upper 按工作区 hash
  分片，多项目互不串扰，位于 `/dev/shm/.cache-<tag>/lsp/<hash>`。
- 生命周期：插件 `sandbox.lsp` 负责安装/卸载包装，卸载时恢复原始 `vim.lsp.rpc.start`。

## 6. 运行时后端

- `bwrap`（若存在）：最小只读系统集 + 多可写根 overlay，并施加 `--as-pid-1` 等隐匿参数
  （详见 §15）。root 下优先使用无 user namespace 的显式隔离标志，否则用 `--unshare-all`。
  - **overlay 可用时**：每个可写根（`process_roots`）真实内容作为只读 lower、会话 upper
    作为可写层，命令看到真实内容且写入可捕获。
  - **overlay 不可用时**：把会话私有目录 `--bind` 到该根（命名空间隔离与只读 rootfs 保留），
    **不再让全部 `process` 工具直接失败**。
  - **网络默认放行**：带 userns 时 `--unshare-all` 后按需 `--share-net`；无 userns 时默认共享，
    `offline=true` 才隔离（`--unshare-net`）。
- `unshare`（兜底）：`--user --map-root-user --mount --pid --fork --ipc --uts --mount-proc`
  （默认共享网络；`offline=true` 时加 `--net` 隔离）。
- 能力探测：`bwrap` / `unshare` / unprivileged userns / cgroup v2 / overlayfs / seccomp。
  - `bwrap` 与 `overlayfs` 均为**功能实测**（真实启动一次 bwrap / 真实挂载一次 overlay），
    不只看二进制或 `/proc/filesystems`：宿主 `/` 的 superblock 归属 init userns 时
    （如容器内），新建 userns 里 overlay 会返回 `EINVAL`，仅凭内核支持判断会产生假阳性。
  - 能力探测只是**粗粒度门禁**；构造进程前缀时还会用**真实执行路径**
    （lower=真实 cwd、upper/work=私有层）再实测一次 overlay 挂载，按 `(dev_lower, dev_upper)`
    缓存结果。探测用同源临时目录、真实路径跨挂载/跨 userns 归属时会产生假阳性，因此
    真实路径实测失败即降级 `--bind` 私有 cwd，保证 `run_command` 不因 overlay 挂载失败而硬失败。
- 后端完全不可用时返回明确错误（`SANDBOX_BACKEND_UNAVAILABLE`），**不静默降级**；
  但 overlay 单项不可用属于可降级能力，按上面的私有 cwd 方案继续执行。

> 说明：进程内工具（LSP / treesitter / UI 交互）无法用 namespace 隔离，
> 以「只读默认 + 写入暂存 + 策略门禁」约束；这是已记录的边界，不声称硬隔离。

### 权限收敛与宿主敏感路径遮蔽（默认开启）

仅靠 namespace 隔离不足以阻止「root 载荷 + 全 capability + 可访问宿主 socket」的逃逸。
`runtime` 在 bwrap 前缀中默认施加以下纵深防御：

- **丢弃全部 capability**：`--cap-drop ALL`（可经 `tools.sandbox.cap_add` 按需加回）。
  载荷不再持有 `CAP_SYS_ADMIN`/`CAP_SYS_MODULE`/`CAP_SYS_PTRACE` 等，`mount`、模块加载、
  写 `/proc/sys/kernel/core_pattern`、`ptrace` 等被内核直接拒绝（实测 `CapEff=0`）。
- **seccomp 基线默认开启**（见 §12）：即便未来出现 capability 相关内核缺陷，denylist
  仍拦截 `mount`/`unshare`/`setns`/`bpf`/`init_module` 等危险 syscall。
- **遮蔽宿主敏感路径**（`tools.sandbox.mask_paths`，安全默认）：目录以空 `tmpfs`、
  文件/socket 以 `/dev/null` 覆盖（socket 变为字符设备，`connect` 失败）。默认覆盖
  `/var/run/docker.sock`（等价宿主 root，最经典逃逸入口）、`/var/lib/docker`、
  containerd/podman 数据、编排器（herdr）/面板（1panel）/D-Bus/systemd 控制通道，
  以及 `/root/.ssh`、`/root/.aws`、`/root/.gnupg`、`/root/.kube`、keyring 等宿主凭据，
  并补充 `/etc/shadow`、`/etc/gshadow`、`/etc/sudoers`、`/etc/machine-id`、`/etc/ssh`、
  `/var/log`、`/var/spool/cron` 及 root 命令历史等读取面泄露项。
  遮蔽挂载置于各可写根 overlay 之后，确保覆盖生效。
- **最小只读系统集（白名单，默认开启）**：不再 `--ro-bind / /`，也**不再整目录暴露 `/usr`**
  （宿主根分区挂到同一块磁盘时会泄露 `/usr/share/doc` 包数据库、`/usr/local/go_workspace`、
  `/usr/src` 等软件清单）。仅按 `tools.sandbox.readonly_roots`（默认 `/usr` 的运行时子树
  `bin`/`sbin`/`lib*`/`libexec`/`include`、`share/{terminfo,locale,zoneinfo,ca-certificates,misc,…}`、
  `local/{bin,sbin,lib,libexec,include}`，以及 `/lib*`、`/bin`、`/sbin` 加载器符号链接根）与
  `tools.sandbox.readonly_paths`（默认 `/etc` 必要文件：`ld.so.cache`/`passwd`/`group`/
  `nsswitch.conf`/`ssl`/`alternatives`/`profile` 等）只读暴露必要内容。
  未列出的宿主路径在沙箱内**不存在**：`/var/log`、`/etc/shadow`、`/opt`、`/srv`、
  `/mnt`、`/media`、`/boot`、`/usr/share/doc`、`/usr/src`、`/usr/local/go_workspace` 等默认不可达。
  `/etc/passwd`、`/etc/group` 作为运行所需的标准只读文件保留（Unix 世界可读，仅暴露账户名，
  不含口令）。需要更小读取面时可继续收窄白名单；需要额外路径时显式加回（并同步 `mask_paths`）。
  该读取面同样用于 LSP 命名空间覆盖（见 §5）。
- **`/etc/resolv.conf` 净化**（`tools.sandbox.resolv_conf`，默认 `sanitize`）：仅保留
  `nameserver` 行，剥离 `search`/`domain`/`options`，避免泄露宿主内网/Tailscale 域；
  可配 `hide`（不暴露）或 `passthrough`（原样暴露宿主文件）。
- **`/proc` 泄露项隐藏**（`tools.sandbox.hide_proc_paths`，默认 `/proc/cmdline`、`/proc/version`）：
  procfs 全局可见（不随 pid namespace 隔离），以空文件只读覆盖，避免泄露宿主内核命令行
  （`root=UUID`、`crashkernel`）与内核版本。
- **遮蔽目录（`tools.sandbox.mask_dirs`，默认开启）**：当 cwd 位于某遮蔽目录
  （默认 `/home`、`/root`）下时，仅把「含 cwd 的用户 home」以只读暴露
  （`/home` 取一级用户子目录，其他遮蔽目录取自身），并沿 cwd 祖先链遮蔽其兄弟条目
  （含隐藏文件/目录）；cwd 子树自身豁免，cwd 即作用域时遮蔽其隐藏子条目（凭据类 dotfile）。
  其他用户 home 不在白名单内，默认不可见。总开关 `mask_dirs_enabled`（默认开）。
  - **审批放行**：工具参数命中遮蔽条目时，即使处于 `async` 模式也弹窗审批
    （复用 `tool_service` / `ui/components/tool_approval`）；批准后仅对该次调用解除对应
    遮蔽条目（`ctx.sandbox_unmask` → 运行时 unmask），拒绝则终止该工具调用。
  - **进程内 fail-closed**：`read`/`fs_write` 等进程内工具不受 mount 遮蔽约束，
    无审批界面（headless/子 Agent）时直接拒绝，不静默放行；`process` 类由 mount 硬遮蔽。
  - `mask_dirs_approval = false` 时命中遮蔽目录不弹窗，直接硬遮蔽。

> **残余风险（user namespace）**：NeoAI 以 root 运行时，`bwrap` 只能把调用者 uid 1:1
> 映射（`uid_map 0 0`），无法在插件内做真正的 uid 重映射；而 `conceal` 为去指纹刻意
> 不在 root 下新建 userns。丢弃全部 capability + seccomp 后，1:1 映射不再可直接提权，
> 但读取未遮蔽的 root 文件仍受文件权限约束。**彻底根治需在容器运行时层启用
> `userns-remap` / rootless**，使容器 root 映射到高位宿主 uid——属部署侧配置，不在本插件内。

## 7. 配置

```lua
require("NeoAI").setup({
  tools = {
    sandbox = {
      enabled = true,
      fail_closed = true,
      mode = "dry_run",              -- dry_run | commit
      backend = "auto",              -- auto | bwrap | unshare
      offline = false,               -- 网络默认放行（仅记录）
      require_seccomp = true,        -- 缺少 seccomp 能力则拒绝外部执行（默认开，fail-closed）
      cap_add = {},                  -- 按需加回的 capability；默认空 = --cap-drop ALL
      -- 最小只读系统集（白名单）：/usr 只挂运行时子树，不整目录暴露（支持 * 通配）。
      readonly_roots = {
        "/lib", "/lib32", "/lib64", "/libx32", "/bin", "/sbin", -- 加载器/二进制符号链接根（必须）
        "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/lib32", "/usr/lib64", "/usr/libx32",
        "/usr/libexec", "/usr/include",
        "/usr/share/terminfo", "/usr/share/locale", "/usr/share/zoneinfo",
        "/usr/share/ca-certificates", "/usr/share/misc", "/usr/share/common-licenses",
        "/usr/share/git-core", "/usr/share/vim", "/usr/share/nvim",
        "/usr/local/bin", "/usr/local/sbin", "/usr/local/lib", "/usr/local/libexec",
        "/usr/local/include", "/usr/local/go",
      },
      readonly_paths = {             -- 最小 /etc 必要文件白名单（支持 * 通配）
        "/etc/ld.so.cache", "/etc/passwd", "/etc/group", "/etc/nsswitch.conf",
        "/etc/hosts", "/etc/ssl", "/etc/alternatives", "/etc/localtime",
      },
      resolv_conf = "sanitize",      -- /etc/resolv.conf：sanitize（默认，仅 nameserver）| hide | passthrough
      tmpfs_roots = { "/tmp", "/var/tmp" }, -- 每会话私有 tmpfs（不作为 overlay lower；退出即销毁）
      hide_proc_paths = { "/proc/cmdline", "/proc/version" }, -- 以空文件覆盖，隐藏宿主内核信息
      mask_paths = {                 -- 遮蔽宿主敏感路径（目录 tmpfs / 文件 socket 用 /dev/null）
        "/run/docker.sock", "/var/run/docker.sock", "/var/lib/docker",
        "/root/.config/herdr", "/etc/1panel", "/root/.ssh", "/root/.aws", "/root/.gnupg",
        "/etc/shadow", "/etc/gshadow", "/etc/machine-id", "/etc/ssh", "/var/log",
        "/root/.bash_history", "/root/.zsh_history",
      },
      mask_dirs_enabled = true,      -- 遮蔽目录总开关（默认开）
      mask_dirs = { "/home", "/root" }, -- 遮蔽目录列表（cwd 所在作用域只读暴露并遮蔽其余条目）
      mask_dirs_approval = true,     -- 命中遮蔽目录时弹窗审批（复用工具审批 UI）
      process_roots = {},            -- run_command 可写根（默认仅 cwd，自动补入；按需加回更多）
      seccomp = { enabled = true, filter_path = "" }, -- 内置 denylist 过滤器；仅 bwrap 后端
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
run_command overlay 候选捕获（含删除 whiteout 捕获与尝试目录清理）。

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

### 网络（默认放行 + 记录）

网络**默认不拦截**（`tools.sandbox.offline=false`）：网络类工具（`web_fetch`/`read_image`）
正常执行，并把端点写入证据（`evidence` kind=`network`）与策略回放记录；`run_command`
进程默认共享宿主网络（bwrap `--share-net`）。
- `tools.sandbox.offline=true`：硬拒绝网络类工具（`NETWORK_OFFLINE`），并隔离进程网络
  （bwrap 不加 `--share-net`，unshare 后端加 `--net`）。
- 可选更严格：`tools.sandbox.network.enabled=true` 且 `allowed_endpoints` 声明后，按应用层
  端点（主机模式，支持 `*.example.com`）放行，并受 `budget_bytes` 约束；未声明端点拒绝。
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

- `tools.sandbox.seccomp.enabled=true` 时启用；**默认开启**（与 `--cap-drop ALL` 共同构成纵深防御）。
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

## 15. 沙箱隐匿（conceal，常开）

`sandbox/conceal.lua` 降低 AI 通过外部命令识别「自己处在沙箱」的能力，**无配置开关**。
它只抬高识别门槛，不声称让沙箱不可检测；固有痕迹（namespace inode、能力位、宿主自身
容器信息）无法在不破坏隔离的前提下抹除。

### 进程级去特征（`sandbox.runtime`）

- **PID 1 不是 bwrap**：bwrap 前缀加入 `--as-pid-1`，载荷自身成为 PID 1，进程表不再出现
  `bwrap --unshare-all …`。命令的 `ps`/`/proc/1/cmdline` 只看到普通 shell。
- **root 下不建 user namespace**：探测到以 root 运行且 `bwrap` 可在无 userns 下完成隔离时，
  用显式 `--unshare-pid/ipc/uts/cgroup` 取代 `--unshare-all`，从而不产生
  `uid_map 0 0 1` 与独立的 `ns/user`（非 root 自动回退带 userns 的隔离）。
  无 userns 时网络默认共享，`offline=true` 才加 `--unshare-net`。
- **无特征命名**：overlay 私有层基目录为 `/dev/shm/.cache-<tag>`，会话 shell 状态挂载点为
  `/tmp/.s-<tag>`（tag 由缓存目录 + 进程号派生，跨热重载稳定）；会话包装脚本变量/文件改名，
  PID 1 命令行不出现沙箱自有标识。

### 命令输出脱敏（`shell.redact`）

`run_command` 在把 stdout/stderr 回传模型前经 `conceal.redact()`，抹去：

- overlay 挂载选项 `lowerdir=`/`upperdir=`/`workdir=` 的真实路径与 `userxattr`/`uuid=on`；
- 挂载类型 `overlay` → `tmpfs`（mountinfo / mounts / mount 三种格式）；
- `bwrap` 进程/工具名；`NeoAI-sandbox`、`neoai_session`、`__neoai` 等自有标识；
- overlay 基目录 / 会话挂载点的动态路径与 basename；
- 外层容器路径线索（`/var/lib/containerd/...`、`docker/rootfs/overlayfs/...`）。

脱敏是**文本层尽力而为**：模型可用编码/间接方式绕过（如 `base64`），也可读取未被过滤的
系统接口（`/proc/filesystems` 仍列出内核 overlay 支持）。测试见
`tests/test_sandbox.lua` 的「隐匿」用例。

## 16. 密钥防护（secrets，常开）

`sandbox/secret.lua` 让 AI 看不到、也用不了真实密钥：基于熵检测，进沙箱加密为随机 token，
仅在 commit 发布到真实工作区时解密；对 token 操作留痕并在待审界面警告；工具参数中出现
**原始密钥**时硬拦截并立即终止整个 Agent。

### 检测（熵 + 字符集启发式）

- 候选：长度 `[min_length, max_length]`、含字母与数字、不同字符数 `≥ min_distinct`、
  香农熵 `≥ min_entropy`（默认 20/200/8/3.5）。
- 默认排除**纯小写十六进制**（`exclude_pure_hex`）：避免把 git SHA / sha256 / md5 等
  哈希与校验和当密钥；代价是纯小写 hex 形式的密钥不被覆盖。
- **环境变量按名强制 token 化**：`sanitized_env()` 对变量名（按 `_` 切分后整段匹配）
  命中 `KEY`/`TOKEN`/`SECRET`/`PASSWORD`/`CREDENTIAL` 的值**无视熵阈值**一律替换为 token，
  覆盖 `GLM_API_KEY=dfe946…` 这类纯 hex 密钥逃过熵检测的盲区（刻意不含过宽的 `AUTH`，
  以免误伤 `SSH_AUTH_SOCK` 等路径变量）。
- `allowlist` 可再加 Lua pattern 排除。参数见
  [configuration.md](configuration.md) 的 `tools.sandbox.secrets`。

### 加密映射与生命周期

- 每个真实密钥分配一个随机 token（`NEOKEY_<hex>`）；映射表**仅在内存**，不落盘。
- **进沙箱加密**：工具结果（`read_file`/`run_command`/… 回传模型前）、工作区暂存视图
  （`candidate._base_entry` / `merge_candidate`）、以及 `run_command` 的**环境变量**
  （高熵值、以及敏感名变量的值替换为 token，命令拿到 token 而非真实密钥）都做 token 化。
- **出沙箱解密**：只在 commit / CAS 发布写入真实文件时把 token 还原为密钥
  （`candidate.publish`）。映射缺失（如热重载后）时**拒绝发布**（`SECRET_UNRESOLVED`），
  绝不把 token 当内容写入真实文件。
- 暂存视图 token 化后，`base_hash`（真实基线，用于 CAS 冲突检测）与
  `view_base_hash`（token 化基线，用于改动判定）分开记录，保证只读工具与编辑一致。

### 留痕与告警

- 每次检测到新密钥、以及工具参数中用到 token，都写入一条 `kind="secret"` 证据。
- 候选内容涉及 token 时，待审变更单元带 `secret_warning`，`NeoAISandboxReview`
  以红色 `⚠ 密钥操作×N` 醒目提示（见 [configuration.md](configuration.md)）。
- 事件：`SANDBOX_SECRET_DETECTED` / `SANDBOX_SECRET_TRACED` / `SANDBOX_SECRET_BLOCKED`。

### 原始密钥硬拦截

工具参数（深度扫描）中出现映射表中已知的**原始密钥**时：

1. 拒绝该工具调用（`SANDBOX_SECRET_BLOCKED`）；
2. 调用 `core.agent.runtime.abort(agent, "secret_exposure")` **立即终止整个 Agent**；
3. 发出 `SANDBOX_SECRET_BLOCKED` 事件并 `vim.notify` 明确通知用户。

> 边界：熵检测为启发式，长随机串（非 hex）可能误报；但由于 token 在 commit 时无损还原，
> 误报不改变最终写入内容，仅增加留痕噪声。映射表不落盘，热重载后未提交的 token 无法还原，
> 该候选会被拒绝发布（fail-closed）。纯小写 hex 密钥、以及命令在沙箱内直接读取真实文件
> 并在同一命令内使用密钥（不经过模型）的行为不在覆盖范围内。

## 17. 权限档位与自动提权

默认所有外部命令以**最小权限**运行；权限不足时**自动发起升级**（记录，不静默执行），
并按档位逐级收紧审查。核心模块 `sandbox/privilege.lua`（分类/解析/留痕）与
`sandbox/hostop.lua`（T2 主机效果提案）。

### 档位

| 档 | 名称 | 用途 | 隔离 | 审查 |
|---|---|---|---|---|
| **T0** | minimal | 普通命令 | cap-drop ALL + seccomp + 遮蔽 + **默认隔离网络** | 无逐命令审查；fs 改动进待审队列 |
| **T1** | elevated | 网络访问、受控 docker | 隔离内执行，网络放行 | 自动授权、留痕；fs 改动进待审队列 |
| **T2** | privileged | cap_add、宿主 socket、宿主挂载 | **嵌套 userns** 内执行（cap 被作用域限制，够不到宿主） | 主机效果冻结为**提案**，异步审批后 replay |

- 分类：`privilege.classify()` 解析命令，`docker/podman`→T1，`curl/git push/pip/npm`→T1 网络，
  `sudo/mount/modprobe/iptables/systemctl`→T2；复合命令取最高档。规则见
  `tools.sandbox.privilege.classify`（`bins` / `bin`+`subs`）。
- 最高档：`tools.sandbox.privilege.max_tier`（默认 2）；越界由策略硬拒绝
  （`PRIVILEGE_TIER_EXCEEDS_MAX`）。
- 自动升级：T0 命令失败且输出命中权限/网络模式（`operation not permitted`、`could not resolve
  host`、`cannot connect to the docker daemon` 等）时，自动以所需档位在隔离内重跑，写
  `kind="privilege"` 证据并发出 `SANDBOX_PRIVILEGE_ESCALATION_REQUESTED`。可通过
  `auto_escalate=false` 关闭。
- 留痕：每次档位裁决/升级记录证据（`record=true` 默认开）与事件。

### 受控 docker（方案：外部受控 socket）

沙箱**不绑定宿主 `/var/run/docker.sock`**（默认遮蔽）。`tools.sandbox.docker.mode="controlled"`
时，T1 把 `docker.socket` 指向的**受控 socket** bind 到沙箱内 `/var/run/docker.sock`，并注入
`DOCKER_HOST=unix:///var/run/docker.sock`。受控 socket 由部署侧提供：

```bash
# 1) rootless dockerd（推荐：容器 root ≠ 宿主 root）
dockerd-rootless-setuptool.sh install
# socket 通常位于 /run/user/<uid>/docker.sock
#   tools.sandbox.docker.socket = "/run/user/1000/docker.sock"

# 2) docker-socket-proxy（对宿主 socket 做 API 白名单过滤，仅暴露只读/受限端点）
docker run -d --name neoai-docker-proxy \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -e CONTAINERS=1 -e IMAGES=1 -e EXEC=0 -e POST=0 -e VOLUMES=0 \
  -p 127.0.0.1:2375:2375 tecnativa/docker-socket-proxy
#   docker.socket = "/path/to/exposed/docker.sock"（经 TCP→unix 转发）

# 3) DinD 边车（独立 daemon，隔离于宿主）
#   docker.socket = "<dind 容器挂载出的 docker.sock>"
```

`mode="off"` 禁用 docker（T1 docker 命令拒绝）；`mode="host"` 仅 T2 允许，且主机效果需异步审批。

### T2 主机效果提案

T2 命令在嵌套 userns 内执行（`--unshare-all` + 可选 `--cap-add`，cap 被限制在该 userns），
因此**不会直接影响宿主**。其主机效果由 `hostop.freeze()` 冻结为提案，进入 `:NeoAISandboxReview`
待审队列（展示命令与 `[T2]` 徽标）；用户审批后 `review.apply` 在主机上 replay 命令并写回执
（`SANDBOX_HOST_OP_APPLIED`），拒绝则不执行（`SANDBOX_HOST_OP_REJECTED`）。全程不阻塞工具调用。

> 边界：T2 在嵌套 userns 内无法使用 overlay（宿主 `/` superblock 归属 init userns 会 `EINVAL`），
> 退化为「只读根 + 私有 cwd」，改动仅在 cwd 捕获；任意路径的主机效果以提案形式处理。

### 配置

见 [configuration.md](configuration.md) 的 `tools.sandbox.privilege` 与 `tools.sandbox.docker`。
