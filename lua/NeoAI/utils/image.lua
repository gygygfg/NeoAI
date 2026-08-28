--- 图像基础工具
--- @module NeoAI.utils.image
--- 纯 Lua，零外部依赖（可选 ImageMagick 缩略见 core/attachment）。提供：
--- - base64 编码（多模态 data URL 用）
--- - 图像媒体类型识别（magic bytes + 扩展名）
--- - 图像像素尺寸解析（PNG / JPEG / GIF / WebP 头部）
--- - 文件路径 → 媒体类型映射

local M = {}

-- ========== base64 ==========

local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

--- 字节字符串 base64 编码
--- @param data string 二进制字节串（0-255 每字节）
--- @param n number|nil 参与编码的字节数（默认 #data）
--- @return string
function M.base64_encode(data, n)
  n = n or #data
  if n <= 0 then return "" end
  local bit = require("bit")
  local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift
  local out = {}
  local i = 1
  while i <= n do
    local b1 = data:byte(i)
    local b2 = (i + 1 <= n) and data:byte(i + 1)
    local b3 = (i + 2 <= n) and data:byte(i + 2)
    local o1 = rshift(b1, 2)
    local o2 = bor(lshift(band(b1, 3), 4), b2 and rshift(b2, 4) or 0)
    out[#out + 1] = B64_CHARS:sub(o1 + 1, o1 + 1)
    out[#out + 1] = B64_CHARS:sub(o2 + 1, o2 + 1)
    if b2 then
      local o3 = bor(lshift(band(b2, 15), 2), b3 and rshift(b3, 6) or 0)
      out[#out + 1] = B64_CHARS:sub(o3 + 1, o3 + 1)
    else
      out[#out + 1] = "="
    end
    if b3 then
      local o4 = band(b3, 63)
      out[#out + 1] = B64_CHARS:sub(o4 + 1, o4 + 1)
    else
      out[#out + 1] = "="
    end
    i = i + 3
  end
  return table.concat(out)
end

--- base64 长度（含 padding）估算
--- @param n number 原始字节数
--- @return number
function M.base64_length(n)
  return math.ceil(n / 3) * 4
end

-- ========== 媒体类型识别 ==========

--- 支持的图像媒体类型
--- @type string[]
M.IMAGE_MEDIA_TYPES = { "image/png", "image/jpeg", "image/webp", "image/gif" }

--- 扩展名 → 媒体类型
local EXT_MEDIA = {
  png = "image/png",
  jpg = "image/jpeg",
  jpeg = "image/jpeg",
  webp = "image/webp",
  gif = "image/gif",
}

--- magic bytes → 媒体类型
local function _magic_media_type(bytes)
  if not bytes or #bytes == 0 then return nil end
  if #bytes >= 8 and bytes:sub(1, 8) == "\137PNG\r\n\26\n" then return "image/png" end
  if #bytes >= 2 and bytes:sub(1, 2) == "\255\216" then return "image/jpeg" end
  if #bytes >= 4 and bytes:sub(1, 4) == "GIF8" then return "image/gif" end
  if #bytes >= 12 and bytes:sub(1, 4) == "RIFF" and bytes:sub(9, 12) == "WEBP" then return "image/webp" end
  return nil
end

--- 从扩展名获取媒体类型
--- @param path string
--- @return string|nil
function M.media_type_for_path(path)
  local ext = (path or ""):match("%.([^%.\\/]+)$") or ""
  return EXT_MEDIA[ext:lower()]
end

--- 从 magic bytes 验证媒体类型（不受扩展名声明影响）
--- @param bytes string
--- @return string|nil
function M.detect_media_type(bytes)
  return _magic_media_type(bytes)
end

--- 媒体类型 → 扩展名
--- @param media_type string
--- @return string
function M.extension_for_media_type(media_type)
  if media_type == "image/png" then return "png" end
  if media_type == "image/jpeg" then return "jpg" end
  if media_type == "image/webp" then return "webp" end
  if media_type == "image/gif" then return "gif" end
  return "img"
end

-- ========== 尺寸解析 ==========

local bit = require("bit")
local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift

--- 读取大端 uint16/uint24/uint32
local function _be16(s, i) return bor(lshift(s:byte(i), 8), s:byte(i + 1)) end
local function _be24(s, i) return bor(lshift(s:byte(i), 16), lshift(s:byte(i + 1), 8), s:byte(i + 2)) end
local function _be32(s, i)
  return bor(lshift(s:byte(i), 24), lshift(s:byte(i + 1), 16), lshift(s:byte(i + 2), 8), s:byte(i + 3))
end

--- 解析 PNG 尺寸（IHDR）
--- @param bytes string
--- @return number, number|nil
local function _png_dim(bytes)
  if #bytes < 24 then return nil end
  -- 签名 8 字节；IHDR: length(4)+type(4)+width(4)+height(4)
  if bytes:sub(13, 16) ~= "IHDR" then return nil end
  return _be32(bytes, 17), _be32(bytes, 21)
end

--- 解析 GIF 尺寸（逻辑屏幕描述符）：header 6 字节 + 宽高小端各 2 字节
local function _gif_dim(bytes)
  if #bytes < 10 then return nil end
  -- GIF87a/GIF89a[1-6]；width[7-8] LE；height[9-10] LE
  local w = bytes:byte(7) + lshift(bytes:byte(8), 8)
  local h = bytes:byte(9) + lshift(bytes:byte(10), 8)
  return w, h
end

--- 解析 WebP 尺寸
--- RIFF[1-4]/size[5-8]/WEBP[9-12]/chunk4cc[13-16]/size[17-20]/payload[21..]
--- @return number, number|nil
local function _webp_dim(bytes)
  if #bytes < 27 then return nil end
  local chunk = bytes:sub(13, 16)
  if chunk == "VP8X" then
    return _be24(bytes, 25) + 1, _be24(bytes, 28) + 1
  end
  if chunk == "VP8L" then
    if bytes:byte(21) ~= 0x2F then return nil end
    local b1, b2, b3, b4 = bytes:byte(22), bytes:byte(23), bytes:byte(24), bytes:byte(25)
    local w1 = b1 + lshift(band(b2, 0x3F), 8)
    local h1 = rshift(b2, 6) + lshift(b3, 2) + lshift(band(b4, 0x0F), 10)
    return w1 + 1, h1 + 1
  end
  if chunk == "VP8 " then
    -- 帧头：payload[1-3] 帧 tag；[4-6] 起始码 0x9D 0x01 0x2A
    if bytes:byte(24) ~= 0x9D or bytes:byte(25) ~= 0x01 or bytes:byte(26) ~= 0x2A then return nil end
    local b27, b28, b29, b30 = bytes:byte(27), bytes:byte(28), bytes:byte(29), bytes:byte(30)
    local w = b27 + lshift(band(b28, 0x3F), 8)
    local h = rshift(b28, 6) + lshift(b29, 2) + lshift(band(b30, 0x0F), 10)
    return w, h
  end
  return nil, nil
end

--- 解析 JPEG 尺寸（扫描 SOFn 帧头）
local function _jpeg_dim(bytes)
  local n = #bytes
  if n < 4 or bytes:sub(1, 2) ~= "\255\216" then return nil end
  local i = 3
  while i < n do
    local byte = bytes:byte(i)
    if byte ~= 255 then i = i + 1 else
      local marker = bytes:byte(i + 1)
      if not marker then return nil end
      if marker == 0xFF then i = i + 1 else
        i = i + 2
        if marker == 0xD8 or marker == 0xD9 or marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7) then
          -- standalone marker（无长度字段）
        else
          if i > n - 1 then return nil end
          local len = _be16(bytes, i)
          if len < 2 or i + len > n + 1 then return nil end
          if (marker >= 0xC0 and marker <= 0xCF)
            and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
            -- precision(1)@i+2；height(2 BE)@i+3；width(2 BE)@i+5
            if i + 7 <= n + 1 then
              return _be16(bytes, i + 5), _be16(bytes, i + 3)
            end
            return nil
          end
          i = i + len
        end
      end
    end
  end
  return nil
end

--- 解析图像尺寸（按媒体类型）
--- @param bytes string
--- @param media_type string|nil 缺省时按 magic 自动识别
--- @return number width, number height, string|nil detected_media_type
function M.parse_dimensions(bytes, media_type)
  if not bytes or #bytes == 0 then return nil, nil, nil end
  media_type = media_type or M.detect_media_type(bytes)
  if media_type == nil then return nil, nil, nil end
  local w, h
  if media_type == "image/png" then
    w, h = _png_dim(bytes)
  elseif media_type == "image/gif" then
    w, h = _gif_dim(bytes)
  elseif media_type == "image/jpeg" then
    w, h = _jpeg_dim(bytes)
  elseif media_type == "image/webp" then
    w, h = _webp_dim(bytes)
  end
  return w, h, media_type
end

return M
