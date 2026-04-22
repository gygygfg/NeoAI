local M = {}

-- 模块内部状态
local state = {
  initialized = false,
  config = {},
  session_manager = nil,
  is_generating = false,
  current_generation_id = nil,
  tools = {},
  response_builder = nil,
  ai_provider = nil,
  event_constants = nil,
}

-- 初始化 AI 响应流程模块
-- @param options table 初始化选项
function M.initialize(options)
  if state.initialized then
    return
  end

  state.config = options.config or {}
  state.session_manager = options.session_manager

  -- 导入子模块
  state.response_builder = require("NeoAI.core.ai.response_builder")
  state.ai_provider = require("NeoAI.core.ai.ai_provider")
  state.event_constants = require("NeoAI.core.events.event_constants")

  -- 初始化子模块
  state.response_builder.initialize({
    config = state.config,
  })

  state.initialized = true
end

-- 执行 AI 响应流程
-- @param messages table 消息列表
-- @param options table 选项
-- @return string 生成ID
function M.execute_response_flow(messages, options)
  if not state.initialized then
    error("AI response flow not initialized")
  end

  state.is_generating = true
  local generation_id = "gen_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999))
  state.current_generation_id = generation_id

  local session_id = options and options.session_id
  local window_id = options and options.window_id

  -- 检查是否是流式请求
  local is_stream = options and options.stream == true

  if is_stream then
    -- 执行流式响应流程
    M._execute_stream_flow(generation_id, messages, session_id, window_id)
  else
    -- 执行直接响应流程
    M._execute_direct_flow(generation_id, messages, session_id, window_id)
  end

  return generation_id
end

-- 执行直接AI响应流程（非流式）
-- @param generation_id string 生成ID
-- @param messages table 消息列表
-- @param session_id string 会话ID
-- @param window_id number 窗口ID
function M._execute_direct_flow(generation_id, messages, session_id, window_id)
  -- 触发AI请求开始事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = state.event_constants.AI_REQUEST_STARTED,
    data = {
      generation_id = generation_id,
      messages = messages,
      session_id = session_id,
      window_id = window_id,
    },
  })

  -- 使用异步方式调用AI提供者
  state.ai_provider.send_request_async(messages, {
    stream = false,
  }, function(success, ai_response, error_msg)
    -- 回调函数在主线程中执行
    vim.schedule(function()
      if not success then
        -- 触发AI响应错误事件
        vim.api.nvim_exec_autocmds("User", {
          pattern = state.event_constants.AI_RESPONSE_ERROR,
          data = {
            generation_id = generation_id,
            error_msg = error_msg or "AI请求失败，请检查API配置和网络连接。",
            messages = messages,
            session_id = session_id,
            window_id = window_id,
          },
        })

        -- 触发生成错误事件
        vim.api.nvim_exec_autocmds("User", {
          pattern = state.event_constants.GENERATION_ERROR,
          data = {
            generation_id = generation_id,
            error_msg = error_msg or "AI请求失败，请检查API配置和网络连接。",
            messages = messages,
            session_id = session_id,
            window_id = window_id,
          },
        })

        -- 使用备用响应
        ai_response = {
          content = "AI请求失败: " .. (error_msg or "请检查API配置和网络连接。"),
          id = generation_id,
        }
      end

      -- 处理AI响应
      if not ai_response then
        -- 如果连备用响应都没有，创建默认响应
        ai_response = {
          content = "AI请求失败，请检查API配置和网络连接。",
          id = generation_id,
        }
      end

      -- 构建最终响应
      local final_response = state.response_builder.build_response({
        original_messages = messages,
        ai_response = ai_response,
      })

      -- 触发生成完成事件
      vim.api.nvim_exec_autocmds("User", {
        pattern = state.event_constants.GENERATION_COMPLETED,
        data = {
          generation_id = generation_id,
          response = final_response,
          messages = messages,
          session_id = session_id,
          window_id = window_id,
          used_tools = false,
        },
      })

      -- 触发AI响应完成事件
      vim.api.nvim_exec_autocmds("User", {
        pattern = state.event_constants.AI_RESPONSE_COMPLETE,
        data = {
          generation_id = generation_id,
          response = final_response,
          messages = messages,
          session_id = session_id,
          window_id = window_id,
        },
      })

      -- 清理状态
      state.is_generating = false
      state.current_generation_id = nil
    end)
  end)
end

-- 执行流式AI响应流程
-- @param generation_id string 生成ID
-- @param messages table 消息列表
-- @param session_id string 会话ID
-- @param window_id number 窗口ID
function M._execute_stream_flow(generation_id, messages, session_id, window_id)
  -- 触发AI请求开始事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = state.event_constants.AI_REQUEST_STARTED,
    data = {
      generation_id = generation_id,
      messages = messages,
      session_id = session_id,
      window_id = window_id,
    },
  })

  -- 使用异步方式调用AI提供者（流式）
  state.ai_provider.send_request_async(messages, {
    stream = true,
  }, function(success, ai_response, error_msg)
    -- 回调函数在主线程中执行
    vim.schedule(function()
      if not success then
        -- 触发AI响应错误事件
        vim.api.nvim_exec_autocmds("User", {
          pattern = state.event_constants.AI_RESPONSE_ERROR,
          data = {
            generation_id = generation_id,
            error_msg = error_msg or "AI请求失败，请检查API配置和网络连接。",
            messages = messages,
            session_id = session_id,
            window_id = window_id,
          },
        })

        -- 触发生成错误事件
        vim.api.nvim_exec_autocmds("User", {
          pattern = state.event_constants.GENERATION_ERROR,
          data = {
            generation_id = generation_id,
            error_msg = error_msg or "AI请求失败，请检查API配置和网络连接。",
            messages = messages,
            session_id = session_id,
            window_id = window_id,
          },
        })

        -- 使用备用响应
        ai_response = {
          content = "AI请求失败: " .. (error_msg or "请检查API配置和网络连接。"),
          id = generation_id,
        }
      end

      -- 处理AI响应
      if not ai_response then
        -- 如果连备用响应都没有，创建默认响应
        ai_response = {
          content = "AI请求失败，请检查API配置和网络连接。",
          id = generation_id,
        }
      end

      -- 构建最终响应
      local final_response = state.response_builder.build_response({
        original_messages = messages,
        ai_response = ai_response,
      })

      -- 触发生成完成事件
      vim.api.nvim_exec_autocmds("User", {
        pattern = state.event_constants.GENERATION_COMPLETED,
        data = {
          generation_id = generation_id,
          response = final_response,
          messages = messages,
          session_id = session_id,
          window_id = window_id,
          used_tools = false,
        },
      })

      -- 触发AI响应完成事件
      vim.api.nvim_exec_autocmds("User", {
        pattern = state.event_constants.AI_RESPONSE_COMPLETE,
        data = {
          generation_id = generation_id,
          response = final_response,
          messages = messages,
          session_id = session_id,
          window_id = window_id,
        },
      })

      -- 清理状态
      state.is_generating = false
      state.current_generation_id = nil
    end)
  end)
end

-- 取消当前生成
function M.cancel_generation()
  if not state.is_generating then
    return
  end

  local generation_id = state.current_generation_id

  -- 触发取消事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = state.event_constants.GENERATION_CANCELLED,
    data = {
      generation_id = generation_id,
    },
  })

  -- 清理状态
  state.is_generating = false
  state.current_generation_id = nil
end

-- 设置工具
-- @param tools table 工具字典
function M.set_tools(tools)
  state.tools = tools or {}
end

-- 获取状态
-- @return table 状态信息
function M.get_status()
  return {
    initialized = state.initialized,
    is_generating = state.is_generating,
    current_generation_id = state.current_generation_id,
    tools_count = state.tools and #state.tools or 0,
  }
end

return M
