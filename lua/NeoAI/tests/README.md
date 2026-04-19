# NeoAI 测试框架重构

## 概述

已将测试用的辅助文件都收到主测试 init 文件里，创建了统一的测试辅助模块。

## 主要更改

### 1. 创建了统一的测试辅助模块
- **文件**: `test_helpers.lua`
- **功能**: 整合了所有测试辅助功能，包括：
  - 测试运行器功能（原 `test_runner.lua`）
  - 测试工具函数（原 `test_utils.lua`）
  - Neovim 模拟环境（原 `mock_neovim.lua`）
  - 断言函数集合
  - 测试环境工具
  - 测试套件管理

### 2. 更新了主入口文件
- **文件**: `init.lua`
- **更改**: 
  - 现在加载统一的 `test_helpers` 模块
  - 保留了向后兼容性
  - 增强了 `run_all()` 函数，添加自动注册功能
  - 改进了错误处理

### 3. 更新了示例测试文件
- **文件**: `example_test.lua`
- **更改**: 更新为使用新的统一测试辅助模块

### 4. 创建了验证文件
- **文件**: 
  - `test_integration.lua` - 集成测试套件
  - `verify_framework.lua` - 框架验证脚本

## 新的文件结构

```
tests/
├── init.lua                    # 主入口文件（已更新）
├── test_helpers.lua           # 统一的测试辅助模块（新增）
├── example_test.lua           # 示例测试（已更新）
├── test_integration.lua       # 集成测试（新增）
├── verify_framework.lua       # 框架验证（新增）
├── README.md                  # 本文档（新增）
└── [其他测试文件]             # 其他测试套件文件
```

## 已弃用的文件

以下文件的功能已整合到 `test_helpers.lua` 中：
- `test_runner.lua` - 测试运行器功能
- `test_utils.lua` - 测试工具函数
- `mock_neovim.lua` - Neovim 模拟环境

## 使用方法

### 1. 在 Neovim 中运行测试
```vim
:NeoAITest          " 运行所有测试
:NeoAITestSuite <name>  " 运行特定测试套件
```

### 2. 在命令行中运行测试
```bash
nvim --headless -c "lua require('NeoAI.tests').run_all()" -c "qa!"
```

### 3. 创建新的测试套件
```lua
-- my_test.lua
local M = {}

function M.register_tests(test_helpers)
    local suite = test_helpers.register_suite("我的测试套件")
    
    suite:add_test("测试1", function()
        test_helpers.assert(true, "测试通过")
    end)
    
    suite:add_test("测试2", function()
        test_helpers.assert_equal(1, 1, "相等测试")
    end)
end

return M
```

## 主要功能

### 测试运行器
- 支持测试套件和测试用例管理
- 支持 before/after 钩子函数
- 详细的测试结果报告

### 断言函数
- `assert(condition, message)`
- `assert_equal(actual, expected, message)`
- `assert_not_equal(actual, expected, message)`
- `assert_nil(value, message)`
- `assert_not_nil(value, message)`
- `assert_type(value, expected_type, message)`
- `assert_table_contains(table, key, message)`
- `assert_table_equal(expected, actual, message)`

### 测试工具
- `create_temp_test_dir(prefix)` - 创建临时测试目录
- `create_temp_test_file(dir, filename, content)` - 创建临时测试文件
- `cleanup_temp_dir(dir_path)` - 清理临时目录
- `cleanup_all_test_dirs()` - 清理所有测试目录
- `get_test_config()` - 获取测试配置

### 模拟函数
- `mock_function(original, mock)` - 基础模拟函数
- `mock_function_advanced(func, returns)` - 增强版模拟函数
- `spy_on(obj, method_name)` - 间谍函数

### Neovim 模拟环境
- `setup_mock_neovim()` - 设置模拟环境
- `is_neovim_environment()` - 检测 Neovim 环境

## 向后兼容性

新的框架保持了向后兼容性：
1. 现有的测试套件文件可以继续使用
2. 测试套件注册函数签名不变
3. 主入口 API 保持不变

## 验证

运行以下命令验证新的测试框架：
```bash
cd /root/NeoAI/pack/plugins/start/NeoAI
lua -e "package.path = package.path .. ';/root/NeoAI/pack/plugins/start/NeoAI/lua/?.lua;/root/NeoAI/pack/plugins/start/NeoAI/lua/?/init.lua' require('NeoAI.tests')"
```

## 优势

1. **统一管理**: 所有测试辅助功能集中在一个文件中
2. **易于维护**: 减少文件数量，降低维护成本
3. **功能完整**: 整合了所有必要的测试工具
4. **向后兼容**: 不影响现有测试代码
5. **文档完善**: 提供了详细的使用说明和示例