--- NeoAI 配置模块入口
--- 统一导出配置相关的子模块

local M = {}

M.keymap_manager = require("NeoAI.core.config.keymap_manager")
M.state = require("NeoAI.core.config.state")

--- 初始化所有配置子模块
--- @param config table 完整配置
function M.initialize(config)
  M.keymap_manager.initialize(config)
  M.state.initialize(config)
end

return M
