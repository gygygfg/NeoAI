-- Tree-sitter 语法树工具模块
-- 提供语法解析、节点查询、代码结构分析等常用功能
-- 每个工具的定义（名称、描述、参数、实现）集中在一起，方便修改
-- 仅在 Neovim >= 0.5 且 Tree-sitter 可用时自动启用
local M = {}

local define_tool = require("NeoAI.tools.builtin.tool_helpers").define_tool

-- 检查 Tree-sitter 是否可用
local ts_available = false
---@class vim.treesitter
---@field language table<string, any>
---@field query table<string, any>
---@field get_string_parser fun(source: string, lang: string): table
local ts = nil

local function check_ts()
  if ts_available then
    return true
  end
  local ok, loaded = pcall(require, "vim.treesitter")
  if ok then
    ts = loaded
    ts_available = true
    return true
  end
  return false
end

-- 扩展名到 Tree-sitter 解析器名称的直接映射
-- 避免在 fast event 上下文中调用 vim.filetype.match（内部调用 getenv）
local ext_to_parser = {
  [".lua"] = "lua",
  [".py"] = "python",
  [".js"] = "javascript",
  [".ts"] = "typescript",
  [".jsx"] = "tsx",
  [".tsx"] = "tsx",
  [".go"] = "go",
  [".rs"] = "rust",
  [".java"] = "java",
  [".c"] = "c",
  [".cpp"] = "cpp",
  [".h"] = "c",
  [".hpp"] = "cpp",
  [".rb"] = "ruby",
  [".php"] = "php",
  [".json"] = "json",
  [".yaml"] = "yaml",
  [".yml"] = "yaml",
  [".md"] = "markdown",
  [".sh"] = "bash",
  [".bash"] = "bash",
  [".zsh"] = "bash",
  [".css"] = "css",
  [".html"] = "html",
  [".htm"] = "html",
  [".vue"] = "vue",
  [".svelte"] = "svelte",
  [".toml"] = "toml",
  [".sql"] = "sql",
  [".cmake"] = "cmake",
  [".mk"] = "make",
  [".query"] = "query",
  [".regex"] = "regex",
}

-- 从文件路径推断语言（使用扩展名映射，避免在 fast event 上下文中调用 vim.filetype.match）
-- 从文件路径推断 Tree-sitter 解析器名称（使用扩展名映射，避免在 fast event 中调用 vim.filetype.match）
local function detect_lang_from_filepath(filepath)
  local ext = vim.fn.fnamemodify(filepath, ":e")
  if ext and ext ~= "" then
    ext = "." .. ext:lower()
    local parser = ext_to_parser[ext]
    if parser then
      return parser
    end
  end

  -- 尝试匹配完整文件名（如 Makefile、Dockerfile）
  local basename = vim.fn.fnamemodify(filepath, ":t")
  if basename == "Makefile" then
    return "make"
  end
  if basename == "Dockerfile" or basename:match("^Dockerfile%.[a-zA-Z]+$") then
    return "dockerfile"
  end

  return nil
end

--- 检查并自动安装 Tree-sitter 解析器（回调模式）
--- 如果解析器未安装，尝试通过 nvim-treesitter 安装
--- @param lang string 语言名称
--- @param on_success function 安装成功或已存在时回调
--- @param on_error function 安装失败时回调
local function ensure_parser_installed(lang, on_success, on_error)
  -- 检查解析器是否已安装
  ---@diagnostic disable-next-line: need-check-nil
  local ok_inspect, _ = pcall(ts.language.inspect, lang)
  if ok_inspect then
    if on_success then
      on_success()
    end
    return
  end

  -- 尝试通过 nvim-treesitter 安装
  -- 优先使用 vim.treesitter.language.add（Neovim 0.12 内置 API）
  local has_language_add = pcall(function()
    return type(vim.treesitter.language.add) == "function"
  end)

  if has_language_add then
    -- 使用内置 API 添加/安装语言
    local ok_add, add_err = pcall(vim.treesitter.language.add, lang)
    if ok_add then
      -- 安装后再次检查
      ---@diagnostic disable-next-line: need-check-nil
      local ok2, _ = pcall(ts.language.inspect, lang)
      if ok2 then
        if on_success then
          on_success()
        end
        return
      end
    end
    -- 如果内置 API 失败，回退到命令方式
  end

  -- 尝试通过 :TSInstallSync 命令
  local has_ts_install = pcall(function()
    return vim.fn.exists(":TSInstallSync") == 2
  end)

  if has_ts_install then
    local ok, err = pcall(function()
      vim.cmd("TSInstallSync " .. lang)
    end)
    if ok then
      ---@diagnostic disable-next-line: need-check-nil
      local ok2, _ = pcall(ts.language.inspect, lang)
      if ok2 then
        if on_success then
          on_success()
        end
        return
      end
    end
    -- 失败，继续尝试其他方式
  end

  -- 尝试通过 :TSInstall 命令（异步）
  local has_ts_install_async = pcall(function()
    return vim.fn.exists(":TSInstall") == 2
  end)

  if has_ts_install_async then
    vim.cmd("TSInstall " .. lang)
    vim.defer_fn(function()
      ---@diagnostic disable-next-line: need-check-nil
      local ok2, _ = pcall(ts.language.inspect, lang)
      if ok2 then
        if on_success then
          on_success()
        end
      else
        -- 最后尝试使用内置 API 的 require 方式
        local ok_require, _ = pcall(function()
          require("vim.treesitter.language").add(lang)
        end)
        if ok_require then
          ---@diagnostic disable-next-line: need-check-nil
          local ok3, _ = pcall(ts.language.inspect, lang)
          if ok3 then
            if on_success then
              on_success()
            end
            return
          end
        end
        if on_error then
          on_error("Tree-sitter 解析器 " .. lang .. " 正在后台安装，请稍后重试")
        end
      end
    end, 3000)
    return
  end

  if on_error then
    on_error("未找到 nvim-treesitter 插件，无法自动安装解析器: " .. lang)
  end
end

-- 异步读取文件内容（回调模式）
-- 使用 vim.uv 异步 I/O，不阻塞主线程
local function read_file_content_async(filepath, on_success, on_error)
  local abs_path = vim.fn.fnamemodify(filepath, ":p")
  vim.uv.fs_open(abs_path, "r", 438, function(open_err, fd)
    if open_err or not fd then
      if on_error then
        on_error("无法读取文件: " .. (open_err or "未知错误"))
      end
      return
    end
    vim.uv.fs_fstat(fd, function(stat_err, stat)
      if stat_err or not stat then
        vim.uv.fs_close(fd)
        if on_error then
          on_error("无法读取文件: " .. (stat_err or "无法获取文件信息"))
        end
        return
      end
      vim.uv.fs_read(fd, stat.size, 0, function(read_err, data)
        vim.uv.fs_close(fd)
        if read_err or not data then
          if on_error then
            on_error("无法读取文件: " .. (read_err or "未知错误"))
          end
          return
        end
        if on_success then
          on_success(data)
        end
      end)
    end)
  end)
end

-- 公共节点过滤函数：支持正则匹配 text，node_type 不匹配时回退到同类型节点
-- 返回 filtered 和 fallback_used（是否使用了回退）
local function filter_nodes(nodes, args)
  local filtered = {}

  -- 第一轮：精确匹配所有条件
  for _, node in ipairs(nodes or {}) do
    local matched = true
    if args.node_type and node.type ~= args.node_type then
      matched = false
    end
    if matched and args.text ~= nil then
      -- 使用 Lua 的 string.find 做子串匹配（不区分大小写可选）
      if not node.text:find(args.text, 1, true) then
        matched = false
      end
    end
    if matched and args.named ~= nil and node.named ~= args.named then
      matched = false
    end
    if matched then
      table.insert(filtered, node)
    end
  end

  -- 如果指定了 node_type 但没有匹配到任何节点，回退到只按 text 和 named 过滤
  if #filtered == 0 and args.node_type then
    local fallback = {}
    for _, node in ipairs(nodes or {}) do
      local matched = true
      if args.text ~= nil then
        if not node.text:find(args.text, 1, true) then
          matched = false
        end
      end
      if matched and args.named ~= nil and node.named ~= args.named then
        matched = false
      end
      if matched then
        table.insert(fallback, node)
      end
    end
    if #fallback > 0 then
      return fallback, true
    end
  end

  return filtered, false
end

-- 递归遍历节点树，返回扁平化的节点信息列表
local function _traverse_node(node, source, depth, max_depth)
  if not node then
    return {}
  end

  local results = {}
  local sr, sc, er, ec = node:range()
  local text = vim.treesitter.get_node_text(node, source)

  table.insert(results, {
    type = node:type(),
    named = node:named(),
    start_row = sr,
    start_col = sc,
    end_row = er,
    end_col = ec,
    text = text,
    depth = depth,
  })

  if max_depth and max_depth >= 0 and depth >= max_depth then
    return results
  end

  local child_count = node:named_child_count()
  for i = 0, child_count - 1 do
    local child = node:named_child(i)
    local child_results = _traverse_node(child, source, depth + 1, max_depth)
    for _, r in ipairs(child_results) do
      table.insert(results, r)
    end
  end

  return results
end

-- 解析文件内容并返回语法树（回调模式）
-- 自动检测语言并安装缺失的解析器
-- 注意：read_file_content_async 的回调在 vim.uv fast event 上下文中执行，
-- 因此所有回调需要用 vim.schedule 切换到主线程
local function parse_file_content_async(filepath, max_depth, on_success, on_error)
  read_file_content_async(filepath, function(content)
    vim.schedule(function()
      local lang = detect_lang_from_filepath(filepath)
      if not lang then
        if on_error then
          on_error("无法确定文件语言")
        end
        return
      end

      -- 确保解析器已安装
      ensure_parser_installed(lang, function()
        ---@diagnostic disable-next-line: need-check-nil
        local ok, parser = pcall(ts.get_string_parser, content, lang)
        if not ok or not parser then
          if on_error then
            on_error("无法为语言 '" .. lang .. "' 创建解析器")
          end
          return
        end

        local ok2, trees = pcall(parser.parse, parser)
        if not ok2 or not trees or #trees == 0 then
          if on_error then
            on_error("解析失败")
          end
          return
        end

        local root = trees[1]:root()
        local nodes = _traverse_node(root, content, 0, max_depth or 3)

        if on_success then
          on_success({
            filepath = filepath,
            language = lang,
            line_count = #vim.split(content, "\n", { plain = true }),
            root_type = root:type(),
            node_count = #nodes,
            nodes = nodes,
          })
        end
      end, function(err)
        if on_error then
          on_error(err)
        end
      end)
    end)
  end, function(err)
    vim.schedule(function()
      if on_error then
        on_error(err)
      end
    end)
  end)
end

-- ============================================================================
-- 工具 parse_file - 解析文件并返回语法树（回调模式）
-- ============================================================================

local function _parse_file(args, on_success, on_error)
  if not check_ts() then
    if on_error then
      on_error("Tree-sitter 不可用（需要 Neovim >= 0.5）")
    end
    return
  end

  if not args then
    if on_error then
      on_error("需要参数")
    end
    return
  end

  local max_depth = args.max_depth or 3

  -- 处理 filepaths 列表
  if args.filepaths and #args.filepaths > 0 then
    local results = {}
    local pending = #args.filepaths
    local has_error = false

    local function check_done()
      if has_error then
        return
      end
      pending = pending - 1
      if pending <= 0 then
        if on_success then
          on_success(results)
        end
      end
    end

    for _, fp in ipairs(args.filepaths) do
      parse_file_content_async(fp, max_depth, function(r)
        table.insert(results, r)
        check_done()
      end, function(err)
        table.insert(results, { filepath = fp, error = err })
        check_done()
      end)
    end
    return
  end

  -- 处理单个 filepath
  if args.filepath then
    parse_file_content_async(args.filepath, max_depth, function(result)
      if on_success then
        on_success(result)
      end
    end, function(err)
      if on_error then
        on_error(err)
      end
    end)
    return
  end

  if on_error then
    on_error("需要 filepath（文件路径）或 filepaths（路径列表）参数")
  end
end

M.parse_file = define_tool({
  name = "parse_file",
  description = "解析文件并返回 Tree-sitter 语法树节点信息，支持 filepath（单个文件路径）和 filepaths（路径列表）参数。如果解析器未安装，会自动尝试安装。",
  func = _parse_file,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      filepaths = {
        type = "array",
        items = { type = "string" },
        description = "文件路径列表，批量解析多个文件的语法树",
      },
      max_depth = {
        type = "number",
        description = "最大遍历深度（默认 3，设为 -1 表示不限）",
        default = 3,
      },
    },
  },
  returns = {
    type = "object",
    description = "单个文件的语法树信息，或路径列表时返回数组",
  },
  category = "treesitter",
  permissions = { read = true },
  approval = { behavior = "auto_approve" },
})

-- ============================================================================
-- 工具 query_tree - 使用查询模式捕获节点（回调模式）
-- ============================================================================

local function _query_tree_for_source(source_text, lang, query_string)
  ---@diagnostic disable-next-line: need-check-nil
  local ok, query = pcall(ts.query.parse, lang, query_string)
  if not ok then
    return nil, "查询语法错误: " .. tostring(query)
  end

  ---@diagnostic disable-next-line: need-check-nil
  local ok2, parser = pcall(ts.get_string_parser, source_text, lang)
  if not ok2 or not parser then
    return nil, "无法为语言 '" .. lang .. "' 创建解析器"
  end

  local ok3, trees = pcall(parser.parse, parser)
  if not ok3 or not trees or #trees == 0 then
    return nil, "解析失败"
  end

  local root = trees[1]:root()

  local captures = {}
  local ok4, iter = pcall(query.iter_captures, query, root, source_text, 0, -1)
  if not ok4 then
    return nil, "迭代捕获失败: " .. tostring(iter)
  end

  for capture_id, node, metadata in iter do
    local text = vim.treesitter.get_node_text(node, source_text)
    local sr, sc, er, ec = node:range()
    table.insert(captures, {
      capture_id = capture_id,
      node_type = node:type(),
      text = text,
      start_row = sr,
      start_col = sc,
      end_row = er,
      end_col = ec,
      named = node:named(),
    })
  end

  return {
    language = lang,
    query = query_string,
    capture_count = #captures,
    captures = captures,
  },
    nil
end

local function _query_tree(args, on_success, on_error)
  if not check_ts() then
    if on_error then
      on_error("Tree-sitter 不可用（需要 Neovim >= 0.5）")
    end
    return
  end

  if not args or not args.query or not args.filepath then
    if on_error then
      on_error("需要 query（查询字符串）和 filepath（文件路径）参数")
    end
    return
  end

  local query_string = args.query

  read_file_content_async(args.filepath, function(content)
    local lang = detect_lang_from_filepath(args.filepath)
    if not lang then
      if on_error then
        on_error("无法确定文件语言")
      end
      return
    end

    ensure_parser_installed(lang, function()
      local result, qerr = _query_tree_for_source(content, lang, query_string)
      if qerr then
        if on_error then
          on_error(qerr)
        end
        return
      end
      result.filepath = args.filepath
      if on_success then
        on_success(result)
      end
    end, function(err)
      if on_error then
        on_error(err)
      end
    end)
  end, function(err)
    if on_error then
      on_error(err)
    end
  end)
end

M.query_tree = define_tool({
  name = "query_tree",
  description = "使用 Tree-sitter 查询模式捕获文件中语法树节点，支持自定义查询字符串。如果解析器未安装，会自动尝试安装。",
  func = _query_tree,
  async = true,
  parameters = {
    type = "object",
    properties = {
      query = { type = "string", description = "Tree-sitter 查询字符串，如 '((function_definition) @func)'" },
      filepath = { type = "string", description = "文件路径" },
    },
    required = { "query", "filepath" },
  },
  returns = {
    type = "object",
    description = "查询捕获结果",
  },
  category = "treesitter",
  permissions = { read = true },
  approval = { behavior = "auto_approve" },
})

-- ============================================================================
-- 工具 get_node_at_position - 获取文件中指定位置的语法树节点（回调模式）
-- ============================================================================

local function _get_node_at_position(args, on_success, on_error)
  if not check_ts() then
    if on_error then
      on_error("Tree-sitter 不可用（需要 Neovim >= 0.5）")
    end
    return
  end

  if not args or not args.filepath then
    if on_error then
      on_error("需要 filepath（文件路径）参数")
    end
    return
  end

  local filepath = args.filepath
  local target_row = args.row or 0
  local target_col = args.col or 0

  read_file_content_async(filepath, function(content)
    local lang = detect_lang_from_filepath(filepath)
    if not lang then
      if on_error then
        on_error("无法确定文件语言")
      end
      return
    end

    ensure_parser_installed(lang, function()
      ---@diagnostic disable-next-line: need-check-nil
      local ok, parser = pcall(ts.get_string_parser, content, lang)
      if not ok or not parser then
        if on_error then
          on_error("无法为语言 '" .. lang .. "' 创建解析器")
        end
        return
      end

      local ok2, trees = pcall(parser.parse, parser)
      if not ok2 or not trees or #trees == 0 then
        if on_error then
          on_error("解析失败")
        end
        return
      end

      local root = trees[1]:root()

      -- 在语法树中查找指定位置的节点
      local function find_node_at_pos(node, r, c)
        if not node then
          return nil
        end
        local sr, sc, er, ec = node:range()
        if r >= sr and r <= er and (r > sr or c >= sc) and (r < er or c <= ec) then
          for i = 0, node:named_child_count() - 1 do
            local child = node:named_child(i)
            local found = find_node_at_pos(child, r, c)
            if found then
              return found
            end
          end
          return node
        end
        return nil
      end

      local target_node = find_node_at_pos(root, target_row, target_col)
      if not target_node then
        if on_error then
          on_error("未找到该位置的节点")
        end
        return
      end

      local text = vim.treesitter.get_node_text(target_node, content)
      local sr, sc, er, ec = target_node:range()

      -- 获取父节点链
      local ancestors = {}
      local current = target_node:parent()
      while current do
        table.insert(ancestors, {
          type = current:type(),
          text = vim.treesitter.get_node_text(current, content),
        })
        current = current:parent()
      end

      -- 获取子节点
      local children = {}
      local child_count = target_node:named_child_count()
      for i = 0, child_count - 1 do
        local child = target_node:named_child(i)
        table.insert(children, {
          type = child:type(),
          text = vim.treesitter.get_node_text(child, content),
        })
      end

      if on_success then
        on_success({
          filepath = filepath,
          position = { row = target_row, col = target_col },
          node = {
            type = target_node:type(),
            text = text,
            named = target_node:named(),
            start_row = sr,
            start_col = sc,
            end_row = er,
            end_col = ec,
          },
          ancestors = ancestors,
          children = children,
        })
      end
    end, function(err)
      if on_error then
        on_error(err)
      end
    end)
  end, function(err)
    if on_error then
      on_error(err)
    end
  end)
end

M.get_node_at_position = define_tool({
  name = "get_node_at_position",
  description = "获取文件中指定位置（行、列）的 Tree-sitter 语法树节点，包含父节点链和子节点信息。如果解析器未安装，会自动尝试安装。",
  func = _get_node_at_position,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      row = { type = "number", description = "行号（0-based，默认 0）" },
      col = { type = "number", description = "列号（0-based，默认 0）" },
    },
    required = { "filepath" },
  },
  returns = {
    type = "object",
    description = "节点信息，包含父节点链和子节点",
  },
  category = "treesitter",
  permissions = { read = true },
  approval = { behavior = "auto_approve" },
})

-- ============================================================================
-- 辅助函数：在 parse_file_content_async 回调中处理过滤和响应
-- 所有 get_node_* 工具共享此模式
-- ============================================================================

--- 在 parse_file_content_async 回调中执行过滤并返回结果
--- @param args table 工具参数
--- @param on_success function 成功回调
--- @param on_error function 失败回调
--- @param build_response function 构建响应函数 (result, filtered, fallback) -> table
local function _with_parsed_tree(args, on_success, on_error, build_response)
  if not check_ts() then
    if on_error then
      on_error("Tree-sitter 不可用（需要 Neovim >= 0.5）")
    end
    return
  end
  if not args or not args.filepath then
    if on_error then
      on_error("需要 filepath（文件路径）参数")
    end
    return
  end

  parse_file_content_async(args.filepath, -1, function(result)
    local filtered, fallback = filter_nodes(result.nodes, args)
    if #filtered == 0 then
      if on_error then
        on_error("未找到匹配的节点")
      end
      return
    end
    local ret = build_response(result, filtered, fallback)
    if on_success then
      on_success(ret)
    end
  end, function(err)
    if on_error then
      on_error(err or "解析结果为空")
    end
  end)
end

-- ============================================================================
-- 工具 get_node_type - 获取节点类型（回调模式）
-- ============================================================================

local function _get_node_type(args, on_success, on_error)
  _with_parsed_tree(args, on_success, on_error, function(result, filtered, fallback)
    local types = {}
    local seen = {}
    for _, node in ipairs(filtered) do
      if not seen[node.type] then
        seen[node.type] = true
        table.insert(types, node.type)
      end
    end
    local ret = {
      filepath = args.filepath,
      language = result.language,
      match_count = #filtered,
      node_types = types,
      nodes = filtered,
    }
    if fallback then
      ret.warning = "未找到指定 node_type '"
        .. (args.node_type or "")
        .. "' 的节点，已回退到同类型节点"
    end
    return ret
  end)
end

M.get_node_type = define_tool({
  name = "get_node_type",
  description = "获取文件中匹配节点的类型信息，支持按 node_type、text、named 属性过滤。如果解析器未安装，会自动尝试安装。",
  func = _get_node_type,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      node_type = { type = "string", description = "节点类型过滤（可选），如 'function_definition'" },
      text = { type = "string", description = "节点文本过滤（可选）" },
      named = { type = "boolean", description = "是否为命名节点（可选）" },
    },
    required = { "filepath" },
  },
  returns = { type = "object", description = "匹配节点的类型信息列表" },
  category = "treesitter",
  permissions = { read = true },
  approval = { behavior = "auto_approve" },
})

-- ============================================================================
-- 工具 get_node_range - 获取节点范围（回调模式）
-- ============================================================================

local function _get_node_range(args, on_success, on_error)
  if not check_ts() then
    if on_error then
      on_error("Tree-sitter 不可用（需要 Neovim >= 0.5）")
    end
    return
  end
  if not args or not args.filepath then
    if on_error then
      on_error("需要 filepath（文件路径）参数")
    end
    return
  end

  parse_file_content_async(args.filepath, -1, function(result)
    local filtered, fallback = filter_nodes(result.nodes, args)
    if #filtered == 0 then
      if on_error then
        on_error("未找到匹配的节点")
      end
      return
    end

    -- 如果需要 include_code，异步读取文件内容
    if args.include_code then
      read_file_content_async(args.filepath, function(content)
        local file_lines = vim.split(content, "\n", { plain = true })
        local ranges = {}
        for _, node in ipairs(filtered) do
          local entry = {
            type = node.type,
            text = node.text,
            start_row = node.start_row,
            start_col = node.start_col,
            end_row = node.end_row,
            end_col = node.end_col,
          }
          local code_lines = {}
          for line_num = node.start_row, node.end_row do
            local line_content = file_lines[line_num + 1] or ""
            table.insert(code_lines, string.format("%d: %s", line_num, line_content))
          end
          entry.code = table.concat(code_lines, "\n")
          table.insert(ranges, entry)
        end
        local ret = {
          filepath = args.filepath,
          language = result.language,
          match_count = #filtered,
          ranges = ranges,
        }
        if fallback then
          ret.warning = "未找到指定 node_type '"
            .. (args.node_type or "")
            .. "' 的节点，已回退到同类型节点"
        end
        if on_success then
          on_success(ret)
        end
      end, function(err)
        if on_error then
          on_error(err)
        end
      end)
    else
      local ranges = {}
      for _, node in ipairs(filtered) do
        table.insert(ranges, {
          type = node.type,
          text = node.text,
          start_row = node.start_row,
          start_col = node.start_col,
          end_row = node.end_row,
          end_col = node.end_col,
        })
      end
      local ret = {
        filepath = args.filepath,
        language = result.language,
        match_count = #filtered,
        ranges = ranges,
      }
      if fallback then
        ret.warning = "未找到指定 node_type '"
          .. (args.node_type or "")
          .. "' 的节点，已回退到同类型节点"
      end
      if on_success then
        on_success(ret)
      end
    end
  end, function(err)
    if on_error then
      on_error(err or "解析结果为空")
    end
  end)
end

M.get_node_range = define_tool({
  name = "get_node_range",
  description = "获取文件中匹配节点的范围信息（返回: 起始行/列、结束行/列），支持按 node_type、text、named 属性过滤，可选返回带行号的节点代码。如果解析器未安装，会自动尝试安装。",
  func = _get_node_range,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      node_type = { type = "string", description = "节点类型过滤（可选），如 'function_definition'" },
      text = { type = "string", description = "节点文本过滤（可选）" },
      named = { type = "boolean", description = "是否为命名节点（可选）" },
      include_code = {
        type = "boolean",
        description = "是否返回带行号的节点代码（可选，默认 false）",
      },
    },
    required = { "filepath" },
  },
  returns = { type = "object", description = "匹配节点的范围信息列表" },
  category = "treesitter",
  permissions = { read = true },
  approval = { behavior = "auto_approve" },
})

-- ============================================================================
-- 工具 is_named_node - 检查是否为命名节点（回调模式）
-- ============================================================================

local function _is_named_node(args, on_success, on_error)
  _with_parsed_tree(args, on_success, on_error, function(result, filtered, fallback)
    local named_info = {}
    for _, node in ipairs(filtered) do
      table.insert(named_info, { type = node.type, text = node.text, named = node.named })
    end
    local ret = {
      filepath = args.filepath,
      language = result.language,
      match_count = #filtered,
      nodes = named_info,
    }
    if fallback then
      ret.warning = "未找到指定 node_type '"
        .. (args.node_type or "")
        .. "' 的节点，已回退到同类型节点"
    end
    return ret
  end)
end

M.is_named_node = define_tool({
  name = "is_named_node",
  description = "检查文件中匹配节点是否为命名节点，支持按 node_type、text 属性过滤。如果解析器未安装，会自动尝试安装。",
  func = _is_named_node,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      node_type = { type = "string", description = "节点类型过滤（可选），如 'function_definition'" },
      text = { type = "string", description = "节点文本过滤（可选）" },
    },
    required = { "filepath" },
  },
  returns = { type = "object", description = "匹配节点的命名状态信息" },
  category = "treesitter",
  permissions = { read = true },
  approval = { behavior = "auto_approve" },
})

-- ============================================================================
-- 工具 get_parent_node - 获取父节点（回调模式）
-- ============================================================================

local function _find_parent_by_attrs(nodes, target_type, target_text, target_named)
  local function is_parent_of(parent, child)
    return parent.start_row <= child.start_row
      and parent.end_row >= child.end_row
      and (parent.start_row < child.start_row or (parent.start_row == child.start_row and parent.start_col <= child.start_col))
      and (parent.end_row > child.end_row or (parent.end_row == child.end_row and parent.end_col >= child.end_col))
      and parent.depth < child.depth
  end

  local targets, fallback = filter_nodes(nodes, {
    node_type = target_type,
    text = target_text,
    named = target_named,
  })

  if #targets == 0 then
    return nil, "未找到匹配的目标节点"
  end

  local parents = {}
  for _, target in ipairs(targets) do
    local parent = nil
    for _, candidate in ipairs(nodes) do
      if is_parent_of(candidate, target) then
        if not parent or candidate.depth > parent.depth then
          parent = candidate
        end
      end
    end
    table.insert(parents, { target = target, parent = parent })
  end

  return parents, nil, fallback
end

local function _get_parent_node(args, on_success, on_error)
  if not check_ts() then
    if on_error then
      on_error("Tree-sitter 不可用（需要 Neovim >= 0.5）")
    end
    return
  end
  if not args or not args.filepath then
    if on_error then
      on_error("需要 filepath（文件路径）参数")
    end
    return
  end

  parse_file_content_async(args.filepath, -1, function(result)
    local parents, perr, fallback = _find_parent_by_attrs(result.nodes or {}, args.node_type, args.text, args.named)
    if perr or not parents then
      if on_error then
        on_error(perr or "未找到父节点")
      end
      return
    end
    local parent_info = {}
    for _, item in ipairs(parents) do
      table.insert(parent_info, {
        target_node = item.target,
        parent_node = item.parent and {
          type = item.parent.type,
          text = item.parent.text,
          start_row = item.parent.start_row,
          start_col = item.parent.start_col,
          end_row = item.parent.end_row,
          end_col = item.parent.end_col,
          depth = item.parent.depth,
        } or nil,
      })
    end
    local ret = {
      filepath = args.filepath,
      language = result.language,
      match_count = #parent_info,
      parents = parent_info,
    }
    if fallback then
      ret.warning = "未找到指定 node_type '"
        .. (args.node_type or "")
        .. "' 的节点，已回退到同类型节点"
    end
    if on_success then
      on_success(ret)
    end
  end, function(err)
    if on_error then
      on_error(err or "解析结果为空")
    end
  end)
end

M.get_parent_node = define_tool({
  name = "get_parent_node",
  description = "获取文件中匹配节点的父节点信息，支持按 node_type、text、named 属性过滤目标节点。如果解析器未安装，会自动尝试安装。",
  func = _get_parent_node,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      node_type = { type = "string", description = "目标节点类型过滤（可选）" },
      text = { type = "string", description = "目标节点文本过滤（可选）" },
      named = { type = "boolean", description = "目标节点是否为命名节点（可选）" },
    },
    required = { "filepath" },
  },
  returns = { type = "object", description = "匹配节点的父节点信息" },
  category = "treesitter",
  permissions = { read = true },
  approval = { behavior = "auto_approve" },
})

-- ============================================================================
-- 工具 get_child_nodes - 获取子节点列表（回调模式）
-- ============================================================================

local function _get_child_nodes(args, on_success, on_error)
  _with_parsed_tree(args, on_success, on_error, function(result, filtered, fallback)
    local children_info = {}
    for _, parent in ipairs(filtered) do
      local children = {}
      for _, candidate in ipairs(result.nodes) do
        if
          candidate.depth == parent.depth + 1
          and candidate.start_row >= parent.start_row
          and candidate.end_row <= parent.end_row
        then
          table.insert(children, candidate)
        end
      end
      table.insert(children_info, {
        parent = {
          type = parent.type,
          text = parent.text,
          start_row = parent.start_row,
          start_col = parent.start_col,
          end_row = parent.end_row,
          end_col = parent.end_col,
        },
        child_count = #children,
        children = children,
      })
    end
    local ret = {
      filepath = args.filepath,
      language = result.language,
      match_count = #children_info,
      children_info = children_info,
    }
    if fallback then
      ret.warning = "未找到指定 node_type '"
        .. (args.node_type or "")
        .. "' 的节点，已回退到同类型节点"
    end
    return ret
  end)
end

M.get_child_nodes = define_tool({
  name = "get_child_nodes",
  description = "获取文件中匹配节点的直接子节点列表，支持按 node_type、text、named 属性过滤父节点。如果解析器未安装，会自动尝试安装。",
  func = _get_child_nodes,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      node_type = { type = "string", description = "父节点类型过滤（可选），如 'function_definition'" },
      text = { type = "string", description = "父节点文本过滤（可选）" },
      named = { type = "boolean", description = "父节点是否为命名节点（可选）" },
    },
    required = { "filepath" },
  },
  returns = { type = "object", description = "匹配父节点的子节点列表" },
  category = "treesitter",
  permissions = { read = true },
  approval = { behavior = "auto_approve" },
})

-- get_tools() - 返回所有工具列表供注册
-- 导出 parse_file_content_async 供 file_tools 等模块使用
-- 用于在读取大文件时获取语法树结构概览
function M.parse_file_content_async(filepath, max_depth, on_success, on_error)
  parse_file_content_async(filepath, max_depth, on_success, on_error)
end

function M.get_tools()
  if not check_ts() then
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
