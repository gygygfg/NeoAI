--- 多模态内容块与 wire 序列化
--- @module 'NeoAI.core.model.content'
--- 对齐 deepseek-harness：会话消息只存引用，请求期把图像解析为 data URL 注入。
--- - has_image：是否包含（工具结果中 / content 块中的）图像
--- - materialize：从逻辑消息构建 wire 消息（文本模式回流式；图像模式转为 part 数组，
---   工具结果图像跟随其字符串 tool 消息以单独 user 消息投递），并经预算 offload。
--- 依赖：core.attachment + utils(async/json/image)。

local async = require("NeoAI.utils.async")
local json = require("NeoAI.utils.json")
local attachment = require("NeoAI.core.attachment.attachment")

local M = {}

-- ========== 私有常量 ==========

local OFFLOADED_IMAGE_TEXT = table.concat({
  "[image omitted to keep the request within its image limit; older images are omitted first.",
  "If this image is still needed, ask the model to read it again when a path is available.]",
}, " ")

local TOOL_RESULT_IMAGE_TEXT = "Attached image(s):"

-- ========== 私有函数 ==========

--- 解码工具结果的 JSON，提取 image 引用（read_image 返回 { path, image=ref, ... }）
--- @param content string
--- @return table|nil ref
local function _image_ref_from_tool(content)
  if not content or content == "" then return nil end
  -- 仅字符串（工具结果 JSON 文本）需要解码；块数组由 blocks_has_image 处理。
  if type(content) ~= "string" then return nil end
  -- 廉价前置过滤：JSON 中图像引用键固定为 "image"，不含该子串的工具结果（如大文件读取）
  -- 无需 JSON 解码。否则每次裁剪/序列化都要对 MB 级内容做完整解码，阻塞主线程。
  if not content:find('"image"', 1, true) then return nil end
  local ok, obj = pcall(json.decode, content)
  if not ok or type(obj) ~= "table" then return nil end
  local img = obj.image
  if type(img) == "table" and img.attachmentId then
    return img
  end
  -- 兼容：image 为数组
  if type(img) == "table" and #img > 0 and img[1].attachmentId then
    return img[1]
  end
  return nil
end

--- content 块数组中是否有图像
--- @param blocks table|nil
--- @return boolean
function M.blocks_has_image(blocks)
  if type(blocks) ~= "table" then return false end
  for _, b in ipairs(blocks) do
    if type(b) == "table" and b.type == "image" then return true end
  end
  return false
end

--- 展平内容块为纯文本（供文本模式/助手消息用）
--- @param blocks table|nil
--- @return string
function M.flatten_text(blocks)
  if type(blocks) ~= "table" then return "" end
  local out = {}
  for _, b in ipairs(blocks) do
    if type(b) == "table" and b.type == "text" and b.text then
      out[#out + 1] = b.text
    end
  end
  return table.concat(out)
end

--- messages 是否包含图像
--- @param messages table
--- @return boolean
function M.has_image(messages)
  for _, m in ipairs(messages or {}) do
    if m.role == "tool" and _image_ref_from_tool(m.content) then
      return true
    end
    if m.image then return true end
    if type(m.content) == "table" and M.blocks_has_image(m.content) then return true end
  end
  return false
end

--- 按消息顺序收集所有图像引用（最旧在前）
--- @param messages table
--- @return table 数组 ref
local function _collect_refs(messages)
  local refs = {}
  for _, m in ipairs(messages or {}) do
    if m.role == "tool" then
      local ref = _image_ref_from_tool(m.content)
      if ref then refs[#refs + 1] = ref end
    elseif m.image then
      refs[#refs + 1] = m.image
    elseif type(m.content) == "table" then
      for _, b in ipairs(m.content) do
        if type(b) == "table" and b.type == "image" and b.attachment then
          refs[#refs + 1] = b.attachment
        end
      end
    end
  end
  return refs
end

--- 解析数量上限：`nil`/`0`/负数 = 不限；其余取整。
--- @param v any
--- @return number|nil
local function _count_limit(v)
  local n = tonumber(v)
  if n == nil or n <= 0 then return nil end
  return math.floor(n)
end

--- 计算请求内图像数量/字节预算 offload：超限的最旧图像替换为文本占位。
--- 数量配额默认**不限**（`maxImagesPerRequest = 0`）：会话里看图（read_image）不应因条数
--- 被静默丢弃；仅保留 provider 侧的硬上限 `maxRequestImages` 与字节预算兜底。
--- @param wire table 已构建的 wire 消息
--- @param policy table
--- @return number omitted 被替换为文本占位的图像数
local function _apply_budget(wire, policy)
  local max_count = _count_limit(policy.maxImagesPerRequest)
  local hard_count = _count_limit(policy.maxRequestImages)
  if hard_count and (not max_count or hard_count < max_count) then max_count = hard_count end
  local max_bytes = tonumber(policy.maxRequestBytes)
  if max_bytes and max_bytes <= 0 then max_bytes = nil end
  local count = 0
  local total_bytes = 0
  local omitted = 0
  for _, m in ipairs(wire) do
    if type(m.content) == "table" then
      for i, part in ipairs(m.content) do
        if type(part) == "table" and part.type == "image" then
          local b = part._bytes or 0
          local over_count = max_count and count >= max_count
          local over_bytes = max_bytes and (total_bytes + b) > max_bytes
          if over_count or over_bytes then
            m.content[i] = { type = "text", text = OFFLOADED_IMAGE_TEXT }
            omitted = omitted + 1
          else
            count = count + 1
            total_bytes = total_bytes + b
          end
        end
      end
    end
  end
  return omitted
end

--- 图像因字节/条数预算被 offload 时的提示（同一进程内限流，避免长会话刷屏）。
--- 静默丢弃会让模型误以为「工具没生效」：至少要留一条可追溯提示。
--- @param omitted number
local _offload_notice_at = 0
local function _notice_offload(omitted)
  if omitted <= 0 then return end
  local now = vim.uv.now()
  if now - _offload_notice_at < 60000 then return end
  _offload_notice_at = now
  local msg = ("[NeoAI] 本轮请求图像预算不足，已省略 %d 张较早的图像（可用 :NeoAI 配置调大 "
    .. "ai.attachments.request_image.maxRequestBytes）"):format(omitted)
  pcall(function()
    require("NeoAI.kernel.logger").warn("[multimodal] %s", msg)
  end)
  local ok_ui, uis = pcall(vim.api.nvim_list_uis)
  if ok_ui and type(uis) == "table" and #uis > 0 then
    vim.schedule(function() pcall(vim.notify, msg, vim.log.levels.WARN) end)
  end
end

--- 构造协议中立的图像块（由 adapter 按协议编码为 image_url / source / inlineData）
--- @param ri table request_image 结果 { data, mediaType, bytes }
--- @return table
local function _neutral_image_part(ri)
  local image = require("NeoAI.utils.image")
  return {
    type = "image",
    media_type = ri.mediaType,
    base64 = image.base64_encode(ri.data),
    _bytes = ri.bytes,
  }
end

--- 构建 wire 消息（vision=true 且含图像时）
--- @param messages table
--- @param infos table 数组 { url?, bytes=number }（与 collect_refs 顺序一致）
--- @param policy table|nil
--- @return table wire
local function _build_wire(messages, infos, policy)
  local wire = {}
  local pending = {} -- 待冲刷的图像 part
  local info_i = 0
  local function flush()
    if #pending == 0 then return end
    local parts = { { type = "text", text = TOOL_RESULT_IMAGE_TEXT } }
    for _, p in ipairs(pending) do
      parts[#parts + 1] = p.part
      parts[#parts]._bytes = p.bytes
    end
    wire[#wire + 1] = { role = "user", content = parts }
    pending = {}
  end
  for _, m in ipairs(messages or {}) do
    local role = m.role
    if role == "system" or role == "assistant" then
      flush()
      wire[#wire + 1] = m
    elseif role == "user" then
      if type(m.content) == "table" then
        flush()
        local parts = {}
        for _, b in ipairs(m.content) do
          if type(b) == "table" and b.type == "text" and b.text then
            parts[#parts + 1] = { type = "text", text = b.text }
          elseif type(b) == "table" and b.type == "image" and b.attachment then
            info_i = info_i + 1
            local info = infos and infos[info_i]
            if info and info.part then
              parts[#parts + 1] = info.part
            else
              parts[#parts + 1] = { type = "text", text = OFFLOADED_IMAGE_TEXT }
            end
          end
        end
        wire[#wire + 1] = { role = "user", content = parts }
      else
        flush()
        wire[#wire + 1] = m
      end
    elseif role == "tool" then
      local ref = _image_ref_from_tool(m.content)
      if ref then
        info_i = info_i + 1
        local info = infos and infos[info_i]
        wire[#wire + 1] = { role = "tool", tool_call_id = m.tool_call_id, content = m.content or "(no output)" }
        if info and info.part then
          pending[#pending + 1] = { part = info.part, bytes = info.bytes }
        else
          pending[#pending + 1] = { part = { type = "text", text = OFFLOADED_IMAGE_TEXT }, bytes = 0 }
        end
      else
        wire[#wire + 1] = m
      end
    else
      flush()
      wire[#wire + 1] = m
    end
  end
  flush()
  local omitted = _apply_budget(wire, policy or {})
  if omitted and omitted > 0 then _notice_offload(omitted) end
  -- 清理内部字节字段（避免泄漏进 wire JSON）
  for _, m in ipairs(wire) do
    if type(m.content) == "table" then
      for _, p in ipairs(m.content) do
        if type(p) == "table" then p._bytes = nil end
      end
    end
  end
  return wire
end

-- ========== 公开 API ==========

--- 将逻辑消息物化为 wire 消息
--- @param messages table 逻辑消息（context_builder 输出）
--- @param opts table { vision: boolean, policy?: table }
--- @return Deferred resolve(wire_messages)
function M.materialize(messages, opts)
  opts = opts or {}
  if not opts.vision then
    return async.resolve(messages)
  end
  if not M.has_image(messages) then
    return async.resolve(messages)
  end
  local policy = opts.policy or attachment.request_policy()
  local refs = _collect_refs(messages)
  if #refs == 0 then
    return async.resolve(messages)
  end
  local tasks = {}
  for _, ref in ipairs(refs) do
    tasks[#tasks + 1] = attachment.read_request_image(ref, policy)
  end
  return async.all(tasks):then_(function(ris)
    local infos = {}
    for _, ri in ipairs(ris) do
      if ri and ri.data then
        infos[#infos + 1] = { part = _neutral_image_part(ri), bytes = ri.bytes }
      else
        infos[#infos + 1] = { part = nil, bytes = 0 }
      end
    end
    return _build_wire(messages, infos, policy)
  end)
end

--- 计算一组图像引用的总字节数（供 request 层预算判断）
--- @param refs table
--- @return number
function M.total_ref_bytes(refs)
  local total = 0
  for _, r in ipairs(refs or {}) do
    total = total + (r.bytes or 0)
  end
  return total
end

return M
