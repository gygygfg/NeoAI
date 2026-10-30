--- 沙箱挂载点规范化与单点失败隔离
--- @module 'NeoAI.tests.test_sandbox_mounts'
--- 覆盖：父目录符号链接折算（`/var/run -> /run`）、源缺失绑定剔除、重复挂载去重、
--- 安全关键挂载硬失败、bwrap init 失败自愈（prune_mount + 错误文案解析）。
--- 历史缺陷：默认遮蔽表同时列 `/run/docker.sock` 与 `/var/run/docker.sock`；旧版 bubblewrap
--- 对「父目录为符号链接」的挂载点创建失败（`Can't create file ...: No such file or directory`），
--- 单条挂载失败导致**每条外部命令**的 bwrap init 失败（进程内工具不受影响）。

local tests = require("NeoAI.tests")

tests.suite("sandbox_mounts", function(_, it)
  local runtime = require("NeoAI.sandbox.execution.runtime")

  it("挂载目的路径：父目录符号链接被折算为真实路径", function(t)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/real", "p")
    local ok = vim.fn.system({ "ln", "-sfn", dir .. "/real", dir .. "/link" }) == ""
    if not ok then
      vim.fn.delete(dir, "rf")
      return
    end
    t.eq(dir .. "/real/file", runtime.mount_dst(dir .. "/link/file"),
      "父目录为符号链接时应折算为真实路径（末段保留）")
    t.eq(dir .. "/real/file", runtime.mount_dst(dir .. "/link/file/"),
      "尾斜杠应被规范化")
    -- 末段本身是符号链接时**不得**默认解析：`/bin -> usr/bin`，折算成 `/usr/bin` 会让命名空间里
    -- 没有 `/bin` 这个符号链接（bwrap 在 `/usr/bin` 建挂载点），`/bin/sh` 直接 ENOENT。
    t.eq("/bin", runtime.mount_dst("/bin"), "末段符号链接应保留")
    t.eq("/lib64", runtime.mount_dst("/lib64"), "末段符号链接应保留")
    -- 整机根视图（resolve_leaf=true）下命名空间镜像宿主符号链接；bwrap >= 0.12 拒绝挂载到
    -- 符号链接目的路径，故末段必须折算。
    t.eq("/usr/bin", runtime.mount_dst("/bin", true), "整机根视图应展开末段符号链接")
    t.eq(dir .. "/real/file", runtime.mount_dst(dir .. "/link/file", true))
    vim.fn.delete(dir, "rf")
  end)

  it("前缀：不出现经符号链接父目录的挂载目的路径", function(t)
    if runtime.backend() ~= "bwrap" then return end
    -- 仅当宿主 /var/run 确实是符号链接时才有可验证性（Ubuntu/Debian 常见）。
    if vim.fn.resolve("/var/run") == "/var/run" then return end
    local prefix = runtime.process_prefix({ cwd = "/tmp" })
    t.not_nil(prefix, "应能构造前缀")
    for _, v in ipairs(prefix) do
      t.true_(v ~= "/var/run/docker.sock", "不应把未规范化的 /var/run/docker.sock 交给 bwrap")
      t.true_(v ~= "/var/run/containerd", "不应把未规范化的 /var/run/containerd 交给 bwrap")
    end
  end)

  it("挂载收尾：源缺失的绑定被剔除、重复挂载去重、保留项不受影响", function(t)
    -- 源 /nope/missing 不存在 → bwrap 会 `Can't find source path` 让整条命令失败 → 剔除。
    local argv = {
      "bwrap",
      "--ro-bind", "/", "/",
      "--bind", "/nope/missing", "/run/x",
      "--tmpfs", "/run/y",
      "--dir", "/run/z",
      -- 相同选项 + 相同目的路径：后者覆盖前者，剔除前一条（视图等价）。
      "--ro-bind", "/etc", "/opt/same",
      "--ro-bind", "/usr", "/opt/same",
    }
    local out, skips, err = runtime._finalize_mounts(argv)
    t.not_nil(out, "收尾不应失败: " .. tostring(err))
    t.eq(1, #skips, "应剔除 1 条源缺失的绑定")
    t.eq("/nope/missing", skips[1].path)
    local joined = table.concat(out, "\n")
    t.true_(joined:find("/nope/missing", 1, true) == nil, "源缺失的绑定应被移除")
    t.true_(joined:find("--tmpfs\n/run/y", 1, true) ~= nil, "tmpfs 挂载应保留")
    t.true_(joined:find("--dir\n/run/z", 1, true) ~= nil, "--dir 挂载点应保留")
    -- /opt/same 只应出现一次，且保留后一条（/usr）。
    local count = 0
    for i, v in ipairs(out) do
      if v == "/opt/same" then
        count = count + 1
        t.eq("/usr", out[i - 1], "应保留后一条（/usr 覆盖 /etc）")
      end
    end
    t.eq(1, count, "重复目的路径应只保留一条")
  end)

  it("挂载收尾：安全关键 overlay 的 upper/work 缺失 → 硬失败", function(t)
    local argv = {
      "bwrap", "--overlay-src", "/",
      "--overlay", "/nope/upper", "/nope/work", "/",
    }
    local out, _, err = runtime._finalize_mounts(argv)
    t.nil_(out, "overlay 缺失不应被静默剔除")
    t.matches("SANDBOX_MOUNT_FAILED", tostring(err), "应返回明确错误码")
  end)

  it("错误解析：兼容各版本 bwrap 挂载失败文案", function(t)
    local cases = {
      { "bwrap: Can't create file at /var/run/docker.sock: No such file or directory", "dest", "/var/run/docker.sock" },
      { "bwrap: Can't create file /tmp/a: Read-only file system", "dest", "/tmp/a" },
      { "bwrap: Can't mkdir /var/run/podman: No such file or directory", "dest", "/var/run/podman" },
      { "bwrap: Can't mkdir parents for /x/y: Read-only file system", "dest", "/x/y" },
      { "bwrap: Can't make symlink at /x/l: File exists", "dest", "/x/l" },
      { "bwrap: Can't mount on symlink destination /etc/resolv.conf", "symlink", "/etc/resolv.conf" },
      { "bwrap: Can't bind mount /nope on /tmp/x: No such file or directory", "dest", "/tmp/x" },
      { "bwrap: Can't find source path /nope: No such file or directory", "src", "/nope" },
    }
    for _, c in ipairs(cases) do
      local info = runtime.mount_failure_info(c[1])
      t.not_nil(info, "应解析: " .. c[1])
      t.eq(c[2], info.kind, "kind 不符: " .. c[1])
      t.eq(c[3], info.path, "path 不符: " .. c[1])
    end
    t.nil_(runtime.mount_failure_info("bash: line 1: foo: command not found"), "非挂载错误不应被识别")
    t.nil_(runtime.mount_failure_info(nil), "nil 应安全返回")
  end)

  it("自愈剔除：仅移除失败目的路径对应的挂载（目标已不存在）", function(t)
    if runtime.backend() ~= "bwrap" then return end
    local prefix = runtime.process_prefix({ cwd = "/tmp" })
    t.not_nil(prefix, "应能构造前缀")
    -- 造一个「宿主上不存在」的挂载目的路径（等价于 TOCTOU 消失）。
    local dest = vim.fn.tempname() .. "/gone"
    local argv = {}
    for _, v in ipairs(prefix) do argv[#argv + 1] = v end
    -- 插入到 `--`（载荷分隔符）之前，确保会被挂载扫描器看到。
    local pos = #argv + 1
    for i, v in ipairs(argv) do
      if v == "--" then pos = i break end
    end
    table.insert(argv, pos, dest)
    table.insert(argv, pos, "--tmpfs")
    t.nil_(vim.uv.fs_stat(dest), "测试目标应不存在")
    local pruned, removed = runtime.prune_mount(argv, { kind = "dest", path = dest })
    t.not_nil(pruned, "目标不存在时应允许自愈剔除")
    t.eq(1, #removed, "应移除 1 条挂载")
    t.eq(#argv - 2, #pruned, "只应移除 --tmpfs 及其参数")
    local joined = table.concat(pruned, "\n")
    t.true_(joined:find(dest, 1, true) == nil, "目标挂载应被移除")
  end)

  it("自愈护栏：目标仍存在时拒绝剔除（避免解除遮蔽）", function(t)
    if runtime.backend() ~= "bwrap" then return end
    local prefix = runtime.process_prefix({ cwd = "/tmp" })
    t.not_nil(prefix, "应能构造前缀")
    -- 找一个真实存在的文件遮蔽（--bind /dev/null <dest>）。
    local dest
    for i, v in ipairs(prefix) do
      if v == "--bind" and prefix[i + 1] == "/dev/null" and prefix[i + 2] then
        dest = prefix[i + 2]
        break
      end
    end
    if not dest or not vim.uv.fs_stat(dest) then return end
    local pruned = runtime.prune_mount(prefix, { kind = "dest", path = dest })
    t.nil_(pruned, "目标仍存在时不得自愈剔除（会解除遮蔽）")
  end)

  it("收尾后可正常初始化：真实 bwrap 前缀执行命令成功", function(t)
    if runtime.backend() ~= "bwrap" then return end
    local prefix = runtime.process_prefix({ cwd = "/tmp" })
    t.not_nil(prefix, "应能构造前缀")
    local cmd = {}
    for _, v in ipairs(prefix) do cmd[#cmd + 1] = v end
    for _, v in ipairs({ "/bin/sh", "-c", "echo MOUNT_OK" }) do cmd[#cmd + 1] = v end
    local out = vim.fn.system(cmd)
    t.eq(0, vim.v.shell_error, "前缀应能正常 init 并执行，实际输出: " .. tostring(out))
    t.matches("MOUNT_OK", tostring(out))
  end)

  it("bwrap >= 0.12：符号链接目的路径经收尾折算后可正常 init", function(t)
    if runtime.backend() ~= "bwrap" then return end
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local target = dir .. "/target"
    local f = assert(io.open(target, "w"))
    f:write("x\n")
    f:close()
    local link = dir .. "/link"
    vim.fn.system({ "ln", "-sfn", target, link })
    local argv = {
      "bwrap", "--dev-bind", "/", "/", "--ro-bind", "/etc/hostname", link,
      "/bin/sh", "-c", "echo SYMLINK_OK",
    }
    local out, _, err = runtime._finalize_mounts(argv, { resolve_leaf = true })
    t.not_nil(out, "收尾不应失败: " .. tostring(err))
    local joined = table.concat(out, " ")
    t.true_(joined:find(link, 1, true) == nil, "符号链接目的路径应被折算为真实路径")
    t.true_(joined:find(target, 1, true) ~= nil, "应挂载到真实路径")
    local run = vim.fn.system(out)
    t.eq(0, vim.v.shell_error, "折算后前缀应能 init，实际输出: " .. tostring(run))
    t.matches("SYMLINK_OK", tostring(run))
    vim.fn.delete(dir, "rf")
  end)

  it("自愈：符号链接目的路径错误 → 改写为真实路径（不剔除）", function(t)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local target = dir .. "/target"
    local f = assert(io.open(target, "w"))
    f:write("x\n")
    f:close()
    local link = dir .. "/link"
    vim.fn.system({ "ln", "-sfn", target, link })
    local argv = {
      "bwrap", "--dev-bind", "/", "/", "--ro-bind", "/etc/hostname", link,
      "/bin/sh", "-c", "true",
    }
    local healed, actions = runtime.heal_mount(argv, { kind = "symlink", path = link })
    t.not_nil(healed, "应修复符号链接目的路径")
    t.eq(1, #actions, "应记录 1 条修复")
    t.eq(target, actions[1].resolved)
    local joined = table.concat(healed, " ")
    t.true_(joined:find(link, 1, true) == nil, "不应再出现符号链接目的路径")
    t.true_(joined:find(target, 1, true) ~= nil, "应改写为真实路径")
    vim.fn.delete(dir, "rf")
  end)

  it("resolv.conf 为符号链接：真实路径挂载位于 /run/systemd 遮蔽之后", function(t)
    if runtime.backend() ~= "bwrap" then return end
    local lst = vim.uv.fs_lstat("/etc/resolv.conf")
    if not (lst and lst.type == "link") then return end
    local prefix = assert(runtime.process_prefix({ cwd = "/tmp" }))
    local idx_mask, idx_bind = nil, nil
    for i, v in ipairs(prefix) do
      if v == "--tmpfs" and prefix[i + 1] == "/run/systemd" then idx_mask = i end
      if v == "--ro-bind" and type(prefix[i + 2]) == "string"
        and prefix[i + 2] ~= "/etc/resolv.conf" and prefix[i + 2]:find("resolv", 1, true)
      then
        idx_bind = i
      end
    end
    t.not_nil(idx_bind, "应在真实路径补挂 resolv.conf（避免符号链接目的路径）")
    if idx_mask then
      t.true_(idx_bind > idx_mask, "补挂必须在 /run/systemd 遮蔽之后，否则会被遮掉")
    end
  end)

  it("遮蔽后补挂：符号链接目标落在被遮蔽目录内仍可见（resolv.conf 场景）", function(t)
    if runtime.backend() ~= "bwrap" then return end
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/etc", "p")
    vim.fn.mkdir(dir .. "/run/systemd", "p")
    local sym = dir .. "/etc/resolv.conf"
    local target = dir .. "/run/systemd/resolv.conf"
    vim.fn.system({ "ln", "-sfn", target, sym })
    local src = dir .. "/sanitized"
    local f = assert(io.open(src, "w"))
    f:write("nameserver 127.0.0.1\n")
    f:close()
    -- 模拟 systemd-resolved：/etc/resolv.conf -> /run/systemd/resolv.conf，而 /run/systemd
    -- 稍后被整体遮蔽。早挂（符号链接路径折算到真实路径）会被遮蔽；必须在遮蔽之后再挂一次。
    local argv = {
      "bwrap", "--dev-bind", "/", "/",
      "--ro-bind", src, sym,
      "--tmpfs", dir .. "/run/systemd",
      "--ro-bind", src, target,
      "/bin/sh", "-c", "cat " .. sym,
    }
    local out, _, err = runtime._finalize_mounts(argv, { resolve_leaf = true })
    t.not_nil(out, "收尾不应失败: " .. tostring(err))
    local res = vim.fn.system(out)
    t.eq(0, vim.v.shell_error, "应能 init 并读取: " .. tostring(res))
    t.matches("nameserver 127.0.0.1", tostring(res), "遮蔽后补挂应生效，实际: " .. tostring(res))
    vim.fn.delete(dir, "rf")
  end)
end)
