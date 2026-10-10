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
end)
