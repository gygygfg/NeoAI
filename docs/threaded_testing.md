# NeoAI 测试框架（v3.0）

> NeoAI 自带**轻量自定义测试框架**（无外部依赖，`:NeoAITest` 运行）。
> 所有测试文件位于 `lua/NeoAI/tests/`。旧版文档中提到的 `thread_worker.lua` /
> `thread_scheduler.lua` / `threaded_runner.lua` 及 `:NeoAITestAll` 命令均**不存在**。
> 对应源码：`lua/NeoAI/tests/init.lua`。

## 1. 运行方式

```vim
:NeoAITest              " 运行全部测试
:NeoAITest flow_tools   " 运行指定套件（按名字）
:NeoAITest test_agent test_herder  " 运行多个套件
```

`run_all(...)` 动态加载 `lua/NeoAI/tests/test_*.lua`（幂等），收集所有 `suite` 并执行。
支持按名字过滤（`requested` 匹配套件名）。

## 2. 测试框架 API（tests/init.lua）

### 2.1 套件定义

```lua
local tests = require("NeoAI.tests")

tests.suite("flow_tools", function(describe, it, before_each)
  before_each(function()
    -- 每个用例前的初始化（可选）
  end)
  it("should ...", function(t)
    t.eq(1, 1)
  end)
end)
```

- `suite(name, fn)`：定义测试套件，`fn(describe, it, before_each)`。
- `it(name, fn)`：定义用例，`fn(t)` 收到断言辅助表 `t`。

### 2.2 断言辅助

`it` 的用例回调参数 `t` 包含全部断言辅助：

| 辅助 | 说明 |
| --- | --- |
| `t.eq(expected, actual, msg?)` | 相等 |
| `t.ne(expected, actual, msg?)` / `t.not_eq(...)` | 不等 |
| `t.true_(value, msg?)` | 为真 |
| `t.false_(value, msg?)` | 为假 |
| `t.nil_(value, msg?)` / `t.not_nil(value, msg?)` | nil / 非 nil |
| `t.matches(pattern, value, msg?)` | 字符串匹配 |
| `t.ok(value, msg?)` | 真值 |
| `t.deep_eq(expected, actual, msg?)` | 深比较（`vim.inspect`） |
| `t.sleep(ms)` | 异步等待（返回 Deferred） |
| `t.throws(fn)` | 捕获错误（返回 ok, err） |

### 2.3 运行器

`run_all(...)` 会：

1. **会话隔离**：把会话默认路径重定向到临时目录（`~/.cache/NeoAI-test`），结束后清理并
   恢复内存中的真实会话，防止测试污染真实历史。
2. 动态加载所有 `test_*.lua`。
3. 用 `xpcall` 逐个运行用例（带 `debug.traceback`），统计 `passed / failed / errors`。
4. 返回 `{ passed, failed, errors }`。

## 3. 测试文件清单

`lua/NeoAI/tests/` 下按模块/特性划分：

| 文件 | 覆盖 |
| --- | --- |
| `test_kernel.lua` | 内核（config_store / event_bus / events / lifecycle） |
| `test_session.lua` | 会话（session / session_store / context_builder / compactor） |
| `test_model_registry.lua` | 模型注册表 |
| `test_agent.lua` | Agent（agent / runtime / guardian） |
| `test_guard.lua` | 工具循环护栏 |
| `test_overflow.lua` | 上下文溢出恢复 |
| `test_tools.lua` | 工具系统 |
| `test_services.lua` | 服务层（chat / tool / model / status） |
| `test_ask_user.lua` | 向用户提问 |
| `test_herder.lua` | Herder 状态上报 |
| `test_plan_mode.lua` | 计划模式 |
| `test_chat_ui.lua` | 聊天 UI |
| `test_tree_ui.lua` | 会话树 UI |
| `test_display_modes.lua` | 显示模式插件 |
| `test_fold.lua` | 折叠 |
| `test_status.lua` | 状态栏服务 |
| `test_multimodal.lua` | 多模态图像 |
| `test_cache_strategy.lua` | 前缀缓存策略 |
| test_chat_keys / test_timer / test_todo / test_sub_agent_result / test_http / test_markdown / test_model_picker | 其它 |

## 4. headless 运行

测试可在 headless 模式运行（无需 GUI）：

```bash
nvim --headless "+lua require('NeoAI.tests').run_all()" +q
```

> 具体集成脚本见 `lua/NeoAI/tests/nvim_test.py` 与 `lua/NeoAI/tests/nvim/*.yaml`（若存在）。

## 5. 相关文档

- [testing.md](testing.md)：测试方法与断言。
- [threaded_testing 说明]：本框架为轻量单线程运行器，**没有**多线程测试组件。
