--- 树界面处理器

local M = {}

local state = { initialized = false, config = nil }

local function get_hm()
  local ok, hm = pcall(require, "NeoAI.core.history_manager")
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
  local new_id = hm.create_session("子会话-" .. session.name, false, sid)
  notify("已创建子会话: " .. new_id)
  hm.set_current_session(new_id)
  open_chat_for_session(new_id)
  hm.auto_name_session(new_id)
end

function M.handle_N()
  if not state.initialized then return end
  local hm = get_hm()
  if not hm then return end
  local new_id = hm.create_session("新会话", true, nil)
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
