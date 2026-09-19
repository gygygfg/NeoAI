--- 纯 Lua SHA-256 专项测试
--- @module NeoAI.tests.test_sha256
--- 与 `vim.fn.sha256` 交叉校验（候选 CAS 依赖哈希一致），并覆盖工作线程内 `load(source)` 的等价性。

local tests = require("NeoAI.tests")

tests.suite("sha256", function(_, it)
  it("与 vim.fn.sha256 一致（空串/短串/长串/二进制/多块）", function(t)
    local sha = require("NeoAI.utils.sha256")
    local cases = {
      "",
      "a",
      "abc",
      "The quick brown fox jumps over the lazy dog",
      string.rep("x", 55),
      string.rep("x", 56),
      string.rep("x", 63),
      string.rep("x", 64),
      string.rep("payload-", 1000),
      "\0\1\2\255\254",
      string.char(0, 255, 0, 255) .. string.rep("\128", 200),
    }
    for _, s in ipairs(cases) do
      t.eq(vim.fn.sha256(s), sha.hex(s), "输入长度 " .. #s)
    end
  end)

  it("工作线程内 load(source) 与主线程结果一致", function(t)
    local sha = require("NeoAI.utils.sha256")
    local worker = assert(load(sha.source))()
    for _, s in ipairs({ "", "abc", string.rep("data", 100), "中文-UTF8-密钥" }) do
      t.eq(vim.fn.sha256(s), worker(s), "输入长度 " .. #s)
    end
  end)

  it("已知向量", function(t)
    local sha = require("NeoAI.utils.sha256")
    t.eq("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", sha.hex("abc"))
    t.eq("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", sha.hex(""))
  end)
end)
