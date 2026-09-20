--- 沙箱行为观测（eBPF / strace / procfs）
--- @module NeoAI.sandbox.observer
--- 通过内核层观测沙箱进程的**真实行为**（文件打开、网络连接、进程执行），用于：
---   * 「越界访问留痕」——以实际打开的路径判定，而非解析命令字符串；
---   * 「⚠ 密钥」告警——以实际访问的密钥文件判定；
--- 观测事件按沙箱 attempt 的 cgroup 精确归属（cgroup v2 目录 inode = `cgroup` 内建值）。
---
--- 后端优先级（可配置）：`ebpf`（bpftrace）→ `strace` → `procfs`（/proc/<pid>/fd）。
--- 均不可用时返回 nil，由调用方回退到命令解析启发式（`tools/executor` 既有逻辑）。
--- 观测为**尽力而为**：失败/缺失只降级，不阻断工具执行（除非配置 fail_closed）。
---
--- 约束：eBPF 需 root + bpftrace；strace 需可执行文件（经命令前缀包裹）；procfs 仅能观测
--- 文件打开/执行（无法可靠观测网络），且为轮询采样、可能漏掉瞬时进程。

local config_store = require("NeoAI.kernel.config_store")
local logger = require("NeoAI.kernel.logger")

local M = {}

-- ========== 私有常量 ==========

--- bpftrace 探针脚本：按 `$1`（cgroup id）过滤，输出制表符分隔事件行。
--- F=file / X=exec / N=net；路径由 Lua 侧清洗（制表符/换行）。
local BTRACE_SCRIPT = table.concat({
  'tracepoint:syscalls:sys_enter_openat /cgroup == $1/ {',
  '  printf("F\\topenat\\t%d\\t%s\\n", pid, str(args->filename));',
  '}',
  'tracepoint:syscalls:sys_enter_open /cgroup == $1/ {',
  '  printf("F\\topen\\t%d\\t%s\\n", pid, str(args->filename));',
  '}',
  'tracepoint:syscalls:sys_enter_execve /cgroup == $1/ {',
  '  printf("X\\texecve\\t%d\\t%s\\n", pid, str(args->filename));',
  '}',
  'tracepoint:syscalls:sys_enter_connect /cgroup == $1/ {',
  '  $sa = (struct sockaddr *)args->uservaddr;',
  '  $fam = $sa->sa_family;',
  '  if ($fam == 2) {',
  '    $sin = (struct sockaddr_in *)$sa;',
  '    printf("N\\tconnect\\t%d\\t%s:%d\\n", pid, ntop($fam, $sin->sin_addr.s_addr), bswap($sin->sin_port));',
  '  } else if ($fam == 10) {',
  '    $sin6 = (struct sockaddr_in6 *)$sa;',
  '    printf("N\\tconnect\\t%d\\t[%s]:%d\\n", pid, ntop($fam, $sin6->sin6_addr.in6_u.u6_addr32), bswap($sin6->sin6_port));',
  '  } else {',
  '    printf("N\\tconnect\\t%d\\tfamily=%d\\n", pid, $fam);',
  '  }',
  '}',
}, "\n")

local DEFAULT_POLL_MS = 200

-- ========== 私有状态 ==========

local state = {
  backend = nil,        -- 探测结果缓存（"ebpf"|"strace"|"procfs"|"heuristic"）
  backend_reason = nil,
  notified = false,     -- 启动探测通知只发一次
}

-- ========== 私有函数 ==========

--- 观测配置
--- @return table
local function _cfg()
  return config_store.get("tools.sandbox.observe") or {}
end

--- @return boolean
local function _is_root()
  return vim.uv.getuid ~= nil and vim.uv.getuid() == 0
end

--- tracefs 是否可用（bpftrace 挂载探针所需）
--- @return boolean
local function _tracefs_ok()
  return vim.fn.isdirectory("/sys/kernel/tracing/events") == 1
    or vim.fn.isdirectory("/sys/kernel/debug/tracing/events") == 1
end

--- 内核 BTF 是否可用（tracepoint 结构体解析/强制转换所需）
--- @return boolean
local function _btf_ok()
  return vim.fn.filereadable("/sys/kernel/btf/vmlinux") == 1
end

--- 清洗观测到的路径：去掉控制字符，防止注入事件行。
--- @param s string|nil
--- @return string
local function _clean(s)
  if type(s) ~= "string" then return "" end
  return (s:gsub("[%z\1-\31\127]", ""))
end

-- ========== 事件解析（导出供测试） ==========

--- 解析一行 bpftrace 输出为事件
--- @param line string
--- @return table|nil { kind, op, pid, path?, host?, port? }
function M.parse_bpftrace_line(line)
  if type(line) ~= "string" or line == "" then return nil end
  local tag, op, pid, rest = line:match("^(%a)\t([^\t]+)\t(%d+)\t(.*)$")
  if not tag then return nil end
  local pidn = tonumber(pid)
  if tag == "F" then
    return { kind = "file", op = op, pid = pidn, path = _clean(rest) }
  elseif tag == "X" then
    return { kind = "exec", op = op, pid = pidn, path = _clean(rest) }
  elseif tag == "N" then
    local host, port = rest:match("^(.-):(%d+)$")
    if host then
      return { kind = "net", op = op, pid = pidn, host = _clean(host), port = tonumber(port) }
    end
    return { kind = "net", op = op, pid = pidn, host = _clean(rest) }
  end
  return nil
end

--- 解析一行 strace 输出为事件（openat/open/execve/connect）
--- @param line string
--- @return table|nil
function M.parse_strace_line(line)
  if type(line) ~= "string" or line == "" then return nil end
  local pid, rest = line:match("^%[pid%s+(%d+)%]%s+(.*)$")
  if not pid then pid, rest = line:match("^(%d+)%s+(.*)$") end
  if not pid then return nil end
  local pidn = tonumber(pid)
  local path = rest:match('^openat%(%s*[^,]+,%s*"([^"]*)"')
    or rest:match('^open%("([^"]*)"')
    or rest:match('^execve%("([^"]*)"')
  if path then
    local op = rest:match("^([%a_]+)%(") or "open"
    local kind = (op == "execve" or op == "execveat") and "exec" or "file"
    return { kind = kind, op = op, pid = pidn, path = _clean(path) }
  end
  if rest:match("^connect%(") then
    local ip = rest:match('inet_addr%("([^"]+)"%)')
    local port = rest:match("sin_port=htons%((%d+)%)")
    local sun = rest:match('sun_path="([^"]*)"')
    if ip then return { kind = "net", op = "connect", pid = pidn, host = ip, port = tonumber(port) } end
    if sun then return { kind = "net", op = "connect", pid = pidn, host = _clean(sun) } end
    return { kind = "net", op = "connect", pid = pidn, host = "?" }
  end
  return nil
end

-- ========== 后端探测 ==========

--- 探测各后端可用性（含内核条件），并按配置优先级给出选定后端。
--- @return table { ebpf = {ok, reason}, strace = {ok, reason}, procfs = {ok, reason}, backend = string }
function M.probe()
  local out = {}
  if vim.fn.executable("bpftrace") ~= 1 then
    out.ebpf = { ok = false, reason = "未安装 bpftrace" }
  elseif not _is_root() then
    out.ebpf = { ok = false, reason = "需要 root 权限（当前非 root）" }
  elseif not _tracefs_ok() then
    out.ebpf = { ok = false, reason = "内核 tracefs 不可用（未挂载 tracefs）" }
  elseif not _btf_ok() then
    out.ebpf = { ok = false, reason = "内核 BTF 不可用（缺 /sys/kernel/btf/vmlinux）" }
  else
    out.ebpf = { ok = true, reason = "bpftrace" }
  end
  if vim.fn.executable("strace") == 1 then
    out.strace = { ok = true, reason = "strace" }
  else
    out.strace = { ok = false, reason = "未安装 strace" }
  end
  if vim.fn.isdirectory("/proc/self/fd") == 1 then
    out.procfs = { ok = true, reason = "procfs" }
  else
    out.procfs = { ok = false, reason = "/proc 不可用" }
  end
  local cfg = _cfg()
  local order = { "ebpf", "strace", "procfs" }
  if cfg.backend and cfg.backend ~= "" and cfg.backend ~= "auto" then order = { cfg.backend } end
  out.backend = "heuristic"
  if cfg.enabled ~= false then
    for _, b in ipairs(order) do
      if out[b] and out[b].ok then out.backend = b break end
    end
  end
  return out
end

--- 选择观测后端（缓存）。返回 "heuristic" 表示应回退命令解析。
--- @return string backend
--- @return string|nil reason
function M.backend()
  if state.backend then return state.backend, state.backend_reason end
  local p = M.probe()
  state.backend = p.backend
  state.backend_reason = (p.backend ~= "heuristic" and p[p.backend] and p[p.backend].reason)
    or "no kernel observer"
  return state.backend, state.backend_reason
end

--- 启动时探测并通知观测后端选择：eBPF 不可用、回退 strace 且未安装等均 `vim.notify`。
--- 仅在观测启用且未选定 ebpf 时通知；同一进程只通知一次。
function M.notify_backend()
  if state.notified then return end
  state.notified = true
  local cfg = _cfg()
  if cfg.enabled == false or cfg.notify == false then return end
  local p = M.probe()
  if p.backend == "ebpf" then return end
  if not p.ebpf.ok then
    vim.notify("[NeoAI] eBPF 观测不可用：" .. p.ebpf.reason, vim.log.levels.INFO)
  end
  if p.backend == "strace" then
    vim.notify("[NeoAI] 已回退到 strace 观测", vim.log.levels.INFO)
  elseif not p.strace.ok then
    vim.notify("[NeoAI] strace 观测不可用：" .. p.strace.reason, vim.log.levels.INFO)
  end
  if p.backend == "procfs" then
    vim.notify("[NeoAI] 已回退到 procfs 观测（/proc/<pid>/fd）", vim.log.levels.INFO)
  elseif p.backend == "heuristic" then
    vim.notify("[NeoAI] 无内核级观测，已回退命令解析启发式", vim.log.levels.WARN)
  end
end

--- 是否有内核级观测后端可用（非命令解析回退）
--- @return boolean
--- @return string backend
function M.available()
  local b = M.backend()
  return b == "ebpf" or b == "strace" or b == "procfs", b
end

-- ========== eBPF 后端 ==========

--- 线程内解析 bpftrace 输出：按行切分、仅保留文件事件、按路径去重，返回以 `\n` 连接的唯一
--- 路径。自包含（仅字符串操作，无 upvalue），可 `string.dump` 到工作线程执行——把构建/测试
--- 产生的百万级事件的解析移出主线程；主线程只需对去重后的少量路径做留痕/密钥判定。
--- @param text string 若干完整行（以 `\n` 结尾）
--- @return string 唯一路径以 `\n` 连接
local function _parse_file_paths(text)
  local seen, out, n = {}, {}, 0
  local pos = 1
  while true do
    local nl = text:find("\n", pos, true)
    if not nl then break end
    local line = text:sub(pos, nl - 1)
    pos = nl + 1
    local tag, rest = line:match("^(%a)\t[^\t]+\t%d+\t(.*)$")
    if tag == "F" and rest and rest ~= "" then
      local p = (rest:gsub("[%z\1-\31\127]", ""))
      if p ~= "" and not seen[p] then seen[p] = true; n = n + 1; out[n] = p end
    end
  end
  return table.concat(out, "\n")
end

--- @param opts table { cgroup_id, on_event, on_error? }
--- @return table|nil handle
--- @return string|nil err
local function _start_ebpf(opts)
  local cg_id = tonumber(opts.cgroup_id)
  if not cg_id then return nil, "OBSERVE_NO_CGROUP" end
  local work = require("NeoAI.utils.work")
  local offload = work.available()
  local handle = {
    backend = "ebpf", stopped = false, pending = "", ready = false,
    inflight = 0, queue = {},
  }
  local function emit(evt)
    if evt and opts.on_event then pcall(opts.on_event, evt) end
  end
  --- 解析结果（唯一路径串）→ 逐条派发文件事件
  local function emit_encoded(encoded)
    if type(encoded) ~= "string" or encoded == "" then return end
    local pos = 1
    while true do
      local nl = encoded:find("\n", pos, true)
      local p = nl and encoded:sub(pos, nl - 1) or encoded:sub(pos)
      if p ~= "" then emit({ kind = "file", path = p }) end
      if not nl then break end
      pos = nl + 1
    end
  end
  local function parse_sync(text)
    emit_encoded(_parse_file_paths(text))
  end
  -- 有界并发解析：最多 4 个 job 在途，其余排队；避免一次性排满线程池。
  local pump
  local function start_job(text)
    handle.inflight = handle.inflight + 1
    work.run(_parse_file_paths, text):then_(function(encoded)
      handle.inflight = handle.inflight - 1
      emit_encoded(encoded)
      pump()
    end, function()
      handle.inflight = handle.inflight - 1
      pump()
    end)
  end
  pump = function()
    while handle.inflight < 4 and #handle.queue > 0 do
      start_job(table.remove(handle.queue, 1))
    end
  end
  local function dispatch(text)
    if text == "" then return end
    handle.ready = true
    if not offload then parse_sync(text); return end
    handle.queue[#handle.queue + 1] = text
    pump()
  end
  local job = vim.fn.jobstart({ "bpftrace", "-e", BTRACE_SCRIPT, tostring(cg_id) }, {
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      if not data then return end
      -- 末元素可能是未终结的残行，累积到下次
      local text = ""
      if #data > 1 then text = table.concat(data, "\n", 1, #data - 1) .. "\n" end
      if #data >= 1 then handle.pending = handle.pending .. (data[#data] or "") end
      if text ~= "" then dispatch(text) end
    end,
    on_stderr = function(_, data)
      local msg = table.concat(data or {}, " ")
      if msg:find("Attaching", 1, true) then handle.ready = true end
      if opts.on_error and msg:find("ERROR", 1, true) then pcall(opts.on_error, msg) end
    end,
  })
  if job <= 0 then
    return nil, "OBSERVE_BPFTRACE_SPAWN_FAILED"
  end
  handle.job = job
  --- 等待探针挂载完成（最多 ms 毫秒）；返回是否就绪。
  function handle.wait_ready(ms)
    if handle.ready then return true end
    vim.wait(ms or 1000, function() return handle.ready end, 10)
    return handle.ready
  end
  function handle.stop()
    if handle.stopped then return end
    handle.stopped = true
    -- 冲刷残行（best-effort，小量，同步即可）；在途解析 job 的结果仍会异步派发。
    if handle.pending and handle.pending ~= "" then
      local p = handle.pending
      handle.pending = ""
      pcall(parse_sync, p)
    end
    pcall(vim.fn.jobstop, job)
  end
  return handle
end

-- ========== procfs 后端 ==========

--- @param opts table { cgroup_path, on_event, poll_ms? }
--- @return table|nil handle
--- @return string|nil err
local function _start_procfs(opts)
  local cg = opts.cgroup_path
  if type(cg) ~= "string" or cg == "" or vim.fn.isdirectory(cg) ~= 1 then
    return nil, "OBSERVE_NO_CGROUP"
  end
  local poll_ms = tonumber(opts.poll_ms) or DEFAULT_POLL_MS
  local handle = { backend = "procfs", stopped = false, seen = {} }
  local function emit(evt)
    if evt and opts.on_event then pcall(opts.on_event, evt) end
  end
  local function scan_pid(pid)
    local fddir = "/proc/" .. pid .. "/fd"
    local fh = vim.uv.fs_scandir(fddir)
    if not fh then return end
    while true do
      local fd, t = vim.uv.fs_scandir_next(fh)
      if not fd then break end
      if t == "link" or t == nil then
        local target = vim.uv.fs_readlink(fddir .. "/" .. fd)
        if type(target) == "string" and target:sub(1, 1) == "/" then
          local key = pid .. "\0" .. target
          if not handle.seen[key] then
            handle.seen[key] = true
            emit({ kind = "file", op = "open", pid = tonumber(pid), path = _clean(target) })
          end
        end
      end
    end
    local exe = vim.uv.fs_readlink("/proc/" .. pid .. "/exe")
    if type(exe) == "string" then
      local key = pid .. "\0exe\0" .. exe
      if not handle.seen[key] then
        handle.seen[key] = true
        emit({ kind = "exec", op = "execve", pid = tonumber(pid), path = _clean(exe) })
      end
    end
  end
  local function tick()
    if handle.stopped then return end
    local f = io.open(cg .. "/cgroup.procs", "r")
    if f then
      for line in f:lines() do
        local pid = line:match("^(%d+)")
        if pid then scan_pid(pid) end
      end
      f:close()
    end
  end
  local timer = vim.uv.new_timer()
  timer:start(0, poll_ms, vim.schedule_wrap(tick))
  handle.timer = timer
  function handle.stop()
    if handle.stopped then return end
    handle.stopped = true
    pcall(function() timer:stop() end)
    pcall(function() timer:close() end)
  end
  return handle
end

-- ========== strace 后端（命令前缀 + 轮询 trace 文件） ==========

--- 线程内解析 strace 新增行（自包含，可 `string.dump` 到工作线程）：从 offset 起读取新行，
--- 仅保留文件事件（openat/open/execve）路径并按路径去重。构建/测试每秒可产生大量 openat，
--- 逐行纯 Lua 解析此前在主线程进行，会占满主线程；移入线程池后主线程只派发去重路径。
--- 输入 `<trace_path>\n<offset>`；返回 `<new_offset>\n<unique paths...>`。
--- @param encoded string
--- @return string
local function _parse_strace_worker(encoded)
  local nl = encoded:find("\n", 1, true)
  if not nl then return "0\n" end
  local path = encoded:sub(1, nl - 1)
  local offset = tonumber(encoded:sub(nl + 1)) or 0
  local f = io.open(path, "r")
  if not f then return tostring(offset) .. "\n" end
  f:seek("set", offset)
  local seen, out, n = {}, {}, 0
  for line in f:lines() do
    local pid, rest = line:match("^%[pid%s+(%d+)%]%s+(.*)$")
    if not pid then pid, rest = line:match("^(%d+)%s+(.*)$") end
    if pid then
      -- 仅文件打开事件（与 eBPF 后端一致）；execve 归 exec 类，观测消费方不使用。
      local p = rest:match('^openat%(%s*[^,]+,%s*"([^"]*)"')
        or rest:match('^open%("([^"]*)"')
      if p then
        p = p:gsub("[%z\1-\31\127]", "")
        if p ~= "" and not seen[p] then seen[p] = true; n = n + 1; out[n] = p end
      end
    end
  end
  local newoff = f:seek()
  f:close()
  return tostring(newoff) .. "\n" .. table.concat(out, "\n")
end

--- 构造 strace 命令前缀（用于包裹沙箱 argv）。仅 strace 后端可用时返回。
--- 返回的 handle 轮询 trace 文件并解析事件；进程结束后由调用方 `handle.stop()`。
--- @param opts table { attempt_id?, on_event, poll_ms? }
--- @return table|nil prefix
--- @return table|nil handle
function M.strace_prefix(opts)
  if M.backend() ~= "strace" then return nil, nil end
  local dir = vim.fn.stdpath("cache") .. "/NeoAI/observe"
  vim.fn.mkdir(dir, "p")
  local out = string.format("%s/trace_%s_%d.log", dir, tostring(opts.attempt_id or "x"), vim.fn.getpid())
  local prefix = { "strace", "-f", "-qq", "-e", "trace=openat,open,connect,execve", "-o", out, "--" }
  local handle = { backend = "strace", stopped = false, offset = 0 }
  local poll_ms = tonumber(opts.poll_ms) or DEFAULT_POLL_MS
  local work = require("NeoAI.utils.work")
  local function emit_path(p)
    if p ~= "" and opts.on_event then
      pcall(opts.on_event, { kind = "file", op = "open", path = p })
    end
  end
  --- 应用线程内解析结果：更新 offset（单调不回退，避免与同步冲刷竞争）并派发文件事件。
  local function apply(encoded)
    if type(encoded) ~= "string" or encoded == "" then return end
    local nl = encoded:find("\n", 1, true)
    local off = nl and tonumber(encoded:sub(1, nl - 1))
    if off and off > handle.offset then handle.offset = off end
    local pos = (nl or 0) + 1
    while pos <= #encoded do
      local n2 = encoded:find("\n", pos, true)
      local p = n2 and encoded:sub(pos, n2 - 1) or encoded:sub(pos)
      emit_path(p)
      if not n2 then break end
      pos = n2 + 1
    end
  end
  --- 同步冲刷（线程池不可用 / stop 收尾）：逐行解析（含 exec/connect，保持原行为）。
  local function drain_sync()
    local f = io.open(out, "r")
    if not f then return end
    f:seek("set", handle.offset)
    for line in f:lines() do
      local evt = M.parse_strace_line(line)
      if evt and opts.on_event then pcall(opts.on_event, evt) end
    end
    handle.offset = f:seek()
    f:close()
  end
  local function drain()
    if handle.stopped then return end
    if not work.available() then drain_sync(); return end
    if handle.draining then return end
    handle.draining = true
    work.run(_parse_strace_worker, out .. "\n" .. tostring(handle.offset)):then_(function(encoded)
      handle.draining = false
      apply(encoded)
    end, function()
      handle.draining = false
    end)
  end
  local timer = vim.uv.new_timer()
  timer:start(0, poll_ms, vim.schedule_wrap(drain))
  handle.timer = timer
  handle.path = out
  function handle.stop()
    if handle.stopped then return end
    -- 同步冲刷残量（通常很小）：保证 stop 返回前事件已派发。
    drain_sync()
    handle.stopped = true
    pcall(function() timer:stop() end)
    pcall(function() timer:close() end)
  end
  return prefix, handle
end

-- ========== 公开 API ==========

--- 启动一次观测。
--- @param opts table {
---   cgroup_id? number, cgroup_path? string, attempt_id? string,
---   on_event function(evt), on_error? function(msg), poll_ms? number }
--- @return table|nil handle  { backend, stop() }
--- @return string|nil err
function M.start(opts)
  opts = opts or {}
  local backend = M.backend()
  if backend == "ebpf" then
    return _start_ebpf(opts)
  elseif backend == "procfs" then
    return _start_procfs(opts)
  end
  -- strace 需命令前缀包裹，调用方用 M.strace_prefix()；此处不启动。
  return nil, "OBSERVE_BACKEND_UNAVAILABLE: " .. tostring(M.backend and select(2, M.backend()))
end

--- 当前后端描述（诊断用）
--- @return string
function M.describe()
  local b, r = M.backend()
  return b .. (r and ("(" .. r .. ")") or "")
end

--- 重置（测试用）
function M.reset()
  state.backend = nil
  state.backend_reason = nil
  state.notified = false
end

M._clean = _clean
M.BTRACE_SCRIPT = BTRACE_SCRIPT

return M
