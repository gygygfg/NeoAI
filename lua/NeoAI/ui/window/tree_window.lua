local M = {}
local MODULE_NAME = "NeoAI.ui.window.tree_window"
local window_manager = require("NeoAI.ui.window.window_manager")

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
  node_counter = 0, -- 节点计数器，用于生成序号
  max_node_number = 0, -- 最大节点编号
}

--- 初始化树窗口
--- @param config table 配置
function M.initialize(config)
  if state.initialized then
    return
  end

  state.config = config or {}
  state.initialized = true
  state.node_counter = 0
  state.max_node_number = 0
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
  state.node_counter = 0
  state.max_node_number = 0

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

  -- 加载树数据
  M._load_tree_data(session_id)

  -- 先计算树的总节点数，用于序号生成
  M._calculate_node_numbers(state.tree_data)

  -- 渲染树
  M.render_tree(state.tree_data)

  -- 设置按键映射
  M.set_keymaps()

  -- 初始化悬浮窗口
  M._update_float_window()

  -- 触发树窗口打开事件
  vim.api.nvim_exec_autocmds("User", { pattern = "NeoAI:tree_window_opened", data = { window_id = window_id } })

  return true
end

--- 计算树的总节点数并生成序号映射
--- @param nodes table 节点列表
--- @return number 总节点数
function M._calculate_node_numbers(nodes)
  if not nodes then
    return 0
  end

  local count = 0
  local node_stack = {}

  -- 使用栈进行深度优先遍历
  -- 先将所有根节点逆序入栈，确保深度优先遍历的顺序
  for i = #nodes, 1, -1 do
    table.insert(node_stack, { node = nodes[i], depth = 0 })
  end

  -- 存储每个节点的编号
  state.node_numbers = {}

  -- 深度优先遍历
  while #node_stack > 0 do
    local stack_item = table.remove(node_stack)
    local node = stack_item.node
    local depth = stack_item.depth

    -- 为当前节点分配编号
    count = count + 1
    state.node_numbers[node.id] = count

    -- 如果节点有子节点且是展开状态，将子节点逆序入栈
    if state.expanded_nodes[node.id] and node.children and #node.children > 0 then
      for i = #node.children, 1, -1 do
        table.insert(node_stack, { node = node.children[i], depth = depth + 1 })
      end
    end
  end

  state.max_node_number = count
  return count
end

--- 渲染树状图
--- @param tree_data table 树数据
function M.render_tree(tree_data)
  if not state.current_window_id then
    print("调试：没有当前窗口ID", vim.log.levels.WARN)
    return
  end

  -- 重置计数器
  state.node_counter = 0
  state.node_numbers = {}

  -- 触发开始渲染树事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = "NeoAI:tree_rendering_start", data = { window_id = state.current_window_id } }
  )

  -- 计算节点总数和编号
  local total_nodes = M._calculate_node_numbers(tree_data)
  state.node_counter = total_nodes

  -- 获取窗口宽度，并减去左侧行号栏的宽度
  local window_width = nil
  local win_handle = window_manager.get_window_win(state.current_window_id)
  if win_handle and vim.api.nvim_win_is_valid(win_handle) then
    local win_config = vim.api.nvim_win_get_config(win_handle)
    if win_config and win_config.width then
      window_width = win_config.width

      -- 减去左侧行号栏的宽度
      local number_width = vim.api.nvim_get_option_value("numberwidth", { win = win_handle })
      if number_width then
        window_width = window_width - number_width
      end

      -- 减去符号列的宽度（如果有）
      local signcolumn = vim.api.nvim_get_option_value("signcolumn", { win = win_handle })
      if signcolumn and signcolumn ~= "no" then
        -- 符号列通常占用2个字符宽度
        window_width = window_width - 2
      end
    end
  end

  -- 调试：打印树数据信息
  print("调试：开始渲染树，节点总数: " .. total_nodes, vim.log.levels.INFO)
  if tree_data and #tree_data > 0 then
    print("调试：树数据根节点数量: " .. #tree_data, vim.log.levels.INFO)
    for i, node in ipairs(tree_data) do
      print(
        "调试：根节点 "
          .. i
          .. ": "
          .. (node.name or "未命名")
          .. " (类型: "
          .. (node.type or "未知")
          .. ")",
        vim.log.levels.INFO
      )
      if node.children then
        print("调试：  子节点数量: " .. #node.children, vim.log.levels.INFO)
      end
    end
  else
    print("调试：树数据为空或无效", vim.log.levels.WARN)
  end

  -- 使用 window_manager 的通用渲染函数，传递窗口宽度
  local content = window_manager.render_tree(tree_data, state, M._load_tree_data, window_width)

  -- 调试：打印渲染后的内容
  print("调试：渲染后的内容行数: " .. #content, vim.log.levels.INFO)
  if #content > 0 then
    for i = 1, math.min(10, #content) do
      print("调试：内容行 " .. i .. ": " .. content[i], vim.log.levels.INFO)
    end
  end

  -- 设置窗口内容
  window_manager.set_window_content(state.current_window_id, content)

  -- 高亮选中节点
  M._highlight_selected_node()

  -- 设置光标位置到选中的节点
  if state.selected_node_id then
    local win_handle = window_manager.get_window_win(state.current_window_id)
    if win_handle and vim.api.nvim_win_is_valid(win_handle) then
      -- 构建行号映射找到选中节点所在行
      local line_to_node = M._build_line_to_node_map()
      for line, node_id in pairs(line_to_node) do
        if node_id == state.selected_node_id then
          local cursor_line = line + 2 -- 内容偏移量（标题行+空行）
          vim.api.nvim_win_set_cursor(win_handle, { cursor_line + 1, 0 }) -- 1-based
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

  -- 触发树渲染完成事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = "NeoAI:tree_rendering_complete", data = { window_id = state.current_window_id } }
  )
end

--- 刷新树状图
function M.refresh_tree()
  if not state.current_window_id then
    return
  end

  -- 重新加载数据
  M._load_tree_data(state.current_session_id)

  -- 重置计数器
  state.node_counter = 0
  state.node_numbers = {}

  -- 重新计算节点编号
  M._calculate_node_numbers(state.tree_data)

  -- 重新渲染
  M.render_tree(state.tree_data)
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
        return node.name
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
    state.node_counter = 0
    state.max_node_number = 0
    state.node_numbers = {}
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
  state.node_counter = 0
  state.max_node_number = 0
  state.node_numbers = {}

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

--- 渲染树节点（内部使用）
--- @param content table 内容表
--- @param node table 节点
--- @param depth number 深度
--- @param is_last boolean 是否是父节点的最后一个子节点
--- @param parent_prefix string 父节点的前缀
function M._render_tree_node(content, node, depth, is_last, parent_prefix)
  if not node then
    return
  end

  -- 跳过虚拟根节点的渲染（它只作为容器）
  if node.type == "virtual_root" then
    -- 直接渲染子节点
    if state.expanded_nodes[node.id] and node.children then
      local child_count = #node.children
      for i, child in ipairs(node.children) do
        local child_is_last = (i == child_count)
        M._render_tree_node(content, child, depth, child_is_last, parent_prefix)
      end
    end
    return
  end

  -- 获取当前节点的编号
  local node_number = state.node_numbers[node.id] or 0
  local number_str = tostring(node_number)

  -- 计算编号的宽度，确保对齐
  local max_number_len = tostring(state.max_node_number):len()
  local padded_number = string.rep(" ", max_number_len - number_str:len()) .. number_str

  -- 生成当前节点的前缀
  local current_prefix = parent_prefix or ""
  local line_prefix = ""

  if depth > 0 then
    -- 使用文件树样式的连接符
    if is_last then
      line_prefix = current_prefix .. "└───"
    else
      line_prefix = current_prefix .. "├───"
    end
  else
    line_prefix = "" -- 根节点没有前缀
  end

  -- 判断是否有子节点
  local node_prefix = ""
  if node.children and #node.children > 0 then
    if state.expanded_nodes[node.id] then
      node_prefix = "" -- 展开的节点不需要前缀
    else
      node_prefix = "" -- 折叠的节点也不需要前缀
    end
  else
    node_prefix = "" -- 没有子节点的节点也不需要前缀
  end

  -- 清理节点名称中的二进制数据和控制字符
  local cleaned_name = node.name
  if cleaned_name then
    -- 清理节点名称中的乱码（UTF-8截断导致的 <xx> 格式）
    -- 移除所有 <xx> 格式的十六进制标记（单个尖括号内容）
    cleaned_name = cleaned_name:gsub("<[%x][%x]>", "")
    -- 移除控制字符
    cleaned_name = cleaned_name:gsub("[%c%z]", "")
    -- 合并多余空格
    cleaned_name = cleaned_name:gsub("%s+", " ")
    cleaned_name = cleaned_name:gsub("^%s+", "")
    cleaned_name = cleaned_name:gsub("%s+$", "")
    if cleaned_name == "" then
      cleaned_name = "未命名节点"
    end
  else
    cleaned_name = "未命名节点"
  end

  -- 生成节点行，包含序号
  local line = padded_number .. " " .. line_prefix .. node_prefix .. cleaned_name
  if node.metadata then
    -- 显示会话的消息数量
    if node.type == "session" and node.metadata.message_count then
      line = line .. string.format(" (%d 消息)", node.metadata.message_count)
    end

    -- 显示分支的会话数量
    if (node.type == "root_branch" or node.type == "sub_branch") and node.metadata.session_count then
      line = line .. string.format(" (%d 会话)", node.metadata.session_count)
    end

    -- 显示创建时间
    if node.metadata.created_at then
      local time_str = os.date("%H:%M", node.metadata.created_at)
      line = line .. " [" .. time_str .. "]"
    end
  end

  table.insert(content, line)

  -- 渲染子节点（如果展开）
  -- 需求1: conversation_round 类型的节点不展开显示子消息，问答绑定在一行
  -- 但如果有用户创建的子分支（node类型），仍然需要显示
  if state.expanded_nodes[node.id] and node.children then
    -- 过滤子节点：跳过 message 类型的子节点（问答已在一行显示），但显示其他类型（如 node 子分支）
    local visible_children = {}
    for _, child in ipairs(node.children) do
      if child.type ~= "message" then
        table.insert(visible_children, child)
      end
    end

    if #visible_children > 0 then
      local child_count = #visible_children

      -- 为子节点生成新的前缀
      local child_parent_prefix = parent_prefix or ""
      if depth > 0 then
        if is_last then
          child_parent_prefix = child_parent_prefix .. "    "
        else
          child_parent_prefix = child_parent_prefix .. "│   "
        end
      end

      for i, child in ipairs(visible_children) do
        local child_is_last = (i == child_count)
        M._render_tree_node(content, child, depth + 1, child_is_last, child_parent_prefix)
      end
    end
  end
end

--- 加载树数据（内部使用）
--- @param session_id string 会话ID
function M._load_tree_data(session_id)
  -- 调试：打印加载树数据的开始
  print("调试：开始加载树数据，会话ID: " .. (session_id or "nil"), vim.log.levels.INFO)

  -- 使用 history_tree 组件加载实际的会话数据
  local history_tree = require("NeoAI.ui.components.history_tree")

  -- 确保 history_tree 已初始化
  if not history_tree then
    print("调试：无法加载 history_tree 模块", vim.log.levels.ERROR)
    error("无法加载 history_tree 模块")
  end

  -- 如果 history_tree 未初始化，使用默认配置初始化
  local config = state.config or {}

  -- 确保有正确的保存路径，与 session_manager 保持一致
  -- 优先从配置中获取，否则从 session_manager 获取，最后使用默认值
  local save_path = config.save_path
  if not save_path and config.session then
    save_path = config.session.save_path
  end
  if not save_path then
    -- 尝试从 session_manager 获取实际使用的路径
    pcall(function()
      local sm = require("NeoAI.core.session.session_manager")
      if sm.is_initialized and sm.is_initialized() then
        -- 通过内部状态获取 save_path（没有公开 API，直接访问 state）
        -- 或者通过重新初始化获取
      end
    end)
  end
  if not save_path then
    -- 使用与 config_manager 默认值一致的路径
    save_path = vim.fn.stdpath("cache") .. "/neoai_sessions"
  end

  history_tree.initialize({
    save_path = save_path,
    max_messages_per_session = config.max_messages_per_session or 10,
  })

  -- 强制刷新历史树数据
  if history_tree.refresh then
    print("调试：调用 history_tree.refresh", vim.log.levels.INFO)
    history_tree.refresh(session_id)
  else
    print("调试：history_tree.refresh 函数不存在", vim.log.levels.WARN)
  end

  -- 从 history_tree 获取树数据
  print("调试：调用 history_tree.build_tree", vim.log.levels.INFO)
  state.tree_data = history_tree.build_tree(session_id)

  -- 调试：打印获取的树数据信息
  if state.tree_data then
    print("调试：获取到树数据，根节点数量: " .. #state.tree_data, vim.log.levels.INFO)
    for i, node in ipairs(state.tree_data) do
      print(
        "调试：根节点 "
          .. i
          .. ": "
          .. (node.name or "未命名")
          .. " (类型: "
          .. (node.type or "未知")
          .. ")",
        vim.log.levels.INFO
      )
    end
  else
    print("调试：获取的树数据为 nil", vim.log.levels.WARN)
    state.tree_data = {}
  end

  -- 如果获取的数据为空，保持空数据
  if not state.tree_data or #state.tree_data == 0 then
    print("调试：树数据为空，无可用数据", vim.log.levels.WARN)
    state.tree_data = {}
  end

  -- 递归展开所有节点
  local function expand_all_nodes(nodes)
    for _, node in ipairs(nodes) do
      state.expanded_nodes[node.id] = true
      if node.children and #node.children > 0 then
        expand_all_nodes(node.children)
      end
    end
  end
  expand_all_nodes(state.tree_data)

  -- 触发数据加载完成事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = "NeoAI:tree_data_loaded",
    data = {
      window_id = state.current_window_id,
      session_id = session_id,
      session_count = #state.tree_data,
      total_messages = M._count_total_messages(state.tree_data),
    },
  })

  -- 调试：打印加载完成信息
  print("调试：树数据加载完成，总节点数: " .. #state.tree_data, vim.log.levels.INFO)
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
function M._build_line_to_node_map()
  local line_to_node = {}
  local current_line = 0

  local function traverse_node(node)
    -- 跳过虚拟根节点的显示（它只作为容器）
    if node.type == "virtual_root" then
      if state.expanded_nodes[node.id] and node.children then
        for _, child in ipairs(node.children) do
          traverse_node(child)
        end
      end
      return
    end

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

  -- 更新光标位置（加上内容偏移量3）
  local win_handle = window_manager.get_window_win(state.current_window_id)
  if win_handle and vim.api.nvim_win_is_valid(win_handle) then
          local cursor_line = new_line + 2 -- 内容偏移量（标题行+空行）
    vim.api.nvim_win_set_cursor(win_handle, { cursor_line + 1, 0 }) -- 1-based
  end

  -- 重新渲染树以更新高亮
  M.render_tree(state.tree_data)

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
  
  -- 如果没有选中节点，在虚拟根节点下创建（相当于创建新会话）
  if not target_node_id then
    -- 查找虚拟根节点ID
    for _, root_node in ipairs(state.tree_data) do
      if root_node.type == "virtual_root" then
        target_node_id = root_node.id
        break
      end
    end
  end
  
  if not target_node_id then
    print("无法找到目标节点", vim.log.levels.WARN)
    return
  end

  -- 触发新建子节点事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = "NeoAI:tree_node_new_child_creating",
    data = { window_id = state.current_window_id, node_id = target_node_id },
  })

  -- 判断目标节点类型
  local target_name = M._get_node_name_by_id(target_node_id) or ""
  
  if target_node_id == "virtual_root" or target_name == "所有会话" then
    -- 在根下创建新会话
    local session_mgr_loaded, session_mgr = pcall(require, "NeoAI.core.session.session_manager")
    if session_mgr_loaded and session_mgr and session_mgr.is_initialized and session_mgr.is_initialized() then
      local session_id = session_mgr.create_session("新会话")
      if session_id then
        print("新会话创建成功: " .. session_id, vim.log.levels.INFO)
      else
        print("新会话创建失败", vim.log.levels.ERROR)
      end
    else
      print("会话管理器未初始化", vim.log.levels.ERROR)
    end
  elseif target_node_id:match("^session_") then
    -- 需求3: 在会话下直接创建子分支（节点），而不是提示去聊天窗口
    local branch_name = M._generate_branch_name(target_node_id)
    local tree_handlers = require("NeoAI.ui.handlers.tree_handlers")
    local success = tree_handlers.create_branch(target_node_id, branch_name)
    if success then
      print("子分支创建成功: " .. branch_name, vim.log.levels.INFO)
    else
      print("子分支创建失败", vim.log.levels.ERROR)
    end
  else
    -- 其他节点：使用 tree_handlers.create_branch 创建子分支
    local branch_name = M._generate_branch_name(target_node_id)
    local tree_handlers = require("NeoAI.ui.handlers.tree_handlers")
    local success = tree_handlers.create_branch(target_node_id, branch_name)
    if success then
      print("子分支创建成功: " .. branch_name, vim.log.levels.INFO)
    else
      print("子分支创建失败", vim.log.levels.ERROR)
    end
  end

  -- 刷新树视图
  M.refresh_tree()

  -- 触发新建子节点完成事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = "NeoAI:tree_node_new_child_created",
    data = { window_id = state.current_window_id, node_id = target_node_id },
  })
end

--- 新建根节点/会话（N键）：创建新会话
function M._new_root_branch()
  -- 触发新建根节点事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = "NeoAI:tree_node_new_root_creating", data = { window_id = state.current_window_id } }
  )

  -- 创建新会话
  local session_mgr_loaded, session_mgr = pcall(require, "NeoAI.core.session.session_manager")
  if session_mgr_loaded and session_mgr and session_mgr.is_initialized and session_mgr.is_initialized() then
    local session_id = session_mgr.create_session("新会话")
    if session_id then
      print("新会话创建成功: " .. session_id, vim.log.levels.INFO)
    else
      print("新会话创建失败", vim.log.levels.ERROR)
    end
  else
    print("会话管理器未初始化", vim.log.levels.ERROR)
  end

  -- 刷新树视图
  M.refresh_tree()

  -- 触发新建根节点完成事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = "NeoAI:tree_node_new_root_created", data = { window_id = state.current_window_id } }
  )
end

--- 删除对话（d键）：删除轮次或消息节点
function M._delete_node()
  if state.selected_node_id then
    local node_id = state.selected_node_id
    -- 只允许删除 round_ 和 msg_ 开头的节点（对话轮次和消息）
    if not node_id:match("^round_") and not node_id:match("^msg_") then
      print("d 键仅用于删除对话轮次或消息，请使用 D 删除会话/分支", vim.log.levels.WARN)
      return
    end

    -- 显示确认对话框
    local confirm = vim.fn.confirm("确定要删除此对话吗？", "&Yes\n&No", 2)
    if confirm ~= 1 then
      return
    end

    -- 触发删除节点事件
    vim.api.nvim_exec_autocmds("User", {
      pattern = "NeoAI:tree_node_deleting",
      data = { window_id = state.current_window_id, node_id = node_id },
    })

    -- 从 tree_manager 删除节点
    local tree_mgr_loaded, tree_mgr = pcall(require, "NeoAI.core.session.tree_manager")
    if tree_mgr_loaded and tree_mgr and tree_mgr.is_initialized and tree_mgr.is_initialized() then
      pcall(tree_mgr.delete_node, node_id)
      print("对话删除成功", vim.log.levels.INFO)
    else
      print("对话删除失败: 树管理器未初始化", vim.log.levels.ERROR)
    end

    -- 刷新树视图
    M.refresh_tree()

    -- 触发删除节点完成事件
    vim.api.nvim_exec_autocmds("User", {
      pattern = "NeoAI:tree_node_deleted",
      data = { window_id = state.current_window_id, node_id = node_id },
    })
  else
    print("请先选择一个节点", vim.log.levels.WARN)
  end
end

--- 删除分支/会话（D键）：删除会话或分支节点（包含所有子对话）
function M._delete_node_force()
  if state.selected_node_id then
    local node_id = state.selected_node_id
    -- 需求2: 允许删除 session_、root_、node_ 开头的节点（会话和分支）
    if not node_id:match("^session_") and not node_id:match("^root_") and not node_id:match("^node_") then
      print("D 键仅用于删除会话或分支，请使用 d 删除对话轮次", vim.log.levels.WARN)
      return
    end

    -- 显示确认对话框
    local confirm = vim.fn.confirm(
      "确定要删除 '" .. (M._get_node_name_by_id(node_id) or node_id) .. "' 吗？\n这将删除所有子对话！",
      "&Yes\n&No",
      2
    )
    if confirm ~= 1 then
      return
    end

    -- 触发强制删除节点事件
    vim.api.nvim_exec_autocmds("User", {
      pattern = "NeoAI:tree_node_force_deleting",
      data = { window_id = state.current_window_id, node_id = node_id },
    })

    -- 调用 tree_handlers.delete_branch 处理删除
    local tree_handlers = require("NeoAI.ui.handlers.tree_handlers")
    local success, err = tree_handlers.delete_branch(node_id)

    if success then
      print("删除成功: " .. node_id, vim.log.levels.INFO)
    else
      print("删除失败: " .. (err or "未知错误"), vim.log.levels.ERROR)
    end

    -- 刷新树视图
    M.refresh_tree()

    -- 触发强制删除节点完成事件
    vim.api.nvim_exec_autocmds("User", {
      pattern = "NeoAI:tree_node_force_deleted",
      data = { window_id = state.current_window_id, node_id = node_id },
    })
  else
    print("请先选择一个节点", vim.log.levels.WARN)
  end
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
      status_text = status_text .. state.selected_node_id
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
--- @param node_id string 节点ID
--- @return boolean 是否成功
function M.select_node(node_id)
  if not state.initialized then
    return false
  end

  if not node_id then
    return false
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
