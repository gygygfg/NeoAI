-- 测试 vim.defer_fn 修复
local function test_watch_stream()
  print("test_watch_stream called")
  return nil  -- 模拟返回 nil 的情况
end

-- 错误的调用方式（会导致 vim.defer_fn(nil, 50)）
-- vim.defer_fn(test_watch_stream(), 50)

-- 正确的调用方式
vim.defer_fn(function() test_watch_stream() end, 50)

print("Test completed")