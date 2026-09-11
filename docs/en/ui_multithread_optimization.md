# NeoAI Thread Pool Optimization (v3.0)

> [中文](../ui_multithread_optimization.md) | **English**

> v3.0 no longer uses the multi-threaded UI based on `vim.uv.new_thread()` (the old `history_tree` /
> `chat_window` / `tree_window` components have been removed). Currently, blocking I/O and CPU-intensive
> computation are delegated uniformly to the **`utils.work` thread pool** to avoid stalling the nvim
> main thread; async primitives are provided by `utils.async`.
> Corresponding source: `lua/NeoAI/utils/work.lua`, `lua/NeoAI/utils/async.lua`,
> `lua/NeoAI/utils/timer.lua`.

## 1. Core Idea

The Neovim main thread handles the event loop and UI rendering. If blocking file I/O (reading large
files, recursive directory search, writing to disk) or CPU-intensive computation is done on the main
thread, the entire editor stalls. Therefore:

- **Blocking I/O / CPU-intensive** → the `utils.work` thread pool (libuv `vim.uv.new_work`).
- **Async primitives** → `utils.async` (Promise / Deferred / AbortSignal / retry).
- **Pausable timing** → `utils.timer` (tracks active execution time, excluding paused durations while waiting for user interaction).

## 2. The utils.work Thread Pool

Built on the libuv thread pool, with 4 threads by default; file system operations also queue and share
the pool.

```lua
local work = require("NeoAI.utils.work")

work.run(function(path)
  local f = io.open(path, "rb")
  local data = f:read("*a")
  f:close()
  return data           -- returns a string (a pure primitive type)
end, "/path/to/file"):then_(function(data)
  -- the main thread receives the result
end, function(err) ... end)
```

**Constraints** (inside the thread is a fresh Lua state; closures / require / vim.fn / vim.api are not shared):

- The worker function is passed as bytecode (`string.dump`), and it can only use its arguments + the pure Lua standard library + `vim.uv`.
- Arguments and return values must be primitive types (string / number / boolean / nil), and **cannot be a table**.
- Without `vim.uv.new_work` (nvim < 0.10), it falls back to synchronous execution via `vim.schedule` (still without blocking the call stack).

## 3. Modules That Use the Thread Pool

| Module | Purpose |
| --- | --- |
| `utils/fs.lua` | `read_file_async` / `write_file_async` / `append_file_async` / `delete_file_async` / `list_dir_async` / `search_files_async` / `read_file_lines_async`. |
| `tools/builtin/file_ops.lua` | `read_file` / `edit_file` / `list_files` / `search_files` / `delete_file` (async variants). |
| `tools/builtin/read_image.lua` | Reads a binary file (`work.run(_read_binary, abs_path)`). |
| `tools/builtin/edit_file.lua` (edit mode) | Reads the file + performs structured replacement + writes to disk (all completed inside the thread pool). |

## 4. Thread Pool vs. the Old Multi-threaded UI

The old (now removed) approach: add `_xxx_async` methods to components such as `history_tree` /
`chat_window` / `tree_window`, run them in a separate thread with `vim.uv.new_thread()`, and call back
to the main thread. Problems:

- Complex tables had to be serialized/copied between threads, which is error-prone.
- Each component implemented its own async methods, making them hard to maintain and reuse.

The current approach: **converge on the unified `utils.work` thread pool**. Blocking I/O is explicitly
delegated to `utils.work`, async flows are composed uniformly with `utils.async` Deferreds, and the UI
layer is only responsible for event-driven rendering (`chat_view` merges multiple chunks within the
same tick into a single render, working together with folding and the floating window).

## 5. Related Documents

- [utils.md](utils.md): Detailed API for `utils.work` / `utils.async` / `utils.timer`.
- [tool_system.md](tool_system.md): How file tools use the thread pool.
- [ui_system.md](ui_system.md): `chat_view` event-driven render merging.
