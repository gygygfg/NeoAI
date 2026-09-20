--- 沙箱诊断（合并原 fault + bench）
--- @module NeoAI.sandbox.diag
--- 故障注入（验证恢复/回滚路径）与性能基准（关键路径耗时）。仅测试/诊断使用，默认不改变行为。
--- 原 `sandbox/fault` 与 `sandbox/bench` 保留为兼容 shim（转指本模块）。

local M = {}

-- ========== 故障注入（原 sandbox/fault） ==========

--- 已定义的注入点
M.POINTS = {
  "backend", -- 运行时后端不可用
  "freeze", -- 候选冻结失败
  "publish", -- CAS 发布失败
  "store", -- 持久化写入失败
}

local fstate = {
  active = {}, -- point -> 剩余注入次数
  log = {},
}

--- 在指定点注入 count 次故障
--- @param point string
--- @param count number|nil 默认 1
function M.set(point, count)
  fstate.active[point] = count or 1
end

--- 命中注入点（消费一次）
--- @param point string
--- @return boolean injected
function M.hit(point)
  local n = fstate.active[point]
  if n and n > 0 then
    fstate.active[point] = n - 1
    fstate.log[#fstate.log + 1] = { point = point, at = os.time() }
    return true
  end
  return false
end

--- 是否配置了某注入点
--- @param point string
--- @return boolean
function M.active(point)
  return (fstate.active[point] or 0) > 0
end

--- 注入日志
--- @return table 数组
function M.history()
  return vim.deepcopy(fstate.log)
end

--- 清除全部注入
function M.clear()
  fstate.active = {}
end

-- ========== 性能基准（原 sandbox/bench） ==========

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

--- 重置（测试用）
function M.reset()
  fstate.active = {}
  fstate.log = {}
end

-- ========== 捕获/物化性能基准（暂存堆积回归） ==========

--- 复现「暂存很多文件后 run_command 结束变慢」并给出分段耗时（仅诊断用，会重置沙箱）。
--- 构造 N 个暂存文件 → 物化进 overlay → 捕获。返回物化与捕获主线程耗时，用于回归对比。
--- 注意：会修改 `tools.sandbox.workspace_root` 并 `sandbox.reset()`，不要在运行中的会话里调用。
--- @param opts table|nil { files?: number 暂存文件数，默认 200 }
--- @return table { files, materialize_ms, capture_ms }
function M.bench_capture(opts)
  opts = opts or {}
  local n = tonumber(opts.files) or 200
  local fs = require("NeoAI.utils.fs")
  local config_store = require("NeoAI.kernel.config_store")
  local candidate = require("NeoAI.sandbox.candidate")
  local control = require("NeoAI.sandbox.control")
  local store = require("NeoAI.sandbox.store")
  local sandbox = require("NeoAI.sandbox")
  local dir = fs.canonical(vim.fn.tempname())
  fs.ensure_dir(dir)
  local prev_root = config_store.get("tools.sandbox.workspace_root")
  config_store.set("tools.sandbox.workspace_root", vim.fn.tempname() .. "/sb")
  sandbox.reset()
  local a = control.new_attempt("run_command", {}, {}, { effect = "process" })
  candidate.begin(a, store.root())
  local files = {}
  for i = 1, n do
    local p = dir .. "/f" .. i .. ".txt"
    fs.write_file(p, "base " .. i .. "\n")
    files[#files + 1] = {
      path = p, action = "modify", content = "staged " .. i .. "\n",
      before_hash = "sha256:b" .. i, after_hash = "sha256:s" .. i, mode = 420,
    }
  end
  candidate.merge_candidate({ files = files })
  local base = vim.fn.tempname()
  local upper, work = base .. "/upper", base .. "/work"
  fs.ensure_dir(upper); fs.ensure_dir(work)
  local specs = { { root = dir, upper = upper, work = work, mode = "overlay" } }
  -- 第一次物化（冷）：读取+写入全部暂存文件
  local cold = M.measure(function() candidate.materialize_overlay(specs) end, 1)
  -- 第二次物化（热）：未改动应跳过
  local warm = M.measure(function() candidate.materialize_overlay(specs) end, 1)
  local capture_ms, done = -1, false
  local t0 = vim.uv.hrtime()
  candidate.capture_overlay_async(a.attempt_id, dir, upper):then_(function()
    capture_ms = (vim.uv.hrtime() - t0) / 1e6
    done = true
  end, function() done = true end)
  vim.wait(30000, function() return done end)
  candidate.cleanup(a.attempt_id)
  if prev_root ~= nil then config_store.set("tools.sandbox.workspace_root", prev_root) end
  vim.fn.delete(dir, "rf")
  vim.fn.delete(base, "rf")
  return {
    files = n,
    materialize_cold_ms = cold.total_ms,
    materialize_warm_ms = warm.total_ms,
    capture_ms = capture_ms,
  }
end

return M
