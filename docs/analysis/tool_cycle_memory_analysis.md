# NeoAI 工具循环引擎深度分析

## 目录
1. [架构概览](#1-架构概览)
2. [核心流程](#2-核心流程)
3. [CPU 占用问题分析](#3-cpu-占用问题分析)
4. [内存累积问题分析](#4-内存累积问题分析)
5. [审批流程与工具循环的交互](#5-审批流程与工具循环的交互)
6. [潜在 Bug 和改进建议](#6-潜在-bug-和改进建议)

---

## 1. 架构概览

### 文件结构

```
lua/NeoAI/
├── core/ai/
│   ├── engine.lua              # AI 引擎核心：生成流程编排、事件调度
│   ├── tool_cycle.lua          # 工具循环引擎：主/子 agent 的工具调用循环
│   ├── request_handler.lua     # HTTP 请求构建和异常检测
│   └── sub_agent_engine.lua    # 子 agent 引擎
├── tools/
│   ├── tool_executor.lua       # 工具执行器：参数规范化、审批检查、超时管理
│   ├── approval_handler.lua    # 审批处理器：审批队列、UI 弹窗
│   ├── approval_state.lua      # 审批状态管理
│   ├── tool_validator.lua      # 工具验证器：权限和审批检查
│   ├── tool_registry.lua       # 工具注册表
│   └── tool_pack.lua           # 工具包分组管理
└── utils/
    ├── http_utils.lua          # HTTP 请求工具
    └── logger.lua              # 日志工具
```

### 事件驱动架构

工具循环使用 **双事件等待机制**：

```
┌─────────────────────────────────────────────────────────┐
│                    TOOL_LOOP_STARTED                     │
│                         │                               │
│                  _execute_tools()                        │
│                    (并发执行)                             │
│                  ╱    │    ╲                             │
│            tool₁  tool₂  tool₃                           │
│              │      │      │                             │
│            on_result callbacks                           │
│              ╲      │      ╱                             │
│           _on_tools_complete()                           │
│              → TOOL_EXECUTION_ALL_COMPLETED              │
│                         │                               │
│              once_display_closed (50ms)                  │
│                         │                               │
│              _check_round_complete()                     │
│         (等待 GENERATION_COMPLETED 事件)                  │
│                         │                               │
│              _proceed_to_next_round()                    │
│                         │                               │
│              _request_generation()                       │
│              → TOOL_RESULT_RECEIVED                      │
│                         │                               │
│              engine.handle_tool_result()                 │
│                    (HTTP 请求)                            │
│                         │                               │
│              on_generation_complete()                    │
│              → GENERATION_COMPLETED                      │
│                         │                               │
│              _execute_tools() ← 循环                     │
└─────────────────────────────────────────────────────────┘
```

---

## 2. 核心流程

### 2.1 工具执行入口 (`_execute_tools`)

```lua
-- tool_cycle.lua 行 702-915

function M._execute_tools(session_id, tool_calls, is_sub_agent)
  -- 1. 防重入检查：phase == "waiting_tools" 则跳过
  -- 2. 空工具调用：直接请求 AI 生成
  -- 3. 设置 phase = "waiting_tools"
  -- 4. 清空 active_tool_calls（原地清理，不替换表引用）
  -- 5. 预注册所有 tool_call_id（防竞态）
  -- 6. 异步并发执行所有工具（vim.schedule）
  -- 7. 设置超时保护（默认 300s，审批期间可延长）
end
```

**关键设计**：
- 工具通过 `vim.schedule` 异步并发执行，不阻塞主线程
- `active_tool_calls` 表跟踪未完成的工具调用
- 每个工具完成时从 `active_tool_calls` 中移除自己
- 当 `active_tool_calls` 为空时触发 `_on_tools_complete`

### 2.2 单工具执行 (`_execute_single_tool`)

```lua
-- tool_cycle.lua 行 917-1703

function M._execute_single_tool(session_id, tool_call, is_sub_agent, on_complete)
  -- 1. 工具名称修正（别名映射 + 模糊匹配）
  -- 2. 参数规范化
  -- 3. tool_call_id 级别去重（_executed_tool_call_ids）
  -- 4. 子 agent 边界审核
  -- 5. create_sub_agent 特殊处理
  -- 6. confirm_file_change 拦截处理（统一确认/放弃/重试）
  -- 7. Write 工具 AI 预览拦截
  -- 8. 普通工具执行
end
```

### 2.3 Write 工具 AI 预览流程

```
write 工具调用
  │
  ├─ tool_executor.execute_with_orchestrator()
  │   ├─ 识别为 write 工具
  │   ├─ arguments._needs_ai_preview = true
  │   ├─ 发射 "AI 检查" 子步骤事件
  │   └─ 覆盖 on_success：拦截真实写入，构造预览
  │
  ├─ 工具执行成功 → _intercept_write_tool_result()
  │   ├─ 读取文件修改点附近 ±10 行的内容
  │   └─ 构造预览结果返回给 AI
  │
  ├─ AI 看到预览 → 调用 confirm_file_change 工具
  │   ├─ action="confirm" → 重新执行 write 工具（走过审批）
  │   ├─ action="abandon" → 放弃修改
  │   └─ action="retry" → 用修正参数重新执行（仍走预览）
  │
  └─ confirm 路径 → write 工具重新执行 → approval_handler
      ├─ 用户审批通过 → 实际写入文件
      └─ 用户拒绝 → 错误回调
```

### 2.4 审批流程

```
tool_executor.execute_async()
  │
  ├─ tool_validator.check_approval()
  │   ├─ allow_all 已设置 → 跳过审批
  │   ├─ 路径安全 AND 参数安全 → 跳过审批
  │   └─ 路径或参数不安全 → needs_user_approval = true
  │
  ├─ needs_user_approval == true
  │   ├─ approval_handler.enqueue(item)
  │   ├─ 发射 TOOL_APPROVAL_QUEUED 事件
  │   └─ 清除超时定时器（审批通过后重新设置）
  │
  └─ needs_user_approval == false
      └─ _continue_execution() 直接执行
```

---

## 3. CPU 占用问题分析

### 3.1 `once_display_closed` 的 50ms 延迟

```lua
-- tool_cycle.lua 行 230-245
local function once_display_closed(session_id, callback)
  vim.defer_fn(function()
    local ok, err = pcall(callback)
    if not ok then
      logger.warn("[tool_orchestrator] once_display_closed 回调异常: %s", tostring(err))
    end
  end, 50)  -- ← 仅 50ms 延迟
end
```

**问题**：50ms 的延迟意味着在工具完成后仅 50ms 就会触发下一轮 AI 请求。在快速工具执行场景下（如 read_file），这会形成紧密的事件循环：
- 工具完成 → 50ms → 请求生成 → AI 响应 → 工具执行 → 50ms → ...

**影响**：虽然每个步骤都是异步的，但高频的事件发射和回调处理会增加 CPU 负载。

**建议**：考虑将延迟增加到 100-200ms，或使用自适应延迟（根据迭代次数递增）。

### 3.2 并发工具执行

```lua
-- tool_cycle.lua 行 835-843
for _, tc in ipairs(tool_calls) do
  vim.schedule(function()
    -- 所有工具在同一个事件循环中并发启动
    M._execute_single_tool(session_id, tc, is_sub_agent, nil)
  end)
end
```

**问题**：所有工具同时通过 `vim.schedule` 调度。当 AI 返回大量工具调用时（如 5-10 个），它们在同一事件循环中并发执行，可能导致：
- 多个 tool 结果同时写入 `ss.messages`
- 多次 `_trim_messages` 调用（每个工具结果一次）
- 多个事件（`TOOL_EXECUTION_COMPLETED` 等）密集发射

**建议**：考虑对工具执行进行分批（per tool_pack）或添加微小的交错延迟。

### 3.3 `_add_tool_result_to_messages` 中的 `_trim_messages`

```lua
-- tool_cycle.lua 行 2562-2604
function M._add_tool_result_to_messages(...)
  -- ...
  table.insert(ss.messages, tool_msg)
  _trim_messages(ss.messages)  -- ← 每次工具结果都触发裁剪
end
```

**问题**：`_trim_messages` 需要遍历整个 messages 数组、计算轮次、检查 tool_calls 配对关系、创建新数组并原地替换。当有多个工具同时完成时，这会被多次调用。

**建议**：将裁剪操作延迟到工具批次全部完成后，或使用引用计数延迟裁剪。

### 3.4 `_trim_messages` 的实现效率

```lua
-- tool_cycle.lua 行 61-123
local function _trim_messages(messages)
  -- 遍历找 system 消息数量
  -- 从后向前数 user 消息数（MIN_RETAIN_ROUNDS=3）
  -- 检查 assistant(tool_calls) -> tool 配对关系
  -- 创建新 trimmed 表
  -- 原地替换 messages
end
```

**问题**：每次调用都创建新的 `trimmed` 表并逐元素复制。虽然有 30 条消息的上限，但频繁调用仍有开销。

---

## 4. 内存累积问题分析

### 4.1 `_param_retry_counts` 泄漏

```lua
-- tool_cycle.lua 行 28
local _param_retry_counts = {}  -- 模块级变量！
```

**问题**：这是模块级局部变量，在整个 NeoAI 生命周期中持续存在。键格式为 `session_id:tool_name`。每当前工具执行失败并触发重试时，此表新增条目。

**清理时机**：仅在 `unregister_session()`（行 490-494）和 `unregister_sub_agent_session()`（行 560-565）时清理。

**泄漏场景**：
- 会话未正常注销（如窗口关闭但 session 未调用 unregister）
- 长时间运行的会话中反复调用同一工具失败
- 不同 session_id 使用同一子 agent

**建议**：
1. 在工具重试计数达到上限（3次）后立即清理对应条目
2. 添加全局清理机制（如会话空闲时清理）
3. 考虑使用弱引用表

### 4.2 `_executed_tool_call_ids` 未在所有路径重置

```lua
-- 重置位置：
-- 1. _proceed_to_next_round() 行 1930: ss._executed_tool_call_ids = {}
-- 2. _finish_loop() 行 2648, 2685: ss._executed_tool_call_ids = {}

-- 未重置的路径：
-- request_stop() 行 2731-2732: 只清理 active_tool_calls，不清理 _executed_tool_call_ids
```

**问题**：当用户取消生成时，`request_stop` 清理了 `active_tool_calls` 但未清理 `_executed_tool_call_ids`。下次工具循环可能因去重检查而跳过工具调用。

**建议**：在 `request_stop` 中添加 `ss._executed_tool_call_ids = {}`。

### 4.3 `ss.messages` 累积

```lua
-- MAX_CONTEXT_MESSAGES = 30, MIN_RETAIN_ROUNDS = 3
-- 每次工具结果插入后调用 _trim_messages
```

**分析**：`_trim_messages` 将消息数控制在 30 条以内，这是合理的。但需要注意：
- 系统消息不计入裁剪
- 裁剪点必须保证 assistant(tool_calls) ↔ tool 消息配对完整性
- 在某些极端情况下（如所有非系统消息都是 tool 消息），裁剪会跳过

**潜在风险**：如果裁剪跳过（行 100-102），消息会持续增长。

### 4.4 `accumulated_usage` 的累积

```lua
-- tool_cycle.lua 行 426-439 (GENERATION_COMPLETED 监听器)
-- tool_cycle.lua 行 2040-2056 (on_generation_complete)
```

**分析**：`accumulated_usage` 在每个轮次中累加 token 使用量。它在 `start_async_loop`（行 636）中被重置。只在单个会话生命周期内累积，不会跨会话泄漏。

### 4.5 会话状态表泄漏

```lua
-- state.sessions = {}     -- 主 agent 会话
-- state.sub_agent_sessions = {}  -- 子 agent 会话
```

**问题**：会话仅在显式调用 `unregister_session`/`unregister_sub_agent_session` 时清理。如果窗口关闭、用户取消等路径未正确调用 unregister，会话对象会永久保留。

**建议**：添加会话超时机制或定期清理不活跃的会话。

### 4.6 `_tools` 表

```lua
-- tool_cycle.lua 行 129
local _tools = {}
```

**分析**：存储可用工具列表，只在 `set_tools()`（行 2784）和 `shutdown()`/`cleanup_all()` 中修改。不是主要的内存泄漏源。

---

## 5. 审批流程与工具循环的交互

### 5.1 审批期间的 active_tool_calls

当工具需要审批时：
1. `tool_executor.execute_async` 将工具加入审批队列（`approval_handler.enqueue`）
2. 工具的 `on_success`/`on_error` 回调被保存到队列项中
3. `active_tool_calls[tool_call_id]` 仍然存在（在 `_execute_single_tool` 中预注册）
4. 审批通过后，`approval_handler._show_approval_dialog` 的 `on_select` 回调调用 `tool_executor._continue_execution`
5. `_continue_execution` 执行完毕后调用 `on_success`/`on_error` 回调
6. 回调中清理 `active_tool_calls` 并检查是否触发 `_on_tools_complete`

**设计是正确的**：审批期间工具保持"活跃"状态，防止工具循环提前推进。

### 5.2 审批超时保护

```lua
-- tool_cycle.lua 行 845-914
-- 默认 300 秒超时，审批期间自动延长
-- 审批等待最多重试 60 次（每次 5 秒 = 额外 5 分钟）
```

**流程**：
1. 超时检查函数 `_timeout_check` 在 `_execute_tools` 中设置
2. 如果检测到 `approval_handler.is_showing()` 或队列非空，延长 5 秒后重新检查
3. 最多重试 60 次（额外 5 分钟）
4. 超过上限后强制完成

**潜在问题**：如果用户在审批窗口中长时间不操作（超过 5+5=10 分钟），工具会被强制完成，审批窗口可能被意外关闭。

### 5.3 审批窗口与 UI 冻结

审批窗口使用 `nvim_open_win` 创建，通过 `vim.keymap.set` 绑定快捷键：
- `<CR>` 确认
- `<C-a>` 允许所有
- `<Esc>` / `<C-c>` 取消
- `<C-r>` 取消并说明原因

**事件驱动设计**：
- `on_select` 回调在确认时触发
- `on_cancel` 回调在取消时触发
- `WinClosed` 自动命令处理窗口被外部关闭

**UI 不应冻结**：所有操作都是事件驱动、非阻塞的。如果用户感知到卡顿，可能是以下原因：
- 审批窗口渲染时计算高度/内容有性能问题
- 多个审批窗口同时打开（理论上 `approval_showing` 标志应阻止）
- 工具循环超时与审批窗口冲突

### 5.4 confirm_file_change 与审批的关系

Write 工具的特殊流程：
1. Write 工具执行 → AI 预览拦截 → 返回预览给 AI
2. AI 调用 `confirm_file_change` 工具确认
3. `confirm_file_change(action="confirm")` → 重新执行 write 工具（此时走过审批）
4. 审批通过 → 实际写入

**关键代码**（tool_cycle.lua 行 1300-1397）：
```lua
if action == "confirm" then
  -- 重新执行 write 工具（走过审批）
  tool_executor.execute_with_orchestrator(last_write_tool_name, last_write_args, ...)
end
```

**潜在问题**：
- 第二次执行（审批通过后）的 `tool_call_id` 是新生成的
- 新 `tool_call_id` 被添加到 `active_tool_calls` 中
- 如果用户审批时间很长，外部超时检查可能会检测到并延长等待

---

## 6. 潜在 Bug 和改进建议

### 6.1 紧急修复建议

#### Bug 1: `request_stop` 未清理 `_executed_tool_call_ids`

**位置**：`tool_cycle.lua` 行 2725-2745

```lua
function M.request_stop(session_id)
  if session_id then
    local ss = state.sessions[session_id] or state.sub_agent_sessions[session_id]
    if ss then
      ss.stop_requested = true
      if next(ss.active_tool_calls) ~= nil then
        ss.active_tool_calls = {}
        -- BUG: 未清理 _executed_tool_call_ids
        vim.schedule(function()
          M._on_tools_complete(session_id, ss._is_sub_agent)
        end)
      end
    end
  end
end
```

**修复**：添加 `ss._executed_tool_call_ids = {}`。

#### Bug 2: `_param_retry_counts` 重试上限后未清理

**位置**：`tool_cycle.lua` 多处（行 1227, 1425, 1669）

```lua
if retry_count >= 3 then
  -- 已达重试上限，但 _param_retry_counts[retry_key] 未清理
end
```

**修复**：在重试上限到达后设置 `_param_retry_counts[retry_key] = nil`。

#### Bug 3: 消息裁剪边界条件

**位置**：`tool_cycle.lua` 行 96-103

```lua
while keep_from > system_count + 1 and messages[keep_from].role == "tool" do
  keep_from = keep_from - 1
end
-- 如果所有消息都是 tool 消息，keep_from 可能 <= system_count
if keep_from > #messages or keep_from <= system_count or messages[keep_from].role == "tool" then
  return  -- 跳过裁剪，消息无限增长
end
```

**修复**：在极端情况下应强制裁剪到最近的有效消息。

### 6.2 性能优化建议

#### 优化 1: 延迟消息裁剪

将 `_trim_messages` 从 `_add_tool_result_to_messages` 中移出，改为在工具批次完成后调用一次：

```lua
-- 在 _on_tools_complete 中调用
M._on_tools_complete = function(session_id, is_sub_agent)
  -- ... 现有逻辑 ...
  _trim_messages(ss.messages)  -- 仅裁剪一次
end
```

#### 优化 2: 增加 `once_display_closed` 延迟

```lua
local function once_display_closed(session_id, callback)
  -- 50ms → 150ms，减少 CPU 密集度
  vim.defer_fn(function()
    -- ...
  end, 150)
end
```

或根据迭代次数使用自适应延迟：
```lua
local delay = math.min(50 + (ss.current_iteration or 0) * 20, 300)
vim.defer_fn(function() ... end, delay)
```

#### 优化 3: 分批工具执行

```lua
-- 按 tool_pack 分组，每组之间添加 10ms 延迟
for pack_name, tools in pairs(grouped) do
  for _, tc in ipairs(tools) do
    vim.schedule(function() ... end)
  end
  -- 组间延迟可减少事件密集度
end
```

### 6.3 内存管理改进建议

#### 改进 1: 添加会话超时清理

```lua
-- 定期清理长时间不活跃的会话
local SESSION_IDLE_TIMEOUT = 30 * 60  -- 30 分钟
function M._cleanup_idle_sessions()
  local now = os.time()
  for sid, ss in pairs(state.sessions) do
    if ss.phase == "idle" and ss._last_active and (now - ss._last_active) > SESSION_IDLE_TIMEOUT then
      M.unregister_session(sid)
    end
  end
end
```

#### 改进 2: 使用 `vim.deepcopy` 替代手动复制

在 `_trim_messages` 中，手动创建 trimmed 数组并逐元素复制可以优化：

```lua
-- 当前实现（行 105-122）
local trimmed = {}
for i = 1, system_count do trimmed[i] = messages[i] end
-- ...
-- 可以简化为 table.move
```

#### 改进 3: 重置 `_param_retry_counts` 的时机

```lua
-- 在每个工具成功完成后清理对应的重试计数
if success then
  local retry_key = session_id .. ":" .. tool_name
  _param_retry_counts[retry_key] = nil
end
```

### 6.4 审批流程改进建议

#### 改进 1: 审批超时用户提示

当审批等待时间过长时，给用户一个通知：

```lua
if timeout_retries > 30 then  -- 等待超过 2.5 分钟
  vim.notify("[NeoAI] 工具审批等待时间较长，请尽快处理", vim.log.levels.WARN)
end
```

#### 改进 2: 审批队列可视化

当前审批队列是内部的，用户只能看到当前审批的工具。建议在 UI 中显示队列状态。

#### 改进 3: 全局审批超时配置

```lua
-- 允许用户在配置中设置审批超时
M.approval_timeout_ms = config.approval_timeout_ms or 300000
```

---

## 附录：关键数据流

### A. 完整工具循环示例（Write 工具 + 审批）

```
1. AI 返回: edit_file(filepath="/etc/config", new_text="...")
2. _execute_tools → _execute_single_tool
3. tool_executor.execute_with_orchestrator("edit_file", args, ...)
4. 识别为 write 工具 → 设置 _needs_ai_preview=true
5. execute_async → 模拟执行 → 构造预览
6. on_result: 返回预览结果（modify point ±10 lines）
7. _add_tool_result_to_messages: 添加预览到 messages
8. active_tool_calls 减少 → _on_tools_complete
9. _check_round_complete → _proceed_to_next_round
10. _request_generation → AI 看到预览
11. AI 返回: confirm_file_change(action="confirm", reason="...")
12. _execute_single_tool 拦截 confirm_file_change
13. action="confirm": 重新执行 edit_file（真实执行）
14. execute_async → check_approval → 需要审批
15. approval_handler.enqueue → 显示审批窗口
16. 用户按 <CR> 确认
17. _continue_execution → 实际写入文件
18. on_success → active_tool_calls 减少 → _on_tools_complete
19. ... 循环继续
```

### B. 关键状态转换

```
idle
  │
  ├─ start_async_loop → waiting_tools (或 waiting_model)
  │
waiting_tools
  │
  ├─ 所有工具完成 → waiting_model
  │
waiting_model
  │
  ├─ AI 生成完成 → _check_round_complete
  │   ├─ 有工具调用 → _execute_tools → waiting_tools
  │   └─ 无工具调用 → _finish_loop → idle
  │
round_complete
  │
  └─ _proceed_to_next_round → waiting_model
```
