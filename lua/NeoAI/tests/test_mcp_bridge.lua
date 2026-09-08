--- MCP 管理器桥接测试（init → 连接 → 注册 → 调用）
--- @module NeoAI.tests.test_mcp_bridge
--- 用 monkeypatch transports.create 注入内存传输，模拟一次完整 MCP 连接：
--- 验证工具/资源/提示被注册进 registry，且模型可经工具 func 调用远端 tools/call。

local tests = require("NeoAI.tests")
local json = require("NeoAI.utils.json")
local config_store = require("NeoAI.kernel.config_store")
local registry = require("NeoAI.tools.registry")

--- 内存假传输：按 method 返回预设响应
local function _fake_transport()
  local ft = { open_ = true }
  function ft:open() self.open_ = true end
  function ft:close() self.open_ = false end
  function ft:is_open() return self.open_ end
  function ft:send(encoded)
    local msg = json.decode(encoded)
    local id = msg.id
    local result
    if msg.method == "initialize" then
      result = { protocolVersion = "2025-06-18", capabilities = { tools = {} }, serverInfo = { name = "fake" } }
    elseif msg.method == "tools/list" then
      result = { tools = {
        { name = "get_time", description = "查询当前时间", inputSchema = { type = "object", properties = { fmt = { type = "string" } }, required = {} } },
      } }
    elseif msg.method == "tools/call" then
      result = { content = { { type = "text", text = "12:00" } } }
    elseif msg.method == "resources/read" then
      result = { contents = { { uri = "file:///x", text = "resource-body" } } }
    elseif msg.method == "resources/list" then
      result = { resources = { { uri = "file:///x", name = "x", description = "文件 x" } } }
    elseif msg.method == "prompts/list" then
      result = { prompts = { { name = "greet", description = "问候模板" } } }
    else
      result = {}
    end
    if id ~= nil then
      ft.on_message({ jsonrpc = "2.0", id = id, result = result })
    end
  end
  return ft
end

tests.suite("mcp_bridge", function(_, it, before_each)
  before_each(function()
    config_store.load({
      mcp = { enabled = true, servers = {} },
      tools = { builtin = false, approval = { mode = "auto_allow" } },
    })
    local mcp = require("NeoAI.services.mcp")
    mcp.reset()
    registry.reset()
  end)

  it("连接后注册 mcp 工具并可通过 func 调用", function(t)
    local transports = require("NeoAI.services.mcp.transports")
    local orig_create = transports.create
    transports.create = function() return _fake_transport() end

    -- 配置一个服务器并 init
    config_store.load({ mcp = { enabled = true, servers = { demo = { transport = "stdio" } } } })
    local mcp = require("NeoAI.services.mcp")
    mcp.init()
    local ready = vim.wait(4000, function()
      local cfg = mcp.state.servers.demo
      return cfg and cfg.state == "ready"
    end)
    t.true_(ready, "demo 服务器应连上并就绪")

    -- tools/list 已注册为 NeoAI 工具
    local def = registry.get("mcp__demo__get_time")
    t.not_nil(def, "应注册 mcp__demo__get_time")
    t.eq("mcp", def.category)
    t.eq("mcp", def.source)
    t.eq("demo", def.mcp_server)
    t.eq("get_time", def.mcp_tool)

    -- 通过工具 func 调用 tools/call
    local got_success, out = nil
    def.func({ fmt = "%H:%M" }, function(v) got_success = true; out = v end, function(e) out = e end)
    t.true_(vim.wait(4000, function() return got_success ~= nil end), "工具调用应 resolve")
    t.matches("12:00", tostring(out))

    -- 资源/提示浏览工具也已注册
    t.not_nil(registry.get("mcp__demo__list_resources"))
    t.not_nil(registry.get("mcp__demo__read_resource"))
    t.not_nil(registry.get("mcp__demo__list_prompts"))
    t.not_nil(registry.get("mcp__demo__get_prompt"))

    -- 资源读取
    local r_ok, r_str = nil
    registry.get("mcp__demo__read_resource").func({ uri = "file:///x" }, function(v) r_ok = true; r_str = v end, function(e) r_str = e end)
    t.true_(vim.wait(4000, function() return r_ok ~= nil end), "资源读取应 resolve")
    t.matches("resource%-body", tostring(r_str))

    transports.create = orig_create
  end)

  it("清理后 no-op（无服务器不崩溃）", function(t)
    local mcp = require("NeoAI.services.mcp")
    mcp.init()
    local d = mcp.call_tool("nope", "x", {})
    t.true_(vim.wait(4000, function() return d:is_resolved() or not d:is_pending() end), "未知服务器应快速返回")
    t.matches("未知 MCP 服务器", tostring((d._state == "resolved" and d._value) or ""))
  end)

  it("传输无法创建时不进入无限循环（坏配置快速失败）", function(t)
    local mcp = require("NeoAI.services.mcp")
    -- http 无 url：transports.create 返回 nil，_connect 失败
    config_store.load({ mcp = { enabled = true, servers = { bad = { transport = "http" } } } })
    mcp.init()
    local d = mcp.call_tool("bad", "x", {})
    t.true_(vim.wait(2000, function() return not d:is_pending() end), "不可用服务器应在有限时间内 settle，而非无限循环")
    t.matches("连接失败或不可用", tostring((d._state == "resolved" and d._value) or (d._state == "rejected" and d._error and d._error.message) or ""))
  end)

  it("refresh 变更检测：工具名变化才报告 changed", function(t)
    local transports = require("NeoAI.services.mcp.transports")
    local orig_create = transports.create
    -- 可变工具集的假传输：tools/list 返回 ft.tools
    local ft = { open_ = true, tools = {
      { name = "get_time", description = "d", inputSchema = { type = "object", properties = {}, required = {} } },
    } }
    function ft:open() self.open_ = true end
    function ft:close() self.open_ = false end
    function ft:is_open() return self.open_ end
    function ft:send(encoded)
      local msg = json.decode(encoded)
      local result
      if msg.method == "initialize" then
        result = { protocolVersion = "2025-06-18", capabilities = { tools = {} }, serverInfo = { name = "f" } }
      elseif msg.method == "tools/list" then
        result = { tools = ft.tools }
      elseif msg.method == "resources/list" or msg.method == "prompts/list" then
        result = {}
      else
        result = {}
      end
      if msg.id ~= nil then
        ft.on_message({ jsonrpc = "2.0", id = msg.id, result = result })
      end
    end
    transports.create = function() return ft end

    config_store.load({ mcp = { enabled = true, servers = { demo = { transport = "stdio" } } } })
    local mcp = require("NeoAI.services.mcp")
    mcp.reset()
    registry.reset()
    mcp.init()
    t.true_(vim.wait(4000, function() return mcp.state.servers.demo and mcp.state.servers.demo.state == "ready" end), "demo 应就绪")

    -- 工具未变 → changed=false
    local d1 = mcp.refresh("demo")
    t.true_(vim.wait(4000, function() return not d1:is_pending() end), "refresh 应 settle")
    t.eq("resolved", d1._state, "refresh 应 resolve")
    t.eq(false, d1._value, "工具未变化时 changed 应为 false")

    -- 工具名增加 → changed=true
    ft.tools[#ft.tools + 1] = { name = "other", description = "x", inputSchema = { type = "object", properties = {}, required = {} } }
    local d2 = mcp.refresh("demo")
    t.true_(vim.wait(4000, function() return not d2:is_pending() end), "refresh(变化) 应 settle")
    t.eq("resolved", d2._state, "refresh(变化) 应 resolve")
    t.eq(true, d2._value, "工具名变化时 changed 应为 true")

    transports.create = orig_create
  end)
end)
