---@module lsp_utils

-- LSP 通用基础设施
-- 从 neovim_lsp.lua 提取的公共函数，供 file_tools、neovim_lsp 等模块复用

local M = {}

-- 缓存
local lsp_available = nil

-- ================================================================
-- LSP 符号类型名称映射（兼容 Neovim 0.12，该版本没有 vim.lsp.symbol_kind_name）
-- ================================================================
local symbol_kind_names = {
  [1] = "File",
  [2] = "Module",
  [3] = "Namespace",
  [4] = "Package",
  [5] = "Class",
  [6] = "Method",
  [7] = "Property",
  [8] = "Field",
  [9] = "Constructor",
  [10] = "Enum",
  [11] = "Interface",
  [12] = "Function",
  [13] = "Variable",
  [14] = "Constant",
  [15] = "String",
  [16] = "Number",
  [17] = "Boolean",
  [18] = "Array",
  [19] = "Object",
  [20] = "Key",
  [21] = "Null",
  [22] = "EnumMember",
  [23] = "Struct",
  [24] = "Event",
  [25] = "Operator",
  [26] = "TypeParameter",
}

--- 安全获取符号类型名称（兼容旧版本 Neovim）
--- @param kind integer|any LSP SymbolKind 编号
--- @return string 符号类型名称
function M.safe_symbol_kind_name(kind)
  if type(kind) ~= "number" then
    return tostring(kind or "Unknown")
  end
  local ok, result = pcall(vim.lsp.symbol_kind_name, kind)
  if ok and result then
    return result
  end
  return symbol_kind_names[kind] or ("Symbol_" .. kind)
end

-- ================================================================
-- LSP 可用性检查
-- ================================================================

--- 检查 LSP 模块是否可用
--- @return boolean
function M.check_lsp()
  if lsp_available then
    return true
  end
  local ok = pcall(require, "vim.lsp")
  if ok then
    lsp_available = true
    return true
  end
  return false
end

-- ================================================================
-- LSP 客户端验证
-- ================================================================

--- 判断客户端是否为正式 LSP 服务（纯能力检测，不依赖硬编码名称）
--- 规则：仅支持 inlineCompletion 且无任何核心 LSP 能力的客户端视为非正式
--- @param client table|nil LSP 客户端
--- @return boolean
function M.is_formal_lsp_client(client)
  if not client then
    return false
  end
  local caps = client.server_capabilities
  if not caps then
    return true -- 尚未初始化完成，暂时视为正式
  end
  local has_core = caps.hoverProvider
    or caps.definitionProvider
    or caps.referencesProvider
    or caps.documentFormattingProvider
    or caps.codeActionProvider
    or caps.completionProvider
    or caps.documentSymbolProvider
    or caps.workspaceSymbolProvider
    or caps.implementationProvider
    or caps.declarationProvider
    or caps.renameProvider
    or caps.typeDefinitionProvider
    or caps.signatureHelpProvider
  if not has_core and caps.inlineCompletionProvider then
    return false
  end
  return true
end

--- 检查 LSP 客户端是否支持悬停(大多数 LSP 操作的基础能力)
--- 若 server_capabilities 为 nil(尚未完成初始化)，返回 true 以避免过滤掉刚启动的客户端
--- @param client table LSP 客户端
--- @return boolean
function M.client_has_required_capabilities(client)
  local caps = client.server_capabilities
  if not caps then
    return true
  end
  local has_hover = caps.hoverProvider == true or (type(caps.hoverProvider) == "table")
  return has_hover
end

-- ================================================================
-- 文件缓冲区管理
-- ================================================================

--- 确保文件已加载到 Neovim 缓冲区
--- 返回 bufnr, cleanup 函数。若文件之前不在缓冲区，cleanup 会关闭它
--- @param filepath string 文件路径
--- @return integer bufnr
--- @return function cleanup
--- @return nil
function M.ensure_buf_loaded(filepath)
  local abs_path = vim.fn.fnamemodify(filepath, ":p")
  local bufnr = vim.fn.bufnr(abs_path)
  local was_loaded = true

  if bufnr == -1 then
    bufnr = vim.fn.bufadd(abs_path)
    vim.fn.bufload(bufnr)
    was_loaded = false
  end

  local function cleanup()
    if not was_loaded and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end

  return bufnr, cleanup
end

return M
