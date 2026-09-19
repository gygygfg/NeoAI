--- 越界访问留痕
--- @module NeoAI.sandbox.trace
--- `read_all`（默认）下沙箱可读整机（仅遮蔽 mask_paths 中的重要配置文件），但**访问 cwd
--- 之外的用户工作目录**（home/root 等）会在此留痕：写入证据（evidence）+ 事件，并在审批
--- 悬浮窗（`:NeoAISandboxReview`）以「越界访问」区展示。非阻塞：不阻断读取。
---
--- 去重：同一 (tool, path) 只记录一次，避免高频读取刷屏；可按需 `reset()`。
--- 展示时按文件路径合并（`list_grouped`）、升序排序；`file_count` 返回去重文件数（供状态栏徽标）。

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

--- 按文件路径聚合留痕：同一路径的多次/多工具访问合并为一条，并按路径升序排序。
--- 纯函数，可对原始或已分组条目再次调用（幂等）。
--- @param entries table|nil 留痕数组（缺省用当前内存留痕）
--- @return table 数组 { path, tools = string[], tool = string, count, created_at, last_at }
function M.group(entries)
  local groups, order = {}, {}
  for _, tr in ipairs(entries or state.items) do
    local path = tostring(tr.path or "")
    if path ~= "" then
      local g = groups[path]
      if not g then
        g = {
          path = path, tools = {}, tool = tr.tool, count = 0,
          created_at = tr.created_at, last_at = tr.created_at,
        }
        groups[path] = g
        order[#order + 1] = g
      end
      g.count = g.count + (tonumber(tr.count) or 1)
      if tr.created_at then g.last_at = tr.created_at end
      local tools = tr.tools or { tr.tool }
      for _, name in ipairs(tools) do
        if type(name) == "string" and name ~= "" then
          local exists = false
          for _, prev in ipairs(g.tools) do if prev == name then exists = true break end end
          if not exists then g.tools[#g.tools + 1] = name end
        end
      end
    end
  end
  table.sort(order, function(a, b) return a.path < b.path end)
  return order
end

--- 按文件聚合后的留痕（路径升序）
--- @return table 数组
function M.list_grouped()
  return M.group(state.items)
end

--- 去重后的文件数（按路径聚合；O(n)，供状态栏高频调用）
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
