---@module "NeoAI.ui.components.model_selector"
--- 模型选择器组件（浮动窗口菜单）
--- 从 chat_window.lua 分离，负责模型选择菜单的显示和模型切换逻辑

local M = {}

local config_merger = require("NeoAI.core.config.merger")
local Events = require("NeoAI.core.events")

local state = {
  initialized = false,
  -- 当前场景内使用的模型候选索引（1-based）
  current_model_index = 1,
  -- 外部回调（由 chat_window 注入）
  callbacks = {},
  -- 选择器是否正在运行（防止重复打开及异常关闭后无法重新打开）
  _selecting = false,
}

--- 初始化
--- @param config table|nil 配置
--- @param callbacks table|nil 回调函数表 { on_update_title, on_render_chat, on_get_window_id }
function M.initialize(config, callbacks)
  if state.initialized then return end
  state.config = config or {}
  state.callbacks = callbacks or {}
  if config and config.current_model_index then
    state.current_model_index = config.current_model_index
  end
  state.initialized = true
end

--- 更新回调函数
--- @param callbacks table
function M.update_callbacks(callbacks)
  state.callbacks = vim.tbl_extend("force", state.callbacks or {}, callbacks or {})
end

--- 获取当前使用的模型候选索引
--- @return number 当前模型索引（1-based）
function M.get_current_index()
  return state.current_model_index or 1
end

--- 设置当前模型索引
--- @param index number
function M.set_current_index(index)
  state.current_model_index = index
end

--- 获取当前使用的模型标签
--- @return string|nil 模型标签，如 "deepseek/deepseek-chat"
function M.get_current_label()
  local models = config_merger.get_available_models("chat")
  local target = models[state.current_model_index]
  if target then
    return string.format("%s/%s", target.provider or "?", target.model_name or "?")
  end
  return nil
end

--- 显示模型选择器（浮动窗口菜单）
--- 列出当前场景（chat）内所有模型候选，用户选择后切换
function M.show()
  -- 防止重复打开：如果已有选择器在运行，跳过
  if state._selecting then
    vim.notify("[NeoAI] 模型选择器已打开，请先关闭当前选择", vim.log.levels.WARN)
    return
  end

  local models = config_merger.get_available_models("chat")

  if #models == 0 then
    vim.notify("[NeoAI] 没有可用的模型（请检查 API key 配置）", vim.log.levels.WARN)
    return
  end

  -- 构建选择菜单项
  local items = {}
  for i, m in ipairs(models) do
    local indicator = (i == state.current_model_index) and "✓ " or "  "
    table.insert(items, string.format("%s%s/%s", indicator, m.provider or "?", m.model_name or "?"))
  end

  local current_label = "未知"
  local current = models[state.current_model_index]
  if current then
    current_label = string.format("%s/%s", current.provider or "?", current.model_name or "?")
  end

  state._selecting = true
  local ok, err = pcall(vim.ui.select, items, {
    prompt = "选择 AI 模型 (当前: " .. current_label .. ")",
    format_item = function(item)
      return item
    end,
  }, function(choice, idx)
    state._selecting = false
    if choice and idx and idx ~= state.current_model_index then
      M.switch_to(idx)
    end
  end)
  -- 如果 pcall 失败（如 vim.ui.select 被意外中断），清理状态
  if not ok then
    state._selecting = false
    -- vim.ui.select 异常关闭，重置状态以便下次能重新打开
    vim.schedule(function()
      -- 延迟重置，避免在事件处理中立即重新打开
      state._selecting = false
    end)
  end
end

--- 切换到当前场景内的指定模型候选
--- @param model_index number 模型候选索引（1-based）
function M.switch_to(model_index)
  if not model_index or model_index == state.current_model_index then
    return
  end

  local models = config_merger.get_available_models("chat")
  local target = models[model_index]

  if not target then
    vim.notify("[NeoAI] 无效的模型索引: " .. tostring(model_index), vim.log.levels.WARN)
    return
  end

  local old_index = state.current_model_index
  state.current_model_index = model_index

  -- 通过回调更新聊天窗口标题
  if state.callbacks.on_update_title then
    state.callbacks.on_update_title(string.format("NeoAI 聊天 [%s/%s]",
      target.provider or "?", target.model_name or "?"))
  end

  -- 通过回调重新渲染聊天内容
  if state.callbacks.on_render_chat then
    state.callbacks.on_render_chat()
  end

  -- 触发模型切换事件
  local window_id = nil
  if state.callbacks.on_get_window_id then
    window_id = state.callbacks.on_get_window_id()
  end

  vim.api.nvim_exec_autocmds("User", {
    pattern = Events.MODEL_SWITCHED,
    data = {
      old_index = old_index,
      new_index = model_index,
      provider = target.provider,
      model_name = target.model_name,
      window_id = window_id,
    },
  })

  local label = string.format("%s/%s", target.provider or "?", target.model_name or "?")
  vim.notify(string.format("[NeoAI] 已切换到模型: %s", label), vim.log.levels.INFO)
end

return M
