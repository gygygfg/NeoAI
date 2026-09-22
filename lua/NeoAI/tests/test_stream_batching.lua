--- 流式累积（避免 O(n²) 拼接）专项测试
--- @module NeoAI.tests.test_stream_batching
--- 验证：小内容逐分片即时可见；大内容分片累积后 finalize 不丢数据、顺序正确。

local tests = require("NeoAI.tests")

tests.suite("stream_batching", function(_, it)
  local agent_mod = require("NeoAI.core.agent.agent")

  it("小内容逐分片即时物化（语义不变）", function(t)
    local agent = agent_mod.create()
    agent:append_content("hello ")
    t.eq("hello ", agent.messages[#agent.messages].content)
    agent:append_content("world")
    t.eq("hello world", agent.messages[#agent.messages].content)
  end)

  it("小推理逐分片即时物化", function(t)
    local agent = agent_mod.create()
    agent:append_reasoning("a")
    agent:append_reasoning("b")
    t.eq("ab", agent.messages[#agent.messages].reasoning)
  end)

  it("大内容分片累积：finalize 后完整且顺序正确", function(t)
    local agent = agent_mod.create()
    local chunks = {}
    local piece = string.rep("x", 64)
    local n = 4000 -- 256KB，超过 SMALL_CONTENT_BYTES
    for i = 1, n do
      chunks[i] = i .. ":" .. piece
      agent:append_content(chunks[i])
    end
    local msg = agent.messages[#agent.messages]
    -- 未 finalize 前可能是前缀，但绝不超过总长
    t.ok(#msg.content <= #table.concat(chunks), "前缀不应超过总长")
    agent:finalize_stream()
    t.eq(table.concat(chunks), msg.content, "finalize 后应完整")
  end)

  it("8KB 边界：超过后转分片累积，finalize 完整且顺序正确", function(t)
    local agent = agent_mod.create()
    local chunks = {}
    local piece = string.rep("z", 100)
    for i = 1, 200 do -- ~20KB，超过 8KB 小内容阈值
      chunks[i] = i .. ":" .. piece
      agent:append_content(chunks[i])
    end
    local msg = agent.messages[#agent.messages]
    t.ok(#msg.content <= #table.concat(chunks), "累积期内容不应超过总长")
    agent:finalize_stream()
    t.eq(table.concat(chunks), msg.content, "finalize 后应完整且顺序正确")
  end)

  it("大推理分片累积：finalize 后完整", function(t)
    local agent = agent_mod.create()
    local chunks = {}
    for i = 1, 4000 do
      chunks[i] = "r" .. i .. ":"
      agent:append_reasoning(chunks[i])
    end
    agent:finalize_stream()
    t.eq(table.concat(chunks), agent.messages[#agent.messages].reasoning)
  end)

  it("finalize 清理内部缓冲字段", function(t)
    local agent = agent_mod.create()
    for i = 1, 4000 do agent:append_content("y" .. i) end
    agent:finalize_stream()
    local msg = agent.messages[#agent.messages]
    t.nil_(msg._content_parts, "_content_parts 应清理")
    t.nil_(msg._content_bytes, "_content_bytes 应清理")
  end)
end)
