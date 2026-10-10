--- 沙箱行为观测（eBPF/strace/procfs）与增量密钥检测
--- @module NeoAI.tests.test_observer
--- 离线覆盖：bpftrace/strace 事件解析、后端选择、密钥路径判定、增量上下文扫描、
--- 以及「观测到的密钥文件访问」驱动的 UI 告警行。

local tests = require("NeoAI.tests")

--- 保存/恢复全局配置
local function with_config(overrides, fn)
  local config_store = require("NeoAI.kernel.config_store")
  local saved = config_store.get_all()
  local merged = vim.deepcopy(overrides or {})
  config_store.load(merged)
  local ok, err = pcall(fn)
  config_store.load(saved)
  if not ok then error(err, 0) end
end

tests.suite("observer", function(_, it)
  local observer = require("NeoAI.sandbox.observer")
  local secret = require("NeoAI.sandbox.secret")

  it("解析 bpftrace 事件行：文件/执行/网络", function(t)
    local f = observer.parse_bpftrace_line("F\topenat\t123\t/root/.ssh/id_rsa")
    t.eq("file", f.kind)
    t.eq("openat", f.op)
    t.eq(123, f.pid)
    t.eq("/root/.ssh/id_rsa", f.path)
    local x = observer.parse_bpftrace_line("X\texecve\t7\t/usr/bin/ls")
    t.eq("exec", x.kind)
    t.eq("/usr/bin/ls", x.path)
    local n = observer.parse_bpftrace_line("N\tconnect\t9\t1.2.3.4:443")
    t.eq("net", n.kind)
    t.eq("1.2.3.4", n.host)
    t.eq(443, n.port)
    t.eq(nil, observer.parse_bpftrace_line("garbage"))
  end)

  it("解析 strace 事件行：openat/execve/connect（含 [pid] 前缀）", function(t)
    local o = observer.parse_strace_line('123 openat(AT_FDCWD, "/root/.aws/credentials", O_RDONLY) = 3')
    t.eq("file", o.kind)
    t.eq("/root/.aws/credentials", o.path)
    local e = observer.parse_strace_line('[pid  99] execve("/bin/ls", ["ls"], 0x0) = 0')
    t.eq("exec", e.kind)
    t.eq(99, e.pid)
    t.eq("/bin/ls", e.path)
    local c = observer.parse_strace_line(
      '[pid  99] connect(3, {sa_family=AF_INET, sin_port=htons(443), sin_addr=inet_addr("1.2.3.4")}, 16) = 0')
    t.eq("net", c.kind)
    t.eq("1.2.3.4", c.host)
    t.eq(443, c.port)
    t.eq(nil, observer.parse_strace_line("nonsense"))
  end)

  it("观测路径清洗：剔除控制字符", function(t)
    local evt = observer.parse_bpftrace_line("F\topenat\t1\t/root/\1secret\2.rsa")
    t.eq("/root/secret.rsa", evt.path)
  end)

  it("解析写/删事件标签（写日志）", function(t)
    local w = observer.parse_bpftrace_line("W\topenat\t5\t/root/a.txt")
    t.eq("file", w.kind)
    t.true_(w.write == true, "W 应标记 write")
    t.eq("/root/a.txt", w.path)
    local d = observer.parse_bpftrace_line("D\tunlinkat\t5\t/root/b.txt")
    t.true_(d.delete == true, "D 应标记 delete")
    local f = observer.parse_bpftrace_line("F\topenat\t5\t/root/c.txt")
    t.nil_(f.write, "F 不应标记 write")
    t.nil_(f.delete, "F 不应标记 delete")
  end)

  it("后端选择：关闭观测 / 强制 heuristic 时回退命令解析", function(t)
    observer.reset()
    with_config({ tools = { sandbox = { observe = { enabled = false } } } }, function()
      t.eq("heuristic", observer.backend())
      t.false_(observer.available())
    end)
    observer.reset()
    with_config({ tools = { sandbox = { observe = { backend = "heuristic" } } } }, function()
      t.eq("heuristic", observer.backend())
    end)
    observer.reset()
  end)

  it("后端探测：返回各后端可用性与选定后端", function(t)
    observer.reset()
    local p = observer.probe()
    t.not_nil(p.ebpf)
    t.not_nil(p.strace)
    t.not_nil(p.procfs)
    t.true_(p.backend == "ebpf" or p.backend == "strace" or p.backend == "procfs" or p.backend == "heuristic",
      "后端应为已知值，实际 " .. tostring(p.backend))
    observer.reset()
  end)

  it("启动通知：观测关闭时不 notify", function(t)
    observer.reset()
    local calls = 0
    local orig = vim.notify
    vim.notify = function() calls = calls + 1 end
    with_config({ tools = { sandbox = { observe = { enabled = false } } } }, function()
      observer.notify_backend()
    end)
    vim.notify = orig
    observer.reset()
    t.eq(0, calls, "关闭观测不应通知")
  end)

  it("启动通知：回退命令解析时发出提示", function(t)
    observer.reset()
    local msgs = {}
    local orig = vim.notify
    vim.notify = function(m) msgs[#msgs + 1] = tostring(m) end
    with_config({ tools = { sandbox = { observe = { backend = "heuristic", notify = true } } } }, function()
      observer.notify_backend()
    end)
    vim.notify = orig
    observer.reset()
    t.true_(#msgs >= 1, "应发出回退通知")
  end)

  it("密钥文件路径判定", function(t)
    t.true_(secret.is_secret_path("/root/.ssh/id_rsa"))
    t.true_(secret.is_secret_path("/home/u/.aws/credentials"))
    t.true_(secret.is_secret_path("/proj/.env"))
    t.true_(secret.is_secret_path("/x/server.key"))
    t.false_(secret.is_secret_path("/usr/bin/ls"))
    t.false_(secret.is_secret_path(nil))
  end)

  it("增量上下文扫描：仅检测新增消息", function(t)
    secret.reset()
    local _tok, used = secret.tokenize("aws = AKIAIOSFODNN7EXAMPLE")
    t.true_(#used >= 1, "应登记至少一个密钥 token")
    local msgs = {
      { role = "user", content = "ordinary" },
      { role = "user", content = "raw AKIAIOSFODNN7EXAMPLE" },
    }
    t.not_nil(secret.context_leak_from(msgs, 1), "从第 1 条起应命中")
    t.not_nil(secret.context_leak_from(msgs, 2), "从第 2 条起应命中")
    t.eq(nil, secret.context_leak_from(msgs, 3), "越过后无新增应不命中")
    t.not_nil(secret.context_leak(msgs), "全量扫描应命中")
    secret.reset()
  end)

  it("观测到的密钥文件访问驱动 UI 告警行（优先于命令解析）", function(t)
    local ml = require("NeoAI.ui.components.message_list")
    local line = ml.helpers.secret_warning_line(
      { name = "read_file", arguments = '{"file_path":"/tmp/plain.txt"}' },
      { role = "tool", content = "ok", secret_paths = { "/root/.ssh/id_rsa" } })
    t.not_nil(line, "观测到密钥访问应产生告警行")
    t.matches("观测到密钥文件", line)
    t.matches("/root/%.ssh/id_rsa", line)
  end)

  it("观测预热：后台预创建 cgroup 并挂载探针，可清理", function(t)
    local cgroup = require("NeoAI.sandbox.cgroup")
    if not cgroup.probe().available then return end
    local wrapper = require("NeoAI.sandbox.wrapper")
    wrapper.clear_prewarm()
    -- 注入伪 eBPF 后端：验证预热流程（预创建 cgroup + 启动探针）而不依赖真实 bpftrace。
    local started = {}
    local orig_backend, orig_available, orig_start = observer.backend, observer.available, observer.start
    observer.backend = function() return "ebpf" end
    observer.available = function() return true, "ebpf" end
    observer.start = function(opts)
      started[#started + 1] = opts
      return { backend = "ebpf", ready = false, stop = function() end }
    end
    with_config({ tools = { sandbox = { observe = { enabled = true, prewarm = true } } } }, function()
      wrapper._prewarm_observer()
      local info = wrapper.prewarm_info()
      t.eq(true, info.active, "应存在预热 cgroup")
      t.eq(true, info.has_handle, "应已启动预热探针")
      t.eq(1, #started, "应只启动一次探针")
      t.true_(started[1].cgroup_id ~= nil, "探针应按 cgroup id 过滤")
      -- 幂等：已有预热时不重复启动
      wrapper._prewarm_observer()
      t.eq(1, #started, "已有预热不应重复启动")
    end)
    observer.backend, observer.available, observer.start = orig_backend, orig_available, orig_start
    wrapper.clear_prewarm()
    t.eq(false, wrapper.prewarm_info().active, "清理后应无预热")
  end)

  it("预热 TTL 定时器用 uv 句柄停止（不把 userdata 传给 timer_stop，避免 E5101）", function(t)
    local wrapper = require("NeoAI.sandbox.wrapper")
    local cgroup = require("NeoAI.sandbox.cgroup")
    if not cgroup.probe().available then return end
    wrapper.clear_prewarm()
    local observer = require("NeoAI.sandbox.observer")
    local orig_backend, orig_available, orig_start = observer.backend, observer.available, observer.start
    observer.backend = function() return "ebpf" end
    observer.available = function() return true, "ebpf" end
    observer.start = function() return { backend = "ebpf", ready = false, stop = function() end } end
    local stop_args = {}
    local orig_stop = vim.fn.timer_stop
    vim.fn.timer_stop = function(id)
      stop_args[#stop_args + 1] = id
      return orig_stop(id)
    end
    with_config({ tools = { sandbox = { observe = { enabled = true, prewarm = true, prewarm_ttl_ms = 60000 } } } }, function()
      wrapper._prewarm_observer()
      t.eq(true, wrapper.prewarm_info().has_handle, "应已启动预热探针")
      wrapper.clear_prewarm()
    end)
    vim.fn.timer_stop = orig_stop
    observer.backend, observer.available, observer.start = orig_backend, orig_available, orig_start
    for _, id in ipairs(stop_args) do
      t.ne("userdata", type(id), "不得把 uv 定时器句柄传给 vim.fn.timer_stop（会抛 E5101）")
    end
    t.eq(false, wrapper.prewarm_info().active, "清理后应无预热")
  end)

  it("strace 观测：解析移入线程池并按路径去重派发文件事件", function(t)
    local work = require("NeoAI.utils.work")
    if not work.available() then return end -- 无 worker：同步回退已另有覆盖
    local orig_backend = observer.backend
    observer.backend = function() return "strace" end
    local got = {}
    local prefix, handle = observer.strace_prefix({
      attempt_id = "strace_async_test",
      on_event = function(evt) got[#got + 1] = evt end,
      poll_ms = 20,
    })
    t.not_nil(prefix, "应返回 strace 前缀")
    t.not_nil(handle, "应返回 handle")
    local f = io.open(handle.path, "w")
    f:write('123 openat(AT_FDCWD, "/root/.ssh/id_rsa", O_RDONLY) = 3\n')
    f:write('123 openat(AT_FDCWD, "/root/.ssh/id_rsa", O_RDONLY) = 3\n')
    f:write('123 openat(AT_FDCWD, "/usr/bin/ls", O_RDONLY) = 4\n')
    f:close()
    vim.wait(3000, function() return handle.offset > 0 and not handle.draining end, 20)
    handle.stop()
    observer.backend = orig_backend
    local paths, n_rsa = {}, 0
    for _, e in ipairs(got) do
      paths[e.path] = true
      if e.path == "/root/.ssh/id_rsa" then n_rsa = n_rsa + 1 end
    end
    t.true_(paths["/root/.ssh/id_rsa"], "应派发密钥文件路径")
    t.true_(paths["/usr/bin/ls"], "应派发普通文件路径")
    t.eq(1, n_rsa, "线程内解析应按路径去重（同一路径只派发一次）")
    pcall(os.remove, handle.path)
  end)

  it("cgroup：预热句柄可认领到 attempt（release 生效）", function(t)
    local cgroup = require("NeoAI.sandbox.cgroup")
    if not cgroup.probe().available then return end
    local h = cgroup.prepare("prewarm_test", { pids = 4 })
    t.not_nil(h, "应能创建预热 cgroup")
    cgroup.adopt(h, "attempt_real")
    t.eq("attempt_real", h.attempt_id, "应改挂到真实 attempt")
    cgroup.release(h)
    t.eq(0, vim.fn.isdirectory(h.path), "release 后目录应删除")
  end)
end)
