--- NeoAI 测试运行器：结果聚合与报告
--- @module 'NeoAI.tests.runner.report'
--- 聚合各分片结果（优先用 sidecar/注入结果，回退扫描输出），并打印报告：分片失败时仅输出
--- 日志文件路径 + 末尾 N 行（懒读，不驻留整段输出）。

local timings_mod = require("NeoAI.tests.runner.timings")
local shard_mod = require("NeoAI.tests.runner.shard")

local M = {}

-- 失败分片报告时懒读日志的最大字节/行数
local TAIL_MAX_BYTES = 65536
local TAIL_MAX_LINES = 40

--- 懒读文件末尾若干行（按字节 seek，避免读入整文件）。
--- @param path string|nil
--- @param max_lines number|nil
--- @param max_bytes number|nil
--- @return string|nil
function M.read_tail(path, max_lines, max_bytes)
  if not path then return nil end
  local f = io.open(path, "r")
  if not f then return nil end
  f:seek("end")
  local size = f:seek()
  local start = math.max(0, size - (max_bytes or TAIL_MAX_BYTES))
  f:seek("set", start)
  local data = f:read("*a") or ""
  f:close()
  local lines = {}
  for line in (data .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  local want = max_lines or TAIL_MAX_LINES
  if #lines > want then
    local trimmed = {}
    for i = #lines - want + 1, #lines do trimmed[#trimmed + 1] = lines[i] end
    lines = trimmed
  end
  return table.concat(lines, "\n")
end

--- 记录一个已完成分片结果到 agg（并行/串行共用）。
--- 优先采用注入结果/sidecar 字段；无则回退扫描输出（旧路径兼容）。
--- @param agg table
--- @param sid number
--- @param names table
--- @param started_ns number
--- @param res table
function M.record(agg, sid, names, started_ns, res)
  res = res or {}
  local ms = (vim.uv.hrtime() - started_ns) / 1e6
  local passed = tonumber(res.passed) or 0
  local failed = tonumber(res.failed) or 0
  -- 回退：无结构化结果且带输出时，从输出扫描 SUMMARY/TIMING。
  local output = res.output
  if (passed + failed) == 0 and output and output ~= "" then
    local parsed = require("NeoAI.tests")._parse_child_output(output, "", res.exit_code or 0)
    passed, failed = parsed.passed, parsed.failed
    if not res.errors or #res.errors == 0 then res.errors = parsed.errors end
  end
  local produced = (passed + failed) > 0
  local timings = res.timings
  if not timings or next(timings) == nil then
    timings = output and timings_mod.parse(output) or {}
  end
  local shard = {
    index = sid,
    names = names,
    passed = passed,
    failed = failed,
    produced = produced,
    exit_code = res.exit_code,
    elapsed_ms = ms,
    log_path = res.log_path,
    timings = timings,
  }
  -- 注入式执行器（测试/旧路径）未落盘日志时，保留其小块输出以便失败定位。
  if not shard.log_path and output then shard.output = output end
  if not produced then
    shard.failed = shard.failed + 1
    agg.errors[#agg.errors + 1] = ("分片 #%d 异常退出（code=%s）: %s")
      :format(sid, tostring(res.exit_code), table.concat(names, ","))
  end
  agg.passed = agg.passed + shard.passed
  agg.failed = agg.failed + shard.failed
  for _, e in ipairs(res.errors or {}) do agg.errors[#agg.errors + 1] = e end
  agg.shards[sid] = shard
end

--- 解析注入式执行器返回的清单/输出（发现阶段用）。
--- @param output string|nil
--- @return table[] suites
--- @return string[] load_errors
function M.parse_manifest(output)
  return shard_mod.parse_manifest(output)
end

--- 打印并行结果报告；失败时附带日志文件路径 + 末尾 N 行。
--- @param agg table
--- @param opts table
function M.print(agg, opts)
  local heavy = agg.heavy_workers or 0
  print(("\n=== NeoAI 并行测试（%d 分片 / %d light + %d heavy worker，%.1fs） ===")
    :format(#agg.shards, agg.workers, heavy, agg.elapsed_ms / 1000))
  for i = 1, #agg.shards do
    local sh = agg.shards[i]
    if sh then
      local mark = sh.failed > 0 and "✗" or "✓"
      print(("  %s [%d] %6.1fs  %d 通过 / %d 失败  (%s)")
        :format(mark, sh.index, sh.elapsed_ms / 1000, sh.passed, sh.failed,
          table.concat(sh.names, ", ")))
    end
  end
  print(("SUMMARY passed=%d failed=%d"):format(agg.passed, agg.failed))
  if agg.failed > 0 or (opts and opts.verbose) then
    for i = 1, #agg.shards do
      local sh = agg.shards[i]
      if sh and (sh.failed > 0 or not sh.produced) then
        print(("\n--- 分片 #%d （%s） ---"):format(sh.index, table.concat(sh.names, ", ")))
        if sh.log_path then
          print(("日志: %s"):format(sh.log_path))
          local tail = M.read_tail(sh.log_path)
          if tail and tail ~= "" then print(tail) end
        elseif sh.output and sh.output ~= "" then
          print(sh.output)
        end
      end
    end
  end
end

return M
