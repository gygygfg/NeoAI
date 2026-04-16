-- NeoAI 后端模块
-- 负责会话管理、消息 CRUD、数据持久化（导入/导出）以及 AI 回复模拟
local M = {}
local config = require("NeoAI.config")
local utils = require("NeoAI.utils")
local llm_utils = require("NeoAI.llm_utils")

-- 模块状态变量
M.config_dir = nil -- 配置目录路径
M.config_file = nil -- 会话数据文件路径
M.sessions = {} -- 所有会话列表（节点集合）
M.session_graph = {} -- 有向图的邻接表表示：session_id -> {children = {id1, id2, ...}, parent = id}
M.current_session = nil -- 当前活跃会话 ID
M.message_handlers = {} -- 消息事件处理器映射表
M.editable_states = {} -- 消息可编辑状态缓存
M.llm_config = nil -- LLM API 配置（从 setup 传入的合并后配置）
M._session_counter = 0 -- 全局会话计数器（用于统一命名）

--- 自动同步指定会话数据到文件
-- @param session_id 会话 ID
function M._auto_sync(session_id)
  M.export_session(session_id, M.config_file, true)
end

--- 触发指定类型的事件，通知所有注册的处理器
-- @param event 事件名称
-- @param data 事件数据
function M._trigger(event, data)
  local handlers = M.message_handlers[event] or {}
  for _, handler in ipairs(handlers) do
    handler(data)
  end
end

--- 创建一个新的会话
-- @param name 会话名称（可选）
-- @param parent_id 父会话 ID（可选，用于构建有向图关系）
-- @return table 新创建的会话对象
function M.new_session(name, parent_id)
  local session_id = #M.sessions + 1
  M._session_counter = M._session_counter + 1

  -- 统一命名：根会话用"会话N"，分支用"会话父N-子序号"
  if not name then
    if parent_id then
      -- 分支：使用父会话ID和分支计数器
      M._branch_counters = M._branch_counters or {}
      M._branch_counters[parent_id] = (M._branch_counters[parent_id] or 0) + 1
      name = string.format("会话%d-%d", parent_id, M._branch_counters[parent_id])
    else
      name = "会话" .. M._session_counter
    end
  end

  local session = {
    id = session_id,
    name = name,
    messages = {}, -- 消息列表
    created_at = os.time(),
    updated_at = os.time(),
    config = {
      auto_scroll = M.validated_config and M.validated_config.ui and M.validated_config.ui.auto_scroll
        or config.defaults.ui.auto_scroll,
      show_timestamps = M.validated_config and M.validated_config.ui and M.validated_config.ui.show_timestamps
        or config.defaults.ui.show_timestamps,
      max_history = M.validated_config and M.validated_config.background and M.validated_config.background.max_history
        or config.defaults.background.max_history,
    },
  }

  M.sessions[session_id] = session

  -- 初始化有向图邻接表结构
  M.session_graph[session_id] = {
    children = {}, -- 子节点列表
    parent = parent_id or nil, -- 父节点 ID
  }

  -- 如果指定了父节点，建立有向边
  if parent_id and M.session_graph[parent_id] then
    table.insert(M.session_graph[parent_id].children, session_id)
  end

  M.current_session = session_id
  M._auto_sync(session_id) -- 自动持久化到文件
  M._trigger("session_created", session)

  return session
end

--- 向指定会话添加一条消息
-- @param session_id 会话 ID
-- @param message 消息对象
-- @return table|nil 添加的消息对象，或失败时返回 nil
function M.add_message(session_id, message)
  local session = M.sessions[session_id]
  if not session then
    return nil
  end

  table.insert(session.messages, message)
  session.updated_at = os.time()

  -- 如果消息数超出最大历史限制，删除最早的消息
  if session.config.max_history > 0 and #session.messages > session.config.max_history then
    table.remove(session.messages, 1)
  end

  M._auto_sync(session_id)
  M._trigger("message_added", { session_id = session_id, message = message })

  return message
end

--- 编辑指定会话中的某条消息
-- @param session_id 会话 ID
-- @param message_id 消息 ID
-- @param new_content 新的消息内容
-- @return boolean 是否编辑成功
function M.edit_message(session_id, message_id, new_content)
  local session = M.sessions[session_id]
  if not session then
    return false
  end

  for i, msg in ipairs(session.messages) do
    if tostring(msg.id) == tostring(message_id) then
      local old_content = msg.content
      msg.content = new_content
      msg.timestamp = os.time()
      session.updated_at = os.time()
      M._auto_sync(session_id)
      M._trigger("message_edited", {
        session_id = session_id,
        message_id = message_id,
        message = msg,
        old_content = old_content,
      })
      return true
    end
  end

  return false
end

--- 从缓冲区读取并保存编辑的消息（UI 层调用此接口）
-- 根据行号从缓冲区读取完整消息内容（支持多行/换行），然后调用 edit_message 保存
-- @param session_id 会话 ID
-- @param message_id 消息 ID
-- @param buf 缓冲区句柄
-- @param start_line 消息内容起始行（0-indexed）
-- @param end_line 消息内容结束行（0-indexed，不包含）
-- @return boolean, string? 是否成功, 失败原因（可选）
function M.save_buffer_edit(session_id, message_id, buf, start_line, end_line)
  -- 参数校验
  local session = M.sessions[session_id]
  if not session then
    return false, "会话不存在"
  end

  local target_msg = nil
  for _, msg in ipairs(session.messages) do
    if tostring(msg.id) == tostring(message_id) then
      target_msg = msg
      break
    end
  end

  if not target_msg then
    return false, "消息不存在"
  end

  -- 从缓冲区读取编辑后的内容
  local lines = vim.api.nvim_buf_get_lines(buf, start_line, end_line, false)
  if not lines or #lines == 0 then
    return false, "缓冲区内容为空"
  end

  local content = table.concat(lines, "\n")
  content = vim.trim(content)

  if content == "" then
    return false, "内容为空，未保存"
  end

  if content == target_msg.content then
    return false, "内容未修改"
  end

  -- 调用 edit_message 保存
  local success = M.edit_message(session_id, message_id, content)
  if success then
    local preview = string.sub(content, 1, 50)
    if #content > 50 then
      preview = preview .. "..."
    end
    return true, preview
  end

  return false, "保存失败"
end

--- 查找缓冲区中某行所属的消息对象
-- 根据当前缓冲区的内容行，重新计算行号到消息的映射，返回指定行对应的消息信息
-- @param session 会话对象
-- @param buf 缓冲区句柄
-- @param target_line 目标行号（0-indexed）
-- @param max_width 最大显示宽度（可选，默认60）
-- @return table? 消息信息 {session_id, message_id, start_line, end_line}，找不到返回 nil
function M.find_message_at_line(session, buf, target_line, max_width)
  if not session or not session.messages then
    return nil
  end

  max_width = max_width or 60
  local current_line = 0

  for i, msg in ipairs(session.messages) do
    -- 标题行（不可编辑）
    current_line = current_line + 1

    -- 跳过推理内容行
    if msg.metadata and msg.metadata.has_reasoning and msg.metadata.reasoning_content then
      local llm_config = M.llm_config or (M.validated_config and M.validated_config.llm) or config.defaults.llm
      if llm_config.show_reasoning then
        local is_complete = not msg.pending
        current_line = current_line
          + utils.count_reasoning_display_lines(msg.metadata.reasoning_content, max_width, is_complete, msg.id)
      end
    end

    -- 计算内容行（使用 utils.wrap_message_content）
    local wrap_width = max_width - 4
    local content_lines = utils.wrap_message_content(msg.content or "", wrap_width)
    local content_line_count = #content_lines

    local msg_start = current_line
    local msg_end = current_line + content_line_count

    -- 检查目标行是否在当前消息的内容范围内
    if target_line >= msg_start and target_line < msg_end then
      return {
        session_id = session.id,
        message_id = msg.id,
        start_line = msg_start,
        end_line = msg_end,
      }
    end

    current_line = msg_end

    -- 消息间的空行
    if i < #session.messages then
      current_line = current_line + 1
    end
  end

  return nil
end

--- 使用 curl 发起 HTTPS 流式请求到大模型 API
-- 支持 OpenAI 兼容的 API 格式，使用 SSE (Server-Sent Events) 协议
-- @param session_id 会话 ID
-- @param user_content 用户消息内容
-- @param on_chunk 流式数据块回调函数（每次收到新内容时调用）
-- @param on_complete 完成回调函数（请求完成或失败时调用）
function M.request_ai_stream(session_id, user_content, on_chunk, on_complete)
  local session = M.sessions[session_id]
  if not session then
    if on_complete then
      on_complete(false, "会话不存在")
    end
    return
  end

  -- 使用存储的 LLM 配置
  local llm_config = M.llm_config or (M.validated_config and M.validated_config.llm) or config.defaults.llm

  -- 验证 API 配置
  if not llm_config.api_key or llm_config.api_key == "" then
    local error_msg = "未配置 API 密钥"
    vim.notify("[NeoAI] " .. error_msg, vim.log.levels.ERROR)
    if on_complete then
      on_complete(false, error_msg)
    end
    return
  end

  -- 创建 pending 状态的占位消息
  local pending_msg = utils.create_message("assistant", "🔄 正在思考...", os.time(), { pending = true })
  pending_msg.pending = true
  M.add_message(session_id, pending_msg)

  -- 构建请求体（不包含工具）
  local messages = utils.build_api_messages(session, user_content, M.llm_config, M.validated_config)

  local request_body = vim.fn.json_encode({
    model = llm_config.model,
    messages = messages,
    stream = llm_config.stream,
    temperature = llm_config.temperature,
    max_tokens = llm_config.max_tokens,
    top_p = llm_config.top_p,
  })

  -- 创建临时文件
  local body_file = vim.fn.tempname() .. "_body.json"
  local tmp_file = vim.fn.tempname() .. ".sse"

  vim.fn.writefile({ request_body }, body_file)

  -- 构建 curl 命令
  local curl_cmd = string.format(
    "curl -s -N --connect-timeout 10 --max-time %d "
      .. '-X POST "%s" '
      .. '-H "Content-Type: application/json" '
      .. '-H "Authorization: Bearer %s" '
      .. '-d "@%s" > "%s" 2>&1',
    llm_config.timeout,
    llm_config.api_url,
    llm_config.api_key,
    body_file,
    tmp_file
  )

  local accumulated_content = ""
  local accumulated_reasoning = "" -- 推理/思考内容
  local request_finished = false
  local last_processed_pos = 0
  local last_update_time = 0
  local stream_update_interval = llm_config.stream_update_interval or 100 -- 默认100ms
  local last_reasoning_update_time = 0 -- 最后一次推理内容更新时间
  local min_reasoning_completion_delay = 100 -- 最小推理完成延迟（毫秒），确保思考过程真的结束了
  local min_reasoning_completion_delay = 100 -- 最小推理完成延迟（毫秒），确保思考过程真的结束了

  -- 启动后台 job
  local job_id = vim.fn.jobstart(curl_cmd, {
    on_exit = function(job, exit_code)
      vim.schedule(function()
        request_finished = true

        -- 读取完整的响应文件
        if vim.fn.filereadable(tmp_file) == 1 then
          local handle = io.open(tmp_file, "r")
          if handle then
            handle:seek("set", last_processed_pos)
            local remaining = handle:read("*a")
            handle:close()

            -- 处理剩余的 SSE 事件
            if remaining and remaining ~= "" then
              for line in remaining:gmatch("[^\r\n]+") do
                if line:match("^data:") then
                  local data = utils.parse_sse_data(line)
                  if data and data.choices and data.choices[1] then
                    local delta = data.choices[1].delta
                    if delta then
                      -- 提取推理内容
                      local reasoning = utils.extract_reasoning_from_delta(delta)
                      if reasoning then
                        accumulated_reasoning = accumulated_reasoning .. reasoning
                        pending_msg.metadata.reasoning_content = accumulated_reasoning
                        pending_msg.metadata.has_reasoning = true
                        pending_msg.metadata.reasoning_finished = false
                      end
                      -- 提取常规内容
                      if delta.content and delta.content ~= vim.NIL then
                        local content_str = type(delta.content) == "string" and delta.content or tostring(delta.content)
                        accumulated_content = accumulated_content .. content_str
                      end
                    end
                  end
                end
              end
            end

            -- 清理临时文件
            vim.fn.delete(tmp_file)
            vim.fn.delete(body_file)
          end
        end

        -- 更新消息为最终内容
        for i, msg in ipairs(session.messages) do
          if msg.id == pending_msg.id then
            local final_content
            if accumulated_content ~= "" then
              final_content = accumulated_content
            elseif accumulated_reasoning ~= "" then
              final_content = "思考完成:\n" .. accumulated_reasoning
            else
              final_content = "抱歉，未能生成回复。"
            end

            msg.content = final_content
            msg.pending = false
            msg.timestamp = os.time()
            -- 存储推理/思考内容到 metadata
            if accumulated_reasoning ~= "" then
              msg.metadata.reasoning_content = accumulated_reasoning
              msg.metadata.has_reasoning = true
            end
            break
          end
        end

        session.updated_at = os.time()
        M._auto_sync(session_id)

        -- 触发最后一次更新
        if on_chunk then
          on_chunk(accumulated_content)
        end

        -- 如果存在推理内容且尚未触发完成事件，触发推理完成事件
        -- 注意：如果已经在收到常规内容时触发过，这里不再重复触发
        if
          accumulated_reasoning ~= "" and (not pending_msg.metadata or not pending_msg.metadata.reasoning_finished)
        then
          -- 确保元数据存在
          pending_msg.metadata = pending_msg.metadata or {}
          pending_msg.metadata.reasoning_content = accumulated_reasoning
          pending_msg.metadata.has_reasoning = true
          pending_msg.metadata.reasoning_finished = true

          -- 同时更新会话中的消息元数据
          for i, msg in ipairs(session.messages) do
            if msg.id == pending_msg.id then
              msg.metadata = msg.metadata or {}
              msg.metadata.reasoning_content = accumulated_reasoning
              msg.metadata.has_reasoning = true
              msg.metadata.reasoning_finished = true
              break
            end
          end

          M._trigger("ai_reasoning_finished", {
            session_id = session_id,
            message = pending_msg,
          })
        end

        -- 触发完成回调
        if on_complete then
          -- 退出码为0表示请求成功，即使内容为空
          local success = exit_code == 0
          local error_msg
          if success then
            error_msg = nil
          else
            error_msg = "请求失败，退出码: " .. exit_code
          end

          -- 简化调试信息
          if not success then
            vim.notify(string.format("[NeoAI] 请求失败: exit_code=%d", exit_code), vim.log.levels.WARN)
          end

          on_complete(success, error_msg, accumulated_content)
        end

        M._trigger("ai_replied", {
          session_id = session_id,
          message = pending_msg,
          content = accumulated_content,
          reasoning_content = accumulated_reasoning,
        })
      end)
    end,
  })

  if job_id <= 0 then
    local error_msg = "无法启动 API 请求"
    vim.notify("[NeoAI] " .. error_msg, vim.log.levels.ERROR)

    for i, msg in ipairs(session.messages) do
      if msg.id == pending_msg.id then
        msg.content = "❌ " .. error_msg
        msg.pending = false
        msg.timestamp = os.time()
        break
      end
    end

    if on_complete then
      on_complete(false, error_msg)
    end
    return
  end

  -- 启动文件监听器
  local function watch_stream()
    if request_finished then
      vim.defer_fn(function() watch_stream() end, 50)
      return
    end

    if vim.fn.filereadable(tmp_file) == 1 then
      local file_size = vim.fn.getfsize(tmp_file)
      if file_size <= last_processed_pos then
        vim.defer_fn(function() watch_stream() end, 50)
        return
      end

      local handle = io.open(tmp_file, "r")
      if not handle then
        vim.defer_fn(function() watch_stream() end, 50)
        return
      end

      handle:seek("set", last_processed_pos)
      local new_content = handle:read("*a")
      handle:close()

      if not new_content or new_content == "" then
        vim.defer_fn(function() watch_stream() end, 50)
        return
      end

      last_processed_pos = last_processed_pos + #new_content

      -- 解析 SSE 事件
      for line in new_content:gmatch("[^\r\n]+") do
        if line:match("^data:") then
          local data = utils.parse_sse_data(line)
          if data and data.choices and data.choices[1] then
            local delta = data.choices[1].delta
            if delta then
              -- 提取推理内容
              local reasoning = utils.extract_reasoning_from_delta(delta)
              if reasoning then
                accumulated_reasoning = accumulated_reasoning .. reasoning
                pending_msg.metadata.reasoning_content = accumulated_reasoning
                pending_msg.metadata.has_reasoning = true
                pending_msg.metadata.reasoning_finished = false
                last_reasoning_update_time = vim.loop.now() -- 更新推理内容时间戳
                -- 触发推理内容更新事件
                M._trigger("ai_reasoning_update", {
                  session_id = session_id,
                  message = pending_msg,
                  reasoning_content = accumulated_reasoning,
                })
              end
              -- 提取常规内容
              if delta.content and delta.content ~= vim.NIL then
                local content_str = type(delta.content) == "string" and delta.content or tostring(delta.content)
                accumulated_content = accumulated_content .. content_str
                -- 实时更新消息内容，使 UI 能显示流式内容
                pending_msg.content = accumulated_content
                -- 同时更新会话中的消息内容
                for i, msg in ipairs(session.messages) do
                  if msg.id == pending_msg.id then
                    msg.content = accumulated_content
                    break
                  end
                end
                -- 当有常规内容且推理内容已存在时，检查是否应该关闭悬浮窗口
                -- 使用最小延迟确保思考过程真的结束了
                if accumulated_reasoning ~= "" and not pending_msg.metadata.reasoning_finished then
                  local current_time = vim.loop.now()
                  local time_since_last_reasoning = current_time - last_reasoning_update_time
                  
                  -- 如果推理内容已经停止更新超过100ms，则认为思考过程真的结束了
                  if time_since_last_reasoning >= min_reasoning_completion_delay then
                    pending_msg.metadata.reasoning_finished = true
                    -- 同时更新会话中的消息元数据
                    for i, msg in ipairs(session.messages) do
                      if msg.id == pending_msg.id then
                        msg.metadata = msg.metadata or {}
                        msg.metadata.reasoning_finished = true
                        break
                      end
                    end
                    -- 触发推理完成事件，关闭悬浮窗口
                    M._trigger("ai_reasoning_finished", {
                      session_id = session_id,
                      message = pending_msg,
                    })
                  end
                end
                -- 控制流式更新频率
                local current_time = vim.loop.now()
                if current_time - last_update_time >= stream_update_interval then
                  last_update_time = current_time
                  if on_chunk then
                    on_chunk(accumulated_content)
                  end
                end
              end
            end
          end
        end
      end
    end

    vim.defer_fn(function() watch_stream() end, 50)
  end

  watch_stream()
end

--- 执行工具调用
-- @param tool_name 工具名称
-- @param arguments 工具参数
-- @return table 工具执行结果
local function execute_tool_call(tool_name, arguments)
  local result = {}

  -- 根据工具名称调用对应的函数
  if tool_name == "shell_execute" then
    result = llm_utils.shell_execute(arguments)
  elseif tool_name == "read_file" then
    result = llm_utils.read_file(arguments)
  elseif tool_name == "write_file" then
    result = llm_utils.write_file(arguments)
  elseif tool_name == "list_directory" then
    result = llm_utils.list_directory(arguments)
  elseif tool_name == "analyze_code" then
    result = llm_utils.analyze_code(arguments)
  else
    result = { success = false, error = "未知工具: " .. tool_name }
  end

  -- 确保所有失败的结果都有 error 字段
  if not result.success then
    result.error = result.error or result.output or "未知错误"
  end

  return result
end

--- 处理工具调用并继续对话
-- @param session_id 会话 ID
-- @param tool_calls 工具调用列表
-- @param on_chunk 流式更新回调
-- @param on_complete 完成回调
local function handle_tool_calls(session_id, tool_calls, on_chunk, on_complete)
  local session = M.sessions[session_id]
  if not session then
    if on_complete then
      on_complete(false, "会话不存在")
    end
    return
  end

  -- 检查工具调用列表是否有效
  if not tool_calls or #tool_calls == 0 then
    -- 空工具调用列表，静默处理
    if on_complete then
      on_complete(true, nil, "")
    end
    return
  end

  -- 首先，更新助理消息以包含工具调用信息
  local assistant_msg = nil
  for i = #session.messages, 1, -1 do
    if session.messages[i].role == "assistant" and session.messages[i].pending then
      assistant_msg = session.messages[i]
      break
    end
  end

  if assistant_msg then
    -- 记录工具调用到元数据
    local tool_calls_metadata = {}
    for i = 1, #tool_calls do
      local tool_call = tool_calls[i]
      if tool_call then
        local func = tool_call["function"]
        if func and func.name then
          table.insert(tool_calls_metadata, {
            id = tool_call.id,
            name = func.name,
            arguments = func.arguments,
          })
        end
      end
    end

    assistant_msg.metadata = assistant_msg.metadata or {}
    assistant_msg.metadata.tool_calls = tool_calls_metadata
    assistant_msg.pending = false
    -- 当 AI 返回工具调用时，content 通常为 null 或空字符串
    -- 设置为空字符串以避免混淆
    assistant_msg.content = ""

    -- 同时更新会话中的消息内容
    for i, msg in ipairs(session.messages) do
      if msg.id == assistant_msg.id then
        msg.content = ""
        break
      end
    end

    -- 触发 AI 回复事件（工具调用场景）
    M._trigger("ai_replied", {
      session_id = session_id,
      message = assistant_msg,
      content = "",
      has_tool_calls = true,
    })
  end

  -- 注意：在工具调用场景中，我们不在这里调用 on_complete
  -- 整个对话流程包括：第一次请求（识别工具）→ 执行工具 → 第二次请求（基于工具结果回复）
  -- 只有当第二次请求完成后，整个对话才算完成

  -- 为每个工具调用执行并收集结果
  local tool_results = {}

  for i = 1, #tool_calls do
    local tool_call = tool_calls[i]
    if tool_call then
      local func = tool_call["function"]
      if not func or not func.name then
        -- 跳过不完整的工具调用条目
        goto continue
      end

      local tool_name = func.name
      local arguments = func.arguments

      -- 解析参数（如果是字符串）
      local parsed_args = {}
      if type(arguments) == "string" then
        if arguments ~= "" then
          local ok, decoded = pcall(vim.fn.json_decode, arguments)
          if ok and decoded then
            parsed_args = decoded
          else
            -- JSON 解析失败，尝试作为简单参数处理
            parsed_args = {}
            -- 对于某些工具，可以将字符串作为单个参数
            if tool_name == "shell_execute" then
              parsed_args.command = arguments
            elseif tool_name == "read_file" then
              parsed_args.filepath = arguments
            end
          end
        else
          parsed_args = {}
        end
      else
        parsed_args = arguments or {}
      end

      -- 执行工具
      local result = execute_tool_call(tool_name, parsed_args)

      -- 格式化结果
      local formatted_result = ""
      if result.success then
        if result.content then
          formatted_result = result.content
        elseif result.output then
          formatted_result = result.output
        elseif result.analysis then
          formatted_result = "分析结果:\n" .. vim.fn.json_encode(result.analysis)
        else
          formatted_result = "操作成功"
        end

        -- 直接打印工具执行结果
        -- 工具执行成功，不显示通知
      else
        -- 确保有错误信息
        local error_msg = result.error or result.output or "未知错误"
        formatted_result = "错误: " .. error_msg

        -- 只在工具执行失败时显示错误通知
        vim.notify(string.format("[NeoAI] 工具调用失败: %s - %s", tool_name, error_msg), vim.log.levels.WARN)
      end

      table.insert(tool_results, {
        tool_call_id = tool_call.id,
        role = "tool",
        name = tool_name,
        content = formatted_result,
      })
    end
    ::continue::
  end

  -- 将工具结果添加到消息历史中
  for _, result in ipairs(tool_results) do
    -- 工具结果消息的content字段设置为空或简化的提示，避免工具输出被打印到正文中
    -- 完整的工具结果保存在metadata.tool_result_content中，供悬浮文本显示
    local tool_content = "" -- 设置为空，不显示在正文中

    local tool_msg = utils.create_message(result.role, tool_content, os.time(), {
      tool_name = result.name,
      tool_call_id = result.tool_call_id,
      -- 标记为工具执行结果，支持悬浮文本显示
      is_tool_result = true,
      tool_result_content = result.content,
    })
    M.add_message(session_id, tool_msg)

    -- 触发工具结果添加事件，UI层可以显示悬浮文本
    M._trigger("tool_result_added", {
      session_id = session_id,
      message = tool_msg,
      tool_name = result.name,
      tool_content = result.content,
    })
  end

  -- 继续对话：使用工具结果再次请求 AI
  local last_user_msg = nil
  for i = #session.messages, 1, -1 do
    if session.messages[i].role == "user" then
      last_user_msg = session.messages[i]
      break
    end
  end

  if last_user_msg then
    -- 重新请求 AI，这次包含工具结果
    -- 注意：这里需要传递一个新的 on_complete 回调，让 UI 层知道第二次请求已完成
    -- 工具执行是第一次请求的一部分，第二次请求是新的对话轮次

    -- 在工具调用场景中，第二次请求需要明确的提示
    -- 告诉AI基于工具结果生成回复

    -- 收集工具结果内容
    local tool_results = {}
    for _, msg in ipairs(session.messages) do
      if msg.role == "tool" and msg.content then
        table.insert(tool_results, msg.content)
      end
    end

    local second_request_prompt
    if #tool_results > 0 then
      -- 如果有工具结果，告诉AI基于工具结果生成回复，但不直接包含工具结果内容
      -- 这样可以避免工具输出被直接打印到正文中
      second_request_prompt =
        "我已经执行了你请求的工具操作。请基于工具执行的结果，用自然语言总结或解释，帮助用户理解。不要直接引用工具输出的原始内容，而是提供有意义的解释和总结。"
    else
      second_request_prompt =
        "我已经执行了你请求的工具操作。请基于工具返回的结果，用自然语言总结或解释这些结果，帮助用户理解。"
    end

    -- 构建专门用于工具调用后回复的消息列表
    -- 我们需要移除工具调用消息，因为AI看到工具调用消息会认为需要继续调用工具
    local messages = {}

    -- 添加系统提示
    local sys_prompt = M.llm_config and M.llm_config.system_prompt
    if not sys_prompt and M.validated_config then
      if M.validated_config.defaults then
        sys_prompt = M.validated_config.defaults.llm.system_prompt
      elseif M.validated_config.llm then
        sys_prompt = M.validated_config.llm.system_prompt
      end
    end
    sys_prompt = sys_prompt or ""
    if sys_prompt and sys_prompt ~= "" then
      table.insert(messages, {
        role = "system",
        content = sys_prompt,
      })
    end

    -- 添加历史消息，但过滤掉工具调用相关的消息
    -- 我们只保留用户消息和工具结果消息
    local last_user_msg_content = nil
    for _, msg in ipairs(session.messages) do
      if msg.role == "user" then
        -- 用户消息
        last_user_msg_content = msg.content or ""
        table.insert(messages, {
          role = "user",
          content = last_user_msg_content,
        })
      elseif msg.role == "tool" then
        -- 在第二次请求中，我们不直接包含工具消息
        -- 而是将工具结果整合到后续的用户消息中
        -- 这里跳过工具消息，它的内容会在后续的提示中使用
      elseif msg.role == "assistant" then
        -- 对于助手消息，在工具调用后的第二次请求中，我们使用简化的消息
        -- 不包含 tool_calls 字段，避免API期望继续工具调用
        if msg.metadata and msg.metadata.tool_calls then
          -- 这是工具调用消息，我们使用一个简化的版本
          -- 告诉AI工具已经执行完成
          table.insert(messages, {
            role = "assistant",
            content = "我已经执行了请求的工具操作。",
          })
        elseif msg.content and msg.content ~= "" then
          -- 普通助手消息
          table.insert(messages, {
            role = "assistant",
            content = msg.content or "",
          })
        end
      end
    end

    -- 添加第二次请求的提示
    -- 如果最后一条消息已经是用户消息，并且内容与我们的提示相似，则不需要重复添加
    local should_add_prompt = true
    if last_user_msg_content and last_user_msg_content:find("请基于工具执行结果生成回复") then
      should_add_prompt = false
    end

    if should_add_prompt then
      table.insert(messages, {
        role = "user",
        content = second_request_prompt,
      })
    end

    -- 移除调试信息，简化日志输出

    -- 创建新的pending消息用于第二次回复
    local second_pending_msg =
      utils.create_message("assistant", "🔄 正在分析工具结果...", os.time(), { pending = true })
    second_pending_msg.pending = true
    M.add_message(session_id, second_pending_msg)

    -- 构建请求体（不包含工具）
    local llm_config = M.llm_config or (M.validated_config and M.validated_config.llm) or config.defaults.llm

    local request_body = vim.fn.json_encode({
      model = llm_config.model,
      messages = messages,
      stream = llm_config.stream,
      temperature = llm_config.temperature,
      max_tokens = llm_config.max_tokens,
      top_p = llm_config.top_p,
    })

    -- 创建临时文件
    local body_file = vim.fn.tempname() .. "_body_tool_result.json"
    local tmp_file = vim.fn.tempname() .. "_tool_result.sse"

    vim.fn.writefile({ request_body }, body_file)

    -- 构建 curl 命令
    local curl_cmd = string.format(
      "curl -s -N --connect-timeout 10 --max-time %d "
        .. '-X POST "%s" '
        .. '-H "Content-Type: application/json" '
        .. '-H "Authorization: Bearer %s" '
        .. '-d "@%s" > "%s" 2>&1',
      llm_config.timeout,
      llm_config.api_url,
      llm_config.api_key,
      body_file,
      tmp_file
    )

    local accumulated_content = ""
    local accumulated_reasoning = "" -- 推理/思考内容
    local request_finished = false
    local last_processed_pos = 0
    local last_update_time = 0
    local stream_update_interval = llm_config.stream_update_interval or 100
    local last_reasoning_update_time = 0 -- 最后一次推理内容更新时间
    local min_reasoning_completion_delay = 100 -- 最小推理完成延迟（毫秒），确保思考过程真的结束了

    -- 为第二次请求创建一个本地的 on_complete 回调
    -- 注意：这里使用闭包来访问外部的 on_complete 参数
    local second_request_on_complete = function(success, error_msg, final_content)
      if success then
        M._trigger("response_received", {
          session_id = session_id,
          response = final_content or accumulated_content,
        })
        M._trigger("ai_replied", {
          session_id = session_id,
          message = second_pending_msg,
          content = final_content or accumulated_content,
          reasoning_content = accumulated_reasoning,
        })
        -- 如果存在原始的 on_complete 回调，也调用它
        if on_complete then
          on_complete(success, error_msg, final_content or accumulated_content)
        end
      else
        vim.notify("[NeoAI] AI 回复失败: " .. (error_msg or "未知错误"), vim.log.levels.WARN)
        -- 如果存在原始的 on_complete 回调，也调用它
        if on_complete then
          on_complete(success, error_msg, final_content or accumulated_content)
        end
      end
    end

    -- 启动后台 job
    local job_id = vim.fn.jobstart(curl_cmd, {
      on_exit = function(job, exit_code)
        vim.schedule(function()
          request_finished = true

          -- 读取完整的响应文件
          if vim.fn.filereadable(tmp_file) == 1 then
            local handle = io.open(tmp_file, "r")
            if handle then
              handle:seek("set", last_processed_pos)
              local remaining = handle:read("*a")
              handle:close()

              -- 解析剩余的SSE数据以提取内容
              for line in remaining:gmatch("[^\r\n]+") do
                if line:match("^data:") then
                  local data = utils.parse_sse_data(line)
                  if data and data.choices and data.choices[1] then
                    local delta = data.choices[1].delta
                    -- 收集推理内容
                    if delta.reasoning_content and delta.reasoning_content ~= vim.NIL then
                      local reasoning_str = type(delta.reasoning_content) == "string" and delta.reasoning_content or tostring(delta.reasoning_content)
                      accumulated_reasoning = accumulated_reasoning .. reasoning_str
                    end
                    -- 收集内容
                    if delta and delta.content and delta.content ~= vim.NIL then
                      local content_str = type(delta.content) == "string" and delta.content or tostring(delta.content)
                      accumulated_content = accumulated_content .. content_str
                    end
                  end
                end
              end

              -- 清理临时文件
              vim.fn.delete(tmp_file)
              vim.fn.delete(body_file)
            end
          end

          -- 更新消息为最终内容
          for i, msg in ipairs(session.messages) do
            if msg.id == second_pending_msg.id then
              local final_content
              if accumulated_content ~= "" then
                final_content = accumulated_content
              else
                final_content = "抱歉，未能生成回复。"
              end

              msg.content = final_content
              msg.pending = false
              msg.timestamp = os.time()

              -- 存储推理内容
              if accumulated_reasoning ~= "" then
                msg.metadata = msg.metadata or {}
                msg.metadata.reasoning_content = accumulated_reasoning
                msg.metadata.has_reasoning = true
              end

              break
            end
          end

          session.updated_at = os.time()
          M._auto_sync(session_id)

          -- 如果存在推理内容且尚未触发完成事件，触发推理完成事件
          if accumulated_reasoning ~= "" and (not second_pending_msg.metadata or not second_pending_msg.metadata.reasoning_finished) then
            second_pending_msg.metadata = second_pending_msg.metadata or {}
            second_pending_msg.metadata.reasoning_content = accumulated_reasoning
            second_pending_msg.metadata.has_reasoning = true
            second_pending_msg.metadata.reasoning_finished = true

            M._trigger("ai_reasoning_finished", {
              session_id = session_id,
              message = second_pending_msg,
            })
          end

          -- 简化调试信息
          if exit_code ~= 0 then
            vim.notify(string.format("[NeoAI] 第二次请求失败: exit_code=%d", exit_code), vim.log.levels.WARN)
          end

          -- 调用本地的 on_complete 回调
          local success = exit_code == 0
          local error_msg = success and nil or "请求失败，退出码: " .. exit_code
          second_request_on_complete(success, error_msg, accumulated_content)
        end)
      end,
    })

    if job_id <= 0 then
      local error_msg = "无法启动 API 请求"
      vim.notify("[NeoAI] " .. error_msg, vim.log.levels.ERROR)

      for i, msg in ipairs(session.messages) do
        if msg.id == second_pending_msg.id then
          msg.content = "❌ " .. error_msg
          msg.pending = false
          msg.timestamp = os.time()
          break
        end
      end
      return
    end

    -- 启动文件监听器
    local function watch_stream()
      if request_finished then
        return
      end

      if vim.fn.filereadable(tmp_file) == 1 then
        local file_size = vim.fn.getfsize(tmp_file)
        if file_size <= last_processed_pos then
          vim.defer_fn(function() watch_stream() end, 50)
          return
        end

        local handle = io.open(tmp_file, "r")
        if not handle then
          vim.defer_fn(function() watch_stream() end, 50)
          return
        end

        handle:seek("set", last_processed_pos)
        local new_content = handle:read("*a")
        handle:close()

        if not new_content or new_content == "" then
          vim.defer_fn(function() watch_stream() end, 50)
          return
        end

        last_processed_pos = last_processed_pos + #new_content

        -- 解析 SSE 事件
        for line in new_content:gmatch("[^\r\n]+") do
          if line:match("^data:") then
            local data = utils.parse_sse_data(line)
            if data and data.choices and data.choices[1] then
              local delta = data.choices[1].delta

              -- 收集推理内容
              if delta.reasoning_content and delta.reasoning_content ~= vim.NIL then
                local reasoning_str = type(delta.reasoning_content) == "string" and delta.reasoning_content or tostring(delta.reasoning_content)
                accumulated_reasoning = accumulated_reasoning .. reasoning_str
                last_reasoning_update_time = vim.loop.now()

                -- 触发推理更新事件
                M._trigger("ai_reasoning_update", {
                  session_id = session_id,
                  message = second_pending_msg,
                  reasoning_content = accumulated_reasoning,
                })
              end

              -- 收集内容
              if delta and delta.content and delta.content ~= vim.NIL then
                local content_str = type(delta.content) == "string" and delta.content or tostring(delta.content)
                accumulated_content = accumulated_content .. content_str

                -- 实时更新消息内容
                for i, msg in ipairs(session.messages) do
                  if msg.id == second_pending_msg.id then
                    msg.content = accumulated_content
                    break
                  end
                end
                -- 触发流式更新事件
                M._trigger("ai_stream_update", {
                  session_id = session_id,
                  content = accumulated_content,
                })

                -- 控制流式更新频率
                local current_time = vim.loop.now()
                if current_time - last_update_time >= stream_update_interval then
                  last_update_time = current_time
                  if on_chunk then
                    on_chunk(accumulated_content)
                  end
                end
              end

              -- 检查推理内容是否完成
              if accumulated_reasoning ~= "" and not second_pending_msg.metadata.reasoning_finished then
                local current_time = vim.loop.now()
                local time_since_last_reasoning = current_time - last_reasoning_update_time

                if time_since_last_reasoning >= min_reasoning_completion_delay then
                  second_pending_msg.metadata = second_pending_msg.metadata or {}
                  second_pending_msg.metadata.reasoning_finished = true

                  -- 同时更新会话中的消息元数据
                  for i, msg in ipairs(session.messages) do
                    if msg.id == second_pending_msg.id then
                      msg.metadata = msg.metadata or {}
                      msg.metadata.reasoning_finished = true
                      break
                    end
                  end

                  M._trigger("ai_reasoning_finished", {
                    session_id = session_id,
                    message = second_pending_msg,
                  })
                end
              end
            end
          end
        end
      end
    end

    vim.defer_fn(function() watch_stream() end, 50)

    watch_stream()
  else
    if on_complete then
      on_complete(false, "未找到用户消息")
    end
  end
end

--- 使用 function calling 发起 AI 请求
-- @param session_id 会话 ID
-- @param user_content 用户消息内容
-- @param on_chunk 流式数据块回调函数
-- @param on_complete 完成回调函数
function M.request_ai_stream_with_tools(session_id, user_content, on_chunk, on_complete)
  local session = M.sessions[session_id]
  if not session then
    if on_complete then
      on_complete(false, "会话不存在")
    end
    return
  end

  -- 使用存储的 LLM 配置
  local llm_config = M.llm_config or (M.validated_config and M.validated_config.llm) or config.defaults.llm

  -- 验证 API 配置
  if not llm_config.api_key or llm_config.api_key == "" then
    local error_msg = "未配置 API 密钥"
    vim.notify("[NeoAI] " .. error_msg, vim.log.levels.ERROR)
    if on_complete then
      on_complete(false, error_msg)
    end
    return
  end

  -- 创建 pending 状态的占位消息
  local pending_msg = utils.create_message("assistant", "🔄 正在思考...", os.time(), { pending = true })
  pending_msg.pending = true
  M.add_message(session_id, pending_msg)

  -- 构建请求体（包含工具）
  local messages = utils.build_api_messages(session, user_content, M.llm_config, M.validated_config)
  local tools = llm_utils.get_tools()

  local request_body = vim.fn.json_encode({
    model = llm_config.model,
    messages = messages,
    stream = llm_config.stream,
    temperature = llm_config.temperature,
    max_tokens = llm_config.max_tokens,
    top_p = llm_config.top_p,
    tools = tools,
    tool_choice = "auto",
  })

  -- 创建临时文件
  local body_file = vim.fn.tempname() .. "_body.json"
  local tmp_file = vim.fn.tempname() .. ".sse"

  vim.fn.writefile({ request_body }, body_file)

  -- 构建 curl 命令
  local curl_cmd = string.format(
    "curl -s -N --connect-timeout 10 --max-time %d "
      .. '-X POST "%s" '
      .. '-H "Content-Type: application/json" '
      .. '-H "Authorization: Bearer %s" '
      .. '-d "@%s" > "%s" 2>&1',
    llm_config.timeout,
    llm_config.api_url,
    llm_config.api_key,
    body_file,
    tmp_file
  )

  local accumulated_content = ""
  local accumulated_reasoning = "" -- 推理/思考内容
  local tool_calls = {}
  local has_tool_calls = false
  local request_finished = false
  local last_processed_pos = 0
  local last_update_time = 0
  local stream_update_interval = llm_config.stream_update_interval or 100 -- 默认100ms
  local last_reasoning_update_time = 0 -- 最后一次推理内容更新时间
  local min_reasoning_completion_delay = 100 -- 最小推理完成延迟（毫秒），确保思考过程真的结束了

  -- 启动后台 job
  local job_id = vim.fn.jobstart(curl_cmd, {
    on_exit = function(job, exit_code)
      vim.schedule(function()
        request_finished = true

        -- 读取完整的响应文件
        if vim.fn.filereadable(tmp_file) == 1 then
          local handle = io.open(tmp_file, "r")
          if handle then
            handle:seek("set", last_processed_pos)
            local remaining = handle:read("*a")
            handle:close()

            -- 处理剩余的 SSE 事件
            if remaining and remaining ~= "" then
              for line in remaining:gmatch("[^\r\n]+") do
                if line:match("^data:") then
                  local data = utils.parse_sse_data(line)
                  if data and data.choices and data.choices[1] then
                    local delta = data.choices[1].delta

                    -- 检查是否有工具调用
                    if delta.tool_calls then
                      has_tool_calls = true
                      for _, tool_call in ipairs(delta.tool_calls) do
                        local idx = tool_call.index or 0
                        -- 合并流式片段：按 index 合并
                        if not tool_calls[idx + 1] then
                          tool_calls[idx + 1] = tool_call
                        else
                          local existing = tool_calls[idx + 1]
                          -- 合并 id、type、name 等新字段
                          if tool_call.id then
                            existing.id = tool_call.id
                          end
                          if tool_call.type then
                            existing.type = tool_call.type
                          end
                          if tool_call["function"] then
                            existing["function"] = existing["function"] or {}
                            if tool_call["function"].name then
                              existing["function"].name = tool_call["function"].name
                            end
                            if tool_call["function"].arguments then
                              existing["function"].arguments = (existing["function"].arguments or "")
                                .. tool_call["function"].arguments
                            end
                          end
                        end
                      end
                    end

                    -- 收集内容
                    if delta.content and delta.content ~= vim.NIL then
                      local content_str = type(delta.content) == "string" and delta.content or tostring(delta.content)
                      accumulated_content = accumulated_content .. content_str
                      -- 实时更新消息内容，使 UI 能显示流式内容
                      pending_msg.content = accumulated_content
                      -- 同时更新会话中的消息内容
                      for i, msg in ipairs(session.messages) do
                        if msg.id == pending_msg.id then
                          msg.content = accumulated_content
                          break
                        end
                      end
                      -- 控制流式更新频率
                      local current_time = vim.loop.now()
                      if current_time - last_update_time >= stream_update_interval then
                        last_update_time = current_time
                        if on_chunk then
                          on_chunk(accumulated_content)
                        end
                      end
                    end

                    -- 提取推理内容
                    local reasoning = utils.extract_reasoning_from_delta(delta)
                    if reasoning then
                      accumulated_reasoning = accumulated_reasoning .. reasoning
                      pending_msg.metadata.reasoning_content = accumulated_reasoning
                      pending_msg.metadata.has_reasoning = true
                      pending_msg.metadata.reasoning_finished = false
                      last_reasoning_update_time = vim.loop.now() -- 更新推理内容时间戳
                    end
                  end
                end
              end
            end

            -- 清理临时文件
            vim.fn.delete(tmp_file)
            vim.fn.delete(body_file)
          end
        end

        -- 更新消息
        for i, msg in ipairs(session.messages) do
          if msg.id == pending_msg.id then
            if has_tool_calls and #tool_calls > 0 then
              -- 有工具调用，处理工具调用
              msg.content = "🔧 正在执行工具..."
              msg.pending = false
              msg.timestamp = os.time()

              -- 处理工具调用
              handle_tool_calls(session_id, tool_calls, on_chunk, on_complete)
              return -- 有工具调用时，直接返回，不执行后续的完成回调
            else
              -- 没有工具调用，正常完成
              local final_content = ""

              -- 如果 accumulated_content 不为空，使用它
              if accumulated_content ~= "" then
                final_content = accumulated_content
              else
                -- 更可靠的检测：检查整个会话历史中是否有工具调用
                -- 因为第二次请求时，pending_msg是新的，工具调用消息在历史中
                local has_tool_calls_in_history = false
                local tool_result_content = ""

                for _, history_msg in ipairs(session.messages) do
                  if history_msg.metadata and history_msg.metadata.tool_calls then
                    has_tool_calls_in_history = true
                  end
                  if history_msg.role == "tool" and history_msg.content then
                    tool_result_content = history_msg.content
                  end
                end

                -- 如果是工具调用后的请求，使用工具结果生成回复
                if has_tool_calls_in_history then
                  -- 尝试从工具结果中提取信息
                  if tool_result_content ~= "" then
                    -- 如果是目录列表结果，生成有意义的回复
                    if tool_result_content:match("total %d+") then
                      -- 解析目录列表结果
                      local lines = {}
                      for line in tool_result_content:gmatch("[^\r\n]+") do
                        if not line:match("^total") then
                          table.insert(lines, line)
                        end
                      end

                      -- 提取文件名
                      local file_list = {}
                      for _, line in ipairs(lines) do
                        local filename = line:match("[^ ]+$")
                        if filename and filename ~= "." and filename ~= ".." then
                          table.insert(file_list, filename)
                        end
                      end

                      if #file_list > 0 then
                        final_content = "我已经查看了目录内容。当前目录包含以下文件：\n"
                        for i, filename in ipairs(file_list) do
                          if i <= 10 then -- 只显示前10个文件
                            final_content = final_content .. "- " .. filename .. "\n"
                          else
                            final_content = final_content .. "- ... 还有 " .. (#file_list - 10) .. " 个文件\n"
                            break
                          end
                        end
                        final_content = final_content .. "\n总共 " .. #file_list .. " 个文件/目录。"
                      else
                        final_content = "目录为空或无法解析目录内容。"
                      end
                    else
                      -- 其他类型的工具结果
                      final_content = "我已经执行了工具操作。工具返回的结果是：\n"
                        .. string.sub(tool_result_content, 1, 200)
                        .. (#tool_result_content > 200 and "..." or "")
                    end
                  else
                    final_content = "我已经处理了工具调用，但工具没有返回具体结果。"
                  end
                else
                  final_content = "抱歉，未能生成回复。"
                end
              end

              msg.content = final_content
              msg.pending = false
              msg.timestamp = os.time()

              -- 直接打印最终内容信息
              -- vim.notify(
              --   string.format(
              --     "[NeoAI] 请求完成: exit_code=%d, has_tool_calls=%s, accumulated_content_length=%d, final_content=%s",
              --     exit_code,
              --     tostring(has_tool_calls),
              --     #accumulated_content,
              --     #final_content > 50 and string.sub(final_content, 1, 50) .. "..." or final_content
              --   ),
              --   vim.log.levels.INFO
              -- )

              -- 存储推理内容
              if accumulated_reasoning ~= "" then
                msg.metadata.reasoning_content = accumulated_reasoning
                msg.metadata.has_reasoning = true
              end

              session.updated_at = os.time()
              M._auto_sync(session_id)

              -- 如果存在推理内容且尚未触发完成事件，触发推理完成事件
              -- 注意：如果已经在收到常规内容时触发过，这里不再重复触发
              if accumulated_reasoning ~= "" and (not msg.metadata or not msg.metadata.reasoning_finished) then
                -- 确保元数据存在
                msg.metadata = msg.metadata or {}
                msg.metadata.reasoning_content = accumulated_reasoning
                msg.metadata.has_reasoning = true
                msg.metadata.reasoning_finished = true

                -- 同时更新 pending_msg 的元数据
                pending_msg.metadata = pending_msg.metadata or {}
                pending_msg.metadata.reasoning_content = accumulated_reasoning
                pending_msg.metadata.has_reasoning = true
                pending_msg.metadata.reasoning_finished = true

                M._trigger("ai_reasoning_finished", {
                  session_id = session_id,
                  message = pending_msg,
                })
              end

              -- 触发最后一次更新
              if on_chunk then
                on_chunk(accumulated_content)
              end

              if on_complete then
                -- 修复：当退出码为0时，即使accumulated_content为空也应视为成功
                -- 因为AI可能返回空内容，特别是在工具调用后的第二次请求中
                local success = exit_code == 0
                local error_msg
                if success then
                  error_msg = nil
                else
                  error_msg = "请求失败，退出码: " .. exit_code
                end

                -- 简化调试信息
                if not success then
                  vim.notify(
                    string.format(
                      "[NeoAI] 请求失败: exit_code=%d, has_tool_calls=%s",
                      exit_code,
                      tostring(has_tool_calls)
                    ),
                    vim.log.levels.WARN
                  )
                end

                on_complete(success, error_msg, accumulated_content)
              end

              M._trigger("ai_replied", {
                session_id = session_id,
                message = pending_msg,
                content = accumulated_content,
                reasoning_content = accumulated_reasoning,
              })
            end
            break
          end
        end
      end)
    end,
  })

  if job_id <= 0 then
    local error_msg = "无法启动 API 请求"
    vim.notify("[NeoAI] " .. error_msg, vim.log.levels.ERROR)

    for i, msg in ipairs(session.messages) do
      if msg.id == pending_msg.id then
        msg.content = "❌ " .. error_msg
        msg.pending = false
        msg.timestamp = os.time()
        break
      end
    end

    if on_complete then
      on_complete(false, error_msg)
    end
    return
  end

  -- 启动文件监听器
  local function watch_stream()
    if request_finished then
      return
    end

    if vim.fn.filereadable(tmp_file) == 1 then
      local file_size = vim.fn.getfsize(tmp_file)
      if file_size <= last_processed_pos then
        vim.defer_fn(function() watch_stream() end, 50)
        return
      end

      local handle = io.open(tmp_file, "r")
      if not handle then
        vim.defer_fn(function() watch_stream() end, 50)
        return
      end

      handle:seek("set", last_processed_pos)
      local new_content = handle:read("*a")
      handle:close()

      if not new_content or new_content == "" then
        vim.defer_fn(function() watch_stream() end, 50)
        return
      end

      last_processed_pos = last_processed_pos + #new_content

      -- 解析 SSE 事件
      for line in new_content:gmatch("[^\r\n]+") do
        if line:match("^data:") then
          local data = utils.parse_sse_data(line)
          if data and data.choices and data.choices[1] then
            local delta = data.choices[1].delta

            -- 检查工具调用
            if delta.tool_calls then
              has_tool_calls = true
              for _, tool_call in ipairs(delta.tool_calls) do
                local idx = tool_call.index or 0
                -- 合并流式片段：按 index 合并
                if not tool_calls[idx + 1] then
                  tool_calls[idx + 1] = tool_call
                else
                  local existing = tool_calls[idx + 1]
                  if tool_call.id then
                    existing.id = tool_call.id
                  end
                  if tool_call.type then
                    existing.type = tool_call.type
                  end
                  if tool_call["function"] then
                    existing["function"] = existing["function"] or {}
                    if tool_call["function"].name then
                      existing["function"].name = tool_call["function"].name
                    end
                    if tool_call["function"].arguments then
                      existing["function"].arguments = (existing["function"].arguments or "")
                        .. tool_call["function"].arguments
                    end
                  end
                end
              end
            end

            -- 收集内容
            if delta.content and delta.content ~= vim.NIL then
              local content_str = type(delta.content) == "string" and delta.content or tostring(delta.content)
              accumulated_content = accumulated_content .. content_str
              -- 控制流式更新频率
              local current_time = vim.loop.now()
              if current_time - last_update_time >= stream_update_interval then
                last_update_time = current_time
                if on_chunk then
                  on_chunk(accumulated_content)
                end
              end
            end

            -- 提取推理内容
            local reasoning = utils.extract_reasoning_from_delta(delta)
            if reasoning then
              accumulated_reasoning = accumulated_reasoning .. reasoning
              pending_msg.metadata.reasoning_content = accumulated_reasoning
              pending_msg.metadata.has_reasoning = true
              pending_msg.metadata.reasoning_finished = false
              last_reasoning_update_time = vim.loop.now()  -- 更新推理内容更新时间
              M._trigger("ai_reasoning_update", {
                session_id = session_id,
                message = pending_msg,
                reasoning_content = accumulated_reasoning,
              })
            end

            -- 当有推理内容且尚未标记为完成时，检查是否应该关闭悬浮窗口
            -- 使用最小延迟确保思考过程真的结束了
            if accumulated_reasoning ~= "" and not pending_msg.metadata.reasoning_finished then
              local current_time = vim.loop.now()
              local time_since_last_reasoning = current_time - last_reasoning_update_time
              
              -- 如果推理内容已经停止更新超过100ms，则认为思考过程真的结束了
              if time_since_last_reasoning >= min_reasoning_completion_delay then
                pending_msg.metadata.reasoning_finished = true
                -- 同时更新会话中的消息元数据
                for i, msg in ipairs(session.messages) do
                  if msg.id == pending_msg.id then
                    msg.metadata = msg.metadata or {}
                    msg.metadata.reasoning_finished = true
                    break
                  end
                end
                -- 触发推理完成事件，关闭悬浮窗口
                M._trigger("ai_reasoning_finished", {
                  session_id = session_id,
                  message = pending_msg,
                })
              end
            end
          end
        end
      end
    end

    vim.defer_fn(watch_stream, 50)
  end

  watch_stream()
end

--- 发送消息（用户消息 + 触发 AI 回复）
-- @param session_id 会话 ID 或消息内容（若为内容则使用当前会话）
-- @param content 消息内容
-- @return table|nil 发送的用户消息对象，或失败时返回 nil
function M.send_message(session_id, content)
  -- 兼容参数顺序：若 content 为空，则第一个参数就是内容
  if content == nil then
    content = session_id
    session_id = M.current_session
  end

  local session = M.sessions[session_id]
  if not session or not content or content == "" then
    return nil
  end

  -- 创建并添加用户消息
  local user_msg = utils.create_message("user", content)
  M.add_message(session_id, user_msg)

  -- 检查是否启用 function calling
  local use_function_calling = false
  if M.validated_config and M.validated_config.llm then
    use_function_calling = M.validated_config.llm.enable_function_calling or false
  end

  -- 选择使用哪个请求函数
  local request_func = use_function_calling and M.request_ai_stream_with_tools or M.request_ai_stream

  -- 使用流式 API 请求 AI 回复
  request_func(
    session_id,
    content,
    -- on_chunk: 流式更新回调（可选，用于自定义处理）
    function(accumulated_content)
      -- 触发流式更新事件
      M._trigger("ai_stream_update", {
        session_id = session_id,
        content = accumulated_content,
      })
    end,
    -- on_complete: 完成回调
    function(success, error_msg, final_content)
      if success then
        M._trigger("response_received", {
          session_id = session_id,
          response = final_content,
        })
      else
        vim.notify("[NeoAI] AI 回复失败: " .. (error_msg or "未知错误"), vim.log.levels.WARN)
      end
    end
  )

  return user_msg
end

--- 注册事件监听器
-- @param event 事件名称
-- @param handler 回调函数
function M.on(event, handler)
  M.message_handlers[event] = M.message_handlers[event] or {}
  table.insert(M.message_handlers[event], handler)
end

--- 同步指定（或全部）会话数据到文件
-- @param session_id 会话 ID（可选，为空时同步所有会话）
-- @return boolean 是否成功
function M.sync_data(session_id)
  if session_id then
    local session = M.sessions[session_id]
    if session then
      M.export_session(session_id, M.config_file, true)
      return true
    end
  else
    -- 同步所有会话
    for id, _ in pairs(M.sessions) do
      M.export_session(id, M.config_file, true)
    end
    return true
  end
  return false
end

--- 防抖同步：延迟指定时间后执行 sync_data，期间重复调用会重置计时器
-- @param session_id 会话 ID
-- @param delay_ms 延迟时间（毫秒），默认 500
local debounce_sync_timer = { timer = nil }
function M.debounce_sync(session_id, delay_ms)
  local debounce_func = utils.create_debounce_sync(M.sync_data, session_id, delay_ms, debounce_sync_timer)
  debounce_func()
end

--- 导出指定会话到 JSON 文件
-- @param session_id 会话 ID
-- @param filepath 导出文件路径（可选，默认使用 config_file）
-- @param internal 是否为内部调用（为 true 时不触发事件）
-- @return boolean 是否导出成功
function M.export_session(session_id, filepath, internal)
  local session = M.sessions[session_id]
  if not session then
    return false
  end

  -- 构建导出数据结构（包含有向图邻接表信息）
  local graph_rel = M.session_graph[session_id] or { parent = nil, children = {} }
  local export_data = {
    id = session.id,
    name = session.name,
    messages = {},
    created_at = session.created_at,
    updated_at = session.updated_at,
    config = session.config,
    export_time = os.time(),
    -- 有向图关系信息（所有 ID 转为字符串）
    graph_relations = {
      parent = graph_rel.parent and tostring(graph_rel.parent),
      children = {},
    },
  }

  -- 转换子节点 ID 为字符串
  for _, child_id in ipairs(graph_rel.children or {}) do
    table.insert(export_data.graph_relations.children, tostring(child_id))
  end

  -- 序列化消息
  for _, msg in ipairs(session.messages) do
    table.insert(export_data.messages, {
      id = msg.id,
      role = msg.role,
      content = msg.content,
      timestamp = msg.timestamp,
      metadata = msg.metadata,
      editable = M.editable_states[msg.id] or false,
    })
  end

  filepath = filepath or M.config_file
  vim.fn.mkdir(M.config_dir, "p") -- 确保目录存在

  -- 读取已有的数据（合并模式）
  local all_data = {}
  if vim.fn.filereadable(filepath) == 1 then
    local content = vim.fn.readfile(filepath)
    if #content > 0 then
      all_data = vim.fn.json_decode(table.concat(content, "\n")) or {}
    end
  end

  -- 更新指定会话的数据（转换为字符串键）
  all_data[tostring(session.id)] = export_data

  -- 同时保存完整的图结构信息（在所有会话导出时更新）
  if not all_data._graph then
    all_data._graph = {}
  end

  -- 将图结构转换为字符串键（JSON 要求键为字符串）
  local graph_to_save = {}
  for sid, relations in pairs(M.session_graph) do
    local sid_str = tostring(sid)
    graph_to_save[sid_str] = {
      parent = relations.parent and tostring(relations.parent),
      children = {},
    }
    for _, child_id in ipairs(relations.children) do
      table.insert(graph_to_save[sid_str].children, tostring(child_id))
    end
  end
  all_data._graph = graph_to_save

  vim.fn.writefile({ vim.fn.json_encode(all_data) }, filepath)

  if not internal then
    M._trigger("session_exported", { session_id = session_id, filepath = filepath })
  end

  return true
end

--- 从 JSON 文件导入会话数据
-- @param filepath 导入文件路径（可选）
-- @return table 导入的会话 ID 列表
function M.import_sessions(filepath)
  filepath = filepath or M.config_file

  if vim.fn.filereadable(filepath) ~= 1 then
    return {}
  end

  local content = vim.fn.readfile(filepath)
  if #content == 0 then
    return {}
  end

  local data = vim.fn.json_decode(table.concat(content, "\n")) or {}
  local imported = {}

  -- 重置计数器（避免导入后命名冲突）
  M._session_counter = 0
  M._branch_counters = {}

  -- 先导入图结构关系（如果存在）
  if data._graph then
    -- 将字符串键转换回整数
    for sid_str, relations in pairs(data._graph) do
      local sid = tonumber(sid_str)
      if sid then
        M.session_graph[sid] = {
          children = {},
          parent = relations.parent and tonumber(relations.parent),
        }
        for _, child_str in ipairs(relations.children or {}) do
          local child_id = tonumber(child_str)
          if child_id then
            table.insert(M.session_graph[sid].children, child_id)
          end
        end
      end
    end
  end

  for session_key, session_data in pairs(data) do
    -- 跳过元数据字段
    if session_key ~= "_graph" then
      local session = {
        id = session_data.id,
        name = session_data.name,
        messages = {},
        created_at = session_data.created_at or os.time(),
        updated_at = session_data.updated_at or os.time(),
        config = session_data.config or {},
      }

      -- 重建消息对象
      for _, msg_data in ipairs(session_data.messages or {}) do
        local msg = utils.create_message(msg_data.role, msg_data.content, msg_data.timestamp, msg_data.metadata)
        msg.id = msg_data.id
        msg.editable = msg_data.editable or false
        if msg.editable then
          M.editable_states[msg.id] = true
        end
        table.insert(session.messages, msg)
      end

      M.sessions[session.id] = session
      table.insert(imported, session.id)

      -- 如果图结构中没有该会话的信息，初始化默认值
      if not M.session_graph[session.id] then
        M.session_graph[session.id] = {
          children = {},
          parent = nil,
        }
      end

      -- 从 graph_relations 中恢复图结构（兼容旧数据格式）
      if session_data.graph_relations then
        M.session_graph[session.id].parent = session_data.graph_relations.parent
          and tonumber(session_data.graph_relations.parent)
        M.session_graph[session.id].children = {}
        for _, child_str in ipairs(session_data.graph_relations.children or {}) do
          local child_id = tonumber(child_str)
          if child_id then
            table.insert(M.session_graph[session.id].children, child_id)
          end
        end
      end
    end
  end

  -- 设置计数器为最大会话 ID
  for sid, _ in pairs(M.sessions) do
    if sid > M._session_counter then
      M._session_counter = sid
    end
  end

  M._trigger("sessions_imported", { count = #imported })
  return imported
end

--- 获取指定会话的统计信息
-- @param session_id 会话 ID
-- @return table 统计数据表
function M.get_session_stats(session_id)
  local session = M.sessions[session_id]
  if not session then
    return {}
  end

  local stats = {
    total_messages = #session.messages,
    user_messages = 0,
    ai_messages = 0,
    system_messages = 0,
    editable_messages = 0,
    duration_minutes = math.floor((os.time() - session.created_at) / 60),
  }

  -- 按角色分类统计
  for _, msg in ipairs(session.messages) do
    if msg.role == "user" then
      stats.user_messages = stats.user_messages + 1
    elseif msg.role == "assistant" then
      stats.ai_messages = stats.ai_messages + 1
    elseif msg.role == "system" then
      stats.system_messages = stats.system_messages + 1
    end
    if msg.editable then
      stats.editable_messages = stats.editable_messages + 1
    end
  end

  return stats
end

--- 获取会话的父节点
-- @param session_id 会话 ID
-- @return number|nil 父节点 ID，不存在返回 nil
function M.get_parent(session_id)
  if M.session_graph[session_id] then
    return M.session_graph[session_id].parent
  end
  return nil
end

--- 获取会话的所有祖先节点（递归）
-- @param session_id 会话 ID
-- @return table 祖先节点 ID 列表（从直接父节点到根节点）
function M.get_ancestors(session_id)
  local ancestors = {}
  local current = M.get_parent(session_id)
  while current do
    table.insert(ancestors, current)
    current = M.get_parent(current)
  end
  return ancestors
end

--- 获取会话的所有后代节点（递归）
-- @param session_id 会话 ID
-- @return table 后代节点 ID 列表
function M.get_descendants(session_id)
  local descendants = {}
  local children = M.get_children(session_id)

  for _, child_id in ipairs(children) do
    table.insert(descendants, child_id)
    -- 递归获取子节点的后代
    local child_descendants = M.get_descendants(child_id)
    for _, desc_id in ipairs(child_descendants) do
      table.insert(descendants, desc_id)
    end
  end

  return descendants
end

--- 建立两个会话之间的有向边关系
-- @param parent_id 父会话 ID
-- @param child_id 子会话 ID
-- @return boolean 是否成功建立关系
function M.add_edge(parent_id, child_id)
  if not M.sessions[parent_id] or not M.sessions[child_id] then
    return false
  end

  -- 初始化图结构（如果不存在）
  if not M.session_graph[parent_id] then
    M.session_graph[parent_id] = { children = {}, parent = nil }
  end
  if not M.session_graph[child_id] then
    M.session_graph[child_id] = { children = {}, parent = nil }
  end

  -- 避免重复添加边
  for _, existing_child in ipairs(M.session_graph[parent_id].children) do
    if existing_child == child_id then
      return true -- 边已存在
    end
  end

  -- 添加有向边：parent_id -> child_id
  table.insert(M.session_graph[parent_id].children, child_id)
  M.session_graph[child_id].parent = parent_id

  return true
end

--- 删除两个会话之间的有向边关系
-- @param parent_id 父会话 ID
-- @param child_id 子会话 ID
-- @return boolean 是否成功删除关系
function M.remove_edge(parent_id, child_id)
  if not M.session_graph[parent_id] or not M.session_graph[child_id] then
    return false
  end

  -- 从父节点的子节点列表中移除
  local children = M.session_graph[parent_id].children
  for i, existing_child in ipairs(children) do
    if existing_child == child_id then
      table.remove(children, i)
      break
    end
  end

  -- 清除子节点的父节点引用
  if M.session_graph[child_id].parent == parent_id then
    M.session_graph[child_id].parent = nil
  end

  return true
end

--- 计算两个会话的共同前缀轮次数（通过比较消息内容）
-- @param session_id_a 会话 A
-- @param session_id_b 会话 B
-- @return number 共同前缀的轮次数
function M.get_common_prefix_turns(session_id_a, session_id_b)
  local session_a = M.sessions[session_id_a]
  local session_b = M.sessions[session_id_b]
  if not session_a or not session_b then
    return 0
  end

  local common = 0
  local msg_a = session_a.messages
  local msg_b = session_b.messages
  local len = math.min(#msg_a, #msg_b)

  for i = 1, len do
    if msg_a[i].role == msg_b[i].role and msg_a[i].content == msg_b[i].content then
      if msg_a[i].role == "user" then
        common = common + 1
      end
    else
      break
    end
  end

  return common
end

--- 获取指定会话的所有直接子分支
-- @param session_id 会话 ID
-- @return table 子分支 ID 列表
function M.get_children(session_id)
  local graph = M.session_graph[session_id]
  if not graph then
    return {}
  end
  return vim.deepcopy(graph.children)
end

--- 获取图的完整结构（用于调试或导出）
-- @return table 图的邻接表结构
function M.get_graph_structure()
  return M.session_graph
end

--- 后端模块初始化
-- 读取配置、导入已有数据、创建默认会话
-- @param validated_config 已验证的配置表（由 init.lua 传入）
function M.setup(validated_config)
  validated_config = validated_config or {}
  M.config_dir = validated_config.background and validated_config.background.config_dir
    or config.defaults.background.config_dir
  M.config_file = validated_config.background and validated_config.background.config_file
    or (M.config_dir .. "/sessions.json")

  -- 存储完整的验证后配置
  M.validated_config = validated_config
  -- 存储 LLM 配置（供流式请求使用）
  M.llm_config = validated_config.llm or config.defaults.llm

  -- 尝试导入已有的会话数据
  M.import_sessions()

  -- 如果没有任何会话，创建默认会话
  local has_sessions = false
  for _, _ in pairs(M.sessions) do
    has_sessions = true
    break
  end

  if not has_sessions then
    M.new_session()
  end

  -- 设置当前活跃会话
  if not M.current_session then
    for id, _ in pairs(M.sessions) do
      M.current_session = id
      break
    end
  end

  -- vim.notify("[NeoAI] 后端已初始化，当前会话: " .. (M.sessions[M.current_session] and M.sessions[M.current_session].name or "无"))
end

--- 判断是否应该显示树视图（会话列表）
-- 始终显示树视图，供用户选择或创建会话
-- @return boolean 是否应显示树视图
function M.should_show_tree()
  return true -- 始终显示树视图
end

--- 在指定轮次处创建新分支（复制从根到该轮次的路径）
-- 新分支将包含从根会话到当前轮次的所有消息
-- @param session_id 当前会话 ID
-- @param turn_index 对话轮次索引（从 1 开始）
-- @return table? 新创建的会话对象，失败返回 nil
function M.create_branch_at_turn(session_id, turn_index)
  local session = M.sessions[session_id]
  if not session then
    vim.notify("[NeoAI] 错误: 会话不存在", vim.log.levels.ERROR)
    return nil
  end

  -- 获取该轮次对应的消息索引
  local turns = {}
  local current_turn = nil
  for i, msg in ipairs(session.messages) do
    if msg.role == "user" then
      current_turn = { user_msg_index = i, assistant_msg_index = nil, turn_num = #turns + 1 }
      table.insert(turns, current_turn)
    elseif msg.role == "assistant" and current_turn and not current_turn.assistant_msg_index then
      current_turn.assistant_msg_index = i
    end
  end

  if turn_index < 1 or turn_index > #turns then
    vim.notify("[NeoAI] 错误: 无效的轮次索引", vim.log.levels.ERROR)
    return nil
  end

  local target_turn = turns[turn_index]
  local last_msg_index = target_turn.assistant_msg_index or target_turn.user_msg_index

  -- 创建新分支会话（自动命名）
  local new_session = M.new_session(nil, session_id)

  -- 复制从开始到该轮次的所有消息
  for i = 1, last_msg_index do
    local msg = session.messages[i]
    local new_msg = utils.create_message(msg.role, msg.content, msg.timestamp, vim.deepcopy(msg.metadata))
    M.add_message(new_session.id, new_msg)
  end

  vim.notify("[NeoAI] 已创建分支: " .. new_session.name, vim.log.levels.INFO)
  return new_session
end

--- 新建空对话
-- 创建一个没有任何消息的新会话
-- @param name 会话名称（可选，留空则使用自动命名）
-- @return table 新创建的会话对象
function M.new_empty_conversation(name)
  local session = M.new_session(name)
  -- 清空消息
  session.messages = {}
  vim.notify("[NeoAI] 已创建空对话: " .. session.name, vim.log.levels.INFO)
  return session
end

--- 删除指定轮次的对话（用户消息 + 可能的助手回复）
-- @param session_id 会话 ID
-- @param turn_index 轮次索引（从 1 开始）
-- @return boolean 是否成功
function M.delete_turn(session_id, turn_index)
  local session = M.sessions[session_id]
  if not session then
    vim.notify("[NeoAI] 错误: 会话不存在", vim.log.levels.ERROR)
    return false
  end

  -- 找出该轮次对应的消息索引
  local turns = {}
  local current_turn = nil
  for i, msg in ipairs(session.messages) do
    if msg.role == "user" then
      current_turn = { user_msg_index = i, assistant_msg_index = nil, turn_num = #turns + 1 }
      table.insert(turns, current_turn)
    elseif msg.role == "assistant" and current_turn and not current_turn.assistant_msg_index then
      current_turn.assistant_msg_index = i
    end
  end

  if turn_index < 1 or turn_index > #turns then
    vim.notify("[NeoAI] 错误: 无效的轮次索引", vim.log.levels.ERROR)
    return false
  end

  local target_turn = turns[turn_index]
  local start_idx = target_turn.user_msg_index
  local end_idx = target_turn.assistant_msg_index or start_idx

  -- 从后往前删除消息（避免索引变化）
  for i = end_idx, start_idx, -1 do
    table.remove(session.messages, i)
  end

  session.updated_at = os.time()
  M._auto_sync(session_id)
  M._trigger("turn_deleted", { session_id = session_id, turn_index = turn_index })
  M._trigger("message_deleted", { session_id = session_id })

  vim.notify("[NeoAI] 已删除第 " .. turn_index .. " 轮对话", vim.log.levels.INFO)
  return true
end

--- 删除当前分支（从当前会话到所有后代）
-- 删除当前会话及其所有子会话（递归）
-- @param session_id 会话 ID
-- @return boolean 是否成功
function M.delete_branch(session_id)
  local session = M.sessions[session_id]
  if not session then
    vim.notify("[NeoAI] 错误: 会话不存在", vim.log.levels.ERROR)
    return false
  end

  -- 获取所有后代节点
  local descendants = M.get_descendants(session_id)
  table.insert(descendants, 1, session_id) -- 包含自己

  -- 从后往前删除（先删除子节点）
  table.sort(descendants, function(a, b)
    return a > b
  end)

  local deleted_count = 0
  for _, sid in ipairs(descendants) do
    -- 从图结构中移除
    if M.session_graph[sid] then
      -- 清除父节点的引用
      local parent_id = M.session_graph[sid].parent
      if parent_id and M.session_graph[parent_id] then
        local children = M.session_graph[parent_id].children
        for i, child_id in ipairs(children) do
          if child_id == sid then
            table.remove(children, i)
            break
          end
        end
      end
      M.session_graph[sid] = nil
    end

    -- 删除会话
    if M.sessions[sid] then
      M.sessions[sid] = nil
      deleted_count = deleted_count + 1
    end
  end

  -- 如果删除的是当前会话，切换到其他可用会话
  if M.current_session == session_id or not M.sessions[M.current_session] then
    for id, _ in pairs(M.sessions) do
      M.current_session = id
      break
    end
  end

  -- 重写整个文件，确保已删除的会话从 JSON 中清除
  M._sync_all_sessions()

  M._trigger("branch_deleted", { session_id = session_id, deleted_count = deleted_count })
  vim.notify("[NeoAI] 已删除分支，共 " .. deleted_count .. " 个会话", vim.log.levels.INFO)
  return true
end

--- 同步所有会话数据到文件（完整重写）
function M._sync_all_sessions()
  vim.fn.mkdir(M.config_dir, "p")

  local all_data = {}

  -- 保存所有会话
  for sid, session in pairs(M.sessions) do
    local graph_rel = M.session_graph[sid] or { parent = nil, children = {} }
    local export_data = {
      id = session.id,
      name = session.name,
      messages = {},
      created_at = session.created_at,
      updated_at = session.updated_at,
      config = session.config,
      export_time = os.time(),
      graph_relations = {
        parent = graph_rel.parent and tostring(graph_rel.parent),
        children = {},
      },
    }

    for _, child_id in ipairs(graph_rel.children or {}) do
      table.insert(export_data.graph_relations.children, tostring(child_id))
    end

    for _, msg in ipairs(session.messages) do
      table.insert(export_data.messages, {
        id = msg.id,
        role = msg.role,
        content = msg.content,
        timestamp = msg.timestamp,
        metadata = msg.metadata,
        editable = M.editable_states[msg.id] or false,
      })
    end

    all_data[tostring(sid)] = export_data
  end

  -- 保存完整的图结构
  local graph_to_save = {}
  for sid, relations in pairs(M.session_graph) do
    local sid_str = tostring(sid)
    graph_to_save[sid_str] = {
      parent = relations.parent and tostring(relations.parent),
      children = {},
    }
    for _, child_id in ipairs(relations.children) do
      table.insert(graph_to_save[sid_str].children, tostring(child_id))
    end
  end
  all_data._graph = graph_to_save

  vim.fn.writefile({ vim.fn.json_encode(all_data) }, M.config_file)
end

return M
