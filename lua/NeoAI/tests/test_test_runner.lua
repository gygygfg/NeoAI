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

  it("隔离运行器：定位插件根目录", function(t)
    local root = tests._plugin_root()
    t.not_nil(root, "应定位到插件根目录")
    t.eq(1, vim.fn.filereadable(root .. "/lua/NeoAI/tests/init.lua"),
      "根目录下应存在 lua/NeoAI/tests/init.lua")
  end)

  it("隔离运行器：预置脚本包含套件名与 SUMMARY", function(t)
    local script = tests._isolated_script({ "tools", "plugins" })
    t.matches("run_all%(unpack%(names%)%)", script, "应调用 run_all")
    t.matches('"tools"', script, "应内联套件名 tools")
    t.matches('"plugins"', script, "应内联套件名 plugins")
    t.matches("SUMMARY passed=", script, "应打印 SUMMARY")
  end)

  it("隔离运行器：解析子进程输出", function(t)
    local out = "noise\nSUMMARY passed=7 failed=2\nERROR:: suite :: case\nmore"
    local r = tests._parse_child_output(out, "", 1)
    t.eq(7, r.passed)
    t.eq(2, r.failed)
    t.eq(1, #r.errors)
    t.matches("suite :: case", r.errors[1], "应捕获失败详情")
    t.false_(r.ok, "有失败不应标记 ok")
    local r2 = tests._parse_child_output("SUMMARY passed=3 failed=0\n", "", 0)
    t.true_(r2.ok, "全通过且退出码 0 应为 ok")
    t.eq(3, r2.passed)
    t.eq(0, r2.failed)
  end)

  it("隔离运行器：经可注入执行器回调结果并清理脚本", function(t)
    local captured_cmd, captured_script
    tests._set_child_spawner(function(cmd, script_path, o)
      captured_cmd, captured_script = cmd, script_path
      local f = io.open(script_path, "r")
      t.not_nil(f, "子进程脚本应已写入")
      if f then f:close() end
      o.on_done(tests._parse_child_output("SUMMARY passed=1 failed=0\n", "", 0))
    end)
    local done, result
    tests.run_isolated({ "fixture" }, {
      on_done = function(res) done, result = true, res end,
    })
    tests._set_child_spawner(nil)
    t.true_(done, "on_done 应被调用")
    t.eq(1, result.passed)
    t.eq(0, result.failed)
    t.not_nil(captured_cmd, "应构造子进程 argv")
    t.eq("--headless", captured_cmd[2], "argv 应为 headless nvim")
    t.eq(0, vim.fn.filereadable(captured_script), "回调后应清理脚本")
  end)
end)
