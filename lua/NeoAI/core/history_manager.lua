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
  trigger_event("NeoAI:round_added", { session_id = session_id, session = session })
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
    trigger_event("NeoAI:orphans_cleaned", {})
  end
end

--- 获取树结构（用于渲染）
function M.get_tree()
  M.cleanup_orphans()
  local roots = M.get_root_sessions()

  local session_index = 0

  -- 前向声明，用于相互递归
  local build_node

  --- 构建会话节点：显示会话名称，轮次作为子节点
  --- 如果会话有多个子会话，创建分支节点
  local function build_session_node(session)
    if not session then
      return nil
    end
    session_index = session_index + 1

    -- 构建该会话的轮次预览
    local s_round_text = ""
    if session.user and session.user ~= "" then
      local user_preview = session.user:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
      if #user_preview > 20 then
        user_preview = user_preview:sub(1, 20) .. "…"
      end
      s_round_text = "👤" .. user_preview
    end
    if
      session.assistant
      and (
        type(session.assistant) == "table" and #session.assistant > 0
        or type(session.assistant) == "string" and session.assistant ~= ""
      )
    then
      local ai_text = ""
      local last_entry = session.assistant
      if type(session.assistant) == "table" and #session.assistant > 0 then
        last_entry = session.assistant[#session.assistant]
      end
      local ok, parsed = pcall(vim.json.decode, last_entry)
      if ok and type(parsed) == "table" and parsed.content then
        ai_text = parsed.content
      elseif type(last_entry) == "string" then
        ai_text = last_entry
      end
      local ai_preview = ai_text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
      if #ai_preview > 20 then
        ai_preview = ai_preview:sub(1, 20) .. "…"
      end
      if s_round_text ~= "" then
        s_round_text = s_round_text .. " | 🤖" .. ai_preview
      else
        s_round_text = "🤖" .. ai_preview
      end
    end

    local s_child_ids = session.child_ids or {}
    local session_children = {}

    -- 添加会话自身的轮次
    if s_round_text ~= "" then
      table.insert(session_children, {
        id = session.id .. "_round",
        name = s_round_text,
        is_round = true,
        preview = s_round_text,
        children = {},
      })
    end

    if #s_child_ids == 1 then
      -- 只有一个子会话：链式扁平化展开
      local function collect_chain(s, collected)
        local scids = s.child_ids or {}
        for _, scid in ipairs(scids) do
          local sc_session = state.sessions[scid]
          if sc_session then
            local sc_node = build_node(sc_session, false)
            if sc_node then
              table.insert(collected, sc_node)
            end
            collect_chain(sc_session, collected)
          end
        end
      end
      collect_chain(session, session_children)
    elseif #s_child_ids > 1 then
      -- 多个子会话：统一放在一个虚拟分支节点下
      local branch_children = {}
      for _, scid in ipairs(s_child_ids) do
        local sc_session = state.sessions[scid]
        if sc_session then
          -- 子会话自身的轮次
          local sc_node = build_node(sc_session, false)
          if sc_node then
            table.insert(branch_children, sc_node)
          end
          -- 链式收集子会话的子会话
          local function collect_branch(s, collected)
            local bscids = s.child_ids or {}
            for _, bscid in ipairs(bscids) do
              local bs_session = state.sessions[bscid]
              if bs_session then
                local bs_node = build_node(bs_session, false)
                if bs_node then
                  table.insert(collected, bs_node)
                end
                collect_branch(bs_session, collected)
              end
            end
          end
          collect_branch(sc_session, branch_children)
        end
      end
      -- 计算分支总轮数
      local branch_rounds = 0
      for _, bc in ipairs(branch_children) do
        if bc.is_round then
          branch_rounds = branch_rounds + 1
        elseif bc.round_count and bc.round_count > 0 then
          branch_rounds = branch_rounds + bc.round_count
        else
          branch_rounds = branch_rounds + 1
        end
      end
      if #branch_children > 0 then
        local branch_node = {
          id = "__branch_" .. session.id,
          name = "分支",
          is_virtual = true,
          round_count = branch_rounds,
          children = branch_children,
        }
        table.insert(session_children, branch_node)
      end
    end

    -- 计算该会话的总轮数
    local total_rounds = 0
    for _, child in ipairs(session_children) do
      if child.is_round then
        total_rounds = total_rounds + 1
      elseif child.round_count and child.round_count > 0 then
        total_rounds = total_rounds + child.round_count
      else
        total_rounds = total_rounds + 1
      end
    end

    local session_node = {
      id = session.id,
      name = "会话" .. session_index,
      preview = s_round_text,
      round_count = total_rounds,
      children = session_children,
    }
    return session_node
  end

  build_node = function(session, is_root)
    if not session then
      return nil
    end
    session_index = session_index + 1

    -- 构建轮次预览文本
    local round_text = ""
    if session.user and session.user ~= "" then
      local user_preview = session.user:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
      if #user_preview > 20 then
        user_preview = user_preview:sub(1, 20) .. "…"
      end
      round_text = "👤" .. user_preview
    end
    if
      session.assistant
      and (
        type(session.assistant) == "table" and #session.assistant > 0
        or type(session.assistant) == "string" and session.assistant ~= ""
      )
    then
      local ai_text = ""
      local last_entry = session.assistant
      if type(session.assistant) == "table" and #session.assistant > 0 then
        last_entry = session.assistant[#session.assistant]
      end
      local ok, parsed = pcall(vim.json.decode, last_entry)
      if ok and type(parsed) == "table" and parsed.content then
        ai_text = parsed.content
      elseif type(last_entry) == "string" then
        ai_text = last_entry
      end
      local ai_preview = ai_text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
      if #ai_preview > 20 then
        ai_preview = ai_preview:sub(1, 20) .. "…"
      end
      if round_text ~= "" then
        round_text = round_text .. " | 🤖" .. ai_preview
      else
        round_text = "🤖" .. ai_preview
      end
    end

    local child_ids = session.child_ids or {}

    local node = {
      id = session.id,
      name = "会话" .. session_index,
      preview = round_text,
      round_count = 0,
      children = {},
    }

    if is_root then
      -- 根节点：创建虚拟文件夹节点，把子会话放进去
      -- 根节点自身的轮次内容作为虚拟文件夹节点的 preview 显示，不单独作为子节点
      local root_children = {}

      -- 为每个直接子会话创建会话节点
      local cids = session.child_ids or {}
      for _, cid in ipairs(cids) do
        local child_session = state.sessions[cid]
        if child_session then
          -- 构建会话节点（显示会话名称，轮次作为子节点）
          local session_node = build_session_node(child_session)
          if session_node then
            table.insert(root_children, session_node)
          end
        end
      end

      -- 计算总轮数
      local total_rounds = 0
      for _, child in ipairs(root_children) do
        if child.is_round then
          total_rounds = total_rounds + 1
        elseif child.round_count and child.round_count > 0 then
          total_rounds = total_rounds + child.round_count
        else
          total_rounds = total_rounds + 1
        end
      end
      -- 创建虚拟文件夹节点，把根节点自身和所有子会话都放进去
      local virtual_node = {
        id = "__folder_" .. session.id,
        name = session.name,
        is_virtual = true,
        round_count = total_rounds,
        children = root_children,
      }
      -- 返回虚拟文件夹节点，替换原来的根节点
      return virtual_node
    else
      -- 非根节点：直接用轮次内容作为节点名称，不包含子节点
      -- 子会话由父节点的 build_session_node 收集
      if round_text ~= "" then
        node.name = round_text
        node.round_count = 1
        node.is_round = true
      end
      -- 标记是否有子会话（用于渲染时显示文件夹图标）
      if #child_ids > 0 then
        node.has_children = true
      end
    end
    return node
  end

  local tree = {}
  for _, root in ipairs(roots) do
    local node = build_node(root, true)
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
