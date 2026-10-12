--- 危险设备访问门禁测试
--- @module 'NeoAI.tests.test_device_consent'
--- 覆盖：
--- 1. risk.device_access 检测（/dev/kvm、/dev/net/tun、of=、重定向、引号、glob）与不误判；
--- 2. device_consent 配置/动作/超时/允许列表（本会话内存）；
--- 3. request 决策（headless 拒绝、弹窗允许、会话记住、超时自动阻止）；
--- 4. bind_mounts 生成 --dev-bind 挂载项；
--- 5. 门禁端到端（run_command 引用危险设备）：deny 拒绝 / ask 批准后执行 / allow 直接放行。

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

local function run_cmd(cmd, timeout)
  local done, out = false, nil
  require("NeoAI.tools").execute("run_command", { command = cmd, description = "t" }, {})
    :then_(function(r) out = tostring(r); done = true end,
      function(e) out = "ERR:" .. tostring(e and e.message or e); done = true end)
  vim.wait(timeout or 20000, function() return done end, 50)
  return out
end

tests.suite("device_consent", function(_, it)
  it("risk.device_access：命中 /dev/kvm、/dev/net/tun、of=、重定向、glob；不误判无害设备", function(t)
    local risk = require("NeoAI.sandbox.review.risk")
    local function has(cmd, path)
      local m = risk.device_access(cmd)
      for _, p in ipairs(m) do if p == path then return true end end
      return false
    end
    t.true_(has("qemu-system-x86_64 -enable-kvm -device /dev/kvm", "/dev/kvm"), "直接引用 /dev/kvm")
    t.true_(has("ip tuntap add dev tap0; ip link set tap0 up", "/dev/net/tun") == false, "无 /dev 引用不命中")
    t.true_(has("dd if=/dev/zero of=/dev/net/tun bs=1", "/dev/net/tun"), "of= 命中 /dev/net/tun")
    t.true_(has("echo hi >/dev/kvm", "/dev/kvm"), "重定向命中 /dev/kvm")
    t.true_(has('cat "/dev/net/tun"', "/dev/net/tun"), "引号命中 /dev/net/tun")
    t.true_(has("losetup /dev/loop0 img", "/dev/loop0"), "glob /dev/loop* 命中 /dev/loop0")
    t.true_(has("fio --filename=/dev/nvme0n1", "/dev/nvme0n1"), "glob /dev/nvme* 命中")
    -- 不误判
    t.eq(0, #risk.device_access("cat /dev/null; echo /dev/urandom /dev/random /dev/zero"), "无害设备不命中")
    t.eq(0, #risk.device_access("grep -r kvm /etc"), "纯文本 kvm 不命中")
    t.eq(0, #risk.device_access("echo /dev/kvm-backup"), "非精确路径不命中")
    t.eq(0, #risk.device_access(nil), "nil 不命中")
  end)

  it("device_consent：动作/超时/允许列表均为本会话内存", function(t)
    local dc = require("NeoAI.sandbox.review.device_consent")
    dc.reset()
    with_config({ tools = { sandbox = { devices = { action = "ask", timeout_ms = 12345, allowed = {} } } } }, function()
      t.eq("ask", dc.action(), "默认动作 ask")
      t.eq(12345, dc.timeout_ms(), "读取配置超时")
      t.eq(0, #dc.allowed(), "初始允许列表为空")
      t.true_(dc.add_allowed("/dev/kvm"), "新增允许设备")
      t.false_(dc.add_allowed("/dev/kvm"), "重复应拒绝")
      t.true_(dc.is_allowed("/dev/kvm"), "应命中允许列表")
      t.false_(dc.is_allowed("/dev/loop0"), "未允许设备不命中")
      t.true_(dc.remove_allowed(1), "移除允许设备")
      t.false_(dc.remove_allowed(99), "越界移除应失败")
      t.eq(0, #dc.allowed(), "移除后为空")
    end)
    with_config({ tools = { sandbox = { devices = { enabled = false } } } }, function()
      t.false_(dc.enabled(), "可关闭")
    end)
  end)

  it("request：headless 无界面 → 拒绝（fail-closed）", function(t)
    local dc = require("NeoAI.sandbox.review.device_consent")
    require("NeoAI.sandbox.review.approval_hub").reset()
    dc.reset()
    local decision, done
    dc.request({ "/dev/kvm" }):then_(function(v) decision = v; done = true end)
    t.true_(vim.wait(2000, function() return done end), "应完成")
    t.eq("deny", decision, "headless 应拒绝")
  end)

  it("request：弹窗允许（仅本次/会话/拒绝）+ 超时自动阻止", function(t)
    local dc = require("NeoAI.sandbox.review.device_consent")
    local function ask_with(reply, devices, timeout_ms)
      local d
      with_config({ tools = { sandbox = { devices = { timeout_ms = timeout_ms or 30000, allowed = {} } } } }, function()
        dc.set_ui({ show = function(_ctx, decide) decide(reply) end, hide = function() end })
        local decision
        dc.request(devices or { "/dev/kvm" }):then_(function(v) decision = v; d = v end)
        t.true_(vim.wait(3000, function() return d ~= nil end), "应完成")
      end)
      dc.set_ui(nil)
      return d
    end
    t.eq("allow_once", ask_with("allow_once"), "仅本次允许")
    t.eq("deny", ask_with("deny"), "拒绝")
    -- 会话允许并入白名单
    with_config({ tools = { sandbox = { devices = { allowed = {} } } } }, function()
      dc.set_ui({ show = function(_ctx, decide) decide("allow_session") end, hide = function() end })
      local decision, done
      dc.request({ "/dev/kvm" }):then_(function(v) decision = v; done = true end)
      t.true_(vim.wait(3000, function() return done end), "应完成")
      t.eq("allow_session", decision)
      t.true_(dc.is_allowed("/dev/kvm"), "会话允许应写入白名单")
    end)
    dc.set_ui(nil)
    -- 超时：弹窗不决策 → 自动拒绝
    with_config({ tools = { sandbox = { devices = { timeout_ms = 60, allowed = {} } } } }, function()
      dc.set_ui({ show = function() end, hide = function() end })
      local decision, done
      dc.request({ "/dev/kvm" }):then_(function(v) decision = v; done = true end)
      t.true_(vim.wait(3000, function() return done end), "超时应完成")
      t.eq("deny", decision, "超时应自动阻止")
    end)
    dc.reset()
  end)

  it("request：暂存待弹（弹窗未呈现）不因超时自动拒绝；呈现后到时才拒绝", function(t)
    local dc = require("NeoAI.sandbox.review.device_consent")
    -- 未呈现（is_open=false）：小超时后仍不应 resolve（继续等待，避免用户不在聊天界面时被静默拒绝）
    with_config({ tools = { sandbox = { devices = { timeout_ms = 40, allowed = {} } } } }, function()
      dc.set_ui({ show = function() end, hide = function() end, is_open = function() return false end })
      local decision
      dc.request({ "/dev/kvm" }):then_(function(v) decision = v end)
      vim.wait(250)
      t.eq(nil, decision, "暂存待弹时超时不应自动拒绝")
    end)
    dc.set_ui(nil)
    dc.reset()
    -- 已呈现（is_open=true）：到时自动拒绝
    with_config({ tools = { sandbox = { devices = { timeout_ms = 40, allowed = {} } } } }, function()
      dc.set_ui({ show = function() end, hide = function() end, is_open = function() return true end })
      local decision, done
      dc.request({ "/dev/kvm" }):then_(function(v) decision = v; done = true end)
      t.true_(vim.wait(2000, function() return done end), "呈现后超时应完成")
      t.eq("deny", decision, "呈现后超时应自动阻止")
    end)
    dc.reset()
  end)

  it("bind_mounts：已批准且宿主存在的设备生成 mode=dev", function(t)
    local dc = require("NeoAI.sandbox.review.device_consent")
    -- /dev/null 是真实字符设备，仅用于验证挂载项生成逻辑（不校验是否在危险模式表内）。
    local m = dc.bind_mounts({ "/dev/null" }, { sandbox_device_granted = { "/dev/null" } })
    t.eq(1, #m, "应生成 1 个挂载项")
    t.eq("/dev/null", m[1].src)
    t.eq("/dev/null", m[1].dst)
    t.eq("dev", m[1].mode)
    t.eq(0, #dc.bind_mounts({ "/dev/null" }, {}), "未批准不生成")
    t.eq(0, #dc.bind_mounts({ "/dev/does-not-exist-xyz" }, { sandbox_device_granted = { "/dev/does-not-exist-xyz" } }),
      "不存在的设备不生成")
  end)

  it("门禁端到端（静态回退 dynamic=false）：deny 拒绝 / ask 批准后执行 / allow 直接放行", function(t)
    local dc = require("NeoAI.sandbox.review.device_consent")
    require("NeoAI.sandbox").reset()
    dc.reset()
    -- 命令引用 /dev/kvm 但仅 echo（不真正依赖该设备），故批准后可正常执行。
    local cmd = "echo neoai_dev_ok /dev/kvm"
    -- 1) 默认 ask + headless → 拒绝
    with_config({ tools = { sandbox = { enabled = true, fail_closed = true, mode = "dry_run", ephemeral_roots = {},
      devices = { dynamic = false } } } }, function()
      t.matches("危险设备", run_cmd(cmd), "headless ask 应拒绝")
    end)
    -- 2) 弹窗允许 → 执行
    with_config({
      tools = {
        sandbox = { enabled = true, fail_closed = true, mode = "dry_run", ephemeral_roots = {},
          devices = { dynamic = false } },
        approval = { mode = "auto_allow" },
      },
    }, function()
      require("NeoAI.sandbox").reset()
      dc.reset()
      dc.set_ui({ show = function(_ctx, decide) decide("allow_once") end, hide = function() end })
      t.matches("neoai_dev_ok", run_cmd(cmd), "批准后应执行")
      dc.set_ui(nil)
    end)
    -- 3) action=deny → 直接拒绝
    with_config({
      tools = {
        sandbox = { enabled = true, fail_closed = true, mode = "dry_run", ephemeral_roots = {},
          devices = { action = "deny", dynamic = false } },
        approval = { mode = "auto_allow" },
      },
    }, function()
      require("NeoAI.sandbox").reset()
      dc.reset()
      t.matches("危险设备", run_cmd(cmd), "deny 应拒绝")
    end)
    -- 4) action=allow → 直接放行（无弹窗）
    with_config({
      tools = {
        sandbox = { enabled = true, fail_closed = true, mode = "dry_run", ephemeral_roots = {},
          devices = { action = "allow", dynamic = false } },
        approval = { mode = "auto_allow" },
      },
    }, function()
      require("NeoAI.sandbox").reset()
      dc.reset()
      t.matches("neoai_dev_ok", run_cmd(cmd), "allow 应放行")
    end)
    dc.reset()
  end)

  it("动态监测：device_path_match 命中具体路径且不误判", function(t)
    local risk = require("NeoAI.sandbox.review.risk")
    t.eq("/dev/kvm", risk.device_path_match("/dev/kvm"), "应命中 /dev/kvm")
    t.eq("/dev/net/tun", risk.device_path_match("/dev/net/tun"), "应命中 /dev/net/tun")
    t.eq("/dev/loop3", risk.device_path_match("/dev/loop3"), "glob 命中 /dev/loop3")
    t.eq(nil, risk.device_path_match("/dev/null"), "无害设备不命中")
    t.eq(nil, risk.device_path_match("/etc/hostname"), "普通文件不命中")
    t.eq(nil, risk.device_path_match(nil), "nil 不命中")
  end)

  it("动态监测：_device_observe 记录命中的危险设备并终止命令树", function(t)
    local wrapper = require("NeoAI.sandbox.execution.wrapper")
    local dc = require("NeoAI.sandbox.review.device_consent")
    local observer = require("NeoAI.sandbox.observe.observer")
    dc.reset()
    -- 与真实后端无关：桩定 backend=ebpf，使 dynamic_active 为真。
    local orig_backend = observer.backend
    ---@diagnostic disable-next-line: duplicate-set-field
    observer.backend = function() return "ebpf" end
    with_config({ tools = { sandbox = { devices = { enabled = true, dynamic = true, allowed = {} } } } }, function()
      local killed = false
      local ctx = { sandbox_kill = function() killed = true end }
      local matched = wrapper._device_observe({ tool_name = "run_command" }, ctx, "/dev/kvm")
      t.eq("/dev/kvm", matched, "应识别 /dev/kvm 访问")
      t.true_(ctx.sandbox_device_blocked ~= nil and ctx.sandbox_device_blocked["/dev/kvm"] == true,
        "应记入 blocked")
      t.true_(killed, "应请求终止命令树")
      t.true_(ctx.sandbox_device_killed, "应标记已终止（幂等）")
      -- 已允许设备不再阻断
      dc.add_allowed("/dev/kvm")
      local ctx2 = { sandbox_kill = function() end }
      t.eq(nil, wrapper._device_observe({ tool_name = "run_command" }, ctx2, "/dev/kvm"),
        "已允许设备不再阻断")
      -- 无害路径不阻断
      local ctx3 = { sandbox_kill = function() end }
      t.eq(nil, wrapper._device_observe({ tool_name = "run_command" }, ctx3, "/dev/null"),
        "无害设备不阻断")
      -- dynamic=false 时不进行动态阻断（交由静态回退）
      local ctx4 = { sandbox_kill = function() end }
      require("NeoAI.kernel.config_store").set("tools.sandbox.devices.dynamic", false)
      t.eq(nil, wrapper._device_observe({ tool_name = "run_command" }, ctx4, "/dev/kvm"),
        "dynamic=false 时不动态阻断")
    end)
    observer.backend = orig_backend
    dc.reset()
  end)

  it("动态监测：eBPF 端到端（观测到危险设备 open → 未批准拒绝；可用时才跑）", function(t)
    local observer = require("NeoAI.sandbox.observe.observer")
    if observer.backend() ~= "ebpf" then return end -- 无 eBPF 后端（CI）时跳过
    local dc = require("NeoAI.sandbox.review.device_consent")
    local cfg = require("NeoAI.kernel.config_store")
    with_config({
      tools = {
        sandbox = { enabled = true, fail_closed = true, mode = "dry_run", postprocess = "sync",
          ephemeral_roots = {}, resident = { enabled = false },
          observe = { enabled = true, backend = "ebpf", wait_ready_ms = 3000 },
          devices = { enabled = true, dynamic = true, action = "ask", allowed = {} } },
        approval = { mode = "auto_allow" },
      },
    }, function()
      require("NeoAI.sandbox").reset()
      dc.reset()
      -- /dev/kvm 在宿主通常不存在：命令 open 失败 → 动态识别 → headless 弹窗拒绝。
      if vim.uv.fs_stat("/dev/kvm") ~= nil then return end
      local out = run_cmd("cat /dev/kvm")
      t.matches("危险设备", out, "动态监测应拒绝未批准的危险设备访问")
    end)
    dc.reset()
  end)
end)
