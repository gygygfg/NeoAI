--- 持久化附件存储
--- @module NeoAI.core.attachment.attachment
--- 对齐 deepseek-harness 的 durable attachment 语义：
--- - 不可变、内容寻址（sha256）存储，会话消息只存引用，不存字节；
--- - 统一的准入限制（媒体类型 / 字节 / 像素 / 数量）；
--- - 请求期 request-image：按模型 route 的像素 / 字节预算产出一次可序列化的图像
---   （可选 ImageMagick 缩略，缺省直传原始字节给 provider 自行处理尺寸）；
--- - 是否支持图像输入（vision model 门禁）。
--- 依赖：utils + kernel(config/logger) + core.model（无反向）。

local async = require("NeoAI.utils.async")
local work = require("NeoAI.utils.work")
local fs = require("NeoAI.utils.fs")
local image = require("NeoAI.utils.image")
local config_store = require("NeoAI.kernel.config_store")
local logger = require("NeoAI.kernel.logger")

local M = {}

-- ========== 私有状态 ==========

local _root = nil
local _downscale_tool = nil -- 已探测的 ImageMagick 可执行名（nil = 无）

-- ========== 私有常量 ==========

local DEFAULT_LIMITS = {
  maxImageBytes = 20 * 1024 * 1024, -- 单图字节上限（原始）
  maxImagesPerMessage = 16,
  maxMessageImageBytes = 40 * 1024 * 1024,
  maxImagePixels = 50000000, -- 解码后像素上限（未缩略时粗估强拒）
  maxImageDimension = 8000, -- 长边上限
}

local DEFAULT_REQUEST_POLICY = {
  maxPixels = 640000, -- 单请求图像总像素预算
  maxBytes = 1024 * 1024, -- 单请求图像编码字节上限（超过且无法缩略则 offload）
  maxImagesPerRequest = 8, -- 单请求最多保留图像数（超出丢最旧）
  maxRequestBytes = 20 * 1024 * 1024, -- 单个请求的全部图像累计（超出丢最旧）
  maxRequestImages = 600, -- 与 provider 上限对齐的深层兜底
}

-- ========== 私有函数 ==========

local function _cfg()
  return config_store.get("ai.attachments") or {}
end

--- 附件根目录（可被配置覆盖）
--- @return string
local function _root_dir()
  if _root then return _root end
  local base = vim.fn.stdpath("cache") .. "/NeoAI/attachments"
  _root = _cfg().path or base
  return _root
end

--- 按 attachmentId 生成目录/基础路径（sha256 前 2 位分桶）
--- @param attachment_id string
--- @return string
local function _id_path(attachment_id)
  local h = (attachment_id or ""):gsub("^sha256:", "")
  return fs.join(_root_dir(), h:sub(1, 2), h)
end

--- attachmentId（sha256 前缀）
--- @param hash string
--- @return string
local function _attachment_id(hash)
  return "sha256:" .. hash
end

--- 计算内容哈希（sha256；失败时退化为简易 FNV，仅用于本地寻址）
--- @param data string
--- @return string
local function _hash(data)
  local ok, h = pcall(vim.fn.sha256, data)
  if ok and h and h ~= "" then return h end
  local bit = require("bit")
  local hash = 2166136261
  for i = 1, #data do
    hash = bit.bxor(hash, data:byte(i))
    hash = (hash * 16777619) % 4294967296
  end
  return string.format("%08x%08x", hash, #data)
end

--- 线程内读取二进制文件
--- @param path string
--- @return string
local function _read_binary(path)
  local f = io.open(path, "rb")
  if not f then error("无法打开附件: " .. path) end
  local data = f:read("*a")
  f:close()
  return data
end

--- 线程内写二进制文件
--- @param path string
--- @param data string
--- @return string
local function _write_binary(path, data)
  local f = io.open(path, "wb")
  if not f then error("无法写入附件: " .. path) end
  f:write(data)
  f:close()
  return "ok"
end

--- 线程内写文本文件（meta json 由主线程编码后传入原始字符串）
--- @param path string
--- @param text string
--- @return string
local function _write_text(path, text)
  local f = io.open(path, "w")
  if not f then error("无法写入附件 meta: " .. path) end
  f:write(text)
  f:close()
  return "ok"
end

--- 读取 meta json
--- @param path string
--- @return table|nil
local function _read_meta(path)
  local json = require("NeoAI.utils.json")
  local data = fs.read_file(path)
  if not data then return nil end
  local ok, obj = pcall(json.decode, data)
  if not ok or type(obj) ~= "table" then return nil end
  return obj
end

--- 权限目录准备（原始格式目录）
--- @param paths table 需确保的目录
local function _ensure_dirs(paths)
  for _, p in ipairs(paths) do
    fs.ensure_dir(p)
  end
end

--- 是否支持某模型输入图像
--- @param model_id string
--- @param provider string|nil
--- @return boolean
function M.supports_image(model_id, provider)
  if not model_id then return false end
  local cfg = _cfg()
  local full = (provider and (provider .. ":" .. model_id)) or model_id
  local md = model_id:lower()
  for _, m in ipairs(cfg.vision_models or {}) do
    if type(m) == "string" then
      if m == model_id or m == full then return true end
      local p, mid = m:match("^([^:]+):(.+)$")
      if mid == model_id then return true end
    end
  end
  -- 启发式：常见视觉模型命名特征（可配置）
  for _, pat in ipairs(cfg.vision_model_heuristics or { "vision", "-vl", "4o", "gemini" }) do
    if md:find(pat, 1, true) then return true end
  end
  return false
end

--- 准入上限（config 合并默认）
--- @return table
function M.image_limits()
  local cfg = _cfg()
  local lim = vim.tbl_extend("force", vim.deepcopy(DEFAULT_LIMITS), cfg.limits or {})
  if cfg.media_types then lim.mediaTypes = cfg.media_types end
  return lim
end

--- 请求图像策略（config 合并默认）
--- @return table
function M.request_policy()
  local cfg = _cfg()
  return vim.tbl_extend("force", vim.deepcopy(DEFAULT_REQUEST_POLICY), cfg.request_image or {})
end

--- 附件存储是否启用
--- @return boolean
function M.enabled()
  return _cfg().enabled ~= false
end

--- PNG 是否含 alpha（颜色类型 4/6）
local function _png_has_alpha(bytes)
  if bytes:sub(1, 8) ~= "\137PNG\r\n\26\n" then return false end
  local ct = bytes:byte(26)
  return ct == 4 or ct == 6
end

--- JPEG/WebP/GIF 的 alpha 探测（保守为 false；WebP VP8X 见 alpha 标志）
local function _image_has_alpha(bytes, media_type)
  if media_type == "image/png" then return _png_has_alpha(bytes) end
  if media_type == "image/webp" and bytes:sub(13, 16) == "VP8X" then
    local flags = bytes:byte(21)
    return flags ~= nil and flags % 2 == 1
  end
  if media_type == "image/gif" then return true end -- 透明帧常见，保守标记
  return false
end

--- 探测 ImageMagick 可执行名（magick 优先，其次 convert）
--- @return string|nil
function M.downscale_tool()
  if _downscale_tool == nil then
    if vim.fn.executable("magick") == 1 then
      _downscale_tool = "magick"
    elseif vim.fn.executable("convert") == 1 then
      _downscale_tool = "convert"
    else
      _downscale_tool = false
    end
  end
  return _downscale_tool or nil
end

--- 用 ImageMagick 缩放到目标像素预算（best-effort；失败返回 nil）
--- 同步执行：仅在存在 magick/convert 且确需缩放大图时触发，属罕见路径。
--- @param data string 原始字节
--- @param media_type string
--- @param width number|nil
--- @param height number|nil
--- @param max_pixels number
--- @return string|nil 缩放后的 PNG 字节
function M.downscale_sync(data, media_type, width, height, max_pixels)
  local tool = M.downscale_tool()
  if not tool or not width or not height then return nil end
  if width * height <= max_pixels then return nil end -- 无需缩放
  local scale = math.sqrt(max_pixels / (width * height))
  local tw = math.max(1, math.floor(width * scale))
  local th = math.max(1, math.floor(height * scale))
  -- 统一经沙箱运行：以共享目录下的临时文件承载输入/输出，写入经 overlay 暂存为候选。
  -- 属罕见 best-effort 路径：同步等待其完成；失败（含沙箱拒绝）返回 nil，放弃缩放。
  local sandbox_exec = require("NeoAI.sandbox.exec")
  local shared = sandbox_exec.ensure_shared()
  local stamp = ("%d_%d"):format(vim.fn.getpid(), vim.fn.rand())
  local inp = shared .. "/ds_in_" .. stamp
  local outp = shared .. "/ds_out_" .. stamp .. ".png"
  local wf = io.open(inp, "wb")
  if not wf then return nil end
  wf:write(data)
  wf:close()
  local argv = { tool, inp, "-resize", string.format("%dx%d", tw, th), "-strip", outp }
  local d = sandbox_exec.run(argv, {
    name = "downscale", writable_roots = { shared }, network = false, timeout_ms = 30000,
  })
  vim.wait(30000, function() return not d:is_pending() end, 20)
  local result = d._value
  local out = nil
  if d:is_resolved() and result and result.code == 0 then
    local read_target = require("NeoAI.sandbox.candidate").read_path(outp) or outp
    local rf = io.open(read_target, "rb")
    if rf then out = rf:read("*a"); rf:close() end
  end
  pcall(os.remove, inp)
  pcall(os.remove, outp)
  if not out or out == "" then return nil end
  return out
end

--- 保存一张图像附件（准入 + 内容寻址 + 持久化）
--- @param opts table { data, mediaType, name? }
--- @return Deferred resolve(ref)
function M.save_image(opts)
  opts = opts or {}
  local data = opts.data
  if not data or #data == 0 then
    return async.reject({ kind = "attachment", message = "图像数据为空" })
  end
  local limits = M.image_limits()
  local detected = image.detect_media_type(data)
  if not detected then
    return async.reject({ kind = "attachment", message = "字节数据不是受支持的图像格式（PNG/JPEG/WebP/GIF）" })
  end
  local declared = opts.mediaType
  if declared and declared ~= detected then
    return async.reject({ kind = "attachment", message = ("扩展名声明 %s 但实际为 %s"):format(declared, detected) })
  end
  if not vim.tbl_contains(limits.mediaTypes or image.IMAGE_MEDIA_TYPES, detected) then
    return async.reject({ kind = "attachment", message = detected .. " 不在本部署允许的图像类型内" })
  end
  if #data > limits.maxImageBytes then
    return async.reject({ kind = "attachment", message = ("图像超过单图字节上限（%d 字节）"):format(limits.maxImageBytes) })
  end

  local hash = _hash(data)
  local attachment_id = _attachment_id(hash)
  local dir = _id_path(attachment_id)
  local ext = image.extension_for_media_type(detected)

  -- 读取既有 meta（可能已存在 → 幂等返回）
  local meta_path = fs.join(dir, "meta.json")
  local existing = _read_meta(meta_path)
  if existing and existing.attachmentId == attachment_id then
    return async.resolve(existing)
  end

  local w, h = image.parse_dimensions(data, detected)
  if w and (w > limits.maxImageDimension or h and h > limits.maxImageDimension) then
    return async.reject({ kind = "attachment", message = ("图像长边超过 %dpx 上限"):format(limits.maxImageDimension) })
  end
  if w and h and w * h > limits.maxImagePixels then
    return async.reject({ kind = "attachment", message = ("图像像素超过 %d 上限：%dx%d"):format(limits.maxImagePixels, w, h) })
  end

  local ref = {
    attachmentId = attachment_id,
    mediaType = detected,
    bytes = #data,
    width = w,
    height = h,
    name = opts.name,
  }
  local meta = {
    attachmentId = attachment_id,
    mediaType = detected,
    bytes = #data,
    width = w,
    height = h,
    name = opts.name,
    hash = hash,
    ext = ext,
    data_url_ready = false,
  }

  -- 磁盘写入（线程池）
  _ensure_dirs({ dir })
  local enc_ok, meta_str = pcall(function() return require("NeoAI.utils.json").encode(meta) end)
  if not enc_ok then
    return async.reject({ kind = "attachment", message = "附件 meta 编码失败" })
  end
  local job = async.all({
    work.run(_write_binary, fs.join(dir, "original." .. ext), data),
    work.run(_write_text, meta_path, meta_str),
  })
  return job:then_(function()
    logger.info("[attachment] 已保存图像 %s (%d 字节, %s)", attachment_id, #data, detected)
    return ref
  end)
end

--- 按 attachmentId 读取原始字节
--- @param attachment_id string
--- @return Deferred resolve(string)
function M.read_original(attachment_id)
  local dir = _id_path(attachment_id)
  local meta = _read_meta(fs.join(dir, "meta.json"))
  if not meta then
    return async.reject({ kind = "attachment", message = "附件不存在: " .. tostring(attachment_id) })
  end
  return work.run(_read_binary, fs.join(dir, "original." .. meta.ext))
end

--- 计算 request-image 的 variantId（确定性：attachment + 像素 + 字节预算）
--- @param ref table
--- @param policy table
--- @return string
function M.variant_id(ref, policy)
  return ("%s:p%d:b%d"):format(ref.attachmentId, policy.maxPixels, policy.maxBytes)
end

--- 读取/生成某附件的 request-image（带磁盘缓存）
--- @param ref table { attachmentId, mediaType, bytes, width, height, name? }
--- @param policy table { maxPixels, maxBytes }
--- @return Deferred resolve(request_image|nil) nil = 因预算无法表示（调用方应降级为文本）
function M.read_request_image(ref, policy)
  policy = policy or M.request_policy()
  local d = async.Deferred.new()
  M._request_image_impl(ref, policy):then_(function(ri)
    d:resolve(ri)
  end, function(err)
    -- 表示失败不回题主流程：记录并降级
    logger.warn("[attachment] request-image 生成失败: %s", tostring(err and err.message or err))
    d:resolve(nil)
  end)
  return d
end

--- request-image 实现（含缓存读写）
--- @param ref table
--- @param policy table
--- @return Deferred resolve(request_image|nil)
function M._request_image_impl(ref, policy)
  if not ref or not ref.attachmentId then return async.resolve(nil) end
  local variant = M.variant_id(ref, policy)
  local dir = _id_path(ref.attachmentId)
  local meta = _read_meta(fs.join(dir, "meta.json"))
  if not meta then return async.resolve(nil) end
  local rpath = fs.join(dir, "request_" .. variant .. ".bin")
  local vmeta_path = fs.join(dir, "request_" .. variant .. ".json")
  local vmeta = _read_meta(vmeta_path)
  if vmeta and fs.exists(rpath) then
    -- 命中缓存：直接读取
    return work.run(_read_binary, rpath):then_(function(bytes)
      if not bytes or bytes == "" then return nil end
      return {
        variantId = variant,
        attachment = ref,
        data = bytes,
        mediaType = vmeta.mediaType,
        bytes = #bytes,
        width = vmeta.width,
        height = vmeta.height,
        hasAlpha = vmeta.hasAlpha == true,
        space = "srgb",
        depth = "uchar",
      }
    end)
  end

  -- 需要生成：读取原始
  return work.run(_read_binary, fs.join(dir, "original." .. meta.ext)):then_(function(orig)
    local w = meta.width or ref.width
    local h = meta.height or ref.height
    local scale_to_policy = function(data, mt, ww, hh)
      -- 优先缩到像素预算；无缩略工具或缩略失败则直传原图（允许 provider 自行处理），
      -- 仅当原始字节超出字节预算时降级。
      if ww and hh and (ww * hh > policy.maxPixels) then
        local small = M.downscale_sync(data, mt, ww, hh, policy.maxPixels)
        if small and #small > 0 then
          local dw, dh = image.parse_dimensions(small, "image/png")
          return async.resolve({ data = small, mediaType = "image/png", use = true,
            width = dw or ww, height = dh or hh, hasAlpha = _png_has_alpha(small) })
        end
      end
      return async.resolve({ data = data, mediaType = mt, use = #data <= policy.maxBytes,
        width = ww, height = hh, hasAlpha = _image_has_alpha(data, mt) })
    end
    return scale_to_policy(orig, meta.mediaType or ref.mediaType, w, h):then_(function(res)
      if not res or not res.use then return nil end
      -- 缓存生成的 request-image
      _ensure_dirs({ dir })
      local enc_ok, vmeta_str = pcall(function() return require("NeoAI.utils.json").encode({
        mediaType = res.mediaType,
        width = res.width,
        height = res.height,
        hasAlpha = res.hasAlpha == true,
        bytes = #res.data,
      }) end)
      if not enc_ok then return nil end
      return async.all({
        work.run(_write_binary, rpath, res.data),
        work.run(_write_text, vmeta_path, vmeta_str),
      }):then_(function()
        return {
          variantId = variant,
          attachment = ref,
          data = res.data,
          mediaType = res.mediaType,
          bytes = #res.data,
          width = res.width,
          height = res.height,
          hasAlpha = res.hasAlpha == true,
          space = "srgb",
          depth = "uchar",
        }
      end)
    end)
  end)
end

--- 生成 data URL
--- @param request_image table
--- @return string
function M.data_url(request_image)
  if not request_image or not request_image.data then return nil end
  return "data:" .. request_image.mediaType .. ";base64," .. image.base64_encode(request_image.data)
end

--- 依据引用解析 request-image 的 data URL
--- @param ref table
--- @param policy table|nil
--- @return Deferred resolve(string|nil)
function M.resolve_data_url(ref, policy)
  return M.read_request_image(ref, policy):then_(function(ri)
    if not ri then return nil end
    return M.data_url(ri)
  end)
end

--- 重置（测试用）
function M.reset()
  _root = nil
  _downscale_tool = nil
end

return M
