--- 生命周期管理
--- @module NeoAI.kernel.lifecycle
--- 启动/关闭/信号处理。维护注册的清理函数列表，关闭时按序执行。

local M = {}

-- ========== 私有状态 ==========

local state = {
  bootstrapped = false,
  shutting_down = false,
  cleanup_fns = {},
}

-- ========== 公开 API ==========

--- 内核引导：初始化日志、事件常量，注册全局清理自动命令
--- @return table lifecycle
function M.bootstrap()
  if state.bootstrapped then return M end
  state.bootstrapped = true

  local config_store = require("NeoAI.kernel.config_store")
  local logger = require("NeoAI.kernel.logger")

  -- 初始化日志（从配置读取）
  logger.init(config_store.get("log"))

  -- VimLeavePre：执行所有清理函数（保存会话、关闭异步任务）
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("NeoAILifecycle", { clear = true }),
    callback = function()
      M.shutdown()
    end,
    desc = "NeoAI: 生命周期清理",
  })

  -- 延迟 100ms 后台刷新模型列表（启动不阻塞）
  local model_refresh = config_store.get("ai.model_refresh")
  if model_refresh and model_refresh.on_startup then
    vim.schedule(function()
      if state.shutting_down then return end
      local ok, model_service = pcall(require, "NeoAI.services.model_service")
      if ok and model_service and model_service.prefetch then
        pcall(model_service.prefetch)
      end
    end)
  end

  logger.info("NeoAI kernel bootstrapped")
  return M
end

--- 注册清理函数（VimLeave 时执行）
--- @param fn function
--- @return function 取消注册
function M.on_shutdown(fn)
  if state.shutting_down then return function() end end
  table.insert(state.cleanup_fns, fn)
  local removed = false
  return function()
    if removed then return end
    removed = true
    for i, f in ipairs(state.cleanup_fns) do
      if f == fn then
        table.remove(state.cleanup_fns, i)
        break
      end
    end
  end
end

--- 关闭：执行所有清理函数，逆序
function M.shutdown()
  if state.shutting_down then return M end
  state.shutting_down = true
  local logger = require("NeoAI.kernel.logger")
  local fns = state.cleanup_fns
  state.cleanup_fns = {}
  for i = #fns, 1, -1 do
    local ok, err = pcall(fns[i])
    if not ok then
      logger.warn("[lifecycle] 清理函数异常: %s", tostring(err))
    end
  end
  -- 触发插件关闭事件
  local event_bus = require("NeoAI.kernel.event_bus")
  local events = require("NeoAI.kernel.events")
  event_bus.emit(events.PLUGIN_SHUTDOWN, {})
  logger.info("NeoAI shutdown complete")
  return M
end

--- 是否已关闭
--- @return boolean
function M.is_shutting_down()
  return state.shutting_down
end

--- 重置（测试用）
function M.reset()
  state.bootstrapped = false
  state.shutting_down = false
  state.cleanup_fns = {}
end

return M
