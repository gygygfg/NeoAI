--- 沙箱容器受控运行（docker/podman 与沙箱同 namespace）
--- @module NeoAI.sandbox.container
--- AI 调用容器运行时（docker/podman 等）时，尽量让容器进程运行在沙箱自身的命名空间内，
--- 从而被沙箱的隔离边界（bwrap/unshare 的 pid/net/ipc/uts）一并约束，而不是逃逸到宿主。
---
--- 现实约束：
---   * podman / buildah 为「无守护进程（daemonless）」运行时，CLI 直接在沙箱内执行，
---     容器是 CLI 的子进程；注入 `--net=host --pid=host --ipc=host --uts=host` 后，
---     容器复用沙箱 CLI 的命名空间 → 与沙箱同 namespace（受控）。
---   * docker 依赖外部守护进程，容器由宿主侧 daemon 创建，无法复用沙箱命名空间；
---     此时保持「受控 socket」方案（见 privilege.lua / docs），并明确记录原因。
---
--- 本模块只做命令分析与重写（纯函数，可离线测试），不实际启动容器。

local config_store = require("NeoAI.kernel.config_store")

local M = {}

-- ========== 常量 ==========

-- 需要跳过的命令前缀（不改变被调用的运行时）
local SKIP_PREFIX = {
  env = true, command = true, nohup = true, time = true, nice = true, stdbuf = true,
}

-- 可共享沙箱命名空间的（无守护进程）运行时
local DAEMONLESS = { podman = true, buildah = true }
-- 依赖外部守护进程的运行时（无法共享沙箱命名空间）
local DAEMONFUL = { docker = true, nerdctl = true }

-- 触发注入的子命令
local RUN_SUBS = { run = true, create = true }

-- 需要注入的命名空间共享标志
local SHARE_FLAGS = { "--net=host", "--pid=host", "--ipc=host", "--uts=host" }

-- ========== 私有函数 ==========

local function _cfg()
  return config_store.get("tools.sandbox.container") or {}
end

--- 按 shell 规则切分为 token（保留引号内空白，重写时以单空格连接）
--- @param s string
--- @return table
local function _tokens(s)
  local out = {}
  local i, n = 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c:match("%s") then
      i = i + 1
    else
      local start = i
      local quote = nil
      while i <= n do
        local ch = s:sub(i, i)
        if quote then
          if ch == quote then quote = nil end
        elseif ch == "'" or ch == '"' then
          quote = ch
        elseif ch:match("%s") then
          break
        end
        i = i + 1
      end
      out[#out + 1] = s:sub(start, i - 1)
    end
  end
  return out
end

--- 找到运行时命令 token 下标（跳过 VAR=val 与 SKIP_PREFIX）
--- @param toks table
--- @return number|nil index
local function _manager_index(toks)
  local i = 1
  while i <= #toks and toks[i]:match("^[%w_]+=") do i = i + 1 end
  while i <= #toks and SKIP_PREFIX[toks[i]] do i = i + 1 end
  return i <= #toks and i or nil
end

--- 运行时名（去路径）
--- @param token string
--- @return string
local function _bin(token)
  return vim.fn.fnamemodify(token, ":t")
end

-- ========== 公开 API ==========

--- 识别命令中的容器运行时
--- @param command string
--- @return string|nil manager
function M.detect(command)
  if type(command) ~= "string" or command == "" then return nil end
  local toks = _tokens(command)
  local i = _manager_index(toks)
  if not i then return nil end
  local bin = _bin(toks[i])
  if DAEMONLESS[bin] or DAEMONFUL[bin] then return bin end
  return nil
end

--- 分析命令并给出受控计划（必要时重写命令）
--- @param command string
--- @return table|nil plan {
---   manager, sub?, mode ("namespace"|"controlled"), share_namespace, command, reason?, rewritten?
--- }
function M.plan(command)
  local cfg = _cfg()
  if cfg.enabled == false then return nil end
  if type(command) ~= "string" or command == "" then return nil end
  local manager = M.detect(command)
  if not manager then return nil end
  local toks = _tokens(command)
  local i = _manager_index(toks)
  local sub = toks[i + 1]
  local plan = {
    manager = manager,
    sub = sub,
    share_namespace = false,
    command = command,
    rewritten = false,
  }
  if DAEMONFUL[manager] then
    -- docker 等有守护进程：无法与沙箱同 namespace，保持受控 socket 方案。
    plan.mode = "controlled"
    plan.reason = "DOCKER_NAMESPACE_NOT_SHARABLE"
    return plan
  end
  -- 无守护进程运行时：仅对 run/create 注入命名空间共享标志。
  if cfg.share_namespace == false or not RUN_SUBS[sub] then
    plan.mode = "namespace"
    plan.reason = RUN_SUBS[sub] and "SHARE_NAMESPACE_DISABLED" or "NO_RUN_SUBCOMMAND"
    return plan
  end
  -- 已声明任一共享标志则不重复注入
  local has = false
  for _, t in ipairs(toks) do
    for _, f in ipairs(SHARE_FLAGS) do
      if t == f then has = true end
    end
  end
  if has then
    plan.mode = "namespace"
    plan.share_namespace = true
    plan.reason = "ALREADY_SHARED"
    return plan
  end
  local new_toks = {}
  for idx, t in ipairs(toks) do
    new_toks[#new_toks + 1] = t
    if idx == i + 1 then
      for _, f in ipairs(SHARE_FLAGS) do new_toks[#new_toks + 1] = f end
    end
  end
  plan.mode = "namespace"
  plan.share_namespace = true
  plan.rewritten = true
  plan.command = table.concat(new_toks, " ")
  plan.reason = "SHARED_WITH_SANDBOX"
  return plan
end

--- 记录一次容器受控计划（证据 + 事件 + 审计）
--- @param plan table
--- @param meta table|nil { tool?, command_id?, attempt_id? }
function M.record(plan, meta)
  if type(plan) ~= "table" then return end
  meta = meta or {}
  pcall(function()
    require("NeoAI.sandbox.evidence").add("container", {
      manager = plan.manager, sub = plan.sub, mode = plan.mode,
      share_namespace = plan.share_namespace, reason = plan.reason,
      source = "observed", coverage = "full",
    }, { tool = meta.tool, command_id = meta.command_id, attempt_id = meta.attempt_id })
  end)
  pcall(function()
    require("NeoAI.kernel.event_bus").emit(require("NeoAI.kernel.events").SANDBOX_CONTAINER_PLANNED, {
      manager = plan.manager, mode = plan.mode, share_namespace = plan.share_namespace,
      reason = plan.reason, command_id = meta.command_id,
    })
  end)
  pcall(function()
    require("NeoAI.sandbox.audit").observe({
      kind = "container", tool = meta.tool, manager = plan.manager,
      mode = plan.mode, share_namespace = plan.share_namespace, reason = plan.reason,
      command_id = meta.command_id, level = plan.share_namespace and 1 or 2,
    })
  end)
end

--- 重置（测试用）
function M.reset() end

return M
