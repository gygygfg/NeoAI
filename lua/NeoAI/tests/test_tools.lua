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

  it("AUTO 模式自动允许所有工具调用", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ tools = { approval = { mode = "prompt", per_tool = {} } } })
    local tool_service = require("NeoAI.services.tool_service")
    tool_service.reset()
    local registry = require("NeoAI.tools.registry")
    local helpers = require("NeoAI.tools.builtin.tool_helpers")
    registry.register(helpers.define_tool(
      "auto_tool", "自动", { type = "object", properties = {}, required = {} },
      function(args, on_success) on_success("ran") end
    ))
    local shown = false
    tool_service.set_approval_ui({
      show = function() shown = true end,
      hide = function() end,
    })
    t.false_(tool_service.is_auto_mode())
    t.true_(tool_service.set_auto_mode(true), "应开启 AUTO 模式")
    t.true_(tool_service.is_auto_mode())
    local agent = { id = "auto-agent" }
    local ran = false
    tool_service.execute(agent, "auto_tool", {}, nil, {}):then_(function(r)
      t.eq("ran", r)
      ran = true
    end):catch(function(e)
      t.true_(false, "AUTO 模式不应失败: " .. tostring(e.message))
    end)
    local waited = vim.wait(2000, function() return ran end)
    t.true_(waited, "AUTO 模式应直接执行工具")
    t.false_(shown, "AUTO 模式不应弹审批窗")
    -- 关闭后恢复弹窗审批
    t.false_(tool_service.set_auto_mode(false))
    t.false_(tool_service.is_auto_mode())
    tool_service.reset()
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

  it("审批超时拒绝而非永久挂起", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      tools = { approval = { mode = "prompt", per_tool = {}, timeout_ms = 100 } },
    })
    local tool_service = require("NeoAI.services.tool_service")
    local registry = require("NeoAI.tools.registry")
    local helpers = require("NeoAI.tools.builtin.tool_helpers")
    registry.register(helpers.define_tool(
      "timeout_tool", "超时工具", { type = "object", properties = {}, required = {} },
      function(args, on_success) on_success("不应执行") end
    ))
    -- 模拟审批 UI 永不回调（弹窗被覆盖/丢失场景）：此前会永久挂起
    tool_service.set_approval_ui({
      show = function() end,
      hide = function() end,
    })
    local agent = { id = "timeout-agent" }
    local settled = false
    tool_service.execute(agent, "timeout_tool", {}, nil, {}):then_(function()
      t.true_(false, "超时工具不应被执行")
    end):catch(function(e)
      settled = true
      t.matches("审批超时", tostring(e.message))
      print("  approval timeout done")
    end)
    local got = vim.wait(2000, function() return settled end)
    t.true_(got, "审批超时应按时拒绝而非永久挂起")
    tool_service.reset()
  end)

  it("ensure_buffer 后台加载未打开的文件", function(t)
    local helpers = require("NeoAI.tools.builtin.tool_helpers")
    local fs = require("NeoAI.utils.fs")
    local path = "/tmp/neoai_bg_buffer_test.lua"
    fs.write_file(path, "local x = 1\n")
    local cur = vim.api.nvim_get_current_buf()
    t.eq(-1, vim.fn.bufnr(path), "文件应尚未打开")
    local buf = helpers.ensure_buffer(path)
    t.not_nil(buf, "应返回加载后的 bufnr")
    t.eq(buf, vim.fn.bufnr(path))
    t.true_(vim.api.nvim_buf_is_loaded(buf), "buffer 应已加载")
    t.eq(cur, vim.api.nvim_get_current_buf(), "不应切换当前窗口/buffer")
    t.eq("lua", vim.bo[buf].filetype, "后台加载后应补齐 filetype")
  end)

  it("parse_file 自动后台打开未加载文件", function(t)
    local registry = require("NeoAI.tools.registry")
    registry.reset()
    local executor = require("NeoAI.tools.executor")
    local tree_ops = require("NeoAI.tools.builtin.tree_ops")
    registry.register_many(tree_ops.get_tools())
    local fs = require("NeoAI.utils.fs")
    local path = "/tmp/neoai_bg_parse.lua"
    fs.write_file(path, "local function f() end\nf()\n")
    t.eq(-1, vim.fn.bufnr(path), "文件应尚未打开")
    local done = false
    executor.execute("parse_file", { filepath = path }, {}):then_(function(r)
      t.matches("root", r)
      done = true
    end, function(e)
      t.true_(false, "不应失败: " .. tostring(e))
      done = true
    end)
    local waited = vim.wait(2000, function() return done end)
    t.true_(waited, "parse_file 应后台加载文件后解析成功")
  end)

  it("lsp_hover 无客户端时立即拒绝而非挂起", function(t)
    local registry = require("NeoAI.tools.registry")
    registry.reset()
    local executor = require("NeoAI.tools.executor")
    local lsp_ops = require("NeoAI.tools.builtin.lsp_ops")
    registry.register_many(lsp_ops.get_tools())
    local fs = require("NeoAI.utils.fs")
    local path = "/tmp/neoai_bg_lsp.txt"
    fs.write_file(path, "hello\n")
    local done = false
    executor.execute("lsp_hover", { filepath = path, line = 1, col = 1 }):then_(function(r)
      done = true
      t.true_(false, "无客户端不应成功: " .. tostring(r))
    end, function(e)
      t.matches("无 LSP 客户端", tostring(e))
      done = true
    end)
    local waited = vim.wait(2000, function() return done end)
    t.true_(waited, "lsp_hover 应立刻拒绝（无客户端），不得挂起")
  end)

  it("persist_buffer 仅写回后台加载的 buffer", function(t)
    local helpers = require("NeoAI.tools.builtin.tool_helpers")
    local fs = require("NeoAI.utils.fs")
    -- 后台加载：修改后应落盘
    local bg_path = "/tmp/neoai_bg_persist.txt"
    fs.write_file(bg_path, "bg-original\n")
    local bg = helpers.ensure_buffer(bg_path)
    t.true_(helpers.is_background_loaded(bg))
    pcall(vim.api.nvim_buf_set_text, bg, 0, 0, 0, -1, { "bg-persisted" })
    local saved, err = helpers.persist_buffer(bg)
    t.true_(saved, "后台 buffer 应可保存: " .. tostring(err))
    t.eq("bg-persisted", fs.read_file(bg_path):match("[^\r\n]+"))
    -- 用户打开的 buffer：persist 应是 no-op，不覆盖磁盘
    local open_path = "/tmp/neoai_bg_open.txt"
    fs.write_file(open_path, "open-original\n")
    local open_buf = vim.fn.bufadd(open_path)
    vim.cmd("buffer " .. open_buf)
    pcall(vim.api.nvim_buf_set_text, open_buf, 0, 0, 0, -1, { "user-unsaved" })
    t.false_(helpers.is_background_loaded(open_buf))
    local saved2 = helpers.persist_buffer(open_buf)
    t.true_(saved2, "用户 buffer 不应被写、也不应报错")
    t.eq("open-original", fs.read_file(open_path):match("[^\r\n]+"), "用户未保存改动不应落盘")
  end)

  it("delete_node 对后台加载文件修改后落盘", function(t)
    local registry = require("NeoAI.tools.registry")
    registry.reset()
    local executor = require("NeoAI.tools.executor")
    local tree_ops = require("NeoAI.tools.builtin.tree_ops")
    registry.register_many(tree_ops.get_tools())
    local fs = require("NeoAI.utils.fs")
    local path = "/tmp/neoai_bg_delete.lua"
    fs.write_file(path, "local keep = 1\nlocal remove = 2\n")
    local done = false
    executor.execute("delete_node", { filepath = path, line = 2, col = 1 }):then_(function(r)
      t.matches("已删除", r)
      done = true
    end, function(e)
      t.true_(false, "不应失败: " .. tostring(e))
      done = true
    end)
    local waited = vim.wait(2000, function() return done end)
    t.true_(waited, "delete_node 应成功")
    local content = fs.read_file(path)
    t.matches("local keep", content or "")
    t.eq(nil, content:find("remove", 1, true), "删除应从磁盘生效")
  end)

  it("query_tree 合法字段名查询成功", function(t)
    local registry = require("NeoAI.tools.registry")
    registry.reset()
    local executor = require("NeoAI.tools.executor")
    local tree_ops = require("NeoAI.tools.builtin.tree_ops")
    registry.register_many(tree_ops.get_tools())
    local fs = require("NeoAI.utils.fs")
    local path = "/tmp/neoai_bg_query.lua"
    fs.write_file(path, "local obj = tbl.field\nprint('hi')\n")
    local done = false
    executor.execute("query_tree", {
      filepath = path,
      query = "(dot_index_expression table: (identifier) @obj field: (identifier) @field)",
    }):then_(function(r)
      t.matches("obj", r)
      t.matches("field", r)
      done = true
    end, function(e)
      t.true_(false, "合法 query 不应失败: " .. tostring(e))
      done = true
    end)
    local waited = vim.wait(2000, function() return done end)
    t.true_(waited, "query_tree 应成功")
  end)

  it("query_tree 非法字段名返回纠错提示", function(t)
    local registry = require("NeoAI.tools.registry")
    registry.reset()
    local executor = require("NeoAI.tools.executor")
    local tree_ops = require("NeoAI.tools.builtin.tree_ops")
    registry.register_many(tree_ops.get_tools())
    local fs = require("NeoAI.utils.fs")
    local path = "/tmp/neoai_bg_query.lua"
    fs.write_file(path, "local obj = tbl.field\n")
    local done = false
    executor.execute("query_tree", {
      filepath = path,
      query = "(dot_index_expression object: (identifier) @obj field: (identifier) @field)",
    }):then_(function(r)
      t.true_(false, "非法字段名不应成功: " .. tostring(r))
      done = true
    end, function(e)
      t.matches("query 解析失败", tostring(e))
      t.matches("有效字段名", tostring(e))
      t.matches("table", tostring(e), "纠错提示应包含合法字段名 table")
      done = true
    end)
    local waited = vim.wait(2000, function() return done end)
    t.true_(waited, "query_tree 应返回纠错提示")
  end)

  it("lsp 请求服务器无响应时按请求级超时快速拒绝", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.set("tools.lsp.timeout_ms", 200)
    local registry = require("NeoAI.tools.registry")
    registry.reset()
    local executor = require("NeoAI.tools.executor")
    local lsp_ops = require("NeoAI.tools.builtin.lsp_ops")
    registry.register_many(lsp_ops.get_tools())
    local fs = require("NeoAI.utils.fs")
    local path = "/tmp/neoai_lsp_timeout.lua"
    fs.write_file(path, "local x = 1\n")
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    vim.bo[buf].filetype = "lua"
    -- 模拟"已附加但永不响应"的服务器：buf_request 返回非空客户端映射但从不回调。
    -- 修复前工具会挂到 executor 超时（默认 30s）；现在应按请求级超时快速失败。
    local orig = vim.lsp.buf_request
    vim.lsp.buf_request = function(bnr, method, params, cb)
      return { [1] = 1 }
    end
    local done = false
    executor.execute("lsp_type_definition", { filepath = path, line = 5, col = 9 }):then_(function(r)
      t.true_(false, "不应成功: " .. tostring(r))
      done = true
    end, function(e)
      t.matches("超时", tostring(e))
      done = true
    end)
    local waited = vim.wait(1500, function() return done end)
    t.true_(waited, "应快速按请求超时拒绝，而非挂到 executor 超时")
    vim.lsp.buf_request = orig
    config_store.set("tools.lsp.timeout_ms", nil)
  end)

  it("environment: 无 git 工作树时禁用 git 工具，进入后恢复", function(t)
    local env = require("NeoAI.tools.environment")
    local tool_loop = require("NeoAI.core.agent.tool_loop")
    local tools = {
      git_status = { description = "git" },
      git_diff = { description = "git" },
      list_files = { description = "ws" },
      read_file = { description = "generic" },
    }
    local agent = { tools = tools }
    local function def_names()
      local out = {}
      for _, d in ipairs(tool_loop._tool_definitions(agent)) do
        out[#out + 1] = d["function"].name
      end
      table.sort(out)
      return out
    end

    local cwd = vim.fn.getcwd()
    local tmp = "/tmp/neoai_env_test"
    vim.fn.mkdir(tmp, "p")
    vim.cmd("cd " .. tmp)
    local names_no_git = def_names()
    vim.cmd("cd " .. cwd) -- 先恢复 cwd 再断言，断言失败也不影响后续测试
    t.true_(vim.tbl_contains(names_no_git, "read_file"), "通用工具应保留")
    t.true_(vim.tbl_contains(names_no_git, "list_files"), "工作区工具应保留（cwd 存在）")
    t.false_(vim.tbl_contains(names_no_git, "git_status"), "无 git 目录时 git 工具应禁用")
    t.false_(vim.tbl_contains(names_no_git, "git_diff"), "无 git 目录时 git 工具应禁用")

    local names_restored = def_names()
    t.eq(env.git_available(), vim.tbl_contains(names_restored, "git_status"),
      "git 工具暴露与否应与 git 环境一致")
  end)
end)
