--- 沙箱进程实例隔离与启动路径回归
--- @module NeoAI.tests.test_sandbox_instance
--- 覆盖：
---   1. 每个 nvim 进程使用独立实例 store 根，待审队列跨实例互不可见；
---   2. 热重载（同进程 shutdown/init）保留本实例待审队列；
---   3. `sandbox.init` 不再同步探测运行时能力（懒加载，避免拖慢新开 nvim）；
---   4. 过期实例目录回收只清理已死进程。

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

tests.suite("sandbox_instance", function(_, it)
  it("不同实例的 store 根与待审队列互不可见", function(t)
    local sandbox = require("NeoAI.sandbox")
    local instance = require("NeoAI.sandbox.instance")
    local review = require("NeoAI.sandbox.review")
    local store = require("NeoAI.sandbox.store")
    local base = vim.fn.tempname()
    with_config({ tools = { sandbox = { workspace_root = base } } }, function()
      instance.set_id("1111_1")
      sandbox.reset()
      t.eq(base .. "/instances/1111_1", store.root(), "store 根应为实例目录")
      t.eq(base, sandbox.base_root(), "base_root 应返回配置基根")
      review.enqueue({
        candidate_digest = "sha256:iso_a",
        files = { { path = "/tmp/iso_a", action = "modify" } },
        created_at = 1,
      }, { tool = "edit_file" })
      t.eq(1, sandbox.pending_count(), "本实例应有 1 条待审")

      -- 模拟另一个并发 nvim 实例：仅切换实例身份，不删除第一实例目录。
      instance.set_id("2222_1")
      store.init(instance.root(base))
      review.reset()
      t.eq(base .. "/instances/2222_1", store.root(), "另一实例根不同")
      t.eq(0, sandbox.pending_count(), "另一实例不应看到第一实例的待审")

      -- 切回第一实例：自己的待审仍在。
      instance.set_id("1111_1")
      store.init(instance.root(base))
      review.reset()
      t.eq(1, sandbox.pending_count(), "本实例待审应保留")
    end)
    instance.reset()
    pcall(vim.fn.delete, base, "rf")
  end)

  it("同进程热重载保留本实例待审队列", function(t)
    local sandbox = require("NeoAI.sandbox")
    local instance = require("NeoAI.sandbox.instance")
    local base = vim.fn.tempname()
    with_config({ tools = { sandbox = { workspace_root = base } } }, function()
      instance.set_id("3333_1")
      sandbox.reset()
      sandbox.review.enqueue({
        candidate_digest = "sha256:hot_a",
        files = { { path = "/tmp/hot_a", action = "modify" } },
        created_at = 1,
      }, { tool = "edit_file" })
      t.eq(1, sandbox.pending_count())
      -- 热重载：shutdown 清空暂存但保留待审；init 重新水合。
      sandbox.shutdown()
      sandbox.init()
      t.eq(1, sandbox.pending_count(), "热重载后待审应保留")
    end)
    instance.reset()
    pcall(vim.fn.delete, base, "rf")
  end)

  it("shutdown 等待后台后处理受 shutdown_timeout_ms 约束（卡住不长时间阻塞退出）", function(t)
    local sandbox = require("NeoAI.sandbox")
    local wrapper = require("NeoAI.sandbox.wrapper")
    local async = require("NeoAI.utils.async")
    local base = vim.fn.tempname()
    with_config({ tools = { sandbox = { workspace_root = base, shutdown_timeout_ms = 150 } } }, function()
      sandbox.reset()
      -- 模拟一个永不完成的在途后处理链：shutdown 不应无限/长时间等待。
      wrapper._set_postprocess_pending(async.Deferred.new())
      t.true_(sandbox.postprocess_pending(), "应有在途后处理（否则用例无效）")
      local t0 = vim.uv.hrtime()
      sandbox.shutdown()
      local dt = (vim.uv.hrtime() - t0) / 1e6
      wrapper._reset_postprocess()
      t.true_(dt < 1500, string.format("shutdown 应受 shutdown_timeout_ms 约束（实际 %.0f ms）", dt))
      t.true_(dt >= 100, string.format("shutdown 应至少等待配置的时长（实际 %.0f ms）", dt))
    end)
    sandbox.init()
    pcall(vim.fn.delete, base, "rf")
  end)

  it("init 不同步探测运行时能力（懒加载）", function(t)
    local sandbox = require("NeoAI.sandbox")
    local runtime = require("NeoAI.sandbox.runtime")
    local base = vim.fn.tempname()
    with_config({ tools = { sandbox = { workspace_root = base } } }, function()
      sandbox.reset()
      local orig = runtime.probe
      local calls = 0
      runtime.probe = function(...)
        calls = calls + 1
        return orig(...)
      end
      local ok, err = pcall(function()
        sandbox.shutdown()
        sandbox.init()
      end)
      runtime.probe = orig
      if not ok then error(err, 0) end
      t.eq(0, calls, "sandbox.init 不应同步探测运行时能力")
    end)
    pcall(vim.fn.delete, base, "rf")
  end)

  it("runtime.warm 预热能力与 overlay 探测（幂等、可重复调用）", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    local out = runtime.warm()
    t.eq("table", type(out))
    t.eq("boolean", type(out.capabilities), "应返回 capabilities 布尔")
    t.eq("table", type(runtime.capabilities()), "预热后能力应可用")
    -- 幂等：重复调用不报错（探测结果本身有缓存）
    t.eq("table", type(runtime.warm()))
  end)

  it("gc 只回收已死进程的实例目录", function(t)
    local instance = require("NeoAI.sandbox.instance")
    local base = vim.fn.tempname()
    local live = base .. "/instances/" .. tostring(vim.fn.getpid()) .. "_1"
    local dead = base .. "/instances/99999999_1"
    vim.fn.mkdir(live, "p")
    vim.fn.mkdir(dead, "p")
    local removed = instance.gc(base)
    t.eq(1, removed, "应回收 1 个已死实例")
    t.true_(vim.fn.isdirectory(live) == 1, "存活实例目录应保留")
    t.eq(0, vim.fn.isdirectory(dead), "已死实例目录应删除")
    vim.fn.delete(base, "rf")
  end)

  it("异步落盘失败被检测并保留内存缓存（写入失败不被当作成功）", function(t)
    local sandbox = require("NeoAI.sandbox")
    local store = require("NeoAI.sandbox.store")
    local work = require("NeoAI.utils.work")
    local async = require("NeoAI.utils.async")
    local base = vim.fn.tempname()
    with_config({ tools = { sandbox = { workspace_root = base } } }, function()
      sandbox.reset()
      -- 模拟线程池原子写失败：work.run 直接以 "\0<err>" 解析，不真正落盘。
      local orig_run = work.run
      work.run = function()
        local d = async.Deferred.new()
        d:resolve("\0ENOSPC")
        return d
      end
      local ok, err = pcall(function()
        local cand = { candidate_digest = "sha256:asyncfail", created_at = 1, files = {} }
        store.write_candidate_async(cand)
        t.true_(vim.wait(2000, function()
          return next(store.write_errors()) ~= nil
        end, 20), "写入失败应被记录（不再静默当作成功）")
        t.not_nil(store.read_candidate("sha256:asyncfail"),
          "失败时内存缓存应保留，刚写入的内容仍可读回")
      end)
      work.run = orig_run
      if not ok then error(err, 0) end
    end)
    sandbox.reset()
    pcall(vim.fn.delete, base, "rf")
  end)
end)
