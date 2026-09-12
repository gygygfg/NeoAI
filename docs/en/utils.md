# NeoAI Utils Library (v3.0)

> [中文](../utils.md) | **English**

> The `utils` directory holds pure utility modules with **zero business dependencies**. It follows the one-way dependency rule
> `utils → kernel → core → services → ui/tools`, and is reused by every other layer.
> Corresponding source: `lua/NeoAI/utils/*`.

## 1. Module List

| Module | Responsibility |
| --- | --- |
| `init.lua` | Utility library entry point: `async` / `json` / `http` / `fs` / `stringx` + `deepcopy`. |
| `async.lua` | Async primitives: Promise/Deferred/AbortSignal/retry/sleep/all/race. |
| `json.lua` | JSON encode/decode (`encode`/`decode`/`decode_or_nil`/`decode_line`). |
| `http.lua` | Async HTTP client (curl jobstart, streaming SSE, AbortSignal termination). |
| `fs.lua` | File operations + JSONL read/write and torn-line repair. |
| `work.lua` | Thread pool (libuv `new_work`) that moves blocking I/O / CPU-intensive computation off the main thread. |
| `timer.lua` | Pausable timer (tracks active execution time, excluding pauses spent waiting for human interaction). |
| `image.lua` | Image type detection / media types. |
| `stringx.lua` | String extensions (trim/split/template/glob/uuid, etc.). |

## 2. async.lua

- `Deferred.new()`: a Promise you resolve/reject manually.
- `promise:finally(cb)`: waits for cleanup (including a returned Deferred), preserving the original value/rejection; a cleanup failure replaces that outcome with its error.
- `new(executor)`: a Promise with an executor(resolve, reject).
- `all(promises)` / `race(promises)`: concurrent aggregation.
- `retry(fn, opts)`: exponential backoff retry (`delay_ms` / `backoff` / `signal` / `should_retry`).
- `sleep(ms)`: delay.
- `create_signal()`: AbortSignal (`abort(reason)` / `aborted()` / `subscribe(cb)` / `reason()`).

> Cancellation semantics: `signal:abort(reason)` sets the aborted state; HTTP requests and tool executions listen on the signal
> and cancel in a cascade. The retry in `request.send_stream` also passes `signal`.

## 3. json.lua

- `encode(value)`: Lua value → JSON string.
- `decode(json_str)`: JSON → Lua value (raises on failure).
- `decode_or_nil(json_str)`: safe decoding (returns nil on failure).
- `decode_line(line)`: decode a single JSONL line.

## 4. http.lua

An async HTTP client built on `curl` jobstart:

- `request(opts)`: non-blocking request. opts `{ base_url, path, method, headers, body, query, timeout_ms, stream }`.
- Streaming: `on_chunk(data, done)` handles SSE, with `done=true` only on successful completion. Successful requests resolve `""` instead of retaining the full raw stream; error bodies are capped at 64 KiB, with `body_truncated=true` when truncated.
- Reconstruction preserves line fragments and UTF-8 bytes across job callbacks, including adjacent `event:` and `data:` lines.
- AbortSignal: kills the curl job on abort.
- `get_json(base_url, path, opts)`: convenience function for GET JSON.

> ⚠️ Depends on `curl` (`utils.http` uses curl jobstart); if curl is missing from the environment, requests may fail to be sent.

## 5. fs.lua

- File operations: `read_file` / `write_file` / `append_file` / `delete_file`.
- Atomic writes: `write_file_atomic(path, content, { backup = true })` uses a same-directory temporary file, fsync and rename, optionally keeping the previous version as `.bak`.
- Both write and close failures return `false, err`; threaded async variants reject with the error.
- Directories: `ensure_dir` / `mkdir` / `is_dir` / `list_dir` / `join` / `basename` / `dirname` / `copy_file` / `expand`.
- JSONL: `read_jsonl` / `append_jsonl` / `repair_jsonl` (torn-line recovery).
- Async variants: `read_file_async` / `write_file_async` / `append_file_async` / `delete_file_async` /
  `list_dir_async` / `search_files_async` / `read_file_lines_async` (all go through the `utils.work` thread pool).

> Blocking file I/O (reading large files / recursive search / writing to disk) runs in the thread pool via `utils.work`,
> so it does not occupy the nvim main thread and prevents the main UI from freezing during tool calls.

## 6. work.lua (thread pool)

Moves pure Lua computation off the main thread using the libuv thread pool (`vim.uv.new_work`).

**Constraints** (the libuv thread has a fresh Lua state and shares no closures / require / vim.fn / vim.api):

- The work function must be passed as **bytecode** (`string.dump`): it can only use arguments + the pure Lua standard library + `vim.uv`.
- Arguments and return values must be **primitive types** (string / number / boolean / nil), never tables.
- The return value should be a string (nil / other primitive types are automatically `tostring`ed).
- The thread pool defaults to 4 threads; file system operations also run in the pool and share its queue.

```lua
local work = require("NeoAI.utils.work")
work.run(function(path)
  local f = io.open(path, "rb")
  local data = f:read("*a")
  f:close()
  return data
end, "/path/to/file"):then_(function(data) ... end, function(err) ... end)
```

Without `vim.uv.new_work` (nvim < 0.10), it falls back to synchronous execution via `vim.schedule` (which still guarantees the call stack is not blocked).

## 7. timer.lua (pausable timer)

Tracks "active execution time" (excluding pause time spent waiting for human interaction) and enforces timeouts based on that active time.

```lua
local timer = require("NeoAI.utils.timer").create()
timer:start(30000)         -- set the timeout budget (nil / <0 = no timeout)
tool_service.execute(...)  -- tool execution, while waiting for approval/ask_user
  -- where user interaction is awaited: timer:pause()
  -- after the interaction ends: timer:resume()
timer:elapsed()            -- current active elapsed time (excluding paused periods)
timer:stop()               -- tool execution finished
```

> The tool loop `tool_loop._execute_single` creates a pausable timer for each tool; it calls `pause` during approval waits and
> `ask_user` responses, then `resume` afterward, so waiting time is not counted toward elapsed time and does not consume the timeout
> budget. The "elapsed time" shown in the collapsed text is `timer:elapsed()`, ticking in real time (`chat_view` refreshes every second).

## 8. image.lua

- `media_type_for_path(path)`: infers the media type from the extension (png/jpeg/webp/gif).
- `detect_media_type(data)`: detects the real image format from the magic bytes.
- `IMAGE_MEDIA_TYPES`: constants for the supported media types.

> Used by the `read_image` tool for "gate first, then read from disk": when the declared extension does not match the actual bytes, it rejects and prompts for conversion.

## 9. stringx.lua

- `trim` / `split` / `startswith` / `endswith` / `is_blank`.
- `template` (`{}` placeholders).
- `glob_to_pattern` / `glob_match`.
- `truncate` / `capitalize` / `uuid` (unique id generation, used for agent/session/message).

## 10. logger (kernel/logger.lua)

The logging module has moved from `utils` to `kernel` (to satisfy the kernel → utils dependency rule) and is initialized by `kernel/lifecycle`.

```lua
log = {
  level = "WARN",           -- DEBUG / INFO / WARN / ERROR / FATAL
  path = vim.fn.stdpath("cache") .. "/NeoAI/neoai.log",
  format = "[{time}] [{level}] {message}",
  max_size = 10485760,      -- 10MB
  max_backups = 5,
  verbose = false,
}
```
