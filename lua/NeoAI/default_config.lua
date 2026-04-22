local M = {}

-- 默认配置
local DEFAULT_CONFIG = {
  -- AI配置
  ai = {
    base_url = "https://api.deepseek.com/chat/completions",
    api_key = os.getenv("DEEPSEEK_API_KEY") or "",
    model = "deepseek-reasoner",
    temperature = 0.7,
    max_tokens = 4096,
    stream = true,
    timeout = 60000, -- HTTP请求超时时间（毫秒）
    system_prompt = "你是一个AI编程助手，帮助用户解决编程问题。",
  },
  -- UI配置
  ui = {
    -- 默认打开的界面: 'tree' (树界面), 'chat' (聊天界面)
    default_ui = "tree",
    -- 窗口模式配置: 'float' (浮动窗口), 'tab' (新标签页), 'split' (分割窗口)
    window_mode = "tab",
    window = {
      width = 80,
      height = 20,
      border = "rounded",
    },
    colors = {
      background = "Normal",
      border = "FloatBorder",
      text = "Normal",
    },
  },
  -- 键位配置
  keymaps = {
    global = {
      open_tree = { key = "<leader>at", desc = "打开树界面" },
      open_chat = { key = "<leader>ac", desc = "打开聊天界面" },
      close_all = { key = "<leader>aq", desc = "关闭所有窗口" },
      toggle_ui = { key = "<leader>aa", desc = "切换UI显示" },
    },
    tree = {
      select = { key = "<CR>", desc = "选择节点/分支" },
      new_child = { key = "n", desc = "新建子分支" },
      new_root = { key = "N", desc = "新建根分支" },
      delete_dialog = { key = "d", desc = "删除对话" },
      delete_branch = { key = "D", desc = "删除分支" },
      expand = { key = "o", desc = "展开节点" },
      collapse = { key = "O", desc = "折叠节点" },
    },
    chat = {
      send = {
        insert = { key = "<CR>", desc = "发送消息" },
        normal = { key = "<CR>", desc = "发送消息" },
      },
      cancel = { key = "<Esc>", desc = "取消生成" },
      edit = { key = "e", desc = "编辑消息" },
      delete = { key = "dd", desc = "删除消息" },
      scroll_up = { key = "<C-u>", desc = "向上滚动" },
      scroll_down = { key = "<C-d>", desc = "向下滚动" },
      toggle_reasoning = { key = "r", desc = "切换思考过程显示" },
      newline = { key = "<C-CR>", desc = "新建行" },
      clear = { key = "<C-u>", desc = "清空输入" },
    },
    virtual_input = {
      normal_mode = { key = "<CR>", desc = "发送消息" },
      submit = { key = "<C-s>", desc = "发送消息(Ctrl+s)" },
      cancel = { key = "<Esc>", desc = "取消输入并关闭输入框" },
      clear = { key = "<C-u>", desc = "清空输入" },
    },
  },
  -- 会话配置
  session = {
    auto_save = true,
    save_path = vim.fn.stdpath("cache") .. "/sessions.json",
    max_history_per_session = 100,
  },
  -- 工具配置
  tools = {
    enabled = true,
    builtin = true,
    external = {},
  },
  -- 测试配置
  test = {
    auto_test = false, -- 是否在启动后自动运行所有测试
    delay_ms = 1500, -- 延迟毫秒数（VimEnter后1500毫秒）
  },
}

-- 模块状态
local state = {
  config = {}, -- 当前配置
  defaults = {}, -- 默认配置
  initialized = false, -- 初始化标志
}

--- 初始化配置管理器
--- @param defaults table 默认配置表
--- @return nil
function M.initialize(defaults)
  -- 如果已经初始化，直接返回
  if state.initialized then
    return
  end

  -- 设置默认配置
  state.defaults = defaults or DEFAULT_CONFIG
  -- 深度拷贝默认配置到当前配置
  state.config = vim.deepcopy(state.defaults)
  state.initialized = true

  -- 确保必需的配置字段存在
  M._ensure_required_fields()
end

--- 确保必需的配置字段存在（内部函数）
--- 这个函数会检查并确保所有必需的配置字段都存在，如果不存在则使用默认值
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

--- 获取配置值（支持点号路径）
--- @param key string 配置键，可以是嵌套键，如 "ai.api_key"
--- @param default any 默认值，当配置不存在时返回
--- @return any 配置值
function M.get(key, default)
  if not key then
    return vim.deepcopy(state.config)
  end

  -- 支持点号分隔的路径
  local keys = vim.split(key, ".", { plain = true })
  local value = state.config

  for _, k in ipairs(keys) do
    if type(value) == "table" then
      value = value[k]
    else
      return default
    end
  end

  if value == nil then
    return default
  end
  return value
end

--- 设置配置值（支持点号路径）
--- @param key string 配置键
--- @param value any 配置值
--- @return nil
function M.set(key, value)
  if not key then
    return
  end

  local keys = vim.split(key, ".", { plain = true })
  local target = state.config

  -- 遍历到倒数第二个键
  for i = 1, #keys - 1 do
    local k = keys[i]
    if not target[k] or type(target[k]) ~= "table" then
      target[k] = {}
    end
    target = target[k]
  end

  -- 设置最后一个键的值
  local last_key = keys[#keys]
  target[last_key] = value
end

--- 批量设置配置
--- @param config table 配置表，键值对形式
--- @return nil
function M.set_many(config)
  for key, value in pairs(config) do
    M.set(key, value)
  end
end

--- 获取所有配置
--- @return table 所有配置的深度拷贝
function M.get_all()
  return vim.deepcopy(state.config)
end

--- 重置配置为默认值
--- @return nil
function M.reset()
  state.config = vim.deepcopy(state.defaults)
  M._ensure_required_fields()
end

--- 验证配置的有效性
--- 检查必需字段是否存在，以及字段值是否在有效范围内
--- @return boolean, string 是否有效，错误信息
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
--- @param filepath string 文件路径
--- @return boolean, string 是否成功，错误信息
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

  if not success then
    return false, err or "未知错误"
  end
  return true, "导出成功"
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

  -- 更新配置
  if data.config then
    state.config = data.config
    M._ensure_required_fields()
  end

  return true, "导入成功"
end

--- 获取配置摘要
--- 返回一个包含配置概要信息的字符串
--- @return string 配置摘要
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
--- 通过验证函数检查配置是否完整有效
--- @return boolean 是否完整
function M.is_complete()
  local valid, _ = M.validate()
  return valid
end

--- 验证用户配置（兼容旧版本）
--- @param config table 用户配置
--- @return table 验证后的配置
function M.validate_config(config)
  if not config then
    return {}
  end

  -- 验证AI配置
  if config.ai then
    if config.ai.model and type(config.ai.model) ~= "string" then
      vim.notify("[NeoAI] ai.model must be a string. Using default.", vim.log.levels.WARN)
      config.ai.model = nil
    end

    if config.ai.api_key ~= nil and type(config.ai.api_key) ~= "string" then
      vim.notify("[NeoAI] ai.api_key must be a string. Using default.", vim.log.levels.WARN)
      config.ai.api_key = nil
    end

    if
      config.ai.temperature
      and (type(config.ai.temperature) ~= "number" or config.ai.temperature < 0 or config.ai.temperature > 2)
    then
      vim.notify("[NeoAI] ai.temperature must be a number between 0 and 2. Using default.", vim.log.levels.WARN)
      config.ai.temperature = nil
    end

    if config.ai.max_tokens and (type(config.ai.max_tokens) ~= "number" or config.ai.max_tokens < 1) then
      vim.notify("[NeoAI] ai.max_tokens must be a positive number. Using default.", vim.log.levels.WARN)
      config.ai.max_tokens = nil
    end
  end

  -- 验证UI配置
  if config.ui then
    -- 验证默认UI
    if config.ui.default_ui then
      local valid_uis = { "tree", "chat" }
      if not vim.tbl_contains(valid_uis, config.ui.default_ui) then
        vim.notify(
          string.format("[NeoAI] ui.default_ui must be one of: tree, chat. Using default.", config.ui.default_ui),
          vim.log.levels.WARN
        )
        config.ui.default_ui = nil
      end
    end

    -- 验证窗口模式
    if config.ui.window_mode then
      local valid_modes = { "float", "tab", "split" }
      if not vim.tbl_contains(valid_modes, config.ui.window_mode) then
        vim.notify(
          string.format(
            "[NeoAI] ui.window_mode must be one of: float, tab, split. Using default.",
            config.ui.window_mode
          ),
          vim.log.levels.WARN
        )
        config.ui.window_mode = nil
      end
    end

    if config.ui.window then
      if config.ui.window.width and (type(config.ui.window.width) ~= "number" or config.ui.window.width < 10) then
        vim.notify("[NeoAI] ui.window.width must be a number >= 10. Using default.", vim.log.levels.WARN)
        config.ui.window.width = nil
      end

      if config.ui.window.height and (type(config.ui.window.height) ~= "number" or config.ui.window.height < 5) then
        vim.notify("[NeoAI] ui.window.height must be a number >= 5. Using default.", vim.log.levels.WARN)
        config.ui.window.height = nil
      end
    end
  end

  -- 验证键位配置（现在在顶层）
  if config.keymaps then
    local valid_contexts = { "global", "tree", "chat", "virtual_input" }
    for context, keymap_table in pairs(config.keymaps) do
      -- 检查上下文是否有效
      if not vim.tbl_contains(valid_contexts, context) then
        vim.notify(
          string.format(
            "[NeoAI] Invalid keymap context: %s. Valid contexts are: global, tree, chat, virtual_input. Using default.",
            context
          ),
          vim.log.levels.WARN
        )
        config.keymaps[context] = nil
      else
        -- 检查键位表是否为table
        if type(keymap_table) ~= "table" then
          vim.notify(string.format("[NeoAI] keymaps.%s must be a table. Using default.", context), vim.log.levels.WARN)
          config.keymaps[context] = nil
        else
          -- 验证每个键位配置
          for action, key_config in pairs(keymap_table) do
            -- 特殊处理 send 配置（它本身是一个包含 insert 和 normal 的表）
            if action == "send" then
              if type(key_config) ~= "table" then
                vim.notify(
                  string.format(
                    "[NeoAI] keymaps.%s.send must be a table with insert and normal fields. Using default.",
                    context
                  ),
                  vim.log.levels.WARN
                )
                keymap_table[action] = nil
              else
                -- 验证 insert 配置
                if key_config.insert then
                  if type(key_config.insert) ~= "table" then
                    vim.notify(
                      string.format(
                        "[NeoAI] keymaps.%s.send.insert must be a table with key and desc fields. Using default.",
                        context
                      ),
                      vim.log.levels.WARN
                    )
                    key_config.insert = nil
                  else
                    if not key_config.insert.key or type(key_config.insert.key) ~= "string" then
                      vim.notify(
                        string.format("[NeoAI] keymaps.%s.send.insert.key must be a string. Using default.", context),
                        vim.log.levels.WARN
                      )
                      key_config.insert = nil
                    end
                  end
                end

                -- 验证 normal 配置
                if key_config.normal then
                  if type(key_config.normal) ~= "table" then
                    vim.notify(
                      string.format(
                        "[NeoAI] keymaps.%s.send.normal must be a table with key and desc fields. Using default.",
                        context
                      ),
                      vim.log.levels.WARN
                    )
                    key_config.normal = nil
                  else
                    if not key_config.normal.key or type(key_config.normal.key) ~= "string" then
                      vim.notify(
                        string.format("[NeoAI] keymaps.%s.send.normal.key must be a string. Using default.", context),
                        vim.log.levels.WARN
                      )
                      key_config.normal = nil
                    end
                  end
                end
              end
            else
              -- 处理其他普通键位配置
              if type(key_config) ~= "table" then
                vim.notify(
                  string.format(
                    "[NeoAI] keymaps.%s.%s must be a table with key and desc fields. Using default.",
                    context,
                    action
                  ),
                  vim.log.levels.WARN
                )
                keymap_table[action] = nil
              else
                -- 检查key字段是否存在且为字符串
                if not key_config.key or type(key_config.key) ~= "string" then
                  vim.notify(
                    string.format("[NeoAI] keymaps.%s.%s.key must be a string. Using default.", context, action),
                    vim.log.levels.WARN
                  )
                  keymap_table[action] = nil
                end

                -- 检查desc字段是否存在且为字符串（可选）
                if key_config.desc and type(key_config.desc) ~= "string" then
                  vim.notify(
                    string.format("[NeoAI] keymaps.%s.%s.desc must be a string. Ignoring desc.", context, action),
                    vim.log.levels.WARN
                  )
                  key_config.desc = nil
                end
              end
            end
          end
        end
      end
    end
  end

  -- 验证会话配置
  if config.session then
    if
      config.session.max_history_per_session
      and (type(config.session.max_history_per_session) ~= "number" or config.session.max_history_per_session < 1)
    then
      vim.notify(
        "[NeoAI] session.max_history_per_session must be a positive number. Using default.",
        vim.log.levels.WARN
      )
      config.session.max_history_per_session = nil
    end
  end

  return config
end

--- 合并默认配置（兼容旧版本）
--- @param config table 用户配置
--- @return table 合并后的配置
function M.merge_defaults(config)
  local result = vim.deepcopy(DEFAULT_CONFIG)

  -- 深度合并配置
  local function deep_merge(target, source)
    for k, v in pairs(source) do
      if type(v) == "table" and type(target[k]) == "table" then
        deep_merge(target[k], v)
      else
        target[k] = v
      end
    end
  end

  deep_merge(result, config or {})
  return result
end

--- 清理配置（兼容旧版本）
--- @param config table 配置
--- @return table 清理后的配置
function M.sanitize_config(config)
  -- 确保必要的路径存在
  if config.session and config.session.save_path then
    local path = config.session.save_path
    if not vim.fn.isdirectory(path) then
      vim.fn.mkdir(path, "p")
    end
  end

  -- 清理API密钥
  if config.ai and config.ai.api_key then
    -- 可以在这里添加API密钥的加密或安全处理
    -- 目前只是保留原样
    -- 这里可以添加安全处理逻辑
    -- 空块，保留用于未来扩展
    -- 占位符，避免空块警告
    local _ = config.ai.api_key
  end

  return config
end

--- 获取默认配置（兼容旧版本）
--- @return table 默认配置
function M.get_default_config()
  return vim.deepcopy(DEFAULT_CONFIG)
end

return M

