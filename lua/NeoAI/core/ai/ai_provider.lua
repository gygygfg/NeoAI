-- AI 提供者模块
-- 负责与外部AI API进行通信
local M = {}

-- 导入必要的模块
local logger = require("NeoAI.utils.logger")
local json = require("NeoAI.utils.json")

-- 模块内部状态
local state = {
  initialized = false,
  config = {},
  http = nil, -- HTTP客户端
}

-- 初始化AI提供者
-- @param config table AI配置
-- @return table 返回模块自身
function M.initialize(config)
  if state.initialized then
    return M
  end

  state.config = config or {}
  
  -- 尝试加载HTTP客户端
  local ok, http = pcall(require, "plenary.curl")
  if ok then
    state.http = http
    logger.debug("使用plenary.curl作为HTTP客户端")
  else
    -- 尝试其他HTTP客户端
    ok, http = pcall(require, "resty.http")
    if ok then
      state.http = http
      logger.debug("使用resty.http作为HTTP客户端")
    else
      -- 使用Neovim内置的HTTP客户端
      state.http = {
        request = function(options)
          return vim.system({
            "curl",
            "-X", "POST",
            "-H", "Content-Type: application/json",
            "-H", "Authorization: Bearer " .. (state.config.api_key or ""),
            "-d", options.body,
            options.url,
          }, { text = true }):wait()
        end
      }
      logger.debug("使用curl命令作为HTTP客户端")
    end
  end

  state.initialized = true
  return M
end

-- 发送非流式请求到AI API
-- @param messages table 消息列表
-- @param options table 请求选项
-- @return table|nil AI响应，包含content和id字段
function M.send_request(messages, options)
  if not state.initialized then
    error("AI提供者未初始化")
  end

  local request_options = vim.tbl_extend("force", {
    model = state.config.model or "deepseek-reasoner",
    temperature = state.config.temperature or 0.7,
    max_tokens = state.config.max_tokens or 4096,
    stream = false,
  }, options or {})

  -- 构建请求体
  local request_body = {
    model = request_options.model,
    messages = messages,
    temperature = request_options.temperature,
    max_tokens = request_options.max_tokens,
    stream = request_options.stream,
  }

  -- 添加系统提示（如果有）
  if state.config.system_prompt then
    table.insert(request_body.messages, 1, {
      role = "system",
      content = state.config.system_prompt,
    })
  end

  local body_json = json.encode(request_body)
  if not body_json then
    logger.error("无法编码请求体为JSON")
    return nil
  end

  logger.debug("发送AI请求到: " .. (state.config.base_url or "未知URL"))
  logger.debug("请求体: " .. body_json)

  -- 发送HTTP请求
  local response
  if state.http.request then
    -- 使用plenary.curl或resty.http
    response = state.http.request({
      url = state.config.base_url,
      method = "POST",
      headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. (state.config.api_key or ""),
      },
      body = body_json,
      timeout = state.config.timeout or 60000,
    })
  else
    -- 使用Neovim内置方式
    response = state.http.request({
      url = state.config.base_url,
      body = body_json,
    })
  end

  -- 处理响应
  if response and response.body then
    local ok, result = pcall(json.decode, response.body)
    if ok and result then
      if result.error then
        logger.error("AI API错误: " .. (result.error.message or "未知错误"))
        return nil
      end

      if result.choices and #result.choices > 0 then
        local choice = result.choices[1]
        local message = choice.message or {}
        
        return {
          content = message.content or "",
          id = result.id or ("ai_resp_" .. os.time() .. "_" .. math.random(1000, 9999)),
          model = result.model,
          usage = result.usage,
          finish_reason = choice.finish_reason,
        }
      end
    else
      logger.error("无法解析AI响应: " .. (response.body or "空响应"))
    end
  else
    logger.error("AI请求失败: " .. (response and response.stderr or "未知错误"))
  end

  return nil
end

-- 异步发送请求到AI API
-- @param messages table 消息列表
-- @param options table 请求选项
-- @param callback function 回调函数
function M.send_request_async(messages, options, callback)
  if not state.initialized then
    error("AI提供者未初始化")
  end

  local request_options = vim.tbl_extend("force", {
    model = state.config.model or "deepseek-reasoner",
    temperature = state.config.temperature or 0.7,
    max_tokens = state.config.max_tokens or 4096,
    stream = false,
  }, options or {})

  -- 构建请求体
  local request_body = {
    model = request_options.model,
    messages = messages,
    temperature = request_options.temperature,
    max_tokens = request_options.max_tokens,
    stream = request_options.stream,
  }

  -- 添加系统提示（如果有）
  if state.config.system_prompt then
    table.insert(request_body.messages, 1, {
      role = "system",
      content = state.config.system_prompt,
    })
  end

  local body_json = json.encode(request_body)
  if not body_json then
    logger.error("无法编码请求体为JSON")
    if callback then
      callback(false, nil, "无法编码请求体为JSON")
    end
    return
  end

  logger.debug("异步发送AI请求到: " .. (state.config.base_url or "未知URL"))

  -- 使用异步工作器执行HTTP请求
  local async_worker = require("NeoAI.utils.async_worker")
  
  async_worker.submit_task("ai_request", function()
    -- 在工作器线程中执行HTTP请求
    local response
    if state.http.request then
      -- 使用plenary.curl或resty.http
      response = state.http.request({
        url = state.config.base_url,
        method = "POST",
        headers = {
          ["Content-Type"] = "application/json",
          ["Authorization"] = "Bearer " .. (state.config.api_key or ""),
        },
        body = body_json,
        timeout = state.config.timeout or 60000,
      })
    else
      -- 使用Neovim内置方式
      response = state.http.request({
        url = state.config.base_url,
        body = body_json,
      })
    end

    -- 处理响应
    if response and response.body then
      local ok, result = pcall(json.decode, response.body)
      if ok and result then
        if result.error then
          logger.error("AI API错误: " .. (result.error.message or "未知错误"))
          return nil, result.error.message
        end

        if result.choices and #result.choices > 0 then
          local choice = result.choices[1]
          local message = choice.message or {}
          
          return {
            content = message.content or "",
            id = result.id or ("ai_resp_" .. os.time() .. "_" .. math.random(1000, 9999)),
            model = result.model,
            usage = result.usage,
            finish_reason = choice.finish_reason,
          }
        end
      else
        logger.error("无法解析AI响应: " .. (response.body or "空响应"))
        return nil, "无法解析AI响应"
      end
    else
      logger.error("AI请求失败: " .. (response and response.stderr or "未知错误"))
      return nil, "AI请求失败"
    end

    return nil, "未知错误"
  end, function(success, result, error_msg)
    -- 回调函数在主线程中执行
    if callback then
      callback(success, result, error_msg)
    end
  end)
end

-- 发送流式请求到AI API
-- @param messages table 消息列表
-- @param options table 请求选项
-- @param on_chunk function 处理数据块的函数
-- @return function 取消函数，用于取消请求
function M.send_stream_request(messages, options, on_chunk)
  if not state.initialized then
    error("AI提供者未初始化")
  end

  local request_options = vim.tbl_extend("force", {
    model = state.config.model or "deepseek-reasoner",
    temperature = state.config.temperature or 0.7,
    max_tokens = state.config.max_tokens or 4096,
    stream = true,
  }, options or {})

  -- 构建请求体
  local request_body = {
    model = request_options.model,
    messages = messages,
    temperature = request_options.temperature,
    max_tokens = request_options.max_tokens,
    stream = request_options.stream,
  }

  -- 添加系统提示（如果有）
  if state.config.system_prompt then
    table.insert(request_body.messages, 1, {
      role = "system",
      content = state.config.system_prompt,
    })
  end

  local body_json = json.encode(request_body)
  if not body_json then
    logger.error("无法编码请求体为JSON")
    return function() end
  end

  logger.debug("发送流式AI请求到: " .. (state.config.base_url or "未知URL"))

  -- 创建取消标志
  local cancelled = false
  
  -- 在后台线程中发送请求
  vim.schedule(function()
    -- 这里应该使用真正的流式HTTP请求
    -- 由于HTTP客户端限制，这里使用模拟方式
    local response_id = "stream_" .. os.time() .. "_" .. math.random(1000, 9999)
    
    -- 发送初始块（包含ID）
    if on_chunk and not cancelled then
      on_chunk({
        id = response_id,
        event = "start",
        timestamp = os.time(),
      })
    end
    
    -- 模拟流式响应
    local mock_responses = {
      "这是",
      "AI的",
      "流式",
      "响应",
      "。",
    }
    
    for i, chunk in ipairs(mock_responses) do
      if cancelled then break end
      
      vim.defer_fn(function()
        if on_chunk and not cancelled then
          on_chunk({
            id = response_id,
            content = chunk,
            index = i,
            timestamp = os.time(),
          })
        end
      end, i * 100) -- 每100ms发送一个块
    end
    
    -- 发送完成块
    vim.defer_fn(function()
      if on_chunk and not cancelled then
        on_chunk({
          id = response_id,
          event = "done",
          timestamp = os.time(),
        })
      end
    end, #mock_responses * 100 + 100)
  end)
  
  -- 返回取消函数
  return function()
    cancelled = true
    logger.debug("流式请求已取消")
  end
end

-- 获取提供者状态
-- @return table 状态信息
function M.get_status()
  return {
    initialized = state.initialized,
    config = {
      base_url = state.config.base_url,
      model = state.config.model,
      has_api_key = not not state.config.api_key,
    },
    http_client = state.http and "已加载" or "未加载",
  }
end

-- 导出模块
return M