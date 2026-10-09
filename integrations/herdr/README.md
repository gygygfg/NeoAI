# NeoAI ⇄ Herdr 集成

让 [Herdr](https://herdr.dev)（AI 编码代理的终端工作区管理器）**识别 NeoAI 的 Agent 生命周期**
（`working` / `idle` / `blocked`），从而在 Herdr 侧边栏/边框实时反映 NeoAI 的真实作态，
而不是靠屏幕输出启发式猜测。

## 工作原理（已实测）

Herdr 识别 agent 有两条途径：

1. **屏幕检测**——Herdr 用内建/远程「agent 检测清单」+ 进程名匹配，识别 *编译期已知* 的 agent
   （`claude` / `codex` / `opencode` / `pi` …）。**agent 身份是编译进二进制的固定集合，无法由外部新增。**
2. **主动上报**——pane 内的程序通过 `herdr pane report-agent` 直接把生命周期状态告诉 Herdr。
   **这条路径不要求 agent 先被检测**，是外部 agent 接入的正道。

NeoAI 走的是第 2 条：Neovim 插件内的
[`NeoAI.services.herder`](../../lua/NeoAI/services/herder.lua) 把多会话（含子 Agent）聚合为
pane 级状态（`blocked > working > idle`），带严格递增 `--seq` 上报；并在接管权威时附带一次
`report-metadata`（`--display-agent NeoAI` + 中文状态文案），让 Herdr 侧边栏显示 **NeoAI** 而非裸 `neoai` 标签。

### 为什么没有「检测清单（manifest）」

Herdr 支持本地清单覆盖：`~/.config/herdr/agent-detection/<id>.toml`。实测结论：

| 操作 | 结果 |
|---|---|
| 覆盖**已有** agent（如 `pi`） | ✅ 生效（`source_kind="local override"`，`local_override_shadowing_remote=true`） |
| **新增** agent（`neoai`） | ❌ 被忽略（`neoai` 不进清单；`herdr agent explain --file … --agent neoai` → `unknown_agent`） |

因此本仓库**不提供** `neoai` 检测清单（对新增 agent 无效）。真正生效的是上面第 2 条上报路径。
若希望 Herdr 原生支持 `herdr integration install neoai`，需要 Herdr 上游新增 target——见
[`upstream/`](upstream/)。

## 无需安装即可工作

只要满足：**① 运行在 Herdr pane 内**（`HERDR_ENV=1`、`HERDR_PANE_ID` 存在）；
**② `herder.enabled = true`（默认开）**——NeoAI 就会自动上报，**无需任何 Herdr 侧安装**。

## 可选：显示增强片段

`config.snippet.toml` 是可选的 Herdr 配置片段：在 `[ui]` 下开启
`show_agent_labels_on_pane_borders`，让分屏边框显示上报的 agent 标签（如 NeoAI）。
它**不影响**生命周期识别，仅影响展示。

**默认自动安装**：NeoAI 启动时若处于 Herder 环境，会**异步、静默、幂等**地把该片段写入
`~/.config/herdr/config.toml`（marker 幂等、写入前备份、`herdr config check` 校验失败自动回滚、
已安装则跳过）。可用 `herder.auto_install = false` 关闭。

也可手动控制：

- **手动**：把 `config.snippet.toml` 内容追加到 `~/.config/herdr/config.toml`，然后
  `herdr server reload-config`。
- **从 Neovim**（带 marker 幂等、写入前备份、写入后 `herdr config check` 校验、失败自动回滚）：

  ```vim
  :NeoAIHerderConfig           " 预览片段
  :NeoAIHerderConfig install   " 追加到 config.toml
  :NeoAIHerderConfig uninstall " 移除 NeoAI 写入的片段
  :NeoAIHerderStatus           " 查看集成状态
  ```

## 独立上报脚本

`herdr-agent-state.sh` 是**非 Neovim 上下文**（启动器/包装脚本/其它编辑器）可用的薄封装，
复用同一上报协议：

```sh
# 在 Herdr pane 内
./herdr-agent-state.sh --state working --display-agent NeoAI --seq 1
./herdr-agent-state.sh --state blocked  --seq 2
./herdr-agent-state.sh --state idle     --seq 3
./herdr-agent-state.sh --release        --seq 4
```

非 Herdr 环境（`HERDR_ENV != 1`）下为 no-op（退出码 0）。

## 诊断

在 Herdr pane 内：

```sh
herdr agent list                 # 应出现 agent=neoai 及其 agent_status
herdr pane get "$HERDR_PANE_ID"  # 查看 display_agent / state_labels
herdr agent explain "$HERDR_PANE_ID"   # 若为上报型 agent 会提示无检测标签
herdr --skill                    # Herdr 自身的 agent 集成技能说明
```

## 文件

| 文件 | 说明 |
|---|---|
| `herdr-agent-state.sh` | 独立上报脚本（report-agent / report-metadata / release-agent 封装） |
| `config.snippet.toml` | 可选的 Herdr 侧边栏展示增强片段 |
| `upstream/TARGET.md` | 给 Herdr 上游的「原生 NeoAI target」接入说明 |
| `upstream/install_neoai.rs.txt` | `install_neoai` 安装逻辑的 Rust 骨架（可照 `install_pi` 改写） |

## 相关

- 配置项：`README.md` 的「Herder 终端状态集成」章节、[`docs/configuration.md`](../../docs/configuration.md) 2.6 `herder`。
- 服务实现：[`lua/NeoAI/services/herder.lua`](../../lua/NeoAI/services/herder.lua)（上报）、
  [`lua/NeoAI/services/herder_install.lua`](../../lua/NeoAI/services/herder_install.lua)（配置片段安装器）。
