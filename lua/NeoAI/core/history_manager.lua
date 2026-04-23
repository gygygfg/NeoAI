--- NeoAI 会话历史管理器
--- 使用 JSON 数组文件存储会话数据
--- 文件格式: [\n{...},\n{...}\n]
--- 每个会话对象（扁平结构，一轮对话一个会话）:
--- {
---   id: "session_1",
---   name: "会话名称",
---   created_at: 1234567890,
---   updated_at: 1234567890,
---   is_root: true,
---   child_ids: [],
---   user: "用户消息",
---   assistant: '{"content":"...","reasoning_content":"..."}',
---   timestamp: 1234567890,
---   usage: { prompt_tokens: 24, completion_tokens: 770, total_tokens: 794 }
--- }

local M = {}

local state = {
  initialized = false,
  config = nil,
  sessions = {},
  current_session_id = nil,
  save_debounce_timer = nil,
}

--- 获取存储文件路径
local function get_filepath()
  local save_path = state.config.save_path
  if not save_path or save_path == "" then
    save_path = vim.fn.stdpath("cache") .. "/NeoAI"
  end
  return save_path .. "/sessions.json"
end

--- 防抖保存
local function debounce_save()
  if not state.config.auto_save then
    return
  end
  if state.save_debounce_timer then
    state.save_debounce_timer:stop()
    state.save_debounce_timer:close()
    state.save_debounce_timer = nil
  end
  state.save_debounce_timer = vim.loop.new_timer()
  state.save_debounce_timer:start(
    500,
    0,
    vim.schedule_wrap(function()
      if state.save_debounce_timer then
        state.save_debounce_timer:close()
        state.save_debounce_timer = nil
      end
      M._save()
    end)
  )
end

--- 触发事件
local function trigger_event(name, data)
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = name, data = data or {} })
end

--- 生成会话ID
local function generate_id()
  local max_num = 0
  for id, _ in pairs(state.sessions) do
    local num = tonumber(id:match("session_(%d+)"))
    if num and num > max_num then
      max_num = num
    end
  end
  return "session_" .. (max_num + 1)
end

--- 初始化
function M.initialize(options)
  if state.initialized then
    return
  end
  options = options or {}
  state.config = vim.deepcopy(options.config or options or {})
  if state.config.session and type(state.config.session) == "table" then
    for k, v in pairs(state.config.session) do
      state.config[k] = v
    end
    state.config.session = nil
  end
  state.config.auto_save = state.config.auto_save ~= false
  state.sessions = {}
  state.current_session_id = nil
  M._load()
  state.initialized = true
end

--- 加载会话数据
function M._load()
  local filepath = get_filepath()
  local dir = filepath:match("(.*/)")
  if dir and vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  if vim.fn.filereadable(filepath) ~= 1 then
    vim.fn.writefile({ "[" }, filepath)
    vim.fn.writefile({ "]" }, filepath, "a")
    return
  end
  local ok, data = pcall(function()
    local lines = vim.fn.readfile(filepath)
    if #lines == 0 then
      return {}
    end
    local content = table.concat(lines, "\n")
    if content == "[" or content == "[]" then
      return {}
    end
    return vim.json.decode(content)
  end)
  if not ok or type(data) ~= "table" then
    state.sessions = {}
    return
  end
  for _, session in ipairs(data) do
    if session and session.id then
      state.sessions[session.id] = session
    end
  end
end

--- 保存会话数据到文件
function M._save()
  local filepath = get_filepath()
  local dir = filepath:match("(.*/)")
  if dir and vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  local arr = {}
  for _, session in pairs(state.sessions) do
    table.insert(arr, session)
  end
  table.sort(arr, function(a, b)
    return (a.created_at or 0) < (b.created_at or 0)
  end)
  if #arr == 0 then
    vim.fn.writefile({ "[" }, filepath)
    vim.fn.writefile({ "]" }, filepath, "a")
    return
  end
  local lines = {}
  table.insert(lines, "[")
  for i, session in ipairs(arr) do
    local json = vim.json.encode(session)
    if i < #arr then
      table.insert(lines, json .. ",")
    else
      table.insert(lines, json)
    end
  end
  table.insert(lines, "]")
  vim.fn.writefile(lines, filepath)
end

--- 创建新会话（扁平结构，一轮对话一个会话）
--- @param name string 会话名称
--- @param is_root boolean 是否为根会话
--- @param parent_id string|nil 父会话ID（如果是子会话）
--- @return string 会话ID
function M.create_session(name, is_root, parent_id)
  if not state.initialized then
    error("History manager not initialized")
  end
  local id = generate_id()
  local session = {
    id = id,
    name = name or "新会话",
    created_at = os.time(),
    updated_at = os.time(),
    is_root = (parent_id == nil and is_root ~= false) or (is_root == true),
    child_ids = {},
    user = "",
    assistant = "",
    timestamp = nil,
    usage = {},
  }
  state.sessions[id] = session
  if parent_id and state.sessions[parent_id] then
    table.insert(state.sessions[parent_id].child_ids, id)
    state.sessions[parent_id].updated_at = os.time()
  end
  state.current_session_id = id
  debounce_save()
  trigger_event("NeoAI:session_created", { session_id = id, session = session })
  return id
end

--- 获取会话
function M.get_session(session_id)
  if not session_id then
    return nil
  end
  return state.sessions[session_id]
end

--- 获取当前会话
function M.get_current_session()
  if not state.current_session_id then
    return nil
  end
  return state.sessions[state.current_session_id]
end

--- 设置当前会话
function M.set_current_session(session_id)
  if not state.sessions[session_id] then
    return false
  end
  state.current_session_id = session_id
  trigger_event("NeoAI:session_changed", { session_id = session_id })
  return true
end

--- 获取或创建当前会话
function M.get_or_create_current_session(name)
  if state.current_session_id and state.sessions[state.current_session_id] then
    return state.sessions[state.current_session_id]
  end
  local id = M.create_session(name or "聊天会话", true, nil)
  return state.sessions[id]
end

--- 删除会话
function M.delete_session(session_id)
  local session = state.sessions[session_id]
  if not session then
    return false
  end
  for _, s in pairs(state.sessions) do
    for i, cid in ipairs(s.child_ids) do
      if cid == session_id then
        table.remove(s.child_ids, i)
        s.updated_at = os.time()
        break
      end
    end
  end
  local function delete_children(ids)
    for _, cid in ipairs(ids) do
      local child = state.sessions[cid]
      if child then
        delete_children(child.child_ids or {})
        state.sessions[cid] = nil
      end
    end
  end
  delete_children(session.child_ids or {})
  state.sessions[session_id] = nil
  if state.current_session_id == session_id then
    state.current_session_id = nil
  end
  debounce_save()
  trigger_event("NeoAI:session_deleted", { session_id = session_id })
  return true
end

--- 添加一轮对话（扁平结构：直接设置 user/assistant/timestamp）
--- @param session_id string 会话ID
--- @param user_msg string 用户消息
--- @param assistant_msg string AI回复（JSON字符串，含 content 和 reasoning_content）
--- @param usage table|nil token用量
--- @return table|nil
function M.add_round(session_id, user_msg, assistant_msg, usage)
  local session = state.sessions[session_id]
  if not session then
    return nil
  end
  session.user = user_msg or ""
  session.assistant = assistant_msg or ""
  session.timestamp = os.time()
  if usage and type(usage) == "table" then
    session.usage = usage
  end
  session.updated_at = os.time()
  debounce_save()
  trigger_event("NeoAI:round_added", { session_id = session_id, session = session })
  return session
end

--- 更新当前会话的AI回复（用于流式更新）
function M.update_last_assistant(session_id, content)
  local session = state.sessions[session_id]
  if not session then
    return
  end
  session.assistant = content
  session.updated_at = os.time()
  debounce_save()
end

--- 更新当前会话的 usage 信息
function M.update_usage(session_id, usage)
  local session = state.sessions[session_id]
  if not session or not usage then
    return
  end
  session.usage = usage
  session.updated_at = os.time()
  debounce_save()
end

--- 获取会话的所有消息（展平为 role/content 列表）
function M.get_messages(session_id)
  local session = state.sessions[session_id]
  if not session then
    return {}
  end
  local msgs = {}
  if session.user and session.user ~= "" then
    table.insert(msgs, { role = "user", content = session.user })
  end
  if session.assistant and session.assistant ~= "" then
    -- assistant 可能是 JSON 字符串（含 reasoning_content），也可能是纯文本
    local content = session.assistant
    local ok, parsed = pcall(vim.json.decode, session.assistant)
    if ok and type(parsed) == "table" and parsed.content then
      content = parsed.content
    end
    table.insert(msgs, { role = "assistant", content = content })
  end
  return msgs
end

--- 获取所有根会话
function M.get_root_sessions()
  local roots = {}
  for _, session in pairs(state.sessions) do
    if session.is_root then
      table.insert(roots, session)
    end
  end
  table.sort(roots, function(a, b)
    return (a.created_at or 0) < (b.created_at or 0)
  end)
  return roots
end

--- 获取所有会话列表
function M.list_sessions()
  local result = {}
  for _, session in pairs(state.sessions) do
    table.insert(result, {
      id = session.id,
      name = session.name,
      created_at = session.created_at,
      updated_at = session.updated_at,
      is_root = session.is_root,
      child_count = #(session.child_ids or {}),
      has_content = session.user ~= nil and session.user ~= "",
    })
  end
  table.sort(result, function(a, b)
    return (a.created_at or 0) < (b.created_at or 0)
  end)
  return result
end

--- 重命名会话
function M.rename_session(session_id, new_name)
  local session = state.sessions[session_id]
  if not session then
    return false
  end
  session.name = new_name
  session.updated_at = os.time()
  debounce_save()
  return true
end

--- 清理未被引用的子会话
function M.cleanup_orphans()
  local referenced = {}
  for _, session in pairs(state.sessions) do
    if session.is_root then
      referenced[session.id] = true
      local function mark_children(ids)
        for _, cid in ipairs(ids) do
          referenced[cid] = true
          local child = state.sessions[cid]
          if child then
            mark_children(child.child_ids or {})
          end
        end
      end
      mark_children(session.child_ids or {})
    end
  end
  local changed = false
  for id, _ in pairs(state.sessions) do
    if not referenced[id] then
      state.sessions[id] = nil
      changed = true
    end
  end
  if changed then
    debounce_save()
    trigger_event("NeoAI:orphans_cleaned", {})
  end
end

--- 获取树结构（用于渲染）
function M.get_tree()
  M.cleanup_orphans()
  local roots = M.get_root_sessions()

  local session_index = 0
  local function build_node(session)
    if not session then
      return nil
    end
    session_index = session_index + 1
    local preview = ""
    if session.user and session.user ~= "" then
      local raw = session.user:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
      preview = raw:sub(1, 20)
      if #raw > 20 then
        preview = preview .. "…"
      end
    end
    local node = {
      id = session.id,
      name = "会话" .. session_index,
      preview = preview,
      children = {},
    }
    local child_ids = session.child_ids or {}
    if #child_ids > 1 then
      local branch_node = {
        id = "__branch_" .. session.id,
        name = session.name .. " (分支)",
        is_virtual = true,
        children = {},
      }
      for _, cid in ipairs(child_ids) do
        local child_node = build_node(state.sessions[cid])
        if child_node then
          table.insert(branch_node.children, child_node)
        end
      end
      table.insert(node.children, branch_node)
    elseif #child_ids == 1 then
      local child_node = build_node(state.sessions[child_ids[1]])
      if child_node then
        table.insert(node.children, child_node)
      end
    end
    return node
  end
  local tree = {}
  for _, root in ipairs(roots) do
    local node = build_node(root)
    if node then
      table.insert(tree, node)
    end
  end
  return tree
end

--- 获取选中会话的上下文路径
--- 从当前会话向子会话捋，遇到多个子会话则在此新开子会话
--- 遇到无子会话的则把这条线作为上文
--- @param session_id string 当前选中的会话ID
--- @return table 上下文消息列表, string|nil 新会话应该挂在哪个会话下
function M.get_context_and_new_parent(session_id)
  local session = state.sessions[session_id]
  if not session then
    return {}, nil
  end

  local context_msgs = {}
  local current = session
  local new_parent_id = session_id

  for _ = 1, 100 do
    local child_ids = current.child_ids or {}
    if #child_ids == 0 then
      local msgs = M.get_messages(current.id)
      for _, m in ipairs(msgs) do
        table.insert(context_msgs, m)
      end
      new_parent_id = current.id
      break
    elseif #child_ids == 1 then
      local msgs = M.get_messages(current.id)
      for _, m in ipairs(msgs) do
        table.insert(context_msgs, m)
      end
      current = state.sessions[child_ids[1]]
      if not current then
        break
      end
    else
      local msgs = M.get_messages(current.id)
      for _, m in ipairs(msgs) do
        table.insert(context_msgs, m)
      end
      new_parent_id = current.id
      break
    end
  end

  return context_msgs, new_parent_id
end

--- 检查是否已初始化
function M.is_initialized()
  return state.initialized
end

--- 重置（测试用）
function M._test_reset()
  state.initialized = false
  state.config = nil
  state.sessions = {}
  state.current_session_id = nil
  if state.save_debounce_timer then
    state.save_debounce_timer:stop()
    state.save_debounce_timer:close()
    state.save_debounce_timer = nil
  end
end

return M
