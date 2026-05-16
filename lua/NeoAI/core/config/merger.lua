--- NeoAI 配置合并器
--- 职责：将用户配置与默认配置合并，生成完整配置
--- 合并规则：
---   1. 遍历用户传入的每个字段，检查类型是否与默认配置匹配
---   2. 对枚举值（如 window_mode、default_ui、log.level）检查是否在允许范围内
---   3. providers 为自由拓展表，不做严格类型校验
---   4. 校验通过的字段合并覆盖默认配置（部分覆盖，只修改传入的字段）
---   5. 校验失败的字段跳过，使用默认值，并 notify 提示用户

local M = {}

local logger = require("NeoAI.utils.logger")
local default_config_module = require("NeoAI.default_config")


-- ========== 闭包内私有状态 ==========
local _saved_config = nil

-- ========== 枚举值定义 ==========

local VALID_ENUMS = {
  ui = {
    default_ui = { "tree", "chat" },
    window_mode = { "float", "tab", "split" },
  },
  log = {
    level = { "DEBUG", "INFO", "WARN", "ERROR", "FATAL" },
  },
}

-- ========== 类型约束定义 ==========
-- 描述默认配置中每个字段期望的类型和约束
-- 格式：{ type = "类型", enum = {可选值}, min = 最小值, free_form = true 表示自由拓展表 }
-- nil 表示该字段无额外约束（仅检查类型）

local TYPE_CONSTRAINTS = {
  ai = {
    type = "table",
    fields = {
      default = { type = "string" },
      providers = { type = "table", free_form = true }, -- 自由拓展表，不做严格校验
      scenarios = { type = "table", free_form = true }, -- 场景配置，不做严格校验
      stream = { type = "boolean" },
      timeout = { type = "number", min = 1000 },
      reasoning_enabled = { type = "boolean" },
      system_prompt = { type = "string" },
    },
  },
  ui = {
    type = "table",
    fields = {
      default_ui = { type = "string", enum = VALID_ENUMS.ui.default_ui },
      window_mode = { type = "string", enum = VALID_ENUMS.ui.window_mode },
      window = {
        type = "table",
        fields = {
          width = { type = "number", min = 10 },
          height = { type = "number", min = 5 },
          border = { type = "string" },
        },
      },
      colors = {
        type = "table",
        fields = {
          background = { type = "string" },
          border = { type = "string" },
          text = { type = "string" },
        },
      },
      split = {
        type = "table",
        fields = {
          size = { type = "number", min = 10 },
          chat_direction = { type = "string", enum = { "left", "right" } },
          tree_direction = { type = "string", enum = { "left", "right" } },
        },
      },
      tree = {
        type = "table",
        fields = {
          foldenable = { type = "boolean" },
          foldmethod = { type = "string" },
          foldcolumn = { type = "string" },
          foldlevel = { type = "number" },
        },
      },
    },
  },
  keymaps = {
    type = "table",
    fields = {
      global = { type = "table", free_form = true },
      tree = { type = "table", free_form = true },
      chat = { type = "table", free_form = true },
    },
  },
  session = {
    type = "table",
    fields = {
      auto_save = { type = "boolean" },
      auto_naming = { type = "boolean" },
      save_path = { type = "string" },
      max_history_per_session = { type = "number", min = 1 },
    },
  },
  tools = {
    type = "table",
    fields = {
      enabled = { type = "boolean" },
      builtin = { type = "boolean" },
      external = { type = "table" },
      approval = {
        type = "table",
        fields = {
          default_auto_allow = { type = "boolean" },
          allowed_directories = { type = "table", free_form = true },
          allowed_param_groups = { type = "table", free_form = true },
          tool_overrides = { type = "table", free_form = true },
        },
      },
    },
  },
  log = {
    type = "table",
    fields = {
      level = { type = "string", enum = VALID_ENUMS.log.level },
      output_path = { type = "string", nullable = true },
      format = { type = "string" },
      max_file_size = { type = "number", min = 1024 },
      max_backups = { type = "number", min = 0 },
      verbose = { type = "boolean" },
      print_debug = { type = "boolean" },
    },
  },
  test = {
    type = "table",
    fields = {
      auto_test = { type = "boolean" },
      delay_ms = { type = "number", min = 0 },
    },
  },
}

-- ========== 工具函数 ==========

--- 格式化类型名（用于提示信息）
--- @param t string Lua 类型名
--- @return string 友好的类型描述
local function _type_name(t)
  local names = {
    string = "字符串",
    number = "数字",
    boolean = "布尔值",
    table = "表",
  }
  return names[t] or tostring(t)
end

--- 判断 table 是否为数组（连续数字索引）
--- @param t table
--- @return boolean
local function _is_array(t)
  if type(t) ~= "table" then
    return false
  end
  local count = #t
  if count == 0 then
    return false
  end
  -- 检查是否所有数字键 1..count 都存在，且无非数字键
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k > count or math.floor(k) ~= k then
      return false
    end
  end
  return true
end

--- 格式化枚举值列表（用于提示信息）
--- @param enum table 枚举值数组
--- @return string
local function _enum_str(enum)
  return table.concat(enum, ", ")
end

-- 收集所有配置错误，一次性提示
local _config_errors = {}

--- 收集配置错误（延迟提示）
--- @param path string 字段路径
--- @param msg string 错误描述
local function _collect_error(path, msg)
  table.insert(_config_errors, "配置项 " .. path .. " " .. msg .. "，已使用默认值")
end

--- 输出所有收集到的配置错误
local function _flush_errors()
  if #_config_errors == 0 then
    return
  end
  local msg = "[NeoAI] 配置存在以下问题：\n  " .. table.concat(_config_errors, "\n  ")
  vim.notify(msg, vim.log.levels.WARN)
  _config_errors = {}
end

-- ========== 校验 + 合并（整合逻辑）==========

--- 校验单个值是否符合类型约束
--- @param value any 用户传入的值
--- @param constraint table 类型约束
--- @param path string 当前路径（用于错误提示）
--- @return boolean 是否通过校验
local function _validate_value(value, constraint, path)
  if value == nil then
    return true
  end

  -- 允许为 nil 的字段
  if constraint.nullable and value == vim.NIL then
    return true
  end

  local expected_type = constraint.type

  -- 类型检查
  if type(value) ~= expected_type then
    local actual = _type_name(type(value))
    local expected = _type_name(expected_type)
    _collect_error(path, string.format("类型错误：期望 %s，实际为 %s", expected, actual))
    return false
  end

  -- 枚举值检查
  if constraint.enum and not vim.tbl_contains(constraint.enum, value) then
    _collect_error(path, string.format("值 '%s' 无效，可选值：%s", tostring(value), _enum_str(constraint.enum)))
    return false
  end

  -- 最小值检查
  if constraint.min ~= nil and type(value) == "number" and value < constraint.min then
    _collect_error(path, string.format("值 %s 过小，最小值为 %s", tostring(value), tostring(constraint.min)))
    return false
  end

  -- 最大值检查
  if constraint.max ~= nil and type(value) == "number" and value > constraint.max then
    _collect_error(path, string.format("值 %s 过大，最大值为 %s", tostring(value), tostring(constraint.max)))
    return false
  end

  return true
end

--- 递归校验并合并用户配置到默认配置
--- 校验失败的字段跳过不合并，使用默认值
--- @param default table 默认配置（将被修改）
--- @param user table 用户配置
--- @param constraint table|nil 类型约束
--- @param path string 当前路径
local function _validate_and_merge(default, user, constraint, path)
  if type(user) ~= "table" or type(default) ~= "table" then
    return
  end

  local fields = constraint and constraint.fields or nil

  for k, v in pairs(user) do
    local current_path = path .. "." .. tostring(k)

    -- 如果该字段在默认配置中不存在，提示未知字段
    if default[k] == nil then
      _collect_error(current_path, "未知配置项")
      goto continue
    end

    local child_constraint = fields and fields[k] or nil

    -- 空表保护：如果用户传入空表且默认值非空，跳过覆盖保留默认值
    -- 适用于所有分支：无约束定义、free_form、递归合并
    if type(v) == "table" and next(v) == nil and type(default[k]) == "table" and next(default[k]) ~= nil then
      goto continue
    end

    -- 无约束定义：接受用户值
    if child_constraint == nil then
      default[k] = vim.deepcopy(v)
      goto continue
    end

    -- 自由拓展表：深层合并（保留默认表中的已有字段，添加/覆盖用户传入的字段）
    if child_constraint.free_form then
      if type(v) == "table" and type(default[k]) == "table" then
        for sub_k, sub_v in pairs(v) do
          -- 空表保护：跳过空表覆盖，保留默认值
          if type(sub_v) == "table" and next(sub_v) == nil and type(default[k][sub_k]) == "table" and next(default[k][sub_k]) ~= nil then
            -- 跳过
          elseif type(sub_v) == "table" and type(default[k][sub_k]) == "table" then
            -- 判断默认子值是否为数组
            if _is_array(default[k][sub_k]) and not _is_array(sub_v) then
              -- 默认值是数组（如 scenarios.chat = { { ... } }），
              -- 用户传入的是非数组表（如 { model_name = "xxx" }），
              -- 应将用户字段合并到数组的第一个元素中
              for inner_k, inner_v in pairs(sub_v) do
                default[k][sub_k][1][inner_k] = vim.deepcopy(inner_v)
              end
            else
              -- 子值也是表：递归合并，保留默认值中未覆盖的字段
              for inner_k, inner_v in pairs(sub_v) do
                default[k][sub_k][inner_k] = vim.deepcopy(inner_v)
              end
            end
          else
            default[k][sub_k] = vim.deepcopy(sub_v)
          end
        end
      else
        default[k] = vim.deepcopy(v)
      end
      goto continue
    end

    -- 校验值
    if not _validate_value(v, child_constraint, current_path) then
      -- 校验失败：跳过该字段，使用默认值
      goto continue
    end

    -- 如果用户值和默认值都是表，递归合并
    if type(v) == "table" and type(default[k]) == "table" then
      _validate_and_merge(default[k], v, child_constraint, current_path)
      goto continue
    end

    -- 基本类型值：覆盖
    default[k] = v

    ::continue::
  end
end

-- ========== 公共 API ==========

--- 处理用户配置：校验 → 合并 → 清理，一步完成
--- @param user_config table 用户配置
--- @return table 处理后的完整配置
function M.process_config(user_config)
  local config = user_config or {}

  -- 1. 从默认配置深拷贝一份作为结果
  local default_config = default_config_module.get_default_config()
  local result = vim.deepcopy(default_config)

  -- 2. 校验并合并用户配置到结果
  if config and next(config) ~= nil then
    _validate_and_merge(result, config, { type = "table", fields = TYPE_CONSTRAINTS }, "")
  end

  -- 3. 一次性输出所有配置错误
  _flush_errors()

  -- 4. 确保日志目录存在
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

  if result.stream == nil then
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

--- 设置配置（由 core/init.lua 初始化时调用）
--- @param config table 完整配置
function M.set_config(config)
  _saved_config = config
end

--- 获取指定场景的 AI 候选列表
--- @param scenario string 场景名称
--- @param full_config table|nil 完整配置（可选，不传则使用保存的配置）
--- @return table 候选配置列表
function M.get_scenario_candidates(scenario, full_config)
  full_config = full_config or _saved_config or {}
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
--- @param full_config table|nil 完整配置（可选，不传则使用保存的配置）
--- @return table 模型列表
function M.get_available_models(scenario, full_config)
  full_config = full_config or _saved_config or {}
  local ai_config = (full_config and full_config.ai) or {}
  local providers = ai_config.providers or {}

  -- 收集场景配置中指定的模型（优先排在前面）
  local scenario_models = {}
  local seen = {}
  if scenario and ai_config.scenarios and ai_config.scenarios[scenario] then
    local entry = ai_config.scenarios[scenario]
    local candidates = {}
    if type(entry) == "table" then
      if entry[1] == nil or type(entry[1]) ~= "table" then
        candidates = { entry }
      else
        candidates = entry
      end
    end
    for _, c in ipairs(candidates) do
      local p = c.provider or "deepseek"
      local m = c.model_name or ""
      local key = p .. "/" .. m
      if not seen[key] then
        seen[key] = true
        table.insert(scenario_models, { provider = p, model_name = m })
      end
    end
  end

  local result = {}
  local index = 0

  -- 先插入场景配置中指定的模型
  for _, sm in ipairs(scenario_models) do
    local provider_def = providers[sm.provider]
    if provider_def then
      local has_key = provider_def.api_key and #provider_def.api_key > 0
      if has_key then
        index = index + 1
        table.insert(result, {
          index = index,
          provider = sm.provider,
          model_name = sm.model_name,
          api_type = provider_def.api_type or "openai",
          label = string.format("%s/%s [%s]", sm.provider, sm.model_name, provider_def.api_type or "openai"),
        })
      end
    end
  end

  -- 再插入其他所有模型（跳过已在场景配置中出现过的）
  for provider_name, provider_def in pairs(providers) do
    local has_key = provider_def and provider_def.api_key and #provider_def.api_key > 0
    if has_key and provider_def.models and type(provider_def.models) == "table" then
      for _, model_name in ipairs(provider_def.models) do
        local key = provider_name .. "/" .. model_name
        if not seen[key] then
          seen[key] = true
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
  end

  return result
end

return M
