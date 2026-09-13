--- 沙箱控制面入口
--- @module NeoAI.sandbox
--- 为工具执行提供受约束的工作区修改、候选冻结、CAS 发布与 dry-run/commit。
--- 所有工具执行经 wrapper.gate；加载器为工具附加 __sandbox 规格。
---
--- 不变量（设计文档 §1.1）：
---   dry-run 不构成安全边界；隔离执行只改私有状态；commit 只发布已冻结候选；
---   硬拒绝不可被确认覆盖；未知结果不报告为成功。

local config_store = require("NeoAI.kernel.config_store")
local store = require("NeoAI.sandbox.store")
local control = require("NeoAI.sandbox.control")
local candidate = require("NeoAI.sandbox.candidate")
local runtime = require("NeoAI.sandbox.runtime")
local wrapper = require("NeoAI.sandbox.wrapper")
local policy = require("NeoAI.sandbox.policy")
local tool_spec = require("NeoAI.sandbox.tool_spec")
local review = require("NeoAI.sandbox.review")
local grant = require("NeoAI.sandbox.grant")
local impact = require("NeoAI.sandbox.impact")
local evidence = require("NeoAI.sandbox.evidence")
local envelope = require("NeoAI.sandbox.envelope")
local network = require("NeoAI.sandbox.network")
local broker = require("NeoAI.sandbox.broker")
local replay = require("NeoAI.sandbox.replay")
local cgroup = require("NeoAI.sandbox.cgroup")
local seccomp = require("NeoAI.sandbox.seccomp")
local cache = require("NeoAI.sandbox.cache")
local fault = require("NeoAI.sandbox.fault")
local bench = require("NeoAI.sandbox.bench")
local events = require("NeoAI.kernel.events")

local M = {}

-- ========== 私有状态 ==========

local state = {
  initialized = false,
  active = nil, -- 当前暂存尝试（供 persist_buffer 重定向）
}

-- ========== 私有函数 ==========

local function _root()
  return config_store.get("tools.sandbox.workspace_root")
    or (vim.fn.stdpath("cache") .. "/NeoAI/sandbox")
end

local function _emit(event, payload)
  local event_bus = require("NeoAI.kernel.event_bus")
  event_bus.emit(event, payload or {})
end

-- ========== 公开 API ==========

--- 初始化：探测运行时能力并准备存储
--- @return table
function M.init()
  if state.initialized then return M end
  store.init(_root())
  cache.init(_root())
  runtime.probe()
  state.initialized = true
  return M
end

--- 探测运行时能力（含 cgroup / seccomp）
--- @return table
function M.probe()
  local caps = runtime.capabilities()
  caps.cgroup = cgroup.probe().available
  caps.seccomp_filter = seccomp.available()
  return caps
end

--- 关闭：清理暂存
function M.shutdown()
  candidate.reset()
  state.active = nil
  state.initialized = false
end

--- 为工具附加沙箱规格（加载器/注册表调用）
--- @param tool table
--- @return table
function M.attach(tool)
  return wrapper.attach(tool)
end

--- 执行门禁
--- @param tool table
--- @param args table
--- @param ctx table
--- @param call_original function
--- @return Deferred
function M.gate(tool, args, ctx, call_original)
  return wrapper.gate(tool, args, ctx, call_original)
end

--- 当前暂存尝试
--- @return table|nil
function M.active_attempt()
  return state.active
end

--- 设置当前暂存尝试（返回旧值）
--- @param attempt table|nil
--- @return table|nil
function M._set_active_attempt(attempt)
  local prev = state.active
  state.active = attempt
  return prev
end

--- 提交候选（CAS 发布到真实工作区）
--- @param digest string
--- @param opts table|nil { expected_base? }
--- @return table { ok, state, reason?, receipt? }
function M.commit(digest, opts)
  M.init()
  local cand = store.read_candidate(digest)
  if not cand then
    return { ok = false, state = "FAILED", reason = "CANDIDATE_NOT_FOUND: " .. tostring(digest) }
  end
  _emit(events.SANDBOX_PUBLISH_STARTED, { candidate_digest = digest, command_id = cand.command_id })
  local pub = candidate.publish(cand, opts or {})
  if pub.ok then
    store.write_receipt(pub.receipt)
    store.discard_candidate(digest)
    review.supersede_by_digest(digest, pub.receipt.operation_id)
    _emit(events.SANDBOX_COMMITTED, { candidate_digest = digest, operation_id = pub.receipt.operation_id })
  else
    _emit(events.SANDBOX_CONFLICT, { candidate_digest = digest, reason = pub.reason })
  end
  return pub
end

--- 丢弃候选（资源清理，不称为回滚）
--- @param digest string
--- @return boolean
function M.discard(digest)
  M.init()
  local ok = store.discard_candidate(digest)
  if ok then _emit(events.SANDBOX_DISCARDED, { candidate_digest = digest }) end
  return ok
end

--- 列出待处理候选
--- @return table 数组
function M.list()
  M.init()
  return store.list_candidates()
end

--- 读取单个候选
--- @param digest string
--- @return table|nil
function M.show(digest)
  M.init()
  return store.read_candidate(digest)
end

--- 读取发布回执
--- @param operation_id string
--- @return table|nil
function M.receipt(operation_id)
  M.init()
  return store.read_receipt(operation_id)
end

-- ========== 异步审批（change_set）==========

--- 列出变更单元
--- @param filter table|nil { review_state?, apply_state? }
--- @return table 数组
function M.list_reviews(filter)
  M.init()
  return review.list(filter)
end

--- 待审数量
--- @return number
function M.pending_count()
  return review.pending_count()
end

--- 批准变更单元
--- @param id string
--- @return table|nil
function M.approve(id)
  return review.approve(id)
end

--- 拒绝变更单元
--- @param id string
--- @param reason string|nil
--- @return table|nil
function M.reject(id, reason)
  return review.reject(id, reason)
end

--- 应用变更单元（CAS 发布；opts.files 支持选择性应用）
--- @param id string
--- @param opts table|nil
--- @return table
function M.apply(id, opts)
  return review.apply(id, opts)
end

--- 应用全部待审/已批准变更单元
--- @param opts table|nil
--- @return table
function M.apply_all(opts)
  return review.apply_all(opts)
end

-- ========== 任务授权（task grant）==========

--- 创建窄范围任务授权
--- @param spec table
--- @return table
function M.create_grant(spec)
  local g = grant.create(spec)
  _emit(events.SANDBOX_GRANT_CREATED, { grant_id = g.grant_id, scope = g.scope, operations = g.operations })
  return g
end

--- 列出任务授权
--- @param filter table|nil
--- @return table
function M.list_grants(filter)
  return grant.list(filter)
end

--- 撤销任务授权
--- @param id string
--- @return boolean
function M.revoke_grant(id)
  local ok = grant.revoke(id)
  if ok then _emit(events.SANDBOX_GRANT_REVOKED, { grant_id = id }) end
  return ok
end

-- ========== 证据 / 影响 ==========

--- 分页读取证据
--- @param opts table|nil
--- @return table
function M.evidence_page(opts)
  return evidence.page(opts)
end

--- 读取单条证据
--- @param id string
--- @return table|nil
function M.evidence_get(id)
  return evidence.get(id)
end

-- ========== 依赖图与组合发布（阶段四）==========

--- 计算变更单元依赖闭包
--- @param id string
--- @return table
function M.dependencies(id)
  return review.dependencies(id)
end

--- 生成组合发布集合（无发布副作用）
--- @param ids table
--- @return table
function M.prepare_publication_set(ids)
  return review.prepare_publication_set(ids)
end

--- 应用组合发布集合
--- @param set table
--- @return table
function M.apply_set(set)
  return review.apply_set(set)
end

--- 从已有变更单元派生新 revision（按文件/hunk 拆分后重新审查）
--- @param id string
--- @param opts table
--- @return table|nil item
--- @return string|nil err
function M.derive_revision(id, opts)
  return review.derive_revision(id, opts)
end

-- ========== 策略回放 ==========

--- 回放一条已记录的裁决
--- @param evidence_id string
--- @param opts table|nil
--- @return table
function M.replay(evidence_id, opts)
  return replay.replay(evidence_id, opts)
end

--- 记录一次裁决为证据（供回放）
--- @param facts table
--- @param verdict table
--- @param meta table|nil
--- @return string
function M.record_decision(facts, verdict, meta)
  return replay.record(facts, verdict, meta)
end

-- ========== 保留期 / 指标 ==========

--- 清理过期候选与变更单元（保留待审/已批准/有回执引用者）
--- @return table { removed_reviews, removed_candidates }
function M.prune()
  M.init()
  local days = config_store.get("tools.sandbox.retention.candidate_days") or 7
  local cutoff = os.time() - days * 86400
  local removed_reviews, removed_candidates = 0, 0
  local referenced = {}
  for _, item in ipairs(review.list()) do
    local stale = (item.created_at or 0) < cutoff
    local terminal = item.review_state == review.REVIEW.REJECTED
      or item.apply_state == review.APPLY.APPLIED
      or item.apply_state == review.APPLY.FAILED
      or item.apply_state == review.APPLY.CONFLICT
    if stale and terminal then
      store.discard_candidate(item.candidate_digest)
      store.delete_review(item.change_set_id)
      removed_reviews = removed_reviews + 1
    else
      referenced[item.candidate_digest] = true
    end
  end
  for _, cand in ipairs(store.list_candidates()) do
    if not referenced[cand.candidate_digest] and (cand.created_at or 0) < cutoff then
      store.discard_candidate(cand.candidate_digest)
      removed_candidates = removed_candidates + 1
    end
  end
  local removed_evidence = evidence.prune(days)
  return { removed_reviews = removed_reviews, removed_candidates = removed_candidates, removed_evidence = removed_evidence }
end

--- 运行指标
--- @return table
function M.metrics()
  M.init()
  local items = review.list()
  local m = { candidates = #store.list_candidates(), reviews = #items, pending = 0, applied = 0, rejected = 0, conflicts = 0 }
  for _, item in ipairs(items) do
    if item.review_state == review.REVIEW.PENDING then m.pending = m.pending + 1 end
    if item.review_state == review.REVIEW.REJECTED then m.rejected = m.rejected + 1 end
    if item.apply_state == review.APPLY.APPLIED then m.applied = m.applied + 1 end
    if item.apply_state == review.APPLY.CONFLICT then m.conflicts = m.conflicts + 1 end
  end
  return m
end

--- 子模块引用
M.control = control
M.candidate = candidate
M.runtime = runtime
M.policy = policy
M.tool_spec = tool_spec
M.wrapper = wrapper
M.store = store
M.review = review
M.grant = grant
M.impact = impact
M.evidence = evidence
M.envelope = envelope
M.network = network
M.broker = broker
M.cgroup = cgroup
M.seccomp = seccomp
M.cache = cache
M.fault = fault
M.bench = bench

--- 重置（测试用）
function M.reset()
  candidate.reset()
  control.reset()
  store.reset()
  runtime.reset()
  policy.reset()
  review.reset()
  grant.reset()
  evidence.reset()
  network.reset()
  broker.reset()
  cgroup.reset()
  seccomp.reset()
  cache.reset()
  fault.reset()
  state.active = nil
  state.initialized = false
  M.init()
end

return M
