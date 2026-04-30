-- 工具包管理模块
-- 将相关工具组织为"工具包"，支持批次并发执行和分组显示
--
-- 工具包定义：
--   pack_name: 包名（如 "file_tools"）
--   display_name: 显示名称（如 "文件操作"）
--   tools: 包内工具名列表
--   icon: 显示图标
--
-- 使用方式：
--   1. 工具定义时通过 category 字段指定所属包
--   2. tool_orchestrator 按包分组并发执行
--   3. UI 按包分组显示执行状态

local M = {}

local logger = require("NeoAI.utils.logger")

-- ========== 工具包注册表 ==========

--- @type table<string, ToolPack>
--- ToolPack = { name: string, display_name: string, icon: string, tools: string[], order: number }
local packs = {}

-- ========== 内置工具包定义 ==========

local default_packs = {
  file_tools = {
    name = "file_tools",
    display_name = "文件操作",
    icon = "📁",
    tools = {
      "read_file",
      "write_file",
      "list_files",
      "search_files",
      "file_exists",
      "create_directory",
      "ensure_dir",
      "delete_file",
    },
    order = 1,
  },
  lsp_tools = {
    name = "lsp_tools",
    display_name = "代码分析",
    icon = "🔍",
    tools = {
      "lsp_hover",
      "lsp_definition",
      "lsp_references",
      "lsp_implementation",
      "lsp_declaration",
      "lsp_document_symbols",
      "lsp_workspace_symbols",
      "lsp_code_action",
      "lsp_rename",
      "lsp_format",
      "lsp_diagnostics",
      "lsp_client_info",
      "lsp_signature_help",
      "lsp_completion",
      "lsp_type_definition",
      "lsp_service_info",
    },
    order = 2,
  },
  treesitter_tools = {
    name = "treesitter_tools",
    display_name = "语法分析",
    icon = "🌳",
    tools = {
      "parse_file",
      "query_tree",
      "get_node_at_position",
      "get_node_type",
      "get_node_range",
      "is_named_node",
      "get_parent_node",
      "get_child_nodes",
    },
    order = 3,
  },
  log_tools = {
    name = "log_tools",
    display_name = "日志",
    icon = "📝",
    tools = { "log_message", "get_log_levels" },
    order = 4,
  },
  system_tools = {
    name = "system_tools",
    display_name = "系统",
    icon = "⚙️",
    tools = { "stop_tool_loop" },
    order = 5,
  },
}

-- ========== 初始化 ==========

function M.initialize()
  for name, def in pairs(default_packs) do
    packs[name] = vim.deepcopy(def)
  end
end

-- ========== 注册/查询 ==========

--- 注册一个工具包
--- @param pack_def table { name, display_name, icon, tools, order? }
function M.register_pack(pack_def)
  if not pack_def or not pack_def.name then
    return false
  end
  packs[pack_def.name] = vim.deepcopy(pack_def)
  return true
end

--- 获取工具包定义
--- @param pack_name string
--- @return table|nil
function M.get_pack(pack_name)
  return packs[pack_name] and vim.deepcopy(packs[pack_name]) or nil
end

--- 获取工具所属的包名
--- @param tool_name string
--- @return string|nil 包名，未归属返回 nil
function M.get_pack_for_tool(tool_name)
  for _, pack in pairs(packs) do
    for _, t in ipairs(pack.tools) do
      if t == tool_name then
        return pack.name
      end
    end
  end
  return nil
end

--- 获取所有工具包
--- @return table[]
function M.get_all_packs()
  local result = {}
  for _, pack in pairs(packs) do
    table.insert(result, vim.deepcopy(pack))
  end
  table.sort(result, function(a, b)
    return (a.order or 99) < (b.order or 99)
  end)
  return result
end

--- 获取工具包显示名称
--- @param pack_name string
--- @return string
function M.get_pack_display_name(pack_name)
  if pack_name == "_uncategorized" then
    return "工具调用"
  end
  local pack = packs[pack_name]
  return pack and pack.display_name or pack_name or "工具调用"
end

--- 获取工具包图标
--- @param pack_name string
--- @return string
function M.get_pack_icon(pack_name)
  if pack_name == "_uncategorized" then
    return "🔧"
  end
  local pack = packs[pack_name]
  return pack and pack.icon or "🔧"
end

--- 获取工具包内的工具列表
--- @param pack_name string
--- @return string[]
function M.get_pack_tools(pack_name)
  local pack = packs[pack_name]
  return pack and vim.deepcopy(pack.tools) or {}
end

-- ========== 工具调用分组 ==========

--- 将工具调用列表按包分组
--- @param tool_calls table[] 工具调用列表，每个元素包含 { name, ... }
--- @return table<string, table[]> 按包名分组的工具调用
function M.group_by_pack(tool_calls)
  local grouped = {}
  local uncategorized = {}

  for _, tc in ipairs(tool_calls) do
    -- 兼容多种工具调用格式：{ name = "xxx" }, { func = { name = "xxx" } }, { ["function"] = { name = "xxx" } }
    local tool_name = tc.name
      or (tc.func and tc.func.name)
      or (tc["function"] and tc["function"].name)
      or ""
    local pack_name = M.get_pack_for_tool(tool_name)

    if pack_name then
      if not grouped[pack_name] then
        grouped[pack_name] = {}
      end
      table.insert(grouped[pack_name], tc)
    else
      table.insert(uncategorized, tc)
    end
  end

  -- 如果有未分类的工具，也加入结果
  if #uncategorized > 0 then
    grouped["_uncategorized"] = uncategorized
  end

  return grouped
end

--- 获取工具包的显示排序键
--- @param pack_name string
--- @return number
function M.get_pack_order(pack_name)
  local pack = packs[pack_name]
  return pack and pack.order or 99
end

return M
