--- NeoAI UI 事件监听器
--- 职责：管理 UI 模块的事件监听，从 ui/init.lua 提取

local M = {}

local Events = require("NeoAI.core.events")

-- ========== 注册事件监听 ==========

--- 注册 UI 事件监听
--- @param state table UI 状态引用（来自 ui/init.lua）
--- @param callbacks table { refresh_tree, refresh_chat, chat_window, tree_window, get_hm }
function M.register_listeners(state, callbacks)
  local function refresh_tree()
    if state.current_ui_mode == "tree" and state.windows.tree then
      callbacks.tree_window.refresh_tree()
    end
  end

  local function refresh_chat()
    if state.current_ui_mode == "chat" and state.windows.chat then
      callbacks.chat_window.render_chat()
    end
  end

  vim.api.nvim_create_autocmd("User", {
    pattern = Events.SESSION_CREATED,
    callback = function(args)
      local data = args.data or {}
      state.current_session_id = data.session_id
      if state.current_ui_mode == "chat" and state.windows.chat then
        callbacks.chat_window.update_title((data.session or {}).name or "新会话")
      end
      refresh_tree()
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    pattern = Events.SESSION_LOADED,
    callback = function(args)
      local data = args.data or {}
      if data.latest_session_id then
        state.current_session_id = data.latest_session_id
      end
      if state.current_ui_mode == "chat" and state.windows.chat then
        local hm = callbacks.get_hm()
        if hm and hm.is_initialized() then
          local session = hm.get_session(state.current_session_id)
          if session then
            callbacks.chat_window.update_title(session.name or "加载的会话")
            callbacks.chat_window.render_chat()
          end
        end
      end
      refresh_tree()
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    pattern = Events.SESSION_DELETED,
    callback = function(args)
      if state.current_session_id == (args.data or {}).session_id then
        state.current_session_id = nil
      end
      refresh_tree()
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    pattern = Events.SESSION_CHANGED,
    callback = function(args)
      local data = args.data or {}
      state.current_session_id = data.session_id
      local session = data.session or {}
      if state.current_ui_mode == "chat" and state.windows.chat then
        callbacks.chat_window.update_title(session.name or "会话")
        callbacks.chat_window.render_chat()
      end
      refresh_tree()
    end,
  })

  for _, event in ipairs({ Events.BRANCH_CREATED, Events.BRANCH_DELETED }) do
    vim.api.nvim_create_autocmd("User", { pattern = event, callback = refresh_tree })
  end

  vim.api.nvim_create_autocmd("User", {
    pattern = Events.BRANCH_SWITCHED,
    callback = function() refresh_chat(); refresh_tree() end,
  })

  vim.api.nvim_create_autocmd("User", {
    pattern = Events.MESSAGE_ADDED,
    callback = refresh_chat,
  })

  -- 对话轮次添加后刷新树（用户在聊天中发送消息后，tree 自动更新）
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.ROUND_ADDED,
    callback = refresh_tree,
  })

  -- 会话重命名后刷新树
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.SESSION_RENAMED,
    callback = refresh_tree,
  })
end

return M
