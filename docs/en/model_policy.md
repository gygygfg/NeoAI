# Automatic Per-Model Selection: Protocol Dialects · Capability Tables · Context Policy

> [中文](../model_policy.md) | **English**

> This document summarizes the request/cache differences across major model APIs (from official
> documentation) and explains how NeoAI converges these differences into an "automatic per-model
> selection" pipeline: **context filtering/compaction → protocol encoding → send**.
> Corresponding source: `lua/NeoAI/core/model/{capabilities,profiles,adapter,prompt_cache}.lua`,
> `lua/NeoAI/core/agent/{request,prefix,agent}.lua`, `lua/NeoAI/core/session/compactor.lua`.

---

## 1. Why Dispatch by Model

A single pipeline contains three kinds of differences, which in the past were all handled
uniformly as "OpenAI shape + fixed 64000 window":

1. **Protocol family differences**: Anthropic puts `system` at the top level, uses `input_schema`
   for tools, `source.base64` for images, and `tool_result` blocks for tool results; Gemini uses
   `contents` + `functionDeclarations` (types must be uppercase, and unsupported schema keywords
   must be trimmed) + `inlineData`.
2. **Vendor dialect differences**: even for OpenAI-compatible APIs, the
   `max_tokens` / `max_completion_tokens` / `maxOutputTokens` fields differ; reasoning parameters
   include `reasoning_effort` / `enable_thinking` / `thinking:{type}` / `thinkingConfig`; whether
   temperature may be sent in thinking mode differs; and streaming usage requires
   `stream_options.include_usage`.
3. **Cache mechanism differences**: the hit-count fields, the minimum cacheable length, and
   whether explicit caching is supported all differ.

Today this is driven by three layers of data (see `docs/ai_engine.md` for the layering):

```
provider_name + provider + model
   │  profiles.resolve()      dialect: vendor/model overrides within a protocol family
   ▼
 dialect ──►  adapter.<protocol>  protocol encode/decode (messages/tools/image/usage)
   │
 capabilities.resolve()     capabilities: window/max_output/cache mechanism/min cacheable/chars-per-token
```

---

## 2. Official Documentation Highlights (Caching)

| Provider | Mechanism | Trigger | Hit/write fields | Minimum cacheable | TTL | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| **DeepSeek** | Disk prefix cache (sliding window) | Fully automatic | `prompt_cache_hit_tokens` / `prompt_cache_miss_tokens` | Per prefix unit | Hours to days | Requires an **exact match of the cache prefix unit**; three persistence modes: request boundary, common prefix detection, fixed-length chunking |
| **OpenAI** | prompt cache (KV) | Implicit by default; explicit supported on GPT-5.6+ | `prompt_tokens_details.cached_tokens` | 1,024 (newer versions) | Minutes | Explicit: `prompt_cache_options.mode="explicit"` + content block `prompt_cache_breakpoint`; write 1.25× / read 0.1×; ≤4 writes per request; **changing tools/order/schema invalidates the prefix after the breakpoint** |
| **Anthropic** | Prefix cache | Automatic at top level, or `cache_control` breakpoints | `cache_read_input_tokens` / `cache_creation_input_tokens` | 512 / 1,024 / 2,048 / 4,096 (by model) | 5 minutes / 1 hour | `input_tokens` does **not** include cache hits; breakpoints control cache boundaries; at most 4 breakpoints |
| **Gemini** | Implicit (default on 2.5+) + explicit `cachedContents` | Implicit is automatic; explicit requires creating a cache object | `usageMetadata.cachedContentTokenCount` / `promptTokenCount` | 2,048 (2.5) / 4,096 (3.x) | 1 hour by default (`ttl`) | Explicit: `POST /v1beta/cachedContents` (`model=models/{m}`, `systemInstruction`, `tools`, `ttl:"3600s"`), the response contains `name`; clean up with `DELETE /v1beta/{name}` |

## 3. Official Documentation Highlights (Request Parameter Dialects)

| Dimension | OpenAI/DeepSeek | OpenAI o series | Anthropic | Gemini |
| --- | --- | --- | --- | --- |
| Output limit field | `max_tokens` | `max_completion_tokens` | `max_tokens` (required) | `generationConfig.maxOutputTokens` |
| Reasoning switch | — | `reasoning_effort` | `thinking:{type:"enabled",budget_tokens}` (temperature must be 1) | `generationConfig.thinkingConfig` |
| Reasoning stream | `reasoning_content` / `reasoning` | Same | `thinking`/`thinking_delta` blocks (with signature) | part `thought:true` |
| Auth | `Authorization: Bearer` | Same | `x-api-key` + `anthropic-version` | URL `?key=` |
| usage | `prompt_tokens` (including hits) | Same | `input_tokens` / `output_tokens` (input excludes hits) | `usageMetadata.*TokenCount` |

Third-party OpenAI-compatible dialects: SiliconFlow/Alibaba Cloud `enable_thinking`, Zhipu
`thinking:{type}`, OpenRouter `reasoning:{enabled,exclude}`, Groq `reasoning_format`.

## 4. Model Numeric Metadata: Prefer Live Retrieval

Values such as `max_tokens` / `max_output` / context window are **no longer hardcoded**; instead
they are retrieved **live** from each vendor's `/models` endpoint where possible (overriding the
built-in table), and only fall back to the built-in capability table when unavailable.

The model list pipeline (`adapter.parse_models` → `registry` → `capabilities`) already preserves
the values returned by the endpoints:

| Protocol/Vendor | Endpoint fields | Extractable |
| --- | --- | --- |
| Google `/v1beta/models` | `inputTokenLimit` / `outputTokenLimit` | Window + max output |
| OpenRouter | `context_length` + `top_provider.max_completion_tokens` | Window + output |
| Groq / Together / Fireworks etc. | `context_window` / `context_length` | Window |
| OpenAI `/v1/models` | Only `id` / `owned_by` | — (fall back to built-in table) |
| Anthropic `/v1/models` | `id` / `display_name` | — (fall back to built-in table) |
| DeepSeek `/models` | `id` / `owned_by` | — (fall back to built-in table) |

Numeric resolution priority: **user `overrides` → live API metadata → built-in pattern → `api_type`
default → fallback**. The returned `caps.source = { window, max_output }` annotates the source of
each value (`user` / `live` / `builtin` / `api_default`) for easier diagnosis.

### Send Strategy for the Output Limit

- **Explicitly provided by the user** (`opts.max_tokens` or scenario `modes.*.max_tokens`) →
  **used as-is** (clamped when it exceeds the model's `max_output`, to avoid vendor 400s).
- **Not provided** → **the parameter is not sent**, leaving the default maximum output to the
  model/vendor. Live metadata / `overrides.max_output` is no longer automatically sent as
  `max_tokens`; it is used only for clamping decisions, required-field fallbacks, and capacity display.
- Exception: protocol **required** fields (Anthropic `max_tokens`) fall back to the capability
  table's `max_output`.
- If the model is still truncated by its own output limit (`finish_reason=length`/`max_tokens`/`MAX_TOKENS`),
  the tool loop automatically continues (see the tool call loop in [ai_engine.md](ai_engine.md));
  the continuation prompt is added only to the request and is never persisted.

Live values are fetched at startup prefetch / manual refresh (`ai.model_refresh`), so they **add no
per-request network round trip**; a failed fetch or missing field falls back silently — it never
errors and never blocks.

## 5. Token-Saving Highlights

1. **Stable prefix**: the system prompt is rendered from ordered segments and tools are output in
   lexicographic order by name (`prefix.lua`); any byte change invalidates the prefix cache from
   the first changed token onward.
2. **Reasoning content is not echoed back**: the chain of thought is UI-only and is not sent with
   the history (default policy), avoiding repeated sending and prefix disruption; if Anthropic's
   tool loop errors due to a missing signature, the dialect option
   `reasoning_echo="within_round"` can retain it within the same round.
3. **Compaction replaces rather than appends**: the checkpoint message `<compacted-summary>`
   replaces the folded interval, so the unchanged prefix before the replacement point can still
   reuse the cache.
4. **Put large, shared content first** and send requests with similar prefixes together (to improve
   the common prefix detection hit rate).
5. **Explicit breakpoints** avoid rewriting volatile content; **streaming** requires
   `stream_options.include_usage` to obtain usage statistics with hits.
6. **History truncation + image budget offload** (`context_builder` / `content.materialize`).

---

## 6. Configuration: `ai.model_policy`

```lua
ai = {
  model_policy = {
    enabled = true,                 -- master switch; when false only the three protocols' base codecs are kept
    explicit_cache = {
      enabled = true,               -- master switch for explicit caching
      openai = false,               -- OpenAI explicit breakpoints are off by default (implicit caching is enough)
      -- anthropic = true,          -- per-mechanism switch (defaults to following the master switch)
      -- gemini = true,
    },
    -- capability overrides (key = model id or provider name)
    overrides = {
      ["deepseek-v4-flash"] = { window = 131072, max_output = 8192 },
      ["my-cjk-model"] = { chars_per_token = 1.8 },
    },
    -- dialect overrides (key = provider name or model id)
    dialects = {
      ["my-provider"] = { max_tokens_field = "max_completion_tokens", reasoning_kind = "effort" },
    },
  },
}
```

**Resolution order**
- Capability table (numeric): user `overrides` → **live API metadata** → built-in model pattern →
  `api_type` default → fallback (window 64000 / output 4096).
- Dialect: user `dialects` → model pattern (the protocol must match `api_type`) → vendor profile →
  protocol default.
- Context window: an **explicit non-default value** of `ai.context_cache.context_window` takes
  priority; otherwise it is derived from the model capability table, and unknown models fall back
  to 64000 (so the default value does not mask real windows such as Gemini 1M / Claude 200k).

**`reasoning_kind` values**: `none` / `effort` / `budget` / `enable_thinking` / `thinking_object` / `openrouter_object` / `thinking_config`.

**Degradation guarantee**: when explicit cache injection or remote cache object creation fails, it
**silently degrades to implicit caching** and never blocks the request; after compaction, explicit
caches are `invalidate`d (Gemini deletes and awaits the next rebuild), and on session destruction
`dispose` cleans up.

## 7. Adding a New Model / New Provider

- New model: add an entry `{ pat=..., window=..., cache_kind=... }` to `MODELS` in `core/model/capabilities.lua`, or override it via the user config `model_policy.overrides`; if the vendor's `/models` already returns the values, no manual maintenance is needed.
- New vendor dialect: add an item to `PROFILES` in `core/model/profiles.lua` (or use `model_policy.dialects`).
- New protocol family: register `encode_messages/encode_tools/build_body/parse_*` in `ADAPTERS` in `core/model/adapter.lua`, and add a default dialect to `PROTOCOLS`.

## 8. Related Documentation

- [ai_engine.md](ai_engine.md): engine pipeline and context compaction / prefix caching.
- [configuration.md](configuration.md): `ai.model_policy` / `ai.context_cache` configuration items.
- [EVENTS.md](EVENTS.md): event constants.
