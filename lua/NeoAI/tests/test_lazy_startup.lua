--- 懒加载启动测试
--- @module NeoAI.tests.test_lazy_startup
--- setup() 只登记占位（命令/键位），不启动服务；首次显式 ensure_started_sync 才分两阶段
--- 异步启动。为彻底隔离全局状态，用隔离子进程 nvim 验证。

local tests = require("NeoAI.tests")

--- 定位插件根目录（含 lua/ 的仓库根）
--- @return string
local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":p:h:h:h:h")
end

local CHILD_SCRIPT = [=[-- NeoAI 懒加载子进程校验（自动生成）
local ok, err = xpcall(function()
  local NeoAI = require("NeoAI")
  NeoAI.setup({
    log = { level = "ERROR" },
    session = { auto_save = false },
    mcp = { enabled = false },
    ai = { model_refresh = { on_startup = false } },
    tools = {
      sandbox = {
        observe = { enabled = false },
        systemd = { user = { enabled = false } },
        postprocess = "sync",
        run_as = { uid = 0, gid = 0 },
      },
    },
  })
  local services = require("NeoAI.kernel.services")

  assert(NeoAI.is_phase1_done() == false, "setup 后阶段 1 不应已完成")
  assert(NeoAI.is_fully_started() == false, "setup 后不应已启动")
  assert(services.use("services.ui") == nil, "setup 后 ui 服务不应已提供")
  assert(vim.fn.exists(":NeoAIOpen") == 2, "占位命令 NeoAIOpen 应存在")

  local found = false
  for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
    if m.desc == "打开聊天界面" then found = true break end
  end
  assert(found, "占位键位（打开聊天界面）应存在")

  assert(NeoAI.ensure_started_sync(60000) == true, "懒加载启动应完成")
  assert(NeoAI.is_fully_started(), "应已全量启动")
  assert(NeoAI.is_phase1_done(), "阶段 1 应已完成")
  assert(services.use("services.ui") ~= nil, "启动后 ui 服务应可用")
  assert(services.use("services.tools") ~= nil, "启动后 tools 服务应可用")
  assert(NeoAI.ensure_started_sync(1000) == true, "重复调用应幂等返回 true")
end, debug.traceback)

if ok then
  io.stdout:write("LAZY_TEST_OK\n")
else
  io.stdout:write("LAZY_TEST_FAIL\n" .. tostring(err) .. "\n")
end
]=]

tests.suite("lazy_startup", function(_, it)
  it("setup 只登记，首次调用异步两阶段启动", function(t)
    local root = plugin_root()
    local path = vim.fn.tempname() .. "_neoai_lazy.lua"
    local f = assert(io.open(path, "w"))
    f:write(CHILD_SCRIPT)
    f:close()

    local prog = (vim.v.progpath ~= "" and vim.v.progpath) or "nvim"
    local out = vim.fn.system({
      prog, "--headless", "--clean", "-u", "NONE",
      "--cmd", "set rtp+=" .. root,
      "-c", "luafile " .. vim.fn.fnameescape(path),
      "-c", "qa!",
    })
    pcall(os.remove, path)

    t.true_(out:find("LAZY_TEST_OK", 1, true) ~= nil,
      "子进程应输出 LAZY_TEST_OK，实际输出:\n" .. tostring(out))
  end)
end)
