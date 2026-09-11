# NeoAI 工具系统（v3.0）

> [English](en/tool_system.md) | **中文**

> 工具系统让 AI 通过结构化工具调用接口与编辑器/文件系统交互。工具注册、校验、
> 审批（串行单槽位）、执行、分类，均由本系统完成。Agent 的工具循环经
> `services.tool_service` 调用本系统执行工具。
> 对应源码：`lua/NeoAI/tools/*`、`lua/NeoAI/services/tool_service.lua`。

## 1. 模块结构

| 模块 | 职责 |
| --- | --- |
| `tools/init.lua` | 工具系统入口。`init()` 应用审批配置 + 加载内置工具；`get_tools()` / `execute()` / `reload_tools()`。 |
| `tools/registry.lua` | 工具注册表：注册、查询、别名解析、审批配置管理。 |
| `tools/executor.lua` | 工具执行器：参数规范化 → 校验 → 审批决策 → 执行（异步）+ 基于可暂停计时器的超时。 |
| `tools/validator.lua` | 参数 schema 校验 + 审批决策（路径/参数组安全判断）。 |
| `tools/packer.lua` | 工具按类别分组打包（UI 分类展示）。 |
| `tools/environment.lua` | 工具环境探测（workspace / git 目录），不可用则禁用依赖环境工具。 |
| `tools/builtin/*` | 内置工具实现（见下）。 |

## 2. 工具定义

工具通过 `tool_helpers.define_tool(name, description, params, func, opts)` 构造。工具定义结构：

```lua
{
  name = "read_file",            -- 工具名
  description = "读取文件内容…", -- 描述（给模型）
  parameters = { type = "object", properties = {...}, required = {...} }, -- schema
  func = function(args, on_success, on_error, ctx) ... end, -- 执行函数
  category = "file",             -- 分类（file/system/git/treesitter/lsp/log/agent/mcp/skill）
  source = "builtin",            -- 来源（builtin/mcp；mcp 工具在 executor 中跳过参数别名改写）
  approval = { auto_allow = ... }, -- 审批配置
  timeout = ...                  -- 可选超时（ms）
}
```

> **统一注入 `description` 参数**：`define_tool` 会为所有工具补充一个必填字符串参数 `description`
> （「本次调用目的说明」），除非已存在。供审批与折叠展示使用。

工具定义支持两种执行形式（`executor._call_tool`）：

- **回调风格**：`func(args, on_success, on_error, ctx)`（`arity >= 2`）。
- **返回 Deferred**：`func(args, ctx)` 返回带 `then_` 的对象。

## 3. 工具注册

`tools/init.lua` 的 `BUILTIN_MODULES` 列出内置工具模块，`init()` 时经 `registry.register_many` 同步注册
（仅注册定义，无 I/O，确保首个 Agent 请求前已就绪）。`tool_helpers.lua` 是工具定义辅助库，不入内置清单。

内置工具模块：`file_ops` / `shell` / `git_ops` / `lsp_ops` / `tree_ops` / `log_ops` / `plan`（子 Agent）/
`todo` / `plan_mode` / `ask_user` / `read_image` / `skills`（技能工具 + 系统提示段）。
MCP 远端工具由 `services/mcp/init.lua` 动态注册（`category = "mcp"`，`source = "mcp"`），详见 [mcp.md](mcp.md)。

## 4. 执行流程（tools/executor.lua）

`M.execute(tool_name, raw_args, ctx)` 完整流水线：

```
resolve_name（别名/模糊匹配）
  → _normalize_arguments（别名映射，如 cmd→command、file→filepath）
  → _expand_path_args（展开 ~ / $VAR 路径）
  → validator.validate_parameters（schema 校验）
  → 审批决策 validator.check_approval(...)
      ├─ 需审批 → tool_service.approve_and_execute(...)
      │           （审批通过后 continue_fn 继续，计时器审批后才 start）
      └─ 直接执行 → _execute_tool(...)
          → _call_tool（调用 func/execute）
          → 基于可暂停计时器做超时（等待审批/提问不计入）
```

### 4.1 参数别名规范化

`_normalize_arguments` 处理常见别名：`cmd→command`、`file/files→filepath`、`start→start_line`、
`end→end_line`、`new_text/text→content` 等。简单字符串参数（`read_file` 等）直接转 `{ filepath = ... }`。

### 4.2 路径展开

`_expand_path_args` 对 `path` / `filepath` / `file_path` / `dirs` / `dir` 字段展开 `~` 别名
（`~/...` ↔ 主目录），使相对主目录的路径可正常读写。

### 4.3 审批决策（tools/validator.lua）

`validator.check_approval(tool_name, args, approval_config, mode)`：

- `mode == "auto_allow"` → 不审批。
- `mode == "strict"` → 必审批。
- `approval_config.auto_allow == true` → 不审批。
- **路径安全**：`filepath` 落入 `allowed_directories` → 安全。
- **参数安全**：`command` 首词落入 `allowed_param_groups`（如 `ls`/`grep`）→ 安全。
- 无路径且无命令 → 按 `auto_allow` 决定。

### 4.4 超时（可暂停计时器）

`executor._execute_tool` 用可暂停计时器（`utils.timer`）基于**活跃时间**做超时：
等待审批/提问期间暂停，不累计耗时、不消耗超时预算。超时缺省 `tools.executor.timeout_ms`（30s），
可被工具自带 `timeout` 或 `ctx.timeout_ms` 覆盖。

## 5. 审批（services/tool_service.lua）

审批是**串行单槽位**设计：工具执行本身并行（tool_loop 并发发起），但「弹窗确认」串行化——
一次只展示一个审批弹窗，其余排队，互不覆盖。

### 5.1 串行审批队列

```
M.execute(agent, name, args, tool_call_id, opts)
  ├─ 子 Agent 边界审核 _review_sub_agent（plan.review_tool_call）
  ├─ 计划模式门禁 plan_mode.check_tool（修改类工具在计划模式下驳回）
  ├─ 构造 ctx（含可暂停 timer）
  └─ executor.execute(...)
```

`approve_and_execute`：

- `auto_allow` 模式或该工具已 `allow_all` → 直接执行。
- 否则入 `approval_queue`，`_drain_approval_queue` 逐条弹窗（单槽位）。
- **审批超时兜底**：`tools.approval.timeout_ms` 默认 60s，超时拒绝而不是永久挂起；
  一旦决策（`item.d = nil`）超时即失效，不干扰已批准工具的执行。
- `AUTO` 模式（`toggle_auto_mode`）：自动允许所有工具调用，开启时立刻批批准当前待审批/排队的工具。

### 5.2 审批 UI

`tool_approval` 组件经 `tool_service.set_approval_ui(impl)` 注入。无 UI（headless/测试）时默认允许并 notify。

## 6. 内置工具

### 📁 文件操作（file_ops.lua，阻塞 I/O 走线程池）

`read_file` / `edit_file` / `list_files` / `search_files` / `file_exists` / `create_directory` /
`ensure_dir` / `delete_file` / `confirm_file_change`。

> `edit_file` 支持 `mode='write'/'append'/'edit'`。`confirm_file_change` 配合 `edit_file`：
> 模型先看到「预览」结果，再调 `confirm_file_change(action='confirm'/'abandon'/'retry')` 确认。
> 阻塞式文件 I/O（读大文件/递归搜索/写盘）经 `utils.work` 在线程池执行，不占用主线程。
>
> **`read_file` 大文件保护**：未指定 `start_line`/`end_line` 且文件字符数超过阈值（默认
> `tools.read_file.outline_threshold_chars=500`）时，不返回全文，而返回该文件的 tree-sitter
> **语法树节点大纲**（用 `get_string_parser` 从字符串解析，不加载 buffer）；该文件类型无解析器时
> 回退为「提示 + 前 `outline_preview_lines` 行预览」。大纲仅输出有命名子节点的结构节点，
> 受 `outline_max_nodes`/`outline_max_depth` 限制；指定行范围时不受该保护影响。

### 💻 Shell（shell.lua）

`run_command`：异步 jobstart（非交互），收集 stdout/stderr，支持 `timeout_ms`（默认 30000，-1 不限）。

### 🗂 Git（git_ops.lua）

`git_status` / `git_diff` / `git_log` / `git_commit_detail` / `git_branch` / `git_file_history` /
`git_rollback` / `git_auto_commit_config`。

### 🔧 LSP（lsp_ops.lua，Neovim >= 0.12）

`lsp_hover` / `lsp_definition` / `lsp_references` / `lsp_implementation` / `lsp_declaration` /
`lsp_document_symbols` / `lsp_workspace_symbols` / `lsp_code_action` / `lsp_rename` / `lsp_format` /
`lsp_diagnostics` / `lsp_client_info` / `lsp_signature_help` / `lsp_completion` /
`lsp_type_definition` / `lsp_service_info`。

> `lsp_ops` 有**请求级超时**兜底（`tools.lsp.timeout_ms` 默认 10s）：服务器无响应时快速失败，
> 避免工具循环挂到 executor 超时。

### 🌳 Tree-sitter（tree_ops.lua）

`parse_file` / `query_tree` / `get_node_at_position` / `get_node_type` / `get_node_range` /
`is_named_node` / `get_parent_node` / `get_child_nodes` / `get_node_code` / `delete_node`。

### 🪵 日志（log_ops.lua）

`log_message` / `get_log_levels`。

### 🤖 子 Agent（plan.lua）

`create_sub_agent` / `wait_sub_agent` / `get_sub_agent_status` / `cancel_sub_agent`。详见
[sub_agent_system.md](sub_agent_system.md)。

### 📋 待办（todo.lua）

`todo_write`（整表替换）/ `todo_read` / `todo_clear`。会注册 agent 级系统提示段 `deployment:todos`
（order=100），把当前任务清单注入每次请求。

### 📐 计划模式（plan_mode.lua）

`enter_plan_mode`（进入计划模式：工具上下文切换为只读/信息 + 提问）/ `exit_plan_mode`（用户确认后解析计划为 todo 并转入 CHAT 执行）。详见 [configuration.md](configuration.md) 与 [chat_enhanced_usage.md](chat_enhanced_usage.md)。

### 💬 向用户提问（ask_user.lua）

`ask_user`：暂停生成向用户提问，回答回传为工具结果。发射 `ASK_USER_WAITING`/`ASK_USER_ANSWERED`，
等待期间暂停可暂停计时器。选项既可以是字符串，也可以是 `{ label, description }`（label 为选项简介，
description 为选项描述，二者在弹窗中分别展示并高亮）。同一时刻只展示一个提问弹窗，并行发起的
多次提问按序排队（前一个回答/取消后再展示下一个），不会直接失败。

### 🖼 图像（read_image.lua）

`read_image`：读取 PNG/JPEG/WebP/GIF，持久化进附件存储，返回引用。详见
[configuration.md](configuration.md)（多模态）。

## 7. 工具输出到模型（tool_loop._tool_definitions）

工具定义输出到请求时（`core.agent.tool_loop._tool_definitions`）：

- 按名称字典序输出（确定性，前缀缓存友好）。
- 空 `properties` 不输出该字段（DeepSeek 拒绝 `[]` schema）。
- 先环境探测（`tools.environment.filter_tools`），禁用依赖不可用环境（workspace/git）的工具。
- 计划模式下只保留只读/信息查询 + `ask_user`（`plan_mode.apply_tool_filter`）。

## 8. 环境探测（tools/environment.lua）

- `workspace_available()`：cwd 非空且目录存在。
- `git_available()`：从 cwd 向上查 `.git`（目录或文件，覆盖 worktree）。
- `filter_tools()`：依赖git环境的工具（git_*）无 git 目录则禁用；依赖 workspace 的
  `list_files`/`search_files` 无 cwd 则禁用。

## 9. 相关文档

- [ai_engine.md](ai_engine.md)：Agent 引擎（`tool_loop` 调用工具系统）。
- [sub_agent_system.md](sub_agent_system.md)：子 Agent 边界审核。
- [EVENTS.md](EVENTS.md)：工具事件（`TOOL_*`、`TOOL_ARG_*`、审批）。
