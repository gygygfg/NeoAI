--- 沙箱控制面入口
--- @module NeoAI.sandbox
--- 为工具执行提供受约束的工作区修改、候选冻结、CAS 发布与 dry-run/commit。
--- 所有工具执行经 wrapper.gate；加载器为工具附加 __sandbox 规格。
---
--- 不变量（设计文档 §1.1）：
---   dry-run 不构成安全边界；隔离执行只改私有状态；commit 只发布已冻结候选；
---   硬拒绝不可被确认覆盖；未知结果不报告为成功。

local config_store = require("NeoAI.kernel.config_store")
local instance = require("NeoAI.sandbox.instance")
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
local privilege = require("NeoAI.sandbox.privilege")
local hostop = require("NeoAI.sandbox.hostop")
local cache = require("NeoAI.sandbox.cache")
local fault = require("NeoAI.sandbox.fault")
local bench = require("NeoAI.sandbox.bench")
local risk = require("NeoAI.sandbox.risk")
local audit = require("NeoAI.sandbox.audit")
local container = require("NeoAI.sandbox.container")
local secret = require("NeoAI.sandbox.secret")
local trace = require("NeoAI.sandbox.trace")
local events = require("NeoAI.kernel.events")

local M = {}

-- ========== 私有状态 ==========

local state = {
  initialized = false,
  active = nil, -- 当前暂存尝试（供 persist_buffer 重定向）
  session_unsubs = nil, -- 会话轮换的事件订阅句柄
  gc_scheduled = false, -- 已调度过期实例目录回收
  warm_scheduled = false, -- 已调度运行时能力/overlay 探测预热（每进程一次）
}

-- ========== 私有函数 ==========

local function _base_root()
  return config_store.get("tools.sandbox.workspace_root")
    or (vim.fn.stdpath("cache") .. "/NeoAI/sandbox")
end

--- 本进程的实例作用域 store 根。待审队列/候选/回执/证据均落在此目录下，
--- 与其它并发 nvim 实例完全隔离（见 sandbox.instance）。
--- @return string
local function _root()
  return instance.root(_base_root())
end

local function _emit(event, payload)
  local event_bus = require("NeoAI.kernel.event_bus")
  event_bus.emit(event, payload or {})
end

--- 把持久化的待审变更单元重新物化进当前沙箱会话的暂存层。
--- 插件热重载 / 重开时 `shutdown` 会清空暂存目录，但待审队列仍落盘；若不再物化，
--- 只读工具会看不到这些待审修改（沙箱视图与待审队列不一致）。此处按候选内容重建。
local function _rehydrate_pending()
  local ok, items = pcall(review.list)
  if not ok or type(items) ~= "table" then return end
  for _, item in ipairs(items) do
    -- 待审（PENDING）与已批准但尚未应用（APPROVED/NOT_REQUESTED）的候选都要重新物化：
    -- 包安装等大批量暂存内容在重启后仍应可读、可应用，直到真正应用或拒绝。
    local st = item.review_state
    local ap = item.apply_state
    local keep = st == review.REVIEW.PENDING
      or (st == review.REVIEW.APPROVED and ap == review.APPLY.NOT_REQUESTED)
    if keep then
      local cand = store.read_candidate(item.candidate_digest)
      if cand then pcall(candidate.merge_candidate, cand) end
    end
  end
end

-- ========== 公开 API ==========

--- 初始化：准备本进程隔离的存储，并水合本进程的待审队列。
--- 启动路径保持非阻塞：不再在 setup 时同步探测运行时能力（`runtime.capabilities()`
--- 首次真正需要时惰性探测），过期实例目录的回收延迟到启动完成后调度。
--- @return table
function M.init()
  if state.initialized then return M end
  local root = _root()
  store.init(root)
  cache.init(root)
  candidate.ensure_dirs(root)
  state.initialized = true
  _rehydrate_pending()
  -- 启动探测内核级观测后端（eBPF/strace/procfs）：不可用或发生回退时 notify（异步，不阻塞启动）。
  vim.schedule(function()
    pcall(function() require("NeoAI.sandbox.observer").notify_backend() end)
  end)
  if not state.gc_scheduled then
    state.gc_scheduled = true
    local base = _base_root()
    vim.schedule(function() pcall(instance.gc, base) end)
  end
  -- 预热运行时能力与 overlay 可写性探测：把首条进程命令开始处的同步功能实测（bwrap/
  -- overlay，约百 ms）提前到启动空闲时机完成并写入缓存，避免 run_command 开始时卡主线程。
  -- 每进程一次；延迟一小段让启动 UI 先渲染。探测函数被替换（测试桩）时跳过，避免干扰。
  if not state.warm_scheduled then
    state.warm_scheduled = true
    local probe_ref = runtime.probe
    vim.defer_fn(function()
      if runtime.probe ~= probe_ref then return end
      pcall(runtime.warm)
    end, 200)
  end
  -- 后台统计一次沙箱暂存磁盘用量（供磁盘上限门禁读缓存；不阻塞启动）。
  vim.schedule(function() pcall(function() require("NeoAI.sandbox.disk").refresh(true) end) end)
  return M
end

--- 配置的沙箱存储基根（所有实例目录的父级；不含本进程实例子目录）
--- @return string
function M.base_root()
  return _base_root()
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
  M.unwatch_sessions()
  pcall(function() require("NeoAI.sandbox.net_gateway").teardown() end)
  pcall(function() require("NeoAI.sandbox.host_proxy").stop() end)
  -- 停止长驻服务：捕获其改动为候选并合并回暂存（有界等待），避免服务进程跨关闭残留。
  pcall(function() require("NeoAI.sandbox.service").stop_all({ timeout_ms = 10000 }) end)
  -- 停止会话级常驻沙箱实例（连同其命名空间内的后台进程）。
  pcall(function() require("NeoAI.sandbox.resident").stop({ timeout_ms = 2000 }) end)
  -- 先等后台后处理（异步模式下命令结果已返回、捕获/冻结/结算未完成）与异步写入落盘，
  -- 避免关闭时丢失最后一笔冻结与待审入队。等待有上限（tools.sandbox.shutdown_timeout_ms，
  -- 默认 3s）：后处理卡住时不至于让 `:qall` / 插件热重载长时间无响应。
  local timeout = tonumber(config_store.get("tools.sandbox.shutdown_timeout_ms"))
  if timeout == nil then timeout = 3000 end
  timeout = math.max(0, timeout)
  pcall(function() require("NeoAI.sandbox.wrapper").await_postprocess(timeout) end)
  pcall(function() require("NeoAI.sandbox.store").flush(timeout) end)
  candidate.reset(timeout)
  state.active = nil
  state.initialized = false
end

--- 订阅 agent 生命周期，在 agentEnd（生成结束/错误/取消/中止）时轮换沙箱会话。
--- 同一 agent 循环内共用同一会话（编辑可叠加）；跨循环切换到新会话但迁移暂存内容，
--- 保证文件修改的一致性。幂等，返回取消订阅函数。
--- @return function|nil 取消订阅
function M.watch_sessions()
  if state.session_unsubs then return end
  local event_bus = require("NeoAI.kernel.event_bus")
  local events = require("NeoAI.kernel.events")
  local unsubs = {}
  local function rotate(payload)
    -- 仅当「当前主 Agent 仍在工作」时才抑制非本 Agent 的轮换。子 Agent / 辅助生成也会
    -- 发同名 GENERATION_* 事件；若其结束就轮换，会删除主循环仍在使用的暂存目录
    -- （进程 bind 挂载源），使运行中的 run_command 突然 ENOENT，表现为间歇性
    -- `cd: can't cd to ...`。无当前 Agent（测试/无会话）或主 Agent 已空闲时保持旧行为。
    local agent_id = type(payload) == "table" and payload.agent_id or nil
    if agent_id ~= nil then
      local ok, chat = pcall(require, "NeoAI.services.chat_service")
      if ok and chat and type(chat.get_current_agent) == "function" then
        local cur = chat.get_current_agent()
        local busy = type(chat.has_pending_work) == "function" and chat.has_pending_work()
        if cur and cur.id and cur.id ~= agent_id and busy then
          return
        end
      end
    end
    -- 会话轮换前先终止常驻沙箱实例（其命名空间绑定当前会话的 overlay 目录）。
    pcall(function() require("NeoAI.sandbox.resident").stop({ timeout_ms = 2000 }) end)
    pcall(candidate.rotate_session)
  end
  for _, ev in ipairs({
    events.GENERATION_COMPLETED,
    events.GENERATION_ERROR,
    events.GENERATION_CANCELLED,
    events.AGENT_ABORTED,
  }) do
    unsubs[#unsubs + 1] = event_bus.on(ev, rotate)
  end
  state.session_unsubs = unsubs
  return M.unwatch_sessions
end

--- 取消会话轮换订阅（插件卸载/测试用）
function M.unwatch_sessions()
  for _, u in ipairs(state.session_unsubs or {}) do
    if u then pcall(u) end
  end
  state.session_unsubs = nil
end

--- 当前沙箱会话 id
--- @return string|nil
function M.session_id()
  return candidate.session_id()
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
  if ok then
    -- 候选已删除：对应待审项必须同步标记为已拒绝，否则重新打开审批界面会
    -- 再次显示一个无法应用的待审项（候选已不存在）。
    review.discard_by_digest(digest, "DISCARDED")
    _emit(events.SANDBOX_DISCARDED, { candidate_digest = digest })
  end
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

--- 待审摘要：文件数 + 最高安全级别（供状态栏徽标与 L3 危险高亮）
--- @return table { count = number, max_level = number|nil }
function M.pending_summary()
  return review.pending_summary()
end

--- 是否有后台后处理在途（异步模式下命令结果已返回、捕获/冻结/结算尚未完成）
--- @return boolean
function M.postprocess_pending()
  return require("NeoAI.sandbox.wrapper").postprocess_pending()
end

--- 等待后台后处理完成（测试/关闭前调用）
--- @param timeout_ms number|nil
--- @return boolean
function M.await_postprocess(timeout_ms)
  return require("NeoAI.sandbox.wrapper").await_postprocess(timeout_ms)
end

--- 越界访问留痕（访问 cwd 之外用户工作目录；供审批悬浮窗展示）
--- @return table 数组
function M.list_traces()
  return trace.list()
end

--- 越界访问留痕（按文件路径合并、排序；供审批悬浮窗展示）
--- @return table 数组
function M.list_traces_grouped()
  return trace.list_grouped()
end

--- 越界访问留痕的去重文件数（供状态栏徽标）
--- @return number
function M.trace_count()
  return trace.file_count()
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

--- 拒绝变更单元中的单个文件（其余文件保留待审）
--- @param id string
--- @param path string
--- @param reason string|nil
--- @return table|nil
function M.reject_file(id, path, reason)
  return review.reject_file(id, path, reason)
end

--- 应用变更单元（CAS 发布；opts.files 支持选择性应用）
--- @param id string
--- @param opts table|nil
--- @return table
function M.apply(id, opts)
  return review.apply(id, opts)
end

--- 撤销/重做保存：把真实文件与保存时保留的原文件快照交换（可反复切换）
--- @param id string change_set_id
--- @param opts table|nil { allow_root?, prefer_sudo?, force? }
--- @return table { ok, state, reason? }
function M.undo(id, opts)
  M.init()
  return review.undo(id, opts)
end

--- 列出已保存/已撤销（含快照）的变更单元
--- @return table 数组
function M.list_saved()
  M.init()
  local out = {}
  for _, item in ipairs(review.list()) do
    if item.snapshot_id and (item.apply_state == review.APPLY.APPLIED
        or item.apply_state == review.APPLY.REVERTED) then
      -- 附加快照文件清单（选择性应用时 item.files 可能含未应用文件）。
      local snap = store.read_snapshot(item.snapshot_id)
      local files = {}
      for _, e in ipairs((snap and snap.files) or {}) do
        files[#files + 1] = { path = e.path, action = e.action, side = e.side }
      end
      item.saved_files = files
      out[#out + 1] = item
    end
  end
  return out
end

--- 应用全部待审/已批准变更单元
--- @param opts table|nil
--- @return table
function M.apply_all(opts)
  return review.apply_all(opts)
end

--- 开始批量应用会话：会话内 apply(id, { batch = ctx }) 把候选删除推迟到 end_batch
--- 统一对账（避免逐项 O(n) 全表扫描在待审堆积时退化为 O(n²)）。供 UI 逐项让出主循环时使用。
--- @return table ctx
function M.begin_batch()
  return review.begin_batch()
end

--- 结束批量应用会话：一次对账删除会话内已应用的候选。
--- @param ctx table
function M.end_batch(ctx)
  return review.end_batch(ctx)
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
      or item.apply_state == review.APPLY.REVERTED
      or item.apply_state == review.APPLY.FAILED
      or item.apply_state == review.APPLY.CONFLICT
    if stale and terminal then
      store.discard_candidate(item.candidate_digest)
      if item.snapshot_id then store.delete_snapshot(item.snapshot_id) end
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
M.privilege = privilege
M.hostop = hostop
M.cache = cache
M.fault = fault
M.bench = bench
M.risk = risk
M.audit = audit
M.container = container
M.secret = secret
M.trace = trace

--- 重置（测试用）
function M.reset()
  -- 确保 store 根已知：前序代码可能已调用 store.reset() 将 root 置空；此时直接
  -- store.reset() 会因 root 为 nil 而 no-op，无法删除磁盘上的残留候选/待审，造成
  -- 跨 reset/跨套件污染。先按当前实例根初始化，使其可被清理。
  if not store.root() then store.init(_root()) end
  -- 等待后台后处理完成，避免 reset 时仍有在途捕获/冻结/结算写入旧实例目录造成污染。
  pcall(function() require("NeoAI.sandbox.wrapper").await_postprocess(60000) end)
  -- 停止长驻服务并回收其 overlay/cgroup（先于 candidate/control/store 清理）。
  pcall(function() require("NeoAI.sandbox.service").reset() end)
  -- 停止会话级常驻沙箱实例（连同其后台进程与资源域）。
  pcall(function() require("NeoAI.sandbox.resident").reset() end)
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
  privilege.reset()
  hostop.reset()
  cache.reset()
  fault.reset()
  risk.reset()
  audit.reset()
  container.reset()
  pcall(function() require("NeoAI.sandbox.systemd").reset() end)
  require("NeoAI.sandbox.secret").reset()
  trace.reset()
  pcall(function() require("NeoAI.sandbox.net_gateway").reset() end)
  pcall(function() require("NeoAI.sandbox.host_proxy").reset() end)
  pcall(function() require("NeoAI.sandbox.disk").reset() end)
  -- 回收观测预热（后台预挂载的 bpftrace 探针 + 预创建 cgroup），避免 reset 后残留。
  pcall(function() require("NeoAI.sandbox.wrapper").clear_prewarm() end)
  state.active = nil
  state.initialized = false
  M.init()
  -- 测试专用：reset 期望重置后立即具备确定的能力状态，故此处同步探测一次。
  -- 生产启动路径（setup → init）仍保持惰性探测，不在此列。
  pcall(runtime.probe)
end

return M
