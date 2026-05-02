--- 测试: core/ai/http_client.lua
--- 测试 HTTP 客户端的初始化、请求构建、状态管理等功能
--- 注意：实际 HTTP 请求测试需要 API key 和网络连接，这里只测试逻辑层
local M = {}

local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_http_client ===")

  return test.run_tests({
    --- 测试 initialize
    test_initialize = function()
      local hc = require("NeoAI.core.ai.http_client")
      hc.initialize({ config = {} })
      -- 幂等初始化
      hc.initialize({ config = {} })
    end,

    --- 测试 get_state
    test_get_state = function()
      local hc = require("NeoAI.core.ai.http_client")
      local state = hc.get_state()
      assert.not_nil(state, "应返回状态")
      assert.not_nil(state.initialized)
      assert.not_nil(state.active_requests_count)
      assert.is_true(state.initialized, "应已初始化")
    end,

    --- 测试 _sanitize_json_body
    test_sanitize_json_body = function()
      local hc = require("NeoAI.core.ai.http_client")

      -- 有效 JSON
      local result = hc._sanitize_json_body('{"key":"value"}')
      assert.equal('{"key":"value"}', result)

      -- 空字符串
      local result2 = hc._sanitize_json_body("")
      assert.equal("", result2)

      -- nil
      local result3 = hc._sanitize_json_body(nil)
      assert.equal(nil, result3)
    end,

    --- 测试 clear_request_dedup
    test_clear_request_dedup = function()
      local hc = require("NeoAI.core.ai.http_client")

      -- nil generation_id
      hc.clear_request_dedup(nil)

      -- 有效 generation_id
      hc.clear_request_dedup("test_gen_1")
    end,

    --- 测试 cancel_all_requests
    test_cancel_all_requests = function()
      local hc = require("NeoAI.core.ai.http_client")
      hc.cancel_all_requests()
      -- 不应崩溃
    end,

    --- 测试 send_request（无 API key 应返回错误）
    test_send_request_no_key = function()
      local hc = require("NeoAI.core.ai.http_client")

      local response, err = hc.send_request({
        request = { model = "test", messages = {} },
        generation_id = "test_gen",
        base_url = "https://test.api.com",
        api_key = "",
        timeout = 5000,
      })

      assert.equal(nil, response, "无 API key 应返回 nil")
      assert.not_nil(err, "应返回错误信息")
    end,

    --- 测试 send_request 无 base_url
    test_send_request_no_url = function()
      local hc = require("NeoAI.core.ai.http_client")

      local response, err = hc.send_request({
        request = { model = "test", messages = {} },
        generation_id = "test_gen",
        base_url = "",
        api_key = "sk-test",
        timeout = 5000,
      })

      assert.equal(nil, response, "无 base_url 应返回 nil")
      assert.not_nil(err, "应返回错误信息")
    end,

    --- 测试 send_request_async（无 API key 应返回错误）
    test_send_request_async_no_key = function()
      local hc = require("NeoAI.core.ai.http_client")

      local called = false
      local request_id = hc.send_request_async({
        request = { model = "test", messages = {} },
        generation_id = "test_gen_async",
        base_url = "https://test.api.com",
        api_key = "",
        timeout = 5000,
      }, function(response, err)
        called = true
        assert.equal(nil, response)
        assert.not_nil(err)
      end)

      vim.wait(500, function() return called end)
    end,

    --- 测试 send_stream_request（无 API key 应返回错误）
    test_send_stream_request_no_key = function()
      local hc = require("NeoAI.core.ai.http_client")

      local request_id, err = hc.send_stream_request({
        request = { model = "test", messages = {}, stream = true },
        generation_id = "test_gen_stream",
        base_url = "https://test.api.com",
        api_key = "",
        timeout = 5000,
      }, function(data) end, function() end, function(err) end)

      assert.equal(nil, request_id)
      assert.not_nil(err)
    end,

    --- 测试 _read_file
    test_read_file = function()
      local hc = require("NeoAI.core.ai.http_client")

      -- 不存在的文件
      local content = hc._read_file("/tmp/nonexistent_http_test_file.txt")
      assert.equal(nil, content)

      -- 存在的文件
      local test_path = "/tmp/neoai_http_test.txt"
      local f = io.open(test_path, "w")
      if f then
        f:write("test content")
        f:close()
      end

      local content2 = hc._read_file(test_path)
      assert.equal("test content", content2)

      os.remove(test_path)
    end,

    --- 测试 cancel_request
    test_cancel_request = function()
      local hc = require("NeoAI.core.ai.http_client")

      -- 取消不存在的请求不应崩溃
      hc.cancel_request("nonexistent_request_id")
    end,

    --- 测试 shutdown
    test_shutdown = function()
      local hc = require("NeoAI.core.ai.http_client")
      hc.shutdown()

      local state = hc.get_state()
      assert.is_false(state.initialized, "shutdown 后应未初始化")

      -- 重新初始化
      hc.initialize({ config = {} })
    end,
  })
end

-- 直接运行
if pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M
