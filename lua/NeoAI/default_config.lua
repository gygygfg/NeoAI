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
        send = { key = "<C-s>", desc = "发送消息" },
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
        normal_mode = { key = "<Esc>", desc = "回到正常模式" },
        submit = { key = "<CR>", desc = "发送消息" },
        cancel = { key = "<C-c>", desc = "回到正常模式" },
        clear = { key = "<C-u>", desc = "清空输入" },
      },
    },
  },
  -- 会话配置
  session = {
    auto_save = true,
    save_path = vim.fn.stdpath("data") .. "/neoai_sessions",
    max_history = 100,
  },
  -- 工具配置
  tools = {
    enabled = true,
    builtin = true,
    external = {},
  },
}

--- 验证用户配置
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
    if config.ai.api_key and type(config.ai.api_key) ~= "string" then
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

    -- 验证键位配置
    if config.ui.keymaps then
      local valid_contexts = { "global", "tree", "chat" }
      for context, keymap_table in pairs(config.ui.keymaps) do
        -- 检查上下文是否有效
        if not vim.tbl_contains(valid_contexts, context) then
          vim.notify(
            string.format(
              "[NeoAI] Invalid keymap context: %s. Valid contexts are: global, tree, chat. Using default.",
              context
            ),
            vim.log.levels.WARN
          )
          config.ui.keymaps[context] = nil
        else
          -- 检查键位表是否为table
          if type(keymap_table) ~= "table" then
            vim.notify(
              string.format("[NeoAI] keymaps.%s must be a table. Using default.", context),
              vim.log.levels.WARN
            )
            config.ui.keymaps[context] = nil
          else
            -- 验证每个键位配置
            for action, key_config in pairs(keymap_table) do
              -- 检查是否为table且包含key和desc字段
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
      config.session.max_history and (type(config.session.max_history) ~= "number" or config.session.max_history < 1)
    then
      vim.notify("[NeoAI] session.max_history must be a positive number. Using default.", vim.log.levels.WARN)
      config.session.max_history = nil
    end
  end

  return config
end

--- 合并默认配置
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

--- 清理配置
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
  end

  return config
end

--- 获取默认配置
--- @return table 默认配置
function M.get_default_config()
  return vim.deepcopy(DEFAULT_CONFIG)
end

return M
