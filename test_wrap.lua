local utils = require("NeoAI.utils")

-- 测试文本
local test_text = "，而妻子本意是'如果看到鸡"

-- 测试不同宽度下的换行
for width = 20, 50, 5 do
  local wrapped = utils.wrap_text(test_text, width)
  print(string.format("宽度 %d: %s", width, table.concat(wrapped, " | ")))
end

-- 测试 display_width
print("\n字符串显示宽度测试:")
print("测试文本: " .. test_text)
print("显示宽度: " .. utils.display_width(test_text))
print("字符串长度: " .. #test_text)

-- 逐个字符测试
print("\n逐个字符宽度:")
for ch in test_text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
  local width = utils.display_width(ch)
  local byte = ch:byte(1)
  print(string.format("字符: %s, 字节: 0x%02x, 宽度: %d", ch, byte, width))
end