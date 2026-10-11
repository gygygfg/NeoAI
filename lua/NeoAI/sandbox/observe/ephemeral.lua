--- 临时写入留痕（会话私有临时根）
--- @module 'NeoAI.sandbox.observe.ephemeral'
--- 沙箱内临时根（`/tmp`、`/var/tmp` 等，见 `tools.sandbox.ephemeral_roots`）的写入为
--- **会话私有、nvim 退出即丢弃**：不进入待审队列、不 CAS 发布、也不弹审批悬浮窗
--- （见 `sandbox.execution.wrapper` 的 `_settle_candidate`）。本模块只做**只读留痕**，
--- 使审批悬浮窗（`:NeoAISandboxReview` 的「越界/异常」页）能展示 AI 在临时根写过哪些文件——
--- 不改变任何效果与发布语义，仍不产生待审候选。
---
--- 去重：同一 (tool, path) 只记录一次，避免高频写入刷屏；可按需 `reset()`。
--- 展示时按文件路径合并（`list_grouped`，复用 `observe.trace` 的分组）、升序排序；
--- `file_count` 返回去重文件数。

local M = {}

local trace = require("NeoAI.sandbox.observe.trace")

-- ========== 私有状态 ==========

local state = {
  items = {}, -- 有序留痕项
  seen = {}, -- key(tool\0path) -> item
  seq = 0,
  max = 200, -- 内存保留上限（超出丢弃最旧）
}

-- ========== 私有函数 ==========

local function _emit(event, payload)
  require("NeoAI.kernel.event_bus").emit(event, payload or {})
end

-- ========== 公开 API ==========

--- 记录一次临时根写入（非阻塞）。同 (tool, path) 去重。
--- @param entry table { path, tool?, command?, source? }
--- @return table|nil item 新记录（已存在时返回已有项）
function M.record(entry)
  entry = entry or {}
  local path = entry.path
  if type(path) ~= "string" or path == "" then return nil end
  local key = tostring(entry.tool or "") .. "\0" .. path
  local now = os.time()
  -- 同 (tool, path) 已存在：不新增条目（保持去重口径与状态栏计数不变），仅刷新时间与命令。
  local existing = state.seen[key]
  if existing then
    existing.last_at = now
    if existing.command == nil and type(entry.command) == "string" and entry.command ~= "" then
      existing.command = entry.command
    end
    return existing
  end
  state.seq = state.seq + 1
  local item = {
    trace_id = string.format("eph_%d_%s", state.seq, tostring(now)),
    path = path,
    tool = entry.tool,
    command = entry.command,
    created_at = now,
    last_at = now,
  }
  state.items[#state.items + 1] = item
  state.seen[key] = item
  -- 内存上限：超出丢弃最旧（并同步 seen）
  while #state.items > state.max do
    local old = table.remove(state.items, 1)
    if old then state.seen[tostring(old.tool or "") .. "\0" .. old.path] = nil end
  end
  pcall(function()
    _emit(require("NeoAI.kernel.events").SANDBOX_EPHEMERAL_WRITE, {
      trace_id = item.trace_id, path = path, tool = item.tool, command = item.command,
    })
  end)
  return item
end

--- 列出留痕（按时间先后）
--- @return table 数组
function M.list()
  local out = {}
  for _, it in ipairs(state.items) do out[#out + 1] = vim.deepcopy(it) end
  return out
end

--- 按文件路径聚合留痕（路径升序；复用 observe.trace 的分组，输入为临时写入条目）
--- @return table 数组
function M.list_grouped()
  return trace.group(state.items)
end

--- 去重后的文件数（按路径聚合；O(n)）
--- @return number
function M.file_count()
  local seen, n = {}, 0
  for _, it in ipairs(state.items) do
    local p = it.path
    if type(p) == "string" and p ~= "" and not seen[p] then
      seen[p] = true
      n = n + 1
    end
  end
  return n
end

--- 留痕数量
--- @return number
function M.count()
  return #state.items
end

--- 重置（测试用）
function M.reset()
  state.items = {}
  state.seen = {}
  state.seq = 0
end

return M
