--- NeoAI UI 层入口
--- @module NeoAI.ui
--- 编排窗口/组件/键位。对外暴露 open/close 等命令入口。

local window_manager = require("NeoAI.ui.window.manager")
local chat_view = require("NeoAI.ui.window.chat_view")
local tree_view = require("NeoAI.ui.window.tree_view")
local config_store = require("NeoAI.kernel.config_store")

local M = {}

-- ========== 私有状态 ==========

local state = {
  initialized = false,
}

-- ========== 公开 API ==========

--- 初始化 UI 层（幂等）
--- @return table ui
function M.init()
  if state.initialized then return M end
  state.initialized = true
  -- 注册审批 UI
  local approval_ui = require("NeoAI.ui.components.tool_approval")
  approval_ui.init()
  -- 启动子 Agent 监控监听
  local sub_agent_dock = require("NeoAI.ui.components.sub_agent_dock")
  sub_agent_dock.init()
  return M
end

--- 打开默认界面（按配置 default_view）
--- @return table
function M.open_default()
  M.init()
  local default_view = config_store.get("ui.default_view") or "chat"
  if default_view == "tree" then
    return M.open_tree()
  end
  return M.open_chat()
end

--- 打开聊天界面
--- @return table
function M.open_chat()
  M.init()
  -- 树窗口保持打开，不自动关闭（可同时浏览会话）
  return chat_view.open()
end

--- 打开会话树界面
--- @return table
function M.open_tree()
  M.init()
  -- 聊天窗口保持打开，不自动关闭
  return tree_view.open()
end

--- 关闭所有窗口
function M.close_all()
  chat_view.close()
  tree_view.close()
  window_manager.close_all()
end

--- 是否有窗口
--- @return boolean
function M.has_windows()
  return window_manager.has_windows()
end

--- 显示键位配置
function M.show_keymaps()
  local keymap = require("NeoAI.ui.keymap")
  keymap.show_keymaps()
end

--- 聊天窗口状态
function M.chat_status()
  chat_view.show_status()
end

--- 获取聊天视图
--- @return table
function M.get_chat_view()
  return chat_view
end

--- 获取树视图
--- @return table
function M.get_tree_view()
  return tree_view
end

--- 切换默认界面
--- @param mode string "tree"|"chat"
function M.switch_view(mode)
  config_store.set("ui.default_view", mode)
  M.close_all()
  if mode == "tree" then
    M.open_tree()
  else
    M.open_chat()
  end
end

--- 重置（测试用）
function M.reset()
  M.close_all()
  state.initialized = false
end

return M
