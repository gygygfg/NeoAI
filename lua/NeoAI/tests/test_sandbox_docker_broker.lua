--- 自研 Unix socket Docker broker 测试（无真实 daemon）
local tests = require("NeoAI.tests")

local function exchange(socket, raw, timeout)
  local uv = vim.uv
  local cli = uv.new_pipe(false)
  local got, done = {}, false
  cli:connect(socket, function(err)
    if err then done = true; return end
    cli:write(raw)
    cli:read_start(function(rerr, data)
      if rerr or not data then done = true; return end
      if #data > 0 then got[#got + 1] = data end
    end)
  end)
  vim.wait(timeout or 3000, function() return done end, 10)
  pcall(function() cli:close() end)
  return table.concat(got)
end

tests.suite("sandbox_docker_broker", function(_, it)
  local broker = require("NeoAI.sandbox.docker.broker")
  local probe = require("NeoAI.sandbox.docker.probe")
  local review = require("NeoAI.sandbox.docker.review")

  it("拒绝策略外的 create（不触达上游）", function(t)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local sock = root .. "/broker.sock"
    probe._set_override({
      tier = "N1", runtime = "podman", userns = true, rootless = true,
      microvm = false, gvisor = false, reasons = {}, at = os.time(),
    })
    broker._set_upstream(function() error("should not be called") end)
    local ok, err = broker.ensure({
      socket_path = sock, upstream_path = root .. "/runtime.sock",
      workspace_roots = { root },
    })
    t.true_(ok, err)
    local body = vim.json.encode({ Image = "alpine", HostConfig = { Privileged = true } })
    local raw = "POST /containers/create HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: "
      .. #body .. "\r\n\r\n" .. body
    local res = exchange(sock, raw)
    t.matches("403", res)
    t.matches("permission denied", res)
    broker.reset(); probe.reset(); review.reset()
    pcall(vim.fn.delete, root, "rf")
  end)

  it("允许 ping 并转发上游响应", function(t)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local sock = root .. "/broker.sock"
    probe._set_override({
      tier = "N1", runtime = "podman", userns = true, rootless = true,
      microvm = false, gvisor = false, reasons = {}, at = os.time(),
    })
    broker._set_upstream(function(req, cb)
      cb(true, 200, "ok", "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
    end)
    local ok, err = broker.ensure({
      socket_path = sock, upstream_path = root .. "/runtime.sock",
      workspace_roots = { root },
    })
    t.true_(ok, err)
    local res = exchange(sock, "GET /_ping HTTP/1.1\r\nHost: docker\r\n\r\n")
    t.matches("HTTP/1.1 200", res)
    t.matches("ok", res)
    broker.reset(); probe.reset()
    pcall(vim.fn.delete, root, "rf")
  end)

  it("容器操作先 inspect/审查：blocked 容器拒绝", function(t)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local sock = root .. "/broker.sock"
    probe._set_override({
      tier = "N1", runtime = "podman", userns = true, rootless = true,
      microvm = false, gvisor = false, reasons = {}, at = os.time(),
    })
    local insp = {
      Id = "abc", Name = "/x", Image = "sha256:i", State = { Running = true },
      Config = { Image = "alpine", Env = {} },
      HostConfig = { Privileged = true, CapDrop = { "ALL" }, Memory = 1, PidsLimit = 1 },
    }
    broker._set_upstream(function(req, cb)
      if req.path:find("/containers/abc/json") then
        cb(true, 200, vim.json.encode(insp), nil)
      else
        cb(true, 200, "ok", "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
      end
    end)
    local ok, err = broker.ensure({
      socket_path = sock, upstream_path = root .. "/runtime.sock",
      workspace_roots = { root },
    })
    t.true_(ok, err)
    local res = exchange(sock, "GET /containers/abc/json HTTP/1.1\r\nHost: docker\r\n\r\n")
    t.matches("403", res)
    broker.reset(); probe.reset(); review.reset()
    pcall(vim.fn.delete, root, "rf")
  end)
end)
