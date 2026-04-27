-- Neovim LSP 操作工具模块
-- 提供 LSP 核心操作：悬停文档、跳转定义、查找引用、重命名、格式化、诊断等
-- 每个工具的定义（名称、描述、参数、实现）集中在一起，方便修改
-- 仅在 Neovim >= 0.5 且 LSP 客户端可用时自动启用
local M = {}

local define_tool = require("NeoAI.tools.builtin.tool_helpers").define_tool

-- 检查 LSP 是否可用
local lsp_available = false

-- LSP 符号类型名称映射（兼容 Neovim 0.12，该版本没有 vim.lsp.symbol_kind_name）
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

local function safe_symbol_kind_name(kind)
  if type(kind) ~= "number" then
    return tostring(kind or "Unknown")
  end
  -- 优先使用 Neovim 内置函数（如果存在）
  local ok, result = pcall(vim.lsp.symbol_kind_name, kind)
  if ok and result then
    return result
  end
  -- 回退到本地映射表
  return symbol_kind_names[kind] or ("Symbol_" .. kind)
end

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

-- 确保文件已加载到缓冲区，返回 bufnr 和清理函数
-- 如果文件之前不在缓冲区，加载后返回的 cleanup 会关闭它
-- 如果文件已在缓冲区，cleanup 为空操作
local function ensure_buf_loaded(filepath)
  local abs_path = vim.fn.fnamemodify(filepath, ":p")
  local bufnr = vim.fn.bufnr(abs_path)
  local was_loaded = true

  if bufnr == -1 then
    -- 文件不在缓冲区，加载它
    bufnr = vim.fn.bufadd(abs_path)
    vim.fn.bufload(bufnr)
    was_loaded = false
  end

  -- 返回清理函数：如果是我们加载的临时缓冲区，关闭它
  local function cleanup()
    if not was_loaded and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end

  return bufnr, cleanup, nil
end

-- 检查 LSP 客户端是否支持格式化和悬停（本模块所需的核心能力）
local function client_has_required_capabilities(client)
  local caps = client.server_capabilities
  if not caps then
    return false
  end
  -- 需要同时支持格式化（documentFormattingProvider）和悬停（hoverProvider）
  local has_format = caps.documentFormattingProvider == true or (type(caps.documentFormattingProvider) == "table")
  local has_hover = caps.hoverProvider == true or (type(caps.hoverProvider) == "table")
  return has_format and has_hover
end

-- 从客户端列表中过滤出支持格式化和悬停的客户端
local function filter_qualified_clients(clients)
  if not clients then
    return {}
  end
  local qualified = {}
  for _, client in ipairs(clients) do
    if client_has_required_capabilities(client) then
      table.insert(qualified, client)
    end
  end
  return qualified
end

-- 等待 LSP 客户端通过 LspAttach 事件 attach 到缓冲区
-- 使用 vim.wait 处理事件循环，最多等待 timeout_ms 毫秒
-- 返回过滤后的客户端列表，或 nil
-- 注意：LspAttach 回调中会筛选客户端，只有支持格式化和悬停的客户端才触发 done=true
local function wait_for_lsp_attach(bufnr, timeout_ms)
  timeout_ms = timeout_ms or 5000
  local clients = nil
  local done = false

  -- 先检查当前是否已有合格的客户端已 attach
  clients = filter_qualified_clients(vim.lsp.get_clients({ bufnr = bufnr }))
  if clients and #clients > 0 then
    return clients
  end

  -- 创建一次性 autocmd 监听 LspAttach
  -- 在回调中筛选：只有支持格式化和悬停的客户端才触发 done=true
  -- 这样可以避免 GitHub Copilot 等不支持的客户端触发回调
  local augroup = vim.api.nvim_create_augroup("NeoAILspWait_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("LspAttach", {
    group = augroup,
    buffer = bufnr,
    once = true,
    callback = function(args)
      -- 获取触发事件的客户端
      local client = vim.lsp.get_client_by_id(args.data and args.data.client_id)
      if client and client_has_required_capabilities(client) then
        done = true
      end
    end,
  })

  -- 等待事件或超时
  vim.wait(timeout_ms, function()
    return done
  end, 50)

  -- 清理 autocmd
  pcall(vim.api.nvim_del_augroup_by_id, augroup)

  -- 再次检查客户端
  clients = filter_qualified_clients(vim.lsp.get_clients({ bufnr = bufnr }))
  if clients and #clients > 0 then
    return clients
  end

  -- 也检查全局客户端
  local all_clients = vim.lsp.get_clients()
  if all_clients and #all_clients > 0 then
    for _, client in ipairs(all_clients) do
      if client_has_required_capabilities(client) then
        local ok = pcall(vim.lsp.buf_attach_client, bufnr, client.id)
        if ok then
          vim.wait(200)
          clients = filter_qualified_clients(vim.lsp.get_clients({ bufnr = bufnr }))
          if clients and #clients > 0 then
            return clients
          end
        end
      end
    end
  end

  return nil
end

-- 获取文件对应的 LSP 客户端
-- 只返回同时支持格式化（formatting）和悬停（hover）的客户端
-- 如果文件没有关联的客户端，尝试通过 LspAttach 事件等待或直接启动
-- 返回 clients, err, bufnr, cleanup
local function get_lsp_clients(filepath)
  local bufnr, cleanup, err = ensure_buf_loaded(filepath)
  if err then
    return nil, err, nil, nil
  end

  -- 第一步：直接查找已 attach 到该缓冲区的客户端
  local clients = filter_qualified_clients(vim.lsp.get_clients({ bufnr = bufnr }))
  if clients and #clients > 0 then
    return clients, nil, bufnr, cleanup
  end

  -- 第二步：通过 LspAttach 事件等待 LSP 客户端 attach（最多 5 秒）
  clients = wait_for_lsp_attach(bufnr, 5000)
  if clients then
    return clients, nil, bufnr, cleanup
  end

  -- 第三步：尝试通过文件类型推断并启动 LSP 服务器
  -- 优先使用用户配置的 LSP 系统（如 lsp/init.lua 中的 start_server_with_config）
  local abs_path = vim.fn.fnamemodify(filepath, ":p")
  local ft = vim.filetype.match({ filename = abs_path })
  if ft then
    local ft_to_lsp_config = {
      lua = "lua_ls",
      python = "pyright",
      javascript = "ts_ls",
      typescript = "ts_ls",
      javascriptreact = "ts_ls",
      typescriptreact = "ts_ls",
      go = "gopls",
      rust = "rust_analyzer",
      java = "jdtls",
      c = "clangd",
      cpp = "clangd",
      ruby = "solargraph",
      php = "intelephense",
      json = "jsonls",
      yaml = "yamlls",
      markdown = "marksman",
      bash = "bashls",
      sh = "bashls",
      zsh = "bashls",
      css = "cssls",
      html = "htmlls",
      vue = "volar",
      svelte = "svelte",
    }
    local config_name = ft_to_lsp_config[ft]
    if config_name then
      -- 方式 A：尝试通过用户配置的 LSP 系统启动（如 lsp/init.lua 中的 start_server_with_config）
      -- 查找用户配置模块中是否有 start_server_with_config 函数
      local user_lsp_ok, user_lsp = pcall(require, "lsp")
      if user_lsp_ok and user_lsp.start_server_with_config then
        local ok = user_lsp.start_server_with_config(config_name, bufnr)
        if ok then
          clients = wait_for_lsp_attach(bufnr, 5000)
          if clients then
            return clients, nil, bufnr, cleanup
          end
        end
      end

      -- 方式 B：检查配置是否已通过 vim.lsp.config 注册
      local configs = rawget(vim.lsp.config, "_configs")
      if configs and configs[config_name] then
        local ok, client_id = pcall(vim.lsp.start, config_name)
        if ok and client_id then
          clients = wait_for_lsp_attach(bufnr, 3000)
          if clients then
            return clients, nil, bufnr, cleanup
          end
        end
      end

      -- 方式 C：直接启动 LSP 服务器
      local default_cmds = {
        lua_ls = { "lua-language-server" },
        pyright = { "pyright-langserver", "--stdio" },
        ts_ls = { "typescript-language-server", "--stdio" },
        html = { "vscode-html-language-server", "--stdio" },
        cssls = { "vscode-css-language-server", "--stdio" },
        jsonls = { "vscode-json-language-server", "--stdio" },
        yamlls = { "yaml-language-server", "--stdio" },
        bashls = { "bash-language-server", "start" },
        clangd = { "clangd" },
        gopls = { "gopls" },
        rust_analyzer = { "rust-analyzer" },
      }
      local cmd = default_cmds[config_name]
      if cmd then
        local lsp_config = {
          name = config_name,
          cmd = cmd,
          root_dir = vim.fn.getcwd(),
        }
        local ok, client_id = pcall(vim.lsp.start, lsp_config)
        if ok and client_id then
          clients = wait_for_lsp_attach(bufnr, 5000)
          if clients then
            return clients, nil, bufnr, cleanup
          end
        end
      end
    end
  end

  if cleanup then
    cleanup()
  end
  return nil,
    "文件 '" .. filepath .. "' 没有关联的 LSP 客户端（需要同时支持格式化和悬停功能）",
    nil,
    nil
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

  -- 需要跳过的节点类型（注释、字符串等，不包含有效符号）
  local skip_types = {
    comment = true,
    string = true,
    string_literal = true,
    line_comment = true,
    block_comment = true,
  }

  -- 递归遍历查找匹配的节点
  -- 跳过根节点（如 chunk、program），因为根节点包含整个文件内容
  local root_types = { chunk = true, program = true }

  -- 检查符号名是否包含 '.'（如 "M.setup"、"table.insert"）
  local symbol_parts = {}
  local is_dotted = false
  if symbol_name:find(".", 1, true) then
    is_dotted = true
    for part in symbol_name:gmatch("[^.]+") do
      table.insert(symbol_parts, part)
    end
  end

  local function search_node(node, depth, max_depth)
    if not node or (max_depth and depth > max_depth) then
      return nil
    end

    -- 跳过根节点类型，避免根节点包含整个文件内容导致返回 (0,0)
    if root_types[node:type()] then
      -- 直接搜索子节点
      for i = 0, node:named_child_count() - 1 do
        local child = node:named_child(i)
        local r, c = search_node(child, depth + 1, max_depth)
        if r then
          return r, c
        end
      end
      return nil
    end

    -- 跳过注释和字符串节点
    if skip_types[node:type()] then
      return nil
    end

    local text = vim.treesitter.get_node_text(node, content)
    local node_type_match = true
    if node_type and node:type() ~= node_type then
      node_type_match = false
    end

    if node_type_match and text then
      -- 策略一：精确匹配（text == symbol_name）
      if text == symbol_name then
        -- 查找子节点中精确匹配符号名的 identifier 节点
        for i = 0, node:named_child_count() - 1 do
          local child = node:named_child(i)
          local child_text = vim.treesitter.get_node_text(child, content)
          if child_text == symbol_name then
            local sr, sc = child:range()
            return sr, sc
          end
        end
        local sr, sc = node:range()
        return sr, sc
      end

      -- 策略二：子串匹配（text 包含 symbol_name）
      if text:find(symbol_name, 1, true) then
        -- 优先查找子节点中精确匹配符号名的 identifier 节点
        for i = 0, node:named_child_count() - 1 do
          local child = node:named_child(i)
          local child_text = vim.treesitter.get_node_text(child, content)
          if child_text == symbol_name then
            local sr, sc = child:range()
            return sr, sc
          end
        end
        -- 如果没有找到精确匹配的子节点，返回当前节点的起始位置
        local sr, sc = node:range()
        return sr, sc
      end

      -- 策略三：带点符号名匹配（如 "M.setup" 匹配 field 节点 "M.setup"）
      if is_dotted and text == symbol_parts[#symbol_parts] then
        -- 当前节点文本等于最后一部分（如 "setup"），向上检查父节点链
        -- 对于 field 节点如 "M.setup"，子节点是 "M" 和 "setup"
        -- 我们直接检查当前节点的父节点是否包含完整的点号表达式
        local parent = node:parent()
        if parent then
          local parent_text = vim.treesitter.get_node_text(parent, content)
          if parent_text == symbol_name then
            local sr, sc = node:range()
            return sr, sc
          end
        end
      end
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

  local row, col = search_node(root, 0, 50)
  if not row then
    return nil, "未找到符号 '" .. symbol_name .. "' 在文件中的位置"
  end

  return row, col
end

-- 执行 LSP 请求并等待结果
-- 使用 Neovim 0.12 的 buf_request_sync，单次请求，超时 3 秒
local function lsp_request(bufnr, method, params)
  local ok, responses = pcall(vim.lsp.buf_request_sync, bufnr, method, params, 3000)
  if ok and responses then
    for _, response in pairs(responses) do
      if type(response) == "table" and response.result ~= nil then
        return response.result
      end
    end
  end
  return nil
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

  local clients, err, bufnr, cleanup = get_lsp_clients(args.filepath)
  if err then
    return { filepath = args.filepath, error = err }
  end

  -- 通过符号名称定位
  local row, col
  if args.symbol then
    row, col = find_symbol_position(args.filepath, args.symbol, args.node_type)
    if not row then
      if cleanup then
        cleanup()
      end
      return { filepath = args.filepath, error = "未找到符号 '" .. args.symbol .. "' 在文件中的位置" }
    end
  else
    if cleanup then
      cleanup()
    end
    return { error = "需要 symbol（符号名称）参数来定位" }
  end

  local result = lsp_request(bufnr, "textDocument/hover", {
    textDocument = { uri = vim.uri_from_fname(vim.fn.fnamemodify(args.filepath, ":p")) },
    position = { line = row, character = col },
  })

  if cleanup then
    cleanup()
  end

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

  local clients, err, bufnr, cleanup = get_lsp_clients(args.filepath)
  if err then
    return { filepath = args.filepath, error = err }
  end

  local row, col
  if args.symbol then
    row, col = find_symbol_position(args.filepath, args.symbol, args.node_type)
    if not row then
      if cleanup then
        cleanup()
      end
      return { filepath = args.filepath, error = "未找到符号 '" .. args.symbol .. "' 在文件中的位置" }
    end
  else
    if cleanup then
      cleanup()
    end
    return { error = "需要 symbol（符号名称）参数来定位" }
  end

  local result = lsp_request(bufnr, "textDocument/definition", {
    textDocument = { uri = vim.uri_from_fname(vim.fn.fnamemodify(args.filepath, ":p")) },
    position = { line = row, character = col },
  })

  if cleanup then
    cleanup()
  end

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

  local clients, err, bufnr, cleanup = get_lsp_clients(args.filepath)
  if err then
    return { filepath = args.filepath, error = err }
  end

  local row, col
  if args.symbol then
    row, col = find_symbol_position(args.filepath, args.symbol, args.node_type)
    if not row then
      if cleanup then
        cleanup()
      end
      return { filepath = args.filepath, error = "未找到符号 '" .. args.symbol .. "' 在文件中的位置" }
    end
  else
    if cleanup then
      cleanup()
    end
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

  if cleanup then
    cleanup()
  end

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

  local clients, err, bufnr, cleanup = get_lsp_clients(args.filepath)
  if err then
    return { filepath = args.filepath, error = err }
  end

  local row, col
  if args.symbol then
    row, col = find_symbol_position(args.filepath, args.symbol, args.node_type)
    if not row then
      if cleanup then
        cleanup()
      end
      return { filepath = args.filepath, error = "未找到符号 '" .. args.symbol .. "' 在文件中的位置" }
    end
  else
    if cleanup then
      cleanup()
    end
    return { error = "需要 symbol（符号名称）参数来定位" }
  end

  local result = lsp_request(bufnr, "textDocument/implementation", {
    textDocument = { uri = vim.uri_from_fname(vim.fn.fnamemodify(args.filepath, ":p")) },
    position = { line = row, character = col },
  })

  if cleanup then
    cleanup()
  end

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

  local clients, err, bufnr, cleanup = get_lsp_clients(args.filepath)
  if err then
    return { filepath = args.filepath, error = err }
  end

  local row, col
  if args.symbol then
    row, col = find_symbol_position(args.filepath, args.symbol, args.node_type)
    if not row then
      if cleanup then
        cleanup()
      end
      return { filepath = args.filepath, error = "未找到符号 '" .. args.symbol .. "' 在文件中的位置" }
    end
  else
    if cleanup then
      cleanup()
    end
    return { error = "需要 symbol（符号名称）参数来定位" }
  end

  local result = lsp_request(bufnr, "textDocument/declaration", {
    textDocument = { uri = vim.uri_from_fname(vim.fn.fnamemodify(args.filepath, ":p")) },
    position = { line = row, character = col },
  })

  if cleanup then
    cleanup()
  end

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

  local clients, err, bufnr, cleanup = get_lsp_clients(args.filepath)
  if err then
    return { filepath = args.filepath, error = err }
  end

  local result = lsp_request(bufnr, "textDocument/documentSymbol", {
    textDocument = { uri = vim.uri_from_fname(vim.fn.fnamemodify(args.filepath, ":p")) },
  })

  if cleanup then
    cleanup()
  end

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
        kind_name = safe_symbol_kind_name(sym.kind),
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

  -- 需要 filepath 来获取已 attach 的客户端
  if not args.filepath then
    return { error = "需要 filepath（文件路径）参数来定位 LSP 客户端" }
  end

  local clients, err, bufnr, cleanup = get_lsp_clients(args.filepath)
  if err then
    return { filepath = args.filepath, error = err }
  end

  -- 对每个客户端发送 workspace/symbol 请求
  local all_symbols = {}
  for _, client in ipairs(clients) do
    if client.server_capabilities and client.server_capabilities.workspaceSymbolProvider then
      local result = lsp_request(bufnr, "workspace/symbol", { query = args.query })
      if result and #result > 0 then
        for _, sym in ipairs(result) do
          table.insert(all_symbols, {
            name = sym.name,
            kind = sym.kind,
            kind_name = safe_symbol_kind_name(sym.kind),
            location = sym.location,
            container_name = sym.containerName,
          })
        end
      end
    end
  end

  if cleanup then
    cleanup()
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
      filepath = { type = "string", description = "文件路径，用于定位 LSP 客户端" },
    },
    required = { "query", "filepath" },
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

  local clients, err, bufnr, cleanup = get_lsp_clients(args.filepath)
  if err then
    return { filepath = args.filepath, error = err }
  end

  -- 通过符号名称定位
  local row, col
  if args.symbol then
    row, col = find_symbol_position(args.filepath, args.symbol, args.node_type)
    if not row then
      if cleanup then
        cleanup()
      end
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

  if cleanup then
    cleanup()
  end

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
  description = "获取文件中指定符号位置的 LSP 代码操作建议（如自动修复、重构等），通过符号名称定位，返回操作标题和类型列表。注意：通常仅在文件有诊断信息（错误/警告）的位置才会有代码操作建议，无诊断的位置可能返回空结果。",
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

  local clients, err, bufnr, cleanup = get_lsp_clients(args.filepath)
  if err then
    return { filepath = args.filepath, error = err }
  end

  local row, col
  if args.symbol then
    row, col = find_symbol_position(args.filepath, args.symbol, args.node_type)
    if not row then
      if cleanup then
        cleanup()
      end
      return { filepath = args.filepath, error = "未找到符号 '" .. args.symbol .. "' 在文件中的位置" }
    end
  else
    if cleanup then
      cleanup()
    end
    return { error = "需要 symbol（符号名称）参数来定位要重命名的符号" }
  end

  local result = lsp_request(bufnr, "textDocument/rename", {
    textDocument = { uri = vim.uri_from_fname(vim.fn.fnamemodify(args.filepath, ":p")) },
    position = { line = row, character = col },
    newName = args.new_name,
  })

  if cleanup then
    cleanup()
  end

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

  local clients, err, bufnr, cleanup = get_lsp_clients(args.filepath)
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

  if cleanup then
    cleanup()
  end

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

  local bufnr, cleanup, err = ensure_buf_loaded(args.filepath)
  if err then
    return { filepath = args.filepath, error = err }
  end

  local diagnostics = vim.diagnostic.get(bufnr, {
    severity = args.severity and { min = args.severity },
  })

  if cleanup then
    cleanup()
  end

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

-- 判断 LSP 客户端是否功能完整（至少支持一项核心语义功能）
-- 排除仅支持 inline_completion 的客户端（如 GitHub Copilot）
local function is_client_functionally_complete(client)
  local caps = client.server_capabilities
  if not caps then
    return false
  end
  -- 核心语义功能列表：只要支持其中任意一项就认为是功能完整的客户端
  local core_capabilities = {
    caps.hoverProvider,
    caps.definitionProvider,
    caps.referencesProvider,
    caps.documentFormattingProvider,
    caps.codeActionProvider,
    caps.completionProvider,
    caps.signatureHelpProvider,
    caps.documentSymbolProvider,
    caps.workspaceSymbolProvider,
    caps.implementationProvider,
    caps.declarationProvider,
    caps.typeDefinitionProvider,
    caps.renameProvider,
  }
  for _, cap in ipairs(core_capabilities) do
    if cap == true or type(cap) == "table" then
      return true
    end
  end
  return false
end

local function _lsp_client_info(args)
  if not check_lsp() then
    return { error = "LSP 不可用" }
  end

  local clients = vim.lsp.get_clients()
  if not clients or #clients == 0 then
    return { error = "没有活跃的 LSP 客户端" }
  end

  local client_list = {}
  local filtered_count = 0
  for _, client in ipairs(clients) do
    -- 过滤掉功能不完整的客户端（如仅支持 inline_completion 的 GitHub Copilot）
    if not is_client_functionally_complete(client) then
      filtered_count = filtered_count + 1
    else
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
          inline_completion = client.server_capabilities.inlineCompletionProvider,
          document_color = client.server_capabilities.colorProvider,
          semantic_tokens = client.server_capabilities.semanticTokensProvider,
        },
      }
      table.insert(client_list, info)
    end
  end

  return {
    client_count = #client_list,
    filtered_count = filtered_count,
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

  local clients, err, bufnr, cleanup = get_lsp_clients(args.filepath)
  if err then
    return { filepath = args.filepath, error = err }
  end

  local row, col
  if args.symbol then
    row, col = find_symbol_position(args.filepath, args.symbol, args.node_type)
    if not row then
      if cleanup then
        cleanup()
      end
      return { filepath = args.filepath, error = "未找到符号 '" .. args.symbol .. "' 在文件中的位置" }
    end
  else
    if cleanup then
      cleanup()
    end
    return { error = "需要 symbol（符号名称）参数来定位" }
  end

  local result = lsp_request(bufnr, "textDocument/signatureHelp", {
    textDocument = { uri = vim.uri_from_fname(vim.fn.fnamemodify(args.filepath, ":p")) },
    position = { line = row, character = col },
  })

  if cleanup then
    cleanup()
  end

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
  description = "获取文件中指定符号的 LSP 签名帮助信息（函数参数提示），通过符号名称定位，返回参数列表和文档。注意：符号名必须在函数调用位置（如 `foo(` 或 `obj.method(`），而非定义位置（如 `function foo()`），否则 LSP 无法返回签名信息。",
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

  local clients, err, bufnr, cleanup = get_lsp_clients(args.filepath)
  if err then
    return { filepath = args.filepath, error = err }
  end

  local row, col
  if args.symbol then
    row, col = find_symbol_position(args.filepath, args.symbol, args.node_type)
    if not row then
      if cleanup then
        cleanup()
      end
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

  if cleanup then
    cleanup()
  end

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

  local clients, err, bufnr, cleanup = get_lsp_clients(args.filepath)
  if err then
    return { filepath = args.filepath, error = err }
  end

  local row, col
  if args.symbol then
    row, col = find_symbol_position(args.filepath, args.symbol, args.node_type)
    if not row then
      if cleanup then
        cleanup()
      end
      return { filepath = args.filepath, error = "未找到符号 '" .. args.symbol .. "' 在文件中的位置" }
    end
  else
    if cleanup then
      cleanup()
    end
    return { error = "需要 symbol（符号名称）参数来定位" }
  end

  local result = lsp_request(bufnr, "textDocument/typeDefinition", {
    textDocument = { uri = vim.uri_from_fname(vim.fn.fnamemodify(args.filepath, ":p")) },
    position = { line = row, character = col },
  })

  if cleanup then
    cleanup()
  end

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
  description = "获取文件中指定符号的类型定义位置，通过符号名称和可选的节点类型定位，返回类型定义所在的文件和位置范围。注意：仅适用于有静态类型系统的语言（如 TypeScript、Java、Go），Lua、Python、JavaScript 等动态类型语言通常无法提供类型定义信息。",
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
