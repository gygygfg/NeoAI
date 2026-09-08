--- MCP JSON-RPC 客户端测试
--- @module NeoAI.tests.test_mcp_client
--- 用内存假传输验证客户端逻辑：id 关联、通知分发、服务器请求应答、initialize 握手。
--- （不依赖真实子进程/网络，跨环境可跑。）

local tests = require("NeoAI.tests")
local async = require("NeoAI.utils.async")
local json = require("NeoAI.utils.json")

--- 构造内存假传输
local function _fake_transport()
  local ft = { sent = {}, open_ = false }
  function ft:open() self.open_ = true end
  function ft:close() self.open_ = false end
  function ft:is_open() return self.open_ end
  function ft:send(s) self.sent[#self.sent + 1] = s end
  return ft
end

--- 提取最近一条已发送 JSON-RPC 的 id
local function _last_id(ft)
  local msg = json.decode(ft.sent[#ft.sent] or "{}")
  return msg and msg.id
end

--- 等待 Deferred settle
local function _wait(d, ms)
  return vim.wait(ms or 4000, function() return d:is_resolved() or not d:is_pending() end)
end

tests.suite("mcp_client", function(_, it)
  it("请求/响应 id 关联并 resolve", function(t)
    local client_mod = require("NeoAI.services.mcp.client")
    local ft = _fake_transport()
    local client = client_mod.new(ft, { name = "t", timeout_ms = 2000 })
    ft:open()
    local d = client:request("tools/list", {})
    local id = _last_id(ft)
    t.not_nil(id, "请求应带 id")
    ft.on_message({ jsonrpc = "2.0", id = id, result = { tools = { { name = "a" } } } })
    t.true_(_wait(d), "请求应 resolve")
    local result = d._state == "resolved" and d._value or nil
    t.eq(1, #result.tools)
    t.eq("a", result.tools[1].name)
  end)

  it("不带 id 的通知只分发，不匹配请求", function(t)
    local client_mod = require("NeoAI.services.mcp.client")
    local ft = _fake_transport()
    local client = client_mod.new(ft, { name = "t" })
    ft:open()
    local got = nil
    client:on_notification("notifications/tools/list_changed", function() got = true end)
    client:notify("notifications/initialized", {})
    ft.on_message({ jsonrpc = "2.0", method = "notifications/tools/list_changed" })
    t.eq(true, got, "通知回调应触发")
  end)

  it("服务器->客户端请求被应答（method not found）", function(t)
    local client_mod = require("NeoAI.services.mcp.client")
    local ft = _fake_transport()
    local client = client_mod.new(ft, { name = "t" })
    ft:open()
    ft.on_message({ jsonrpc = "2.0", id = 99, method = "ping" })
    -- 未注册处理器 → 回 -32601
    local reply = json.decode(ft.sent[#ft.sent])
    t.eq(99, reply.id)
    t.eq(-32601, reply.error.code)
  end)

  it("initialize 握手：请求 + 应答后发 initialized 通知", function(t)
    local client_mod = require("NeoAI.services.mcp.client")
    local ft = _fake_transport()
    local client = client_mod.new(ft, { name = "t" })
    ft:open()
    local d = client:initialize({})
    local req = json.decode(ft.sent[1])
    t.eq("initialize", req.method)
    t.eq("NeoAI", req.params.clientInfo.name)
    local id = req.id
    ft.on_message({ jsonrpc = "2.0", result = { protocolVersion = "2025-06-18", capabilities = {}, serverInfo = { name = "s" } }, id = id })
    t.true_(_wait(d), "initialize 应 resolve")
    -- 握手后应发送 initialized 通知
    local has_init_notify = false
    for _, s in ipairs(ft.sent) do
      local m = json.decode(s)
      if m.method == "notifications/initialized" then has_init_notify = true end
    end
    t.true_(has_init_notify, "应发送 initialized 通知")
    t.true_(client:is_initialized())
  end)

  it("请求在 client close 后被 reject", function(t)
    local client_mod = require("NeoAI.services.mcp.client")
    local ft = _fake_transport()
    local client = client_mod.new(ft, { name = "t", timeout_ms = 5000 })
    ft:open()
    local d = client:request("tools/list", {})
    client:close()
    t.true_(_wait(d), "close 后请求应 settle")
    local err = d._state == "rejected" and d._error or nil
    t.not_nil(err, "应 reject")
    t.matches("关闭", tostring(err.message))
  end)

  it("initialize 使用调用方指定的 timeout_ms（connect_timeout 生效）", function(t)
    local client_mod = require("NeoAI.services.mcp.client")
    local ft = _fake_transport()
    local client = client_mod.new(ft, { name = "t", timeout_ms = 60000 })
    ft:open()
    local captured
    client.request = function(_, _method, _params, opts)
      captured = opts and opts.timeout_ms
      return async.resolve({ protocolVersion = "2025-06-18", capabilities = {}, serverInfo = {} })
    end
    local d = client:initialize({ timeout_ms = 2500 })
    t.true_(_wait(d), "initialize 应 resolve")
    t.eq(2500, captured, "应把 connect_timeout_ms 传给 initialize 请求")
  end)

  it("传输断开（on_exit）拒绝挂起请求并标记失效", function(t)
    local client_mod = require("NeoAI.services.mcp.client")
    local ft = _fake_transport()
    local client = client_mod.new(ft, { name = "t" })
    ft:open()
    local d = client:request("tools/list", {})
    ft.on_exit(1) -- 模拟 stdio 子进程退出
    t.true_(_wait(d), "传输断开后挂起请求应 settle")
    local err = d._state == "rejected" and d._error or nil
    t.not_nil(err, "应 reject")
    t.eq("disconnected", err.kind)
    t.true_(client.transport_dead, "应标记传输失效，以便上层重连")
  end)
end)
