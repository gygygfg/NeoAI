-- NeoAI 插件自动命令
-- 此文件在插件初始化后加载
-- NeoAI 不在 VimEnter 时自动初始化或打开 UI。
-- 命令和快捷键由用户显式调用 setup() 后注册。

-- 退出时由 kernel.lifecycle 统一处理保存与清理（VimLeavePre）
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("NeoAIShutdown", { clear = true }),
  callback = function()
    local ok, lifecycle = pcall(require, "NeoAI.kernel.lifecycle")
    if ok and lifecycle then
      pcall(lifecycle.shutdown)
    end
  end,
  desc = "NeoAI: 退出时保存会话并清理资源",
})

-- ========== 会话恢复残留清理（:restart / -S 载入会话） ==========
-- 真正的注册在 `NeoAI.ui.session_cleanup.install()`（由 NeoAI.setup() 保证调用）。
-- 此处仅在 after/plugin 确实被 source 的挂载方式下补一次（幂等，clear=true）。
pcall(function() require("NeoAI.ui.session_cleanup").install() end)
