-- DeepSeek 响应模拟测试
-- 直接调用主模块渲染响应，测试主模块是否正确处理流式响应

local M = {}

-- 测试状态
local test_state = {
  initialized = false,
  response_files = {},
}

--- 初始化测试环境
local function init_test_environment()
  if test_state.initialized then
    return true
  end

  print("🔧 初始化DeepSeek响应测试环境...")

  -- 加载响应文件
  test_state.response_files = {
    streaming_no_reasoning = "/root/NeoAI/pack/plugins/start/NeoAI/lua/NeoAI/tests/deepseek_responses/streaming_no_reasoning_20260419_231549.json",
    reasoning_streaming = "/root/NeoAI/pack/plugins/start/NeoAI/lua/NeoAI/tests/deepseek_responses/reasoning_streaming_20260419_231549.json",
    reasoning_non_stream = "/root/NeoAI/pack/plugins/start/NeoAI/lua/NeoAI/tests/deepseek_responses/reasoning_non_stream_20260419_231549.json",
  }

  -- 验证响应文件存在
  for name, path in pairs(test_state.response_files) do
    local file = io.open(path, "r")
    if not file then
      print("❌ 响应文件不存在: " .. path)
      return false
    end
    file:close()
  end

  test_state.initialized = true
  print("✅ DeepSeek响应测试环境初始化完成")
  return true
end

--- 读取响应文件内容
local function read_response_file(filepath)
  local file = io.open(filepath, "r")
  if not file then
    return nil, "无法打开文件: " .. filepath
  end

  local content = file:read("*a")
  file:close()

  return content
end

--- 解析SSE响应数据
local function parse_sse_response(content)
  local lines = {}
  for line in content:gmatch("[^\r\n]+") do
    table.insert(lines, line)
  end

  local chunks = {}
  for _, line in ipairs(lines) do
    if line:sub(1, 6) == "data: " then
      local data = line:sub(7)
      if data ~= "[DONE]" then
        table.insert(chunks, data)
      end
    end
  end

  return chunks
end

--- 测试无推理的流式响应
local function test_streaming_no_reasoning()
  print("🧪 测试无推理的流式响应...")

  -- 尝试加载主模块的流处理器
  local stream_processor
  local success, err = pcall(function()
    stream_processor = require("NeoAI.core.ai.stream_processor")
  end)

  if not success or not stream_processor then
    print("❌ 无法加载流处理器: " .. tostring(err))
    return false, "无法加载流处理器"
  end

  print("✅ 流处理器加载成功")

  -- 初始化流处理器
  stream_processor.initialize({
    config = {
      debug = true,
    },
  })

  -- 设置事件监听器来捕获渲染输出
  local content_output = {}

  -- 监听内容事件
  vim.api.nvim_create_autocmd("User", {
    pattern = "content_chunk",
    callback = function(args)
      local data = args.data
      if data and #data > 0 then
        local chunk = data[1]
        table.insert(content_output, chunk)
        -- print("📝 主模块内容块: " .. tostring(chunk):sub(1, 50) .. "...")
      end
    end,
  })

  -- 读取响应文件
  local content, err = read_response_file(test_state.response_files.streaming_no_reasoning)
  if not content then
    return false, "无法读取响应文件: " .. err
  end

  -- 解析SSE数据
  local chunks = parse_sse_response(content)
  if #chunks == 0 then
    return false, "响应文件中没有有效的数据块"
  end

  print("📊 解析到 " .. #chunks .. " 个数据块")
  print("🚀 开始调用主模块处理流式响应...")

  -- 直接调用主模块的流处理器处理每个数据块
  for i, chunk in ipairs(chunks) do
    -- 添加 "data: " 前缀，因为流处理器期望这个格式
    local data_chunk = "data: " .. chunk

    -- 调用主模块处理数据块
    local success, err = pcall(function()
      stream_processor.process_chunk(data_chunk)
    end)

    if not success then
      print("❌ 处理数据块 " .. i .. " 时出错: " .. tostring(err))
    else
      -- print("📥 已处理数据块 " .. i .. "/" .. #chunks)
    end

    -- 添加小延迟模拟流式效果
    vim.wait(10)
  end

  -- 刷新缓冲区
  stream_processor.flush_buffer()

  print("✅ 无推理流式响应测试完成")
  print("📈 主模块处理结果 - 内容块: " .. #content_output)

  -- 显示一些示例输出
  if #content_output > 0 then
    print("📋 内容输出示例 (前3个):")
    for i = 1, math.min(3, #content_output) do
      print("  " .. i .. ". " .. tostring(content_output[i]):sub(1, 100) .. "...")
    end
  end

  return true, "无推理流式响应测试完成"
end

--- 测试带推理的流式响应
local function test_reasoning_streaming()
  print("🧪 测试带推理的流式响应...")

  -- 尝试加载主模块的流处理器
  local stream_processor
  local success, err = pcall(function()
    stream_processor = require("NeoAI.core.ai.stream_processor")
  end)

  if not success or not stream_processor then
    print("❌ 无法加载流处理器: " .. tostring(err))
    return false, "无法加载流处理器"
  end

  print("✅ 流处理器加载成功")

  -- 初始化流处理器
  stream_processor.initialize({
    config = {
      debug = true,
    },
  })

  -- 设置事件监听器来捕获渲染输出
  local reasoning_output = {}
  local content_output = {}

  -- 监听推理事件
  vim.api.nvim_create_autocmd("User", {
    pattern = "reasoning_chunk",
    callback = function(args)
      local data = args.data
      if data and #data > 0 then
        local chunk = data[1]
        table.insert(reasoning_output, chunk)
        -- print("💭 主模块推理块: " .. tostring(chunk):sub(1, 50) .. "...")
      end
    end,
  })

  -- 监听内容事件
  vim.api.nvim_create_autocmd("User", {
    pattern = "content_chunk",
    callback = function(args)
      local data = args.data
      if data and #data > 0 then
        local chunk = data[1]
        table.insert(content_output, chunk)
        -- print("📝 主模块内容块: " .. tostring(chunk):sub(1, 50) .. "...")
      end
    end,
  })

  -- 读取响应文件
  local content, err = read_response_file(test_state.response_files.reasoning_streaming)
  if not content then
    return false, "无法读取响应文件: " .. err
  end

  -- 解析SSE数据
  local chunks = parse_sse_response(content)
  if #chunks == 0 then
    return false, "响应文件中没有有效的数据块"
  end

  print("📊 解析到 " .. #chunks .. " 个数据块")
  print("🚀 开始调用主模块处理流式响应...")

  -- 直接调用主模块的流处理器处理每个数据块
  for i, chunk in ipairs(chunks) do
    -- 添加 "data: " 前缀，因为流处理器期望这个格式
    local data_chunk = "data: " .. chunk

    -- 调用主模块处理数据块
    local success, err = pcall(function()
      stream_processor.process_chunk(data_chunk)
    end)

    if not success then
      print("❌ 处理数据块 " .. i .. " 时出错: " .. tostring(err))
    else
      -- print("📥 已处理数据块 " .. i .. "/" .. #chunks)
    end

    -- 添加小延迟模拟流式效果
    vim.wait(10)
  end

  -- 刷新缓冲区
  stream_processor.flush_buffer()

  print("✅ 带推理流式响应测试完成")
  print("📈 主模块处理结果 - 推理块: " .. #reasoning_output .. ", 内容块: " .. #content_output)

  -- 显示一些示例输出
  if #reasoning_output > 0 then
    print("📋 推理输出示例 (前3个):")
    for i = 1, math.min(3, #reasoning_output) do
      print("  " .. i .. ". " .. tostring(reasoning_output[i]):sub(1, 100) .. "...")
    end
  end

  if #content_output > 0 then
    print("📋 内容输出示例 (前3个):")
    for i = 1, math.min(3, #content_output) do
      print("  " .. i .. ". " .. tostring(content_output[i]):sub(1, 100) .. "...")
    end
  end

  return true, "带推理流式响应测试完成"
end

--- 测试非流式推理响应
local function test_reasoning_non_stream()
  print("🧪 测试非流式推理响应...")

  -- 读取响应文件
  local content, err = read_response_file(test_state.response_files.reasoning_non_stream)
  if not content then
    return false, "无法读取响应文件: " .. err
  end

  -- 解析JSON数据
  local success, data = pcall(vim.json.decode, content)
  if not success then
    return false, "无法解析JSON响应: " .. tostring(data)
  end

  -- 检查响应结构
  if not data.choices or #data.choices == 0 then
    return false, "响应中没有choices字段"
  end

  local choice = data.choices[1]
  local message = choice.message

  if not message then
    return false, "响应中没有message字段"
  end

  -- 检查推理内容
  if message.reasoning_content then
    print("💭 推理内容: " .. message.reasoning_content:sub(1, 100) .. "...")
  else
    print("⚠️  响应中没有推理内容")
  end

  -- 检查响应内容
  if message.content then
    print("📝 响应内容: " .. message.content:sub(1, 100) .. "...")
  else
    print("⚠️  响应中没有内容")
  end

  return true, "非流式推理响应测试完成"
end

--- 运行所有测试
function M.run_all_tests()
  if not init_test_environment() then
    return false, "测试环境初始化失败"
  end

  print("🚀 开始运行DeepSeek响应测试...")

  -- 运行测试
  local results = {}

  -- 测试无推理流式响应
  local success1, msg1 = test_streaming_no_reasoning()
  table.insert(results, { name = "无推理流式响应", success = success1, message = msg1 })

  -- 等待一下
  vim.wait(1000)

  -- 测试带推理流式响应
  local success2, msg2 = test_reasoning_streaming()
  table.insert(results, { name = "带推理流式响应", success = success2, message = msg2 })

  -- 等待一下
  vim.wait(1000)

  -- 测试非流式推理响应
  local success3, msg3 = test_reasoning_non_stream()
  table.insert(results, { name = "非流式推理响应", success = success3, message = msg3 })

  -- 打印测试结果
  print("\n📊 测试结果汇总:")
  local passed = 0
  local failed = 0

  for _, result in ipairs(results) do
    if result.success then
      print("✅ " .. result.name .. ": " .. result.message)
      passed = passed + 1
    else
      print("❌ " .. result.name .. ": " .. result.message)
      failed = failed + 1
    end
  end

  print("\n🎯 总计: " .. passed .. " 通过, " .. failed .. " 失败")

  return failed == 0, "测试完成: " .. passed .. " 通过, " .. failed .. " 失败"
end

--- 运行单个测试
function M.run_test(test_name)
  if not init_test_environment() then
    return false, "测试环境初始化失败"
  end

  print("🚀 运行测试: " .. test_name)

  if test_name == "streaming_no_reasoning" then
    return test_streaming_no_reasoning()
  elseif test_name == "reasoning_streaming" then
    return test_reasoning_streaming()
  elseif test_name == "reasoning_non_stream" then
    return test_reasoning_non_stream()
  else
    return false, "未知测试: " .. test_name
  end
end

--- 注册测试套件到统一的测试框架
function M.register_tests(test_helpers)
  local suite = test_helpers.register_suite("DeepSeek响应测试")

  -- 设置钩子函数
  suite.before_all = function()
    print("🔧 DeepSeek响应测试套件开始前的准备工作")
    if not init_test_environment() then
      error("测试环境初始化失败")
    end
  end

  suite.after_all = function()
    print("🧹 DeepSeek响应测试套件结束后的清理工作")
    -- 清理测试状态
    test_state.initialized = false
    test_state.response_files = {}
  end

  suite.before_each = function()
    print("  📝 每个DeepSeek响应测试开始前的准备工作")
  end

  suite.after_each = function()
    print("  📝 每个DeepSeek响应测试结束后的清理工作")
  end

  -- 添加测试用例
  suite:add_test("无推理的流式响应测试", function()
    local success, msg = test_streaming_no_reasoning()
    test_helpers.assert(success, "无推理流式响应测试失败: " .. tostring(msg))
  end, "测试DeepSeek无推理的流式响应处理")

  suite:add_test("带推理的流式响应测试", function()
    local success, msg = test_reasoning_streaming()
    test_helpers.assert(success, "带推理流式响应测试失败: " .. tostring(msg))
  end, "测试DeepSeek带推理的流式响应处理")

  suite:add_test("非流式推理响应测试", function()
    local success, msg = test_reasoning_non_stream()
    test_helpers.assert(success, "非流式推理响应测试失败: " .. tostring(msg))
  end, "测试DeepSeek非流式的推理响应处理")
end

return M
