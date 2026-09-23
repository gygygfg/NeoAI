--- 沙箱 systemd 门面入口与维护脚本兼容桩专项测试
--- @module NeoAI.tests.test_sandbox_maintscript
--- 覆盖：process_prefix 把极薄入口覆盖绑定到真实二进制路径、包安装注入 policy-rc.d；
--- 入口经文件 IPC 转发到 Lua 门面（stdout/stderr/退出码与真实 systemctl 一致）。

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

--- 从 process_prefix argv 中取绑定到某 guest 路径的宿主源（--ro-bind/--bind src dst）。
local function src_for(prefix, guest)
  for i, v in ipairs(prefix or {}) do
    if v == guest and i > 1 then return prefix[i - 1] end
  end
  return nil
end

tests.suite("sandbox_maintscript", function(_, it)
  it("privilege.resolve：包安装注入维护脚本桩，可配置关闭", function(t)
    local privilege = require("NeoAI.sandbox.privilege")
    with_config({ tools = { sandbox = { systemd = { maintscript_stubs = true } } } }, function()
      local r = privilege.resolve(1, { package = true, apt = true })
      t.true_(r.ok, "应解析成功")
      t.true_(r.privileges.maintscript_stubs == true, "包安装应注入维护脚本桩")
    end)
    with_config({ tools = { sandbox = { systemd = { maintscript_stubs = false } } } }, function()
      local r = privilege.resolve(1, { package = true, apt = true })
      t.true_(r.ok, "应解析成功")
      t.true_(r.privileges.maintscript_stubs ~= true, "关闭后不应注入")
    end)
    -- 非包安装不注入
    with_config({ tools = { sandbox = { systemd = { maintscript_stubs = true } } } }, function()
      local r = privilege.resolve(0, {})
      t.true_(r.ok, "应解析成功")
      t.true_(r.privileges.maintscript_stubs ~= true, "非包安装不应注入")
    end)
  end)

  it("process_prefix：入口覆盖绑定真实二进制路径（不再前置非标准 PATH）", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local prefix = runtime.process_prefix({
      cwd = "/tmp",
      privileges = { cap_add = {}, unmask = {}, mounts = {} },
    })
    t.not_nil(prefix, "应能构造前缀")
    local joined = table.concat(prefix, " ")
    t.true_(joined:find("/tmp/.dynbin", 1, true) == nil, "不应再前置 /tmp/.dynbin")
    local src = src_for(prefix, "/usr/bin/systemctl")
    t.not_nil(src, "应把入口绑定到 /usr/bin/systemctl")
    t.matches("/sd%-bin/systemctl$", src, "入口源应为生成的 systemctl 桩")
    t.not_nil(src_for(prefix, "/usr/bin/journalctl"), "应绑定 journalctl 入口")
    local ipc = require("NeoAI.sandbox.systemd_ipc")
    t.not_nil(src_for(prefix, ipc.guest_dir()), "应绑定 IPC 目录")
    -- 未标记包安装时不绑定 policy-rc.d
    t.true_(joined:find("/usr/sbin/policy-rc.d", 1, true) == nil, "未注入时不应绑定 policy-rc.d")

    local p2 = runtime.process_prefix({
      cwd = "/tmp",
      privileges = { maintscript_stubs = true, cap_add = {}, unmask = {}, mounts = {} },
    })
    t.not_nil(src_for(p2, "/usr/sbin/policy-rc.d"), "包安装应绑定 policy-rc.d")
  end)

  it("sandbox_env：不再注入非标准 PATH 项", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local env = runtime.sandbox_env({ maintscript_stubs = true })
    t.true_(tostring(env.PATH or ""):find("/tmp/.dynbin", 1, true) == nil, "不应出现 /tmp/.dynbin")
  end)

  it("入口语义：经 IPC 转发到 Lua 门面，stdout/stderr/退出码与真实 systemctl 一致", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local ipc = require("NeoAI.sandbox.systemd_ipc")
    local hostdir = ipc.ensure()
    local prefix = runtime.process_prefix({
      cwd = "/tmp",
      privileges = { cap_add = {}, unmask = {}, mounts = {} },
    })
    local src = src_for(prefix, "/usr/bin/systemctl")
    t.not_nil(src, "应能定位入口桩")
    -- policy-rc.d 语义
    local policy = src:gsub("/systemctl$", "/policy-rc.d")
    vim.fn.system({ policy })
    t.eq(101, vim.v.shell_error, "policy-rc.d 应退出 101")

    -- 把入口的 guest IPC 目录改写到宿主实际目录后执行，验证完整转发链路。
    local f = io.open(src, "rb")
    t.not_nil(f, "入口桩应可读")
    local raw = f:read("*a")
    f:close()
    raw = raw:gsub("/run/systemd/units", hostdir)
    local copy = vim.fn.tempname() .. "/systemctl"
    vim.fn.mkdir(vim.fn.fnamemodify(copy, ":h"), "p")
    local w = io.open(copy, "wb")
    w:write(raw)
    w:close()
    vim.uv.fs_chmod(copy, tonumber("0755", 8))

    local function run(args)
      local out, err, code, done = {}, {}, nil, false
      vim.fn.jobstart(vim.list_extend({ copy }, args), {
        stdout_buffered = false, stderr_buffered = false,
        on_stdout = function(_, d) if d and #d > 0 then out[#out + 1] = table.concat(d, "\n") end end,
        on_stderr = function(_, d) if d and #d > 0 then err[#err + 1] = table.concat(d, "\n") end end,
        on_exit = function(_, c) code = c; done = true end,
      })
      vim.wait(8000, function() return done end, 20)
      return table.concat(out, "\n"), table.concat(err, "\n"), code
    end

    local _, _, vcode = run({ "--version" })
    t.eq(0, vcode, "--version 应成功")
    local _, _, acode = run({ "is-active", "nosuch.service" })
    t.eq(4, acode, "is-active 缺失单元应退出 4")
    local _, serr, scode = run({ "start", "nosuch.service" })
    t.eq(5, scode, "start 缺失单元应退出 5")
    t.matches("not found", serr, "start 缺失单元错误应真实")
    vim.fn.delete(vim.fn.fnamemodify(copy, ":h"), "rf")
    ipc.stop()
  end)
end)
