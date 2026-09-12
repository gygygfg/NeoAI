--- web_fetch 工具测试
--- @module NeoAI.tests.test_web_fetch
--- 纯逻辑测试：不联网、不安装依赖、不启动浏览器。
--- 覆盖：门控、工具 schema、缓存 key、选项组装、Node 输出解析、信封、缓存淘汰。

local tests = require("NeoAI.tests")
local config_store = require("NeoAI.kernel.config_store")
local fs = require("NeoAI.utils.fs")

--- 基础配置：启用但关闭自动安装（避免触发真实安装）
local function _enable()
  config_store.load({
    tools = {
      web_fetch = {
        enabled = true,
        auto_install = false,
        engine = "chromium",
        format = "markdown",
        nav_timeout_ms = 30000,
        timeout_ms = 45000,
        max_bytes = 1024 * 1024,
        cache = { enabled = true, ttl_sec = 3600, max_entries = 200, max_bytes = 500 * 1024 * 1024 },
      },
    },
  })
end

--- 构造临时缓存目录并写入若干条目文件
--- @param entries table { { key, size, ts } }
--- @return string dir
local function _seed_cache(entries)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  for _, e in ipairs(entries) do
    local pad = string.rep("x", e.size)
    local ok = pcall(function()
      local f = io.open(dir .. "/" .. e.key .. ".json", "wb")
      f:write(('{"ts":%d,"content":"%s"}'):format(e.ts, pad))
      f:close()
    end)
    if not ok then error("写入缓存测试文件失败") end
  end
  return dir
end

tests.suite("web_fetch", function(_, it, before_each)
  local wf

  before_each(function()
    config_store.reset()
    wf = require("NeoAI.tools.builtin.web_fetch")
    wf.reset()
  end)

  it("默认不启用时 get_tools() 为空", function(t)
    config_store.reset()
    wf.reset()
    t.false_(wf._is_enabled(), "默认应关闭")
    t.eq(0, #wf.get_tools(), "关闭时不应暴露任何工具")
  end)

  it("启用后暴露 web_fetch 且 schema 正确", function(t)
    _enable()
    local tools = wf.get_tools()
    t.eq(1, #tools)
    local def = tools[1]
    t.eq("web_fetch", def.name)
    t.eq("web", def.category)
    t.true_(def.approval and def.approval.auto_allow == true, "应自动放行")
    t.eq(-1, def.timeout, "长任务应不设固定超时")
    local props = def.parameters.properties
    t.not_nil(props.url, "应有 url 参数")
    t.true_(vim.tbl_contains(def.parameters.required, "url"), "url 必填")
    t.not_nil(props.format, "应有 format 参数")
    t.deep_eq({ "markdown", "text" }, props.format.enum)
    t.not_nil(props.script, "应有 script 参数")
  end)

  it("缓存 key：稳定且对参数敏感", function(t)
    local k1 = wf._cache_key("https://a.com", { format = "markdown" })
    local k2 = wf._cache_key("https://a.com", { format = "markdown" })
    t.eq(k1, k2, "相同输入应得到相同 key")
    t.eq(64, #k1, "sha256 十六进制为 64 字符")
    t.ne(k1, wf._cache_key("https://a.com", { format = "text" }), "format 变化应改变 key")
    t.ne(k1, wf._cache_key("https://b.com", { format = "markdown" }), "url 变化应改变 key")
    t.ne(k1, wf._cache_key("https://a.com", { format = "markdown", selector = "#x" }), "selector 变化应改变 key")
  end)

  it("_build_options：默认值与覆盖 + 非法值拒绝", function(t)
    _enable()
    local cfg = wf._cfg()

    local opts = wf._build_options("https://a.com", {}, cfg)
    t.not_nil(opts)
    t.eq("chromium", opts.engine)
    t.eq("markdown", opts.format)
    t.eq(30000, opts.nav_timeout_ms)
    t.not_nil(opts.script_file, "应解析出内置 clean 脚本")
    t.matches("clean%.js$", opts.script_file)

    local opts2 = wf._build_options("https://a.com", { format = "text", engine = "firefox", wait_ms = 500 }, cfg)
    t.not_nil(opts2)
    t.eq("text", opts2.format)
    t.eq("firefox", opts2.engine)
    t.eq(500, opts2.wait_ms)

    -- html 已不再支持，应被拒绝（避免回吐原始 HTML）
    local no_html, html_err = wf._build_options("https://a.com", { format = "html" }, cfg)
    t.nil_(no_html, "html 格式应被拒绝")
    t.matches("format", html_err or "")

    local bad, err = wf._build_options("https://a.com", { format = "pdf" }, cfg)
    t.nil_(bad)
    t.matches("format", err or "")

    local bad2, err2 = wf._build_options("https://a.com", { engine = "edge" }, cfg)
    t.nil_(bad2)
    t.matches("engine", err2 or "")

    local bad3, err3 = wf._build_options("https://a.com", { script = "../evil" }, cfg)
    t.nil_(bad3, "路径穿越脚本名应被拒绝")
    t.matches("注入脚本", err3 or "")

    local bad4, err4 = wf._build_options("https://a.com", { script = "nope" }, cfg)
    t.nil_(bad4, "未知脚本应被拒绝")
    t.matches("注入脚本", err4 or "")
  end)

  it("_build_options：图片目录与上限", function(t)
    _enable()
    local cfg = wf._cfg()
    local opts = wf._build_options("https://a.com", {}, cfg)
    t.not_nil(opts)
    t.not_nil(opts.images_dir, "应给出图片临时目录")
    t.true_(fs.is_dir(opts.images_dir), "图片目录应真实存在（mktemp -d）")
    t.matches("neoai_web_fetch%.", opts.images_dir)
    t.eq(50, opts.max_images, "max_images 默认 50")
    t.eq(5 * 1024 * 1024, opts.max_image_bytes, "max_image_bytes 默认 5MB")
    -- 清理本次创建的临时目录
    wf._cleanup_images()
  end)

  it("_images_dir：懒创建且同会话复用；_cleanup_images 删除全部", function(t)
    _enable()
    local d1 = wf._images_dir()
    local d2 = wf._images_dir()
    t.not_nil(d1)
    t.eq(d1, d2, "同一会话应复用同一目录")
    t.true_(fs.is_dir(d1), "目录应存在")
    local n = wf._cleanup_images()
    t.true_(n >= 1, "应至少删除 1 个目录")
    t.false_(fs.is_dir(d1), "清理后目录应被删除")
    wf._cleanup_images()
  end)

  it("_ensure_cleanup_registered：幂等，仅首次注册", function(t)
    _enable()
    t.true_(wf._ensure_cleanup_registered(), "首次应注册")
    t.false_(wf._ensure_cleanup_registered(), "再次应跳过")
    -- 启用后 get_tools 会触发注册，不报错
    local tools = wf.get_tools()
    t.eq(1, #tools)
    wf._cleanup_images()
  end)

  it("readability 脚本触发 need_readability", function(t)
    _enable()
    local cfg = wf._cfg()
    local opts = wf._build_options("https://a.com", { script = "readability" }, cfg)
    t.not_nil(opts)
    t.true_(opts.need_readability, "readability 脚本应注入库")
    t.matches("readability%.js$", opts.script_file)

    local opts2 = wf._build_options("https://a.com", { script = "clean" }, cfg)
    t.false_(opts2.need_readability, "clean 不应注入 readability")
  end)

  it("脚本名清洗与列举（防路径穿越）", function(t)
    t.eq("clean", wf._sanitize_script_name("clean"))
    t.eq("clean", wf._sanitize_script_name("clean.js"))
    t.nil_(wf._sanitize_script_name("../etc/passwd"))
    t.nil_(wf._sanitize_script_name("a/b"))
    t.nil_(wf._sanitize_script_name(""))

    local names = wf._list_scripts()
    t.true_(vim.tbl_contains(names, "clean"), "应内置 clean")
    t.true_(vim.tbl_contains(names, "readability"), "应内置 readability")
  end)

  it("_parse_node_output：成功 / ok:false / 非 JSON", function(t)
    local ok = wf._parse_node_output('{"ok":true,"content":"# hi","title":"T"}')
    t.true_(ok.ok)
    t.eq("# hi", ok.content)
    t.eq("T", ok.title)

    local fail = wf._parse_node_output('{"ok":false,"error":"boom"}')
    t.false_(fail.ok)
    t.matches("boom", fail.error or "")

    local garbage = wf._parse_node_output("not json at all")
    t.false_(garbage.ok)
    t.matches("解析", garbage.error or "")

    local empty = wf._parse_node_output("   ")
    t.false_(empty.ok)
  end)

  it("_parse_node_output：大输出（>128KB）完整解析，模拟管道截断回归", function(t)
    -- 回归：曾因 render_url.js 在 stdout 管道异步写入后立即 process.exit()，
    -- 复杂页面（大 JSON）在 64KB/128KB 管道缓冲处被截断而解析失败。
    -- 这里验证一个远超管道缓冲区的完整 JSON 能被正确解析。
    local big = string.rep("百度一下，你就知道abc", 9000) -- 远超 128KB
    local payload = vim.json.encode({ ok = true, url = "https://example.com", title = "T", content = big })
    t.ok(#payload > 128 * 1024, "载荷应大于 128KB（实际 " .. #payload .. "）")
    local parsed = wf._parse_node_output(payload)
    t.true_(parsed.ok)
    t.eq(#big, #(parsed.content or ""), "内容应完整保留，不得被截断")
    t.eq(big, parsed.content)
  end)

  it("_parse_node_output：非 JSON 错误信息 UTF-8 安全截断（不产生乱码）", function(t)
    -- 回归：错误信息曾用 trimmed:sub(1, 500) 按字节截断，可能切断多字节字符产生乱码。
    -- 构造一个前 500 字节内正好断开多字节字符的无效 JSON。
    local s = "汉" .. string.rep("字", 400) -- 每字 3 字节：1 + 3*400 = 1201 字节
    local res = wf._parse_node_output(s)
    t.false_(res.ok)
    t.matches("解析 Node 输出失败", res.error or "")
    -- 截断结果应为合法 UTF-8（vim.json.encode 遇到非法字节会报错，以此验证）
    local enc_ok = pcall(vim.json.encode, { e = res.error })
    t.true_(enc_ok, "错误信息应为合法 UTF-8，可被编码")
  end)

  it("_format_envelope：结构 / bytes / cached / 截断", function(t)
    local out = wf._format_envelope("https://a.com", {
      title = "标题", engine = "chromium", format = "markdown", cached = false, script = "clean",
    }, "hello")
    t.matches("source: https://a%.com", out)
    t.matches("title: 标题", out)
    t.matches("cached: no", out)
    t.matches("bytes: 5", out)
    t.matches("\n---\nhello", out)

    local out2 = wf._format_envelope("https://a.com", { cached = true }, "x")
    t.matches("cached: yes", out2)

    local out3 = wf._format_envelope("https://a.com", { truncated = true }, "x")
    t.matches("截断", out3)
  end)

  it("_truncate：超限截断并附提示", function(t)
    local s, trunc = wf._truncate("abcdefghij", 5)
    t.true_(trunc)
    t.matches("^abcde", s)
    t.matches("截断", s)

    local s2, trunc2 = wf._truncate("abc", 10)
    t.false_(trunc2)
    t.eq("abc", s2)

    local s3, trunc3 = wf._truncate("abc", 0)
    t.false_(trunc3, "max_bytes<=0 表示不截断")
    t.eq("abc", s3)
  end)

  it("缓存读写：命中 / 过期 / force_refresh 语义", function(t)
    _enable()
    local cfg = wf._cfg()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    wf._set_cache_dir(dir)

    local key = wf._cache_key("https://a.com", {})
    t.true_(wf._cache_write(key, { url = "https://a.com", title = "T", content = "hi", ts = os.time() }, cfg))
    local hit = wf._cache_read(key, cfg)
    t.not_nil(hit)
    t.eq("hi", hit.content)

    -- 过期条目应读不到
    local key2 = wf._cache_key("https://old.com", {})
    wf._cache_write(key2, { url = "https://old.com", content = "old", ts = os.time() - 100000 }, { cache = { enabled = true, ttl_sec = 10 } })
    t.nil_(wf._cache_read(key2, cfg), "过期条目不应命中")

    -- 关闭缓存时读写都失效
    t.nil_(wf._cache_read(key, { cache = { enabled = false } }))
    t.false_(wf._cache_write(key, { content = "x", ts = os.time() }, { cache = { enabled = false } }))
  end)

  it("缓存容量上限：最旧优先淘汰，总大小不超上限", function(t)
    _enable()
    local cfg = { cache = { enabled = true, ttl_sec = 0, max_entries = 100, max_bytes = 1200 } }
    local dir = _seed_cache({
      { key = "a", size = 400, ts = 100 },
      { key = "b", size = 400, ts = 200 },
      { key = "c", size = 400, ts = 300 },
    })
    wf._set_cache_dir(dir)

    t.eq(3, #wf._iter_cache_entries())
    -- 写入第 4 条 300 字节 → 需要淘汰最旧的以腾出空间
    local ok = wf._cache_write("d", { url = "https://d.com", content = string.rep("y", 260), ts = 400 }, cfg)
    t.true_(ok)

    local names = {}
    for _, e in ipairs(wf._iter_cache_entries()) do names[e.key] = true end
    t.nil_(names["a"], "最旧的 a 应被淘汰")
    t.true_(wf._cache_size_bytes() <= 1200, "总大小不应超上限，实际=" .. wf._cache_size_bytes())
  end)

  it("缓存条目数上限：超出时淘汰最旧", function(t)
    _enable()
    local cfg = { cache = { enabled = true, ttl_sec = 0, max_entries = 2, max_bytes = 10 * 1024 * 1024 } }
    local dir = _seed_cache({
      { key = "a", size = 20, ts = 100 },
      { key = "b", size = 20, ts = 200 },
    })
    wf._set_cache_dir(dir)

    wf._cache_write("c", { url = "https://c.com", content = "cc", ts = os.time() }, cfg)
    local names = {}
    for _, e in ipairs(wf._iter_cache_entries()) do names[e.key] = true end
    t.nil_(names["a"], "条目数超限时应淘汰最旧")
    t.true_(names["b"] and names["c"], "较新条目应保留")
  end)

  it("单条超过总容量时不写入缓存", function(t)
    _enable()
    local cfg = { cache = { enabled = true, ttl_sec = 0, max_entries = 100, max_bytes = 200 } }
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    wf._set_cache_dir(dir)

    local big = string.rep("z", 500)
    local ok = wf._cache_write("big", { url = "https://big.com", content = big }, cfg)
    t.false_(ok, "单条超容量应放弃写入")
    t.eq(0, #wf._iter_cache_entries())
    t.eq(0, wf._cache_size_bytes())
  end)

  it("_build_install_script：含 node/npm 检查与引擎安装", function(t)
    _enable()
    local cfg = wf._cfg()
    local script = wf._build_install_script("/tmp/whatever", "chromium", cfg)
    t.matches("NODE_MISSING", script)
    t.matches("NPM_MISSING", script)
    t.matches("npm install", script)
    t.matches("playwright install chromium", script)
    t.matches("PLAYWRIGHT_BROWSERS_PATH", script)
    t.nil_(script:find("with%-deps", 1, true), "默认不应附带 --with-deps")
  end)

  it("_build_env_exports：默认无输出，设置了镜像/代理时正确导出", function(t)
    _enable()
    -- 1) 默认（全空）→ 不输出任何 export/unset
    local base = wf._build_env_exports(wf._cfg())
    t.eq(0, #base, "默认配置不应注入网络环境变量")

    -- 2) 镜像 + npm 源 + 显式代理
    local lines = wf._build_env_exports({
      playwright_download_host = "https://registry.npmmirror.com/-/binary/playwright",
      npm_registry = "https://registry.npmmirror.com/",
      http_proxy = "http://127.0.0.1:7890",
      https_proxy = "http://127.0.0.1:7890",
    })
    local joined = table.concat(lines, "\n")
    t.matches("PLAYWRIGHT_DOWNLOAD_HOST", joined)
    t.matches("registry%.npmmirror%.com/%-/binary/playwright", joined)
    t.matches("export http_proxy=", joined)
    t.matches("export https_proxy=", joined)

    -- 3) ignore_system_proxy=true → 清空继承的代理变量
    local cleared = table.concat(wf._build_env_exports({ ignore_system_proxy = true }), "\n")
    t.matches("unset", cleared)
    t.matches("HTTP_PROXY", cleared)
    t.matches("HTTPS_PROXY", cleared)
  end)

  it("镜像/代理配置透传进安装脚本", function(t)
    config_store.load({
      tools = {
        web_fetch = {
          enabled = true,
          auto_install = false,
          npm_registry = "https://registry.npmmirror.com/",
          playwright_download_host = "https://registry.npmmirror.com/-/binary/playwright",
          ignore_system_proxy = true,
        },
      },
    })
    local cfg = wf._cfg()
    local script = wf._build_install_script("/tmp/whatever", "chromium", cfg)
    t.matches("--registry='https://registry.npmmirror.com/'", script)
    t.matches("PLAYWRIGHT_DOWNLOAD_HOST", script)
    t.matches("unset HTTP_PROXY", script)
  end)

  it("资源目录与内置文件存在", function(t)
    _enable()
    local assets = wf._assets_dir()
    t.true_(fs.exists(fs.join(assets, "render_url.js")), "应内置 render_url.js")
    t.true_(fs.exists(fs.join(assets, "package.json")), "应内置 package.json")
    t.true_(fs.exists(fs.join(assets, "scripts", "clean.js")), "应内置 clean.js")
    t.true_(fs.exists(fs.join(assets, "scripts", "readability.js")), "应内置 readability.js")
  end)
end)
