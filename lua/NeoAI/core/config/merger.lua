--- NeoAI 配置合并器
--- 职责：将用户配置与默认配置合并，生成完整配置
--- 所有合并逻辑集中在此处，default_config.lua 只负责定义默认配置

local M = {}

local logger = require("NeoAI.utils.logger")
local default_config_module = require("NeoAI.default_config")
local state_manager = require("NeoAI.core.config.state")

-- 记录新增字段提示（避免重复提示）
local _new_field_warnings = {}

--- 处理用户配置：验证 → 合并 → 清理，一步完成
--- @param user_config table 用户配置
--- @return table 处理后的完整配置
function M.process_config(user_config)
  local config = user_config or {}

  -- 1. 验证并清理用户配置中的无效字段
  config = M._validate_and_clean(config)

  -- 2. 合并到默认配置
  local result = M._merge_with_defaults(config)

  -- 3. 确保日志目录存在
  if result.log and result.log.output_path then
    local log_dir = vim.fn.fnamemodify(result.log.output_path, ":h")
    if vim.fn.isdirectory(log_dir) == 0 then
      vim.fn.mkdir(log_dir, "p")
    end
  end

  -- 4. 初始化日志器（传入合并后的日志配置）
  if result.log then
    logger.initialize(result.log)
  end

  -- 5. 确保保存目录存在
  if result.session and result.session.save_path then
    local path = result.session.save_path
    if vim.fn.isdirectory(path) == 0 then
      vim.fn.mkdir(path, "p")
    end
  end

  return result
end

--- 验证并清理用户配置中的无效字段
--- @param config table 用户配置
--- @return table 清理后的配置
function M._validate_and_clean(config)
  if not config or next(config) == nil then
    return {}
  end

  if config.ai then
    M._validate_ai_config(config.ai)
  end
  if config.ui then
    M._validate_ui_config(config.ui)
  end
  if config.keymaps then
    M._validate_keymap_config(config.keymaps)
  end
  if config.log then
    M._validate_log_config(config.log)
  end
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
  local valid_contexts = { "global", "tree", "chat" }
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

--- 验证日志配置
function M._validate_log_config(log_config)
  local valid_levels = { "DEBUG", "INFO", "WARN", "ERROR", "FATAL" }
  if log_config.level and not vim.tbl_contains(valid_levels, log_config.level:upper()) then
    vim.notify("[NeoAI] log.level must be one of: DEBUG, INFO, WARN, ERROR, FATAL. Using default.", vim.log.levels.WARN)
    log_config.level = nil
  end

  if log_config.max_file_size and (type(log_config.max_file_size) ~= "number" or log_config.max_file_size < 1024) then
    vim.notify("[NeoAI] log.max_file_size must be a number >= 1024. Using default.", vim.log.levels.WARN)
    log_config.max_file_size = nil
  end

  if log_config.max_backups and (type(log_config.max_backups) ~= "number" or log_config.max_backups < 0) then
    vim.notify("[NeoAI] log.max_backups must be a non-negative number. Using default.", vim.log.levels.WARN)
    log_config.max_backups = nil
  end

  if log_config.verbose ~= nil and type(log_config.verbose) ~= "boolean" then
    vim.notify("[NeoAI] log.verbose must be a boolean. Using default.", vim.log.levels.WARN)
    log_config.verbose = nil
  end

  if log_config.print_debug ~= nil and type(log_config.print_debug) ~= "boolean" then
    vim.notify("[NeoAI] log.print_debug must be a boolean. Using default.", vim.log.levels.WARN)
    log_config.print_debug = nil
  end
end

--- 合并用户配置到默认配置
--- 规则：
---   - 数字/字符串/布尔值：用户值覆盖默认值
---   - 表结构：保留默认表结构，递归合并内部字段
---   - 新增字段（默认中没有的）：给出提示但不添加
--- @param config table 用户配置
--- @return table 合并后的配置
function M._merge_with_defaults(config)
  local default_config = default_config_module.get_default_config()
  local result = vim.deepcopy(default_config)
  _new_field_warnings = {}

  if not config or next(config) == nil then
    return result
  end

  local function merge_known_paths(target, source, path)
    for k, v in pairs(source) do
      local current_path = (path == "") and k or (path .. "." .. k)

      -- 默认中没有该字段：提示但不添加
      if target[k] == nil then
        if not _new_field_warnings[current_path] then
          _new_field_warnings[current_path] = true
          vim.notify(
            "[NeoAI] 未知配置项: " .. current_path .. ", 已忽略",
            vim.log.levels.WARN
          )
        end
        goto continue
      end

      -- scenarios 特殊处理（AI 场景配置）
      if k == "scenarios" and type(v) == "table" and type(target[k]) == "table" then
        for scenario_name, scenario_entry in pairs(v) do
          if type(scenario_entry) == "table" and type(target[k][scenario_name]) == "table" then
            local default_entry = target[k][scenario_name]
            if scenario_entry[1] == nil or type(scenario_entry[1]) ~= "table" then
              -- 单元素表
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
              -- 数组
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
        goto continue
      end

      -- 表结构：递归合并
      if type(v) == "table" and type(target[k]) == "table" then
        merge_known_paths(target[k], v, current_path)
        goto continue
      end

      -- 数字/字符串/布尔值：用户值覆盖默认值
      target[k] = v

      ::continue::
    end
  end

  merge_known_paths(result, config, "")
  return result
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

  if provider then
    result.base_url = provider.base_url
    result.api_key = provider.api_key
    if not result.api_type then
      result.api_type = provider.api_type or "openai"
    end
  end

  for k, v in pairs(candidate) do
    result[k] = v
  end

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
--- @param scenario string 场景名称
--- @return table 候选配置列表
function M.get_scenario_candidates(scenario)
  local full_config = state_manager.get_config()
  local ai_config = full_config and full_config.ai
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
      local resolved = resolve_candidate(entry, ai_config)
      if resolved then
        table.insert(candidates, resolved)
      end
    else
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

--- 获取指定场景的第一个可用 AI 配置
--- @param scenario string 场景名称
--- @return table|nil
function M.get_preset(scenario)
  local candidates = M.get_scenario_candidates(scenario)
  return candidates[1] or nil
end

--- 获取所有可用的模型候选
--- @param scenario string 场景名称（保留参数兼容，实际忽略）
--- @return table 模型列表
function M.get_available_models(scenario)
  local full_config = state_manager.get_config()
  local ai_config = (full_config and full_config.ai) or {}
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
