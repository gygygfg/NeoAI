--- systemd 单元解析助手
--- @module 'NeoAI.sandbox.systemd.systemd_parse'
--- 从 systemd.lua 抽出的无状态纯函数（不引用模块状态；内部相互调用保持原样）。

--- 归一化 shell 重定向语法（仅用于判断复合命令，不影响真实执行）。
--- @param s string
--- @return string
local function _normalize_redirects(s)
  return (tostring(s):gsub(">&", ">"):gsub("&>", ">"):gsub("|&", "|"))
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

--- 解析 systemd 容量（`512M`/`1G`/`infinity` 等），返回字节数或 math.huge。
--- @param s string|nil
--- @return number|nil
local function _parse_size(s)
  if s == nil then return nil end
  s = tostring(s):gsub("%s+", "")
  if s == "" then return nil end
  if s:lower() == "infinity" then return math.huge end
  local n, u = s:match("^([%d%.]+)([%a]*)$")
  if not n then return nil end
  local ul = u:lower()
  local mul
  if ul == "" or ul == "b" then mul = 1
  elseif ul == "k" or ul == "kb" or ul == "kib" then mul = 1024
  elseif ul == "m" or ul == "mb" or ul == "mib" then mul = 1024 ^ 2
  elseif ul == "g" or ul == "gb" or ul == "gib" then mul = 1024 ^ 3
  elseif ul == "t" or ul == "tb" or ul == "tib" then mul = 1024 ^ 4
  end
  if not mul then return nil end
  return math.floor(tonumber(n) * mul)
end

--- 解析 CPUQuota 百分比（`50%` → 50；也接受裸数字）。返回百分数。
--- @param s string|nil
--- @return number|nil
local function _parse_quota(s)
  if s == nil then return nil end
  local str = tostring(s):gsub("%s+", "")
  local p = str:match("^(%d+)%%$")
  if p then return tonumber(p) end
  return tonumber(str)
end

--- 秒数 → systemd 风格时长字符串（`100ms`/`1.5s`/`1min 30s`/`2h`）。
--- @param sec number|nil
--- @return string
local function _format_sec(sec)
  sec = tonumber(sec) or 0
  if sec <= 0 then return "0" end
  if sec < 1 then return string.format("%dms", math.floor(sec * 1000 + 0.5)) end
  if sec < 60 then
    if sec == math.floor(sec) then return string.format("%ds", math.floor(sec)) end
    return string.format("%.3gs", sec)
  end
  local m = math.floor(sec / 60)
  local s = sec - m * 60
  if m < 60 then
    if s > 0 then return string.format("%dmin %ds", m, math.floor(s + 0.5)) end
    return string.format("%dmin", m)
  end
  local h = math.floor(m / 60)
  m = m - h * 60
  if m > 0 then return string.format("%dh %dmin", h, m) end
  return string.format("%dh", h)
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

return {
  normalize_redirects = _normalize_redirects,
  parse_ini = _parse_ini,
  get = _get,
  parse_size = _parse_size,
  parse_quota = _parse_quota,
  format_sec = _format_sec,
  expand_env = _expand_env,
  expand_specifiers = _expand_specifiers,
  split_args = _split_args,
  quote_argv = _quote_argv,
}
