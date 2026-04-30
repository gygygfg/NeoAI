-- 工具包管理模块
-- 从 ./builtin/*.lua 模块动态扫描工具定义，根据工具的 category 字段自动分组
--
-- 工具包定义：
--   pack_name: 包名（由 category 自动生成）
--   display_name: 显示名称
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

-- ========== 分类配置 ==========

--- 分类显示配置
--- key 为 category 值，value 为 { display_name, icon, order }
local category_config = {
  file = { display_name = "文件操作", icon = "📁", order = 1 },
  lsp = { display_name = "代码分析", icon = "🔍", order = 2 },
  treesitter = { display_name = "语法分析", icon = "🌳", order = 3 },
  log = { display_name = "日志", icon = "📝", order = 4 },
  system = { display_name = "系统", icon = "⚙️", order = 5 },
  uncategorized = { display_name = "工具调用", icon = "🔧", order = 99 },
}

-- ========== 初始化 ==========

--- 从 builtin 目录动态扫描工具，按 category 分组
function M.initialize()
  packs = {}

  local builtin_dir = debug.getinfo(1).source:match("^@(.+)$")
  if not builtin_dir then return end

  builtin_dir = builtin_dir:match("^(.+/)tool_pack%.lua$")
  if not builtin_dir then return end

  builtin_dir = builtin_dir .. "builtin"

  local handle = vim.loop.fs_scandir(builtin_dir)
  if not handle then return end

  while true do
    local name, type = vim.loop.fs_scandir_next(handle)
    if not name then break end
    if type == "file" and name:match("%.lua$") then
      local mod_name = name:gsub("%.lua$", "")
      local ok, mod = pcall(require, "NeoAI.tools.builtin." .. mod_name)
      if ok and mod and mod.get_tools then
        local tools = mod.get_tools()
        for _, tool in ipairs(tools) do
          if tool.name and tool.func then
            local cat = tool.category or "uncategorized"
            if not packs[cat] then
              local cfg = category_config[cat] or { display_name = cat, icon = "🔧", order = 99 }
              packs[cat] = {
                name = cat,
                display_name = cfg.display_name,
                icon = cfg.icon,
                tools = {},
                order = cfg.order,
              }
            end
            table.insert(packs[cat].tools, tool.name)
          end
        end
      end
    end
  end

  -- 对每个包内的工具列表排序
  for _, pack in pairs(packs) do
    table.sort(pack.tools)
  end
end

-- ========== 注册/查询 ==========

--- 注册一个工具包（外部扩展用）
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

--- 获取所有已注册的工具名称列表（展平所有包）
--- @return string[]
function M.get_all_tool_names()
  local names = {}
  local seen = {}
  for _, pack in pairs(packs) do
    for _, tool_name in ipairs(pack.tools) do
      if not seen[tool_name] then
        seen[tool_name] = true
        table.insert(names, tool_name)
      end
    end
  end
  table.sort(names)
  return names
end

-- ========== 工具调用分组 ==========

--- 将工具调用列表按包分组
--- @param tool_calls table[] 工具调用列表，每个元素包含 { name, ... }
--- @return table<string, table[]> 按包名分组的工具调用
function M.group_by_pack(tool_calls)
  local grouped = {}
  local uncategorized = {}

  for _, tc in ipairs(tool_calls) do
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
