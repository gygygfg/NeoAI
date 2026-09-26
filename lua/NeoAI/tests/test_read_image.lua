--- read_image 工具专项测试
--- @module NeoAI.tests.test_read_image
--- 覆盖门禁（模型能力/类型/可读性）与成功摄入路径；附件目录隔离到临时路径。
local tests = require("NeoAI.tests")
local config_store = require("NeoAI.kernel.config_store")

tests.suite("read_image", function(_, it, before_each)
  local attachment, tool, att_dir

  -- 1x1 PNG（与 test_multimodal 同一常量）
  local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local function b64decode(s)
    local map = {}
    for i = 1, #B64 do map[B64:sub(i, i)] = i - 1 end
    s = s:gsub("%s", "")
    local out = {}
    for p = 0, #s / 4 - 1 do
      local a = map[s:sub(p * 4 + 1, p * 4 + 1)] or 0
      local b = map[s:sub(p * 4 + 2, p * 4 + 2)] or 0
      local c = map[s:sub(p * 4 + 3, p * 4 + 3)] or 0
      local d = map[s:sub(p * 4 + 4, p * 4 + 4)] or 0
      local x = a * 0x40000 + b * 0x1000 + c * 0x40 + d
      out[#out + 1] = string.char(math.floor(x / 0x10000) % 0x100)
      if s:sub(p * 4 + 3, p * 4 + 3) ~= "=" then out[#out + 1] = string.char(math.floor(x / 0x100) % 0x100) end
      if s:sub(p * 4 + 4, p * 4 + 4) ~= "=" then out[#out + 1] = string.char(x % 0x100) end
    end
    return table.concat(out)
  end
  local PNG = b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")

  local function write_file(path, data)
    local f = assert(io.open(path, "wb"))
    f:write(data)
    f:close()
  end

  local function invoke(args, ctx)
    local result, err, done = nil, nil, false
    tool.func(args, function(v) result, done = v, true end, function(e) err, done = e, true end, ctx)
    if not done then
      vim.wait(15000, function() return done end, 15)
    end
    return result, err
  end

  before_each(function()
    att_dir = vim.fn.tempname() .. "-neoai_att"
    config_store.set("ai.attachments.path", att_dir)
    config_store.set("ai.attachments.enabled", true)
    config_store.set("ai.attachments.media_types", nil)
    attachment = require("NeoAI.core.attachment.attachment")
    attachment.reset()
    os.execute("rm -rf " .. vim.fn.shellescape(att_dir))
    tool = require("NeoAI.tools.builtin.read_image").get_tools()[1]
  end)

  local function vision_ctx(model)
    return { agent = { model = model or "test-vision", config = { provider = "test" } } }
  end

  it("缺少 file_path 时报错", function(t)
    local _, err = invoke({}, vision_ctx())
    t.matches("需要非空的 file_path", err)
  end)

  it("无法解析模型 route 时报错", function(t)
    local _, err = invoke({ file_path = "x.png" }, {})
    t.matches("无法解析当前模型 route", err)
  end)

  it("非视觉模型被门禁拒绝（不读盘）", function(t)
    local _, err = invoke({ file_path = "x.png" }, vision_ctx("plain-model-xyz"))
    t.matches("未声明支持图像输入", err)
  end)

  it("附件存储禁用时报错", function(t)
    config_store.set("ai.attachments.enabled", false)
    attachment.reset()
    local _, err = invoke({ file_path = "x.png" }, vision_ctx())
    t.matches("附件存储未启用", err)
  end)

  it("非图像扩展名被拒绝", function(t)
    local _, err = invoke({ file_path = att_dir .. "/note.txt" }, vision_ctx())
    t.matches("仅接受 PNG/JPEG/WebP/GIF", err)
  end)

  it("不可读文件报错", function(t)
    local _, err = invoke({ file_path = att_dir .. "/missing.png" }, vision_ctx())
    t.matches("文件不可读", err)
  end)

  it("扩展名与实际格式不一致时报错", function(t)
    vim.fn.mkdir(att_dir, "p")
    write_file(att_dir .. "/fake.png", "GIF89a" .. string.char(1, 0, 1, 0))
    local _, err = invoke({ file_path = att_dir .. "/fake.png" }, vision_ctx())
    t.matches("扩展名声明", err)
  end)

  it("被部署类型白名单排除时报错", function(t)
    vim.fn.mkdir(att_dir, "p")
    config_store.set("ai.attachments.media_types", { "image/png" })
    attachment.reset()
    write_file(att_dir .. "/anim.gif", "GIF89a" .. string.char(1, 0, 1, 0))
    local _, err = invoke({ file_path = att_dir .. "/anim.gif" }, vision_ctx())
    t.matches("不被本部署允许", err)
  end)

  it("合法 PNG 成功摄入并返回图像引用", function(t)
    vim.fn.mkdir(att_dir, "p")
    write_file(att_dir .. "/pic.png", PNG)
    local res, err = invoke({ file_path = att_dir .. "/pic.png" }, vision_ctx())
    t.nil_(err, tostring(err))
    t.not_nil(res, "应返回结果")
    t.not_nil(res.image, "应返回附件引用")
    t.eq("image/png", res.image.mediaType)
    t.matches("<type>image</type>", res.text)
    t.matches("image/png", res.text)
  end)
end)
