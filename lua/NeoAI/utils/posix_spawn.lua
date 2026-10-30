--- POSIX 子进程启动（posix_spawn）
--- @module 'NeoAI.utils.posix_spawn'
--- 为什么不使用 `vim.uv.spawn`/`fork`：
--- - `fork` 会复制父进程页表；主 nvim 加载大量 Lua 堆/缓冲区时，即使写时复制也会造成
---   明显的 RSS 峰值与缺页抖动。
--- - `posix_spawn` 由 libc 使用 vfork/clone 实现，不复制父进程地址空间；适合启动常驻
---   worker 或短生命周期 helper。
---
--- 本模块只负责「启动 / 非阻塞回收 / 信号」；进程池、RPC、单实例由上层管理。
--- 约束：需要 LuaJIT FFI（Neovim 自带）。FFI 不可用时显式报错，不静默退回 fork 式启动。
---
--- 用法：
--- ```lua
--- local ps = require("NeoAI.utils.posix_spawn")
--- local pid, err = ps.spawn({ "/bin/echo", "hi" }, {
---   stdout = "/tmp/echo.log", stderr = "/tmp/echo.log",
---   env = { FOO = "bar" },
--- })
--- ```
--- `stdout`/`stderr` 通过 `/bin/sh -c 'exec "$0" "$@" >>... 2>&1'` 重定向（避免
--- `posix_spawn_file_actions_*` 在不同 libc 实现上的 ABI 差异）。argv 以独立参数传入，
--- 不拼接 shell 字符串，不存在注入。

local M = {}

local ok_ffi, ffi = pcall(require, "ffi")
if not ok_ffi then
  M._error = "LuaJIT FFI 不可用，无法使用 posix_spawn"
  return M
end

pcall(ffi.cdef, [[
typedef int pid_t;
int posix_spawn(pid_t *pid, const char *path, const void *file_actions,
                const void *attrp, char *const argv[], char *const envp[]);
int posix_spawnp(pid_t *pid, const char *file, const void *file_actions,
                 const void *attrp, char *const argv[], char *const envp[]);
int waitpid(int pid, int *status, int options);
]])

local WNOHANG = 1

--- 是否可用
--- @return boolean
function M.available()
  return ok_ffi == true and ffi.C.posix_spawn ~= nil
end

--- 当前进程是否仍存活（不发送信号，仅探测）
--- @param pid number
--- @return boolean
function M.alive(pid)
  if type(pid) ~= "number" or pid <= 0 then return false end
  local ok, res = pcall(vim.uv.kill, pid, 0)
  return ok and res == 0
end

--- 非阻塞回收子进程。
--- @param pid number
--- @return table|nil result { pid, code, signal, exited=true }；仍在运行时返回 nil
function M.reap(pid)
  if type(pid) ~= "number" or pid <= 0 then return nil end
  local status = ffi.new("int[1]", 0)
  local r = ffi.C.waitpid(pid, status, WNOHANG)
  if r == 0 then return nil end
  if r == pid then
    local st = tonumber(status[0]) or 0
    local code = math.floor(st / 256) % 256
    local sig = st % 128
    if sig ~= 0 then code = nil end
    return { pid = pid, code = code, signal = sig ~= 0 and sig or nil, exited = true, status = st }
  end
  -- ECHILD：已被回收 / pid 不属于本进程。视为退出，避免上层永久等待。
  return { pid = pid, code = nil, signal = nil, exited = true, status = nil, unknown = true }
end

--- 发送信号（默认 SIGTERM=15）。
--- @param pid number
--- @param sig number|nil
--- @return boolean ok
--- @return string|nil err
function M.kill(pid, sig)
  if type(pid) ~= "number" or pid <= 0 then return false, "invalid pid" end
  local ok, err = pcall(vim.uv.kill, pid, sig or 15)
  return ok, ok and nil or tostring(err)
end

--- 构造环境变量数组（当前环境 + overrides）。
--- @param overrides table|nil
--- @return char** envp, table anchor
local function _build_env(overrides)
  local env = {}
  local ok, cur = pcall(vim.fn.environ)
  if ok and type(cur) == "table" then
    for k, v in pairs(cur) do
      if type(k) == "string" and k ~= "" and v ~= nil then env[k] = tostring(v) end
    end
  elseif vim.uv and type(vim.uv.os_environ) == "function" then
    local ok2, cur2 = pcall(vim.uv.os_environ)
    if ok2 and type(cur2) == "table" then
      for k, v in pairs(cur2) do
        if type(k) == "string" and k ~= "" and v ~= nil then env[k] = tostring(v) end
      end
    end
  end
  for k, v in pairs(overrides or {}) do
    if v == nil then env[k] = nil else env[k] = tostring(v) end
  end

  local keys = {}
  for k in pairs(env) do keys[#keys + 1] = k end
  table.sort(keys)
  local n = #keys
  local argv = ffi.new("char *[?]", n + 1)
  local anchor = {}
  for i, k in ipairs(keys) do
    local s = k .. "=" .. env[k]
    anchor[i] = s
    argv[i - 1] = ffi.cast("char *", s)
  end
  argv[n] = nil
  return argv, anchor
end

--- 构造 argv 数组（保持 Lua 字符串锚定，避免被 GC）。
--- @param list table
--- @return char** argv, table anchor
local function _build_argv(list)
  local n = #list
  local argv = ffi.new("char *[?]", n + 1)
  local anchor = {}
  for i = 1, n do
    local s = tostring(list[i])
    anchor[i] = s
    argv[i - 1] = ffi.cast("char *", s)
  end
  argv[n] = nil
  return argv, anchor
end

--- 通过 `/bin/sh -c` 重定向 stdio 并执行 argv。
--- `script` 固定，argv 作为 `$0`/`$@` 传入，不拼接。
--- @param list table 原始 argv
--- @param opts table { stdout?, stderr?, stdin?, env? }
--- @return number|nil pid
--- @return string|nil err
local function _spawn_redirected(list, opts)
  local sh = (vim.fn.executable("sh") == 1) and "/bin/sh" or nil
  if not sh then return nil, "找不到 /bin/sh" end
  local script = 'exec "$0" "$@"'
  local stdin = opts.stdin
  if stdin then
    script = script .. ' <"$NEOAI_SPAWN_STDIN"'
  else
    script = script .. " </dev/null"
  end
  if opts.stdout then
    script = script .. ' >>"$NEOAI_SPAWN_STDOUT"'
  end
  if opts.stderr then
    script = script .. ' 2>>"$NEOAI_SPAWN_STDERR"'
  elseif opts.stdout then
    script = script .. " 2>&1"
  end
  local argv_list = { sh, "-c", script }
  for _, a in ipairs(list) do argv_list[#argv_list + 1] = a end
  local env = {}
  for k, v in pairs(opts.env or {}) do env[k] = v end
  if opts.stdin then env.NEOAI_SPAWN_STDIN = opts.stdin end
  if opts.stdout then env.NEOAI_SPAWN_STDOUT = opts.stdout end
  if opts.stderr then env.NEOAI_SPAWN_STDERR = opts.stderr end
  return M.spawn(argv_list, { env = env, redirect = false })
end

--- 启动子进程。
--- @param list table argv（第一个元素为可执行文件路径；含 `/` 用 posix_spawn，否则用 posix_spawnp）
--- @param opts table|nil
---   { env?: table, stdout?: string, stderr?: string, stdin?: string, redirect?: boolean }
--- @return number|nil pid
--- @return string|nil err
function M.spawn(list, opts)
  if not M.available() then return nil, M._error or "posix_spawn 不可用" end
  if type(list) ~= "table" or #list == 0 then return nil, "argv 不能为空" end
  opts = opts or {}
  if opts.redirect ~= false and (opts.stdout or opts.stderr or opts.stdin) then
    return _spawn_redirected(list, opts)
  end

  local argv, argv_anchor = _build_argv(list)
  local envp, env_anchor = _build_env(opts.env)
  -- 保持 anchor 引用到 spawn 返回之后（FFI cast 不持有 Lua 字符串）。
  local _keepalive = { argv_anchor, env_anchor }
  local pid_buf = ffi.new("pid_t[1]", 0)
  local path = tostring(list[1])
  local rc
  if path:find("/", 1, true) then
    rc = ffi.C.posix_spawn(pid_buf, path, nil, nil, argv, envp)
  else
    rc = ffi.C.posix_spawnp(pid_buf, path, nil, nil, argv, envp)
  end
  _keepalive = nil
  if rc ~= 0 then
    return nil, string.format("posix_spawn 失败(%d): %s", tonumber(rc) or -1, path)
  end
  local pid = tonumber(pid_buf[0])
  if not pid or pid <= 0 then return nil, "posix_spawn 返回无效 pid" end
  return pid
end

return M
