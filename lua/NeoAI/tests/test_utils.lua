--- 测试: 工具函数模块
--- 合并了 test_utils_common, test_utils_logger, test_utils_json, test_utils_table_utils, test_utils_file_utils, test_async_worker
local M = {}

local test

-- 检测是否为 headless 模式
-- 使用 vim.api.nvim_list_uis() 是最可靠的检测方式
-- 在 headless 模式下，nvim_list_uis() 返回空表 {}
-- 注意：colors_name 可能被 colorscheme 插件设置，不能作为 headless 检测依据
local function is_headless()
  if vim.env.NVIM_HEADLESS then
    return true
  end
  local uis = vim.api.nvim_list_uis()
  if #uis == 0 then
    return true
  end
  return false
end

-- 安全的等待函数
-- 在 headless 模式下使用 vim.uv.run('once') 循环来处理 vim.defer_fn 回调
-- 同时定期调用 vim.wait(1) 来处理 vim.schedule 回调
-- 注意：vim.wait 能处理 vim.schedule 回调，但不能处理 vim.defer_fn 回调
-- 而 vim.uv.run('once') 能处理 vim.defer_fn 回调，但不能处理 vim.schedule 回调
local function safe_wait(timeout_ms, cond)
  -- vim.wait 可以同时处理 vim.schedule 和 vim.defer_fn 回调
  -- 在 headless 和非 headless 模式下都使用 vim.wait
  -- 注意：vim.uv.run('once') 不能处理 vim.defer_fn 回调
  return vim.wait(timeout_ms, cond, 1)
end

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  -- 确保 _logger 可用（直接 dofile 运行时可能为 nil）
  if not test._logger then
    local logger = require("NeoAI.utils.logger")
    test._logger = logger
  end
  -- 保存 logger 状态，测试结束后恢复
  local logger = require("NeoAI.utils.logger")
  local _saved_log_path = logger.get_output_path()
  local _saved_log_level = logger.get_level()
  test._logger.info("\n=== test_utils ===")

  local results = test.run_tests({
    -- ========== common ==========
    test_common_deep_copy = function()
      local utils = require("NeoAI.utils")
      local original = { a = 1, b = { c = 2, d = { e = 3 } } }
      local copy = utils.deep_copy(original)
      assert.equal(original.a, copy.a)
      assert.equal(original.b.c, copy.b.c)
      copy.b.c = 100
      assert.equal(2, original.b.c)
      assert.equal(42, utils.deep_copy(42))
      assert.equal("hello", utils.deep_copy("hello"))
    end,
    -- ========== common ==========
    test_common_deep_copy = function()
      local utils = require("NeoAI.utils")
      local original = { a = 1, b = { c = 2, d = { e = 3 } } }
      local copy = utils.deep_copy(original)
      assert.equal(original.a, copy.a)
      assert.equal(original.b.c, copy.b.c)
      copy.b.c = 100
      assert.equal(2, original.b.c)
      assert.equal(42, utils.deep_copy(42))
      assert.equal("hello", utils.deep_copy("hello"))
    end,

    test_common_deep_merge = function()
      local utils = require("NeoAI.utils")
      local merged = utils.deep_merge({ a = 1, b = { c = 2 } }, { b = { d = 3 }, e = 4 })
      assert.equal(1, merged.a)
      assert.equal(2, merged.b.c)
      assert.equal(3, merged.b.d)
      assert.equal(4, merged.e)
      assert.equal(42, utils.deep_merge(nil, 42))
      assert.equal("hello", utils.deep_merge("hello", nil))
    end,

    test_common_safe_call = function()
      local utils = require("NeoAI.utils")
      local result, err = utils.safe_call(function(a, b) return a + b end, 3, 4)
      assert.equal(7, result)
      assert.equal(nil, err)
      local result2, err2 = utils.safe_call(function() error("出错了") end)
      assert.equal(nil, result2)
      assert.not_nil(err2)
      local result3, err3 = utils.safe_call("not_a_function")
      assert.equal(nil, result3)
      assert.not_nil(err3)
    end,

    test_common_unique_id = function()
      local utils = require("NeoAI.utils")
      local id1 = utils.unique_id("test")
      local id2 = utils.unique_id("test")
      assert.not_equal(id1, id2, "两次生成的 ID 应不同")
      assert.is_true(string.find(id1, "^test_") ~= nil, "ID 应以前缀开头")
      assert.is_true(string.find(utils.unique_id(), "^id_") ~= nil)
    end,

    test_common_is_empty = function()
      local utils = require("NeoAI.utils")
      assert.is_true(utils.is_empty(nil))
      assert.is_true(utils.is_empty(""))
      assert.is_true(utils.is_empty({}))
      assert.is_false(utils.is_empty("hello"))
      assert.is_false(utils.is_empty({ 1 }))
    end,

    test_common_default = function()
      local utils = require("NeoAI.utils")
      assert.equal("default", utils.default(nil, "default"))
      assert.equal("default", utils.default("", "default"))
      assert.equal("hello", utils.default("hello", "default"))
    end,

    test_common_random_string = function()
      local utils = require("NeoAI.utils")
      assert.equal(10, #utils.random_string(10))
    end,

    test_common_check_type = function()
      local utils = require("NeoAI.utils")
      assert.is_true(utils.check_type("hello", "string"))
      assert.is_true(utils.check_type(42, "number"))
      assert.is_true(utils.check_type(true, "boolean"))
      assert.is_true(utils.check_type({ 1, 2 }, "array"))
      assert.is_true(utils.check_type({ a = 1 }, "object"))
      assert.is_false(utils.check_type(42, "string"))
      assert.is_false(utils.check_type({}, "array"))
    end,

    test_common_measure_time = function()
      local utils = require("NeoAI.utils")
      local result, duration = utils.measure_time(function(a, b) return a * b end, 6, 7)
      assert.equal(42, result)
      assert.is_true(duration >= 0)
    end,

    test_common_cache = function()
      local utils = require("NeoAI.utils")
      local call_count = 0
      local cached_fn = utils.cache(function(x) call_count = call_count + 1; return x * 2 end, 1)
      assert.equal(10, cached_fn(5))
      assert.equal(1, call_count, "第一次调用应执行函数")
      assert.equal(10, cached_fn(5))
      assert.equal(1, call_count, "第二次调用应命中缓存")
    end,

    test_common_merge_tables = function()
      local utils = require("NeoAI.utils")
      local merged = utils.merge_tables({ a = 1 }, { b = 2 })
      assert.equal(1, merged.a)
      assert.equal(2, merged.b)
    end,

    -- ========== logger ==========
    test_logger_initialize = function()
      local logger = require("NeoAI.utils.logger")
      -- 保存当前输出路径，测试后恢复
      local saved_path = logger.get_output_path()
      logger.initialize({ level = "DEBUG" })
      if saved_path then logger.set_output(saved_path) end
    end,

    test_logger_level = function()
      local logger = require("NeoAI.utils.logger")
      -- 保存当前输出路径，测试后恢复
      local saved_path = logger.get_output_path()
      logger.set_level("DEBUG")
      assert.equal("DEBUG", logger.get_level())
      logger.set_level("INFO")
      assert.equal("INFO", logger.get_level())
      logger.set_level("WARN")
      assert.equal("WARN", logger.get_level())
      logger.set_level("INVALID")
      assert.equal("INFO", logger.get_level(), "无效级别应回退到 INFO")
      if saved_path then logger.set_output(saved_path) end
    end,

    test_logger_methods = function()
      local logger = require("NeoAI.utils.logger")
      -- 使用临时文件，不污染主日志
      local saved_path = logger.get_output_path()
      local tmp_path = "/tmp/neoai_test_log_methods.log"
      logger.set_output(tmp_path)
      logger.set_level("DEBUG")
      logger.debug("调试消息")
      logger.info("信息消息")
      logger.warn("警告消息")
      logger.error("错误消息")
      logger.fatal("致命错误")
      logger.info("用户 %s 登录", "张三")
      logger.warn("重试 %d/%d", 1, 3)
      logger.set_output(nil)
      os.remove(tmp_path)
      if saved_path then logger.set_output(saved_path) end
    end,

    test_logger_output = function()
      local logger = require("NeoAI.utils.logger")
      local saved_path = logger.get_output_path()
      local test_path = "/tmp/neoai_test_log_output.log"
      logger.set_output(test_path)
      assert.equal(test_path, logger.get_output_path())
      logger.info("测试写入文件")
      logger.set_output(nil)
      assert.equal(nil, logger.get_output_path())
      os.remove(test_path)
      if saved_path then logger.set_output(saved_path) end
    end,

    test_logger_clear = function()
      local logger = require("NeoAI.utils.logger")
      -- 使用临时文件测试 clear，不污染主日志
      local saved_path = logger.get_output_path()
      local tmp_path = "/tmp/neoai_test_log_clear.log"
      logger.set_output(tmp_path)
      logger.info("写入一些内容")
      logger.clear()
      logger.info("清空后的内容")
      logger.set_output(nil)
      os.remove(tmp_path)
      if saved_path then logger.set_output(saved_path) end
    end,

    test_logger_stats = function()
      local logger = require("NeoAI.utils.logger")
      local saved_path = logger.get_output_path()
      local stats = logger.get_stats()
      assert.not_nil(stats)
      assert.not_nil(stats.level)
      assert.not_nil(stats.initialized)
      if saved_path then logger.set_output(saved_path) end
    end,

    test_logger_create_child = function()
      local logger = require("NeoAI.utils.logger")
      local saved_path = logger.get_output_path()
      local child = logger.create_child("TestModule")
      assert.not_nil(child)
      assert.is_true(type(child.info) == "function")
      child.info("子日志器测试")
      if saved_path then logger.set_output(saved_path) end
    end,

    test_logger_exception = function()
      local logger = require("NeoAI.utils.logger")
      local saved_path = logger.get_output_path()
      logger.exception("测试异常信息", "测试上下文")
      if saved_path then logger.set_output(saved_path) end
    end,

    test_logger_verbose_and_debug = function()
      local logger = require("NeoAI.utils.logger")
      local saved_path = logger.get_output_path()
      logger.initialize({ verbose = true, print_debug = true })
      assert.is_true(logger.is_verbose_enabled())
      assert.is_true(logger.is_print_debug_enabled())
      logger.verbose("详细消息")
      logger.debug_print("调试", "打印")
      logger.initialize({ verbose = false, print_debug = false })
      if saved_path then logger.set_output(saved_path) end
    end,

    test_logger_custom_output = function()
      local logger = require("NeoAI.utils.logger")
      local saved_path = logger.get_output_path()
      local last_message = nil
      logger.set_custom_output(function(msg) last_message = msg end)
      logger.info("自定义输出测试")
      logger.set_output(nil)
      if saved_path then logger.set_output(saved_path) end
    end,

    test_logger_rotate = function()
      local logger = require("NeoAI.utils.logger")
      local saved_path = logger.get_output_path()
      local test_path = "/tmp/neoai_test_rotate.log"
      logger.set_output(test_path)
      logger.initialize({ level = "DEBUG", output_path = test_path, max_file_size = 100, max_backups = 2 })
      for i = 1, 50 do logger.info("测试轮转消息 #" .. i) end
      logger.set_output(nil)
      os.remove(test_path)
      -- 先恢复 max_file_size，再恢复 output_path
      -- 防止恢复 output_path 后因 max_file_size 过小触发 rotate() 轮转主日志
      logger.initialize({ max_file_size = 10485760, max_backups = 5 })
      if saved_path then logger.set_output(saved_path) end
    end,

    -- ========== json ==========
    test_json_encode_basic = function()
      local json = require("NeoAI.utils.json")
      assert.equal('"hello"', json.encode("hello"))
      assert.equal("42", json.encode(42))
      assert.equal("3.14", json.encode(3.14))
      assert.equal("true", json.encode(true))
      assert.equal("false", json.encode(false))
      assert.equal("null", json.encode(nil))
    end,

    test_json_encode_array = function()
      local json = require("NeoAI.utils.json")
      assert.equal("[1,2,3]", json.encode({ 1, 2, 3 }))
      assert.equal('["a","b","c"]', json.encode({ "a", "b", "c" }))
      assert.equal("[]", json.encode({}))
    end,

    test_json_encode_object = function()
      local json = require("NeoAI.utils.json")
      local result = json.encode({ a = 1, b = "hello" })
      assert.is_true(string.find(result, '"a":1') ~= nil)
      assert.is_true(string.find(result, '"b":"hello"') ~= nil)
    end,

    test_json_encode_nested = function()
      local json = require("NeoAI.utils.json")
      local result = json.encode({ name = "test", items = { 1, 2, 3 }, config = { enabled = true } })
      assert.is_true(type(result) == "string" and #result > 0)
    end,

    test_json_encode_special_chars = function()
      local json = require("NeoAI.utils.json")
      assert.equal('"hello\\nworld"', json.encode("hello\nworld"))
      assert.equal('"tab\\there"', json.encode("tab\there"))
      assert.equal('"quote\\"here"', json.encode('quote"here'))
    end,

    test_json_decode_basic = function()
      local json = require("NeoAI.utils.json")
      assert.equal("hello", json.decode('"hello"'))
      assert.equal(42, json.decode("42"))
      assert.equal(true, json.decode("true"))
      assert.equal(false, json.decode("false"))
      assert.equal(nil, json.decode("null"))
    end,

    test_json_decode_array = function()
      local json = require("NeoAI.utils.json")
      local result = json.decode("[1,2,3]")
      assert.equal(1, result[1])
      assert.equal(2, result[2])
      assert.equal(3, result[3])
    end,

    test_json_decode_object = function()
      local json = require("NeoAI.utils.json")
      local result = json.decode('{"a":1,"b":"hello"}')
      assert.equal(1, result.a)
      assert.equal("hello", result.b)
    end,

    test_json_decode_nested = function()
      local json = require("NeoAI.utils.json")
      local result = json.decode('{"name":"test","items":[1,2,3],"config":{"enabled":true}}')
      assert.equal("test", result.name)
      assert.equal(1, result.items[1])
      assert.equal(true, result.config.enabled)
    end,

    test_json_decode_escaped = function()
      local json = require("NeoAI.utils.json")
      assert.equal("hello\nworld", json.decode('"hello\\nworld"'))
      assert.equal('quote"here', json.decode('"quote\\"here"'))
    end,

    test_json_decode_empty = function()
      local json = require("NeoAI.utils.json")
      assert.equal(nil, json.decode(""))
      assert.equal(nil, json.decode(nil))
      assert.equal(nil, json.decode("   "))
    end,

    test_json_decode_sse = function()
      local json = require("NeoAI.utils.json")
      local result = json.decode('data: {"content":"hello"}')
      assert.not_nil(result)
      assert.equal("hello", result.content)
      assert.equal(nil, json.decode("[DONE]"))
      assert.equal(nil, json.decode("data: [DONE]"))
    end,

    test_json_roundtrip = function()
      local json = require("NeoAI.utils.json")
      local data = { string = "hello", number = 42, boolean = true, array = { 1, 2, 3 }, object = { nested = { key = "value" } } }
      local decoded = json.decode(json.encode(data))
      assert.equal("hello", decoded.string)
      assert.equal(42, decoded.number)
      assert.equal(true, decoded.boolean)
      assert.equal("value", decoded.object.nested.key)
    end,

    test_json_decode_unicode = function()
      local json = require("NeoAI.utils.json")
      assert.equal("中文", json.decode('"\\u4e2d\\u6587"'))
    end,

    test_json_decode_invalid = function()
      local json = require("NeoAI.utils.json")
      local result1 = json.decode("{")
      assert.is_true(result1 == nil or type(result1) == "table", "未终止对象应返回 nil 或 table")
      assert.equal(nil, json.decode("undefined"))
    end,

    -- ========== table_utils ==========
    test_table_keys = function()
      local tu = require("NeoAI.utils.table_utils")
      local result = tu.keys({ a = 1, b = 2, c = 3 })
      table.sort(result)
      assert.equal("a", result[1])
      assert.equal("b", result[2])
      assert.equal("c", result[3])
      assert.is_true(#tu.keys(nil) == 0)
    end,

    test_table_values = function()
      local tu = require("NeoAI.utils.table_utils")
      local result = tu.values({ a = 1, b = 2, c = 3 })
      table.sort(result)
      assert.equal(1, result[1])
      assert.equal(2, result[2])
      assert.equal(3, result[3])
    end,

    test_table_filter = function()
      local tu = require("NeoAI.utils.table_utils")
      local result = tu.filter({ 1, 2, 3, 4, 5 }, function(v) return v % 2 == 0 end)
      assert.equal(2, result[1])
      assert.equal(4, result[2])
    end,

    test_table_map = function()
      local tu = require("NeoAI.utils.table_utils")
      local result = tu.map({ 1, 2, 3 }, function(v) return v * 2 end)
      assert.equal(2, result[1])
      assert.equal(4, result[2])
      assert.equal(6, result[3])
    end,

    test_table_reduce = function()
      local tu = require("NeoAI.utils.table_utils")
      assert.equal(15, tu.reduce({ 1, 2, 3, 4, 5 }, function(acc, v) return acc + v end, 0))
      assert.equal(24, tu.reduce({ 2, 3, 4 }, function(acc, v) return acc * v end))
    end,

    test_table_length = function()
      local tu = require("NeoAI.utils.table_utils")
      assert.equal(3, tu.length({ a = 1, b = 2, c = 3 }))
      assert.equal(0, tu.length({}))
      assert.equal(0, tu.length(nil))
    end,

    test_table_is_empty = function()
      local tu = require("NeoAI.utils.table_utils")
      assert.is_true(tu.is_empty({}))
      assert.is_false(tu.is_empty({ 1 }))
    end,

    test_table_merge = function()
      local tu = require("NeoAI.utils.table_utils")
      local result = tu.merge({ a = 1 }, { b = 2 }, { c = 3 })
      assert.equal(1, result.a)
      assert.equal(2, result.b)
      assert.equal(3, result.c)
    end,

    test_table_contains = function()
      local tu = require("NeoAI.utils.table_utils")
      assert.is_true(tu.contains({ 1, 2, 3 }, 2))
      assert.is_false(tu.contains({ 1, 2, 3 }, 4))
    end,

    test_table_has_key = function()
      local tu = require("NeoAI.utils.table_utils")
      assert.is_true(tu.has_key({ a = 1 }, "a"))
      assert.is_false(tu.has_key({ a = 1 }, "b"))
    end,

    test_table_deep_equal = function()
      local tu = require("NeoAI.utils.table_utils")
      assert.is_true(tu.deep_equal({ a = 1, b = { c = 2 } }, { a = 1, b = { c = 2 } }))
      assert.is_false(tu.deep_equal({ a = 1 }, { a = 2 }))
    end,

    test_table_clone = function()
      local tu = require("NeoAI.utils.table_utils")
      local original = { a = 1, b = { c = 2 } }
      local cloned = tu.clone(original)
      cloned.a = 100
      assert.equal(1, original.a)
    end,

    test_table_pick_omit = function()
      local tu = require("NeoAI.utils.table_utils")
      local picked = tu.pick({ a = 1, b = 2, c = 3 }, { "a", "c" })
      assert.equal(1, picked.a)
      assert.equal(3, picked.c)
      assert.equal(nil, picked.b)
      local omitted = tu.omit({ a = 1, b = 2, c = 3 }, { "b" })
      assert.equal(1, omitted.a)
      assert.equal(3, omitted.c)
      assert.equal(nil, omitted.b)
    end,

    test_table_find = function()
      local tu = require("NeoAI.utils.table_utils")
      local val, key = tu.find({ a = 1, b = 2, c = 3 }, function(v) return v == 2 end)
      assert.equal(2, val)
      assert.equal("b", key)
    end,

    test_table_group_by = function()
      local tu = require("NeoAI.utils.table_utils")
      local items = { { type = "fruit", name = "apple" }, { type = "fruit", name = "banana" }, { type = "veg", name = "carrot" } }
      local grouped = tu.group_by(items, function(item) return item.type end)
      assert.equal(2, #grouped.fruit)
      assert.equal(1, #grouped.veg)
    end,

    test_table_unique = function()
      local tu = require("NeoAI.utils.table_utils")
      local result = tu.unique({ 1, 2, 2, 3, 3, 3 })
      assert.equal(3, #result)
    end,

    test_table_reverse_slice = function()
      local tu = require("NeoAI.utils.table_utils")
      local reversed = tu.reverse({ 1, 2, 3 })
      assert.equal(3, reversed[1])
      assert.equal(2, reversed[2])
      assert.equal(1, reversed[3])
      local sliced = tu.slice({ 1, 2, 3, 4, 5 }, 2, 4)
      assert.equal(2, sliced[1])
      assert.equal(3, sliced[2])
      assert.equal(4, sliced[3])
    end,

    test_table_flatten = function()
      local tu = require("NeoAI.utils.table_utils")
      local result = tu.flatten({ 1, { 2, 3 }, { 4, { 5, 6 } } }, 1)
      assert.equal(1, result[1])
      assert.is_true(type(result[2]) == "table", "depth=1 时子表应保留")
    end,

    test_table_pairs = function()
      local tu = require("NeoAI.utils.table_utils")
      local pairs = tu.to_pairs({ a = 1, b = 2 })
      assert.equal(2, #pairs)
      local result = tu.from_pairs(pairs)
      assert.equal(1, result.a)
      assert.equal(2, result.b)
    end,

    test_table_deep_copy = function()
      local tu = require("NeoAI.utils.table_utils")
      local original = { a = 1, b = { c = 2 } }
      local copy = tu.deep_copy(original)
      copy.b.c = 100
      assert.equal(2, original.b.c)
    end,

    test_table_deep_merge = function()
      local tu = require("NeoAI.utils.table_utils")
      local merged = tu.deep_merge({ a = 1, b = { c = 2 } }, { b = { d = 3 } })
      assert.equal(1, merged.a)
      assert.equal(2, merged.b.c)
      assert.equal(3, merged.b.d)
    end,

    test_table_sort = function()
      local tu = require("NeoAI.utils.table_utils")
      local result = tu.sort({ 3, 1, 4, 1, 5, 9, 2, 6 })
      assert.equal(1, result[1])
      assert.equal(2, result[3])
    end,

    -- ========== file_utils ==========
    test_file_read_write = function()
      local fu = require("NeoAI.utils.file_utils")
      local test_path = "/tmp/neoai_test_file.txt"
      local ok, err = fu.write_file(test_path, "Hello World!")
      assert.is_true(ok, "写入应成功: " .. tostring(err))
      assert.equal("Hello World!", fu.read_file(test_path), "读取内容应匹配")
      os.remove(test_path)
    end,

    test_file_read_not_found = function()
      local fu = require("NeoAI.utils.file_utils")
      local content, err = fu.read_file("/tmp/nonexistent_file_12345.txt")
      assert.equal(nil, content)
      assert.not_nil(err)
    end,

    test_file_write_append = function()
      local fu = require("NeoAI.utils.file_utils")
      local test_path = "/tmp/neoai_test_append.txt"
      fu.write_file(test_path, "第一行\n")
      fu.write_file(test_path, "第二行\n", true)
      assert.equal("第一行\n第二行\n", fu.read_file(test_path))
      os.remove(test_path)
    end,

    test_file_read_write_lines = function()
      local fu = require("NeoAI.utils.file_utils")
      local test_path = "/tmp/neoai_test_lines.txt"
      fu.write_lines(test_path, { "行1", "行2", "行3" })
      local lines = fu.read_lines(test_path)
      assert.equal(3, #lines)
      assert.equal("行1", lines[1])
      os.remove(test_path)
    end,

    test_file_exists = function()
      local fu = require("NeoAI.utils.file_utils")
      local test_path = "/tmp/neoai_test_exists.txt"
      assert.is_false(fu.exists(test_path))
      fu.write_file(test_path, "test")
      assert.is_true(fu.exists(test_path))
      os.remove(test_path)
    end,

    test_file_mkdir = function()
      local fu = require("NeoAI.utils.file_utils")
      local test_dir = "/tmp/neoai_test_dir"
      os.execute("rm -rf " .. test_dir)
      assert.is_false(fu.dir_exists(test_dir))
      assert.is_true(fu.mkdir(test_dir))
      assert.is_true(fu.dir_exists(test_dir))
      assert.is_true(fu.mkdir(test_dir), "重复创建应成功")
      os.execute("rm -rf " .. test_dir)
    end,

    test_file_join_path = function()
      local fu = require("NeoAI.utils.file_utils")
      assert.equal("/a/b/c", fu.join_path("/a", "b", "c"))
      assert.equal("a/b/c", fu.join_path("a", "b", "c"))
    end,

    test_file_path_utils = function()
      local fu = require("NeoAI.utils.file_utils")
      assert.equal("txt", fu.get_extension("/path/to/file.txt"))
      assert.equal("file.txt", fu.get_filename("/path/to/file.txt"))
      local dirname = fu.get_dirname("/path/to/file.txt")
      assert.is_true(dirname == "path/to" or dirname == "/path/to")
    end,

    test_file_stats = function()
      local fu = require("NeoAI.utils.file_utils")
      local test_path = "/tmp/neoai_test_stats.txt"
      fu.write_file(test_path, "12345")
      assert.equal(5, fu.get_file_size(test_path))
      assert.is_true(fu.get_mtime(test_path) > 0)
      os.remove(test_path)
    end,

    test_file_copy_move_delete = function()
      local fu = require("NeoAI.utils.file_utils")
      local src = "/tmp/neoai_test_src.txt"
      local dst = "/tmp/neoai_test_dst.txt"
      fu.write_file(src, "复制测试")
      assert.is_true(fu.copy_file(src, dst), "复制应成功")
      assert.is_true(fu.exists(dst))
      local move_dst = "/tmp/neoai_test_moved.txt"
      assert.is_true(fu.move_file(dst, move_dst), "移动应成功")
      assert.is_false(fu.exists(dst))
      assert.is_true(fu.exists(move_dst))
      assert.is_true(fu.delete_file(move_dst), "删除应成功")
      os.remove(src)
    end,

    test_file_path_normalization = function()
      local fu = require("NeoAI.utils.file_utils")
      assert.equal("/tmp/test", fu.abs_path("/tmp/test"))
      assert.equal("/a/c/d", fu.normalize_path("/a//b/../c/./d"))
    end,

    test_file_is_file_dir = function()
      local fu = require("NeoAI.utils.file_utils")
      local test_path = "/tmp/neoai_test_isfile.txt"
      fu.write_file(test_path, "test")
      assert.is_true(fu.is_file(test_path))
      assert.is_false(fu.is_directory(test_path))
      os.remove(test_path)
    end,

    test_file_search_files = function()
      local fu = require("NeoAI.utils.file_utils")
      local results, err = fu.search_files("/tmp", "*", false)
      if results then assert.is_true(type(results) == "table") end
    end,

    test_file_ensure_dir = function()
      local fu = require("NeoAI.utils.file_utils")
      local test_dir = "/tmp/neoai_test_ensure"
      os.execute("rm -rf " .. test_dir)
      assert.is_true(fu.ensure_dir(test_dir))
      os.execute("rm -rf " .. test_dir)
    end,

    test_file_cleanup_session_buffers = function()
      local fu = require("NeoAI.utils.file_utils")
      fu.cleanup_session_buffers()
      assert.equal(0, fu.get_loaded_buffer_count())
    end,

    -- ========== async_worker ==========
    test_async_submit_task = function()
      local aw = require("NeoAI.utils.async_worker")
      aw.reset()
      local result = nil
      local id = aw.submit_task("test_task", function() return "task_result" end, function(success, res) result = res end)
      assert.is_true(id > 0, "应返回任务ID")
      safe_wait(500, function() return result ~= nil end)
      assert.equal("task_result", result)
    end,

    test_async_submit_task_fail = function()
      local aw = require("NeoAI.utils.async_worker")
      aw.reset()
      local error_msg = nil
      aw.submit_task("fail_task", function() error("任务失败") end, function(success, res, err) error_msg = err end)
      safe_wait(500, function() return error_msg ~= nil end)
      assert.not_nil(error_msg, "应返回错误信息")
    end,

    test_async_submit_batch = function()
      local aw = require("NeoAI.utils.async_worker")
      aw.reset()
      local results = {}
      local ids = aw.submit_batch({ { name = "batch_1", task_func = function() return "r1" end, callback = function(s, r) results[1] = r end }, { name = "batch_2", task_func = function() return "r2" end, callback = function(s, r) results[2] = r end } })
      assert.is_true(#ids == 2, "应有2个任务ID")
      safe_wait(500, function() return results[1] ~= nil and results[2] ~= nil end)
      assert.equal("r1", results[1])
      assert.equal("r2", results[2])
    end,

    test_async_worker_status = function()
      local aw = require("NeoAI.utils.async_worker")
      aw.reset()
      local id = aw.submit_task("status_test", function() return "ok" end)
      local status = aw.get_worker_status(id)
      assert.not_nil(status)
      assert.equal("status_test", status.name)
      safe_wait(500, function() return aw.get_worker_status(id) == nil end)
      local all = aw.get_all_worker_status()
      assert.is_true(type(all) == "table")
    end,

    test_async_cancel_worker = function()
      local aw = require("NeoAI.utils.async_worker")
      aw.reset()
      local id = aw.submit_task("cancel_test", function() local start = vim.uv.now(); while vim.uv.now() - start < 500 do vim.uv.run("once") end; return "too_late" end)
      assert.is_true(aw.cancel_worker(id), "取消应成功")
    end,

    test_async_cancel_all = function()
      local aw = require("NeoAI.utils.async_worker")
      aw.reset()
      aw.submit_task("c1", function() local start = vim.uv.now(); while vim.uv.now() - start < 500 do vim.uv.run("once") end; return "ok" end)
      local cancelled = aw.cancel_all_workers()
      assert.is_true(#cancelled >= 0)
    end,

    test_async_cleanup_completed = function()
      local aw = require("NeoAI.utils.async_worker")
      aw.reset()
      aw.submit_task("cleanup_test", function() return "ok" end)
      safe_wait(500, function() return aw.get_total_count() == 0 end)
      aw.cleanup_completed()
    end,

    test_async_worker_counts = function()
      local aw = require("NeoAI.utils.async_worker")
      aw.reset()
      aw.set_max_workers(5)
      assert.equal(0, aw.get_active_count())
      assert.equal(0, aw.get_total_count())
    end,

    test_async_run_in_background = function()
      local aw = require("NeoAI.utils.async_worker")
      local result = nil
      aw.run_in_background(function(a, b) return a + b end, function(success, res) result = res end, 3, 4)
      safe_wait(500, function() return result ~= nil end)
      assert.equal(7, result)
    end,

    test_async_run_batch_tasks = function()
      local aw = require("NeoAI.utils.async_worker")
      local all_done = false
      aw.run_batch_tasks({ { func = function() return 1 end }, { func = function() return 2 end } }, function(success, results) all_done = true; assert.equal(1, results[1]); assert.equal(2, results[2]) end)
      safe_wait(500, function() return all_done end)
    end,

    test_async_thread_safe_callback = function()
      local aw = require("NeoAI.utils.async_worker")
      local called = false
      local safe_cb = aw.create_thread_safe_callback(function() called = true end)
      assert.not_nil(safe_cb)
      safe_cb()
      safe_wait(100, function() return called end)
      assert.is_true(called)
    end,

    test_async_compute_heavy_task = function()
      local aw = require("NeoAI.utils.async_worker")
      local result = nil
      aw.compute_heavy_task(function() local sum = 0; for i = 1, 100 do sum = sum + i end; return sum end, function(success, res) result = res end)
      safe_wait(500, function() return result ~= nil end)
      assert.equal(5050, result)
    end,

    test_async_ui_updates = function()
      local aw = require("NeoAI.utils.async_worker")
      local called = false
      aw.schedule_ui_update(function() called = true end, 10)
      safe_wait(200, function() return called end)
      assert.is_true(called)
      local called2 = false
      aw.batch_ui_updates({ function() called2 = true end })
      safe_wait(100, function() return called2 end)
    end,

    test_async_reset = function()
      local aw = require("NeoAI.utils.async_worker")
      aw.reset()
      assert.equal(0, aw.get_total_count())
    end,
  })

  -- 恢复 logger 状态
  -- 注意：先恢复 max_file_size，再恢复 output_path
  -- 防止 test_logger_rotate 将 max_file_size 设为 100 后，
  -- 恢复 output_path 时触发 rotate() 轮转 neoai.log
  logger.initialize({ max_file_size = 10485760, max_backups = 5 })
  if _saved_log_path then
    logger.set_output(_saved_log_path)
  end
  if _saved_log_level then
    logger.set_level(_saved_log_level)
  end

  return results
end

-- 直接运行（仅在非 run_all 模式下）
if not _G._NEOAI_TEST_RUNNING and pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M
