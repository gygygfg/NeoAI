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
-- 工具 read_file - 读取文件内容
-- ============================================================================

local function _read_file(args)
  if not args then
    return "错误: 需要文件参数"
  end

  -- 支持 files（列表）和 file（单个）两种参数
  local files = args.files or {}
  if args.file and type(args.file) == "table" then
    table.insert(files, args.file)
  end

  if #files == 0 then
    return "错误: 需要文件列表或单个文件参数"
  end

  local fu = get_file_utils()
  local results = {}

  for _, f in ipairs(files) do
    local filepath = f.filepath
    if not filepath then
      table.insert(results, string.format("=== (未知文件) ===\n错误: 缺少 filepath 字段"))
      goto continue
    end

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

    if not content then
      table.insert(results, string.format("=== %s ===\n错误: %s", filepath, err or "无法读取文件"))
      goto continue
    end

    -- 解析行范围
    local start_line = f.start or 1
    local end_line = f["end"] or -1 -- -1 表示读取到末尾

    -- 将内容按行分割
    local all_lines = {}
    for line in content:gmatch("[^\n]+") do
      table.insert(all_lines, line)
    end
    -- 处理文件末尾换行符
    local total_lines = #all_lines
    if content:sub(-1) == "\n" then
      total_lines = total_lines + 1
    end

    -- 规范化行号
    if start_line < 1 then
      start_line = 1
    end
    if end_line < 0 or end_line > total_lines then
      end_line = total_lines
    end
    if start_line > end_line then
      table.insert(
        results,
        string.format("=== %s ===\n错误: 起始行(%d)大于结束行(%d)", filepath, start_line, end_line)
      )
      goto continue
    end

    -- 提取指定行范围
    local output_lines = {}
    for i = start_line, end_line do
      local line_content = all_lines[i] or ""
      table.insert(output_lines, string.format("%4d | %s", i, line_content))
    end

    local header = string.format("=== %s === (行 %d-%d, 共 %d 行)", filepath, start_line, end_line, total_lines)
    table.insert(results, header .. "\n" .. table.concat(output_lines, "\n"))

    ::continue::
  end

  return table.concat(results, "\n\n")
end

M.read_file = define_tool({
  name = "read_file",
  description = "读取一个或多个文件的指定行范围，返回带行号的结果。每个文件可指定 filepath（必填）、start（起始行，默认1）、end（结束行，默认末尾）",
  func = _read_file,
  parameters = {
    type = "object",
    properties = {
      files = {
        type = "array",
        items = {
          type = "object",
          properties = {
            filepath = { type = "string", description = "文件路径（必填）" },
            start = { type = "number", description = "起始行号，从1开始，默认1" },
            ["end"] = { type = "number", description = "结束行号，-1或省略表示读取到末尾" },
          },
          required = { "filepath" },
        },
        description = "文件参数列表（与 file 二选一）",
      },
      file = {
        type = "object",
        properties = {
          filepath = { type = "string", description = "文件路径（必填）" },
          start = { type = "number", description = "起始行号，从1开始，默认1" },
          ["end"] = { type = "number", description = "结束行号，-1或省略表示读取到末尾" },
        },
        required = { "filepath" },
        description = "单个文件参数（与 files 二选一）",
      },
    },
    oneOf = {
      { required = { "files" } },
      { required = { "file" } },
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
  if not args then
    return {}
  end

  -- 支持 files（列表）和 file（单个）两种参数
  local files = args.files or {}
  if args.file and type(args.file) == "table" then
    table.insert(files, args.file)
  end

  if #files == 0 then
    return {}
  end

  local fu = get_file_utils()
  local results = {}

  for _, f in ipairs(files) do
    local filepath = f.filepath
    local content = f.content
    if not filepath or not content then
      table.insert(
        results,
        { filepath = filepath or "(未知)", success = false, error = "缺少 filepath 或 content 字段" }
      )
      goto continue
    end

    local append = f.append or false
    local ok

    if fu then
      local success, _ = fu.write_file(filepath, content, append)
      ok = success == true
    else
      local mode = append and "a" or "w"
      local file, err = io.open(filepath, mode)
      if not file then
        table.insert(results, { filepath = filepath, success = false, error = err or "无法打开文件" })
        goto continue
      end
      file:write(content)
      file:close()
      ok = true
    end

    table.insert(results, { filepath = filepath, success = ok })

    ::continue::
  end

  return results
end

M.write_file = define_tool({
  name = "write_file",
  description = "写入一个或多个文件的内容，支持覆盖和追加模式",
  func = _write_file,
  parameters = {
    type = "object",
    properties = {
      files = {
        type = "array",
        items = {
          type = "object",
          properties = {
            filepath = { type = "string", description = "文件路径（必填）" },
            content = { type = "string", description = "要写入的内容（必填）" },
            append = { type = "boolean", description = "是否追加模式，false 为覆盖", default = false },
          },
          required = { "filepath", "content" },
        },
        description = "文件参数列表（与 file 二选一）",
      },
      file = {
        type = "object",
        properties = {
          filepath = { type = "string", description = "文件路径（必填）" },
          content = { type = "string", description = "要写入的内容（必填）" },
          append = { type = "boolean", description = "是否追加模式，false 为覆盖", default = false },
        },
        required = { "filepath", "content" },
        description = "单个文件参数（与 files 二选一）",
      },
    },
    oneOf = {
      { required = { "files" } },
      { required = { "file" } },
    },
  },
  returns = {
    type = "array",
    items = {
      type = "object",
      properties = {
        filepath = { type = "string" },
        success = { type = "boolean" },
        error = { type = "string", description = "失败时的错误信息" },
      },
    },
    description = "写入结果列表",
  },
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

  -- 支持 files（列表）和 file（单个）两种参数
  local file_specs = args.files or {}
  if args.file and type(args.file) == "table" then
    table.insert(file_specs, args.file)
  end
  if #file_specs == 0 then
    -- 默认列出当前目录
    file_specs = { {} }
  end

  local files = {}

  for _, spec in ipairs(file_specs) do
    local dir = spec.dir or "."
    local pattern = spec.pattern or "*"
    local recursive = spec.recursive or false
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
  description = "列出一个或多个目录中的文件，支持模式匹配和递归查找",
  func = _list_files,
  parameters = {
    type = "object",
    properties = {
      files = {
        type = "array",
        items = {
          type = "object",
          properties = {
            dir = { type = "string", description = "目录路径", default = "." },
            pattern = { type = "string", description = "文件模式（如 *.txt）", default = "*" },
            recursive = { type = "boolean", description = "是否递归查找", default = false },
          },
        },
        description = "目录参数列表（与 file 二选一）",
      },
      file = {
        type = "object",
        properties = {
          dir = { type = "string", description = "目录路径", default = "." },
          pattern = { type = "string", description = "文件模式（如 *.txt）", default = "*" },
          recursive = { type = "boolean", description = "是否递归查找", default = false },
        },
        description = "单个目录参数（与 files 二选一）",
      },
    },
    oneOf = {
      { required = { "files" } },
      { required = { "file" } },
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

  -- 支持 files（列表）和 file（单个）两种参数
  local files = args.files or {}
  if args.file and type(args.file) == "table" then
    table.insert(files, args.file)
  end

  if #files == 0 then
    return {}
  end

  local fu = get_file_utils()
  local results = {}

  for _, f in ipairs(files) do
    local filepath = f.filepath
    if not filepath then
      table.insert(results, { filepath = "(未知)", exists = false })
      goto continue
    end

    local exists
    if fu then
      exists = fu.exists(filepath)
    else
      local file = io.open(filepath, "r")
      if file then
        file:close()
        exists = true
      else
        exists = false
      end
    end
    table.insert(results, { filepath = filepath, exists = exists })

    ::continue::
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
      files = {
        type = "array",
        items = {
          type = "object",
          properties = {
            filepath = { type = "string", description = "文件或目录路径（必填）" },
          },
          required = { "filepath" },
        },
        description = "路径参数列表（与 file 二选一）",
      },
      file = {
        type = "object",
        properties = {
          filepath = { type = "string", description = "文件或目录路径（必填）" },
        },
        required = { "filepath" },
        description = "单个路径参数（与 files 二选一）",
      },
    },
    oneOf = {
      { required = { "files" } },
      { required = { "file" } },
    },
  },
  returns = {
    type = "array",
    items = {
      type = "object",
      properties = {
        filepath = { type = "string" },
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

  -- 支持 files（列表）和 file（单个）两种参数
  local files = args.files or {}
  if args.file and type(args.file) == "table" then
    table.insert(files, args.file)
  end

  if #files == 0 then
    return {}
  end

  local fu = get_file_utils()
  local results = {}

  for _, f in ipairs(files) do
    local filepath = f.filepath
    if not filepath then
      table.insert(results, { filepath = "(未知)", success = false })
      goto continue
    end

    local ok
    if fu then
      local success, _ = fu.mkdir(filepath)
      ok = success == true
    else
      local cmd = 'mkdir -p "' .. filepath .. '" 2>/dev/null'
      local result = os.execute(cmd)
      ok = result == 0 or result == true
    end
    table.insert(results, { filepath = filepath, success = ok })

    ::continue::
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
      files = {
        type = "array",
        items = {
          type = "object",
          properties = {
            filepath = { type = "string", description = "目录路径（必填）" },
            parents = { type = "boolean", description = "是否创建父目录", default = true },
          },
          required = { "filepath" },
        },
        description = "目录参数列表（与 file 二选一）",
      },
      file = {
        type = "object",
        properties = {
          filepath = { type = "string", description = "目录路径（必填）" },
          parents = { type = "boolean", description = "是否创建父目录", default = true },
        },
        required = { "filepath" },
        description = "单个目录参数（与 files 二选一）",
      },
    },
    oneOf = {
      { required = { "files" } },
      { required = { "file" } },
    },
  },
  returns = {
    type = "array",
    items = {
      type = "object",
      properties = {
        filepath = { type = "string" },
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

  -- 支持 files（列表）和 file（单个）两种参数
  local files = args.files or {}
  if args.file and type(args.file) == "table" then
    table.insert(files, args.file)
  end

  if #files == 0 then
    return {}
  end

  local fu = get_file_utils()
  local results = {}

  for _, f in ipairs(files) do
    local filepath = f.filepath
    if not filepath then
      table.insert(results, { filepath = "(未知)", success = false })
      goto continue
    end

    local ok
    if fu then
      local success, _ = fu.mkdir(filepath)
      ok = success == true
    else
      local clean_path = filepath:gsub("/+$", "")
      local cmd = 'mkdir -p "' .. clean_path .. '" 2>/dev/null'
      local result = os.execute(cmd)
      ok = result == 0 or result == true
    end
    table.insert(results, { filepath = filepath, success = ok })

    ::continue::
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
      files = {
        type = "array",
        items = {
          type = "object",
          properties = {
            filepath = { type = "string", description = "目录路径（必填）" },
            parents = { type = "boolean", description = "是否创建父目录", default = true },
          },
          required = { "filepath" },
        },
        description = "目录参数列表（与 file 二选一）",
      },
      file = {
        type = "object",
        properties = {
          filepath = { type = "string", description = "目录路径（必填）" },
          parents = { type = "boolean", description = "是否创建父目录", default = true },
        },
        required = { "filepath" },
        description = "单个目录参数（与 files 二选一）",
      },
    },
    oneOf = {
      { required = { "files" } },
      { required = { "file" } },
    },
  },
  returns = {
    type = "array",
    items = {
      type = "object",
      properties = {
        filepath = { type = "string" },
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

  -- 支持 files（列表）和 file（单个）两种参数
  local files = args.files or {}
  if args.file and type(args.file) == "table" then
    table.insert(files, args.file)
  end

  if #files == 0 then
    return {}
  end

  local results = {}

  for _, f in ipairs(files) do
    local filepath = f.filepath
    if not filepath then
      table.insert(results, { filepath = "(未知)", success = false, error = "缺少 filepath 字段" })
      goto continue
    end

    local ok, err
    local file = io.open(filepath, "r")
    if file then
      file:close()
      local success = os.remove(filepath)
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
    table.insert(results, { filepath = filepath, success = ok, error = err })

    ::continue::
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
      files = {
        type = "array",
        items = {
          type = "object",
          properties = {
            filepath = { type = "string", description = "文件路径（必填）" },
          },
          required = { "filepath" },
        },
        description = "文件参数列表（与 file 二选一）",
      },
      file = {
        type = "object",
        properties = {
          filepath = { type = "string", description = "文件路径（必填）" },
        },
        required = { "filepath" },
        description = "单个文件参数（与 files 二选一）",
      },
    },
    oneOf = {
      { required = { "files" } },
      { required = { "file" } },
    },
  },
  returns = {
    type = "array",
    items = {
      type = "object",
      properties = {
        filepath = { type = "string" },
        success = { type = "boolean" },
        error = { type = "string", description = "失败时的错误信息" },
      },
    },
    description = "文件删除结果列表",
  },
  category = "file",
  permissions = { write = true },
})

-- get_tools() - 返回所有工具列表供注册
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

return M
