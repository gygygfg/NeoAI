# NeoAI Tool System (v3.0)

> [中文](../tool_system.md) | **English**

> The tool system lets the AI interact with the editor and file system through a structured tool-calling
> interface. Tool registration, validation, approval (serial, single slot), execution, and categorization are
> all handled by this system. The Agent's tool loop calls into this system through
> `services.tool_service` to execute tools.
> Corresponding sources: `lua/NeoAI/tools/*`, `lua/NeoAI/services/tool_service.lua`.

## 1. Module Structure

| Module | Responsibility |
| --- | --- |
| `tools/init.lua` | Tool system entry point. `init()` applies approval config + loads built-in tools; `get_tools()` / `execute()` / `reload_tools()`. |
| `tools/registry.lua` | Tool registry: registration, lookup, alias resolution, approval config management. |
| `tools/executor.lua` | Tool executor: argument normalization → validation → approval decision → execution (async) + timeout based on a pausable timer. |
| `tools/validator.lua` | Parameter schema validation + approval decision (path/param-group safety checks). |
| `tools/packer.lua` | Groups tools by category for packing (categorized UI display). |
| `tools/environment.lua` | Tool environment detection (workspace / git directory); disables environment-dependent tools when unavailable. |
| `tools/builtin/*` | Built-in tool implementations (see below). |
| `sandbox/*` | Tool execution sandbox control plane (preflight / isolated execution / candidate freeze / CAS publish); see [sandbox.md](sandbox.md). |

## 2. Tool Definition

Tools are constructed through `tool_helpers.define_tool(name, description, params, func, opts)`. Tool definition structure:

```lua
{
  name = "read_file",            -- tool name
  description = "Read file contents…", -- description (for the model)
  parameters = { type = "object", properties = {...}, required = {...} }, -- schema
  func = function(args, on_success, on_error, ctx) ... end, -- execution function
  category = "file",             -- category (file/system/git/treesitter/lsp/log/agent/mcp/skill)
  source = "builtin",            -- source (builtin/mcp; mcp tools skip argument alias rewriting in the executor)
  approval = { auto_allow = ... }, -- approval config
  timeout = ...                  -- optional timeout (ms)
}
```

> **Uniform injection of the `description` parameter**: `define_tool` adds a required string parameter
> `description` ("description of the purpose of this call") to every tool, unless it already exists.
> It is used for approval and collapsed display.

Tool definitions support two execution forms (`executor._call_tool`):

- **Callback style**: `func(args, on_success, on_error, ctx)` (`arity >= 2`).
- **Returns a Deferred**: `func(args, ctx)` returns an object with `then_`.

> **Tool conventions (shared system-prompt section)**: to cut prompt size, per-tool descriptions are
> kept terse and cross-tool boilerplate is factored into a single system section `tools:conventions`
> (registered by `tools/init.lua` via `kernel.core_bridge.prefix`, emitted once): required
> `description`; 1-based line numbers; `~`/`$VAR` path expansion; oversized output truncated to
> head+tail and spilled to disk (read back via `read_file` `offset/limit`); `git_*` `repo` defaults
> to the session repo; `run_command` interactive PTY auto-answer and `terminal_*` precise control.
>
> **opencode-style aliases (additive, back-compatible)**: `executor._normalize_arguments` accepts
> `filePath → file_path`, `oldString/newString → old_text/new_text`, `pattern → query`,
> `glob → include`, `timeout → timeout_ms`; `registry.resolve_name` accepts opencode tool names
> `bash/glob/grep/webfetch/task/todowrite/todoread`. Old names keep working.

## 3. Tool Registration

`BUILTIN_MODULES` in `tools/init.lua` lists the built-in tool modules; `init()` registers them synchronously via
`registry.register_many` (definitions only, no I/O, ensuring readiness before the first Agent request).
`tool_helpers.lua` is the tool-definition helper library and is not part of the built-in list.

Built-in tool modules: `file_ops` / `shell` / `git_ops` / `lsp_ops` / `tree_ops` / `log_ops` / `plan` (sub-agent) /
`todo` / `plan_mode` / `ask_user` / `read_image` / `web_fetch` (web fetch, disabled by default) / `skills` (skill tools + system prompt section).
(The `service` long-lived-service module is no longer registered; background processes are carried by the
session-resident sandbox instance, see `sandbox/execution/resident.lua`.)
MCP remote tools are registered dynamically by `services/mcp/init.lua` (`category = "mcp"`, `source = "mcp"`); see [mcp.md](mcp.md) for details.

## 4. Execution Flow (tools/executor.lua)

The full pipeline of `M.execute(tool_name, raw_args, ctx)`:

```
resolve_name (alias/fuzzy matching)
  → _normalize_arguments (alias mapping, e.g. cmd→command, file→file_path)
  → _expand_path_args (expand ~ / $VAR paths)
  → validator.validate_parameters (schema validation)
  → approval decision validator.check_approval(...)
      ├─ approval required (when applicable) → tool_service.approve_and_execute(...)
      │           (continue_fn resumes after approval; the timer starts only after approval)
      └─ direct execution → _execute_tool(...)
          → sandbox gate sandbox.gate(...) (preflight → isolated execution → freeze candidate → CAS publish)
          → _call_tool (invoke func/execute)
          → timeout based on a pausable timer (waiting for approval/question does not count)
```

> **Sandbox enforcement**: every tool execution goes through `services.sandbox.gate`; the loader
> and registry attach `__sandbox_spec` (effect/paths). The default async review
> (`tools.approval.mode="async"`) executes effectful tools immediately in the sandbox and freezes
> a candidate without blocking; real changes enter a review queue and are applied after async
> confirmation via `:NeoAISandboxReview`. When the sandbox service is missing and
> `fail_closed=true`, execution is rejected. See [sandbox.md](sandbox.md).
>
> **Note**: in `async` (the default) there is **no pre-execution blocking approval** — the "approval
> decision" branch above is skipped and the tool goes straight to the sandbox; whether human
> confirmation is needed is decided afterwards by the sandbox risk level (`sandbox.approval`).
> Exception: if a tool path hits a **masked directory** (even under async) an approval dialog still
> pops up, and approving it unmasks only that single call.

### 4.1 Argument Alias Normalization

`_normalize_arguments` handles common aliases: `cmd→command`, `file/files/filepath→file_path`, `start→start_line`,
`end→end_line`, etc. Plain string arguments (for `read_file` and similar) are converted
directly to `{ file_path = ... }`.

> Note: `new_text` / `text` are **no longer** aliased to `content`. That alias used to make `edit_file`
> misread a "partial replace" as a "whole-file overwrite" (silent overwrite); it has been removed and a
> misplaced argument now errors out instead.

### 4.2 Path Expansion

`_expand_path_args` expands `~` aliases in the `path` / `file_path` / `filepath` / `dirs` / `dir` fields
(`~/...` ↔ home directory), so that paths relative to the home directory can be read and written normally.

### 4.3 Approval Decision (tools/validator.lua, non-async modes)

> Used for the pre-execution decision only when `tools.approval.mode` is `prompt` / `strict`
> (or `auto_allow`); it does not apply under the default `async`.

`validator.check_approval(tool_name, args, approval_config, mode)`:

- `mode == "auto_allow"` → no approval.
- `mode == "strict"` → approval always required.
- `approval_config.auto_allow == true` → no approval.
- **Path safety**: `file_path` falls within `allowed_directories` → safe.
- **Parameter safety**: the first word of `command` falls within `allowed_param_groups` (such as `ls`/`grep`) → safe.
- No path and no command → decided by `auto_allow`.

### 4.4 Timeout (Pausable Timer)

`executor._execute_tool` uses a pausable timer (`utils.timer`) to time out based on **active time**:
it pauses while waiting for approval/question, neither accumulating elapsed time nor consuming timeout budget.
The default timeout is `tools.executor.timeout_ms` (30s), and can be overridden by the tool's own `timeout`
or by `ctx.timeout_ms`.

## 5. Approval Dialog (services/tool_service.lua)

> The default `async` mode **does not take this path**: the tool has already run in the sandbox and
> confirmation happens through the review queue (`:NeoAISandboxReview`). This section describes the
> **pre-execution approval dialog** under `prompt`/`strict` modes, plus fallback cases
> such as masked-directory hits.

Approval is a **serial, single-slot** design: tool execution itself is parallel (issued concurrently by tool_loop),
but "popup confirmation" is serialized — only one approval popup is shown at a time, and the rest queue up
without overwriting one another.

### 5.1 Serial Approval Queue

```
M.execute(agent, name, args, tool_call_id, opts)
  ├─ sub-agent boundary review _review_sub_agent (plan.review_tool_call)
  ├─ plan mode gate plan_mode.check_tool (mutating tools are rejected in plan mode)
  ├─ build ctx (including a pausable timer)
  └─ executor.execute(...)
```

`approve_and_execute`:

- `auto_allow` mode, or the tool already has `allow_all` → execute directly.
- Otherwise it enters `approval_queue`, and `_drain_approval_queue` pops up confirmations one at a time (single slot).
- **Approval timeout fallback**: `tools.approval.timeout_ms` defaults to 60s; on timeout the request is rejected
  rather than hanging forever; once a decision exists (`item.d = nil`), the timeout is void and does not interfere
  with the execution of already-approved tools.

### 5.2 Approval UI

The `tool_approval` component is injected via `tool_service.set_approval_ui(impl)`. Without a UI (headless/testing),
approval is allowed by default and a notify is sent.

## 6. Built-in Tools

### 📁 File Operations (file_ops.lua, blocking I/O goes through a thread pool)

`read_file` / `edit_file` / `list_files` / `search_files` / `file_exists` / `create_directory` /
`ensure_dir` / `delete_file` / `confirm_file_change`.

> `edit_file` has **two strictly mutually exclusive** usages (misuse errors out; it never silently overwrites):
> (1) partial replace — provide an `edits` array, or the top-level `old_text`+`new_text` shorthand for a single
> replacement, and **do not pass `mode`**; (2) whole-file overwrite / append — you **must** pass an explicit
> `mode='write'` (overwrite) or `mode='append'` (append) together with `content`.
> Rules: replace fields together with `mode` → error; `content` without `mode` → error; neither → error;
> `content` together with replace fields → error; top-level `old_text`/`new_text` must come as a pair; `mode`
> only accepts `write`/`append` (synonyms like `replace`/`edit`/`overwrite` are rejected to avoid ambiguity
> with overwrite). `confirm_file_change` works together with `edit_file`:
> the model first sees the "preview" result, then calls `confirm_file_change(action='confirm'/'abandon'/'retry')` to confirm.
> Blocking file I/O (reading large files / recursive search / writing to disk) runs in a thread pool via `utils.work`,
> without occupying the main thread.
>
> **Concurrent edits to the same file are serialized via a file lock**: `tool_loop` fires tool calls in parallel, and
> the replace branch is "read → modify → write"; concurrent edits to the same file would all read the stale content
> and the last writer would clobber the others (lost update). So writes (overwrite/append) and the whole
> "read → modify → write" chain run inside a **cross-process file lock** (`utils.lock`): the key is `edit_file` combined
> with the canonicalized path, and `lock.acquire_async` waits **non-blockingly** (polled via `vim.defer_fn`, never
> blocking the main thread) instead of failing; multiple nvim instances editing the same file are mutually exclusive
> too. The lock is always released (`finally`) once the work finishes (even on error).
>
> **`read_file` large-file protection**: when `start_line`/`end_line` is not specified and the file's character count
> exceeds the threshold (default `tools.read_file.outline_threshold_chars=500`), the full text is not returned;
> instead, a tree-sitter **syntax tree node outline** of the file is returned (parsed from the string via
> `get_string_parser`, without loading a buffer; it prints only structural nodes that have named children,
> subject to `outline_max_nodes`/`outline_max_depth`); when no parser exists for that file type (or parsing fails),
> it returns the file's **head + tail** and **spills the full file content to the sandbox-private `/tmp`** (the path is
> included so the model can read it back in segments via `read_file` `start_line`/`end_line`). Specifying a line range
> bypasses the outline protection, but the slice is still bounded by the **AI-context output cap** described below.

### 💻 Shell (shell.lua)

`run_command`: executes a Shell command. With `tools.run_command.interactive.enabled` (**on by default**) it runs under an **interactive PTY** (`jobstart pty=true`):

- **Goal**: run the command and complete its interactions (`read` input, y/n confirmations, menu choices, passphrases, ...).
- **How to operate**: `command` is required; `timeout_ms` is optional (default 30000, -1 = unlimited; pass a large value such as 120000~600000 for multi-round interaction). While the command awaits input, NeoAI polls `/proc/<pid>/{fd/0,syscall,wchan}` to detect "process blocked reading the terminal" (an OS-level signal, not terminal-text parsing) and uses `/proc/<pid>/io` `rchar` growth to tell consecutive reads apart. Each wait fires a **single-turn LLM request** (the judge) returning `{"action":"text"|"keys"|"kill"|"none",...}` JSON that directly injects text/keys or ends the process; a floating terminal (when the chat cursor is following) mirrors the output for manual typing.
- **Tool-description requirement**: `description` is required and must state the command's **goal and expected inputs** (the judge uses it). The description handed to the model marks it as "interactive" and explains the goal and how to operate.
- With `enabled=false` it falls back to the original non-interactive jobstart path and restores resident-sandbox semantics.

`terminal_send_text` / `terminal_send_keys` / `terminal_kill`: **interactive terminal** control tools.

- **Goal**: while a command awaits input, inject a line of text / send a key sequence (Enter/Tab/Escape/Up/Ctrl-C, ...) / end the process.
- **How to operate**: only operate on an existing PTY session (`effect=in_process`; never spawns a process); normally called automatically by the judge, so the model usually does not need to call them manually unless precise control is required.

The floating terminal window is rendered with `nvim_open_term` by `ui/components/terminal_window.lua` and forwards manual typing when focused; `show_window` controls when it pops up (always/on_wait/never, **all requiring the chat cursor to be following**): `always` pops at session start; `on_wait` pops only after the command has been running longer than `show_window_delay_ms` (default 2000ms) without finishing (a fast command that ends within ~2s never flashes a window). On a follow flip it automatically hides (reviewing earlier content) / re-pops (back at the bottom, for sessions still meeting the respective condition) via `UI_FOLLOW_CHANGED`; every open (first pop or re-pop) renders a **fresh `nvim_open_term` channel**, so the session's accumulated output is **replayed on open** to avoid an empty window (which would look like "it won't open"). **It also does not pop up when focus is not on the NeoAI UI** (the user switched to another window): it waits via `UI_FOCUS_CHANGED` and pops after switching back (see the lifecycle reporting in [sandbox.md](sandbox.md)). See [configuration.md](configuration.md) `tools.run_command.interactive`.
When combined stdout/stderr exceeds `tools.run_command.max_output_bytes` (default 16 MiB), the command is
truncated and terminated so huge outputs (hundreds of MB) cannot freeze the main thread with line-by-line
processing; already-produced content is still returned and marked "truncated".
When a command ends with exit code 137 (SIGKILL), the resource-domain events are read to distinguish
"suspected OOM" from "forcibly terminated".

### ✂️ Tool-output "AI-context cap" (output_guard.lua)

The text returned by `run_command` (all three paths) + read-only `git_*` tools + `read_file` passes through the
`tools.builtin.output_guard.cap` exit guard: when the text exceeds `tools.output_guard.max_chars` (default 20000)
characters, only the **head `head_chars` + a truncation marker + the tail `tail_chars`** are returned, and the
**full output is written to the sandbox-private** `/tmp/<spill_dir>/` (default `/tmp/neoai-out/…`); the marker
gives that path, which the model can read back in segments via `read_file` `start_line`/`end_line`.

- **Separate concerns** from `run_command.max_output_bytes` (the 16 MiB "anti-freeze hard kill" protecting the
  main thread): this cap protects the **model context** and is far smaller (default 20k chars).
- The spill directory is the host-side **session-private directory** bound to the guest `/tmp` (registered in
  `sandbox.guest_fs` by `_append_tmpfs_roots` on bind), so one-shot/resident/exec/lsp paths all land in the same
  directory; `/tmp/…` arguments to `read_file`/`list_files`/`file_exists` are mapped back via `guest_fs.to_host`
  (only when the mapped host file exists, so a real host `/tmp` file is never shadowed).
- The truncation note contains a sandbox path, so it must be appended **after** `conceal.redact`, otherwise it is
  stripped by redaction.
- **Degradation**: with no sandbox (no `/tmp` mapping) the guard only truncates and does not spill, and says so.
- Disable with `tools.output_guard.enabled=false` (one-switch opt-out; only the existing hard caps remain).

### 🔌 Background processes (session-resident sandbox instance)

A `run_command` that ends with a terminal `&` or starts with `nohup`/`setsid` is carried by the
**session-resident sandbox instance** when `tools.sandbox.resident.enabled=true`: commands execute
inside one persistent mount+pid namespace, so background processes survive across tool calls
(visible to `ps`/`kill` within the session), close to normal bash. Command changes are still captured
per call and frozen as candidates for async review. The `service_*` tools are no longer registered
(the AI manages background processes with plain shell); `sandbox.service` is kept only for the
systemctl facade. See the "Session-resident sandbox instance" section of [sandbox.md](sandbox.md).

### 🗂 Git (git_ops.lua)

Read-only: `git_status` / `git_diff` / `git_log` / `git_commit_detail` / `git_branch` /
`git_file_history` / `git_auto_commit_config` (executed in the sandbox namespace, seeing the staged view).

Mutations (run **inside the sandbox**, `effect=process`; changes are **staged atomically into the
review window**): `git_add` / `git_commit` / `git_stash` / `git_restore`. `.git` is a
tightly coupled "index ↔ object store ↔ refs" database, applied atomically in
`object → normal file → pointer` order so nothing ever dangles (see [sandbox.md](sandbox.md)); git
mutation subcommands in `run_command` are refused (`SANDBOX_GIT_MUTATION_VIA_COMMAND`) and must use the
dedicated tools above.

### 🔧 LSP (lsp_ops.lua, Neovim >= 0.12)

`lsp_hover` / `lsp_definition` / `lsp_references` / `lsp_implementation` / `lsp_declaration` /
`lsp_document_symbols` / `lsp_workspace_symbols` / `lsp_code_action` / `lsp_rename` / `lsp_format` /
`lsp_diagnostics` / `lsp_client_info` / `lsp_signature_help` / `lsp_completion` /
`lsp_type_definition` / `lsp_service_info` / `lsp_check`.

> `lsp_ops` has a **request-level timeout** fallback (`tools.lsp.timeout_ms`, default 10s): it fails fast when the
> server does not respond, preventing the tool loop from hanging until the executor timeout.
>
> Files not in any buffer are **auto-opened in a background buffer** (no window switch / layout change): the
> path is `~`-expanded and made absolute, registered-but-unloaded buffers are actually loaded, and files that
> exist only as a sandbox staged copy (AI-created, not yet written to disk) can be opened too. LSP client
> attach is asynchronous, so the tools **wait for it before requesting** (`tools.lsp.attach_timeout_ms`,
> default 3s; on timeout they still issue one request to return an accurate error): this covers both a
> buffer just background-loaded and a buffer whose server may still be starting/restarting (another LSP
> client already exists in the session); a buffer that already timed out once is not waited on again,
> avoiding a false "no LSP client" report.
>
> `lsp_diagnostics` **re-fetches on every call**: pull clients (`textDocument/diagnostic`, sandbox clone
> preferred) are queried directly for the latest diagnostics; when only push clients exist, it forces a
> didChange (content unchanged, no undo entry) so the server re-lints, then waits for `publishDiagnostics`
> before reading the cache (with timeout fallback) instead of returning a stale cache.
>
> **Unified output format** (all `lsp_*` tools share one text convention; line/column are 1-based):
> position tools (`lsp_definition`/`lsp_references`/`lsp_declaration`/`lsp_implementation`/
> `lsp_type_definition`) output `path:line:col`; `lsp_diagnostics` outputs
> `path:line:col [Severity] message` (Severity is `Error`/`Warning`/`Info`/`Hint`); symbol tools output
> `Name (Kind)  path:line:col` (`lsp_document_symbols` nests children by two spaces per depth).
>
> `lsp_check`: **project-wide diagnostics** running the LSP server's **CLI check command** over a
> file/directory/glob (e.g. `lua-language-server --check=.`, see `tools.lsp.check.servers`); independent
> of whether buffers are open, fully recomputed and reproducible. The command runs inside the sandbox
> (reads the staged view, writes never leak) so it is decoupled from the editor LSP's mount/cache state.
> Result reading: lua-language-server writes JSON to `--check_out_path` (stdout carries only the progress
> bar); config uses the `{out}` placeholder pointing to a "sandbox-writable, host-readable" file that the
> tool reads back after exit. stdout progress/ANSI (`Initializing`, `===017/322`, `Diagnosis complete`,
> …) is stripped and never echoed. Parsing tolerates lua-language-server / pyright / generic JSON, and
> extracts JSON from text when needed.
> Params: `path` (file/dir/glob, default cwd), `severity` (minimum level error|warning|information|hint,
> passed to the CLI and also filtered locally), `format` (`summary` (default: file/problem counts +
> per-rule/per-message/per-file breakdown) / `text` (grouped by code) / `json`), `server` (auto-selected),
> `codes`/`exclude_codes` (rule include/exclude), `paths`/`exclude_paths` (path substring or glob
> include/exclude), `limit` (text/json detail cap, default 200), `baseline` (a json output path, or
> `"auto"` to use the cached previous result → report **new/fixed**).
> **Scope consistency**: file/dir/glob all scan the same **workspace root** and then filter, so a single
> file's result equals its result inside a directory run (no order-of-magnitude drift from the CLI's
> single-file vs directory loading differences).
> Output is capped by `output_guard`. If the server config declares `root_files` (e.g. `.luarc.json`) and
> the workspace root lacks them (**detected via the sandbox view**: a just-staged `.luarc.json` counts), a
> **strong warning** is prepended; if `auto_config` is also set (on by default for lua-language-server),
> the check runs with **built-in defaults** (LuaJIT + vim globals), removing the bulk of `undefined-global`
> noise. That temporary config **only affects this sandboxed check and is never written to the workspace**,
> so `file_exists(.luarc.json)` being false is normal; set `auto_config_persist=true` to generate a real,
> pending (staged) file visible to read tools and publishable on approval. On empty results the tool
> **attributes the filter correctly** (severity vs out-of-scope vs code/path).
> `lsp_service_info`/`lsp_client_info` show each client's **workspace root and launch command**; an empty
> root is flagged with "cross-file/type resolution will produce heavy false positives (e.g.
> undefined-global)" plus a fix suggestion.

### 🌳 Tree-sitter (tree_ops.lua)

`parse_file` / `query_tree` / `get_node_at_position` / `get_node_type` / `get_node_range` /
`is_named_node` / `get_parent_node` / `get_child_nodes` / `get_node_code` / `delete_node`.

### 🪵 Logging (log_ops.lua)

`log_message` / `get_log_levels`.

### 🤖 Sub-agent (plan.lua)

`create_sub_agent` / `wait_sub_agent` / `get_sub_agent_status` / `cancel_sub_agent`. See
[sub_agent_system.md](sub_agent_system.md) for details.

### 📋 Todo (todo.lua)

`todo_write` (full-table replacement) / `todo_read` / `todo_clear`. Registers an agent-level system prompt section
`deployment:todos` (order=100) that injects the current task list into every request.

### 📐 Plan Mode (plan_mode.lua)

`enter_plan_mode` (enter plan mode: the tool context switches to read-only/informational + asking questions). Plan mode **does not give the AI any mode-switching tool**; after the plan is emitted the user runs `:NeoAIApprovePlan` (or toggles the mode manually) to confirm execution. See [configuration.md](configuration.md) and [chat_enhanced_usage.md](chat_enhanced_usage.md) for details.

### 💬 Asking the User (ask_user.lua)

`ask_user`: pauses generation to ask the user a question; the answer comes back as the tool result. It emits
`ASK_USER_WAITING`/`ASK_USER_ANSWERED`, and pauses the pausable timer while waiting. Options can be either strings
or `{ label, description }` (label is a short option summary, description is the option description; the two are
displayed separately in the popup and highlighted). Popup keys: digits `1-9` select an option directly,
`i`/Enter opens free-text input; **`<Esc>` cancels only in NORMAL mode** (in INSERT mode `<Esc>` keeps its
original meaning of leaving insert mode, so editing does not accidentally cancel the whole question — to give up,
press `<Esc>` back to NORMAL and then `<Esc>` again). Only one question popup is shown at a time; multiple questions
issued in parallel are queued in order (the next is shown after the previous is answered/cancelled), and they do not
fail outright. **It does not pop up immediately when focus is not on the NeoAI UI**: the config is stashed and it
waits (`ASK_USER_WAITING` is still emitted, so the Herder lifecycle shows `blocked`), then pops once the user
switches back to the NeoAI UI (`UI_FOCUS_CHANGED` focused=true). The same mechanism applies to the blocking
tool-approval (tool_approval), secret-alert (secret_alert) and network-consent (net_consent) popups (see the
"Focus-aware interactive popups" section in [sandbox.md](sandbox.md)).

### 🖼 Images (read_image.lua)

`read_image`: reads PNG/JPEG/WebP/GIF, persists it into attachment storage, and returns a reference. See
[configuration.md](configuration.md) (multimodal).

### 🌐 Web fetch (web_fetch.lua, disabled by default)

`web_fetch`: renders dynamic pages (React/Vue/SPA) in a headless browser, injects JS, takes the final DOM and
converts it to Markdown with a general converter (turndown). **Disabled by default** (`tools.web_fetch.enabled = false`;
while off, `get_tools()` returns nothing — no registration, no dependency install). Once enabled, bash checks and
installs Node deps and the browser engine in the cache dir (`stdpath('cache')/NeoAI/web_fetch`) — **the installation runs
on the host, outside the sandbox**, so hundreds of MB of artifacts never enter the overlay and get re-captured by every
`run_command`; with `auto_install=true` this happens in the background and the first call waits for it. Lua only
orchestrates and never parses dynamic pages itself. Results are cached by URL + args (TTL / entry count / total-size cap default 500MB,
evicting oldest first). Injection scripts are extensible: built-ins in `assets/web_fetch/scripts/*.js`, overridable by
same-named scripts in the user dir (`tools.web_fetch.scripts_dir`). See [configuration.md](configuration.md) (`tools.web_fetch`).

## 7. Tool Output to the Model (tool_loop._tool_definitions)

When tool definitions are output into the request (`core.agent.tool_loop._tool_definitions`):

- Output in lexicographic order by name (deterministic, prefix-cache friendly).
- Empty `properties` omits that field (DeepSeek rejects `[]` schemas).
- Environment detection runs first (`tools.environment.filter_tools`), disabling tools that depend on unavailable
  environments (workspace/git).
- In plan mode, only read-only/informational queries + `run_command` (read-only research) + `ask_user` are kept (`plan_mode.apply_tool_filter`).

## 8. Environment Detection (tools/environment.lua)

- `workspace_available()`: cwd is non-empty and the directory exists.
- `git_available()`: searches upward from cwd for `.git` (directory or file, covering worktrees).
- `filter_tools()`: tools that depend on the git environment (git_*) are disabled when there is no git directory;
  workspace-dependent `list_files`/`search_files` are disabled when there is no cwd.

## 9. Related Documentation

- [ai_engine.md](ai_engine.md): Agent engine (`tool_loop` calls the tool system).
- [sub_agent_system.md](sub_agent_system.md): Sub-agent boundary review.
- [EVENTS.md](EVENTS.md): Tool events (`TOOL_*`, `TOOL_ARG_*`, approval).
