--- 会话内 Docker API 策略测试
local tests = require("NeoAI.tests")

local function json_req(method, path, obj)
  local body = obj and vim.json.encode(obj) or ""
  return {
    method = method,
    path = path,
    headers = { ["content-type"] = "application/json" },
    body = body,
  }
end

local function create_body(hc, extra)
  local body = { Image = "alpine:latest", HostConfig = hc or {} }
  for k, v in pairs(extra or {}) do body[k] = v end
  return body
end

tests.suite("sandbox_docker_policy", function(_, it)
  local policy = require("NeoAI.sandbox.docker.policy")

  it("安全 create：强制 cap-drop/安全选项/资源限制/标签", function(t)
    local req = json_req("POST", "/containers/create", create_body({}))
    local d = policy.check(req, {
      workspace_roots = { "/work" },
      labels = { ["neoai.sandbox.owner"] = "me" },
      limits = { memory_bytes = 1024, pids = 10, nano_cpus = 1 },
    })
    t.true_(d.allow, d.reason)
    local body = vim.json.decode(d.request.body)
    t.eq("ALL", body.HostConfig.CapDrop[1])
    t.eq(0, #body.HostConfig.CapAdd)
    t.true_(body.HostConfig.SecurityOpt[1]:find("no%-new%-privileges") ~= nil)
    t.eq(1024, body.HostConfig.Memory)
    t.eq(10, body.HostConfig.PidsLimit)
    t.eq("me", body.Labels["neoai.sandbox.owner"])
  end)

  it("拒绝 Privileged / CapAdd / 设备 / 发布端口 / host pid", function(t)
    local cases = {
      { { Privileged = true }, "PRIVILEGED_DENIED" },
      { { CapAdd = { "SYS_ADMIN" } }, "CAP_ADD_DENIED" },
      { { Devices = { { PathOnHost = "/dev/sda" } } }, "DEVICES_DENIED" },
      { { PortBindings = { ["80/tcp"] = { { HostPort = "8080" } } } }, "PORT_BINDINGS_DENIED" },
      { { PidMode = "host" }, "PIDMODE_DENIED" },
    }
    for _, c in ipairs(cases) do
      local d = policy.check(json_req("POST", "/containers/create", create_body(c[1])), {
        workspace_roots = { "/work" },
      })
      t.false_(d.allow, "应拒绝: " .. c[2])
      t.eq(c[2], d.reason)
    end
  end)

  it("bind 只允许 workspace 内路径，拒绝宿主敏感路径", function(t)
    local ok = policy.check(json_req("POST", "/containers/create", create_body({
      Binds = { "/work/project:/data:ro" },
    })), { workspace_roots = { "/work/project" }, allow_binds = true })
    t.true_(ok.allow, ok.reason)
    local bad = policy.check(json_req("POST", "/containers/create", create_body({
      Binds = { "/etc:/host:ro" },
    })), { workspace_roots = { "/work" }, allow_binds = true })
    t.false_(bad.allow)
    t.eq("BIND_OUTSIDE_WORKSPACE", bad.reason)
    local disabled = policy.check(json_req("POST", "/containers/create", create_body({
      Binds = { "/work:/data" },
    })), { workspace_roots = { "/work" } })
    t.eq("BINDS_DISABLED", disabled.reason)
  end)

  it("网络：host 仅允许会话 netns；自定义网络拒绝", function(t)
    local base = { workspace_roots = { "/work" } }
    local host_deny = policy.check(json_req("POST", "/containers/create", create_body({ NetworkMode = "host" })), base)
    t.eq("NETWORK_MODE_DENIED:host", host_deny.reason)
    local host_ok = policy.check(json_req("POST", "/containers/create", create_body({ NetworkMode = "host" })),
      vim.tbl_extend("force", base, { session_netns = true }))
    t.true_(host_ok.allow, host_ok.reason)
    local custom = policy.check(json_req("POST", "/containers/create", create_body({ NetworkMode = "my-net" })), base)
    t.eq("NETWORK_MODE_DENIED:my-net", custom.reason)
  end)

  it("endpoint 白名单：拒绝 exec/build/swarm/volumes", function(t)
    local ctx = { workspace_roots = { "/work" } }
    for _, p in ipairs({ "/build", "/swarm/init", "/volumes/create", "/containers/abc/exec" }) do
      local d = policy.check(json_req("POST", p, {}), ctx)
      t.false_(d.allow, p)
    end
  end)

  it("镜像拉取仅允许 registry allowlist，禁止 fromSrc", function(t)
    local ctx = { workspace_roots = { "/work" } }
    local ok = policy.check(json_req("POST", "/images/create?fromImage=alpine&tag=latest", nil), ctx)
    t.true_(ok.allow, ok.reason)
    local deny = policy.check(json_req("POST", "/images/create?fromImage=evil.example/x&tag=latest", nil), ctx)
    t.eq("REGISTRY_DENIED:evil.example", deny.reason)
    local src = policy.check(json_req("POST", "/images/create?fromSrc=-", nil), ctx)
    t.eq("IMAGE_FROM_SRC_DENIED", src.reason)
  end)
end)
