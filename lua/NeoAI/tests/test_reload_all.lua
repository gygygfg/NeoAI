--- reload_all 热重载实现测试（供 :NeoAIReloadAll 命令使用的底层实现）
--- @module NeoAI.tests.test_reload_all

local tests = require("NeoAI.tests")

tests.suite("reload_all", function(_, it)
  it("reload_all 不再注册为 AI 工具（改由 :NeoAIReloadAll 命令驱动）", function(t)
    local tools = require("NeoAI.tools")
    tools.init()
    local reg = tools.registry
    t.false_(reg.has("reload_all"), "reload_all 不应再注册为 AI 工具")
  end)

  it("_plugin_root 解析出含 lua/ 的插件根目录", function(t)
    local m = require("NeoAI.tools.builtin.reload_all")
    local root = m._plugin_root()
    t.not_nil(root, "应解析出插件根目录")
    t.true_(vim.fn.isdirectory(root .. "/lua") == 1, "插件根下应存在 lua/ 目录")
    t.true_(vim.fn.isdirectory(root .. "/lua/NeoAI") == 1, "插件根下应存在 lua/NeoAI/")
  end)

  it("预检脚本包含关键模块与结果标记", function(t)
    local m = require("NeoAI.tools.builtin.reload_all")
    local script = m._precheck_script()
    t.matches("NeoAI", script)
    t.matches("setup", script)
    t.matches("RELOAD_PRECHECK_OK", script)
    t.matches("RELOAD_PRECHECK_FAIL", script)
    -- 脚本本身应可被 Lua 解析
    local f = loadstring(script)
    t.not_nil(f, "预检脚本应为合法 Lua")
  end)

  it("预检失败时返回报错", function(t)
    local m = require("NeoAI.tools.builtin.reload_all")
    -- 注入一个必定失败的预检执行器（模拟子进程报错）
    m._set_spawner(function()
      return { code = 1, stdout = "RELOAD_PRECHECK_FAIL\n", stderr = "some_module: syntax error near 'x'" }
    end)

    local res = m._precheck()
    t.false_(res.ok, "预检失败应返回 ok=false")
    t.not_nil(res.message, "预检失败应返回错误信息")
    t.matches("syntax error", res.message, "错误信息应包含子进程 stderr")

    m._set_spawner(nil)
  end)

  it("预检通过时返回 ok", function(t)
    local m = require("NeoAI.tools.builtin.reload_all")
    m._set_spawner(function()
      return { code = 0, stdout = "RELOAD_PRECHECK_OK\n", stderr = "" }
    end)

    local res = m._precheck()
    t.true_(res.ok, "预检通过应返回 ok=true")
    t.matches("预检通过", res.message)

    m._set_spawner(nil)
  end)
end)
