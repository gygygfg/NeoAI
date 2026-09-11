--- 工具结果裁剪（模型无关）
--- @module NeoAI.core.session.tool_result_pruner
--- 策略对齐 deepseek-harness 的 compaction-tool-result-pruner：
--- 在触发摘要压缩之前，先把超预算的工具结果（read_file / run_command 等大输出）
--- 裁成「头部 + 省略标记 + 尾部」，保留原始消息其余字段（tool_call_id / tool_name）。
--- 多数情况下仅靠裁剪即可把请求压回阈值内，从而避免一次昂贵的摘要调用。
--- 裁剪是语法级的：保留头尾，不判断中间哪些行语义重要；含图像引用的结果不裁剪。

local config_store = require("NeoAI.kernel.config_store")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")

local M = {}

-- ========== 私有常量 ==========

--- 省略标记（与 deepseek-harness 逐字一致）
local PRUNE_MARKER = "\n\n[... tool result middle pruned ...]\n\n"
local DEFAULT_THRESHOLD_CHARS = 8192
local DEFAULT_HEAD_CHARS = 4096
local DEFAULT_TAIL_CHARS = 1024

-- ========== 私有函数 ==========

--- 是否为 Vimscript Blob（Lua type 也是 "string"，但 Vim 函数会抛 E976）
--- @param v any
--- @return boolean
local function _is_blob(v)
  return type(v) == "string" and vim.fn.type(v) == vim.v.t_blob
end

--- 统计文本码点数（Blob 视为 0，避免 vim.fn.strchars 抛 E976）
--- @param text any
--- @return number
local function _char_len(text)
  if type(text) ~= "string" or _is_blob(text) then return 0 end
  return vim.fn.strchars(text)
end

--- 获取裁剪配置（允许 opts 覆盖 context_cache）
--- @param opts table|nil { context_cache? }
--- @return table { enabled, threshold_chars, head_chars, tail_chars }
local function _cfg(opts)
  local cfg = vim.deepcopy(config_store.get("ai.context_cache") or {})
  if opts and opts.context_cache then
    for k, v in pairs(opts.context_cache) do cfg[k] = v end
  end
  return {
    enabled = cfg.prune_enabled ~= false,
    threshold_chars = tonumber(cfg.prune_threshold_chars) or DEFAULT_THRESHOLD_CHARS,
    head_chars = tonumber(cfg.prune_head_chars) or DEFAULT_HEAD_CHARS,
    tail_chars = tonumber(cfg.prune_tail_chars) or DEFAULT_TAIL_CHARS,
  }
end

--- 保留头部与尾部，中间以标记替换（按码点切片，不切断多字节字符）
--- @param text string
--- @param head_end number 保留的头部码点数
--- @param tail_start number 尾部起始码点下标
--- @return string head, string tail
local function _slice(text, head_end, tail_start)
  local total = _char_len(text)
  local head = vim.fn.strcharpart(text, 0, math.max(0, math.min(total, head_end)))
  local tail_len = math.max(0, total - tail_start)
  local tail = vim.fn.strcharpart(text, math.max(0, tail_start), tail_len)
  return head, tail
end

-- ========== 公开 API ==========

--- 统计内容的文本码点数（非 text 块计 0）
--- @param content string|table|nil
--- @return number
function M.measure_content(content)
  if type(content) == "string" then
    return _char_len(content)
  end
  if type(content) == "table" then
    local n = 0
    for _, b in ipairs(content) do
      if type(b) == "table" and b.type == "text" and b.text then
        n = n + _char_len(b.text)
      end
    end
    return n
  end
  return 0
end

--- 裁剪内容：超过阈值时保留头部 + 标记 + 尾部，否则返回 nil。
--- 字符串原样返回字符串；块数组保留非文本块及其相对顺序。
--- @param content string|table
--- @param cfg table|nil 已解析配置（缺省读 config_store）
--- @return string|table|nil 裁剪结果，未超阈值返回 nil
function M.prune_content(content, cfg)
  cfg = cfg or _cfg()
  -- 头 + 尾已不小于阈值时无法在不增长的前提下裁剪，直接跳过
  if cfg.head_chars + cfg.tail_chars >= cfg.threshold_chars then return nil end
  local total = M.measure_content(content)
  if total <= cfg.threshold_chars then return nil end

  local removed_start = cfg.head_chars
  local removed_end = math.max(removed_start, total - cfg.tail_chars)

  if type(content) == "string" then
    local head, tail = _slice(content, removed_start, removed_end)
    return head .. PRUNE_MARKER .. tail
  end

  local out = {}
  local consumed = 0
  local marker_inserted = false
  for _, b in ipairs(content) do
    if type(b) ~= "table" or b.type ~= "text" or not b.text then
      out[#out + 1] = b
    elseif _is_blob(b.text) then
      out[#out + 1] = b
    else
      local points = _char_len(b.text)
      local block_start = consumed
      local block_end = block_start + points
      local head_end = math.min(points, math.max(0, removed_start - block_start))
      local tail_start = math.min(points, math.max(0, removed_end - block_start))
      local intersects = block_start < removed_end and block_end > removed_start
      local marker_text = (intersects and not marker_inserted) and PRUNE_MARKER or ""
      if marker_text ~= "" then marker_inserted = true end
      local head = vim.fn.strcharpart(b.text, 0, head_end)
      local tail = vim.fn.strcharpart(b.text, tail_start, points - tail_start)
      local text = head .. marker_text .. tail
      if text ~= "" then
        local copy = vim.deepcopy(b)
        copy.text = text
        out[#out + 1] = copy
      end
      consumed = block_end
    end
  end
  return out
end

--- 就地裁剪 Agent 消息队列中的所有超预算工具结果。
--- 含图像引用的工具结果跳过（裁剪会使内嵌 JSON 失效、图像无法注入）。
--- @param agent table
--- @param opts table|nil { context_cache? }
--- @return table { pruned = number, chars_removed = number }
function M.prune_agent(agent, opts)
  local cfg = _cfg(opts)
  if not cfg.enabled or not agent or not agent.messages then
    return { pruned = 0, chars_removed = 0 }
  end
  local content_mod = require("NeoAI.core.model.content")
  local pruned, chars_removed = 0, 0
  for _, msg in ipairs(agent.messages) do
    if msg.role == "tool" and msg.content ~= nil and not msg.pruned
      and not _is_blob(msg.content) then
      if not content_mod.has_image({ msg }) then
        local before = M.measure_content(msg.content)
        local out = M.prune_content(msg.content, cfg)
        if out ~= nil then
          local after = M.measure_content(out)
          if after < before then
            msg.prune_original_chars = before
            msg.content = out
            msg.pruned = true
            pruned = pruned + 1
            chars_removed = chars_removed + (before - after)
            event_bus.emit(events.TOOL_RESULT_PRUNED, {
              agent_id = agent.id,
              tool_name = msg.tool_name,
              chars_before = before,
              chars_after = after,
            })
          end
        end
      end
    end
  end
  return { pruned = pruned, chars_removed = chars_removed }
end

--- 省略标记（供测试/文档引用）
M.PRUNE_MARKER = PRUNE_MARKER

return M
