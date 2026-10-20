--- 沙箱依赖诊断与用户可见话术
--- @module 'NeoAI.sandbox.execution.deps'
---
--- 纯文案 + 只读探测：不引用任何模块状态，**绝不 require** 其它沙箱模块
--- （`runtime.lua` 会 require 本模块，反向 require 会成环；能力数据一律由调用方传入）。
---
--- 目标：所有「依赖缺失」提示都写清三件事——**缺哪个依赖**、为什么需要它、怎么装；
--- 并在 Android/Termux 上明确说明内核禁止非特权 user namespace（装包也无法启用隔离）。
--- 本模块只产出正文，`[NeoAI]` 前缀与日志级别由调用方拼接。

local M = {}

--- 依赖（二进制名）→ 发行版包名，供安装提示使用
local PKG_NAME = {
  bwrap = "bubblewrap",
  unshare = "util-linux",
  setpriv = "util-linux",
  bpftrace = "bpftrace",
  strace = "strace",
}

--- 包管理器 → 安装命令模板（`%s` 为包名；`generic` 缺失时走兜底文案）
local PM_CMD = {
  pkg = "pkg install %s",
  apt = "sudo apt install -y %s",
  dnf = "sudo dnf install -y %s",
  pacman = "sudo pacman -S --needed %s",
  apk = "sudo apk add %s",
  zypper = "sudo zypper install -y %s",
}

--- 模块级缓存 + 测试钩子（override 非 nil 时优先于实测，置 nil 清除）
local state = {
  platform = nil, ---@type string|nil
  platform_override = nil, ---@type string|nil
  pkg_manager = nil, ---@type string|nil
  pkg_override = nil, ---@type string|nil
}

--- 当前平台判定：`termux` | `android` | `linux` | 其它 sysname 小写。
--- 判定依据与 `tools/builtin/web_fetch.lua` 的平台守卫同源：Termux 的 `$PREFIX` 指向
--- com.termux 应用目录；Android 用户空间存在 `/system/build.prop`（桌面 Linux 没有该文件）。
--- @return string
function M.platform()
  if state.platform_override ~= nil then return state.platform_override end
  if state.platform ~= nil then return state.platform end
  local p
  local ok, uname = pcall(function() return vim.uv.os_uname() end)
  if not ok or type(uname) ~= "table" then
    p = "other"
  elseif uname.sysname ~= "Linux" then
    p = tostring(uname.sysname or "other"):lower()
  else
    local prefix = type(vim.env.PREFIX) == "string" and vim.env.PREFIX or ""
    local ok_stat, st = pcall(vim.uv.fs_stat, "/system/build.prop")
    if prefix:find("com.termux", 1, true) then
      p = "termux"
    elseif ok_stat and st ~= nil then
      p = "android"
    else
      p = "linux"
    end
  end
  state.platform = p
  return p
end

--- 设置平台覆盖（测试钩子）：传字符串即视为该平台，传 nil 恢复实测并清缓存。
--- @param platform string|nil
function M.set_platform_override(platform)
  state.platform_override = platform
  state.platform = nil
  state.pkg_manager = nil
end

--- 是否 Android/Termux（内核禁止非特权 user namespace，沙箱隔离不成立）。
--- @return boolean
function M.is_mobile()
  local p = M.platform()
  return p == "termux" or p == "android"
end

--- 探测包管理器：`pkg`|`apt`|`dnf`|`pacman`|`apk`|`zypper`|`generic`。
--- 先读 `/etc/os-release` 的 `ID`/`ID_LIKE`，无法判定时按已安装的包管理器二进制兜底。
--- @return string
function M.pkg_manager()
  if state.pkg_override ~= nil then return state.pkg_override end
  if state.pkg_manager ~= nil then return state.pkg_manager end
  local pm
  if M.platform() == "termux" then
    pm = "pkg"
  else
    local id = ""
    local f = io.open("/etc/os-release", "r")
    if f then
      local content = f:read("*a") or ""
      f:close()
      local vals = {}
      for k, v in content:gmatch("([%w_]+)=\"?([^\n\"]*)") do vals[k] = v end
      id = ((vals.ID or "") .. " " .. (vals.ID_LIKE or "")):lower()
    end
    if id:find("debian", 1, true) or id:find("ubuntu", 1, true) then
      pm = "apt"
    elseif id:find("fedora", 1, true) or id:find("rhel", 1, true) or id:find("centos", 1, true) then
      pm = "dnf"
    elseif id:find("arch", 1, true) or id:find("manjaro", 1, true) then
      pm = "pacman"
    elseif id:find("alpine", 1, true) then
      pm = "apk"
    elseif id:find("suse", 1, true) then
      pm = "zypper"
    else
      pm = "generic"
      for _, cand in ipairs({ "apt", "dnf", "pacman", "apk", "pkg", "zypper" }) do
        if vim.fn.executable(cand) == 1 then
          pm = cand
          break
        end
      end
    end
  end
  state.pkg_manager = pm
  return pm
end

--- 设置包管理器覆盖（测试钩子）：传 nil 恢复实测并清缓存。
--- @param pm string|nil
function M.set_pkg_manager_override(pm)
  state.pkg_override = pm
  state.pkg_manager = nil
end

--- 依赖的安装提示（一句命令）。
--- Android/Termux 上额外说明：沙箱依赖（bwrap/unshare/userns）即使装上也无法启用隔离；
--- 观测依赖（bpftrace/strace）在该平台通常不可用（传 `opts.mobile_note = false` 使用该措辞）。
--- @param dep string 二进制名（bwrap/unshare/setpriv/bpftrace/strace）或包名
--- @param opts table|nil { mobile_note: boolean|nil }（默认 true：按沙箱隔离依赖措辞）
--- @return string
function M.install_hint(dep, opts)
  local name = PKG_NAME[tostring(dep or "")] or tostring(dep or "")
  if name == "" then return "" end
  local tmpl = PM_CMD[M.pkg_manager()] or "用发行版包管理器安装 %s"
  local cmd = tmpl:format(name)
  if M.is_mobile() then
    if opts and opts.mobile_note == false then
      return "安装：`" .. cmd .. "`——但该依赖在 Android/Termux 上通常不可用（内核与权限受限）。"
    end
    return "安装：`" .. cmd .. "`——但 Android/Termux 上即使安装成功也无法启用沙箱隔离："
      .. "内核禁止非特权 user namespace（`clone(CLONE_NEWUSER)` 被 SELinux 拒绝）。"
  end
  return "安装：" .. cmd
end

--- 生成「沙箱内核能力」报告（供 `:NeoAIDoctor` / `:checkhealth NeoAI` 渲染）。
--- 判定与 `runtime.backend()` 同源：有隔离后端 = `ok`，否则 `warn`
--- （不因「装了 unshare 二进制但内核拒绝非特权 userns」而误报可用）。
--- @param opts table|nil {
---   backend: "bwrap"|"unshare"|nil（隔离后端；nil = 无后端）
---   bwrap/unshare/userns/overlayfs/seccomp/cgroup2: boolean（能力实测结果）
---   setpriv: boolean|nil（unshare 后端能否经 setpriv 施加 seccomp；nil 视为未知/可用）
---   docker/podman: boolean|nil（容器运行时存在性，仅用于说明「不参与隔离后端」）
--- }
--- @return table { status = "ok"|"warn", lines = string[] }
function M.backend_report(opts)
  opts = opts or {}
  local backend = opts.backend
  local lines = {}
  local function add(line) lines[#lines + 1] = line end

  if backend == "bwrap" then
    add("隔离后端：bwrap（bubblewrap 包）可用——唯一支持 overlay 暂存层、档位挂载/capability"
      .. "与 /proc/sys 遮蔽的后端")
    if opts.overlayfs then
      add("overlay 可写层：可用（工具写入冻结为待审候选）")
    else
      add("overlay 可写层：不可用（降级为 bind + 播种；写入仍冻结为待审候选）")
    end
    if opts.seccomp == false then
      add("seccomp 基线：内核不支持（缺 /proc/sys/kernel/seccomp/actions_avail），"
        .. "将按三层行为模型降级留痕")
    else
      add("seccomp 基线：内核支持，经 bwrap 原生 --seccomp 施加")
    end
    if opts.cgroup2 then
      add("cgroup v2：可用（资源限额 + 取消/超时整树终止）")
    else
      add("cgroup v2：不可用（资源限额与整树终止失效，取消命令可能残留子进程）")
    end
  elseif backend == "unshare" then
    add("隔离后端：unshare（util-linux 包）+ 非特权 user namespace 可用")
    add("该后端无 overlay 可写层，也不支持档位挂载/capability 与 /proc/sys 遮蔽"
      .. "（这三项降级放行并留痕）；需要完整能力请安装 bwrap（bubblewrap）")
    if opts.seccomp == false then
      add("seccomp 基线：内核不支持（缺 /proc/sys/kernel/seccomp/actions_avail），"
        .. "将按三层行为模型降级留痕")
    elseif opts.setpriv == false then
      add("seccomp 基线：无法施加——缺 `setpriv --seccomp-filter`（util-linux ≥ 2.32 才提供），"
        .. "将按三层行为模型降级留痕（" .. M.install_hint("setpriv") .. "）")
    else
      add("seccomp 基线：经 `setpriv --no-new-privs --seccomp-filter` 施加")
    end
    if opts.cgroup2 == false then
      add("cgroup v2：不可用（资源限额与整树终止失效，取消命令可能残留子进程）")
    end
  else
    add("未找到可用的命名空间隔离后端（bwrap，或 unshare + 非特权 userns）")
    if opts.bwrap then
      add("bwrap 已安装但功能实测失败（真实启动一次隔离载荷未成功）：常见原因是宿主 / 的"
        .. "superblock 归属初始 userns（容器内）或非特权 userns 被内核禁用")
    else
      add("缺少 bwrap（bubblewrap 包）：没有它就无 overlay 暂存层、档位挂载/capability"
        .. " 与 /proc/sys 遮蔽。" .. M.install_hint("bwrap"))
    end
    if opts.unshare and opts.userns == false then
      add("unshare 已安装，但非特权 user namespace 被内核拒绝"
        .. "（`unshare --user --map-root-user true` 失败）：unshare 兜底后端不可用。"
        .. "需内核开启（/proc/sys/kernel/unprivileged_userns_clone=1）或改用 root + bwrap")
    elseif not opts.unshare then
      add("缺少 unshare（util-linux 包）：unshare 兜底后端不可用。" .. M.install_hint("unshare"))
    end
    if M.is_mobile() then
      add("Android/Termux：内核禁止非特权 user namespace"
        .. "（SELinux 拦截 clone(CLONE_NEWUSER)），安装任何包都无法启用沙箱隔离")
    end
    add("结果：沙箱禁用并退回审批模式——命令经事前审批（tools.approval.mode）后直接在宿主执行，"
      .. "写入直接落盘、不冻结待审候选")
    if opts.docker then
      add("注：已检测到 docker，但它不参与隔离后端（容器门面仅支持 podman），此处忽略")
    end
  end

  return { status = backend ~= nil and "ok" or "warn", lines = lines }
end

--- 把降级内部码翻成用户可读话术（保留原码，便于与 evidence / 日志对账）。
--- @param layer string 降级层："seccomp"|"privilege"|"sysctl_mask"|"backend"|其它
--- @param mode string|nil 后端（"bwrap"|"unshare"；历史实现亦写作 init，等价 bwrap）
--- @param reason string|nil 内部原因码
--- @param fallback string|nil 兜底方式（"ebpf"|"approval"|...）
--- @return string
function M.degrade_text(layer, mode, reason, fallback)
  layer = tostring(layer or "")
  reason = tostring(reason or "")
  local code = reason ~= "" and ("（原因码 " .. reason .. "）") or ""

  if layer == "seccomp" then
    local why
    if reason == "setpriv_unavailable" then
      why = "缺 `setpriv --seccomp-filter`（util-linux ≥ 2.32 才提供该参数），"
        .. "无法在 unshare 后端装载 seccomp 过滤器"
    elseif reason == "filter_unavailable" then
      why = "没有可用的 seccomp BPF 过滤器（内置 denylist 未生成，且未配置 "
        .. "tools.sandbox.seccomp.filter_path）"
    elseif reason ~= "" then
      why = reason
    else
      why = "seccomp 基线无法施加"
    end
    local tail
    if fallback == "ebpf" then
      tail = "已启用 eBPF 行为兜底（补救型：命中危险 syscall 即 cgroup.kill 整树终止并判失败，"
        .. "副作用可能已发生一次，不等价于发生前拦截）"
    else
      tail = "本次无行为强制层（仅强告警 + 审计）；如需恢复 fail-closed，可设 "
        .. "tools.sandbox.seccomp.on_unavailable=\"deny\""
    end
    local hint = (reason == "setpriv_unavailable") and ("。" .. M.install_hint("setpriv")) or ""
    return "seccomp 基线不可用——" .. why .. code .. "；" .. tail .. hint
  elseif layer == "privilege" then
    local what = (reason == "tier_cap_add") and "档位 capability（cap_add）"
      or "档位挂载（额外 bind/overlay）"
    return "unshare 后端不支持" .. what .. code
      .. "；仅 bwrap 后端可施加，已忽略并放行（载荷已是 userns 内 root，"
      .. "T0 所需的 CAP_DAC_OVERRIDE/SETUID/SETGID 等效具备）。" .. M.install_hint("bwrap")
  elseif layer == "sysctl_mask" then
    return "unshare 后端无法遮蔽 /proc/sys（core_pattern/modprobe 等需 bind mount）" .. code
      .. "；这些全局 sysctl 在本次命令内仍可被写入，已放行并留痕。" .. M.install_hint("bwrap")
  elseif layer == "backend" then
    return "无命名空间隔离后端（缺 bwrap，或 unshare 的非特权 userns 被内核拒绝）" .. code
      .. "；已退回审批模式（命令经事前审批后直接在宿主执行，写入直接落盘、不冻结待审候选）"
  end

  local parts = { "未分类的降级层 layer=" .. layer }
  if mode ~= nil and tostring(mode) ~= "" then parts[#parts + 1] = "mode=" .. tostring(mode) end
  if reason ~= "" then parts[#parts + 1] = "reason=" .. reason end
  if fallback ~= nil and tostring(fallback) ~= "" then
    parts[#parts + 1] = "fallback=" .. tostring(fallback)
  end
  return table.concat(parts, "，")
end

--- 清空探测缓存（测试用）。
function M.reset()
  state.platform = nil
  state.platform_override = nil
  state.pkg_manager = nil
  state.pkg_override = nil
end

return M
