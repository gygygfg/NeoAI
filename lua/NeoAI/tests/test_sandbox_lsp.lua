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
        -- --unshare-pid 对 Node 系 LSP server 会致其启动后退出（exit 1），LSP 前缀有意去掉。
        if f ~= "--unshare-pid" then
          t.true_(joined:find(f, 1, true) ~= nil, "应包含探测标志 " .. f)
        end
      end
      t.true_(joined:find("--unshare-pid", 1, true) == nil, "LSP 不应隔离 PID 命名空间（Node server 会退出）")
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

  it("LSP server 的 ~/.config 可写（避免状态库只读导致 exit 1）", function(t)
    local lsp = require("NeoAI.sandbox.lsp")
    local sandbox = require("NeoAI.sandbox")
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local cfg_dir = vim.fn.stdpath("config") ~= "" and vim.fn.fnamemodify(vim.fn.stdpath("config"), ":h") or vim.fn.expand("~/.config")
    if vim.fn.isdirectory(cfg_dir) ~= 1 then return end
    local fs = require("NeoAI.utils.fs")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    with_config({ tools = { sandbox = { mode = "dry_run", review = { enabled = true }, lsp_overlay = { enabled = true } } } }, function()
      sandbox.reset()
      local wrapped = lsp.wrap_cmd({ "fake-lsp", "--stdio" }, { cwd = dir })
      if not wrapped then return end
      local found = false
      for i = 1, #wrapped - 2 do
        if wrapped[i] == "--bind" and wrapped[i + 1] == cfg_dir and wrapped[i + 2] == cfg_dir then
          found = true
        end
      end
      t.true_(found, "应把配置目录（XDG_CONFIG_HOME，默认 ~/.config）rw bind 到宿主")
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
        file_path = dir .. "/f.txt", mode = "write", content = "staged\n", description = "t",
      }, {}):then_(function()
        local specs = lsp.refresh(dir)
        if specs then
          local creal = fs.canonical(dir .. "/f.txt")
          local found, rel
          for _, s in ipairs(specs) do
            if s.root == "/" then found = s; rel = creal:sub(2)
            elseif creal:sub(1, #s.root + 1) == s.root .. "/" then found = s; rel = creal:sub(#s.root + 2) end
          end
          t.not_nil(found, "应有一个覆盖暂存文件的 overlay 规格")
          t.eq("staged\n", fs.read_file(found.upper .. "/" .. rel), "upper 应含暂存内容")
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

  it("LSP overlay 覆盖所有已暂存路径（与文件工具同一命名空间视图）", function(t)
    local lsp = require("NeoAI.sandbox.lsp")
    local sandbox = require("NeoAI.sandbox")
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local fs = require("NeoAI.utils.fs")
    local cwd = vim.fn.tempname()
    local outside = vim.fn.tempname()
    fs.ensure_dir(cwd)
    fs.ensure_dir(outside)
    fs.write_file(outside .. "/g.txt", "real\n")
    local prev = vim.fn.getcwd()
    vim.fn.chdir(cwd)
    with_config({ tools = {
      approval = { mode = "async" },
      sandbox = { mode = "dry_run", read_all = false, review = { enabled = true }, lsp_overlay = { enabled = true } },
    } }, function()
      sandbox.reset()
      local done = false
      require("NeoAI.tools").execute("edit_file", {
        file_path = outside .. "/g.txt", mode = "write", content = "staged\n", description = "t",
      }, {}):then_(function()
        local specs = lsp.refresh(cwd)
        if not specs then done = true; return end
        local creal = fs.canonical(outside .. "/g.txt")
        local found
        for _, s in ipairs(specs) do
          if s.root == creal or creal:sub(1, #s.root + 1) == s.root .. "/" then found = s end
        end
        t.not_nil(found, "LSP overlay 应覆盖工作区外的暂存路径")
        local rel = creal:sub(#found.root + 2)
        t.eq("staged\n", fs.read_file(found.upper .. "/" .. rel), "LSP upper 应含暂存内容")
        t.eq("real\n", fs.read_file(outside .. "/g.txt"), "真实文件不应改动")
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(10000, function() return done end), "应完成")
    end)
    vim.fn.chdir(prev)
    sandbox.reset()
    vim.fn.delete(cwd, "rf")
    vim.fn.delete(outside, "rf")
  end)

  it("LSP 工具用暂存内容同步后台 buffer（didOpen 与沙箱视图一致）", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local helpers = require("NeoAI.tools.builtin.tool_helpers")
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local real = dir .. "/f.lua"
    fs.write_file(real, "local x = 1\n")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local bufnr = helpers.ensure_buffer(real)
      t.not_nil(bufnr, "应能后台加载 buffer")
      local done = false
      require("NeoAI.tools").execute("edit_file", {
        file_path = real, mode = "write", content = "local y = 2\n", description = "t",
      }, {}):then_(function()
        helpers.sync_buffer_from_sandbox(bufnr, real)
        t.eq("local y = 2",
          table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n"),
          "后台 buffer 应同步为暂存内容")
        t.eq("local x = 1\n", fs.read_file(real), "真实文件不应改动")
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(10000, function() return done end), "应完成")
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
    sandbox.reset()
    vim.fn.delete(dir, "rf")
  end)

  it("LSP 命名空间与 run_command 共享暂存视图（同一路径同一内容）", function(t)
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
        file_path = dir .. "/f.txt", mode = "write", content = "staged\n", description = "t",
      }, {}):then_(function()
        local wrapped = lsp.wrap_cmd({ "cat", "f.txt" }, { cwd = dir })
        if not wrapped then done = true; return end
        local out = {}
        vim.fn.jobstart(wrapped, {
          stdout_buffered = true, stderr_buffered = true,
          on_stdout = function(_, d) for _, l in ipairs(d) do if l ~= "" then out[#out + 1] = l end end end,
          on_stderr = function(_, d) for _, l in ipairs(d) do if l ~= "" then out[#out + 1] = "ERR:" .. l end end end,
          on_exit = function(_, c) out[#out + 1] = "EXIT=" .. c end,
        })
        t.true_(vim.wait(15000, function() return #out > 0 and out[#out]:match("^EXIT=") ~= nil end), "命令应完成")
        t.matches("staged", table.concat(out, "\n"), "LSP 命名空间应看到暂存内容")
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(10000, function() return done end), "应完成")
    end)
    vim.fn.chdir(prev)
    sandbox.reset()
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
