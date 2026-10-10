--- 沙箱长驻服务工具（tools.builtin.service）专项测试
--- @module NeoAI.tests.test_service_tool
--- 通过注入假的 sandbox.service 验证工具层的校验/格式化/回调，不启动真实进程。
local tests = require("NeoAI.tests")

tests.suite("service_tool", function(_, it)
  local tool_mod = require("NeoAI.tools.builtin.service")
  local tools = {}
  for _, tl in ipairs(tool_mod.get_tools()) do tools[tl.name] = tl end

  local function with_fake(fake, fn)
    local real = package.loaded["NeoAI.sandbox.execution.service"]
    package.loaded["NeoAI.sandbox.execution.service"] = fake
    local ok, err = pcall(fn)
    package.loaded["NeoAI.sandbox.execution.service"] = real
    if not ok then error(err, 0) end
  end

  local function invoke(tool, args)
    local res, err, done = nil, nil, false
    tool.func(args, function(v) res, done = v, true end, function(e) err, done = e, true end, {})
    if not done then
      vim.wait(3000, function() return done end, 10)
    end
    return res, err
  end

  local fake = {
    start = function(name, _, opts) return { name = name, id = "svc_" .. name, job = 4242, cwd = (opts and opts.cwd) or "/tmp/work" } end,
    logs = function(name) return name == "empty" and "" or "line1\nline2" end,
    status = function(name)
      if name == "missing" then return nil end
      return { name = name, status = "running", id = "svc_" .. name, pid = 99, cwd = "/tmp", log_bytes = 12 }
    end,
    list = function()
      return {
        { name = "a", status = "running", id = "svc_a", pid = 1 },
        { name = "b", status = "stopped", id = "svc_b", exit_code = 0 },
      }
    end,
    stop = function(name, cb) cb(nil, { name = name, id = "svc_" .. name, exit_code = 0 }) end,
  }

  it("long_lived 标记：start/stop 为长驻服务", function(t)
    t.true_(tools.service_start.long_lived == true)
    t.true_(tools.service_stop.long_lived == true)
    t.nil_(tools.service_logs.long_lived)
  end)

  it("service_start：缺少 name/command 校验", function(t)
    with_fake(fake, function()
      local _, e1 = invoke(tools.service_start, {})
      t.matches("缺少必填字符串参数 name", e1)
      local _, e2 = invoke(tools.service_start, { name = "web" })
      t.matches("缺少必填字符串参数 command", e2)
    end)
  end)

  it("service_start：成功返回服务信息", function(t)
    with_fake(fake, function()
      local res, err = invoke(tools.service_start, { name = "web", command = "node server.js" })
      t.nil_(err)
      t.matches("服务已启动", res)
      t.matches("web", res)
      t.matches("pid=4242", res)
    end)
  end)

  it("service_logs：返回日志、空日志有占位", function(t)
    with_fake(fake, function()
      t.matches("line1", invoke(tools.service_logs, { name = "web" }))
      t.eq("（暂无日志）", invoke(tools.service_logs, { name = "empty" }))
    end)
  end)

  it("service_status：单服务状态与未知服务报错", function(t)
    with_fake(fake, function()
      local res = invoke(tools.service_status, { name = "web" })
      t.matches("web %[running%]", res)
      t.matches("pid=99", res)
      local _, err = invoke(tools.service_status, { name = "missing" })
      t.matches("服务不存在", err)
    end)
  end)

  it("service_status：无 name 时列出全部；空列表有占位", function(t)
    with_fake(fake, function()
      local res = invoke(tools.service_status, {})
      t.matches("a %[running%]", res)
      t.matches("b %[stopped%]", res)
    end)
    with_fake({
      start = fake.start, logs = fake.logs, status = fake.status, stop = fake.stop,
      list = function() return {} end,
    }, function()
      t.eq("（无运行中的服务）", invoke(tools.service_status, {}))
    end)
  end)

  it("service_stop：回调返回停止信息与末尾日志", function(t)
    with_fake(fake, function()
      local res, err = invoke(tools.service_stop, { name = "web" })
      t.nil_(err)
      t.matches("服务已停止", res)
      t.matches("%[末尾日志%]", res)
      t.matches("line1", res)
    end)
  end)

  it("service_stop：缺少 name 校验", function(t)
    with_fake(fake, function()
      local _, err = invoke(tools.service_stop, {})
      t.matches("缺少必填字符串参数 name", err)
    end)
  end)
end)
