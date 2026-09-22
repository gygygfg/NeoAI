--- ANSI SGR 解析测试
--- @module NeoAI.tests.test_ansi
--- 覆盖：颜色/属性解析、reset、256 色与真彩色、非 SGR 序列剥离。

local tests = require("NeoAI.tests")

tests.suite("ansi", function(_, it)
  it("解析基础颜色与 reset，剥离转义保留文本", function(t)
    local ansi = require("NeoAI.utils.ansi")
    ansi.reset()
    local lines = ansi.parse("\27[1;36m== A ==\27[0m plain \27[31mred\27[0m")
    t.eq(1, #lines, "单行")
    t.eq("== A == plain red", lines[1].text, "应剥离转义")
    t.eq(2, #lines[1].spans, "应有两个高亮区间")
    t.eq(0, lines[1].spans[1][1])
    t.eq(7, lines[1].spans[1][2])
    t.eq(14, lines[1].spans[2][1])
    t.eq(17, lines[1].spans[2][2])
    t.true_(lines[1].spans[1][3] ~= lines[1].spans[2][3], "不同颜色应使用不同高亮组")
  end)

  it("多行按 \\n 切分，\\r 与光标/OSC 序列被剥离", function(t)
    local ansi = require("NeoAI.utils.ansi")
    local lines = ansi.parse("a\27[2Kb\r\n\27]0;title\7c\27[1A")
    t.eq(2, #lines, "应为两行")
    t.eq("ab", lines[1].text, "行内非 SGR 序列与 \\r 应剥离")
    t.eq("c", lines[2].text, "OSC 标题与光标移动应剥离")
  end)

  it("256 色与真彩色生成独立高亮组", function(t)
    local ansi = require("NeoAI.utils.ansi")
    ansi.reset()
    local lines = ansi.parse("\27[38;5;208mX\27[48;2;10;20;30mY\27[0mZ")
    t.eq("XYZ", lines[1].text)
    t.eq(2, #lines[1].spans, "256 色与真彩色各一段")
    t.true_(lines[1].spans[1][3] ~= lines[1].spans[2][3], "颜色不同组名应不同")
    t.false_(ansi.has_ansi("plain"), "无转义应判 false")
    t.true_(ansi.has_ansi("\27[0m"), "含转义应判 true")
  end)

  it("控制字节与非法 UTF-8 被清洗（不渲染成 ^P / <f9> 乱码）", function(t)
    local ansi = require("NeoAI.utils.ansi")
    -- C0 控制字节（0x16 / DEL）应剥离，制表符保留。
    local lines = ansi.parse("a\22b\127c\9keep")
    t.eq("abc\tkeep", lines[1].text, "C0 控制字节剥离、制表符保留")
    -- 非法首字节 0xF9 应替换为 U+FFFD。
    local l2 = ansi.parse("\249ok")
    t.true_(l2[1].text:find("\239\191\189", 1, true) ~= nil, "非法字节替换为 U+FFFD")
    t.true_(l2[1].text:find("ok", 1, true) ~= nil, "其余文本保留")
  end)
end)
