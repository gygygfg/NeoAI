--- 沙箱依赖诊断与用户话术测试
--- @module 'NeoAI.tests.test_sandbox_deps'
--- 纯函数覆盖（离线可复现）：平台/包管理器探测与测试钩子、安装提示、后端能力报告
--- （bwrap / unshare / 无后端三支，docker 不计入隔离后端）、降级原因话术
--- （内部码翻人话并保留原码）。

local tests = require("NeoAI.tests")

tests.suite("sandbox_deps", function(_, it)
  local deps = require("NeoAI.sandbox.execution.deps")

  --- 在指定平台/包管理器下执行，结束后复位测试钩子（避免污染后续套件）。
  --- @param platform string|nil
  --- @param pm string|nil
  --- @param fn function
  local function with_env(platform, pm, fn)
    deps.set_platform_override(platform)
    deps.set_pkg_manager_override(pm)
    local ok, err = pcall(fn)
    deps.reset()
    if not ok then error(err, 0) end
  end

  it("平台探测：override 生效，reset 后恢复实测", function(t)
    deps.reset()
    deps.set_platform_override("termux")
    t.eq("termux", deps.platform())
    t.true_(deps.is_mobile(), "Termux 应视为移动平台")
    deps.set_platform_override("linux")
    t.false_(deps.is_mobile(), "桌面 Linux 不应视为移动平台")
    deps.reset()
    local p = deps.platform()
    t.true_(type(p) == "string" and p ~= "", "复位后应返回实测平台名")
  end)

  it("安装提示：按包管理器给出命令，Termux 说明装包也无法启用隔离", function(t)
    with_env("linux", "apt", function()
      local hint = deps.install_hint("bwrap")
      t.matches("bubblewrap", hint, "应给出包名 bubblewrap")
      t.matches("apt", hint, "应给出 apt 命令")
    end)
    with_env("termux", "pkg", function()
      local hint = deps.install_hint("bwrap")
      t.matches("bubblewrap", hint)
      t.matches("user namespace", hint, "Termux 应说明内核禁止非特权 userns")
    end)
    with_env("linux", "pacman", function()
      local hint = deps.install_hint("setpriv")
      t.matches("util%-linux", hint, "setpriv 属 util-linux 包")
      t.matches("pacman", hint)
    end)
  end)

  it("后端报告：bwrap 可用时报 ok 并列出 overlay/seccomp/cgroup 能力", function(t)
    local r = deps.backend_report({
      backend = "bwrap", bwrap = true, userns = true,
      overlayfs = true, seccomp = true, cgroup2 = true,
    })
    t.eq("ok", r.status)
    local text = table.concat(r.lines, "\n")
    t.matches("bwrap", text)
    t.matches("overlay", text)
    t.matches("seccomp", text)
    t.matches("cgroup v2", text)
  end)

  it("后端报告：unshare 可用但缺 setpriv 时点名 util-linux ≥ 2.32", function(t)
    with_env("linux", "apt", function()
      local r = deps.backend_report({
        backend = "unshare", unshare = true, userns = true, seccomp = true, setpriv = false,
      })
      t.eq("ok", r.status)
      local text = table.concat(r.lines, "\n")
      t.matches("unshare", text)
      t.matches("setpriv", text)
      t.matches("util%-linux", text, "应点名 util-linux 包")
      t.matches("三[层]", text, "应说明按三层行为模型降级")
    end)
  end)

  it("后端报告：无后端时逐项点名缺 bwrap / userns 被拒，docker 不计入隔离后端", function(t)
    with_env("linux", "apt", function()
      local r = deps.backend_report({
        backend = nil, bwrap = false, unshare = true, userns = false, docker = true,
      })
      t.eq("warn", r.status, "无隔离后端应为 warn")
      local text = table.concat(r.lines, "\n")
      t.matches("bubblewrap", text, "应点名 bubblewrap 包")
      t.matches("user namespace", text, "应说明非特权 userns 被内核拒绝")
      t.matches("退回审批", text, "应说明退回审批模式")
      t.matches("docker", text, "存在 docker 时应说明它不参与隔离后端")
      t.matches("podman", text, "应说明容器门面仅 podman")
    end)
  end)

  it("后端报告：Termux/Android 追加平台不支持说明", function(t)
    with_env("termux", "pkg", function()
      local r = deps.backend_report({ backend = nil, bwrap = false, unshare = false, userns = false })
      t.eq("warn", r.status)
      local text = table.concat(r.lines, "\n")
      t.matches("Termux", text, "应点明 Android/Termux 平台原因")
      t.matches("util%-linux", text, "缺 unshare 时应点名 util-linux")
      t.matches("审批", text)
    end)
  end)

  it("降级话术：seccomp 缺 setpriv 时翻成人话并保留原码", function(t)
    with_env("linux", "apt", function()
      local text = deps.degrade_text("seccomp", "unshare", "setpriv_unavailable", "ebpf")
      t.matches("setpriv", text)
      t.matches("util%-linux", text)
      t.matches("setpriv_unavailable", text, "应保留内部原码便于对账")
      t.matches("eBPF", text, "fallback=ebpf 应说明行为兜底")
    end)
  end)

  it("降级话术：filter_unavailable / privilege / sysctl_mask / backend 分支", function(t)
    with_env("linux", "apt", function()
      local f = deps.degrade_text("seccomp", "bwrap", "filter_unavailable", nil)
      t.matches("filter_unavailable", f)
      t.matches("无行为强制层", f, "无 eBPF 兜底时应说明落到第 3 层")

      local p = deps.degrade_text("privilege", "unshare", "tier_mounts", nil)
      t.matches("tier_mounts", p)
      t.matches("bwrap", p, "应指出档位挂载只有 bwrap 支持")

      local s = deps.degrade_text("sysctl_mask", "unshare", "proc_sys_unmaskable", nil)
      t.matches("proc_sys_unmaskable", s)
      t.matches("/proc/sys", s)

      local b = deps.degrade_text("backend", "none", "no_backend", "approval")
      t.matches("no_backend", b)
      t.matches("审批", b)
    end)
  end)

  it("后端报告：overlay 不可用且 bwrap 版本过旧 → 指明升级 0.11+，无需 docker/podman", function(t)
    with_env("linux", "apt", function()
      local r = deps.backend_report({
        backend = "bwrap", bwrap = true, unshare = true, userns = true,
        overlayfs = false, seccomp = true, cgroup2 = true, bwrap_version = "0.9.0",
      })
      t.eq("ok", r.status)
      local text = table.concat(r.lines, "\n")
      t.matches("0%.9%.0", text, "应显示 bwrap 版本")
      t.matches("0%.11", text, "应提示 overlay 需要 bubblewrap >= 0.11.0")
      t.matches("Docker", text, "应说明无需 Docker/Podman")
    end)
  end)

  it("降级话术：未知层附上 layer/reason 便于对账，不丢信息", function(t)
    local text = deps.degrade_text("mystery_layer", "mode_x", "some_reason", "some_fallback")
    t.matches("mystery_layer", text)
    t.matches("some_reason", text)
    t.matches("some_fallback", text)
  end)
end)
