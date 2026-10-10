--- Herder 终端状态信号服务测试
--- @module NeoAI.tests.test_herder

local tests = require("NeoAI.tests")

-- 测试通过覆盖 job 运行器来捕获上报命令，避免真正调用 herdr。
local captured = {}

local function reset_herder_env()
  -- 保留并清空目标 env（测试结束后恢复，避免影响其它套件）
  local orig = {
    HERDR_ENV = vim.env.HERDR_ENV,
    HERDER_BIN_PATH = vim.env.HERDER_BIN_PATH,
    HERDR_BIN_PATH = vim.env.HERDR_BIN_PATH,
    HERDR_PANE_ID = vim.env.HERDR_PANE_ID,
    HERDR_CONFIG_PATH = vim.env.HERDR_CONFIG_PATH,
  }
  -- 先设置为已知值（配置路径指向临时目录，避免自动安装误写真实用户配置）
  vim.env.HERDR_ENV = "1"
  vim.env.HERDER_BIN_PATH = "/usr/local/bin/herdr"
  vim.env.HERDR_BIN_PATH = "/usr/local/bin/herdr"
  vim.env.HERDR_PANE_ID = "w1:p1"
  vim.env.HERDR_CONFIG_PATH = vim.fn.tempname() .. "-neoai-herder-cfg/config.toml"
  return orig
end

local function restore_env(orig)
  vim.env.HERDR_ENV = orig.HERDR_ENV
  vim.env.HERDER_BIN_PATH = orig.HERDER_BIN_PATH
  vim.env.HERDR_BIN_PATH = orig.HERDR_BIN_PATH
  vim.env.HERDR_PANE_ID = orig.HERDR_PANE_ID
  vim.env.HERDR_CONFIG_PATH = orig.HERDR_CONFIG_PATH
end

--- 初始化 herder（加载含默认 herder 配置的 config）
--- @param override table|nil 覆盖 herder 配置（如 { report_metadata = false }）
local function init_herder(override)
  local config_store = require("NeoAI.kernel.config_store")
  -- 测试默认关闭自动安装，避免后台写真实配置；需要时由用例显式开启
  local herder_cfg = vim.tbl_extend("force", { auto_install = false }, override or {})
  config_store.load({ herder = herder_cfg })
  local herder = require("NeoAI.services.herder")
  herder.reset()
  captured = {}
  herder.set_job(function(argv) captured[#captured + 1] = argv end)
  herder.init()
  return herder
end

--- 取某条捕获 argv 中的 --state 值
local function arg_state(argv)
  for i, a in ipairs(argv) do
    if a == "--state" then return argv[i + 1] end
  end
  return nil
end

--- 取某条捕获 argv 中某 flag 之后的值
local function arg_value(argv, flag)
  for i, a in ipairs(argv) do
    if a == flag then return argv[i + 1] end
  end
  return nil
end

--- 取某条捕获 argv 中的第 3 个元素（子命令）
local function arg_command(argv)
  return argv[3]
end

--- 收集某类子命令的全部 argv
local function collect(cmd)
  local out = {}
  for _, argv in ipairs(captured) do
    if arg_command(argv) == cmd then out[#out + 1] = argv end
  end
  return out
end

--- report-agent 的 --state 序列
local function report_states()
  local out = {}
  for _, argv in ipairs(collect("report-agent")) do out[#out + 1] = arg_state(argv) end
  return out
end

--- 全部捕获 argv 的 --seq 序列
local function seqs()
  local out = {}
  for _, argv in ipairs(captured) do out[#out + 1] = tonumber(arg_value(argv, "--seq")) end
  return out
end

--- 模拟 agent 创建
local function emit_created(agent_id)
  local eb = require("NeoAI.kernel.event_bus")
  local ev = require("NeoAI.kernel.events")
  eb.emit(ev.AGENT_CREATED, { agent = { id = agent_id, state = "idle" } })
end

--- 模拟 agent 状态切换
local function emit_state(agent_id, new_state)
  local eb = require("NeoAI.kernel.event_bus")
  local ev = require("NeoAI.kernel.events")
  eb.emit(ev.AGENT_STATE_CHANGED, { agent_id = agent_id, new = new_state })
end

--- 读取文件内容（不存在返回 nil）
local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local c = f:read("*a")
  f:close()
  return c
end

tests.suite("herder", function(_, it)
  it("非 Herder 环境时完全 no-op", function(t)
    local orig = reset_herder_env()
    vim.env.HERDR_ENV = nil -- 取消 Herder 标记
    local herder = init_herder()
    t.false_(herder.is_available(), "无 HERDR_ENV 时不应可用")
    t.eq("idle", herder.get_state())
    -- 触发事件也不应产生任何上报
    emit_created("a0")
    t.eq(0, #captured, "非 Herder 环境不应调用上报命令")
    restore_env(orig)
  end)

  it("Herdr 不注入 BIN_PATH 时回退 PATH 上的 herdr", function(t)
    local orig = reset_herder_env()
    -- Herdr 在 pane 内并不注入这两个变量（实测 env 内无 BIN_PATH）
    vim.env.HERDER_BIN_PATH = nil
    vim.env.HERDR_BIN_PATH = nil
    local herder = init_herder()
    t.true_(herder.is_available(), "缺省应回退 PATH 上的 herdr，而非永久 no-op")

    emit_created("a1")
    emit_state("a1", "generating")
    local reports = collect("report-agent")
    t.eq(1, #reports)
    t.eq("herdr", reports[1][1], "应调用 PATH 上的 herdr")
    t.eq("working", arg_state(reports[1]))
    restore_env(orig)
  end)

  it("首个非 idle 信号才接管权威，随后上报回到 idle", function(t)
    local orig = reset_herder_env()
    local herder = init_herder()
    t.true_(herder.is_available())

    emit_created("a1")
    t.eq(0, #captured, "创建即 idle 不应上报")
    t.false_(herder.has_authority())

    emit_state("a1", "generating")
    t.eq(1, #collect("report-agent"))
    t.eq("working", arg_state(collect("report-agent")[1]))
    t.true_(herder.has_authority(), "进入 working 后接管权威")

    emit_state("a1", "idle")
    t.eq(2, #collect("report-agent"))
    t.eq("idle", arg_state(collect("report-agent")[2]))
    restore_env(orig)
  end)

  it("接管权威时附带一次 report-metadata（display_agent/状态文案），且不重复", function(t)
    local orig = reset_herder_env()
    local herder = init_herder()

    emit_created("a1")
    emit_state("a1", "generating")
    local md = collect("report-metadata")
    t.eq(1, #md, "接管权威时应上报一次展示元数据")
    t.eq("NeoAI", arg_value(md[1], "--display-agent"))
    -- state_labels 按确定性顺序输出
    local labels = {}
    local argv = md[1]
    for i, a in ipairs(argv) do
      if a == "--state-label" then labels[#labels + 1] = argv[i + 1] end
    end
    t.deep_eq({ "working=生成中", "blocked=等待确认", "idle=就绪" }, labels)

    emit_state("a1", "idle")
    emit_state("a1", "generating")
    t.eq(1, #collect("report-metadata"), "同一权威生命周期内元数据只上报一次")
    restore_env(orig)
  end)

  it("report_metadata=false 时不上报元数据", function(t)
    local orig = reset_herder_env()
    local herder = init_herder({ report_metadata = false })

    emit_created("a1")
    emit_state("a1", "generating")
    t.eq(1, #collect("report-agent"))
    t.eq(0, #collect("report-metadata"), "关闭后不应上报元数据")
    restore_env(orig)
  end)

  it("所有上报 --seq 严格递增", function(t)
    local orig = reset_herder_env()
    local herder = init_herder()

    emit_created("a1")
    emit_state("a1", "generating") -- metadata + report
    emit_state("a1", "idle")
    local s = seqs()
    t.ok(#s >= 3)
    for i = 2, #s do
      t.ok(s[i] > s[i - 1], "seq 应严格递增")
    end
    t.eq(herder.get_seq(), s[#s])
    restore_env(orig)
  end)

  it("seq 以挂钟为基数（不从 1 开始）", function(t)
    local orig = reset_herder_env()
    local herder = init_herder()
    emit_created("a1")
    emit_state("a1", "generating")
    local s = seqs()
    t.ok(#s >= 1)
    t.ok(s[1] >= 1e12, "seq 应以挂钟为基数（否则重启后会被 herdr 当过期包丢弃）")
    -- CLI 参数必须是纯整数（不能是科学计数法）
    t.matches("^%d+$", arg_value(collect("report-agent")[1], "--seq"))
    restore_env(orig)
  end)

  it("reset 后 seq 不回退（reload/重开 nvim 仍被 herdr 接受）", function(t)
    local orig = reset_herder_env()
    local herder = init_herder()
    emit_created("a1")
    emit_state("a1", "generating")
    emit_state("a1", "idle")
    local max1 = seqs()[#seqs()]

    -- 模拟插件 reload / 同一 pane 内重开 nvim：模块状态被重置
    vim.wait(5, function() return false end) -- 让挂钟前进，避免同一微秒内基数相等
    herder.reset()
    herder = init_herder()
    emit_created("a2")
    emit_state("a2", "generating")
    local s2 = seqs()
    t.ok(#s2 >= 1)
    for _, v in ipairs(s2) do
      t.ok(v > max1, "重置后新的 seq 必须大于此前最大值，否则 herdr 会当过期包丢弃")
    end
    restore_env(orig)
  end)

  it("公开 API 透出 source/agent/display_agent/pane_id", function(t)
    local orig = reset_herder_env()
    local herder = init_herder()
    t.eq("custom:neoai", herder.get_source())
    t.eq("neoai", herder.get_agent())
    t.eq("NeoAI", herder.get_display_agent())
    t.eq("w1:p1", herder.get_pane_id())
    restore_env(orig)
  end)

  it("审批阻塞态优先级高于 working", function(t)
    local orig = reset_herder_env()
    local herder = init_herder()
    local eb = require("NeoAI.kernel.event_bus")
    local ev = require("NeoAI.kernel.events")

    emit_created("a1")
    emit_created("a2")
    emit_state("a1", "generating")
    t.eq("working", report_states()[1])

    eb.emit(ev.TOOL_APPROVAL_REQUESTED, { agent_id = "a1", tool_name = "edit_file", args = {} })
    t.eq("blocked", report_states()[2], "审批中应上报 blocked")

    eb.emit(ev.TOOL_APPROVED, { agent_id = "a1", tool_name = "edit_file" })
    t.eq("working", report_states()[3], "审批通过且仍 working 应回落 working")
    restore_env(orig)
  end)

  it("ask_user 等待触发 blocked，回答后回到 idle", function(t)
    local orig = reset_herder_env()
    local herder = init_herder()
    local eb = require("NeoAI.kernel.event_bus")
    local ev = require("NeoAI.kernel.events")

    emit_created("a1")
    eb.emit(ev.ASK_USER_WAITING, { agent_id = "a1" })
    t.eq("blocked", report_states()[1], "等待用户回答应上报 blocked")

    eb.emit(ev.ASK_USER_ANSWERED, { agent_id = "a1" })
    t.eq("idle", report_states()[2], "回答后应回到 idle")
    restore_env(orig)
  end)

  it("pty 会话等待输入不影响 pane 状态（不标红）", function(t)
    local orig = reset_herder_env()
    local herder = init_herder()
    local eb = require("NeoAI.kernel.event_bus")
    local ev = require("NeoAI.kernel.events")

    emit_created("a1")
    t.eq("idle", herder.get_state(), "空闲 agent 应为 idle")
    -- pty 等待用户输入：不应把 pane 变成 blocked（不标红）
    eb.emit(ev.PTY_WAITING_INPUT, { id = "pty1" })
    t.eq("idle", herder.get_state(), "pty 等待输入不应改变 pane 状态")
    -- agent 正在生成时，pty 等待同样不应把它改写为 blocked
    emit_state("a1", "generating")
    t.eq("working", herder.get_state(), "generating agent 应为 working")
    eb.emit(ev.PTY_WAITING_INPUT, { id = "pty2" })
    t.eq("working", herder.get_state(), "pty 等待输入不应把 working agent 标为 blocked")
    -- 输入送达 / 会话退出：pane 状态仍按 agent 作态显示
    eb.emit(ev.PTY_INPUT_SENT, { id = "pty2" })
    t.eq("working", herder.get_state())
    eb.emit(ev.PTY_EXITED, { id = "pty2" })
    t.eq("working", herder.get_state(), "pty 退出不应改变 pane 状态")
    -- agent 回 idle 后 pane 才回 idle
    emit_state("a1", "idle")
    t.eq("idle", herder.get_state(), "agent 回 idle 后 pane 应为 idle")
    restore_env(orig)
  end)

  it("最后一个 agent 移除时清除元数据并释放权威", function(t)
    local orig = reset_herder_env()
    local herder = init_herder()
    local eb = require("NeoAI.kernel.event_bus")
    local ev = require("NeoAI.kernel.events")

    emit_created("a1")
    emit_state("a1", "generating")
    t.true_(herder.has_authority())

    eb.emit(ev.AGENT_DISPOSED, { agent_id = "a1" })
    t.eq(1, #collect("release-agent"), "最后一个 agent 移除应调用 release-agent")
    -- 释放前应清除展示元数据
    local md = collect("report-metadata")
    local cleared = false
    for _, argv in ipairs(md) do
      for _, a in ipairs(argv) do
        if a == "--clear-display-agent" then cleared = true end
      end
    end
    t.true_(cleared, "释放前应发送 --clear-display-agent")
    t.false_(herder.has_authority(), "释放后不再持有权威")

    -- 释放后再创建 idle agent 不应重新上报
    local n = #captured
    emit_created("a2")
    t.eq(n, #captured)
    restore_env(orig)
  end)

  it("shutdown：已接管权威时发 release-agent 并清元数据（退出/重启/卸载）", function(t)
    local orig = reset_herder_env()
    local herder = init_herder()
    emit_created("a1")
    emit_state("a1", "generating")
    t.true_(herder.has_authority(), "进入 working 后应已接管权威")

    captured = {}
    herder.shutdown()
    t.eq(1, #collect("release-agent"), "shutdown 应发送 release-agent 释放 pane 权威")
    -- 释放前应清除展示元数据
    local cleared = false
    for _, argv in ipairs(collect("report-metadata")) do
      for _, a in ipairs(argv) do
        if a == "--clear-display-agent" then cleared = true end
      end
    end
    t.true_(cleared, "释放前应发送 --clear-display-agent")
    t.false_(herder.has_authority(), "shutdown 后不应再持有权威")
    t.false_(herder.is_available(), "shutdown 后应复位为不可用")
    restore_env(orig)
  end)

  it("shutdown：未接管权威时不产生任何多余上报", function(t)
    local orig = reset_herder_env()
    local herder = init_herder()
    -- 仅创建 idle agent：从未接管权威
    emit_created("a1")
    t.false_(herder.has_authority())

    captured = {}
    herder.shutdown()
    t.eq(0, #captured, "未接管权威时 shutdown 不应发任何上报")
    t.false_(herder.is_available())
    restore_env(orig)
  end)

  it("多会话聚合：任一 blocked 即上报 blocked", function(t)
    local orig = reset_herder_env()
    local herder = init_herder()
    local eb = require("NeoAI.kernel.event_bus")
    local ev = require("NeoAI.kernel.events")

    emit_created("a1")
    emit_created("a2")
    emit_state("a1", "generating")
    t.eq("working", report_states()[1])

    eb.emit(ev.ASK_USER_WAITING, { agent_id = "a2" })
    t.eq("blocked", report_states()[2], "只要任一会话阻塞就上报 blocked")

    eb.emit(ev.ASK_USER_ANSWERED, { agent_id = "a2" })
    t.eq("working", report_states()[3], "阻塞解除后回落 working")
    restore_env(orig)
  end)

  it("auto_install：启动时异步静默安装展示片段，且不重复写入", function(t)
    local orig = reset_herder_env()
    -- 指向临时配置路径 + 假 herdr（config check 退出 0）
    local dir = vim.fn.tempname() .. "-neoai-herder-auto"
    vim.fn.mkdir(dir, "p")
    local cfg = dir .. "/config.toml"
    vim.env.HERDR_CONFIG_PATH = cfg
    local bin = vim.fn.tempname() .. "-fakeherdr0"
    vim.fn.writefile({ "#!/bin/sh", "exit 0" }, bin)
    vim.fn.setfperm(bin, "rwxr-xr-x")
    vim.env.HERDER_BIN_PATH = bin
    vim.env.HERDR_BIN_PATH = bin

    init_herder({ auto_install = true })
    -- 等待异步安装落盘
    vim.wait(3000, function()
      local c = read_file(cfg)
      return c ~= nil and c:find("# >>> NeoAI herder integration", 1, true) ~= nil
    end, 50)
    local content = read_file(cfg)
    t.ok(content and content:find("# >>> NeoAI herder integration", 1, true) ~= nil, "应已异步写入展示片段")

    -- 幂等：再次（模拟二次启动）不应重复写入
    local install = require("NeoAI.services.herder_install")
    local started = install.install_async()
    t.false_(started, "已安装时不应再次写入")
    t.eq(content, read_file(cfg), "重复安装不应改变文件")
    restore_env(orig)
  end)

  it("测试运行器默认关闭 herder 自动安装（不写真实配置）", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    -- 运行器在每个套件前 config_store.load({})，应命中测试默认 auto_install=false，
    -- 避免启动 herder 服务时把展示增强片段写入用户真实配置。
    config_store.load({})
    t.false_(config_store.get("herder.auto_install"), "测试默认应关闭 herder.auto_install")
  end)

  it("auto_install=false 时启动 herder 不创建配置文件", function(t)
    local orig = reset_herder_env()
    local dir = vim.fn.tempname() .. "-neoai-herder-noauto"
    vim.fn.mkdir(dir, "p")
    local cfg = dir .. "/config.toml"
    vim.env.HERDR_CONFIG_PATH = cfg
    local bin = vim.fn.tempname() .. "-fakeherdr0"
    vim.fn.writefile({ "#!/bin/sh", "exit 0" }, bin)
    vim.fn.setfperm(bin, "rwxr-xr-x")
    vim.env.HERDER_BIN_PATH = bin
    vim.env.HERDR_BIN_PATH = bin

    init_herder({ auto_install = false })
    vim.wait(400)
    t.nil_(read_file(cfg), "auto_install=false 不应写任何 herder 配置")
    restore_env(orig)
  end)
end)
