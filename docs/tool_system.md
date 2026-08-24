# Tool System Architecture

The tool system enables AI to interact with the editor and filesystem through
a structured tool-calling interface. Tools are registered, validated, executed
with approval, and grouped by category for organized display.

## Module Structure

**tools/init.lua:**

- Entry point, initializes all tool sub-modules
  - `init()`: Apply approval config + lazily load built-in tools
  - `get_tools()`: List all registered tools
  - `execute_tool(tool_name, args)`: Execute a tool (via executor)
  - `reload_tools()`: Reload built-in tools (debug)

**tools/registry.lua:**

- Central registry for tool definitions
  - `register(tool)`: Register tool with validation
  - `get(tool_name)`: Get tool definition
  - `list(category)`: List tools, optionally filtered by category
  - `list_as_map()`: List as name → def map (for Agent binding)
  - `search(query)`: Search tools by name/description/category
  - `resolve_name(raw)`: Resolve aliases/fuzzy names
  - `get_approval_config(tool_name)`: Get approval configuration
  - `apply_approval_config(per_tool)`: Apply user approval overrides

**tools/executor.lua:**

- Tool execution engine
  - `execute(tool_name, args, ctx)`: Main exec (normalize + validate + approve + run)
  - `_normalize_arguments`: Alias mapping + simplified format conversion
  - Timeout management with settled-flag pattern

**tools/validator.lua:**

- Tool validation
  - `validate_tool(tool_def)`: Validate tool definition structure
  - `validate_parameters(parameters, args)`: Validate parameters against schema
  - `check_approval(tool_name, args, config, mode)`: Check if approval needed
  - `is_path_allowed(filepath, dirs)`: Path safety check
  - `is_params_safe(args, groups)`: Parameter safety check

**tools/packer.lua:**

- Tool pack grouping
  - `group_by_pack(tool_calls)`: Group tool calls by category
  - `get_pack_for_tool(tool_name)`: Get pack name for tool
  - `get_all_packs()`: List all packs sorted by order

**tools/approval_handler.lua:**

- Tool approval workflow
  - `enqueue(item)`: Add tool to approval queue
  - `process_queue()`: Show approval dialog for next item
  - `pause_timer()` / `resume_timer()`: Pause/resolve tool timeout during approval
  - UI rendering: Floating window with tool info and action keys

**tools/approval_state.lua:**

- Shared approval state
  - `get_tool_config(tool_name)`: Get runtime approval config
  - `set_tool_config(tool_name, config)`: Set runtime config
  - `set_allow_all(tool_name)`: Mark tool as "always allow"

## Built-in Tools

**file_ops.lua (category: file):**

- `read_file(filepath, start_line, end_line)`: Read file contents
- `edit_file(filepath, edits, mode, explanation)`: Edit file with structured edits
- `list_files(query, max_results)`: Search files by glob pattern
- `search_files(query, include_pattern)`: Text search in workspace
- `file_exists(filepath)`: Check if file exists
- `create_directory(filepath)`: Create directory
- `ensure_dir(filepath)`: Ensure directory exists
- `delete_file(filepath)`: Delete file
- `confirm_file_change(action)`: Confirm/abandon file write

**log_ops.lua (category: log):**

- `log_message(message, level)`: Log a message
- `get_log_levels()`: Get available log levels

**tree_ops.lua (category: treesitter):**

- `parse_file(filepath)`: Parse file with treesitter
- `query_tree(filepath, query)`: Query AST with pattern
- `get_node_at_position(filepath, line, col)`: Get node at position
- `get_node_type(node)`: Get node type
- `get_node_range(node)`: Get node range
- `is_named_node(node)`: Check if named node
- `get_parent_node(node)`: Get parent node
- `get_child_nodes(node)`: Get child nodes
- `get_node_code(node)`: Get node source code
- `delete_node(filepath, node)`: Delete AST node

**lsp_ops.lua (category: lsp):**

- `lsp_hover(filepath, line, col)`: Hover information
- `lsp_definition(filepath, line, col)`: Go to definition
- `lsp_references(filepath, line, col)`: Find references
- `lsp_implementation(filepath, line, col)`: Find implementations
- `lsp_declaration(filepath, line, col)`: Go to declaration
- `lsp_document_symbols(filepath)`: Document symbols
- `lsp_workspace_symbols(query)`: Workspace symbols
- `lsp_code_action(filepath, line, col)`: Code actions
- `lsp_rename(filepath, line, col, new_name)`: Rename symbol
- `lsp_format(filepath)`: Format document
- `lsp_diagnostics(filepath)`: Get diagnostics
- `lsp_client_info()`: LSP client info
- `lsp_signature_help(filepath, line, col)`: Signature help
- `lsp_completion(filepath, line, col)`: Completions
- `lsp_type_definition(filepath, line, col)`: Type definition
- `lsp_service_info()`: LSP service info

**shell.lua (category: system):**

- `run_command(cmd, flag)`: Run shell command (async)

**plan.lua (category: agent):**

- `create_sub_agent(task, boundaries)`: Create sub-agent
- `get_sub_agent_status(sub_agent_id)`: Get sub-agent status
- `cancel_sub_agent(sub_agent_id)`: Cancel sub-agent
- `review_tool_call(sub_agent_id, tool_call)`: Boundary enforcement
- `get_summary(sub_agent_id)`: Get sub-agent execution summary
- `cleanup_sub_agent(sub_agent_id)`: Clean up sub-agent state

**tool_helpers.lua:**

- Utility functions used by other tool modules
- `define_tool(name, desc, params, func, opts)`: Tool definition builder

## Tool Approval Workflow

The approval system uses a three-tier check:

1. **Allow-all check:**
   - If user selected "Allow All" for this tool (via approval_state),
     execution proceeds without dialog

2. **Path safety AND parameter safety check:**
   - Path safety: Tool arguments reference files in allowed_directories
   - Parameter safety: Tool arguments match allowed_param_groups
   - Both safe: auto-execute without dialog
   - Either unsafe: show approval dialog

3. **Approval dialog:**
   - Shows tool name, description, and arguments
   - User actions: confirm (once), confirm all, cancel, cancel with reason
   - Timer paused during approval (`approval_handler.pause_timer`)
   - Timer resumed after approval (`approval_handler.resume_timer`)

Approval configuration:

- `default_auto_allow`: Global default (false = require approval)
- `tool_overrides`: Per-tool overrides
- `allowed_directories`: Safe directory patterns
- `allowed_param_groups`: Safe parameter value patterns

## Parameter Normalization

The `tool_executor._normalize_arguments()` function handles:

**Tool name aliases:**

```text
"read" -> "read_file", "cat" -> "read_file"
"write" -> "edit_file", "edit" -> "edit_file"
"list" -> "list_files", "ls" -> "list_files"
"search" -> "search_files", "grep" -> "search_files"
"delete" -> "delete_file", "rm" -> "delete_file"
"mkdir" -> "create_directory"
"cmd" -> "run_command"
```

**Parameter name aliases:**

```text
"cmd" -> "command"
"file" -> "filepath", "files" -> "filepath"
"dir" -> "dirs", "dir_path" -> "dirs"
"start" -> "start_line", "end" -> "end_line"
```

**Simplified format conversion:**

- `file="foo.lua"` → `filepath={{filepath="foo.lua"}}`
- Inherits related fields (start_line, end_line, content, etc.)

**JSON repair:**

- Truncated JSON strings are repaired (add missing quotes/braces)
- Non-standard key:value format parsed as fallback

## Tool Timeout Management

Timeout configuration:

- Global default: 30 seconds (configurable via `tool_timeout_ms`)
- Per-tool override: `tool_def.timeout` field
- `-1` = no timeout (used by run_command for interactive commands)

Timeout lifecycle:

1. `_set_timeout()` starts timer when tool execution begins
2. `_pause_timeout()` pauses timer during approval dialog
3. `_resume_timeout()` resumes with remaining time
4. `_clear_timeout()` cancels timer on completion/error
5. `_reset_timeout()` replaces timer with new duration
