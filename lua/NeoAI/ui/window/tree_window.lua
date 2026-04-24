--- 树窗口
--- 职责：静态渲染、格式化树结构显示

local M = {}
local window_manager = require("NeoAI.ui.window.window_manager")
local async_worker = require("NeoAI.utils.async_worker")

local state = {
  initialized = false,
  config = nil,
  current_window_id = nil,
  current_session_id = nil,
  tree_data = {},       -- 从 history_manager.get_tree() 获取的树结构（已包含虚拟节点）
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

--- 从扁平列表重建树结构
--- 使用 list_sessions() 获取所有会话，再通过 get_session() 获取 child_ids 重建父子关系
local function rebuild_tree_from_list()
  local ok, hm = pcall(require, "NeoAI.core.history_manager")
  if not ok or not hm.is_initialized() then
    return {}
  end

  local sessions = hm.list_sessions() or {}
  if #sessions == 0 then
    return {}
  end

  -- 第一步：构建 id -> session 映射，并获取完整会话对象
  local session_map = {}
  for _, s in ipairs(sessions) do
    local full = hm.get_session(s.id)
    if full then
      session_map[s.id] = full
    end
  end

  -- 第二步：构建轮次预览文本
  local function build_round_text(session)
    if not session then return "" end
    local text = ""
    if session.user and session.user ~= "" then
      local user_preview = session.user:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
      if #user_preview > 20 then
        user_preview = user_preview:sub(1, 20) .. "…"
      end
      text = "👤" .. user_preview
    end
    if session.assistant and (
      (type(session.assistant) == "table" and #session.assistant > 0)
      or (type(session.assistant) == "string" and session.assistant ~= "")
    ) then
      local ai_text = ""
      local last_entry = session.assistant
      if type(session.assistant) == "table" and #session.assistant > 0 then
        last_entry = session.assistant[#session.assistant]
      end
      local ok2, parsed = pcall(vim.json.decode, last_entry)
      if ok2 and type(parsed) == "table" and parsed.content then
        ai_text = parsed.content
      elseif type(last_entry) == "string" then
        ai_text = last_entry
      end
      local ai_preview = ai_text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
      if #ai_preview > 20 then
        ai_preview = ai_preview:sub(1, 20) .. "…"
      end
      if text ~= "" then
        text = text .. " | 🤖" .. ai_preview
      else
        text = "🤖" .. ai_preview
      end
    end
    return text
  end

  -- 第三步：递归构建树节点
  local function build_node(session)
    if not session then return nil end
    local round_text = build_round_text(session)
    local node = {
      id = session.id,
      session_id = session.id,
      name = session.name or "未命名",
      round_text = round_text,
      children = {},
    }
    for _, cid in ipairs(session.child_ids or {}) do
      local child = session_map[cid]
      if child then
        local child_node = build_node(child)
        if child_node then
          table.insert(node.children, child_node)
        end
      end
    end
    return node
  end

  -- 第四步：只取根会话构建树
  local tree = {}
  for _, s in ipairs(sessions) do
    if s.is_root then
      local full = session_map[s.id]
      if full then
        local node = build_node(full)
        if node then
          table.insert(tree, node)
        end
      end
    end
  end

  return tree
end

--- 获取 history_manager 的树结构
local function load_tree()
  local ok, hm = pcall(require, "NeoAI.core.history_manager")
  if not ok or not hm.is_initialized() then
    return {}
  end
  -- 改为使用 list_sessions 重建树
  return rebuild_tree_from_list()
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
    pattern = "NeoAI:window_opening",
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
    pattern = "NeoAI:window_opened",
    data = { window_id = window_id },
  })

  -- 异步加载并渲染
  M._load_and_render_async(function()
    M.set_keymaps()
    M._update_float_window()
  end)

  vim.api.nvim_exec_autocmds("User", {
    pattern = "NeoAI:tree_window_opened",
    data = { window_id = window_id },
  })

  return true
end

--- 异步加载树数据
function M._load_and_render_async(callback)
  async_worker.submit_task("load_tree_data", function()
    return load_tree()
  end, function(success, tree)
    if success and tree then
      state.tree_data = tree
    else
      state.tree_data = {}
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

  -- 禁用光标监听
  if state.cursor_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.cursor_augroup)
    state.cursor_augroup = nil
  end
  _rendering = true

  local ok, err = pcall(function()
    vim.api.nvim_exec_autocmds("User", {
      pattern = "NeoAI:tree_rendering_start",
      data = { window_id = state.current_window_id },
    })

    local content = M._build_display_content()

    window_manager.set_window_content(state.current_window_id, content)

    -- 恢复选中光标位置
    if state.selected_session_id then
      local win_handle = window_manager.get_window_win(state.current_window_id)
      if win_handle and vim.api.nvim_win_is_valid(win_handle) then
        local line_map = M._build_line_to_session_map()
        for line, sid in pairs(line_map) do
          if sid == state.selected_session_id then
            local cursor_line = line + 2
            vim.api.nvim_win_set_cursor(win_handle, { cursor_line + 1, 0 })
            break
          end
        end
      end
    end

    vim.api.nvim_exec_autocmds("User", {
      pattern = "NeoAI:rendering_complete",
      data = { window_id = state.current_window_id },
    })
    vim.api.nvim_exec_autocmds("User", {
      pattern = "NeoAI:tree_rendering_complete",
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

--- 将原始会话树转换为带虚拟节点的显示树
--- 规则：
--- 1. 根会话 → 虚拟文件夹节点（📂 会话名），包含该会话的所有轮次和子会话
--- 2. 子会话的轮次直接扁平化到文件夹下（不创建中间会话节点）
--- 3. 只有当一个子会话有多个子会话（分支）时，才创建分支节点
local function build_display_tree(raw_tree)
  local display_tree = {}

  -- 收集一个会话节点及其所有后代的轮次
  local function collect_all_rounds(session_node)
    local rounds = {}
    if session_node.round_text and session_node.round_text ~= "" then
      table.insert(rounds, {
        id = session_node.id .. "_round",
        session_id = session_node.session_id,
        name = session_node.round_text,
        is_round = true,
        children = {},
      })
    end
    for _, child in ipairs(session_node.children or {}) do
      local child_rounds = collect_all_rounds(child)
      for _, r in ipairs(child_rounds) do
        table.insert(rounds, r)
      end
    end
    return rounds
  end

  local function flatten_rounds(session_node, collected)
    -- 收集当前会话的轮次
    if session_node.round_text and session_node.round_text ~= "" then
      table.insert(collected, {
        id = session_node.id .. "_round",
        session_id = session_node.session_id,
        name = session_node.round_text,
        is_round = true,
        children = {},
      })
    end
    -- 递归处理子会话
    local child_ids = session_node.children or {}
    if #child_ids == 1 then
      -- 只有一个子会话：检查它是否有子会话
      local only_child = child_ids[1]
      if #(only_child.children or {}) > 0 then
        -- 子会话有子会话：创建分支节点
        local branch_rounds = collect_all_rounds(only_child)
        if #branch_rounds > 0 then
          table.insert(collected, {
            id = "__branch_" .. only_child.id,
            name = "分支",
            is_virtual = true,
            round_count = #branch_rounds,
            children = branch_rounds,
          })
        end
      else
        -- 子会话没有子会话：链式扁平化
        flatten_rounds(only_child, collected)
      end
    elseif #child_ids > 1 then
      -- 多个子会话：分别处理每个子会话
      for _, child in ipairs(child_ids) do
        if #(child.children or {}) > 0 then
          -- 该子会话有子会话：创建分支节点
          local branch_rounds = collect_all_rounds(child)
          if #branch_rounds > 0 then
            table.insert(collected, {
              id = "__branch_" .. child.id,
              name = "分支",
              is_virtual = true,
              round_count = #branch_rounds,
              children = branch_rounds,
            })
          end
        else
          -- 该子会话没有子会话：直接收集轮次（扁平化）
          flatten_rounds(child, collected)
        end
      end
    end
  end

  for _, root in ipairs(raw_tree) do
    local root_children = {}
    flatten_rounds(root, root_children)
    if #root_children > 0 then
      table.insert(display_tree, {
        id = "__folder_" .. root.id,
        session_id = root.session_id,
        name = root.name,
        is_virtual = true,
        round_count = #root_children,
        children = root_children,
      })
    end
  end

  return display_tree
end

--- 构建显示内容
function M._build_display_content()
  local content = {}
  table.insert(content, "=== NeoAI 会话树 ===")
  table.insert(content, "")

  -- 将原始树转换为带虚拟节点的显示树
  local display_tree = build_display_tree(state.tree_data)

  if #display_tree == 0 then
    table.insert(content, "暂无会话")
    table.insert(content, "按 N 创建新会话")
  else
    local function render_node(node, depth, is_last, prefix)
      local line_prefix = prefix or ""
      local icon = ""
      local name = node.name or "未命名"

      if node.is_virtual then
        icon = "📂 "
        if node.round_count and node.round_count > 0 then
          name = name .. "  (" .. node.round_count .. "轮)"
        end
      elseif node.is_round then
        -- 轮次节点，直接显示预览文本
      end

      local connector = is_last and "└──" or "├──"
      if depth == 0 then
        table.insert(content, connector .. icon .. name)
      else
        table.insert(content, line_prefix .. connector .. icon .. name)
      end

      if node.children and #node.children > 0 then
        for i, child in ipairs(node.children) do
          local child_prefix
          if node.is_virtual and depth > 0 then
            -- 非根虚拟节点（分支）的子节点：始终显示垂直线
            child_prefix = line_prefix .. "│   "
          elseif depth == 0 then
            child_prefix = is_last and "    " or "│   "
          else
            child_prefix = line_prefix .. (is_last and "    " or "│   ")
          end
          render_node(child, depth + 1, i == #node.children, child_prefix)
        end
      end
    end

    for i, root in ipairs(display_tree) do
      render_node(root, 0, i == #display_tree, "")
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
  local line = 0

  local function traverse(node)
    if node.session_id then
      map[line] = node.session_id
    end
    line = line + 1
    if node.children then
      for _, child in ipairs(node.children) do
        traverse(child)
      end
    end
  end

  local display_tree = build_display_tree(state.tree_data)
  for _, root in ipairs(display_tree) do
    traverse(root)
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
  local tree_config = (state.config.keymaps or {}).tree or {}
  local keymaps = {
    up = "k",
    down = "j",
    left = "h",
    right = "l",
    select = (tree_config.select or {}).key or "<CR>",
    new_child = (tree_config.new_child or {}).key or "n",
    new_root = (tree_config.new_root or {}).key or "N",
    delete = (tree_config.delete_dialog or {}).key or "d",
    delete_branch = (tree_config.delete_branch or {}).key or "D",
    quit = "q",
    refresh = "r",
  }

  local handlers = require("NeoAI.ui.handlers.tree_handlers")

  local mapping = {
    [keymaps.up] = function() M._move_selection("up") end,
    [keymaps.down] = function() M._move_selection("down") end,
    [keymaps.select] = function() handlers.handle_enter() end,
    [keymaps.new_child] = function() handlers.handle_n() end,
    [keymaps.new_root] = function() handlers.handle_N() end,
    [keymaps.delete] = function() handlers.handle_d() end,
    [keymaps.delete_branch] = function() handlers.handle_D() end,
    [keymaps.quit] = function() M.close() end,
    [keymaps.refresh] = function() M.refresh_tree() end,
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
    if line + 2 == cursor_line then
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
  local total_lines = 0
  for _ in pairs(line_map) do
    total_lines = total_lines + 1
  end
  if total_lines == 0 then
    return
  end

  -- 找到当前选中的行号
  local current_line = nil
  for line, sid in pairs(line_map) do
    if sid == state.selected_session_id then
      current_line = line
      break
    end
  end

  -- 构建有序行号列表
  local sorted_lines = {}
  for line, _ in pairs(line_map) do
    table.insert(sorted_lines, line)
  end
  table.sort(sorted_lines)

  local new_line
  if current_line == nil then
    new_line = sorted_lines[1]
  elseif direction == "up" then
    for i = #sorted_lines, 1, -1 do
      if sorted_lines[i] < current_line then
        new_line = sorted_lines[i]
        break
      end
    end
    if not new_line then
      new_line = sorted_lines[#sorted_lines] -- 循环到末尾
    end
  elseif direction == "down" then
    for i = 1, #sorted_lines do
      if sorted_lines[i] > current_line then
        new_line = sorted_lines[i]
        break
      end
    end
    if not new_line then
      new_line = sorted_lines[1] -- 循环到开头
    end
  end

  if new_line then
    state.selected_session_id = line_map[new_line]
    local win_handle = window_manager.get_window_win(state.current_window_id)
    if win_handle and vim.api.nvim_win_is_valid(win_handle) then
      local cursor_line = new_line + 2
      vim.api.nvim_win_set_cursor(win_handle, { cursor_line + 1, 0 })
    end
    M._update_float_window()
    local handlers = require("NeoAI.ui.handlers.tree_handlers")
    handlers.handle_cursor_moved()
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
    state.tree_data = {}
    state.selected_session_id = nil
    return
  end

  vim.api.nvim_exec_autocmds("User", {
    pattern = "NeoAI:window_closing",
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
  state.tree_data = {}
  state.selected_session_id = nil
  state.float_win_id = nil
  state.float_buf_id = nil

  vim.api.nvim_exec_autocmds("User", {
    pattern = "NeoAI:window_closed",
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
    local ok, hm = pcall(require, "NeoAI.core.history_manager")
    if ok and hm.is_initialized() then
      local session = hm.get_session(state.selected_session_id)
      if session then
        status_text = status_text .. (session.name or "无")
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

--- 获取树数据
function M.get_tree_data()
  return state.tree_data
end

return M
