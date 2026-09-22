# NeoAI 线程池优化（v3.0）

> [English](en/ui_multithread_optimization.md) | **中文**

> v3.0 不再使用基于 `vim.uv.new_thread()` 的多线程 UI（旧 `history_tree` / `chat_window` /
> `tree_window` 等组件已删除）。当前把阻塞式 I/O / CPU 密集计算统一交给 **`utils.work` 线程池**
> 执行，避免卡住 nvim 主线程；异步原语由 `utils.async` 提供。
> 对应源码：`lua/NeoAI/utils/work.lua`、`lua/NeoAI/utils/async.lua`、
> `lua/NeoAI/utils/timer.lua`、`lua/NeoAI/utils/textmetrics.lua`。

## 1. 核心思路

Neovim 主线程负责事件循环与界面渲染。若在主线程做阻塞式文件 I/O（读大文件、递归目录搜索、
写盘）或 CPU 密集计算，会卡住整个编辑器。因此：

- **阻塞式 I/O / CPU 密集** → `utils.work` 线程池（libuv `vim.uv.new_work`）。
- **异步原语** → `utils.async`（Promise / Deferred / AbortSignal / retry）。
- **可暂停计时** → `utils.timer`（跟踪活跃执行时间，剔除等待用户交互的暂停时长）。

## 2. utils.work 线程池

基于 libuv 线程池（`vim.uv.new_work`），池大小 = CPU 核数（本机实测 16 根线程；16 个 300ms
任务 308ms 完成，64 个 1201ms），文件系统操作也在池内排队共享。

```lua
local work = require("NeoAI.utils.work")

work.run(function(path)
  local f = io.open(path, "rb")
  local data = f:read("*a")
  f:close()
  return data           -- 返回 string（纯原始类型）
end, "/path/to/file"):then_(function(data)
  -- 主线程收到结果
end, function(err) ... end)
```

**结构化输入/输出**：table 不能跨线程传递（`queue` 拒绝 table），需要结构化数据时用
`work.run_codec(fn, input, ...)`：主线程把 `input` 经 `vim.mpack` 编码为二进制单串传入，线程内
用 `vim.mpack` 解码（worker 内 `vim.mpack` 可用）；`fn(data, ...)` 返回任意可 msgpack 化的值，
主线程再解码。可附带若干原始类型额外参数（打包传递，规避 `queue` 参数丢失）。相比 JSON 更快、
原生支持二进制（无需 base64 哨兵）。

```lua
work.run_codec(function(data)
  -- data 已是解码后的 table
  return { sum = data.a + data.b }
end, { a = 1, b = 2 }):then_(function(res) ... end)
```

**约束**（线程内是全新 Lua state，不共享闭包；`require` 的 package.path 不含 nvim runtime）：

- 工作函数以字节码（`string.dump`）传入（带弱表缓存），仅能用参数 + 纯 Lua 标准库 + `vim.uv`。
- 参数与返回值必须是原始类型（string / number / boolean / nil），**不能是 table**（用 `run_codec`）。
- 线程内 `vim` 表可用（`vim.mpack`/`vim.json`/`vim.uv`/`vim.deepcopy` 等纯函数安全）；`vim.fn` 为 nil，
  且**禁止**调用会触及 nvim 主状态的 `vim.api.*`（非线程安全）。
- 需要纯 Lua 实现时，把模块 `source`（如 `utils/textmetrics.lua`、`utils/sha256.lua`）作为参数传入线程内 `load`。
- **已强制多线程、无同步回退**：启动时 `work.require()` 校验 `vim.uv.new_work`，并跑一次
  worker 往返自检（`work.selfcheck`）确认 worker 内 `vim.mpack` 可用；任一不满足即显式报错。

## 2.1 已卸载的主线程热点（激进优化）

| 路径 | 卸载方式 |
| --- | --- |
| 流式正文/推理拼接 | 分片数组累积 + 自适应物化（`core/agent/agent.lua`、`core/agent/request.lua`），消除逐分片 `..` 的 O(n²)；小内容阈值 8KB，超过后按字节/时间阈值分段物化；`MESSAGE_UPDATED` payload 只带轻量标量视图（不含正文与流式瞬态分片数组；`nvim_exec_autocmds` 会深拷贝 payload，携带大文本会退化为 O(n²)）；轨迹 wire 数据（请求体/SSE 分片）按 `ai.trace.max_rounds` 有界保留，旧轮降级为摘要 |
| 工具参数快照 | 仅流结束拼接全量；节流快照只发有界预览（`core/agent/stream.lua`） |
| 会话持久化 | 浅拷贝外壳（去整会话 `vim.deepcopy`）+ C 实现 `json.encode_fast` + `persist_async` 线程池写盘 + 每会话串行队列（`services/chat_service.lua`、`core/session/session_store.lua`） |
| 状态栏容量估算 | 按廉价 key 缓存，仅在消息数/用量/模型变化时重算（`services/status.lua`），不再每次 lualine 重绘全量估算 |
| 工具参数密钥扫描 | 小参数同步快路径（保持审批同步语义）；大参数经 `secret.scan_all_async` 线程池单遍扫描（`sandbox/secret.lua`、`tools/executor.lua`） |
| 沙箱 canonical 哈希 / 评审 manifest | 改用 C 实现 `json.encode_fast`，去纯 Lua UTF-8 深扫（`sandbox/control.lua`、`sandbox/cache.lua`、`sandbox/broker.lua`、`sandbox/review.lua`、`sandbox/evidence.lua`） |
| 沙箱遮蔽判定 | `runtime.is_masked_path` 的遮蔽路径列表（`vim.fn.glob` 通配展开）与各条目的规范化形式按配置表引用缓存；此前对每个候选文件逐次 glob + `vim.fn.resolve`（约 60 条 × 文件数），数千文件命令的异步后处理会把主线程 CPU 拉满（实测 2000 文件后处理主线程 4.2s → ~0.17s）（`sandbox/runtime.lua`） |
| 历史工具参数解码 | 按 arguments 串有界记忆化（`core/model/adapter.lua`） |
| 流式 UI 渲染 | 生成中渲染节流（至多每 80ms 一次）+ markdown 渲染结果记忆化（`ui/window/chat_view.lua`、`ui/components/markdown_view.lua`） |
| 工具结果/参数展示 | 有界美化打印：超过 256KB 的结果/参数跳过全量 JSON 解码，按有界原始前缀渲染（实测 10MB 结果渲染 ~97ms → ~0.1ms）；同一工具块参数/结果只解码一次，供密钥扫描与渲染复用（`ui/components/message_list.lua`） |
| 长会话流式渲染 | 块描述符按「廉价输入」（消息身份、content/reasoning 长度、推理开关、工具调用与结果身份及状态）复用；未变化块跳过指纹/签名拼接与 build 闭包分配，只重建变化块（`ui/components/message_list.lua`） |

## 3. 使用线程池的模块

| 模块 | 用途 |
| --- | --- |
| `utils/fs.lua` | `read_file_async` / `write_file_async` / `append_file_async` / `delete_file_async` / `list_dir_async` / `search_files_async` / `read_file_lines_async`。 |
| `utils/work.lua` | `run_codec`：`vim.mpack` 编解码结构化输入/输出（主线程与 worker 内均可用）。 |
| `tools/builtin/file_ops.lua` | `read_file` / `edit_file` / `list_files` / `search_files` / `delete_file`（异步变体）。 |
| `tools/builtin/read_image.lua` | 读二进制文件（`work.run(_read_binary, abs_path)`）。 |
| `sandbox/candidate.lua` | `capture_overlay_async` / `finish_async`：overlay 递归遍历、文件读取、SHA-256 哈希在线程池内完成，主线程只做状态登记/组装。**未改动的物化文件按 mtime/size 签名（`dsig`）跳过读取与哈希**；`finish_async` 按 `tools.sandbox.work_chunk_files`（默认 128）分块并发投递，使 npm/cargo 等大量文件场景用满多核。 |
| `sandbox/conceal.lua` | `redact_async`：命令输出的指纹脱敏（十余次 gsub，可能达 MB 级）在线程池内完成。 |
| `sandbox/secret.lua` | `tokenize_many_async` / `tokenize_async` / `scan_all_async`：密钥全文扫描（具名规则 + 变量名 + 熵检测）在线程池执行，token 生成/映射/事件仍在主线程；文本数超过分块大小时按块并发，合并时把跨块同一密钥的等价 token 统一为规范 token（保证 detokenize 可还原）。 |
| `utils/sha256.lua` | 纯 Lua SHA-256；`source` 源码字符串传入线程内 `load`，供候选哈希与线程内 token 派生在独立核心计算。 |
| `utils/textmetrics.lua` | 纯 Lua 文本度量（显示宽度/码点切片/折行）；`source` 源码字符串传入线程内 `load`。 |
| `core/session/tool_result_pruner.lua` | `prune_agent_async`：MB 级工具结果的码点统计/切片经线程池计算（实测 12×3.7MB 从主线程阻塞 330ms → 0ms，4 线程并行约 140ms），仅把裁剪结果传回主线程应用。 |

> 渲染侧（`ui/components/markdown_view.lua`）已改为纯 Lua `utils.textmetrics` 单遍扫描
> （不再逐字符 `vim.fn.strwidth/strcharpart`），CJK 表格折行约快 1.8~3 倍；按设计渲染仍在
> 主线程执行，但已通过「流式节流 + 渲染结果记忆化」降低重复解析开销。

## 4. 线程池 vs 旧多线程 UI

旧（已删除）方案：给 `history_tree` / `chat_window` / `tree_window` 等组件添加 `_xxx_async` 方法，
用 `vim.uv.new_thread()` 在独立线程运行并回调主线程。问题：

- 线程间要序列化/复制复杂 table，易出错。
- 每个组件各自实现异步方法，难维护、难复用。

当前方案：**收敛到 `utils.work` 统一线程池**。阻塞 I/O 明确委托给 `utils.work`，异步流程统一用
`utils.async` 的 Deferred 组合，UI 层只负责事件驱动渲染（`chat_view` 把同一 tick 内的多次分片
合并为一次渲染，配合折叠与悬浮窗）。

## 5. 相关文档

- [utils.md](utils.md)：`utils.work` / `utils.async` / `utils.timer` 详细 API。
- [tool_system.md](tool_system.md)：文件工具如何使用线程池。
- [ui_system.md](ui_system.md)：`chat_view` 事件驱动渲染合并。
