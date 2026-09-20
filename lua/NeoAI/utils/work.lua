--- 工作线程执行器
--- @module NeoAI.utils.work
--- 基于 libuv 线程池（vim.uv.new_work）把纯 Lua 计算移出 nvim 主线程，
--- 避免 CPU 密集 / 阻塞式文件 I/O（如递归目录搜索、大文件读写）卡住主界面。
--- 约束（libuv 线程）：
--- - 工作函数必须以字节码（string.dump）传入：线程内是全新 Lua state，不共享
---   闭包 upvalue / require / vim.fn / vim.api，仅能用参数 + 纯 Lua 标准库 + vim.uv。
--- - 参数与返回值必须是原始类型（string / number / boolean / nil），不能是 table。
--- - 线程池默认 4 个线程，文件系统操作本身也在池里，排队共享。

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

-- ========== 私有状态 ==========

local has_new_work = vim.uv ~= nil and type(vim.uv.new_work) == "function"

-- ========== 私有函数 ==========

--- 无 new_work（nvim < 0.10）时的同步回退：仍走 vim.schedule 保证不阻塞调用栈。
--- @param fn function(...)
--- @param args table 原始类型参数数组
--- @return Deferred
local function _run_sync(fn, args)
  local d = async.Deferred.new()
  vim.schedule(function()
    local ok, res = pcall(fn, unpack(args, 1, #args))
    if ok then
      d:resolve(res)
    else
      d:reject({ kind = "work", message = tostring(res) })
    end
  end)
  return d
end

-- ========== 公开 API ==========

--- 是否支持工作线程
--- @return boolean
function M.available()
  return has_new_work
end

--- 在线程池中执行纯 Lua 计算
--- 工作函数 fn 会经 string.dump 序列化后在独立线程运行，因此：
--- - 只能通过参数传递输入（全部为原始类型：string/number/boolean/nil）
--- - fn 内不能用 require / vim.fn / vim.api / 捕获外部 upvalue；只能用纯 Lua 标准库与 vim.uv
--- - 返回值应为 string（nil/其它原始类型会自动 tostring；table 不保证）
--- 函数体内抛错时以 reject 返回，不会让线程崩溃或卡住主循环。
--- 每个任务独立 new_work（线程池负责排队），回调可关联到本 Deferred，可并发发起。
--- @param fn function(...) -> string|nil 自包含的纯 Lua 函数（会被 string.dump）
--- @param ... any 传给 fn 的输入（仅原始类型）
--- @return Deferred resolve(string), reject({ kind="work", message })
function M.run(fn, ...)
  if not has_new_work then
    return _run_sync(fn, { ... })
  end
  if type(fn) ~= "function" then
    return async.reject({ kind = "work", message = "work.run 需要函数参数" })
  end

  local ok, code = pcall(string.dump, fn)
  if not ok then
    return async.reject({ kind = "work", message = "工作函数序列化失败: " .. tostring(code) })
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