--- NeoAI 配置模块入口
--- 统一导出配置相关的子模块

local M = {}

M.keymap_manager = require("NeoAI.core.config.keymap_manager")
M.state = require("NeoAI.core.config.state")
M.merger = require("NeoAI.core.config.merger")

--- 初始化所有配置子模块
--- @param config table 完整配置
function M.initialize(config)
  M.keymap_manager.initialize(config)
  -- 注意：config 和 app 状态切片已在 init.lua 的 setup() 中注册
  -- 此处不再重复注册，避免冗余的 WARN 日志
end

return M
