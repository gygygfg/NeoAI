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
-- 候选密钥允许的字符集：字母/数字/下划线/连字符/加号（不含 `/`、`.`、`=`，
-- 避免把路径/域名/赋值前缀并入候选；base64 末尾的 `=` 会留在 token 之外，往返无损）
local RUN_PAT = "[%w_%-%+]+"

local DEFAULTS = {
  enabled = true,
  min_length = 20,
  max_length = 200,
  min_entropy = 3.5,
  min_distinct = 8,
  -- 排除纯小写十六进制串（git SHA / sha256 / md5 等哈希与校验和），避免把常见
  -- 标识符当密钥导致 token 化后不可用；代价是纯小写 hex 形式的密钥不被覆盖。
  exclude_pure_hex = true,
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
--- @return string
local function _token_for(secret)
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
  state.traces[#state.traces + 1] = { event = "detected", token = token, at = os.time() }
  pcall(function()
    require("NeoAI.kernel.event_bus").emit(require("NeoAI.kernel.events").SANDBOX_SECRET_DETECTED, {
      token = token,
    })
  end)
  return token
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

--- 检测文本中的高熵密钥候选
--- @param text string
--- @return table 数组 { value, start, stop, entropy }
function M.detect(text)
  local out = {}
  if type(text) ~= "string" or text == "" then return out end
  local cfg = _cfg()
  local pos = 1
  while true do
    local s, e = text:find(RUN_PAT, pos)
    if not s then break end
    local run = text:sub(s, e)
    if _is_candidate(run, cfg) then
      out[#out + 1] = { value = run, start = s, stop = e, entropy = _entropy(run) }
    end
    pos = e + 1
  end
  return out
end

--- 把文本中的密钥替换为随机 token（进沙箱加密）
--- @param text string
--- @return string tokenized
--- @return table tokens 本次用到的 token 数组
function M.tokenize(text)
  if not M.enabled() or type(text) ~= "string" or text == "" then return text, {} end
  local cfg = _cfg()
  local used = {}
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
--- @return table var -> tokenized_value
function M.sanitized_env()
  local overrides = {}
  if not M.enabled() then return overrides end
  local env = vim.fn.environ() or {}
  for k, v in pairs(env) do
    if type(v) == "string" and #v > 0 then
      if _secret_name(k) then
        overrides[k] = _token_for(v)
      else
        local nv = M.tokenize(v)
        if nv ~= v then overrides[k] = nv end
      end
    end
  end
  return overrides
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
