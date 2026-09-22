--- 沙箱控制面：标识、摘要、状态机、幂等与 fencing
--- @module NeoAI.sandbox.control
--- 状态机与并发控制的单一事实来源；不直接执行 I/O。

local json = require("NeoAI.utils.json")

local M = {}

-- ========== 状态常量 ==========

M.STATE = {
  RECEIVED = "RECEIVED",
  PARSED = "PARSED",
  PREFLIGHTED = "PREFLIGHTED",
  AWAITING_EXECUTION_AUTH = "AWAITING_EXECUTION_AUTH",
  STAGING = "STAGING",
  CANDIDATE_READY = "CANDIDATE_READY",
  COMPLETED_READ_ONLY = "COMPLETED_READ_ONLY",
  AWAITING_PUBLICATION_AUTH = "AWAITING_PUBLICATION_AUTH",
  READY_TO_PUBLISH = "READY_TO_PUBLISH",
  PUBLISHING = "PUBLISHING",
  VERIFYING = "VERIFYING",
  COMMITTED = "COMMITTED",
  CONFLICT = "CONFLICT",
  RECOVERING = "RECOVERING",
  ROLLED_BACK = "ROLLED_BACK",
  RECOVERY_REQUIRED = "RECOVERY_REQUIRED",
  ROLLBACK_FAILED = "ROLLBACK_FAILED",
  RECONCILING = "RECONCILING",
  OUTCOME_UNKNOWN = "OUTCOME_UNKNOWN",
  REJECTED = "REJECTED",
  BLOCKED = "BLOCKED",
  FAILED = "FAILED",
  CANCELLED = "CANCELLED",
  EXPIRED = "EXPIRED",
}

-- 合法状态迁移（条件/事件 → 下一状态）
local TRANSITIONS = {
  RECEIVED = { PARSED = true, REJECTED = true },
  PARSED = { PREFLIGHTED = true, BLOCKED = true, AWAITING_EXECUTION_AUTH = true, REJECTED = true },
  AWAITING_EXECUTION_AUTH = { PREFLIGHTED = true, CANCELLED = true, EXPIRED = true },
  PREFLIGHTED = { STAGING = true, FAILED = true, CANCELLED = true },
  STAGING = { CANDIDATE_READY = true, FAILED = true, CANCELLED = true },
  CANDIDATE_READY = {
    COMPLETED_READ_ONLY = true,
    AWAITING_PUBLICATION_AUTH = true,
    READY_TO_PUBLISH = true,
    FAILED = true,
    CANCELLED = true,
  },
  AWAITING_PUBLICATION_AUTH = { READY_TO_PUBLISH = true, CANCELLED = true, EXPIRED = true },
  READY_TO_PUBLISH = { PUBLISHING = true, CANCELLED = true },
  PUBLISHING = { VERIFYING = true, CONFLICT = true, RECONCILING = true },
  VERIFYING = { COMMITTED = true, RECOVERING = true, RECONCILING = true },
  RECOVERING = { ROLLED_BACK = true, RECOVERY_REQUIRED = true, ROLLBACK_FAILED = true },
  RECONCILING = { VERIFYING = true, READY_TO_PUBLISH = true, OUTCOME_UNKNOWN = true },
}

-- ========== 私有状态 ==========

local state = {
  seq = 0,
  fencing = 0,
  attempts = {}, -- command_id -> attempt record
  idempotency = {}, -- client_idempotency_key -> { request_hash, command_id }
  leases = {}, -- command_id -> { fencing_token, expires_at }
}

-- ========== 私有函数 ==========

--- 规范化编码：map 键排序，保证摘要稳定
--- @param value any
--- @return string
local function _canonical(value)
  local t = type(value)
  if t == "table" then
    if vim.islist(value) then
      local parts = {}
      for _, v in ipairs(value) do parts[#parts + 1] = _canonical(v) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(value) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
      parts[#parts + 1] = json.encode_fast(k) .. ":" .. _canonical(value[k])
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  if t == "string" then return json.encode_fast(value) end
  if value == nil then return "null" end
  return tostring(value)
end

--- @param value any
--- @return string sha256:<hex>
local function _hash(value)
  local encoded = _canonical(value)
  local ok, hex = pcall(vim.fn.sha256, encoded)
  if not ok or not hex or hex == "" then
    -- 极端回退：非加密摘要，仅用于非安全场景
    local n = 0
    for i = 1, #encoded do n = (n * 31 + encoded:byte(i)) % 2147483647 end
    return "fallback:" .. tostring(n)
  end
  return "sha256:" .. hex
end

-- ========== 公开 API ==========

--- 计算规范化摘要
--- @param value any
--- @return string
function M.hash(value)
  return _hash(value)
end

--- 签发新的执行尝试
--- @param tool_name string
--- @param args table
--- @param ctx table
--- @param spec table
--- @return table attempt
function M.new_attempt(tool_name, args, ctx, spec)
  state.seq = state.seq + 1
  local seq = state.seq
  local command_id = string.format("cmd_%d_%s", seq, tool_name)
  local attempt_id = string.format("attempt_%d", seq)
  local request_hash = _hash({
    tool = tool_name,
    args = args,
    cwd = vim.fn.getcwd(),
    effect = spec and spec.effect or "process",
  })
  local execution_intent_hash = _hash({
    request_hash = request_hash,
    agent = ctx and ctx.agent and ctx.agent.id or nil,
    mode = ctx and ctx.sandbox_mode or nil,
  })
  local attempt = {
    command_id = command_id,
    attempt_id = attempt_id,
    request_hash = request_hash,
    execution_intent_hash = execution_intent_hash,
    tool_name = tool_name,
    effect = spec and spec.effect or "process",
    state = M.STATE.RECEIVED,
    state_version = 1,
    created_at = os.time(),
  }
  state.attempts[command_id] = attempt
  return attempt
end

--- 幂等去重：同一 client_idempotency_key 携带不同请求必须拒绝
--- @param key string
--- @param request_hash string
--- @return boolean ok
--- @return string|nil reason
function M.claim_idempotency(key, request_hash)
  if type(key) ~= "string" or key == "" then return true end
  local prev = state.idempotency[key]
  if prev and prev.request_hash ~= request_hash then
    return false, "IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_REQUEST"
  end
  if not prev then
    state.idempotency[key] = { request_hash = request_hash }
  end
  return true
end

--- 状态迁移（条件更新：expected_version 不符则失败）
--- @param attempt table
--- @param next_state string
--- @return boolean
function M.transition(attempt, next_state)
  local allowed = TRANSITIONS[attempt.state]
  if not allowed or not allowed[next_state] then
    return false
  end
  attempt.state = next_state
  attempt.state_version = attempt.state_version + 1
  return true
end

--- 获取尝试记录
--- @param command_id string
--- @return table|nil
function M.get_attempt(command_id)
  return state.attempts[command_id]
end

--- 颁发写租约（返回 fencing token）
--- @param command_id string
--- @param ttl_sec number|nil
--- @return number fencing_token
function M.acquire_lease(command_id, ttl_sec)
  state.fencing = state.fencing + 1
  local token = state.fencing
  state.leases[command_id] = {
    fencing_token = token,
    expires_at = os.time() + (ttl_sec or 300),
  }
  return token
end

--- 校验写租约与 fencing token
--- @param command_id string
--- @param token number
--- @return boolean ok
--- @return string|nil reason
function M.check_lease(command_id, token)
  local lease = state.leases[command_id]
  if not lease then return false, "NO_LEASE" end
  if lease.fencing_token ~= token then return false, "STALE_FENCING_TOKEN" end
  if os.time() > lease.expires_at then return false, "LEASE_EXPIRED" end
  return true
end

--- 释放租约
--- @param command_id string
function M.release_lease(command_id)
  state.leases[command_id] = nil
end

--- 重置（测试用）
function M.reset()
  state.seq = 0
  state.fencing = 0
  state.attempts = {}
  state.idempotency = {}
  state.leases = {}
end

return M
