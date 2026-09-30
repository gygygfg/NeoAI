--- 沙箱边界逃逸与拦截矩阵（真实 bwrap）
--- @module NeoAI.tests.test_sandbox_boundary_escape
--- 覆盖现有测试未触及的边界：seccomp denylist 全量真实验证、mount/chroot/pivot_root 负向、
--- pid namespace 隔离、/proc 信息泄露基线、/proc/sys 只读、mask_paths 端到端（哨兵）、
--- /run 私有写、setuid+NoNewPrivs、宿主敏感路径哨兵。设计边界以「基线断言」固化并标注。

local tests = require("NeoAI.tests")
local H = require("NeoAI.tests.sandbox_boundary_helpers")

tests.suite("sandbox_boundary_escape", function(_, it)
  it("seccomp：denylist 危险 syscall 真实拦截（EPERM）", function(t)
    if not H.bwrap() or not H.has("python3") then return end
    if not H.is_x86_64() then return end
    local script = H.syscall_script(H.SYS_DENY)
    local out = H.python({ cwd = "/tmp" }, script)
    local got = {}
    for name, errno in tostring(out):gmatch("([%w_]+)=(%d+)") do got[name] = tonumber(errno) end
    local missing, wrong = {}, {}
    for name in pairs(H.SYS_DENY) do
      if got[name] == nil then missing[#missing + 1] = name
      elseif got[name] ~= 1 then wrong[#wrong + 1] = name .. "=" .. got[name] end
    end
    t.eq(0, #missing, "探测脚本应覆盖全部 syscall，缺失: " .. table.concat(missing, ","))
    t.eq(0, #wrong, "denylist syscall 应全部返回 EPERM(1)，异常: " .. table.concat(wrong, ","))
  end)

  it("seccomp：clone3 返回 ENOSYS、clone 带命名空间标志被拒", function(t)
    if not H.bwrap() or not H.has("python3") then return end
    if not H.is_x86_64() then return end
    local script = [[
import ctypes
libc = ctypes.CDLL(None, use_errno=True)
libc.syscall.restype = ctypes.c_long
libc.syscall.argtypes = [ctypes.c_long]*7
ctypes.set_errno(0)
libc.syscall(435, 0, 0, 0, 0, 0, 0)  # clone3
print("clone3=%d" % ctypes.get_errno())
ctypes.set_errno(0)
libc.syscall(56, 0x10000000, 0, 0, 0, 0, 0)  # clone(CLONE_NEWUSER)
print("clone_newuser=%d" % ctypes.get_errno())
]]
    local out = H.python({ cwd = "/tmp" }, script)
    t.matches("clone3=38", out, "clone3 应返回 ENOSYS(38)")
    t.matches("clone_newuser=1", out, "clone(CLONE_NEWUSER) 应 EPERM(1)")
  end)

  it("seccomp：socket 地址族白名单（AF_UNIX 放行，AF_VSOCK/AF_ALG 拒绝）", function(t)
    if not H.bwrap() or not H.has("python3") then return end
    local script = [[
import ctypes
libc = ctypes.CDLL(None, use_errno=True)
libc.socket.restype = ctypes.c_int
libc.socket.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_int]
for name, dom in [("unix",1),("inet",2),("vsock",40),("alg",38),("packet",17)]:
    ctypes.set_errno(0)
    fd = libc.socket(dom, 1, 0)
    e = ctypes.get_errno()
    if fd >= 0:
        print("%s=OK" % name)
        import os; os.close(fd)
    else:
        print("%s=%d" % (name, e))
]]
    local out = H.python({ cwd = "/tmp" }, script)
    t.matches("unix=OK", out, "AF_UNIX 应放行")
    t.matches("inet=OK", out, "AF_INET 应放行")
    t.matches("vsock=1", out, "AF_VSOCK 应 EPERM(1)")
    t.matches("alg=1", out, "AF_ALG 应 EPERM(1)")
    t.matches("packet=1", out, "AF_PACKET 应 EPERM(1)")
  end)

  it("seccomp：mknod 设备节点屏障（CHR/BLK 拒绝，FIFO 放行）", function(t)
    if not H.bwrap() or not H.has("python3") then return end
    local script = [[
import ctypes, os
libc = ctypes.CDLL(None, use_errno=True)
libc.mknod.restype = ctypes.c_int
libc.mknod.argtypes = [ctypes.c_char_p, ctypes.c_uint, ctypes.c_uint]
def probe(name, path, mode):
    try: os.remove(path)
    except OSError: pass
    ctypes.set_errno(0)
    r = libc.mknod(path.encode(), mode, 0)
    print("%s=%d" % (name, ctypes.get_errno()))
    if r == 0:
        try: os.remove(path)
        except OSError: pass
probe("chr", "/tmp/.neoai_mknod_chr", 0o020000 | 0o600)
probe("blk", "/tmp/.neoai_mknod_blk", 0o060000 | 0o600)
probe("fifo", "/tmp/.neoai_mknod_fifo", 0o010000 | 0o600)
probe("reg", "/tmp/.neoai_mknod_reg", 0o100000 | 0o600)
]]
    local out = H.python({ cwd = "/tmp" }, script)
    t.matches("chr=1", out, "字符设备 mknod 应 EPERM(1)")
    t.matches("blk=1", out, "块设备 mknod 应 EPERM(1)")
    t.matches("fifo=0", out, "FIFO 应放行")
    t.matches("reg=0", out, "普通文件应放行")
  end)

  it("mount/chroot/pivot_root/umount 真实负向（T0 普通命令）", function(t)
    if not H.bwrap() then return end
    local out, code = H.direct({ cwd = "/tmp" },
      "mount -t tmpfs none /mnt 2>&1; echo RC=$?; "
      .. "chroot / /bin/true 2>&1; echo RC=$?; "
      .. "pivot_root / /mnt 2>&1; echo RC=$?; "
      .. "umount / 2>&1; echo RC=$?")
    t.true_(code ~= 0 or out:find("not permitted") ~= nil or out:find("denied") ~= nil,
      "应至少有一项被拒，实际: " .. tostring(out))
    -- 所有四项均不应为 RC=0（成功）
    local z = 0
    for _ in out:gmatch("RC=0") do z = z + 1 end
    t.eq(0, z, "mount/chroot/pivot_root/umount 均不应成功，实际输出: " .. tostring(out))
  end)

  it("pid namespace：沙箱内看不到宿主进程", function(t)
    if not H.bwrap() then return end
    local marker = "NEOAI_PIDNS_" .. tostring(math.random(1, 1e9))
    local job = vim.fn.jobstart({ "bash", "-c", "exec -a " .. marker .. " sleep 300" }, { detach = false })
    t.true_(job > 0, "应能启动宿主标记进程")
    vim.wait(200, function() return false end)
    local host_found = vim.fn.system("pgrep -f " .. marker .. " | wc -l"):gsub("%s", "")
    t.true_(tonumber(host_found) and tonumber(host_found) >= 1, "宿主应能看到标记进程")
    local out = H.direct({ cwd = "/tmp" }, "pgrep -f " .. marker .. " | wc -l")
    t.matches("0", out:gsub("%s", ""), "沙箱内不应看到宿主标记进程")
    pcall(vim.fn.jobstop, job)
  end)

  it("/proc/sys 整体只读（EROFS），危险 proc 泄露项为空", function(t)
    if not H.bwrap() then return end
    local out = H.direct({ cwd = "/tmp" },
      "echo 0 > /proc/sys/kernel/randomize_va_space 2>&1; echo RC=$?; "
      .. "for f in /proc/kcore /proc/kallsyms /proc/vmallocinfo /proc/timer_list /proc/modules /proc/cmdline /proc/version; do "
      .. "  echo \"$f=$(wc -c < $f 2>/dev/null)\"; done")
    t.true_(out:find("Read%-only") ~= nil or out:find("Permission denied") ~= nil or out:find("RC=1") ~= nil,
      "写 /proc/sys 应被拒（EROFS），实际: " .. tostring(out))
    for _, f in ipairs({ "/proc/kcore", "/proc/kallsyms", "/proc/vmallocinfo", "/proc/cmdline", "/proc/version" }) do
      local n = out:match(vim.pesc(f) .. "=(%d+)")
      t.eq(0, tonumber(n) or -1, f .. " 应被遮蔽为空，实际字节数: " .. tostring(n))
    end
  end)

  it("[设计边界基线] /proc/net 与 hostname 对沙箱可见（共享 netns 固有）", function(t)
    if not H.bwrap() then return end
    local out = H.direct({ cwd = "/tmp" },
      "test -r /proc/net/tcp && echo NET_TCP_READABLE; "
      .. "test -r /proc/net/unix && echo NET_UNIX_READABLE; "
      .. "h=$(hostname 2>/dev/null); test -n \"$h\" && echo HOSTNAME_VISIBLE")
    -- 固化为基线：这些是共享 netns 的已知残余，行为变化（被修复或进一步泄露）应报警。
    t.matches("NET_TCP_READABLE", out, "基线：/proc/net/tcp 可读（共享 netns 残余）")
    t.matches("NET_UNIX_READABLE", out, "基线：/proc/net/unix 可读（共享 netns 残余）")
    t.matches("HOSTNAME_VISIBLE", out, "基线：hostname 继承宿主")
  end)

  it("mask_paths 端到端：写 /etc/shadow 不落宿主（哨兵/哈希校验）", function(t)
    if not H.bwrap() then return end
    if vim.uv.getuid() ~= 0 then return end
    local before = vim.fn.sha256(vim.fn.system("cat /etc/shadow 2>/dev/null"))
    local out = H.direct({ cwd = "/tmp" },
      "id -u > /etc/shadow 2>&1; echo WRITE_RC=$?; "
      .. "cat /etc/shadow 2>/dev/null | wc -c")
    local after = vim.fn.sha256(vim.fn.system("cat /etc/shadow 2>/dev/null"))
    t.eq(before, after, "/etc/shadow 宿主内容不应被改动")
    -- 沙箱内既写不进、也读不到宿主口令哈希（/dev/null 遮蔽）。
    t.true_(out:find("root:") == nil, "沙箱内不应读到宿主 /etc/shadow 内容，实际: " .. tostring(out))
  end)

  it("整机 overlay 暂存：改写 /usr、/var/log、/root 哨兵不落宿主", function(t)
    if not H.bwrap() then return end
    if vim.uv.getuid() ~= 0 then return end
    local placed = H.sentinel_place({ "/usr", "/var/log", "/root", "/etc" })
    if #placed == 0 then return end
    local cmds = {}
    for _, s in ipairs(placed) do
      cmds[#cmds + 1] = "echo HACKED > " .. s.path .. " 2>&1 || true"
    end
    H.direct({ cwd = "/tmp" }, table.concat(cmds, "; "))
    local ok, bad = H.sentinel_verify(placed)
    t.true_(ok, "哨兵文件不应被沙箱改动，首个异常: " .. tostring(bad))
    H.sentinel_clean(placed)
  end)

  it("/run 为每会话私有可写（宿主不可见）", function(t)
    if not H.bwrap() then return end
    local name = "neoai_run_probe_" .. tostring(math.random(1, 1e9))
    local out = H.direct({ cwd = "/tmp" },
      "mkdir -p /run/" .. name .. " && echo ok > /run/" .. name .. "/f && cat /run/" .. name .. "/f")
    t.matches("ok", out, "沙箱内应可写 /run 并读回")
    t.true_(vim.fn.isdirectory("/run/" .. name) == 0, "宿主 /run 不应出现该目录")
  end)

  it("NoNewPrivs=1：setuid/文件能力被忽略", function(t)
    if not H.bwrap() then return end
    local out = H.direct({ cwd = "/tmp" }, "grep -i '^NoNewPrivs' /proc/self/status")
    t.matches("NoNewPrivs:%s+1", out, "载荷应带 NoNewPrivs=1")
  end)
end)
