--- 审批分流中心
--- @module 'NeoAI.sandbox.review.approval_hub'
---
--- 汇聚所有「需用户批准 / 需用户关注」的请求与观测，按**页面（page）**分类，供多级页面
--- 审批悬浮窗（`ui/components/sandbox_review`）统一渲染与决策。分流机制：
---
--- | page       | 含义                     | 阻塞 | 数据来源 |
--- | ---        | ---                      | ---  | --- |
--- | `files`    | 待修改（文件变更单元）   | 否   | `sandbox.review` 待审队列 + 已保存 |
--- | `behavior` | 工具调用同意行为         | 是   | `tool_service` 审批队列（非遮蔽原因） |
--- | `resource` | 访问资源（遮蔽目录等）   | 是   | `tool_service` 审批队列（`ctx.sandbox_unmask`） |
--- | `network`  | 网络请求（出沙箱访问）   | 是   | `sandbox.net_consent` |
--- | `anomaly`  | 越界 / 异常行为（观测）  | 否   | `sandbox.trace` 越界留痕 + `sandbox.audit` 异常 |
---
--- 阻塞类请求由来源模块（tool_service / net_consent）提交；来源仍可自行弹独立弹窗以保证
--- 即时响应，同时把条目镜像到本中心（同一 `id`），中心窗口亦可决策（决策幂等）。
--- **可选去重**：提交时给 `dedupe_key`，同页同键的**在途**条目合并为一条（`count` 累加、
--- 决策回调追加），一次决策让该目标下所有挂起请求一起结算（网络请求页即按「端口 + 服务进程」去重）。
--- 观测类页面由 provider 函数按需列举。
---
--- 本模块**无 UI 依赖**：headless / 测试下 `set_ui(nil)` 时仅保留条目不渲染。

local M = {}

-- ========== 页面定义（顺序即页面切换顺序） ==========

M.PAGES = {
  { id = "files", label = "待修改", kind = "review" },
  { id = "behavior", label = "工具行为", kind = "blocking" },
  { id = "resource", label = "资源访问", kind = "blocking" },
  { id = "network", label = "网络请求", kind = "blocking" },
  { id = "anomaly", label = "越界/异常", kind = "observe" },
}

-- id -> true
local PAGE_IDS = {}
for _, p in ipairs(M.PAGES) do PAGE_IDS[p.id] = true end

-- ========== 私有状态 ==========

local state = {
  ui = nil, -- { refresh = function() } 多级页面窗口注册
  seq = 0,
  entries = {}, -- id -> entry
  order = {}, -- id 数组（提交顺序）
  providers = {}, -- page -> function(): items[]（观测类页面）
}

local function _emit_changed(page)
  pcall(function()
    require("NeoAI.kernel.event_bus").emit(
      require("NeoAI.kernel.events").SANDBOX_APPROVAL_CHANGED, { page = page })
  end)
  if state.ui and type(state.ui.refresh) == "function" then
    pcall(state.ui.refresh)
  end
end

--- 页面是否属于「阻塞 agent 执行」的审批页。
--- @param page string
--- @return boolean
local function _is_blocking_page(page)
  for _, p in ipairs(M.PAGES) do
    if p.id == page then return p.kind == "blocking" end
  end
  return false
end

--- 广播阻塞类审批弹窗生命周期（Herder 据此标记 pane blocked / 恢复）。
--- @param event_name string SANDBOX_APPROVAL_BLOCKING_OPENED/CLOSED
--- @param rec table 审批条目
local function _emit_blocking(event_name, rec)
  if not rec then return end
  pcall(function()
    require("NeoAI.kernel.event_bus").emit(event_name, {
      id = rec.id, page = rec.page,
      title = rec.title, kind = rec.meta and rec.meta.kind or nil,
    })
  end)
end

--- 查找同页同 dedupe_key 的待处理条目（仍在等待决策）。
--- @param page string
--- @param key string
--- @return table|nil
local function _find_dedupe(page, key)
  for _, id in ipairs(state.order) do
    local rec = state.entries[id]
    if rec and rec.page == page and rec.dedupe_key == key then return rec end
  end
  return nil
end

-- ========== 公开 API ==========

--- 注册页面窗口（ui/components/sandbox_review 调用）；传 nil 注销。
--- @param ui table|nil { refresh = function() }
function M.set_ui(ui)
  state.ui = ui
end

--- 是否已注册页面窗口
--- @return boolean
function M.available()
  return state.ui ~= nil and type(state.ui.refresh) == "function"
end

--- 请求页面窗口打开并切到指定页（无窗口时忽略）。供阻塞类来源在无独立弹窗时拉起统一窗口。
--- @param page string
function M.open_page(page)
  if not M.available() then return end
  if type(state.ui.open_page) == "function" then
    pcall(state.ui.open_page, page)
  else
    pcall(state.ui.refresh)
  end
end

--- 提交一条阻塞类审批请求（来源模块调用）。
--- @param page string PAGES 中的 id（blocking 类）
--- @param entry table {
---   id: string|nil,                -- 缺省自动生成
---   title: string,
---   detail: string[]|nil,          -- 展示用详情行（已单行化）
---   decisions: table[]|nil,        -- { { key, label, value } }；缺省为 allow_once/allow_session/deny
---   on_decision: function(value),  -- 幂等决策回调（重复调用只生效一次由来源保证）
---   dedupe_key: string|nil,        -- 同页同键的在途条目合并为一条（并发/重复请求去重）
---   meta: table|nil,
--- }
--- @return string id
function M.submit(page, entry)
  assert(PAGE_IDS[page], "approval_hub: unknown page " .. tostring(page))
  entry = entry or {}
  -- 去重（可选）：同页 + 同 dedupe_key 且**仍在待处理**时合并——只保留一条展示，
  -- 追加决策回调并把 `count` 累加；一次决策让该目标下所有挂起请求一起生效。
  local dk = entry.dedupe_key
  if type(dk) == "string" and dk ~= "" then
    local exist = _find_dedupe(page, dk)
    if exist then
      exist.deciders = exist.deciders or {}
      if type(entry.on_decision) == "function" then
        exist.deciders[#exist.deciders + 1] = entry.on_decision
      end
      exist.count = (tonumber(exist.count) or 1) + 1
      _emit_changed(page)
      return exist.id
    end
  end
  state.seq = state.seq + 1
  local id = entry.id or string.format("ah_%d_%d", state.seq, os.time())
  local deciders = {}
  if type(entry.on_decision) == "function" then deciders[1] = entry.on_decision end
  local rec = {
    id = id,
    page = page,
    seq = state.seq,
    title = tostring(entry.title or ""),
    detail = type(entry.detail) == "table" and entry.detail or {},
    decisions = entry.decisions,
    on_decision = entry.on_decision,
    deciders = deciders,
    dedupe_key = (type(dk) == "string" and dk ~= "") and dk or nil,
    count = 1,
    meta = entry.meta,
    blocking = _is_blocking_page(page),
    created_at = os.time(),
  }
  if state.entries[id] == nil then state.order[#state.order + 1] = id end
  state.entries[id] = rec
  _emit_changed(page)
  if rec.blocking then
    _emit_blocking(require("NeoAI.kernel.events").SANDBOX_APPROVAL_BLOCKING_OPENED, rec)
  end
  return id
end

--- 决策一条阻塞类条目（幂等：不存在则忽略）。由窗口 / 来源调用。
--- 去重条目会把**所有**挂起请求的决策回调各调一次（每条请求各自结算）。
--- @param id string
--- @param value any 决策值（如 "allow_once"|"allow_session"|"deny"）
--- @return boolean 是否找到并调用
function M.resolve(id, value)
  local rec = state.entries[id]
  if not rec then return false end
  state.entries[id] = nil
  for i, oid in ipairs(state.order) do
    if oid == id then table.remove(state.order, i); break end
  end
  local deciders = rec.deciders
  if type(deciders) ~= "table" then
    deciders = {}
    if type(rec.on_decision) == "function" then deciders[1] = rec.on_decision end
  end
  if rec.blocking then
    _emit_blocking(require("NeoAI.kernel.events").SANDBOX_APPROVAL_BLOCKING_CLOSED, rec)
  end
  -- 先快照再回调：回调内可能再次 submit（新请求）/clear（同条目）修改集合。
  local list = {}
  for i, fn in ipairs(deciders) do list[i] = fn end
  for _, fn in ipairs(list) do pcall(fn, value) end
  _emit_changed(rec.page)
  return true
end

--- 移除条目（不触发决策回调；用于来源已自行关闭的场景）。
--- @param id string
function M.clear(id)
  if state.entries[id] == nil then return end
  local rec = state.entries[id]
  local page = rec.page
  if rec.blocking then
    _emit_blocking(require("NeoAI.kernel.events").SANDBOX_APPROVAL_BLOCKING_CLOSED, rec)
  end
  state.entries[id] = nil
  for i, oid in ipairs(state.order) do
    if oid == id then table.remove(state.order, i); break end
  end
  _emit_changed(page)
end

--- 查询某条目的记录（不存在返回 nil）
--- @param id string
--- @return table|nil
function M.get(id)
  return state.entries[id]
end

--- 某页的阻塞类条目（提交顺序）
--- @param page string
--- @return table[] 数组（浅拷贝引用）
function M.list(page)
  local out = {}
  for _, id in ipairs(state.order) do
    local rec = state.entries[id]
    if rec and rec.page == page then out[#out + 1] = rec end
  end
  return out
end

--- 注册观测类页面 provider（返回 items 数组）。
--- @param page string
--- @param fn function|nil
function M.register_provider(page, fn)
  state.providers[page] = fn
end

--- 观测类页面条目
--- @param page string
--- @return table[]
function M.observe(page)
  local fn = state.providers[page]
  if type(fn) ~= "function" then return {} end
  local ok, items = pcall(fn)
  if not ok or type(items) ~= "table" then return {} end
  return items
end

--- 阻塞类条目总数（单页或全部）
--- @param page string|nil
--- @return number
function M.pending_count(page)
  local n = 0
  for _, rec in pairs(state.entries) do
    if page == nil or rec.page == page then n = n + 1 end
  end
  return n
end

--- 重置（测试用）
function M.reset()
  for _, rec in pairs(state.entries) do
    if rec.blocking then
      _emit_blocking(require("NeoAI.kernel.events").SANDBOX_APPROVAL_BLOCKING_CLOSED, rec)
    end
  end
  state.ui = nil
  state.seq = 0
  state.entries = {}
  state.order = {}
  state.providers = {}
end

return M
