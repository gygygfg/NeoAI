--- 自动档位探测测试
local tests = require("NeoAI.tests")

tests.suite("sandbox_docker_probe", function(_, it)
  local probe = require("NeoAI.sandbox.docker.probe")

  it("N0：无 rootless runtime", function(t)
    probe._set_override({
      tier = "N0", runtime = nil, userns = true, rootless = false,
      microvm = false, gvisor = false, reasons = { "NO_ROOTLESS_RUNTIME" }, at = os.time(),
    })
    t.eq("N0", probe.tier())
    t.false_(probe.available())
    t.eq("NO_ROOTLESS_RUNTIME", probe.status().reasons[1])
    probe.reset()
  end)

  it("N1：rootless 会话；microVM/gVisor 提升 N2", function(t)
    probe._set_override({
      tier = "N1", runtime = "podman", userns = true, rootless = true,
      microvm = false, gvisor = false, reasons = {}, at = os.time(),
    })
    t.eq("N1", probe.tier())
    t.true_(probe.available())
    probe._set_override({
      tier = "N2", runtime = "podman", userns = true, rootless = true,
      microvm = true, gvisor = false, virt = "kata", reasons = {}, at = os.time(),
    })
    t.eq("N2", probe.tier())
    t.true_(probe.status().microvm)
    probe.reset()
  end)
end)
