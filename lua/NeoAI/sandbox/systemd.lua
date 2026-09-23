--- 沙箱 systemctl 门面（方案 A）
--- @module NeoAI.sandbox.systemd
--- AI 在沙箱内调用 `systemctl`/`journalctl` 时，不调用宿主 systemd、也不改宿主机：
---   * 解析 unit 文件（优先沙箱暂存副本，使 AI 新建/修改的 unit 可见）；
---   * `start`/`restart` 按依赖（Requires/Wants/After/Before）递归，把 ExecStart 交给
---     `sandbox.service` 在沙箱内启动（独立 overlay + cgroup，写入停止时冻结为候选）；
---   * `stop`/`status`/`is-active`/`show`/`cat`/`daemon-reload`/`list-units` 由服务状态合成；
---   * 不支持的 Type（notify/forking/dbus/idle…）与 socket/timer 单元**明确报错**；
---   * 门面不处理的动词回退既有 T2/hostop 提案路径（由 wrapper 决定，见 docs/sandbox.md）。
--- 本模块只负责解析与路由，不直接 spawn 宿主进程（启动经 sandbox.service）。

local config_store = require("NeoAI.kernel.config_store")
local fs = require("NeoAI.utils.fs")
local async = require("NeoAI.utils.async")

local M = {}

--- 被 `systemctl stop` 停掉的基线单元（门面基线默认 active）。`start` 清除，`reset` 清空。
local stopped_baseline = {}

-- ========== 常量 ==========

local KNOWN_SUFFIXES = {
  ".service", ".socket", ".timer", ".target", ".mount", ".path", ".slice",
  ".scope", ".device", ".swap", ".automount",
}

-- 门面基线运行单元（系统 scope）：真实已启动的 systemd 系统必然存在的核心 target 与基础服务。
-- 它们没有对应的沙箱服务进程，仅用于让 `list-units`/`status`/`is-active` 与「健康 systemd 已
-- 启动」自洽——否则 list-units 恒为空、且与 is-system-running=running 观感矛盾。
-- 刻意不含 dbus/logind 之外的会话总线相关单元，避免与沙箱其它门面（如 timedatectl 无总线）
-- 互相矛盾。
local BASELINE_ACTIVE = {
  ["sysinit.target"] = { active = "active", sub = "active", desc = "System Initialization" },
  ["basic.target"] = { active = "active", sub = "active", desc = "Basic System" },
  ["sockets.target"] = { active = "active", sub = "active", desc = "Socket Units" },
  ["paths.target"] = { active = "active", sub = "active", desc = "Path Units" },
  ["timers.target"] = { active = "active", sub = "active", desc = "Timer Units" },
  ["local-fs.target"] = { active = "active", sub = "active", desc = "Local File Systems" },
  ["network.target"] = { active = "active", sub = "active", desc = "Network" },
  ["multi-user.target"] = { active = "active", sub = "active", desc = "Multi-User System" },
  ["systemd-journald.service"] = { active = "active", sub = "running", desc = "Journal Service" },
  ["systemd-udevd.service"] = {
    active = "active", sub = "running",
    desc = "Rule-based Manager for Device Events and Files",
  },
}

--- @param name string
--- @param scope string|nil
--- @return table|nil
local function _baseline(name, scope)
  if scope == "user" then return nil end
  return BASELINE_ACTIVE[name]
end

-- 单元类型支持：simple/exec 长驻、oneshot 跑完即返回。notify/forking/dbus/idle 等按 **best-effort**
-- 以 simple 语义在沙箱内执行（不做 sd_notify READY / daemonize 子进程跟踪）；仅未知类型明确报错。
local SUPPORTED_TYPES = {
  simple = true, exec = true, oneshot = true,
  notify = true, ["notify-reload"] = true, ["oneshot-notify"] = true,
  forking = true, dbus = true, idle = true,
}

--- oneshot 语义（start 阻塞到进程退出并按退出码返回）。
--- @param typ string
--- @return boolean
local function _is_oneshot(typ)
  return typ == "oneshot" or typ == "oneshot-notify"
end

-- 门面处理的动词。
local SUPPORTED_VERBS = {
  start = true, stop = true, restart = true, status = true, ["is-active"] = true,
  ["is-enabled"] = true, show = true, cat = true, ["daemon-reload"] = true,
  ["list-units"] = true, ["list-unit-files"] = true,
  ["list-timers"] = true, ["list-sockets"] = true, ["list-jobs"] = true,
  ["get-default"] = true, ["set-default"] = true, ["show-environment"] = true,
  -- 环境探测类：合成「已启动/无失败」输出，避免暴露「非 systemd 环境」。
  ["is-system-running"] = true, ["is-failed"] = true,
  -- 清除失败状态：门面无持久失败单元，幂等成功（真实 systemd 支持该动词）。
  ["reset-failed"] = true,
}

-- 使「无动词的 systemctl」等价于 `list-units` 的选项（真实 systemctl 默认动词即 list-units）。
-- 例如 `systemctl --failed` == `systemctl list-units --failed`。`--version`/`--help` 不在列。
local LIST_OPTS = {
  ["--failed"] = true, ["--all"] = true, ["-a"] = true, ["--state"] = true,
  ["--type"] = true, ["-t"] = true, ["--no-legend"] = true, ["--plain"] = true,
  ["--no-pager"] = true, ["--full"] = true, ["--no-ask-password"] = true,
}

-- 明确拒绝（不落到宿主机，也不回退 hostop）的动词。
local REJECT_VERBS = {
  enable = true, disable = true, reenable = true, mask = true, unmask = true,
  reload = true, ["reload-or-restart"] = true, ["try-reload-or-restart"] = true,
  kill = true, edit = true, link = true, revert = true,
  isolate = true, ["switch-root"] = true, ["set-property"] = true,
  -- 宿主电源/内核状态：明确拒绝（绝不回退 hostop 在宿主执行）。
  poweroff = true, reboot = true, halt = true, kexec = true, suspend = true,
  hibernate = true, ["hybrid-sleep"] = true, ["suspend-then-hibernate"] = true,
  rescue = true, emergency = true,
}

-- 指定其它主机/根/镜像的选项：无法在本地沙箱门面处理 → 回退 hostop。
local HOST_TARGET_OPTS = {
  ["-H"] = true, ["--host"] = true, ["-M"] = true, ["--machine"] = true,
  ["--root"] = true, ["--image"] = true,
}

-- 需要跳过前缀（不改变被调用的命令）
local SKIP_PREFIX = {
  env = true, command = true, nohup = true, time = true, nice = true, stdbuf = true,
  sudo = true, doas = true,
}

-- 需要独立取值的选项（其后的 token 是值而非 verb/unit）
local OPT_VALUE = {
  ["--type"] = true, ["-t"] = true, ["--state"] = true, ["--property"] = true, ["-p"] = true,
  ["--lines"] = true, ["-n"] = true, ["--unit"] = true, ["-u"] = true,
  ["--host"] = true, ["-H"] = true, ["--machine"] = true, ["-M"] = true,
  ["--root"] = true, ["--image"] = true, ["--job-mode"] = true, ["--signal"] = true,
  ["-s"] = true, ["--kill-who"] = true, ["--what"] = true,
}

-- ========== 私有函数 ==========

--- @return table
local function _cfg()
  return config_store.get("tools.sandbox.systemd") or {}
end

--- @return table
local function _svc()
  local ok, mod = pcall(require, "NeoAI.sandbox.service")
  if ok then return mod end
  return nil
end

--- @param scope string|nil "system"（默认）| "user"
--- @return table
local function _unit_roots(scope)
  if scope == "user" then
    local roots = _cfg().user_unit_roots
    if type(roots) == "table" and #roots > 0 then return roots end
    local home = vim.fn.expand("~")
    return {
      home .. "/.config/systemd/user", "/etc/systemd/user",
      "/usr/lib/systemd/user", "/lib/systemd/user", "/run/systemd/user",
    }
  end
  local roots = _cfg().unit_roots
  if type(roots) == "table" and #roots > 0 then return roots end
  return {
    "/etc/systemd/system", "/run/systemd/system",
    "/usr/lib/systemd/system", "/lib/systemd/system",
  }
end

--- 用户级 `enable`/`disable` 的软链管理根（与 `_unit_roots("user")` 第一项一致）。
--- @return string
local function _user_admin_root()
  local roots = _cfg().user_unit_roots
  if type(roots) == "table" and #roots > 0 then return roots[1] end
  return vim.fn.expand("~/.config/systemd/user")
end

--- @param token string
--- @return string
local function _bin(token)
  return vim.fn.fnamemodify(tostring(token), ":t")
end

--- 归一化 shell 重定向语法（仅用于判断复合命令，不影响真实执行）。
--- @param s string
--- @return string
local function _normalize_redirects(s)
  return (tostring(s):gsub(">&", ">"):gsub("&>", ">"):gsub("|&", "|"))
end

--- 按 shell 规则切分 token（去引号），并检测未加引号的复合分隔符。
--- @param s string
--- @return table tokens
--- @return boolean compound
local function _tokenize(s)
  local out = {}
  local i, n = 1, #s
  local compound = false
  while i <= n do
    local c = s:sub(i, i)
    if c == "\n" or c == ";" or c == "|" or c == "&" then
      compound = true
      i = i + 1
    elseif c:match("%s") then
      i = i + 1
    else
      local start = i
      local quote = nil
      local buf = {}
      while i <= n do
        local ch = s:sub(i, i)
        if quote then
          if ch == quote then
            quote = nil
          elseif ch == "\\" and quote == '"' and i < n then
            i = i + 1
            buf[#buf + 1] = s:sub(i, i)
          else
            buf[#buf + 1] = ch
          end
        elseif ch == "'" or ch == '"' then
          quote = ch
        elseif ch == "\\" and i < n then
          i = i + 1
          buf[#buf + 1] = s:sub(i, i)
        elseif ch:match("%s") or ch == ";" or ch == "|" or ch == "&" then
          break
        else
          buf[#buf + 1] = ch
        end
        i = i + 1
      end
      out[#out + 1] = table.concat(buf)
    end
  end
  return out, compound
end

--- 解析一个 systemctl/journalctl 调用；非独立调用返回 nil。
--- @param command string
--- @return table|nil plan { kind, verb, units, opts, route, raw, argv }
function M.parse_command(command)
  if type(command) ~= "string" or command == "" then return nil end
  local toks, compound = _tokenize(_normalize_redirects(command))
  if compound or #toks == 0 then return nil end
  return M._plan_tokens(toks, command)
end

--- 由已切分的 token 列表构造计划（门面与沙箱内 shim 共用）。
--- @param toks table
--- @param raw string
--- @return table|nil
function M._plan_tokens(toks, raw)
  if type(toks) ~= "table" or #toks == 0 then return nil end
  local i = 1
  while i <= #toks and (toks[i]:match("^[%w_]+=") or SKIP_PREFIX[_bin(toks[i])]) do i = i + 1 end
  if i > #toks then return nil end
  local bin = _bin(toks[i])
  if bin == "systemd-run" then
    return M._parse_systemd_run(toks, i + 1, raw)
  end
  if bin == "systemd-analyze" then
    return M._parse_systemd_analyze(toks, i + 1, raw)
  end
  if bin == "hostnamectl" then
    return M._parse_simple_tool(toks, i + 1, raw, "hostnamectl", "status")
  end
  if bin == "timedatectl" then
    return M._parse_simple_tool(toks, i + 1, raw, "timedatectl", "status")
  end
  if bin == "dmesg" then
    return M._parse_simple_tool(toks, i + 1, raw, "dmesg", nil)
  end
  if bin ~= "systemctl" and bin ~= "journalctl" then return nil end
  local kind = bin
  local argv = {}
  for j = i, #toks do argv[#argv + 1] = toks[j] end
  i = i + 1

  if kind == "journalctl" then
    local plan = M._parse_journalctl(toks, i, raw)
    if plan then plan.argv = argv end
    return plan
  end

  local opts, verb, units = {}, nil, {}
  local host_target = false
  while i <= #toks do
    local t = toks[i]
    if t:sub(1, 1) == "-" and t ~= "-" then
      local name = t:match("^([^=]+)")
      if HOST_TARGET_OPTS[name] then host_target = true end
      if OPT_VALUE[name] and not t:find("=", 1, true) then
        -- 独立取值的选项：把值并入 `name=value`，既保留（供 list-units 过滤）又不把它误当
        -- verb/unit。缺值时仅保留选项本身（与真实 systemctl 的报错由后续处理）。
        local val = toks[i + 1]
        if val ~= nil and val:sub(1, 1) ~= "-" then
          opts[#opts + 1] = t .. "=" .. val
          i = i + 1
        else
          opts[#opts + 1] = t
        end
      else
        opts[#opts + 1] = t
      end
    elseif not verb then
      verb = t
    else
      units[#units + 1] = t
    end
    i = i + 1
  end
  if not verb then
    -- 只有列表相关选项时，默认动词为 list-units（真实 systemctl 行为）；否则保持 nil
    -- （裸 `systemctl`、`--version`/`--help` 交由 exec 回退/版本分支处理）。
    local list_opt = false
    for _, o in ipairs(opts) do
      if LIST_OPTS[o:match("^([^=]+)")] then list_opt = true; break end
    end
    if not list_opt then return nil end
    verb = "list-units"
  end

  -- `systemctl --user`：由**伪造的 systemd 解析器**在门面内处理（不启动真实 systemd/dbus）。
  -- 单元从用户单元根（`~/.config/systemd/user` 等，优先暂存副本）解析，start/stop/is-active
  -- 由沙箱服务状态合成，enable/disable 的软链暂存到用户单元根。
  local scope = "system"
  for _, o in ipairs(opts) do
    if o == "--user" then scope = "user" end
  end

  local route
  if host_target then
    route = "hostop"
  elseif SUPPORTED_VERBS[verb] then
    route = "facade"
  elseif REJECT_VERBS[verb] then
    route = "reject"
  else
    route = "hostop"
  end
  return {
    kind = kind, verb = verb, units = units, opts = opts, route = route,
    scope = scope, raw = raw, argv = argv,
  }
end

--- @param toks table
--- @param i number
--- @param raw string
--- @return table|nil
function M._parse_journalctl(toks, i, raw)
  local units = {}
  local tail = nil
  while i <= #toks do
    local t = toks[i]
    if t == "-u" or t == "--unit" then
      i = i + 1
      if toks[i] then units[#units + 1] = toks[i] end
    elseif t:match("^%-%-unit=") then
      units[#units + 1] = t:sub(#"--unit=" + 1)
    elseif t:match("^%-u.+") then
      units[#units + 1] = t:sub(3)
    elseif t == "-n" or t == "--lines" then
      i = i + 1
      tail = tonumber(toks[i])
    elseif t:match("^%-%-lines=") then
      tail = tonumber(t:sub(#"--lines=" + 1))
    elseif t:match("^%-n%d+$") then
      tail = tonumber(t:sub(3))
    end
    i = i + 1
  end
  return { kind = "journalctl", verb = "logs", units = units, tail = tail, route = "facade", raw = raw }
end

--- 需要取值的 systemd-run 选项。
local RUN_OPT_VALUE = {
  ["--unit"] = true, ["-u"] = true, ["--property"] = true, ["-p"] = true,
  ["--setenv"] = true, ["-E"] = true, ["--working-directory"] = true,
  ["--description"] = true, ["--slice"] = true, ["--service-type"] = true,
  ["--uid"] = true, ["--gid"] = true, ["--nice"] = true,
  ["--timer-property"] = true, ["--on-active"] = true, ["--on-calendar"] = true,
}

--- 解析 `systemd-run`：临时单元（后台服务），支持 `--unit`/`--wait`/`--user`/
--- `--setenv`(`-E`)/`--working-directory`/`-p WorkingDirectory=`；`--pipe`/`-P`/`--pty`/`-t`/
--- `--scope`（前台/管道 IO）按后台服务执行并回传输出与退出码（真实无 tty，但不再报不支持）。
--- @param toks table
--- @param i number 指向 `systemd-run` 之后的第一个 token
--- @param raw string
--- @return table|nil
function M._parse_systemd_run(toks, i, raw)
  local unit, scope, wait = nil, "system", false
  local workdir, env, pipe = nil, {}, false
  local rest = {}
  while i <= #toks do
    local t = toks[i]
    if t == "--" then
      i = i + 1
      while i <= #toks do rest[#rest + 1] = toks[i]; i = i + 1 end
      break
    elseif t:sub(1, 1) == "-" and t ~= "-" then
      local name, val = t:match("^([^=]+)=(.*)$")
      name = name or t
      if name == "--unit" or name == "-u" then
        unit = val
        if not unit and toks[i + 1] and toks[i + 1]:sub(1, 1) ~= "-" then unit = toks[i + 1]; i = i + 1 end
      elseif name == "--wait" then
        wait = true
      elseif name == "--user" then
        scope = "user"
      elseif name == "--scope" or name == "-t" or name == "--pty" or name == "-P"
        or name == "--pipe" or name == "--shell" then
        -- 前台/管道/交互 IO：以后台服务执行并等待，回传其输出与退出码（`--pipe` 语义）。
        pipe = true
        wait = true
      elseif name == "--property" or name == "-p" then
        local p = val
        if not p and toks[i + 1] then p = toks[i + 1]; i = i + 1 end
        local pk, pv = tostring(p or ""):match("^([^=]+)=(.*)$")
        if pk == "WorkingDirectory" then workdir = pv
        elseif pk == "Environment" then
          for tok in tostring(pv or ""):gmatch('"[^"]*"|%S+') do
            local clean = tok:gsub('^"', ""):gsub('"$', "")
            local k, v = clean:match("^([%w_]+)=(.*)$")
            if k then env[k] = v end
          end
        end
      elseif name == "--setenv" or name == "-E" then
        local kv = val
        if not kv and toks[i + 1] then kv = toks[i + 1]; i = i + 1 end
        local k, v = tostring(kv or ""):match("^([%w_]+)=(.*)$")
        if k then env[k] = v end
      elseif name == "--working-directory" then
        workdir = val
        if not workdir and toks[i + 1] then workdir = toks[i + 1]; i = i + 1 end
      elseif name == "--description" then
        if not val and toks[i + 1] then i = i + 1 end
      elseif RUN_OPT_VALUE[name] then
        if not val and toks[i + 1] then i = i + 1 end
      end
      -- 其余布尔选项（--collect/--same-dir/--quiet 等）忽略。
    else
      -- getopt 语义：第一个非选项 token 起为命令及其参数，后续 `-x` 属于命令本身。
      while i <= #toks do rest[#rest + 1] = toks[i]; i = i + 1 end
      break
    end
    i = i + 1
  end
  if #rest == 0 and not unit then return nil end
  return {
    kind = "systemd-run", verb = "run", route = "facade", scope = scope,
    units = unit and { unit } or {}, argv = rest, wait = wait, pipe = pipe,
    workdir = workdir, env = env, raw = raw,
  }
end

--- 解析 `systemd-analyze`：动词缺省为 `time`（真实行为）；`--version`/`-V` 单独处理。
--- @param toks table
--- @param i number 指向 `systemd-analyze` 之后的第一个 token
--- @param raw string
--- @return table
function M._parse_systemd_analyze(toks, i, raw)
  local opts, verb, version = {}, nil, false
  while i <= #toks do
    local t = toks[i]
    if t == "--version" or t == "-V" then
      version = true
    elseif t:sub(1, 1) == "-" and t ~= "-" then
      opts[#opts + 1] = t
    elseif not verb then
      verb = t
    end
    i = i + 1
  end
  if version then
    return { kind = "systemd-analyze", verb = "version", opts = opts, units = {}, route = "facade", raw = raw }
  end
  return {
    kind = "systemd-analyze", verb = verb or "time", opts = opts, units = {},
    route = "facade", raw = raw,
  }
end

--- 通用解析：选项 + 可选动词 + 参数（hostnamectl/timedatectl/dmesg 共用）。
--- @param toks table
--- @param i number
--- @param raw string
--- @param kind string
--- @param default_verb string|nil
--- @return table
function M._parse_simple_tool(toks, i, raw, kind, default_verb)
  local opts, args, verb = {}, {}, nil
  while i <= #toks do
    local t = toks[i]
    if t == "--" then
      i = i + 1
      while i <= #toks do args[#args + 1] = toks[i]; i = i + 1 end
      break
    elseif t:sub(1, 1) == "-" and t ~= "-" then
      opts[#opts + 1] = t
    elseif default_verb ~= nil and not verb then
      verb = t
    else
      args[#args + 1] = t
    end
    i = i + 1
  end
  return {
    kind = kind, verb = verb or default_verb, opts = opts, args = args,
    units = {}, route = "facade", raw = raw,
  }
end

--- 单元名归一化：无已知后缀则补 `.service`。
--- @param name string
--- @return string
local function _normalize_unit_name(name)
  for _, suf in ipairs(KNOWN_SUFFIXES) do
    if name:sub(-#suf) == suf then return name end
  end
  return name .. ".service"
end

-- 会话私有临时根：仅 `/run`（/run/systemd/system、/run/systemd/user 是标准单元根）。沙箱内
-- `/run` 绑定到宿主侧会话私有目录，门面必须读该目录（否则看不到沙箱写入，且会泄漏宿主运行时
-- 单元）。`/tmp`、`/var/tmp` 非标准单元根，且自定义 unit_roots 可能位于其下，故不映射。
local VIEW_TMP_ROOTS = { "/run" }

--- 沙箱内路径若属于映射的临时根，映射到宿主侧会话私有目录；否则返回 nil。
--- @param path string
--- @return string|nil
local function _guest_tmp_host(path)
  local ok, runtime = pcall(require, "NeoAI.sandbox.runtime")
  if not ok or type(runtime.host_tmp_dir) ~= "function" then return nil end
  for _, root in ipairs(VIEW_TMP_ROOTS) do
    if path == root or path:sub(1, #root + 1) == root .. "/" then
      return runtime.host_tmp_dir(root) .. path:sub(#root + 1)
    end
  end
  return nil
end

--- 读取文件内容（同一私有视图）：
---   1. 临时根（`/tmp`、`/var/tmp`、`/run`）→ 宿主侧会话私有目录（**不回退**宿主真实目录）；
---   2. 其余路径 → 优先沙箱暂存副本（overlay 上的 AI 编辑），否则宿主真实文件。
--- @param path string
--- @return string|nil content
--- @return string|nil staged_path
local function _read_view(path)
  local mapped = _guest_tmp_host(path)
  if mapped then
    if not fs.exists(mapped) then return nil, nil end
    local okc, c = pcall(fs.read_file, mapped)
    if okc and type(c) == "string" then return c, mapped end
    return nil, nil
  end
  local staged = nil
  local ok, candidate = pcall(require, "NeoAI.sandbox.candidate")
  if ok and candidate and type(candidate.read_path) == "function" then
    local sp = candidate.read_path(path)
    if sp and fs.exists(sp) then staged = sp end
  end
  local read = staged or path
  if not staged then
    -- 整机根 overlay：命令写入 /etc、/usr 等落在 overlay upper（宿主真实路径看不到），
    -- 门面须读 upper 才能与沙箱同一视图（否则 AI 写的单元 systemctl 看不到）。
    local okr, runtime = pcall(require, "NeoAI.sandbox.runtime")
    if okr and type(runtime.root_overlay_uppers) == "function" then
      for _, up in ipairs(runtime.root_overlay_uppers()) do
        local cand = up .. path
        if fs.exists(cand) then read = cand; break end
      end
    end
  end
  if not fs.exists(read) then return nil, staged end
  local ok2, content = pcall(fs.read_file, read)
  if not ok2 or type(content) ~= "string" then return nil, staged end
  return content, staged
end

--- 解析 INI 风格 unit 文件（[Section] Key=Value，支持 `\` 续行与注释）。
--- @param content string
--- @return table sections { [section] = { [key] = { values... } } }
local function _parse_ini(content)
  local sections = {}
  local cur = nil
  local pending = ""
  local function flush()
    if pending == "" then return end
    local line = pending
    pending = ""
    local trimmed = line:gsub("^%s+", "")
    if trimmed == "" or trimmed:sub(1, 1) == "#" or trimmed:sub(1, 1) == ";" then return end
    local sec = trimmed:match("^%[([^%]]+)%]%s*$")
    if sec then
      cur = sec
      sections[cur] = sections[cur] or {}
      return
    end
    local key, val = trimmed:match("^([%w_%-%.]+)%s*=%s*(.*)$")
    if key and cur then
      local bucket = sections[cur][key] or {}
      bucket[#bucket + 1] = val
      sections[cur][key] = bucket
    end
  end
  for raw in tostring(content):gmatch("([^\n]*)\n?") do
    local line = raw:gsub("\r$", "")
    if line:sub(-1) == "\\" then
      pending = pending .. line:sub(1, -2)
    else
      pending = pending .. line
      flush()
    end
  end
  flush()
  return sections
end

--- @param sections table
--- @param sec string
--- @param key string
--- @return string|nil first
--- @return table values
local function _get(sections, sec, key)
  local s = sections[sec]
  if not s or not s[key] then return nil, {} end
  return s[key][1], s[key]
end

--- 展开 `${VAR}`（`$$` → 字面 `$`）。未定义变量展开为空（systemd 语义）。
--- **不**展开裸 `$VAR`：真实 systemd 只支持 `${VAR}`，裸 `$i` 原样传给进程（避免把
--- `ExecStart=/bin/sh -c 'i=1; [ $i -lt 2 ]'` 里的 `$i` 误展开为空导致 `[: -lt:` 报错）。
--- @param value string
--- @param env table
--- @return string
local function _expand_env(value, env)
  local out = value:gsub("%$%$", "\1")
  out = out:gsub("%${([%w_]+)}", function(k) return env[k] or "" end)
  return (out:gsub("\1", "$"))
end

--- 展开 systemd 说明符（`%n`/`%N`/`%p`/`%i`/`%u`/`%h`/`%t`…，`%%` → 字面 `%`）。
--- 与真实 systemd 对齐：`%n` 单元全名、`%N` 去类型后缀、`%p` 前缀、`%i` 实例（非模板为空）、
--- `%j` 前缀末段、`%u`/`%h`/`%s` 运行用户/家目录/shell、`%t`/`%T` 运行时/临时目录。
--- 未知说明符保留原文（真实 systemd 会拒绝，这里 best-effort，避免把非说明符的 `%` 误删）。
--- @param value string
--- @param name string 单元全名（如 demo@inst.service）
--- @return string
local function _expand_specifiers(value, name)
  local base = name:match("^(.*)%.[%w]+$") or name
  local prefix, instance = base:match("^([^@]*)@(.*)$")
  if not prefix then prefix, instance = base, "" end
  local home = vim.fn.expand("~")
  if home == "" or home == "~" then home = "/root" end
  local uid = 0
  pcall(function()
    local pw = vim.uv.os_get_passwd()
    if pw and pw.uid then uid = pw.uid end
  end)
  local map = {
    ["%"] = "%",
    n = name,
    N = base,
    p = prefix,
    P = prefix,
    i = instance,
    I = instance,
    j = prefix:match("([^/]+)$") or prefix,
    u = os.getenv("USER") or os.getenv("LOGNAME") or "root",
    U = tostring(uid),
    h = home,
    s = os.getenv("SHELL") or "/bin/sh",
    t = "/run",
    T = "/tmp",
  }
  return (value:gsub("%%(.)", function(c) return map[c] or ("%" .. c) end))
end

--- 按 shell 规则切分 ExecStart 参数（支持引号与反斜杠）。
--- @param s string
--- @return table argv
--- @return string|nil err
local function _split_args(s)
  local argv, buf, quote = {}, {}, nil
  local i, n = 1, #s
  while i <= n do
    local ch = s:sub(i, i)
    if quote then
      if ch == quote then
        quote = nil
      elseif ch == "\\" and quote == '"' and i < n then
        i = i + 1
        buf[#buf + 1] = s:sub(i, i)
      else
        buf[#buf + 1] = ch
      end
    elseif ch == "'" or ch == '"' then
      quote = ch
    elseif ch == "\\" and i < n then
      i = i + 1
      buf[#buf + 1] = s:sub(i, i)
    elseif ch:match("%s") then
      if #buf > 0 then argv[#argv + 1] = table.concat(buf); buf = {} end
    else
      buf[#buf + 1] = ch
    end
    i = i + 1
  end
  if quote then return {}, "UNBALANCED_QUOTE" end
  if #buf > 0 then argv[#argv + 1] = table.concat(buf) end
  return argv, nil
end

--- 解析 Environment= / EnvironmentFile 不支持时的环境变量。
--- @param sections table
--- @return table env
--- @return string|nil err
local function _parse_environment(sections)
  local env = {}
  local _, vals = _get(sections, "Service", "Environment")
  for _, raw in ipairs(vals or {}) do
    local rest = raw
    while rest and rest ~= "" do
      local token
      local q = rest:match('^%s*"([^"]*)"')
      if q then
        token = q
        rest = rest:sub(#q + 3)
      else
        token = rest:match("^%s*(%S+)")
        if token then rest = rest:sub(#token + 1) else rest = "" end
      end
      if token and token ~= "" then
        local k, v = token:match("^([%w_]+)=(.*)$")
        if k then env[k] = v end
      end
    end
  end
  return env
end

--- 解析 unit 文件内容。
--- @param content string
--- @param name string
--- @return table|nil unit
--- @return string|nil err
function M.parse_unit(content, name)
  local sections = _parse_ini(content)
  local svc = sections["Service"] or {}
  local typ = svc.Type and svc.Type[1] or "simple"
  typ = tostring(typ):gsub("%s+$", "")
  if not SUPPORTED_TYPES[typ] then
    return nil, "Unit has an unsupported Type= setting: " .. typ
  end

  local env, eerr = _parse_environment(sections)
  if eerr then return nil, eerr end

  -- ExecStart 列表：先展开说明符与环境变量，再切分 argv。空值 `ExecStart=` 表示重置列表
  -- （systemd 语义）。oneshot 允许多条（顺序执行）；其余类型取最后一条（后写覆盖）。
  local exec_vals = svc.ExecStart or {}
  local exec_raws = {}
  for _, raw in ipairs(exec_vals) do
    local r = raw:match("^[%-@:+!]*(.*)$") or raw
    r = _expand_specifiers(r, name)
    r = _expand_env(r, env)
    if r:match("^%s*$") then
      exec_raws = {}
    else
      exec_raws[#exec_raws + 1] = r
    end
  end
  if #exec_raws == 0 then
    return nil, "单元缺少 ExecStart（沙箱门面不支持无 ExecStart 的单元）"
  end
  if not _is_oneshot(typ) and #exec_raws > 1 then
    exec_raws = { exec_raws[#exec_raws] }
  end
  local argv_list = {}
  for _, r in ipairs(exec_raws) do
    local argv, aerr = _split_args(r)
    if aerr then return nil, "ExecStart 解析失败：" .. aerr end
    if #argv == 0 then return nil, "ExecStart 为空" end
    argv_list[#argv_list + 1] = argv
  end
  local argv = argv_list[1]
  local exec_raw = exec_raws[1]

  local workdir = nil
  local wd = _get(sections, "Service", "WorkingDirectory")
  if wd and wd ~= "" and wd ~= "-" then
    wd = wd:gsub("^%-", "")
    workdir = _expand_env(_expand_specifiers(wd, name), env)
  end

  -- User=/Group=：沙箱载荷以固定沙箱身份运行，无法在门面内切换用户；接受该设置并按当前
  -- 沙箱身份执行（best-effort，不报错），使 `User=root` 等常见单元可正常启动。
  local run_user = _get(sections, "Service", "User")
  local run_group = _get(sections, "Service", "Group")
  if _get(sections, "Socket") then
    return nil, "沙箱环境不支持 socket 单元"
  end

  local requires, wants = {}, {}
  local _, req_vals = _get(sections, "Unit", "Requires")
  for _, line in ipairs(req_vals or {}) do
    for tok in line:gmatch("%S+") do requires[#requires + 1] = _normalize_unit_name(tok) end
  end
  local _, want_vals = _get(sections, "Unit", "Wants")
  for _, line in ipairs(want_vals or {}) do
    for tok in line:gmatch("%S+") do wants[#wants + 1] = _normalize_unit_name(tok) end
  end
  local after, before = {}, {}
  local _, after_vals = _get(sections, "Unit", "After")
  for _, line in ipairs(after_vals or {}) do
    for tok in line:gmatch("%S+") do after[#after + 1] = _normalize_unit_name(tok) end
  end
  local _, before_vals = _get(sections, "Unit", "Before")
  for _, line in ipairs(before_vals or {}) do
    for tok in line:gmatch("%S+") do before[#before + 1] = _normalize_unit_name(tok) end
  end
  for _, unsup in ipairs({ "Requisite", "BindsTo", "PartOf", "OnFailure" }) do
    if _get(sections, "Unit", unsup) then
      return nil, "沙箱门面不支持 " .. unsup .. "="
    end
  end

  local desc = _get(sections, "Unit", "Description")
  return {
    name = name,
    description = desc or name,
    type = typ,
    argv = argv,
    argv_list = argv_list,
    exec = exec_raw,
    env = env,
    workdir = workdir,
    user = run_user,
    group = run_group,
    requires = requires,
    wants = wants,
    after = after,
    before = before,
  }
end

--- 定位并加载一个单元（优先沙箱暂存副本）。
--- @param name string
--- @param scope string|nil "system"（默认）| "user"
--- @return table|nil unit
--- @return string|nil err
--- @return string|nil path
local function _load_unit(name, scope)
  local norm = _normalize_unit_name(name)
  if norm:find("@") then
    return nil, "沙箱门面不支持模板/实例化单元：" .. name
  end
  local suffix = norm:match("(%.[%w]+)$")
  if suffix and suffix ~= ".service" and suffix ~= ".target" then
    return nil, "沙箱环境不支持 " .. suffix .. " 单元（仅支持 .service/.target）"
  end
  for _, root in ipairs(_unit_roots(scope)) do
    local path = root .. "/" .. norm
    local content = _read_view(path)
    if content then
      if norm:sub(-8) == ".target" then
        return { name = norm, target = true, description = norm, requires = {}, wants = {}, after = {}, before = {} }, nil, path
      end
      local unit, err = M.parse_unit(content, norm)
      if not unit then return nil, err, path end
      unit.path = path
      return unit, nil, path
    end
  end
  -- systemd-run 创建的瞬态单元没有单元文件，但在 sandbox.service 中有运行态：返回伪 unit
  -- （含 command）使 start/stop/restart/status/show/cat 与文件单元一致处理。
  local svc = _svc()
  local key = (scope == "user" and "user-unit:" or "unit:") .. norm
  local info = svc and svc.status(key) or nil
  if info then
    return {
      name = norm, transient = true, command = info.command,
      description = info.command or norm, type = "simple",
      argv = {}, env = {}, workdir = info.cwd,
      requires = {}, wants = {}, after = {}, before = {},
    }, nil, nil
  end
  return nil, "Unit " .. norm .. " not found（沙箱内未找到该 unit 文件）"
end

--- 依赖闭包（Requires/Wants 递归 + After/Before 拓扑排序）。
--- @param names table 请求的单元名
--- @param max number
--- @param scope string|nil "system"（默认）| "user"
--- @return table|nil ordered 单元名列表
--- @return table|nil units map
--- @return string|nil err
function M.resolve_closure(names, max, scope)
  local units, ordered, visiting = {}, {}, {}
  local function load(name)
    if units[name] then return units[name] end
    local unit, err = _load_unit(name, scope)
    if not unit then return nil, err end
    units[name] = unit
    return unit
  end
  local function visit(name, required)
    if ordered[name] then return true end
    if visiting[name] then return true end -- 环：忽略顺序，避免死循环
    visiting[name] = true
    local unit, err = load(name)
    if not unit then
      visiting[name] = nil
      -- Wants 缺失忽略；Requires 缺失报错，但 .target 常无独立文件，容忍。
      if not required or name:sub(-8) == ".target" then return true end
      return nil, err
    end
    if #ordered >= max then
      visiting[name] = nil
      return nil, "依赖数量超过上限 " .. tostring(max)
    end
    for _, dep in ipairs(unit.requires) do
      local ok, derr = visit(dep, true)
      if not ok then return nil, derr end
    end
    for _, dep in ipairs(unit.wants or {}) do
      local ok, derr = visit(dep, false)
      if not ok then return nil, derr end
    end
    visiting[name] = nil
    ordered[name] = true
    ordered[#ordered + 1] = name
    return true
  end
  for _, name in ipairs(names) do
    local ok, err = visit(_normalize_unit_name(name), true)
    if not ok then return nil, nil, err end
  end
  -- After 排序：A After B → B 先于 A（仅当两者都在闭包内）。
  local pos = {}
  for i, n in ipairs(ordered) do pos[n] = i end
  local changed = true
  local guard = 0
  while changed and guard < #ordered * #ordered + 1 do
    changed = false
    guard = guard + 1
    for i = 1, #ordered do
      local n = ordered[i]
      local u = units[n]
      for _, dep in ipairs(u.after or {}) do
        if pos[dep] and pos[dep] > i then
          ordered[i], ordered[pos[dep]] = ordered[pos[dep]], ordered[i]
          pos[ordered[i]], pos[ordered[pos[dep]]] = i, pos[dep]
          changed = true
        end
      end
    end
  end
  return ordered, units, nil
end

--- 成功结果（systemctl 成功通常静默）。
--- @param stdout string|nil
--- @return table
local function _ok(stdout)
  return { stdout = stdout or "", stderr = "", code = 0 }
end

--- 失败结果（真实 systemctl 风格错误 + 退出码）。
--- @param stderr string|nil
--- @param code number|nil
--- @return table
local function _fail(stderr, code)
  return { stdout = "", stderr = stderr or "", code = code or 1 }
end

--- shell 单引号转义并拼接（systemd-run 的 argv 交给 sandbox.service 以 shell 执行）。
--- @param argv table
--- @return string
local function _quote_argv(argv)
  local out = {}
  for _, a in ipairs(argv) do
    out[#out + 1] = "'" .. tostring(a):gsub("'", "'\\''") .. "'"
  end
  return table.concat(out, " ")
end

--- 生成真实风格的临时单元名（`run-r<hex>.service`）。
--- @return string
local function _transient_name()
  local hex = {}
  for _ = 1, 32 do hex[#hex + 1] = string.format("%x", math.random(0, 15)) end
  return "run-r" .. table.concat(hex) .. ".service"
end

--- @param unit table
--- @param scope string|nil "system"（默认）| "user"
--- @return string
local function _unit_key(unit, scope)
  return (scope == "user" and "user-unit:" or "unit:") .. unit.name
end

--- 沙箱服务运行态（门面启动的单元 / systemd-run 瞬态单元）；无则 nil。
--- @param name string
--- @param scope string
--- @return table|nil
local function _runtime_info(name, scope)
  local svc = _svc()
  if not svc then return nil end
  return svc.status(_unit_key({ name = name }, scope))
end

--- @param text string
--- @return string
local function _redact(text)
  local ok, conceal = pcall(require, "NeoAI.sandbox.conceal")
  if ok and conceal and conceal.redact then
    local ok2, out = pcall(conceal.redact, text)
    if ok2 and type(out) == "string" then return out end
  end
  return text
end

--- 启动一个已解析单元（不处理依赖）。
--- @param unit table
--- @param scope string|nil "system"（默认）| "user"
--- @return table|nil svc
--- @return string|nil err
local function _start_one(unit, scope)
  if unit.target then return { name = unit.name, target = true }, nil end
  local svc = _svc()
  if not svc then return nil, "长驻服务模块不可用" end
  local key = _unit_key(unit, scope)
  local existing = svc.status(key)
  if existing and (existing.status == "running" or existing.status == "exited") then
    -- 已在运行，或 oneshot 已结束（真实 systemctl start 幂等）。
    return existing, nil
  end
  local command
  if unit.transient then
    command = unit.command
    if not command or command == "" then return nil, "瞬态单元缺少命令" end
  else
    -- 单元 ExecStart 是 argv（execvp 语义），交给服务的 shell 前逐参数单引号转义，
    -- 保留参数边界（如 `sh -c 'exit 3'` 不能被拆成 `sh -c exit 3`）。oneshot 多条按序以
    -- `&&` 串联（任一条失败即停止，与真实 systemd 的 oneshot 顺序执行语义一致）。
    local list = unit.argv_list or { unit.argv }
    local parts = {}
    for _, a in ipairs(list) do parts[#parts + 1] = _quote_argv(a) end
    command = table.concat(parts, " && ")
  end
  local started, err = svc.start(key, command, {
    workdir = unit.workdir,
    cwd = unit.workdir,
    env = unit.env,
    unit = unit.name,
  })
  if not started then return nil, err or ("启动失败：" .. unit.name) end
  return started, nil
end

--- 等待单元进程结束（用于 oneshot：真实 `systemctl start` 会阻塞到单元退出）。
--- @param name string
--- @param scope string
--- @return Deferred resolve(exit_code)
local function _wait_service(name, scope)
  local d = async.Deferred.new()
  local deadline = vim.uv.now() + (tonumber(_cfg().start_timeout_ms) or 30000)
  local function poll()
    local info = _runtime_info(name, scope)
    if not info or info.status == "exited" then
      d:resolve(tonumber(info and info.exit_code) or 0)
      return
    end
    if vim.uv.now() >= deadline then d:resolve(0); return end
    vim.defer_fn(poll, 30)
  end
  poll()
  return d
end

--- 按序启动单元；`oneshot` 启动后等待其结束（真实 `systemctl start` 会阻塞到单元退出），
--- 退出码非零则返回真实风格错误。resolve `{ok=true}` 或 `{err=string}`。
--- @param ordered table
--- @param unitmap table
--- @param scope string
--- @return Deferred
local function _start_ordered(ordered, unitmap, scope)
  local d = async.Deferred.new()
  local function step(i)
    if i > #ordered then d:resolve({ ok = true }); return end
    local name = ordered[i]
    local unit = unitmap[name]
    local svc, serr = _start_one(unit, scope)
    if not svc then
      d:resolve({ err = string.format("Failed to start %s: %s.", name, tostring(serr)) })
      return
    end
    if _is_oneshot(unit.type) then
      _wait_service(name, scope):then_(function(rc)
        if rc ~= 0 then
          d:resolve({ err = string.format(
            "Job for %s failed because the control process exited with error code %d.\n"
            .. 'See "systemctl status %s" and "journalctl -xe" for details.', name, rc, name) })
        else
          step(i + 1)
        end
      end, function() step(i + 1) end)
    else
      step(i + 1)
    end
  end
  step(1)
  return d
end

--- 停止一个单元（异步）。
--- @param unit table
--- @param scope string|nil "system"（默认）| "user"
--- @return Deferred
local function _stop_one(unit, scope)
  local svc = _svc()
  if not svc then return async.reject("长驻服务模块不可用") end
  local d = async.Deferred.new()
  svc.stop(_unit_key(unit, scope), function(err)
    if err then return d:reject(err) end
    d:resolve(true)
  end)
  return d
end

--- 明确拒绝动词的真实 systemctl 风格错误文本（不暴露沙箱）。
--- @param verb string
--- @param unit string|nil
--- @return string
function M.reject_text(verb, unit)
  local u = unit and _normalize_unit_name(unit) or nil
  if verb == "reload" or verb == "reload-or-restart" or verb == "try-reload-or-restart" then
    if u then
      return "Failed to reload " .. u .. ": Job type reload is not applicable for unit " .. u .. "."
    end
    return "Failed to reload: Job type reload is not applicable."
  end
  if verb == "kill" then
    return "Failed to kill unit: Operation not permitted"
  end
  if verb == "mask" or verb == "unmask" or verb == "link" or verb == "revert" then
    if u then return "Failed to " .. verb .. " unit: Unit file " .. u .. " does not exist." end
    return "Failed to " .. tostring(verb) .. " unit: Unit file does not exist."
  end
  if verb == "poweroff" or verb == "reboot" or verb == "halt" or verb == "kexec" then
    return "Failed to " .. tostring(verb) .. " system via logind: Access denied"
  end
  if verb == "suspend" or verb == "hibernate" or verb == "hybrid-sleep"
    or verb == "suspend-then-hibernate" then
    return "Failed to " .. tostring(verb) .. " system via logind: Access denied"
  end
  if verb == "rescue" or verb == "emergency" or verb == "isolate" then
    return "Failed to " .. tostring(verb) .. ": Operation not permitted"
  end
  return "Unknown command verb '" .. tostring(verb) .. "'."
end

--- @param msg string
--- @return string
function M.error_text(msg)
  return _redact("systemctl: " .. tostring(msg))
end

-- ========== 公开 API ==========

--- 计算并暂存 systemd `enable`/`disable` 的符号链接变更（不落宿主机，进入待审）。
--- enable：解析单元 `[Install] WantedBy/RequiredBy`，在 `/etc/systemd/system/<target>.wants/`
--- 下暂存指向单元文件的软链候选；disable：删除各单元根下已有的 `<target>.wants/<unit>` 软链。
--- @param attempt table
--- @param plan table M.parse_command 结果（verb=enable/disable）
--- @param ctx table
--- @param spec table
--- @return Deferred
function M.stage_install(attempt, plan, ctx, spec)
  local control = require("NeoAI.sandbox.control")
  local candidate = require("NeoAI.sandbox.candidate")
  local store = require("NeoAI.sandbox.store")
  local wrapper = require("NeoAI.sandbox.wrapper")
  local root = store.root() or (vim.fn.stdpath("cache") .. "/NeoAI/sandbox")
  local scope = plan.scope or "system"
  local unit_name = plan.units[1]
  if not unit_name then
    return async.resolve(_fail("Failed to " .. tostring(plan.verb) .. " unit: Invalid argument.", 1))
  end
  unit_name = _normalize_unit_name(unit_name)
  local unit, uerr, upath = _load_unit(unit_name, scope)
  if not unit then
    return async.resolve(_fail(
      string.format("Failed to %s unit: Unit file %s does not exist.", tostring(plan.verb), unit_name), 1))
  end
  local unit_path = unit.path or upath

  control.transition(attempt, "STAGING")
  candidate.begin(attempt, root)
  local staged, links = 0, {}
  if plan.verb == "enable" then
    local content = _read_view(unit_path)
    local sections = content and _parse_ini(content) or {}
    local targets = {}
    local function add_targets(key)
      local _, vals = _get(sections, "Install", key)
      for _, line in ipairs(vals or {}) do
        for tok in line:gmatch("%S+") do targets[#targets + 1] = tok end
      end
    end
    add_targets("WantedBy")
    add_targets("RequiredBy")
    if #targets == 0 then
      candidate.cleanup(attempt.attempt_id)
      return async.resolve(_fail(
        "The unit files have no installation config (WantedBy=, RequiredBy=, Also=, Alias= settings "
        .. "in the [Install] section, and DefaultInstance= for template units). This means they are "
        .. "not meant to be enabled using systemctl.", 1))
    end
    local admin_root = scope == "user" and _user_admin_root() or "/etc/systemd/system"
    for _, t in ipairs(targets) do
      local link = admin_root .. "/" .. t .. ".wants/" .. unit_name
      if candidate.stage_link(attempt.attempt_id, link, unit_path) then
        staged = staged + 1; links[#links + 1] = link
      end
    end
  else
    for _, r in ipairs(_unit_roots(scope)) do
      local handle = vim.uv.fs_scandir(r)
      if handle then
        while true do
          local name, t = vim.uv.fs_scandir_next(handle)
          if not name then break end
          if t == "directory" and name:sub(-6) == ".wants" then
            local link = r .. "/" .. name .. "/" .. unit_name
            local lst = vim.uv.fs_lstat(link)
            if lst and lst.type == "link" then
              if candidate.stage_delete(attempt.attempt_id, link) then
                staged = staged + 1; links[#links + 1] = link
              end
            end
          end
        end
      end
    end
  end

  local cand = candidate.finish(attempt.attempt_id)
  if not cand or #(cand.files or {}) == 0 then
    candidate.cleanup(attempt.attempt_id)
    control.transition(attempt, "COMPLETED_READ_ONLY")
    return async.resolve(_ok(""))
  end
  cand.command_id = attempt.command_id
  wrapper.settle_exec_candidate(attempt, cand, ctx or {}, spec, { code = 0 }, { command = plan.raw })
  local msgs = {}
  for _, link in ipairs(links) do
    if plan.verb == "disable" then
      msgs[#msgs + 1] = string.format('Removed "%s".', link)
    else
      msgs[#msgs + 1] = string.format("Created symlink %s → %s.", link, unit_path)
    end
  end
  return async.resolve(_ok(table.concat(msgs, "\n")))
end

-- ========== 真实行为（门面与沙箱内 shim 共用；所有解析/实现都在 Lua） ==========

--- 宿主真实 systemd 版本字符串（两行），失败回退常量。缓存。
local _host_ver_cache
local function _host_version()
  if _host_ver_cache ~= nil then return _host_ver_cache end
  local out = ""
  pcall(function()
    local real = vim.fn.exepath("systemctl")
    if real ~= "" then out = vim.fn.system({ real, "--version" }) or "" end
  end)
  out = tostring(out):gsub("%s+$", "")
  if out == "" then out = "systemd 255" end
  _host_ver_cache = out
  return out
end

--- @return string
local function _hostname()
  local ok, h = pcall(vim.uv.os_gethostname)
  if ok and type(h) == "string" and h ~= "" then return h end
  return "localhost"
end

--- @param epoch number|nil
--- @return string
local function _stamp(epoch)
  return os.date("%a %Y-%m-%d %H:%M:%S", epoch)
end

--- @return string
local function _now_stamp()
  return _stamp(os.time())
end

--- 在单元根中定位单元（优先暂存副本）；返回规范化名与真实根路径（不含沙箱内部路径）。
--- @param name string
--- @param scope string
--- @return string norm
--- @return string|nil path
local function _unit_find(name, scope)
  local norm = _normalize_unit_name(name)
  for _, root in ipairs(_unit_roots(scope)) do
    local path = root .. "/" .. norm
    local content = _read_view(path)
    if content then return norm, path end
  end
  return norm, nil
end

--- @param path string|nil
--- @return table targets
local function _install_targets(path)
  if not path then return {} end
  local content = _read_view(path)
  local sections = content and _parse_ini(content) or {}
  local targets = {}
  for _, key in ipairs({ "WantedBy", "RequiredBy" }) do
    local _, vals = _get(sections, "Install", key)
    for _, line in ipairs(vals or {}) do
      for tok in line:gmatch("%S+") do targets[#targets + 1] = tok end
    end
  end
  return targets, sections
end

--- is-enabled 语义：enabled/disabled/static/masked/not-found + LSB 退出码。
--- @param name string
--- @param scope string
--- @param path string|nil
--- @return string
--- @return number
local function _enabled_state(name, scope, path)
  if not path then return "not-found", 4 end
  for _, root in ipairs(_unit_roots(scope)) do
    local l = root .. "/" .. name
    local st = vim.uv.fs_lstat(l)
    if st and st.type == "link" then
      local tgt = nil
      pcall(function() tgt = vim.uv.fs_readlink(l) end)
      if tgt == "/dev/null" then return "masked", 1 end
    end
  end
  local targets = _install_targets(path)
  if #targets == 0 then return "static", 0 end
  for _, root in ipairs(_unit_roots(scope)) do
    for _, t in ipairs(targets) do
      local link = root .. "/" .. t .. ".wants/" .. name
      local st = vim.uv.fs_lstat(link)
      if st and st.type == "link" then return "enabled", 0 end
    end
  end
  return "disabled", 1
end

--- 服务运行态：active/inactive/failed/activating/deactivating + 退出码 + 服务信息。
--- @param name string
--- @param scope string
--- @return string
--- @return number
--- @return table|nil
local function _active_state(name, scope)
  local svc = _svc()
  local key = _unit_key({ name = name }, scope)
  local info = svc and svc.status(key) or nil
  if info then
    if info.status == "running" then return "active", 0, info end
    if info.status == "starting" then return "activating", 0, info end
    if info.status == "stopping" then return "deactivating", 0, info end
    if info.status == "exited" then
      -- 进程已结束：退出码非零才是 failed；零退出按 inactive(dead)（未跟踪 RemainAfterExit）。
      -- 真实 systemd 的 oneshot 成功既不是 failed、`is-active` 也不返回 3=inactive。
      local rc = tonumber(info.exit_code) or 0
      if rc ~= 0 then return "failed", 3, info end
      return "inactive", 3, info
    end
    return "inactive", 3, info
  end
  local base = _baseline(name, scope)
  if base then
    if stopped_baseline[name] then return "inactive", 3, nil end
    return base.active, 0, { baseline = true }
  end
  return "inactive", 3, nil
end

--- 子状态（list-units 的 SUB 列；真实 systemd：running/exited/dead/start/stop/failed）。
--- @param name string
--- @param scope string
--- @return string
local function _sub_state(name, scope)
  local active, _, info = _active_state(name, scope)
  if info and info.baseline then
    local base = _baseline(name, scope)
    return base and base.sub or "active"
  end
  local status = info and info.status or nil
  if status == "starting" then return "start" end
  if status == "stopping" then return "stop" end
  if status == "exited" then return "exited" end
  if active == "active" then return "running" end
  if active == "failed" then return "failed" end
  return "dead"
end

--- 门面自身的系统运行态：有失败单元 → degraded，否则 running。**不查询宿主** systemd
--- （否则会把宿主的 degraded 泄漏进沙箱，与门面呈现的「健康 systemd」自相矛盾）。
--- @return string
local function _facade_state()
  local svc = _svc()
  if svc then
    for _, info in ipairs(svc.list()) do
      if info.status == "exited" and (tonumber(info.exit_code) or 0) ~= 0 then
        return "degraded"
      end
    end
  end
  return "running"
end

--- @param opts table|nil
--- @param name string
--- @return boolean
local function _has_opt(opts, name)
  for _, o in ipairs(opts or {}) do
    if o == name or tostring(o):sub(1, #name + 1) == name .. "=" then return true end
  end
  return false
end

--- 收集 `--state=` / `-t|--type=` / `--failed` / `--all` 过滤条件（list-units/list-unit-files）。
--- `--state` 可逗号分隔，且匹配真实 systemd 语义：LOAD/ACTIVE/SUB 任一命中即保留。
--- @param opts table|nil
--- @return table { states=set, types=set, failed=bool, all=bool }
local function _list_filters(opts)
  local states, types = {}, {}
  local failed, all = false, false
  for _, o in ipairs(opts or {}) do
    local k, v = tostring(o):match("^([^=]+)=(.*)$")
    if k == "--state" then
      for s in tostring(v):gmatch("[^,]+") do if s ~= "" then states[s] = true end end
    elseif k == "--type" or k == "-t" then
      if v ~= "" then types[v] = true end
    elseif o == "--failed" then
      failed = true
    elseif o == "--all" or o == "-a" then
      all = true
    end
  end
  return { states = states, types = types, failed = failed, all = all }
end

--- @param name string
--- @param types table
--- @return boolean
local function _type_match(name, types)
  if not next(types) then return true end
  local suf = name:match("(%.[%w]+)$")
  local t = suf and suf:sub(2)
  return (t ~= nil and types[t] == true)
end

--- 枚举单元根下的全部单元文件名（含已知后缀；真实 list-units 会涉及所有类型）。
--- @param scope string|nil
--- @return table names
local function _enum_units(scope)
  local seen, names = {}, {}
  local function scan(dir)
    if not fs.is_dir(dir) then return end
    for _, entry in ipairs(fs.list_dir(dir) or {}) do
      local n = type(entry) == "table" and entry.name or tostring(entry)
      if n and not seen[n] then
        local suf = n:match("(%.[%w]+)$")
        if suf and vim.tbl_contains(KNOWN_SUFFIXES, suf) then
          seen[n] = true
          names[#names + 1] = n
        end
      end
    end
  end
  for _, root in ipairs(_unit_roots(scope)) do
    -- 临时根（/run/systemd/system 等）只扫宿主侧会话私有目录，不扫宿主真实目录。
    local mapped = _guest_tmp_host(root)
    if mapped then
      scan(mapped)
    else
      scan(root)
      -- 整机根 overlay upper：命令写入的单元（/etc/systemd/system 等）。
      local okr, runtime = pcall(require, "NeoAI.sandbox.runtime")
      if okr and type(runtime.root_overlay_uppers) == "function" then
        for _, up in ipairs(runtime.root_overlay_uppers()) do scan(up .. root) end
      end
    end
  end
  return names
end

--- 单个单元 status 文本块。
--- @param name string
--- @param scope string
--- @return string|nil block
--- @return string|nil err
--- @return number code
local function _status_block(name, scope)
  local norm, path = _unit_find(name, scope)
  local base = _baseline(norm, scope)
  if not path and not base then
    -- 瞬态单元（systemd-run）：无单元文件但有运行态，合成真实风格 status。
    local rinfo = _runtime_info(norm, scope)
    if not rinfo then return nil, "Unit " .. norm .. " could not be found.", 4 end
    local active = "inactive"
    if rinfo.status == "running" then active = "active"
    elseif rinfo.status == "exited" and (tonumber(rinfo.exit_code) or 0) ~= 0 then active = "failed" end
    local sub = (active == "active" and "running")
      or (active == "failed" and "failed")
      or (rinfo.status == "exited" and "exited" or "dead")
    local dot = (active == "active") and "●" or "○"
    local lines = {
      string.format("%s %s - %s", dot, norm, tostring(rinfo.command or norm)),
      string.format("     Loaded: loaded (/run/systemd/transient/%s; transient)", norm),
    }
    if active == "active" then
      lines[#lines + 1] = string.format("     Active: active (%s) since %s; 0s ago", sub, _now_stamp())
      if rinfo.pid then
        lines[#lines + 1] = string.format("   Main PID: %d (%s)", rinfo.pid, norm:gsub("%.service$", ""))
      end
      lines[#lines + 1] = string.format("     CGroup: /system.slice/%s", norm)
      if rinfo.pid then
        lines[#lines + 1] = string.format("             └─%d %s", rinfo.pid, tostring(rinfo.command or norm))
      end
      return table.concat(lines, "\n"), nil, 0
    end
    lines[#lines + 1] = string.format("     Active: %s (%s)", active, sub)
    return table.concat(lines, "\n"), nil, 3
  end
  local content = path and _read_view(path) or nil
  local sections = content and _parse_ini(content) or {}
  local desc = _get(sections, "Unit", "Description") or (base and base.desc) or norm
  local active, _, info = _active_state(norm, scope)
  local sub = _sub_state(norm, scope)
  local enabled = select(1, _enabled_state(norm, scope, path))
  local dot = (active == "active") and "●" or "○"
  local loaded_src = path and string.format("(%s; %s; preset: enabled)", path, enabled) or "(builtin; static)"
  local lines = {
    string.format("%s %s - %s", dot, norm, desc),
    string.format("     Loaded: loaded %s", loaded_src),
  }
  if active == "active" then
    lines[#lines + 1] = string.format("     Active: active (%s) since %s; 0s ago", sub, _now_stamp())
    if info and info.pid then
      lines[#lines + 1] = string.format("   Main PID: %d (%s)", info.pid, norm:gsub("%.service$", ""))
    end
    lines[#lines + 1] = "      Tasks: 1 (limit: 8192)"
    lines[#lines + 1] = "     Memory: 1.0M"
    lines[#lines + 1] = "        CPU: 10ms"
    lines[#lines + 1] = string.format("     CGroup: /system.slice/%s", norm)
    if info and info.pid then
      lines[#lines + 1] = string.format("             └─%d %s", info.pid, tostring(info.command or norm))
    end
    return table.concat(lines, "\n"), nil, 0
  end
  lines[#lines + 1] = "     Active: inactive (dead)"
  return table.concat(lines, "\n"), nil, 3
end

--- systemctl show 的 Key=Value 属性集。
--- @param name string
--- @param scope string
--- @return string
local function _show_text(name, scope)
  local norm, path = _unit_find(name, scope)
  local active, _, info = _active_state(norm, scope)
  local is_baseline = info ~= nil and info.baseline == true
  local is_runtime = (not path) and info ~= nil and info.baseline ~= true
  local loaded = (path or is_baseline or is_runtime) and "loaded" or "not-found"
  local sub = _sub_state(norm, scope)
  local lines = {
    "Type=simple",
    "Restart=no",
    "TimeoutStartUSec=1min 30s",
    "TimeoutStopUSec=1min 30s",
    "RemainAfterExit=no",
    "GuessMainPID=yes",
    "MainPID=" .. tostring((info and info.pid) or 0),
    "ControlPID=0",
    "Result=success",
    "NRestarts=0",
    "MemoryCurrent=[not set]",
    "TasksCurrent=[not set]",
    "Id=" .. norm,
    "Names=" .. norm,
  }
  if path then
    local content = _read_view(path)
    local sections = content and _parse_ini(content) or {}
    local desc = _get(sections, "Unit", "Description")
    lines[#lines + 1] = "Description=" .. tostring(desc or norm)
    local exec = _get(sections, "Service", "ExecStart")
    if exec then lines[#lines + 1] = "ExecStart=" .. tostring(exec) end
    local wd = _get(sections, "Service", "WorkingDirectory")
    if wd then lines[#lines + 1] = "WorkingDirectory=" .. tostring(wd) end
  elseif is_runtime then
    lines[#lines + 1] = "Description=" .. tostring(info.command or norm)
    lines[#lines + 1] = "ExecStart=" .. tostring(info.command or "")
  else
    lines[#lines + 1] = "Description=" .. norm
  end
  lines[#lines + 1] = "LoadState=" .. loaded
  lines[#lines + 1] = "ActiveState=" .. ((path or is_baseline or is_runtime) and active or "inactive")
  lines[#lines + 1] = "SubState=" .. sub
  lines[#lines + 1] = "CanStart=" .. ((path or is_runtime) and "yes" or "no")
  lines[#lines + 1] = "CanStop=yes"
  lines[#lines + 1] = "CanReload=no"
  lines[#lines + 1] = "NeedDaemonReload=no"
  lines[#lines + 1] = "Transient=" .. (is_runtime and "yes" or "no")
  if not path and not is_baseline and not is_runtime then
    lines[#lines + 1] = string.format(
      'LoadError=org.freedesktop.systemd1.NoSuchUnit "Unit %s not found."', norm)
  end
  return table.concat(lines, "\n")
end

--- @param name string
--- @param scope string
--- @return table
local function _cat(name, scope)
  local norm, path = _unit_find(name, scope)
  if not path then
    -- 瞬态单元：合成真实 `systemctl cat` 的 `/run/systemd/transient/...` 视图。
    local rinfo = _runtime_info(norm, scope)
    if not rinfo then return _fail("No files found for " .. norm .. ".", 1) end
    return _ok(string.format(
      "# /run/systemd/transient/%s\n# This is a transient unit file, created programmatically via the systemd API. Do not edit.\n"
      .. "[Unit]\nDescription=%s\n\n[Service]\nExecStart=%s",
      norm, tostring(rinfo.command or norm), tostring(rinfo.command or "")))
  end
  local content = _read_view(path) or ""
  return _ok("# " .. path .. "\n" .. content:gsub("%s+$", ""))
end

--- list-units：默认隐藏 inactive（真实 systemd 行为，`--all` 才显示全部）；支持
--- `--failed`/`--state=`/`--type=` 过滤。ACTIVE/SUB 从门面服务运行态合成。
--- @param scope string
--- @param no_legend boolean
--- @param opts table|nil
--- @return table
local function _list_units(scope, no_legend, opts)
  local svc = _svc()
  local filters = _list_filters(opts)
  local seen, names = {}, {}
  for _, n in ipairs(_enum_units(scope)) do
    if not seen[n] then seen[n] = true; names[#names + 1] = n end
  end
  if scope ~= "user" then
    for n in pairs(BASELINE_ACTIVE) do
      if not seen[n] then seen[n] = true; names[#names + 1] = n end
    end
  end
  if svc then
    for _, info in ipairs(svc.list()) do
      local n = info.unit
      if n and not seen[n] then seen[n] = true; names[#names + 1] = n end
    end
  end
  table.sort(names)
  local lines, count = {}, 0
  if not no_legend then
    lines[#lines + 1] = string.format("  %-72s %-6s %-8s %-12s %s", "UNIT", "LOAD", "ACTIVE", "SUB", "DESCRIPTION")
  end
  for _, n in ipairs(names) do
    if _type_match(n, filters.types) then
      local active, _, _ = _active_state(n, scope)
      local sub = _sub_state(n, scope)
      local load = "loaded"
      local keep
      if filters.failed then
        keep = active == "failed"
      elseif next(filters.states) then
        keep = filters.states[active] or filters.states[sub] or filters.states[load]
      else
        -- 默认（无 --all）：仅显示非 inactive 的已加载单元。
        keep = filters.all or active ~= "inactive"
      end
      if keep then
        count = count + 1
        local base = _baseline(n, scope)
        local desc = (base and base.desc) or n
        local _, path = _unit_find(n, scope)
        if path then
          local content = _read_view(path)
          local sections = content and _parse_ini(content) or {}
          desc = _get(sections, "Unit", "Description") or desc
        end
        lines[#lines + 1] = string.format("  %-72s %-6s %-8s %-12s %s", n, load, active, sub, desc)
      end
    end
  end
  if not no_legend then
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("%d loaded units listed.", count)
    lines[#lines + 1] = "To show all installed unit files use 'systemctl list-unit-files'."
  end
  return _ok(table.concat(lines, "\n"))
end

--- list-unit-files：枚举全部已安装单元文件，支持 `--type=`；STATE 由已 Enabled 软链/Install 段推导。
--- @param scope string
--- @param no_legend boolean
--- @param opts table|nil
--- @return table
local function _list_unit_files(scope, no_legend, opts)
  local filters = _list_filters(opts)
  local names = _enum_units(scope)
  table.sort(names)
  local lines, count = {}, 0
  if not no_legend then
    lines[#lines + 1] = string.format("%-44s %-15s %s", "UNIT FILE", "STATE", "PRESET")
  end
  for _, n in ipairs(names) do
    if _type_match(n, filters.types) then
      count = count + 1
      local _, path = _unit_find(n, scope)
      local state = select(1, _enabled_state(n, scope, path))
      local preset = state == "enabled" and "enabled" or (state == "disabled" and "disabled" or "-")
      lines[#lines + 1] = string.format("%-44s %-15s %s", n, state, preset)
    end
  end
  if not no_legend then
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("%d unit files listed.", count)
  end
  return _ok(table.concat(lines, "\n"))
end

--- 无真实日志时合成的基础系统行（模板，实际时间戳逐条递增，避免所有行同一时刻）。
local BASELINE_LOGS = {
  "Started Daily apt download activities.",
  "Reached target Timer Units.",
  "Started Daily Cleanup of Temporary Directories.",
  "Reached target Basic System.",
  "Started User Manager for UID 0.",
}

--- journalctl 合成输出（用沙箱服务日志；无日志时合成若干系统行）。
--- 时间戳逐条递增（真实 journal 每条日志各有时间），`Logs begin/end` 覆盖首尾；
--- `-n <N>` 限制行数。
--- @param plan table
--- @param scope string
--- @return table
local function _journal(plan, scope)
  local svc = _svc()
  local host = _hostname()
  local entries = {}
  for _, name in ipairs(plan.units or {}) do
    local key = _unit_key({ name = _normalize_unit_name(name) }, scope)
    local text = svc and svc.logs(key, plan.tail)
    if text and text ~= "" then
      local norm = _normalize_unit_name(name)
      for line in text:gmatch("[^\n]+") do
        entries[#entries + 1] = string.format("%s %s[1]: %s", host, norm, _redact(line))
      end
    end
  end
  if #entries == 0 then
    local n = tonumber(plan.tail)
    if n == nil then n = 3 end
    if n < 0 then n = 0 end
    if n > #BASELINE_LOGS then n = #BASELINE_LOGS end
    for i = 1, n do
      entries[#entries + 1] = string.format("%s systemd[1]: %s", host, BASELINE_LOGS[i])
    end
  elseif plan.tail and plan.tail > 0 and #entries > plan.tail then
    local trimmed = {}
    for i = #entries - plan.tail + 1, #entries do trimmed[#trimmed + 1] = entries[i] end
    entries = trimmed
  end

  local now = os.time()
  local count = #entries
  local function ts(i) return now - (count - i) end
  local out = {}
  if count > 0 then
    out[#out + 1] = string.format("-- Logs begin at %s, end at %s. --", _stamp(ts(1)), _stamp(ts(count)))
  else
    out[#out + 1] = string.format("-- No entries --")
  end
  for i = 1, count do
    out[#out + 1] = string.format("%s %s", _stamp(ts(i)), entries[i])
  end
  return _ok(table.concat(out, "\n"))
end

--- 从闭包错误中提取缺失单元名。
--- @param cerr string|nil
--- @param fallback string
--- @return string
local function _missing_unit(cerr, fallback)
  local u = cerr and tostring(cerr):match("Unit%s+([%w%._@%-]+)%s+not found")
  return _normalize_unit_name(u or fallback)
end

--- 去除错误文本中的沙箱实现字样（门面错误对 AI 应与真实 systemd 一致、不暴露沙箱）。
--- @param reason string|nil
--- @return string
local function _public_reason(reason)
  local s = tostring(reason or "")
  s = s:gsub("沙箱门面", ""):gsub("沙箱环境", ""):gsub("沙箱内", ""):gsub("沙箱", "")
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- systemd-analyze 合成数据：固件/引导/内核/用户空间耗时（秒）。真实 systemd-analyze 依赖
-- system D-Bus 从 PID1 取启动分析；沙箱无 D-Bus，故由门面合成**确定性且自洽**的数据。
local ANALYZE = { firmware = 3.123, loader = 1.456, kernel = 2.789, userspace = 6.543 }
local ANALYZE_BLAME = {
  { 3.210, "NetworkManager-wait-online.service" },
  { 1.980, "systemd-udev-settle.service" },
  { 1.120, "systemd-journald.service" },
  { 0.840, "systemd-udevd.service" },
  { 0.310, "systemd-logind.service" },
}

--- @return number
local function _analyze_total()
  return ANALYZE.firmware + ANALYZE.loader + ANALYZE.kernel + ANALYZE.userspace
end

--- `systemd-analyze time` 输出（真实字段）。
--- @return string
local function _analyze_time()
  return string.format(
    "Startup finished in %.3fs (firmware) + %.3fs (loader) + %.3fs (kernel) + %.3fs (userspace) = %.3fs\n"
    .. "multi-user.target reached after %.3fs in userspace.",
    ANALYZE.firmware, ANALYZE.loader, ANALYZE.kernel, ANALYZE.userspace, _analyze_total(),
    ANALYZE.userspace - 0.122)
end

--- `systemd-analyze blame` 输出（按耗时降序；真实输出即此格式）。
--- @return string
local function _analyze_blame()
  local rows = vim.deepcopy(ANALYZE_BLAME)
  table.sort(rows, function(a, b) return a[1] > b[1] end)
  local out = {}
  for _, r in ipairs(rows) do
    out[#out + 1] = string.format("%7.3fs %s", r[1], r[2])
  end
  return table.concat(out, "\n")
end

--- `systemd-analyze critical-chain` 输出（合成链）。
--- @return string
local function _analyze_chain()
  local t = ANALYZE.userspace
  local function at(d) return string.format("%.3fs", math.max(0, t - d)) end
  return table.concat({
    string.format("multi-user.target @%s", at(0.000)),
    string.format("└─basic.target @%s", at(0.010)),
    string.format("  └─sockets.target @%s", at(0.020)),
    string.format("    └─systemd-journald.socket @%s", at(0.030)),
    string.format("      └─system.slice @%s", at(0.040)),
    string.format("        └─-.slice @%s", at(0.040)),
  }, "\n")
end

--- `systemd-analyze unit-paths` 输出。
--- @return string
local function _analyze_unit_paths()
  return table.concat(_unit_roots("system"), "\n")
end

--- systemd-analyze 分派。
--- @param plan table
--- @return Deferred
local function _dispatch_analyze(plan)
  local verb = plan.verb
  if verb == "version" or _has_opt(plan.opts, "--version") then
    return async.resolve(_ok(_host_version()))
  end
  if verb == "time" then return async.resolve(_ok(_analyze_time())) end
  if verb == "blame" then return async.resolve(_ok(_analyze_blame())) end
  if verb == "critical-chain" then return async.resolve(_ok(_analyze_chain())) end
  if verb == "unit-paths" then return async.resolve(_ok(_analyze_unit_paths())) end
  return async.resolve(_fail("Unknown command verb '" .. tostring(verb) .. "'.", 1))
end

--- @return table
local function _uname()
  local ok, u = pcall(vim.uv.os_uname)
  if ok and type(u) == "table" then return u end
  return {}
end

--- @return string
local function _os_pretty()
  local f = io.open("/etc/os-release", "r")
  if f then
    local data = f:read("*a") or ""
    f:close()
    local name = data:match('PRETTY_NAME="([^"]*)"') or data:match("PRETTY_NAME=([^\n]*)")
    if name and name ~= "" then return name end
  end
  return "Linux"
end

--- @return string
local function _timezone()
  local f = io.open("/etc/timezone", "r")
  if f then
    local tz = (f:read("*l") or ""):gsub("%s+$", "")
    f:close()
    if tz ~= "" then return tz end
  end
  return "Etc/UTC"
end

--- hostnamectl 状态输出（合成真实字段；不依赖 system D-Bus）。
--- @return string
local function _hostnamectl_status()
  local host = _hostname()
  local u = _uname()
  return table.concat({
    string.format("   Static hostname: %s", host),
    "         Icon name: computer-container",
    "           Chassis: container",
    string.format("        Machine ID: %s", vim.fn.sha256(host):sub(1, 32)),
    string.format("           Boot ID: %s", vim.fn.sha256(host .. ":boot"):sub(1, 32)),
    "    Virtualization: docker",
    string.format("  Operating System: %s", _os_pretty()),
    string.format("            Kernel: Linux %s", tostring(u.release or "")),
    string.format("      Architecture: %s", tostring(u.machine or "x86-64")),
  }, "\n")
end

--- timedatectl 状态输出。
--- @return string
local function _timedatectl_status()
  local now = os.time()
  return table.concat({
    string.format("               Local time: %s", os.date("%a %Y-%m-%d %H:%M:%S", now)),
    string.format("           Universal time: %s", os.date("!%a %Y-%m-%d %H:%M:%S UTC", now)),
    string.format("                 RTC time: %s", os.date("!%a %Y-%m-%d %H:%M:%S", now)),
    string.format("                Time zone: %s (UTC, +0000)", _timezone()),
    "System clock synchronized: yes",
    "              NTP service: active",
    "          RTC in local TZ: no",
  }, "\n")
end

--- @param name string
--- @return Deferred
local function _dispatch_hostnamectl(plan)
  if _has_opt(plan.opts, "--version") then return async.resolve(_ok(_host_version())) end
  local verb = plan.verb
  if verb == "status" then
    if _has_opt(plan.opts, "--static") or _has_opt(plan.opts, "--transient")
      or _has_opt(plan.opts, "--pretty") then
      return async.resolve(_ok(_hostname()))
    end
    return async.resolve(_ok(_hostnamectl_status()))
  end
  if verb == "set-hostname" then
    -- 宿主主机名属宿主状态：门面不修改宿主，返回真实风格拒绝（受限容器语义）。
    return async.resolve(_fail("Failed to set hostname: Access denied", 1))
  end
  return async.resolve(_fail("Unknown command verb '" .. tostring(verb) .. "'.", 1))
end

--- @param plan table
--- @return Deferred
local function _dispatch_timedatectl(plan)
  if _has_opt(plan.opts, "--version") then return async.resolve(_ok(_host_version())) end
  local verb = plan.verb
  if verb == "status" then return async.resolve(_ok(_timedatectl_status())) end
  if verb == "show" then
    return async.resolve(_ok(table.concat({
      "Timezone=" .. _timezone(),
      "LocalRTC=no",
      "CanNTP=yes",
      "NTP=yes",
      "NTPSynchronized=yes",
      "TimeUSec=" .. tostring(os.time() * 1000000),
    }, "\n")))
  end
  if verb == "set-time" or verb == "set-timezone" or verb == "set-ntp" or verb == "set-local-rtc" then
    return async.resolve(_fail(string.format("Failed to set %s: Access denied", verb:gsub("set%-", "")), 1))
  end
  return async.resolve(_fail("Unknown command verb '" .. tostring(verb) .. "'.", 1))
end

--- dmesg 合成内核环形缓冲行（不含宿主真实内核信息）。
local DMESG_LINES = {
  { 0.000000, "Linux version 6.1.0-30-amd64 (debian-kernel@lists.debian.org) (gcc-12) #1 SMP PREEMPT_DYNAMIC" },
  { 0.000000, "Command line: BOOT_IMAGE=/vmlinuz-6.1.0-30-amd64 root=/dev/vda1 ro quiet" },
  { 0.000000, "BIOS-provided physical RAM map:" },
  { 0.012345, "Memory: 3.8GiB available" },
  { 0.234567, "smpboot: CPU0: Intel(R) Xeon(R) Processor" },
  { 0.543210, "systemd[1]: systemd 257 running in system mode (+PAM +AUDIT +SELINUX +SECCOMP)" },
  { 0.654321, "systemd[1]: Detected container virtualization docker." },
  { 0.765432, "systemd[1]: Reached target Basic System." },
}

--- `dmesg` 合成输出；支持 `-T`/`--ctime`（人类可读时间戳）与 `-l`/`--level` 过滤。
--- @param plan table
--- @return Deferred
local function _dispatch_dmesg(plan)
  local human = _has_opt(plan.opts, "--ctime") or _has_opt(plan.opts, "-T") or _has_opt(plan.opts, "--human")
  local opts = plan.opts or {}
  local argv = {}
  for _, o in ipairs(opts) do argv[#argv + 1] = o end
  for _, a in ipairs(plan.args or {}) do argv[#argv + 1] = a end
  local level = nil
  for i, o in ipairs(argv) do
    if o == "-l" or o == "--level" then
      level = argv[i + 1]
    else
      local v = o:match("^%-%-level=(.+)$") or o:match("^%-l(%S+)$")
      if v then level = v end
    end
  end
  local strict = false
  if level then
    local lv = level:lower()
    strict = (lv:find("err") or lv:find("warn") or lv:find("crit")
      or lv:find("alert") or lv:find("emerg")) ~= nil
  end
  local total = DMESG_LINES[#DMESG_LINES][1]
  local now = os.time()
  local out = {}
  for _, ln in ipairs(DMESG_LINES) do
    local text = ln[2]
    if text:find("<host>") then text = text:gsub("<host>", _hostname()) end
    if strict then
      -- 粗略级别过滤：非 info 级别只保留含错误/警告特征的行。
      if not text:lower():find("error") and not text:lower():find("fail")
        and not text:lower():find("warn") and not text:lower():find("denied") then
        text = nil
      end
    end
    if text then
      local stamp
      if human then
        stamp = "[" .. os.date("%a %b %d %H:%M:%S %Y", now - math.floor((total - ln[1]) + 0.5)) .. "]"
      else
        stamp = string.format("[%12.6f]", ln[1])
      end
      out[#out + 1] = stamp .. " " .. text
    end
  end
  return async.resolve(_ok(table.concat(out, "\n")))
end

--- 分派一个计划（返回 Deferred resolve({stdout,stderr,code})）。
--- @param plan table
--- @return Deferred
local function _dispatch(plan)
  if plan.kind == "systemd-analyze" then return _dispatch_analyze(plan) end
  if plan.kind == "hostnamectl" then return _dispatch_hostnamectl(plan) end
  if plan.kind == "timedatectl" then return _dispatch_timedatectl(plan) end
  if plan.kind == "dmesg" then return _dispatch_dmesg(plan) end
  local verb = plan.verb
  local scope = plan.scope or "system"
  local units = plan.units or {}
  local opts = plan.opts or {}
  local quiet = _has_opt(opts, "--quiet") or _has_opt(opts, "-q")
  local no_legend = _has_opt(opts, "--no-legend") or _has_opt(opts, "--plain")

  if verb == "logs" then return async.resolve(_journal(plan, scope)) end
  if verb == "daemon-reload" then return async.resolve(_ok("")) end
  if verb == "reset-failed" then
    -- 清除失败状态：门面无持久失败单元（服务退出码即状态来源），幂等成功（真实语义）。
    return async.resolve(_ok(""))
  end
  if verb == "get-default" then
    return async.resolve(_ok(scope == "user" and "default.target" or "multi-user.target"))
  end
  if verb == "set-default" then
    if #units == 0 then return async.resolve(_fail("Failed to set default target: Invalid argument.", 1)) end
    return async.resolve(_ok(""))
  end
  if verb == "show-environment" then
    -- 真实输出 systemd 管理器环境变量；沙箱管理器无额外变量 → 空输出、退出 0。
    return async.resolve(_ok(""))
  end
  if verb == "list-jobs" then
    return async.resolve(_ok("No jobs running."))
  end
  if verb == "list-timers" then
    local lines = {}
    if not no_legend then
      lines[#lines + 1] = string.format("  %-24s %-12s %-24s %-12s %-32s %s",
        "NEXT", "LEFT", "LAST", "PASSED", "UNIT", "ACTIVATES")
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "0 timers listed."
    return async.resolve(_ok(table.concat(lines, "\n")))
  end
  if verb == "list-sockets" then
    local lines = {}
    if not no_legend then
      lines[#lines + 1] = string.format("  %-16s %-32s %s", "LISTEN", "UNIT", "ACTIVATES")
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "0 sockets listed."
    return async.resolve(_ok(table.concat(lines, "\n")))
  end

  if verb == "is-system-running" then
    -- 用门面自身状态（不查宿主），与沙箱内呈现的 systemd 自洽。
    local state = _facade_state()
    local code = (state == "running") and 0 or 1
    return async.resolve({ stdout = quiet and "" or state, stderr = "", code = code })
  end
  if verb == "is-failed" then
    -- 真实 `is-failed` 打印系统态，且在「failed」时退出 0，其余退出 1（degraded 不算 failed）。
    local state = _facade_state()
    local code = (state == "failed") and 0 or 1
    return async.resolve({ stdout = quiet and "" or state, stderr = "", code = code })
  end

  if verb == "status" and #units == 0 then
    local state = _facade_state()
    local failed = 0
    local svcs = _svc()
    if svcs then
      for _, info in ipairs(svcs.list()) do
        if info.status == "exited" and (tonumber(info.exit_code) or 0) ~= 0 then failed = failed + 1 end
      end
    end
    local text = table.concat({
      string.format("● %s", _hostname()),
      string.format("     State: %s", state),
      "      Jobs: 0 queued",
      string.format("    Failed: %d units", failed),
      string.format("     Since: %s", _now_stamp()),
      "    CGroup: /",
    }, "\n")
    return async.resolve({ stdout = text, stderr = "", code = state == "running" and 0 or 1 })
  end

  if verb == "list-units" then return async.resolve(_list_units(scope, no_legend, opts)) end
  if verb == "list-unit-files" then return async.resolve(_list_unit_files(scope, no_legend, opts)) end

  if verb == "is-active" then
    if #units == 0 then return async.resolve(_fail("Unit name missing.", 1)) end
    local outs, code = {}, 0
    for _, name in ipairs(units) do
      local norm, path = _unit_find(name, scope)
      local active, acode, info = _active_state(norm, scope)
      if not path and not info then
        outs[#outs + 1] = "inactive"; code = math.max(code, 4)
      else
        outs[#outs + 1] = active; code = math.max(code, acode)
      end
    end
    return async.resolve({ stdout = quiet and "" or table.concat(outs, "\n"), stderr = "", code = code })
  end

  if verb == "is-enabled" then
    if #units == 0 then return async.resolve(_fail("Unit name missing.", 1)) end
    local outs, code = {}, 0
    for _, name in ipairs(units) do
      local norm, path = _unit_find(name, scope)
      if not path and _runtime_info(norm, scope) then
        -- 瞬态单元：真实 systemd 报告 generated 且退出码 0。
        outs[#outs + 1] = "generated"
      else
        local state, scode = _enabled_state(norm, scope, path)
        outs[#outs + 1] = state; code = math.max(code, scode)
      end
    end
    return async.resolve({ stdout = quiet and "" or table.concat(outs, "\n"), stderr = "", code = code })
  end

  if verb == "cat" then
    if #units == 0 then return async.resolve(_fail("Unit name missing.", 1)) end
    local outs, errs, code = {}, {}, 0
    for _, name in ipairs(units) do
      local r = _cat(name, scope)
      if r.stdout ~= "" then outs[#outs + 1] = r.stdout end
      if r.stderr ~= "" then errs[#errs + 1] = r.stderr end
      code = math.max(code, r.code)
    end
    return async.resolve({ stdout = table.concat(outs, "\n"), stderr = table.concat(errs, "\n"), code = code })
  end

  if verb == "show" then
    if #units == 0 then return async.resolve(_fail("Unit name missing.", 1)) end
    local outs = {}
    for _, name in ipairs(units) do outs[#outs + 1] = _show_text(name, scope) end
    return async.resolve({ stdout = table.concat(outs, "\n"), stderr = "", code = 0 })
  end

  if verb == "status" then
    if #units == 0 then return async.resolve(_fail("Unit name missing.", 1)) end
    local outs, errs, code = {}, {}, 0
    for _, name in ipairs(units) do
      local block, err, bcode = _status_block(name, scope)
      if err then errs[#errs + 1] = err; code = math.max(code, bcode or 1)
      else outs[#outs + 1] = block; code = math.max(code, bcode or 0) end
    end
    return async.resolve({ stdout = table.concat(outs, "\n\n"), stderr = table.concat(errs, "\n"), code = code })
  end

  if verb == "run" then
    -- systemd-run：启动一个沙箱内临时单元（后台服务）。真实 systemd-run 立即返回
    -- `Running as unit: <name>`；`--wait` 时等待其结束并返回单元退出码；`--pipe`/`-P`/`--pty`
    -- 回传单元输出（无 tty）。
    local argv = plan.argv or {}
    if #argv == 0 then
      return async.resolve(_fail("Failed to start transient service: No command specified.", 1))
    end
    local svc = _svc()
    if not svc then return async.resolve(_fail("Failed to start transient service: Operation not permitted.", 1)) end
    local name = _normalize_unit_name(units[1] or _transient_name())
    if name:find("@") then
      return async.resolve(_fail("Failed to start transient service: Invalid unit name.", 1))
    end
    local key = _unit_key({ name = name }, scope)
    if svc.status(key) then
      return async.resolve(_fail(string.format(
        "Failed to start transient service: Unit %s already exists.", name), 1))
    end
    local started, serr = svc.start(key, _quote_argv(argv), {
      cwd = plan.workdir, unit = name, env = plan.env,
    })
    if not started then
      return async.resolve(_fail(string.format(
        "Failed to start transient service: %s", tostring(serr or "failed")), 1))
    end
    local msg = string.format("Running as unit: %s", name)
    if not plan.wait then return async.resolve(_ok(msg)) end
    local d = async.Deferred.new()
    local deadline = vim.uv.now() + 600000
    local function poll()
      local info = svc.status(key)
      if not info or info.status == "exited" then
        if plan.pipe then
          -- `--pipe`/`--pty`：真实回传命令输出与退出码（不含 "Running as unit"）。
          d:resolve({ stdout = tostring(svc.logs(key) or ""), stderr = "",
            code = tonumber(info and info.exit_code) or 0 })
        else
          d:resolve({ stdout = msg, stderr = "", code = tonumber(info and info.exit_code) or 0 })
        end
        return
      end
      if vim.uv.now() >= deadline then
        d:resolve({ stdout = plan.pipe and tostring(svc.logs(key) or "") or msg, stderr = "", code = 0 })
        return
      end
      vim.defer_fn(poll, 50)
    end
    poll()
    return d
  end

  if verb == "start" or verb == "stop" or verb == "restart" then
    if #units == 0 then return async.resolve(_fail("Unit name missing.", 1)) end
    -- 基线单元（门面呈现为 active 的核心 target/基础服务）没有真实进程：写操作按真实语义
    -- 幂等成功（start/restart）或置停（stop），避免对系统单元一律报 Operation not permitted。
    local all_baseline = true
    for _, n in ipairs(units) do
      if not _baseline(_normalize_unit_name(n), scope) then all_baseline = false; break end
    end
    if all_baseline then
      for _, n in ipairs(units) do
        local norm = _normalize_unit_name(n)
        if verb == "stop" then stopped_baseline[norm] = true
        else stopped_baseline[norm] = nil end
      end
      return async.resolve(_ok(""))
    end
    local max = tonumber(_cfg().max_deps) or 32
    local ordered, unitmap, cerr = M.resolve_closure(units, max, scope)
    if not ordered then
      local c = tostring(cerr or "")
      -- 仅真正「未找到」才报 not found；其余（单元文件设置不受支持/解析失败等）透传清洗后的
      -- 具体原因，不再一律谎报 Operation not permitted（该文案既误导 AI 又掩盖真实原因）。
      if c:find("not found", 1, true) then
        local miss = _missing_unit(cerr, units[1])
        return async.resolve(_fail(
          string.format("Failed to %s %s: Unit %s not found.", verb, miss, miss), 5))
      end
      local norm = _normalize_unit_name(units[1])
      local reason = _public_reason(cerr)
      if reason == "" then reason = "Unit " .. norm .. " is not loaded properly." end
      return async.resolve(_fail(string.format("Failed to %s %s: %s", verb, norm, reason), 1))
    end
    if verb == "start" then
      local d = async.Deferred.new()
      _start_ordered(ordered, unitmap, scope):then_(function(r)
        if r.err then d:resolve(_fail(r.err, 1)) else d:resolve(_ok("")) end
      end)
      return d
    end
    if verb == "stop" then
      local d = async.Deferred.new()
      local function step(idx)
        if idx < 1 then return d:resolve(_ok("")) end
        _stop_one(unitmap[ordered[idx]], scope):then_(function() step(idx - 1) end, function() step(idx - 1) end)
      end
      step(#ordered)
      return d
    end
    -- restart：先停后起
    local d = async.Deferred.new()
    local function stop_all(idx, done)
      if idx > #ordered then return done() end
      _stop_one(unitmap[ordered[idx]], scope):then_(function() stop_all(idx + 1, done) end,
        function() stop_all(idx + 1, done) end)
    end
    stop_all(1, function()
      _start_ordered(ordered, unitmap, scope):then_(function(r)
        if r.err then
          d:resolve(_fail(r.err:gsub("Failed to start", "Failed to restart"), 1))
        else
          d:resolve(_ok(""))
        end
      end)
    end)
    return d
  end

  if verb == "enable" or verb == "disable" or verb == "reenable" then
    local unit_name = units[1]
    if not unit_name then return async.resolve(_fail("Failed to enable unit: Invalid argument.", 1)) end
    local norm, path = _unit_find(unit_name, scope)
    if not path then
      return async.resolve(_fail(
        string.format("Failed to %s unit: Unit file %s does not exist.", verb, norm), 1))
    end
    local targets = _install_targets(path)
    if #targets == 0 then
      return async.resolve(_fail(
        "The unit files have no installation config (WantedBy=, RequiredBy=, Also=, Alias= settings "
        .. "in the [Install] section, and DefaultInstance= for template units). This means they are "
        .. "not meant to be enabled using systemctl.", 1))
    end
    if verb == "disable" then return async.resolve(_ok("")) end
    local admin_root = scope == "user" and _user_admin_root() or "/etc/systemd/system"
    local lines = {}
    for _, t in ipairs(targets) do
      lines[#lines + 1] = string.format("Created symlink %s/%s.wants/%s → %s.", admin_root, t, norm, path)
    end
    return async.resolve(_ok(table.concat(lines, "\n")))
  end

  if REJECT_VERBS[verb] then
    return async.resolve(_fail(M.reject_text(verb, units[1]), 1))
  end

  return async.resolve(_fail("Unknown command verb '" .. tostring(verb) .. "'.", 1))
end

--- 执行一个 systemctl/journalctl 调用（计划或 argv），返回 {stdout, stderr, code}。
--- 所有解析/实现都在 Lua：门面直接调用；沙箱内 shim 经 IPC 转到这里。
--- @param input table 计划（含 verb）或 argv 列表
--- @return Deferred
function M.exec(input)
  if _cfg().enabled == false then return async.reject("systemd disabled") end
  --- 规范化：非空输出以换行结尾（真实 systemctl 的 stdout/stderr 均以换行结束）。
  --- @param res table|nil
  --- @return table
  local function norm(res)
    res = res or {}
    local out = tostring(res.stdout or "")
    local err = tostring(res.stderr or "")
    if out ~= "" and out:sub(-1) ~= "\n" then out = out .. "\n" end
    if err ~= "" and err:sub(-1) ~= "\n" then err = err .. "\n" end
    return { stdout = out, stderr = err, code = tonumber(res.code) or 0 }
  end

  local plan
  -- 已解析的计划：有 `kind` 或 `verb`（dmesg 等无动词工具只有 kind）。
  if type(input) == "table" and (input.verb ~= nil or input.kind ~= nil) then
    plan = input
  elseif type(input) == "table" then
    local bin0 = tostring(input[1] or ""):match("([^/]+)$")
    local versionable = {
      systemctl = true, journalctl = true, ["systemd-run"] = true,
      ["systemd-analyze"] = true, hostnamectl = true, timedatectl = true,
    }
    if versionable[bin0] then
      for _, a in ipairs(input) do
        if a == "--version" or a == "-V" then
          return async.resolve(norm({ stdout = _host_version(), stderr = "", code = 0 }))
        end
      end
    end
    plan = M._plan_tokens(input, table.concat(input, " "))
    if not plan then
      local bin = tostring(input[1] or ""):match("([^/]+)$")
      if bin == "journalctl" then
        return async.resolve(norm(_journal({ units = {}, tail = nil }, "system")))
      end
      if bin == "systemctl" then
        return async.resolve(norm(_list_units("system", false)))
      end
      return async.resolve(norm(_fail("Unknown command verb '" .. tostring(input[1]) .. "'.", 1)))
    end
  else
    return async.reject("invalid systemd invocation")
  end
  local d = _dispatch(plan)
  local out = async.Deferred.new()
  d:then_(function(res) out:resolve(norm(res)) end, function(e) out:reject(e) end)
  return out
end

--- 处理一个门面计划（门禁路径）。返回 Deferred resolve({stdout, stderr, code})。
--- @param plan table M.parse_command 的结果
--- @return Deferred
function M.handle(plan)
  if type(plan) ~= "table" then return async.reject("无效的 systemd 计划") end
  return M.exec(plan)
end

--- 门面可用性/配置摘要（诊断用）。
--- @return table
function M.describe()
  local cfg = _cfg()
  return {
    enabled = cfg.enabled ~= false,
    mode = cfg.mode or "facade",
    unit_roots = _unit_roots("system"),
    user_unit_roots = _unit_roots("user"),
    supported_types = { "simple", "exec", "oneshot" },
  }
end

--- 重置（测试用）。
function M.reset()
  stopped_baseline = {}
end

return M
