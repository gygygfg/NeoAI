--- 跨进程互斥锁与 overlay 挂载锁解析专项测试
--- @module NeoAI.tests.test_lock
local tests = require("NeoAI.tests")
local lock = require("NeoAI.utils.lock")

tests.suite("lock", function(_, it)
  local function key()
    return "test-lock-" .. vim.fn.tempname()
  end

  it("基本互斥：持有期间不可再获取，释放后可再获取", function(t)
    local k = key()
    local h1 = lock.try_acquire(k)
    t.not_nil(h1, "应能获取")
    t.nil_(lock.try_acquire(k), "持有期间不应再获取")
    lock.release(h1)
    local h2 = lock.try_acquire(k)
    t.not_nil(h2, "释放后应可再获取")
    lock.release(h2)
  end)

  it("不同 key 互不影响（可并行）", function(t)
    local a, b = key(), key()
    local ha = lock.try_acquire(a)
    local hb = lock.try_acquire(b)
    t.not_nil(ha)
    t.not_nil(hb)
    lock.release(ha)
    lock.release(hb)
  end)

  it("陈旧锁（持有进程已退出）可被自动回收", function(t)
    local k = key()
    vim.fn.mkdir(lock._dir(), "p")
    local path = lock._dir() .. "/" .. vim.fn.sha256(k) .. ".lock"
    local f = assert(io.open(path, "w"))
    f:write("999999\n") -- 不存在的 PID
    f:close()
    local h = lock.try_acquire(k)
    t.not_nil(h, "死 PID 的陈旧锁应被回收后获取成功")
    lock.release(h)
  end)

  it("acquire_all：去重且含冲突时整体失败", function(t)
    local a, b = key(), key()
    local handles = lock.acquire_all({ a, a, b }, 1000)
    t.not_nil(handles)
    t.eq(2, #handles, "重复 key 应去重")
    local h2 = lock.acquire_all({ a, key() }, 50)
    t.nil_(h2, "含已持有 key 时应整体失败")
    lock.release_all(handles)
  end)

  it("with：持锁执行并保证释放", function(t)
    local k = key()
    local ran = false
    local ok = lock.with(k, 1000, function() ran = true end)
    t.true_(ok)
    t.true_(ran)
    local h = lock.try_acquire(k)
    t.not_nil(h, "with 结束后应已释放")
    lock.release(h)
  end)
end)

tests.suite("overlay_lock", function(_, it)
  it("overlay_lock_keys：解析 bwrap --overlay 三元组", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    local keys = runtime.overlay_lock_keys({
      "bwrap", "--overlay-src", "/", "--overlay", "/u", "/w", "/", "--", "true",
    })
    t.deep_eq({ "/w" }, keys)
  end)

  it("overlay_lock_keys：无 overlay 返回空", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    t.deep_eq({}, runtime.overlay_lock_keys({ "bwrap", "--ro-bind", "/", "/", "--", "true" }))
  end)
end)
