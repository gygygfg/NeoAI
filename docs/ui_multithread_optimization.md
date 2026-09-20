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

基于 libuv 线程池，默认 4 根线程，文件系统操作也在池内排队共享。

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

**约束**（线程内是全新 Lua state，不共享闭包 / require / vim.fn / vim.api）：

- 工作函数以字节码（`string.dump`）传入，仅能用参数 + 纯 Lua 标准库 + `vim.uv`。
- 参数与返回值必须是原始类型（string / number / boolean / nil），**不能是 table**。
- 无 `vim.uv.new_work`（nvim < 0.10）时回退到 `vim.schedule` 同步执行（仍不阻塞调用栈）。

## 3. 使用线程池的模块

| 模块 | 用途 |
| --- | --- |
| `utils/fs.lua` | `read_file_async` / `write_file_async` / `append_file_async` / `delete_file_async` / `list_dir_async` / `search_files_async` / `read_file_lines_async`。 |
| `tools/builtin/file_ops.lua` | `read_file` / `edit_file` / `list_files` / `search_files` / `delete_file`（异步变体）。 |
| `tools/builtin/read_image.lua` | 读二进制文件（`work.run(_read_binary, abs_path)`）。 |
| `tools/builtin/edit_file.lua`（edit 模式） | 读文件 + 结构化替换 + 写盘（在线程池内完成）。 |
| `sandbox/candidate.lua` | `capture_overlay_async` / `finish_async`：overlay 递归遍历、文件读取、SHA-256 哈希在线程池内完成，主线程只做状态登记/组装。**未改动的物化文件按 mtime/size 签名（`dsig`）跳过读取与哈希**；`finish_async` 按 `tools.sandbox.work_chunk_files`（默认 128）分块并发投递，使 npm/cargo 等大量文件场景用满多核。 |
| `sandbox/conceal.lua` | `redact_async`：命令输出的指纹脱敏（十余次 gsub，可能达 MB 级）在线程池内完成。 |
| `sandbox/secret.lua` | `tokenize_many_async` / `tokenize_async`：密钥全文扫描（具名规则 + 变量名 + 熵检测）在线程池执行，token 生成/映射/事件仍在主线程；文本数超过分块大小时按块并发，合并时把跨块同一密钥的等价 token 统一为规范 token（保证 detokenize 可还原）。 |
| `utils/sha256.lua` | 纯 Lua SHA-256；`source` 源码字符串传入线程内 `load`，供候选哈希与线程内 token 派生在独立核心计算。 |
| `utils/textmetrics.lua` | 纯 Lua 文本度量（显示宽度/码点切片/折行）；`source` 源码字符串传入线程内 `load`。 |
| `core/session/tool_result_pruner.lua` | `prune_agent_async`：MB 级工具结果的码点统计/切片经线程池计算（实测 12×3.7MB 从主线程阻塞 330ms → 0ms，4 线程并行约 140ms），仅把裁剪结果传回主线程应用；线程池不可用或 `ui.render.threaded=false` 时回退同步。 |

> 渲染侧（`ui/components/markdown_view.lua`）已改为纯 Lua `utils.textmetrics` 单遍扫描
> （不再逐字符 `vim.fn.strwidth/strcharpart`），CJK 表格折行约快 1.8~3 倍；按当前设计
> 渲染仍同步执行（`ui.render.threaded` 只控制计算卸载），后续如需可复用 `textmetrics.source`
> 把整段渲染搬进线程池。

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
