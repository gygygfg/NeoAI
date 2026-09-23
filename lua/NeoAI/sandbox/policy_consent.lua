--- 沙箱策略确认：代理规避等「需用户批准」的操作暂停 Agent 并弹窗询问。
--- 交互式 Neovim 使用内建 `confirm`；真正 headless（无 attached UI）失败关闭（拒绝）。
--- 会话级「始终允许」按 kind 记忆。策略由 `tools.sandbox.network.block_proxy_evasion` 选择。
--- @module NeoAI.sandbox.policy_consent

local M = {}

local state = { session = {} }

--- 是否存在可交互的 Neovim UI（`--headless` 无 attached UI）。
--- @return boolean
local function _interactive()
  local ok, uis = pcall(vim.api.nvim_list_uis)
  return ok and type(uis) == "table" and #uis > 0
end

--- 本会话是否已对某策略「始终允许」
--- @param kind string
--- @return boolean
function M.is_session_allowed(kind)
  return type(kind) == "string" and state.session[kind] == true
end

--- 记住本会话「始终允许」
--- @param kind string
function M.allow_session(kind)
  if type(kind) == "string" and kind ~= "" then state.session[kind] = true end
end

--- 暂停并询问用户。返回 `"once"|"session"|"deny"`。
--- @param kind string 策略标识（如 "proxy_evasion"）
--- @param opts table|nil { title?, detail? }
--- @return string
function M.ask(kind, opts)
  opts = opts or {}
  if M.is_session_allowed(kind) then return "session" end
  if not _interactive() then return "deny" end
  local prompt = tostring(opts.title or "沙箱策略确认")
  if opts.detail and opts.detail ~= "" then
    prompt = prompt .. " " .. tostring(opts.detail):gsub("%s+", " ")
  end
  local choices = "仅本次允许\n本次会话始终允许\n拒绝"
  local ret = vim.fn.confirm(prompt, choices, 3, "Warning")
  if ret == 1 then return "once" end
  if ret == 2 then M.allow_session(kind); return "session" end
  return "deny"
end

--- 重置（测试用）
function M.reset()
  state.session = {}
end

return M
