--- 沙箱网络边界（沙箱外视角 + 真实 bwrap）
--- @module NeoAI.tests.test_sandbox_boundary_net
--- 覆盖：宿主过滤代理本机拦截与服务进程身份；裸 TCP 基线（设计边界）；沙箱内监听端口反向
--- 暴露；DNS；端口+服务进程粒度弹窗端到端（批准放行 / 拒绝拦截）。全部使用本地 mock，离线。

local tests = require("NeoAI.tests")
local H = require("NeoAI.tests.sandbox_boundary_helpers")
local with_config = H.with_config

--- 宿主侧 TCP echo 服务（回环随机端口）
local function host_echo()
  local srv = vim.uv.new_tcp()
  srv:bind("127.0.0.1", 0)
  local port = srv:getsockname().port
  srv:listen(16, function(err)
    if err then return end
    local cli = vim.uv.new_tcp()
    srv:accept(cli)
    cli:read_start(function(rerr, data)
      if rerr or not data then pcall(function() cli:close() end); return end
      pcall(function() cli:write(data) end)
    end)
  end)
  return port, function() pcall(function() srv:close() end) end
end

--- 在真实沙箱内执行 run_command（full path，含代理注入）。
local function run_in_sandbox(cmd, timeout_ms)
  local out, done = nil, false
  require("NeoAI.tools").execute("run_command", { command = cmd, description = "t" }, {})
    :then_(function(v) out = v; done = true end,
      function(e) out = "ERR:" .. tostring(e and e.message or e); done = true end)
  vim.wait(timeout_ms or 20000, function() return done end, 50)
  return tostring(out)
end

tests.suite("sandbox_boundary_net", function(_, it)
  it("宿主过滤代理：本机目标弹窗展示服务进程身份，批准后放行", function(t)
    local hp = require("NeoAI.sandbox.host_proxy")
    local nc = require("NeoAI.sandbox.net_consent")
    hp.reset(); nc.reset()
    local port, close_srv = host_echo()
    local seen
    nc.set_ui({ show = function(ctx, decide)
      seen = ctx.service
      decide("allow_once")
    end })
    local addr = hp.start("127.0.0.1", 0)
    local cli = vim.uv.new_tcp()
    local resp, done = {}, false
    cli:connect(addr.host, addr.port, function(err)
      if err then done = true; return end
      cli:write(("CONNECT 127.0.0.1:%d HTTP/1.1\r\n\r\n"):format(port))
      cli:read_start(function(e, d)
        if e or not d then done = true; return end
        if #d > 0 then resp[#resp + 1] = d end
      end)
    end)
    vim.wait(5000, function() return done end, 20)
    t.matches("200 Connection Established", table.concat(resp), "批准后应放行")
    t.not_nil(seen, "弹窗应携带服务进程身份")
    t.not_nil(seen.comm, "服务身份应含进程名")
    pcall(function() cli:close() end)
    hp.stop(); close_srv(); hp.reset(); nc.reset()
  end)

  it("[设计边界基线] 裸 TCP 不经代理可直连宿主本机端口", function(t)
    if not H.bwrap() or not H.has("python3") then return end
    local port, close_srv = host_echo()
    with_config({ tools = { approval = { mode = "auto_allow" },
      sandbox = { enabled = true, fail_closed = true, mode = "dry_run", resident = { enabled = true } } } }, function()
      local out = run_in_sandbox(("python3 -c \"import socket;s=socket.create_connection(('127.0.0.1',%d),3);s.sendall(b'ping');print('RAW_OK',s.recv(16));s.close()\""):format(port))
      -- 固化基线：裸 TCP（不认代理）在共享 netns 下可直达宿主本机——应用层过滤无法覆盖。
      t.matches("RAW_OK", out, "基线：裸 TCP 应可达宿主本机（设计边界），实际: " .. out)
    end)
    close_srv()
  end)

  it("反向暴露：沙箱内监听的端口宿主可连接（共享 netns）", function(t)
    if not H.bwrap() or not H.has("python3") then return end
    local resident = require("NeoAI.sandbox.resident")
    if not resident.available() then return end
    local port = 38991
    with_config({ tools = { approval = { mode = "auto_allow" },
      sandbox = { enabled = true, fail_closed = true, mode = "dry_run", resident = { enabled = true } } } }, function()
      require("NeoAI.sandbox").reset()
      run_in_sandbox("python3 -m http.server " .. port .. " --bind 127.0.0.1 >/tmp/.neoai_b2.log 2>&1 & echo started")
      vim.wait(1500)
      local cli = vim.uv.new_tcp()
      local connected, done = false, false
      cli:connect("127.0.0.1", port, function(err)
        connected = (err == nil); done = true
      end)
      vim.wait(5000, function() return done end, 20)
      t.true_(connected, "宿主应能连入沙箱内监听端口（共享 netns 基线）")
      pcall(function() cli:close() end)
      run_in_sandbox("pkill -f 'http.server " .. port .. "' >/dev/null 2>&1; true")
      resident.stop({ timeout_ms = 5000 })
    end)
  end)

  it("DNS：沙箱内可解析 localhost（resolv.conf 净化后仍可用）", function(t)
    if not H.bwrap() or not H.has("python3") then return end
    with_config({ tools = { approval = { mode = "auto_allow" },
      sandbox = { enabled = true, fail_closed = true, mode = "dry_run", resident = { enabled = true } } } }, function()
      local out = run_in_sandbox("python3 -c \"import socket;print('DNS_OK',socket.getaddrinfo('localhost',80)[0][4][0])\"")
      t.matches("DNS_OK", out, "应能解析 localhost，实际: " .. out)
    end)
  end)

  it("端口+服务进程粒度弹窗端到端：拒绝拦截 / 批准放行", function(t)
    if not H.bwrap() or not H.has("python3") or not H.has("curl") then return end
    local resident = require("NeoAI.sandbox.resident")
    if not resident.available() then return end
    local hp = require("NeoAI.sandbox.host_proxy")
    local nc = require("NeoAI.sandbox.net_consent")
    -- 宿主侧 HTTP 服务（python3），comm 可识别
    local port = 38992
    local srv = vim.fn.jobstart({ "python3", "-m", "http.server", tostring(port), "--bind", "127.0.0.1" },
      { detach = false })
    t.true_(srv > 0, "应能启动宿主 mock 服务")
    vim.wait(1200)
    with_config({ tools = { approval = { mode = "auto_allow" },
      sandbox = { enabled = true, fail_closed = true, mode = "dry_run", resident = { enabled = true } } } }, function()
      require("NeoAI.sandbox").reset()
      nc.reset(); hp.reset()
      local owner_comm
      -- 1) 拒绝：应拦截
      nc.set_ui({ show = function(ctx, decide) owner_comm = ctx.service and ctx.service.comm; decide("deny") end })
      local denied = run_in_sandbox(("curl -s -m 5 -o /dev/null -w '%%{http_code}' http://127.0.0.1:%d/"):format(port))
      t.matches("403", denied, "拒绝时经代理应返回 403，实际: " .. denied)
      t.not_nil(owner_comm, "弹窗应携带宿主服务进程身份")
      -- 2) 批准：应放行
      nc.set_ui({ show = function(_, decide) decide("allow_once") end })
      local ok = run_in_sandbox(("curl -s -m 5 -o /dev/null -w '%%{http_code}' http://127.0.0.1:%d/"):format(port))
      t.matches("200", ok, "批准后应放行（200），实际: " .. ok)
      resident.stop({ timeout_ms = 5000 })
    end)
    pcall(vim.fn.jobstop, srv)
  end)
end)
