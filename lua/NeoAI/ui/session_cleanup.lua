--- 会话恢复残留清理
--- @module 'NeoAI.ui.session_cleanup'
---
--- 背景：`:restart` 会先 `:mksession` 存会话、`:qall` 退出、再以同 argv 重启并恢复会话。
--- `sessionoptions` 默认含 `blank,buffers`，于是 NeoAI 的聊天主 buffer / 输入框 buffer
--- 会作为 `buftype=nofile` 暂存 buffer 被一并保存、恢复。但恢复出来的只是「壳」：
--- Lua 侧窗口句柄与状态都随进程丢失，表现为残留的孤儿界面 buffer——既会占用
--- `NeoAI Chat` 等名字（导致新聊天 buffer 无法命名、跳过去时输入框不打开），
--- 又让界面看起来「没关干净」。手动 `nvim -S session.vim` 同理。
---
--- 本模块在会话载入后（SessionLoadPost）与非正常启动兜底（VimEnter +
--- `v:startreason ~= "normal"`）清理这些孤儿，使聊天界面完全关闭，用户需显式
--- `:NeoAIChat` 重开（新会话）。清理逻辑在 `ui.window.manager.cleanup_session_orphans`，
--- 此处只负责「何时触发」，懒 require 以免在启动早期加载 UI 模块。
---
--- 注册点：由 `NeoAI.setup()` 调用 `install()`。**不能只依赖 `after/plugin/NeoAI.lua`**：
--- 实测（Neovim 0.12 + `vim.opt.rtp:prepend` 挂载）`after/plugin` 目录并不会被自动
--- source，故必须在保证执行的 setup 路径上注册。幂等：重复 install 用 `clear = true`
--- 重建自动命令组，不会重复触发。

local M = {}

--- 延迟一拍执行孤儿清理（幂等）：下一拍执行以确保恢复后置动作已跑完、识别更准。
local function _schedule_cleanup()
  vim.schedule(function()
    local ok, manager = pcall(require, "NeoAI.ui.window.manager")
    if not ok or type(manager) ~= "table"
      or type(manager.cleanup_session_orphans) ~= "function" then
      return
    end
    pcall(manager.cleanup_session_orphans)
  end)
end

--- 安装会话恢复清理钩子（幂等）。
--- @return function 卸载函数（删除自动命令组；供测试/卸载使用）
function M.install()
  -- foldexpr 兜底桩：恢复出的聊天窗口 foldexpr = "v:lua.NeoAIFoldExpr()"，
  -- 而定义它的模块状态已随重启丢失；无此桩，窗口重绘求值 foldexpr 会报错。
  -- chat_view.open 会用真实实现覆盖它。
  if _G.NeoAIFoldExpr == nil then
    _G.NeoAIFoldExpr = function() return 0 end
  end

  local group = vim.api.nvim_create_augroup("NeoAISessionCleanup", { clear = true })
  vim.api.nvim_create_autocmd("SessionLoadPost", {
    group = group,
    callback = _schedule_cleanup,
    desc = "NeoAI: 清理会话恢复带入的界面残留",
  })
  vim.api.nvim_create_autocmd("VimEnter", {
    group = group,
    callback = function()
      -- 仅在非正常启动（:restart / -S 载入会话）时兜底清理；普通启动不动。
      if vim.v.startreason == "normal" then return end
      _schedule_cleanup()
    end,
    desc = "NeoAI: 重启后兜底清理界面残留",
  })

  return function()
    pcall(vim.api.nvim_del_augroup_by_name, "NeoAISessionCleanup")
  end
end

return M
