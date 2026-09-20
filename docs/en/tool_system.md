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

## 3. Tool Registration

`BUILTIN_MODULES` in `tools/init.lua` lists the built-in tool modules; `init()` registers them synchronously via
`registry.register_many` (definitions only, no I/O, ensuring readiness before the first Agent request).
`tool_helpers.lua` is the tool-definition helper library and is not part of the built-in list.

Built-in tool modules: `file_ops` / `shell` / `git_ops` / `lsp_ops` / `tree_ops` / `log_ops` / `plan` (sub-agent) /
`todo` / `plan_mode` / `ask_user` / `read_image` / `web_fetch` (web fetch, disabled by default) / `skills` (skill tools + system prompt section) /
`service` (long-lived services: `service_start`/`service_logs`/`service_status`/`service_stop`).
MCP remote tools are registered dynamically by `services/mcp/init.lua` (`category = "mcp"`, `source = "mcp"`); see [mcp.md](mcp.md) for details.

## 4. Execution Flow (tools/executor.lua)

The full pipeline of `M.execute(tool_name, raw_args, ctx)`:

```
resolve_name (alias/fuzzy matching)
  → _normalize_arguments (alias mapping, e.g. cmd→command, file→filepath)
  → _expand_path_args (expand ~ / $VAR paths)
  → validator.validate_parameters (schema validation)
  → approval decision validator.check_approval(...)
      ├─ approval required → tool_service.approve_and_execute(...)
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

### 4.1 Argument Alias Normalization

`_normalize_arguments` handles common aliases: `cmd→command`, `file/files→filepath`, `start→start_line`,
`end→end_line`, `new_text/text→content`, etc. Plain string arguments (for `read_file` and similar) are converted
directly to `{ filepath = ... }`.

### 4.2 Path Expansion

`_expand_path_args` expands `~` aliases in the `path` / `filepath` / `file_path` / `dirs` / `dir` fields
(`~/...` ↔ home directory), so that paths relative to the home directory can be read and written normally.

### 4.3 Approval Decision (tools/validator.lua)

`validator.check_approval(tool_name, args, approval_config, mode)`:

- `mode == "auto_allow"` → no approval.
- `mode == "strict"` → approval always required.
- `approval_config.auto_allow == true` → no approval.
- **Path safety**: `filepath` falls within `allowed_directories` → safe.
- **Parameter safety**: the first word of `command` falls within `allowed_param_groups` (such as `ls`/`grep`) → safe.
- No path and no command → decided by `auto_allow`.

### 4.4 Timeout (Pausable Timer)

`executor._execute_tool` uses a pausable timer (`utils.timer`) to time out based on **active time**:
it pauses while waiting for approval/question, neither accumulating elapsed time nor consuming timeout budget.
The default timeout is `tools.executor.timeout_ms` (30s), and can be overridden by the tool's own `timeout`
or by `ctx.timeout_ms`.

## 5. Approval (services/tool_service.lua)

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
- `AUTO` mode (`toggle_auto_mode`): automatically allows all tool calls; when enabled, it immediately approves the
  tools currently awaiting approval or queued.

### 5.2 Approval UI

The `tool_approval` component is injected via `tool_service.set_approval_ui(impl)`. Without a UI (headless/testing),
approval is allowed by default and a notify is sent.

## 6. Built-in Tools

### 📁 File Operations (file_ops.lua, blocking I/O goes through a thread pool)

`read_file` / `edit_file` / `list_files` / `search_files` / `file_exists` / `create_directory` /
`ensure_dir` / `delete_file` / `confirm_file_change`.

> `edit_file` supports `mode='write'/'append'/'edit'` (when `mode` is omitted it is inferred from the
> fields: `content` → `write`, `edits` → `edit`). `confirm_file_change` works together with `edit_file`:
> the model first sees the "preview" result, then calls `confirm_file_change(action='confirm'/'abandon'/'retry')` to confirm.
> Blocking file I/O (reading large files / recursive search / writing to disk) runs in a thread pool via `utils.work`,
> without occupying the main thread.
>
> **`read_file` large-file protection**: when `start_line`/`end_line` is not specified and the file's character count
> exceeds the threshold (default `tools.read_file.outline_threshold_chars=500`), the full text is not returned;
> instead, a tree-sitter **syntax tree node outline** of the file is returned (parsed from the string via
> `get_string_parser`, without loading a buffer); when no parser exists for that file type, it falls back to
> "a hint + a preview of the first `outline_preview_lines` lines". The outline only prints structural nodes that have
> named children, subject to `outline_max_nodes`/`outline_max_depth`; specifying a line range bypasses this protection.

### 💻 Shell (shell.lua)

`run_command`: async jobstart (non-interactive), collects stdout/stderr, supports `timeout_ms` (default 30000, -1 for unlimited).
When combined stdout/stderr exceeds `tools.run_command.max_output_bytes` (default 16 MiB), the command is
truncated and terminated so huge outputs (hundreds of MB) cannot freeze the main thread with line-by-line
processing; already-produced content is still returned and marked "truncated".
When a command ends with exit code 137 (SIGKILL), the resource-domain events are read to distinguish
"suspected OOM" from "forcibly terminated".

### 🔌 Long-lived services (service.lua)

`service_start` (start a background persistent process that survives across tool calls) / `service_logs` /
`service_status` / `service_stop`. Unlike `run_command`'s `&`/nohup (reaped when the command ends), a
service runs in its own sandbox overlay + cgroup; on stop its workspace changes are frozen as candidates
and queued for async review. Its lifecycle is reclaimed by `sandbox.shutdown`/`reset`. See the
"Long-lived services" section of [sandbox.md](sandbox.md).

### 🗂 Git (git_ops.lua)

`git_status` / `git_diff` / `git_log` / `git_commit_detail` / `git_branch` / `git_file_history` /
`git_rollback` / `git_auto_commit_config`.

### 🔧 LSP (lsp_ops.lua, Neovim >= 0.12)

`lsp_hover` / `lsp_definition` / `lsp_references` / `lsp_implementation` / `lsp_declaration` /
`lsp_document_symbols` / `lsp_workspace_symbols` / `lsp_code_action` / `lsp_rename` / `lsp_format` /
`lsp_diagnostics` / `lsp_client_info` / `lsp_signature_help` / `lsp_completion` /
`lsp_type_definition` / `lsp_service_info`.

> `lsp_ops` has a **request-level timeout** fallback (`tools.lsp.timeout_ms`, default 10s): it fails fast when the
> server does not respond, preventing the tool loop from hanging until the executor timeout.

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
displayed separately in the popup and highlighted). Only one question popup is shown at a time; multiple questions
issued in parallel are queued in order (the next is shown after the previous is answered/cancelled), and they do not
fail outright.

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
