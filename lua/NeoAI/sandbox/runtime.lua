--- 沙箱运行时后端
--- @module NeoAI.sandbox.runtime
--- 外部隔离后端探测与进程前缀构造。优先 bwrap，其次 unshare。
--- 关键能力缺失时返回明确错误，不静默降级（设计文档 §7.1）。
---
--- 注意：进程内工具（LSP/treesitter 等）无法经 namespace 隔离，由 wrapper 以
--- 「只读默认 + 写入暂存」约束，本模块只负责外部进程的隔离边界。

local async = require("NeoAI.utils.async")
local config_store = require("NeoAI.kernel.config_store")

local M = {}

-- ========== 私有状态 ==========

local state = {
  caps = nil,
  overlay_probe = {}, -- "dev_lower:dev_upper" -> boolean（按文件系统对缓存实测结果）
  empty_file = nil, -- 用于覆盖 /proc 泄露项的空文件路径（宿主）
}

-- 默认遮蔽的宿主敏感路径（安全默认，可经 tools.sandbox.mask_paths 覆盖）：
--   * 容器/编排 socket 与数据（docker.sock = 宿主 root，是经典逃逸入口）；
--   * 编排器 / 面板 / D-Bus / systemd 控制通道；
--   * 宿主凭据与密钥目录（SSH/AWS/GPG/kube/docker 配置/netrc/git 凭据/keyring）；
--   * 宿主身份/日志/命令历史等读取面泄露项（即便经 process_roots 或 cwd 覆盖而可达）。
-- 目录以空 tmpfs 遮蔽，文件/socket 以 /dev/null 覆盖（connect 将返回 ENOTSOCK）。
local DEFAULT_MASK_PATHS = {
  "/run/docker.sock", "/var/run/docker.sock",
  "/run/containerd", "/run/containerd/containerd.sock",
  "/var/run/containerd", "/var/lib/docker", "/var/lib/containerd",
  "/run/podman", "/var/run/podman", "/var/lib/containers",
  "/root/.config/herdr", "/etc/1panel", "/run/1panel", "/var/run/1panel",
  "/run/dbus", "/run/systemd",
  "/root/.ssh", "/root/.aws", "/root/.gnupg", "/root/.kube",
  "/root/.docker/config.json", "/root/.netrc", "/root/.git-credentials",
  "/root/.cache/keyring-*", "/root/.cache/at-spi", "/root/.local/share/keyrings",
  -- 宿主身份与凭据
  "/etc/shadow", "/etc/shadow-", "/etc/gshadow", "/etc/gshadow-",
  "/etc/sudoers", "/etc/sudoers.d", "/etc/machine-id", "/etc/hostid",
  "/etc/ssh", "/etc/ssl/private", "/etc/ipa", "/etc/krb5.keytab",
  -- 日志、计划任务与审计
  "/var/log", "/var/spool/cron", "/etc/crontab", "/etc/cron.d",
  "/etc/cron.daily", "/etc/cron.hourly", "/etc/cron.weekly", "/etc/cron.monthly",
  -- root 命令历史与残留（经 /root overlay 可达时）
  "/root/.bash_history", "/root/.zsh_history", "/root/.sh_history",
  "/root/.python_history", "/root/.mysql_history", "/root/.psql_history",
  "/root/.sqlite_history", "/root/.node_repl_history", "/root/.wget-hsts",
  "/root/.lesshst", "/root/.viminfo", "/root/.config/gh", "/root/.config/gcloud",
}

-- 最小只读系统集（白名单）：仅这些宿主根/子树以只读方式暴露给外部命令。
-- 不再整目录暴露 `/usr`：当宿主把根分区（含 /usr）挂到同一块大磁盘时，整目录会泄露
-- 宿主软件清单（/usr/share/doc 包数据库、/usr/local/go_workspace、/usr/src 等）。改为
-- 按运行时真正需要的子树挂载。`/lib*`、`/bin`、`/sbin` 是指向 `/usr/lib*`、`/usr/bin`、
-- `/usr/sbin` 的符号链接，必须保留（动态加载器 `/lib64/ld-linux-*` 等），否则任何二进制
-- 都无法启动。未列出的宿主路径在沙箱内**不存在**（/home、/var/log、/etc/shadow、/opt、
-- /srv、/mnt、/media、/boot、/usr/share/doc、/usr/src、/usr/local/go_workspace 等默认不可达）。
-- 需要更多子树时显式加回本列表（并同步收紧 mask_paths）。
local DEFAULT_READONLY_ROOTS = {
  -- 动态加载器与二进制符号链接根（必须，否则二进制无法启动）
  "/lib", "/lib32", "/lib64", "/libx32", "/bin", "/sbin",
  -- 运行时可执行文件、共享库与头文件
  "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/lib32", "/usr/lib64", "/usr/libx32",
  "/usr/libexec", "/usr/include",
  -- 运行时共享数据（刻意不含 /usr/share/doc、/usr/share/man、/usr/share/info 等宿主软件清单）
  "/usr/share/terminfo", "/usr/share/locale", "/usr/share/zoneinfo",
  "/usr/share/ca-certificates", "/usr/share/misc", "/usr/share/common-licenses",
  "/usr/share/awk", "/usr/share/perl", "/usr/share/perl5",
  "/usr/share/pkgconfig", "/usr/share/aclocal", "/usr/share/bash-completion",
  "/usr/share/git-core", "/usr/share/vim", "/usr/share/nvim",
  "/usr/share/tabset", "/usr/share/gnupg", "/usr/share/icu",
  -- 本地安装工具与 Go 工具链（刻意不含 /usr/local/go_workspace、/usr/local/src、/usr/local/man）
  "/usr/local/bin", "/usr/local/sbin", "/usr/local/lib", "/usr/local/libexec",
  "/usr/local/include", "/usr/local/go",
}

-- 最小 /etc 必要文件（白名单）：命令运行所需，避免整目录暴露（含 shadow/machine-id/ssh 等）。
-- 支持 `*` 通配；不存在的条目自动跳过。
-- 注意：`/etc/resolv.conf` 不在此列——默认经 `_sanitized_resolv_conf()` 净化后单独绑定
-- （仅保留 nameserver 行，剥离 search/domain/options），避免泄露宿主内网/Tailscale 域。
local DEFAULT_READONLY_PATHS = {
  "/etc/ld.so.cache", "/etc/ld.so.conf", "/etc/ld.so.conf.d",
  "/etc/passwd", "/etc/group", "/etc/nsswitch.conf",
  "/etc/hosts", "/etc/hostname", "/etc/host.conf",
  "/etc/localtime", "/etc/timezone", "/etc/os-release", "/etc/debian_version",
  "/etc/ssl", "/etc/ca-certificates", "/etc/ca-certificates.conf",
  "/etc/alternatives", "/etc/terminfo", "/etc/mime.types", "/etc/shells",
  "/etc/environment", "/etc/profile", "/etc/profile.d", "/etc/bash.bashrc",
  "/etc/inputrc", "/etc/security", "/etc/pam.d", "/etc/xdg", "/etc/fonts",
  "/etc/gitconfig", "/etc/npmrc", "/etc/apt", "/etc/dpkg",
  "/etc/python3*",
}

-- 每会话私有临时根（tmpfs 语义）：这些根始终以「会话私有目录（mode 1777）」绑定，
-- 绝不作为 overlay 的只读 lower 暴露宿主真实内容（否则会泄露 /tmp 跨会话残留与宿主数据）。
-- 退出/轮换会话即随进程目录销毁；可用 `tools.sandbox.tmpfs_roots` 覆盖。
-- 私有目录位置由 `tools.sandbox.tmp_private_base` 决定：
--   host（默认）= 建在宿主根之下的隐藏临时子目录（如 /tmp/.cache-<tag>/<session>），
--                  命名空间映射回该根，AI 只见自己的私有子目录（隔离 AI）；
--   session     = 建在会话进程目录下（/dev/shm 等），保持旧行为。
local DEFAULT_TMPFS_ROOTS = { "/tmp", "/var/tmp" }

-- 默认隐藏的 /proc 泄露项：这些文件在 procfs 中全局可见（不随 pid namespace 隔离），
-- 会泄露宿主内核命令行（root=UUID、crashkernel）与内核版本。以空文件只读覆盖，
-- 读取得到空内容。可用 `tools.sandbox.hide_proc_paths` 覆盖（只增不减）。
local DEFAULT_HIDE_PROC = { "/proc/cmdline", "/proc/version" }

-- 强制遮蔽的危险全局 sysctl（常驻，不可被用户配置移除）。这些条目**非命名空间**，
-- 且写权限按 `test_perm` 的 DAC 判定（euid == 全局 root uid）放行——`--cap-drop ALL`
-- 并不能阻止写。沙箱以 root 运行且不建 userns 时 euid 即全局 root，故 core_pattern/
-- modprobe 可被写入，构成 coredump/modprobe 提权原语（宿主全局状态被改）。
-- 以空文件只读覆盖后：读为空、写返回 EROFS，从根上封死。
local MANDATORY_PROC_MASKS = {
  "/proc/sys/kernel/core_pattern",
  "/proc/sys/kernel/modprobe",
  "/proc/sys/kernel/hotplug",
  "/proc/sys/kernel/uevent_helper",
  "/proc/sys/kernel/kexec_load_disabled",
  "/proc/sys/kernel/sysrq",
  "/proc/sys/kernel/panic",
  "/proc/sys/kernel/panic_on_oops",
  "/proc/sys/kernel/perf_event_paranoid",
  "/proc/sys/kernel/unprivileged_bpf_disabled",
  "/proc/sys/kernel/unprivileged_userns_clone",
  "/proc/sys/vm/drop_caches",
  "/proc/sys/vm/compact_memory",
  -- 非 /proc/sys 下的危险/信息泄露 proc 文件：magic sysrq 触发口、内核内存读口、
  -- 已加载模块清单、内核符号表（地址已被 kptr_restrict 遮蔽，整表一并隐藏）。
  "/proc/sysrq-trigger",
  "/proc/kcore",
  "/proc/modules",
  "/proc/kallsyms",
  -- 内核信息泄露面（审计实测可读）：/proc/vmallocinfo 暴露内核虚拟地址（绕过 kptr_restrict），
  -- 另有调度/内存/中断/密钥等元信息。统一以空文件只读覆盖。
  "/proc/vmallocinfo",
  "/proc/timer_list",
  "/proc/slabinfo",
  "/proc/interrupts",
  "/proc/softirqs",
  "/proc/buddyinfo",
  "/proc/zoneinfo",
  "/proc/pagetypeinfo",
  "/proc/keys",
  "/proc/sched_debug",
  "/proc/iomem",
  "/proc/ioports",
}

-- ========== 私有函数 ==========

-- 关闭除 0/1/2 外所有继承 fd 的 shell 片段（bash）。沙箱载荷不得继承宿主的目录 fd
-- （如 AppImage 挂载点 /tmp/.mount_* 的 fd），否则可用 openat(dir_fd, "..") 逐级
-- 上溯逃逸出 chroot/命名空间。注意：dash 只支持个位数 fd 重定向（无法关闭 fd 1023），
-- 故优先用 bash；无 bash 时用 python3 的 closerange；再退回 sh（仅个位 fd，尽力而为）。
local BASH_FD_CLOSE = "for _f in /proc/self/fd/*; do _n=${_f##*/}; "
  .. "if [ \"$_n\" -gt 2 ] 2>/dev/null; then eval \"exec $_n>&-\" 2>/dev/null; fi; done"
local PY_FD_CLOSE = "import os,sys; os.closerange(3, 65536); os.execvp(sys.argv[1], sys.argv[1:])"
local PY_FD_CLOSE_SECCOMP = "import os,sys; os.closerange(3, 65536); "
  .. "f=os.open(sys.argv[1], os.O_RDONLY); os.dup2(f, 3); os.execvp(sys.argv[2], sys.argv[2:])"
local SH_FD_CLOSE = "for _n in 3 4 5 6 7 8 9; do eval \"exec $_n>&-\" 2>/dev/null; done"

--- 用外部程序包装内层 argv：先关闭继承 fd（可选前置片段），再 exec 内层命令。
--- 优先 bash（支持多位数 fd），其次 python3，最后 sh（仅个位 fd）。
--- @param inner table 内层命令 argv
--- @param pre string|nil 关闭 fd 之后、exec 之前执行的片段（如 `exec 3<'<filter>'` 打开 seccomp fd）
--- @return table
local function _wrap_close_fds(inner, pre)
  local bash = vim.fn.exepath("bash")
  if bash ~= "" then
    local snippet = BASH_FD_CLOSE
    if type(pre) == "string" and pre ~= "" then snippet = snippet .. "; " .. pre end
    snippet = snippet .. "; exec \"$@\""
    local out = { bash, "-c", snippet, "bash" }
    for _, v in ipairs(inner) do out[#out + 1] = v end
    return out
  end
  local py = vim.fn.exepath("python3")
  if py ~= "" then
    local out
    if type(pre) == "string" and pre ~= "" then
      local filter = pre:match("^exec 3<'(.-)'$") or pre:match("^exec 3<(.*)$")
      out = { py, "-c", PY_FD_CLOSE_SECCOMP, filter or "" }
    else
      out = { py, "-c", PY_FD_CLOSE }
    end
    for _, v in ipairs(inner) do out[#out + 1] = v end
    return out
  end
  local snippet = SH_FD_CLOSE
  if type(pre) == "string" and pre ~= "" then snippet = snippet .. "; " .. pre end
  snippet = snippet .. "; exec \"$@\""
  local out = { "sh", "-c", snippet, "sh" }
  for _, v in ipairs(inner) do out[#out + 1] = v end
  return out
end

--- 配置的按需加回 capability（默认空：载荷不持有任何 capability）
--- @return table 字符串数组
local function _global_cap_add()
  local list = config_store.get("tools.sandbox.cap_add")
  if type(list) ~= "table" then return {} end
  local out = {}
  for _, c in ipairs(list) do
    if type(c) == "string" and c ~= "" then out[#out + 1] = c end
  end
  return out
end

--- 有效 capability 列表：全局 cap_add + 档位 cap_add
--- @param priv table|nil 档位隔离参数
--- @return table 字符串数组
local function _cap_add(priv)
  local out = _global_cap_add()
  if priv and type(priv.cap_add) == "table" then
    for _, c in ipairs(priv.cap_add) do
      if type(c) == "string" and c ~= "" then out[#out + 1] = c end
    end
  end
  return out
end

local function _executable(name)
  return vim.fn.executable(name) == 1
end

--- 同步运行一次探测命令，返回是否成功
--- @param argv table
--- @return boolean
local function _run_probe(argv)
  local ok = pcall(vim.fn.system, argv)
  return ok and vim.v.shell_error == 0
end

-- 无 user namespace 的隔离标志（root 下使用）：隐匿 uid_map / ns/user 指纹，
-- 同时保留 mount/pid/ipc/uts/cgroup 隔离。net 不隔离（默认共享），offline 时另加 --unshare-net。
local NO_USER_FLAGS = { "--unshare-pid", "--unshare-ipc", "--unshare-uts", "--unshare-cgroup" }
-- 带 user namespace 的隔离标志（非 root 兜底）。
local USER_FLAGS = { "--unshare-all" }

--- 当前进程是否以 root 运行（root 下可省去 user namespace）
--- @return boolean
local function _is_root()
  return vim.uv.getuid ~= nil and vim.uv.getuid() == 0
end

--- 读取只读白名单配置；缺省/空表时退回内置安全默认
--- @param key string
--- @param default table
--- @return table
local function _readonly_list(key, default)
  local cfg = config_store.get(key)
  if type(cfg) == "table" and next(cfg) ~= nil then return cfg end
  return default
end

--- 配置的列表：显式表（含空表）即以其为准，非表时退回内置默认。
--- @param key string
--- @param default table
--- @return table
local function _config_list(key, default)
  local cfg = config_store.get(key)
  if type(cfg) == "table" then return cfg end
  return default
end

--- 每会话私有临时根（规范化：去尾斜杠、剔除空/根）
--- @return table 字符串数组
local function _tmpfs_roots()
  local out = {}
  for _, p in ipairs(_config_list("tools.sandbox.tmpfs_roots", DEFAULT_TMPFS_ROOTS)) do
    if type(p) == "string" and p ~= "" and p ~= "/" then
      out[#out + 1] = p:gsub("/+$", "")
    end
  end
  return out
end

--- 需隐藏的 /proc 泄露项（用户可配置，只增不减）
--- @return table 字符串数组
local function _hide_proc_paths()
  return _config_list("tools.sandbox.hide_proc_paths", DEFAULT_HIDE_PROC)
end

--- 实际遮蔽的 /proc 路径：强制危险 sysctl 表 ∪ 用户隐藏项（去重）。强制项不可移除。
--- @return table 字符串数组
local function _proc_mask_paths()
  local seen, out = {}, {}
  local function add(p)
    if type(p) ~= "string" or p == "" or seen[p] then return end
    seen[p] = true
    out[#out + 1] = p
  end
  for _, p in ipairs(MANDATORY_PROC_MASKS) do add(p) end
  for _, p in ipairs(_hide_proc_paths()) do add(p) end
  return out
end

--- 不应自动暴露的宿主目录前缀（凭据/系统/沙箱自身）
local AUTO_EXPOSE_SKIP = {
  "/etc", "/var", "/run", "/dev", "/proc", "/sys", "/boot",
  "/root/.ssh", "/root/.aws", "/root/.gnupg", "/root/.kube", "/root/.docker",
  "/root/.config/herdr", "/root/.netrc", "/root/.git-credentials",
}

--- 自动直通宿主 PATH 中的工具目录（opt-in，`tools.sandbox.expose_tool_paths`）。
--- 用于让 node/npm/fd/go 等装在 $HOME 下的工具链在沙箱内可用；只暴露存在的目录，
--- 跳过凭据/系统目录。返回去尾斜杠的目录数组。
--- @return table 字符串数组
local function _auto_tool_paths()
  if config_store.get("tools.sandbox.expose_tool_paths") ~= true then return {} end
  local out, seen = {}, {}
  for dir in tostring(vim.env.PATH or ""):gmatch("[^:]+") do
    if dir ~= "" and not seen[dir] then
      seen[dir] = true
      dir = dir:gsub("/+$", "")
      if vim.fn.isdirectory(dir) == 1 then
        local skip = false
        for _, pre in ipairs(AUTO_EXPOSE_SKIP) do
          if dir == pre or dir:sub(1, #pre + 1) == pre .. "/" then skip = true break end
        end
        -- 跳过沙箱自身存储与临时根
        if not skip then
          local ok, store = pcall(require, "NeoAI.sandbox.store")
          local root = (ok and store and store.root and store.root()) or ""
          if root ~= "" and (dir == root or dir:sub(1, #root + 1) == root .. "/") then skip = true end
        end
        if not skip then out[#out + 1] = dir end
      end
    end
  end
  return out
end

--- 宿主运行时直通路径（opt-in，`tools.sandbox.expose_paths`）：规范化去尾斜杠。
--- 另可经 `tools.sandbox.expose_tool_paths=true` 自动直通宿主 PATH 中的工具目录。
--- @return table 字符串数组
local function _expose_paths()
  local out, seen = {}, {}
  local function add(p)
    if type(p) ~= "string" or p == "" or p == "/" then return end
    p = p:gsub("/+$", "")
    if seen[p] then return end
    seen[p] = true
    out[#out + 1] = p
  end
  for _, p in ipairs(_config_list("tools.sandbox.expose_paths", {})) do add(p) end
  for _, p in ipairs(_auto_tool_paths()) do add(p) end
  return out
end

--- 沙箱运行时私有目录（宿主，不暴露给沙箱）：存放空文件、净化 resolv.conf 等。
--- 优先沙箱存储根；不可用时退回 nvim 缓存目录。
--- @return string
local function _private_dir()
  local ok, store = pcall(require, "NeoAI.sandbox.store")
  local root = (ok and store and store.root and store.root())
    or (vim.fn.stdpath("cache") .. "/NeoAI/sandbox")
  local dir = root .. "/runtime"
  pcall(vim.fn.mkdir, dir, "p")
  return dir
end

--- 稳定的空文件路径（用于只读覆盖 /proc 泄露项，使读取得到空内容）。
--- @return string|nil
local function _empty_file()
  if state.empty_file and vim.uv.fs_stat(state.empty_file) then return state.empty_file end
  local p = _private_dir() .. "/empty"
  local f = io.open(p, "w")
  if not f then return nil end
  f:close()
  pcall(vim.uv.fs_chmod, p, 384) -- 0600
  state.empty_file = p
  return p
end

--- 生成净化后的 resolv.conf（仅保留 nameserver 行，剥离 search/domain/options 等
--- 泄露宿主内网/Tailscale 域的字段）。无 nameserver 或不可读时返回 nil（退化为不暴露）。
--- @return string|nil 宿主私有路径
local function _sanitized_resolv_conf()
  local f = io.open("/etc/resolv.conf", "r")
  if not f then return nil end
  local lines = {}
  for line in f:lines() do
    local ns = line:match("^%s*(nameserver%s+[^%s#;]+)")
    if ns then lines[#lines + 1] = ns end
  end
  f:close()
  if #lines == 0 then return nil end
  local p = _private_dir() .. "/resolv.conf"
  local out = io.open(p, "w")
  if not out then return nil end
  out:write("# NeoAI sandbox: sanitized (search/domain/options stripped)\n")
  for _, l in ipairs(lines) do out:write(l, "\n") end
  out:close()
  pcall(vim.uv.fs_chmod, p, 420) -- 0644
  return p
end

-- 默认遮蔽目录（安全默认，可经 tools.sandbox.mask_dirs 覆盖）：这些目录下除 cwd 路径外的
-- 内容对外部命令不可见。`/home` 按「每个用户 home」为作用域暴露，其他用户 home 不暴露。
local DEFAULT_MASK_DIRS = { "/home", "/root" }

--- 路径 p 是否等于 r 或位于 r 之下（按路径段边界）
--- @param p string
--- @param r string
--- @return boolean
local function _under(p, r)
  if type(p) ~= "string" or type(r) ~= "string" then return false end
  return p == r or p:sub(1, #r + 1) == r .. "/"
end

--- 解析路径的规范形式（进程内工具遮蔽判定用）：展开 ~/环境变量 → 绝对化 → 解析符号链接。
--- 必须解析 `/proc/<pid>/root`、`/proc/<pid>/cwd`、`/proc/<pid>/fd` 及普通符号链接，
--- 否则 `read_file /proc/self/root/etc/shadow` 或工作区内指向宿主凭据的符号链接可绕过
--- `mask_paths`/`mask_dirs`（进程内工具不经 mount 遮蔽，只靠这里的路径比对）。
--- `vim.fn.resolve` 能解析悬空符号链接（目标尚不存在时按符号链接指向判定），
--- 使「经符号链接写入未创建文件」也被覆盖。
--- @param path string
--- @return string
local function _canonical(path)
  if type(path) ~= "string" or path == "" then return path end
  local abs = vim.fn.fnamemodify(path, ":p")
  local ok, resolved = pcall(vim.fn.resolve, abs)
  if ok and type(resolved) == "string" and resolved ~= "" then abs = resolved end
  abs = abs:gsub("^/+", "/"):gsub("/+$", "")
  if abs == "" then abs = "/" end
  return abs
end

--- 遮蔽目录总开关（默认开）
--- @return boolean
local function _mask_dirs_enabled()
  return config_store.get("tools.sandbox.mask_dirs_enabled") ~= false
end

--- 配置的遮蔽目录列表（存在性过滤）
--- @return table 字符串数组
local function _mask_dirs()
  local cfg = config_store.get("tools.sandbox.mask_dirs")
  local list = (type(cfg) == "table" and next(cfg) ~= nil) and cfg or DEFAULT_MASK_DIRS
  local out = {}
  for _, d in ipairs(list) do
    if type(d) == "string" and d ~= "" and d ~= "/" then
      d = d:gsub("/+$", "")
      if d ~= "" and vim.uv.fs_stat(d) then out[#out + 1] = d end
    end
  end
  return out
end

--- cwd 对应的遮蔽作用域列表：命中遮蔽目录时，暴露（只读）并遮蔽的是「含 cwd 的用户 home」，
--- `/home` 取一级子目录（用户）为作用域，其他遮蔽目录取自身。
--- @param cwd string|nil
--- @return table 作用域路径数组
local function _mask_scopes(cwd)
  if not _mask_dirs_enabled() then return {} end
  if type(cwd) ~= "string" or cwd == "" then return {} end
  cwd = cwd:gsub("/+$", "")
  local out = {}
  for _, d in ipairs(_mask_dirs()) do
    if _under(cwd, d) then
      local scope = d
      if d == "/home" then
        local first = cwd:sub(#d + 2):match("^([^/]+)")
        if first then scope = d .. "/" .. first end
      end
      out[#out + 1] = scope
    end
  end
  return out
end

--- 追加最小只读系统集挂载（白名单）。未列出的宿主路径在沙箱内不存在，
--- 因此读取面不再等于整机根。支持 `*` 通配，跳过不存在的条目。
--- 当 cwd 位于某个遮蔽目录下时，额外把该作用域（用户 home）以只读暴露，使工作目录可访问；
--- 作用域内的敏感条目由 `_masked_paths` 的目录遮蔽收敛。
--- @param argv table
--- @param cwd string|nil
local function _append_readonly_mounts(argv, cwd)
  local seen = {}
  local function add(p)
    if type(p) ~= "string" or p == "" or p == "/" then return end
    p = p:gsub("/+$", "")
    if p == "" or seen[p] then return end
    if vim.uv.fs_stat(p) then
      seen[p] = true
      argv[#argv + 1] = "--ro-bind"
      argv[#argv + 1] = p
      argv[#argv + 1] = p
    end
  end
  local function add_list(list)
    for _, p in ipairs(list or {}) do
      if type(p) == "string" and p:find("[*?[]") then
        local ok, matches = pcall(vim.fn.glob, p, false, true)
        if ok and type(matches) == "table" then
          for _, m in ipairs(matches) do add(m) end
        end
      else
        add(p)
      end
    end
  end
  add_list(_readonly_list("tools.sandbox.readonly_roots", DEFAULT_READONLY_ROOTS))
  add_list(_readonly_list("tools.sandbox.readonly_paths", DEFAULT_READONLY_PATHS))
  for _, scope in ipairs(_mask_scopes(cwd)) do add(scope) end
  -- /etc/resolv.conf：默认净化后暴露（仅 nameserver，剥离 search/domain/options，避免
  -- 泄露宿主内网/Tailscale 域）；"hide" 不暴露；"passthrough" 原样暴露宿主文件。
  local rmode = config_store.get("tools.sandbox.resolv_conf") or "sanitize"
  if rmode == "passthrough" then
    add("/etc/resolv.conf")
  elseif rmode ~= "hide" then
    local rp = _sanitized_resolv_conf()
    if rp then
      argv[#argv + 1] = "--ro-bind"
      argv[#argv + 1] = rp
      argv[#argv + 1] = "/etc/resolv.conf"
    end
  end
end

--- 追加每会话私有临时根挂载。给了 session_base（会话私有宿主目录）时，把其下
--- 按根编码的子目录以 mode 1777 绑定到该根（tmpfs 语义、会话内共享、退出即销毁）；
--- 未给时退回空 `--tmpfs`。始终不把宿主真实临时目录作为 lower/内容暴露。
--- 临时根私有目录位置模式：host（默认，建在宿主根之下的隐藏子目录）| session（旧行为）
--- @return string
local function _tmp_private_base_mode()
  local m = config_store.get("tools.sandbox.tmp_private_base")
  if m == "session" then return "session" end
  return "host"
end

--- 清理某临时根私有基目录下除 keep_session 外的陈旧会话子目录
--- @param base string
--- @param keep_session string|nil
local function _prune_tmp_base(base, keep_session)
  if vim.fn.isdirectory(base) ~= 1 then return end
  for _, name in ipairs(vim.fn.readdir(base) or {}) do
    if name ~= keep_session then
      pcall(vim.fn.delete, base .. "/" .. name, "rf")
    end
  end
end

--- 追加每会话私有临时根挂载。
--- host 模式：在宿主根（如 /tmp）下建隐藏子目录 <root>/.cache-<tag>/<session>（1777），
--- 命名空间 bind 回该根——AI 在沙箱内看到的 /tmp 即此私有子目录，宿主 /tmp 内容不可见。
--- session 模式/不可用时：退回进程目录下的私有目录；再退回空 tmpfs。
--- @param argv table
--- @param session_base string|nil 会话进程目录（其 basename 即会话 id）
local function _append_tmpfs_roots(argv, session_base)
  local session = (type(session_base) == "string" and session_base ~= "")
    and vim.fn.fnamemodify(session_base, ":t") or nil
  local mode = _tmp_private_base_mode()
  local conceal = require("NeoAI.sandbox.conceal")
  for _, p in ipairs(_tmpfs_roots()) do
    local bound = false
    -- host 模式：私有目录建在宿主根之下，命名空间映射回该根
    if mode == "host" and session and vim.fn.isdirectory(p) == 1 then
      local base = conceal.tmp_base_host(p)
      local dir = base .. "/" .. session
      pcall(vim.fn.mkdir, dir, "p")
      pcall(vim.uv.fs_chmod, dir, 1023) -- 01777（sticky + world-writable）
      if vim.fn.isdirectory(dir) == 1 then
        _prune_tmp_base(base, session)
        argv[#argv + 1] = "--bind"
        argv[#argv + 1] = dir
        argv[#argv + 1] = p
        bound = true
      end
    end
    -- session 模式 / host 模式建目录失败：退回进程目录下的私有目录
    if not bound and type(session_base) == "string" and session_base ~= "" then
      local dir = session_base .. "/" .. p:gsub("^/", ""):gsub("/", "_")
      pcall(vim.fn.mkdir, dir, "p")
      pcall(vim.uv.fs_chmod, dir, 1023)
      if vim.fn.isdirectory(dir) == 1 then
        argv[#argv + 1] = "--bind"
        argv[#argv + 1] = dir
        argv[#argv + 1] = p
        bound = true
      end
    end
    if not bound then
      argv[#argv + 1] = "--tmpfs"
      argv[#argv + 1] = p
    end
  end
end

--- 清理沙箱临时根在宿主侧创建的私有目录（重置/关闭时调用）。
function M.cleanup_tmp_roots()
  local conceal = require("NeoAI.sandbox.conceal")
  for _, p in ipairs(_tmpfs_roots()) do
    pcall(vim.fn.delete, conceal.tmp_base_host(p), "rf")
  end
end

--- 追加 /proc/sys 整体只读绑定：一次性封闭**所有**非命名空间全局 sysctl 的写入面
--- （core_pattern/modprobe/randomize_va_space/kptr_restrict/dmesg_restrict/net.*/vm.*/fs.* 等）。
--- 这些条目的写权限按 DAC（euid == 全局 root uid）判定，`--cap-drop ALL` 无法阻止；
--- 共享 netns 下 net.* 还会直接改宿主网络。只读绑定后读仍可用、写返回 EROFS。
--- 必须在 `--proc /proc` 之后调用（源路径取自新 procfs）。
--- @param argv table
local function _append_proc_sys_ro(argv)
  argv[#argv + 1] = "--ro-bind"
  argv[#argv + 1] = "/proc/sys"
  argv[#argv + 1] = "/proc/sys"
end

--- 追加 /proc 泄露项与危险 sysctl 遮蔽（以空文件只读覆盖：读为空、写 EROFS）。
--- 强制表（core_pattern/modprobe 等）始终生效，用户 `hide_proc_paths` 只能追加。
--- @param argv table
local function _append_hidden_proc(argv)
  local empty = _empty_file()
  if not empty then return end
  for _, p in ipairs(_proc_mask_paths()) do
    if type(p) == "string" and p ~= "" and vim.uv.fs_stat(p) then
      argv[#argv + 1] = "--ro-bind"
      argv[#argv + 1] = empty
      argv[#argv + 1] = p
    end
  end
end

--- 追加宿主运行时直通挂载（opt-in）：置于 tmpfs/遮蔽之后，故可显式暴露被遮蔽或临时根
--- 下的工具链目录（如 appimage nvim 的 `/tmp/.mount_*`、mason 的 `~/.local/share/nvim/mason`）。
--- 仅以只读绑定暴露；空/根/不存在路径跳过。
--- @param argv table
local function _append_expose_mounts(argv)
  for _, p in ipairs(_expose_paths()) do
    if vim.uv.fs_stat(p) then
      argv[#argv + 1] = "--ro-bind"
      argv[#argv + 1] = p
      argv[#argv + 1] = p
    end
  end
end

--- 追加 bwrap 基础隔离参数（隔离标志 + 最小只读系统集 + --as-pid-1 隐藏 bwrap 进程）
--- @param argv table
--- @param flags table 隔离标志
--- @param priv table|nil 档位隔离参数（cap_add 等）
--- @param cwd string|nil 工作目录（用于决定是否暴露其所在用户 home）
local function _append_bwrap_base(argv, flags, priv, cwd)
  argv[#argv + 1] = "bwrap"
  for _, f in ipairs(flags) do argv[#argv + 1] = f end
  for _, f in ipairs({ "--die-with-parent", "--as-pid-1" }) do argv[#argv + 1] = f end
  _append_readonly_mounts(argv, cwd)
  for _, f in ipairs({ "--dev", "/dev", "--proc", "/proc" }) do
    argv[#argv + 1] = f
  end
  -- /proc/sys 整体只读绑定（根因修复），见 _append_proc_sys_ro。
  _append_proc_sys_ro(argv)
  -- 临时根默认空 tmpfs（会话级绑定的覆盖见 process_prefix）；/proc 泄露项以空文件覆盖。
  _append_tmpfs_roots(argv)
  _append_hidden_proc(argv)
  -- 丢弃全部 capabilities（可经 tools.sandbox.cap_add / 档位 cap_add 按需加回）。载荷不再
  -- 持有 CAP_SYS_ADMIN / CAP_SYS_MODULE / CAP_SYS_PTRACE 等，mount、模块加载等被内核拒绝。
  -- 注意：cap-drop **不能**阻止写 core_pattern/modprobe —— /proc/sys 的写权限按 DAC
  -- （euid == 全局 root uid）判定，与 capability 无关；这类全局 sysctl 由上面的
  -- _append_hidden_proc（MANDATORY_PROC_MASKS）以只读绑定遮蔽，而非依赖 cap-drop/seccomp。
  argv[#argv + 1] = "--cap-drop"
  argv[#argv + 1] = "ALL"
  for _, cap in ipairs(_cap_add(priv)) do
    argv[#argv + 1] = "--cap-add"
    argv[#argv + 1] = cap
  end
end

--- 功能探测 bwrap 基础隔离是否可用（隔离标志 + 只读 rootfs）
--- @param flags table 隔离标志
--- @return boolean
local function _bwrap_works(flags)
  if not _executable("bwrap") then return false end
  local argv = {}
  _append_bwrap_base(argv, flags)
  argv[#argv + 1] = "--"
  argv[#argv + 1] = "true"
  return _run_probe(argv)
end

--- 以给定 lower/upper/work 真实挂载一次 overlay，返回是否成功。
--- /proc/filesystems 含 overlay 只是内核支持，不代表新建 userns 内可挂载：
--- 当宿主 / 的 superblock 归属 init userns 时（如容器内），overlay 的 lower/upper
--- 与新建 userns 不同源，内核返回 EINVAL。必须实测，且**必须用真实执行时的路径**
--- 实测：lower 与 upper/work 落在不同挂载/不同 userns 归属时才会触发 EINVAL，
--- 用同源临时目录探测会产生假阳性。
--- @param lower string
--- @param upper string
--- @param work string
--- @param flags table 隔离标志
--- @return boolean
local function _overlay_mount_works(lower, upper, work, flags)
  local argv = {}
  _append_bwrap_base(argv, flags)
  for _, f in ipairs({
    "--overlay-src", lower, "--overlay", upper, work, lower,
    "--chdir", lower, "--", "true",
  }) do argv[#argv + 1] = f end
  return _run_probe(argv)
end

--- 功能探测 overlay 是否可用（同源临时目录）。仅作粗粒度能力门禁，
--- 真实执行前还须用实际路径再实测一次（见 M.overlay_mountable）。
--- @param flags table 隔离标志
--- @return boolean
local function _overlay_works(flags)
  local tmp = vim.fn.tempname()
  local lower, upper, work = tmp .. "/lower", tmp .. "/upper", tmp .. "/work"
  pcall(vim.fn.mkdir, lower, "p")
  pcall(vim.fn.mkdir, upper, "p")
  pcall(vim.fn.mkdir, work, "p")
  local ok = _overlay_mount_works(lower, upper, work, flags)
  pcall(vim.fn.delete, tmp, "rf")
  return ok
end

--- 探测内核/工具能力（含 bwrap/overlay 功能实测）
--- @return table
local function _probe()
  local caps = {
    bwrap = false,
    unshare = _executable("unshare"),
    userns = false,
    userns_free = false,
    bwrap_flags = nil,
    cgroup2 = false,
    overlayfs = false,
    seccomp = false,
    checked_at = os.time(),
  }
  -- 非特权 user namespace
  local f = io.open("/proc/sys/kernel/unprivileged_userns_clone", "r")
  if f then
    local v = f:read("*a")
    f:close()
    caps.userns = v:gsub("%s", "") == "1"
  else
    caps.userns = caps.unshare
  end
  -- bwrap：功能实测（仅存在二进制不够）。隐匿优先：root 下先试「无 user namespace」，
  -- 成功则采用（避免 uid_map/ns-user 泄露）；否则退回带 userns 的隔离。
  local flags = nil
  if _is_root() and _bwrap_works(NO_USER_FLAGS) then
    flags = NO_USER_FLAGS
    caps.userns_free = true
  elseif _bwrap_works(USER_FLAGS) then
    flags = USER_FLAGS
  end
  caps.bwrap = flags ~= nil
  caps.bwrap_flags = flags
  -- overlayfs：在选定隔离模式下真实挂载实测
  if caps.bwrap then
    caps.overlayfs = _overlay_works(flags)
  end
  -- cgroup v2
  local cf = io.open("/sys/fs/cgroup/cgroup.controllers", "r")
  if cf then
    caps.cgroup2 = true
    cf:close()
  end
  -- seccomp（内核编译支持）
  local sf = io.open("/proc/sys/kernel/seccomp/actions_avail", "r")
  if sf then
    caps.seccomp = true
    sf:close()
  end
  return caps
end

--- 计算遮蔽目录产生的遮蔽路径（仅路径）。作用域 = cwd 所在用户 home：
---   * cwd 深于作用域：沿 cwd 祖先链逐级遮蔽兄弟条目（含隐藏文件/目录），cwd 子树豁免；
---   * cwd 即作用域：遮蔽其隐藏子条目（凭据类 dotfile），普通工作文件保留。
--- 未命中遮蔽目录（如 cwd=/tmp）时返回空。仅在 `mask_dirs_enabled ~= false` 时生效。
--- @param cwd string|nil
--- @return table 路径数组
local function _dir_masks(cwd)
  if not _mask_dirs_enabled() then return {} end
  if type(cwd) ~= "string" or cwd == "" then return {} end
  cwd = cwd:gsub("/+$", "")
  local out = {}
  for _, scope in ipairs(_mask_scopes(cwd)) do
    if scope == cwd then
      local handle = vim.uv.fs_scandir(scope)
      if handle then
        while true do
          local name = vim.uv.fs_scandir_next(handle)
          if not name then break end
          if name:sub(1, 1) == "." and name ~= "." and name ~= ".." then
            out[#out + 1] = scope .. "/" .. name
          end
        end
      end
    else
      local node = scope
      while node ~= cwd do
        local next_child = cwd:sub(#node + 2):match("^([^/]+)")
        if not next_child then break end
        local handle = vim.uv.fs_scandir(node)
        if handle then
          while true do
            local name = vim.uv.fs_scandir_next(handle)
            if not name then break end
            if name ~= next_child then out[#out + 1] = node .. "/" .. name end
          end
        end
        node = node .. "/" .. next_child
      end
    end
  end
  return out
end

--- 计算某目标路径对应的「遮蔽条目」：即隐藏它的那一条 mask 挂载路径；未被遮蔽返回 nil。
--- 供工具审批使用：命中时弹窗审批，批准后对该条目解除遮蔽（unmask）。
--- @param path string|nil
--- @param cwd string|nil
--- @return string|nil mask_entry
local function _mask_entry(path, cwd)
  if not _mask_dirs_enabled() then return nil end
  if type(path) ~= "string" or path == "" then return nil end
  -- 先解析符号链接/`/proc/<pid>/root`，否则可经其绕过遮蔽目录命中判定。
  path = _canonical(path)
  if path == "" or path == "/" then return nil end
  if type(cwd) ~= "string" or cwd == "" then return nil end
  cwd = _canonical(cwd)
  for _, scope in ipairs(_mask_scopes(cwd)) do
    if _under(path, scope) then
      if scope == cwd then
        -- cwd 即作用域：仅隐藏子条目被遮蔽
        local first = path:sub(#scope + 2):match("^([^/]+)")
        if first and first:sub(1, 1) == "." then return scope .. "/" .. first end
        return nil
      end
      if path == cwd or _under(path, cwd) or _under(cwd, path) then return nil end
      local node = scope
      while true do
        local next_child = cwd:sub(#node + 2):match("^([^/]+)")
        if not next_child then return nil end
        local child = path:sub(#node + 2):match("^([^/]+)")
        if child == next_child then
          node = node .. "/" .. next_child
        else
          return node .. "/" .. (child or path:sub(#node + 2))
        end
      end
    end
  end
  return nil
end

--- 配置/内置的宿主敏感遮蔽路径（展开 glob、去重）。不含沙箱自身存储与按 cwd 的遮蔽目录。
--- @return table 字符串数组
local function _config_mask_paths()
  local out, seen = {}, {}
  local cfg = config_store.get("tools.sandbox.mask_paths")
  local list = type(cfg) == "table" and cfg or DEFAULT_MASK_PATHS
  for _, p in ipairs(list) do
    if type(p) == "string" then
      if p:find("[*?[]") then
        local okg, matches = pcall(vim.fn.glob, p, false, true)
        if okg and type(matches) == "table" then
          for _, m in ipairs(matches) do
            m = m:gsub("/+$", "")
            if m ~= "" and m ~= "/" and not seen[m] then seen[m] = true; out[#out + 1] = m end
          end
        end
      else
        p = p:gsub("/+$", "")
        if p ~= "" and p ~= "/" and not seen[p] then seen[p] = true; out[#out + 1] = p end
      end
    end
  end
  return out
end

--- 需要在隔离环境内遮蔽的宿主路径，返回 { path, kind } 数组（kind = "dir" | "file"）。
--- 三类：
---   1. 沙箱自身存储（候选/会话/回执）——AI 的外部命令不得看到或篡改内部状态；
---   2. 宿主敏感路径（socket / 凭据 / 容器数据）——见 DEFAULT_MASK_PATHS；
---   3. 遮蔽目录作用域内的兄弟/隐藏条目——见 `_dir_masks`（cwd 子树豁免）。
--- @param unmask table|nil 解除遮蔽的路径数组（档位提权 / 审批放行）
--- @param cwd string|nil 工作目录（用于遮蔽目录）
--- @return table 数组 { path, kind }
local function _masked_paths(unmask, cwd)
  local out, seen = {}, {}
  local skip, skip_list = {}, {}
  for _, p in ipairs(unmask or {}) do
    if type(p) == "string" and p ~= "" then
      p = p:gsub("/+$", "")
      if p ~= "" and not skip[p] then
        skip[p] = true
        skip_list[#skip_list + 1] = p
      end
    end
  end
  --- 是否被 unmask 覆盖（精确或祖先命中）
  local function unmasked(p)
    if skip[p] then return true end
    for _, u in ipairs(skip_list) do if _under(p, u) then return true end end
    return false
  end
  local function add(p, force)
    if type(p) ~= "string" or p == "" or p == "/" then return end
    p = p:gsub("/+$", "")
    if seen[p] or (not force and unmasked(p)) then return end
    local st = vim.uv.fs_stat(p)
    if not st then return end
    seen[p] = true
    out[#out + 1] = { path = p, kind = st.type == "directory" and "dir" or "file" }
  end
  -- 沙箱自身存储永远遮蔽（force），审批放行/档位 unmask 均不得解除。
  local ok, store = pcall(require, "NeoAI.sandbox.store")
  if ok and store and store.root then add(store.root(), true) end
  for _, p in ipairs(_config_mask_paths()) do add(p) end
  for _, p in ipairs(_dir_masks(cwd)) do add(p) end
  return out
end

-- ========== 公开 API ==========
--- 探测并缓存能力
--- @return table
function M.probe()
  state.caps = _probe()
  return state.caps
end

--- @return table
function M.capabilities()
  if not state.caps then return M.probe() end
  return state.caps
end

--- 当前选定的 bwrap 隔离标志（无 user namespace 优先；探测未运行时回退带 userns）
--- @return table
function M.bwrap_flags()
  local caps = M.capabilities()
  return caps.bwrap_flags or USER_FLAGS
end

--- 追加最小只读系统集挂载参数（供 LSP overlay 等复用，保证读取面一致）。
--- @param argv table|nil
--- @return table
function M.append_readonly(argv)
  argv = argv or {}
  _append_readonly_mounts(argv)
  return argv
end

--- 追加每会话私有临时根挂载（供 LSP 前缀复用）。session_base 给定时绑定其下 1777
--- 子目录，否则退回空 tmpfs。
--- @param argv table|nil
--- @param session_base string|nil
--- @return table
function M.append_tmpfs_roots(argv, session_base)
  argv = argv or {}
  _append_tmpfs_roots(argv, session_base)
  return argv
end

--- 追加 /proc 泄露项隐藏挂载（供 LSP 前缀复用）。
--- @param argv table|nil
--- @return table
function M.append_hidden_proc(argv)
  argv = argv or {}
  _append_hidden_proc(argv)
  return argv
end

--- 追加 /proc/sys 只读绑定（供 LSP 前缀复用；须在 `--proc /proc` 之后调用）。
--- @param argv table|nil
--- @return table
function M.append_proc_sys_ro(argv)
  argv = argv or {}
  _append_proc_sys_ro(argv)
  return argv
end

--- 强制遮蔽的危险全局 sysctl 列表（常驻，不可被用户配置移除）。
--- @return table 字符串数组
function M.mandatory_proc_masks()
  local out = {}
  for i, p in ipairs(MANDATORY_PROC_MASKS) do out[i] = p end
  return out
end

--- 实际遮蔽的 /proc 路径（强制表 ∪ 用户 hide_proc_paths，去重）。
--- @return table 字符串数组
function M.proc_mask_paths()
  return _proc_mask_paths()
end

--- 沙箱外部命令可代理变量（大小写两种写法）
local PROXY_KEYS = {
  "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "FTP_PROXY", "RSYNC_PROXY",
  "http_proxy", "https_proxy", "all_proxy", "ftp_proxy", "rsync_proxy",
}

--- 沙箱外部命令代理策略：
---   "strip"（默认）：不把宿主代理传入沙箱（如 mihomo 只代理 opencode 自身）；
---   "passthrough"：沿用宿主代理；
---   table { http, https, all, no_proxy }：显式设置（未列出的代理变量清除）。
--- @return string|table
local function _proxy_policy()
  local netcfg = config_store.get("tools.sandbox.network") or {}
  local p = netcfg.proxy
  if p == nil then return "strip" end
  return p
end

--- 是否启用「宿主本机访问拦截」代理（默认开）。offline=true 时网络已硬隔离，无需代理。
--- @return boolean
local function _host_local_block_enabled()
  local netcfg = config_store.get("tools.sandbox.network") or {}
  if netcfg.host_local_block == false then return false end
  local sandbox = config_store.get("tools.sandbox") or {}
  if sandbox.offline == true then return false end
  -- 独立 netns 网关模式已自行提供代理，二者互斥。
  local ok_ng, net_gateway = pcall(require, "NeoAI.sandbox.net_gateway")
  if ok_ng and net_gateway.enabled() then return false end
  return true
end

--- 生成清除代理变量的 shell 片段（供外部命令前置）。passthrough 或无需清除时返回 nil。
--- 网络网关模式 / 本机拦截代理启用时返回 nil：会注入指向宿主代理的变量，不能被清除。
--- @return string|nil
local function _proxy_unset_snippet()
  local ok_ng, net_gateway = pcall(require, "NeoAI.sandbox.net_gateway")
  if ok_ng and net_gateway.enabled() then return nil end
  if _host_local_block_enabled() then return nil end
  local p = _proxy_policy()
  if p == "passthrough" then return nil end
  local keep = {}
  if type(p) == "table" then
    if p.http then keep.HTTP_PROXY = true; keep.http_proxy = true end
    if p.https then keep.HTTPS_PROXY = true; keep.https_proxy = true end
    if p.all then keep.ALL_PROXY = true; keep.all_proxy = true end
  end
  local keys = {}
  for _, k in ipairs(PROXY_KEYS) do
    if not keep[k] then keys[#keys + 1] = k end
  end
  if #keys == 0 then return nil end
  return "unset " .. table.concat(keys, " ") .. " 2>/dev/null"
end

--- 构造沙箱进程环境：密钥 token 化覆盖 + expose_paths 目录前置到 PATH + 代理策略 + 档位 env。
--- 所有外部进程（run_command / runtime.run）统一经此构造，保证环境一致且可观测。
--- @param privileges table|nil { env? = table }
--- @return table
function M.sandbox_env(privileges)
  local env = require("NeoAI.sandbox.secret").sanitized_env()
  local expose = _expose_paths()
  if #expose > 0 and config_store.get("tools.sandbox.expose_path_env") ~= false then
    local cur = vim.env.PATH or ""
    env.PATH = table.concat(expose, ":") .. (cur ~= "" and (":" .. cur) or "")
  end
  -- 代理策略：显式代理写入 env（strip 时由外部命令前置 unset 清除，避免宿主代理不可达导致失败）。
  local proxy = _proxy_policy()
  if type(proxy) == "table" then
    if proxy.http then env.HTTP_PROXY = proxy.http; env.http_proxy = proxy.http end
    if proxy.https then env.HTTPS_PROXY = proxy.https; env.https_proxy = proxy.https end
    if proxy.all then env.ALL_PROXY = proxy.all; env.all_proxy = proxy.all end
    if proxy.no_proxy ~= nil then env.NO_PROXY = proxy.no_proxy; env.no_proxy = proxy.no_proxy end
  end
  -- 网络网关模式：注入代理环境，使 curl/wget/git 等经宿主网关（探测端口、拦截服务）。
  local ok_ng, net_gateway = pcall(require, "NeoAI.sandbox.net_gateway")
  if ok_ng and net_gateway.enabled() then
    for k, v in pairs(net_gateway.env()) do env[k] = v end
  end
  -- 宿主本机访问拦截：注入指向宿主过滤代理（host_proxy）的代理变量。代理拦截本机目标、
  -- 放行外部并记录；网络整体仍是「放行 + 记录」。裸 TCP 不经代理（应用层边界，见文档）。
  if _host_local_block_enabled() then
    local ok_hp, host_proxy = pcall(require, "NeoAI.sandbox.host_proxy")
    if ok_hp and host_proxy then
      local addr = host_proxy.ensure()
      if addr then
        local url = ("http://127.0.0.1:%d"):format(addr.port)
        env.HTTP_PROXY, env.http_proxy = url, url
        env.HTTPS_PROXY, env.https_proxy = url, url
        local socks = ("socks5h://127.0.0.1:%d"):format(addr.port)
        env.ALL_PROXY, env.all_proxy = socks, socks
        env.NO_PROXY, env.no_proxy = "", ""
      end
    end
  end
  if privileges and type(privileges.env) == "table" then
    for k, v in pairs(privileges.env) do env[k] = v end
  end
  return env
end

--- 外部命令应前置的代理清除片段（strip/显式策略下；passthrough 返回 nil）。
--- @return string|nil
function M.proxy_unset_snippet()
  return _proxy_unset_snippet()
end

--- 用 shell 包装 argv：先关闭除 0/1/2 外所有继承 fd，再 exec argv。
--- 供 LSP 等自建 bwrap 前缀复用，避免继承宿主目录 fd 造成 chroot 逃逸。
--- @param argv table
--- @return table
function M.wrap_close_fds(argv)
  return _wrap_close_fds(argv)
end

--- 配置的每会话私有临时根列表（供 wrapper 从可写根 overlay 中剔除）。
--- @return table 字符串数组
function M.tmpfs_roots()
  return _tmpfs_roots()
end

--- 追加宿主敏感路径遮蔽挂载（供 LSP 命名空间等复用，保持与 run_command 一致的遮蔽面）：
--- 仅应用配置/内置 mask_paths 与沙箱自身存储，不含按 cwd 的遮蔽目录（避免遮蔽工作区兄弟）。
--- @param argv table|nil
--- @return table
function M.append_masked(argv)
  argv = argv or {}
  for _, mp in ipairs(_masked_paths(nil, nil)) do
    if mp.kind == "dir" then
      table.insert(argv, "--tmpfs"); table.insert(argv, mp.path)
    else
      table.insert(argv, "--bind"); table.insert(argv, "/dev/null"); table.insert(argv, mp.path)
    end
  end
  return argv
end

--- 查询目标路径命中的遮蔽条目（供工具审批：命中则弹窗，批准后 unmask 该条目）。
--- @param path string|nil
--- @param cwd string|nil
--- @return string|nil mask_entry
function M.mask_entry(path, cwd)
  return _mask_entry(path, cwd)
end

--- 目标路径是否命中宿主敏感遮蔽路径（`tools.sandbox.mask_paths` + 沙箱自身存储）。
--- 供**进程内** read/fs_write 工具显式拦截：这些工具不经 namespace，mount 遮蔽对其无效，
--- 必须由执行器按此查询 fail-closed。不含按 cwd 的遮蔽目录（由 `mask_entry` 处理，
--- 语义与审批放行不同）。
--- @param path string|nil 绝对路径
--- @return string|nil 命中的遮蔽条目
function M.is_masked_path(path)
  if type(path) ~= "string" or path == "" then return nil end
  -- 解析符号链接与 `/proc/<pid>/root|cwd|fd`：进程内工具只按路径比对遮蔽，
  -- 若不做规范化，`/proc/self/root/etc/shadow` 或指向宿主凭据的符号链接可绕过。
  path = _canonical(path)
  if path == "" or path == "/" then return nil end
  local ok, store = pcall(require, "NeoAI.sandbox.store")
  if ok and store and store.root then
    local sr = (store.root() or ""):gsub("/+$", "")
    if sr ~= "" and (_under(path, sr) or _under(path, _canonical(sr))) then return sr end
  end
  for _, p in ipairs(_config_mask_paths()) do
    -- 同时比对原始与规范化后的遮蔽条目：条目自身可能含符号链接（如 /var/run → /run）。
    if _under(path, p) or _under(path, _canonical(p)) then return p end
  end
  return nil
end

--- 遮蔽目录总开关与列表（只读查询）
--- @return boolean
function M.mask_dirs_enabled()
  return _mask_dirs_enabled()
end

--- @return table 配置的遮蔽目录列表
function M.mask_dirs()
  return _mask_dirs()
end

--- 当前环境是否可在 bwrap userns 内真实挂载 overlayfs（粗粒度能力门禁）
--- @return boolean
function M.overlay_available()
  return M.capabilities().overlayfs == true
end

--- 用真实执行路径（lower=cwd, upper/work=私有层）实测 overlay 是否可挂载。
--- 结果按 lower/upper 所在文件系统设备对缓存：同一 (dev_lower, dev_upper) 组合
--- 在本进程内复用，避免每条命令都多起一次 bwrap。
--- @param lower string
--- @param upper string
--- @param work string
--- @return boolean
function M.overlay_mountable(lower, upper, work)
  if not (lower and upper and work) then return false end
  local st_u = vim.uv.fs_stat(upper)
  local key = tostring(lower) .. "|" .. tostring(st_u and st_u.dev or -1)
  local cached = state.overlay_probe[key]
  if cached ~= nil then return cached end
  local ok = _overlay_mount_works(lower, upper, work, M.bwrap_flags())
  state.overlay_probe[key] = ok
  return ok
end

--- 诊断某可写根为何无法使用 overlay（供能力查询与降级提示）。
--- 返回 nil 表示可用；否则返回简短原因码（含设备/挂载信息）。
--- @param root string
--- @param upper string|nil
--- @param work string|nil
--- @return string|nil
function M.overlay_reason(root, upper, work)
  local caps = M.capabilities()
  if not caps.bwrap then return "NO_BWRAP_BACKEND" end
  if not caps.overlayfs then
    -- 粗粒度探测失败：区分是否缺少 user namespace（root 下免 userns 可用）
    local flags = caps.bwrap_flags or M.bwrap_flags()
    local userns = false
    for _, f in ipairs(flags) do
      if f == "--unshare-all" or f == "--unshare-user" then userns = true end
    end
    if userns then
      return "OVERLAY_COARSE_PROBE_FAILED(userns=true; 容器内宿主 / 归属 init userns 时 overlay 会 EINVAL)"
    end
    return "OVERLAY_COARSE_PROBE_FAILED(内核/挂载不支持或 upper 文件系统不支持 overlay)"
  end
  if not (root and upper and work) then return nil end
  if M.overlay_mountable(root, upper, work) then return nil end
  local st_l = vim.uv.fs_stat(root)
  local st_u = vim.uv.fs_stat(upper)
  local ldev = st_l and st_l.dev or -1
  local udev = st_u and st_u.dev or -1
  if ldev ~= udev then
    return string.format("OVERLAY_MOUNT_EINVAL(lower_dev=%s upper_dev=%s; lower/upper 跨挂载或 userns 归属不同)",
      tostring(ldev), tostring(udev))
  end
  return string.format("OVERLAY_MOUNT_EINVAL(dev=%s; 该文件系统不支持 overlay upper/work)",
    tostring(ldev))
end

--- 诊断当前环境的 overlay 可用性（供能力查询）：用真实执行路径（cwd + 沙箱 overlay 基目录）
--- 实测一次并返回原因，便于排查降级模式为何触发。
--- @param root string|nil（默认当前工作目录）
--- @return table { available, reason?, flags, userns, upper? }
function M.overlay_diagnosis(root)
  root = root or vim.fn.getcwd()
  local caps = M.capabilities()
  local flags = caps.bwrap_flags or M.bwrap_flags()
  local userns = false
  for _, f in ipairs(flags) do
    if f == "--unshare-all" or f == "--unshare-user" then userns = true end
  end
  if not caps.bwrap then
    return { available = false, reason = "NO_BWRAP_BACKEND", flags = flags, userns = userns }
  end
  if not caps.overlayfs then
    return { available = false, reason = M.overlay_reason(root), flags = flags, userns = userns }
  end
  local base = require("NeoAI.sandbox.conceal").base_host()
  local upper, work = base .. "/diag-u", base .. "/diag-w"
  pcall(vim.fn.mkdir, upper, "p")
  pcall(vim.fn.mkdir, work, "p")
  local ok = M.overlay_mountable(root, upper, work)
  return {
    available = ok,
    reason = ok and nil or M.overlay_reason(root, upper, work),
    flags = flags, userns = userns, upper = upper,
  }
end

--- 选择可用后端
--- @return string|nil "bwrap" | "unshare"
function M.backend()
  local caps = M.capabilities()
  local cfg = config_store.get("tools.sandbox.backend") or "auto"
  if cfg == "bwrap" then
    return caps.bwrap and "bwrap" or nil
  elseif cfg == "unshare" then
    return (caps.unshare and caps.userns) and "unshare" or nil
  end
  if caps.bwrap then return "bwrap" end
  if caps.unshare and caps.userns then return "unshare" end
  return nil
end

--- 构造外部进程 argv 前缀
--- @param opts table { cwd?, upper?, work?, fallback_cwd?, session_tmp_dir?, network?, privileges? = { tier, cap_add, mounts, unmask, network, userns } }
--- @return table|nil prefix
--- @return string|nil err
--- @return string|nil effective_cwd 隔离环境内应使用的工作目录
function M.process_prefix(opts)
  opts = opts or {}
  local backend = M.backend()
  if not backend then
    return nil, "SANDBOX_BACKEND_UNAVAILABLE: 既无 bwrap 也无可用的 unshare/userns"
  end
  local cfg = config_store.get("tools.sandbox") or {}
  local offline = cfg.offline ~= false
  local priv = opts.privileges
  -- 独立 netns + 宿主网关模式：沙箱只能到达宿主网关（探测端口，服务被拦）。
  local net_gateway = require("NeoAI.sandbox.net_gateway")
  local gateway_mode = net_gateway.enabled()
  if gateway_mode and backend ~= "bwrap" then
    return nil, "GATEWAY_REQUIRES_BWRAP: 网络网关模式仅支持 bwrap 后端"
  end
  if gateway_mode then
    local ng, ngerr = net_gateway.ensure()
    if not ng then return nil, ngerr end
  end
  if backend == "bwrap" then
    local overlays = opts.overlays or {}
    local flags = M.bwrap_flags()
    -- 档位要求嵌套 userns（如 T2）：改用带 user namespace 的隔离标志，
    -- 使 cap_add 的权限被限制在该 userns 内，够不到宿主。
    if priv and priv.userns then flags = USER_FLAGS end
    -- 网关模式：网络命名空间由 `ip netns exec` 提供，bwrap 不得再 unshare net，
    -- 故使用不带 net 的隔离标志（--unshare-pid/ipc/uts/cgroup）。
    if gateway_mode then flags = NO_USER_FLAGS end
    local userns = false
    for _, f in ipairs(flags) do if f == "--unshare-all" then userns = true end end
    local argv = {}
    _append_bwrap_base(argv, flags, priv, opts.cwd)
    -- F2：临时根覆盖为「会话私有目录」（mode 1777，位于 /dev/shm 等 tmpfs 上），
    -- 覆盖基础参数里的空 tmpfs；绝不把宿主真实 /tmp、/var/tmp 作为 lower/内容暴露，
    -- 退出/轮换会话即销毁，杜绝跨会话残留泄露。
    _append_tmpfs_roots(argv, opts.session_tmp_dir)
    -- --new-session：新终端会话；--as-pid-1 已在基础参数中，使载荷成为 PID 1，
    -- 避免进程表出现 `bwrap --unshare-all ...` 这一沙箱指纹。
    table.insert(argv, "--new-session")
    -- 档位额外挂载（如受控 docker socket）：置于遮蔽之前，且对应路径在 unmask 中放开。
    if priv then
      for _, m in ipairs(priv.mounts or {}) do
        if m and m.src and m.dst then
          table.insert(argv, m.mode == "ro" and "--ro-bind" or "--bind")
          table.insert(argv, m.src)
          table.insert(argv, m.dst)
        end
      end
    end
    -- 多可写根：ext4 等支持 overlay 的根用 overlay（真实内容只读 lower，写入进 upper）；
    -- tmpfs 等不支持 overlay 的根退化为把会话私有目录 bind 到该根（可写、会话内持久）。
    local overlays_active = false
    for _, ov in ipairs(overlays) do
      local mode = ov.mode
      if not mode then
        mode = (M.overlay_available() and M.overlay_mountable(ov.root, ov.upper, ov.work))
          and "overlay" or "bind"
      end
      if mode == "overlay" then
        table.insert(argv, "--overlay-src"); table.insert(argv, ov.root)
        table.insert(argv, "--overlay"); table.insert(argv, ov.upper)
        table.insert(argv, ov.work); table.insert(argv, ov.root)
        overlays_active = true
      elseif ov.bind then
        table.insert(argv, "--bind"); table.insert(argv, ov.bind)
        table.insert(argv, ov.root)
        overlays_active = true
      end
    end
    -- 兼容：未提供 overlays 时按 cwd 单层 overlay
    if #overlays == 0 and opts.cwd then
      local overlay_ok = opts.upper and opts.work
        and M.overlay_available()
        and M.overlay_mountable(opts.cwd, opts.upper, opts.work)
      if overlay_ok then
        table.insert(argv, "--overlay-src"); table.insert(argv, opts.cwd)
        table.insert(argv, "--overlay"); table.insert(argv, opts.upper)
        table.insert(argv, opts.work); table.insert(argv, opts.cwd)
        overlays_active = true
      end
    end
    -- 会话级 shell 状态目录：把宿主会话目录 bind 到沙箱内固定路径，供 run_command
    -- 跨命令保存/载入 cwd 与导出变量（/tmp 可写或已被 overlay 覆盖，可建挂载点）。
    -- 挂载点使用无特征名（见 sandbox.conceal），不暴露沙箱自身。
    if opts.session_dir then
      table.insert(argv, "--bind"); table.insert(argv, opts.session_dir)
      table.insert(argv, require("NeoAI.sandbox.conceal").session_mount())
    end
    -- 遮蔽沙箱自身存储与宿主敏感路径：置于各可写根 overlay/bind 之后，确保覆盖生效。
    -- 目录用空 tmpfs；文件/socket 用 /dev/null 覆盖（socket 被替换为字符设备，connect 失败）。
    -- 档位 unmask 中的路径（如受控 docker socket）不遮蔽。
    for _, mp in ipairs(_masked_paths(priv and priv.unmask or nil, opts.cwd)) do
      if mp.kind == "dir" then
        table.insert(argv, "--tmpfs"); table.insert(argv, mp.path)
      else
        table.insert(argv, "--bind"); table.insert(argv, "/dev/null"); table.insert(argv, mp.path)
      end
    end
    -- 宿主运行时直通（opt-in）：置于遮蔽之后，允许显式暴露被遮蔽/临时根下的工具链。
    _append_expose_mounts(argv)
    -- 降级：无任何 overlay 生效时把私有可写目录 bind 到 cwd，保留隔离与只读 rootfs。
    if opts.cwd and not overlays_active and opts.fallback_cwd then
      table.insert(argv, "--bind"); table.insert(argv, opts.fallback_cwd)
      table.insert(argv, opts.cwd)
    end
    if opts.cwd then
      table.insert(argv, "--chdir")
      table.insert(argv, opts.cwd)
    end
    -- 网络：
    --   网关模式：网络由外部 netns 提供（仅可达宿主网关），此处不再处理 net 标志；
    --   档位显式指定时以档位为准（T0 默认放行网络，经 host_proxy 拦截本机；T1/T2 允许网络）；
    --   未指定档位时维持旧语义：带 userns 隔离 net 后按需 --share-net，否则 offline 才隔离。
    --   offline=true 为硬隔离，优先级高于档位（网络类工具与进程网络一律断开）。
    if not gateway_mode then
      local want_net
      if offline then want_net = false
      elseif priv then want_net = priv.network == true
      else want_net = true end
      if userns then
        if want_net then table.insert(argv, "--share-net") end
      elseif not want_net then
        table.insert(argv, "--unshare-net")
      end
    end
    -- 网关模式：在 bwrap 之前加 `ip netns exec <ns>`，把载荷放进隔离网络命名空间。
    if gateway_mode then
      local pre = net_gateway.exec_prefix()
      local full = {}
      for _, v in ipairs(pre) do full[#full + 1] = v end
      for _, v in ipairs(argv) do full[#full + 1] = v end
      argv = full
    end
    -- seccomp 基线：bwrap 在载荷 exec 前装载过滤器；用 shell 打开过滤器 fd 后 exec bwrap
    local seccomp = require("NeoAI.sandbox.seccomp")
    if seccomp.enabled() then
      local filter, ferr = seccomp.ensure_filter()
      if not filter then
        return nil, ferr or "SANDBOX_SECCOMP_UNAVAILABLE"
      end
      table.insert(argv, "--seccomp")
      table.insert(argv, "3")
      return _wrap_close_fds(argv, "exec 3<'" .. filter .. "'"), nil, opts.cwd
    end
    return _wrap_close_fds(argv), nil, opts.cwd
  end
  -- unshare 后端：无 overlay 支持，退化为空暂存 cwd（仍隔离 net/pid/ipc/uts/user）
  if require("NeoAI.sandbox.seccomp").enabled() then
    return nil, "SANDBOX_SECCOMP_UNAVAILABLE: unshare 后端不支持 seccomp 基线"
  end
  -- 档位提权（额外挂载 / 加回 capability）仅 bwrap 后端支持，不静默降级。
  if priv and ((priv.mounts and #priv.mounts > 0) or (priv.cap_add and #priv.cap_add > 0)) then
    return nil, "SANDBOX_PRIVILEGE_UNSUPPORTED: unshare 后端不支持档位挂载/capability"
  end
  -- 危险全局 sysctl 遮蔽（core_pattern/modprobe 等）需要 bind mount，仅 bwrap 后端支持。
  -- unshare 后端下 root 的 euid 仍是全局 root，DAC 会放行写入 → 必须 fail-closed，不静默降级。
  if #MANDATORY_PROC_MASKS > 0 then
    return nil, "SANDBOX_SYSCTL_MASK_UNAVAILABLE: unshare 后端无法遮蔽 /proc/sys（core_pattern/modprobe 等）"
  end
  local argv = { "unshare", "--user", "--map-root-user", "--mount", "--pid", "--fork",
    "--ipc", "--uts", "--mount-proc" }
  -- 网络：档位显式指定时以档位为准；否则仅 offline=true 时隔离 net。
  local want_net
  if priv then want_net = priv.network == true else want_net = not offline end
  if not want_net then
    table.insert(argv, "--net")
  end
  return _wrap_close_fds(argv), nil, (opts.fallback_cwd or opts.cwd)
end

--- 判断某 effect 是否可在当前环境隔离执行
--- @return boolean ok
--- @return string|nil err
function M.check_available()
  if require("NeoAI.sandbox.fault").hit("backend") then
    return false, "SANDBOX_BACKEND_UNAVAILABLE: injected"
  end
  local backend = M.backend()
  if not backend then
    return false, "SANDBOX_BACKEND_UNAVAILABLE: 既无 bwrap 也无可用的 unshare/userns"
  end
  local cfg = config_store.get("tools.sandbox") or {}
  if cfg.require_seccomp then
    local seccomp = require("NeoAI.sandbox.seccomp")
    if backend ~= "bwrap" then
      return false, "SANDBOX_SECCOMP_UNAVAILABLE: 仅 bwrap 后端支持 seccomp 基线"
    end
    if not seccomp.available() then
      return false, "SANDBOX_SECCOMP_UNAVAILABLE: 需要 seccomp 过滤器但未提供"
    end
  end
  return true
end

--- 运行外部进程（受隔离）
--- @param argv table 完整命令（未含前缀）
--- @param opts table { cwd?, timeout_ms?, signal?, network? }
--- @return Deferred resolve({ code, stdout, stderr })
function M.run(argv, opts)
  opts = opts or {}
  local prefix, err = M.process_prefix(opts)
  if not prefix then
    return async.reject({ kind = "sandbox", message = err })
  end
  -- 代理策略：清除宿主代理变量（默认），避免不可达代理导致命令失败。
  local unset = _proxy_unset_snippet()
  local run_argv = argv
  if unset then
    run_argv = { "sh", "-c", unset .. "\nexec \"$@\"", "sh" }
    for _, v in ipairs(argv) do run_argv[#run_argv + 1] = v end
  end
  local full = {}
  for _, v in ipairs(prefix) do full[#full + 1] = v end
  for _, v in ipairs(run_argv) do full[#full + 1] = v end

  local d = async.Deferred.new()
  local stdout, stderr = {}, {}
  local done = false
  local job
  local function settle(res)
    if done then return end
    done = true
    d:resolve(res)
  end
  if opts.signal then
    opts.signal:subscribe(function()
      if job then pcall(vim.fn.jobstop, job) end
      settle({ code = -1, stdout = table.concat(stdout, "\n"), stderr = table.concat(stderr, "\n"), aborted = true })
    end)
  end
  if opts.timeout_ms and opts.timeout_ms > 0 then
    vim.defer_fn(function()
      if done then return end
      if job then pcall(vim.fn.jobstop, job) end
      settle({ code = -1, stdout = table.concat(stdout, "\n"), stderr = table.concat(stderr, "\n"), timed_out = true })
    end, opts.timeout_ms)
  end
  job = vim.fn.jobstart(full, {
    cwd = opts.cwd,
    -- 环境变量脱敏 + 宿主运行时直通（统一经 sandbox_env 构造）。
    env = M.sandbox_env(opts.privileges),
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      for _, line in ipairs(data or {}) do stdout[#stdout + 1] = line end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data or {}) do stderr[#stderr + 1] = line end
    end,
    on_exit = function(_, code)
      settle({ code = code, stdout = table.concat(stdout, "\n"), stderr = table.concat(stderr, "\n") })
    end,
  })
  if job <= 0 then
    return async.reject({ kind = "sandbox", message = "无法启动隔离进程" })
  end
  return d
end

--- 重置（测试用）
function M.reset()
  state.caps = nil
  state.overlay_probe = {}
  state.empty_file = nil
  pcall(M.cleanup_tmp_roots)
end

return M
