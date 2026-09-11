# NeoAI 聊天界面使用指南（v3.0）

> 本文档描述 v3.0 聊天界面的实际使用。旧版提到的 `NeoAI.ui.chat_enhanced` 模块、
> `:NeoAISend` / `:NeoAIMode` / `:NeoAIDemo` / `:NeoAIList` 命令均**不存在**。
> 对应源码：`lua/NeoAI/ui/window/chat_view.lua`、`lua/NeoAI/ui/components/*`。

## 1. 打开聊天

```vim
:NeoAIChat        " 直接打开聊天界面
:NeoAIOpen        " 打开默认界面（按 ui.default_view，chat/tree）
```

或在 Neovim 配置中绑定快捷键（`keymaps.global`，默认 `<leader>ac`）。

## 2. 界面布局

聊天窗口 = **主消息区（上）** + **输入框（下，split，高度 3）**。

- 主消息区：`expr` 折叠（推理 / 每个工具调用块 / 工具结果各自独立成折叠），`foldenable` 显式开启。
  光标贴近底部（最后 5 行内）时流式输出自动跟随；`j`/`k` 与鼠标滚轮走同一滚动逻辑
  （`_scroll`，光标被钳制在 `[1, 行数]`），滚到 buffer 末尾即止，不会越过末行在下方留白。
- 输入框：普通 buffer + `virt_text` 渲染 `> ` 前缀（不用 `buftype=prompt`，避免与 nvim-cmp 冲突）；
  放开 `neoai_input` filetype 的补全。

## 3. 基本交互

| 操作 | 键 | 说明 |
| --- | --- | --- |
| 发送 | 插入模式 `<C-s>` / 普通模式 `<CR>` | 多行输入：插入模式回车换行（不发送） |
| 取消生成 | `<Esc>` | 通过 AbortSignal 取消（正常停止，非错误） |
| 进入插入 | `i` / `a` | 普通模式 |
| 关闭窗口 | `q` | |
| 切换思考显示 | `r` | `message_list.toggle_reasoning` |
| 切换模型 | `M` | 弹出模型选择器 |
| 循环模式 | `m` | CHAT → PLAN → AUTO |
| 循环显示模式 | `<C-t>`（插入）/ `T`（普通） | chat / trajectory |
| 热重载显示模式 | `<F5>` | 重载当前显示模式插件 |
| 确认计划 | — | 由 AI 调用 `exit_plan_mode`（弹审批窗口确认）或执行 `:NeoAIApprovePlan` |
| 工具审批 | `<C-a>` | 审批弹窗内确认 |
| 滚动 | `j` / `k` / 鼠标滚轮 | 光标移动式滚动（不越过 buffer 末尾） |

## 4. 流式更新与悬浮窗

- **正文流式**：实时增量显示，同一 tick 内多次分片合并为一次渲染（避免主线程卡顿）。
- **思考过程悬浮窗**（`reasoning_panel`）：`REASONING_CHUNK` 时实时追加；正文开始/推理结束/生成结束自动关闭。
- **工具参数接收悬浮窗**（`tool_args_panel`）：模型流式生成工具调用参数时实时打开「接收参数」窗口，
  随分片**增量追加**（单个工具调用时逐片 append 原始参数，与思考过程悬浮窗一致，避免整段重排），
  `TOOL_ARG_COMPLETED` 时关闭。窗口高度按**显示行数**（含 wrap 折行）自适应，并始终自动滚到内容末尾。
- 各悬浮窗共享 `float_stream_window`：窗口高度随内容增长（至多到上限），开启 `smoothscroll`，
  长单行也能滚到尾部；写入后先增高再滚动、并把光标移到内容末尾（末行末列）后 `zb` 贴底。
- 光标处于消息区最后 5 行内才自动跟随滚动并弹悬浮窗；回看上方内容时不打扰。

## 5. 折叠（components/fold）

推理 / 每个工具调用块（调用 + 结果）各自独立成折叠，块与块之间无需分隔行。折叠占位文本统一由
`components.fold` 提供。工具执行期间每秒重渲染一次，让折叠文本中的**耗时**实时跳动
（基于可暂停计时器 `utils.timer` 的活跃耗时，剔除审批/提问等待时间）。

展开/折叠：`zM`（全部收起）/ `zo`（展开）/ `zR`（全部展开）。

## 6. 计划模式（PLAN）

`m` 或 `:NeoAIPlan` 切换计划模式：

- 工具上下文只保留**只读/信息查询工具 + `ask_user` + `exit_plan_mode`**，不暴露任何修改类工具。
- 执行期门禁同步收紧，调用可见集之外的工具会被驳回。
- AI 在计划模式下调研、提问澄清，输出**清晰、格式化的修改计划**。
- 计划完成后 AI 调用 `exit_plan_mode`（弹出审批窗口由用户确认；也可执行 `:NeoAIApprovePlan`），
  确认后转入 CHAT 模式，把计划解析为任务清单（todo）并自动执行。
- 生成过程中切换模式（`m` / `:NeoAIPlan` / `:NeoAIAuto`）会延迟到当前回合结束后生效，
  不打断正在进行的生成。

## 7. AUTO 模式

`:NeoAIAuto` 或 `m` 循环到 AUTO 模式：自动允许所有工具调用（运行期开关），开启时立即批准当前
待审批/排队的工具。**生成/工具执行过程中**切到 AUTO 也会**立即生效**（审批放宽与工具集/模型
变更解耦），不会等到本轮结束——避免「切了 AUTO 本轮还在弹审批框」；离开 AUTO 与其它模式切换
仍延迟到本轮结束，避免中途打断当前回合。

## 8. 向用户提问（ask_user）

AI 在生成过程中可通过 `ask_user` 暂停并向用户提问，等待回答。提问弹窗（`ui/components/ask_user`）
支持选项快速选择；回答作为工具结果回传给 AI。未注册 UI 时回退到 `vim.ui.input`。

## 9. 相关文档

- [configuration.md](configuration.md)：`ui.*` / `keymaps.*` 配置。
- [ui_system.md](ui_system.md)：`chat_view` 内部实现。
- [ai_engine.md](ai_engine.md)：生成/工具循环/计划模式。
