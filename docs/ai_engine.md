# NeoAI Agent 引擎（v3.0）

> [English](en/ai_engine.md) | **中文**

> 本文档描述 NeoAI 的 Agent 引擎，从会话构建上下文、发送请求、处理流式响应、
> 执行工具循环、到上下文压缩与溢出恢复的完整链路。
> 对应源码：`lua/NeoAI/core/agent/*`。

## 1. 模块结构

`core/agent/` 下每个模块职责单一，依赖单向（`agent → runtime → request/stream/tool_loop`）。

| 模块 | 职责 |
| --- | --- |
| `agent.lua` | Agent 对象（纯数据 + 方法，不含 I/O）。状态机 `idle → generating → tool_running → idle`（或 `aborted`/`error`）。私有消息队列、工具集、独立 AbortSignal。 |
| `runtime.lua` | Agent 运行时：`create` / `spawn`（派生） / `dispose` / `abort` / `run`。解析场景配置、绑定工具、编排生成流程。 |
| `request.lua` | 请求构建（经 adapter）+ 发送（流式/非流式）+ 指数退避重试 + 上下文溢出判断。 |
| `stream.lua` | 流式响应处理：把 OpenAI 分片格式的增量 `tool_calls` 累积为完整 tool_call，并实时发射 `TOOL_ARG_CHUNK`/`TOOL_ARG_COMPLETED`。 |
| `tool_loop.lua` | 工具调用循环：并行执行工具 → 请求 AI 继续 → 直到无工具调用。 |
| `prefix.lua` | 前缀缓存身份一致性：系统提示按有序段拼接、工具按字典序输出、fingerprint 比对，缓存命中率最大化；缓存命中解析按模型机制分派（OpenAI/DeepSeek/Anthropic/Gemini 字段归一）。 |
| `guard.lua` | 工具循环护栏：检测连续重复的工具调用并注入提醒（observe-and-enrich）。 |
| `recovery.lua` | 上下文溢出恢复：请求返回 context window exceeded 时自动压缩历史后重发。 |

## 2. 核心概念

### 2.0 按模型自动选择（capabilities / profiles / adapter）

整条链路对每个请求解析出一套「模型策略」：

- `core/model/profiles.lua` → **方言**：协议族内的厂商/模型覆盖（`max_tokens` / `max_completion_tokens` /
  `maxOutputTokens`；`reasoning_effort` / `enable_thinking` / `thinking` / `thinkingConfig`；鉴权头；
  usage 字段；`reasoning_echo`）。模型 pattern 仅在协议与 `api_type` 一致时覆盖 provider profile。
- `core/model/capabilities.lua` → **能力**：上下文窗口、最大输出、缓存机制（`openai`/`anthropic`/`gemini`）、
  最小可缓存 token、显式缓存 TTL/断点上限、字符/token 系数。数值解析序：用户覆盖 → **实时 API 元数据
  （`/models` 回传的 `inputTokenLimit` / `context_length` 等）** → 内置 pattern → `api_type` 默认 → 兜底
  （`caps.source` 标注来源）。`max_tokens` 发送策略：仅用户显式配置才发送，未配置则不发送
  （由模型/厂商默认最大输出决定；必填协议如 Anthropic 用能力表 `max_output` 兜底）。
- `core/model/adapter.lua` → **协议编解码**：把内部规范（OpenAI 形消息 + 统一响应）编解码为
  各协议 wire 形态（`encode_messages` / `encode_tools`；Anthropic `system` 顶层 + `tool_use`/`tool_result`
  + `input_schema` + `source.base64`；Gemini `contents` + `functionDeclarations`（类型大写、裁剪 schema）
  + `inlineData`）。
- `core/model/prompt_cache.lua` → **显式缓存**：Anthropic `cache_control` 断点 / OpenAI explicit /
  Gemini `cachedContents` 生命周期；失败自动降级为隐式。

请求参数格式与缓存命中计算方案因此**随模型自动选择**，未知模型安全回退。详见
[model_policy.md](model_policy.md)。

### 2.1 Agent 对象（每次对话全新实例）

每个会话对应一个**全新的 Agent 实例**，零状态泄漏：

- `id`：全局唯一（`stringx.uuid("agent")`）。
- `session_id`：所属会话 id。
- `parent`：子 Agent 的父 Agent id。
- `messages`：私有消息队列（`{ role, content, reasoning?, tool_calls?, ts }`）。
- `tools`：可见工具子集（`name -> tool def`）。
- `signal`：独立 AbortSignal（取消信号）。
- `state`：状态机当前值。
- `cache`：前缀缓存身份指纹与命中统计。

状态机由 `agent.lua` 定义：

```
idle → generating → tool_running → idle
            ↓              ↓
         aborted          error
```

### 2.2 场景化配置解析

`runtime._resolve_agent_config` 按 `scenario` 解析模型配置，优先级：`场景 provider/preset → 预设 → 用户覆盖`。
场景取值：`chat` / `coding` / `reasoning` / `agent`。`model = "auto"` 时从 `core.model.registry` 解析默认模型。

## 3. 生成流程（runtime.run）

`runtime.run(agent, content)` 是主入口：

1. **忙碌检查**：`agent_mod.is_busy(agent)`（generating / tool_running）→ 返回 `reject({kind="busy"})`。
2. **信号复位**：若上一次被取消（`signal:aborted()`），则替换为全新 AbortSignal（否则新一轮请求会立即失败）。
3. **上下文压缩检查**：`compactor.maybe_compact(agent)` —— 到达压力阈值先折叠旧历史，复用前缀缓存。
4. **护栏复位**：`guard.reset(agent)` —— 用户新输入重置重复调用计数。
5. **添加用户消息**：`agent:add_message("user", content)`，发射 `MESSAGE_SENT`。
6. **生成**：`_run_generation(agent, {})`（见下）。

### 3.1 生成（_run_generation）

```
_runtime._run_generation(agent, opts)
  → stream.create(agent) 创建流处理器
  → agent:set_state("generating") + GENERATION_STARTED
  → recovery.send_stream(agent, { agent_config, model, signal }, on_chunk)
      ├─ 逐 chunk → proc.process(chunk)（内容/推理/工具调用增量写入 agent）
      ├─ 成功 → usage 累加 + proc.finish() 得到工具调用
      │    ├─ 有工具调用 → tool_loop.run(agent, tool_calls, tool_service)
      │    └─ 无工具调用 → 若空响应写 EMPTY_RESPONSE_MESSAGE → 收尾 idle
      └─ 失败（取消）→ 状态复位 idle，reject({kind="cancelled"})
                    （普通错误）→ 状态 error + GENERATION_ERROR
```

### 3.2 流式处理（stream.lua）

`stream.create(agent)` 返回 `processor`，`processor.process(parsed)` 处理每个解析后的分片：

- **推理**：`REASONING_STARTED` → `agent:append_reasoning(chunk)`（`REASONING_CHUNK`）。
- **内容**：`agent:append_content(chunk)`。
- **工具调用**：`_accumulate_tool_calls` 按 `index` 累积增量（名/参数字符串拼接），
  并实时发射 `TOOL_ARG_CHUNK { agent_id, tool_calls = 当前累积快照 }`。

`processor.finish()` 结束流：把累积的 tool_calls finalize 写入 agent（`set_tool_calls`，
发射 `TOOL_CALL_DETECTED`），并发射 `TOOL_ARG_COMPLETED`。

> `TOOL_ARG_CHUNK` / `TOOL_ARG_COMPLETED` 是新增事件，供 UI 实时展示「接收参数」悬浮窗
> （`tool_args_panel`），与思考过程悬浮窗行为一致。

### 3.3 上下文构建（core/session/context_builder）

`context_builder.build_from_agent(agent)` 从 Agent 消息队列构建 API 上下文：

- 首条系统消息由 `prefix.build_system_prompt(agent)` 渲染（有序段拼接）。
- 工具调用协议要求：带 `tool_calls` 的 assistant 消息，`content` 必须为 `null`（或省略）。
- **推理内容（reasoning_content）不随历史回传**：避免每次请求重复发送整段思维链、
  使 DeepSeek 前缀缓存从该 assistant 消息起字节不一致而失效。内部 `message.reasoning`
  仍保留用于渲染。

## 4. 工具调用循环（tool_loop.lua）

`tool_loop.run(agent, tool_calls, tool_service, opts)` 是工具循环主循环。

### 4.1 循环结构

```
_run() 每轮：
  1. abort 检查 → reject({kind="aborted"})
  2. rounds 计数，超过 MAX_ROUNDS(1000) → 写 LOOP_LIMIT_MESSAGE + TOOL_LOOP_LIMIT_REACHED
  3. 无工具调用 → resolve({response, rounds})
  4. set_state("tool_running") + TOOL_LOOP_STARTED
  5. 并行执行所有工具（_execute_single，promises[i]）
  6. async.all(...) → 结果统一按原始顺序写回消息队列（add_tool_result）
  7. 护栏 check_round（重复调用提醒注入）
  8. set_state("generating") + TOOL_LOOP_FINISHED
  9. _send_round(agent) 请求下一轮
     ├─ 轮边界压缩：maybe_compact({allow_busy=true})（工具结果已回写、下一轮请求前）
     ├─ 轮前刷新（MCP stale schema）
     ├─ 有工具调用 → 回到第 1 步循环
     ├─ 无工具调用但被截断 → _drain_truncation 自动续写（见 4.5）
     └─ 无工具调用 → 若最后一条是 tool 消息则写 EMPTY_RESPONSE_MESSAGE → 结束
```

> **轮边界压缩**：`_send_round` 在真正发送前先调 `compactor.maybe_compact(agent, { allow_busy = true })`。
> 此刻上一轮工具结果已回写、下一轮请求尚未发出，无并发写入，折叠历史安全；长工具循环因此逐轮
> 收敛上下文。压缩为 no-op（低于阈值/无可折叠）时不阻断发送，压缩异常也兜底走原发送路径。

### 4.5 截断续写（_drain_truncation）

模型输出被输出上限截断（`finish_reason` 为 `length` / `max_tokens` / `MAX_TOKENS`，见
`tool_loop.is_truncated`）且本轮无工具调用时，若 `ai.truncation` 启用且未达 `max_continues`，
自动以 `extra_user` 附加续写提示（`ai.truncation.nudge`）重发一轮：

- 提示**只进请求 wire、不落库**（`context_builder.build_from_agent` 的 `extra_user`），续写内容经
  `append_content` 追加进**同一条** assistant 消息，不产生空 assistant 历史或聊天噪声。
- 续写得到工具调用 → 回到循环第 1 步；得到正文/非截断 → 正常结束；达到次数上限仍截断 →
  写入 `TRUNCATED_MESSAGE`（可见提示）后结束，避免循环静默退出。
- 首轮（runtime 直接生成、无工具调用）同样经 `_drain_truncation` 处理，续写出工具调用则进入
  工具循环。
- 计数 `agent._truncation_continues` 在每轮用户输入时重置（`runtime.run` 内）。

### 4.2 工具定义输出（_tool_definitions）

- 工具按名称字典序输出：确定性 → 相同工具集跨请求逐字节相同，前缀缓存友好。
- 空 properties 不输出该字段（DeepSeek 拒绝 `[]` schema）。
- 先做环境探测（`tools.environment.filter_tools`）：无法获取 workspace/git 目录时禁用相关工具。
- 计划模式（`plan_mode.apply_tool_filter`）：只保留只读/信息查询工具 + `ask_user`。

### 4.3 单工具执行（_execute_single）

`tool_service.execute(agent, name, args, tool_call_id, opts)`：

- 每个工具创建**可暂停计时器**（`utils.timer.create`）：从真正开始执行（审批通过/直接执行）才计时，
  等待用户审批或 ask_user 回答期间暂停，耗时与超时不计等待。
- 执行结果/错误发射 `TOOL_EXECUTION_STARTED` / `TOOL_EXECUTION_COMPLETED` / `TOOL_EXECUTION_ERROR`
  （均携带 `duration_ms`，供折叠文本实时展示耗时）。

### 4.4 并行执行与顺序回写

工具调用**并行执行**（`vim.schedule`），但结果在 `async.all` 完成后**统一按原始调用顺序**写回
消息队列（`_execute_single` 不直接写入）。保证 tool 消息顺序与 assistant 的 `tool_calls` 一致，
API 兼容且前缀缓存确定。

## 5. 前缀缓存（prefix.lua）

策略对齐 deepseek-harness 的上下文缓存实践：

1. **系统提示按有序段拼接**：`identity(-100) / persona(0) / 工具指引(100+)`，渲染逐字节稳定。
   任何顺序位或文本变化都会使前缀缓存从第一个变更 token 起失效。
2. **工具定义按名称字典序输出**（确定性）。
3. **缓存身份（fingerprint）**：`_fnv1a` 稳定哈希，跨请求比对。身份变更即前缀缓存失效，用于诊断与统计。
4. **缓存用量解析**：从 provider usage 解析 `prompt_cache_hit_tokens` / `cached_tokens` 等，
   计算命中率。

系统提示段可注册：

- 全局：`prefix.register_section(name, order, text)`。
- Agent 级：`prefix.register_agent_section(agent, name, order, text)`（遮蔽同名全局段）。
  `todo` 模块注册 `deployment:todos`（order=100），`plan_mode` 注册 `deployment:plan_policy`（order=100），
  分别把当前任务清单/计划策略注入系统提示。

## 6. 上下文压缩（core/session/compactor）

`compactor.maybe_compact(agent, opts)` 做 token 压力检查（两处触发）：

- **回合边界**：`runtime.run` 在新一步前调用（不传 `allow_busy`，要求 `idle`）。
- **工具循环内部**：`tool_loop._send_round` 每轮发送前调用 `maybe_compact(agent, { allow_busy = true })`——
  上一轮工具结果已回写、下一轮请求尚未发出，此刻折叠历史安全（无并发写入）。长循环因此逐轮收敛，
  不至于耗尽上下文后撞溢出。

门禁 `_can_compact(agent, opts)`：无效 agent / `_compacting` / 信号已 abort → 拒绝；
`opts.allow_busy` 为真时放宽 `idle` 要求（允许在 `generating`/`tool_running` 下压缩）。

达到 `context_window * threshold_ratio` 阈值时折叠最早的整段历史，保留最近尾部（retain 预算）。
其中 `context_window` 缺省按模型能力表推导（用户显式非默认配置优先），显式缓存模型自动取
更保守的阈值/保留比。实例模型参考 [model_policy.md](model_policy.md)。

- **辅助摘要调用**：`_summarize` 逐字节回放会话前缀（相同系统提示、工具 schema、被折叠区消息），
  再把压缩指令作为最后的 user 消息追加 → 复用 provider 的热前缀缓存。
- **检查点替换**：用带 `<compacted-summary>` 标签的 checkpoint user 消息**替换被折叠区间**
  （`_replace_with_checkpoint`），并记录 `replaced_count` 与 `replaced_synced_count`（被替换消息中
  **已落盘**的条数；回合边界压缩时二者相等，循环中途压缩时前者大于后者）。
  后续请求在替换点之前的未变前缀仍可复用缓存。仅替换而非追加（不产生第二份历史副本）。
  成功后发射 `COMPACTION_COMPLETED`。

`force_compact`（溢出恢复用）跳过压力阈值判断；**缺省 `allow_busy = true`**，保证溢出恢复在
回合首轮与工具循环中途（`generating`/`tool_running`）都能真正压缩——先裁剪，裁剪已足以回到窗口内
则不再摘要，否则做一次最大化的平衡头部缩减（retain 0，只保留最新一个不可分单元）。

## 7. 溢出恢复（recovery.lua）

`recovery.send_stream(agent, opts, on_chunk)` 包裹 `request.send_stream`，被回合首轮
（`runtime._run_generation`）与工具循环每一轮（`tool_loop._send_round`）共用：

- 请求返回 `context window exceeded` 时（`request.is_context_overflow`），先 `force_compact(agent, { allow_busy = true })`
  压缩历史，再重新请求（`attempt()` 重试）。`allow_busy = true` 是关键：请求已因溢出失败、
  agent 仍处于 `generating`/`tool_running`，若不放宽 `idle` 守卫，压缩会被拒绝、溢出错误直接抛出。
- 每轮请求最多触发一次压缩恢复；成功后重置 `agent._overflow_recovered = false`，允许后续再次恢复。
- 无可折叠内容时原样抛回溢出错误。

## 8. 请求与重试（request.lua）

`request.send` / `request.send_stream`：

- **多模态物化**：`_prepare_messages` 把会话内的图像引用解析为协议中立的图像块（`core.model.content.materialize`）；
  模型不支持图像时原样为文本。
- **请求体构建**：经 `core.model.adapter`（openai/anthropic/google）+ `core.model.profiles` 方言适配；
  编码后由 `prompt_cache.apply_async` 注入显式缓存（失败降级隐式）。
- **流式强制**：`send_stream` 强制 `stream = true`；OpenAI 兼容端点自动加 `stream_options.include_usage`
  （否则拿不到 usage，无法统计缓存命中）。
- **重试**：`async.retry` 指数退避（`delay_ms=1000, backoff=2`），`max_retries` 缺省 3。
  4xx 不重试、abort 不重试。
- **上下文溢出判断**：`_is_context_overflow` 匹配多种 provider 措辞（`context_length`、
  `prompt is too long`、`too many tokens` 等），主要看 400/413/429。

## 9. 相关文档

- [EVENTS.md](EVENTS.md)：事件常量与数据。
- [tool_system.md](tool_system.md)：工具系统（`tool_loop` 依赖 `tool_service`）。
- [sub_agent_system.md](sub_agent_system.md)：子 Agent（`runtime.spawn`）。
- [configuration.md](configuration.md)：`ai.context_cache` / `ai.reasoning_enabled` 等配置。
- [model_policy.md](model_policy.md)：按模型自动选择（协议方言 / 能力表 / 显式缓存 / token 节省技巧）。
