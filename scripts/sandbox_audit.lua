-- 沙箱逃逸/信息泄露审计脚本（离线、可复现）
-- 从沙箱内部运行探测命令，输出结构化报告，供人工确认后修复。
--
-- 运行：
--   nvim --headless --clean -u NONE --cmd "set rtp+=$PWD" \
--     -c "luafile scripts/sandbox_audit.lua"
-- 关注：所有 `write_*` 应为 READONLY；`raw_tcp_host`/`proc_net_*`/`ip_*` 为已知残余边界。
local function main()
  require("NeoAI").setup({ log = { level = "ERROR" }, session = { auto_save = false } })
  local runtime = require("NeoAI.sandbox.runtime")
  local store = require("NeoAI.sandbox.store")
  store.init(vim.fn.stdpath("cache") .. "/NeoAI/sandbox")
  local backend = runtime.backend()
  print("BACKEND=" .. tostring(backend))
  if backend ~= "bwrap" then
    print("SKIP: bwrap 后端不可用")
    return
  end

  -- 宿主侧 HTTP/TCP 监听（用于裸 TCP 与代理拦截对比）
  local srv = vim.uv.new_tcp()
  srv:bind("127.0.0.1", 0)
  srv:listen(16, function()
    local c = vim.uv.new_tcp()
    local ok = pcall(function() srv:accept(c) end)
    if not ok then return end
    c:read_start(function(_, data)
      if not data then pcall(function() c:close() end); return end
      c:write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
    end)
  end)
  local hp = srv:getsockname().port
  print("HOST_LISTENER_PORT=" .. hp)

  local workdir = "/tmp"
  
  local prefix = runtime.process_prefix({ cwd = workdir })
  if not prefix then print("SKIP: 无法构造沙箱前缀"); return end
  local env = runtime.sandbox_env(nil)
  local store_root = store.root() or ""

  local script = ([[
P() { printf '\n### %s\n' "$1"; }
W() { if ( : > "$1" ) 2>/dev/null; then echo WRITABLE; else echo READONLY; fi; }

P cap_eff; grep -E 'Cap(Eff|Bnd)|Seccomp:|NoNewPrivs' /proc/self/status
P cmdline_hidden; cat /proc/cmdline; echo "[end]"
P core_pattern_read; cat /proc/sys/kernel/core_pattern; echo "[end]"
P write_core_pattern; W /proc/sys/kernel/core_pattern
P write_modprobe; W /proc/sys/kernel/modprobe
P write_sysrq; W /proc/sys/kernel/sysrq
P write_randomize_va_space; W /proc/sys/kernel/randomize_va_space
P write_pid_max; W /proc/sys/kernel/pid_max
P write_kptr_restrict; W /proc/sys/kernel/kptr_restrict
P write_dmesg_restrict; W /proc/sys/kernel/dmesg_restrict
P write_net_ip_forward; W /proc/sys/net/ipv4/ip_forward
P write_net_all_forward; W /proc/sys/net/ipv4/conf/all/forwarding
P write_vm_swappiness; W /proc/sys/vm/swappiness
P write_vm_max_map_count; W /proc/sys/vm/max_map_count
P write_vm_overcommit; W /proc/sys/vm/overcommit_memory
P write_fs_protected_hardlinks; W /proc/sys/fs/protected_hardlinks
P sysrq_trigger_h; ( echo h > /proc/sysrq-trigger ) 2>&1 | head -1
P etc_shadow; if [ -s /etc/shadow ]; then echo LEAK; else echo MASKED; fi
P docker_sock; if [ -S /var/run/docker.sock ]; then echo SOCK_VISIBLE; else echo MASKED; fi
P root_ssh; ls -A /root/.ssh 2>&1 | head -3; echo "[end]"
P write_etc_passwd; W /etc/passwd
P proc1_root; readlink /proc/1/root 2>&1; ls /proc/1/root 2>&1 | head -3; echo "[end]"
P pid1_cmdline; tr '\0' ' ' < /proc/1/cmdline; echo
P host_tmp; ls -A /tmp 2>&1 | head -5; echo "[end]"
P sandbox_storage; ls -A "STORE_ROOT" 2>&1 | head -3; echo "[end]"
P proc_net_tcp; echo "lines=$(wc -l < /proc/net/tcp 2>/dev/null)"
P proc_net_unix; echo "lines=$(wc -l < /proc/net/unix 2>/dev/null)"
P ip_addr; ip -o addr 2>/dev/null | wc -l
P ip_route; ip route 2>/dev/null | wc -l
P mount_overlay_leak; grep -c overlay /proc/self/mountinfo 2>/dev/null
P kcore; ls -l /proc/kcore 2>&1
P kallsyms; head -1 /proc/kallsyms 2>&1
P modules; head -2 /proc/modules 2>&1
P dev_mem_kmsg; ls -l /dev/mem /dev/kmsg 2>&1
P sys_exists; ls -d /sys 2>&1
P unshare; unshare -Urn true 2>&1; echo "rc=$?"
P nsenter; nsenter --mount=/proc/1/ns/mnt true 2>&1; echo "rc=$?"
P mount_tmpfs; mkdir -p /mnt/x 2>/dev/null; mount -t tmpfs none /mnt/x 2>&1; echo "rc=$?"
P write_sysrq_trigger_dry; W /proc/sysrq-trigger
P ulimit_core; ulimit -c
P fds; ls /proc/self/fd 2>/dev/null | wc -l
P raw_tcp_host; (nc -z -w1 127.0.0.1 HPORT && echo RAW_REACHED) 2>&1 || echo RAW_BLOCKED
P proxy_host; curl -s -m 3 -o /dev/null -w 'HTTP=%{http_code}\n' "http://127.0.0.1:HPORT/" 2>&1
P env_proxy; env | grep -i proxy | sort; echo "[end]"

# ===== Round 2：新攻击面 =====
P dev_shm; ls -A /dev/shm 2>&1 | head -5; echo "[end]"
P mountinfo_raw; grep -aE 'lowerdir|upperdir|workdir' /proc/self/mountinfo 2>/dev/null | head -2; echo "[end]"
P proc_info_leaks; for f in /proc/timer_list /proc/slabinfo /proc/interrupts /proc/keys /proc/vmallocinfo /proc/buddyinfo /proc/zoneinfo /proc/pagetypeinfo; do printf '%-22s ' "$f"; head -c 40 "$f" 2>&1 | tr '\n' ' '; echo; done
P kmsg_read; head -c 40 /proc/kmsg 2>&1 | tr '\n' ' '; echo
P unix_abstract_count; grep -ac '@' /proc/net/unix 2>/dev/null
P ns_inodes; for n in mnt pid net user; do printf '%-5s ' "$n"; readlink /proc/self/ns/$n; done
P syscall_probe; cat > /tmp/audit_r2.py <<'PY'
import ctypes, os
libc = ctypes.CDLL("libc.so.6", use_errno=True)
T = {'mount':(165,(0,0,0,0,0)),'unshare':(272,(0x10000000,)),'setns':(308,(0,0)),
 'open_tree':(428,(0,0,0)),'move_mount':(429,(0,0,0,0,0)),'fsopen':(430,(0,0)),
 'fsmount':(432,(0,0,0)),'mount_setattr':(442,(0,0,0,0,0)),'bpf':(321,(0,0,0)),
 'keyctl':(250,(0,0,0,0,0)),'perf_event_open':(298,(0,0,-1,-1,0)),'io_uring_setup':(425,(1,0))}
for n,(nr,a) in T.items():
    ctypes.set_errno(0); r = libc.syscall(nr,*a); e = ctypes.get_errno()
    print("SYSCALL %-16s errno=%-3d %s" % (n,e,("EPERM" if e==1 else ("OK" if r>=0 else os.strerror(e)))))
ctypes.set_errno(0); r = libc.syscall(56, 0x10000000|17, 0, 0, 0, 0)
print("SYSCALL clone_NEWUSER errno=%d %s" % (ctypes.get_errno(), "EPERM" if ctypes.get_errno()==1 else "ALLOWED"))
ctypes.set_errno(0); r = libc.syscall(435, 0, 0)
print("SYSCALL clone3        errno=%d %s" % (ctypes.get_errno(), "ENOSYS" if ctypes.get_errno()==38 else os.strerror(ctypes.get_errno())))
PY
python3 /tmp/audit_r2.py 2>&1

# ===== Round 3：废弃/边缘 syscall 与主机状态 =====
P host_info_leaks; printf 'loadavg='; cat /proc/loadavg; printf 'pressure='; head -1 /proc/pressure/cpu 2>&1; printf 'hostname='; hostname 2>&1; ls /proc/bus 2>&1 | tr '\n' ' '; echo
P setuid_bins; find / -perm -4000 -type f 2>/dev/null | head -6; echo "[end]"
P mknod_dev; mknod /tmp/neoai_node c 1 3 2>&1; echo "rc=$?"
P write_uid_map; ( echo "0 0 1" > /proc/self/uid_map ) 2>&1 && echo WROTE || echo DENIED
P write_etc_hosts; W /etc/hosts
P syscall_probe3; cat > /tmp/audit_r3.py <<'PY'
import ctypes, os, socket
libc = ctypes.CDLL("libc.so.6", use_errno=True)
def call(nr, *a):
    ctypes.set_errno(0); r = libc.syscall(nr, *a); return r, ctypes.get_errno()
def show(name, nr, *a):
    r,e = call(nr,*a)
    print("SYSCALL %-16s errno=%-3d %s" % (name,e,"EPERM" if e==1 else ("ENOSYS" if e==38 else ("OK" if r>=0 else os.strerror(e)))))
show("iopl",172,3); show("ioperm",173,0,8,1); show("mknod",133,0,0,0)
show("settimeofday",164,0,0); show("prctl_SET_MM",157,35,0,0,0,0)
show("open_by_handle_at",304,0,0,0); show("kexec_load",246,0,0,0,0)
r,e = call(156,0); print("SYSCALL sysctl(2)        errno=%-3d %s" % (e,"ENOSYS(disabled)" if e==38 else os.strerror(e)))
for fam,nm in [(1,"AF_UNIX"),(2,"AF_INET"),(10,"AF_INET6"),(17,"AF_PACKET"),(38,"AF_ALG"),(40,"AF_VSOCK"),(44,"AF_XDP")]:
    try:
        s=socket.socket(fam, socket.SOCK_RAW if fam==17 else socket.SOCK_STREAM); s.close(); print("socket %-10s OK"%nm)
    except OSError as ex: print("socket %-10s errno=%d %s"%(nm,ex.errno,os.strerror(ex.errno)))
PY
python3 /tmp/audit_r3.py 2>&1
]]):gsub("STORE_ROOT", store_root):gsub("HPORT", tostring(hp))

  local argv = {}
  for _, v in ipairs(prefix) do argv[#argv + 1] = v end
  argv[#argv + 1] = "/bin/sh"
  argv[#argv + 1] = "-c"
  argv[#argv + 1] = script

  local res = vim.system(argv, { env = env, text = true }):wait()
  print(res.stdout or "")
  if res.stderr and res.stderr ~= "" then print("--- stderr ---\n" .. res.stderr) end

  -- conceal 旁路检查：read_file 直读 /proc/self/mountinfo 是否泄露 overlay 真实路径
  local done = false
  require("NeoAI.tools").execute("read_file",
    { filepath = "/proc/self/mountinfo", description = "audit" }, {}):then_(function(r)
    local s = tostring(r)
    print("\n### read_file_mountinfo")
    print("path_leak=" .. tostring(s:find("/.cache-", 1, true) ~= nil or s:find(store_root, 1, true) ~= nil))
    print("lowerdir_redacted=" .. tostring(s:find("lowerdir=hidden", 1, true) ~= nil))
    done = true
  end, function(e)
    print("\n### read_file_mountinfo ERROR: " .. tostring(e and e.message or e)); done = true
  end)
  vim.wait(15000, function() return done end)

  print("AUDIT_DONE")
  pcall(function() srv:close() end)
  pcall(function() require("NeoAI.sandbox.host_proxy").stop() end)
end

main()
vim.cmd("qa!")
