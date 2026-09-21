# NeoAI 会话系统（v3.0）

> [English](en/history_manager.md) | **中文**

> 会话系统管理对话历史，支持**分支树**、**追加式 JSONL 持久化**、**上下文构建**与**上下文压缩**。
> 对应源码：`lua/NeoAI/core/session/*`。

## 1. 模块结构

| 模块 | 职责 |
| --- | --- |
| `core/session/session.lua` | 会话对象（纯净数据 + 方法），字段 `id / parent_id / root_id / created_at / updated_at / model / messages / metadata`。fork 分支。 |
| `core/session/session_store.lua` | 会话持久化：追加式 JSONL + `.bak` 备份 + 撕裂行修复；CRUD + get_chain/get_downstream 链式遍历。 |
| `core/session/context_builder.lua` | 从会话/Agent 构建发送给模型的上下文消息（含 system 渲染、工具调用协议处理）。 |
| `core/session/tool_result_pruner.lua` | 模型无关的工具结果裁剪：摘要前把超长工具结果裁成「头部 + 省略标记 + 尾部」。 |
| `core/session/compactor.lua` | 上下文压缩：达到压力阈值时后台折叠第一轮至倒数第二轮、辅助摘要（前缀缓存复用）、写入压缩覆盖层（渲染/持久化仍原始）。 |

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
- **init**：逐行读取并修复 JSONL（`fs.repair_jsonl`），仅反序列化每个会话的最新快照。
- **persist(session)** / **update(session)**：追加单个会话快照，返回 `true` 或 `false, err`；达到日志冗余阈值时合并。
- **save_all()**：写入同目录临时文件、fsync、备份旧文件到 `.bak`，再 rename 替换正式文件；失败返回 `false, err`，正式文件不被截断。
- **delete(session_id)**：删除目标及直接子会话。更深后代重挂到最近存活祖先，无祖先则提升为根，并更新子树的 `root_id`。保存成功后才提交内存变更和删除事件；失败返回 `{}, err`。
- **get_chain(session_id)**：从根到指定会话的祖先链（含自身，根在前）。
- **get_downstream(session_id)**：沿会话树向下的单子链。只有唯一子会话才继续深入；
  遇分裂分支（多个子会话）或末尾即止。用于重建完整线性对话。
- **工具结果 UI 元数据持久化**：工具结果消息的 `tool_name` / `duration_ms` / `notice`
  （沙箱降级、特权档等用户可见附加提示）/ `secret_paths`（内核观测到的密钥文件）随会话
  落盘，关闭会话再打开后审批与渲染所需的「额外提示」不会丢失；这些字段仅供 UI 展示，
  不进入模型上下文（编码时由适配器白名单过滤）。

### 3.1 撕裂行恢复

`fs.repair_jsonl` 在读取前修复被截断/撕裂的最后一行，保证崩溃后下一次启动能正常加载。
完整 JSON 末行缺换行时会补齐分隔符，避免后续追加粘连。聊天消息只有保存成功才标记 `_synced`；失败后保留内存内容供重试。

### 3.2 日志合并

```lua
session = {
  log_compaction = {
    enabled = true,
    max_redundant_records = 64,
    min_bytes = 8 * 1024 * 1024,
  },
}
```

冗余旧快照达到 64 条，或日志达到 8 MiB 且至少为最新快照总大小的两倍时，原子重写为每个会话一条快照。
合并失败不影响已经成功追加的记录，下次持久化再次尝试。此合并只回收磁盘旧版本，不压缩/删除会话消息。

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

后台异步、非阻塞压缩：达到阈值时启动摘要生成后立即返回，agent 不被阻塞，也不弹压缩悬浮窗。
摘要完成后写入**压缩覆盖层**，后续请求与再次压缩使用压缩后的替换；渲染与会话持久化仍是原始上下文。

1. **触发**：分两处（均保持阈值判断，`start_background` 后台执行）。
   - **回合边界**：`runtime.run` 追加用户消息后调 `start_background(agent, { allow_busy = true })`。
   - **工具循环内部**：`tool_loop._send_round` 每轮发送前调 `start_background(agent, { allow_busy = true })`；
     溢出恢复（`recovery`）仍调**阻塞等待**的 `force_compact(agent, { allow_busy = true })`。
   估算 token 达到 `context_window * threshold_ratio` 阈值时折叠。
2. **模型无关裁剪**：先由 `tool_result_pruner.prune_agent` 把超预算的工具结果裁成
   「头部 + 省略标记 + 尾部」（`prune_threshold_chars` / `prune_head_chars` / `prune_tail_chars`），
   含图像引用的结果跳过。裁剪后已回到阈值内则直接结束，无需摘要调用；有裁剪则作废过期 API 用量。
3. **选择折叠区间（常规）**：`_select_round_shadow` 折叠**第一轮至倒数第二轮**（保留最后一轮完整），
   以请求视图（可能已含上一次检查点）中最后一条非运行态 user 消息为最后一轮起点。
   溢出恢复的 `force_compact` 则走 `_select_shadow_range` 做最大化平衡头部缩减
   （retain 0，至少 `min_shadow_messages` 条；切点必须**工具配对平衡**，不拆散
   `assistant.tool_calls` 与其 `tool` 结果）。
4. **辅助摘要**：`_summarize` 逐字节回放请求视图前缀（相同系统提示、工具 schema、被折叠区消息），
   再追加压缩指令作为最后一条 user 消息 → 复用 provider 热前缀缓存。
5. **压缩覆盖层**：`_apply_overlay` 写入 `agent.compaction = { checkpoint, replaced }`：
   - `checkpoint`：带 `<compacted-summary>` 标签的 user 消息；
   - `replaced`：被替换的**非运行态快照**消息条数（跨运行态快照计数，重开可复现）。

   **不改动 `agent.messages`**：聊天渲染与会话持久化仍是原始完整历史。
   `context_builder.request_view(agent)` 用「检查点 + 未替换尾部」构建请求视图；
   `build_from_agent` 使用该视图。覆盖层存于 `session.metadata.compaction`，`load_session` 重开时还原。
6. **收敛重试**：摘要后仍高于阈值时按 `compaction_retries` 重试；常规压缩在无新的可折叠原始消息时停止。

`force_compact`（溢出恢复用）跳过压力阈值判断，**缺省 `allow_busy = true`**，**阻塞等待**；先裁剪，
裁剪已足以回到窗口内则不再摘要，否则做一次最大化的平衡头部缩减（retain 0，只保留最新一个不可分单元）。

## 6. 会话树与分支

会话通过 `parent_id` / `root_id` 表达树形结构。从树界面打开某会话时，`chat_service.load_session`
沿 `get_chain`（祖先）向上延展到首轮，再沿 `get_downstream`（单子链）向下延展到分裂分支或末尾，
拼出完整线性对话（`_build_chain_messages`），避免只打开选中会话丢失分支上下文。

## 7. 相关文档

- [configuration.md](configuration.md)：`session.*` 配置（save_path / max_history_per_session / file）。
- [ai_engine.md](ai_engine.md)：`context_builder` / `compactor` 在生成流程中的作用。
- [EVENTS.md](EVENTS.md)：会话事件（`SESSION_*`）。
