--- 宿主资源探测（CPU 核数）
--- @module NeoAI.utils.host
--- 所有「多核计算核心数」预算的唯一来源：统一走 `core_budget()`（`max(1, 核数-2)`），
--- 不再由配置项分散指定，避免不同路径各自为政（如硬编码 4、或留 1/上不封顶）。

local M = {}

--- 宿主逻辑 CPU 数：`vim.uv.cpus` 优先，回退 `nproc`；探测失败时为 1。
--- @return number
function M.cores()
  local ok, cpus = pcall(vim.uv.cpus)
  if ok and type(cpus) == "table" and #cpus > 0 then return #cpus end
  local raw = vim.fn.system("nproc 2>/dev/null") or ""
  local n = tonumber((raw:gsub("%s+$", "")))
  return (n and n > 0) and n or 1
end

--- 可用计算核数预算：预留 2 核给 nvim/UI，至少 1。
--- 用于工作线程并行度、沙箱 CPU 配额与全局 CPU 预算。
--- @return number
function M.core_budget()
  return math.max(1, M.cores() - 2)
end

return M
