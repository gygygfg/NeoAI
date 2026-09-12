--- stringx 工具测试
--- @module NeoAI.tests.test_stringx
--- 重点回归 UTF-8 安全截断：字节截断不得切断多字节字符（否则显示为乱码，
--- 并可能让下游严格 JSON 解析器报 invalid unicode code point）。

local tests = require("NeoAI.tests")

--- 字符串是否为合法 UTF-8
--- @param s string
--- @return boolean
local function _valid_utf8(s)
  return (pcall(vim.str_utfindex, s))
end

tests.suite("stringx", function(_, it)
  it("基础函数：trim/split/startswith/endswith/template", function(t)
    local sx = require("NeoAI.utils.stringx")
    t.eq("hi", sx.trim("  hi  "))
    t.eq(3, #sx.split("a,b,c", ","))
    t.true_(sx.startswith("NeoAI:foo", "NeoAI:"))
    t.true_(sx.endswith("foo.lua", ".lua"))
    t.eq("你好 world", sx.template("{a} {b}", { a = "你好", b = "world" }))
  end)

  it("safe_truncate：不在多字节字符中间截断（产生合法 UTF-8）", function(t)
    local sx = require("NeoAI.utils.stringx")
    -- "零副作用" 每字 3 字节；从 4 到 15 逐字节预算都应产出合法 UTF-8
    local s = string.rep("零副作用", 5)
    for n = 4, 15 do
      local r = sx.safe_truncate(s, n, "…")
      t.true_(_valid_utf8(r), ("预算 %d 的截断结果应为合法 UTF-8"):format(n))
      t.true_(#r <= n, ("预算 %d 结果不得超预算（实际 %d）"):format(n, #r))
      t.matches("…$", r, ("预算 %d 应以省略符结尾"):format(n))
    end
    -- 4 字节 emoji 同样不得被切断
    for n = 4, 12 do
      local r = sx.safe_truncate("😀😀😀😀", n, "")
      t.true_(_valid_utf8(r), ("emoji 预算 %d 结果应为合法 UTF-8"):format(n))
    end
  end)

  it("safe_truncate：未超预算原样返回；nil/非字符串安全", function(t)
    local sx = require("NeoAI.utils.stringx")
    t.eq("abc", sx.safe_truncate("abc", 10, "…"), "未超预算应原样返回")
    t.nil_(sx.safe_truncate(nil, 5, "…"), "nil 入参返回 nil")
    local r = sx.safe_truncate(12345, 3, "…")
    t.true_(_valid_utf8(r), "非字符串入参不应崩溃")
  end)

  it("safe_truncate：极小预算不崩溃、无非法字节", function(t)
    local sx = require("NeoAI.utils.stringx")
    local s = "汉字内容测试"
    for n = 0, 4 do
      local r = sx.safe_truncate(s, n, "…")
      t.true_(_valid_utf8(r), ("极小预算 %d 结果应为合法 UTF-8"):format(n))
    end
    -- 预算 < 省略符字节：内容清零，仅剩省略符
    local r0 = sx.safe_truncate(s, 0, "…")
    t.eq("…", r0, "预算 0 时仅保留省略符")
  end)

  it("truncate：超限截断且结果为合法 UTF-8（不切断多字节字符）", function(t)
    local sx = require("NeoAI.utils.stringx")
    t.eq("abcdefghij", sx.truncate("abcdefghij", 20), "未超限原样返回")
    local r = sx.truncate(string.rep("汉字", 10), 10)
    t.true_(#r <= 10, ("truncate 结果不得超限（实际 %d）"):format(#r))
    t.true_(_valid_utf8(r), "truncate 结果应为合法 UTF-8（不得切断汉字）")
    t.matches("%.%.%.$", r, "应追加 ... 省略符")
  end)

  it("sanitize_utf8：非法字节替换为 U+FFFD 且合法内容不变", function(t)
    local sx = require("NeoAI.utils.stringx")
    t.eq("正常内容", sx.sanitize_utf8("正常内容"), "合法内容不变")
    local bad = "汉\xff字"
    local fixed = sx.sanitize_utf8(bad)
    t.true_(_valid_utf8(fixed), "修复后应为合法 UTF-8")
    t.matches("\239\191\189", fixed, "非法字节应替换为 U+FFFD")
  end)
end)
