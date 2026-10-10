# NeoAI UI 系统（v3.0）

> [English](en/ui_system.md) | **中文**

> UI 层负责窗口/组件/键位的编排。对所有窗口做纯文本渲染（禁用 LSP 挂载、禁用行号/符号列），
> 事件驱动流式更新，提供「折叠 + 悬浮窗」双重视图。
> 对应源码：`lua/NeoAI/ui/*`。

## 1. 模块结构

| 模块 | 职责 |
| --- | --- |
| `ui/init.lua` | UI 入口：初始化（注册审批/提问/子Agent监控 UI）、`open_default`/`open_chat`/`open_tree`/`close_all`、键位显示。 |
| `ui/window/manager.lua` | 窗口管理器：`float` / `tab` / `split` 三种模式创建/关闭/聚焦；禁用 LSP 挂载与行号/符号列。 |
| `ui/window/chat_view.lua` | 聊天视图（**支持多实例**，见 §4.0）：绑定事件、流式更新、折叠、悬浮窗调度、输入框联动、后台收起/恢复、显示模式宿主。 |
| `ui/window/tree_view.lua` | 会话树视图：分支树展示与 CRUD。 |
| `ui/components/*` | 可复用组件（见下）。 |
| `ui/geometry.lua` | 浮窗几何计算：按屏幕**相对比例**推导浮窗宽高与居中/贴边位置，避免硬编码像素尺寸。`compute{ w_ratio, h_ratio, fit_h, min_w, max_w, min_h, max_h, margin, anchor, row, narrow }` → `{ width, height, col, row }`。内置全局最小尺寸兜底（`ui.float.min_width/min_height`，默认 24/4），并提供 `track/untrack/refresh/reset`：已登记的浮窗在编辑器窗口 resize（`VimResized`）时实时重算尺寸与位置跟随（流式窗可用自定义 `apply` 保留内容自适应高度）。另支持**窄屏留白**（见 §2.1）。 |
| `ui/session_cleanup.lua` | 会话恢复残留清理：`:restart`/`-S` 后清掉界面孤儿 buffer（见 §4.9）。 |
| `ui/keymap.lua` | 键位注册（`register_context`）与展示。 |

## 2. 窗口管理（manager.lua）

支持三种窗口模式（`ui.window_mode`）：`float` / `tab` / `split`。

- `create(window_type, opts)`：创建窗口，设置 `filetype`（`neoai`），命名 buffer（`NeoAI Chat` / `NeoAI Sessions`），
  触发 `WINDOW_OPENED`。（输入框 buffer 由 `input_box` 命名为 `NeoAI Input`。）
- `cleanup_session_orphans()`：清理 `:restart` / `-S` 会话恢复带入的**界面孤儿 buffer**（详见 §4.9）。
- **禁用 LSP**：`_disable_lsp` 把 buffer 设为 `buftype=nofile`、设 `b:copilot_disabled`/`b:copilot_disable`，
  并通过 `LspAttach` 兜底拦截（打 `b:neoai_ui` 标记），任何 LSP 客户端（含 Copilot）试图挂载时立即解绑。
- **统一窗口配置**：关闭 `number`/`relativenumber`/`signcolumn`/`foldcolumn`/`list`/`colorcolumn`/`spell`。

### 2.1 浮窗窄屏留白（geometry.lua）

浮窗默认按整屏比例居中，窗口较窄时会显得贴边、左右比例失衡。为此 `geometry` 引入**基准窗口**
（`set_narrow_base(win)` / `clear_narrow_base()`，由 `chat_view` 在 open/close 登记/清除聊天主窗口）。
`compute` 依基准窗口宽度 `base_w`（屏幕坐标左列 `base_col`）分档（阈值/留白先硬编码）：

| 基准窗口宽度 | 浮窗宽度 | 浮窗左列 |
| --- | --- | --- |
| `< 40` | `base_w`（左右占满窗口） | `base_col` |
| `40 ≤ base_w < 100` | `base_w - 10`（左右各留 5 格） | `base_col + 5` |
| `≥ 100` | 维持现状：`floor(cols * w_ratio)` 居中 | 相对**屏幕**居中 |

- 仅当存在有效基准窗口且 `base_w < 100` 时生效；否则维持原「相对屏幕」逻辑（无回归）。
- 窄屏两档**跳过全局 `min_w`**（否则 `base_w-10` 可能被抬超基准窗口），仍受 `max_w` 与
  `base_w` 约束，并把 `col` 钳到窗口/屏幕范围内。
- `compute` 新增 `opts.narrow`（默认 true）；NeoAI 主界面窗口（`manager._open_float` 的 chat/tree）
  传 `narrow = false`，不受该规则影响。
- `refresh()`（`VimResized`）重算时会重新解析基准窗口宽度，实时跟随。
- 各浮窗组件（流式窗/推理面板/审批/提问/模型选择/网络同意/密钥告警/子 Agent 坞/终端/轨迹弹窗等）
  经 `geometry.compute` 统一生效，无需逐个改动。

## 3. UI 初始化（ui/init.lua）

`M.init()` 幂等，注册三类 UI 实现：

- **审批 UI**：`ui/components/tool_approval.init()`（经 `tool_service.set_approval_ui` 注入）。
- **向用户提问 UI**：`ui/components/ask_user.init()`（经 `ask_user.set_ui` 注入）。
- **子 Agent 监控**：`ui/components/sub_agent_dock.init()`。

`open_default()` 按 `ui.default_view`（chat/tree）打开对应界面。

## 4. 聊天视图（chat_view.lua）

### 4.0 多聊天实例

同一 nvim 内可并存**多个独立聊天实例**：`<leader>ac` / `:NeoAIChat` 每次在**新标签页**开一个
新实例，使用唯一 buffer 名（`NeoAI Chat`、`NeoAI Chat 2`…；输入框 `NeoAI Input`、`NeoAI Input 2`…），
旧实例**保留并继续运行**（各自事件订阅/会话/流式输出），互不顶替、不共享名称。

实现：`chat_view.lua` 的整个函数体是一个**闭包工厂** `_make_instance()`（工厂内的 `M` 是**实例 API**，
既有 `M.xxx` 自引用天然指向实例）；文件末尾的模块表是**实例管理器**：

- `open(opts)`：默认复用**当前聚焦**实例；`opts.new_window=true` 时新建实例（新标签页）。
- `open_new(opts)`：直接新建实例（分配唯一 id 与唯一 buffer 名）。
- `close()` / `close_all()`：关闭当前实例 / 全部实例。
- `has_window()`：任一实例存活即为真；`refresh`/`flush`/`set_display` 等透传方法作用于当前实例。
- **焦点路由** `_note_focus(id)`：`WinEnter`/`BufEnter` 命中某实例窗口时，登记
  `input_box._set_current(inst)`、`geometry.set_narrow_base(win)`、`display_modes.attach(host)`，
  并 `chat_service.set_current_agent(agent_id)`，使既有 `get_current_agent()` / 状态栏 / 审批
  自动落到聚焦实例。
- `input_box.lua` 同法工厂化；模块表是「当前输入框」代理（无实例时惰性建默认实例，
  兼容不涉及多实例的既有调用与单测）。关联单体（`reasoning_panel`/`tool_args_panel`/
  `float_stream_window`/`display_modes`/`geometry` 基准）为**共享单例**，只服务当前聚焦实例。
- **跳转到别的实例（路由）**：主窗口里 `:b`/`:bnext` 落到**另一实例**的聊天 buffer（或其输入
  buffer）时，不把该 buffer 就地显示在残缺界面里，而是**路由到那个实例**——切到它的标签页、聚焦
  其输入框，并把本窗口回退到自己的聊天 buffer（`_inst_by_buf` / `_route_to_inst`，带 `_routing`
  重入守卫）。输入框内敲 `:b <某聊天 buffer>` 同样先按此路由（`_resolve_target_inst`），**不再**
  走「新标签页重放」——后者会产出「只有聊天内容、没有输入框」的裸标签页（多实例回归）。
- **每实例独立流式浮窗**：`float_stream_window` / `reasoning_panel` / `tool_args_panel` 均已
  工厂化（`.new()`）；chat_view 在每个实例内建一套（三者共享该实例的一个浮动窗口，互斥复用），
  各实例的思考/接收参数/上下文压缩浮窗**互不干扰**（关闭一个不影响另一个）。`tool_args_panel`
  的增量进度 `seen` 亦为每实例独立。模块表是「当前」代理（缺省惰性建一个默认实例），
  `_on_focus` 同步其 current；关闭实例**总是**关掉其自身浮窗（避免泄漏）。
- **推理显示开关按 buffer 独立**：`message_list` 的 `show_reasoning` 由全局改为
  `state.show_by_buf[buf]`（缺省回退 `default_show`）；`toggle/is/set_show_reasoning` 接可选
  `buf`，渲染按目标 buffer 解析，`trajectory` 显示模式按 host buffer 读取。一个实例切换推理
  显示不影响别的实例。
- augroup 名按实例唯一（`NeoAIChatFocus_<id>` / `NeoAIChatResize_<id>` / `NeoAIInputHeight_<id>`），
  避免多实例互相 `clear`。
- **渲染取数按实例 Agent**：`chat_view` 一切「取消息 / 是否仍有工作」的读取都走
  `chat_service.get_messages_for_agent(state.agent_id)` / `has_pending_work_for_agent(state.agent_id)`，
  **绝不**用全局 `get_messages()` / `has_pending_work()`（那取的是聚焦实例）。否则后台实例收到自身
  流式事件后会读到聚焦实例的消息、把自己的 buffer 覆盖成别人的内容，表现为「chat 界面无法更新
  buffer」。相应新增 `pending_count_for_agent` / `get_agent_for_buffer`（供 `trajectory` 的 `:w`
  按 buffer 绑定的实例保存会话）。
- 保护复用语义：`reload_all` / 树选会话 / `toggle_ui` 走默认 `open()`（复用当前实例，不新建）。

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

### 4.3.1 增量刷新（避免整 buffer 重写）

普通刷新（流式分片、事件驱动的重渲染、工具耗时 tick、窗口宽度变化等）**不再整 buffer 重写**，
而走增量路径：

- `components.incremental` 按「块 key + 签名」缓存每条消息（对话模式）或每个 turn（轨迹模式）
  的渲染结果。签名覆盖所有影响渲染的输入（role/content/reasoning/tool_calls/duration_ms、
  折叠块状态 `fold.get_status`、`streaming`/`table_width` 等）；签名未变的块直接复用，
  只有变化的块会重新渲染。**对话模式下执行中工具的实时耗时不计入签名**（每秒变化会命中缓存失效→
  重建整块，大消息时占主线程）：`message_list.refresh_tool_times` 仅就地改写首行耗时，
  块其余内容复用缓存；状态变化（running→success）仍触发整块重建以锁定总耗时。
- 拼接出的行与上次写入内容做最长公共前缀/后缀差分（`incremental.diff_range`），只把**变化的
  行区间** `nvim_buf_set_lines` 写回；内容完全一致时**完全不触碰 buffer**（`changed=false`），
  连带跳过 `zx`/`zM` 折叠重算与滚动。表格高亮也只在差异区间内重贴。
- 因此流式输出时每片只改写末尾若干行，历史消息所在的前缀区域零开销；`chat_view._render` 依据
  返回的 diff 决定是否重算折叠与滚动。

缓存失效（`incremental.invalidate`）：会话切换、上下文压缩 / 计划蒸馏重排历史、
切换显示模式、窗口宽度变化（表格重排）时清空镜像，下一次渲染回退到全量替换，避免基于旧行位置
做差分写入。旧行为可通过 `ui.chat.incremental = false` 降级回整 buffer 全量重写。

### 4.4 折叠

主窗口用 `expr` 折叠（`components.fold.foldexpr`），推理 / 每个工具调用块（调用+结果）各自独立成折叠。
折叠块内**每行必为单行**（`_append_fold_block` 会把含真实换行的内容按行拆开）：流式未完成/非法的
工具参数可能含真实换行，若原样作为一行写入，`nvim_buf_set_lines` 会报错并使 buffer 半写、把一个
工具折叠拆成两段。
折叠占位文本由 `components.fold` 统一提供。**只有被渲染层显式登记为推理块的折叠才显示
「🤔 思考过程 N 行」**（`message_list` 写入 buffer 后登记推理块起始行），工具块显示 `🔧 工具名`，
其余未识别折叠显示中性占位（`📄 首行预览 (N 行)`），避免「所有折叠都渲染成思考过程」。
工具块首行与**已登记的推理块起始行**都会返回 `>1` 强制开启新折叠：AI 不输出正文时，同一轮次内
下一条 assistant 的推理行会紧接上一工具块的结果行、且同处缩进层级，若不强制断折会被并入上一
工具块（表现为「思考过程被收进工具调用折叠里面」）。
工具执行期间每秒刷新一次（`TOOL_TICK_MS=1000`），让折叠文本中的耗时实时跳动；刷新只就地
改写工具首行（见 4.3.1）。是否跳过 `foldclose!` 以**渲染前**已展开的折叠为准（`open_folds`）：
命中则跳过（否则先收起再 `zo` 重开会让用户正在查看的块闪烁）；未命中（含收起的折叠）一律
执行 `foldclose!`。**不能**用写入后的 `foldclosed` 判定——改写行本身会让折叠短暂呈现为
「展开」，据此跳过会让原本收起的块持续露出内容（表现为内容被刷到折叠外又回去）。
就地改写折叠首行还会触发 nvim 增量折叠更新的缺陷：折叠结束行被截断，内容泄漏到折叠外。
只要写入区间命中折叠首行就重新赋值 `foldexpr` 强制整段折叠重算以修正边界。识别首行**不能只看
`foldlevel` 上升**：相邻工具折叠同为 level 1，前一行仍是上一折叠的 level 1，级别并不上升；需结合
「闭合折叠首行」（`foldclosed(ln)==ln`）与工具块首行文本兜底。且结构性变化（如某工具完成追加结果
行）可能与就地刷新**同批写入**，故不能只在 `inserted==removed` 时判定，否则同批中仍在执行工具的
折叠会漏修（表现为内容一行行露在折叠外）。

**插入模式折叠抑制与补算**：只要**任一**窗口处于插入模式，nvim 全局不计算 `foldlevel`（所有 buffer
均为 0），且 `InsertLeave` 后也不自动补算，除非聊天窗口重新获得焦点或内容再次写入。表现为「光标在
输入框进入插入模式后」新写入的折叠文本不被折叠。`_render` 在检测到当前模式为插入/替换时置
`state.folds_dirty=true`，`_register_focus_tracking` 注册的 `InsertLeave` 自动命令（延迟到事件循环末尾）
调 `_recompute_folds`：在聊天窗口上下文中重建 `foldexpr`（同值赋值也触发整段重算）→ `1,$foldclose!`
收起重算后新出现的折叠 → 恢复此前已展开的折叠。非 dirty、仍处插入模式、或窗口已不在聊天 buffer 上时
跳过（补算会被再次抑制 / 作用到错误 buffer）。
命令**参数或结果含密钥**（沙箱假密钥 或具名规则命中的原始密钥）时，在该工具折叠块**外**
追加**高亮警告**（`NeoAISecretWarning`），折叠文本保持干净（不含 `⚠ 密钥`）。
警告**指明具体是哪个命令/工具获取或使用了哪些密钥文件**，并按项换行格式化：首行
`⚠ 密钥：<工具> <获取/使用>`，命令单独一行，命中的密钥文件 / 类型 / 环境变量各占一行，例如：
```
⚠ 密钥：run_command 获取了密钥
· 执行 `cat ~/.ssh/id_rsa`
· 密钥文件：
·   /root/.ssh/id_rsa
```
（每行以 `· ` 起头而非空格缩进——聊天窗口按缩进折叠，缩进行会被并入折叠块而收起。）
无法确定文件时回退为密钥类型（具名规则，如 `private_key`）→ 敏感环境变量名 → 通用提示
（见 [sandbox.md](sandbox.md) 密钥防护）。**结果中仅出现敏感环境变量名不触发告警**（变量名只是
引用，未读到密钥内容）；参数中出现才按「使用密钥」告警。同时，**含密钥的工具调用参数与结果不做 500 字截断**
（完整展示），并在行内把命中的密钥值（假密钥 与具名规则命中的原始密钥）以同一
`NeoAISecretWarning` 高亮（`message_list` 与轨迹模式一致）。
命令输出中的 **ANSI SGR 颜色**（如 `\27[1;36m…\27[0m`）由 `utils.ansi` 解析：转义序列从展示文本中
剥离，颜色/属性（16/256/真彩色 + bold/italic/underline/reverse/strikethrough）以惰性创建的高亮组
（`NeoAIAnsi_*`）按区间贴合，非 SGR 的 CSI/OSC 序列（光标、清屏、窗口标题）一并剥离；
模型可见的结果内容保持原样，颜色仅影响展示。

**普通场景下工具调用的「参数:」按顶层字段逐行展示并各自截断**：剔除 description 样板字段后，顶层字段按名排序，每条一行并保留 JSON 引号格式；顶层字段数超过五十时只展示前五十条并追加省略提示；单个字段值的单行 JSON 文本超过五十个码点时按码点截断并追加省略号（UTF-8 安全）。含密钥场景不按字段截断，仍完整多行展示。

### 4.5 推理与工具参数悬浮窗

- **思考过程悬浮窗**（`reasoning_panel`）：`REASONING_CHUNK` 流式追加；正文开始/推理结束/生成结束自动关闭；
  同 tick 分片批量合并；光标不跟随时抑制弹出。
- **工具参数悬浮窗**（`tool_args_panel`）：`TOOL_ARG_CHUNK` 实时打开；单个工具调用时对累积快照做差分，
  把**新增参数分片**直接 `append` 到窗口尾部（与思考悬浮窗一致，不整段解析/重排）；多工具、名字变化或
  参数被替换等不连续变化时回退整段重建（`set_text`）。`TOOL_ARG_COMPLETED`/生成结束关闭；
  参数接收阶段先收起思考悬浮窗（避免两窗重叠）；批量冲刷 + 取消标记（`_cancel_pending_tool_args`）。

两者都：光标不跟随时不弹（`_cursor_within_follow_margin`）、`minimal` 浮窗、`foldenable=false`
（避免继承全局折叠把内容收起），且**高度上限 5 行**（`open(title, { max_height = 5 })`，
`float_stream_window` 按 `max_height` 限制自适应高度）。共享的 `float_stream_window` 还：按**显示行数**
（`nvim_win_text_height`，含 wrap 折行）自适应高度、开启 `smoothscroll`、写入后**先增高再滚**，
并把光标移到内容末尾（`G$`）后 `zb` 贴底，保证长单行/大量内容始终滚到最新尾部。

**跟随跳变即隐藏 / 重弹**：这些浮窗跟随底部流式内容，光标离开底部就应一并隐去。各流式 handler 在
「跟随判定」**之前**把 `*_active` 置位（工具参数另存 `last_tool_calls`、上下文操作另存 `ctxop_last_text`），
统一经 `_set_following(f)` 收口：仅在 `state.following` **真正跳变**时动作——跟随→非跟随调 `_hide_floats()`
隐藏全部（思考 / 接收参数 / 上下文压缩·计划蒸馏）；非跟随→跟随调 `_reshow_floats()` 重弹**仍在进行**的那个。
三个浮窗共用同一 `float_stream_window`，故重弹**互斥**：优先级 上下文压缩·计划蒸馏 > 接收参数 > 思考过程。
跳变还会广播 `UI_FOLLOW_CHANGED`（见 `events.lua`），供伪终端（`services.pty`）等其它自动浮窗订阅。
滚动 / 光标移动 / `BufEnter` 等处统一调 `M._sync_follow()` 按实时光标重判并同步（取代原先各处直接给
`state.following` 赋值），保证跳变只在用户实际滚动时发生一次。

### 4.6 输入框联动与滚动

主消息区（上）+ 输入 split（下，高度 3）。发送后切回主窗口并进入普通模式（生成期间可滚动浏览）；
主体与输入框共用一套 chat 上下文键位（`_build_chat_actions`）。`input_box` 用 `virt_text` 渲染 `> `
前缀（不用 `buftype=prompt`，避免与 nvim-cmp 冲突），并放开 `neoai_input` filetype 的补全。
`attach_window` 会用 `'winfixbuf'`（Neovim 0.10+，`pcall` 兼容旧版）**锁定输入窗口**：输入 buffer 是
`nofile` 暂存 buffer（命名为 `NeoAI Input`；多实例按聊天名派生唯一名 `NeoAI Input 2`/`NeoAI Input 3`…，
便于会话恢复识别/清理与 `:ls` 辨识），若允许在输入窗口执行
`:e <file>` / `:bnext` 等，该窗口会**复用输入 buffer**
（`buftype` 变空、内容被文件名替换），此后输入落进用户文件、`:wq` 误保存。

为避免把底层的 `E1513`（Cannot switch buffer）直接抛给用户，`chat_view` 另在高层用 `CmdlineLeave`
（`_on_input_cmdline_leave`）**通用拦截输入窗口内的任意 `:` 命令行**：中止原命令后在当前窗口原样
重放；仅当重放因 `winfixbuf` 报 E1513 时，才改用**新标签页**（`tabnew`）执行。因为无法穷举会切换到
输入窗口 buffer 的命令（`:e`/`:bnext` 之外还有 `:terminal`/`:help` 及各类插件命令），白名单必然漏网，
所以改用「先原样执行、仅对 E1513 翻转到新标签页」的通用策略：聊天主窗口与输入框保持不变，
用户拿不到 E1513，且普通输入（回车发送）、`:set`/`:w`/`:q` 等一概不受影响。`winfixbuf` 仍是
**低层兜底**：未触发 Cmdline 事件的路径（插件直接 `nvim_win_set_buf`、`<Cmd>` 等）仍被它拦下，
保输入 buffer 不被复用。（顺序：临时关 `winfixbuf` → `set_buf` → 重开。）

> 关键技术点：Lua 回调里直接给 `ev.abort`/`vim.v.event.abort` 赋值无效，必须 `let v:event.abort = v:true`。
> 注：`:sp`/`:vsp`/`:tabedit`/`:tabnew`/`:sbuffer`/`:sview` 等会新开窗口、不碰本窗口 buffer，
> `winfixbuf` 本就放行，原样重放即成功，不会误开标签。

> 注：`:sp`/`:vsp`/`:tabedit`/`:tabnew`/`:sbuffer`/`:sview` 等会新开窗口、不碰本窗口 buffer，
> `winfixbuf` 本就放行，无需拦截。

主消息区滚动分两套：

- **`j` / `k`**：走 `_scroll(delta)`，按行移动光标（光标被钳制在 `[1, 行数]`）。
- **鼠标滚轮 `<ScrollWheelUp>` / `<ScrollWheelDown>`**：走 `_wheel_scroll(delta)`，用 `<C-E>`/`<C-Y>`
  原生平滑滚动视口（保留滚轮手感），步长取 `mousescroll` 的 `ver` 值（默认 3）。滚轮滚动后会同步
  光标（滚到底时置于末行以保持跟随；回看历史时置于视口首行以取消跟随）。

为避免原生滚轮越过 buffer 末尾、在末行下方留出大片空白，向下滚且末行已可见时，
`_wheel_scroll` 会把末行下方的空白行数钳制到 `ui.chat.mousescroll_max_blank`（默认 3，`0` 为严格贴底）：
空白过多则回滚、不足则补足呼吸空间。空白行数用 `nvim_win_text_height` 计算（正确考虑折叠与折行），
并减去 winbar 占用的 1 行。

### 4.7 后台收起 / 恢复

焦点追踪（`WinEnter`/`BufEnter`）判断当前窗口是否属于聊天界面（按显示的 buffer 而非窗口句柄）：
焦点离开（或主窗口被 `:bnext` 切到别的文件）时收起输入框（`_collapse_aux`），回到聊天时恢复
（`_restore_aux`，输入 buffer 内容保留）。**特例**：主窗口被切到的 buffer 若属于**另一聊天实例**
（聊天主 buffer 或其输入 buffer），不收起了事，而是路由到那个实例（见 §4.0）——避免出现「显示着
聊天内容却没有输入框」的残缺界面。

`_restore_aux` 为**「确保输入区存在」**语义：只要聊天主窗口有效且输入窗口缺失/失效就重建，不再只在
`state.collapsed` 为真时才建。这样即使用户在输入框里 `:q`/`<C-w>c` 把输入窗口关掉（`winfixbuf` 并不阻止关窗，
且此时 `collapsed` 仍为 false），回到聊天界面时输入框也会自动补回，不会永久消失。
`WinClosed` 负责在输入窗口被关掉时及时清除失效句柄；创建时用重入守卫 `_input_creating` 防止 `:split`
同步触发的嵌套 `WinEnter` 建出第二个输入框。

### 4.8 界面 buffer 的 LSP 隔离（ui/lsp_guard）

NeoAI 的聊天/输入框/悬浮窗等都是纯 UI 文本，若 LSP 客户端（native LSP / GitHub Copilot）
挂载上去，`document_color` / `folding_range` / `semantic_tokens` / `inline_completion` 会持续
空耗 CPU（Copilot 尤其明显）。`ui/lsp_guard` 统一拦截：

- 以 `neoai*` filetype（或 `b:neoai_ui` 标记）识别 NeoAI buffer；
- **一次性**把 `neoai*` 写入 `g:copilot_filetypes`（值空 = 禁用）：copilot.vim 从源头就不
  attach/启动 language server（`nofile` 不在其内置禁用列表里），避免「先启动再被解绑」的开销；
- `FileType neoai*` 时设置 `b:neoai_ui`、普通 buftype 改 `nofile`（阻断 native LSP 自动启动；
  保留 `acwrite`，轨迹模式 `:w` 保存依赖它）、逐 buffer 关闭 Copilot
  （`b:copilot_disabled`/`b:copilot_disable`/`b:copilot_enabled=false`）并解绑已挂载客户端；
- `LspAttach` 兜底：对 NeoAI buffer 上延迟/异步挂载的客户端 schedule 解绑。

由 `ui.init` 安装、`ui.reset` 卸载（幂等，可热重载）。

### 4.9 会话恢复残留清理（ui/session_cleanup.lua）

`:restart` 会先 `:mksession` 存会话、`:qall` 退出、再以同 argv 重启并恢复会话；`sessionoptions`
默认含 `blank,buffers`，于是聊天主 buffer / 输入框 buffer 会作为 `nofile` 暂存 buffer 被一起保存、
恢复。但恢复出来的只是「壳」：Lua 侧窗口句柄与状态都随进程丢失，形成**界面孤儿 buffer**——
既占用 `NeoAI Chat` / `NeoAI Input` 等名字（导致新建聊天 buffer 的 `nvim_buf_set_name` 静默失败、
跳到该 buffer 时输入框不打开），又让界面看起来「没关干净」。手动 `nvim -S session.vim` 同理。

`ui/session_cleanup.install()`（由 `NeoAI.setup()` 调用）在：

- **`SessionLoadPost`**（会话载入后）与
- **`VimEnter` 且 `v:startreason ~= "normal"`**（`:restart` / `-S` 兜底）

两个时机 `vim.schedule` 延迟一拍调用 `manager.cleanup_session_orphans()`：识别 `filetype` 以
`neoai` 开头、或 basename 命中 `NeoAI Chat` / `NeoAI Sessions` / `NeoAI Input`（含 `NeoAI Input N`）/
`NeoAI-<数字>` 的**无主** buffer（跳过 `state.windows` 登记的有效窗口 buffer，以及各实例经
`manager.register_aux` 登记的输入 buffer——收起时窗口虽关、buffer 仍保留），安全关窗 +
`nvim_buf_delete(force)`，全程 `pcall`、幂等、不触碰非 NeoAI buffer。
效果：重启后聊天界面完全关闭，用户需显式 `:NeoAIChat` 重开（新会话）；恢复残留的
`NeoAI Input N` 不会被「有实时聊天即整体豁免」放过而占名（多实例下输入 buffer 名唯一化依赖于此）。

同时定义 `_G.NeoAIFoldExpr` 兜底桩（返回 0），避免恢复出的窗口 `foldexpr=v:lua.NeoAIFoldExpr()`
在重绘首帧报错（`chat_view.open` 会用真实实现覆盖）。

> 注册点必须在 `NeoAI.setup()`：实测（Neovim 0.12 + `vim.opt.rtp:prepend` 挂载）`after/plugin`
> 目录不会被自动 source，`after/plugin/NeoAI.lua` 只作幂等补充。

`chat_view.open()` 在新建窗口分支也会先做一次清理（兜底同名冲突），`close()` 连带删除输入 buffer
（`input_box.destroy()`），避免 `nofile` 命名 buffer 泄漏。

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
| `input_box` | 聊天输入框。`create`/`attach_window`/`focus`/`submit`/`on_submitted`/`clear`；`virt_text` 渲染 `>` 前缀；放开 `neoai_input` 文件类型补全；`attach_window` 用 `'winfixbuf'`（0.10+）锁窗，作为低层兜底防止 `:e`/`:bnext`/`:terminal` 等复用输入 buffer（用户级通用拦截见 `chat_view` 的 `CmdlineLeave`）。 |
| `message_list` | 消息列表渲染。`render(buf, messages)`；`toggle_reasoning()`。 |
| `float_stream_window` | 复用流式悬浮窗。`open(title,{filetype,max_height})`/`set_text`/`append`/`get_text`/`close`/`is_open`/`reset`；思考过程 / 接收参数 / 计划蒸馏共享同一窗口（上下文压缩为后台异步、不弹窗，不再使用）。窗口**按屏幕比例**（宽 0.70×列数、高 0.60×行数、顶部对齐）开窗，高度上限按显示行数（`nvim_win_text_height`）自适应，受 `max_height` 限制，开启 `smoothscroll`，写入后先增高再滚、光标移到内容末尾后 `zb` 贴底。 |
| `reasoning_panel` | 思考过程悬浮窗（`float_stream_window` 适配器，高度上限 5 行）。`open`/`show`/`append`/`close`/`is_open`；`filetype=neoai_reasoning`。 |
| `tool_args_panel` | 工具参数接收悬浮窗（`float_stream_window` 适配器，流式工具调用参数，高度上限 5 行）。单工具时按分片增量 `append`，否则整段重建；`open`/`show`/`close`/`is_open`/`get_content`/`reset`；`filetype=neoai_tool_args`。 |
| `lsp_guard` | 界面 buffer 的 LSP 隔离。`install()`/`uninstall()`/`disable(buf)`；按 `neoai*` filetype 关闭 LSP/Copilot 并解绑已挂载客户端（见 §4.8）。 |
| `model_picker` | 模型选择器（异步加载模型列表）。`open(callback)`。 |
| `tool_approval` | 工具审批弹窗。`init()`；串行单槽位展示。 |
| `ask_user` | 向用户提问弹窗。`init()`；经 `ask_user.set_ui` 注入。 |
| `sub_agent_dock` | 子 Agent 状态监控。`init()`。 |
| `terminal_window` | 交互式命令的悬浮**可交互**终端（`nvim_open_term` 渲染，焦点在内时可手动键入转发给命令）。按会话 id 开窗；**仅在聊天光标跟随时弹出**（`show_window` 控制时机：always=会话启动即弹 / on_wait=命令运行超过 `show_window_delay_ms`（默认 2000ms）仍未结束才弹，短命令不弹），跟随跳变时随 `UI_FOLLOW_CHANGED` 隐藏 / 重弹（见 `services.pty`；每次开窗都用新的 `nvim_open_term` 通道，开窗时重放累计输出，避免空白窗口）；headless 下为 no-op。由 `services.pty` 驱动。 |
| `sandbox_review` | 沙箱待审审批界面。`open()`（**无待审/审批/留痕事项时同样打开窗口并展示空界面，不弹提示、不自动关闭**；刷新到空队列也保持窗口，待新事项到达由事件订阅自动刷新）；按路径级别高亮（工作区绿/用户目录黄/系统红）、按安全级别显示高危/中危/低危风险档与原因；界面按「未应用（待审）/ 已应用（含快照，可撤销）」分区；审批单位为单个文件：`<CR>` 仅应用该文件、`A` 一键同意全部工作区内修改（工作区外文件与主机操作保留待审；逐项让出主循环、标题显示进度、进行中防重入）、`d` 仅拒绝该文件（其余文件保留待审）、`i` 临时关闭审批窗并打开该条目的修改 diff 预览（关闭后自动返回并恢复光标），头行仅作信息展示，`q` 关闭；在**越界访问留痕**行按 `i` 打开访问详情（汇总涉及工具/来源/涉及命令数/首末时间，逐条列出工具/类型/命令/时间），在**越界命令**行按 `i` 打开命令详情（列出该命令越界访问的文件）；**窗口打开期间订阅沙箱广播事件自动刷新**（待审/已应用/越界留痕/主机操作变化即时重绘，同一 tick 内事件合并），无需手动刷新。**「已应用」区默认折叠**：整区收起（`za`/`zo` 展开），展开后每条再各自收起（两级折叠），刷新后重新收起；**待审条目「头行显示、其余折叠」、`za`/`zo` 可展开**（头行保留整组审批入口与高亮，其后文件/风险列表默认收起），越界留痕区不折叠。**高危条目**（L3 critical，以及 `package_confirm` 开启时的 L2 包/敏感安装）首次 `<CR>` 不直接应用：调用模型生成一条后果警告并自动打开 diff（顶部展示警告，生成中显示占位；标题按级别区分 `⚠ L2 高危 · 确认应用` / `⚠ L3 严重 · 确认应用`，按键提示行高亮，若冻结时剔除了遮蔽/易变缓存文件会追加「将跳过 N 个」说明），用户在 diff 内再次 `<CR>` 才真正应用、`q`/`<Esc>` 取消；模型不可用时回退规则警告（见 `sandbox/review/l3_warning.lua`）。 |
| `fold` | 折叠（推理/工具调用/结果共用实现）。`foldexpr`/`foldtext`/`record_start`/`record_end`/`has_running`/`set_live_timer`/`set_foldexpr_override`/`set_foldtext_override`/`set_reasoning_lines`/`is_reasoning_start`/`generic_label`。 |
| `display_modes/` | 显示模式插件管理器 + `chat.lua`/`trajectory.lua`。 |
| `markdown_view` | Markdown 渲染器。 |

## 7. 键位（ui/keymap.lua）

`keymap.register_context("chat", actions, buf)` 把一段 action handler 映射到指定 buffer。主界面与
输入框共用同一份 chat 上下文键位（排除 send/insert，在输入框内单独绑定）。`show_keymaps()` 展示
当前键位配置。

聊天上下文键位（`keymaps.chat`）：`insert`(i)、`quit`(q)、`send`、`cancel`(<Esc>)、`toggle_reasoning`(r)、
`switch_model`(M)、`cycle_mode`(m)、`cycle_display`(<C-t>/T)、`reload_display`(<F5>)、
`tool_approval`(<C-a>)、`sandbox_review`(<leader>ap，触发 `:NeoAISandboxReview`)、
`approval.confirm/confirm_all/add_to_workspace/cancel/cancel_with_reason`（`add_to_workspace` 把所操作文件所在目录并入该工具运行期 `allowed_directories`，仅当前会话生效）。
另有主消息区内部滚动映射：`j`/`k`（走 `_scroll`，按行移动光标）、
`<ScrollWheelUp>`/`<ScrollWheelDown>`（走 `_wheel_scroll`，平滑滚动视口并把末行下方留白钳制在
`ui.chat.mousescroll_max_blank` 行内）。

## 8. 相关文档

- [configuration.md](configuration.md)：`ui.*` / `keymaps.*` 配置。
- [EVENTS.md](EVENTS.md)：UI 事件（`WINDOW_*`、`DISPLAY_MODE_CHANGED` 等）。
- [chat_enhanced_usage.md](chat_enhanced_usage.md)：聊天界面使用指南。
