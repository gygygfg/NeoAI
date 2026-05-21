-- Lua文件操作工具模块（回调模式）
-- 所有工具使用回调模式异步执行，不阻塞主线程
-- 工具函数签名：func(args, on_success, on_error)
local M = {}

local fu = require("NeoAI.utils.file_utils")
local neovim_tree = require("NeoAI.tools.builtin.neovim_tree")
local block_node_types = neovim_tree.block_node_types or {}

local log_tools = require("NeoAI.tools.builtin.log_tools")

-- ============================================================================
-- 并发读取队列：防止多个 read_file 同时执行导致主线程卡顿
-- ============================================================================
local read_queue = {}
local read_queue_active = false

local function process_read_queue()
  if read_queue_active or #read_queue == 0 then
    return
  end
  read_queue_active = true
  local task = table.remove(read_queue, 1)
  vim.schedule(function()
    task()
  end)
end

local function enqueue_read(task_fn)
  table.insert(read_queue, task_fn)
  if not read_queue_active then
    process_read_queue()
  end
end

local function dequeue_read()
  read_queue_active = false
  if #read_queue > 0 then
    process_read_queue()
  end
end

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

  local filepath = args.filepath
  local start_line = args.start_line or args.start or 1
  local end_line = args.end_line or args["end"] or -1
  local is_full_file = (start_line == 1) and (end_line == -1)

  -- 将实际读取逻辑包装为任务函数，放入并发队列串行执行
  local function do_read()
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
              dequeue_read()
            else
              local output_lines = {}
              for i = 1, total_lines do
                table.insert(output_lines, string.format("%4d | %s", i, all_lines[i] or ""))
              end
              local header = string.format("=== %s === (行 1-%d, 共 %d 行)", filepath, total_lines, total_lines)
              if on_success then
                on_success(header .. "\n" .. table.concat(output_lines, "\n"))
              end
              dequeue_read()
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
            dequeue_read()
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
        dequeue_read()
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
      dequeue_read()
    end

    local function on_read_err(err)
      if on_error then
        on_error(string.format("读取文件失败 %s: %s", filepath, err or "无法读取文件"))
      end
      dequeue_read()
    end

    local content, err = fu.read_file(filepath)
    if content then
      on_content(content)
    else
      on_read_err(err)
    end
  end

  -- 将读取任务加入队列，串行执行
  enqueue_read(do_read)
end
M.read_file = {
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
}

-- ============================================================================
-- 工具 replace_text
-- ============================================================================

--- 将 vim.diagnostic 列表格式化为统一结构
--- @param diagnostics table vim.diagnostic.get 返回的诊断列表
--- @return table 格式化后的诊断列表
local function format_diagnostics(diagnostics)
  if not diagnostics then
    return {}
  end
  local results = {}
  for _, d in ipairs(diagnostics) do
    table.insert(results, {
      message = d.message,
      severity = d.severity, -- 1=Error,2=Warn,3=Info,4=Hint
      source = d.source,
      code = d.code,
      lnum = d.lnum and d.lnum + 1 or nil, -- 转为 1-based
      end_lnum = d.end_lnum and d.end_lnum + 1 or nil,
      col = d.col and d.col + 1 or nil,
      end_col = d.end_col and d.end_col + 1 or nil,
    })
  end
  return results
end

--- 规范化行文本：去除 \r，tab 转空格
local function normalize_line_text(line)
  if not line then
    return ""
  end
  local normalized = line
  normalized = normalized:gsub("\r", "")
  normalized = normalized:gsub("\t", "    ")
  return normalized
end

--- 从指定行号开始，上下查找匹配的文本行
--- 返回: { start_line, end_line } 或 nil
local function find_text_range(lines, anchor_line, search_text)
  if not lines or not anchor_line or not search_text then
    return nil
  end
  if anchor_line < 1 or anchor_line > #lines then
    return nil
  end

  local normalized_search = normalize_line_text(search_text)
  if normalized_search == "" then
    return nil
  end

  -- 去除所有空白字符（空格、制表符）后匹配
  -- 忽略缩进差异，只匹配非空白内容
  local search_stripped = normalized_search:gsub("%s", "")
  if search_stripped == "" then
    return nil
  end

  -- 匹配函数：去除行中所有空白字符后做子串匹配
  local function line_matches(line)
    local line_stripped = normalize_line_text(line):gsub("%s", "")
    return line_stripped:find(search_stripped, 1, true) ~= nil
  end

  if line_matches(lines[anchor_line]) then
    local s, e = anchor_line, anchor_line
    for i = anchor_line + 1, #lines do
      if line_matches(lines[i]) then
        e = i
      else
        break
      end
    end
    for i = anchor_line - 1, 1, -1 do
      if line_matches(lines[i]) then
        s = i
      else
        break
      end
    end
    return { start_line = s, end_line = e }
  end

  -- 回退搜索：从 anchor 向上查找
  for i = anchor_line - 1, math.max(1, anchor_line - 10), -1 do
    if line_matches(lines[i]) then
      local s, e = i, i
      for j = i + 1, #lines do
        if line_matches(lines[j]) then
          e = j
        else
          break
        end
      end
      for j = i - 1, 1, -1 do
        if line_matches(lines[j]) then
          s = j
        else
          break
        end
      end
      return { start_line = s, end_line = e }
    end
  end

  -- 回退搜索：从 anchor 向下查找
  for i = anchor_line + 1, math.min(#lines, anchor_line + 10) do
    if line_matches(lines[i]) then
      local s, e = i, i
      for j = i + 1, #lines do
        if line_matches(lines[j]) then
          e = j
        else
          break
        end
      end
      for j = i - 1, 1, -1 do
        if line_matches(lines[j]) then
          s = j
        else
          break
        end
      end
      return { start_line = s, end_line = e }
    end
  end

  return nil
end

local function _replace_text(args, on_success, on_error)
  if not args or not args.filepath then
    if on_error then
      on_error("需要 filepath 参数")
    end
    return
  end

  local filepath = args.filepath
  local new_text = args.new_text
  local start_match = args.start_match -- { line_number, search_text }
  local end_match = args.end_match -- { line_number, search_text }

  if not new_text then
    if on_error then
      on_error("需要 new_text 参数（替换后的文本内容）")
    end
    return
  end

  if not start_match or not end_match then
    if on_error then
      on_error("需要 start_match 和 end_match 参数（格式：{line_number, search_text}）")
    end
    return
  end

  local file_content, err = fu.read_file(filepath)
  if not file_content then
    if on_error then
      on_error(string.format("读取文件失败 %s: %s", filepath, err or "无法读取文件"))
    end
    return
  end

  -- 先剥掉末尾换行再 split
  local has_trailing_nl = file_content:sub(-1) == "\n"
  local content = has_trailing_nl and file_content:sub(1, -2) or file_content
  local lines = vim.split(content, "\n", { plain = true })
  local total_lines = #lines

  local start_anchor = start_match.line_number
  local start_text = start_match.search_text
  local end_anchor = end_match.line_number
  local end_text = end_match.search_text

  if not start_anchor or not start_text or not end_anchor or not end_text then
    if on_error then
      on_error("start_line 和 end_line 必须为 {line_number, search_text} 格式")
    end
    return
  end

  if start_anchor < 1 or start_anchor > total_lines then
    if on_error then
      on_error(string.format("start_line 行号 %d 超出文件范围 (1-%d)", start_anchor, total_lines))
    end
    return
  end
  if end_anchor < 1 or end_anchor > total_lines then
    if on_error then
      on_error(string.format("end_line 行号 %d 超出文件范围 (1-%d)", end_anchor, total_lines))
    end
    return
  end

  local start_range = find_text_range(lines, start_anchor, start_text)
  if not start_range then
    if on_error then
      on_error(string.format("在行 %d 附近未找到匹配文本: %s", start_anchor, start_text))
    end
    return
  end

  local end_range = find_text_range(lines, end_anchor, end_text)
  if not end_range then
    if on_error then
      on_error(string.format("在行 %d 附近未找到匹配文本: %s", end_anchor, end_text))
    end
    return
  end

  local replace_start = start_range.start_line
  local replace_end = end_range.end_line

  if replace_start > replace_end then
    if on_error then
      on_error(
        string.format(
          "起始匹配范围(行 %d-%d)在结束匹配范围(行 %d-%d)之后，请检查搜索文本",
          start_range.start_line,
          start_range.end_line,
          end_range.start_line,
          end_range.end_line
        )
      )
    end
    return
  end

  -- 构建新文件内容
  local new_lines = {}
  for i = 1, replace_start - 1 do
    table.insert(new_lines, lines[i])
  end
  local replacement_lines = vim.split(new_text, "\n", { plain = true })

  for _, rl in ipairs(replacement_lines) do
    table.insert(new_lines, rl)
  end
  for i = replace_end + 1, total_lines do
    table.insert(new_lines, lines[i])
  end

  local new_content_str = table.concat(new_lines, "\n")
  if has_trailing_nl then
    new_content_str = new_content_str .. "\n"
  end

  local success, write_err = fu.write_file(filepath, new_content_str, false)
  if success ~= true then
    if on_error then
      on_error(string.format("写入文件失败 %s: %s", filepath, write_err or "写入失败"))
    end
    return
  end

  -- 写入成功，构建基础结果
  local base_result = {
    filepath = filepath,
    success = true,
    start_line = replace_start,
    end_line = replace_end,
    diagnostics = {},
    diagnostic_count = 0,
  }

  -- 异步加载文件到 buffer 并监听 LSP 诊断，诊断到达或超时后再调用 on_success
  vim.schedule(function()
    local emitted = false
    local lsp_ok, lsp_utils = pcall(require, "NeoAI.utils.lsp_utils")
    if not lsp_ok or not lsp_utils or not lsp_utils.check_lsp() then
      if on_success then
        on_success(base_result)
      end
      return
    end

    local bufnr, cleanup, buf_err = lsp_utils.ensure_buf_loaded(filepath)
    if buf_err or not bufnr then
      if on_success then
        on_success(base_result)
      end
      return
    end

    -- 确保文件类型正确设置（bufadd/bufload 可能未正确触发 FileType 事件）
    local ft = vim.filetype.match({ buf = bufnr, filename = filepath })
    if ft and ft ~= "" then
      local current_ft = vim.bo[bufnr].filetype
      if current_ft ~= ft then
        vim.bo[bufnr].filetype = ft
      end
    end

    -- Tree-sitter 后备诊断：当 LSP 诊断不可用时，使用 Tree-sitter 的 ERROR 节点检测语法错误
    local function get_ts_error_diagnostics()
      local ok_parser = pcall(vim.treesitter.get_parser, bufnr)
      if not ok_parser then
        -- 尝试通过语言名获取解析器
        local ft = vim.bo[bufnr].filetype
        if ft and ft ~= "" then
          local ok_lang = pcall(vim.treesitter.language.get_lang, ft)
          if ok_lang then
            ok_parser = pcall(vim.treesitter.get_parser, bufnr, ft)
          end
        end
      end
      if not ok_parser then
        return {}
      end

      local ok_parse, tree = pcall(function()
        local p = vim.treesitter.get_parser(bufnr)
        if not p then
          return {}
        end
        return p:parse()
      end)
      if not ok_parse or not tree or #tree == 0 then
        return {}
      end

      local root = tree[1]:root()
      local ts_ft = vim.bo[bufnr].filetype or "python"
      local ok_query, query = pcall(vim.treesitter.query.parse, ts_ft, "((ERROR) @err)")
      if not ok_query or not query then
        return {}
      end

      local results = {}
      local seen_positions = {} -- 去重
      for pattern, match in query:iter_matches(root, bufnr, 0, -1) do
        for id, capture_table in pairs(match) do
          -- 在 Neovim 0.10+ 中，capture_table 是 { [1] = TSNode_userdata } 格式
          local tsnode = capture_table and capture_table[1]
          if tsnode then
            local ok_range, srow, scol, erow, ecol = pcall(tsnode.range, tsnode)
            if ok_range then
              local pos_key = srow .. "-" .. scol .. "-" .. erow .. "-" .. ecol
              if not seen_positions[pos_key] then
                seen_positions[pos_key] = true
                local err_text = vim.treesitter.get_node_text(tsnode, bufnr)
                if err_text and #err_text > 80 then
                  err_text = err_text:sub(1, 80) .. "..."
                end
                table.insert(results, {
                  message = "语法错误: " .. (err_text or ""),
                  severity = 1,
                  source = "treesitter",
                  code = nil,
                  lnum = srow + 1,
                  end_lnum = erow + 1,
                  col = scol + 1,
                  end_col = ecol + 1,
                })
              end
            end
          end
        end
      end
      return results
    end

    local function emit_diagnostics()
      emitted = true

      pcall(function()
        diag_timer:stop()
      end)
      pcall(function()
        diag_timer:close()
      end)

      -- 删除 autocmd，避免后续误触发
      pcall(vim.api.nvim_del_augroup_by_id, augroup)

      if cleanup then
        cleanup()
      end

      if on_success then
        -- 先尝试 LSP 诊断
        local diagnostics = vim.diagnostic.get(bufnr)
        if not diagnostics or #diagnostics == 0 then
          -- LSP 诊断为空，回退到 Tree-sitter
          diagnostics = get_ts_error_diagnostics()
        end
        base_result.diagnostics = format_diagnostics(diagnostics)
        base_result.diagnostic_count = #diagnostics
        on_success(base_result)
      end
    end

    --- 触发 FileType autocmd 以启动 LSP（如果尚未运行）
    local function trigger_lsp_autocmd()
      local current_ft = vim.bo[bufnr].filetype
      if current_ft and current_ft ~= "" then
        -- 先检查是否已有该文件类型的 LSP 客户端
        local lm
        pcall(function()
          lm = require("NeoAI.utils.language_map")
        end)
        local expected_config = lm and lm.ft_to_lsp_config and lm.ft_to_lsp_config[current_ft]

        -- 检查是否有同名的 LSP 客户端已 attach
        local already_attached = false
        if expected_config then
          local attached = vim.lsp.get_clients({ bufnr = bufnr })
          for _, c in ipairs(attached) do
            if c.name == expected_config then
              already_attached = true
              break
            end
          end
        end

        if not already_attached then
          -- 触发 FileType 事件，让 lspconfig 或其他机制启动 LSP
          -- 注意：不要指定 group，这样才能执行所有注册的 FileType autocmd
          pcall(vim.api.nvim_exec_autocmds, "FileType", {
            buffer = bufnr,
            modelines = false,
          })
          -- 再次检查是否有客户端 attach
          local after = vim.lsp.get_clients({ bufnr = bufnr })
          if #after == 0 and expected_config then
            -- FileType 事件未触发 LSP 启动，手动尝试启动
            local mason_cmd = lm and lm.mason_executables and lm.mason_executables[expected_config]
            if not mason_cmd then
              mason_cmd = lm and lm.lsp_commands and lm.lsp_commands[expected_config]
            end
            if mason_cmd then
              local project_root = filepath
              pcall(function()
                local fu = require("NeoAI.utils.file_utils")
                project_root = fu.find_project_root(filepath) or vim.fn.getcwd()
              end)
              local temp_config = {
                name = expected_config,
                cmd = mason_cmd,
                root_dir = project_root,
              }
              local ok, client_id = pcall(vim.lsp.start, temp_config)
              if ok and client_id then
                pcall(vim.lsp.buf_attach_client, bufnr, client_id)
              end
            end
          end
        end
        return true
      end
      return false
    end

    --- 向已附加的 LSP 客户端发送 didChange 通知，强制重新诊断
    local function force_lsp_diagnostics()
      local clients = vim.lsp.get_clients({ bufnr = bufnr })
      if #clients == 0 then
        return false
      end

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      -- 去除末尾多余的空行（nvim_buf_get_lines 总是以空行结尾）
      if #lines > 0 and lines[#lines] == "" then
        local actual_line_count = vim.api.nvim_buf_line_count(bufnr)
        if #lines > actual_line_count then
          table.remove(lines)
        end
      end
      local text = table.concat(lines, "\n")
      local uri = vim.uri_from_bufnr(bufnr)
      local version = vim.b[bufnr].changedtick or 1

      for _, client in ipairs(clients) do
        if client.supports_method and client.supports_method("textDocument/didChange", { bufnr = bufnr }) then
          local ok, err = pcall(client.notify, client, "textDocument/didChange", {
            textDocument = {
              uri = uri,
              version = version,
            },
            contentChanges = {
              {
                text = text,
              },
            },
          })
          if not ok then
            log_tools.log_tool("force_lsp_diagnostics notify error: " .. tostring(err), "warn")
          end
        end
      end
      return true
    end

    -- 超时保护：5 秒后不再等待，返回当前已有的诊断
    local diag_timer = vim.defer_fn(function()
      -- 先删除 autocmd，避免在清理过程中误触发
      pcall(vim.api.nvim_del_augroup_by_id, augroup)
      emit_diagnostics()
    end, 5000)

    -- 创建 autocmd 组，分别监听 LspAttach 和 DiagnosticChanged
    local augroup = vim.api.nvim_create_augroup("neoai_replace_text_diag_" .. bufnr, { clear = true })

    -- LspAttach：LSP 客户端 attach 时，主动触发诊断请求
    vim.api.nvim_create_autocmd("LspAttach", {
      group = augroup,
      buffer = bufnr,
      callback = function()
        -- 延迟一下等 LSP 稳定后，主动触发诊断
        vim.defer_fn(function()
          force_lsp_diagnostics()
          -- 再延迟一小段时间让 LSP 处理并发布诊断
          vim.defer_fn(function()
            local diags = vim.diagnostic.get(bufnr)
            if diags and #diags > 0 then
              emit_diagnostics()
            end
          end, 800)
        end, 200)
      end,
    })

    -- DiagnosticChanged：LSP 发布诊断时立即收集（不设 once，确保能捕获）
    vim.api.nvim_create_autocmd("DiagnosticChanged", {
      group = augroup,
      buffer = bufnr,
      callback = function()
        emit_diagnostics()
      end,
    })

    -- === 核心修复：主动触发 FileType 事件以启动 LSP ===
    -- 先设置好 autocmd，再触发 FileType 事件
    trigger_lsp_autocmd()

    -- 检查是否已有客户端 attach（可能通过 FileType 事件刚启动）
    local clients = vim.lsp.get_clients({ bufnr = bufnr })
    if #clients > 0 then
      vim.defer_fn(function()
        force_lsp_diagnostics()
        vim.defer_fn(function()
          local diags = vim.diagnostic.get(bufnr)
          if diags and #diags > 0 then
            emit_diagnostics()
          end
        end, 800)
      end, 100)
    end

    -- 立即检查当前是否已有诊断（可能 buffer 已加载且 LSP 已发布诊断）
    local existing_diags = vim.diagnostic.get(bufnr)
    if existing_diags and #existing_diags > 0 then
      emit_diagnostics()
    end
  end)
end

M.replace_text = {
  name = "replace_text",
  description = [[替换文件中指定范围的文本内容。替换的是从 **start_match 匹配行的行首**到 **end_match 匹配行的行尾**的完整范围，而非行内的子串。
  start_match = { line_number: 行号, search_text: "搜索文本" }
  end_match = { line_number: 行号, search_text: "搜索文本" }
  工具会从指定行号开始上下查找匹配的文本
  示例：
  { filepath = "/path/to/file", start_match = {line_number = 5, search_text = "function foo"}, end_match = {line_number = 7, search_text = "}"}, new_text = "新的函数内容" }]],
  func = _replace_text,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径（必填）" },
      start_match = {
        type = "object",
        properties = {
          line_number = { type = "number", description = "行号" },
          search_text = { type = "string", description = "搜索文本" },
        },
        required = { "line_number", "search_text" },
        additionalProperties = false,
        description = "起始匹配定位：{line_number, search_text}，工具从该行号上下查找匹配文本，确定替换起始位置",
      },
      end_match = {
        type = "object",
        properties = {
          line_number = { type = "number", description = "行号" },
          search_text = { type = "string", description = "搜索文本" },
        },
        required = { "line_number", "search_text" },
        additionalProperties = false,
        description = "结束匹配定位：{line_number, search_text}，工具从该行号上下查找匹配文本，确定替换结束位置",
      },
      new_text = {
        type = "string",
        description = "替换后的新文本内容（必填）",
      },
    },
    required = { "filepath", "start_match", "end_match", "new_text" },
  },
  returns = {
    type = "object",
    description = "替换结果，包含文件路径、是否成功、替换范围及 LSP 诊断信息",
    properties = {
      filepath = { type = "string" },
      success = { type = "boolean" },
      start_line = { type = "number", description = "实际替换的起始行号" },
      end_line = { type = "number", description = "实际替换的结束行号" },

      diagnostic_count = { type = "number", description = "LSP 诊断数量（仅 LSP 可用时提供）" },
      diagnostics = {
        type = "array",
        items = {
          type = "object",
          properties = {
            message = { type = "string" },
            severity = { type = "number", description = "1=错误, 2=警告, 3=信息, 4=提示" },
            source = { type = "string" },
            code = { type = "number" },
            lnum = { type = "number", description = "行号（1-based）" },
            end_lnum = { type = "number" },
            col = { type = "number" },
            end_col = { type = "number" },
          },
        },
        description = "LSP 诊断列表（仅 LSP 可用时提供）",
      },
    },
  },
  category = "file",
  permissions = { write = true },
}
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

  local dir = args.dir
  -- 去掉末尾斜杠，避免路径中出现双斜杠（如 /tmp//file.txt）
  dir = dir:gsub("/+$", "")
  local pattern = args.pattern or "*"
  local recursive = args.recursive or false
  local max_results = args.max_results
  if max_results == nil or max_results <= 0 then
    max_results = 50
  end
  local all_files = {}

  local function done_callback()
    vim.schedule(function()
      if on_success then
        on_success(all_files)
      end
    end)
  end

  if recursive then
    scan_dir_recursive(dir, pattern, all_files, max_results, done_callback)
  else
    scan_dir_flat(dir, pattern, all_files, max_results, done_callback)
  end
end

M.list_files = {
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
}

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

  local dir = args.dir or "."
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
    vim.schedule(function()
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

M.search_files = {
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
}

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
  local filepath = args.filepath

  local function on_exists(exists)
    if on_success then
      on_success({ filepath = filepath, exists = exists })
    end
  end

  on_exists(fu.exists(filepath))
end

M.file_exists = {
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
}

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

  local filepath = args.filepath

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

M.create_directory = {
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
}

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

  local filepath = args.filepath:gsub("/+$", "")

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

M.ensure_dir = {
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
}

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

  local filepath = args.filepath
  -- 去掉末尾斜杠，统一路径格式
  filepath = filepath:gsub("/+$", "")

  if not fu.exists(filepath) then
    if on_error then
      on_error(string.format("路径不存在: %s", filepath))
    end
    return
  end

  -- 使用 uv.fs_stat 检测是文件还是目录
  local uv = vim.uv or vim.loop
  local stat_ok, stat = pcall(uv.fs_stat, filepath)
  local is_dir = stat_ok and stat and stat.type == "directory"

  if is_dir then
    -- 目录使用 uv.fs_rmdir（仅支持空目录）
    local callback_called = false
    local function safe_callback(ok, result)
      if callback_called then
        return
      end
      callback_called = true
      if timer then
        timer:stop()
        timer:close()
      end
      if ok then
        if on_success then
          on_success(result)
        end
      else
        if on_error then
          on_error(result)
        end
      end
    end

    local timer = uv.new_timer()
    if timer then
      timer:start(
        10000,
        0,
        vim.schedule_wrap(function()
          safe_callback(false, string.format("删除目录超时 %s（目录可能非空或无权限）", filepath))
        end)
      )
    end
    uv.fs_rmdir(filepath, function(rmdir_err)
      vim.schedule(function()
        if rmdir_err then
          safe_callback(
            false,
            string.format(
              "删除目录失败 %s: %s（目录可能非空，请使用 run_command 执行 rm -rf）",
              filepath,
              tostring(rmdir_err)
            )
          )
        else
          safe_callback(true, { filepath = filepath, success = true, type = "directory" })
        end
      end)
    end)
  else
    -- 文件使用 uv.fs_unlink
    local callback_called = false
    local function safe_callback(ok, result)
      if callback_called then
        return
      end
      callback_called = true
      if timer then
        timer:stop()
        timer:close()
      end
      if ok then
        if on_success then
          on_success(result)
        end
      else
        if on_error then
          on_error(result)
        end
      end
    end

    local timer = uv.new_timer()
    if timer then
      timer:start(
        10000,
        0,
        vim.schedule_wrap(function()
          safe_callback(false, string.format("删除文件超时 %s（文件可能被锁定或无权限）", filepath))
        end)
      )
    end
    uv.fs_unlink(filepath, function(unlink_err)
      vim.schedule(function()
        if unlink_err then
          safe_callback(false, string.format("删除文件失败 %s: %s", filepath, tostring(unlink_err)))
        else
          safe_callback(true, { filepath = filepath, success = true, type = "file" })
        end
      end)
    end)
  end
end

M.delete_file = {
  name = "delete_file",
  description = "删除文件或空目录。非空目录请使用 run_command 执行 rm -rf",
  func = _delete_file,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件或空目录路径（必填）" },
    },
    required = { "filepath" },
  },
  returns = {
    type = "object",
    properties = {
      filepath = { type = "string" },
      success = { type = "boolean" },
      type = { type = "string", description = "删除类型：file 或 directory" },
    },
    description = "删除结果",
  },
  category = "file",
  permissions = { write = true },
}

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
