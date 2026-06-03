--- 流程测试: utils 模块链
--- 调用链: common → table_utils → file_utils → json → logger → async_worker
--- 验证数据在各模块间流转的正确性

local M = {}

function M.run(test_module)
  local assert = test_module.assert
  local logger = test_module._logger or require("NeoAI.utils.logger")

  local tests = {

    -- ============================================================
    -- 流程 1: common → table_utils 深拷贝/深合并链
    -- ============================================================
    flow_common_to_table_utils = function()
      -- 步骤 1: 通过 common 创建复杂嵌套数据
      local common = require("NeoAI.utils.common")
      local original = {
        name = "flow_test",
        config = { timeout = 3000, retry = 3 },
        items = { { id = 1 }, { id = 2 } },
      }

      -- 步骤 2: common.deep_copy 委托给 table_utils
      local copied = common.deep_copy(original)
      assert.not_nil(copied, "common.deep_copy 应返回非 nil")
      assert.not_equal(original, copied, "深拷贝应返回新表（不是同一个引用）")
      assert.equal(original.name, copied.name, "深拷贝应保持字符串值")
      assert.equal(original.config.timeout, copied.config.timeout, "深拷贝应保持嵌套值")

      -- 修改拷贝不应影响原表（验证深拷贝）
      copied.config.timeout = 9999
      assert.equal(3000, original.config.timeout, "修改拷贝不应影响原表的嵌套字段")

      -- 步骤 3: common.deep_merge 委托给 table_utils（验证合并逻辑）
      local overrides = { config = { retry = 5 }, items = { { id = 3 } } }
      local merged = common.deep_merge(original, overrides)
      assert.equal(5, merged.config.retry, "deep_merge 应覆盖嵌套字段")
      assert.equal(3000, merged.config.timeout, "deep_merge 应保留未覆盖的嵌套字段")

      -- 步骤 4: common.merge_tables 别名也经过同一路径
      local merged2 = common.merge_tables({ a = 1 }, { b = 2 })
      assert.equal(1, merged2.a, "merge_tables 应保留第一个表的字段")
      assert.equal(2, merged2.b, "merge_tables 应合并第二个表的字段")
    end,

    -- ============================================================
    -- 流程 2: table_utils 独立链（keys → values → filter → map → reduce）
    -- ============================================================
    flow_table_utils_pipeline = function()
      local tu = require("NeoAI.utils.table_utils")

      -- 步骤 1: 构建测试数据
      local data = { a = 10, b = 20, c = 30, d = 40 }

      -- 步骤 2: keys → values 提取
      local keys = tu.keys(data)
      assert.type_eq("table", keys, "keys 应返回表")
      assert.equal(4, #keys, "keys 应返回 4 个键")

      local values = tu.values(data)
      assert.equal(4, #values, "values 应返回 4 个值")

      -- 步骤 3: filter 过滤
      local filtered = tu.filter(data, function(v, k)
        return v > 15
      end)
      -- filter 可能返回数组或字典表
      local count = 0
      for _ in pairs(filtered) do count = count + 1 end
      assert.equal(3, count, "filter 应过滤出 3 个元素（20, 30, 40）")

      -- 步骤 4: map 映射
      local mapped = tu.map(data, function(v, k)
        return v * 2
      end)
      -- mapped 按 key 保留，验证映射结果
      assert.equal(20, mapped.a, "map a: 10*2 = 20")
      assert.equal(40, mapped.b, "map b: 20*2 = 40")

      -- 步骤 5: reduce 归约
      local sum = tu.reduce(data, function(acc, v)
        return acc + v
      end, 0)
      assert.equal(100, sum, "reduce sum 10+20+30+40 = 100")
    end,

    -- ============================================================
    -- 流程 3: table_utils → file_utils 数据持久化链
    -- ============================================================
    flow_table_to_file = function()
      local tu = require("NeoAI.utils.table_utils")
      local fu = require("NeoAI.utils.file_utils")

      -- 步骤 1: 使用 table_utils 构建复杂数据
      local data = {
        metadata = { version = "1.0", created = os.time() },
        items = tu.map({ 1, 2, 3 }, function(v) return { id = v, value = v * v } end),
      }

      -- 步骤 2: 通过 file_utils 写入临时文件
      local tmpfile = os.tmpname() .. "_flow_test.json"
      local json_str = vim.json.encode(data)
      local ok, err = fu.write_file(tmpfile, json_str)
      assert.is_true(ok, "write_file 应成功: " .. (err or ""))

      -- 步骤 3: 通过 file_utils 读取回来
      local content, read_err = fu.read_file(tmpfile)
      assert.not_nil(content, "read_file 应返回内容: " .. (read_err or ""))
      local decoded = vim.json.decode(content)
      assert.equal("1.0", decoded.metadata.version, "读回的数据应保持 metadata.version")

      -- 步骤 4: 验证 file_utils 路径操作
      local filename = fu.get_filename(tmpfile)
      assert.not_nil(filename, "get_filename 应返回文件名")
      assert.is_true(string.find(filename, "flow_test"), "文件名应包含 'flow_test'")

      local dirname = fu.get_dirname(tmpfile)
      assert.not_nil(dirname, "get_dirname 应返回目录名")

      -- 清理
      os.remove(tmpfile)
    end,

    -- ============================================================
    -- 流程 4: file_utils 完整文件生命周期（check → read → write → delete）
    -- ============================================================
    flow_file_lifecycle = function()
      local fu = require("NeoAI.utils.file_utils")

      -- 步骤 1: 检查不存在
      local tmpfile = os.tmpname() .. "_lifecycle_test.txt"
      assert.is_false(fu.exists(tmpfile), "新建临时文件应不存在")

      -- 步骤 2: 写入内容
      local ok, err = fu.write_file(tmpfile, "line1\nline2\nline3")
      assert.is_true(ok, "write_file 应成功: " .. (err or ""))

      -- 步骤 3: 检查存在
      assert.is_true(fu.exists(tmpfile), "写入后文件应存在")
      assert.is_true(fu.is_file(tmpfile), "is_file 应返回 true")

      -- 步骤 4: 读取内容
      local content, read_err = fu.read_file(tmpfile)
      assert.not_nil(content, "read_file 应成功: " .. (read_err or ""))
      assert.equal("line1\nline2\nline3", content, "文件内容应匹配")

      -- 步骤 5: 读取行
      local lines, lines_err = fu.read_lines(tmpfile)
      assert.not_nil(lines, "read_lines 应成功: " .. (lines_err or ""))
      assert.equal(3, #lines, "应有 3 行")

      -- 步骤 6: 删除文件
      local del_ok, del_err = fu.delete_file(tmpfile)
      assert.is_true(del_ok, "delete_file 应成功: " .. (del_err or ""))

      -- 步骤 7: 确认删除
      assert.is_false(fu.exists(tmpfile), "删除后文件应不存在")
    end,

    -- ============================================================
    -- 流程 5: json → table_utils 编解码往返链
    -- ============================================================
    flow_json_roundtrip = function()
      local json = require("NeoAI.utils.json")
      local tu = require("NeoAI.utils.table_utils")

      -- 步骤 1: 用 table_utils 构建复杂嵌套数据
      local original = {
        name = "roundtrip",
        array = tu.map({ 1, 2, 3 }, function(v) return v * 10 end),
        nested = { deep = { value = "test" } },
        booleans = { true, false },
      }

      -- 步骤 2: json.encode → json.decode 往返
      local encoded = json.encode(original)
      assert.type_eq("string", encoded, "json.encode 应返回字符串")
      assert.is_true(#encoded > 0, "编码结果不应为空")

      local decoded = json.decode(encoded)
      assert.type_eq("table", decoded, "json.decode 应返回表")

      -- 步骤 3: 验证深层结构
      assert.equal("roundtrip", decoded.name, "往返后 name 应相等")
      assert.equal(10, decoded.array[1], "往返后 array[1] 应为 10")
      assert.equal(30, decoded.array[3], "往返后 array[3] 应为 30")
      assert.equal("test", decoded.nested.deep.value, "往返后深层嵌套值应相等")

      -- 步骤 4: 用 table_utils 深比较
      local is_equal = tu.deep_equal(original, decoded)
      assert.is_true(is_equal, "json 编码/解码往返后 deep_equal 应返回 true")
    end,

    -- ============================================================
    -- 流程 6: logger → file_utils 日志写入链
    -- ============================================================
    flow_logger_to_file = function()
      local log = require("NeoAI.utils.logger")
      local fu = require("NeoAI.utils.file_utils")

      -- 步骤 1: 设置 logger 输出到临时文件
      local tmpfile = os.tmpname() .. "_flow_log_test.log"
      log.set_output(tmpfile)
      log.set_level("DEBUG")

      -- 步骤 2: 写入各级别日志
      log.debug("flow debug message")
      log.info("flow info message")
      log.warn("flow warn message")
      log.error("flow error message")

      -- 步骤 3: 通过 file_utils 读取日志文件
      local content, read_err = fu.read_file(tmpfile)
      assert.not_nil(content, "应能读取日志文件: " .. (read_err or ""))

      -- 步骤 4: 验证日志内容
      assert.is_true(string.find(content, "debug", 1, true) ~= nil
        or string.find(content:upper(), "DEBUG") ~= nil, "日志应包含 debug 级别内容")

      -- 步骤 5: 验证日志级别过滤
      local level = log.get_level()
      assert.not_nil(level, "get_level 应返回非 nil")

      -- 恢复并清理
      log.set_output(nil)
      pcall(os.remove, tmpfile)
    end,

    -- ============================================================
    -- 流程 7: common 工具函数完整链
    -- ============================================================
    flow_common_utilities = function()
      local common = require("NeoAI.utils.common")

      -- safe_call
      local result, err = common.safe_call(function(x) return x * 2 end, 21)
      assert.equal(42, result, "safe_call 应正确返回计算结果")
      assert.is_nil(err, "safe_call 成功时错误应为 nil")

      -- safe_call 错误处理
      local err_result, err_msg = common.safe_call(function() error("test error") end)
      assert.is_nil(err_result, "safe_call 失败时结果应为 nil")
      assert.is_true(tostring(err_msg or ""):find("test error"), "safe_call 应返回错误消息")

      -- unique_id
      local id1 = common.unique_id("test")
      local id2 = common.unique_id("test")
      assert.not_nil(id1, "unique_id 应返回非 nil")
      assert.not_equal(id1, id2, "连续 unique_id 应返回不同值")

      -- is_empty
      assert.is_true(common.is_empty(nil), "nil 应为空")
      assert.is_true(common.is_empty(""), "空字符串应为空")
      assert.is_true(common.is_empty({}), "空表应为空")
      assert.is_false(common.is_empty("hello"), "非空字符串不应为空")
      assert.is_false(common.is_empty({ 1 }), "非空表不应为空")

      -- default 值
      assert.equal("fallback", common.default(nil, "fallback"), "nil 应返回默认值")
      assert.equal("fallback", common.default("", "fallback"), "空字符串应返回默认值")
      assert.equal("keep", common.default("keep", "fallback"), "非空值应保持原值")

      -- check_type
      assert.is_true(common.check_type("hello", "string"), "字符串类型检查应通过")
      assert.is_true(common.check_type(42, "number"), "数字类型检查应通过")
      assert.is_true(common.check_type({ 1, 2 }, "array"), "数组检查应通过")
      assert.is_true(common.check_type({ a = 1 }, "object"), "对象检查应通过")
      assert.is_false(common.check_type(42, "string"), "类型不匹配应返回 false")

      -- random_string
      local rs = common.random_string(12)
      assert.type_eq("string", rs, "random_string 应返回字符串")
      assert.equal(12, #rs, "random_string 长度应匹配")
    end,

    -- ============================================================
    -- 流程 8: async_worker 基本生命周期
    -- ============================================================
    flow_async_worker = function()
      local ok, aw = pcall(require, "NeoAI.utils.async_worker")
      if not ok or not aw then
        return  -- 模块可能不存在，跳过
      end

      -- 步骤 1: 重置状态
      if aw.reset then
        aw.reset()
      end

      -- 步骤 2: 验证初始状态
      if aw.get_active_workers then
        local active = aw.get_active_workers()
        assert.is_true(active >= 0, "get_active_workers 应返回非负数")
      end

      -- 步骤 3: 设置最大工作器数
      if aw.set_max_workers then
        aw.set_max_workers(4)
      end

      -- 步骤 4: 获取 worker 总数
      if aw.get_worker_count then
        local count = aw.get_worker_count()
        assert.is_true(count >= 0, "get_worker_count 应返回非负数")
      end

      -- 步骤 5: 检查并行支持
      if aw.is_parallel_supported then
        local supported = aw.is_parallel_supported()
        -- 仅验证不报错
        assert.is_true(true, "is_parallel_supported 不应报错")
      end
    end,

    -- ============================================================
    -- 流程 9: utils init 加载链
    -- ============================================================
    flow_utils_init = function()
      local utils = require("NeoAI.utils")

      -- 验证 utils 模块初始化正确
      assert.not_nil(utils, "utils 模块应可加载")
      assert.type_eq("function", utils.initialize, "utils.initialize 应为函数")
      assert.type_eq("function", utils.get_module, "utils.get_module 应为函数")
      assert.type_eq("function", utils.list_modules, "utils.list_modules 应为函数")
      assert.type_eq("function", utils.is_module_loaded, "utils.is_module_loaded 应为函数")
      assert.type_eq("function", utils.reload, "utils.reload 应为函数")

      -- 验证自动加载的模块
      local modules = utils.list_modules()
      assert.type_eq("table", modules, "list_modules 应返回表")
      assert.is_true(#modules > 0, "应有至少一个已加载模块")

      -- 验证模块可查询
      for _, mod_name in ipairs(modules) do
        assert.is_true(utils.is_module_loaded(mod_name),
          "模块 " .. mod_name .. " 应标记为已加载")
        local mod = utils.get_module(mod_name)
        assert.not_nil(mod, "get_module(" .. mod_name .. ") 应返回非 nil")
      end
    end,

    -- ============================================================
    -- 流程 10: table_utils 数组操作完整链
    -- ============================================================
    flow_table_array_ops = function()
      local tu = require("NeoAI.utils.table_utils")

      local arr = { 1, 2, 3, 4, 5 }

      -- reverse
      if tu.reverse then
        local rev = tu.reverse(arr)
        assert.equal(5, rev[1], "reverse 后第一个元素应为 5")
        assert.equal(1, rev[5], "reverse 后最后一个元素应为 1")
      end

      -- sort
      if tu.sort then
        local unsorted = { 5, 3, 1, 4, 2 }
        local sorted = tu.sort(unsorted)
        assert.equal(1, sorted[1], "sort 后第一个元素应为 1")
        assert.equal(5, sorted[5], "sort 后最后一个元素应为 5")
      end

      -- unique / deduplicate
      if tu.unique then
        local dups = { 1, 2, 2, 3, 3, 3 }
        local uniq = tu.unique(dups)
        assert.equal(3, #uniq, "unique 应去重为 3 个元素")
      end

      -- contains
      if tu.contains then
        assert.is_true(tu.contains(arr, 3), "contains(3) 应返回 true")
        assert.is_false(tu.contains(arr, 99), "contains(99) 应返回 false")
      end

      -- has_key
      if tu.has_key then
        local dict = { x = 1, y = 2 }
        assert.is_true(tu.has_key(dict, "x"), "has_key('x') 应返回 true")
        assert.is_false(tu.has_key(dict, "z"), "has_key('z') 应返回 false")
      end

      -- clone (浅拷贝)
      if tu.clone then
        local cloned = tu.clone(arr)
        assert.not_equal(arr, cloned, "clone 应返回新表")
        assert.equal(arr[1], cloned[1], "clone 的值应相等")
      end

      -- length
      if tu.length then
        local len = tu.length({ a = 1, b = 2, c = 3 })
        assert.equal(3, len, "length 应返回 3")
      end

      -- is_empty
      if tu.is_empty then
        assert.is_true(tu.is_empty({}), "is_empty({}) 应返回 true")
        assert.is_false(tu.is_empty({ 1 }), "is_empty({1}) 应返回 false")
      end
    end,
  }

  return test_module.run_tests(tests)
end

return M
