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
---   assistant: ["{\"content\":\"...\",\"reasoning_content\":\"...\"}"],
---   timestamp: 1234567890,
---   usage: { prompt_tokens: 24, completion_tokens: 770, total_tokens: 794 }
--- }
--- assistant 字段为数组，每个元素是一轮 AI 回复的 JSON 字符串
--- 支持工具调用时的多轮对话

local M = {}

local Events = require("NeoAI.core.events.event_constants")

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

--- 向 child_ids 添加唯一元素（去重）
--- @param ids table child_ids 数组
--- @param id string 要添加的ID
local function add_unique_child(ids, id)
  for _, existing in ipairs(ids) do
    if existing == id then
      return
    end
  end
  table.insert(ids, id)
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

-- 使用 Neovim 内置函数截断 UTF-8 字符串
local function truncate_utf8(str, max_len)
  if not str or str == "" then
    return str
  end
  local positions = vim.str_utf_pos(str)
  if #positions <= max_len then
    return str
  end
  local byte_pos = positions[max_len + 1] - 1
  return str:sub(1, byte_pos)
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
    name = name or "聊天会话",
    created_at = os.time(),
    updated_at = os.time(),
    is_root = (parent_id == nil and is_root ~= false) or (is_root == true),
    child_ids = {},
    user = "",
    assistant = {},
    timestamp = nil,
    usage = {},
  }
  state.sessions[id] = session
  if parent_id and state.sessions[parent_id] then
    table.insert(state.sessions[parent_id].child_ids, id)
    state.sessions[parent_id].updated_at = os.time()
  end
  state.current_session_id = id
  -- 不在创建时保存，等 add_round（会话完成一轮对话）时才保存
  trigger_event(Events.SESSION_CREATED, { session_id = id, session = session })
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
  trigger_event(Events.SESSION_CHANGED, { session_id = session_id })
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
--- 删除会话时，将其 child_ids 上提到父节点下，而不是删除子会话
--- 确保 child_ids 元素唯一
function M.delete_session(session_id)
  local session = state.sessions[session_id]
  if not session then
    return false
  end

  -- 找到父节点，将被删除会话的子会话上提到父节点下
  local parent_id = nil
  for _, s in pairs(state.sessions) do
    for i, cid in ipairs(s.child_ids) do
      if cid == session_id then
        parent_id = s.id
        table.remove(s.child_ids, i)
        s.updated_at = os.time()
        break
      end
    end
    if parent_id then
      break
    end
  end

  -- 将被删除会话的子会话上提到父节点下
  if parent_id and state.sessions[parent_id] then
    for _, child_id in ipairs(session.child_ids or {}) do
      local child = state.sessions[child_id]
      if child then
        child.is_root = false
        add_unique_child(state.sessions[parent_id].child_ids, child_id)
      end
    end
    state.sessions[parent_id].updated_at = os.time()
  elseif not parent_id then
    -- 没有父节点（根节点被删除），子会话提升为根会话
    for _, child_id in ipairs(session.child_ids or {}) do
      local child = state.sessions[child_id]
      if child then
        child.is_root = true
      end
    end
  end

  -- 删除会话本身
  state.sessions[session_id] = nil
  if state.current_session_id == session_id then
    state.current_session_id = nil
  end

  debounce_save()
  trigger_event(Events.SESSION_DELETED, { session_id = session_id })
  return true
end

--- 添加一轮对话（扁平结构：直接设置 user/assistant/timestamp）
--- @param session_id string 会话ID
--- @param user_msg string 用户消息
--- @param assistant_msg string|table AI回复（JSON字符串或数组，含 content 和 reasoning_content）
--- @param usage table|nil token用量
--- @return table|nil
function M.add_round(session_id, user_msg, assistant_msg, usage)
  local session = state.sessions[session_id]
  if not session then
    return nil
  end
  session.user = user_msg or ""
  -- assistant 字段为数组，每个元素是一轮 AI 回复的 JSON 字符串
  if type(assistant_msg) == "table" then
    session.assistant = assistant_msg
  elseif assistant_msg and assistant_msg ~= "" then
    session.assistant = { assistant_msg }
  else
    session.assistant = {}
  end
  session.timestamp = os.time()
  if usage and type(usage) == "table" then
    session.usage = usage
  end
  session.updated_at = os.time()
  debounce_save()
  trigger_event(Events.ROUND_ADDED, { session_id = session_id, session = session })
  return session
end

--- 更新当前会话的AI回复（用于流式更新）
--- 如果 content 是字符串，追加到 assistant 数组末尾
--- 如果 content 是数组，直接替换 assistant 字段
function M.update_last_assistant(session_id, content)
  local session = state.sessions[session_id]
  if not session then
    return
  end
  if type(content) == "table" then
    session.assistant = content
  elseif content and content ~= "" then
    -- 追加到数组末尾
    if type(session.assistant) ~= "table" then
      session.assistant = {}
    end
    table.insert(session.assistant, content)
  end
  session.updated_at = os.time()
  debounce_save()
end

--- 追加一轮 assistant 回复到数组末尾（用于工具调用时的多轮对话）
--- @param session_id string 会话ID
--- @param assistant_entry string AI回复的JSON字符串
--- @return boolean 是否成功
function M.add_assistant_entry(session_id, assistant_entry)
  local session = state.sessions[session_id]
  if not session then
    return false
  end
  if type(session.assistant) ~= "table" then
    -- 兼容旧格式：如果是字符串，转为数组
    if session.assistant and session.assistant ~= "" then
      session.assistant = { session.assistant }
    else
      session.assistant = {}
    end
  end
  table.insert(session.assistant, assistant_entry)
  session.updated_at = os.time()
  debounce_save()
  return true
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
--- assistant 字段为数组，每个元素是一轮 AI 回复的 JSON 字符串
function M.get_messages(session_id)
  local session = state.sessions[session_id]
  if not session then
    return {}
  end
  local msgs = {}
  if session.user and session.user ~= "" then
    table.insert(msgs, { role = "user", content = session.user })
  end
  -- assistant 为数组，每个元素是一轮 AI 回复
  local assistant_list = session.assistant
  if type(assistant_list) ~= "table" then
    -- 兼容旧格式：如果是字符串，转为数组
    if assistant_list and assistant_list ~= "" then
      assistant_list = { assistant_list }
    else
      assistant_list = {}
    end
  end
  for _, entry in ipairs(assistant_list) do
    local content = entry
    -- 尝试解析 JSON 字符串（含 reasoning_content）
    local ok, parsed = pcall(vim.json.decode, entry)
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
    trigger_event(Events.ORPHANS_CLEANED, {})
  end
end

--- 构建轮次预览文本（辅助函数）
--- @param session table 会话对象
--- @return string 轮次预览文本
function M.build_round_text(session)
  if not session then
    return ""
  end
  local user_text = ""
  local ai_text = ""
  if session.user and session.user ~= "" then
    user_text = session.user:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  end
  if
    session.assistant
    and (
      type(session.assistant) == "table" and #session.assistant > 0
      or type(session.assistant) == "string" and session.assistant ~= ""
    )
  then
    local last_entry = session.assistant
    if type(session.assistant) == "table" and #session.assistant > 0 then
      last_entry = session.assistant[#session.assistant]
    end
    if type(last_entry) == "table" and last_entry.content then
      ai_text = last_entry.content
    elseif type(last_entry) == "string" then
      local ok, parsed = pcall(vim.json.decode, last_entry)
      if ok and type(parsed) == "table" and parsed.content then
        ai_text = parsed.content
      else
        ai_text = last_entry
      end
    end
    ai_text = ai_text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  end
  -- 构建显示文本
  local text = ""
  if user_text ~= "" and ai_text ~= "" then
    -- 1. 用户截断到15字符
    local user_len = #user_text
    if user_len > 15 then
      user_text = truncate_utf8(user_text, 15) .. "…"
      user_len = 15
    end
    -- 2. 加上用户emoji
    text = "👤" .. user_text
    -- 3. AI截断使总长（不含emoji）不超过20
    local max_ai = 20 - user_len
    if max_ai < 0 then
      max_ai = 0
    end
    if #ai_text > max_ai then
      ai_text = truncate_utf8(ai_text, max_ai) .. "…"
    end
    -- 4. 加上AI emoji
    text = text .. " | 🤖" .. ai_text
  elseif user_text ~= "" then
    if #user_text > 20 then
      user_text = truncate_utf8(user_text, 20) .. "…"
    end
    text = "👤" .. user_text
  elseif ai_text ~= "" then
    if #ai_text > 20 then
      ai_text = truncate_utf8(ai_text, 20) .. "…"
    end
    text = "🤖" .. ai_text
  end
  return text
end

--- 获取树结构（用于渲染）
--- 返回原始会话树形结构，不创建虚拟节点
--- 每个节点包含：id, session_id, name, children, round_text
function M.get_tree()
  M.cleanup_orphans()
  local roots = M.get_root_sessions()

  local function build_session_node(session)
    local round_text = M.build_round_text(session)
    local node = {
      id = session.id,
      session_id = session.id,
      name = session.name,
      round_text = round_text,
      children = {},
    }
    for _, cid in ipairs(session.child_ids or {}) do
      local child = state.sessions[cid]
      if child then
        table.insert(node.children, build_session_node(child))
      end
    end
    return node
  end

  local tree = {}
  for _, root in ipairs(roots) do
    table.insert(tree, build_session_node(root))
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

  -- 从当前会话向上回溯到根，收集路径上的所有会话ID
  local path_ids = {}
  local current = session
  for _ = 1, 100 do
    table.insert(path_ids, 1, current.id) -- 插入到开头，保持从根到当前顺序
    local parent_id = M.find_parent_session(current.id)
    if not parent_id then
      break -- 没有父节点，说明已到根
    end
    current = state.sessions[parent_id]
    if not current then
      break
    end
  end

  -- 按从根到当前的顺序收集消息
  local context_msgs = {}
  for _, pid in ipairs(path_ids) do
    local msgs = M.get_messages(pid)
    for _, m in ipairs(msgs) do
      table.insert(context_msgs, m)
    end
  end

  -- 确定新会话应该挂在哪个会话下
  -- 规则：从选中会话沿子会话链向下走，找到链尾或分支点
  -- - 如果选中会话有唯一子会话链，则沿链向下找到链尾作为 new_parent_id
  -- - 如果选中会话有多个子会话（分支点），则选中会话本身作为分支点
  -- - 如果选中会话无子会话（链尾），则选中会话本身作为 new_parent_id
  local new_parent_id = M._find_chain_tail_or_branch(session_id)

  return context_msgs, new_parent_id
end

--- 沿子会话链向下找到链尾或分支点
--- @param session_id string 起始会话ID
--- @return string 链尾或分支点的会话ID
function M._find_chain_tail_or_branch(session_id)
  local current = state.sessions[session_id]
  if not current then
    return session_id
  end

  for _ = 1, 100 do
    local child_ids = current.child_ids or {}
    if #child_ids == 0 then
      -- 无子会话：当前节点就是链尾
      return current.id
    elseif #child_ids == 1 then
      -- 唯一子会话：继续沿链向下
      current = state.sessions[child_ids[1]]
      if not current then
        return session_id
      end
    else
      -- 多个子会话：当前节点就是分支点
      return current.id
    end
  end

  return current and current.id or session_id
end

--- 查找某个会话的父会话ID
--- @param session_id string 子会话ID
--- @return string|nil 父会话ID，如果没有父会话则返回nil
function M.find_parent_session(session_id)
  for _, s in pairs(state.sessions) do
    for _, cid in ipairs(s.child_ids or {}) do
      if cid == session_id then
        return s.id
      end
    end
  end
  return nil
end

--- 向上查找最近的父分支节点
--- 分支节点定义为 child_ids >= 2 的节点
--- 如果找到根节点仍未找到分支节点，则返回根节点
--- @param session_id string 起始会话ID
--- @return string|nil 分支节点ID，nil表示无父节点（本身就是根）
function M.find_nearest_branch_parent(session_id)
  local current_id = session_id
  local branch_parent_id = nil

  for _ = 1, 100 do
    local parent_id = M.find_parent_session(current_id)
    if not parent_id then
      -- 已到根节点，没有父节点
      break
    end
    local parent = state.sessions[parent_id]
    if parent and #(parent.child_ids or {}) >= 2 then
      -- 找到分支节点
      branch_parent_id = parent_id
      break
    end
    current_id = parent_id
  end

  return branch_parent_id
end

--- 删除从分支节点到选中节点的整条链
--- 从选中节点向上回溯到分支节点（不含分支节点本身），删除路径上的所有会话
--- 如果选中节点本身就是根节点（无父节点），则删除整个根会话
--- @param session_id string 选中会话ID
--- @return boolean 是否成功
function M.delete_chain_to_branch(session_id)
  local session = state.sessions[session_id]
  if not session then
    return false
  end

  -- 找到最近的父分支节点
  local branch_parent_id = M.find_nearest_branch_parent(session_id)

  if not branch_parent_id then
    -- 没有父节点，说明选中节点是根节点，直接删除整个根会话
    return M.delete_session(session_id)
  end

  -- 从选中节点向上回溯到分支节点，收集路径上的所有会话ID（不含分支节点本身）
  local chain_ids = {}
  local current_id = session_id
  for _ = 1, 100 do
    if current_id == branch_parent_id then
      break
    end
    table.insert(chain_ids, current_id)
    local parent_id = M.find_parent_session(current_id)
    if not parent_id then
      break
    end
    current_id = parent_id
  end

  -- 从分支节点的 child_ids 中移除链首节点
  local branch_parent = state.sessions[branch_parent_id]
  if branch_parent then
    local chain_head_id = chain_ids[#chain_ids] -- 链中离分支节点最近的节点
    for i, cid in ipairs(branch_parent.child_ids or {}) do
      if cid == chain_head_id then
        table.remove(branch_parent.child_ids, i)
        branch_parent.updated_at = os.time()
        break
      end
    end
  end

  -- 删除链上的所有会话（从叶子到根方向删除）
  -- 每个被删除会话的子会话上提到分支节点下
  for _, cid in ipairs(chain_ids) do
    local s = state.sessions[cid]
    if s then
      -- 将被删除会话的子会话上提到分支节点下
      for _, child_id in ipairs(s.child_ids or {}) do
        local child = state.sessions[child_id]
        if child then
          child.is_root = false
          add_unique_child(branch_parent.child_ids, child_id)
        end
      end
      -- 删除会话
      state.sessions[cid] = nil
      if state.current_session_id == cid then
        state.current_session_id = nil
      end
    end
  end

  debounce_save()
  trigger_event(Events.SESSION_DELETED, { session_id = session_id })
  return true
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

--- 导出所有会话到文件
--- @param filepath string 导出文件路径
--- @return boolean, string|nil 导出是否成功，错误信息
function M.export_sessions(filepath)
  local data = {
    sessions = {},
    export_time = os.time(),
  }
  for _, session in pairs(state.sessions) do
    table.insert(data.sessions, session)
  end

  local content = vim.json.encode(data)
  local success, err = pcall(function()
    local file = io.open(filepath, "w")
    if not file then
      error("无法打开文件: " .. filepath)
    end
    file:write(content)
    file:close()
  end)

  if success then
    return true
  else
    return false, err
  end
end

--- 从文件导入会话
--- @param filepath string 导入文件路径
--- @return boolean, string|nil 导入是否成功，错误信息
function M.import_sessions(filepath)
  local success, data = pcall(function()
    local file = io.open(filepath, "r")
    if not file then
      error("无法打开文件: " .. filepath)
    end
    local content = file:read("*a")
    file:close()
    return vim.json.decode(content)
  end)

  if not success then
    return false, data
  end

  if data.sessions then
    for _, session in ipairs(data.sessions) do
      if session and session.id then
        state.sessions[session.id] = session
      end
    end
  end

  debounce_save()
  return true, nil
end

return M
