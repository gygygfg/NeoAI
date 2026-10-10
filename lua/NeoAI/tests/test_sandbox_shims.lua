--- 沙箱兼容 shim 专项测试：fault / bench 转发到 diag
--- @module 'NeoAI.tests.test_sandbox_shims'
local tests = require("NeoAI.tests")

tests.suite("sandbox_shims", function(_, it)
  it("fault 为 diag 的兼容 shim", function(t)
    local diag = require("NeoAI.sandbox.observe.diag")
    t.eq(diag, require("NeoAI.sandbox.observe.fault"))
  end)

  it("bench 为 diag 的兼容 shim", function(t)
    local diag = require("NeoAI.sandbox.observe.diag")
    t.eq(diag, require("NeoAI.sandbox.observe.bench"))
  end)
end)
