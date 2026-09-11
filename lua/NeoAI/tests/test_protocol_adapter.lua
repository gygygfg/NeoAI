--- 三协议编解码测试（messages / tools / image / usage / stream）
--- @module NeoAI.tests.test_protocol_adapter

local tests = require("NeoAI.tests")

tests.suite("protocol_adapter", function(_, it)
  local adapter = require("NeoAI.core.model.adapter")

  local IMG = { type = "image", media_type = "image/png", base64 = "AAAA" }

  it("OpenAI：中立图像块 → image_url，字段直通", function(t)
    local a = adapter.get("openai")
    local enc = a.encode_messages({
      { role = "system", content = "sys" },
      { role = "user", content = { { type = "text", text = "hi" }, IMG } },
      { role = "assistant", content = "", tool_calls = { { id = "c1", ["function"] = { name = "f", arguments = "{}" } } } },
      { role = "tool", tool_call_id = "c1", content = "ok" },
    }, {})
    t.eq("sys", enc.messages[1].content)
    t.eq("image_url", enc.messages[2].content[2].type)
    t.eq("data:image/png;base64,AAAA", enc.messages[2].content[2].image_url.url)
    t.eq("c1", enc.messages[4].tool_call_id)
    -- 工具定义原样
    local tools = { { type = "function", ["function"] = { name = "f" } } }
    t.eq(tools, a.encode_tools(tools, {}))
  end)

  it("OpenAI：reasoning effort / enable_thinking 形态", function(t)
    local a = adapter.get("openai")
    local b1 = a.build_body({ model = "o3", messages = {}, reasoning_enabled = true, dialect = { reasoning_kind = "effort", max_tokens_field = "max_completion_tokens" } })
    t.eq("medium", b1.reasoning_effort)
    t.false_(b1.max_tokens ~= nil)
    local b2 = a.build_body({ model = "m", messages = {}, reasoning_enabled = true, dialect = { reasoning_kind = "enable_thinking" } })
    t.true_(b2.enable_thinking)
    local b3 = a.build_body({ model = "m", messages = {}, reasoning_enabled = true, dialect = { reasoning_kind = "thinking_object" } })
    t.eq("enabled", b3.thinking.type)
  end)

  it("OpenAI：流式自动加 stream_options.include_usage", function(t)
    local a = adapter.get("openai")
    local b = a.build_body({ model = "m", messages = {}, stream = true, dialect = { stream_usage = true } })
    t.true_(b.stream_options.include_usage)
    local b2 = a.build_body({ model = "m", messages = {}, stream = true, dialect = { stream_usage = false } })
    t.nil_(b2.stream_options)
  end)

  it("输出上限：未传入时不发送（OpenAI / Gemini 省略字段）", function(t)
    local o = adapter.get("openai")
    local bo = o.build_body({ model = "m", messages = {}, dialect = {} })
    t.nil_(bo.max_tokens)
    local o2 = o.build_body({ model = "m", messages = {}, dialect = { max_tokens_field = "max_completion_tokens" } })
    t.nil_(o2.max_completion_tokens)
    local g = adapter.get("google")
    local bg = g.build_body({ model = "m", messages = {}, dialect = {} })
    t.nil_(bg.generationConfig.maxOutputTokens)
    -- 传入时原样使用
    t.eq(2048, o.build_body({ model = "m", messages = {}, max_tokens = 2048, dialect = {} }).max_tokens)
  end)

  it("输出上限：Anthropic 必填，未传时保留兼底", function(t)
    local a = adapter.get("anthropic")
    local b = a.build_body({ model = "claude", messages = {}, dialect = {} })
    t.not_nil(b.max_tokens)
  end)

  it("Anthropic：system 顶层 + tool_use/tool_result + input_schema + base64 图像", function(t)
    local a = adapter.get("anthropic")
    local enc = a.encode_messages({
      { role = "system", content = "SYS" },
      { role = "user", content = "q" },
      { role = "assistant", content = "ans", tool_calls = { { id = "t1", ["function"] = { name = "read", arguments = '{"a":1}' } } } },
      { role = "tool", tool_call_id = "t1", tool_name = "read", content = "R" },
      { role = "user", content = { { type = "text", text = "看" }, IMG } },
    }, {})
    t.eq("SYS", enc.system)
    t.eq("user", enc.messages[1].role)
    -- assistant: text + tool_use
    local asst = enc.messages[2]
    t.eq("assistant", asst.role)
    t.eq("text", asst.content[1].type)
    t.eq("tool_use", asst.content[2].type)
    t.eq("read", asst.content[2].name)
    t.eq(1, asst.content[2].input.a)
    -- tool → user + tool_result
    local tr = enc.messages[3]
    t.eq("user", tr.role)
    t.eq("tool_result", tr.content[1].type)
    t.eq("t1", tr.content[1].tool_use_id)
    -- 图像块
    local imgblock = enc.messages[4].content[2]
    t.eq("image", imgblock.type)
    t.eq("base64", imgblock.source.type)
    t.eq("AAAA", imgblock.source.data)
    -- 工具 → input_schema
    local tools = a.encode_tools({ { type = "function", ["function"] = { name = "read", description = "d", parameters = { type = "object" } } } }, {})
    t.eq("read", tools[1].name)
    t.eq("object", tools[1].input_schema.type)
  end)

  it("Anthropic：开启 thinking 时 temperature 强制为 1", function(t)
    local a = adapter.get("anthropic")
    local b = a.build_body({ model = "claude", messages = {}, reasoning_enabled = true, temperature = 0.3, dialect = { reasoning_kind = "budget" } })
    t.eq(1, b.temperature)
    t.eq("enabled", b.thinking.type)
  end)

  it("Gemini：contents + systemInstruction + functionDeclarations + inlineData", function(t)
    local a = adapter.get("google")
    local enc = a.encode_messages({
      { role = "system", content = "SYS" },
      { role = "user", content = "q" },
      { role = "assistant", content = "ans", tool_calls = { { id = "t1", ["function"] = { name = "read", arguments = '{"a":1}' } } } },
      { role = "tool", tool_call_id = "t1", tool_name = "read", content = "R" },
      { role = "user", content = { { type = "text", text = "看" }, IMG } },
    }, {})
    t.eq("SYS", enc.system[1].text)
    t.eq("user", enc.messages[1].role)
    t.eq("model", enc.messages[2].role)
    t.eq("read", enc.messages[2].parts[2].functionCall.name)
    t.eq("R", enc.messages[3].parts[1].functionResponse.response.result)
    t.eq("image/png", enc.messages[4].parts[2].inlineData.mimeType)
    -- 工具 schema：类型大写 + 裁剪不支持关键字
    local tools = a.encode_tools({ { type = "function", ["function"] = { name = "read", parameters = {
      type = "object", properties = { a = { type = "string", default = "x" } }, additionalProperties = false,
    } } } }, {})
    local decl = tools[1].functionDeclarations[1]
    t.eq("OBJECT", decl.parameters.type)
    t.eq("STRING", decl.parameters.properties.a.type)
    t.nil_(decl.parameters.properties.a.default)
    t.nil_(decl.parameters.additionalProperties)
  end)

  it("响应解析：Anthropic thinking 块 / Gemini thought 分片", function(t)
    local a = adapter.get("anthropic")
    local r = a.parse_response('{"content":[{"type":"thinking","thinking":"T"},{"type":"text","text":"C"}],"stop_reason":"end_turn"}')
    t.eq("C", r.content)
    t.eq("T", r.reasoning)

    local g = adapter.get("google")
    local sc = g.parse_stream_chunk('{"candidates":[{"content":{"parts":[{"text":"th","thought":true},{"text":"vis"}]}}]}')
    t.eq("th", sc.reasoning)
    t.eq("vis", sc.content)
  end)

  it("usage 为 JSON null 时不得泄漏 vim.NIL（三协议流式/非流式）", function(t)
    -- vim.json.decode 将 null 解码为 vim.NIL(userdata，真值)，适配器必须丢弃，
    -- 否则 vim.tbl_deep_extend 会抛 "expected table, got userdata"。
    local o = adapter.get("openai")
    t.nil_(o.parse_stream_chunk('{"choices":[{"delta":{}}],"usage":null}'))
    t.nil_(o.parse_response('{"choices":[{"message":{"content":"x"},"finish_reason":"stop"}],"usage":null}').usage)

    local a = adapter.get("anthropic")
    t.nil_(a.parse_stream_chunk('{"type":"message_start","message":{"usage":null}}'))
    t.nil_(a.parse_stream_chunk('{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":null}').usage)
    t.nil_(a.parse_response('{"content":[],"stop_reason":"end_turn","usage":null}').usage)

    local g = adapter.get("google")
    t.nil_(g.parse_stream_chunk('{"usageMetadata":null}'))
    t.nil_(g.parse_response('{"candidates":[{"finishReason":"STOP"}],"usageMetadata":null}').usage)
  end)

  it("内部字段（_bytes）不进入 wire JSON", function(t)
    local json = require("NeoAI.utils.json")
    local part = { type = "image", media_type = "image/png", base64 = "AAAA", _bytes = 123 }
    local enc = adapter.get("openai").encode_messages({ { role = "user", content = { part } } }, {})
    local encoded = json.encode(enc.messages)
    t.nil_(encoded:find("_bytes", 1, true))
    t.true_(encoded:find("image_url", 1, true) ~= nil)
  end)
end)
