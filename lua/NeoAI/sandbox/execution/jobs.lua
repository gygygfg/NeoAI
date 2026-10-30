--- 沙箱后台任务登记表（主进程侧）
--- @module 'NeoAI.sandbox.execution.jobs'
--- worker 进程负责执行重任务；本模块只在主进程维护「哪些条目正在执行」的轻量视图，
--- 供审批窗口高亮/进度显示。事件只带标量与 id，不带文件内容，避免主线程深拷贝大表。
---
--- 生命周期：begin → stage* → finish。任何阶段异常都必须 finish，避免条目永久显示「执行中」。

local M = {}

local state = {
  seq = 0,
  active = {}, -- id -> job
  history = {}, -- 最近完成（有界）
  by_item = {}, -- change_set_id -> job
}

local HISTORY_MAX = 50

local function _now_ms()
  return math.floor((vim.uv.hrtime() or 0) / 1e6)
end

local function _emit(name, payload)
  pcall(function()
    require("NeoAI.kernel.event_bus").emit(name, payload)
  end)
end

local function _reindex()
  state.by_item = {}
  for _, job in pairs(state.active) do
    if job.change_set_id then state.by_item[tostring(job.change_set_id)] = job end
    for _, id in ipairs(job.item_ids or {}) do
      state.by_item[tostring(id)] = job
    end
  end
end

--- 开始一个任务。
--- @param opts table {
---   kind: string, change_set_id?: string, attempt_id?: string,
---   item_ids?: string[], label?: string, total?: number,
--- }
--- @return table job
function M.begin(opts)
  opts = opts or {}
  state.seq = state.seq + 1
  local job = {
    id = "job_" .. tostring(state.seq) .. "_" .. tostring(os.time()),
    kind = opts.kind or "task",
    label = opts.label or opts.kind or "任务",
    change_set_id = opts.change_set_id and tostring(opts.change_set_id) or nil,
    attempt_id = opts.attempt_id and tostring(opts.attempt_id) or nil,
    item_ids = opts.item_ids,
    state = "running",
    stage = "start",
    done = 0,
    total = tonumber(opts.total) or nil,
    started_at = _now_ms(),
    updated_at = _now_ms(),
  }
  state.active[job.id] = job
  _reindex()
  _emit(require("NeoAI.kernel.events").SANDBOX_JOB_STARTED, {
    id = job.id, kind = job.kind, label = job.label,
    change_set_id = job.change_set_id, attempt_id = job.attempt_id,
    total = job.total,
  })
  return job
end

--- 更新阶段/进度。
--- @param job table
--- @param stage string
--- @param info table|nil { done?: number, total?: number, message?: string }
function M.stage(job, stage, info)
  if type(job) ~= "table" or not job.id or not state.active[job.id] then return end
  info = info or {}
  job.stage = stage or job.stage
  if info.done ~= nil then job.done = tonumber(info.done) or job.done end
  if info.total ~= nil then job.total = tonumber(info.total) or job.total end
  if info.message ~= nil then job.message = info.message end
  job.updated_at = _now_ms()
  _emit(require("NeoAI.kernel.events").SANDBOX_JOB_UPDATED, {
    id = job.id, kind = job.kind, stage = job.stage,
    done = job.done, total = job.total, message = job.message,
    change_set_id = job.change_set_id,
  })
end

--- 绑定条目 id（如 enqueue 后才知道 change_set_id）。
--- @param job table
--- @param change_set_id string|nil
function M.bind(job, change_set_id)
  if type(job) ~= "table" or not state.active[job.id] then return end
  job.change_set_id = change_set_id and tostring(change_set_id) or nil
  _reindex()
end

--- 结束任务。
--- @param job table
--- @param ok boolean
--- @param err string|nil
function M.finish(job, ok, err)
  if type(job) ~= "table" or not job.id then return end
  local active = state.active[job.id]
  if not active then return end
  state.active[job.id] = nil
  active.state = ok == false and "failed" or "done"
  active.error = err
  active.finished_at = _now_ms()
  active.updated_at = active.finished_at
  state.history[#state.history + 1] = active
  while #state.history > HISTORY_MAX do table.remove(state.history, 1) end
  _reindex()
  _emit(require("NeoAI.kernel.events").SANDBOX_JOB_FINISHED, {
    id = active.id, kind = active.kind, state = active.state, error = err,
    change_set_id = active.change_set_id, attempt_id = active.attempt_id,
  })
end

--- 活跃任务列表（数组）。
--- @return table[]
function M.list()
  local out = {}
  for _, job in pairs(state.active) do out[#out + 1] = job end
  table.sort(out, function(a, b) return (a.started_at or 0) < (b.started_at or 0) end)
  return out
end

--- change_set_id -> 活跃 job。
--- @param id string|nil
--- @return table|nil
function M.for_item(id)
  if not id then return nil end
  return state.by_item[tostring(id)]
end

--- 是否有活跃任务。
--- @return boolean
function M.any()
  return next(state.active) ~= nil
end

--- 诊断摘要。
--- @return table
function M.summary()
  local n, kinds = 0, {}
  for _, job in pairs(state.active) do
    n = n + 1
    kinds[job.kind] = (kinds[job.kind] or 0) + 1
  end
  return { count = n, kinds = kinds }
end

--- 重置（测试 / 插件停止）。
function M.reset()
  state.seq = 0
  state.active = {}
  state.history = {}
  state.by_item = {}
end

return M
