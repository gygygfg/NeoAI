--- 沙箱会话：轮换/暂存 overlay/run_command/commit CAS/后端/磁盘
--- @module NeoAI.tests.test_sandbox_session
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

local function trim(s)
  return (tostring(s or ""):gsub("%s+$", ""))
end


tests.suite("sandbox_session", function(_, it)
  it("沙箱会话：轮换不立即删除旧暂存目录（避免 bind 源被删）", function(t)
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local control = require("NeoAI.sandbox.execution.control")
    local store = require("NeoAI.sandbox.state.store")
    with_config({ tools = { sandbox = { workspace_root = vim.fn.tempname() .. "/sb" } } }, function()
      sandbox.reset()
      local a = control.new_attempt("edit_file", {}, {}, { effect = "fs_write" })
      candidate.begin(a, store.root())
      local old_proc = candidate.process_dir()
      t.true_(vim.fn.isdirectory(old_proc) == 1, "旧进程目录应存在")
      candidate.rotate_session()
      -- 仍有在途尝试：旧目录不得被删除（否则运行中命令的 bind 源突然消失）
      t.true_(vim.fn.isdirectory(old_proc) == 1, "有在途尝试时旧目录不应被删")
      candidate.cleanup(a.attempt_id)
      -- 尝试结束后异步清理（线程池）
      local ok = vim.wait(5000, function() return vim.fn.isdirectory(old_proc) ~= 1 end)
      t.true_(ok, "尝试结束后旧目录应被异步清理")
    end)
  end)

  it("commit：基线被他人修改后 CAS 失败（CONFLICT），不覆盖", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "auto_allow" }, sandbox = { mode = "dry_run" } } }, function()
      sandbox.reset()
      local p = vim.fn.tempname() .. ".txt"
      fs.write_file(p, "base\n")
      local done = false
      require("NeoAI.tools").execute("edit_file", {
        file_path = p, mode = "write", content = "agent\n", description = "t",
      }, {}):then_(function()
        -- 模拟发布前他人修改真实工作区
        fs.write_file(p, "human\n")
        local cand = sandbox.list()[1]
        local res = sandbox.commit(cand.candidate_digest)
        t.false_(res.ok, "基线变化应 CAS 失败")
        t.eq("CONFLICT", res.state)
        t.eq("human", trim(fs.read_file(p)), "不得覆盖他人修改")
        fs.delete_file(p)
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(3000, function() return done end), "edit_file 应完成")
    end)
  end)

  it("buffer 写盘工具 dry_run 不落真实磁盘", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "auto_allow" }, sandbox = { mode = "dry_run" } } }, function()
      sandbox.reset()
      local p = vim.fn.tempname() .. ".lua"
      fs.write_file(p, "local keep = 1\nlocal remove = 2\n")
      local done = false
      require("NeoAI.tools").execute("delete_node", {
        file_path = p, line = 2, col = 1, description = "t",
      }, {}):then_(function()
        t.matches("remove", fs.read_file(p) or "", "dry_run 下真实文件不应被删除节点")
        local list = sandbox.list()
        t.eq(1, #list, "应冻结候选")
        fs.delete_file(p)
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(3000, function() return done end), "delete_node 应完成")
    end)
  end)

  it("运行时：能力探测与隔离进程执行", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    local caps = runtime.probe()
    t.true_(caps.bwrap or caps.unshare, "应至少有一种隔离工具")
    local backend = runtime.backend()
    t.not_nil(backend, "auto 应选出一个可用后端")
    if backend then
      local done = false
      runtime.run({ "sh", "-c", "echo isolated-ok" }, { timeout_ms = 5000 }):then_(function(r)
        t.eq(0, r.code, "隔离命令应成功: " .. tostring(r.stderr))
        t.matches("isolated%-ok", r.stdout or "")
        done = true
      end, function(e)
        t.true_(false, "隔离执行不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(8000, function() return done end), "隔离进程应完成")
    end
  end)

  it("runtime：后端可用时构造前缀，不可用时返回明确错误", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    local prefix, err = runtime.process_prefix({})
    if runtime.backend() == nil then
      t.nil_(prefix)
      t.matches("SANDBOX_BACKEND_UNAVAILABLE", tostring(err))
    else
      t.not_nil(prefix, "有后端时应能构造前缀")
      t.eq("table", type(prefix))
      t.eq(nil, err)
    end
  end)

  it("隐匿：进程前缀含 --as-pid-1 且不暴露沙箱自有路径", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    local conceal = require("NeoAI.sandbox.observe.conceal")
    if runtime.backend() ~= "bwrap" then return end
    local prefix = runtime.process_prefix({ cwd = "/tmp", session_dir = "/tmp/neoai_sess" })
    t.not_nil(prefix, "应能构造前缀")
    local joined = table.concat(prefix, " ")
    t.true_(joined:find("--as-pid-1", 1, true) ~= nil, "应使用 --as-pid-1 隐藏 bwrap 进程")
    t.true_(joined:find("NeoAI-sandbox", 1, true) == nil, "前缀不应含 NeoAI-sandbox")
    t.true_(joined:find(".neoai_session", 1, true) == nil, "前缀不应含旧会话挂载点")
    t.true_(joined:find(conceal.session_mount(), 1, true) ~= nil, "应使用无特征会话挂载点")
    -- root 且免 userns 时不应出现 --unshare-all（uid_map / ns-user 指纹）
    if runtime.capabilities().userns_free then
      t.true_(joined:find("--unshare-all", 1, true) == nil, "免 userns 时不应含 --unshare-all")
      t.true_(joined:find("--unshare-user", 1, true) == nil, "免 userns 时不应含 --unshare-user")
    end
  end)

  it("隐匿：overlay 基目录与会话挂载点无特征命名", function(t)
    local conceal = require("NeoAI.sandbox.observe.conceal")
    if vim.fn.isdirectory("/dev/shm") == 1 and vim.fn.filewritable("/dev/shm") == 2 then
      t.true_(not conceal.base_host():find("NeoAI", 1, true), "基目录不应含 NeoAI")
      t.true_(not conceal.base_host():find("sandbox", 1, true), "基目录不应含 sandbox")
    end
    t.true_(not conceal.session_basename():find("neoai", 1, true), "会话名不应含 neoai")
  end)

  it("暂存后端：默认落盘（不占 /dev/shm 内存），可切回 shm；私有 tmp 与基目录同后端", function(t)
    local conceal = require("NeoAI.sandbox.observe.conceal")
    with_config({ tools = { sandbox = { staging_backend = "disk" } } }, function()
      local base = conceal.base_host()
      t.true_(base:sub(1, #"/dev/shm") ~= "/dev/shm", "默认不应在 /dev/shm（内存）")
      t.true_(base:find("NeoAI", 1, true) == nil and base:find("sandbox", 1, true) == nil,
        "基目录应无特征命名: " .. base)
      local tmp_base = conceal.tmp_base_host("/tmp")
      t.eq(base, tmp_base:sub(1, #base), "私有 /tmp 基目录应位于暂存基目录之下（同后端）")
    end)
    if vim.fn.isdirectory("/dev/shm") == 1 and vim.fn.filewritable("/dev/shm") == 2 then
      with_config({ tools = { sandbox = { staging_backend = "shm" } } }, function()
        t.eq("/dev/shm", conceal.base_host():sub(1, #"/dev/shm"), "shm 后端应使用 /dev/shm")
      end)
    end
  end)

  it("磁盘上限：默认 64GiB；暂存超限时拒绝写类/进程工具", function(t)
    local disk = require("NeoAI.sandbox.execution.disk")
    local conceal = require("NeoAI.sandbox.observe.conceal")
    with_config({ tools = { sandbox = { limits = { disk_bytes = 64 * 1024 * 1024 * 1024 } } } }, function()
      t.eq(64 * 1024 * 1024 * 1024, disk.limit(), "默认上限应为 64GiB")
      disk.refresh(true)
      t.true_(vim.wait(10000, function() return disk.usage() ~= nil end, 20), "用量统计应完成")
      t.true_(disk.check(), "未超限应放行")
    end)
    with_config({ tools = { sandbox = { limits = { disk_bytes = 1 } } } }, function()
      -- 确保暂存有字节占用（否则 0 < 1 不会触发）
      vim.fn.mkdir(conceal.base_host(), "p")
      require("NeoAI.utils.fs").write_file(conceal.base_host() .. "/x", "hello")
      disk.refresh(true)
      t.true_(vim.wait(10000, function() return (disk.usage() or 0) > 0 end, 20), "用量统计应完成且 > 0")
      local ok, err = disk.check()
      t.false_(ok, "超限应拒绝")
      t.matches("SANDBOX_DISK_LIMIT_EXCEEDED", err or "")
      -- 门禁：run_command 在超限时应被拒绝（不执行）
      local rejected
      local done = false
      require("NeoAI.tools").execute("run_command", { command = "echo hi", description = "t" }, {})
        :then_(function() done = true end, function(e) rejected = e; done = true end)
      t.true_(vim.wait(10000, function() return done end, 20), "应返回")
      t.not_nil(rejected, "超限时 run_command 应被拒绝")
      t.matches("DISK_LIMIT", tostring(rejected and (rejected.message or rejected)) .. "")
    end)
    pcall(vim.fn.delete, conceal.base_host() .. "/x")
    disk.reset()
  end)

  it("加固：默认最小权限（cap-drop ALL + 主机全局能力收敛），可显式放宽", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local fs = require("NeoAI.utils.fs")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local file = dir .. "/secret.sock"
    fs.write_file(file, "")
    -- 默认：cap-drop ALL + 档位基线（T0 仅 CAP_DAC_OVERRIDE），并按 cap_drop 额外收敛主机全局能力；
    -- 读取面靠遮蔽 + 只读根收敛，写入靠 overlay 暂存。
    local privilege = require("NeoAI.sandbox.execution.privilege")
    local t0 = privilege.resolve(0, { tier = 0 })
    t.true_(t0.ok, "T0 应可解析")
    with_config({ tools = { sandbox = { mask_paths = { dir, file } } } }, function()
      local prefix = runtime.process_prefix({ cwd = "/tmp", privileges = t0.privileges })
      t.not_nil(prefix, "应能构造前缀")
      local joined = table.concat(prefix, " ")
      t.true_(joined:find("--cap-drop ALL", 1, true) ~= nil, "默认应丢弃全部 capability（最小权限）")
      t.true_(joined:find("--cap-drop CAP_NET_ADMIN", 1, true) ~= nil, "应丢弃 CAP_NET_ADMIN（禁 netlink 改宿主网络）")
      t.true_(joined:find("--cap-drop CAP_SYS_TIME", 1, true) ~= nil, "应丢弃 CAP_SYS_TIME（禁改宿主时钟）")
      t.true_(joined:find("--cap-drop CAP_SYS_MODULE", 1, true) ~= nil, "应丢弃 CAP_SYS_MODULE")
      t.true_(joined:find("--cap-drop CAP_SYS_RAWIO", 1, true) ~= nil, "应丢弃 CAP_SYS_RAWIO")
      -- 基线加回 CAP_DAC_OVERRIDE（root 载荷访问他人属主 0700 目录）+ CAP_SETUID/CAP_SETGID
      -- （沙箱内降权，供 PostgreSQL 等拒绝 root 运行的服务）；CHOWN 等仍按命令窄授予。
      t.true_(joined:find("--cap-add CAP_DAC_OVERRIDE", 1, true) ~= nil, "应基线加回 CAP_DAC_OVERRIDE")
      t.true_(joined:find("--cap-add CAP_CHOWN", 1, true) == nil, "默认不应加回 CAP_CHOWN")
      t.true_(joined:find("--cap-add CAP_SETUID", 1, true) ~= nil, "应基线加回 CAP_SETUID（沙箱内降权）")
      t.true_(joined:find("--cap-add CAP_SETGID", 1, true) ~= nil, "应基线加回 CAP_SETGID（沙箱内降权）")
      t.true_(joined:find("--tmpfs " .. dir, 1, true) ~= nil, "目录应以空 tmpfs 遮蔽")
      t.true_(joined:find("--bind /dev/null " .. file, 1, true) ~= nil, "文件/socket 应以 /dev/null 遮蔽")
    end)
    -- 显式放宽：cap_add = { "ALL" } → 不 --cap-drop ALL
    with_config({ tools = { sandbox = { cap_add = { "ALL" } } } }, function()
      local prefix = runtime.process_prefix({ cwd = "/tmp" })
      local joined = table.concat(prefix, " ")
      t.true_(joined:find("--cap-drop ALL", 1, true) == nil, "cap_add={ALL} 应保留完整能力")
    end)
    -- 显式列出被丢弃的能力时以显式为准（不重复 drop）
    with_config({ tools = { sandbox = { cap_add = { "ALL", "CAP_NET_ADMIN" } } } }, function()
      local prefix = runtime.process_prefix({ cwd = "/tmp" })
      local joined = table.concat(prefix, " ")
      t.true_(joined:find("--cap-drop CAP_NET_ADMIN", 1, true) == nil, "显式列出的能力不应被 cap_drop 覆盖")
    end)
    -- 档位能力：T2 嵌套 userns 内完整能力（caps 被 userns 作用域限制）
    local privilege = require("NeoAI.sandbox.execution.privilege")
    local t2 = privilege.resolve(2, { tier = 2, network = true })
    t.true_(t2.ok, "T2 应可解析")
    with_config({ tools = { sandbox = {} } }, function()
      local pre2 = table.concat(runtime.process_prefix({ cwd = "/tmp", privileges = t2.privileges }), " ")
      t.true_(pre2:find("--cap-drop ALL", 1, true) == nil, "T2 应保留完整能力（userns 内作用域受限）")
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("最小权限：载荷默认以非 root 运行（root 启动用 run_as + setpriv 降权）", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    with_config({ tools = { sandbox = { run_as = { uid = 65534, gid = 65534 } } } }, function()
      local prefix = runtime.process_prefix({ cwd = "/tmp" })
      t.not_nil(prefix, "应能构造前缀")
      local joined = table.concat(prefix, " ")
      if vim.uv.getuid() == 0 then
        -- root 启动：bwrap 保持 root 完成挂载，载荷经 setpriv 降权（不用 bwrap --uid，
        -- 否则 guest 会映射到宿主 root，是 root 伪装）。
        t.true_(joined:find("setpriv", 1, true) ~= nil, "root 启动应以 setpriv 降权载荷")
        t.true_(joined:find("--reuid 65534", 1, true) ~= nil, "应把载荷降为 uid 65534")
        t.true_(joined:find("--uid 65534", 1, true) == nil, "root 启动不应使用 bwrap --uid")
      else
        -- 非 root 启动：用 userns 把当前用户映射为沙箱内 guest root（euid=0），宿主仍非 root。
        t.true_(joined:find("--uid 0", 1, true) ~= nil, "非 root 启动应把沙箱内载荷映射为 root(uid 0)")
        t.true_(joined:find("--unshare-user", 1, true) ~= nil or joined:find("--unshare-all", 1, true) ~= nil,
          "非 root 载荷需要 user namespace 承载 --uid/--gid")
      end
    end)
    -- 显式放弃降权（uid=0）：不注入 --uid / setpriv（保持以 root 运行载荷）。
    with_config({ tools = { sandbox = { run_as = { uid = 0, gid = 0 } } } }, function()
      local prefix = runtime.process_prefix({ cwd = "/tmp" })
      local joined = table.concat(prefix, " ")
      t.true_(joined:find("--uid", 1, true) == nil, "uid=0 不应注入 --uid")
      t.true_(joined:find("setpriv", 1, true) == nil, "uid=0 不应 setpriv")
    end)
  end)

  it("只读 mount 列举不算特权；变更型 mount 仍为 T2", function(t)
    local privilege = require("NeoAI.sandbox.execution.privilege")
    local spec = { effect = "process" }
    for _, cmd in ipairs({
      "mount",
      "mount -l",
      "mount --show-labels",
      "mount -t ext4",
      "findmnt -no OPTIONS -T /root",
      "mount | grep -E ' / '",
      "ls -la; mount | head",
    }) do
      t.eq(0, privilege.classify("run_command", { command = cmd }, spec).tier,
        "只读 mount 不应升级档位: " .. cmd)
    end
    for _, cmd in ipairs({
      "mount /dev/sdb1 /mnt",
      "mount -a",
      "mount -o remount /",
      "umount /mnt",
    }) do
      t.eq(2, privilege.classify("run_command", { command = cmd }, spec).tier,
        "变更型 mount 应为 T2: " .. cmd)
    end
  end)

  it("T2 嵌套 userns 不追加 setpriv（避免未映射 uid EINVAL）", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    local privilege = require("NeoAI.sandbox.execution.privilege")
    if runtime.backend() ~= "bwrap" then return end
    local t2 = privilege.resolve(2, { tier = 2, network = true })
    t.true_(t2.ok, "T2 应可解析")
    with_config({ tools = { sandbox = { run_as = { uid = 65534, gid = 65534 } } } }, function()
      local prefix = runtime.process_prefix({ cwd = "/tmp", privileges = t2.privileges })
      t.not_nil(prefix, "应能构造 T2 前缀")
      local joined = table.concat(prefix, " ")
      if vim.uv.getuid() == 0 then
        t.true_(joined:find("--unshare-all", 1, true) ~= nil, "T2 应使用嵌套 userns")
        t.true_(joined:find("setpriv", 1, true) == nil,
          "T2 userns 内不应 setpriv（run_as.uid 未映射，会 EINVAL）")
      end
    end)
  end)

  it("最小权限：实际执行以非 root 身份（id -u == run_as.uid）", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" or vim.uv.getuid() ~= 0 then return end
    if vim.fn.executable("setpriv") ~= 1 then return end
    local sandbox = require("NeoAI.sandbox")
    -- 工作区须可被非 root 载荷遍历：用 /tmp 下的临时目录（真实部署中工作区归用户所有）。
    -- 注意不能用 vim.fn.tempname()（位于 /tmp/nvim.<user>，0700，非 root 不可遍历）。
    local ws = "/tmp/neoai-nr-" .. tostring(os.time()) .. "-" .. tostring(vim.fn.getpid())
    require("NeoAI.utils.fs").ensure_dir(ws)
    pcall(vim.uv.fs_chmod, ws, 493) -- 0755
    -- 沙箱存储根也须可被载荷遍历（默认在 /root 下，root 启动 + 专用 uid 时不可达）。
    local store_root = ws .. "/store"
    require("NeoAI.utils.fs").ensure_dir(store_root)
    pcall(vim.uv.fs_chmod, store_root, 493)
    local saved_cwd = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(ws))
    local ok, err = pcall(function()
      with_config({ tools = { approval = { mode = "async" }, sandbox = {
        run_as = { uid = 65534, gid = 65534 }, mode = "dry_run", review = { enabled = true },
        workspace_root = store_root,
      } } }, function()
        sandbox.reset()
        local done, out = false, nil
        require("NeoAI.tools").execute("run_command", { command = "id -u", description = "t" }, {})
          :then_(function(r) out = tostring(r); done = true end,
            function(e) out = "ERR:" .. tostring(e and e.message or e); done = true end)
      t.true_(vim.wait(10000, function() return done end), "命令应完成")
      t.matches("65534", out, "载荷应以 uid 65534 运行（实际: " .. tostring(out) .. "）")
      -- 会话 shell 状态目录须可被非 root 载荷写入（cwd/env），否则命令会报
      -- `cannot create .../cwd: Permission denied`。
      t.true_(not tostring(out):find("Permission denied", 1, true),
        "会话状态目录不应有权限错误（实际: " .. tostring(out) .. "）")
    end)
    end)
    vim.cmd("cd " .. vim.fn.fnameescape(saved_cwd))
    vim.fn.delete(ws, "rf")
    if not ok then error(err, 0) end
  end)

  it("落盘：先非 root 尝试，权限不足 → NEEDS_ROOT；批准后以 root 写入", function(t)
    local writer = require("NeoAI.sandbox.execution.writer")
    if vim.uv.getuid() ~= 0 then return end
    local fs = require("NeoAI.utils.fs")
    local dir = "/tmp/neoai-writer-" .. tostring(os.time()) .. "-" .. tostring(vim.fn.getpid())
    fs.ensure_dir(dir)
    pcall(vim.uv.fs_chmod, dir, 493) -- 0755（root 属主，非 root 不可写）
    local target = dir .. "/f.txt"
    with_config({ tools = { sandbox = { run_as = { uid = 65534, gid = 65534 } } } }, function()
      local res = writer.apply("write", target, "hi\n", {})
      t.eq(writer.STATE.NEEDS_ROOT, res.state, "非 root 不可写应返回 NEEDS_ROOT")
      t.true_(vim.uv.fs_stat(target) == nil, "未批准时不应写入真实盘")
      local res2 = writer.apply("write", target, "hi\n", { allow_root = true })
      t.true_(res2.ok, "批准后应写入: " .. tostring(res2.err))
      t.eq("root", res2.writer, "批准后应以 root 写入")
      t.eq("hi\n", fs.read_file(target))
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("权限：permission denied / read-only 触发提权建议（全档位）", function(t)
    local privilege = require("NeoAI.sandbox.execution.privilege")
    local esc = privilege.detect_escalation({ code = 1, stderr = "touch: cannot touch '/x': Permission denied" })
    t.not_nil(esc, "permission denied 应触发提权建议")
    t.eq(privilege.TIER.PRIVILEGED, esc.tier)
    local esc2 = privilege.detect_escalation({ code = 1, stderr = "Read-only file system" })
    t.not_nil(esc2, "read-only 应触发提权建议")
  end)

  it("风险：危险指令（fork bomb / shred / wipefs）判为 L3 且默认待审", function(t)
    local risk = require("NeoAI.sandbox.review.risk")
    local cmds = { ":(){ :|:& };:", "shred -u /etc/passwd", "wipefs -a /dev/sda", "dd if=/dev/zero of=/dev/sda" }
    for _, cmd in ipairs(cmds) do
      local r = risk.classify({ command = cmd, tool = "run_command" })
      t.eq(3, r.level, "应判 L3: " .. cmd)
      t.eq("review", risk.action(r.level, {}), "默认应进入待审: " .. cmd)
    end
  end)

  it("安全：禁止访问本机 SSH 服务（命令级硬拒绝 + agent 遮蔽 + 环境清除）", function(t)
    local risk = require("NeoAI.sandbox.review.risk")
    local runtime = require("NeoAI.sandbox.execution.runtime")
    for _, cmd in ipairs({
      "ssh root@localhost", "scp a 127.0.0.1:/x", "sftp ::1",
      "git clone ssh://127.0.0.1/repo", "sshpass -p x ssh localhost",
    }) do
      local denied = risk.ssh_local_target(cmd)
      t.true_(denied, "应拒绝本机 SSH: " .. cmd)
    end
    t.false_(risk.ssh_local_target("ssh user@example.com"), "远端 ssh 不应拒绝")
    t.false_(risk.ssh_local_target("ls -la"), "非 ssh 命令不应拒绝")
    with_config({ tools = { sandbox = {} } }, function()
      t.not_nil(runtime.is_masked_path("/run/sshd"), "应遮蔽 sshd 运行目录")
      t.not_nil(runtime.is_masked_path("/run/ssh-agent.socket"), "应遮蔽 ssh-agent socket")
      local sn = runtime.proxy_unset_snippet()
      t.matches("SSH_AUTH_SOCK", sn or "", "应清除 SSH_AUTH_SOCK")
    end)
  end)

  it("密钥：AI 生成的高熵内容被识别（生成私钥/随机 token 需关注）", function(t)
    local secret = require("NeoAI.sandbox.secret.secret")
    secret.reset()
    local key_line = string.rep("MIIEowIBAAKCAQEA", 4)
    local files = {
      { path = "/tmp/gen.key", content = "-----BEGIN RSA PRIVATE KEY-----\n" .. key_line .. "\n-----END RSA PRIVATE KEY-----\n" },
      { path = "/tmp/tok.txt", content = "token=Zx9Qw2Lm7Pk4Rt8Yv3Bn6Hd1Sg5Jf0Ac\n" },
      { path = "/tmp/plain.txt", content = "hello world, no secrets here\n" },
    }
    local hits = secret.detect_generated(files)
    t.true_(#hits >= 2, "应识别生成的高熵/私钥内容，实际: " .. vim.inspect(hits))
    -- 宿主密钥的加密 token（NEOKEY_*）不应被当作「AI 生成密钥」
    local h2 = secret.detect_generated({ { path = "/x", content = "k=NEOKEY_deadbeefcafebabe\n" } })
    t.eq(0, #h2, "NEOKEY token 不应计入生成高熵")
  end)

  it("密钥：生成检测受扫描预算约束（大候选不占满主线程）", function(t)
    local secret = require("NeoAI.sandbox.secret.secret")
    secret.reset()
    with_config({ tools = { sandbox = { secrets = { generated_scan_max_files = 1 } } } }, function()
      local files = {
        { path = "/tmp/a.key", content = "token=Zx9Qw2Lm7Pk4Rt8Yv3Bn6Hd1Sg5Jf0Ac\n" },
        { path = "/tmp/b.key", content = "token=Ab1Cd2Ef3Gh4Ij5Kl6Mn7Op8Qr9St0Uv\n" },
      }
      local hits = secret.detect_generated(files)
      t.eq(1, #hits, "超出扫描预算的文件不应被扫描")
    end)
  end)

  it("密钥：异步分析结果与同步一致（工作线程）", function(t)
    local secret = require("NeoAI.sandbox.secret.secret")
    secret.reset()
    local files = {
      { path = "/tmp/a.key", content = "token=Zx9Qw2Lm7Pk4Rt8Yv3Bn6Hd1Sg5Jf0Ac\n" },
      { path = "/tmp/b.key", content = "-----BEGIN RSA PRIVATE KEY-----\n"
        .. string.rep("MIIEowIBAAKCAQEA", 4) .. "\n-----END RSA PRIVATE KEY-----\n" },
      { path = "/tmp/plain.txt", content = "hello world, nothing to see\n" },
    }
    return secret.analyze_files_async(files):then_(function(r)
      if r.offloaded == false then return end -- 无 worker：跳过（同步版已另有覆盖）
      local sw = secret.warn_for_files(files)
      t.eq(sw and sw.count or 0, r.warning and r.warning.count or 0, "token 计数应与同步一致")
      t.eq(#secret.detect_generated(files), #r.generated, "生成高熵命中数应与同步一致")
    end)
  end)

  it("存储：异步写入立即可读且 flush 后落盘", function(t)
    local store = require("NeoAI.sandbox.state.store")
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    store.init(root)
    local cand = {
      candidate_digest = "sha256:async1", created_at = 1,
      files = { { path = "/tmp/x", content = "hello" } },
    }
    local done = false
    store.write_candidate_async(cand):then_(function()
      t.not_nil(store.read_candidate("sha256:async1"), "写入后应立即可读（内存缓存）")
      local listed = false
      for _, c in ipairs(store.list_candidates()) do
        if c.candidate_digest == "sha256:async1" then listed = true end
      end
      t.true_(listed, "列表应包含异步写入的候选")
      t.true_(store.flush(2000), "flush 应完成")
      t.eq(1, vim.fn.filereadable(root .. "/candidates/sha256_async1.json"), "flush 后应落盘")
      done = true
    end, function(e)
      t.true_(false, tostring(e and e.message or e)); done = true
    end)
    t.true_(vim.wait(3000, function() return done end), "应完成")
    store.reset()
  end)

  it("存储：非法 UTF-8 候选经线程校验后无损落盘（二进制不损坏）", function(t)
    local store = require("NeoAI.sandbox.state.store")
    local fs = require("NeoAI.utils.fs")
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    store.init(root)
    -- 模拟 OpenPGP keyring：含 NUL 与大量非法 UTF-8 字节的二进制内容。
    local bin = "\xef\xbf\xbd\x02\x0d\x04\x63\x17\x2e\xcf\x98\x1f\x06\x7d\xff\xfe\x00\x80\xc0"
    local cand = {
      candidate_digest = "sha256:badutf8",
      files = { { path = "/tmp/x", content = "ok\xff\xfeend" .. bin } },
    }
    store.write_candidate_async(cand)
    t.true_(store.flush(5000), "flush 应完成")
    local raw = fs.read_file(root .. "/candidates/sha256_badutf8.json")
    t.not_nil(raw, "应落盘")
    t.false_(raw:find("\xff", 1, true) ~= nil, "落盘 JSON 不应含非法 UTF-8 字节")
    -- 关键：读回内容必须与原二进制**逐字节一致**（此前会被替换为 U+FFFD 而损坏）。
    local got = store.read_candidate("sha256:badutf8")
    t.not_nil(got, "应可读回")
    t.eq(cand.files[1].content, got.files[1].content, "二进制内容应无损往返")
    store.reset()
  end)

  it("JSON：encode_lossless/decode_lossless 无损往返二进制，encode 会损坏", function(t)
    local json = require("NeoAI.utils.json")
    local bin = "abc\xff\xfe\x00\x80\xc0\xef\xbf\xbddef"
    local enc = json.encode_lossless({ content = bin, nested = { { v = bin } } })
    t.true_(enc:find("__neoai_bytes_b64__", 1, true) ~= nil, "应使用 base64 哨兵")
    local dec = json.decode_lossless(enc)
    t.eq(bin, dec.content, "顶层二进制应无损")
    t.eq(bin, dec.nested[1].v, "嵌套二进制应无损")
    -- 对照：普通 encode 会把非法字节替换为 U+FFFD（因此持久化不能用它）
    local lossy = json.decode(json.encode({ content = bin }))
    t.true_(lossy.content ~= bin, "encode 应有损（证明必须用 lossless）")
    t.matches("\239\191\189", lossy.content, "encode 应替换为 U+FFFD")
    -- 合法文本：lossless 与 encode 输出一致
    t.eq(json.encode({ a = "中文ok" }), json.encode_lossless({ a = "中文ok" }), "合法文本编码应一致")
  end)

  it("存储：异步写入快照立即可读且 flush 后落盘", function(t)
    local store = require("NeoAI.sandbox.state.store")
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    store.init(root)
    local rec = {
      snapshot_id = "snap_async1", state = "APPLIED",
      files = { { path = "/tmp/x", alt_content = "old-content" } },
    }
    store.write_snapshot_async(rec)
    local got = store.read_snapshot("snap_async1")
    t.not_nil(got, "写入后应立即可读（内存缓存）")
    t.eq("snap_async1", got.snapshot_id)
    t.eq("old-content", got.files[1].alt_content)
    t.true_(store.flush(2000), "flush 应完成")
    t.eq(1, vim.fn.filereadable(root .. "/snapshots/snap_async1.json"), "flush 后应落盘")
    local listed = false
    for _, s in ipairs(store.list_snapshots()) do
      if s.snapshot_id == "snap_async1" then listed = true end
    end
    t.true_(listed, "落盘快照应可被列出")
    store.reset()
  end)

  it("工作线程：batched 保持顺序且限制并发", function(t)
    local work = require("NeoAI.utils.work")
    if not work.available() then return end
    local tasks = {}
    for i = 1, 20 do tasks[i] = i end
    local max_inflight, inflight = 0, 0
    local done, results, err = false, nil, nil
    work.batched(tasks, 3, function(v)
      inflight = inflight + 1
      if inflight > max_inflight then max_inflight = inflight end
      return work.run(function(x) return tostring(x) end, v):then_(function(r)
        inflight = inflight - 1
        return r
      end)
    end):then_(function(res)
      results = res; done = true
    end, function(e)
      err = e; done = true
    end)
    t.true_(vim.wait(10000, function() return done end), "应完成: " .. tostring(err and err.message or err))
    t.eq(20, #(results or {}), "结果数应一致")
    t.eq("1", results[1], "顺序应保持")
    t.eq("20", results[20], "顺序应保持")
    t.true_(max_inflight <= 3, "并发不应超过上限")
  end)

  it("加固：只读白名单可配置且跳过不存在项", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    local fs = require("NeoAI.utils.fs")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local file = dir .. "/keep.conf"
    fs.write_file(file, "x")
    with_config({ tools = { sandbox = {
      read_all = false,
      readonly_roots = { dir },
      readonly_paths = { file, dir .. "/missing.conf" },
    } } }, function()
      local joined = table.concat(runtime.append_readonly({}), " ")
      t.true_(joined:find("--ro-bind " .. dir .. " " .. dir, 1, true) ~= nil, "应只读暴露配置的根")
      t.true_(joined:find("--ro-bind " .. file .. " " .. file, 1, true) ~= nil, "应只读暴露配置的文件")
      t.true_(joined:find("missing.conf", 1, true) == nil, "不存在项应跳过")
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("加固：读取面收敛（/usr 不整目录暴露，/var/lib 与 /usr/share 只读暴露）", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    with_config({ tools = { sandbox = { read_all = false } } }, function()
    local prefix = runtime.process_prefix({ cwd = "/tmp" })
    t.not_nil(prefix, "应能构造前缀")
    local joined = table.concat(prefix, " ")
    t.true_(joined:find("--ro-bind / /", 1, true) == nil, "不应再整机只读根")
    t.true_(joined:find("--ro-bind /usr /usr ", 1, true) == nil, "不应整目录暴露 /usr")
    t.true_(joined:find("--ro-bind /usr/bin /usr/bin", 1, true) ~= nil, "应白名单暴露 /usr/bin")
    t.true_(joined:find("--ro-bind /usr/lib /usr/lib", 1, true) ~= nil, "应白名单暴露 /usr/lib")
    t.true_(joined:find("--ro-bind /usr/share /usr/share", 1, true) ~= nil, "应只读暴露 /usr/share")
    t.true_(joined:find("--ro-bind /var/lib /var/lib", 1, true) ~= nil, "应只读暴露 /var/lib")
    local cmd = {}
    for _, v in ipairs(prefix) do cmd[#cmd + 1] = v end
    for _, v in ipairs({ "/bin/sh", "-c",
      "if [ -e /home ]; then echo LEAK_HOME; fi; "
      .. "if [ -s /etc/shadow ]; then echo LEAK_SHADOW; fi; "
      .. "if [ -s /etc/machine-id ]; then echo LEAK_MACHINEID; fi; "
      .. "if [ -n \"$(ls -A /var/log 2>/dev/null)\" ]; then echo LEAK_VARLOG; fi; "
      .. "if [ -e /usr/local/go_workspace ]; then echo LEAK_GOWORKSPACE; fi; "
      .. "if [ -e /usr/src ]; then echo LEAK_USRSRC; fi; "
      .. "if [ -d /usr/share ] && [ -d /var/lib ]; then echo VISIBLE_OK; fi; "
      .. "echo READ_CONVERGED",
    }) do cmd[#cmd + 1] = v end
    local out = vim.fn.system(cmd)
    t.true_(out:find("READ_CONVERGED", 1, true) ~= nil, "命令应完成，实际: " .. tostring(out))
    t.true_(out:find("LEAK_", 1, true) == nil, "不应泄露宿主敏感路径，实际: " .. tostring(out))
    t.true_(out:find("VISIBLE_OK", 1, true) ~= nil, "/var/lib 与 /usr/share 应可见，实际: " .. tostring(out))
    end)
  end)

  it("加固：read_all 整机只读暴露，mask_paths 仍遮蔽、mask_dirs 不遮蔽", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    with_config({ tools = { sandbox = { read_all = true } } }, function()
      t.true_(runtime.read_all(), "read_all 默认开")
      local joined = table.concat(runtime.process_prefix({ cwd = "/tmp" }), " ")
      t.true_(joined:find("--ro-bind / /", 1, true) ~= nil, "应整机只读暴露")
      -- 重要配置文件（mask_paths）仍遮蔽
      t.true_(joined:find("--tmpfs /root/.ssh", 1, true) ~= nil, "mask_paths 应仍遮蔽 /root/.ssh")
      -- mask_dirs（home/root 兄弟目录）不再挂载遮蔽
      t.true_(joined:find("--tmpfs /root/neoai", 1, true) == nil, "mask_dirs 不应再遮蔽兄弟目录")
    end)
  end)

  it("越界访问判定：cwd 之外的用户目录命中，cwd 子树/系统路径不命中", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    t.eq("/root/other/x", runtime.outside_workspace("/root/other/x", "/root/proj"), "cwd 外 home 路径应命中")
    t.nil_(runtime.outside_workspace("/root/proj/a.lua", "/root/proj"), "cwd 子树不命中")
    t.nil_(runtime.outside_workspace("/usr/bin/ls", "/root/proj"), "系统路径不命中")
  end)

  it("越界访问判定：遮蔽目录配置变更后前缀缓存失效", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    with_config({ tools = { sandbox = { mask_dirs = { "/etc" } } } }, function()
      t.eq("/etc/x", runtime.outside_workspace("/etc/x", "/root/proj"), "自定义遮蔽目录应命中")
      t.nil_(runtime.outside_workspace("/root/other/x", "/root/proj"), "未配置的 /root 不再命中")
    end)
    -- 恢复默认配置：缓存应按配置表引用失效，/root 重新命中
    t.eq("/root/other/x", runtime.outside_workspace("/root/other/x", "/root/proj"),
      "恢复默认后 /root 应重新命中")
  end)

  it("越界访问判定：软件包/依赖缓存目录不计入（避免审批悬浮窗刷屏）", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    local home = vim.fn.expand("~")
    t.nil_(runtime.outside_workspace(home .. "/.cache/uv/archive-v0/x.py", "/root/proj"),
      "~/.cache/uv 应忽略")
    t.nil_(runtime.outside_workspace(home .. "/.npm/_cacache/x", "/root/proj"),
      "~/.npm 应忽略")
    t.nil_(runtime.outside_workspace(home .. "/.cargo/registry/cache/x", "/root/proj"),
      "~/.cargo 应忽略")
    t.eq(home .. "/other/x", runtime.outside_workspace(home .. "/other/x", "/root/proj"),
      "非缓存 home 路径仍应命中")
  end)

  it("越界访问判定：trace_ignore_paths 可配置且变更后缓存失效", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    local home = vim.fn.expand("~")
    with_config({ tools = { sandbox = { observe = { trace_ignore_paths = { "~/work/cache" } } } } }, function()
      t.nil_(runtime.outside_workspace(home .. "/work/cache/a", "/root/proj"),
        "自定义忽略目录应命中")
      -- volatile_paths 始终合并：~/.cache/uv 仍忽略
      t.nil_(runtime.outside_workspace(home .. "/.cache/uv/x", "/root/proj"),
        "volatile_paths 合并后仍忽略")
      t.eq(home .. "/other/x", runtime.outside_workspace(home .. "/other/x", "/root/proj"),
        "其它 home 路径仍命中")
    end)
    -- 恢复默认：默认缓存目录重新忽略、自定义目录不再忽略
    t.nil_(runtime.outside_workspace(home .. "/.cache/uv/x", "/root/proj"),
      "恢复默认后缓存目录仍忽略")
    t.eq(home .. "/work/cache/a", runtime.outside_workspace(home .. "/work/cache/a", "/root/proj"),
      "恢复默认后自定义目录重新命中")
  end)

  it("证据：异步写入可 flush 落盘（观测留痕非阻塞）", function(t)
    local store = require("NeoAI.sandbox.state.store")
    local evidence = require("NeoAI.sandbox.review.evidence")
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    store.init(root)
    local id = evidence.add_async("observation",
      { kind = "outside_access", path = "/root/x" }, { tool = "run_command" })
    t.not_nil(id, "应返回 evidence_id")
    t.true_(store.flush(5000), "flush 应完成")
    t.not_nil(store.read_evidence(id), "异步写入的证据应可读回")
    store.reset()
  end)

  it("越界访问留痕：read_file 访问 cwd 外用户目录被记录（非阻塞）", function(t)
    local sandbox = require("NeoAI.sandbox")
    local fs = require("NeoAI.utils.fs")
    with_config({ tools = { approval = { mode = "auto_allow" }, sandbox = { mode = "dry_run", read_all = true } } }, function()
      sandbox.reset()
      local target = vim.fn.expand("~") .. "/.bashrc"
      if not fs.exists(target) then return end
      local done = false
      require("NeoAI.tools").execute("read_file", { file_path = target, description = "r" }, {})
        :then_(function() done = true end, function() done = true end)
      t.true_(vim.wait(8000, function() return done end), "应完成")
      local traces = sandbox.list_traces()
      t.true_(#traces >= 1, "应记录越界访问")
      local found = false
      for _, it in ipairs(traces) do
        if it.tool == "read_file" and it.path:find(".bashrc", 1, true) then found = true end
      end
      t.true_(found, "应记录 read_file 的越界路径")
    end)
  end)

  it("越界访问留痕：按文件合并/排序，去重文件计数", function(t)
    local trace = require("NeoAI.sandbox.observe.trace")
    trace.reset()
    trace.record({ tool = "list_files", path = "/root/z.txt" })
    trace.record({ tool = "read_file", path = "/root/a.txt" })
    trace.record({ tool = "list_files", path = "/root/a.txt" })
    trace.record({ tool = "read_file", path = "/root/a.txt" })
    local grouped = trace.list_grouped()
    t.eq(2, #grouped, "应按路径去重为 2 个文件")
    t.eq("/root/a.txt", grouped[1].path, "应按路径升序（a 在前）")
    t.eq("/root/z.txt", grouped[2].path)
    t.eq(2, grouped[1].count, "同路径记录应合并（record 按 tool+path 去重）")
    t.deep_eq({ "read_file", "list_files" }, grouped[1].tools, "工具名应去重合并（首现顺序）")
    t.eq(2, trace.file_count(), "file_count 应为去重文件数")
    trace.reset()
  end)

  it("越界访问留痕：同 (tool,path) 的不同命令累积（去重有界）", function(t)
    local trace = require("NeoAI.sandbox.observe.trace")
    trace.reset()
    trace.record({ tool = "run_command", path = "/root/a.txt", command = "cat /root/a.txt" })
    trace.record({ tool = "run_command", path = "/root/a.txt", command = "grep token /root/a.txt" })
    -- 重复命令只累积一次
    trace.record({ tool = "run_command", path = "/root/a.txt", command = "cat /root/a.txt" })
    t.eq(1, trace.count(), "同 (tool,path) 仍只有一条留痕")
    t.eq(1, trace.file_count(), "去重文件数不变")
    local g = trace.list_grouped()[1]
    t.deep_eq({ "cat /root/a.txt", "grep token /root/a.txt" }, g.commands, "应累积不同命令（去重有序）")
    -- 无命令的文件类访问不产生命令
    trace.record({ tool = "read_file", path = "/root/b.txt" })
    local gb = trace.list_grouped()[2]
    t.deep_eq({}, gb.commands, "无命令访问的 commands 为空")
    trace.reset()
  end)

  it("越界访问留痕：按命令聚合（命令 → 涉及文件）", function(t)
    local trace = require("NeoAI.sandbox.observe.trace")
    trace.reset()
    trace.record({ tool = "run_command", path = "/root/a.txt", command = "cat /root/a.txt" })
    trace.record({ tool = "run_command", path = "/root/b.txt", command = "cat /root/a.txt" })
    trace.record({ tool = "run_command", path = "/root/a.txt", command = "grep x /root/a.txt" })
    trace.record({ tool = "read_file", path = "/root/c.txt" })
    local by = trace.list_grouped_by_command()
    -- 有命令者按命令升序在前（cat… < grep…），无命令哨兵组置末。
    t.eq("cat /root/a.txt", by[1].command, "命令应升序（cat 在前）")
    t.deep_eq({ "/root/a.txt", "/root/b.txt" }, by[1].files, "同一命令应合并文件（去重有序）")
    t.eq("grep x /root/a.txt", by[2].command)
    t.eq(nil, by[3].command, "无命令访问归入哨兵组（command=nil）")
    t.deep_eq({ "/root/c.txt" }, by[3].files, "哨兵组应含无命令访问的文件")
    trace.reset()
  end)

  it("保存/撤销保存：撤销回滚原文件并回到待审，冲突时拒绝", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "auto_allow" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local p = vim.fn.tempname() .. "_undo.txt"
      fs.write_file(p, "base\n")
      local id, done = nil, false
      require("NeoAI.tools").execute("edit_file", {
        file_path = p, mode = "write", content = "next\n", description = "t",
      }, {}):then_(function()
        local items = sandbox.list_reviews({ review_state = "PENDING" })
        t.eq(1, #items, "应有一个待审单元")
        id = items[1].change_set_id
        local res = sandbox.apply(id, { auto_approve = true })
        t.true_(res.ok, tostring(res.reason))
        t.eq("next", trim(fs.read_file(p)), "应用后应为新内容")
        local saved = sandbox.list_saved()
        t.eq(1, #saved, "应有 1 个已保存项")
        t.eq("APPLIED", saved[1].apply_state, "应为已保存状态")
        t.eq(p, saved[1].saved_files and saved[1].saved_files[1] and saved[1].saved_files[1].path,
          "快照应附带文件清单")

        -- 撤销保存：真实文件回滚 → 恢复原内容，条目回到待审队列（不再保留「已撤销」态）
        local u = sandbox.undo(id)
        t.true_(u.ok, tostring(u.reason))
        t.eq("PENDING", u.state, "撤销后应回到待审")
        t.eq("base", trim(fs.read_file(p)), "撤销后应恢复原内容")
        t.eq(0, #sandbox.list_saved(), "撤销后不应再出现在已应用区")
        local pend = sandbox.list_reviews({ review_state = "PENDING" })
        t.eq(1, #pend, "撤销后应重新出现在待审区")
        t.eq(id, pend[1].change_set_id, "应保留原变更单元 id")
        t.not_nil(sandbox.show(pend[1].candidate_digest), "撤销后候选应可重新读取")

        -- 重新应用：写回新内容并再次进入已应用区
        local r = sandbox.apply(id, { auto_approve = true })
        t.true_(r.ok, tostring(r.reason))
        t.eq("next", trim(fs.read_file(p)), "重新应用应为新内容")
        t.eq(1, #sandbox.list_saved(), "重新应用后应回到已应用区")

        -- 外部改动后撤销应冲突（拒绝覆盖用户改动）
        fs.write_file(p, "external\n")
        local c = sandbox.undo(id)
        t.false_(c.ok, "外部改动后撤销应失败")
        t.eq("CONFLICT", c.state, "应为 CONFLICT")
        t.eq("external", trim(fs.read_file(p)), "冲突时不应覆盖用户改动")
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(5000, function() return done end), "应完成")
      fs.delete_file(p)
    end)
  end)

  it("临时根（ephemeral_roots）：/tmp 写入不产生待审候选、不落真实盘、读取一致", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "auto_allow" }, sandbox = {
      mode = "dry_run", review = { enabled = true }, ephemeral_roots = { "/tmp" },
    } } }, function()
      sandbox.reset()
      local p = vim.fn.tempname() .. "_eph.txt"
      pcall(fs.delete_file, p)
      local done = false
      require("NeoAI.tools").execute("edit_file",
        { file_path = p, description = "t", mode = "write", content = "eph\n" }, {}):then_(function()
          t.false_(fs.exists(p), "临时根写入不应落到真实磁盘")
          t.eq(0, #sandbox.list_reviews({ review_state = "PENDING" }), "临时根不应产生待审候选")
          done = true
        end, function(e) t.true_(false, tostring(e and e.message or e)); done = true end)
      t.true_(vim.wait(8000, function() return done end), "edit_file 应完成")
      local done2, out = false, nil
      require("NeoAI.tools").execute("read_file", { file_path = p, description = "r" }, {})
        :then_(function(r) out = tostring(r); done2 = true end, function() done2 = true end)
      t.true_(vim.wait(8000, function() return done2 end), "read_file 应完成")
      t.matches("eph", out or "", "读取应看到临时根内容（暂存一致）")
    end)
  end)

  it("工具子进程：写入经 overlay 暂存为候选（不直接落盘）", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local sandbox = require("NeoAI.sandbox")
    local exec = require("NeoAI.sandbox.execution.exec")
    with_config({ tools = { sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      -- 暂存根必须可被捕获：不能位于 `<cache>/NeoAI`（自身运行时，捕获阶段整棵排除）。
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      local real_file = dir .. "/out.txt"
      pcall(os.remove, real_file)
      local done, result = false, nil
      exec.run({ "bash", "-c", "echo STAGED > " .. real_file }, {
        name = "probe", writable_roots = { dir }, network = false, timeout_ms = 20000,
      }):then_(function(res) result = res; done = true end, function() done = true end)
      t.true_(vim.wait(20000, function() return done end, 20), "子进程应完成")
      t.true_(result and result.code == 0, "命令应成功")
      t.eq(0, vim.fn.filereadable(real_file), "真实文件不应落盘（已暂存）")
      local staged = require("NeoAI.sandbox.execution.candidate").read_path(real_file)
      t.not_nil(staged, "应存在暂存副本")
      local f = staged and io.open(staged)
      local content = f and f:read("*a") or ""
      if f then f:close() end
      t.matches("STAGED", content, "暂存副本应含写入内容")
      t.true_(sandbox.pending_count() >= 1, "应进入待审队列")
      pcall(vim.fn.delete, dir, "rf")
    end)
  end)

  it("工具子进程：沙箱禁用且 fail_closed 时拒绝", function(t)
    local exec = require("NeoAI.sandbox.execution.exec")
    with_config({ tools = { sandbox = { enabled = false, fail_closed = true } } }, function()
      local full, finish, err = exec.open({ "true" }, { network = true })
      t.eq(nil, full, "应拒绝执行")
      t.eq(nil, finish, "不应返回结束回调")
      t.not_nil(err, "应给出拒绝原因")
    end)
  end)

  it("工具子进程：无 overlay 时降级放行（与 run_command 一致）", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local sandbox = require("NeoAI.sandbox")
    local exec = require("NeoAI.sandbox.execution.exec")
    local saved_avail, saved_writable = runtime.overlay_available, runtime.overlay_writable
    runtime.overlay_available = function() return false end
    runtime.overlay_writable = function() return false end
    local ok, err = pcall(function()
      with_config({ tools = { sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
        sandbox.reset()
        local full, finish, werr = exec.open({ "true" }, { network = true })
        t.not_nil(full, "无 overlay 应降级放行工具子进程: " .. tostring(werr))
        t.not_nil(finish, "放行时应返回结束回调")
      end)
    end)
    runtime.overlay_available, runtime.overlay_writable = saved_avail, saved_writable
    sandbox.reset()
    if not ok then error(err, 0) end
  end)

end)
