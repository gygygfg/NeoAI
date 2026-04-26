-- Tree-sitter 语法树工具模块
-- 提供语法解析、节点查询、代码结构分析等常用功能
-- 每个工具的定义（名称、描述、参数、实现）集中在一起，方便修改
-- 仅在 Neovim >= 0.5 且 Tree-sitter 可用时自动启用
local M = {}

local define_tool = require("NeoAI.tools.builtin.tool_helpers").define_tool

-- 检查 Tree-sitter 是否可用
local ts_available = false
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

-- 从文件路径推断语言（使用 vim.filetype.match + vim.treesitter.language.get_lang）
local function detect_lang_from_filepath(filepath)
  local abs_path = vim.fn.fnamemodify(filepath, ":p")
  local ft = vim.filetype.match({ filename = abs_path })
  if not ft then
    return nil
  end
  ---@diagnostic disable-next-line: undefined-field, need-check-nil
  local ok, lang = pcall(ts.language.get_lang, ft)
  if ok and lang then
    return lang
  end
  return nil
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

-- 解析文件内容并返回语法树
local function parse_file_content(filepath, max_depth)
  local content, err = read_file_content(filepath)
  if not content then
    return nil, err
  end

  local lang = detect_lang_from_filepath(filepath)
  if not lang then
    return nil, "无法确定文件语言"
  end

  ---@diagnostic disable-next-line: undefined-field, need-check-nil
  local ok, parser = pcall(ts.get_string_parser, content, lang)
  if not ok or not parser then
    return nil, "无法为语言 '" .. lang .. "' 创建解析器"
  end

  local ok2, trees = pcall(parser.parse, parser)
  if not ok2 or not trees or #trees == 0 then
    return nil, "解析失败"
  end

  local root = trees[1]:root()
  local nodes = _traverse_node(root, content, 0, max_depth or 3)

  return {
    filepath = filepath,
    language = lang,
    line_count = #vim.split(content, "\n", { plain = true }),
    root_type = root:type(),
    node_count = #nodes,
    nodes = nodes,
  },
    nil
end

-- ============================================================================
-- 工具 parse_file - 解析文件并返回语法树
-- ============================================================================

local function _parse_file(args)
  if not check_ts() then
    return { error = "Tree-sitter 不可用（需要 Neovim >= 0.5）" }
  end

  local max_depth = args.max_depth or 3

  -- 处理 filepaths 列表
  if args.filepaths and #args.filepaths > 0 then
    local results = {}
    for _, fp in ipairs(args.filepaths) do
      local r, err = parse_file_content(fp, max_depth)
      if err then
        table.insert(results, { filepath = fp, error = err })
      else
        table.insert(results, r)
      end
    end
    return results
  end

  -- 处理单个 filepath
  if args.filepath then
    local result, err = parse_file_content(args.filepath, max_depth)
    if err then
      return { filepath = args.filepath, error = err }
    end
    return result
  end

  return { error = "需要 filepath（文件路径）或 filepaths（路径列表）参数" }
end

M.parse_file = define_tool({
  name = "parse_file",
  description = "解析文件并返回 Tree-sitter 语法树节点信息，支持 filepath（单个文件路径）和 filepaths（路径列表）参数",
  func = _parse_file,
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
})

-- ============================================================================
-- 工具 query_captures - 使用查询模式捕获节点
-- ============================================================================

local function _query_captures_for_source(source_text, lang, query_string)
  ---@diagnostic disable-next-line: undefined-field, need-check-nil
  local ok, query = pcall(ts.query.parse, lang, query_string)
  if not ok then
    return nil, "查询语法错误: " .. tostring(query)
  end

  ---@diagnostic disable-next-line: undefined-field, need-check-nil
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

local function _query_captures(args)
  if not check_ts() then
    return { error = "Tree-sitter 不可用（需要 Neovim >= 0.5）" }
  end

  if not args or not args.query or not args.filepath then
    return { error = "需要 query（查询字符串）和 filepath（文件路径）参数" }
  end

  local query_string = args.query

  local content, err = read_file_content(args.filepath)
  if not content then
    return { filepath = args.filepath, error = err }
  end

  local lang = detect_lang_from_filepath(args.filepath)
  if not lang then
    return { filepath = args.filepath, error = "无法确定文件语言" }
  end

  local result, qerr = _query_captures_for_source(content, lang, query_string)
  if qerr then
    return { filepath = args.filepath, error = qerr }
  end
  result.filepath = args.filepath
  return result
end

M.query_captures = define_tool({
  name = "query_captures",
  description = "使用 Tree-sitter 查询模式捕获文件中语法树节点，支持自定义查询字符串",
  func = _query_captures,
  parameters = {
    type = "object",
    properties = {
      query = { type = "string", description = "Tree-sitter 查询字符串，如 '((function_definition) @func)'" },
      filepath = {
        type = "string",
        description = "文件路径",
      },
    },
    required = { "query", "filepath" },
  },
  returns = {
    type = "object",
    description = "查询捕获结果",
  },
  category = "treesitter",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 get_node_at_position - 获取文件中指定位置的语法树节点
-- ============================================================================

local function _get_node_at_position(args)
  if not check_ts() then
    return { error = "Tree-sitter 不可用（需要 Neovim >= 0.5）" }
  end

  if not args or not args.filepath then
    return { error = "需要 filepath（文件路径）参数" }
  end

  local filepath = args.filepath
  local row = args.row
  local col = args.col

  local content, err = read_file_content(filepath)
  if not content then
    return { filepath = filepath, error = err }
  end

  local lang = detect_lang_from_filepath(filepath)
  if not lang then
    return { filepath = filepath, error = "无法确定文件语言" }
  end

  ---@diagnostic disable-next-line: undefined-field, need-check-nil
  local ok, parser = pcall(ts.get_string_parser, content, lang)
  if not ok or not parser then
    return { filepath = filepath, error = "无法为语言 '" .. lang .. "' 创建解析器" }
  end

  local ok2, trees = pcall(parser.parse, parser)
  if not ok2 or not trees or #trees == 0 then
    return { filepath = filepath, error = "解析失败" }
  end

  local root = trees[1]:root()

  local target_row = row or 0
  local target_col = col or 0

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
    return { filepath = filepath, error = "未找到该位置的节点" }
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

  return {
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
  }
end

M.get_node_at_position = define_tool({
  name = "get_node_at_position",
  description = "获取文件中指定位置（行、列）的 Tree-sitter 语法树节点，包含父节点链和子节点信息",
  func = _get_node_at_position,
  parameters = {
    type = "object",
    properties = {
      filepath = {
        type = "string",
        description = "文件路径",
      },
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
})

-- ============================================================================
-- 工具 get_node_type - 获取节点类型
-- ============================================================================

local function _get_node_type(args)
  if not check_ts() then
    return { error = "Tree-sitter 不可用（需要 Neovim >= 0.5）" }
  end

  if not args or not args.filepath then
    return { error = "需要 filepath（文件路径）参数" }
  end

  local result, err = parse_file_content(args.filepath, -1)
  if err or not result then
    return { filepath = args.filepath, error = err or "解析结果为空" }
  end

  -- 按属性过滤节点
  local filtered = {}
  for _, node in ipairs(result.nodes or {}) do
    local matched = true
    if args.node_type and node.type ~= args.node_type then
      matched = false
    end
    if matched and args.text ~= nil and node.text ~= args.text then
      matched = false
    end
    if matched and args.named ~= nil and node.named ~= args.named then
      matched = false
    end
    if matched then
      table.insert(filtered, node)
    end
  end

  if #filtered == 0 then
    return { filepath = args.filepath, error = "未找到匹配的节点" }
  end

  local types = {}
  local seen = {}
  for _, node in ipairs(filtered) do
    if not seen[node.type] then
      seen[node.type] = true
      table.insert(types, node.type)
    end
  end

  return {
    filepath = args.filepath,
    language = result and result.language,
    match_count = #filtered,
    node_types = types,
    nodes = filtered,
  }
end

M.get_node_type = define_tool({
  name = "get_node_type",
  description = "获取文件中匹配节点的类型信息，支持按 node_type、text、named 属性过滤",
  func = _get_node_type,
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
  returns = {
    type = "object",
    description = "匹配节点的类型信息列表",
  },
  category = "treesitter",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 get_node_range - 获取节点范围
-- ============================================================================

local function _get_node_range(args)
  if not check_ts() then
    return { error = "Tree-sitter 不可用（需要 Neovim >= 0.5）" }
  end

  if not args or not args.filepath then
    return { error = "需要 filepath（文件路径）参数" }
  end

  local result, err = parse_file_content(args.filepath, -1)
  if err or not result then
    return { filepath = args.filepath, error = err or "解析结果为空" }
  end

  -- 按属性过滤节点
  local filtered = {}
  for _, node in ipairs(result.nodes or {}) do
    local matched = true
    if args.node_type and node.type ~= args.node_type then
      matched = false
    end
    if matched and args.text ~= nil and node.text ~= args.text then
      matched = false
    end
    if matched and args.named ~= nil and node.named ~= args.named then
      matched = false
    end
    if matched then
      table.insert(filtered, node)
    end
  end

  if #filtered == 0 then
    return { filepath = args.filepath, error = "未找到匹配的节点" }
  end

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

  return {
    filepath = args.filepath,
    language = result and result.language,
    match_count = #filtered,
    ranges = ranges,
  }
end

M.get_node_range = define_tool({
  name = "get_node_range",
  description = "获取文件中匹配节点的范围信息（起始行/列、结束行/列），支持按 node_type、text、named 属性过滤",
  func = _get_node_range,
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
  returns = {
    type = "object",
    description = "匹配节点的范围信息列表",
  },
  category = "treesitter",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 is_named_node - 检查是否为命名节点
-- ============================================================================

local function _is_named_node(args)
  if not check_ts() then
    return { error = "Tree-sitter 不可用（需要 Neovim >= 0.5）" }
  end

  if not args or not args.filepath then
    return { error = "需要 filepath（文件路径）参数" }
  end

  local result, err = parse_file_content(args.filepath, -1)
  if err or not result then
    return { filepath = args.filepath, error = err or "解析结果为空" }
  end

  -- 按属性过滤节点
  local filtered = {}
  for _, node in ipairs(result.nodes or {}) do
    local matched = true
    if args.node_type and node.type ~= args.node_type then
      matched = false
    end
    if matched and args.text ~= nil and node.text ~= args.text then
      matched = false
    end
    if matched then
      table.insert(filtered, node)
    end
  end

  if #filtered == 0 then
    return { filepath = args.filepath, error = "未找到匹配的节点" }
  end

  local named_info = {}
  for _, node in ipairs(filtered) do
    table.insert(named_info, {
      type = node.type,
      text = node.text,
      named = node.named,
    })
  end

  return {
    filepath = args.filepath,
    language = result and result.language,
    match_count = #filtered,
    nodes = named_info,
  }
end

M.is_named_node = define_tool({
  name = "is_named_node",
  description = "检查文件中匹配节点是否为命名节点，支持按 node_type、text 属性过滤",
  func = _is_named_node,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      node_type = { type = "string", description = "节点类型过滤（可选），如 'function_definition'" },
      text = { type = "string", description = "节点文本过滤（可选）" },
    },
    required = { "filepath" },
  },
  returns = {
    type = "object",
    description = "匹配节点的命名状态信息",
  },
  category = "treesitter",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 get_parent_node - 获取父节点
-- ============================================================================

-- 递归查找节点的父节点（基于节点属性匹配）
local function _find_parent_by_attrs(nodes, target_type, target_text, target_named)
  -- 构建父子关系映射：子节点 -> 父节点
  -- 由于 parse_file_content 返回的是扁平列表，我们需要重新构建树
  -- 这里采用简单策略：在扁平列表中，父节点是范围包含子节点的最近上层节点
  local function is_parent_of(parent, child)
    return parent.start_row <= child.start_row
      and parent.end_row >= child.end_row
      and (parent.start_row < child.start_row or (parent.start_row == child.start_row and parent.start_col <= child.start_col))
      and (parent.end_row > child.end_row or (parent.end_row == child.end_row and parent.end_col >= child.end_col))
      and parent.depth < child.depth
  end

  -- 找到所有匹配的目标节点
  local targets = {}
  for _, node in ipairs(nodes) do
    local matched = true
    if target_type and node.type ~= target_type then
      matched = false
    end
    if matched and target_text ~= nil and node.text ~= target_text then
      matched = false
    end
    if matched and target_named ~= nil and node.named ~= target_named then
      matched = false
    end
    if matched then
      table.insert(targets, node)
    end
  end

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
    table.insert(parents, {
      target = target,
      parent = parent,
    })
  end

  return parents, nil
end

local function _get_parent_node(args)
  if not check_ts() then
    return { error = "Tree-sitter 不可用（需要 Neovim >= 0.5）" }
  end

  if not args or not args.filepath then
    return { error = "需要 filepath（文件路径）参数" }
  end

  local result, err = parse_file_content(args.filepath, -1)
  if err or not result then
    return { filepath = args.filepath, error = err or "解析结果为空" }
  end

  local parents, perr = _find_parent_by_attrs(result.nodes or {}, args.node_type, args.text, args.named)
  if perr or not parents then
    return { filepath = args.filepath, error = perr or "未找到父节点" }
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

  return {
    filepath = args.filepath,
    language = result and result.language,
    match_count = #parent_info,
    parents = parent_info,
  }
end

M.get_parent_node = define_tool({
  name = "get_parent_node",
  description = "获取文件中匹配节点的父节点信息，支持按 node_type、text、named 属性过滤目标节点",
  func = _get_parent_node,
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
  returns = {
    type = "object",
    description = "匹配节点的父节点信息",
  },
  category = "treesitter",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 get_child_nodes - 获取子节点列表
-- ============================================================================

local function _get_child_nodes(args)
  if not check_ts() then
    return { error = "Tree-sitter 不可用（需要 Neovim >= 0.5）" }
  end

  if not args or not args.filepath then
    return { error = "需要 filepath（文件路径）参数" }
  end

  local result, err = parse_file_content(args.filepath, -1)
  if err or not result then
    return { filepath = args.filepath, error = err or "解析结果为空" }
  end

  -- 找到匹配的父节点
  local filtered = {}
  for _, node in ipairs(result.nodes or {}) do
    local matched = true
    if args.node_type and node.type ~= args.node_type then
      matched = false
    end
    if matched and args.text ~= nil and node.text ~= args.text then
      matched = false
    end
    if matched and args.named ~= nil and node.named ~= args.named then
      matched = false
    end
    if matched then
      table.insert(filtered, node)
    end
  end

  if #filtered == 0 then
    return { filepath = args.filepath, error = "未找到匹配的父节点" }
  end

  -- 对每个匹配的父节点，找到其直接子节点
  -- 直接子节点：范围被父节点包含，且深度 = 父节点深度 + 1
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

  return {
    filepath = args.filepath,
    language = result and result.language,
    match_count = #children_info,
    children_info = children_info,
  }
end

M.get_child_nodes = define_tool({
  name = "get_child_nodes",
  description = "获取文件中匹配节点的直接子节点列表，支持按 node_type、text、named 属性过滤父节点",
  func = _get_child_nodes,
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
  returns = {
    type = "object",
    description = "匹配父节点的子节点列表",
  },
  category = "treesitter",
  permissions = { read = true },
})

-- ============================================================================
-- get_tools() - 返回所有工具列表供注册
-- ============================================================================

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
