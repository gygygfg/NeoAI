--- Mason 风格高亮助手
--- @module 'NeoAI.ui.mason_hl'
--- 审批悬浮窗页标签 / ask_user 多问题标签等统一采用 **mason.nvim 的高亮风格**：
--- 若存在 mason.nvim 的高亮组（`MasonHighlight` / `MasonHighlightBlock` /
--- `MasonHighlightBlockBold` / `MasonHighlightSecondary` / `MasonHeader` …），则把目标组**链接**到
--- 对应 Mason 组（复用用户 Mason 主题配色，形成块状高亮）；否则回退到内置兜底配色。
--- 高亮以 `default=true` 定义：用户已显式自定义这些组时不覆盖。

local M = {}

--- 是否存在某高亮组
--- @param name string
--- @return boolean
function M.exists(name)
  if type(name) ~= "string" or name == "" then return false end
  local ok, v = pcall(vim.fn.hlexists, name)
  return ok and v == 1
end

--- 定义目标高亮组：存在 Mason 组时链接到它，否则用兜底属性。
--- 注意：`link` 不能与其它属性并存，故链接分支只设 link。
--- @param target string 目标高亮组名
--- @param mason string|nil Mason 高亮组名
--- @param fallback table|nil 兜底属性（如 { fg = "#...", bold = true }）
function M.def(target, mason, fallback)
  if mason and M.exists(mason) then
    vim.api.nvim_set_hl(0, target, { default = true, link = mason })
    return
  end
  if fallback then
    vim.api.nvim_set_hl(0, target, vim.tbl_extend("force", { default = true }, fallback))
  end
end

return M
