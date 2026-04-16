-- NeoAI 配置模块
-- 负责配置的默认值、验证、合并
local M = {}

-- 默认配置
M.defaults = {
  ui = {
    default_mode = "tab",
    width = 80,
    height = 25,
    border = "rounded",
    info_border = "none",
    input_separator = "single",
    message_separator = "single",
    auto_scroll = true,
    show_timestamps = true,
    show_role_icons = true,
  },

  keymaps = {
    chat = {
      global = {
        open = { key = "<leader>nc", desc = "打开聊天" },
        new = { key = "<leader>nn", desc = "新建会话" },
      },
      normal = {
        edit_message = { key = "e", desc = "编辑消息" },
        toggle_reasoning = { key = "r", desc = "切换推理内容显示" },
        export_session = { key = "s", desc = "导出会话" },
        close = { key = "q", desc = "关闭聊天" },
        close_esc = { key = "<Esc>", desc = "关闭聊天" },
        normal_mode_send = { key = "<CR>", desc = "发送消息或编辑" },
      },
      insert = {
        send = { key = "<C-s>", desc = "发送消息" },
        close = { key = "<C-c>", desc = "关闭聊天" },
        newline = { key = "<CR>", desc = "换行" },
      },
    },
    tree = {
      normal = {
        select_or_create = { key = "<CR>", desc = "选择会话" },
        new_branch = { key = "n", desc = "新建分支" },
        new_conversation = { key = "N", desc = "新建空对话" },
        delete_turn = { key = "d", desc = "删除当前轮次" },
        delete_branch = { key = "D", desc = "删除当前分支" },
        close = { key = "q", desc = "关闭" },
        close_esc = { key = "<Esc>", desc = "关闭" },
        refresh = { key = "r", desc = "刷新树" },
        open_config = { key = "e", desc = "打开配置文件" },
      },
    },
  },

  role_icons = {
    user = "👤",
    assistant = "🤖",
    system = "⚙️",
  },

  colors = {
    user_bg = "Normal",
    assistant_bg = "Comment",
    system_bg = "ErrorMsg",
    border = "FloatBorder",
  },

  background = {
    config_dir = vim.fn.stdpath("cache") .. "/NeoAI",
    config_file = nil,
    max_history = 100,
  },

  llm = {
    api_url = "https://api.deepseek.com/chat/completions",
    api_key = os.getenv("DEEPSEEK_API_KEY") or "",
    model = "deepseek-reasoner",
    show_reasoning = true,
    stream = true,
    system_prompt = [[1. 角色与基础设定
    - 身份定义：你是一个交互式智能体，用于帮助用户处理软件工程任务。
    - 安全底线：注意不要引入安全漏洞，比如命令注入、XSS、SQL注入等OWASP十大漏洞。
    2. 核心系统规则
    - 输出风格：所有解释、注释以及与用户的交流都应使用用户指定的语言，技术术语和代码标识符保持原样。
    - 工具使用：不要在有专用工具时使用bash，使用专用工具可以提升可读性。
    - 执行任务：用户主要会让你执行软件工程任务，如修复bug、添加功能、重构代码等。
    3. 代码开发原则
    - 增量式开发：增量式进展优于"大爆炸"式开发
    - 实用主义：实用主义优于教条主义，适应项目现实
    - 代码简洁：清晰的意图优于巧妙的代码，保持代码的"无聊"和"显而易见"
    4. 安全与谨慎原则
    - 高风险操作确认：对于难以撤销、影响共享系统、有潜在风险的操作，必须先征求用户确认
    - 避免破坏性操作：遇到问题时不要用破坏性操作"绕过去"，而应找根本原因]],
    temperature = 0.7,
    max_tokens = 2048,
    top_p = 1.0,
    stream_update_interval = 100,
    timeout = 120,
    enable_function_calling = true, -- 启用 function calling
  },
}

--- 获取有效的配置文件路径
-- @param cfg 配置表
-- @return string 配置文件路径
function M.get_config_file(cfg)
  return cfg.config_file or (cfg.config_dir .. "/sessions.json")
end

--- 验证单个配置项
-- @param key 配置键
-- @param user_value 用户提供的值
-- @param default_value 默认值
-- @param path 当前路径（用于错误信息）
-- @param errors 错误收集表
-- @return boolean 是否验证通过
local function validate_config_item(key, user_value, default_value, path, errors)
  local full_path = path .. "." .. key
  local default_type = type(default_value)
  local user_type = type(user_value)

  -- 类型检查
  if default_type ~= user_type then
    table.insert(
      errors,
      string.format("配置项 %s 类型错误: 期望 %s, 实际 %s", full_path, default_type, user_type)
    )
    return false
  end

  -- 递归验证嵌套表
  if default_type == "table" then
    -- 不验证空表
    if next(default_value) == nil then
      return true
    end

    local all_valid = true
    for k, v in pairs(user_value) do
      if default_value[k] == nil then
        table.insert(errors, string.format("未知配置项: %s.%s", full_path, k))
        all_valid = false
      else
        if not validate_config_item(k, v, default_value[k], full_path, errors) then
          all_valid = false
        end
      end
    end

    -- 检查必填项
    for k, v in pairs(default_value) do
      if user_value[k] == nil then
        table.insert(errors, string.format("缺失必填配置项: %s.%s", full_path, k))
        all_valid = false
      end
    end

    return all_valid
  end

  -- 值验证（可选，根据具体需求添加）
  if key == "width" and user_value < 20 then
    table.insert(errors, string.format("配置项 %s 值过小: 最小 20, 实际 %d", full_path, user_value))
    return false
  end

  if key == "height" and user_value < 10 then
    table.insert(errors, string.format("配置项 %s 值过小: 最小 10, 实际 %d", full_path, user_value))
    return false
  end

  if key == "max_tokens" and user_value <= 0 then
    table.insert(errors, string.format("配置项 %s 值无效: 必须大于 0, 实际 %d", full_path, user_value))
    return false
  end

  if key == "temperature" and (user_value < 0 or user_value > 2) then
    table.insert(
      errors,
      string.format("配置项 %s 值超出范围: 应在 0-2 之间, 实际 %.2f", full_path, user_value)
    )
    return false
  end

  if key == "top_p" and (user_value < 0 or user_value > 1) then
    table.insert(
      errors,
      string.format("配置项 %s 值超出范围: 应在 0-1 之间, 实际 %.2f", full_path, user_value)
    )
    return false
  end

  return true
end

--- 验证用户配置并合并到默认配置
-- @param user_config 用户提供的配置
-- @return table 合并后的配置, table 错误信息列表
function M.validate_and_merge(user_config)
  local errors = {}
  local merged_config = {}
  user_config = user_config or {}

  -- 深度合并函数
  local function deep_merge(default, user)
    local result = vim.deepcopy(default)

    for key, value in pairs(user) do
      if type(value) == "table" and type(result[key]) == "table" then
        result[key] = deep_merge(result[key], value)
      else
        result[key] = value
      end
    end

    return result
  end

  -- 验证配置
  for key, default_value in pairs(M.defaults) do
    local user_value = user_config[key]

    if user_value ~= nil then
      if not validate_config_item(key, user_value, default_value, "config", errors) then
        -- 验证失败，使用默认值
        merged_config[key] = default_value
      else
        -- 验证通过，使用用户值
        if type(user_value) == "table" and type(default_value) == "table" then
          merged_config[key] = deep_merge(default_value, user_value)
        else
          merged_config[key] = user_value
        end
      end
    else
      -- 用户未提供，使用默认值
      merged_config[key] = default_value
    end
  end

  -- 检查用户配置中是否有默认配置不存在的键
  for key, _ in pairs(user_config) do
    if M.defaults[key] == nil then
      table.insert(errors, string.format("未知配置项: %s", key))
    end
  end

  -- 确保 config_file 有默认值
  if merged_config.background.config_file == nil then
    merged_config.background.config_file = M.get_config_file(merged_config.background)
  end

  return merged_config, errors
end

-- 测试函数
function M.test_config_validation()
  local test_config = {
    ui = {
      default_mode = "float",
      width = 60,
      height = 20,
      -- 测试未知键
      unknown_key = "should_warn",
    },
    llm = {
      temperature = 1.5, -- 有效值
      max_tokens = 1000,
      -- 测试类型错误
      api_url = 123, -- 应该是字符串
    },
    -- 测试未知顶级配置
    unknown_section = {
      some_key = "value",
    },
  }

  local merged, errors = M.validate_and_merge(test_config)

  print("=== 配置验证测试 ===")
  print("合并后的配置:")
  vim.print(merged)
  print("\n验证错误:")
  for _, err in ipairs(errors) do
    print("  - " .. err)
  end

  return merged, errors
end

return M
