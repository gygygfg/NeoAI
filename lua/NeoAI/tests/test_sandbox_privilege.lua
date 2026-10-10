--- 沙箱权限：加固/最小权限/提权/cap-drop/mount/seccomp 能力
--- @module 'NeoAI.tests.test_sandbox_privilege'
--- 由原 test_sandbox.lua 按用例分片而来（42 个用例，彼此独立、无跨用例共享状态）。

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

tests.suite("sandbox_privilege", function(_, it)
  it("加固：遮蔽目录命中走审批，批准放行、无界面 fail-closed", function(t)
    local fs = require("NeoAI.utils.fs")
    local home = "/root/neoai_mask_approve_test"
    local proj = home .. "/proj"
    local secret = home .. "/other/secret.txt"
    fs.ensure_dir(proj)
    fs.ensure_dir(home .. "/other")
    fs.write_file(secret, "TOPSECRET")
    local prev = vim.fn.getcwd()
    vim.fn.chdir(proj)
    with_config({ tools = { sandbox = {
      read_all = false, mask_dirs_enabled = true, mask_dirs = { "/root" }, mask_dirs_approval = true,
    } } }, function()
      -- 1) 有审批界面：弹窗（stub）批准后放行读取
      local asked = nil
      local stub = {
        approve_and_execute = function(name, _, _, continue_fn)
          asked = name
          return continue_fn()
        end,
      }
      local done, result = false, nil
      require("NeoAI.tools").execute("read_file", { file_path = secret, description = "t" }, { tool_service = stub })
        :then_(function(r)
          result = tostring(r)
          done = true
        end, function(e)
          result = "ERR:" .. tostring(e and e.message or e)
          done = true
        end)
      t.true_(vim.wait(10000, function() return done end), "应完成")
      t.eq("read_file", asked, "应触发审批弹窗")
      t.matches("TOPSECRET", result or "", "批准后应可读取")
      -- 2) 无审批界面：进程内读取 fail-closed 拒绝
      local done2, err2 = false, nil
      require("NeoAI.tools").execute("read_file", { file_path = secret, description = "t" }, {})
        :then_(function(r)
          err2 = "OK:" .. tostring(r)
          done2 = true
        end, function(e)
          err2 = "ERR:" .. tostring(e and e.message or e)
          done2 = true
        end)
      t.true_(vim.wait(10000, function() return done2 end), "应完成")
      t.matches("ERR:", err2 or "", "无界面应拒绝，实际: " .. tostring(err2))
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(home, "rf")
  end)

  it("加固：进程内工具硬拦截宿主敏感遮蔽路径（mask_paths）", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    local fs = require("NeoAI.utils.fs")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local file = dir .. "/secret.env"
    fs.write_file(file, "TOPSECRET")
    with_config({ tools = { sandbox = { mask_paths = { file, dir } } } }, function()
      -- 查询 API：目录/文件/后代命中，普通路径不命中
      t.eq(dir, runtime.is_masked_path(dir), "目录本身应命中")
      t.eq(dir, runtime.is_masked_path(dir .. "/sub/x"), "目录后代应命中")
      t.eq(file, runtime.is_masked_path(file), "文件本身应命中")
      t.nil_(runtime.is_masked_path("/tmp/neoai_not_masked"), "普通路径不应命中")
      -- 进程内 read_file 命中即硬拒绝（即便有审批界面也不放行）
      local stub = { approve_and_execute = function(_, _, _, cont) return cont() end }
      local done, err = false, nil
      require("NeoAI.tools").execute("read_file", { file_path = file, description = "t" }, { tool_service = stub })
        :then_(function(r)
          err = "OK:" .. tostring(r)
          done = true
        end, function(e)
          err = "ERR:" .. tostring(e and e.message or e)
          done = true
        end)
      t.true_(vim.wait(5000, function() return done end), "应快速返回")
      t.matches("宿主敏感遮蔽路径", err or "", "应硬拒绝，实际: " .. tostring(err))
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("加固：is_masked_path 支持本次 attempt 的 unmask（档位/审批放行）", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    local fs = require("NeoAI.utils.fs")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local file = dir .. "/secret.env"
    fs.write_file(file, "x")
    with_config({ tools = { sandbox = { mask_paths = { file } } } }, function()
      t.eq(file, runtime.is_masked_path(file), "默认应命中")
      t.nil_(runtime.is_masked_path(file, { file }), "unmask 精确命中应放行")
      t.nil_(runtime.is_masked_path(file, { dir }), "unmask 祖先命中应放行")
      t.eq(file, runtime.is_masked_path(file, { "/tmp/neoai_other" }), "无关 unmask 不应放行")
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("加固：NeoAI 自身运行时/状态路径被识别（不计入候选，避免日志增长致 CAS 冲突）", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    local fs = require("NeoAI.utils.fs")
    local cache = vim.fn.stdpath("cache") .. "/NeoAI"
    t.true_(runtime.is_self_runtime_path(cache), "缓存根应命中")
    t.true_(runtime.is_self_runtime_path(cache .. "/neoai.log"), "日志应命中")
    t.true_(runtime.is_self_runtime_path(cache .. "/sessions.jsonl"), "会话文件应命中")
    t.true_(runtime.is_self_runtime_path(cache .. "/sandbox/instances/1_2/upper/x"), "沙箱 store 后代应命中")
    t.false_(runtime.is_self_runtime_path(cache .. "_other/x"), "前缀边界不应命中")
    t.false_(runtime.is_self_runtime_path("/tmp/neoai_project_file.lua"), "工作区普通文件不应命中")
    -- 可配置的 log.path 也纳入识别
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    with_config({ log = { path = dir .. "/my.log" } }, function()
      t.true_(runtime.is_self_runtime_path(dir .. "/my.log"), "自定义日志路径应命中")
      t.false_(runtime.is_self_runtime_path(dir .. "/other.log"), "自定义日志的兄弟文件不应命中")
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("性能回归：遮蔽路径 glob/规范化按配置缓存，不随逐文件判定重算", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    local glob = vim.fn.glob
    local calls = 0
    vim.fn.glob = function(...)
      calls = calls + 1
      return glob(...)
    end
    local ok, err = pcall(function()
      with_config({ tools = { sandbox = { mask_paths = { "/tmp/neoai_mask_glob_*", "/etc/shadow" } } } }, function()
        -- 预热缓存：首次判定会 glob 展开通配条目
        runtime.is_masked_path("/tmp/neoai_x")
        calls = 0
        -- 大候选捕获/合并会对每个文件逐次判定：命中缓存后不得再逐次 glob（主线程 CPU 热点）
        for i = 1, 100 do runtime.is_masked_path("/tmp/plain_" .. i) end
        t.eq(0, calls, "缓存命中后不应逐次 glob")
      end)
      -- 配置变更应失效缓存并采用新规则
      with_config({ tools = { sandbox = { mask_paths = { "/tmp/neoai_mask_a" } } } }, function()
        t.not_nil(runtime.is_masked_path("/tmp/neoai_mask_a"), "新配置应生效")
      end)
      with_config({ tools = { sandbox = { mask_paths = { "/tmp/neoai_mask_b" } } } }, function()
        t.nil_(runtime.is_masked_path("/tmp/neoai_mask_a"), "配置变更应失效旧缓存")
        t.not_nil(runtime.is_masked_path("/tmp/neoai_mask_b"), "配置变更后新条目应命中")
      end)
    end)
    vim.fn.glob = glob
    if not ok then error(err) end
  end)

  it("加固：遮蔽路径解析符号链接与 /proc/<pid>/root，防进程内绕过", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    local fs = require("NeoAI.utils.fs")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local file = dir .. "/secret.env"
    fs.write_file(file, "TOPSECRET")
    local link_dir = vim.fn.tempname()
    fs.ensure_dir(link_dir)
    local link = link_dir .. "/link.env"
    vim.uv.fs_symlink(file, link)
    -- 悬空符号链接：目标尚未创建，但指向被遮蔽目录（写入也会落到宿主敏感路径）
    local dangling = link_dir .. "/dangling.env"
    vim.uv.fs_symlink(dir .. "/new-secret.env", dangling)
    with_config({ tools = { sandbox = { mask_paths = { file, dir } } } }, function()
      t.eq(file, runtime.is_masked_path(file), "原路径应命中")
      t.eq(file, runtime.is_masked_path(link), "符号链接应解析到遮蔽文件")
      t.eq(dir, runtime.is_masked_path(dangling), "悬空符号链接应解析到遮蔽目录")
      t.eq(file, runtime.is_masked_path("/proc/self/root" .. file), "/proc/<pid>/root 应解析到遮蔽文件")
      t.eq(file, runtime.is_masked_path("/proc/1/root" .. file), "/proc/1/root 应解析到遮蔽文件")
      -- 进程内 read_file 经符号链接/`/proc/self/root` 均应硬拒绝
      local function must_reject(path)
        local done, err = false, nil
        require("NeoAI.tools").execute("read_file", { file_path = path, description = "t" }, {})
          :then_(function(r)
            err = "OK:" .. tostring(r)
            done = true
          end, function(e)
            err = "ERR:" .. tostring(e and e.message or e)
            done = true
          end)
        t.true_(vim.wait(5000, function() return done end), "应快速返回")
        t.matches("宿主敏感遮蔽路径", err or "", "应硬拒绝: " .. tostring(path))
      end
      must_reject(link)
      must_reject("/proc/self/root" .. file)
      -- 非进程内 fs 工具（read_image，effect=network）的本地 file_path 也纳入遮蔽判定。
      local done, err = false, nil
      require("NeoAI.tools").execute("read_image", { file_path = file, description = "t" }, {})
        :then_(function(r)
          err = "OK:" .. tostring(r)
          done = true
        end, function(e)
          err = "ERR:" .. tostring(e and e.message or e)
          done = true
        end)
      t.true_(vim.wait(5000, function() return done end), "应快速返回")
      t.matches("宿主敏感遮蔽路径", err or "", "read_image 应硬拒绝，实际: " .. tostring(err))
    end)
    vim.fn.delete(link_dir, "rf")
    vim.fn.delete(dir, "rf")
  end)

  it("加固：mask_paths 硬命中优先于遮蔽目录软命中（非进程内 fs 工具不放行）", function(t)
    local fs = require("NeoAI.utils.fs")
    local home = "/root/neoai_mask_order_test"
    local proj = home .. "/proj"
    fs.ensure_dir(proj)
    fs.ensure_dir(home .. "/other")
    local secret = home .. "/other/secret.png"
    fs.write_file(secret, "x")
    local prev = vim.fn.getcwd()
    vim.fn.chdir(proj)
    with_config({ tools = { sandbox = { mask_dirs = { home }, mask_paths = { secret } } } }, function()
      local done, err = false, nil
      require("NeoAI.tools").execute("read_image", { file_path = secret, description = "t" }, {})
        :then_(function(r)
          err = "OK:" .. tostring(r)
          done = true
        end, function(e)
          err = "ERR:" .. tostring(e and e.message or e)
          done = true
        end)
      t.true_(vim.wait(5000, function() return done end), "应快速返回")
      t.matches("宿主敏感遮蔽路径", err or "", "mask_paths 应优先硬拒绝，实际: " .. tostring(err))
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(home, "rf")
  end)

  it("权限档位：命令分类与最高档校验", function(t)
    local privilege = require("NeoAI.sandbox.execution.privilege")
    local spec = { effect = "process" }
    t.eq(0, privilege.classify("run_command", { command = "ls -la" }, spec).tier, "普通命令应为 T0")
    local docker = privilege.classify("run_command", { command = "docker ps" }, spec)
    t.eq(1, docker.tier, "docker 命令应为 T1")
    t.true_(docker.docker, "应标记需要 docker")
    local net = privilege.classify("run_command", { command = "curl https://x" }, spec)
    t.eq(1, net.tier, "网络命令应为 T1")
    local sudo = privilege.classify("run_command", { command = "sudo mount /dev/x" }, spec)
    t.eq(2, sudo.tier, "sudo/mount 应为 T2")
    -- sudo/doas 是降权包装器（载荷本就 root）：档位由被包裹命令决定；被包裹命令普通时至少 T1
    -- 并标记 privdrop（按 sysadmin 加回能力/解除 sudoers 遮蔽），使 `sudo -u <user>` 可用。
    local sudo_id = privilege.classify("run_command", { command = "sudo id" }, spec)
    t.eq(1, sudo_id.tier, "sudo id 应为 T1（降权包装器）")
    t.true_(sudo_id.privdrop, "应标记 privdrop")
    t.eq(0, privilege.classify("read_file", { file_path = "/x" }, { effect = "read" }).tier, "非 process 应 T0")
    -- 复合命令取最高档
    t.eq(1, privilege.classify("run_command", { command = "ls && sudo id" }, spec).tier, "复合命令取最高档")
    -- 最高档校验
    with_config({ tools = { sandbox = { privilege = { max_tier = 1 } } } }, function()
      t.false_(privilege.resolve(2, { tier = 2 }).ok, "超过 max_tier 应拒绝")
      t.true_(privilege.resolve(1, { tier = 1 }).ok, "等于 max_tier 应放行")
    end)
  end)

  it("权限档位：T0 默认放行网络（仅记录），offline 时硬隔离", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    local privilege = require("NeoAI.sandbox.execution.privilege")
    if runtime.backend() ~= "bwrap" then return end
    local t0 = privilege.resolve(0, { tier = 0 })
    local pre0 = table.concat(assert(runtime.process_prefix({ cwd = "/tmp", privileges = t0.privileges })), " ")
    t.true_(pre0:find("--unshare-net", 1, true) == nil, "T0 默认不应隔离网络（仅记录）")
    local t1 = privilege.resolve(1, { tier = 1, network = true })
    local pre1 = table.concat(assert(runtime.process_prefix({ cwd = "/tmp", privileges = t1.privileges })), " ")
    t.true_(pre1:find("--unshare-net", 1, true) == nil, "T1 不应隔离网络")
    -- T2 走嵌套 userns
    local t2 = privilege.resolve(2, { tier = 2, network = true })
    local pre2 = table.concat(assert(runtime.process_prefix({ cwd = "/tmp", privileges = t2.privileges })), " ")
    t.true_(pre2:find("--unshare-all", 1, true) ~= nil, "T2 应新建 user namespace")
    -- offline=true 硬隔离，优先于档位
    with_config({ tools = { sandbox = { offline = true } } }, function()
      local preo = table.concat(assert(runtime.process_prefix({ cwd = "/tmp", privileges = t0.privileges })), " ")
      t.true_(preo:find("--unshare-net", 1, true) ~= nil, "offline=true 应隔离网络")
    end)
  end)

  it("受控 docker：T1 挂载受控 socket 而非宿主 socket", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    local privilege = require("NeoAI.sandbox.execution.privilege")
    if runtime.backend() ~= "bwrap" then return end
    local fs = require("NeoAI.utils.fs")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local sock = dir .. "/docker.sock"
    fs.write_file(sock, "")
    with_config({ tools = { sandbox = { docker = { mode = "controlled", socket = sock } } } }, function()
      local res = privilege.resolve(1, { tier = 1, docker = true, network = true })
      t.true_(res.ok, "受控 socket 存在时应可解析 T1")
      t.eq(sock, res.privileges.mounts[1] and res.privileges.mounts[1].src, "应挂载受控 socket")
      t.eq("/var/run/docker.sock", res.privileges.mounts[1].dst, "应挂载到 docker.sock")
      t.eq("unix:///var/run/docker.sock", res.privileges.env.DOCKER_HOST, "应注入 DOCKER_HOST")
      local pre = table.concat(assert(runtime.process_prefix({ cwd = "/tmp", privileges = res.privileges })), " ")
      t.true_(pre:find("--bind " .. sock .. " /var/run/docker.sock", 1, true) ~= nil, "前缀应绑定受控 socket")
      t.true_(pre:find("--bind /dev/null /var/run/docker.sock", 1, true) == nil, "不应遮蔽受控 socket")
    end)
    -- socket 缺失 → 明确拒绝
    with_config({ tools = { sandbox = { docker = { mode = "controlled", socket = "/nonexistent/docker.sock" } } } }, function()
      local res = privilege.resolve(1, { tier = 1, docker = true })
      t.false_(res.ok, "受控 socket 缺失应拒绝")
      t.matches("DOCKER_SOCKET", tostring(res.reason))
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("权限档位：策略对越界档位硬拒绝", function(t)
    local policy = require("NeoAI.sandbox.review.policy")
    with_config({ tools = { sandbox = { privilege = { max_tier = 1 } } } }, function()
      local v = policy.evaluate({
        tool = "run_command", effect = "process", args = { command = "sudo id" },
        privilege = { tier = 2 },
      })
      t.eq("DENY", v.decision, "越界档位应硬拒绝")
      t.true_(vim.tbl_contains(v.reason_codes, "PRIVILEGE_TIER_EXCEEDS_MAX"), "应带越界原因")
    end)
  end)

  it("权限档位：失败检测与自动升级（记录事件，不静默）", function(t)
    local privilege = require("NeoAI.sandbox.execution.privilege")
    local esc = assert(privilege.detect_escalation({ code = 6, stderr = "curl: (6) Could not resolve host: x" }))
    t.not_nil(esc, "网络失败应建议升级")
    t.eq(1, esc.tier, "网络失败应为 T1")
    local perm = assert(privilege.detect_escalation({ code = 1, stderr = "mount: Operation not permitted" }))
    t.eq(2, perm.tier, "权限拒绝应为 T2")
    t.eq(nil, privilege.detect_escalation({ code = 0, stderr = "could not resolve host" }), "成功不应升级")

    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local events = require("NeoAI.kernel.events")
    local event_bus = require("NeoAI.kernel.event_bus")
    local got = false
    local unsub = event_bus.on(events.SANDBOX_PRIVILEGE_ESCALATION_REQUESTED, function() got = true end)
    local sandbox = require("NeoAI.sandbox")
    with_config({
      tools = {
        approval = { mode = "async" },
        sandbox = { mode = "dry_run", review = { enabled = true }, privilege = { auto_escalate = true, max_tier = 2 } },
      },
    }, function()
      sandbox.reset()
      local done = false
      -- 该命令本身未命中分类（T0），但失败输出命中网络失败模式 → 自动发起 T1 升级。
      require("NeoAI.tools").execute("run_command", {
        command = "sh -c 'echo \"could not resolve host: x\" >&2; exit 6'",
        description = "t",
      }, {}):then_(function() done = true end, function() done = true end)
      t.true_(vim.wait(12000, function() return done end), "命令应完成")
      t.true_(got, "应触发自动升级事件")
    end)
    if unsub then pcall(unsub) end
  end)

  it("主机操作：冻结提案、审批后 replay、拒绝不执行", function(t)
    local sandbox = require("NeoAI.sandbox")
    local hostop = require("NeoAI.sandbox.execution.hostop")
    with_config({ tools = { sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local control = require("NeoAI.sandbox.execution.control")
      control.reset()
      local attempt = control.new_attempt("run_command", { command = "echo HOST_OP_OK" }, {}, { effect = "process" })
      local rec = assert(hostop.freeze(attempt, { command = "echo HOST_OP_OK" }, { tier = 2 }, { reason = "test" }))
      t.not_nil(rec, "应冻结提案")
      local found
      for _, rev_item in ipairs(sandbox.list_reviews({ review_state = "PENDING" })) do
        if rev_item.kind == "host_op" and rev_item.host_op_id == rec.host_op_id then found = rev_item end
      end
      t.not_nil(found, "提案应进入待审队列")
      t.false_(sandbox.apply(found.change_set_id).ok, "未审批不应执行")
      sandbox.approve(found.change_set_id)
      local res = sandbox.apply(found.change_set_id)
      t.true_(res.ok, "审批后应执行成功")
      t.true_(res.result and tostring(res.result.stdout):find("HOST_OP_OK", 1, true) ~= nil, "应捕获主机输出")
      -- 拒绝不执行
      local rec2 = assert(hostop.freeze(attempt, { command = "echo SHOULD_NOT_RUN" }, { tier = 2 }, {}))
      local found2
      for _, rev_item in ipairs(sandbox.list_reviews({ review_state = "PENDING" })) do
        if rev_item.kind == "host_op" and rev_item.host_op_id == rec2.host_op_id then found2 = rev_item end
      end
      sandbox.reject(found2.change_set_id, "no")
      t.eq("REJECTED", assert(hostop.get(rec2.host_op_id)).state, "拒绝后提案应为 REJECTED")
    end)
  end)

  it("主机操作 replay：等待期间不冻结事件循环（UI 计时器可刷新）", function(t)
    local hostop = require("NeoAI.sandbox.execution.hostop")
    local store = require("NeoAI.sandbox.state.store")
    local saved_root = store.root()
    store.init(vim.fn.tempname() .. "-hostop-nonblock")
    hostop.reset()
    store.write_host_op({
      host_op_id = "ho_nonblock", command = "sleep 0.4; echo TICK_OK",
      tool = "run_command", command_id = "c_nb", attempt_id = "a_nb", tier = 2,
      state = "PENDING", created_at = os.time(),
    })
    local ticked = false
    local timer = vim.fn.timer_start(100, function() ticked = true end, vim.empty_dict())
    local res = hostop.replay("ho_nonblock")
    pcall(vim.fn.timer_stop, timer)
    t.true_(res.ok, "replay 应成功")
    t.true_(ticked, "等待主机命令期间事件循环应继续运行（计时器已触发）")
    t.true_(tostring(res.result and res.result.stdout or ""):find("TICK_OK", 1, true) ~= nil, "应捕获主机输出")
    hostop.reset()
    if saved_root then store.init(saved_root) else store.reset() end
  end)

  it("主机操作：T2 命令自动冻结主机提案", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local sandbox = require("NeoAI.sandbox")
    with_config({
      tools = {
        approval = { mode = "async" },
        sandbox = { mode = "dry_run", review = { enabled = true }, privilege = { max_tier = 2 } },
      },
    }, function()
      sandbox.reset()
      local done = false
      -- 用真正的 T2 命令（只读的 `mount`/`mount --version` 已不再触发 T2）。
      require("NeoAI.tools").execute("run_command", { command = "umount /mnt", description = "t" }, {})
        :then_(function() done = true end, function() done = true end)
      t.true_(vim.wait(12000, function() return done end), "命令应完成")
      t.true_(#require("NeoAI.sandbox.execution.hostop").list({}) >= 1, "T2 命令应冻结主机提案")
    end)
  end)

  it("缺 root：非 root 载荷权限不足时显式冻结 root 请求（hostop）", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local sandbox = require("NeoAI.sandbox")
    local hostop = require("NeoAI.sandbox.execution.hostop")
    local saved = runtime.payload_nonroot
    ---@diagnostic disable-next-line: duplicate-set-field
    runtime.payload_nonroot = function() return true end
    with_config({
      tools = {
        approval = { mode = "async" },
        sandbox = {
          mode = "dry_run", review = { enabled = true },
          privilege = { auto_escalate = false },
        },
      },
    }, function()
      sandbox.reset()
      local done = false
      -- 权限不足（exit 1 + permission denied）且不自动提权：应显式生成 root 请求而非静默失败。
      require("NeoAI.tools").execute("run_command", {
        command = "echo 'permission denied' >&2; exit 1", description = "t",
      }, {}):then_(function() done = true end, function() done = true end)
      t.true_(vim.wait(12000, function() return done end), "命令应完成")
      local found = false
      for _, h in ipairs(hostop.list({}) or {}) do
        if h.reason == "ROOT_REQUIRED" then found = true end
      end
      t.true_(found, "缺 root 且权限不足应显式生成 ROOT_REQUIRED 主机提案")
    end)
    runtime.payload_nonroot = saved
    sandbox.reset()
  end)

  it("缺 root：有 root 时权限不足不生成 root 请求（避免误报）", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local sandbox = require("NeoAI.sandbox")
    local hostop = require("NeoAI.sandbox.execution.hostop")
    local saved = runtime.payload_nonroot
    ---@diagnostic disable-next-line: duplicate-set-field
    runtime.payload_nonroot = function() return false end
    with_config({
      tools = {
        approval = { mode = "async" },
        sandbox = {
          mode = "dry_run", review = { enabled = true },
          privilege = { auto_escalate = false },
        },
      },
    }, function()
      sandbox.reset()
      local done = false
      require("NeoAI.tools").execute("run_command", {
        command = "echo 'permission denied' >&2; exit 1", description = "t",
      }, {}):then_(function() done = true end, function() done = true end)
      t.true_(vim.wait(12000, function() return done end), "命令应完成")
      for _, h in ipairs(hostop.list({}) or {}) do
        t.true_(h.reason ~= "ROOT_REQUIRED", "有 root 时不应生成 ROOT_REQUIRED 提案")
      end
    end)
    runtime.payload_nonroot = saved
    sandbox.reset()
  end)

  it("隐匿：输出脱敏抹去 bwrap/overlay/沙箱指纹", function(t)
    local conceal = require("NeoAI.sandbox.observe.conceal")
    local s = conceal.redact("bwrap --unshare-all NeoAI-sandbox /tmp/.neoai_session "
      .. "lowerdir=/dev/shm/x upperdir=/y workdir=/z type overlay; overlay on /root type overlay")
    t.true_(s:find("bwrap", 1, true) == nil, "不应残留 bwrap")
    t.true_(s:find("NeoAI-sandbox", 1, true) == nil, "不应残留 NeoAI-sandbox")
    t.true_(s:find("neoai_session", 1, true) == nil, "不应残留 neoai_session")
    t.true_(s:find("lowerdir=/dev/shm/x", 1, true) == nil, "应隐藏 lowerdir 路径")
    t.true_(s:find("type overlay", 1, true) == nil, "应隐藏 overlay 挂载类型")
    t.true_(s:find("overlay on", 1, true) == nil, "应隐藏 mount 的 overlay 前缀")
    t.eq("", conceal.redact(""), "空串原样返回")
    t.eq(nil, conceal.redact(nil), "nil 原样返回")
    -- 只读/降级措辞不暴露给模型：内核 EROFS 文案改写为普通权限错误。
    local ro = conceal.redact("touch: cannot touch '/x': Read-only file system")
    t.true_(ro:find("Read-only", 1, true) == nil, "不应残留 Read-only file system")
    t.matches("Permission denied", ro)
    t.true_(conceal.redact("挂载为只读"):find("只读", 1, true) == nil, "不应残留中文只读字样")
  end)

  it("隐匿：run_command 回传输出经脱敏且 PID1 非 bwrap", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local done = false
      require("NeoAI.tools").execute("run_command", {
        command = "echo NeoAI-sandbox bwrap; tr '\\0' ' ' < /proc/1/cmdline; echo",
        description = "t",
      }, {}):then_(function(r)
        local s = tostring(r)
        t.true_(not s:find("NeoAI-sandbox", 1, true), "输出不应含 NeoAI-sandbox")
        t.true_(not s:find("bwrap", 1, true), "输出不应含 bwrap")
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(15000, function() return done end), "run_command 应完成")
    end)
  end)

  it("密钥防护：熵检测与 token 往返", function(t)
    local secret = require("NeoAI.sandbox.secret.secret")
    secret.reset()
    local fake = "sk-Ab3xY9pQ2mNv7Kd4Lw8Zr1Tg6Hs5"
    local found = secret.detect("KEY=" .. fake .. " end")
    t.eq(1, #found, "应检测到 1 个高熵候选")
    t.eq(fake, found[1].value)
    -- 纯小写十六进制（git sha/sha256）不应被当作密钥
    t.eq(0, #secret.detect("sha=a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"))
    local tok, used = secret.tokenize("v=" .. fake)
    t.true_(#used == 1, "应生成 1 个 token")
    t.true_(secret.has_token(tok), "结果应含 token")
    t.true_(not secret.find_real_secret(tok), "token 化后不应含原始密钥")
    local back, unresolved = secret.detokenize(tok)
    t.eq("v=" .. fake, back, "应可无损还原")
    t.eq(0, unresolved, "应全部解析")
    -- 热重载后残留的假密钥（映射缺失）应计为 unresolved（fail-closed）
    secret.load_stale_fakes({ "NEOKEY_deadbeef" })
    local _, u2 = secret.detokenize("NEOKEY_deadbeef")
    t.eq(1, u2, "未知/残留假密钥应计为 unresolved")
    secret.reset()
  end)

  it("密钥防护：缩小认定范围（内容哈希/base64 不 token 化，上下文仍认定）", function(t)
    local secret = require("NeoAI.sandbox.secret.secret")
    secret.reset()
    -- SRI integrity / 内容哈希：即便含 `-`，也不应被 token 化（否则破坏 package-lock.json）
    local sri = '"integrity": "sha512-9BvYg0kq3s0mC1uQ0m5r8pQ2xY6wZ1aB3cD4eF5gH6iJ7kL8mN9oP0qR1sT2uV3wX4yZ5a6b7c8d9e0f1g2h=="'
    t.eq(sri, (secret.tokenize(sri)), "SRI integrity 不应被 token 化")
    t.eq(0, #secret.detect(sri), "SRI integrity 不应被识别为密钥")
    local sha = "sha256-a1b2c3d4e5f60718293a4b5c6d7e8f9012345678abcdef"
    t.eq(sha, (secret.tokenize(sha)), "带算法前缀的哈希不应被 token 化")
    -- 无分隔符的裸高熵串（base64/随机）不再视为密钥
    local bare = "blob Zx9Qw2Lm7Pk4Rt8Yv3Bn6Hd1Sg5Jf0Ac end"
    t.eq(bare, (secret.tokenize(bare)), "无上下文的裸高熵串不应被 token 化")
    t.eq(0, #secret.detect(bare), "无上下文的裸高熵串不应被识别")
    -- 敏感变量名上下文仍认定（纯字母数字值也 token 化）
    local ctx = "API_KEY=Zx9Qw2Lm7Pk4Rt8Yv3Bn6Hd1Sg5Jf0Ac"
    local out, used = secret.tokenize(ctx)
    t.true_(#used == 1, "敏感名赋值应被 token 化")
    t.eq(ctx, (secret.detokenize(out)), "上下文密钥应可无损还原")
    -- 密钥形态（含分隔符）仍认定
    local key = "sk-Ab3xY9pQ2mNv7Kd4Lw8Zr1Tg6Hs5"
    t.true_(secret.has_token((secret.tokenize(key))), "带分隔符的密钥形态仍应被 token 化")
    secret.reset()
  end)

  it("密钥防护：代码标识符（snake_case 函数名/常量）不被误判为密钥", function(t)
    local secret = require("NeoAI.sandbox.secret.secret")
    secret.reset()
    -- 工具输出里的 Python 回溯函数名不应被 token 化（否则污染模型可见结果）
    local tb = 'File "/x/urllib3/util/ssl_.py", line 220, in create_urllib3_context'
    t.eq(tb, (secret.tokenize(tb)), "回溯函数名不应被 token 化")
    t.eq(0, #secret.detect(tb), "回溯函数名不应被识别为密钥")
    local const = "HTTP_SSL_CONTEXT_V2_API"
    t.eq(const, (secret.tokenize(const)), "全大写常量名不应被 token 化")
    -- 软件包名/版本串（含纯数字段）不应被 token 化（dpkg -l 输出误报回归）
    for _, pkg in ipairs({
      "openjdk-21-jdk-headless", "openjdk-21-jre-headless", "libssl-dev", "libapache-pom-java",
      "python3.11-minimal", "golang-1.21", "nodejs-18", "libx264-164",
    }) do
      t.eq(pkg, (secret.tokenize(pkg)), "软件包名不应被 token 化: " .. pkg)
      t.eq(0, #secret.detect(pkg), "软件包名不应被识别为密钥: " .. pkg)
    end
    -- 真正的密钥形态（混合大小写 + 分隔符）仍应被 token 化
    local key = "sk-Ab3xY9pQ2mNv7Kd4Lw8Zr1Tg6Hs5"
    t.true_(secret.has_token((secret.tokenize(key))), "混合大小写密钥形态仍应被 token 化")
    -- 敏感变量名上下文中的小写值仍强制脱敏
    local ctx = "API_KEY=my_lowercase_secret_value_1234"
    t.true_(secret.has_token((secret.tokenize(ctx))), "敏感名上下文仍应脱敏")
    secret.reset()
  end)

  it("密钥防护：路径分量不被 token 化（不破坏 PATH/LD_LIBRARY_PATH/pip）", function(t)
    local secret = require("NeoAI.sandbox.secret.secret")
    secret.reset()
    -- 路径中的高熵目录段不应被 token 化，否则程序找不到库/模块（如 pip 报 ssl module 缺失）
    local path = "/opt/build_0abc123def456789abcdef/lib"
    t.eq(path, (secret.tokenize(path)), "路径分量不应被 token 化")
    local list = "/opt/lib:/secret_abc123def4567890abcdef"
    t.eq(list, (secret.tokenize(list)), "路径列表不应被 token 化")
    -- URL 中的结构化凭据仍应脱敏
    local url = "https://user:sk-Ab3xY9pQ2mNv7Kd4Lw8Zr1Tg6Hs5@host/simple"
    t.true_(secret.has_token((secret.tokenize(url))), "URL 中的凭据仍应被 token 化")
    -- 路径类环境变量（LD_LIBRARY_PATH / CA bundle）不应被覆盖
    vim.env.NEOAI_TEST_LD_LIBRARY_PATH = path
    vim.env.NEOAI_TEST_CA_BUNDLE = "/etc/ssl/certs/build_0abc123def456789abcdef.pem"
    local ov = secret.sanitized_env()
    t.eq(nil, ov.NEOAI_TEST_LD_LIBRARY_PATH, "路径类环境变量不应被 token 化")
    t.eq(nil, ov.NEOAI_TEST_CA_BUNDLE, "证书路径不应被 token 化")
    vim.env.NEOAI_TEST_LD_LIBRARY_PATH = nil
    vim.env.NEOAI_TEST_CA_BUNDLE = nil
    secret.reset()
  end)

  it("密钥防护：高熵扫描按密钥文件门控（entropy=false 仅保留具名规则）", function(t)
    local secret = require("NeoAI.sandbox.secret.secret")
    secret.reset()
    -- 不匹配任何具名规则的高熵密钥形态串（仅靠熵检测命中）
    local key = "Zx9Kd-Qm2Lp5Zr8Tv1Wn4Bc"
    t.true_(secret.has_token((secret.tokenize(key))), "默认应做熵扫描")
    t.eq(key, (secret.tokenize(key, { entropy = false })), "关闭熵扫描后高熵串应原样保留")
    local aws = "AKIAIOSFODNN7EXAMPLE"
    t.true_(secret.has_token((secret.tokenize(aws, { entropy = false }))), "具名规则不受熵开关影响")
    local out = secret.tokenize_result({ output = key, id = aws }, { entropy = false })
    t.eq(key, out.output, "结果字段高熵串不应 token 化")
    t.true_(secret.has_token(out.id), "结果字段具名规则仍 token 化")
    secret.reset()
  end)

  it("密钥防护：普通文件不做高熵 token 化，疑似密钥文件才做", function(t)
    local fs = require("NeoAI.utils.fs")
    local secret = require("NeoAI.sandbox.secret.secret")
    secret.reset()
    local key = "Zx9Kd-Qm2Lp5Zr8Tv1Wn4Bc"
    local plain = "/tmp/neoai_entropy_plain.txt"
    local envf = "/tmp/.env"
    fs.write_file(plain, "value " .. key .. "\n")
    fs.write_file(envf, "value " .. key .. "\n")
    local function read(p)
      local done, res = false, nil
      require("NeoAI.tools").execute("read_file", { file_path = p, description = "t" }, {})
        :then_(function(r) res = tostring(r); done = true end,
          function(e) res = "ERR:" .. tostring(e and e.message or e); done = true end)
      t.true_(vim.wait(10000, function() return done end), "read_file 应完成")
      return res
    end
    local r1 = assert(read(plain))
    t.true_(r1:find(key, 1, true) ~= nil, "普通文件高熵串应原样返回，实际: " .. tostring(r1))
    local r2 = assert(read(envf))
    t.true_(secret.has_token(r2), "疑似密钥文件高熵串应被 token 化，实际: " .. tostring(r2))
    fs.delete_file(plain)
    fs.delete_file(envf)
    secret.reset()
  end)

  it("密钥防护：疑似密钥文件路径判定（shell rc / 历史 / /etc）", function(t)
    local secret = require("NeoAI.sandbox.secret.secret")
    t.true_(secret.is_secret_path("/root/.bashrc"), ".bashrc 应视为密钥文件")
    t.true_(secret.is_secret_path("/root/.zshrc"), ".zshrc 应视为密钥文件")
    t.true_(secret.is_secret_path("/root/.bash_history"), "历史文件应视为密钥文件")
    t.true_(secret.is_secret_path("/etc/shadow"), "/etc 下应视为密钥文件")
    t.true_(secret.is_secret_path("/etc/ssh/sshd_config"), "/etc 下应视为密钥文件")
    t.false_(secret.is_secret_path("/tmp/notes.txt"), "普通文件不应视为密钥文件")
    -- 公开 CA 证书包（pip/certifi、系统信任库）不是密钥，不应触发高熵扫描
    t.false_(secret.is_secret_path(
      "/root/test/python-app/.venv/lib/python3.13/site-packages/pip/_vendor/certifi/cacert.pem"),
      "certifi CA bundle 不应视为疑似密钥文件")
  end)

  it("密钥防护：哈希/校验和文件与 .shada 不视为密钥", function(t)
    local secret = require("NeoAI.sandbox.secret.secret")
    -- 哈希/校验和清单、Neovim 状态转储（.shada）、git 对象库：非凭据，
    -- 既不应触发高熵扫描，也不应触发「获取密钥」告警。
    for _, p in ipairs({
      "/root/.local/state/nvim/shada/main.shada",
      "/root/.local/state/nvim/shada/main.shada.tmp",
      "/root/.local/share/nvim/shada/main.shada",
      "/repo/SHA256SUMS", "/repo/SHA512SUMS", "/repo/MD5SUMS", "/repo/CHECKSUMS",
      "/repo/pkg.tar.gz.sha256", "/repo/pkg.zip.sha512", "/repo/pkg.md5",
      "/repo/pkg.sha256sum", "/repo/pkg.md5sum",
      "/repo/.git/objects/ab/cdef0123456789abcdef0123456789abcdef01",
    }) do
      t.false_(secret.is_secret_path(p), "非凭据文件不应视为疑似密钥文件: " .. p)
      t.false_(secret.is_sensitive_path(p), "非凭据文件不应触发获取密钥告警: " .. p)
    end
    -- 生成式密钥扫描也跳过非凭据文件：即便内部含含 `-`/`_` 的高熵片段（如 base64url 寄存器）也不告警。
    local flags = secret.detect_generated({
      { path = "/root/.local/state/nvim/shada/main.shada",
        content = "reg eyJhbGciOiJIUzI1NiJ9-abc_DEF-1234567890abcdefghij mm" },
      { path = "/repo/SHA256SUMS",
        content = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678abcdef0123456789abcdef01  f.tar.gz" },
    })
    t.eq(0, #flags, "非凭据文件不应被生成式密钥扫描命中")
    -- 但真正的敏感路径仍应命中（回归保护）
    t.true_(secret.is_sensitive_path("/root/.ssh/id_rsa"), "id_rsa 仍应视为凭据文件")
  end)

  it("密钥防护：告警严口径路径判定（排除普通系统文件/历史）", function(t)
    local secret = require("NeoAI.sandbox.secret.secret")
    -- 真正的凭据文件
    for _, p in ipairs({
      "/root/.ssh/id_rsa", "/root/.aws/credentials", "/root/.config/gcloud/application_default_credentials.json",
      "/root/.kube/config", "/proj/.env", "/proj/.env.local", "/x/server.key",
      "/etc/shadow", "/etc/sudoers", "/etc/ssh/sshd_config", "/etc/apt/trusted.gpg.d/x.gpg",
      "/root/.local/share/keyrings/login.keyring",
    }) do
      t.true_(secret.is_sensitive_path(p), "应视为凭据文件: " .. p)
    end
    -- 普通命令频繁打开、并非密钥的路径（误报来源）
    for _, p in ipairs({
      "/etc/ld.so.cache", "/etc/nsswitch.conf", "/etc/passwd", "/etc/group",
      "/etc/os-release", "/etc/localtime", "/etc/ssl/openssl.cnf",
      "/usr/local/go/go.env", "/etc/rustup/settings.toml", "/root/.npmrc",
      "/root/.bash_history", "/root/.python_history", "/tmp/notes.txt",
      -- 公开 CA 证书包（pip 随包 vendored 的 certifi、系统信任库）不是凭据
      "/root/test/python-app/.venv/lib/python3.13/site-packages/pip/_vendor/certifi/cacert.pem",
      "/etc/ssl/certs/ca-certificates.pem",
      "/usr/lib/python3/dist-packages/certifi/cacert.pem",
      -- 系统 CA 包（Debian/Ubuntu `/usr/lib/ssl/cert.pem`、`/etc/ssl/certs/ca-certificates.crt`）
      "/usr/lib/ssl/cert.pem",
      "/etc/ssl/certs/ca-certificates.crt",
      "/etc/pki/tls/certs/ca-bundle.crt",
      -- 第三方包缓存/vendored 源码树中的测试夹具（cargo check 等会大量打开）
      "/root/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/openssl-0.10.81/test/key.pem",
      "/root/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/openssl-0.10.81/test/intermediate-ca.key",
      "/root/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/tokio-native-tls-0.3.1/tests/identity.p12",
      "/proj/node_modules/foo/test/server.key",
      "/root/.venv/lib/python3.13/site-packages/pkg/test/id_rsa",
    }) do
      t.false_(secret.is_sensitive_path(p), "不应视为凭据文件: " .. p)
    end
  end)

  it("密钥防护：工具结果中的原始密钥被 token 化", function(t)
    local secret = require("NeoAI.sandbox.secret.secret")
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    secret.reset()
    local fake = "sk-Ab3xY9pQ2mNv7Kd4Lw8Zr1Tg6Hs5"
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local done = false
      require("NeoAI.tools").execute("run_command", {
        command = "printf '%s\\n' '" .. fake .. "'",
        description = "t",
      }, {}):then_(function(r)
        local s = tostring(r)
        t.true_(not s:find(fake, 1, true), "模型可见输出不应含原始密钥")
        t.true_(secret.has_token(s), "模型可见输出应含 token")
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(15000, function() return done end), "run_command 应完成")
    end)
    secret.reset()
  end)

  it("密钥防护：工具参数出现原始密钥时硬拦截并终止 Agent", function(t)
    local secret = require("NeoAI.sandbox.secret.secret")
    secret.reset()
    local fake = "sk-Ab3xY9pQ2mNv7Kd4Lw8Zr1Tg6Hs5"
    secret.tokenize(fake)
    local abort_reason
    local agent = {
      id = "a_secret_test",
      signal = {
        abort = function(_, r) abort_reason = r end,
        reason = function() return abort_reason end,
        aborted = function() return abort_reason ~= nil end,
      },
    }
    local done = false
    -- 关闭告警弹窗：无 UI 确认时按 fail-closed 立即硬拦截。
    with_config({ tools = { sandbox = { secrets = { alert = { enabled = false } } } } }, function()
      require("NeoAI.tools").execute("run_command", {
        command = "echo " .. fake,
        description = "t",
      }, { agent = agent }):then_(function()
        t.true_(false, "含原始密钥的调用应被拒绝")
        done = true
      end, function(e)
        t.matches("SANDBOX_SECRET_BLOCKED", tostring(e and e.message or e))
        t.eq("secret_exposure", abort_reason, "应立即终止整个 Agent")
        done = true
      end)
      t.true_(vim.wait(5000, function() return done end), "应快速拒绝")
    end)
    secret.reset()
  end)

  it("密钥防护：AI 上下文出现原始密钥时终止 Agent（token 不终止）", function(t)
    local secret = require("NeoAI.sandbox.secret.secret")
    secret.reset()
    local fake = "sk-Ab3xY9pQ2mNv7Kd4Lw8Zr1Tg6Hs5"
    local tok = secret.tokenize(fake)
    t.true_(secret.has_token(tok), "应生成 token")
    local recovery = require("NeoAI.core.agent.recovery")
    local abort_reason
    local agent = {
      id = "a_ctx_secret",
      signal = {
        abort = function(_, r) abort_reason = r end,
        reason = function() return abort_reason end,
        aborted = function() return abort_reason ~= nil end,
      },
    }
    -- 原始密钥出现在 AI 可见上下文（wire 消息）→ 无告警 UI 时 fail-closed 终止 Agent
    with_config({ tools = { sandbox = { secrets = { alert = { enabled = false } } } } }, function()
      local ok, err = recovery._guard_secret_context(agent,
        { { role = "assistant", content = "KEY=" .. fake } })
      t.false_(ok, "上下文含原始密钥应被拒绝")
      t.matches("SANDBOX_SECRET_BLOCKED", tostring(err and err.message or err))
      t.eq("secret_exposure", abort_reason, "应终止整个 Agent")
      -- 假密钥（已知遮蔽值）出现在上下文不终止
      t.true_(recovery._guard_secret_context(agent,
        { { role = "assistant", content = "KEY=" .. tok } }), "假密钥不应终止 Agent")
    end)
    secret.reset()
  end)

  it("密钥防护：KEY 环境变量 token 操作只提级审批、不终止", function(t)
    local secret = require("NeoAI.sandbox.secret.secret")
    secret.reset()
    local fake = "sk-Ab3xY9pQ2mNv7Kd4Lw8Zr1Tg6Hs5"
    local tok = secret.tokenize(fake)
    local ctx = {}
    local done = false
    require("NeoAI.tools").execute("read_file", {
      file_path = "/nonexistent/" .. tok, description = "t",
    }, ctx):then_(function() done = true end, function() done = true end)
    t.true_(vim.wait(5000, function() return done end), "应完成")
    t.eq(true, ctx.secret_operation, "token 操作应提级审批（secret_operation），而非终止")
    secret.reset()
  end)

  it("密钥防护：commit 发布时把 token 还原为真实密钥并留痕警告", function(t)
    local secret = require("NeoAI.sandbox.secret.secret")
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    secret.reset()
    local fake = "sk-Ab3xY9pQ2mNv7Kd4Lw8Zr1Tg6Hs5"
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local p = dir .. "/cfg.env"
    with_config({ tools = { approval = { mode = "async" }, sandbox = { mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local done = false
      require("NeoAI.tools").execute("edit_file", {
        file_path = p, mode = "write", content = "KEY=" .. fake .. "\n", description = "t",
      }, {}):then_(function()
        local items = sandbox.list_reviews({ review_state = "PENDING" })
        local found
        for _, rev_item in ipairs(items) do
          for _, f in ipairs(rev_item.files or {}) do if f.path == p then found = rev_item end end
        end
        t.not_nil(found, "应产生待审变更单元")
        t.true_(found.secret_warning and found.secret_warning.count > 0, "应带密钥操作警告")
        local res = sandbox.apply(found.change_set_id, { auto_approve = true })
        t.true_(res.ok, tostring(res.reason))
        local content = fs.read_file(p) or ""
        t.true_(content:find(fake, 1, true) ~= nil, "真实文件应还原为原始密钥")
        t.true_(not secret.has_token(content), "真实文件不应残留 token")
        done = true
      end, function(e)
        t.true_(false, "不应失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(5000, function() return done end), "edit_file 应完成")
    end)
    vim.fn.delete(dir, "rf")
    secret.reset()
  end)

  it("密钥防护：run_command 环境变量中的密钥被替换为 token", function(t)
    local secret = require("NeoAI.sandbox.secret.secret")
    secret.reset()
    local fake = "sk-Ab3xY9pQ2mNv7Kd4Lw8Zr1Tg6Hs5"
    vim.env.NEOAI_TEST_API_KEY = fake
    local overrides = secret.sanitized_env()
    t.true_(overrides.NEOAI_TEST_API_KEY ~= nil, "应覆盖该环境变量")
    t.true_(not tostring(overrides.NEOAI_TEST_API_KEY):find(fake, 1, true), "覆盖值不应含原始密钥")
    vim.env.NEOAI_TEST_API_KEY = nil
    secret.reset()
  end)

  it("密钥防护：纯 hex 密钥按变量名强制 token 化", function(t)
    local secret = require("NeoAI.sandbox.secret.secret")
    secret.reset()
    local hexkey = "dfe946fb66864c48927f31f2aa49164d"
    vim.env.NEOAI_TEST_GLM_API_KEY = hexkey
    local overrides = secret.sanitized_env()
    t.true_(overrides.NEOAI_TEST_GLM_API_KEY ~= nil, "纯 hex 的 *_API_KEY 也应被覆盖")
    t.true_(not tostring(overrides.NEOAI_TEST_GLM_API_KEY):find(hexkey, 1, true), "覆盖值不应含原始密钥")
    vim.env.NEOAI_TEST_PLAIN = "hello"
    local ov2 = secret.sanitized_env()
    t.eq(nil, ov2.NEOAI_TEST_PLAIN, "普通低熵变量不应被 token 化")
    vim.env.NEOAI_TEST_GLM_API_KEY = nil
    vim.env.NEOAI_TEST_PLAIN = nil
    secret.reset()
  end)

  it("密钥防护：沙箱进程拿到真实密钥（env + 命令 token 还原，仅限沙箱内）", function(t)
    local secret = require("NeoAI.sandbox.secret.secret")
    local runtime = require("NeoAI.sandbox.execution.runtime")
    secret.reset()
    local fake = "sk-Ab3xY9pQ2mNv7Kd4Lw8Zr1Tg6Hs5"
    -- 环境变量：sanitized_env 给 token（AI/日志面），sandbox_env 还原真实值（沙箱进程面）
    vim.env.NEOAI_TEST_REPL_KEY = fake
    local sanitized = secret.sanitized_env()
    t.true_(secret.has_token(sanitized.NEOAI_TEST_REPL_KEY), "sanitized_env 应为 token")
    local env = runtime.sandbox_env(nil)
    t.eq(fake, env.NEOAI_TEST_REPL_KEY, "sandbox_env 应还原真实密钥")
    vim.env.NEOAI_TEST_REPL_KEY = nil
    if runtime.backend() ~= "bwrap" then secret.reset(); return end
    -- 命令参数中的假密钥：沙箱内应还原为真实密钥（用 sha256 观测，避免长度相同无法区分）
    local tok = secret.tokenize(fake)
    with_config({ tools = { approval = { mode = "auto_allow" }, sandbox = { mode = "dry_run" } } }, function()
      local done, out = false, nil
      require("NeoAI.tools").execute("run_command", {
        command = "printf '%s' '" .. tok .. "' | sha256sum", description = "t",
      }, {}):then_(function(r)
        out = tostring(r)
        done = true
      end, function(e)
        out = "ERR:" .. tostring(e and e.message or e)
        done = true
      end)
      t.true_(vim.wait(15000, function() return done end), "run_command 应完成")
      local want = vim.fn.sha256(fake)
      t.true_(out ~= nil and out:find(want, 1, true) ~= nil,
        "命令应拿到真实密钥（sha256 " .. want .. "，实际: " .. tostring(out) .. "）")
    end)
    secret.reset()
  end)

  it("AppImage：沙箱环境注入 APPIMAGE_EXTRACT_AND_RUN（可配置关闭）", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    local env = runtime.sandbox_env(nil)
    t.eq("1", env.APPIMAGE_EXTRACT_AND_RUN, "默认应注入 extract-and-run，避免沙箱内 FUSE 挂载")
    with_config({ tools = { sandbox = { appimage_extract_and_run = false } } }, function()
      local env2 = runtime.sandbox_env(nil)
      t.nil_(env2.APPIMAGE_EXTRACT_AND_RUN, "关闭配置后不应注入")
    end)
  end)

  it("密钥防护：文本层按变量名强制脱敏（纯 hex / 含点号多段密钥）", function(t)
    local secret = require("NeoAI.sandbox.secret.secret")
    secret.reset()
    -- 复现日志泄露：GLM_API_KEY 值 = 纯小写 hex + `.` + 无数字段，熵检测会漏
    -- （hex 段被 exclude_pure_hex 排除，另一段因无数字不满足候选条件）。
    local raw = "dfe946fb66864c48927f31f2aa49164d.rwbWDAfnQjlHuMFt"
    local line = "GLM_API_KEY=" .. raw
    local out = secret.tokenize(line)
    t.true_(not out:find(raw, 1, true), "按变量名应强制 token 化，实际: " .. out)
    t.true_(not out:find("dfe946fb", 1, true), "纯 hex 段也不应泄露")
    t.true_(secret.has_token(out), "应回传假密钥")
    local back, unresolved = secret.detokenize(out)
    t.eq(line, back, "应可无损还原")
    t.eq(0, unresolved, "应全部解析")
    -- JSON 风格键值同样按名脱敏，且保留键结构
    local j = secret.tokenize('{"PASSWORD": "hunter2"}')
    t.true_(not j:find("hunter2", 1, true), "JSON 值应脱敏")
    t.matches('"PASSWORD"', j, "应保留键结构")
    t.eq('{"PASSWORD": "hunter2"}', (secret.detokenize(j)), "JSON 应无损还原")
    -- 非敏感名 + 纯 hex 仍不误报（保持既有行为）
    local sha = "sha=a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
    t.eq(sha, (secret.tokenize(sha)), "非敏感名不应被 token 化")
    secret.reset()
  end)

  it("密钥防护：代码表达式（NAME = os.getenv(...)）不被误判为原始密钥", function(t)
    local secret = require("NeoAI.sandbox.secret.secret")
    secret.reset()
    local code = table.concat({
      "local function ai_config()",
      '  local api_key = os.getenv("GIT_COMMIT_AI_API_KEY")',
      "  if not api_key then return nil end",
      "  return { api_key = api_key }",
      "end",
    }, "\n")
    local out, used = secret.tokenize(code)
    t.eq(code, out, "代码表达式不应被 token 化")
    t.eq(0, #used, "不应产生 token")
    t.nil_(secret.find_real_secret(code), "不应命中原始密钥（否则 edit_file 会被误终止）")
    t.nil_(secret.scan({ edits = { { old_text = "x", new_text = code } } }).secret, "扫描参数不应命中")
    -- 注释/文档中的 "Bearer token" 不应被当作凭据进入映射表
    local doc = "-- Bearer token required for auth"
    t.eq(doc, (secret.tokenize(doc)), "注释中的 Bearer 不应被 token 化")
    t.nil_(secret.find_real_secret(doc), "注释不应进入映射表")
    -- 真实 Bearer 凭据仍应被 token 化
    local hdr = "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV"
    t.true_(secret.has_token((secret.tokenize(hdr))), "真实 Bearer 凭据应被 token 化")
    secret.reset()
  end)

  it("密钥防护：赋值值不像凭据时不登记原始密钥（短值/普通单词/路径不误报）", function(t)
    local secret = require("NeoAI.sandbox.secret.secret")
    secret.reset()
    -- 源码/文档里的普通赋值不应登记为原始密钥，否则后续命令含该片段会被误拦截
    -- （回归：`'password': 'bar'`、`key_separator = "."`、`CONFIGFILE_KEY = 'pyproject.toml'`）。
    for _, s in ipairs({
      "{'username': 'foo', 'password': 'bar', 'host': 'bar.com'}",
      'child_node.key_separator = "."',
      "CONFIGFILE_KEY = 'pyproject.toml'",
      "METADATA_KEY = '__metadata__'",
    }) do
      local out, used = secret.tokenize(s)
      t.eq(s, out, "非凭据赋值不应被 token 化: " .. s)
      t.eq(0, #used, "非凭据赋值不应产生 token: " .. s)
    end
    t.nil_(secret.find_real_secret("pyproject.toml"), "普通文件名不应登记为原始密钥")
    -- 路径值（`*_KEY = /path`）不是凭据：登记后任何含该路径片段的命令都会被硬拦截。
    local path = "/root/test/apps/python/.venv"
    t.nil_(secret.find_real_secret(path), "路径不应登记为原始密钥")
    local cmd = "env | grep -i proxy; ls -la " .. path .. "/bin/python*"
    t.nil_(secret.scan({ command = cmd }).secret, "含普通路径的命令不应被判定为原始密钥")
    -- 相对/多段路径值同样不登记（如 `"cache_key": "bin/python"`），否则 `bin/python`
    -- 这类路径片段会命中 `.../.venv/bin/python*` 命令。
    for _, s in ipairs({
      '{"cache_key": "bin/python"}',
      'exec_key = apps/python/.venv',
    }) do
      local out, used = secret.tokenize(s)
      t.eq(s, out, "相对路径赋值不应被 token 化: " .. s)
      t.eq(0, #used, "相对路径赋值不应产生 token: " .. s)
    end
    t.nil_(secret.find_real_secret("bin/python"), "相对路径片段不应登记为原始密钥")
    -- 真正的凭据赋值仍应脱敏并可无损还原。
    local cred = '{"PASSWORD": "hunter2"}'
    local tok = secret.tokenize(cred)
    t.true_(not tok:find("hunter2", 1, true), "真实凭据赋值仍应 token 化")
    t.eq(cred, (secret.detokenize(tok)), "凭据赋值应无损还原")
    -- 敏感环境变量名扫描不应把 NeoAI 内部事件标识当作变量名。
    t.eq(0, #secret.scan_names({ "SANDBOX_SECRET_BLOCKED: 工具参数包含原始密钥，已终止 Agent" }),
      "内部事件标识不应被当作敏感环境变量名")
    t.true_(#secret.scan_names({ "AWS_SECRET_ACCESS_KEY=xxx" }) > 0, "真实敏感变量名仍应识别")
    secret.reset()
  end)

  it("密钥防护：环境变量名引用（api_key=DASHSCOPE_API_KEY）不登记、不终止 Agent", function(t)
    local secret = require("NeoAI.sandbox.secret.secret")
    secret.reset()
    -- 知识库案例回归：`api_key=DASHSCOPE_API_KEY` 的右值是**变量名引用**而非凭据值，不得登记为
    -- 原始密钥；否则同文件内裸变量名（`os.getenv('DASHSCOPE_API_KEY')` 等）会让请求前守卫
    -- 误命中并终止 Agent。
    local code = table.concat({
      "import os",
      "DASHSCOPE_API_KEY = os.getenv('DASHSCOPE_API_KEY')",
      "client = OpenAI(api_key=DASHSCOPE_API_KEY)",
    }, "\n")
    local out, used = secret.tokenize(code)
    t.eq(code, out, "变量名引用不应被 token 化")
    t.eq(0, #used, "变量名引用不应产生 token")
    t.nil_(secret.find_real_secret(code), "变量名引用不应登记为原始密钥")
    -- 监控保留：环境变量名仍由 scan_names 识别（软升级路径）。
    t.true_(vim.tbl_contains(secret.scan_names({ out }), "DASHSCOPE_API_KEY"),
      "环境变量名仍应被监控识别")
    -- 请求前守卫：上下文含该变量名不终止 Agent。
    local recovery = require("NeoAI.core.agent.recovery")
    local abort_reason
    local agent = {
      id = "a_env_name_ref",
      signal = {
        abort = function(_, r) abort_reason = r end,
        reason = function() return abort_reason end,
        aborted = function() return abort_reason ~= nil end,
      },
    }
    t.true_(recovery._guard_secret_context(agent, { { role = "user", content = out } }),
      "环境变量名不应终止 Agent")
    t.eq(nil, abort_reason, "不应触发 abort")
    secret.reset()
  end)

  it("密钥防护：环境变量密钥裸值兜底 token 化且不终止 Agent", function(t)
    local secret = require("NeoAI.sandbox.secret.secret")
    secret.reset()
    -- 纯 hex / 无具名前缀的环境变量密钥：处于非赋值上下文（知识库裸值）时熵检测不会覆盖，
    -- 必须由「已知环境变量密钥」兜底明文替换 token 化，否则 AI 上下文守卫会误判并终止。
    local hexkey = "dfe946fb66864c48927f31f2aa49164d"
    local otherkey = "6xYSL2abcdefghijklmnopqrstuvwxyz0123456789"
    vim.env.NEOAI_TEST_BARE_KEY = hexkey
    vim.env.NEOAI_TEST_PLAIN_KEY = otherkey
    local ov = secret.sanitized_env()
    t.true_(secret.is_env_secret(hexkey), "应登记为环境变量密钥（软信号）")
    t.true_(secret.has_token(ov.NEOAI_TEST_BARE_KEY), "环境变量覆盖值应为 token")
    -- 非赋值上下文的裸值（entropy=false，模拟普通文件）也必须被兜底 token 化。
    for _, raw in ipairs({ hexkey, otherkey }) do
      local out = secret.tokenize("处理案例裸值：\n" .. raw .. "\n", { entropy = false })
      t.true_(not out:find(raw, 1, true), "裸环境变量密钥不应原样回传: " .. out)
      t.true_(secret.has_token(out), "裸环境变量密钥应被替换为 token")
    end
    -- 异步（工作线程）路径同样兜底：不能因线程参数传递而漏掉。
    local done, res = false, nil
    secret.tokenize_async("值：" .. hexkey .. "\n", { entropy = false }):then_(function(v)
      res = v; done = true
    end, function() done = true end)
    t.true_(vim.wait(3000, function() return done end), "异步 token 化应完成")
    t.true_(res ~= nil and not res:find(hexkey, 1, true), "异步路径裸值也应 token 化")
    -- 请求前守卫：环境变量密钥值出现在上下文不终止 Agent。
    local recovery = require("NeoAI.core.agent.recovery")
    local abort_reason
    local agent = {
      id = "a_env_value",
      signal = {
        abort = function(_, r) abort_reason = r end,
        reason = function() return abort_reason end,
        aborted = function() return abort_reason ~= nil end,
      },
    }
    t.true_(recovery._guard_secret_context(agent, { { role = "tool", content = hexkey } }),
      "环境变量密钥值不应终止 Agent")
    t.eq(nil, abort_reason, "不应触发 abort")
    -- 非环境变量密钥仍应硬拦截（回归保护）。
    local fake = "sk-Ab3xY9pQ2mNv7Kd4Lw8Zr1Tg6Hs5"
    secret.tokenize(fake)
    t.not_nil(secret.context_leak({ { role = "tool", content = fake } }),
      "非环境变量原始密钥仍应命中")
    vim.env.NEOAI_TEST_BARE_KEY = nil
    vim.env.NEOAI_TEST_PLAIN_KEY = nil
    secret.reset()
  end)

end)
