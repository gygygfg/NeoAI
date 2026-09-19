--- LSP 命名空间覆盖测试
--- @module NeoAI.tests.test_sandbox_lsp
--- 覆盖：opt-in 开关、bwrap+overlay 命令包装、暂存物化、install/卸载恢复。

local tests = require("NeoAI.tests")

local function with_config(overrides, fn)
  local config_store = require("NeoAI.kernel.config_store")
  local saved = config_store.get_all()
  local merged = vim.deepcopy(overrides or {})
  merged.tools = merged.tools or {}
  merged.tools.sandbox = merged.tools.sandbox or {}
  if merged.tools.sandbox.ephemeral_roots == nil then
    merged.tools.sandbox.ephemeral_roots = {}
  end
  config_store.load(merged)
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
      -- 前缀先经 fd 关闭包装（bash/python/sh）再 exec bwrap；bwrap 可能不在首位。
      local bw
      for i, v in ipairs(wrapped) do if v == "bwrap" then bw = i end end
      t.not_nil(bw, "应包含 bwrap 启动")
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

  it("LSP 隔离标志与 overlay 探测一致（不用 --unshare-all）", function(t)
    local lsp = require("NeoAI.sandbox.lsp")
    local sandbox = require("NeoAI.sandbox")
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local fs = require("NeoAI.utils.fs")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    with_config({ tools = { sandbox = { mode = "dry_run", review = { enabled = true }, lsp_overlay = { enabled = true } } } }, function()
      sandbox.reset()
      local wrapped = lsp.wrap_cmd({ "fake-lsp", "--stdio" }, { cwd = dir })
      if not wrapped then return end -- overlay 不可用环境跳过
      local joined = table.concat(wrapped, " ")
      -- 硬编码 --unshare-all 会让 overlay 在 userns 内只读（lower=/ 时挂载 EINVAL），
      -- 导致 LSP 启动即退出；必须使用探测所用的 bwrap_flags()。
      t.true_(joined:find("--unshare-all", 1, true) == nil, "不应使用 --unshare-all")
      for _, f in ipairs(runtime.bwrap_flags()) do
        t.true_(joined:find(f, 1, true) ~= nil, "应包含探测标志 " .. f)
      end
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("npm/npx 缓存直连宿主（避免 overlay 被 wipe 后重复下载）", function(t)
    local lsp = require("NeoAI.sandbox.lsp")
    local sandbox = require("NeoAI.sandbox")
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local npm_dir = vim.fn.expand("~/.npm")
    if vim.fn.isdirectory(npm_dir) ~= 1 then return end
    local fs = require("NeoAI.utils.fs")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    with_config({ tools = { sandbox = { mode = "dry_run", review = { enabled = true }, lsp_overlay = { enabled = true } } } }, function()
      sandbox.reset()
      local wrapped = lsp.wrap_cmd({ "fake-lsp", "--stdio" }, { cwd = dir })
      if not wrapped then return end
      local found = false
      for i = 1, #wrapped - 2 do
        if wrapped[i] == "--bind" and wrapped[i + 1] == npm_dir and wrapped[i + 2] == npm_dir then
          found = true
        end
      end
      t.true_(found, "应把 ~/.npm rw bind 到宿主")
    end)
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

  it("不再全局包装 vim.lsp.rpc.start（编辑器 LSP 不受影响）", function(t)
    local lsp = require("NeoAI.sandbox.lsp")
    lsp.reset()
    -- 模块存在 clients_for / client_supporting 的 AI 专用 API，但不得改动 rpc.start
    t.not_nil(lsp.clients_for, "应提供 clients_for")
    t.not_nil(lsp.client_supporting, "应提供 client_supporting")
    t.nil_(lsp.install, "不应再提供全局 install")
  end)

  it("配置关闭时 AI 沙箱克隆为空", function(t)
    local lsp = require("NeoAI.sandbox.lsp")
    with_config({ tools = { sandbox = { lsp_overlay = { enabled = false } } } }, function()
      lsp.reset()
      t.eq(0, #lsp.clients_for(vim.api.nvim_get_current_buf()), "关闭时不应有克隆")
      t.nil_(lsp.client_supporting("textDocument/hover", vim.api.nvim_get_current_buf()), "关闭时应返回 nil")
    end)
  end)
end)
