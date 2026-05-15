--- NeoAI 会话历史管理器
--- 职责：会话数据的 CRUD 操作、消息管理
--- 持久化委托给 history_persistence 模块
--- 缓存委托给 history_cache 模块
--- 会话保存委托给 history_saver 模块（事件驱动、队列异步写入）
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
local saver = require("NeoAI.core.history.saver")
local shutdown_flag = require("NeoAI.core.shutdown_flag")
local message_builder = require("NeoAI.core.history.message_builder")

-- ========== 状态 ==========

local state = {
  initialized = false,
  sessions = {},           -- { [id] = session }
  current_session_id = nil,
  _vimleave_hooked = false,
  _is_shutting_down = false,
}

-- 保存的完整配置引用
local _config = nil

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

  state.sessions = {}
  state.current_session_id = nil

  local full_config = (options or {}).config or {}
  _config = full_config
  local session_config = full_config.session or {}
  local auto_save = session_config.auto_save ~= false
  local auto_naming = session_config.auto_naming ~= false

  -- 初始化持久化模块（幂等）
  persistence.initialize({ config = session_config })

  -- 初始化缓存模块（幂等）
  cache.initialize(get_sessions_ref, M.build_round_text)

  -- 初始化会话历史保存器（事件驱动、队列异步写入，幂等）
  saver.initialize(M)

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
    local orc_ok, tool_orc = pcall(require, "NeoAI.core.ai.tool_cycle")
    if orc_ok and tool_orc then
      if tool_orc.set_shutting_down then
        tool_orc.set_shutting_down()
      end
      if tool_orc.cleanup_all then
        tool_orc.cleanup_all()
      end
    end
  end)

  -- 1.5 清理子 agent（停止所有定时器，释放资源）
  pcall(function()
    local pe_ok, plan_executor = pcall(require, "NeoAI.tools.builtin.plan_executor")
    if pe_ok and plan_executor and plan_executor.cleanup_all then
      plan_executor.cleanup_all()
    end
  end)

  -- 1.6 清理子 agent 引擎（清理 autocmd 监听器和 runner 状态）
  pcall(function()
    local sa_ok, sub_agent_engine = pcall(require, "NeoAI.core.ai.sub_agent_engine")
    if sa_ok and sub_agent_engine and sub_agent_engine.cleanup_all then
      sub_agent_engine.cleanup_all()
    end
  end)

  -- 2. 取消所有 HTTP 请求
  pcall(function()
    local http_ok, http_utils = pcall(require, "NeoAI.utils.http_utils")
    if http_ok and http_utils and http_utils.cancel_all_requests then
      http_utils.cancel_all_requests()
    end
  end)

  -- 2.5 清理 engine 的活跃生成状态（防止 HTTP 回调触发死循环）
  pcall(function()
    local ae_ok, engine = pcall(require, "NeoAI.core.ai.engine")
    if ae_ok and engine then
      if engine.cleanup_all_generations then
        engine.cleanup_all_generations()
      end
    end
  end)

  -- 3. 刷新 saver 队列（等待所有待处理保存完成）
  saver.shutdown_sync()

  -- 4. 清空 persistence 写入队列（避免异步回调在退出过程中执行）
  persistence.flush_queue()

  -- 5. 同步保存会话数据
  persistence.sync_save(state.sessions)
end

--- 加载会话数据
function M._load()
  local loaded = persistence.load()
  state.sessions = loaded
  -- 如果有已加载的会话，设置当前会话为最近更新的那个
  local latest_id = nil
  local latest_time = 0
  for id, session in pairs(loaded) do
    local t = session.updated_at or session.created_at or 0
    if t > latest_time then
      latest_time = t
      latest_id = id
    end
  end
  if latest_id then
    state.current_session_id = latest_id
  end
  trigger_event(Events.SESSION_LOADED, {
    session_count = vim.tbl_count(loaded),
    latest_session_id = latest_id,
  })
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
  -- 如果调用方显式传入了 name，直接使用；否则根据 auto_naming 决定默认值
  if name == nil then
    local auto_naming = (_config and _config.session and _config.session.auto_naming) ~= false
    name = auto_naming and "聊天会话" or ""
  end
  local session = {
    id = id,
    name = name,
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

  -- 注意：不在此处调用 _mark_dirty()，避免空会话被保存到历史文件
  -- 只有 add_round（用户发送消息）时才触发保存
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
  -- 如果调用方传了 name，直接使用；否则让 create_session 根据 auto_naming 决定
  local id = M.create_session(name, true, nil)
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

  local auto_naming = (_config and _config.session and _config.session.auto_naming) ~= false
  if auto_naming then
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
--- 同时保存结构化 table（完整数据）和折叠文本（UI 显示）
--- @param session_id string 会话ID
--- @param tool_name string 工具名称
--- @param arguments table 工具参数
--- @param result string|table 工具执行结果
--- @param pack_name string|nil 工具所属包名（如 "lsp_tools"、"file_tools"），nil 或 "_uncategorized" 表示未分类
function M.add_tool_result(session_id, tool_name, arguments, result, pack_name)
  local session = state.sessions[session_id]
  if not session then return false end

  -- 构建结构化 tool_call 条目，保留完整数据
  local tool_call_entry = {
    type = "tool_call",
    tool_name = tool_name or "unknown",
    arguments = arguments or {},
    result = result,
    pack_name = pack_name, -- 保存工具包分类信息
    timestamp = os.time(),
  }

  if type(session.assistant) ~= "table" then
    if session.assistant and session.assistant ~= "" then
      session.assistant = { session.assistant }
    else
      session.assistant = {}
    end
  end

  -- 尝试合并到上一条 tool_call 条目（同一次工具调用多结果合并）
  local last_idx = #session.assistant
  local appended = false
  if last_idx and last_idx > 0 then
    local last_entry = session.assistant[last_idx]
    -- 如果上一条也是同名的 tool_call，合并结果
    if type(last_entry) == "table" and last_entry.type == "tool_call" and last_entry.tool_name == tool_call_entry.tool_name then
      -- 将多个结果合并为数组
      if not last_entry.results then
        last_entry.results = { last_entry.result }
        last_entry.result = nil
      end
      table.insert(last_entry.results, result)
      -- 合并参数（如果不同）
      if not last_entry.arguments_list then
        last_entry.arguments_list = { last_entry.arguments }
      end
      table.insert(last_entry.arguments_list, arguments or {})
      last_entry.timestamp = os.time()
      appended = true
    end
  end

  if not appended then
    table.insert(session.assistant, tool_call_entry)
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

--- 将单个会话的消息展平为 role/content 列表（内部公共函数）
--- 委托给 message_builder.session_to_messages
--- @param session table 会话对象
--- @return table { {role, content}, ... }
function M._session_to_messages(session)
  return message_builder.session_to_messages(session)
end

--- 获取会话的所有消息（展平为 role/content 列表）
--- 委托给 _session_to_messages
function M.get_messages(session_id)
  local session = state.sessions[session_id]
  if not session then return {} end
  return M._session_to_messages(session)
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
  return message_builder.build_round_text(session)
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
  if session.name and session.name ~= "" then
    for _, dn in ipairs(default_names) do
      if session.name == dn or session.name:find("^" .. dn) then
        is_default = true
        break
      end
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

  local chat_service = require("NeoAI.core.ai.chat_service")
  chat_service.auto_name_session(session_id, user_msg, function(success, name_or_error)
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
  local auto_save = (_config and _config.session and _config.session.auto_save) ~= false
  if not auto_save then return end
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

-- ========== 外部变更检测 ==========

--- 检查文件是否有变化（基于行号缓存）
--- @return boolean
function M.has_file_changed()
  return persistence.has_file_changed()
end

--- 从文件重新加载会话数据（增量解析，只解析有变化的行）
--- @return boolean 是否成功重新加载
function M.reload_from_file()
  if not state.initialized then
    return false
  end

  local loaded = persistence.load()
  if not loaded then
    return false
  end

  state.sessions = loaded
  cache.invalidate_all()

  -- 触发事件通知 UI 刷新
  trigger_event(Events.SESSION_LOADED, {
    session_count = vim.tbl_count(loaded),
    latest_session_id = state.current_session_id,
  })

  logger.debug("[history_manager] 已从文件重新加载会话数据")
  return true
end

-- ========== 状态查询 ==========

function M.is_initialized()
  return state.initialized
end

-- ========== 重置（测试用） ==========

function M._test_reset()
  state.initialized = false
  state.sessions = {}
  state.current_session_id = nil
  state._is_shutting_down = false
  persistence._test_reset()
  cache._test_reset()
  saver._test_reset()

  local test_file = "/tmp/neoai_test_sessions/sessions.json"
  if vim.fn.filereadable(test_file) == 1 then
    pcall(vim.fn.delete, test_file)
  end
end

return M
