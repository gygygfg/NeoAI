--- 沙箱故障注入
--- @module NeoAI.sandbox.fault
--- 在关键执行点注入可控故障，用于验证恢复/回滚路径（设计文档 §13 阶段四出口条件）。
--- 仅测试/诊断使用；默认不注入任何故障。

local M = {}

-- 已定义的注入点
M.POINTS = {
  "backend", -- 运行时后端不可用
  "freeze", -- 候选冻结失败
  "publish", -- CAS 发布失败
  "store", -- 持久化写入失败
}

-- ========== 私有状态 ==========

local state = {
  active = {}, -- point -> 剩余注入次数
  log = {},
}

-- ========== 公开 API ==========

--- 在指定点注入 count 次故障
--- @param point string
--- @param count number|nil 默认 1
function M.set(point, count)
  state.active[point] = count or 1
end

--- 命中注入点（消费一次）
--- @param point string
--- @return boolean injected
function M.hit(point)
  local n = state.active[point]
  if n and n > 0 then
    state.active[point] = n - 1
    state.log[#state.log + 1] = { point = point, at = os.time() }
    return true
  end
  return false
end

--- 是否配置了某注入点
--- @param point string
--- @return boolean
function M.active(point)
  return (state.active[point] or 0) > 0
end

--- 注入日志
--- @return table 数组
function M.history()
  return vim.deepcopy(state.log)
end

--- 清除全部注入
function M.clear()
  state.active = {}
end

--- 重置（测试用）
function M.reset()
  state.active = {}
  state.log = {}
end

return M
