--- 沙箱策略服务
--- @module NeoAI.sandbox.policy
--- 规则输入来自控制面验证过的不可变事实；规则在受限环境执行。
--- 聚合顺序：DENY 高于 NEEDS_CONFIRMATION 高于 ALLOW（设计文档 §9.1）。
--- 规则异常、超时、结构错误统一产生 DENY（POLICY_EVALUATION_FAILED）。

local M = {}

-- ========== 私有状态 ==========

local state = {
  instruction_budget = 200000,
  time_budget_ms = 100,
}

-- ========== 私有函数 ==========

--- 受限 Lua 规则执行：显式函数白名单，禁 os/io/debug/load/require。
--- @param fn function
--- @param facts table
--- @return boolean ok
--- @return any result_or_err
local function _run_restricted(fn, facts)
  local instructions = 0
  local started = vim.uv.hrtime()
  local budget = state.instruction_budget
  local deadline = started + state.time_budget_ms * 1e6
  local env = {
    facts = facts,
    string = { format = string.format, find = string.find, match = string.match, sub = string.sub, lower = string.lower },
    table = { concat = table.concat, insert = table.insert, sort = table.sort },
    math = { min = math.min, max = math.max, floor = math.floor, abs = math.abs },
    ipairs = ipairs,
    pairs = pairs,
    type = type,
    tostring = tostring,
    tonumber = tonumber,
  }
  -- LuaJIT 的 JIT 编译会绕过 debug 钩子（紧循环永不触发预算），
  -- 因此规则执行期间关闭 JIT，保证指令预算/墙钟限制真实生效。
  local has_jit = false
  do
    local ok, jit = pcall(require, "jit")
    if ok and jit and jit.off then
      has_jit = true
      pcall(jit.off)
    end
  end
  local step = 1000
  debug.sethook(function()
    instructions = instructions + step
    if instructions > budget then
      error("POLICY_INSTRUCTION_BUDGET_EXCEEDED", 0)
    end
    if vim.uv.hrtime() > deadline then
      error("POLICY_TIME_BUDGET_EXCEEDED", 0)
    end
  end, "", step)
  local ok, res = pcall(function()
    return fn(facts, env)
  end)
  debug.sethook()
  if has_jit then pcall(require("jit").on) end
  if not ok then return false, res end
  return true, res
end

--- 归一化单条规则结果
--- @param res any
--- @return table { decision, reason_codes, constraints, required_grants }
local function _normalize(res)
  if type(res) ~= "table" then
    return { decision = "DENY", reason_codes = { "POLICY_INVALID_RESULT" }, constraints = {}, required_grants = {} }
  end
  local decision = res.decision
  if decision ~= "ALLOW" and decision ~= "DENY" and decision ~= "NEEDS_CONFIRMATION" then
    return { decision = "DENY", reason_codes = { "POLICY_INVALID_DECISION" }, constraints = {}, required_grants = {} }
  end
  local codes = {}
  for _, c in ipairs(res.reason_codes or {}) do codes[#codes + 1] = tostring(c) end
  local grants = {}
  for _, g in ipairs(res.required_grants or {}) do grants[#grants + 1] = g end
  return {
    decision = decision,
    reason_codes = codes,
    constraints = res.constraints or {},
    required_grants = grants,
  }
end

--- 合并约束：权限集合取交集，预算取更小值（更严格）
--- @param list table 数组
--- @return table
local function _intersect_constraints(list)
  local out = nil
  for _, c in ipairs(list) do
    if type(c) == "table" then
      if out == nil then
        out = vim.deepcopy(c)
      else
        for k, v in pairs(c) do
          if type(v) == "number" and type(out[k]) == "number" then
            out[k] = math.min(out[k], v)
          elseif type(v) == "table" and type(out[k]) == "table" then
            -- 列表取交集（更严格）
            local allow = {}
            for _, item in ipairs(v) do allow[item] = true end
            local merged = {}
            for _, item in ipairs(out[k]) do
              if allow[item] then merged[#merged + 1] = item end
            end
            out[k] = merged
          else
            out[k] = v
          end
        end
      end
    end
  end
  return out or {}
end

-- ========== 公开 API ==========

--- 评估事实并聚合裁决
--- @param facts table
--- @return table { decision, reason_codes }
function M.evaluate(facts)
  local cfg = require("NeoAI.kernel.config_store").get("tools.sandbox.policy") or {}
  local results = {}
  local hard_deny = false
  local codes = {}

  -- 1) 内置硬拒绝规则
  for _, name in ipairs(cfg.deny_tools or {}) do
    if facts.tool == name then
      results[#results + 1] = { decision = "DENY", reason_codes = { "TOOL_HARD_DENIED" } }
    end
  end
  if facts.effect == "network" then
    local offline = require("NeoAI.kernel.config_store").get("tools.sandbox.offline")
    if offline ~= false then
      results[#results + 1] = { decision = "DENY", reason_codes = { "NETWORK_NOT_DECLARED" } }
    else
      local url = facts.args and (facts.args.url or facts.args.endpoint)
      local ok, reason = require("NeoAI.sandbox.network").authorize(url, {})
      if not ok then
        results[#results + 1] = { decision = "DENY", reason_codes = { reason } }
      end
    end
  end
  if facts.effect == "process" then
    local runtime = require("NeoAI.sandbox.runtime")
    local ok, err = runtime.check_available()
    if not ok then
      results[#results + 1] = { decision = "DENY", reason_codes = { err } }
    end
  end

  -- 2) 用户规则（受限执行）
  for _, rule in ipairs(cfg.rules or {}) do
    if type(rule) == "function" then
      local ok, res = _run_restricted(rule, facts)
      if not ok then
        results[#results + 1] = { decision = "DENY", reason_codes = { "POLICY_EVALUATION_FAILED" } }
      else
        results[#results + 1] = _normalize(res)
      end
    end
  end

  -- 3) 聚合：DENY > NEEDS_CONFIRMATION > ALLOW；约束取更严格交集
  local needs_confirmation = false
  local constraints = {}
  local required_grants = {}
  for _, r in ipairs(results) do
    if r.constraints and next(r.constraints) then constraints[#constraints + 1] = r.constraints end
    for _, g in ipairs(r.required_grants or {}) do required_grants[#required_grants + 1] = g end
    if r.decision == "DENY" then
      hard_deny = true
      for _, c in ipairs(r.reason_codes) do codes[#codes + 1] = c end
    elseif r.decision == "NEEDS_CONFIRMATION" then
      needs_confirmation = true
      for _, c in ipairs(r.reason_codes) do codes[#codes + 1] = c end
    end
  end
  local merged_constraints = _intersect_constraints(constraints)
  if hard_deny then
    return { decision = "DENY", reason_codes = codes, constraints = merged_constraints, required_grants = required_grants }
  end
  if needs_confirmation or #required_grants > 0 then
    return { decision = "NEEDS_CONFIRMATION", reason_codes = codes, constraints = merged_constraints, required_grants = required_grants }
  end
  return { decision = "ALLOW", reason_codes = codes, constraints = merged_constraints, required_grants = required_grants }
end

--- 设置资源限制（测试用）
--- @param opts table { instruction_budget?, time_budget_ms? }
function M.set_limits(opts)
  if opts.instruction_budget then state.instruction_budget = opts.instruction_budget end
  if opts.time_budget_ms then state.time_budget_ms = opts.time_budget_ms end
end

--- 重置（测试用）
function M.reset()
  state.instruction_budget = 200000
  state.time_budget_ms = 100
end

return M
