--- 测试: utils/init.lua
--- 测试工具库的初始化、模块加载、函数合并等功能
local M = {}

local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_utils_init ===")

  return test.run_tests({
    --- 测试自动初始化
    test_auto_initialized = function()
      local utils = require("NeoAI.utils")
      -- 加载时已自动初始化，应有模块（text_utils 可能不存在，但其他模块应存在）
      local modules = utils.list_modules()
      -- 至少 common 模块应存在
      assert.is_true(utils.is_module_loaded("common"), "common 应已加载")
    end,

    --- 测试 list_modules
    test_list_modules = function()
      local utils = require("NeoAI.utils")
      local modules = utils.list_modules()
      assert.contains(modules, "common", "应包含 common 模块")
      assert.contains(modules, "table_utils", "应包含 table_utils 模块")
      assert.contains(modules, "file_utils", "应包含 file_utils 模块")
      assert.contains(modules, "logger", "应包含 logger 模块")
    end,

    --- 测试 get_module
    test_get_module = function()
      local utils = require("NeoAI.utils")
      local common = utils.get_module("common")
      assert.not_nil(common, "common 模块应存在")

      local missing = utils.get_module("nonexistent")
      assert.equal(nil, missing, "不存在的模块应返回 nil")
    end,

    --- 测试 is_module_loaded
    test_is_module_loaded = function()
      local utils = require("NeoAI.utils")
      assert.is_true(utils.is_module_loaded("common"), "common 应已加载")
      assert.is_false(utils.is_module_loaded("nonexistent"), "不存在的模块应未加载")
    end,

    --- 测试函数已合并到主表
    test_functions_merged = function()
      local utils = require("NeoAI.utils")
      -- 这些函数应可直接通过 utils 调用
      assert.is_true(type(utils.list_modules) == "function", "list_modules 应可用")
      assert.is_true(type(utils.get_module) == "function", "get_module 应可用")
      assert.is_true(type(utils.is_module_loaded) == "function", "is_module_loaded 应可用")
    end,

    --- 测试 reload
    test_reload = function()
      local utils = require("NeoAI.utils")
      utils.reload()
      -- reload 后 text_utils 可能加载失败，但 common 应存在
      assert.is_true(utils.is_module_loaded("common") or #utils.list_modules() > 0,
        "reload 后应有模块")
    end,
  })
end

-- 直接运行
if pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M

