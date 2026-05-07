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
  if not hm then vim.notify("历史管理器未初始化", vim.log.levels.ERROR); return end
  local session = hm.get_session(session_id)
  if not session then vim.notify("会话不存在: " .. session_id, vim.log.levels.WARN); return end
  hm.set_current_session(session_id)
  vim.notify("切换到会话: " .. session.name, vim.log.levels.INFO)
  local cw = require("NeoAI.ui.window.chat_window")
  if cw.is_open() then cw.close() end
  require("NeoAI.ui").open_chat_ui(session_id, "main")
end

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO)
end

function M.initialize(config)
  if state.initialized then return true end
  state.config = config or {}
  state.initialized = true
  return true
end

function M.handle_enter()
  if not state.initialized then return end
  local sid = get_selected_session_id()
  if not sid then notify("未选中任何会话节点", vim.log.levels.WARN); return end
  open_chat_for_session(sid)
end

function M.handle_n()
  if not state.initialized then return end
  local hm = get_hm()
  if not hm then return end
  local sid = get_selected_session_id()
  if not sid then notify("请先选中一个会话节点", vim.log.levels.WARN); return end
  local session = hm.get_session(sid)
  if not session then notify("会话不存在", vim.log.levels.WARN); return end
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
  if not state.initialized then return end
  local hm = get_hm()
  if not hm then return end
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
  if not state.initialized then return end
  local hm = get_hm()
  if not hm then return end
  local sid = get_selected_session_id()
  if not sid then notify("未选中任何会话节点", vim.log.levels.WARN); return end
  local session = hm.get_session(sid)
  if not session then notify("会话不存在", vim.log.levels.WARN); return end
  hm.delete_session(sid)
  notify("已删除会话: " .. session.name)
  get_tree_window().refresh_tree()
end

function M.handle_D()
  if not state.initialized then return end
  local hm = get_hm()
  if not hm then return end
  local sid = get_selected_session_id()
  if not sid then notify("未选中任何会话节点", vim.log.levels.WARN); return end
  local session = hm.get_session(sid)
  if not session then notify("会话不存在", vim.log.levels.WARN); return end

  local bp_id = hm.find_nearest_branch_parent(sid)
  local msg = bp_id
    and ("确定要删除从分支 '" .. (hm.get_session(bp_id) or {}).name or bp_id .. "' 到 '" .. session.name .. "' 的整条对话链吗？")
    or ("确定要删除根会话 '" .. session.name .. "' 及其所有子会话吗？")
  if vim.fn.confirm(msg, "&Yes\n&No", 2) ~= 1 then return end

  if hm.delete_chain_to_branch(sid) then notify("已删除对话链") else notify("删除失败", vim.log.levels.ERROR) end
  get_tree_window().refresh_tree()
end

--- 构建连接符前缀
--- 正向遍历 flat_items，根据 is_last_branch 状态决定每层是否需要画 │
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

  -- needs_line[level] = boolean，表示该层级是否需要画 │
  local needs_line = {}

  -- 正向遍历
  for i = 1, n do
    local item = flat_items[i]
    local indent = item.indent or 0

    local parts = {}
    for level = 1, indent do
      if level < indent then
        -- 祖先层级：使用 needs_line
        if needs_line[level] then
          table.insert(parts, "│  ")
        else
          table.insert(parts, "   ")
        end
      else
        -- 自身层级：虚拟节点用 needs_line，非虚拟节点根据 is_last_branch
        if item.is_virtual then
          if needs_line[level] then
            table.insert(parts, "│  ")
          else
            table.insert(parts, "   ")
          end
        else
          if not item.is_last_branch then
            table.insert(parts, "│  ")
          else
            table.insert(parts, "   ")
          end
        end
      end
    end
    prefixes[i] = table.concat(parts)

    -- 更新 needs_line：当前节点的状态影响后续行
    if not item.is_virtual then
      needs_line[indent] = not item.is_last_branch
    end
  end

  -- 特殊处理：根虚拟节点（indent==0）
  -- 虚拟根节点画 │ 的条件：它前面最近的根节点（indent=1 的非虚拟节点）不是最后一个兄弟
  for i, item in ipairs(flat_items) do
    if item.is_virtual and item.indent == 0 then
      if i ~= 1 then
        for j = i - 1, 1, -1 do
          if not flat_items[j].is_virtual and flat_items[j].indent == 1 then
            if not flat_items[j].is_last_branch then
              prefixes[i] = "│  "
            end
            break
          end
        end
      end
    end
  end

  return prefixes
end

function M.handle_cursor_moved()
  if state.initialized then get_tree_window().update_float_window() end
end

function M.handle_key(key)
  if not state.initialized then return end
  local handlers = { ["<CR>"] = M.handle_enter, n = M.handle_n, N = M.handle_N, d = M.handle_d, D = M.handle_D }
  if handlers[key] then handlers[key]() end
end

function M.get_selected_session_id() return get_selected_session_id() end
function M.refresh_tree() get_tree_window().refresh_tree() end
function M.update_config(new_config)
  state.config = vim.tbl_extend("force", state.config, new_config or {})
end

return M
