--- 异步审批：变更单元（change_set）队列
--- @module NeoAI.sandbox.review
--- AI 的修改在沙箱中立即执行并冻结为候选，进入待审队列；用户异步确认允许
--- 哪些文件/配置修改后，才 CAS 发布到真实工作区（设计文档 §15）。
---
--- 三条状态线（work/review/apply）中本模块持有 review_state 与 apply_state：
---   review_state: PENDING | APPROVED | REJECTED | EXPIRED | SUPERSEDED
---   apply_state : NOT_REQUESTED | APPLYING | APPLIED | CONFLICT | FAILED | RECONCILING

local store = require("NeoAI.sandbox.store")
local candidate = require("NeoAI.sandbox.candidate")

local M = {}

-- ========== 状态常量 ==========

M.REVIEW = {
  PENDING = "PENDING",
  APPROVED = "APPROVED",
  REJECTED = "REJECTED",
  EXPIRED = "EXPIRED",
  SUPERSEDED = "SUPERSEDED",
}

M.APPLY = {
  NOT_REQUESTED = "NOT_REQUESTED",
  APPLYING = "APPLYING",
  APPLIED = "APPLIED",
  CONFLICT = "CONFLICT",
  FAILED = "FAILED",
  RECONCILING = "RECONCILING",
}

-- ========== 私有状态 ==========

local state = {
  items = {}, -- change_set_id -> item
  seq = 0,
}

-- ========== 私有函数 ==========

local function _emit(event, payload)
  local event_bus = require("NeoAI.kernel.event_bus")
  event_bus.emit(event, payload or {})
end

local function _persist(item)
  pcall(store.write_review, item)
end

--- @param content string
--- @return string
local function _sha(content)
  local ok, hex = pcall(vim.fn.sha256, content or "")
  return ok and ("sha256:" .. hex) or "sha256:?"
end

--- 从候选构造写集合（供展示与选择性应用）
--- @param cand table
--- @return table 数组
local function _write_set(cand)
  local out = {}
  for _, f in ipairs(cand.files or {}) do out[#out + 1] = f.path end
  return out
end

-- ========== 公开 API ==========

--- 入队一个候选为待审变更单元
--- @param cand table 冻结候选
--- @param meta table { tool?, command_id?, attempt_id?, base_version?, read_set? }
--- @return table item
function M.enqueue(cand, meta)
  meta = meta or {}
  -- 空候选（无文件改动）没有审批意义，不入待审队列，避免出现「0 个文件」空项。
  if #(cand and cand.files or {}) == 0 then return nil end
  -- 密钥防护：候选内容涉及 token（密钥被加密映射）时生成警告。
  local secret_warning = meta.secret_warning
  if secret_warning == nil then
    local ok, s = pcall(require, "NeoAI.sandbox.secret")
    if ok and s.enabled() then secret_warning = s.warn_for_files(cand.files) end
  end
  state.seq = state.seq + 1
  local id = meta.id or string.format("cs_%d_%s", state.seq, tostring(os.time()))
  local item = {
    change_set_id = id,
    revision = meta.revision or 1,
    supersedes = meta.supersedes,
    candidate_digest = cand.candidate_digest,
    base_version = meta.base_version or cand.command_id,
    tool = meta.tool,
    command_id = meta.command_id or cand.command_id,
    attempt_id = meta.attempt_id,
    read_set = meta.read_set or {},
    write_set = _write_set(cand),
    files = cand.files or {},
    effect = cand.effect,
    evidence = meta.evidence or {},
    stats = meta.stats or {},
    -- 密钥防护：候选内容涉及 token 操作时的警告（供待审界面醒目提示）
    secret_warning = secret_warning,
    depends_on = meta.depends_on or {},
    atomic_group = meta.atomic_group,
    review_state = M.REVIEW.PENDING,
    apply_state = M.APPLY.NOT_REQUESTED,
    created_at = os.time(),
  }
  state.items[id] = item
  _persist(item)
  _emit(require("NeoAI.kernel.events").SANDBOX_REVIEW_ENQUEUED, {
    change_set_id = id,
    candidate_digest = cand.candidate_digest,
    write_set = item.write_set,
    tool = item.tool,
  })
  return item
end

--- 入队一条主机操作提案（T2 特权档的主机效果，审批后 replay）
--- @param rec table hostop 记录
--- @return table item
function M.enqueue_host_op(rec)
  state.seq = state.seq + 1
  local id = string.format("cs_%d_%s", state.seq, tostring(os.time()))
  local item = {
    change_set_id = id,
    kind = "host_op",
    host_op_id = rec.host_op_id,
    candidate_digest = "host_op:" .. tostring(rec.host_op_id),
    tool = rec.tool,
    command_id = rec.command_id,
    attempt_id = rec.attempt_id,
    write_set = { rec.command },
    files = {},
    privilege_tier = rec.tier,
    effect = "process",
    review_state = M.REVIEW.PENDING,
    apply_state = M.APPLY.NOT_REQUESTED,
    created_at = os.time(),
  }
  state.items[id] = item
  _persist(item)
  return item
end

--- 获取变更单元（带内存缓存，保证引用稳定）
--- @param id string
--- @return table|nil
function M.get(id)
  local item = state.items[id]
  if item then return item end
  item = store.read_review(id)
  if item then state.items[id] = item end
  return item
end

--- 列出变更单元
--- @param filter table|nil { review_state?, apply_state? }
--- @return table 数组
function M.list(filter)
  filter = filter or {}
  local out = {}
  local seen = {}
  -- 内存态优先（含未落盘的最新状态）
  for id, item in pairs(state.items) do
    seen[id] = true
    out[#out + 1] = item
  end
  for _, item in ipairs(store.list_reviews()) do
    if not seen[item.change_set_id] then out[#out + 1] = item end
  end
  local filtered = {}
  for _, item in ipairs(out) do
    -- 过滤空变更单元（0 文件）：历史持久化记录可能残留，无审批意义。
    -- 主机操作提案（host_op）无文件但必须保留。
    local has_files = (item.files and #item.files > 0) or (item.write_set and #item.write_set > 0)
    if (has_files or item.kind == "host_op")
      and (not filter.review_state or item.review_state == filter.review_state)
      and (not filter.apply_state or item.apply_state == filter.apply_state) then
      filtered[#filtered + 1] = item
    end
  end
  table.sort(filtered, function(a, b) return (a.created_at or 0) < (b.created_at or 0) end)
  return filtered
end

--- 待审数量（按文件计：审批单位为单个文件，与审批界面一致）
--- 一个变更单元可能含多个文件，用户需逐个确认，故徽标数应为待审文件总数。
--- @return number
function M.pending_count()
  local n = 0
  for _, item in ipairs(M.list({ review_state = M.REVIEW.PENDING })) do
    if item.kind == "host_op" then
      n = n + 1
    else
      local count = #(item.files or {})
      if count == 0 then count = #(item.write_set or {}) end
      n = n + count
    end
  end
  return n
end

--- 批准变更单元（不应用）
--- @param id string
--- @return table|nil item
function M.approve(id)
  local item = M.get(id)
  if not item then return nil end
  if item.review_state == M.REVIEW.REJECTED then return item end
  item.review_state = M.REVIEW.APPROVED
  item.approved_at = os.time()
  state.items[id] = item
  _persist(item)
  _emit(require("NeoAI.kernel.events").SANDBOX_REVIEW_APPROVED, { change_set_id = id })
  return item
end

--- 拒绝变更单元（丢弃候选，不应用）
--- @param id string
--- @param reason string|nil
--- @return table|nil item
function M.reject(id, reason)
  local item = M.get(id)
  if not item then return nil end
  item.review_state = M.REVIEW.REJECTED
  item.reject_reason = reason
  item.rejected_at = os.time()
  state.items[id] = item
  if item.kind == "host_op" then
    pcall(function() require("NeoAI.sandbox.hostop").reject(item.host_op_id, reason) end)
    _persist(item)
    _emit(require("NeoAI.kernel.events").SANDBOX_REVIEW_REJECTED, { change_set_id = id, reason = reason })
    return item
  end
  store.discard_candidate(item.candidate_digest)
  -- 拒绝后暂存副本失效：后续编辑应重新以真实文件为基线，不能带上被拒改动。
  candidate.invalidate(item.write_set)
  _persist(item)
  _emit(require("NeoAI.kernel.events").SANDBOX_REVIEW_REJECTED, { change_set_id = id, reason = reason })
  return item
end

--- 拒绝变更单元中的单个文件（其余文件保留待审，按文件审批）
--- @param id string
--- @param path string
--- @param reason string|nil
--- @return table|nil item 剩余文件的待审项；无剩余时返回被拒绝的原项
function M.reject_file(id, path, reason)
  local item = M.get(id)
  if not item then return nil end
  local files = item.files
  if not files or #files == 0 then
    return M.reject(id, reason)
  end
  local remaining_paths = {}
  local found = false
  for _, f in ipairs(files) do
    if f.path == path then found = true else remaining_paths[#remaining_paths + 1] = f.path end
  end
  if not found then return item end
  -- 被拒文件的暂存副本失效：后续编辑重新以真实文件为基线，不带上被拒改动。
  candidate.invalidate({ path })
  if #remaining_paths == 0 then
    return M.reject(id, reason)
  end
  local child = M.derive_revision(id, { paths = remaining_paths })
  if not child then
    -- 候选缺失等异常：退化为整单元拒绝，保证不残留无法处理的待审项。
    return M.reject(id, reason)
  end
  _emit(require("NeoAI.kernel.events").SANDBOX_REVIEW_REJECTED, {
    change_set_id = id, path = path, reason = reason,
  })
  return child
end

--- 将选择性应用后剩余的文件重新入队为新的待审变更单元（按文件审批）。
--- @param item table 原变更单元
--- @param remaining table 剩余文件数组
--- @return table|nil 新变更单元
local function _requeue_remaining(item, remaining)
  if #remaining == 0 then return nil end
  local manifest = {}
  for _, f in ipairs(remaining) do
    manifest[#manifest + 1] = { path = f.path, action = f.action, after_hash = f.after_hash }
  end
  local json = require("NeoAI.utils.json")
  local newcand = {
    candidate_digest = "sha256:" .. vim.fn.sha256(json.encode(manifest)),
    files = remaining,
    created_at = os.time(),
    effect = item.effect,
    command_id = item.command_id,
  }
  store.write_candidate(newcand)
  return M.enqueue(newcand, {
    tool = item.tool,
    revision = item.revision or 1,
    supersedes = item.change_set_id,
    base_version = item.base_version,
    evidence = item.evidence,
    stats = item.stats,
    depends_on = item.depends_on,
    atomic_group = item.atomic_group,
  })
end

--- 应用变更单元（CAS 发布到真实工作区）
--- 支持选择性应用：opts.files 指定允许的文件子集（按单个文件审批）。
--- @param id string
--- @param opts table|nil { files?: string[], auto_approve?: boolean }
--- @return table { ok, state, reason?, receipt? }
function M.apply(id, opts)
  opts = opts or {}
  local item = M.get(id)
  if not item then
    return { ok = false, state = "FAILED", reason = "CHANGE_SET_NOT_FOUND: " .. tostring(id) }
  end
  -- 主机操作提案：审批后在主机上 replay（无候选、无文件）
  if item.kind == "host_op" then
    if opts.auto_approve and item.review_state == M.REVIEW.PENDING then M.approve(id) end
    if item.review_state ~= M.REVIEW.APPROVED then
      return { ok = false, state = "NOT_APPROVED", reason = "CHANGE_SET_NOT_APPROVED: " .. tostring(id) }
    end
    item.apply_state = M.APPLY.APPLYING
    _persist(item)
    local res = require("NeoAI.sandbox.hostop").replay(item.host_op_id)
    item.apply_state = res.ok and M.APPLY.APPLIED or M.APPLY.FAILED
    item.fail_reason = res.reason
    state.items[id] = item
    _persist(item)
    return res
  end
  if opts.auto_approve and item.review_state == M.REVIEW.PENDING then
    M.approve(id)
  end
  if item.review_state ~= M.REVIEW.APPROVED then
    return { ok = false, state = "NOT_APPROVED", reason = "CHANGE_SET_NOT_APPROVED: " .. tostring(id) }
  end
  local cand = store.read_candidate(item.candidate_digest)
  if not cand then
    return { ok = false, state = "FAILED", reason = "CANDIDATE_NOT_FOUND: " .. tostring(item.candidate_digest) }
  end
  -- 选择性应用：按允许文件子集过滤候选，未选中的文件保留为新的待审项
  local remaining = {}
  if opts.files and #opts.files > 0 then
    local allow = {}
    for _, p in ipairs(opts.files) do allow[p] = true end
    local filtered = {}
    for _, f in ipairs(cand.files or {}) do
      if allow[f.path] then filtered[#filtered + 1] = f else remaining[#remaining + 1] = f end
    end
    if #filtered == 0 then
      return { ok = false, state = "FAILED", reason = "NO_FILES_SELECTED" }
    end
    cand = vim.deepcopy(cand)
    cand.files = filtered
    cand.candidate_digest = cand.candidate_digest .. ":subset" .. tostring(#filtered)
  end

  item.apply_state = M.APPLY.APPLYING
  _persist(item)
  _emit(require("NeoAI.kernel.events").SANDBOX_PUBLISH_STARTED, {
    change_set_id = id, candidate_digest = item.candidate_digest,
  })
  local pub = candidate.publish(cand, { expected_base = item.base_version })
  if pub.ok then
    item.apply_state = M.APPLY.APPLIED
    item.applied_at = os.time()
    item.receipt = pub.receipt
    store.write_receipt(pub.receipt)
    store.discard_candidate(item.candidate_digest)
    _persist(item)
    -- 仅应用了部分文件：其余文件保留待审，供用户逐个确认
    if #remaining > 0 then _requeue_remaining(item, remaining) end
    _emit(require("NeoAI.kernel.events").SANDBOX_APPLIED, {
      change_set_id = id, operation_id = pub.receipt.operation_id,
    })
  else
    item.apply_state = pub.state == "CONFLICT" and M.APPLY.CONFLICT or M.APPLY.FAILED
    item.fail_reason = pub.reason
    _persist(item)
    _emit(require("NeoAI.kernel.events").SANDBOX_CONFLICT, {
      change_set_id = id, reason = pub.reason,
    })
  end
  return pub
end

--- 应用所有已批准（或全部待审）变更单元
--- @param opts table|nil { only_approved?: boolean }
--- @return table { applied, failed }
function M.apply_all(opts)
  opts = opts or {}
  local result = { applied = 0, failed = 0 }
  local items = opts.only_approved
    and M.list({ review_state = M.REVIEW.APPROVED })
    or M.list({ review_state = M.REVIEW.PENDING })
  for _, item in ipairs(items) do
    local res = M.apply(item.change_set_id, { auto_approve = true })
    if res.ok then result.applied = result.applied + 1 else result.failed = result.failed + 1 end
  end
  return result
end

--- 将某候选摘要对应的待审变更单元标记为已应用（供直接 commit 后对账）
--- @param digest string
--- @param operation_id string|nil
function M.supersede_by_digest(digest, operation_id)
  for _, item in ipairs(M.list()) do
    if item.candidate_digest == digest and item.review_state == M.REVIEW.PENDING then
      item.review_state = M.REVIEW.APPROVED
      item.apply_state = M.APPLY.APPLIED
      item.receipt = operation_id and { operation_id = operation_id } or nil
      state.items[item.change_set_id] = item
      _persist(item)
    end
  end
end

--- 丢弃指定候选摘要对应的待审变更单元（供候选被显式丢弃后对账）。
--- 候选被 `sandbox.discard` 删除后，其待审项若仍为 PENDING，会在下次打开聊天界面/
--- 审批界面时重新出现且无法应用；此处统一标记为 REJECTED 并失效暂存副本。
--- @param digest string
--- @param reason string|nil
--- @return number 更新的变更单元数
function M.discard_by_digest(digest, reason)
  if not digest then return 0 end
  local n = 0
  for _, item in ipairs(M.list({ review_state = M.REVIEW.PENDING })) do
    if item.candidate_digest == digest then
      item.review_state = M.REVIEW.REJECTED
      item.reject_reason = reason or "DISCARDED"
      item.rejected_at = os.time()
      state.items[item.change_set_id] = item
      candidate.invalidate(item.write_set)
      _persist(item)
      _emit(require("NeoAI.kernel.events").SANDBOX_REVIEW_REJECTED, {
        change_set_id = item.change_set_id, reason = item.reject_reason,
      })
      n = n + 1
    end
  end
  return n
end

--- 取代（SUPERSEDED）覆盖指定路径的旧待审变更单元。
--- 同一文件被再次编辑/发布时，旧待审项不再有意义（内容已被更新版本覆盖），
--- 标记为 SUPERSEDED 并丢弃候选，避免同一文件在队列中出现多个版本。
--- @param paths table 路径数组
--- @param except_id string|nil 不取代的 change_set_id（通常是刚入队的新项）
--- @return number superseded 被取代的数量
function M.supersede_by_paths(paths, except_id)
  local set = {}
  for _, p in ipairs(paths or {}) do set[p] = true end
  if not next(set) then return 0 end
  local n = 0
  for _, item in ipairs(M.list({ review_state = M.REVIEW.PENDING })) do
    if item.change_set_id ~= except_id then
      local overlap = false
      for _, f in ipairs(item.files or {}) do
        if set[f.path] then overlap = true break end
      end
      if overlap then
        item.review_state = M.REVIEW.SUPERSEDED
        item.superseded_by = except_id
        item.superseded_at = os.time()
        state.items[item.change_set_id] = item
        store.discard_candidate(item.candidate_digest)
        _persist(item)
        _emit(require("NeoAI.kernel.events").SANDBOX_REVIEW_SUPERSEDED, {
          change_set_id = item.change_set_id, superseded_by = except_id,
        })
        n = n + 1
      end
    end
  end
  return n
end

-- ========== 依赖图与组合发布（阶段四）==========

--- 计算变更单元的依赖闭包（拓扑序，依赖在前）
--- @param id string
--- @return table { order = string[], missing = string[], cycle = boolean }
function M.dependencies(id)
  local order, missing, visiting, visited = {}, {}, {}, {}
  local cycle = false
  local function visit(cid)
    if visited[cid] then return end
    if visiting[cid] then cycle = true; return end
    visiting[cid] = true
    local item = M.get(cid)
    if not item then missing[#missing + 1] = cid; visiting[cid] = nil; return end
    for _, dep in ipairs(item.depends_on or {}) do visit(dep) end
    visiting[cid] = nil
    visited[cid] = true
    order[#order + 1] = cid
  end
  visit(id)
  return { order = order, missing = missing, cycle = cycle }
end

--- 合并多个成员候选为组合候选（按路径；同路径不同内容视为冲突）
--- @param members table 变更单元数组
--- @return table { candidate?, conflicts = table }
local function _compose(members)
  local by_path = {}
  local conflicts = {}
  for _, item in ipairs(members) do
    local cand = store.read_candidate(item.candidate_digest)
    if not cand then
      conflicts[#conflicts + 1] = { reason = "CANDIDATE_NOT_FOUND", change_set_id = item.change_set_id }
    else
      for _, f in ipairs(cand.files or {}) do
        local prev = by_path[f.path]
        if prev and prev.after_hash ~= f.after_hash then
          conflicts[#conflicts + 1] = { reason = "PATH_CONFLICT", path = f.path, a = prev.change_set_id, b = item.change_set_id }
        else
          local copy = vim.deepcopy(f)
          copy.change_set_id = item.change_set_id
          by_path[f.path] = copy
        end
      end
    end
  end
  local files = {}
  for _, f in pairs(by_path) do files[#files + 1] = f end
  table.sort(files, function(a, b) return a.path < b.path end)
  local manifest = {}
  for _, f in ipairs(files) do manifest[#manifest + 1] = { path = f.path, action = f.action, after_hash = f.after_hash } end
  local json = require("NeoAI.utils.json")
  local digest = "sha256:" .. vim.fn.sha256(json.encode(manifest))
  return { candidate = { candidate_digest = digest, files = files, created_at = os.time() }, conflicts = conflicts }
end

--- 生成组合发布集合（依赖闭包 + 组合候选 + 意图摘要）
--- 不产生发布副作用（设计文档 §15.4）。
--- @param ids table 选中的 change_set_id 数组
--- @return table { state, members, missing, cycle, conflicts, candidate?, publication_intent_hash? }
function M.prepare_publication_set(ids)
  local members, missing, cycle = {}, {}, false
  local seen = {}
  for _, id in ipairs(ids or {}) do
    local deps = M.dependencies(id)
    if deps.cycle then cycle = true end
    for _, m in ipairs(deps.missing) do missing[#missing + 1] = m end
    for _, cid in ipairs(deps.order) do
      if not seen[cid] then
        seen[cid] = true
        local item = M.get(cid)
        if item then members[#members + 1] = item end
      end
    end
  end
  if #missing > 0 then
    return { state = "BLOCKED_DEPENDENCY", members = members, missing = missing, cycle = cycle }
  end
  if cycle then
    return { state = "BLOCKED_DEPENDENCY", members = members, missing = {}, cycle = true }
  end
  local composed = _compose(members)
  if #composed.conflicts > 0 then
    return { state = "CONFLICT", members = members, conflicts = composed.conflicts }
  end
  local json = require("NeoAI.utils.json")
  local revisions = {}
  for _, m in ipairs(members) do revisions[#revisions + 1] = { id = m.change_set_id, revision = m.revision or 1, digest = m.candidate_digest } end
  local intent_hash = "sha256:" .. vim.fn.sha256(json.encode({
    members = revisions,
    candidate_digest = composed.candidate.candidate_digest,
  }))
  return {
    state = "READY",
    members = members,
    missing = {},
    conflicts = {},
    candidate = composed.candidate,
    publication_intent_hash = intent_hash,
  }
end

--- 应用组合发布集合（CAS 发布组合候选）
--- @param set table prepare_publication_set 返回
--- @return table { ok, state, reason?, receipt? }
function M.apply_set(set)
  if not set or set.state ~= "READY" or not set.candidate then
    return { ok = false, state = set and set.state or "FAILED", reason = "PUBLICATION_SET_NOT_READY" }
  end
  local pub = candidate.publish(set.candidate, { expected_base = set.publication_intent_hash })
  if pub.ok then
    store.write_receipt(pub.receipt)
    store.discard_candidate(set.candidate.candidate_digest)
    for _, m in ipairs(set.members or {}) do
      m.review_state = M.REVIEW.APPROVED
      m.apply_state = M.APPLY.APPLIED
      m.applied_at = os.time()
      m.receipt = pub.receipt
      state.items[m.change_set_id] = m
      _persist(m)
      store.discard_candidate(m.candidate_digest)
      _emit(require("NeoAI.kernel.events").SANDBOX_APPLIED, {
        change_set_id = m.change_set_id, operation_id = pub.receipt.operation_id,
      })
    end
  else
    for _, m in ipairs(set.members or {}) do
      m.apply_state = pub.state == "CONFLICT" and M.APPLY.CONFLICT or M.APPLY.FAILED
      m.fail_reason = pub.reason
      state.items[m.change_set_id] = m
      _persist(m)
    end
    _emit(require("NeoAI.kernel.events").SANDBOX_CONFLICT, { reason = pub.reason })
  end
  return pub
end

--- 从已有变更单元派生新 revision（用于按文件/hunk 拆分的重新验证）
--- 生成新的组合候选并要求重新审查；原变更单元标记 SUPERSEDED（不迁移旧批准）。
--- @param parent_id string
--- @param opts table { contents?: table<path,string>, paths?: string[] }
--- @return table|nil item
--- @return string|nil err
function M.derive_revision(parent_id, opts)
  opts = opts or {}
  local parent = M.get(parent_id)
  if not parent then return nil, "CHANGE_SET_NOT_FOUND" end
  local cand = store.read_candidate(parent.candidate_digest)
  if not cand then return nil, "CANDIDATE_NOT_FOUND" end
  local files = {}
  if opts.contents then
    for _, f in ipairs(cand.files or {}) do
      local new_content = opts.contents[f.path]
      if new_content ~= nil then
        local copy = vim.deepcopy(f)
        copy.content = new_content
        copy.after_hash = _sha(new_content)
        files[#files + 1] = copy
      end
    end
  elseif opts.paths then
    local allow = {}
    for _, p in ipairs(opts.paths) do allow[p] = true end
    for _, f in ipairs(cand.files or {}) do
      if allow[f.path] then files[#files + 1] = vim.deepcopy(f) end
    end
  else
    for _, f in ipairs(cand.files or {}) do files[#files + 1] = vim.deepcopy(f) end
  end
  if #files == 0 then return nil, "NO_FILES_SELECTED" end
  table.sort(files, function(a, b) return a.path < b.path end)
  local manifest = {}
  for _, f in ipairs(files) do manifest[#manifest + 1] = { path = f.path, action = f.action, after_hash = f.after_hash } end
  local json = require("NeoAI.utils.json")
  local newcand = {
    candidate_digest = _sha(json.encode(manifest)),
    files = files,
    created_at = os.time(),
    effect = parent.effect,
    command_id = parent.command_id,
  }
  store.write_candidate(newcand)
  -- 原变更单元标记 SUPERSEDED，不迁移旧批准
  parent.review_state = M.REVIEW.SUPERSEDED
  state.items[parent_id] = parent
  _persist(parent)
  _emit(require("NeoAI.kernel.events").SANDBOX_REVIEW_SUPERSEDED, { change_set_id = parent_id })
  return M.enqueue(newcand, {
    tool = parent.tool,
    revision = (parent.revision or 1) + 1,
    supersedes = parent_id,
    base_version = parent.base_version,
    evidence = parent.evidence,
    stats = parent.stats,
    depends_on = parent.depends_on,
    atomic_group = parent.atomic_group,
  })
end

--- 重置（测试用）
function M.reset()
  state.items = {}
  state.seq = 0
end

return M
