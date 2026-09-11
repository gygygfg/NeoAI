--- 前缀管理与缓存身份一致性
--- @module NeoAI.core.agent.prefix
--- 策略对齐 deepseek-harness 的上下文缓存实践：
--- 1. 系统提示按有序段拼接（身份 -100 / persona 0 / 工具指引 100+），渲染逐字节稳定，
---    任何顺序位或文本变化都会使前缀缓存从第一个变更 token 起失效。
--- 2. 工具定义按名称字典序输出（确定性），相同工具集跨请求逐字节相同。
--- 3. 缓存身份（fingerprint）跨请求比对，身份变更即前缀缓存失效，用于诊断与统计。
--- 4. 从 provider usage 解析缓存命中/未命中 token（prompt_cache_hit_tokens / cached_tokens）。

local config_store = require("NeoAI.kernel.config_store")
local logger = require("NeoAI.kernel.logger")

local M = {}

-- LuaJIT 位操作（Lua 5.1 无 ~ 运算符）
local bit = require("bit")

-- ========== 私有常量 ==========

local ORDER_IDENTITY = -100
local ORDER_PERSONA = 0
local ORDER_TOOL_GUIDANCE = 100

-- 全局段注册表 name -> { order = number, text = string, name = string }
local _sections = {}
-- agent 级段覆盖 agent_id -> name -> section
local _agent_sections = {}

-- ========== 私有函数 ==========

--- FNV-1a 32 位稳定哈希（确定性指纹）
--- @param str string
--- @return string 8 位十六进制
local function _fnv1a(str)
  local hash = 2166136261
  for i = 1, #str do
    local byte = str:byte(i)
    hash = bit.bxor(hash, byte)
    hash = (hash * 16777619) % 4294967296
  end
  return string.format("%08x", hash)
end

--- 确定性 JSON 序列化（键按字典序排序），用于缓存身份
--- @param value any
--- @return string
local function _canonical_json(value)
  local t = type(value)
  if t == "nil" then return "null" end
  if t == "boolean" then return value and "true" or "false" end
  if t == "number" then
    if value ~= value or value == math.huge or value == -math.huge then return "null" end
    return tostring(value)
  end
  if t == "string" then
    return '"' .. value
      :gsub("\\", "\\\\")
      :gsub('"', '\\"')
      :gsub("\n", "\\n")
      :gsub("\r", "\\r")
      :gsub("\t", "\\t") .. '"'
  end
  if t == "table" then
    local is_array = #value > 0
    if is_array then
      local parts = {}
      for i = 1, #value do parts[i] = _canonical_json(value[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(value) do
      if type(k) == "string" then keys[#keys + 1] = k end
    end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
      parts[#parts + 1] = _canonical_json(k) .. ":" .. _canonical_json(value[k])
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end

--- 获取配置（允许 opts 覆盖）
--- @param opts table|nil
--- @return table
local function _cfg(opts)
  local cfg = vim.deepcopy(config_store.get("ai.context_cache") or {})
  if opts and opts.context_cache then
    for k, v in pairs(opts.context_cache) do cfg[k] = v end
  end
  return cfg
end

-- ========== 系统提示段 ==========

--- 注册一个系统提示段（全局）
--- @param name string 段名（同层唯一）
--- @param order number 顺序位（-100 身份 / 0 persona / 100+ 工具指引）
--- @param text string|function 段文本（function 则每次渲染时求值）
function M.register_section(name, order, text)
  if _sections[name] then
    error('prompt section "' .. name .. '" is already registered')
  end
  if type(order) ~= "number" or order ~= order then
    error('prompt section "' .. name .. '" order must be a finite number')
  end
  _sections[name] = { name = name, order = order, text = text }
  return function()
    _sections[name] = nil
  end
end

--- 注册一个 agent 级系统提示段（遮蔽同名全局段）
--- @param agent table
--- @param name string
--- @param order number
--- @param text string|function
function M.register_agent_section(agent, name, order, text)
  _agent_sections[agent.id] = _agent_sections[agent.id] or {}
  if _agent_sections[agent.id][name] then
    error('prompt section "' .. name .. '" is already registered in this scope')
  end
  _agent_sections[agent.id][name] = { name = name, order = order, text = text }
  return function()
    if _agent_sections[agent.id] then
      _agent_sections[agent.id][name] = nil
    end
  end
end

--- 清空段注册（测试用）
function M.reset_sections()
  _sections = {}
  _agent_sections = {}
end

--- 渲染有序系统提示
--- @param agent table|nil
--- @param opts table|nil { context_cache? }
--- @return string
function M.build_system_prompt(agent, opts)
  local cfg = _cfg(opts)
  local sections = {}

  if cfg.include_identity ~= false then
    sections[#sections + 1] = {
      name = "harness:identity",
      order = ORDER_IDENTITY,
      text = cfg.identity or "你是一个由 NeoAI 驱动的 AI 编程助手。",
    }
  end

  local persona = (agent and agent.config and agent.config.system_prompt)
    or config_store.get("ai.system_prompt")
  if persona and persona ~= "" then
    sections[#sections + 1] = { name = "deployment:persona", order = ORDER_PERSONA, text = persona }
  end

  local merged = {}
  for name, s in pairs(_sections) do merged[name] = s end
  if agent then
    local scoped = _agent_sections[agent.id]
    if scoped then
      for name, s in pairs(scoped) do merged[name] = s end
    end
  end
  for _, s in pairs(merged) do
    sections[#sections + 1] = s
  end

  table.sort(sections, function(a, b)
    if a.order ~= b.order then return a.order < b.order end
    return a.name < b.name
  end)

  local parts = {}
  for _, s in ipairs(sections) do
    local text = type(s.text) == "function" and s.text() or s.text
    if text and text ~= "" then
      parts[#parts + 1] = text
    end
  end
  return table.concat(parts, "\n\n")
end

-- ========== 缓存身份 ==========

--- 计算请求前缀的缓存身份指纹
--- @param system_text string 系统提示文本（逐字节）
--- @param tool_defs table 工具定义数组（已确定性排序）
--- @return string 8 位十六进制指纹
function M.prefix_id(system_text, tool_defs)
  local parts = { "S\n", system_text or "" }
  for _, td in ipairs(tool_defs or {}) do
    local fn = td and td["function"] or {}
    parts[#parts + 1] = "\nT\n" .. (fn.name or "")
    parts[#parts + 1] = "\nD\n" .. (fn.description or "")
    if fn.parameters then
      parts[#parts + 1] = "\nP\n" .. _canonical_json(fn.parameters)
    end
  end
  return _fnv1a(table.concat(parts))
end

--- 确定性 JSON 序列化（供 guard 等模块做参数指纹复用）
--- @param value any
--- @return string
M.canonical_json = _canonical_json

--- 校验并记录 Agent 的缓存身份
--- @param agent table
--- @param messages table API 消息数组（首条为 system）
--- @param tool_defs table 工具定义
--- @return string 当前前缀指纹
function M.verify_cache_identity(agent, messages, tool_defs)
  local system_text = ""
  if messages and messages[1] and messages[1].role == "system" then
    system_text = messages[1].content or ""
  end
  local id = M.prefix_id(system_text, tool_defs)
  local cache = agent.cache or {}
  if cache.last_prefix_id and cache.last_prefix_id ~= id then
    logger.warn("[prefix] 缓存身份变更，前缀缓存将失效: %s -> %s", cache.last_prefix_id, id)
    cache.identity_changes = (cache.identity_changes or 0) + 1
  end
  cache.last_prefix_id = id
  agent.cache = cache
  return id
end

-- ========== 缓存用量解析 ==========

--- 从 provider usage 解析缓存命中/未命中 token
--- 保持向后兼容：不传 model/provider 时按 OpenAI/DeepSeek 字段解析。
--- @param usage table|nil 原始 usage
--- @param model string|nil 模型 id（提供则按能力表分派解析器）
--- @param provider_name string|nil 提供商名
--- @return table|nil { cache_read, cache_write, cache_miss, ratio }
function M.parse_cache_usage(usage, model, provider_name)
  if not usage or type(usage) ~= "table" then return nil end

  local kind = "openai"
  if model or provider_name then
    local ok, caps = pcall(function()
      return require("NeoAI.core.model.capabilities").resolve(model, provider_name)
    end)
    if ok and caps and caps.cache_kind then kind = caps.cache_kind end
  end

  local cache_read, cache_write, total_prompt

  if kind == "anthropic" then
    -- Anthropic: input_tokens 不含缓存命中（无缓存时 input_tokens 即全部输入）
    local read = tonumber(usage.cache_read_input_tokens) or 0
    local write = tonumber(usage.cache_creation_input_tokens) or 0
    local input = tonumber(usage.input_tokens) or tonumber(usage.prompt_tokens) or 0
    cache_read = read
    cache_write = write
    total_prompt = input + read + write
  elseif kind == "gemini" then
    -- Gemini: promptTokenCount 为输入总量，cachedContentTokenCount 为其中命中缓存的部分
    local meta = usage.usageMetadata or usage
    cache_read = tonumber(meta.cachedContentTokenCount or usage.cachedContentTokenCount) or 0
    cache_write = 0
    total_prompt = tonumber(meta.promptTokenCount or usage.promptTokenCount or usage.prompt_tokens) or 0
  else
    -- OpenAI / DeepSeek: prompt_tokens 已包含缓存命中（含 cache_read）
    local details = usage.prompt_tokens_details or {}
    cache_read = tonumber(usage.cache_read
      or usage.prompt_cache_hit_tokens
      or details.cached_tokens) or 0
    cache_write = tonumber(usage.cache_write
      or usage.prompt_cache_miss_tokens) or 0
    total_prompt = tonumber(usage.prompt_tokens) or 0
  end

  local cache_miss = math.max(0, total_prompt - cache_read)
  return {
    cache_read = cache_read,
    cache_write = cache_write,
    cache_miss = cache_miss,
    ratio = total_prompt > 0 and (cache_read / total_prompt) or 0,
  }
end

return M
