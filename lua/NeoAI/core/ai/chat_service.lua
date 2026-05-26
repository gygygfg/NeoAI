--- NeoAI 聊天服务（后端 + 计算层）
--- 前后端分离架构中的后端服务层
--- 职责：会话管理、消息历史管理、AI 生成请求调度、事件分发、自动命名会话
---       消息内容计算（格式化、渲染行生成、内容提取等 CPU 密集型操作）
---
--- 依赖关系：
---   - 会话管理 → history_manager
---   - AI 生成 → engine（仅触发生成，不参与生成流程编排）
---   - 自动命名 → http_utils + config_merger
---   - 消息计算 → markdown_renderer（纯文本格式化）

local M = {}


local logger = require("NeoAI.utils.logger")
local event_constants = require("NeoAI.core.events")
local engine = require("NeoAI.core.ai.engine")
local history_manager = require("NeoAI.core.history.manager")
local shutdown_flag = require("NeoAI.core.shutdown_flag")
local markdown_renderer = require("NeoAI.ui.components.markdown_renderer")

-- ========== 状态 ==========

local state = {
  initialized = false,
  pending_user_messages = {},
}

-- ========== 守卫 ==========

local function guard()
  if not state.initialized then
    logger.error("[chat_service] 服务未初始化")
    return false
  end
  return true
end

-- ========== 初始化 ==========

function M.initialize(options)
  if state.initialized then
    return M
  end
  M._setup_event_listeners()
  state.initialized = true
  logger.info("[chat_service] 聊天服务初始化完成")
  return M
end

-- ========== 事件监听 ==========

function M._setup_event_listeners()
  vim.api.nvim_create_autocmd("User", {
    pattern = event_constants.GENERATION_COMPLETED,
    callback = function(args)
      local data = args.data or {}
      logger.debug("[chat_service] 生成完成: session=" .. tostring(data.session_id))
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    pattern = event_constants.GENERATION_ERROR,
    callback = function(args)
      local data = args.data or {}
      logger.warn(
        "[chat_service] 生成错误: session=" .. tostring(data.session_id) .. ", error=" .. tostring(data.error_msg)
      )
    end,
  })
  -- 监听取消生成事件，仅用于日志记录
  -- 实际的停止逻辑由 chat_service.cancel_generation() 统一处理
  -- 避免在此处重复调用 engine.cancel_generation() 和 tool_orc.request_stop()
  -- 否则会导致停止逻辑执行两次，且顺序不可控
  vim.api.nvim_create_autocmd("User", {
    pattern = event_constants.CANCEL_GENERATION,
    callback = function(args)
      local data = args.data or {}
      local session_id = data.session_id
      logger.debug("[chat_service] 收到取消生成事件: session=" .. tostring(session_id))
    end,
  })
end

-- ========== 会话管理 ==========

function M.create_session(name, is_root, parent_id)
  if not guard() then
    return nil
  end
  return history_manager.create_session(name, is_root, parent_id)
end

function M.get_or_create_current_session(name)
  if not guard() then
    return nil
  end
  return history_manager.get_or_create_current_session(name)
end

function M.get_session(session_id)
  if not guard() then
    return nil
  end
  return history_manager.get_session(session_id)
end

function M.get_current_session()
  if not guard() then
    return nil
  end
  return history_manager.get_current_session()
end

function M.set_current_session(session_id)
  if not guard() then
    return false
  end
  return history_manager.set_current_session(session_id)
end

function M.delete_session(session_id)
  if not guard() then
    return false
  end
  return history_manager.delete_session(session_id)
end

function M.rename_session(session_id, new_name)
  if not guard() then
    return false
  end
  return history_manager.rename_session(session_id, new_name)
end

function M.list_sessions()
  if not guard() then
    return {}
  end
  return history_manager.list_sessions()
end

function M.get_tree()
  if not guard() then
    return {}
  end
  return history_manager.get_tree()
end

-- ========== 消息管理 ==========

function M.get_context(session_id)
  if not guard() then
    return {}, nil
  end
  return history_manager.get_context_and_new_parent(session_id)
end

function M.get_raw_messages(session_id)
  if not guard() then
    return {}
  end

  local hm = history_manager
  local session = hm.get_session(session_id)
  if not session then
    return {}
  end

  -- 从根到选中节点沿唯一子会话链向上回溯，再从选中节点沿唯一子会话链向下走到末端
  -- 与 get_context_and_new_parent 保持一致，确保聊天窗口显示的消息与 AI 上下文一致
  local path_ids = {}
  -- 第一步：从选中节点向上回溯到根
  local current = session
  for _ = 1, 100 do
    table.insert(path_ids, 1, current.id)
    local parent_id = hm.find_parent_session(current.id)
    if not parent_id then
      break
    end
    current = hm.get_session(parent_id)
    if not current then
      break
    end
  end
  -- 第二步：从选中节点沿唯一子会话链向下走到末端
  current = session
  for _ = 1, 100 do
    local child_ids = current.child_ids or {}
    if #child_ids ~= 1 then
      break
    end
    current = hm.get_session(child_ids[1])
    if not current then
      break
    end
    table.insert(path_ids, current.id)
  end

  -- 按从根到当前的顺序收集消息，复用 manager 的消息展平逻辑
  local messages = {}
  for _, pid in ipairs(path_ids) do
    local s = hm.get_session(pid)
    if not s then
      break
    end
    local session_msgs = hm._session_to_messages(s)
    for _, msg in ipairs(session_msgs) do
      table.insert(messages, msg)
    end
  end
  return messages
end

function M.add_round(session_id, user_msg, assistant_msg, usage)
  if not guard() then
    return nil
  end
  return history_manager.add_round(session_id, user_msg, assistant_msg, usage)
end

function M.update_last_assistant(session_id, content)
  if not guard() then
    return
  end
  history_manager.update_last_assistant(session_id, content)
end

function M.add_tool_result(session_id, tool_name, arguments, result)
  if not guard() then
    return false
  end
  return history_manager.add_tool_result(session_id, tool_name, arguments, result)
end

function M.update_usage(session_id, usage)
  if not guard() then
    return
  end
  history_manager.update_usage(session_id, usage)
end

function M.find_parent_session(session_id)
  if not guard() then
    return nil
  end
  return history_manager.find_parent_session(session_id)
end

function M.find_nearest_branch_parent(session_id)
  if not guard() then
    return nil
  end
  return history_manager.find_nearest_branch_parent(session_id)
end

function M.delete_chain_to_branch(session_id)
  if not guard() then
    return false
  end
  return history_manager.delete_chain_to_branch(session_id)
end

-- ========== AI 生成 ==========

function M.send_message(params)
  if not guard() then
    return false, "聊天服务未初始化"
  end

  local content = params.content
  local session_id = params.session_id
  local window_id = params.window_id
  local options = params.options or {}

  if not content or vim.trim(content) == "" then
    return false, "消息内容不能为空"
  end

  -- 使用传入的 session_id，如果未提供则获取或创建会话
  local hm = history_manager
  local target_session_id = session_id
  if not target_session_id then
    local session = hm.get_or_create_current_session("聊天会话")
    if not session then
      return false, "无法创建会话"
    end
    target_session_id = session.id

    -- 如果当前会话已有内容，创建分支会话（以当前会话为父节点）
    -- 这样 get_context_and_new_parent 能沿父链回溯到根节点，获取完整历史消息
    if session.user ~= nil and session.user ~= "" then
      local new_id = hm.create_session("分支-" .. (session.name or "会话"), false, session.id)
      hm.set_current_session(new_id)
      target_session_id = new_id
    end
  end

  -- 保存用户消息到待写入队列
  state.pending_user_messages[target_session_id] = content

  -- 获取上下文消息
  local context_msgs, _ = hm.get_context_and_new_parent(target_session_id)
  local messages = {}
  for _, msg in ipairs(context_msgs) do
    table.insert(messages, { role = msg.role, content = msg.content })
  end

  -- 去重：检查最后一条消息是否与当前消息相同
  local last_msg = messages[#messages]
  if not (last_msg and last_msg.role == "user" and last_msg.content == content) then
    table.insert(messages, { role = "user", content = content })
  end

  if #messages == 0 then
    return false, "上下文消息为空"
  end

  -- 检查工具是否启用
  local tools_enabled = true
  local core = require("NeoAI.core")
  local full_config = core.get_config() or {}
  if full_config and full_config.tools then
    tools_enabled = full_config.tools.enabled ~= false
  end

  -- 检查深度思考模式是否启用
  local reasoning_enabled = false
  if full_config and full_config.ai then
    reasoning_enabled = full_config.ai.reasoning_enabled == true
  end

  -- 调用 AI 引擎生成响应
  engine.generate_response(messages, {
    session_id = target_session_id,
    window_id = window_id,
    model_index = options.model_index or 1,
    stream = options.stream ~= false,
    options = {
      tools_enabled = tools_enabled,
      reasoning_enabled = reasoning_enabled,
    },
  })

  -- 触发消息发送事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.MESSAGE_SENT,
    data = {
      session_id = target_session_id,
      window_id = window_id,
      role = "user",
      message = content,
    },
  })

  return true, "消息已发送"
end

function M.cancel_generation()
  if not guard() then
    return
  end
  -- 从 history_manager 获取当前 session_id
  local current_session = history_manager.get_current_session()
  local session_id = current_session and current_session.id or nil

  -- 直接取消 HTTP 请求并设置停止标志，不触发总结轮次
  -- engine.cancel_generation() 内部会设置 stop_requested 并取消 HTTP 请求
  engine.cancel_generation()

  -- 最后触发取消事件，让 UI 监听器更新界面状态
  -- 注意：CANCEL_GENERATION 事件的监听器中不应再调用 tool_orc.request_stop 或 engine.cancel_generation
  -- 否则会导致重复执行
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.CANCEL_GENERATION,
    data = { session_id = session_id },
  })
end

function M.get_engine_status()
  if not guard() then
    return { initialized = false }
  end
  return engine.get_status()
end

function M.switch_model(model_index)
  if not guard() then
    return
  end
  logger.info("[chat_service] 模型切换: index=" .. tostring(model_index))
end

-- ========== 自动命名会话 ==========

--- 根据用户消息自动生成会话名称
--- 使用 AI 命名场景配置，回退到聊天场景配置
--- @param session_id string 会话 ID
--- @param user_msg string 用户消息
--- @param callback function 回调 (success, name)
function M.auto_name_session(session_id, user_msg, callback)
  if not guard() then
    if callback then callback(false, "聊天服务未初始化") end
    return
  end
  if not user_msg or user_msg == "" then
    if callback then callback(false, "无用户消息") end
    return
  end
  local naming_text = user_msg:sub(1, 200)
  local http_utils = require("NeoAI.utils.http_utils")
  local config_merger = require("NeoAI.core.config.merger")
  vim.schedule(function()
    local preset = nil
    if config_merger and config_merger.get_preset then
      preset = config_merger.get_preset("naming")
    end
    if not preset or not preset.base_url or not preset.api_key then
      local core = require("NeoAI.core")
      local full_config = core.get_config() or {}
      local ai_config = (full_config and full_config.ai) or {}
      local scenarios = ai_config.scenarios or {}
      local entry = scenarios["naming"] or scenarios[ai_config.default or "chat"]
      if entry then
        local candidate = type(entry) == "table" and (entry[1] or entry) or entry
        local provider_name = candidate.provider or "deepseek"
        local provider = (ai_config.providers or {})[provider_name]
        if provider then
          preset = {
            base_url = provider.base_url,
            api_key = provider.api_key,
            model_name = candidate.model_name or candidate.model,
            timeout = candidate.timeout or 10000,
            api_type = candidate.api_type or "openai",
          }
        end
      end
    end
    if not preset or not preset.base_url or not preset.api_key then
      if callback then callback(false, "未配置 AI 提供商") end
      return
    end
    local response, err = http_utils.send_request({
      request = {
        model = preset.model_name or "",
        messages = {
          { role = "system", content = "你是一个会话命名助手。根据用户的第一条消息，生成一个简短（不超过20个字符）且有意义的会话名称。只返回名称本身，不要加引号、标点或解释。" },
          { role = "user", content = "请为以下对话生成一个简短的名称：" .. naming_text },
        },
        temperature = 0.3,
        max_tokens = 50,
        stream = false,
      },
      generation_id = "naming_" .. session_id .. "_" .. os.time(),
      base_url = preset.base_url,
      api_key = preset.api_key,
      timeout = preset.timeout or 10000,
      api_type = preset.api_type or "openai",
      provider_config = preset,
    })
    if err then
      if callback then callback(false, "命名请求失败: " .. tostring(err)) end
      return
    end
    if not response or not response.choices or #response.choices == 0 then
      if callback then callback(false, "命名响应无效") end
      return
    end
    local msg = response.choices[1].message
    local name = msg.content or ""
    if name == "" and msg.reasoning_content then
      name = msg.reasoning_content
    end
    name = name:gsub("^[%s\"'「『]+(.-)[%s\"'」』]+$", "%1"):gsub("^%s*(.-)%s*$", "%1"):gsub("[。，！？、；：]$", "")
    if #name > 30 then
      name = name:sub(1, 30) .. "…"
    end
    if name == "" then
      if callback then callback(false, "生成的名称无效") end
      return
    end
    if callback then callback(true, name) end
  end)
end

-- ========== 历史持久化 ==========

function M.save()
  if not guard() then
    return
  end
  history_manager._save()
end

-- ========== 消息内容计算（CPU 密集型操作，在后台线程执行）==========

--- 构建助理消息内容（JSON 格式）
--- 将正文和思考内容合并为可用于存储的 table 格式
--- @param content_text string 正文内容
--- @param reasoning_text string|nil 思考内容
--- @return table { content = string, reasoning_content = string|nil }
function M.build_assistant_content(content_text, reasoning_text)
  if reasoning_text and reasoning_text ~= "" then
    return {
      content = content_text or "",
      reasoning_content = reasoning_text,
    }
  end
  return content_text or ""
end

--- 格式化 table 为多行字符串，强制每个元素换行显示
--- 避免 vim.inspect 将短数组合并为一行
--- @param t table
--- @param indent string 缩进前缀
--- @return string
function M.format_table_for_fold(t, indent)
  indent = indent or ""
  if type(t) == "string" then
    -- 如果字符串包含换行，使用多行格式
    if t:find("\n") then
      local lines = vim.split(t, "\n")
      local parts = {}
      for _, line in ipairs(lines) do
        table.insert(parts, indent .. "  " .. line)
      end
      return table.concat(parts, "\n")
    end
    return string.format("%q", t)
  end
  if type(t) ~= "table" then
    return tostring(t)
  end

  -- 估算 table 大小：如果元素超过 500 个，回退到单行 JSON 格式
  -- 避免生成超大折叠文本导致性能问题和界面卡顿
  local count = 0
  for _ in pairs(t) do
    count = count + 1
    if count > 500 then
      -- 超过 500 个元素，使用 JSON 编码单行显示
      local ok, encoded = pcall(vim.json.encode, t)
      if ok then
        return encoded
      end
      break
    end
  end

  -- 判断是数组还是字典
  local is_array = true
  local max_key = 0
  for k, _ in pairs(t) do
    if type(k) ~= "number" or k <= 0 or math.floor(k) ~= k then
      is_array = false
      break
    end
    if k > max_key then
      max_key = k
    end
  end
  if is_array and max_key == #t then
    -- 数组：每个元素换行
    local parts = { "{" }
    for i, v in ipairs(t) do
      local val_str = M.format_table_for_fold(v, indent .. "  ")
      table.insert(parts, indent .. "  " .. val_str .. ",")
    end
    table.insert(parts, indent .. "}")
    return table.concat(parts, "\n")
  else
    -- 字典：每个键值对换行
    local parts = { "{" }
    -- 排序键
    local keys = {}
    for k, _ in pairs(t) do
      table.insert(keys, k)
    end
    table.sort(keys, function(a, b)
      if type(a) == type(b) then
        return tostring(a) < tostring(b)
      end
      return type(a) < type(b)
    end)
    for _, k in ipairs(keys) do
      local v = t[k]
      local key_str = type(k) == "string" and k or "[" .. tostring(k) .. "]"
      local val_str = M.format_table_for_fold(v, indent .. "  ")
      table.insert(parts, indent .. "  " .. key_str .. " = " .. val_str .. ",")
    end
    table.insert(parts, indent .. "}")
    return table.concat(parts, "\n")
  end
end

--- 截断过长的内容，限制在 max_lines 行以内
--- 如果超过 max_lines 行，只保留前 max_lines 行并添加截断提示
--- 用于折叠文本中的结果渲染，避免超大折叠文本导致界面卡顿
--- @param content string 原始内容
--- @param max_lines number|nil 最大行数，默认 200
--- @return string 截断后的内容
function M.truncate_content_for_fold(content, max_lines)
  max_lines = max_lines or 200
  if not content or content == "" then
    return content or ""
  end
  local lines = vim.split(content, "\n")
  if #lines <= max_lines then
    return content
  end
  local truncated = {}
  for i = 1, max_lines do
    table.insert(truncated, lines[i])
  end
  local remaining = #lines - max_lines
  table.insert(truncated, string.format("... [已截断，剩余 %d 行未显示]", remaining))
  return table.concat(truncated, "\n")
end

--- 格式化折叠文本 }}} 后的剩余内容（AI 总结正文）
--- remaining 来自 msg.content.content 中 }}} 之后的纯文本正文，非 JSON
--- @param content string 剩余内容文本
--- @return table 格式化后的行列表
function M.format_remaining_content(content)
  if not content or content == "" then
    return {}
  end
  local lines = {}
  local first = true
  for mline in content:gmatch("[^\n]+") do
    if first then
      table.insert(lines, string.format("🤖 AI: %s", mline))
      first = false
    else
      table.insert(lines, string.format("    %s", mline))
    end
  end
  return lines
end

--- 将单条消息渲染为文本行列表（纯计算，无 buffer/window 交互）
--- 注意：返回的每一行都不包含 \n 换行符，由调用方逐行写入缓冲区
--- @param msg table 消息对象 {role, content}
--- @param prev_role string|nil 上一条消息的角色
--- @return table 文本行列表
function M.render_message(msg, prev_role)
  local lines = {}
  local role_prefix = msg.role == "user" and "👤 用户:" or "🤖 AI:"

  -- 统一获取 raw_content（支持 Lua table 和字符串两种格式）
  local raw_content
  local has_reasoning = false
  local reasoning_content = ""
  local main_content = ""
  -- 检测 JSON 格式的工具调用
  local has_tool_calls = false

  if type(msg.content) == "table" then
    -- Lua table 格式：{ reasoning_content = "...", content = "..." }
    reasoning_content = msg.content.reasoning_content or ""
    main_content = msg.content.content or ""
    has_reasoning = reasoning_content ~= ""
    raw_content = main_content
  else
    raw_content = msg.content or ""
    if type(raw_content) ~= "string" then
      local ok, encoded = pcall(vim.json.encode, raw_content)
      raw_content = ok and encoded or tostring(raw_content)
    end

    -- 尝试解析 JSON 格式（兼容旧数据）
    -- 优化：跳过明显非 JSON 的内容，避免每 chunk 都做昂贵的 JSON 解析
    if msg.role == "assistant" then
      local first_char = type(raw_content) == "string" and raw_content:sub(1, 1) or ""
      -- 只有以 { 或 [ 开头且不以 {{{ 开头的内容才尝试 JSON 解析
      if (first_char == "{" or first_char == "[") and not raw_content:find("^{{{") then
        local json_ok, parsed = pcall(vim.json.decode, raw_content)
        if json_ok and type(parsed) == "table" then
          -- 检查是否包含 tool_calls
          if parsed.tool_calls and type(parsed.tool_calls) == "table" and #parsed.tool_calls > 0 then
            has_tool_calls = true
          end
          if parsed.reasoning_content and parsed.reasoning_content ~= "" then
            has_reasoning = true
            reasoning_content = parsed.reasoning_content
            main_content = parsed.content or ""
            raw_content = main_content
          elseif parsed.content and parsed.content ~= "" then
            main_content = parsed.content
            raw_content = main_content
          end
        end
      end
    end
    -- 如果未通过 JSON 解析设置 main_content，直接使用 raw_content
    if main_content == "" then
      main_content = raw_content
    end
  end

  -- 确保 raw_content 始终是字符串（防止嵌套 table 导致折叠文本检测失败）
  if type(raw_content) ~= "string" then
    local ok, encoded = pcall(vim.json.encode, raw_content)
    raw_content = ok and encoded or tostring(raw_content)
  end
  if type(main_content) ~= "string" then
    local ok, encoded = pcall(vim.json.encode, main_content)
    main_content = ok and encoded or tostring(main_content)
  end

  -- 检查是否是折叠文本（以 {{{ 开头）
  if msg.role == "assistant" and type(raw_content) == "string" and raw_content:find("^{{{") then
    -- 先处理 reasoning（如果有）
    if has_reasoning then
      -- 一次遍历完成拆分、拼接和判断
      local reasoning_lines_count = 0
      local reasoning_total_len = 0
      local reasoning_first = true
      for rline in reasoning_content:gmatch("[^\n]+") do
        reasoning_lines_count = reasoning_lines_count + 1
        reasoning_total_len = reasoning_total_len + #rline + 1
        if reasoning_first then
          reasoning_first = false
          local has_content = main_content and main_content ~= ""
          if has_content or reasoning_total_len >= 200 then
            table.insert(lines, "{{{ 🤔 思考过程")
            table.insert(lines, "  " .. rline)
          else
            table.insert(lines, "🤖 AI: 🤔 思考过程:")
            table.insert(lines, "    " .. rline)
          end
        else
          if reasoning_total_len >= 200 or (main_content and main_content ~= "") then
            table.insert(lines, "  " .. rline)
          else
            table.insert(lines, "    " .. rline)
          end
        end
      end
      if reasoning_total_len >= 200 or (main_content and main_content ~= "") then
        table.insert(lines, "}}}")
      end
      table.insert(lines, "")
    end
    if not has_reasoning then
      table.insert(lines, role_prefix)
    end
    -- 用 string.reverse 从末尾反向查找最后一个 }}}
    local clean_content = raw_content
    if clean_content:find("\r") then
      clean_content = clean_content:gsub("\r\n", "\n"):gsub("\r", "\n")
    end
    -- 直接使用 msg.fold_end 缓存
    local fold_start = msg.fold_end
    if fold_start and fold_start > 0 then
      -- fold_part = 从开头到 }}} 结束（含 }}}）
      local fold_part = clean_content:sub(1, fold_start + 2)
      for line in fold_part:gmatch("[^\n]+") do
        table.insert(lines, line)
      end
      local remaining = clean_content:sub(fold_start + 3)
      remaining = remaining:gsub("^\n+", ""):gsub("\n+$", "")
      if remaining and remaining ~= "" then
        table.insert(lines, "")
        local remaining_lines = M.format_remaining_content(remaining)
        for _, rline in ipairs(remaining_lines) do
          table.insert(lines, rline)
        end
      end
    else
      for line in clean_content:gmatch("[^\n]+") do
        table.insert(lines, line)
      end
    end
    table.insert(lines, "")
    return lines
  end

  -- 检查 msg 是否包含 tool_calls 字段（原生 table 结构）
  if msg.role == "assistant" and msg.tool_calls and type(msg.tool_calls) == "table" and #msg.tool_calls > 0 then
    table.insert(lines, "{{{ 🔧 工具调用:")
    for _, tc in ipairs(msg.tool_calls) do
      local func = tc["function"] or tc.func or {}
      local tool_name = (func.name or "") ~= "" and func.name or "工具"
      local args_str = ""
      if func.arguments then
        local ok, parsed = pcall(vim.json.decode, func.arguments)
        if ok and parsed then
          args_str = vim.inspect(parsed)
          if #args_str > 100 then
            args_str = args_str:sub(1, 100) .. "..."
          end
        else
          args_str = func.arguments
        end
      end
      table.insert(lines, string.format("    🔧 %s(%s)", tool_name, args_str))
    end
    table.insert(lines, "}}}")
    if raw_content and raw_content ~= "" then
      table.insert(lines, "")
      for _, mline in ipairs(vim.split(raw_content, "\n")) do
        table.insert(lines, mline)
      end
    end
    table.insert(lines, "")
    return lines
  end

  if has_tool_calls then
    -- 有工具调用的 JSON 格式消息
    table.insert(lines, "{{{ 🔧 工具调用:")
    local json_ok, parsed = pcall(vim.json.decode, raw_content)
    if json_ok and parsed and parsed.tool_calls then
      for _, tc in ipairs(parsed.tool_calls) do
        local func = tc["function"] or tc.func or {}
        local tool_name = (func.name or "") ~= "" and func.name or "工具"
        local args_str = ""
        if func.arguments then
          local ok2, parsed2 = pcall(vim.json.decode, func.arguments)
          if ok2 and parsed2 then
            args_str = vim.inspect(parsed2)
            if #args_str > 100 then
              args_str = args_str:sub(1, 100) .. "..."
            end
          else
            args_str = func.arguments
          end
        end
        table.insert(lines, string.format("    🔧 %s(%s)", tool_name, args_str))
      end
    end
    table.insert(lines, "}}}")
    if main_content and main_content ~= "" then
      table.insert(lines, "")
      for _, mline in ipairs(vim.split(main_content, "\n")) do
        table.insert(lines, mline)
      end
    end
    table.insert(lines, "")
    return lines
  end

  if has_reasoning then
    -- 有思考过程
    local reasoning_lines = vim.split(reasoning_content, "\n")
    -- 判断条件：只有无正文且短思考（<200字符）才不折叠，否则一律折叠
    local has_content = main_content and main_content ~= ""
    local reasoning_text_combined = table.concat(reasoning_lines, " ")
    local reasoning_short = #reasoning_text_combined < 200
    local use_folded = has_content or not reasoning_short

    if use_folded then
      -- 折叠文本格式
      table.insert(lines, "{{{ 🤔 思考过程")
      for _, rline in ipairs(reasoning_lines) do
        table.insert(lines, "  " .. rline)
      end
      table.insert(lines, "}}}")
    else
      -- 无正文且思考短：直接显示
      table.insert(lines, role_prefix .. " 🤔 思考过程:")
      for _, rline in ipairs(reasoning_lines) do
        table.insert(lines, "    " .. rline)
      end
    end
    if main_content and main_content ~= "" then
      table.insert(lines, "")
      for _, mline in ipairs(vim.split(main_content, "\n")) do
        table.insert(lines, mline)
      end
    end
  elseif main_content and main_content ~= "" then
    -- 普通消息（有实际内容）：使用 markdown 格式化
    local formatted_lines = markdown_renderer.format_text(main_content)
    if #formatted_lines > 0 then
      table.insert(lines, string.format("%s %s", role_prefix, formatted_lines[1]))
      for i = 2, #formatted_lines do
        table.insert(lines, string.format("    %s", formatted_lines[i]))
      end
    end
  else
    -- 空内容消息，跳过不渲染
  end

  table.insert(lines, "")
  return lines
end

--- 从响应中提取内容字符串
--- @param response any 响应数据（字符串或 table）
--- @return string
function M.extract_response_content(response)
  if type(response) == "string" then
    return response
  end
  if type(response) == "table" then
    if response.content then
      return response.content
    end
    if response.text then
      return response.text
    end
  end
  return tostring(response)
end

--- 构建 token 用量文本
--- @param usage table token 用量数据
--- @return string|nil 格式化的用量文本，无有效数据时返回 nil
function M.build_usage_text(usage)
  if not usage or not next(usage) then
    return nil
  end

  local prompt_tokens = (usage.prompt_tokens or usage.promptTokens or usage.input_tokens or usage.inputTokens) or 0
  local completion_tokens = (
    usage.completion_tokens
    or usage.completionTokens
    or usage.output_tokens
    or usage.outputTokens
  ) or 0
  local total_tokens = (usage.total_tokens or usage.totalTokens) or (prompt_tokens + completion_tokens)

  local reasoning_tokens = 0
  if usage.completion_tokens_details and type(usage.completion_tokens_details) == "table" then
    reasoning_tokens = usage.completion_tokens_details.reasoning_tokens or 0
  end

  if reasoning_tokens and reasoning_tokens > 0 then
    return string.format(
      "📊 Token 用量: 输入 %d · 输出 %d (思考 %d) · 总计 %d",
      prompt_tokens,
      completion_tokens,
      reasoning_tokens,
      total_tokens
    )
  else
    return string.format(
      "📊 Token 用量: 输入 %d · 输出 %d · 总计 %d",
      prompt_tokens,
      completion_tokens,
      total_tokens
    )
  end
end

--- 构建保存到历史记录的最终内容
--- 将响应内容与折叠文本合并，返回可用于历史保存的格式
--- @param response_content string|table 基础响应内容
--- @param reasoning_text string 思考内容
--- @param tool_display_state table|nil 工具调用状态 { active, results, folded_saved }
--- @param last_assistant_content string|table|nil 最后一条 assistant 消息的完整内容
--- @return table|nil { content, reasoning_content } 或 nil
function M.build_final_content_for_history(response_content, reasoning_text, tool_display_state, last_assistant_content)
  local has_tool_results = tool_display_state and tool_display_state.active and #(tool_display_state.results or {}) > 0
  local folded_saved = tool_display_state and tool_display_state.folded_saved

  local final_content = response_content
  if has_tool_results or folded_saved then
    if last_assistant_content then
      -- last_assistant_content 可能是 table（含 reasoning_content 和 content 字段）或字符串
      if type(last_assistant_content) == "table" then
        final_content = last_assistant_content
      elseif last_assistant_content ~= "" then
        final_content = last_assistant_content
      end
    end
  end

  -- 检查是否为空
  local is_empty = false
  if type(final_content) == "table" then
    is_empty = (final_content.content == nil or final_content.content == "")
      and (final_content.reasoning_content == nil or final_content.reasoning_content == "")
  else
    is_empty = final_content == ""
  end
  if is_empty and reasoning_text == "" then
    return nil
  end

  return {
    content = final_content,
    reasoning_content = reasoning_text,
  }
end

-- ========== 清理 ==========

function M.is_initialized()
  return state.initialized
end

function M.shutdown()
  if not guard() then
    return
  end
  state.initialized = false
  state.pending_user_messages = {}
  logger.info("[chat_service] 聊天服务已关闭")
end

return M


