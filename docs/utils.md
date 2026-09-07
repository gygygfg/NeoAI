# NeoAI Utils 工具库（v3.0）

> `utils` 目录是纯工具模块，**零业务依赖**。遵循依赖单向规则
> `utils → kernel → core → services → ui/tools`，被其它各层复用。
> 对应源码：`lua/NeoAI/utils/*`。

## 1. 模块列表

| 模块 | 职责 |
| --- | --- |
| `init.lua` | 工具库入口：`async` / `json` / `http` / `fs` / `stringx` + `deepcopy`。 |
| `async.lua` | 异步原语：Promise/Deferred/AbortSignal/retry/sleep/all/race。 |
| `json.lua` | JSON 编解码（`encode`/`decode`/`decode_or_nil`/`decode_line`）。 |
| `http.lua` | 异步 HTTP 客户端（curl jobstart，流式 SSE，AbortSignal 终止）。 |
| `fs.lua` | 文件操作 + JSONL 读写/撕裂行修复。 |
| `work.lua` | 线程池（libuv `new_work`），把阻塞式 I/O / CPU 密集计算移出主线程。 |
| `timer.lua` | 可暂停计时器（跟踪活跃执行时间，剔除等待人类交互的暂停时长）。 |
| `image.lua` | 图像类型检测 / 媒体类型。 |
| `stringx.lua` | 字符串扩展（trim/split/template/glob/uuid 等）。 |

## 2. async.lua

- `Deferred.new()`：手动 resolve/reject 的 Promise。
- `new(executor)`：带 executor(resolve, reject) 的 Promise。
- `all(promises)` / `race(promises)`：并发聚合。
- `retry(fn, opts)`：指数退避重试（`delay_ms` / `backoff` / `signal` / `should_retry`）。
- `sleep(ms)`：延时。
- `create_signal()`：AbortSignal（`abort(reason)` / `aborted()` / `subscribe(cb)` / `reason()`）。

> 取消语义：`signal:abort(reason)` 置为中止态；HTTP 请求、工具执行监听 signal，
> 一级级联取消。`request.send_stream` 的 retry 也传 `signal`。

## 3. json.lua

- `encode(value)`：Lua 值 → JSON 字符串。
- `decode(json_str)`：JSON → Lua 值（失败抛错）。
- `decode_or_nil(json_str)`：安全解码（失败返回 nil）。
- `decode_line(line)`：JSONL 单行解码。

## 4. http.lua

基于 `curl` jobstart 的异步 HTTP 客户端：

- `request(opts)`：非阻塞请求。opts `{ base_url, path, method, headers, body, query, timeout_ms, stream }`。
- 流式：`on_chunk(data, done)` 回调处理 SSE。
- AbortSignal：on abort 时 kill curl job。
- `get_json(base_url, path, opts)`：GET JSON 便捷函数。

> ⚠️ 依赖 `curl`（`utils.http` 用 curl jobstart）；环境变量内没有 curl 可能无法发送请求。

## 5. fs.lua

- 文件操作：`read_file` / `write_file` / `append_file` / `delete_file`。
- 目录：`ensure_dir` / `mkdir` / `is_dir` / `list_dir` / `join` / `basename` / `dirname` / `copy_file` / `expand`。
- JSONL：`read_jsonl` / `append_jsonl` / `repair_jsonl`（撕裂行恢复）。
- 异步变体：`read_file_async` / `write_file_async` / `append_file_async` / `delete_file_async` /
  `list_dir_async` / `search_files_async` / `read_file_lines_async`（均走 `utils.work` 线程池）。

> 阻塞式文件 I/O（读大文件 / 递归搜索 / 写盘）经 `utils.work` 在线程池执行，
> 不占用 nvim 主线程，避免工具调用时主界面卡住。

## 6. work.lua（线程池）

基于 libuv 线程池（`vim.uv.new_work`）把纯 Lua 计算移出主线程。

**约束**（libuv 线程内是全新 Lua state，不共享闭包 / require / vim.fn / vim.api）：

- 工作函数必须以**字节码**（`string.dump`）传入：仅能用参数 + 纯 Lua 标准库 + `vim.uv`。
- 参数与返回值必须是**原始类型**（string / number / boolean / nil），不能是 table。
- 返回值应为 string（nil / 其它原始类型会自动 `tostring`）。
- 线程池默认 4 根线程，文件系统操作也在池里，排队共享。

```lua
local work = require("NeoAI.utils.work")
work.run(function(path)
  local f = io.open(path, "rb")
  local data = f:read("*a")
  f:close()
  return data
end, "/path/to/file"):then_(function(data) ... end, function(err) ... end)
```

无 `vim.uv.new_work`（nvim < 0.10）时回退到 `vim.schedule` 同步执行（仍保证不阻塞调用栈）。

## 7. timer.lua（可暂停计时器）

跟踪「活跃执行时间」（剔除等待人类交互的暂停时长），并基于活跃时间执行超时。

```lua
local timer = require("NeoAI.utils.timer").create()
timer:start(30000)         -- 设定超时预算（nil / <0 = 无超时）
tool_service.execute(...)  -- 工具执行，等待审批/ask_user 时
  -- 在等待用户交互处：timer:pause()
  -- 交互结束后：timer:resume()
timer:elapsed()            -- 当前活跃耗时（剔除暂停期间）
timer:stop()               -- 工具执行完毕
```

> 工具循环 `tool_loop._execute_single` 为每个工具创建可暂停计时器；审批等待与 `ask_user` 回答
> 期间 `pause`，结束后 `resume`，从而等待时间不计入耗时、不消耗超时预算。折叠文本展示的
> 「耗时」即 `timer:elapsed()`，实时跳动（`chat_view` 每秒刷新）。

## 8. image.lua

- `media_type_for_path(path)`：按扩展名推断媒体类型（png/jpeg/webp/gif）。
- `detect_media_type(data)`：按 magic 字节检测真实图像格式。
- `IMAGE_MEDIA_TYPES`：支持的媒体类型常量。

> 供 `read_image` 工具做「先门禁再读盘」：扩展名声明与字节实际不符时拒绝并提示转换。

## 9. stringx.lua

- `trim` / `split` / `startswith` / `endswith` / `is_blank`。
- `template`（`{}` 占位符）。
- `glob_to_pattern` / `glob_match`。
- `truncate` / `capitalize` / `uuid`（唯一 id 生成，用于 agent/session/message）。

## 10. logger（kernel/logger.lua）

日志模块已从 `utils` 移到 `kernel`（满足 kernel → utils 依赖规则），由 `kernel/lifecycle` 初始化。

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
