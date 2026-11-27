# AGENTS.md — NeoAI 开发约定（供 AI 编码助手）

本文件是仓库级的开发与协作约定。修改代码前请先阅读 `styleGuide.md` 与 `docs/plugins.md`。

## 项目概览

NeoAI 是一个 Neovim AI 编程助手插件（Lua）。分层：

- `lua/NeoAI/kernel/` — 内核：`config_store` / `event_bus` / `events` / `lifecycle` / `logger` /
  `services`（服务定位器）/ `plugins`（插件宿主）。零业务依赖。
- `lua/NeoAI/core/` — 核心业务：session / model / agent。
- `lua/NeoAI/services/` — 服务层（chat/tool/model/status/skills/herder/mcp）。
- `lua/NeoAI/tools/` — 工具系统与内置工具。
- `lua/NeoAI/ui/` — 表现层。
- `lua/NeoAI/plugins/` — 插件目录与默认组合（`catalog.lua`）及副作用插件。

## 关键命令

```bash
# 运行全部内置测试（并行，双 lane 有界并发 + 独占通道，输出 SUMMARY passed/failed）
# 可选环境变量 NEOAI_TEST_WORKERS 覆盖 light 通道 worker 数（默认按实际核数与可用内存动态分配：
#                  light=核数-heavy，上限 16；每 heavy 分片预留 1536MB、每 light 分片 512MB）
#                 NEOAI_TEST_HEAVY_WORKERS 覆盖 heavy 通道并发上限（默认核数/2；总并发硬上限 = 核数-2；=1 回退旧串行通道）
#                 运行期每个分片启动前还会经 runner/memguard 做一次内存许可（有界等待后放行）
#                 NEOAI_TEST_MEM_MB 可覆盖可用内存（MB，便于复现/CI 固定机器规格）
#                 NEOAI_TEST_SANDBOX_ROOT 固定测试进程的沙箱存储根（默认临时目录；沙箱内/只读 cache 场景必要）
#                 NEOAI_TEST_VERBOSE=1 还原逐用例明细打印（默认仅失败 + 套件摘要）
nvim --headless --clean -u NONE --cmd "set rtp+=$PWD" \
  --cmd "lua require('NeoAI').setup({ log={level='ERROR'}, session={auto_save=false} })" \
  -c "lua local r=require('NeoAI.tests.parallel').run(); print('SUMMARY passed='..r.passed..' failed='..r.failed); vim.cmd(r.failed>0 and 'cquit 1' or 'qa!')"

# 顺序运行（调试单套件）：run_all("plugins") / run_all("kernel","services")
nvim --headless --clean -u NONE --cmd "set rtp+=$PWD" \
  --cmd "lua require('NeoAI').setup({ log={level='ERROR'}, session={auto_save=false} })" \
  -c "lua local r=require('NeoAI.tests').run_all(); print('SUMMARY passed='..r.passed..' failed='..r.failed); vim.cmd('qa!')"
```

- 测试框架：`lua/NeoAI/tests/init.lua`，套件文件 `lua/NeoAI/tests/test_*.lua`，运行器自动加载。
- 并行运行器：`lua/NeoAI/tests/parallel.lua` 为**薄门面**（签名不变），职责拆到
  `lua/NeoAI/tests/runner/{config,timings,shard,spawn,scheduler,report}.lua`。按「文件（套件）」
  分派到隔离 headless 子进程，采用**双 lane 有界并发**：light（非资源重套件，LPT 分片成 W 个
  进程）与 heavy（`sandbox*`/`pty`，一套件一进程，上限 H）**重叠执行**、任一子进程结束即回填，
  约束 `#light≤W`、`#heavy≤H`、`W+H≤核数-2`（预留两核给系统/编辑器）。权重优先用实测耗时缓存 `.neoai_test_timings.json`
  （gitignored），无缓存按用例数。另有**独占通道**：会触碰宿主全局 `/run/netns` 的套件（默认
  `sandbox_view*`、`sandbox_boundary_net`、`sandbox_boundary_escape`、`sandbox_docker_policy`、
  `gateway`）不进 heavy lane，而在两 lane 全部结束后一套件一进程串行执行，绝不与其他分片
  重叠（并发 `ip netns add/del` 会争用共享的 `/run/netns` 挂载点）；可用 `opts.exclusive_suites` 覆盖。
  文件级分片保证固定端口（各文件唯一）与文件内固定临时路径
  不跨 worker 冲突；子进程注入独立 `mcp.cache_path`。
- **主线程卸载（父进程 + worker 子进程）**：每个 worker 把结果写入 **sidecar**（小 JSON）并把
  stdout/stderr 直接落盘为**日志文件**；父进程只读小 sidecar、不缓冲/扫描整段输出、不驻留分片
  全量输出，失败时**懒读日志尾部**（路径 + 末尾 N 行）。worker **按分片只加载本分片测试模块**、
  跳过 fresh worker 首套件的冗余全量重置、默认仅打印失败 + 套件摘要。heavy 并发之前必须先完成
  结果处理卸载，否则父端输出回流会随 H 放大。
- 过滤（隔离复现/跳过危险用例）：`NEOAI_TEST_ONLY=<p1,p2>`（仅跑含任一子串的用例）、
  `NEOAI_TEST_SKIP=<p1,p2>`（跳过）。`NEOAI_TEST_HEAVY=1` 开启重资源/环境敏感用例
  （真实 OOM、双实例并存等，见 `test_sandbox_boundary_consistency.lua`），默认跳过。`run_all` 每个套件前会恢复干净环境（配置默认 + 插件
  `start_all` + 工具 `reload_tools`），杜绝跨套件污染。
- **宿主稳定性**：在嵌套容器/VM 上，内核 overlay 不可用时若回退 **fuse-overlayfs 挂载整机 `/`**
  会卡死内核并触发硬件看门狗整机复位。测试默认关闭该兜底（测试默认 `tools.sandbox.fuse_root_overlay=false`，
  见 `tests/init.lua`），降级为 bind+seed，故无需再跳过相关用例；确需验证真实 fuse 兜底时用
  `NEOAI_TEST_ALLOW_FUSE=1`（仅限具备真实内核隔离的环境）。overlay **能力探测**的真实挂载已用
  跨进程文件锁（`utils/lock.lua`）按 work 目录串行化。
- 测试必须离线可复现：HTTP 用 `tests/http_server.lua` 的本地 TCP mock；除非用例明确要求，不要访问真实外部 API。
- 每个测试套件有独立会话临时目录；`kernel.*` 与 `core.session.*` 提供 `reset()` 供隔离。

## 架构硬性约定

1. **业务代码不得直接 `require` 具体服务模块**（`NeoAI.services.*`）。改为：
   `require("NeoAI.kernel.services").use("services.model_service")`。
   `use()` 在服务未提供/被禁用时返回 `nil`，**不得回退默认模块**；调用方需显式降级。
2. **副作用必须可卸载**：任何注册（命令、全局键位、事件订阅、提示段、MCP 连接、工具、状态栏监听、
   UI 注入）都必须返回清理函数，由插件宿主在卸载时调用。禁止只注册不释放。
3. **新增可替换能力**：在 `plugins/catalog.lua` 登记为服务提供方（`service` + `module`），
   或作为独立副作用插件（`start` 返回清理）。工具用 `tool.<name>` 规格。
4. **事件名使用常量**：`kernel/events.lua`，禁止硬编码事件字符串。
5. **配置**：新增配置项写入 `default_config.lua` 并同步 `docs/configuration.md` 与英文版。
6. **插件生命周期**：`register → start（依赖优先、提供服务、执行 start）→ started`；
   失败回滚本次新启动的插件；`stop` 逆序清理并注销服务。启动/停止必须幂等。
7. `NeoAIReloadAll` 必须先 `plugins.stop_all()` 再清缓存重载。
8. **懒加载启动（默认，无配置）**：`NeoAI.setup()` 只登记插件并注册命令/键位占位符，**不启动**；
   首次触发经 `NeoAI.ensure_phase1/ensure_started` 两阶段异步启动（阶段 1 UI 就绪即打开界面，
   阶段 2 后台按帧加载；见 `plugins/builtin/lazy.lua`、`kernel/plugins.start_list_async`）。
   新增副作用插件时须标注 `phase`（`catalog.lua`）；只读访问器不得触发启动。
   测试/热重载用 `ensure_started_sync()` 同步等待全量启动。
9. **工具执行必须过沙箱**：所有工具经 `services.sandbox` 门禁（`tools/executor` 强制，
   `tools/registry`/加载器附加 `__sandbox_spec`）。安全边界（网关 `GATEWAY_REQUIRES_BWRAP`、
   降权 `SANDBOX_SETPRIV_UNAVAILABLE`）缺失时**硬拒绝**，不得绕过或静默降级。「无任何隔离后端」
   （`SANDBOX_BACKEND_UNAVAILABLE`）默认亦硬拒，仅当显式 `tools.sandbox.allow_unisolated=true` 时
   降级为**直跑**（无隔离、写入直接落盘，不冻结候选）——绝不静默（告警 + 审计）。
   **例外——防御层/能力缺失**（seccomp 基线 `SANDBOX_SECCOMP_UNAVAILABLE`、unshare 的 `/proc/sys`
   遮蔽 `SANDBOX_SYSCTL_MASK_UNAVAILABLE`、unshare 档位挂载/capability `SANDBOX_PRIVILEGE_UNSUPPORTED`）：
   默认降级放行，且**绝不静默**——seccomp 走三层行为模型（第 1 层 bwrap 原生 / unshare 经
   `setpriv --no-new-privs --seccomp-filter`；第 2 层 eBPF 行为兜底，命中危险 syscall 即
   `cgroup.kill`，补救型；第 3 层无行为强制层，仅强告警）；unshare 的 `/proc/sys` 遮蔽与档位
   挂载/capability 则忽略并留痕（载荷在 userns 内为 root，T0 所需能力等效具备）。
   任何降级均写 evidence（`sandbox_degrade`）+ 发 `SANDBOX_DEGRADED` 事件 + `vim.notify`（会话去重）+
   结果提示。安全优先可经 `tools.sandbox.seccomp.on_unavailable="deny"`（或 `require_backstop=true`）
   恢复 fail-closed。**禁止以字符/文本静态判定作为拒绝依据**：字符串/正则/命令名黑名单只能用于
   **风险分级与提示文案**（命中最多 `needs_confirm` + 强制人工复核），**绝不拒绝执行**、绝不新增
   危险命令名或危险文本模式的黑名单。理由（实测见 `docs/sandbox.md` 核心不变量 6）：文本匹配判定
   的是命令「长什么样」而非进程「做了什么」，`kmod --help`、`echo 'curl x | sh'` 被误拦，而
   `| $SH`、`ba""sh`、`eval "$(curl …)"`、先落盘再 `source` 全部漏判。新增拒绝必须落在**内核/运行时
   强制层**：seccomp 基线（syscall）、capability 档位（`CAP_NET_ADMIN` 等）、命名空间与设备隔离、
   cgroup 资源域与 `cgroup.kill`、网络门禁、人工审批。危险二进制以**所需被剥夺的 syscall/capability**
   定义，**不以名字定义**（busybox 软链可绕名字，绕不过 `EPERM`）。动态侧（exec 调用链守卫）只做
   **观测 + 补救**，不等价于 seccomp 的发生前拦截；classic seccomp 无法解引用路径参数，「按二进制
   路径发生前拦截」需 LSM/bwrap。**无任何动态强制层**（既无 seccomp 又无 eBPF backstop）时强制
   `approval_mode="prompt"`（同步事前审批），**禁止** `async` 的「先执行后审批」。默认异步审批
   （`tools.approval.mode="async"`）：效果类工具立即在沙箱内
   执行并冻结候选，真实修改进入待审队列，用户经 `:NeoAI SandboxReview` 异步确认后应用。
   详见 `docs/sandbox.md` 与下方「沙箱视图模型（三视图 / 不叠加 / 不直写）」。

10. **命令入口单一**：全部用户命令收敛为一条 `:NeoAI <子命令>`（`plugins/builtin/commands.lua` 的
    `M.SUBCOMMANDS` 为唯一来源）。Neovim 命令名不允许 `.`/`_`/`-`，`complete=customlist` 只接受纯字符串
    候选——子命令说明由 `ui/command_hint.lua` 呈现（装了 cmp-cmdline 则注册 `neoai_cmd` 源，否则内置浮窗）。
    新增功能一律**加子命令**（带 `desc` 与 `phase1` 标记），不再新增 `:NeoAI*` 平铺命令；`lazy.lua` 占位命令
    与真实命令同名，阶段判定必须走 `commands.is_phase1()` 以免两处名单漂移。
11. **输入框上下文引用**：`#` 占位符（`ui/components/hash_complete.lua`）只插入 `#{...}` 文本并高亮，
    在 `input_box.M.submit` 里**发送前**才展开；解析失败必须**原样保留**占位符（不得抛错/变空串），
    所有输出统一经 `utils/stringx.safe_truncate`（UTF-8 安全），`#{message}`/`#{notify}` 按**字符数**封顶。
12. **仓库约定文件加载**：`AGENTS.md` 通过 `core/session/agents_md.lua` 在会话首个回合注入**一轮
    `read_file` 工具调用**（assistant tool_calls + tool 结果，id 一一对应），**不得**写进系统提示段
    （会使 provider 前缀缓存全量失效）。该虚构轮必须带一个**占位 reasoning**：DeepSeek thinking +
    tools 要求请求中所有历史 assistant 回传 `reasoning_content`，缺失会直接 400（即便这一轮是
    NeoAI 自己构造的）。幂等：每个顶层 agent 只一次；子 Agent 不注入。
    `AGENTS.md` 的**只读**访问免沙箱审批（`session.agents_md.auto_allow_read`，默认开，仅作用于
    `read_file`）；AI **更新** `AGENTS.md` 仍走既有沙箱审批，**禁止**因任何 auto_allow/session_auto
    被静默放行。
13. **并发工具各自出结果**：工具结果按原始调用顺序落库（保证 `tool` 消息与 `assistant.tool_calls` 对齐），
    但界面**不得**等整批完成才渲染：`tool_loop` 每完成一个工具即经 `kernel/live_metrics.set_result` 发布
    运行期结果，UI 对尚未配对的结果消息用它渲染（落库后清除）。

## 沙箱视图模型（三视图 / 不叠加 / 不直写）

`tools.sandbox.single_view`（默认开；`NEOAI_SINGLE_VIEW=0` 或配置 `false` 可回退旧模型）下，
沙箱只有**三个视图**，任何改动都必须维持这三层语义：

| 视图 | 存储 | 角色 |
| --- | --- | --- |
| ① 真实盘 | 宿主文件（只读 lower） | **唯一**落盘点：只有审批发布（`writer.apply`/`apply_file`）能写真实文件 |
| ② 沙箱合并视图 | `<沙箱暂存基>/view/<root>/upper`（= 暂存） | 命令 / 只读工具 / LSP 共用同一份；AI 未发布改动**就是**视图内容 |
| ③ 候选 | 只存 delta 元数据 `{path, action, hash, mode, base_hash}` | 审批展示/发布时按需从视图②取内容 |

### 不叠加（每轮占用恒定，禁止逐命令叠加 overlay）

1. **暂存目录就是 overlay upper**：`candidate.process_dir()` 返回稳定视图目录；`_workspace_path`
   对视图覆盖根直接返回 upper 路径。不得再引入第二份"工作区暂存副本"作为可写数据。
2. **禁止每条命令物化/捕获回写**：`materialize_overlay` 对视图原生条目只登记签名、不拷贝；
   `merge_candidate(_async)` 只登记台账、不写第二份内容。旧模型（每条命令前暂存→upper、
   命令后 upper→暂存）实测会把 nvim RSS 吃到 27.7GB 被内核 OOM 杀死，**禁止恢复**。
3. **视图基目录稳定**：`rotate_session`（agentEnd）只推进会话 id，**不迁移/不复制**暂存；
   视图目录只随进程结束/`reset` 清理。
4. **同一 upper 只挂一次**：常驻实例与一次性命令不得同时挂载同一 `<view>/<root>/upper`；
   不属于常驻实例的命令（T1/T2、包安装、跨挂载、fuse）使用独立 `<view>/attempt_<id>`，
   结束后按 delta 合并回视图并删除。`bwrap` 报 `upperdir is in-use ... undefined behavior`
   即为违规（`dmesg` 可见），必须修成串行/独立 upper，不得忽略。
5. **常驻实例挂载期间不得从宿主侧写 upper**：写入必须经命名空间桥（`file_bridge`/`ns_fs`）
   在挂载点内完成；`invalidate` 对视图原生条目交给 `resident.sync_real`（宿主侧 `delete` 属于
   未定义行为，实测会阻塞）。
6. **捕获只处理 delta 且必须有预算**：优先用写日志（eBPF）路径集；全量遍历只做元数据比对。
   `capture_max_bytes` / `capture_max_files` 超限转 blob 或跳过；`generated_dirs`（`target`、
   `node_modules`、`build`、`.gradle` 等，按工作区根向下 0~2 层）整棵子树**不捕获**。
   `non_capture_paths` 中的包管理器缓存同理。
7. **候选内容按需**：冻结/发布不得把整个工作区或构建产物读进 Lua；单文件受
   `max_file_bytes`、整体受 `capture_max_*` 约束，大文件一律走 blob（内核 copyfile，不读内存）。

### 不直写（沙箱任何写入都不得直接落真实盘）

1. **唯一落盘点**：`writer.apply` / `writer.apply_file`（审批发布）。其余任何模块
   （candidate/merge/materialize/capture/ns_fs/LSP/reclaim）**禁止**直接写真实工作区文件。
2. **缓存也不直写**：`~/.gradle`、`~/.m2`、`~/.cargo/registry`、`~/.npm/_cacache`、pip/uv/go
   缓存等只作为**只读 lower**；沙箱内下载落在当前会话视图里（进程结束即丢弃）。**禁止**用
   读写 bind 把宿主缓存目录直接暴露给沙箱（曾实现过 `persist_caches`，已按"禁止直写"移除）。
3. **卸载/删除同规则**：删除 = 视图内 whiteout 或 `retire`（同盘 rename 到搬出层），
   发布时才作用于真实盘；不得为了"省事"直接 `unlink`/`rm -rf` 真实文件。
4. **沙箱自身存储也算"非真实盘"**：视图/候选/blob/证据都写在沙箱存储根，
   可以清理（`reclaim`、`:NeoAI SandboxGC`），但不属于用户数据。
5. **回退开关不是许可**：`NEOAI_SINGLE_VIEW=0` 只用于兼容/排查；旧模型的两份可写数据
   与逐命令叠加同样受本约束（尤其"不直写"）。

### 不驻留内存（候选内容只存元数据，文件留在同盘）

> **教训（2026-11-27）**：宿主 nvim 以 `anon-rss 27.2 GB + swap 4.4 GB` 被内核 OOM
> `SIGKILL`，整个交互面消失、连错误日志都来不及写。现场：单条工具循环 65 轮，每轮把
> 8k+ 个暂存文件（其中 5 GB 来自工作区外的 `~/.cache/sdw-cargo-target` 构建产物）的内容
> 读进 Lua 组装候选；沙箱实例目录残留 7.6 GB，直到手动 `:NeoAI SandboxGC`。**结论**：
> 文件内容绝不能随候选/物化常驻 nvim 内存——它属于磁盘，用同盘复制与命名空间视图传递。

1. **候选只存 delta 元数据**：`files[]` 只有 `path/action/hash/blob/mode` 等元数据，
   `content` 恒为 `nil`（`tools.sandbox.inline_candidate_bytes` 默认 0 = 从不内联）。
   任何新增字段不得携带文件正文。
2. **内容用同盘复制**：暂存 → 候选 blob 一律 `uv.fs_copyfile`（内核复制，不读 Lua）；
   哈希在 worker 线程内读一次（≤ `max_file_bytes`）后即释放，**不得把内容回传主进程**。
3. **物化不读内容**：`materialize_overlay` 对未 token 化的视图条目走 `copy_file` + 原子
   `rename`；只有被密钥 token 化的文本（`entry.tokenized`）才允许读出还原真实内容。
4. **发布按需读**：审批/发布时才从 blob 读（受单文件上限约束），读完即释放；大文件走
   `writer.apply_file` 复制。
5. **禁止以"方便"为由回退**：不要为了做三方合并、日志、UI 展示把整份内容塞进 `state.*`、
   `candidate.files`、证据或事件 payload；需要摘要就存哈希/大小/签名。
6. **宿主自身也要有上限**：常驻命令输出（`resident`）的块缓冲、未解析帧缓冲、服务器噪声
   都必须有硬上限（超限截断并终止命令）；`kernel/self_guard` 的 RSS 看门狗是最后一道
   保命线（soft 回收 → hard 中止当前回合），**不得**靠内核 OOM 兜底。
7. **沙箱存储是缓存**：全部位于 `stdpath("cache")/NeoAI/sandbox`；启动回收死进程实例
   （`instance.gc`），进程退出（`VimLeavePre`，非热重载）删除本进程实例目录
   （`sandbox.cleanup({phase="exit"})`）。

### 计划模式草稿（异步沙箱）

1. **草稿不是候选**：`tools.approval.mode="async"` 且沙箱隔离可用时，计划模式允许写类工具，
   但写入只进视图/暂存；`wrapper._settle_candidate` 在计划 scope 下直接走
   `sandbox/execution/plan_draft`：**不写候选 JSON、不入 review、强制 auto=false**。
2. **退出即丢弃**：`plan_mode.exit` / scope owner 的 `cleanup` / `sandbox.reset` 调
   `plan_draft.discard`；只撤销计划模式自身改动（登记视图签名比对），路径若原本有待审项则
   恢复旧待审内容，不得误删用户改动。
3. **能力上限**：草稿模式不是"全部工具"——`filter_capabilities` 按类别白名单 + 名称拒绝
   （SSH/长驻服务）+ MCP `plan_safe` + `extra_safe_tools` 显式放行；命令 tier≥2 在执行前拒绝。
4. **子 Agent 继承**：`runtime.spawn` 继承父 `_plan_scope_id`，子 Agent 写入同样是草稿；
   同 scope 丢弃。非 async/无隔离后端时退回只读白名单。
5. **Agent 对话规范**：子 Agent 用 `ask_user` 向上提问（不弹窗，转交主 Agent），主 Agent 统一用
   `send_sub_agent_message` 回复；有在途提问时 send 即回答，否则注入下一轮/续跑。

### 责任落点（改这些代码前先读本节）

- 视图/路径映射：`lua/NeoAI/sandbox/execution/view.lua`
- 暂存与候选：`lua/NeoAI/sandbox/execution/candidate.lua`
- 门禁与挂载：`lua/NeoAI/sandbox/execution/wrapper.lua`、`runtime.lua`、`resident.lua`
- 落盘：`lua/NeoAI/sandbox/execution/writer.lua`
- 崩溃回收：`lua/NeoAI/sandbox/execution/reclaim.lua`（`:NeoAI SandboxGC`）
- 计划模式草稿：`lua/NeoAI/sandbox/execution/plan_draft.lua`、`lua/NeoAI/tools/builtin/plan_mode.lua`
  （能力上限/提示词/scope）、`lua/NeoAI/core/agent/sub_agent.lua`（ask_user 转交与 send 对话）
- 回归：`lua/NeoAI/tests/test_sandbox_single_view.lua`（视图映射/轮换不迁移/零拷贝/预算/权限位/回收/JVM 代理）
  以及 `docs/sandbox.md` §2.2「单视图模型（三视图）」。
- 配置与文档：`default_config.lua` 的 `single_view`、`capture_max_bytes`、`capture_max_files`、
  `inline_candidate_bytes`、`generated_dirs`、`non_capture_paths`、`cleanup`、
  `network.java_proxy`；同步 `docs/configuration.md` 与英文版。

## 进程与任务隔离（崩溃不向上传导）

1. **总管理**：`kernel/supervisor.lua` 是子进程（后台 worker / 常驻沙箱命令服务器 / 后台服务）
   的唯一状态源与重启策略：`register` → 崩溃 `report_crash`（退避重启）→ 熔断（`failed` 并提示）
   → `:NeoAI Recover` 复位。新增子进程**必须登记**，禁止自建"无限重启循环"。子进程内存上限
   **按剩余内存动态刷新**（`memory_auto`，心跳周期重算并在线写 cgroup `memory.max`；收紧立即、
   放宽需 >20%），超限由内核回收子进程。
2. **任务分发**：`kernel/task_dispatch.lua` 双通道（interactive / background）+ 超时/重试/
   取消/排队上限；压力 warn 暂停后台通道、critical 拒绝新任务；失败一律以结构化错误返回
   （工具结果报错），**禁止**把异常抛回 nvim 主循环。
3. **失败语义**：子进程死亡 = 任务失败 + 自动重启（退避/熔断），**不是** nvim 崩溃。重活
   （捕获/冻结/哈希/编码/大文件 IO）必须在 worker 进程，主线程只做 UI 与状态机。
4. **自身看门狗**：`kernel/self_guard.lua` 只看本进程 RSS/Lua 堆；soft 回收可释放缓存 + GC；
   hard 回收后仍超限才经注册的 abort handler（`chat_service.abort_all`）中止当前回合并进入
   cooldown。绝不主动退出 nvim，探测不到 `/proc` 时视为 ok。
5. **崩溃恢复**：`core/session/recovery.lua` 干净退出标记（`state/alive-<pid>.json`）+ 启动
   检测 + 回收死进程沙箱存储 + 重开被中断会话（`:NeoAI Recover`）。**会话按轮落盘是恢复的
   前提**——任何改动不得破坏 `tool_loop` 轮末持久化（`set_round_persist`）。
6. **回归**：`test_supervisor.lua` / `test_task_dispatch.lua` / `test_self_guard.lua` /
   `test_crash_recovery.lua`；新增配置同步 `docs/configuration.md`（中英）。

## 代码风格

- 见 `styleGuide.md`（模块模板、命名、异步模式、事件约定）。
- 模块顶部写 `--- @module` 文档注释；公开函数写 `--- @param` / `--- @return`。
- 不引入新第三方依赖（仅用 Neovim 内置与 `utils/`）。

## 提交前检查

1. 新增/修改行为必须有测试覆盖（尤其插件协议、清理、替换、禁用、失败回滚）。
2. 运行完整回归，确保 `failed=0`。
3. 同步更新文档（`docs/plugins.md`、`docs/configuration.md`、`docs/testing.md`、README 及英文镜像）。
