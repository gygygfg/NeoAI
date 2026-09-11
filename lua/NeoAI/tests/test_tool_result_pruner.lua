--- 工具结果裁剪测试
--- @module NeoAI.tests.test_tool_result_pruner

local tests = require("NeoAI.tests")

tests.suite("tool_result_pruner", function(_, it)
  local pruner = require("NeoAI.core.session.tool_result_pruner")

  it("measure_content 按码点计数（CJK 每字一码点，非文本块计 0）", function(t)
    t.eq(5, pruner.measure_content("中文abc"))
    t.eq(0, pruner.measure_content({ { type = "image", attachment = {} } }))
    t.eq(4, pruner.measure_content({
      { type = "text", text = "中文" },
      { type = "image" },
      { type = "text", text = "ab" },
    }))
  end)

  it("prune_content 未超阈值返回 nil", function(t)
    local cfg = { threshold_chars = 100, head_chars = 60, tail_chars = 20 }
    t.nil_(pruner.prune_content(string.rep("x", 100), cfg))
    t.nil_(pruner.prune_content(string.rep("x", 10), cfg))
  end)

  it("prune_content 字符串：保留头尾 + 省略标记，且更小", function(t)
    local cfg = { threshold_chars = 1000, head_chars = 400, tail_chars = 100 }
    local content = "H" .. string.rep("m", 9800) .. "T"
    local out = pruner.prune_content(content, cfg)
    t.not_nil(out)
    t.true_(#out < #content)
    t.true_(out:find(pruner.PRUNE_MARKER, 1, true) ~= nil)
    t.eq("H", out:sub(1, 1))
    t.eq("T", out:sub(-1))
    t.true_(pruner.measure_content(out) <= cfg.threshold_chars)
  end)

  it("prune_content 块数组：保留非文本块及其相对顺序", function(t)
    local cfg = { threshold_chars = 100, head_chars = 40, tail_chars = 20 }
    local img = { type = "image", attachment = { id = "a" } }
    local out = pruner.prune_content({
      { type = "text", text = string.rep("a", 500) },
      img,
      { type = "text", text = string.rep("b", 500) },
    }, cfg)
    t.not_nil(out)
    t.eq(3, #out)
    t.eq("image", out[2].type)
    t.eq(img, out[2])
  end)

  it("prune_agent 只裁剪 tool 消息并保留其余字段；二次调用幂等", function(t)
    local big = string.rep("z", 20000)
    local agent = {
      id = "p1",
      messages = {
        { role = "user", content = big },
        { role = "assistant", content = "", tool_calls = { { id = "c1" } } },
        { role = "tool", tool_name = "read_file", tool_call_id = "c1", content = big },
      },
    }
    local opts = { context_cache = { prune_threshold_chars = 1000, prune_head_chars = 400, prune_tail_chars = 100 } }
    local r1 = pruner.prune_agent(agent, opts)
    t.eq(1, r1.pruned)
    t.true_(r1.chars_removed > 0)
    t.eq(big, agent.messages[1].content)
    t.true_(agent.messages[3].pruned)
    t.eq("read_file", agent.messages[3].tool_name)
    t.eq("c1", agent.messages[3].tool_call_id)
    t.true_(#agent.messages[3].content < #big)
    local r2 = pruner.prune_agent(agent, opts)
    t.eq(0, r2.pruned)
  end)

  it("prune_agent 跳过含图像引用的工具结果", function(t)
    local content = vim.json.encode({
      path = "/tmp/a.png",
      image = { attachmentId = "att1" },
      padding = string.rep("p", 20000),
    })
    local agent = {
      id = "p2",
      messages = { { role = "tool", tool_name = "read_image", content = content } },
    }
    local opts = { context_cache = { prune_threshold_chars = 1000, prune_head_chars = 400, prune_tail_chars = 100 } }
    local r = pruner.prune_agent(agent, opts)
    t.eq(0, r.pruned)
    t.eq(content, agent.messages[1].content)
  end)

  it("Blob 工具结果跳过且不抛 E976", function(t)
    local tmp = vim.fn.tempname()
    local f = io.open(tmp, "wb")
    f:write("bin\0" .. string.rep("x", 20000))
    f:close()
    local blob = vim.fn.readblob(tmp)
    vim.fn.delete(tmp)
    t.eq(0, pruner.measure_content(blob))
    local agent = { id = "p3", messages = { { role = "tool", content = blob } } }
    local opts = { context_cache = { prune_threshold_chars = 1000, prune_head_chars = 400, prune_tail_chars = 100 } }
    local r = pruner.prune_agent(agent, opts)
    t.eq(0, r.pruned)
    t.eq(blob, agent.messages[1].content)
  end)
end)
