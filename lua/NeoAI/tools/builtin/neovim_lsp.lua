-- Neovim LSP 操作工具模块
-- 提供 LSP 核心操作：悬停文档、跳转定义、查找引用、重命名、格式化、诊断等
-- 每个工具的定义（名称、描述、参数、实现）集中在一起，方便修改
-- 仅在 Neovim >= 0.5 且 LSP 客户端可用时自动启用
local M = {}

local define_tool = require("NeoAI.tools.builtin.tool_helpers").define_tool

-- 检查 LSP 是否可用
local lsp_available = false

local function check_lsp()
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

-- 读取文件内容
local function read_file_content(filepath)
  local abs_path = vim.fn.fnamemodify(filepath, ":p")
  local file, err = io.open(abs_path, "r")
  if not file then
    return nil, "无法读取文件: " .. (err or "未知错误")
  end
  local content = file:read("*a")
  file:close()
  return content, nil
end

-- 获取当前缓冲区信息
local function get_buf_info(filepath)
  local abs_path = vim.fn.fnamemodify(filepath, ":p")
  local bufnr = vim.fn.bufnr(abs_path)
  if bufnr == -1 then
    return nil, "文件未在缓冲区中打开: " .. filepath
  end
  return bufnr, nil
end

-- 获取文件对应的 LSP 客户端
local function get_lsp_clients(filepath)
  local bufnr, err = get_buf_info(filepath)
  if err then
    return nil, err
  end
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if not clients or #clients == 0 then
    return nil, "文件 '" .. filepath .. "' 没有关联的 LSP 客户端"
  end
  return clients, nil, bufnr
end

-- 使用 Tree-sitter 在文件中查找符号位置
-- 返回 { row, col } 或 nil
local function find_symbol_position(filepath, symbol_name, node_type)
  local ok_ts, ts = pcall(require, "vim.treesitter")
  if not ok_ts then
    return nil, "Tree-sitter 不可用，无法定位符号"
  end

  local content, err = read_file_content(filepath)
  if not content then
    return nil, err
  end

  -- 推断语言
  local abs_path = vim.fn.fnamemodify(filepath, ":p")
  local ft = vim.filetype.match({ filename = abs_path })
  if not ft then
    return nil, "无法确定文件类型"
  end
  local ok_lang, lang = pcall(ts.language.get_lang, ft)
  if not ok_lang or not lang then
    return nil, "无法确定 Tree-sitter 语言"
  end

  local ok_parser, parser = pcall(ts.get_string_parser, content, lang)
  if not ok_parser or not parser then
    return nil, "无法创建解析器"
  end

  local ok_trees, trees = pcall(parser.parse, parser)
  if not ok_trees or not trees or #trees == 0 then
    return nil, "解析失败"
  end

  local root = trees[1]:root()

  -- 递归遍历查找匹配的节点
  local function search_node(node, depth, max_depth)
    if not node or (max_depth and depth > max_depth) then
      return nil
    end

    local text = vim.treesitter.get_node_text(node, content)
    local node_type_match = true
    if node_type and node:type() ~= node_type then
      node_type_match = false
    end

    if node_type_match and text and text:find(symbol_name, 1, true) then
      local sr, sc = node:range()
      return sr, sc
    end

    -- 优先搜索命名子节点
    for i = 0, node:named_child_count() - 1 do
      local child = node:named_child(i)
      local r, c = search_node(child, depth + 1, max_depth)
      if r then
        return r, c
      end
    end

    return nil
  end

  local row, col = search_node(root, 0, 10)
  if not row then
    return nil, "未找到符号 '" .. symbol_name .. "' 在文件中的位置"
  end

  return row, col
end

-- 使用 Tree-sitter 在文件中查找所有匹配符号的位置
local function find_all_symbol_positions(filepath, symbol_name, node_type)
  local ok_ts, ts = pcall(require, "vim.treesitter")
  if not ok_ts then
    return nil, "Tree-sitter 不可用，无法定位符号"
  end

  local content, err = read_file_content(filepath)
  if not content then
    return nil, err
  end

  local abs_path = vim.fn.fnamemodify(filepath, ":p")
  local ft = vim.filetype.match({ filename = abs_path })
  if not ft then
    return nil, "无法确定文件类型"
  end
  local ok_lang, lang = pcall(ts.language.get_lang, ft)
  if not ok_lang or not lang then
    return nil, "无法确定 Tree-sitter 语言"
  end

  local ok_parser, parser = pcall(ts.get_string_parser, content, lang)
  if not ok_parser or not parser then
    return nil, "无法创建解析器"
  end

  local ok_trees, trees = pcall(parser.parse, parser)
  if not ok_trees or not trees or #trees == 0 then
    return nil, "解析失败"
  end

  local root = trees[1]:root()
  local positions = {}

  local function search_node(node, depth, max_depth)
    if not node or (max_depth and depth > max_depth) then
      return
    end

    local text = vim.treesitter.get_node_text(node, content)
    local node_type_match = true
    if node_type and node:type() ~= node_type then
      node_type_match = false
    end

    if node_type_match and text and text:find(symbol_name, 1, true) then
      local sr, sc = node:range()
      table.insert(positions, { row = sr, col = sc, text = text, type = node:type() })
    end

    for i = 0, node:named_child_count() - 1 do
      local child = node:named_child(i)
      search_node(child, depth + 1, max_depth)
    end
  end

  search_node(root, 0, 10)

  if #positions == 0 then
    return nil, "未找到符号 '" .. symbol_name .. "' 在文件中的位置"
  end

  return positions
end

-- 执行 LSP 请求并等待结果
local function lsp_request(bufnr, method, params)
  local result = nil
  local done = false

  vim.lsp.buf_request(bufnr, method, params, function(err, res, ctx)
    if not err then
      result = res
    end
    done = true
  end)

  -- 等待结果（最多 5 秒）
  local timeout = 5000
  local elapsed = 0
  while not done and elapsed < timeout do
    vim.wait(50)
    elapsed = elapsed + 50
  end

  return result
end
-- ============================================================================
-- 工具 lsp_hover - 悬浮显示符号文档
-- ============================================================================

local function _lsp_hover(args)
  if not check_lsp() then
    return { error = "LSP 不可用" }
  end

  if not args or not args.filepath then
    return { error = "需要 filepath（文件路径）参数" }
  end

  local clients, err, bufnr = get_lsp_clients(args.filepath)
  if err then
    return { filepath = args.filepath, error = err }
  end

  -- 通过符号名称定位
  local row, col
  if args.symbol then
    row, col = find_symbol_position(args.filepath, args.symbol, args.node_type)
    if not row then
      return { filepath = args.filepath, error = "未找到符号 '" .. args.symbol .. "' 在文件中的位置" }
    end
  else
    return { error = "需要 symbol（符号名称）参数来定位" }
  end

  local result = lsp_request(bufnr, "textDocument/hover", {
    textDocument = { uri = vim.uri_from_fname(vim.fn.fnamemodify(args.filepath, ":p")) },
    position = { line = row, character = col },
  })

  if not result then
    return { filepath = args.filepath, error = "未找到符号 '" .. args.symbol .. "' 的悬停信息" }
  end

  return {
    filepath = args.filepath,
    symbol = args.symbol,
    position = { row = row, col = col },
    contents = result.contents,
    range = result.range,
  }
end

M.lsp_hover = define_tool({
  name = "lsp_hover",
  description = "获取文件中指定符号的 LSP 悬停信息（函数/变量说明文档），通过符号名称和可选的节点类型定位",
  func = _lsp_hover,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      symbol = { type = "string", description = "符号名称，如函数名、变量名" },
      node_type = {
        type = "string",
        description = "节点类型过滤（可选），如 'function_definition'、'identifier'",
      },
    },
    required = { "filepath", "symbol" },
  },
  returns = {
    type = "object",
    description = "悬停信息，包含文档内容和位置范围",
  },
  category = "lsp",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 lsp_definition - 跳转到定义
-- ============================================================================

local function _lsp_definition(args)
  if not check_lsp() then
    return { error = "LSP 不可用" }
  end

  if not args or not args.filepath then
    return { error = "需要 filepath（文件路径）参数" }
  end

  local clients, err, bufnr = get_lsp_clients(args.filepath)
  if err then
    return { filepath = args.filepath, error = err }
  end

  local row, col
  if args.symbol then
    row, col = find_symbol_position(args.filepath, args.symbol, args.node_type)
    if not row then
      return { filepath = args.filepath, error = "未找到符号 '" .. args.symbol .. "' 在文件中的位置" }
    end
  else
    return { error = "需要 symbol（符号名称）参数来定位" }
  end

  local result = lsp_request(bufnr, "textDocument/definition", {
    textDocument = { uri = vim.uri_from_fname(vim.fn.fnamemodify(args.filepath, ":p")) },
    position = { line = row, character = col },
  })

  if not result or #result == 0 then
    return { filepath = args.filepath, error = "未找到符号 '" .. args.symbol .. "' 的定义" }
  end

  local locations = {}
  for _, loc in ipairs(result) do
    table.insert(locations, {
      uri = loc.uri or loc.targetUri,
      filename = loc.filename or (loc.uri and vim.uri_to_fname(loc.uri)),
      range = loc.range or loc.targetRange,
    })
  end

  return {
    filepath = args.filepath,
    symbol = args.symbol,
    position = { row = row, col = col },
    locations = locations,
  }
end

M.lsp_definition = define_tool({
  name = "lsp_definition",
  description = "获取文件中指定符号的定义位置，通过符号名称和可选的节点类型定位，返回定义所在的文件和位置范围",
  func = _lsp_definition,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      symbol = { type = "string", description = "符号名称，如函数名、变量名" },
      node_type = {
        type = "string",
        description = "节点类型过滤（可选），如 'function_definition'、'identifier'",
      },
    },
    required = { "filepath", "symbol" },
  },
  returns = {
    type = "object",
    description = "定义位置信息列表",
  },
  category = "lsp",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 lsp_references - 查找所有引用
-- ============================================================================

local function _lsp_references(args)
  if not check_lsp() then
    return { error = "LSP 不可用" }
  end

  if not args or not args.filepath then
    return { error = "需要 filepath（文件路径）参数" }
  end

  local clients, err, bufnr = get_lsp_clients(args.filepath)
  if err then
    return { filepath = args.filepath, error = err }
  end

  local row, col
  if args.symbol then
    row, col = find_symbol_position(args.filepath, args.symbol, args.node_type)
    if not row then
      return { filepath = args.filepath, error = "未找到符号 '" .. args.symbol .. "' 在文件中的位置" }
    end
  else
    return { error = "需要 symbol（符号名称）参数来定位" }
  end

  local include_declaration = true
  if args.include_declaration ~= nil then
    include_declaration = args.include_declaration
  end

  local result = lsp_request(bufnr, "textDocument/references", {
    textDocument = { uri = vim.uri_from_fname(vim.fn.fnamemodify(args.filepath, ":p")) },
    position = { line = row, character = col },
    context = { includeDeclaration = include_declaration },
  })

  if not result or #result == 0 then
    return { filepath = args.filepath, error = "未找到符号 '" .. args.symbol .. "' 的引用" }
  end

  local references = {}
  for _, ref in ipairs(result) do
    table.insert(references, {
      uri = ref.uri,
      filename = ref.filename or (ref.uri and vim.uri_to_fname(ref.uri)),
      range = ref.range,
    })
  end

  return {
    filepath = args.filepath,
    symbol = args.symbol,
    position = { row = row, col = col },
    reference_count = #references,
    references = references,
  }
end

M.lsp_references = define_tool({
  name = "lsp_references",
  description = "获取文件中指定符号的所有引用位置，通过符号名称和可选的节点类型定位，返回引用列表",
  func = _lsp_references,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      symbol = { type = "string", description = "符号名称，如函数名、变量名" },
      node_type = {
        type = "string",
        description = "节点类型过滤（可选），如 'function_definition'、'identifier'",
      },
      include_declaration = {
        type = "boolean",
        description = "是否包含声明位置（可选，默认 true）",
      },
    },
    required = { "filepath", "symbol" },
  },
  returns = {
    type = "object",
    description = "引用位置信息列表",
  },
  category = "lsp",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 lsp_implementation - 查看实现位置
-- ============================================================================

local function _lsp_implementation(args)
  if not check_lsp() then
    return { error = "LSP 不可用" }
  end

  if not args or not args.filepath then
    return { error = "需要 filepath（文件路径）参数" }
  end

  local clients, err, bufnr = get_lsp_clients(args.filepath)
  if err then
    return { filepath = args.filepath, error = err }
  end

  local row, col
  if args.symbol then
    row, col = find_symbol_position(args.filepath, args.symbol, args.node_type)
    if not row then
      return { filepath = args.filepath, error = "未找到符号 '" .. args.symbol .. "' 在文件中的位置" }
    end
  else
    return { error = "需要 symbol（符号名称）参数来定位" }
  end

  local result = lsp_request(bufnr, "textDocument/implementation", {
    textDocument = { uri = vim.uri_from_fname(vim.fn.fnamemodify(args.filepath, ":p")) },
    position = { line = row, character = col },
  })

  if not result or #result == 0 then
    return { filepath = args.filepath, error = "未找到符号 '" .. args.symbol .. "' 的实现" }
  end

  local locations = {}
  for _, loc in ipairs(result) do
    table.insert(locations, {
      uri = loc.uri,
      filename = loc.filename or (loc.uri and vim.uri_to_fname(loc.uri)),
      range = loc.range,
    })
  end

  return {
    filepath = args.filepath,
    symbol = args.symbol,
    position = { row = row, col = col },
    locations = locations,
  }
end

M.lsp_implementation = define_tool({
  name = "lsp_implementation",
  description = "获取文件中指定符号的实现位置，通过符号名称和可选的节点类型定位，返回实现所在的文件和位置范围",
  func = _lsp_implementation,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      symbol = { type = "string", description = "符号名称，如函数名、变量名" },
      node_type = {
        type = "string",
        description = "节点类型过滤（可选），如 'function_definition'、'identifier'",
      },
    },
    required = { "filepath", "symbol" },
  },
  returns = {
    type = "object",
    description = "实现位置信息列表",
  },
  category = "lsp",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 lsp_declaration - 查看声明位置
-- ============================================================================

local function _lsp_declaration(args)
  if not check_lsp() then
    return { error = "LSP 不可用" }
  end

  if not args or not args.filepath then
    return { error = "需要 filepath（文件路径）参数" }
  end

  local clients, err, bufnr = get_lsp_clients(args.filepath)
  if err then
    return { filepath = args.filepath, error = err }
  end

  local row, col
  if args.symbol then
    row, col = find_symbol_position(args.filepath, args.symbol, args.node_type)
    if not row then
      return { filepath = args.filepath, error = "未找到符号 '" .. args.symbol .. "' 在文件中的位置" }
    end
  else
    return { error = "需要 symbol（符号名称）参数来定位" }
  end

  local result = lsp_request(bufnr, "textDocument/declaration", {
    textDocument = { uri = vim.uri_from_fname(vim.fn.fnamemodify(args.filepath, ":p")) },
    position = { line = row, character = col },
  })

  if not result or #result == 0 then
    return { filepath = args.filepath, error = "未找到符号 '" .. args.symbol .. "' 的声明" }
  end

  local locations = {}
  for _, loc in ipairs(result) do
    table.insert(locations, {
      uri = loc.uri,
      filename = loc.filename or (loc.uri and vim.uri_to_fname(loc.uri)),
      range = loc.range,
    })
  end

  return {
    filepath = args.filepath,
    symbol = args.symbol,
    position = { row = row, col = col },
    locations = locations,
  }
end

M.lsp_declaration = define_tool({
  name = "lsp_declaration",
  description = "获取文件中指定符号的声明位置，通过符号名称和可选的节点类型定位，返回声明所在的文件和位置范围",
  func = _lsp_declaration,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      symbol = { type = "string", description = "符号名称，如函数名、变量名" },
      node_type = {
        type = "string",
        description = "节点类型过滤（可选），如 'function_definition'、'identifier'",
      },
    },
    required = { "filepath", "symbol" },
  },
  returns = {
    type = "object",
    description = "声明位置信息列表",
  },
  category = "lsp",
  permissions = { read = true },
})
-- ============================================================================
-- 工具 lsp_document_symbols - 获取文档符号列表
-- ============================================================================

local function _lsp_document_symbols(args)
  if not check_lsp() then
    return { error = "LSP 不可用" }
  end

  if not args or not args.filepath then
    return { error = "需要 filepath（文件路径）参数" }
  end

  local clients, err, bufnr = get_lsp_clients(args.filepath)
  if err then
    return { filepath = args.filepath, error = err }
  end

  local result = lsp_request(bufnr, "textDocument/documentSymbol", {
    textDocument = { uri = vim.uri_from_fname(vim.fn.fnamemodify(args.filepath, ":p")) },
  })

  if not result or #result == 0 then
    return { filepath = args.filepath, error = "未找到文档符号" }
  end

  local function flatten_symbols(symbols, depth)
    depth = depth or 0
    local flat = {}
    for _, sym in ipairs(symbols) do
      local entry = {
        name = sym.name,
        kind = sym.kind,
        kind_name = vim.lsp.symbol_kind_name(sym.kind),
        range = sym.range,
        selection_range = sym.selectionRange,
        detail = sym.detail,
        depth = depth,
      }
      table.insert(flat, entry)
      if sym.children and #sym.children > 0 then
        local children = flatten_symbols(sym.children, depth + 1)
        for _, child in ipairs(children) do
          table.insert(flat, child)
        end
      end
    end
    return flat
  end

  local symbols = flatten_symbols(result)

  return {
    filepath = args.filepath,
    symbol_count = #symbols,
    symbols = symbols,
  }
end

M.lsp_document_symbols = define_tool({
  name = "lsp_document_symbols",
  description = "获取文件中所有符号（变量、函数、类等）的列表，返回符号名称、类型和位置范围",
  func = _lsp_document_symbols,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
    },
    required = { "filepath" },
  },
  returns = {
    type = "object",
    description = "文档符号列表",
  },
  category = "lsp",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 lsp_workspace_symbols - 搜索工作区符号
-- ============================================================================

local function _lsp_workspace_symbols(args)
  if not check_lsp() then
    return { error = "LSP 不可用" }
  end

  if not args or not args.query then
    return { error = "需要 query（查询字符串）参数" }
  end

  local clients = vim.lsp.get_clients()
  if not clients or #clients == 0 then
    return { error = "没有活跃的 LSP 客户端" }
  end

  -- 对每个客户端发送 workspace/symbol 请求
  local all_symbols = {}
  for _, client in ipairs(clients) do
    if client.server_capabilities and client.server_capabilities.workspaceSymbolProvider then
      local result = lsp_request(0, "workspace/symbol", { query = args.query })
      if result and #result > 0 then
        for _, sym in ipairs(result) do
          table.insert(all_symbols, {
            name = sym.name,
            kind = sym.kind,
            kind_name = vim.lsp.symbol_kind_name(sym.kind),
            location = sym.location,
            container_name = sym.containerName,
          })
        end
      end
    end
  end

  if #all_symbols == 0 then
    return { error = "未找到匹配工作区符号: " .. args.query }
  end

  return {
    query = args.query,
    symbol_count = #all_symbols,
    symbols = all_symbols,
  }
end

M.lsp_workspace_symbols = define_tool({
  name = "lsp_workspace_symbols",
  description = "在工作区中搜索符号（函数、类、变量等），返回匹配的符号列表及其位置",
  func = _lsp_workspace_symbols,
  parameters = {
    type = "object",
    properties = {
      query = { type = "string", description = "符号名称查询字符串，支持模糊匹配" },
    },
    required = { "query" },
  },
  returns = {
    type = "object",
    description = "工作区符号搜索结果",
  },
  category = "lsp",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 lsp_code_action - 获取代码修复建议
-- ============================================================================

local function _lsp_code_action(args)
  if not check_lsp() then
    return { error = "LSP 不可用" }
  end

  if not args or not args.filepath then
    return { error = "需要 filepath（文件路径）参数" }
  end

  local clients, err, bufnr = get_lsp_clients(args.filepath)
  if err then
    return { filepath = args.filepath, error = err }
  end

  -- 通过符号名称定位
  local row, col
  if args.symbol then
    row, col = find_symbol_position(args.filepath, args.symbol, args.node_type)
    if not row then
      return { filepath = args.filepath, error = "未找到符号 '" .. args.symbol .. "' 在文件中的位置" }
    end
  else
    row = 0
    col = 0
  end

  -- 获取该位置的诊断信息（用于 code action context）
  local diagnostics = {}
  if args.include_diagnostics ~= false then
    diagnostics = vim.diagnostic.get(bufnr, { lnum = row })
  end

  local result = lsp_request(bufnr, "textDocument/codeAction", {
    textDocument = { uri = vim.uri_from_fname(vim.fn.fnamemodify(args.filepath, ":p")) },
    range = {
      start = { line = row, character = col },
      ["end"] = { line = row, character = col + 1 },
    },
    context = {
      diagnostics = diagnostics,
      only = args.only,
    },
  })

  if not result or #result == 0 then
    return { filepath = args.filepath, error = "未找到该位置的代码操作" }
  end

  local actions = {}
  for _, action in ipairs(result) do
    table.insert(actions, {
      title = action.title,
      kind = action.kind,
      is_preferred = action.isPreferred,
    })
  end

  return {
    filepath = args.filepath,
    symbol = args.symbol,
    action_count = #actions,
    actions = actions,
  }
end

M.lsp_code_action = define_tool({
  name = "lsp_code_action",
  description = "获取文件中指定符号位置的 LSP 代码操作建议（如自动修复、重构等），通过符号名称定位，返回操作标题和类型列表",
  func = _lsp_code_action,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      symbol = { type = "string", description = "符号名称（可选），不指定则从文件开头查找" },
      node_type = { type = "string", description = "节点类型过滤（可选）" },
      only = {
        type = "array",
        items = { type = "string" },
        description = "仅返回指定类型的代码操作（可选），如 'refactor.extract.function'",
      },
      include_diagnostics = {
        type = "boolean",
        description = "是否包含诊断信息作为上下文（可选，默认 true）",
      },
    },
    required = { "filepath" },
  },
  returns = {
    type = "object",
    description = "代码操作建议列表",
  },
  category = "lsp",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 lsp_rename - 重命名符号
-- ============================================================================

local function _lsp_rename(args)
  if not check_lsp() then
    return { error = "LSP 不可用" }
  end

  if not args or not args.filepath then
    return { error = "需要 filepath（文件路径）参数" }
  end

  if not args.new_name then
    return { error = "需要 new_name（新名称）参数" }
  end

  local clients, err, bufnr = get_lsp_clients(args.filepath)
  if err then
    return { filepath = args.filepath, error = err }
  end

  local row, col
  if args.symbol then
    row, col = find_symbol_position(args.filepath, args.symbol, args.node_type)
    if not row then
      return { filepath = args.filepath, error = "未找到符号 '" .. args.symbol .. "' 在文件中的位置" }
    end
  else
    return { error = "需要 symbol（符号名称）参数来定位要重命名的符号" }
  end

  local result = lsp_request(bufnr, "textDocument/rename", {
    textDocument = { uri = vim.uri_from_fname(vim.fn.fnamemodify(args.filepath, ":p")) },
    position = { line = row, character = col },
    newName = args.new_name,
  })

  return {
    filepath = args.filepath,
    symbol = args.symbol,
    new_name = args.new_name,
    changes = result and result.changes,
  }
end

M.lsp_rename = define_tool({
  name = "lsp_rename",
  description = "重命名文件中指定符号，通过符号名称定位，返回重命名影响的所有文件变更",
  func = _lsp_rename,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      symbol = { type = "string", description = "要重命名的符号名称" },
      new_name = { type = "string", description = "新名称" },
      node_type = { type = "string", description = "节点类型过滤（可选）" },
    },
    required = { "filepath", "symbol", "new_name" },
  },
  returns = {
    type = "object",
    description = "重命名结果，包含所有受影响的文件变更",
  },
  category = "lsp",
  permissions = { write = true },
})

-- ============================================================================
-- 工具 lsp_format - 格式化代码
-- ============================================================================

local function _lsp_format(args)
  if not check_lsp() then
    return { error = "LSP 不可用" }
  end

  if not args or not args.filepath then
    return { error = "需要 filepath（文件路径）参数" }
  end

  local clients, err, bufnr = get_lsp_clients(args.filepath)
  if err then
    return { filepath = args.filepath, error = err }
  end

  local options = {}
  if args.tab_size then
    options.tabSize = args.tab_size
  end
  if args.insert_spaces ~= nil then
    options.insertSpaces = args.insert_spaces
  end

  local result = lsp_request(bufnr, "textDocument/formatting", {
    textDocument = { uri = vim.uri_from_fname(vim.fn.fnamemodify(args.filepath, ":p")) },
    options = options,
  })

  if not result or #result == 0 then
    return { filepath = args.filepath, error = "格式化失败或无变更" }
  end

  -- 读取格式化后的内容
  local content, _ = read_file_content(args.filepath)

  return {
    filepath = args.filepath,
    formatted = true,
    content = content,
  }
end

M.lsp_format = define_tool({
  name = "lsp_format",
  description = "使用 LSP 格式化指定文件中的代码，支持设置缩进大小和空格/制表符偏好",
  func = _lsp_format,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      tab_size = { type = "number", description = "缩进大小（可选）" },
      insert_spaces = { type = "boolean", description = "是否使用空格缩进（可选）" },
    },
    required = { "filepath" },
  },
  returns = {
    type = "object",
    description = "格式化结果，包含格式化后的文件内容",
  },
  category = "lsp",
  permissions = { write = true },
})
-- ============================================================================
-- 工具 lsp_diagnostics - 获取诊断信息
-- ============================================================================

local function _lsp_diagnostics(args)
  if not check_lsp() then
    return { error = "LSP 不可用" }
  end

  if not args or not args.filepath then
    return { error = "需要 filepath（文件路径）参数" }
  end

  local bufnr, err = get_buf_info(args.filepath)
  if err then
    return { filepath = args.filepath, error = err }
  end

  local diagnostics = vim.diagnostic.get(bufnr, {
    severity = args.severity and { min = args.severity },
  })

  if not diagnostics or #diagnostics == 0 then
    return { filepath = args.filepath, diagnostic_count = 0, diagnostics = {} }
  end

  local results = {}
  for _, d in ipairs(diagnostics) do
    table.insert(results, {
      severity = d.severity,
      message = d.message,
      source = d.source,
      code = d.code,
      lnum = d.lnum,
      col = d.col,
      end_lnum = d.end_lnum,
      end_col = d.end_col,
    })
  end

  return {
    filepath = args.filepath,
    diagnostic_count = #results,
    diagnostics = results,
  }
end

M.lsp_diagnostics = define_tool({
  name = "lsp_diagnostics",
  description = "获取文件中所有 LSP 诊断信息（错误、警告、提示等），支持按严重程度过滤",
  func = _lsp_diagnostics,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      severity = {
        type = "number",
        description = "最低严重程度过滤（可选）：1=错误, 2=警告, 3=信息, 4=提示",
      },
    },
    required = { "filepath" },
  },
  returns = {
    type = "object",
    description = "诊断信息列表",
  },
  category = "lsp",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 lsp_client_info - 获取 LSP 客户端信息
-- ============================================================================

local function _lsp_client_info(args)
  if not check_lsp() then
    return { error = "LSP 不可用" }
  end

  local clients = vim.lsp.get_clients()
  if not clients or #clients == 0 then
    return { error = "没有活跃的 LSP 客户端" }
  end

  local client_list = {}
  for _, client in ipairs(clients) do
    local info = {
      name = client.name,
      id = client.id,
      root_dir = client.config and client.config.root_dir,
      capabilities = client.server_capabilities and {
        hover_provider = client.server_capabilities.hoverProvider,
        definition_provider = client.server_capabilities.definitionProvider,
        references_provider = client.server_capabilities.referencesProvider,
        rename_provider = client.server_capabilities.renameProvider,
        document_formatting_provider = client.server_capabilities.documentFormattingProvider,
        code_action_provider = client.server_capabilities.codeActionProvider,
        completion_provider = client.server_capabilities.completionProvider,
        signature_help_provider = client.server_capabilities.signatureHelpProvider,
        document_symbol_provider = client.server_capabilities.documentSymbolProvider,
        workspace_symbol_provider = client.server_capabilities.workspaceSymbolProvider,
        implementation_provider = client.server_capabilities.implementationProvider,
        declaration_provider = client.server_capabilities.declarationProvider,
        inline_completion = client.server_capabilities.inlineCompletion,
        document_color = client.server_capabilities.colorProvider,
        semantic_tokens = client.server_capabilities.semanticTokensProvider,
      },
    }
    table.insert(client_list, info)
  end

  return {
    client_count = #client_list,
    clients = client_list,
  }
end

M.lsp_client_info = define_tool({
  name = "lsp_client_info",
  description = "获取当前所有活跃的 LSP 客户端信息，包括名称、根目录、支持的能力列表",
  func = _lsp_client_info,
  parameters = {
    type = "object",
    properties = {},
  },
  returns = {
    type = "object",
    description = "LSP 客户端信息列表",
  },
  category = "lsp",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 lsp_signature_help - 获取签名帮助
-- ============================================================================

local function _lsp_signature_help(args)
  if not check_lsp() then
    return { error = "LSP 不可用" }
  end

  if not args or not args.filepath then
    return { error = "需要 filepath（文件路径）参数" }
  end

  local clients, err, bufnr = get_lsp_clients(args.filepath)
  if err then
    return { filepath = args.filepath, error = err }
  end

  local row, col
  if args.symbol then
    row, col = find_symbol_position(args.filepath, args.symbol, args.node_type)
    if not row then
      return { filepath = args.filepath, error = "未找到符号 '" .. args.symbol .. "' 在文件中的位置" }
    end
  else
    return { error = "需要 symbol（符号名称）参数来定位" }
  end

  local result = lsp_request(bufnr, "textDocument/signatureHelp", {
    textDocument = { uri = vim.uri_from_fname(vim.fn.fnamemodify(args.filepath, ":p")) },
    position = { line = row, character = col },
  })

  if not result then
    return { filepath = args.filepath, error = "未找到符号 '" .. args.symbol .. "' 的签名帮助" }
  end

  local signatures = {}
  for _, sig in ipairs(result.signatures or {}) do
    local params = {}
    for _, param in ipairs(sig.parameters or {}) do
      table.insert(params, {
        label = param.label,
        documentation = param.documentation,
      })
    end
    table.insert(signatures, {
      label = sig.label,
      documentation = sig.documentation,
      parameters = params,
      active_parameter = sig.activeParameter,
    })
  end

  return {
    filepath = args.filepath,
    symbol = args.symbol,
    position = { row = row, col = col },
    active_signature = result.activeSignature,
    active_parameter = result.activeParameter,
    signatures = signatures,
  }
end

M.lsp_signature_help = define_tool({
  name = "lsp_signature_help",
  description = "获取文件中指定符号的 LSP 签名帮助信息（函数参数提示），通过符号名称定位，返回参数列表和文档",
  func = _lsp_signature_help,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      symbol = { type = "string", description = "符号名称，如函数名" },
      node_type = { type = "string", description = "节点类型过滤（可选），如 'call_expression'" },
    },
    required = { "filepath", "symbol" },
  },
  returns = {
    type = "object",
    description = "签名帮助信息",
  },
  category = "lsp",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 lsp_completion - 获取补全建议
-- ============================================================================

local function _lsp_completion(args)
  if not check_lsp() then
    return { error = "LSP 不可用" }
  end

  if not args or not args.filepath then
    return { error = "需要 filepath（文件路径）参数" }
  end

  local clients, err, bufnr = get_lsp_clients(args.filepath)
  if err then
    return { filepath = args.filepath, error = err }
  end

  local row, col
  if args.symbol then
    row, col = find_symbol_position(args.filepath, args.symbol, args.node_type)
    if not row then
      return { filepath = args.filepath, error = "未找到符号 '" .. args.symbol .. "' 在文件中的位置" }
    end
  else
    row = 0
    col = 0
  end

  local result = lsp_request(bufnr, "textDocument/completion", {
    textDocument = { uri = vim.uri_from_fname(vim.fn.fnamemodify(args.filepath, ":p")) },
    position = { line = row, character = col },
    context = {
      triggerKind = args.trigger_kind or 1,
      triggerCharacter = args.trigger_character,
    },
  })

  if not result or not result.items or #result.items == 0 then
    return { filepath = args.filepath, error = "未找到该位置的补全建议" }
  end

  local items = {}
  for _, item in ipairs(result.items) do
    table.insert(items, {
      label = item.label,
      kind = item.kind,
      detail = item.detail,
      documentation = item.documentation,
      insert_text = item.insertText,
      insert_text_format = item.insertTextFormat,
    })
  end

  return {
    filepath = args.filepath,
    position = { row = row, col = col },
    is_incomplete = result.isIncomplete,
    item_count = #items,
    items = items,
  }
end

M.lsp_completion = define_tool({
  name = "lsp_completion",
  description = "获取文件中指定符号位置的 LSP 补全建议列表，通过符号名称定位，返回补全项标签、类型、文档和插入文本",
  func = _lsp_completion,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      symbol = { type = "string", description = "符号名称（可选），用于定位补全触发位置" },
      node_type = { type = "string", description = "节点类型过滤（可选）" },
      trigger_kind = {
        type = "number",
        description = "触发类型（可选）：1=手动触发, 2=触发字符, 3=不完整补全",
      },
      trigger_character = { type = "string", description = "触发字符（可选），如 '.'" },
    },
    required = { "filepath" },
  },
  returns = {
    type = "object",
    description = "补全建议列表",
  },
  category = "lsp",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 lsp_type_definition - 获取类型定义
-- ============================================================================

local function _lsp_type_definition(args)
  if not check_lsp() then
    return { error = "LSP 不可用" }
  end

  if not args or not args.filepath then
    return { error = "需要 filepath（文件路径）参数" }
  end

  local clients, err, bufnr = get_lsp_clients(args.filepath)
  if err then
    return { filepath = args.filepath, error = err }
  end

  local row, col
  if args.symbol then
    row, col = find_symbol_position(args.filepath, args.symbol, args.node_type)
    if not row then
      return { filepath = args.filepath, error = "未找到符号 '" .. args.symbol .. "' 在文件中的位置" }
    end
  else
    return { error = "需要 symbol（符号名称）参数来定位" }
  end

  local result = lsp_request(bufnr, "textDocument/typeDefinition", {
    textDocument = { uri = vim.uri_from_fname(vim.fn.fnamemodify(args.filepath, ":p")) },
    position = { line = row, character = col },
  })

  if not result or #result == 0 then
    return { filepath = args.filepath, error = "未找到符号 '" .. args.symbol .. "' 的类型定义" }
  end

  local locations = {}
  for _, loc in ipairs(result) do
    table.insert(locations, {
      uri = loc.uri,
      filename = loc.filename or (loc.uri and vim.uri_to_fname(loc.uri)),
      range = loc.range,
    })
  end

  return {
    filepath = args.filepath,
    symbol = args.symbol,
    position = { row = row, col = col },
    locations = locations,
  }
end

M.lsp_type_definition = define_tool({
  name = "lsp_type_definition",
  description = "获取文件中指定符号的类型定义位置，通过符号名称和可选的节点类型定位，返回类型定义所在的文件和位置范围",
  func = _lsp_type_definition,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      symbol = { type = "string", description = "符号名称，如变量名、函数名" },
      node_type = { type = "string", description = "节点类型过滤（可选）" },
    },
    required = { "filepath", "symbol" },
  },
  returns = {
    type = "object",
    description = "类型定义位置信息列表",
  },
  category = "lsp",
  permissions = { read = true },
})

-- get_tools() - 返回所有工具列表供注册
function M.get_tools()
  if not check_lsp() then
    return {}
  end

  local tools = {}
  for _, v in pairs(M) do
    if type(v) == "table" and v.name and v.func then
      table.insert(tools, v)
    end
  end
  table.sort(tools, function(a, b)
    return a.name < b.name
  end)
  return tools
end

return M
