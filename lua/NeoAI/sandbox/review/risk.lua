--- 沙箱安全级别评估与审批分级
--- @module 'NeoAI.sandbox.review.risk'
--- 把一次工具调用/外部命令的「事实」与「执行结果」映射为安全级别（L0-L3），并据此
--- 给出审批动作（auto / record / review / block）。集中落地：
---   * 审批按安全级别分级（写入保护已覆盖文件改动，进程提权仅记录供异常分析）；
---   * 通过命令执行结果判断安全级别；
---   * 仅在必要时才暂停 agent 向用户索要权限。
---
--- 级别：
---   L0 low      常规、可逆、工作区内（默认按配置动作，通常是 review）
---   L1 moderate 网络、包安装、T1 提权
---   L2 high     用户目录/系统路径写入、T2 特权、危险命令、**工作区内的密钥操作**
---   L3 critical **工作区外的密钥操作**、主机效果、破坏性命令
---
--- 说明：本模块只做「评估与建议」，不直接执行/发布；最终动作由 wrapper 结合
--- 任务授权、sandbox.mode、会话自动审批与包规则综合决定。

local config_store = require("NeoAI.kernel.config_store")
local fs = require("NeoAI.utils.fs")

local M = {}

-- ========== 常量 ==========

M.LEVEL = { LOW = 0, MODERATE = 1, HIGH = 2, CRITICAL = 3 }

local LEVEL_NAME = { [0] = "low", [1] = "moderate", [2] = "high", [3] = "critical" }
local LEVEL_BADGE = { [0] = "L0", [1] = "L1", [2] = "L2", [3] = "L3" }

--- 去重风险原因（保留首次出现顺序）。风险原因是「类别」而非逐文件计数：包安装会对每个
--- 工作区外写入路径重复追加 `SYSTEM_PATH_WRITE`（可达数千次），直接透传会撑爆待审展示、
--- AI 审计与后果警告文本。此处按类别去重，界面如需数量再自行合并计数。
--- @param list table|nil
--- @return table
local function _dedupe(list)
  local out, seen = {}, {}
  for _, r in ipairs(list or {}) do
    if type(r) == "string" and not seen[r] then
      seen[r] = true
      out[#out + 1] = r
    end
  end
  return out
end

-- 危险命令**文本形迹**（仅用于风险分级与提示文案，绝不用于拒绝执行）。
-- 匹配为 Lua pattern。核心不变量：安全边界只能由内核/运行时强制层提供（seccomp、capability、
-- 命名空间/设备隔离、cgroup.kill、网络门禁、人工审批）；字符串匹配判定的是命令「长什么样」，
-- 而非进程「做了什么」，实测双向失效（`echo 'curl x | sh'` 被误判、`| $SH` 与 `ba""sh` 漏判），
-- 故命中只提升 L 级并置 needs_confirm 强制人工复核，不产生 DENY。详见 docs/sandbox.md 核心不变量 6。
-- 仅覆盖**绕过文件暂存层**的破坏形态（写块设备、mkfs、wipefs 等）与间接执行形迹。
local ADVISORY_PATTERNS = {
  { level = 3, name = "DESTRUCTIVE", pats = {
    "mkfs", "dd%s+[^\n]*of=/dev/", ">%s*/dev/sd", ">%s*/dev/nvme",
    "shred%s", "wipefs", "blkdiscard", "of=/dev/",
  } },
  { level = 3, name = "FORK_BOMB", pats = {
    ":%(%)%s*{%s*:%s*|%s*:%s*&%s*}",
    "while%s+true%s+do%s+.*fork",
    "perl%s+%-e%s+['\"]?fork",
  } },
  { level = 3, name = "PIPE_TO_SHELL", pats = {
    "curl[^\n]-|%s*[%w/]*sh", "wget[^\n]-|%s*[%w/]*sh", "|%s*sh%s*$", "|%s*bash%s*$",
  } },
  { level = 2, name = "PERMISSION_WIDE", pats = {
    "chmod%s+%-[%w]*R[%w]*%s+777", "chmod%s+777%s+/", "chown%s+%-R", "chmod%s+%-R%s+777",
  } },
  { level = 2, name = "HOST_CONTROL", pats = {
    "systemctl", "iptables", "nft%s", "insmod", "modprobe", "mount%s+%-",
    "mkfs", "swapoff", "swapon",
  } },
}

-- 本机 SSH 服务目标（禁止访问）：回环、链路本地、通配地址、localhost。
local SSH_LOCAL_TARGETS = { "localhost", "127.", "::1", "[::1]", "0.0.0.0", "169.254." }

--- 命令是否试图访问**本机 SSH 服务**（ssh/scp/sftp/sshpass 或 `ssh://` 指向本机）。
--- 供 wrapper 硬拒绝：在「agent socket 遮蔽 + SSH_AUTH_SOCK 环境清除」之外，直接禁止
--- 沙箱内命令连接宿主 sshd（共享 netns 下裸 TCP 不经代理，需命令级闸门）。
--- @param command string|nil
--- @return boolean denied
--- @return string|nil target
function M.ssh_local_target(command)
  if type(command) ~= "string" or command == "" then return false end
  local lower = command:lower()
  local has_ssh = lower:find("%f[%w]ssh%f[%W]") ~= nil
    or lower:find("%f[%w]scp%f[%W]") ~= nil
    or lower:find("%f[%w]sftp%f[%W]") ~= nil
    or lower:find("sshpass", 1, true) ~= nil
    or lower:find("ssh://", 1, true) ~= nil
  if not has_ssh then return false end
  for _, t in ipairs(SSH_LOCAL_TARGETS) do
    if lower:find(t, 1, true) then return true, t end
  end
  return false
end

-- ========== 危险设备访问检测 ==========

--- glob（`*` 通配）匹配：把模式转为 Lua pattern 后整串匹配。
--- @param pat string
--- @param path string
--- @return boolean
local function _glob_match(pat, path)
  if type(pat) ~= "string" or pat == "" then return false end
  if pat == path then return true end
  local out = {}
  for i = 1, #pat do
    local c = pat:sub(i, i)
    if c == "*" then
      out[#out + 1] = ".*"
    elseif c:match("[%^%$%(%)%%%.%[%]%+%-%?]") then
      out[#out + 1] = "%" .. c
    else
      out[#out + 1] = c
    end
  end
  return path:match("^" .. table.concat(out) .. "$") ~= nil
end

--- 危险设备访问检测：命令文本中引用的、命中 `tools.sandbox.devices.paths` 的设备节点。
--- 覆盖 `>` 重定向、`of=/dev/...`、shell 引号与行继续拼接；返回**具体**设备路径（去重）。
--- 无害设备（/dev/null、/dev/urandom 等）不在默认模式列表，永不命中。
--- @param command string|nil 有效命令文本（含脚本折叠后的 `effective`）
--- @return table matched 具体设备路径数组（去重；未命中/关闭时为空）
function M.device_access(command)
  if type(command) ~= "string" or command == "" then return {} end
  local dev = (config_store.get("tools.sandbox") or {}).devices or {}
  if dev.enabled == false then return {} end
  local pats = dev.paths
  if type(pats) ~= "table" or #pats == 0 then return {} end
  -- 去掉引号与行继续拼接，使 `of="/dev/net/tun"`、`> /dev/kvm` 等一并还原为可匹配 token。
  local text = command:gsub("\\\n", " "):gsub("\\\r\n", " "):gsub("['\"]", "")
  local matched, seen = {}, {}
  for tok in text:gmatch("/dev/[%w%._%-/]*") do
    if not seen[tok] then
      for _, p in ipairs(pats) do
        if _glob_match(p, tok) then
          seen[tok] = true
          matched[#matched + 1] = tok
          break
        end
      end
    end
  end
  return matched
end

--- 单个**具体**路径是否命中危险设备模式（供运行期观测按实际路径判定）。
--- @param path string|nil
--- @return string|nil matched 命中时返回该路径
function M.device_path_match(path)
  if type(path) ~= "string" or path == "" then return nil end
  local dev = (config_store.get("tools.sandbox") or {}).devices or {}
  if dev.enabled == false then return nil end
  local pats = dev.paths
  if type(pats) ~= "table" then return nil end
  for _, p in ipairs(pats) do
    if _glob_match(p, path) then return path end
  end
  return nil
end

-- 执行结果 → 安全级别提示（失败模式）。命中取最高。
local RESULT_PATTERNS = {
  { level = 2, name = "PERMISSION_DENIED", pats = {
    "operation not permitted", "permission denied", "must be root", "are you root",
    "requires root", "requires cap_", "you need to be root", "read-only file system",
  } },
  { level = 1, name = "NETWORK_ATTEMPT", pats = {
    "could not resolve host", "temporary failure in name resolution", "network is unreachable",
    "connection refused", "connection timed out", "no route to host", "couldn't connect to server",
    "cannot connect to the docker daemon", "is the docker daemon running",
  } },
  { level = 1, name = "PACKAGE_CHANGED", pats = {
    "setting up ", "successfully installed", "successfully built", "added %d+ package",
    "installed %d+ package", "updated %d+ package",
  } },
  { level = 3, name = "DESTRUCTIVE_OUTPUT", pats = {
    "no space left on device", "input/output error", "structure needs cleaning",
  } },
}

-- ========== 私有函数 ==========

local function _cfg()
  return config_store.get("tools.sandbox") or {}
end

--- 审批配置
local function _approval_cfg()
  return _cfg().approval or {}
end

--- 规范化绝对路径（去尾斜杠）
--- @param p string
--- @return string
local function _norm(p)
  return fs.canonical(p)
end

local function _under(path, base)
  if base == "" then return false end
  return path == base or path:sub(1, #base + 1) == base .. "/"
end

--- cwd/home 的规范化结果缓存：`path_level` 对每个候选路径都要判定是否在工作区内，
--- 若每次都 `_norm(vim.fn.getcwd())` + `_norm(vim.fn.expand("~"))`（各含 fnamemodify/
--- expand/resolve/gsub 数次 Vimscript 往返），暂存上万文件时是结算主线程的主要卡顿源。
--- 以原始 cwd 字符串为键，cwd 变化（`:cd`/`lcd`）时自动重算。
local _loc_cache = { cwd_key = nil, cwd = nil, home = nil }

--- @return string cwd 规范化绝对路径
--- @return string home 规范化绝对路径
local function _locations()
  local cwd_raw = vim.fn.getcwd()
  if _loc_cache.cwd_key ~= cwd_raw then
    _loc_cache.cwd_key = cwd_raw
    _loc_cache.cwd = _norm(cwd_raw)
    _loc_cache.home = _norm(vim.fn.expand("~"))
  end
  return _loc_cache.cwd, _loc_cache.home
end

--- 路径所属级别：workspace=0 / user=1 / system=2
--- @param path string
--- @return number
function M.path_level(path)
  if type(path) ~= "string" or path == "" then return 2 end
  local abs = _norm(path)
  local cwd, home = _locations()
  if _under(abs, cwd) then return 0 end
  if home ~= "" and _under(abs, home) then return 1 end
  return 2
end

--- 级别名称
--- @param level number
--- @return string
function M.level_name(level)
  return LEVEL_NAME[level] or "low"
end

--- 级别徽标
--- @param level number|nil
--- @return string
function M.badge(level)
  return LEVEL_BADGE[level] or "L0"
end

--- 匹配危险命令的**文本形迹**，返回最高命中级别与原因（advisory：只用于分级，不用于拒绝）
--- @param text string|nil
--- @return number level
--- @return table reasons
local function _dangerous(text)
  local level, reasons = 0, {}
  if type(text) ~= "string" or text == "" then return level, reasons end
  local lower = text:lower()
  for _, rule in ipairs(ADVISORY_PATTERNS) do
    for _, p in ipairs(rule.pats) do
      if lower:find(p) then
        if rule.level > level then level = rule.level end
        reasons[#reasons + 1] = rule.name
        break
      end
    end
  end
  return level, reasons
end

-- ========== 公开 API ==========

--- 评估一次调用/候选的安全级别
--- @param facts table {
---   effect?, paths? (写路径数组), privilege_tier?, package?, network?,
---   secret?, host_op?, command?, command_effective?, script_opaque?, tool?
--- }
--- @return table { level, name, badge, reasons = table }
function M.classify(facts)
  facts = facts or {}
  local level, reasons = 0, {}
  local function bump(l, reason)
    if l and l > level then level = l end
    if reason then reasons[#reasons + 1] = reason end
  end
  -- 写入路径级别（单遍：同时记录是否存在工作区外写入，供密钥操作分级复用，
  -- 避免对 `facts.paths` 二次遍历 + 二次 path_level 规范化）
  -- `facts.path_levels`（path -> level）由包候选分类工作线程预计算：有则直接用，
  -- 免主线程对每个路径 `fs.canonical`。
  local levels = facts.path_levels
  local outside = false
  for _, p in ipairs(facts.paths or {}) do
    local pl = (levels and levels[p]) or M.path_level(p)
    if pl > 0 then
      outside = true
      bump(pl, pl == 1 and "USER_PATH_WRITE" or "SYSTEM_PATH_WRITE")
    end
  end
  if facts.network then bump(M.LEVEL.MODERATE, "NETWORK_ACCESS") end
  if facts.package then bump(M.LEVEL.MODERATE, "PACKAGE_INSTALL") end
  -- 间接执行（脚本/解释器）无法静态解析：提升级别并（由 wrapper）强制复核。
  if facts.script_opaque then bump(M.LEVEL.MODERATE, "OPAQUE_SCRIPT_EXECUTION") end
  if facts.privilege_tier and facts.privilege_tier >= 1 then
    bump(facts.privilege_tier >= 2 and M.LEVEL.HIGH or M.LEVEL.MODERATE,
      facts.privilege_tier >= 2 and "PRIVILEGE_T2" or "PRIVILEGE_T1")
  end
  if facts.host_op then bump(M.LEVEL.CRITICAL, "HOST_OPERATION") end
  if facts.secret then
    -- 密钥操作按作用域分级：工作区内 L2（HIGH），工作区外（用户目录/系统路径）L3（CRITICAL）。
    if outside then
      bump(M.LEVEL.CRITICAL, "SECRET_OPERATION_OUTSIDE_WORKSPACE")
    else
      bump(M.LEVEL.HIGH, "SECRET_OPERATION")
    end
  end
  -- command_effective 折叠了脚本间接执行的内容（见 sandbox/script_scan），优先使用。
  local dlevel, dreasons = _dangerous(facts.command_effective or facts.command)
  if dlevel > level then level = dlevel end
  for _, r in ipairs(dreasons) do reasons[#reasons + 1] = r end
  -- 包安装（apt/pip/npm 等）属高危但非 critical：其状态文件位于工作区外、且常含高熵签名/
  -- 哈希，不因「工作区外写入/密钥误报」升到 L3；仅当命令本身命中破坏性模式时才保留 L3。
  if facts.package and level >= M.LEVEL.CRITICAL and dlevel < M.LEVEL.CRITICAL then
    level = M.LEVEL.HIGH
  end
  -- 放宽风险提示：**安全安装**（未改动第三方软件源/密钥）不因写入 /usr /var /etc 等系统路径
  -- 升到 L2（封顶中危）；敏感安装（`package_sensitive`）保留系统路径写入的高危评级。
  if facts.package and not facts.package_sensitive
    and dlevel < M.LEVEL.CRITICAL and level > M.LEVEL.MODERATE then
    level = M.LEVEL.MODERATE
  end
  return { level = level, name = M.level_name(level), badge = M.badge(level), reasons = _dedupe(reasons) }
end

--- 命令文本命中的最高危险级别（供包安装降级判定）
--- @param command string|nil
--- @return number
function M.dangerous_level(command)
  local l = _dangerous(command)
  return l
end

-- ========== 内核/危险命令硬拒绝 ==========

-- 内核/系统管理类命令的**名字形迹**（advisory：只提升风险并要求人工复核，不拒绝执行）。
-- 已删除原 DENY_BINS / CAP_GATED_BINS 名字黑名单：其中每个二进制所需的危险 syscall
-- （init_module/finit_module/delete_module/reboot/kexec_load/bpf/perf_event_open/swapon…）
-- 都已被 seccomp 基线拦截，名字表拦不住任何 seccomp 拦不住的东西，只产出 `kmod --help`
-- 这类误报；而 iptables/nft 的真实约束是 CAP_NET_ADMIN——busybox 软链可绕过名字，却绕不过
-- EPERM。故「危险」以**能力事实**（所需被剥夺的 syscall/capability）定义，不以名字定义。
-- 本表只用于：给出提示文案、把级别抬到 HIGH/CRITICAL 以触发强制人工复核。
-- 注意：`mount`/`umount` 属 T2 主机操作（冻结为提案、审批后 sudo），`mknod`/`unshare` 等由
-- seccomp 基线与命名空间隔离处理，故不在此表（避免与既有分层防护重复）。
local KERNEL_TRACE_BINS = {
  modprobe = true, insmod = true, rmmod = true, kmod = true, modinfo = true,
  sysctl = true, kexec = true, reboot = true, shutdown = true, poweroff = true,
  halt = true, sysrq = true, bpf = true, perf = true, setcap = true,
  swapon = true, swapoff = true,
}

-- 需要特定 Linux 能力才可能生效的「底层网络/防火墙」命令（同样只是 advisory 形迹）：
-- 真实约束是 capability，沙箱基线 `--cap-drop ALL` 默认不授予，故内核会以 EPERM 拒绝。
local CAP_TRACE_BINS = {
  iptables = "CAP_NET_ADMIN", ip6tables = "CAP_NET_ADMIN",
  nft = "CAP_NET_ADMIN", arptables = "CAP_NET_ADMIN", ebtables = "CAP_NET_ADMIN",
}

-- 命令包装器/解释器：段首为它们时，向下扫描段内所有 token 寻找真实命令首词。
-- 含 shell 关键字（then/do/…）与 xargs：脚本正文/复合命令里危险命令常出现在这些位置
-- （`if …; then modprobe x; fi`、`… | xargs modprobe`），不扫描会漏判。
local WRAPPERS = {
  sudo = true, doas = true, env = true, nohup = true, nice = true, ionice = true,
  stdbuf = true, setsid = true, timeout = true, command = true, exec = true,
  bash = true, sh = true, dash = true, zsh = true, ksh = true, fish = true,
  xargs = true,
  ["then"] = true, ["do"] = true, ["else"] = true, ["elif"] = true, ["if"] = true,
  ["while"] = true, ["until"] = true, ["done"] = true, ["fi"] = true, time = true,
}

--- 危险命令**形迹**评估（advisory：只用于分级与人工复核提示，**绝不用于拒绝执行**）。
--- 命中返回形迹原因码与建议级别，未命中返回 nil。
--- 真实拦截由内核/运行时强制层承担：命中项所需的危险 syscall 已由 seccomp 基线拦截
--- （init_module/finit_module/delete_module/reboot/kexec_load/bpf/perf_event_open/swapon…），
--- 网络管理类由 CAP_NET_ADMIN 缺失导致 EPERM，设备写入由设备门禁 + `--dev` 最小 devtmpfs 约束，
--- 间接执行链由 exec 调用链守卫按真实 execve 归因。详见 docs/sandbox.md「核心不变量 6」。
--- @param command string|nil 命令文本（可含脚本折叠后的 effective 文本）
--- @param opts table|nil { caps? = table<string, boolean> 已授予能力集合；用于提示「能力已授予」而非放行 }
--- @return table|nil { reasons = table<string>, level = number, bins = table<string> }
function M.advisory(command, opts)
  if type(command) ~= "string" or command == "" then return nil end
  opts = opts or {}
  local caps = opts.caps or {}
  local reasons, bins = {}, {}
  local level = 0

  -- 破坏性 / 管道执行 / fork 炸弹等形迹
  local dlevel, dreasons = _dangerous(command)
  if dlevel > 0 then
    level = dlevel
    for _, r in ipairs(dreasons) do reasons[#reasons + 1] = "DESTRUCTIVE:" .. r end
  end

  -- 名字形迹：仅用于提示与抬级；能力已授予时不再作为「缺失能力」提示。
  local function _mark(base)
    if KERNEL_TRACE_BINS[base] then
      reasons[#reasons + 1] = "KERNEL_TRACE:" .. base
      bins[#bins + 1] = base
      if level < M.LEVEL.HIGH then level = M.LEVEL.HIGH end
    end
    local cap = CAP_TRACE_BINS[base]
    if cap then
      if not caps[cap] then
        reasons[#reasons + 1] = "CAPABILITY_MISSING:" .. base .. ":" .. cap
        if level < M.LEVEL.HIGH then level = M.LEVEL.HIGH end
      else
        reasons[#reasons + 1] = "CAPABILITY_GRANTED:" .. base .. ":" .. cap
      end
      bins[#bins + 1] = base
    end
  end
  local function _base(tok)
    tok = tok:gsub("^['\"]+", ""):gsub("['\"]+$", "")
    return tok:match("[^/]+$") or tok
  end
  for seg in command:gmatch("[^;|&\n]+") do
    local toks = {}
    for t in seg:gmatch("%S+") do toks[#toks + 1] = t end
    if #toks > 0 then
      local first = _base(toks[1])
      if WRAPPERS[first] then
        for _, t in ipairs(toks) do _mark(_base(t)) end
      else
        _mark(first)
      end
    end
  end

  if #reasons == 0 then return nil end
  return { reasons = reasons, level = level, bins = bins }
end

--- 兼容 shim：默认**恒定返回 nil**（不再拒绝任何命令）。
---
--- 安全边界由内核/运行时强制层提供（docs/sandbox.md 核心不变量 6）。保留本函数名是为了让
--- 历史调用点与外部集成在升级后不会语义反转；需要形迹信息请改用 `M.advisory`。
---
--- **应急回滚**：`tools.sandbox.risk.text_guard="enforce"` 可恢复旧的文本硬拒绝波形，
--- 但它**不可靠、不是安全边界**（判定命令「长什么样」而非进程「做了什么」），仅供排查
--- 兼容问题时短时使用；默认 `"advisory"` 下本函数永远返回 nil。
--- @param command string|nil
--- @param opts table|nil
--- @return string|nil reason 仅当 text_guard="enforce" 时可能返回形迹原因
function M.deny_reason(command, opts)
  local mode
  pcall(function()
    mode = (require("NeoAI.kernel.config_store").get("tools.sandbox.risk") or {}).text_guard
  end)
  if mode ~= "enforce" then return nil end
  -- 应急路径：按旧语义返回形迹原因（调用方据此拒绝）。
  local adv = M.advisory(command, opts)
  if not adv then return nil end
  local reasons = {}
  for _, r in ipairs(adv.reasons) do
    -- 兼容旧返回格式："DESTRUCTIVE:<names>" / "KERNEL_COMMAND:<bin>" / "CAPABILITY_REQUIRED:<bin>:<cap>"
    local kernel = r:match("^KERNEL_TRACE:(.+)$")
    if kernel then
      reasons[#reasons + 1] = "KERNEL_COMMAND:" .. kernel
    else
      local capbin, cap = r:match("^CAPABILITY_MISSING:(.-):(CAP_%w+)$")
      if capbin then
        reasons[#reasons + 1] = "CAPABILITY_REQUIRED:" .. capbin .. ":" .. cap
      elseif not r:match("^CAPABILITY_GRANTED:") then
        reasons[#reasons + 1] = r
      end
    end
  end
  if #reasons == 0 then return nil end
  return table.concat(reasons, ",")
end

--- 代理规避判定：显式清除/绕过 HTTP(S)_PROXY/ALL_PROXY 的命令。
--- host_local_block 依赖代理变量生效；`unset *proxy`、`env -u *proxy`、`curl --noproxy`、
--- `--proxy ""` 等会使其失效而直连宿主本机。仅覆盖**显式**规避；不认代理的裸 TCP
--- （nc/ssh/自建 socket）无法由此覆盖，属已知应用层边界（见 docs/sandbox.md）。
---
--- 规范化：shell 会做引号拼接与 ANSI-C 引用（`--noprox''y`、`$'--noproxy'`），静态扫描须
--- 还原为实际 token，否则可用拼接绕过。另收集简单变量赋值（`c=--noproxy`）以展开 `$c`。
--- 短选项 `-x` 是 curl 的 `--proxy`，但在 `set -x`/`tar -x`/`grep -x`/`bash -x` 中是常见
--- 无关开关，故仅在 curl 段上按代理选项判定，避免误报硬拒绝。
--- @param command string|nil 折叠后的有效命令文本
--- @return string|nil reason 如 "PROXY_EVASION:unset"
function M.network_evasion_reason(command)
  if type(command) ~= "string" or command == "" then return nil end
  -- 还原 shell 引号拼接 / ANSI-C 引用 / 反斜杠转义（仅用于匹配，不改变实际命令）。
  local function _norm_tok(tok)
    local s = tostring(tok)
    s = s:gsub("%$'", ""):gsub('%$"', "")
    s = s:gsub("['\"]", ""):gsub("\\", "")
    return s
  end
  -- 收集 `NAME=value`（含行首/分号后），用于展开 `$NAME`/`${NAME}`，防止变量间接绕过。
  local vars = {}
  for name, val in command:gmatch("([%a_][%w_]*)%=([^%s;|&]+)") do
    vars[name] = _norm_tok(val)
  end
  local function _expand(tok)
    local s = _norm_tok(tok)
    s = s:gsub("%${([%a_][%w_]*)}", function(n) return vars[n] or "" end)
    s = s:gsub("%$([%a_][%w_]*)", function(n) return vars[n] or "" end)
    return s
  end
  local function _is_proxy_var(tok)
    return _expand(tok):lower():match("^[%a_]*proxy$") ~= nil
  end
  for seg in command:gmatch("[^;|&\n]+") do
    local toks = {}
    for t in seg:gmatch("%S+") do toks[#toks + 1] = t end
    if #toks > 0 then
      local f0 = _expand(toks[1])
      local first = (f0:match("[^/]+$") or f0):lower()
      -- `-x` 仅在 curl 上等同 `--proxy`；其它命令（set/tar/grep/bash…）的 `-x` 无关代理。
      local short_x_proxy = first == "curl" or first:match("^curl") ~= nil
      if first == "unset" then
        for i = 2, #toks do
          if _is_proxy_var(toks[i]) then return "PROXY_EVASION:unset" end
        end
      elseif first == "env" then
        for i = 2, #toks do
          local t = _expand(toks[i])
          if (t == "-u" or t == "--unset") and _is_proxy_var(toks[i + 1]) then
            return "PROXY_EVASION:env-unset"
          elseif t:match("^%-%-unset=") and _is_proxy_var(t:sub(9)) then
            return "PROXY_EVASION:env-unset"
          end
        end
      elseif first == "export" then
        for i = 2, #toks do
          local name = _expand(toks[i]):match("^([%a_]+)=$")
          if name and _is_proxy_var(name) then return "PROXY_EVASION:export-clear" end
        end
      end
      for i = 1, #toks do
        local t = _expand(toks[i])
        if t == "--noproxy" or t == "--no-proxy"
          or t:match("^%-%-noproxy=") or t:match("^%-%-no%-proxy=") then
          return "PROXY_EVASION:noproxy"
        end
        if t == "--proxy" or (short_x_proxy and t == "-x") then
          -- 仅把「字面空值」或「已知被赋空值的变量」视为清空代理；未展开的 `$var` 不误判
          -- （可能是合法代理变量）。
          local raw = toks[i + 1]
          local empty = raw == nil or _norm_tok(raw) == ""
          if not empty and raw then
            local name = _norm_tok(raw):match("^%$?{?([%a_][%w_]*)%}?$")
            if name and vars[name] == "" then empty = true end
          end
          if empty then return "PROXY_EVASION:proxy-empty" end
        elseif t:match("^%-%-proxy=") or (short_x_proxy and t:match("^%-x=")) then
          local v = t:gsub("^%-%-proxy=", ""):gsub("^%-x=", "")
          if v == "" then return "PROXY_EVASION:proxy-empty" end
        end
      end
    end
  end
  return nil
end

--- 结果扫描窗口上限（字节）：`from_result` 仅扫描输出首/尾各 N 字节，避免无上限输出
--- （`timeout=-1` 的 run_command 可达数百 MB）在主线程做全量 lower + 模式匹配而冻结界面。
--- 风险信号（权限不足/网络/包变更/破坏性输出）通常出现在输出开头或结尾。0 = 不限制。
--- @return number
local function _result_scan_bytes()
  local n = tonumber(config_store.get("tools.sandbox.risk.result_scan_bytes"))
  if n == nil then return 262144 end
  return n
end

--- 依据命令执行结果判断安全级别（失败/网络/包变更等信号）
--- @param result table|nil { code, stdout, stderr }
--- @param base table|nil classify() 结果（取较大者）
--- @return table { level, name, badge, reasons, signals }
function M.from_result(result, base)
  local level = base and base.level or 0
  local reasons = {}
  for _, r in ipairs(base and base.reasons or {}) do reasons[#reasons + 1] = r end
  local signals = {}
  if type(result) == "table" then
    local cap = _result_scan_bytes()
    local function window(s)
      s = tostring(s or "")
      if cap <= 0 or #s <= cap * 2 then return s end
      -- 保留首尾：中间截断（信号多在首尾），显著降低大输出的主线程扫描成本。
      return s:sub(1, cap) .. "\n…\n" .. s:sub(-cap)
    end
    local text = (window(result.stdout) .. "\n" .. window(result.stderr)):lower()
    for _, rule in ipairs(RESULT_PATTERNS) do
      for _, p in ipairs(rule.pats) do
        if text:find(p) then
          if rule.level > level then level = rule.level end
          reasons[#reasons + 1] = rule.name
          signals[#signals + 1] = rule.name
          break
        end
      end
    end
  end
  return { level = level, name = M.level_name(level), badge = M.badge(level), reasons = _dedupe(reasons), signals = signals }
end

--- 依据级别给出建议审批动作
--- @param level number
--- @param opts table|nil { session_auto?, package?, package_sensitive?, secret? }
--- @return string "auto" | "record" | "review" | "block"
function M.action(level, opts)
  opts = opts or {}
  -- 密钥永不因会话自动审批而跳过（需显式确认/规则）。
  if opts.secret then return "review" end
  if opts.package then
    -- 包安装始终需人工确认（不自动落盘）；packages.mode 可整体放行/拒绝。
    local pkg = _cfg().packages or {}
    local mode = pkg.mode or "review"
    if mode == "allow" then return "auto" end
    if mode == "deny" then return "block" end
    return "review"
  end
  local cfg = _approval_cfg()
  local levels = cfg.levels or {}
  local override = levels[level] or levels[tostring(level)]
  if type(override) == "string" and override ~= "" then return override end
  -- 会话自动审批（默认关闭）：仅对 L0/L1 自动放行，L2+ 仍需确认。
  if opts.session_auto and level <= M.LEVEL.MODERATE then
    return "auto"
  end
  return cfg.default or "review"
end

--- 记录一次安全级别评估（证据 + 事件，可选审计）
--- @param meta table { tool?, command_id?, attempt_id?, level, reasons, signals?, source? }
function M.record(meta)
  meta = meta or {}
  if meta.level == nil then return end
  pcall(function()
    require("NeoAI.sandbox.review.evidence").add("risk", {
      level = meta.level, name = M.level_name(meta.level),
      reasons = meta.reasons or {}, signals = meta.signals or {},
      tool = meta.tool, source = meta.source or "observed", coverage = "full",
    }, { tool = meta.tool, command_id = meta.command_id, attempt_id = meta.attempt_id })
  end)
  pcall(function()
    require("NeoAI.kernel.event_bus").emit(require("NeoAI.kernel.events").SANDBOX_RISK_ASSESSED, {
      level = meta.level, name = M.level_name(meta.level),
      reasons = meta.reasons, signals = meta.signals,
      tool = meta.tool, command_id = meta.command_id,
    })
  end)
end

--- 重置（测试用）：无模块级状态
function M.reset() end

return M
