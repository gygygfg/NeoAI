-- Lua文件操作工具模块
-- 提供文件读取、写入、查找、搜索等常用功能
-- 修复了原代码中的逻辑错误，并添加了详细中文注释
local M = {}

-- 本地辅助函数区域 ------------------------------------------------------

-- 读取文件内容的本地函数
-- @param path string 文件路径
-- @return string|nil, string|nil 成功返回内容，失败返回nil和错误信息
local function read_file_content(path)
  -- 打开文件，使用只读模式
  local file, err = io.open(path, "r")
  if not file then
    -- 修复：原代码此处有缩进问题，return语句提前返回
    -- 现在正确返回nil和错误信息
    return nil, err
  end

  -- 读取文件全部内容
  local content = file:read("*a")

  -- 关闭文件
  file:close()

  -- 返回读取到的内容
  return content
end

-- 写入文件内容的本地函数
-- @param path string 文件路径
-- @param content string 要写入的内容
-- @param append boolean 是否为追加模式，默认为false（覆盖模式）
-- @return boolean, string|nil 成功返回true，失败返回false和错误信息
local function write_file_content(path, content, append)
  -- 决定文件打开模式：追加或覆盖
  local mode = append and "a" or "w"

  -- 打开文件
  local file, err = io.open(path, mode)
  if not file then
    -- 修复：返回false和错误信息，而不是直接返回false
    return false, err
  end

  -- 写入内容
  file:write(content)

  -- 关闭文件
  file:close()

  -- 写入成功
  return true
end

-- 检查文件或目录是否存在
-- @param path string 文件或目录路径
-- @return boolean 是否存在
local function file_exists(path)
  local file = io.open(path, "r")
  if file then
    file:close()
    return true
  end
  return false
end

-- 创建目录（包括父目录）
-- @param path string 目录路径
-- @return boolean 是否创建成功
local function create_directory(path)
  -- 使用mkdir -p命令创建目录（包括不存在的父目录）
  -- 2>/dev/null 将错误信息重定向到空设备，不显示
  local cmd = 'mkdir -p "' .. path .. '" 2>/dev/null'
  local result = os.execute(cmd)
  return result == 0 or result == true
end

-- 公开API函数区域 ------------------------------------------------------

--- 读取文件内容
--- @param args table 参数表，包含path字段
--- @return string 成功返回文件内容，失败返回错误信息字符串
function M.read_file(args)
  -- 参数检查
  if not args or not args.path then
    return "错误: 需要文件路径"
  end

  local path = args.path
  local content, error_msg = read_file_content(path)

  if content then
    return content
  else
    return "错误: " .. (error_msg or "无法读取文件")
  end
end

--- 写入文件内容
--- @param args table 参数表，包含path和content字段，append可选
--- @return boolean 是否写入成功
function M.write_file(args)
  -- 参数检查
  if not args or not args.path or not args.content then
    return false
  end

  local path = args.path
  local content = args.content
  local append = args.append or false -- 默认为覆盖模式

  local success, error_msg = write_file_content(path, content, append)

  -- 返回写入结果
  return success
end

--- 列出目录中的文件
--- @param args table 参数表，可包含dir、pattern、recursive字段
--- @return table 文件路径列表
function M.list_files(args)
  local dir = args.dir or "." -- 默认当前目录
  local pattern = args.pattern or "*" -- 默认匹配所有文件
  local recursive = args.recursive or false -- 默认不递归

  -- 注意：此函数依赖于系统find命令，在非Unix系统上可能不工作
  local files = {}
  local find_cmd

  if recursive then
    -- 递归查找
    find_cmd = 'find "' .. dir .. '" -name "' .. pattern .. '" -type f 2>/dev/null | head -100'
  else
    -- 非递归查找，只查找当前目录
    find_cmd = 'find "' .. dir .. '" -maxdepth 1 -name "' .. pattern .. '" -type f 2>/dev/null'
  end

  local handle = io.popen(find_cmd)
  if handle then
    for line in handle:lines() do
      table.insert(files, line)
    end
    handle:close()
  end

  return files
end

--- 在文件中搜索指定内容
--- @param args table 参数表，必须包含pattern字段
--- @return table 搜索结果列表，每个结果包含file、line、content字段
function M.search_files(args)
  if not args or not args.pattern then
    return {}
  end

  local pattern = args.pattern
  local dir = args.dir or "." -- 默认当前目录
  local file_pattern = args.file_pattern or "*" -- 默认所有文件
  local case_sensitive = args.case_sensitive or false -- 默认不区分大小写

  local results = {}

  -- 构建grep命令
  local grep_cmd = "grep -n" -- -n显示行号
  if not case_sensitive then
    grep_cmd = grep_cmd .. " -i" -- -i忽略大小写
  end

  -- 转义单引号，避免shell注入
  local escaped_pattern = pattern:gsub("'", "'\"'\"'")
  grep_cmd = grep_cmd .. " -- '" .. escaped_pattern .. "' "

  -- 先查找符合条件的文件
  local find_cmd = 'find "' .. dir .. '" -type f -name "' .. file_pattern .. '" 2>/dev/null | head -50'
  local handle = io.popen(find_cmd)

  if handle then
    for file in handle:lines() do
      -- 在每个文件中搜索
      local search_handle = io.popen(grep_cmd .. '"' .. file .. '" 2>/dev/null')
      if search_handle then
        for line in search_handle:lines() do
          -- 解析grep输出格式：行号:内容
          local line_num, content = line:match("^(%d+):(.+)$")
          if line_num and content then
            table.insert(results, {
              file = file,
              line = tonumber(line_num),
              content = content,
            })
          end
        end
        search_handle:close()
      end
    end
    handle:close()
  end

  return results
end

--- 检查文件或目录是否存在
--- @param args table 参数表，包含path字段
--- @return boolean 是否存在
function M.file_exists(args)
  if not args or not args.path then
    return false
  end
  return file_exists(args.path)
end

--- 创建目录
--- @param args table 参数表，包含path字段，parents可选
--- @return boolean 是否创建成功
function M.create_directory(args)
  if not args or not args.path then
    return false
  end

  local path = args.path
  local parents = args.parents ~= false -- 默认为true，创建父目录

  if parents then
    -- 创建目录（包括父目录）
    return create_directory(path)
  else
    -- 只创建最后一级目录（父目录必须存在）
    local cmd = 'mkdir "' .. path .. '" 2>/dev/null'
    local result = os.execute(cmd)
    return result == 0 or result == true
  end
end

--- 获取所有可用的文件操作工具
--- @return table 工具列表，每个工具包含名称、描述、函数、参数定义等
function M.get_tools()
  return {
    {
      name = "read_file",
      description = "读取文件内容",
      func = M.read_file,
      parameters = {
        type = "object",
        properties = {
          path = {
            type = "string",
            description = "文件路径",
          },
        },
        required = { "path" },
      },
      returns = {
        type = "string",
        description = "文件内容",
      },
      category = "file",
      permissions = {
        read = true,
      },
    },
    {
      name = "write_file",
      description = "写入文件内容",
      func = M.write_file,
      parameters = {
        type = "object",
        properties = {
          path = {
            type = "string",
            description = "文件路径",
          },
          content = {
            type = "string",
            description = "要写入的内容",
          },
          append = {
            type = "boolean",
            description = "是否追加模式",
            default = false,
          },
        },
        required = { "path", "content" },
      },
      returns = {
        type = "boolean",
        description = "是否写入成功",
      },
      category = "file",
      permissions = {
        write = true,
      },
    },
    {
      name = "list_files",
      description = "列出目录中的文件",
      func = M.list_files,
      parameters = {
        type = "object",
        properties = {
          dir = {
            type = "string",
            description = "目录路径",
            default = ".",
          },
          pattern = {
            type = "string",
            description = "文件模式（如 *.lua）",
            default = "*",
          },
          recursive = {
            type = "boolean",
            description = "是否递归查找",
            default = false,
          },
        },
      },
      returns = {
        type = "array",
        items = {
          type = "string",
        },
        description = "文件路径列表",
      },
      category = "file",
      permissions = {
        read = true,
      },
    },
    {
      name = "search_files",
      description = "搜索文件内容",
      func = M.search_files,
      parameters = {
        type = "object",
        properties = {
          pattern = {
            type = "string",
            description = "搜索模式",
          },
          dir = {
            type = "string",
            description = "搜索目录",
            default = ".",
          },
          file_pattern = {
            type = "string",
            description = "文件模式（如 *.lua）",
            default = "*",
          },
          case_sensitive = {
            type = "boolean",
            description = "是否区分大小写",
            default = false,
          },
        },
        required = { "pattern" },
      },
      returns = {
        type = "array",
        items = {
          type = "object",
          properties = {
            file = { type = "string" },
            line = { type = "number" },
            content = { type = "string" },
          },
        },
        description = "匹配结果列表",
      },
      category = "file",
      permissions = {
        read = true,
      },
    },
    {
      name = "file_exists",
      description = "检查文件或目录是否存在",
      func = M.file_exists,
      parameters = {
        type = "object",
        properties = {
          path = {
            type = "string",
            description = "路径",
          },
        },
        required = { "path" },
      },
      returns = {
        type = "boolean",
        description = "是否存在",
      },
      category = "file",
      permissions = {
        read = true,
      },
    },
    {
      name = "create_directory",
      description = "创建目录",
      func = M.create_directory,
      parameters = {
        type = "object",
        properties = {
          path = {
            type = "string",
            description = "目录路径",
          },
          parents = {
            type = "boolean",
            description = "是否创建父目录",
            default = true,
          },
        },
        required = { "path" },
      },
      returns = {
        type = "boolean",
        description = "是否创建成功",
      },
      category = "file",
      permissions = {
        write = true,
      },
    },
  }
end

-- 模块测试用例 ------------------------------------------------------

-- 测试函数，演示模块功能
local function test_module()
  print("=== 开始测试文件操作模块 ===")

  -- 测试文件存在检查
  local test_file = "test_example.txt"
  local exists_args = { path = test_file }
  print("1. 检查测试文件是否存在:", M.file_exists(exists_args))

  -- 测试写入文件
  local write_args = {
    path = test_file,
    content = "这是测试文件内容\n第二行内容\n搜索测试关键字",
  }
  print("2. 写入测试文件:", M.write_file(write_args))

  -- 测试读取文件
  local read_args = { path = test_file }
  local content = M.read_file(read_args)
  -- 确保content是字符串类型
  local content_str = type(content) == "string" and content or ""
  print("3. 读取文件内容（前50字符）:", string.sub(content_str, 1, 50))

  -- 测试文件存在检查（写入后）
  print("4. 再次检查测试文件是否存在:", M.file_exists(exists_args))

  -- 测试列出文件
  local list_args = { dir = ".", pattern = "*.txt" }
  local files = M.list_files(list_args)
  print("5. 列出当前目录txt文件:")
  for i, file in ipairs(files) do
    print("  " .. i .. ". " .. file)
  end

  -- 测试搜索文件内容
  local search_args = {
    pattern = "测试",
    dir = ".",
    file_pattern = "*.txt",
  }
  local results = M.search_files(search_args)
  print("6. 搜索包含'测试'的内容:")
  for i, result in ipairs(results) do
    print("  " .. i .. ". 文件:" .. result.file .. " 行:" .. result.line .. " 内容:" .. result.content)
  end

  -- 测试创建目录
  local mkdir_args = { path = "test_dir/sub_dir" }
  print("7. 创建嵌套目录:", M.create_directory(mkdir_args))

  -- 清理测试文件
  os.execute("rm -f " .. test_file)
  os.execute("rm -rf test_dir")

  print("=== 测试完成 ===")
end

-- 如果直接运行此文件，则执行测试
if arg and arg[0] and arg[0]:match("file_tools%.lua$") then
  test_module()
end

return M
