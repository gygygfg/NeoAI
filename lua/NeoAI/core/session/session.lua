--- 会话对象
--- @module NeoAI.core.session.session
--- 纯净数据结构 + 方法，无副作用、无 I/O。
--- 字段：id, parent_id, root_id, created_at, updated_at, model, messages, metadata

local stringx = require("NeoAI.utils.stringx")

local M = {}

-- ========== 构造函数 ==========

--- 创建会话对象
--- @param opts table|nil { parent_id?, root_id?, model?, metadata?, messages?, id? }
--- @return table 会话
function M.create(opts)
  opts = opts or {}
  local now = os.time()
  local id = opts.id or stringx.uuid("sess")
  local parent_id = opts.parent_id or nil
  local root_id = opts.root_id
  if not root_id then
    -- 子会话若未显式指定 root_id，以父会话为根（深层继承由 session_store 解析）
    root_id = parent_id or id
  end
  return {
    id = id,
    parent_id = parent_id,
    root_id = root_id,
    created_at = opts.created_at or now,
    updated_at = opts.updated_at or now,
    model = opts.model or nil,
    messages = vim.deepcopy(opts.messages or {}),
    metadata = vim.deepcopy(opts.metadata or {
      name = opts.name or nil,
      tags = {},
      usage = { prompt = 0, completion = 0 },
    }),
  }
end

-- ========== 序列化 ==========

--- 序列化为纯数据表（不含函数/引用）
--- @param session table
--- @return table
function M.serialize(session)
  return vim.deepcopy(session)
end

--- 反序列化
--- @param data table
--- @return table 会话
function M.deserialize(data)
  if not data or not data.id then
    error("会话数据无效：缺少 id")
  end
  return M.create({
    id = data.id,
    parent_id = data.parent_id,
    root_id = data.root_id,
    created_at = data.created_at,
    updated_at = data.updated_at,
    model = data.model,
    messages = data.messages,
    metadata = data.metadata,
  })
end

-- ========== 消息操作 ==========

--- 添加消息
--- @param session table
--- @param message table { role, content, reasoning?, tool_calls?, ts? }
--- @return table 会话（可变）
function M.add_message(session, message)
  local msg = vim.deepcopy(message)
  msg.ts = msg.ts or os.time()
  msg.id = msg.id or stringx.uuid("msg")
  table.insert(session.messages, msg)
  session.updated_at = os.time()
  -- 统计 usage
  if msg.role == "assistant" then
    local usage = session.metadata.usage or { prompt = 0, completion = 0 }
    if msg.content then
      usage.completion = usage.completion + (#msg.content)
    end
    session.metadata.usage = usage
  end
  return session
end

--- 获取消息
--- @param session table
--- @param index number 1-based
--- @return table|nil
function M.get_message(session, index)
  return session.messages[index]
end

--- 更新消息
--- @param session table
--- @param index number
--- @param patch table
--- @return table|nil
function M.update_message(session, index, patch)
  local msg = session.messages[index]
  if not msg then return nil end
  for k, v in pairs(patch) do
    msg[k] = v
  end
  session.updated_at = os.time()
  return msg
end

--- 删除消息
--- @param session table
--- @param index number
--- @return boolean
function M.delete_message(session, index)
  if not session.messages[index] then return false end
  table.remove(session.messages, index)
  session.updated_at = os.time()
  return true
end

--- 截断消息到指定数量（保留最近 n 条，含 system）
--- @param session table
--- @param max_count number|nil
--- @return table 会话
function M.trim_messages(session, max_count)
  max_count = max_count or 1000
  local msgs = session.messages
  if #msgs <= max_count then return session end
  local system_count = 0
  for _, m in ipairs(msgs) do
    if m.role == "system" then system_count = system_count + 1 end
  end
  local keep = system_count + (max_count - system_count)
  if keep <= system_count then keep = system_count + 1 end
  local trimmed = {}
  for i = 1, system_count do trimmed[i] = msgs[i] end
  local j = system_count + 1
  for i = #msgs - (max_count - system_count) + 1, #msgs do
    if i > system_count then
      trimmed[j] = msgs[i]
      j = j + 1
    end
  end
  session.messages = trimmed
  return session
end

--- 清空消息（保留 system 消息）
--- @param session table
--- @return table 会话
function M.clear_messages(session)
  local system = {}
  for _, m in ipairs(session.messages) do
    if m.role == "system" then system[#system + 1] = m end
  end
  session.messages = system
  session.updated_at = os.time()
  return session
end

-- ========== 元数据 ==========

--- 设置会话名称
--- @param session table
--- @param name string
--- @return table 会话
function M.rename(session, name)
  session.metadata.name = name
  session.updated_at = os.time()
  return session
end

--- 获取会话名称（无则用 id）
--- @param session table
--- @return string
function M.get_name(session)
  return session.metadata.name or session.id
end

--- 累加 usage
--- @param session table
--- @param usage table { prompt?, completion? }
--- @return table 会话
function M.add_usage(session, usage)
  local u = session.metadata.usage or { prompt = 0, completion = 0 }
  u.prompt = u.prompt + (usage.prompt or 0)
  u.completion = u.completion + (usage.completion or 0)
  session.metadata.usage = u
  return session
end

-- ========== 分支 ==========

--- 派生新会话（fork）
--- @param session table
--- @param opts table|nil { copy_messages? = true }
--- @return table 新会话（parent_id = session.id）
function M.fork(session, opts)
  opts = opts or {}
  local child = M.create({
    parent_id = session.id,
    root_id = session.root_id,
    model = session.model,
  })
  if opts.copy_messages then
    child.messages = vim.deepcopy(session.messages)
  end
  return child
end

--- 判断是否为根会话
--- @param session table
--- @return boolean
function M.is_root(session)
  return session.parent_id == nil or session.parent_id == session.id
end

return M
