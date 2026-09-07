# NeoAI 工具循环引擎深度分析（v3.0）

> 本文档分析 v3.0 的工具调用循环（`core/agent/tool_loop.lua`）及其与审批、护栏、超时的交互。
> 旧版 `core/ai/tool_cycle.lua` / `tool_executor.lua` / `approval_handler.lua` 等已删除，
> 对应职责由 `core/agent/tool_loop.lua` + `services/tool_service.lua` + `tools/*` 继承。

## 目录

1. [架构概览](#1-架构概览)
2. [核心流程](#2-核心流程)
3. [CPU 占用与性能](#3-cpu-占用与性能)
4. [内存与状态管理](#4-内存与状态管理)
5. [审批与工具循环的交互](#5-审批与工具循环的交互)
6. [潜在问题与设计取舍](#6-潜在问题与设计取舍)

---

## 1. 架构概览

### 文件结构（v3.0）

```
lua/NeoAI/
├── core/agent/
│   ├── agent.lua          # Agent 对象（状态机 + 私有消息队列 + AbortSignal）
│   ├── runtime.lua        # 运行时（create/spawn/dispose/abort/run）
│   ├── tool_loop.lua      # 工具调用循环（本文分析对象）
│   ├── stream.lua         # 流式处理（含工具参数流式累积）
│   ├── prefix.lua         # 前缀缓存身份一致性
│   ├── guard.lua          # 工具循环护栏（重复调用提醒）
│   └── request.lua        # 请求构建/发送/重试
├── services/
│   └── tool_service.lua   # 审批（串行单槽位）+ 调度 + 执行
├── tools/
│   ├── executor.lua       # 参数规范化/校验/审批决策/执行+超时
│   ├── registry.lua       # 工具注册表
│   └── builtin/*          # 内置工具
└── utils/
    ├── async.lua          # Promise/Deferred/AbortSignal
    ├── timer.lua          # 可暂停计时器
    └── work.lua           # 线程池（阻塞式 I/O）
```

### 事件驱动架构

```
TOOL_LOOP_STARTED (tool_loop.run)
      │
      ├─ 并行执行 _execute_single（每个工具一个 Deferred）
      │      ├─ TOOL_EXECUTION_STARTED
      │      ├─ tool_service.execute → executor.execute
      │      │      ├─ 别名解析 → 参数规范化 → 路径展开 → schema 校验
      │      │      ├─ 审批决策（validator.check_approval）
      │      │      │      ├─ 需审批 → approve_and_execute（串行弹窗）
      │      │      │      └─ 直接执行 → _execute_tool（可暂停计时器超时）
      │      └─ TOOL_EXECUTION_COMPLETED / _ERROR
      │
      ├─ async.all(promises) 全部完成
      │      └─ 按原始顺序 add_tool_result 写回消息队列
      │             └─ TOOL_RESULT_RECEIVED
      │
      ├─ guard.check_round（重复调用提醒）
      │      └─ 有提醒 → add_message("user", reminder) + TOOL_LOOP_GUARD_REMINDER
      │
      ├─ set_state("generating") + TOOL_LOOP_FINISHED
      │
      └─ _send_round（请求下一轮，持久流处理器）
             ├─ 有工具调用 → 循环
             └─ 无工具调用 → 若末条是 tool 写 EMPTY_RESPONSE_MESSAGE → 结束
```

---

## 2. 核心流程

### 2.1 工具循环入口（tool_loop.run）

`tool_loop.run(agent, tool_calls, tool_service, opts)` 主循环 `_loop()`：

- 每轮检查 `signal:aborted()` → 循环取消。
- 轮数超过 `MAX_ROUNDS(1000)` → 写 `LOOP_LIMIT_MESSAGE`（不弹 notify，经 `MESSAGE_ADDED` 直接可见）
  + 发射 `TOOL_LOOP_LIMIT_REACHED`，结束。
- 无工具调用 → resolve。
- `set_state("tool_running")` + `TOOL_LOOP_STARTED`。

### 2.2 单工具执行（_execute_single）

```lua
local function _execute_single(agent, tool_call, tool_service, opts)
  -- 1. 解析 tool_call 的 arguments JSON（尝试修复残缺 JSON）
  -- 2. 创建可暂停计时器（utils.timer）
  -- 3. 以原对象注册到 fold（set_live_timer，供 UI 实时读取活跃耗时）
  -- 4. TOOL_EXECUTION_STARTED
  -- 5. tool_service.execute(...) → Deferred
  -- 6. 完成/失败 → TOOL_EXECUTION_COMPLETED/_ERROR（含 duration_ms）
end
```

工具调用**并行执行**（每个一个 Deferred），但结果在 `async.all` 完成后**统一按原始顺序写回**
消息队列（`_execute_single` 不直接写入），保证 tool 消息顺序与 assistant 的 `tool_calls` 一致。

### 2.3 工具定义输出（_tool_definitions）

- 按名称**字典序**输出（确定性，前缀缓存友好）。
- 空 `properties` 不输出该字段（DeepSeek 拒绝 `[]` schema）。
- 先环境探测（`tools.environment.filter_tools`），禁用依赖不可用环境的工具。
- 计划模式只保留只读/信息查询 + `ask_user`（`plan_mode.apply_tool_filter`）。

---

## 3. CPU 占用与性能

### 3.1 渲染合并（chat_view 侧）

`chat_view` 把同一 tick 内多次分片/事件合并为一次渲染（`_schedule_render`），
避免逐片全量重渲染 + `zxzM` 折叠重算卡主线程。工具执行期间每秒（`TOOL_TICK_MS=1000`）
刷新折叠文本耗时。

### 3.2 工具循环内的异步调度

工具经 `tool_service.execute` 执行，阻塞式 I/O 在 `utils.work` 线程池跑（不占用主线程）。
审批在 `tool_service` 内**串行化**（单槽位弹窗，其余排队），并发启动不会让弹窗互相覆盖。

### 3.3 折叠耗时刷新

工具执行期间 `chat_view` 每秒重渲染折叠文本，让耗时实时跳动。`fold.has_running()` 为 false 时
停止刷新。耗时基于 `utils.timer` 的**活跃时间**（剔除审批/提问等待）。

---

## 4. 内存与状态管理

### 4.1 Agent 私有消息队列

每个 Agent 持有私有 `messages`。工具结果在 `_execute_single` 不直接写入，而是由 `async.all`
完成后按原始顺序 `add_tool_result`。`agent.messages` 随会话生命周期累积。

### 4.2 上下文压缩

`runtime.run` 在每次新一步前调用 `compactor.maybe_compact`：达到压力阈值（`context_window *
threshold_ratio`）时折叠最早的整段历史，保留最近尾部（retain 预算），用检查点替换（仅替换而非追加）。
`force_compact` 用于溢出恢复。

### 4.3 前缀缓存身份

`prefix.verify_cache_identity` 跨请求比对 fingerprint，身份变更即前缀缓存失效（用于诊断与统计）。
`context_builder` 不把 `reasoning_content` 写回历史，避免使 DeepSeek 前缀缓存从该 assistant
消息起失效。

### 4.4 会话/子 Agent 清理

`runtime.dispose(agent)` 释放资源（`signal:abort("disposed")`），`plan_mode.cleanup` 清理 agent 级
提示段，`todo.cleanup` 清理待办状态。`chat_service.detach_window` 在窗口关闭时持久化 + 清理 +
`tool_service.clear_approval`（释放串行审批槽位）。

---

## 5. 审批与工具循环的交互

### 5.1 审批期间的计时

每个工具在 `tool_loop._execute_single` 创建**可暂停计时器**（`utils.timer`）。工具从真正开始执行
（审批通过/直接执行）才计时；等待用户审批或 `ask_user` 回答期间 `timer:pause()`，结束后 `resume()`。
等待时间不计入耗时、不消耗超时预算。

### 5.2 串行审批队列

`tool_service` 是**串行单槽位**：一次只展示一个审批弹窗，其余入 `approval_queue` 排队，
互不覆盖。工具执行本身并行，但「弹窗确认」串行化。

- **审批超时兜底**：`tools.approval.timeout_ms` 默认 60s，超时拒绝而不是永久挂起；一旦决策
  （`item.d = nil`）超时即失效。
- **弹窗失败容错**：展示失败（`pcall`）时释放串行槽位并拒绝该条目，工具以错误结果结束、
  循环继续，不会因 `approval_showing` 残留 true 卡死。
- **AUTO 模式**：`toggle_auto_mode` 自动允许所有工具调用，开启时立即批准当前待审批/排队的工具。

### 5.3 计划模式门禁

`tool_service.execute` 先 `plan_mode.check_tool(agent, tool_name)`：计划模式下调用可见集之外的
任何工具都会被驳回（纵深防御，`tool_loop._tool_definitions` 已过滤）。

---

## 6. 潜在问题与设计取舍

### 6.1 工具循环终止条件

- **护栏**（`guard`）：observe-and-enrich，检测连续重复工具调用并注入提醒，但不否决。用户新输入
  (`runtime.run` 中 `guard.reset`) 重置计数链。阈值 3/5/8，可配置。
- **轮数上限**：`MAX_ROUNDS(1000)` 防御性上限，达到即停止并写说明。

### 6.2 空响应处理

工具循环第二轮或模型未返回内容时（无工具调用、无正文），写 `EMPTY_RESPONSE_MESSAGE` 作为
assistant 收尾，避免聊天「看起来卡住」。

### 6.3 溢出恢复

`recovery.send_stream` 在请求返回 context overflow 时先 `force_compact` 压缩历史再重试，
每轮最多一次，成功后重置标志。无可折叠内容时原样抛回溢出错误。

### 6.4 已知取舍

- 工具并行执行 + 顺序回写：保证 API 兼容与前缀缓存确定，但 `async.all` 需等待最慢的工具。
- 串行审批：牺牲弹窗并发避免互相覆盖，但审批等待通过可暂停计时器不超时。

---

## 附录：关键数据流（Write 工具 + 审批）

```
1. 模型返回 edit_file(filepath, description, edits)
2. _execute_single → tool_service.execute
3. executor.execute：
   resolve_name → 别名解析 → 路径展开 → schema 校验
   → 审批决策（edit_file auto_allow=false → 需审批）
4. approve_and_execute → 入串行审批队列
5. 用户按 <CR> 确认 → TOOL_APPROVED → continue_fn 恢复执行
6. continue_fn → _execute_tool（可暂停计时器 start）
   → edit_file 走 utils.work 线程池改盘 + reload_buffers_for
7. TOOL_EXECUTION_COMPLETED（含 duration_ms）
8. async.all → add_tool_result（按原始顺序）
9. guard.check_round → _send_round → 模型续写
```
