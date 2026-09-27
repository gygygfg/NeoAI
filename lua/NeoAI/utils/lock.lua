--- 跨进程互斥锁（文件锁）
--- @module NeoAI.utils.lock
--- 用 `O_CREAT|O_EXCL` 创建锁文件实现**跨进程**互斥；不同 key 互不影响，可并行。
--- 用于串行化同一 overlay `work` 目录的挂载：内核 overlayfs 对同一 upper/work 的并发/重叠挂载
--- 会打印 "workdir is in-use as upperdir/workdir of another mount" 并进入未定义行为（可死锁，
--- 进而触发硬件看门狗整机复位）。
---
--- 持有者进程崩溃时锁文件会残留，通过记录 PID 并检测其存活来自动清理陈旧锁。
--- 锁通过文件描述符持有；调用方须在操作结束后 `release()`。

local M = {}

local _boot_id_cache = nil

local function _uv()
  return vim.uv or vim.loop
end

--- 当前内核启动 ID（跨重启区分，避免 PID 复用误判锁存活）
--- @return string
local function _boot_id()
  if _boot_id_cache == nil then
    local f = io.open("/proc/sys/kernel/random/boot_id", "r")
    if f then
      _boot_id_cache = (f:read("*a") or ""):gsub("%s+$", "")
      f:close()
    else
      _boot_id_cache = ""
    end
  end
  return _boot_id_cache
end

--- @return string
local function _dir()
  return (vim.fn.stdpath("cache") or vim.fn.tempname()) .. "/NeoAI/locks"
end

local function _ensure_dir()
  pcall(vim.fn.mkdir, _dir(), "p")
end

--- @param key string
--- @return string
local function _path(key)
  return _dir() .. "/" .. vim.fn.sha256(tostring(key)) .. ".lock"
end

--- 进程是否存活
--- @param pid number|nil
--- @return boolean
local function _alive(pid)
  if not pid or pid <= 0 then return false end
  local ok, res = pcall(_uv().kill, pid, 0)
  if not ok then return false end
  -- luv: 存活返回 0（部分版本 true），进程不存在返回 nil + err
  return res == 0 or res == true
end

--- 读取锁文件记录的 PID 与启动 ID
--- @param path string
--- @return number|nil pid, string|nil boot_id, boolean existed
local function _read_owner(path)
  local f = io.open(path, "r")
  if not f then return nil, nil, false end
  local content = f:read("*a") or ""
  f:close()
  local pid_s, boot = content:match("^(%d+)%s*(%S*)")
  return tonumber(pid_s), (boot ~= "" and boot or nil), true
end

--- 锁文件年龄（秒）；无法 stat 时返回 0
--- @param path string
--- @return number
local function _age_sec(path)
  local st = _uv().fs_stat(path)
  if not st or not st.mtime then return 0 end
  return os.time() - (st.mtime.sec or 0)
end

--- 非阻塞尝试获取锁。成功返回句柄，失败返回 nil（不等待）。
--- @param key string
--- @param depth number|nil 内部重试深度（清理陈旧锁后重试）
--- @return table|nil handle { fd, path, key }
function M.try_acquire(key, depth)
  depth = depth or 0
  _ensure_dir()
  local path = _path(key)
  local fd = _uv().fs_open(path, "wx", 420) -- O_WRONLY|O_CREAT|O_EXCL, 0644
  if fd then
    local ok = pcall(_uv().fs_write, fd, tostring(vim.fn.getpid()) .. " " .. _boot_id() .. "\n")
    if not ok then
      pcall(_uv().fs_close, fd)
      pcall(os.remove, path)
      return nil
    end
    return { fd = fd, path = path, key = key }
  end
  -- 已存在：判断是否为陈旧锁（持有进程已死 / 跨重启 PID 复用 / 超过时限）
  if depth < 3 then
    local pid, boot, existed = _read_owner(path)
    if existed and not pid then
      -- 内容尚未写入（写入窗口）：短暂视为占用，稍后重试
      vim.wait(5)
      return M.try_acquire(key, depth + 1)
    end
    local cur_boot = _boot_id()
    local boot_mismatch = boot ~= nil and cur_boot ~= "" and boot ~= cur_boot
    local dead = (pid ~= nil and not _alive(pid))
    local too_old = _age_sec(path) > 120 -- 探测类锁为短操作；超过 2 分钟必为陈旧
    if dead or boot_mismatch or too_old then
      pcall(os.remove, path)
      return M.try_acquire(key, depth + 1)
    end
  end
  return nil
end

--- 阻塞获取锁（轮询）。超时返回 nil。
--- @param key string
--- @param timeout_ms number|nil 默认 60000
--- @return table|nil handle
function M.acquire(key, timeout_ms)
  local deadline = _uv().hrtime() / 1e6 + (timeout_ms or 60000)
  while true do
    local h = M.try_acquire(key)
    if h then return h end
    if _uv().hrtime() / 1e6 > deadline then return nil end
    vim.wait(20)
  end
end

--- 一次获取多个 key（排序去重后按序获取，避免不同调用方以不同顺序加锁造成死锁）。
--- 任一失败则释放已获取的全部并返回 nil。
--- @param keys string[]
--- @param timeout_ms number|nil
--- @return table[]|nil handles
function M.acquire_all(keys, timeout_ms)
  local uniq = {}
  local seen = {}
  for _, k in ipairs(keys or {}) do
    if type(k) == "string" and k ~= "" and not seen[k] then
      seen[k] = true
      uniq[#uniq + 1] = k
    end
  end
  table.sort(uniq)
  local handles = {}
  for _, k in ipairs(uniq) do
    local h = M.acquire(k, timeout_ms)
    if not h then
      M.release_all(handles)
      return nil
    end
    handles[#handles + 1] = h
  end
  return handles
end

--- 一次非阻塞获取多个 key（排序去重）。任一失败则释放已获取的并返回 nil。
--- @param keys string[]
--- @return table[]|nil handles
function M.try_acquire_all(keys)
  local uniq, seen = {}, {}
  for _, k in ipairs(keys or {}) do
    if type(k) == "string" and k ~= "" and not seen[k] then
      seen[k] = true
      uniq[#uniq + 1] = k
    end
  end
  table.sort(uniq)
  local handles = {}
  for _, k in ipairs(uniq) do
    local h = M.try_acquire(k)
    if not h then
      M.release_all(handles)
      return nil
    end
    handles[#handles + 1] = h
  end
  return handles
end

--- 释放句柄
--- @param h table|nil
function M.release(h)
  if not h then return end
  if h.fd then pcall(_uv().fs_close, h.fd) end
  pcall(os.remove, h.path)
end

--- 释放句柄数组
--- @param handles table|nil
function M.release_all(handles)
  for _, h in ipairs(handles or {}) do M.release(h) end
end

--- 便捷：持锁执行 fn（同步）
--- @param key string
--- @param timeout_ms number|nil
--- @param fn function
--- @return boolean ok, any result
function M.with(key, timeout_ms, fn)
  local h = M.acquire(key, timeout_ms)
  if not h then return false, "LOCK_TIMEOUT" end
  local pok, res = pcall(fn)
  M.release(h)
  if not pok then error(res, 0) end
  return true, res
end

--- 重置（测试用）：清理本进程可清理的锁目录
function M._dir()
  return _dir()
end

return M
