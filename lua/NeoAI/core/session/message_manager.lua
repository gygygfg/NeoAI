local M = {}

local SkipList = require("NeoAI.utils.skiplist")

-- 消息存储：使用跳表按时间序存储
-- 结构：{ [branch_id] = SkipList实例 }
-- 跳表 key = created_at 时间戳（微秒精度，冲突时 + 计数器）
-- 跳表 value = 消息对象
local branch_messages = {}
local message_counter = 0
local timestamp_counter = 0 -- 用于同一时间戳的消息排序

-- 消息ID到跳表位置的映射（用于快速查找）
local message_id_map = {}

-- 模块状态
local state = {
  initialized = false,
  event_bus = nil,
  config = nil,
}

--- 生成唯一的时间戳键
--- 使用 os.time() + 计数器，确保同一时间戳的消息有序
--- @return number 唯一键
local function generate_timestamp_key()
  timestamp_counter = timestamp_counter + 1
  -- 使用高精度时间：os.time() * 1000000 + 计数器
  -- 计数器范围 1-999999，确保同一秒内的消息有序
  return os.time() * 1000000 + (timestamp_counter % 999999 + 1)
end

--- 获取或创建分支的跳表
--- @param branch_id string 分支ID
--- @return table 跳表实例
local function get_or_create_skiplist(branch_id)
  if not branch_messages[branch_id] then
    branch_messages[branch_id] = SkipList:new({
      max_level = 16,
      probability = 0.5,
      unique = true, -- 每个 key 唯一
    })
  end
  return branch_messages[branch_id]
end

--- 初始化消息管理器
--- @param options table 选项
function M.initialize(options)
  if state.initialized then
    return
  end

  state.event_bus = options.event_bus
  state.config = options.config or {}
  state.initialized = true
end

--- 添加消息
--- @param branch_id string 分支ID
--- @param role string 角色（user/assistant/tool）
--- @param content string|table 消息内容
--- @param metadata table 元数据
--- @return string 消息ID
function M.add_message(branch_id, role, content, metadata)
  if not state.initialized then
    error("Message manager not initialized")
  end

  if not branch_id then
    error("Branch ID is required")
  end

  if not role or not (role == "user" or role == "assistant" or role == "tool") then
    error("Role must be 'user', 'assistant', or 'tool'")
  end

  message_counter = message_counter + 1
  local message_id = "msg_" .. message_counter
  local created_at = os.time()

  local message = {
    id = message_id,
    branch_id = branch_id,
    role = role,
    content = content,
    metadata = metadata or {},
    created_at = created_at,
    updated_at = created_at,
  }

  -- 生成跳表 key（时间戳 + 计数器保证有序）
  local skiplist_key = generate_timestamp_key()

  -- 存储到跳表
  local sl = get_or_create_skiplist(branch_id)
  sl:insert(skiplist_key, message)

  -- 存储到 ID 映射（用于快速查找）
  message_id_map[message_id] = {
    branch_id = branch_id,
    skiplist_key = skiplist_key,
  }

  -- 触发事件
  vim.api.nvim_exec_autocmds("User", { pattern = "NeoAI:message_added", data = { message_id, message } })

  -- 自动保存
  pcall(function()
    local session_manager = require("NeoAI.core.session.session_manager")
    if session_manager.is_initialized and session_manager.is_initialized() then
      session_manager._save_sessions()
    end
  end)

  return message_id
end

--- 获取消息（按时间序）
--- @param branch_id string 分支ID
--- @param limit number 限制数量
--- @return table 消息列表
function M.get_messages(branch_id, limit)
  if not branch_id then
    return {}
  end

  local sl = branch_messages[branch_id]
  if not sl then
    return {}
  end

  -- 使用跳表范围查询获取所有消息（按时间正序）
  return sl:range(-math.huge, math.huge, {
    limit = limit or math.huge,
    reverse = false,
  })
end

--- 获取最新 N 条消息（逆序）
--- @param branch_id string 分支ID
--- @param limit number 限制数量
--- @return table 消息列表
function M.get_latest_messages(branch_id, limit)
  if not branch_id then
    return {}
  end

  local sl = branch_messages[branch_id]
  if not sl then
    return {}
  end

  return sl:range(-math.huge, math.huge, {
    limit = limit or 10,
    reverse = true,
  })
end

--- 编辑消息
--- @param message_id string 消息ID
--- @param content string|table 新内容
function M.edit_message(message_id, content)
  local entry = message_id_map[message_id]
  if not entry then
    error("Message not found: " .. message_id)
  end

  local sl = branch_messages[entry.branch_id]
  if not sl then
    error("Branch not found for message: " .. message_id)
  end

  local message = sl:search(entry.skiplist_key)
  if not message then
    error("Message not found in skiplist: " .. message_id)
  end

  local old_content = message.content
  message.content = content
  message.updated_at = os.time()

  -- 触发事件
  vim.api.nvim_exec_autocmds("User", { pattern = "NeoAI:message_edited", data = { message_id, old_content, content } })

  -- 自动保存
  pcall(function()
    local session_manager = require("NeoAI.core.session.session_manager")
    if session_manager.is_initialized and session_manager.is_initialized() then
      session_manager._save_sessions()
    end
  end)
end

--- 更新消息
--- @param message_id string 消息ID
--- @param updates table 更新字段
function M.update_message(message_id, updates)
  local entry = message_id_map[message_id]
  if not entry then
    return false
  end

  local sl = branch_messages[entry.branch_id]
  if not sl then
    return false
  end

  local message = sl:search(entry.skiplist_key)
  if not message then
    return false
  end

  if not updates or type(updates) ~= "table" then
    return false
  end

  -- 应用更新
  for key, value in pairs(updates) do
    if key ~= "id" and key ~= "branch_id" and key ~= "created_at" then -- 保护关键字段
      message[key] = value
    end
  end

  message.updated_at = os.time()

  -- 触发消息更新事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = "NeoAI:message_updated",
    data = {
      message_id = message_id,
      message = message,
    }
  })

  -- 更新后立即保存
  pcall(function()
    local session_manager = require("NeoAI.core.session.session_manager")
    if session_manager.is_initialized and session_manager.is_initialized() then
      if session_manager._save_sessions then
        session_manager._save_sessions()
      end
    end
  end)

  return true
end

--- 删除消息
--- @param message_id string 消息ID
function M.delete_message(message_id)
  local entry = message_id_map[message_id]
  if not entry then
    return
  end

  local sl = branch_messages[entry.branch_id]
  if not sl then
    return
  end

  local message = sl:search(entry.skiplist_key)
  if not message then
    return
  end

  -- 从跳表中删除
  sl:delete(entry.skiplist_key)

  -- 从 ID 映射中删除
  message_id_map[message_id] = nil

  -- 触发事件
  vim.api.nvim_exec_autocmds("User", { pattern = "NeoAI:message_deleted", data = { message_id, message } })

  -- 自动保存
  pcall(function()
    local session_manager = require("NeoAI.core.session.session_manager")
    if session_manager.is_initialized and session_manager.is_initialized() then
      session_manager._save_sessions()
    end
  end)
end

--- 清空分支消息
--- @param branch_id string 分支ID
function M.clear_messages(branch_id)
  if not branch_id then
    return
  end

  local sl = branch_messages[branch_id]
  if not sl then
    return
  end

  -- 收集要删除的消息ID
  local deleted_ids = {}
  for _, msg in sl:iter() do
    if msg.branch_id == branch_id then
      table.insert(deleted_ids, msg.id)
    end
  end

  -- 清空 ID 映射
  for _, msg_id in ipairs(deleted_ids) do
    message_id_map[msg_id] = nil
  end

  -- 清空跳表
  sl:clear()

  -- 触发事件
  vim.api.nvim_exec_autocmds("User", { pattern = "NeoAI:messages_cleared", data = { branch_id, deleted_ids } })
end

--- 获取消息数量
--- @param branch_id string 分支ID
--- @return number 消息数量
function M.get_message_count(branch_id)
  if not branch_id then
    return 0
  end

  local sl = branch_messages[branch_id]
  if not sl then
    return 0
  end

  return sl:get_size()
end

--- 获取最新消息
--- @param branch_id string 分支ID
--- @return table|nil 最新消息
function M.get_latest_message(branch_id)
  if not branch_id then
    return nil
  end

  local sl = branch_messages[branch_id]
  if not sl then
    return nil
  end

  local latest = sl:last()
  if latest then
    return vim.deepcopy(latest)
  end
  return nil
end

--- 根据消息ID获取消息
--- @param message_id string 消息ID
--- @return table|nil 消息
function M.get_message_by_id(message_id)
  local entry = message_id_map[message_id]
  if not entry then
    return nil
  end

  local sl = branch_messages[entry.branch_id]
  if not sl then
    return nil
  end

  local message = sl:search(entry.skiplist_key)
  if message then
    return vim.deepcopy(message)
  end
  return nil
end

--- 获取指定时间范围内的消息
--- @param branch_id string 分支ID
--- @param start_time number 开始时间戳
--- @param end_time number 结束时间戳
--- @param opts table|nil 可选参数（limit, reverse）
--- @return table 消息列表
function M.get_messages_in_range(branch_id, start_time, end_time, opts)
  if not branch_id then
    return {}
  end

  local sl = branch_messages[branch_id]
  if not sl then
    return {}
  end

  -- 时间戳键的格式：os.time() * 1000000 + 计数器
  local min_key = start_time * 1000000
  local max_key = (end_time or math.huge) * 1000000 + 999999

  return sl:range(min_key, max_key, opts)
end

--- 重置消息管理器（主要用于测试）
function M.reset()
  branch_messages = {}
  message_counter = 0
  timestamp_counter = 0
  message_id_map = {}
  state.initialized = false
  state.event_bus = nil
  state.config = nil

  return true
end

return M
