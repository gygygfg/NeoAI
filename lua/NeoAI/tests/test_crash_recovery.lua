--- 崩溃自动恢复
--- @module 'NeoAI.tests.test_crash_recovery'
--- 覆盖：干净退出标记写入/删除、不干净退出检测（死 pid / 自身 pid 跳过）、
---       被中断会话识别（user / tool / 带 tool_calls 的 assistant 三种尾部缺口）、
---       recover 回收开关与限流、start/stop 幂等与标记清理。
--- 说明：标记目录与会话来源均注入临时值，不触碰真实 `~/.cache` 会话与沙箱。

local tests = require("NeoAI.tests")

local function tmpdir(tag)
  local dir = vim.fn.stdpath("cache") .. "/neoai_recovery_test_" .. tostring(tag) .. "_" .. tostring(vim.uv.hrtime())
  vim.fn.mkdir(dir, "p")
  return dir
end

local function cleanup(dir)
  if dir and dir ~= "" then pcall(vim.fn.delete, dir, "rf") end
end

--- 找一个确定不存在的 pid（用于模拟「已死进程」的残留标记）
--- @return number
local function dead_pid()
  local pid = 999999
  while pid > 100 do
    local ok, res = pcall(vim.uv.kill, pid, 0)
    if not ok or (res ~= true and res ~= 0) then return pid end
    pid = pid - 1
  end
  return 999999
end

--- 会话夹具
local function session(id, updated_at, tail)
  local msgs = {
    { role = "user", content = "hello" },
    { role = "assistant", content = "hi" },
  }
  for _, m in ipairs(tail or {}) do msgs[#msgs + 1] = m end
  return { id = id, updated_at = updated_at, messages = msgs }
end

tests.suite("crash_recovery", function(_, it)
  local rec = require("NeoAI.core.session.recovery")

  it("标记：写入 / 删除（幂等）", function(t)
    local dir = tmpdir("mark")
    rec.reset()
    rec._set_dir(dir)
    t.true_(rec.mark_started(), "写标记应成功")
    local marker = dir .. "/alive-" .. tostring(vim.fn.getpid()) .. ".json"
    t.eq(1, vim.fn.filereadable(marker), "标记文件应存在")
    rec.mark_clean_exit()
    t.eq(0, vim.fn.filereadable(marker), "干净退出应删除标记")
    rec.mark_clean_exit() -- 幂等
    cleanup(dir)
    rec.reset()
  end)

  it("detect：自身标记不算不干净；死 pid 标记算", function(t)
    local dir = tmpdir("detect")
    rec.reset()
    rec._set_dir(dir)
    rec.mark_started()
    t.false_(rec.detect().unclean, "只有自身标记时不应判定崩溃")

    local dead = dead_pid()
    local path = dir .. "/alive-" .. tostring(dead) .. ".json"
    local f = assert(io.open(path, "w"))
    f:write(vim.json.encode({ pid = dead, started_at = os.time() - 100, cwd = "/tmp" }))
    f:close()
    local det = rec.detect()
    t.true_(det.unclean, "死 pid 标记应判定崩溃")
    t.eq(dead, det.markers[1].pid)
    cleanup(dir)
    rec.reset()
  end)

  it("interrupted_sessions：只挑尾部有缺口的会话并按更新时间降序", function(t)
    local now = os.time()
    local sessions = {
      done = session("s-done", now, {}), -- assistant 收尾 → 正常
      user_tail = session("s-user", now - 10, { { role = "user", content = "again" } }),
      tool_tail = session("s-tool", now - 20, {
        { role = "assistant", content = "", tool_calls = { { id = "c1" } } },
        { role = "tool", tool_call_id = "c1", content = "ok" },
      }),
      calls_tail = session("s-calls", now - 30, {
        { role = "assistant", content = "", tool_calls = { { id = "c2" } } },
      }),
      old = session("s-old", now - 99999, { { role = "user", content = "x" } }),
    }
    rec.reset()
    rec._set_session_source(function() return sessions end)
    local list = rec.interrupted_sessions({ { pid = 1, started_at = now - 3600 } }, {})
    local ids = {}
    for _, s in ipairs(list) do ids[#ids + 1] = s.id end
    t.eq(3, #list, "三个有缺口且足够新的会话")
    t.eq("s-user", ids[1], "按 updated_at 降序")
    t.eq("s-tool", ids[2])
    t.eq("s-calls", ids[3])
    rec.reset()
  end)

  it("recover：不干净时回收（可关）+ 列出会话 + 发事件，且不自动重开", function(t)
    local dir = tmpdir("recover")
    local dead = dead_pid()
    rec.reset()
    rec._set_dir(dir)
    local path = dir .. "/alive-" .. tostring(dead) .. ".json"
    local f = assert(io.open(path, "w"))
    f:write(vim.json.encode({ pid = dead, started_at = os.time() - 10 }))
    f:close()
    rec._set_session_source(function()
      return { s1 = session("s1", os.time(), { { role = "user", content = "hi" } }) }
    end)
    local config_store = require("NeoAI.kernel.config_store")
    local saved = config_store.get_all()
    config_store.load({ session = { recovery = { enabled = true, reclaim_sandbox = false, auto_open = 2, notify = false } } })
    local seen = nil
    local events = require("NeoAI.kernel.events")
    local un = require("NeoAI.kernel.event_bus").on(events.SESSION_RECOVERED, function(p) seen = p end)
    local res = rec.recover({})
    un()
    config_store.load(saved)
    t.true_(res.unclean)
    t.false_(res.reclaimed, "reclaim_sandbox=false 时不应回收")
    t.eq(1, #res.sessions)
    t.eq("s1", res.sessions[1].id)
    t.eq(2, res.auto_open, "auto_open 透传配置值")
    t.not_nil(seen, "应发 session:recovered 事件")
    t.eq(1, #seen.sessions)
    cleanup(dir)
    rec.reset()
  end)

  it("start/stop：写标记 + 退出钩子；stop 清理标记与监听", function(t)
    local dir = tmpdir("start")
    rec.reset()
    rec._set_dir(dir)
    rec._set_session_source(function() return {} end)
    local res, stop = rec.start({ install_signals = false })
    t.true_(type(res) == "table")
    local marker = dir .. "/alive-" .. tostring(vim.fn.getpid()) .. ".json"
    t.eq(1, vim.fn.filereadable(marker), "start 应写本进程标记")
    local gname = "NeoAIRecovery" .. vim.fn.getpid()
    --- 统计本进程恢复组上的 VimLeavePre 自动命令数（按 group_name 过滤，
    --- 避免 `group="<name>"` 在部分版本/环境下的查找差异）
    local function _count()
      local n = 0
      for _, ac in ipairs(vim.api.nvim_get_autocmds({ event = "VimLeavePre" })) do
        if ac.group_name == gname then n = n + 1 end
      end
      return n
    end
    t.eq(1, _count(), "应安装 VimLeavePre 钩子")
    stop()
    t.eq(0, vim.fn.filereadable(marker), "stop 应删除标记")
    t.eq(0, _count(), "stop 应删除自动命令")
    stop() -- 幂等
    cleanup(dir)
    rec.reset()
  end)

  it("session.recovery.enabled=false 时 start 为 no-op", function(t)
    local dir = tmpdir("off")
    rec.reset()
    rec._set_dir(dir)
    local config_store = require("NeoAI.kernel.config_store")
    local saved = config_store.get_all()
    config_store.load({ session = { recovery = { enabled = false } } })
    local res, stop = rec.start({ install_signals = false })
    config_store.load(saved)
    t.false_(res.unclean)
    local marker = dir .. "/alive-" .. tostring(vim.fn.getpid()) .. ".json"
    t.eq(0, vim.fn.filereadable(marker), "关闭时不应写标记")
    stop()
    cleanup(dir)
    rec.reset()
  end)
end)
