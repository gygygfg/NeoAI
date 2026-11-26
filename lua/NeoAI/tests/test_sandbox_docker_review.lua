--- 会话内容器安全审查测试
local tests = require("NeoAI.tests")

local function insp(over)
  local base = {
    Id = "abc",
    Name = "/demo",
    Image = "sha256:img",
    State = { Running = true },
    Config = { Image = "alpine", Env = { "A=1" } },
    HostConfig = {
      CapDrop = { "ALL" },
      Memory = 1024 * 1024,
      PidsLimit = 128,
      NetworkMode = "bridge",
    },
    Mounts = {},
  }
  return vim.tbl_deep_extend("force", base, over or {})
end

tests.suite("sandbox_docker_review", function(_, it)
  local review = require("NeoAI.sandbox.docker.review")

  it("安全容器：safe；危险参数：blocked", function(t)
    t.eq("safe", review.evaluate(insp(), { workspace_roots = { "/work" } }).level)
    t.eq("blocked", review.evaluate(insp({ HostConfig = { Privileged = true } }), {}).level)
    t.eq("blocked", review.evaluate(insp({ HostConfig = { PidMode = "host" } }), {}).level)
    t.eq("blocked", review.evaluate(insp({ HostConfig = { CapAdd = { "CAP_SYS_ADMIN" } } }), {}).level)
    t.eq("blocked", review.evaluate(insp({ HostConfig = { PortBindings = { ["80/tcp"] = {} } } }), {}).level)
  end)

  it("敏感项：secret env / 无资源限制 / 非 workspace 挂载 -> sensitive", function(t)
    local a = review.evaluate(insp({ Config = { Image = "alpine", Env = { "API_TOKEN=x" } } }), {})
    t.eq("sensitive", a.level)
    local b = review.evaluate(insp({
      HostConfig = { CapDrop = { "ALL" }, Memory = 0, PidsLimit = 0, NetworkMode = "bridge" },
    }), {})
    t.eq("sensitive", b.level)
    local c = review.evaluate(insp({
      HostConfig = { CapDrop = { "ALL" }, Memory = 1, PidsLimit = 1, NetworkMode = "bridge", Binds = { "/data:/data" } },
    }), { workspace_roots = { "/work" } })
    t.eq("sensitive", c.level)
  end)

  it("digest 随安全字段变化；inspect 脱敏 env/mount 源", function(t)
    local a = review.evaluate(insp(), {})
    local b = review.evaluate(insp({ HostConfig = { CapDrop = { "ALL" }, Memory = 2048, PidsLimit = 128, NetworkMode = "bridge" } }), {})
    t.not_eq(a.digest, b.digest)
    local red = review.redact_inspect(insp({ Config = { Image = "x", Env = { "TOKEN=secret" } }, Mounts = { { Type = "bind", Source = "/home/me/x", Destination = "/x" } } }))
    t.eq("TOKEN=<redacted>", red.Config.Env[1])
    t.eq("<redacted>", red.Mounts[1].Source)
  end)

  it("审批绑定 digest，撤销后失效", function(t)
    review.reset()
    local v = review.evaluate(insp(), {})
    t.false_(review.is_approved("abc", v.digest))
    t.true_(review.approve("abc", v.digest))
    t.true_(review.is_approved("abc", v.digest))
    t.false_(review.is_approved("abc", "other"))
    t.true_(review.revoke("abc"))
    t.false_(review.is_approved("abc", v.digest))
  end)

  it("操作矩阵：blocked 全拒；sensitive 需批准；safe 可生命周期", function(t)
    t.false_(review.operation_allowed("blocked", "inspect"))
    t.true_(review.operation_allowed("safe", "lifecycle", {}))
    t.true_(review.operation_allowed("safe", "logs", {}))
    t.false_(review.operation_allowed("sensitive", "logs", {}))
    t.true_(review.operation_allowed("sensitive", "logs", { approved = true }))
    t.false_(review.operation_allowed("safe", "destructive", { owned = false }))
    t.true_(review.operation_allowed("safe", "destructive", { owned = true }))
  end)
end)
