# NeoAI Thread Pool Optimization (v3.0)

> [中文](../ui_multithread_optimization.md) | **English**

> v3.0 no longer uses the multi-threaded UI based on `vim.uv.new_thread()` (the old `history_tree` /
> `chat_window` / `tree_window` components have been removed). Currently, blocking I/O and CPU-intensive
> computation are delegated uniformly to the **`utils.work` thread pool** to avoid stalling the nvim
> main thread; async primitives are provided by `utils.async`.
> Corresponding source: `lua/NeoAI/utils/work.lua`, `lua/NeoAI/utils/async.lua`,
> `lua/NeoAI/utils/timer.lua`, `lua/NeoAI/utils/textmetrics.lua`.

## 1. Core Idea

The Neovim main thread handles the event loop and UI rendering. If blocking file I/O (reading large
files, recursive directory search, writing to disk) or CPU-intensive computation is done on the main
thread, the entire editor stalls. Therefore:

- **Blocking I/O / CPU-intensive** → the `utils.work` thread pool (libuv `vim.uv.new_work`).
- **Async primitives** → `utils.async` (Promise / Deferred / AbortSignal / retry).
- **Pausable timing** → `utils.timer` (tracks active execution time, excluding paused durations while waiting for user interaction).

## 2. The utils.work Thread Pool

Built on the libuv thread pool (`vim.uv.new_work`); pool size = CPU count (measured on this machine:
16 threads; 16×300ms jobs finish in 308ms, 64 in 1201ms). File system operations also queue and share
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

**Structured input/output**: tables cannot cross the thread boundary (`queue` rejects tables). For
structured data use `work.run_codec(fn, input, ...)`: the main thread encodes `input` into a single
binary string with `vim.mpack`, and the thread decodes it with `vim.mpack` (available inside workers);
`fn(data, ...)` returns any msgpack-able value that the main thread decodes. Extra primitive arguments
may be appended (packed to avoid `queue` argument loss). Compared with JSON it is faster and natively
supports binary (no base64 sentinel).

```lua
work.run_codec(function(data)
  -- data is already a decoded table
  return { sum = data.a + data.b }
end, { a = 1, b = 2 }):then_(function(res) ... end)
```

**Constraints** (inside the thread is a fresh Lua state; closures are not shared; `require`'s package.path excludes the nvim runtime):

- The worker function is passed as bytecode (`string.dump`, weak-table cached), and it can only use its arguments + the pure Lua standard library + `vim.uv`.
- Arguments and return values must be primitive types (string / number / boolean / nil), and **cannot be a table** (use `run_codec`).
- Inside a worker the `vim` table is available (`vim.mpack`/`vim.json`/`vim.uv`/`vim.deepcopy` are safe pure functions); `vim.fn` is nil, and calling main-state-touching `vim.api.*` is **forbidden** (not thread-safe).
- When a pure-Lua implementation is needed, pass the module `source` (e.g. `utils/textmetrics.lua`, `utils/sha256.lua`) and `load` it inside the thread.
- **Threading is mandatory, with no synchronous fallback**: at startup `work.require()` validates `vim.uv.new_work` and runs a worker round-trip self-check (`work.selfcheck`) confirming `vim.mpack` is available inside workers; any failure is reported loudly.

## 2.1 Offloaded main-thread hot spots (aggressive optimization)

| Path | Offload strategy |
| --- | --- |
| Streaming content/reasoning concat | Chunk arrays + adaptive materialization (`core/agent/agent.lua`, `core/agent/request.lua`) removing per-fragment `..` O(n²); small-content threshold is 8KB, beyond which materialization is batched by byte/time budget; the `MESSAGE_UPDATED` payload carries only a lightweight scalar view (no body text or transient chunk array; `nvim_exec_autocmds` deep-copies payloads, so carrying large text regresses to O(n²)); trajectory wire data (request body/SSE chunks) is retained boundedly per `ai.trace.max_rounds`, with older rounds degraded to summaries |
| Tool-argument snapshots | Full concat only at stream end; throttled snapshots emit a bounded preview (`core/agent/stream.lua`) |
| Session persistence | Shallow session shell (no full `vim.deepcopy`) + C `json.encode_fast` + `persist_async` disk writes in the pool + per-session serial queue (`services/chat_service.lua`, `core/session/session_store.lua`) |
| Statusline capacity estimate | Cached by a cheap key; recomputed only when message count/usage/model change (`services/status.lua`), no full estimate per lualine redraw |
| Tool-argument secret scan | Small args use a synchronous fast path (keeps approval synchronous); large args go through `secret.scan_all_async` single-pass in the pool (`sandbox/secret.lua`, `tools/executor.lua`) |
| Sandbox canonical hashing / review manifest | Switched to C `json.encode_fast`, dropping the pure-Lua UTF-8 deep scan (`sandbox/control.lua`, `sandbox/cache.lua`, `sandbox/broker.lua`, `sandbox/review.lua`, `sandbox/evidence.lua`) |
| Sandbox masking decision | `runtime.is_masked_path` caches the mask-path list (`vim.fn.glob` wildcard expansion) and each entry's canonical form, keyed by the config table reference. Previously it ran glob + `vim.fn.resolve` per candidate file (~60 entries × file count), so the async postprocess of a command creating thousands of files pegged the main thread (measured: 2000 files 4.2s → ~0.17s main-thread CPU) (`sandbox/runtime.lua`) |
| Historical tool-argument decode | Bounded memoization keyed by the arguments string (`core/model/adapter.lua`) |
| Streaming UI render | Render throttling during generation (at most once per 80ms) + markdown render memoization (`ui/window/chat_view.lua`, `ui/components/markdown_view.lua`) |
| Tool result/argument display | Bounded pretty-printing: results/arguments over 256KB skip the full JSON decode and render a bounded raw prefix (measured: a 10MB result goes from ~97ms to ~0.1ms); each tool block decodes its arguments/result once, shared by the secret scan and the renderer (`ui/components/message_list.lua`) |
| Long-session streaming render | Block descriptors are reused based on "cheap inputs" (message identity, content/reasoning length, reasoning toggle, tool-call/result identity and status); unchanged blocks skip fingerprint/signature building and build-closure allocation, and only changed blocks are rebuilt (`ui/components/message_list.lua`) |

## 3. Modules That Use the Thread Pool

| Module | Purpose |
| --- | --- |
| `utils/fs.lua` | `read_file_async` / `write_file_async` / `append_file_async` / `delete_file_async` / `list_dir_async` / `search_files_async` / `read_file_lines_async`. |
| `utils/work.lua` | `run_codec`: `vim.mpack` codec for structured input/output (available on both the main thread and inside workers). |
| `tools/builtin/file_ops.lua` | `read_file` / `edit_file` / `list_files` / `search_files` / `delete_file` (async variants). |
| `tools/builtin/read_image.lua` | Reads a binary file (`work.run(_read_binary, abs_path)`). |
| `sandbox/candidate.lua` | `capture_overlay_async` / `finish_async`: overlay recursive walk, file reads and SHA-256 hashing run in the thread pool; the main thread only registers/assembles state. **Unchanged materialized files are skipped by mtime/size signature (`dsig`) without reading or hashing**; `finish_async` dispatches in chunks of `tools.sandbox.work_chunk_files` (default 128) to use multiple cores on many-file workloads (npm/cargo). |
| `sandbox/conceal.lua` | `redact_async`: fingerprint redaction of command output (a dozen gsub passes, possibly MB-scale) runs in the thread pool. |
| `sandbox/secret.lua` | `tokenize_many_async` / `tokenize_async` / `scan_all_async`: full-text secret scanning (named rules + variable names + entropy) runs in the thread pool; token generation/mapping/events stay on the main thread. When the text count exceeds the chunk size, chunks run concurrently and equivalent tokens for the same secret across chunks are unified to a canonical token (so `detokenize` round-trips). |
| `utils/sha256.lua` | Pure-Lua SHA-256; the `source` string is `load`ed inside a thread so candidate hashing and in-thread token derivation run on another core. |
| `utils/textmetrics.lua` | Pure-Lua text metrics (display width / codepoint slicing / wrapping); the `source` string is `load`ed inside a thread. |
| `core/session/tool_result_pruner.lua` | `prune_agent_async`: codepoint counting/slicing of MB-scale tool results runs in the thread pool (measured: 12×3.7MB goes from a 330ms main-thread block to 0ms, ~140ms across 4 threads); only the pruned result is handed back to the main thread. |

> Rendering (`ui/components/markdown_view.lua`) now uses a pure-Lua single pass via
> `utils.textmetrics` instead of per-character `vim.fn.strwidth/strcharpart`, making CJK table
> wrapping ~1.8–3x faster. Rendering still runs on the main thread by design, but repeated parsing
> is reduced via streaming throttling + render memoization.

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
