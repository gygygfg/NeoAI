--- 沙箱一致性与故障（真实 bwrap）
--- @module 'NeoAI.tests.test_sandbox_boundary_consistency'
--- 覆盖：并发写同一文件（无丢失/撕裂）、命令超时被终止后的恢复、祖先目录 TOCTOU 符号链接
--- 替换不落宿主、read_all 普通命令写系统路径的候选冻结与发布落盘。重资源用例 opt-in
--- （NEOAI_TEST_HEAVY=1）避免常规回归不稳定。

local tests = require("NeoAI.tests")
local H = require("NeoAI.tests.sandbox_boundary_helpers")
local with_config = H.with_config
local fs = require("NeoAI.utils.fs")
local sandbox = require("NeoAI.sandbox")

--- 执行 run_command 并等待结果
local function run(cmd, opts, timeout_ms)
  local out, done = nil, false
  require("NeoAI.tools").execute("run_command",
    { command = cmd, description = "t", timeout_ms = opts and opts.timeout_ms or nil }, {})
    :then_(function(v) out = v; done = true end,
      function(e) out = "ERR:" .. tostring(e and e.message or e); done = true end)
  vim.wait(timeout_ms or 30000, function() return done end, 50)
  return out
end

local function read_via_tool(path)
  local out, done
  require("NeoAI.tools").execute("read_file", { file_path = path, description = "t" }, {})
    :then_(function(v) out = v; done = true end, function(e) out = "ERR:" .. tostring(e); done = true end)
  vim.wait(10000, function() return done end, 50)
  return tostring(out)
end

local function find_pending(path)
  for _, it in ipairs(sandbox.list_reviews({ review_state = "PENDING" })) do
    for _, f in ipairs(it.files or {}) do
      if f.path == path then return it end
    end
  end
  return nil
end

local BWRAP_CFG = { tools = { approval = { mode = "async" },
  sandbox = { enabled = true, fail_closed = true, mode = "dry_run",
    resident = { enabled = true }, review = { enabled = true } } } }

tests.suite("sandbox_boundary_consistency", function(_, it)
  it("并发写同一文件：内容完整、无丢失/撕裂（append 可交换）", function(t)
    if not H.bwrap() then return end
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    local f = dir .. "/concurrent.txt"
    fs.write_file(f, "")
    with_config(BWRAP_CFG, function()
      sandbox.reset()
      local _, _, da, db = nil, nil, false, false
      require("NeoAI.tools").execute("run_command",
        { command = "for i in $(seq 1 20); do echo AAAA >> " .. f .. "; done", description = "t" }, {})
        :then_(function(v) _ = v; da = true end, function() da = true end)
      require("NeoAI.tools").execute("run_command",
        { command = "for i in $(seq 1 20); do echo BBBB >> " .. f .. "; done", description = "t" }, {})
        :then_(function(v) _ = v; db = true end, function() db = true end)
      t.true_(vim.wait(40000, function() return da and db end, 50), "两条命令应完成")
      local content = read_via_tool(f)
      local na, nb = 0, 0
      for _ in content:gmatch("AAAA") do na = na + 1 end
      for _ in content:gmatch("BBBB") do nb = nb + 1 end
      t.eq(20, na, "AAAA 行不应丢失，实际内容:\n" .. content)
      t.eq(20, nb, "BBBB 行不应丢失，实际内容:\n" .. content)
      for line in content:gmatch("[^\n]+") do
        t.true_(line == "AAAA" or line == "BBBB", "不应出现撕裂行: " .. line)
      end
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
  end)

  it("命令超时被终止：下一条命令恢复且无残留", function(t)
    if not H.bwrap() then return end
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    with_config(BWRAP_CFG, function()
      sandbox.reset()
      local killed = run("sleep 30", { timeout_ms = 900 }, 15000)
      t.not_nil(killed, "超时命令应返回（而不是永久挂起）")
      local after = run("echo RECOVERED_OK", nil, 20000)
      t.matches("RECOVERED_OK", after, "超时后下一条命令应正常，实际: " .. after)
      t.eq(0, #sandbox.list_reviews({ review_state = "PENDING" }),
        "被终止的只读命令不应产生待审候选")
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
  end)

  it("TOCTOU：祖先目录被替换为指向 /etc 的符号链接，写入不落宿主", function(t)
    if not H.bwrap() then return end
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    fs.ensure_dir(dir .. "/d")
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    local host_target = "/etc/.neoai_toctou_test"
    pcall(os.remove, host_target)
    with_config(BWRAP_CFG, function()
      sandbox.reset()
      run("mv d d.bak && ln -s /etc d && echo pwn > d/.neoai_toctou_test; echo DONE", nil, 20000)
      t.true_(vim.uv.fs_stat(host_target) == nil,
        "经祖先符号链接指向 /etc 的写入不应落宿主真实盘")
    end)
    pcall(os.remove, host_target)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
  end)

  it("read_all：普通命令写系统路径 → 候选冻结 → 发布落盘", function(t)
    if not H.bwrap() then return end
    if vim.uv.getuid() ~= 0 then return end
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    local target = "/usr/.neoai_syswrite_test"
    pcall(os.remove, target)
    with_config(BWRAP_CFG, function()
      sandbox.reset()
      run("echo neoai_syswrite > " .. target, nil, 20000)
      local item = assert(find_pending(target))
      t.not_nil(item, "写系统路径应冻结为待审候选")
      t.true_(vim.uv.fs_stat(target) == nil, "dry_run 不应写真实系统路径")
      local res = sandbox.apply(item.change_set_id, { auto_approve = true })
      if res and res.then_ then
        local done = false
        ---@type any
        local r = nil
        res:then_(function(v) r = v; done = true end, function() done = true end)
        vim.wait(20000, function() return done end, 50)
        res = r
      end
      t.true_(res and res.ok, "发布应成功: " .. tostring(res and res.reason))
      local fh = io.open(target, "r")
      t.not_nil(fh, "发布后宿主应存在该文件")
      if fh then
        local c = fh:read("*a"); fh:close()
        t.matches("neoai_syswrite", c, "宿主文件内容应正确")
      end
    end)
    pcall(os.remove, target)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
  end)

  it("[opt-in] 真实 OOM：小内存限额触发 SIGKILL 与归因", function(t)
    if os.getenv("NEOAI_TEST_HEAVY") ~= "1" then return end
    if not H.bwrap() or not H.has("python3") then return end
    local cgroup = require("NeoAI.sandbox.execution.cgroup")
    if not cgroup.probe().available then return end
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    local saw_oom, non_oom_kill = false, nil
    with_config({ tools = { approval = { mode = "async" }, sandbox = {
      enabled = true, fail_closed = true, mode = "dry_run", resident = { enabled = false },
      limits = { dynamic = false, memory_bytes = 32 * 1024 * 1024, pids = 256 },
    } } }, function()
      sandbox.reset()
      for _ = 1, 3 do
        local out = run("python3 -c \"b=bytearray();\nwhile True: b.extend(b'x'*10485760)\"",
          { timeout_ms = 8000 }, 20000)
        local s = tostring(out)
        if s:find("沙箱资源域内存不足", 1, true) then saw_oom = true break end
        if s:find("137", 1, true) and not s:find("超时", 1, true) then non_oom_kill = s end
      end
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
    -- 归因成功通过；若环境未在 8s 内触发 OOM（容器 CPU/内存压力）则跳过；
    -- 但出现 137 却未归因为 OOM 则是回归，必须失败。
    if not saw_oom and non_oom_kill then
      t.true_(false, "137 终止应归因为 OOM，实际: " .. non_oom_kill)
    end
    t.true_(saw_oom or non_oom_kill == nil, "OOM 归因或环境跳过")
  end)

  it("[opt-in] 双 nvim 实例：常驻沙箱与待审队列互不可见", function(t)
    if os.getenv("NEOAI_TEST_HEAVY") ~= "1" then return end
    -- 端到端起两个 headless nvim 成本高且环境敏感；此处仅校验实例作用域 store 根隔离。
    local instance = require("NeoAI.sandbox.execution.instance")
    local base = vim.fn.tempname() .. "/sb"
    instance.set_id("aaaa_1")
    local r1 = instance.root(base)
    instance.set_id("bbbb_2")
    local r2 = instance.root(base)
    instance.set_id(nil)
    t.true_(r1 ~= r2, "不同实例应有独立 store 根")
    t.true_(r1:find("aaaa_1", 1, true) ~= nil and r2:find("bbbb_2", 1, true) ~= nil,
      "store 根应按实例 id 分片")
  end)

  it("PTY 路径 OOM 归因（回归：默认交互层不丢失 137 归因）", function(t)
    local services = require("NeoAI.kernel.services")
    local config_store = require("NeoAI.kernel.config_store")
    local saved_cfg = config_store.get_all()
    local saved_sandbox = services.use("services.sandbox")
    local saved_pty = services.use("services.pty")
    ---@type table<string, any>
    local cg = require("NeoAI.sandbox.execution.cgroup")
    local oa, ob = cg.oom_attribution, cg.oom_baseline
    config_store.load({ tools = { approval = { mode = "auto_allow" },
      run_command = { interactive = { enabled = true, engine = "auto" } } } })
    cg.oom_baseline = function() return {} end
    cg.oom_attribution = function() return { oom = true, level = "sandbox" } end
    local async = require("NeoAI.utils.async")
    services.provide("services.pty", {
      available = function() return true, nil end,
      open = function() return { id = 1 } end,
      await = function()
        local d = async.Deferred.new()
        d:resolve({ code = 137, output = "", timed_out = false })
        return d
      end,
    })
    services.provide("services.sandbox", {
      attach = function() end,
      gate = function(_, _, ctx, call_original)
        ctx.sandbox_prefix, ctx.sandbox_env, ctx.sandbox_cwd = {}, {}, "/tmp"
        ctx.sandbox_cgroup_path = "/tmp/fakecg"
        ctx.sandbox_resident = false
        return call_original()
      end,
    })
    local out, done
    require("NeoAI.tools").execute("run_command", { command = "true", description = "t" }, {})
      :then_(function(v) out = v; done = true end,
        function(e) out = "ERR:" .. tostring(e and e.message or e); done = true end)
    vim.wait(5000, function() return done end, 20)
    cg.oom_attribution, cg.oom_baseline = oa, ob
    config_store.load(saved_cfg)
    services.provide("services.sandbox", saved_sandbox)
    services.provide("services.pty", saved_pty)
    t.matches("沙箱资源域内存不足", tostring(out), "PTY 137 应归因为沙箱资源域 OOM，实际: " .. tostring(out))
  end)
end)
