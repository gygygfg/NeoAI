# NeoAI 测试指南（v3.0）

> NeoAI 采用**轻量自定义测试框架**（`lua/NeoAI/tests/init.lua`，无外部依赖）。
> 以 `suite` / `it` 组织用例，`t.<断言>` 断言，`:NeoAITest` 运行。
> 配合 Mock 对 HTTP、模型、文件系统等做隔离单元/集成测试。

## 1. 运行

```vim
:NeoAITest          " 运行全部套件
:NeoAITest flow_tools  " 运行指定套件（按名字）
```

headless 运行：

```bash
nvim --headless "+lua require('NeoAI.tests').run_all()" +q
```

## 2. 测试组织

```lua
local tests = require("NeoAI.tests")

tests.suite("flow_config", function(describe, it, before_each)
  before_each(function()
    require("NeoAI.kernel.config_store").reset()
  end)

  it("merge user overrides default", function(t)
    local cs = require("NeoAI.kernel.config_store")
    cs.load({ ai = { default_provider = "openai" } })
    t.eq(cs.get("ai.default_provider"), "openai")
  end)

  it("reads dotted path", function(t)
    local cs = require("NeoAI.kernel.config_store")
    cs.load({})
    t.eq(cs.get("ui.window.width"), 80)
  end)
end)
```

## 3. 断言辅助

用例回调收到 `t`（断言辅助表）：

| 断言 | 说明 |
| --- | --- |
| `t.eq(a, b)` | 相等 |
| `t.ne(a, b)` / `t.not_eq(a, b)` | 不等 |
| `t.true_(v)` / `t.false_(v)` | 真假 |
| `t.nil_(v)` / `t.not_nil(v)` | nil / 非 nil |
| `t.matches(pattern, v)` | 字符串匹配 |
| `t.ok(v)` | 真值 |
| `t.deep_eq(a, b)` | 深比较 |
| `t.sleep(ms)` | 异步等待（返回 Deferred） |
| `t.throws(fn)` | 捕获错误 |

## 4. Mock 策略

### 4.1 会话/文件隔离

测试运行器自动把会话默认路径重定向到临时目录（`~/.cache/NeoAI-test`），结束后清理并恢复
内存中的真实会话，防止测试污染真实历史。`kernel.*` 与 `core.session.*` 模块提供 `reset()` 方法
（config_store / event_bus / lifecycle / session_store / registry / tool_service 等），便于隔离。

### 4.2 HTTP / AI Mock

对 HTTP 请求做 Mock，模拟 LLM 的流式与非流式响应：

- 需要时覆写 `utils.http` 的请求层，或注入 mock server。
- `test_http.lua` 覆盖 HTTP 客户端；`test_integration.lua` 用 mock server 做集成。

### 4.3 工具 Mock

可直接调用工具定义，或覆写 `registry`（如 `registry.reset()` 后用 `register` 注入 mock 工具）。
`test_tools.lua`、`test_sub_agent_result.lua` 覆盖工具与子 Agent 结果。

### 4.4 事件 / 状态隔离

各模块 `reset()`（`event_bus.clear_all`、`herder.reset`、`chat_service.reset`、`status.reset` 等）
确保测试间无残留订阅/状态。

## 5. 测试覆盖主题

| 文件 | 覆盖 |
| --- | --- |
| `test_kernel` | 内核：配置合并、事件总线、生命周期 |
| `test_session` | 会话对象、JSONL 存储、上下文构建、压缩 |
| `test_tool_result_pruner` | 工具结果裁剪（码点计量、头/标记/尾、图像跳过） |
| `test_agent / test_guard / test_overflow` | Agent 状态机、护栏、溢出恢复、配对安全切分 |
| `test_runtime_context` | 运行时上下文注入 |
| `test_model_registry / test_model_capabilities / test_model_profiles / test_model_metadata` | 模型注册表、能力表、方言、实时元数据 |
| `test_protocol_adapter` | 协议编解码 |
| `test_prompt_cache / test_cache_strategy / test_cache_usage` | 显式缓存、前缀缓存策略、缓存命中用量 |
| `test_model_picker` | 模型选择器 |
| `test_modes` | 模式（CHAT/PLAN/AUTO） |
| `test_multimodal` | 多模态图像 |
| `test_tools / test_tool_pending` | 工具执行、工具待发/暂存 |
| `test_max_tokens / test_truncation` | max_tokens 发送策略、输出截断续写 |
| `test_sub_agent_result` | 子 Agent 结果 |
| `test_pending_queue` | 待发消息队列 |
| `test_services / test_status` | 服务层（chat/tool/model/status）、状态栏 |
| `test_ask_user / test_herder` | 提问、Herder 上报 |
| `test_plan_mode / test_plan_distill / test_todo` | 计划模式、计划蒸馏、待办 |
| `test_skills` | Skills（frontmatter/发现/装载） |
| `test_mcp_client / test_mcp_transport / test_mcp_bridge` | MCP 客户端、传输层、桥接 |
| `test_chat_ui / test_tree_ui / test_chat_keys` | 聊天/树 UI、聊天键位 |
| `test_display_modes / test_fold / test_markdown` | 显示模式、折叠、Markdown |
| `test_timer / test_http / test_integration` | 可暂停计时器、HTTP 客户端、集成（mock server） |

## 6. 相关文档

- [threaded_testing.md](threaded_testing.md)：测试框架结构与运行器。
- [utils.md](utils.md)：`utils.async`（Deferred/sleep 等用于测试）。
