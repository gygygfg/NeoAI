--- 沙箱密钥防护：熵检测 + 随机加密映射（进沙箱加密 / 出沙箱 commit 时解密）
--- @module NeoAI.sandbox.secret
--- 常开（配置 `tools.sandbox.secrets` 可调阈值/关闭）。职责：
---   1. 基于香农熵 + 字符集启发式检测高熵密钥候选；
---   2. 为每个真实密钥生成随机 token（进程内映射表，不落盘），
---      「进沙箱」时把密钥替换为 token（工具结果、暂存视图、环境变量），
---      「出沙箱」仅在 commit 发布到真实工作区时把 token 还原为密钥；
---   3. 对 token 或**敏感环境变量名**的操作留痕（证据 + 待审警告），只提级不终止；
---   4. **原始密钥**（映射表中已知的真实值）出现在工具参数或 AI 可见上下文时上报硬拦截，
---      由执行器 / 请求前守卫终止 Agent；token（KEY 环境变量操作）只提级审批，不终止。
---
--- 边界：熵检测是启发式的，默认按上下文收窄（`entropy_requires_context`）——裸熵串须呈密钥
--- 形态（含 `-`/`_` 且非 snake_case 代码标识符）或处于敏感变量名赋值上下文，纯字母数字/base64
--- 元数据（SRI integrity、内容哈希、构建产物摘要等）与回溯函数名不再 token 化；映射表仅在内存，
--- 热重载后 token 无法还原 → commit 明确拒绝（fail-closed），不写入 token。

local M = {}

-- ========== 私有常量 ==========

local TOKEN_PREFIX = "NEOKEY_"
local TOKEN_PAT = "NEOKEY_%x+"
-- 环境变量信号：列出「在 AI 可见输出中被 token 化」的变量名（逗号分隔）。
-- 沙箱进程环境本身经 `runtime.sandbox_env` 还原为真实密钥（token→真实仅限沙箱内部进程），
-- 但命令输出回传模型前会重新 token 化，故该信号帮助 Agent 判断哪些值在输出中是 token。
local ENV_MARKER = "NEOAI_TOKENIZED_ENV"
-- 候选密钥允许的字符集：字母/数字/下划线/连字符/加号（不含 `/`、`.`、`=`，
-- 避免把路径/域名/赋值前缀并入候选；base64 末尾的 `=` 会留在 token 之外，往返无损）
local RUN_PAT = "[%w_%-%+]+"

-- 具名敏感信息规则（Lua pattern）：命中即视为敏感信息，无视熵阈值一律 token 化/脱敏。
-- 覆盖「高熵熵检测」盲区（结构化凭据、带前缀的 token、私钥块等），实现敏感信息全部脱敏。
-- 每条 `{ name, pattern }`；pattern 命中整段（含捕获）作为敏感值处理。
-- prefix：匹配必然包含的字面量子串，用于 gsub 前的 plain find 快速短路——
-- 大文件（暂存视图）通常不含任何凭据前缀，可省去每条规则一次全文扫描。
local DEFAULT_RULES = {
  { name = "private_key", prefix = "-----BEGIN", pattern = "%-%-%-%-%-BEGIN[%w ]*PRIVATE KEY%-%-%-%-%-[%s%S]-%-%-%-%-%-END[%w ]*PRIVATE KEY%-%-%-%-%-" },
  { name = "aws_access_key", prefix = "AKIA", pattern = "AKIA[0-9A-Z]+" },
  { name = "github_token", prefix = "gh", pattern = "gh[pousr]_[A-Za-z0-9]+" },
  { name = "slack_token", prefix = "xox", pattern = "xox[baprs]%-[A-Za-z0-9%-]+" },
  { name = "google_api_key", prefix = "AIza", pattern = "AIza[0-9A-Za-z_%-]+" },
  { name = "stripe_key", prefix = "k_", pattern = "s?[rp]k_(live|test)_[A-Za-z0-9]+" },
  { name = "openai_key", prefix = "sk-", pattern = "sk%-[A-Za-z0-9_%-]+" },
  { name = "jwt", prefix = "eyJ", pattern = "eyJ[%w_%-]+%.eyJ[%w_%-]+%.[%w_%-]+" },
  -- Bearer/Basic 后接普通英文单词（注释/文档，如 "Bearer token"）不应视为凭据：
  -- 要求凭证部分足够长且像 token（含数字或 base64/连接符）。
  { name = "bearer", prefix = "earer", validate_kind = "bearer", pattern = "[Bb]earer%s+[%w%._%-]+", validate = function(m)
    local v = m:match("^[Bb]earer%s+(.+)$")
    return v ~= nil and #v >= 16 and (v:match("%d") ~= nil or v:find("[%+/=._%-]") ~= nil)
  end },
  { name = "basic_auth", prefix = "asic", validate_kind = "basic", pattern = "[Bb]asic%s+[A-Za-z0-9+/=]+", validate = function(m)
    local v = m:match("^[Bb]asic%s+(.+)$")
    return v ~= nil and #v >= 16 and (v:match("%d") ~= nil or v:find("[%+/=]") ~= nil)
  end },
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
  -- 缩小认定范围：裸熵串须呈密钥形态（含 - / _ 分隔符）且不是代码标识符（snake_case 符号，
  -- 如 `create_urllib3_context`），或处于敏感变量名赋值上下文（KEY=/TOKEN:/PASSWORD= 等），
  -- 才视为密钥；纯字母数字/base64 串（SRI integrity、内容哈希、构建产物摘要等元数据）不再
  -- token 化，避免误伤 package-lock.json、`python -m build` 及工具输出中的回溯函数名。
  -- 设为 false 退回旧的「任意高熵串即密钥」行为。
  entropy_requires_context = true,
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

-- ========== 扫描核心（主线程与工作线程共用） ==========
-- 该核心是纯 Lua（不引用 vim / 模块状态），以源码字符串形式提供：主线程 `load` 后直接调用；
-- 工作线程（utils.work，独立 Lua state）同样 `load` 该源码，从而把「规则匹配 + 变量名 +
-- 熵检测」的全文扫描移出主线程。token 生成/映射/事件由调用方通过 `token_for` 回调注入：
--   主线程 -> `_token_for`（写映射、发事件）
--   工作线程 -> 本地 map 生成 token（纯 Lua sha256），主线程事后合并

local SCAN_SRC = [==[
local TOKEN_PREFIX = "NEOKEY_"
local RUN_PAT = "[%w_%-%+]+"
local NAME_VALUE_CHARS = "[%w%._%+%=/:-]+"
local SECRET_NAME_SEGMENTS = {
  "KEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "CREDENTIAL", "CREDENTIALS",
}

local function entropy(s)
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

--- 代码标识符/包名形态：以 - / _ 分段且每段都是「字母 + 可选尾随数字」或纯数字
--- （如 `create_urllib3_context`、`DEFAULT_CIPHERS_LIST`、`openjdk-21-jdk-headless`、
--- `libssl-dev`、`python3.11-minimal`）。这类串是源码符号 / 软件包名 / 版本串，不是凭据；
--- 裸熵检测须排除，避免把回溯函数名与 `dpkg -l` 输出的包名误 token 化。
local function looks_like_identifier(run)
  local segs = 0
  for seg in run:gmatch("[^%-_]+") do
    if not (seg:match("^%a+%d*$") or seg:match("^%d+$")) then return false end
    segs = segs + 1
  end
  return segs >= 2
end

local function is_candidate(run, cfg, context)
  if run:sub(1, #TOKEN_PREFIX) == TOKEN_PREFIX then return false end
  if #run < cfg.min_length or #run > cfg.max_length then return false end
  if not (run:find("%a") and run:find("%d")) then return false end
  if cfg.exclude_pure_hex ~= false and run:match("^[0-9a-f]+$") then return false end
  -- 内容摘要/完整性校验（sha512-/sha256-/md5-/blake2-/blake3-<base64|hex>）不是凭据：
  -- 其 base64/hex 主体属元数据，token 化会破坏 package-lock.json 等。即便含 `-` 也排除。
  if run:match("^sha%d+%-") or run:match("^md5%-") or run:match("^blake[0-9a-z]*%-") then
    return false
  end
  -- 缩小认定范围：裸熵串须呈「密钥形态」（含 - / _ 分隔符），或处于敏感变量名赋值
  -- 上下文（context，如 KEY=/TOKEN:/PASSWORD=）。纯字母数字/base64 串（SRI integrity、
  -- 内容哈希、构建产物摘要等元数据）不视为密钥，避免误伤 lockfile / 构建工具。
  if cfg.entropy_requires_context ~= false and not context then
    if not run:find("[%-_]") then return false end
    -- 裸熵串还须不是代码标识符（snake_case 符号），否则会把函数名/常量名当密钥。
    if looks_like_identifier(run) then return false end
  end
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
  return entropy(run) >= cfg.min_entropy
end

local function secret_name(name)
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

--- 前缀是否以「敏感变量名 + 赋值分隔符」结尾，用于裸熵串的上下文认定。
--- 支持 `NAME=` / `NAME:` / `"NAME": "` 等结尾形态（值与名之间允许引号/空白）。
--- @param prefix string
--- @return boolean
local function secret_name_prefix(prefix)
  if type(prefix) ~= "string" or prefix == "" then return false end
  local name = prefix:match("([%a_][%w_]*)['\"]?%s*[=:]%s*['\"]?$")
  return name ~= nil and secret_name(name)
end

--- 值是否呈文件系统路径 / URL 形态。路径不是凭据：`*_KEY = /path`、`key_separator = "/"`
--- 这类赋值登记为「原始密钥」后，任何含该路径片段的命令都会被硬拦截（误报）。
--- @param value any
--- @return boolean
local function looks_like_path(value)
  if type(value) ~= "string" or value == "" then return false end
  if value:sub(1, 1) == "/" or value:sub(1, 2) == "~/" or value:sub(1, 2) == "./"
    or value:sub(1, 3) == "../" or value:match("^%a:[/\\]") then
    return true
  end
  if value:match("^%a[%w+.-]*://") then return true end
  -- 相对/多段路径（含 `/` 且无 Base64 特征）：如 `bin/python`、`apps/python/.venv`。
  -- Base64 凭据通常含 `+`/`=` 或大写，据此与路径区分。
  if value:find("/", 1, true) and not value:find("+", 1, true)
    and not value:find("=", 1, true) and not value:find("%u") then
    return true
  end
  return false
end

--- 赋值值是否像凭据（供 `NAME = value` / `"NAME": "value"` 的按名脱敏）。
--- 必须排除普通单词 / 路径 / 单字符，否则源码里的 `'password': 'bar'`、
--- `key_separator = "."`、`CONFIGFILE_KEY = 'pyproject.toml'` 会被误登记为原始密钥，
--- 污染映射表并让后续 `find_real_secret` 子串匹配误拦截命令。
--- 认定：长度 >= 4，含数字；或长度 >= 8 且含大写 / Base64 特殊字符。
--- @param value any
--- @return boolean
local function looks_like_assigned_secret(value)
  if type(value) ~= "string" or #value < 4 then return false end
  if looks_like_path(value) then return false end
  if value:find("%d") then return true end
  if #value >= 8 and value:find("%u") then return true end
  if #value >= 8 and value:find("[%+/=:]") then return true end
  return false
end

--- 规则校验：主线程可用 validate 函数；工作线程无函数，用 validate_kind 复刻同义逻辑。
local function validate(rule, m)
  if type(rule.validate) == "function" then return rule.validate(m) end
  local k = rule.validate_kind
  if k == "bearer" then
    local v = m:match("^[Bb]earer%s+(.+)$")
    return v ~= nil and #v >= 16 and (v:match("%d") ~= nil or v:find("[%+/=._%-]") ~= nil)
  elseif k == "basic" then
    local v = m:match("^[Bb]asic%s+(.+)$")
    return v ~= nil and #v >= 16 and (v:match("%d") ~= nil or v:find("[%+/=]") ~= nil)
  end
  return true
end

local function apply_rules(text, cfg, token_for)
  for _, rule in ipairs(cfg.rules or {}) do
    local present = true
    if type(rule.prefix) == "string" and rule.prefix ~= "" then
      present = text:find(rule.prefix, 1, true) ~= nil
    end
    if type(rule.pattern) == "string" and present then
      local ok, out = pcall(function()
        return (text:gsub(rule.pattern, function(m)
          if not validate(rule, m) then return m end
          return token_for(m, rule.name)
        end))
      end)
      if ok and type(out) == "string" then text = out end
    end
  end
  return text
end

local function apply_secret_names(text, token_for)
  if not (text:find("=", 1, true) or text:find(":", 1, true)) then return text end
  -- 廉价预检：敏感名片段须**紧跟 = 或 :**（赋值形态）才可能命中；否则跳过 5 次全文 gsub。
  -- 大量普通源码/数据文件（如 venv、node_modules）只是恰好含 "key"/"token" 子串，
  -- 逐文件多次全文 gsub 是主要耗时（实测 36 MB 约 9s）。
  local hint = false
  for _, w in ipairs(SECRET_NAME_SEGMENTS) do
    if text:find(w .. "[%a_]*[\"']?%s*[=:]") or text:find(w:lower() .. "[%a_]*[\"']?%s*[=:]") then
      hint = true
      break
    end
  end
  if not hint and not (text:find("APIKEY[%a_]*[\"']?%s*[=:]") or text:find("apikey[%a_]*[\"']?%s*[=:]")) then
    return text
  end
  local function make(name, value)
    if type(name) ~= "string" or type(value) ~= "string" then return nil end
    if value == "" or not secret_name(name) then return nil end
    if value:sub(1, #TOKEN_PREFIX) == TOKEN_PREFIX then return nil end
    -- 值不像凭据（普通单词/路径/短值）时不登记，避免污染原始密钥映射表。
    if not looks_like_assigned_secret(value) then return nil end
    return token_for(value, "env_name:" .. name)
  end
  text = text:gsub("([%a_][%w_]*)(%s*=%s*)(" .. NAME_VALUE_CHARS .. ")([%(]?)", function(name, sep, value, paren)
    if paren == "(" then return nil end
    local token = make(name, value)
    if not token then return nil end
    return name .. sep .. token
  end)
  -- 带引号赋值（含 JSON `"name": "value"`）：名字/值两侧引号可省略或配对，用反向引用一次
  -- 匹配所有形态。此前对单/双引号各跑两条 gsub（共 4 次全文扫描），大文件时是主要耗时。
  text = text:gsub("([\"']?)([%a_][%w_]*)%1(%s*[=:]%s*)([\"'])(.-)%4", function(q1, name, sep, q2, value)
    local token = make(name, value)
    if not token then return nil end
    return q1 .. name .. q1 .. sep .. q2 .. token .. q2
  end)
  return text
end

--- run 是否紧邻路径分隔符（`/`）——即某个文件系统路径的分量。路径分量是 PATH/
--- LD_LIBRARY_PATH/PYTHONPATH 等环境变量与日志中路径的组成部分，token 化会让程序找不到
--- 库/模块（如 pip 报 `without an ssl module`），故不参与通用熵 token 化。
--- @param text string
--- @param s number 起点（1-based）
--- @param e number 终点（1-based）
--- @return boolean
local function is_path_component(text, s, e)
  local before = s > 1 and text:sub(s - 1, s - 1) or ""
  local after = e < #text and text:sub(e + 1, e + 1) or ""
  return before == "/" or after == "/" or before == "\\" or after == "\\"
end

--- 全文 token 化：具名规则 -> 变量名赋值 -> 残余高熵串。token_for(secret, rule_name) -> 替换文本。
--- 残余扫描保留位置，跳过路径分量（见 `is_path_component`）。
--- `opts.entropy == false` 时跳过残余高熵扫描（仅保留具名规则与敏感变量名赋值），
--- 供「非密钥文件」路径避免对全文做昂贵的熵计算。
--- @param text string
--- @param cfg table
--- @param token_for function
--- @param opts table|nil { entropy?: boolean }
--- @return string
local function process(text, cfg, token_for, opts)
  text = apply_rules(text, cfg, token_for)
  text = apply_secret_names(text, token_for)
  if opts and opts.entropy == false then return text end
  local parts, pos = {}, 1
  while true do
    local s, e = text:find(RUN_PAT, pos)
    if not s then
      parts[#parts + 1] = text:sub(pos)
      break
    end
    parts[#parts + 1] = text:sub(pos, s - 1)
    local run = text:sub(s, e)
    if not is_path_component(text, s, e) and is_candidate(run, cfg) then
      parts[#parts + 1] = token_for(run, nil)
    else
      parts[#parts + 1] = run
    end
    pos = e + 1
  end
  return table.concat(parts)
end

return { process = process, apply_rules = apply_rules, is_candidate = is_candidate, entropy = entropy,
  validate = validate, secret_name = secret_name, secret_name_prefix = secret_name_prefix }
]==]

local _scan = assert(load(SCAN_SRC))()

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

--- 确保每进程随机盐已就绪（token 派生用；跨密钥唯一）
--- @return string
local function _ensure_salt()
  if state.salt then return state.salt end
  local seed = table.concat({ tostring(os.time()), tostring(vim.fn.getpid()), tostring(math.random(1, 2 ^ 30)) })
  state.salt = tostring(vim.fn.sha256(seed))
  return state.salt
end

--- 登记一个（已生成的）secret->token 映射并触发留痕/事件/审计。
--- 供主线程 `_token_for` 与工作线程结果合并共用。
--- @param secret string
--- @param token string
--- @param rule_name string|nil
local function _register_token(secret, token, rule_name)
  if state.by_secret[secret] then return end
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
end

--- 生成随机 token（每进程随机盐，跨密钥唯一）
--- @param secret string
--- @param rule_name string|nil 命中的具名规则（用于留痕）
--- @return string
local function _token_for(secret, rule_name)
  local existing = state.by_secret[secret]
  if existing then return existing end
  state.seq = state.seq + 1
  local hex = tostring(vim.fn.sha256(_ensure_salt() .. "|" .. state.seq .. "|" .. secret))
  local token = TOKEN_PREFIX .. hex:sub(1, 32)
  _register_token(secret, token, rule_name)
  return token
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
        local res = text:gsub(rule.pattern, function(m)
          if not _scan.validate(rule, m) then return m end
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
  return _scan.entropy(s or "")
end

--- 检测文本中的密钥候选（具名规则 + 带上下文/密钥形态的高熵串）
--- 高熵串需呈密钥形态（含 - / _）或处于敏感变量名赋值上下文；纯字母数字/base64
--- （内容哈希、SRI integrity 等）不计入，见 `tools.sandbox.secrets.entropy_requires_context`。
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
    out[#out + 1] = { value = v, start = s, stop = e, entropy = _scan.entropy(v), rule = rule }
  end
  local pos = 1
  while true do
    local s, e = text:find(RUN_PAT, pos)
    if not s then break end
    local run = text:sub(s, e)
    -- 裸熵串的上下文信号：紧邻的敏感变量名赋值（KEY=/TOKEN:/PASSWORD=）使其无需分隔符。
    -- 只回看有限窗口，避免在大文本上对每个 run 复制整段前缀（O(n²)）。
    local prefix = text:sub(s > 64 and s - 64 or 1, s - 1)
    if _scan.is_candidate(run, cfg, _scan.secret_name_prefix(prefix)) then add(s, e) end
    pos = e + 1
  end
  -- 具名规则：补充结构化敏感信息（私钥块/带前缀 token 等熵检测盲区）；与熵检测重叠时去重。
  for _, rule in ipairs(cfg.rules or {}) do
    if type(rule.pattern) == "string" then
      local s, e = text:find(rule.pattern)
      while s do
        local m = text:sub(s, e)
        if _scan.validate(rule, m) then add(s, e, rule.name) end
        s, e = text:find(rule.pattern, e + 1)
      end
    end
  end
  return out
end

--- 检测文本中**具名规则**命中的敏感信息（不做熵检测）。
--- 供 UI 行内高亮等热路径使用：具名规则命中带 `rule`，正是界面告警/高亮所依据的类别；
--- 熵检测（`detect`）逐行调用代价高，而 UI 只需定位带前缀的结构化凭据与 token。
--- 每条规则先以其 `prefix` 做 plain find 短路，绝大多数行不含任何前缀时近乎零开销。
--- @param text string
--- @return table 数组 { value, start, stop, rule }
function M.detect_named(text)
  local out = {}
  if type(text) ~= "string" or text == "" then return out end
  local cfg = _cfg()
  if cfg.enabled == false then return out end
  local seen = {}
  for _, rule in ipairs(cfg.rules or {}) do
    if type(rule.pattern) == "string" then
      local present = true
      if type(rule.prefix) == "string" and rule.prefix ~= "" then
        present = text:find(rule.prefix, 1, true) ~= nil
      end
      if present then
        local s, e = text:find(rule.pattern)
        while s do
          local key = s .. ":" .. e
          if not seen[key] then
            seen[key] = true
            local m = text:sub(s, e)
            if _scan.validate(rule, m) then
              out[#out + 1] = { value = m, start = s, stop = e, rule = rule.name }
            end
          end
          s, e = text:find(rule.pattern, e + 1)
        end
      end
    end
  end
  return out
end
--- @param text string
--- @param opts table|nil { entropy?: boolean } entropy=false 时跳过残余高熵扫描
--- @return string tokenized
--- @return table tokens 本次用到的 token 数组
function M.tokenize(text, opts)
  if not M.enabled() or type(text) ~= "string" or text == "" then return text, {} end
  local cfg = _cfg()
  local used = {}
  -- 全文扫描核心（规则 -> 变量名赋值 -> 残余高熵串）；token 生成经回调注入。
  local out = _scan.process(text, cfg, function(secret, rule_name)
    local token = _token_for(secret, rule_name)
    used[#used + 1] = token
    return token
  end, opts)
  return out, used
end

-- ========== 工作线程：全文扫描（移出主线程） ==========
-- 编码统一为二进制安全的 `<len>:<bytes>` 字段顺序拼接（无分隔符），主线程与线程内共用规则。

--- 线程内批量 token 化：扫描核心在独立线程执行，token 由本地 map + 纯 Lua sha256 生成；
--- 返回新 token 条目与 tokenized 文本，主线程据此登记映射并触发事件/审计。
--- @param cfg_enc string
--- @param map_enc string
--- @param salt string
--- @param seq number|string
--- @param texts_enc string
--- @param sha_src string
--- @param scan_src string
--- @param entropy_flags string|nil 与文本并行的 "0"/"1" 串；"0" 跳过该文本的残余高熵扫描
--- @return string 编码结果
local function _tokenize_worker(cfg_enc, map_enc, salt, seq, texts_enc, sha_src, scan_src, entropy_flags)
  local sha = assert(load(sha_src))()
  local process = assert(load(scan_src))().process
  local function make_reader(s)
    local pos = 1
    return function()
      local colon = s:find(":", pos, true)
      local len = tonumber(s:sub(pos, colon - 1))
      local v = s:sub(colon + 1, colon + len)
      pos = colon + len + 1
      return v
    end
  end
  local nxt = make_reader(cfg_enc)
  local cfg = {
    min_length = tonumber(nxt()), max_length = tonumber(nxt()),
    min_entropy = tonumber(nxt()), min_distinct = tonumber(nxt()),
    exclude_pure_hex = nxt() == "1", entropy_requires_context = nxt() == "1",
    allowlist = {}, rules = {},
  }
  for _ = 1, tonumber(nxt()) do cfg.allowlist[#cfg.allowlist + 1] = nxt() end
  for _ = 1, tonumber(nxt()) do
    local name, pattern, vk, prefix = nxt(), nxt(), nxt(), nxt()
    cfg.rules[#cfg.rules + 1] = {
      name = name ~= "" and name or nil, pattern = pattern,
      validate_kind = vk ~= "" and vk or nil, prefix = prefix ~= "" and prefix or nil,
    }
  end
  local map = {}
  local mn = make_reader(map_enc)
  for _ = 1, tonumber(mn()) do
    local secret, token = mn(), mn()
    map[secret] = token
  end
  local tn = make_reader(texts_enc)
  local texts = {}
  for i = 1, tonumber(tn()) do texts[i] = tn() end

  seq = tonumber(seq) or 0
  local new = {}
  local function token_for(secret, rule)
    local t = map[secret]
    if t then return t end
    seq = seq + 1
    t = "NEOKEY_" .. sha(salt .. "|" .. seq .. "|" .. secret):sub(1, 32)
    map[secret] = t
    new[#new + 1] = { secret, t, rule }
    return t
  end
  local outs = {}
  for i = 1, #texts do
    local entropy = not (entropy_flags and entropy_flags:sub(i, i) == "0")
    outs[i] = process(texts[i], cfg, token_for, { entropy = entropy })
  end

  local function es(s) s = s or ""; return tostring(#s) .. ":" .. s end
  local parts = { es(tostring(seq)), es(tostring(#new)) }
  for _, e in ipairs(new) do
    parts[#parts + 1] = es(e[1]); parts[#parts + 1] = es(e[2]); parts[#parts + 1] = es(e[3] or "")
  end
  parts[#parts + 1] = es(tostring(#outs))
  for i = 1, #outs do parts[#parts + 1] = es(outs[i]) end
  return table.concat(parts)
end

--- 主线程侧编码辅助
--- @param s string|nil
--- @return string
local function _enc_str(s)
  s = s or ""
  return tostring(#s) .. ":" .. s
end

--- @param cfg table
--- @return string
local function _encode_cfg(cfg)
  local p = {
    _enc_str(tostring(cfg.min_length or 20)), _enc_str(tostring(cfg.max_length or 200)),
    _enc_str(tostring(cfg.min_entropy or 3.5)), _enc_str(tostring(cfg.min_distinct or 8)),
    _enc_str(cfg.exclude_pure_hex ~= false and "1" or "0"),
    _enc_str(cfg.entropy_requires_context ~= false and "1" or "0"),
  }
  local al = cfg.allowlist or {}
  p[#p + 1] = _enc_str(tostring(#al))
  for _, x in ipairs(al) do p[#p + 1] = _enc_str(tostring(x)) end
  local rules = cfg.rules or {}
  p[#p + 1] = _enc_str(tostring(#rules))
  for _, r in ipairs(rules) do
    p[#p + 1] = _enc_str(r.name or ""); p[#p + 1] = _enc_str(r.pattern or "")
    p[#p + 1] = _enc_str(r.validate_kind or ""); p[#p + 1] = _enc_str(r.prefix or "")
  end
  return table.concat(p)
end

--- @param by_secret table
--- @return string
local function _encode_map(by_secret)
  local p = {}
  local n = 0
  for secret, token in pairs(by_secret) do
    n = n + 1
    p[#p + 1] = _enc_str(secret); p[#p + 1] = _enc_str(token)
  end
  return _enc_str(tostring(n)) .. table.concat(p)
end

--- @param texts table
--- @return string
local function _encode_texts(texts)
  local p = { _enc_str(tostring(#texts)) }
  for _, t in ipairs(texts) do p[#p + 1] = _enc_str(t) end
  return table.concat(p)
end

--- 解析工作线程结果：seq, new_entries, out_texts
--- @param enc string
--- @return number seq
--- @return table new entries { {secret, token, rule?} }
--- @return table out_texts
local function _decode_result(enc)
  local pos = 1
  local function rd()
    local colon = enc:find(":", pos, true)
    local len = tonumber(enc:sub(pos, colon - 1))
    local v = enc:sub(colon + 1, colon + len)
    pos = colon + len + 1
    return v
  end
  local seq = tonumber(rd())
  local new = {}
  for _ = 1, tonumber(rd()) do
    local secret, token, rule = rd(), rd(), rd()
    new[#new + 1] = { secret = secret, token = token, rule = rule ~= "" and rule or nil }
  end
  local outs = {}
  for i = 1, tonumber(rd()) do outs[i] = rd() end
  return seq, new, outs
end

--- 规则是否可离线：带 validate 函数但无 validate_kind 的规则无法序列化到线程。
--- @param cfg table
--- @return boolean
local function _can_offload(cfg)
  for _, r in ipairs(cfg.rules or {}) do
    if type(r.validate) == "function" and not r.validate_kind then return false end
  end
  return true
end

--- 计算逐项熵开关串：`opts.entropy` 统一开关，`opts.entropy_flags` 按文本下标覆盖。
--- @param texts table
--- @param opts table|nil
--- @return string "0"/"1" 串
local function _entropy_flags(texts, opts)
  opts = opts or {}
  local default = opts.entropy ~= false
  local flags = opts.entropy_flags
  local out = {}
  for i = 1, #texts do
    local on = default
    if type(flags) == "table" and flags[i] ~= nil then on = flags[i] ~= false end
    out[i] = on and "1" or "0"
  end
  return table.concat(out)
end

--- 每个工作任务的文本数（与候选冻结共用同一配置键）。
--- @return number
local function _work_chunk_files()
  local n = tonumber(require("NeoAI.kernel.config_store").get("tools.sandbox.work_chunk_files"))
  if not n or n <= 0 then return 128 end
  return n
end

--- 每批并发提交的 chunk 数上限（默认 4，与 libuv 线程池一致），避免一次性排满队列饿死
--- 后续 UI 关键 job。可经 tools.sandbox.work_parallelism 调整。
--- @return number
local function _work_parallelism()
  local n = tonumber(require("NeoAI.kernel.config_store").get("tools.sandbox.work_parallelism"))
  if not n or n <= 0 then return 4 end
  return n
end

--- 合并并行分块的 token 结果：各块 seq 起点相同，同一 secret 在不同块可能被分配不同 token。
--- 取首次出现的 token 为规范值，并把其余分块输出中的等价 token 替换回规范 token，
--- 保证 detokenize 可无损还原；最后统一登记并推进全局 seq。
--- @param results table 数组 { seq, new, outs }
--- @return table 合并后的逐项输出
local function _merge_chunk_results(results)
  local canonical, canonical_list = {}, {}
  local max_seq = state.seq
  for _, r in ipairs(results) do
    if r.seq and r.seq > max_seq then max_seq = r.seq end
    for _, e in ipairs(r.new) do
      local secret, token = e.secret, e.token
      if secret and not canonical[secret] then
        canonical[secret] = token
        canonical_list[#canonical_list + 1] = e
      end
    end
  end
  for _, r in ipairs(results) do
    local remap = nil
    for _, e in ipairs(r.new) do
      local secret, token = e.secret, e.token
      local canon = secret and canonical[secret]
      if canon and canon ~= token then
        remap = remap or {}
        remap[token] = canon
      end
    end
    if remap then
      -- 单遍按 token 模式重写：每个输出文件只扫描一次（此前对每个 remap 项各做一次
      -- 全文 gsub，块内输出×remap 近似平方，数万文件时占满主线程）。
      for i = 1, #r.outs do
        local out = r.outs[i]
        r.outs[i] = out:gsub(TOKEN_PAT, function(tok) return remap[tok] or tok end)
      end
    end
  end
  for _, e in ipairs(canonical_list) do _register_token(e.secret, e.token, e.rule) end
  state.seq = max_seq
  local outs, idx = {}, 0
  for _, r in ipairs(results) do
    for i = 1, #r.outs do idx = idx + 1; outs[idx] = r.outs[i] end
  end
  return outs
end

--- 批量异步 token 化：全文扫描（规则/变量名/熵）在线程池执行，token 生成与登记在主线程。
--- @param texts table 字符串数组
--- @param opts table|nil { entropy?: boolean 统一开关；entropy_flags?: boolean[] 按项覆盖 }
--- @return Deferred resolve(数组：逐项 tokenized 文本)
function M.tokenize_many_async(texts, opts)
  local async = require("NeoAI.utils.async")
  if not M.enabled() then return async.resolve(texts) end
  local work = require("NeoAI.utils.work")
  local cfg = _cfg()
  local flags = _entropy_flags(texts, opts)
  if not work.available() or not _can_offload(cfg) then
    local out = {}
    for i, t in ipairs(texts) do out[i] = (M.tokenize(t, { entropy = flags:sub(i, i) ~= "0" })) end
    return async.resolve(out)
  end
  local sha_src = require("NeoAI.utils.sha256").source
  local salt = _ensure_salt()
  local cfg_enc = _encode_cfg(cfg)
  local chunk = _work_chunk_files()
  if #texts <= chunk then
    local map_enc, texts_enc = _encode_map(state.by_secret), _encode_texts(texts)
    return work.run(_tokenize_worker, cfg_enc, map_enc, salt, state.seq, texts_enc, sha_src, SCAN_SRC, flags)
      :then_(function(enc)
        local seq, new, outs = _decode_result(enc)
        for _, e in ipairs(new) do _register_token(e.secret, e.token, e.rule) end
        if seq and seq > state.seq then state.seq = seq end
        return outs
      end)
  end
  -- 大量文本（如 npm/cargo 产生的大量候选文件）：按块并发投递到线程池用满多核，
  -- 结果按原顺序合并。各块独立分配 token，合并时统一到规范 token（见 _merge_chunk_results）。
  local map_enc = _encode_map(state.by_secret)
  local tasks = {}
  local i = 1
  while i <= #texts do
    local j = math.min(i + chunk - 1, #texts)
    local sub = {}
    for k = i, j do sub[#sub + 1] = texts[k] end
    tasks[#tasks + 1] = { sub = sub, flags = flags:sub(i, j) }
    i = j + 1
  end
  return work.batched(tasks, _work_parallelism(), function(task)
    return work.run(_tokenize_worker, cfg_enc, map_enc, salt, state.seq,
      _encode_texts(task.sub), sha_src, SCAN_SRC, task.flags):then_(function(enc)
        local seq, new, outs = _decode_result(enc)
        return { seq = seq, new = new, outs = outs }
      end)
  end):then_(function(results)
    return _merge_chunk_results(results)
  end)
end

--- 单文本异步 token 化
--- @param text string
--- @param opts table|nil { entropy?: boolean }
--- @return Deferred resolve(string)
function M.tokenize_async(text, opts)
  return M.tokenize_many_async({ text or "" }, opts):then_(function(outs) return outs[1] end)
end

-- ========== 工作线程：候选文件密钥分析（token 警告 + 生成高熵） ==========

--- 线程内逐文件扫描：统计 NEOKEY token 与生成高熵/具名规则命中（检测逻辑与主线程一致）。
--- @param cfg_enc string
--- @param texts_enc string
--- @param scan_src string
--- @return string 编码结果（每文件：token 数+token 列表，hits 数+各 hit 的 value/entropy/rule）
local function _analyze_worker(cfg_enc, texts_enc, scan_src)
  local scan = assert(load(scan_src))()
  local RUN_PAT = "[%w_%-%+]+"
  local function make_reader(s)
    local pos = 1
    return function()
      local colon = s:find(":", pos, true)
      if not colon then return nil end
      local len = tonumber(s:sub(pos, colon - 1)) or 0
      local v = s:sub(colon + 1, colon + len)
      pos = colon + len + 1
      return v
    end
  end
  local nxt = make_reader(cfg_enc)
  local cfg = {
    min_length = tonumber(nxt()), max_length = tonumber(nxt()),
    min_entropy = tonumber(nxt()), min_distinct = tonumber(nxt()),
    exclude_pure_hex = nxt() == "1", entropy_requires_context = nxt() == "1",
    allowlist = {}, rules = {},
  }
  for _ = 1, tonumber(nxt()) do cfg.allowlist[#cfg.allowlist + 1] = nxt() end
  for _ = 1, tonumber(nxt()) do
    local name, pattern, vk, prefix = nxt(), nxt(), nxt(), nxt()
    cfg.rules[#cfg.rules + 1] = {
      name = name ~= "" and name or nil, pattern = pattern,
      validate_kind = vk ~= "" and vk or nil, prefix = prefix ~= "" and prefix or nil,
    }
  end
  local tn = make_reader(texts_enc)
  local texts = {}
  for i = 1, tonumber(tn()) do texts[i] = tn() or "" end

  local function detect(text)
    local out, seen = {}, {}
    local function add(s, e, rule)
      if s == nil then return end
      local key = s .. ":" .. e
      if seen[key] then return end
      seen[key] = true
      local v = text:sub(s, e)
      out[#out + 1] = { value = v, entropy = scan.entropy(v), rule = rule }
    end
    local pos = 1
    while true do
      local s, e = text:find(RUN_PAT, pos)
      if not s then break end
      local run = text:sub(s, e)
      local prefix = text:sub(s > 64 and s - 64 or 1, s - 1)
      if scan.is_candidate(run, cfg, scan.secret_name_prefix(prefix)) then add(s, e) end
      pos = e + 1
    end
    for _, rule in ipairs(cfg.rules or {}) do
      if type(rule.pattern) == "string" then
        local s, e = text:find(rule.pattern)
        while s do
          local m = text:sub(s, e)
          if scan.validate(rule, m) then add(s, e, rule.name) end
          s, e = text:find(rule.pattern, e + 1)
        end
      end
    end
    return out
  end

  local function es(s) s = s or ""; return tostring(#s) .. ":" .. s end
  local parts = { es(tostring(#texts)) }
  for i = 1, #texts do
    local text = texts[i]
    local toks, ntok = {}, 0
    for tok in text:gmatch("NEOKEY_%x+") do ntok = ntok + 1; toks[#toks + 1] = tok end
    parts[#parts + 1] = es(tostring(ntok))
    for _, t in ipairs(toks) do parts[#parts + 1] = es(t) end
    local hits = detect(text)
    parts[#parts + 1] = es(tostring(#hits))
    for _, h in ipairs(hits) do
      parts[#parts + 1] = es(h.value); parts[#parts + 1] = es(tostring(h.entropy)); parts[#parts + 1] = es(h.rule or "")
    end
  end
  return table.concat(parts)
end

--- 主线程解析 `_analyze_worker` 结果：按文件返回 token 与 hits。
--- @param enc string
--- @return table 数组 { tokens = string[], hits = { {value, entropy, rule} } }
local function _decode_analyze(enc)
  local pos = 1
  local function rd()
    local colon = enc:find(":", pos, true)
    if not colon then return nil end
    local len = tonumber(enc:sub(pos, colon - 1)) or 0
    local v = enc:sub(colon + 1, colon + len)
    pos = colon + len + 1
    return v
  end
  local n = tonumber(rd()) or 0
  local out = {}
  for i = 1, n do
    local ntok = tonumber(rd()) or 0
    local toks = {}
    for _ = 1, ntok do toks[#toks + 1] = rd() end
    local nhits = tonumber(rd()) or 0
    local hits = {}
    for _ = 1, nhits do
      local value = rd(); local entropy = tonumber(rd()); local rule = rd()
      hits[#hits + 1] = { value = value, entropy = entropy, rule = (rule ~= "" and rule) or nil }
    end
    out[i] = { tokens = toks, hits = hits }
  end
  return out
end

--- 批量异步分析候选文件：NEOKEY token 警告 + 生成高熵/具名规则命中在**工作线程**扫描，
--- 主线程只做预算选择与结果聚合，避免大候选逐文件全文扫描阻塞结算。
--- @param files table 候选文件数组（含 content）
--- @param opts table|nil { generated?: boolean 是否做生成高熵检测，默认 true }
--- @return Deferred resolve({ warning = {count,tokens}|nil, generated = table[] })
function M.analyze_files_async(files, opts)
  local async = require("NeoAI.utils.async")
  opts = opts or {}
  local empty = { warning = nil, generated = {}, offloaded = true }
  if not M.enabled() then return async.resolve(empty) end
  local cfg = _cfg()
  -- 预算选择：与 detect_generated 同步版一致（生成检测受 generated_scan_max_* 约束）。
  local max_bytes = tonumber(cfg.generated_scan_max_bytes) or 0
  local max_files = tonumber(cfg.generated_scan_max_files) or 0
  local scan_bytes, scan_count = 0, 0
  local selected, idx = {}, {}
  for i, f in ipairs(files or {}) do
    if type(f.content) == "string" and f.content ~= "" then
      if not (max_files > 0 and scan_count >= max_files)
        and not (max_bytes > 0 and scan_bytes + #f.content > max_bytes) then
        scan_bytes = scan_bytes + #f.content
        scan_count = scan_count + 1
        selected[#selected + 1] = f.content
        idx[#idx + 1] = i
      end
    end
  end
  if #selected == 0 then return async.resolve(empty) end
  local work = require("NeoAI.utils.work")
  if not work.available() or not _can_offload(cfg) then
    return async.resolve({ offloaded = false }) -- 回退：调用方使用同步版
  end
  local cfg_enc = _encode_cfg(cfg)
  -- 结果聚合：与同步版语义一致（token 去重计数 + 生成高熵命中按文件索引还原）。
  local function accumulate(per, idxs, tokens, generated)
    local count = 0
    for k, entry in ipairs(per) do
      for _, tok in ipairs(entry.tokens) do
        count = count + 1
        tokens[tok] = true
      end
      if opts.generated ~= false then
        for _, hit in ipairs(entry.hits) do
          if not hit.value:match("^" .. TOKEN_PAT .. "$") then
            local fi = idxs[k]
            generated[#generated + 1] = {
              path = files[fi] and files[fi].path, entropy = hit.entropy, rule = hit.rule,
              preview = hit.value:sub(1, 8) .. "…",
            }
          end
        end
      end
    end
    return count
  end
  local function finalize(tokens, count, generated)
    local warning = nil
    if count > 0 then
      local list = {}
      for tok in pairs(tokens) do list[#list + 1] = tok end
      table.sort(list)
      warning = { count = count, tokens = list }
    end
    return { warning = warning, generated = generated }
  end
  local chunk = _work_chunk_files()
  if #selected <= chunk then
    return work.run(_analyze_worker, cfg_enc, _encode_texts(selected), SCAN_SRC):then_(function(enc)
      local tokens, generated = {}, {}
      local count = accumulate(_decode_analyze(enc), idx, tokens, generated)
      return finalize(tokens, count, generated)
    end)
  end
  -- 大量文本（大候选）：按块并发投递到线程池用满多核，结果按顺序聚合。
  local subs, idx_chunks = {}, {}
  local i = 1
  while i <= #selected do
    local j = math.min(i + chunk - 1, #selected)
    local sub, subidx = {}, {}
    for k = i, j do sub[#sub + 1] = selected[k]; subidx[#sub + 1] = idx[k] end
    subs[#subs + 1] = sub
    idx_chunks[#idx_chunks + 1] = subidx
    i = j + 1
  end
  return work.batched(subs, _work_parallelism(), function(sub)
    return work.run(_analyze_worker, cfg_enc, _encode_texts(sub), SCAN_SRC):then_(function(enc)
      return _decode_analyze(enc)
    end)
  end):then_(function(results)
    local tokens, generated, count = {}, {}, 0
    for ci, per in ipairs(results) do
      count = count + accumulate(per, idx_chunks[ci], tokens, generated)
    end
    return finalize(tokens, count, generated)
  end)
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

-- AI 读取到 KEY（结果被 token 化）时追加的说明：真实密钥已被沙箱遮蔽（仅对 AI 不可见），
-- 这是沙箱的显示层保护，不代表程序出错、也不影响程序实际运行；token 在写入文件时自动还原。
-- 沙箱只遮蔽密钥形态的高熵串，路径/函数名/构建哈希等原样保留（见 `is_path_component` /
-- `looks_like_identifier`）；环境变量侧以 `NEOAI_TOKENIZED_ENV` 标识被遮蔽的变量名。
local READ_HINT = "提示：结果中的 NEOKEY_* 为沙箱密钥 token——真实密钥已被沙箱遮蔽，仅对 AI 不可见，"
  .. "不代表程序出错、也不影响程序实际运行（写入文件时自动替换回原有真实密钥）。"
  .. "沙箱只遮蔽密钥形态的高熵串，路径、函数名、构建哈希等原样保留；"
  .. "被遮蔽的环境变量名见 NEOAI_TOKENIZED_ENV。"

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

-- 敏感环境变量名形态：全大写字母/数字/下划线，长度 >= 6（排除 KEY/TOKEN 等短词噪声）。
local ENV_NAME_PAT = "%u[%u%d_]*"

--- NeoAI 内部事件/标识（非环境变量）。例如错误文案里的 `SANDBOX_SECRET_BLOCKED`
--- 含 `SECRET` 段且全大写，会被误判为敏感环境变量名，从而渲染出「密钥环境变量：
--- SANDBOX_SECRET_BLOCKED」这类无意义告警。按前缀排除。
--- @param name string
--- @return boolean
local function is_internal_identifier(name)
  return name:match("^SANDBOX_SECRET_") ~= nil
end

--- 深度扫描值中的**敏感环境变量名**（全大写、名字含 KEY/TOKEN/SECRET/PASSWORD/CREDENTIAL 段）。
--- 用于「出现了 key 的环境变量名」时的软告警 + 审批：**不终止 Agent**，只提级并把候选送入
--- 待审（悬浮窗展示 `⚠ 密钥操作`）。全大写 + 长度阈值避免把代码里的 `api_key`/`os.getenv`
--- 等小写标识符当作环境变量名。
--- @param value any
--- @return table 去重后的名字数组
function M.scan_names(value)
  local out, seen = {}, {}
  local function walk(v)
    local t = type(v)
    if t == "string" then
      for name in v:gmatch(ENV_NAME_PAT) do
        if #name >= 6 and not seen[name] and not is_internal_identifier(name)
          and _scan.secret_name(name) then
          seen[name] = true
          out[#out + 1] = name
        end
      end
    elseif t == "table" then
      for k, x in pairs(v) do
        walk(x)
        if type(k) == "string" then walk(k) end
      end
    end
  end
  walk(value)
  return out
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

--- 递归扫描值中是否含映射表已知的原始密钥。
--- @param v any
--- @return string|nil secret
local function _walk_real_secret(v)
  local t = type(v)
  if t == "string" then
    return M.find_real_secret(v)
  elseif t == "table" then
    for k, x in pairs(v) do
      local hit = _walk_real_secret(x)
      if hit then return hit end
      if type(k) == "string" then
        local hk = M.find_real_secret(k)
        if hk then return hk end
      end
    end
  end
  return nil
end

--- 扫描 AI 可见上下文（wire 消息等嵌套结构）是否含映射表中已知的**原始密钥**。
--- 供请求前终止判定：原始密钥出现在 AI 上下文中说明 token 化被绕过（沙箱上下文被突破）。
--- token（`NEOKEY_*`）不算命中——KEY 环境变量操作只提级审批，不终止 Agent。
--- @param value any
--- @return string|nil secret 命中的原始密钥
function M.context_leak(value)
  if not M.enabled() then return nil end
  if next(state.by_secret) == nil then return nil end
  return _walk_real_secret(value)
end

--- 增量扫描：仅检测 `messages[from..]` 中的新增项是否含原始密钥。
--- 供请求前守卫只检测**新增上下文/工具调用**，避免每轮对整段历史重扫。
--- @param messages table 消息数组
--- @param from number 起始下标（1-based，含）
--- @return string|nil secret
function M.context_leak_from(messages, from)
  if not M.enabled() then return nil end
  if next(state.by_secret) == nil then return nil end
  if type(messages) ~= "table" then return nil end
  for i = math.max(1, tonumber(from) or 1), #messages do
    local hit = _walk_real_secret(messages[i])
    if hit then return hit end
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
--- @param opts table|nil { entropy?: boolean }
--- @return table tokens 用到的 token 数组
function M.tokenize_args(args, opts)
  local used = {}
  local function walk(t)
    for k, v in pairs(t) do
      if type(v) == "string" then
        local nv, toks = M.tokenize(v, opts)
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

--- 生成 token 化的环境变量覆盖（供日志/审计与 AI 可见面；**不是**沙箱进程最终环境）。
--- 变量名命中敏感词段（KEY/TOKEN/SECRET/PASSWORD/CREDENTIAL）时**无视熵阈值**强制 token 化，
--- 避免纯 hex 密钥（如 GLM_API_KEY）逃过熵检测而原样暴露。
--- 只要发生 token 化，就注入 `NEOAI_TOKENIZED_ENV=<变量名列表>` 信号，标记哪些值在 AI 可见
--- 输出中会被 token 化。沙箱进程实际环境由 `runtime.sandbox_env` 构造，会把 token 还原为真实
--- 密钥（token→真实仅限沙箱内部进程）。
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
      if _scan.secret_name(k) then
        overrides[k] = _token_for(v)
        names[#names + 1] = k
      elseif v:find("/", 1, true) or v:find("\\", 1, true) then
        -- 路径/URL 类值：只应用具名规则（结构化凭据），不做通用熵 token 化。
        -- PATH/LD_LIBRARY_PATH/PYTHONPATH/SSL_CERT_FILE 等是程序运行所必需，
        -- 把路径段误 token 化会让 pip/ssl 等找不到库或模块。
        local nv = _scan.apply_rules(v, _cfg(), _token_for)
        if nv ~= v then
          overrides[k] = nv
          names[#names + 1] = k
        end
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
--- @param opts table|nil { entropy?: boolean } entropy=false 时仅脱敏具名规则/敏感变量名
--- @return any
function M.tokenize_result(value, opts)
  if not M.enabled() then return value end
  local t = type(value)
  if t == "string" then
    return (M.tokenize(value, opts))
  elseif t == "table" then
    local out = vim.deepcopy(value)
    local function walk(v)
      if type(v) == "table" then
        for k, x in pairs(v) do
          if type(x) == "string" then v[k] = M.tokenize(x, opts)
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
    -- 先做 C 级子串预筛：绝大多数候选文件不含 token，避免对每个文件都启动 gmatch
    -- 模式扫描（1M 文件时是结算主线程的固定热点）。
    if type(f.content) == "string" and f.content:find("NEOKEY_", 1, true) then
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

--- 检测 AI **生成/写入**的高熵/结构化敏感内容（候选文件内容）。
--- 与 `warn_for_files`（只识别已 token 化的宿主密钥）不同：此函数直接对候选内容做熵/具名规则
--- 检测，捕获 AI 自行生成的密钥类信息（生成的私钥、随机 token、API key 等），供留痕与审批提示。
--- token（`NEOKEY_*`）不计入（那是宿主密钥的加密形式，由 `warn_for_files` 处理）。
--- @param files table 候选文件数组
--- @return table 数组 { path, entropy, rule, preview }
function M.detect_generated(files)
  local out = {}
  if not M.enabled() then return out end
  local token_pat = "^" .. TOKEN_PAT .. "$"
  -- 扫描预算：候选文件很多/很大时，逐文件全文熵/规则检测是结算阶段的主线程热点。
  -- 超预算的文件跳过（0 = 不限制），避免大候选（包安装/构建产物）冻结界面。
  local cfg = _cfg()
  local max_bytes = tonumber(cfg.generated_scan_max_bytes) or 0
  local max_files = tonumber(cfg.generated_scan_max_files) or 0
  local scanned_bytes, scanned_files = 0, 0
  for _, f in ipairs(files or {}) do
    if max_files > 0 and scanned_files >= max_files then break end
    if type(f.content) == "string" and f.content ~= "" then
      local size = #f.content
      if max_bytes > 0 and scanned_bytes + size > max_bytes then
        -- 本文件超预算：跳过（不再继续消耗主线程）。
      else
        scanned_bytes = scanned_bytes + size
        scanned_files = scanned_files + 1
        for _, hit in ipairs(M.detect(f.content)) do
          if not hit.value:match(token_pat) then
            out[#out + 1] = {
              path = f.path, entropy = hit.entropy, rule = hit.rule,
              preview = hit.value:sub(1, 8) .. "…",
            }
          end
        end
      end
    end
  end
  return out
end

-- 疑似密钥文件（宽口径）：供「高熵精确定位」的启用判定——只对这些文件做昂贵的全文熵扫描。
-- 含 shell 启动脚本/历史与 /etc/* 等可能内联凭据的配置；**不用于 UI 告警**（见下）。
local SECRET_PATH_PATS = {
  -- 凭据目录/文件
  "%.ssh/", "%.aws/", "%.gnupg/", "%.config/gcloud", "%.kube/", "%.docker/config%.json",
  "%.netrc$", "%.npmrc$", "%.pypirc$", "%.git%-credentials$", "/%.env$", "/%.env%.",
  "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa", "%.pem$", "%.key$", "%.p12$", "%.pfx$",
  "credentials", "secret",
  -- shell 启动脚本 / 历史（常内联 export KEY=... 与命令行凭据）
  "%.bashrc", "%.bash_profile", "%.bash_aliases", "%.bash_history", "%.bash_login",
  "%.zshrc", "%.zprofile", "%.zshenv", "%.zlogin", "%.zsh_history",
  "%.profile$", "%.pgpass$", "%.htpasswd$",
  "%.mysql_history$", "%.psql_history$", "%.python_history$", "%.irb_history$",
  -- 系统敏感配置
  "^/etc/", "/shadow$", "/sudoers",
}

-- 公开 CA 证书包 / 信任库（非密钥）：pip/certifi、系统 ca-certificates、语言运行时内置信任库等。
-- 这些 `.pem` 被普通命令（pip/curl/python）频繁打开，内容是公开根证书，不是凭据，
-- 不应触发「获取密钥」告警，也不应被高熵 token 化（否则会把证书 base64 误当密钥）。
local PUBLIC_CERT_BASENAMES = {
  ["cacert.pem"] = true, ["ca-bundle.pem"] = true, ["ca-certificates.pem"] = true,
  ["ca-root.pem"] = true, ["roots.pem"] = true, ["bundle.pem"] = true,
  ["chain.pem"] = true, ["fullchain.pem"] = true, ["trusted.pem"] = true,
  ["truststore.pem"] = true,
  -- 系统 CA 包常见名（证书是公开信息，非私钥）：Debian/Ubuntu 的 `/usr/lib/ssl/cert.pem`、
  -- `/etc/ssl/certs/ca-certificates.crt`，RHEL 系的 `ca-bundle.crt`/`tls-ca-bundle.pem` 等。
  ["cert.pem"] = true, ["ca-certificates.crt"] = true, ["ca-bundle.crt"] = true,
  ["tls-ca-bundle.pem"] = true,
}
local PUBLIC_CERT_DIR_PATS = {
  "/certifi/", "/ca%-certificates/", "/ssl/certs/",
  "/usr/lib/ssl/", "/usr/share/ca%-certificates/", "/usr/local/share/ca%-certificates/",
}

-- 第三方包缓存 / vendored 源码树（非凭据）：其中的 `*.pem`/`*.key`/`*.p12` 是依赖自带的
-- **测试夹具/示例证书**（如 `openssl` crate 的 `test/*.pem`、`tokio-native-tls` 的
-- `tests/identity.p12`），并非用户凭据；构建/测试命令（`cargo check`/`pip install`/`npm test`）
-- 会大量打开，不应触发「获取密钥」告警，也不应做高熵 token 化。
local NON_CREDENTIAL_DIR_PATS = {
  "/%.cargo/registry/", "/%.cargo/git/", "/%.rustup/", "/registry/src/",
  "/node_modules/", "/site%-packages/", "/dist%-packages/",
  "/go/pkg/mod/", "/%.gradle/caches/", "/%.m2/repository/", "/%.pub%-cache/",
}

--- 路径是否为公开 CA 证书包/信任库（非密钥）。
--- @param path string
--- @return boolean
local function is_public_cert_bundle(path)
  local base = path:match("[^/]+$") or path
  if PUBLIC_CERT_BASENAMES[base:lower()] then return true end
  for _, pat in ipairs(PUBLIC_CERT_DIR_PATS) do
    if path:find(pat) then return true end
  end
  return false
end

--- 路径是否位于第三方包缓存/vendored 源码树（非用户凭据）。
--- @param path string
--- @return boolean
local function is_non_credential_dir(path)
  for _, pat in ipairs(NON_CREDENTIAL_DIR_PATS) do
    if path:find(pat) then return true end
  end
  return false
end

--- 路径是否疑似密钥文件（宽口径：用于决定是否做高熵扫描）
--- @param path string|nil
--- @return boolean
function M.is_secret_path(path)
  if type(path) ~= "string" or path == "" then return false end
  if is_public_cert_bundle(path) or is_non_credential_dir(path) then return false end
  for _, pat in ipairs(SECRET_PATH_PATS) do
    if path:find(pat) then return true end
  end
  return false
end

-- 真正的凭据/密钥文件（严口径）：供 UI「获取密钥」告警。刻意排除常见误报——
-- `/etc/ld.so.cache`、`/etc/nsswitch.conf`、`/etc/passwd`、`/etc/group`、`/etc/os-release`、
-- `/etc/localtime`、`/etc/ssl/openssl.cnf`、`*.env`（如 `go.env`）、`.npmrc`、shell/解释器
-- 历史（`.bash_history`/`.python_history`）等：这些被普通命令（uname/cat/python/…）频繁打开，
-- 并非密钥，不应触发告警。
local SENSITIVE_PATH_PATS = {
  "%.ssh/", "%.aws/", "%.gnupg/", "%.config/gcloud", "%.kube/", "%.docker/config%.json",
  "%.netrc$", "%.pypirc$", "%.git%-credentials$", "/%.env$", "/%.env%.",
  "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa", "%.pem$", "%.key$", "%.p12$", "%.pfx$",
  "application_default_credentials", "/credentials$",
  "/shadow$", "/gshadow$", "/sudoers", "/etc/ssh/", "/etc/apt/auth%.conf",
  "trusted%.gpg", "keyrings?/",
}

--- 路径是否为真正的凭据/密钥文件（严口径，供 UI 告警）。
--- @param path string|nil
--- @return boolean
function M.is_sensitive_path(path)
  if type(path) ~= "string" or path == "" then return false end
  if is_public_cert_bundle(path) or is_non_credential_dir(path) then return false end
  for _, pat in ipairs(SENSITIVE_PATH_PATS) do
    if path:find(pat) then return true end
  end
  return false
end

--- 记录一次 token / 密钥环境变量名操作留痕（并写证据）
--- @param event string
--- @param meta table { tool?, path?, tokens?, names? }
function M.trace(event, meta)
  meta = meta or {}
  state.traces[#state.traces + 1] = {
    event = event, tool = meta.tool, path = meta.path,
    tokens = meta.tokens, names = meta.names, at = os.time(),
  }
  _record({
    event = event, tool = meta.tool, path = meta.path,
    tokens = meta.tokens and vim.tbl_keys(meta.tokens) or {},
    names = meta.names or {},
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
