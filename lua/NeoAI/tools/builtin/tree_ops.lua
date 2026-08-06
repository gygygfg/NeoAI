--- Tree-sitter 语法树工具
--- @module NeoAI.tools.builtin.tree_ops
--- 通过 Neovim 内置 treesitter（vim.treesitter）提供代码分析工具。

local helpers = require("NeoAI.tools.builtin.tool_helpers")

local M = {}

-- ========== 私有函数 ==========

--- 确保文件已加载且有 parser
--- @param filepath string
--- @return number|nil bufnr
local function _ensure_parsed(filepath)
  if not filepath or filepath == "" then return nil end
  local bufnr = vim.fn.bufnr(filepath)
  if bufnr < 0 then return nil end
  local ok = pcall(vim.treesitter.get_parser, bufnr)
  if not ok then return nil end
  return bufnr
end

--- 获取语法树
--- @param bufnr number
--- @return TSNode|nil root
local function _root(bufnr)
  local parser = vim.treesitter.get_parser(bufnr)
  if not parser then return nil end
  local tree = parser:parse()[1]
  return tree and tree:root()
end

--- 在指定行/列查找节点
--- @param bufnr number
--- @param row number 0-based
--- @param col number 0-based
--- @return TSNode|nil
local function _node_at(bufnr, row, col)
  local root = _root(bufnr)
  if not root then return nil end
  return root:named_descendant_for_range(row, col, row, col)
end

--- 节点范围
--- @param node TSNode
--- @return number start_row, number start_col, number end_row, number end_col
local function _node_range(node)
  return node:range()
end

--- 获取节点源代码
--- @param node TSNode
--- @param bufnr number
--- @return string
local function _node_code(node, bufnr)
  local sr, sc, er, ec = _node_range(node)
  local lines = vim.api.nvim_buf_get_lines(bufnr, sr, er + 1, false)
  if #lines == 0 then return "" end
  lines[1] = lines[1]:sub(sc + 1)
  lines[#lines] = lines[#lines]:sub(1, ec - (sr == er and sc or 0))
  return table.concat(lines, "\n")
end

-- ========== 工具定义 ==========

local tree_tools = {}

tree_tools.parse_file = helpers.define_tool(
  "parse_file",
  "解析文件语法树并返回根节点概览。filepath 必填。",
  {
    type = "object",
    properties = { filepath = { type = "string" } },
    required = { "filepath" },
  },
  function(args, on_success, on_error)
    local bufnr = _ensure_parsed(args.filepath)
    if not bufnr then on_error("无法解析文件（缺少 parser 或文件未打开）") return end
    local root = _root(bufnr)
    if not root then on_error("无法获取语法树") return end
    on_success(string.format("root: %s, children: %d", root:type(), root:child_count()))
  end,
  { category = "treesitter" }
)

tree_tools.get_node_at_position = helpers.define_tool(
  "get_node_at_position",
  "获取指定位置（行/列）的语法树节点。filepath/line/col 必填（1-based）。",
  {
    type = "object",
    properties = { filepath = { type = "string" }, line = { type = "integer" }, col = { type = "integer" } },
    required = { "filepath", "line", "col" },
  },
  function(args, on_success, on_error)
    local bufnr = _ensure_parsed(args.filepath)
    if not bufnr then on_error("无法解析文件") return end
    local node = _node_at(bufnr, (args.line or 1) - 1, (args.col or 1) - 1)
    if not node then on_error("位置无节点") return end
    local sr, sc, er, ec = _node_range(node)
    on_success(string.format("%s %d:%d-%d:%d", node:type(), sr + 1, sc + 1, er + 1, ec + 1))
  end,
  { category = "treesitter" }
)

tree_tools.get_node_type = helpers.define_tool(
  "get_node_type",
  "获取节点类型。filepath/line/col 必填。",
  {
    type = "object",
    properties = { filepath = { type = "string" }, line = { type = "integer" }, col = { type = "integer" } },
    required = { "filepath", "line", "col" },
  },
  function(args, on_success, on_error)
    local bufnr = _ensure_parsed(args.filepath)
    if not bufnr then on_error("无法解析文件") return end
    local node = _node_at(bufnr, (args.line or 1) - 1, (args.col or 1) - 1)
    if not node then on_error("位置无节点") return end
    on_success(node:type())
  end,
  { category = "treesitter" }
)

tree_tools.get_node_range = helpers.define_tool(
  "get_node_range",
  "获取节点范围。filepath/line/col 必填。",
  {
    type = "object",
    properties = { filepath = { type = "string" }, line = { type = "integer" }, col = { type = "integer" } },
    required = { "filepath", "line", "col" },
  },
  function(args, on_success, on_error)
    local bufnr = _ensure_parsed(args.filepath)
    if not bufnr then on_error("无法解析文件") return end
    local node = _node_at(bufnr, (args.line or 1) - 1, (args.col or 1) - 1)
    if not node then on_error("位置无节点") return end
    local sr, sc, er, ec = _node_range(node)
    on_success(string.format("%d:%d-%d:%d", sr + 1, sc + 1, er + 1, ec + 1))
  end,
  { category = "treesitter" }
)

tree_tools.is_named_node = helpers.define_tool(
  "is_named_node",
  "检查节点是否为命名节点。filepath/line/col 必填。",
  {
    type = "object",
    properties = { filepath = { type = "string" }, line = { type = "integer" }, col = { type = "integer" } },
    required = { "filepath", "line", "col" },
  },
  function(args, on_success, on_error)
    local bufnr = _ensure_parsed(args.filepath)
    if not bufnr then on_error("无法解析文件") return end
    local node = _node_at(bufnr, (args.line or 1) - 1, (args.col or 1) - 1)
    if not node then on_error("位置无节点") return end
    on_success(tostring(node:named()))
  end,
  { category = "treesitter" }
)

tree_tools.get_parent_node = helpers.define_tool(
  "get_parent_node",
  "获取节点父节点。filepath/line/col 必填。",
  {
    type = "object",
    properties = { filepath = { type = "string" }, line = { type = "integer" }, col = { type = "integer" } },
    required = { "filepath", "line", "col" },
  },
  function(args, on_success, on_error)
    local bufnr = _ensure_parsed(args.filepath)
    if not bufnr then on_error("无法解析文件") return end
    local node = _node_at(bufnr, (args.line or 1) - 1, (args.col or 1) - 1)
    if not node then on_error("位置无节点") return end
    local parent = node:parent()
    if not parent then on_error("无父节点") return end
    local sr, sc, er, ec = _node_range(parent)
    on_success(string.format("%s %d:%d-%d:%d", parent:type(), sr + 1, sc + 1, er + 1, ec + 1))
  end,
  { category = "treesitter" }
)

tree_tools.get_child_nodes = helpers.define_tool(
  "get_child_nodes",
  "获取节点子节点列表。filepath/line/col 必填。",
  {
    type = "object",
    properties = { filepath = { type = "string" }, line = { type = "integer" }, col = { type = "integer" } },
    required = { "filepath", "line", "col" },
  },
  function(args, on_success, on_error)
    local bufnr = _ensure_parsed(args.filepath)
    if not bufnr then on_error("无法解析文件") return end
    local node = _node_at(bufnr, (args.line or 1) - 1, (args.col or 1) - 1)
    if not node then on_error("位置无节点") return end
    local out = {}
    for i = 0, node:child_count() - 1 do
      local c = node:child(i)
      if c then
        local sr, sc, er, ec = _node_range(c)
        out[#out + 1] = string.format("%d: %s %d:%d", i, c:type(), sr + 1, sc + 1)
      end
    end
    on_success(#out > 0 and table.concat(out, "\n") or "无子节点")
  end,
  { category = "treesitter" }
)

tree_tools.get_node_code = helpers.define_tool(
  "get_node_code",
  "获取节点源代码。filepath/line/col 必填。",
  {
    type = "object",
    properties = { filepath = { type = "string" }, line = { type = "integer" }, col = { type = "integer" } },
    required = { "filepath", "line", "col" },
  },
  function(args, on_success, on_error)
    local bufnr = _ensure_parsed(args.filepath)
    if not bufnr then on_error("无法解析文件") return end
    local node = _node_at(bufnr, (args.line or 1) - 1, (args.col or 1) - 1)
    if not node then on_error("位置无节点") return end
    on_success(_node_code(node, bufnr))
  end,
  { category = "treesitter" }
)

tree_tools.query_tree = helpers.define_tool(
  "query_tree",
  "用 treesitter query 查询节点。filepath 必填，query 必填。",
  {
    type = "object",
    properties = { filepath = { type = "string" }, query = { type = "string" } },
    required = { "filepath", "query" },
  },
  function(args, on_success, on_error)
    local bufnr = _ensure_parsed(args.filepath)
    if not bufnr then on_error("无法解析文件") return end
    local lang = vim.treesitter.language.get_lang(vim.bo[bufnr].filetype) or vim.bo[bufnr].filetype
    local ok, query = pcall(vim.treesitter.query.parse, lang, args.query)
    if not ok then on_error("query 解析失败: " .. tostring(query)) return end
    local root = _root(bufnr)
    if not root then on_error("无法获取语法树") return end
    local out = {}
    for id, node, metadata in query:iter_captures(root, bufnr) do
      local name = query.captures[id] or tostring(id)
      local sr, sc, er, ec = _node_range(node)
      out[#out + 1] = string.format("%s %d:%d-%d:%d", name, sr + 1, sc + 1, er + 1, ec + 1)
    end
    on_success(#out > 0 and table.concat(out, "\n") or "无匹配")
  end,
  { category = "treesitter" }
)

tree_tools.delete_node = helpers.define_tool(
  "delete_node",
  "删除语法树节点。filepath/line/col 必填。",
  {
    type = "object",
    properties = { filepath = { type = "string" }, line = { type = "integer" }, col = { type = "integer" } },
    required = { "filepath", "line", "col" },
  },
  function(args, on_success, on_error)
    local bufnr = _ensure_parsed(args.filepath)
    if not bufnr then on_error("无法解析文件") return end
    local node = _node_at(bufnr, (args.line or 1) - 1, (args.col or 1) - 1)
    if not node then on_error("位置无节点") return end
    local sr, sc, er, ec = _node_range(node)
    local ok = pcall(vim.api.nvim_buf_set_text, bufnr, sr, sc, er, ec, {})
    if not ok then on_error("删除失败") return end
    on_success(string.format("已删除节点 %s (%d:%d-%d:%d)", node:type(), sr + 1, sc + 1, er + 1, ec + 1))
  end,
  { category = "treesitter", approval = { auto_allow = false } }
)

--- 获取工具列表
--- @return table 数组
function M.get_tools()
  local out = {}
  for _, tool in pairs(tree_tools) do
    out[#out + 1] = tool
  end
  return out
end

return M
