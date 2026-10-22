--- 沙箱动态 exec 调用链守卫
--- @module 'NeoAI.sandbox.observe.exec_guard'
--- 消费 `observer` 采集的 `execve`/`execveat` 事件，还原「根命令 → 各级子进程」的**真实
--- 调用链**，按**能力类别**（而非二进制名字）判定危险执行，命中后由调用方 `cgroup.kill`
--- 整树终止并写证据。
---
--- 存在意义：字符/文本静态判定（命令名黑名单、`curl | sh` 正则）实测双向失效——
--- `echo 'curl x | sh'` 被误拦，而 `| $SH`、`ba""sh`、`eval "$(curl …)"`、先落盘再 `source`
--- 全部漏拦。名字表也多余（所需危险 syscall 已由 seccomp 拦截，busybox 软链可绕名字）。
--- 唯一可靠的判定依据是**进程实际 exec 了哪个可执行文件**：`busybox iptables`、软链、
--- 变量间接、`eval` 派生在 execve 链上都会暴露真实路径。
---
--- **能力边界（务必如实理解，见 docs/sandbox.md「动态调用链判定」）**：
---   * 本模块是**观测 + 补救**：命中时进程已经 exec，副作用可能已发生一次，**不等价于**
---     seccomp 的发生前拦截（第 1 层仍必须是 seccomp）。
---   * 观测尽力而为：tracepoint 缺失、事件丢失、`procfs` 轮询漏采瞬时进程、极短命进程在
---     探针就绪前已完成 exec，都可能漏采，不承诺无漏采。
---   * classic seccomp 无法解引用路径参数，「按二进制路径**发生前**拦截」只能由
---     LSM（bpf/apparmor/selinux）或 bwrap 提供，本模块做不到。
---   * 无 eBPF/strace 后端时 exec 守卫**如实缺失**为「无动态强制层」，调用方应据此强制
---     同步事前审批（`approval_mode="prompt"`），不得假装有边界。
---
--- 归类依据是**能力事实**：由观测到的危险 syscall 与该二进制的 canonical 身份共同决定，
--- 名字只用于提示文案（`class_label`），不参与裁决。

local M = {}

--- 能力类别（用于归因与提示，不用于放行/拒绝的文本匹配）
---   module   : 内核模块装载/卸载、内核参数写入
---   clock    : 系统时钟
---   firewall : 网络管理（CAP_NET_ADMIN）
---   rawio    : 裸端口/裸设备 I/O
---   mount    : 挂载/命名空间
---   reboot   : 重启/关机/kexec
---   bpf      : eBPF / 性能事件
---   swap     : 交换区
---   ptrace   : 进程注入
M.CLASS = {
  module = "module",
  clock = "clock",
  firewall = "firewall",
  rawio = "rawio",
  mount = "mount",
  reboot = "reboot",
  bpf = "bpf",
  swap = "swap",
  ptrace = "ptrace",
}

--- 危险 syscall → 能力类别。与 `execution/seccomp.lua` 的 `ARCH[*].blocked` 对齐。
--- 这是**能力事实表**（syscall 层），不是命令名黑名单——新增项必须以「内核拒绝的 syscall」
--- 为单位，不得以二进制名字为单位（见 docs/sandbox.md 核心不变量 6）。
M.SYSCALL_CLASS = {
  init_module = M.CLASS.module, finit_module = M.CLASS.module, delete_module = M.CLASS.module,
  mount = M.CLASS.mount, umount2 = M.CLASS.mount, pivot_root = M.CLASS.mount,
  chroot = M.CLASS.mount, unshare = M.CLASS.mount, setns = M.CLASS.mount,
  clock_settime = M.CLASS.clock, clock_adjtime = M.CLASS.clock,
  adjtimex = M.CLASS.clock, settimeofday = M.CLASS.clock,
  reboot = M.CLASS.reboot, kexec_load = M.CLASS.reboot,
  bpf = M.CLASS.bpf, perf_event_open = M.CLASS.bpf,
  swapon = M.CLASS.swap, swapoff = M.CLASS.swap,
  ptrace = M.CLASS.ptrace,
  iopl = M.CLASS.rawio, ioperm = M.CLASS.rawio, mknod = M.CLASS.rawio, mknodat = M.CLASS.rawio,
}

-- ========== 私有状态 ==========

--- 每个 attempt/命令 id 一条调用链：chain_key → { nodes = { [pid] = node }, order = {pid...} }
local _chains = {}
--- 环形上限（每个链最多保留的节点数），防长跑命令无限增长。
local DEFAULT_MAX_CHAIN = 64

local function _cfg()
  local ok, cs = pcall(require, "NeoAI.kernel.config_store")
  if not ok then return {} end
  local okg, v = pcall(cs.get, "tools.sandbox.observe.exec_guard")
  return okg and type(v) == "table" and v or {}
end

--- 是否启用
--- @return boolean
function M.enabled()
  local c = _cfg()
  if c.enabled == false then return false end
  return true
end

--- 链容量上限
--- @return number
function M.max_chain()
  local c = _cfg()
  return tonumber(c.max_chain) or DEFAULT_MAX_CHAIN
end

--- 清理路径噪声（bpftrace 的 str() 可能带不可打印字符/相对路径）
--- @param p string|nil
--- @return string|nil
local function _clean(p)
  if type(p) ~= "string" then return nil end
  p = p:gsub("[%z\1-\31\127]", "")
  if p == "" then return nil end
  return p
end

--- 有界 canonical 化：能读到 `/proc/<pid>/exe` 时以它为准（内核给出真实可执行文件，
--- 自动解开软链、busybox 多调用名字、`$VAR` 间接）；读不到则退回事件路径。
--- 限制：只做 readlink（O(1)），不递归解析、不 stat 不存在路径，避免在事件回调里做重活。
--- @param pid number|nil
--- @param path string|nil
--- @return string|nil
local function _canonical(pid, path)
  path = _clean(path)
  if pid then
    local ok, exe = pcall(vim.uv.fs_readlink, "/proc/" .. tostring(pid) .. "/exe")
    if ok and type(exe) == "string" and exe ~= "" then
      local e = _clean(exe)
      if e then
        -- 被删除的可执行文件会带 " (deleted)" 后缀，去掉以便归类
        return (e:gsub(" %(deleted%)$", ""))
      end
    end
  end
  return path
end

--- 取父进程 pid：`/proc/<pid>/stat` 第 4 字段（在 `)` 之后开始计字段，避免 comm 内含空格/括号）。
--- 不从 bpftrace 取：访问 `task_struct->real_parent` 在新内核上可能编译失败，一旦整脚本编译
--- 失败则所有探针都不挂载（见 observer 的 exec 探针注释）。读 procfs 廉价且可靠。
--- @param pid number|nil
--- @return number|nil
local function _ppid(pid)
  if not pid then return nil end
  local f = io.open("/proc/" .. tostring(pid) .. "/stat", "r")
  if not f then return nil end
  local line = f:read("*l") or ""
  f:close()
  -- 格式：pid (comm) state ppid …；comm 可含空格与括号，故从最后一个 ')' 之后切。
  local tail = line:match("%)%s+(.*)$")
  if not tail then return nil end
  local ppid = tail:match("^%S+%s+(%d+)")
  return tonumber(ppid)
end

--- 取二进制基名（仅用于提示文案）
--- @param path string|nil
--- @return string|nil
local function _basename(path)
  if not path then return nil end
  return path:match("([^/]+)$")
end

-- ========== 公开 API ==========

--- 重置某条链（新一轮命令开始 / 测试隔离）
--- @param key string|nil 链标识（通常 command_id / attempt_id）；nil = 清空全部
function M.reset(key)
  if key == nil then
    _chains = {}
    return
  end
  _chains[key] = nil
end

--- 消费一条观测事件。仅处理 `kind=="exec"`；其余事件忽略（由既有消费方处理）。
--- @param event table { kind, op, pid, path, ppid?, argv0? }
--- @param key string|nil 链标识；nil 时归入默认链
--- @return table|nil node 新增的节点（未处理时 nil）
function M.observe(event, key)
  if not M.enabled() then return nil end
  if type(event) ~= "table" or event.kind ~= "exec" then return nil end
  local pid = tonumber(event.pid)
  if not pid then return nil end
  key = key or "default"
  local chain = _chains[key]
  if not chain then
    chain = { nodes = {}, order = {} }
    _chains[key] = chain
  end
  local path = _canonical(pid, event.path)
  if not path then return nil end
  local existing = chain.nodes[pid]
  if existing and existing.path == path then return nil end
  local node = {
    pid = pid,
    ppid = tonumber(event.ppid) or _ppid(pid),
    path = path,
    argv0 = _clean(event.argv0) or _basename(path),
    op = event.op or "execve",
    class = existing and existing.class or nil,  -- 保留已标注的能力类别
    syscall = existing and existing.syscall or nil,
  }
  if not existing then
    chain.order[#chain.order + 1] = pid
    local max = M.max_chain()
    while #chain.order > max do
      local drop = table.remove(chain.order, 1)
      chain.nodes[drop] = nil
    end
  end
  chain.nodes[pid] = node
  return node
end

--- 从某 pid 向根回溯，返回调用链（根在前）。
--- 由于 execve 事件不总带 ppid（eBPF 探针在部分内核上取不到），回溯仅在带 ppid 时生效，
--- 否则退化为「该 pid 自身」——仍足以归因「哪个二进制被真正执行」。
--- @param key string|nil
--- @param pid number|nil
--- @return table 节点数组（根 → 叶子）
function M.chain(key, pid)
  key = key or "default"
  local chain = _chains[key]
  if not chain then return {} end
  pid = tonumber(pid)
  if not pid then
    -- 无指定 pid：返回按事件顺序的全部节点
    local out = {}
    for _, p in ipairs(chain.order) do
      local n = chain.nodes[p]
      if n then out[#out + 1] = n end
    end
    return out
  end
  local out, seen = {}, {}
  local cur = chain.nodes[pid]
  while cur and not seen[cur.pid] do
    seen[cur.pid] = true
    table.insert(out, 1, cur)
    cur = cur.ppid and chain.nodes[cur.ppid] or nil
  end
  return out
end

--- 用危险 syscall 命中给节点标注能力类别，并返回归因结果。
--- @param key string|nil
--- @param syscall string|nil 命中的危险 syscall（如 "init_module"）
--- @param pid number|nil 触发该 syscall 的 pid
--- @return table { syscall, class, pid, path, argv0, basename, chain = table }
function M.violation(key, syscall, pid)
  local class = syscall and M.SYSCALL_CLASS[syscall] or nil
  key = key or "default"
  local chain = _chains[key]
  local node = chain and pid and chain.nodes[tonumber(pid)] or nil
  if node then
    node.class = class or node.class
    node.syscall = syscall
  end
  -- 归因：优先命中 pid 自身的 exec 节点；取不到时退化为「链上最近一个节点」。
  local leaf = node
  if not leaf then
    local all = M.chain(key, nil)
    leaf = all[#all]
  end
  local path = leaf and leaf.path or nil
  return {
    syscall = syscall,
    class = class,
    pid = leaf and leaf.pid or tonumber(pid),
    path = path,
    argv0 = leaf and leaf.argv0 or nil,
    basename = leaf and (_basename(path) or leaf.argv0) or nil,
    chain = M.chain(key, leaf and leaf.pid or nil),
  }
end

--- 危险 syscall 的能力类别
--- @param syscall string|nil
--- @return string|nil
function M.class_of(syscall)
  return syscall and M.SYSCALL_CLASS[syscall] or nil
end

--- 当前环境是否存在可用的 exec 事件来源（决定 exec 守卫是否真的在生效）。
--- 这是「无动态强制层」判定的输入之一：为 false 时调用方必须强制同步事前审批，
--- 不得假装有边界（见 docs/sandbox.md 核心不变变 6）。
--- @return boolean
--- @return string 原因
function M.source_available()
  local ok, obs = pcall(require, "NeoAI.sandbox.observe.observer")
  if not ok or type(obs.backend) ~= "function" then return false, "observer 不可用" end
  local okb, backend = pcall(obs.backend)
  if not okb then return false, "后端探测失败" end
  -- ebpf 的 X 帧与 procfs 的 kind=exec 都能喂进调用链；strace 后端只采集文件路径。
  if backend == "ebpf" or backend == "procfs" then
    return true, backend
  end
  return false, tostring(backend or "unknown")
end

--- 能力类别的人类可读标签（仅用于提示文案）
--- @param class string|nil
--- @return string
function M.class_label(class)
  local labels = {
    module = "内核模块/内核参数",
    clock = "系统时钟",
    firewall = "网络管理（CAP_NET_ADMIN）",
    rawio = "裸端口/裸设备 I/O",
    mount = "挂载/命名空间",
    reboot = "重启/关机/kexec",
    bpf = "eBPF/性能事件",
    swap = "交换区",
    ptrace = "进程注入",
  }
  return labels[class] or tostring(class or "未知")
end

--- 把归因结果压成一行证据文案
--- @param v table|nil M.violation 的返回值
--- @return string
function M.describe(v)
  if type(v) ~= "table" then return "未知" end
  local parts = {}
  if v.syscall then parts[#parts + 1] = "syscall=" .. tostring(v.syscall) end
  if v.class then parts[#parts + 1] = "class=" .. tostring(v.class) end
  if v.path then parts[#parts + 1] = "exe=" .. tostring(v.path) end
  if v.pid then parts[#parts + 1] = "pid=" .. tostring(v.pid) end
  if type(v.chain) == "table" and #v.chain > 1 then
    local hops = {}
    for _, n in ipairs(v.chain) do hops[#hops + 1] = tostring(n.argv0 or _basename(n.path) or n.pid) end
    parts[#parts + 1] = "chain=" .. table.concat(hops, " → ")
  end
  return table.concat(parts, " ")
end

--- 把调用链压成可写入 evidence 的结构（有界，仅保留必要字段）
--- @param nodes table
--- @return table
function M.chain_evidence(nodes)
  local out = {}
  for _, n in ipairs(nodes or {}) do
    out[#out + 1] = {
      pid = n.pid, ppid = n.ppid, path = n.path, argv0 = n.argv0,
      class = n.class, syscall = n.syscall,
    }
  end
  return out
end

return M
