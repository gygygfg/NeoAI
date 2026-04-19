--[[
  config_manager.lua
  Neovim AI 助手插件的配置管理模块
  
  这个模块负责管理插件的配置，包括：
  - AI API 配置
  - 用户界面配置
  - 会话管理配置
  
  使用说明：
  local config = require("config_manager")
  config.initialize(default_config)
  config.set("ai.api_key", "your-api-key")
--]]

-- 配置管理模块
local M = {}

-- 模块状态
local state = {
  config = {}, -- 当前配置
  defaults = {}, -- 默认配置
  initialized = false, -- 初始化标志
}

--- 初始化配置管理器
-- @param defaults table 默认配置表
-- @return 无返回值
function M.initialize(defaults)
  -- 如果已经初始化，直接返回
  if state.initialized then
    return
  end

  -- 设置默认配置
  state.defaults = defaults or {}
  -- 深度拷贝默认配置到当前配置
  state.config = vim.deepcopy(state.defaults)
  state.initialized = true

  -- 确保必需的配置字段存在
  M._ensure_required_fields()
end

--- 确保必需的配置字段存在（内部函数）
-- 这个函数会检查并确保所有必需的配置字段都存在，如果不存在则使用默认值
local function _ensure_required_fields()
  -- 必需字段的定义
  local required_fields = {
    ai = {
      api_key = "", -- AI API 密钥
      model = "deepseek-reasoner", -- 使用的模型
      temperature = 0.7, -- 温度参数，控制生成随机性
      max_tokens = 4096, -- 最大token数
      stream = true, -- 是否使用流式输出
    },
    ui = {
      default_ui = "tree", -- 默认UI界面：tree(树状) 或 chat(聊天)
      window_mode = "tab", -- 窗口模式：tab(标签页)、float(浮动)、split(分割)
    },
    session = {
      auto_save = true, -- 是否自动保存会话
      max_history_per_session = 100, -- 每个会话最大历史记录数
    },
  }

  -- 确保顶层字段存在
  for field, default_value in pairs(required_fields) do
    if state.config[field] == nil then
      state.config[field] = vim.deepcopy(default_value)
    else
      -- 如果字段是表，确保子字段存在
      if type(default_value) == "table" then
        for sub_field, sub_default in pairs(default_value) do
          if state.config[field][sub_field] == nil then
            state.config[field][sub_field] = sub_default
          end
        end
      end
    end
  end
end

-- 将内部函数公开给模块
M._ensure_required_fields = _ensure_required_fields

--- 获取配置值
-- @param key string 配置键，可以是嵌套键，如 "ai.api_key"
-- @param default any 默认值，当配置不存在时返回
-- @return any 配置值
function M.get(key, default)
  local value = state.config[key]
  if value == nil then
    return default
  end
  return value
end

--- 设置配置值
-- @param key string 配置键
-- @param value any 配置值
-- @return 无返回值
function M.set(key, value)
  state.config[key] = value
end

--- 批量设置配置
-- @param config table 配置表，键值对形式
-- @return 无返回值
function M.set_many(config)
  for key, value in pairs(config) do
    state.config[key] = value
  end
end

--- 获取所有配置
-- @return table 所有配置的深度拷贝
function M.get_all()
  return vim.deepcopy(state.config)
end

--- 重置配置为默认值
-- @return 无返回值
function M.reset()
  state.config = vim.deepcopy(state.defaults)
  M._ensure_required_fields()
end

--- 验证配置的有效性
-- 检查必需字段是否存在，以及字段值是否在有效范围内
-- @return boolean, string 是否有效，错误信息
function M.validate()
  -- 检查必需字段
  local required_fields = {
    "ai", -- AI 配置
    "ui", -- 用户界面配置
    "session", -- 会话配置
  }

  for _, field in ipairs(required_fields) do
    if state.config[field] == nil then
      return false, "缺少必需字段: " .. field
    end
  end

  -- 验证 AI 配置
  if state.config.ai then
    -- 检查 max_tokens
    if type(state.config.ai.max_tokens) ~= "number" or state.config.ai.max_tokens <= 0 then
      return false, "ai.max_tokens 必须是正数"
    end

    -- 检查 temperature
    if
      type(state.config.ai.temperature) ~= "number"
      or state.config.ai.temperature < 0
      or state.config.ai.temperature > 2
    then
      return false, "ai.temperature 必须在 0 到 2 之间"
    end

    -- 检查 model
    if state.config.ai.model and type(state.config.ai.model) ~= "string" then
      return false, "ai.model 必须是字符串"
    end
  end

  -- 验证 UI 配置
  if state.config.ui then
    local valid_uis = { "tree", "chat" }
    if state.config.ui.default_ui and not vim.tbl_contains(valid_uis, state.config.ui.default_ui) then
      return false, "ui.default_ui 必须是 'tree' 或 'chat'"
    end

    local valid_modes = { "float", "tab", "split" }
    if state.config.ui.window_mode and not vim.tbl_contains(valid_modes, state.config.ui.window_mode) then
      return false, "ui.window_mode 必须是 'float', 'tab' 或 'split'"
    end
  end

  -- 验证会话配置
  if state.config.session then
    if
      type(state.config.session.max_history_per_session) ~= "number"
      or state.config.session.max_history_per_session <= 0
    then
      return false, "session.max_history_per_session 必须是正数"
    end
  end

  return true, "配置验证通过"
end

--- 导出配置到文件
-- @param filepath string 文件路径
-- @return boolean, string 是否成功，错误信息
function M.export(filepath)
  -- 准备导出的数据
  local data = {
    config = state.config, -- 当前配置
    defaults = state.defaults, -- 默认配置
    export_time = os.time(), -- 导出时间
  }

  -- 将数据编码为 JSON
  local content = vim.json.encode(data)

  -- 安全地写入文件
  local success, err = pcall(function()
    local file = io.open(filepath, "w")
    if not file then
      error("无法打开文件: " .. filepath)
    end
    file:write(content)
    file:close()
  end)

  return success, err
end

--- 从文件导入配置
-- @param filepath string 文件路径
-- @return boolean, string 是否成功，错误信息
function M.import(filepath)
  local success, data = pcall(function()
    local file = io.open(filepath, "r")
    if not file then
      error("无法打开文件: " .. filepath)
    end
    local content = file:read("*a")
    file:close()
    return vim.json.decode(content)
  end)

  if not success then
    return false, data
  end

  -- 更新配置
  if data.config then
    state.config = data.config
    M._ensure_required_fields()
  end

  return true, "导入成功"
end

--- 获取配置摘要
-- 返回一个包含配置概要信息的字符串
-- @return string 配置摘要
function M.get_summary()
  local summary = {}

  -- 遍历所有配置
  for key, value in pairs(state.config) do
    if key == "ai" and value.api_key then
      -- 对 API 密钥进行脱敏处理
      if value.api_key and #value.api_key > 0 then
        summary[#summary + 1] = "ai.api_key: [已设置]"
      else
        summary[#summary + 1] = "ai.api_key: [未设置]"
      end
    else
      -- 其他配置项
      summary[#summary + 1] = tostring(key) .. ": " .. vim.inspect(value)
    end
  end

  return table.concat(summary, "\n")
end

--- 检查配置是否完整
-- 通过验证函数检查配置是否完整有效
-- @return boolean 是否完整
function M.is_complete()
  local valid, _ = M.validate()
  return valid
end

-- 导出模块
return M
