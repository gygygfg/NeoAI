# NeoAI 子 Agent 系统（v3.0）

> [English](en/sub_agent_system.md) | **中文**

> 子 Agent 让 AI 通过 `create_sub_agent` 把复杂任务拆给独立沙箱执行。每个子 Agent 是
> **全新环境、零继承**，拥有独立的 AbortSignal 与工具子集，在边界约束（allowed_tools /
> allowed_directories / max_tool_calls 等）内运行。
> 对应源码：`lua/NeoAI/core/agent/runtime.lua`、`lua/NeoAI/tools/builtin/plan.lua`、
> `lua/NeoAI/ui/components/sub_agent_dock.lua`。

## 1. 模块结构

| 模块 | 职责 |
| --- | --- |
| `core/agent/runtime.lua` | Agent 运行时。`spawn(parent, override)` 派生子 Agent（全新环境）。 |
| `tools/builtin/plan.lua` | 子 Agent 工具：`create_sub_agent` / `wait_sub_agent` / `get_sub_agent_status` / `cancel_sub_agent`；边界审核、调用计数、前台等待。 |
| `services/tool_service.lua` | 子 Agent 工具调用边界审核（`plan.review_tool_call`）。 |
| `ui/components/sub_agent_dock.lua` | 子 Agent 状态监控（dock）。 |

## 2. 子 Agent 生命周期

### 2.1 创建（create_sub_agent）

```lua
plan_tools.create_sub_agent = helpers.define_tool(
  "create_sub_agent",
  "创建子 Agent 执行独立子任务。task 必填；mode 可选 'background'（默认，立即返回）或 'foreground'（等待子 Agent 完成后返回完整结果）；boundaries 可选约束。",
  ...)
```

流程：

1. 生成 `sub_id`（`sub_<time>_<rand>`），记录到 `state.sub_agents[sub_id]`。
2. 调用 `runtime.spawn(parent_agent, { task, model, scenario="agent" })` 创建全新子 Agent。
3. **边界约束**：`boundaries.allowed_tools` 决定工具子集（`_allowed_tools`）；未指定时默认只读工具。
4. 发射 `SUB_AGENT_CREATED`。
5. `runtime.run(sub_agent, task)` 开始执行；完成/失败时分别发射
   `SUB_AGENT_COMPLETED` / `SUB_AGENT_ERROR` + `SUB_AGENT_RESULT_READY`。
6. `mode == "foreground"`：调用 `M.wait(sub_id)` 等待并返回完整结果；否则立即返回「已创建」。

### 2.2 执行

子 Agent 经 `runtime.run(sub_agent, task)` 走与主 Agent 相同的生成流程（含工具循环 `tool_loop`）。
每个子 Agent 拥有独立的 AbortSignal（`child.signal = async.create_signal()`），不继承父信号。

### 2.3 工具子集（_allowed_tools）

```lua
function M._allowed_tools(allowed_tools)
  if allowed_tools and #allowed_tools > 0 then
    -- 用允许列表（从 registry 取定义）
  else
    -- 默认只读工具：read_file / list_files / search_files / file_exists /
    -- log_message / get_log_levels / git_status / git_diff / git_log /
    -- lsp_diagnostics / parse_file / get_node_code
  end
end
```

### 2.4 边界审核（review_tool_call）

子 Agent 每次工具调用经 `services/tool_service._review_sub_agent` → `plan.review_tool_call`：

- `boundaries.allowed_tools` 存在且不含该工具 → 驳回 `"[调度 agent 驳回] 工具 'x' 的调用被拒绝"`。
- `boundaries.max_tool_calls` 达到上限 → 驳回 `"已达到最大工具调用次数"`。
- 通过则 `plan.track_tool_call(sub_id)` 计数。

### 2.5 前台等待（wait）

`M.wait(sub_id)` 返回 Deferred：若子 Agent 已处于终态（completed/error/cancelled）立即 resolve；
否则订阅 `SUB_AGENT_COMPLETED` / `SUB_AGENT_ERROR` / `SUB_AGENT_UPDATED(cancelled)` 事件等待。
`wait_sub_agent` 工具就是该语义的封装（前台等待完整结果）。

### 2.6 取消（cancel_sub_agent）

`runtime.abort(sub, "user_cancelled")` 取消子 Agent，置状态 `cancelled`，发射 `SUB_AGENT_UPDATED`。

## 3. 工具列表

| 工具 | 描述 | 默认审批 |
| --- | --- | --- |
| `create_sub_agent` | 创建子 Agent；`mode` 可选 background/foreground；`boundaries` 可选约束（allowed_tools / allowed_directories / allowed_commands / max_tool_calls / max_iterations）；`context` 可选 | ❌ 需审批 |
| `wait_sub_agent` | 等待子 Agent 完成并返回完整结果；若已完成则立即返回 | ❌ 需审批 |
| `get_sub_agent_status` | 查询子 Agent 状态与结果 | ✅ 自动允许 |
| `cancel_sub_agent` | 取消子 Agent | ✅ 自动允许 |

> `create_sub_agent` 与 `wait_sub_agent` 默认需审批（`auto_allow=false`，无 `timeout` 时按
> `tools.executor.timeout_ms` 兜底；`create_sub_agent` 设定了 `timeout = -1` 表示不限）。

## 4. 子 Agent 状态与事件

`state.sub_agents[sub_id]` 记录 `{ id, agent_id, task, boundaries, status, started_at, tool_calls, context }`，
`status` 取值：`running` / `completed` / `error` / `cancelled`。

子 Agent 事件（详见 [EVENTS.md](EVENTS.md)）：

| 事件 | 触发 |
| --- | --- |
| `SUB_AGENT_CREATED` | 创建子 Agent |
| `SUB_AGENT_UPDATED` | 子 Agent 状态更新（如取消） |
| `SUB_AGENT_COMPLETED` | 子 Agent 完成 |
| `SUB_AGENT_ERROR` | 子 Agent 出错 |
| `SUB_AGENT_RESULT_READY` | 结果就绪（供主 Agent 回传） |

## 5. UI 监控（sub_agent_dock）

子 Agent 状态通过 `sub_agent_dock` 监控（`ui/init.lua` 调用 `sub_agent_dock.init()`），在 UI 上展示
各子 Agent 的进行/完成/出错状态。

## 6. 示例

```lua
-- 在对话中让 AI 发起：后台子 Agent
create_sub_agent({
  task = "分析 README.md 的架构树",
  mode = "background",
  boundaries = { allowed_tools = { "read_file", "list_files", "search_files" } },
})

-- 前台等待结果（会阻塞到子 Agent 完成）
wait_sub_agent({ sub_agent_id = "sub_abc" })

-- 查询状态
get_sub_agent_status({ sub_agent_id = "sub_abc" })

-- 取消
cancel_sub_agent({ sub_agent_id = "sub_abc" })
```

## 7. 相关文档

- [ai_engine.md](ai_engine.md)：`runtime.spawn` / `runtime.run` 生成流程。
- [tool_system.md](tool_system.md)：工具边界审核、`boundaries` 约束。
- [EVENTS.md](EVENTS.md)：子 Agent 事件。
