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
  sudo = true, doas = true,
}

-- 可共享沙箱命名空间的（无守护进程）运行时
local DAEMONLESS = { podman = true, buildah = true }
-- 依赖外部守护进程的运行时（无法共享沙箱命名空间）
local DAEMONFUL = { docker = true, nerdctl = true, ["docker-compose"] = true }

-- 远程/连接型选项：会访问宿主或远端，门面明确拒绝。
local REMOTE_OPTS = {
  ["-r"] = true, ["--remote"] = true, ["-H"] = true, ["--host"] = true,
  ["--url"] = true, ["--connection"] = true,
}
-- 会管理宿主机（VM/连接）的子命令：门面明确拒绝。
local UNSUPPORTED_SUBS = { machine = true }

-- docker 命令在沙箱内改写为 podman（无守护进程，容器受沙箱约束）。
local DOCKER_ALIASES = { docker = "podman", ["docker-compose"] = "podman-compose" }

-- podman 可用性（测试可覆盖）。
local podman_override = nil

-- 触发注入的子命令
local RUN_SUBS = { run = true, create = true }

-- 需要注入的命名空间共享标志
local SHARE_FLAGS = { "--net=host", "--pid=host", "--ipc=host", "--uts=host" }

-- ========== 私有函数 ==========

local function _cfg()
  return config_store.get("tools.sandbox.container") or {}
end

--- 按 shell 规则切分为 token（保留引号，重写时只替换目标 token 的字节区间）。
--- @param s string
--- @return table tokens
--- @return table spans { {s=start,e=end}, ... }（与 tokens 一一对应，字节偏移）
local function _tokens(s)
  local out, spans = {}, {}
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
      spans[#spans + 1] = { s = start, e = i - 1 }
    end
  end
  return out, spans
end

--- 把命令中第 idx 个 token 替换为 alias（仅替换该字节区间，保留其余原文与引号）。
--- @param command string
--- @param spans table
--- @param idx number
--- @param alias string
--- @return string|nil
local function _rewrite_manager(command, spans, idx, alias)
  local span = spans and spans[idx]
  if not span then return nil end
  return command:sub(1, span.s - 1) .. alias .. command:sub(span.e + 1)
end

--- 沙箱内是否可改写为 podman（无守护进程运行时）。
--- @return boolean
local function _podman_available()
  if podman_override ~= nil then return podman_override end
  return vim.fn.executable("podman") == 1
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

--- 容器门面判定：运行时/子命令能否在沙箱内管理，或需明确拒绝（不触碰宿主机）。
---   * 无守护进程（podman/buildah）：容器是 CLI 子进程，随沙箱 namespace 隔离 → `sandbox`；
---   * docker/docker-compose：默认改写为 podman/podman-compose（`container.docker_to_podman`，
---     沙箱内有 podman 时）→ `sandbox` + `command`；无 podman 且未配置受控 socket → `unsupported`；
---   * docker/nerdctl 显式受控 socket（`docker.mode="controlled"` 且 socket 存在）→ `controlled`；
---   * 远程/连接型选项（`--remote`/`-H`/`--connection`）与宿主 VM 子命令（`machine`）→ `unsupported`。
--- @param command string
--- @return table|nil { manager, original_manager?, sub?, mode="sandbox"|"controlled"|"unsupported",
---   reason?, command?, rewritten? }
function M.facade(command)
  local cfg = _cfg()
  if cfg.enabled == false then return nil end
  if type(command) ~= "string" or command == "" then return nil end
  local manager = M.detect(command)
  if not manager then return nil end
  local toks, spans = _tokens(command)
  local i = _manager_index(toks)
  local sub = i and toks[i + 1] or nil
  for idx = i + 1, #toks do
    local t = toks[idx]
    local name = t:match("^([^=]+)")
    if REMOTE_OPTS[t] or REMOTE_OPTS[name] then
      return { manager = manager, sub = sub, mode = "unsupported", reason = "CONTAINER_REMOTE_UNSUPPORTED" }
    end
  end
  if DAEMONLESS[manager] then
    if sub and UNSUPPORTED_SUBS[sub] then
      return { manager = manager, sub = sub, mode = "unsupported", reason = "CONTAINER_SUBCOMMAND_UNSUPPORTED" }
    end
    return { manager = manager, sub = sub, mode = "sandbox" }
  end
  -- docker/nerdctl 等有守护进程运行时。
  local d = config_store.get("tools.sandbox.docker") or {}
  -- 显式受控 socket 优先（部署侧明确选择）。
  if d.mode == "controlled" and type(d.socket) == "string" and d.socket ~= ""
    and vim.uv.fs_stat(d.socket) ~= nil then
    return { manager = manager, sub = sub, mode = "controlled" }
  end
  -- 改写为 podman（无守护进程，容器受沙箱约束）。
  local alias = DOCKER_ALIASES[manager]
  local alias_enabled = alias ~= nil and cfg.docker_to_podman ~= false
  if alias_enabled and _podman_available() then
    local rewritten = _rewrite_manager(command, spans, i, alias)
    if rewritten then
      return {
        manager = alias, original_manager = manager, sub = sub,
        mode = "sandbox", command = rewritten, rewritten = true,
      }
    end
  end
  local reason = alias_enabled and "CONTAINER_PODMAN_UNAVAILABLE" or "CONTAINER_REQUIRES_HOST_DAEMON"
  return { manager = manager, sub = sub, mode = "unsupported", reason = reason }
end

--- 门面拒绝时返回给模型的明确错误文本。
--- @param plan table
--- @return string
function M.unsupported_text(plan)
  local mgr = tostring(plan and plan.manager or "container")
  if plan and plan.reason == "CONTAINER_REMOTE_UNSUPPORTED" then
    return "沙箱环境不支持远程/连接型容器管理（`" .. mgr .. " --remote/-H/--connection`）："
      .. "不会访问宿主或远端。"
  end
  if plan and plan.reason == "CONTAINER_SUBCOMMAND_UNSUPPORTED" then
    return "沙箱环境不支持 `" .. mgr .. " " .. tostring(plan.sub) .. "`（会触及宿主机）。"
  end
  if plan and plan.reason == "CONTAINER_PODMAN_UNAVAILABLE" then
    return "沙箱环境不支持 `" .. mgr .. "`：容器管理需宿主守护进程，会触及宿主机；"
      .. "且沙箱内未找到 podman，无法在沙箱内替代。请先安装 podman，或改用 podman 命令。"
  end
  return "沙箱环境不支持 `" .. mgr .. "`：容器管理需宿主守护进程，会触及宿主机；"
    .. "请改用 podman（无守护进程，容器在沙箱内运行）。"
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

--- 测试钩子：覆盖 podman 可用性判定（nil 恢复真实探测）。
--- @param v boolean|nil
function M._set_podman_available(v)
  podman_override = v
end

--- 重置（测试用）
function M.reset()
  podman_override = nil
end

return M
