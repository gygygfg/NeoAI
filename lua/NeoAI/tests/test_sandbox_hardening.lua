--- 沙箱边界加固测试
--- @module NeoAI.tests.test_sandbox_hardening
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
  it("能力门禁：CAP_NET_ADMIN 授予时 iptables 放行，缺失时拒绝", function(t)
    local risk = require("NeoAI.sandbox.risk")
    -- 缺省（无能力）→ 拒绝
    t.not_nil(risk.deny_reason("iptables -F"), "无能力应拒绝 iptables")
    t.not_nil(risk.deny_reason("iptables -F", { caps = {} }), "显式空能力应拒绝")
    -- 授予能力 → 放行
    t.eq(nil, risk.deny_reason("iptables -F", { caps = { CAP_NET_ADMIN = true } }),
      "授予 CAP_NET_ADMIN 后应放行")
    t.eq(nil, risk.deny_reason("nft list ruleset", { caps = { CAP_NET_ADMIN = true } }),
      "授予 CAP_NET_ADMIN 后 nft 应放行")
    -- 无条件拒绝表不受能力影响
    t.not_nil(risk.deny_reason("modprobe x", { caps = { CAP_NET_ADMIN = true } }),
      "modprobe 始终拒绝")
  end)

  it("privilege.effective_caps：T2 默认 ALL 不展开，显式 cap_add 才授予", function(t)
    local privilege = require("NeoAI.sandbox.privilege")
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
    local risk = require("NeoAI.sandbox.risk")
    local script_scan = require("NeoAI.sandbox.script_scan")
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
    local pc = require("NeoAI.sandbox.policy_consent")
    pc.reset()
    local orig_uis = vim.api.nvim_list_uis
    local orig_confirm = vim.fn.confirm
    -- headless（无 attached UI）→ 失败关闭
    t.eq("deny", pc.ask("proxy_evasion", { title = "t" }), "headless 应拒绝")
    -- 交互式：伪造 UI 与 confirm
    vim.api.nvim_list_uis = function() return { {} } end
    vim.fn.confirm = function() return 1 end
    t.eq("once", pc.ask("proxy_evasion", {}), "选项1=仅本次允许")
    vim.fn.confirm = function() return 2 end
    t.eq("session", pc.ask("proxy_evasion", {}), "选项2=本次会话始终允许")
    t.true_(pc.is_session_allowed("proxy_evasion"), "应记住会话允许")
    vim.fn.confirm = function() return 3 end
    t.eq("session", pc.ask("proxy_evasion", {}), "已会话允许时不再弹窗")
    t.eq("deny", pc.ask("other", {}), "其它策略选项3=拒绝")
    vim.api.nvim_list_uis = orig_uis
    vim.fn.confirm = orig_confirm
    pc.reset()
  end)

  it("代理规避：默认弹窗拒绝（headless）；批准后放行；可配置 deny/allow", function(t)
    local tools = require("NeoAI.tools")
    local pc = require("NeoAI.sandbox.policy_consent")
    local function run(cmd)
      local done, out = false, nil
      tools.execute("run_command", { command = cmd, description = "t" }, {})
        :then_(function(r) out = tostring(r); done = true end,
          function(e) out = "ERR:" .. tostring(e and e.message or e); done = true end)
      t.true_(vim.wait(15000, function() return done end), "命令应完成")
      return out
    end
    local cmd = "env -u http_proxy echo neoai_evasion_ok"
    -- 默认 ask + headless（无 UI）→ 拒绝
    t.matches("代理规避未获批准", run(cmd), "headless ask 应拒绝")
    -- 用户批准（stub）→ 放行
    local orig = pc.ask
    pc.ask = function() return "once" end
    local allowed_out = run(cmd)
    pc.ask = orig
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
    local cgroup = require("NeoAI.sandbox.cgroup")
    t.eq("function", type(cgroup.applied), "应导出 applied")
    t.eq("function", type(cgroup.unavailable), "应导出 unavailable")
    t.eq("table", type(cgroup.applied(nil)), "applied(nil) 应返回表")
    local caps = cgroup.capabilities()
    t.eq("table", type(caps.controllers), "应暴露 cgroup.controllers")
  end)

  it("tar 属主还原兼容：沙箱环境默认 TAR_OPTIONS=--no-same-owner", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    local env = runtime.sandbox_env({})
    t.matches("no%-same%-owner", tostring(env.TAR_OPTIONS), "应注入 --no-same-owner")
    -- 已有 TAR_OPTIONS 时保留并补开关
    local env2 = runtime.sandbox_env({ env = { TAR_OPTIONS = "--numeric-owner" } })
    t.matches("no%-same%-owner", tostring(env2.TAR_OPTIONS), "应补 --no-same-owner")
  end)

  it("systemd 门面：daemon-reload 静默成功（真实 systemctl 行为）", function(t)
    local sd = require("NeoAI.sandbox.systemd")
    with_config({ tools = { sandbox = { systemd = { enabled = true } } } }, function()
      local plan = sd.parse_command("systemctl daemon-reload")
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
    local nc = require("NeoAI.sandbox.net_consent")
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
    local cgroup = require("NeoAI.sandbox.cgroup")
    if not cgroup.capabilities().available then return end
    local h, err = cgroup.prepare_delegated("test_hardening", cgroup.resolve_limits())
    t.not_nil(h, tostring(err))
    t.not_nil(h.limit_path, "应有不可写的限额层 limit_path")
    t.true_(h.limit_path ~= h.path, "限额层与暴露叶子应不同")
    t.true_(tostring(h.path):match("/leaf$") ~= nil, "暴露路径应为 leaf")
    cgroup.release_delegated(h)
  end)

  it("cgroup：内部委派叶子（有 subtree_control）上 join_prefix 下沉到非内部子域", function(t)
    local cgroup = require("NeoAI.sandbox.cgroup")
    if not cgroup.capabilities().available then return end
    local h, err = cgroup.prepare_delegated("test_join_internal", cgroup.resolve_limits())
    t.not_nil(h, tostring(err))
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
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local resident = require("NeoAI.sandbox.resident")
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
      require("NeoAI.sandbox.net_consent").reset()
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
end)
