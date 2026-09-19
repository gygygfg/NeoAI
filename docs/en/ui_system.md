# NeoAI UI System (v3.0)

> [中文](../ui_system.md) | **English**

> The UI layer handles the orchestration of windows/components/keymaps. It renders all windows as plain text
> (LSP attachment and line numbers/sign columns are disabled), updates streaming content in an event-driven
> way, and provides a dual view: "folds + floating windows".
> Corresponding source: `lua/NeoAI/ui/*`.

## 1. Module Structure

| Module | Responsibility |
| --- | --- |
| `ui/init.lua` | UI entry point: initialization (registers approval/questioning/sub-agent monitoring UIs), `open_default`/`open_chat`/`open_tree`/`close_all`, keymap display. |
| `ui/window/manager.lua` | Window manager: create/close/focus for the three modes `float` / `tab` / `split`; disables LSP attachment and line numbers/sign columns. |
| `ui/window/chat_view.lua` | Chat view: binds events, streaming updates, folds, floating window scheduling, input box linkage, background collapse/restore, display mode host. |
| `ui/window/tree_view.lua` | Session tree view: branch tree display and CRUD. |
| `ui/components/*` | Reusable components (see below). |
| `ui/keymap.lua` | Keymap registration (`register_context`) and display. |

## 2. Window Management (manager.lua)

Supports three window modes (`ui.window_mode`): `float` / `tab` / `split`.

- `create(window_type, opts)`: creates a window, sets `filetype` (`neoai`), names the buffer (`NeoAI Chat` / `NeoAI Sessions`),
  and fires `WINDOW_OPENED`.
- **Disabling LSP**: `_disable_lsp` sets the buffer to `buftype=nofile`, sets `b:copilot_disabled`/`b:copilot_disable`,
  and applies a catch-all interception via `LspAttach` (tagging with `b:neoai_ui`), so any LSP client (including Copilot) is immediately detached when it tries to attach.
- **Unified window config**: disables `number`/`relativenumber`/`signcolumn`/`foldcolumn`/`list`/`colorcolumn`/`spell`.

## 3. UI Initialization (ui/init.lua)

`M.init()` is idempotent and registers three kinds of UI implementations:

- **Approval UI**: `ui/components/tool_approval.init()` (injected via `tool_service.set_approval_ui`).
- **User questioning UI**: `ui/components/ask_user.init()` (injected via `ask_user.set_ui`).
- **Sub-agent monitoring**: `ui/components/sub_agent_dock.init()`.

`open_default()` opens the corresponding view according to `ui.default_view` (chat/tree).

## 4. Chat View (chat_view.lua)

### 4.1 Layout

Main message area (top, `expr` folds) + input split window (bottom, height 3, `winfixheight`).

### 4.2 Event Subscriptions

When the chat window opens it subscribes to: `MESSAGE_ADDED` / `MESSAGE_UPDATED` / `STREAM_CHUNK` / `TOOL_CALL_DETECTED` /
`TOOL_RESULT_RECEIVED` / `TOOL_EXECUTION_STARTED|COMPLETED|ERROR` / `REASONING_CHUNK` /
`REASONING_COMPLETED` / `TOOL_ARG_CHUNK` / `TOOL_ARG_COMPLETED` / `GENERATION_COMPLETED` /
`GENERATION_ERROR` / `AGENT_ABORTED`.

### 4.3 Streaming Render Coalescing

Multiple chunks/events within the same tick are rendered only once (`_schedule_render` coalesces them), avoiding
per-chunk full re-renders plus fold recomputation that would block the main thread. Whether the cursor is following
(within the last 5 lines) is cached at scheduling time: when not following, floating windows are not popped up and
folds are not collapsed, and fold blocks that were expanded before the rewrite are restored, so the position the
user is viewing is not dragged away.

### 4.3.1 Incremental Refresh (no full-buffer rewrite)

Ordinary refreshes (streaming chunks, event-driven re-renders, tool-duration ticks, window-width changes, ...)
**no longer rewrite the whole buffer**. They take an incremental path:

- `components.incremental` caches the render result of each message (chat mode) or each turn (trajectory mode)
  keyed by "block key + signature". The signature covers every input that affects rendering (role/content/reasoning/
  tool_calls/duration_ms, fold-block state `fold.get_status`/`get_duration`, `streaming`/`table_width`, ...). Blocks
  whose signature is unchanged are reused; only changed blocks are re-rendered.
- The assembled lines are diffed against the last written content via longest common prefix/suffix
  (`incremental.diff_range`), and only the **changed line range** is written back with `nvim_buf_set_lines`. When the
  content is identical the buffer is **not touched at all** (`changed=false`), which also skips the `zx`/`zM` fold
  recomputation and scrolling. Table highlights are likewise only repainted inside the diff range.
- As a result, each streaming chunk rewrites only a few trailing lines, and the prefix region holding earlier
  messages costs nothing. `chat_view._render` uses the returned diff to decide whether to recompute folds and scroll.

Cache invalidation (`incremental.invalidate`): switching sessions, context compaction / plan distillation that
reorders history, switching display modes, and window-width changes (table reflow) clear the mirror so the next
render falls back to a full rewrite, avoiding diff writes based on stale line positions. The old behavior can be
restored by setting `ui.chat.incremental = false`.

### 4.4 Folds

The main window uses `expr` folds (`components.fold.foldexpr`); reasoning / each tool call block (call + result)
becomes its own independent fold. The fold placeholder text is provided uniformly by `components.fold`. **Only folds
explicitly registered as reasoning by the renderer show `🤔 思考过程 N 行`** (`message_list` registers reasoning start
lines after writing the buffer); tool blocks show `🔧 <tool>` and any other unrecognized fold shows a neutral
placeholder (`📄 <first-line preview> (N lines)`), so not every fold is rendered as a thinking process. During tool
execution it re-renders once per second (`TOOL_TICK_MS=1000`), so the elapsed time in the fold text ticks in real time.
When a command's **arguments or result contain a secret** (sandbox token `NEOKEY_*` or a raw secret matched by a
named rule), a **separate highlighted warning line** (`⚠ 密钥`, `NeoAISecretWarning`) is appended **outside** the
tool fold block; the fold title stays clean (no `⚠ 密钥` suffix) and the warning remains visible while collapsed.
The warning **names the exact command/tool and the key file it obtained or used**, e.g.
`⚠ 密钥：run_command 执行 cat ~/.ssh/id_rsa 获取/使用了密钥（密钥文件：/root/.ssh/id_rsa）`; when the file cannot be
determined it falls back to the secret type (named rule, e.g. `private_key`) → sensitive environment variable
name → generic notice (see the secrets section of [sandbox.md](sandbox.md)). Moreover, for a tool call that
contains a secret, its **arguments and result are shown in full (no 500-char truncation)** and the matched
secret values (`NEOKEY_*` tokens and raw secrets matched by named rules) are highlighted inline with the same
`NeoAISecretWarning` group (identical in `message_list` and trajectory mode).
**ANSI SGR colors** in command output (e.g. `\27[1;36m…\27[0m`) are parsed by `utils.ansi`: escape sequences are
stripped from the displayed text and the colors/attributes (16/256/truecolor + bold/italic/underline/reverse/
strikethrough) are applied per span via lazily created highlight groups (`NeoAIAnsi_*`); non-SGR CSI/OSC sequences
(cursor, erase, window title) are stripped as well. The model-visible result content is unchanged — colors affect
display only.

### 4.5 Reasoning and Tool Arguments Floating Windows

- **Reasoning process floating window** (`reasoning_panel`): `REASONING_CHUNK` appends streaming content; it closes
  automatically when the main text starts / reasoning ends / generation ends; chunks in the same tick are batched and
  coalesced; popup is suppressed when the cursor is not following.
- **Tool arguments floating window** (`tool_args_panel`): `TOOL_ARG_CHUNK` opens it in real time; for a single tool
  call it diffs against the accumulated snapshot and directly `append`s the **new argument chunks** to the end of the
  window (consistent with the reasoning floating window, without parsing/rearranging the whole segment); for
  discontinuous changes such as multiple tools, a name change, or replaced arguments, it falls back to rebuilding the
  whole segment (`set_text`). It closes on `TOOL_ARG_COMPLETED`/generation end; during the argument-receiving phase it
  first collapses the reasoning floating window (to avoid the two windows overlapping); batched flush + cancellation
  flag (`_cancel_pending_tool_args`).

Both: do not pop up when the cursor is not following (`_cursor_within_follow_margin`), `minimal` floating window,
`foldenable=false` (to avoid inheriting global folds and collapsing the content), and are **capped at 5 lines**
(`open(title, { max_height = 5 })`; `float_stream_window` limits its adaptive height by `max_height`). The shared
`float_stream_window` additionally: adapts its height to the **number of display lines** (`nvim_win_text_height`,
including wrapped lines), enables `smoothscroll`, **grows first and then scrolls** after writing, and moves the cursor
to the end of the content (`G$`) followed by `zb` to stick to the bottom, ensuring that a long single line/large
amount of content always scrolls to the latest tail.

### 4.6 Input Box Linkage and Scrolling

Main message area (top) + input split (bottom, height 3). After sending, focus returns to the main window and enters
normal mode (you can scroll and browse during generation); the main body and the input box share the same set of chat
context keymaps (`_build_chat_actions`). `input_box` renders the `> ` prefix with `virt_text` (it does not use
`buftype=prompt`, to avoid conflicts with nvim-cmp), and enables completion for the `neoai_input` filetype.

Scrolling in the main message area uses two paths:

- **`j` / `k`**: go through `_scroll(delta)`, moving the cursor by line (clamped to `[1, line count]`).
- **Mouse wheel `<ScrollWheelUp>` / `<ScrollWheelDown>`**: go through `_wheel_scroll(delta)`, using
  `<C-E>`/`<C-Y>` to smoothly scroll the viewport (preserving the native wheel feel); the step size takes the `ver`
  value of `mousescroll` (default 3). After scrolling it syncs the cursor (moved to the last line when at the bottom to
  keep following; moved to the top visible line when reviewing history to cancel following).

To avoid the native wheel scrolling past the end of the buffer and leaving a large blank area below the last line,
when scrolling down with the last line already visible `_wheel_scroll` clamps the blank lines below the last line to
`ui.chat.mousescroll_max_blank` (default 3; `0` means strictly bottom-aligned): if there is too much blank space it
scrolls back, and if too little it adds breathing room. The blank count is computed with `nvim_win_text_height`
(correctly accounting for folds and wrapped lines), minus the 1 line taken by the winbar.

> **AUTO takes effect immediately**: while the Agent is busy (generating/tool_running), `chat_service._request_mode`
> calls `tool_service.set_auto_mode(true)` **immediately** if the target is AUTO (internally auto-approving the current
> pending approval/queued items), rather than waiting until the end of the current turn; other mode switches
> (toolset/model, including leaving AUTO) are still deferred and applied at the end of the current turn.

### 4.7 Background Collapse / Restore

Focus tracking (`WinEnter`/`BufEnter`) determines whether the current window belongs to the chat view (based on the
displayed buffer rather than the window handle): when focus leaves (or the main window is switched to another file via
`:bnext`), the input box is collapsed (`_collapse_aux`), and when returning to the chat it is restored
(`_restore_aux`, with the input buffer content preserved).

### 4.8 LSP Isolation for UI Buffers (ui/lsp_guard)

NeoAI's chat/input/floating windows are pure UI text; if an LSP client (native LSP / GitHub Copilot) attaches to
them, `document_color` / `folding_range` / `semantic_tokens` / `inline_completion` keep burning CPU (especially
Copilot). `ui/lsp_guard` intercepts uniformly:

- Identifies NeoAI buffers by `neoai*` filetype (or the `b:neoai_ui` marker).
- **One-time**: adds `neoai*` to `g:copilot_filetypes` (empty value = disabled), so copilot.vim never attaches /
  starts the language server for them (`nofile` is not in its built-in disabled list), avoiding the
  start-then-detach overhead.
- On `FileType neoai*`: sets `b:neoai_ui`, changes a normal buftype to `nofile` (blocking native LSP auto-start;
  `acwrite` is preserved because trajectory-mode `:w` saving depends on it), disables Copilot per buffer
  (`b:copilot_disabled`/`b:copilot_disable`/`b:copilot_enabled=false`), and detaches attached clients.
- `LspAttach` fallback: schedules detach for clients that attach to a NeoAI buffer late/asynchronously.

Installed by `ui.init` and removed by `ui.reset` (idempotent, hot-reload friendly).

## 5. Display Modes (display_modes)

Following deepseek-harness's Cordis plugin model, the chat view's "display modes" are made into plugins:

- Each mode is an independent Lua module (`ui/components/display_modes/<name>.lua`, module name = mode name) that
  registers itself.
- Plugin interface: `{ name, label, desc, load?(host), unload?(host), render?(buf, messages) }`.
- The host is injected by `chat_view.open`: it provides `get_buf` / `get_messages` / `set_foldexpr` / `set_foldtext` / `refresh`.
- **Switching modes** = unload the current plugin (`unload`) → load the target plugin (`load`), i.e. hot-swapping. `activate(name, {force})`.
- **Hot reload**: `reload(name)` clears the require cache and reloads the module (plugin changes take effect without
  restarting the view).
- Built-in modes: `chat` (conversation) and `trajectory` (trajectory). Switching fires `DISPLAY_MODE_CHANGED`.

## 6. Component List

| Component | Responsibility |
| --- | --- |
| `input_box` | Chat input box. `create`/`attach_window`/`focus`/`submit`/`on_submitted`/`clear`; renders the `>` prefix with `virt_text`; enables completion for the `neoai_input` filetype. |
| `message_list` | Message list rendering. `render(buf, messages)`; `toggle_reasoning()`. |
| `float_stream_window` | Reusable streaming floating window. `open(title,{filetype,max_height})`/`set_text`/`append`/`get_text`/`close`/`is_open`/`reset`; reasoning process / receiving arguments / context compaction / plan distillation share the same window. The window height adapts to the number of display lines (`nvim_win_text_height`), bounded by `max_height`, `smoothscroll` is enabled, and after writing it grows first then scrolls, with the cursor moved to the end of the content followed by `zb` to stick to the bottom. |
| `reasoning_panel` | Reasoning process floating window (`float_stream_window` adapter, height capped at 5 lines). `open`/`show`/`append`/`close`/`is_open`; `filetype=neoai_reasoning`. |
| `tool_args_panel` | Tool arguments receiving floating window (`float_stream_window` adapter, streaming tool call arguments, height capped at 5 lines). For a single tool it `append`s incrementally by chunk, otherwise it rebuilds the whole segment; `open`/`show`/`close`/`is_open`/`get_content`/`reset`; `filetype=neoai_tool_args`. |
| `lsp_guard` | LSP isolation for UI buffers. `install()`/`uninstall()`/`disable(buf)`; disables LSP/Copilot for `neoai*` filetypes and detaches attached clients (see §4.8). |
| `model_picker` | Model picker (asynchronously loads the model list). `open(callback)`. |
| `tool_approval` | Tool approval popup. `init()`; serial single-slot display. |
| `ask_user` | User questioning popup. `init()`; injected via `ask_user.set_ui`. |
| `sub_agent_dock` | Sub-agent status monitoring. `init()`. |
| `fold` | Folds (shared implementation for reasoning/tool calls/results). `foldexpr`/`foldtext`/`record_start`/`record_end`/`has_running`/`set_live_timer`/`set_foldexpr_override`/`set_foldtext_override`/`set_reasoning_lines`/`is_reasoning_start`/`generic_label`. |
| `display_modes/` | Display mode plugin manager + `chat.lua`/`trajectory.lua`. |
| `markdown_view` | Markdown renderer. |

## 7. Keymaps (ui/keymap.lua)

`keymap.register_context("chat", actions, buf)` maps a set of action handlers to the specified buffer. The main view
and the input box share the same chat context keymaps (send/insert are excluded and bound separately inside the input
box). `show_keymaps()` displays the current keymap configuration.

Chat context keymaps (`keymaps.chat`): `insert`(i), `quit`(q), `send`, `cancel`(<Esc>), `toggle_reasoning`(r),
`switch_model`(M), `cycle_mode`(m), `cycle_display`(<C-t>/T), `reload_display`(<F5>),
`tool_approval`(<C-a>), `approval.confirm/confirm_all/add_to_workspace/cancel/cancel_with_reason` (`add_to_workspace` merges the operated file's directory into that tool's runtime `allowed_directories`, session-only).
There are also internal scrolling mappings for the main message area: `j`/`k` (through `_scroll`, moving the cursor by
line), and `<ScrollWheelUp>`/`<ScrollWheelDown>` (through `_wheel_scroll`, smoothly scrolling the viewport while clamping
the blank space below the last line to `ui.chat.mousescroll_max_blank` lines).

## 8. Related Documents

- [configuration.md](configuration.md): `ui.*` / `keymaps.*` configuration.
- [EVENTS.md](EVENTS.md): UI events (`WINDOW_*`, `DISPLAY_MODE_CHANGED`, etc.).
- [chat_enhanced_usage.md](chat_enhanced_usage.md): chat view usage guide.
