# NeoAI Chat Interface User Guide (v3.0)

> [中文](../chat_enhanced_usage.md) | **English**

> This document describes actual usage of the v3.0 chat interface. The `NeoAI.ui.chat_enhanced` module
> and the `:NeoAISend` / `:NeoAIMode` / `:NeoAIDemo` / `:NeoAIList` commands mentioned in older
> versions **do not exist**.
> Corresponding source: `lua/NeoAI/ui/window/chat_view.lua`, `lua/NeoAI/ui/components/*`.

## 1. Opening the Chat

```vim
:NeoAIChat        " Open the chat interface directly
:NeoAIOpen        " Open the default view (per ui.default_view, chat/tree)
```

Or bind a keymap in your Neovim configuration (`keymaps.global`, default `<leader>ac`).

## 2. Interface Layout

The chat window = **main message area (top)** + **input box (bottom, split, height 3)**.

- Main message area: `expr` folds (reasoning / each tool call block / tool results each become independent
  folds), with `foldenable` explicitly enabled.
  When the cursor is near the bottom (within the last 5 lines), streaming output follows along automatically;
  `j`/`k` move the cursor by line (`_scroll`), while the mouse wheel uses `<C-E>`/`<C-Y>` to smoothly scroll the
  viewport (`_wheel_scroll`), clamping the blank space below the last line to `ui.chat.mousescroll_max_blank`
  (default 3) lines instead of leaving more and more white space like the native behavior.
- Input box: a regular buffer with a `virt_text`-rendered `> ` prefix (not using `buftype=prompt`, to avoid
  conflicts with nvim-cmp); completion is enabled for the `neoai_input` filetype.

## 3. Basic Interaction

| Action | Key | Description |
| --- | --- | --- |
| Send | Insert mode `<C-s>` / Normal mode `<CR>` | Multi-line input: pressing Enter in insert mode inserts a newline (does not send) |
| Cancel generation | `<Esc>` | Cancel via AbortSignal (a normal stop, not an error) |
| Enter insert mode | `i` / `a` | Normal mode |
| Close window | `q` | |
| Toggle reasoning display | `r` | `message_list.toggle_reasoning` |
| Switch model | `M` | Opens the model selector |
| Cycle mode | `m` | CHAT → PLAN → AUTO |
| Cycle display mode | `<C-t>` (insert) / `T` (normal) | chat / trajectory |
| Hot-reload display mode | `<F5>` | Reload the current display-mode plugin |
| Approve plan | — | AI calls `exit_plan_mode` (opens an approval window for confirmation) or run `:NeoAIApprovePlan` |
| Tool approval | `<C-a>` | Confirm inside the approval popup |
| Sandbox review | `<leader>ap` | Equivalent to `:NeoAISandboxReview`; list and apply pending sandbox changes (per-file approval), graded high/medium/low; press `i` to preview that item's diff (temporarily closes the review window and returns with the cursor restored) |
| Scroll | `j` / `k` / mouse wheel | `j`/`k` move the cursor by line; the wheel smoothly scrolls the viewport, with blank space below the last line capped at `ui.chat.mousescroll_max_blank` lines |

## 4. Streaming Updates and Floating Windows

- **Body streaming**: incremental display in real time; multiple chunks within the same tick are merged into a
  single render (to avoid blocking the main thread).
- **Reasoning floating window** (`reasoning_panel`): appends in real time on `REASONING_CHUNK`; closes
  automatically when the body starts / reasoning ends / generation ends.
- **Tool-argument receiving floating window** (`tool_args_panel`): when the model streams tool call arguments,
  a "receiving arguments" window opens in real time and **incrementally appends** as chunks arrive (for a single
  tool call it appends the raw arguments chunk by chunk, consistent with the reasoning floating window, to avoid
  reflowing the entire block), closing on `TOOL_ARG_COMPLETED`. The window height adapts to the **number of
  displayed lines** (including wrapped lines) and always scrolls automatically to the end of the content.
- All floating windows share `float_stream_window`: the window height grows with the content (up to a maximum),
  `smoothscroll` is enabled, and even a long single line can be scrolled to its end; after writing, it first grows
  taller and then scrolls, moves the cursor to the end of the content (last line, last column), and then uses `zb`
  to pin it to the bottom.
- Auto-follow scrolling and popup floating windows happen only when the cursor is within the last 5 lines of the
  message area; reviewing earlier content does not disturb them.

## 5. Folding (components/fold)

Reasoning / each tool call block (call + result) each become independent folds, with no separator line needed
between blocks. The fold placeholder text is provided uniformly by `components.fold`. During tool execution it
re-renders once per second so that the **elapsed time** in the fold text ticks in real time (based on the active
elapsed time of the pausable timer `utils.timer`, excluding time spent waiting on approvals/questions).

Expand/collapse: `zM` (collapse all) / `zo` (expand) / `zR` (expand all).

## 6. Plan Mode (PLAN)

`m` or `:NeoAIPlan` toggles plan mode:

- The tool context keeps only **read-only/information-query tools + `run_command` (read-only research) + `ask_user` + `exit_plan_mode`**, exposing no
  modifying tools at all.
- The execution-time gate tightens accordingly; tools outside the visible set are rejected when called.
- In plan mode the AI researches and asks clarifying questions, then outputs a **clear, well-formatted change
  plan**.
- After the plan is complete, the AI calls `exit_plan_mode` (an approval window pops up for the user to confirm;
  you can also run `:NeoAIApprovePlan`); once confirmed, it switches to CHAT mode, parses the plan into a todo
  list, and executes it automatically.
- Switching modes during generation (`m` / `:NeoAIPlan` / `:NeoAIAuto`) is deferred until the current turn ends,
  so it does not interrupt an in-progress generation.

## 7. AUTO Mode

`:NeoAIAuto` or `m` cycles to AUTO mode: automatically allow all tool calls (a runtime switch); when enabled it
immediately approves currently pending/queued tools. Switching to AUTO **during generation/tool execution** also
takes effect **immediately** (approval relaxation is decoupled from tool-set/model changes), rather than waiting
until the end of the turn — avoiding "I switched to AUTO but this turn still keeps popping up approval dialogs".
Leaving AUTO and switching to other modes is still deferred until the end of the turn, to avoid interrupting the
current turn midway.

## 8. Asking the User (ask_user)

During generation the AI can pause and ask the user a question via `ask_user`, waiting for the answer. The question
popup (`ui/components/ask_user`) supports quick option selection; the answer is passed back to the AI as a tool
result. When no UI is registered, it falls back to `vim.ui.input`.

## 9. Related Documentation

- [configuration.md](configuration.md): `ui.*` / `keymaps.*` configuration.
- [ui_system.md](ui_system.md): `chat_view` internal implementation.
- [ai_engine.md](ai_engine.md): generation / tool loop / plan mode.
