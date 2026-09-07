# NeoAI 线程池优化（v3.0）

> v3.0 不再使用基于 `vim.uv.new_thread()` 的多线程 UI（旧 `history_tree` / `chat_window` /
> `tree_window` 等组件已删除）。当前把阻塞式 I/O / CPU 密集计算统一交给 **`utils.work` 线程池**
> 执行，避免卡住 nvim 主线程；异步原语由 `utils.async` 提供。
> 对应源码：`lua/NeoAI/utils/work.lua`、`lua/NeoAI/utils/async.lua`、
> `lua/NeoAI/utils/timer.lua`。

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
