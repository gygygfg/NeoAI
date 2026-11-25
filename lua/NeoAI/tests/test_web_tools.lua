--- Web 工具测试（web_search / web_fetch）
--- @module 'NeoAI.tests.test_web_tools'
--- 纯逻辑 + 本地 mock HTTP，不访问真实外部 API。
--- 覆盖：开关/schema、查询校验、结果合并与格式化、DeepSeek provider 门控、
--- Search/Fetch 请求路径与鉴权、HTTP 错误。

local tests = require("NeoAI.tests")
local config_store = require("NeoAI.kernel.config_store")

local function _load_config(base_url)
  config_store.load({
    ai = {
      default_provider = "deepseek",
      providers = {
        deepseek = {
          api_type = "openai",
          base_url = base_url or "https://api.deepseek.com",
          api_key = "test-deepseek-key",
        },
        openai = {
          api_type = "openai",
          base_url = "https://api.openai.com/v1",
          api_key = "test-openai-key",
        },
      },
      model_refresh = { on_startup = false },
    },
    tools = {
      approval = { mode = "auto_allow", per_tool = {} },
      web = {
        search = { enabled = true, max_results = 8, max_queries = 4, timeout_ms = 5000 },
        fetch = { enabled = true, timeout_ms = 5000, max_output_chars = 200000 },
      },
    },
  })
end

local function _deepseek_agent()
  return { config = { provider = "deepseek" }, model = "deepseek-v4-flash" }
end

local function _openai_agent()
  return { config = { provider = "openai" }, model = "gpt-4.1" }
end

--- 直接调用工具 func（回调式），返回 success/error。
local function _call(tool, args, agent)
  local done, ok, value = false, false, nil
  tool.func(args, function(v)
    ok, value, done = true, v, true
  end, function(e)
    ok, value, done = false, e, true
  end, { agent = agent })
  vim.wait(5000, function() return done end, 10)
  return ok, value
end

tests.suite("web_tools", function(_, it, before_each)
  local ws, wf, wp

  before_each(function()
    config_store.reset()
    ws = require("NeoAI.tools.builtin.web_search")
    wf = require("NeoAI.tools.builtin.web_fetch")
    wp = require("NeoAI.tools.web_provider")
    ws.reset()
    wf.reset()
  end)

  it("默认关闭时两个工具都不注册", function(t)
    t.eq(0, #ws.get_tools(), "web_search 默认关闭")
    t.eq(0, #wf.get_tools(), "web_fetch 默认关闭")
  end)

  it("启用后 schema：web_search.queries、web_fetch.url", function(t)
    _load_config()
    local st = ws.get_tools()[1]
    t.not_nil(st)
    t.eq("web_search", st.name)
    t.eq("web", st.category)
    t.true_(st.approval and st.approval.auto_allow == true)
    t.eq(-1, st.timeout)
    t.not_nil(st.parameters.properties.queries)
    t.eq("array", st.parameters.properties.queries.type)
    t.true_(vim.tbl_contains(st.parameters.required, "queries"))

    local ft = wf.get_tools()[1]
    t.not_nil(ft)
    t.eq("web_fetch", ft.name)
    t.not_nil(ft.parameters.properties.url)
    t.true_(vim.tbl_contains(ft.parameters.required, "url"))
  end)

  it("queries 校验：空/超限/空白/去重", function(t)
    local maxq = 4
    local q, err = ws._parse_queries({ queries = {} }, maxq)
    t.nil_(q)
    t.matches("at least one", err or "")

    q, err = ws._parse_queries({ queries = { "a", "b", "c", "d", "e" } }, maxq)
    t.nil_(q)
    t.matches("at most 4", err or "")

    q, err = ws._parse_queries({ queries = { "a", "  " } }, maxq)
    t.nil_(q)
    t.matches("non%-empty", err or "")

    q = ws._parse_queries({ queries = { "a", "a", "b" } }, maxq)
    t.deep_eq({ "a", "b" }, q)
  end)

  it("多查询合并：轮询、URL 去重、上限截断", function(t)
    local results = {
      { sources = { { url = "u1" }, { url = "u2" }, { url = "u3" } }, truncated = false },
      { sources = { { url = "u2" }, { url = "u4" } }, truncated = false },
    }
    local merged = ws._merge_results(results, 3)
    t.eq(3, #merged.sources)
    t.eq("u1", merged.sources[1].url)
    t.eq("u2", merged.sources[2].url)
    t.eq("u4", merged.sources[3].url)
    t.true_(merged.truncated, "超出上限应标记截断")
  end)

  it("搜索结果格式对齐 Harness", function(t)
    local text = wp.format_search_output({
      sources = {
        { url = "https://example.com/a", title = "A", snippet = "snippet A", publishedAt = "2026-06-01" },
        { url = "https://example.org/b", snippet = "snippet B" },
      },
      truncated = true,
    })
    t.matches("External web content follows", text)
    t.matches("Sources:", text)
    t.matches("%- %[A%]%(https://example.com/a%) — snippet A %(2026%-06%-01%)", text)
    t.matches("%- %[example.org%]%(https://example.org/b%) — snippet B", text)
    t.matches("Showing the first 2 sources", text)
    t.matches("Cite the relevant URLs", text)
  end)

  it("无结果格式", function(t)
    local text = wp.format_search_output({ sources = {}, truncated = false })
    t.matches("No results found", text)
    t.matches("Cite the relevant URLs", text)
  end)

  it("fetch 输出格式与截断", function(t)
    local text = wp.format_fetch_output("https://example.com", "hello", 200000)
    t.matches("^Fetched https://example.com %(HTTP 200%)", text)
    t.matches("External web content follows", text)
    t.matches("hello", text)

    local small = wp.format_fetch_output("https://example.com", string.rep("x", 5000), 500)
    t.true_(vim.fn.strchars(small) <= 500, "输出应不超过字符上限")
    t.matches("Content truncated", small)

    local cn = wp.format_fetch_output("https://example.com", string.rep("中", 5000), 500)
    t.true_(vim.fn.strchars(cn) <= 500, "中文输出应不超过字符上限")
    t.matches("Content truncated", cn)
  end)

  it("endpoint 规范化：base_url 带 /v1 不重复拼接", function(t)
    local b, p = wp.endpoint("https://api.deepseek.com", "search")
    t.eq("https://api.deepseek.com", b)
    t.eq("/v1/tools/search", p)
    b, p = wp.endpoint("https://api.deepseek.com/v1/", "fetch")
    t.eq("https://api.deepseek.com/v1", b)
    t.eq("/tools/fetch", p)
  end)

  it("provider 门控：非 DeepSeek 隐藏并拒绝执行", function(t)
    _load_config()
    local env = require("NeoAI.tools.environment")
    local all = { web_search = {}, web_fetch = {}, read_file = {} }

    local ds = env.filter_tools(all, _deepseek_agent())
    t.not_nil(ds.web_search, "DeepSeek 应保留 web_search")
    t.not_nil(ds.web_fetch, "DeepSeek 应保留 web_fetch")

    local oa = env.filter_tools(all, _openai_agent())
    t.nil_(oa.web_search, "非 DeepSeek 不应暴露 web_search")
    t.nil_(oa.web_fetch, "非 DeepSeek 不应暴露 web_fetch")
    t.not_nil(oa.read_file, "其他工具不受影响")

    local ok, err = _call(ws.get_tools()[1], { queries = { "x" } }, _openai_agent())
    t.false_(ok)
    t.matches("仅在使用 DeepSeek", tostring(err))

    local ok2, err2 = _call(wf.get_tools()[1], { url = "https://example.com" }, _openai_agent())
    t.false_(ok2)
    t.matches("仅在使用 DeepSeek", tostring(err2))
  end)

  it("DeepSeek Search：请求路径/鉴权/body 与结果格式化", function(t)
    local server = require("NeoAI.tests.http_server")
    local seen = {}
    server.with_server(function(client, request)
      seen.path = request:match("^POST (%S+)")
      seen.auth = request:match("\r\nAuthorization:%s*([^\r\n]+)")
      local header_end = request:find("\r\n\r\n", 1, true)
      seen.body = vim.json.decode(request:sub(header_end + 4))
      server.respond(client, vim.json.encode({
        results = {
          {
            title = "Result One",
            url = "https://example.com/one",
            summary = "summary one",
            date = "2026-06-01T00:00:00+00:00",
          },
        },
      }))
    end, function(base)
      _load_config(base)
      local ok, out = _call(ws.get_tools()[1], { queries = { "hello" } }, _deepseek_agent())
      t.true_(ok, tostring(out))
      t.eq("/v1/tools/search", seen.path)
      t.eq("Bearer test-deepseek-key", seen.auth)
      t.eq("hello", seen.body.query)
      t.eq(8, seen.body.count)
      t.false_(seen.body.need_content)
      t.matches("Sources:", out)
      t.matches("%[Result One%]%(https://example.com/one%)", out)
      t.matches("summary one", out)
    end)
  end)

  it("DeepSeek Fetch：请求路径/鉴权/body 与输出", function(t)
    local server = require("NeoAI.tests.http_server")
    local seen = {}
    server.with_server(function(client, request)
      seen.path = request:match("^POST (%S+)")
      seen.auth = request:match("\r\nAuthorization:%s*([^\r\n]+)")
      local header_end = request:find("\r\n\r\n", 1, true)
      seen.body = vim.json.decode(request:sub(header_end + 4))
      server.respond(client, vim.json.encode({ title = "Example", content = "page body" }))
    end, function(base)
      _load_config(base)
      local ok, out = _call(wf.get_tools()[1], { url = "https://example.com/page" }, _deepseek_agent())
      t.true_(ok, tostring(out))
      t.eq("/v1/tools/fetch", seen.path)
      t.eq("Bearer test-deepseek-key", seen.auth)
      t.eq("https://example.com/page", seen.body.url)
      t.matches("^Fetched https://example.com/page", out)
      t.matches("page body", out)
    end)
  end)

  it("HTTP 错误返回可读错误", function(t)
    local server = require("NeoAI.tests.http_server")
    server.with_server(function(client)
      server.respond(client, "unauthorized", "401 Unauthorized")
    end, function(base)
      _load_config(base)
      local ok, err = _call(ws.get_tools()[1], { queries = { "x" } }, _deepseek_agent())
      t.false_(ok)
      t.matches("web_search 失败", tostring(err))
      t.matches("401", tostring(err))
    end)
  end)

  it("url 校验：非空 http/https", function(t)
    local _, err = wf._validate_url("")
    t.matches("non%-empty", err or "")
    local _, err2 = wf._validate_url("ftp://example.com")
    t.matches("http", err2 or "")
    t.eq("https://example.com", (wf._validate_url("https://example.com")))
  end)
end)
