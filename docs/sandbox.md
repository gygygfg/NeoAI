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
| `sandbox/observe.lua` | 影响记录（fs/process/network，未知用 null）与裁决信封（decision/severity/stats/asks/evidence）；合并原 `impact`+`envelope`（旧文件为兼容 shim） |
| `sandbox/evidence.lua` | 证据保存、脱敏、分页读取 |
| `sandbox/grant.lua` | 窄范围任务授权（范围/操作/预算/有效期/撤销） |
| `sandbox/writer.lua` | 落盘写入器：先非 root 尝试，权限不足 → NEEDS_ROOT，批准后 root/`sudo`(tty) 写入 |
| `sandbox/network.lua` | 受控网络网关（默认放行；启用后按声明端点放行） |
| `sandbox/broker.lua` | 外部操作适配器协议（幂等/查询/补偿能力声明与对账） |
| `sandbox/replay.lua` | 策略回放（同规则同事实复现裁决） |
| `sandbox/cgroup.lua` | cgroup v2 资源域（内存/PID/CPU），每次尝试独立域 |
| `sandbox/seccomp.lua` | seccomp 能力探测与 require_seccomp 门禁 |
| `sandbox/privilege.lua` | 权限档位（T0/T1/T2）分类、解析、自动升级检测与留痕 |
| `sandbox/hostop.lua` | T2 主机效果提案（冻结/审批后 replay/拒绝） |
| `sandbox/cache.lua` | 内容寻址缓存（隔离写入、可清理） |
| `sandbox/diag.lua` | 故障注入（后端/冻结/发布/持久化）与关键路径性能基准；合并原 `fault`+`bench`（旧文件为兼容 shim） |
| `sandbox/tool_spec.lua` | 每个工具的影响类别（effect）与暂存路径声明 |
| `sandbox/wrapper.lua` | 执行门禁：`attach` 附加规格、`gate` 强制过闸门 |
| `sandbox/risk.lua` | 安全级别评估（L0-L3）、审批分级动作与结果分级 |
| `sandbox/script_scan.lua` | 脚本间接执行静态扫描（Shell 正文 + 高级语言内嵌 shell、递归、不透明判定） |
| `sandbox/audit.lua` | AI 读取/调用行为监视、风险分与异常事件 |
| `sandbox/container.lua` | 容器运行时受控：与沙箱同 namespace（podman）或受控 socket（docker） |

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
- **待审队列以内存为准**：首次访问时从磁盘水合历史变更单元，之后 `list` / `pending_summary`
  直接读内存，不再每次全量扫描 `reviews/` 目录。否则待审堆积到数百/上千时，
  `supersede_by_paths`（每次工具调用）与状态栏徽标刷新会退化为 O(n²) 磁盘扫描并占满主线程。
  状态栏刷新（`services.status`）也按 tick 合并，避免同一 tick 内数百次事件各触发一次重绘。
- **按 nvim 进程实例隔离**：每个 nvim 进程使用独立实例存储根
  `<workspace_root>/instances/<pid>_<启动时间>`，待审队列/候选/回执/证据互不共享——同时
  打开两个会话时**不会看到对方的审批**；关闭任一实例只清理自己的暂存，不影响其它实例
  运行中的 agent。同一进程内热重载保持实例 id 不变，本实例的待审队列与暂存候选得以保留；
  已死进程遗留的实例目录在下次启动后由 `sandbox.instance.gc` 异步回收（不阻塞启动）。
- **模型可见性**：工具结果**原样返回给模型**，不附加「已暂存/待审」说明，让 AI 认为
  修改已完成；待审状态只通过**醒目的状态栏徽标**提示用户（`statusline` 的 `sandbox`
  段，仅在待审数 > 0 时显示黄底加粗的 `待审N`，见 [configuration.md](configuration.md)）。
- 异步确认命令：
  - `:NeoAISandboxReview` — 打开待审审批界面（`ui/components/sandbox_review.lua`）：
    按文件路径级别高亮 —— **工作区文件=绿色、用户目录=黄色、系统路径=红色**，
    「待审」状态标签**按安全等级着色**（L0 灰 / L1 黄 / L2 橙 / L3 红）；并按安全级别显示
    **高危/中危/低危** 风险档（`[L0]低危` …
     `[L2]/[L3]高危`）与风险原因。**头行 = 整单元审批**（`<CR>` 一次应用该变更单元的全部
     文件），**文件行 = 单文件审批**（`<CR>` 仅应用光标所在文件）；`d` 拒绝该文件（头行则拒绝
     整单元，其余文件保留待审）、`i` 临时关闭审批窗并打开该条目的**修改 diff**
     预览（`q`/`<Esc>` 关闭后自动返回审批窗并恢复光标）；在**越界访问留痕**行按 `i` 则打开
     该路径的**访问详情**（逐次列出工具 / 类型 / 命令 / 时间，非审批目标）、`u` **撤销/重做保存**、
     `r` 刷新、`q`/`<Esc>` 关闭。
     聊天主窗口内可按 `<leader>ap` 直接触发（`keymaps.chat.sandbox_review`）。
     - **显示已保存 / 撤销保存**：应用（保存）时保留每个文件的**原文件快照**（真实文件
       应用前的内容），审批界面底部「已保存（已应用，u 撤销/重做保存）」区展示已发布到真实
       工作区的变更；在条目行按 `u` 把真实文件与快照**交换**——已保存 → 撤销（回滚到应用前
       内容），已撤销 → 重新保存，可反复切换。交换前做 CAS 校验：真实文件若已被外部改动
       （哈希不符）则拒绝并报 `CONFLICT`，绝不覆盖用户改动。快照随每进程实例隔离存储
       （`store` 的 `snapshots/`），随实例目录回收。
     - **包安装按安装命令合并**：npm/pip/apt 等包安装命令产生的候选在头行标注
       `包安装 <管理器>: <包名>`（`privilege.package_info`），并**按安装命令键
       `package_key`（`<管理器>:<包名列表>`）合并为一个审批单元**——同一安装命令产生的多个
       候选（索引、元数据、包文件）在待审队列中只显示一个条目，整包一次审批（`<CR>` 应用全部
       文件），无需逐文件确认；仍可用 `files` 选择性只应用部分文件。识别会跳过
       `sudo`/`doas`/`env`/`bash -c`/`for …; do …` 等包装器，避免漏判包安装而使风险误升到 L3。
     - **包安装的可写根与能力**：包安装命令（任一段命中包管理器，`req.package`）会自动把
       包安装可写根（`tools.sandbox.packages.roots`：`/usr`、`/var`、`/etc`、`~/.cache`、`~/.npm`、
       `~/.nvm`、`~/.cargo`、`~/.rustup`、`~/go`、`~/.local` 等）加入可写根并 overlay 暂存，
       使 `apt update`/`apt install`/`pip install`/`npm install`/`nvm install` 等能写入索引/
       缓存/元数据**与安装目标**（`/usr` 覆盖 `/usr/bin`、`/usr/games` 等；`/var` 覆盖 dpkg/apt
       状态、man 缓存等；`/etc` 覆盖 dpkg postinst 的配置写入，如 libc-bin 刷新
       `/etc/ld.so.cache`——只读根下会以 `Read-only file system` 失败并让 dpkg 退出码非 0），
       且写入同样冻结为候选，真实盘不变；`/etc` 内的敏感条目（shadow/sudoers/ssh/cron 等）
       仍由 `mask_paths` 遮蔽，不受影响。当 `cap_add` 收窄（如 `{}`）时，
       capability 的按需加回（`req.package`：命令**任一段**命中包管理器即授予）按
       `tools.sandbox.packages.cap_add` 加回窄能力——`apt-get install …; echo; tail` 这类
       链式命令同样授予（否则 apt 无法 chown/setuid 到 `_apt` 而失败）。写入仍全部进 overlay
       暂存、敏感路径由遮蔽挂载保护，故混合命令继承窄能力不扩大宿主面。
       `--cap-drop ALL` 会移除 `CAP_DAC_OVERRIDE`（root 连 `_apt` 拥有的 0700 目录都不可写），
       故按 `tools.sandbox.packages.cap_add` 加回 `CAP_DAC_OVERRIDE`/`CAP_CHOWN`/`CAP_SETUID`
       等窄能力（**不含 `CAP_MKNOD`**：设备节点由 seccomp 基线硬拦，见 §6）；若载荷降权为
       专用非 root uid，这些窄能力以 **ambient** 形式保留，否则改 uid 会清空能力、包安装锁失败。
       进程始终在 mount/pid 命名空间 + seccomp + 只读根 + 遮蔽 + overlay 暂存约束内。
     - **超大文件不纳入候选**（`tools.sandbox.max_file_bytes`，默认 8 MiB）：超过上限的文件
       仍写入 overlay 私有层（不落真实盘），但不进入候选/待审/发布，避免 `apt` 的
       `pkgcache.bin`、缓存归档、镜像层等被嵌入候选 JSON 而阻塞主线程 / 撑爆磁盘。
     - **暂存内容持久**：`PENDING` 与 `APPROVED`（尚未应用）的候选在重载/重开后由
       `_rehydrate_pending` 从落盘候选重新物化进暂存层，包安装等大批量暂存内容在应用或
       拒绝前一直保留可读，不随会话轮转/退出销毁。
    - **L3 二次确认**（`tools.sandbox.review.l3_warning.enabled`，默认开）：对 `risk_level=3`
      的条目，首次 `<CR>` **不直接应用**，而是由模型（`sandbox/l3_warning.lua` 经
      `core/agent/request`）生成一条简洁的中文**后果警告**，并自动打开该条目的**修改 diff**，
      警告展示在 diff 顶部（生成期间显示占位）。用户在 diff 内再次 `<CR>` 才真正应用，
      `q`/`<Esc>` 取消并返回审批窗。模型不可用/超时/未配置 provider 时回退为基于
      `risk_reasons`/路径的确定性规则警告，不阻断流程。
    - **AI 审计**（`tools.sandbox.review.ai_audit`，默认开，待审界面内按 `a`，可配置 `key`）：
      把**原会话的用户消息**（排除运行上下文快照与压缩检查点）与**分级的待审变更/修改内容
      的结构化文本**（`sandbox/ai_audit.lua`：变更单元 id、工具、权限档、风险级别与原因、
      密钥/包安装/命令、逐文件 diff）交给模型，为**每个文件（主机操作为其命令）生成一句不超过
      50 字的简体中文风险说明**。说明**以「安全」或「不安全」开头（先结论后原因）**，
      并**暗灰色补充渲染在对应文件行下方**（模型按 `<路径或命令> => <安全|不安全>：<说明>`
      逐行输出，`parse_notes` 解析并按 50 字截断；未按格式输出时整段压成一句兜底）；窗口顶部
      先渲染**整体结论**（`ai_audit.verdict`：任一说明判为不安全 → 红色「不安全」，否则绿色
      「安全」）。待审变更**按风险从高到低送入模型**，高危（L2/L3）变更优先且不得省略，避免
      因总长/输出上限截断而缺失其说明；**每条都要审**——模型漏答的条目在对应行下方标注红色
      「（AI 未给出说明，请人工确认）」。生成中/失败在顶部显示简短暗灰状态行。**不进入聊天界面、
      也不自动应用或拒绝**任何变更；用户仍以审批界面为准。审批窗默认开启自动换行（`wrap`/`linebreak`）。
      diff/用户消息/总文本分别按 `max_diff_chars`/`max_user_chars`/`max_total_chars` 截断，
      输出上限与超时由 `max_tokens`/`timeout_ms` 控制；`enabled=false` 时不注册该按键。全局并发
      上限 `max_concurrent`（默认 10）：在途审计请求超出即排队 FIFO，避免 auto 频繁触发时请求风暴。
      **自动审计**（`ai_audit.auto`，默认 `false`）：开启后打开待审界面即自动发起审计，待审
      集合变化时自动重审；也可随时按 `key`（默认 `a`）手动触发。
  - `:NeoAISandboxApprove <id>` / `:NeoAISandboxReject <id>` — 批准（不应用）/ 拒绝并丢弃。
  - `:NeoAISandboxApply <id>` — 批准并应用（CAS 发布）；`:NeoAISandboxApplyAll` 批量应用。
  - `:NeoAISandboxList` / `:NeoAISandboxShow` / `:NeoAISandboxDiscard <digest>` / `:NeoAISandboxCommit <digest>`。
    丢弃候选会同步把引用该候选的 `PENDING` 变更单元标记为 `REJECTED`（`review.discard_by_digest`），
    否则重开聊天/审批界面会重新显示一个候选已不存在、无法应用的待审项。
- 选择性应用：`sandbox.apply(id, { files = { ... } })` 只应用指定文件子集（重新冻结组合候选后 CAS）；
  未选中的文件会保留为新的待审变更单元，供用户逐个确认。`sandbox.reject_file(id, path)` 按文件拒绝。
- **发布前重校验（纵深防御）**：`candidate.publish` 对每个文件重新规范化路径——解析结果与记录
  路径不一致（`..`/符号链接被引入或替换，如落盘候选被篡改）→ `CONFLICT/PATH_CHANGED`；
  命中宿主敏感遮蔽路径（`is_masked_path`）→ `FAILED/SANDBOX_MASKED_TARGET`。候选内容即便
  被本地进程改写也无法写出到未经验证的真实位置。
- **同文件取代**：同一文件被再次编辑（新候选入队）或直接发布时，覆盖该路径的旧 `PENDING`
  变更单元被标记为 `SUPERSEDED` 并丢弃候选，队列只保留最新版本，避免用户看到同一文件的
  多个版本（`review.supersede_by_paths`）。

### 脚本间接执行静态扫描（`tools.sandbox.script_scan`，默认开）

命令把执行委托给脚本/解释器时，命令字符串本身看不到真正的操作（`bash deploy.sh`、
`python setup.py`、`node x.js`、`./run.sh`、`bash -c '…'`、`python -c '…'`）。执行前
`sandbox/script_scan.lua` 会：

- 识别解释器调用与直接可执行脚本（按 shebang 判语言），支持 `source`/`.` 引用；
- 读取脚本内容（**优先沙箱暂存副本**，使 AI 本次新建/修改的脚本也被扫描；宿主敏感遮蔽路径
  不读取，直接标记不透明）；
- **仅读取常规文件**：字符/块设备、FIFO、socket 等虽 `filereadable()` 为真，但 `read("*a")`
  会阻塞或产生无界内容（如 `head -c … /dev/urandom | base64` 此前会读取设备直至超时，单条
  命令卡数秒且有 OOM 风险），故直接视为不可读、标记不透明；shebang 判定只读取有界头部；
- Shell 脚本取出去注释后的正文；Python/Node/Ruby/Perl/PHP 提取 `os.system`/`subprocess.*`/
  `child_process.exec`/`system`/反引号/`%x{}` 等 shell 调用的字符串字面量；
- 递归扫描被引用的脚本（限 `max_depth`/`max_files`/`max_bytes`，检测环）。

折叠出的 `effective` 文本并入 `risk.deny_reason`（硬拒绝）、`privilege.classify`（档位/包
识别）与 `risk.classify`（安全级别），使 `bash deploy.sh` 里的 `pip install`、
`sudo modprobe`、`mkfs.ext4 /dev/sdb1` 不再漏判：

- 脚本内**设备级/内核命令硬拒绝**（与直接命令同规则）；`rm`/`rm -rf` 等纯文件修改不硬拒绝
  （由只读根 + overlay 修改暂存保护宿主机），其效果冻结为候选待审；
- 其余命中（包安装、`systemctl`、`chmod -R 777` 等）提升级别并**强制复核**——不随
  `mode=commit`、任务授权或会话自动审批放行；
- 无法静态解析的间接执行（`eval`、`base64 -d | sh`、`curl … | sh`、`python -m`、
  动态 `-c "$VAR"`、读不到/超限的脚本）标记为**不透明**，提升到 L1（`OPAQUE_SCRIPT_EXECUTION`）
  并强制复核。

> 本模块只做**静态**分析。不做运行时追踪：沙箱的 seccomp 基线拦 `ptrace`/`bpf`/`process_vm_*`，
> 沙箱内 `strace`/eBPF 不可用，且 shim（`LD_PRELOAD`/PATH 包装）可被 AI 绕过；稳健的动态侧
> 信号是**效果观测**（overlay 捕获的真实文件改动、网络目标、包路径识别），与本静态扫描互补。

### 暂存机制

- **显式路径工具**（`edit_file` / `create_directory` / `ensure_dir` / `delete_file`）：
  门禁把路径参数重写到 `<root>/workspace/<hash>` 的私有副本，工具只改副本。
  **路径在暂存前先做完整规范化**（`utils.fs.canonical`：展开 `~`、绝对化、解析符号链接并
  折叠 `..`），使「暂存键 / 风险分级 / 审批展示 / 发布目标」使用同一真实路径——否则
  `x/../../../etc/cron.d/pwn`（`x` 不存在时 `fnamemodify(:p)` 不折叠 `..`）会被展示为
  工作区内 L0 绿色，发布时却由内核解析写到工作区外。
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
  - LSP 工具与 `run_command`/git 读工具共享同一暂存视图：`tools.sandbox.lsp_overlay.enabled`
    默认开启，AI 克隆出的 LSP server 进程被放进 bwrap + overlay（见下节），其磁盘读取即看到
    暂存内容（不再读真实磁盘）；overlay 不可用时自动跳过，回退编辑器客户端。写类 LSP 工具
    （`lsp_rename`/`lsp_format`）的落盘始终经 `persist_buffer` 重定向到暂存层。
  - **git 读工具（`git_status` / `git_diff` / `git_log` / `git_branch` / `git_file_history` /
    `git_commit_detail`）**：在沙箱命名空间内执行（与 `run_command` 同一 overlay），磁盘读取
    看到的是**暂存内容**而非真实工作区；命令以 `GIT_OPTIONAL_LOCKS=0` 运行避免写 index，
    且作为只读进程工具**不捕获候选**、不入待审队列。真实工作区不会被 git 读操作改动。
    （`git_rollback` 为写操作，仍按宿主执行并经审批。）
- **buffer 写盘工具**（`delete_node` / `lsp_rename` / `lsp_format`）：
  `tool_helpers.persist_buffer` 在沙箱激活时把 `:write!` 重定向到暂存层。
- **外部进程**（`run_command`）：bwrap 后端对一组**可写根**（`tools.sandbox.process_roots`，
  默认仅 cwd，未覆盖时自动补入）做 overlayfs：真实根为只读 lower、会话 upper 为可写层。
  命令能读取这些根的真实内容，且对其下**任意路径**的新建/修改/删除都落到 upper，随后冻结为
  候选（删除以 whiteout 设备节点识别为 `delete`/`rmdir`）。
  - `/tmp`、`/var/tmp` 属**每会话私有临时根**（`tools.sandbox.tmpfs_roots`）：默认
    （`tmp_private_base="host"`）在宿主根之下建隐藏临时子目录（如 `/tmp/.cache-<tag>/<session>`，
    mode 1777），并经**命名空间 bind 映射回该根**——沙箱内 `/tmp` 即此会话私有子目录，
    宿主 `/tmp` 真实内容对 AI 不可见（隔离 AI）。**不**作为 overlay 只读 lower，退出/轮换
     会话即销毁。命令对 `/tmp` 的写入属临时草稿，不冻结为候选，杜绝跨会话残留与宿主 `/tmp` 泄露。
    `tmp_private_base="session"` 可退回旧的「建在会话进程目录（/dev/shm）」行为。
  - **临时候选根（`tools.sandbox.ephemeral_roots`，默认同 `tmpfs_roots`）**：这些根（**cwd 子树
    除外**）下的文件写入为**会话私有、nvim 退出即丢弃**——不进入待审队列、不 CAS 发布、也不弹
    审批悬浮窗（内容仅在暂存层，供本次会话读取一致）。对进程内工具（`edit_file`/`create_directory`
    等直接写宿主的工具）与外部命令统一生效，避免把 `/tmp` 草稿当作待审修改反复确认。
    `ephemeral_roots = {}` 可关闭（`/tmp` 下也走正常待审/审批）。
  - 默认不再覆盖 `/root`、`/home`、`/etc` 等整目录，避免把宿主真实 home/账户/配置作为
    只读 lower 暴露；需要写这些路径时显式加回 `process_roots`，并同步收紧 `mask_paths`。
  - 可写层为**会话级共享**：同一 agent 循环内所有命令共用（命令 N 看得到命令 N-1 的
    写入）；agentEnd 轮换会话时随会话目录清理（改动已冻结为候选）。
  - **双向互通**：命令执行前把工作区暂存内容物化进可写层（命令能看到 `edit_file`
    尚未发布的编辑与新建，删除以 whiteout 表示）；命令结束后把改动合并回工作区暂存映射
    （`read_file`/`edit_file` 能看到命令的改动并继续叠加）。捕获时**只记录命令真正改动过的
    文件**：与当前工作区暂存内容一致（或已标记删除）的物化文件不产生候选，避免只读命令
    （`ls`/`cat`/`git status` 等）把 AI 的暂存编辑重复捕获为 `run_command` 候选并取代原
    `edit_file` 候选——否则拒绝该只读命令会连带失效暂存编辑，表现为「已允许的修改被回滚」。
  - **权限位保留**：候选记录文件权限（`mode`），物化进 overlay 与 CAS 发布时按原权限写回
    （`write_file_atomic` 的 mkstemp 默认 0600，会剥离可执行位，导致 venv/bin 脚本失效）；
    新建文件用常规默认 0644，不强制 0600。
  - **目录一致性**：目录暂存（`create_directory`/`ensure_dir`/`run_command` 新建目录）必须用
    `isdirectory` 判定，不能用 `fs.exists`（基于 filereadable，对目录恒为 false）。否则会话
    轮换会把目录误判为「暂存缺失」并标记删除，物化为 whiteout，沙箱视图里目录变成设备节点/
    文件（表现为 `ls dir/: Not a directory`）。此外文件写入工具（`edit_file` 等）拒绝以目录为
    目标（`SANDBOX_TARGET_IS_DIR`），物化时也防御「文件覆盖目录」的类型冲突；`create_directory`
    新建的目录会在命令执行前物化进可写层，使 `run_command` 可见。
  - **删除对账**：命令删除的若是「沙箱-only」文件（真实磁盘本不存在、仅由先前命令或暂存产生），
    overlayfs 不会生成 whiteout，capture 遍历 upper 看不到任何条目。capture 结束后对本次
    materialize 记录过的路径对账：upper 中已消失且真实磁盘也不存在 → 标记工作区删除并取代该
    路径的旧待审候选（净效果为「无改动」），避免下一次物化把旧内容「复活」（表现为删除后
    仍能读到旧文件，如命令输出文件 `.out`）。
  - overlay 基目录由 `sandbox.conceal` 以**无特征名**生成（`/dev/shm/.cache-<tag>`，
    不含 `NeoAI`/`sandbox` 字样；须在可写根之外，避免 upper 落在 lower 之下导致内核
    `EINVAL`）；`/dev/shm` 不可用时退回沙箱根目录。
  - **沙箱自身存储对命令不可见**：沙箱存储基根（`tools.sandbox.workspace_root`，默认
    `stdpath("cache")/NeoAI/sandbox`）及其 `instances/` 容器在命名空间内以空 `tmpfs` 遮蔽，
    命令无法读取/篡改候选、会话、回执等内部状态，也无法枚举其它并发实例的待审内容
    （防止信息泄露与逃逸）。
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
  - **轮换的原子性**：轮换**不立即删除**旧会话目录，而是排队、待**无在途命令**时再在
    线程池里异步清理。旧会话目录是运行中命令的 `--bind` 挂载源，立即 `rm -rf` 会让挂载
    路径突然 `ENOENT`，表现为间歇性 `cd: can't cd to ...`（暂存文件系统原子性/竞态）。
  - **仅主 Agent 触发轮换**：子 Agent / 辅助生成也发同名 `GENERATION_*` 事件；当前主
    Agent 仍忙碌时，非本 Agent 的结束事件不轮换，避免删除主循环仍在使用的暂存目录。
  - 暂存内容物化（`materialize_overlay`）采用**同目录临时文件 + rename 原子替换**，
    避免并行运行的命令读到半写/缺失内容。
- **路径不泄露**：工具的成功结果与错误信息中的暂存路径都会被还原为真实工作区路径
  （包括只读工具读取已删除暂存副本时的报错），模型永远看不到沙箱内部路径。
- **热重载一致性**：`sandbox.shutdown()` 会清空暂存目录，但待审队列与候选仍落盘；下次
  `sandbox.init()` 会按**待审（PENDING）与已批准未应用（APPROVED/NOT_REQUESTED）**候选内容
  **重新物化**进新会话暂存层（`_rehydrate_pending`），使重载/重开后只读工具看到的视图与
  待审队列一致，且已批准未应用的改动在应用/拒绝前仍可读、可应用。

### AI 专用沙箱 LSP（默认开启）

- 开关：`tools.sandbox.lsp_overlay.enabled`（默认 true）。仅 `bwrap` 后端且工作区根可挂载
  overlay 时生效；不满足条件自动跳过，AI 工具回退编辑器客户端，不影响正常使用。设为 false
  可关闭（AI 工具改读真实磁盘）。
- 隔离范围：**只影响 AI 的 `lsp_*` 工具**。不再全局包装 `vim.lsp.rpc.start`，编辑器自身的
  LSP 进程照常读写真实磁盘；AI 工具调用时按需克隆编辑器同名 server（客户端名加
  `@neoai-sandbox` 后缀），只有克隆体走沙箱命名空间与暂存层。
- 机制：把克隆 server 的启动命令包成
  `bwrap <隔离标志> <最小只读系统集> … --overlay-src <工作区> --overlay <upper> <work> <工作区> --chdir <工作区> <原命令>`；
  隔离标志与 overlay 探测/`run_command` 一致（root 下为不含 user namespace 的显式标志）。
  lower 为真实工作区（只读），upper 为沙箱私有可写层。克隆 server 读到的是「真实文件 + 暂存改动」
  的合并视图，且路径仍是真实路径。
- 诊断：克隆体的 `textDocument/publishDiagnostics` 不外溢到编辑器；`lsp_diagnostics` 优先通过
  pull diagnostics（`textDocument/diagnostic`）读取克隆体诊断（反映暂存内容），服务器不支持时
  回退编辑器诊断。
- 一致性刷新：每次 LSP 工具调用前、以及克隆 server 启动时，`sandbox.lsp.refresh()` 会用当前
  工作区暂存重新物化 upper（先清空再写入），使克隆 server 即时看到最新未发布改动。
- 隔离与缓存：克隆 server 的缓存/状态目录（`stdpath(cache|data|state)`、`~/.cache`、`~/.local/*`、
  `~/.npm`）以 rw bind 直连宿主，避免缓存写入 overlay 或被当作待审候选；overlay upper 按工作区
  hash 分片，多项目互不串扰，位于 `/dev/shm/.cache-<tag>/lsp/<hash>`。rw bind 之后应用与
  `run_command` 一致的 `mask_paths` 遮蔽（如 `~/.local/share/keyrings`、`~/.cache/keyring-*`），
  避免随缓存目录把 keyring/凭据暴露给克隆 server。
- 生命周期：克隆客户端由 `sandbox.lsp.clients_for` / `client_supporting` 按需启动并缓存，
  `stop_all()` 统一停止；不注册任何全局 hook，卸载/禁用不影响编辑器 LSP。

## 6. 运行时后端

- `bwrap`（若存在）：最小只读系统集 + 多可写根 overlay，并施加 `--as-pid-1` 等隐匿参数
  （详见 §15）。root 下优先使用无 user namespace 的显式隔离标志，否则用 `--unshare-all`。
  - **overlay 可用时**：每个可写根（`process_roots`）真实内容作为只读 lower、会话 upper
    作为可写层，命令看到真实内容且写入可捕获。
  - **overlay 不可用时（默认 fail-closed）**：不降级运行——`process` 工具直接拒绝，返回
    `SANDBOX_OVERLAY_UNAVAILABLE`（附不可用原因），避免命令在「看不到真实磁盘文件」的私有
    视图里静默运行、把「看不到」误判为「文件不存在/改动未生效」。可用
    `tools.sandbox.overlay_fail_closed = false` 显式允许降级：此时把会话私有目录 `--bind`
    到该根（命名空间隔离与只读 rootfs 保留），命令看到的是会话私有视图（仅含暂存改动），
    `run_command` 会以**仅用户可见**的方式提示「降级模式」（`ctx.sandbox_degraded` →
    工具结果的 UI 附加元数据 `notice`，附 `ctx.sandbox_degraded_reason` 原因），
    **不写入模型可见的结果内容**，避免把「看不到」误判为「文件不存在/改动未生效」，
    也不让模型据此感知沙箱状态。
  - **T2 特权档（嵌套 userns）**：天然无 overlay，其主机效果冻结为提案，属有意设计，**不算
    「降级」**。该档单独以 `ctx.sandbox_userns` 标记，`run_command` 显示**特权档专用提示**
    （「以特权档（T2）在嵌套命名空间内执行……主机效果将冻结为提案待审」），**仅用户可见**，
    不使用「overlay 不可用」的降级告警文案，避免误导。
  - **排查降级原因**：`:NeoAISandboxCaps` 输出 `overlay=ready` 或
    `overlay=unavailable(<原因>)`；`runtime.overlay_diagnosis()` 用真实执行路径
    （cwd + 沙箱 overlay 基目录）实测 **可写性**（挂载 + 写入探针，与真实门禁一致）并返回
    `{ available, reason, flags, userns }`。`runtime.overlay_reason()` 对「能挂载但载荷写不
    进去」返回 `OVERLAY_NOT_WRITABLE(...)`，不再因只看挂载而返回空原因。
    常见原因：宿主 `/` 归属 init userns 且以 userns 运行（overlay EINVAL）、
    lower/upper 跨挂载或 userns 归属不同、upper 所在文件系统不支持 overlay upper/work
    （如未启用 xattr 的 tmpfs / fuse / 网络文件系统）、upper/work 权限或归属与载荷身份不匹配。
  - **网络默认放行**：带 userns 时 `--unshare-all` 后按需 `--share-net`；无 userns 时默认共享，
    `offline=true` 才隔离（`--unshare-net`）。
- `unshare`（兜底）：`--user --map-root-user --mount --pid --fork --ipc --uts --mount-proc`
  （默认共享网络；`offline=true` 时加 `--net` 隔离）。
- 能力探测：`bwrap` / `unshare` / unprivileged userns / cgroup v2 / overlayfs / seccomp。
  - **懒加载**：`sandbox.init()` 不在插件启动时同步探测（探测会真实启动 bwrap/挂载
    overlay，宿主繁忙时拖慢新开 nvim）；首次真正需要沙箱能力（`runtime.capabilities()` /
    构造进程前缀）时才探测并缓存，此后进程内复用。
  - `bwrap` 与 `overlayfs` 均为**功能实测**（真实启动一次 bwrap / 真实挂载一次 overlay），
    不只看二进制或 `/proc/filesystems`：宿主 `/` 的 superblock 归属 init userns 时
    （如容器内），新建 userns 里 overlay 会返回 `EINVAL`，仅凭内核支持判断会产生假阳性。
  - 能力探测只是**粗粒度门禁**；构造进程前缀时还会用**真实执行路径**
    （lower=真实 cwd、upper/work=私有层）再实测一次 overlay 挂载，按 `(dev_lower, dev_upper)`
    缓存结果。探测用同源临时目录、真实路径跨挂载/跨 userns 归属时会产生假阳性，因此
    真实路径实测失败即按上面的 fail-closed 策略处理（默认拒绝，不硬失败也不静默降级）。
- 后端完全不可用时返回明确错误（`SANDBOX_BACKEND_UNAVAILABLE`），**不静默降级**；
  overlay 单项不可用时默认同样 fail-closed（`SANDBOX_OVERLAY_UNAVAILABLE`），
  仅 `tools.sandbox.overlay_fail_closed = false` 才回退私有 cwd。

> 说明：进程内工具（LSP / treesitter / UI 交互）无法用 namespace 隔离，
> 以「只读默认 + 写入暂存 + 策略门禁」约束；这是已记录的边界，不声称硬隔离。

### 权限收敛与宿主敏感路径遮蔽（默认开启）

沙箱默认**授予完整 root 能力**（`tools.sandbox.cap_add = { "ALL" }`），使 node/python/apt/
dpkg/pip 等任意开发与包管理操作在沙箱内可用；同时按 `tools.sandbox.cap_drop` **收敛「可修改
宿主全局状态」的能力**（网络栈/时钟/内核模块/裸 I/O/重启/MAC/审计）——即便授予 ALL 也逐项
丢弃，netlink 改宿主路由/防火墙、改宿主时钟等被 `EPERM` 拦截，而这些能力与开发/包管理
工作流无关。**宿主不可修改**由以下共同保证：**命名空间（mount/pid/uts/ipc/cgroup）+
只读根（`--ro-bind / /`）+ overlay 暂存 + 宿主敏感路径遮蔽 + `/proc/sys` 只读绑定 +
seccomp（含设备节点屏障）**——沙箱内进程看到的是一份「暂存文件系统」（overlay 私有可写层），
所有写入冻结为候选、真实系统不受影响，AI 以为修改已成功。需要最小权限时可设
`cap_add = {}`（`--cap-drop ALL`，包安装按 `packages.cap_add` 按需加回窄能力）。`runtime`
在 bwrap 前缀中默认施加以下约束：

- **关闭继承 fd（防 chroot 逃逸）**：启动载荷前先关闭除 0/1/2 外所有继承 fd。否则宿主
  进程（如 AppImage 运行时）持有的**目录 fd**（如 `/tmp/.mount_*`）会被沙箱继承，AI 可用
  `openat(dir_fd, "..")` 逐级上溯重回宿主 `/`，绕过 chroot/命名空间。实现见
  `runtime._wrap_close_fds`：优先 `bash`（支持多位数 fd），无 `bash` 时用 `python3`
  的 `os.closerange`，最后退回 `sh`（dash 仅支持个位数 fd，属尽力而为）。`run_command`、
  `runtime.run` 与 LSP 命名空间覆盖均经此包装。

- **完整能力默认 + 主机全局能力收敛（`cap_drop`）**：默认 `cap_add = { "ALL" }`，不施加
  `--cap-drop ALL`——node/python/apt/dpkg/pip 等任意操作以完整 root 能力运行。同时按
  `cap_drop`（默认 `CAP_NET_ADMIN`/`CAP_SYS_TIME`/`CAP_SYS_MODULE`/`CAP_SYS_RAWIO`/
  `CAP_SYS_BOOT`/`CAP_MAC_ADMIN`/`CAP_MAC_OVERRIDE`/`CAP_AUDIT_CONTROL`）逐项 `--cap-drop`，
  封住「capability 层面的宿主全局修改」（netlink 改路由/防火墙、改时钟、加载模块、裸端口
  I/O、重启、改 MAC/审计）——这些能力开发/包管理工作流不需要；显式在 `cap_add` 列出的能力
  不会被丢弃。宿主**文件系统**的不可修改不依赖 capability，而依赖命名空间 + 只读根 +
  overlay 暂存（写入冻结为候选）。需要最小权限时设 `cap_add = {}`（`--cap-drop ALL`，
  纯包安装命令按 `packages.cap_add` 加回 `CAP_DAC_OVERRIDE`/`CAP_CHOWN`/`CAP_SETUID` 等窄
  能力；混合命令如 `apt update && cat /x` 不加回）。
  沙箱内已是 root，命令前导的 `sudo`/`doas`（及其常见布尔 flag）会被**自动剥离**（`sudo apt
  update` → `apt update`）；否则 `sudo` 在嵌套 userns 下 `setresuid` 会 EINVAL、且
  `/etc/sudoers` 被遮蔽，必然失败。含 `-u/-g/-i/-s` 等改变用户/登录的形式保持原样。
  **注意**：capability 与写 `/proc/sys/kernel/core_pattern`、`modprobe` 等全局 sysctl 无关——
  这些条目非命名空间，其写权限按 **DAC**（`euid == 全局 root uid`）判定；沙箱以 root 运行且
  不建 userns 时 `euid` 即全局 root，任何 capability 配置下都可写，构成 coredump/modprobe
  提权原语（修改宿主全局内核状态）。故由下面的「危险全局 sysctl 强制遮蔽」以只读绑定封死。
- **`/proc/sys` 整体只读绑定（常驻，根因修复）**：在 `--proc /proc` 之后 `--ro-bind
  /proc/sys /proc/sys`，一次性封闭**所有**非命名空间全局 sysctl 的写入面。审计实测：修复前
  `randomize_va_space`/`pid_max`/`kptr_restrict`/`dmesg_restrict`/`net.ipv4.ip_forward`/
  `net.ipv4.conf.all.forwarding`/`vm.swappiness`/`vm.max_map_count`/`vm.overcommit_memory`/
  `fs.protected_hardlinks` 等均 **WRITABLE**（`--cap-drop ALL` 挡不住，写权限按 DAC 的
  `euid==全局 root uid` 判定；共享 netns 下 `net.*` 还会直接改宿主网络）；修复后全部 `EROFS`，
  且读取不受影响。
- **危险/信息泄露 proc 文件强制遮蔽（常驻，不可配置移除）**：`runtime.MANDATORY_PROC_MASKS`
  以空文件只读覆盖（读为空、写 `EROFS`）：`/proc/sys/kernel/{core_pattern,modprobe,hotplug,
  uevent_helper,kexec_load_disabled,sysrq,panic,panic_on_oops,perf_event_paranoid,
  unprivileged_bpf_disabled,unprivileged_userns_clone}`、`/proc/sys/vm/{drop_caches,
  compact_memory}`，以及非 `/proc/sys` 的 `/proc/sysrq-trigger`（magic sysrq 触发口）、
  `/proc/kcore`（内核内存读口）、`/proc/modules`、`/proc/kallsyms`，以及审计实测可读的内核
  信息泄露面 `/proc/vmallocinfo`（暴露内核虚拟地址，绕过 `kptr_restrict`）、`/proc/timer_list`、
  `/proc/slabinfo`、`/proc/interrupts`、`/proc/softirqs`、`/proc/buddyinfo`、`/proc/zoneinfo`、
  `/proc/pagetypeinfo`、`/proc/keys`、`/proc/sched_debug`、`/proc/iomem`、`/proc/ioports`。
  用户 `hide_proc_paths` 只能**追加**、不能移除强制项。`unshare` 兜底后端无法 bind mount，
  故对 `process` 类 **fail-closed**（`SANDBOX_SYSCTL_MASK_UNAVAILABLE`），不静默降级。
- **seccomp 基线默认开启**（见 §12）：即便未来出现 capability 相关内核缺陷，denylist
  仍拦截 `mount`/`unshare`/`setns`/`bpf`/`init_module` 等危险 syscall。
- **设备节点屏障（seccomp，纵深防御）**：`mknod`/`mknodat` 的 `mode` 含 `S_IFCHR`/
  `S_IFBLK` 位（字符/块设备）一律 `EPERM`——设备节点**不经 overlayfs**，`open` 直接触达
  真实设备，创建块设备即可裸读宿主磁盘、绕过暂存/遮蔽/审批（`mknod /tmp/d b 8 0 &&
  dd if=/tmp/d`）。即便 capability 含 `CAP_MKNOD`（如默认 `cap_add = { "ALL" }`），
  该屏障仍然生效；FIFO（`mkfifo`）与普通文件不受影响。
- **宿主全局状态 syscall 屏障（seccomp，纵深防御）**：`adjtimex`/`settimeofday`/
  `clock_settime`/`clock_adjtime`（改宿主时钟）与 `iopl`/`ioperm`（裸端口 I/O，x86）返回
  `EPERM`，与 `cap_drop`（`CAP_SYS_TIME`/`CAP_SYS_RAWIO`）形成双保险；`mount`/`unshare`/
  `setns`/`bpf`/`init_module`/`kexec_load`/`reboot` 等亦在 denylist。
- **遮蔽宿主敏感路径**（`tools.sandbox.mask_paths`，安全默认）：目录以空 `tmpfs`、
  文件/socket 以 `/dev/null` 覆盖（socket 变为字符设备，`connect` 失败）。默认覆盖
  `/var/run/docker.sock`（等价宿主 root，最经典逃逸入口）、`/var/lib/docker`、
  containerd/podman 数据、编排器（herdr）/面板（1panel）/D-Bus/systemd 控制通道，
  以及 `/root/.ssh`、`/root/.aws`、`/root/.gnupg`、`/root/.kube`、keyring 等宿主凭据，
  **Git 凭据与签名密钥**（`~/.git-credentials`、`~/.config/git/credentials`、`~/.git-credential-cache`、
  `~/.netrc`、`~/.ssh`、`~/.gnupg`、`~/.config/gh` 等，root 与 `/home/*` 用户均覆盖），
  并补充 `/etc/shadow`、`/etc/gshadow`、`/etc/sudoers`、`/etc/machine-id`、`/etc/ssh`、
  `/var/log`、`/var/spool/cron` 及 root 命令历史等读取面泄露项。
  遮蔽挂载置于各可写根 overlay 之后，确保覆盖生效。
  进程内 `read`/`fs_write` 工具不经 namespace，mount 遮蔽对其无效；执行器对路径参数额外
  查询 `runtime.is_masked_path`，命中即**硬拒绝**（`路径位于宿主敏感遮蔽路径`，不可审批放行），
  覆盖 `read_file`/`search_files`/`edit_file` 等直接读宿主的路径。
- **读取面：整机只读（`read_all`，默认开启）**：默认以 `--ro-bind / /` 把宿主根整体**只读**
  暴露，仅遮蔽 `mask_paths` 中的重要配置文件/凭据（见上）与沙箱自身存储——即「除重要配置
  文件外均可读」，`/opt`、`/srv`、其他项目目录等都可读。`mask_dirs`（`/home`、`/root`
  兄弟目录）不再挂载遮蔽。
  - **越界访问留痕（非阻塞）**：访问 `cwd` 之外的用户工作目录（home/root 之下）时记录
    证据（`evidence` kind=observation）并发出 `sandbox:outside_access` 事件，同时在审批悬浮窗
    `:NeoAISandboxReview` 的「越界访问留痕」区展示；仍直接放行读取，不阻断。展示时**按文件
    路径合并**（同一路径的多个工具合并为一行 `[tool1, tool2] path`）并**按路径升序排序**；
    状态栏 `sandbox` 段在有待审变更之外，也会在有留痕时显示 `越界N`（`N` 为去重文件数）。
    去重按 `(tool, path)`。判定来源默认是**内核级行为观测**（`tools.sandbox.observe`，
    后端 `ebpf`(bpftrace) → `strace` → `procfs`）：按 attempt 的 cgroup 精确归属，
    观测真实 `openat/open` 访问，不再依赖命令字符串解析；三者均不可用时回退命令解析
    启发式（进程内读取工具按路径参数、`run_command` 按命令串中的绝对路径）。系统路径
    （`/usr`、`/etc` 等）不计入，避免噪声。
  - **`read_all = false`（退回最小白名单）**：不整机暴露，也**不整目录暴露 `/usr`**
    （避免泄露 `/usr/local/go_workspace`、`/usr/src` 等软件清单）。按 `tools.sandbox.readonly_roots`
    暴露运行时子树：`/usr` 的 `bin`/`sbin`/`lib*`/`libexec`/`include`、
    `local/{bin,sbin,lib,libexec,include}`，以及 `/lib*`、`/bin`、`/sbin` 加载器符号链接根；
    另**整目录只读暴露 `/usr/share` 与 `/var/lib`**（宿主包数据库 dpkg/apt/rpm、运行时资源
    nodejs/dotnet/java/git-core/terminfo 等）。`tools.sandbox.readonly_paths`（默认 `/etc`
    必要文件：`ld.so.cache`/`passwd`/`group`/`nsswitch.conf`/`ssl`/`alternatives`/`profile` 等）
    只读暴露必要内容。未列出的宿主路径在沙箱内**不存在**。`/etc/passwd`、`/etc/group` 作为
    运行所需的标准只读文件保留（Unix 世界可读，仅暴露账户名，不含口令）。
  两种模式下危险/敏感子路径都由 `mask_paths` 遮蔽（如 `/var/lib/docker`、`/var/lib/containerd`；
  如需隐藏软件清单可把 `/usr/share/doc|man|info` 加入 `mask_paths`）。该读取面同样用于 LSP
  命名空间覆盖（见 §5）。
- **工具子进程统一经沙箱（`NeoAI.sandbox.exec`）**：所有工具内部 spawn 的子进程
  （`run_command` 的 shell、`git` 操作、`read_image` 的 curl 下载、`web_fetch` 的
  bash/node 渲染与依赖安装、MCP stdio server 等）都在 bwrap 命名空间内创建，而非宿主。
  这些辅助进程不做候选冻结（只写工具自身缓存/临时目录），通过 `rw_binds` 以可写方式暴露
  工具自身目录（宿主与沙箱同路径可见），通过 `ro_binds` 只读暴露命令所在目录；其余读取面
  沿用最小只读白名单与宿主敏感路径遮蔽。工具临时/下载目录统一落在共享根
  `stdpath('cache')/NeoAI/shared`（位于沙箱存储之外，宿主与沙箱同路径可见，避免暴露宿主 `/tmp`）。
  后端不可用/沙箱禁用时按 `tools.sandbox.fail_closed` 决定：`true` 拒绝执行（默认），
  否则回退宿主（不静默降级读取面）。
- **宿主运行时直通（`tools.sandbox.expose_paths`，opt-in，默认空）**：这些宿主路径在
  遮蔽/临时根**之后**以只读方式暴露，并把目录前置到沙箱 `PATH`（`expose_path_env`），
  使 `run_command` 能调用宿主工具链（如 appimage `nvim` 的 `/tmp/.mount_*`、`lua`/`luajit`、
  `~/.local/share/nvim/mason` 下的二进制）。默认空保持最小读取面；仅暴露可信、只读的
  工具目录，**不要放入凭据/密钥目录**。注意这会扩大沙箱读取面，属显式 opt-in。
  - **自动直通工具目录**（`tools.sandbox.expose_tool_paths`，默认关）：开启后自动把宿主
    `PATH` 中**存在**且非凭据/系统目录（跳过 `/etc`、`/var`、`~/.ssh` 等）的 bin 目录
    只读暴露并前置到沙箱 `PATH`，使装在 `$HOME` 下的 `node`/`npm`/`fd`/`go` 等工具链可用
    （否则它们因未被挂载而在沙箱内“缺失”，只有位于 `/usr` 等白名单目录的工具可用）。
- **AppImage 支持（`tools.sandbox.appimage_extract_and_run`，默认开）**：沙箱按设计拦截
  `mount`/新挂载 API 且不暴露 `/dev/fuse`，AppImage 无法以 FUSE 挂载运行。开启后沙箱进程环境
  注入 `APPIMAGE_EXTRACT_AND_RUN=1`，AppImage 运行时改为解包到会话私有 `/tmp`（写临时根不产生
  待审候选）再执行，**不扩大任何权限**；非 AppImage 程序忽略该变量。设为 `false` 可关闭。
- **代理策略（`tools.sandbox.network.proxy`，默认 `strip`）**：默认**不把宿主代理传入沙箱**
  （如 mihomo 只代理 opencode 自身），避免宿主 `HTTPS_PROXY=127.0.0.1:7890` 在沙箱内不可达
  导致 `pip`/`npm` 按代理配置走网络时报 `Connection refused`。`strip` 会在外部命令前
  `unset` 代理变量（`run_command` 与 `runtime.run` 都覆盖）；`passthrough` 沿用宿主代理；
  也可用 `{ http, https, all, no_proxy }` 显式设置（未列出的代理变量清除）。
- **`/etc/resolv.conf` 净化**（`tools.sandbox.resolv_conf`，默认 `sanitize`）：仅保留
  `nameserver` 行，剥离 `search`/`domain`/`options`，避免泄露宿主内网/Tailscale 域；
  可配 `hide`（不暴露）或 `passthrough`（原样暴露宿主文件）。
- **`/proc` 泄露项隐藏**（`tools.sandbox.hide_proc_paths`，默认 `/proc/cmdline`、`/proc/version`）：
  procfs 全局可见（不随 pid namespace 隔离），以空文件只读覆盖，避免泄露宿主内核命令行
  （`root=UUID`、`crashkernel`）与内核版本。此项与上一条「危险全局 sysctl 强制遮蔽」共用
  同一只读覆盖机制，用户配置**只增不减**。
- **宿主本机访问拦截（`tools.sandbox.network.host_local_block`，默认开）**：见 §6.1。
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
    其中命中 `mask_paths`（宿主敏感路径/沙箱存储）时一律**硬拒绝**，即使有审批界面也不放行；
    仅遮蔽目录（`mask_dirs`）命中才走审批放行。命中判定前先对路径做**规范化**（展开 `~`、
    绝对化并解析符号链接，含 `/proc/<pid>/root`、`/proc/<pid>/cwd`、`/proc/<pid>/fd` 及悬空
    符号链接），否则 `read_file /proc/self/root/etc/shadow` 或工作区内指向宿主凭据的符号链接
    可绕过 `mask_paths`/`mask_dirs`。同一路径同时命中 `mask_paths` 与 `mask_dirs` 时，
    以 `mask_paths` 硬拒绝优先（不得因软命中而放行）。
  - `mask_dirs_approval = false` 时命中遮蔽目录不弹窗，直接硬遮蔽。

> **残余风险（user namespace）**：NeoAI 以 root 运行时，`bwrap` 只能把调用者 uid 1:1
> 映射（`uid_map 0 0`），无法在插件内做真正的 uid 重映射；而 `conceal` 为去指纹刻意
> 不在 root 下新建 userns。默认完整能力下，载荷在命名空间内即宿主 root：**文件系统修改**
> 由「命名空间 + 只读根 + overlay 暂存 + 遮蔽 + 审批」封死，**宿主全局状态修改**由
> `cap_drop`（网络/时钟/模块/裸 I/O/重启/MAC/审计）+ seccomp（设备节点、时钟、端口 I/O、
> mount/unshare/bpf/… 屏障）封死；`CAP_DAC_OVERRIDE` 仍可**读取**遮蔽名单之外 DAC 保护的
> 0600 文件（信息泄露，非修改）。设 `cap_add = {}` 可进一步收敛为最小权限（包安装按
> `packages.cap_add` 按需加回，混合命令不加回）。**彻底根治需在容器运行时层启用
> `userns-remap` / rootless**，使容器 root 映射到高位宿主 uid——属部署侧配置，不在本插件内。

### 6.1 宿主本机访问拦截（`tools.sandbox.network.host_local_block`，默认开启）

网络整体策略为「**放行 + 记录**」（`offline=false`），但默认拦截**向宿主本机**的访问，
防止 AI 借外部命令触达宿主服务（SSRF，如宿主管理面板、内部端口、云元数据）：

- **机制**：为沙箱外部命令注入 `HTTP_PROXY`/`HTTPS_PROXY`（HTTP 代理）与 `ALL_PROXY`
  （`socks5h://`），指向宿主侧纯 Lua 过滤代理 `sandbox/host_proxy.lua`（监听 `127.0.0.1`
  随机端口，`host_local_proxy_port` 可固定）。代理支持 **HTTP CONNECT + 绝对形式 + SOCKS5**：
  目标命中本机集合（`127/8`、`::1`、宿主各网卡 IP、`169.254/16`、`fe80::/10`、
  `169.254.169.254`）即拒绝并记录；其余外部目标双向转发并记录。**目标只解析一次**：
  经 `getaddrinfo` 规范化为 IP（把八进制/十六进制/短式 IPv4、全展开 IPv6、IPv4-mapped
  `::ffff:127.0.0.1` 等统一），再按数值判定本机集合，随后**用同一批已校验 IP 连接**——
  避免「字面量字符串比较与内核解析不一致」及「校验/连接两次解析被 DNS rebinding 切换答案」。
  解析失败时 fail-closed 视为本机拒绝。记录经 `run_command` 结果摘要回传，并写入 `network` 证据。
- **T0 默认放行网络**：`tools.sandbox.privilege.tiers[0].network = true`，T0 不再
  `--unshare-net`；`offline=true` 时仍硬隔离（优先于档位）。
- **边界（重要）**：这是**应用层**过滤。**不认代理的裸 TCP**（`nc`/`ssh`/数据库客户端、
  忽略代理变量的工具）在共享 netns 下可直连宿主本机，不受此层约束。要硬拦截裸 TCP 只能：
  root + iptables/nft（按目的地过滤），或无 root 的 `slirp4netns`/`passt`（原生用户态
  网络栈，本机未安装）——本插件不引入这些依赖。故本机拦截为「非硬边界」，见
  `sandbox/host_proxy.lua` 模块头。
- **残余信息泄露（共享 netns 固有）**：因 T0 共享宿主网络命名空间，`/proc/net/tcp`、
  `/proc/net/unix`（宿主连接/Unix socket 清单）、`ip addr`/`ip route`（netlink，宿主拓扑）
  对沙箱可见。`/proc/net` 是 `self/net` 符号链接，无法用挂载遮蔽；netlink 也不经挂载。
  仅靠隔离 netns 才能消除，与「网络放行」取舍冲突，故作为已知边界记录（连接仍受代理与本机
  拦截约束，泄露的是元信息）。
- **抽象命名空间 Unix socket（残余）**：路径遮蔽只作用于文件系统 socket（如
  `/var/run/docker.sock` 被替换为字符设备）；**抽象命名空间 socket（`@name`，无文件路径）
  不受遮蔽**，共享 netns 下可被 connect。与裸 TCP 同类，属应用层过滤无法覆盖的残余边界
  （审计实测 `AF_UNIX` connect 可达，抽象 socket 计数可见）。
- **宿主元信息泄露（procfs 全局条目，残余）**：`/proc/loadavg`、`/proc/pressure/*`、
  `/proc/cpuinfo`、`/proc/bus/{pci,input}`、`/proc/schedstat` 等为全局 procfs 条目，暴露宿主
  负载/进程数/硬件信息；新 uts ns 会**继承宿主 hostname**（`hostname` 可见宿主名）。属低危
  信息泄露，按需可继续加入 `MANDATORY_PROC_MASKS`（会牺牲对应工具）。
- **setuid 二进制（残余，已被 NNP 中和）**：沙箱内可见宿主 setuid 程序（`mount`/`passwd`/
  `ssh-keysign`/`fusermount3`/`chrome-sandbox` 等），但 `NoNewPrivs=1` 使 setuid/文件 capability
  一律被忽略，且 `mount`/`clone(CLONE_NEWUSER)` 已被 seccomp 拦截、`/dev/fuse` 不存在，
  故不可借其提权。
- **与独立 netns 网关（`network.gateway`）互斥**：后者启用时由网关提供代理，本拦截自动让位。

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
      cap_add = {},                  -- 默认最小权限（`--cap-drop ALL`）；按命令窄范围加回（包安装经 packages.cap_add）
      run_as = { uid = 0, gid = 0 }, -- 载荷运行身份：默认 root（工具链/包管理可用，写入仍全部暂存）；非 root 启动自动用当前 uid；设为 nobody 等专用非 root uid 可加固（/root 将不可遍历）
      cap_drop = {                   -- 主机全局能力收敛（即便 cap_add 含 ALL 也逐项丢弃）
        "CAP_NET_ADMIN", "CAP_SYS_TIME", "CAP_SYS_MODULE", "CAP_SYS_RAWIO",
        "CAP_SYS_BOOT", "CAP_MAC_ADMIN", "CAP_MAC_OVERRIDE", "CAP_AUDIT_CONTROL",
      },
      -- 最小只读系统集（白名单）：/usr 不整目录暴露，但只读暴露 /usr/share 与 /var/lib（支持 * 通配）。
      readonly_roots = {
        "/lib", "/lib32", "/lib64", "/libx32", "/bin", "/sbin", -- 加载器/二进制符号链接根（必须）
        "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/lib32", "/usr/lib64", "/usr/libx32",
        "/usr/libexec", "/usr/include",
        "/usr/share",                -- 运行时共享数据（nodejs/dotnet/java/git-core/terminfo 等）
        "/usr/local/bin", "/usr/local/sbin", "/usr/local/lib", "/usr/local/libexec",
        "/usr/local/include", "/usr/local/go",
        "/var/lib",                  -- 宿主包数据库（dpkg/apt/rpm 等）；危险子路径仍由 mask_paths 遮蔽
      },
      readonly_paths = {             -- 最小 /etc 必要文件白名单（支持 * 通配）
        "/etc/ld.so.cache", "/etc/passwd", "/etc/group", "/etc/nsswitch.conf",
        "/etc/hosts", "/etc/ssl", "/etc/alternatives", "/etc/localtime",
      },
      expose_paths = {},             -- 宿主运行时直通（opt-in）：遮蔽/临时根之后只读暴露并前置 PATH
      expose_path_env = true,        -- 是否把 expose_paths 目录前置到沙箱 PATH
      expose_tool_paths = false,     -- 自动直通宿主 PATH 工具目录（opt-in，默认关；使 $HOME 下 node/npm/fd/go 可用）
      appimage_extract_and_run = true, -- AppImage：注入 APPIMAGE_EXTRACT_AND_RUN=1 解包运行（沙箱不暴露 /dev/fuse，无法挂载）
      resolv_conf = "sanitize",      -- /etc/resolv.conf：sanitize（默认，仅 nameserver）| hide | passthrough
      tmpfs_roots = { "/tmp", "/var/tmp" }, -- 每会话私有临时根（不作为 overlay lower；退出即销毁）
      ephemeral_roots = { "/tmp", "/var/tmp" }, -- 临时候选根（cwd 子树除外）：写入会话私有、退出即丢弃，不产生待审/审批
      tmp_private_base = "host",     -- host（默认，宿主根下的隐藏子目录，命名空间映射回该根）| session
      hide_proc_paths = { "/proc/cmdline", "/proc/version" }, -- 追加隐藏项（危险 sysctl 强制表只增不减）
      mask_paths = {                 -- 遮蔽宿主敏感路径（目录 tmpfs / 文件 socket 用 /dev/null）
        "/run/docker.sock", "/var/run/docker.sock", "/var/lib/docker",
        "/root/.config/herdr", "/etc/1panel", "/root/.ssh", "/root/.aws", "/root/.gnupg",
        "/root/.git-credentials", "/root/.config/git/credentials", "/root/.config/gh",
        "/home/*/.ssh", "/home/*/.gnupg", "/home/*/.git-credentials", "/home/*/.config/gh",
        "/etc/shadow", "/etc/gshadow", "/etc/machine-id", "/etc/ssh", "/var/log",
        "/root/.bash_history", "/root/.zsh_history",
      },
      mask_dirs_enabled = true,      -- 遮蔽目录总开关（默认开）
      mask_dirs = { "/home", "/root" }, -- 遮蔽目录列表（cwd 所在作用域只读暴露并遮蔽其余条目）
      mask_dirs_approval = true,     -- 命中遮蔽目录时弹窗审批（复用工具审批 UI）
      process_roots = {},            -- run_command 可写根（默认仅 cwd，自动补入；按需加回更多）
      network = {
        host_local_block = true,     -- 拦截向宿主本机的访问（应用层；裸 TCP 不覆盖，见 §6.1）
        host_local_proxy_port = 0,   -- 宿主过滤代理端口（0 = 自动分配 loopback 随机端口）
        proxy = "strip",             -- strip | passthrough | { http, https, all, no_proxy }
      },
      seccomp = { enabled = true, filter_path = "" }, -- 内置 denylist 过滤器；仅 bwrap 后端
      workspace_root = vim.fn.stdpath("cache") .. "/NeoAI/sandbox", -- 基根；每进程实例隔离在 <root>/instances/<pid>_<ts>
      review = { enabled = true, auto_apply = false }, -- 异步审批：候选进入待审队列
      retention = { candidate_days = 7, max_pending = 20 },
      policy = {
        deny_tools = {},             -- 硬拒绝工具名（确认亦不可覆盖）
        rules = {},                  -- 受限 Lua 规则函数数组
      },
      limits = { wall_ms = 60000, dynamic = true, memory_ratio = 0.5, cpu_cores_max = 4, cpu_global_max = 0, pids_max = 2048 },
    },
  },
})
```

策略规则在受限环境执行：经 `setfenv` 把规则的**全局环境**替换为显式白名单（`string`/`table`/
`math`/`ipairs`/`pairs`/`type`/`tostring`/`tonumber`/`facts`），因此 `os`/`io`/`debug`/`require`/
`load`/`pcall` 均不可达（`pcall` 刻意排除，避免规则吞掉预算 hook 抛出的中止错误）；`setfenv`
不可用或失败时 fail-closed 拒绝该规则。仍有指令/墙钟预算；规则异常、超时、结构错误统一产生
`DENY`（`POLICY_EVALUATION_FAILED`）。聚合顺序为 `DENY` 高于 `NEEDS_CONFIRMATION` 高于 `ALLOW`。
> 残余：规则若通过 upvalue 提前捕获了全局（如 `local os = os`），`setfenv` 无法回收——仅从
> 可信来源引入规则。

## 8. 事件

`SANDBOX_PUBLISH_STARTED` / `SANDBOX_COMMITTED` / `SANDBOX_DISCARDED` /
`SANDBOX_CONFLICT`，以及异步审批 `SANDBOX_REVIEW_ENQUEUED` / `SANDBOX_REVIEW_APPROVED` /
`SANDBOX_REVIEW_REJECTED` / `SANDBOX_APPLIED`，详见 [EVENTS.md](EVENTS.md)。

## 9. 测试

`lua/NeoAI/tests/test_sandbox.lua` 覆盖：加载器强制附加规格、fail-closed、
状态机/幂等/fencing、策略聚合与受限规则、dry-run 不落盘、CAS 发布与冲突、
buffer 写盘重定向、运行时能力探测与隔离进程执行、异步审批入队/应用/拒绝、
run_command overlay 候选捕获（含删除 whiteout 捕获与尝试目录清理）、
进程内 `mask_paths` 硬拦截、密钥按名强制脱敏（文本层），以及安全加固回归：
发布前路径重规范化（拒绝 `..` 穿越/遮蔽目标）、风险分级与审批 UI 的路径解析、
受限规则环境隔离（`os`/`pcall` 不可达）、seccomp x32 位拦截、候选存储目录 `0700`。

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

### 独立 netns + 宿主网关（`network.gateway`，opt-in）

开启 `tools.sandbox.network.gateway.enabled=true` 后，沙箱进程进入**独立网络命名空间**
（`ip netns exec <ns> bwrap …`，bwrap 不再 unshare net），仅能到达宿主网关；网关在宿主侧
对目标 `host:port` 先做 TCP connect **探针**（可探测宿主哪些端口在监听），随后**不回传真实
服务数据**，而是把拦截原因（JSON）返回给客户端：

- 开放端口：`HTTP 403` + `{"open":true,"reason":"port_open_but_service_access_blocked_…"}`；
- 关闭端口：`HTTP 502` + `{"open":false,"reason":"port_not_open:…"}`；
- 非宿主本机地址：`HTTP 403` + `only_host_local_addresses_allowed`。

实现为宿主侧 HTTP 代理（`sandbox/gateway.lua`，纯 Lua/vim.uv）；`run_command` 注入
`HTTP(S)_PROXY` 指向网关，故 `curl`/`wget`/`git`/`nmap --proxies` 等**走代理的工具**可经网关
探测并拿到原因；直接裸 TCP 不经代理无法到达宿主（隔离 netns），因此不生效。`run_command`
结果会附上本次探测摘要（开放/关闭端口 + 拦截原因）供 AI 参考。

编排（`sandbox/net_gateway.lua`）：创建 veth 对与 netns、默认路由指向网关，并在宿主防火墙
（如 ufw）插入**仅针对该 veth 且限定目的地址与端口**的入站放行规则（`-i <veth> -d <gw_ip>
-p tcp --dport <网关端口>`，而非按接口全放行——否则 netns 可直达宿主任意非 loopback 服务），
并插入 `-i <veth> -j DROP` 的 FORWARD 丢弃规则（宿主 `ip_forward=1` 时阻止 netns 经宿主转发
直达局域网/外网）；均在 teardown 时移除。资源在会话/插件卸载时清理。需 root 与 `ip`；不可用
时 fail-closed（`GATEWAY_*` 明确错误）。

> 说明：真正的透明拦截（任意裸 TCP 均可扫端口、服务被拦）需要 `TPROXY` +
> `SO_ORIGINAL_DST`，纯 Lua 无法实现（需少量原生代码），当前以代理网关方案覆盖代理类工具。

### AI 读取到密钥时的提示

当工具结果被 token 化（AI 读取到 `NEOKEY_*`）时，`tools/executor` 会在结果末尾附加说明：
「`NEOKEY_*` 为沙箱密钥 token——真实密钥已被沙箱遮蔽，仅对 AI 不可见，**不代表程序出错、
也不影响程序实际运行**（写入文件时自动替换回原有真实密钥）。沙箱只遮蔽密钥形态的高熵串，
路径、函数名、构建哈希等原样保留。」环境变量侧另有 `NEOAI_TOKENIZED_ENV` 信号（见密钥防护章节）。

### 外部操作 broker

外部副作用走适配器协议，不套用本地文件发布的原子性/回滚承诺。适配器须声明
`supports_idempotency` / `idempotency_retention` / `supports_query` / `transaction_boundary` /
`compensation_semantics` / `irreversible_effects`。broker 以稳定 `operation_id` 记录意图，
按幂等键去重，并在结果不明时进入 `OUTCOME_UNKNOWN`、由 `reconcile` 查询对账，禁止盲目重放。

### 保留期与指标

`:NeoAISandboxPrune` 按 `retention.candidate_days` 清理已终结（已拒绝/已应用/失败/冲突）的
候选与变更单元；有恢复/对账/已排队引用者不清理。`:NeoAISandboxMetrics` 输出候选/待审/已应用/
已拒绝/冲突计数。存储根及子目录（`candidates`/`reviews`/`evidence`/`receipts`/`host_ops`）
权限收紧为 `0700`，避免同机其他用户枚举/读取未发布内容与命令详情。
> 边界：同一 uid 的本地进程可读写这些文件（与能读写用户其它文件等价），不属本插件的防护范围；
> 发布侧的路径重校验与遮蔽硬拒绝仍会拦截被篡改候选写出到敏感位置。

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

每次外部进程尝试使用独立资源域 `tools.sandbox.limits`。默认 `dynamic = true`：按宿主资源
动态推导上限——内存 = `MemTotal * memory_ratio`（默认 0.5，受 `memory_max_bytes` 上限约束）、
CPU = `min(核数, cpu_cores_max)` 个核（默认 4）、PID = `pids_max`（默认 2048）；静态
`memory_bytes`/`pids`/`cpu_max`（>0）优先于动态推导。

所有并发任务挂在共享父域 `neoai` 下：父域 `cpu.max` = 全局预算 `cpu_global_max`
（默认 `max(1, 核数-1)`，留 1 核给 nvim/UI），子域 `cpu.max` = `min(cpu_cores_max, 全局预算)`。
因此并发任务 CPU 配额之和不会超过宿主可用核数（避免「每个任务各 N 核、合计远超核数」的
超卖导致整机打满、chat 界面卡顿），单任务仍受 `cpu_cores_max` 细分约束。

控制面创建 cgroup v2 子域并把进程加入
（`join_prefix` 先写 `cgroup.procs` 再 exec），结束/异常时 `cgroup.kill` 并删除子域，确保进程树
收敛。cgroup 不可用时默认**跳过限制并告警**（不阻断）；设 `limits.fail_closed = true` 则明确拒绝
（`SANDBOX_CGROUP_UNAVAILABLE`），不静默降级。

**CPU 亲和性**（`limits.cpu_affinity`，默认 `"auto"`）：沙箱进程经 `taskset -c` 绑定到 **nvim 当前
CPU 之外**的核，避免与 nvim 抢占同一核；单核宿主或 `taskset` 缺失时自动跳过。可设 `"off"`/`false`
关闭，或用 `"2,3"`/`"2-3"` 指定显式 cpuset。亲和性在 bwrap 之前施加（`_prepend_affinity`），
覆盖整个沙箱进程树；与 cgroup `cpu.max` 配额叠加。

### seccomp 基线

内置生成 denylist 过滤器（x86_64/aarch64）：先校验 `AUDIT_ARCH`（不符直接 `KILL_PROCESS`），
再对危险 syscall（`ptrace`/`mount`/`unshare`/`setns`/`bpf`/`kexec_load`/`init_module`/
`io_uring_*`/`open_by_handle_at`/新挂载 API `open_tree`/`move_mount`/`fsopen`/`fsconfig`/
`fsmount`/`fspick`/`mount_setattr`/…）返回 `EPERM`，其余 `ALLOW`。经 `bwrap --seccomp FD`
在载荷 exec 前施加（bwrap 特权设置不被过滤）：`runtime` 用 shell 打开过滤器 fd 再 exec bwrap。

- **`clone`/`clone3` 命名空间过滤（审计加固）**：`unshare`/`setns` 被拦，但 `clone`/`clone3`
  带 `CLONE_NEWUSER` 等标志可创建**嵌套 userns**，绕过 unshare 拦截。过滤器对 `clone`
  检查 `args[0] & (NEWUSER|NEWNS|NEWPID|NEWNET|NEWIPC|NEWUTS|NEWCGROUP)`，命中返回 `EPERM`；
  `clone3` 的标志在指针参数中无法由经典 seccomp 解引用，故返回 `ENOSYS` 促使 glibc 回退到
  `clone`（回退后再受上述 flags 过滤），避免直接 `EPERM` 打断线程创建。
- **`socket` 地址族白名单（审计加固）**：仅放行 `AF_UNIX`/`AF_INET`/`AF_INET6`/`AF_NETLINK`，
  其余地址族（`AF_PACKET`/`AF_VSOCK`/`AF_ALG`/`AF_XDP`/`AF_TIPC`…）返回 `EPERM`。尤其
  **`AF_VSOCK` 不受网络命名空间隔离、也不经代理**，可直达宿主 vsock 服务（审计实测可创建
  并 connect 宿主 CID）——属独立于 netns 的宿主通信通道，必须按地址族拦截。
- **x32 ABI 位拦截（审计加固）**：x86_64 的 x32 进程 `seccomp_data.arch` 与 x86_64 相同，但
  syscall 号带 `__X32_SYSCALL_BIT`（`0x40000000`）。若不做屏蔽，denylist 的精确 `JEQ` 全部
  失配 → 整份过滤器被绕过（`syscall(165 | 0x40000000, …)` 仍到达 `sys_mount`/`mknod` 处理器）。
  过滤器在加载 `nr` 后先 `JSET 0x40000000` → `KILL_PROCESS`，早于所有号码比较（仅 x86_64）。
- **`mknod`/`mknodat` 设备节点屏障（审计加固）**：`mode` 含 `S_IFCHR`/`S_IFBLK` 位即返回
  `EPERM`，封死「创建设备节点 → `open` 直接触达真实设备 → 裸读磁盘」的逃逸通道（设备节点
  不经 overlayfs，暂存/遮蔽/审批对 `open` 设备节点均无效）。FIFO（`mkfifo`）与普通文件
  不受影响；即便 capability 含 `CAP_MKNOD` 也硬拦（纵深防御，覆盖 `cap_add={"ALL"}` 场景）。
- `tools.sandbox.seccomp.enabled=true` 时启用；**默认开启**（与 `--cap-drop ALL` 共同构成纵深防御）。
- `filter_path` 为空则用内置 denylist 生成到 `<root>/seccomp/baseline-v5-<arch>.bpf`
  （文件名带版本，内容变更时自动重建）；
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

`run_command` 在把 stdout/stderr 回传模型前经 `conceal.redact()`；**进程内 `read` 工具读取
`/proc/*` 时同样补做脱敏**（审计发现 `read_file /proc/self/mountinfo` 曾直出 overlay 真实
路径，绕过 shell 输出脱敏；现由 `wrapper.gate` 对 `/proc` 读取结果调用 `conceal.redact`）。
抹去：

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
仅在 commit 发布到真实工作区时解密。**加密后的 key（token）与敏感环境变量名**出现时只留痕
并在待审悬浮窗**提级警告**（判为密钥操作：工作区内 L2 / 工作区外 L3，强制待审，
`⚠ 密钥操作`），**不终止 Agent**；
仅当**原始密钥**（未加密的真实值）出现在**工具参数**或 **AI 可见上下文**（即将发给模型的
wire 消息）中时，才硬拦截并立即终止整个 Agent——后者说明 token 化被绕过（沙箱上下文被突破）。
注：检测前会解析路径/代码语义，`api_key = os.getenv("..._API_KEY")` 这类代码表达式不会被当作
原始密钥。

> **chat 界面高亮「获取/使用密钥的命令」**：工具块渲染时扫描其**参数**与**结果**（模型上下文），
> 命中沙箱 token（`NEOKEY_*`）或**具名规则**命中的原始密钥时，在该工具折叠块**外**单独追加一行
> 告警并施加 `NeoAISecretWarning`（红色加粗下划线）高亮。告警**明确区分两种情况**：
> `⚠ 密钥：<工具> 获取了密钥（…）`——结果/内核观测到读取了密钥；`⚠ 密钥：<工具> 使用了密钥（…）`
> ——参数携带密钥值/token/敏感环境变量名，或使用型命令（`ssh -i`/`curl`/`gpg`…）引用密钥文件；
> 两者兼具时提示「获取并使用了密钥」。**仅列出/查看密钥文件不告警**：`ls`/`find`/`stat` 等
> 仅列出型命令与 `list_files`/`search_files`/`file_exists` 等工具不构成读取或使用；读取型命令
> 引用密钥路径但结果无密钥内容也不触发（避免误报）。**告警路径采用严口径**
> （`secret.is_sensitive_path`）：仅真正的凭据文件（`~/.ssh`/`~/.aws`/`~/.kube`/`.env`/`id_rsa`/
> `*.pem`/`*.key`/`/etc/shadow`/`/etc/ssh`/`trusted.gpg`/keyring…）计入；普通命令频繁打开的
> 非密钥文件（`/etc/ld.so.cache`、`/etc/nsswitch.conf`、`/etc/passwd`、`/etc/group`、
> `/etc/os-release`、`/etc/localtime`、`*.env` 如 `go.env`、`.npmrc`、`.bash_history`/
> `.python_history` 等）一律忽略，避免把 `uname`/`cat /etc/os-release` 等误报为「获取密钥」。
> 明细回退顺序：观测到的密钥文件 → 参数中的密钥文件 → 密钥类型（具名规则）→ 敏感环境变量名 → 通用提示。
> 折叠标题保持干净（不再追加 `⚠ 密钥`），收起状态也能看到独立的高亮警告行。含密钥时工具调用的
> **参数与结果完整展示（不截断）**，行内命中的密钥值（`NEOKEY_*` token / 具名规则原始密钥）以同组
> 高亮；轨迹显示模式在工具行追加同款文本标记并同样行内高亮。见
> `ui/components/message_list.lua`、`ui/components/fold.lua`。
>
> **观测优先（eBPF/strace/procfs）**：默认由 `tools.sandbox.observe` 在内核层观测沙箱进程
> 真实打开的密钥文件（`openat/open`，按 attempt cgroup 精确归属），命中即在对应工具块告警并
> 指向**实际访问的文件**，优先于命令/参数解析；观测后端不可用时才回退上述内容扫描启发式。
> 高熵检测只作用于**新增上下文与工具调用**（请求前守卫 `secret.context_leak_from` 增量扫描，
> 压缩替换历史时才回退全量），不对整段历史每轮重扫。
>
> **启动探测**：插件启动时探测后端可用性（eBPF 检查 `bpftrace` 可执行、root、tracefs、
> 内核 BTF；再依次检查 strace/procfs）。eBPF 内核不可用/未安装、或回退 strace 而 strace
> 未安装时 `vim.notify` 提示（可用 `tools.sandbox.observe.notify=false` 关闭）。
>
> **非阻塞挂载**：eBPF 探针挂载默认**不阻塞命令**（`tools.sandbox.observe.wait_ready_ms=0`）。
> bpftrace 挂载约需 0.5s，此前每条进程命令都在执行前有界等待（最多 800ms），是可感知的固定
> 卡顿来源；现在探针异步挂载，命令立即执行，挂载完成前的早期访问可能漏观测（由命令解析启发式
> 兜底）。需要更全观测时把 `wait_ready_ms` 设为正值（有界等待，代价是每条命令固定增加该等待）。
>
> **观测预热**（`tools.sandbox.observe.prewarm=true`，默认开）：进程命令返回后，在 **AI 生成
> 下一轮的间隙**后台预创建下一个 attempt 的 cgroup 并挂载 eBPF 探针，使约 0.5s 的挂载与 AI 输出
> 重叠；下一条进程命令直接复用**已挂载**的 cgroup + 探针（事件派发目标在复用时指向本次 attempt），
> 无需等待挂载。超时未被复用（默认 90s，`prewarm_ttl_ms`）则回收探针与 cgroup。仅 eBPF 后端
> 需要预热（strace/procfs 启动廉价）。

### 检测（熵 + 字符集启发式）

- 候选：长度 `[min_length, max_length]`、含字母与数字、不同字符数 `≥ min_distinct`、
  香农熵 `≥ min_entropy`（默认 20/200/8/3.5）。
- 默认排除**纯小写十六进制**（`exclude_pure_hex`）：避免把 git SHA / sha256 / md5 等
  哈希与校验和当密钥；代价是纯小写 hex 形式的密钥不被覆盖。
- **缩小认定范围**（`entropy_requires_context`，默认开）：裸高熵串必须呈**密钥形态**
  （含 `-`/`_` 分隔符）且**不是代码标识符/软件包名**（snake_case 函数名/常量，或
  `-`/`_` 分段且每段为「字母+数字」或纯数字的包名/版本串，如 `create_urllib3_context`、
  `HTTP_SSL_CONTEXT_V2_API`、`openjdk-21-jdk-headless`、`libssl-dev`、`python3.11-minimal`），
  或处于**敏感变量名赋值上下文**
  （`KEY=`/`TOKEN:`/`PASSWORD=` 等）才视为密钥；纯字母数字/base64 串（SRI `integrity`、
  内容哈希、构建产物摘要等元数据）不再 token 化。另排除带算法前缀的内容摘要
  （`sha512-`/`sha256-`/`md5-`/`blake2-`…）与**路径分量**（紧邻 `/` 的串，如
  `/opt/build_0abc…/lib`），避免把 `package-lock.json` 的 integrity、`python -m build`
  源码里的哈希、工具输出中的 Python 回溯函数名或路径写坏/读错。
  设 `false` 退回旧的「任意高熵串即密钥」行为。
- **仅疑似密钥文件做高熵扫描**（`entropy_secret_paths_only`，默认开）：全文熵扫描只对
  路径命中「疑似密钥文件」的内容执行，避免对普通文件/工具输出做昂贵的逐字符熵计算。判定见
  `sandbox.secret.is_secret_path`，覆盖 `~/.ssh/`、`~/.aws/`、`~/.gnupg/`、`~/.config/gcloud`、
  `~/.kube/`、`~/.docker/config.json`、`.env`、`id_rsa`/`*.pem`/`*.key`/`*.p12`、`~/.bashrc`/
  `~/.zshrc`/`~/.profile` 等 shell 启动脚本与历史（`~/.bash_history`/`~/.zsh_history` 等）、
  `/etc/*` 等系统敏感配置。**具名规则（私钥块/AKIA/ghp_/sk-/JWT/Bearer…）与敏感变量名赋值
  仍对所有内容生效**；设 `false` 退回旧的「所有内容都做熵检测」行为。
  门控对**显式目标**（工具路径参数 / 命令串中的路径）用宽口径；对**内核观测到的路径**用
  严口径（`secret.is_sensitive_path`）——`dpkg -l`/`ss`/`python` 等普通命令会顺带打开
  `/etc/ld.so.cache`、`/etc/nsswitch.conf` 等宽口径命中项，若据此启用熵扫描会误 token 化
  结果中的软件包名。
- **环境变量按名强制 token 化**：`sanitized_env()` 对变量名（按 `_` 切分后整段匹配）
  命中 `KEY`/`TOKEN`/`SECRET`/`PASSWORD`/`CREDENTIAL` 的值**无视熵阈值**一律替换为 token，
  覆盖 `GLM_API_KEY=dfe946…` 这类纯 hex 密钥逃过熵检测的盲区（刻意不含过宽的 `AUTH`，
  以免误伤 `SSH_AUTH_SOCK` 等路径变量）。非敏感名变量若值含 `/`（PATH/LD_LIBRARY_PATH/
  PYTHONPATH/SSL_CERT_FILE 等路径或 URL），**只应用具名规则、不做通用熵 token 化**，
  避免把路径段误 token 化导致 pip/ssl 等找不到库或模块。
- **文本层按名强制 token 化**：`tokenize()`（工具结果/暂存内容）对文本中的赋值
  `NAME=value`、`NAME="value"`、`"NAME": "value"`，当 `NAME` 命中同一敏感名规则时，
  无视熵阈值替换 `value`。这补上熵检测的两个盲区：纯小写 hex 段（被 `exclude_pure_hex`
  排除）与含 `.` 等多段密钥（被 `RUN_PAT` 拆成不满足候选条件的片段），例如
  `/proc/self/environ` 中的 `GLM_API_KEY=dfe946….rwbWDAf…`。值字符集刻意收窄，避免跨条目吞并。
- `allowlist` 可再加 Lua pattern 排除。参数见
  [configuration.md](configuration.md) 的 `tools.sandbox.secrets`。

### 环境变量：沙箱进程拿到真实值，AI 只见 token

`sanitized_env()` 生成 token 化覆盖（供日志/审计与 AI 可见面）；`sandbox_env()` 在构造沙箱
进程环境时会把 token 还原为真实密钥——**token→真实密钥的替换仅允许发生在沙箱内部进程**。
因此：

- 沙箱内程序（`curl`/`pip`/`python` 等）使用**真实密钥**，不会因遮蔽而 401 / 构建失败。
- 命令输出回传模型前会重新 token 化，AI 仍只看到 `NEOKEY_<hex>`；`NEOAI_TOKENIZED_ENV`
  列出被遮蔽的变量名，便于判断哪些值在 AI 可见输出中是 token。
- 需要整体关闭环境变量 token 化（调试 / 本地可信运行时）时，设
  `tools.sandbox.secrets.tokenize_env = false`；工具结果与暂存内容仍按密钥防护处理。
  **注意这会降低隔离强度，仅建议在可信环境临时使用。**

### 加密映射与生命周期

- 每个真实密钥分配一个随机 token（`NEOKEY_<hex>`）；映射表**仅在内存**，不落盘。
- **进沙箱加密**：工具结果（`read_file`/`run_command`/… 回传模型前）、工作区暂存视图
  （`candidate._base_entry` / `merge_candidate`）与 `run_command` 的**环境变量**都做 token 化，
  供 AI / 日志 / 待审 UI 面使用。
- **token→真实密钥的替换仅限沙箱内部进程**：`sandbox_env()` 还原环境变量，门禁把命令参数
  （`ctx.sandbox_command`，exec 工具还原 argv）与物化进 overlay 的文件
  （`materialize_overlay`）中的 `NEOKEY_` 还原为真实值，使 `pip`/`python -m build`/`curl`
  等程序正常运行。AI 上下文、日志、证据与待审 UI 仍只看到 token（命令输出回传前重新 token 化）。
- **出沙箱解密**：只在 commit / CAS 发布写入真实文件时把 token 还原为密钥
  （`candidate.publish`）。映射缺失（如热重载后）时**拒绝发布**（`SECRET_UNRESOLVED`），
  绝不把 token 当内容写入真实文件。
- 暂存视图 token 化后，`base_hash`（真实基线，用于 CAS 冲突检测）与
  `view_base_hash`（token 化基线，用于改动判定）分开记录，保证只读工具与编辑一致。

### 留痕与告警

- 每次检测到新密钥、以及工具参数中用到 token 或出现敏感环境变量名，都写入一条
  `kind="secret"` 证据。
- 工具参数用到 token 或出现敏感环境变量名（全大写、含 `KEY`/`TOKEN`/`SECRET`/`PASSWORD`/
  `CREDENTIAL` 段，长度 ≥ 6；如 `GIT_COMMIT_AI_API_KEY`）时置 `ctx.secret_operation`，
  候选按密钥操作判级（工作区内 L2 / 工作区外 L3）并**强制待审**（`auto=false`），
  **不终止 Agent**。
- 候选内容涉及 token，或本次调用命中敏感环境变量名时，待审变更单元带 `secret_warning`，
  `NeoAISandboxReview` 悬浮窗以红色 `⚠ 密钥操作×N` 醒目提示（含环境变量名，见
  [configuration.md](configuration.md)）。
- 事件：`SANDBOX_SECRET_DETECTED` / `SANDBOX_SECRET_TRACED` / `SANDBOX_SECRET_BLOCKED`。

### 原始密钥硬拦截（工具参数与 AI 上下文）

映射表中已知的**原始密钥**出现在以下**任一**位置时终止整个 Agent：

1. **工具参数**（深度扫描，出向）：拒绝该工具调用（`SANDBOX_SECRET_BLOCKED`）；
2. **AI 可见上下文**（请求前扫描 `core/agent/recovery` 即将发送的 wire 消息）：说明沙箱
   token 化被绕过（沙箱上下文被突破），拒绝该轮请求。

两种情况都会：调用 `core.agent.runtime.abort(agent, "secret_exposure")` **立即终止整个
Agent**；发出 `SANDBOX_SECRET_BLOCKED` 事件并 `vim.notify` 明确通知用户。token
（`NEOKEY_*`）不触发终止，只提级审批。

> 边界：熵检测为启发式；默认按上下文收窄（`entropy_requires_context`）后，无分隔符、无
> 敏感名上下文的纯字母数字/base64 串不再视为密钥——可消除 integrity/构建哈希误伤，代价是
> 无前缀、无上下文的纯 base64 密钥（如 AWS secret key）不再覆盖。token 在 commit 时无损还原，
> 误报不改变最终写入内容，仅增加留痕噪声。映射表不落盘，热重载后未提交的 token 无法还原，
> 该候选会被拒绝发布（fail-closed）。纯小写 hex 密钥、以及命令在沙箱内直接读取真实文件
> 并在同一命令内使用密钥（不经过模型）的行为不在覆盖范围内。

### 16.1 AI 生成的高熵信息（生成密钥也关注）

除「宿主已有密钥进入沙箱」外，**AI 在沙箱内自行生成**的密钥类高熵内容同样被关注：
`secret.detect_generated(files)` 对候选文件内容直接做熵/具名规则检测（与只识别已 token 化的
`warn_for_files` 互补），命中生成私钥块、随机 token、API key 等时：

- 写 `kind="secret"` 证据（`event="generated_high_entropy"`）；
- 发 `SANDBOX_SECRET_DETECTED`（`source="generated"`）并 `audit.observe`（`GENERATED_HIGH_ENTROPY`）；
- 候选按密钥操作提级并**强制进入待审**（悬浮窗 `⚠ 密钥操作`），不终止 Agent。

`NEOKEY_*` token（宿主密钥的加密形式）不计入生成检测，由 `warn_for_files` 处理。命令输出/
工具参数中的生成密钥经 `tokenize_result`/`tokenize_args` 走既有 token 化路径。

### 16.2 本机 SSH 服务禁止访问

禁止沙箱内进程使用宿主的 SSH 服务（ssh-agent / sshd）：

- **遮蔽 agent/sshd 路径**（`mask_paths` 默认）：`/run/sshd`、`/run/sshd.pid`、
  `/run/ssh-agent.socket`、`/run/user/*/keyring*`、`/run/user/*/ssh*`、`/run/user/*/gnupg*`、
  `/tmp/ssh-*`、`~/.ssh`、`~/.ssh-agent` 等（agent 套接字被替换为字符设备，`connect` 失败）。
- **清除环境变量**：外部命令前置 `unset SSH_AUTH_SOCK SSH_AGENT_PID`（`runtime.proxy_unset_snippet`
  始终生成该片段），使 `ssh`/`git` 无法借宿主 agent 认证。
- **命令级硬拒绝**：`wrapper` 对 `ssh`/`scp`/`sftp`/`sshpass` 或 `ssh://` 指向本机
  （`localhost`/`127.`/`::1`/`0.0.0.0`/`169.254.`）的命令直接拒绝（`SSH_LOCAL_SERVICE_DENIED`），
  写证据与事件（共享 netns 下裸 TCP 不经代理，需命令级闸门）。远端 `ssh` 不受影响。
- 分类上 `sshd`/`ssh-agent`/`ssh-add`/`ssh-keysign`/`gpg-agent` 属 T2 特权（主机效果需审批）。

## 17. 权限档位与自动提权

默认所有外部命令以**最小权限**运行；权限不足时**自动发起升级**（记录，不静默执行），
并按档位逐级收紧审查。核心模块 `sandbox/privilege.lua`（分类/解析/留痕）与
`sandbox/hostop.lua`（T2 主机效果提案）。

### 档位

| 档 | 名称 | 用途 | 隔离 | 审查 |
|---|---|---|---|---|
| **T0** | minimal | 普通命令 | 完整能力（默认 `cap_add={ALL}`）减去主机全局能力（`cap_drop`：网络/时钟/模块/裸 I/O/重启/MAC/审计）+ seccomp（含设备节点屏障）+ 遮蔽 + overlay 暂存 + **默认放行网络（经 host_proxy 拦截本机，见 §6.1）** | 无逐命令审查；fs 改动进待审队列 |
| **T1** | elevated | 网络访问、受控 docker、包安装 | 隔离内执行，网络放行；`cap_add` 收窄时含包管理器的命令（`req.package`，含链式）按 `packages.cap_add` 加回窄能力；docker.sock 仅 docker 命令解除遮蔽 | 自动授权、留痕；fs 改动进待审队列 |
| **T2** | privileged | cap_add、宿主 socket、宿主挂载 | **嵌套 userns** 内执行并授予完整能力（cap 被 userns 作用域限制，够不到宿主；seccomp 基线仍生效） | 主机效果冻结为**提案**，异步审批后 replay |

- 分类：`privilege.classify()` 解析命令，`docker/podman`→T1，`curl/git push/pip/npm`→T1 网络，
  `sudo/mount/modprobe/iptables/systemctl`→T2；复合命令取最高档。规则见
  `tools.sandbox.privilege.classify`（`bins` / `bin`+`subs`）。
  - **只读 `mount` 不算特权**：裸 `mount`、`mount -l`、`mount --show-labels`、`mount -t ext4`
    以及 `mount | grep`/`findmnt` 等仅读取挂载表，按 T0 执行；只有存在位置参数（设备/挂载点）
    或变更型选项（`-a`/`-o`/`--bind`/`--remount`/`--move`/`--make-*` 等）的 `mount` 才是 T2。
- 最高档：`tools.sandbox.privilege.max_tier`（默认 2）；越界由策略硬拒绝
  （`PRIVILEGE_TIER_EXCEEDS_MAX`）。
- **载荷运行身份（默认 root）**：默认 `run_as.uid=0`——沙箱载荷以 root 运行，使 AI 可在沙箱内使用
  `/root` 下的工具链（nvm/cargo/go 等 0700 目录非 root 不可遍历）与包管理（dpkg 硬检查 euid==0）。
  **所有写入仍全部进入 overlay 暂存并冻结为候选，真实磁盘只读**。设为专用非 root uid（如
  `nobody` 65534）可加固：非 userns 档位由 `setpriv` 把载荷降为该 uid，配置的窄能力以 ambient
  形式保留；T2（嵌套 userns）下该 uid 在新建 userns 内未映射，`setpriv` 会
  `setresuid: Invalid argument`，故 **T2 不追加 `setpriv`**，载荷以 userns root 运行（能力受
  userns 作用域限制，够不到宿主）。
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
>
> **包安装绝不冻结为主机提案**：包管理器命令（`apt`/`pip`/`pipx`/`npm` 等，`req.package`）即使
> 在沙箱内因只读/权限失败而命中提权信号，也**不升级 T2、不冻结主机提案**——沙箱内失败即失败，
> 绝不回退到宿主机安装（`hostop.freeze` 拒绝冻结，`hostop.replay` 对历史遗留提案兜底拒绝）。
> 安装应通过包管理器可写根在 overlay 暂存内完成（见 §5、§17）。

### 配置

见 [configuration.md](configuration.md) 的 `tools.sandbox.privilege` 与 `tools.sandbox.docker`。

### 17.1 载荷运行身份、overlay 可写实测与写入提权

**默认 root**（`tools.sandbox.run_as.uid=0`）：沙箱载荷以 root 运行，使 AI 可在沙箱内使用 `/root`
下的工具链（nvm/cargo/go 等 0700 目录非 root 不可遍历）与包管理（`dpkg` 硬检查 `euid==0`，仅
capability 不够）。**写入仍全部进入 overlay 暂存并冻结为候选，真实磁盘只读**；宿主不可修改由
命名空间 + 只读根 + overlay + 遮蔽 + `/proc/sys` 只读绑定 + seccomp 保证，不依赖非 root。

**非 root 启动 = 沙箱内 guest root**：NeoAI 以非 root 用户启动时，用 **user namespace** 把当前
用户映射为沙箱内 root（`--unshare-user --uid 0 --gid 0`）——沙箱内 `euid=0`，工具链与包管理可用，
但宿主身份仍是当前非 root 用户，写入同样全部暂存。真正需要**宿主 root** 的操作（写系统路径、
`systemctl` 等）在沙箱内无法完成：冻结为待审，用户在审批界面确认后经 `writer`/`hostop` 以
`sudo`（继承 tty，可能要求输入密码）执行。

**可选加固（降权为专用非 root uid）**：设 `run_as = { uid = 65534, gid = 65534 }` 后，非 root 启动
NeoAI 时自动用当前 uid，并用 `--unshare-user --uid/--gid` 在用户命名空间内切到该 uid；root 启动时
用配置的专用非 root uid：**bwrap 仍以 root 运行**（这样它才能在 `/root` 等 0700 目录下创建挂载点、
挂载 overlay），仅**载荷**经 `setpriv --reuid/--regid` 降权，配置的窄能力（`packages.cap_add` 等）
以 **ambient** 形式保留，否则降 uid 会清空 permitted/effective 导致包安装无法获取锁。不能改用
`bwrap --uid N`（root 下会把 guest N 映射到宿主 root，即 root 伪装）。沙箱可写目录（overlay
upper/work、暂存、会话）会 chown 到该 uid。
> 边界：非 root 载荷对 0700 目录（如 `/root`）的**绝对路径**访问受 DAC 限制（`cwd`/相对路径正常），
> 且 `dpkg` 等会因 `euid!=0` 失败；此时请把工作区/`workspace_root` 与工具链放在可被该 uid 遍历的
> 位置（如 `/home/<user>`）。

**overlay 可写实测**：`runtime.overlay_writable(lower, upper, work)` 在选层前用真实执行路径 +
真实载荷 uid 实测「写-读-删」三段，结果按 `(lower, upper.dev, uid, gid)` 缓存。挂载成功不代表
可写（非 root + upper 归属/DAC 可能 EROFS/EACCES），故「能挂 **且** 能写」才用 overlay，否则
降级为 bind 私有可写目录。`:NeoAISandboxCaps` / `runtime.overlay_diagnosis()` 可排查。

**写入全暂存 + 落盘降权优先**：命令的写入全部进入 overlay/暂存（不碰真实盘）。真正落盘
（CAS 发布）经 `sandbox/writer.lua`：先以非 root 载荷身份尝试（root 进程用 `setpriv` 降权执行），
成功即 `writer=nonroot`；失败且为权限错误（EACCES/EPERM/EROFS）则返回 `NEEDS_ROOT`，由
`review.apply` 标记 `apply_state=NEEDS_ROOT` 并进入 `:NeoAISandboxReview` 待审（不自动提权）。
用户确认（`allow_root=true`）后：插件为 root 则以 root 写入，否则以 `sudo`（继承 tty）写入；
回执记录 `writer`/`escalated`。提权重试前重新校验基线（防 TOCTOU）。

**全档位自动提权**：权限/网络失败（`operation not permitted`/`permission denied`/
`read-only file system`/网络不可达等）时，**任意档位**都可自动升档（T0→T1→T2，直到
`privilege.max_tier`）并在隔离内重跑；每步写 `privilege` 证据、发
`SANDBOX_PRIVILEGE_ESCALATION_REQUESTED` 并 `audit.observe`，不静默。

## 18. 安全分级、容器受控与行为审计

### 18.1 审批按安全级别分级（`sandbox/risk.lua`）

每次效果类调用都会评估安全级别（L0-L3），并在待审界面以 `[L0]`-`[L3]` 徽标着色展示，
同时记录证据（`kind="risk"`）与 `SANDBOX_RISK_ASSESSED` 事件：

| 级别 | 含义 | 触发（取最高） |
| --- | --- | --- |
| L0 low | 常规、可逆、工作区内 | 工作区文件写入、只读 |
| L1 moderate | 网络、包安装、T1 提权 | 网络访问、`apt/pip/npm…`、T1 |
| L2 high | 用户/系统路径写入、T2、危险命令、**工作区内的密钥操作** | `~`/系统路径写入、T2、`chmod -R 777`、`systemctl`、工作区内密钥操作 |
| L3 critical | **工作区外的密钥操作**、主机效果、破坏性命令 | 工作区外密钥操作、主机操作、`mkfs`、`dd of=/dev/*`、`curl … | sh` |

审批动作由 `risk.action(level, opts)` 给出：`auto`（直接发布）/ `record`（发布并记录）/
`review`（进入异步待审，不阻塞 agent）/ `block`（硬拒绝）。默认 `default="review"`
保持既有语义；可用 `tools.sandbox.approval.levels` 覆盖单级动作。

- **内核/危险命令硬拒绝**（`risk.deny_reason`）：默认异步模式下，普通命令（`python`/`node`/
  `go`/`rust`/`apt`/`pip`/`npm` 等，含 T1/T2）**立即在沙箱内执行、不弹审批**，写入全部冻结为
  候选；仅下列命令**直接拒绝、不执行**：内核模块/状态（`modprobe`/`insmod`/`rmmod`/`kmod`/
  `modinfo`/`sysctl`/`kexec`/`reboot`/`shutdown`/`poweroff`/`halt`/`bpf`/`perf`）、`setcap`、
  内核防火墙（`iptables`/`ip6tables`/`nft`/`arptables`/`ebtables`）、`swapon`/`swapoff`，
  以及**绕过文件暂存层**的破坏性模式（`mkfs`、`dd of=/dev/*`、`> /dev/sd*`、fork 炸弹、
  `curl … | sh` 等）。`rm`/`rm -rf` 等纯文件修改**不在硬拒绝列表**：只读根 + overlay 修改暂存
  已保护宿主机，其删除效果冻结为待审候选（详见 §5 暂存机制）。
  段首为 `sudo`/`doas`/`env`/`bash -c` 等包装器时会向下识别真实命令。`mount`/`umount` 仍按
  T2 主机操作冻结为提案（审批后 `sudo` replay），`mknod`/`unshare` 等由 seccomp 与命名空间
  隔离处理，不在硬拒绝列表内。

- **包管理器专用识别 + 封顶 L2**：`apt`/`apt-get`/`dnf`/`pacman`/`pip`/`pipx`/`uv`/`poetry`/
  `conda`/`mamba`/`npm`/`npx`/`pnpm`/`yarn`/`bun`/`cargo`/`go`/`gem`/`composer` 等
  （`tools.sandbox.packages.managers`）统一识别为包安装（T1 + 网络 + 包状态目录可写根 + root 能力）。
  此外按**改动路径特征**识别（`privilege.package_path_manager`）：命中 `node_modules`、
  `site-packages`/`dist-packages`、`/var/lib/apt`、`/var/lib/dpkg`、`~/.cargo`、`~/.npm`、
   `conda/pkgs`、`/var/lib/gems` 等即视为「由包管理器修改」。包安装属高危但非 critical：
   其状态文件位于工作区外、且常含高熵 GPG 签名/哈希，不因「工作区外写入 / 密钥误报」升到 L3
   （`risk.classify` 对 `package` 封顶 L2，并跳过对包状态文件的密钥检测）；仅当命令本身命中
   设备级破坏模式（`mkfs`、`dd of=/dev/*`、`curl … | sh` 等）时才保留 L3。
   - **放宽风险与提示**（`privilege.package_sensitive`）：**安全安装**（未改动第三方软件源/密钥，
     如普通 `apt/pip/npm install`）不因写入 `/usr`/`/var`/`/etc` 等系统路径升到 L2，**风险封顶中危
     （L1）**且不触发密钥误报；**敏感安装**（`add-apt-repository`/`sources.list`/`--add-repo`/
     `--index-url`/`npm --registry`，或 `apt-key`/`trusted.gpg`/`keyring`/`gpg --import`/`rpm --import`
     等改动第三方软件源或密钥/信任链）保留 L2 高危，并在审批窗头行标注 `⚠ 涉及软件源/密钥`。
     放宽只作用于**风险与提示**：包安装写入仍在暂存层，需用户确认后才应用，不自动落盘。
  - **解释器模块形式**：`python3 -m pip install …` 也识别为包安装（`-m` 后的模块即管理器），
    沙箱内对包安装命令注入 `PIP_BREAK_SYSTEM_PACKAGES=1`/`PIP_ROOT_USER_ACTION=ignore`，
    突破 Debian/Ubuntu 的 PEP 668（`externally-managed`）限制——所有写入仍进 overlay 暂存并
    冻结为候选，绝不落宿主。
  - **安装产物跨命令可见**：存在暂存改动的包可写根（如 `/usr`、`~/.local`）会自动加入后续
    命令的可写层，使后续 `python -m build` 等能看到刚安装的包（否则非包安装命令默认只覆盖 cwd）。

- **写入保护优先**：文件改动始终经暂存层，故**进程提权行为仅做记录**（证据 + `SANDBOX_PRIVILEGE_RECORDED`
  + 审计），用于后续异常行为分析，不作为阻塞式审批门槛。T2 主机效果仍冻结为提案（见 §17）。
- **仅在必要时才暂停**：默认异步模式下 agent 不被暂停；只有真正需要人工判断的动作
  （如命中遮蔽目录、`block` 级别）才走阻塞式审批或拒绝。

### 18.2 通过命令执行结果判断安全级别

外部命令结束后，`risk.from_result({code,stdout,stderr})` 解析结果信号（权限不足
`operation not permitted`/`permission denied` → L2，网络失败 → L1，包变更
`Setting up …`/`Successfully installed …` → L1，破坏性输出 → L3），与调用前分级取较大者，
记录证据并驱动自动提权检测（§17）。只读进程工具也会记录结果分级。

### 18.3 容器受控运行（`sandbox/container.lua`）

AI 调用容器运行时（docker/podman 等）时，尽量让容器与沙箱处于**同一 namespace**：

- **无守护进程运行时**（`podman`/`buildah`）：CLI 在沙箱内执行、容器是 CLI 子进程，命令重写为
  注入 `--net=host --pid=host --ipc=host --uts=host`，容器复用沙箱的 pid/net/ipc/uts
  命名空间，被沙箱隔离边界一并约束（`tools.sandbox.container.share_namespace`，默认开）。
- **有守护进程运行时**（`docker`/`nerdctl`）：容器由宿主侧 daemon 创建，无法复用沙箱命名空间，
  保持「受控 socket」方案（§17）并记录原因 `DOCKER_NAMESPACE_NOT_SHARABLE`。

计划写入 `kind="container"` 证据并发出 `SANDBOX_CONTAINER_PLANNED`。

### 18.4 新会话自动审批（默认关闭）

`tools.sandbox.review.session_auto_approve`（默认 false）：开启后 L0/L1 风险自动应用，
L2+ 与包/密钥仍进入待审。目的是即便仅靠本地模型的智能水平，也能在写入保护下管理 agent
行为。命令 `:NeoAISandboxAutoApprove [on|off|status]` 可随时切换。

### 18.5 安装包额外规则

包安装命令（`apt/pip/npm/go/cargo/gem/composer…`）分类为 `package`（T1，需网络）。
`tools.sandbox.packages.mode`：`review`（默认，强制进入待审，**不随会话自动审批放行**）、
`allow`（允许自动应用）、`deny`（硬拒绝）。包安装的写入仍在暂存层，不会直接改动宿主。
放宽后安全安装仅需一次确认（风险封顶中危），敏感安装（改动第三方软件源/密钥）保留高危标注；
两者均不自动落盘。

### 18.6 敏感信息全部脱敏与行为审计

- **具名敏感信息规则**（`sandbox/secret.lua` 的 `rules`/`extra_rules`）：除熵检测外，按 Lua
  pattern 识别私钥块、`AKIA…`、`ghp_…`、`sk-…`、`xox…`、JWT、`Bearer`/`Basic` 等结构化凭据，
  命中即 token 化（可无损还原）并留痕。`secret.redact()` 提供破坏性脱敏（用于日志/证据），
  发出 `SANDBOX_SENSITIVE_REDACTED`。
- **行为审计**（`sandbox/audit.lua`）：记录 AI 的读取/调用/进程/网络/密钥/提权/容器/包安装等
  观测，累计加权风险分与异常计数；`:NeoAISandboxAudit` 查看摘要。高风险观测发出
  `SANDBOX_AUDIT_ANOMALY`。

### 18.7 命令与事件

- 命令：`:NeoAISandboxAudit`、`:NeoAISandboxAutoApprove [on|off|status]`。
- 事件：`SANDBOX_RISK_ASSESSED` / `SANDBOX_RISK_BLOCKED` / `SANDBOX_AUDIT_OBSERVED` /
  `SANDBOX_AUDIT_ANOMALY` / `SANDBOX_CONTAINER_PLANNED` / `SANDBOX_SENSITIVE_REDACTED`。
- 测试：`lua/NeoAI/tests/test_sandbox_governance.lua`。
