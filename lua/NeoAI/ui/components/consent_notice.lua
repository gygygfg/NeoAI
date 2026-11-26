--- 审批界面共享的「后果告知」区块
--- @module 'NeoAI.ui.components.consent_notice'
--- 由 tool_approval / sandbox_review / secret_alert 等所有同意面共用，保证同一风险只有
--- 一种说法。文案来自 `sandbox/review/consequence.lua`，本模块只负责排版与「放行范围」的
--- 措辞，不提供「永久允许」——放行范围只有「仅本次」与「本会话」。
---
--- 不做高亮/建窗：调用方拿到文本后按自己的渲染方式展示（弹窗是纯文本缓冲区，
--- 待审列表是折叠条目），这样不会为了统一文案而统一 UI 实现。

local M = {}

-- ========== 私有函数 ==========

--- 放行范围说明（按可用的决策类型生成）
--- @param opts table|nil { grant?: "once"|"session", allow_session?: boolean }
--- @return string
local function _grant_scope(opts)
  opts = opts or {}
  if opts.grant == "once" then
    return "仅本次调用有效，下一次调用会重新询问"
  end
  if opts.allow_session == false then
    return "仅本次调用有效（本机未启用会话放行）"
  end
  return "确认后本会话内持续有效；选「仅本次」则只对本次调用生效"
end

-- ========== 公开 API ==========

--- 生成后果告知区块
--- @param opts table {
---   consequence_id: string|nil, grant?: "once"|"session", allow_session?: boolean }
--- @return string|nil 无对应后果条目时返回 nil
function M.text(opts)
  opts = opts or {}
  local ok, consequence = pcall(require, "NeoAI.sandbox.review.consequence")
  if not ok or type(consequence) ~= "table" then return nil end
  local c = consequence.get(opts.consequence_id)
  if not c then return nil end
  local lines = {
    "⚠ 后果：" .. tostring(c.title or opts.consequence_id),
    "   能力  " .. tostring(c.ability or ""),
    "   范围  " .. tostring(c.scope or ""),
    "   持续  " .. _grant_scope(opts),
    "   建议  " .. tostring(c.suggestion or ""),
  }
  return table.concat(lines, "\n")
end

--- 决策项：哪些放行动作对本次审批可用
--- 受保护资源不放「允许并加入工作目录」（那是把目录范围长期扩大，会话内），也不放
--- 「允许所有」（会话级工具级自动放行会让后续同一工具的受保护访问**不再展示后果**，
--- 等于把一次同意洗成一条静默通道）。
--- @param opts table|nil { protected?: boolean }
--- @return table { add_to_workspace: boolean, confirm_all: boolean }
function M.actions(opts)
  opts = opts or {}
  local protected = opts.protected == true
  return { add_to_workspace = not protected, confirm_all = not protected }
end

--- 待审条目头部的一行摘要
--- @param consequence_id string|nil
--- @return string|nil
function M.summary(consequence_id)
  local ok, consequence = pcall(require, "NeoAI.sandbox.review.consequence")
  if not ok or type(consequence) ~= "table" then return nil end
  return consequence.summary(consequence_id)
end

return M
