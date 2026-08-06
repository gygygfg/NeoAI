# 测试指南

## 概述

NeoAI 测试体系采用 Lua 测试框架，结合 Mock 机制对各个模块进行单元测试和集成测试。

## 测试策略

| 测试类型 | 覆盖范围 | 工具 |
|---------|---------|------|
| **单元测试** | 单个模块/函数 | Lua 单元测试框架 |
| **集成测试** | 模块间交互 | Mock HTTP + 模拟 AI 响应 |
| **功能测试** | 端到端工作流 | Neovim 测试环境 |
| **Mock 测试** | AI API、文件系统 | 自定义 Mock 函数 |

## Mock 策略

### AI API Mock

对 HTTP 请求进行 Mock，模拟 LLM 的流式和非流式响应：

```lua
-- Mock 配置
local mock_responses = {
    stream = {
        -- 模拟流式文本响应
        { type = "content", content = "Hello" },
        { type = "content", content = " World" },
        { type = "done", reason = "stop" }
    },
    tool_call = {
        -- 模拟工具调用响应
        { type = "tool_call",
          tool_calls = {{
              id = "call_mock",
              function = { name = "read_file", arguments = '{"filepath":"test.txt"}' }
          }}
        },
        { type = "done", reason = "tool_calls" }
    }
}

-- Mock HTTP 请求
function mock_http_request(url, opts)
    if opts.stream then
        -- 返回流式 Mock 数据
        return mock_stream_response(mock_responses.stream)
    else
        -- 返回完整 Mock 响应
        return mock_complete_response(mock_responses.tool_call)
    end
end
```

### 文件系统 Mock

```lua
-- Mock 文件系统操作
local mock_fs = {
    files = {
        ["/test/file.txt"] = "original content"
    },
    read_file = function(path)
        return mock_fs.files[path]
    end,
    write_file = function(path, content)
        mock_fs.files[path] = content
    end,
    file_exists = function(path)
        return mock_fs.files[path] ~= nil
    end
}
```

### Request Handler Mock

```lua
-- Mock RequestHandler
local MockRequestHandler = {}

function MockRequestHandler:new(config)
    return setmetatable({
        _config = config,
        _scenario = "simple_response"
    }, { __index = MockRequestHandler })
end

function MockRequestHandler:send_request(messages, opts)
    if self._scenario == "simple_response" then
        -- 返回简单文本响应
        return { content = "This is a mock response" }
    elseif self._scenario == "tool_call_response" then
        -- 返回带工具调用的响应
        return {
            content = nil,
            tool_calls = {{
                id = "call_1",
                function = { name = "read_file", arguments = '{}' }
            }}
        }
    elseif self._scenario == "error_response" then
        -- 返回错误
        error("API Error: rate limit exceeded")
    end
end
```

## 测试用例结构

### AI 引擎测试

```lua
describe("AIEngine", function()
    before_each(function()
        -- 创建 Mock 配置
        local config = {
            provider = "openai",
            model = "gpt-4",
            api_key = "test-key",
            max_tokens = 100,
            stream = true
        }
        -- 注入 Mock 依赖
        package.loaded["NeoAI.core.ai.request_handler"] = MockRequestHandler
        -- 创建引擎实例
        local Engine = require("NeoAI.core.ai.engine")
        self.engine = Engine:new(config)
    end)

    describe("on_submit()", function()
        it("应该创建新会话并开始生成", function()
            self.engine:on_submit("Hello AI!", {})
            -- 验证会话已创建
            assert.not_nil(self.engine._session_id)
            -- 验证用户消息已添加
            local session = self.engine._sessions[self.engine._session_id]
            assert.equal("user", session.messages[1].role)
            assert.equal("Hello AI!", session.messages[1].content)
        end)
    end)

    describe("prepare_messages()", function()
        it("应该包含系统消息", function()
            -- ...
        end)
    end)

    describe("stop_generation()", function()
        it("应该设置停止标志", function()
            self.engine:stop_generation()
            assert.is_true(self.engine._stop_flag)
        end)
    end)
end)
```

### 历史管理器测试

```lua
describe("HistoryManager", function()
    describe("add_message()", function()
        it("应该按顺序添加消息", function()
            local hm = HistoryManager:new({})
            local sid = hm:create_session()
            hm:add_message(sid, "user", "Hello")
            hm:add_message(sid, "assistant", "Hi there")
            local msgs = hm:get_messages(sid)
            assert.equal(2, #msgs)
            assert.equal("user", msgs[1].role)
            assert.equal("assistant", msgs[2].role)
        end)
    end)

    describe("prune_messages()", function()
        it("应该在超过限制时修剪消息", function()
            -- ...
        end)
    end)
end)
```

### 工具注册表测试

```lua
describe("ToolRegistry", function()
    describe("execute()", function()
        it("应该正确执行注册的工具", function()
            -- ...
        end)
        it("应该处理不存在的工具并返回错误", function()
            -- ...
        end)
        it("应该处理工具参数规范化", function()
            -- ...
        end)
    end)
end)
```

## 运行测试

```bash
# 运行所有测试
make test

# 运行特定测试文件
make test TEST=test_ai_engine

# 运行特定测试用例
make test TEST=test_ai_engine TEST_CASE="should create new session"
```

## Mock 最佳实践

1. **隔离依赖** — 每个测试应 Mock 所有外部依赖
2. **场景覆盖** — 覆盖正常流程、边界条件和错误场景
3. **状态重置** — 每个测试前后重置状态，避免测试间污染
4. **断言清晰** — 明确断言每个测试的预期行为
5. **Mock 验证** — 验证 Mock 是否按预期被调用
