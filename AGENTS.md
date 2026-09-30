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
# 运行全部内置测试（并行，多 worker 隔离子进程，输出 SUMMARY passed/failed）
# 可选环境变量 NEOAI_TEST_WORKERS 覆盖 worker 数（默认 min(nproc, 8)）
nvim --headless --clean -u NONE --cmd "set rtp+=$PWD" \
  --cmd "lua require('NeoAI').setup({ log={level='ERROR'}, session={auto_save=false} })" \
  -c "lua local r=require('NeoAI.tests.parallel').run(); print('SUMMARY passed='..r.passed..' failed='..r.failed); vim.cmd(r.failed>0 and 'cquit 1' or 'qa!')"

# 顺序运行（调试单套件）：run_all("plugins") / run_all("kernel","services")
nvim --headless --clean -u NONE --cmd "set rtp+=$PWD" \
  --cmd "lua require('NeoAI').setup({ log={level='ERROR'}, session={auto_save=false} })" \
  -c "lua local r=require('NeoAI.tests').run_all(); print('SUMMARY passed='..r.passed..' failed='..r.failed); vim.cmd('qa!')"
```

- 测试框架：`lua/NeoAI/tests/init.lua`，套件文件 `lua/NeoAI/tests/test_*.lua`，运行器自动加载。
- 并行运行器：`lua/NeoAI/tests/parallel.lua`，按「文件（套件）」分片到多个隔离 headless
  子进程；权重优先用实测耗时缓存 `.neoai_test_timings.json`（gitignored），无缓存按用例数。
  文件级分片保证固定端口（各文件唯一）与文件内固定临时路径不跨 worker 冲突；子进程注入独立
  `mcp.cache_path`。资源重/时序敏感套件（`sandbox*`、`pty`）自动走**串行通道**，避免并发下
  bwrap/cgroup 争抢导致 137/SIGKILL 与 PTY 时序 flaky。
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
7. `NeoAIReloadAll` / `reload_all` 必须先 `plugins.stop_all()` 再清缓存重载。
8. **懒加载启动（默认，无配置）**：`NeoAI.setup()` 只登记插件并注册命令/键位占位符，**不启动**；
   首次触发经 `NeoAI.ensure_phase1/ensure_started` 两阶段异步启动（阶段 1 UI 就绪即打开界面，
   阶段 2 后台按帧加载；见 `plugins/builtin/lazy.lua`、`kernel/plugins.start_list_async`）。
   新增副作用插件时须标注 `phase`（`catalog.lua`）；只读访问器不得触发启动。
   测试/热重载用 `ensure_started_sync()` 同步等待全量启动。
9. **工具执行必须过沙箱**：所有工具经 `services.sandbox` 门禁（`tools/executor` 强制，
   `tools/registry`/加载器附加 `__sandbox_spec`）。沙箱服务缺失且 `fail_closed` 时拒绝执行，
   不得绕过或静默降级。默认异步审批（`tools.approval.mode="async"`）：效果类工具立即在沙箱内
   执行并冻结候选，真实修改进入待审队列，用户经 `:NeoAISandboxReview` 异步确认后应用。
   详见 `docs/sandbox.md`。

## 代码风格

- 见 `styleGuide.md`（模块模板、命名、异步模式、事件约定）。
- 模块顶部写 `--- @module` 文档注释；公开函数写 `--- @param` / `--- @return`。
- 不引入新第三方依赖（仅用 Neovim 内置与 `utils/`）。

## 提交前检查

1. 新增/修改行为必须有测试覆盖（尤其插件协议、清理、替换、禁用、失败回滚）。
2. 运行完整回归，确保 `failed=0`。
3. 同步更新文档（`docs/plugins.md`、`docs/configuration.md`、`docs/testing.md`、README 及英文镜像）。
