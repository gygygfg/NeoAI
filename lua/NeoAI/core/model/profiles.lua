--- 协议族 + 厂商/模型方言层
--- @module NeoAI.core.model.profiles
--- 内部规范固定为「OpenAI 形消息 + 统一响应」；本模块把各协议族内的厂商/模型方言
--- （参数名、推理参数形态、推理回传策略、鉴权头、usage 字段、溢出错误措辞）解析成一张
--- dialect 表，供 core.model.adapter（协议编解码）与 core.agent.request（发送）消费。
---
--- 解析顺序：用户覆盖（ai.model_policy.dialects）→ 厂商 profile → 模型 pattern → 协议默认。
--- 纯数据 + 纯函数。

local config_store = require("NeoAI.kernel.config_store")

local M = {}

-- ========== 私有常量 ==========

--- 协议族默认方言
local PROTOCOLS = {
  openai = {
    protocol = "openai",
    max_tokens_field = "max_tokens",
    temperature_supported = true,
    reasoning_kind = "none",
    reasoning_echo = "never",
    stream_usage = true, -- OpenAI 兼容需 stream_options.include_usage 才回传 usage
    cache_directive = "none",
    max_tokens_required = false, -- 未传则不发送（由厂商默认决定）
  },
  anthropic = {
    protocol = "anthropic",
    max_tokens_field = "max_tokens",
    temperature_supported = true,
    reasoning_kind = "budget",
    reasoning_echo = "never", -- 保守：默认不回传 thinking（避免无 signature 报错）
    stream_usage = false,
    cache_directive = "anthropic_auto",
    max_tokens_required = true, -- Anthropic 的 max_tokens 为必填，未传时用能力表兼底
  },
  google = {
    protocol = "google",
    max_tokens_field = "maxOutputTokens",
    temperature_supported = true,
    reasoning_kind = "thinking_config",
    reasoning_echo = "never",
    stream_usage = false,
    cache_directive = "none",
    max_tokens_required = false,
  },
}

--- 厂商 / 模型 profile（对协议默认的覆盖）
local PROFILES = {
  -- OpenAI 系
  openai = { protocol = "openai", reasoning_kind = "none" },
  openai_reasoning = {
    protocol = "openai",
    max_tokens_field = "max_completion_tokens",
    temperature_supported = false,
    reasoning_kind = "effort",
    default_effort = "medium",
  },
  deepseek = { protocol = "openai", reasoning_kind = "none" },
  groq = { protocol = "openai", reasoning_kind = "none" },
  together = { protocol = "openai", reasoning_kind = "none" },
  openrouter = { protocol = "openai", reasoning_kind = "openrouter_object" },
  siliconflow = { protocol = "openai", reasoning_kind = "enable_thinking" },
  aliyun = { protocol = "openai", reasoning_kind = "enable_thinking" },
  zhipu = { protocol = "openai", reasoning_kind = "thinking_object" },
  moonshot = { protocol = "openai", reasoning_kind = "none" },
  baidu = { protocol = "openai", reasoning_kind = "none" },
  stepfun = { protocol = "openai", reasoning_kind = "none" },
  -- 原生协议
  anthropic = { protocol = "anthropic", reasoning_kind = "budget" },
  google = { protocol = "google", reasoning_kind = "thinking_config" },
}

--- 模型 id pattern → profile 名（provider 无独立 profile 时使用）
local MODEL_PROFILES = {
  { pat = "gpt-5", profile = "openai_reasoning" },
  { pat = "o1", profile = "openai_reasoning" },
  { pat = "o3", profile = "openai_reasoning" },
  { pat = "o4", profile = "openai_reasoning" },
  { pat = "claude", profile = "anthropic" },
  { pat = "gemini", profile = "google" },
  { pat = "deepseek", profile = "deepseek" },
}

-- ========== 私有函数 ==========

--- 用户方言覆盖：ai.model_policy.dialects[provider] 或 [model]
--- @param provider_name string|nil
--- @param model string|nil
--- @return table|nil
local function _dialect_override(provider_name, model)
  local overrides = config_store.get("ai.model_policy.dialects")
  if type(overrides) ~= "table" then return nil end
  if provider_name and overrides[provider_name] then return overrides[provider_name] end
  if model and overrides[model] then return overrides[model] end
  return nil
end

--- 获取账号可用的 profile（仅当协议与提供商 api_type 一致，避免第三方兼容端点被误换成原生协议）
--- @param name string|nil
--- @param protocol string
--- @return table|nil
local function _applicable(name, protocol)
  if not name then return nil end
  local p = PROFILES[name]
  if not p then return nil end
  if (p.protocol or protocol) ~= protocol then return nil end
  return p
end

--- 依 provider → model 选择适用的 profile 名（协议必须与提供商 api_type 一致）
--- @param provider_name string|nil
--- @param provider table
--- @param model string|nil
--- @param protocol string
--- @return string|nil provider_profile
--- @return string|nil model_profile
local function _detect_profiles(provider_name, provider, model, protocol)
  local pname = nil
  if provider_name and PROFILES[provider_name] then
    pname = provider_name
  elseif type(provider.dialect) == "string" and PROFILES[provider.dialect] then
    pname = provider.dialect
  end
  if not _applicable(pname, protocol) then pname = nil end

  local mname = nil
  local id = tostring(model or ""):lower()
  for _, mp in ipairs(MODEL_PROFILES) do
    if id ~= "" and id:find(mp.pat, 1, true) and _applicable(mp.profile, protocol) then
      mname = mp.profile
      break
    end
  end
  return pname, mname
end

-- ========== 公开 API ==========

--- 解析方言
--- @param provider_name string|nil
--- @param provider table|nil 提供商配置（缺省按 provider_name 读取）
--- @param model string|nil 模型 id
--- @return table dialect
function M.resolve(provider_name, provider, model)
  provider = provider or (provider_name and config_store.get("ai.providers." .. provider_name)) or {}
  local protocol = provider.api_type or "openai"
  local dialect = vim.deepcopy(PROTOCOLS[protocol] or PROTOCOLS.openai)

  local provider_profile, model_profile = _detect_profiles(provider_name, provider, model, protocol)
  if provider_profile then
    dialect = vim.tbl_deep_extend("force", dialect, vim.deepcopy(PROFILES[provider_profile]))
  end
  if model_profile then
    -- 模型 pattern 比 provider 更具体，后应用以覆盖（如 openai 账号下的 gpt-5/o 系列）
    dialect = vim.tbl_deep_extend("force", dialect, vim.deepcopy(PROFILES[model_profile]))
  end
  dialect.profile = model_profile or provider_profile

  local ov = _dialect_override(provider_name, model)
  if ov then
    dialect = vim.tbl_deep_extend("force", dialect, vim.deepcopy(ov))
  end

  if config_store.get("ai.model_policy.enabled") == false then
    dialect = vim.deepcopy(PROTOCOLS[protocol] or PROTOCOLS.openai)
  end

  dialect.name = dialect.profile or provider_name or protocol
  return dialect
end

--- 是否需要 thinking（推理）参数
--- @param dialect table
--- @return boolean
function M.reasoning_enabled(dialect)
  return dialect and dialect.reasoning_kind and dialect.reasoning_kind ~= "none"
end

--- 是否有厂商/模型 profile 命中（供诊断）
--- @param provider_name string|nil
--- @param provider table|nil
--- @param model string|nil
--- @return boolean
function M.has_profile(provider_name, provider, model)
  provider = provider or (provider_name and config_store.get("ai.providers." .. provider_name)) or {}
  local protocol = provider.api_type or "openai"
  local pp, mp = _detect_profiles(provider_name, provider, model, protocol)
  return pp ~= nil or mp ~= nil
end

return M
