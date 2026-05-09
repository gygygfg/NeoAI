-- 请求适配器模块
-- 负责根据 api_type 将统一请求格式转换为各 API 提供商的原生格式
-- 支持的 api_type：
--   - "openai"（默认）：OpenAI 兼容格式 /chat/completions
--   - "anthropic"：Anthropic Messages API 格式 /v1/messages
--   - "google"：Google Gemini API 格式
--   - "custom"：自定义格式（通过 adapter 函数）
local M = {}

local logger = require("NeoAI.utils.logger")
local json = require("NeoAI.utils.json")

-- ========== 适配器注册表 ==========

local adapters = {}

--- 注册适配器
--- @param api_type string API 类型名称
--- @param adapter table 适配器，包含 transform_request 和 transform_response 方法
function M.register_adapter(api_type, adapter)
  adapters[api_type] = adapter
  logger.debug(string.format("Request adapter registered: %s", api_type))
end

--- 获取适配器
--- @param api_type string API 类型名称
--- @return table|nil 适配器
function M.get_adapter(api_type)
  return adapters[api_type or "openai"]
end

-- ========== OpenAI 适配器（默认） ==========

M.register_adapter("openai", {
  name = "OpenAI 兼容格式",

  --- 转换请求体为 OpenAI 格式
  --- @param request table 统一请求格式
  --- @param provider_config table 提供商配置
  --- @return table OpenAI 格式的请求体
  transform_request = function(request, provider_config)
    -- OpenAI 格式已经是标准格式，直接返回
    -- 但需要处理 extra_body（如 DeepSeek Thinking Mode）
    local result = {}
    for k, v in pairs(request) do
      if k ~= "extra_body" then
        result[k] = v
      end
    end
    -- 将 extra_body 中的字段合并到顶层
    if request.extra_body then
      for k, v in pairs(request.extra_body) do
        result[k] = v
      end
    end
    return result
  end,

  --- 转换响应为统一格式
  --- @param response table API 原始响应
  --- @return table 统一格式的响应
  transform_response = function(response)
    -- OpenAI 格式已经是标准格式
    return response
  end,

  --- 获取请求头
  --- @param api_key string API 密钥
  --- @return table HTTP 请求头
  get_headers = function(api_key)
    return {
      ["Content-Type"] = "application/json",
      ["Authorization"] = "Bearer " .. api_key,
    }
  end,
})

-- ========== Anthropic 适配器 ==========

M.register_adapter("anthropic", {
  name = "Anthropic Messages API",

  --- 转换请求体为 Anthropic Messages API 格式
  --- @param request table 统一请求格式
  --- @param provider_config table 提供商配置
  --- @return table Anthropic 格式的请求体
  transform_request = function(request, provider_config)
    local anthropic_request = {
      model = request.model,
      max_tokens = request.max_tokens or 4096,
      stream = request.stream or false,
    }

    -- 处理 system 消息（Anthropic 将 system 作为顶层字段）
    local messages = {}
    local system_content = nil

    if request.messages then
      for _, msg in ipairs(request.messages) do
        if msg.role == "system" then
          -- Anthropic 的 system 消息是顶层字段
          if type(msg.content) == "string" then
            system_content = msg.content
          elseif type(msg.content) == "table" then
            system_content = msg.content
          end
        elseif msg.role == "tool" then
          -- Anthropic 的工具结果格式：role = "user"，content 包含 tool_result 块
          local tool_result_content = ""
          if type(msg.content) == "string" then
            tool_result_content = msg.content
          elseif type(msg.content) == "table" then
            local ok, encoded = pcall(json.encode, msg.content)
            tool_result_content = ok and encoded or tostring(msg.content)
          else
            tool_result_content = tostring(msg.content)
          end

          table.insert(messages, {
            role = "user",
            content = {
              {
                type = "tool_result",
                tool_use_id = msg.tool_call_id or "",
                content = tool_result_content,
              },
            },
          })
        elseif msg.role == "assistant" and msg.tool_calls then
          -- Anthropic 的工具调用格式：content 包含 tool_use 块
          local content_blocks = {}

          -- 如果有文本内容，先添加 text 块
          if msg.content and msg.content ~= "" then
            table.insert(content_blocks, {
              type = "text",
              text = msg.content,
            })
          end

          -- 添加 tool_use 块
          -- arguments 已在 http_client 中解析为 Lua table
          for _, tc in ipairs(msg.tool_calls) do
            local tool_func = tc["function"] or tc.func
            local arguments = {}
            if tool_func and tool_func.arguments then
              if type(tool_func.arguments) == "table" then
                arguments = tool_func.arguments
              end
            end

            table.insert(content_blocks, {
              type = "tool_use",
              id = tc.id or ("toolu_" .. tostring(os.time())),
              name = tool_func and tool_func.name or "",
              input = arguments,
            })
          end

          table.insert(messages, {
            role = "assistant",
            content = content_blocks,
          })
        else
          -- 普通 user/assistant 消息
          local anthropic_msg = {
            role = msg.role,
            content = msg.content or "",
          }

          -- 处理 reasoning_content（Anthropic 不支持，但保留以防后续支持）
          if msg.reasoning_content then
            anthropic_msg.reasoning_content = msg.reasoning_content
          end

          table.insert(messages, anthropic_msg)
        end
      end
    end

    anthropic_request.messages = messages

    -- 设置 system 字段
    if system_content then
      anthropic_request.system = system_content
    end

    -- 处理工具定义（Anthropic 的 tools 格式）
    if request.tools and #request.tools > 0 then
      local anthropic_tools = {}
      for _, tool in ipairs(request.tools) do
        if tool.type == "function" and tool["function"] then
          table.insert(anthropic_tools, {
            name = tool["function"].name,
            description = tool["function"].description or "",
            input_schema = tool["function"].parameters or {
              type = "object",
              properties = {},
            },
          })
        end
      end
      if #anthropic_tools > 0 then
        anthropic_request.tools = anthropic_tools
      end
    end

    -- 处理 thinking/extra_body（Anthropic 原生支持 extended thinking）
    if request.extra_body and request.extra_body.thinking then
      anthropic_request.thinking = request.extra_body.thinking
    end

    -- 处理 temperature（Anthropic 支持）
    if request.temperature then
      anthropic_request.temperature = request.temperature
    end

    -- 处理 top_p（Anthropic 支持）
    if request.top_p then
      anthropic_request.top_p = request.top_p
    end

    -- 处理 stop_sequences（Anthropic 支持）
    if request.stop then
      anthropic_request.stop_sequences = type(request.stop) == "table" and request.stop or { request.stop }
    end

    -- 处理 metadata
    if request.metadata then
      anthropic_request.metadata = request.metadata
    end

    return anthropic_request
  end,

  --- 转换 Anthropic 响应为统一格式
  --- @param response table Anthropic 原始响应
  --- @return table 统一格式的响应
  transform_response = function(response)
    -- 转换为 OpenAI 兼容格式
    local unified = {
      id = response.id or "",
      object = "chat.completion",
      created = os.time(),
      model = response.model or "",
      choices = {},
      usage = {},
    }

    if response.content and #response.content > 0 then
      local message = {
        role = "assistant",
        content = "",
        tool_calls = {},
      }

      local text_parts = {}
      local tool_calls = {}

      for _, block in ipairs(response.content) do
        if block.type == "text" then
          table.insert(text_parts, block.text or "")
        elseif block.type == "tool_use" then
          local arguments_table = {}
          if block.input and type(block.input) == "table" then
            arguments_table = block.input
          end

          table.insert(tool_calls, {
            id = block.id or ("toolu_" .. tostring(os.time())),
            type = "function",
            ["function"] = {
              name = block.name or "",
              arguments = arguments_table,
            },
          })
        end
      end

      message.content = table.concat(text_parts, "")

      if #tool_calls > 0 then
        message.tool_calls = tool_calls
      end

      -- 处理 thinking/redacted_thinking（Anthropic extended thinking）
      for _, block in ipairs(response.content) do
        if block.type == "thinking" then
          message.reasoning_content = block.thinking or ""
          break
        elseif block.type == "redacted_thinking" then
          message.reasoning_content = (message.reasoning_content or "") .. "[Redacted Thinking]"
        end
      end

      local finish_reason = response.stop_reason or "stop"
      -- 映射 Anthropic 的 stop_reason 到 OpenAI 格式
      local finish_reason_map = {
        end_turn = "stop",
        stop_sequence = "stop",
        max_tokens = "length",
        tool_use = "tool_calls",
      }

      table.insert(unified.choices, {
        index = 0,
        message = message,
        finish_reason = finish_reason_map[finish_reason] or finish_reason,
        delta = message,
      })
    end

    -- 处理 usage
    if response.usage then
      unified.usage = {
        prompt_tokens = response.usage.input_tokens or 0,
        completion_tokens = response.usage.output_tokens or 0,
        total_tokens = (response.usage.input_tokens or 0) + (response.usage.output_tokens or 0),
      }
    end

    -- 处理 stop_reason 为 tool_use 但没有 content 的情况
    if response.stop_reason == "tool_use" and #unified.choices == 0 then
      -- 这种情况不应该发生，但做防御
      table.insert(unified.choices, {
        index = 0,
        message = {
          role = "assistant",
          content = "",
          tool_calls = {},
        },
        finish_reason = "tool_calls",
      })
    end

    return unified
  end,

  --- 获取 Anthropic 请求头
  --- @param api_key string API 密钥
  --- @return table HTTP 请求头
  get_headers = function(api_key)
    return {
      ["Content-Type"] = "application/json",
      ["x-api-key"] = api_key,
      ["anthropic-version"] = "2023-06-01",
    }
  end,
})

-- ========== Google Gemini 适配器 ==========

M.register_adapter("google", {
  name = "Google Gemini API",

  --- 转换请求体为 Google Gemini 格式
  --- @param request table 统一请求格式
  --- @param provider_config table 提供商配置
  --- @return table Google Gemini 格式的请求体
  transform_request = function(request, provider_config)
    local gemini_contents = {}
    local system_instruction = nil

    if request.messages then
      for _, msg in ipairs(request.messages) do
        if msg.role == "system" then
          -- Gemini 的 system_instruction 是顶层字段
          system_instruction = {
            parts = {
              {
                text = type(msg.content) == "string" and msg.content or tostring(msg.content),
              },
            },
          }
        elseif msg.role == "tool" then
          -- Gemini 的工具结果：role = "function"，parts 包含 functionResponse
          local content = msg.content or ""
          if type(content) ~= "string" then
            local ok, encoded = pcall(json.encode, content)
            content = ok and encoded or tostring(content)
          end

          table.insert(gemini_contents, {
            role = "function",
            parts = {
              {
                functionResponse = {
                  name = msg.name or "",
                  response = {
                    name = msg.name or "",
                    content = content,
                  },
                },
              },
            },
          })
        elseif msg.role == "assistant" and msg.tool_calls then
          -- Gemini 的工具调用：parts 包含 functionCall
          local parts = {}

          -- 如果有文本内容
          if msg.content and msg.content ~= "" then
            table.insert(parts, {
              text = msg.content,
            })
          end

          -- 添加 functionCall
          -- arguments 已在 http_client 中解析为 Lua table
          for _, tc in ipairs(msg.tool_calls) do
            local tool_func = tc["function"] or tc.func
            local args = {}
            if tool_func and tool_func.arguments then
              if type(tool_func.arguments) == "table" then
                args = tool_func.arguments
              end
            end

            table.insert(parts, {
              functionCall = {
                name = tool_func and tool_func.name or "",
                args = args,
              },
            })
          end

          table.insert(gemini_contents, {
            role = "model",
            parts = parts,
          })
        else
          -- 普通消息
          local gemini_role = msg.role
          if gemini_role == "assistant" then
            gemini_role = "model"
          end

          local content = msg.content or ""
          if type(content) ~= "string" then
            local ok, encoded = pcall(json.encode, content)
            content = ok and encoded or tostring(content)
          end

          table.insert(gemini_contents, {
            role = gemini_role,
            parts = {
              {
                text = content,
              },
            },
          })
        end
      end
    end

    local gemini_request = {
      contents = gemini_contents,
    }

    -- 设置 system_instruction
    if system_instruction then
      gemini_request.system_instruction = system_instruction
    end

    -- 处理 generationConfig
    local generation_config = {}

    if request.temperature then
      generation_config.temperature = request.temperature
    end
    if request.max_tokens then
      generation_config.max_output_tokens = request.max_tokens
    end
    if request.top_p then
      generation_config.top_p = request.top_p
    end
    if request.stop then
      generation_config.stop_sequences = type(request.stop) == "table" and request.stop or { request.stop }
    end

    if next(generation_config) then
      gemini_request.generation_config = generation_config
    end

    -- 处理工具定义
    if request.tools and #request.tools > 0 then
      local gemini_tools = {}
      for _, tool in ipairs(request.tools) do
        if tool.type == "function" and tool["function"] then
          table.insert(gemini_tools, {
            function_declarations = {
              {
                name = tool["function"].name,
                description = tool["function"].description or "",
                parameters = tool["function"].parameters or {
                  type = "object",
                  properties = {},
                },
              },
            },
          })
        end
      end
      if #gemini_tools > 0 then
        gemini_request.tools = gemini_tools
      end
    end

    -- 处理 stream
    if request.stream then
      -- Gemini 流式通过不同的端点处理，这里标记
      gemini_request.stream = true
    end

    return gemini_request
  end,

  --- 转换 Google Gemini 响应为统一格式
  --- @param response table Google Gemini 原始响应
  --- @return table 统一格式的响应
  transform_response = function(response)
    local unified = {
      id = "gemini-" .. tostring(os.time()),
      object = "chat.completion",
      created = os.time(),
      model = response.model or "",
      choices = {},
      usage = {},
    }

    if response.candidates and #response.candidates > 0 then
      local candidate = response.candidates[1]
      local message = {
        role = "assistant",
        content = "",
        tool_calls = {},
      }

      local text_parts = {}
      local tool_calls = {}

      if candidate.content and candidate.content.parts then
        for _, part in ipairs(candidate.content.parts) do
          if part.text then
            table.insert(text_parts, part.text)
          elseif part.functionCall then
            local arguments_table = {}
            if part.functionCall.args and type(part.functionCall.args) == "table" then
              arguments_table = part.functionCall.args
            end

            table.insert(tool_calls, {
              id = "fcall_" .. tostring(os.time()) .. "_" .. tostring(#tool_calls + 1),
              type = "function",
              ["function"] = {
                name = part.functionCall.name or "",
                arguments = arguments_table,
              },
            })
          end
        end
      end

      message.content = table.concat(text_parts, "")

      if #tool_calls > 0 then
        message.tool_calls = tool_calls
      end

      local finish_reason = candidate.finishReason or "STOP"
      local finish_reason_map = {
        STOP = "stop",
        MAX_TOKENS = "length",
        SAFETY = "content_filter",
        RECITATION = "content_filter",
        OTHER = "stop",
        FUNCTION_CALL = "tool_calls",
      }

      table.insert(unified.choices, {
        index = 0,
        message = message,
        finish_reason = finish_reason_map[finish_reason] or "stop",
        delta = message,
      })
    end

    -- 处理 usage
    if response.usageMetadata then
      unified.usage = {
        prompt_tokens = response.usageMetadata.promptTokenCount or 0,
        completion_tokens = response.usageMetadata.candidatesTokenCount or 0,
        total_tokens = (response.usageMetadata.promptTokenCount or 0) + (response.usageMetadata.candidatesTokenCount or 0),
      }
    end

    return unified
  end,

  --- 获取 Google Gemini 请求头
  --- @param api_key string API 密钥
  --- @return table HTTP 请求头
  get_headers = function(api_key)
    return {
      ["Content-Type"] = "application/json",
      ["x-goog-api-key"] = api_key,
    }
  end,
})

-- ========== 通用适配器接口 ==========

--- 转换请求体
--- @param request table 统一请求格式
--- @param api_type string API 类型
--- @param provider_config table 提供商配置
--- @return table 转换后的请求体
function M.transform_request(request, api_type, provider_config)
  local adapter = adapters[api_type or "openai"]
  if not adapter then
    logger.warn(string.format("No adapter found for api_type '%s', falling back to openai", api_type or "nil"))
    adapter = adapters["openai"]
  end
  return adapter.transform_request(request, provider_config)
end

--- 转换响应
--- @param response table API 原始响应
--- @param api_type string API 类型
--- @return table 转换后的响应
function M.transform_response(response, api_type)
  local adapter = adapters[api_type or "openai"]
  if not adapter then
    return response
  end
  return adapter.transform_response(response)
end

--- 获取请求头
--- @param api_key string API 密钥
--- @param api_type string API 类型
--- @return table HTTP 请求头
function M.get_headers(api_key, api_type)
  local adapter = adapters[api_type or "openai"]
  if not adapter then
    -- 默认使用 Bearer token
    return {
      ["Content-Type"] = "application/json",
      ["Authorization"] = "Bearer " .. api_key,
    }
  end
  return adapter.get_headers(api_key)
end

--- 获取适配器名称
--- @param api_type string API 类型
--- @return string 适配器名称
function M.get_adapter_name(api_type)
  local adapter = adapters[api_type or "openai"]
  return adapter and adapter.name or "Unknown"
end

--- 获取所有已注册的适配器类型
--- @return table 适配器类型列表
function M.get_available_types()
  local types = {}
  for t, _ in pairs(adapters) do
    table.insert(types, t)
  end
  table.sort(types)
  return types
end

return M
