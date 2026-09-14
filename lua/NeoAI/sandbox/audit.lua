--- 沙箱行为审计与风险评估
--- @module NeoAI.sandbox.audit
--- 对 AI 的「读取 / 调用」行为做持续监视与风险评估：记录每次工具调用、外部命令、密钥
--- 检测、提权、容器、包安装等观测，累计加权风险分，并在异常（高风险、重复命中）时
--- 发出事件。用于「对 AI 的读取、调用行为做监视与风险评估」。
---
--- 仅内存保留（有界环形缓冲），不落盘；需要持久化的调用方另行写 evidence。

local M = {}

-- ========== 常量 ==========

local MAX_ENTRIES = 500

-- 各级别权重（用于风险分）
local LEVEL_WEIGHT = { [0] = 1, [1] = 3, [2] = 8, [3] = 20 }

-- 异常阈值：单条观测达到该级别即视为异常
local ANOMALY_LEVEL = 2

-- ========== 私有状态 ==========

local state = {
  entries = {}, -- 环形：{ at, kind, tool, level, reasons, meta }
  counts = {}, -- kind -> n
  levels = {}, -- level -> n
  score = 0,
  anomalies = 0,
}

-- ========== 私有函数 ==========

local function _emit(event, payload)
  pcall(function()
    require("NeoAI.kernel.event_bus").emit(event, payload or {})
  end)
end

local function _trim()
  while #state.entries > MAX_ENTRIES do
    table.remove(state.entries, 1)
  end
end

-- ========== 公开 API ==========

--- 记录一条行为观测
--- @param entry table {
---   kind: "tool"|"read"|"write"|"process"|"network"|"secret"|"privilege"|"container"|"package",
---   tool?, level?, reasons?, paths?, command_id?, meta? = table
--- }
--- @return table entry
function M.observe(entry)
  entry = entry or {}
  local level = entry.level or 0
  local rec = {
    at = os.time(),
    kind = entry.kind or "tool",
    tool = entry.tool,
    level = level,
    reasons = entry.reasons or {},
    paths = entry.paths,
    command_id = entry.command_id,
    manager = entry.manager,
    mode = entry.mode,
    share_namespace = entry.share_namespace,
    reason = entry.reason,
  }
  state.entries[#state.entries + 1] = rec
  _trim()
  state.counts[rec.kind] = (state.counts[rec.kind] or 0) + 1
  state.levels[level] = (state.levels[level] or 0) + 1
  state.score = state.score + (LEVEL_WEIGHT[level] or 1)
  _emit(require("NeoAI.kernel.events").SANDBOX_AUDIT_OBSERVED, {
    kind = rec.kind, tool = rec.tool, level = level, reasons = rec.reasons,
    command_id = rec.command_id,
  })
  if level >= ANOMALY_LEVEL then
    state.anomalies = state.anomalies + 1
    _emit(require("NeoAI.kernel.events").SANDBOX_AUDIT_ANOMALY, {
      kind = rec.kind, tool = rec.tool, level = level, reasons = rec.reasons,
      command_id = rec.command_id,
    })
  end
  return rec
end

--- 当前累计风险分
--- @return number
function M.risk_score()
  return state.score
end

--- 风险分对应的等级名（用于展示）
--- @return string
function M.risk_band()
  local s = state.score
  if s >= 200 then return "critical" end
  if s >= 80 then return "high" end
  if s >= 20 then return "moderate" end
  return "low"
end

--- 行为计数快照
--- @return table { counts, levels, anomalies, score }
function M.counts()
  return {
    counts = vim.deepcopy(state.counts),
    levels = vim.deepcopy(state.levels),
    anomalies = state.anomalies,
    score = state.score,
  }
end

--- 最近观测（可过滤）
--- @param filter table|nil { kind?, min_level?, limit? }
--- @return table 数组
function M.list(filter)
  filter = filter or {}
  local out = {}
  for _, e in ipairs(state.entries) do
    if (not filter.kind or e.kind == filter.kind)
      and (not filter.min_level or (e.level or 0) >= filter.min_level) then
      out[#out + 1] = vim.deepcopy(e)
    end
  end
  if filter.limit and #out > filter.limit then
    local trimmed = {}
    for i = #out - filter.limit + 1, #out do trimmed[#trimmed + 1] = out[i] end
    out = trimmed
  end
  return out
end

--- 人类可读摘要（供命令输出）
--- @return string
function M.summary()
  local c = M.counts()
  local kinds = {}
  for k, n in pairs(c.counts) do kinds[#kinds + 1] = string.format("%s=%d", k, n) end
  table.sort(kinds)
  local lv = {}
  for l = 0, 3 do if (c.levels[l] or 0) > 0 then lv[#lv + 1] = string.format("L%d=%d", l, c.levels[l]) end end
  return string.format("风险分=%d(%s) 异常=%d [%s] %s",
    c.score, M.risk_band(), c.anomalies, table.concat(lv, ","), table.concat(kinds, " "))
end

--- 重置（测试用）
function M.reset()
  state.entries = {}
  state.counts = {}
  state.levels = {}
  state.score = 0
  state.anomalies = 0
end

return M
