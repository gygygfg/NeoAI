# NeoAI UI 系统（v3.0）

> UI 层负责窗口/组件/键位的编排。对所有窗口做纯文本渲染（禁用 LSP 挂载、禁用行号/符号列），
> 事件驱动流式更新，提供「折叠 + 悬浮窗」双重视图。
> 对应源码：`lua/NeoAI/ui/*`。

## 1. 模块结构

| 模块 | 职责 |
| --- | --- |
| `ui/init.lua` | UI 入口：初始化（注册审批/提问/子Agent监控 UI）、`open_default`/`open_chat`/`open_tree`/`close_all`、键位显示。 |
| `ui/window/manager.lua` | 窗口管理器：`float` / `tab` / `split` 三种模式创建/关闭/聚焦；禁用 LSP 挂载与行号/符号列。 |
| `ui/window/chat_view.lua` | 聊天视图：绑定事件、流式更新、折叠、悬浮窗调度、输入框联动、后台收起/恢复、显示模式宿主。 |
| `ui/window/tree_view.lua` | 会话树视图：分支树展示与 CRUD。 |
| `ui/components/*` | 可复用组件（见下）。 |
| `ui/keymap.lua` | 键位注册（`register_context`）与展示。 |

## 2. 窗口管理（manager.lua）

支持三种窗口模式（`ui.window_mode`）：`float` / `tab` / `split`。

- `create(window_type, opts)`：创建窗口，设置 `filetype`（`neoai`），命名 buffer（`NeoAI Chat` / `NeoAI Sessions`），
  触发 `WINDOW_OPENED`。
- **禁用 LSP**：`_disable_lsp` 把 buffer 设为 `buftype=nofile`、设 `b:copilot_disabled`/`b:copilot_disable`，
  并通过 `LspAttach` 兜底拦截（打 `b:neoai_ui` 标记），任何 LSP 客户端（含 Copilot）试图挂载时立即解绑。
- **统一窗口配置**：关闭 `number`/`relativenumber`/`signcolumn`/`foldcolumn`/`list`/`colorcolumn`/`spell`。

## 3. UI 初始化（ui/init.lua）

`M.init()` 幂等，注册三类 UI 实现：

- **审批 UI**：`ui/components/tool_approval.init()`（经 `tool_service.set_approval_ui` 注入）。
- **向用户提问 UI**：`ui/components/ask_user.init()`（经 `ask_user.set_ui` 注入）。
- **子 Agent 监控**：`ui/components/sub_agent_dock.init()`。

`open_default()` 按 `ui.default_view`（chat/tree）打开对应界面。

## 4. 聊天视图（chat_view.lua）

### 4.1 布局

主消息区（上，`expr` 折叠）+ 输入 split 窗（下，高度 3，`winfixheight`）。

### 4.2 事件订阅

聊天窗口打开时订阅：`MESSAGE_ADDED` / `MESSAGE_UPDATED` / `STREAM_CHUNK` / `TOOL_CALL_DETECTED` /
`TOOL_RESULT_RECEIVED` / `TOOL_EXECUTION_STARTED|COMPLETED|ERROR` / `REASONING_CHUNK` /
`REASONING_COMPLETED` / `TOOL_ARG_CHUNK` / `TOOL_ARG_COMPLETED` / `GENERATION_COMPLETED` /
`GENERATION_ERROR` / `AGENT_ABORTED`。

### 4.3 流式渲染合并

同一 tick 内多次分片/事件只渲染一次（`_schedule_render` 合并），避免逐片全量重渲染 + 折叠重算
卡住主线程。光标是否跟随（最后 5 行内）在调度时缓存：不跟随时不弹悬浮窗、不收起折叠，
并把重写前已展开的折叠块恢复，避免拽走用户正在查看的位置。

### 4.4 折叠

主窗口用 `expr` 折叠（`components.fold.foldexpr`），推理 / 每个工具调用块（调用+结果）各自独立成折叠。
折叠占位文本由 `components.fold` 统一提供。工具执行期间每秒重渲染一次（`TOOL_TICK_MS=1000`），
让折叠文本中的耗时实时跳动。

### 4.5 推理与工具参数悬浮窗

- **思考过程悬浮窗**（`reasoning_panel`）：`REASONING_CHUNK` 流式追加；正文开始/推理结束/生成结束自动关闭；
  同 tick 分片批量合并；光标不跟随时抑制弹出。
- **工具参数悬浮窗**（`tool_args_panel`）：`TOOL_ARG_CHUNK` 实时打开/更新，`TOOL_ARG_COMPLETED`/生成结束关闭；
  参数接收阶段先收起思考悬浮窗（避免两窗重叠）；批量冲刷 + 取消标记（`_cancel_pending_tool_args`）。

两者都：光标不跟随时不弹（`_cursor_within_follow_margin`）、`minimal` 浮窗、`foldenable=false`
（避免继承全局折叠把内容收起）。

### 4.6 输入框联动

主消息区（上）+ 输入 split（下，高度 3）。发送后切回主窗口并进入普通模式（生成期间可滚动浏览）；
主体与输入框共用一套 chat 上下文键位（`_build_chat_actions`）。`input_box` 用 `virt_text` 渲染 `> `
前缀（不用 `buftype=prompt`，避免与 nvim-cmp 冲突），并放开 `neoai_input` filetype 的补全。

### 4.7 后台收起 / 恢复

焦点追踪（`WinEnter`/`BufEnter`）判断当前窗口是否属于聊天界面（按显示的 buffer 而非窗口句柄）：
焦点离开（或主窗口被 `:bnext` 切到别的文件）时收起输入框（`_collapse_aux`），回到聊天时恢复
（`_restore_aux`，输入 buffer 内容保留）。

## 5. 显示模式（display_modes）

参照 deepseek-harness 的 Cordis 插件模型，把聊天界面的「显示模式」做成插件：

- 每个模式是一个独立 Lua 模块（`ui/components/display_modes/<name>.lua`，模块名 = 模式名），自行注册。
- 插件接口：`{ name, label, desc, load?(host), unload?(host), render?(buf, messages) }`。
- host 由 `chat_view.open` 注入：提供 `get_buf` / `get_messages` / `set_foldexpr` / `set_foldtext` / `refresh`。
- **切换模式** = 卸载当前插件（`unload`）→ 加载目标插件（`load`），即热插拔。`activate(name, {force})`。
- **热重载**：`reload(name)` 清除 require 缓存后重新加载模块（无需重启界面让插件改动生效）。
- 内置模式：`chat`（对话）与 `trajectory`（轨迹）。切换触发 `DISPLAY_MODE_CHANGED`。

## 6. 组件清单

| 组件 | 职责 |
| --- | --- |
| `input_box` | 聊天输入框。`create`/`attach_window`/`focus`/`submit`/`on_submitted`/`clear`；`virt_text` 渲染 `>` 前缀；放开 `neoai_input` 文件类型补全。 |
| `message_list` | 消息列表渲染。`render(buf, messages)`；`toggle_reasoning()`。 |
| `float_stream_window` | 复用流式悬浮窗。`open(title,{filetype})`/`set_text`/`append`/`get_text`/`close`/`is_open`/`reset`；思考过程 / 接收参数 / 上下文压缩 / 计划蒸馏共享同一窗口。 |
| `reasoning_panel` | 思考过程悬浮窗（`float_stream_window` 适配器）。`open`/`show`/`append`/`close`/`is_open`；`filetype=neoai_reasoning`。 |
| `tool_args_panel` | 工具参数接收悬浮窗（`float_stream_window` 适配器，流式工具调用参数）。`open`/`show`/`close`/`is_open`/`get_content`/`reset`；`filetype=neoai_tool_args`。 |
| `model_picker` | 模型选择器（异步加载模型列表）。`open(callback)`。 |
| `tool_approval` | 工具审批弹窗。`init()`；串行单槽位展示。 |
| `ask_user` | 向用户提问弹窗。`init()`；经 `ask_user.set_ui` 注入。 |
| `sub_agent_dock` | 子 Agent 状态监控。`init()`。 |
| `fold` | 折叠（推理/工具调用/结果共用实现）。`foldexpr`/`foldtext`/`record_start`/`record_end`/`has_running`/`set_live_timer`/`set_foldexpr_override`/`set_foldtext_override`。 |
| `display_modes/` | 显示模式插件管理器 + `chat.lua`/`trajectory.lua`。 |
| `markdown_view` | Markdown 渲染器。 |

## 7. 键位（ui/keymap.lua）

`keymap.register_context("chat", actions, buf)` 把一段 action handler 映射到指定 buffer。主界面与
输入框共用同一份 chat 上下文键位（排除 send/insert，在输入框内单独绑定）。`show_keymaps()` 展示
当前键位配置。

聊天上下文键位（`keymaps.chat`）：`insert`(i)、`quit`(q)、`send`、`cancel`(<Esc>)、`toggle_reasoning`(r)、
`switch_model`(M)、`cycle_mode`(m)、`cycle_display`(<C-t>/T)、`reload_display`(<F5>)、`approve_plan`(P)、
`tool_approval`(<C-a>)、`approval.confirm/confirm_all/cancel/cancel_with_reason`。

## 8. 相关文档

- [configuration.md](configuration.md)：`ui.*` / `keymaps.*` 配置。
- [EVENTS.md](EVENTS.md)：UI 事件（`WINDOW_*`、`DISPLAY_MODE_CHANGED` 等）。
- [chat_enhanced_usage.md](chat_enhanced_usage.md)：聊天界面使用指南。
