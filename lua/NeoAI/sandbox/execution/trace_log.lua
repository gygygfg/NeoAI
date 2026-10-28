--- 沙箱取证日志（默认关闭）
--- @module 'NeoAI.sandbox.execution.trace_log'
---
--- 目的：定位「命令产物跨命令丢失/回滚」一类问题。默认零开销：`enabled()` 首次调用后即缓存，
--- 未开启时所有调用点都在 `if` 外零成本返回。
---
--- 开关：
---   * 环境变量 `NEOAI_SANDBOX_TRACE=1`
---   * 输出文件 `NEOAI_SANDBOX_TRACE_FILE`（默认 `<sandbox store>/trace.log`）
---
--- 记录内容（结构化，按时间递增的毫秒时间戳）：
---   attach            命令视图来源：backend / 常驻与否 / 每个可写根的 root+mode / 暂存根数量
---   journal           eBPF 写日志是否被信任（hint 增量捕获 vs 全量遍历）
---   capture           捕获模式、upper 条目数、hint 未覆盖条目数（= 潜在静默丢改动）
---   merge             合并进暂存层的路径（命令产物是否真正进入沙箱视图）
---   materialize       物化写入条数、overlay 权威跳过条数、疑似「暂存回写覆盖上层」的样本
---
--- 该模块只写诊断文件，不参与任何门禁判定，不得据此改变执行语义。

local M = {}

local state = {
  checked = false,
  enabled = false,
  file = nil,
  path = nil,
  t0 = 0,
  lines = 0,
}

--- 解析日志路径（环境变量优先，其次沙箱存储根）。
--- @return string
local function _resolve_path()
  local env = os.getenv("NEOAI_SANDBOX_TRACE_FILE")
  if type(env) == "string" and env ~= "" then return env end
  local root = nil
  local ok, store = pcall(require, "NeoAI.sandbox.state.store")
  if ok and type(store.root) == "function" then root = store.root() end
  if type(root) ~= "string" or root == "" then
    root = (vim.fn.stdpath("cache") or "/tmp") .. "/NeoAI/sandbox"
  end
  return root .. "/trace.log"
end

--- 是否开启取证日志（结果缓存，首次调用后不再读环境变量）。
--- @return boolean
function M.enabled()
  if state.checked then return state.enabled end
  state.checked = true
  state.t0 = vim.uv.hrtime()
  local v = os.getenv("NEOAI_SANDBOX_TRACE")
  state.enabled = type(v) == "string" and v ~= "" and v ~= "0" and v ~= "false"
  return state.enabled
end

--- 当前日志文件路径（未开启时亦返回解析结果，便于调用方提示）。
--- @return string
function M.path()
  if state.path then return state.path end
  return _resolve_path()
end

--- 追加一行取证日志（未开启时立即返回）。
--- @param fmt string
--- @param ... any
--- @return nil
function M.log(fmt, ...)
  if not M.enabled() then return end
  local line
  if select("#", ...) > 0 then
    local ok, s = pcall(string.format, fmt, ...)
    line = ok and s or tostring(fmt)
  else
    line = tostring(fmt)
  end
  if not state.file then
    local p = _resolve_path()
    pcall(vim.fn.mkdir, vim.fn.fnamemodify(p, ":h"), "p")
    local f = io.open(p, "a")
    if not f then return end
    state.file, state.path = f, p
  end
  local ms = (vim.uv.hrtime() - state.t0) / 1e6
  local okw = pcall(state.file.write, state.file, string.format("%10.1f %s\n", ms, line))
  if not okw then return end
  state.lines = state.lines + 1
  if state.lines % 8 == 0 then pcall(state.file.flush, state.file) end
end

--- 取列表前 n 项拼成日志样本串。
--- @param list table
--- @param n integer|nil
--- @return string
function M.sample(list, n)
  n = n or 8
  local out = {}
  for i = 1, math.min(n, #(list or {})) do out[#out + 1] = tostring(list[i]) end
  if #(list or {}) > n then out[#out + 1] = ("…(+%d)"):format(#list - n) end
  return table.concat(out, " | ")
end

--- 冲刷并关闭句柄（测试/关闭前调用）。
--- @return nil
function M.flush()
  if state.file then
    pcall(state.file.flush, state.file)
    pcall(state.file.close, state.file)
    state.file = nil
  end
end

--- 重置（测试用）。
--- @return nil
function M.reset()
  M.flush()
  pcall(vim.fn.delete, M.path())
  state.checked, state.enabled, state.path, state.lines = false, false, nil, 0
end

return M
