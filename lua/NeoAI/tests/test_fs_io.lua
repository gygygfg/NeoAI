local tests = require("NeoAI.tests")
local fs = require("NeoAI.utils.fs")

local function with_dir(fn)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local ok, err = xpcall(function() fn(dir) end, function(e) return e end)
  vim.fn.delete(dir, "rf")
  if not ok then error(err, 0) end
end

tests.suite("fs_io", function(_, it)
  it("原子保存保留旧版备份并清理临时文件", function(t)
    with_dir(function(dir)
      local path = dir .. "/session.jsonl"
      t.true_(fs.write_file_atomic(path, "old", { backup = true }))
      t.true_(fs.write_file_atomic(path, "new", { backup = true }))
      t.eq("new", fs.read_file(path))
      t.eq("old", fs.read_file(path .. ".bak"))
      t.eq(2, #vim.fn.readdir(dir))
    end)
  end)

  it("原子保存处理短写，备份/写入/同步/rename 失败不损坏原文件", function(t)
    with_dir(function(dir)
      local path = dir .. "/data"
      fs.write_file(path, "original")
      local write = vim.uv.fs_write
      vim.uv.fs_write = function(fd, data, offset) return write(fd, data:sub(1, 3), offset) end
      local called, ok = pcall(fs.write_file_atomic, path, "short writes handled")
      vim.uv.fs_write = write
      t.true_(called)
      t.true_(ok)
      t.eq("short writes handled", fs.read_file(path))
      for _, entry in ipairs({ { fs, "copy_file" }, { vim.uv, "fs_write" }, { vim.uv, "fs_fsync" }, { vim.uv, "fs_rename" } }) do
        local object, key = entry[1], entry[2]
        local original = object[key]
        object[key] = function() return nil, "injected failure" end
        local success, saved, err = pcall(fs.write_file_atomic, path, "replacement", { backup = true })
        object[key] = original
        t.true_(success)
        t.false_(saved)
        t.eq("injected failure", err)
        t.eq("short writes handled", fs.read_file(path))
        for _, name in ipairs(vim.fn.readdir(dir)) do
          t.nil_(name:find(".tmp.", 1, true), "临时文件应被清理")
        end
      end
    end)
  end)

  it("同步写入检查 write 与 close 返回值", function(t)
    for _, fail_at in ipairs({ "write", "close" }) do
      local closed = false
      local open = io.open
      io.open = function()
        return {
          write = function() if fail_at == "write" then return nil, "write failed" end; return true end,
          close = function() closed = true; if fail_at == "close" then return nil, "close failed" end; return true end,
        }
      end
      local called, ok, err = pcall(fs.write_file, "unused", "data")
      io.open = open
      t.true_(called)
      t.false_(ok)
      t.eq(fail_at .. " failed", err)
      t.true_(closed)
    end
  end)

  it("真实磁盘满错误：同步与线程池写入/追加均失败", function(t)
    if not vim.uv.fs_stat("/dev/full") then return end -- Linux 故障设备
    t.false_(fs.write_file("/dev/full", "data"))
    t.false_(fs.append_file("/dev/full", "data"))
    for _, result in ipairs({ fs.write_file_async("/dev/full", "data"), fs.append_file_async("/dev/full", "data") }) do
      local failure
      t.await(result:catch(function(err) failure = err end))
      t.eq("work", failure.kind)
      t.not_nil(failure.message)
    end
  end)

  it("完整 JSONL 末行缺换行时后续追加仍可恢复", function(t)
    with_dir(function(dir)
      local path = dir .. "/data.jsonl"
      fs.write_file(path, '{"id":"first"}')
      fs.repair_jsonl(path)
      t.true_(fs.append_jsonl(path, { id = "second" }))
      t.eq(2, #fs.read_jsonl(path))
    end)
  end)

  it("读取超大文件拒绝整读并提示行范围，行范围按块读取", function(t)
    with_dir(function(dir)
      local path = dir .. "/big.txt"
      local parts = {}
      for i = 1, 100 do parts[#parts + 1] = "line-" .. i .. "-xxxxxxxxxxxxxxxxxxxx" end
      fs.write_file(path, table.concat(parts, "\n") .. "\n")
      -- 整读上限远小于文件：必须拒绝，不得 OOM。
      local failure
      t.await(fs.read_file_async(path, 50):catch(function(err) failure = err end))
      t.eq("work", failure.kind)
      t.matches("过大", failure.message)
      -- 行范围：只读前 3 行，成功且不整读。
      local got = t.await(fs.read_file_lines_async(path, 1, 3, 100000))
      t.eq("line-1-xxxxxxxxxxxxxxxxxxxx\nline-2-xxxxxxxxxxxxxxxxxxxx\nline-3-xxxxxxxxxxxxxxxxxxxx", got)
      -- 起始行 + 不限定结束行：与 vim.split(content.."\n") 语义一致（保留末尾换行）。
      local all = t.await(fs.read_file_lines_async(path, 1, 0, 100000))
      t.eq(table.concat(parts, "\n") .. "\n", all)
      -- 单行超过累计上限：拒绝而非无限增长。
      local failure2
      t.await(fs.read_file_lines_async(path, 1, 1, 5):catch(function(err) failure2 = err end))
      t.eq("work", failure2.kind)
      t.matches("上限", failure2.message)
    end)
  end)

  it("读取目录明确报错而非静默返回空", function(t)
    with_dir(function(dir)
      local failure
      t.await(fs.read_file_async(dir, 1024):catch(function(err) failure = err end))
      t.eq("work", failure.kind)
      t.matches("目录", failure.message)
    end)
  end)

  it("搜索跳过超大文件与二进制文件，正常文件仍命中", function(t)
    with_dir(function(dir)
      fs.write_file(dir .. "/ok.txt", "hello needle world\n")
      fs.write_file(dir .. "/big.txt", string.rep("padding ", 50) .. "needle\n")
      fs.write_file(dir .. "/bin.dat", "hello needle\0binary\n")
      local result = t.await(fs.search_files_async(dir, "needle", { max_file_bytes = 40 }))
      t.matches("ok.txt", result)
      t.eq(nil, result:find("big.txt", 1, true), "超大文件应被跳过")
      t.eq(nil, result:find("bin.dat", 1, true), "二进制文件应被跳过")
    end)
  end)

  it("list_dir 递归有条目上限（防止超大目录跑满工作线程）", function(t)
    with_dir(function(dir)
      for i = 1, 8 do fs.write_file(dir .. "/f" .. i .. ".txt", "x") end
      -- entry_cap 覆盖内置 50000 上限，验证到达上限即停止。
      local result = t.await(fs.list_dir_async(dir, 0, { entry_cap = 3 }))
      local lines = vim.split(result, "\n", { plain = true })
      t.eq(3, #lines, "应只返回上限条数")
    end)
  end)

  it("search_files 无匹配时受遍历上限约束（不无界遍历）", function(t)
    with_dir(function(dir)
      for i = 1, 10 do fs.write_file(dir .. "/d" .. i .. ".txt", "nothing here") end
      local result = t.await(fs.search_files_async(dir, "ZZZ_nomatch", { visit_cap = 5 }))
      t.matches("已扫描", result, "应提示因目录过大而停止")
    end)
  end)
end)
