--- 会话树视图
--- @module 'NeoAI.ui.window.tree_view'
--- 会话树窗口：展示会话分支，支持选择/新建/删除/展开折叠。
--- 默认展开根节点，子节点用连接线缩进显示。

local window_manager = require("NeoAI.ui.window.manager")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")
local chat_view = require("NeoAI.ui.window.chat_view")
local services = require("NeoAI.kernel.services")
local config_store = require("NeoAI.kernel.config_store")

-- 会话存储经服务定位器解析（禁用/未就绪时为 nil）：ui 不直接 require core 模块。
-- 以代理保持既有 `session_store.xxx` 调用点不变，调用时惰性解析服务。
local session_store = setmetatable({}, {
  __index = function(_, k)
    local ss = services.use("services.session")
    return ss and ss[k]
  end,
})

--- 聊天服务经服务定位器动态解析（禁用时为 nil）
local function _chat_service()
  return services.use("services.chat_service")
end

local M = {}

-- ========== 私有状态 ==========

local state = {
  win_id = nil,
  buf = nil,
  flat_items = {}, -- { { depth, session, is_open, prefix } }
  selected_idx = 1,
  expanded = {}, -- session_id -> true
  unsubs = {},
  cursor_augroup = nil,
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

--- 是否为子 Agent 结果消息（标记或投递包装文本，兼容旧数据）
--- @param message table
--- @return boolean
local function _is_sub_agent_message(message)
  if not message then return false end
  if message.sub_agent then return true end
  if message.role ~= "user" then return false end
  return type(message.content) == "string" and message.content:match("^%s*【子 Agent ") ~= nil
end

--- 将一次 Agent 执行聚合为一个节点。
--- user 开始、下一条 user 前的最后一条非空 assistant 结束；工具步骤不单列。
--- @param session table
--- @return table 数组 { user?, assistant? }
local function _conversation_rounds(session)
  local rounds = {}
  local current = nil
  for index, message in ipairs(session.messages or {}) do
    if _is_sub_agent_message(message) then
      -- 子 Agent 结果不是用户轮次：不作为新轮起点（归入当前轮的 AI 回复）
    elseif message.role == "user" then
      if current then
        current.last = index - 1
        rounds[#rounds + 1] = current
      end
      current = { user = _message_preview(message.content), first = index }
    elseif message.role == "assistant" then
      local content = _message_preview(message.content)
      if content then
        current = current or { first = index }
        -- 工具循环可能产生多条 assistant 消息，最终文本才是本轮结果。
        current.assistant = content
      end
    end
  end
  if current then
    current.last = #(session.messages or {})
    rounds[#rounds + 1] = current
  end
  return rounds
end

--- 是否为子 Agent 会话（metadata.tags 含 sub_agent）
--- @param session table
--- @return boolean
local function _is_sub_agent_session(session)
  local tags = session and session.metadata and session.metadata.tags
  if type(tags) ~= "table" then return false end
  for _, t in ipairs(tags) do
    if t == "sub_agent" then return true end
  end
  return false
end

--- 会话是否在会话树中整体隐藏：子 Agent 会话及其整支后代都不显示。
--- 子 Agent 会话由子 Agent 管理器挂在主会话下（`parent_id` = 主会话），
--- 在树里混排会让用户误以为它们是用户分支；隐藏后主会话节点仍是用户对话主线。
--- @param session table
--- @return boolean
local function _is_hidden_branch(session)
  if not session then return false end
  if _is_sub_agent_session(session) then return true end
  for _, ancestor in ipairs(session_store.get_chain(session.id)) do
    if ancestor.id ~= session.id and _is_sub_agent_session(ancestor) then
      return true
    end
  end
  return false
end

--- 单轮会话树节点文本，不显示内部会话 ID。
--- 子 Agent 会话不标记为「用户」（其首条消息是任务而非用户输入），改用专属前缀。
--- @param round table
--- @param session table
--- @param is_root boolean 是否为会话节点（首轮）
--- @return string
local function _round_preview(round, session, is_root)
  local parts = {}
  if _is_sub_agent_session(session) then
    if is_root then
      local name = session.metadata and session.metadata.name
      parts[#parts + 1] = "🤖 子 Agent" .. (name and name ~= "" and ("：" .. name) or "")
    elseif round.user then
      parts[#parts + 1] = "📋 任务：" .. round.user
    end
    if round.assistant then parts[#parts + 1] = "🤖 " .. round.assistant end
    return #parts > 0 and table.concat(parts, " | ") or "子 Agent"
  end
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
--- 正在聊天界面使用的会话（尚未发出首条消息）不会被删除，
--- 否则刚按 N/n 新建、正等待输入的会话会被立刻清理掉。
--- @return number 删除数量
local function _cleanup_empty_sessions()
  local delete_ids = {}
  local cs = _chat_service()
  for id, s in pairs(session_store.get_all()) do
    if _session_is_empty(s) and not (cs and cs.is_session_active(id)) then
      local branch_empty = true
      for _, d in ipairs(session_store.get_descendants(id)) do
        if not _session_is_empty(d) or (cs and cs.is_session_active(d.id)) then
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

--- ========== 工作目录分组 ==========

--- 会话绑定的工作目录（`metadata.cwd`）；无则返回空串（归入「未绑定工作目录」组）。
--- @param session table
--- @return string
local function _cwd_of(session)
  local cwd = session and session.metadata and session.metadata.cwd
  if type(cwd) == "string" then return cwd end
  return ""
end

--- 分组键（与会话 id 区分，避免折叠态串扰）。
--- @param cwd string
--- @return string
local function _group_key(cwd)
  return "group:" .. cwd
end

--- 组头文本：▾/▸ + 目录名 + 完整路径 + 会话数（无绑定目录时省略路径）。
--- @param cwd string
--- @param n number 会话数
--- @param is_open boolean
--- @return string
local function _group_label(cwd, n, is_open)
  local caret = is_open and "▾" or "▸"
  if cwd == "" then
    return ("%s 📁 （未绑定工作目录）  · %d 个会话"):format(caret, n)
  end
  local base = vim.fn.fnamemodify(cwd, ":t")
  if base == "" then base = cwd end
  return ("%s 📁 %s  %s  · %d 个会话"):format(caret, base, cwd, n)
end

--- 当前编辑器工作区目录（用于把对应分组置顶）；检测失败回退 cwd。
--- @return string
local function _editor_group_cwd()
  local ok, wr = pcall(require, "NeoAI.core.session.workspace_root")
  if ok and wr and type(wr.detect_from_context) == "function" then
    local ok2, root = pcall(wr.detect_from_context)
    if ok2 and type(root) == "string" and root ~= "" then return root end
  end
  return vim.fn.getcwd()
end

--- 展平会话树，使用 ├─、└─ 和 │ 绘制层级连接线。
--- 顶层按会话绑定工作目录（`metadata.cwd`）分组：每组先渲染一行组头（▾/▸ + 目录名 +
--- 完整路径 + 会话数），可折叠；组内根会话以 depth=1 走原有树渲染（分支/多轮次照旧缩进）。
--- @return table 数组
local function _build_flat()
  local items = {}
  local editor_cwd = _editor_group_cwd()
  -- 按根会话绑定的工作目录分组（组内保持 updated_at 倒序：get_roots 已排序）。
  -- 子 Agent 会话（及其后代）不参与分组与计数：它们在树中整体隐藏。
  local groups, order = {}, {}
  for _, root in ipairs(session_store.get_roots()) do
    if not _is_hidden_branch(root) then
      local cwd = _cwd_of(root)
      local key = _group_key(cwd)
      local g = groups[key]
      if not g then
        g = { key = key, cwd = cwd, roots = {}, max_updated = root.updated_at or 0, count = 0 }
        groups[key] = g
        order[#order + 1] = g
      end
      g.roots[#g.roots + 1] = root
      if (root.updated_at or 0) > g.max_updated then g.max_updated = root.updated_at or 0 end
    end
  end
  -- 会话数（含分支/多轮次所属会话）：按绑定 cwd 统计。
  for _, s in pairs(session_store.get_all()) do
    if not _is_hidden_branch(s) then
      local g = groups[_group_key(_cwd_of(s))]
      if g then g.count = g.count + 1 end
    end
  end
  -- 组排序等级：0=精确实等编辑器工作区；1=路径边界匹配（编辑器位于组目录之下或反之）；
  -- 2=其它。用于把「当前编辑器工作区」对应的组置顶。
  local function _rank(cwd)
    if cwd == "" or editor_cwd == "" then return 2 end
    local a = cwd:gsub("/+$", "")
    local b = editor_cwd:gsub("/+$", "")
    if a == b then return 0 end
    if a ~= "" and b:sub(1, #a + 1) == a .. "/" then return 1 end
    if b ~= "" and a:sub(1, #b + 1) == b .. "/" then return 1 end
    return 2
  end
  table.sort(order, function(x, y)
    local rx, ry = _rank(x.cwd), _rank(y.cwd)
    if rx ~= ry then return rx < ry end
    if x.max_updated ~= y.max_updated then return x.max_updated > y.max_updated end
    return tostring(x.cwd) < tostring(y.cwd)
  end)
  local function walk(session, depth, prefix, is_last)
    -- 子 Agent 会话整体隐藏（连同其整支后代）：它们是主会话的附属会话，
    -- 渲染出来会与用户分支混排，也容易被误当作可编辑的对话主线。
    local children = {}
    for _, child in ipairs(session_store.get_children(session.id)) do
      if not _is_sub_agent_session(child) then children[#children + 1] = child end
    end
    -- 空会话不渲染为节点；其子会话提升到当前层级
    if _session_is_empty(session) then
      for idx, child in ipairs(children) do
        walk(child, depth, prefix, is_last and idx == #children)
      end
      return
    end
    local is_open = state.expanded[session.id] == true
    local rounds = _conversation_rounds(session)
    local has_children = #rounds > 1 or #children > 0
    local connector = is_last and "└─ " or "├─ "
    items[#items + 1] = {
      kind = "session",
      depth = depth,
      session = session,
      is_open = is_open,
      has_children = has_children,
      prefix = prefix .. connector,
      is_last = false,
      round = nil, -- 会话节点 = 打开整个会话
      label = _round_preview(rounds[1] or {}, session, true),
    }

    if is_open then
      local entry_count = #rounds - 1 + #children
      local child_prefix = prefix .. (is_last and "   " or "│  ")
      local entry_idx = 0

      -- 首轮是会话节点本身；剩余轮次和分支会话作为其子节点连续展示。
      for round_idx = 2, #rounds do
        entry_idx = entry_idx + 1
        items[#items + 1] = {
          kind = "session",
          depth = depth + 1,
          session = session,
          is_open = false,
          has_children = false,
          prefix = child_prefix .. (entry_idx == entry_count and "└─ " or "├─ "),
          is_last = false,
          round = round_idx,
          label = _round_preview(rounds[round_idx], session, false),
        }
      end
      for _, child in ipairs(children) do
        entry_idx = entry_idx + 1
        walk(child, depth + 1, child_prefix, entry_idx == entry_count)
      end
    end
  end
  for gi, g in ipairs(order) do
    local is_last_group = (gi == #order)
    local is_open = state.expanded[g.key] ~= false -- 分组：nil=展开
    items[#items + 1] = {
      kind = "group",
      key = g.key,
      cwd = g.cwd,
      is_open = is_open,
      prefix = is_last_group and "└─ " or "├─ ",
      label = _group_label(g.cwd, g.count, is_open),
    }
    if is_open then
      local group_child_prefix = is_last_group and "   " or "│  "
      local n = #g.roots
      for ri, root in ipairs(g.roots) do
        -- 默认展开根节点
        if state.expanded[root.id] == nil then
          state.expanded[root.id] = true
        end
        walk(root, 1, group_child_prefix, ri == n)
      end
    end
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
  if not M.has_window() then return end
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
  for _, item in ipairs(state.flat_items) do
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

--- 当前光标所在项（以窗口实际光标行为准，避免鼠标点击后 selected_idx 失同步）
local function _current_item()
  if not state.win_id or not vim.api.nvim_win_is_valid(state.win_id) then return nil end
  local row = vim.api.nvim_win_get_cursor(state.win_id)[1]
  if row < 1 or row > #state.flat_items then return nil end
  return state.flat_items[row]
end

--- 移动光标
local function _move(delta)
  if #state.flat_items == 0 then return end
  state.selected_idx = math.max(1, math.min(#state.flat_items, state.selected_idx + delta))
  _update_selection()
end

--- 展开/折叠当前项（分组头或会话节点）。分组以「非显式 false」为展开态。
local function _toggle_expand(item)
  item = item or _current_item()
  if not item then return end
  if item.kind == "group" then
    state.expanded[item.key] = not (state.expanded[item.key] ~= false)
    _render()
    return
  end
  if not item.has_children then return end
  state.expanded[item.session.id] = not (state.expanded[item.session.id] == true)
  _render()
end

--- 显式展开（want=true）/折叠（want=false）当前项（供 o/O 分组键使用）。
--- @param item table|nil
--- @param want boolean
local function _set_expand(item, want)
  item = item or _current_item()
  if not item then return end
  if item.kind == "group" then
    state.expanded[item.key] = want
    _render()
    return
  end
  if not item.has_children then return end
  state.expanded[item.session.id] = want
  _render()
end

--- 沿会话树向下的单子链取出末尾会话（叶）。
--- 若会话仅有一个子会话就继续深入其唯一子会话，直到遇分裂分支（多个子会话）
--- 或末尾（无子会话）为止；无子会话时返回其自身。
--- 用于从树进入「单分支中间」的会话时顺延到该分支末尾，使当前会话落在末尾、
--- 后续新消息追加到末尾，而不是停在中间会话上。
--- 子 Agent 会话不计入单子链：它们是主会话的附属会话（`parent_id` 指向主会话），
--- 顺延时必须跳过，否则"主会话只有一个子 Agent 会话"时点主会话会误入子 Agent 会话。
--- @param session table
--- @return table 末尾会话
local function _downstream_leaf(session)
  local down = session_store.get_downstream(session.id, { skip_sub_agent = true })
  return down[#down] or session
end

--- 将给定会话打开到聊天界面（选择或新建共用）。
--- 打开后按 ui.tree.auto_close_on_select 决定是否关闭树窗口。
--- @param session table
--- @param round number|nil 选中的轮次；nil = 整个会话
local function _open_session_in_chat(session, round)
  if not session then return end
  -- 选择会话节点（未指定轮次）时顺延到单分支末尾；显式选中某轮次（回退改稿）不顺延。
  if not round then
    session = _downstream_leaf(session)
  end
  chat_view.open({ session_id = session.id, round = round })
  -- 打开会话到聊天界面后自动关闭会话树（可用 ui.tree.auto_close_on_select 关闭此行为）
  if config_store.get("ui.tree.auto_close_on_select", true) then
    M.close()
  end
end

--- 光标所在项所属分组的 cwd（分组头取自身；会话取绑定 cwd）；无则 nil。
--- @param item table|nil
--- @return string|nil
local function _item_cwd(item)
  if not item then return nil end
  local cwd = (item.kind == "group") and item.cwd or _cwd_of(item.session)
  if type(cwd) ~= "string" or cwd == "" then return nil end
  return cwd
end

--- 选择并打开聊天；作用于分组头时改为折叠/展开该组。
local function _select()
  local item = _current_item()
  if not item then return end
  if item.kind == "group" then
    _toggle_expand(item)
    return
  end
  _open_session_in_chat(item.session, item.round)
end

--- 新建子分支：创建会话后直接切到聊天界面，避免"看不见新会话"。
--- 作用于分组头或在组内时，继承光标所在分组的 cwd。
local function _new_child()
  local item = _current_item()
  local session
  if not item then
    session = session_store.create()
  elseif item.kind == "group" then
    session = session_store.create({ cwd = _item_cwd(item) })
    state.expanded[item.key] = true
  else
    session = session_store.create({ parent_id = item.session.id })
    state.expanded[item.session.id] = true
  end
  _open_session_in_chat(session)
end

--- 新建根分支：创建会话后直接切到聊天界面；继承光标所在分组的 cwd。
local function _new_root()
  local item = _current_item()
  local session = session_store.create({ cwd = _item_cwd(item) })
  _open_session_in_chat(session)
end

--- 删除光标所在轮次（会话首行对应第一轮）；分组头不可删除。
local function _delete_round()
  local item = _current_item()
  if not item then return end
  if item.kind == "group" then
    vim.notify("[NeoAI] 分组行不可删除", vim.log.levels.WARN)
    return
  end
  local round = _conversation_rounds(item.session)[item.round or 1]
  if not round then return end
  local ok, err = session_store.delete_messages(item.session.id, round.first, round.last)
  if not ok then vim.notify("[NeoAI] 删除轮次失败: " .. tostring(err), vim.log.levels.ERROR) end
  _render()
end

--- 删除该轮所属会话及全部后代分支；分组头不可删除。
local function _delete_branch()
  local item = _current_item()
  if not item then return end
  if item.kind == "group" then
    vim.notify("[NeoAI] 分组行不可删除", vim.log.levels.WARN)
    return
  end
  local _, err = session_store.delete(item.session.id, { recursive = true })
  if err then vim.notify("[NeoAI] 删除会话失败: " .. tostring(err), vim.log.levels.ERROR) end
  _render()
end

--- 设置键位
local function _set_keymaps()
  local keymap = require("NeoAI.ui.keymap")
  local actions = {
    quit = function() M.close() end,
    select = _select,
    new_child = _new_child,
    new_root = _new_root,
    delete_dialog = _delete_round,
    delete_branch = _delete_branch,
    expand = function() _set_expand(nil, true) end,
    collapse = function() _set_expand(nil, false) end,
  }
  vim.keymap.set("n", "j", function() _move(1) end, { buffer = state.buf, desc = "下移" })
  vim.keymap.set("n", "k", function() _move(-1) end, { buffer = state.buf, desc = "上移" })
  keymap.register_context("tree", actions, state.buf)

  -- 鼠标点击/滚动等移动光标时同步选中索引
  state.cursor_augroup = vim.api.nvim_create_augroup("NeoAITreeCursor", { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = state.cursor_augroup,
    buffer = state.buf,
    callback = function()
      if not state.win_id or not vim.api.nvim_win_is_valid(state.win_id) then return end
      state.selected_idx = vim.api.nvim_win_get_cursor(state.win_id)[1]
    end,
  })
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

  -- 订阅会话变更。
  -- 注意：SESSION_CREATED 在 session_store.create() 内部同步触发；直接在这里 _render()
  -- 会在"新建会话 → 打开聊天"的间隙里先跑一遍空会话清理，把刚创建的空会话删掉。
  -- 因此统一延迟到下一事件循环再渲染，让 chat 先绑定该会话（is_session_active 保护）。
  local function _schedule_render()
    vim.schedule(function()
      if M.has_window() then _render() end
    end)
  end
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.SESSION_CREATED, _schedule_render)
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.SESSION_DELETED, _schedule_render)
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.SESSION_RENAMED, _schedule_render)

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
  if state.cursor_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.cursor_augroup)
    state.cursor_augroup = nil
  end
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
