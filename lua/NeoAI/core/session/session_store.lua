--- 会话持久化
--- @module NeoAI.core.session.session_store
--- 追加式 JSONL 存储。CRUD + 序列化 + 撕裂行恢复 + .bak 备份。
--- 追加写入无需解析整个文件；崩溃恢复截断最后不完整行即可。

local fs = require("NeoAI.utils.fs")
local async = require("NeoAI.utils.async")
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

--- 原子重写整个文件（删除/更新时用）
--- @param path string
--- @param sessions table
local function _rewrite_all(path, sessions)
  local json = require("NeoAI.utils.json")
  local lines = {}
  local sizes = {}
  for id, s in pairs(sessions) do
    if s then
      local line = json.encode_fast(session_mod.serialize(s))
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
  local s = session_mod.create(opts)
  state.sessions[s.id] = s
  local ok, err = M.persist(s)
  if not ok then
    vim.notify("[NeoAI] 新会话暂未保存: " .. tostring(err), vim.log.levels.ERROR)
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
  local line = json.encode_fast(session_mod.serialize(session)) .. "\n"
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
--- @return boolean
function M.persist(session)
  local path, line, log, err = _prepare_persist(session)
  if not path then return false, err end
  local ok
  ok, err = fs.append_file(path, line)
  if not ok then
    -- 失败追加可能留下半行，后续重试不能直接接到其后。
    log.dirty = true
    return false, err
  end
  return _finish_persist(path, line, log, session)
end

--- 异步追加式持久化（写盘在 utils.work 线程池，不阻塞主线程）
--- 编码使用 C 实现的 encode_fast（跳过纯 Lua UTF-8 深扫），主线程仅做一次 JSON 序列化。
--- @param session table
--- @return Deferred resolve(true), reject(err)
function M.persist_async(session)
  local path, line, log, err = _prepare_persist(session)
  if not path then return async.reject(err) end
  return fs.append_file_async(path, line):then_(function()
    return _finish_persist(path, line, log, session)
  end, function(e)
    log.dirty = true
    return async.reject(e)
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

--- 默认删除目标及直接子会话；opts.recursive 删除完整分支。
--- @param session_id string
--- @param opts table|nil { recursive?: boolean }
--- @return table 删除的 id 列表（保存失败为空）, string|nil 错误
function M.delete(session_id, opts)
  M.init()
  local target = state.sessions[session_id]
  if not target then return {} end
  local deleted = { session_id }
  local removed = { [session_id] = true }
  -- 保留既有的一层删除语义。
  local children = opts and opts.recursive and M.get_descendants(session_id) or M.get_children(session_id)
  for _, c in ipairs(children) do
    if not removed[c.id] then
      deleted[#deleted + 1] = c.id
      removed[c.id] = true
    end
  end
  local survivors = {}
  local reparented = {}
  for id, s in pairs(state.sessions) do
    if not removed[id] then
      local parent = s.parent_id
      local seen = { [id] = true }
      while parent and removed[parent] and not seen[parent] do
        seen[parent] = true
        parent = state.sessions[parent].parent_id
      end
      if parent and (removed[parent] or not state.sessions[parent]) then parent = nil end
      local copy = vim.tbl_extend("force", {}, s)
      copy.parent_id = parent
      survivors[id] = copy
      if parent ~= s.parent_id then reparented[#reparented + 1] = id end
    end
  end
  for id, s in pairs(survivors) do
    local root = s
    local seen = { [id] = true }
    while root.parent_id and survivors[root.parent_id] and not seen[root.parent_id] do
      root = survivors[root.parent_id]
      seen[root.id] = true
    end
    s.root_id = root.id
  end
  -- 先提交磁盘；失败时不改变内存树或发送删除成功事件。
  local ok, err = _save(_session_path(), survivors)
  if not ok then return {}, err end
  for id, s in pairs(survivors) do
    -- 保留存活会话的对象身份，避免 UI/Agent 持有陈旧引用。
    state.sessions[id].parent_id = s.parent_id
    state.sessions[id].root_id = s.root_id
  end
  for _, id in ipairs(deleted) do state.sessions[id] = nil end
  event_bus.emit(events.SESSION_SAVED, { count = M.count() })
  event_bus.emit(events.SESSION_DELETED, { session_id = session_id, deleted = deleted, reparented = reparented })
  return deleted
end

--- 获取直接子会话
--- @param session_id string
--- @return table 数组
function M.get_children(session_id)
  local out = {}
  for id, s in pairs(state.sessions) do
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
  for id, s in pairs(state.sessions) do
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
--- @param session_id string
--- @return table 数组
function M.get_downstream(session_id)
  local out = {}
  local current = session_id
  local guard = 0
  while state.sessions[current] and guard < 1000 do
    local children = M.get_children(current)
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
