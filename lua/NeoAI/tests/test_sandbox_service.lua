--- 沙箱长驻服务 / 镜像 / 诊断专项测试
--- @module NeoAI.tests.test_sandbox_service
--- 覆盖：service_start/logs/status/stop 生命周期与清理、停止时捕获工作区改动、
--- long_lived 门禁分支、pip/npm/maven 镜像注入、cgroup 事件/OOM 诊断。

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
    ephemeral_roots = {}, service = { enabled = true },
  }
  for k, v in pairs(extra or {}) do base[k] = v end
  return base
end

tests.suite("sandbox_service", function(_, it)
  it("service：启动/日志/状态/停止 + 注册表清理", function(t)
    with_config({ tools = { sandbox = sandbox_config() } }, function()
      require("NeoAI.sandbox").reset()
      local svc_mod = require("NeoAI.sandbox.service")
      local svc, err = svc_mod.start("t1",
        "for i in 1 2 3 4 5; do echo hello-$i; sleep 0.2; done", { cwd = vim.fn.getcwd() })
      t.not_nil(svc, "启动失败: " .. tostring(err))
      t.eq("running", svc.status)
      local got = vim.wait(5000, function()
        return (svc_mod.logs("t1") or ""):find("hello-3", 1, true) ~= nil
      end, 50)
      t.true_(got, "应产生日志")
      local info = svc_mod.status("t1")
      t.not_nil(info)
      t.eq("t1", info.name)
      local stopped = false
      svc_mod.stop("t1", function() stopped = true end)
      t.true_(vim.wait(10000, function() return stopped end, 50), "停止应完成")
      t.eq(nil, svc_mod.status("t1"), "停止后应从注册表移除")
    end)
  end)

  it("service：停止时把服务改动捕获回工作区暂存", function(t)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    with_config({ tools = { sandbox = sandbox_config() } }, function()
      require("NeoAI.sandbox").reset()
      local svc_mod = require("NeoAI.sandbox.service")
      local candidate = require("NeoAI.sandbox.candidate")
      local out = dir .. "/svc_out.txt"
      local svc, err = svc_mod.start("writer",
        "echo svcdata > " .. out .. "; echo READY; sleep 30", { cwd = dir })
      t.not_nil(svc, "启动失败: " .. tostring(err))
      t.true_(vim.wait(5000, function()
        return (svc_mod.logs("writer") or ""):find("READY", 1, true) ~= nil
      end, 50), "服务应就绪")
      local stopped = false
      svc_mod.stop("writer", function() stopped = true end)
      t.true_(vim.wait(10000, function() return stopped end, 50), "停止应完成")
      local staged_path = candidate.read_path(out)
      t.not_nil(staged_path, "服务写入应被捕获进工作区暂存")
      local content = require("NeoAI.utils.fs").read_file(staged_path)
      t.matches("svcdata", content or "")
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("service_* 工具为 long_lived 进程规格，logs/status 为只读", function(t)
    local registry = require("NeoAI.tools.registry")
    local start = registry.get("service_start")
    t.not_nil(start, "service_start 应已注册")
    t.eq("process", start.__sandbox_spec.effect)
    t.true_(start.__sandbox_spec.long_lived == true, "service_start 应标记 long_lived")
    local stop = registry.get("service_stop")
    t.not_nil(stop)
    t.true_(stop.__sandbox_spec.long_lived == true, "service_stop 应标记 long_lived")
    t.eq("read", registry.get("service_logs").__sandbox_spec.effect)
    t.eq("read", registry.get("service_status").__sandbox_spec.effect)
  end)

  it("门禁：service_start 经 long_lived 分支执行并可停止", function(t)
    with_config({
      tools = {
        approval = { mode = "auto_allow" },
        sandbox = sandbox_config(),
      },
    }, function()
      require("NeoAI.sandbox").reset()
      local done, err = false, nil
      require("NeoAI.tools").execute("service_start",
        { name = "gate1", command = "echo hi; sleep 30", description = "t" }, {})
        :then_(function() done = true end, function(e) err = e; done = true end)
      t.true_(vim.wait(15000, function() return done end, 50), "应返回")
      t.eq(nil, err, "不应报错: " .. tostring(err and (err.message or err)))
      local svc_mod = require("NeoAI.sandbox.service")
      t.not_nil(svc_mod.status("gate1"), "服务应已注册")
      svc_mod.stop_all({ timeout_ms = 10000 })
      t.eq(nil, svc_mod.status("gate1"), "stop_all 后应清空")
    end)
  end)

  it("镜像：pip/npm 环境变量 + maven settings.xml 与 MAVEN_OPTS", function(t)
    with_config({
      tools = {
        sandbox = sandbox_config({
          network = {
            mirrors = {
              pip = "https://pypi.tuna.tsinghua.edu.cn/simple",
              npm = "https://registry.npmmirror.com/",
              maven = "https://maven.aliyun.com/repository/public",
            },
          },
        }),
      },
    }, function()
      require("NeoAI.sandbox").reset()
      local runtime = require("NeoAI.sandbox.runtime")
      local env = runtime.sandbox_env({})
      t.eq("https://pypi.tuna.tsinghua.edu.cn/simple", env.PIP_INDEX_URL)
      t.eq("pypi.tuna.tsinghua.edu.cn", env.PIP_TRUSTED_HOST)
      t.eq("https://registry.npmmirror.com/", env.npm_config_registry)
      t.matches("%-s ", env.MAVEN_OPTS or "")
      t.matches("/tmp/.mvn%-settings.xml", env.MAVEN_OPTS or "")
      -- settings.xml 生成在宿主私有目录，由 process_prefix 只读绑定到 guest 路径。
      local host = require("NeoAI.sandbox.conceal").base_host() .. "/runtime/mvn-settings.xml"
      local f = io.open(host, "r")
      t.not_nil(f, "settings.xml 应存在: " .. host)
      local body = f:read("*a")
      f:close()
      t.matches("maven.aliyun.com", body)
    end)
  end)

  it("诊断：cgroup 事件快照与 OOM 判定", function(t)
    local cgroup = require("NeoAI.sandbox.cgroup")
    local snap = cgroup.events_snapshot("/nonexistent")
    t.eq("table", type(snap))
    t.false_(cgroup.snapshot_oom({ memory_events = "oom_kill 0" }))
    t.true_(cgroup.snapshot_oom({ memory_events = "oom_kill 1" }))
    t.true_(cgroup.snapshot_oom({ memory_events = "low 0\noom_group_kill 2" }))
    local diag = require("NeoAI.sandbox.diag")
    local limits = diag.sandbox_limits()
    t.eq("table", type(limits))
    t.eq("boolean", type(limits.systemd))
  end)
end)
