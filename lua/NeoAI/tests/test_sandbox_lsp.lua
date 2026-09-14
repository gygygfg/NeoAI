--- LSP 命名空间覆盖测试
--- @module NeoAI.tests.test_sandbox_lsp
--- 覆盖：opt-in 开关、bwrap+overlay 命令包装、暂存物化、install/卸载恢复。

local tests = require("NeoAI.tests")

local function with_config(overrides, fn)
  local config_store = require("NeoAI.kernel.config_store")
  local saved = config_store.get_all()
  config_store.load(overrides)
  local ok, err = pcall(fn)
  config_store.load(saved)
  if not ok then error(err, 0) end
end

tests.suite("sandbox_lsp", function(_, it)
  it("默认关闭时不包装 LSP 命令", function(t)
    local lsp = require("NeoAI.sandbox.lsp")
    with_config({ tools = { sandbox = { lsp_overlay = { enabled = false } } } }, function()
      t.nil_(lsp.wrap_cmd({ "fake-lsp", "--stdio" }, { cwd = vim.fn.getcwd() }), "关闭时应返回 nil")
    end)
  end)

  it("启用且 overlay 可用时把 LSP 命令包进 bwrap + overlay", function(t)
    local lsp = require("NeoAI.sandbox.lsp")
    local sandbox = require("NeoAI.sandbox")
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local fs = require("NeoAI.utils.fs")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    with_config({ tools = { sandbox = { mode = "dry_run", review = { enabled = true }, lsp_overlay = { enabled = true } } } }, function()
      sandbox.reset()
      local wrapped = lsp.wrap_cmd({ "fake-lsp", "--stdio" }, { cwd = dir })
      if not wrapped then return end -- overlay 不可用环境跳过
      t.eq("bwrap", wrapped[1], "应以 bwrap 启动")
      t.eq("fake-lsp", wrapped[#wrapped - 1], "原始命令应保留在末尾")
      t.eq("--stdio", wrapped[#wrapped], "原始参数顺序不变")
      local joined = table.concat(wrapped, " ")
      t.true_(joined:find("--overlay", 1, true) ~= nil, "应挂载 overlay")
      t.true_(joined:find("--ro-bind", 1, true) ~= nil, "应为只读 rootfs")
      t.true_(joined:find("--chdir", 1, true) ~= nil, "应设置工作目录")
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
  end)

  it("refresh 把暂存内容物化进 LSP overlay upper", function(t)
    local lsp = require("NeoAI.sandbox.lsp")
    local sandbox = require("NeoAI.sandbox")
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local fs = require("NeoAI.utils.fs")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    fs.write_file(dir .. "/f.txt", "real\n")
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    with_config({ tools = {
      approval = { mode = "async" },
      sandbox = { mode = "dry_run", review = { enabled = true }, lsp_overlay = { enabled = true } },
    } }, function()
      sandbox.reset()
      local done = false
      require("NeoAI.tools").execute("edit_file", {
        filepath = dir .. "/f.txt", mode = "write", content = "staged\n", description = "t",
      }, {}):then_(function()
        local specs = lsp.refresh(dir)
        if specs then
          t.eq("staged\n", fs.read_file(specs[1].upper .. "/f.txt"), "upper 应含暂存内容")
        end
        t.eq("real\n", fs.read_file(dir .. "/f.txt"), "真实文件不应改动")
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(5000, function() return done end), "应完成")
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
  end)

  it("install/uninstall 恢复 vim.lsp.rpc.start", function(t)
    local lsp = require("NeoAI.sandbox.lsp")
    lsp.reset()
    local original = vim.lsp.rpc.start
    local cleanup = lsp.install()
    t.not_nil(cleanup, "应安装成功")
    t.true_(vim.lsp.rpc.start ~= original, "应替换 rpc.start")
    cleanup()
    t.eq(original, vim.lsp.rpc.start, "卸载应恢复原始实现")
    lsp.reset()
  end)
end)
