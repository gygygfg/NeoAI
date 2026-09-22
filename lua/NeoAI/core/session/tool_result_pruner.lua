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
local async = require("NeoAI.utils.async")
local tm = require("NeoAI.utils.textmetrics")
local work = require("NeoAI.utils.work")

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
--- 走纯 Lua `utils.textmetrics`：MB 级内容不再逐次 C 边界往返，且可在线程池内计算。
--- @param text any
--- @return number
local function _char_len(text)
  if type(text) ~= "string" or _is_blob(text) then return 0 end
  return tm.strchars(text)
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
  local head = tm.strcharpart(text, 0, math.max(0, math.min(total, head_end)))
  local tail_len = math.max(0, total - tail_start)
  local tail = tm.strcharpart(text, math.max(0, tail_start), tail_len)
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
      local head = tm.strcharpart(b.text, 0, head_end)
      local tail = tm.strcharpart(b.text, tail_start, points - tail_start)
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

-- ========== 线程池卸载（异步裁剪） ==========

--- 工作线程内的字符串裁剪（纯 Lua）：textmetrics 源码经参数传入，线程内 load。
--- 返回编码结果：`"\0"` = 未超阈值不裁剪；`"\1"<before>"\t"<after>"\n"<text>` = 裁剪结果。
--- @param content string
--- @param head_chars number
--- @param tail_chars number
--- @param threshold number
--- @param tm_src string utils.textmetrics 源码
--- @param marker string 省略标记
--- @return string
local function _prune_worker(content, head_chars, tail_chars, threshold, tm_src, marker)
  local metrics = load(tm_src)()
  if head_chars + tail_chars >= threshold then return "\0" end
  local total = metrics.strchars(content)
  if total <= threshold then return "\0" end
  local removed_start = head_chars
  local removed_end = math.max(removed_start, total - tail_chars)
  local head = metrics.strcharpart(content, 0, removed_start)
  local tail = metrics.strcharpart(content, removed_end, total - removed_end)
  local text = head .. marker .. tail
  return "\1" .. total .. "\t" .. metrics.strchars(text) .. "\n" .. text
end

--- 线程池与 textmetrics 源码是否可用（已强制多线程，无同步回退开关）
--- @return boolean
local function _offload_enabled()
  if not work.available() then return false end
  if tm.source == nil then return false end
  return true
end

--- 解析 _prune_worker 的编码结果
--- @param encoded string|nil
--- @return number|nil before
--- @return number|nil after
--- @return string|nil text
local function _parse_prune_result(encoded)
  if type(encoded) ~= "string" or encoded:sub(1, 1) ~= "\1" then return nil end
  local body = encoded:sub(2)
  local tab = body:find("\t", 1, true)
  local nl = body:find("\n", 1, true)
  if not tab or not nl or tab >= nl then return nil end
  local before = tonumber(body:sub(1, tab - 1))
  local after = tonumber(body:sub(tab + 1, nl - 1))
  if not before or not after then return nil end
  return before, after, body:sub(nl + 1)
end

--- 异步就地裁剪：把码点统计与切片分配到 `utils.work` 线程池，避免 MB 级工具结果
--- 在发送/压缩路径阻塞主线程。仅卸载字符串内容；块数组与 Blob 走同步路径。
--- 线程池不可用时回退同步 `prune_agent`（行为等价）。
--- 单个任务失败不影响其余结果（视为该条不裁剪）。
--- @param agent table
--- @param opts table|nil { context_cache? }
--- @return Deferred resolve({ pruned = number, chars_removed = number })
function M.prune_agent_async(agent, opts)
  local cfg = _cfg(opts)
  if not cfg.enabled or not agent or not agent.messages then
    return async.resolve({ pruned = 0, chars_removed = 0 })
  end
  if not _offload_enabled() then
    return async.resolve(M.prune_agent(agent, opts))
  end
  local content_mod = require("NeoAI.core.model.content")
  local items = {}
  for _, msg in ipairs(agent.messages) do
    if msg.role == "tool" and type(msg.content) == "string" and msg.content ~= ""
      and not msg.pruned and not _is_blob(msg.content) then
      -- 廉价前置过滤：码点数 ≤ 字节数，字节数未超阈值者必不裁剪，避免为其空跑工作线程
      -- （每轮对全部历史工具结果各起一个 work 任务会随轮次线性放大线程池排队）。
      if #msg.content > cfg.threshold_chars then
        -- has_image 已加廉价子串前置过滤：非图像结果不再 JSON 解码，主线程开销可忽略。
        if not content_mod.has_image({ msg }) then
          local p = work.run(_prune_worker, msg.content, cfg.head_chars, cfg.tail_chars,
            cfg.threshold_chars, tm.source, PRUNE_MARKER)
          local safe = async.Deferred.new()
          p:then_(function(v) safe:resolve(v) end, function() safe:resolve(nil) end)
          items[#items + 1] = { msg = msg, deferred = safe }
        end
      end
    end
  end
  if #items == 0 then
    -- 无字符串候选（或仅有块数组内容）：回退同步裁剪，行为与 prune_agent 一致
    return async.resolve(M.prune_agent(agent, opts))
  end
  local deferreds = {}
  for i, item in ipairs(items) do deferreds[i] = item.deferred end
  return async.all(deferreds):then_(function(results)
    local pruned, chars_removed = 0, 0
    for i, item in ipairs(items) do
      local before, after, text = _parse_prune_result(results[i])
      if before and after and text and after < before then
        item.msg.prune_original_chars = before
        item.msg.content = text
        item.msg.pruned = true
        pruned = pruned + 1
        chars_removed = chars_removed + (before - after)
        event_bus.emit(events.TOOL_RESULT_PRUNED, {
          agent_id = agent.id,
          tool_name = item.msg.tool_name,
          chars_before = before,
          chars_after = after,
        })
      end
    end
    -- 残余（块数组内容 / 异步任务失败未覆盖）：同步补齐，保证与 prune_agent 行为一致。
    -- 已裁剪消息带 pruned 标记会被跳过，故此处只处理异步未覆盖的少数项。
    local residual = M.prune_agent(agent, opts)
    pruned = pruned + residual.pruned
    chars_removed = chars_removed + residual.chars_removed
    return { pruned = pruned, chars_removed = chars_removed }
  end)
end

return M
