-- 思考过程管理
-- 负责管理 AI 的思考过程，包括开始、追加、结束和格式化思考内容
local M = {}

-- 导入事件常量
local event_constants = require("NeoAI.core.events.event_constants")

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
  state.event_group = vim.api.nvim_create_augroup("NeoAIReasoningEvents", { clear = true })

  -- 监听思考内容事件
  vim.api.nvim_create_autocmd("User", {
    group = state.event_group,
    pattern = event_constants.REASONING_CONTENT,
    callback = function(args)
      local content = args.data and args.data.reasoning_content or ""
      -- 自动开始思考过程
      if not state.reasoning_active then
        M.start_reasoning()
      end

      M.append_reasoning(content)
    end,
    desc = "处理思考内容",
  })

  -- 监听思考开始事件
  vim.api.nvim_create_autocmd("User", {
    group = state.event_group,
    pattern = event_constants.REASONING_STARTED,
    callback = function()
      M.start_reasoning()
    end,
    desc = "处理思考开始",
  })

  -- 监听思考完成事件
  vim.api.nvim_create_autocmd("User", {
    group = state.event_group,
    pattern = event_constants.REASONING_COMPLETED,
    callback = function()
      M.finish_reasoning()
    end,
    desc = "处理思考完成",
  })

  -- 触发配置加载事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.CONFIG_LOADED,
    data = {
      config = state.config,
    },
  })
end

--- 开始思考过程
--- @return nil
function M.start_reasoning()
  if not state.initialized then
    return
  end

  if state.reasoning_active then
    return
  end

  state.reasoning_active = true
  state.reasoning_start_time = os.time()
  state.reasoning_text = ""
  state.reasoning_chunks = {}

  -- 触发思考开始事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.REASONING_STARTED,
  })

  -- 触发日志事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.LOG_INFO,
    data = {
      message = "思考过程开始",
      timestamp = state.reasoning_start_time,
    },
  })
end

--- 追加思考内容
--- @param content string 思考内容
--- @return nil
function M.append_reasoning(content)
  if not state.initialized then
    return
  end

  if not state.reasoning_active then
    M.start_reasoning()
  end

  -- 确保内容是字符串
  local safe_content = content
  if type(safe_content) ~= "string" then
    safe_content = tostring(safe_content)
  end

  -- 添加到思考文本
  state.reasoning_text = state.reasoning_text .. safe_content

  -- 添加到思考块列表
  table.insert(state.reasoning_chunks, {
    content = safe_content,
    timestamp = os.time(),
  })

  -- 触发消息更新事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.MESSAGE_UPDATED,
    data = {
      message_id = "reasoning",
      message = {
        role = "assistant",
        content = state.reasoning_text,
        reasoning = true,
      },
    },
  })
end

--- 结束思考过程
--- @return nil
function M.finish_reasoning()
  if not state.initialized then
    return
  end

  if not state.reasoning_active then
    return
  end

  local reasoning_duration = os.time() - (state.reasoning_start_time or os.time())
  state.reasoning_active = false

  -- 触发思考完成事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.REASONING_COMPLETED,
    data = {
      reasoning_text = state.reasoning_text,
      duration = reasoning_duration,
    },
  })

  -- 触发日志事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.LOG_INFO,
    data = {
      message = string.format(
        "思考过程结束，时长：%d秒，内容长度：%d字符",
        reasoning_duration,
        #state.reasoning_text
      ),
      timestamp = os.time(),
    },
  })

  -- 触发消息更新事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.MESSAGE_UPDATED,
    data = {
      message_id = "reasoning",
      message = {
        role = "assistant",
        content = state.reasoning_text,
        reasoning = true,
        completed = true,
      },
    },
  })
end

--- 获取思考内容
--- @return string 思考文本
function M.get_reasoning()
  return state.reasoning_text
end

--- 获取思考文本
--- @return string 思考文本
function M.get_reasoning_text()
  return state.reasoning_text
end

--- 清除思考内容
--- @return nil
function M.clear_reasoning()
  if not state.initialized then
    return
  end

  state.reasoning_active = false
  state.reasoning_text = ""
  state.reasoning_start_time = nil
  state.reasoning_chunks = {}

  -- 触发消息删除事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.MESSAGE_DELETED,
    data = {
      message_id = "reasoning",
      message = {
        role = "assistant",
        content = "",
        reasoning = true,
      },
    },
  })
end

--- 检查思考过程是否激活
--- @return boolean 是否激活
function M.is_reasoning_active()
  return state.reasoning_active
end

--- 获取思考摘要
--- @param max_length number 最大长度
--- @return string 摘要
function M.get_reasoning_summary(max_length)
  if not state.reasoning_text or state.reasoning_text == "" then
    return ""
  end

  max_length = max_length or 200

  if #state.reasoning_text <= max_length then
    return state.reasoning_text
  end

  -- 截取前 max_length 个字符，并确保在完整单词处截断
  local summary = state.reasoning_text:sub(1, max_length)
  local last_space = summary:find("[%s%p]$")
  if last_space then
    summary = summary:sub(1, last_space - 1)
  end

  return summary .. "..."
end

--- 格式化思考内容
--- @param reasoning_text_or_include_timestamps string|boolean 思考文本或是否包含时间戳
--- @param include_timestamps boolean 是否包含时间戳
--- @return string 格式化后的思考文本
function M.format_reasoning(reasoning_text_or_include_timestamps, include_timestamps)
  local reasoning_text = state.reasoning_text
  local use_timestamps = include_timestamps or false

  -- 处理参数重载
  if type(reasoning_text_or_include_timestamps) == "string" then
    reasoning_text = reasoning_text_or_include_timestamps
    use_timestamps = include_timestamps or false
  elseif type(reasoning_text_or_include_timestamps) == "boolean" then
    use_timestamps = reasoning_text_or_include_timestamps
  end

  if not reasoning_text or reasoning_text == "" then
    return ""
  end

  if not use_timestamps then
    return reasoning_text
  end

  -- 格式化带时间戳的思考内容
  local formatted = ""
  for i, chunk in ipairs(state.reasoning_chunks) do
    local time_str = os.date("%H:%M:%S", chunk.timestamp)
    formatted = formatted .. string.format("[%s] %s\n", time_str, chunk.content)
  end

  return formatted
end

--- 获取思考状态
--- @return table 状态信息
function M.get_reasoning_state()
  return {
    active = state.reasoning_active,
    text_length = #state.reasoning_text,
    chunks_count = #state.reasoning_chunks,
    start_time = state.reasoning_start_time,
    duration = state.reasoning_start_time and (os.time() - state.reasoning_start_time) or 0,
  }
end

--- 添加一次性监听器
--- @param event_pattern string 事件模式
--- @param callback function 回调函数
function M.add_once_listener(event_pattern, callback)
  if not state.initialized then
    return
  end

  local listener_id = vim.api.nvim_create_autocmd("User", {
    group = state.event_group,
    pattern = event_pattern,
    callback = function(args)
      callback(args)
      vim.api.nvim_del_autocmd(listener_id)
      state.once_listeners[listener_id] = nil
    end,
    once = true,
  })

  state.once_listeners[listener_id] = true
end

--- 清理所有监听器
function M.cleanup()
  if state.event_group then
    vim.api.nvim_del_augroup_by_id(state.event_group)
    state.event_group = nil
  end

  -- 清理一次性监听器
  for listener_id, _ in pairs(state.once_listeners) do
    pcall(vim.api.nvim_del_autocmd, listener_id)
  end
  state.once_listeners = {}

  state.initialized = false

  -- 触发插件关闭事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.PLUGIN_SHUTDOWN,
  })
end

--- 导出模块
return M
