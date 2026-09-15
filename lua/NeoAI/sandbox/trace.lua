--- 越界访问留痕
--- @module NeoAI.sandbox.trace
--- `read_all`（默认）下沙箱可读整机（仅遮蔽 mask_paths 中的重要配置文件），但**访问 cwd
--- 之外的用户工作目录**（home/root 等）会在此留痕：写入证据（evidence）+ 事件，并在审批
--- 悬浮窗（`:NeoAISandboxReview`）以「越界访问」区展示。非阻塞：不阻断读取。
---
--- 去重：同一 (tool, path) 只记录一次，避免高频读取刷屏；可按需 `reset()`。

local M = {}

-- ========== 私有状态 ==========

local state = {
  items = {}, -- 有序留痕项
  seen = {}, -- key(tool\0path) -> item
  seq = 0,
  max = 200, -- 内存保留上限（超出丢弃最旧）
}

-- ========== 私有函数 ==========

local function _emit(event, payload)
  local event_bus = require("NeoAI.kernel.event_bus")
  event_bus.emit(event, payload or {})
end

-- ========== 公开 API ==========

--- 记录一次越界访问（非阻塞）。同 (tool, path) 去重。
--- @param entry table { path, tool?, kind?, command?, source? }
--- @return table|nil item 新记录（已存在时返回已有项）
function M.record(entry)
  entry = entry or {}
  local path = entry.path
  if type(path) ~= "string" or path == "" then return nil end
  local key = tostring(entry.tool or "") .. "\0" .. path
  if state.seen[key] then return state.seen[key] end
  state.seq = state.seq + 1
  local item = {
    trace_id = string.format("tr_%d_%s", state.seq, tostring(os.time())),
    path = path,
    tool = entry.tool,
    kind = entry.kind or "read",
    command = entry.command,
    created_at = os.time(),
  }
  state.items[#state.items + 1] = item
  state.seen[key] = item
  -- 内存上限：超出丢弃最旧（并同步 seen）
  while #state.items > state.max do
    local old = table.remove(state.items, 1)
    if old then state.seen[tostring(old.tool or "") .. "\0" .. old.path] = nil end
  end
  pcall(function()
    require("NeoAI.sandbox.evidence").add("observation", {
      kind = "outside_access", path = path, tool = item.tool, command = item.command,
    }, { tool = item.tool, source = entry.source or "observed", coverage = "full" })
  end)
  pcall(function()
    _emit(require("NeoAI.kernel.events").SANDBOX_OUTSIDE_ACCESS, {
      trace_id = item.trace_id, path = path, tool = item.tool, kind = item.kind,
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
