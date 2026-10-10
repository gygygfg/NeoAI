--- 沙箱审批 UI 相关测试的 services.sandbox 桩辅助（非测试套件）
--- @module 'NeoAI.tests.sandbox_stub'
--- 沙箱审批 UI 经 `services.sandbox` 门面访问沙箱能力（不再直接 require 沙箱内部模块）。
--- 测试桩通常只覆盖数据/行为方法（list_reviews / list_traces / apply / reject ...）；
--- 而「渲染与查询辅助」（risk_badge / hub_pages / audit_verdict / group_traces ...）此前是 UI
--- 直接 require 沙箱内部模块取得、现改经门面，故在此按真实实现补齐——等价于重构前的行为。
---
--- 注意：只补齐这些辅助，不注入 apply/apply_async 之类行为方法，以免改变「被桩省略的方法」
--- 所触发的分支（例如 UI 里 `if sandbox.apply_async then ... else sandbox.apply(...)`）。

local services = require("NeoAI.kernel.services")
local real_sandbox = require("NeoAI.sandbox")

-- UI 经门面调用、且此前经直接 require 访问的渲染/查询辅助。
local SB_HELPERS = {
  "audit_verdict", "audit_list", "audit_user_messages", "audit_generate",
  "risk_badge", "group_traces", "group_traces_by_command",
  "hub_pages", "hub_pending_count", "hub_list", "hub_resolve", "hub_get",
  "set_hub_ui", "reset_approval_hub",
  "detokenize", "git_path_class", "content_for",
  "l3_generate", "l3_fallback",
}

local M = {}

--- 以桩覆盖 + 真实辅助补齐后登记 `services.sandbox`。
--- 桩内显式提供的键优先（不被覆盖）。
--- @param overrides table|nil 数据/行为方法覆盖
function M.provide(overrides)
  overrides = overrides or {}
  for _, name in ipairs(SB_HELPERS) do
    if overrides[name] == nil then overrides[name] = real_sandbox[name] end
  end
  services.provide("services.sandbox", overrides)
end

return M
