--- 模型能力表
--- @module NeoAI.core.model.capabilities
--- 按模型 / 提供商标注「数值能力」：上下文窗口、最大输出、缓存机制类型与阈值、
--- 每 token 字符估算系数等。整条链路（压缩阈值、容量显示、缓存命中解析、请求参数）
--- 据此按模型自动选择，未知模型回退到保守默认值。
---
--- 解析顺序：用户覆盖（ai.model_policy.overrides）→ 内置模型 pattern → api_type 默认 → 兜底。
--- 纯数据 + 纯函数，无副作用（仅读 config_store）。

local config_store = require("NeoAI.kernel.config_store")

local M = {}

-- ========== 私有常量 ==========

--- 兜底上下文窗口（与历史行为一致，未知模型不改变既有压缩阈值）
local DEFAULT_WINDOW = 64000
--- 兜底最大输出 token
local DEFAULT_MAX_OUTPUT = 4096
--- 兜底每 token 字符数（英文约 4；CJK 可覆盖为 1.5~2）
local DEFAULT_CHARS_PER_TOKEN = 4

--- 内置模型 pattern：小写子串匹配，自上而下先匹配先胜。
--- 字段：
---   window        上下文窗口 token
---   max_output    最大输出 token
---   cache_kind    缓存机制（openai / anthropic / gemini / none）
---   min_cacheable 最小可缓存 token（低于则不缓存，不报错）
---   explicit      是否支持显式缓存（断点 / 缓存对象）
---   ttl           缓存 TTL 秒（显式缓存续期用）
---   max_breakpoints 显式断点上限（Anthropic=4）
---   reasoning     推理参数形态提示（effort / budget / enable / thinking_config）
local MODELS = {
  -- ===== OpenAI =====
  { pat = "gpt-5", window = 400000, max_output = 128000, cache_kind = "openai", min_cacheable = 1024, explicit = true },
  { pat = "gpt-4.1", window = 1047576, max_output = 32768, cache_kind = "openai", min_cacheable = 1024 },
  { pat = "gpt-4o", window = 128000, max_output = 16384, cache_kind = "openai", min_cacheable = 1024 },
  { pat = "gpt-4-turbo", window = 128000, max_output = 4096, cache_kind = "openai", min_cacheable = 1024 },
  { pat = "gpt-4", window = 8192, max_output = 4096, cache_kind = "openai" },
  { pat = "gpt-3.5", window = 16385, max_output = 4096, cache_kind = "openai" },
  { pat = "o4", window = 200000, max_output = 100000, cache_kind = "openai", min_cacheable = 1024, reasoning = "effort" },
  { pat = "o3", window = 200000, max_output = 100000, cache_kind = "openai", min_cacheable = 1024, reasoning = "effort" },
  { pat = "o1", window = 200000, max_output = 100000, cache_kind = "openai", min_cacheable = 1024, reasoning = "effort" },
  -- ===== Anthropic =====
  { pat = "claude", window = 200000, max_output = 8192, cache_kind = "anthropic", min_cacheable = 1024, explicit = true, ttl = 300, max_breakpoints = 4, reasoning = "budget" },
  -- ===== Google =====
  { pat = "gemini", window = 1048576, max_output = 8192, cache_kind = "gemini", min_cacheable = 2048, explicit = true, ttl = 3600, reasoning = "thinking_config" },
  -- ===== DeepSeek =====
  -- V3+/V4 系列上下文窗口为 128K（旧版 deepseek-chat 64K 已下线）
  { pat = "deepseek", window = 131072, max_output = 8192, cache_kind = "openai", explicit = false },
  -- ===== 其它常见 =====
  { pat = "kimi", window = 131072, max_output = 8192, cache_kind = "openai" },
  { pat = "moonshot", window = 131072, max_output = 8192, cache_kind = "openai" },
  { pat = "glm", window = 131072, max_output = 4096, cache_kind = "openai" },
  { pat = "qwen", window = 131072, max_output = 8192, cache_kind = "openai" },
  { pat = "llama", window = 131072, max_output = 8192, cache_kind = "openai" },
  { pat = "mixtral", window = 32768, max_output = 8192, cache_kind = "openai" },
  { pat = "step", window = 65536, max_output = 8192, cache_kind = "openai" },
}

--- 协议族默认值（模型 pattern 未命中时按 api_type 取）
local API_DEFAULTS = {
  openai = { cache_kind = "openai", window = 128000, max_output = DEFAULT_MAX_OUTPUT },
  anthropic = {
    cache_kind = "anthropic", window = 200000, max_output = 8192,
    explicit = true, min_cacheable = 1024, ttl = 300, max_breakpoints = 4,
  },
  google = {
    cache_kind = "gemini", window = 1048576, max_output = 8192,
    explicit = true, min_cacheable = 2048, ttl = 3600,
  },
}

-- ========== 私有函数 ==========

--- 读取某 provider 的配置表
--- @param provider_name string|nil
--- @return table
local function _provider(provider_name)
  if not provider_name then return {} end
  return config_store.get("ai.providers." .. provider_name) or {}
end

--- 读取模型列表中实时回传的数值元数据（来自 /models 响应）
--- 优先级：实时 > 内置表；未获取到则返回 nil（回退内置）。
--- 延迟 require registry，避免模块加载期循环依赖。
--- @param model string|nil
--- @param provider_name string|nil
--- @return table|nil { context_window?, max_output? }
local function _live_meta(model, provider_name)
  if not model then return nil end
  local ok, registry = pcall(require, "NeoAI.core.model.registry")
  if not ok or not registry.meta then return nil end
  local ok2, meta = pcall(registry.meta, model, provider_name)
  if not ok2 then return nil end
  return meta
end

--- 用户覆盖：ai.model_policy.overrides[model] 优先，其次 overrides[provider]
--- @param model string|nil
--- @param provider_name string|nil
--- @return table|nil
local function _override_for(model, provider_name)
  local overrides = config_store.get("ai.model_policy.overrides")
  if type(overrides) ~= "table" then return nil end
  if model and overrides[model] then return overrides[model] end
  if provider_name and overrides[provider_name] then return overrides[provider_name] end
  return nil
end

-- ========== 公开 API ==========

--- 能力表兜底窗口（供测试 / 文档引用）
M.DEFAULT_WINDOW = DEFAULT_WINDOW

--- 解析某模型的能力表
--- 数值（上下文窗口 / 最大输出）解析优先级：用户 overrides → 实时 API 元数据 → 内置 pattern → api_type 默认 → 兜底；
--- 其余能力（缓存机制类型/最小可缓存/TTL/断点）只来自内置 pattern 与 api_type 默认。
--- @param model string|nil 模型 id
--- @param provider_name string|nil 提供商名
--- @param provider table|nil 提供商配置（缺省按 provider_name 读取）
--- @return table caps { context_window, max_output, cache_kind, min_cacheable, explicit_cache, cache_ttl, max_breakpoints, chars_per_token, reasoning, matched, source }
function M.resolve(model, provider_name, provider)
  provider = provider or _provider(provider_name)
  local api_type = provider.api_type or "openai"
  local caps = vim.deepcopy(API_DEFAULTS[api_type] or {})

  local id = tostring(model or ""):lower()
  local matched = nil
  for _, m in ipairs(MODELS) do
    if id ~= "" and id:find(m.pat, 1, true) then
      caps = vim.tbl_deep_extend("force", caps, vim.deepcopy(m))
      matched = m.pat
      break
    end
  end

  -- 数值能力按优先级覆盖：内置/协议默认 → 实时 → 用户覆盖
  local enabled = config_store.get("ai.model_policy.enabled") ~= false
  local base_src = matched and "builtin" or "api_default"
  local window = tonumber(caps.window) or DEFAULT_WINDOW
  local max_output = tonumber(caps.max_output) or DEFAULT_MAX_OUTPUT
  local window_src = base_src
  local output_src = base_src

  if enabled then
    local live = _live_meta(model, provider_name)
    if live then
      local lw = tonumber(live.context_window)
      if lw and lw > 0 then
        window = lw
        window_src = "live"
      end
      local lo = tonumber(live.max_output)
      if lo and lo > 0 then
        max_output = lo
        output_src = "live"
      end
    end
  end

  local ov = _override_for(model, provider_name)
  if ov then
    caps = vim.tbl_deep_extend("force", caps, vim.deepcopy(ov))
    local ow = tonumber(ov.window)
    if ow and ow > 0 then
      window = ow
      window_src = "user"
    end
    local oo = tonumber(ov.max_output)
    if oo and oo > 0 then
      max_output = oo
      output_src = "user"
    end
  end

  return {
    context_window = window,
    max_output = max_output,
    cache_kind = caps.cache_kind or "openai",
    min_cacheable = tonumber(caps.min_cacheable) or 0,
    explicit_cache = caps.explicit == true,
    cache_ttl = tonumber(caps.ttl) or nil,
    max_breakpoints = tonumber(caps.max_breakpoints) or nil,
    chars_per_token = tonumber(caps.chars_per_token) or DEFAULT_CHARS_PER_TOKEN,
    reasoning = caps.reasoning or nil,
    matched = matched,
    source = { window = window_src, max_output = output_src },
  }
end

--- 解析上下文窗口：显式配置（且非默认值）优先，否则按模型能力表推导，最后兜底
--- 约定：config 的 context_window 只有与内置默认不同才视为用户显式覆盖，
--- 这样「默认 64000」不会屏蔽模型真实窗口（如 Gemini 1M / Claude 200k）。
--- @param cfg_window number|string|nil 配置中的 context_window
--- @param model string|nil
--- @param provider_name string|nil
--- @param provider table|nil
--- @return number
function M.resolve_window(cfg_window, model, provider_name, provider)
  if config_store.get("ai.model_policy.enabled") == false then
    return (type(cfg_window) == "number" and cfg_window) or DEFAULT_WINDOW
  end
  if type(cfg_window) == "number" and cfg_window > 0 and cfg_window ~= DEFAULT_WINDOW then
    return cfg_window
  end
  local caps = M.resolve(model, provider_name, provider)
  if caps.context_window and caps.context_window > 0 then
    return caps.context_window
  end
  return (type(cfg_window) == "number" and cfg_window) or DEFAULT_WINDOW
end

--- 是否为模型级用户覆盖（供诊断）
--- @param model string|nil
--- @param provider_name string|nil
--- @return boolean
function M.has_override(model, provider_name)
  return _override_for(model, provider_name) ~= nil
end

return M
