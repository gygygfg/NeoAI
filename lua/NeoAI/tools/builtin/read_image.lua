--- read_image 工具
--- @module NeoAI.tools.builtin.read_image
--- 模型侧读图入口：读取 PNG/JPEG/WebP/GIF 文件，持久化进附件存储，
--- 返回引用（会话只存引用，不存字节）；发送请求时经 core.model.content 解析为
--- data URL 注入。约治越严——先门禁（当前模型声明图像输入 / 允许的类型 / 像素与字节
--- 上限）再读盘，避免在无意义时读取大图。
--- 支持两种来源：
--- 1. 本地路径：按扩展名声明媒体类型，read 后按 magic bytes 校验一致性；
--- 2. http(s) URL：用 curl 下载到 /tmp 临时文件（不设执行权限），读取完成后删除。

local work = require("NeoAI.utils.work")
local fs = require("NeoAI.utils.fs")
local image = require("NeoAI.utils.image")
local attachment = require("NeoAI.core.attachment.attachment")
local helpers = require("NeoAI.tools.builtin.tool_helpers")
local async = require("NeoAI.utils.async")

local M = {}

-- ========== 私有常量 ==========

local MAX_READ_BYTES = 64 * 1024 * 1024 -- 单次读取字节兜底（防 OOM）
local MAX_DOWNLOAD_SECONDS = 30 -- curl --max-time 兜底（防挂起）

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

--- 规范化错误对象为可读字符串
--- @param e any
--- @return string
local function _err_msg(e)
  if type(e) == "table" and e.message then return e.message end
  return tostring(e)
end

--- 判断路径是否为 http(s) URL
--- @param path string
--- @return boolean
local function _is_url(path)
  return type(path) == "string" and (path:lower():match("^https?://") ~= nil)
end

--- 生成 /tmp 下的临时图像文件路径（普通文件，无执行权限）
--- @return string
local function _make_temp_image_path()
  return ("/tmp/neoai_img_%d_%d.img"):format(vim.fn.getpid(), vim.fn.rand())
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

--- 摄入一张本地（或已下载到本地的）图像：读盘 → 空/超限 → magic → 允许类型 →
--- declared 一致性 → save_image。封装为 Deferred，便于 URL 分支链式处理并统一清理。
--- @param target_path string 磁盘上已存在的文件路径
--- @param declared_media string|nil 扩展名声明的媒体类型（本地路径提供；URL 来源传 nil，跳过一致性）
--- @param display_path string 用于信封与展示的路径（本地为绝对路径，URL 场景为原始 URL）
--- @return Deferred resolve(ref)
local function _ingest(target_path, declared_media, display_path)
  local limits = attachment.image_limits()
  -- 读盘（线程池）
  return work.run(_read_binary, target_path):then_(function(data)
    if not data or #data == 0 then
      error(("读取到空文件: %s"):format(target_path))
    end
    if #data > MAX_READ_BYTES then
      error(("文件超过单次读取上限 %d 字节: %s"):format(MAX_READ_BYTES, target_path))
    end
    -- magic 校验（否则扩展名声明与实际不符）
    local detected = image.detect_media_type(data)
    if not detected then
      error(("%s 的字节数据不是受支持的图像格式（PNG/JPEG/WebP/GIF）"):format(target_path))
    end
    if not vim.tbl_contains(limits.mediaTypes or image.IMAGE_MEDIA_TYPES, detected) then
      error(("%s 不被本部署允许的图像类型包含"):format(detected))
    end
    if declared_media and declared_media ~= detected then
      error(("扩展名声明 %s 但字节实际为 %s；请将文件名改为匹配其真实格式（转换后再读）"):format(declared_media, detected))
    end

    -- 持久化附件（内容寻址；先于返回，保证引用指向已提交对象）
    return attachment.save_image({
      data = data,
      mediaType = detected,
      name = fs.basename(display_path or target_path),
    }):then_(function(ref)
      return ref
    end, function(serr)
      error(_err_msg(serr))
    end)
  end)
end

--- 用 curl 将 URL 下载到 /tmp 临时文件（普通文件，无执行权限）。
--- 非阻塞（jobstart）；成功写出文件后 resolve 临时文件路径，失败 reject 并清理。
--- @param url string
--- @param max_bytes number --max-filesize 上限（字节）
--- @return Deferred resolve(tmp_path string)
local function _download_to_temp(url, max_bytes)
  local d = async.Deferred.new()
  local tmp = _make_temp_image_path()
  local stderr_chunks = {}
  local cmd = {
    "curl", "-sSL", "--fail", "--max-time", tostring(MAX_DOWNLOAD_SECONDS),
    "--max-filesize", tostring(max_bytes), "-o", tmp, "--", url,
  }
  local job_id = vim.fn.jobstart(cmd, {
    stderr_buffered = true,
    on_stdout = function() end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line and line ~= "" then stderr_chunks[#stderr_chunks + 1] = line end
        end
      end
    end,
    on_exit = function(_, code)
      if code == 0 and vim.fn.filereadable(tmp) == 1 then
        d:resolve(tmp)
      else
        local msg = "下载失败: " .. url
        if #stderr_chunks > 0 then
          msg = msg .. " (" .. table.concat(stderr_chunks, " ") .. ")"
        end
        pcall(vim.fn.delete, tmp)
        d:reject({ kind = "download", message = msg })
      end
    end,
  })
  if job_id == 0 then
    pcall(vim.fn.delete, tmp)
    d:reject({ kind = "download", message = "无法启动 curl 下载: " .. url })
  end
  return d
end

-- ========== 工具定义 ==========

local read_image = helpers.define_tool(
  "read_image",
  "读取一张 PNG/JPEG/WebP/GIF 图片，把图像本身（而非路径描述）注入对话，供多模态模型分析图像内容（截图、图表、示意图、OCR 等）。可传本地文件路径或 http(s) 图片 URL（URL 会下载到临时目录，读取完成后自动删除）。需当前模型支持图像输入。可并发读取多个独立文件。",
  {
    type = "object",
    properties = {
      file_path = { type = "string", description = "图像文件路径，或 http(s) 图片 URL" },
    },
    required = { "file_path" },
  },
  function(args, on_success, on_error, ctx)
    local file_path = args.file_path
    if type(file_path) ~= "string" or file_path:gsub("%s", "") == "" then
      on_error("read_image 需要非空的 file_path")
      return
    end

    -- 门禁：一切在磁盘/网络 I/O 之前，任何拒绝都不读盘、不发起网络请求
    local ok, err = _assert_vision_capable(ctx)
    if not ok then
      on_error(err)
      return
    end

    local limits = attachment.image_limits()
    local intended = limits.maxImageBytes or 20 * 1024 * 1024

    -- ===== URL 分支：下载到 /tmp，读取完成后删除 =====
    if _is_url(file_path) then
      local tmp_to_clean = nil
      _download_to_temp(file_path, intended):then_(function(tmp)
        -- 下载成功后摄入（declared=nil：跳过扩展名一致性，格式由 magic 判定）
        tmp_to_clean = tmp
        return _ingest(tmp, nil, file_path)
      end):then_(function(ref)
        on_success({
          path = file_path,
          text = _format_envelope(file_path, ref),
          image = ref,
        })
      end, function(err)
        on_error(_err_msg(err))
      end):finally(function()
        -- 成功/失败均清理临时文件（成功路径 set 了 tmp_to_clean；失败路径 _download_to_temp 已自清）
        if tmp_to_clean then
          pcall(vim.fn.delete, tmp_to_clean)
        end
      end)
      return
    end

    -- ===== 本地路径分支 =====
    local media_type = image.media_type_for_path(file_path)
    if not media_type then
      on_error(("read_image 仅接受 PNG/JPEG/WebP/GIF 路径：%s"):format(file_path))
      return
    end
    if not vim.tbl_contains(limits.mediaTypes or image.IMAGE_MEDIA_TYPES, media_type) then
      on_error(("%s 不被本部署允许的图像类型包含"):format(media_type))
      return
    end

    local abs_path = vim.fn.fnamemodify(file_path, ":p")
    if vim.fn.filereadable(abs_path) ~= 1 then
      on_error("文件不可读: " .. abs_path)
      return
    end

    _ingest(abs_path, media_type, abs_path):then_(function(ref)
      on_success({
        path = abs_path,
        text = _format_envelope(abs_path, ref),
        image = ref,
      })
    end, function(err)
      on_error(_err_msg(err))
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
