--- 会话持久化
--- @module NeoAI.core.session.session_store
--- 追加式 JSONL 存储。CRUD + 序列化 + 撕裂行恢复 + .bak 备份。
--- 追加写入无需解析整个文件；崩溃恢复截断最后不完整行即可。

local fs = require("NeoAI.utils.fs")
local stringx = require("NeoAI.utils.stringx")
local session_mod = require("NeoAI.core.session.session")
local config_store = require("NeoAI.kernel.config_store")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")

local M = {}

-- ========== 私有状态 ==========

local state = {
  sessions = {}, -- id -> session
  loaded = false,
}

-- ========== 私有函数 ==========

local function _session_path()
  local session_cfg = config_store.get("session") or {}
  return fs.join(session_cfg.save_path or (vim.fn.stdpath("cache") .. "/NeoAI"), session_cfg.file or "sessions.jsonl")
end

--- 原子重写整个文件（删除/更新时用）
--- @param path string
--- @param sessions table
local function _rewrite_all(path, sessions)
  local json = require("NeoAI.utils.json")
  local lines = {}
  for id, s in pairs(sessions) do
    if s then
      lines[#lines + 1] = json.encode(session_mod.serialize(s))
    end
  end
  -- 先写 .bak 再写正式文件
  fs.copy_file(path, path .. ".bak")
  local ok = fs.write_file(path, table.concat(lines, "\n") .. "\n")
  if not ok then
    fs.copy_file(path .. ".bak", path) -- 回滚
    return false
  end
  return true
end

-- ========== 公开 API ==========

--- 初始化会话存储
function M.init()
  if state.loaded then return M end
  local path = _session_path()
  if fs.exists(path) then
    fs.repair_jsonl(path)
    local rows = fs.read_jsonl(path)
    for _, data in ipairs(rows) do
      local ok, s = pcall(session_mod.deserialize, data)
      if ok and s then
        state.sessions[s.id] = s
      end
    end
  end
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
  M.persist(s)
  event_bus.emit(events.SESSION_CREATED, { session = s })
  return s
end

--- 追加式持久化单个会话
--- @param session table
--- @return boolean
function M.persist(session)
  local path = _session_path()
  fs.ensure_dir(fs.dirname(path))
  return fs.append_jsonl(path, session_mod.serialize(session))
end

--- 保存（重写整个文件，用于删除/批量变更后）
function M.save_all()
  local path = _session_path()
  fs.ensure_dir(fs.dirname(path))
  _rewrite_all(path, state.sessions)
  event_bus.emit(events.SESSION_SAVED, { count = M.count() })
end

--- 更新会话并持久化
--- @param session table
function M.update(session)
  state.sessions[session.id] = session
  M.save_all()
end

--- 删除会话（同时删除其子孙）
--- @param session_id string
--- @return table 删除的 id 列表
function M.delete(session_id)
  M.init()
  local target = state.sessions[session_id]
  if not target then return {} end
  local deleted = { session_id }
  -- 收集子孙
  local children = M.get_children(session_id)
  for _, c in ipairs(children) do
    deleted[#deleted + 1] = c.id
  end
  for _, id in ipairs(deleted) do
    state.sessions[id] = nil
  end
  M.save_all()
  event_bus.emit(events.SESSION_DELETED, { session_id = session_id, deleted = deleted })
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
  table.sort(out, function(a, b) return (a.created_at or 0) < (b.created_at or 0) end)
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
  table.sort(out, function(a, b) return (a.updated_at or 0) > (b.updated_at or 0) end)
  return out
end

--- 遍历后代（BFS）
--- @param session_id string
--- @return table 数组
function M.get_descendants(session_id)
  local out = {}
  local queue = { session_id }
  while #queue > 0 do
    local current = table.remove(queue, 1)
    for _, c in ipairs(M.get_children(current)) do
      out[#out + 1] = c
      queue[#queue + 1] = c.id
    end
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
end

return M
