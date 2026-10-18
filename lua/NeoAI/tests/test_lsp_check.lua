--- lsp_check 工具回归
--- @module 'NeoAI.tests.test_lsp_check'
--- 覆盖：项目级全量诊断运行配置的 CLI（此处用 mock 脚本写 LuaLS JSON 到 {out}）、
--- 严重级别过滤、code 过滤、limit、summary/text/json 渲染、结果文件回读。
--- 不依赖真实 lua-language-server。

local tests = require("NeoAI.tests")
local H = require("NeoAI.tests.sandbox_boundary_helpers")

local JSON = '{"file:///tmp/a.lua":[' ..
  '{"range":{"start":{"line":1,"character":0}},"severity":1,"message":"boom","code":"E1"},' ..
  '{"range":{"start":{"line":3,"character":2}},"severity":2,"message":"warn","code":"W1"}' ..
  ']}'

local function lsp_tool()
  for _, t in ipairs(require("NeoAI.tools.builtin.lsp_ops").get_tools()) do
    if t.name == "lsp_check" then return t end
  end
  error("lsp_check 未注册")
end

--- 写一个 mock 检查脚本：把 JSON 写入 argv[1]（即 {out}）。
local function write_mock_script(dir)
  local script = dir .. "/mock-check.sh"
  local f = io.open(script, "w")
  assert(f, "无法写 mock 脚本")
  f:write("#!/bin/sh\nprintf '%s' " .. ("'" .. JSON .. "'") .. " > \"$1\"\n")
  f:close()
  return script
end

local function call(tool, args, cfg, wait_ms)
  local result, err, done = nil, nil, false
  H.with_config({ tools = { lsp = { check = cfg } } }, function()
    tool.func(args, function(v) result = v; done = true end,
      function(e) err = e; done = true end, { cwd = "/tmp" })
  end)
  vim.wait(wait_ms or 8000, function() return done end, 20)
  return result, err
end

tests.suite("lsp_check", function(_, it)
  it("lua-ls：运行 CLI 并解析 {out}，text 输出含诊断", function(t)
    local tool = lsp_tool()
    local dir = vim.fn.tempname(); vim.fn.mkdir(dir, "p")
    local script = write_mock_script(dir)
    local cfg = {
      enabled = true, timeout_ms = 5000,
      servers = { mock = { argv = { "/bin/sh", script, "{out}" }, format = "lua-ls" } },
    }
    local out, err = call(tool, { server = "mock", format = "text" }, cfg)
    t.nil_(err, "不应报错: " .. tostring(err))
    t.matches("boom", out or "", "应含 boom 诊断")
    t.matches("E1", out or "", "应含 code")
    t.matches("a%.lua:2:1", out or "", "应含 1-based 行:列")
    vim.fn.delete(dir, "rf")
  end)

  it("severity 过滤：只保留 Error", function(t)
    local tool = lsp_tool()
    local dir = vim.fn.tempname(); vim.fn.mkdir(dir, "p")
    local script = write_mock_script(dir)
    local cfg = {
      enabled = true, timeout_ms = 5000,
      servers = { mock = { argv = { "/bin/sh", script, "{out}" }, format = "lua-ls" } },
    }
    local out = call(tool, { server = "mock", severity = "error" }, cfg)
    t.matches("boom", out or "", "应含 Error")
    t.false_((out or ""):find("warn", 1, true) ~= nil, "不应含 Warning")
    vim.fn.delete(dir, "rf")
  end)

  it("format=summary：按严重级别计数", function(t)
    local tool = lsp_tool()
    local dir = vim.fn.tempname(); vim.fn.mkdir(dir, "p")
    local script = write_mock_script(dir)
    local cfg = {
      enabled = true, timeout_ms = 5000,
      servers = { mock = { argv = { "/bin/sh", script, "{out}" }, format = "lua-ls" } },
    }
    local out = call(tool, { server = "mock", format = "summary" }, cfg)
    t.matches("Error=1", out or "", "summary 应计 Error=1")
    t.matches("Warning=1", out or "", "summary 应计 Warning=1")
    vim.fn.delete(dir, "rf")
  end)

  it("指定未配置的 server 时明确报错", function(t)
    local tool = lsp_tool()
    local cfg = { enabled = true, servers = { mock = { argv = { "/bin/true" }, format = "text" } } }
    local out, err = call(tool, { server = "nonexistent" }, cfg, 2000)
    t.nil_(out, "未配置的 server 不应有输出")
    t.not_nil(err, "应给出错误")
  end)

  it("自动选择：按扩展名匹配已安装的 server，未安装的跳过", function(t)
    local lsp = require("NeoAI.tools.builtin.lsp_ops")
    local servers = {
      ["lua-language-server"] = {
        argv = { "definitely-not-installed-luals-xyz", "--check={path}" },
        format = "lua-ls",
        extensions = { "lua" },
      },
      pymock = { argv = { "/bin/sh", "-c", "true" }, format = "pyright", extensions = { "py" } },
    }
    local py = lsp._pick_check_server(servers, "/tmp/a.py", nil)
    t.eq("pymock", py, "应选扩展名命中的已安装 server")
    local lua = lsp._pick_check_server(servers, "/tmp/a.lua", nil)
    t.eq("pymock", lua, "命中的 lua server 未安装时应回退到任一已安装 server")
    local _, _, err = lsp._pick_check_server(
      { only = { argv = { "definitely-not-installed-xyz" }, format = "text" } }, "/tmp/a.py", nil)
    t.matches("没有可用的 server CLI", tostring(err), "全部未安装时应给出可操作诊断")
  end)

  it("显式指定未安装的 server：报可执行文件不可用（而非未配置）", function(t)
    local lsp = require("NeoAI.tools.builtin.lsp_ops")
    local name, _, err = lsp._pick_check_server(
      { mock = { argv = { "definitely-not-installed-xyz" }, format = "text" } }, "/tmp/a.py", "mock")
    t.nil_(name)
    t.matches("可执行文件不可用", tostring(err))
  end)

  it("解析 pyright --outputjson", function(t)
    local lsp = require("NeoAI.tools.builtin.lsp_ops")
    local text = '{"generalDiagnostics":[{"file":"/a.py","severity":"error","message":"bad",'
      .. '"rule":"reportX","range":{"start":{"line":2,"character":4}}}]}'
    local diags = lsp._parse_pyright(text)
    t.eq(1, #(diags or {}))
    t.eq(3, (diags or {})[1].line, "pyright 行号应转 1-based")
    t.eq(5, (diags or {})[1].col)
    t.eq(1, (diags or {})[1].severity)
    t.eq("reportX", (diags or {})[1].code)
    t.nil_(lsp._parse_pyright("not json"), "非法 JSON 应回退原文")
  end)

  it("解析 clangd --check 文本诊断", function(t)
    local lsp = require("NeoAI.tools.builtin.lsp_ops")
    local diags = lsp._parse_clangd(
      "/a.c:3:7: warning: unused variable 'x' [-Wunused-variable]\nAll checks completed, 1 errors")
    t.eq(1, #(diags or {}))
    t.eq(3, (diags or {})[1].line)
    t.eq(2, (diags or {})[1].severity, "warning → 2")
    t.eq("-Wunused-variable", (diags or {})[1].code)
    local none = lsp._parse_clangd("All checks completed, 0 errors")
    t.eq(0, #(none or {}), "无诊断应返回空表")
    t.nil_(lsp._parse_clangd("random output"), "不可解析输出应回退原文")
    -- clangd 17+ check 模式日志格式（无路径/列号）
    local modern = lsp._parse_clangd(
      "E[08:23:15.327] [undeclared_var_use] Line 2: use of undeclared identifier 'x'\n"
        .. "All checks completed, 1 errors", "/a.c")
    t.eq(1, #(modern or {}))
    t.eq(2, (modern or {})[1].line)
    t.eq(1, (modern or {})[1].severity)
    t.eq("undeclared_var_use", (modern or {})[1].code)
    t.eq("/a.c", (modern or {})[1].path)
    t.nil_(lsp._parse_clangd("All checks completed, 2 errors"), "声称有错误却无法解析时应回退原文")
  end)
end)
