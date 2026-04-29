--- NeoAI 会话历史管理器
--- 职责：会话数据的 CRUD 操作、消息管理
--- 持久化委托给 history_persistence 模块
--- 缓存委托给 history_cache 模块
---
--- 会话结构（扁平结构，一轮对话一个会话）:
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

local M = {}

local logger = require("NeoAI.utils.logger")
local Events = require("NeoAI.core.events")
local persistence = require("NeoAI.core.history.persistence")
local cache = require("NeoAI.core.history.cache")
local shutdown_flag = require("NeoAI.core.shutdown_flag")

-- ========== 状态 ==========

local state = {
  initialized = false,
  config = nil,
  sessions = {},           -- { [id] = session }
  current_session_id = nil,
  _vimleave_hooked = false,
  _is_shutting_down = false,
}

-- ========== 辅助函数 ==========

--- 获取 sessions 表的引用（供缓存模块使用）
local function get_sessions_ref()
  return state.sessions
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
    if existing == id then return end
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

--- 使用 Neovim 内置函数截断 UTF-8 字符串
local function truncate_utf8(str, max_len)
  if not str or str == "" then return str end
  local positions = vim.str_utf_pos(str)
  if #positions <= max_len then return str end
  local byte_pos = positions[max_len + 1] - 1
  return str:sub(1, byte_pos)
end

--- 查找 assistant 数组中最后一条 AI 回复条目的索引
local function find_last_assistant_entry_index(assistant_list)
  if type(assistant_list) ~= "table" then return nil end
  for i = #assistant_list, 1, -1 do
    local entry = assistant_list[i]
    if type(entry) == "table" then
      if entry.type ~= "tool_call" then
        return i
      end
    elseif type(entry) == "string" then
      -- 兼容旧格式（预编码的 JSON 字符串）
      local ok, parsed = pcall(vim.json.decode, entry)
      if not ok or type(parsed) ~= "table" or parsed.type ~= "tool_call" then
        return i
      end
    end
  end
  return nil
end

-- ========== 初始化 ==========

function M.initialize(options)
  if state.initialized then return end

  options = options or {}
  state.config = vim.deepcopy(options.config or options or {})
  if state.config.session and type(state.config.session) == "table" then
    for k, v in pairs(state.config.session) do
      state.config[k] = v
    end
    state.config.session = nil
  end
  state.config.auto_save = state.config.auto_save ~= false
  state.config.auto_naming = state.config.auto_naming ~= false
  state.sessions = {}
  state.current_session_id = nil

  -- 初始化持久化模块
  persistence.initialize({ config = state.config })

  -- 初始化缓存模块
  cache.initialize(get_sessions_ref, M.build_round_text)

  state.initialized = true

  -- 同步加载历史文件
  M._load()

  -- 注册 VimLeavePre 自动保存钩子
  if not state._vimleave_hooked then
    state._vimleave_hooked = true
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = vim.api.nvim_create_augroup("NeoAIHistorySave", { clear = true }),
      callback = function()
        M._shutdown_and_save()
      end,
    })
  end
end

--- 关闭并保存（VimLeavePre 使用）
function M._shutdown_and_save()
  state._is_shutting_down = true
  persistence.set_shutting_down()
  shutdown_flag.set()

  -- 1. 通知工具编排器关闭（清理所有会话状态和 autocmd）
  pcall(function()
    local orc_ok, tool_orc = pcall(require, "NeoAI.core.ai.tool_orchestrator")
    if orc_ok and tool_orc then
      if tool_orc.set_shutting_down then
        tool_orc.set_shutting_down()
      end
      if tool_orc.cleanup_all then
        tool_orc.cleanup_all()
      end
    end
  end)

  -- 2. 取消所有 HTTP 请求
  pcall(function()
    local http_ok, http_client = pcall(require, "NeoAI.core.ai.http_client")
    if http_ok and http_client and http_client.cancel_all_requests then
      http_client.cancel_all_requests()
    end
  end)

  -- 3. 清空 persistence 写入队列（避免异步回调在退出过程中执行）
  persistence.flush_queue()

  -- 4. 同步保存会话数据
  persistence.sync_save(state.sessions)
end

--- 加载会话数据
function M._load()
  local loaded = persistence.load()
  state.sessions = loaded
  trigger_event(Events.SESSION_LOADED, {})
end

-- ========== 会话 CRUD ==========

--- 创建新会话
--- @param name string 会话名称
--- @param is_root boolean 是否为根会话
--- @param parent_id string|nil 父会话ID
--- @return string 会话ID
function M.create_session(name, is_root, parent_id)
  if not state.initialized then error("History manager not initialized") end

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
  cache.invalidate_round_text(id)
  cache.invalidate_tree()
  cache.invalidate_list()

  M._mark_dirty()
  trigger_event(Events.SESSION_CREATED, { session_id = id, session = session })
  return id
end

--- 获取会话
function M.get_session(session_id)
  if not session_id then return nil end
  return state.sessions[session_id]
end

--- 获取当前会话
function M.get_current_session()
  if not state.current_session_id then return nil end
  return state.sessions[state.current_session_id]
end

--- 设置当前会话
function M.set_current_session(session_id)
  if not state.sessions[session_id] then return false end
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
function M.delete_session(session_id)
  local session = state.sessions[session_id]
  if not session then return false end

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
    if parent_id then break end
  end

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
    for _, child_id in ipairs(session.child_ids or {}) do
      local child = state.sessions[child_id]
      if child then child.is_root = true end
    end
  end

  state.sessions[session_id] = nil
  cache.invalidate_round_text(session_id)
  cache.invalidate_tree()
  cache.invalidate_list()

  if state.current_session_id == session_id then
    state.current_session_id = nil
  end

  M._mark_dirty()
  trigger_event(Events.SESSION_DELETED, { session_id = session_id })
  return true
end

--- 重命名会话
function M.rename_session(session_id, new_name)
  local session = state.sessions[session_id]
  if not session then return false end
  session.name = new_name
  session.updated_at = os.time()
  cache.invalidate_tree()
  cache.invalidate_list()
  M._mark_dirty()
  return true
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
    return (a.updated_at or a.created_at or 0) < (b.updated_at or b.created_at or 0)
  end)
  return roots
end

--- 获取所有会话列表（带缓存）
function M.list_sessions()
  return cache.get_list()
end

--- 获取树结构（带缓存）
function M.get_tree()
  return cache.get_tree(M.cleanup_orphans, M.get_root_sessions, M.get_session)
end

-- ========== 消息管理 ==========

--- 添加一轮对话
--- @param session_id string 会话ID
--- @param user_msg string 用户消息
--- @param assistant_msg string|table AI回复
--- @param usage table|nil token用量
--- @return table|nil
function M.add_round(session_id, user_msg, assistant_msg, usage)
  local session = state.sessions[session_id]
  if not session then return nil end

  session.user = user_msg or ""
  if type(assistant_msg) == "table" then
    if #assistant_msg > 0 then
      session.assistant = assistant_msg
    end
  elseif assistant_msg and assistant_msg ~= "" then
    local ok, parsed = pcall(vim.json.decode, assistant_msg)
    if ok and type(parsed) == "table" then
      session.assistant = { parsed }
    else
      session.assistant = { { content = assistant_msg } }
    end
  end
  session.timestamp = os.time()
  if usage and type(usage) == "table" then
    session.usage = usage
  end
  session.updated_at = os.time()

  cache.invalidate_round_text(session_id)
  cache.invalidate_tree()
  cache.invalidate_list()
  M._mark_dirty()

  trigger_event(Events.ROUND_ADDED, { session_id = session_id, session = session })

  if state.config.auto_naming ~= false then
    M.auto_name_session(session_id)
  end

  return session
end

--- 更新当前会话的AI回复（用于流式更新）
function M.update_last_assistant(session_id, content, flush)
  local session = state.sessions[session_id]
  if not session then return end

  if type(content) == "table" then
    if type(session.assistant) ~= "table" then
      session.assistant = {}
    end
    local last_ai_idx = find_last_assistant_entry_index(session.assistant)
    if last_ai_idx then
      session.assistant[last_ai_idx] = content
    else
      table.insert(session.assistant, content)
    end
  elseif content and content ~= "" then
    if type(session.assistant) ~= "table" then
      session.assistant = {}
    end
    local last_ai_idx = find_last_assistant_entry_index(session.assistant)
    local entry
    local ok, parsed = pcall(vim.json.decode, content)
    if ok and type(parsed) == "table" then
      entry = parsed
    else
      entry = { content = content }
    end
    if last_ai_idx then
      session.assistant[last_ai_idx] = entry
    else
      table.insert(session.assistant, entry)
    end
  end
  session.updated_at = os.time()

  cache.invalidate_round_text(session_id)
  cache.invalidate_tree()

  if flush then
    M._mark_dirty()
  else
    M._mark_dirty_light()
  end
end

--- 追加一轮 assistant 回复到数组末尾
function M.add_assistant_entry(session_id, assistant_entry)
  local session = state.sessions[session_id]
  if not session then return false end

  if type(session.assistant) ~= "table" then
    if session.assistant and session.assistant ~= "" then
      session.assistant = { session.assistant }
    else
      session.assistant = {}
    end
  end

  if type(assistant_entry) == "string" then
    local ok, parsed = pcall(vim.json.decode, assistant_entry)
    if ok and type(parsed) == "table" then
      table.insert(session.assistant, parsed)
    elseif assistant_entry:match("^{{{") then
      table.insert(session.assistant, assistant_entry)
    else
      table.insert(session.assistant, { content = assistant_entry })
    end
  else
    table.insert(session.assistant, assistant_entry)
  end
  session.updated_at = os.time()
  return true
end

--- 记录工具调用结果到历史
function M.add_tool_result(session_id, tool_name, arguments, result)
  local session = state.sessions[session_id]
  if not session then return false end

  local args_str = vim.inspect(arguments or {})
  if #args_str > 100 then args_str = args_str:sub(1, 100) .. "..." end
  local result_str = type(result) == "table"
    and (pcall(vim.json.encode, result) and vim.json.encode(result) or vim.inspect(result))
    or tostring(result or "")
  if #result_str > 200 then
    result_str = result_str:sub(1, 200) .. "\n    ... [truncated, total " .. #result_str .. " chars]"
  end
  result_str = result_str:gsub("\n", "\n    ")

  local folded_text = "{{{ 🔧 工具调用"
    .. "\n  🔧 " .. (tool_name or "unknown")
    .. "\n    参数: " .. args_str
    .. "\n    结果: " .. result_str
    .. "\n}}}"

  if type(session.assistant) ~= "table" then
    if session.assistant and session.assistant ~= "" then
      session.assistant = { session.assistant }
    else
      session.assistant = {}
    end
  end

  local last_idx = #session.assistant
  local appended = false
  if last_idx and last_idx > 0 then
    local last_entry = session.assistant[last_idx]
    if type(last_entry) == "string" and last_entry:match("^{{{.-" .. tool_name .. "}}}") then
      local base = last_entry:sub(1, #last_entry - 3)
      local new_entry = base
        .. "\n  🔧 " .. (tool_name or "unknown")
        .. "\n    参数: " .. args_str
        .. "\n    结果: " .. result_str
        .. "\n}}}"
      session.assistant[last_idx] = new_entry
      appended = true
    elseif type(last_entry) == "string" and last_entry:match("^{{{") then
      local base = last_entry:sub(1, #last_entry - 3)
      local new_entry = base
        .. "\n  🔧 " .. (tool_name or "unknown")
        .. "\n    参数: " .. args_str
        .. "\n    结果: " .. result_str
        .. "\n}}}"
      session.assistant[last_idx] = new_entry
      appended = true
    end
  end

  if not appended then
    table.insert(session.assistant, folded_text)
  end
  session.updated_at = os.time()

  cache.invalidate_round_text(session_id)
  cache.invalidate_tree()
  M._mark_dirty()
  return true
end

--- 更新 usage 信息（累积模式）
function M.update_usage(session_id, usage)
  local session = state.sessions[session_id]
  if not session or not usage then return end

  local existing = session.usage or {}
  local function acc(key, src_key)
    local val = usage[src_key or key]
    if val and type(val) == "number" then
      existing[key] = (existing[key] or 0) + val
    end
  end
  acc("prompt_tokens", "prompt_tokens")
  acc("prompt_tokens", "promptTokens")
  acc("prompt_tokens", "input_tokens")
  acc("prompt_tokens", "inputTokens")
  acc("completion_tokens", "completion_tokens")
  acc("completion_tokens", "completionTokens")
  acc("completion_tokens", "output_tokens")
  acc("completion_tokens", "outputTokens")
  acc("total_tokens", "total_tokens")
  acc("total_tokens", "totalTokens")

  if usage.completion_tokens_details and type(usage.completion_tokens_details) == "table" then
    local rt = usage.completion_tokens_details.reasoning_tokens or 0
    if not existing.completion_tokens_details then
      existing.completion_tokens_details = {}
    end
    existing.completion_tokens_details.reasoning_tokens = (existing.completion_tokens_details.reasoning_tokens or 0) + rt
  end
  session.usage = existing
  session.updated_at = os.time()
end

--- 获取会话的所有消息（展平为 role/content 列表）
function M.get_messages(session_id)
  local session = state.sessions[session_id]
  if not session then return {} end

  local msgs = {}
  if session.user and session.user ~= "" then
    table.insert(msgs, { role = "user", content = session.user })
  end

  local assistant_list = session.assistant
  if type(assistant_list) ~= "table" then
    assistant_list = (assistant_list and assistant_list ~= "") and { assistant_list } or {}
  end

  for _, entry in ipairs(assistant_list) do
    local content = entry
    local msg_type = "assistant"

    local parsed = entry
    if type(entry) == "string" then
      local ok, decoded = pcall(vim.json.decode, entry)
      if ok and type(decoded) == "table" then
        parsed = decoded
      else
        parsed = nil
      end
    end

    if type(parsed) == "table" then
      if parsed.type == "tool_call" then
        local args_str = vim.inspect(parsed.arguments or {})
        if #args_str > 200 then args_str = args_str:sub(1, 200) .. "..." end
        local result_str = tostring(parsed.result or "")
        if #result_str > 300 then result_str = result_str:sub(1, 300) .. "\n... [truncated]" end
        content = string.format(
          "🔧 工具调用: %s\n参数: %s\n结果: %s",
          parsed.tool_name or "unknown", args_str, result_str
        )
        msg_type = "tool"
      elseif parsed.content then
        content = parsed.content
      end
    end
    table.insert(msgs, { role = msg_type, content = content })
  end
  return msgs
end

-- ========== 上下文路径 ==========

function M.get_context_and_new_parent(session_id)
  local session = state.sessions[session_id]
  if not session then return {}, nil end

  local upward_ids = {}
  local current = session
  for _ = 1, 100 do
    table.insert(upward_ids, 1, current.id)
    local parent_id = M.find_parent_session(current.id)
    if not parent_id then break end
    current = state.sessions[parent_id]
    if not current then break end
  end

  local downward_ids = {}
  current = session
  for _ = 1, 100 do
    local child_ids = current.child_ids or {}
    if #child_ids ~= 1 then break end
    current = state.sessions[child_ids[1]]
    if not current then break end
    table.insert(downward_ids, current.id)
  end

  local path_ids = {}
  for _, pid in ipairs(upward_ids) do table.insert(path_ids, pid) end
  for _, pid in ipairs(downward_ids) do table.insert(path_ids, pid) end

  local context_msgs = {}
  for _, pid in ipairs(path_ids) do
    local msgs = M.get_messages(pid)
    for _, m in ipairs(msgs) do
      table.insert(context_msgs, m)
    end
  end

  local new_parent_id = path_ids[#path_ids]
  return context_msgs, new_parent_id
end

function M.find_parent_session(session_id)
  for _, s in pairs(state.sessions) do
    for _, cid in ipairs(s.child_ids or {}) do
      if cid == session_id then return s.id end
    end
  end
  return nil
end

function M.find_nearest_branch_parent(session_id)
  local current_id = session_id
  for _ = 1, 100 do
    local parent_id = M.find_parent_session(current_id)
    if not parent_id then break end
    local parent = state.sessions[parent_id]
    if parent and #(parent.child_ids or {}) >= 2 then
      return parent_id
    end
    current_id = parent_id
  end
  return nil
end

function M.delete_chain_to_branch(session_id)
  local session = state.sessions[session_id]
  if not session then return false end

  local branch_parent_id = M.find_nearest_branch_parent(session_id)
  if not branch_parent_id then
    return M.delete_session(session_id)
  end

  local chain_ids = {}
  local current_id = session_id
  for _ = 1, 100 do
    if current_id == branch_parent_id then break end
    table.insert(chain_ids, current_id)
    local parent_id = M.find_parent_session(current_id)
    if not parent_id then break end
    current_id = parent_id
  end

  local branch_parent = state.sessions[branch_parent_id]
  if branch_parent then
    local chain_head_id = chain_ids[#chain_ids]
    for i, cid in ipairs(branch_parent.child_ids or {}) do
      if cid == chain_head_id then
        table.remove(branch_parent.child_ids, i)
        branch_parent.updated_at = os.time()
        break
      end
    end
  end

  for _, cid in ipairs(chain_ids) do
    local s = state.sessions[cid]
    if s then
      for _, child_id in ipairs(s.child_ids or {}) do
        local child = state.sessions[child_id]
        if child then
          child.is_root = false
          add_unique_child(branch_parent.child_ids, child_id)
        end
      end
      state.sessions[cid] = nil
      if state.current_session_id == cid then
        state.current_session_id = nil
      end
    end
  end

  cache.invalidate_all()
  M._mark_dirty()
  trigger_event(Events.SESSION_DELETED, { session_id = session_id })
  return true
end

-- ========== 清理 ==========

function M.cleanup_orphans()
  local referenced = {}
  local function mark_children(ids)
    for _, cid in ipairs(ids) do
      referenced[cid] = true
      local child = state.sessions[cid]
      if child then mark_children(child.child_ids or {}) end
    end
  end

  for _, session in pairs(state.sessions) do
    if session.is_root then
      referenced[session.id] = true
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
    cache.invalidate_all()
    M._mark_dirty()
    trigger_event(Events.ORPHANS_CLEANED, {})
  end
end

-- ========== Round Text ==========

function M.build_round_text(session)
  if not session then return "" end

  local user_text = ""
  local ai_text = ""

  if session.user and session.user ~= "" then
    user_text = session.user:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  end

  if session.assistant and (
    (type(session.assistant) == "table" and #session.assistant > 0) or
    (type(session.assistant) == "string" and session.assistant ~= "")
  ) then
    local last_entry = session.assistant
    if type(session.assistant) == "table" and #session.assistant > 0 then
      last_entry = session.assistant[#session.assistant]
    end

    if type(last_entry) == "table" then
      if last_entry.content then
        ai_text = last_entry.content
      elseif last_entry.type == "tool_call" then
        ai_text = "🔧 " .. (last_entry.tool_name or "工具调用")
      end
    elseif type(last_entry) == "string" then
      local ok, parsed = pcall(vim.json.decode, last_entry)
      if ok and type(parsed) == "table" then
        if parsed.content then
          ai_text = parsed.content
        elseif parsed.type == "tool_call" then
          ai_text = "🔧 " .. (parsed.tool_name or "工具调用")
        end
      else
        ai_text = last_entry
      end
    end
    ai_text = ai_text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  end

  local text = ""
  if user_text ~= "" and ai_text ~= "" then
    local user_len = #user_text
    if user_len > 15 then
      user_text = truncate_utf8(user_text, 15) .. "…"
      user_len = 15
    end
    text = "👤" .. user_text
    local max_ai = 20 - user_len
    if max_ai < 0 then max_ai = 0 end
    if #ai_text > max_ai then
      ai_text = truncate_utf8(ai_text, max_ai) .. "…"
    end
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

-- ========== 自动命名 ==========

function M.auto_name_session(session_id, callback)
  local session = state.sessions[session_id]
  if not session then
    if callback then callback(false, "会话不存在") end
    return
  end

  local default_names = { "聊天会话", "新会话", "子会话", "分支", "会话" }
  local is_default = false
  for _, dn in ipairs(default_names) do
    if session.name == dn or session.name:find("^" .. dn) then
      is_default = true
      break
    end
  end
  if not is_default then
    if callback then callback(true, session.name) end
    return
  end

  local user_msg = session.user or ""
  if user_msg == "" then
    if callback then callback(false, "无用户消息") end
    return
  end

  local ai_engine = require("NeoAI.core.ai.ai_engine")
  ai_engine.auto_name_session(session_id, user_msg, function(success, name_or_error)
    if success then
      M.rename_session(session_id, name_or_error)
      trigger_event(Events.SESSION_RENAMED, { session_id = session_id, name = name_or_error })
      if callback then callback(true, name_or_error) end
    else
      if callback then callback(false, name_or_error) end
    end
  end)
end

-- ========== 持久化 ==========

function M._mark_dirty()
  if not state.config.auto_save then return end
  if state._is_shutting_down then return end

  persistence.debounced_save(function()
    return state.sessions
  end)
end

function M._mark_dirty_light()
end

function M._save()
  if state._is_shutting_down then return end
  local content = persistence.serialize(state.sessions)
  if content then
    persistence.enqueue_save("manual", content)
  end
end

function M.sync_save_vimleave()
  persistence.sync_save(state.sessions)
end

-- ========== 导出/导入 ==========

function M.export_sessions(filepath)
  local data = {
    sessions = {},
    export_time = os.time(),
  }
  for _, session in pairs(state.sessions) do
    table.insert(data.sessions, session)
  end

  local content = vim.json.encode(data)
  local ok, err = pcall(function()
    local file = io.open(filepath, "w")
    if not file then error("无法打开文件: " .. filepath) end
    file:write(content)
    file:close()
  end)
  return ok, ok and nil or err
end

function M.import_sessions(filepath)
  local ok, data = pcall(function()
    local file = io.open(filepath, "r")
    if not file then error("无法打开文件: " .. filepath) end
    local content = file:read("*a")
    file:close()
    return vim.json.decode(content)
  end)
  if not ok then return false, data end

  if data.sessions then
    for _, session in ipairs(data.sessions) do
      if session and session.id then
        state.sessions[session.id] = session
      end
    end
  end

  cache.invalidate_all()
  M._mark_dirty()
  return true, nil
end

-- ========== 状态查询 ==========

function M.is_initialized()
  return state.initialized
end

-- ========== 重置（测试用） ==========

function M._test_reset()
  state.initialized = false
  state.config = nil
  state.sessions = {}
  state.current_session_id = nil
  state._is_shutting_down = false
  persistence._test_reset()
  cache._test_reset()

  local test_file = "/tmp/neoai_test_sessions/sessions.json"
  if vim.fn.filereadable(test_file) == 1 then
    pcall(vim.fn.delete, test_file)
  end
end

return M
