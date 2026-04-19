local M = {}

-- 自动加载所有工具模块
local modules = {
  "common",
  "text_utils",
  "table_utils",
  "file_utils",
  "logger",
  "tool_registry",
}

-- 存储已加载的模块
local loaded_modules = {}

--- 初始化工具库
function M.initialize()
  for _, module_name in ipairs(modules) do
    local ok, module = pcall(require, "NeoAI.utils." .. module_name)
    if ok then
      loaded_modules[module_name] = module
      -- 将模块函数合并到主表中
      for func_name, func in pairs(module) do
        if type(func) == "function" then
          M[func_name] = func
        end
      end
    else
      local warn_level = vim.log.levels and vim.log.levels.WARN or "WARN"
      vim.notify("无法加载工具模块: " .. module_name, warn_level)
    end
  end
end

--- 获取特定模块
--- @param module_name string 模块名称
--- @return table|nil 模块
function M.get_module(module_name)
  return loaded_modules[module_name]
end

--- 重新加载所有模块
function M.reload()
  loaded_modules = {}
  M.initialize()
end

--- 列出所有可用模块
--- @return table 模块名称列表
function M.list_modules()
  local result = {}
  for module_name, _ in pairs(loaded_modules) do
    table.insert(result, module_name)
  end
  table.sort(result)
  return result
end

--- 检查模块是否已加载
--- @param module_name string 模块名称
--- @return boolean 是否已加载
function M.is_module_loaded(module_name)
  return loaded_modules[module_name] ~= nil
end

-- 自动初始化
M.initialize()

return M

