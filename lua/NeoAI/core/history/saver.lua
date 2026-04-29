--- NeoAI 会话历史保存器
--- 职责：通过事件监听收集会话数据，使用队列与异步写入保证原子性
--- 监听的事件：
---   - GENERATION_COMPLETED: AI 生成完成（含本轮 AI 数据）
---   - TOOL_EXECUTION_COMPLETED: 工具执行完成
---   - TOOL_EXECUTION_ERROR: 工具执行出错
---   - USER_MESSAGE_SENT: 用户消息已发送

local M = {}

local logger = require("NeoAI.utils.logger")
local Events = require("NeoAI.core.events")
local async_worker = require("NeoAI.utils.async_worker")

-- ========== 状态 ==========

local state = {
  initialized = false,
  history_manager = nil,

  -- 写入队列（按会话分组，保证原子性）
  _save_queue = {},       -- { [session_id] = { pending: true, data: {...}, timer: nil } }
  _save_in_progress = {}, -- { [session_id] = true }
  _flush_timer = nil,     -- 批量刷新定时器
  _autocmd_ids = {},
}

-- ========== 内部：写入队列 ==========

--- 将保存任务加入队列（按会话去重合并）
--- @param session_id string 会话ID
--- @param save_fn function 保存函数：function() -> { content: string, callback: function|nil }
local function enqueue_save(session_id, save_fn)
  if not session_id then return end

  local entry = state._save_queue[session_id]
  if not entry then
    entry = { pending = true, save_fn = save_fn, timer = nil }
    state._save_queue[session_id] = entry
  else
    -- 已有待处理任务，更新 save_fn（取最新数据）
    entry.save_fn = save_fn
  end

  -- 启动防抖定时器（300ms 内合并多次写入）
  if entry.timer and not entry.timer:is_closing() then
    entry.timer:again()
  else
    entry.timer = vim.uv.new_timer()
    entry.timer:start(300, 0, vim.schedule_wrap(function()
      M._flush_session(session_id)
    end))
  end

  -- 启动全局批量刷新定时器（最迟 2s 强制刷新所有待处理会话）
  if not state._flush_timer or state._flush_timer:is_closing() then
    state._flush_timer = vim.uv.new_timer()
    state._flush_timer:start(2000, 0, vim.schedule_wrap(function()
      M.flush_all()
    end))
  end
end

--- 刷新单个会话的待处理保存
--- @param session_id string
function M._flush_session(session_id)
  local entry = state._save_queue[session_id]
  if not entry then return end
  if state._save_in_progress[session_id] then return end

  state._save_queue[session_id] = nil
  state._save_in_progress[session_id] = true

  if entry.timer and not entry.timer:is_closing() then
    entry.timer:stop()
    entry.timer:close()
  end

  -- 通过 async_worker 异步执行保存
  async_worker.submit_task(
    "history_save_" .. session_id,
    function()
      local ok, result = pcall(entry.save_fn)
      if ok then return result end
      return nil, tostring(result)
    end,
    function(success, result, error_msg)
      state._save_in_progress[session_id] = nil

      if not success then
        logger.warn("[history_saver] 会话保存失败: session=" .. session_id .. ", error=" .. tostring(error_msg))
        -- 重试：重新入队
        if entry.retry_count or 0 < 3 then
          entry.retry_count = (entry.retry_count or 0) + 1
          state._save_queue[session_id] = entry
          logger.warn("[history_saver] 重试保存 (" .. entry.retry_count .. "/3)")
        end
      end
    end,
    { timeout_ms = 5000 }
  )
end

--- 刷新所有待处理的会话保存
function M.flush_all()
  if state._flush_timer and not state._flush_timer:is_closing() then
    state._flush_timer:stop()
    state._flush_timer:close()
    state._flush_timer = nil
  end

  local session_ids = {}
  for sid, _ in pairs(state._save_queue) do
    table.insert(session_ids, sid)
  end
  for _, sid in ipairs(session_ids) do
    M._flush_session(sid)
  end
end

--- 清空所有待处理队列（关闭时使用）
function M.flush_queue()
  local count = 0
  for sid, _ in pairs(state._save_queue) do
    count = count + 1
    state._save_queue[sid] = nil
  end
  return count
end

-- ========== 事件监听器 ==========

--- 处理用户消息发送事件
--- 注意：chat_service.send_message 已处理分支创建逻辑，
--- 此处只负责保存用户消息到指定会话
local function on_user_message_sent(data)
  local session_id = data.session_id
  local content = data.message
  if not session_id or not content then return end

  enqueue_save(session_id, function()
    local hm = state.history_manager
    if not hm or not hm.is_initialized() then return false, "history_manager 未初始化" end

    -- 确保会话存在
    local session = hm.get_session(session_id)
    if not session then
      hm.set_current_session(session_id)
      session = hm.get_or_create_current_session()
    end
    if not session then return false, "无法创建会话: " .. session_id end

    -- 保存用户消息
    hm.add_round(session_id, content, "", {})
    return true
  end)
end

--- 处理 AI 生成完成事件
--- 事件数据包含本轮完整的 AI 回复（含 reasoning）
--- 注意：如果后续有 HISTORY_SAVE_FINAL 事件（含 UI 构建的折叠文本），
--- 此事件保存的内容会被覆盖。HISTORY_SAVE_FINAL 优先。
local function on_generation_completed(data)
  local session_id = data.session_id
  local response = data.response or ""
  local reasoning_text = data.reasoning_text or ""
  local usage = data.usage or {}

  if not session_id then return end
  if response == "" and reasoning_text == "" then return end

  enqueue_save(session_id, function()
    local hm = state.history_manager
    if not hm or not hm.is_initialized() then return false, "history_manager 未初始化" end

    local session = hm.get_session(session_id)
    if not session then return false, "会话不存在: " .. session_id end

    -- 构建含 reasoning 的 assistant 条目
    local assistant_entry
    if reasoning_text ~= "" then
      assistant_entry = {
        content = response,
        reasoning_content = reasoning_text,
      }
    else
      assistant_entry = { content = response }
    end

    -- 追加到 assistant 数组末尾
    hm.add_assistant_entry(session_id, assistant_entry)
    hm.update_usage(session_id, usage)
    return true
  end)
end

--- 处理历史保存最终内容事件（来自 chat_window，含 UI 构建的折叠文本）
--- 此事件优先于 GENERATION_COMPLETED，因为内容已包含 UI 层面的折叠文本
local function on_history_save_final(data)
  local session_id = data.session_id
  local content = data.content
  local reasoning_content = data.reasoning_content or ""
  local usage = data.usage or {}

  if not session_id or not content then return end

  enqueue_save(session_id, function()
    local hm = state.history_manager
    if not hm or not hm.is_initialized() then return false, "history_manager 未初始化" end

    local session = hm.get_session(session_id)
    if not session then return false, "会话不存在: " .. session_id end

    -- 构建含 reasoning 的 assistant 条目
    local assistant_entry
    if reasoning_content ~= "" then
      assistant_entry = {
        content = content,
        reasoning_content = reasoning_content,
      }
    else
      assistant_entry = { content = content }
    end

    -- 追加到 assistant 数组末尾
    hm.add_assistant_entry(session_id, assistant_entry)
    hm.update_usage(session_id, usage)
    return true
  end)
end

--- 处理工具执行完成事件
local function on_tool_execution_completed(data)
  local session_id = data.session_id
  local tool_name = data.tool_name
  local args = data.args
  local result = data.result

  if not session_id or not tool_name then return end

  -- 过滤掉注入的内部参数
  local clean_args = {}
  if type(args) == "table" then
    for k, v in pairs(args) do
      if k ~= "_session_id" and k ~= "_tool_call_id" then
        clean_args[k] = v
      end
    end
  else
    clean_args = args
  end

  enqueue_save(session_id, function()
    local hm = state.history_manager
    if not hm or not hm.is_initialized() then return false, "history_manager 未初始化" end
    hm.add_tool_result(session_id, tool_name, clean_args, result)
    return true
  end)
end

--- 处理工具执行错误事件
local function on_tool_execution_error(data)
  local session_id = data.session_id
  local tool_name = data.tool_name
  local args = data.args
  local error_msg = data.error_msg

  if not session_id or not tool_name then return end

  local clean_args = {}
  if type(args) == "table" then
    for k, v in pairs(args) do
      if k ~= "_session_id" and k ~= "_tool_call_id" then
        clean_args[k] = v
      end
    end
  else
    clean_args = args
  end

  enqueue_save(session_id, function()
    local hm = state.history_manager
    if not hm or not hm.is_initialized() then return false, "history_manager 未初始化" end
    hm.add_tool_result(session_id, tool_name, clean_args, "[错误] " .. tostring(error_msg))
    return true
  end)
end

-- ========== 初始化 ==========

function M.initialize(history_manager)
  if state.initialized then return end

  state.history_manager = history_manager

  -- 注册事件监听器
  local ids = {}

  -- 用户消息发送
  table.insert(ids, vim.api.nvim_create_autocmd("User", {
    pattern = Events.MESSAGE_SENT,
    callback = function(args)
      on_user_message_sent(args.data or {})
    end,
  }))

  -- AI 生成完成（含本轮 AI 数据）
  table.insert(ids, vim.api.nvim_create_autocmd("User", {
    pattern = Events.GENERATION_COMPLETED,
    callback = function(args)
      on_generation_completed(args.data or {})
    end,
  }))

  -- 工具执行完成
  table.insert(ids, vim.api.nvim_create_autocmd("User", {
    pattern = Events.TOOL_EXECUTION_COMPLETED,
    callback = function(args)
      on_tool_execution_completed(args.data or {})
    end,
  }))

  -- 工具执行错误
  table.insert(ids, vim.api.nvim_create_autocmd("User", {
    pattern = Events.TOOL_EXECUTION_ERROR,
    callback = function(args)
      on_tool_execution_error(args.data or {})
    end,
  }))

  -- 保存最终 AI 回复（含 UI 构建的折叠文本，来自 chat_window）
  table.insert(ids, vim.api.nvim_create_autocmd("User", {
    pattern = Events.HISTORY_SAVE_FINAL,
    callback = function(args)
      on_history_save_final(args.data or {})
    end,
  }))

  state._autocmd_ids = ids
  state.initialized = true

  logger.debug("[history_saver] 初始化完成，已注册事件监听器")
end

-- ========== 关闭 ==========

function M.shutdown()
  M.flush_all()

  for _, id in ipairs(state._autocmd_ids) do
    pcall(vim.api.nvim_del_autocmd, id)
  end
  state._autocmd_ids = {}

  state.initialized = false
  state._save_queue = {}
  state._save_in_progress = {}
end

--- 关闭并强制同步保存
function M.shutdown_sync()
  -- 先刷新所有待处理队列
  M.flush_all()

  -- 等待所有 async_worker 完成（最多 3s）
  local deadline = vim.loop.now() + 3000
  while vim.loop.now() < deadline do
    local has_pending = false
    for _, v in pairs(state._save_in_progress) do
      if v then has_pending = true; break end
    end
    if not has_pending then break end
    vim.wait(50, function() return false end)
  end

  -- 清理 autocmd
  for _, id in ipairs(state._autocmd_ids) do
    pcall(vim.api.nvim_del_autocmd, id)
  end
  state._autocmd_ids = {}

  state.initialized = false
  state._save_queue = {}
  state._save_in_progress = {}
end

--- 重置（测试用）
function M._test_reset()
  state.initialized = false
  state._save_queue = {}
  state._save_in_progress = {}
  if state._flush_timer and not state._flush_timer:is_closing() then
    state._flush_timer:stop()
    state._flush_timer:close()
  end
  state._flush_timer = nil
  for _, id in ipairs(state._autocmd_ids) do
    pcall(vim.api.nvim_del_autocmd, id)
  end
  state._autocmd_ids = {}
end

return M
