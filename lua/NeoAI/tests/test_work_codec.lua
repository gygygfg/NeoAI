--- 工作线程结构化卸载（vim.mpack 编解码）专项测试
--- @module 'NeoAI.tests.test_work_codec'
--- 覆盖：utils.work.run_codec 的结构化输入输出、二进制往返、额外原始参数与错误传播。

local tests = require("NeoAI.tests")

tests.suite("work_codec", function(_, it)
  local work = require("NeoAI.utils.work")

  it("run_codec：table 进 table 出", function(t)
    local fn = function(data)
      local sum = 0
      for _, v in ipairs(data.list) do sum = sum + v end
      return { sum = sum, n = #data.list, tag = data.tag }
    end
    local res = t.await(work.run_codec(fn, { list = { 1, 2, 3, 4 }, tag = "ok" }))
    t.eq(10, res.sum)
    t.eq(4, res.n)
    t.eq("ok", res.tag)
  end)

  it("run_codec：嵌套结构与 UTF-8", function(t)
    local fn = function(data)
      return { got = data.nested.list[2], text = data.text }
    end
    local res = t.await(work.run_codec(fn, {
      nested = { list = { "a", "b" } },
      text = "中文 emoji 😀",
    }))
    t.eq("b", res.got)
    t.eq("中文 emoji 😀", res.text)
  end)

  it("run_codec：二进制字符串原生无损往返（无需 base64）", function(t)
    local raw = "bin\xff\xfe\x00end"
    local fn = function(data)
      return { round = data.raw, len = #data.raw }
    end
    local res = t.await(work.run_codec(fn, { raw = raw }))
    t.eq(raw, res.round, "二进制应精确还原")
    t.eq(#raw, res.len)
  end)

  it("run_codec：额外原始类型参数透传", function(t)
    local fn = function(data, mult)
      return { v = data.x * mult }
    end
    local res = t.await(work.run_codec(fn, { x = 7 }, 6))
    t.eq(42, res.v)
  end)

  it("run_codec：worker 内抛错以 reject 返回，不崩溃", function(t)
    local fn = function()
      error("boom")
    end
    local ok, err = pcall(function()
      t.await(work.run_codec(fn, {}))
    end)
    t.false_(ok, "应抛出错误")
    local msg = type(err) == "table" and (err.message or err.kind) or tostring(err)
    t.matches("boom", tostring(msg), "错误信息应透传")
  end)

  it("run_codec：worker 内可用 vim.mpack 与 vim.deepcopy", function(t)
    local fn = function(data)
      local copy = vim.deepcopy(data)
      return { copied = copy.value, has_mpack = type(vim.mpack) == "table" }
    end
    local res = t.await(work.run_codec(fn, { value = "x" }))
    t.eq("x", res.copied)
    t.true_(res.has_mpack, "worker 内应可用 vim.mpack")
  end)

  it("work.available 为真（本环境支持多线程）", function(t)
    t.true_(work.available(), "new_work 应可用")
  end)

  it("selfcheck：worker 内 vim.mpack 往返自检通过", function(t)
    t.true_(work.selfcheck({ timeout_ms = 5000 }), "自检应通过")
  end)

  -- ===== json.encode_async：大对象编码卸载（UTF-8 校验下沉线程池） =====

  it("json.encode_async：与 encode 逐字节一致（键顺序确定，前缀缓存稳定）", function(t)
    local json = require("NeoAI.utils.json")
    local body = { model = "m", stream = true, messages = {}, tools = {} }
    local chunk = string.rep("中文 mixed ASCII。\n", 400)
    for i = 1, 40 do body.messages[i] = { role = "user", content = chunk .. i } end
    for i = 1, 8 do
      body.tools[i] = {
        type = "function",
        ["function"] = { name = "tool_" .. i, description = "说明", parameters = { type = "object" } },
      }
    end
    t.true_(json.should_encode_async(body), "超过阈值应卸载")
    local first = t.await(json.encode_async(body))
    t.eq(json.encode(body), first, "异步编码应与同步编码逐字节一致")
    t.eq(first, t.await(json.encode_async(body)), "多次编码应稳定（键顺序不随机）")
  end)

  it("json.encode_async：非法 UTF-8 与 encode 同样清洗为 U+FFFD", function(t)
    local json = require("NeoAI.utils.json")
    local dirty = {
      a = "x \xc3",
      nested = { "\xed\xa0\x80", valid = "ok" },
      big = string.rep("abc", 30000),
    }
    local got = t.await(json.encode_async(dirty))
    t.eq(json.encode(dirty), got, "非法 UTF-8 应走清洗兜底路径")
    t.false_(got:find("\xc3", 1, true) ~= nil, "输出不应含非法字节")
  end)

  it("json.encode_async：小对象不卸载（保持同步语义）", function(t)
    local json = require("NeoAI.utils.json")
    t.false_(json.should_encode_async({ a = 1, b = "x" }), "小对象不应触发线程往返")
    local small = { a = 1, b = "x" }
    t.eq(json.encode(small), t.await(json.encode_async(small, { min_bytes = 1 })), "小对象应同步编码")
  end)

  it("json.estimate_bytes：有界估算（达到上限即提前返回）", function(t)
    local json = require("NeoAI.utils.json")
    local many = {}
    for i = 1, 1000 do many[i] = string.rep("y", 100) end
    local full = json.estimate_bytes(many)
    t.true_(full >= 100000, "应统计字符串总体积")
    t.true_(json.estimate_bytes(many, 1024) < full, "达到上限应提前返回（不再遍历全部）")
  end)
end)
