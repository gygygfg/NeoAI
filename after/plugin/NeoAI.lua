-- NeoAI 插件自动命令
-- 此文件在插件初始化后加载

-- 退出时自动保存会话
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("NeoAIAutoSave", { clear = true }),
  callback = function()
    -- 安全地尝试获取核心模块
    local success, core = pcall(require, "NeoAI.core")
    if not success then
      return
    end
    
    -- 检查 core 是否已初始化（get_session_manager 在未初始化时会 error）
    local ok, session_mgr = pcall(core.get_session_manager, core)
    if ok and session_mgr then
      -- 记录日志（可选）
      vim.notify("NeoAI: 正在保存会话...", vim.log.levels.INFO)
      
      -- 注意：_save_sessions 函数目前是空实现
      -- 当实现文件保存功能后，这里会自动生效
    end
  end,
  desc = "退出时自动保存NeoAI会话",
})
