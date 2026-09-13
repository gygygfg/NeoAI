--- 外部操作 broker
--- @module NeoAI.sandbox.broker
--- 外部副作用走专用适配器协议，不套用本地文件发布的原子性与回滚承诺（设计文档 §3.2/§11）。
--- 适配器必须声明幂等/查询/事务/补偿/不可逆能力；控制面据声明决定重试与对账策略。

local json = require("NeoAI.utils.json")

local M = {}

-- ========== 能力字段 ==========

M.CAPABILITY_FIELDS = {
  "supports_idempotency",
  "idempotency_retention",
  "supports_query",
  "transaction_boundary",
  "compensation_semantics",
  "irreversible_effects",
}

M.STATE = {
  PENDING = "PENDING",
  SUCCEEDED = "SUCCEEDED",
  FAILED = "FAILED",
  OUTCOME_UNKNOWN = "OUTCOME_UNKNOWN",
  COMPENSATED = "COMPENSATED",
}

-- ========== 私有状态 ==========

local state = {
  adapters = {}, -- id -> adapter
  operations = {}, -- operation_id -> record
  idempotency = {}, -- key -> operation_id
  seq = 0,
}

-- ========== 私有函数 ==========

local function _hash(value)
  local ok, hex = pcall(vim.fn.sha256, json.encode(value))
  return ok and ("sha256:" .. hex) or "sha256:?"
end

-- ========== 公开 API ==========

--- 注册外部操作适配器
--- @param adapter table { id, supports_idempotency?, idempotency_retention?, supports_query?, transaction_boundary?, compensation_semantics?, irreversible_effects?, invoke?, query?, compensate? }
--- @return boolean ok
--- @return string|nil err
function M.register(adapter)
  if type(adapter) ~= "table" or type(adapter.id) ~= "string" or adapter.id == "" then
    return false, "adapter.id 必须为非空字符串"
  end
  state.adapters[adapter.id] = adapter
  return true
end

--- 获取适配器
--- @param id string
--- @return table|nil
function M.get(id)
  return state.adapters[id]
end

--- 列出适配器及其能力声明
--- @return table 数组
function M.list()
  local out = {}
  for _, a in pairs(state.adapters) do
    local caps = {}
    for _, f in ipairs(M.CAPABILITY_FIELDS) do caps[f] = a[f] end
    out[#out + 1] = { id = a.id, capabilities = caps }
  end
  table.sort(out, function(x, y) return x.id < y.id end)
  return out
end

--- 调用外部操作
--- @param id string
--- @param op string
--- @param params table
--- @param opts table|nil { idempotency_key?, task_id? }
--- @return table { ok, state, operation_id?, result?, reason? }
function M.invoke(id, op, params, opts)
  opts = opts or {}
  local adapter = state.adapters[id]
  if not adapter then
    return { ok = false, state = M.STATE.FAILED, reason = "ADAPTER_NOT_FOUND: " .. tostring(id) }
  end
  if type(adapter.invoke) ~= "function" then
    return { ok = false, state = M.STATE.FAILED, reason = "ADAPTER_NOT_INVOKABLE: " .. tostring(id) }
  end
  local request_hash = _hash({ op = op, params = params })
  local key = opts.idempotency_key
  if key and state.idempotency[key] then
    local prev = state.operations[state.idempotency[key]]
    if prev and prev.request_hash ~= request_hash then
      return { ok = false, state = M.STATE.FAILED, reason = "IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_REQUEST" }
    end
    return { ok = true, state = prev.state, operation_id = prev.operation_id, result = prev.result }
  end

  state.seq = state.seq + 1
  local operation_id = string.format("op_%d_%s", state.seq, id)
  local record = {
    operation_id = operation_id,
    adapter = id,
    op = op,
    request_hash = request_hash,
    idempotency_key = key,
    state = M.STATE.PENDING,
    created_at = os.time(),
  }
  state.operations[operation_id] = record
  if key then state.idempotency[key] = operation_id end

  local ok, res = pcall(adapter.invoke, op, params)
  if not ok then
    record.state = M.STATE.FAILED
    record.reason = tostring(res)
    return { ok = false, state = record.state, operation_id = operation_id, reason = record.reason }
  end
  if type(res) == "table" and res.outcome_unknown then
    record.state = M.STATE.OUTCOME_UNKNOWN
    record.result = res.result
    return { ok = false, state = record.state, operation_id = operation_id, result = res.result, reason = "OUTCOME_UNKNOWN" }
  end
  record.state = M.STATE.SUCCEEDED
  record.result = res
  return { ok = true, state = record.state, operation_id = operation_id, result = res }
end

--- 对账：查询远端真实结果
--- @param operation_id string
--- @return table { ok, state, result?, reason? }
function M.reconcile(operation_id)
  local record = state.operations[operation_id]
  if not record then
    return { ok = false, state = M.STATE.FAILED, reason = "OPERATION_NOT_FOUND: " .. tostring(operation_id) }
  end
  local adapter = state.adapters[record.adapter]
  if not adapter or type(adapter.query) ~= "function" then
    record.state = M.STATE.OUTCOME_UNKNOWN
    return { ok = false, state = M.STATE.OUTCOME_UNKNOWN, reason = "QUERY_UNSUPPORTED" }
  end
  local ok, res = pcall(adapter.query, operation_id)
  if not ok then
    record.state = M.STATE.OUTCOME_UNKNOWN
    return { ok = false, state = M.STATE.OUTCOME_UNKNOWN, reason = tostring(res) }
  end
  if res == true then
    record.state = M.STATE.SUCCEEDED
    return { ok = true, state = M.STATE.SUCCEEDED }
  elseif res == false then
    record.state = M.STATE.FAILED
    return { ok = false, state = M.STATE.FAILED }
  end
  record.state = M.STATE.OUTCOME_UNKNOWN
  return { ok = false, state = M.STATE.OUTCOME_UNKNOWN, reason = "QUERY_INCONCLUSIVE" }
end

--- 获取操作记录
--- @param operation_id string
--- @return table|nil
function M.operation(operation_id)
  return state.operations[operation_id]
end

--- 重置（测试用）
function M.reset()
  state.adapters = {}
  state.operations = {}
  state.idempotency = {}
  state.seq = 0
end

return M
