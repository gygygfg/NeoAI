local M = {}

-- 模块状态
local state = {
  initialized = false, -- 是否已初始化
  config = nil, -- 配置信息
  reasoning_active = false, -- 思考过程是否激活
  reasoning_text = "", -- 思考文本内容
  reasoning_start_time = nil, -- 思考开始时间
  reasoning_chunks = {}, -- 思考内容块
  event_group = nil, -- 事件组
  once_listeners = {}, -- 一次性监听器
}

--- 初始化思考过程管理器
--- @param options table 选项
function M.initialize(options)
  if state.initialized then
    return
  end

  state.config = options.config or {}
  state.initialized = true

  -- 创建事件组
  state.event_group = vim.api.nvim_create_augroup("NeoAIEvents", { clear = true })

  -- 监听思考内容事件
  vim.api.nvim_create_autocmd("User", {
    group = state.event_group,
    pattern = "reasoning_content",
    callback = function(args)
      local content = args.data and args.data[1] or ""
      -- 自动开始思考过程
      if not state.reasoning_active then
        M.start_reasoning()
      end

      M.append_reasoning(content)
    end,
    desc = "处理思考内容",
  })

  -- 监听思考块事件
  vim.api.nvim_create_autocmd("User", {
    group = state.event_group,
    pattern = "reasoning_chunk",
    callback = function(args)
      local chunk = args.data and args.data[1] or ""
      -- 自动开始思考过程
      if not state.reasoning_active then
        M.start_reasoning()
      end

      M.append_reasoning(chunk)
    end,
    desc = "处理思考块",
  })

  -- 监听思考开始事件
  vim.api.nvim_create_autocmd("User", {
    group = state.event_group,
    pattern = "reasoning_started",
    callback = function()
      -- 触发UI显示事件
      vim.api.nvim_exec_autocmds("User", {
        pattern = "show_reasoning_display",
      })
    end,
    desc = "思考开始",
  })

  -- 监听思考完成事件
  vim.api.nvim_create_autocmd("User", {
    group = state.event_group,
    pattern = "reasoning_finished",
    callback = function(args)
      local reasoning_text = args.data and args.data[1] or ""
      -- 触发UI关闭事件
      vim.api.nvim_exec_autocmds("User", {
        pattern = "close_reasoning_display",
        data = { reasoning_text },
      })
    end,
    desc = "思考完成",
  })
end

--- 开始思考过程
function M.start_reasoning()
  if not state.initialized then
    return
  end

  if state.reasoning_active then
    return
  end

  state.reasoning_active = true
  state.reasoning_text = ""
  state.reasoning_start_time = os.time()
  state.reasoning_chunks = {}

  -- 触发开始事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = "reasoning_started",
  })
end

--- 追加思考内容
--- @param content string 思考内容
function M.append_reasoning(content)
  if not state.initialized then
    return
  end

  if not state.reasoning_active then
    M.start_reasoning()
  end

  -- 添加内容（确保 content 不是 nil）
  local safe_content = content or ""

  -- 确保 safe_content 是字符串类型
  if type(safe_content) ~= "string" then
    safe_content = tostring(safe_content)
  end

  state.reasoning_text = state.reasoning_text .. safe_content
  table.insert(state.reasoning_chunks, {
    content = safe_content,
    timestamp = os.time(),
  })

  -- 触发追加事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = "reasoning_appended",
    data = { content, state.reasoning_text },
  })
end

--- 完成思考过程
function M.finish_reasoning()
  if not state.initialized then
    return
  end

  if not state.reasoning_active then
    return
  end

  local reasoning_duration = os.time() - (state.reasoning_start_time or os.time())
  state.reasoning_active = false

  -- 触发完成事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = "reasoning_finished",
    data = { state.reasoning_text, reasoning_duration },
  })

  -- 清空思考内容
  M.clear_reasoning()
end

--- 添加推理步骤（别名函数）
--- @param step string 推理步骤
function M.add_step(step)
  M.append_reasoning(step)
end

--- 完成推理（别名函数）
function M.complete_reasoning()
  M.finish_reasoning()
end

--- 获取推理内容
--- @return string 推理内容
function M.get_reasoning()
  return state.reasoning_text
end

--- 获取思考文本
--- @return string 思考文本
function M.get_reasoning_text()
  return state.reasoning_text
end

--- 清空思考
function M.clear_reasoning()
  state.reasoning_text = ""
  state.reasoning_chunks = {}
  state.reasoning_start_time = nil
end

--- 获取思考状态
--- @return table 思考状态
function M.get_reasoning_state()
  return {
    active = state.reasoning_active,
    text = state.reasoning_text,
    start_time = state.reasoning_start_time,
    duration = state.reasoning_start_time and (os.time() - state.reasoning_start_time) or 0,
    chunk_count = #state.reasoning_chunks,
  }
end

--- 获取思考块列表
--- @return table 思考块列表
function M.get_reasoning_chunks()
  return vim.deepcopy(state.reasoning_chunks)
end

--- 是否正在思考
--- @return boolean 是否正在思考
function M.is_reasoning_active()
  return state.reasoning_active
end

--- 获取思考摘要
--- @param max_length number 最大长度
--- @return string 思考摘要
function M.get_reasoning_summary(max_length)
  max_length = max_length or 200

  if #state.reasoning_text <= max_length then
    return state.reasoning_text
  end

  -- 简单截断
  local summary = state.reasoning_text:sub(1, max_length) .. "..."

  -- 尝试在句子边界截断
  local last_period = summary:reverse():find("%.")
  if last_period then
    summary = summary:sub(1, max_length - last_period + 1) .. "..."
  end

  return summary
end

--- 格式化思考内容为显示文本
--- @param reasoning_text_or_include_timestamps string|boolean 推理文本或是否包含时间戳
--- @return string 格式化后的文本
function M.format_reasoning(reasoning_text_or_include_timestamps)
  -- 处理字符串参数（推理文本）
  if type(reasoning_text_or_include_timestamps) == "string" then
    local reasoning_text = reasoning_text_or_include_timestamps
    if not reasoning_text or reasoning_text == "" then
      return ""
    end

    local lines = {}
    table.insert(lines, "=== 思考过程 ===")
    table.insert(lines, "")
    table.insert(lines, reasoning_text)
    table.insert(lines, "")
    table.insert(lines, "=== 思考结束 ===")

    return table.concat(lines, "\n")
  end

  -- 处理布尔参数（是否包含时间戳）
  local include_timestamps = reasoning_text_or_include_timestamps or false

  if not state.reasoning_text or state.reasoning_text == "" then
    return ""
  end

  if not include_timestamps or #state.reasoning_chunks == 0 then
    return state.reasoning_text
  end

  local lines = {}
  table.insert(lines, "=== 思考过程 ===")
  table.insert(lines, "")

  local start_time = state.reasoning_start_time
  for i, chunk in ipairs(state.reasoning_chunks) do
    local time_offset = chunk.timestamp - start_time
    local time_str = string.format("[+%ds]", time_offset)
    table.insert(lines, time_str .. " " .. chunk.content)
  end

  table.insert(lines, "")
  table.insert(lines, "=== 思考结束 ===")

  return table.concat(lines, "\n")
end

return M
