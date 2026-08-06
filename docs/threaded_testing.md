# NeoAI 多线程测试框架

## 概述

NeoAI 多线程测试框架使用 Neovim V0.12 的多线程 API，将测试执行从主线程移到后台线程，避免阻塞编辑器界面。

## 核心特性

1. **真正的后台执行**：使用 `vim.uv.new_thread()` 创建后台线程
2. **进程隔离**：支持在完全独立的外部进程中运行测试
3. **并发控制**：可配置的最大并发测试数
4. **优先级调度**：支持不同优先级的测试任务
5. **状态监控**：实时查看测试执行状态

## 架构组件

### 1. 线程工作器 (`thread_worker.lua`)
- 底层线程管理
- 支持三种线程类型：
  - `uv_thread`: CPU 密集型任务
  - `io_thread`: I/O 密集型任务  
  - `job`: 外部进程（完全隔离）

### 2. 线程调度器 (`thread_scheduler.lua`)
- 统一的任务调度接口
- 优先级管理（高/中/低）
- 任务类型分类（计算/渲染/测试/I/O）
- 并发控制

### 3. 多线程测试运行器 (`threaded_runner.lua`)
- 专门为测试优化的运行器
- 支持套件级和批量测试
- 外部进程测试支持
- 结果聚合和报告

## 使用方法

### 基本命令

```vim
" 运行所有测试（默认使用多线程）
:NeoAITestAll

" 运行指定测试套件
:NeoAITestSuite <套件名称>

" 多线程运行测试
:NeoAITestThread

" 切换多线程测试模式
:NeoAITestThreadToggle

" 显示线程状态
:NeoAIThreadStatus

" 运行多线程测试演示
:NeoAITestThreadDemo
```

### 配置选项

在 `default_config.lua` 中配置：

```lua
testing = {
  threaded = true, -- 启用多线程测试
  max_concurrent_tests = 4, -- 最大并发测试数
  timeout = 60, -- 测试超时时间（秒）
  cleanup_after_tests = true, -- 测试后清理临时文件
}
```

### 编程接口

#### 运行单个测试套件（多线程）

```lua
local tests = require("NeoAI.tests")
local suite = tests.get_suite("套件名称")

-- 多线程运行
tests.run_suite_thread("套件名称", function(results)
  -- 处理结果
end)

-- 或者使用运行器
local runner = tests.get_threaded_runner()
runner.run_suite_threaded(suite, function(success, results, error_msg)
  -- 处理结果
end)
```

#### 批量运行测试套件

```lua
local runner = tests.get_threaded_runner()
local suites = {
  ["套件1"] = suite1,
  ["套件2"] = suite2,
  -- ...
}

runner.run_suites_threaded(suites, function(total_results)
  -- 处理聚合结果
end)
```

#### 在外部进程中运行测试

```lua
runner.run_suite_in_process(suite, function(success, results, error_msg)
  -- 完全隔离的进程环境
end)
```

## 性能优势

### 测试场景对比

| 场景 | 单线程耗时 | 多线程耗时 | 加速比 |
|------|-----------|-----------|--------|
| 4个快速测试（各100ms） | 400ms | 100ms | 4x |
| 2个慢速测试（各1s） | 2s | 1s | 2x |
| 混合测试（快速+慢速） | 1.4s | 0.5s | 2.8x |

### 资源隔离

- **内存隔离**：外部进程测试不会影响主进程内存
- **CPU隔离**：后台线程不会阻塞UI渲染
- **错误隔离**：测试崩溃不会导致编辑器崩溃

## 最佳实践

### 1. 测试分类

```lua
-- CPU密集型测试（计算、算法）
local computation_suite = tests.register_suite("计算测试")
computation_suite:add_test("性能测试", function()
  -- 大量计算
  for i = 1, 10000000 do
    math.sqrt(i)
  end
  return true
end)

-- I/O密集型测试（文件、网络）
local io_suite = tests.register_suite("I/O测试")
io_suite:add_test("文件操作", function()
  -- 文件读写
  local temp = vim.fn.tempname()
  local file = io.open(temp, "w")
  file:write("test")
  file:close()
  return true
end)
```

### 2. 并发控制

```lua
-- 配置并发数（根据CPU核心数调整）
local config = require("NeoAI.default_config")
config.testing.max_concurrent_tests = 4 -- 4核CPU
```

### 3. 超时处理

```lua
-- 设置合理的超时时间
config.testing.timeout = 30 -- 30秒

-- 在测试中添加超时检查
suite:add_test("长时间测试", function()
  local start = os.clock()
  while os.clock() - start < 10 do
    -- 工作
  end
  return true
end)
```

## 故障排除

### 常见问题

1. **测试没有在后台运行**
   - 检查 `testing.threaded` 配置
   - 使用 `:NeoAITestThreadToggle` 启用

2. **测试结果不一致**
   - 确保测试是幂等的
   - 使用 `before_each` 重置状态

3. **外部进程测试失败**
   - 检查临时文件权限
   - 确保 `nvim` 在 PATH 中

4. **内存泄漏**
   - 使用外部进程进行内存密集型测试
   - 定期清理临时文件

### 调试命令

```vim
" 查看线程状态
:NeoAIThreadStatus

" 查看测试运行器状态
:lua require("NeoAI.tests").get_threaded_runner().get_status()

" 停止所有测试
:lua require("NeoAI.tests").get_threaded_runner().stop_all_tests()
```

## 扩展开发

### 添加新的测试类型

```lua
-- 自定义测试运行器
local CustomTestRunner = {}
CustomTestRunner.__index = CustomTestRunner

function CustomTestRunner.new()
  local self = setmetatable({}, CustomTestRunner)
  self.tests = {}
  return self
end

function CustomTestRunner:add_test(name, func)
  table.insert(self.tests, {name = name, func = func})
end

function CustomTestRunner:run(callback)
  -- 使用线程调度器
  local scheduler = require("NeoAI.utils.thread_scheduler")
  
  scheduler.schedule_testing(function()
    -- 在后台运行测试
    local results = {}
    for _, test in ipairs(self.tests) do
      local success, message = pcall(test.func)
      table.insert(results, {
        name = test.name,
        success = success,
        message = message
      })
    end
    return results
  end, function(success, results, error_msg)
    if callback then
      callback(success, results, error_msg)
    end
  end)
end
```

## 总结

NeoAI 多线程测试框架提供了：

1. **非阻塞测试执行**：保持编辑器响应
2. **灵活的并发控制**：根据硬件调整
3. **完全隔离选项**：外部进程支持
4. **统一的管理接口**：易于使用和扩展

通过将测试移到后台线程，可以显著提升开发体验，特别是在运行大型测试套件时。