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
  REVERTED = "REVERTED",
  CONFLICT = "CONFLICT",
  FAILED = "FAILED",
  RECONCILING = "RECONCILING",
  NEEDS_ROOT = "NEEDS_ROOT",
}

-- ========== 私有状态 ==========

local state = {
  items = {}, -- change_set_id -> item
  seq = 0,
  session_auto = nil, -- 会话级自动审批覆盖（nil = 用配置默认，默认关闭）
  loaded = false, -- 是否已从磁盘水合过历史变更单元
  -- 待审摘要缓存：待审堆积到数千时，状态栏每次重绘都全量扫描会随轮次线性变慢；
  -- 任何变更单元写操作（_persist）都会失效缓存，下次读取时重算一次。
  pending_cache = nil,
  pending_items = nil, -- PENDING 项缓存（_pending_items 维护；任何写操作失效）
  ref_scans = 0, -- 诊断：`_candidate_referenced` 全表扫描次数（测试断言批量删除不再逐项扫描）
  -- 终态（REJECTED/SUPERSEDED）变更单元的 FIFO 淘汰序：长期会话中取代风暴会累积大量
  -- 已无意义的终态项，`state.items` 长期驻留会持续占内存。超上限的终态项从内存淘汰，
  -- `M.get` 按需从磁盘回读（数据不丢）。APPLIED/REVERTED 保留（撤销列表需要）。
  terminal_order = {},
  terminal_set = {},
}

-- ========== 候选内容按需读取（内存 item 已剥离 content） ==========

-- 候选文件内容 LRU：内存 item.files 不再长期持有 content（落盘后剥离），diff 预览等
-- 需要时按候选摘要读取单条内容。按 (候选摘要, 路径) 缓存，条目数上限见配置。
local content_lru = {}
local content_lru_order = {}
local content_lru_set = {}

local function _content_limit()
  local n = tonumber(require("NeoAI.kernel.config_store").get(
    "tools.sandbox.review.content_cache_max"))
  if n == nil then n = 64 end
  return math.max(0, n)
end

local function _content_touch(key)
  for i = 1, #content_lru_order do
    if content_lru_order[i] == key then table.remove(content_lru_order, i); break end
  end
  content_lru_order[#content_lru_order + 1] = key
end

local function _content_put(key, content)
  local lim = _content_limit()
  if lim <= 0 then return end
  if content_lru_set[key] then
    content_lru[key] = content
    _content_touch(key)
    return
  end
  content_lru[key] = content
  content_lru_set[key] = true
  content_lru_order[#content_lru_order + 1] = key
  while #content_lru_order > lim do
    local old = table.remove(content_lru_order, 1)
    content_lru[old] = nil
    content_lru_set[old] = nil
  end
end

local function _clear_content_cache()
  content_lru, content_lru_order, content_lru_set = {}, {}, {}
end

-- ========== 私有函数 ==========

--- 首次访问时把磁盘上的历史变更单元水合进内存，之后以内存为准。
--- 关键：`M.list` 此前每次调用都 `store.list_reviews()`（scandir + 逐文件 JSON 解码），
--- 待审堆积到数百/上千时，`supersede_by_paths`（每次工具调用）与状态栏
--- `pending_summary`（每次重绘多次）会退化为 O(n²) 磁盘扫描，占满主线程。
--- 内存态由 review 自身写入维护，进程内即权威来源，无需反复读盘。
local function _ensure_loaded()
  if state.loaded then return end
  state.loaded = true
  local ok, persisted = pcall(store.list_reviews)
  if not ok or type(persisted) ~= "table" then return end
  for _, item in ipairs(persisted) do
    local id = item and item.change_set_id
    if id and not state.items[id] then
      -- 部分取代增量：被更新候选覆盖的路径单独持久化（避免重编码整单元）；水合时并回。
      local removed = store.read_review_removed and store.read_review_removed(id)
      if removed and type(removed.paths) == "table" then item.superseded_paths = removed.paths end
      state.items[id] = item
    end
  end
  state.pending_cache = nil
  state.pending_items = nil
end

--- 待审项缓存（按 created_at 升序）。`supersede_by_paths`/包合并每次工具调用都要遍历待审项，
--- 若每次都对**全部**变更单元（含大量终态项）过滤 + 排序，长会话会逐渐变慢；这里增量维护。
--- 任何写操作（`_persist`）都会失效，下次重建一次。
--- @return table 数组（PENDING 且有文件/主机操作提案）
local function _pending_items()
  if state.pending_items then return state.pending_items end
  _ensure_loaded()
  local out = {}
  for _, item in pairs(state.items) do
    if item.review_state == M.REVIEW.PENDING then
      local has_files = (item.files and #item.files > 0) or (item.write_set and #item.write_set > 0)
      if has_files or item.kind == "host_op" then out[#out + 1] = item end
    end
  end
  table.sort(out, function(a, b) return (a.created_at or 0) < (b.created_at or 0) end)
  state.pending_items = out
  return out
end

local function _emit(event, payload)
  local event_bus = require("NeoAI.kernel.event_bus")
  event_bus.emit(event, payload or {})
end

--- 变更单元是否为「可淘汰的终态」（已拒绝/已被取代，撤销列表不依赖它们）。
--- APPLIED/REVERTED 保留：`list_saved` 需要据此展示撤销/重做。
--- @param item table|nil
--- @return boolean
local function _dead_terminal(item)
  if type(item) ~= "table" then return false end
  return item.review_state == M.REVIEW.REJECTED
    or item.review_state == M.REVIEW.SUPERSEDED
    or item.review_state == M.REVIEW.EXPIRED
end

local function _mark_terminal(id)
  if not id or state.terminal_set[id] then return end
  state.terminal_set[id] = true
  state.terminal_order[#state.terminal_order + 1] = id
end

--- 终态淘汰：超过 `terminal_cache_max` 的终态项从内存移除（磁盘仍有记录，`M.get` 回读）。
local function _maybe_evict()
  local limit = tonumber(require("NeoAI.kernel.config_store").get(
    "tools.sandbox.review.terminal_cache_max"))
  if limit == nil then limit = 200 end
  if limit < 0 then limit = 0 end
  while #state.terminal_order > limit do
    local id = table.remove(state.terminal_order, 1)
    state.terminal_set[id] = nil
    local item = state.items[id]
    if item and _dead_terminal(item) then state.items[id] = nil end
  end
end

--- 落盘后剥离内存 item 的文件内容：候选已单独落盘（`read_candidate` 可读回），
--- 长期持有 content 会让暂存上千文件时内存翻倍。diff 预览经 `M.content_for` 按需读取。
--- @param item table
local function _strip_content(item)
  if type(item) ~= "table" or type(item.files) ~= "table" then return end
  for _, f in ipairs(item.files) do
    if type(f) == "table" and f.content ~= nil then f.content = nil end
  end
end

local function _persist(item)
  -- 写盘即视为状态变更：失效待审摘要缓存（pending_summary 会重算并缓存）与待审项缓存。
  state.pending_cache = nil
  state.pending_items = nil
  -- 异步落盘（文件写入移入线程池）：待审项含候选文件内容，大候选时同步 fsync 会卡主线程。
  -- 内存态是权威来源，store 的写缓存保证刚写入即可同步读回；reset/shutdown 前会 flush。
  pcall(store.write_review_async, item)
  -- 落盘副本已（同步）编码捕获，剥离内存内容（候选内容仍可经候选读取）。
  _strip_content(item)
  -- 部分取代增量单独落盘（避免重编码整单元）；与 item 同步，防止水合时丢失/陈旧。
  if type(item.superseded_paths) == "table" then
    pcall(store.write_review_removed, item.change_set_id, item.superseded_paths)
  end
  -- 终态登记与淘汰（仅在状态写入后；淘汰不影响磁盘记录与候选引用统计）。
  if item.change_set_id and _dead_terminal(item) then _mark_terminal(item.change_set_id) end
  _maybe_evict()
end

--- 部分取代增量中被覆盖的路径数量。
--- @param item table
--- @return number
local function _superseded_count(item)
  local sup = item and item.superseded_paths
  if type(sup) ~= "table" then return 0 end
  local n = 0
  for _ in pairs(sup) do n = n + 1 end
  return n
end

--- 候选是否仍被某个「可应用」变更单元引用。
--- 候选按内容寻址（摘要 = manifest 哈希），同一内容被再次编辑会产生相同摘要，
--- 因此多个变更单元可能共享同一候选文件。删除前必须确认无其他项仍引用，
--- 否则会孤立其待审项，用户点击「允许」时报 CANDIDATE_NOT_FOUND。
--- @param digest string
--- @return boolean
local function _candidate_referenced(digest)
  if not digest then return false end
  _ensure_loaded()
  state.ref_scans = state.ref_scans + 1
  for _, item in pairs(state.items) do
    if item.candidate_digest == digest then
      local terminal = item.review_state == M.REVIEW.REJECTED
        or item.review_state == M.REVIEW.SUPERSEDED
        or item.apply_state == M.APPLY.APPLIED
        or item.apply_state == M.APPLY.REVERTED
      if not terminal then return true end
    end
  end
  return false
end

--- 删除候选，但仅当无其他可应用变更单元仍引用它（防止共享摘要被误删）。
--- @param digest string
--- @return boolean
local function _discard_candidate(digest)
  if _candidate_referenced(digest) then return false end
  return store.discard_candidate(digest)
end

--- 批量删除候选：先**一次**统计仍被非终态变更单元引用的摘要集合，再删除未被引用者。
--- `supersede_by_paths` / 包安装合并会一次取代大量同路径候选；若对每个候选都调
--- `_candidate_referenced`（全表扫描），待审堆积到数百/上千时退化为 O(n²)。批量版
--- 把引用统计合并为单次 O(n)，删除为 O(k)。
--- 注意：调用方须先完成所有状态改写（把将被删除的项标记为终态），再调用本函数。
--- @param digests table digest -> true
local function _discard_candidates(digests)
  if not digests or next(digests) == nil then return end
  _ensure_loaded()
  local referenced = {}
  for _, item in pairs(state.items) do
    local digest = item.candidate_digest
    if digest and digests[digest] then
      local terminal = item.review_state == M.REVIEW.REJECTED
        or item.review_state == M.REVIEW.SUPERSEDED
        or item.apply_state == M.APPLY.APPLIED
        or item.apply_state == M.APPLY.REVERTED
      if not terminal then referenced[digest] = true end
    end
  end
  for digest in pairs(digests) do
    if not referenced[digest] then store.discard_candidate(digest) end
  end
end

--- @param content string
--- @return string
local function _sha(content)
  local ok, hex = pcall(vim.fn.sha256, content or "")
  return ok and ("sha256:" .. hex) or "sha256:?"
end

--- 大文件 stat 签名（与 candidate 同口径）：不读取内容做 CAS，避免读取数百 MB。
--- @param st table|nil
--- @return string|nil
local function _stat_sig(st)
  if not (st and st.type == "file" and st.mtime) then return nil end
  return string.format("sig:%s:%s:%s",
    tostring(st.mtime.sec), tostring(st.mtime.nsec), tostring(st.size))
end

--- 读取文件内容（不存在返回 nil）
--- @param path string
--- @return string|nil
local function _read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local c = f:read("*a")
  f:close()
  return c
end

-- ========== 应用快照（保存 / 撤销保存交换原文件与快照）==========

--- 快照单文件内容上限（与候选同源配置，避免删除大文件时读入/落盘巨量内容）
--- @return number
local function _snapshot_cap()
  local n = tonumber(require("NeoAI.kernel.config_store").get("tools.sandbox.max_file_bytes"))
  if n == nil then return 8 * 1024 * 1024 end
  return n
end

--- 快照撤销 CAS 模式："sig"（默认，mtime/size 签名，省去逐文件读取+哈希）| "hash"（最强一致性）。
--- @return string
local function _snapshot_cas_mode()
  local m = require("NeoAI.kernel.config_store").get("tools.sandbox.review.snapshot_cas")
  if m == "hash" then return "hash" end
  return "sig"
end

--- 应用前捕获「原文件」快照侧（真实文件当前内容），用于撤销保存时交换。
--- 内容按文件复制到 blob（不读入 Lua 内存、不嵌入快照 JSON），撤销时按文件复制回写。
--- @param cand table 冻结候选（已按选择性应用过滤）
--- @return table 数组
local function _capture_snapshot(cand)
  local cap = _snapshot_cap()
  local store = require("NeoAI.sandbox.store")
  local entries = {}
  for _, f in ipairs(cand.files or {}) do
    local st = vim.uv.fs_stat(f.path)
    local is_file = st ~= nil and st.type == "file"
    local too_large = is_file and cap > 0 and (st.size or 0) > cap
    local alt_blob, alt_content
    if is_file and not too_large then
      alt_blob = store.copy_to_blob(f.path,
        "snap|" .. tostring(cand.candidate_digest) .. "|" .. f.path)
      if not alt_blob then alt_content = _read_file(f.path) end
    end
    entries[#entries + 1] = {
      path = f.path,
      action = f.action,
      alt_exists = st ~= nil,
      alt_type = st and st.type or nil,
      alt_mode = st and (st.mode % 4096) or nil,
      alt_content = alt_content,
      alt_blob = alt_blob,
      alt_too_large = too_large or nil,
      side = "after", -- 真实盘当前为「保存后」版本；快照侧为「保存前」版本
    }
  end
  return entries
end

--- 发布成功后落盘快照，并记录「当前盘上版本」的签名/哈希用于撤销时冲突检测。
--- @param item table 变更单元
--- @param entries table _capture_snapshot 结果
--- @param operation_id string|nil
local function _store_snapshot(item, entries, operation_id)
  local cap = _snapshot_cap()
  local cas = _snapshot_cas_mode()
  for _, e in ipairs(entries) do
    local st = vim.uv.fs_stat(e.path)
    e.disk_exists = st ~= nil
    e.disk_type = st and st.type or nil
    if st and st.type == "file" then
      -- 默认用 stat 签名做撤销 CAS（不整读文件，避免应用后逐文件读取+哈希的 CPU 开销）；
      -- 大文件同样用签名。可用 `snapshot_cas="hash"` 恢复逐文件哈希。
      if cas == "sig" or (cap > 0 and (st.size or 0) > cap) then
        e.disk_sig = _stat_sig(st)
        e.disk_hash = nil
      else
        e.disk_hash = _sha(_read_file(e.path) or "")
        e.disk_sig = nil
      end
    else
      e.disk_hash = nil
      e.disk_sig = nil
    end
  end
  local rec = {
    snapshot_id = "snap_" .. tostring(item.change_set_id),
    change_set_id = item.change_set_id,
    operation_id = operation_id,
    state = M.APPLY.APPLIED,
    created_at = os.time(),
    updated_at = os.time(),
    files = entries,
  }
  store.write_snapshot_async(rec)
  item.snapshot_id = rec.snapshot_id
  return rec
end

--- 撤销已应用变更后，用快照中「已应用侧」内容重建候选，使原变更单元以待审身份重新入队。
--- 快照交换后 `alt_*` 侧即应用时写入的真实内容；`item.files` 仍保留候选的 CAS 元数据
--- （`before_hash`/`base_type`/`mode` 等，仅 content 被剥离），据此可还原出与首次应用等价的候选。
--- @param item table 原变更单元
--- @param rec table 已交换的快照记录
--- @return boolean ok
local function _requeue_after_undo(item, rec)
  local by_path = {}
  for _, f in ipairs(item.files or {}) do
    if type(f) == "table" and f.path then by_path[f.path] = f end
  end
  local files = {}
  for _, e in ipairs(rec.files or {}) do
    local meta = by_path[e.path] or {}
    local entry = {}
    for k, v in pairs(meta) do entry[k] = v end
    entry.path = e.path
    local action = meta.action or e.action
    if not action then
      if e.alt_exists then
        action = (e.alt_type == "directory") and "mkdir" or "modify"
      else
        action = (e.disk_type == "directory") and "rmdir" or "delete"
      end
    end
    entry.action = action
    if entry.link == nil and (action == "create" or action == "modify") then
      if e.alt_content ~= nil then
        entry.content = e.alt_content
        entry.blob = nil
        entry.after_hash = entry.after_hash or _sha(e.alt_content)
      elseif e.alt_blob then
        entry.content = nil
        entry.blob = e.alt_blob
      else
        return false
      end
    end
    files[#files + 1] = entry
  end
  if #files == 0 then return false end
  table.sort(files, function(a, b) return a.path < b.path end)
  local manifest = {}
  for _, f in ipairs(files) do
    manifest[#manifest + 1] = { path = f.path, action = f.action, after_hash = f.after_hash }
  end
  local json = require("NeoAI.utils.json")
  local cand = {
    candidate_digest = _sha(json.encode_fast(manifest)),
    files = files,
    created_at = os.time(),
    effect = item.effect,
    command_id = item.command_id,
  }
  store.write_candidate_async(cand)
  item.candidate_digest = cand.candidate_digest
  item.files = cand.files
  local write_set = {}
  for _, f in ipairs(cand.files) do write_set[#write_set + 1] = f.path end
  item.write_set = write_set
  item.review_state = M.REVIEW.PENDING
  item.apply_state = M.APPLY.NOT_REQUESTED
  item.approved_at = nil
  item.applied_at = nil
  item.receipt = nil
  item.snapshot_id = nil
  item.reverted_at = nil
  item.fail_reason = nil
  item.needs_root = nil
  return true
end

--- 撤销保存：把真实文件与快照交换（回滚到应用前内容）。
--- 撤销后该变更单元**回到待审队列**（重建候选、清空快照），可重新审批/应用；不再保留「已撤销」态做重做。
--- 写入前做 CAS 校验（真实文件须仍是上次写入的版本），避免覆盖用户外部改动。
--- @param id string change_set_id
--- @param opts table|nil { allow_root?: boolean, prefer_sudo?: boolean, force?: boolean }
--- @return table { ok, state, reason? }
function M.undo(id, opts)
  opts = opts or {}
  local item = M.get(id)
  if not item then
    return { ok = false, state = "FAILED", reason = "CHANGE_SET_NOT_FOUND: " .. tostring(id) }
  end
  local rec = item.snapshot_id and store.read_snapshot(item.snapshot_id)
  if not rec then
    return { ok = false, state = "FAILED", reason = "SNAPSHOT_NOT_FOUND: " .. tostring(id) }
  end
  -- 冲突预检：真实文件须仍是上次写入的版本（否则拒绝，避免覆盖外部改动）。
  if not opts.force then
    for _, e in ipairs(rec.files or {}) do
      local st = vim.uv.fs_stat(e.path)
      local exists = st ~= nil
      local ok = (exists == (e.disk_exists == true))
      if ok and exists then
        if (st.type == "file") ~= (e.disk_type == "file") then
          ok = false
        elseif st.type == "file" then
          if e.disk_sig then
            ok = (_stat_sig(st) == e.disk_sig)
          else
            ok = (_sha(_read_file(e.path) or "") == e.disk_hash)
          end
        end
      end
      if not ok then
        return { ok = false, state = "CONFLICT", reason = "TARGET_CHANGED: " .. tostring(e.path) }
      end
    end
  end
  local writer = require("NeoAI.sandbox.writer")
  local store = require("NeoAI.sandbox.store")
  local cas = _snapshot_cas_mode()
  for _, e in ipairs(rec.files or {}) do
    if e.alt_too_large then
      return { ok = false, state = "FAILED", reason = "SNAPSHOT_TOO_LARGE: " .. tostring(e.path) }
    end
    -- 交换前记录当前（保存侧）版本，交换后成为新的快照侧。
    local st = vim.uv.fs_stat(e.path)
    local cur_exists = st ~= nil
    local cur_type = st and st.type or nil
    local cur_mode = st and (st.mode % 4096) or nil
    -- 交换前记录快照侧（即将写回真实盘的版本），用于更新 disk_* 状态。
    local wrote_exists, wrote_type = e.alt_exists, e.alt_type
    local wrote_blob, wrote_content = e.alt_blob, e.alt_content
    -- 写入前把「当前（保存侧）版本」复制到 blob：写入后它成为新的快照侧（撤销/重做对称）。
    local new_blob
    if cur_exists and cur_type == "file" then
      new_blob = store.copy_to_blob(e.path,
        "snap|" .. tostring(rec.snapshot_id) .. "|" .. e.path .. "|" .. tostring(vim.uv.hrtime()))
    end

    local res
    if not wrote_exists then
      -- 快照侧不存在：删除当前盘上的文件/目录（两侧都不存在时无需操作）。
      if not cur_exists then
        res = { ok = true, state = "WRITTEN" }
      else
        local action = (cur_type == "directory") and "rmdir" or "delete"
        res = writer.apply(action, e.path, nil, {
          allow_root = opts.allow_root == true, prefer_sudo = opts.prefer_sudo == true,
        })
      end
    elseif wrote_type == "directory" then
      res = writer.apply("mkdir", e.path, nil, {
        allow_root = opts.allow_root == true, prefer_sudo = opts.prefer_sudo == true, mode = e.alt_mode,
      })
    elseif wrote_blob then
      res = writer.apply_file("write", e.path, wrote_blob, {
        allow_root = opts.allow_root == true, prefer_sudo = opts.prefer_sudo == true, mode = e.alt_mode,
      })
    else
      res = writer.apply("write", e.path, wrote_content or "", {
        allow_root = opts.allow_root == true, prefer_sudo = opts.prefer_sudo == true, mode = e.alt_mode,
      })
    end
    if res.state == writer.STATE.NEEDS_ROOT then
      return { ok = false, state = "NEEDS_ROOT", reason = res.reason or ("WRITE_REQUIRES_ROOT: " .. e.path) }
    end
    if not res.ok then
      return { ok = false, state = "FAILED", reason = res.reason or res.err or ("WRITE_FAILED: " .. e.path) }
    end
    -- 交换两侧：当前盘内容（写入前已复制到 blob）成为新的快照侧；disk_* 为刚写回的版本。
    e.alt_exists, e.alt_type, e.alt_mode = cur_exists, cur_type, cur_mode
    e.alt_content, e.alt_blob, e.alt_too_large = nil, new_blob, nil
    e.side = (e.side == "after") and "before" or "after"
    e.disk_exists = wrote_exists
    e.disk_type = wrote_type
    if wrote_exists and wrote_type == "file" then
      if cas == "hash" and not wrote_blob then
        e.disk_hash = _sha(wrote_content or "")
        e.disk_sig = nil
      else
        local wst = vim.uv.fs_stat(e.path)
        e.disk_sig = wst and _stat_sig(wst) or nil
        e.disk_hash = nil
      end
    else
      e.disk_hash = nil
      e.disk_sig = nil
    end
  end
  -- 撤销「已应用」变更：重建候选并回到待审（删除快照与已应用记录）。
  if rec.state == M.APPLY.APPLIED and _requeue_after_undo(item, rec) then
    store.delete_snapshot(rec.snapshot_id)
    pcall(store.delete_review_removed, id)
    state.items[id] = item
    _persist(item)
    _emit(require("NeoAI.kernel.events").SANDBOX_REVERTED, {
      change_set_id = id, apply_state = M.APPLY.NOT_REQUESTED, requeued = true,
    })
    return { ok = true, state = "PENDING", requeued = true, change_set_id = id }
  end
  -- 兼容历史「已撤销」记录：交换回已保存（重做）。
  rec.state = (rec.state == M.APPLY.APPLIED) and M.APPLY.REVERTED or M.APPLY.APPLIED
  rec.updated_at = os.time()
  store.write_snapshot_async(rec)
  item.apply_state = rec.state
  item.reverted_at = (rec.state == M.APPLY.REVERTED) and os.time() or nil
  state.items[id] = item
  _persist(item)
  _emit(require("NeoAI.kernel.events").SANDBOX_REVERTED, {
    change_set_id = id, apply_state = rec.state,
  })
  return { ok = true, state = rec.state, snapshot = rec }
end

--- 从候选构造写集合（供展示与选择性应用）
--- @param cand table
--- @return table 数组
local function _write_set(cand)
  local out = {}
  for _, f in ipairs(cand.files or {}) do out[#out + 1] = f.path end
  return out
end

--- 去重合并两个字符串数组（保留首次出现顺序）
--- @param a table|nil
--- @param b table|nil
--- @return table
local function _union(a, b)
  local out, seen = {}, {}
  for _, list in ipairs({ a or {}, b or {} }) do
    for _, v in ipairs(list) do
      if type(v) == "string" and not seen[v] then seen[v] = true; out[#out + 1] = v end
    end
  end
  return out
end

--- 合并同一「安装命令」（package_key）的待审候选为一个审批单元。
--- 包安装命令（apt/pip/npm 等）常产生多个候选（索引、元数据、包文件），按安装命令键合并后，
--- 待审悬浮窗只显示一个条目、整包一次审批，避免同类条目反复确认。
--- @param item table 新入队的变更单元（含 package_key）
--- @param cand table 新候选
--- @return table 合并后的变更单元（无同类时返回 item）
local function _merge_package_item(item, cand)
  local key = item.package_key
  if type(key) ~= "string" or key == "" then return item end
  local members = {}
  for _, it in ipairs(_pending_items()) do
    if it.change_set_id ~= item.change_set_id and it.package_key == key then
      members[#members + 1] = it
    end
  end
  if #members == 0 then return item end
  local base = members[1]
  -- 部分取代增量：成员中被更新候选覆盖的路径不再并入（除非新候选本身重新写入该路径）。
  local skip = {}
  for _, it in ipairs(members) do
    if type(it.superseded_paths) == "table" then
      for p in pairs(it.superseded_paths) do skip[p] = true end
    end
  end
  for _, f in ipairs(cand.files or {}) do skip[f.path] = nil end
  -- 按路径合并文件（新候选优先），并集排序。
  local by_path, order = {}, {}
  local function add(f)
    if skip[f.path] then return end
    if not by_path[f.path] then order[#order + 1] = f.path end
    by_path[f.path] = f
  end
  for _, it in ipairs(members) do
    local c = store.read_candidate(it.candidate_digest)
    -- 不 deepcopy（含 content 的大候选会造成内存与耗时翻倍）：文件条目只读复用。
    for _, f in ipairs((c and c.files) or it.files or {}) do add(f) end
  end
  for _, f in ipairs(cand.files or {}) do add(f) end
  local files = {}
  for _, p in ipairs(order) do files[#files + 1] = by_path[p] end
  table.sort(files, function(a, b) return a.path < b.path end)
  local manifest = {}
  for _, f in ipairs(files) do manifest[#manifest + 1] = { path = f.path, action = f.action, after_hash = f.after_hash } end
  local json = require("NeoAI.utils.json")
  local digest = "sha256:" .. vim.fn.sha256(json.encode_fast(manifest))
  local newcand = {
    candidate_digest = digest, files = files, created_at = os.time(),
    effect = base.effect or cand.effect, command_id = cand.command_id,
  }
  store.write_candidate_async(newcand)
  -- 合并后要丢弃各成员候选：先确保新候选落盘，避免异步写未完成时旧候选被删而新候选尚不存在
  -- （应用时 CANDIDATE_NOT_FOUND）。有界等待（写入已在异步链上，不阻塞 Agent）。
  pcall(store.flush, 30000)
  local to_discard = {}
  -- 其余同键成员并入 base：标记取代并丢弃各自候选。
  for i = 2, #members do
    local it = members[i]
    it.review_state = M.REVIEW.SUPERSEDED
    it.superseded_by = base.change_set_id
    it.superseded_at = os.time()
    state.items[it.change_set_id] = it
    if it.candidate_digest ~= digest then to_discard[it.candidate_digest] = true end
    _persist(it)
    pcall(store.delete_review_removed, it.change_set_id)
    _emit(require("NeoAI.kernel.events").SANDBOX_REVIEW_SUPERSEDED, {
      change_set_id = it.change_set_id, superseded_by = base.change_set_id,
    })
  end
  local old_base_digest = base.candidate_digest
  base.candidate_digest = digest
  base.files = files
  base.write_set = _write_set(newcand)
  -- 合并后的候选已按增量剔除被取代路径，清空增量并删除其落盘记录。
  base.superseded_paths = nil
  base.partial_superseded_by = nil
  pcall(store.delete_review_removed, base.change_set_id)
  base.package_names = _union(base.package_names, item.package_names)
  base.command = item.command or base.command
  base.package_manager = item.package_manager or base.package_manager
  if (tonumber(item.risk_level) or 0) > (tonumber(base.risk_level) or 0) then
    base.risk_level = item.risk_level
    base.risk_name = item.risk_name
  end
  base.risk_reasons = _union(base.risk_reasons, item.risk_reasons)
  base.secret_warning = item.secret_warning or base.secret_warning
  base.updated_at = os.time()
  state.items[base.change_set_id] = base
  _persist(base)
  if old_base_digest ~= digest then to_discard[old_base_digest] = true end
  -- 新条目已并入 base：标记取代并丢弃其候选。
  item.review_state = M.REVIEW.SUPERSEDED
  item.superseded_by = base.change_set_id
  item.superseded_at = os.time()
  state.items[item.change_set_id] = item
  if item.candidate_digest ~= digest then to_discard[item.candidate_digest] = true end
  _persist(item)
  pcall(store.delete_review_removed, item.change_set_id)
  _discard_candidates(to_discard)
  _emit(require("NeoAI.kernel.events").SANDBOX_REVIEW_SUPERSEDED, {
    change_set_id = item.change_set_id, superseded_by = base.change_set_id,
  })
  return base
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
  -- 包安装候选由 wrapper 明确跳过密钥检测（状态文件含高熵签名/哈希），此处不重复检测，
  -- 避免把包管理器状态文件误报为「密钥操作」。
  local secret_warning = meta.secret_warning
  if secret_warning == nil and not meta.package then
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
    -- 不透明派生：命令/脚本加密变换后的密钥流，发布前需人工确认。
    derived_opaque = meta.derived_opaque,
    depends_on = meta.depends_on or {},
    atomic_group = meta.atomic_group,
    -- 安全分级：级别、原因、包安装标记与建议动作（供审批分级展示与决策）
    risk_level = meta.risk_level,
    risk_name = meta.risk_name,
    risk_reasons = meta.risk_reasons,
    package = meta.package,
    action = meta.action,
    -- 包安装：管理器/包名/合并键/命令（按安装命令合并为一个审批单元，界面标注）。
    command = meta.command,
    package_manager = meta.package_manager,
    package_names = meta.package_names,
    package_key = meta.package_key,
    package_sensitive = meta.package_sensitive,
    -- 冻结时剔除的不可发布文件（遮蔽/易变缓存），供审批界面提示。
    dropped = meta.dropped,
    review_state = M.REVIEW.PENDING,
    apply_state = M.APPLY.NOT_REQUESTED,
    created_at = os.time(),
  }
  -- git 操作原子组：候选涉及 `.git` 对象/指针时，整条候选是一个不可分割的原子单元
  -- （索引↔对象库耦合），界面整组通过/丢弃，禁止逐文件选择性应用。
  if not item.atomic_group then
    local ok_rt, rt = pcall(require, "NeoAI.sandbox.runtime")
    if ok_rt and rt and type(rt.git_path_class) == "function" then
      for _, f in ipairs(item.files or {}) do
        local gc = rt.git_path_class(f.path)
        if gc == "object" or gc == "pointer" then
          item.atomic_group = "git"
          break
        end
      end
    end
  end
  state.items[id] = item
  -- 先做包合并（可能需要候选内容），再落盘并剥离内存内容：`_persist` 会剥离 `item.files`，
  -- 而它与 `cand.files` 是同一引用，先剥离会让合并后的候选丢失新文件内容。
  local merged = _merge_package_item(item, cand)
  if merged == item then _persist(item) end
  _emit(require("NeoAI.kernel.events").SANDBOX_REVIEW_ENQUEUED, {
    change_set_id = id,
    candidate_digest = cand.candidate_digest,
    write_set = item.write_set,
    tool = item.tool,
  })
  return merged
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
    -- 主机操作提案属 L3（critical）：供审批界面红色高危标注与 AI 审计正确分级。
    risk_level = 3,
    risk_name = "critical",
    risk_reasons = { "HOST_OPERATION" },
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

--- 读取某变更单元中单个文件的候选内容（供 diff 预览）：内存 item 落盘后已剥离 content，
--- 此处优先命中内存（刚入队尚未剥离），否则按候选摘要读取并做小型 LRU 缓存。
--- @param id string change_set_id
--- @param path string
--- @return string|nil
function M.content_for(id, path)
  if not id or not path then return nil end
  local item = state.items[id] or store.read_review(id)
  if not item then return nil end
  if type(item.files) == "table" then
    for _, f in ipairs(item.files) do
      if type(f) == "table" and f.path == path then
        if f.content ~= nil then return f.content end
        if f.blob and not f.large then
          local raw = _read_file(f.blob)
          if raw ~= nil then return raw end
        end
        break
      end
    end
  end
  local digest = item.candidate_digest
  if not digest then return nil end
  local key = digest .. "\0" .. path
  if content_lru_set[key] then
    _content_touch(key)
    return content_lru[key]
  end
  local cand = store.read_candidate(digest)
  if not cand then return nil end
  local content
  for _, f in ipairs(cand.files or {}) do
    if f.path == path then
      if f.content ~= nil then content = f.content
      elseif f.blob and not f.large then content = _read_file(f.blob) end
      break
    end
  end
  if content ~= nil then _content_put(key, content) end
  return content
end

--- 列出变更单元
--- @param filter table|nil { review_state?, apply_state? }
--- @return table 数组
function M.list(filter)
  _ensure_loaded()
  filter = filter or {}
  local filtered = {}
  for _, item in pairs(state.items) do
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

--- 待审摘要：待审文件数 + 最高安全级别（单次扫描，供状态栏徽标与危险高亮）。
--- 待审数量按文件计（审批单位为单个文件，与审批界面一致）：一个变更单元可能含多个文件，
--- 用户需逐个确认，故徽标数应为待审文件总数。
--- @return table { count = number, max_level = number|nil }
function M.pending_summary()
  _ensure_loaded()
  if state.pending_cache then return state.pending_cache end
  local count, max_level = 0, nil
  for _, item in pairs(state.items) do
    if item.review_state == M.REVIEW.PENDING then
      if item.kind == "host_op" then
        count = count + 1
      else
        local n = #(item.files or {})
        if n == 0 then n = #(item.write_set or {}) end
        -- 部分取代：被更新候选覆盖的路径不再待审，从计数中扣除。
        n = n - _superseded_count(item)
        if n < 0 then n = 0 end
        count = count + n
      end
      if item.risk_level and (not max_level or item.risk_level > max_level) then
        max_level = item.risk_level
      end
    end
  end
  state.pending_cache = { count = count, max_level = max_level }
  return state.pending_cache
end

--- 待审数量（按文件计）
--- @return number
function M.pending_count()
  return M.pending_summary().count
end

--- 会话级自动审批是否开启（默认关闭；仅靠本地模型时由用户显式开启以管理 agent 行为）
--- @return boolean
function M.session_auto()
  if state.session_auto ~= nil then return state.session_auto == true end
  local cfg = require("NeoAI.kernel.config_store").get("tools.sandbox.review") or {}
  return cfg.session_auto_approve == true
end

--- 设置会话级自动审批（nil 恢复配置默认）
--- @param v boolean|nil
function M.set_session_auto(v)
  state.session_auto = v
end

--- 是否应自动应用（会话自动审批或全局 review.auto_apply）
--- @return boolean
function M.auto_apply_enabled()
  if M.session_auto() then return true end
  local cfg = require("NeoAI.kernel.config_store").get("tools.sandbox.review") or {}
  return cfg.auto_apply == true
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
  _discard_candidate(item.candidate_digest)
  -- 拒绝后暂存副本失效：后续编辑应重新以真实文件为基线，不能带上被拒改动。
  candidate.invalidate(item.write_set)
  _persist(item)
  pcall(store.delete_review_removed, id)
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
  -- git 原子组：不允许逐文件丢弃，整体拒绝。
  if item.atomic_group == "git" then
    return M.reject(id, reason)
  end
  local files = item.files
  if not files or #files == 0 then
    return M.reject(id, reason)
  end
  local remaining_paths = {}
  local found = false
  local sup = type(item.superseded_paths) == "table" and item.superseded_paths or nil
  for _, f in ipairs(files) do
    if f.path == path then found = true
    elseif not (sup and sup[f.path]) then remaining_paths[#remaining_paths + 1] = f.path end
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
    candidate_digest = "sha256:" .. vim.fn.sha256(json.encode_fast(manifest)),
    files = remaining,
    created_at = os.time(),
    effect = item.effect,
    command_id = item.command_id,
  }
  store.write_candidate_async(newcand)
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

--- 应用前置：解析条目、自动批准、读取候选、按选择性应用过滤。
--- 成功返回 `ctx`（供 `_apply_settle` 收尾）；无需发布时返回 `nil, result`。
--- @param id string
--- @param opts table
--- @return table|nil ctx
--- @return table|nil early_result
local function _apply_begin(id, opts)
  opts = opts or {}
  local item = M.get(id)
  if not item then
    return nil, { ok = false, state = "FAILED", reason = "CHANGE_SET_NOT_FOUND: " .. tostring(id) }
  end
  -- 陈旧 id / 审批界面：被取代（SUPERSEDED）的旧变更单元已丢弃候选，无法直接应用。
  -- 沿 supersede 链重定向到最新版本，使用户对旧 id 的应用意图落到当前内容，而不是
  -- 报 NOT_APPROVED。已应用（APPLIED）的终态直接视为成功（幂等）。
  local seen = { [id] = true }
  while item.review_state == M.REVIEW.SUPERSEDED and item.superseded_by
    and not seen[item.superseded_by] do
    seen[item.superseded_by] = true
    local nxt = M.get(item.superseded_by)
    if not nxt then break end
    item = nxt
    id = item.change_set_id
  end
  -- git 原子组：忽略文件子集，始终整组应用（避免只写索引/只写对象导致损坏）。
  if item.atomic_group == "git" then opts.files = nil end
  if item.apply_state == M.APPLY.APPLIED then
    return nil, { ok = true, state = "ALREADY_APPLIED", receipt = item.receipt }
  end
  -- 自动批准是为「应用」服务的瞬时状态：一旦应用失败必须回退为待审，
  -- 否则条目停留在 APPROVED 而从待审悬浮窗（只列 PENDING）中消失，用户无法重试/拒绝。
  local auto_approved = false
  local function _restore_pending()
    if auto_approved and item.review_state == M.REVIEW.APPROVED then
      item.review_state = M.REVIEW.PENDING
      item.approved_at = nil
      state.items[id] = item
      _persist(item)
    end
  end
  -- 主机操作提案：审批后在主机上 replay（无候选、无文件）
  if item.kind == "host_op" then
    if opts.auto_approve and item.review_state == M.REVIEW.PENDING then
      M.approve(id)
      auto_approved = true
    end
    if item.review_state ~= M.REVIEW.APPROVED then
      return nil, { ok = false, state = "NOT_APPROVED", reason = "CHANGE_SET_NOT_APPROVED: " .. tostring(id) }
    end
    item.apply_state = M.APPLY.APPLYING
    _persist(item)
    local res = require("NeoAI.sandbox.hostop").replay(item.host_op_id)
    item.apply_state = res.ok and M.APPLY.APPLIED or M.APPLY.FAILED
    item.fail_reason = res.reason
    state.items[id] = item
    _persist(item)
    if not res.ok then _restore_pending() end
    return nil, res
  end
  if opts.auto_approve and item.review_state == M.REVIEW.PENDING then
    M.approve(id)
    auto_approved = true
  end
  if item.review_state ~= M.REVIEW.APPROVED then
    return nil, { ok = false, state = "NOT_APPROVED", reason = "CHANGE_SET_NOT_APPROVED: " .. tostring(id) }
  end
  local cand = store.read_candidate(item.candidate_digest)
  if not cand then
    -- 大候选的落盘是异步的（线程池）：可能仍在写队列。先冲刷再读，避免误报丢失。
    pcall(store.flush, 2000)
    cand = store.read_candidate(item.candidate_digest)
  end
  if not cand and store.was_written and store.was_written(item.candidate_digest) then
    -- 候选曾成功落盘、文件后续丢失（实例存储被外部清理等），但待审项仍可恢复内容：
    -- 内存条目（若尚未剥离）或沙箱暂存副本（`candidate.read_path`）重建候选并回写，
    -- 使应用继续可用，而不是报 CANDIDATE_NOT_FOUND。
    local rebuilt, has_content = {}, false
    if type(item.files) == "table" and #item.files > 0 then
      for _, f in ipairs(item.files) do
        if type(f) == "table" then
          local entry = {}
          for k, v in pairs(f) do entry[k] = v end
          if f.content ~= nil or f.blob ~= nil or f.link ~= nil then
            has_content = true
          elseif f.action == "create" or f.action == "modify" then
            -- 内存内容已被剥离：从沙箱暂存副本恢复（生产路径总会先 merge_candidate）。
            local staged = candidate.read_path and candidate.read_path(f.path)
            local content = staged and _read_file(staged) or nil
            if content ~= nil then entry.content = content; has_content = true end
          end
          rebuilt[#rebuilt + 1] = entry
        else
          rebuilt[#rebuilt + 1] = f
        end
      end
    end
    if has_content then
      cand = {
        candidate_digest = item.candidate_digest,
        files = rebuilt,
        effect = item.effect,
        command_id = item.command_id,
        created_at = item.created_at,
      }
      pcall(store.write_candidate_async, cand)
      require("NeoAI.kernel.logger").warn(
        "[sandbox] 候选文件丢失，已从待审项/暂存重建: %s（%d 文件；store.root=%s）",
        tostring(item.candidate_digest), #rebuilt, tostring(store.root and store.root()))
    end
  end
  if not cand then
    require("NeoAI.kernel.logger").warn(
      "[sandbox] 应用失败：候选不存在 %s（store.root=%s）", tostring(item.candidate_digest),
      tostring(store.root and store.root()))
    _restore_pending()
    return nil, { ok = false, state = "FAILED", reason = "CANDIDATE_NOT_FOUND: " .. tostring(item.candidate_digest) }
  end
  -- 选择性应用：按允许文件子集过滤候选，未选中的文件保留为新的待审项。
  -- 部分取代：被更新候选覆盖的路径从本单元剔除且**不回队**（归新单元所有）。
  local sup = type(item.superseded_paths) == "table" and item.superseded_paths or nil
  local apply_all = not (opts.files and #opts.files > 0)
  local allow
  if not apply_all then
    allow = {}
    for _, p in ipairs(opts.files) do
      if not (sup and sup[p]) then allow[p] = true end
    end
  end
  local remaining = {}
  local filtered = {}
  for _, f in ipairs(cand.files or {}) do
    local already = sup and sup[f.path]
    if (not already) and (apply_all or (allow and allow[f.path])) then
      filtered[#filtered + 1] = f
    elseif not already then
      remaining[#remaining + 1] = f
    end
  end
  if #filtered == 0 then
    _restore_pending()
    return nil, { ok = false, state = "FAILED", reason = "NO_FILES_SELECTED" }
  end
  if #filtered < #(cand.files or {}) then
    -- 浅拷贝 + 替换 files：不深拷贝含内容的大候选（上万文件时是应用阶段主线程卡顿源）。
    local copy = {}
    for k, v in pairs(cand) do copy[k] = v end
    copy.files = filtered
    copy.candidate_digest = cand.candidate_digest .. ":subset" .. tostring(#filtered)
    cand = copy
  end
  return {
    id = id, item = item, cand = cand, remaining = remaining,
    restore_pending = _restore_pending, opts = opts,
  }
end

--- 应用收尾：根据发布结果更新条目状态、落盘快照、删除候选、回执与事件。
--- @param ctx table _apply_begin 返回值
--- @param pub table candidate.publish(_async) 结果
--- @return table pub
local function _apply_settle(ctx, pub)
  local item, id = ctx.item, ctx.id
  if pub.ok then
    item.apply_state = M.APPLY.APPLIED
    item.applied_at = os.time()
    item.receipt = pub.receipt
    store.write_receipt(pub.receipt)
    -- 已应用：部分取代增量已完成使命，清理（被取代路径由新单元持有）。
    item.superseded_paths = nil
    -- 批量应用（apply_all / begin_batch 会话）时把候选删除推迟到全部应用后一次性对账，
    -- 避免对每个候选做一次全表引用扫描（O(n²)）；单项应用仍即时删除。
    local deferred = ctx.opts._defer_discard or (ctx.opts.batch and ctx.opts.batch.deferred)
    if deferred then
      deferred[item.candidate_digest] = true
    else
      _discard_candidate(item.candidate_digest)
    end
    _store_snapshot(item, ctx.snapshot_entries, pub.receipt.operation_id)
    _persist(item)
    pcall(store.delete_review_removed, item.change_set_id)
    -- 仅应用了部分文件：其余文件保留待审，供用户逐个确认
    if #ctx.remaining > 0 then _requeue_remaining(item, ctx.remaining) end
    _emit(require("NeoAI.kernel.events").SANDBOX_APPLIED, {
      change_set_id = id, operation_id = pub.receipt.operation_id,
    })
  elseif pub.state == "NEEDS_ROOT" then
    -- 非 root 写入被拒（目标归 root 所有）：保持待审并标记「需 root」，进入异步审批；
    -- 用户确认（allow_root=true）后才以 root / sudo 写入。不自动提权。
    item.apply_state = M.APPLY.NEEDS_ROOT
    item.needs_root = true
    item.fail_reason = pub.reason
    _persist(item)
    ctx.restore_pending()
    _emit(require("NeoAI.kernel.events").SANDBOX_PRIVILEGE_ESCALATION_REQUESTED, {
      change_set_id = id, reason = "PUBLISH_WRITE_DENIED",
    })
  else
    item.apply_state = pub.state == "CONFLICT" and M.APPLY.CONFLICT or M.APPLY.FAILED
    item.fail_reason = pub.reason
    _persist(item)
    ctx.restore_pending()
    _emit(require("NeoAI.kernel.events").SANDBOX_CONFLICT, {
      change_set_id = id, reason = pub.reason,
    })
  end
  return pub
end

--- 发布前的公共步骤：标记 APPLYING、广播开始、捕获原文件快照。
--- @param ctx table
--- @return table pub_opts
local function _apply_publish_begin(ctx)
  local item = ctx.item
  item.apply_state = M.APPLY.APPLYING
  _persist(item)
  _emit(require("NeoAI.kernel.events").SANDBOX_PUBLISH_STARTED, {
    change_set_id = ctx.id, candidate_digest = item.candidate_digest,
  })
  -- 保存前捕获原文件快照（真实文件当前内容），供撤销保存时交换。
  ctx.snapshot_entries = _capture_snapshot(ctx.cand)
  return {
    expected_base = item.base_version,
    allow_root = ctx.opts.allow_root == true,
    prefer_sudo = ctx.opts.prefer_sudo == true,
  }
end

--- 应用变更单元（CAS 发布到真实工作区，同步）
--- 支持选择性应用：opts.files 指定允许的文件子集（按单个文件审批）。
--- @param id string
--- @param opts table|nil { files?: string[], auto_approve?: boolean }
--- @return table { ok, state, reason?, receipt? }
function M.apply(id, opts)
  local ctx, early = _apply_begin(id, opts)
  if early then return early end
  local pub_opts = _apply_publish_begin(ctx)
  local pub = candidate.publish(ctx.cand, pub_opts)
  return _apply_settle(ctx, pub)
end

--- 应用变更单元（异步）：CAS + 写入在线程池分块执行，主线程不被大候选落盘阻塞。
--- 提权（allow_root / root+run_as 降权）、顺序敏感（git 原子组/删除）或线程池不可用时，
--- `candidate.publish_async` 内部回落同步发布，语义与 `M.apply` 一致。
--- @param id string
--- @param opts table|nil
--- @return Deferred resolve(table { ok, state, reason?, receipt? })
function M.apply_async(id, opts)
  local async = require("NeoAI.utils.async")
  local ctx, early = _apply_begin(id, opts)
  if early then return async.resolve(early) end
  local pub_opts = _apply_publish_begin(ctx)
  return candidate.publish_async(ctx.cand, pub_opts):then_(function(pub)
    return _apply_settle(ctx, pub)
  end)
end

--- 开始一次批量应用会话：会话内 `apply` 把候选删除推迟到 `end_batch` 统一对账。
--- 供 UI 在**逐项让出主循环**地应用大量变更时复用——否则每项都触发一次 O(n) 引用扫描，
--- 待审堆积到数百/上千时退化为 O(n²)，占满主线程。
--- @return table ctx { deferred = table }
function M.begin_batch()
  return { deferred = {} }
end

--- 结束批量应用会话：对会话内已应用候选做一次 O(n) 引用统计，删除未被引用者。
--- @param ctx table M.begin_batch 返回值
function M.end_batch(ctx)
  if ctx and ctx.deferred then _discard_candidates(ctx.deferred) end
end

--- 应用所有已批准（或全部待审）变更单元
--- @param opts table|nil { only_approved?: boolean }
--- @return table { applied, failed }
function M.apply_all(opts)
  opts = opts or {}
  local result = { applied = 0, failed = 0 }
  local items
  if opts.only_approved then
    items = M.list({ review_state = M.REVIEW.APPROVED })
  else
    items = _pending_items()
  end
  -- 候选删除推迟到全部应用结束后批量对账：`_discard_candidates` 只做一次引用统计，
  -- 避免逐项 `_candidate_referenced` 全表扫描在大批量应用时退化为 O(n²)。
  local deferred = {}
  for _, item in ipairs(items) do
    local res = M.apply(item.change_set_id, { auto_approve = true, _defer_discard = deferred })
    if res.ok then result.applied = result.applied + 1 else result.failed = result.failed + 1 end
  end
  _discard_candidates(deferred)
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
  for _, item in ipairs(_pending_items()) do
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
--- 同一文件被再次编辑/发布时，旧待审项不再有意义（内容已被更新版本覆盖）。
--- **按文件粒度取代**：只记录被覆盖的路径（增量，O(重叠)），同单元其余文件保留为待审。
--- 否则一条包含上千文件的包安装变更单元会因后续命令只改其中一个文件（如 import 生成
--- `.pyc`）而被整单元丢弃，导致批准后包内 `.py`/dist-info 缺失（`ImportError ...
--- (unknown location)`、命名空间包）。
--- 增量取代**不重编码整单元/候选**（含上万文件时那是每轮卡顿源），只在应用/展示时按增量剔除。
--- 例外：`atomic_group="git"` 的对象/指针必须整组保留，不可拆分。
--- @param paths table 路径数组
--- @param except_id string|nil 不取代的 change_set_id（通常是刚入队的新项）
--- @return number superseded 受影响的变更单元数量
function M.supersede_by_paths(paths, except_id)
  local set = {}
  for _, p in ipairs(paths or {}) do set[p] = true end
  if not next(set) then return 0 end
  local n = 0
  local to_discard = {}
  for _, item in ipairs(_pending_items()) do
    if item.change_set_id ~= except_id and type(item.files) == "table" and #item.files > 0 then
      local sup = type(item.superseded_paths) == "table" and item.superseded_paths or nil
      local overlap = 0
      for _, f in ipairs(item.files) do
        if set[f.path] and not (sup and sup[f.path]) then overlap = overlap + 1 end
      end
      if overlap > 0 then
        local eff = #item.files - _superseded_count(item)
        if item.atomic_group == "git" or overlap >= eff then
          -- 整单元取代：单文件变更单元、git 原子组（索引↔对象库不可拆分）。
          item.superseded_paths = nil
          item.review_state = M.REVIEW.SUPERSEDED
          item.superseded_by = except_id
          item.superseded_at = os.time()
          state.items[item.change_set_id] = item
          if item.candidate_digest then to_discard[item.candidate_digest] = true end
          _persist(item)
          pcall(store.delete_review_removed, item.change_set_id)
          _emit(require("NeoAI.kernel.events").SANDBOX_REVIEW_SUPERSEDED, {
            change_set_id = item.change_set_id, superseded_by = except_id,
          })
        else
          -- 部分取代：仅登记被覆盖的路径（增量小文件），不改 item.files/candidate_digest，
          -- 故无需重编码整单元（上万文件时避免每轮 O(N) 编码/写盘）。应用/展示时按增量剔除。
          sup = sup or {}
          for _, f in ipairs(item.files) do
            if set[f.path] and not sup[f.path] then sup[f.path] = true end
          end
          item.superseded_paths = sup
          item.partial_superseded_by = except_id
          item.updated_at = os.time()
          state.items[item.change_set_id] = item
          state.pending_cache = nil
          state.pending_items = nil
          pcall(store.write_review_removed, item.change_set_id, sup)
          -- 待审项内容已变化：广播入队事件触发审批窗刷新（事件语义为「待审集合变化」）。
          _emit(require("NeoAI.kernel.events").SANDBOX_REVIEW_ENQUEUED, {
            change_set_id = item.change_set_id, candidate_digest = item.candidate_digest,
            tool = item.tool, partial_supersede = true,
          })
        end
        n = n + 1
      end
    end
  end
  -- 状态改写完成后再批量删除候选：单次引用统计，避免逐项全表扫描的 O(n²)。
  _discard_candidates(to_discard)
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
          -- 浅拷贝（不 deepcopy 含 content 的大候选）：只额外写入 change_set_id。
          local copy = {}
          for k, v in pairs(f) do copy[k] = v end
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
  local digest = "sha256:" .. vim.fn.sha256(json.encode_fast(manifest))
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
  local intent_hash = "sha256:" .. vim.fn.sha256(json.encode_fast({
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
    local to_discard = { [set.candidate.candidate_digest] = true }
    for _, m in ipairs(set.members or {}) do
      m.review_state = M.REVIEW.APPROVED
      m.apply_state = M.APPLY.APPLIED
      m.applied_at = os.time()
      m.receipt = pub.receipt
      state.items[m.change_set_id] = m
      _persist(m)
      if m.candidate_digest then to_discard[m.candidate_digest] = true end
      _emit(require("NeoAI.kernel.events").SANDBOX_APPLIED, {
        change_set_id = m.change_set_id, operation_id = pub.receipt.operation_id,
      })
    end
    _discard_candidates(to_discard)
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
  -- 部分取代增量：被更新候选覆盖的路径不派生进新 revision。
  local psup = type(parent.superseded_paths) == "table" and parent.superseded_paths or nil
  local function keep(p) return not (psup and psup[p]) end
  if opts.contents then
    for _, f in ipairs(cand.files or {}) do
      local new_content = opts.contents[f.path]
      if new_content ~= nil and keep(f.path) then
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
      if allow[f.path] and keep(f.path) then files[#files + 1] = vim.deepcopy(f) end
    end
  else
    for _, f in ipairs(cand.files or {}) do
      if keep(f.path) then files[#files + 1] = vim.deepcopy(f) end
    end
  end
  if #files == 0 then return nil, "NO_FILES_SELECTED" end
  table.sort(files, function(a, b) return a.path < b.path end)
  local manifest = {}
  for _, f in ipairs(files) do manifest[#manifest + 1] = { path = f.path, action = f.action, after_hash = f.after_hash } end
  local json = require("NeoAI.utils.json")
  local newcand = {
    candidate_digest = _sha(json.encode_fast(manifest)),
    files = files,
    created_at = os.time(),
    effect = parent.effect,
    command_id = parent.command_id,
  }
  store.write_candidate_async(newcand)
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
  state.session_auto = nil
  state.loaded = false
  state.pending_cache = nil
  state.pending_items = nil
  state.ref_scans = 0
  state.terminal_order = {}
  state.terminal_set = {}
  _clear_content_cache()
end

--- 诊断：`_candidate_referenced` 全表扫描累计次数（测试用）
--- @return number
function M._ref_scans()
  return state.ref_scans
end

--- 诊断：当前内存中驻留的变更单元数量（测试用；验证终态淘汰）。
--- @return number
function M._memory_count()
  local n = 0
  for _ in pairs(state.items) do n = n + 1 end
  return n
end

return M
