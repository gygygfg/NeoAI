--- 沙箱密钥防护：熵检测 + 随机加密映射（进沙箱加密 / 出沙箱 commit 时解密）
--- @module NeoAI.sandbox.secret
--- 常开（配置 `tools.sandbox.secrets` 可调阈值/关闭）。职责：
---   1. 基于香农熵 + 字符集启发式检测高熵密钥候选；
---   2. 为每个真实密钥生成随机 token（进程内映射表，不落盘），
---      「进沙箱」时把密钥替换为 token（工具结果、暂存视图、环境变量），
---      「出沙箱」仅在 commit 发布到真实工作区时把 token 还原为密钥；
---   3. 对 token 的操作留痕（证据 + 待审警告）；
---   4. 工具参数中出现**原始密钥**（映射表中已知的真实值）时上报硬拦截，由执行器终止 Agent。
---
--- 边界：熵检测是启发式的，存在误报（长哈希/随机串会被当作密钥，但会原样往返，不破坏内容）；
--- 映射表仅在内存，热重载后 token 无法还原 → commit 明确拒绝（fail-closed），不写入 token。

local M = {}

-- ========== 私有常量 ==========

local TOKEN_PREFIX = "NEOKEY_"
local TOKEN_PAT = "NEOKEY_%x+"
-- 环境变量信号：沙箱进程内该变量列出被 token 化的变量名（逗号分隔），
-- 使工具/Agent 能区分「真实密钥」与「沙箱 token」，避免把 token 当真实凭据误判（如 401）。
local ENV_MARKER = "NEOAI_TOKENIZED_ENV"
-- 候选密钥允许的字符集：字母/数字/下划线/连字符/加号（不含 `/`、`.`、`=`，
-- 避免把路径/域名/赋值前缀并入候选；base64 末尾的 `=` 会留在 token 之外，往返无损）
local RUN_PAT = "[%w_%-%+]+"

-- 具名敏感信息规则（Lua pattern）：命中即视为敏感信息，无视熵阈值一律 token 化/脱敏。
-- 覆盖「高熵熵检测」盲区（结构化凭据、带前缀的 token、私钥块等），实现敏感信息全部脱敏。
-- 每条 `{ name, pattern }`；pattern 命中整段（含捕获）作为敏感值处理。
local DEFAULT_RULES = {
  { name = "private_key", pattern = "%-%-%-%-%-BEGIN[%w ]*PRIVATE KEY%-%-%-%-%-[%s%S]-%-%-%-%-%-END[%w ]*PRIVATE KEY%-%-%-%-%-" },
  { name = "aws_access_key", pattern = "AKIA[0-9A-Z]+" },
  { name = "github_token", pattern = "gh[pousr]_[A-Za-z0-9]+" },
  { name = "slack_token", pattern = "xox[baprs]%-[A-Za-z0-9%-]+" },
  { name = "google_api_key", pattern = "AIza[0-9A-Za-z_%-]+" },
  { name = "stripe_key", pattern = "s?[rp]k_(live|test)_[A-Za-z0-9]+" },
  { name = "openai_key", pattern = "sk%-[A-Za-z0-9_%-]+" },
  { name = "jwt", pattern = "eyJ[%w_%-]+%.eyJ[%w_%-]+%.[%w_%-]+" },
  { name = "bearer", pattern = "[Bb]earer%s+[%w%._%-]+" },
  { name = "basic_auth", pattern = "[Bb]asic%s+[A-Za-z0-9+/=]+" },
}

local DEFAULTS = {
  enabled = true,
  min_length = 20,
  max_length = 200,
  min_entropy = 3.5,
  min_distinct = 8,
  -- 排除纯小写十六进制串（git SHA / sha256 / md5 等哈希与校验和），避免把常见
  -- 标识符当密钥导致 token 化后不可用；代价是纯小写 hex 形式的密钥不被覆盖。
  exclude_pure_hex = true,
  -- 是否对沙箱进程环境变量做 token 化。关闭后环境变量原样注入（调试/本地可信运行时），
  -- 工具结果与暂存内容仍按密钥防护处理。
  tokenize_env = true,
  -- 具名敏感信息规则（见 DEFAULT_RULES）；配置后**替换**内置规则。
  rules = DEFAULT_RULES,
  -- 额外追加的具名规则（在内置/配置规则之外追加）
  extra_rules = {},
  -- 额外排除的正则（Lua pattern），命中则不视为密钥
  allowlist = {},
}

-- ========== 私有状态 ==========

local state = {
  by_secret = {}, -- secret -> token
  by_token = {}, -- token -> secret
  seq = 0,
  salt = nil,
  traces = {}, -- 留痕：{ event, tool, path, tokens, at }
}

-- ========== 私有函数 ==========

local function _cfg()
  local c = require("NeoAI.kernel.config_store").get("tools.sandbox.secrets")
  local out = {}
  for k, v in pairs(DEFAULTS) do out[k] = v end
  if type(c) == "table" then
    for k, v in pairs(c) do out[k] = v end
  end
  -- 具名规则：默认/配置规则 + extra_rules 追加
  local rules = {}
  for _, r in ipairs(out.rules or {}) do
    if type(r) == "table" and type(r.pattern) == "string" then rules[#rules + 1] = r end
  end
  for _, r in ipairs(out.extra_rules or {}) do
    if type(r) == "table" and type(r.pattern) == "string" then rules[#rules + 1] = r end
  end
  out.rules = rules
  return out
end

--- 香农熵（bits/char）
--- @param s string
--- @return number
local function _entropy(s)
  if s == "" then return 0 end
  local freq = {}
  local n = #s
  for i = 1, n do
    local ch = s:sub(i, i)
    freq[ch] = (freq[ch] or 0) + 1
  end
  local e = 0
  for _, c in pairs(freq) do
    local p = c / n
    e = e - p * (math.log(p) / math.log(2))
  end
  return e
end

--- 是否高熵密钥候选
--- @param run string
--- @param cfg table
--- @return boolean
local function _is_candidate(run, cfg)
  if run:sub(1, #TOKEN_PREFIX) == TOKEN_PREFIX then return false end
  if #run < cfg.min_length or #run > cfg.max_length then return false end
  -- 至少含字母与数字（降低对长英文标识符的误报）
  if not (run:find("%a") and run:find("%d")) then return false end
  -- 纯小写十六进制（哈希/校验和）排除
  if cfg.exclude_pure_hex ~= false and run:match("^[0-9a-f]+$") then return false end
  local distinct = {}
  local nd = 0
  for i = 1, #run do
    local ch = run:sub(i, i)
    if not distinct[ch] then distinct[ch] = true; nd = nd + 1 end
  end
  if nd < cfg.min_distinct then return false end
  for _, pat in ipairs(cfg.allowlist or {}) do
    if type(pat) == "string" and run:match(pat) then return false end
  end
  return _entropy(run) >= cfg.min_entropy
end

--- 生成随机 token（每进程随机盐，跨密钥唯一）
--- @param secret string
--- @param rule_name string|nil 命中的具名规则（用于留痕）
--- @return string
local function _token_for(secret, rule_name)
  local existing = state.by_secret[secret]
  if existing then return existing end
  state.seq = state.seq + 1
  if not state.salt then
    local seed = table.concat({ tostring(os.time()), tostring(vim.fn.getpid()), tostring(math.random(1, 2 ^ 30)) })
    state.salt = tostring(vim.fn.sha256(seed))
  end
  local hex = tostring(vim.fn.sha256(state.salt .. "|" .. state.seq .. "|" .. secret))
  local token = TOKEN_PREFIX .. hex:sub(1, 32)
  state.by_secret[secret] = token
  state.by_token[token] = secret
  state.traces[#state.traces + 1] = { event = "detected", token = token, rule = rule_name, at = os.time() }
  pcall(function()
    require("NeoAI.kernel.event_bus").emit(require("NeoAI.kernel.events").SANDBOX_SECRET_DETECTED, {
      token = token, rule = rule_name,
    })
  end)
  if rule_name then
    pcall(function()
      require("NeoAI.sandbox.audit").observe({
        kind = "secret", level = 3, reasons = { "SENSITIVE_RULE:" .. tostring(rule_name) },
      })
    end)
  end
  return token
end

--- 应用具名敏感信息规则：命中整段替换为 token（进沙箱加密，可无损还原）。
--- @param text string
--- @param cfg table
--- @param used table token 累加器
--- @return string
local function _apply_rules(text, cfg, used)
  for _, rule in ipairs(cfg.rules or {}) do
    if type(rule.pattern) == "string" then
      local ok, out = pcall(function()
        return (text:gsub(rule.pattern, function(m)
          local token = _token_for(m, rule.name)
          used[#used + 1] = token
          return token
        end))
      end)
      if ok and type(out) == "string" then text = out end
    end
  end
  return text
end

--- 对文本应用具名敏感信息规则做**破坏性脱敏**（用于日志/证据，不可还原）。
--- @param text string
--- @return string redacted
--- @return table hits 命中的规则名数组
function M.redact(text)
  if type(text) ~= "string" or text == "" then return text, {} end
  local cfg = _cfg()
  if cfg.enabled == false then return text, {} end
  local hits = {}
  for _, rule in ipairs(cfg.rules or {}) do
    if type(rule.pattern) == "string" then
      local ok, out, n = pcall(function()
        local count = 0
        local res = text:gsub(rule.pattern, function()
          count = count + 1
          return "[REDACTED:" .. tostring(rule.name) .. "]"
        end)
        return res, count
      end)
      if ok and type(out) == "string" then
        text = out
        if (n or 0) > 0 then
          hits[#hits + 1] = rule.name
          pcall(function()
            require("NeoAI.kernel.event_bus").emit(require("NeoAI.kernel.events").SANDBOX_SENSITIVE_REDACTED, {
              rule = rule.name, count = n,
            })
          end)
        end
      end
    end
  end
  return text, hits
end

--- 记录一条留痕（证据）
--- @param payload table
local function _record(payload)
  pcall(function()
    require("NeoAI.sandbox.evidence").add("secret", payload, {
      tool = payload.tool, source = "observed", coverage = "full",
    })
  end)
end

-- 环境变量名中出现的敏感词段（按 `_` 切分后整段匹配）。命中则**无视熵阈值**强制
-- token 化，覆盖纯 hex（如 GLM_API_KEY=dfe946…）等熵检测盲区。
-- 刻意不含过宽的 "AUTH"（会误伤 SSH_AUTH_SOCK 等路径类变量）。
local SECRET_NAME_SEGMENTS = {
  "KEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "CREDENTIAL", "CREDENTIALS",
}

--- 环境变量名是否暗示其值敏感
--- @param name string
--- @return boolean
local function _secret_name(name)
  if type(name) ~= "string" or name == "" then return false end
  local n = name:upper()
  if n:find("APIKEY", 1, true) then return true end
  for seg in n:gmatch("[A-Z0-9]+") do
    for _, w in ipairs(SECRET_NAME_SEGMENTS) do
      if seg == w then return true end
    end
  end
  return false
end

-- 具名赋值中敏感值的字符集：仅密钥常见字符，避免把空白/引号/控制符/分隔符并入候选而跨条目吞并
-- （如 /proc/self/environ 以 NUL 分隔、值中含 `.`/`+`/`/`/`=`/`:`）。
local NAME_VALUE_CHARS = "[%w%._%+%=/:-]+"

--- 按变量名强制 token 化赋值中的敏感值。覆盖熵检测盲区：
---   * 纯小写十六进制（被 `exclude_pure_hex` 排除）；
---   * 含 `.` 等分隔符的多段密钥（被 `RUN_PAT` 拆成不满足候选条件的片段）。
--- 仅当赋值**名字**暗示敏感（`_secret_name`）时才替换值，避免误伤普通配置/代码。
--- 支持 `NAME=value` / `NAME="value"` / `"NAME": "value"` 三种写法。
--- @param text string
--- @param used table token 累加器
--- @return string
local function _apply_secret_names(text, used)
  local function make(name, value)
    if type(name) ~= "string" or type(value) ~= "string" then return nil end
    if value == "" or not _secret_name(name) then return nil end
    if value:sub(1, #TOKEN_PREFIX) == TOKEN_PREFIX then return nil end
    local token = _token_for(value, "env_name:" .. name)
    used[#used + 1] = token
    return token
  end
  text = text:gsub("([%a_][%w_]*)(%s*=%s*)(" .. NAME_VALUE_CHARS .. ")", function(name, sep, value)
    local token = make(name, value)
    if not token then return nil end
    return name .. sep .. token
  end)
  for _, q in ipairs({ '"', "'" }) do
    text = text:gsub("([%a_][%w_]*)(%s*=%s*)" .. q .. "(.-)" .. q, function(name, sep, value)
      local token = make(name, value)
      if not token then return nil end
      return name .. sep .. q .. token .. q
    end)
    text = text:gsub(q .. "([%a_][%w_]*)" .. q .. "(%s*:%s*)" .. q .. "(.-)" .. q, function(name, sep, value)
      local token = make(name, value)
      if not token then return nil end
      return q .. name .. q .. sep .. q .. token .. q
    end)
  end
  return text
end

-- ========== 公开 API ==========

--- 是否启用密钥防护
--- @return boolean
function M.enabled()
  return _cfg().enabled ~= false
end

--- 计算字符串香农熵（导出供测试）
--- @param s string
--- @return number
function M.entropy(s)
  return _entropy(s or "")
end

--- 检测文本中的密钥候选（高熵 + 具名敏感信息规则）
--- @param text string
--- @return table 数组 { value, start, stop, entropy, rule? }
function M.detect(text)
  local out = {}
  if type(text) ~= "string" or text == "" then return out end
  local cfg = _cfg()
  local seen = {}
  local function add(s, e, rule)
    if s == nil then return end
    local key = s .. ":" .. e
    if seen[key] then return end
    seen[key] = true
    local v = text:sub(s, e)
    out[#out + 1] = { value = v, start = s, stop = e, entropy = _entropy(v), rule = rule }
  end
  local pos = 1
  while true do
    local s, e = text:find(RUN_PAT, pos)
    if not s then break end
    local run = text:sub(s, e)
    if _is_candidate(run, cfg) then add(s, e) end
    pos = e + 1
  end
  -- 具名规则：补充结构化敏感信息（私钥块/带前缀 token 等熵检测盲区）；与熵检测重叠时去重。
  for _, rule in ipairs(cfg.rules or {}) do
    if type(rule.pattern) == "string" then
      local s, e = text:find(rule.pattern)
      while s do
        add(s, e, rule.name)
        s, e = text:find(rule.pattern, e + 1)
      end
    end
  end
  return out
end

--- 把文本中的密钥/敏感信息替换为随机 token（进沙箱加密）
--- @param text string
--- @return string tokenized
--- @return table tokens 本次用到的 token 数组
function M.tokenize(text)
  if not M.enabled() or type(text) ~= "string" or text == "" then return text, {} end
  local cfg = _cfg()
  local used = {}
  -- 先应用具名敏感信息规则（结构化凭据优先，整段替换）
  text = _apply_rules(text, cfg, used)
  -- 再按变量名强制 token 化赋值中的敏感值（覆盖纯 hex / 含点号多段密钥等熵检测盲区）
  text = _apply_secret_names(text, used)
  -- 再对残余高熵串做熵检测替换
  local out = text:gsub(RUN_PAT, function(run)
    if _is_candidate(run, cfg) then
      local token = _token_for(run)
      used[#used + 1] = token
      return token
    end
    return run
  end)
  return out, used
end

--- 把 token 还原为真实密钥（出沙箱 commit 解密）
--- @param text string
--- @return string restored
--- @return number unresolved 未解析的 token 数（映射缺失，调用方应 fail-closed）
function M.detokenize(text)
  if type(text) ~= "string" or text == "" then return text, 0 end
  local unresolved = 0
  local out = text:gsub(TOKEN_PAT, function(tok)
    local secret = state.by_token[tok]
    if secret then return secret end
    unresolved = unresolved + 1
    return tok
  end)
  return out, unresolved
end

--- 文本是否含 token
--- @param text string
--- @return boolean
function M.has_token(text)
  return type(text) == "string" and text:find(TOKEN_PAT) ~= nil
end

-- AI 读取到 KEY（结果被 token 化）时追加的说明：token 仅对 AI 不可见，真实密钥在
-- 网络发送 / 写入文件时自动还原，不改变程序语义。避免 AI 误以为拿到的是真实密钥或
-- 误判密钥无效。
local READ_HINT = "提示：结果中的 NEOKEY_* 为沙箱密钥 token——仅对 AI 不可见；"
  .. "网络发送、写入文件时会自动替换回原有真实密钥，不影响程序执行。"

--- AI 读取到 KEY 时的提示文本
--- @return string
function M.read_hint()
  return READ_HINT
end

--- 值（字符串或表内字符串字段）是否含 token
--- @param value any
--- @return boolean
function M.contains_token(value)
  local t = type(value)
  if t == "string" then return M.has_token(value) end
  if t == "table" then
    for k, v in pairs(value) do
      if M.contains_token(v) then return true end
      if type(k) == "string" and M.has_token(k) then return true end
    end
  end
  return false
end

--- 文本是否含映射表中已知的**原始密钥**
--- @param text string
--- @return string|nil secret
function M.find_real_secret(text)
  if type(text) ~= "string" or text == "" then return nil end
  for secret in pairs(state.by_secret) do
    if #secret >= 8 and text:find(secret, 1, true) then return secret end
  end
  return nil
end

--- 深度扫描参数中的字符串：返回是否命中原始密钥与用到的 token
--- @param value any
--- @param acc table|nil { secret?, tokens = {} }
--- @return table { secret?, tokens = table }
function M.scan(value, acc)
  acc = acc or { tokens = {} }
  local t = type(value)
  if t == "string" then
    local secret = M.find_real_secret(value)
    if secret and not acc.secret then acc.secret = secret end
    for tok in value:gmatch(TOKEN_PAT) do acc.tokens[tok] = true end
  elseif t == "table" then
    for k, v in pairs(value) do
      M.scan(v, acc)
      if type(k) == "string" then M.scan(k, acc) end
    end
  end
  return acc
end

--- 对工具参数做 token 化（深度遍历字符串；由执行器按 fs_write 规格调用）
--- @param args table
--- @return table tokens 用到的 token 数组
function M.tokenize_args(args)
  local used = {}
  local function walk(t)
    for k, v in pairs(t) do
      if type(v) == "string" then
        local nv, toks = M.tokenize(v)
        if nv ~= v then t[k] = nv end
        for _, tok in ipairs(toks) do used[#used + 1] = tok end
      elseif type(v) == "table" then
        walk(v)
      end
    end
  end
  if type(args) == "table" then walk(args) end
  return used
end

--- 生成沙箱进程环境覆盖：把高熵环境变量值替换为 token（命令拿到 token，非真实密钥）。
--- 变量名命中敏感词段（KEY/TOKEN/SECRET/PASSWORD/CREDENTIAL）时**无视熵阈值**强制 token 化，
--- 避免纯 hex 密钥（如 GLM_API_KEY）逃过熵检测而原样注入沙箱。
--- 只要发生 token 化，就注入 `NEOAI_TOKENIZED_ENV=<变量名列表>` 信号，使沙箱内
--- 能明确区分「沙箱 token」与真实密钥（避免把 token 当真实凭据而误判 401）。
--- 配置 `tools.sandbox.secrets.tokenize_env=false` 可整体关闭环境变量 token 化。
--- @return table var -> tokenized_value（另含 NEOAI_TOKENIZED_ENV 信号）
function M.sanitized_env()
  local overrides = {}
  if not M.enabled() then return overrides end
  if _cfg().tokenize_env == false then return overrides end
  local env = vim.fn.environ() or {}
  local names = {}
  for k, v in pairs(env) do
    if type(v) == "string" and #v > 0 then
      if _secret_name(k) then
        overrides[k] = _token_for(v)
        names[#names + 1] = k
      else
        local nv = M.tokenize(v)
        if nv ~= v then
          overrides[k] = nv
          names[#names + 1] = k
        end
      end
    end
  end
  if #names > 0 then
    table.sort(names)
    overrides[ENV_MARKER] = table.concat(names, ",")
  end
  return overrides
end

--- 沙箱内用于标识「哪些环境变量已被 token 化」的变量名
--- @return string
function M.env_marker_name()
  return ENV_MARKER
end

--- 对工具结果做 token 化（字符串或表内字符串字段）
--- @param value any
--- @return any
function M.tokenize_result(value)
  if not M.enabled() then return value end
  local t = type(value)
  if t == "string" then
    return (M.tokenize(value))
  elseif t == "table" then
    local out = vim.deepcopy(value)
    local function walk(v)
      if type(v) == "table" then
        for k, x in pairs(v) do
          if type(x) == "string" then v[k] = M.tokenize(x)
          elseif type(x) == "table" then walk(x) end
        end
      end
    end
    walk(out)
    return out
  end
  return value
end

--- 扫描候选文件内容中的 token，返回警告信息（供待审队列展示）
--- @param files table 候选文件数组
--- @return table|nil { count, tokens }
function M.warn_for_files(files)
  local tokens = {}
  local count = 0
  for _, f in ipairs(files or {}) do
    if type(f.content) == "string" then
      for tok in f.content:gmatch(TOKEN_PAT) do
        count = count + 1
        tokens[tok] = true
      end
    end
  end
  if count == 0 then return nil end
  local list = {}
  for tok in pairs(tokens) do list[#list + 1] = tok end
  table.sort(list)
  return { count = count, tokens = list }
end

--- 记录一次 token 操作留痕（并写证据）
--- @param event string
--- @param meta table { tool?, path?, tokens? }
function M.trace(event, meta)
  meta = meta or {}
  state.traces[#state.traces + 1] = {
    event = event, tool = meta.tool, path = meta.path,
    tokens = meta.tokens, at = os.time(),
  }
  _record({
    event = event, tool = meta.tool, path = meta.path,
    tokens = meta.tokens and vim.tbl_keys(meta.tokens) or {},
  })
end

--- 当前留痕快照（测试/审计用）
--- @return table
function M.traces()
  return vim.deepcopy(state.traces)
end

--- 重置（测试用）
function M.reset()
  state.by_secret = {}
  state.by_token = {}
  state.seq = 0
  state.salt = nil
  state.traces = {}
end

return M
