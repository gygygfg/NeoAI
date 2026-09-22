--- 沙箱降权 / 属主持久 / cgroup 可写 测试
--- @module NeoAI.tests.test_sandbox_privdrop
--- 覆盖：载荷可在沙箱内降权到非 root 用户（runuser/setpriv，供 PostgreSQL 等拒绝 root 的服务）；
--- chown 等属主改动跨命令持久（sysadmin 命令走常驻实例的持久 overlay）；/sys/fs/cgroup 可写
--- （委派 cgroup 子树，AI/服务可创建子 cgroup 并写 memory.max）。

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

local function sandbox_config(extra)
  local base = {
    enabled = true, fail_closed = true, mode = "dry_run",
    ephemeral_roots = {}, resident = { enabled = true },
    limits = { delegate_cgroup = true },
  }
  for k, v in pairs(extra or {}) do base[k] = v end
  return base
end

--- 同步执行一条 run_command，返回输出字符串（失败返回 nil, err）。
--- 不在命令间重置沙箱：跨命令持久性（chown）依赖同一沙箱会话/常驻实例。
local function run(t, command)
  local out, err, done = nil, nil, false
  require("NeoAI.tools").execute("run_command", { command = command, description = "t" }, {})
    :then_(function(v) out = tostring(v); done = true end, function(e) err = e; done = true end)
  t.true_(vim.wait(20000, function() return done end, 50), "命令应返回: " .. command)
  return out, err
end

tests.suite("sandbox_privdrop", function(_, it)
  it("沙箱内可降权到非 root 用户（runuser / setpriv）", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    if vim.fn.executable("runuser") ~= 1 then return end
    with_config({ tools = { approval = { mode = "auto_allow" }, sandbox = sandbox_config() } }, function()
      require("NeoAI.sandbox").reset()
      local out, err = run(t, "runuser -u nobody -- id -u 2>&1")
      t.eq(nil, err, "不应报错: " .. tostring(err and (err.message or err)))
      t.matches("65534", tostring(out), "runuser 应降权到 nobody(65534)，实际: " .. tostring(out))
      require("NeoAI.sandbox.resident").stop({ timeout_ms = 5000 })
    end)
  end)

  it("chown 属主改动跨命令持久（sysadmin 走常驻实例持久 overlay）", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    if vim.fn.executable("chown") ~= 1 then return end
    with_config({ tools = { approval = { mode = "auto_allow" }, sandbox = sandbox_config() } }, function()
      require("NeoAI.sandbox").reset()
      local _, err1 = run(t, "rm -f /tmp/.neoai_chown_probe && touch /tmp/.neoai_chown_probe && chown 65534:65534 /tmp/.neoai_chown_probe && stat -c %u /tmp/.neoai_chown_probe")
      t.eq(nil, err1, "chown 命令不应报错: " .. tostring(err1 and (err1.message or err1)))
      -- 第二条命令：新命令（T0）在同一常驻实例的持久视图内应看到属主仍是 nobody。
      local out2, err2 = run(t, "stat -c %u /tmp/.neoai_chown_probe 2>&1")
      t.eq(nil, err2, "stat 不应报错: " .. tostring(err2 and (err2.message or err2)))
      t.matches("65534", tostring(out2), "属主应跨命令持久为 nobody(65534)，实际: " .. tostring(out2))
      require("NeoAI.sandbox.resident").stop({ timeout_ms = 5000 })
    end)
  end)

  it("沙箱内 /sys/fs/cgroup 可写：可创建子 cgroup 并写 memory.max", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local cgroup = require("NeoAI.sandbox.cgroup")
    if not cgroup.delegation_enabled() then return end
    with_config({ tools = { approval = { mode = "auto_allow" }, sandbox = sandbox_config() } }, function()
      require("NeoAI.sandbox").reset()
      local out, err = run(t,
        "test -w /sys/fs/cgroup && mkdir -p /sys/fs/cgroup/neoai_probe && "
        .. "echo max > /sys/fs/cgroup/neoai_probe/memory.max 2>/dev/null; "
        .. "cat /sys/fs/cgroup/neoai_probe/memory.max 2>&1")
      t.eq(nil, err, "不应报错: " .. tostring(err and (err.message or err)))
      t.matches("max", tostring(out), "应能在委派子树内创建子 cgroup 并写 memory.max，实际: " .. tostring(out))
      require("NeoAI.sandbox.resident").stop({ timeout_ms = 5000 })
    end)
  end)
end)
