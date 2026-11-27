--- 计划模式草稿台账
--- @module 'NeoAI.sandbox.execution.plan_draft'
--- 计划模式（异步沙箱）下，AI 的文件改动仍然落在沙箱视图/暂存里，但：
---   * **不进审批队列**（不 enqueue review、不写候选 JSON、无法被 SandboxCommit）；
---   * **不自动发布**（强制 auto=false，即使会话自动审批/包安装放行）；
---   * 退出计划模式 / Agent 销毁时**自动丢弃**：只撤销计划模式自己造成的改动，
---     若该路径在草稿之前本来就有待审改动，则把旧待审内容恢复回视图，不丢用户改动。
---
--- 作用域（scope）由 plan_mode 建立：`"plan:" .. root_agent.id`，子 Agent 在 spawn 时继承
--- `_plan_scope_id`，因此子 Agent 的写入同样是草稿，随父 scope 一起丢弃。
---
--- 与候选的关系：草稿**不写**候选存储，`SCOPE` 里只保存 `{ path -> { sig, review_id } }`
--- 元数据；丢弃时按视图条目的当前签名（mtime/size/mode）判断「是否仍是我写的那份」，
--- 不一致（被其它 Agent/命令改过）就跳过并留证，绝不误删他人改动。

local candidate = require("NeoAI.sandbox.execution.candidate")
local store = require("NeoAI.sandbox.state.store")
local control = require("NeoAI.sandbox.execution.control")
local logger = require("NeoAI.kernel.logger")

local M = {}

-- ========== 私有状态 ==========

local state = {
  scopes = {}, -- scope -> { active, owner_agent_id, items = { [path] = { sig, review_id } } }
}

-- ========== 私有函数 ==========

--- 收集草稿涉及的路径（候选文件 + 视图同步文件），去重。
--- @param cand table|nil
--- @return string[] paths
local function _paths_of(cand)
  local out, seen = {}, {}
  local function add(p)
    if type(p) == "string" and p ~= "" and not seen[p] then
      seen[p] = true
      out[#out + 1] = p
    end
  end
  for _, f in ipairs((cand and cand.files) or {}) do
    if type(f) == "table" then add(f.path) end
  end
  for _, f in ipairs((cand and cand.view_files) or {}) do
    if type(f) == "table" then add(f.path) end
  end
  return out
end

--- @param scope string|nil
--- @return table|nil
local function _scope(scope)
  return scope and state.scopes[scope] or nil
end

--- 把草稿路径登记进 scope（可重复：同一路径以最后一次写入的签名为准，
--- 但保留首次发现的待审项 id——它代表「草稿之前就存在的用户改动」）。
--- @param scope string
--- @param paths string[]
--- @return number 新增/更新条数
local function _register_paths(scope, paths)
  local sc = _scope(scope)
  if not sc or not sc.active then return 0 end
  local review = require("NeoAI.sandbox.review.review")
  local pending = review.pending_for_paths(paths)
  local n = 0
  for _, p in ipairs(paths) do
    local sig = candidate.staged_sig(p)
    if sig ~= nil then
      local prev = sc.items[p]
      sc.items[p] = {
        sig = sig,
        review_id = (prev and prev.review_id) or pending[p],
      }
      n = n + 1
    else
      logger.warn("[sandbox:plan_draft] 路径无暂存登记，跳过草稿记录: %s", tostring(p))
    end
  end
  return n
end

--- 恢复某个旧待审项中「与草稿重叠」的文件内容到视图（只取草稿涉及路径，避免覆盖其它更新）。
--- @param review_id string
--- @param paths table path -> true
--- @return number 恢复的文件数
local function _restore_pending(review_id, paths)
  local review = require("NeoAI.sandbox.review.review")
  local item = review.get(review_id)
  if not item or item.review_state ~= review.REVIEW.PENDING then return 0 end
  if item.kind == "host_op" or not item.candidate_digest then return 0 end
  local cand = store.read_candidate(item.candidate_digest)
  if not cand then return 0 end
  local keep, n = {}, 0
  for _, f in ipairs(cand.files or {}) do
    if type(f) == "table" and paths[f.path] then
      keep[#keep + 1] = f
      n = n + 1
    end
  end
  if n == 0 then return 0 end
  local restore = { files = keep, view_files = {} }
  -- no_supersede：合并旧待审内容时不得把该待审项自身标记为 SUPERSEDED。
  local ok = pcall(candidate.merge_candidate, restore, { no_supersede = true })
  if not ok then
    logger.warn("[sandbox:plan_draft] 恢复旧待审内容失败: %s", tostring(review_id))
    return 0
  end
  return n
end

-- ========== 公开 API ==========

--- 开启（或重置）一个计划草稿作用域。
--- @param scope string
--- @param owner_agent_id string|nil
--- @return boolean
function M.begin(scope, owner_agent_id)
  if type(scope) ~= "string" or scope == "" then return false end
  state.scopes[scope] = { active = true, owner_agent_id = owner_agent_id, items = {} }
  return true
end

--- 作用域是否仍在收集草稿（退出计划模式后置 false）。
--- @param scope string|nil
--- @return boolean
function M.is_active(scope)
  local sc = _scope(scope)
  return sc ~= nil and sc.active == true
end

--- 作用域是否为指定 Agent 所有（Agent 销毁时据此决定是否丢弃）。
--- @param scope string|nil
--- @param agent_id string|nil
--- @return boolean
function M.is_owner(scope, agent_id)
  local sc = _scope(scope)
  return sc ~= nil and sc.owner_agent_id ~= nil and sc.owner_agent_id == agent_id
end

--- 登记一次草稿写入（供测试/特殊路径直接使用；正常路径走 settle）。
--- @param scope string
--- @param cand table
--- @return number
function M.register(scope, cand)
  return _register_paths(scope, _paths_of(cand))
end

--- 结算一次计划模式写入：登记草稿 + 追加模型可见提示 + 置只读完成态。
--- 调用方在此之前已完成暂存（fs_write 直接写视图 / 命令 merge），此处不再落盘。
--- @param scope string|nil
--- @param cand table|nil
--- @param attempt table
--- @param ctx table|nil
--- @param result any
--- @return table|nil { ok = true, value = any } 非草稿作用域返回 nil（调用方继续正常结算）
function M.settle(scope, cand, attempt, ctx, result)
  local active = M.is_active(scope)
  local started = ctx and ctx._plan_draft_active == true
  if not active and not started then return nil end
  local paths = _paths_of(cand)
  -- 捕获预算可能截断 cand.files（条目数上限），但 attempt.mapping 仍记录本次触碰的全部路径；
  -- 草稿退出时必须把这些路径一起丢弃，否则会残留无法发布的视图改动。
  do
    local seen = {}
    for _, p in ipairs(paths) do seen[p] = true end
    for real in pairs((attempt and attempt.mapping) or {}) do
      if type(real) == "string" and real ~= "" and not seen[real] then
        seen[real] = true
        paths[#paths + 1] = real
      end
    end
  end
  if not active then
    -- 异步后处理晚于 exit：计划模式已退出，本次改动必须立即丢弃，绝不补入审批队列。
    local stats = M.discard_paths(paths, "plan_exit_race")
    if attempt then
      pcall(function() control.transition(attempt, "COMPLETED_READ_ONLY") end)
    end
    local outcome = require("NeoAI.sandbox.protected.outcome")
    local out = outcome.append(result, outcome.plan_draft({
      files = cand and cand.files or nil,
      discarded = true,
      tool = attempt and attempt.tool_name or nil,
    }).text)
    logger.warn("[sandbox:plan_draft] 结算晚于退出计划模式，已立即丢弃 %d 个文件", #paths)
    return { ok = true, value = out, plan_draft_discarded = stats }
  end
  local n = _register_paths(scope, paths)
  if attempt then
    pcall(function() control.transition(attempt, "COMPLETED_READ_ONLY") end)
  end
  if n > 0 then
    pcall(function()
      local sample = {}
      for i = 1, math.min(#paths, 200) do sample[#sample + 1] = paths[i] end
      require("NeoAI.sandbox.review.evidence").add("plan_draft", {
        files = sample,
        truncated = #paths > #sample or nil,
        count = n,
        agent_id = ctx and ctx.agent and ctx.agent.id or nil,
        tool = attempt and attempt.tool_name or nil,
      }, { tool = attempt and attempt.tool_name or nil, command_id = attempt and attempt.command_id or nil })
    end)
    logger.info("[sandbox:plan_draft] 暂存计划草稿 %d 个文件（退出计划模式丢弃）", n)
  end
  local outcome = require("NeoAI.sandbox.protected.outcome")
  local out = outcome.append(result, outcome.plan_draft({
    files = cand and cand.files or nil,
    tool = attempt and attempt.tool_name or nil,
  }).text)
  return { ok = true, value = out }
end

--- 丢弃一组草稿条目（path -> { sig, review_id }）。
--- @param items table
--- @param reason string|nil
--- @return table { discarded: number, restored: number, skipped: number }
local function _discard_items(items, reason)
  local invalidate, restore_paths = {}, {}
  local skipped = 0
  for path, rec in pairs(items or {}) do
    local now = candidate.staged_sig(path)
    if now ~= nil and (rec.sig == nil or now == rec.sig) then
      if rec.review_id then
        restore_paths[rec.review_id] = restore_paths[rec.review_id] or {}
        restore_paths[rec.review_id][path] = true
      else
        invalidate[#invalidate + 1] = path
      end
    else
      skipped = skipped + 1
      logger.info("[sandbox:plan_draft] 跳过已变更的草稿路径（不误删他人改动）: %s", tostring(path))
    end
  end
  local discarded = 0
  if #invalidate > 0 then
    local ok_inv, err_inv = pcall(candidate.invalidate, invalidate)
    if not ok_inv then
      logger.warn("[sandbox:plan_draft] 丢弃暂存视图失败: %s", tostring(err_inv))
    end
    discarded = discarded + #invalidate
  end
  local restored = 0
  for rid, set in pairs(restore_paths) do
    local n = _restore_pending(rid, set)
    if n > 0 then
      restored = restored + n
    else
      -- 旧待审项已失效/候选缺失：退回真实盘，避免残留草稿内容。
      local fallback = {}
      for p in pairs(set) do fallback[#fallback + 1] = p end
      pcall(candidate.invalidate, fallback)
      discarded = discarded + #fallback
    end
  end
  local stats = { discarded = discarded, restored = restored, skipped = skipped }
  if discarded + restored > 0 or skipped > 0 then
    pcall(function()
      require("NeoAI.sandbox.review.evidence").add("plan_draft_discard", {
        discarded = discarded, restored = restored, skipped = skipped, reason = reason,
      }, { tool = "plan_draft" })
    end)
    logger.info("[sandbox:plan_draft] 丢弃 reason=%s discarded=%d restored=%d skipped=%d",
      tostring(reason or ""), discarded, restored, skipped)
  end
  return stats
end

--- 丢弃作用域内全部草稿。
--- @param scope string|nil
--- @param reason string|nil
--- @return table { discarded: number, restored: number, skipped: number }
function M.discard(scope, reason)
  local sc = _scope(scope)
  if not sc then return { discarded = 0, restored = 0, skipped = 0 } end
  sc.active = false
  local items = sc.items or {}
  sc.items = {}
  return _discard_items(items, reason or ("plan_scope:" .. tostring(scope)))
end

--- 立即丢弃一组路径（用于「命令执行期间已退出计划模式」的异步竞态：结算晚于 exit）。
--- 与 `discard` 同样的恢复语义：优先恢复这些路径在草稿前已存在的待审内容。
--- @param paths string[]
--- @param reason string|nil
--- @return table { discarded: number, restored: number, skipped: number }
function M.discard_paths(paths, reason)
  local review = require("NeoAI.sandbox.review.review")
  local items = {}
  for _, p in ipairs(paths or {}) do
    if type(p) == "string" and p ~= "" then
      local pending = review.pending_for_paths({ p })[p]
      items[p] = { sig = candidate.staged_sig(p), review_id = pending }
    end
  end
  return _discard_items(items, reason or "plan_draft_late_settle")
end

--- 当前作用域的草稿条目（测试/诊断）。
--- @param scope string
--- @return table path -> { sig, review_id }
function M.items(scope)
  local sc = _scope(scope)
  return vim.deepcopy(sc and sc.items or {})
end

--- 重置（沙箱 reset/插件卸载）：只清内存台账（沙箱存储本身随 reset 清理）。
function M.reset()
  state.scopes = {}
end

return M
