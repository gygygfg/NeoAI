--- 会话树视图
--- @module NeoAI.ui.window.tree_view
--- 会话树窗口：展示会话分支，支持选择/新建/删除/展开折叠。
--- 默认展开根节点，子节点用连接线缩进显示。

local window_manager = require("NeoAI.ui.window.manager")
local session_store = require("NeoAI.core.session.session_store")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")
local chat_view = require("NeoAI.ui.window.chat_view")

local M = {}

-- ========== 私有状态 ==========

local state = {
  win_id = nil,
  buf = nil,
  flat_items = {}, -- { { depth, session, is_open, prefix } }
  selected_idx = 1,
  expanded = {}, -- session_id -> true
  unsubs = {},
  cleaning = false, -- 清理空会话时的重入保护
}

-- ========== 私有函数 ==========

--- 按 Unicode 字符而非 UTF-8 字节截取消息摘要。
--- @param content string|nil
--- @return string|nil
local function _message_preview(content)
  if not content then return nil end
  content = vim.trim(content:gsub("%s+", " "))
  if content == "" then return nil end
  if vim.fn.strchars(content) > 20 then
    content = vim.fn.strcharpart(content, 0, 20) .. "..."
  end
  return content
end

--- 将一次 Agent 执行聚合为一个节点。
--- user 开始、下一条 user 前的最后一条非空 assistant 结束；工具步骤不单列。
--- @param session table
--- @return table 数组 { user?, assistant? }
local function _conversation_rounds(session)
  local rounds = {}
  local current = nil
  for _, message in ipairs(session.messages or {}) do
    if message.role == "user" then
      if current then rounds[#rounds + 1] = current end
      current = { user = _message_preview(message.content) }
    elseif message.role == "assistant" then
      local content = _message_preview(message.content)
      if content then
        current = current or {}
        -- 工具循环可能产生多条 assistant 消息，最终文本才是本轮结果。
        current.assistant = content
      end
    end
  end
  if current then rounds[#rounds + 1] = current end
  return rounds
end

--- 单轮会话树节点文本，不显示内部会话 ID。
--- @param round table
--- @return string
local function _round_preview(round)
  local parts = {}
  if round.user then parts[#parts + 1] = "👤 用户：" .. round.user end
  if round.assistant then parts[#parts + 1] = "🤖 AI：" .. round.assistant end
  return #parts > 0 and table.concat(parts, " | ") or "新会话"
end

--- 判断会话是否为空（无任何消息）
--- @param session table
--- @return boolean
local function _session_is_empty(session)
  return #(session.messages or {}) == 0
end

--- 清理空会话：空会话直接从存储删除，避免树里显示 "├─ 新会话"。
--- 仅删除整支（含所有子孙）都为空的分支，避免误删含内容的子会话。
--- @return number 删除数量
local function _cleanup_empty_sessions()
  local delete_ids = {}
  for id, s in pairs(session_store.get_all()) do
    if _session_is_empty(s) then
      local branch_empty = true
      for _, d in ipairs(session_store.get_descendants(id)) do
        if not _session_is_empty(d) then
          branch_empty = false
          break
        end
      end
      if branch_empty then
        delete_ids[#delete_ids + 1] = id
      end
    end
  end
  for _, id in ipairs(delete_ids) do
    session_store.delete(id)
  end
  return #delete_ids
end

--- 展平会话树，使用 ├─、└─ 和 │ 绘制层级连接线。
local function _build_flat()
  local items = {}
  local roots = session_store.get_roots()
  local function walk(session, depth, prefix, is_last, is_root)
    local children = session_store.get_children(session.id)
    -- 空会话不渲染为节点；其子会话提升到当前层级
    if _session_is_empty(session) then
      for idx, child in ipairs(children) do
        walk(child, depth, prefix, is_last and idx == #children, is_root)
      end
      return
    end
    local is_open = state.expanded[session.id] == true
    local rounds = _conversation_rounds(session)
    local has_children = #rounds > 1 or #children > 0
    local connector = (is_root and #roots == 1) and "" or (is_last and "└─ " or "├─ ")
    items[#items + 1] = {
      depth = depth,
      session = session,
      is_open = is_open,
      has_children = has_children,
      prefix = prefix .. connector,
      is_last = false,
      label = _round_preview(rounds[1] or {}),
    }

    if is_open then
      local entry_count = #rounds - 1 + #children
      local child_prefix = prefix
      if not (is_root and #roots == 1) then
        child_prefix = child_prefix .. (is_last and "   " or "│  ")
      end
      local entry_idx = 0

      -- 首轮是会话节点本身；剩余轮次和分支会话作为其子节点连续展示。
      for round_idx = 2, #rounds do
        entry_idx = entry_idx + 1
        items[#items + 1] = {
          depth = depth + 1,
          session = session,
          is_open = false,
          has_children = false,
          prefix = child_prefix .. (entry_idx == entry_count and "└─ " or "├─ "),
          is_last = false,
          label = _round_preview(rounds[round_idx]),
        }
      end
      for _, child in ipairs(children) do
        entry_idx = entry_idx + 1
        walk(child, depth + 1, child_prefix, entry_idx == entry_count, false)
      end
    end
  end
  for idx, root in ipairs(roots) do
    -- 默认展开根节点
    if state.expanded[root.id] == nil then
      state.expanded[root.id] = true
    end
    local is_last_root = (idx == #roots)
    walk(root, 0, "", is_last_root, true)
  end
  return items
end

--- 更新选中行高亮
local function _update_selection()
  if not state.win_id or not vim.api.nvim_win_is_valid(state.win_id) then return end
  -- 用 cursorline 实现选中高亮
  if #state.flat_items > 0 then
    local target = math.min(state.selected_idx, #state.flat_items)
    vim.api.nvim_win_set_cursor(state.win_id, { target, 0 })
  end
end

--- 渲染树
local function _render()
  if state.cleaning then return end
  -- 先删除空会话（delete 会触发 SESSION_DELETED 重入 _render，用 cleaning 防抖）
  state.cleaning = true
  local ok, err = pcall(_cleanup_empty_sessions)
  state.cleaning = false
  if not ok then
    vim.notify("[NeoAI] 清理空会话失败: " .. tostring(err), vim.log.levels.WARN)
  end
  state.flat_items = _build_flat()
  local lines = {}
  for i, item in ipairs(state.flat_items) do
    lines[#lines + 1] = item.prefix .. item.label
  end
  if #lines == 0 then
    lines = { "（无会话，按 N 新建）" }
  end
  local was_modifiable = vim.bo[state.buf].modifiable
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = was_modifiable
  -- 高亮选中行
  _update_selection()
end

--- 当前选中项
local function _current_item()
  local item = state.flat_items[state.selected_idx]
  if not item then return nil end
  return item
end

--- 移动光标
local function _move(delta)
  if #state.flat_items == 0 then return end
  state.selected_idx = math.max(1, math.min(#state.flat_items, state.selected_idx + delta))
  _update_selection()
end

--- 展开/折叠
local function _toggle_expand()
  local item = _current_item()
  if not item then return end
  if not item.has_children then return end
  if state.expanded[item.session.id] then
    state.expanded[item.session.id] = false
  else
    state.expanded[item.session.id] = true
  end
  _render()
end

--- 选择并打开聊天
local function _select()
  local item = _current_item()
  if not item then return end
  chat_view.open({ session_id = item.session.id })
end

--- 新建子分支
local function _new_child()
  local item = _current_item()
  if not item then
    session_store.create()
  else
    session_store.create({ parent_id = item.session.id })
    state.expanded[item.session.id] = true
  end
  _render()
end

--- 新建根分支
local function _new_root()
  session_store.create()
  _render()
end

--- 删除对话
local function _delete()
  local item = _current_item()
  if not item then return end
  session_store.delete(item.session.id)
  _render()
end

--- 设置键位
local function _set_keymaps()
  local keymap = require("NeoAI.ui.keymap")
  local actions = {
    select = _select,
    new_child = _new_child,
    new_root = _new_root,
    delete_dialog = _delete,
    delete_branch = _delete,
    expand = _toggle_expand,
    collapse = _toggle_expand,
  }
  vim.keymap.set("n", "j", function() _move(1) end, { buffer = state.buf, desc = "下移" })
  vim.keymap.set("n", "k", function() _move(-1) end, { buffer = state.buf, desc = "上移" })
  keymap.register_context("tree", actions, state.buf)
end

-- ========== 公开 API ==========

--- 打开会话树
--- @return table { win_id, buf }
function M.open()
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    vim.api.nvim_set_current_win(state.win_id)
    return { win_id = state.win_id, buf = state.buf }
  end
  session_store.init()
  local created = window_manager.create("tree", { title = "NeoAI Sessions" })
  state.win_id = created.win_id
  state.buf = created.buf
  vim.wo[state.win_id].cursorline = true
  vim.wo[state.win_id].wrap = false
  vim.bo[state.buf].modifiable = false
  _render()
  _set_keymaps()

  -- 订阅会话变更
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.SESSION_CREATED, function() _render() end)
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.SESSION_DELETED, function() _render() end)
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.SESSION_RENAMED, function() _render() end)

  return { win_id = state.win_id, buf = state.buf }
end

--- 关闭
function M.close()
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    window_manager.close(state.win_id)
  end
  -- 清理 buffer，避免重复打开后 :ls 出现多个同名残留
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  for _, unsub in ipairs(state.unsubs) do unsub() end
  state.unsubs = {}
  state.win_id = nil
  state.buf = nil
  state.selected_idx = 1
  state.expanded = {}
end

--- 是否有打开的窗口
--- @return boolean
function M.has_window()
  return state.win_id ~= nil and vim.api.nvim_win_is_valid(state.win_id)
end

--- 刷新
function M.refresh()
  _render()
end

--- 重置（测试用）
function M.reset()
  M.close()
end

return M
