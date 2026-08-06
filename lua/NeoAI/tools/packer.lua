--- 工具分组打包
--- @module NeoAI.tools.packer
--- 按类别对工具调用分组，用于 UI 分类展示和分批执行。

local M = {}

-- ========== 私有常量 ==========

local PACK_ORDER = {
  file = 1,
  system = 2,
  git = 3,
  treesitter = 4,
  lsp = 5,
  log = 6,
  agent = 7,
}

-- ========== 公开 API ==========

--- 按包分组工具调用
--- @param tool_calls table 数组 { name | {name, ...} }
--- @return table { [category] = { tool_calls } }
function M.group_by_pack(tool_calls)
  local grouped = {}
  for _, call in ipairs(tool_calls or {}) do
    local name = type(call) == "string" and call or (call.name or call.tool or (call["function"] and call["function"].name))
    if name then
      local category = M.get_pack_for_tool(name) or "other"
      if not grouped[category] then grouped[category] = {} end
      grouped[category][#grouped[category] + 1] = call
    end
  end
  return grouped
end

--- 获取工具所属类别（默认返回注册表中的 category，否则 fallback 表）
--- @param tool_name string
--- @return string
function M.get_pack_for_tool(tool_name)
  local fallback = {
    read_file = "file", edit_file = "file", list_files = "file",
    search_files = "file", file_exists = "file", create_directory = "file",
    ensure_dir = "file", delete_file = "file", confirm_file_change = "file",
    run_command = "system",
    git_diff = "git", git_log = "git", git_status = "git",
    git_commit_detail = "git", git_rollback = "git", git_file_history = "git",
    git_branch = "git", git_auto_commit_config = "git",
    parse_file = "treesitter", query_tree = "treesitter",
    get_node_at_position = "treesitter", get_node_type = "treesitter",
    get_node_range = "treesitter", is_named_node = "treesitter",
    get_parent_node = "treesitter", get_child_nodes = "treesitter",
    get_node_code = "treesitter", delete_node = "treesitter",
    lsp_hover = "lsp", lsp_definition = "lsp", lsp_references = "lsp",
    lsp_implementation = "lsp", lsp_declaration = "lsp",
    lsp_document_symbols = "lsp", lsp_workspace_symbols = "lsp",
    lsp_code_action = "lsp", lsp_rename = "lsp", lsp_format = "lsp",
    lsp_diagnostics = "lsp", lsp_client_info = "lsp",
    lsp_signature_help = "lsp", lsp_completion = "lsp",
    lsp_type_definition = "lsp", lsp_service_info = "lsp",
    log_message = "log", get_log_levels = "log",
    create_sub_agent = "agent", get_sub_agent_status = "agent",
    cancel_sub_agent = "agent",
  }
  -- 已知工具优先用 fallback 映射（避免注册时未显式标类导致归类错误）
  local known = fallback[tool_name]
  if known then return known end
  local registry = require("NeoAI.tools.registry")
  local tool = registry.get(tool_name)
  if tool and tool.category and tool.category ~= "other" then return tool.category end
  return "other"
end

--- 获取所有类别（按顺序排序）
--- @return table 数组
function M.get_all_packs()
  local packs = {}
  local seen = {}
  for name, order in pairs(PACK_ORDER) do
    packs[#packs + 1] = { name = name, order = order }
    seen[name] = true
  end
  table.sort(packs, function(a, b) return a.order < b.order end)
  local out = {}
  for _, p in ipairs(packs) do out[#out + 1] = p.name end
  return out
end

--- 类别显示名
--- @param category string
--- @return string
function M.pack_display_name(category)
  local names = {
    file = "文件操作",
    system = "系统命令",
    git = "Git",
    treesitter = "语法树",
    lsp = "LSP",
    log = "日志",
    agent = "子 Agent",
    other = "其它",
  }
  return names[category] or category
end

return M
