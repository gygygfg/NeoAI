local M = {}

-- 配置存储
local config_store = {}
local change_callbacks = {}

-- 默认配置
local default_config = {
    api_key = "",
    model = "gpt-3.5-turbo",
    temperature = 0.7,
    max_tokens = 1000,
    save_path = vim.fn.stdpath("data") .. "/neoa",
    auto_save = true,
    ui = {
        theme = "auto",
        font_size = 14,
        show_reasoning = true
    }
}

--- 初始化配置管理器
--- @param initial_config table 初始配置
function M.initialize(initial_config)
  -- 合并默认配置和用户配置
  local full_config = M.get_full_config(initial_config)
  
  -- 验证配置
  local valid, err = M.validate_config(full_config)
  if not valid then
    vim.notify("NeoAI 配置验证失败: " .. err, vim.log.levels.ERROR)
    -- 使用默认配置作为回退
    full_config = M.get_default_config()
  end
  
  config_store = vim.deepcopy(full_config)
  change_callbacks = {}
end

--- 获取默认配置
--- @return table 默认配置
function M.get_default_config()
    return vim.deepcopy(default_config)
end

--- 验证配置
--- @param config table 要验证的配置
--- @return boolean|string 验证结果，true表示有效，字符串表示错误信息
function M.validate_config(config)
    if type(config) ~= "table" then
        return "配置必须是table类型"
    end
    
    -- 基本验证规则
    local validation_rules = {
        api_key = { type = "string", required = true },
        model = { type = "string", required = true },
        temperature = { type = "number", min = 0, max = 2 },
        max_tokens = { type = "number", min = 1, max = 4096 },
        save_path = { type = "string" },
        auto_save = { type = "boolean" }
    }
    
    for key, rule in pairs(validation_rules) do
        if rule.required and config[key] == nil then
            return string.format("缺少必需的配置项: %s", key)
        end
        
        if config[key] ~= nil then
            -- 检查类型
            if rule.type and type(config[key]) ~= rule.type then
                return string.format("配置项 %s 的类型应该是 %s，但得到的是 %s", 
                    key, rule.type, type(config[key]))
            end
            
            -- 检查数值范围
            if rule.type == "number" then
                if rule.min and config[key] < rule.min then
                    return string.format("配置项 %s 的值不能小于 %s", key, rule.min)
                end
                if rule.max and config[key] > rule.max then
                    return string.format("配置项 %s 的值不能大于 %s", key, rule.max)
                end
            end
        end
    end
    
    return true
end

--- 合并配置
--- @param base_config table 基础配置
--- @param override_config table 覆盖配置
--- @return table 合并后的配置
function M.merge_configs(base_config, override_config)
    return vim.tbl_deep_extend("force", {}, base_config, override_config)
end

--- 获取完整配置（合并默认值和用户配置）
--- @param user_config table 用户配置
--- @return table 完整配置
function M.get_full_config(user_config)
    local default = M.get_default_config()
    return M.merge_configs(default, user_config or {})
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

