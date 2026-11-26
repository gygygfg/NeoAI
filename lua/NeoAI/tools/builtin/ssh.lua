--- 宿主侧 SSH 能力工具（别名驱动，密钥不进沙箱）
--- @module 'NeoAI.tools.builtin.ssh'
--- 设计目标：AI 能「用本机密钥通过 openssh 做事」，但**沙箱内没有任何密钥/agent**。
---
--- 执行路径：
---   AI 只给「别名 + 远端命令 / 隧道参数」→ `sandbox/ssh/broker` 用别名配置拼出**参数固定**的
---   宿主 ssh 命令 → `sandbox/execution/hostop` 冻结为主机操作提案（待审）→ 用户在审批界面确认
---   后由 hostop 在**宿主**执行 → `ssh_result` 读回状态与输出。
---
--- 因此：
---   * 密钥文件只被宿主 openssh 进程读取（沙箱无路径、无 fd、无 socket）；
---   * 目的地/用户名/端口/私钥来自配置，AI 无法把它们换成自己的；
---   * 「自己编译一套 ssh」在能力层面没有收益——它既拿不到钥匙，也没有可用的目标。
---
--- 工具本身**不启动进程**（只入队提案），故沙箱规格为 `in_process`（见 `execution/tool_spec.lua`）。

local helpers = require("NeoAI.tools.builtin.tool_helpers")

local M = {}

-- ========== 私有函数 ==========

--- @return table
local function _broker()
  return require("NeoAI.sandbox.ssh.broker")
end

--- 结果信封：提案已入队（不是失败，也无需重试）
--- @param rec table|nil
--- @param what string
--- @return string
local function _pending_text(rec, what)
  local id = (rec and rec.host_op_id) or "?"
  return table.concat({
    "[沙箱] STAGED host_op=" .. id .. " decision=NEEDS_CONFIRMATION kind=host_op",
    "what=" .. what,
    "state=宿主侧提案已排队；用户在 :NeoAI SandboxReview 确认后才在宿主执行（密钥不进入沙箱）",
    "result=确认后用 ssh_result(host_op_id=\"" .. id .. "\") 读取状态与输出",
    "retryable=false do_not_repeat=true",
  }, "\n")
end

--- @param id any
--- @return string|nil
local function _host_op_id(id)
  if type(id) ~= "string" or id == "" then return nil end
  if not id:match("^ho_%w+_?%w*$") then return nil end
  return id
end

-- ========== 工具定义 ==========

local ssh_run = helpers.define_tool(
  "ssh_run",
  "在配置好的 SSH 别名（宿主侧）上执行一条远端命令。别名固定了主机/用户/端口/私钥；"
  .. "本工具不接收 host/端口/ssh 选项，调用会冻结为待审提案，用户确认后由宿主 openssh 执行，"
  .. "再用 ssh_result 读回输出。密钥不会进入沙箱。",
  {
    type = "object",
    properties = {
      alias = { type = "string", description = "tools.sandbox.ssh.aliases 中声明的别名" },
      command = { type = "string", description = "在远端执行的 shell 命令（在远端执行，不在本机）" },
    },
    required = { "alias", "command" },
  },
  function(args, on_success, on_error)
    local cmd, err = _broker().build_exec_command(args.alias, args.command)
    if not cmd then
      on_error({ kind = "ssh", message = tostring(err or "无法构建 ssh 命令") })
      return
    end
    local rec = require("NeoAI.sandbox.execution.hostop").freeze_capability({
      tool = "ssh_run",
      command = cmd,
      reason = "SSH_ALIAS:" .. tostring(args.alias),
      no_sudo = true,
    })
    if not rec then
      on_error({ kind = "ssh", message = "无法创建主机操作提案（待审队列不可用？）" })
      return
    end
    on_success(_pending_text(rec, "ssh_run alias=" .. tostring(args.alias)))
  end,
  { category = "system", approval = { auto_allow = false } }
)

local ssh_tunnel = helpers.define_tool(
  "ssh_tunnel",
  "管理配置好的 SSH 别名上的本地端口转发（仅 127.0.0.1，目标主机受别名白名单约束）。"
  .. "action=open 打开隧道、close 关闭。同样冻结为待审提案，由宿主 openssh 执行；"
  .. "不支持远端转发(-R)/动态代理(-D)。",
  {
    type = "object",
    properties = {
      action = { type = "string", enum = { "open", "close" }, description = "open 打开 / close 关闭" },
      alias = { type = "string", description = "tools.sandbox.ssh.aliases 中声明的别名" },
      local_port = { type = "integer", description = "本地监听端口（必须落在别名的 local_ports 范围内）" },
      remote_host = { type = "string", description = "open 时必填：隧道对端主机（必须命中别名白名单）" },
      remote_port = { type = "integer", description = "open 时必填：隧道对端端口" },
    },
    required = { "action", "alias", "local_port" },
  },
  function(args, on_success, on_error)
    local broker = _broker()
    local cmd, err
    if args.action == "open" then
      cmd, err = broker.build_tunnel_open_command(args.alias, {
        local_port = args.local_port,
        remote_host = args.remote_host,
        remote_port = args.remote_port,
      })
    elseif args.action == "close" then
      cmd, err = broker.build_tunnel_close_command(args.alias, args.local_port)
    else
      on_error({ kind = "ssh", message = "action 必须是 open 或 close" })
      return
    end
    if not cmd then
      on_error({ kind = "ssh", message = tostring(err or "无法构建隧道命令") })
      return
    end
    local rec = require("NeoAI.sandbox.execution.hostop").freeze_capability({
      tool = "ssh_tunnel",
      command = cmd,
      reason = ("SSH_TUNNEL:%s:%s"):format(tostring(args.action), tostring(args.alias)),
      no_sudo = true,
    })
    if not rec then
      on_error({ kind = "ssh", message = "无法创建主机操作提案（待审队列不可用？）" })
      return
    end
    on_success(_pending_text(rec, ("ssh_tunnel %s alias=%s port=%s"):format(
      tostring(args.action), tostring(args.alias), tostring(args.local_port))))
  end,
  { category = "system", approval = { auto_allow = false } }
)

local ssh_result = helpers.define_tool(
  "ssh_result",
  "读取宿主侧 SSH 提案（host_op_id）的审批状态与执行结果（stdout/stderr/退出码）。"
  .. "只读；不改动任何状态。",
  {
    type = "object",
    properties = {
      host_op_id = { type = "string", description = "ssh_run / ssh_tunnel 返回的 host_op_id" },
    },
    required = { "host_op_id" },
  },
  function(args, on_success, on_error)
    local id = _host_op_id(args.host_op_id)
    if not id then
      on_error({ kind = "ssh", message = "host_op_id 非法（应形如 ho_1_1700000000）" })
      return
    end
    local rec = require("NeoAI.sandbox.execution.hostop").get(id)
    if not rec then
      on_error({ kind = "ssh", message = "找不到该提案: " .. id })
      return
    end
    local lines = {
      ("[沙箱] HOST_OP id=%s tool=%s state=%s"):format(id, tostring(rec.tool), tostring(rec.state)),
    }
    if rec.reason then lines[#lines + 1] = "reason=" .. tostring(rec.reason) end
    if rec.reject_reason then lines[#lines + 1] = "reject=" .. tostring(rec.reject_reason) end
    local r = rec.result
    if type(r) == "table" then
      lines[#lines + 1] = "exit_code=" .. tostring(r.code)
      local out = tostring(r.stdout or "")
      local errout = tostring(r.stderr or "")
      if out ~= "" then lines[#lines + 1] = "stdout:\n" .. out end
      if errout ~= "" then lines[#lines + 1] = "stderr:\n" .. errout end
    elseif rec.state == "PENDING" then
      lines[#lines + 1] = "state=等待用户在审批界面（:NeoAI SandboxReview）确认"
    end
    on_success(table.concat(lines, "\n"))
  end,
  { category = "system", approval = { auto_allow = true } }
)

-- ========== 公开 API ==========

--- 获取工具列表
--- @return table 数组
function M.get_tools()
  return { ssh_run, ssh_tunnel, ssh_result }
end

--- 重置（测试用）
function M.reset()
  pcall(function() require("NeoAI.sandbox.ssh.broker").reset() end)
end

return M
