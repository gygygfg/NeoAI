-- Lua文件操作工具模块
-- 提供文件读取、写入、查找、搜索等常用功能
-- 每个工具的定义（名称、描述、参数、实现）集中在一起，方便修改
local M = {}

local define_tool = require("NeoAI.tools.builtin.tool_helpers").define_tool

-- 复用 file_utils 模块
local function get_file_utils()
  local ok, fu = pcall(require, "NeoAI.utils.file_utils")
  return ok and fu or nil
end

-- ============================================================================
-- 工具1: read_file - 读取文件内容
-- ============================================================================

local function _read_file(args)
  if not args then
    return "错误: 需要文件路径"
  end

  -- 支持 paths（列表）和 path（单个路径）两种参数
  local paths = args.paths or {}
  if args.path and type(args.path) == "string" then
    table.insert(paths, args.path)
  end

  if #paths == 0 then
    return "错误: 需要文件路径列表或单个文件路径"
  end

  local fu = get_file_utils()
  local results = {}

  for _, filepath in ipairs(paths) do
    local content, err
    if fu then
      content, err = fu.read_file(filepath)
    else
      local file, io_err = io.open(filepath, "r")
      if file then
        content = file:read("*a")
        file:close()
      else
        err = io_err or "无法读取文件"
      end
    end

    if content then
      local lines = {}
      local line_num = 1
      for line in content:gmatch("[^\n]+") do
        table.insert(lines, string.format("%4d | %s", line_num, line))
        line_num = line_num + 1
      end
      -- 处理文件末尾可能没有换行符的情况
      if content:sub(-1) == "\n" then
        table.insert(lines, string.format("%4d |", line_num))
      end
      table.insert(results, string.format("=== %s ===\n%s", filepath, table.concat(lines, "\n")))
    else
      table.insert(results, string.format("=== %s ===\n错误: %s", filepath, err or "无法读取文件"))
    end
  end

  return table.concat(results, "\n\n")
end

M.read_file = define_tool({
  name = "read_file",
  description = "读取一个或多个文件的内容，返回带行号的结果",
  func = _read_file,
  parameters = {
    type = "object",
    properties = {
      paths = {
        type = "array",
        items = { type = "string" },
        description = "文件路径列表（与 path 二选一）",
      },
      path = {
        type = "string",
        description = "单个文件路径（与 paths 二选一）",
      },
    },
    oneOf = {
      { required = { "paths" } },
      { required = { "path" } },
    },
  },
  returns = { type = "string", description = "带行号的文件内容" },
  category = "file",
  permissions = { read = true },
})

-- ============================================================================
-- 工具2: write_file - 写入文件内容
-- ============================================================================

local function _write_file(args)
  if not args or not args.path or not args.content then
    return false
  end

  local fu = get_file_utils()
  if fu then
    local ok, _ = fu.write_file(args.path, args.content, args.append or false)
    return ok == true
  end

  local mode = args.append and "a" or "w"
  local file, err = io.open(args.path, mode)
  if not file then
    return false
  end
  file:write(args.content)
  file:close()
  return true
end

M.write_file = define_tool({
  name = "write_file",
  description = "写入文件内容",
  func = _write_file,
  parameters = {
    type = "object",
    properties = {
      path = { type = "string", description = "文件路径" },
      content = { type = "string", description = "要写入的内容" },
      append = { type = "boolean", description = "是否追加模式", default = false },
    },
    required = { "path", "content" },
  },
  returns = { type = "boolean", description = "是否写入成功" },
  category = "file",
  permissions = { write = true },
})

-- ============================================================================
-- 工具3: list_files - 列出目录中的文件
-- ============================================================================

local function _list_files(args)
  if not args then
    return {}
  end

  -- 支持 dirs（列表）和 dir（单个）两种参数
  local dirs = args.dirs or {}
  if args.dir and type(args.dir) == "string" then
    table.insert(dirs, args.dir)
  end
  if #dirs == 0 then
    table.insert(dirs, ".")
  end

  local pattern = args.pattern or "*"
  local recursive = args.recursive or false
  local files = {}

  for _, dir in ipairs(dirs) do
    if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
      local dir_cmd = "dir " .. (recursive and "/s " or "") .. "/b /a:-d " .. vim.fn.shellescape(dir) .. " 2>nul"
      local output = vim.fn.systemlist(dir_cmd)
      if vim.v.shell_error == 0 then
        for _, line in ipairs(output) do
          if pattern == "*" or line:match(vim.pesc(pattern):gsub("%%%*", ".*"):gsub("%%%?", ".")) then
            table.insert(files, line)
          end
        end
      end
    else
      local ls_cmd = "ls"
      if recursive then
        ls_cmd = ls_cmd .. " -laR"
      else
        ls_cmd = ls_cmd .. " -la"
      end
      ls_cmd = ls_cmd .. " --format=single-column --time-style=long-iso " .. vim.fn.shellescape(dir) .. " 2>/dev/null"
      local output = vim.fn.systemlist(ls_cmd)
      if vim.v.shell_error == 0 then
        local current_dir = ""
        for _, line in ipairs(output) do
          if line:match("^$") then
          -- skip
          elseif line:match(":$") then
            current_dir = line:gsub(":$", "")
          elseif line ~= "." and line ~= ".." then
            if pattern == "*" or line:match(vim.pesc(pattern):gsub("%%%*", ".*"):gsub("%%%?", ".")) then
              local full_path
              if recursive and current_dir ~= "" then
                full_path = current_dir .. "/" .. line
              else
                full_path = dir .. "/" .. line
              end
              table.insert(files, full_path)
            end
          end
        end
      end
    end
  end

  return files
end

M.list_files = define_tool({
  name = "list_files",
  description = "列出目录中的文件",
  func = _list_files,
  parameters = {
    type = "object",
    properties = {
      dir = { type = "string", description = "单个目录路径（与 dirs 二选一）", default = "." },
      dirs = {
        type = "array",
        items = { type = "string" },
        description = "目录路径列表（与 dir 二选一）",
      },
      pattern = { type = "string", description = "文件模式（如 *.txt）", default = "*" },
      recursive = { type = "boolean", description = "是否递归查找", default = false },
    },
  },
  returns = { type = "array", items = { type = "string" }, description = "文件路径列表" },
  category = "file",
  permissions = { read = true },
})

-- ============================================================================
-- 工具4: search_files - 搜索文件内容
-- ============================================================================

local function _search_files(args)
  if not args or not args.pattern then
    return {}
  end

  local pattern = args.pattern
  local dir = args.dir or "."
  local file_pattern = args.file_pattern or "*"
  local case_sensitive = args.case_sensitive or false
  local results = {}

  local grep_cmd = "grep -n"
  if not case_sensitive then
    grep_cmd = grep_cmd .. " -i"
  end

  local escaped_pattern = pattern:gsub("'", "'\"'\"'")
  grep_cmd = grep_cmd .. " -- '" .. escaped_pattern .. "' "

  local find_cmd = 'find "' .. dir .. '" -type f -name "' .. file_pattern .. '" 2>/dev/null | head -50'
  local handle = io.popen(find_cmd)

  if handle then
    for file in handle:lines() do
      local search_handle = io.popen(grep_cmd .. '"' .. file .. '" 2>/dev/null')
      if search_handle then
        for line in search_handle:lines() do
          local line_num, content = line:match("^(%d+):(.+)$")
          if line_num and content then
            table.insert(results, { file = file, line = tonumber(line_num), content = content })
          end
        end
        search_handle:close()
      end
    end
    handle:close()
  end

  return results
end

M.search_files = define_tool({
  name = "search_files",
  description = "搜索文件内容",
  func = _search_files,
  parameters = {
    type = "object",
    properties = {
      pattern = { type = "string", description = "搜索模式" },
      dir = { type = "string", description = "搜索目录", default = "." },
      file_pattern = { type = "string", description = "文件模式（如 *.py）", default = "*" },
      case_sensitive = { type = "boolean", description = "是否区分大小写", default = false },
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
  permissions = { read = true },
})

-- ============================================================================
-- 工具5: file_exists - 检查文件或目录是否存在
-- ============================================================================

local function _file_exists(args)
  if not args then
    return {}
  end

  -- 支持 paths（列表）和 path（单个）两种参数
  local paths = args.paths or {}
  if args.path and type(args.path) == "string" then
    table.insert(paths, args.path)
  end

  if #paths == 0 then
    return {}
  end

  local fu = get_file_utils()
  local results = {}

  for _, p in ipairs(paths) do
    local exists
    if fu then
      exists = fu.exists(p)
    else
      local file = io.open(p, "r")
      if file then
        file:close()
        exists = true
      else
        exists = false
      end
    end
    table.insert(results, { path = p, exists = exists })
  end

  return results
end

M.file_exists = define_tool({
  name = "file_exists",
  description = "检查一个或多个文件或目录是否存在",
  func = _file_exists,
  parameters = {
    type = "object",
    properties = {
      path = { type = "string", description = "单个路径（与 paths 二选一）" },
      paths = {
        type = "array",
        items = { type = "string" },
        description = "路径列表（与 path 二选一）",
      },
    },
    oneOf = {
      { required = { "paths" } },
      { required = { "path" } },
    },
  },
  returns = {
    type = "array",
    items = {
      type = "object",
      properties = {
        path = { type = "string" },
        exists = { type = "boolean" },
      },
    },
    description = "路径存在状态列表",
  },
  category = "file",
  permissions = { read = true },
})

-- ============================================================================
-- 工具6: create_directory - 创建目录
-- ============================================================================

local function _create_directory(args)
  if not args then
    return {}
  end

  -- 支持 paths（列表）和 path（单个）两种参数
  local paths = args.paths or {}
  if args.path and type(args.path) == "string" then
    table.insert(paths, args.path)
  end

  if #paths == 0 then
    return {}
  end

  local fu = get_file_utils()
  local results = {}

  for _, p in ipairs(paths) do
    local ok
    if fu then
      local success, _ = fu.mkdir(p)
      ok = success == true
    else
      local cmd = 'mkdir -p "' .. p .. '" 2>/dev/null'
      local result = os.execute(cmd)
      ok = result == 0 or result == true
    end
    table.insert(results, { path = p, success = ok })
  end

  return results
end

M.create_directory = define_tool({
  name = "create_directory",
  description = "创建一个或多个目录",
  func = _create_directory,
  parameters = {
    type = "object",
    properties = {
      path = { type = "string", description = "单个目录路径（与 paths 二选一）" },
      paths = {
        type = "array",
        items = { type = "string" },
        description = "目录路径列表（与 path 二选一）",
      },
      parents = { type = "boolean", description = "是否创建父目录", default = true },
    },
    oneOf = {
      { required = { "paths" } },
      { required = { "path" } },
    },
  },
  returns = {
    type = "array",
    items = {
      type = "object",
      properties = {
        path = { type = "string" },
        success = { type = "boolean" },
      },
    },
    description = "目录创建结果列表",
  },
  category = "file",
  permissions = { write = true },
})

-- ============================================================================
-- 工具7: ensure_dir - 确保目录存在
-- ============================================================================

local function _ensure_dir(args)
  if not args then
    return {}
  end

  -- 支持 paths（列表）和 path（单个）两种参数
  local paths = args.paths or {}
  if args.path and type(args.path) == "string" then
    table.insert(paths, args.path)
  end

  if #paths == 0 then
    return {}
  end

  local fu = get_file_utils()
  local results = {}

  for _, p in ipairs(paths) do
    local ok
    if fu then
      local success, _ = fu.mkdir(p)
      ok = success == true
    else
      local clean_path = p:gsub("/+$", "")
      local cmd = 'mkdir -p "' .. clean_path .. '" 2>/dev/null'
      local result = os.execute(cmd)
      ok = result == 0 or result == true
    end
    table.insert(results, { path = p, success = ok })
  end

  return results
end

M.ensure_dir = define_tool({
  name = "ensure_dir",
  description = "确保一个或多个目录存在，如果不存在则创建",
  func = _ensure_dir,
  parameters = {
    type = "object",
    properties = {
      path = { type = "string", description = "单个目录路径（与 paths 二选一）" },
      paths = {
        type = "array",
        items = { type = "string" },
        description = "目录路径列表（与 path 二选一）",
      },
      parents = { type = "boolean", description = "是否创建父目录", default = true },
    },
    oneOf = {
      { required = { "paths" } },
      { required = { "path" } },
    },
  },
  returns = {
    type = "array",
    items = {
      type = "object",
      properties = {
        path = { type = "string" },
        success = { type = "boolean" },
      },
    },
    description = "目录确保结果列表",
  },
  category = "file",
  permissions = { write = true },
})

-- ============================================================================
-- 工具8: delete_file - 删除文件
-- ============================================================================

local function _delete_file(args)
  if not args then
    return {}
  end

  -- 支持 paths（列表）和 path（单个）两种参数
  local paths = args.paths or {}
  if args.path and type(args.path) == "string" then
    table.insert(paths, args.path)
  end

  if #paths == 0 then
    return {}
  end

  local results = {}

  for _, p in ipairs(paths) do
    local ok, err
    local file = io.open(p, "r")
    if file then
      file:close()
      local success = os.remove(p)
      if success then
        ok = true
      else
        ok = false
        err = "无法删除文件"
      end
    else
      ok = false
      err = "文件不存在"
    end
    table.insert(results, { path = p, success = ok, error = err })
  end

  return results
end

M.delete_file = define_tool({
  name = "delete_file",
  description = "删除一个或多个文件",
  func = _delete_file,
  parameters = {
    type = "object",
    properties = {
      path = { type = "string", description = "单个文件路径（与 paths 二选一）" },
      paths = {
        type = "array",
        items = { type = "string" },
        description = "文件路径列表（与 path 二选一）",
      },
    },
    oneOf = {
      { required = { "paths" } },
      { required = { "path" } },
    },
  },
  returns = {
    type = "array",
    items = {
      type = "object",
      properties = {
        path = { type = "string" },
        success = { type = "boolean" },
        error = { type = "string", description = "失败时的错误信息" },
      },
    },
    description = "文件删除结果列表",
  },
  category = "file",
  permissions = { write = true },
})

-- ============================================================================
-- get_tools() - 返回所有工具列表供注册
-- ============================================================================

function M.get_tools()
  local tools = {}
  for _, v in pairs(M) do
    if type(v) == "table" and v.name and v.func then
      table.insert(tools, v)
    end
  end
  -- 按名称排序
  table.sort(tools, function(a, b)
    return a.name < b.name
  end)
  return tools
end

-- 模块测试用例
local function test_module()
  print("=== 开始测试文件操作模块 ===")

  local test_file = "test_example.txt"
  print("1. 检查测试文件是否存在:", M.file_exists.func({ path = test_file }))

  print(
    "2. 写入测试文件:",
    M.write_file.func({ path = test_file, content = "测试内容\n第二行\n关键字" })
  )

  local content = M.read_file.func({ path = test_file })
  local content_str = type(content) == "string" and content or ""
  print("3. 读取文件内容（前50字符）:", string.sub(content_str, 1, 50))

  print("4. 再次检查测试文件是否存在:", M.file_exists.func({ path = test_file }))

  local files = M.list_files.func({ dir = ".", pattern = "*.txt" })
  print("5. 列出当前目录txt文件:")
  for i, file in ipairs(files) do
    print("  " .. i .. ". " .. file)
  end

  local results = M.search_files.func({ pattern = "关键字", dir = ".", file_pattern = "*.txt" })
  print("6. 搜索包含'关键字'的内容:")
  for i, result in ipairs(results) do
    print("  " .. i .. ". 文件:" .. result.file .. " 行:" .. result.line .. " 内容:" .. result.content)
  end

  print("7. 创建嵌套目录:", M.create_directory.func({ path = "test_dir/sub_dir" }))

  os.execute("rm -f " .. test_file)
  os.execute("rm -rf test_dir")

  print("=== 测试完成 ===")
end

if arg and arg[0] and arg[0]:match("file_tools%.lua$") then
  test_module()
end

return M
