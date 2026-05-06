--- 树窗口
--- 职责：直接渲染 history_tree 处理好的 flat_items 列表
--- flat_items 已包含：虚拟节点、is_last、缩进级别、连接符数组

local M = {}

local logger = require("NeoAI.utils.logger")
local Events = require("NeoAI.core.events")
local window_manager = require("NeoAI.ui.window.window_manager")
local async_worker = require("NeoAI.utils.async_worker")
local state_manager = require("NeoAI.core.config.state")

local state = {
  initialized = false,
  config = nil,
  current_window_id = nil,
  current_session_id = nil,
  flat_items = {}, -- 从 history_tree 获取的渲染列表
  selected_session_id = nil, -- 当前选中的真实会话ID
  cursor_augroup = nil,
  float_win_id = nil,
  float_buf_id = nil,
}

local _rendering = false

--- 初始化
function M.initialize(config)
  if state.initialized then
    return
  end
  state.config = config or {}
  state.initialized = true
end

--- 打开树窗口
function M.open(session_id, window_id)
  if not state.initialized then
    error("Tree window not initialized")
  end
  if not window_id or type(window_id) ~= "string" then
    error("window_id parameter is required and must be a string")
  end
  if not window_id:match("^win_") then
    error("Invalid window_id format. Must start with 'win_'")
  end

  if state.current_window_id then
    M.close()
  end

  state.current_window_id = window_id
  state.current_session_id = session_id
  state.selected_session_id = nil

  vim.api.nvim_exec_autocmds("User", {
    pattern = Events.WINDOW_OPENING,
    data = { window_id = window_id, window_type = "tree" },
  })

  local buf = window_manager.get_window_buf(window_id)
  local win_handle = window_manager.get_window_win(window_id)

  -- 应用折叠配置
  local tree_config = (state.config.ui or {}).tree or {}

  if buf then
    vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
    vim.api.nvim_set_option_value("foldmethod", tree_config.foldmethod or "manual", { win = win_handle })
    vim.api.nvim_set_option_value("foldcolumn", tree_config.foldcolumn or "0", { win = win_handle })
    vim.api.nvim_set_option_value("foldlevel", tree_config.foldlevel or 99, { win = win_handle })
  end
  if win_handle then
    vim.api.nvim_set_option_value("foldenable", tree_config.foldenable ~= false, { win = win_handle })
    vim.api.nvim_set_option_value("wrap", false, { win = win_handle })
    vim.api.nvim_set_option_value("linebreak", false, { win = win_handle })
    vim.api.nvim_set_option_value("cursorline", true, { win = win_handle })
  end

  vim.api.nvim_exec_autocmds("User", {
    pattern = Events.WINDOW_OPENED,
    data = { window_id = window_id },
  })

  -- 获取窗口的协程上下文（由 window_manager.create_window 创建）
  -- 后续所有协程内共享变量通过此上下文隔离
  local ctx = window_manager.get_window_context(window_id)

  -- 异步加载并渲染
  M._load_and_render_async(function()
    -- 在窗口的协程上下文中执行初始化操作
    local init_fn = function()
      M.set_keymaps()
      M._update_float_window()
      -- 渲染完成后将光标移动到第一个有效节点行
      M._move_cursor_to_first_node()
    end

    if ctx then
      state_manager.with_context(ctx, init_fn)
    else
      init_fn()
    end
  end)

  -- 监听会话重命名事件，自动刷新树
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.SESSION_RENAMED,
    callback = function()
      if state.current_window_id then
        M.refresh_tree()
      end
    end,
    desc = "会话重命名后刷新树",
  })

  vim.api.nvim_exec_autocmds("User", {
    pattern = Events.TREE_WINDOW_OPENED,
    data = { window_id = window_id },
  })

  return true
end

--- 对未命名的会话触发自动命名（已移至 history_manager，通过 config.auto_naming 控制）
local function _auto_name_unamed_sessions()
  -- 不再在此处触发自动命名，统一由 history_manager 的 add_round 处理
end

--- 异步加载树数据
function M._load_and_render_async(callback)
  async_worker.submit_task("load_tree_data", function()
    local history_tree = require("NeoAI.ui.components.history_tree")
    return history_tree.build_flat_items()
  end, function(success, items)
    if success and items then
      if type(items) == "string" then
        local ok, decoded = pcall(vim.json.decode, items)
        state.flat_items = ok and decoded or {}
      else
        state.flat_items = items
      end
    else
      state.flat_items = {}
    end
    M.render_tree()
    if callback then
      callback()
    end
  end)
end

--- 渲染树
function M.render_tree()
  if not state.current_window_id then
    return
  end

  -- 保存当前光标行号（1-based），用于渲染后恢复
  local saved_cursor_line = nil
  local win_handle = window_manager.get_window_win(state.current_window_id)
  if win_handle and vim.api.nvim_win_is_valid(win_handle) then
    saved_cursor_line = vim.api.nvim_win_get_cursor(win_handle)[1]
  end

  -- 禁用光标监听
  if state.cursor_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.cursor_augroup)
    state.cursor_augroup = nil
  end
  _rendering = true

  local ok, err = pcall(function()
    vim.api.nvim_exec_autocmds("User", {
      pattern = Events.TREE_RENDERING_START,
      data = { window_id = state.current_window_id },
    })

    local content = M._build_display_content()

    window_manager.set_window_content(state.current_window_id, content)

    -- 恢复光标行号（直接记忆行号，不依赖 session_id）
    if saved_cursor_line then
      local buf = window_manager.get_window_buf(state.current_window_id)
      if not buf then
        return
      end
      local line_count = vim.api.nvim_buf_line_count(buf)
      local target_line = math.min(saved_cursor_line, line_count)
      if target_line < 1 then
        target_line = 1
      end
      if win_handle and vim.api.nvim_win_is_valid(win_handle) then
        vim.api.nvim_win_set_cursor(win_handle, { target_line, 0 })
      end
    end

    -- 根据光标位置更新 selected_session_id
    M._update_selection_from_cursor()

    vim.api.nvim_exec_autocmds("User", {
      pattern = Events.RENDERING_COMPLETE,
      data = { window_id = state.current_window_id },
    })
    vim.api.nvim_exec_autocmds("User", {
      pattern = Events.TREE_RENDERING_COMPLETE,
      data = { window_id = state.current_window_id },
    })
  end)

  _rendering = false

  -- 恢复光标监听
  local buf = window_manager.get_window_buf(state.current_window_id)
  if buf then
    M._setup_cursor_listener(buf)
  end

  if not ok then
    print("渲染树出错: " .. tostring(err), vim.log.levels.ERROR)
  end
end

--- 构建显示内容
--- 根据 history_tree 的抽象节点数据做具体渲染
function M._build_display_content()
  local content = {}
  table.insert(content, "=== NeoAI 会话树 ===")
  table.insert(content, "")
  table.insert(content, "─────────────────────────────")
  table.insert(content, "")

  if #state.flat_items == 0 then
    table.insert(content, "暂无会话")
    table.insert(content, "按 N 创建新会话")
  else
    for idx, item in ipairs(state.flat_items) do
      local line = ""

      -- 1. 根据缩进级别生成连接线
      local indent = item.indent or 0
      -- 使用 connectors 数组的实际长度，确保祖先层级的连接符都能渲染
      -- 当 indent 为 0 时，不渲染任何连接符（顶级节点）
      local connector_count = item.connectors and #item.connectors or indent
      local loop_end = (indent == 0) and 0 or math.max(indent, connector_count)
      for i = 1, loop_end do
        if item.connectors and item.connectors[i] then
          line = line .. item.connectors[i]
        else
          line = line .. "   "
        end
      end

      -- 2. 虚拟节点：渲染为 "📂 聊天会话"
      if item.is_virtual then
        line = line .. "📂 聊天会话"
        table.insert(content, line)
      else
        -- 3. 根据 display_type 和 is_last_session 渲染前缀
        if item.display_type == "branch" then
          if item.is_last_session then
            line = line .. "└─ 📂 " .. item.display_text
          else
            line = line .. "├─ 📂 " .. item.display_text
          end
        else
          if item.is_last_session then
            line = line .. "└─ " .. item.display_text
          else
            line = line .. "├─ " .. item.display_text
          end
        end
        table.insert(content, line)
      end
    end
  end

  table.insert(content, "")
  table.insert(content, "---")
  table.insert(content, "使用方向键导航，Enter 选择，n/N 新建节点，d 删除")
  return content
end

--- 构建行号到真实会话ID的映射
function M._build_line_to_session_map()
  local map = {}
  for line, item in ipairs(state.flat_items) do
    if not item.is_virtual and item.session_id then
      -- line 是 flat_items 中的索引（1-based），content 中前面有标题行 + 空行 + 分隔线 + 空行 = 4行
      -- flat_items 第1行在 content 第5行（1-based），cursor_pos[1]=5 → cursor_line=4（0-based）
      -- 所以 key = line + 3，匹配时 4 == 4 ✅
      map[line + 3] = item.session_id
    end
  end
  return map
end

--- 刷新树
function M.refresh_tree()
  if not state.current_window_id then
    return
  end
  M._load_and_render_async(nil)
end

--- 设置按键映射
function M.set_keymaps(keymap_manager)
  if not state.current_window_id then
    return
  end
  local buf = window_manager.get_window_buf(state.current_window_id)
  if not buf then
    return
  end

  -- 清除现有映射
  local existing_maps = vim.api.nvim_buf_get_keymap(buf, "n")
  for _, map in ipairs(existing_maps) do
    vim.api.nvim_buf_del_keymap(buf, "n", map.lhs)
  end

  -- 从合并后的配置中获取 tree 上下文键位
  -- 所有键位统一由 default_config.lua 定义，模块内部不提供任何 fallback 默认值
  local tree_config = state.config.keymaps.tree
  local keymaps = {
    up = "k",
    down = "j",
    left = "h",
    right = "l",
    select = tree_config.select.key,
    new_child = tree_config.new_child.key,
    new_root = tree_config.new_root.key,
    delete = tree_config.delete_dialog.key,
    delete_branch = tree_config.delete_branch.key,
    quit = "q",
    refresh = "r",
  }

  local handlers = require("NeoAI.ui.handlers.tree_handlers")

  local mapping = {
    [keymaps.up] = function()
      M._move_selection("up")
    end,
    [keymaps.down] = function()
      M._move_selection("down")
    end,
    [keymaps.select] = function()
      handlers.handle_enter()
    end,
    [keymaps.new_child] = function()
      handlers.handle_n()
    end,
    [keymaps.new_root] = function()
      handlers.handle_N()
    end,
    [keymaps.delete] = function()
      handlers.handle_d()
    end,
    [keymaps.delete_branch] = function()
      handlers.handle_D()
    end,
    [keymaps.quit] = function()
      M.close()
    end,
    [keymaps.refresh] = function()
      M.refresh_tree()
    end,
  }

  for key, callback in pairs(mapping) do
    vim.keymap.set("n", key, callback, { buffer = buf, noremap = true, silent = true })
  end

  M._setup_cursor_listener(buf)
end

--- 设置光标移动监听
function M._setup_cursor_listener(buf)
  if state.cursor_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.cursor_augroup)
  end
  state.cursor_augroup = vim.api.nvim_create_augroup("NeoAITreeWindowCursor", { clear = true })

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = state.cursor_augroup,
    buffer = buf,
    callback = function()
      if _rendering then
        return
      end
      M._update_selection_from_cursor()
    end,
    desc = "更新树窗口选中状态",
  })

  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = state.cursor_augroup,
    buffer = buf,
    callback = function()
      M._update_float_window()
    end,
    desc = "更新树窗口悬浮窗口位置",
  })
end

--- 从光标位置更新选中状态
function M._update_selection_from_cursor()
  local win_handle = window_manager.get_window_win(state.current_window_id)
  if not win_handle or not vim.api.nvim_win_is_valid(win_handle) then
    return
  end
  local cursor_pos = vim.api.nvim_win_get_cursor(win_handle)
  local cursor_line = cursor_pos[1] - 1

  local line_map = M._build_line_to_session_map()
  for line, sid in pairs(line_map) do
    if line == cursor_line then
      if state.selected_session_id ~= sid then
        state.selected_session_id = sid
        M._update_float_window()
        -- 通知 handlers 更新悬浮文本
        local handlers = require("NeoAI.ui.handlers.tree_handlers")
        handlers.handle_cursor_moved()
      end
      return
    end
  end
  -- 光标不在任何节点上
  if state.selected_session_id then
    state.selected_session_id = nil
    M._update_float_window()
  end
end

--- 移动选中
function M._move_selection(direction)
  local line_map = M._build_line_to_session_map()
  local sorted = {}
  for line, _ in pairs(line_map) do table.insert(sorted, line) end
  table.sort(sorted)
  if #sorted == 0 then return end

  local current = nil
  for line, sid in pairs(line_map) do
    if sid == state.selected_session_id then current = line; break end
  end

  local new_line
  if not current then
    new_line = sorted[1]
  elseif direction == "up" then
    for i = #sorted, 1, -1 do
      if sorted[i] < current then new_line = sorted[i]; break end
    end
    new_line = new_line or sorted[#sorted]
  elseif direction == "down" then
    for i = 1, #sorted do
      if sorted[i] > current then new_line = sorted[i]; break end
    end
    new_line = new_line or sorted[1]
  end

  if new_line then
    state.selected_session_id = line_map[new_line]
    local win = window_manager.get_window_win(state.current_window_id)
    if win and vim.api.nvim_win_is_valid(win) then
      -- new_line 来自 _build_line_to_session_map，key = line + 3（1-based），需要加1得到 content 中的实际行号
      vim.api.nvim_win_set_cursor(win, { new_line + 1, 0 })
    end
    M._update_float_window()
    require("NeoAI.ui.handlers.tree_handlers").handle_cursor_moved()
  end
end

--- 获取当前选中的真实会话ID
function M.get_selected_session_id()
  return state.selected_session_id
end

--- 关闭树窗口
function M.close()
  if not state.current_window_id then
    return
  end
  local win_handle = window_manager.get_window_win(state.current_window_id)
  if not win_handle or not vim.api.nvim_win_is_valid(win_handle) then
    state.current_window_id = nil
    state.flat_items = {}
    state.selected_session_id = nil
    return
  end

  vim.api.nvim_exec_autocmds("User", {
    pattern = Events.WINDOW_CLOSING,
    data = { window_id = state.current_window_id },
  })

  window_manager.close_window(state.current_window_id)

  if state.cursor_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.cursor_augroup)
    state.cursor_augroup = nil
  end
  M._close_float_window()

  state.current_window_id = nil
  state.current_session_id = nil
  state.flat_items = {}
  state.selected_session_id = nil
  state.float_win_id = nil
  state.float_buf_id = nil

  vim.api.nvim_exec_autocmds("User", {
    pattern = Events.WINDOW_CLOSED,
    data = { window_id = state.current_window_id },
  })
end

--- 更新悬浮窗口
function M.update_float_window()
  M._update_float_window()
end

--- 创建/更新悬浮窗口
function M._update_float_window()
  if not state.current_window_id then
    return
  end
  local main_win_handle = window_manager.get_window_win(state.current_window_id)
  if not main_win_handle or not vim.api.nvim_win_is_valid(main_win_handle) then
    return
  end

  local status_text = "当前选中: "
  if state.selected_session_id then
    local ok, hm = pcall(require, "NeoAI.core.history.manager")
    if ok and hm.is_initialized() then
      local session = hm.get_session(state.selected_session_id)
      if session then
        -- 优先显示用户提问，提问为空时回退显示会话名称
        local display_text = session.user or ""
        if display_text == "" then
          display_text = (session.name and session.name ~= "") and session.name or "无"
        else
          -- 截断过长文本
          local one_line = display_text:gsub("\n", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
          if #one_line > 60 then
            one_line = one_line:sub(1, 60) .. "…"
          end
          display_text = one_line
        end
        status_text = status_text .. display_text
      else
        status_text = status_text .. "无"
      end
    else
      status_text = status_text .. state.selected_session_id
    end
  else
    status_text = status_text .. "无"
  end

  local main_win_info = vim.fn.getwininfo(main_win_handle)
  if not main_win_info or #main_win_info == 0 then
    return
  end
  local win_info = main_win_info[1]
  local main_width = win_info.width
  local float_width = math.min(#status_text + 4, main_width - 4)
  local float_height = 1
  local relative_col = main_width - float_width - 2
  local relative_row = 1

  -- 获取主窗口的 buffer 句柄
  local main_buf = window_manager.get_window_buf(state.current_window_id)

  if not state.float_win_id or not vim.api.nvim_win_is_valid(state.float_win_id) then
    state.float_buf_id = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("buflisted", false, { buf = state.float_buf_id })
    vim.api.nvim_set_option_value("modifiable", true, { buf = state.float_buf_id })
    vim.api.nvim_set_option_value("readonly", false, { buf = state.float_buf_id })

    -- 阻止 LSP 附加到树窗口的悬浮状态窗口
    local wm = require("NeoAI.ui.window.window_manager")
    wm.block_lsp_for_buffer(state.float_buf_id, "树窗口悬浮状态")

    state.float_win_id = vim.api.nvim_open_win(state.float_buf_id, false, {
      relative = "win",
      win = main_win_handle,
      width = float_width,
      height = float_height,
      col = relative_col,
      row = relative_row,
      style = "minimal",
      border = "single",
      focusable = false,
      zindex = 100,
    })

    vim.api.nvim_set_option_value("wrap", false, { win = state.float_win_id })
    vim.api.nvim_set_option_value("cursorline", false, { win = state.float_win_id })
    vim.api.nvim_set_option_value("number", false, { win = state.float_win_id })
    vim.api.nvim_set_option_value("signcolumn", "no", { win = state.float_win_id })

    -- 注册到 window_manager，以便切换 buffer 时自动隐藏/显示
    if main_buf then
      window_manager.register_float_window(main_buf, state.float_win_id, state.float_buf_id)
    end
  else
    vim.api.nvim_win_set_config(state.float_win_id, {
      relative = "win",
      win = main_win_handle,
      width = float_width,
      height = float_height,
      col = relative_col,
      row = relative_row,
    })
  end

  if state.float_buf_id and vim.api.nvim_buf_is_valid(state.float_buf_id) then
    vim.api.nvim_set_option_value("modifiable", true, { buf = state.float_buf_id })
    vim.api.nvim_set_option_value("readonly", false, { buf = state.float_buf_id })
    vim.api.nvim_buf_set_lines(state.float_buf_id, 0, -1, false, { status_text })
    vim.api.nvim_set_option_value("modifiable", false, { buf = state.float_buf_id })
    vim.api.nvim_set_option_value("readonly", true, { buf = state.float_buf_id })
    vim.api.nvim_set_option_value("modified", false, { buf = state.float_buf_id })
  end
end

--- 关闭悬浮窗口
function M._close_float_window()
  -- 从 window_manager 注销
  local main_buf = state.current_window_id and window_manager.get_window_buf(state.current_window_id)
  if main_buf then
    window_manager.unregister_float_window(main_buf)
  end
  if state.float_win_id and vim.api.nvim_win_is_valid(state.float_win_id) then
    vim.api.nvim_win_close(state.float_win_id, true)
    state.float_win_id = nil
  end
  if state.float_buf_id and vim.api.nvim_buf_is_valid(state.float_buf_id) then
    vim.api.nvim_buf_delete(state.float_buf_id, { force = true })
    state.float_buf_id = nil
  end
end

--- 检查是否打开
function M.is_open()
  if not state.initialized then
    return false
  end
  return state.current_window_id ~= nil
end

--- 更新配置
function M.update_config(new_config)
  if not state.initialized then
    return
  end
  state.config = vim.tbl_extend("force", state.config, new_config or {})
  if state.current_window_id then
    M.set_keymaps()
    M.render_tree()
  end
end

--- 刷新
function M.refresh()
  if not state.initialized or not state.current_window_id then
    return false
  end
  M.render_tree()
  return true
end

--- 将光标移动到第一个有效节点行
function M._move_cursor_to_first_node()
  if not state.current_window_id then
    return
  end
  local line_map = M._build_line_to_session_map()
  local sorted = {}
  for line, _ in pairs(line_map) do
    table.insert(sorted, line)
  end
  table.sort(sorted)
  if #sorted == 0 then
    return
  end
  local first_line = sorted[1]
  local win_handle = window_manager.get_window_win(state.current_window_id)
  if win_handle and vim.api.nvim_win_is_valid(win_handle) then
    -- first_line 来自 _build_line_to_session_map，key = line + 3（1-based），需要加1得到 content 中的实际行号
    vim.api.nvim_win_set_cursor(win_handle, { first_line + 1, 0 })
    state.selected_session_id = line_map[first_line]
    M._update_float_window()
    local handlers = require("NeoAI.ui.handlers.tree_handlers")
    handlers.handle_cursor_moved()
  end
end

--- 获取树数据
function M.get_tree_data()
  return state.flat_items
end

return M
