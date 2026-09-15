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

-- 危险命令模式（依据命令文本初判级别）。匹配为 Lua pattern。
local DANGEROUS = {
  { level = 3, name = "DESTRUCTIVE", pats = {
    "rm%s+%-[%w]*r[%w]*f[%w]*%s+/", "rm%s+%-[%w]*f[%w]*r[%w]*%s+/",
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

--- 路径所属级别：workspace=0 / user=1 / system=2
--- @param path string
--- @return number
function M.path_level(path)
  if type(path) ~= "string" or path == "" then return 2 end
  local abs = _norm(path)
  local cwd = _norm(vim.fn.getcwd())
  if _under(abs, cwd) then return 0 end
  local home = _norm(vim.fn.expand("~"))
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
---   secret?, host_op?, command?, tool?
--- }
--- @return table { level, name, badge, reasons = table }
function M.classify(facts)
  facts = facts or {}
  local level, reasons = 0, {}
  local function bump(l, reason)
    if l and l > level then level = l end
    if reason then reasons[#reasons + 1] = reason end
  end
  -- 写入路径级别
  for _, p in ipairs(facts.paths or {}) do
    local pl = M.path_level(p)
    if pl > 0 then bump(pl, pl == 1 and "USER_PATH_WRITE" or "SYSTEM_PATH_WRITE") end
  end
  if facts.network then bump(M.LEVEL.MODERATE, "NETWORK_ACCESS") end
  if facts.package then bump(M.LEVEL.MODERATE, "PACKAGE_INSTALL") end
  if facts.privilege_tier and facts.privilege_tier >= 1 then
    bump(facts.privilege_tier >= 2 and M.LEVEL.HIGH or M.LEVEL.MODERATE,
      facts.privilege_tier >= 2 and "PRIVILEGE_T2" or "PRIVILEGE_T1")
  end
  if facts.host_op then bump(M.LEVEL.CRITICAL, "HOST_OPERATION") end
  if facts.secret then
    -- 密钥操作按作用域分级：工作区内 L2（HIGH），工作区外（用户目录/系统路径）L3（CRITICAL）。
    local outside = false
    for _, p in ipairs(facts.paths or {}) do
      if M.path_level(p) > 0 then outside = true break end
    end
    if outside then
      bump(M.LEVEL.CRITICAL, "SECRET_OPERATION_OUTSIDE_WORKSPACE")
    else
      bump(M.LEVEL.HIGH, "SECRET_OPERATION")
    end
  end
  local dlevel, dreasons = _dangerous(facts.command)
  if dlevel > level then level = dlevel end
  for _, r in ipairs(dreasons) do reasons[#reasons + 1] = r end
  -- 包安装（apt/pip/npm 等）属高危但非 critical：其状态文件位于工作区外、且常含高熵签名/
  -- 哈希，不因「工作区外写入/密钥误报」升到 L3；仅当命令本身命中破坏性模式时才保留 L3。
  if facts.package and level >= M.LEVEL.CRITICAL and dlevel < M.LEVEL.CRITICAL then
    level = M.LEVEL.HIGH
  end
  return { level = level, name = M.level_name(level), badge = M.badge(level), reasons = reasons }
end

--- 命令文本命中的最高危险级别（供包安装降级判定）
--- @param command string|nil
--- @return number
function M.dangerous_level(command)
  local l = _dangerous(command)
  return l
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
    local text = (tostring(result.stdout or "") .. "\n" .. tostring(result.stderr or "")):lower()
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
  return { level = level, name = M.level_name(level), badge = M.badge(level), reasons = reasons, signals = signals }
end

--- 依据级别给出建议审批动作
--- @param level number
--- @param opts table|nil { session_auto?, package?, secret? }
--- @return string "auto" | "record" | "review" | "block"
function M.action(level, opts)
  opts = opts or {}
  -- 密钥与包安装永不因会话自动审批而跳过（需显式确认/规则）。
  if opts.secret then return "review" end
  if opts.package then
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
