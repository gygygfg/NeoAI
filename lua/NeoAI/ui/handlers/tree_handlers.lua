--- 树界面处理器
--- 职责：光标移动时切换悬浮文本、快捷键注册/映射、指导 chat 界面获取对话链

local M = {}

local state = {
  initialized = false,
  config = nil,
}

function M.initialize(config)
  if state.initialized then
    return true
  end
  state.config = config or {}
  state.initialized = true
  return true
end

local function get_hm()
  local ok, hm = pcall(require, "NeoAI.core.history_manager")
  if ok and hm.is_initialized() then
    return hm
  end
  return nil
end

--- 获取当前选中的会话ID（从 tree_window 状态中读取）
local function get_selected_session_id()
  local tree_window = require("NeoAI.ui.window.tree_window")
  return tree_window.get_selected_session_id()
end

--- 打开聊天界面并加载指定会话的对话链
--- @param session_id string 会话ID
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
  local ui = require("NeoAI.ui")
  local chat_window = require("NeoAI.ui.window.chat_window")
  if chat_window.is_open() then
    chat_window.close()
  end
  ui.open_chat_ui(session_id, "main")
end

--- 处理 Enter 键：选中节点并打开聊天
function M.handle_enter()
  if not state.initialized then
    return
  end
  local session_id = get_selected_session_id()
  if not session_id then
    vim.notify("未选中任何会话节点", vim.log.levels.WARN)
    return
  end
  open_chat_for_session(session_id)
end

--- 处理 n 键：在选中会话下创建子会话
function M.handle_n()
  if not state.initialized then
    return
  end
  local session_id = get_selected_session_id()
  if not session_id then
    vim.notify("请先选中一个会话节点", vim.log.levels.WARN)
    return
  end
  local hm = get_hm()
  if not hm then
    return
  end
  local session = hm.get_session(session_id)
  if not session then
    vim.notify("会话不存在", vim.log.levels.WARN)
    return
  end
  local new_id = hm.create_session("子会话-" .. session.name, false, session_id)
  vim.notify("已创建子会话: " .. new_id, vim.log.levels.INFO)
  hm.set_current_session(new_id)
  open_chat_for_session(new_id)
end

--- 处理 N 键：创建新的根会话
function M.handle_N()
  if not state.initialized then
    return
  end
  local hm = get_hm()
  if not hm then
    return
  end
  local new_id = hm.create_session("新会话", true, nil)
  vim.notify("已创建根会话: " .. new_id, vim.log.levels.INFO)
  hm.set_current_session(new_id)
  open_chat_for_session(new_id)
end

--- 处理 d 键：删除会话
function M.handle_d()
  if not state.initialized then
    return
  end
  local session_id = get_selected_session_id()
  if not session_id then
    vim.notify("未选中任何会话节点", vim.log.levels.WARN)
    return
  end
  local hm = get_hm()
  if not hm then
    return
  end
  local session = hm.get_session(session_id)
  if not session then
    vim.notify("会话不存在", vim.log.levels.WARN)
    return
  end
  hm.delete_session(session_id)
  vim.notify("已删除会话: " .. session.name, vim.log.levels.INFO)
  -- 刷新树窗口
  local tree_window = require("NeoAI.ui.window.tree_window")
  tree_window.refresh_tree()
end

--- 处理 D 键：删除整条对话链
--- 找到选中节点的最近父分支节点，删除从分支点到选中节点的整条链
function M.handle_D()
  if not state.initialized then
    return
  end
  local session_id = get_selected_session_id()
  if not session_id then
    vim.notify("未选中任何会话节点", vim.log.levels.WARN)
    return
  end
  local hm = get_hm()
  if not hm then
    return
  end
  local session = hm.get_session(session_id)
  if not session then
    vim.notify("会话不存在", vim.log.levels.WARN)
    return
  end

  -- 查找最近的父分支节点
  local branch_parent_id = hm.find_nearest_branch_parent(session_id)

  -- 构建确认信息
  local confirm_msg
  if not branch_parent_id then
    -- 无父节点，删除整个根会话
    confirm_msg = "确定要删除根会话 '" .. session.name .. "' 及其所有子会话吗？"
  else
    local branch_parent = hm.get_session(branch_parent_id)
    local branch_name = branch_parent and branch_parent.name or branch_parent_id
    confirm_msg = "确定要删除从分支 '" .. branch_name .. "' 到 '" .. session.name .. "' 的整条对话链吗？"
  end

  local confirm = vim.fn.confirm(confirm_msg, "&Yes\n&No", 2)
  if confirm ~= 1 then
    return
  end

  -- 删除整条链
  local ok = hm.delete_chain_to_branch(session_id)
  if ok then
    vim.notify("已删除对话链", vim.log.levels.INFO)
  else
    vim.notify("删除失败", vim.log.levels.ERROR)
  end

  -- 刷新树窗口
  local tree_window = require("NeoAI.ui.window.tree_window")
  tree_window.refresh_tree()
end

--- 处理光标移动：更新悬浮文本
function M.handle_cursor_moved()
  if not state.initialized then
    return
  end
  local tree_window = require("NeoAI.ui.window.tree_window")
  tree_window.update_float_window()
end

--- 按键分发
function M.handle_key(key)
  if not state.initialized then
    return
  end
  local handlers = {
    ["<CR>"] = M.handle_enter,
    ["n"] = M.handle_n,
    ["N"] = M.handle_N,
    ["d"] = M.handle_d,
    ["D"] = M.handle_D,
  }
  local handler = handlers[key]
  if handler then
    handler()
  end
end

--- 获取当前选中的会话ID（供外部调用）
function M.get_selected_session_id()
  return get_selected_session_id()
end

--- 刷新树
function M.refresh_tree()
  local tree_window = require("NeoAI.ui.window.tree_window")
  tree_window.refresh_tree()
end

--- 更新配置
function M.update_config(new_config)
  state.config = vim.tbl_extend("force", state.config, new_config or {})
end

return M
