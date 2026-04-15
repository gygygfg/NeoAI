-- 测试窗口宽度计算函数
local utils = require("NeoAI.utils")

-- 创建一个测试窗口
local buf = vim.api.nvim_create_buf(false, true)
local win = vim.api.nvim_open_win(buf, false, {
  relative = "editor",
  width = 80,
  height = 20,
  row = 10,
  col = 10,
  style = "minimal",
  border = "single"
})

print("测试窗口宽度计算:")
print("窗口ID:", win)

-- 测试1: 默认情况（无行号）
local width1 = utils.calculate_text_width(win)
print("测试1 - 无行号:", width1)

-- 测试2: 启用行号
vim.api.nvim_set_option_value("number", true, { win = win })
local width2 = utils.calculate_text_width(win)
print("测试2 - 有行号:", width2)
print("宽度差:", width1 - width2)

-- 测试3: 禁用行号
vim.api.nvim_set_option_value("number", false, { win = win })
local width3 = utils.calculate_text_width(win)
print("测试3 - 禁用行号:", width3)
print("是否与测试1相同:", width3 == width1)

-- 测试4: 启用相对行号
vim.api.nvim_set_option_value("relativenumber", true, { win = win })
local width4 = utils.calculate_text_width(win)
print("测试4 - 相对行号:", width4)
print("是否与测试2相同:", width4 == width2)

-- 清理
vim.api.nvim_win_close(win, true)
vim.api.nvim_buf_delete(buf, { force = true })

print("\n测试完成!")