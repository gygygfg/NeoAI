--- 动态 exec 调用链守卫测试
--- @module 'NeoAI.tests.test_sandbox_exec_guard'
--- 覆盖：
--- 1. 链构建：按真实 execve 事件还原 pid → ppid 调用链（根在前）；
--- 2. 能力归类：按危险 syscall 归入能力类别，而非按二进制名字；
--- 3. 归因：命中时定位到具体 pid + canonical path + 链，写入可持久化的 evidence 结构；
--- 4. 环形上限：长跑命令不会无限增长；
--- 5. 后端缺失降级：无 eBPF/procfs 时 `source_available()` 如实返回 false（不假装有边界）；
--- 6. 关闭开关后不消费事件。
---
--- 存在意义：字符静态判定（命令名黑名单、`curl | sh` 正则）实测双向失效，唯一可靠的判定
--- 依据是进程实际 exec 了哪个可执行文件；本守卫即该动态侧，且必须诚实标注「观测 + 补救」。

local tests = require("NeoAI.tests")

local function cfg(overrides, fn)
  local config_store = require("NeoAI.kernel.config_store")
  local saved = config_store.get_all()
  local merged = vim.deepcopy(saved)
  merged.tools = merged.tools or {}
  merged.tools.sandbox = merged.tools.sandbox or {}
  merged.tools.sandbox.observe = merged.tools.sandbox.observe or {}
  for k, v in pairs(overrides or {}) do
    merged.tools.sandbox.observe[k] = v
  end
  config_store.load(merged)
  local ok, err = pcall(fn)
  config_store.load(saved)
  if not ok then error(err, 0) end
end

tests.suite("sandbox_exec_guard", function(_, it)
  it("链构建：按 pid → ppid 还原调用链（根在前）", function(t)
    local guard = require("NeoAI.sandbox.observe.exec_guard")
    guard.reset()
    -- 模拟 sh → curl → bash 的真实 exec 序列（ppid 显式给出，绕过 /proc 依赖）
    guard.observe({ kind = "exec", op = "execve", pid = 100, ppid = 1, path = "/bin/sh" }, "k1")
    guard.observe({ kind = "exec", op = "execve", pid = 101, ppid = 100, path = "/usr/bin/curl" }, "k1")
    guard.observe({ kind = "exec", op = "execve", pid = 102, ppid = 101, path = "/bin/bash" }, "k1")
    local chain = guard.chain("k1", 102)
    t.eq(3, #chain, "应还原三级调用链")
    t.eq("/bin/sh", chain[1].path, "根节点为 sh")
    t.eq("/usr/bin/curl", chain[2].path, "中间节点为 curl")
    t.eq("/bin/bash", chain[3].path, "叶子为 bash")
    -- 无 pid 时按事件顺序返回
    t.eq(3, #guard.chain("k1", nil), "无 pid 时应返回全部节点")
    guard.reset()
  end)

  it("能力归类：按危险 syscall 归类，不按二进制名字", function(t)
    local guard = require("NeoAI.sandbox.observe.exec_guard")
    t.eq("module", guard.class_of("init_module"), "init_module → module")
    t.eq("module", guard.class_of("finit_module"), "finit_module → module")
    t.eq("bpf", guard.class_of("bpf"), "bpf → bpf")
    t.eq("bpf", guard.class_of("perf_event_open"), "perf_event_open → bpf")
    t.eq("clock", guard.class_of("clock_settime"), "clock_settime → clock")
    t.eq("reboot", guard.class_of("reboot"), "reboot → reboot")
    t.eq("mount", guard.class_of("mount"), "mount → mount")
    t.eq("swap", guard.class_of("swapon"), "swapon → swap")
    t.eq("rawio", guard.class_of("iopl"), "iopl → rawio")
    t.eq(nil, guard.class_of("openat"), "无害 syscall 无能力类别")
    t.eq(nil, guard.class_of(nil), "nil syscall 安全返回")
  end)

  it("归因：定位到具体 pid 与 canonical path，并给出可持久化 evidence", function(t)
    local guard = require("NeoAI.sandbox.observe.exec_guard")
    guard.reset()
    guard.observe({ kind = "exec", op = "execve", pid = 200, ppid = 1, path = "/bin/sh" }, "k2")
    -- busybox 多调用：文本层看到的是 `iptables`，execve 链上看到的是真实路径
    guard.observe({ kind = "exec", op = "execve", pid = 201, ppid = 200, path = "/usr/bin/busybox" }, "k2")
    local v = guard.violation("k2", "bpf", 201)
    t.eq(201, v.pid, "应归因到触发 pid")
    t.eq("bpf", v.class, "应带能力类别")
    t.eq("bpf", v.syscall, "应带命中 syscall")
    t.not_nil(v.path, "应给出可执行路径")
    t.eq(2, #v.chain, "应带完整调用链")
    local ev = guard.chain_evidence(v.chain)
    t.eq(2, #ev, "evidence 链长度与链一致")
    t.eq(201, ev[2].pid, "evidence 保留 pid")
    t.eq("bpf", ev[2].class, "evidence 保留能力类别")
    t.not_nil(guard.describe(v), "应可压成一行文案")
    guard.reset()
  end)

  it("归因：事件缺失时退化为链上最近节点（不报错、不崩）", function(t)
    local guard = require("NeoAI.sandbox.observe.exec_guard")
    guard.reset()
    guard.observe({ kind = "exec", op = "execve", pid = 300, ppid = 1, path = "/bin/sh" }, "k3")
    local v = guard.violation("k3", "init_module", 999) -- 999 从未 exec 过
    t.not_nil(v, "应返回归因结果")
    t.eq("module", v.class, "能力类别来自 syscall")
    t.eq(300, v.pid, "退化为链上最近节点")
    guard.reset()
  end)

  it("环形上限：链节点数不超过 max_chain", function(t)
    cfg({ exec_guard = { enabled = true, max_chain = 4 } }, function()
      local guard = require("NeoAI.sandbox.observe.exec_guard")
      guard.reset()
      for i = 1, 20 do
        guard.observe({ kind = "exec", op = "execve", pid = 1000 + i, ppid = 1, path = "/bin/x" .. i }, "k4")
      end
      t.eq(4, #guard.chain("k4", nil), "应只保留最近 max_chain 个节点")
      guard.reset()
    end)
  end)

  it("非 exec 事件被忽略（文件/网络事件仍由既有消费方处理）", function(t)
    local guard = require("NeoAI.sandbox.observe.exec_guard")
    guard.reset()
    t.eq(nil, guard.observe({ kind = "file", op = "openat", pid = 1, path = "/etc/passwd" }, "k5"),
      "文件事件不应进入调用链")
    t.eq(nil, guard.observe({ kind = "net", op = "connect", pid = 1, host = "127.0.0.1" }, "k5"),
      "网络事件不应进入调用链")
    t.eq(0, #guard.chain("k5", nil), "链应为空")
    guard.reset()
  end)

  it("关闭开关后不消费事件", function(t)
    cfg({ exec_guard = { enabled = false } }, function()
      local guard = require("NeoAI.sandbox.observe.exec_guard")
      guard.reset()
      t.eq(false, guard.enabled(), "应识别为关闭")
      t.eq(nil, guard.observe({ kind = "exec", op = "execve", pid = 400, path = "/bin/sh" }, "k6"),
        "关闭时不应消费")
      t.eq(0, #guard.chain("k6", nil), "链应为空")
      guard.reset()
    end)
  end)

  it("后端缺失降级：source_available 如实报告，不假装有边界", function(t)
    local guard = require("NeoAI.sandbox.observe.exec_guard")
    local ok, backend = guard.source_available()
    t.eq("boolean", type(ok), "应返回布尔可用性")
    t.eq("string", type(backend), "应返回后端名/原因")
    -- 本机（无 bpftrace、cgroup 不可写）通常为 false；有 eBPF/procfs 时为 true。
    -- 两者都合法，关键是**不抛错且如实**：不可用时必须能被调用方感知为「无动态强制层」。
    local observer = require("NeoAI.sandbox.observe.observer")
    local real = observer.backend()
    if real == "ebpf" or real == "procfs" then
      t.eq(true, ok, "ebpf/procfs 后端下应可用")
    else
      t.eq(false, ok, "无 exec 事件来源时应如实报不可用（实际后端: " .. tostring(real) .. "）")
    end
  end)

  it("exec 事件从 observer 解析到 guard 全链贯通（eBPF X 帧格式）", function(t)
    local observer = require("NeoAI.sandbox.observe.observer")
    local guard = require("NeoAI.sandbox.observe.exec_guard")
    -- X 帧：X\texecve\t<pid>\t<filename>
    local evt = observer.parse_bpftrace_line("X\texecve\t1234\t/usr/bin/busybox")
    t.not_nil(evt, "应能解析 X 帧")
    t.eq("exec", evt.kind, "应解析为 exec 事件")
    t.eq(1234, evt.pid, "应解析 pid")
    t.eq("/usr/bin/busybox", evt.path, "应解析可执行路径")

    guard.reset()
    guard.observe(evt, "k7")
    local chain = guard.chain("k7", nil)
    t.eq(1, #chain, "应进入调用链")
    t.eq("/usr/bin/busybox", chain[1].path, "链节点应为真实可执行路径")
    guard.reset()
  end)

  it("execveat 帧同样被解析（防止改接入口绕过调用链）", function(t)
    local observer = require("NeoAI.sandbox.observe.observer")
    local evt = observer.parse_bpftrace_line("X\texecveat\t77\t/bin/bash")
    t.not_nil(evt, "应能解析 execveat")
    t.eq("exec", evt.kind)
    t.eq(77, evt.pid)
  end)
end)
