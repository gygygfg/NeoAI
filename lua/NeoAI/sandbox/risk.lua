--- 沙箱安全级别评估与审批分级
--- @module NeoAI.sandbox.risk
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

-- 危险命令模式（依据命令文本初判级别）。匹配为 Lua pattern。
-- 仅覆盖**绕过文件暂存层**的破坏（写块设备、mkfs、wipefs 等）：`rm`/`rm -rf` 等纯文件
-- 修改由「只读根 + overlay 修改暂存」保护宿主机，不在此硬拦截（其效果冻结为候选待审）。
local DANGEROUS = {
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
--- @param level number
--- @return string
function M.badge(level)
  return LEVEL_BADGE[level] or "L0"
end

--- 匹配危险命令模式，返回最高命中级别与原因
--- @param text string
--- @return number level
--- @return table reasons
local function _dangerous(text)
  local level, reasons = 0, {}
  if type(text) ~= "string" or text == "" then return level, reasons end
  local lower = text:lower()
  for _, rule in ipairs(DANGEROUS) do
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

-- 内核/系统管理命令（首词命中即硬拒绝，不执行）。普通命令不受影响，仍可在沙箱内执行。
-- 注意：`mount`/`umount` 属 T2 主机操作（冻结为提案、审批后 sudo），`mknod`/`unshare` 等由
-- seccomp 基线与命名空间隔离处理，故不在此列表（避免绕过既有的分层防护）。
local DENY_BINS = {
  -- 内核模块与内核状态
  modprobe = true, insmod = true, rmmod = true, kmod = true, modinfo = true,
  sysctl = true, kexec = true, reboot = true, shutdown = true, poweroff = true,
  halt = true, sysrq = true, bpf = true, perf = true,
  -- 文件能力（可提权）
  setcap = true,
  -- 内核交换区
  swapon = true, swapoff = true,
}

-- 需要特定 Linux 能力才能生效的「底层网络/防火墙」命令：**按能力判定**而非按命令名一刀切。
-- 沙箱基线（--cap-drop ALL + 窄 cap_add）默认不授予这些能力，故默认仍拒绝；但若调用方
-- 显式授予所需能力（tools.sandbox.privilege.tiers[*].cap_add 或全局 cap_add），则放行，
-- 使 `iptables` 等不再因「命令名」被无条件否决。opts.caps 为已授予能力集合（见
-- privilege.effective_caps）；注意 `ALL` 不解除全局 cap_drop，故不视为授予被全局丢弃的能力。
local CAP_GATED_BINS = {
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

--- 内核/破坏性命令硬拒绝判定：命中返回原因（不执行），否则 nil。
--- 普通命令（含 python/node/go/rust/apt/pip/npm 等）不命中，仍可在沙箱内执行。
--- @param command string|nil
--- @param opts table|nil { caps? = table<string, boolean> 已授予能力集合；缺省视为空（fail-closed） }
--- @return string|nil reason 如 "KERNEL_COMMAND:modprobe" / "CAPABILITY_REQUIRED:iptables:CAP_NET_ADMIN"
function M.deny_reason(command, opts)
  if type(command) ~= "string" or command == "" then return nil end
  opts = opts or {}
  local caps = opts.caps or {}
  -- 破坏性 / 管道执行 / fork 炸弹等 L3 模式
  local dlevel, dreasons = _dangerous(command)
  if dlevel >= M.LEVEL.CRITICAL then
    return "DESTRUCTIVE:" .. table.concat(dreasons, ",")
  end
  -- 单条命令名判定：无条件拒绝表 → 拒绝；能力门禁表 → 能力缺失才拒绝。
  local function _deny_bin(base)
    if DENY_BINS[base] then return "KERNEL_COMMAND:" .. base end
    local cap = CAP_GATED_BINS[base]
    if cap and not caps[cap] then
      return "CAPABILITY_REQUIRED:" .. base .. ":" .. cap
    end
    return nil
  end
  -- 内核/系统管理命令：按段检查首词；段首为包装器/解释器时扫描段内所有 token。
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
        for _, t in ipairs(toks) do
          local reason = _deny_bin(_base(t))
          if reason then return reason end
        end
      else
        local reason = _deny_bin(first)
        if reason then return reason end
      end
    end
  end
  return nil
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
  local function _norm(tok)
    local s = tostring(tok)
    s = s:gsub("%$'", ""):gsub('%$"', "")
    s = s:gsub("['\"]", ""):gsub("\\", "")
    return s
  end
  -- 收集 `NAME=value`（含行首/分号后），用于展开 `$NAME`/`${NAME}`，防止变量间接绕过。
  local vars = {}
  for name, val in command:gmatch("([%a_][%w_]*)%=([^%s;|&]+)") do
    vars[name] = _norm(val)
  end
  local function _expand(tok)
    local s = _norm(tok)
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
          local empty = raw == nil or _norm(raw) == ""
          if not empty and raw then
            local name = _norm(raw):match("^%$?{?([%a_][%w_]*)%}?$")
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
    require("NeoAI.sandbox.evidence").add("risk", {
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
