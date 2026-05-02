--- 测试: utils/file_utils.lua
--- 测试文件工具函数的读写、路径操作、目录管理等功能
local M = {}

local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_utils_file_utils ===")

  return test.run_tests({
    --- 测试 read_file / write_file
    test_read_write_file = function()
      local fu = require("NeoAI.utils.file_utils")
      local test_path = "/tmp/neoai_test_file.txt"

      -- 写入
      local ok, err = fu.write_file(test_path, "Hello World!")
      assert.is_true(ok, "写入应成功: " .. tostring(err))

      -- 读取
      local content, err2 = fu.read_file(test_path)
      assert.equal("Hello World!", content, "读取内容应匹配")

      -- 清理
      os.remove(test_path)
    end,

    --- 测试 read_file 文件不存在
    test_read_file_not_found = function()
      local fu = require("NeoAI.utils.file_utils")
      local content, err = fu.read_file("/tmp/nonexistent_file_12345.txt")
      assert.equal(nil, content, "不存在的文件应返回 nil")
      assert.not_nil(err, "应返回错误信息")
    end,

    --- 测试 write_file 追加模式
    test_write_file_append = function()
      local fu = require("NeoAI.utils.file_utils")
      local test_path = "/tmp/neoai_test_append.txt"

      fu.write_file(test_path, "第一行\n")
      fu.write_file(test_path, "第二行\n", true)

      local content = fu.read_file(test_path)
      assert.equal("第一行\n第二行\n", content)

      os.remove(test_path)
    end,

    --- 测试 read_lines / write_lines
    test_read_write_lines = function()
      local fu = require("NeoAI.utils.file_utils")
      local test_path = "/tmp/neoai_test_lines.txt"

      local ok = fu.write_lines(test_path, { "行1", "行2", "行3" })
      assert.is_true(ok, "写入行应成功")

      local lines = fu.read_lines(test_path)
      assert.equal(3, #lines)
      assert.equal("行1", lines[1])
      assert.equal("行2", lines[2])
      assert.equal("行3", lines[3])

      os.remove(test_path)
    end,

    --- 测试 exists
    test_exists = function()
      local fu = require("NeoAI.utils.file_utils")
      local test_path = "/tmp/neoai_test_exists.txt"

      assert.is_false(fu.exists(test_path), "文件初始不应存在")

      fu.write_file(test_path, "test")
      assert.is_true(fu.exists(test_path), "写入后应存在")

      os.remove(test_path)
    end,

    --- 测试 mkdir / dir_exists
    test_mkdir = function()
      local fu = require("NeoAI.utils.file_utils")
      local test_dir = "/tmp/neoai_test_dir"

      -- 清理
      os.execute("rm -rf " .. test_dir)

      assert.is_false(fu.dir_exists(test_dir), "目录初始不应存在")

      local ok = fu.mkdir(test_dir)
      assert.is_true(ok, "创建目录应成功")
      assert.is_true(fu.dir_exists(test_dir), "创建后应存在")

      -- 重复创建
      local ok2 = fu.mkdir(test_dir)
      assert.is_true(ok2, "重复创建应成功")

      os.execute("rm -rf " .. test_dir)
    end,

    --- 测试 join_path
    test_join_path = function()
      local fu = require("NeoAI.utils.file_utils")

      assert.equal("/a/b/c", fu.join_path("/a", "b", "c"))
      assert.equal("a/b/c", fu.join_path("a", "b", "c"))
      assert.equal("/a/b", fu.join_path("/a", "/b"))
    end,

    --- 测试 get_extension / get_filename / get_dirname
    test_path_utils = function()
      local fu = require("NeoAI.utils.file_utils")

      assert.equal("txt", fu.get_extension("/path/to/file.txt"))
      assert.equal("file.txt", fu.get_filename("/path/to/file.txt"))
      assert.equal("/path/to", fu.get_dirname("/path/to/file.txt"))
    end,

    --- 测试 get_file_size / get_mtime
    test_file_stats = function()
      local fu = require("NeoAI.utils.file_utils")
      local test_path = "/tmp/neoai_test_stats.txt"

      fu.write_file(test_path, "12345")

      local size = fu.get_file_size(test_path)
      assert.equal(5, size, "文件大小应为5字节")

      local mtime = fu.get_mtime(test_path)
      assert.is_true(mtime > 0, "修改时间应大于0")

      os.remove(test_path)
    end,

    --- 测试 copy_file / move_file / delete_file
    test_copy_move_delete = function()
      local fu = require("NeoAI.utils.file_utils")
      local src = "/tmp/neoai_test_src.txt"
      local dst = "/tmp/neoai_test_dst.txt"

      fu.write_file(src, "复制测试")

      -- 复制
      local ok, err = fu.copy_file(src, dst)
      assert.is_true(ok, "复制应成功: " .. tostring(err))
      assert.is_true(fu.exists(dst), "目标文件应存在")

      -- 移动
      local move_dst = "/tmp/neoai_test_moved.txt"
      local ok2, err2 = fu.move_file(dst, move_dst)
      assert.is_true(ok2, "移动应成功: " .. tostring(err2))
      assert.is_false(fu.exists(dst), "原文件应不存在")
      assert.is_true(fu.exists(move_dst), "移动后文件应存在")

      -- 删除
      local ok3, err3 = fu.delete_file(move_dst)
      assert.is_true(ok3, "删除应成功: " .. tostring(err3))

      os.remove(src)
    end,

    --- 测试 abs_path / normalize_path
    test_path_normalization = function()
      local fu = require("NeoAI.utils.file_utils")

      local abs = fu.abs_path("/tmp/test")
      assert.equal("/tmp/test", abs)

      local normalized = fu.normalize_path("/a//b/../c/./d")
      assert.equal("/a/c/d", normalized)
    end,

    --- 测试 is_file / is_directory
    test_is_file_dir = function()
      local fu = require("NeoAI.utils.file_utils")
      local test_path = "/tmp/neoai_test_isfile.txt"

      fu.write_file(test_path, "test")
      assert.is_true(fu.is_file(test_path))
      assert.is_false(fu.is_directory(test_path))

      os.remove(test_path)
    end,

    --- 测试 search_files
    test_search_files = function()
      local fu = require("NeoAI.utils.file_utils")
      -- search_files 使用外部命令，测试基本功能
      local results, err = fu.search_files("/tmp", "*", false)
      if results then
        assert.is_true(type(results) == "table")
      end
    end,

    --- 测试 ensure_dir（别名）
    test_ensure_dir = function()
      local fu = require("NeoAI.utils.file_utils")
      local test_dir = "/tmp/neoai_test_ensure"
      os.execute("rm -rf " .. test_dir)

      local ok = fu.ensure_dir(test_dir)
      assert.is_true(ok)

      os.execute("rm -rf " .. test_dir)
    end,

    --- 测试 cleanup_session_buffers
    test_cleanup_session_buffers = function()
      local fu = require("NeoAI.utils.file_utils")
      fu.cleanup_session_buffers()
      assert.equal(0, fu.get_loaded_buffer_count())
    end,
  })
end

-- 直接运行
if pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M
