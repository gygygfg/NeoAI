--- 工作线程执行器
--- @module NeoAI.utils.work
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
---   本身也在池里，排队共享。启动时经 `M.configure_threadpool()` 按宿主核数放大
---   （默认 `max(1, 核数-2)`），使大量读写文件的卸载获得真实并行。

local async = require("NeoAI.utils.async")

local M = {}

-- ========== 私有常量 ==========

-- 工作线程内统一执行器：接收 string.dump 出来的函数字节码，load 后 pcall 运行。
-- 返回值用前缀区分成功/失败（线程回调只能拿原始类型，无法安全传异常对象）。
local WORKER_RUNNER = table.concat({
  [[local code = ...]],
  [[local nargs = select("#", ...) - 1]],
  [[local args = {}]],
  [[for i = 1, nargs do args[i] = (select(i + 1, ...)) end]],
  [[local fn = assert(load(code, "=worker", "b"))]],
  [[local unpackx = table.unpack or unpack]],
  [[local ok, res = pcall(fn, unpackx(args, 1, nargs))]],
  [[if ok then]],
  [[  if res == nil then return "\1" end]],
  [[  if type(res) ~= "string" then return "\1" .. tostring(res) end]],
  [[  return "\1" .. res]],
  [[end]],
  [[return "\0" .. tostring(res)]],
}, "\n")

-- 结构化编解码工作线程执行器：入参/出参经 `vim.mpack` 编解码（worker 内同样可用），
-- 使线程函数可接收/返回任意可 msgpack 化的数据（table / 二进制 string）。
-- 参数约定：queue(code, payload, ...extras)。
local WORKER_CODEC_RUNNER = table.concat({
  [[local code, payload = ...]],
  [[if not (vim and vim.mpack) then return "\0worker 线程缺少 vim.mpack" end]],
  [[local nextra = select("#", ...) - 2]],
  [[local extras = {}]],
  [[for i = 1, nextra do extras[i] = (select(i + 2, ...)) end]],
  [[local fn = assert(load(code, "=worker_codec", "b"))]],
  [[local data = vim.mpack.decode(payload)]],
  [[local unpackx = table.unpack or unpack]],
  [[local ok, res = pcall(fn, data, unpackx(extras, 1, nextra))]],
  [[if not ok then return "\0" .. tostring(res) end]],
  [[local ok2, enc = pcall(vim.mpack.encode, res)]],
  [[if not ok2 then return "\0" .. tostring(enc) end]],
  [[return "\1" .. enc]],
}, "\n")

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

--- 实际工作并行度：统一 `max(1, 核数-2)`（`utils.host.core_budget`），并限制在显式设置的
--- libuv 线程池大小（`UV_THREADPOOL_SIZE`）内，避免提交数超过池容量堆积。
--- @return number
function M.parallelism()
  local n = require("NeoAI.utils.host").core_budget()
  local pool = tonumber(vim.env.UV_THREADPOOL_SIZE)
  if pool and pool > 0 and n > pool then n = pool end
  return n
end

--- 启动早期设置 libuv 线程池大小（`UV_THREADPOOL_SIZE`），使 `new_work` 能用上多核。
--- 必须在 libuv 线程池首次创建（任何 worker/异步 fs 任务）之前调用才生效；用户已显式
--- 设置该环境变量时尊重用户值。libuv 线程池大小一旦创建不可再变，故只能尽力而为。
--- @return number 目标线程数（未改写环境变量时返回既有的用户值）
function M.configure_threadpool()
  local cur = vim.env.UV_THREADPOOL_SIZE
  if cur and cur ~= "" then
    return tonumber(cur) or require("NeoAI.utils.host").core_budget()
  end
  local n = require("NeoAI.utils.host").core_budget()
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
  local d = M.run_codec(function(data)
    return { mpack = (type(vim) == "table" and type(vim.mpack) == "table"), v = data.v }
  end, { v = 1 })
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
      require("NeoAI.kernel.logger").error(
        "[NeoAI.work] 工作线程自检失败: %s",
        tostring(type(e) == "table" and (e.message or e.kind) or e))
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

  local d = async.Deferred.new()
  local ctx_ok, ctx = pcall(vim.uv.new_work, WORKER_CODEC_RUNNER, function(out)
    if out and out:sub(1, 1) == "\1" then
      local ok, decoded = pcall(vim.mpack.decode, out:sub(2))
      if ok then
        -- mpack 把 null 解为 vim.NIL；顶层归一为 nil，与旧 JSON 行为一致。
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