# 给 Herdr 上游：新增原生 `neoai` 集成 target

> 状态：**提案（草案）**。本文件描述如何让 Herdr 原生支持
> `herdr integration install neoai`。文件/符号名依据已装二进制的可观测事实
> （CLI `--help`、`herdr::*` 符号、`herdr --default-config`）推断，落地前请对照
> Herdr 源码树核对确切路径与命名。

## 背景

- `herdr integration install <TARGET>` 的 `<TARGET>` 是**编译期固定枚举**：
  `pi, omp, claude, codex, copilot, devin, droid, kimi, opencode, kilo, hermes,
  qodercli, cursor, mastracode, antigravity-cli, grok`。
- `herdr integration status` 会为每个 target 打印其「安装落点」，例如
  `claude → ~/.claude/hooks/herdr-agent-state.sh`、`opencode → ~/.config/opencode/plugins/herdr-agent-state.js`。
  可见每个 target = 「把一份 hook 文件写到某 agent 的约定位置」+ 该 agent 在生命周期事件时调用它。
- NeoAI（Neovim 插件）**自身就会上报**（`herdr pane report-agent` / `pane report-metadata`），
  不依赖外部 hook 才能工作。因此 `neoai` target 的价值主要是：
  1. 让 `integration status/install` 能发现并引导 NeoAI 用户；
  2. 可选地把「上报」接入非插件场景（见 `../herdr-agent-state.sh`）。

## 需要改动的点（对照源码核对）

1. **IntegrationTarget 枚举**：在定义 `pi/omp/claude/…` 的位置新增 `Neoai`。
   - 观测符号：`herdr::integration::targets`、`IntegrationInstallParams`。
   - 同步 `IntegrationInstallParams` / `IntegrationUninstallParams` / `IntegrationInstallResult` 的 serde 与
     CLI 解析（`possible values:` 列表由该枚举生成）。
   - CLI 名称：`neoai`（kebab/lowercase，与其它 target 一致）。

2. **canonical id**：与 `cjk_ime_agents` / 检测枚举里的命名对齐。若同时提供 bundled 检测清单，
   需在检测用的 agent 枚举（观测：`herdr::detect::Agent`，值含 `piclaudecodex…`）加入 `Neoai`。
   否则仅作为「上报型」target，不需要进入检测枚举。

3. **install 逻辑**：新增 `install_neoai`，参考现有 `install_pi`（观测符号/文件名
   `install_pi`、`herdr-agent-state.ts`）。
   - 详见 [`install_neoai.rs.txt`](install_neoai.rs.txt)。

4. **路径探测函数**：把 NeoAI 的约定落点加入各平台路径解析（观测：`home_dir`、
   `XDG_CONFIG_HOME`、`PI_CONFIG_DIR`、`.claude` … 这类按 agent 分派的常量表）。

5. **status/version**：`herdr integration status` 需能识别已安装版本（观测：
   `HERDR_INTEGRATION_ID`、`HERDR_INTEGRATION_VERSION` 注入 + 文件内注释标记）。

6. **测试**：仿现有 integration 测试，覆盖：安装幂等、版本识别、卸载、路径解析（临时 HOME/XDG）。

## 建议的 target 语义（二选一）

- **A. 纯发现型**：`install_neoai` 只打印「NeoAI 无需安装，插件会自动上报」并把
  `config.snippet.toml` 的展示增强片段落到 `~/.config/herdr/config.toml`（带 marker）。
- **B. 落脚本型**：把 `herdr-agent-state.sh` 安装到约定目录，供非 Neovim 场景复用
  （与 `claude`/`codex` 等的 `herdr-agent-state.sh` 形态一致）。

推荐 **A**：NeoAI 上报内建，无需 hook；Herdr 侧只需「可发现 + 可选展示增强」。

## 落点建议（与 NeoAI 仓库协同）

- NeoAI 仓库已提供：`integrations/herdr/herdr-agent-state.sh`、`integrations/herdr/config.snippet.toml`。
- Herdr 侧安装时可从 NeoAI 仓库/发布物获取这两个文件，或内嵌等价内容。
