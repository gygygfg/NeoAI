local M = {}

-- 配置存储
local config_store = {}
local change_callbacks = {}

--- 初始化配置管理器
--- @param initial_config table 初始配置
function M.initialize(initial_config)
  config_store = vim.deepcopy(initial_config or {})
  change_callbacks = {}
end

--- 获取配置值
--- @param key string 配置键（支持点号分隔）
--- @param default any 默认值
--- @return any 配置值
function M.get(key, default)
  if not key then
    return vim.deepcopy(config_store)
  end

  local parts = vim.split(key, ".", { plain = true })
  local current = config_store

  for _, part in ipairs(parts) do
    if type(current) ~= "table" then
      return default
    end
    current = current[part]
    if current == nil then
      return default
    end
  end

  return vim.deepcopy(current)
end

--- 设置配置值
--- @param key string 配置键（支持点号分隔）
--- @param value any 配置值
function M.set(key, value)
  if not key then
    error("Key is required")
  end

  local parts = vim.split(key, ".", { plain = true })
  local current = config_store

  -- 遍历到倒数第二部分
  for i = 1, #parts - 1 do
    local part = parts[i]
    if type(current[part]) ~= "table" then
      current[part] = {}
    end
    current = current[part]
  end

  -- 设置最后一部分
  local last_part = parts[#parts]
  local old_value = current[last_part]
  current[last_part] = value

  -- 触发变更回调
  M._trigger_change(key, old_value, value)
end

--- 验证配置值
--- @param key string 配置键
--- @param value any 配置值
--- @return boolean, string 是否有效，错误信息
function M.validate(key, value)
  -- 这里可以添加具体的验证逻辑
  -- 目前只做基本类型检查
  if key:match("^ai%.") then
    if key == "ai.temperature" then
      if type(value) ~= "number" or value < 0 or value > 2 then
        return false, "Temperature must be between 0 and 2"
      end
    elseif key == "ai.max_tokens" then
      if type(value) ~= "number" or value < 1 then
        return false, "Max tokens must be positive"
      end
    end
  elseif key:match("^ui%.") then
    if key == "ui.window.width" or key == "ui.window.height" then
      if type(value) ~= "number" or value < 1 then
        return false, "Window dimensions must be positive"
      end
    end
  end

  return true, nil
end

--- 注册配置变更回调
--- @param callback function 回调函数
function M.on_change(callback)
  if type(callback) ~= "function" then
    error("Callback must be a function")
  end
  table.insert(change_callbacks, callback)
end

--- 触发配置变更事件（内部使用）
--- @param key string 配置键
--- @param old_value any 旧值
--- @param new_value any 新值
function M._trigger_change(key, old_value, new_value)
  for _, callback in ipairs(change_callbacks) do
    local ok, err = pcall(callback, key, old_value, new_value)
    if not ok then
      vim.notify("Error in config change callback: " .. err, vim.log.levels.ERROR)
    end
  end
end

--- 重置配置
function M.reset()
  config_store = {}
  change_callbacks = {}
end

return M

