local M = {}
local MODULE_NAME = "NeoAI.ui.window.tree_window"
local window_manager = require("NeoAI.ui.window.window_manager")
local async_worker = require("NeoAI.utils.async_worker")

-- 模块状态
local state = {
  initialized = false,
  config = nil,
  current_window_id = nil,
  current_session_id = nil, -- 当前会话ID
  tree_data = {},
  selected_node_id = nil,
  expanded_nodes = {},
  cursor_augroup = nil, -- 光标移动自动命令组
  float_win_id = nil, -- 悬浮窗口ID
  float_buf_id = nil, -- 悬浮窗口缓冲区ID
}

-- 渲染中标志，防止 CursorMoved 事件触发递归
local _rendering = false
-- 待处理的异步渲染任务ID
local _pending_render_task = nil

--- 初始化树窗口
--- @param config table 配置
function M.initialize(config)
  if state.initialized then
    return
  end

  state.config = config or {}
  state.initialized = true
end

--- 打开树状图窗口
--- @param session_id string 会话ID
--- @param window_id string 窗口ID（必须由调用者通过 window_manager 创建）                                                                  --- @return boolean 是否成功
function M.open(session_id, window_id)
  if not state.initialized then
    error("Tree window not initialized")
  end

  -- 检查 window_id 参数
  if not window_id or type(window_id) ~= "string" then
    error("window_id parameter is required and must be a string")
  end

  -- 验证窗口ID格式
  if not window_id:match("^win_") then
    error("Invalid window_id format. Must start with 'win_'")
  end

  -- 如果已有窗口，先关闭
  if state.current_window_id then
    M.close()
  end

  state.current_window_id = window_id
  state.current_session_id = session_id
  state.selected_node_id = nil
  state.expanded_nodes = {}

  -- 触发窗口打开事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = "NeoAI:window_opening", data = { window_id = window_id, window_type = "tree" } }
  )

  -- 获取缓冲区和窗口句柄并设置选项
  local buf = window_manager.get_window_buf(window_id)
  local win_handle = window_manager.get_window_win(window_id)

  if buf then
    -- 设置缓冲区选项
    vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
  end

  if win_handle then
    -- 设置窗口选项（wrap 和 linebreak 都是窗口本地选项）
    -- 注意：为了确保截断生效，将 wrap 设置为 false
    vim.api.nvim_set_option_value("wrap", false, { win = win_handle })
    vim.api.nvim_set_option_value("linebreak", false, { win = win_handle })
    vim.api.nvim_set_option_value("cursorline", true, { win = win_handle })
  end

  -- 触发窗口打开事件
  vim.api.nvim_exec_autocmds("User", { pattern = "NeoAI:window_opened", data = { window_id = window_id } })

  -- 异步加载树数据并渲染
  M._load_tree_data_async(session_id, function()
    M.render_tree(state.tree_data)
  end)

  -- 设置按键映射
  M.set_keymaps()

  -- 初始化悬浮窗口
  M._update_float_window()

  -- 触发树窗口打开事件
  vim.api.nvim_exec_autocmds("User", { pattern = "NeoAI:tree_window_opened", data = { window_id = window_id } })

  return true
end

--- 渲染树状图
--- @param tree_data table 树数据
function M.render_tree(tree_data)
  if not state.current_window_id then
    print("调试：没有当前窗口ID", vim.log.levels.WARN)
    return
  end

  -- 临时禁用 CursorMoved 自动命令，防止渲染过程中触发事件链导致死循环
  local cursor_augroup_saved = state.cursor_augroup
  if cursor_augroup_saved then
    pcall(vim.api.nvim_del_augroup_by_id, cursor_augroup_saved)
    state.cursor_augroup = nil
  end

  -- 设置渲染中标志
  _rendering = true

  -- 用 pcall 保护渲染逻辑，确保即使出错也能恢复自动命令组
  local ok, err = pcall(function()
    -- 触发开始渲染树事件
    vim.api.nvim_exec_autocmds(
      "User",
      { pattern = "NeoAI:tree_rendering_start", data = { window_id = state.current_window_id } }
    )

    -- 获取窗口宽度
    local window_width = nil
    local win_handle = window_manager.get_window_win(state.current_window_id)
    if win_handle and vim.api.nvim_win_is_valid(win_handle) then
      local win_config = vim.api.nvim_win_get_config(win_handle)
      if win_config and win_config.width then
        window_width = win_config.width
        local number_width = vim.api.nvim_get_option_value("numberwidth", { win = win_handle })
        if number_width then
          window_width = window_width - number_width
        end
        local signcolumn = vim.api.nvim_get_option_value("signcolumn", { win = win_handle })
        if signcolumn and signcolumn ~= "no" then
          window_width = window_width - 2
        end
      end
    end

    -- 使用 window_manager 的通用渲染函数
    local content = window_manager.render_tree(tree_data, state, M._load_tree_data, window_width)

    -- 设置窗口内容
    window_manager.set_window_content(state.current_window_id, content)

    -- 高亮选中节点
    M._highlight_selected_node()

    -- 设置光标位置到选中的节点
    if state.selected_node_id then
      local cursor_win_handle = window_manager.get_window_win(state.current_window_id)
      if cursor_win_handle and vim.api.nvim_win_is_valid(cursor_win_handle) then
        local line_to_node = M._build_line_to_node_map()
        for line, node_id in pairs(line_to_node) do
          if node_id == state.selected_node_id then
            local cursor_line = line + 2
            vim.api.nvim_win_set_cursor(cursor_win_handle, { cursor_line + 1, 0 })
            break
          end
        end
      end
    end

    -- 触发渲染完成事件
    vim.api.nvim_exec_autocmds(
      "User",
      { pattern = "NeoAI:rendering_complete", data = { window_id = state.current_window_id } }
    )

    vim.api.nvim_exec_autocmds(
      "User",
      { pattern = "NeoAI:tree_rendering_complete", data = { window_id = state.current_window_id } }
    )
  end)

  -- 清除渲染中标志
  _rendering = false

  -- 恢复 CursorMoved 自动命令
  local buf = window_manager.get_window_buf(state.current_window_id)
  if buf then
    M._setup_cursor_listener(buf)
  end

  if not ok then
    print("渲染树出错: " .. tostring(err), vim.log.levels.ERROR)
  end
end

--- 刷新树状图
function M.refresh_tree()
  if not state.current_window_id then
    return
  end

  -- 异步重新加载数据并渲染
  M._load_tree_data_async(state.current_session_id, function()
    -- 渲染前验证选中的节点是否仍然存在于树中
    if state.selected_node_id then
      local function node_exists(nodes, target_id)
        for _, node in ipairs(nodes) do
          if node.id == target_id then return true end
          if node.children and #node.children > 0 then
            if node_exists(node.children, target_id) then return true end
          end
        end
        return false
      end
      if not node_exists(state.tree_data, state.selected_node_id) then
        state.selected_node_id = nil
      end
    end
    M.render_tree(state.tree_data)
  end)
end

--- 设置按键映射
--- @param keymap_manager table|nil 键位配置管理器
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

  -- 获取键位配置
  local keymaps = {}

  if keymap_manager then
    -- 从键位配置管理器获取
    local tree_keymaps = keymap_manager.get_context_keymaps("tree")
    if tree_keymaps then
      -- 映射到内部键位名称，使用配置的值或默认值
      keymaps = {
        up = tree_keymaps.up and tree_keymaps.up.key or "k",
        down = tree_keymaps.down and tree_keymaps.down.key or "j",
        left = tree_keymaps.left and tree_keymaps.left.key or "h",
        right = tree_keymaps.right and tree_keymaps.right.key or "l",
        select = tree_keymaps.select and tree_keymaps.select.key or "<CR>",
        new_child = tree_keymaps.new_child and tree_keymaps.new_child.key or "n",
        new_root = tree_keymaps.new_root and tree_keymaps.new_root.key or "N",
        delete = tree_keymaps.delete_dialog and tree_keymaps.delete_dialog.key or "d",
        delete_force = tree_keymaps.delete_branch and tree_keymaps.delete_branch.key or "D",
        expand = tree_keymaps.expand and tree_keymaps.expand.key or "o",
        collapse = tree_keymaps.collapse and tree_keymaps.collapse.key or "O",
        quit = tree_keymaps.quit and tree_keymaps.quit.key or "q",
        refresh = tree_keymaps.refresh and tree_keymaps.refresh.key or "r",
      }
    else
      keymaps = state.config.keymaps or M._get_default_keymaps()
    end
  else
    keymaps = state.config.keymaps or M._get_default_keymaps()
  end

  -- 使用闭包创建局部函数引用，避免每次按键都调用 require
  -- 这些函数形成闭包，可以访问外部作用域的 M 模块
  -- 使用 vim.keymap.set() 直接传递函数，性能更好且消除 LSP 警告
  local function move_selection_up()
    M._move_selection("up")
  end

  local function move_selection_down()
    M._move_selection("down")
  end

  local function collapse_current_node()
    M._collapse_node()
  end

  local function expand_current_node()
    M._expand_node()
  end

  local function select_current_node()
    M._select_node()
  end

  local function create_new_child_branch()
    M._new_child_branch()
  end

  local function create_new_root_branch()
    M._new_root_branch()
  end

  local function delete_current_node()
    M._delete_node()
  end

  local function delete_current_node_force()
    M._delete_node_force()
  end

  local function close_tree_window()
    M.close()
  end

  local function refresh_tree_window()
    M.refresh_tree()
  end

  -- 设置按键映射（使用 vim.keymap.set 直接传递函数）
  for key, mapping in pairs(keymaps) do
    local callback = nil
    if key == "up" then
      callback = move_selection_up
    elseif key == "down" then
      callback = move_selection_down
    elseif key == "left" then
      callback = collapse_current_node
    elseif key == "right" then
      callback = expand_current_node
    elseif key == "select" then
      callback = select_current_node
    elseif key == "expand" then
      callback = expand_current_node
    elseif key == "collapse" then
      callback = collapse_current_node
    elseif key == "new_child" then
      callback = create_new_child_branch
    elseif key == "new_root" then
      callback = create_new_root_branch
    elseif key == "delete" then
      callback = delete_current_node
    elseif key == "delete_force" then
      callback = delete_current_node_force
    elseif key == "quit" then
      callback = close_tree_window
    elseif key == "refresh" then
      callback = refresh_tree_window
    end

    if callback then
      vim.keymap.set("n", mapping, callback, { buffer = buf, noremap = true, silent = true })
    end
  end

  -- 设置光标移动监听器
  M._setup_cursor_listener(buf)
end

--- 设置光标移动监听器（内部使用）
--- @param buf number 缓冲区句柄
function M._setup_cursor_listener(buf)
  -- 如果已经有监听器，先清理
  if state.cursor_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.cursor_augroup)
  end

  -- 创建自动命令组
  state.cursor_augroup = vim.api.nvim_create_augroup("NeoAITreeWindowCursor", { clear = true })

  -- 监听光标移动事件
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = state.cursor_augroup,
    buffer = buf,
    callback = function()
      -- 更新高亮显示
      M._update_cursor_highlight()
    end,
    desc = "更新树窗口光标高亮",
  })

  -- 监听窗口大小变化事件
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = state.cursor_augroup,
    buffer = buf,
    callback = function()
      -- 更新悬浮窗口位置
      M._update_float_window()
    end,
    desc = "更新树窗口悬浮窗口位置",
  })
end

--- 更新光标高亮（内部使用）
function M._update_cursor_highlight()
  -- 渲染中不处理光标高亮，防止递归调用导致死循环
  if _rendering then
    return
  end

  -- 获取当前光标位置的节点ID
  local selected_node_id = M.get_selected_node()

  -- 如果选中节点有变化，更新状态并刷新显示
  if selected_node_id ~= state.selected_node_id then
    state.selected_node_id = selected_node_id

    -- 更新显示（只更新底部状态行，不重新渲染整个树）
    M._update_status_line()
  end
end

--- 获取默认键位配置
--- @return table 默认键位配置
function M._get_default_keymaps()
  return {
    up = "k",
    down = "j",
    left = "h",
    right = "l",
    select = "<CR>",
    expand = "o",
    collapse = "O", -- 注意：这是大写O，与全局配置一致
    new_child = "n",
    new_root = "N",
    delete = "d",
    delete_force = "D",
    quit = "q",
    refresh = "r",
  }
end

--- 获取选中节点（基于光标位置）
--- @return string|nil 选中节点ID
function M.get_selected_node()
  -- 如果没有窗口打开，返回nil
  if not state.current_window_id then
    return nil
  end

  -- 获取当前光标位置
  local win_handle = window_manager.get_window_win(state.current_window_id)
  if not win_handle or not vim.api.nvim_win_is_valid(win_handle) then
    return nil
  end

  -- 获取光标行号（0-based）
  local cursor_pos = vim.api.nvim_win_get_cursor(win_handle)
  local cursor_line = cursor_pos[1] - 1 -- 转换为0-based

  -- 构建行号到节点ID的映射
  local line_to_node = M._build_line_to_node_map()

  -- 遍历映射，查找光标所在行对应的节点ID
  for line, node_id in pairs(line_to_node) do
    -- 节点行号 + 内容偏移量(2) = 实际光标行号
    if line + 2 == cursor_line then
      return node_id
    end
  end

  return nil
end

--- 根据行号获取节点ID（内部使用）
--- @param line_number number 行号（0-based）
--- @return string|nil 节点ID
function M._get_node_id_at_line(line_number)
  -- 如果没有树数据，返回nil
  if not state.tree_data or #state.tree_data == 0 then
    return nil
  end

  -- 使用 _build_line_to_node_map 构建映射
  local line_to_node = M._build_line_to_node_map()

  -- 返回对应行的节点ID
  return line_to_node[line_number]
end

--- 根据节点ID获取节点名称（内部使用）
--- @param node_id string 节点ID
--- @return string|nil 节点名称
function M._get_node_name_by_id(node_id)
  if not node_id or not state.tree_data then
    return nil
  end

  local function search_node(nodes)
    for _, node in ipairs(nodes) do
      if node.id == node_id then
        return node.preview or node.name
      end

      -- 递归搜索子节点
      if node.children then
        local result = search_node(node.children)
        if result then
          return result
        end
      end
    end

    return nil
  end

  return search_node(state.tree_data)
end

--- 关闭树窗口
function M.close()
  if not state.current_window_id then
    return
  end

  -- 检查树窗口是否真的打开
  local win_handle = window_manager.get_window_win(state.current_window_id)
  if not win_handle or not vim.api.nvim_win_is_valid(win_handle) then
    -- 窗口已关闭，清理状态但不触发事件
    state.current_window_id = nil
    state.tree_data = {}
    state.selected_node_id = nil
    state.expanded_nodes = {}
    return
  end

  -- 触发窗口关闭前事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = "NeoAI:window_closing", data = { window_id = state.current_window_id } }
  )

  -- 触发树窗口关闭事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = "NeoAI:tree_window_closing", data = { window_id = state.current_window_id } }
  )

  window_manager.close_window(state.current_window_id)

  -- 清理自动命令组
  if state.cursor_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.cursor_augroup)
    state.cursor_augroup = nil
  end

  -- 关闭悬浮窗口
  M._close_float_window()

  state.current_window_id = nil
  state.current_session_id = nil
  state.tree_data = {}
  state.selected_node_id = nil
  state.expanded_nodes = {}
  state.float_win_id = nil
  state.float_buf_id = nil

  -- 触发窗口关闭事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = "NeoAI:window_closed", data = { window_id = state.current_window_id } }
  )

  -- 触发树窗口关闭完成事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = "NeoAI:tree_window_closed", data = { window_id = state.current_window_id } }
  )
end

--- 异步加载树数据（内部使用）
--- @param session_id string 会话ID
--- @param callback function|nil 加载完成后的回调
function M._load_tree_data_async(session_id, callback)
  async_worker.submit_task("load_tree_data", function()
    local history_tree = require("NeoAI.ui.components.history_tree")
    local config = state.config or {}
    local save_path = config.session and config.session.save_path
    if not save_path then
      save_path = vim.fn.stdpath("cache") .. "/NeoAI"
    end
    history_tree.initialize({
      save_path = save_path,
      max_messages_per_session = config.max_messages_per_session or 10,
    })
    if history_tree.refresh then
      history_tree.refresh(session_id)
    end
    local tree_data = history_tree.get_tree_data()
    return tree_data
  end, function(success, tree_data)
    if success and tree_data then
      state.tree_data = tree_data
      local function expand_all_nodes(nodes)
        for _, node in ipairs(nodes) do
          state.expanded_nodes[node.id] = true
          if node.children and #node.children > 0 then
            expand_all_nodes(node.children)
          end
        end
      end
      expand_all_nodes(state.tree_data)
      vim.api.nvim_exec_autocmds("User", {
        pattern = "NeoAI:tree_data_loaded",
        data = {
          window_id = state.current_window_id,
          session_id = session_id,
          session_count = #state.tree_data,
        },
      })
    else
      state.tree_data = {}
    end
    if callback then
      callback()
    end
  end)
end

--- 加载树数据（同步版本，内部使用）
--- @param session_id string 会话ID
function M._load_tree_data(session_id)
  local history_tree = require("NeoAI.ui.components.history_tree")
  local config = state.config or {}
  local save_path = config.session and config.session.save_path
  if not save_path then
    save_path = vim.fn.stdpath("cache") .. "/NeoAI"
  end
  history_tree.initialize({
    save_path = save_path,
    max_messages_per_session = config.max_messages_per_session or 10,
  })
  if history_tree.refresh then
    history_tree.refresh(session_id)
  end
  state.tree_data = history_tree.get_tree_data() or {}
  local function expand_all_nodes(nodes)
    for _, node in ipairs(nodes) do
      state.expanded_nodes[node.id] = true
      if node.children and #node.children > 0 then
        expand_all_nodes(node.children)
      end
    end
  end
  expand_all_nodes(state.tree_data)
  vim.api.nvim_exec_autocmds("User", {
    pattern = "NeoAI:tree_data_loaded",
    data = {
      window_id = state.current_window_id,
      session_id = session_id,
      session_count = #state.tree_data,
    },
  })
end

--- 计算总消息数（内部使用）
--- @param nodes table 节点列表
--- @return number 总消息数
function M._count_total_messages(nodes)
  if not nodes then
    return 0
  end

  local count = 0

  for _, node in ipairs(nodes) do
    -- 如果是消息节点，计数
    if node.type == "message" then
      count = count + 1
    end

    -- 递归计数子节点
    if node.children and #node.children > 0 then
      count = count + M._count_total_messages(node.children)
    end
  end

  return count
end

--- 构建行号到节点ID的映射（内部使用）
--- @return table 行号到节点ID的映射表
--- @return integer 当前行号
function M._build_line_to_node_map()
  local line_to_node = {}
  local current_line = 0

  local function traverse_node(node)
    -- 记录当前行的节点ID
    line_to_node[current_line] = node.id
    current_line = current_line + 1

    -- 如果节点展开，遍历子节点
    if state.expanded_nodes[node.id] and node.children then
      for _, child in ipairs(node.children) do
        traverse_node(child)
      end
    end
  end

  -- 遍历所有根节点
  for _, root_node in ipairs(state.tree_data) do
    traverse_node(root_node)
  end

  return line_to_node, current_line
end

--- 移动选择（内部使用）
--- @param direction string 方向 ('up' 或 'down')
function M._move_selection(direction)
  -- 触发选择移动事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = "NeoAI:tree_node_selection_moving",
    data = { window_id = state.current_window_id, direction = direction },
  })

  -- 构建行号到节点ID的映射
  local line_to_node, total_lines = M._build_line_to_node_map()

  if total_lines == 0 then
    return
  end

  -- 查找当前选中节点所在的行号
  local current_line = nil
  if state.selected_node_id then
    for line, node_id in pairs(line_to_node) do
      if node_id == state.selected_node_id then
        current_line = line
        break
      end
    end
  end

  -- 计算新的行号
  local new_line
  if current_line == nil then
    -- 没有选中任何节点，默认选中第一个
    new_line = 0
  elseif direction == "up" then
    new_line = current_line - 1
    if new_line < 0 then
      new_line = total_lines - 1 -- 循环到末尾
    end
  elseif direction == "down" then
    new_line = current_line + 1
    if new_line >= total_lines then
      new_line = 0 -- 循环到开头
    end
  end

  -- 更新选中的节点ID
  state.selected_node_id = line_to_node[new_line]

  -- 只更新光标位置和状态行，不重新渲染整个树
  -- 避免触发 CursorMoved 事件链导致死循环
  local win_handle = window_manager.get_window_win(state.current_window_id)
  if win_handle and vim.api.nvim_win_is_valid(win_handle) then
    local cursor_line = new_line + 2 -- 内容偏移量（标题行+空行）
    vim.api.nvim_win_set_cursor(win_handle, { cursor_line + 1, 0 }) -- 1-based
  end

  -- 更新状态行显示
  M._update_status_line()

  -- 触发选择移动完成事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = "NeoAI:tree_node_selection_moved",
    data = { window_id = state.current_window_id, direction = direction },
  })
end

--- 展开节点（内部使用）
function M._expand_node()
  if state.selected_node_id then
    -- 触发节点展开事件
    vim.api.nvim_exec_autocmds("User", {
      pattern = "NeoAI:tree_node_expanding",
      data = { window_id = state.current_window_id, node_id = state.selected_node_id },
    })

    state.expanded_nodes[state.selected_node_id] = true
    M.render_tree(state.tree_data)

    -- 触发节点展开完成事件
    vim.api.nvim_exec_autocmds("User", {
      pattern = "NeoAI:tree_node_expanded",
      data = { window_id = state.current_window_id, node_id = state.selected_node_id },
    })
  end
end

--- 折叠节点（内部使用）
function M._collapse_node()
  if state.selected_node_id then
    -- 触发节点折叠事件
    vim.api.nvim_exec_autocmds("User", {
      pattern = "NeoAI:tree_node_collapsing",
      data = { window_id = state.current_window_id, node_id = state.selected_node_id },
    })

    state.expanded_nodes[state.selected_node_id] = nil
    M.render_tree(state.tree_data)

    -- 触发节点折叠完成事件
    vim.api.nvim_exec_autocmds("User", {
      pattern = "NeoAI:tree_node_collapsed",
      data = { window_id = state.current_window_id, node_id = state.selected_node_id },
    })
  end
end

--- 选择节点（内部使用）
function M._select_node()
  -- 动态获取当前光标位置的节点ID
  local selected_node_id = M.get_selected_node()

  if selected_node_id then
    -- 触发节点选择事件
    vim.api.nvim_exec_autocmds("User", {
      pattern = "NeoAI:tree_node_selecting",
      data = { window_id = state.current_window_id, node_id = selected_node_id },
    })

    -- 调用tree_handlers的handle_enter函数
    local tree_handlers = require("NeoAI.ui.handlers.tree_handlers")
    tree_handlers.handle_enter()

    -- 触发节点选择完成事件
    vim.api.nvim_exec_autocmds("User", {
      pattern = "NeoAI:tree_node_selected",
      data = { window_id = state.current_window_id, node_id = selected_node_id },
    })
  else
    print("未选中任何节点", vim.log.levels.WARN)
  end
end

--- 新建子节点（n键）：在会话下新建对话轮次，或在根下新建会话
function M._new_child_branch()
  local target_node_id = state.selected_node_id
  if not target_node_id then
    vim.notify("请先选中一个会话", vim.log.levels.WARN)
    return
  end
  -- 跳过虚拟分支节点和轮次节点
  if target_node_id:match("^__branch_") then
    vim.notify("请选择具体的会话节点", vim.log.levels.WARN)
    return
  end
  if target_node_id:match("_round$") then
    vim.notify("请选择会话节点，而非对话轮次", vim.log.levels.WARN)
    return
  end
  local ok, hm = pcall(require, "NeoAI.core.history_manager")
  if not ok or not hm.is_initialized() then
    vim.notify("历史管理器未初始化", vim.log.levels.ERROR)
    return
  end
  local parent = hm.get_session(target_node_id)
  if not parent then
    vim.notify("会话不存在", vim.log.levels.WARN)
    return
  end
  local new_id = hm.create_session("子会话-" .. parent.name, false, target_node_id)
  vim.notify("已创建子会话: " .. new_id, vim.log.levels.INFO)
  -- 自动打开新创建的会话
  hm.set_current_session(new_id)
  local ui = require("NeoAI.ui")
  local chat_window = require("NeoAI.ui.window.chat_window")
  if chat_window.is_open() then
    chat_window.close()
  end
  ui.open_chat_ui(new_id, "main")
end

function M._new_root_branch()
  local ok, hm = pcall(require, "NeoAI.core.history_manager")
  if not ok or not hm.is_initialized() then
    vim.notify("历史管理器未初始化", vim.log.levels.ERROR)
    return
  end
  local new_id = hm.create_session("新会话", true, nil)
  vim.notify("已创建根会话: " .. new_id, vim.log.levels.INFO)
  -- 自动打开新创建的会话
  hm.set_current_session(new_id)
  local ui = require("NeoAI.ui")
  local chat_window = require("NeoAI.ui.window.chat_window")
  if chat_window.is_open() then
    chat_window.close()
  end
  ui.open_chat_ui(new_id, "main")
end

function M._delete_node()
  if not state.selected_node_id then
    vim.notify("请先选择一个节点", vim.log.levels.WARN)
    return
  end
  local node_id = state.selected_node_id
  -- 跳过虚拟分支节点和轮次节点
  if node_id:match("^__branch_") then
    vim.notify("不能删除虚拟分支节点", vim.log.levels.WARN)
    return
  end
  if node_id:match("_round$") then
    vim.notify("不能删除对话轮次节点", vim.log.levels.WARN)
    return
  end
  local ok, hm = pcall(require, "NeoAI.core.history_manager")
  if not ok or not hm.is_initialized() then
    vim.notify("历史管理器未初始化", vim.log.levels.ERROR)
    return
  end
  local session = hm.get_session(node_id)
  if not session then
    vim.notify("会话不存在", vim.log.levels.WARN)
    return
  end
  local confirm = vim.fn.confirm("确定要删除 '" .. session.name .. "' 吗？", "&Yes\n&No", 2)
  if confirm ~= 1 then
    return
  end
  hm.delete_session(node_id)
  -- 清除选中状态，避免后续渲染时引用已删除的节点
  state.selected_node_id = nil
  vim.notify("已删除会话", vim.log.levels.INFO)
  M.refresh_tree()
end

function M._delete_node_force()
  M._delete_node()
end

--- 高亮选中节点（内部使用）
function M._highlight_selected_node()
  -- 这里可以实现语法高亮
  -- 目前是简化实现
end

--- 创建或更新悬浮窗口（内部使用）
function M._update_float_window()
  if not state.current_window_id then
    return
  end

  -- 获取主窗口信息
  local main_win_handle = window_manager.get_window_win(state.current_window_id)
  if not main_win_handle or not vim.api.nvim_win_is_valid(main_win_handle) then
    return
  end

  -- 构建状态文本
  local status_text = "当前选中: "

  if state.selected_node_id then
    local node_name = M._get_node_name_by_id(state.selected_node_id)
    if node_name then
      -- 移除换行符，确保是单行字符串
      status_text = status_text .. node_name:gsub("\n", " "):gsub("\r", " ")
    else
      -- 节点名称获取失败（可能已被删除），显示为"无"
      status_text = status_text .. "无"
    end
  else
    status_text = status_text .. "无"
  end

  -- 计算悬浮窗口位置（右上角）
  -- 获取主窗口的屏幕位置和大小
  local main_win_info = vim.fn.getwininfo(main_win_handle)
  if not main_win_info or #main_win_info == 0 then
    return
  end

  local win_info = main_win_info[1]
  local main_width = win_info.width
  local main_height = win_info.height
  local main_row = win_info.winrow - 1 -- 转换为0-based
  local main_col = win_info.wincol - 1 -- 转换为0-based

  -- 计算悬浮窗口大小（基于文本长度）
  local float_width = math.min(#status_text + 4, main_width - 4) -- 留出边距
  local float_height = 1

  -- 计算位置：右上角，稍微偏移避免紧贴边缘
  -- 相对于主窗口的位置（从主窗口的左上角开始计算）
  local relative_col = main_width - float_width - 2 -- 右侧对齐，留出2字符边距
  local relative_row = 1 -- 顶部对齐，留出1行边距

  -- 如果悬浮窗口不存在，创建它
  if not state.float_win_id or not vim.api.nvim_win_is_valid(state.float_win_id) then
    -- 创建缓冲区
    state.float_buf_id = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("buflisted", false, { buf = state.float_buf_id })
    vim.api.nvim_set_option_value("modifiable", true, { buf = state.float_buf_id })
    vim.api.nvim_set_option_value("readonly", false, { buf = state.float_buf_id })

    -- 创建悬浮窗口
    local float_opts = {
      relative = "win",
      win = main_win_handle,
      width = float_width,
      height = float_height,
      col = relative_col,
      row = relative_row,
      style = "minimal",
      border = "single",
      focusable = false,
      zindex = 100, -- 确保悬浮窗口在主窗口之上
    }

    state.float_win_id = vim.api.nvim_open_win(state.float_buf_id, false, float_opts)

    -- 设置窗口选项
    vim.api.nvim_set_option_value("wrap", false, { win = state.float_win_id })
    vim.api.nvim_set_option_value("cursorline", false, { win = state.float_win_id })
    vim.api.nvim_set_option_value("number", false, { win = state.float_win_id })
    vim.api.nvim_set_option_value("signcolumn", "no", { win = state.float_win_id })
  else
    -- 更新现有悬浮窗口的位置和大小
    local float_opts = {
      relative = "win",
      win = main_win_handle,
      width = float_width,
      height = float_height,
      col = relative_col,
      row = relative_row,
    }

    vim.api.nvim_win_set_config(state.float_win_id, float_opts)
  end

  -- 更新悬浮窗口内容
  if state.float_buf_id and vim.api.nvim_buf_is_valid(state.float_buf_id) then
    -- 临时设置缓冲区为可修改以便更新内容
    vim.api.nvim_set_option_value("modifiable", true, { buf = state.float_buf_id })
    vim.api.nvim_set_option_value("readonly", false, { buf = state.float_buf_id })

    vim.api.nvim_buf_set_lines(state.float_buf_id, 0, -1, false, { status_text })

    -- 设置缓冲区为只读
    vim.api.nvim_set_option_value("modifiable", false, { buf = state.float_buf_id })
    vim.api.nvim_set_option_value("readonly", true, { buf = state.float_buf_id })
    -- 标记为未修改，避免保存警告
    vim.api.nvim_set_option_value("modified", false, { buf = state.float_buf_id })
  end
end

--- 关闭悬浮窗口（内部使用）
function M._close_float_window()
  if state.float_win_id and vim.api.nvim_win_is_valid(state.float_win_id) then
    vim.api.nvim_win_close(state.float_win_id, true)
    state.float_win_id = nil
  end

  if state.float_buf_id and vim.api.nvim_buf_is_valid(state.float_buf_id) then
    vim.api.nvim_buf_delete(state.float_buf_id, { force = true })
    state.float_buf_id = nil
  end
end

--- 更新状态行（内部使用）
function M._update_status_line()
  -- 使用悬浮窗口显示选中信息
  M._update_float_window()
end

--- 更新配置
--- @param new_config table 新配置
function M.update_config(new_config)
  if not state.initialized then
    return
  end

  state.config = vim.tbl_extend("force", state.config, new_config or {})

  -- 如果窗口打开，重新设置按键映射
  if state.current_window_id then
    M.set_keymaps()
    M.render_tree(state.tree_data)
  end
end

--- 刷新树窗口
--- @return boolean 是否成功
function M.refresh()
  if not state.initialized then
    return false
  end

  if not state.current_window_id then
    return false
  end

  -- 重新渲染树
  M.render_tree(state.tree_data)
  return true
end

--- 获取当前树数据
--- @return table 树数据
function M.get_tree_data()
  return state.tree_data
end

--- 检查树窗口是否已打开
--- @return boolean 是否已打开
function M.is_open()
  if not state.initialized then
    return false
  end

  return state.current_window_id ~= nil
end

--- 选择指定节点
--- @param node_id string|nil 节点ID，传入 nil 清除选中状态
--- @return boolean 是否成功
function M.select_node(node_id)
  if not state.initialized then
    return false
  end

  -- 清除选中状态
  if not node_id then
    state.selected_node_id = nil
    M._update_status_line()
    return true
  end

  -- 触发节点选择事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = "NeoAI:tree_node_selecting", data = { window_id = state.current_window_id, node_id = node_id } }
  )

  -- 设置选中的节点
  state.selected_node_id = node_id

  -- 更新状态行
  M._update_status_line()

  -- 触发节点选择完成事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = "NeoAI:tree_node_selected", data = { window_id = state.current_window_id, node_id = node_id } }
  )

  return true
end

--- 获取节点在树中的路径编号（内部使用）
--- 例如：根节点下第2个子节点的第3个子节点 -> "2-3"
--- @param node_id string 节点ID
--- @param tree_data table 树数据
--- @return string 路径编号字符串
function M._get_node_path_number(node_id, tree_data)
  if not node_id or not tree_data then
    return ""
  end

  -- 从目标节点向上查找父节点，并记录每层在兄弟节点中的序号
  local path_parts = {}
  local current_id = node_id

  while current_id do
    local parent_node = nil
    local sibling_index = nil

    -- 在树中查找当前节点的父节点及其在兄弟中的序号
    local function find_parent_and_index(nodes, target_id)
      for _, node in ipairs(nodes) do
        if node.children then
          for idx, child in ipairs(node.children) do
            if child.id == target_id then
              parent_node = node
              sibling_index = idx
              return true
            end
          end
          -- 递归查找
          if find_parent_and_index(node.children, target_id) then
            return true
          end
        end
      end
      return false
    end

    if not find_parent_and_index(tree_data, current_id) then
      break
    end

    if sibling_index then
      table.insert(path_parts, 1, tostring(sibling_index))
    end

    -- 如果父节点是虚拟根节点，停止向上查找
    if not parent_node or parent_node.type == "virtual_root" or parent_node.id == "virtual_root" then
      break
    end

    current_id = parent_node.id
  end

  if #path_parts == 0 then
    return ""
  end

  return table.concat(path_parts, "-")
end

--- 生成子分支名称
--- @param parent_node_id string 父节点ID
--- @return string 分支名称
function M._generate_branch_name(parent_node_id)
  -- 计算父节点已有的子节点数量
  local child_count = 0
  if state.tree_data then
    local function count_children(nodes, target_id)
      for _, node in ipairs(nodes) do
        if node.id == target_id then
          if node.children then
            return #node.children
          end
          return 0
        end
        if node.children then
          local result = count_children(node.children, target_id)
          if result ~= nil then
            return result
          end
        end
      end
      return nil
    end
    child_count = count_children(state.tree_data, parent_node_id) or 0
  end

  -- 获取父节点的路径编号
  local parent_path = M._get_node_path_number(parent_node_id, state.tree_data)

  -- 生成子节点名称：如果父节点有路径编号，则使用 父路径-子序号
  local child_num = child_count + 1
  if parent_path and parent_path ~= "" then
    return "节点-" .. parent_path .. "-" .. child_num
  else
    return "节点-" .. child_num
  end
end

--- 生成根分支名称
--- @return string 根分支名称
function M._generate_root_branch_name()
  -- 计算虚拟根节点下已有的子节点数量
  local root_count = 0
  if state.tree_data then
    for _, node in ipairs(state.tree_data) do
      if node.type == "virtual_root" and node.children then
        root_count = #node.children
      elseif node.type ~= "virtual_root" then
        root_count = root_count + 1
      end
    end
  end

  -- 生成根节点名称：根节点-编号
  return "根节点-" .. (root_count + 1)
end

--- 测试树窗口创建
--- @return boolean 测试是否成功
function M.test_window_creation()
  if not state.initialized then
    return false
  end

  -- 尝试打开一个测试树窗口
  local window_id = M.open("test_session", "win_test")

  if window_id then
    -- 成功创建，关闭窗口
    M.close()
    return true
  end

  return false
end

return M
