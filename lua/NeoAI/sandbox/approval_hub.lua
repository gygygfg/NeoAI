--- 审批分流中心
--- @module NeoAI.sandbox.approval_hub
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
---   title: string,
---   detail: string[]|nil,       -- 展示用详情行（已单行化）
---   decisions: table[]|nil,     -- { { key, label, value } }；缺省为 allow_once/allow_session/deny
---   on_decision: function(value), -- 幂等决策回调（重复调用只生效一次由来源保证）
---   meta: table|nil,
--- }
--- @return string id
function M.submit(page, entry)
  assert(PAGE_IDS[page], "approval_hub: unknown page " .. tostring(page))
  entry = entry or {}
  state.seq = state.seq + 1
  local id = entry.id or string.format("ah_%d_%d", state.seq, os.time())
  local rec = {
    id = id,
    page = page,
    seq = state.seq,
    title = tostring(entry.title or ""),
    detail = type(entry.detail) == "table" and entry.detail or {},
    decisions = entry.decisions,
    on_decision = entry.on_decision,
    meta = entry.meta,
    created_at = os.time(),
  }
  if state.entries[id] == nil then state.order[#state.order + 1] = id end
  state.entries[id] = rec
  _emit_changed(page)
  return id
end

--- 决策一条阻塞类条目（幂等：不存在则忽略）。由窗口 / 来源调用。
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
  if type(rec.on_decision) == "function" then pcall(rec.on_decision, value) end
  _emit_changed(rec.page)
  return true
end

--- 移除条目（不触发决策回调；用于来源已自行关闭的场景）。
--- @param id string
function M.clear(id)
  if state.entries[id] == nil then return end
  local page = state.entries[id].page
  state.entries[id] = nil
  for i, oid in ipairs(state.order) do
    if oid == id then table.remove(state.order, i); break end
  end
  _emit_changed(page)
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
  state.ui = nil
  state.seq = 0
  state.entries = {}
  state.order = {}
  state.providers = {}
end

return M
