# NeoAI 子 Agent 系统（v4.0）

> [English](en/sub_agent_system.md) | **中文**

> 子 Agent 让主 Agent 通过 `create_sub_agent` 把复杂任务拆给独立会话执行。每个子 Agent 是
> **全新环境、零继承**，拥有独立 AbortSignal、独立持久化子会话与受限工具子集。
> **没有等待工具**：子 Agent 循环自然结束后，其最终正文会自动回传给主 Agent。
> 对应源码：`lua/NeoAI/core/agent/sub_agent.lua`、`lua/NeoAI/tools/builtin/plan.lua`、
> `lua/NeoAI/services/chat_service.lua`、`lua/NeoAI/ui/components/sub_agent_dock.lua`。

## 1. 模块结构

| 模块 | 职责 |
| --- | --- |
| `core/agent/sub_agent.lua` | 子 Agent 的唯一事实来源：注册表 + 生命周期 + 结果回传 + 边界审核。 |
| `tools/builtin/plan.lua` | 调度类工具：`create_sub_agent` / `get_sub_agent_status` / `cancel_sub_agent` / `send_sub_agent_message`（经 `kernel.core_bridge` 委托管理器）。 |
| `services/chat_service.lua` | 注入投递/落盘钩子；把子 Agent 结果回传主 Agent；登记子会话以供切换。 |
| `services/tool_service.lua` | 子 Agent 工具调用边界审核（`sub_agent.review_tool_call`）。 |
| `ui/components/sub_agent_dock.lua` | 子 Agent 状态监控（dock）。 |

## 2. 生命周期

### 2.1 创建（create_sub_agent）

1. 生成 `sub_id`（`sub_<time>_<rand>`），创建一个**独立持久化子会话**
   （`parent_id = 主会话`，`metadata.tags = {"sub_agent"}`，`metadata.name = name`）。
2. `runtime.spawn(parent, { session_id, model, cwd, tools })` 创建全新子 Agent（独立信号、零继承）。
3. 工具子集由 `tools/builtin/plan.lua` 构建：**默认主 Agent 的全部工具，仅排除「Agent 类」工具**
   （`category == "agent"`：调度类 `create_sub_agent`/`get_sub_agent_status`/`cancel_sub_agent`/
   `send_sub_agent_message`、`enter_plan_mode`、`ask_user`、`todo_*`）。
   显式指定 `boundaries.allowed_tools` 时以其为准（同样排除 Agent 类工具）。
4. 发射 `SUB_AGENT_CREATED`；`chat_service` 登记子会话 → Agent 映射（供切换复用运行中的 Agent）。
5. `runtime.run(child, task .. "\n\n" .. final_instruction)` 开始执行。
   `final_instruction` 取 `tools.sub_agent.final_instruction`（默认要求「最后总结你的工作」）。

### 2.2 结果回传（无等待工具）

子 Agent 循环自然结束（无更多工具调用）时：

1. 置状态 `completed`，记录 `result_text`（最终正文）。
2. 持久化子会话，发射 `SUB_AGENT_COMPLETED` + `SUB_AGENT_RESULT_READY`。
3. 经 `chat_service` 注入的 dispatch 钩子把结果投递给主 Agent：
   - 主 Agent 空闲 → 直接注入一条消息并**自动唤醒**主 Agent（起一轮生成）；
   - 主 Agent 忙碌 → 入 pending 队列，在下一轮边界或本轮结束后注入；
   - 主 Agent 已销毁（窗口已关）→ 写回主会话存档，重开会话时可见。

主 Agent 因此无需轮询/等待：它继续自己的工作，子 Agent 完成后结果自动回来。

### 2.3 边界审核（review_tool_call）

子 Agent 每次工具调用经 `tool_service._review_sub_agent` → `sub_agent.review_tool_call`：

- 调度类工具永远驳回。
- `boundaries.allowed_tools` 存在且不含该工具 → 驳回 `[调度 agent 驳回] ...`。
- `boundaries.max_tool_calls` 达到上限 → 驳回。
- 通过则 `sub_agent.track_tool_call` 计数。

> 子 Agent 经 `runtime._run_generation` 以 `is_sub_agent = true` 运行工具循环。
> **审批路由**：`async` 模式（默认）下子 Agent 直接在沙箱执行（越界/跨挂载场景 fail-closed 拒绝）；
> **非 async 模式（`prompt`/`strict`）下子 Agent 的工具审批申请路由到主 Agent**——
> 经 `approval_agent` 把审批归属到主 Agent，用户经审批 UI 决策；实际执行仍使用子 Agent 的
> cwd/沙箱域（`tool_service.execute` 解析 `sub_agent_id` → 父 Agent）。

### 2.4 终止 / 发送消息

- `cancel_sub_agent` → `sub_agent.cancel`：`runtime.abort(child)`，置 `cancelled`，发射 `SUB_AGENT_UPDATED`，持久化。
- `send_sub_agent_message` → `sub_agent.send`：运行中消息在其下一轮注入；已完成的子 Agent 据此续跑一轮。

## 3. 工具列表（主 Agent）

| 工具 | 描述 | 参数说明 |
| --- | --- | --- |
| `create_sub_agent` | 创建子 Agent（后台运行，立即返回；**创建后无需轮询等待**，完成后最终正文自动回传） | `task`（必填）；`name`（可选，简短显示名）；`model`（可选）；`boundaries`（可选）`{allowed_tools, allowed_directories, allowed_commands, max_tool_calls, max_iterations}`；`context`（可选） |
| `get_sub_agent_status` | 查询状态、任务与结果（**正常流程无需调用**，仅用于确认是否仍在运行/是否卡住） | `sub_agent_id`（必填） |
| `cancel_sub_agent` | 终止子 Agent | `sub_agent_id`（必填） |
| `send_sub_agent_message` | 向子 Agent 发送消息（补充指令/追问） | `sub_agent_id`、`message`（均必填） |

> 已移除 `wait_sub_agent`：不再提供等待工具，结果自动回传。
> 子 Agent **不会获得**以上任何调度类工具。
> 默认异步审批（`tools.approval.mode = "async"`）下 `create_sub_agent` 立即在沙箱内执行。

## 4. 状态与事件

`state.subs[sub_id]` 记录 `{ id, name, task, agent_id, session_id, parent_agent_id,
parent_session_id, boundaries, status, result_text, error, started_at, tool_calls }`，
`status` 取值：`running` / `completed` / `error` / `cancelled`。

| 事件 | 触发 |
| --- | --- |
| `SUB_AGENT_CREATED` | 创建子 Agent（含 name/agent_id/session_id） |
| `SUB_AGENT_UPDATED` | 状态更新（取消 / 重新续跑） |
| `SUB_AGENT_COMPLETED` | 完成 |
| `SUB_AGENT_ERROR` | 出错 |
| `SUB_AGENT_RESULT_READY` | 结果就绪（供回传） |

## 5. UI：状态栏与切换

- **winbar**（聊天主窗口顶部）：身份行渲染为 `[CHAT] <model> <state> <子 Agent 名字>`。
  子 Agent 名字平铺；若拼接后**超出聊天窗口宽度**，自动折叠为 `N个子agent正在运行`
  （`services/status.sub_agents_segment`，按窗口宽度自适应）。
- **快捷键** `keymaps.chat.switch_sub_agent`（默认 `<leader>as`）：循环切换并**在新窗口**打开
  一个子 Agent 会话（运行中的子 Agent 会复用活动 Agent，实时查看）。
- **列表弹出窗** `keymaps.chat.sub_agent_list`（默认 `<leader>al`）：在聊天窗口顶部（winbar 显示
  子 Agent 名字处）弹出一个**无边框**悬浮列表，`↑/↓`（k/j）移动光标、`<CR>` 在新窗口进入该
  子 Agent 会话、`q`/`<Esc>` 关闭。浮窗相对聊天窗口定位，窗口尺寸变化时重算几何跟随。
- `sub_agent_dock`：事件驱动的运行状态面板。
- **会话树**：子 Agent 会话（`metadata.tags` 含 `sub_agent`）**不在会话树中显示**，其整支后代
  一并隐藏——它们挂在主会话下（`parent_id` = 主会话），混排进树会与用户分支混淆，且"主会话
  仅有唯一子会话"时点主会话会被单子链顺延误入子 Agent 会话。会话树的分支顺延
  （`session_store.get_downstream(id, {skip_sub_agent=true})`）与上下文拼接
  （`chat_service._build_chain_messages`）同样跳过子 Agent 会话，保证主会话始终落在用户对话
  主线上。子 Agent 的查看入口是状态栏 / `switch_sub_agent` / `sub_agent_list` 浮窗（见上）。
  重开子 Agent 会话时据标签识别（标记 `_sub_agent_session`，只给非 Agent 类工具，且只载入
  其自身消息、不拼接祖先链）。
- **聊天界面**：子 Agent 回传的结果消息**不作为用户消息渲染**，而是像工具调用一样渲染为
  可折叠块（首行 `✅ 子 Agent: <名字>`，含任务与正文），并随会话持久化。

## 6. 示例

```lua
-- 主 Agent 发起（后台运行，无需等待）
create_sub_agent({ task = "分析 README.md 的架构树", name = "README 架构" })

-- 查询状态
get_sub_agent_status({ sub_agent_id = "sub_abc" })

-- 追问 / 补充指令
send_sub_agent_message({ sub_agent_id = "sub_abc", message = "再补充依赖关系" })

-- 终止
cancel_sub_agent({ sub_agent_id = "sub_abc" })
```

## 7. 相关文档

- [ai_engine.md](ai_engine.md)：`runtime.spawn` / `runtime.run` 生成流程。
- [tool_system.md](tool_system.md)：工具边界审核、`boundaries` 约束。
- [EVENTS.md](EVENTS.md)：子 Agent 事件。
- [configuration.md](configuration.md)：`tools.sub_agent.final_instruction`、`keymaps.chat.switch_sub_agent`。
