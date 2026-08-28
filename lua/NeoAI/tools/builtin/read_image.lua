--- read_image 工具
--- @module NeoAI.tools.builtin.read_image
--- 模型侧读图入口：读取 PNG/JPEG/WebP/GIF 文件，持久化进附件存储，
--- 返回引用（会话只存引用，不存字节）；发送请求时经 core.model.content 解析为
--- data URL 注入。约治越严——先门禁（当前模型声明图像输入 / 允许的类型 / 像素与字节
--- 上限）再读盘，避免在无意义时读取大图。

local work = require("NeoAI.utils.work")
local fs = require("NeoAI.utils.fs")
local image = require("NeoAI.utils.image")
local attachment = require("NeoAI.core.attachment.attachment")
local helpers = require("NeoAI.tools.builtin.tool_helpers")

local M = {}

-- ========== 私有常量 ==========

local MAX_READ_BYTES = 64 * 1024 * 1024 -- 单次读取字节兜底（防 OOM）

-- ========== 私有函数 ==========

--- 线程内读二进制文件
--- @param path string
--- @return string
local function _read_binary(path)
  local f = io.open(path, "rb")
  if not f then error("无法打开文件: " .. path) end
  local data = f:read("*a")
  f:close()
  return data
end

--- 校验当前 route 是否声明图像输入（vision model）
--- @param ctx table { agent }
--- @return boolean, string|nil
local function _assert_vision_capable(ctx)
  if not ctx or not ctx.agent then return false, "无法解析当前模型 route" end
  local agent = ctx.agent
  local model = agent.model
  local provider = (agent.config and agent.config.provider)
  if not model then return false, "无法解析当前模型（未选择模型）" end
  if not attachment.enabled() then
    return false, "附件存储未启用，无法读取图像"
  end
  if not attachment.supports_image(model, provider) then
    return false, ("模型 %s 未声明支持图像输入；请切换到多模态模型（如 deepseek-v4-flash-vision-exp）后再调用 read_image"):format(model)
  end
  return true
end

--- 组装模型侧信封文本（路径 + 尺寸 + 字节 + 缩略提示）
--- @param path string
--- @param ref table
--- @return string
local function _format_envelope(path, ref)
  local lines = {
    "<path>" .. path .. "</path>",
    "<type>image</type>",
    "<content>",
  }
  local head = string.format("%s image", ref.mediaType)
  if ref.width and ref.height then
    head = head .. string.format(", %dx%d px", ref.width, ref.height)
  end
  head = head .. (", %d bytes"):format(ref.bytes)
  lines[#lines + 1] = head
  lines[#lines + 1] = "</content>"
  return table.concat(lines, "\n")
end

-- ========== 工具定义 ==========

local read_image = helpers.define_tool(
  "read_image",
  "读取一张 PNG/JPEG/WebP/GIF 图片文件，把图像本身（而非路径描述）注入对话，供多模态模型分析图像内容（截图、图表、示意图、OCR 等）。需当前模型支持图像输入。可并发读取多个独立文件。",
  {
    type = "object",
    properties = {
      file_path = { type = "string", description = "图像文件路径" },
    },
    required = { "file_path" },
  },
  function(args, on_success, on_error, ctx)
    local file_path = args.file_path
    if type(file_path) ~= "string" or file_path:gsub("%s", "") == "" then
      on_error("read_image 需要非空的 file_path")
      return
    end

    -- 门禁：一切在磁盘 I/O 之前，任何拒绝都不读盘
    local ok, err = _assert_vision_capable(ctx)
    if not ok then
      on_error(err)
      return
    end

    local media_type = image.media_type_for_path(file_path)
    if not media_type then
      on_error(("read_image 仅接受 PNG/JPEG/WebP/GIF 路径：%s"):format(file_path))
      return
    end
    local limits = attachment.image_limits()
    if not vim.tbl_contains(limits.mediaTypes or image.IMAGE_MEDIA_TYPES, media_type) then
      on_error(("%s 不被本部署允许的图像类型包含"):format(media_type))
      return
    end

    local abs_path = vim.fn.fnamemodify(file_path, ":p")
    if vim.fn.filereadable(abs_path) ~= 1 then
      on_error("文件不可读: " .. abs_path)
      return
    end

    -- 读盘（线程池）
    work.run(_read_binary, abs_path):then_(function(data)
      if not data or #data == 0 then
        on_error(("读取到空文件: %s"):format(abs_path))
        return
      end
      if #data > MAX_READ_BYTES then
        on_error(("文件超过单次读取上限 %d 字节: %s"):format(MAX_READ_BYTES, abs_path))
        return
      end
      -- magic 校验（否则扩展名声明与实际不符）
      local detected = image.detect_media_type(data)
      if not detected then
        on_error(("%s 的字节数据不是受支持的图像格式（PNG/JPEG/WebP/GIF）"):format(abs_path))
        return
      end
      if detected ~= media_type then
        on_error(("扩展名声明 %s 但字节实际为 %s；请将文件名改为匹配其真实格式（转换后再读）"):format(media_type, detected))
        return
      end

      -- 持久化附件（内容寻址；先于返回，保证引用指向已提交对象）
      attachment.save_image({ data = data, mediaType = detected, name = fs.basename(abs_path) }):then_(function(ref)
        on_success({
          path = abs_path,
          text = _format_envelope(abs_path, ref),
          image = ref,
        })
      end, function(serr)
        on_error(serr and serr.message or ("无法保存图像附件: %s"):format(tostring(serr)))
      end)
    end, function(err)
      on_error(err and err.message or tostring(err))
    end)
  end,
  { category = "file", approval = { auto_allow = true } }
)

--- 获取工具列表
--- @return table 数组
function M.get_tools()
  return { read_image }
end

return M
