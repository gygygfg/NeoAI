--- LSP 操作工具
--- @module NeoAI.tools.builtin.lsp_ops
--- 通过 Neovim 内置 LSP（vim.lsp）提供代码分析工具。

local helpers = require("NeoAI.tools.builtin.tool_helpers")
local async = require("NeoAI.utils.async")

local M = {}

-- ========== 私有函数 ==========

--- 通过文件路径获取 buffer
--- @param filepath string
--- @return number|nil bufnr
local function _bufnr(filepath)
  if not filepath or filepath == "" then
    return vim.api.nvim_get_current_buf()
  end
  local bufnr = vim.fn.bufnr(filepath)
  if bufnr < 0 then
    return nil
  end
  return bufnr
end

--- 获取文件或当前 buffer 的 LSP 客户端
--- @param filepath string|nil
--- @return table|nil client
local function _client_for(filepath)
  local bufnr = _bufnr(filepath)
  if not bufnr then return nil end
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if #clients == 0 then return nil end
  return clients[1]
end

--- 请求 + 等待结果的包装
--- @param method string
--- @param params table
--- @param bufnr number
--- @return Deferred
local function _request(method, params, bufnr)
  local d = async.Deferred.new()
  local called = false
  local ok, err = pcall(vim.lsp.buf_request, bufnr, method, params, function(err_resp, result)
    if called then return end
    called = true
    if err_resp and err_resp.code then
      d:reject({ kind = "lsp", code = err_resp.code, message = err_resp.message })
    else
      d:resolve(result)
    end
  end)
  if not ok then
    d:reject({ kind = "lsp", message = tostring(err) })
  end
  return d
end

--- 位置参数规范化
--- @param args table
--- @return number bufnr, number line, number col
local function _position(args)
  local bufnr = _bufnr(args.filepath)
  if not bufnr then return nil end
  local line = (args.line or 0) - 1 -- LSP 为 0-based
  local col = args.col or 0
  return bufnr, math.max(0, line), math.max(0, col)
end

-- ========== 工具定义 ==========

local lsp_tools = {}

--- 悬停信息
lsp_tools.lsp_hover = helpers.define_tool(
  "lsp_hover",
  "获取光标位置悬停信息。filepath/line/col 可选（默认当前）。",
  {
    type = "object",
    properties = {
      filepath = { type = "string" },
      line = { type = "integer" },
      col = { type = "integer" },
    },
    required = {},
  },
  function(args, on_success, on_error)
    local bufnr, line, col = _position(args)
    if not bufnr then on_error("无法找到文件 buffer") return end
    _request("textDocument/hover", { textDocument = { uri = vim.uri_from_bufnr(bufnr) }, position = { line = line, character = col } }, bufnr)
      :then_(function(result)
        if result and result.contents then
          local out = {}
          local contents = result.contents
          if type(contents) == "string" then
            out[1] = contents
          elseif type(contents) == "table" and contents.value then
            out[1] = contents.value
          elseif type(contents) == "table" then
            for _, c in ipairs(contents) do
              out[#out + 1] = type(c) == "table" and (c.value or "") or tostring(c)
            end
          end
          on_success(table.concat(out, "\n"))
        else
          on_success("无悬停信息")
        end
      end, function(e) on_error(e.message) end)
  end,
  { category = "lsp" }
)

--- 定义
lsp_tools.lsp_definition = helpers.define_tool(
  "lsp_definition",
  "获取符号定义位置。filepath/line/col 可选。",
  {
    type = "object",
    properties = { filepath = { type = "string" }, line = { type = "integer" }, col = { type = "integer" } },
    required = {},
  },
  function(args, on_success, on_error)
    local bufnr, line, col = _position(args)
    if not bufnr then on_error("无法找到文件 buffer") return end
    _request("textDocument/definition", { textDocument = { uri = vim.uri_from_bufnr(bufnr) }, position = { line = line, character = col } }, bufnr)
      :then_(function(locations)
        if not locations or #locations == 0 then on_success("未找到定义") return end
        local out = {}
        for _, loc in ipairs(locations) do
          out[#out + 1] = string.format("%s:%d:%d", loc.uri and vim.uri_to_fname(loc.uri) or "", (loc.range and loc.range.start.line or 0) + 1, (loc.range and loc.range.start.character or 0))
        end
        on_success(table.concat(out, "\n"))
      end, function(e) on_error(e.message) end)
  end,
  { category = "lsp" }
)

--- 引用
lsp_tools.lsp_references = helpers.define_tool(
  "lsp_references",
  "查找符号引用位置。filepath/line/col 可选。",
  {
    type = "object",
    properties = { filepath = { type = "string" }, line = { type = "integer" }, col = { type = "integer" } },
    required = {},
  },
  function(args, on_success, on_error)
    local bufnr, line, col = _position(args)
    if not bufnr then on_error("无法找到文件 buffer") return end
    _request("textDocument/references", { textDocument = { uri = vim.uri_from_bufnr(bufnr) }, position = { line = line, character = col } }, bufnr)
      :then_(function(locations)
        if not locations or #locations == 0 then on_success("未找到引用") return end
        local out = {}
        for _, loc in ipairs(locations) do
          out[#out + 1] = string.format("%s:%d:%d", vim.uri_to_fname(loc.uri), (loc.range and loc.range.start.line or 0) + 1, (loc.range and loc.range.start.character or 0))
        end
        on_success(table.concat(out, "\n"))
      end, function(e) on_error(e.message) end)
  end,
  { category = "lsp" }
)

--- 文档符号
lsp_tools.lsp_document_symbols = helpers.define_tool(
  "lsp_document_symbols",
  "获取文档内符号列表。filepath 可选。",
  {
    type = "object",
    properties = { filepath = { type = "string" } },
    required = {},
  },
  function(args, on_success, on_error)
    local bufnr = _bufnr(args.filepath)
    if not bufnr then on_error("无法找到文件 buffer") return end
    _request("textDocument/documentSymbol", { textDocument = { uri = vim.uri_from_bufnr(bufnr) } }, bufnr)
      :then_(function(symbols)
        if not symbols or #symbols == 0 then on_success("无符号") return end
        local out = {}
        local function walk(sym, depth)
          local name = sym.name or ""
          local kind = vim.lsp.protocol.SymbolKind[sym.kind] or tostring(sym.kind)
          out[#out + 1] = string.rep("  ", depth) .. name .. " (" .. kind .. ")"
          for _, child in ipairs(sym.children or {}) do walk(child, depth + 1) end
        end
        for _, sym in ipairs(symbols) do walk(sym, 0) end
        on_success(table.concat(out, "\n"))
      end, function(e) on_error(e.message) end)
  end,
  { category = "lsp" }
)

--- 工作区符号
lsp_tools.lsp_workspace_symbols = helpers.define_tool(
  "lsp_workspace_symbols",
  "搜索工作区符号。query 必填。",
  {
    type = "object",
    properties = { query = { type = "string" } },
    required = { "query" },
  },
  function(args, on_success, on_error)
    local bufnr = vim.api.nvim_get_current_buf()
    _request("workspace/symbol", { query = args.query }, bufnr)
      :then_(function(symbols)
        if not symbols or #symbols == 0 then on_success("无匹配符号") return end
        local out = {}
        for _, sym in ipairs(symbols) do
          out[#out + 1] = (sym.name or "") .. "  " .. (sym.location and vim.uri_to_fname(sym.location.uri) or "")
        end
        on_success(table.concat(out, "\n"))
      end, function(e) on_error(e.message) end)
  end,
  { category = "lsp" }
)

--- 诊断信息
lsp_tools.lsp_diagnostics = helpers.define_tool(
  "lsp_diagnostics",
  "获取文件诊断信息。filepath 可选。",
  {
    type = "object",
    properties = { filepath = { type = "string" } },
    required = {},
  },
  function(args, on_success, on_error)
    local bufnr = _bufnr(args.filepath)
    if not bufnr then on_error("无法找到文件 buffer") return end
    local diagnostics = vim.diagnostic.get(bufnr)
    if #diagnostics == 0 then on_success("无诊断信息") return end
    local out = {}
    for _, diag in ipairs(diagnostics) do
      local sev = vim.diagnostic.severity[diag.severity] or "?"
      out[#out + 1] = string.format("%s:%d %s: %s", args.filepath or "(当前)", diag.lnum + 1, sev, diag.message)
    end
    on_success(table.concat(out, "\n"))
  end,
  { category = "lsp" }
)

--- 客户端信息
lsp_tools.lsp_client_info = helpers.define_tool(
  "lsp_client_info",
  "获取 LSP 客户端信息。filepath 可选。",
  {
    type = "object",
    properties = { filepath = { type = "string" } },
    required = {},
  },
  function(args, on_success)
    local bufnr = _bufnr(args.filepath)
    local clients = vim.lsp.get_clients()
    local out = {}
    for _, c in ipairs(clients) do
      out[#out + 1] = string.format("%s (%s)%s", c.name, c.root_dir or "", (bufnr and vim.lsp.get_client_by_id(c.id) and " [active]" or ""))
    end
    on_success(#out > 0 and table.concat(out, "\n") or "无 LSP 客户端")
  end,
  { category = "lsp" }
)

--- 代码操作
lsp_tools.lsp_code_action = helpers.define_tool(
  "lsp_code_action",
  "获取代码操作建议。filepath/line/col 可选。",
  {
    type = "object",
    properties = { filepath = { type = "string" }, line = { type = "integer" }, col = { type = "integer" } },
    required = {},
  },
  function(args, on_success, on_error)
    local bufnr, line, col = _position(args)
    if not bufnr then on_error("无法找到文件 buffer") return end
    local range = { start = { line = line, character = col }, ["end"] = { line = line, character = col + 1 } }
    _request("textDocument/codeAction", { textDocument = { uri = vim.uri_from_bufnr(bufnr) }, range = range, context = { diagnostics = {} } }, bufnr)
      :then_(function(actions)
        if not actions or #actions == 0 then on_success("无代码操作") return end
        local out = {}
        for _, a in ipairs(actions) do
          out[#out + 1] = (a.title or a.kind or "action")
        end
        on_success(table.concat(out, "\n"))
      end, function(e) on_error(e.message) end)
  end,
  { category = "lsp" }
)

--- 重命名
lsp_tools.lsp_rename = helpers.define_tool(
  "lsp_rename",
  "重命名符号。filepath/line/col/new_name 必填。",
  {
    type = "object",
    properties = {
      filepath = { type = "string" }, line = { type = "integer" }, col = { type = "integer" },
      new_name = { type = "string" },
    },
    required = { "new_name" },
  },
  function(args, on_success, on_error)
    local bufnr, line, col = _position(args)
    if not bufnr then on_error("无法找到文件 buffer") return end
    _request("textDocument/rename", { textDocument = { uri = vim.uri_from_bufnr(bufnr) }, position = { line = line, character = col }, newName = args.new_name }, bufnr)
      :then_(function(edit)
        if edit and edit.changes then
          for uri, changes in pairs(edit.changes) do
            local b = vim.fn.bufnr(vim.uri_to_fname(uri))
            for _, ch in ipairs(changes) do
              pcall(vim.api.nvim_buf_set_text, b, ch.range.start.line, ch.range.start.character, ch.range["end"].line, ch.range["end"].character, vim.split(ch.newText, "\n", { plain = true }))
            end
          end
          on_success("重命名完成")
        else
          on_success("无重命名编辑")
        end
      end, function(e) on_error(e.message) end)
  end,
  { category = "lsp", approval = { auto_allow = false } }
)

--- 格式化
lsp_tools.lsp_format = helpers.define_tool(
  "lsp_format",
  "格式化文档。filepath 可选。",
  {
    type = "object",
    properties = { filepath = { type = "string" } },
    required = {},
  },
  function(args, on_success, on_error)
    local bufnr = _bufnr(args.filepath)
    if not bufnr then on_error("无法找到文件 buffer") return end
    _request("textDocument/formatting", { textDocument = { uri = vim.uri_from_bufnr(bufnr) }, options = { tabSize = 2, insertSpaces = true } }, bufnr)
      :then_(function(edits)
        if edits and #edits > 0 then
          for _, e in ipairs(edits) do
            pcall(vim.api.nvim_buf_set_text, bufnr, e.range.start.line, e.range.start.character, e.range["end"].line, e.range["end"].character, vim.split(e.newText, "\n", { plain = true }))
          end
          on_success("格式化完成")
        else
          on_success("无需格式化")
        end
      end, function(e) on_error(e.message) end)
  end,
  { category = "lsp", approval = { auto_allow = false } }
)

--- 签名帮助
lsp_tools.lsp_signature_help = helpers.define_tool(
  "lsp_signature_help",
  "获取函数签名。filepath/line/col 可选。",
  {
    type = "object",
    properties = { filepath = { type = "string" }, line = { type = "integer" }, col = { type = "integer" } },
    required = {},
  },
  function(args, on_success, on_error)
    local bufnr, line, col = _position(args)
    if not bufnr then on_error("无法找到文件 buffer") return end
    _request("textDocument/signatureHelp", { textDocument = { uri = vim.uri_from_bufnr(bufnr) }, position = { line = line, character = col } }, bufnr)
      :then_(function(result)
        if result and result.signatures and #result.signatures > 0 then
          local out = {}
          for _, s in ipairs(result.signatures) do
            out[#out + 1] = s.label or ""
          end
          on_success(table.concat(out, "\n"))
        else
          on_success("无签名信息")
        end
      end, function(e) on_error(e.message) end)
  end,
  { category = "lsp" }
)

--- 补全
lsp_tools.lsp_completion = helpers.define_tool(
  "lsp_completion",
  "获取补全建议。filepath/line/col 可选。",
  {
    type = "object",
    properties = { filepath = { type = "string" }, line = { type = "integer" }, col = { type = "integer" } },
    required = {},
  },
  function(args, on_success, on_error)
    local bufnr, line, col = _position(args)
    if not bufnr then on_error("无法找到文件 buffer") return end
    _request("textDocument/completion", { textDocument = { uri = vim.uri_from_bufnr(bufnr) }, position = { line = line, character = col } }, bufnr)
      :then_(function(result)
        local items = result and (result.items or result) or {}
        local out = {}
        for _, item in ipairs(items) do
          out[#out + 1] = item.label or ""
        end
        on_success(#out > 0 and table.concat(out, "\n") or "无补全建议")
      end, function(e) on_error(e.message) end)
  end,
  { category = "lsp" }
)

--- 类型定义
lsp_tools.lsp_type_definition = helpers.define_tool(
  "lsp_type_definition",
  "获取符号类型定义。filepath/line/col 可选。",
  {
    type = "object",
    properties = { filepath = { type = "string" }, line = { type = "integer" }, col = { type = "integer" } },
    required = {},
  },
  function(args, on_success, on_error)
    local bufnr, line, col = _position(args)
    if not bufnr then on_error("无法找到文件 buffer") return end
    _request("textDocument/typeDefinition", { textDocument = { uri = vim.uri_from_bufnr(bufnr) }, position = { line = line, character = col } }, bufnr)
      :then_(function(locations)
        if not locations or #locations == 0 then on_success("未找到类型定义") return end
        local out = {}
        for _, loc in ipairs(locations) do
          out[#out + 1] = string.format("%s:%d:%d", vim.uri_to_fname(loc.uri), (loc.range and loc.range.start.line or 0) + 1, loc.range and loc.range.start.character or 0)
        end
        on_success(table.concat(out, "\n"))
      end, function(e) on_error(e.message) end)
  end,
  { category = "lsp" }
)

--- 声明
lsp_tools.lsp_declaration = helpers.define_tool(
  "lsp_declaration",
  "获取符号声明位置。filepath/line/col 可选。",
  {
    type = "object",
    properties = { filepath = { type = "string" }, line = { type = "integer" }, col = { type = "integer" } },
    required = {},
  },
  function(args, on_success, on_error)
    local bufnr, line, col = _position(args)
    if not bufnr then on_error("无法找到文件 buffer") return end
    _request("textDocument/declaration", { textDocument = { uri = vim.uri_from_bufnr(bufnr) }, position = { line = line, character = col } }, bufnr)
      :then_(function(locations)
        if not locations or #locations == 0 then on_success("未找到声明") return end
        local out = {}
        for _, loc in ipairs(locations) do
          out[#out + 1] = string.format("%s:%d:%d", vim.uri_to_fname(loc.uri), (loc.range and loc.range.start.line or 0) + 1, loc.range and loc.range.start.character or 0)
        end
        on_success(table.concat(out, "\n"))
      end, function(e) on_error(e.message) end)
  end,
  { category = "lsp" }
)

--- 实现
lsp_tools.lsp_implementation = helpers.define_tool(
  "lsp_implementation",
  "获取符号实现位置。filepath/line/col 可选。",
  {
    type = "object",
    properties = { filepath = { type = "string" }, line = { type = "integer" }, col = { type = "integer" } },
    required = {},
  },
  function(args, on_success, on_error)
    local bufnr, line, col = _position(args)
    if not bufnr then on_error("无法找到文件 buffer") return end
    _request("textDocument/implementation", { textDocument = { uri = vim.uri_from_bufnr(bufnr) }, position = { line = line, character = col } }, bufnr)
      :then_(function(locations)
        if not locations or #locations == 0 then on_success("未找到实现") return end
        local out = {}
        for _, loc in ipairs(locations) do
          out[#out + 1] = string.format("%s:%d:%d", vim.uri_to_fname(loc.uri), (loc.range and loc.range.start.line or 0) + 1, loc.range and loc.range.start.character or 0)
        end
        on_success(table.concat(out, "\n"))
      end, function(e) on_error(e.message) end)
  end,
  { category = "lsp" }
)

--- 服务信息
lsp_tools.lsp_service_info = helpers.define_tool(
  "lsp_service_info",
  "获取 LSP 服务信息（客户端、根目录）。",
  {
    type = "object",
    properties = {},
    required = {},
  },
  function(args, on_success)
    local clients = vim.lsp.get_clients()
    local out = {}
    for _, c in ipairs(clients) do
      out[#out + 1] = string.format("%s  root=%s  name=%s", c.id, c.root_dir or "-", c.name)
    end
    on_success(#out > 0 and table.concat(out, "\n") or "无 LSP 客户端")
  end,
  { category = "lsp" }
)

--- 获取工具列表
--- @return table 数组
function M.get_tools()
  local out = {}
  for _, tool in pairs(lsp_tools) do
    out[#out + 1] = tool
  end
  return out
end

return M
