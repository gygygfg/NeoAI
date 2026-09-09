--- 多模态 / 附件测试
--- @module NeoAI.tests.test_multimodal

local tests = require("NeoAI.tests")
local config_store = require("NeoAI.kernel.config_store")

-- 每套件前：把附件目录指向隔离的临时路径，并清空 attachment 的模块级缓存
tests.suite("multimodal", function(_, it, before_each)
  before_each(function()
    config_store.set("ai.attachments.path", "/tmp/opencode/neoai_att")
    os.execute("rm -rf /tmp/opencode/neoai_att")
    require("NeoAI.core.attachment.attachment").reset()
  end)

  local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local function b64decode(s)
    local map = {}
    for i = 1, #B64 do map[B64:sub(i, i)] = i - 1 end
    s = s:gsub("%s", "")
    local out = {}
    for p = 0, #s / 4 - 1 do
      local a, b, c, d = map[s:sub(p * 4 + 1, p * 4 + 1)] or 0, map[s:sub(p * 4 + 2, p * 4 + 2)] or 0, map[s:sub(p * 4 + 3, p * 4 + 3)] or 0, map[s:sub(p * 4 + 4, p * 4 + 4)] or 0
      local x = a * 0x40000 + b * 0x1000 + c * 0x40 + d
      out[#out + 1] = string.char(math.floor(x / 0x10000) % 0x100)
      if s:sub(p * 4 + 3, p * 4 + 3) ~= "=" then out[#out + 1] = string.char(math.floor(x / 0x100) % 0x100) end
      if s:sub(p * 4 + 4, p * 4 + 4) ~= "=" then out[#out + 1] = string.char(x % 0x100) end
    end
    return table.concat(out)
  end

  local PNG_B64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  local PNG = b64decode(PNG_B64)

  -- 等待异步 Deferred settle（同步测试体内驱动事件循环）
  local function wait_until(f, timeout_ms)
    local deadline = vim.uv.hrtime() / 1e6 + (timeout_ms or 3000)
    while not f() do
      if vim.uv.hrtime() / 1e6 > deadline then return false end
      vim.wait(15)
    end
    return true
  end

  it("base64 往返与 PNG 尺寸/DLX 检测", function(t)
    local image = require("NeoAI.utils.image")
    t.eq(image.base64_encode(PNG), PNG_B64, "base64 往返")
    t.eq(image.detect_media_type(PNG), "image/png", "magic 识别 PNG")
    local w, h = image.parse_dimensions(PNG, "image/png")
    t.eq(1, w, "png 宽")
    t.eq(1, h, "png 高")
    t.eq("image/png", image.media_type_for_path("a.png"), "扩展名 png")
    t.eq("image/jpeg", image.media_type_for_path("a.jpeg"), "扩展名 jpeg")
  end)

  it("GIF / JPEG / WebP 尺寸解析", function(t)
    local image = require("NeoAI.utils.image")
    -- GIF：header + 宽高小端
    local gif = "GIF89a" .. string.char(12, 0, 34, 0)
    t.eq("image/gif", image.detect_media_type(gif), "gif magic")
    t.eq(12, (image.parse_dimensions(gif, "image/gif")))
    t.eq(34, select(2, image.parse_dimensions(gif, "image/gif")), "gif 高")

    -- WebP VP8X：宽 20 / 高 30（各减 1 存 24bit 大端）
    local webp = "RIFF" .. string.char(0,0,0,0) .. "WEBP" .. "VP8X"
      .. string.char(0,0,0,10)                      -- chunk size
      .. string.char(0)                              -- flags
      .. string.char(0,0,0)                          -- reserved
      .. string.char(0,0,19)                         -- width-1 = 19 -> 20
      .. string.char(0,0,29)                         -- height-1 = 29 -> 30
    t.eq("image/webp", image.detect_media_type(webp), "webp magic")
    t.eq(20, (image.parse_dimensions(webp, "image/webp")), "webp 宽")
    t.eq(30, select(2, image.parse_dimensions(webp, "image/webp")), "webp 高")

    -- JPEG：SOI + APP0 + SOF0(高 10 / 宽 8)
    local jpeg = "\255\216"
      .. "\255\224\0\16" .. "JFIF\0\1\1\0\0\1\0\1\0\0"
      .. "\255\192\0\15\8" .. string.char(0,10) .. string.char(0,8) .. string.char(3)
      .. string.char(1,0,0,2,0,0,3,0,0)             -- 3 个组件
      .. "\255\217"
    t.eq("image/jpeg", image.detect_media_type(jpeg), "jpeg magic")
    t.eq(8, (image.parse_dimensions(jpeg, "image/jpeg")), "jpeg 宽")
    t.eq(10, select(2, image.parse_dimensions(jpeg, "image/jpeg")), "jpeg 高")
  end)

  it("vision 模型门禁", function(t)
    local att = require("NeoAI.core.attachment.attachment")
    t.true_(att.supports_image("deepseek-v4-flash-vision-exp"), "显式 vision 模型")
    t.true_(att.supports_image("gpt-4o"), "启发式 4o")
    t.true_(att.supports_image("gemini-2.0-flash"), "启发式 gemini")
    t.false_(att.supports_image("deepseek-v4-flash"), "非 vision 模型")
  end)

  it("保存附件并解析 data_url", function(t)
    local att = require("NeoAI.core.attachment.attachment")
    local ok = false
    local ref
    att.save_image({ data = PNG, mediaType = "image/png", name = "t.png" }):then_(function(r)
      ref = r
      ok = true
    end, function(e) error(tostring(e and e.message or e)) end)
    t.true_(wait_until(function() return ok end), "save_image 完成")
    t.eq(1, ref.width, "ref 宽")
    t.eq(1, ref.height, "ref 高")
    t.matches("^sha256:", ref.attachmentId, "内容寻址 id")

    local ok2, ri
    att.read_request_image(ref, att.request_policy()):then_(function(r2)
      ri = r2
      ok2 = true
    end)
    t.true_(wait_until(function() return ok2 end), "request_image 完成")
    t.not_nil(ri, "request_image 存在")
    local url = att.data_url(ri)
    t.eq("data:image/png;base64," .. PNG_B64, url, "data_url 与原文一致")
  end)

  it("materialize：vision 注入图像，text-only 原样", function(t)
    local att = require("NeoAI.core.attachment.attachment")
    local content = require("NeoAI.core.model.content")
    local json = require("NeoAI.utils.json")
    local ok = false
    local ref
    att.save_image({ data = PNG, mediaType = "image/png", name = "t.png" }):then_(function(r) ref = r ok = true end)
    t.true_(wait_until(function() return ok end), "save")

    local msgs = {
      { role = "user", content = "看看这张图" },
      { role = "tool", tool_call_id = "c1", content = json.encode({ path = "x.png", text = "x", image = ref }) },
      { role = "assistant", content = "好" },
    }
    t.true_(content.has_image(msgs), "has_image")

    local ok2, wire
    content.materialize(msgs, { vision = true }):then_(function(w) wire = w ok2 = true end)
    t.true_(wait_until(function() return ok2 end), "materialize(vision)")
    local img = false
    for _, m in ipairs(wire) do
      if type(m.content) == "table" then
        for _, p in ipairs(m.content) do
          if p.type == "image_url" then img = true end
        end
      end
    end
    t.true_(img, "vision 注入 image_url")

    local ok3, wire2
    content.materialize(msgs, { vision = false }):then_(function(w) wire2 = w ok3 = true end)
    t.true_(wait_until(function() return ok3 end), "materialize(text-only)")
    t.eq(3, #wire2, "text-only 保持原消息数")
  end)

  it("materialize：预算 offload 丢最旧图像", function(t)
    local att = require("NeoAI.core.attachment.attachment")
    local content = require("NeoAI.core.model.content")
    local json = require("NeoAI.utils.json")
    local ok = false
    local ref
    att.save_image({ data = PNG, mediaType = "image/png", name = "t.png" }):then_(function(r) ref = r ok = true end)
    t.true_(wait_until(function() return ok end), "save")

    local msgs = {
      { role = "user", content = "a" },
      { role = "tool", tool_call_id = "c1", content = json.encode({ image = ref }) },
      { role = "tool", tool_call_id = "c2", content = json.encode({ image = ref }) },
      { role = "assistant", content = "b" },
    }
    local ok2, wire
    content.materialize(msgs, { vision = true, policy = { maxPixels = 640000, maxBytes = 1024 * 1024, maxImagesPerRequest = 1, maxRequestBytes = 40 * 1024 * 1024, maxRequestImages = 600 } }):then_(function(w) wire = w ok2 = true end)
    t.true_(wait_until(function() return ok2 end), "materialize")
    local img_count = 0
    for _, m in ipairs(wire) do
      if type(m.content) == "table" then
        for _, p in ipairs(m.content) do
          if p.type == "image_url" then img_count = img_count + 1 end
        end
      end
    end
    t.eq(1, img_count, "仅保留 1 张图像（其余 offload 为文本）")
  end)

  it("read_image 工具：门禁 + 成功注入", function(t)
    local registry = require("NeoAI.tools.registry")
    local att = require("NeoAI.core.attachment.attachment")
    -- 工具系统仅在 NeoAI.setup() 时初始化；headless 单测未走过 setup，
    -- 内置工具（含 read_image）不会自动注册到 registry（真实会话中由 setup 注入）。
    -- 这里显式重载内置工具，确保 read_image 已在 registry 中。
    if not registry.has("read_image") then
      require("NeoAI.tools").reload_tools()
    end
    -- 写入真实测试图像文件
    local path = "/tmp/opencode/neoai_test_img.png"
    os.execute("mkdir -p /tmp/opencode")
    local f = io.open(path, "wb")
    f:write(PNG)
    f:close()

    local image_tool = registry.get("read_image")
    t.not_nil(image_tool, "read_image 已注册")

    -- 非视觉模型：门禁拒绝
    local rejected = false
    image_tool.func({ file_path = path, description = "测试" }, function() end, function()
      rejected = true
    end, { agent = { model = "deepseek-v4-flash" } })
    t.true_(rejected, "非视觉模型拒绝")

    -- 视觉模型：注入附件
    local ok = false
    local result
    image_tool.func({ file_path = path, description = "测试" }, function(res)
      result = res
      ok = true
    end, function(e) error("应成功却失败: " .. tostring(e)) end, { agent = { model = "deepseek-v4-flash-vision-exp" } })
    t.true_(wait_until(function() return ok end), "read_image 成功")
    t.not_nil(result.image, "返回图像引用")
    t.eq(path, result.path, "返回路径")
    t.matches("^sha256:", result.image.attachmentId, "图像引用内容寻址")
    -- 校验持久化
    local ok2, accessible
    att.read_original(result.image.attachmentId):then_(function(data) accessible = data ok2 = true end)
    t.true_(wait_until(function() return ok2 end), "附件可读")
    t.eq(PNG, accessible, "附件字节与源一致")
    os.execute("rm -f " .. path)
  end)

  it("read_image 工具：URL 下载 + 附件一致 + 临时文件清理", function(t)
    local registry = require("NeoAI.tools.registry")
    local att = require("NeoAI.core.attachment.attachment")
    if not registry.has("read_image") then
      require("NeoAI.tools").reload_tools()
    end
    local image_tool = registry.get("read_image")
    t.not_nil(image_tool, "read_image 已注册")

    -- 准备 PNG 文件 + 本地 HTTP 服务（python3 http.server 提供 /tmp 下的静态文件）
    os.execute("mkdir -p /tmp/opencode/neoai_www")
    local spath = "/tmp/opencode/neoai_www/t.png"
    local f = io.open(spath, "wb")
    f:write(PNG)
    f:close()

    -- 找一个空闲端口（绑定 127.0.0.1:0 后取出分配给的实际端口）
    local uv = vim.uv
    local sock = uv.new_tcp()
    uv.tcp_bind(sock, "127.0.0.1", 0)
    local sname = uv.tcp_getsockname(sock)
    uv.close(sock)
    local port = sname.port
    t.true_(type(port) == "number" and port > 0, "取得空闲端口")

    -- 启动服务器（jobstart 传空字典 {} 会触发 Vim E475，故省略 options）
    local server_job = vim.fn.jobstart({
      "python3", "-m", "http.server", tostring(port), "--bind", "127.0.0.1",
      "--directory", "/tmp/opencode/neoai_www",
    })
    t.true_(server_job > 0, "HTTP 服务器启动")

    -- 等待服务器就绪（curl -fs 成功即 2xx）
    local ready = wait_until(function()
      pcall(vim.fn.system,
        { "curl", "-fs", "-o", "/dev/null", "http://127.0.0.1:" .. port .. "/t.png" })
      return vim.v.shell_error == 0
    end)
    t.true_(ready, "服务器就绪（可下载 2xx）")

    -- 记录调用前已有的 /tmp 临时文件数，断言调用后不新增（成功/失败均清理）
    local before_leftover = #vim.fn.glob("/tmp/neoai_img_*", false, true)

    local url = "http://127.0.0.1:" .. port .. "/t.png"
    local ok = false
    local result
    image_tool.func({ file_path = url, description = "测试URL" }, function(res)
      result = res
      ok = true
    end, function(e)
      error("URL 读取应成功却失败: " .. tostring(e and e.message or e))
    end, { agent = { model = "deepseek-v4-flash-vision-exp" } })
    t.true_(wait_until(function() return ok end), "URL 读取成功")

    t.eq(url, result.path, "返回 path 为原始 URL")
    t.matches("^sha256:", result.image.attachmentId, "图像引用内容寻址")

    -- 附件字节与源一致
    local ok2, accessible
    att.read_original(result.image.attachmentId):then_(function(data) accessible = data ok2 = true end)
    t.true_(wait_until(function() return ok2 end), "附件可读")
    t.eq(PNG, accessible, "附件字节与源一致")

    -- 临时文件已清理（finally 在 on_success 之后执行，轮询确认无新增）
    local cleaned = wait_until(function()
      return #vim.fn.glob("/tmp/neoai_img_*", false, true) == before_leftover
    end)
    t.true_(cleaned, "临时文件已清理")

    -- 清理：停服务器 + 删除静态目录
    pcall(vim.fn.jobstop, server_job)
    os.execute("rm -rf /tmp/opencode/neoai_www")
  end)
end)
