--- 沙箱任务授权（task grant）
--- @module NeoAI.sandbox.grant
--- 窄范围任务授权：资源范围（路径）、操作类型、累计预算、有效期与撤销。
--- Agent 只能请求匹配，实际匹配与消费由控制面执行（设计文档 §5.2/§15.1）。
--- 有覆盖授权时，候选可自动应用（等价 TASK_POLICY_MATCH）；否则进入用户异步审批。

local M = {}

-- ========== 私有状态 ==========

local state = {
  grants = {}, -- id -> grant
  seq = 0,
}

-- ========== 私有函数 ==========

local function _abs(path)
  local p = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
  return (p:gsub("/+$", ""))
end

--- 路径是否落在 scope 模式内（支持精确、目录前缀、`/**` 递归）
--- @param path string
--- @param patterns table
--- @return boolean
local function _path_allowed(path, patterns)
  local p = _abs(path)
  for _, pattern in ipairs(patterns or {}) do
    local pat = _abs(pattern)
    if pat:sub(-3) == "/**" then
      local prefix = pat:sub(1, -4)
      if p == prefix or p:sub(1, #prefix + 1) == prefix .. "/" then return true end
    elseif p == pat or p:sub(1, #pat + 1) == pat .. "/" then
      return true
    end
  end
  return false
end

local function _op_allowed(grant, operation)
  local ops = grant.operations or { "fs_write" }
  for _, op in ipairs(ops) do
    if op == "*" or op == operation then return true end
  end
  return false
end

local function _active(grant)
  if grant.revoked then return false end
  if grant.expires_at and os.time() > grant.expires_at then return false end
  return true
end

-- ========== 公开 API ==========

--- 创建任务授权
--- @param spec table { scope = { paths = {...} }, operations?, budget? = { max_files? }, ttl_sec?, task_id?, created_by? }
--- @return table grant
function M.create(spec)
  spec = spec or {}
  state.seq = state.seq + 1
  local id = spec.id or string.format("grant_%d_%s", state.seq, tostring(os.time()))
  local grant = {
    grant_id = id,
    task_id = spec.task_id,
    scope = { paths = (spec.scope and spec.scope.paths) or {} },
    operations = spec.operations or { "fs_write" },
    budget = spec.budget or {},
    usage = { files = 0 },
    created_by = spec.created_by or "user",
    created_at = os.time(),
    expires_at = spec.ttl_sec and (os.time() + spec.ttl_sec) or nil,
    revoked = false,
  }
  state.grants[id] = grant
  return grant
end

--- 获取授权
--- @param id string
--- @return table|nil
function M.get(id)
  return state.grants[id]
end

--- 列出授权
--- @param filter table|nil { active_only? }
--- @return table 数组
function M.list(filter)
  filter = filter or {}
  local out = {}
  for _, g in pairs(state.grants) do
    if not filter.active_only or _active(g) then out[#out + 1] = g end
  end
  table.sort(out, function(a, b) return (a.created_at or 0) < (b.created_at or 0) end)
  return out
end

--- 撤销授权
--- @param id string
--- @return boolean
function M.revoke(id)
  local g = state.grants[id]
  if not g then return false end
  g.revoked = true
  g.revoked_at = os.time()
  return true
end

--- 授权是否覆盖给定候选（不消费）
--- @param grant table
--- @param operation string
--- @param cand table
--- @return boolean ok
--- @return string|nil reason
function M.covers(grant, operation, cand)
  if not _active(grant) then return false, "GRANT_INACTIVE" end
  if not _op_allowed(grant, operation) then return false, "GRANT_OPERATION_NOT_ALLOWED" end
  local files = cand and cand.files or {}
  local max_files = grant.budget and grant.budget.max_files
  if max_files and (grant.usage.files + #files) > max_files then
    return false, "GRANT_BUDGET_EXCEEDED"
  end
  for _, f in ipairs(files) do
    if not _path_allowed(f.path, grant.scope.paths) then
      return false, "PATH_OUTSIDE_GRANT_SCOPE: " .. tostring(f.path)
    end
  end
  return true
end

--- 查找覆盖候选的活跃授权
--- @param operation string
--- @param cand table
--- @return table|nil grant
function M.find_covering(operation, cand)
  for _, g in ipairs(M.list({ active_only = true })) do
    local ok = M.covers(g, operation, cand)
    if ok then return g end
  end
  return nil
end

--- 消费授权预算
--- @param id string
--- @param files number
--- @return boolean
function M.consume(id, files)
  local g = state.grants[id]
  if not g then return false end
  g.usage.files = g.usage.files + (files or 0)
  return true
end

--- 重置（测试用）
function M.reset()
  state.grants = {}
  state.seq = 0
end

M._path_allowed = _path_allowed

return M
