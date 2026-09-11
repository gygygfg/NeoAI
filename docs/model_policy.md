# 按模型自动选择：协议方言 · 能力表 · 上下文策略

> [English](en/model_policy.md) | **中文**

> 本文汇总各大模型 API 的请求/缓存差异（来自官方文档），并说明 NeoAI 如何把这些差异
> 收敛成「按模型自动选择」的链路：**上下文过滤/压缩 → 协议编码 → 发送**。
> 对应源码：`lua/NeoAI/core/model/{capabilities,profiles,adapter,prompt_cache}.lua`、
> `lua/NeoAI/core/agent/{request,prefix,agent}.lua`、`lua/NeoAI/core/session/compactor.lua`。

---

## 1. 为什么要按模型分派

同一条链路里有三类差异，过去被一视同仁地按「OpenAI 形 + 固定 64000 窗口」处理：

1. **协议族差异**：Anthropic 的 `system` 在顶层、工具用 `input_schema`、图像用 `source.base64`、
   工具结果用 `tool_result` 块；Gemini 用 `contents` + `functionDeclarations`（类型要大写、
   裁剪不支持 schema 关键字）+ `inlineData`。
2. **厂商方言差异**：同是 OpenAI 兼容，`max_tokens` / `max_completion_tokens` / `maxOutputTokens`
   字段不同；推理参数有 `reasoning_effort` / `enable_thinking` / `thinking:{type}` /
   `thinkingConfig`；思考模式下 temperature 是否可发不同；流式 usage 需 `stream_options.include_usage`。
3. **缓存机制差异**：命中计数字段、最小可缓存长度、是否支持显式缓存都不同。

现在由三层数据驱动（分层见 `docs/ai_engine.md`）：

```
provider_name + provider + model
   │  profiles.resolve()      方言：协议族内的厂商/模型覆盖
   ▼
 dialect ──►  adapter.<protocol>  协议编解码（messages/tools/image/usage）
   │
 capabilities.resolve()     能力：窗口/max_output/缓存机制/最小可缓存/字符系数
```

---

## 2. 官方文档要点（缓存）

| Provider | 机制 | 触发 | 命中/写入字段 | 最小可缓存 | TTL | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| **DeepSeek** | 磁盘前缀缓存（滑动窗口） | 全自动 | `prompt_cache_hit_tokens` / `prompt_cache_miss_tokens` | 按 prefix 单元 | 数小时~数天 | 要求**完全匹配缓存前缀单元**；三种持久化：请求边界、公共前缀检测、定长切分 |
| **OpenAI** | prompt cache（KV） | 默认隐式；GPT-5.6+ 支持显式 | `prompt_tokens_details.cached_tokens` | 1,024（新版） | 数分钟 | 显式：`prompt_cache_options.mode="explicit"` + 内容块 `prompt_cache_breakpoint`；写 1.25× / 读 0.1×；每请求≤4 次写；**改 tools/顺序/schema 会使断点后前缀失效** |
| **Anthropic** | 前缀缓存 | 顶层自动 或 `cache_control` 断点 | `cache_read_input_tokens` / `cache_creation_input_tokens` | 512 / 1,024 / 2,048 / 4,096（按型号） | 5 分钟 / 1 小时 | `input_tokens` **不含**缓存命中；断点可控缓存边界；最多 4 个断点 |
| **Gemini** | 隐式（2.5+ 默认） + 显式 `cachedContents` | 隐式自动；显式需建缓存对象 | `usageMetadata.cachedContentTokenCount` / `promptTokenCount` | 2,048（2.5）/ 4,096（3.x） | 默认 1 小时（`ttl`） | 显式：`POST /v1beta/cachedContents`（`model=models/{m}`、`systemInstruction`、`tools`、`ttl:"3600s"`），响应含 `name`；用完 `DELETE /v1beta/{name}` |

## 3. 官方文档要点（请求参数方言）

| 维度 | OpenAI/DeepSeek | OpenAI o 系列 | Anthropic | Gemini |
| --- | --- | --- | --- | --- |
| 输出上限字段 | `max_tokens` | `max_completion_tokens` | `max_tokens`（必填） | `generationConfig.maxOutputTokens` |
| 推理开关 | — | `reasoning_effort` | `thinking:{type:"enabled",budget_tokens}`（temperature 必须=1） | `generationConfig.thinkingConfig` |
| 推理流出 | `reasoning_content` / `reasoning` | 同 | `thinking`/`thinking_delta` 块（带 signature） | part `thought:true` |
| 鉴权 | `Authorization: Bearer` | 同 | `x-api-key` + `anthropic-version` | URL `?key=` |
| usage | `prompt_tokens`（含命中） | 同 | `input_tokens` / `output_tokens`（输入不含命中） | `usageMetadata.*TokenCount` |

第三方 OpenAI 兼容方言：SiliconFlow/阿里云 `enable_thinking`、智谱 `thinking:{type}`、
OpenRouter `reasoning:{enabled,exclude}`、Groq `reasoning_format`。

## 4. 模型数值元数据：实时获取优先

`max_tokens` / `max_output` / 上下文窗口这些数值**不再写死**，而是优先从各家 `/models` 端点
**实时获取**（能拿到的就覆盖内置表），拿不到才回退内置能力表。

模型列表链路（`adapter.parse_models` → `registry` → `capabilities`）已保留端点回传的数值：

| 协议/厂商 | 端点字段 | 可提取 |
| --- | --- | --- |
| Google `/v1beta/models` | `inputTokenLimit` / `outputTokenLimit` | 窗口 + 最大输出 |
| OpenRouter | `context_length` + `top_provider.max_completion_tokens` | 窗口 + 输出 |
| Groq / Together / Fireworks 等 | `context_window` / `context_length` | 窗口 |
| OpenAI `/v1/models` | 仅 `id` / `owned_by` | —（回退内置表） |
| Anthropic `/v1/models` | `id` / `display_name` | —（回退内置表） |
| DeepSeek `/models` | `id` / `owned_by` | —（回退内置表） |

数值解析优先级：**用户 `overrides` → 实时 API 元数据 → 内置 pattern → `api_type` 默认 → 兜底**。
返回的 `caps.source = { window, max_output }` 标注每个数值的来源（`user` / `live` / `builtin` / `api_default`），便于诊断。

### 输出上限的发送策略

- **用户显式传入**（`opts.max_tokens` 或场景 `modes.*.max_tokens`）→ **原样使用**（超出模型
  `max_output` 时收敛，避免厂商 400）。
- **未传入** → **不发送该参数**，由模型/厂商默认最大输出决定。实时元数据 / `overrides.max_output`
  不再自动作为 `max_tokens` 发送，仅用于收敛判断、必填兜底与容量显示。
- 例外：协议**必填**字段（Anthropic `max_tokens`）用能力表 `max_output` 兜底。
- 若模型仍因自身输出上限被截断（`finish_reason=length`/`max_tokens`/`MAX_TOKENS`），工具循环会
  自动续写（见 [ai_engine.md](ai_engine.md) 工具调用循环），续写提示只进请求、不落库。

实时数值在启动预取 / 手动刷新（`ai.model_refresh`）时获取，**不增加每请求网络往返**；
拉取失败或字段缺失静默回退，绝不报错、绝不阻断。

## 5. Token 节省要点

1. **稳定前缀**：系统提示按有序段渲染、工具按名典序输出（`prefix.lua`），任何字节变化都会从首个变更 token 起使前缀缓存失效。
2. **推理内容不回传**：思维链仅用于 UI，不随历史发送（默认策略），避免重复发送与破坏前缀；Anthropic 工具循环若因无 signature 报错，可用方言 `reasoning_echo="within_round"` 在同一轮内保留。
3. **压缩用替换而非追加**：检查点消息 `<compacted-summary>` 替换被折叠区间，替换点之前的未变前缀仍可复用缓存。
4. **把大而公共的内容放最前**、相近前缀的请求集中发（提高公共前缀检测命中率）。
5. **显式断点**避免重写易变内容；**流式**需 `stream_options.include_usage` 才能拿到 usage 统计命中。
6. **历史截断 + 图像预算 offload**（`context_builder` / `content.materialize`）。

---

## 6. 配置：`ai.model_policy`

```lua
ai = {
  model_policy = {
    enabled = true,                 -- 总开关；false 时仅保留三协议基础编解码
    explicit_cache = {
      enabled = true,               -- 显式缓存总开关
      openai = false,               -- OpenAI 显式断点默认关闭（隐式缓存已足够）
      -- anthropic = true,          -- 分机制开关（缺省跟随总开关）
      -- gemini = true,
    },
    -- 能力覆盖（key = 模型 id 或 provider 名）
    overrides = {
      ["deepseek-v4-flash"] = { window = 131072, max_output = 8192 },
      ["my-cjk-model"] = { chars_per_token = 1.8 },
    },
    -- 方言覆盖（key = provider 名 或 模型 id）
    dialects = {
      ["my-provider"] = { max_tokens_field = "max_completion_tokens", reasoning_kind = "effort" },
    },
  },
}
```

**解析顺序**
- 能力表（数值）：用户 `overrides` → **实时 API 元数据** → 内置模型 pattern → `api_type` 默认 → 兜底
  （窗口 64000 / 输出 4096）。
- 方言：用户 `dialects` → 模型 pattern（协议须与 `api_type` 一致）→ 厂商 profile → 协议默认。
- 上下文窗口：`ai.context_cache.context_window` **显式非默认值**优先，否则按模型能力表推导，
  未知模型回退 64000（因此默认值不会屏蔽 Gemini 1M / Claude 200k 等真实窗口）。

**`reasoning_kind` 取值**：`none` / `effort` / `budget` / `enable_thinking` / `thinking_object` / `openrouter_object` / `thinking_config`。

**降级保证**：显式缓存注入或远端缓存对象创建失败时**静默降级为隐式缓存**，绝不阻断请求；
压缩后对显式缓存 `invalidate`（Gemini 删除并待下次重建），会话销毁时 `dispose` 清理。

## 7. 添加新模型 / 新提供商

- 新模型：在 `core/model/capabilities.lua` 的 `MODELS` 加一条 `{ pat=..., window=..., cache_kind=... }`，或在用户配置 `model_policy.overrides` 覆盖；若厂商 `/models` 已回传数值，无需手动维护。
- 新厂商方言：在 `core/model/profiles.lua` 的 `PROFILES` 加一项（或走 `model_policy.dialects`）。
- 新协议族：`core/model/adapter.lua` 的 `ADAPTERS` 注册 `encode_messages/encode_tools/build_body/parse_*`，并在 `PROTOCOLS` 加默认方言。

## 8. 相关文档

- [ai_engine.md](ai_engine.md)：引擎链路与上下文压缩 / 前缀缓存。
- [configuration.md](configuration.md)：`ai.model_policy` / `ai.context_cache` 配置项。
- [EVENTS.md](EVENTS.md)：事件常量。
