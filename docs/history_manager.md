# NeoAI 会话系统（v3.0）

> 会话系统管理对话历史，支持**分支树**、**追加式 JSONL 持久化**、**上下文构建**与**上下文压缩**。
> 对应源码：`lua/NeoAI/core/session/*`。

## 1. 模块结构

| 模块 | 职责 |
| --- | --- |
| `core/session/session.lua` | 会话对象（纯净数据 + 方法），字段 `id / parent_id / root_id / created_at / updated_at / model / messages / metadata`。fork 分支。 |
| `core/session/session_store.lua` | 会话持久化：追加式 JSONL + `.bak` 备份 + 撕裂行修复；CRUD + get_chain/get_downstream 链式遍历。 |
| `core/session/context_builder.lua` | 从会话/Agent 构建发送给模型的上下文消息（含 system 渲染、工具调用协议处理）。 |
| `core/session/tool_result_pruner.lua` | 模型无关的工具结果裁剪：摘要前把超长工具结果裁成「头部 + 省略标记 + 尾部」。 |
| `core/session/compactor.lua` | 上下文压缩：达到压力阈值时折叠旧历史、辅助摘要（前缀缓存复用）、检查点替换。 |

## 2. 会话对象（session.lua）

会话是纯净数据结构，无副作用、无 I/O：

```
{ id, parent_id, root_id, created_at, updated_at, model,
  messages = { { role, content, reasoning?, tool_calls?, tool_call_id?, ts, checkpoint? } },
  metadata = { name?, tags?, usage? } }
```

- `parent_id`：父会话 id（根会话为 nil）。
- `root_id`：根会话 id（子会话未显式指定时以父为根）。
- `fork(session, {copy_messages})`：派生新会话（`parent_id = session.id`）。
- 消息操作：`add_message` / `get_message` / `update_message` / `delete_message` / `trim_messages` /
  `clear_messages`。
- `add_usage`：累加 usage（prompt/completion）。

## 3. 会话持久化（session_store.lua）

**追加式 JSONL**：每次写入 append 一行 JSON，无需解析整个文件；崩溃恢复截断最后不完整行即可。

- `_session_path()`：`session.save_path / session.file`（默认 `~/.cache/NeoAI/sessions.jsonl`）。
- **init**：读取并修复 JSONL（`fs.repair_jsonl`），反序列化全部会话。
- **persist(session)**：追加式持久化单个会话。
- **save_all()**：原子重写整个文件（先写 `.bak` 再写正式文件；失败回滚），用于删除/批量变更后。
- **delete(session_id)**：删除会话及其全部子孙（`get_descendants`）。
- **get_chain(session_id)**：从根到指定会话的祖先链（含自身，根在前）。
- **get_downstream(session_id)**：沿会话树向下的单子链。只有唯一子会话才继续深入；
  遇分裂分支（多个子会话）或末尾即止。用于重建完整线性对话。

### 3.1 撕裂行恢复

`fs.repair_jsonl` 在读取前修复被截断/撕裂的最后一行，保证崩溃后下一次启动能正常加载。

## 4. 上下文构建（context_builder.lua）

`context_builder.build(session)` / `build_from_agent(agent)`：

- 首条消息为 system（`prefix.build_system_prompt` 渲染）。
- 截断历史：保留最近的 `session.max_history_per_session`（缺省 1000）条非 system。
- **工具调用协议**：带 `tool_calls` 的 assistant 消息，`content` 必须为 `null`（或省略）；
  发送 `content:""` 会被要求严格的模型判定为格式异常。
- **推理内容不随历史回传**：`reasoning_content` 不写入 API 消息，内部 `message.reasoning` 仅用于渲染。
  避免重复发送整段思维链、使 DeepSeek 前缀缓存从该 assistant 消息起失效。
- `build_prefix(agent, range_messages)`：构建压缩回放前缀（system + 指定区间），供压缩辅助调用复用前缀缓存。
- `build_fork_context(session, task)`：从父会话派生子会话的初始上下文。
- `estimate_tokens(messages)`：token 粗估（字符/4）。

## 5. 上下文压缩（compactor.lua）

策略对齐 deepseek-harness 的 compaction：

1. **触发**：`maybe_compact(agent)` 在每次新一步前检查，估算 token 达到
   `context_window * threshold_ratio` 阈值时折叠。
2. **模型无关裁剪**：先由 `tool_result_pruner.prune_agent` 把超预算的工具结果裁成
   「头部 + 省略标记 + 尾部」（`prune_threshold_chars` / `prune_head_chars` / `prune_tail_chars`），
   含图像引用的结果跳过。裁剪后已回到阈值内则直接结束，无需摘要调用；有裁剪则作废过期 API 用量。
3. **选择折叠区间**：`_select_shadow_range` 折叠最早的整段历史，保留最近尾部（`retain_ratio` 预算，
   下限 `retain_min_tokens`，至少 `min_shadow_messages` 条消息）。切点必须**工具配对平衡**：
   前移切点直到不拆散 `assistant.tool_calls` 与其 `tool` 结果，否则压缩后请求会被 API 拒绝。
4. **辅助摘要**：`_summarize` 逐字节回放会话前缀（相同系统提示、工具 schema、被折叠区消息），
   再追加压缩指令作为最后一条 user 消息 → 复用 provider 热前缀缓存。
5. **检查点替换**：生成带 `<compacted-summary>` 标签的 checkpoint user 消息，**替换被折叠区间**
   （`_replace_with_checkpoint`），并记录 `replaced_count`。后续请求在替换点之前的未变前缀仍可复用缓存。
   仅替换而非追加（不产生第二份历史副本）。成功后发射 `COMPACTION_COMPLETED`。
6. **收敛重试**：摘要后仍高于阈值时按 `compaction_retries` 继续折叠更早区间。

`force_compact`（溢出恢复用）跳过压力阈值判断，保留空闲/并发锁检查；先裁剪，裁剪已足以回到
窗口内则不再摘要，否则做一次最大化的平衡头部缩减（retain 0，只保留最新一个不可分单元）。

## 6. 会话树与分支

会话通过 `parent_id` / `root_id` 表达树形结构。从树界面打开某会话时，`chat_service.load_session`
沿 `get_chain`（祖先）向上延展到首轮，再沿 `get_downstream`（单子链）向下延展到分裂分支或末尾，
拼出完整线性对话（`_build_chain_messages`），避免只打开选中会话丢失分支上下文。

## 7. 相关文档

- [configuration.md](configuration.md)：`session.*` 配置（save_path / max_history_per_session / file）。
- [ai_engine.md](ai_engine.md)：`context_builder` / `compactor` 在生成流程中的作用。
- [EVENTS.md](EVENTS.md)：会话事件（`SESSION_*`）。
