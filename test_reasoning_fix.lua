-- 测试推理内容显示修复
local M = {}

function M.test_reasoning_update()
  print("测试推理内容更新逻辑...")
  
  -- 模拟后端发送的推理更新
  local test_cases = {
    {
      name = "测试1: 逐步扩展的文本",
      updates = {
        "这是第一行推理",
        "这是第一行推理\n这是第二行推理",
        "这是第一行推理\n这是第二行推理\n这是第三行推理",
      }
    },
    {
      name = "测试2: 重复发送相同文本",
      updates = {
        "相同的文本",
        "相同的文本", -- 重复
        "相同的文本", -- 再次重复
      }
    },
    {
      name = "测试3: 文本被截断后重新发送",
      updates = {
        "这是一个很长的推理文本，可能会被",
        "这是一个很长的推理文本，可能会被截断",
        "这是一个很长的推理文本，可能会被截断然后重新发送完整版本",
      }
    }
  }
  
  for _, test_case in ipairs(test_cases) do
    print("\n" .. test_case.name)
    local current_text = ""
    
    for i, new_text in ipairs(test_case.updates) do
      print(string.format("  更新 %d: %s", i, new_text:gsub("\n", "\\n")))
      
      -- 模拟 update_reasoning 的逻辑
      if new_text == current_text then
        print("    文本相同，跳过更新")
      elseif new_text:sub(1, #current_text) == current_text then
        print("    文本扩展，更新")
        current_text = new_text
      elseif current_text:sub(1, #new_text) == new_text then
        print("    新文本是现有文本的前缀，保持现有文本")
      else
        print("    完全不同的文本，替换")
        current_text = new_text
      end
    end
  end
end

function M.test_refresh_logic()
  print("\n\n测试浮动窗口刷新逻辑...")
  
  -- 模拟 refresh_reasoning_float 的逻辑
  local last_text = ""
  local updates = {
    "第一次更新",
    "第一次更新", -- 相同，应该跳过
    "第一次更新扩展", -- 不同，应该更新
    "第一次更新扩展", -- 相同，应该跳过
    "完全不同的文本", -- 不同，应该更新
  }
  
  for i, new_text in ipairs(updates) do
    print(string.format("  更新 %d: %s", i, new_text))
    
    if last_text == new_text then
      print("    文本未变化，跳过更新")
    else
      print("    文本变化，更新浮动窗口")
      last_text = new_text
    end
  end
end

-- 运行测试
M.test_reasoning_update()
M.test_refresh_logic()

print("\n\n测试完成！")
print("修复总结：")
print("1. update_reasoning: 避免重复追加相同文本")
print("2. refresh_reasoning_float: 添加文本变化检测")
print("3. ai_reasoning_update: 移除不必要的 update_display 调用")
print("4. _create_reasoning_float_windows: 优化更新逻辑")

return M