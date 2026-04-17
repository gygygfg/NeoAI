-- 配置管理模块
local M = {}

-- 模块状态
local state = {
    config = {},
    defaults = {},
    initialized = false
}

--- 初始化配置管理器
--- @param defaults table 默认配置
function M.initialize(defaults)
    if state.initialized then
        return
    end
    
    state.defaults = defaults or {}
    state.config = vim.deepcopy(state.defaults)
    state.initialized = true
    
    -- 确保必需字段存在
    M._ensure_required_fields()
end

--- 确保必需字段存在
function M._ensure_required_fields()
    -- 新的配置结构
    local required_fields = {
        ai = {
            api_key = "",
            model = "deepseek-reasoner",
            temperature = 0.7,
            max_tokens = 4096,
            stream = true
        },
        ui = {
            default_ui = "tree",
            window_mode = "tab"
        },
        session = {
            auto_save = true,
            max_history = 100
        }
    }
    
    -- 确保顶层字段存在
    for field, default_value in pairs(required_fields) do
        if state.config[field] == nil then
            state.config[field] = vim.deepcopy(default_value)
        else
            -- 确保子字段存在
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

--- 获取配置值
--- @param key string 配置键
--- @param default any 默认值
--- @return any 配置值
function M.get(key, default)
    local value = state.config[key]
    if value == nil then
        return default
    end
    return value
end

--- 设置配置值
--- @param key string 配置键
--- @param value any 配置值
function M.set(key, value)
    state.config[key] = value
end

--- 批量设置配置
--- @param config table 配置表
function M.set_many(config)
    for key, value in pairs(config) do
        state.config[key] = value
    end
end

--- 获取所有配置
--- @return table 所有配置
function M.get_all()
    return vim.deepcopy(state.config)
end

--- 重置配置为默认值
function M.reset()
    state.config = vim.deepcopy(state.defaults)
    M._ensure_required_fields()
end

--- 验证配置
--- @return boolean, string 是否有效，错误信息
function M.validate()
    -- 检查必需字段
    local required_fields = {
        "ai",
        "ui",
        "session"
    }
    
    for _, field in ipairs(required_fields) do
        if state.config[field] == nil then
            return false, "缺少必需字段: " .. field
        end
    end
    
    -- 验证AI配置
    if state.config.ai then
        if type(state.config.ai.max_tokens) ~= "number" or state.config.ai.max_tokens <= 0 then
            return false, "ai.max_tokens 必须是正数"
        end
        
        if type(state.config.ai.temperature) ~= "number" or 
           state.config.ai.temperature < 0 or state.config.ai.temperature > 2 then
            return false, "ai.temperature 必须在 0 到 2 之间"
        end
        
        if state.config.ai.model and type(state.config.ai.model) ~= "string" then
            return false, "ai.model 必须是字符串"
        end
    end
    
    -- 验证UI配置
    if state.config.ui then
        local valid_uis = {"tree", "chat"}
        if state.config.ui.default_ui and not vim.tbl_contains(valid_uis, state.config.ui.default_ui) then
            return false, "ui.default_ui 必须是 'tree' 或 'chat'"
        end
        
        local valid_modes = {"float", "tab", "split"}
        if state.config.ui.window_mode and not vim.tbl_contains(valid_modes, state.config.ui.window_mode) then
            return false, "ui.window_mode 必须是 'float', 'tab' 或 'split'"
        end
    end
    
    -- 验证会话配置
    if state.config.session then
        if type(state.config.session.max_history) ~= "number" or state.config.session.max_history <= 0 then
            return false, "session.max_history 必须是正数"
        end
    end
    
    return true
end

--- 导出配置到文件
--- @param filepath string 文件路径
--- @return boolean, string 是否成功，错误信息
function M.export(filepath)
    local data = {
        config = state.config,
        defaults = state.defaults,
        export_time = os.time()
    }
    
    local content = vim.json.encode(data)
    
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
--- @param filepath string 文件路径
--- @return boolean, string 是否成功，错误信息
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
    
    if data.config then
        state.config = data.config
        M._ensure_required_fields()
    end
    
    return true
end

--- 获取配置摘要
--- @return string 配置摘要
function M.get_summary()
    local summary = {}
    
    for key, value in pairs(state.config) do
        if key == "api_key" then
            if value and #value > 0 then
                summary[#summary + 1] = key .. ": [已设置]"
            else
                summary[#summary + 1] = key .. ": [未设置]"
            end
        else
            summary[#summary + 1] = key .. ": " .. tostring(value)
        end
    end
    
    return table.concat(summary, "\n")
end

--- 检查配置是否完整
--- @return boolean 是否完整
function M.is_complete()
    local valid, _ = M.validate()
    return valid
end

return M