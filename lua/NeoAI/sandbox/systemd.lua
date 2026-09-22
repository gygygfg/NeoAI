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

-- ========== 常量 ==========

local KNOWN_SUFFIXES = {
  ".service", ".socket", ".timer", ".target", ".mount", ".path", ".slice",
  ".scope", ".device", ".swap", ".automount",
}

-- 单元类型支持：simple/exec 长驻，oneshot 跑完即返回；其余明确不支持。
local SUPPORTED_TYPES = { simple = true, exec = true, oneshot = true }
local UNSUPPORTED_TYPES = {
  notify = true, ["notify-reload"] = true, forking = true, dbus = true, idle = true,
  ["oneshot-notify"] = true,
}

-- 门面处理的动词。
local SUPPORTED_VERBS = {
  start = true, stop = true, restart = true, status = true, ["is-active"] = true,
  ["is-enabled"] = true, show = true, cat = true, ["daemon-reload"] = true,
  ["list-units"] = true, ["list-unit-files"] = true,
  -- 环境探测类：合成「已启动/无失败」输出，避免暴露「非 systemd 环境」。
  ["is-system-running"] = true, ["is-failed"] = true,
}

-- 明确拒绝（不落到宿主机，也不回退 hostop）的动词。
local REJECT_VERBS = {
  enable = true, disable = true, reenable = true, mask = true, unmask = true,
  reload = true, ["reload-or-restart"] = true, ["try-reload-or-restart"] = true,
  kill = true, ["reset-failed"] = true, edit = true, link = true, revert = true,
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

--- @return table
local function _unit_roots()
  local roots = _cfg().unit_roots
  if type(roots) == "table" and #roots > 0 then return roots end
  return {
    "/etc/systemd/system", "/run/systemd/system",
    "/usr/lib/systemd/system", "/lib/systemd/system",
  }
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
--- @return table|nil plan { kind, verb, units, opts, route, raw }
function M.parse_command(command)
  if type(command) ~= "string" or command == "" then return nil end
  local toks, compound = _tokenize(_normalize_redirects(command))
  if compound or #toks == 0 then return nil end

  local i = 1
  while i <= #toks and (toks[i]:match("^[%w_]+=") or SKIP_PREFIX[_bin(toks[i])]) do i = i + 1 end
  if i > #toks then return nil end
  local bin = _bin(toks[i])
  if bin ~= "systemctl" and bin ~= "journalctl" then return nil end
  local kind = bin
  i = i + 1

  if kind == "journalctl" then
    return M._parse_journalctl(toks, i, command)
  end

  local opts, verb, units = {}, nil, {}
  local host_target = false
  while i <= #toks do
    local t = toks[i]
    if t:sub(1, 1) == "-" and t ~= "-" then
      local name = t:match("^([^=]+)")
      if HOST_TARGET_OPTS[name] then host_target = true end
      opts[#opts + 1] = t
      if OPT_VALUE[name] and not t:find("=", 1, true) then i = i + 1 end
    elseif not verb then
      verb = t
    else
      units[#units + 1] = t
    end
    i = i + 1
  end
  if not verb then return nil end

  -- `systemctl --user`：交给沙箱内**真实**的嵌套 systemd 用户实例原生执行（门面不拦截）。
  for _, o in ipairs(opts) do
    if o == "--user" then
      return { kind = kind, verb = verb, units = units, opts = opts, route = "native", raw = command }
    end
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
  return { kind = kind, verb = verb, units = units, opts = opts, route = route, raw = command }
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
  if #units == 0 then return nil end
  return { kind = "journalctl", verb = "logs", units = units, tail = tail, route = "facade", raw = raw }
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

--- 读取文件内容（优先沙箱暂存副本）。
--- @param path string
--- @return string|nil content
--- @return string|nil staged_path
local function _read_view(path)
  local staged = nil
  local ok, candidate = pcall(require, "NeoAI.sandbox.candidate")
  if ok and candidate and type(candidate.read_path) == "function" then
    local sp = candidate.read_path(path)
    if sp and fs.exists(sp) then staged = sp end
  end
  local read = staged or path
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

--- 展开 `$VAR` / `${VAR}`（`$$` → 字面 `$`）。未定义变量展开为空（systemd 语义）。
--- @param value string
--- @param env table
--- @return string
local function _expand_env(value, env)
  local out = value:gsub("%$%$", "\1")
  out = out:gsub("%${([%w_]+)}", function(k) return env[k] or "" end)
  out = out:gsub("%$([%w_]+)", function(k) return env[k] or "" end)
  return (out:gsub("\1", "$"))
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
  if UNSUPPORTED_TYPES[typ] then
    return nil, "沙箱环境不支持 Type=" .. typ .. "（仅支持 simple/exec/oneshot）"
  end
  if not SUPPORTED_TYPES[typ] then
    return nil, "沙箱环境不支持 Type=" .. typ
  end

  local env, eerr = _parse_environment(sections)
  if eerr then return nil, eerr end

  local exec_vals = svc.ExecStart or {}
  if #exec_vals == 0 then
    return nil, "单元缺少 ExecStart（沙箱门面不支持无 ExecStart 的单元）"
  end
  if #exec_vals > 1 and typ ~= "oneshot" then
    return nil, "沙箱门面仅支持单个 ExecStart"
  end
  local exec_raw = exec_vals[1]
  if exec_raw:find("%%%a") then
    return nil, "沙箱门面不支持 systemd 说明符（%" .. exec_raw:match("%%%a") .. "）"
  end
  exec_raw = exec_raw:match("^[%-@:+!]*(.*)$") or exec_raw
  exec_raw = _expand_env(exec_raw, env)
  local argv, aerr = _split_args(exec_raw)
  if aerr then return nil, "ExecStart 解析失败：" .. aerr end
  if #argv == 0 then return nil, "ExecStart 为空" end

  local workdir = nil
  local wd = _get(sections, "Service", "WorkingDirectory")
  if wd and wd ~= "" and wd ~= "-" then
    wd = wd:gsub("^%-", "")
    workdir = _expand_env(wd, env)
  end

  if _get(sections, "Service", "User") or _get(sections, "Service", "Group") then
    return nil, "沙箱门面不支持 User=/Group=（沙箱载荷统一以沙箱身份运行）"
  end
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
    exec = exec_raw,
    env = env,
    workdir = workdir,
    requires = requires,
    wants = wants,
    after = after,
    before = before,
  }
end

--- 定位并加载一个单元（优先沙箱暂存副本）。
--- @param name string
--- @return table|nil unit
--- @return string|nil err
--- @return string|nil path
local function _load_unit(name)
  local norm = _normalize_unit_name(name)
  if norm:find("@") then
    return nil, "沙箱门面不支持模板/实例化单元：" .. name
  end
  local suffix = norm:match("(%.[%w]+)$")
  if suffix and suffix ~= ".service" and suffix ~= ".target" then
    return nil, "沙箱环境不支持 " .. suffix .. " 单元（仅支持 .service/.target）"
  end
  for _, root in ipairs(_unit_roots()) do
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
  return nil, "Unit " .. norm .. " not found（沙箱内未找到该 unit 文件）"
end

--- 依赖闭包（Requires/Wants 递归 + After/Before 拓扑排序）。
--- @param names table 请求的单元名
--- @param max number
--- @return table|nil ordered 单元名列表
--- @return table|nil units map
--- @return string|nil err
function M.resolve_closure(names, max)
  local units, ordered, visiting = {}, {}, {}
  local function load(name)
    if units[name] then return units[name] end
    local unit, err = _load_unit(name)
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

--- 合成 systemctl 风格状态文本。
--- @param unit table
--- @param info table|nil
--- @return string
local function _status_text(unit, info)
  local state, sub = "inactive", "dead"
  if info then
    if info.status == "running" then state, sub = "active", "running"
    elseif info.status == "exited" then state, sub = "inactive", "dead"
    elseif info.status == "starting" then state, sub = "active", "start" end
  end
  local lines = {
    string.format("%s - %s", unit.name, tostring(unit.description or unit.name)),
    string.format("     Loaded: loaded (%s; sandbox)", tostring(unit.path or "unit")),
    string.format("     Active: %s (%s)", state, sub),
  }
  if info and info.pid then lines[#lines + 1] = string.format("   Main PID: %s", tostring(info.pid)) end
  return table.concat(lines, "\n")
end

--- @param unit table
--- @return string
local function _unit_key(unit)
  return "unit:" .. unit.name
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
--- @return table|nil svc
--- @return string|nil err
local function _start_one(unit)
  if unit.target then return { name = unit.name, target = true }, nil end
  local svc = _svc()
  if not svc then return nil, "长驻服务模块不可用" end
  local key = _unit_key(unit)
  local existing = svc.status(key)
  if existing and existing.status == "running" then
    return existing, nil
  end
  local command = table.concat(unit.argv, " ")
  local started, err = svc.start(key, command, {
    workdir = unit.workdir,
    cwd = unit.workdir,
    env = unit.env,
    unit = unit.name,
  })
  if not started then return nil, err or ("启动失败：" .. unit.name) end
  return started, nil
end

--- 停止一个单元（异步）。
--- @param unit table
--- @return Deferred
local function _stop_one(unit)
  local svc = _svc()
  if not svc then return async.reject("长驻服务模块不可用") end
  local d = async.Deferred.new()
  svc.stop(_unit_key(unit), function(err)
    if err then return d:reject(err) end
    d:resolve(true)
  end)
  return d
end

--- @param verb string
--- @return string
function M.reject_text(verb)
  if verb == "enable" or verb == "disable" or verb == "reenable" then
    return "沙箱环境不支持 `systemctl " .. verb .. "`：不修改宿主机、也不写入真实单元目录。"
      .. "沙箱按单元名直接管理服务，无需 enable/disable。"
  end
  if verb == "reload" or verb == "reload-or-restart" or verb == "try-reload-or-restart" then
    return "沙箱环境不支持 `systemctl " .. verb .. "`（reload 语义不支持；可用 restart）。"
  end
  if verb == "kill" then
    return "沙箱环境不支持 `systemctl kill`（可用 stop）。"
  end
  if verb == "poweroff" or verb == "reboot" or verb == "halt" or verb == "kexec"
    or verb == "suspend" or verb == "hibernate" or verb == "hybrid-sleep"
    or verb == "suspend-then-hibernate" or verb == "rescue" or verb == "emergency" then
    return "沙箱禁止 `systemctl " .. tostring(verb) .. "`（宿主电源/内核状态操作，不执行）。"
  end
  return "沙箱环境不支持 `systemctl " .. tostring(verb) .. "`。"
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
  local unit_name = plan.units[1]
  if not unit_name then
    return async.resolve("请指定要 " .. tostring(plan.verb) .. " 的单元名。")
  end
  unit_name = _normalize_unit_name(unit_name)
  local unit, uerr, upath = _load_unit(unit_name)
  if not unit then
    return async.resolve(M.error_text(uerr or ("Unit " .. unit_name .. " not found")))
  end
  local unit_path = unit.path or upath

  control.transition(attempt, "STAGING")
  candidate.begin(attempt, root)
  local staged = 0
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
      return async.resolve("单元 " .. unit_name .. " 无 [Install] WantedBy/RequiredBy，无法 enable。")
    end
    local admin_root = "/etc/systemd/system"
    for _, t in ipairs(targets) do
      local link = admin_root .. "/" .. t .. ".wants/" .. unit_name
      if candidate.stage_link(attempt.attempt_id, link, unit_path) then staged = staged + 1 end
    end
  else
    for _, r in ipairs(_unit_roots()) do
      local handle = vim.uv.fs_scandir(r)
      if handle then
        while true do
          local name, t = vim.uv.fs_scandir_next(handle)
          if not name then break end
          if t == "directory" and name:sub(-6) == ".wants" then
            local link = r .. "/" .. name .. "/" .. unit_name
            local lst = vim.uv.fs_lstat(link)
            if lst and lst.type == "link" then
              if candidate.stage_delete(attempt.attempt_id, link) then staged = staged + 1 end
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
    return async.resolve(plan.verb == "enable"
      and ("（无变更：软链已存在或单元无需 enable）：" .. unit_name)
      or ("（无变更：未找到可删除的软链）：" .. unit_name))
  end
  cand.command_id = attempt.command_id
  wrapper.settle_exec_candidate(attempt, cand, ctx or {}, spec, { code = 0 }, { command = plan.raw })
  return async.resolve(string.format(
    "已暂存 systemctl %s %s 的软链变更（%d 个），等待用户确认后应用。",
    tostring(plan.verb), unit_name, staged))
end

--- 处理一个门面计划。
--- @param plan table M.parse_command 的结果
--- @return Deferred resolve(text) / reject(err)
function M.handle(plan)
  if type(plan) ~= "table" then return async.reject("无效的 systemd 计划") end
  if _cfg().enabled == false then return async.reject("沙箱 systemd 门面已禁用") end
  local verb = plan.verb

  if verb == "logs" then
    local svc = _svc()
    if not svc then return async.reject("长驻服务模块不可用") end
    local texts = {}
    for _, name in ipairs(plan.units) do
      local key = "unit:" .. _normalize_unit_name(name)
      local text, err = svc.logs(key, plan.tail)
      if text then texts[#texts + 1] = text end
      if err and not text then texts[#texts + 1] = err end
    end
    return async.resolve(_redact(table.concat(texts, "\n")))
  end

  if verb == "daemon-reload" then
    return async.resolve(_redact("沙箱门面：已重新加载单元（每次调用均重新读取暂存单元文件）。"))
  end

  -- 环境探测：真实 systemd 会返回系统运行态。沙箱门面恒为已启动（running），避免暴露差异。
  if verb == "is-system-running" then
    return async.resolve("running")
  end
  -- `is-failed` 无失败单元时真实 systemd 打印 active（退出码 1）。
  if verb == "is-failed" then
    return async.resolve("active")
  end
  -- 无单元名的 `systemctl status`：真实 systemd 打印系统总览；合成一段等价概览。
  if verb == "status" and #plan.units == 0 then
    return async.resolve(_redact(table.concat({
      "● sandbox",
      "    State: running",
      "     Jobs: 0 queued",
      "   Failed: 0 units",
      "    Since: 沙箱会话启动",
      "   CGroup: /",
    }, "\n")))
  end

  if verb == "list-units" or verb == "list-unit-files" then
    local svc = _svc()
    local seen, lines = {}, {}
    for _, root in ipairs(_unit_roots()) do
      if fs.is_dir(root) then
        for _, entry in ipairs(fs.list_dir(root) or {}) do
          local name = type(entry) == "table" and entry.name or tostring(entry)
          if name and name:match("%.service$") and not seen[name] then
            seen[name] = true
            local info = svc and svc.status("unit:" .. name) or nil
            local state = info and info.status or "inactive"
            lines[#lines + 1] = string.format("%-40s %s", name, state)
          end
        end
      end
    end
    if #lines == 0 then return async.resolve("（沙箱内未发现单元文件）") end
    table.sort(lines)
    return async.resolve(_redact(table.concat(lines, "\n")))
  end

  if #plan.units == 0 then
    return async.reject("缺少单元名")
  end

  if verb == "cat" then
    local parts = {}
    for _, name in ipairs(plan.units) do
      local norm = _normalize_unit_name(name)
      local content = nil
      for _, root in ipairs(_unit_roots()) do
        local c = _read_view(root .. "/" .. norm)
        if c then content = c; break end
      end
      if not content then return async.reject("Unit " .. norm .. " not found") end
      parts[#parts + 1] = "# " .. norm .. "\n" .. content
    end
    return async.resolve(_redact(table.concat(parts, "\n")))
  end

  -- 依赖闭包（start/restart/status/is-active/show/stop）。
  local max = tonumber(_cfg().max_deps) or 32
  local ordered, units, cerr = M.resolve_closure(plan.units, max)
  if not ordered then return async.reject(cerr or "解析依赖失败") end

  if verb == "start" or verb == "restart" then
    if verb == "restart" then
      local d = async.Deferred.new()
      local function stop_all(idx, done)
        if idx > #ordered then return done() end
        local u = units[ordered[idx]]
        _stop_one(u):then_(function()
          stop_all(idx + 1, done)
        end, function() stop_all(idx + 1, done) end)
      end
      stop_all(1, function()
        local ok, err, msgs = true, nil, {}
        for _, name in ipairs(ordered) do
          local svc, serr = _start_one(units[name])
          if not svc then ok = false; err = serr; break end
          msgs[#msgs + 1] = name
        end
        if not ok then return d:reject(err) end
        d:resolve(_redact("已启动（沙箱内）：" .. table.concat(msgs, ", ")))
      end)
      return d
    end
    local msgs = {}
    for _, name in ipairs(ordered) do
      local svc, serr = _start_one(units[name])
      if not svc then return async.reject(serr) end
      msgs[#msgs + 1] = name
    end
    return async.resolve(_redact("已启动（沙箱内）：" .. table.concat(msgs, ", ")))
  end

  if verb == "stop" then
    local d = async.Deferred.new()
    local function step(idx)
      if idx < 1 then return d:resolve(_redact("已停止（沙箱内）：" .. table.concat(ordered, ", "))) end
      _stop_one(units[ordered[idx]]):then_(function() step(idx - 1) end, function() step(idx - 1) end)
    end
    step(#ordered)
    return d
  end

  if verb == "is-active" then
    local svc = _svc()
    local lines = {}
    for _, name in ipairs(ordered) do
      local info = svc and svc.status(_unit_key(units[name])) or nil
      local active = info and info.status == "running" and "active" or "inactive"
      lines[#lines + 1] = active
    end
    return async.resolve(table.concat(lines, "\n"))
  end

  if verb == "is-enabled" then
    local lines = {}
    for _ = 1, #ordered do lines[#lines + 1] = "disabled" end
    return async.resolve(table.concat(lines, "\n"))
  end

  if verb == "status" or verb == "show" then
    local svc = _svc()
    local parts = {}
    for _, name in ipairs(ordered) do
      local u = units[name]
      local info = svc and svc.status(_unit_key(u)) or nil
      parts[#parts + 1] = _status_text(u, info)
    end
    return async.resolve(_redact(table.concat(parts, "\n\n")))
  end

  return async.reject("沙箱门面不支持：" .. tostring(verb))
end

--- 门面可用性/配置摘要（诊断用）。
--- @return table
function M.describe()
  local cfg = _cfg()
  return {
    enabled = cfg.enabled ~= false,
    mode = cfg.mode or "facade",
    unit_roots = _unit_roots(),
    supported_types = { "simple", "exec", "oneshot" },
  }
end

--- 重置（测试用）。
function M.reset() end

return M
