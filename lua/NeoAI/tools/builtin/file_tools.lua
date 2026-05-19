-- Lua文件操作工具模块（回调模式）
-- 所有工具使用回调模式异步执行，不阻塞主线程
-- 工具函数签名：func(args, on_success, on_error)
local M = {}

local fu = require("NeoAI.utils.file_utils")
local neovim_tree = require("NeoAI.tools.builtin.neovim_tree")
local block_node_types = neovim_tree.block_node_types or {}

local log_tools = require("NeoAI.tools.builtin.log_tools")

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
-- 工具 edit_file
-- ============================================================================

local function _edit_file(args, on_success, on_error)
  if not args or not args.filepath then
    if on_error then
      on_error("需要 filepath 参数")
    end
    return
  end

  local filepath = args.filepath
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
  local end_line = args.end_line
  -- on_write_err 是 on_error 的别名，供内部闭包使用
  local on_write_err = on_error
  -- LSP 诊断等待最大超时（毫秒），避免因 LSP 无响应导致永久挂起
  local max_wait = args.max_wait or 20000

  -- 通用写回调：写入成功后尝试获取 LSP 诊断信息
  local function on_write_ok()
    local result = { filepath = filepath, success = true }

    -- 保存当前窗口和 buffer，避免后续操作改变焦点
    local current_win = vim.api.nvim_get_current_win()
    local current_buf = vim.api.nvim_get_current_buf()

    local function restore_focus()
      pcall(vim.api.nvim_set_current_win, current_win)
      if vim.api.nvim_buf_is_valid(current_buf) then
        local win_buf = vim.api.nvim_win_get_buf(current_win)
        if win_buf ~= current_buf then
          pcall(vim.api.nvim_win_set_buf, current_win, current_buf)
        end
      end
    end

    local ok_lsp, lsp_mod = pcall(require, "NeoAI.tools.builtin.neovim_lsp")
    if ok_lsp and lsp_mod and lsp_mod.lsp_diagnostics and lsp_mod.lsp_diagnostics.func then
      local abs_path = vim.fn.fnamemodify(filepath, ":p")
      local bufnr = vim.fn.bufnr(abs_path)
      if bufnr ~= -1 then
        pcall(vim.api.nvim_buf_call, bufnr, function()
          vim.cmd("edit!")
        end)
      else
        -- 使用 nvim_create_buf 替代 bufadd/bufload，避免改变当前窗口焦点
        bufnr = vim.api.nvim_create_buf(false, true)
        pcall(vim.api.nvim_buf_set_name, bufnr, abs_path)
        local lines = vim.fn.readfile(abs_path)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.bo[bufnr].modified = false
      end

      -- 🔧 修复：设置 filetype 并主动附加 LSP 客户端
      -- bufload 不会触发 filetype 检测，edit! 在后台 buffer 也可能不触发
      -- 没有 filetype 则 LSP 无法匹配，没有客户端附加则 DiagnosticChanged 永不触发
      if vim.bo[bufnr].filetype == "" then
        local ft = vim.filetype.match({ filename = abs_path, buf = bufnr })
        if ft then
          vim.bo[bufnr].filetype = ft
        end
      end
      -- 主动将功能完整的 LSP 客户端附加到目标 buffer
      -- 排除仅补全类客户端（如 GitHub Copilot），避免不必要的附加
      local lsp_clients = vim.lsp.get_clients()
      for _, client in ipairs(lsp_clients) do
        local caps = client.server_capabilities or {}
        if caps.hoverProvider or caps.definitionProvider or caps.documentSymbolProvider or caps.diagnosticProvider then
          pcall(vim.lsp.buf_attach_client, bufnr, client.id)
        end
      end

      local finalized = false
      local timers = {}

      local function safe_close_all_timers()
        for _, t in ipairs(timers) do
          if t and not t:is_closing() then
            pcall(t.stop, t)
            pcall(t.close, t)
          end
        end
        timers = {}
      end

      local function do_fetch_diagnostics()
        if finalized then
          return
        end
        finalized = true
        safe_close_all_timers()

        -- 直接从 vim.diagnostic 获取当前 buffer 的诊断
        -- 此时 DiagnosticChanged 事件应已触发，诊断数据已就绪
        local diagnostics = vim.diagnostic.get(bufnr)
        local results = {}
        if diagnostics then
          for _, d in ipairs(diagnostics) do
            table.insert(results, {
              message = d.message,
              severity = d.severity,
              source = d.source,
              code = d.code,
              lnum = d.lnum and d.lnum + 1 or nil,
              end_lnum = d.end_lnum and d.end_lnum + 1 or nil,
              col = d.col and d.col + 1 or nil,
              end_col = d.end_col and d.end_col + 1 or nil,
            })
          end
        end
        result.diagnostics = results
        result.diagnostic_count = #results

        restore_focus()
        if on_success then
          on_success(result)
        end
      end

      -- 策略：
      -- 1) 监听 DiagnosticChanged 事件（LSP 发布诊断时触发）
      -- 2) 初始延迟 2000ms 后主动获取诊断（兜底）
      -- 3) 总超时 20 秒（防止 LSP 无响应）
      --
      -- 注意：DiagnosticChanged 事件在 LSP 发布 textDocument/publishDiagnostics 时触发，
      -- 即使诊断为空也会触发。事件触发后 vim.diagnostic.get 才能拿到最新数据。

      -- 1) 监听 DiagnosticChanged 事件
      local au_id = vim.api.nvim_create_autocmd("DiagnosticChanged", {
        buffer = bufnr,
        callback = function()
          if finalized then
            return
          end
          -- 事件触发后，防抖 500ms 再获取诊断
          -- 防抖避免 LSP 多次发布诊断时重复获取
          local dt = vim.uv.new_timer()
          if dt then
            table.insert(timers, dt)
            dt:start(
              500,
              0,
              vim.schedule_wrap(function()
                do_fetch_diagnostics()
              end)
            )
          end
        end,
      })

      -- 2) 初始延迟 2000ms：给 LSP 时间处理文件变更并发布诊断
      --    如果 DiagnosticChanged 事件已触发，防抖到期后会调用 do_fetch_diagnostics
      --    如果事件未触发（极端情况），2000ms 后主动获取
      local init_timer = vim.uv.new_timer()
      if init_timer then
        table.insert(timers, init_timer)
        init_timer:start(
          2000,
          0,
          vim.schedule_wrap(function()
            do_fetch_diagnostics()
          end)
        )
      end

      -- 3) 总超时保护（20秒），防止 LSP 无响应导致永久挂起
      local timeout_timer = vim.uv.new_timer()
      if timeout_timer then
        table.insert(timers, timeout_timer)
        timeout_timer:start(
          max_wait,
          0,
          vim.schedule_wrap(function()
            if finalized then
              return
            end
            log_tools.log_message.func(
              { message = "edit_file LSP 诊断等待超时 (" .. max_wait .. "ms)，直接返回", level = "warn" },
              function() end,
              function() end
            )
            do_fetch_diagnostics()
          end)
        )
      end
    else
      restore_focus()
      if on_success then
        on_success(result)
      end
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
        local ok, _ = fu.write_file(filepath, content, false)
        if ok then
          -- 使用 on_write_ok 获取 LSP 诊断信息，并在结果中加入 warning
          -- 通过将 warning 注入 result 中
          local orig_on_success = on_success
          on_success = function(result)
            result.warning = warning
            if orig_on_success then
              orig_on_success(result)
            end
          end
          on_write_ok()
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
          -- 去除 content 末尾的换行符，避免与后续拼接产生双重重叠换行
          local trimmed_content = content:gsub("\n+$", "")
          local new_lines = {}
          if #before > 0 then
            table.insert(new_lines, table.concat(before, "\n"))
          end
          table.insert(new_lines, trimmed_content)
          if #after > 0 then
            table.insert(new_lines, table.concat(after, "\n"))
          end
          local new_content = table.concat(new_lines, "\n")
          -- 如果原文件末尾有换行符，给新内容也加上换行符
          -- 注意：trimmed_content 已去除尾部 \n，所以不会重复
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
      -- 追加模式且 content 为空时，避免空操作
      if append and content == "" then
        if on_success then
          on_success({ filepath = filepath, success = true, notice = "内容为空，未做任何修改" })
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

M.edit_file = {
  name = "edit_file",
  description = "修改文件内容，修改某行到某行的内容，尽量减少对原文件的改动，每次编辑之后行号会变化要重新获取",
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
}

-- ============================================================================
-- 工具 replace_text
-- ============================================================================

local function _replace_text(args, on_success, on_error)
  if not args or not args.filepath then
    if on_error then
      on_error("需要 filepath 参数")
    end
    return
  end
  if not args.pattern then
    if on_error then
      on_error("需要 pattern 参数（匹配的正则表达式）")
    end
    return
  end
  if not args.replacement then
    if on_error then
      on_error("需要 replacement 参数（替换的文本）")
    end
    return
  end

  local filepath = args.filepath
  local pattern = args.pattern
  local replacement = args.replacement
  local start_line = args.start_line
  local end_line = args.end_line
  local dry_run = args.dry_run
  local allow_multi_line = args.allow_multi_line

  local file_content, err = fu.read_file(filepath)
  if not file_content then
    if on_error then
      on_error(string.format("读取文件失败 %s: %s", filepath, err or "无法读取文件"))
    end
    return
  end

  -- 安全检测：多行模式（含 \n）且没有指定行范围时，自动阻止执行
  if not start_line and not end_line and not allow_multi_line then
    if pattern:find("\n") then
      -- 扫描匹配位置
      local matches = {}
      local search_start = 1
      while true do
        local s_pos, e_pos = file_content:find(pattern, search_start)
        if not s_pos then
          break
        end
        -- 计算匹配的起始行号（1-based）
        local start_ln = 1
        for i = 1, s_pos - 1 do
          if file_content:sub(i, i) == "\n" then
            start_ln = start_ln + 1
          end
        end
        local end_ln = start_ln
        for i = s_pos, e_pos - 1 do
          if file_content:sub(i, i) == "\n" then
            end_ln = end_ln + 1
          end
        end
        -- 提取匹配内容预览（最多显示200字符）
        local preview = file_content:sub(s_pos, math.min(s_pos + 199, e_pos))
        preview = preview:gsub("\n", "\\n")
        if #preview >= 200 then
          preview = preview .. "..."
        end
        table.insert(matches, {
          start_line = start_ln,
          end_line = end_ln,
          preview = preview,
        })
        search_start = e_pos + 1
      end

      if #matches > 0 then
        local match_lines = {}
        for _, m in ipairs(matches) do
          table.insert(match_lines, string.format("  行 %d-%d: %s", m.start_line, m.end_line, m.preview))
        end
        local err_msg = string.format(
          "⚠️ 安全拦截：检测到多行模式匹配了 %d 处内容，可能导致意外删除大量行！\n"
            .. "匹配位置：\n%s\n\n"
            .. "建议：\n"
            .. "  1) 使用 start_line/end_line 限定替换范围（推荐）\n"
            .. "  2) 或设置 allow_multi_line = true 跳过此检查\n"
            .. "  3) 或设置 dry_run = true 仅预览匹配结果",
          #matches,
          table.concat(match_lines, "\n")
        )
        if on_error then
          on_error(err_msg)
        end
        return
      end
    end
  end

  -- dry_run 模式：仅预览匹配结果，不执行替换
  if dry_run then
    local matches = {}
    local search_start = 1
    while true do
      local s_pos, e_pos = file_content:find(pattern, search_start)
      if not s_pos then
        break
      end
      local start_ln = 1
      for i = 1, s_pos - 1 do
        if file_content:sub(i, i) == "\n" then
          start_ln = start_ln + 1
        end
      end
      local end_ln = start_ln
      for i = s_pos, e_pos - 1 do
        if file_content:sub(i, i) == "\n" then
          end_ln = end_ln + 1
        end
      end
      local preview = file_content:sub(s_pos, math.min(s_pos + 199, e_pos))
      preview = preview:gsub("\n", "\\n")
      if #preview >= 200 then
        preview = preview .. "..."
      end
      table.insert(matches, {
        start_line = start_ln,
        end_line = end_ln,
        preview = preview,
      })
      search_start = e_pos + 1
    end

    if on_success then
      on_success({
        filepath = filepath,
        success = true,
        dry_run = true,
        match_count = #matches,
        matches = matches,
        notice = string.format("dry_run 模式：共找到 %d 处匹配，未修改文件", #matches),
      })
    end
    return
  end

  if start_line or end_line then
    -- 先剥掉末尾换行再 split，避免末尾空串干扰；最后统一加回
    local has_trailing_nl = file_content:sub(-1) == "\n"
    local content = has_trailing_nl and file_content:sub(1, -2) or file_content
    local lines = vim.split(content, "\n", { plain = true })
    local total_lines = #lines

    local s = start_line or 1
    local e = end_line or total_lines

    -- 校验范围
    if s < 1 then
      s = 1
    end
    if e > total_lines then
      e = total_lines
    end
    if s > e then
      if on_error then
        on_error(string.format("起始行(%d)不能大于结束行(%d)", s, e))
      end
      return
    end

    -- 切成三部分：头 / 中间 / 尾
    local head = s > 1 and table.concat(lines, "\n", 1, s - 1) or nil
    local middle = table.concat(lines, "\n", s, e)
    local tail = e < total_lines and table.concat(lines, "\n", e + 1, total_lines) or nil

    -- 只对中间部分进行替换
    local replaced_middle, replace_count = middle:gsub(pattern, replacement)

    if replace_count == 0 then
      if on_success then
        on_success({
          filepath = filepath,
          success = true,
          replace_count = 0,
          start_line = s,
          end_line = e,
          notice = string.format("在 %d-%d 行范围内未找到匹配的内容，文件未做修改", s, e),
        })
      end
      return
    end

    -- 头 + 替换后的中间 + 尾 → 拼接
    local parts = {}
    if head then
      table.insert(parts, head)
    end
    table.insert(parts, replaced_middle)
    if tail then
      table.insert(parts, tail)
    end
    local new_content = table.concat(parts, "\n")
    if has_trailing_nl then
      new_content = new_content .. "\n"
    end

    local success, write_err = fu.write_file(filepath, new_content, false)
    if success == true then
      if on_success then
        on_success({
          filepath = filepath,
          success = true,
          replace_count = replace_count,
          start_line = s,
          end_line = e,
        })
      end
    else
      if on_error then
        on_error(string.format("写入文件失败 %s: %s", filepath, write_err or "写入失败"))
      end
    end
  else
    -- 全文替换
    local new_content, replace_count = file_content:gsub(pattern, replacement)

    if replace_count == 0 then
      if on_success then
        on_success({
          filepath = filepath,
          success = true,
          replace_count = 0,
          notice = "未找到匹配的内容，文件未做修改",
        })
      end
      return
    end

    local success, write_err = fu.write_file(filepath, new_content, false)
    if success == true then
      if on_success then
        on_success({
          filepath = filepath,
          success = true,
          replace_count = replace_count,
        })
      end
    else
      if on_error then
        on_error(string.format("写入文件失败 %s: %s", filepath, write_err or "写入失败"))
      end
    end
  end
end

M.replace_text = {
  name = "replace_text",
  description = "使用正则表达式在文件中查找并替换文本。应优先选择这个工具来编辑文件内容，它比逐行编辑更高效、更精确。支持正则模式，可通过 pattern 参数指定匹配模式，replacement 参数指定替换文本。可通过可选的 start_line 和 end_line 参数限定替换的行范围（从1开始计数，含首尾行），不指定则替换整个文件。\n\n安全特性：\n- 当匹配模式包含换行符（\\n）且未指定 start_line/end_line 时，自动阻止执行并列出所有匹配位置\n- 可通过 allow_multi_line=true 跳过此安全检查\n- 可通过 dry_run=true 仅预览匹配结果而不实际修改文件",
  func = _replace_text,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径（必填）" },
      pattern = {
        type = "string",
        description = "匹配的正则表达式（必填，正则表达式的关键字需要添加转义）",
      },
      replacement = {
        type = "string",
        description = "替换的文本（必填），支持正则捕获引用如 %1, %2 等",
      },
      start_line = { type = "number", description = "搜索起始行号（可选，从1开始，含该行）" },
      end_line = {
        type = "number",
        description = "搜索结束行号（可选，从1开始，含该行，需 >= start_line）",
      },
      dry_run = {
        type = "boolean",
        description = "预览模式（可选）：仅查找匹配位置并返回，不实际修改文件",
      },
      allow_multi_line = {
        type = "boolean",
        description = "安全开关（可选）：设为 true 可跳过多行匹配的安全检查，允许跨行替换而不限定行范围",
      },
    },
    required = { "filepath", "pattern", "replacement" },
  },
  returns = {
    type = "object",
    properties = {
      filepath = { type = "string" },
      success = { type = "boolean" },
      replace_count = { type = "number", description = "实际替换的次数" },
      start_line = { type = "number", description = "搜索起始行号（指定行范围时返回）" },
      end_line = { type = "number", description = "搜索结束行号（指定行范围时返回）" },
      notice = { type = "string", description = "提示信息（如无匹配时）" },
      dry_run = { type = "boolean", description = "是否为预览模式" },
      match_count = { type = "number", description = "dry_run 模式下匹配的总数" },
      matches = {
        type = "array",
        description = "dry_run 模式下的匹配详情列表",
        items = {
          type = "object",
          properties = {
            start_line = { type = "number" },
            end_line = { type = "number" },
            preview = { type = "string" },
          },
        },
      },
    },
    description = "替换结果，包含文件路径、是否成功、替换次数等信息",
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

  if not fu.exists(filepath) then
    if on_error then
      on_error(string.format("文件不存在: %s", filepath))
    end
    return
  end

  -- 使用 uv.fs_unlink 异步删除，避免 os.remove 在文件锁/NFS 上阻塞
  local uv = vim.uv or vim.loop
  local ok, err = nil, nil
  local deleted = false
  local timer = uv.new_timer()
  if timer then
    timer:start(
      10000,
      0,
      vim.schedule_wrap(function()
        if not deleted then
          ok = nil
          err = "删除超时（文件可能被锁定或无权限）"
          if on_error then
            on_error(string.format("删除文件失败 %s: %s", filepath, err))
          end
        end
      end)
    )
  end
  uv.fs_unlink(filepath, function(unlink_err)
    deleted = true
    if timer then
      timer:stop()
      timer:close()
    end
    if unlink_err then
      if on_error then
        on_error(string.format("删除文件失败 %s: %s", filepath, tostring(unlink_err)))
      end
    else
      if on_success then
        on_success({ filepath = filepath, success = true })
      end
    end
  end)
end

M.delete_file = {
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
