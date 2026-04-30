--- NeoAI 配置模块入口
--- 统一导出配置相关的子模块

local M = {}

M.keymap_manager = require("NeoAI.core.config.keymap_manager")
M.state = require("NeoAI.core.config.state")
M.merger = require("NeoAI.core.config.merger")

--- 初始化所有配置子模块
--- @param config table 完整配置
function M.initialize(config)
  -- keymap_manager 从 state_manager 自行读取键位配置
  M.keymap_manager.initialize(config)
  -- state_manager.initialize 幂等，已初始化则跳过
  M.state.initialize(config)
end

return M
