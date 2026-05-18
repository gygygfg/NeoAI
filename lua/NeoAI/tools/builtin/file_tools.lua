-- Lua文件操作工具模块（回调模式）
-- 所有工具使用回调模式异步执行，不阻塞主线程
-- 工具函数签名：func(args, on_success, on_error)
local M = {}

local define_tool = require("NeoAI.tools.builtin.tool_helpers").define_tool
local fu = require("NeoAI.utils.file_utils")
local neovim_tree = require("NeoAI.tools.builtin.neovim_tree")
local block_node_types = neovim_tree.block_node_types or {}
local resolve_path = require("NeoAI.tools.builtin.tool_helpers").resolve_path


-- ============================================================================
-- 工具 read_file
-- ============================================================================

local function _read_file(args, on_success, on_error)
  if not args or not args.filepath then
    if on_error then
      on_error("需要 filepath 参数")
    end
    return
  end

  local filepath = resolve_path(args.filepath)
  local start_line = args.start_line or args.start or 1
  local end_line = args.end_line or args["end"] or -1
  local is_full_file = (start_line == 1) and (end_line == -1)

  local function build_structure_overview(file_path, tree_result)
    local overview_lines = {}
    table.insert(
      overview_lines,
      string.format("📋 文件结构概览 (%s, 共 %d 行)", file_path, tree_result.line_count)
    )
    table.insert(overview_lines, "=" .. string.rep("=", 60))

    local function extract_name(node)
      local text = node.text:match("^[^\n]+") or node.text
      if node.type == "function_definition" or node.type == "method_definition" then
        local py_name = text:match("def%s+([%w_]+)%s*%(")
        if py_name then
          return py_name
        end
        local lua_name = text:match("function%s+([%w_.:]+)")
        if lua_name then
          return lua_name
        end
        local js_name = text:match("function%s+([%w_]+)")
        if js_name then
          return js_name
        end
        local js_arrow = text:match("([%w_]+)%s*=%s*function")
        if js_arrow then
          return js_arrow
        end
        local js_arrow2 = text:match("([%w_]+)%s*=%s*%(")
        if js_arrow2 then
          return js_arrow2
        end
      elseif node.type == "class_definition" or node.type == "class_declaration" then
        local py_class = text:match("class%s+([%w_]+)")
        if py_class then
          return py_class
        end
        local js_class = text:match("class%s+([%w_]+)")
        if js_class then
          return js_class
        end
        local lua_class = text:match("([%w_]+)%s*=%s*")
        if lua_class then
          return lua_class
        end
      end
      return text
    end

    local structures = {}
    for _, node in ipairs(tree_result.nodes) do
      if block_node_types[node.type] and node.depth <= 4 then
        local name = extract_name(node)
        table.insert(structures, {
          label = node.type,
          name = name,
          depth = node.depth,
          start_row = node.start_row,
          end_row = node.end_row,
        })
      end
    end

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

    table.sort(structures, function(a, b)
      if a.depth ~= b.depth then
        return a.depth < b.depth
      end
      return a.start_row < b.start_row
    end)

    for _, s in ipairs(structures) do
      local indent = string.rep("  ", s.depth)
      local line_range = string.format("行 %d-%d", s.start_row + 1, s.end_row + 1)
      table.insert(overview_lines, string.format("%s[%s] %s (%s)", indent, s.label, s.name, line_range))
    end

    return table.concat(overview_lines, "\n")
  end

  local function on_content(content)
    -- 使用 split 保留空行，确保行号与 wc -l 一致
    local all_lines = vim.split(content, "\n", { plain = true })
    -- 如果文件末尾有换行符，split 会产生一个空字符串作为最后元素，去掉它
    if #all_lines > 0 and all_lines[#all_lines] == "" then
      table.remove(all_lines)
    end
    local total_lines = #all_lines

    if is_full_file and total_lines > 500 then
      local ok_tree, nvim_tree_mod = pcall(require, "NeoAI.tools.builtin.neovim_tree")
      if ok_tree and nvim_tree_mod then
        nvim_tree_mod.parse_file_content_async(filepath, -1, function(tree_result)
          if tree_result and tree_result.nodes and #tree_result.nodes > 0 then
            local overview = build_structure_overview(filepath, tree_result)
            local notices = "⚠️ 文件过长（超过 500 行），仅显示文件结构概览。\n"
              .. "如需读取完整内容，请指定 start_line/end_line 行范围。\n"
              .. '示例：{ filepath = "/path/to/file", start_line = 1, end_line = 100 }\n\n'
            if on_success then
              on_success(notices .. overview)
            end
          else
            local output_lines = {}
            for i = 1, total_lines do
              table.insert(output_lines, string.format("%4d | %s", i, all_lines[i] or ""))
            end
            local header = string.format("=== %s === (行 1-%d, 共 %d 行)", filepath, total_lines, total_lines)
            if on_success then
              on_success(header .. "\n" .. table.concat(output_lines, "\n"))
            end
          end
        end, function()
          local output_lines = {}
          for i = 1, total_lines do
            table.insert(output_lines, string.format("%4d | %s", i, all_lines[i] or ""))
          end
          local header = string.format("=== %s === (行 1-%d, 共 %d 行)", filepath, total_lines, total_lines)
          if on_success then
            on_success(header .. "\n" .. table.concat(output_lines, "\n"))
          end
        end)
        return
      end
    end

    if start_line < 1 then
      start_line = 1
    end
    if end_line < 0 or end_line > total_lines then
      end_line = total_lines
    end
    if start_line > end_line then
      if on_error then
        on_error(string.format("起始行(%d)大于结束行(%d)", start_line, end_line))
      end
      return
    end
    local output_lines = {}
    for i = start_line, end_line do
      table.insert(output_lines, string.format("%4d | %s", i, all_lines[i] or ""))
    end
    local header = string.format("=== %s === (行 %d-%d, 共 %d 行)", filepath, start_line, end_line, total_lines)
    if on_success then
      on_success(header .. "\n" .. table.concat(output_lines, "\n"))
    end
  end

  local function on_read_err(err)
    if on_error then
      on_error(string.format("读取文件失败 %s: %s", filepath, err or "无法读取文件"))
    end
  end

  local content, err = fu.read_file(filepath)
  if content then
    on_content(content)
  else
    on_read_err(err)
  end
end
M.read_file = define_tool({
  name = "read_file",
  description = "读取文件的指定行范围，返回带行号的结果",
  func = _read_file,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径（必填）" },
      start_line = { type = "number", description = "起始行号，从1开始，默认1" },
      end_line = { type = "number", description = "结束行号，-1或省略表示读取到末尾" },
    },
    required = { "filepath" },
  },
  returns = { type = "string", description = "带行号的文件内容" },
  category = "file",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 edit_file
-- ============================================================================

local function _edit_file(args, on_success, on_error)
  if not args or not args.filepath then
    if on_error then
      on_error("需要 filepath 参数")
    end
    return
  end

  local filepath = resolve_path(args.filepath)
  local content = args.content
  if content ~= nil then
    if type(content) ~= "string" then
      content = tostring(content)
    end
  else
    content = ""
  end
  local append = args.append
  if append == nil then
    if on_error then
      on_error("必须提供 append 参数（追加模式为 true，覆盖模式为 false）")
    end
    return
  end
  local start_line = args.start_line
  -- on_write_err 是 on_error 的别名，供内部闭包使用
  local on_write_err = on_error

  -- 通用写回调：写入成功后尝试获取 LSP 诊断信息
  local function on_write_ok()
    local result = { filepath = filepath, success = true }

    local ok_lsp, lsp_mod = pcall(require, "NeoAI.tools.builtin.neovim_lsp")
    if ok_lsp and lsp_mod and lsp_mod.lsp_diagnostics and lsp_mod.lsp_diagnostics.func then
      local abs_path = vim.fn.fnamemodify(filepath, ":p")
      local bufnr = vim.fn.bufnr(abs_path)
      if bufnr ~= -1 then
        pcall(vim.api.nvim_buf_call, bufnr, function()
          vim.cmd("edit!")
        end)
      else
        bufnr = vim.fn.bufadd(abs_path)
        vim.fn.bufload(bufnr)
      end

      local max_wait = 10000
      local timeout_timer = vim.loop.new_timer()
      local debounce_timer = vim.loop.new_timer()
      local au_id = nil
      local finalized = false

      local function finalize()
        if finalized then
          return
        end
        finalized = true

        if au_id then
          pcall(vim.api.nvim_del_autocmd, au_id)
          au_id = nil
        end
        if timeout_timer then
          timeout_timer:stop()
          timeout_timer:close()
        end
        if debounce_timer then
          debounce_timer:stop()
          debounce_timer:close()
        end

        local ok_pcall, call_err = pcall(lsp_mod.lsp_diagnostics.func, { filepath = filepath }, function(diag_result)
          if diag_result and not diag_result.error then
            result.diagnostics = diag_result.diagnostics or {}
            result.diagnostic_count = diag_result.diagnostic_count or 0
          end
          if on_success then
            on_success(result)
          end
        end, function(err_msg)
          log_message("warn", "edit_file 诊断获取失败: " .. tostring(err_msg))
          if on_success then
            on_success(result)
          end
        end)
        if not ok_pcall then
          if on_success then
            on_success(result)
          end
        end
      end

      local function on_diag_changed(diag_args)
        if not diag_args or not diag_args.buf or diag_args.buf ~= bufnr then
          return
        end
        if debounce_timer then
          debounce_timer:stop()
          debounce_timer:start(
            500,
            0,
            vim.schedule_wrap(function()
              finalize()
            end)
          )
        end
      end

      au_id = vim.api.nvim_create_autocmd("DiagnosticChanged", {
        buffer = bufnr,
        callback = on_diag_changed,
      })

      if timeout_timer then
        timeout_timer:start(
          max_wait,
          0,
          vim.schedule_wrap(function()
            finalize()
          end)
        )
      end
    else
      if on_success then
        on_success(result)
      end
    end
  end

  -- 直接写入内容到文件的函数
  local function write_content(content_to_write)
    local success, _ = fu.write_file(filepath, content_to_write, false)
    if success == true then
      on_write_ok()
    else
      on_write_err("写入失败")
    end
  end

  -- 先检查文件是否存在
  local function check_exists_and_proceed()
    local function on_exists(exists)
      if not exists then
        local warning = string.format(
          "⚠️ 警告：文件 '%s' 不存在，已自动创建。\n"
            .. "请确认文件路径是否正确，或使用 create_directory 先创建目录。",
          filepath
        )
        local function write_and_return()
          if on_success then
            on_success({ filepath = filepath, success = true, warning = warning })
          end
        end
        local ok, _ = fu.write_file(filepath, content, false)
        if ok then
          write_and_return()
        else
          if on_error then
            on_error("写入失败")
          end
        end
        return
      end

      if not append and (not start_line or not end_line) then
        if on_error then
          on_error("覆盖模式(append=false)必须提供 start_line 和 end_line 参数")
        end
        return
      end

      if start_line and end_line then
        local function do_range_replace(file_content)
          local lines = vim.split(file_content, "\n", { plain = true })
          if #lines > 0 and lines[#lines] == "" then
            table.remove(lines)
          end
          local total = #lines

          if start_line < 1 then
            start_line = 1
          end
          if end_line > total then
            end_line = total
          end
          if start_line > end_line then
            if on_error then
              on_error(string.format("起始行(%d)大于结束行(%d)", start_line, end_line))
            end
            return
          end

          local before = {}
          for i = 1, start_line - 1 do
            table.insert(before, lines[i])
          end
          local after = {}
          for i = end_line + 1, total do
            table.insert(after, lines[i])
          end

          local new_lines = {}
          if #before > 0 then
            table.insert(new_lines, table.concat(before, "\n"))
          end
          table.insert(new_lines, content)
          if #after > 0 then
            table.insert(new_lines, table.concat(after, "\n"))
          end
          local new_content = table.concat(new_lines, "\n")
          if file_content:sub(-1) == "\n" then
            new_content = new_content .. "\n"
          end

          local success, _ = fu.write_file(filepath, new_content, false)
          if success == true then
            on_write_ok()
          else
            on_write_err("写入失败")
          end
        end

        local file_content, err = fu.read_file(filepath)
        if file_content then
          do_range_replace(file_content)
        else
          if on_error then
            on_error(string.format("读取文件失败 %s: %s", filepath, err or "无法读取文件"))
          end
        end
        return
      end

      local success, _ = fu.write_file(filepath, content, append)
      if success == true then
        on_write_ok()
      else
        on_write_err("写入失败")
      end
    end

    on_exists(fu.exists(filepath))
  end

  check_exists_and_proceed()
end

M.edit_file = define_tool({
  name = "edit_file",
  description = "修改文件内容，修改某行到某行的内容，尽量减少对原文件的改动",
  func = _edit_file,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径（必填）" },
      append = {
        type = "boolean",
        description = "是否追加模式，false 为覆盖（必填）",
      },
      start_line = {
        type = "number",
        description = "起始行号，从1开始，用于替换指定行范围（需配合 end_line）",
      },
      end_line = {
        type = "number",
        description = "结束行号，用于替换指定行范围（需配合 start_line）",
      },
      content = { type = "string", description = "要写入的内容（可选，不填时默认追加模式）" },
    },
    required = { "filepath", "append" },
  },
  returns = {
    type = "object",
    properties = {
      filepath = { type = "string" },
      success = { type = "boolean" },
      diagnostics = {
        type = "array",
        description = "修改后文件的 LSP 诊断信息列表（如有），每项包含 severity, message, source, code, lnum, col 等字段",
      },
      diagnostic_count = {
        type = "number",
        description = "诊断信息条数",
      },
    },
    description = "写入结果，包含文件路径、是否成功。写入成功后异步等待 LSP 诊断（最多 10 秒），诊断到达后随返回值一起返回",
  },
  category = "file",
  permissions = { write = true },
})

-- ============================================================================
-- 工具 list_files
-- ============================================================================

local function glob_to_lua_pattern(glob)
  if glob == "*" then
    return nil
  end
  local p = vim.pesc(glob)
  p = p:gsub("%%%*", ".*"):gsub("%%%?", ".")
  return p
end

local function scan_dir_flat(dir, pattern, all_results, max_results, done_callback)
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
              if max_results and #all_results >= max_results then
                vim.uv.fs_closedir(dir_handle)
                if done_callback then
                  done_callback()
                end
                return
              end
            end
          end
        end
        read_all_entries()
      end)
    end
    read_all_entries()
  end)
end

local function scan_dir_recursive(dir, pattern, all_results, max_results, done_callback)
  vim.uv.fs_opendir(dir, function(opendir_err, dir_handle)
    if opendir_err or not dir_handle then
      if done_callback then
        done_callback()
      end
      return
    end
    local lua_pattern = glob_to_lua_pattern(pattern)
    local subdirs = {}
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
            scan_dir_recursive(subdir, pattern, all_results, max_results, subdir_done)
          end
          return
        end
        for _, entry in ipairs(entries) do
          local name = entry.name
          local typ = entry.type
          local full_path = dir .. "/" .. name
          if typ == "file" then
            if lua_pattern == nil or name:match(lua_pattern) then
              table.insert(all_results, full_path)
              if max_results and #all_results >= max_results then
                vim.uv.fs_closedir(dir_handle)
                if done_callback then
                  done_callback()
                end
                return
              end
            end
          elseif typ == "directory" then
            if name ~= "." and name ~= ".." then
              table.insert(subdirs, full_path)
            end
          end
        end
        read_all_entries()
      end)
    end
    read_all_entries()
  end)
end

local function _list_files(args, on_success, on_error)
  if not args or not args.dir then
    if on_error then
      on_error("需要 dir 参数")
    end
    return
  end

  local dir = resolve_path(args.dir)
  local pattern = args.pattern or "*"
  local recursive = args.recursive or false
  local max_results = args.max_results
  if max_results == nil or max_results <= 0 then
    max_results = 50
  end
  local all_files = {}

  local function done_callback()
    if on_success then
      on_success(all_files)
    end
  end

  if recursive then
    scan_dir_recursive(dir, pattern, all_files, max_results, done_callback)
  else
    scan_dir_flat(dir, pattern, all_files, max_results, done_callback)
  end
end

M.list_files = define_tool({
  name = "list_files",
  description = "列出目录中的文件，支持模式匹配和递归查找",
  func = _list_files,
  async = true,
  parameters = {
    type = "object",
    properties = {
      dir = { type = "string", description = "目录路径（必填）", default = "." },
      pattern = { type = "string", description = "文件模式（如 *.txt）", default = "*" },
      recursive = { type = "boolean", description = "是否递归查找", default = false },
      max_results = {
        type = "number",
        description = "最大返回结果数，默认50",
        default = 50,
      },
    },
    required = { "dir" },
  },
  returns = { type = "array", items = { type = "string" }, description = "文件路径列表" },
  category = "file",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 search_files
-- ============================================================================

local function _search_files(args, on_success, on_error)
  if not args or not args.pattern then
    if on_error then
      on_error("需要 pattern 参数")
    end
    return
  end

  local dir = resolve_path(args.dir or ".")
  local file_pattern = args.file_pattern or "*"
  local case_sensitive = args.case_sensitive
  if case_sensitive == nil then
    case_sensitive = false
  end
  local regex = args.regex
  if regex == nil then
    regex = true
  end
  local search_pattern = args.pattern
  local max_results = args.max_results
  if max_results == nil or max_results <= 0 then
    max_results = 50
  end

  local grep_args = {}
  table.insert(grep_args, "-r")
  if not case_sensitive then
    table.insert(grep_args, "-i")
  end
  if not regex then
    table.insert(grep_args, "-F")
  end
  table.insert(grep_args, "-n")
  if file_pattern and file_pattern ~= "*" then
    table.insert(grep_args, "--include")
    table.insert(grep_args, file_pattern)
  end
  table.insert(grep_args, "--")
  table.insert(grep_args, search_pattern)
  table.insert(grep_args, dir)

  local stdout_pipe = vim.uv.new_pipe()
  local stderr_pipe = vim.uv.new_pipe()
  local stdout_data = {}
  local stderr_data = {}
  local results = {}

  local function safe_close_pipe(pipe)
    if pipe and not pipe:is_closing() then
      pipe:read_stop()
      pipe:close()
    end
  end

  local handle = vim.uv.spawn("grep", {
    args = grep_args,
    stdio = { nil, stdout_pipe, stderr_pipe },
  }, function(code)
    safe_close_pipe(stdout_pipe)
    safe_close_pipe(stderr_pipe)

    if code == 0 or code == 1 then
      local output = table.concat(stdout_data, "")
      for line in output:gmatch("[^\n]+") do
        local file, line_num, content = line:match("^(.+):(%d+):(.+)$")
        if file and line_num and content then
          table.insert(results, { file = file, line = tonumber(line_num), content = content })
          if max_results and max_results > 0 and #results >= max_results then
            break
          end
        end
      end
      if on_success then
        on_success(results)
      end
    else
      local err_msg = table.concat(stderr_data, ""):gsub("^%s*(.-)%s*$", "%1")
      if on_error then
        on_error(
          string.format("grep 搜索失败 (dir=%s, pattern=%s): %s", dir, search_pattern, err_msg or "未知错误")
        )
      end
    end
  end)

  if handle then
    if stdout_pipe then
      stdout_pipe:read_start(function(_, data)
        if data then
          table.insert(stdout_data, data)
        end
      end)
    end
    if stderr_pipe then
      stderr_pipe:read_start(function(_, data)
        if data then
          table.insert(stderr_data, data)
        end
      end)
    end
  else
    safe_close_pipe(stdout_pipe)
    safe_close_pipe(stderr_pipe)
    if on_error then
      on_error(string.format("无法启动 grep 进程 (dir=%s, pattern=%s)", dir, search_pattern))
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
      pattern = { type = "string", description = "搜索模式（必填）" },
      dir = { type = "string", description = "搜索目录", default = "." },
      regex = { type = "boolean", description = "是否使用正则匹配", default = true },
      case_sensitive = { type = "boolean", description = "是否区分大小写", default = false },
      file_pattern = { type = "string", description = "文件通配符模式", default = "*" },
      max_results = {
        type = "number",
        description = "最大返回结果数，默认50",
        default = 50,
      },
    },
    required = { "pattern" },
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
  if not args or not args.filepath then
    if on_error then
      on_error("需要 filepath 参数")
    end
    return
  end

  local filepath = resolve_path(args.filepath)

  local function on_exists(exists)
  local function on_exists(exists)
    if on_success then
      on_success({ filepath = filepath, exists = exists })
    end
  end

  on_exists(fu.exists(filepath))
end

M.file_exists = define_tool({
  name = "file_exists",
  description = "检查文件或目录是否存在",
  func = _file_exists,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件或目录路径（必填）" },
    },
    required = { "filepath" },
  },
  returns = {
    type = "object",
    properties = { filepath = { type = "string" }, exists = { type = "boolean" } },
    description = "路径存在状态",
  },
  category = "file",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 create_directory
-- ============================================================================

local function _create_directory(args, on_success, on_error)
  if not args or not args.filepath then
    if on_error then
      on_error("需要 filepath 参数")
    end
    return
  end

  local filepath = resolve_path(args.filepath)

  local function on_created(ok)
    if ok then
      if on_success then
        on_success({ filepath = filepath, success = true })
      end
    else
      if on_error then
        on_error(string.format("创建目录失败: %s", filepath))
      end
    end
  end

  local success, _ = fu.mkdir(filepath)
  on_created(success == true)
end

M.create_directory = define_tool({
  name = "create_directory",
  description = "创建目录",
  func = _create_directory,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "目录路径（必填）" },
      parents = { type = "boolean", description = "是否创建父目录", default = true },
    },
    required = { "filepath" },
  },
  returns = {
    type = "object",
    properties = { filepath = { type = "string" }, success = { type = "boolean" } },
    description = "目录创建结果",
  },
  category = "file",
  permissions = { write = true },
})

-- ============================================================================
-- 工具 ensure_dir
-- ============================================================================

local function _ensure_dir(args, on_success, on_error)
  if not args or not args.filepath then
    if on_error then
      on_error("需要 filepath 参数")
    end
    return
  end

  local filepath = resolve_path(args.filepath):gsub("/+$", "")

  local function on_ensured(ok)
    if ok then
      if on_success then
        on_success({ filepath = args.filepath, success = true })
      end
    else
      if on_error then
        on_error(string.format("确保目录失败: %s", args.filepath))
      end
    end
  end

  local success, _ = fu.mkdir(filepath)
  on_ensured(success == true)
end

M.ensure_dir = define_tool({
  name = "ensure_dir",
  description = "确保目录存在，如果不存在则创建",
  func = _ensure_dir,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "目录路径（必填）" },
      parents = { type = "boolean", description = "是否创建父目录", default = true },
    },
    required = { "filepath" },
  },
  returns = {
    type = "object",
    properties = { filepath = { type = "string" }, success = { type = "boolean" } },
    description = "目录确保结果",
  },
  category = "file",
  permissions = { write = true },
})

-- ============================================================================
-- 工具 delete_file
-- ============================================================================

local function _delete_file(args, on_success, on_error)
  if not args or not args.filepath then
    if on_error then
      on_error("需要 filepath 参数")
    end
    return
  end

  local filepath = resolve_path(args.filepath)

  if not fu.exists(filepath) then
    if on_error then
      on_error(string.format("文件不存在: %s", filepath))
    end
    return
  end

  local ok, err = fu.delete_file(filepath)
  if ok then
    if on_success then
      on_success({ filepath = filepath, success = true })
    end
  else
    if on_error then
      on_error(string.format("删除文件失败 %s: %s", filepath, err or "无法删除文件"))
    end
  end
end

M.delete_file = define_tool({
  name = "delete_file",
  description = "删除文件",
  func = _delete_file,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径（必填）" },
    },
    required = { "filepath" },
  },
  returns = {
    type = "object",
    properties = { filepath = { type = "string" }, success = { type = "boolean" } },
    description = "文件删除结果",
  },
  category = "file",
  permissions = { write = true },
})

M.delete_file = define_tool({
  name = "delete_file",
  description = "删除文件",
  func = _delete_file,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径（必填）" },
    },
    required = { "filepath" },
  },
  returns = {
    type = "object",
    properties = { filepath = { type = "string" }, success = { type = "boolean" } },
    description = "文件删除结果",
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
