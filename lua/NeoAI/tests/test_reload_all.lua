--- reload_all 工具测试
--- @module NeoAI.tests.test_reload_all

local tests = require("NeoAI.tests")

tests.suite("reload_all", function(_, it)
  it("reload_all 工具已注册且需要审批", function(t)
    local tools = require("NeoAI.tools")
    tools.init()
    local reg = tools.registry
    t.true_(reg.has("reload_all"), "应注册 reload_all 工具")
    local def = reg.get("reload_all")
    t.not_nil(def, "应能取到 reload_all 定义")
    local cfg = reg.get_approval_config("reload_all")
    t.not_nil(cfg, "应有审批配置")
    t.false_(cfg.auto_allow, "reload_all 不应默认自动允许（需审批）")
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

  it("预检失败时返回报错且不触发重载", function(t)
    local m = require("NeoAI.tools.builtin.reload_all")
    -- 注入一个必定失败的预检执行器（模拟子进程报错）
    m._set_spawner(function()
      return { code = 1, stdout = "RELOAD_PRECHECK_FAIL\n", stderr = "some_module: syntax error near 'x'" }
    end)
    -- 记录受控重载是否被调用
    local performed = false
    m._set_perform(function() performed = true; return true end)

    local tool
    for _, tl in ipairs(m.get_tools()) do
      if tl.name == "reload_all" then tool = tl end
    end
    t.not_nil(tool, "应存在 reload_all 工具")

    local out = {}
    tool.func({}, function(msg) out.ok = msg end, function(e) out.err = e end, {})
    t.nil_(out.ok, "预检失败不应走成功回调")
    t.not_nil(out.err, "预检失败应返回错误")
    t.matches("预检失败", out.err)
    t.matches("syntax error", out.err, "错误信息应包含子进程 stderr")

    -- 等待可能的 vim.schedule 延迟执行，确认重载未被调度
    vim.wait(50, function() return performed end)
    t.false_(performed, "预检失败不得触发重载")

    m._set_spawner(nil)
    m._set_perform(nil)
  end)

  it("预检通过时触发重载调度", function(t)
    local m = require("NeoAI.tools.builtin.reload_all")
    m._set_spawner(function()
      return { code = 0, stdout = "RELOAD_PRECHECK_OK\n", stderr = "" }
    end)
    local performed = false
    m._set_perform(function() performed = true; return true end)

    local tool
    for _, tl in ipairs(m.get_tools()) do
      if tl.name == "reload_all" then tool = tl end
    end

    local out = {}
    tool.func({}, function(msg) out.ok = msg end, function(e) out.err = e end, {})
    t.nil_(out.err, "预检通过不应报错")
    t.not_nil(out.ok, "预检通过应返回成功消息")

    local done = vim.wait(1000, function() return performed end)
    t.true_(done, "预检通过后应调度执行重载")

    m._set_spawner(nil)
    m._set_perform(nil)
  end)
end)
