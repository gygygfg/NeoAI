--- NeoAI 测试运行器：有界并发调度
--- @module 'NeoAI.tests.runner.scheduler'
--- 提供通用有界并发池（trampoline 防同步回调重入）与双 lane 并发编排：
--- light 池 W 路（多套件/进程）、heavy 池 H 路（一套件/进程）重叠执行，任一子进程结束即回填。

local M = {}

--- 有界并发池：任意时刻在飞项 ≤ max_in_flight；每完成一项立即回填下一项。
--- 用 running 标志做 trampoline，防止 start_fn 同步调用 done() 造成递归重入。
--- @param items table[] 待执行项
--- @param max_in_flight number 并发上限（≥1）
--- @param start_fn fun(item, done:fun()) 启动一项；完成后须调用 done()
--- @param on_all_done fun() 全部完成回调（恰好一次）
function M.pool(items, max_in_flight, start_fn, on_all_done)
  items = items or {}
  max_in_flight = math.max(1, math.floor(tonumber(max_in_flight) or 1))
  if #items == 0 then
    on_all_done()
    return
  end
  local cursor = 0
  local in_flight = 0
  local running = false
  local all_done_fired = false
  local pump -- 前向声明

  local function maybe_all_done()
    if not all_done_fired and cursor >= #items and in_flight == 0 then
      all_done_fired = true
      on_all_done()
    end
  end

  pump = function()
    if running then return end
    running = true
    while in_flight < max_in_flight and cursor < #items do
      cursor = cursor + 1
      local item = items[cursor]
      in_flight = in_flight + 1
      local finished = false
      start_fn(item, function()
        if finished then return end
        finished = true
        in_flight = in_flight - 1
        pump() -- 回填（重入由 running 标志挡住，交由外层循环继续）
      end)
    end
    running = false
    maybe_all_done()
  end

  pump()
end

--- 双 lane 有界并发：light 池 W 路、heavy 池 H 路，重叠执行；两池均完成时回调。
--- @param light_units table[]
--- @param heavy_units table[]
--- @param light_workers number
--- @param heavy_workers number
--- @param start_fn fun(unit, done:fun())
--- @param on_all_done fun()
function M.run_dual(light_units, heavy_units, light_workers, heavy_workers, start_fn, on_all_done)
  light_units = light_units or {}
  heavy_units = heavy_units or {}
  local remaining = 0
  if #light_units > 0 then remaining = remaining + 1 end
  if #heavy_units > 0 then remaining = remaining + 1 end
  if remaining == 0 then
    on_all_done()
    return
  end
  local function lane_done()
    remaining = remaining - 1
    if remaining == 0 then on_all_done() end
  end
  if #light_units > 0 then
    M.pool(light_units, light_workers, start_fn, lane_done)
  end
  if #heavy_units > 0 then
    M.pool(heavy_units, heavy_workers, start_fn, lane_done)
  end
end

return M
