--- 受保护资源：分类 / 后果文案 / 结构化结果
--- @module 'NeoAI.tests.test_sandbox_consequence'
--- 覆盖「审批界面明确告知后果」（R1）与「硬拒绝 / 进暂存待审明确告诉 AI」（R2）的
--- 纯逻辑部分：分类表、文案目录、结果信封与放行动作裁剪。
--- UI 渲染（弹窗/待审列表）由各自的界面用例覆盖；此处只断言它们共同依赖的契约。

local tests = require("NeoAI.tests")

tests.suite("sandbox_consequence", function(_, it)
  local registry = require("NeoAI.sandbox.protected.registry")
  local consequence = require("NeoAI.sandbox.review.consequence")
  local outcome = require("NeoAI.sandbox.protected.outcome")
  local notice = require("NeoAI.ui.components.consent_notice")

  it("classify: SSH 私钥 → credential 且不提供 read", function(t)
    local c = registry.classify("/root/.ssh/id_ed25519")
    t.not_nil(c)
    t.eq("ssh_private_key", c.id)
    t.eq("credential", c.class)
    t.eq("sign", registry.ops(c.id)[1])
    t.eq("tunnel", registry.ops(c.id)[2])
    local has_read = false
    for _, op in ipairs(registry.ops(c.id)) do
      if op == "read" then has_read = true end
    end
    t.false_(has_read, "密钥资源不得声明 read 能力")
  end)

  it("classify: 凭据目录 / 系统库 / 启动脚本", function(t)
    t.eq("credential_store", registry.classify("~/.aws/credentials").id)
    t.eq("system_account_db", registry.classify("/etc/shadow").id)
    t.eq("container_socket", registry.classify("/run/docker.sock").id)
    t.eq("shell_rc", registry.classify("/root/.bashrc").id)
    t.eq("shell_rc", registry.classify("/home/u/.zshrc").id)
    t.eq("host_logs", registry.classify("/var/log/syslog").id)
  end)

  it("classify: 普通路径不归为受保护资源", function(t)
    t.nil_(registry.classify("/root/project/src/main.lua"))
    t.nil_(registry.classify(vim.fn.tempname()))
    t.nil_(registry.classify(nil))
    t.false_(registry.is_protected("/etc/nginx/nginx.conf"))
  end)

  it("consequence: 每条规则都有文案且五段齐全", function(t)
    for _, id in ipairs(registry.ids()) do
      local c = consequence.get(id)
      t.not_nil(c, "缺少后果文案: " .. id)
      for _, k in ipairs({ "title", "ability", "scope", "persistence", "suggestion" }) do
        t.true_(type(c[k]) == "string" and c[k] ~= "", id .. "." .. k .. " 不可为空")
      end
      t.eq(id, c.id)
    end
  end)

  it("consequence: 文本包含能力与范围，供审批界面展示", function(t)
    local text = consequence.text("ssh_private_key")
    t.not_nil(text)
    t.true_(text:find("SSH 私钥", 1, true) ~= nil)
    t.true_(text:find("能力", 1, true) ~= nil)
    t.true_(text:find("范围", 1, true) ~= nil)
    t.true_(text:find("持续", 1, true) ~= nil)
  end)

  it("consequence: 配置可覆盖文案但 id 不变", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    local saved = config_store.get("tools.sandbox.protected.consequences")
    config_store.set("tools.sandbox.protected.consequences", {
      ssh_private_key = { suggestion = "本项目只允许 deploy key" },
    })
    local c = consequence.get("ssh_private_key")
    t.eq("本项目只允许 deploy key", c.suggestion)
    t.eq("ssh_private_key", c.id)
    t.not_nil(c.ability, "未覆盖的字段应保留内置值")
    config_store.set("tools.sandbox.protected.consequences", saved or {})
  end)

  it("outcome.blocked: 机器可读且不可重试", function(t)
    local o = outcome.blocked({
      resource = "/root/.ssh/id_ed25519",
      op = "read",
      class = "credential",
      code = "PROTECTED_RESOURCE",
      reason = "受保护资源",
    })
    t.eq("PROTECTED_RESOURCE", o.code)
    t.true_(o.text:find("BLOCKED code=PROTECTED_RESOURCE", 1, true) ~= nil)
    t.true_(o.text:find("resource=/root/.ssh/id_ed25519", 1, true) ~= nil)
    t.true_(o.text:find("op=read", 1, true) ~= nil)
    t.true_(o.text:find("retryable=false", 1, true) ~= nil)
    t.true_(o.text:find("do_not_repeat=true", 1, true) ~= nil)
  end)

  it("outcome.staged: 带上 change_set 与后果，明确不是失败", function(t)
    local o = outcome.staged({
      change_set = "cs_1_2",
      files = { { path = "/root/.bashrc" } },
      consequence_id = "shell_rc",
    })
    t.true_(o.text:find("STAGED change_set=cs_1_2", 1, true) ~= nil)
    t.true_(o.text:find("files=1", 1, true) ~= nil)
    t.true_(o.text:find("consequence=shell_rc", 1, true) ~= nil)
    t.true_(o.text:find("NEEDS_CONFIRMATION", 1, true) ~= nil)
    t.true_(o.text:find("retryable=false", 1, true) ~= nil)
  end)

  it("outcome.append: 字符串拼接 / 表写输出字段", function(t)
    t.eq("out\n\n[沙箱] X", outcome.append("out", "[沙箱] X"))
    t.eq("[沙箱] X", outcome.append("", "[沙箱] X"))
    local tbl = { stdout = "out", code = 0 }
    local r = outcome.append(tbl, "[沙箱] X")
    t.eq("out\n\n[沙箱] X", r.stdout)
    t.eq(0, r.code)
    local tbl2 = { code = 1 }
    t.eq("[沙箱] X", outcome.append(tbl2, "[沙箱] X").notice)
    t.eq(tbl2, outcome.append(tbl2, ""))
  end)

  it("consent_notice.actions: 受保护资源只留仅本次/取消", function(t)
    local a = notice.actions({ protected = true })
    t.false_(a.confirm_all)
    t.false_(a.add_to_workspace)
    local b = notice.actions({ protected = false })
    t.true_(b.confirm_all)
    t.true_(b.add_to_workspace)
    local c = notice.actions()
    t.true_(c.confirm_all)
  end)

  it("consent_notice.text: 无对应资源时返回 nil（不显示空后果块）", function(t)
    t.nil_(notice.text({ consequence_id = "no_such_resource" }))
    t.nil_(notice.text({}))
    t.not_nil(notice.text({ consequence_id = "ssh_private_key" }))
  end)

  it("tool_approval: 受保护资源不提示、也不绑定会话放行/加目录", function(t)
    local tool_approval = require("NeoAI.ui.components.tool_approval")
    tool_approval.reset()
    tool_approval.show({
      text = "工具: read_file",
      tool_name = "read_file",
      actions = notice.actions({ protected = true }),
      on_confirm = function() end,
      on_cancel = function() end,
      on_confirm_all = function() end,
      on_add_to_workspace = function() end,
    })
    local text, buf
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local b = vim.api.nvim_win_get_buf(win)
      if vim.bo[b].filetype == "neoai_approval" then
        buf = b
        text = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
        break
      end
    end
    t.not_nil(text, "应创建审批悬浮窗")
    t.true_(text:find("回车", 1, true) ~= nil, "仍应提示回车允许一次")
    t.true_(text:find("允许所有", 1, true) == nil, "受保护资源不应提示会话放行")
    t.true_(text:find("加入工作目录", 1, true) == nil, "受保护资源不应提示加入工作目录")
    local lhs = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do lhs[m.lhs] = true end
    t.false_(lhs["A"] == true, "A 不应被绑定")
    t.false_(lhs["D"] == true, "D 不应被绑定")
    tool_approval.reset()
  end)

  it("preauthorize: 指纹 × 消费者 × 目标 × 配额", function(t)
    local pre = require("NeoAI.sandbox.protected.preauthorize")
    local config_store = require("NeoAI.kernel.config_store")
    pre.reset()
    local fp = pre.fingerprint("SECRET-VALUE-123")
    t.not_nil(fp)
    t.true_(fp:match("^sha256:%x+$") ~= nil, "指纹应为 sha256:<hex>")
    t.eq(fp, pre.fingerprint("SECRET-VALUE-123"), "同一密钥指纹稳定")
    t.ne(fp, pre.fingerprint("OTHER-VALUE"), "不同密钥指纹不同")
    local saved = config_store.get("tools.sandbox.protected.preauthorized")
    config_store.set("tools.sandbox.protected.preauthorized", {
      { fingerprint = fp, consumers = { "tool:git_fetch" }, targets = { "github.com" }, max_uses = 2 },
    })
    local c = { "egress", "tool:git_fetch" }
    t.true_(pre.has_any())
    t.true_(pre.allow({ secret = "SECRET-VALUE-123", consumers = c, target = "github.com", op = "egress" }))
    t.false_(pre.allow({ secret = "SECRET-VALUE-123", consumers = c, target = "evil.example" }), "目标不匹配应拒绝")
    t.false_(pre.allow({ secret = "SECRET-VALUE-123", consumers = { "egress", "tool:git_push" }, target = "github.com" }), "消费者不匹配应拒绝")
    t.false_(pre.allow({ secret = "OTHER-VALUE", consumers = c, target = "github.com" }), "指纹不匹配应拒绝")
    t.true_(pre.allow({ secret = "SECRET-VALUE-123", consumers = c, target = "github.com" }), "未超次仍应允许")
    t.false_(pre.allow({ secret = "SECRET-VALUE-123", consumers = c, target = "github.com" }), "超过 max_uses 应拒绝")
    config_store.set("tools.sandbox.protected.preauthorized", saved or {})
    pre.reset()
  end)

  it("preauthorize: 过期 / 通配目标 / 无指纹不匹配", function(t)
    local pre = require("NeoAI.sandbox.protected.preauthorize")
    local config_store = require("NeoAI.kernel.config_store")
    pre.reset()
    local fp = pre.fingerprint("K2")
    local saved = config_store.get("tools.sandbox.protected.preauthorized")
    config_store.set("tools.sandbox.protected.preauthorized", {
      { fingerprint = fp, targets = { "*.example.com" } },
      { fingerprint = fp, expires_at = os.time() - 10 },
    })
    t.true_(pre.allow({ secret = "K2", consumers = { "egress" }, target = "api.example.com" }), "通配目标应匹配")
    t.false_(pre.allow({ secret = "K2", consumers = { "egress" }, target = "example.com.evil" }), "通配不应误匹配")
    t.false_(pre.allow({ secret = "K2", consumers = { "egress" } }), "已过期且无目标，不应匹配")
    t.false_(pre.allow({ consumers = { "egress" }, target = "api.example.com" }), "无密钥（无指纹）不匹配")
    config_store.set("tools.sandbox.protected.preauthorized", saved or {})
    pre.reset()
  end)

  it("preauthorize: 文件指纹与内容指纹同口径（结尾换行不影响）", function(t)
    local pre = require("NeoAI.sandbox.protected.preauthorize")
    t.eq(pre.fingerprint("ABC"), pre.fingerprint("ABC\n\n"), "结尾换行不影响指纹")
    local path = vim.fn.tempname()
    vim.fn.writefile({ "-----BEGIN OPENSSH PRIVATE KEY-----", "AAAA", "-----END OPENSSH PRIVATE KEY-----" }, path)
    local fp_file, err = pre.fingerprint_file(path)
    t.not_nil(fp_file, tostring(err))
    t.eq(pre.fingerprint(table.concat(vim.fn.readfile(path), "\n")), fp_file)
    vim.fn.delete(path)
    t.nil_(pre.fingerprint_file("/no/such/key"), "不可读文件应返回 nil")
  end)

  it("git preauth: 只暴露绑定私钥（无绑定/指纹不符/目标不符均 fail-closed）", function(t)
    if vim.fn.executable("git") ~= 1 then return end
    local wrapper = require("NeoAI.sandbox.execution.wrapper")
    local config_store = require("NeoAI.kernel.config_store")
    local pre = require("NeoAI.sandbox.protected.preauthorize")
    local dir = vim.fn.tempname() .. "-repo"
    vim.fn.mkdir(dir, "p")
    vim.fn.system({ "git", "-C", dir, "init", "-q" })
    if vim.fn.isdirectory(dir .. "/.git") ~= 1 then
      vim.fn.delete(dir, "rf")
      return
    end
    vim.fn.system({ "git", "-C", dir, "remote", "add", "origin", "git@github.com:acme/x.git" })
    local key = vim.fn.tempname()
    vim.fn.writefile({ "-----BEGIN OPENSSH PRIVATE KEY-----", "AAAA", "-----END OPENSSH PRIVATE KEY-----" }, key)
    local fp = pre.fingerprint_file(key)
    t.not_nil(fp)
    local saved_git = config_store.get("tools.sandbox.git")
    local saved_pre = config_store.get("tools.sandbox.protected.preauthorized")
    local function set(binds)
      config_store.set("tools.sandbox.git.credentials", "preauth")
      config_store.set("tools.sandbox.protected.preauthorized", binds or {})
      wrapper._git_preauth_reset()
    end

    -- 无绑定 → fail-closed（不静默退回整目录放开）
    set({})
    local cmd, err = wrapper._git_ssh_command(nil, dir, nil)
    t.nil_(cmd, "无绑定不应注入 GIT_SSH_COMMAND")
    t.matches("GIT_PREAUTH_NO_BINDING", tostring(err))

    -- 绑定命中：显式私钥 + 不读 ssh config（消除 ProxyCommand/LocalCommand 执行面）
    set({ { fingerprint = fp, resource = key, consumers = { "git" }, targets = { "github.com" }, max_uses = 5 } })
    local cmd2, err2 = wrapper._git_ssh_command(nil, dir, nil)
    t.not_nil(cmd2, tostring(err2))
    t.true_(cmd2:find("/dev/null", 1, true) ~= nil, "preauth 应以 -F /dev/null 启动（不读 ssh config）")
    t.false_(cmd2:find(vim.fn.expand("~/.ssh/config"), 1, true) ~= nil, "preauth 不应引用 ssh config")
    t.true_(cmd2:find("IdentitiesOnly=yes", 1, true) ~= nil)
    t.true_(cmd2:find("ForwardAgent=no", 1, true) ~= nil)
    t.true_(cmd2:find(vim.fn.shellescape(key), 1, true) ~= nil, "应显式指定绑定私钥: " .. cmd2)

    -- 访问面：只有绑定私钥（+ known_hosts），绝不放开整个 ~/.ssh
    wrapper._git_preauth_reset()
    local acc = wrapper._git_preauth_access(nil, dir, nil)
    t.not_nil(acc)
    local has_key, has_dir = false, false
    for _, b in ipairs(acc.bind_files or {}) do
      if b.dest == key then has_key = true end
      if b.dest == vim.fn.expand("~/.ssh") then has_dir = true end
    end
    t.true_(has_key, "应绑定命中私钥")
    t.false_(has_dir, "不得放开整个 ~/.ssh 目录")

    -- 指纹不符（钥匙被替换）→ 视为无绑定
    set({ { fingerprint = "sha256:deadbeef", resource = key, consumers = { "git" }, targets = { "github.com" } } })
    local cmd3, err3 = wrapper._git_ssh_command(nil, dir, nil)
    t.nil_(cmd3)
    t.matches("GIT_PREAUTH_NO_BINDING", tostring(err3))

    -- 目标不符 → 视为无绑定
    set({ { fingerprint = fp, resource = key, consumers = { "git" }, targets = { "gitlab.com" } } })
    local cmd4, err4 = wrapper._git_ssh_command(nil, dir, nil)
    t.nil_(cmd4)
    t.matches("GIT_PREAUTH_NO_BINDING", tostring(err4))

    config_store.set("tools.sandbox.git", saved_git or {})
    config_store.set("tools.sandbox.protected.preauthorized", saved_pre or {})
    wrapper._git_preauth_reset()
    vim.fn.delete(dir, "rf")
    vim.fn.delete(key)
  end)

  it("runtime: priv.bind_files 在目录遮蔽之后按单文件只读绑定", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local home_ssh = vim.fn.expand("~/.ssh")
    if vim.fn.isdirectory(home_ssh) ~= 1 then return end
    local key = vim.fn.tempname()
    vim.fn.writefile({ "k" }, key)
    local dest = home_ssh .. "/neoai-test-key"
    local prefix = runtime.process_prefix({
      cwd = "/tmp",
      privileges = { bind_files = { { src = key, dest = dest } } },
    })
    vim.fn.delete(key)
    if not prefix then return end
    local mask_idx, bind_idx
    for i = 1, #prefix - 2 do
      if prefix[i] == "--tmpfs" and prefix[i + 1] == home_ssh then mask_idx = i end
      if prefix[i] == "--ro-bind" and prefix[i + 1] == key and prefix[i + 2] == dest then bind_idx = i end
    end
    t.not_nil(mask_idx, "~/.ssh 应仍以空 tmpfs 遮蔽")
    t.not_nil(bind_idx, "命中的私钥应以单文件只读绑定放回")
    t.true_(bind_idx > mask_idx, "单文件绑定必须排在目录遮蔽之后（否则会被覆盖）")
  end)

  it("tool_approval: 普通审批仍提示并绑定会话放行", function(t)
    local tool_approval = require("NeoAI.ui.components.tool_approval")
    tool_approval.reset()
    tool_approval.show({
      text = "工具: edit_file",
      tool_name = "edit_file",
      actions = notice.actions({ protected = false }),
      on_confirm = function() end,
      on_cancel = function() end,
      on_confirm_all = function() end,
      on_add_to_workspace = function() end,
    })
    local text, buf
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local b = vim.api.nvim_win_get_buf(win)
      if vim.bo[b].filetype == "neoai_approval" then
        buf = b
        text = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
        break
      end
    end
    t.not_nil(text, "应创建审批悬浮窗")
    t.true_(text:find("允许所有", 1, true) ~= nil)
    t.true_(text:find("加入工作目录", 1, true) ~= nil)
    local lhs = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do lhs[m.lhs] = true end
    t.true_(lhs["A"] == true)
    t.true_(lhs["D"] == true)
    tool_approval.reset()
  end)
end)
