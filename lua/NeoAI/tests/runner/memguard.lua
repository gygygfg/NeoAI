--- NeoAI 测试运行器：内存许可 / 运行期自适应并发
--- @module 'NeoAI.tests.runner.memguard'
--- 启动时刻的并发计划来自 `runner.config.plan`（核数 + 可用内存）。但并发 worker 拉起后
--- 内存占用会随时间上升（每个 heavy 分片都在跑 bwrap/cgroup/常驻服务），静态计划可能高估。
--- 本模块在每个分片**真正启动前**检查一次可用内存：低于该分片的内存预算时短暂等待
--- （其他分片结束会释放内存），超过等待上限则照常启动（**绝不挂起**），并留一条告警日志。
---
--- 读不到内存信息（非 Linux / uv 不可用）时直接放行。

local config = require("NeoAI.tests.runner.config")

local M = {}

-- ========== 私有状态 ==========

--- 重试间隔（毫秒）
local RETRY_MS = 250
--- 默认最长等待（毫秒）：到时仍不足即放行，避免测试挂起
local DEFAULT_MAX_WAIT_MS = 15000
--- 等待超时后的冷却期（毫秒）：期间不再等待（内存长期不足时避免每个分片都白等一轮）
local TIMEOUT_COOLDOWN_MS = 30000

--- 测试注入：自定义可用内存读取函数（返回 MB）
local available_fn = nil
--- 冷却截止时刻（hrtime 纳秒；0 表示无冷却）
local cooldown_until = 0

-- ========== 公开 API ==========

--- 当前可用内存（MB）；读不到返回 nil
--- @return number|nil
function M.available_mb()
  if available_fn then
    local ok, v = pcall(available_fn)
    return ok and tonumber(v) or nil
  end
  local bytes = config.available_memory_bytes()
  if not bytes then return nil end
  return bytes / (1024 * 1024)
end

--- 申请启动许可：可用内存 ≥ need_mb 时立即 `launch()`；否则按 RETRY_MS 轮询等待，
--- 最多 max_wait_ms 后仍不足则照常 `launch()`（有界等待，不会挂起测试）。
--- @param need_mb number 该分片的内存预算（MB）
--- @param launch fun() 启动分片
--- @param opts table|nil { max_wait_ms?: number }
function M.admit(need_mb, launch, opts)
  opts = opts or {}
  local max_wait_ms = tonumber(opts.max_wait_ms) or DEFAULT_MAX_WAIT_MS
  local now = vim.uv.hrtime()
  -- 冷却期（上一次等待已超时）：说明内存长期不足，直接放行，不再逐分片重复等待。
  if cooldown_until > now then
    launch()
    return
  end
  local started = now
  local warned = false
  local function tick()
    local avail = M.available_mb()
    local waited = (vim.uv.hrtime() - started) / 1e6
    if avail == nil or avail >= (tonumber(need_mb) or 0) or waited >= max_wait_ms then
      if avail ~= nil and (tonumber(need_mb) or 0) > avail then
        cooldown_until = vim.uv.hrtime() + TIMEOUT_COOLDOWN_MS * 1e6
        if not warned then
          warned = true
          pcall(function()
            require("NeoAI.kernel.logger").warn(
              "[tests] 可用内存不足（%.0fMB < 本分片预留 %.0fMB），等待 %.1fs 后仍启动（%ds 内不再等待）",
              avail, tonumber(need_mb) or 0, waited / 1000, TIMEOUT_COOLDOWN_MS / 1000)
          end)
        end
      end
      launch()
      return
    end
    vim.defer_fn(tick, RETRY_MS)
  end
  tick()
end

--- 测试注入：覆盖可用内存读取（nil 恢复真实读取）
--- @param fn function|nil
function M._set_available_mb(fn)
  available_fn = fn
end

--- 重置（测试用）
function M.reset()
  available_fn = nil
  cooldown_until = 0
end

M.RETRY_MS = RETRY_MS
M.DEFAULT_MAX_WAIT_MS = DEFAULT_MAX_WAIT_MS
M.TIMEOUT_COOLDOWN_MS = TIMEOUT_COOLDOWN_MS

return M
