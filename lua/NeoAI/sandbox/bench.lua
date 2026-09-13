--- 沙箱性能基准
--- @module NeoAI.sandbox.bench
--- 对控制面关键路径做轻量基准，供性能回归与容量评估（设计文档 §12）。
--- 仅测量、不改变行为；数值随负载/硬件变化，测试只做合理性与完成性断言。

local M = {}

--- 测量函数在 iterations 次调用下的耗时
--- @param fn function(i)
--- @param iterations number|nil
--- @return table { iterations, total_ms, per_op_ms }
function M.measure(fn, iterations)
  local n = iterations or 100
  local t0 = vim.uv.hrtime()
  for i = 1, n do fn(i) end
  local elapsed = (vim.uv.hrtime() - t0) / 1e6
  return { iterations = n, total_ms = elapsed, per_op_ms = elapsed / n }
end

--- 运行标准基准
--- @param opts table|nil { iterations? }
--- @return table
function M.run(opts)
  opts = opts or {}
  local n = opts.iterations or 200
  local policy = require("NeoAI.sandbox.policy")
  local control = require("NeoAI.sandbox.control")
  local envelope = require("NeoAI.sandbox.envelope")

  local results = {}
  results.policy_eval = M.measure(function()
    policy.evaluate({ tool = "read_file", effect = "read" })
  end, n)
  results.digest = M.measure(function(i)
    control.hash({ a = i, b = "x", c = { 1, 2, 3 } })
  end, n)
  results.new_attempt = M.measure(function(i)
    control.new_attempt("read_file", { i = i }, {}, { effect = "read" })
  end, n)
  results.envelope_build = M.measure(function(i)
    envelope.build({ command_id = "cmd", decision = "ALLOW", stats = {}, asks = { { id = tostring(i) } } })
  end, n)
  return results
end

return M
