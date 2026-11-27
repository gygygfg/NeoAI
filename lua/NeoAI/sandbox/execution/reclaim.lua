--- 崩溃回收：孤儿进程 / 陈旧临时目录
--- @module 'NeoAI.sandbox.execution.reclaim'
---
--- nvim 被内核 OOM 杀（或 SIGKILL）时来不及执行 `sandbox.shutdown()`，会留下：
---   * 被 init 收养的 bpftrace / socat / bwrap（观测探针、网络代理桥、overlay 挂载）；
---   * 每个测试进程的 `sandbox_tests_<pid>` 沙箱（可达数百个、数百 MB）；
---   * 每个进程一份 `/var/tmp/.cache-<tag>` 私有暂存根（单测/多实例累积到 GB 级）。
--- 这些残留既占磁盘，也让「同一个 overlay upper 被多个 bwrap 并行挂载」的几率上升
--- （内核 overlayfs 明确不支持，属未定义行为）。此模块在启动后与 `:NeoAI SandboxGC`
--- 里做一次有界清理：只动「明确属于本沙箱且父进程已死」的进程，以及超过 24h 的临时目录。

local M = {}

-- 默认只清理「明确无人使用」的临时目录：
--   * `sandbox_tests_<pid>`（测试进程沙箱）超过 24h；
--   * `/var/tmp/.cache-<tag>`（每进程暂存根）超过 7 天——目录名不含 pid，无法判断是否有
--     长跑实例仍在使用，故用更长的保留期，避免误删运行中实例的 overlay。
local STALE_SECONDS = 24 * 60 * 60
local DIR_STALE_SECONDS = 7 * 24 * 60 * 60

local function _store_root()
  -- 用**基根**（所有实例的父目录）：孤儿进程属于上一个 nvim 进程，其 cmdline 里是
  -- `<base>/instances/<旧 pid>_<ts>`，不能拿本进程的实例根去匹配。
  local ok_sb, sb = pcall(require, "NeoAI.sandbox")
  if ok_sb and type(sb.base_root) == "function" then
    local b = sb.base_root()
    if type(b) == "string" and b ~= "" then return (b:gsub("/+$", "")) end
  end
  return (vim.fn.stdpath("cache") .. "/NeoAI/sandbox"):gsub("/+$", "")
end

--- 读取 `/proc/<pid>/stat` 的 ppid 与 comm（comm 在括号内，可能含空格）。
--- @param pid number|string
--- @return number|nil ppid
--- @return string|nil comm
local function _proc_stat(pid)
  local f = io.open("/proc/" .. tostring(pid) .. "/stat", "r")
  if not f then return nil, nil end
  local line = f:read("*l") or ""
  f:close()
  local lparen = line:find("(", 1, true)
  local rparen = line:match(".*()%)")
  if not lparen or not rparen then return nil, nil end
  local comm = line:sub(lparen + 1, rparen - 1)
  local rest = line:sub(rparen + 2)
  local ppid = tonumber(rest:match("^(%S+)"))
  return ppid, comm
end

--- 读取进程命令行（NUL 分隔参数用空格连接）。
--- @param pid number|string
--- @return string
local function _cmdline(pid)
  local f = io.open("/proc/" .. tostring(pid) .. "/cmdline", "rb")
  if not f then return "" end
  local raw = f:read("*a") or ""
  f:close()
  return (raw:gsub("%z", " "))
end

--- 列出 /proc 下的数字 pid
--- @return number[]
local function _pids()
  local out = {}
  local handle = vim.uv.fs_scandir("/proc")
  if not handle then return out end
  while true do
    local name = vim.uv.fs_scandir_next(handle)
    if not name then break end
    local pid = tonumber(name)
    if pid then out[#out + 1] = pid end
  end
  return out
end

-- ========== 公开 API ==========

--- 清理「属于本沙箱、但父进程已死」的孤儿进程（bpftrace/socat/bwrap）。
--- 判据三件套：ppid==1（已被 init 收养）+ cmdline 含本沙箱存储根 + 可执行名命中白名单。
--- 绝不按名字杀其它进程（同名的正常 bpftrace/socat 不受影响）。
--- @param opts table|nil { dry_run?: boolean }
--- @return table { killed = string[], scanned = number }
function M.reap_orphans(opts)
  opts = opts or {}
  local root = _store_root()
  -- 只保留存储根的最后一段作为特征，避免误匹配到父目录下的其它项目。
  local needle = root
  local killed, scanned = {}, 0
  for _, pid in ipairs(_pids()) do
    scanned = scanned + 1
    local ppid, comm = _proc_stat(pid)
    if ppid == 1 and comm then
      local is_child = comm == "bpftrace" or comm == "socat" or comm == "bwrap"
      if is_child then
        local cmd = _cmdline(pid)
        if cmd:find(needle, 1, true) then
          if opts.dry_run then
            killed[#killed + 1] = tostring(pid) .. ":" .. comm
          else
            -- 先 SIGTERM，10s 后由内核回收；bwrap 的 --die-with-parent 也会连带清理载荷。
            local ok = pcall(vim.uv.kill, pid, 15)
            if ok then killed[#killed + 1] = tostring(pid) .. ":" .. comm end
          end
        end
      end
    end
  end
  return { killed = killed, scanned = scanned }
end

--- 目录 mtime（秒）；不存在返回 nil。
--- @param path string
--- @return number|nil
local function _mtime(path)
  local st = vim.uv.fs_stat(path)
  return st and st.mtime and tonumber(st.mtime.sec) or nil
end

--- 清理超过 `max_age` 的沙箱临时目录：
---   * `<cache>/NeoAI/sandbox_tests_*`（测试进程沙箱）
---   * `/var/tmp/.cache-*` / `/dev/shm/.cache-*`（每进程私有暂存根，仅删本插件命名形态）
--- 当前进程的目录永不删除。
--- @param opts table|nil { max_age?: number, dry_run?: boolean }
--- @return table { removed = string[], bytes = number }
function M.reap_dirs(opts)
  opts = opts or {}
  local max_age = tonumber(opts.max_age) or STALE_SECONDS
  local now = os.time()
  local self_pid = tostring(vim.fn.getpid())
  local removed, bytes = {}, 0
  local function maybe(path, age)
    if path:find(self_pid, 1, true) then return end
    local mt = _mtime(path)
    local need = tonumber(age) or max_age
    if not mt or (now - mt) < need then return end
    if opts.dry_run then
      removed[#removed + 1] = path
      return
    end
    local ok = pcall(vim.fn.delete, path, "rf")
    if ok then removed[#removed + 1] = path end
  end
  local cache = vim.fn.stdpath("cache") .. "/NeoAI"
  local h = vim.uv.fs_scandir(cache)
  if h then
    while true do
      local name = vim.uv.fs_scandir_next(h)
      if not name then break end
      if name:match("^sandbox_tests_%d+$") then maybe(cache .. "/" .. name, STALE_SECONDS) end
    end
  end
  for _, base in ipairs({ "/var/tmp", "/dev/shm" }) do
    local hb = vim.uv.fs_scandir(base)
    if hb then
      while true do
        local name = vim.uv.fs_scandir_next(hb)
        if not name then break end
        if name:match("^%.cache%-%x+$") then maybe(base .. "/" .. name, DIR_STALE_SECONDS) end
      end
    end
  end
  return { removed = removed, bytes = bytes }
end

--- 一次性执行（启动/`:NeoAI SandboxGC`）：回收孤儿进程 + 陈旧目录，写一条日志摘要。
--- @param opts table|nil { dry_run?: boolean, max_age?: number }
--- @return table
function M.run(opts)
  local orphan = M.reap_orphans(opts)
  local dirs = M.reap_dirs(opts)
  local out = { orphans = orphan, dirs = dirs }
  if #orphan.killed > 0 or #dirs.removed > 0 then
    pcall(function()
      require("NeoAI.kernel.logger").info(
        "[sandbox] 崩溃回收：孤儿进程 %d（%s），陈旧临时目录 %d",
        #orphan.killed, table.concat(orphan.killed, ","), #dirs.removed)
    end)
  end
  return out
end

return M
