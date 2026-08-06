--- 工具系统测试
--- @module NeoAI.tests.test_tools

local tests = require("NeoAI.tests")

tests.suite("tools", function(_, it)
  it("registry 注册与查询", function(t)
    local registry = require("NeoAI.tools.registry")
    registry.reset()
    local helpers = require("NeoAI.tools.builtin.tool_helpers")
    registry.register(helpers.define_tool("test_read", "读取", { type = "object", properties = { filepath = { type = "string" } }, required = { "filepath" } }, function() end, { category = "file" }))
    registry.register(helpers.define_tool("test_write", "写入", { type = "object", properties = {}, required = {} }, function() end, { category = "file" }))
    t.true_(registry.has("test_read"))
    t.eq(2, registry.count())
    t.eq(2, #registry.list("file"))
    t.eq(1, #registry.search("read"))
    local dup, err = registry.register(helpers.define_tool("test_read", "x", nil, function() end))
    t.false_(dup)
    t.matches("已存在", err or "")
  end)

  it("registry 别名解析", function(t)
    local registry = require("NeoAI.tools.registry")
    registry.reset()
    local helpers = require("NeoAI.tools.builtin.tool_helpers")
    registry.register(helpers.define_tool("read_file", "读", nil, function() end))
    t.eq("read_file", registry.resolve_name("read"))
    t.eq("read_file", registry.resolve_name("cat"))
    t.eq("read_file", registry.resolve_name("read_file"))
    t.nil_(registry.resolve_name("不存在"))
  end)

  it("validator 参数校验", function(t)
    local validator = require("NeoAI.tools.validator")
    local params = { type = "object", properties = { filepath = { type = "string" }, max = { type = "integer" } }, required = { "filepath" } }
    local ok, err = validator.validate_parameters(params, {})
    t.false_(ok)
    t.matches("filepath", err or "")
    local ok2 = validator.validate_parameters(params, { filepath = "a.txt", max = 5 })
    t.true_(ok2)
    local ok3 = validator.validate_parameters(params, { filepath = "a.txt", max = "x" })
    t.false_(ok3)
  end)

  it("validator 审批决策", function(t)
    local validator = require("NeoAI.tools.validator")
    local cfg = { auto_allow = false, allowed_directories = {}, allowed_param_groups = {} }
    t.true_(validator.check_approval("x", { filepath = "/tmp/f" }, cfg, "prompt"))
    t.false_(validator.check_approval("x", {}, cfg, "auto_allow"))
    t.true_(validator.check_approval("x", {}, cfg, "strict"))
    local cfg_allow = { auto_allow = true, allowed_directories = {}, allowed_param_groups = {} }
    t.false_(validator.check_approval("x", { filepath = "/tmp/f" }, cfg_allow, "prompt"))
  end)

  it("validator 路径/参数安全", function(t)
    local validator = require("NeoAI.tools.validator")
    t.true_(validator.is_path_allowed("/root/NeoAI/a.txt", { "./" }))
    t.true_(validator.is_params_safe({ command = "ls -la" }, { "ls", "grep" }))
    t.false_(validator.is_params_safe({ command = "rm -rf /" }, { "ls", "grep" }))
  end)

  it("packer 分组", function(t)
    local packer = require("NeoAI.tools.packer")
    local grouped = packer.group_by_pack({ { name = "read_file" }, { name = "run_command" }, { name = "lsp_hover" } })
    t.ok(grouped.file)
    t.ok(grouped.system)
    t.ok(grouped.lsp)
    t.eq(1, #grouped.file)
    t.eq(7, #packer.get_all_packs())
    t.not_nil(packer.pack_display_name("file"))
  end)

  it("executor 执行 file_ops", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ tools = { approval = { mode = "auto_allow", per_tool = {} } } })
    local tools = require("NeoAI.tools")
    local registry = require("NeoAI.tools.registry")
    local file_ops = require("NeoAI.tools.builtin.file_ops")
    registry.register_many(file_ops.get_tools())
    local fs = require("NeoAI.utils.fs")
    local path = "/tmp/neoai_test_file.txt"
    fs.write_file(path, "line1\nline2\n")
    tools.execute("read_file", { filepath = path }, {}):then_(function(r)
      t.matches("line1", r)
      print("  read_file done")
    end)
  end)

  it("executor 别名 + file_exists", function(t)
    local tools = require("NeoAI.tools")
    local async = require("NeoAI.utils.async")
    tools.execute("ls", { path = "/tmp" }, {})
      :then_(function() print("  ls done") end)
    tools.execute("file_exists", { filepath = "/tmp/neoai_test_file.txt" }, {})
      :then_(function(r)
        t.eq("true", r)
        print("  file_exists done")
      end)
  end)

  it("executor 未知工具", function(t)
    local tools = require("NeoAI.tools")
    tools.execute("not_a_tool", {}, {}):catch(function(e)
      t.matches("不存在", tostring(e.message))
      print("  unknown done")
    end)
  end)

  it("executor edit_file write", function(t)
    local tools = require("NeoAI.tools")
    tools.execute("edit_file", { filepath = "/tmp/neoai_test_edit.txt", mode = "write", content = "hello" }, {})
      :then_(function(r)
        t.matches("写入", r)
        print("  edit done")
      end)
  end)

  it("shell run_command", function(t)
    local tools = require("NeoAI.tools")
    local registry = require("NeoAI.tools.registry")
    local shell = require("NeoAI.tools.builtin.shell")
    registry.register_many(shell.get_tools())
    tools.execute("run_command", { command = "echo hello-test" }, {})
      :then_(function(r)
        t.matches("hello%-test", r)
        print("  shell done")
      end)
  end)

  it("tool_service 审批通过执行", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ tools = { approval = { mode = "prompt", per_tool = {} } } })
    local tool_service = require("NeoAI.services.tool_service")
    local async = require("NeoAI.utils.async")
    local agent = { id = "test-agent" }
    local called = false
    -- 注入简单工具
    local registry = require("NeoAI.tools.registry")
    local helpers = require("NeoAI.tools.builtin.tool_helpers")
    registry.register(helpers.define_tool(
      "simple_echo", "echo", { type = "object", properties = {}, required = {} },
      function(args, on_success) on_success("echoed") end
    ))
    tool_service.set_approval_ui({
      show = function(config)
        config.on_confirm() -- 自动确认
      end,
      hide = function() end,
    })
    tool_service.execute(agent, "simple_echo", {}, nil, {}):then_(function(r)
      t.eq("echoed", r)
      print("  tool_service done")
    end):catch(function(e)
      print("  tool_service err:", e.message)
      t.true_(false)
    end)
  end)

  it("tool_service 审批拒绝", function(t)
    local tool_service = require("NeoAI.services.tool_service")
    local registry = require("NeoAI.tools.registry")
    local helpers = require("NeoAI.tools.builtin.tool_helpers")
    registry.register(helpers.define_tool("risky_tool", "危险", { type = "object", properties = {}, required = {} }, function(args, on_success) on_success("should not run") end))
    local ran = false
    tool_service.set_approval_ui({
      show = function(config) config.on_cancel("拒绝") end,
      hide = function() end,
    })
    local agent = { id = "a2" }
    tool_service.execute(agent, "risky_tool", {}, nil, {}):then_(function()
      ran = true
      t.true_(false, "不应执行")
    end):catch(function(e)
      t.matches("拒绝", tostring(e.message))
      t.false_(ran)
      print("  rejected done")
    end)
  end)

  it("子 Agent 边界审核", function(t)
    local plan = require("NeoAI.tools.builtin.plan")
    local registry = require("NeoAI.tools.registry")
    local helpers = require("NeoAI.tools.builtin.tool_helpers")
    registry.register(helpers.define_tool("allowed_tool", "允许", nil, function() end))
    plan.reset()
    -- 直接构造子 agent 条目
    local sub_id = "sub_test"
    plan.get_tools() -- ensure loaded
    -- 模拟边界
    plan._allow_tools_for_test(sub_id, { "allowed_tool" })
    local ok = plan.review_tool_call(sub_id, "allowed_tool")
    t.true_(ok)
    local blocked, reason = plan.review_tool_call(sub_id, "not_allowed")
    t.false_(blocked)
    t.matches("驳回", reason or "missing")
  end)
end)
