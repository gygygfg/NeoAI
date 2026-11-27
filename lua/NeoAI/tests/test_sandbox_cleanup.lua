--- 沙箱存储自动清理（cache 目录）
--- @module 'NeoAI.tests.test_sandbox_cleanup'
--- 覆盖：启动回收死进程实例 / 超龄旧布局目录；退出删除本进程实例；开关关闭时不动；
---       插件热重载（非进程退出）不删实例目录。
--- 说明：全部在临时 base 根上进行，不触碰真实 `~/.cache/nvim/NeoAI/sandbox`。

local tests = require("NeoAI.tests")

--- 在指定 base 根与 cleanup 配置下运行
--- @param base string
--- @param over table|nil cleanup 覆盖项
--- @param fn function
local function with_base(base, over, fn)
  local config_store = require("NeoAI.kernel.config_store")
  local saved = config_store.get_all()
  local cfg = { tools = { sandbox = { workspace_root = base, cleanup = over or {} } } }
  config_store.load(cfg)
  local ok, err = pcall(fn)
  config_store.load(saved)
  if not ok then error(err, 0) end
end

--- 一个确定不存在的 pid（模拟「已死进程」）
--- @return number
local function dead_pid()
  local pid = 999998
  while pid > 100 do
    local ok, res = pcall(vim.uv.kill, pid, 0)
    if not ok or (res ~= true and res ~= 0) then return pid end
    pid = pid - 1
  end
  return 999998
end

--- 触碰目录/文件 mtime（秒）
local function set_age(path, seconds_ago)
  local now = os.time() - seconds_ago
  pcall(vim.uv.fs_utime, path, now, now)
end

tests.suite("sandbox_cleanup", function(_, it)
  local sandbox = require("NeoAI.sandbox")
  local instance = require("NeoAI.sandbox.execution.instance")

  it("start：回收死进程的实例目录（含 candidates/blob 残留）", function(t)
    local base = vim.fn.tempname()
    local dead = dead_pid()
    local leftover = base .. "/instances/" .. tostring(dead) .. "_1"
    vim.fn.mkdir(leftover .. "/candidates", "p")
    assert(io.open(leftover .. "/candidates/x.json", "w")):close()
    with_base(base, { on_start = true, legacy_max_age = 3600 }, function()
      local removed = sandbox.cleanup({ phase = "start" })
      t.eq(0, vim.fn.isdirectory(leftover), "死进程实例目录应被回收")
      t.ok(removed >= 1)
    end)
    pcall(vim.fn.delete, base, "rf")
  end)

  it("start：清理超龄的旧布局目录，未超龄保留", function(t)
    local base = vim.fn.tempname()
    local old = base .. "/candidates"
    local fresh = base .. "/reviews"
    vim.fn.mkdir(old, "p")
    assert(io.open(old .. "/a.json", "w")):close()
    vim.fn.mkdir(fresh, "p")
    assert(io.open(fresh .. "/b.json", "w")):close()
    set_age(old, 7200)
    with_base(base, { on_start = true, legacy_max_age = 3600 }, function()
      sandbox.cleanup({ phase = "start" })
      t.eq(0, vim.fn.isdirectory(old), "超龄旧布局目录应被清理")
      t.eq(1, vim.fn.isdirectory(fresh), "未超龄目录应保留")
    end)
    pcall(vim.fn.delete, base, "rf")
  end)

  it("start 关闭（on_start=false）时不动任何目录", function(t)
    local base = vim.fn.tempname()
    local dead = dead_pid()
    local leftover = base .. "/instances/" .. tostring(dead) .. "_1"
    vim.fn.mkdir(leftover, "p")
    with_base(base, { on_start = false }, function()
      t.eq(0, sandbox.cleanup({ phase = "start" }))
      t.eq(1, vim.fn.isdirectory(leftover), "关闭时不得删除")
    end)
    pcall(vim.fn.delete, base, "rf")
  end)

  it("exit：删除本进程实例目录；on_exit=false 时保留", function(t)
    local base = vim.fn.tempname()
    local prev_id = instance.id()
    with_base(base, { on_exit = true }, function()
      instance.set_id("424242_1")
      local root = instance.root(base)
      vim.fn.mkdir(root .. "/candidates", "p")
      t.eq(1, vim.fn.isdirectory(root))
      sandbox.cleanup({ phase = "exit" })
      t.eq(0, vim.fn.isdirectory(root), "进程退出应删除本进程实例目录")
    end)
    with_base(base, { on_exit = false }, function()
      instance.set_id("424243_1")
      local root = instance.root(base)
      vim.fn.mkdir(root, "p")
      sandbox.cleanup({ phase = "exit" })
      t.eq(1, vim.fn.isdirectory(root), "on_exit=false 时保留")
    end)
    instance.set_id(prev_id)
    pcall(vim.fn.delete, base, "rf")
  end)

  it("插件热重载（sandbox.shutdown 非退出阶段）不删本进程实例目录", function(t)
    local base = vim.fn.tempname()
    local lifecycle = require("NeoAI.kernel.lifecycle")
    local shutting = lifecycle.is_shutting_down()
    with_base(base, { on_exit = true, on_start = false }, function()
      instance.set_id("424244_1")
      local root = instance.root(base)
      vim.fn.mkdir(root, "p")
      sandbox.init()
      -- 模拟热重载：shutdown 时 lifecycle 未处于 shutting_down
      t.false_(shutting, "测试进程不应处于关闭阶段")
      sandbox.shutdown()
      t.eq(1, vim.fn.isdirectory(root), "热重载不得删除实例（否则待审队列/暂存丢失）")
    end)
    pcall(vim.fn.delete, base, "rf")
  end)
end)
