--- git 操作工具（tools.builtin.git_ops）专项测试
--- @module NeoAI.tests.test_git_ops
--- 使用临时真实 git 仓库（-u NONE 下离线可复现），覆盖只读命令与写命令的错误路径。
local tests = require("NeoAI.tests")

tests.suite("git_ops", function(_, it, before_each)
  local git_ops, tools, repo, ctx

  local function git(args)
    return vim.fn.system("git -C " .. vim.fn.shellescape(repo) .. " " .. args)
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

  it("sandbox_prefix：命令被前缀包裹（沙箱命名空间执行）", function(t)
    local saved = ctx.sandbox_cwd
    ctx.sandbox_prefix = { "echo" }
    ctx.sandbox_cwd = nil
    local out = invoke(tools.git_status, {})
    ctx.sandbox_prefix = nil
    ctx.sandbox_cwd = saved
    t.eq("git status --short", out, "前缀应被置于 git 参数之前")
  end)
end)
