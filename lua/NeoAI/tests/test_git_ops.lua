--- git 操作工具（tools.builtin.git_ops）专项测试
--- @module NeoAI.tests.test_git_ops
--- 使用临时真实 git 仓库（-u NONE 下离线可复现），覆盖只读命令与写命令的错误路径。
local tests = require("NeoAI.tests")

tests.suite("git_ops", function(_, it, before_each)
  local git_ops, tools, repo, ctx

  local function git(args)
    return vim.fn.system("git -C " .. vim.fn.shellescape(repo) .. " " .. args)
  end

  -- 在任意目录执行 git（用于「操作其它 git 目录」测试）
  local function git_in(dir, args)
    return vim.fn.system("git -C " .. vim.fn.shellescape(dir) .. " " .. args)
  end

  local function write(rel, content)
    local f = assert(io.open(repo .. "/" .. rel, "w"))
    f:write(content)
    f:close()
  end

  local function invoke(tool, args)
    local result, err, done = nil, nil, false
    tool.func(args, function(v) result, done = v, true end, function(e) err, done = e, true end, ctx)
    if not done then
      vim.wait(15000, function() return done end, 10)
    end
    return result, err
  end

  before_each(function()
    git_ops = require("NeoAI.tools.builtin.git_ops")
    tools = {}
    for _, tl in ipairs(git_ops.get_tools()) do tools[tl.name] = tl end
    repo = vim.fn.tempname() .. "-neoai_git"
    vim.fn.mkdir(repo, "p")
    ctx = { sandbox_cwd = repo }
    git("init -q")
    git("config user.email test@example.com")
    git("config user.name tester")
    write("a.txt", "hello\n")
    git("add a.txt")
    git("commit -qm initial")
  end)

  if vim.fn.executable("git") ~= 1 then
    it("git 不可用：跳过", function(t) t.true_(true) end)
    return
  end

  it("git_status：干净工作区提示", function(t)
    local out, err = invoke(tools.git_status, {})
    t.nil_(err)
    t.eq("工作区干净", out)
  end)

  it("git_status：有改动时列出文件", function(t)
    write("a.txt", "hello\nworld\n")
    local out = invoke(tools.git_status, {})
    t.matches("a%.txt", out)
  end)

  it("git_diff：输出未提交改动", function(t)
    write("a.txt", "hello\nworld\n")
    local out = invoke(tools.git_diff, {})
    t.matches("world", out)
    local single = invoke(tools.git_diff, { file_path = "a.txt" })
    t.matches("world", single)
  end)

  it("git_log 与 git_commit_detail：含提交信息", function(t)
    t.matches("initial", invoke(tools.git_log, { max = 5 }))
    t.matches("initial", invoke(tools.git_commit_detail, { ref = "HEAD" }))
    t.matches("initial", invoke(tools.git_file_history, { file_path = "a.txt" }))
  end)

  it("git_branch：列出分支", function(t)
    local out = invoke(tools.git_branch, {})
    t.not_nil(out)
    t.ok(#out > 0, "应输出分支列表")
  end)

  it("git_add：缺少 paths/all 时报错", function(t)
    local _, err = invoke(tools.git_add, {})
    t.matches("git_add 需要", err)
  end)

  it("git_commit：缺少 message 时报错", function(t)
    local _, err = invoke(tools.git_commit, {})
    t.matches("git_commit 需要 message", err)
  end)

  it("git_stash：非法 action 报错", function(t)
    local _, err = invoke(tools.git_stash, { action = "bogus" })
    t.matches("action 仅支持", err)
  end)

  it("git_rollback：还原文件到 HEAD", function(t)
    write("a.txt", "hello\nchanged\n")
    local out, err = invoke(tools.git_rollback, { file_path = "a.txt" })
    t.nil_(err)
    t.matches("已回滚", out)
    local f = assert(io.open(repo .. "/a.txt", "r"))
    local content = f:read("*a")
    f:close()
    t.eq("hello\n", content, "文件内容应被还原")
  end)

  it("git_auto_commit_config：回显配置", function(t)
    local out = invoke(tools.git_auto_commit_config, { auto_commit = true })
    t.matches("自动提交配置: true", out)
  end)

  it("repo：只读操作作用于其它 git 目录（缺省仍为会话仓库）", function(t)
    local other = vim.fn.tempname() .. "-neoai_git_other"
    vim.fn.mkdir(other, "p")
    git_in(other, "init -q")
    git_in(other, "config user.email t@example.com")
    git_in(other, "config user.name t")
    local f = assert(io.open(other .. "/b.txt", "w"))
    f:write("other-only\n")
    f:close()
    git_in(other, "add b.txt")
    git_in(other, "commit -qm other-commit")
    -- 指定 repo：看到其它仓库的提交，而非会话仓库
    t.matches("other%-commit", invoke(tools.git_log, { repo = other, max = 5 }))
    t.matches("other%-commit", invoke(tools.git_commit_detail, { repo = other, ref = "HEAD" }))
    t.matches("other%-commit", invoke(tools.git_file_history, { repo = other, file_path = "b.txt" }))
    -- 缺省（无 repo）仍读会话仓库
    t.matches("initial", invoke(tools.git_log, { max = 5 }))
    -- 分支列表也能定向
    t.matches("master", invoke(tools.git_branch, { repo = other }))
  end)

  it("repo：写操作在其它 git 目录产生提交（会话仓库不受影响）", function(t)
    local other = vim.fn.tempname() .. "-neoai_git_other_w"
    vim.fn.mkdir(other, "p")
    git_in(other, "init -q")
    git_in(other, "config user.email t@example.com")
    git_in(other, "config user.name t")
    local f = assert(io.open(other .. "/c.txt", "w"))
    f:write("new\n")
    f:close()
    local _, add_err = invoke(tools.git_add, { all = true, repo = other })
    t.nil_(add_err)
    local _, commit_err = invoke(tools.git_commit, { message = "via-tool", repo = other })
    t.nil_(commit_err)
    t.matches("via%-tool", git_in(other, "log --oneline -n 1"))
    t.matches("initial", git_in(repo, "log --oneline -n 1"))
  end)

  it("repo：无效目录时写操作报错（不静默成功）", function(t)
    local _, err = invoke(tools.git_commit, { message = "x", repo = "/nonexistent-neoai-repo-xyz" })
    t.not_nil(err)
    t.matches("git 退出码", err)
  end)

  it("sandbox_prefix：命令被前缀包裹（沙箱命名空间执行）", function(t)
    local saved = ctx.sandbox_cwd
    ctx.sandbox_prefix = { "echo" }
    ctx.sandbox_cwd = nil
    local out = invoke(tools.git_status, {})
    ctx.sandbox_prefix = nil
    ctx.sandbox_cwd = saved
    t.eq("git status --short", out, "前缀应被置于 git 参数之前")
  end)

  it("git_log：输出超限时截断为头+尾并落盘到沙箱 /tmp", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    local guest_fs = require("NeoAI.sandbox.execution.guest_fs")
    local cs = config_store.get("tools.output_guard") or {}
    local saved = { max_chars = cs.max_chars, head_chars = cs.head_chars, tail_chars = cs.tail_chars }
    config_store.set("tools.output_guard.max_chars", 100)
    config_store.set("tools.output_guard.head_chars", 70)
    config_store.set("tools.output_guard.tail_chars", 20)
    local host = vim.fn.tempname() .. "-og"
    vim.fn.mkdir(host, "p")
    guest_fs.set_root("/tmp", host)
    local ok, err = pcall(function()
      for i = 1, 10 do
        write("a.txt", "hello\n" .. i .. "\n")
        git("add a.txt")
        git("commit -qm c" .. i)
      end
      local out = invoke(tools.git_log, { max = 10 })
      t.matches("输出过长已截断", out, "超限输出应被截断")
      t.matches("/tmp/neoai%-out/[%w_%-%.]+%.log", out, "应给出落盘路径")
    end)
    config_store.set("tools.output_guard.max_chars", saved.max_chars)
    config_store.set("tools.output_guard.head_chars", saved.head_chars)
    config_store.set("tools.output_guard.tail_chars", saved.tail_chars)
    guest_fs.clear()
    if not ok then error(err, 0) end
  end)
end)
