--- @class HistoryTreeModule
--- @field build_tree fun(session_id: string?): table
--- @field build_tree_async fun(session_id: string?, callback: fun(data: table)): nil
--- @field get_tree_data fun(): table
--- @field set_tree_data fun(data: table): nil
--- @field clear_tree_data fun(): nil
--- @field get_expanded_nodes fun(): table
--- @field set_expanded_nodes fun(nodes: table): nil
--- @field get_selected_node_id fun(): string?
--- @field set_selected_node_id fun(node_id: string?): nil
--- @field initialize fun(config: table): nil
--- @field is_initialized fun(): boolean

local M = {}

-- 模块状态
local state = {
  initialized = false,
  config = nil,
  tree_data = {},
  expanded_nodes = {},
  selected_node_id = nil,
}



--- 初始化历史树组件
--- @param config table 配置
function M.initialize(config)
  if state.initialized then
    return
  end

  state.config = config or {}
  state.initialized = true
end

--- 渲染历史树
--- @param session_id string 会话ID
function M.render(session_id)
  if not state.initialized then
    return nil
  end

  -- 加载树数据
  M._load_tree_data(session_id)

  -- 这里应该返回渲染后的树数据
  -- 目前只是返回树数据
  return state.tree_data
end

--- 展开节点
--- @param node_id string 节点ID
function M.expand_node(node_id)
  if not state.initialized then
    return
  end

  state.expanded_nodes[node_id] = true
end

--- 折叠节点
--- @param node_id string 节点ID
function M.collapse_node(node_id)
  if not state.initialized then
    return
  end

  state.expanded_nodes[node_id] = nil
end

--- 更新历史树
--- @param session_id string 会话ID
--- @param new_data table 新数据
function M.update(session_id, new_data)
  if not state.initialized then
    return
  end

  -- 更新树数据
  state.tree_data = new_data or {}

  -- 触发更新事件
  if state.config.on_update then
    state.config.on_update(session_id, state.tree_data)
  end
end

--- 获取选中的项目
--- @return table|nil 选中的节点
function M.get_selected_item()
  if not state.initialized or not state.selected_node_id then
    return nil
  end

  -- 在树数据中查找选中的节点
  local function find_node(nodes, node_id)
    for _, node in ipairs(nodes) do
      if node.id == node_id then
        return node
      end

      if node.children then
        local found = find_node(node.children, node_id)
        if found then
          return found
        end
      end
    end

    return nil
  end

  return find_node(state.tree_data, state.selected_node_id)
end

--- 选择节点
--- @param node_id string 节点ID
function M.select_node(node_id)
  if not state.initialized then
    return
  end

  state.selected_node_id = node_id
end

--- 更新节点
--- @param node_id string 节点ID
--- @param data table 节点数据
function M.update_node(node_id, data)
  if not state.initialized then
    return
  end

  -- 查找并更新节点
  local function update_node_recursive(nodes)
    for _, node in ipairs(nodes) do
      if node.id == node_id then
        for k, v in pairs(data) do
          node[k] = v
        end
        return true
      end

      if node.children and #node.children > 0 then
        if update_node_recursive(node.children) then
          return true
        end
      end
    end

    return false
  end

  update_node_recursive(state.tree_data)
end

--- 获取选中节点
--- @return string|nil 选中节点ID
function M.get_selected_node()
  return state.selected_node_id
end

--- 获取树数据
--- @return table 树数据
function M.get_tree_data()
  -- 使用vim.deepcopy进行深拷贝
  if vim and vim.deepcopy then
    return vim.deepcopy(state.tree_data)
  else
    -- 简单的深拷贝实现（用于测试）
    local function deepcopy(orig)
      local orig_type = type(orig)
      local copy
      if orig_type == "table" then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
          copy[deepcopy(orig_key)] = deepcopy(orig_value)
        end
        setmetatable(copy, deepcopy(getmetatable(orig)))
      else
        copy = orig
      end
      return copy
    end
    return deepcopy(state.tree_data)
  end
end

--- 获取展开的节点
--- @return table 展开的节点ID列表
function M.get_expanded_nodes()
  local nodes = {}
  for node_id, _ in pairs(state.expanded_nodes) do
    table.insert(nodes, node_id)
  end
  return nodes
end

--- 清空树数据
function M.clear()
  state.tree_data = {}
  state.expanded_nodes = {}
  state.selected_node_id = nil
end

--- 查找节点
--- @param predicate function 谓词函数
--- @return table|nil 找到的节点
function M.find_node(predicate)
  if not state.initialized or type(predicate) ~= "function" then
    return nil
  end

  local function find_recursive(nodes)
    for _, node in ipairs(nodes) do
      if predicate(node) then
        return node
      end

      if node.children and #node.children > 0 then
        local found = find_recursive(node.children)
        if found then
          return found
        end
      end
    end

    return nil
  end

  return find_recursive(state.tree_data)
end

--- 获取节点路径
--- @param node_id string 节点ID
--- @return table 节点路径
function M.get_node_path(node_id)
  if not state.initialized then
    return {}
  end

  local path = {}

  local function find_path_recursive(nodes, current_path)
    for _, node in ipairs(nodes) do
      local new_path = {}
      for _, v in ipairs(current_path) do
        table.insert(new_path, v)
      end
      table.insert(new_path, node.id)

      if node.id == node_id then
        return new_path
      end

      if node.children and #node.children > 0 then
        local found = find_path_recursive(node.children, new_path)
        if found then
          return found
        end
      end
    end

    return nil
  end

  return find_path_recursive(state.tree_data, {}) or {}
end

--- 获取子节点
--- @param node_id string 节点ID
--- @return table 子节点列表
function M.get_children(node_id)
  if not state.initialized then
    return {}
  end

  local node = M.find_node(function(n)
    return n.id == node_id
  end)

  if node and node.children then
    -- 深拷贝子节点
    if vim and vim.deepcopy then
      return vim.deepcopy(node.children)
    else
      local copy = {}
      for i, child in ipairs(node.children) do
        copy[i] = { id = child.id, name = child.name, type = child.type }
        if child.children then
          copy[i].children = {}
          for j, grandchild in ipairs(child.children) do
            copy[i].children[j] = { id = grandchild.id, name = grandchild.name, type = grandchild.type }
          end
        end
      end
      return copy
    end
  end

  return {}
end

--- 获取父节点
--- @param node_id string 节点ID
--- @return table|nil 父节点
function M.get_parent(node_id)
  if not state.initialized then
    return nil
  end

  local function find_parent_recursive(nodes, parent)
    for _, node in ipairs(nodes) do
      if node.id == node_id then
        return parent
      end

      if node.children and #node.children > 0 then
        local found = find_parent_recursive(node.children, node)
        if found then
          return found
        end
      end
    end

    return nil
  end

  return find_parent_recursive(state.tree_data, nil)
end

--- 构建树
--- @param session_id string 会话ID
--- @return table 构建的树数据
function M.build_tree(session_id)
  if not state.initialized then
    return {}
  end

  -- 加载树数据
  M._load_tree_data(session_id)

  -- 返回构建的树数据
  return M.get_tree_data()
end

--- 刷新树
--- @param session_id string 会话ID
function M.refresh(session_id)
  if not state.initialized then
    return
  end

  -- 重新加载树数据
  M._load_tree_data(session_id)

  -- 触发更新事件
  if state.config.on_update then
    state.config.on_update(session_id, state.tree_data)
  end

  if vim and vim.notify then
    vim.notify("历史树已刷新", vim.log.levels.INFO)
  end
end

--- 获取指定行的节点
--- @param line_number number 行号（1-based）
--- @return table|nil 节点数据
function M.get_node_at_line(line_number)
  if not state.initialized then
    return nil
  end

  -- 这里需要根据实际的树渲染逻辑来获取节点
  -- 由于我们不知道具体的渲染实现，这里返回一个模拟节点
  if line_number > 0 and line_number <= #state.tree_data then
    if vim and vim.deepcopy then
      return vim.deepcopy(state.tree_data[line_number])
    else
      local node = state.tree_data[line_number]
      return { id = node.id, name = node.name, type = node.type }
    end
  end

  return nil
end

--- 查找节点的父节点
--- @param node_id string 节点ID
--- @return table|nil 父节点，如果找不到返回nil
function M.find_parent(node_id)
  if not state.initialized then
    return nil
  end

  local function find_parent_recursive(nodes, parent)
    for _, node in ipairs(nodes) do
      if node.id == node_id then
        return parent
      end

      if node.children and #node.children > 0 then
        local found = find_parent_recursive(node.children, node)
        if found then
          return found
        end
      end
    end

    return nil
  end

  return find_parent_recursive(state.tree_data, nil)
end

--- 添加节点
--- @param parent_id string|nil 父节点ID
--- @param node_data table 节点数据
--- @return boolean 是否添加成功
function M.add_node(parent_id, node_data)
  if not state.initialized or not node_data or not node_data.id then
    return false
  end

  if not parent_id then
    -- 添加到根节点
    table.insert(state.tree_data, node_data)
    return true
  end

  local parent = M.find_node(function(n)
    return n.id == parent_id
  end)

  if not parent then
    return false
  end

  if not parent.children then
    parent.children = {}
  end

  table.insert(parent.children, node_data)
  return true
end

--- 删除节点
--- @param node_id string 节点ID
--- @return boolean 是否删除成功
function M.delete_node(node_id)
  if not state.initialized then
    return false
  end

  local function delete_recursive(nodes)
    for i, node in ipairs(nodes) do
      if node.id == node_id then
        table.remove(nodes, i)

        -- 从展开节点中移除
        state.expanded_nodes[node_id] = nil

        -- 如果删除的是选中节点，清空选中
        if state.selected_node_id == node_id then
          state.selected_node_id = nil
        end

        return true
      end

      if node.children and #node.children > 0 then
        if delete_recursive(node.children) then
          return true
        end
      end
    end

    return false
  end

  return delete_recursive(state.tree_data)
end

--- 移动节点
--- @param node_id string 节点ID
--- @param new_parent_id string 新父节点ID
--- @return boolean 是否移动成功
function M.move_node(node_id, new_parent_id)
  if not state.initialized then
    return false
  end

  -- 查找节点
  local node_to_move = nil
  local old_parent_nodes = nil
  local node_index = nil

  local function find_node_recursive(nodes, parent_nodes)
    for i, node in ipairs(nodes) do
      if node.id == node_id then
        node_to_move = node
        old_parent_nodes = parent_nodes or nodes
        node_index = i
        return true
      end

      if node.children and #node.children > 0 then
        if find_node_recursive(node.children, node.children) then
          return true
        end
      end
    end

    return false
  end

  if not find_node_recursive(state.tree_data) then
    return false
  end

  -- 从原位置移除
  if old_parent_nodes and node_index then
    table.remove(old_parent_nodes, node_index)
  else
    return false
  end

  -- 添加到新位置
  if not new_parent_id then
    -- 移动到根节点
    table.insert(state.tree_data, node_to_move)
  else
    local new_parent = M.find_node(function(n)
      return n.id == new_parent_id
    end)

    if not new_parent then
      -- 如果找不到新父节点，回滚
      if old_parent_nodes and node_index then
        table.insert(old_parent_nodes, node_index, node_to_move)
      end
      return false
    end

    if not new_parent.children then
      new_parent.children = {}
    end

    table.insert(new_parent.children, node_to_move)
  end

  return true
end

--- 加载树数据（内部使用）
--- @param session_id string 会话ID
function M._load_tree_data(session_id)
  -- 清空现有数据
  state.tree_data = {}

  -- 优先从文件系统加载会话数据
  local sessions = M._load_sessions_from_file()

  -- 如果文件没有数据，再尝试从历史管理器加载
  if not sessions or #sessions == 0 then
    local history_manager = require("NeoAI.core.history_manager")

    -- 确保历史管理器已初始化
    -- 尝试调用 get_sessions，如果失败则初始化
    local success, result = pcall(function()
      return history_manager.get_sessions()
    end)

    if not success then
      -- 历史管理器未初始化，使用配置初始化
      local config = state.config or {}
      history_manager.initialize({
        save_path = config.save_path or os.getenv("HOME") .. "/.cache/nvim/NeoAI",
        auto_save = config.auto_save or false,
        auto_load = config.auto_load ~= false,
        max_history_per_session = config.max_messages_per_session or 100,
      })
      sessions = history_manager.get_sessions()
    else
      sessions = result
    end
  end

  -- 如果还是没有数据，尝试从会话管理器加载
  if not sessions or #sessions == 0 then
    local session_manager = require("NeoAI.core.session.session_manager")
    sessions = session_manager.list_sessions()
  end

  -- 转换会话数据为树节点
  for _, session in ipairs(sessions) do
    local session_node = {
      id = "session_" .. session.id,
      name = session.name or "未命名会话",
      type = "session",
      metadata = {
        message_count = session.metadata and session.metadata.message_count or 0,
        created_at = session.metadata and session.metadata.created_at or os.time(),
        last_updated = session.metadata and session.metadata.last_updated or os.time(),
      },
      children = {},
      raw_data = session, -- 保存原始数据供后续使用
    }

    -- 如果这是当前会话，添加标记
    if session_id and tostring(session.id) == tostring(session_id) then
      session_node.name = session_node.name .. " (当前)"
      session_node.metadata.is_current = true
    end

    -- 尝试加载会话的消息作为子节点
    M._load_session_messages(session, session_node)

    table.insert(state.tree_data, session_node)

    -- 默认展开当前会话
    if session_node.metadata.is_current then
      state.expanded_nodes[session_node.id] = true
    end
  end

  -- 如果没有数据，使用模拟数据作为后备
  if #state.tree_data == 0 then
    M._load_fallback_data()
  end

  -- 按最后更新时间排序
  table.sort(state.tree_data, function(a, b)
    return (a.metadata.last_updated or 0) > (b.metadata.last_updated or 0)
  end)
end

--- 从文件系统加载会话数据
--- @return table 会话列表
function M._load_sessions_from_file()
  local sessions = {}

  -- 获取保存路径
  local config = state.config or {}
  local save_path = config.save_path or os.getenv("HOME") .. "/.cache/nvim/NeoAI"
  local sessions_file = save_path .. "/sessions.json"

  -- 检查文件是否存在
  if vim.fn.filereadable(sessions_file) == 1 then
    local content = vim.fn.readfile(sessions_file)
    if #content > 0 then
      local success, data = pcall(vim.json.decode, table.concat(content, "\n"))
      if success and data then
        -- 转换数据格式
        for session_id, session_data in pairs(data) do
          -- 跳过 _graph 等元数据键
          if type(session_data) == "table" and session_id ~= "_graph" then
            -- 使用会话ID作为会话标识符
            local session_name = session_data.name or ("会话 " .. session_id)
            local message_count = #(session_data.messages or {})

            table.insert(sessions, {
              id = session_id,
              name = session_name,
              metadata = {
                message_count = message_count,
                created_at = session_data.created_at or os.time(),
                last_updated = session_data.updated_at or os.time(),
              },
              messages = session_data.messages or {},
            })
          end
        end
      end
    end
  end

  return sessions
end

--- UTF-8 安全截断辅助函数
--- @param str string 要截断的字符串
--- @param max_chars number 最大字符数
--- @return string 截断后的字符串
local function safe_utf8_truncate(str, max_chars)
  if not str or #str == 0 or max_chars <= 0 then
    return ""
  end

  -- 如果有 vim.str_utfindex，使用它
  if vim and vim.str_utfindex then
    -- vim.str_utfindex 需要两个参数：字符串和编码
    -- 要获取 UTF-8 字符数，传递 "utf-8"
    local char_count = vim.str_utfindex(str, "utf-8")
    if char_count <= max_chars then
      return str
    end

    -- 确保 max_chars + 1 在有效范围内
    local target_char = max_chars + 1
    if target_char > char_count + 1 then
      target_char = char_count + 1
    elseif target_char < 1 then
      target_char = 1
    end

    -- 使用 pcall 安全地调用 vim.str_byteindex
    local ok, byte_end = pcall(vim.str_byteindex, str, target_char)
    if not ok or not byte_end then
      byte_end = #str + 1
    end

    return str:sub(1, byte_end - 1) .. "..."
  end

  -- 纯 Lua 环境下的 UTF-8 安全处理
  local result = ""
  local byte_pos = 1
  local char_pos = 0

  while byte_pos <= #str and char_pos < max_chars do
    local byte = str:byte(byte_pos)
    local char_len = 1

    -- 检测 UTF-8 字符长度
    if byte >= 0xF0 then
      char_len = 4
    elseif byte >= 0xE0 then
      char_len = 3
    elseif byte >= 0xC0 then
      char_len = 2
    end

    -- 确保有足够的字节
    if byte_pos + char_len - 1 <= #str then
      result = result .. str:sub(byte_pos, byte_pos + char_len - 1)
      byte_pos = byte_pos + char_len
      char_pos = char_pos + 1
    else
      break
    end
  end

  if char_pos >= max_chars and byte_pos <= #str then
    result = result .. "..."
  end

  return result
end

--- 获取 UTF-8 字符串的字符数
--- @param str string 要计算长度的字符串
--- @return number 字符串的字符数
local function utf8_len(str)
  if not str then
    return 0
  end

  -- 如果有 vim.str_utfindex，使用它
  if vim and vim.str_utfindex then
    -- vim.str_utfindex 需要两个参数：字符串和编码
    -- 要获取 UTF-8 字符数，传递 "utf-8"
    return vim.str_utfindex(str, "utf-8")
  end

  -- 纯 Lua 环境下的 UTF-8 字符计数
  local count = 0
  local i = 1
  while i <= #str do
    local byte = str:byte(i)
    if byte >= 0xF0 then
      i = i + 4
    elseif byte >= 0xE0 then
      i = i + 3
    elseif byte >= 0xC0 then
      i = i + 2
    else
      i = i + 1
    end
    count = count + 1
  end
  return count
end

--- UTF-8 安全子字符串函数
--- @param str string 要截取的字符串
--- @param start_char number 起始字符位置（1-based）
--- @param end_char number 结束字符位置（1-based）
--- @return string 截取后的字符串
local function safe_utf8_sub(str, start_char, end_char)
  if not str or #str == 0 then
    return ""
  end

  -- 获取字符串的字符数
  local char_count = utf8_len(str)
  if char_count == 0 then
    return ""
  end

  -- 参数验证和边界检查
  if start_char < 1 then
    start_char = 1
  end

  if end_char > char_count then
    end_char = char_count
  end

  if start_char > end_char then
    return ""
  end

  -- 如果有 vim.str_utfindex，使用它
  if vim and vim.str_utfindex then
    -- 确保索引在有效范围内
    if start_char > char_count or start_char < 1 then
      return ""
    end

    -- 在 Neovim 0.12.0 中，vim.str_byteindex 对边界条件更严格
    -- 确保 end_char + 1 不超过 char_count + 1
    local end_char_plus_one = end_char + 1
    if end_char_plus_one > char_count + 1 then
      end_char_plus_one = char_count + 1
    end

    -- 确保 end_char_plus_one 在有效范围内（1 到 char_count+1）
    if end_char_plus_one < 1 then
      end_char_plus_one = 1
    elseif end_char_plus_one > char_count + 1 then
      end_char_plus_one = char_count + 1
    end

    -- 确保 start_char 在有效范围内（1 到 char_count）
    if start_char < 1 then
      start_char = 1
    elseif start_char > char_count then
      start_char = char_count
    end

    -- 使用 pcall 安全地调用 vim.str_byteindex
    local ok_start, byte_start = pcall(vim.str_byteindex, str, start_char)
    local ok_end, byte_end = pcall(vim.str_byteindex, str, end_char_plus_one)

    if not ok_start or not byte_start then
      return ""
    end

    -- 确保 byte_end 有效
    if not ok_end or not byte_end then
      byte_end = #str + 1
    end

    -- 确保 byte_start 和 byte_end 在有效范围内
    if byte_start < 1 then
      byte_start = 1
    end
    if byte_end > #str + 1 then
      byte_end = #str + 1
    end
    if byte_start > byte_end then
      byte_start = byte_end
    end

    return str:sub(byte_start, byte_end - 1)
  end

  -- 纯 Lua 环境下的 UTF-8 安全处理
  local result = ""
  local byte_pos = 1
  local char_pos = 0

  while byte_pos <= #str and char_pos < end_char do
    local byte = str:byte(byte_pos)
    local char_len = 1

    -- 检测 UTF-8 字符长度
    if byte >= 0xF0 then
      char_len = 4
    elseif byte >= 0xE0 then
      char_len = 3
    elseif byte >= 0xC0 then
      char_len = 2
    end

    -- 确保有足够的字节
    if byte_pos + char_len - 1 <= #str then
      if char_pos >= start_char - 1 then
        result = result .. str:sub(byte_pos, byte_pos + char_len - 1)
      end
      byte_pos = byte_pos + char_len
      char_pos = char_pos + 1
    else
      break
    end
  end

  return result
end

--- @return string 前5个字
local function extract_first_five_words(message)
  if not message then
    return ""
  end

  -- 处理不同类型的消息格式
  local content
  if type(message) == "string" then
    content = message
  elseif message.content then
    content = message.content
  elseif message.text then
    content = message.text
  elseif message.message then
    content = message.message
  else
    return ""
  end

  if not content or type(content) ~= "string" or #content == 0 then
    return ""
  end

  -- 移除换行符和多余空格
  content = content:gsub("\n", " "):gsub("\r", " ")
  content = content:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")

  -- 按空格分割成单词，使用 UTF-8 安全的方法
  local words = {}
  local word_start = nil
  local in_word = false

  -- 使用 UTF-8 安全的字符遍历
  local char_count = utf8_len(content)
  local byte_pos = 1

  for char_idx = 1, char_count do
    -- 获取当前字符的字节位置
    local byte_start = byte_pos
    local char_len = 1

    if byte_pos <= #content then
      local byte = content:byte(byte_pos)
      if byte >= 0xF0 then
        char_len = 4
      elseif byte >= 0xE0 then
        char_len = 3
      elseif byte >= 0xC0 then
        char_len = 2
      end

      -- 确保有足够的字节
      if byte_pos + char_len - 1 > #content then
        char_len = 1
      end

      local char_str = content:sub(byte_pos, byte_pos + char_len - 1)
      local is_space = char_str:match("%s")

      if not is_space and not in_word then
        -- 单词开始
        word_start = char_idx
        in_word = true
      elseif is_space and in_word then
        -- 单词结束
        -- 确保 char_idx - 1 不小于 word_start
        local end_idx = char_idx - 1
        if word_start and end_idx >= word_start then
          local word = safe_utf8_sub(content, word_start, end_idx)
          if word and #word > 0 then
            table.insert(words, word)
          end
        end
        in_word = false
        word_start = nil
      end

      byte_pos = byte_pos + char_len
    else
      break
    end
  end

  -- 处理最后一个单词
  if in_word and word_start then
    local char_count = utf8_len(content)
    -- 确保 word_start 不超过 char_count 且大于 0
    if word_start >= 1 and word_start <= char_count then
      local word = safe_utf8_sub(content, word_start, char_count)
      if word and #word > 0 then
        table.insert(words, word)
      end
    end
  end

  -- 取前5个字，但限制总长度
  local result = {}
  local total_length = 0
  local max_length = 30 -- 限制总长度，避免显示过长

  for i = 1, math.min(5, #words) do
    local word = words[i]
    if total_length + #word <= max_length then
      table.insert(result, word)
      total_length = total_length + #word + 1 -- +1 用于空格
    else
      -- 如果添加这个单词会超过长度限制，添加省略号并停止
      if #result > 0 then
        result[#result] = result[#result] .. "..."
      end
      break
    end
  end

  return table.concat(result, " ")
end

--- 加载会话消息作为子节点
--- @param session table 会话数据
--- @param session_node table 会话节点
function M._load_session_messages(session, session_node)
  if not session or not session_node then
    return
  end

  -- 首先加载分支数据
  M._load_session_branches(session, session_node)

  -- 获取消息数据
  local messages = session.messages or {}

  -- 如果没有消息数据，尝试从其他来源获取
  if #messages == 0 and session.raw_data and session.raw_data.messages then
    messages = session.raw_data.messages
  end

  -- 限制显示的消息数量
  local max_messages = state.config and state.config.max_messages_per_session or 20
  local display_messages = {}

  for i = math.max(1, #messages - max_messages + 1), #messages do
    table.insert(display_messages, messages[i])
  end

  -- 按照一轮（user-assistant 配对）分组消息
  local conversation_rounds = {}
  local current_round = nil

  for i, msg in ipairs(display_messages) do
    local msg_role = msg.role or "unknown"

    -- 如果是用户消息，开始新的一轮
    if msg_role == "user" then
      current_round = {
        id = "round_" .. session.id .. "_" .. i,
        messages = {},
        user_message = msg,
        assistant_message = nil,
        round_number = #conversation_rounds + 1,
      }
      table.insert(current_round.messages, msg)
      table.insert(conversation_rounds, current_round)

    -- 如果是助手消息，添加到当前轮
    elseif msg_role == "assistant" and current_round then
      current_round.assistant_message = msg
      table.insert(current_round.messages, msg)

      -- 重置当前轮，准备下一轮
      current_round = nil

    -- 其他类型的消息（如 tool），添加到当前轮或作为独立消息
    elseif current_round then
      table.insert(current_round.messages, msg)
    else
      -- 独立消息（没有配对的 user/assistant）
      local standalone_round = {
        id = "round_" .. session.id .. "_" .. i,
        messages = { msg },
        user_message = nil,
        assistant_message = nil,
        round_number = #conversation_rounds + 1,
        is_standalone = true,
      }
      table.insert(conversation_rounds, standalone_round)
    end
  end

  -- 创建对话轮次节点
  for _, round in ipairs(conversation_rounds) do
    -- 提取用户和AI消息的前5个字
    local user_preview = ""
    local ai_preview = ""

    if round.user_message then
      user_preview = extract_first_five_words(round.user_message)
    end

    if round.assistant_message then
      ai_preview = extract_first_five_words(round.assistant_message)
    end

    -- 构建节点名称
    local node_name = "第" .. round.round_number .. "轮"
    if user_preview ~= "" then
      node_name = node_name .. " 用户:" .. user_preview
    end
    if ai_preview ~= "" then
      node_name = node_name .. " AI:" .. ai_preview
    end

    local round_node = {
      id = round.id,
      name = node_name,
      type = "conversation_round",
      metadata = {
        round_number = round.round_number,
        message_count = #round.messages,
        has_user = round.user_message ~= nil,
        has_assistant = round.assistant_message ~= nil,
        is_standalone = round.is_standalone or false,
      },
      children = {},
      raw_data = round,
    }

    -- 为每轮对话创建消息子节点
    for j, msg in ipairs(round.messages) do
      local msg_content = msg.content or ""

      -- 移除消息内容中的换行符
      msg_content = msg_content:gsub("\n", " "):gsub("\r", " ")

      -- 使用 UTF-8 安全截断函数
      local truncated_content = safe_utf8_truncate(msg_content, 50)

      local msg_node = {
        id = "msg_" .. session.id .. "_" .. (msg.id or (round.round_number .. "_" .. j)),
        name = "[" .. (msg.role or "unknown") .. "] " .. truncated_content,
        type = "message",
        metadata = {
          role = msg.role,
          timestamp = msg.timestamp or os.time(),
          full_content = msg_content,
          message_id = msg.id,
          round_number = round.round_number,
        },
        children = {},
        raw_data = msg,
      }

      table.insert(round_node.children, msg_node)
    end

    table.insert(session_node.children, round_node)
  end

  -- 更新消息计数
  session_node.metadata.message_count = #messages
end

--- 加载后备数据（模拟数据）
function M._load_fallback_data()
  state.tree_data = {
    {
      id = "session_1",
      name = "示例会话",
      type = "session",
      metadata = {
        message_count = 6,
        created_at = os.time() - 3600,
        last_updated = os.time() - 1800,
      },
      children = {
        {
          id = "round_1_1",
          name = "第1轮 用户:你好 AI:你好！有什么可以帮助你的？",
          type = "conversation_round",
          metadata = {
            round_number = 1,
            message_count = 2,
            has_user = true,
            has_assistant = true,
            is_standalone = false,
          },
          children = {
            {
              id = "msg_1_1_1",
              name = "[user] 你好",
              type = "message",
              metadata = {
                role = "user",
                timestamp = os.time() - 3600,
                full_content = "你好",
                round_number = 1,
              },
              children = {},
            },
            {
              id = "msg_1_1_2",
              name = "[assistant] 你好！有什么可以帮助你的？",
              type = "message",
              metadata = {
                role = "assistant",
                timestamp = os.time() - 3500,
                full_content = "你好！有什么可以帮助你的？",
                round_number = 1,
              },
              children = {},
            },
          },
        },
        {
          id = "round_1_2",
          name = "第2轮 用户:当前目录下有什么 AI:🔧 正在执行工具...",
          type = "conversation_round",
          metadata = {
            round_number = 2,
            message_count = 4,
            has_user = true,
            has_assistant = true,
            is_standalone = false,
          },
          children = {
            {
              id = "msg_1_2_1",
              name = "[user] 当前目录下有什么",
              type = "message",
              metadata = {
                role = "user",
                timestamp = os.time() - 3400,
                full_content = "当前目录下有什么",
                round_number = 2,
              },
              children = {},
            },
            {
              id = "msg_1_2_2",
              name = "[assistant] 🔧 正在执行工具...",
              type = "message",
              metadata = {
                role = "assistant",
                timestamp = os.time() - 3300,
                full_content = "🔧 正在执行工具...",
                round_number = 2,
              },
              children = {},
            },
            {
              id = "msg_1_2_3",
              name = "[tool] ",
              type = "message",
              metadata = {
                role = "tool",
                timestamp = os.time() - 3200,
                full_content = "",
                round_number = 2,
              },
              children = {},
            },
            {
              id = "msg_1_2_4",
              name = "[assistant] 根据查看，当前目录下有以下文件...",
              type = "message",
              metadata = {
                role = "assistant",
                timestamp = os.time() - 3100,
                full_content = "根据查看，当前目录下有以下文件...",
                round_number = 2,
              },
              children = {},
            },
          },
        },
      },
    },
  }

  -- 默认展开根节点
  for _, root_node in ipairs(state.tree_data) do
    state.expanded_nodes[root_node.id] = true
  end
end

--- 更新配置
--- @param new_config table 新配置
function M.update_config(new_config)
  if not state.initialized then
    return
  end

  state.config = vim.tbl_extend("force", state.config, new_config or {})
end

-- 测试函数
local function test_module()
  print("=== 测试历史树模块 ===")

  -- 初始化模块
  M.initialize({
    on_update = function(session_id, data)
      print("配置更新回调: 会话ID=" .. (session_id or "nil") .. ", 数据节点数=" .. #data)
    end,
  })

  -- 构建树
  local tree_data = M.build_tree("test_session")
  print("树数据加载完成，根节点数: " .. #tree_data)

  -- 展开节点
  M.expand_node("branch_1")
  print("已展开节点: branch_1")

  -- 选择节点
  M.select_node("branch_2")
  print("已选择节点: " .. (M.get_selected_node() or "nil"))

  -- 获取选中项目
  local selected = M.get_selected_item()
  if selected then
    print("选中节点名称: " .. selected.name)
  end

  -- 获取展开节点
  local expanded = M.get_expanded_nodes()
  print("展开节点数: " .. #expanded)

  -- 添加新节点
  local new_node = {
    id = "new_node_1",
    name = "新节点",
    type = "message",
    content = "测试消息",
  }

  local added = M.add_node("branch_2", new_node)
  print("添加节点结果: " .. tostring(added))

  -- 查找节点
  local found = M.find_node(function(node)
    return node.name == "新节点"
  end)

  if found then
    print("找到节点: " .. found.id)
  end

  -- 获取父节点
  local parent = M.get_parent("new_node_1")
  if parent then
    print("父节点: " .. parent.name)
  end

  -- 删除节点
  local deleted = M.delete_node("new_node_1")
  print("删除节点结果: " .. tostring(deleted))

  -- 移动节点
  local moved = M.move_node("branch_2", "session_2")
  print("移动节点结果: " .. tostring(moved))

  -- 刷新树
  M.refresh("test_session")

  print("=== 测试完成 ===")
end

-- 运行测试
if not vim then
  -- 非Neovim环境下运行测试
  test_module()
end

--- 异步构建树
--- @param session_id string 会话ID
--- @param callback function 回调函数
function M.build_tree_async(session_id, callback)
  if not state.initialized then
    if callback then
      callback({})
    end
    return
  end

  -- 使用异步工作器
  local async_worker = require("NeoAI.utils.async_worker")

  async_worker.submit_task("build_history_tree", function()
    -- 在后台线程中加载树数据
    M._load_tree_data(session_id)

    -- 返回构建的树数据
    return M.get_tree_data()
  end, function(success, tree_data, error_msg)
    if callback then
      if success then
        callback(tree_data)
      else
        -- 如果异步失败，回退到同步版本
        local fallback_data = M.build_tree(session_id)
        callback(fallback_data)
      end
    end
  end)
end

--- 加载会话的分支数据
--- @param session table 会话数据
--- @param session_node table 会话节点
function M._load_session_branches(session, session_node)
  if not session or not session_node then
    return
  end

  -- 获取分支数据
  local branches = session.branches or {}
  
  -- 如果没有分支数据，尝试从其他来源获取
  if #branches == 0 and session.raw_data and session.raw_data.branches then
    branches = session.raw_data.branches
  end
  
  -- 如果没有分支数据，尝试从分支管理器获取
  if #branches == 0 then
    local branch_manager_loaded, branch_manager = pcall(require, "NeoAI.core.session.branch_manager")
    if branch_manager_loaded and branch_manager then
      -- 尝试获取分支树
      local success, branch_tree = pcall(branch_manager.get_branch_tree, session.id)
      if success and branch_tree then
        -- 转换分支树为节点格式
        for _, branch in ipairs(branch_tree) do
          table.insert(branches, branch)
        end
      end
    end
  end
  
  -- 创建分支节点
  for _, branch in ipairs(branches) do
    local branch_node = {
      id = "branch_" .. (branch.id or #session_node.children + 1),
      name = branch.name or "未命名分支",
      type = "branch",
      metadata = {
        created_at = branch.created_at or os.time(),
        message_count = branch.message_count or 0,
        branch_id = branch.id,
        parent_branch_id = branch.parent_id,
      },
      children = {},
      raw_data = branch,
    }
    
    -- 如果是当前分支，添加标记
    if session.current_branch_id and branch.id == session.current_branch_id then
      branch_node.name = branch_node.name .. " (当前)"
      branch_node.metadata.is_current = true
    end
    
    table.insert(session_node.children, branch_node)
    
    -- 默认展开当前分支
    if branch_node.metadata.is_current then
      state.expanded_nodes[branch_node.id] = true
    end
  end
  
  -- 按创建时间排序分支
  table.sort(session_node.children, function(a, b)
    return (a.metadata.created_at or 0) > (b.metadata.created_at or 0)
  end)
end

return M
