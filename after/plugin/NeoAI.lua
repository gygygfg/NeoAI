-- NeoAI 插件自动命令
-- 此文件在插件初始化后加载

-- 退出时自动保存会话
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("NeoAIAutoSave", { clear = true }),
  callback = function()
    local backend = require("NeoAI.backend")
    if #backend.sessions > 0 then
      backend.sync_data()
    end
  end,
  desc = "退出时自动保存NeoAI会话",
})
