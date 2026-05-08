--- 树界面处理器

local M = {}

local state = { initialized = false, config = nil }

local function get_hm()
  local ok, hm = pcall(require, "NeoAI.core.history.manager")
  return ok and hm.is_initialized() and hm or nil
end

local function get_tree_window()
  return require("NeoAI.ui.window.tree_window")
end

local function get_selected_session_id()
  return get_tree_window().get_selected_session_id()
end

local function open_chat_for_session(session_id)
  local hm = get_hm()
  if not hm then
    vim.notify("历史管理器未初始化", vim.log.levels.ERROR)
    return
  end
  local session = hm.get_session(session_id)
  if not session then
    vim.notify("会话不存在: " .. session_id, vim.log.levels.WARN)
    return
  end
  hm.set_current_session(session_id)
  vim.notify("切换到会话: " .. session.name, vim.log.levels.INFO)
  local cw = require("NeoAI.ui.window.chat_window")
  if cw.is_open() then
    cw.close()
  end
  require("NeoAI.ui").open_chat_ui(session_id, "main")
end

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO)
end

function M.initialize(config)
  if state.initialized then
    return true
  end
  state.config = config or {}
  state.initialized = true
  return true
end

function M.handle_enter()
  if not state.initialized then
    return
  end
  local sid = get_selected_session_id()
  if not sid then
    notify("未选中任何会话节点", vim.log.levels.WARN)
    return
  end
  open_chat_for_session(sid)
end

function M.handle_n()
  if not state.initialized then
    return
  end
  local hm = get_hm()
  if not hm then
    return
  end
  local sid = get_selected_session_id()
  if not sid then
    notify("请先选中一个会话节点", vim.log.levels.WARN)
    return
  end
  local session = hm.get_session(sid)
  if not session then
    notify("会话不存在", vim.log.levels.WARN)
    return
  end
  local core = require("NeoAI.core")
  local full_config = core.get_config() or {}
  local auto_naming = (full_config.session and full_config.session.auto_naming) ~= false
  local child_name = auto_naming and ("子会话-" .. session.name) or ""
  local new_id = hm.create_session(child_name, false, sid)
  notify("已创建子会话: " .. new_id)
  hm.set_current_session(new_id)
  open_chat_for_session(new_id)
  hm.auto_name_session(new_id)
end

function M.handle_N()
  if not state.initialized then
    return
  end
  local hm = get_hm()
  if not hm then
    return
  end
  local core = require("NeoAI.core")
  local full_config = core.get_config() or {}
  local auto_naming = (full_config.session and full_config.session.auto_naming) ~= false
  local new_id = hm.create_session(auto_naming and "新会话" or "", true, nil)
  notify("已创建根会话: " .. new_id)
  hm.set_current_session(new_id)
  open_chat_for_session(new_id)
  hm.auto_name_session(new_id)
end

function M.handle_d()
  if not state.initialized then
    return
  end
  local hm = get_hm()
  if not hm then
    return
  end
  local sid = get_selected_session_id()
  if not sid then
    notify("未选中任何会话节点", vim.log.levels.WARN)
    return
  end
  local session = hm.get_session(sid)
  if not session then
    notify("会话不存在", vim.log.levels.WARN)
    return
  end
  hm.delete_session(sid)
  notify("已删除会话: " .. session.name)
  get_tree_window().refresh_tree()
end

function M.handle_D()
  if not state.initialized then
    return
  end
  local hm = get_hm()
  if not hm then
    return
  end
  local sid = get_selected_session_id()
  if not sid then
    notify("未选中任何会话节点", vim.log.levels.WARN)
    return
  end
  local session = hm.get_session(sid)
  if not session then
    notify("会话不存在", vim.log.levels.WARN)
    return
  end

  local bp_id = hm.find_nearest_branch_parent(sid)
  local msg = bp_id
      and ("确定要删除从分支 '" .. (hm.get_session(bp_id) or {}).name or bp_id .. "' 到 '" .. session.name .. "' 的整条对话链吗？")
    or ("确定要删除根会话 '" .. session.name .. "' 及其所有子会话吗？")
  if vim.fn.confirm(msg, "&Yes\n&No", 2) ~= 1 then
    return
  end

  if hm.delete_chain_to_branch(sid) then
    notify("已删除对话链")
  else
    notify("删除失败", vim.log.levels.ERROR)
  end
  get_tree_window().refresh_tree()
end

--- 构建连接符前缀
--- 按根虚拟节点分组处理，每组内独立计算 needs_line
--- 规则：
---   1. 根虚拟节点之间用竖线连接（从最后一个虚拟根节点到第一个）
---   2. 虚拟节点自身如果后面还有同级非虚拟节点，也需要画竖线
---   3. 子节点从父级虚拟节点继承竖线状态
---   4. 非虚拟节点根据 is_last_branch 决定自身层级是否画竖线
---   5. 不更改缩进
--- @param flat_items table 平铺列表，每个元素有 indent, is_virtual, is_last_branch 字段
--- @return table<string> 每个元素对应的前缀字符串
function M.build_connectors(flat_items)
  if not flat_items or #flat_items == 0 then
    return {}
  end

  local n = #flat_items
  local prefixes = {}
  for i = 1, n do
    prefixes[i] = ""
  end

  -- 按根虚拟节点分组
  local groups = {}
  local current_group = nil
  for i = 1, n do
    local item = flat_items[i]
    if item.is_virtual and item.indent == 0 then
      current_group = { start = i, items = {} }
      table.insert(groups, current_group)
    end
    if current_group then
      table.insert(current_group.items, i)
    end
  end

  -- 处理每个组
  for g_idx, group in ipairs(groups) do
    local is_last_group = (g_idx == #groups)
    local g_items = group.items

    -- 计算组内每个 level 的 needs_line
    -- 从后往前遍历组内非虚拟节点，每个 level 由最后一个节点决定
    local needs_line = {}
    for idx = #g_items, 1, -1 do
      local i = g_items[idx]
      local item = flat_items[i]
      local indent = item.indent or 0
      if not item.is_virtual and needs_line[indent] == nil then
        needs_line[indent] = not item.is_last_branch
      end
    end

    -- 虚拟节点：如果后面有同级非虚拟节点，设置 needs_line
    for _, idx in ipairs(g_items) do
      local item = flat_items[idx]
      if item.is_virtual and item.indent > 0 then
        if needs_line[item.indent] == nil then
          local has_next = false
          for j = idx + 1, n do
            local nj = flat_items[j]
            if nj.indent < item.indent then
              break
            end
            if nj.indent == item.indent and not nj.is_virtual then
              has_next = true
              break
            end
          end
          needs_line[item.indent] = has_next
        end
      end
    end

    -- 默认值
    for level = 1, 20 do
      if needs_line[level] == nil then
        needs_line[level] = false
      end
    end

    -- 构建组内节点的前缀
    for _, idx in ipairs(g_items) do
      local item = flat_items[idx]
      local indent = item.indent or 0

      -- 非最后一个根组：所有层级强制竖线（确保子节点从父级继承竖线）
      local force_all = (not is_last_group and indent >= 1)

      local parts = {}
      for level = 1, indent do
        if force_all then
          table.insert(parts, "│  ")
        elseif needs_line[level] then
          table.insert(parts, "│  ")
        else
          table.insert(parts, "   ")
        end
      end
      prefixes[idx] = table.concat(parts)
    end
  end

  return prefixes
end

function M.handle_cursor_moved()
  if state.initialized then
    get_tree_window().update_float_window()
  end
end

function M.handle_key(key)
  if not state.initialized then
    return
  end
  local handlers = { ["<CR>"] = M.handle_enter, n = M.handle_n, N = M.handle_N, d = M.handle_d, D = M.handle_D }
  if handlers[key] then
    handlers[key]()
  end
end

function M.get_selected_session_id()
  return get_selected_session_id()
end
function M.refresh_tree()
  get_tree_window().refresh_tree()
end
function M.update_config(new_config)
  state.config = vim.tbl_extend("force", state.config, new_config or {})
end

return M
