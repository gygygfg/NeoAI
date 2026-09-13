--- 插件系统测试
--- @module NeoAI.tests.test_plugins
--- 覆盖：依赖等待、替换、禁用、失败回滚、实际消息请求、重复启动、工具重载与热重载。
--- 使用唯一 id/服务名，测试后清理，避免污染已启动的内置插件。

local tests = require("NeoAI.tests")

-- 保存/恢复全局配置，避免用例改动影响后续套件
local function with_config(overrides, fn)
  local config_store = require("NeoAI.kernel.config_store")
  local saved = config_store.get_all()
  config_store.load(overrides)
  local ok, err = pcall(fn)
  config_store.load(saved)
  if not ok then error(err, 0) end
end

tests.suite("plugins", function(_, it)
  it("services.use 未提供时返回 nil，不回退默认模块", function(t)
    local services = require("NeoAI.kernel.services")
    t.nil_(services.use("test.missing_service"))
    t.false_(services.has("test.missing_service"))
  end)

  it("services.wait 依赖等待：provide 后回调", function(t)
    local services = require("NeoAI.kernel.services")
    local name = "test.wait_service"
    services.revoke(name)
    local got = nil
    local cancel = services.wait(name, function(impl) got = impl end)
    t.nil_(got, "提供前不应回调")
    local impl = { ok = true }
    services.provide(name, impl)
    t.eq(impl, got, "提供后应回调且携带实现")
    cancel()
    services.revoke(name)
  end)

  it("plugins 依赖优先启动", function(t)
    local plugins = require("NeoAI.kernel.plugins")
    plugins.unregister("test.dep")
    plugins.unregister("test.main")
    local order = {}
    plugins.register({ id = "test.dep", start = function() order[#order + 1] = "dep" end })
    plugins.register({ id = "test.main", deps = { "test.dep" }, start = function() order[#order + 1] = "main" end })
    local ok, err = plugins.start("test.main")
    t.true_(ok, tostring(err))
    t.deep_eq({ "dep", "main" }, order, "依赖应先于本体启动")
    plugins.unregister("test.main")
    plugins.unregister("test.dep")
  end)

  it("plugins 循环依赖检测", function(t)
    local plugins = require("NeoAI.kernel.plugins")
    plugins.unregister("test.cyc_a")
    plugins.unregister("test.cyc_b")
    plugins.register({ id = "test.cyc_a", deps = { "test.cyc_b" } })
    plugins.register({ id = "test.cyc_b", deps = { "test.cyc_a" } })
    local ok, err = plugins.start("test.cyc_a")
    t.false_(ok, "循环依赖应启动失败")
    t.matches("循环依赖", tostring(err))
    plugins.unregister("test.cyc_a")
    plugins.unregister("test.cyc_b")
  end)

  it("plugins 重复启动幂等", function(t)
    local plugins = require("NeoAI.kernel.plugins")
    plugins.unregister("test.idem")
    local starts, cleans = 0, 0
    plugins.register({
      id = "test.idem",
      start = function() starts = starts + 1; return function() cleans = cleans + 1 end end,
    })
    t.true_(plugins.start("test.idem"))
    t.true_(plugins.start("test.idem"))
    t.eq(1, starts, "重复 start 不应重复执行")
    plugins.stop("test.idem")
    plugins.stop("test.idem")
    t.eq(1, cleans, "重复 stop 不应重复清理")
    plugins.unregister("test.idem")
  end)

  it("plugins 启动失败回滚本次新启动的依赖", function(t)
    local plugins = require("NeoAI.kernel.plugins")
    plugins.unregister("test.roll_dep")
    plugins.unregister("test.roll_bad")
    local dep_cleaned = false
    plugins.register({
      id = "test.roll_dep",
      start = function() return function() dep_cleaned = true end end,
    })
    plugins.register({
      id = "test.roll_bad",
      deps = { "test.roll_dep" },
      start = function() error("boom") end,
    })
    local ok, err = plugins.start("test.roll_bad")
    t.false_(ok)
    t.matches("boom", tostring(err))
    t.true_(dep_cleaned, "失败回滚应清理本次新启动的依赖")
    t.false_(plugins.is_started("test.roll_dep"))
    t.false_(plugins.is_started("test.roll_bad"))
    plugins.unregister("test.roll_bad")
    plugins.unregister("test.roll_dep")
  end)

  it("plugins.start_all 失败时整批回滚", function(t)
    local plugins = require("NeoAI.kernel.plugins")
    plugins.unregister("test.batch_good")
    plugins.unregister("test.batch_bad")
    plugins.register({ id = "test.batch_good", start = function() end })
    plugins.register({ id = "test.batch_bad", start = function() error("batch fail") end })
    local res = plugins.start_all()
    t.false_(res.ok)
    t.eq("test.batch_bad", res.failed)
    t.false_(plugins.is_started("test.batch_good"), "整批回滚应停止本次新启动的插件")
    plugins.unregister("test.batch_bad")
    plugins.unregister("test.batch_good")
  end)

  it("catalog 禁用插件并移除依赖闭包", function(t)
    with_config({ plugins = { disabled = { "ui" } } }, function()
      local catalog = require("NeoAI.plugins.catalog")
      local ids = {}
      for _, id in ipairs(catalog.builtin_ids()) do ids[id] = true end
      t.nil_(ids["ui"], "ui 应被禁用")
      t.nil_(ids["commands"], "依赖 ui 的 commands 应一并移除")
      t.nil_(ids["keymaps"], "依赖 ui 的 keymaps 应一并移除")
      t.true_(ids["services.model_service"], "无依赖的服务应保留")
    end)
  end)

  it("catalog entries=false 禁用插件", function(t)
    with_config({ plugins = { entries = { ["tool.shell"] = false } } }, function()
      local catalog = require("NeoAI.plugins.catalog")
      local ids = {}
      for _, id in ipairs(catalog.builtin_ids()) do ids[id] = true end
      t.nil_(ids["tool.shell"], "tool.shell 应被 entries=false 禁用")
      t.true_(ids["tool.file_ops"], "其它工具插件应保留")
    end)
  end)

  it("catalog entries.module 替换服务实现", function(t)
    with_config({
      plugins = { entries = { ["services.model_service"] = { module = "my_model_provider" } } },
    }, function()
      local catalog = require("NeoAI.plugins.catalog")
      local target = nil
      for _, spec in ipairs(catalog.build_specs()) do
        if spec.id == "services.model_service" then target = spec end
      end
      t.not_nil(target, "应存在 services.model_service 规格")
      t.eq("my_model_provider", target.module, "实现模块应被替换")
    end)
  end)

  it("禁用 services.mcp 时 mcp.connect 一并移除", function(t)
    with_config({ plugins = { disabled = { "services.mcp" } } }, function()
      local catalog = require("NeoAI.plugins.catalog")
      local ids = {}
      for _, id in ipairs(catalog.builtin_ids()) do ids[id] = true end
      t.nil_(ids["services.mcp"])
      t.nil_(ids["mcp.connect"], "依赖 services.mcp 的连接插件应一并移除")
    end)
  end)

  it("tool 插件卸载移除工具并可重复启动恢复", function(t)
    local plugins = require("NeoAI.kernel.plugins")
    local registry = require("NeoAI.tools.registry")
    t.true_(registry.has("run_command"), "默认应已注册 run_command")
    t.true_(plugins.stop("tool.shell"))
    t.false_(registry.has("run_command"), "卸载后工具应被移除")
    t.true_(plugins.start("tool.shell"))
    t.true_(registry.has("run_command"), "重新启动后工具应恢复")
  end)

  it("tool.skills 卸载释放提示段且可重复注册", function(t)
    local plugins = require("NeoAI.kernel.plugins")
    t.true_(plugins.stop("tool.skills"))
    local skills_tool = require("NeoAI.tools.builtin.skills")
    local ok, err = pcall(skills_tool.get_tools)
    t.true_(ok, "提示段应已释放，可重新注册: " .. tostring(err))
    t.true_(plugins.start("tool.skills"))
  end)

  it("实际消息请求：经 chat_service 与本地 mock server 端到端", function(t)
    local server = require("NeoAI.tests.http_server")
    local function mock(client)
      local first = vim.json.encode({ choices = { { delta = { content = "pong" } } } })
      local second = vim.json.encode({ choices = { { delta = {}, finish_reason = "stop" } },
        usage = { prompt_tokens = 3, completion_tokens = 2 } })
      server.respond(client, "data: " .. first .. "\n\ndata: " .. second .. "\n\ndata: [DONE]\n\n")
    end
    server.with_server(mock, function(base_url)
      with_config({
        ai = {
          default_provider = "mock",
          providers = { mock = { api_type = "openai", base_url = base_url, api_key = "test" } },
          modes = { chat = { provider = "mock", model = "test" } },
          model_refresh = { on_startup = false },
        },
        tools = { approval = { mode = "auto_allow", per_tool = {} } },
        session = { save_path = "/tmp/neoai_test_plugins", file = "s.jsonl" },
      }, function()
        local services = require("NeoAI.kernel.services")
        local chat = services.use("services.chat_service")
        t.not_nil(chat, "聊天服务应可用")
        require("NeoAI.core.agent.runtime").reset()
        chat.reset()
        t.await(chat.send_message("ping"))
        local agent = chat.get_current_agent()
        t.not_nil(agent)
        local last = agent.messages[#agent.messages]
        t.eq("assistant", last.role)
        t.eq("pong", last.content, "mock 响应应写入对话")
        chat.reset()
      end)
    end)
  end)

  it("重复启停工具插件后工具数量一致", function(t)
    local plugins = require("NeoAI.kernel.plugins")
    local registry = require("NeoAI.tools.registry")
    local before = registry.count()
    plugins.stop("tool.shell")
    plugins.start("tool.shell")
    t.eq(before, registry.count(), "启停工具插件不应改变工具总数")
  end)

  it("热重载：stop_all 后 start_all 恢复服务与工具", function(t)
    local plugins = require("NeoAI.kernel.plugins")
    local services = require("NeoAI.kernel.services")
    local registry = require("NeoAI.tools.registry")
    local before_tools = registry.count()

    plugins.stop_all()
    local stopped_has_shell = registry.has("run_command")
    local stopped_svc = services.has("services.chat_service")
    local stopped_cmd = vim.fn.exists(":NeoAIChat")

    local res = plugins.start_all()
    local after_tools = registry.count()

    t.false_(stopped_has_shell, "卸载后插件工具应移除")
    t.false_(stopped_svc, "卸载后服务应注销")
    t.eq(0, stopped_cmd, "卸载后命令应删除")
    t.true_(res.ok, tostring(res.error))
    t.eq(before_tools, after_tools, "重启后工具数量应恢复")
    t.true_(services.has("services.chat_service"), "重启后服务应恢复")
    t.true_(registry.has("run_command"), "重启后插件工具应恢复")
  end)
end)
