# NeoAI UI 多线程优化文档

## 概述

本优化将所有UI模块中的CPU密集型计算移到多线程中执行，通过异步回调将结果传回主线程更新UI，避免了主线程阻塞，提升了Neovim的响应性。

## 修改的模块

### 1. `ui/components/history_tree.lua`
- 添加了 `_load_tree_data_async(session_id, callback)` 方法
- 添加了 `build_tree_async(session_id, callback)` 方法  
- 添加了 `refresh_async(session_id, callback)` 方法

### 2. `ui/components/reasoning_display.lua`
- 添加了 `_convert_to_folded_text_async(reasoning_text, callback)` 方法

### 3. `ui/window/chat_window.lua`
- 添加了 `_load_messages_async(session_id, callback)` 方法
- 添加了 `open_async(session_id, window_id, callback)` 方法
- 已有 `render_chat_async(callback)` 方法

### 4. `ui/window/tree_window.lua`
- 添加了 `_load_tree_data_async(session_id, callback)` 方法
- 添加了 `render_tree_async(tree_data, callback)` 方法
- 添加了 `open_async(session_id, window_id, callback)` 方法
- 添加了 `refresh_tree_async(callback)` 方法

### 5. `ui/window/window_manager.lua`
- 添加了 `render_tree_async(tree_data, state, load_data_func, callback)` 方法
- 添加了 `set_window_content_async(window_id, content, callback)` 方法

## 设计模式

所有异步方法都遵循相同的模式：

```lua
-- 1. 在多线程中执行CPU密集型计算
local thread = vim.uv.new_thread(function()
    local heavy_result = perform_complex_syntax_parsing()

    -- 2. 通过异步回调将结果传回主线程
    vim.schedule(function()
        -- 3. 在主线程中安全地更新UI
        update_syntax_highlighting(heavy_result)
    end)
end)

-- 避免频繁的单个更新
vim.schedule(function()
    multiple_ui_updates_in_one_batch()
end)
```

## 核心原则

### 1. 线程分离
- **CPU密集型计算**：在 `vim.uv.new_thread` 中执行
- **UI更新**：通过 `vim.schedule` 在主线程中执行
- **数据传递**：通过回调函数传递结果

### 2. 批量更新
- 使用 `vim.schedule` 包装多个UI更新操作
- 避免频繁的单个UI更新调用
- 减少主线程的调度开销

### 3. 错误处理
- 所有异步方法都支持回调函数
- 回调函数接收 `(success, result, error_message)` 参数
- 提供友好的错误信息

## 使用示例

### 异步构建历史树
```lua
local history_tree = require("NeoAI.ui.components.history_tree")
history_tree.build_tree_async("session_id", function(tree_data)
    print("异步构建完成，节点数: " .. #tree_data)
end)
```

### 异步打开聊天窗口
```lua
local chat_window = require("NeoAI.ui.window.chat_window")
chat_window.open_async("session_id", "win_123", function(success, message)
    if success then
        print("聊天窗口已异步打开")
    else
        print("打开失败: " .. message)
    end
end)
```

### 异步渲染树窗口
```lua
local tree_window = require("NeoAI.ui.window.tree_window")
tree_window.render_tree_async(tree_data, function(success, result)
    if success then
        print("树状图异步渲染完成")
    end
end)
```

## 性能优势

### 1. 响应性提升
- 主线程不再被CPU密集型计算阻塞
- UI保持流畅响应
- 用户可以继续编辑和操作

### 2. 并行处理
- 多个异步操作可以并行执行
- 充分利用多核CPU
- 减少总体等待时间

### 3. 内存优化
- 大数据处理在后台线程进行
- 主线程内存压力减小
- 避免大型数据结构在主线程中构建

## 测试和验证

### 测试文件
- `examples/ui_multithread_example.lua` - 完整的使用示例
- `tests/ui_multithread_test.lua` - 自动化测试

### 运行测试
```lua
-- 运行示例
:lua require('NeoAI.examples.ui_multithread_example').run_all_demos()

-- 运行测试
:lua require('NeoAI.tests.ui_multithread_test').run_all_tests()
```

## 向后兼容性

### 保持同步方法
- 所有原有的同步方法保持不变
- 新增的异步方法以 `_async` 后缀命名
- 开发者可以逐步迁移到异步版本

### 回调函数设计
- 回调函数参数一致：`(success, result, error_message)`
- 支持可选的回调函数参数
- 提供默认的错误处理

## 最佳实践

### 1. 何时使用异步
- **大数据处理**：处理大量历史记录、消息、树节点
- **复杂计算**：语法分析、文本转换、数据格式化
- **网络请求**：API调用、文件读取、数据库查询

### 2. 何时使用同步
- **简单操作**：状态切换、配置更新、简单查询
- **即时反馈**：需要立即响应的用户操作
- **小数据量**：处理少量数据的操作

### 3. 错误处理
```lua
module.async_method(params, function(success, result, error)
    if success then
        -- 处理成功结果
        process_result(result)
    else
        -- 处理错误
        vim.notify("操作失败: " .. error, vim.log.levels.ERROR)
    end
end)
```

## 总结

本次优化为NeoAI的所有UI模块添加了多线程支持，显著提升了应用的响应性和性能。通过将CPU密集型计算移到后台线程，并使用异步回调更新UI，确保了Neovim主线程的流畅性。

所有修改都保持了向后兼容性，原有的同步API继续可用，开发者可以根据需要选择使用同步或异步版本。