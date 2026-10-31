--- 删除 = 搬出（retire）：节点 rename 到同盘 `.neoai-retired/`，撤销整棵搬回。
--- @module 'NeoAI.tests.test_sandbox_retire'
---
--- 覆盖：节点搬出（不遍历、不销毁）、整棵撤销、目录签名 CAS、搬出+重建、
--- `.git` 安全闸门、三视图可见性与生命周期回收。

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

local function stat(p)
  return vim.uv and vim.uv.fs_lstat(p) or vim.loop.fs_lstat(p)
end

local function sig(p)
  local st = stat(p)
  return require("NeoAI.sandbox.execution.candidate_util").dir_sig(st)
end

local function sha(content)
  return "sha256:" .. vim.fn.sha256(content)
end

local function read(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local c = f:read("*a")
  f:close()
  return c
end

tests.suite("sandbox_retire", function(_, it)
  it("发布：目录节点一次 rename 搬出，整棵内容保留且 git 视图干净", function(t)
    local fs = require("NeoAI.utils.fs")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local retired = require("NeoAI.sandbox.execution.retired")
    with_config({ tools = { sandbox = { enabled = true, mode = "dry_run" } } }, function()
      require("NeoAI.sandbox").reset()
      local base = fs.canonical(vim.fn.tempname())
      local dir = base .. "/proj"
      local dead = dir .. "/cache/deep"
      fs.ensure_dir(dead)
      fs.write_file(dead .. "/a.txt", "A\n")
      fs.write_file(dead .. "/b.bin", string.rep("B", 1024))
      local cand = {
        candidate_digest = "sha256:retire_dir",
        files = {
          { path = dir .. "/cache", action = "retire", recursive = true,
            base_exists = true, base_type = "directory", before_sig = sig(dir .. "/cache") },
        },
      }
      local pub = candidate.publish(cand, { change_set_id = "cs_rd" })
      t.true_(pub.ok, "节点搬出应成功: " .. tostring(pub.reason))
      t.nil_(stat(dir .. "/cache"), "原路径应消失（一次 rename）")
      local moved = assert(pub.retired and pub.retired[1] and pub.retired[1].retired)
      t.eq("A\n", read(moved .. "/deep/a.txt"), "搬出层应完整保留子树")
      t.eq(1024, #assert(read(moved .. "/deep/b.bin")), "大文件内容应完整")
      -- 搬出层对 git 不可见（自带 `*` 的 .gitignore）
      t.eq("*\n", read((moved:match("^(.*)/[^/]*$")):match("^(.*)/[^/]*$") .. "/.gitignore"),
        "搬出容器应含 `*` 的 .gitignore")
      t.eq("NeoAI retired layer\n",
        read((moved:match("^(.*)/[^/]*$")):match("^(.*)/[^/]*$") .. "/.neoai-owner"),
        "搬出容器应有 owner 标记（同名用户目录不会被误用）")
      if vim.fn.executable("git") == 1 then
        vim.fn.system({ "git", "-C", dir, "init", "-q" })
        local out = vim.fn.system({ "git", "-C", dir, "status", "--porcelain" })
        t.eq("", out, "搬出层不得出现在 git status: " .. tostring(out))
      end
      -- 撤销 = 整棵搬回
      local writer = require("NeoAI.sandbox.execution.writer")
      local back = writer.apply("unretire", dir .. "/cache", moved, {})
      t.true_(back.ok, "撤销应整棵搬回: " .. tostring(back.err))
      t.eq("A\n", read(dir .. "/cache/deep/a.txt"), "搬回后内容应完整")
      t.nil_(stat(dir .. "/cache/.neoai-retired"), "搬回后不应残留搬出目录")
      vim.fn.delete(base, "rf")
    end)
  end)

  it("发布：文件节点搬出保留权限位，撤销后权限一致", function(t)
    local fs = require("NeoAI.utils.fs")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local writer = require("NeoAI.sandbox.execution.writer")
    with_config({ tools = { sandbox = { enabled = true, mode = "dry_run" } } }, function()
      require("NeoAI.sandbox").reset()
      local base = fs.canonical(vim.fn.tempname())
      fs.ensure_dir(base)
      local f = base .. "/run.sh"
      fs.write_file(f, "#!/bin/sh\necho hi\n")
      vim.uv.fs_chmod(f, 493) -- 0755
      local before = stat(f).mode % 4096
      local cand = {
        candidate_digest = "sha256:retire_file",
        files = {
          { path = f, action = "retire", base_exists = true, base_type = "file",
            before_hash = sha(read(f)) },
        },
      }
      local pub = candidate.publish(cand, { change_set_id = "cs_rf" })
      t.true_(pub.ok, "文件搬出应成功: " .. tostring(pub.reason))
      t.nil_(stat(f), "原文件应消失")
      local moved = pub.retired[1].retired
      t.eq(before, stat(moved).mode % 4096, "搬出后权限位应保留")
      local back = writer.apply("unretire", f, moved, {})
      t.true_(back.ok, "撤销应成功")
      t.eq(before, stat(f).mode % 4096, "搬回后权限位应一致")
      vim.fn.delete(base, "rf")
    end)
  end)

  it("CAS：目录签名变化（外部新增）→ BASELINE_CHANGED，不吞并他人写入", function(t)
    local fs = require("NeoAI.utils.fs")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    with_config({ tools = { sandbox = { enabled = true, mode = "dry_run" } } }, function()
      require("NeoAI.sandbox").reset()
      local base = fs.canonical(vim.fn.tempname())
      local d = base .. "/d"
      fs.ensure_dir(d)
      fs.write_file(d .. "/a.txt", "a\n")
      local before = sig(d)
      -- 目录 mtime 粒度可能是 1s：等待跨秒后再制造外部改动，保证签名确实变化。
      vim.wait(1200, function() return false end)
      -- 外部新增一个文件（目录 mtime 变化）
      fs.write_file(d .. "/b.txt", "b\n")
      local cand = {
        candidate_digest = "sha256:retire_cas",
        files = {
          { path = d, action = "retire", recursive = true, base_exists = true,
            base_type = "directory", before_sig = before },
        },
      }
      local pub = candidate.publish(cand, { change_set_id = "cs_cas" })
      t.false_(pub.ok, "签名不符应拒绝")
      t.eq("CONFLICT", pub.state, "应为 CAS 冲突")
      t.matches("BASELINE_CHANGED", tostring(pub.reason), "应给明确原因")
      t.true_(fs.exists(d .. "/b.txt"), "冲突时不得搬走任何内容")
      vim.fn.delete(base, "rf")
    end)
  end)

  it("发布：同一候选「节点搬出 + 该目录下重建写入」→ 新目录只含候选视图", function(t)
    local fs = require("NeoAI.utils.fs")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    with_config({ tools = { sandbox = { enabled = true, mode = "dry_run" } } }, function()
      require("NeoAI.sandbox").reset()
      local base = fs.canonical(vim.fn.tempname())
      local venv = base .. "/.venv"
      fs.ensure_dir(venv .. "/old")
      fs.write_file(venv .. "/old/keep.txt", "old\n")
      local cand = {
        candidate_digest = "sha256:retire_recreate",
        files = {
          { path = venv, action = "retire", recursive = true, base_exists = true,
            base_type = "directory", before_sig = sig(venv) },
          { path = venv .. "/bin/python", action = "create", content = "#!/bin/sh\n",
            after_hash = sha("#!/bin/sh\n"), base_exists = false },
        },
      }
      local pub = candidate.publish(cand, { change_set_id = "cs_recreate" })
      t.true_(pub.ok, "搬出后重建应成功: " .. tostring(pub.reason))
      t.eq("#!/bin/sh\n", read(venv .. "/bin/python"), "新视图应写入")
      t.nil_(stat(venv .. "/old/keep.txt"), "旧内容不应残留在新视图")
      local moved = pub.retired[1].retired
      t.eq("old\n", read(moved .. "/old/keep.txt"), "旧内容应完整保留在搬出层")
      vim.fn.delete(base, "rf")
    end)
  end)

  it("安全：含 .git 目录的仓库根拒绝整棵搬出；工作树 `.git` 文件允许", function(t)
    local fs = require("NeoAI.utils.fs")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    with_config({ tools = { sandbox = { enabled = true, mode = "dry_run" } } }, function()
      require("NeoAI.sandbox").reset()
      local base = fs.canonical(vim.fn.tempname())
      local repo = base .. "/repo"
      fs.ensure_dir(repo .. "/.git")
      fs.write_file(repo .. "/.git/config", "[core]\n")
      local bad = candidate.publish({
        candidate_digest = "sha256:retire_repo",
        files = {
          { path = repo, action = "retire", recursive = true, base_exists = true,
            base_type = "directory" },
        },
      }, { change_set_id = "cs_repo" })
      t.false_(bad.ok, "含 .git 目录的仓库根不得整棵搬出")
      t.matches("SANDBOX_GIT_INTERNAL", tostring(bad.reason), "应明确拒绝原因: " .. tostring(bad.reason))
      t.true_(fs.exists(repo .. "/.git/config"), "拒绝时不得改动仓库")

      -- 工作树：`.git` 是**文件**（gitdir 反指），允许随父目录搬出（`git worktree remove` 语义）
      local wt = base .. "/wt"
      fs.ensure_dir(wt)
      fs.write_file(wt .. "/.git", "gitdir: ../repo/.git/worktrees/wt\n")
      fs.write_file(wt .. "/a.txt", "a\n")
      local ok = candidate.publish({
        candidate_digest = "sha256:retire_wt",
        files = {
          { path = wt, action = "retire", recursive = true, base_exists = true,
            base_type = "directory" },
        },
      }, { change_set_id = "cs_wt" })
      t.true_(ok.ok, "工作树（.git 文件）应允许搬出: " .. tostring(ok.reason))
      t.nil_(stat(wt), "工作树目录应被搬出")
      vim.fn.delete(base, "rf")
    end)
  end)

  it("安全：拒绝把自身运行时/store 的祖先目录整棵搬出", function(t)
    local fs = require("NeoAI.utils.fs")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local sb_base = fs.canonical(vim.fn.tempname())
    local sb_root = sb_base .. "/sb"
    fs.ensure_dir(sb_base)
    fs.ensure_dir(sb_root)
    with_config({ tools = { sandbox = { enabled = true, mode = "dry_run", workspace_root = sb_root } } }, function()
      require("NeoAI.sandbox").reset()
      local r = candidate.publish({
        candidate_digest = "sha256:retire_self_ancestor",
        files = { { path = sb_base, action = "retire", recursive = true, base_exists = true,
          base_type = "directory" } },
      }, { change_set_id = "cs_self_root" })
      t.false_(r.ok, "不得搬走沙箱 store 的祖先目录")
      t.matches("SANDBOX_RETIRE_SELF_ANCESTOR", tostring(r.reason), "应给明确原因: " .. tostring(r.reason))
      t.true_(fs.is_dir(sb_root), "拒绝时不得改动目录")
      vim.fn.delete(sb_base, "rf")
    end)
  end)

  it("安全：拒绝 `/` 与搬出层内部路径", function(t)    local candidate = require("NeoAI.sandbox.execution.candidate")
    with_config({ tools = { sandbox = { enabled = true, mode = "dry_run" } } }, function()
      require("NeoAI.sandbox").reset()
      local r1 = candidate.publish({
        candidate_digest = "sha256:retire_root",
        files = { { path = "/", action = "retire", recursive = true, base_exists = true,
          base_type = "directory" } },
      }, { change_set_id = "cs_root" })
      t.false_(r1.ok, "不得搬出 /")
      local r2 = candidate.publish({
        candidate_digest = "sha256:retire_layer",
        files = { { path = "/tmp/x/.neoai-retired/y", action = "retire", base_exists = true,
          base_type = "file" } },
      }, { change_set_id = "cs_layer" })
      t.false_(r2.ok, "不得搬出搬出层自身")
      t.matches("SANDBOX_RETIRED_TARGET", tostring(r2.reason), "应明确拒绝原因")
    end)
  end)

  it("视图：被搬出节点的子树不可见（读取/目录判定），重建的子项可见", function(t)
    local fs = require("NeoAI.utils.fs")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local control = require("NeoAI.sandbox.execution.control")
    local store = require("NeoAI.sandbox.state.store")
    with_config({ tools = { sandbox = { enabled = true, mode = "dry_run" } } }, function()
      require("NeoAI.sandbox").reset()
      local base = fs.canonical(vim.fn.tempname())
      local dir = base .. "/app"
      local upper = base .. "/upper"
      fs.ensure_dir(dir .. "/sub")
      fs.ensure_dir(upper)
      fs.write_file(dir .. "/sub/a.txt", "a\n")
      fs.write_file(upper .. "/.wh.sub", "")
      local a = control.new_attempt("run_command", { command = "rm -rf sub" }, {}, { effect = "process" })
      candidate.begin(a, assert(store.root()))
      candidate.capture_overlay(a.attempt_id, dir, upper)
      local cand = candidate.finish(a.attempt_id)
      t.true_(cand and #cand.files == 1, "删除只记一条节点")
      -- 视图：整棵子树不可见（不枚举，只按祖先节点判定）
      local mapped = candidate.read_path(dir .. "/sub/a.txt")
      t.not_nil(mapped, "被删子树下的路径应映射到不存在的暂存路径（而不是真实文件）")
      t.nil_(stat(mapped), "映射目标不得存在（读取即失败，与已删文件一致）")
      t.false_(candidate.view_is_dir(dir .. "/sub"), "被删节点不应再判为目录")
      -- 重建的同名子树：写入后按精确条目恢复可见
      candidate.merge_candidate({
        files = {
          { path = dir .. "/sub/new.txt", action = "create", content = "n\n" },
        },
      })
      t.true_(candidate.read_path(dir .. "/sub/new.txt") ~= nil, "重建的子项应可见")
      candidate.cleanup(a.attempt_id)
      vim.fn.delete(base, "rf")
    end)
  end)

  it("生命周期：keep 外立即回收，keep 内保留；TTL 到期回收", function(t)    local fs = require("NeoAI.utils.fs")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local retired = require("NeoAI.sandbox.execution.retired")
    with_config({ tools = { sandbox = { enabled = true, mode = "dry_run" } } }, function()
      require("NeoAI.sandbox").reset()
      local base = fs.canonical(vim.fn.tempname())
      local d1, d2 = base .. "/d1", base .. "/d2"
      fs.ensure_dir(d1); fs.write_file(d1 .. "/a", "1")
      fs.ensure_dir(d2); fs.write_file(d2 .. "/b", "2")
      local p1 = candidate.publish({
        candidate_digest = "sha256:gc1",
        files = { { path = d1, action = "retire", recursive = true, base_exists = true, base_type = "directory" } },
      }, { change_set_id = "cs_gc1" })
      local p2 = candidate.publish({
        candidate_digest = "sha256:gc2",
        files = { { path = d2, action = "retire", recursive = true, base_exists = true, base_type = "directory" } },
      }, { change_set_id = "cs_gc2" })
      t.true_(p1.ok and p2.ok, "两次搬出都应成功")
      local r1, r2 = p1.retired[1].retired, p2.retired[1].retired
      -- 生命周期：cs_gc2 仍在列表（可撤销）→ 只回收 cs_gc1
      local n = retired.gc({ keep = { cs_gc2 = true }, ttl_days = 7 })
      t.eq(1, n, "应回收 1 个已离开列表的单元")
      t.nil_(stat(r1), "keep 外的搬出内容应被回收")
      t.not_nil(stat(r2), "keep 内的搬出内容应保留")
      -- TTL：把登记时间改老，超过 ttl_days 的兜底回收
      local registry = require("NeoAI.sandbox.state.store").root() .. "/retired.json"
      local raw = assert(fs.read_file(registry))
      local data = assert(vim.json.decode(raw))
      for _, list in pairs(data) do
        for _, e in ipairs(list) do e.at = os.time() - 30 * 86400 end
      end
      fs.write_file_atomic(registry, vim.json.encode(data))
      retired.gc({ keep = { cs_gc2 = true }, ttl_days = 7 })
      t.nil_(stat(r2), "TTL 到期应回收")
      vim.fn.delete(base, "rf")
    end)
  end)

  it("规划：同名用户目录不被复用；同名节点目标顺延", function(t)
    local fs = require("NeoAI.utils.fs")
    local retired = require("NeoAI.sandbox.execution.retired")
    with_config({ tools = { sandbox = { enabled = true, mode = "dry_run" } } }, function()
      require("NeoAI.sandbox").reset()
      local base = fs.canonical(vim.fn.tempname())
      local parent = base .. "/p"
      fs.ensure_dir(parent)
      -- 用户自己的同名目录（无 owner 标记）：绝不写入/复用
      fs.ensure_dir(parent .. "/.neoai-retired")
      fs.write_file(parent .. "/.neoai-retired/keep.txt", "user\n")
      local node = parent .. "/d"
      fs.ensure_dir(node)
      local plan = assert(retired.plan(node, "cs_plan"))
      t.eq(parent .. "/.neoai-retired-2", plan.container, "应顺延到 .neoai-retired-2")
      t.eq("user\n", fs.read_file(parent .. "/.neoai-retired/keep.txt"), "用户目录不得被改动")
      -- 同一单元内同名节点（重试/冲突）：目标顺延 `~2`
      local plan2 = assert(retired.plan(node, "cs_plan"))
      t.eq(plan.dest, plan2.dest, "纯计算应是确定性的")
      local moved = assert(retired.move(node, plan))
      t.not_nil(stat(moved), "搬出目标应存在")
      local plan3 = assert(retired.plan(node, "cs_plan"))
      t.eq(plan.dest .. "~2", plan3.dest, "搬出目标已存在时应顺延")
      vim.fn.delete(base, "rf")
    end)
  end)

  it("列举：搬出层对 list_files 不可见", function(t)
    local fs = require("NeoAI.utils.fs")
    with_config({ tools = { approval = { mode = "auto_allow" }, sandbox = { mode = "dry_run" } } }, function()
      require("NeoAI.sandbox").reset()
      local base = fs.canonical(vim.fn.tempname())
      fs.ensure_dir(base .. "/.neoai-retired/cs_x")
      fs.write_file(base .. "/.neoai-retired/cs_x/a.txt", "secret\n")
      fs.write_file(base .. "/visible.txt", "v\n")
      local done, out = false, nil
      require("NeoAI.tools").execute("list_files", { path = base, description = "t" }, {})
        :then_(function(r) out = r; done = true end, function(e) out = tostring(e); done = true end)
      t.true_(vim.wait(10000, function() return done end), "list_files 应完成")
      local text = tostring(out)
      t.true_(text:find("visible.txt", 1, true) ~= nil, "普通文件应列出: " .. text)
      t.nil_(text:find("neoai%-retired"), "搬出层不得出现在列举结果: " .. text)
      vim.fn.delete(base, "rf")
    end)
  end)

  it("审批视图：动作标签为「删除·已搬出」", function(t)
    local sr = require("NeoAI.ui.components.sandbox_review")
    local cwd = vim.fn.getcwd()
    local data = sr.build_lines({
      {
        change_set_id = "cs_label", tool = "edit_file",
        files = { { path = cwd .. "/gone", action = "retire", recursive = true, base_type = "directory" } },
      },
    })
    local found = false
    for _, line in ipairs(data.lines or {}) do
      if line:find("删除·已搬出", 1, true) then found = true break end
    end
    t.true_(found, "应显示搬出标签: " .. table.concat(data.lines or {}, "\n"))
  end)

  it("撤销（审批链路）：目录搬出后 u 整棵搬回并入队待审", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local review = require("NeoAI.sandbox.review.review")
    with_config({ tools = { sandbox = { enabled = true, mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local base = fs.canonical(vim.fn.tempname())
      local d = base .. "/tree"
      fs.ensure_dir(d .. "/sub")
      fs.write_file(d .. "/sub/a.txt", "A\n")
      local cand = {
        candidate_digest = "sha256:undo_dir",
        files = { { path = d, action = "retire", recursive = true, base_exists = true,
          base_type = "directory", before_sig = sig(d) } },
      }
      assert(require("NeoAI.sandbox.state.store").write_candidate(cand))
      local item = assert(review.enqueue(cand, { tool = "edit_file" }))
      local res = sandbox.apply(item.change_set_id, { auto_approve = true })
      t.true_(res.ok, "应用应成功: " .. tostring(res.reason))
      t.nil_(stat(d), "原路径应消失")
      local u = sandbox.undo(item.change_set_id)
      t.true_(u and u.ok, "撤销应成功: " .. tostring(u and u.reason))
      t.eq("PENDING", u.state, "撤销后应回到待审")
      t.eq("A\n", read(d .. "/sub/a.txt"), "整棵子树应完整搬回")
      local pending = sandbox.list_reviews({ review_state = "PENDING" })
      t.eq(1, #pending, "应有一个待审单元")
      -- 再次应用（重试）不应卡在 BASELINE_CHANGED
      local res2 = sandbox.apply(pending[1].change_set_id, { auto_approve = true })
      t.true_(res2.ok, "撤销后再次删除应成功: " .. tostring(res2.reason))
      vim.fn.delete(base, "rf")
    end)
  end)

  it("部分应用：搬出失败时后代写入不落到旧树，二者一起回队重试", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local review = require("NeoAI.sandbox.review.review")
    local diag = require("NeoAI.sandbox.observe.diag")
    with_config({ tools = { sandbox = { enabled = true, mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local base = fs.canonical(vim.fn.tempname())
      local d = base .. "/venv"
      fs.ensure_dir(d .. "/old")
      fs.write_file(d .. "/old/keep.txt", "old\n")
      local cand = {
        candidate_digest = "sha256:retire_partial",
        files = {
          { path = d, action = "retire", recursive = true, base_exists = true,
            base_type = "directory", before_sig = sig(d) },
          { path = d .. "/bin", action = "create", content = "BIN\n",
            after_hash = sha("BIN\n"), base_exists = false },
        },
      }
      assert(require("NeoAI.sandbox.state.store").write_candidate(cand))
      local item = assert(review.enqueue(cand, { tool = "edit_file" }))
      diag.set("retire", 1)
      local res = sandbox.apply(item.change_set_id, { auto_approve = true })
      t.eq("PARTIAL", res.state, "部分应用应返回 PARTIAL")
      t.true_((res.failed and #res.failed or 0) >= 1, "应记录失败项")
      t.true_(fs.exists(d .. "/old/keep.txt"), "搬出失败时旧树必须保留")
      t.nil_(stat(d .. "/bin"), "搬出失败时后代写入不得落到旧树")
      -- 回队的重试单元应同时包含节点与后代写入，且可成功
      local pending = sandbox.list_reviews({ review_state = "PENDING" })
      t.eq(1, #pending, "失败项应回队为待审")
      local actions = {}
      for _, f in ipairs(pending[1].files or {}) do actions[f.path] = f.action end
      t.eq("retire", actions[d], "回队应含节点搬出")
      t.eq("create", actions[d .. "/bin"], "回队应含被阻断的后代写入")
      local res2 = sandbox.apply(pending[1].change_set_id, { auto_approve = true })
      t.true_(res2.ok, "重试应成功: " .. tostring(res2.reason))
      t.eq("BIN\n", read(d .. "/bin"), "重试后应写入新视图")
      t.nil_(stat(d .. "/old/keep.txt"), "重试后旧内容应已搬出")
      vim.fn.delete(base, "rf")
    end)
  end)

  it("保留期清理：prune 回收已不在列表的搬出内容", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    with_config({ tools = { sandbox = { enabled = true, mode = "dry_run" } } }, function()
      sandbox.reset()
      local base = fs.canonical(vim.fn.tempname())
      local d = base .. "/prunable"
      fs.ensure_dir(d)
      fs.write_file(d .. "/a.txt", "a\n")
      local pub = candidate.publish({
        candidate_digest = "sha256:prune_retire",
        files = { { path = d, action = "retire", recursive = true, base_exists = true, base_type = "directory" } },
      }, { change_set_id = "cs_prune_retire" })
      t.true_(pub.ok, "搬出应成功")
      local moved = pub.retired[1].retired
      t.not_nil(stat(moved), "搬出内容应存在")
      -- 未登记任何审批单元 → keep 为空 → prune 应回收
      local stats = sandbox.prune()
      t.true_((stats.removed_retired or 0) >= 1, "prune 应回收该搬出内容: " .. vim.inspect(stats))
      t.nil_(stat(moved), "回收后搬出内容应被删除")
      vim.fn.delete(base, "rf")
    end)
  end)
end)
