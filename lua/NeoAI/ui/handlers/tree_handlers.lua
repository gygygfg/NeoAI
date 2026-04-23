--- 树界面处理器
--- 基于新的 history_manager

local M = {}

local state = {
  initialized = false,
  config = nil,
}

function M.initialize(config)
  if state.initialized then return true end
  state.config = config or {}
  state.initialized = true
  return true
end

local function get_hm()
  local ok, hm = pcall(require, "NeoAI.core.history_manager")
  if ok and hm.is_initialized() then return hm end
  return nil
end

function M.handle_enter()
  if not state.initialized then return end
  local tree_window = require("NeoAI.ui.window.tree_window")
  local selected_id = tree_window.get_selected_node()
  if not selected_id then
    vim.notify("未选中任何节点", vim.log.levels.WARN)
    return
  end
  if selected_id:match("^__branch_") then
    vim.notify("请选择具体的会话节点", vim.log.levels.INFO)
    return
  end
  local hm = get_hm()
  if not hm then
    vim.notify("历史管理器未初始化", vim.log.levels.ERROR)
    return
  end
  local session = hm.get_session(selected_id)
  if not session then
    vim.notify("会话不存在: " .. selected_id, vim.log.levels.WARN)
    return
  end
  hm.set_current_session(selected_id)
  vim.notify("切换到会话: " .. session.name, vim.log.levels.INFO)
  local ui = require("NeoAI.ui")
  local chat_window = require("NeoAI.ui.window.chat_window")
  if chat_window.is_open() then
    chat_window.close()
  end
  ui.open_chat_ui(selected_id, "main")
end

function M.handle_n()
  if not state.initialized then return end
  local tree_window = require("NeoAI.ui.window.tree_window")
  local selected_id = tree_window.get_selected_node()
  if not selected_id then
    vim.notify("请先选中一个会话节点", vim.log.levels.WARN)
    return
  end
  if selected_id:match("^__branch_") then
    vim.notify("请选择具体的会话节点", vim.log.levels.WARN)
    return
  end
  local hm = get_hm()
  if not hm then return end
  local session = hm.get_session(selected_id)
  if not session then
    vim.notify("会话不存在", vim.log.levels.WARN)
    return
  end
  local new_id = hm.create_session("子会话-" .. session.name, false, selected_id)
  vim.notify("已创建子会话: " .. new_id, vim.log.levels.INFO)
  -- 自动打开新创建的会话
  hm.set_current_session(new_id)
  local ui = require("NeoAI.ui")
  local chat_window = require("NeoAI.ui.window.chat_window")
  if chat_window.is_open() then
    chat_window.close()
  end
  ui.open_chat_ui(new_id, "main")
end

function M.handle_N()
  if not state.initialized then return end
  local hm = get_hm()
  if not hm then return end
  local new_id = hm.create_session("新会话", true, nil)
  vim.notify("已创建根会话: " .. new_id, vim.log.levels.INFO)
  -- 自动打开新创建的会话
  hm.set_current_session(new_id)
  local ui = require("NeoAI.ui")
  local chat_window = require("NeoAI.ui.window.chat_window")
  if chat_window.is_open() then
    chat_window.close()
  end
  ui.open_chat_ui(new_id, "main")
end

function M.handle_d()
  if not state.initialized then return end
  local tree_window = require("NeoAI.ui.window.tree_window")
  local selected_id = tree_window.get_selected_node()
  if not selected_id then
    vim.notify("未选中任何节点", vim.log.levels.WARN)
    return
  end
  if selected_id:match("^__branch_") then
    vim.notify("不能删除虚拟分支节点", vim.log.levels.WARN)
    return
  end
  local hm = get_hm()
  if not hm then return end
  local session = hm.get_session(selected_id)
  if not session then
    vim.notify("会话不存在", vim.log.levels.WARN)
    return
  end
  local confirm = vim.fn.confirm("确定要删除 '" .. session.name .. "' 吗？\n子会话也会被删除！", "&Yes\n&No", 2)
  if confirm ~= 1 then return end
  hm.delete_session(selected_id)
  vim.notify("已删除会话", vim.log.levels.INFO)
  tree_window.refresh_tree()
end

function M.handle_key(key)
  if not state.initialized then return end
  local handlers = {
    ["<CR>"] = M.handle_enter,
    ["n"] = M.handle_n,
    ["N"] = M.handle_N,
    ["d"] = M.handle_d,
  }
  local handler = handlers[key]
  if handler then handler() end
end

function M.delete_branch(node_id)
  local hm = get_hm()
  if not hm then return false, "历史管理器未初始化" end
  local ok, err = pcall(hm.delete_session, hm, node_id)
  if ok then
    local tree_win = require("NeoAI.ui.window.tree_window")
    tree_win.refresh_tree()
    return true
  end
  return false, err or "删除失败"
end

function M.create_branch(parent_id, name)
  local hm = get_hm()
  if not hm then return false end
  local new_id = hm.create_session(name or "新分支", false, parent_id)
  if new_id then
    local tree_win = require("NeoAI.ui.window.tree_window")
    tree_win.refresh_tree()
    return true
  end
  return false
end

function M.get_selected_node()
  local tree_window = require("NeoAI.ui.window.tree_window")
  return tree_window.get_selected_node()
end

function M.refresh_tree()
  local tree_window = require("NeoAI.ui.window.tree_window")
  tree_window.refresh_tree()
end

function M.update_config(new_config)
  state.config = vim.tbl_extend("force", state.config, new_config or {})
end

return M
