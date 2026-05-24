-- Tree-sitter 语法树工具模块
-- 提供语法解析、节点查询、代码结构分析等常用功能
-- 每个工具的定义（名称、描述、参数、实现）集中在一起，方便修改
-- 仅在 Neovim >= 0.5 且 Tree-sitter 可用时自动启用
local M = {}

local lm = require("NeoAI.utils.language_map")

local block_node_types = {
  -- 通用
  function_definition = true,
  class_definition = true,
  class_declaration = true,
  struct_specifier = true,
  enum_specifier = true,
  union_specifier = true,
  interface_declaration = true,
  type_declaration = true,
  method_definition = true,
  constructor_definition = true,
  destructor_definition = true,
  -- 控制流块
  if_statement = true,
  else_clause = true,
  switch_statement = true,
  case_statement = true,
  for_statement = true,
  while_statement = true,
  do_statement = true,
  try_statement = true,
  catch_clause = true,
  finally_clause = true,
  -- 注意：module、program、translation_unit 等根容器类型不应在此列表中，
  -- 因为它们代表整个文件，删除根节点会清空文件。
  block = true,
  body = true,
  declaration = true,
  template_declaration = true,
  -- Lua
  local_function_declaration = true,
  -- Python
  decorated_definition = true,
  -- JavaScript/TypeScript
  arrow_function = true,
  generator_function = true,
  export_statement = true,
  lexical_declaration = true,
  variable_declaration = true,
  -- Go
  func_declaration = true,
  method_declaration = true,
  -- Rust
  impl_item = true,
  trait_item = true,
  -- 宏
  macro_definition = true,
  macro_invocation = true,
  -- 注释（可删除节点）
  comment = true,
  line_comment = true,
  block_comment = true,
  -- 字符串字面量（可删除节点）
  string = true,
  string_literal = true,
  string_content = true,
  -- 导入导出语句（可删除节点）
  import_statement = true,
  import_declaration = true,
  export_declaration = true,
  -- 语句级节点（可删除）
  expression_statement = true,
  return_statement = true,
  break_statement = true,
  continue_statement = true,
  assert_statement = true,
  raise_statement = true,
  -- 属性/装饰器（可删除）
  attribute = true,
  annotation = true,
}

M.block_node_types = block_node_types

-- 扩展名到 Tree-sitter 解析器名称的直接映射
-- 避免在 fast event 上下文中调用 vim.filetype.match（内部调用 getenv）
local ext_to_parser = lm.ext_to_parser
-- 检查 Tree-sitter 是否可用
local ts_available = false
---@class vim.treesitter
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
  -- 确保 ts 模块已加载
  if not check_ts() then
    if on_error then
      on_error("Tree-sitter 不可用（需要 Neovim >= 0.5）")
    end
    return
  end

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
  local has_language_add = pcall(vim.treesitter.language.add, lang)

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
      vim.schedule(function()
        if on_error then
          on_error("无法读取文件: " .. (open_err or "未知错误"))
        end
      end)
      return
    end
    vim.uv.fs_fstat(fd, function(stat_err, stat)
      if stat_err or not stat then
        vim.uv.fs_close(fd)
        vim.schedule(function()
          if on_error then
            on_error("无法读取文件: " .. (stat_err or "无法获取文件信息"))
          end
        end)
        return
      end
      vim.uv.fs_read(fd, stat.size, 0, function(read_err, data)
        vim.uv.fs_close(fd)
        vim.schedule(function()
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
  end)
end

-- 公共节点过滤函数：支持正则匹配 text，node_type 不匹配时回退到同类型节点
-- 返回 filtered 和 fallback_used（是否使用了回退）
-- node_type 支持带编号格式，如 'function_definition[2]' 表示匹配第2个 function_definition
local function filter_nodes(nodes, node_type, text, named)
  -- 解析 node_type 中的编号后缀 [N]
  local actual_type = node_type
  local target_index = nil
  if node_type then
    local base_type, idx = node_type:match("^(.-)%[(%d+)%]$")
    if base_type and idx then
      actual_type = base_type
      target_index = tonumber(idx)
    end
  end

  local filtered = {}

  -- 第一轮：精确匹配所有条件
  for _, node in ipairs(nodes or {}) do
    local matched = true
    if actual_type and node.type ~= actual_type then
      matched = false
    end
    if matched and target_index and node.type_index ~= target_index then
      matched = false
    end
    if matched and text ~= nil then
      -- 使用 Lua 的 string.find 做子串匹配（不区分大小写可选）
      if not node.text:find(text, 1, true) then
        matched = false
      end
    end
    if matched and named ~= nil and node.named ~= named then
      matched = false
    end
    if matched then
      table.insert(filtered, node)
    end
  end

  -- 安全检查：如果指定了 node_type 但没有任何节点匹配，返回清晰错误而不是静默回退
  -- 注意：不在这里过滤根容器节点（depth == 0），由调用方自行处理

  return filtered, false
end

-- 检测 node_type 是否看起来像匿名 token
-- Tree-sitter 的匿名节点类型通常是运算符、分隔符等纯符号 token
-- 如: + - * / = == != < > <= >= && || ! ~ & | ^ << >> ( ) { } [ ] ; , . : :: -> => ? # @ $
local function looks_like_anonymous_token(node_type)
  if not node_type or node_type == "" then
    return false
  end
  -- 如果包含字母、数字或下划线，则很可能是命名节点类型
  if node_type:find("[%w_]") then
    return false
  end
  return true
end

-- 构建"未找到匹配节点"的友好错误消息
-- @param node_type string|nil 用户指定的 node_type（可能带 [N] 编号后缀）
-- @param nodes table|nil 解析树中的所有节点（用于列出有效类型）
-- @return string 错误消息
local function _build_no_match_error(node_type, nodes)
  local parts = { "未找到匹配的节点" }

  -- 提取基础类型名（去掉 [N] 编号后缀）用于匿名 token 检测
  local base_type = node_type
  if node_type then
    local b, _ = node_type:match("^(.-)%[(%d+)%]$")
    if b then
      base_type = b
    end
  end

  -- 检测是否为匿名 token：这类节点不会出现在 named_child 遍历结果中
  if base_type and looks_like_anonymous_token(base_type) then
    parts[#parts + 1] = "。\""
    parts[#parts + 1] = base_type
    parts[#parts + 1] = "\" 看起来像是匿名 token（Tree-sitter 中的运算符、分隔符等），"
      .. "不属于命名节点类型，因此无法通过 node_type 参数匹配。"
      .. "建议：使用 query_tree 工具配合自定义查询来查找匿名 token，"
      .. "或使用 text 参数进行文本匹配"
    return table.concat(parts)
  end

  -- 列出文件中存在的命名节点类型，帮助用户找到正确的类型名
  if nodes and #nodes > 0 then
    local types = {}
    local seen = {}
    for _, n in ipairs(nodes) do
      if not seen[n.type] then
        seen[n.type] = true
        table.insert(types, n.type)
      end
    end
    if #types > 0 then
      table.sort(types)
      local max_show = 20
      local type_list = {}
      for i = 1, math.min(#types, max_show) do
        type_list[#type_list + 1] = types[i]
      end
      parts[#parts + 1] = "。文件中存在的命名节点类型: "
      parts[#parts + 1] = table.concat(type_list, ", ")
      if #types > max_show then
        parts[#parts + 1] = " ... (共 "
        parts[#parts + 1] = tostring(#types)
        parts[#parts + 1] = " 种，仅显示前 "
        parts[#parts + 1] = tostring(max_show)
        parts[#parts + 1] = " 种)"
      end
    end
  end

  return table.concat(parts)
end

-- 递归遍历语法树节点
local function _traverse_node(node, source, depth, max_depth)
  if not node then
    return {}
  end

  if max_depth >= 0 and depth > max_depth then
    return {}
  end

  local results = {}
  local text = vim.treesitter.get_node_text(node, source)
  local sr, sc, er, ec = node:range()

  table.insert(results, {
    type = node:type(),
    text = text,
    named = node:named(),
    start_row = sr,
    start_col = sc,
    end_row = er,
    end_col = ec,
    depth = depth,
  })

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

        -- 给相同类型节点自动编号 [1][2][3]...
        local type_counts = {}
        for _, node in ipairs(nodes) do
          type_counts[node.type] = (type_counts[node.type] or 0) + 1
          node.type_index = type_counts[node.type]
        end

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

  -- 解析单个 filepath
  local filepath = args.filepath

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
        if r and r.nodes then
          local filtered = {}
          for _, n in ipairs(r.nodes) do
            if block_node_types[n.type] then
              table.insert(filtered, n)
            end
          end
          r.nodes = filtered
          -- 过滤后重新编号
          local tc = {}
          for _, n2 in ipairs(filtered) do
            tc[n2.type] = (tc[n2.type] or 0) + 1
            n2.type_index = tc[n2.type]
          end
        end
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
  if filepath then
    parse_file_content_async(filepath, max_depth, function(result)
      if result and result.nodes then
        local filtered = {}
        for _, n in ipairs(result.nodes) do
          if block_node_types[n.type] then
            table.insert(filtered, n)
          end
        end
        result.nodes = filtered
        -- 过滤后重新编号
        local tc = {}
        for _, n2 in ipairs(filtered) do
          tc[n2.type] = (tc[n2.type] or 0) + 1
          n2.type_index = tc[n2.type]
        end
      end
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

M.parse_file = {
  name = "parse_file",
  description = "解析文件并返回 Tree-sitter 语法树节点信息，支持 filepath（单个文件路径）和 filepaths（路径列表）参数。",
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
}

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
  }
end

-- ============================================================================
-- 工具 query_tree - 使用 Tree-sitter 查询模式捕获节点（回调模式）
-- ============================================================================

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
  local filepath = args.filepath

  read_file_content_async(filepath, function(content)
    vim.schedule(function()
      local lang = detect_lang_from_filepath(filepath)
      if not lang then
        local ext = vim.fn.fnamemodify(filepath, ":e")
        local filetype_hint = ext and ext ~= "" and ("（文件扩展名 '.%s' 没有对应的 Tree-sitter 解析器）"):format(ext)
          or "（无法从文件路径推断语言类型）"
        if on_error then
          on_error("无法确定文件语言" .. filetype_hint .. "。Tree-sitter 仅支持编程语言文件，不支持纯文本文件")
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
        result.filepath = filepath
        if on_success then
          on_success(result)
        end
      end, function(err)
        if on_error then
          on_error(err)
        end
      end)
    end) -- end vim.schedule
  end, function(err)
    if on_error then
      on_error(err)
    end
  end)
end

M.query_tree = {
  name = "query_tree",
  description = "使用 Tree-sitter 查询模式捕获文件中语法树节点，支持自定义查询字符串。",
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
}

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
    vim.schedule(function()
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
    end) -- end vim.schedule
  end, function(err)
    if on_error then
      on_error(err)
    end
  end)
end
M.get_node_at_position = {
  name = "get_node_at_position",
  description = "获取文件中指定位置（行、列）的 Tree-sitter 语法树节点，包含父节点链和子节点信息。",
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
}

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

  local filepath = args.filepath
  parse_file_content_async(filepath, -1, function(result)
    local filtered = filter_nodes(result.nodes, args.node_type, args.text, args.named)
    if #filtered == 0 then
      if on_error then
        on_error(_build_no_match_error(args.node_type, result.nodes))
      end
      return
    end
    local ret = build_response(result, filtered, false)
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

M.get_node_type = {
  name = "get_node_type",
  description = "获取文件中匹配节点的类型信息，支持按 node_type、text、named 属性过滤。",
  func = _get_node_type,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      node_type = { type = "string", description = "节点类型过滤（可选，仅支持命名节点类型，匿名 token 如运算符 '+' 请使用 text 参数或 query_tree），如 'function_definition'" },
      text = { type = "string", description = "节点文本过滤（可选）" },
      named = { type = "boolean", description = "是否为命名节点（可选）" },
    },
    required = { "filepath" },
  },
  returns = { type = "object", description = "匹配节点的类型信息列表" },
  category = "treesitter",
  permissions = { read = true },
}

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

  local filepath = args.filepath

  parse_file_content_async(filepath, -1, function(result)
    local filtered = filter_nodes(result.nodes, args.node_type, args.text, args.named)
    if #filtered == 0 then
      if on_error then
        on_error(_build_no_match_error(args.node_type, result.nodes))
      end
      return
    end

    -- 如果需要 include_code，异步读取文件内容
    if args.include_code then
      read_file_content_async(filepath, function(content)
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

M.get_node_range = {
  name = "get_node_range",
  description = "获取文件中匹配节点的范围信息（返回: 起始行/列、结束行/列），支持按 node_type、text、named 属性过滤，可选返回带行号的节点代码。",
  func = _get_node_range,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      node_type = { type = "string", description = "节点类型过滤（可选，仅支持命名节点类型，匿名 token 如运算符 '+' 请使用 text 参数或 query_tree），如 'function_definition'" },
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
}

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

M.is_named_node = {
  name = "is_named_node",
  description = "检查文件中匹配节点是否为命名节点，支持按 node_type、text 属性过滤。",
  func = _is_named_node,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      node_type = { type = "string", description = "节点类型过滤（可选，仅支持命名节点类型，匿名 token 如运算符 '+' 请使用 text 参数或 query_tree），如 'function_definition'" },
      text = { type = "string", description = "节点文本过滤（可选）" },
    },
    required = { "filepath" },
  },
  returns = { type = "object", description = "匹配节点的命名状态信息" },
  category = "treesitter",
  permissions = { read = true },
}

-- ============================================================================
-- 工具 get_parent_node - 获取父节点（回调模式）
-- ============================================================================

local function _find_parent_by_attrs(nodes, target_type, target_text, target_named)
  -- 修复 BUG 4: is_parent_of 函数体为空，添加正确的父子关系判断
  -- 父节点必须满足：范围完全包含子节点，且深度小于子节点
  local function is_parent_of(parent, child)
    if not parent or not child then
      return false
    end
    -- 父节点的深度必须小于子节点
    if parent.depth >= child.depth then
      return false
    end
    -- 父节点的范围必须完全包含子节点
    -- Tree-sitter 的 end_row/end_col 是独占的（exclusive）
    if parent.start_row < child.start_row then
      return parent.end_row > child.end_row
          or (parent.end_row == child.end_row and parent.end_col >= child.end_col)
    end
    if parent.start_row == child.start_row and parent.start_col <= child.start_col then
      return parent.end_row > child.end_row
          or (parent.end_row == child.end_row and parent.end_col >= child.end_col)
    end
    return false
  end

  local targets = filter_nodes(nodes, target_type, target_text, target_named)

  if #targets == 0 then
    return nil, _build_no_match_error(target_type, nodes)
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

  local filepath = args.filepath

  parse_file_content_async(filepath, -1, function(result)
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
      filepath = filepath,
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

M.get_parent_node = {
  name = "get_parent_node",
  description = "获取文件中匹配节点的父节点信息，支持按 node_type、text、named 属性过滤目标节点。",
  func = _get_parent_node,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      node_type = { type = "string", description = "目标节点类型过滤（可选，仅支持命名节点类型，匿名 token 如运算符 '+' 请使用 text 参数或 query_tree）" },
      text = { type = "string", description = "目标节点文本过滤（可选）" },
      named = { type = "boolean", description = "目标节点是否为命名节点（可选）" },
    },
    required = { "filepath" },
  },
  returns = { type = "object", description = "匹配节点的父节点信息" },
  category = "treesitter",
  permissions = { read = true },
}

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

M.get_child_nodes = {
  name = "get_child_nodes",
  description = "获取文件中匹配节点的直接子节点列表，支持按 node_type、text、named 属性过滤父节点。",
  func = _get_child_nodes,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      node_type = { type = "string", description = "父节点类型过滤（可选，仅支持命名节点类型，匿名 token 如运算符 '+' 请使用 text 参数或 query_tree），如 'function_definition'" },
      text = { type = "string", description = "父节点文本过滤（可选）" },
      named = { type = "boolean", description = "父节点是否为命名节点（可选）" },
    },
    required = { "filepath" },
  },
  returns = { type = "object", description = "匹配父节点的子节点列表" },
  category = "treesitter",
  permissions = { read = true },
}

-- ============================================================================
-- 工具 get_node_code - 获取指定节点的源代码（回调模式）
-- ============================================================================

local function _get_node_code(args, on_success, on_error)
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

  parse_file_content_async(filepath, -1, function(result)
    local filtered = filter_nodes(result.nodes, args.node_type, args.text, args.named)
    if #filtered == 0 then
      if on_error then
        on_error(_build_no_match_error(args.node_type, result.nodes))
      end
      return
    end

    -- 异步读取文件内容以提取精确的源代码
    read_file_content_async(filepath, function(content)
      local file_lines = vim.split(content, "\n", { plain = true })

      -- 修复 BUG 3: 返回所有匹配节点的代码，而非仅第一个
      local all_codes = {}
      for _, node in ipairs(filtered) do
        local code_lines = {}
        for line_num = node.start_row, node.end_row do
          local line_content = file_lines[line_num + 1] or ""
          if line_num == node.start_row and line_num == node.end_row then
            -- 修复 BUG 2: Tree-sitter 的 end_col 是独占的（exclusive），
            -- 所以 sub 的结束位置应为 end_col 而非 end_col + 1
            line_content = line_content:sub(node.start_col + 1, node.end_col)
          elseif line_num == node.start_row then
            line_content = line_content:sub(node.start_col + 1)
          elseif line_num == node.end_row then
            -- 修复 BUG 2: 同上，end_col 是独占的
            line_content = line_content:sub(1, node.end_col)
          end
          table.insert(code_lines, line_content)
        end
        table.insert(all_codes, {
          type = node.type,
          text = node.text,
          start_row = node.start_row,
          start_col = node.start_col,
          end_row = node.end_row,
          end_col = node.end_col,
          code = table.concat(code_lines, "\n"),
        })
      end

      local ret = {
        filepath = filepath,
        language = result.language,
        match_count = #filtered,
        nodes = all_codes,
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
  end, function(err)
    if on_error then
      on_error(err or "解析结果为空")
    end
  end)
end

M.get_node_code = {
  name = "get_node_code",
  description = "获取文件中匹配节点的精确源代码，返回纯文本代码。支持按 node_type、text、named 属性过滤。",
  func = _get_node_code,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      node_type = { type = "string", description = "节点类型过滤（可选，仅支持命名节点类型，匿名 token 如运算符 '+' 请使用 text 参数或 query_tree），如 'function_definition'" },
      text = { type = "string", description = "节点文本过滤（可选）" },
      named = { type = "boolean", description = "是否为命名节点（可选）" },
    },
    required = { "filepath" },
  },
  returns = { type = "object", description = "匹配节点的源代码（code 字段为纯文本）" },
  category = "treesitter",
  permissions = { read = true },
}

-- ============================================================================
-- 工具 delete_node - 删除指定节点（回调模式）
-- 仅支持删除有代码块结构的节点（函数、类、结构体等），防止误删表达式等细粒度节点
-- ============================================================================

-- 代码块结构节点类型白名单（各语言通用的结构节点）
-- 只有这些类型的节点可以被删除，防止误删表达式、变量名等细粒度节点
local function _delete_node(args, on_success, on_error)
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
  local node_type = args.node_type
  local text = args.text
  local named = args.named
  local index = args.index
  local uv = vim.uv or vim.loop
  local finalized = false

  -- 总超时保护：30 秒内未完成则报错退出
  local timeout_timer = uv.new_timer()
  local function finalize_with_timeout(msg, is_err)
    if finalized then
      return
    end
    finalized = true
    if timeout_timer then
      timeout_timer:stop()
      timeout_timer:close()
    end
    if is_err and on_error then
      on_error(msg)
    end
  end
  if timeout_timer then
    timeout_timer:start(
      30000,
      0,
      vim.schedule_wrap(function()
        finalize_with_timeout(
          "delete_node 操作超时（30 秒），Tree-sitter 解析或文件操作可能阻塞",
          true
        )
      end)
    )
  end

  parse_file_content_async(filepath, -1, function(result)
    local filtered = filter_nodes(result.nodes, node_type, text, named)
    if #filtered == 0 then
      if on_error then
        finalize_with_timeout(_build_no_match_error(node_type, result.nodes), true)
      end
      return
    end

    -- 安全检查：过滤掉根容器节点（depth == 0），防止删除整个文件
    local safe_filtered = {}
    local skipped_root = {}
    for _, node in ipairs(filtered) do
      if node.depth == 0 then
        table.insert(skipped_root, node.type)
      else
        table.insert(safe_filtered, node)
      end
    end
    if #safe_filtered == 0 then
      local msg = "所有匹配的节点都是根容器节点（"
        .. table.concat(skipped_root, ", ")
        .. "），拒绝删除。根节点代表整个文件，不能被删除。"
        .. "请指定一个具体的 node_type（如 'function_definition'、'class_definition' 等）"
      if on_error then
        finalize_with_timeout(msg, true)
      end
      return
    end
    filtered = safe_filtered

    -- 检查节点是否可删除（必须是代码块结构节点）
    local deletable = {}
    local skipped = {}
    for _, node in ipairs(filtered) do
      if block_node_types[node.type] then
        table.insert(deletable, node)
      else
        table.insert(skipped, node.type)
      end
    end

    if #deletable == 0 then
      local msg = "没有可删除的代码块结构节点。匹配到的节点类型（"
        .. table.concat(skipped, ", ")
        .. "）不是函数、类、结构体等代码块结构。请指定一个更具体的 node_type，如 'function_definition'"
      if on_error then
        finalize_with_timeout(msg, true)
      end
      return
    end

    -- 根据 index 参数选择要删除的节点
    -- 如果只有一个匹配，index 可省略；多个匹配时必须指定 index
    local target = nil
    if index ~= nil then
      local idx = tonumber(index)
      if not idx or idx < 1 or idx > #deletable then
        local msg = "index 参数无效: " .. tostring(index) .. "。" .. "有效范围: 1 ~ " .. #deletable
        if on_error then
          finalize_with_timeout(msg, true)
        end
        return
      end
      target = deletable[idx]
    elseif #deletable == 1 then
      target = deletable[1]
    else
      -- 多个匹配但未指定 index，返回错误和所有匹配节点信息
      local details = {}
      for i, node in ipairs(deletable) do
        table.insert(
          details,
          string.format(
            "  [%d] 类型: %s, 文本: %s, 位置: 行 %d-%d",
            i,
            node.type,
            node.text:gsub("\n", "\\n"):sub(1, 60),
            node.start_row + 1,
            node.end_row + 1
          )
        )
      end
      local msg = "匹配到 "
        .. #deletable
        .. " 个节点，请使用 index 参数指定要删除第几个:\n"
        .. table.concat(details, "\n")
      if on_error then
        finalize_with_timeout(msg, true)
      end
      return
    end

    -- 跳过的节点会在最终结果中通过 skipped_types 字段提示

    -- 异步读取文件内容
    read_file_content_async(filepath, function(content)
      local file_lines = vim.split(content, "\n", { plain = true })
      local deletions = {}

      do
        local node = target
        local sr, sc, er, ec = node.start_row, node.start_col, node.end_row, node.end_col
        local deleted_code = {}
        for line_num = sr, er do
          local line_content = file_lines[line_num + 1] or ""
          if line_num == sr and line_num == er then
            table.insert(deleted_code, line_content:sub(sc + 1, ec + 1))
          elseif line_num == sr then
            table.insert(deleted_code, line_content:sub(sc + 1))
          elseif line_num == er then
            table.insert(deleted_code, line_content:sub(1, ec + 1))
          else
            table.insert(deleted_code, line_content)
          end
        end
        table.insert(deletions, {
          type = node.type,
          text = node.text,
          start_row = sr,
          start_col = sc,
          end_row = er,
          end_col = ec,
          deleted_code = table.concat(deleted_code, "\n"),
        })
      end

      -- 从后往前删除（避免行号偏移）
      table.sort(deletions, function(a, b)
        if a.start_row ~= b.start_row then
          return a.start_row > b.start_row
        end
        return a.start_col > b.start_col
      end)

      local new_lines = {}
      for i, line in ipairs(file_lines) do
        table.insert(new_lines, line)
      end

      for _, del in ipairs(deletions) do
        local sr, sc, er, ec = del.start_row, del.start_col, del.end_row, del.end_col

        -- 从 new_lines 中移除被删除节点的行范围
        -- 注意：由于 deletions 已按从后往前排序，删除不会影响前面的行号
        local lines_to_remove = {}
        for line_num = sr, er do
          table.insert(lines_to_remove, line_num + 1)
        end
        -- 从后往前删除行（保持索引正确）
        table.sort(lines_to_remove, function(a, b)
          return a > b
        end)
        for _, idx in ipairs(lines_to_remove) do
          table.remove(new_lines, idx)
        end
      end

      -- 清理删除后残留的连续空行：保留最多 2 行空白行（符合 PEP 8 等规范）
      local cleaned_lines = {}
      local blank_count = 0
      for _, line in ipairs(new_lines) do
        local is_blank = line:match("^%s*$") ~= nil
        if not is_blank then
          table.insert(cleaned_lines, line)
          blank_count = 0
        elseif blank_count < 2 then
          -- 允许最多 2 行连续空白行（PEP 8：顶层定义之间 2 空行）
          table.insert(cleaned_lines, line)
          blank_count = blank_count + 1
        end
        -- else: 第 3 行及以上连续空白行，跳过
      end
      new_lines = cleaned_lines

      -- 使用 Neovim API 直接修改文件缓冲区
      -- 注意：此回调在 libuv fast event 上下文中，需用 vim.schedule 调用 Neovim API
      local abs_path = filepath
      vim.schedule(function()
        local bufnr = vim.fn.bufnr(abs_path)
        local was_loaded = true

        if bufnr == -1 then
          -- 文件未打开，创建隐藏缓冲区并加载
          bufnr = vim.fn.bufadd(abs_path)
          if bufnr == 0 then
            if on_error then
              finalize_with_timeout("无法为文件创建缓冲区: " .. abs_path, true)
            end
            return
          end
          vim.fn.bufload(bufnr)
          -- bufadd 创建的缓冲区 buftype 默认为 "acwrite"，需清空才能用 :write 保存
          pcall(vim.api.nvim_set_option_value, "buftype", "", { buf = bufnr })
          was_loaded = false
        end

        -- 用 nvim_buf_set_lines 替换缓冲区全部内容
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)

        -- 写入磁盘（优先使用 Neovim buffer 写入，失败则回退到 Lua io.open）
        local save_ok, save_err = pcall(vim.api.nvim_buf_call, bufnr, function()
          vim.cmd("write!")
        end)

        -- 清理临时加载的缓冲区（不留下隐藏缓冲区）
        if not was_loaded and vim.api.nvim_buf_is_valid(bufnr) then
          pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end

        if not save_ok then
          -- buffer 写入失败（如 buftype 限制），回退到 Lua io.open 写入
          local content_to_write = table.concat(new_lines, "\n")
          -- 保留原文件末尾换行符
          if content:sub(-1) == "\n" then
            content_to_write = content_to_write .. "\n"
          end
          local fu = require("NeoAI.utils.file_utils")
          fu.write_file_async(abs_path, content_to_write, function()
            vim.schedule(function()
              local ret = {
                filepath = filepath,
                language = result.language,
                deleted_count = #deletions,
                deletions = deletions,
                fallback_write = true,
              }
              if fallback then
                ret.warning = "未找到指定 node_type '"
                  .. (node_type or "")
                  .. "' 的节点，已回退到同类型节点"
              end
              if #skipped > 0 then
                ret.skipped_types = skipped
                ret.skipped_message = "以下节点类型不是代码块结构，已跳过: "
                  .. table.concat(skipped, ", ")
              end
              if #skipped_root > 0 then
                ret.skipped_root_types = skipped_root
                if ret.warning then
                  ret.warning = ret.warning .. "; 已跳过根容器节点: " .. table.concat(skipped_root, ", ")
                else
                  ret.warning = "已跳过根容器节点: " .. table.concat(skipped_root, ", ")
                end
              end
              if on_success then
                if timeout_timer then
                  timeout_timer:stop()
                  timeout_timer:close()
                end
                on_success(ret)
              end
            end)
          end, function(err)
            if on_error then
              finalize_with_timeout("保存文件失败（buffer 和 Lua 回退均失败）: " .. tostring(err), true)
            end
          end)
          return
        end

        local ret = {
          filepath = filepath,
          language = result.language,
          deleted_count = #deletions,
          deletions = deletions,
        }
        if fallback then
          ret.warning = "未找到指定 node_type '"
            .. (node_type or "")
            .. "' 的节点，已回退到同类型节点"
        end
        if #skipped > 0 then
          ret.skipped_types = skipped
          ret.skipped_message = "以下节点类型不是代码块结构，已跳过: " .. table.concat(skipped, ", ")
        end
        if #skipped_root > 0 then
          ret.skipped_root_types = skipped_root
          if ret.warning then
            ret.warning = ret.warning .. "; 已跳过根容器节点: " .. table.concat(skipped_root, ", ")
          else
            ret.warning = "已跳过根容器节点: " .. table.concat(skipped_root, ", ")
          end
        end
        if on_success then
          if timeout_timer then
            timeout_timer:stop()
            timeout_timer:close()
          end
          on_success(ret)
        end
      end)
    end)
  end, function(err)
    finalize_with_timeout(err or "解析结果为空", true)
  end)
end

M.delete_node = {
  name = "delete_node",
  description = "删除文件中匹配的 Tree-sitter 语法树节点，支持按 node_type、text、named 属性过滤。多个匹配时需用 index 参数指定删除第几个。删除后自动保存文件。",
  func = _delete_node,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      node_type = { type = "string", description = "节点类型过滤（可选，仅支持命名节点类型，匿名 token 如运算符 '+' 请使用 text 参数或 query_tree），如 'function_definition'" },
      text = { type = "string", description = "节点文本过滤（可选）" },
      named = { type = "boolean", description = "是否为命名节点（可选）" },
      index = {
        type = "number",
        description = "匹配节点序号（可选，从1开始），仅一个匹配时可省略，多个匹配时必须指定",
      },
    },
    required = { "filepath" },
  },
  returns = { type = "object", description = "删除结果，包含被删除的节点信息" },
  category = "treesitter",
  permissions = { write = true },
}

-- ============================================================================
-- 工具 edit_node - 修改指定语法树节点的内容（回调模式）
-- 用新内容替换匹配节点的源代码，保留节点位置不变
-- ============================================================================

local function _edit_node(args, on_success, on_error)
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
  if not args.content then
    if on_error then
      on_error("需要 content（新内容）参数")
    end
    return
  end
  if not args.node_type then
    if on_error then
      on_error(
        "需要 node_type（节点类型）参数，如 'function_definition'、'class_definition' 等。"
          .. "为防止意外匹配根节点导致整个文件被替换，edit_node 要求必须指定 node_type。"
      )
    end
    return
  end

  local filepath = args.filepath
  local new_content = args.content
  local node_type = args.node_type
  local text = args.text
  local named = args.named
  local index = args.index
  local uv = vim.uv or vim.loop
  local finalized = false

  -- 总超时保护：30 秒
  local timeout_timer = uv.new_timer()
  local function finalize_with_timeout(msg, is_err)
    if finalized then
      return
    end
    finalized = true
    if timeout_timer then
      timeout_timer:stop()
      timeout_timer:close()
    end
    if is_err and on_error then
      on_error(msg)
    end
  end
  if timeout_timer then
    timeout_timer:start(
      30000,
      0,
      vim.schedule_wrap(function()
        finalize_with_timeout("edit_node 操作超时（30 秒）", true)
      end)
    )
  end

  parse_file_content_async(filepath, -1, function(result)
    local filtered = filter_nodes(result.nodes, node_type, text, named)
    if #filtered == 0 then
      if on_error then
        finalize_with_timeout(_build_no_match_error(node_type, result.nodes), true)
      end
      return
    end

    -- 根据 index 参数选择要编辑的节点
    -- 如果只有一个匹配，index 可省略；多个匹配时必须指定 index
    local target = nil
    if index ~= nil then
      local idx = tonumber(index)
      if not idx or idx < 1 or idx > #filtered then
        finalize_with_timeout("index 参数无效: " .. tostring(index) .. "。有效范围: 1 ~ " .. #filtered, true)
        return
      end
      target = filtered[idx]
    elseif #filtered == 1 then
      target = filtered[1]
    else
      -- 多个匹配但未指定 index，返回错误和所有匹配节点信息
      local details = {}
      for i, node in ipairs(filtered) do
        table.insert(details, string.format("  [%d] 类型: %s, 文本: %s, 位置: 行 %d-%d",
          i, node.type, node.text:gsub("\n", "\\n"):sub(1, 200), node.start_row + 1, node.end_row + 1))
      end
      finalize_with_timeout("匹配到 " .. #filtered .. " 个节点，请使用 index 参数指定要修改第几个:\n" .. table.concat(details, "\n"), true)
      return
    end

    -- 异步读取文件内容
    read_file_content_async(filepath, function(content)
      -- ======================================================================
      -- 分割文件内容并定位节点范围
      -- ======================================================================
      local file_lines = vim.split(content, "\n", { plain = true })
      local sr, sc, er, ec = target.start_row, target.start_col, target.end_row, target.end_col
      local new_content_lines = vim.split(new_content, "\n", { plain = true })

      -- 节点首行之前的文本（保留以维持列位置；不再依赖原文本计算缩进）
      local before_on_first_line = ""
      if sr + 1 <= #file_lines then
        before_on_first_line = file_lines[sr + 1]:sub(1, sc)
      end

      -- 构建文件首部：节点起始行之前的所有行
      local head_lines = {}
      for i = 1, sr do
        table.insert(head_lines, file_lines[i])
      end

      -- 构建文件尾部
      local tail_lines = {}
      if er + 1 <= #file_lines then
        local after_on_last_line = file_lines[er + 1]:sub(ec + 1)
        if after_on_last_line ~= "" then
          table.insert(tail_lines, after_on_last_line)
        end
      end
      for i = er + 2, #file_lines do
        table.insert(tail_lines, file_lines[i])
      end

      -- 拼接文件：首部 + 新内容（直接使用用户提供的内容，不额外重算缩进） + 尾部
      local new_parts = {}
      if sr == er then
        -- 单行节点：before + new_content + after 拼接在同一行
        local source_line = file_lines[sr + 1] or ""
        local before = source_line:sub(1, sc)
        local after = source_line:sub(ec + 1)

        for _, line in ipairs(head_lines) do
          table.insert(new_parts, line)
        end
        local combined = before .. new_content .. after
        table.insert(new_parts, combined)
        for _, line in ipairs(tail_lines) do
          table.insert(new_parts, line)
        end
      else
        -- 多行节点：根据原始节点缩进层级，调整新内容所有行的缩进
        -- 计算新内容的最小缩进（跳过空白行），以确定相对缩进基准
        for _, line in ipairs(head_lines) do
          table.insert(new_parts, line)
        end
        if #new_content_lines > 0 then
          -- 原始节点首行的缩进（before_on_first_line 中的前导空白）
          local original_indent = before_on_first_line:match("^(%s*)") or ""

          -- 计算新内容的最小缩进（跳过纯空白行）
          local new_min_indent = nil
          for _, line in ipairs(new_content_lines) do
            local trimmed = line:gsub("^%s+$", "")
            if #trimmed > 0 then
              local indent = line:match("^(%s*)") or ""
              if new_min_indent == nil or #indent < #new_min_indent then
                new_min_indent = indent
              end
            end
          end
          new_min_indent = new_min_indent or ""

          -- 逐行调整：原始缩进 + (行缩进 - 最小缩进)
          for i, line in ipairs(new_content_lines) do
            local trimmed = line:gsub("^%s+$", "")
            if #trimmed == 0 then
              table.insert(new_parts, line)
            else
              local line_indent = line:match("^(%s*)") or ""
              local content = line:sub(#line_indent + 1)
              local relative_indent = math.max(0, #line_indent - #new_min_indent)
              if i == 1 then
                -- 首行保留 before_on_first_line（可能含代码前缀如 "local "）
                table.insert(new_parts, before_on_first_line .. string.rep(" ", relative_indent) .. content)
              else
                -- 后续行以原始缩进为基准
                table.insert(new_parts, original_indent .. string.rep(" ", relative_indent) .. content)
              end
            end
          end
        end
        for _, line in ipairs(tail_lines) do
          table.insert(new_parts, line)
        end
      end
      local content_to_write = table.concat(new_parts, "\n")

      -- ======================================================================
      -- Step 6: 写入文件
      -- ======================================================================
      -- 保留原文件末尾换行符
      if content:sub(-1) == "\n" and content_to_write:sub(-1) ~= "\n" then
        content_to_write = content_to_write .. "\n"
      end

      local abs_path = filepath
      local fu = require("NeoAI.utils.file_utils")
      fu.write_file_async(abs_path, content_to_write, function()
        -- write_file_async 的回调在 fast event 上下文中，需切换到主线程
        vim.schedule(function()
          -- 如果文件已在 Neovim 中打开，刷新缓冲区
          local bufnr = vim.fn.bufnr(abs_path)
          if bufnr ~= -1 then
            pcall(vim.api.nvim_buf_call, bufnr, function()
              vim.cmd("edit!")
            end)
          end

          local ret = {
            filepath = filepath,
            language = result.language,
            node_type = target.type,
            start_row = sr,
            start_col = sc,
            end_row = er,
            end_col = ec,
          }
          if fallback then
            ret.warning = "未找到指定 node_type '"
              .. (node_type or "")
              .. "' 的节点，已回退到同类型节点"
          end
          if multi_match_warning then
            if ret.warning then
              ret.warning = ret.warning .. "; " .. multi_match_warning
            else
              ret.warning = multi_match_warning
            end
          end
          if on_success then
            if timeout_timer then
              timeout_timer:stop()
              timeout_timer:close()
            end
            on_success(ret)
          end
        end)
      end, function(err_msg)
        if on_error then
          finalize_with_timeout("写入文件失败: " .. err_msg, true)
        end
      end)
    end, function(err)
      finalize_with_timeout(err or "解析结果为空", true)
    end)
  end)
end

M.edit_node = {
  name = "edit_node",
  description = "修改文件中匹配的 Tree-sitter 语法树节点的源代码，用新内容替换。支持按 node_type、text、named 属性过滤。修改后自动保存文件。适用于替换函数体、类定义、控制流块等结构化代码块。",
  func = _edit_node,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径（必填）" },
      content = { type = "string", description = "替换的新源代码内容（必填）" },
      node_type = { type = "string", description = "节点类型过滤（必填，防止意外匹配根节点，仅支持命名节点类型，匿名 token 如运算符 '+' 请使用 text 参数或 query_tree），如 'function_definition'" },
      text = { type = "string", description = "节点文本过滤（可选）" },
      named = { type = "boolean", description = "是否为命名节点（可选）" },
      index = {
        type = "number",
        description = "匹配节点序号（可选，从1开始），仅一个匹配时可省略，多个匹配时必须指定",
      },
    },
    required = { "filepath", "content", "node_type" },
  },
  returns = {
    type = "object",
    properties = {
      filepath = { type = "string" },
      language = { type = "string" },
      node_type = { type = "string" },
      start_row = { type = "number" },
      start_col = { type = "number" },
      end_row = { type = "number" },
      end_col = { type = "number" },
    },
    description = "修改结果，包含被替换节点的位置信息",
  },
  category = "treesitter",
  permissions = { write = true },
}

-- 导出 parse_file_content_async 供 file_tools 等模块使用
-- 用于在读取大文件时获取语法树结构概览
function M.parse_file_content_async(filepath, max_depth, on_success, on_error)
  parse_file_content_async(filepath, max_depth, on_success, on_error)
end

return M

