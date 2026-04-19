-- 文件工具模块
-- 此模块为 NeoAI 插件提供了一系列文件操作工具，并管理这些工具的注册与调用
local M = {}

--- 注册文件工具
-- 尝试加载 `file_utils` 模块，并基于其功能定义一组工具函数。
-- 每个工具都包装了对 `file_utils` 中对应函数的调用，并添加了参数校验。
-- @return table 成功时返回工具列表，失败时返回空表
function M.register_file_tools()
  -- 安全地尝试加载依赖模块
  local ok, file_utils = pcall(require, "NeoAI.utils.file_utils")
  if not ok then
    vim.notify("无法加载 file_utils 模块: " .. (file_utils or "未知错误"), vim.log.levels.ERROR)
    return {}
  end -- 这里添加缺失的 end 关键字

  local tools = {
    {
      name = "read_file",
      description = "读取文件内容",
      func = function(params)
        -- 参数校验：确保提供了文件路径
        if not params or not params.path then
          return nil, "缺少文件路径参数"
        end
        -- 调用底层工具函数
        return file_utils.read_file(params.path)
      end,
    },
    {
      name = "write_file",
      description = "写入文件内容",
      func = function(params)
        -- 参数校验：确保提供了文件路径和内容
        if not params or not params.path then
          return nil, "缺少文件路径参数"
        end
        if params.content == nil then
          return nil, "缺少内容参数"
        end
        -- 调用底层工具函数，append 参数可选
        return file_utils.write_file(params.path, params.content, params.append)
      end,
    },
    {
      name = "list_files",
      description = "列出目录中的文件",
      func = function(params)
        -- 参数校验：确保提供了目录路径
        if not params or not params.dir then
          return nil, "缺少目录路径参数"
        end
        -- 调用底层工具函数，pattern 参数可选
        return file_utils.list_files(params.dir, params.pattern)
      end,
    },
    {
      name = "search_files",
      description = "搜索文件",
      func = function(params)
        -- 参数校验：确保提供了目录路径
        if not params or not params.dir then
          return nil, "缺少目录路径参数"
        end
        -- 调用底层工具函数，pattern 和 recursive 参数可选
        return file_utils.search_files(params.dir, params.pattern, params.recursive)
      end,
    },
    {
      name = "file_exists",
      description = "检查文件是否存在",
      func = function(params)
        -- 参数校验：确保提供了路径
        if not params or not params.path then
          return nil, "缺少路径参数"
        end
        -- 调用底层工具函数
        return file_utils.file_exists(params.path)
      end,
    },
    {
      name = "create_directory",
      description = "创建目录",
      func = function(params)
        -- 参数校验：确保提供了目录路径
        if not params or not params.dir then
          return nil, "缺少目录路径参数"
        end
        -- 调用底层工具函数
        return file_utils.create_directory(params.dir)
      end,
    },
  }

  return tools
end

--- 获取所有可用工具
-- 收集并返回当前模块注册的所有工具。
-- 目前主要整合文件工具，未来可在此处添加其他类型的工具。
-- @return table 包含所有工具定义的列表
function M.get_all_tools()
  local all_tools = {}

  -- 添加文件工具
  local file_tools = M.register_file_tools()
  if type(file_tools) == "table" then
    for _, tool in ipairs(file_tools) do
      table.insert(all_tools, tool)
    end
  else
    vim.notify("file_tools 不是table类型: " .. type(file_tools), vim.log.levels.WARN)
  end

  return all_tools
end

--- 通过名称查找工具
-- 在已注册的工具列表中，查找指定名称的工具定义。
-- @param tool_name string 要查找的工具名称
-- @return table|nil 如果找到则返回工具定义，否则返回 nil
function M.get_tool(tool_name)
  local tools = M.get_all_tools()
  for _, tool in ipairs(tools) do
    if tool.name == tool_name then
      return tool
    end
  end
  return nil
end

--- 检查指定名称的工具是否存在
-- @param tool_name string 要检查的工具名称
-- @return boolean 工具存在则返回 true，否则返回 false
function M.has_tool(tool_name)
  return M.get_tool(tool_name) ~= nil
end

--- 执行指定工具
-- 根据工具名称查找工具，并使用提供的参数执行它。
-- @param tool_name string 要执行的工具名称
-- @param params table 传递给工具函数的参数表
-- @return any, string|nil 成功时返回工具执行结果，失败时返回 nil 和错误信息
function M.execute_tool(tool_name, params)
  local tool = M.get_tool(tool_name)
  if not tool then
    return nil, "工具不存在: " .. tool_name
  end
  -- 调用工具的实际功能函数
  return tool.func(params)
end

-- 导出模块
return M
