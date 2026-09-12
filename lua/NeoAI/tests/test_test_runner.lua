local tests = require("NeoAI.tests")

tests.suite("test_runner", function(_, it)
  local function isolated_runner(files, fn)
    local source = debug.getinfo(tests.run_all, "S").source:sub(2)
    local runner = assert(loadfile(source))()
    local glob = vim.fn.glob
    vim.fn.glob = function() return files end
    local ok, err = xpcall(function() fn(runner) end, function(e) return e end)
    vim.fn.glob = glob
    if not ok then error(err, 0) end
  end

  it("模块加载失败计入 failed 与 errors", function(t)
    isolated_runner({ "/nonexistent/test_missing_runner_fixture.lua" }, function(runner)
      local result = runner.run_all()
      t.eq(1, result.failed)
      t.eq(1, #result.errors)
      t.eq(0, result.passed)
    end)
  end)

  it("返回 Deferred 的异步断言失败不会误报通过", function(t)
    isolated_runner({}, function(runner)
      runner.suite("fixture", function(_, test)
        test("async failure", function(a)
          return require("NeoAI.utils.async").sleep(10):then_(function() a.eq(1, 2) end)
        end)
      end)
      local result = runner.run_all("fixture")
      t.eq(1, result.failed)
      t.eq(0, result.passed)
      t.eq(1, #result.errors)
    end)
  end)

  it("不存在的套件计为失败", function(t)
    isolated_runner({}, function(runner)
      local result = runner.run_all("nonexistent")
      t.eq(1, result.failed)
      t.eq(1, #result.errors)
    end)
  end)
end)
