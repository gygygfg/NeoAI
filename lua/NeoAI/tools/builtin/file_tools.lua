-- Lua文件操作工具模块（回调模式）
-- 所有工具使用回调模式异步执行，不阻塞主线程
-- 工具函数签名：func(args, on_success, on_error)
local M = {}

-- 标准参数警告辅助函数
-- 当模型使用简化参数（如直接传 filepath 字符串）时，返回警告并附上正确调用示例
local function warn_simple_args(tool_name, example)
  local msg = string.format(
    "⚠️ 警告：你使用了简化参数格式调用 '%s'。\n"
      .. "虽然操作已执行，但建议使用标准参数格式以确保兼容性。\n"
      .. "正确调用示例：\n%s",
    tool_name,
    example
  )
  return msg
end

local define_tool = require("NeoAI.tools.builtin.tool_helpers").define_tool

-- 复用 file_utils 模块
local function get_file_utils()
  local ok, fu = pcall(require, "NeoAI.utils.file_utils")
  return ok and fu or nil
end

-- ============================================================================
-- vim.uv 异步 I/O 辅助函数（回调模式）
-- ============================================================================

local function uv_read_file(filepath, on_success, on_error)
  vim.uv.fs_open(filepath, "r", 438, function(open_err, fd)
    if open_err or not fd then
      if on_error then
        on_error(open_err or "无法打开文件")
      end
      return
    end
    vim.uv.fs_fstat(fd, function(stat_err, stat)
      if stat_err or not stat then
        vim.uv.fs_close(fd)
        if on_error then
          on_error(stat_err or "无法获取文件信息")
        end
        return
      end
      vim.uv.fs_read(fd, stat.size, 0, function(read_err, data)
        vim.uv.fs_close(fd)
        if read_err or not data then
          if on_error then
            on_error(read_err or "无法读取文件")
          end
          return
        end
        if on_success then
          on_success(data)
        end
      end)
    end)
  end)
end

local function uv_write_file(filepath, content, append, on_success, on_error)
  local flags = append and "a" or "w"
  vim.uv.fs_open(filepath, flags, 438, function(open_err, fd)
    if open_err or not fd then
      if on_error then
        on_error(open_err or "无法打开文件")
      end
      return
    end
    vim.uv.fs_write(fd, content, 0, function(write_err, written)
      vim.uv.fs_close(fd)
      if write_err or not written then
        if on_error then
          on_error(write_err or "无法写入文件")
        end
        return
      end
      if on_success then
        on_success(true)
      end
    end)
  end)
end

local function uv_exists(filepath, on_success)
  vim.uv.fs_stat(filepath, function(_, stat)
    if on_success then
      on_success(stat ~= nil)
    end
  end)
end

local function uv_delete_file(filepath, on_success, on_error)
  vim.uv.fs_unlink(filepath, function(err)
    if err then
      if on_error then
        on_error(err or "无法删除文件")
      end
      return
    end
    if on_success then
      on_success(true)
    end
  end)
end

local function uv_mkdir_p(filepath, on_success, on_error)
  vim.uv.fs_mkdir(filepath, 493, true, function(err)
    if err then
      if on_error then
        on_error(err or "无法创建目录")
      end
      return
    end
    if on_success then
      on_success(true)
    end
  end)
end

-- ============================================================================
-- 工具 read_file
-- ============================================================================

local function _read_file(args, on_success, on_error)
  if not args then
    if on_error then
      on_error("需要文件参数")
    end
    return
  end

  local files = args.files or {}
  if args.file and type(args.file) == "table" then
    table.insert(files, args.file)
  end
  -- 支持标准参数：直接传 filepath 字符串
  if args.filepath and type(args.filepath) == "string" then
    table.insert(files, { filepath = args.filepath, start = args.start, ["end"] = args.end_line or args["end"] })
  end
  if #files == 0 then
    if on_error then
      on_error("需要文件列表或单个文件参数")
    end
    return
  end

  -- 判断是否读取完整文件（未指定 start/end 范围）
  local function is_full_file(f)
    return (not f.start or f.start == 1) and (not f["end"] or f["end"] == -1)
  end

  -- 从语法树节点中提取文件结构概览（支持嵌套层级显示）
  -- 注意：文件过长提示已在 check_done 中统一处理，此处不再重复
  local function build_structure_overview(filepath, tree_result)
    local overview_lines = {}
    table.insert(
      overview_lines,
      string.format("📋 文件结构概览 (%s, 共 %d 行)", filepath, tree_result.line_count)
    )
    table.insert(overview_lines, "=" .. string.rep("=", 60))

    -- 需要提取的结构节点类型映射
    local structure_types = {
      function_definition = "function",
      method_definition = "method",
      class_definition = "class",
      class_declaration = "class",
      struct_specification = "struct",
      interface_declaration = "interface",
      enum_declaration = "enum",
      module_definition = "module",
    }

    -- 从节点文本中提取有意义的名称
    local function extract_name(node)
      local text = node.text:match("^[^\n]+") or node.text
      if node.type == "function_definition" or node.type == "method_definition" then
        -- Python: def name(...):
        local py_name = text:match("def%s+([%w_]+)%s*%(")
        if py_name then return py_name end
        -- Lua: function name(...)
        local lua_name = text:match("function%s+([%w_.:]+)")
        if lua_name then return lua_name end
        -- JS/TS: function name(...) / name = function(...)
        local js_name = text:match("function%s+([%w_]+)")
        if js_name then return js_name end
        local js_arrow = text:match("([%w_]+)%s*=%s*function")
        if js_arrow then return js_arrow end
        local js_arrow2 = text:match("([%w_]+)%s*=%s*%(")
        if js_arrow2 then return js_arrow2 end
      elseif node.type == "class_definition" or node.type == "class_declaration" then
        -- Python: class Name(...):
        local py_class = text:match("class%s+([%w_]+)")
        if py_class then return py_class end
        -- JS/TS: class Name {...}
        local js_class = text:match("class%s+([%w_]+)")
        if js_class then return js_class end
        -- Lua: ClassName = {}
        local lua_class = text:match("([%w_]+)%s*=%s*")
        if lua_class then return lua_class end
      end
      return text
    end

    -- 按深度层级过滤并排序节点
    -- 只保留深度 <= 4 的结构节点（顶层 + 两层嵌套 + 三层嵌套）
    local structures = {}
    for _, node in ipairs(tree_result.nodes) do
      local label = structure_types[node.type]
      if label and node.depth <= 4 then
        local name = extract_name(node)
        table.insert(structures, {
          label = label,
          name = name,
          depth = node.depth,
          start_row = node.start_row,
          end_row = node.end_row,
        })
      end
    end

    -- 如果没有找到结构节点，回退到深度 <= 2 的所有命名节点
    if #structures == 0 then
      for _, node in ipairs(tree_result.nodes) do
        if node.depth <= 2 and node.named then
          table.insert(structures, {
            label = node.type,
            name = (node.text:match("^[^\n]+") or node.text):sub(1, 60),
            depth = node.depth,
            start_row = node.start_row,
            end_row = node.end_row,
          })
        end
      end
    end

    -- 按深度和起始行排序
    table.sort(structures, function(a, b)
      if a.depth ~= b.depth then return a.depth < b.depth end
      return a.start_row < b.start_row
    end)

    -- 生成带缩进的层级显示
    for _, s in ipairs(structures) do
      local indent = string.rep("  ", s.depth)
      local line_range = string.format("行 %d-%d", s.start_row + 1, s.end_row + 1)
      table.insert(overview_lines, string.format("%s[%s] %s (%s)", indent, s.label, s.name, line_range))
    end

    return table.concat(overview_lines, "\n")
  end

  local fu = get_file_utils()
  local results = {}
  local pending = #files

  local warned = false
  -- 标记是否已生成结构概览（大文件）
  local has_structure_overview = false
  local function check_done()
    pending = pending - 1
    if pending <= 0 then
      local output = table.concat(results, "\n\n")
      -- 收集所有需要显示的提示信息
      local notices = {}
      -- 简化参数警告
      if not warned and args.filepath and type(args.filepath) == "string" then
        warned = true
        table.insert(notices, "⚠️ 警告：你使用了简化参数格式调用 'read_file'。")
        table.insert(notices, "虽然操作已执行，但建议使用标准参数格式以确保兼容性。")
        table.insert(notices, "正确调用示例：")
        table.insert(notices, [[{
  files = {
    { filepath = "/path/to/file", start = 1, end = -1 }
  }
}]])
      end
      -- 文件过长提示（当结果中包含结构概览时附加）
      if has_structure_overview then
        if #notices > 0 then
          table.insert(notices, "")
        end
        table.insert(notices, "⚠️ 文件过长（超过 500 行），仅显示文件结构概览。")
        table.insert(notices, "如需读取完整内容，请使用 files 参数指定 start/end 行范围。")
        table.insert(notices, "示例：")
        table.insert(notices, [[{ files = { { filepath = "/path/to/file", start = 1, end = 100 } } }]])
      end
      -- 合并提示信息到输出
      if #notices > 0 then
        output = table.concat(notices, "\n") .. "\n\n" .. output
      end
      if on_success then
        on_success(output)
      end
    end
  end

  for _, f in ipairs(files) do
    local filepath = f.filepath
    if not filepath then
      table.insert(results, "=== (未知文件) ===\n错误: 缺少 filepath 字段")
      check_done()
    else
      local function on_content(content)
        local start_line = f.start or 1
        local end_line = f["end"] or -1
        local all_lines = {}
        for line in content:gmatch("[^\n]+") do
          table.insert(all_lines, line)
        end
        local total_lines = #all_lines
        if content:sub(-1) == "\n" then
          total_lines = total_lines + 1
        end

        -- 检测：读取完整文件且行数 > 500 时，使用 Tree-sitter 返回结构概览
        local is_full = is_full_file(f)
        if is_full and total_lines > 500 then
          -- 尝试使用 Tree-sitter 解析文件结构
          local ok_tree, neovim_tree = pcall(require, "NeoAI.tools.builtin.neovim_tree")
          if ok_tree and neovim_tree then
            -- 使用 neovim_tree 的 parse_file_content_async 异步解析
            -- 注意：parse_file_content_async 的回调通过 vim.schedule 回到主线程
            neovim_tree.parse_file_content_async(filepath, -1, function(tree_result)
              if tree_result and tree_result.nodes and #tree_result.nodes > 0 then
                local overview = build_structure_overview(filepath, tree_result)
                table.insert(results, overview)
                has_structure_overview = true
              else
                -- Tree-sitter 解析成功但无节点，回退到完整读取
                local output_lines = {}
                for i = 1, total_lines do
                  local line_content = all_lines[i] or ""
                  table.insert(output_lines, string.format("%4d | %s", i, line_content))
                end
                local header = string.format("=== %s === (行 1-%d, 共 %d 行)", filepath, total_lines, total_lines)
                table.insert(results, header .. "\n" .. table.concat(output_lines, "\n"))
              end
              check_done()
            end, function(err)
              -- Tree-sitter 解析失败，回退到完整读取
              local output_lines = {}
              for i = 1, total_lines do
                local line_content = all_lines[i] or ""
                table.insert(output_lines, string.format("%4d | %s", i, line_content))
              end
              local header = string.format("=== %s === (行 1-%d, 共 %d 行)", filepath, total_lines, total_lines)
              table.insert(results, header .. "\n" .. table.concat(output_lines, "\n"))
              check_done()
            end)
            return -- 等待异步回调
          end
          -- Tree-sitter 模块不可用，回退到完整读取
        end

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
          check_done()
          return
        end
        local output_lines = {}
        for i = start_line, end_line do
          local line_content = all_lines[i] or ""
          table.insert(output_lines, string.format("%4d | %s", i, line_content))
        end
        local header = string.format("=== %s === (行 %d-%d, 共 %d 行)", filepath, start_line, end_line, total_lines)
        table.insert(results, header .. "\n" .. table.concat(output_lines, "\n"))
        check_done()
      end

      local function on_read_err(err)
        table.insert(results, string.format("=== %s ===\n错误: %s", filepath, err or "无法读取文件"))
        check_done()
      end

      if fu then
        local content, err = fu.read_file(filepath)
        if content then
          on_content(content)
        else
          on_read_err(err)
        end
      else
        uv_read_file(filepath, on_content, on_read_err)
      end
    end
  end
end

M.read_file = define_tool({
  name = "read_file",
  description = "读取一个或多个文件的指定行范围，返回带行号的结果",
  func = _read_file,
  async = true,
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
      filepath = {
        type = "string",
        description = "（简化参数）文件路径，使用此参数时会自动转换为标准格式并附带警告",
      },
      start = { type = "number", description = "（简化参数）起始行号，需配合 filepath 使用" },
      end_line = { type = "number", description = "（简化参数）结束行号，需配合 filepath 使用" },
    },
    oneOf = { { required = { "files" } }, { required = { "file" } }, { required = { "filepath" } } },
  },
  returns = { type = "string", description = "带行号的文件内容" },
  category = "file",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 write_file
-- ============================================================================

local function _write_file(args, on_success, on_error)
  if not args then
    if on_error then
      on_error("需要文件参数")
    end
    return
  end
  local files = args.files or {}
  if args.file and type(args.file) == "table" then
    table.insert(files, args.file)
  end
  -- 支持标准参数：直接传 filepath 和 content 字符串
  local used_simple = false
  if args.filepath and type(args.filepath) == "string" and args.content then
    table.insert(files, { filepath = args.filepath, content = args.content, append = args.append })
    used_simple = true
  end
  if #files == 0 then
    if on_error then
      on_error("需要文件列表或单个文件参数")
    end
    return
  end
  local fu = get_file_utils()
  local results = {}
  local pending = #files
  local function check_done()
    pending = pending - 1
    if pending <= 0 then
      if used_simple then
        local example = [[{
  files = {
    { filepath = "/path/to/file", content = "文件内容", append = false }
  }
}]]
        table.insert(results, 1, { _warning = warn_simple_args("write_file", example) })
      end
      if on_success then
        on_success(results)
      end
    end
  end
  for _, f in ipairs(files) do
    local filepath = f.filepath
    local content = f.content
    if not filepath or not content then
      table.insert(
        results,
        { filepath = filepath or "(未知)", success = false, error = "缺少 filepath 或 content 字段" }
      )
      check_done()
    else
      local append = f.append or false
      local function on_write_ok()
        table.insert(results, { filepath = filepath, success = true })
        check_done()
      end
      local function on_write_err(err)
        table.insert(results, { filepath = filepath, success = false, error = err or "无法写入文件" })
        check_done()
      end
      if fu then
        local success, _ = fu.write_file(filepath, content, append)
        if success == true then
          on_write_ok()
        else
          on_write_err("写入失败")
        end
      else
        uv_write_file(filepath, content, append, on_write_ok, on_write_err)
      end
    end
  end
end

M.write_file = define_tool({
  name = "write_file",
  description = "写入一个或多个文件的内容，支持覆盖和追加模式",
  func = _write_file,
  async = true,
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
      filepath = {
        type = "string",
        description = "（简化参数）文件路径，需配合 content 使用，使用时会附带警告",
      },
      content = { type = "string", description = "（简化参数）要写入的内容，需配合 filepath 使用" },
      append = { type = "boolean", description = "（简化参数）是否追加模式", default = false },
    },
    oneOf = { { required = { "files" } }, { required = { "file" } }, { required = { "filepath", "content" } } },
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
-- 工具 list_files
-- ============================================================================

-- 将 glob 模式转换为 Lua 模式匹配
local function glob_to_lua_pattern(glob)
  if glob == "*" then
    return nil
  end -- nil 表示匹配所有
  -- 转义特殊字符，再将 * 和 ? 转换为 Lua 模式
  local p = vim.pesc(glob)
  p = p:gsub("%%%*", ".*"):gsub("%%%?", ".")
  return p
end

-- 扫描单个目录（非递归），使用 fs_opendir + fs_readdir
-- fs_scandir_next 的回调在 headless 模式下不触发，所以用 fs_readdir 替代
local function scan_dir_flat(dir, pattern, all_results, done_callback)
  vim.uv.fs_opendir(dir, function(opendir_err, dir_handle)
    if opendir_err or not dir_handle then
      if done_callback then
        done_callback()
      end
      return
    end

    local lua_pattern = glob_to_lua_pattern(pattern)

    local function read_all_entries()
      vim.uv.fs_readdir(dir_handle, function(readdir_err, entries)
        if readdir_err then
          vim.uv.fs_closedir(dir_handle)
          if done_callback then
            done_callback()
          end
          return
        end

        if not entries then
          vim.uv.fs_closedir(dir_handle)
          if done_callback then
            done_callback()
          end
          return
        end

        for _, entry in ipairs(entries) do
          if entry.type == "file" then
            if lua_pattern == nil or entry.name:match(lua_pattern) then
              table.insert(all_results, dir .. "/" .. entry.name)
            end
          end
        end

        read_all_entries()
      end)
    end

    read_all_entries()
  end)
end

-- 递归扫描目录（使用 vim.uv.fs_opendir + fs_readdir + fs_closedir）
-- 返回所有匹配文件的完整路径列表
local function scan_dir_recursive(dir, pattern, all_results, done_callback)
  vim.uv.fs_opendir(dir, function(opendir_err, dir_handle)
    if opendir_err or not dir_handle then
      if done_callback then
        done_callback()
      end
      return
    end

    local lua_pattern = glob_to_lua_pattern(pattern)
    local subdirs = {}

    -- 循环读取所有批次
    local function read_all_entries()
      vim.uv.fs_readdir(dir_handle, function(readdir_err, entries)
        if readdir_err then
          vim.uv.fs_closedir(dir_handle)
          if done_callback then
            done_callback()
          end
          return
        end

        -- entries 为 nil 表示读取完毕
        if not entries then
          vim.uv.fs_closedir(dir_handle)
          -- 处理子目录
          if #subdirs == 0 then
            if done_callback then
              done_callback()
            end
            return
          end
          local pending_subdirs = #subdirs
          local subdir_done = function()
            pending_subdirs = pending_subdirs - 1
            if pending_subdirs <= 0 then
              if done_callback then
                done_callback()
              end
            end
          end
          for _, subdir in ipairs(subdirs) do
            scan_dir_recursive(subdir, pattern, all_results, subdir_done)
          end
          return
        end

        -- 处理当前批次
        for _, entry in ipairs(entries) do
          local name = entry.name
          local typ = entry.type
          local full_path = dir .. "/" .. name

          if typ == "file" then
            if lua_pattern == nil or name:match(lua_pattern) then
              table.insert(all_results, full_path)
            end
          elseif typ == "directory" then
            if name ~= "." and name ~= ".." then
              table.insert(subdirs, full_path)
            end
          end
        end

        -- 继续读取下一批
        read_all_entries()
      end)
    end

    read_all_entries()
  end)
end

local function _list_files(args, on_success, on_error)
  if not args then
    if on_error then
      on_error("需要目录参数")
    end
    return
  end
  local file_specs = args.files or {}
  if args.file and type(args.file) == "table" then
    table.insert(file_specs, args.file)
  end
  -- 支持标准参数：直接传 dir_path/pattern/recursive 字符串
  local used_simple = false
  if args.dir_path and type(args.dir_path) == "string" then
    table.insert(file_specs, { dir = args.dir_path, pattern = args.pattern or "*", recursive = args.recursive or false })
    used_simple = true
  end
  -- 支持简化参数：dir 为字符串 + pattern + recursive
  if type(args.dir) == "string" then
    table.insert(file_specs, { dir = args.dir, pattern = args.pattern or "*", recursive = args.recursive or false })
    used_simple = true
  end
  if #file_specs == 0 then
    if on_error then
      on_error("需要目录列表或单个目录参数")
    end
    return
  end
  local all_files = {}
  local pending = #file_specs
  local function check_done()
    pending = pending - 1
    if pending <= 0 then
      if used_simple then
        local example = [[{
  dirs = {
    { dir = "/path/to/dir", pattern = "*.ts", recursive = true }
  }
}]]
        table.insert(all_files, 1, warn_simple_args("list_files", example))
      end
      if on_success then
        on_success(all_files)
      end
    end
  end
  for _, spec in ipairs(file_specs) do
    local dir = spec.dir or "."
    local pattern = spec.pattern or "*"
    local recursive = spec.recursive or false

    if recursive then
      -- 递归模式：使用 scan_dir_recursive
      scan_dir_recursive(dir, pattern, all_files, check_done)
    else
      -- 非递归模式：使用 fs_opendir + fs_readdir（fs_scandir_next 在 headless 模式下回调不触发）
      scan_dir_flat(dir, pattern, all_files, check_done)
    end
  end
end

M.list_files = define_tool({
  name = "list_files",
  description = "列出一个或多个目录中的文件，支持模式匹配和递归查找",
  func = _list_files,
  async = true,
  parameters = {
    type = "object",
    properties = {
      dirs = {
        type = "array",
        items = {
          type = "object",
          properties = {
            dir = { type = "string", description = "目录路径", default = "." },
            pattern = { type = "string", description = "文件模式（如 *.txt）", default = "*" },
            recursive = { type = "boolean", description = "是否递归查找", default = false },
          },
        },
        description = "目录参数列表（与 dir 二选一）",
      },
      dir = {
        type = "string",
        description = "（简化参数）目录路径，使用时会附带警告，推荐使用 dirs 参数",
      },
      dir_path = { type = "string", description = "（简化参数）目录路径，使用时会附带警告" },
      pattern = {
        type = "string",
        description = "（简化参数）文件模式，需配合 dir 使用",
        default = "*",
      },
      recursive = { type = "boolean", description = "（简化参数）是否递归查找", default = false },
    },
    oneOf = { { required = { "dirs" } }, { required = { "dir" } } },
  },
  returns = { type = "array", items = { type = "string" }, description = "文件路径列表" },
  category = "file",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 search_files
-- ============================================================================

local function _search_files(args, on_success, on_error)
  if not args then
    if on_error then
      on_error("需要搜索参数")
    end
    return
  end
  local file_specs = args.files or {}
  if args.file and type(args.file) == "table" then
    table.insert(file_specs, args.file)
  end
  -- 支持简化参数：直接传 pattern/dir 等字符串
  local used_simple = false
  if args.pattern and type(args.pattern) == "string" and not args.files and not args.file then
    table.insert(file_specs, {
      dir = args.dir or ".",
      pattern = args.pattern,
      file_pattern = args.file_pattern or "*",
      case_sensitive = args.case_sensitive or false,
      regex = args.regex or true,
    })
    used_simple = true
  end
  local pattern = args.pattern
  if not pattern and #file_specs == 0 then
    if on_error then
      on_error("需要搜索模式或文件参数")
    end
    return
  end
  if #file_specs == 0 then
    file_specs = { {} }
  end
  local all_results = {}
  local pending = #file_specs
  local function check_done()
    pending = pending - 1
    if pending <= 0 then
      if used_simple then
        local example = [[{
  files = {
    {
      dir = ".",
      pattern = "search_text",
      file_pattern = "*.lua",
      case_sensitive = false,
      regex = true
    }
  }
}]]
        table.insert(all_results, 1, { _warning = warn_simple_args("search_files", example) })
      end
      if on_success then
        on_success(all_results)
      end
    end
  end
  for _, spec in ipairs(file_specs) do
    local dir = spec.dir or "."
    local file_pattern = spec.file_pattern or "*"
    local case_sensitive = spec.case_sensitive
    if case_sensitive == nil then
      case_sensitive = false
    end
    local regex = spec.regex
    if regex == nil then
      regex = true
    end
    local search_pattern = spec.pattern or pattern
    if not search_pattern then
      check_done()
    else
      -- 构建 grep 命令参数
      local grep_args = {}
      -- 递归搜索
      table.insert(grep_args, "-r")
      if not case_sensitive then
        table.insert(grep_args, "-i")
      end
      if not regex then
        table.insert(grep_args, "-F")
      end
      table.insert(grep_args, "-n")
      -- 文件模式过滤（将 glob 转换为 grep 的 --include）
      if file_pattern and file_pattern ~= "*" then
        table.insert(grep_args, "--include")
        table.insert(grep_args, file_pattern)
      end
      table.insert(grep_args, "--")
      table.insert(grep_args, search_pattern)
      table.insert(grep_args, dir)

      -- 使用 vim.uv.spawn 执行 grep -r
      -- 创建 pipe 用于捕获 stdout 和 stderr
      local stdout_pipe = vim.uv.new_pipe()
      local stderr_pipe = vim.uv.new_pipe()
      local stdout_data = {}
      local stderr_data = {}

      -- 在 spawn 时通过 stdio 数组传入 pipe
      local handle = vim.uv.spawn("grep", {
        args = grep_args,
        stdio = { nil, stdout_pipe, stderr_pipe },
      }, function(code)
        -- 关闭 pipe
        if not stdout_pipe:is_closing() then
          stdout_pipe:read_stop()
          stdout_pipe:close()
        end
        if not stderr_pipe:is_closing() then
          stderr_pipe:read_stop()
          stderr_pipe:close()
        end

        if code == 0 then
          -- 有匹配结果
          local output = table.concat(stdout_data, "")
          for line in output:gmatch("[^\n]+") do
            -- grep -rn 输出格式: filepath:line_num:content
            local file, line_num, content = line:match("^(.+):(%d+):(.+)$")
            if file and line_num and content then
              table.insert(all_results, { file = file, line = tonumber(line_num), content = content })
            end
          end
        elseif code == 1 then
          -- grep 返回 1 表示无匹配，不是错误
        else
          -- grep 返回 2+ 表示错误
          local err_msg = table.concat(stderr_data, ""):gsub("^%s*(.-)%s*$", "%1")
          if err_msg and err_msg ~= "" then
            table.insert(all_results, {
              _error = string.format("grep 搜索失败 (dir=%s, pattern=%s): %s", dir, search_pattern, err_msg),
            })
          end
        end
        check_done()
      end)
      if handle then
        stdout_pipe:read_start(function(err, data)
          if data then
            table.insert(stdout_data, data)
          end
        end)
        stderr_pipe:read_start(function(err, data)
          if data then
            table.insert(stderr_data, data)
          end
        end)
      else
        -- spawn 失败，清理 pipe
        if not stdout_pipe:is_closing() then
          stdout_pipe:close()
        end
        if not stderr_pipe:is_closing() then
          stderr_pipe:close()
        end
        table.insert(all_results, {
          _error = string.format("无法启动 grep 进程 (dir=%s, pattern=%s)", dir, search_pattern),
        })
        check_done()
      end
    end
  end
end

M.search_files = define_tool({
  name = "search_files",
  description = "搜索文件内容，支持正则匹配和固定字符串匹配",
  func = _search_files,
  async = true,
  parameters = {
    type = "object",
    properties = {
      pattern = { type = "string", description = "搜索模式（当 files 未指定时使用）" },
      files = {
        type = "array",
        items = {
          type = "object",
          properties = {
            dir = { type = "string", description = "搜索目录", default = "." },
            pattern = { type = "string", description = "搜索模式" },
            file_pattern = { type = "string", description = "文件通配符模式", default = "*" },
            case_sensitive = { type = "boolean", description = "是否区分大小写", default = false },
            regex = { type = "boolean", description = "是否使用正则匹配", default = true },
          },
        },
        description = "搜索参数列表（与 file 二选一）",
      },
      file = {
        type = "object",
        properties = {
          dir = { type = "string", description = "搜索目录", default = "." },
          pattern = { type = "string", description = "搜索模式" },
          file_pattern = { type = "string", description = "文件通配符模式", default = "*" },
          case_sensitive = { type = "boolean", description = "是否区分大小写", default = false },
          regex = { type = "boolean", description = "是否使用正则匹配", default = true },
        },
        description = "单个搜索参数（与 files 二选一）",
      },
      dir = { type = "string", description = "（简化参数）搜索目录", default = "." },
      file_pattern = { type = "string", description = "（简化参数）文件通配符模式", default = "*" },
      case_sensitive = { type = "boolean", description = "（简化参数）是否区分大小写", default = false },
      regex = { type = "boolean", description = "（简化参数）是否使用正则匹配", default = true },
    },
    oneOf = { { required = { "pattern" } }, { required = { "files" } }, { required = { "file" } } },
  },
  returns = {
    type = "array",
    items = {
      type = "object",
      properties = { file = { type = "string" }, line = { type = "number" }, content = { type = "string" } },
    },
    description = "匹配结果列表",
  },
  category = "file",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 file_exists
-- ============================================================================

local function _file_exists(args, on_success, on_error)
  if not args then
    if on_error then
      on_error("需要文件参数")
    end
    return
  end
  local files = args.files or {}
  if args.file and type(args.file) == "table" then
    table.insert(files, args.file)
  end
  -- 支持标准参数：直接传 filepath 字符串
  local used_simple = false
  if args.filepath and type(args.filepath) == "string" then
    table.insert(files, { filepath = args.filepath })
    used_simple = true
  end
  if #files == 0 then
    if on_error then
      on_error("需要文件列表或单个文件参数")
    end
    return
  end
  local fu = get_file_utils()
  local results = {}
  local pending = #files
  local function check_done()
    pending = pending - 1
    if pending <= 0 then
      if used_simple then
        local example = [[{
  files = {
    { filepath = "/path/to/file" }
  }
}]]
        table.insert(
          results,
          1,
          { filepath = "_warning", exists = false, _warning = warn_simple_args("file_exists", example) }
        )
      end
      if on_success then
        on_success(results)
      end
    end
  end
  for _, f in ipairs(files) do
    local filepath = f.filepath
    if not filepath then
      table.insert(results, { filepath = "(未知)", exists = false })
      check_done()
    else
      local function on_exists(exists)
        table.insert(results, { filepath = filepath, exists = exists })
        check_done()
      end
      if fu then
        on_exists(fu.exists(filepath))
      else
        uv_exists(filepath, on_exists)
      end
    end
  end
end

M.file_exists = define_tool({
  name = "file_exists",
  description = "检查一个或多个文件或目录是否存在",
  func = _file_exists,
  async = true,
  parameters = {
    type = "object",
    properties = {
      files = {
        type = "array",
        items = {
          type = "object",
          properties = { filepath = { type = "string", description = "文件或目录路径（必填）" } },
          required = { "filepath" },
        },
        description = "路径参数列表（与 file 二选一）",
      },
      file = {
        type = "object",
        properties = { filepath = { type = "string", description = "文件或目录路径（必填）" } },
        required = { "filepath" },
        description = "单个路径参数（与 files 二选一）",
      },
      filepath = { type = "string", description = "（简化参数）文件或目录路径，使用时会附带警告" },
    },
    oneOf = { { required = { "files" } }, { required = { "file" } }, { required = { "filepath" } } },
  },
  returns = {
    type = "array",
    items = { type = "object", properties = { filepath = { type = "string" }, exists = { type = "boolean" } } },
    description = "路径存在状态列表",
  },
  category = "file",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 create_directory
-- ============================================================================

local function _create_directory(args, on_success, on_error)
  if not args then
    if on_error then
      on_error("需要目录参数")
    end
    return
  end
  local files = args.files or {}
  if args.file and type(args.file) == "table" then
    table.insert(files, args.file)
  end
  -- 支持标准参数：直接传 filepath 字符串
  local used_simple = false
  if args.filepath and type(args.filepath) == "string" then
    table.insert(files, { filepath = args.filepath, parents = args.parents })
    used_simple = true
  end
  if #files == 0 then
    if on_error then
      on_error("需要目录列表或单个目录参数")
    end
    return
  end
  local fu = get_file_utils()
  local results = {}
  local pending = #files
  local function check_done()
    pending = pending - 1
    if pending <= 0 then
      if used_simple then
        local example = [[{
  files = {
    { filepath = "/path/to/dir", parents = true }
  }
}]]
        table.insert(
          results,
          1,
          { filepath = "_warning", success = false, _warning = warn_simple_args("create_directory", example) }
        )
      end
      if on_success then
        on_success(results)
      end
    end
  end
  for _, f in ipairs(files) do
    local filepath = f.filepath
    if not filepath then
      table.insert(results, { filepath = "(未知)", success = false })
      check_done()
    else
      local function on_created(ok)
        table.insert(results, { filepath = filepath, success = ok })
        check_done()
      end
      if fu then
        local success, _ = fu.mkdir(filepath)
        on_created(success == true)
      else
        uv_mkdir_p(filepath, function()
          on_created(true)
        end, function()
          on_created(false)
        end)
      end
    end
  end
end

M.create_directory = define_tool({
  name = "create_directory",
  description = "创建一个或多个目录",
  func = _create_directory,
  async = true,
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
      filepath = { type = "string", description = "（简化参数）目录路径，使用时会附带警告" },
      parents = { type = "boolean", description = "（简化参数）是否创建父目录", default = true },
    },
    oneOf = { { required = { "files" } }, { required = { "file" } }, { required = { "filepath" } } },
  },
  returns = {
    type = "array",
    items = { type = "object", properties = { filepath = { type = "string" }, success = { type = "boolean" } } },
    description = "目录创建结果列表",
  },
  category = "file",
  permissions = { write = true },
})

-- ============================================================================
-- 工具 ensure_dir
-- ============================================================================

local function _ensure_dir(args, on_success, on_error)
  if not args then
    if on_error then
      on_error("需要目录参数")
    end
    return
  end
  local files = args.files or {}
  if args.file and type(args.file) == "table" then
    table.insert(files, args.file)
  end
  -- 支持标准参数：直接传 filepath 字符串
  local used_simple = false
  if args.filepath and type(args.filepath) == "string" then
    table.insert(files, { filepath = args.filepath, parents = args.parents })
    used_simple = true
  end
  if #files == 0 then
    if on_error then
      on_error("需要目录列表或单个目录参数")
    end
    return
  end
  local fu = get_file_utils()
  local results = {}
  local pending = #files
  local function check_done()
    pending = pending - 1
    if pending <= 0 then
      if used_simple then
        local example = [[{
  files = {
    { filepath = "/path/to/dir", parents = true }
  }
}]]
        table.insert(
          results,
          1,
          { filepath = "_warning", success = false, _warning = warn_simple_args("ensure_dir", example) }
        )
      end
      if on_success then
        on_success(results)
      end
    end
  end
  for _, f in ipairs(files) do
    local filepath = f.filepath
    if not filepath then
      table.insert(results, { filepath = "(未知)", success = false })
      check_done()
    else
      local clean_path = filepath:gsub("/+$", "")
      local function on_ensured(ok)
        table.insert(results, { filepath = filepath, success = ok })
        check_done()
      end
      if fu then
        local success, _ = fu.mkdir(clean_path)
        on_ensured(success == true)
      else
        uv_mkdir_p(clean_path, function()
          on_ensured(true)
        end, function()
          on_ensured(false)
        end)
      end
    end
  end
end

M.ensure_dir = define_tool({
  name = "ensure_dir",
  description = "确保一个或多个目录存在，如果不存在则创建",
  func = _ensure_dir,
  async = true,
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
      filepath = { type = "string", description = "（简化参数）目录路径，使用时会附带警告" },
      parents = { type = "boolean", description = "（简化参数）是否创建父目录", default = true },
    },
    oneOf = { { required = { "files" } }, { required = { "file" } }, { required = { "filepath" } } },
  },
  returns = {
    type = "array",
    items = { type = "object", properties = { filepath = { type = "string" }, success = { type = "boolean" } } },
    description = "目录确保结果列表",
  },
  category = "file",
  permissions = { write = true },
})

-- ============================================================================
-- 工具 delete_file
-- ============================================================================

local function _delete_file(args, on_success, on_error)
  if not args then
    if on_error then
      on_error("需要文件参数")
    end
    return
  end
  local files = args.files or {}
  if args.file and type(args.file) == "table" then
    table.insert(files, args.file)
  end
  -- 支持标准参数：直接传 filepath 字符串
  local used_simple = false
  if args.filepath and type(args.filepath) == "string" then
    table.insert(files, { filepath = args.filepath })
    used_simple = true
  end
  if #files == 0 then
    if on_error then
      on_error("需要文件列表或单个文件参数")
    end
    return
  end
  local results = {}
  local pending = #files
  local function check_done()
    pending = pending - 1
    if pending <= 0 then
      if used_simple then
        local example = [[{
  files = {
    { filepath = "/path/to/file" }
  }
}]]
        table.insert(
          results,
          1,
          { filepath = "_warning", success = false, _warning = warn_simple_args("delete_file", example) }
        )
      end
      if on_success then
        on_success(results)
      end
    end
  end
  for _, f in ipairs(files) do
    local filepath = f.filepath
    if not filepath then
      table.insert(results, { filepath = "(未知)", success = false, error = "缺少 filepath 字段" })
      check_done()
    else
      uv_exists(filepath, function(exists)
        if not exists then
          table.insert(results, { filepath = filepath, success = false, error = "文件不存在" })
          check_done()
          return
        end
        uv_delete_file(filepath, function()
          table.insert(results, { filepath = filepath, success = true })
          check_done()
        end, function(err)
          table.insert(results, { filepath = filepath, success = false, error = err or "无法删除文件" })
          check_done()
        end)
      end)
    end
  end
end

M.delete_file = define_tool({
  name = "delete_file",
  description = "删除一个或多个文件",
  func = _delete_file,
  async = true,
  parameters = {
    type = "object",
    properties = {
      files = {
        type = "array",
        items = {
          type = "object",
          properties = { filepath = { type = "string", description = "文件路径（必填）" } },
          required = { "filepath" },
        },
        description = "文件参数列表（与 file 二选一）",
      },
      file = {
        type = "object",
        properties = { filepath = { type = "string", description = "文件路径（必填）" } },
        required = { "filepath" },
        description = "单个文件参数（与 files 二选一）",
      },
      filepath = { type = "string", description = "（简化参数）文件路径，使用时会附带警告" },
    },
    oneOf = { { required = { "files" } }, { required = { "file" } }, { required = { "filepath" } } },
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

-- get_tools()
function M.get_tools()
  local tools = {}
  for _, v in pairs(M) do
    if type(v) == "table" and v.name and v.func then
      table.insert(tools, v)
    end
  end
  table.sort(tools, function(a, b)
    return a.name < b.name
  end)
  return tools
end

return M
