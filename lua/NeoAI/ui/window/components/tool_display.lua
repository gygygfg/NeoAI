---@module "NeoAI.ui.window.components.tool_display"
--- 工具调用悬浮窗组件
--- 所有窗口创建/销毁均通过 window_manager 管理

local M = {}

local logger = require("NeoAI.utils.logger")
local window_manager = require("NeoAI.ui.window.window_manager")
local tool_pack = require("NeoAI.tools.tool_pack")

-- ========== 私有状态 ==========

local state = {
  initialized = false,
  config = nil,
  window_id = nil,
  preview_window_id = nil,
  active = false,
  buffer = "",
  results = {},
  folded_saved = false,
  packs = {},
  pack_order = {},
  substeps = {},
  _finished = false,
  _debounce_timer = nil,
  _last_buffer = "",
  -- 刷新调度标志：多个并发更新合并为一次刷新
  _refresh_pending = false,
  streaming_preview = {
    timer = nil,
    generation_id = nil,
    tools = {},
    window_shown = false,
    _pending_append = "",
    _last_buffer = "",
  },
}

-- ========== 辅助函数 ==========

local function buf_valid(buf) return buf and vim.api.nvim_buf_is_valid(buf) end
local function win_valid(win) return win and vim.api.nvim_win_is_valid(win) end

--- 格式化 table 为多行字符串
local function _format_table_for_fold(t, indent)
  indent = indent or ""
  if type(t) == "string" then
    if t:find("\n") then
      local lines = vim.split(t, "\n")
      local parts = {}
      for _, line in ipairs(lines) do
        table.insert(parts, indent .. "  " .. line)
      end
      return table.concat(parts, "\n")
    end
    return string.format("%q", t)
  end
  if type(t) ~= "table" then return tostring(t) end

  local count = 0
  for _ in pairs(t) do count = count + 1; if count > 500 then
    local ok, encoded = pcall(vim.json.encode, t)
    if ok then return encoded end; break end
  end

  local is_array = true
  local max_key = 0
  for k, _ in pairs(t) do
    if type(k) ~= "number" or k <= 0 or math.floor(k) ~= k then is_array = false; break end
    if k > max_key then max_key = k end
  end
  if is_array and max_key == #t then
    local parts = { "{" }
    for i, v in ipairs(t) do
      table.insert(parts, indent .. "  " .. _format_table_for_fold(v, indent .. "  ") .. ",")
    end
    table.insert(parts, indent .. "}")
    return table.concat(parts, "\n")
  else
    local parts = { "{" }
    local keys = {}
    for k, _ in pairs(t) do table.insert(keys, k) end
    table.sort(keys, function(a, b)
      if type(a) == type(b) then return tostring(a) < tostring(b) end
      return type(a) < type(b)
    end)
    for _, k in ipairs(keys) do
      local v = t[k]
      local key_str = type(k) == "string" and k or "[" .. tostring(k) .. "]"
      table.insert(parts, indent .. "  " .. key_str .. " = " .. _format_table_for_fold(v, indent .. "  ") .. ",")
    end
    table.insert(parts, indent .. "}")
    return table.concat(parts, "\n")
  end
end

--- 截断过长的内容
local function _truncate_content_for_fold(content, max_lines)
  max_lines = max_lines or 200
  if not content or content == "" then return content or "" end
  local lines = vim.split(content, "\n")
  if #lines <= max_lines then return content end
  local truncated = {}
  for i = 1, max_lines do table.insert(truncated, lines[i]) end
  table.insert(truncated, string.format("... [已截断，剩余 %d 行未显示]", #lines - max_lines))
  return table.concat(truncated, "\n")
end

--- JSON 转义字符渲染
local function escape_json_for_display(str)
  str = str:gsub("\\n", "\n")
  str = str:gsub("\\t", "\t")
  str = str:gsub("\\\\", "\\")
  str = str:gsub('\\"', '"')
  return str
end

-- ========== 初始化 ==========

function M.initialize(config)
  if state.initialized then return end
  state.config = config or {}
  state.initialized = true
end

-- ========== 工具包分组管理 ==========

function M.get_packs() return state.packs end
function M.get_pack_order() return state.pack_order end
function M.get_substeps() return state.substeps end
function M.get_results() return state.results end
function M.is_folded_saved() return state.folded_saved end
function M.is_finished() return state._finished end
function M.set_finished(v) state._finished = v end
function M.set_folded_saved(v) state.folded_saved = v end
function M.is_active() return state.active end
function M.get_window_id() return state.window_id end
function M.get_preview_window_id() return state.preview_window_id end

--- 重置状态
function M.reset()
  state.active = false
  state.buffer = ""
  state.results = {}
  state.folded_saved = false
  state.substeps = {}
  state._last_buffer = ""
  state.packs = {}
  state.pack_order = {}

  if state._debounce_timer then
    state._debounce_timer:stop()
    state._debounce_timer:close()
    state._debounce_timer = nil
  end
  state._refresh_pending = false

  M._close_display()
  M._close_preview()

  local preview = state.streaming_preview
  if preview.timer then
    preview.timer:stop()
    preview.timer:close()
    preview.timer = nil
  end
  preview.generation_id = nil
  preview.tools = {}
  preview.window_shown = false
end

--- 初始化工具包分组
function M.init_packs(tool_calls, pack_order)
  -- 清理上一轮残留状态
  if state._debounce_timer then
    state._debounce_timer:stop()
    state._debounce_timer:close()
    state._debounce_timer = nil
  end
  state._refresh_pending = false

  state.active = true
  state.buffer = ""
  state.results = {}
  state._finished = false
  state.folded_saved = false
  state.packs = {}
  state.pack_order = {}
  state.substeps = {}

  local grouped = tool_pack.group_by_pack(tool_calls)
  local order = pack_order or {}

  for _, pack_name in ipairs(order) do
    local pack_tools = grouped[pack_name]
    if pack_tools then
      local tools_info = {}
      for _, tc in ipairs(pack_tools) do
        local fn = tc["function"] or tc.func or {}
        local args_display = {}
        if fn.arguments then
          if type(fn.arguments) == "string" then
            local ok, parsed = pcall(vim.json.decode, fn.arguments)
            args_display = (ok and type(parsed) == "table") and parsed or { raw = fn.arguments }
          elseif type(fn.arguments) == "table" then
            args_display = fn.arguments
          end
        end
        table.insert(tools_info, {
          name = fn.name or "unknown",
          status = "pending",
          duration = 0,
          args = args_display,
        })
      end
      state.packs[pack_name] = { tools = tools_info, order = tool_pack.get_pack_order(pack_name) }
      table.insert(state.pack_order, pack_name)
    end
  end

  -- 未分类工具
  local uncategorized = grouped["_uncategorized"]
  if uncategorized then
    local tools_info = {}
    for _, tc in ipairs(uncategorized) do
      local fn = tc["function"] or tc.func or {}
      local args_display = {}
      if fn.arguments then
        if type(fn.arguments) == "string" then
          local ok, parsed = pcall(vim.json.decode, fn.arguments)
          args_display = (ok and type(parsed) == "table") and parsed or { raw = fn.arguments }
        elseif type(fn.arguments) == "table" then
          args_display = fn.arguments
        end
      end
      table.insert(tools_info, { name = fn.name or "unknown", status = "pending", duration = 0, args = args_display })
    end
    state.packs["_uncategorized"] = { tools = tools_info, order = 99 }
    table.insert(state.pack_order, "_uncategorized")
  end

  M._rebuild_buffer()
end

-- ========== 刷新机制（简单可靠） ==========

--- 调度一次刷新（多个并发更新合并为一次）
local function _schedule_refresh()
  if state._refresh_pending then return end
  state._refresh_pending = true
  vim.schedule(function()
    state._refresh_pending = false
    if not state.active then return end
    M._rebuild_buffer()
    M._sync_display()
    -- 检查是否所有工具都已完成，立即关闭
    if M._all_tools_done() and state.window_id then
      M._close_display()
    end
  end)
end

--- 更新工具状态（立即更新状态，调度一次刷新）
function M.update_tool_status(pack_name, tool_name, status, duration)
  local pack = state.packs[pack_name]
  if not pack then return end
  for _, t in ipairs(pack.tools) do
    if t.name == tool_name then
      t.status = status
      t.duration = duration
      break
    end
  end
  _schedule_refresh()
end

--- 添加工具结果
function M.add_result(result)
  table.insert(state.results, result)
end

--- 更新子步骤（立即更新状态，调度一次刷新）
function M.update_substep(tool_name, substep_name, status, duration, detail)
  if not state.substeps[tool_name] then state.substeps[tool_name] = {} end
  local found = false
  for _, s in ipairs(state.substeps[tool_name]) do
    if s.name == substep_name then
      s.status = status; s.duration = duration; s.detail = detail; found = true; break
    end
  end
  if not found then
    table.insert(state.substeps[tool_name], { name = substep_name, status = status, duration = duration, detail = detail })
  end
  _schedule_refresh()
end

-- ========== 悬浮窗管理（通过 window_manager） ==========

--- 显示工具调用悬浮窗
function M.show_display()
  if state.window_id then return end
  local content = state.buffer
  if content == "" then content = "🔧 工具调用中...\n" end
  local content_lines = vim.split(content, "\n")
  local max_height = math.max(5, math.floor(vim.o.lines / 2))
  local dynamic_height = math.max(5, math.min(#content_lines + 2, max_height))
  local total_cols = vim.o.columns
  local tool_width = math.max(30, math.floor(total_cols * 0.8))
  local tool_col = math.floor((total_cols - tool_width) / 2)
  local tool_row = 1

  -- 检查 reasoning_display 是否可见，在它下方堆叠
  local ok_rd, rd = pcall(require, "NeoAI.ui.window.components.reasoning_display")
  if ok_rd and rd.is_visible and rd.is_visible() then
    local rwid = rd.get_window_id and rd.get_window_id()
    if rwid then
      local rwin = window_manager.get_window_win(rwid)
      if rwin and win_valid(rwin) then
        local rc = vim.api.nvim_win_get_config(rwin)
        tool_row = (rc.row or 1) + (rc.height or 5) + 1
      end
    end
  end

  local tool_border = {
    { "╭", "FloatBorder" }, { "─", "FloatBorder" }, { "┬", "FloatBorder" },
    { "│", "FloatBorder" }, { "┴", "FloatBorder" }, { "─", "FloatBorder" },
    { "╰", "FloatBorder" }, { "│", "FloatBorder" },
  }

  state.window_id = window_manager.create_window("tool_display", {
    title = "🔧 工具调用",
    width = tool_width, height = dynamic_height,
    border = tool_border, style = "minimal", relative = "editor",
    row = tool_row, col = tool_col, zindex = 100, window_mode = "float",
  })

  if not state.window_id then return end

  -- 写入内容
  local buf = window_manager.get_window_buf(state.window_id)
  if buf and buf_valid(buf) then
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, content_lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  end
  local win = window_manager.get_window_win(state.window_id)
  if win and win_valid(win) then
    vim.api.nvim_set_option_value("wrap", true, { win = win })
    if buf and buf_valid(buf) then
      local lc = vim.api.nvim_buf_line_count(buf)
      pcall(vim.api.nvim_win_set_cursor, win, { lc, 0 })
    end
  end

  -- 注册 WinScrolled 监听
  M._setup_scroll_listener()

  -- 触发事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = "NeoAI:tool_display_resized",
    data = { window_id = state.window_id, height = dynamic_height, row = tool_row, width = tool_width, col = 1 },
  })
end

--- 关闭工具调用悬浮窗
function M._close_display()
  if state.window_id then
    window_manager.close_window(state.window_id)
    state.window_id = nil
  end
  if state._debounce_timer then
    state._debounce_timer:stop()
    state._debounce_timer:close()
    state._debounce_timer = nil
  end
  state._refresh_pending = false
  vim.api.nvim_exec_autocmds("User", { pattern = "NeoAI:tool_display_closed", data = {} })
end

--- 直接同步写入 buffer 到悬浮窗
function M._sync_display()
  if not state.window_id then return end
  local buf = window_manager.get_window_buf(state.window_id)
  if not buf or not buf_valid(buf) then return end
  if state.buffer == state._last_buffer then return end
  state._last_buffer = state.buffer
  local lines = vim.split(state.buffer, "\n")
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  local win = window_manager.get_window_win(state.window_id)
  if win and win_valid(win) then
    local lc = vim.api.nvim_buf_line_count(buf)
    pcall(vim.api.nvim_win_set_cursor, win, { lc, 0 })
  end
end

--- 更新悬浮窗内容（兼容旧接口）
function M.update_display()
  M._sync_display()
end

--- 注册 WinScrolled 监听
function M._setup_scroll_listener()
  if not state.window_id then return end
  local buf = window_manager.get_window_buf(state.window_id)
  if not buf or not buf_valid(buf) then return end
  local win = window_manager.get_window_win(state.window_id)
  if not win or not win_valid(win) then return end

  local augroup_name = "NeoAI_tool_scroll_" .. state.window_id
  vim.api.nvim_create_augroup(augroup_name, { clear = true })
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = augroup_name, buffer = buf,
    callback = function()
      local cur_line = vim.api.nvim_win_get_cursor(win)[1]
      local line_count = vim.api.nvim_buf_line_count(buf)
      window_manager.set_tool_display_scroll(state.window_id, cur_line >= line_count)
    end,
  })
end

-- ========== 实时参数预览悬浮窗（通过 window_manager） ==========

--- 显示实时参数预览
function M.show_preview()
  if state.preview_window_id then return end
  local content = M._build_preview_buffer()
  local content_lines = vim.split(content, "\n")
  local max_height = math.max(5, math.floor(vim.o.lines / 2))
  local dynamic_height = math.max(5, math.min(#content_lines + 2, max_height))
  local total_cols = vim.o.columns
  local tool_width = math.max(30, math.floor(total_cols * 0.8))
  local tool_col = math.floor((total_cols - tool_width) / 2)
  local tool_row = 1

  local ok_rd, rd = pcall(require, "NeoAI.ui.window.components.reasoning_display")
  if ok_rd and rd.is_visible and rd.is_visible() then
    local rwid = rd.get_window_id and rd.get_window_id()
    if rwid then
      local rwin = window_manager.get_window_win(rwid)
      if rwin and win_valid(rwin) then
        local rc = vim.api.nvim_win_get_config(rwin)
        tool_row = (rc.row or 1) + (rc.height or 5) + 1
      end
    end
  end

  local tool_border = {
    { "╭", "FloatBorder" }, { "─", "FloatBorder" }, { "┬", "FloatBorder" },
    { "│", "FloatBorder" }, { "┴", "FloatBorder" }, { "─", "FloatBorder" },
    { "╰", "FloatBorder" }, { "│", "FloatBorder" },
  }

  state.preview_window_id = window_manager.create_window("tool_display", {
    title = "🔧 参数接收中...",
    width = tool_width, height = dynamic_height,
    border = tool_border, style = "minimal", relative = "editor",
    row = tool_row, col = tool_col, zindex = 100, window_mode = "float",
  })

  if not state.preview_window_id then return end

  local buf = window_manager.get_window_buf(state.preview_window_id)
  if buf and buf_valid(buf) then
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, content_lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  end
  local win = window_manager.get_window_win(state.preview_window_id)
  if win and win_valid(win) then
    vim.api.nvim_set_option_value("wrap", true, { win = win })
    if buf and buf_valid(buf) then
      local lc = vim.api.nvim_buf_line_count(buf)
      pcall(vim.api.nvim_win_set_cursor, win, { lc, 0 })
    end
  end
end

--- 关闭实时参数预览
function M._close_preview()
  if state.preview_window_id then
    window_manager.close_window(state.preview_window_id)
    state.preview_window_id = nil
  end
end

--- 追加预览内容
function M.append_preview(text)
  if not text or text == "" then return end
  if not state.preview_window_id then return end
  local buf = window_manager.get_window_buf(state.preview_window_id)
  if not buf or not buf_valid(buf) then return end

  local display_text = escape_json_for_display(text)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local last_line = vim.api.nvim_buf_get_lines(buf, line_count - 1, line_count, false)[1] or ""
  local parts = vim.split(display_text, "\n", { plain = true })

  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  local new_last_line = last_line .. parts[1]
  vim.api.nvim_buf_set_lines(buf, line_count - 1, line_count, false, { new_last_line })
  for i = 2, #parts do
    vim.api.nvim_buf_set_lines(buf, line_count + i - 2, line_count + i - 2, false, { parts[i] })
  end
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  local win = window_manager.get_window_win(state.preview_window_id)
  if win and win_valid(win) then
    local final_lc = vim.api.nvim_buf_line_count(buf)
    local final_last = vim.api.nvim_buf_get_lines(buf, final_lc - 1, final_lc, false)[1] or ""
    pcall(vim.api.nvim_win_set_cursor, win, { final_lc, #final_last })
  end
end

--- 构建预览 buffer
function M._build_preview_buffer()
  local preview = state.streaming_preview
  local tools = preview.tools or {}
  if not next(tools) then return "🔧 正在接收工具调用参数..." end
  local text = "🔧 工具调用（参数接收中...）"
  for _, t in pairs(tools) do
    text = text .. "\n\n  🔄 " .. t.name .. " (参数接收中...)"
    if t.arguments and t.arguments ~= "" then
      local display_args = escape_json_for_display(t.arguments)
      display_args = display_args:gsub("\n", "\n  ")
      text = text .. "\n  " .. display_args
    end
  end
  return text
end

--- 尝试解析流式参数
local function try_parse_streaming_args(tool_entry)
  local raw = tool_entry.arguments or ""
  if raw == "" then return end
  local ok, parsed = pcall(vim.json.decode, raw)
  if ok and type(parsed) == "table" then tool_entry.args_display = parsed end
end

--- 更新流式工具调用数据
function M.update_streaming_tools(tool_calls, tool_calls_delta, generation_id)
  local preview = state.streaming_preview
  if preview.generation_id and preview.generation_id ~= generation_id then
    if preview.timer then preview.timer:stop(); preview.timer:close(); preview.timer = nil end
    preview.tools = {}
    preview.window_shown = false
    preview._last_buffer = ""
    preview._pending_append = ""
  elseif not preview.generation_id then
    preview._last_buffer = ""
    preview._pending_append = ""
  end
  preview.generation_id = generation_id

  for _, tc in ipairs(tool_calls) do
    local func = tc["function"] or tc.func or {}
    local tool_name = func.name or ""
    if tool_name ~= "" then
      if not preview.tools[tool_name] then
        preview.tools[tool_name] = { name = tool_name, arguments = "", args_display = {} }
      end
      if func.arguments then
        local args_str = type(func.arguments) == "table" and vim.json.encode(func.arguments) or func.arguments
        preview.tools[tool_name].arguments = args_str
        try_parse_streaming_args(preview.tools[tool_name])
      end
    end
  end

  for _, tc in ipairs(tool_calls_delta) do
    local func = tc["function"] or tc.func or {}
    if func.arguments and type(func.arguments) == "string" and func.arguments ~= "" then
      preview._pending_append = preview._pending_append .. func.arguments
    end
  end
end

--- 触发预览更新（节流）
function M.schedule_preview_update()
  local preview = state.streaming_preview
  if preview._pending_append == "" or state.active or state._finished then return end

  if preview.timer then
    preview.timer:again(60)
  else
    preview.timer = vim.uv.new_timer()
    preview.timer:start(60, 0, vim.schedule_wrap(function()
      preview.timer:stop()
      preview.timer:close()
      preview.timer = nil
      local text = preview._pending_append
      preview._pending_append = ""
      if text == "" or state.active or state._finished then return end

      if not preview.window_shown then
        preview.window_shown = true
        M.show_preview()
      elseif state.preview_window_id then
        M.append_preview(text)
      end
    end))
  end
end

--- 清理流式预览
function M.clear_streaming_preview()
  local preview = state.streaming_preview
  if preview.timer then preview.timer:stop(); preview.timer:close(); preview.timer = nil end
  M._close_preview()
  preview.generation_id = nil
  preview.tools = {}
  preview.window_shown = false
  preview._pending_append = ""
end

-- ========== 内部方法 ==========

--- 重建显示 buffer
--- 已完成（completed/error）的工具行自动移除，只显示未完成或正在执行的工具
function M._rebuild_buffer()
  if M._all_tools_done() then
    state.buffer = ""
    return
  end

  local text = "🔧 工具调用中...\n"
  for _, pack_name in ipairs(state.pack_order) do
    local pack = state.packs[pack_name]
    if not pack then
      break
    end

    -- 检查该包是否有未完成的工具
    local has_active = false
    for _, t in ipairs(pack.tools) do
      if t.status ~= "completed" and t.status ~= "error" then
        has_active = true
        break
      end
    end
    if not has_active then
      goto continue_pack
    end

    local icon = tool_pack.get_pack_icon(pack_name)
    local display_name = tool_pack.get_pack_display_name(pack_name)
    text = text .. "\n" .. icon .. " " .. display_name .. "\n"
    for _, t in ipairs(pack.tools) do
      if t.status == "completed" or t.status == "error" then
        goto next_tool
      end

      local status_icon = "⏳"
      local status_text = "等待中"
      if t.status == "executing" then
        status_icon = "🔄"; status_text = "执行中..."
      elseif t.status == "completed" then
        status_icon = "✅"; status_text = string.format("(%.1fs)", t.duration or 0)
      elseif t.status == "error" then
        status_icon = "❌"; status_text = string.format("(失败, %.1fs)", t.duration or 0)
      end
      text = text .. "  " .. status_icon .. " " .. t.name .. " " .. status_text .. "\n"

      if t.args and type(t.args) == "table" and next(t.args) then
        for k, v in pairs(t.args) do
          if k ~= "_session_id" and k ~= "_tool_call_id" then
            local v_str = type(v) == "string" and v or vim.inspect(v)
            v_str = vim.uri_decode(v_str)
            if v_str:sub(1, 1) == "{" or v_str:sub(1, 1) == "[" then
              local ok, parsed = pcall(vim.json.decode, v_str)
              if ok and type(parsed) == "table" then
                v_str = vim.inspect(parsed, { indent = "", newline = "", separator = ", " })
              end
            end
            local max_width = math.floor(vim.o.columns * 0.8) - 8
            if #v_str > max_width then v_str = v_str:sub(1, max_width - 3) .. "..." end
            local first_line = v_str:match("([^\n]+)") or v_str
            text = text .. "    " .. k .. ": " .. first_line .. "\n"
          end
        end
      end

      local substeps = state.substeps[t.name]
      if substeps and #substeps > 0 then
        for i, s in ipairs(substeps) do
          local is_last = (i == #substeps)
          local prefix = is_last and "    └── " or "    ├── "
          local ss_icon = "⏳"; local ss_text = "等待中"
          if s.status == "executing" then
            ss_icon = "🔄"; ss_text = "执行中..."
          elseif s.status == "completed" then
            ss_icon = "✅"; ss_text = string.format("(%.1fs)", s.duration or 0)
          elseif s.status == "error" then
            ss_icon = "❌"; ss_text = string.format("(失败, %.1fs)", s.duration or 0)
          end
          text = text .. prefix .. ss_icon .. " " .. s.name .. " " .. ss_text .. "\n"
        end
      end
      ::next_tool::
    end
    ::continue_pack::
  end
  state.buffer = text
end

--- 构建折叠文本
function M.build_folded_text()
  local results = state.results or {}
  if #results == 0 then return "" end

  local pack_results = {}
  local pack_order = {}
  for _, r in ipairs(results) do
    local pn = r.pack_name or "_uncategorized"
    if not pack_results[pn] then pack_results[pn] = {}; table.insert(pack_order, pn) end
    table.insert(pack_results[pn], r)
  end
  table.sort(pack_order, function(a, b) return tool_pack.get_pack_order(a) < tool_pack.get_pack_order(b) end)

  local blocks = {}
  for _, pn in ipairs(pack_order) do
    local pack_tools = pack_results[pn]
    local pack_icon = tool_pack.get_pack_icon(pn)
    local pack_name = tool_pack.get_pack_display_name(pn)
    for _, r in ipairs(pack_tools) do
      local duration_str = r.duration and string.format(" (%.1fs)", r.duration) or ""
      local args_str = _format_table_for_fold(r.arguments or {})
      args_str = args_str:gsub("}}}", "} } }"):gsub("{{{", "{ { {")
      args_str = args_str:gsub("\n", "\n    ")
      local result_raw = r.result
      local result_str = ""
      if type(result_raw) == "table" then
        result_str = _format_table_for_fold(result_raw)
      else
        result_str = tostring(result_raw or "")
        local json_ok, json_val = pcall(vim.json.decode, result_str)
        if json_ok and type(json_val) == "table" then result_str = _format_table_for_fold(json_val) end
      end
      result_str = result_str:gsub("\\r\\n", "\n"):gsub("\\r", "\n")
      result_str = _truncate_content_for_fold(result_str, 200)
      local has_warning = false
      for line in result_str:gmatch("[^\n]+") do
        if line:match("^⚠️%s*警告：") then has_warning = true; break end
      end
      local icon = r.is_error and "❌" or (has_warning and "⚠️" or "✅")
      result_str = result_str:gsub("}}}", "} } }"):gsub("{{{", "{ { {")
      result_str = result_str:gsub("\n", "\n    ")

      local block = "{{{ " .. pack_icon .. " " .. pack_name .. " - " .. icon .. " " .. (r.tool_name or "unknown") .. duration_str
        .. "\n    参数: " .. args_str .. "\n    结果: " .. result_str .. "\n}}}"
      table.insert(blocks, block)
    end
  end
  return table.concat(blocks, "\n")
end

function M.get_buffer() return state.buffer end
function M.get_streaming_preview_tools() return state.streaming_preview.tools end
function M.get_streaming_preview_pending() return state.streaming_preview._pending_append end
function M.set_streaming_preview_pending(v) state.streaming_preview._pending_append = v end

--- 检查是否所有工具都已完成（completed 或 error）
function M._all_tools_done()
  for _, pack_name in ipairs(state.pack_order) do
    local pack = state.packs[pack_name]
    if pack then
      for _, t in ipairs(pack.tools) do
        if t.status ~= "completed" and t.status ~= "error" then
          return false
        end
      end
    end
  end
  return #state.pack_order > 0
end

--- 更新配置
function M.update_config(new_config)
  if not state.initialized then return end
  state.config = vim.tbl_extend("force", state.config, new_config or {})
end

return M
