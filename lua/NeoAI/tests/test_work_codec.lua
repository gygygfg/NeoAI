--- 工作线程结构化卸载（vim.mpack 编解码）专项测试
--- @module NeoAI.tests.test_work_codec
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
end)
