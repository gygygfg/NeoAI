--- 沙箱 seccomp 基线
--- @module NeoAI.sandbox.seccomp
--- 生成并施加 seccomp 基线（设计文档 §7.1）：默认 denylist（只拦危险 syscall）+
--- 设备节点屏障，架构不符直接 KILL。经 `bwrap --seccomp FD` 在沙箱载荷上施加
--- （bwrap 特权设置不被过滤）。
---
--- 默认开启（`tools.sandbox.seccomp.enabled=true`）；无可用过滤器时明确拒绝，
--- 不静默声称已施加。`require_seccomp=true` 时外部进程必须有可用过滤器。

local config_store = require("NeoAI.kernel.config_store")
local fs = require("NeoAI.utils.fs")

local M = {}

-- ========== BPF 常量 ==========

local BPF_LD_ABS = 0x20 -- BPF_LD | BPF_W | BPF_ABS
local BPF_JEQ_K = 0x15  -- BPF_JMP | BPF_JEQ | BPF_K
local BPF_JSET_K = 0x45 -- BPF_JMP | BPF_JSET | BPF_K
local BPF_RET_K = 0x06  -- BPF_RET | BPF_K
local SECCOMP_RET_KILL_PROCESS = 0x80000000
local SECCOMP_RET_ALLOW = 0x7fff0000
local SECCOMP_RET_ERRNO_EPERM = 0x00050000 + 1 -- EPERM
local SECCOMP_RET_ERRNO_ENOSYS = 0x00050000 + 38 -- ENOSYS
local AUDIT_ARCH_X86_64 = 0xC000003E
local AUDIT_ARCH_AARCH64 = 0xC00000B7

-- x86_64 的 x32 ABI 位（__X32_SYSCALL_BIT）：x32 进程的 `seccomp_data.arch` 与 x86_64 相同，
-- 但 syscall 号带该高位。若不做屏蔽，denylist 的精确 JEQ 全部失配 → 整份过滤器被绕过
-- （`syscall(165 | 0x40000000, …)` 仍到达 sys_mount/mknod 处理器）。故带该位一律 KILL。
local X32_SYSCALL_BIT = 0x40000000

-- seccomp_data.args[0] 的偏移（nr@0, arch@4, ip@8, args@16）
local ARG0_OFFSET = 16
local ARG1_OFFSET = 24
local ARG2_OFFSET = 32
-- clone(2) 命名空间标志位：NEWNS/NEWCGROUP/NEWUTS/NEWIPC/NEWUSER/NEWPID/NEWNET。
-- 这些位若出现即拒绝：`unshare`/`setns` 已被 denylist 拦截，但 `clone`/`clone3` 带同名标志
-- 可创建嵌套 userns（绕开 unshare 拦截），故在此按 flags 过滤。
local CLONE_NS_MASK = 0x7E020000

-- mknod(2)/mknodat(2) 的设备类型位：S_IFCHR(0x2000) | S_IFBLK(0x6000) = 0x6000。
-- 设备节点**不经 overlayfs**——open 直接触达真实设备，是绕过暂存/遮蔽/审批的裸磁盘通道
-- （`mknod /tmp/d b 8 0 && dd if=/tmp/d` 即可读宿主磁盘）。mode 命中该位即拒绝；
-- FIFO（0x1000）/普通文件（0x8000）不受影响，`mkfifo` 仍可用。
-- 即便 capability 含 CAP_MKNOD（如用户显式加回），这里也硬拦（纵深防御）。
local S_IFDEV_MASK = 0x6000

-- socket(2) 允许的地址族白名单：AF_UNIX / AF_INET / AF_INET6 / AF_NETLINK。
-- 其余地址族（AF_PACKET/AF_VSOCK/AF_ALG/AF_XDP/AF_TIPC…）一律拒绝——尤其 AF_VSOCK 不受
-- 网络命名空间隔离，也不经代理，可直达宿主 vsock 服务（审计实测可创建并 connect）。
local AF_ALLOW = { 1, 2, 10, 16 }

-- 每架构的 denylist（危险 syscall 号）
local ARCH = {
  x86_64 = {
    audit = AUDIT_ARCH_X86_64,
    clone = 56,
    clone3 = 435,
    socket = 41,
    x32_guard = true,
    mknod = 133,
    mknodat = 259,
    blocked = {
      101, -- ptrace
      155, -- pivot_root
      159, -- adjtimex（读写系统时钟参数）
      161, -- chroot
      163, -- acct
      164, -- settimeofday
      165, 166, -- mount, umount2
      167, 168, -- swapon, swapoff
      169, -- reboot
      172, 173, -- iopl, ioperm（裸端口 I/O）
      175, 176, -- init_module, delete_module
      179, -- quotactl
      227, -- clock_settime
      246, -- kexec_load
      248, 249, 250, -- add_key, request_key, keyctl
      272, -- unshare
      298, -- perf_event_open
      303, 304, -- name_to_handle_at, open_by_handle_at
      305, -- clock_adjtime
      308, -- setns
      310, 311, -- process_vm_readv, process_vm_writev
      312, -- kcmp
      313, -- finit_module
      321, -- bpf
      323, -- userfaultfd
      425, 426, 427, -- io_uring_setup/enter/register
      428, 429, -- open_tree, move_mount
      430, 431, 432, 433, -- fsopen, fsconfig, fsmount, fspick
      438, -- pidfd_getfd
      440, -- process_madvise
      442, -- mount_setattr
    },
  },
  aarch64 = {
    audit = AUDIT_ARCH_AARCH64,
    clone = 220,
    clone3 = 435,
    socket = 198,
    -- arm64 无 mknod（glibc 经 mknodat(AT_FDCWD,…) 实现）；号码见 asm-generic/unistd.h。
    mknodat = 33,
    blocked = {
      40, 39, -- mount, umount2
      41, -- pivot_root
      51, -- chroot
      60, -- quotactl
      89, -- acct
      97, -- unshare
      104, 105, 106, -- kexec_load, init_module, delete_module
      112, -- clock_settime
      117, -- ptrace
      142, -- reboot
      170, -- settimeofday
      171, -- adjtimex
      217, 218, 219, -- add_key, request_key, keyctl
      224, 225, -- swapon, swapoff
      241, -- perf_event_open
      264, 265, -- name_to_handle_at, open_by_handle_at
      266, -- clock_adjtime
      268, -- setns
      270, 271, -- process_vm_readv, process_vm_writev
      273, -- finit_module
      280, -- bpf
      282, -- userfaultfd
      425, 426, 427, -- io_uring_*
      428, 429, -- open_tree, move_mount
      430, 431, 432, 433, -- fs*
      438, 440, 442,
    },
  },
}

-- ========== 私有状态 ==========

local state = { filter_path = nil }

-- ========== 私有函数 ==========

local function _u16(n)
  return string.char(n % 256, math.floor(n / 256) % 256)
end

local function _u32(n)
  return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

--- 编码一条 sock_filter（8 字节，小端）
local function _insn(code, jt, jf, k)
  return _u16(code) .. string.char(jt % 256, jf % 256) .. _u32(k)
end

local function _arch()
  local machine = (vim.uv.os_uname() or {}).machine or ""
  if machine == "x86_64" or machine == "amd64" then return ARCH.x86_64, "x86_64" end
  if machine == "aarch64" or machine == "arm64" then return ARCH.aarch64, "aarch64" end
  return nil, machine
end

local function _configured_filter()
  local p = config_store.get("tools.sandbox.seccomp.filter_path")
  if (p == nil or p == "") then p = config_store.get("tools.sandbox.seccomp_filter_path") end
  return p
end

-- ========== 公开 API ==========

--- 生成指定架构的 denylist BPF 过滤器字节
--- @param arch string "x86_64" | "aarch64"
--- @return string|nil
function M.build_filter(arch)
  local spec = ARCH[arch]
  if not spec then return nil end
  local parts = {}
  parts[#parts + 1] = _insn(BPF_LD_ABS, 0, 0, 4)            -- LD arch
  parts[#parts + 1] = _insn(BPF_JEQ_K, 1, 0, spec.audit)    -- JEQ arch ? skip kill : kill
  parts[#parts + 1] = _insn(BPF_RET_K, 0, 0, SECCOMP_RET_KILL_PROCESS)
  parts[#parts + 1] = _insn(BPF_LD_ABS, 0, 0, 0)            -- LD nr
  -- x32 ABI 位：带 `__X32_SYSCALL_BIT` 的 syscall 号与 x86_64 共用 arch，精确 JEQ 会失配，
  -- 必须在所有号码比较之前整体 KILL（仅 x86_64 适用）。
  if spec.x32_guard then
    parts[#parts + 1] = _insn(BPF_JSET_K, 0, 1, X32_SYSCALL_BIT) -- nr & bit ? KILL : skip
    parts[#parts + 1] = _insn(BPF_RET_K, 0, 0, SECCOMP_RET_KILL_PROCESS)
  end
  -- socket：仅放行 AF_UNIX/AF_INET/AF_INET6/AF_NETLINK，其余地址族返回 EPERM。
  if spec.socket then
    local n = #AF_ALLOW
    parts[#parts + 1] = _insn(BPF_JEQ_K, 0, n + 2, spec.socket) -- nr==socket ? LD args0 : skip block
    parts[#parts + 1] = _insn(BPF_LD_ABS, 0, 0, ARG0_OFFSET)
    for i, af in ipairs(AF_ALLOW) do
      -- 命中允许族则跳到块尾（跳过 RET EPERM）：剩余 (n-i) 个 JEQ + 1 个 RET
      parts[#parts + 1] = _insn(BPF_JEQ_K, n - i + 1, 0, af)
    end
    parts[#parts + 1] = _insn(BPF_RET_K, 0, 0, SECCOMP_RET_ERRNO_EPERM)
  end
  -- clone：仅当带命名空间标志时拒绝（否则放行，供 fork/线程正常创建）。
  if spec.clone then
    parts[#parts + 1] = _insn(BPF_JEQ_K, 0, 3, spec.clone)   -- nr==clone ? LD args0 : skip 3
    parts[#parts + 1] = _insn(BPF_LD_ABS, 0, 0, ARG0_OFFSET) -- LD args[0] (flags)
    parts[#parts + 1] = _insn(BPF_JSET_K, 0, 1, CLONE_NS_MASK) -- (flags & mask) ? errno : skip
    parts[#parts + 1] = _insn(BPF_RET_K, 0, 0, SECCOMP_RET_ERRNO_EPERM)
  end
  -- clone3：flags 在指针参数中，经典 seccomp 无法解引用 → 返回 ENOSYS 促使 glibc 回退到
  -- clone（回退后即受上面的 flags 过滤），避免直接 EPERM 打断线程创建。
  if spec.clone3 then
    parts[#parts + 1] = _insn(BPF_JEQ_K, 0, 1, spec.clone3)
    parts[#parts + 1] = _insn(BPF_RET_K, 0, 0, SECCOMP_RET_ERRNO_ENOSYS)
  end
  -- mknod/mknodat：mode（mknod 为 args[1]，mknodat 为 args[2]）含 S_IFCHR/S_IFBLK 位
  -- 即拒绝（EPERM），封死「创建设备节点 → 裸读磁盘」的逃逸通道；FIFO/普通文件放行。
  if spec.mknod then
    parts[#parts + 1] = _insn(BPF_JEQ_K, 0, 3, spec.mknod)   -- nr==mknod ? 检查 mode : 跳过
    parts[#parts + 1] = _insn(BPF_LD_ABS, 0, 0, ARG1_OFFSET) -- LD args[1] (mode)
    parts[#parts + 1] = _insn(BPF_JSET_K, 0, 1, S_IFDEV_MASK) -- (mode & mask) ? EPERM : 放行
    parts[#parts + 1] = _insn(BPF_RET_K, 0, 0, SECCOMP_RET_ERRNO_EPERM)
  end
  if spec.mknodat then
    parts[#parts + 1] = _insn(BPF_JEQ_K, 0, 3, spec.mknodat) -- nr==mknodat ? 检查 mode : 跳过
    parts[#parts + 1] = _insn(BPF_LD_ABS, 0, 0, ARG2_OFFSET) -- LD args[2] (mode)
    parts[#parts + 1] = _insn(BPF_JSET_K, 0, 1, S_IFDEV_MASK)
    parts[#parts + 1] = _insn(BPF_RET_K, 0, 0, SECCOMP_RET_ERRNO_EPERM)
  end
  for _, nr in ipairs(spec.blocked) do
    parts[#parts + 1] = _insn(BPF_JEQ_K, 0, 1, nr)          -- JEQ nr ? ret errno : skip
    parts[#parts + 1] = _insn(BPF_RET_K, 0, 0, SECCOMP_RET_ERRNO_EPERM)
  end
  parts[#parts + 1] = _insn(BPF_RET_K, 0, 0, SECCOMP_RET_ALLOW)
  return table.concat(parts)
end

--- 确保存在可用过滤器文件；返回路径（内置生成或用户提供）
--- @return string|nil path
--- @return string|nil err
function M.ensure_filter()
  local custom = _configured_filter()
  if custom and custom ~= "" then
    if vim.fn.filereadable(custom) == 1 then return custom end
    return nil, "SANDBOX_SECCOMP_FILTER_MISSING: " .. tostring(custom)
  end
  local spec, name = _arch()
  if not spec then
    return nil, "SANDBOX_SECCOMP_ARCH_UNSUPPORTED: " .. tostring(name)
  end
  local root = require("NeoAI.sandbox").store and require("NeoAI.sandbox").store.root()
    or (vim.fn.stdpath("cache") .. "/NeoAI/sandbox")
  local dir = root .. "/seccomp"
  -- 版本化文件名：过滤器内容变更时避免命中旧缓存
  -- （v3：clone/clone3 命名空间过滤 + socket 地址族白名单；
  --   v4：mknod/mknodat 设备节点屏障，CHR/BLK 模式拒绝、FIFO 放行；
  --   v5：时钟（adjtimex/settimeofday/clock_settime/clock_adjtime）与裸端口 I/O（iopl/ioperm）拦截）。
  local path = dir .. "/baseline-v5-" .. name .. ".bpf"
  if vim.fn.filereadable(path) == 1 then
    state.filter_path = path
    return path
  end
  fs.ensure_dir(dir)
  local bytes = M.build_filter(name)
  if not bytes then return nil, "SANDBOX_SECCOMP_BUILD_FAILED" end
  local f = io.open(path, "wb")
  if not f then return nil, "SANDBOX_SECCOMP_WRITE_FAILED: " .. path end
  f:write(bytes)
  f:close()
  state.filter_path = path
  return path
end

--- 是否可施加 seccomp 基线（存在过滤器文件或可生成）
--- @return boolean
function M.available()
  local path, _ = M.ensure_filter()
  return path ~= nil
end

--- 是否启用 seccomp 基线
--- @return boolean
function M.enabled()
  return config_store.get("tools.sandbox.seccomp.enabled") == true
end

--- bwrap seccomp 参数
--- @param fd number
--- @return table
function M.bwrap_args(fd)
  return { "--seccomp", tostring(fd) }
end

--- 重置（测试用）
function M.reset()
  state.filter_path = nil
end

M._arch = _arch
M._u16 = _u16
M._u32 = _u32

return M
