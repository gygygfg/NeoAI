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

  it("service_* 工具不再对 AI 注册（内部模块仅供 systemd 门面复用）", function(t)
    local registry = require("NeoAI.tools.registry")
    t.eq(nil, registry.get("service_start"), "service_start 不应注册")
    t.eq(nil, registry.get("service_stop"), "service_stop 不应注册")
    t.eq(nil, registry.get("service_logs"), "service_logs 不应注册")
    t.eq(nil, registry.get("service_status"), "service_status 不应注册")
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
    -- 归因：子域优先；子域无记录时沿父链上溯祖先，并用基线差分避免历史计数误报。
    local files = {
      ["/cg/neoai/a/memory.events"] = "oom_kill 0\n",
      ["/cg/neoai/memory.events"] = "oom_kill 1\n",
      ["/cg/memory.events"] = "oom_kill 5\n",
    }
    local reader = function(p) return files[p] end
    local attr = cgroup.oom_attribution("/cg/neoai/a", { base = "/cg", reader = reader })
    t.true_(attr.oom, "子域无 OOM 时应上溯父域")
    t.eq("ancestor", attr.level, "父域 OOM 应标记为 ancestor")
    t.eq("/cg/neoai", attr.path, "应定位到父域路径")
    local baseline = cgroup.oom_baseline("/cg/neoai/a", { base = "/cg", reader = reader })
    t.eq(1, baseline["/cg/neoai"], "基线应记录父域当前计数")
    local attr2 = cgroup.oom_attribution("/cg/neoai/a", { base = "/cg", reader = reader, baseline = baseline })
    t.false_(attr2.oom, "计数未变时不应归因为本次 OOM")
    files["/cg/neoai/a/memory.events"] = "oom_kill 3\n"
    local attr3 = cgroup.oom_attribution("/cg/neoai/a", { base = "/cg", reader = reader, baseline = baseline })
    t.true_(attr3.oom, "子域新增 OOM 应归因")
    t.eq("sandbox", attr3.level, "子域 OOM 应标记为 sandbox")
    local diag = require("NeoAI.sandbox.diag")
    local limits = diag.sandbox_limits()
    t.eq("table", type(limits))
    t.eq("boolean", type(limits.systemd))
    t.eq("table", type(limits.cgroup_quota), "诊断应含容器 cgroup 配额")
  end)

  it("service：停止先发 SIGTERM 优雅退出（trap 生效），不立即 SIGKILL", function(t)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    with_config({
      tools = { sandbox = sandbox_config({ service = { enabled = true, stop_timeout_ms = 2000 } }) },
    }, function()
      require("NeoAI.sandbox").reset()
      local svc_mod = require("NeoAI.sandbox.service")
      local candidate = require("NeoAI.sandbox.candidate")
      local term = dir .. "/term.txt"
      local svc, err = svc_mod.start("grace",
        "trap 'echo GRACEFUL > " .. term .. "; exit 0' TERM; echo READY; "
        .. "while true; do sleep 0.1; done", { cwd = dir })
      t.not_nil(svc, "启动失败: " .. tostring(err))
      t.true_(vim.wait(5000, function()
        return (svc_mod.logs("grace") or ""):find("READY", 1, true) ~= nil
      end, 50), "服务应就绪（trap 已安装）")
      local t0 = vim.uv.hrtime()
      local stopped = false
      svc_mod.stop("grace", function() stopped = true end)
      t.true_(vim.wait(10000, function() return stopped end, 50), "停止应完成")
      local dt = (vim.uv.hrtime() - t0) / 1e6
      t.true_(dt < 1800, string.format("优雅退出应在 stop_timeout_ms 内完成（实际 %.0f ms）", dt))
      local staged = candidate.read_path(term)
      t.not_nil(staged, "SIGTERM trap 应写入 term.txt（证 SIGTERM 到达载荷而非立即 SIGKILL）")
      t.matches("GRACEFUL", require("NeoAI.utils.fs").read_file(staged) or "")
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("service：载荷忽略 SIGTERM 时，stop_timeout_ms 后 SIGKILL", function(t)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    with_config({
      tools = { sandbox = sandbox_config({ service = { enabled = true, stop_timeout_ms = 700 } }) },
    }, function()
      require("NeoAI.sandbox").reset()
      local svc_mod = require("NeoAI.sandbox.service")
      local svc, err = svc_mod.start("stubborn",
        "trap '' TERM; echo READY; while true; do sleep 0.1; done", { cwd = dir })
      t.not_nil(svc, "启动失败: " .. tostring(err))
      t.true_(vim.wait(5000, function()
        return (svc_mod.logs("stubborn") or ""):find("READY", 1, true) ~= nil
      end, 50), "服务应就绪")
      local t0 = vim.uv.hrtime()
      local stopped = false
      svc_mod.stop("stubborn", function() stopped = true end)
      t.true_(vim.wait(10000, function() return stopped end, 50), "停止应完成")
      local dt = (vim.uv.hrtime() - t0) / 1e6
      t.true_(dt >= 500, string.format("应等待优雅窗口后才强杀（实际 %.0f ms）", dt))
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("stop_all：对长驻服务同样优雅停止并捕获改动", function(t)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    with_config({
      tools = { sandbox = sandbox_config({ service = { enabled = true, stop_timeout_ms = 2000 } }) },
    }, function()
      require("NeoAI.sandbox").reset()
      local svc_mod = require("NeoAI.sandbox.service")
      local candidate = require("NeoAI.sandbox.candidate")
      local term = dir .. "/term.txt"
      local svc, err = svc_mod.start("grace_all",
        "trap 'echo GRACEFUL > " .. term .. "; exit 0' TERM; echo READY; "
        .. "while true; do sleep 0.1; done", { cwd = dir })
      t.not_nil(svc, "启动失败: " .. tostring(err))
      t.true_(vim.wait(5000, function()
        return (svc_mod.logs("grace_all") or ""):find("READY", 1, true) ~= nil
      end, 50), "服务应就绪")
      svc_mod.stop_all({ timeout_ms = 3000 })
      t.eq(0, #svc_mod.list(), "stop_all 后应清空")
      local staged = candidate.read_path(term)
      t.not_nil(staged, "stop_all 也应优雅停止并捕获 trap 写入")
      t.matches("GRACEFUL", require("NeoAI.utils.fs").read_file(staged) or "")
    end)
    vim.fn.delete(dir, "rf")
  end)
end)
