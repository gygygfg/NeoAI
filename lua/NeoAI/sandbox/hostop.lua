--- 沙箱主机操作提案（T2 特权档）
--- @module NeoAI.sandbox.hostop
--- T2 特权命令在嵌套 user namespace 内自动执行（cap 被 userns 作用域限制，够不到宿主），
--- 其「会落到主机」的效果冻结为提案；用户异步审批后，在主机上 replay 该命令。
--- 不阻塞工具调用：提案进入待审队列，审批前不产生主机副作用（设计见 docs/sandbox.md §17）。

local config_store = require("NeoAI.kernel.config_store")

local M = {}

-- ========== 私有状态 ==========

local state = { seq = 0 }

-- ========== 私有函数 ==========

local function _emit(event, payload)
  require("NeoAI.kernel.event_bus").emit(event, payload or {})
end

--- 在主机上同步执行命令（用户已批准的主机效果），带超时。
--- 非 root 运行 NeoAI 时经 `sudo` 提权（`pty` 以支持密码提示）；提案已经用户审批。
--- @param command string
--- @return table { code, stdout, stderr }
local function _run_host(command)
  local limits = config_store.get("tools.sandbox.limits") or {}
  local timeout_ms = limits.wall_ms or 60000
  local stdout, stderr = {}, {}
  local use_sudo = vim.uv.getuid ~= nil and vim.uv.getuid() ~= 0
  local argv = use_sudo and { "sudo", "sh", "-c", command } or { "sh", "-c", command }
  local done, exit_code = false, nil
  local job = vim.fn.jobstart(argv, {
    pty = use_sudo,
    stdout_buffered = not use_sudo,
    stderr_buffered = not use_sudo,
    on_stdout = function(_, data)
      for _, line in ipairs(data or {}) do stdout[#stdout + 1] = line end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data or {}) do stderr[#stderr + 1] = line end
    end,
    on_exit = function(_, code)
      exit_code = code
      done = true
    end,
  })
  if job <= 0 then
    return { code = -1, stdout = "", stderr = "HOST_OP_SPAWN_FAILED" }
  end
  -- 非阻塞等待：vim.wait 期间持续处理事件循环，chat 界面计时器/输入仍可刷新；
  -- 不用 vim.fn.jobwait（会冻结主线程至多 wall_ms，导致计时刷新停摆）。
  local ok = vim.wait(timeout_ms, function() return done end, 20)
  if not ok or not done then
    pcall(vim.fn.jobstop, job)
    return { code = -1, stdout = table.concat(stdout, "\n"), stderr = table.concat(stderr, "\n") .. "\nHOST_OP_TIMEOUT" }
  end
  return { code = exit_code, stdout = table.concat(stdout, "\n"), stderr = table.concat(stderr, "\n") }
end

-- ========== 公开 API ==========

--- 冻结一条主机操作提案并进入待审队列
--- @param attempt table 控制面尝试
--- @param args table 工具参数（含 command）
--- @param privileges table|nil 档位隔离参数
--- @param meta table|nil { reason? }
--- @return table|nil record
--- @return table|nil review_item
function M.freeze(attempt, args, privileges, meta)
  -- 包安装命令绝不在主机上 replay：沙箱内安装失败即失败，绝不回退到宿主机安装。
  -- 安装失败常伴随「权限不足 / 只读文件系统」信号而触发 T2 升级并冻结主机提案，
  -- 若放行会在用户审批后于宿主机执行 `pipx install …` 等，故在此集中拦截。
  if attempt and attempt.package then return nil end
  local command = args and (args.command or args.cmd)
  if type(command) ~= "string" or command == "" then return nil end
  local store = require("NeoAI.sandbox.store")
  state.seq = state.seq + 1
  local id = string.format("ho_%d_%s", state.seq, tostring(os.time()))
  local rec = {
    host_op_id = id,
    command = command,
    tool = attempt.tool_name,
    command_id = attempt.command_id,
    attempt_id = attempt.attempt_id,
    tier = (privileges and privileges.tier) or 2,
    privileges = {
      cap_add = (privileges and privileges.cap_add) or {},
      mounts = (privileges and privileges.mounts) or {},
      unmask = (privileges and privileges.unmask) or {},
      network = privileges and privileges.network or false,
    },
    reason = meta and meta.reason,
    state = "PENDING",
    created_at = os.time(),
  }
  store.write_host_op(rec)
  local item = require("NeoAI.sandbox.review").enqueue_host_op(rec)
  _emit(require("NeoAI.kernel.events").SANDBOX_HOST_OP_ENQUEUED, {
    host_op_id = id, change_set_id = item and item.change_set_id, command = command,
  })
  return rec, item
end

--- 获取提案
--- @param id string
--- @return table|nil
function M.get(id)
  return require("NeoAI.sandbox.store").read_host_op(id)
end

--- 列出提案
--- @param filter table|nil { state? }
--- @return table 数组
function M.list(filter)
  filter = filter or {}
  local out = {}
  for _, rec in ipairs(require("NeoAI.sandbox.store").list_host_ops()) do
    if not filter.state or rec.state == filter.state then out[#out + 1] = rec end
  end
  return out
end

--- 拒绝提案（不产生主机副作用）
--- @param id string
--- @param reason string|nil
--- @return boolean
function M.reject(id, reason)
  local store = require("NeoAI.sandbox.store")
  local rec = store.read_host_op(id)
  if not rec then return false end
  rec.state = "REJECTED"
  rec.reject_reason = reason
  rec.rejected_at = os.time()
  store.write_host_op(rec)
  _emit(require("NeoAI.kernel.events").SANDBOX_HOST_OP_REJECTED, { host_op_id = id, reason = reason })
  return true
end

--- 在主机上 replay 提案（仅在用户审批后由 review.apply 调用）
--- @param id string
--- @return table { ok, state, reason?, receipt?, result? }
function M.replay(id)
  local store = require("NeoAI.sandbox.store")
  local rec = store.read_host_op(id)
  if not rec then
    return { ok = false, state = "FAILED", reason = "HOST_OP_NOT_FOUND: " .. tostring(id) }
  end
  if rec.state == "APPLIED" then
    return { ok = true, state = "APPLIED", receipt = rec.receipt, result = rec.result }
  end
  -- 兜底：即便历史提案已入队，包安装命令也拒绝在主机执行（绝不回退到宿主机安装）。
  local req = require("NeoAI.sandbox.privilege").classify(
    rec.tool or "run_command", { command = rec.command }, { effect = "process" })
  if req and req.package then
    rec.state = "REJECTED"
    rec.reject_reason = "HOST_OP_PACKAGE_DENIED"
    rec.rejected_at = os.time()
    store.write_host_op(rec)
    _emit(require("NeoAI.kernel.events").SANDBOX_HOST_OP_REJECTED, {
      host_op_id = id, reason = "HOST_OP_PACKAGE_DENIED",
    })
    return { ok = false, state = "REJECTED", reason = "HOST_OP_PACKAGE_DENIED: 包安装不在宿主机执行" }
  end
  local result = _run_host(rec.command)
  rec.state = result.code == 0 and "APPLIED" or "FAILED"
  rec.result = { code = result.code, stdout = result.stdout, stderr = result.stderr }
  rec.applied_at = os.time()
  local receipt = {
    operation_id = "hop_" .. tostring(id),
    host_op_id = id,
    command = rec.command,
    exit_code = result.code,
    at = os.time(),
  }
  rec.receipt = receipt
  store.write_host_op(rec)
  store.write_receipt(receipt)
  pcall(function()
    require("NeoAI.sandbox.evidence").add("host_op", {
      host_op_id = id, command = rec.command, exit_code = result.code,
      source = "observed", coverage = "full",
    }, { tool = rec.tool, command_id = rec.command_id, attempt_id = rec.attempt_id })
  end)
  _emit(require("NeoAI.kernel.events").SANDBOX_HOST_OP_APPLIED, {
    host_op_id = id, exit_code = result.code, operation_id = receipt.operation_id,
  })
  return { ok = result.code == 0, state = rec.state, receipt = receipt, result = rec.result }
end

--- 重置（测试用）
function M.reset()
  state.seq = 0
end

return M
