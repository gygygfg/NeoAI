--- NeoAI 历史缓存模块
--- 职责：树结构缓存、列表缓存、round_text 缓存
--- 缓存失效由 history_manager 在数据变更时通知

local M = {}

-- ========== 状态 ==========

local state = {
  _cache_dirty = true,        -- 缓存是否需要重建
  _cached_flat_list = nil,    -- 缓存 list_sessions 结果
  _cached_tree = nil,         -- 缓存 get_tree 结果
  _round_text_cache = {},     -- { [session_id] = text }
  _sessions_ref = nil,        -- 引用 history_manager 的 sessions 表
  _build_round_text_fn = nil, -- round_text 构建函数引用
}

-- ========== 初始化 ==========

--- 初始化缓存模块
--- @param sessions_ref function 获取 sessions 表的函数
--- @param build_round_text_fn function round_text 构建函数
function M.initialize(sessions_ref, build_round_text_fn)
  state._sessions_ref = sessions_ref
  state._build_round_text_fn = build_round_text_fn
  state._cache_dirty = true
  state._cached_flat_list = nil
  state._cached_tree = nil
  state._round_text_cache = {}
end

-- ========== 缓存失效 ==========

--- 标记所有缓存为脏
function M.invalidate_all()
  state._cache_dirty = true
  state._cached_flat_list = nil
  state._cached_tree = nil
  state._round_text_cache = {}
end

--- 清除 round_text 缓存
--- @param session_id string|nil 指定会话ID，nil 时清除所有
function M.invalidate_round_text(session_id)
  if session_id then
    state._round_text_cache[session_id] = nil
  else
    state._round_text_cache = {}
  end
end

--- 标记列表缓存为脏
function M.invalidate_list()
  state._cache_dirty = true
  state._cached_flat_list = nil
end

--- 标记树缓存为脏
function M.invalidate_tree()
  state._cache_dirty = true
  state._cached_tree = nil
end

-- ========== 列表缓存 ==========

--- 获取所有会话列表（带缓存）
--- @return table 会话列表
function M.get_list()
  if state._cached_flat_list and not state._cache_dirty then
    return state._cached_flat_list
  end

  local sessions = state._sessions_ref()
  local result = {}
  for _, session in pairs(sessions) do
    table.insert(result, {
      id = session.id,
      name = session.name,
      created_at = session.created_at,
      updated_at = session.updated_at,
      is_root = session.is_root,
      child_count = #(session.child_ids or {}),
      has_content = session.user ~= nil and session.user ~= "",
    })
  end
  table.sort(result, function(a, b)
    return (a.updated_at or a.created_at or 0) < (b.updated_at or b.created_at or 0)
  end)

  state._cached_flat_list = result
  state._cache_dirty = false
  return result
end

-- ========== 树缓存 ==========

--- 获取树结构（带缓存）
--- @param cleanup_orphans_fn function 清理孤儿会话的函数
--- @param get_root_sessions_fn function 获取根会话的函数
--- @param get_session_fn function 获取会话的函数
--- @return table 树结构
function M.get_tree(cleanup_orphans_fn, get_root_sessions_fn, get_session_fn)
  if state._cached_tree and not state._cache_dirty then
    return state._cached_tree
  end

  -- 先清理孤儿会话
  cleanup_orphans_fn()

  local roots = get_root_sessions_fn()
  local sessions = state._sessions_ref()

  local function build_session_node(session)
    local round_text = M.get_round_text(session)
    local node = {
      id = session.id,
      session_id = session.id,
      name = session.name,
      round_text = round_text,
      children = {},
    }
    for _, cid in ipairs(session.child_ids or {}) do
      local child = sessions[cid]
      if child then
        table.insert(node.children, build_session_node(child))
      end
    end
    return node
  end

  local tree = {}
  for _, root in ipairs(roots) do
    table.insert(tree, build_session_node(root))
  end

  state._cached_tree = tree
  return tree
end

-- ========== Round Text 缓存 ==========

--- 获取或构建 round_text
--- @param session table 会话对象
--- @return string round_text
function M.get_round_text(session)
  if not session then return "" end

  -- 检查缓存
  local cached = state._round_text_cache[session.id]
  if cached then return cached end

  -- 构建 round_text
  local text = state._build_round_text_fn and state._build_round_text_fn(session) or ""
  state._round_text_cache[session.id] = text
  return text
end

-- ========== 重置 ==========

--- 重置（测试用）
function M._test_reset()
  state._cache_dirty = true
  state._cached_flat_list = nil
  state._cached_tree = nil
  state._round_text_cache = {}
  state._sessions_ref = nil
  state._build_round_text_fn = nil
end

return M
