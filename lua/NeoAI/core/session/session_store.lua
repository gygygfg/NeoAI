--- 会话持久化
--- @module 'NeoAI.core.session.session_store'
--- 追加式 JSONL 存储。CRUD + 序列化 + 撕裂行恢复 + .bak 备份。
--- 追加写入无需解析整个文件；崩溃恢复截断最后不完整行即可。

local fs = require("NeoAI.utils.fs")
local async = require("NeoAI.utils.async")
local work = require("NeoAI.utils.work")
local session_mod = require("NeoAI.core.session.session")
local config_store = require("NeoAI.kernel.config_store")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")

local M = {}

-- ========== 私有状态 ==========

local state = {
  sessions = {}, -- id -> session
  loaded = false,
  default_path_redirect = nil, -- 测试隔离：默认会话目录的重定向
  logs = {}, -- path -> { rows, bytes, sizes = { [session_id] = 最新快照字节数 } }
  -- 每条日志路径一条写盘串行链：追加式持久化（persist_async）与整文件重写（mutate_async）
  -- 必须串行，否则重写可能基于旧快照提交、覆盖刚追加的新快照（丢消息）。
  write_chains = {}, -- path -> Deferred（链尾）
}

-- ========== 私有函数 ==========

local function _default_session_dir()
  return vim.fn.stdpath("cache") .. "/NeoAI"
end

local function _session_path()
  local session_cfg = config_store.get("session") or {}
  local base = session_cfg.save_path or _default_session_dir()
  local file = session_cfg.file or "sessions.jsonl"
  -- 测试隔离：仅当使用默认目录（未被显式配置为其它路径）时重定向到临时目录，
  -- 避免测试会话污染真实历史。显式配置 save_path 的测试不受影响。
  if state.default_path_redirect and base == _default_session_dir() then
    return fs.join(state.default_path_redirect, file)
  end
  return fs.join(base, file)
end

local function _new_log()
  return { rows = 0, bytes = 0, sizes = {}, count = 0, live_bytes = 0 }
end

local function _record(log, id, size)
  log.rows = log.rows + 1
  log.bytes = log.bytes + size
  if id then
    local previous = log.sizes[id]
    if not previous then log.count = log.count + 1 end
    log.live_bytes = log.live_bytes - (previous or 0) + size
    log.sizes[id] = size
  end
end

--- 落盘前对会话对象做密钥脱敏：真/假密钥一律替换为 `<密钥占位符>`。
--- 仅作用于写盘的副本，内存中的会话仍保留 token（供 detokenize 与界面展示）。
--- 沙箱密钥模块不可用或未启用时原样返回。
--- @param session table
--- @return table
local function _redact_session(session)
  local cfg = config_store.get("session") or {}
  if cfg.redact_secrets == false then return session end
  local ok, secret = pcall(require, "NeoAI.sandbox.secret.secret")
  if not ok or type(secret) ~= "table" or type(secret.redact_copy) ~= "function" then return session end
  if secret.enabled and not secret.enabled() then return session end
  local ok2, out = pcall(secret.redact_copy, session)
  if ok2 and type(out) == "table" then return out end
  return session
end

--- 序列化并脱敏（JSON 编码前统一走此处，杜绝真/假密钥写入历史文件）。
--- @param session table
--- @return table
local function _serialize_redacted(session)
  return _redact_session(session_mod.serialize(session))
end

--- 原子重写整个文件（删除/更新时用）
--- @param path string
--- @param sessions table
local function _rewrite_all(path, sessions)
  local json = require("NeoAI.utils.json")
  local lines = {}
  local sizes = {}
  for id, s in pairs(sessions) do
    if s then
      local line = json.encode_fast(_serialize_redacted(s))
      lines[#lines + 1] = line
      sizes[id] = #line + 1
    end
  end
  local content = #lines > 0 and (table.concat(lines, "\n") .. "\n") or ""
  local ok, err = fs.write_file_atomic(path, content, { backup = true })
  if not ok then return false, err end
  state.logs[path] = { rows = #lines, bytes = #content, sizes = sizes, count = #lines, live_bytes = #content }
  return true
end

local function _save(path, sessions)
  local ok, err = fs.ensure_dir(fs.dirname(path))
  if ok then ok, err = _rewrite_all(path, sessions) end
  if not ok then
    require("NeoAI.kernel.logger").error("[session_store] 保存失败 %s: %s", path, tostring(err))
    return false, err
  end
  return true
end

local function _should_compact(log)
  local cfg = config_store.get("session.log_compaction") or {}
  if cfg.enabled == false then return false end
  -- 条数上限限制小快照冗余；字节上限避免少量巨大快照积累。
  local redundant = log.rows - log.count
  return redundant >= math.max(1, cfg.max_redundant_records or 64)
    or (redundant > 0 and log.bytes >= math.max(cfg.min_bytes or 8 * 1024 * 1024, log.live_bytes * 2))
end

-- ========== 纯函数：删除计划（主线程与工作线程共用同一份源码） ==========

--- 删除计划源码。纯 Lua、自包含（无 require / 无 upvalue），可在 utils.work 线程内
--- `assert(load(src))()` 后执行，也可在主线程同步执行——两条路径语义完全一致。
--- 入参：{ sessions = { [id] = { parent_id?, metadata?, ... } }, session_id,
---         recursive?, include_sub_agents? }
--- 出参：{ deleted = {id...}, survivors = { [id] = { parent_id, root_id } }, reparented = {id...} }
local DELETE_PLAN_SRC = [==[
return function(input)
  local sessions = input.sessions or {}
  local target_id = input.session_id
  if not target_id or not sessions[target_id] then
    return { deleted = {}, survivors = {}, reparented = {} }
  end

  -- 一次建索引：parent_id -> 子会话 id 数组（缺失父级/自环不计入）
  local children_of = {}
  for id, s in pairs(sessions) do
    local pid = s.parent_id
    if pid and pid ~= id and sessions[pid] then
      local arr = children_of[pid]
      if not arr then arr = {}; children_of[pid] = arr end
      arr[#arr + 1] = id
    end
  end

  local function descendants(root)
    local out = {}
    local seen = { [root] = true }
    local queue, head = { root }, 1
    while head <= #queue do
      local cur = queue[head]
      head = head + 1
      local ch = children_of[cur]
      if ch then
        for i = 1, #ch do
          local c = ch[i]
          if not seen[c] then
            seen[c] = true
            out[#out + 1] = c
            queue[#queue + 1] = c
          end
        end
      end
    end
    return out
  end

  local function is_sub_agent(id)
    local data = sessions[id]
    local tags = data and data.metadata and data.metadata.tags
    if type(tags) ~= "table" then return false end
    for i = 1, #tags do
      if tags[i] == "sub_agent" then return true end
    end
    return false
  end

  local removed = { [target_id] = true }
  local deleted = { target_id }
  local function remove(id)
    if removed[id] then return end
    removed[id] = true
    deleted[#deleted + 1] = id
  end

  if input.recursive then
    local list = descendants(target_id)
    for i = 1, #list do remove(list[i]) end
  else
    -- 保留既有的一层删除语义：目标 + 直接子会话。
    local ch = children_of[target_id]
    if ch then
      for i = 1, #ch do remove(ch[i]) end
    end
  end

  -- 子 Agent 会话是主会话的附属数据：主会话被删时不得残留（含更深子支），
  -- 否则会留下挂在已删主会话下、在会话树中又整体隐藏的孤儿会话。
  if input.include_sub_agents ~= false then
    local i = 1
    while i <= #deleted do
      local id = deleted[i]
      if is_sub_agent(id) then
        local list = descendants(id)
        for j = 1, #list do remove(list[j]) end
      end
      i = i + 1
    end
  end

  -- 幸存者重挂到最近存活祖先（无祖先则提升为根）
  local survivors = {}
  local reparented = {}
  for id, s in pairs(sessions) do
    if not removed[id] then
      local parent = s.parent_id
      local seen = { [id] = true }
      while parent and removed[parent] and not seen[parent] do
        seen[parent] = true
        local pdata = sessions[parent]
        parent = pdata and pdata.parent_id
      end
      if parent and (removed[parent] or not sessions[parent]) then parent = nil end
      survivors[id] = { parent_id = parent, root_id = id }
      if parent ~= s.parent_id then reparented[#reparented + 1] = id end
    end
  end
  for id, info in pairs(survivors) do
    local cur = id
    local guard = 0
    while guard < 1000 do
      local pid = survivors[cur] and survivors[cur].parent_id
      if not pid or not survivors[pid] then break end
      cur = pid
      guard = guard + 1
    end
    info.root_id = cur
  end
  table.sort(deleted)
  -- 目标会话置于首位：保持既有返回顺序（目标在前，其余按 id 升序），事件消费方依赖该顺序。
  if deleted[1] ~= target_id then
    for i = 2, #deleted do
      if deleted[i] == target_id then
        table.remove(deleted, i)
        table.insert(deleted, 1, target_id)
        break
      end
    end
  end
  table.sort(reparented)
  return { deleted = deleted, survivors = survivors, reparented = reparented }
end
]==]

--- 加载删除计划函数（懒加载 + 缓存）
--- @return function
local function _delete_plan()
  if not state.delete_plan_fn then
    state.delete_plan_fn = assert(load(DELETE_PLAN_SRC))()
  end
  return state.delete_plan_fn
end

-- ========== 纯函数：整文件重写（工作线程内执行） ==========

--- 批量变更的落盘实现源码。在工作线程内直接读写会话日志：
--- 折叠为每 id 最新快照 → 应用 trim / delete 计划 → 原子重写整文件。
--- 仅使用 io / vim.json / vim.uv（严禁 vim.api / vim.fn：线程内非线程安全）。
--- 入参：{ path = string, ops = { {op="delete",...} | {op="trim",...} } }
--- 出参：{ deleted = {id...}, reparented = {id...}, survivors = { [id] = {parent_id, root_id} },
---         rows = number, bytes = number, size_ids = {id...}, size_bytes = {n...} }
local MUTATE_SRC = [==[
return function(input, plan_src)
  local plan_of = assert(load(plan_src))()
  local path = input.path
  local ops = input.ops or {}

  -- 1) 读现有日志（保留原文用于 .bak 备份）并折叠为每 id 最新快照
  local original = nil
  do
    local f = io.open(path, "rb")
    if f then
      original = f:read("*a") or ""
      f:close()
    end
  end
  local order, records = {}, {}
  if original and original ~= "" then
    for line in original:gmatch("[^\r\n]+") do
      local ok, data = pcall(vim.json.decode, line)
      if ok and type(data) == "table" and type(data.id) == "string" then
        if not records[data.id] then order[#order + 1] = data.id end
        records[data.id] = data
      end
    end
  end

  -- 2) 依次应用变更（delete 需先重挂幸存者，再移除被删记录，保证后续 op 看到最新图）
  local removed_set, reparented_set = {}, {}
  for i = 1, #ops do
    local op = ops[i]
    if op.op == "trim" then
      local rec = records[op.id]
      local msgs = rec and rec.messages
      if type(msgs) == "table" and op.first and op.last
        and op.first >= 1 and op.last <= #msgs and op.first <= op.last then
        local out = {}
        for idx = 1, #msgs do
          if idx < op.first or idx > op.last then out[#out + 1] = msgs[idx] end
        end
        rec.messages = out
        rec.updated_at = op.ts or os.time()
      end
    elseif op.op == "delete" then
      if records[op.id] then
        local plan = plan_of({
          sessions = records,
          session_id = op.id,
          recursive = op.recursive == true,
          include_sub_agents = op.include_sub_agents ~= false,
        })
        for id, info in pairs(plan.survivors) do
          local rec = records[id]
          if rec then
            if rec.parent_id ~= info.parent_id then reparented_set[id] = true end
            rec.parent_id = info.parent_id
            rec.root_id = info.root_id
          end
        end
        for j = 1, #plan.deleted do
          local id = plan.deleted[j]
          removed_set[id] = true
          records[id] = nil
        end
      end
    end
  end

  -- 3) 序列化剩余记录（保持首次出现顺序，输出稳定）
  local lines = {}
  local size_ids, size_bytes = {}, {}
  local bytes = 0
  for i = 1, #order do
    local id = order[i]
    local rec = records[id]
    if rec then
      local ok, line = pcall(vim.json.encode, rec)
      if not ok then error("会话快照序列化失败 " .. tostring(id) .. ": " .. tostring(line)) end
      lines[#lines + 1] = line
      local size = #line + 1
      bytes = bytes + size
      size_ids[#size_ids + 1] = id
      size_bytes[#size_bytes + 1] = size
    end
  end
  local content = #lines > 0 and (table.concat(lines, "\n") .. "\n") or ""

  -- 4) 原子重写：mkstemp → 全量写 → 尺寸校验 → fsync → .bak → rename
  -- 语义与 utils.fs.write_file_atomic 一致：任何一步失败都不提交（不截断原文件）。
  local uv = vim.uv
  local fd, tmp = uv.fs_mkstemp(path .. ".tmp.XXXXXX")
  if not fd then error("无法创建临时文件: " .. tostring(tmp)) end
  local write_ok, write_err = pcall(function()
    local offset = 0
    while offset < #content do
      local n, err = uv.fs_write(fd, content:sub(offset + 1), offset)
      if not n or n == 0 then error("文件写入未完成: " .. tostring(err)) end
      offset = offset + n
    end
    local st = uv.fs_stat(tmp)
    if not st or st.size ~= #content then
      error(string.format("写入校验失败：期望 %d 字节，实际 %s 字节", #content, tostring(st and st.size)))
    end
    local synced, sync_err = uv.fs_fsync(fd)
    if not synced then error("落盘失败: " .. tostring(sync_err)) end
  end)
  uv.fs_close(fd)
  if not write_ok then
    uv.fs_unlink(tmp)
    error(write_err)
  end
  if original and original ~= "" then
    local bf, berr = io.open(path .. ".bak", "wb")
    if not bf then
      uv.fs_unlink(tmp)
      error("备份失败: " .. tostring(berr))
    end
    bf:write(original)
    bf:close()
  end
  local renamed, rename_err = uv.fs_rename(tmp, path)
  if not renamed then
    uv.fs_unlink(tmp)
    error("提交失败: " .. tostring(rename_err))
  end

  local deleted, reparented = {}, {}
  for id in pairs(removed_set) do deleted[#deleted + 1] = id end
  for id in pairs(reparented_set) do reparented[#reparented + 1] = id end
  table.sort(deleted)
  -- 目标会话置于首位：保持既有返回顺序（目标在前，其余按 id 升序），事件消费方依赖该顺序。
  if deleted[1] ~= target_id then
    for i = 2, #deleted do
      if deleted[i] == target_id then
        table.remove(deleted, i)
        table.insert(deleted, 1, target_id)
        break
      end
    end
  end
  table.sort(reparented)
  local survivors = {}
  for id, rec in pairs(records) do
    survivors[id] = { parent_id = rec.parent_id, root_id = rec.root_id }
  end
  return {
    deleted = deleted,
    reparented = reparented,
    survivors = survivors,
    rows = #lines,
    bytes = bytes,
    size_ids = size_ids,
    size_bytes = size_bytes,
  }
end
]==]

--- 工作线程执行器：把源码字符串定义的纯函数跑在线程内（自包含，无 upvalue）。
--- @param input any 经 msgpack 解码的结构化入参
--- @param src string 纯函数源码字符串
--- @param extra any|nil 额外原始类型参数（如删除计划源码）
--- @return any
local function _src_runner(input, src, extra)
  return assert(load(src))()(input, extra)
end

-- ========== 普通函数：写盘串行链 ==========

--- 把一次写盘任务串到该路径的串行链上（前序失败不阻断后续，链尾吞掉拒绝）。
--- @param path string
--- @param task function() -> Deferred|any
--- @return Deferred resolve(task 的结果), reject(err)
local function _enqueue_write(path, task)
  local prev = state.write_chains[path]
  local d = async.Deferred.new()
  local function _start()
    local ok, res = pcall(task)
    if not ok then
      d:reject({ kind = "session_write", message = tostring(res) })
      return
    end
    if type(res) == "table" and type(res.then_) == "function" then
      res:then_(function(v) d:resolve(v) end, function(e) d:reject(e) end)
    else
      d:resolve(res)
    end
  end
  if prev then
    prev:then_(_start, _start)
  else
    _start()
  end
  state.write_chains[path] = d
  local function _cleanup()
    if state.write_chains[path] == d then state.write_chains[path] = nil end
  end
  d:then_(_cleanup, _cleanup)
  return d
end

--- 该路径是否有在途写盘任务（整文件重写期间追加写需补写一次，避免被旧快照覆盖）。
--- @param path string
--- @return boolean
local function _has_pending_write(path)
  return state.write_chains[path] ~= nil
end

-- ========== 公开 API ==========

--- 初始化会话存储
function M.init()
  if state.loaded then return M end
  local path = _session_path()
  local log = _new_log()
  if fs.exists(path) then
    local _, repair_err = fs.repair_jsonl(path)
    if repair_err then error("无法修复会话日志: " .. tostring(repair_err)) end
    local json = require("NeoAI.utils.json")
    local latest = {}
    local f, err = io.open(path, "rb")
    if not f then error("无法读取会话: " .. tostring(err)) end
    for line in f:lines() do
      local data = json.decode_line(line)
      if type(data) == "table" and type(data.id) == "string" then
        latest[data.id] = data
        _record(log, data.id, #line + 1)
      else
        _record(log, nil, #line + 1)
      end
    end
    f:close()
    -- 同一会话只反序列化最新快照，不保留/深复制全部旧版本。
    for _, data in pairs(latest) do
      local ok, s = pcall(session_mod.deserialize, data)
      if ok and s then
        state.sessions[s.id] = s
      end
    end
  end
  state.logs[path] = log
  state.loaded = true
  local logger = require("NeoAI.kernel.logger")
  logger.info("[session_store] 已加载 %d 个会话", M.count())
  return M
end

--- 获取所有会话
--- @return table id -> session
function M.get_all()
  return state.sessions
end

--- 按 id 获取会话
--- @param session_id string
--- @return table|nil
function M.get(session_id)
  return state.sessions[session_id]
end

--- 创建新会话（内存 + 持久化）
--- @param opts table|nil
--- @return table 会话
--- @return string|nil err
function M.create(opts)
  M.init()
  opts = vim.deepcopy(opts or {})
  -- 子会话未显式指定 root_id 时，继承父会话的 root_id
  if opts.parent_id and not opts.root_id then
    local parent = state.sessions[opts.parent_id]
    if parent then
      opts.root_id = parent.root_id or parent.id
    end
  end
  -- 会话绑定工作目录（metadata.cwd）：显式 opts.cwd/metadata.cwd 优先；子会话继承父会话；
  -- 否则从 cwd 向上按标记（.git 优先，其次工程配置文件）定位工作区根；标记全覆盖未命中时
  -- 回退 `$PWD`（nvim 启动目录），不再用可能被 `:cd`/`:lcd` 改过的编辑器 cwd。
  -- 此后从其他路径重开该会话时以其为工作区基准，不跟随当前 cwd，也不改编辑器全局 cwd。
  opts.metadata = opts.metadata or {}
  if opts.metadata.cwd == nil then
    local cwd = opts.cwd
    if not cwd and opts.parent_id then
      local parent = state.sessions[opts.parent_id]
      cwd = parent and parent.metadata and parent.metadata.cwd
    end
    if not cwd then
      cwd = require("NeoAI.core.session.workspace_root").resolve()
    end
    opts.metadata.cwd = cwd
  end
  if opts.metadata.tags == nil then opts.metadata.tags = {} end
  if opts.metadata.usage == nil then opts.metadata.usage = { prompt = 0, completion = 0 } end
  if opts.metadata.name == nil then opts.metadata.name = opts.name end
  local s = session_mod.create(opts)
  state.sessions[s.id] = s
  local ok, err = M.persist(s)
  if not ok then
    vim.notify("[NeoAI] 新会话暂未保存: " .. async.error_text(err), vim.log.levels.ERROR)
  end
  event_bus.emit(events.SESSION_CREATED, { session = s })
  return s, err
end

--- 准备一次追加持久化：编码单行并确保目录/日志状态就绪。
--- 编码走 C 实现的 encode_fast（跳过纯 Lua UTF-8 深扫），是主线程唯一的大对象序列化。
--- @param session table
--- @return string|nil path
--- @return string|nil line
--- @return table|nil log
--- @return any err
local function _prepare_persist(session)
  local path = _session_path()
  local ok, err = fs.ensure_dir(fs.dirname(path))
  if not ok then return nil, nil, nil, err end
  local json = require("NeoAI.utils.json")
  local line = json.encode_fast(_serialize_redacted(session)) .. "\n"
  local log = state.logs[path]
  if not log then
    local stat = vim.uv.fs_stat(path)
    log = _new_log()
    log.bytes = stat and stat.size or 0
    state.logs[path] = log
  end
  if log.dirty then
    local _, repair_err = fs.repair_jsonl(path)
    if repair_err then return nil, nil, nil, repair_err end
    log.dirty = false
  end
  return path, line, log
end

--- 追加成功后的记账与周期合并。
--- @param path string
--- @param line string
--- @param log table
--- @param session table
--- @return boolean
local function _finish_persist(path, line, log, session)
  -- 串行链上的整文件重写会替换记账对象：始终以当前记账为准，避免向已淘汰的 log 追加。
  log = state.logs[path] or log
  _record(log, session.id, #line)
  if _should_compact(log) then
    -- 追加已落盘；合并失败保留原日志并记录错误，下次持久化重试合并。
    local sessions = vim.tbl_extend("force", state.sessions, { [session.id] = session })
    _save(path, sessions)
  end
  return true
end

--- 追加式持久化单个会话
--- @param session table
--- @param opts table|nil { _requeued?: boolean 内部标记，防止链尾补写递归 }
--- @return boolean
--- @return string|nil err
function M.persist(session, opts)
  opts = opts or {}
  local path, line, log, err = _prepare_persist(session)
  if not path or not line or not log then return false, err end
  local ok
  ok, err = fs.append_file(path, line)
  if not ok then
    -- 失败追加可能留下半行，后续重试不能直接接到其后。
    log.dirty = true
    return false, err
  end
  local done = _finish_persist(path, line, log, session)
  -- 该路径有在途整文件重写：它可能基于重写前的快照提交并覆盖刚追加的行，
  -- 因此在其结束后补写一次同样的快照（幂等；仅补一次，不递归）。
  if done and not opts._requeued and _has_pending_write(path) then
    local function _requeue()
      if state.sessions[session.id] then M.persist(session, { _requeued = true }) end
    end
    state.write_chains[path]:then_(_requeue, _requeue)
  end
  return done
end

--- 异步追加式持久化（写盘在 utils.work 线程池，不阻塞主线程）
--- 编码使用 C 实现的 encode_fast（跳过纯 Lua UTF-8 深扫），主线程仅做一次 JSON 序列化。
--- 与整文件重写共用同一 per-path 串行链，避免两者交错。
--- @param session table
--- @return Deferred resolve(true), reject(err)
function M.persist_async(session)
  local path, line, log, err = _prepare_persist(session)
  if not path or not line or not log then return async.reject(err) end
  return _enqueue_write(path, function()
    return fs.append_file_async(path, line):then_(function()
      return _finish_persist(path, line, log, session)
    end, function(e)
      -- 线程池/后台 worker 未能启动该任务（队列已满、已停止等）：追加尚未发生，
      -- 退化为**同步追加**。会话消息比一次主线程小写入更重要——资源压力下（如同时
      -- 生成大量图像附件、worker 队列打满）不能直接把消息留在内存里丢掉。
      if type(e) == "table" and e.not_started then
        local ok, serr = fs.append_file(path, line)
        if ok then
          return _finish_persist(path, line, log, session)
        end
        require("NeoAI.kernel.logger").error("[session_store] 追加失败 %s: %s",
          path, tostring(serr))
        return async.reject(serr)
      end
      -- 可能已部分写入：标记脏日志，下次持久化先 repair，再重试。
      log.dirty = true
      return async.reject(e)
    end)
  end)
end

--- 保存（重写整个文件，用于删除/批量变更后）
function M.save_all()
  local path = _session_path()
  local ok, err = _save(path, state.sessions)
  if not ok then return false, err end
  event_bus.emit(events.SESSION_SAVED, { count = M.count() })
  return true
end

--- 更新会话并持久化
--- @param session table
function M.update(session)
  state.sessions[session.id] = session
  return M.persist(session)
end

--- 删除指定消息区间，持久化成功后才更新内存。
function M.delete_messages(session_id, first, last)
  local session = M.get(session_id)
  if not session or not first or not last or first < 1 or last > #session.messages or first > last then
    return false, "无效的消息区间"
  end
  local copy = vim.tbl_extend("force", {}, session)
  copy.messages = {}
  for i, msg in ipairs(session.messages) do
    if i < first or i > last then copy.messages[#copy.messages + 1] = msg end
  end
  copy.updated_at = os.time()
  local ok, err = M.persist(copy)
  if not ok then return false, err end
  session.messages = copy.messages
  session.updated_at = copy.updated_at
  return true
end

--- 删除会话（同步）。默认删除目标及直接子会话；`opts.recursive` 删除完整分支。
--- 被删集合内若有子 Agent 会话（`metadata.tags` 含 `sub_agent`），连同其整支后代一并删除
--- （`opts.include_sub_agents = false` 可关闭），避免留下挂在已删主会话下的孤儿会话。
--- 先提交磁盘；失败时不改变内存树、不发送删除事件。
--- @param session_id string
--- @param opts table|nil { recursive?: boolean, include_sub_agents?: boolean }
--- @return table 删除的 id 列表（保存失败为空）
--- @return string|nil 错误
function M.delete(session_id, opts)
  M.init()
  local target = state.sessions[session_id]
  if not target then return {} end
  local plan = _delete_plan()({
    sessions = state.sessions,
    session_id = session_id,
    recursive = opts and opts.recursive == true,
    include_sub_agents = not (opts and opts.include_sub_agents == false),
  })
  -- 落盘用会话副本（携带重挂后的 parent_id / root_id），提交时只改存活对象的这两个字段，
  -- 保留其对象身份，避免 UI/Agent 持有陈旧引用。
  local survivors = {}
  for id, info in pairs(plan.survivors) do
    local s = state.sessions[id]
    if s then
      local copy = vim.tbl_extend("force", {}, s)
      copy.parent_id = info.parent_id
      copy.root_id = info.root_id
      survivors[id] = copy
    end
  end
  local ok, err = _save(_session_path(), survivors)
  if not ok then return {}, err end
  for id, info in pairs(plan.survivors) do
    local s = state.sessions[id]
    if s then
      s.parent_id = info.parent_id
      s.root_id = info.root_id
    end
  end
  for _, id in ipairs(plan.deleted) do state.sessions[id] = nil end
  event_bus.emit(events.SESSION_SAVED, { count = M.count() })
  event_bus.emit(events.SESSION_DELETED, {
    session_id = session_id,
    deleted = plan.deleted,
    reparented = plan.reparented,
  })
  return plan.deleted
end

--- 在内存真值上模拟一批变更，算出「落盘后应得」的最终状态（纯计算，不改内存/磁盘）。
--- @param ops table
--- @return table|nil survivors 完整会话副本（含重挂后的 parent_id/root_id 与裁剪后的消息）
--- @return table deleted id 数组（目标在前，其余升序）
--- @return table reparented id 数组
--- @return table disk_ops 实际需要落盘的 op（已过滤掉无效项）
local function _simulate_mutations(ops)
  local sessions = state.sessions
  -- 计划用视图：只带 parent_id / metadata（删除计划只读这两项），命中子 Agent 标签判定。
  local view = {}
  for id, s in pairs(sessions) do
    view[id] = { parent_id = s.parent_id, metadata = s.metadata }
  end
  local removed, reparented_ids, trims, disk_ops = {}, {}, {}, {}
  for _, op in ipairs(ops) do
    if op.op == "delete" then
      if view[op.id] then
        local plan = _delete_plan()({
          sessions = view,
          session_id = op.id,
          recursive = op.recursive == true,
          include_sub_agents = op.include_sub_agents ~= false,
        })
        for id, info in pairs(plan.survivors) do
          local v = view[id]
          if v then
            if v.parent_id ~= info.parent_id then reparented_ids[id] = true end
            v.parent_id = info.parent_id
          end
        end
        for _, id in ipairs(plan.deleted) do
          view[id] = nil
          removed[id] = true
        end
        disk_ops[#disk_ops + 1] = op
      end
    elseif op.op == "trim" then
      local s = sessions[op.id]
      local count = s and #(s.messages or {}) or 0
      if s and op.first and op.last and op.first >= 1 and op.last <= count and op.first <= op.last then
        trims[#trims + 1] = op
        disk_ops[#disk_ops + 1] = op
      end
    end
  end
  if #disk_ops == 0 then return nil end

  -- 幸存者完整副本（浅拷贝外壳，消息表按引用共享，与 _build_persist_session 同策略）
  local survivors = {}
  for id, v in pairs(view) do
    local s = sessions[id]
    if s then
      local copy = vim.tbl_extend("force", {}, s)
      copy.parent_id = v.parent_id
      survivors[id] = copy
    end
  end
  -- root_id 重算：沿父链走到根（只走幸存者）
  for id, copy in pairs(survivors) do
    local cur, guard = id, 0
    while guard < 1000 do
      local parent = survivors[cur] and survivors[cur].parent_id
      if not parent or not survivors[parent] then break end
      cur = parent
      guard = guard + 1
    end
    copy.root_id = cur
  end
  for _, t in ipairs(trims) do
    local copy = survivors[t.id]
    if copy then
      local out = {}
      for i, msg in ipairs(copy.messages or {}) do
        if i < t.first or i > t.last then out[#out + 1] = msg end
      end
      copy.messages = out
      copy.updated_at = t.ts or os.time()
    end
  end
  local deleted = {}
  for id in pairs(removed) do deleted[#deleted + 1] = id end
  table.sort(deleted)
  -- 目标会话置于首位（保持既有返回顺序：目标在前，其余升序）
  local lead = nil
  for _, op in ipairs(disk_ops) do
    if op.op == "delete" and removed[op.id] then
      lead = op.id
      break
    end
  end
  if lead and deleted[1] ~= lead then
    for j = 2, #deleted do
      if deleted[j] == lead then
        table.remove(deleted, j)
        table.insert(deleted, 1, lead)
        break
      end
    end
  end
  local reparented = {}
  for id in pairs(reparented_ids) do reparented[#reparented + 1] = id end
  table.sort(reparented)
  return survivors, deleted, reparented, disk_ops
end

--- 异步批量变更（删除会话 / 裁剪轮次）。
--- 整文件重写在 utils.work 线程内完成（读盘 → 应用变更 → 原子重写），与追加式持久化共用
--- 同一条 per-path 写盘串行链。落盘成功后应用内存变更并发事件；失败时不改内存、不发事件
--- （语义：数据未变）。
---
--- 内存变更以**主线程内存真值**计算（内存可能比磁盘新），工作线程结果只用于更新日志记账，
--- 绝不用盘上内容覆盖内存。
--- @param ops table 操作数组
---   `{ op = "delete", id, recursive?, include_sub_agents? }`
---   `{ op = "trim", id, first, last, ts? }`
--- @return Deferred resolve({ deleted = {id...}, reparented = {id...} }), reject(err)
function M.mutate_async(ops)
  M.init()
  ops = type(ops) == "table" and ops or {}
  if #ops == 0 then return async.resolve({ deleted = {}, reparented = {} }) end
  local path = _session_path()

  local survivors, deleted, reparented, disk_ops = _simulate_mutations(ops)
  if not survivors then return async.resolve({ deleted = {}, reparented = {} }) end

  --- 落盘成功后应用内存变更（删除 + 重挂 / root_id 重算 + 轮次裁剪；保留对象身份）。
  local function _commit_memory()
    for id, copy in pairs(survivors) do
      local live = state.sessions[id]
      if live then
        live.parent_id = copy.parent_id
        live.root_id = copy.root_id
        if live.messages ~= copy.messages then
          live.messages = copy.messages
          live.updated_at = copy.updated_at
        end
      end
    end
    for _, id in ipairs(deleted) do state.sessions[id] = nil end
  end

  --- 执行落盘。工作线程不可用时用同一份最终态在主线程同步原子重写（不在此处发事件）。
  local function _run_disk()
    if not work.available() then
      local ok, err = _save(path, survivors)
      if not ok then return async.reject({ kind = "session_write", message = tostring(err) }) end
      return { rows = nil }
    end
    return work.run_codec(_src_runner, { path = path, ops = disk_ops }, MUTATE_SRC, DELETE_PLAN_SRC)
  end

  return _enqueue_write(path, _run_disk):then_(function(disk)
    _commit_memory()
    if type(disk) == "table" and type(disk.rows) == "number" then
      -- 重写后整文件只剩每会话一条最新快照：按工作线程回报的真实尺寸重建记账。
      local log = _new_log()
      log.rows = disk.rows
      log.bytes = disk.bytes or 0
      log.count = disk.rows
      log.live_bytes = disk.bytes or 0
      local ids, vals = disk.size_ids or {}, disk.size_bytes or {}
      for i = 1, math.min(#ids, #vals) do log.sizes[ids[i]] = vals[i] end
      state.logs[path] = log
    end
    event_bus.emit(events.SESSION_SAVED, { count = M.count() })
    if #deleted > 0 then
      event_bus.emit(events.SESSION_DELETED, {
        session_id = deleted[1],
        deleted = deleted,
        reparented = reparented,
      })
    end
    return { deleted = deleted, reparented = reparented }
  end)
end

--- 获取直接子会话
--- @param session_id string
--- @return table 数组
function M.get_children(session_id)
  local out = {}
  for _, s in pairs(state.sessions) do
    if s.parent_id == session_id then
      out[#out + 1] = s
    end
  end
  table.sort(out, function(a, b)
    local at, bt = a.created_at or 0, b.created_at or 0
    if at ~= bt then return at < bt end
    return (a.id or "") < (b.id or "")
  end)
  return out
end

--- 获取根会话
--- @return table 数组
function M.get_roots()
  local out = {}
  for _, s in pairs(state.sessions) do
    if session_mod.is_root(s) then
      out[#out + 1] = s
    end
  end
  -- 按 updated_at 倒序（最近使用在前）；同秒创建时用 id 决胜，保证排序确定，
  -- 避免 Lua table.sort 在键相等时顺序随哈希遍历随机、导致树渲染不稳定
  table.sort(out, function(a, b)
    local at, bt = a.updated_at or 0, b.updated_at or 0
    if at ~= bt then return at > bt end
    return (a.id or "") > (b.id or "")
  end)
  return out
end

--- 遍历后代（BFS）
--- @param session_id string
--- @return table 数组
function M.get_descendants(session_id)
  local out = {}
  local queue = { session_id }
  local seen = { [session_id] = true }
  local head = 1
  while head <= #queue do
    local current = queue[head]
    head = head + 1
    for _, c in ipairs(M.get_children(current)) do
      if not seen[c.id] then
        seen[c.id] = true
        out[#out + 1] = c
        queue[#queue + 1] = c.id
      end
    end
  end
  return out
end

--- 获取从根到指定会话的祖先链（含自身，根在前）
--- @param session_id string
--- @return table 数组
function M.get_chain(session_id)
  local chain = {}
  local current = state.sessions[session_id]
  if not current then return chain end
  local path = { current }
  local parent = current.parent_id
  local guard = 0
  -- 自环根（parent_id == id）与缺失父级都视为到达根部
  while parent and parent ~= current.id and state.sessions[parent] and guard < 1000 do
    current = state.sessions[parent]
    path[#path + 1] = current
    parent = current.parent_id
    guard = guard + 1
  end
  for i = #path, 1, -1 do
    chain[#chain + 1] = path[i]
  end
  return chain
end

--- 沿会话树向下的单子链（不含起始会话）。
--- 只有唯一子会话时继续深入；遇分裂分支（多个子会话）或末尾（无子会话）即止。
--- `opts.skip_sub_agent` 为真时把子 Agent 会话视为不可见：它们不参与单子链判定，
--- 也不会被返回（用于「用户对话主线」的顺延与上下文拼接，避免误入子 Agent 会话）。
--- @param session_id string
--- @param opts table|nil { skip_sub_agent? }
--- @return table 数组
function M.get_downstream(session_id, opts)
  local skip_sub_agent = type(opts) == "table" and opts.skip_sub_agent == true
  local out = {}
  local current = session_id
  local guard = 0
  while state.sessions[current] and guard < 1000 do
    local children = M.get_children(current)
    if skip_sub_agent then
      local visible = {}
      for _, c in ipairs(children) do
        if not session_mod.is_sub_agent(c) then visible[#visible + 1] = c end
      end
      children = visible
    end
    if #children ~= 1 then break end
    out[#out + 1] = children[1]
    current = children[1].id
    guard = guard + 1
  end
  return out
end

--- 会话数量
--- @return number
function M.count()
  local n = 0
  for _ in pairs(state.sessions) do n = n + 1 end
  return n
end

--- 重置（测试用）
function M.reset()
  state.sessions = {}
  state.loaded = false
  state.logs = {}
  state.write_chains = {}
end

--- 设置默认会话目录重定向（测试隔离用）。
--- 仅影响走默认路径（未显式配置 save_path）的会话，不影响显式 save_path 的会话。
--- @param dir string|nil nil 表示取消重定向
--- @return string|nil 原重定向目录（允许嵌套测试恢复）
function M.set_default_path_redirect(dir)
  local previous = state.default_path_redirect
  state.default_path_redirect = dir
  return previous
end

--- 用给定会话表替换内存状态（测试隔离结束后恢复真实会话用）
--- @param sessions table id -> session
function M.restore(sessions)
  state.sessions = sessions or {}
  state.loaded = true
  state.logs = {}
end

return M
