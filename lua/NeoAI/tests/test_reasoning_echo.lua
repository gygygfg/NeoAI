--- 推理内容回传（reasoning_echo）测试
--- @module 'NeoAI.tests.test_reasoning_echo'
--- 验证 DeepSeek thinking 模式在请求携带 tools 时必须回传历史 assistant 的
--- reasoning_content（否则 400 invalid_request_error）；无 tools 的辅助调用与其他
--- 方言仍保持不回传，避免无意义的 payload 膨胀。

local tests = require("NeoAI.tests")

tests.suite("reasoning_echo", function(_, it)
  local function assistant_with_tool(reasoning)
    return {
      role = "assistant",
      content = "",
      reasoning = reasoning,
      tool_calls = {
        { id = "c1", type = "function", ["function"] = { name = "f", arguments = "{}" } },
      },
    }
  end

  it("DeepSeek 方言：带 tools 时回传所有历史 assistant 的 reasoning_content", function(t)
    local profiles = require("NeoAI.core.model.profiles")
    local adapter = require("NeoAI.core.model.adapter")
    local d = profiles.resolve("deepseek", { api_type = "openai" }, "deepseek-v4-flash-vision-exp")
    t.eq("with_tools", d.reasoning_echo, "DeepSeek OpenAI 方言应回传 reasoning")
    local a = assert(adapter.get("openai"))
    local encoded = a.encode_messages({
      assistant_with_tool("先想再调工具"),
      { role = "tool", tool_call_id = "c1", content = "ok" },
      { role = "assistant", content = "最终回答", reasoning = "再想最终答案" },
    }, d, { has_tools = true })
    t.eq("先想再调工具", encoded.messages[1].reasoning_content, "工具调用消息也应回传")
    t.eq("再想最终答案", encoded.messages[3].reasoning_content, "无工具调用的历史 assistant 也应回传")
  end)

  it("DeepSeek 方言：无 tools 的辅助调用不回传 reasoning_content", function(t)
    local profiles = require("NeoAI.core.model.profiles")
    local adapter = require("NeoAI.core.model.adapter")
    local d = profiles.resolve("deepseek", { api_type = "openai" }, "deepseek-v4-flash-vision-exp")
    local encoded = adapter.get("openai").encode_messages({
      assistant_with_tool("思考"),
      { role = "assistant", content = "答案", reasoning = "再思考" },
    }, d, { has_tools = false })
    t.nil_(encoded.messages[1].reasoning_content, "无 tools 时不应回传")
    t.nil_(encoded.messages[2].reasoning_content, "无 tools 时不应回传")
  end)

  it("非 DeepSeek 方言：即使带 tools 也不回传", function(t)
    local profiles = require("NeoAI.core.model.profiles")
    local adapter = require("NeoAI.core.model.adapter")
    local d = profiles.resolve("openai", { api_type = "openai" }, "gpt-4o")
    t.eq("never", d.reasoning_echo)
    local encoded = adapter.get("openai").encode_messages(
      { assistant_with_tool("思考") }, d, { has_tools = true })
    t.nil_(encoded.messages[1].reasoning_content, "OpenAI 方言保持不回传")
  end)

  it("context_builder 保留 reasoning 供 adapter 编码", function(t)
    local cb = require("NeoAI.core.session.context_builder")
    local out = cb.to_api_message(assistant_with_tool("思维链"))
    t.eq("思维链", out.reasoning)
    t.nil_(out.content, "带 tool_calls 的空 content 仍省略")
    t.eq("c1", out.tool_calls[1].id)
  end)

  it("请求体：DeepSeek 带 tools 时实际下发 reasoning_content", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      ai = {
        default_provider = "deepseek",
        providers = {
          deepseek = { api_type = "openai", base_url = "http://127.0.0.1:1", api_key = "k" },
        },
        model_policy = { enabled = true },
      },
    })
    local http = require("NeoAI.utils.http")
    local async = require("NeoAI.utils.async")
    local request = require("NeoAI.core.agent.request")
    local captured = {}
    local orig = http.request
    ---@diagnostic disable-next-line: duplicate-set-field
    http.request = function(opts)
      local body = opts.body
      -- 只收集本用例的请求：测试运行器可能有其它套件遗留的后台请求（不同 model）。
      if type(body) == "table" and body.model == "deepseek-v4-flash-vision-exp" then
        captured[#captured + 1] = body
      end
      return async.resolve(vim.json.encode({
        choices = { { message = { role = "assistant", content = "ok" }, finish_reason = "stop" } },
      }))
    end
    local d = request.send({
      assistant_with_tool("历史思考"),
      { role = "tool", tool_call_id = "c1", content = "ok" },
      { role = "user", content = "继续" },
    }, {
      model = "deepseek-v4-flash-vision-exp",
      agent_config = {
        provider = "deepseek", model = "deepseek-v4-flash-vision-exp", temperature = 0.5,
      },
      tools = {
        {
          type = "function",
          ["function"] = {
            name = "f", description = "f",
            parameters = { type = "object", properties = {} },
          },
        },
      },
    })
    vim.wait(3000, function() return not d:is_pending() end)
    http.request = orig
    local body = captured[#captured]
    t.not_nil(body, "请求体应被捕获")
    t.eq("历史思考", body.messages[1].reasoning_content, "带 tools 的实际请求体应含 reasoning_content")
  end)
end)
