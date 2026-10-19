--- 工作目录根检测测试
--- @module 'NeoAI.tests.test_workspace_root'
--- 覆盖：`.git` 优先、配置文件回退、逐级向上、最近祖先、未命中、总开关。

local tests = require("NeoAI.tests")
local config = require("NeoAI.kernel.config_store")
local fs = require("NeoAI.utils.fs")

local function norm(p)
  local abs = vim.fn.fnamemodify(vim.fn.expand(p), ":p")
  if abs ~= "/" then abs = abs:gsub("/+$", "") end
  return abs
end

tests.suite("workspace_root", function(_, it)
  it("优先命中 .git 祖先（目录或文件）", function(t)
    local wr = require("NeoAI.core.session.workspace_root")
    local base = vim.fn.tempname()
    fs.ensure_dir(base .. "/proj/.git")
    fs.ensure_dir(base .. "/proj/sub/deep")
    t.eq(norm(base .. "/proj"), wr.detect(base .. "/proj/sub/deep"), "应向上找到 .git 仓库根")

    -- worktree：.git 为文件也应命中
    local wt = vim.fn.tempname()
    fs.ensure_dir(wt .. "/repo/sub")
    fs.write_file(wt .. "/repo/.git", "gitdir: /elsewhere\n")
    t.eq(norm(wt .. "/repo"), wr.detect(wt .. "/repo/sub"), ".git 文件（worktree）也应命中")

    vim.fn.delete(base, "rf")
    vim.fn.delete(wt, "rf")
  end)

  it("无 .git 时回退配置文件标记（package.json/pyproject.toml）", function(t)
    local wr = require("NeoAI.core.session.workspace_root")
    -- 关闭 git 通道（用不存在的标记名），仅验证 root_markers 回退，避免受宿主祖先 .git 干扰。
    config.load({ session = { git_markers = { ".neoai_no_such_git_marker" } } })
    local base = vim.fn.tempname()
    fs.ensure_dir(base .. "/app/src")
    fs.write_file(base .. "/app/package.json", "{}\n")
    t.eq(norm(base .. "/app"), wr.detect(base .. "/app/src"), "package.json 应定位项目根")

    local base2 = vim.fn.tempname()
    fs.ensure_dir(base2 .. "/py/mod")
    fs.write_file(base2 .. "/py/pyproject.toml", "[project]\n")
    t.eq(norm(base2 .. "/py"), wr.detect(base2 .. "/py/mod"), "pyproject.toml 应定位项目根")

    config.load({})
    vim.fn.delete(base, "rf")
    vim.fn.delete(base2, "rf")
  end)

  it("起始目录本身含标记时返回自身", function(t)
    local wr = require("NeoAI.core.session.workspace_root")
    local base = vim.fn.tempname()
    fs.ensure_dir(base .. "/proj/.git")
    t.eq(norm(base .. "/proj"), wr.detect(base .. "/proj"), "起点即根时返回起点")
    vim.fn.delete(base, "rf")
  end)

  it(".git 优先于更近的配置文件标记", function(t)
    local wr = require("NeoAI.core.session.workspace_root")
    local base = vim.fn.tempname()
    fs.ensure_dir(base .. "/repo/.git")
    fs.ensure_dir(base .. "/repo/sub")
    fs.write_file(base .. "/repo/sub/package.json", "{}\n")
    -- 虽 sub 更近且有 package.json，但 .git 优先级更高 → 返回 repo
    t.eq(norm(base .. "/repo"), wr.detect(base .. "/repo/sub"), ".git 应先于配置文件命中")
    vim.fn.delete(base, "rf")
  end)

  it("嵌套仓库取最近的 .git 祖先", function(t)
    local wr = require("NeoAI.core.session.workspace_root")
    local base = vim.fn.tempname()
    fs.ensure_dir(base .. "/outer/.git")
    fs.ensure_dir(base .. "/outer/inner/.git")
    fs.ensure_dir(base .. "/outer/inner/x")
    t.eq(norm(base .. "/outer/inner"), wr.detect(base .. "/outer/inner/x"), "应取最近祖先")
    vim.fn.delete(base, "rf")
  end)

  it("无任何标记返回 nil；总开关关闭时返回 nil；空标记列表返回 nil", function(t)
    local wr = require("NeoAI.core.session.workspace_root")
    local base = vim.fn.tempname()
    fs.ensure_dir(base .. "/plain/x")
    -- 用不存在的标记名，避免宿主祖先的 .git/配置文件干扰判定。
    config.load({ session = { git_markers = { ".neoai_no_such_a" }, root_markers = { ".neoai_no_such_b" } } })
    t.nil_(wr.detect(base .. "/plain/x"), "无标记应返回 nil")
    config.load({})

    config.load({ session = { detect_root = false } })
    t.nil_(wr.detect(base .. "/plain/x"), "关闭检测应返回 nil")
    config.load({})

    config.load({ session = { git_markers = {}, root_markers = {} } })
    t.nil_(wr.detect(base .. "/plain/x"), "标记列表为空应返回 nil")
    config.load({})

    vim.fn.delete(base, "rf")
  end)

  it("标记全未命中时 resolve 回退 $PWD；关闭检测时仍用 cwd", function(t)
    local wr = require("NeoAI.core.session.workspace_root")
    local base = vim.fn.tempname()
    fs.ensure_dir(base .. "/plain/x")
    fs.ensure_dir(base .. "/pwd")
    local old_pwd, old_cwd = vim.env.PWD, vim.fn.getcwd()
    -- 用不存在的标记名，避免宿主祖先的 .git/配置文件干扰判定。
    config.load({ session = { git_markers = { ".neoai_no_such_a" }, root_markers = { ".neoai_no_such_b" } } })

    vim.cmd("cd " .. vim.fn.fnameescape(base .. "/plain/x"))
    vim.env.PWD = base .. "/pwd"
    t.eq(norm(base .. "/pwd"), wr.resolve(), "无标记时应回退 $PWD 而非编辑器 cwd")

    vim.env.PWD = base .. "/gone"
    t.eq(norm(base .. "/plain/x"), wr.resolve(), "$PWD 目录不存在时应退回编辑器 cwd")

    config.load({ session = { detect_root = false } })
    vim.env.PWD = base .. "/pwd"
    t.eq(norm(base .. "/plain/x"), wr.resolve(), "关闭检测时应保持旧行为（直接用 cwd）")

    if old_cwd ~= "" then vim.cmd("cd " .. vim.fn.fnameescape(old_cwd)) end
    vim.env.PWD = old_pwd
    config.load({})
    vim.fn.delete(base, "rf")
  end)
end)
