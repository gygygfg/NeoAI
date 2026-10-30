--- 工作线程执行器
--- @module 'NeoAI.utils.work'
--- 基于 libuv 线程池（vim.uv.new_work）把纯 Lua 计算移出 nvim 主线程，
--- 避免 CPU 密集 / 阻塞式文件 I/O（如递归目录搜索、大文件读写）卡住主界面。
--- 约束（libuv 线程）：
--- - 工作函数必须以字节码（string.dump）传入：线程内是全新 Lua state，不共享闭包 upvalue。
---   线程内 `require` 的 package.path 不含 nvim runtime，但 `vim` 表可用（`vim.mpack` /
---   `vim.json` / `vim.uv` / `vim.deepcopy` 等纯函数安全）；`vim.fn` 为 nil，且**禁止**调用
---   会触及 nvim 主状态的 `vim.api.*`（非线程安全）。
--- - `M.run` 的参数与返回值必须是原始类型（string / number / boolean / nil），不能是 table。
--- - `M.run_codec` 用 `vim.mpack` 编解码结构化 table。
--- - 线程池大小 = libuv 线程池大小（默认 4，受 `UV_THREADPOOL_SIZE` 控制），文件系统操作
---   本身也在池里，排队共享。启动时经 `M.configure_threadpool()` 按 `M.io_threads()` 设置
---   （`clamp(核数 × 2, 4, 16)`）。
---   注意：这里**刻意不用** `utils.host.core_budget()`（`max(1, 核数-2)`）——那套「预留 2 核
---   给 UI」的 CPU 预算不适用于 I/O 线程（见 `M.io_threads()` 注释）。2 核宿主上
---   `core_budget()` = 1 会把池压成单线程，使整个 nvim 的异步文件 I/O 串行，导致文件类
---   工具排队到超时、run_command 后处理迟迟不返回。

local async = require("NeoAI.utils.async")

local M = {}

-- ========== 私有状态 ==========

-- 异步兜底失败的上报回调。utils/ 不依赖任何项目模块，故不直接 require kernel.logger；
-- 由内核层（kernel/logger 加载时）注入以接入统一日志，未注入时退化为 vim.notify 提示。
local _async_error_reporter = nil

--- 注入异步错误上报函数（由内核层设置以接入统一日志）。
--- @param fn function(message: string)
function M.set_async_error_reporter(fn)
  _async_error_reporter = fn
end

--- 上报一次异步兜底错误（优先注入的回调，其次 vim.notify）。
--- @param message string
local function _report_async_error(message)
  if _async_error_reporter then
    local ok = pcall(_async_error_reporter, message)
    if ok then return end
  end
  vim.schedule(function() vim.notify(message, vim.log.levels.ERROR) end)
end

-- ========== 私有常量 ==========

-- 工作线程内统一执行器（主进程线程池与后台 worker 进程共用源码）
local RUNNERS = require("NeoAI.utils.worker_runner")
local WORKER_RUNNER = RUNNERS.RUNNER
local WORKER_CODEC_RUNNER = RUNNERS.CODEC_RUNNER

-- ========== 私有状态 ==========

local has_new_work = vim.uv ~= nil and type(vim.uv.new_work) == "function"

-- string.dump 缓存（弱键）：避免每次调用重复序列化同一工作函数。
local dump_cache = setmetatable({}, { __mode = "k" })

-- ========== 私有函数 ==========

--- 序列化工作函数（带缓存）
--- @param fn function
--- @return string|nil code
--- @return string|nil err
local function _dump(fn)
  local cached = dump_cache[fn]
  if cached then return cached end
  local ok, code = pcall(string.dump, fn)
  if not ok then return nil, tostring(code) end
  dump_cache[fn] = code
  return code
end

--- 主进程线程池执行（本地回退 / 自检 / 测试）。
local function _local_run_code(code, ...)
  local d = async.Deferred.new()
  local ctx_ok, ctx = pcall(vim.uv.new_work, WORKER_RUNNER, function(out)
    if out and out:sub(1, 1) == "\1" then
      d:resolve(out:sub(2))
    else
      d:reject({ kind = "work", message = (out and out:sub(2)) or "工作线程异常退出" })
    end
  end)
  if not ctx_ok then
    return async.reject({ kind = "work", message = "创建工作线程失败: " .. tostring(ctx) })
  end
  local queued, qerr = ctx:queue(code, ...)
  if not queued then
    return async.reject({ kind = "work", message = "工作线程入队失败: " .. tostring(qerr) })
  end
  return d
end

local function _local_run_codec_code(code, payload, ...)
  local d = async.Deferred.new()
  local ctx_ok, ctx = pcall(vim.uv.new_work, WORKER_CODEC_RUNNER, function(out)
    if out and out:sub(1, 1) == "\1" then
      local ok, decoded = pcall(vim.mpack.decode, out:sub(2))
      if ok then
        if decoded == vim.NIL then decoded = nil end
        d:resolve(decoded)
      else
        d:reject({ kind = "work", message = "工作线程返回解码失败: " .. tostring(decoded) })
      end
    else
      d:reject({ kind = "work", message = (out and out:sub(2)) or "工作线程异常退出" })
    end
  end)
  if not ctx_ok then
    return async.reject({ kind = "work", message = "创建工作线程失败: " .. tostring(ctx) })
  end
  local queued, qerr = ctx:queue(code, payload, ...)
  if not queued then
    return async.reject({ kind = "work", message = "工作线程入队失败: " .. tostring(qerr) })
  end
  return d
end

--- 远程 worker（主进程只做 UI；工作函数在独立进程内并行执行）。
--- 延迟 require，避免 utils/work ←→ utils/remote_work 的加载环。
--- @return table|nil
local function _remote()
  local ok, r = pcall(require, "NeoAI.utils.remote_work")
  if ok and type(r) == "table" then return r end
  return nil
end

--- 估算原始参数规模（用于 large 模式阈值）。
local function _raw_size(code, ...)
  local n = #code
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    local t = type(v)
    if t == "string" then n = n + #v
    elseif t == "number" or t == "boolean" then n = n + 8
    end
  end
  return n
end

--- 判断参数中是否有 nil 空洞（table 无法无歧义 mpack 编码）。
local function _has_nil(...)
  local n = select("#", ...)
  for i = 1, n do
    if select(i, ...) == nil then return true end
  end
  return false
end

--- 是否全部为可安全跨进程的原始类型（table/cdata/function 不进入原始参数）。
local function _all_primitive(...)
  local n = select("#", ...)
  for i = 1, n do
    local t = type(select(i, ...))
    if t ~= "string" and t ~= "number" and t ~= "boolean" then return false end
  end
  return true
end

-- ========== 公开 API ==========

--- 是否支持工作线程
--- @return boolean
function M.available()
  return has_new_work
end

--- 强制要求工作线程可用（本插件已不提供同步回退）。启动时调用，缺失即显式报错。
--- 除校验 vim.uv.new_work 外，还会跑一次 worker 往返自检（见 `M.selfcheck`）。
function M.require()
  if not has_new_work then
    error("[NeoAI.work] 需要 Neovim 0.10+ 的 vim.uv.new_work；多线程卸载不可用", 2)
  end
  M.selfcheck()
end

--- libuv 线程池目标大小（**I/O 型**并发，与 CPU 预算无关）。
---
--- 为什么不复用 `core_budget()`（`max(1, 核数-2)`）：
---   1. 池里的任务绝大多数是**阻塞 I/O**（read/write/stat/fsync）或读盘后的哈希计算，
---      线程大部分时间在等内核，并不占 CPU。「预留 2 核给 nvim/UI」这个 CPU 预算前提
---      在 I/O 线程上不成立。
---   2. 2 核宿主上 `max(1, 2-2) = 1` 会把 libuv 池压成**单线程**——连 libuv 默认的 4 都不到。
---      而 `vim.uv.fs_*`（nvim 自身所有异步文件操作）与 `work.run` **共享同一个池**，
---      于是整个编辑器的异步 I/O 全部串行。
---      实测（2 核 / 64 个 20ms 任务）：池=1 时约 1290ms（纯串行）；即使把 `work.batched`
---      的并发上限提到 4 仍是 1285ms——因为瓶颈是**池线程数**而非提交数。
---      后果：overlay 捕获上千文件时，read_file / edit_file 等无关工具在队列里排到
---      30s 工具超时，run_command 的后处理（捕获/冻结）也迟迟无法返回，表现为
---      「所有工具卡顿、命令执行完却不返回」。
---   3. 故 I/O 并发**下限取 libuv 默认的 4**，并按核数适度放大；上限 16 避免线程过多
---      争抢内存与调度（每线程有独立栈）。
--- @return number
function M.io_threads()
  local cores = require("NeoAI.utils.host").cores()
  return math.min(math.max(4, cores * 2), 16)
end

--- 实际工作并行度（`work.batched` 的批并发上限）。
--- 取 libuv 池大小（`M.io_threads()`），并限制在用户显式设置的 `UV_THREADPOOL_SIZE` 内，
--- 避免提交数超过池容量后只是排队堆积。
---
--- 资源压力收敛：内存/CPU 紧张时降低提交并发度（warn 减半、critical 降到 1/4），
--- 把 CPU 让给 nvim 主循环与 sshd。注意这里只收敛**提交数**，不动线程池大小
--- （`configure_threadpool` 设置的是 libuv 全局池，创建后不可变，见其注释）。
--- critical 仍保底 2 路：压到 1 会让 I/O 完全串行，工具重新退化为「卡到超时」。
--- @return number
function M.parallelism()
  local n = M.io_threads()
  local pool = tonumber(vim.env.UV_THREADPOOL_SIZE)
  if pool and pool > 0 and n > pool then n = pool end
  -- 压力收敛（探测模块缺失时按 ok 处理，保持原有行为）
  local ok, pressure = pcall(require, "NeoAI.kernel.pressure")
  if ok and pressure.degrade_enabled("thread_pool") then
    local lvl = pressure.level()
    if lvl == "critical" then
      n = math.max(2, math.ceil(n / 4))
    elseif lvl == "warn" then
      n = math.ceil(n / 2)
    end
  end
  return math.max(2, n)
end

--- 启动早期设置 libuv 线程池大小（`UV_THREADPOOL_SIZE`），使 `new_work` 能用上多核。
--- 必须在 libuv 线程池首次创建（任何 worker/异步 fs 任务）之前调用才生效；用户已显式
--- 设置该环境变量时尊重用户值。libuv 线程池大小一旦创建不可再变，故只能尽力而为。
--- 注：因「创建后不可变」，资源压力降级不在此处生效（运行期无法缩小池），
--- 而是收敛 `M.parallelism()` 的提交并发度。
--- @return number 目标线程数（未改写环境变量时返回既有的用户值）
function M.configure_threadpool()
  local cur = vim.env.UV_THREADPOOL_SIZE
  if cur and cur ~= "" then
    return tonumber(cur) or M.io_threads()
  end
  local n = M.io_threads()
  vim.env.UV_THREADPOOL_SIZE = tostring(n)
  return n
end

--- 工作线程自检：在 worker 内跑一次结构化往返，验证 `vim.mpack` 可用。
--- 这是 `run_codec` 的硬前提（worker 内必须能编解码 table）。同步等待至多
--- `opts.timeout_ms`（默认 5000ms）；无法同步等待（如 fast context）时退化为异步检查，
--- 失败仅记录日志，不阻塞启动。
--- @param opts table|nil { timeout_ms?: number }
--- @return boolean 是否完成同步校验（异步退化时返回 true）
function M.selfcheck(opts)
  opts = opts or {}
  -- 自检必须走本地线程池：远程 worker 的启动/握手由 remote_work 自己校验，不能在
  -- setup 阶段同步等待它（否则会把首次启动延迟转嫁到用户初始化）。
  local code, derr = _dump(function(data)
    return { mpack = (type(vim) == "table" and type(vim.mpack) == "table"), v = data.v }
  end)
  if not code then
    error("[NeoAI.work] 自检函数序列化失败: " .. tostring(derr), 2)
  end
  local payload = vim.mpack.encode({ v = 1 })
  local d = _local_run_codec_code(code, payload)
  local done, ok, err = false, nil, nil
  d:then_(function(r)
    ok = (type(r) == "table" and r.mpack == true and r.v == 1)
    done = true
  end, function(e)
    err = e
    done = true
  end)
  local waited = pcall(vim.wait, opts.timeout_ms or 5000, function() return done end, 10)
  if not waited then
    -- 当前上下文不允许同步等待：异步兜底，仅在失败时记录日志。
    d:then_(nil, function(e)
      _report_async_error("[NeoAI.work] 工作线程自检失败: "
        .. tostring(type(e) == "table" and (e.message or e.kind) or e))
    end)
    return true
  end
  if not done then
    error("[NeoAI.work] 工作线程自检超时（worker 未响应）", 2)
  end
  if err then
    error("[NeoAI.work] 工作线程自检失败: "
      .. tostring(type(err) == "table" and (err.message or err.kind) or err), 2)
  end
  if not ok then
    error("[NeoAI.work] 工作线程缺少 vim.mpack，结构化卸载不可用", 2)
  end
  return true
end

--- 在线程池中执行纯 Lua 计算
--- 工作函数 fn 会经 string.dump 序列化后在独立线程运行，因此：
--- - 只能通过参数传递输入（全部为原始类型：string/number/boolean/nil）
--- - fn 不能捕获外部 upvalue；线程内无 `vim.fn`，且禁止调用 `vim.api.*`（非线程安全）；
---   可用纯 Lua 标准库、`vim.uv` 与 `vim.mpack`/`vim.json` 等纯函数
--- - 返回值应为 string（nil/其它原始类型会自动 tostring；table 用 `run_codec`）
--- 函数体内抛错时以 reject 返回，不会让线程崩溃或卡住主循环。
--- 每个任务独立 new_work（线程池负责排队），回调可关联到本 Deferred，可并发发起。
--- @param fn function(...) -> string|nil 自包含的纯 Lua 函数（会被 string.dump）
--- @param ... any 传给 fn 的输入（仅原始类型）
--- @return Deferred resolve(string), reject({ kind="work", message })
function M.run(fn, ...)
  if not has_new_work then
    return async.reject({ kind = "work", message = "工作线程不可用（需要 Neovim 0.10+ 的 vim.uv.new_work）" })
  end
  if type(fn) ~= "function" then
    return async.reject({ kind = "work", message = "work.run 需要函数参数" })
  end

  local code, derr = _dump(fn)
  if not code then
    return async.reject({ kind = "work", message = "工作函数序列化失败: " .. tostring(derr) })
  end

  local remote = _remote()
  local bytes = _raw_size(code, ...)
  if remote and _all_primitive(...) and remote.should_offload(bytes) then
    local args = {}
    local n = select("#", ...)
    for i = 1, n do args[i] = select(i, ...) end
    return remote.run(code, args, { kind = "run", bytes = bytes })
  end
  return _local_run_code(code, ...)
end

--- 在线程池中执行「结构化输入 → 结构化输出」的纯 Lua 计算。
--- 主线程把 input 经 `vim.mpack` 编码为二进制单串传入（规避 table 不能跨线程），工作线程内
--- 用 `vim.mpack` 解码；fn(data, ...extras) 返回任意可 msgpack 化的值；主线程解码结果。
--- 相比 JSON：更快、原生支持二进制（无需 base64 哨兵）、不依赖纯 Lua 编解码源码。
--- 约束同 `M.run`：fn 必须自包含（无 upvalue / require），worker 内可用 `vim.mpack`/`vim.uv`，
--- 但不可调用会触及 nvim 主状态的 `vim.api`/`vim.fn`。
--- @param fn function(data:any, ...):any
--- @param input any 可 msgpack 化的输入（table/string/number/boolean）
--- @param ... any 额外原始类型参数
--- @return Deferred resolve(解码后的结果), reject({ kind="work", message })
function M.run_codec(fn, input, ...)
  if not has_new_work then
    return async.reject({ kind = "work", message = "工作线程不可用（需要 Neovim 0.10+ 的 vim.uv.new_work）" })
  end
  if type(fn) ~= "function" then
    return async.reject({ kind = "work", message = "work.run_codec 需要函数参数" })
  end
  local code, derr = _dump(fn)
  if not code then
    return async.reject({ kind = "work", message = "工作函数序列化失败: " .. tostring(derr) })
  end
  local ok_enc, payload = pcall(vim.mpack.encode, input == nil and {} or input)
  if not ok_enc then
    return async.reject({ kind = "work", message = "输入 msgpack 编码失败: " .. tostring(payload) })
  end

  local remote = _remote()
  local bytes = _raw_size(code, payload, ...)
  if remote and _all_primitive(...) and remote.should_offload(bytes) then
    local extras = {}
    local n = select("#", ...)
    for i = 1, n do extras[i] = select(i, ...) end
    return remote.run_codec(code, payload, extras, { kind = "run_codec", bytes = bytes })
  end
  return _local_run_codec_code(code, payload, ...)
end

--- 重置（测试用）
function M.reset()
  has_new_work = vim.uv ~= nil and type(vim.uv.new_work) == "function"
end

--- 分批并发执行：每次最多 `limit` 个在途任务，完成一批再提交下一批。
--- 避免一次性向 libuv 线程池（默认 4 线程）排入数百个 chunk job，使后续 UI 关键 job
--- （脱敏 / 密钥 token 化 / 落盘）不必排在全部 chunk 之后（表现为工具结果迟迟不返回）。
--- @param tasks table 任务数组
--- @param limit number 每批并发上限
--- @param start function(task) -> Deferred 启动单个任务（在主线程调用，可创建闭包）
--- @return Deferred resolve(结果数组，按 tasks 顺序)
function M.batched(tasks, limit, start)
  limit = math.max(1, tonumber(limit) or 4)
  local out = {}
  local d = async.Deferred.new()
  local i = 0
  local function step()
    if i >= #tasks then d:resolve(out); return end
    local group = {}
    for _ = 1, limit do
      i = i + 1
      if i > #tasks then break end
      group[#group + 1] = { idx = i, res = start(tasks[i]) }
    end
    local pending = #group
    for _, g in ipairs(group) do
      local gi = g
      gi.res:then_(function(v)
        out[gi.idx] = v
        pending = pending - 1
        if pending == 0 then step() end
      end, function(e)
        d:reject(e)
      end)
    end
  end
  step()
  return d
end

return M