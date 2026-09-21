# NeoAI 事件系统（唯一权威文档）

> [English](en/EVENTS.md) | **中文**

> 本文档是 NeoAI 事件系统的**唯一权威来源**，合并了原先分散在
> `docs/event_system.md`、`docs/NATIVE_EVENTS.md`、`docs/IMPLEMENTED_EVENTS.md`
> 三份文档中的内容。

## 1. 概述

NeoAI 采用 **事件驱动异步架构**，所有模块通过事件总线通信，UI 与业务逻辑解耦。

- **事件命名规范**：`domain:verb`（如 `generation:started`、`stream:chunk`）。
- **传播机制**：基于 Neovim 原生 `User` autocmd（`nvim_exec_autocmds`）。
- **前缀**：触发时自动加 `NeoAI:` 前缀（`generation:started` → `NeoAI:generation:started`），
  避免与其它插件事件冲突。
- **常量注册表**：`NeoAI.kernel.events` 模块集中定义全部事件常量。**禁止硬编码事件字符串**，
  一律通过引用常量触发/订阅。

## 2. 事件总线 API

事件总线的实现位于 `NeoAI.kernel.event_bus`，提供发布/订阅/一次性订阅/全清。

```lua
local event_bus = require("NeoAI.kernel.event_bus")
local events    = require("NeoAI.kernel.events")

-- 订阅事件（回调第一个参数为 payload=args.data）
local unsub = event_bus.on(events.GENERATION_STARTED, function(data)
  print("生成开始:", data.agent_id)
end)

-- 触发事件
event_bus.emit(events.GENERATION_STARTED, { agent_id = "agent_xxx" })

-- 订阅一次（触发后自动取消）
event_bus.once(events.SESSION_CREATED, function(data) print("首次会话创建") end)

-- 取消订阅
unsub()

-- 清空所有订阅（插件卸载/测试）
event_bus.clear_all()
```

也可直接使用原生 autocmd（事件总线内部就是这么做的）：

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "NeoAI:generation:started",
  callback = function(args) print(vim.inspect(args.data)) end,
})
```

> **约定**：`emit(event, payload)` 将 payload 放入 `args.data`；
> 订阅回调签名为 `function(data, args) ... end`，其中 `data` 即 `args.data`。
> 订阅回调内部发生异常会被事件总线捕获并记日志，不会中断其它订阅者。

## 3. 事件常量表

所有事件常量在 `NeoAI.kernel.events` 中定义。按分区列如下。

### Agent 生命周期

| 常量 | 值 | 触发时机 | payload 关键字段 |
| --- | --- | --- | --- |
| `AGENT_CREATED` | `agent:created` | 创建 Agent | `{ agent }` |
| `AGENT_SPAWNED` | `agent:spawned` | 派生子 Agent | `{ parent, agent }` |
| `AGENT_DISPOSED` | `agent:disposed` | 销毁 Agent | `{ agent_id }` |
| `AGENT_ABORTED` | `agent:aborted` | 取消 Agent | `{ agent_id, reason }` |
| `AGENT_STATE_CHANGED` | `agent:state_changed` | 状态切换（idle/generating/tool_running/aborted/error） | `{ agent_id, old, new }` |

### 生成 / 流式

| 常量 | 值 | 触发时机 | payload 关键字段 |
| --- | --- | --- | --- |
| `GENERATION_STARTED` | `generation:started` | 开始生成 | `{ agent_id }` |
| `GENERATION_COMPLETED` | `generation:completed` | 生成完成 | `{ agent_id, message }` |
| `GENERATION_ERROR` | `generation:error` | 生成出错 | `{ agent_id, error }` |
| `GENERATION_CANCELLED` | `generation:cancelled` | 生成取消 | `{ agent_id }` |
| `STREAM_STARTED` | `stream:started` | 流式开始 | — |
| `STREAM_CHUNK` | `stream:chunk` | 流式内容分片 | `{ agent_id }` |
| `STREAM_COMPLETED` | `stream:completed` | 流式完成 | — |
| `STREAM_ERROR` | `stream:error` | 流式出错 | — |

### 推理

| 常量 | 值 | 触发时机 | payload 关键字段 |
| --- | --- | --- | --- |
| `REASONING_STARTED` | `reasoning:started` | 推理开始 | `{ agent_id }` |
| `REASONING_CHUNK` | `reasoning:chunk` | 推理内容分片 | `{ agent_id, chunk, reasoning }` |
| `REASONING_COMPLETED` | `reasoning:completed` | 推理完成 | `{ agent_id }` |

### 消息

| 常量 | 值 | 触发时机 | payload 关键字段 |
| --- | --- | --- | --- |
| `MESSAGE_ADDED` | `message:added` | 添加消息 | `{ agent_id, message }` |
| `MESSAGE_UPDATED` | `message:updated` | 更新消息 | `{ agent_id, message }` |
| `MESSAGE_EDITED` | `message:edited` | 编辑消息 | `{ agent_id, message }` |
| `MESSAGE_DELETED` | `message:deleted` | 删除消息 | `{ agent_id, message }` |
| `MESSAGE_SENT` | `message:sent` | 用户发送消息 | `{ agent_id, content }` |
| `MESSAGE_QUEUED` | `message:queued` | 消息入暂存队列（Agent 正忙时） | `{ agent_id, content }` |
| `MESSAGES_CLEARED` | `messages:cleared` | 清空消息 | — |

### 会话

| 常量 | 值 | 触发时机 | payload 关键字段 |
| --- | --- | --- | --- |
| `SESSION_CREATED` | `session:created` | 创建会话 | `{ session }` |
| `SESSION_LOADED` | `session:loaded` | 加载会话 | `{ session_id }` |
| `SESSION_SAVED` | `session:saved` | 保存会话 | `{ count }` |
| `SESSION_DELETED` | `session:deleted` | 删除会话 | `{ session_id, deleted }` |
| `SESSION_SWITCHED` | `session:switched` | 切换会话 | `{ session_id }` |
| `SESSION_RENAMED` | `session:renamed` | 会话重命名 | `{ session_id }` |
| `SESSION_FORKED` | `session:forked` | 会话分支 | `{ parent_id, child }` |

### 分支 / 树

| 常量 | 值 | 触发时机 | payload 关键字段 |
| --- | --- | --- | --- |
| `BRANCH_CREATED` | `branch:created` | 创建分支 | `{ session_id }` |
| `BRANCH_DELETED` | `branch:deleted` | 删除分支 | `{ session_id }` |
| `TREE_REFRESHED` | `tree:refreshed` | 会话树刷新 | — |

### 工具

| 常量 | 值 | 触发时机 | payload 关键字段 |
| --- | --- | --- | --- |
| `TOOL_LOOP_STARTED` | `tool_loop:started` | 工具循环开始 | `{ agent_id, tool_calls }` |
| `TOOL_LOOP_FINISHED` | `tool_loop:finished` | 工具循环结束 | `{ agent_id, rounds }` |
| `TOOL_LOOP_LIMIT_REACHED` | `tool_loop:limit_reached` | 达到最大轮数（1000） | `{ agent_id, rounds }` |
| `TOOL_LOOP_GUARD_REMINDER` | `tool_loop:guard_reminder` | 护栏注入重复调用提醒 | `{ agent_id, repeats }` |
| `TOOL_EXECUTION_STARTED` | `tool:execution_started` | 单个工具开始执行 | `{ agent_id, name, args, tool_call_id }` |
| `TOOL_EXECUTION_COMPLETED` | `tool:execution_completed` | 单个工具完成 | `{ agent_id, name, result, tool_call_id, duration_ms }` |
| `TOOL_EXECUTION_ERROR` | `tool:execution_error` | 单个工具出错 | `{ agent_id, name, error, tool_call_id, duration_ms }` |
| `TOOL_CALL_DETECTED` | `tool:call_detected` | 检测到工具调用 | `{ agent_id, tool_calls }` |
| `TOOL_RESULT_RECEIVED` | `tool:result_received` | 收到工具结果 | `{ agent_id, message }` |
| `TOOL_RESULT_PRUNED` | `tool:result_pruned` | 压缩前裁剪超长工具结果 | `{ agent_id, tool_name, chars_before, chars_after }` |
| `TOOL_APPROVAL_REQUESTED` | `tool:approval_requested` | 发起工具审批（入队） | `{ tool_name, args, agent_id }` |
| `TOOL_APPROVED` | `tool:approved` | 审批通过 | `{ tool_name, agent_id }` |
| `TOOL_APPROVAL_CANCELLED` | `tool:approval_cancelled` | 审批取消/拒绝 | `{ tool_name, reason, agent_id }` |
| `AUTO_MODE_CHANGED` | `approval_mode:auto_changed` | AUTO 模式（自动允许）切换 | `{ active }` |

> 审批事件携带 `agent_id`，供 Herder 等订阅者区分不同 Agent 的阻塞状态。
> `AUTO_MODE_CHANGED` 的值为 `approval_mode:auto_changed`（注意与名不一致，属既有约定）。

### 用户提问（ask_user）

| 常量 | 值 | 触发时机 | payload 关键字段 |
| --- | --- | --- | --- |
| `ASK_USER_WAITING` | `ask_user:waiting` | 开始等待用户回答（Agent 进入 blocked 候选） | `{ agent_id }` |
| `ASK_USER_ANSWERED` | `ask_user:answered` | 用户回答或取消提问 | `{ agent_id }` |

### 工具参数接收（流式）

| 常量 | 值 | 触发时机 | payload 关键字段 |
| --- | --- | --- | --- |
| `TOOL_ARG_CHUNK` | `tool:arg_chunk` | 模型流式生成工具调用参数时逐片触发 | `{ agent_id, tool_calls }`（当前累积的 tool_calls 快照） |
| `TOOL_ARG_COMPLETED` | `tool:arg_completed` | 参数流结束 | `{ agent_id }` |

> UI 借助这两类事件像思考过程悬浮窗一样实时展示「接收参数」悬浮窗（`tool_args_panel`）。

### 待办 / 计划模式

| 常量 | 值 | 触发时机 | payload 关键字段 |
| --- | --- | --- | --- |
| `TODO_UPDATED` | `todo:updated` | 待办清单更新 | `{ session_id, count, counts }` |
| `PLAN_MODE_CHANGED` | `plan_mode:changed` | 计划模式切换 | `{ agent_id, active }` |

### MCP

| 常量 | 值 | 触发时机 | payload 关键字段 |
| --- | --- | --- | --- |
| `MCP_CONNECTING` | `mcp:connecting` | 开始连接某服务器 | `{ server }` |
| `MCP_READY` | `mcp:ready` | 服务器握手并注册完成 | `{ server, tools }` |
| `MCP_ERROR` | `mcp:error` | 连接/初始化失败 | `{ server, error }` |
| `MCP_DISCONNECTED` | `mcp:disconnected` | 服务器断开 | `{ server }` |
| `MCP_TOOLS_UPDATED` | `mcp:tools_updated` | 工具/资源/提示刷新后注册更新 | `{ server }`（chat_service 据此重绑定当前 Agent 工具集） |

### Skills

| 常量 | 值 | 触发时机 | payload 关键字段 |
| --- | --- | --- | --- |
| `SKILLS_UPDATED` | `skills:updated` | 技能索引热重载 | `{ count }` |

### 模型

| 常量 | 值 | 触发时机 | payload 关键字段 |
| --- | --- | --- | --- |
| `MODELS_UPDATED` | `models:updated` | 模型列表更新 | `{ models }` |
| `MODEL_SWITCHED` | `model:switched` | 切换模型 | `{ agent_id, model }` |
| `MODEL_REFRESH_STARTED` | `models:refresh_started` | 开始刷新模型 | `{ provider }` |
| `MODEL_REFRESH_FAILED` | `models:refresh_failed` | 模型刷新失败 | `{ provider, error }` |

### UI / 窗口

| 常量 | 值 | 触发时机 | payload 关键字段 |
| --- | --- | --- | --- |
| `WINDOW_OPENED` | `window:opened` | 打开窗口 | `{ win_id }` |
| `WINDOW_CLOSED` | `window:closed` | 关闭窗口 | `{ win_id }` |
| `UI_REFRESHED` | `ui:refreshed` | UI 刷新 | — |
| `UI_MODE_CHANGED` | `ui:mode_changed` | UI 模式切换 | `{ mode }` |
| `DISPLAY_MODE_CHANGED` | `display:mode_changed` | 显示模式切换 | `{ name }` |

### 子 Agent

| 常量 | 值 | 触发时机 | payload 关键字段 |
| --- | --- | --- | --- |
| `SUB_AGENT_CREATED` | `sub_agent:created` | 创建子 Agent | `{ sub_agent_id, task }` |
| `SUB_AGENT_UPDATED` | `sub_agent:updated` | 子 Agent 更新 | `{ sub_agent_id, status }` |
| `SUB_AGENT_COMPLETED` | `sub_agent:completed` | 子 Agent 完成 | `{ sub_agent_id }` |
| `SUB_AGENT_ERROR` | `sub_agent:error` | 子 Agent 出错 | `{ sub_agent_id, error }` |
| `SUB_AGENT_RESULT_READY` | `sub_agent:result_ready` | 子 Agent 结果就绪 | `{ sub_agent_id }` |

### 配置 / 生命周期

| 常量 | 值 | 触发时机 | payload 关键字段 |
| --- | --- | --- | --- |
| `CONFIG_LOADED` | `config:loaded` | 配置加载 | `{ config }` |
| `CONFIG_CHANGED` | `config:changed` | 配置变更 | `{ path, old, new }` |
| `PLUGIN_INITIALIZED` | `plugin:initialized` | 插件初始化（当前仅定义、未实际 emit） | — |
| `PLUGIN_SHUTDOWN` | `plugin:shutdown` | 插件关闭 | — |

### 日志

| 常量 | 值 | 触发时机 | payload 关键字段 |
| --- | --- | --- | --- |
| `LOG_MESSAGE` | `log:message` | 记录日志消息 | `{ level, message }` |

### 上下文压缩

| 常量 | 值 | 触发时机 | payload 关键字段 |
| --- | --- | --- | --- |
| `COMPACTION_STARTED` | `compaction:started` | （保留，后台压缩不再发射） | `{ agent_id, estimated_tokens }` |
| `COMPACTION_CHUNK` | `compaction:chunk` | （保留，后台压缩不再发射） | `{ agent_id, reasoning, content }` |
| `COMPACTION_COMPLETED` | `compaction:completed` | 后台压缩完成（写入覆盖层） | `{ agent_id, replaced, summary }` |

### 计划蒸馏

| 常量 | 值 | 触发时机 | payload 关键字段 |
| --- | --- | --- | --- |
| `PLAN_DISTILL_STARTED` | `plan_distill:started` | 开始计划阶段蒸馏 | `{ agent_id }` |
| `PLAN_DISTILL_CHUNK` | `plan_distill:chunk` | 分类摘要流式分片到达 | `{ agent_id, reasoning, content }` |
| `PLAN_DISTILLED` | `plan_distilled` | 蒸馏完成 | `{ agent_id, replaced, summary }` |

> 上下文压缩为**后台异步、不弹窗**：不再发射 `COMPACTION_STARTED` / `COMPACTION_CHUNK`（常量保留），仅发射 `COMPACTION_COMPLETED`。
> 计划蒸馏仍会打开"🧬 计划蒸馏"悬浮窗并发射 `PLAN_DISTILL_STARTED` / `PLAN_DISTILL_CHUNK`。

### 沙箱

| 常量 | 值 | 触发时机 | payload 关键字段 |
| --- | --- | --- | --- |
| `SANDBOX_PREFLIGHT_STARTED` | `sandbox:preflight_started` | 开始预检 | `{ command_id, tool }` |
| `SANDBOX_STAGED` | `sandbox:staged` | 隔离执行完成 | `{ command_id, attempt_id }` |
| `SANDBOX_CANDIDATE_READY` | `sandbox:candidate_ready` | 候选冻结完成 | `{ candidate_digest, command_id }` |
| `SANDBOX_PUBLISH_STARTED` | `sandbox:publish_started` | 开始 CAS 发布 | `{ candidate_digest, command_id }` |
| `SANDBOX_COMMITTED` | `sandbox:committed` | 发布并写回执成功 | `{ candidate_digest, operation_id }` |
| `SANDBOX_DISCARDED` | `sandbox:discarded` | 丢弃候选 | `{ candidate_digest }` |
| `SANDBOX_CONFLICT` | `sandbox:conflict` | CAS 基线冲突 | `{ candidate_digest, reason }` |
| `SANDBOX_RECOVERY_REQUIRED` | `sandbox:recovery_required` | 需人工恢复 | `{ command_id }` |
| `SANDBOX_OUTCOME_UNKNOWN` | `sandbox:outcome_unknown` | 结果不明需对账 | `{ operation_id }` |
| `SANDBOX_REVIEW_ENQUEUED` | `sandbox:review_enqueued` | 候选进入异步待审队列 | `{ change_set_id, candidate_digest, write_set, tool }` |
| `SANDBOX_REVIEW_APPROVED` | `sandbox:review_approved` | 变更单元被批准（未应用） | `{ change_set_id }` |
| `SANDBOX_REVIEW_REJECTED` | `sandbox:review_rejected` | 变更单元被拒绝 | `{ change_set_id, reason }` |
| `SANDBOX_APPLIED` | `sandbox:applied` | 变更单元已 CAS 应用到真实工作区 | `{ change_set_id, operation_id }` |
| `SANDBOX_GRANT_CREATED` | `sandbox:grant_created` | 创建任务授权 | `{ grant_id, scope, operations }` |
| `SANDBOX_GRANT_REVOKED` | `sandbox:grant_revoked` | 撤销任务授权 | `{ grant_id }` |
| `SANDBOX_OUTSIDE_ACCESS` | `sandbox:outside_access` | 越界访问留痕（访问 cwd 之外用户工作目录，非阻塞） | `{ trace_id, path, tool, kind }` |
| `SANDBOX_SYSTEMD_ROUTED` | `sandbox:systemd_routed` | systemctl/journalctl 调用被门面路由到沙箱内长驻服务 | `{ verb, units, ok, command_id }` |
| `SANDBOX_SYSTEMD_UNSUPPORTED` | `sandbox:systemd_unsupported` | 门面明确拒绝不支持的 systemd 语义（不落宿主机） | `{ verb, units, command_id }` |
| `SANDBOX_CONTAINER_PLANNED` | `sandbox:container_planned` | 容器受控计划（命名空间共享 / 受控 socket） | `{ manager, mode, share_namespace, reason, command_id }` |
| `SANDBOX_CONTAINER_UNSUPPORTED` | `sandbox:container_unsupported` | 容器门面拒绝需宿主守护进程/远程/宿主子命令 | `{ manager, sub, reason, command_id }` |

## 4. 事件订阅最佳实践

1. **始终引用常量**：订阅/触发都通过 `NeoAI.kernel.events` 的常量，不要硬编码字符串。
2. **及时清理**：`event_bus.on(...)` 返回取消函数，窗口关闭/agent 销毁时调用，防泄漏。
3. **避免阻塞**：事件回调在 autocmd 上下文执行，不要做耗时 I/O；耗时操作用 `vim.schedule` 延后。
4. **错误隔离**：回调抛异常会被 event_bus 捕获并记日志，不会中断其它订阅者（但最好自己 `pcall`）。
5. **payload 为浅表**：`emit` 的 payload 经 `nvim_exec_autocmds` 深拷贝，**不要依赖对象元表/方法**。
   需要传原对象（如计时器、Agent 实例）时，应直接以闭包/模块级引用传递，而非塞进事件 payload。

## 5. 订阅事件示例

```lua
local event_bus = require("NeoAI.kernel.event_bus")
local events    = require("NeoAI.kernel.events")

-- 订阅生成完成并渲染
event_bus.on(events.GENERATION_COMPLETED, function(data)
  print("Agent", data.agent_id, "完成生成")
end)

-- 订阅工具审批（Herder 用：标记阻塞）
event_bus.on(events.TOOL_APPROVAL_REQUESTED, function(data)
  -- data.agent_id
end)

-- 订阅工具参数流（UI 用：打开接收参数悬浮窗）
event_bus.on(events.TOOL_ARG_CHUNK, function(data)
  -- data.tool_calls → tool_args_panel.show(...)
end)
```
