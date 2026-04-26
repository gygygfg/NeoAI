local M = {}

-- 默认配置
local DEFAULT_CONFIG = {
  -- AI配置
  -- 支持多家AI提供商，按场景（窗口命名、聊天、思考、编码、工具执行、子agent）分配不同预设
  ai = {
    -- 默认使用的预设名称
    default = "balanced",

    -- 提供商定义
    providers = {
      deepseek = {
        api_type = "openai",
        base_url = "https://api.deepseek.com/chat/completions",
        api_key = os.getenv("DEEPSEEK_API_KEY") or "",
        models = { "deepseek-v4-flash", "deepseek-v4-pro" },
      },
      openai = {
        api_type = "openai",
        base_url = "https://api.openai.com/v1/chat/completions",
        api_key = os.getenv("OPENAI_API_KEY") or "",
        models = { "gpt-4o", "gpt-4o-mini", "gpt-4-turbo", "gpt-3.5-turbo" },
      },
      anthropic = {
        api_type = "anthropic",
        base_url = "https://api.anthropic.com/v1/messages",
        api_key = os.getenv("ANTHROPIC_API_KEY") or "",
        models = { "claude-sonnet-4-20250514", "claude-3-5-sonnet-20241022", "claude-3-5-haiku-20241022" },
      },
      google = {
        api_type = "google",
        base_url = "https://generativelanguage.googleapis.com/v1beta/models",
        api_key = os.getenv("GOOGLE_API_KEY") or "",
        models = { "gemini-2.0-flash", "gemini-2.0-flash-lite", "gemini-1.5-pro", "gemini-1.5-flash" },
      },
      groq = {
        api_type = "openai",
        base_url = "https://api.groq.com/openai/v1/chat/completions",
        api_key = os.getenv("GROQ_API_KEY") or "",
        models = { "llama-3.3-70b-versatile", "llama-3.1-8b-instant", "mixtral-8x7b-32768" },
      },
      together = {
        api_type = "openai",
        base_url = "https://api.together.xyz/v1/chat/completions",
        api_key = os.getenv("TOGETHER_API_KEY") or "",
        models = { "meta-llama/Llama-3.3-70B-Instruct-Turbo", "mistralai/Mixtral-8x22B-Instruct-v0.1" },
      },
      openrouter = {
        api_type = "openai",
        base_url = "https://openrouter.ai/api/v1/chat/completions",
        api_key = os.getenv("OPENROUTER_API_KEY") or "",
        models = { "openai/gpt-4o", "anthropic/claude-sonnet-4-20250514", "google/gemini-2.0-flash-001" },
      },
      siliconflow = {
        api_type = "openai",
        base_url = "https://api.siliconflow.cn/v1/chat/completions",
        api_key = os.getenv("SILICONFLOW_API_KEY") or "",
        models = { "deepseek-ai/DeepSeek-V3", "deepseek-ai/DeepSeek-R1", "Qwen/Qwen2.5-72B-Instruct" },
      },
      moonshot = {
        api_type = "openai",
        base_url = "https://api.moonshot.cn/v1/chat/completions",
        api_key = os.getenv("MOONSHOT_API_KEY") or "",
        models = { "moonshot-v1-8k", "moonshot-v1-32k", "moonshot-v1-128k" },
      },
      zhipu = {
        api_type = "openai",
        base_url = "https://open.bigmodel.cn/api/paas/v4/chat/completions",
        api_key = os.getenv("ZHIPU_API_KEY") or "",
        models = { "glm-4-plus", "glm-4-air", "glm-4-flash" },
      },
      baidu = {
        api_type = "openai",
        base_url = "https://aip.baidubce.com/rpc/2.0/ai_custom/v1/wenxinworkshop/chat/completions",
        api_key = os.getenv("BAIDU_API_KEY") or "",
        models = { "ernie-4.0-8k", "ernie-3.5-8k" },
      },
      aliyun = {
        api_type = "openai",
        base_url = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
        api_key = os.getenv("ALIYUN_API_KEY") or "",
        models = { "qwen-plus", "qwen-turbo", "qwen-max" },
      },
      stepfun = {
        api_type = "openai",
        base_url = "https://api.stepfun.com/v1/chat/completions",
        api_key = os.getenv("STEPFUN_API_KEY") or "",
        models = { "step-2-16k", "step-1-8k", "step-1-flash" },
      },
    },

    -- 场景配置：分为窗口命名用、聊天用、思考问题用、编写代码用、执行工具用、子agent用
    -- 每个场景可指定多个 AI 候选（数组），按顺序尝试；也可只传一个（单元素表）
    -- 每个候选为 key-value 表：{ provider = '', model_name = '', ... }
    scenarios = {
      -- 窗口命名用：快速低延迟，使用非推理模型避免 reasoning_content 占用 token
      naming = {
        {
          provider = "deepseek",
          model_name = "deepseek-chat",
          temperature = 0.3,
          max_tokens = 50,
          stream = false,
          timeout = 15000,
        },
      },
      -- 聊天用：平衡速度与质量
      chat = {
        {
          provider = "deepseek",
          model_name = "deepseek-v4-flash",
          temperature = 0.7,
          max_tokens = 4096,
          stream = true,
          timeout = 60000,
        },
      },
      -- 思考问题用：深度推理
      reasoning = {
        {
          provider = "deepseek",
          model_name = "deepseek-v4-pro",
          temperature = 0.7,
          max_tokens = 8192,
          stream = true,
          timeout = 120000,
        },
      },
      -- 编写代码用：高质量代码生成
      coding = {
        {
          provider = "deepseek",
          model_name = "deepseek-v4-pro",
          temperature = 0.2,
          max_tokens = 8192,
          stream = true,
          timeout = 120000,
        },
      },
      -- 执行工具用：快速响应
      tools = {
        {
          provider = "deepseek",
          model_name = "deepseek-v4-flash",
          temperature = 0.3,
          max_tokens = 1024,
          stream = true,
          timeout = 30000,
        },
      },
      -- 子agent用
      agent = {
        {
          provider = "deepseek",
          model_name = "deepseek-v4-pro",
          temperature = 0.7,
          max_tokens = 4096,
          stream = true,
          timeout = 60000,
        },
      },
    },

    -- 全局默认值（当预设中未指定时使用）
    stream = true,
    timeout = 60000,
    system_prompt = "你是一个AI编程助手，帮助用户解决编程问题。"
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
    split = {
      -- 分割大小（列数或百分比）
      size = 80,
      -- chat 窗口分割方向: 'left' 在左侧, 'right' 在右侧
      chat_direction = "right",
      -- tree 窗口分割方向: 'left' 在左侧, 'right' 在右侧
      tree_direction = "right",
    },
    tree = {
      foldenable = false,
      foldmethod = "manual",
      foldcolumn = "0",
      foldlevel = 99,
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
        insert = { key = "<C-s>", desc = "发送消息" },
        normal = { key = "<CR>", desc = "发送消息" },
      },
      cancel = { key = "<Esc>", desc = "取消生成" },
      edit = { key = "e", desc = "编辑消息" },
      delete = { key = "dd", desc = "删除消息" },
      scroll_up = { key = "<C-u>", desc = "向上滚动" },
      scroll_down = { key = "<C-d>", desc = "向下滚动" },
      toggle_reasoning = { key = "r", desc = "切换思考过程显示" },
      switch_model = { key = "m", desc = "切换模型" },
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
    auto_naming = true, -- 是否自动命名会话
    save_path = vim.fn.stdpath("cache") .. "/NeoAI",
    max_history_per_session = 1000,
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
  if state.initialized then
    return
  end

  state.defaults = defaults or DEFAULT_CONFIG
  state.config = vim.deepcopy(state.defaults)
  state.initialized = true
end

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
    -- 检查 providers
    if state.config.ai.providers then
      for name, provider in pairs(state.config.ai.providers) do
        if type(provider) ~= "table" then
          return false, string.format("ai.providers.%s 必须是表", name)
        end
        if provider.base_url and type(provider.base_url) ~= "string" then
          return false, string.format("ai.providers.%s.base_url 必须是字符串", name)
        end
        if provider.api_key and type(provider.api_key) ~= "string" then
          return false, string.format("ai.providers.%s.api_key 必须是字符串", name)
        end
      end
    end

    -- 检查 scenarios
    if state.config.ai.scenarios then
      local valid_scenarios = { "naming", "chat", "reasoning", "coding", "tools", "agent" }
      for name, entry in pairs(state.config.ai.scenarios) do
        if not vim.tbl_contains(valid_scenarios, name) then
          return false, string.format("ai.scenarios.%s 不是有效的场景名称", name)
        end
        if type(entry) ~= "table" then
          return false, string.format("ai.scenarios.%s 必须是表", name)
        end
        -- 判断是单元素表还是数组
        if entry[1] == nil or type(entry[1]) ~= "table" then
          -- 单元素表：{ provider = '', model_name = '', ... }
          if entry.provider and type(entry.provider) ~= "string" then
            return false, string.format("ai.scenarios.%s.provider 必须是字符串", name)
          end
          if entry.model_name and type(entry.model_name) ~= "string" then
            return false, string.format("ai.scenarios.%s.model_name 必须是字符串", name)
          end
          if
            entry.temperature
            and (type(entry.temperature) ~= "number" or entry.temperature < 0 or entry.temperature > 2)
          then
            return false, string.format("ai.scenarios.%s.temperature 必须在 0 到 2 之间", name)
          end
          if entry.max_tokens and (type(entry.max_tokens) ~= "number" or entry.max_tokens <= 0) then
            return false, string.format("ai.scenarios.%s.max_tokens 必须是正数", name)
          end
        else
          -- 数组：{ { provider = '', ... }, { provider = '', ... } }
          for i, candidate in ipairs(entry) do
            if type(candidate) ~= "table" then
              return false, string.format("ai.scenarios.%s[%d] 必须是表", name, i)
            end
            if candidate.provider and type(candidate.provider) ~= "string" then
              return false, string.format("ai.scenarios.%s[%d].provider 必须是字符串", name, i)
            end
            if candidate.model_name and type(candidate.model_name) ~= "string" then
              return false, string.format("ai.scenarios.%s[%d].model_name 必须是字符串", name, i)
            end
            if
              candidate.temperature
              and (type(candidate.temperature) ~= "number" or candidate.temperature < 0 or candidate.temperature > 2)
            then
              return false, string.format("ai.scenarios.%s[%d].temperature 必须在 0 到 2 之间", name, i)
            end
            if candidate.max_tokens and (type(candidate.max_tokens) ~= "number" or candidate.max_tokens <= 0) then
              return false, string.format("ai.scenarios.%s[%d].max_tokens 必须是正数", name, i)
            end
          end
        end
      end
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

    -- 验证 split 配置
    if state.config.ui.split then
      local valid_directions = { "left", "right" }
      if
        state.config.ui.split.chat_direction
        and not vim.tbl_contains(valid_directions, state.config.ui.split.chat_direction)
      then
        return false, "ui.split.chat_direction 必须是 'left' 或 'right'"
      end
      if
        state.config.ui.split.tree_direction
        and not vim.tbl_contains(valid_directions, state.config.ui.split.tree_direction)
      then
        return false, "ui.split.tree_direction 必须是 'left' 或 'right'"
      end
      if
        state.config.ui.split.size
        and (
          type(state.config.ui.split.size) ~= "number"
          or (state.config.ui.split.size > 1 and state.config.ui.split.size < 10)
          or state.config.ui.split.size <= 0
        )
      then
        return false, "ui.split.size 必须是 >1 的列数或 0~1 之间的比例"
      end
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
  end

  return true, "导入成功"
end

--- 解析单个 AI 候选配置，合并提供商信息
--- @param candidate table 候选配置：{ provider = '', model_name = '', ... }
--- @param ai_config table ai 配置
--- @return table|nil 完整的 AI 配置
local function resolve_candidate(candidate, ai_config)
  if type(candidate) ~= "table" then
    return nil
  end

  local provider_name = candidate.provider or "deepseek"
  local model_name = candidate.model_name or ""
  local provider = ai_config.providers and ai_config.providers[provider_name]
  local result = {}

  -- 从提供商获取 base_url、api_key 和 api_type
  if provider then
    result.base_url = provider.base_url
    result.api_key = provider.api_key
    -- 如果候选没有显式指定 api_type，从提供商配置继承
    if not result.api_type then
      result.api_type = provider.api_type or "openai"
    end
  end

  -- 复制候选的所有字段
  for k, v in pairs(candidate) do
    result[k] = v
  end

  -- 从全局默认获取未设置的字段
  if not result.stream then
    result.stream = ai_config.stream
  end
  if not result.timeout then
    result.timeout = ai_config.timeout
  end
  if not result.system_prompt then
    result.system_prompt = ai_config.system_prompt
  end

  return result
end

--- 获取指定场景的 AI 候选列表
--- 每个场景可配置多个候选（数组），按顺序返回；也可只传一个（单元素表）
--- @param scenario string 场景名称："naming", "chat", "reasoning", "coding", "tools", "agent"
--- @return table 候选配置列表（每个元素为完整的 AI 配置），如果场景不存在则返回空表
function M.get_scenario_candidates(scenario)
  -- 如果 state.config 未初始化，回退到 DEFAULT_CONFIG
  local config_source = state.initialized and state.config or DEFAULT_CONFIG
  local ai_config = config_source.ai
  if not ai_config or not ai_config.scenarios then
    return {}
  end

  local entry = ai_config.scenarios[scenario]
  if not entry then
    return {}
  end

  local candidates = {}

  if type(entry) == "table" then
    if entry[1] == nil or type(entry[1]) ~= "table" then
      -- 单元素表：{ provider = '', model_name = '', ... }
      local resolved = resolve_candidate(entry, ai_config)
      if resolved then
        table.insert(candidates, resolved)
      end
    else
      -- 数组：{ { provider = '', ... }, { provider = '', ... } }
      for _, candidate in ipairs(entry) do
        local resolved = resolve_candidate(candidate, ai_config)
        if resolved then
          table.insert(candidates, resolved)
        end
      end
    end
  end

  return candidates
end

--- 获取指定场景的第一个可用 AI 配置（快捷方式）
--- @param scenario string 场景名称
--- @return table|nil 完整的 AI 配置
function M.get_preset(scenario)
  local candidates = M.get_scenario_candidates(scenario)
  return candidates[1] or nil
end

--- 获取配置摘要
--- 返回一个包含配置概要信息的字符串
--- @return string 配置摘要
function M.get_summary()
  local summary = {}

  -- 遍历所有配置
  for key, value in pairs(state.config) do
    if key == "ai" then
      summary[#summary + 1] = "ai:"
      -- 显示默认预设
      summary[#summary + 1] = "  default: " .. (value.default or "balanced")
      -- 显示提供商（脱敏 API key）
      if value.providers then
        summary[#summary + 1] = "  providers:"
        for name, provider in pairs(value.providers) do
          local key_status = (provider.api_key and #provider.api_key > 0) and "[已设置]" or "[未设置]"
          local api_type = provider.api_type or "openai"
          summary[#summary + 1] =
            string.format("    %s: %s, api_type=%s, api_key: %s", name, provider.base_url or "?", api_type, key_status)
        end
      end
      -- 显示场景配置
      if value.scenarios then
        summary[#summary + 1] = "  scenarios:"
        for name, entry in pairs(value.scenarios) do
          if type(entry) == "table" then
            if entry[1] == nil or type(entry[1]) ~= "table" then
              -- 单元素表
              summary[#summary + 1] =
                string.format("    %s: provider=%s, model=%s", name, entry.provider or "?", entry.model_name or "?")
            else
              -- 数组
              local parts = {}
              for _, c in ipairs(entry) do
                if type(c) == "table" then
                  table.insert(parts, (c.provider or "?") .. "/" .. (c.model_name or "?"))
                end
              end
              summary[#summary + 1] = string.format("    %s: [%s]", name, table.concat(parts, ", "))
            end
          end
        end
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

--- 处理用户配置：验证 → 合并 → 清理，一步完成
--- 替代旧的 validate_config + merge_defaults + sanitize_config 三步流程
--- @param user_config table 用户配置
--- @return table 处理后的完整配置
function M.process_config(user_config)
  local config = user_config or {}

  -- 1. 验证并清理用户配置中的无效字段
  config = M._validate_and_clean(config)

  -- 2. 合并到默认配置
  local result = M._merge_with_defaults(config)

  -- 3. 初始化状态管理器
  M.initialize(result)

  -- 4. 确保保存目录存在
  if result.session and result.session.save_path then
    local path = result.session.save_path
    if vim.fn.isdirectory(path) == 0 then
      vim.fn.mkdir(path, "p")
    end
  end

  return result
end

--- 验证并清理用户配置中的无效字段（内部函数）
--- @param config table 用户配置
--- @return table 清理后的配置
function M._validate_and_clean(config)
  if not config or next(config) == nil then
    return {}
  end

  -- 验证 AI 配置
  if config.ai then
    M._validate_ai_config(config.ai)
  end

  -- 验证 UI 配置
  if config.ui then
    M._validate_ui_config(config.ui)
  end

  -- 验证键位配置
  if config.keymaps then
    M._validate_keymap_config(config.keymaps)
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

--- 验证 AI 配置
function M._validate_ai_config(ai_config)
  -- 验证 providers
  if ai_config.providers then
    if type(ai_config.providers) ~= "table" then
      vim.notify("[NeoAI] ai.providers must be a table. Using default.", vim.log.levels.WARN)
      ai_config.providers = nil
      return
    end
    for name, provider in pairs(ai_config.providers) do
      if type(provider) ~= "table" then
        vim.notify(string.format("[NeoAI] ai.providers.%s must be a table. Ignoring.", name), vim.log.levels.WARN)
        ai_config.providers[name] = nil
      end
    end
  end

  -- 验证 scenarios
  if ai_config.scenarios then
    if type(ai_config.scenarios) ~= "table" then
      vim.notify("[NeoAI] ai.scenarios must be a table. Using default.", vim.log.levels.WARN)
      ai_config.scenarios = nil
      return
    end
    local valid_scenarios = { "naming", "chat", "reasoning", "coding", "tools", "agent" }
    for name, entry in pairs(ai_config.scenarios) do
      if not vim.tbl_contains(valid_scenarios, name) then
        vim.notify(
          string.format("[NeoAI] ai.scenarios.%s is not a valid scenario. Ignoring.", name),
          vim.log.levels.WARN
        )
        ai_config.scenarios[name] = nil
      elseif type(entry) ~= "table" then
        vim.notify(string.format("[NeoAI] ai.scenarios.%s must be a table. Ignoring.", name), vim.log.levels.WARN)
        ai_config.scenarios[name] = nil
      end
    end
  end
end

--- 验证 UI 配置
function M._validate_ui_config(ui_config)
  local valid_uis = { "tree", "chat" }
  if ui_config.default_ui and not vim.tbl_contains(valid_uis, ui_config.default_ui) then
    vim.notify("[NeoAI] ui.default_ui must be one of: tree, chat. Using default.", vim.log.levels.WARN)
    ui_config.default_ui = nil
  end

  local valid_modes = { "float", "tab", "split" }
  if ui_config.window_mode and not vim.tbl_contains(valid_modes, ui_config.window_mode) then
    vim.notify("[NeoAI] ui.window_mode must be one of: float, tab, split. Using default.", vim.log.levels.WARN)
    ui_config.window_mode = nil
  end

  if ui_config.window then
    if ui_config.window.width and (type(ui_config.window.width) ~= "number" or ui_config.window.width < 10) then
      vim.notify("[NeoAI] ui.window.width must be a number >= 10. Using default.", vim.log.levels.WARN)
      ui_config.window.width = nil
    end
    if ui_config.window.height and (type(ui_config.window.height) ~= "number" or ui_config.window.height < 5) then
      vim.notify("[NeoAI] ui.window.height must be a number >= 5. Using default.", vim.log.levels.WARN)
      ui_config.window.height = nil
    end
  end
end

--- 验证键位配置
function M._validate_keymap_config(keymaps)
  local valid_contexts = { "global", "tree", "chat", "virtual_input" }
  for context, keymap_table in pairs(keymaps) do
    if not vim.tbl_contains(valid_contexts, context) then
      vim.notify(string.format("[NeoAI] Invalid keymap context: %s. Using default.", context), vim.log.levels.WARN)
      keymaps[context] = nil
    elseif type(keymap_table) ~= "table" then
      vim.notify(string.format("[NeoAI] keymaps.%s must be a table. Using default.", context), vim.log.levels.WARN)
      keymaps[context] = nil
    end
  end
end

--- 合并用户配置到默认配置（内部函数）
--- @param config table 用户配置
--- @return table 合并后的配置
function M._merge_with_defaults(config)
  local result = vim.deepcopy(DEFAULT_CONFIG)

  if not config or next(config) == nil then
    return result
  end

  local function merge_known_paths(target, source, path)
    for k, v in pairs(source) do
      if target[k] == nil then
        goto continue
      end

      if k == "scenarios" and type(v) == "table" and type(target[k]) == "table" then
        for scenario_name, scenario_entry in pairs(v) do
          if type(scenario_entry) == "table" and type(target[k][scenario_name]) == "table" then
            local default_entry = target[k][scenario_name]
            if scenario_entry[1] == nil or type(scenario_entry[1]) ~= "table" then
              if default_entry[1] and type(default_entry[1]) == "table" then
                local merged = vim.deepcopy(default_entry[1])
                for field, field_val in pairs(scenario_entry) do
                  if
                    merged[field] ~= nil
                    or field == "provider"
                    or field == "model_name"
                    or field == "temperature"
                    or field == "max_tokens"
                    or field == "stream"
                    or field == "timeout"
                  then
                    merged[field] = field_val
                  end
                end
                target[k][scenario_name] = merged
              end
            else
              for i, candidate in ipairs(scenario_entry) do
                if default_entry[i] and type(default_entry[i]) == "table" then
                  local merged = vim.deepcopy(default_entry[i])
                  for field, field_val in pairs(candidate) do
                    if merged[field] ~= nil then
                      merged[field] = field_val
                    end
                  end
                  target[k][scenario_name][i] = merged
                else
                  target[k][scenario_name][i] = vim.deepcopy(candidate)
                end
              end
            end
          end
        end
      elseif type(v) == "table" and type(target[k]) == "table" then
        merge_known_paths(target[k], v, current_path)
      else
        target[k] = v
      end

      ::continue::
    end
  end

  merge_known_paths(result, config, "")
  return result
end

--- 保留旧接口兼容（内部调用 process_config）
function M.validate_config(config)
  return M._validate_and_clean(config)
end

function M.merge_defaults(config)
  return M._merge_with_defaults(config)
end

function M.sanitize_config(config)
  if config.session and config.session.save_path then
    local path = config.session.save_path
    if vim.fn.isdirectory(path) == 0 then
      vim.fn.mkdir(path, "p")
    end
  end
  return config
end

--- 获取默认配置（兼容旧版本）
--- @return table 默认配置
function M.get_default_config()
  return vim.deepcopy(DEFAULT_CONFIG)
end

--- 获取所有可用场景列表
--- 返回每个场景的名称、提供商和模型名
--- @return table 场景列表，每个元素为 { name, provider, model, label }
function M.get_available_scenarios()
  -- 如果 state.config 未初始化，回退到 DEFAULT_CONFIG
  local config_source = state.initialized and state.config or DEFAULT_CONFIG
  local ai_config = config_source.ai or {}
  local scenarios = ai_config.scenarios or {}
  local result = {}

  for name, entry in pairs(scenarios) do
    if type(entry) == "table" then
      local provider_name, model
      if entry[1] == nil or type(entry[1]) ~= "table" then
        provider_name = entry.provider or "?"
        model = entry.model_name or "?"
      else
        provider_name = entry[1].provider or "?"
        model = entry[1].model_name or "?"
      end
      table.insert(result, {
        name = name,
        provider = provider_name,
        model = model,
        label = string.format("%s (%s/%s)", name, provider_name, model),
      })
    end
  end

  local priority = { "chat", "coding", "reasoning", "tools", "agent", "naming" }
  table.sort(result, function(a, b)
    local pa, pb = 0, 0
    for i, p in ipairs(priority) do
      if a.name == p then
        pa = i
      end
      if b.name == p then
        pb = i
      end
    end
    return pa < pb
  end)

  return result
end

--- 获取所有可用的模型候选（遍历所有有 API key 的提供商的 models 字段）
--- @param scenario string 场景名称（保留参数兼容，实际忽略）
--- @return table 模型列表，每个元素为 { index, provider, model_name, label }
function M.get_available_models(scenario)
  local ai_config = (state.initialized and state.config or DEFAULT_CONFIG).ai or {}
  local providers = ai_config.providers or {}
  local result = {}
  local index = 0

  for provider_name, provider_def in pairs(providers) do
    local has_key = provider_def and provider_def.api_key and #provider_def.api_key > 0
    if has_key and provider_def.models and type(provider_def.models) == "table" then
      for _, model_name in ipairs(provider_def.models) do
        index = index + 1
        table.insert(result, {
          index = index,
          provider = provider_name,
          model_name = model_name,
          api_type = provider_def.api_type or "openai",
          label = string.format("%s/%s [%s]", provider_name, model_name, provider_def.api_type or "openai"),
        })
      end
    end
  end

  return result
end

return M
