--- NeoAI 全局关闭标志模块
--- 所有模块通过此模块检查 Neovim 是否正在关闭
--- 在 VimLeavePre 中设置标志后，所有 vim.schedule 回调应检查此标志并立即返回
--- 避免在退出过程中执行 Neovim API 调用导致卡死

local M = {}

local _is_shutting_down = false

--- 设置关闭标志
function M.set()
  _is_shutting_down = true
end

--- 检查是否正在关闭
--- @return boolean
function M.is_set()
  return _is_shutting_down
end

--- 重置（测试用）
function M.reset()
  _is_shutting_down = false
end

return M
