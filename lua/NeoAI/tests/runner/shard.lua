--- NeoAI 测试运行器：分片与清单解析
--- @module 'NeoAI.tests.runner.shard'
--- 提供纯函数：LPT 贪心分片（可测、可复现）与发现子进程清单输出解析
--- （`SUITE <name> <cases>` / `LOADFAIL:: <msg>`）。

local M = {}

--- LPT 贪心分片：把套件按权重降序分配到当前负载最小的分片。
--- 纯函数，便于单测；权重单位不限（ms 或用例数均可）。
--- @param suites table[] { name, cases }
--- @param workers number
--- @param weights table|nil name -> number（缺省用 cases）
--- @return table[] bins，长度 workers，元素为套件数组
--- @return number[] loads 各分片估算负载
function M.shard(suites, workers, weights)
  workers = math.max(1, math.floor(tonumber(workers) or 1))
  weights = weights or {}
  local bins, loads = {}, {}
  for i = 1, workers do
    bins[i] = {}
    loads[i] = 0
  end
  local indexed = {}
  for _, s in ipairs(suites or {}) do
    local w = tonumber(weights[s.name]) or tonumber(s.cases) or 1
    if w <= 0 then w = 1 end
    indexed[#indexed + 1] = { suite = s, weight = w }
  end
  -- 权重降序；同权重按名字稳定排序，保证结果可复现。
  table.sort(indexed, function(a, b)
    if a.weight ~= b.weight then return a.weight > b.weight end
    return a.suite.name < b.suite.name
  end)
  for _, item in ipairs(indexed) do
    local target = 1
    for i = 2, workers do
      if loads[i] < loads[target] then target = i end
    end
    bins[target][#bins[target] + 1] = item.suite
    loads[target] = loads[target] + item.weight
  end
  -- 分片内按名字排序，便于报告稳定。
  for i = 1, workers do
    table.sort(bins[i], function(a, b) return a.name < b.name end)
  end
  return bins, loads
end

--- 解析清单子进程输出：`SUITE <name> <cases> [<module>]` 与 `LOADFAIL:: <msg>`
--- @param output string|nil
--- @return table[] suites（元素 { name, cases, module? }）
--- @return string[] load_errors
function M.parse_manifest(output)
  local suites = {}
  -- 归一化：headless 的 `print` 在超宽行（80 列边界）可能不落换行，使下一条 `SUITE` 粘在
  -- 上一条 module 尾部（实测 `...promptSUITE sandbox_ops 58 ...`）。先把这种粘连拆回独立行，
  -- 否则下一个套件会整条丢失（其名字被吞进上一条的 module）。
  local out = (output or ""):gsub("(%S)SUITE (%S+ %d+)", "%1\nSUITE %2")
  -- 仅在同一行内解析可选 module 字段（`[^\n]*` 不跨行）。
  for name, cases, rest in out:gmatch("SUITE (%S+) (%d+)([^\n]*)") do
    local mod = rest:match("^%s*(%S+)")
    -- module 名只含字母/数字/下划线/点；异常内容（残留粘连/折行）一律丢弃，退回「加载全部」。
    if mod and not mod:match("^[%w_%.]+$") then mod = nil end
    suites[#suites + 1] = { name = name, cases = tonumber(cases) or 0, module = mod }
  end
  local load_errors = {}
  for msg in (output or ""):gmatch("LOADFAIL:: ([^\n]*)") do
    load_errors[#load_errors + 1] = msg
  end
  return suites, load_errors
end

return M
