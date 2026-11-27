--- 镜像 Neovim 工具回归（无沙箱直跑仅用于测试）
--- @module 'NeoAI.tests.test_nvim_mirror'
--- 覆盖：读取未保存 buffer、Lua 返回值、Ex 命令写文件、镜像 buffer 修改不回写主进程。
local tests = require("NeoAI.tests")

local function with_cfg(fn)
  local config_store = require("NeoAI.kernel.config_store")
  local saved = config_store.get_all()
  local merged = vim.deepcopy(saved or {})
  merged.tools = merged.tools or {}
  merged.tools.nvim = {
    enabled = true,
    allow_unisolated = true,
    timeout_ms = 20000,
    max_buffer_bytes = 1024 * 1024,
    max_total_bytes = 4 * 1024 * 1024,
  }
  config_store.load(merged)
  local ok, err = pcall(fn)
  config_store.load(saved)
  if not ok then error(err, 0) end
end

tests.suite("nvim_mirror", function(_, it)
  it("镜像读取未保存 buffer 内容（save-all 实时视图）", function(t)
    local fs = require("NeoAI.utils.fs")
    local ops = require("NeoAI.tools.builtin.nvim_ops")
    with_cfg(function()
      local dir = vim.fn.tempname()
      fs.ensure_dir(dir)
      local p = dir .. "/a.txt"
      fs.write_file(p, "one\ntwo\n")
      vim.cmd("edit " .. vim.fn.fnameescape(p))
      local buf = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "TWO-unsaved", "three" })
      local got, done = nil, false
      ops._run({
        lua = "local b=NeoAI.buf(" .. buf .. "); return table.concat(vim.api.nvim_buf_get_lines(b,0,-1,false), '|')",
        cwd = dir,
      }, function(ok, data)
        got = { ok = ok, data = data }
        done = true
      end)
      t.true_(vim.wait(20000, function() return done end), "镜像应完成")
      t.true_(got.ok, "镜像应成功")
      t.eq("one|TWO-unsaved|three", got.data.result, "应读取未保存内容")
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end)
  end)

  it("镜像内 buffer 修改不回写；Ex 写文件落宿主（测试直跑）", function(t)
    local fs = require("NeoAI.utils.fs")
    local ops = require("NeoAI.tools.builtin.nvim_ops")
    with_cfg(function()
      local dir = vim.fn.tempname()
      fs.ensure_dir(dir)
      local p = dir .. "/b.txt"
      fs.write_file(p, "orig\n")
      vim.cmd("edit " .. vim.fn.fnameescape(p))
      local buf = vim.api.nvim_get_current_buf()
      local out = dir .. "/written.txt"
      local got, done = nil, false
      ops._run({
        ex = "call setline(1, 'changed') | call writefile(['X'], '" .. out .. "')",
        cwd = dir,
      }, function(ok, data)
        got = { ok = ok, data = data }
        done = true
      end)
      t.true_(vim.wait(20000, function() return done end), "镜像应完成")
      t.true_(got.ok, "镜像应成功")
      t.eq("X\n", fs.read_file(out) or "", "Ex 写文件应生效（测试为无沙箱直跑）")
      t.eq("orig", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1], "主进程 buffer 不应被镜像修改")
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end)
  end)

  it("镜像 Lua 错误返回结构化错误，不挂起", function(t)
    local fs = require("NeoAI.utils.fs")
    local ops = require("NeoAI.tools.builtin.nvim_ops")
    with_cfg(function()
      local dir = vim.fn.tempname()
      fs.ensure_dir(dir)
      local got, done = nil, false
      ops._run({ lua = "error('boom')", cwd = dir }, function(ok, data)
        got = { ok = ok, data = data }
        done = true
      end)
      t.true_(vim.wait(20000, function() return done end), "镜像应完成")
      t.false_(got.ok, "应返回失败")
      local msg = type(got.data) == "table" and (got.data.error or "") or tostring(got.data)
      t.true_(tostring(msg):find("boom", 1, true) ~= nil, "应包含错误信息")
    end)
  end)
end)
