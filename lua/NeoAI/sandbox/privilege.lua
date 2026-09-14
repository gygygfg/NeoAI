--- 沙箱权限档位与自动提权
--- @module NeoAI.sandbox.privilege
--- 为外部进程定义分级权限档位（最小权限 → 提权 → 特权），把「命令所需权限」
--- 映射为具体隔离参数（cap_add / 额外挂载 / 解除遮蔽 / 网络 / 嵌套 userns）。
---
--- 设计模型（见 docs/sandbox.md §17）：
---   T0 最小权限：默认档位，cap-drop ALL + seccomp + 遮蔽 + 默认隔离网络；
---   T1 提权（隔离内）：网络访问、受控 docker socket；自动授权、隔离执行、留痕；
---   T2 特权（主机影响）：在嵌套 userns 内自动执行，主机效果冻结为提案异步审批。
--- 自动提权只「发起请求」，是否放行由策略/授权/审查决定；不静默降级。

local config_store = require("NeoAI.kernel.config_store")

local M = {}

-- ========== 档位常量 ==========

M.TIER = { MINIMAL = 0, ELEVATED = 1, PRIVILEGED = 2 }

-- 档位默认（配置缺省时兜底；与 default_config.lua 保持一致）
local TIER_DEFAULTS = {
  [0] = { name = "minimal", review = "auto", network = false, cap_add = {}, mounts = {}, unmask = {} },
  [1] = {
    name = "elevated", review = "auto", network = true, cap_add = {}, mounts = {},
    unmask = { "/run/docker.sock", "/var/run/docker.sock" },
  },
  [2] = {
    name = "privileged", review = "approve", network = true, userns = true, cap_add = {}, mounts = {},
    unmask = { "/run/docker.sock", "/var/run/docker.sock" },
  },
}

-- 提权失败模式：T0 命令失败时据此建议升级档位（仅发起请求，不静默执行）
local ESCALATION_PATTERNS = {
  {
    tier = M.TIER.ELEVATED, reason = "DOCKER_SOCKET_UNAVAILABLE",
    pats = {
      "cannot connect to the docker daemon", "is the docker daemon running",
      "dial unix /var/run/docker.sock", "docker.sock: connect",
    },
  },
  {
    tier = M.TIER.ELEVATED, reason = "NETWORK_UNREACHABLE",
    pats = {
      "could not resolve host", "temporary failure in name resolution",
      "network is unreachable", "connection refused", "connection timed out",
      "no route to host", "couldn't connect to server", "failed to connect",
    },
  },
  {
    tier = M.TIER.PRIVILEGED, reason = "PRIVILEGE_DENIED",
    pats = {
      "operation not permitted", "must be root", "are you root",
      "requires root", "requires cap_", "you need to be root",
    },
  },
}

-- 可跳过的命令前缀（不含 sudo/doas：它们本身就是特权信号，保留分类）
local SKIP_PREFIX = {
  env = true, command = true, nohup = true, time = true, nice = true,
  stdbuf = true, xargs = true,
}

-- ========== 私有函数 ==========

local function _cfg()
  return config_store.get("tools.sandbox.privilege") or {}
end

local function _docker_cfg()
  return config_store.get("tools.sandbox.docker") or {}
end

--- 按分隔符切分复合命令（`;` `|` `&&` `||` 换行）
--- @param command string
--- @return table 数组
local function _segments(command)
  local out = {}
  for seg in tostring(command):gmatch("[^;|&\n]+") do
    local t = seg:gsub("^%s+", ""):gsub("%s+$", "")
    if t ~= "" then out[#out + 1] = t end
  end
  return out
end

--- @param value string
--- @param list table
--- @return boolean
local function _in(value, list)
  for _, v in ipairs(list or {}) do if v == value then return true end end
  return false
end

--- 对单个命令段分类，返回最高匹配档位与规则名
--- @param seg string
--- @param rules table
--- @return number|nil tier
--- @return string|nil name
local function _classify_segment(seg, rules)
  local toks = {}
  for w in seg:gmatch("%S+") do toks[#toks + 1] = w end
  local i = 1
  while i <= #toks and toks[i]:match("^[%w_]+=") do i = i + 1 end
  while i <= #toks and SKIP_PREFIX[toks[i]] do i = i + 1 end
  local raw = toks[i]
  if not raw then return nil, nil end
  local bin = vim.fn.fnamemodify(raw, ":t")
  local sub = toks[i + 1]
  local best, name
  for _, rule in ipairs(rules or {}) do
    local hit = false
    if rule.bins then
      hit = _in(bin, rule.bins)
    elseif rule.bin and bin == rule.bin then
      hit = (not rule.subs) or _in(sub or "", rule.subs)
    end
    if hit then
      if not best or (rule.tier or 0) > best then best, name = rule.tier or 0, rule.name end
    end
  end
  return best, name
end

--- 合并档位配置（配置值优先，缺省用内置默认）
--- @param tier number
--- @return table
local function _tier_cfg(tier)
  local cfg = _cfg()
  local tiers = cfg.tiers or {}
  local t = tiers[tier] or tiers[tostring(tier)] or {}
  local d = TIER_DEFAULTS[tier] or TIER_DEFAULTS[0]
  local out = {}
  for k, v in pairs(d) do out[k] = vim.deepcopy(v) end
  for k, v in pairs(t) do out[k] = vim.deepcopy(v) end
  return out
end

--- 解析 docker 档位应挂载的 socket（受控优先，宿主仅 T2）
--- @param tier number
--- @param want_docker boolean
--- @return table|nil mount
--- @return string|nil err
--- @return string|nil docker_host
local function _docker_mount(tier, want_docker)
  if not want_docker then return nil, nil, nil end
  local d = _docker_cfg()
  local mode = d.mode or "controlled"
  if mode == "off" then
    return nil, "DOCKER_DISABLED", nil
  end
  if mode == "host" then
    if tier < M.TIER.PRIVILEGED then
      return nil, "DOCKER_HOST_REQUIRES_TIER2", nil
    end
    return { src = "/var/run/docker.sock", dst = "/var/run/docker.sock", mode = "rw" }, nil,
      "unix:///var/run/docker.sock"
  end
  -- controlled：指向外部受控 socket（rootless / socket-proxy / dind）
  local sock = d.socket
  if type(sock) ~= "string" or sock == "" then
    return nil, "DOCKER_SOCKET_NOT_CONFIGURED", nil
  end
  if vim.uv.fs_stat(sock) == nil then
    return nil, "DOCKER_SOCKET_UNAVAILABLE: " .. sock, nil
  end
  return { src = sock, dst = "/var/run/docker.sock", mode = "rw" }, nil,
    "unix:///var/run/docker.sock"
end

-- ========== 公开 API ==========

--- 分类命令所需权限档位
--- @param tool string|nil
--- @param args table|nil
--- @param spec table|nil { effect }
--- @return table { tier, reasons, docker, network }
function M.classify(tool, args, spec)
  local cfg = _cfg()
  if cfg.enabled == false then
    return { tier = M.TIER.MINIMAL, reasons = { "PRIVILEGE_DISABLED" }, docker = false, network = false }
  end
  if not spec or spec.effect ~= "process" then
    return { tier = M.TIER.MINIMAL, reasons = { "NON_PROCESS_EFFECT" }, docker = false, network = false }
  end
  local command = tostring((args and (args.command or args.cmd)) or "")
  if command == "" then
    return { tier = M.TIER.MINIMAL, reasons = { "NO_COMMAND" }, docker = false, network = false }
  end
  local rules = cfg.classify or {}
  local tier, reasons = M.TIER.MINIMAL, {}
  local docker, network = false, false
  for _, seg in ipairs(_segments(command)) do
    local t, name = _classify_segment(seg, rules)
    if t then
      if t > tier then tier = t end
      reasons[#reasons + 1] = name or ("TIER_" .. tostring(t))
      if name == "docker" then docker = true end
      if name == "network" then network = true end
    end
  end
  return { tier = tier, reasons = reasons, docker = docker, network = network }
end

--- 解析档位对应的具体隔离参数
--- @param tier number
--- @param req table|nil classify() 返回（含 docker/network）
--- @return table { ok, privileges?, reason? }
function M.resolve(tier, req)
  local cfg = _cfg()
  if cfg.enabled == false then
    return { ok = false, reason = "PRIVILEGE_DISABLED" }
  end
  local max_tier = cfg.max_tier or 0
  if tier > max_tier then
    return { ok = false, reason = "PRIVILEGE_TIER_EXCEEDS_MAX: " .. tostring(tier) .. " > " .. tostring(max_tier) }
  end
  local t = _tier_cfg(tier)
  local priv = {
    tier = tier,
    name = t.name,
    review = t.review or "auto",
    network = t.network ~= false,
    cap_add = vim.deepcopy(t.cap_add or {}),
    mounts = vim.deepcopy(t.mounts or {}),
    unmask = vim.deepcopy(t.unmask or {}),
    userns = t.userns == true,
    env = {},
  }
  if req and req.docker then
    local mount, err, host = _docker_mount(tier, true)
    if err then return { ok = false, reason = err } end
    if mount then priv.mounts[#priv.mounts + 1] = mount end
    if host then priv.env.DOCKER_HOST = host end
  end
  return { ok = true, privileges = priv }
end

--- 档位对应的审查严格度
--- @param tier number
--- @return string "auto" | "confirm" | "approve"
function M.review_mode(tier)
  return _tier_cfg(tier).review or "auto"
end

--- 档位对应的信封 severity
--- @param tier number
--- @return string
function M.severity(tier)
  if tier >= M.TIER.PRIVILEGED then return "CRITICAL" end
  if tier >= M.TIER.ELEVATED then return "HIGH" end
  return "LOW"
end

--- 依据失败输出建议升级档位（仅建议，不执行）
--- @param result table|nil { code, stdout, stderr }
--- @return table|nil { tier, reason }
function M.detect_escalation(result)
  if type(result) ~= "table" then return nil end
  if result.code == 0 or result.code == nil then return nil end
  local text = (tostring(result.stderr or "") .. "\n" .. tostring(result.stdout or "")):lower()
  local best = nil
  for _, rule in ipairs(ESCALATION_PATTERNS) do
    for _, p in ipairs(rule.pats) do
      if text:find(p, 1, true) then
        if not best or rule.tier > best.tier then best = { tier = rule.tier, reason = rule.reason } end
        break
      end
    end
  end
  return best
end

--- 留痕：一次权限档位裁决/升级（证据 + 事件）
--- @param meta table { tool?, command?, command_id?, attempt_id?, from_tier?, to_tier?, reasons?, reason? }
function M.record(meta)
  meta = meta or {}
  if _cfg().record == false then return end
  pcall(function()
    require("NeoAI.sandbox.evidence").add("privilege", {
      tool = meta.tool, command = meta.command,
      from_tier = meta.from_tier, to_tier = meta.to_tier,
      reasons = meta.reasons or (meta.reason and { meta.reason } or {}),
      source = "observed", coverage = "full",
    }, { tool = meta.tool, command_id = meta.command_id, attempt_id = meta.attempt_id })
  end)
  pcall(function()
    require("NeoAI.kernel.event_bus").emit(
      require("NeoAI.kernel.events").SANDBOX_PRIVILEGE_RECORDED, {
        tool = meta.tool, from_tier = meta.from_tier, to_tier = meta.to_tier,
        reasons = meta.reasons, reason = meta.reason, command_id = meta.command_id,
      })
  end)
end

--- 重置（测试用）
function M.reset()
  -- 无模块级状态
end

M._segments = _segments
M._classify_segment = _classify_segment

return M
