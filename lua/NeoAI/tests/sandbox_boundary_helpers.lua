--- 沙箱边界测试共享基建
--- @module NeoAI.tests.sandbox_boundary_helpers
--- 供 test_sandbox_boundary_* 套件复用的测试工具：配置覆盖、真实 bwrap 前缀直跑（绕开
--- conceal 脱敏，用于验证内核真实行为）、宿主侧哨兵文件、宿主残留断言、syscall 探测模板。

local M = {}

--- 配置覆盖（保存/恢复 config_store）。
--- @param overrides table
--- @param fn function
function M.with_config(overrides, fn)
  local config_store = require("NeoAI.kernel.config_store")
  local saved = config_store.get_all()
  local merged = vim.deepcopy(overrides or {})
  merged.tools = merged.tools or {}
  merged.tools.sandbox = merged.tools.sandbox or {}
  if merged.tools.sandbox.ephemeral_roots == nil then
    merged.tools.sandbox.ephemeral_roots = {}
  end
  config_store.load(merged)
  local ok, err = pcall(fn)
  config_store.load(saved)
  if not ok then error(err, 0) end
end

--- 后端是否为 bwrap（真实内核隔离）。
--- @return boolean
function M.bwrap()
  return require("NeoAI.sandbox.execution.runtime").backend() == "bwrap"
end

--- 可执行是否存在
--- @param bin string
--- @return boolean
function M.has(bin)
  return vim.fn.executable(bin) == 1
end

--- 是否 x86_64（syscall 号/架构相关用例）
--- @return boolean
function M.is_x86_64()
  local m = vim.uv.os_uname().machine
  return m == "x86_64" or m == "amd64"
end

--- 用真实 bwrap 前缀直跑 shell 命令（不经 run_command 工具、不经 conceal 脱敏）。
--- @param opts table runtime.process_prefix 选项（cwd 等）
--- @param shell string
--- @return string 输出（stdout+stderr）
--- @return number 退出码
function M.direct(opts, shell)
  local rt = require("NeoAI.sandbox.execution.runtime")
  local prefix = rt.process_prefix(opts or { cwd = "/tmp" })
  assert(prefix, "process_prefix 应可构造（后端不可用？）")
  local cmd = {}
  for _, v in ipairs(prefix) do cmd[#cmd + 1] = v end
  cmd[#cmd + 1] = "/bin/sh"
  cmd[#cmd + 1] = "-c"
  cmd[#cmd + 1] = shell
  local out = vim.fn.system(cmd)
  return out, vim.v.shell_error
end

--- 用真实 bwrap 前缀直跑 python3 -c 脚本。
--- @param opts table
--- @param script string
--- @return string
--- @return number
function M.python(opts, script)
  local rt = require("NeoAI.sandbox.execution.runtime")
  local prefix = rt.process_prefix(opts or { cwd = "/tmp" })
  if not prefix then return "", -1 end
  local cmd = {}
  for _, v in ipairs(prefix) do cmd[#cmd + 1] = v end
  cmd[#cmd + 1] = "python3"
  cmd[#cmd + 1] = "-c"
  cmd[#cmd + 1] = script
  local out = vim.fn.system(cmd)
  return out, vim.v.shell_error
end

-- ========== 宿主侧哨兵文件 ==========

local sentinel_state = {}

--- 在宿主目录下放置带随机标记的哨兵文件（root、用后即删；不碰真实敏感条目）。
--- @param dirs table 目录列表
--- @return table { { path, hash, mode } }
function M.sentinel_place(dirs)
  local marker = "NEOAI_SENTINEL_" .. tostring(math.random(1, 1e9))
  local placed = {}
  for _, dir in ipairs(dirs) do
    if vim.fn.isdirectory(dir) == 1 then
      local path = dir:gsub("/$", "") .. "/.neoai_probe_" .. tostring(math.random(1, 1e9))
      local f = io.open(path, "w")
      if f then
        f:write(marker .. "\n")
        f:close()
        local hash = vim.fn.sha256(marker)
        placed[#placed + 1] = { path = path, hash = hash, marker = marker }
      end
    end
  end
  sentinel_state[marker] = placed
  return placed
end

--- 校验哨兵未被改动。
--- @param placed table
--- @return boolean ok
--- @return string|nil 首个被改动的路径
function M.sentinel_verify(placed)
  for _, s in ipairs(placed or {}) do
    local f = io.open(s.path, "rb")
    if not f then return false, s.path .. " (缺失)" end
    local c = f:read("*a") or ""
    f:close()
    if c:gsub("%s+$", "") ~= s.marker then return false, s.path .. " (内容被改)" end
  end
  return true, nil
end

--- 清理哨兵文件
--- @param placed table
function M.sentinel_clean(placed)
  for _, s in ipairs(placed or {}) do
    pcall(os.remove, s.path)
  end
end

-- ========== syscall 探测模板（x86_64） ==========

-- denylist syscall 号（x86_64）：seccomp 拦截后应返回 EPERM。
M.SYS_DENY = {
  ptrace = 101, pivot_root = 155, adjtimex = 159, chroot = 161, acct = 163,
  settimeofday = 164, mount = 165, umount2 = 166, swapon = 167, swapoff = 168,
  reboot = 169, iopl = 172, ioperm = 173, init_module = 175, delete_module = 176,
  quotactl = 179, clock_settime = 227, kexec_load = 246,
  add_key = 248, request_key = 249, keyctl = 250, unshare = 272,
  perf_event_open = 298, name_to_handle_at = 303, open_by_handle_at = 304,
  clock_adjtime = 305, setns = 308, process_vm_readv = 310, process_vm_writev = 311,
  kcmp = 312, finit_module = 313, bpf = 321, userfaultfd = 323,
  io_uring_setup = 425, open_tree = 428, move_mount = 429,
  fsopen = 430, fsconfig = 431, fsmount = 432, fspick = 433,
  pidfd_getfd = 438, process_madvise = 440, mount_setattr = 442,
}

--- 生成 syscall 探测 python 脚本：对每个 syscall 传 dummy 参数调用，打印 `name=ENO`。
--- seccomp 在参数解引用前拦截，故 dummy 参数安全。
--- @param mapping table name->nr
--- @return string
function M.syscall_script(mapping)
  local items = {}
  for name, nr in pairs(mapping) do items[#items + 1] = ("(%q,%d)"):format(name, nr) end
  table.sort(items)
  return ([[
import ctypes
libc = ctypes.CDLL(None, use_errno=True)
libc.syscall.restype = ctypes.c_long
libc.syscall.argtypes = [ctypes.c_long]*7
for name, nr in [%s]:
    ctypes.set_errno(0)
    libc.syscall(nr, 0, 0, 0, 0, 0, 0)
    print("%%s=%%d" %% (name, ctypes.get_errno()))
]]):format(table.concat(items, ","))
end

return M
