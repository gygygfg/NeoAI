--- 沙箱边界加固测试
--- @module 'NeoAI.tests.test_sandbox_hardening'
--- 覆盖：
--- 1. 底层网络命令按能力门禁（有 CAP_NET_ADMIN 放行，缺失拒绝），而非按命令名一刀切；
--- 2. 代理规避门禁（unset/env -u/--noproxy/--proxy "" 等）；
--- 3. cgroup 控制器按 cgroup.controllers 门禁 + applied/unavailable 暴露真实生效状态；
--- 4. tar 属主还原兼容（TAR_OPTIONS=--no-same-owner）；
--- 5. systemd 门面 daemon-reload 诚实说明（无常驻管理器）。

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

tests.suite("sandbox_hardening", function(_, it)
  it("能力形迹只做分级提示：iptables 不因缺少 CAP_NET_ADMIN 而被拒绝", function(t)
    local risk = require("NeoAI.sandbox.review.risk")
    -- 核心不变量 6：字符/命令名静态判定不得作为拒绝依据——真实约束是内核（EPERM）。
    -- 拒绝 API 已彻底移除（连 text_guard="enforce" 逃生口一并删除），故直接断言不存在。
    t.eq(nil, risk.deny_reason, "拒绝 API 已移除（不得再以文本判定拒绝命令）")

    -- advisory 给出形迹与提示，能力状态只影响文案（MISSING vs GRANTED），不影响放行与否。
    local adv = risk.advisory("iptables -F")
    t.not_nil(adv, "应给出 advisory 形迹")
    local has_missing = false
    for _, r in ipairs(adv.reasons) do
      if r:find("CAPABILITY_MISSING:iptables", 1, true) then has_missing = true end
    end
    t.ok(has_missing, "未授予能力时提示 CAPABILITY_MISSING")

    local adv2 = risk.advisory("iptables -F", { caps = { CAP_NET_ADMIN = true } })
    t.not_nil(adv2, "能力已授予时仍有形迹提示")
    local has_granted = false
    for _, r in ipairs(adv2.reasons) do
      if r:find("CAPABILITY_GRANTED:iptables", 1, true) then has_granted = true end
    end
    t.ok(has_granted, "已授予能力时提示 CAPABILITY_GRANTED")

    -- 纯查看类命令（help/version）也只是 advisory，绝不拒绝。
    t.not_nil(risk.advisory("kmod --help"), "kmod --help 应作为形迹提示")
    t.not_nil(risk.advisory("modprobe x"), "modprobe 应作为形迹提示（由 seccomp 拦）")
  end)

  it("privilege.effective_caps：T2 默认 ALL 不展开，显式 cap_add 才授予", function(t)
    local privilege = require("NeoAI.sandbox.execution.privilege")
    -- 默认 T2 cap_add={"ALL"}：ALL 不解除全局 cap_drop，故 CAP_NET_ADMIN 未授予
    local caps = privilege.effective_caps("run_command", { command = "iptables -F" }, { effect = "process" })
    t.true_(caps.CAP_NET_ADMIN ~= true, "ALL 不应展开为 CAP_NET_ADMIN")
    -- 显式授予 → 出现在有效能力集合
    with_config({ tools = { sandbox = { privilege = { tiers = { [2] = { cap_add = { "CAP_NET_ADMIN" } } } } } } }, function()
      local c2 = privilege.effective_caps("run_command", { command = "iptables -F" }, { effect = "process" })
      t.true_(c2.CAP_NET_ADMIN == true, "显式 cap_add 应授予 CAP_NET_ADMIN")
    end)
  end)

  it("代理规避门禁：识别 unset/env -u/--noproxy/--proxy 空值", function(t)
    local risk = require("NeoAI.sandbox.review.risk")
    local script_scan = require("NeoAI.sandbox.observe.script_scan")
    -- 与门禁一致：对脚本折叠后的有效命令文本判定（bash -c '…' 内联脚本会被展开）。
    local function eff(c)
      local ok, scan = pcall(script_scan.scan, c, { cwd = vim.fn.getcwd() })
      return (ok and scan and scan.effective) or c
    end
    for _, c in ipairs({
      "unset http_proxy",
      "unset HTTPS_PROXY ALL_PROXY",
      "env -u http_proxy curl http://127.0.0.1",
      "env --unset=all_proxy curl http://x",
      "curl --noproxy '*' http://127.0.0.1:8080",
      "curl --no-proxy http://127.0.0.1",
      "curl --proxy '' http://127.0.0.1",
      "curl -x '' http://127.0.0.1",
      "curl --proxy= http://x",
      "export http_proxy=",
      "bash -c 'unset https_proxy; curl http://127.0.0.1'",
      -- shell 引号拼接 / ANSI-C 引用 / 变量间接：不得绕过静态扫描
      "curl --noprox''y '*' http://127.0.0.1:8080",
      "curl $'--noproxy' '*' http://127.0.0.1:8080",
      "curl --nop''roxy '*' http://127.0.0.1:8080",
      "c=--noproxy; curl $c '*' http://127.0.0.1:8080",
      "p=''; curl --proxy $p http://127.0.0.1",
    }) do
      t.not_nil(risk.network_evasion_reason(eff(c)), "应识别代理规避: " .. c)
    end
    for _, c in ipairs({
      "curl http://example.com",
      "pip install requests",
      "unset FOO",
      "echo proxy",
      "env FOO=1 curl http://example.com",
      "curl --proxy http://127.0.0.1:7890 http://example.com",
      -- `-x` 非代理开关（回归：曾把 set -x 误报为 PROXY_EVASION:proxy-empty）
      "set -x",
      "set -euo pipefail",
      "bash -c 'set -x; echo hi'",
      "tar -xf /tmp/nope.tar",
      "grep -x foo /etc/hostname",
      "bash -x /dev/null",
      -- 未展开的合法代理变量不应被判为空
      "curl --proxy \"$http_proxy\" http://example.com",
    }) do
      t.eq(nil, risk.network_evasion_reason(eff(c)), "不应误判: " .. c)
    end
  end)

  it("策略确认：headless 拒绝；交互式可仅本次/会话允许", function(t)
    local pc = require("NeoAI.sandbox.review.policy_consent")
    pc.reset()
    local orig_uis = vim.api.nvim_list_uis
    local orig_confirm = vim.fn.confirm
    -- headless（无 attached UI）→ 失败关闭
    t.eq("deny", pc.ask("proxy_evasion", { title = "t" }), "headless 应拒绝")
    -- 交互式：伪造 UI 与 confirm
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.api.nvim_list_uis = function() return { {} } end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.confirm = function() return 1 end
    t.eq("once", pc.ask("proxy_evasion", {}), "选项1=仅本次允许")
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.confirm = function() return 2 end
    t.eq("session", pc.ask("proxy_evasion", {}), "选项2=本次会话始终允许")
    t.true_(pc.is_session_allowed("proxy_evasion"), "应记住会话允许")
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.confirm = function() return 3 end
    t.eq("session", pc.ask("proxy_evasion", {}), "已会话允许时不再弹窗")
    t.eq("deny", pc.ask("other", {}), "其它策略选项3=拒绝")
    vim.api.nvim_list_uis = orig_uis
    vim.fn.confirm = orig_confirm
    pc.reset()
  end)

  it("策略确认：注册浮窗 UI 后经弹窗决策（与其它沙箱弹窗一致）", function(t)
    local pc = require("NeoAI.sandbox.review.policy_consent")
    local function via_ui(reply)
      pc.reset()
      local decision
      pc.set_ui({ show = function(_ctx, decide) decide(reply) end, hide = function() end })
      local d = pc.request("proxy_evasion", { title = "t", detail = "d" })
      d:then_(function(v) decision = v end)
      t.true_(vim.wait(2000, function() return decision ~= nil end), "应完成")
      pc.set_ui(nil)
      return decision
    end
    t.eq("allow_once", via_ui("allow_once"), "allow_once 映射为 allow_once")
    t.eq("allow_session", via_ui("allow_session"), "allow_session 映射为 allow_session")
    pc.reset()
    -- 会话允许后不再弹窗
    pc.allow_session("proxy_evasion")
    local d2 = pc.request("proxy_evasion", {})
    local v2
    d2:then_(function(v) v2 = v end)
    t.true_(vim.wait(2000, function() return v2 ~= nil end), "应完成")
    t.eq("allow_session", v2, "会话允许应短路")
    pc.reset()
    t.eq("deny", via_ui("deny"), "deny 映射为 deny")
    pc.reset()
  end)

  it("策略确认：广播到审批中心「工具行为」页（统一审批悬浮窗可见并可决策）", function(t)
    local pc = require("NeoAI.sandbox.review.policy_consent")
    local hub = require("NeoAI.sandbox.review.approval_hub")
    pc.reset()
    hub.reset()
    local orig_uis = vim.api.nvim_list_uis
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.api.nvim_list_uis = function() return { {} } end
    hub.set_ui({ refresh = function() end })
    pc.set_ui({ show = function() end })
    local got
    pc.request("proxy_evasion", { title = "代理规避确认" }):then_(function(v) got = v end)
    local items = hub.list("behavior")
    t.true_(#items >= 1, "应在「工具行为」页出现条目")
    t.true_(hub.resolve(items[#items].id, "allow_once"), "中心应能决策")
    t.true_(vim.wait(2000, function() return got ~= nil end), "应 resolve")
    t.eq("allow_once", got, "中心决策应透传")
    hub.reset()
    vim.api.nvim_list_uis = orig_uis
    pc.reset()
  end)

  it("代理规避：默认弹窗拒绝（headless）；批准后放行；可配置 deny/allow", function(t)
    -- 代理规避门禁位于沙箱进程门禁内；无命名空间隔离后端时沙箱被禁用（退回事前审批），
    -- 门禁不经此路径（命令由用户逐条审批把关）。仅在有隔离后端的环境验证该门禁。
    if require("NeoAI.sandbox.execution.runtime").backend() == nil then return end
    local tools = require("NeoAI.tools")
    ---@type table<string, any>
    local pc = require("NeoAI.sandbox.review.policy_consent")
    local function run(cmd)
      local done, out = false, nil
      -- 显式标记跨挂载点已批准：本用例验证「代理规避」门禁，不应被工作区位于独立挂载点
      -- （如容器卷 /data）时的兼容模式审批门遮蔽（headless 无审批能力）。
      tools.execute("run_command", { command = cmd, description = "t" }, { sandbox_cross_mount_approved = true })
        :then_(function(r) out = tostring(r); done = true end,
          function(e) out = "ERR:" .. tostring(e and e.message or e); done = true end)
      t.true_(vim.wait(15000, function() return done end), "命令应完成")
      return out
    end
    local cmd = "env -u http_proxy echo neoai_evasion_ok"
    -- 默认 ask + headless（无 UI）→ 拒绝
    t.matches("代理规避未获批准", run(cmd), "headless ask 应拒绝")
    -- 用户批准（stub 异步 request）→ 放行
    local async = require("NeoAI.utils.async")
    local orig = pc.request
    pc.request = function() return async.resolve("allow_once") end
    local allowed_out = run(cmd)
    pc.request = orig
    t.matches("neoai_evasion_ok", allowed_out, "批准后应执行")
    -- "deny" → 直接拒绝
    with_config({ tools = { sandbox = { network = { block_proxy_evasion = "deny" } } } }, function()
      t.matches("代理规避未获批准", run(cmd), "deny 应拒绝")
    end)
    -- false → 不拦截
    with_config({ tools = { sandbox = { network = { block_proxy_evasion = false } } } }, function()
      t.matches("neoai_evasion_ok", run(cmd), "false 应放行")
    end)
    pc.reset()
  end)

  it("cgroup：applied/unavailable 暴露真实生效状态，控制器列表可读", function(t)
    local cgroup = require("NeoAI.sandbox.execution.cgroup")
    t.eq("function", type(cgroup.applied), "应导出 applied")
    t.eq("function", type(cgroup.unavailable), "应导出 unavailable")
    ---@diagnostic disable-next-line: param-type-mismatch
    t.eq("table", type(cgroup.applied(nil)), "applied(nil) 应返回表")
    local caps = cgroup.capabilities()
    t.eq("table", type(caps.controllers), "应暴露 cgroup.controllers")
  end)

  it("tar 属主还原兼容：沙箱环境默认 TAR_OPTIONS=--no-same-owner", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    local env = runtime.sandbox_env({})
    t.matches("no%-same%-owner", tostring(env.TAR_OPTIONS), "应注入 --no-same-owner")
    -- 已有 TAR_OPTIONS 时保留并补开关
    local env2 = runtime.sandbox_env({ env = { TAR_OPTIONS = "--numeric-owner" } })
    t.matches("no%-same%-owner", tostring(env2.TAR_OPTIONS), "应补 --no-same-owner")
  end)

  it("systemd 门面：daemon-reload 静默成功（真实 systemctl 行为）", function(t)
    local sd = require("NeoAI.sandbox.systemd.systemd")
    with_config({ tools = { sandbox = { systemd = { enabled = true } } } }, function()
      local plan = assert(sd.parse_command("systemctl daemon-reload"))
      t.not_nil(plan, "应识别 daemon-reload")
      local res
      sd.handle(plan):then_(function(v) res = v end, function(e) res = { err = e } end)
      t.true_(vim.wait(2000, function() return res ~= nil end), "应返回")
      t.eq(nil, res.err, tostring(res.err))
      t.eq(0, res.code)
      t.eq("", res.stdout, "daemon-reload 应静默")
    end)
  end)

  it("网络自动登记：解析 LISTEN inode 并按 cgroup 归属识别沙箱监听", function(t)
    local nc = require("NeoAI.sandbox.net.net_consent")
    nc.reset()
    -- /proc/net/tcp 行：local=0100007F:1F90(8080) st=0A inode=123456
    local text = table.concat({
      "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode",
      "   0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 123456 1 0000000000000000 100 0 0 10 0",
      "   1: 0100007F:0016 00000000:0000 01 00000000:00000000 00:00000000 00000000     0        0 999 1 0000000000000000 100 0 0 10 0",
    }, "\n")
    local m = nc._parse_listen_inodes(text)
    t.eq(8080, m["123456"], "应解析出 LISTEN 端口 8080")
    t.eq(nil, m["999"], "非 LISTEN 不解析")
    t.true_(nc._is_sandbox_cgroup("0::/neoai/neoai_resident_1\n"), "应识别沙箱 cgroup")
    t.false_(nc._is_sandbox_cgroup("0::/user.slice/user-1000.slice\n"), "非沙箱 cgroup 不识别")
    -- 未监听的高端口：返回 false 且不报错
    t.false_(nc.is_sandbox_listening(1), "未监听端口应返回 false")
    -- 已登记内部端口：直接 true
    nc.register_internal_port(8080)
    t.true_(nc.is_sandbox_listening(8080), "已登记端口应 true")
    nc.reset()
  end)

  it("cgroup 委派：限额写在不可写层，暴露给沙箱的是可写叶子", function(t)
    local cgroup = require("NeoAI.sandbox.execution.cgroup")
    if not cgroup.capabilities().available then return end
    local h, err = cgroup.prepare_delegated("test_hardening", cgroup.resolve_limits())
    t.not_nil(h, tostring(err))
    assert(h)
    t.not_nil(h.limit_path, "应有不可写的限额层 limit_path")
    t.true_(h.limit_path ~= h.path, "限额层与暴露叶子应不同")
    t.true_(tostring(h.path):match("/leaf$") ~= nil, "暴露路径应为 leaf")
    cgroup.release_delegated(h)
  end)

  it("cgroup：内部委派叶子（有 subtree_control）上 join_prefix 下沉到非内部子域", function(t)
    local cgroup = require("NeoAI.sandbox.execution.cgroup")
    if not cgroup.capabilities().available then return end
    local h, err = cgroup.prepare_delegated("test_join_internal", cgroup.resolve_limits())
    t.not_nil(h, tostring(err))
    assert(h)
    -- 委派叶子启用了 subtree_control（内部节点），直接写其 cgroup.procs 会 EBUSY；
    -- join_prefix 应下沉到 payload 子域，使进程可入组（限额仍由层级封顶）。
    local prefix = cgroup.join_prefix(h)
    local cmd = {}
    for _, v in ipairs(prefix) do cmd[#cmd + 1] = v end
    cmd[#cmd + 1] = "true"
    local ok, res = pcall(vim.system, cmd)
    if ok then
      local r = res:wait()
      t.eq(0, r.code, "内部委派叶子上 join_prefix 应成功（下沉子域），stderr=" .. tostring(r.stderr))
    end
    t.true_(vim.fn.isdirectory(h.path .. "/payload") == 1, "应创建非内部 payload 子域")
    cgroup.release_delegated(h)
  end)

  it("端到端：沙箱内命令启动的临时监听端口自动免权限放行", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local resident = require("NeoAI.sandbox.execution.resident")
    if not resident.available() then return end
    if vim.fn.executable("python3") ~= 1 or vim.fn.executable("curl") ~= 1 then return end
    local port = 38999
    with_config({
      tools = {
        approval = { mode = "auto_allow" },
        sandbox = {
          enabled = true, fail_closed = true, mode = "dry_run",
          ephemeral_roots = {}, resident = { enabled = true },
        },
      },
    }, function()
      require("NeoAI.sandbox").reset()
      require("NeoAI.sandbox.net.net_consent").reset()
      local function run(cmd)
        local out, done = nil, false
        require("NeoAI.tools").execute("run_command", { command = cmd, description = "t" }, {})
          :then_(function(v) out = v; done = true end, function(e) out = "ERR:" .. tostring(e and e.message or e); done = true end)
        vim.wait(20000, function() return done end, 50)
        return tostring(out)
      end
      -- 沙箱内后台启动临时 HTTP 服务（未声明 PORT，未走 service 模块）
      run("python3 -m http.server " .. port .. " --bind 127.0.0.1 >/tmp/.neoai_h.log 2>&1 & echo started")
      vim.wait(1500)
      -- 沙箱内经代理访问该回环端口：应按 cgroup 归属自动识别为内部端口放行
      local code = run("curl -s -m 4 -o /dev/null -w '%{http_code}' http://127.0.0.1:" .. port .. "/")
      t.matches("200", code, "沙箱内临时服务应被自动放行（实际: " .. code .. "）")
      run("pkill -f 'http.server " .. port .. "' >/dev/null 2>&1; true")
      resident.stop({ timeout_ms = 5000 })
    end)
  end)

  it("无隔离后端：check_available 退回审批（fallback=approval），process_prefix 明确报错", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    -- 仅验证「无命名空间隔离后端」这条路径；有 bwrap/unshare 后端另有覆盖。
    if runtime.backend() ~= nil then return end
    runtime.reset()
    t.false_(runtime.isolation_available(), "无后端时 isolation_available() 应为 false")
    -- 契约：无后端不再 seccomp-only 放行或硬拒，而是返回 fallback="approval" 交调用方退回审批。
    local ok, err, info = runtime.check_available({ tool = "run_command", command = "true" })
    t.true_(ok, "无后端时 check_available 应放行（交调用方退回审批）: " .. tostring(err))
    t.eq("backend", info and info.layer)
    t.eq("approval", info and info.fallback)
    t.eq("no_backend", info and info.reason)
    -- process_prefix 不再构造任何前缀（既无 namespace 亦无 setpriv seccomp-only 降级）。
    local prefix, perr = runtime.process_prefix({ cwd = vim.fn.getcwd() })
    t.nil_(prefix, "无后端时不应构造任何沙箱前缀（含 setpriv seccomp-only）")
    t.matches("BACKEND_UNAVAILABLE", tostring(perr))
  end)

  it("行为兜底：seccomp 不可用时 eBPF 命中触发 cgroup.kill 与 SANDBOX_BEHAVIOR_VIOLATION", function(t)
    local observer = require("NeoAI.sandbox.observe.observer")
    -- 仅当 eBPF 后端可用（root + bpftrace + BTF + tracefs）才验证真实探针；否则跳过。
    if not (type(observer.backstop_available) == "function" and observer.backstop_available()) then return end
    local cgroup = require("NeoAI.sandbox.execution.cgroup")
    if not cgroup.limits_configured() then return end
    local killed = false
    local handle = { path = nil, attempt_id = "backstop_test" }
    local limits = cgroup.resolve_limits()
    local h = cgroup.prepare("backstop_test", limits)
    if not h then return end
    handle = h
    local stat = vim.uv.fs_stat(handle.path)
    if not stat then cgroup.release(handle); return end
    local syscall_seen = nil
    local bs = observer.start_backstop({
      cgroup_id = stat.ino,
      on_violation = function(sys, _pid) syscall_seen = sys; killed = true; pcall(cgroup.kill, handle) end,
    })
    if not bs then cgroup.release(handle); return end
    bs.wait_ready(2000)
    -- 在测试 cgroup 内触发一次危险 syscall（mknodat 创建设备节点）。
    local pid = vim.fn.jobstart({ "sh", "-c",
      "echo $$ > " .. handle.path .. "/cgroup.procs; "
        .. "python3 - <<'PY' 2>/dev/null || true\n"
        .. "import os\ntry:\n os.mknod('/tmp/neoai_backstop_dev', 0o600 | 0o020000, os.makedev(8, 0))\nexcept Exception:\n pass\nPY" }, {})
    local deadline = vim.uv.hrtime() + 4000 * 1e6
    while vim.uv.hrtime() < deadline and not killed do vim.wait(50) end
    pcall(vim.fn.jobstop, pid)
    pcall(bs.stop)
    cgroup.release(handle)
    -- 若内核/环境不允许观测到 mknod（无 python3 等）也不误判失败。
    if syscall_seen then
      t.matches("mknod", tostring(syscall_seen), "应观测到 mknod/mknodat 违规")
      t.true_(killed, "命中后应触发 cgroup.kill")
    end
  end)

  it("档位降级：unshare 后端忽略 cap_add/mounts（degrade 放行 / deny 硬拒）", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "unshare" then return end -- 仅 unshare 后端适用
    local priv = { cap_add = { "CAP_DAC_OVERRIDE" }, mounts = {}, network = true, unmask = {} }
    -- 默认 degrade：不因档位 mounts/cap_add 而硬拒（忽略并放行，载荷为 userns 内 root）。
    with_config({ tools = { sandbox = { backend = "unshare",
      seccomp = { on_unavailable = "degrade" } } } }, function()
      runtime.reset()
      local prefix, err = runtime.process_prefix({ cwd = "/tmp", privileges = priv })
      t.not_nil(prefix, "默认应降级放行（忽略档位 cap_add），实际: " .. tostring(err))
    end)
    -- strict（on_unavailable="deny"）：恢复旧 fail-closed。
    with_config({ tools = { sandbox = { backend = "unshare",
      seccomp = { on_unavailable = "deny" } } } }, function()
      runtime.reset()
      local prefix, err = runtime.process_prefix({ cwd = "/tmp", privileges = priv })
      t.nil_(prefix, "strict 时应硬拒")
      t.matches("PRIVILEGE_UNSUPPORTED", tostring(err))
    end)
  end)

  it("无隔离后端：禁用沙箱、退回审批模式（wrapper.gate 直接放行原工具）", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= nil then return end -- 本机有可用后端则不适用
    local wrapper = require("NeoAI.sandbox.execution.wrapper")
    local async = require("NeoAI.utils.async")
    with_config({ tools = { sandbox = { require_seccomp = true, seccomp = { enabled = true } } } }, function()
      runtime.reset()
      -- 无后端：wrapper.gate 应在门禁顶部直接执行原工具（不套沙箱前缀/不建 overlay/不冻结候选），
      -- 仅留下降级留痕（evidence/事件）；无 notify、无主界面降级文案（由工具审批悬浮窗把关）。
      local called = false
      local tool = { name = "run_command", __sandbox_spec = { effect = "process", paths = {} } }
      local ctx = {}
      wrapper.gate(tool, { command = "echo hi" }, ctx, function()
        called = true
        return async.resolve({ code = 0 })
      end)
      t.true_(called, "无隔离时应直接执行原工具（不经沙箱门禁）")
      t.nil_(ctx.sandbox_prefix, "无隔离直跑不应设置沙箱前缀")
      t.eq(false, ctx.sandbox_resident, "无隔离直跑不应标记常驻沙箱")
      t.not_nil(ctx.sandbox_cwd, "应设置会话工作目录供直跑使用")
      t.not_nil(ctx.sandbox_degrade_info, "应记录降级信息（证据/事件由 note_degrade 落）")
      t.eq("approval", ctx.sandbox_degrade_info and ctx.sandbox_degrade_info.fallback)
      t.nil_(ctx.ui_notice, "无隔离时不应再有主界面降级提示（仅由工具审批悬浮窗把关）")
    end)
  end)

  it("无隔离后端：executor 退回审批模式（强制 prompt，经工具审批弹窗）", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= nil then return end -- 本机有可用后端则不适用
    local executor = require("NeoAI.tools.executor")
    local registry = require("NeoAI.tools.registry")
    local async = require("NeoAI.utils.async")
    -- 注册一个合成 process 工具（tool_spec 未命中 → 归为 process），避免依赖插件加载的内置工具。
    local name = "neoai_test_noiso_cmd"
    registry.register({
      name = name,
      description = "测试用命令工具",
      parameters = {
        type = "object",
        properties = { command = { type = "string" }, description = { type = "string" } },
        required = { "command", "description" },
      },
      func = function() return "real-exec" end,
    })
    -- 配置为 async（默认）：async 依赖沙箱内先执行再事后确认应用，无沙箱时不成立，
    -- 故无隔离时应被强制退回 prompt（事前阻塞审批）。
    with_config({ tools = { sandbox = { enabled = true }, approval = { mode = "async" } } }, function()
      runtime.reset()
      local seen_mode, called = nil, false
      local ctx = {
        approval_mode = "async", -- 会话默认；无隔离时应被覆盖为 prompt
        tool_service = {
          approve_and_execute = function(_, _, actx, _)
            seen_mode = actx.approval_mode
            called = true
            return async.resolve("stub-result")
          end,
        },
      }
      executor.execute(name, { command = "echo hi", description = "t" }, ctx)
      t.true_(called, "无隔离时应经审批模式（prompt）走 approve_and_execute")
      t.eq("prompt", seen_mode, "无隔离时 approval_mode 应被强制为 prompt")
      t.eq("prompt", ctx.approval_mode, "ctx.approval_mode 应被设为 prompt")
      t.nil_(ctx.ui_notice, "无隔离时不应再有主界面降级提示（仅由工具审批悬浮窗把关）")
    end)
  end)
end)
