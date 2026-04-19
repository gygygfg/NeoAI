local M = {}
local MODULE_NAME = "NeoAI.ui.window.tree_window"

local window_manager = require("NeoAI.ui.window.window_manager")

-- 模块状态
local state = {
  initialized = false,
  config = nil,
  current_window_id = nil,
  tree_data = {},
  selected_node_id = nil,
  expanded_nodes = {},
  cursor_augroup = nil, -- 光标移动自动命令组
}

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
--- @param window_id string 窗口ID（必须由调用者通过 window_manager 创建）
--- @return boolean 是否成功
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
    vim.api.nvim_set_option_value("wrap", true, { win = win_handle })
    vim.api.nvim_set_option_value("linebreak", true, { win = win_handle })
    vim.api.nvim_set_option_value("cursorline", true, { win = win_handle })
  end

  -- 触发窗口打开事件
  vim.api.nvim_exec_autocmds("User", { pattern = "NeoAI:window_opened", data = { window_id = window_id } })

  -- 加载树数据
  M._load_tree_data(session_id)

  -- 渲染树
  M.render_tree()

  -- 设置按键映射
  M.set_keymaps()

  -- 触发树窗口打开事件
  vim.api.nvim_exec_autocmds("User", { pattern = "NeoAI:tree_window_opened", data = { window_id = window_id } })

  return true
end

--- 渲染树状图
--- @param tree_data table 树数据
function M.render_tree(tree_data)
  if not state.current_window_id then
    return
  end

  -- 触发开始渲染树事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = "NeoAI:tree_rendering_start", data = { window_id = state.current_window_id } }
  )

  -- 使用 window_manager 的通用渲染函数
  local content = window_manager.render_tree(tree_data, state, M._load_tree_data)

  -- 设置窗口内容
  window_manager.set_window_content(state.current_window_id, content)

  -- 高亮选中节点
  M._highlight_selected_node()

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
  M._load_tree_data()

  -- 重新渲染
  M.render_tree()
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

  -- 计算内容偏移量
  -- 树内容前面有5行：标题、提示、空行、虚拟根节点、空行
  local content_offset = 5

  -- 调整光标行号，减去内容偏移
  local adjusted_line = cursor_line - content_offset
  if adjusted_line < 0 then
    return nil -- 光标在标题、提示、空行、虚拟根节点或空行上
  end

  -- 根据调整后的行号查找对应的节点ID
  return M._get_node_id_at_line(adjusted_line)
end

--- 根据行号获取节点ID（内部使用）
--- @param line_number number 行号（0-based）
--- @return string|nil 节点ID
function M._get_node_id_at_line(line_number)
  -- 如果没有树数据，返回nil
  if not state.tree_data or #state.tree_data == 0 then
    return nil
  end

  -- 构建行号到节点ID的映射
  local line_to_node = {}
  local current_line = 0

  local function traverse_node(node, depth)
    -- 记录当前行的节点ID
    line_to_node[current_line] = node.id
    current_line = current_line + 1

    -- 如果节点展开，遍历子节点
    if state.expanded_nodes[node.id] and node.children then
      for _, child in ipairs(node.children) do
        traverse_node(child, depth + 1)
      end
    end
  end

  -- 遍历所有根节点
  for _, root_node in ipairs(state.tree_data) do
    traverse_node(root_node, 0)
  end

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

  state.current_window_id = nil
  state.tree_data = {}
  state.selected_node_id = nil
  state.expanded_nodes = {}

  -- 触发窗口关闭事件
  vim.api.nvim_exec_autocmds("User", { pattern = "NeoAI:window_closed", data = { window_id = state.current_window_id } })

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

  -- 生成当前节点的前缀
  local current_prefix = parent_prefix or ""
  local line_prefix = ""

  if depth > 0 then
    -- 使用文件树样式的连接符
    if is_last then
      line_prefix = current_prefix .. "└── "
    else
      line_prefix = current_prefix .. "├── "
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

  -- 生成节点行
  local line = line_prefix .. node_prefix .. node.name
  if node.metadata then
    if node.metadata.message_count then
      line = line .. string.format(" (%d 消息)", node.metadata.message_count)
    end

    if node.metadata.created_at then
      local time_str = os.date("%H:%M", node.metadata.created_at)
      line = line .. " [" .. time_str .. "]"
    end
  end

  table.insert(content, line)

  -- 渲染子节点（如果展开）
  if state.expanded_nodes[node.id] and node.children then
    local child_count = #node.children

    -- 为子节点生成新的前缀
    local child_parent_prefix = parent_prefix or ""
    if depth > 0 then
      if is_last then
        child_parent_prefix = child_parent_prefix .. "    " -- 最后一个子节点，父节点是空格
      else
        child_parent_prefix = child_parent_prefix .. "│   " -- 不是最后一个子节点，父节点是竖线
      end
    end

    for i, child in ipairs(node.children) do
      local child_is_last = (i == child_count)
      M._render_tree_node(content, child, depth + 1, child_is_last, child_parent_prefix)
    end
  end
end

--- 加载树数据（内部使用）
--- @param session_id string 会话ID
function M._load_tree_data(session_id)
  -- 这里应该从会话管理器加载树数据
  -- 目前使用模拟数据
  state.tree_data = {
    {
      id = "session_1",
      name = "主会话",
      metadata = {
        message_count = 5,
        created_at = os.time() - 3600,
      },
      children = {
        {
          id = "branch_1",
          name = "主分支",
          metadata = {
            message_count = 5,
            created_at = os.time() - 3600,
          },
          children = {
            {
              id = "branch_2",
              name = "功能开发",
              metadata = {
                message_count = 3,
                created_at = os.time() - 1800,
              },
              children = {},
            },
          },
        },
      },
    },
    {
      id = "session_2",
      name = "测试会话",
      metadata = {
        message_count = 2,
        created_at = os.time() - 7200,
      },
      children = {
        {
          id = "branch_3",
          name = "测试分支",
          metadata = {
            message_count = 2,
            created_at = os.time() - 7200,
          },
          children = {},
        },
      },
    },
  }

  -- 默认展开根节点
  for _, root_node in ipairs(state.tree_data) do
    state.expanded_nodes[root_node.id] = true
  end
end

--- 移动选择（内部使用）
--- @param direction string 方向 ('up' 或 'down')
function M._move_selection(direction)
  -- 触发选择移动事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = "NeoAI:tree_node_selection_moving", data = { window_id = state.current_window_id, direction = direction } }
  )

  -- 实现选择移动逻辑
  -- 目前是简化实现
  vim.notify("移动选择: " .. direction, vim.log.levels.INFO)
  M.render_tree(nil)

  -- 触发选择移动完成事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = "NeoAI:tree_node_selection_moved", data = { window_id = state.current_window_id, direction = direction } }
  )
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
    M.render_tree()

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
    M.render_tree()

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
    tree_handlers.handle_enter(selected_node_id)

    -- 触发节点选择完成事件
    vim.api.nvim_exec_autocmds(
      "User",
      { pattern = "NeoAI:tree_node_selected", data = { window_id = state.current_window_id, node_id = selected_node_id } }
    )
  else
    vim.notify("未选中任何节点", vim.log.levels.WARN)
  end
end

--- 新建子分支（内部使用）
function M._new_child_branch()
  if state.selected_node_id then
    -- 触发新建子分支事件
    vim.api.nvim_exec_autocmds("User", {
      pattern = "NeoAI:tree_node_new_child_creating",
      data = { window_id = state.current_window_id, node_id = state.selected_node_id },
    })

    vim.notify("新建子分支", vim.log.levels.INFO)

    -- 触发新建子分支完成事件
    vim.api.nvim_exec_autocmds("User", {
      pattern = "NeoAI:tree_node_new_child_created",
      data = { window_id = state.current_window_id, node_id = state.selected_node_id },
    })
  else
    vim.notify("请先选择一个节点", vim.log.levels.WARN)
  end
end

--- 新建根分支（内部使用）
function M._new_root_branch()
  -- 触发新建根分支事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = "NeoAI:tree_node_new_root_creating", data = { window_id = state.current_window_id } }
  )

  vim.notify("新建根分支", vim.log.levels.INFO)

  -- 触发新建根分支完成事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = "NeoAI:tree_node_new_root_created", data = { window_id = state.current_window_id } }
  )
end

--- 删除节点（内部使用）
function M._delete_node()
  if state.selected_node_id then
    -- 触发删除节点事件
    vim.api.nvim_exec_autocmds("User", {
      pattern = "NeoAI:tree_node_deleting",
      data = { window_id = state.current_window_id, node_id = state.selected_node_id },
    })

    vim.notify("删除节点: " .. state.selected_node_id, vim.log.levels.WARN)

    -- 触发删除节点完成事件
    vim.api.nvim_exec_autocmds("User", {
      pattern = "NeoAI:tree_node_deleted",
      data = { window_id = state.current_window_id, node_id = state.selected_node_id },
    })
  end
end

--- 强制删除节点（内部使用）
function M._delete_node_force()
  if state.selected_node_id then
    -- 触发强制删除节点事件
    vim.api.nvim_exec_autocmds("User", {
      pattern = "NeoAI:tree_node_force_deleting",
      data = { window_id = state.current_window_id, node_id = state.selected_node_id },
    })

    vim.notify("强制删除节点: " .. state.selected_node_id, vim.log.levels.ERROR)

    -- 触发强制删除节点完成事件
    vim.api.nvim_exec_autocmds("User", {
      pattern = "NeoAI:tree_node_force_deleted",
      data = { window_id = state.current_window_id, node_id = state.selected_node_id },
    })
  end
end

--- 高亮选中节点（内部使用）
function M._highlight_selected_node()
  -- 这里可以实现语法高亮
  -- 目前是简化实现
end

--- 更新状态行（内部使用）
function M._update_status_line()
  if not state.current_window_id then
    return
  end

  -- 获取当前窗口内容
  local buf = window_manager.get_window_buf(state.current_window_id)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  -- 获取所有行
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #lines == 0 then
    return
  end

  -- 查找状态行和分隔行
  local status_line_index = -1
  local separator_line_index = -1

  for i = #lines, 1, -1 do
    local line = lines[i]
    -- 更宽松的匹配，处理可能的前导空格
    if line:find("当前选中") then
      status_line_index = i - 1 -- 转换为0-based索引
    elseif line == "---" then
      separator_line_index = i - 1 -- 转换为0-based索引
      break -- 找到分隔行后停止，假设状态行在它后面
    end
  end

  -- 如果找到状态行，更新它
  if status_line_index >= 0 then
    local status_text = "当前选中: "

    if state.selected_node_id then
      local node_name = M._get_node_name_by_id(state.selected_node_id)
      if node_name then
        status_text = status_text .. node_name
      else
        status_text = status_text .. state.selected_node_id
      end
    else
      status_text = status_text .. "无"
    end

    -- 确保缓冲区可修改 - 使用新的API
    vim.bo[buf].modifiable = true
    vim.bo[buf].readonly = false

    -- 更新状态行
    vim.api.nvim_buf_set_lines(buf, status_line_index, status_line_index + 1, false, { status_text })

    -- 恢复只读状态 - 使用新的API
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true
  else
    -- 如果没有找到状态行，重新渲染整个树
    M.render_tree()
  end
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
    M.render_tree()
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
  M.render_tree()
  return true
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

--- 测试树窗口创建
--- @return boolean 测试是否成功
function M.test_window_creation()
  if not state.initialized then
    return false
  end

  -- 尝试打开一个测试树窗口
  local window_id = M.open("test_session")

  if window_id then
    -- 成功创建，关闭窗口
    M.close()
    return true
  end

  return false
end

return M
