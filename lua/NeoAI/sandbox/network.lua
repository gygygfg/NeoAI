--- 沙箱受控网络网关
--- @module NeoAI.sandbox.network
--- 默认离线；仅在显式启用并声明允许端点后放行，且仍受字节预算约束。
--- L3/L4 五元组不能独立证明应用层身份，这里按声明端点做应用层校验（设计文档 §7.3）。

local M = {}

-- ========== 私有状态 ==========

local state = {
  used_bytes = 0,
}

-- ========== 私有函数 ==========

--- 主机名/URL 是否匹配允许模式（精确或 `*.suffix` / 后缀）
--- @param endpoint string
--- @param patterns table
--- @return boolean
local function _endpoint_allowed(endpoint, patterns)
  if not endpoint or endpoint == "" then return false end
  local host = endpoint:gsub("^%a+://", ""):gsub("[/:].*$", "")
  for _, pat in ipairs(patterns or {}) do
    local p = tostring(pat)
    if p == "*" or p == host then return true end
    if p:sub(1, 2) == "*." then
      local suffix = p:sub(2)
      if host:sub(-#suffix) == suffix then return true end
    end
  end
  return false
end

-- ========== 公开 API ==========

--- 是否允许访问某端点
--- @param endpoint string|nil
--- @param opts table|nil { bytes? }
--- @return boolean allowed
--- @return string|nil reason
function M.authorize(endpoint, opts)
  opts = opts or {}
  local cfg = require("NeoAI.kernel.config_store").get("tools.sandbox.network") or {}
  if cfg.enabled ~= true then
    return false, "NETWORK_NOT_DECLARED"
  end
  if not _endpoint_allowed(endpoint, cfg.allowed_endpoints or {}) then
    return false, "ENDPOINT_NOT_ALLOWED: " .. tostring(endpoint)
  end
  local budget = cfg.budget_bytes
  if budget and (state.used_bytes + (opts.bytes or 0)) > budget then
    return false, "NETWORK_BUDGET_EXCEEDED"
  end
  return true
end

--- 记录已用字节（受控计量）
--- @param bytes number
function M.consume(bytes)
  state.used_bytes = state.used_bytes + (bytes or 0)
end

--- 已用字节
--- @return number
function M.used_bytes()
  return state.used_bytes
end

--- 重置（测试用）
function M.reset()
  state.used_bytes = 0
end

M._endpoint_allowed = _endpoint_allowed

return M
