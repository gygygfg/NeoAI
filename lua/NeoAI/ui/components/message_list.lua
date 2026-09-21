--- 消息列表渲染
--- @module NeoAI.ui.components.message_list
--- 将 Agent 消息渲染到 buffer。支持流式更新、推理折叠、工具结果展示。

local markdown_view = require("NeoAI.ui.components.markdown_view")
local stringx = require("NeoAI.utils.stringx")
local fold = require("NeoAI.ui.components.fold")
local config_store = require("NeoAI.kernel.config_store")
local json = require("NeoAI.utils.json")
local ansi = require("NeoAI.utils.ansi")
local display_modes = require("NeoAI.ui.components.display_modes")
local incremental = require("NeoAI.ui.components.incremental")

local M = {}

-- ========== 私有常量 ==========

local ROLE_LABELS = {
  user = "👤 用户",
  assistant = "🤖 AI",
  system = "⚙️ 系统",
  tool = "🔧 工具",
}

-- ========== 私有状态 ==========

local state = {
  show_reasoning = true,
}

--- 取指定 buffer 的共享块缓存（对话模式块键前缀 c:，避免与轨迹模式互相命中）
--- @param buf number
--- @return table
local function _cache_for(buf)
  return incremental.cache_for(buf)
end

-- ========== 私有函数 ==========

--- 将文本拆分为不含换行符的行数组（统一 \r\n/\r，避免 nvim_buf_set_lines 报错）
--- @param text string|nil
--- @return table 行数组
local function _split_lines(text)
  text = (text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  return vim.split(text, "\n", { plain = true })
end

-- ========== 表格斑马纹高亮 ==========

-- 表格高亮命名空间与高亮组：内容行按奇偶交替深浅，边框行最暗一档
local TABLE_HL_NS = vim.api.nvim_create_namespace("neoai_table_hi")
local TABLE_HL_GROUP = { border = "NeoAITableBorder", odd = "NeoAITableOdd", even = "NeoAITableEven" }

--- 对 #rrggbb 颜色做偏移（dr/dg/db 可为负），返回新颜色
--- @param hex string
--- @param dr number
--- @param dg number
--- @param db number
--- @return string
local function _shade(hex, dr, dg, db)
  local rs, gs, bs = hex:match("^(%x%x)(%x%x)(%x%x)$")
  if not rs then return hex end
  local clamp = function(n) return math.max(0, math.min(255, n)) end
  local r = clamp(tonumber(rs, 16) + dr)
  local g = clamp(tonumber(gs, 16) + dg)
  local b = clamp(tonumber(bs, 16) + db)
  return string.format("#%02x%02x%02x", r, g, b)
end

--- 定义表格高亮组（default=true，不覆盖用户自定义配色）。
--- 深度基于当前 Normal 背景衍生：深色主题 odd=Normal、even 更亮一档、border 更暗；
--- 浅色主题则相反。终端无背景时回退按 &background 的预设色。
local function _ensure_table_hl()
  local dark = vim.o.background ~= "light"
  local normal = vim.api.nvim_get_hl_by_name("Normal", true)
  -- 背景色可能是 hex 字符串 / number（颜色索引）/ nil：不是合法 hex 时回退预设色
  local bg = normal.background
  if type(bg) ~= "string" or not bg:match("^#%x%x%x%x%x%x$") then
    bg = dark and "#1b1b2b" or "#f0f0f0"
  end
  local border, even
  if dark then
    border = _shade(bg, -6, -6, -8)
    even = _shade(bg, 10, 12, 16)
  else
    border = _shade(bg, 6, 6, 8)
    even = _shade(bg, -10, -12, -16)
  end
  vim.api.nvim_set_hl(0, "NeoAITableBorder", { default = true, bg = border })
  vim.api.nvim_set_hl(0, "NeoAITableOdd", { default = true, bg = bg })
  vim.api.nvim_set_hl(0, "NeoAITableEven", { default = true, bg = even })
end

--- 对 buffer 应用表格斑马纹高亮。
--- 传入 range_from/range_to 时只重贴该区间（增量）：前缀区域的高亮保持不动，
--- 由调用方保证区间外的内容与高亮未变化；缺省时清空整个命名空间后全量重加。
--- @param buf number
--- @param marks table|nil 与行并行的元数据数组（每元素 nil 或 { tbl = "border"|"odd"|"even" }）
--- @param start_line number|nil marks[1] 对应的 1-based buffer 行号（默认 1）
--- @param range_from number|nil 增量重贴起始行（1-based，含）
--- @param range_to number|nil 增量重贴结束行（1-based，含）
--- 整行高亮：必须用 set_extmark 把 end_row 限定在本行（`hl_eol=true`）。
--- 不能用 `nvim_buf_add_highlight(..., row, 0, -1)`：其 end_col=-1 会被内部解释为
--- 下一行行首（end_row=row+1），导致后续增量 `clear_namespace(range_from, ...)`
--- 在 range_from=row+1 时误清本行高亮（见 secret 告警行消失回归）。
--- @param b number buffer
--- @param ns number 命名空间
--- @param group string 高亮组
--- @param row number 0-based 行号
local function _set_line_hl(b, ns, group, row)
  pcall(vim.api.nvim_buf_set_extmark, b, ns, row, 0, {
    end_row = row, end_col = 0, hl_eol = true, hl_group = group,
  })
end

local function _apply_table_hl(buf, marks, start_line, range_from, range_to)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  -- marks 与行并行，首行多为 nil（角色头等无高亮），不能用 ipairs（遇 nil 即止）。
  local has = false
  for i = 1, #(marks or {}) do
    if marks[i] and marks[i].tbl then has = true break end
  end
  if not has then return end
  _ensure_table_hl()
  start_line = start_line or 1
  local paint = function(b, ns, m, row)
    local group = m and TABLE_HL_GROUP[m.tbl]
    if group then
      _set_line_hl(b, ns, group, row)
    end
  end
  if range_from and range_to and range_to >= range_from then
    -- 增量：只重贴差异区间（marks 是全量数组，需按 start_line 偏移换算行号）
    local mfrom = range_from - start_line + 1
    local mto = range_to - start_line + 1
    local from = math.max(1, mfrom)
    local to = math.min(#(marks or {}), mto)
    pcall(vim.api.nvim_buf_clear_namespace, buf, TABLE_HL_NS, range_from - 1, range_to)
    for ln = from, to do
      local m = marks[ln]
      if m and m.tbl then
        paint(buf, TABLE_HL_NS, m, start_line - 1 + (ln - 1))
      end
    end
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, TABLE_HL_NS, 0, -1)
  for ln = 1, #marks do
    local m = marks[ln]
    if m and m.tbl then
      paint(buf, TABLE_HL_NS, m, start_line - 1 + (ln - 1))
    end
  end
end

-- ========== 密钥警告高亮 ==========

-- 工具参数 / 工具结果（模型上下文）含密钥时，在对应工具折叠块**外**单独追加一行
-- 高亮警告（非缩进 → 不并入折叠），折叠标题保持干净（不再追加 `⚠ 密钥`）。
local SECRET_HL_NS = vim.api.nvim_create_namespace("neoai_secret_hi")
local SECRET_HL_GROUP = "NeoAISecretWarning"

-- 命令输出的 ANSI SGR 颜色高亮（高亮组由 utils.ansi 惰性创建）。
local ANSI_HL_NS = vim.api.nvim_create_namespace("neoai_ansi_hi")

--- 定义密钥警告高亮组（default=true，用户可在 colorscheme 覆盖）。
local function _ensure_secret_hl()
  vim.api.nvim_set_hl(0, SECRET_HL_GROUP, {
    default = true, fg = "#ff5555", bold = true, underline = true,
  })
end

--- 值是否含密钥：
--- 1) 沙箱 token（`NEOKEY_*`）——已知密钥被加密映射后的表示，确定命中（字符串/块数组均可）；
--- 2) 具名规则命中的结构化敏感信息（私钥块 / 带前缀 token 等），确定命中；
---    仅具名规则（`detect_named`）参与，避免逐行熵检测拖慢大结果渲染。
--- @param v string|table|nil
--- @return boolean
local function _contains_secret(v)
  if v == nil then return false end
  local ok, secret = pcall(require, "NeoAI.sandbox.secret")
  if not ok or type(secret) ~= "table" then return false end
  if secret.enabled and not secret.enabled() then return false end
  if secret.contains_token and secret.contains_token(v) then return true end
  if type(v) == "string" and #v <= 65536 and secret.detect_named then
    local ok2, hits = pcall(secret.detect_named, v)
    if ok2 and type(hits) == "table" and #hits > 0 then return true end
  end
  return false
end

--- 单值密钥信息（一次扫描同时得到「是否含密钥」与命中的具名规则），避免重复检测。
--- @param v string|table|nil
--- @return table { has = boolean, rules = table }
local function _secret_info(v)
  local info = { has = false, rules = {} }
  if v == nil then return info end
  local ok, secret = pcall(require, "NeoAI.sandbox.secret")
  if not ok or type(secret) ~= "table" then return info end
  if secret.enabled and not secret.enabled() then return info end
  if secret.contains_token and secret.contains_token(v) then info.has = true end
  if type(v) == "string" and #v <= 65536 and secret.detect_named then
    local ok2, hits = pcall(secret.detect_named, v)
    if ok2 and type(hits) == "table" then
      for _, hit in ipairs(hits) do
        if hit and hit.rule ~= nil then
          info.has = true
          info.rules[hit.rule] = true
        end
      end
    end
  end
  return info
end

--- 路径是否为真正的凭据/密钥文件（严口径，用于 UI 告警）。
--- 注意与 `sandbox.secret.is_secret_path`（宽口径，用于高熵扫描门控）区分：后者含 `/etc/*`、
--- shell 历史等常见配置，若用于告警会把 `cat /etc/os-release`、`uname` 等误报为「获取密钥」。
--- @param p string
--- @return boolean
local function _is_secret_path(p)
  local ok, secret = pcall(require, "NeoAI.sandbox.secret")
  if ok and secret.is_sensitive_path then return secret.is_sensitive_path(p) end
  return false
end

-- 路径型参数名（含密钥文件路径的工具参数）
local PATH_KEYS = { filepath = true, file = true, path = true, dir = true, dirs = true, target = true }

-- 仅枚举/列出、不读取内容的工具：其路径参数不构成对密钥文件的读取/使用，不告警。
local LIST_ONLY_TOOLS = {
  list_files = true, search_files = true, file_exists = true, create_directory = true,
}

-- 仅查看元数据/列目录、不读取内容的命令首词：命中则不把命令中的密钥路径视为读取/使用。
local LIST_ONLY_CMDS = {
  ls = true, find = true, tree = true, stat = true, file = true, du = true, df = true,
  realpath = true, readlink = true, basename = true, dirname = true, which = true,
  ["type"] = true, command = true, locate = true, echo = true, printf = true, pwd = true,
}

-- 读取密钥内容的命令首词（用于区分「获取」）。
local READ_CMDS = {
  cat = true, tac = true, head = true, tail = true, less = true, more = true,
  grep = true, egrep = true, fgrep = true, rg = true, ag = true, sed = true, awk = true,
  cut = true, sort = true, uniq = true, strings = true, xxd = true, od = true,
  hexdump = true, base64 = true, cp = true, mv = true, tar = true, zip = true,
  unzip = true, diff = true, cmp = true, md5sum = true, sha256sum = true,
}

-- 使用密钥凭据的命令首词（用于区分「使用」）。
local USE_CMDS = {
  ssh = true, scp = true, sftp = true, ["ssh-add"] = true, ["ssh-keygen"] = true,
  curl = true, wget = true, openssl = true, gpg = true, git = true, rsync = true,
  mysql = true, psql = true, ["redis-cli"] = true, docker = true, kubectl = true,
  aws = true, gcloud = true, az = true, ansible = true, ["ansible-playbook"] = true,
  export = true, ["source"] = true,
}

-- 命令包装器/外壳：取真实命令首词时跳过。
local CMD_WRAPPERS = {
  sudo = true, doas = true, env = true, nohup = true, nice = true, ionice = true,
  stdbuf = true, setsid = true, timeout = true, command = true, exec = true,
  bash = true, sh = true, dash = true, zsh = true, ksh = true,
}

--- 命令首个真实可执行名的基名（跳过 sudo/env/赋值/包装器）。
--- @param cmd string|nil
--- @return string|nil
local function _command_bin(cmd)
  if type(cmd) ~= "string" then return nil end
  for tok in cmd:gmatch("%S+") do
    tok = tok:gsub("^['\"]+", ""):gsub("['\"]+$", "")
    if tok ~= "" and not tok:find("=", 1, true) then
      local base = tok:match("[^/]+$") or tok
      if not CMD_WRAPPERS[base] then return base end
    end
  end
  return nil
end

--- 命令对密钥的作用类别："read"（获取）/ "use"（使用）/ nil（仅列出或未知）。
--- @param cmd string|nil
--- @return string|nil
local function _command_secret_kind(cmd)
  local bin = _command_bin(cmd)
  if not bin then return nil end
  if LIST_ONLY_CMDS[bin] then return nil end
  if READ_CMDS[bin] then return "read" end
  if USE_CMDS[bin] then return "use" end
  return nil
end

--- 从工具参数收集疑似密钥文件路径（路径型参数 + 读取/使用型命令中出现的路径）。
--- 仅列出/查看类工具与命令（ls/find/list_files…）不构成读取或使用，路径不计入。
--- @param args table|nil
--- @param tool_name string|nil
--- @return table 去重后的路径数组
local function _secret_paths(args, tool_name)
  local seen, out = {}, {}
  local function add(p)
    if type(p) ~= "string" then return end
    p = p:gsub("^%s+", ""):gsub("%s+$", "")
    if p == "" or seen[p] or not _is_secret_path(p) then return end
    seen[p] = true
    out[#out + 1] = p
  end
  if type(args) ~= "table" then return out end
  if LIST_ONLY_TOOLS[tool_name] then return out end
  for k, v in pairs(args) do
    if PATH_KEYS[k] then
      if type(v) == "string" then add(v)
      elseif type(v) == "table" then
        for _, x in ipairs(v) do add(x) end
      end
    elseif k == "command" and type(v) == "string" then
      -- 仅当命令确实读取/使用密钥（非 ls/find 等仅列出）时，命令中的密钥路径才计入。
      if _command_secret_kind(v) ~= nil then
        for tok in v:gmatch("[%w%._/%+%-~%$%{%}]+") do add(tok) end
      end
    end
  end
  return out
end

--- 收集敏感环境变量名。
--- @param values table
--- @return table
local function _secret_names(values)
  local ok, secret = pcall(require, "NeoAI.sandbox.secret")
  if not ok or type(secret) ~= "table" or not secret.scan_names then return {} end
  local seen, out = {}, {}
  for _, v in ipairs(values or {}) do
    local ok2, names = pcall(secret.scan_names, v)
    if ok2 then
      for _, n in ipairs(names or {}) do
        if not seen[n] then seen[n] = true; out[#out + 1] = n end
      end
    end
  end
  return out
end

--- 构造密钥警告行，**明确区分「获取」与「使用」**：
---   * 获取：工具结果 / 内核观测到的密钥文件读取命中密钥内容；
---   * 使用：工具参数（命令/写入内容）携带密钥值、token 或敏感环境变量名，或使用型命令引用密钥文件。
--- 仅列出密钥文件（ls/find/list_files 等）不构成读取/使用，不产生告警。
--- 明细回退顺序：观测到的密钥文件 → 参数中的密钥文件 → 密钥类型（具名规则）→ 敏感环境变量名 → 通用提示。
--- @param fn table tool_call["function"]
--- @param result_msg table|nil
--- @return string|nil
local function _secret_warning_line(fn, result_msg)
  if not fn then return nil end
  local ok, secret = pcall(require, "NeoAI.sandbox.secret")
  if not ok or type(secret) ~= "table" then return nil end
  if secret.enabled and not secret.enabled() then return nil end

  local args_str = fn.arguments
  local result_content = result_msg and result_msg.content or nil
  -- 失败结果（如沙箱密钥硬拦截返回的 `SANDBOX_SECRET_BLOCKED` 错误对象）不是「读取到的
  -- 内容」，不参与密钥判定；否则错误文案里的内部标识会被当成敏感环境变量名，渲染出
  -- 「密钥环境变量：SANDBOX_SECRET_BLOCKED」这类无意义告警。
  local result_failed = false
  if type(result_content) == "string" and result_content ~= "" then
    local dec = json.decode_or_nil(result_content)
    if type(dec) == "table" and dec.error ~= nil then result_failed = true end
  end
  local args = nil
  if type(args_str) == "string" and args_str ~= "" then
    local dec = json.decode_or_nil(args_str)
    if type(dec) == "table" then args = dec end
  end

  -- 内核观测（eBPF/strace/procfs）到实际访问的密钥文件：真实「获取」行为，优先以此为准。
  -- 仅保留**真正的凭据文件**（严口径）：`/etc/ld.so.cache`、`/etc/passwd`、`go.env`、历史文件等
  -- 被普通命令频繁打开，不是密钥，不应触发告警。
  local observed = {}
  if type(result_msg and result_msg.secret_paths) == "table" then
    local seen = {}
    for _, p in ipairs(result_msg.secret_paths) do
      if type(p) == "string" and p ~= "" and _is_secret_path(p) and not seen[p] then
        seen[p] = true
        observed[#observed + 1] = p
      end
    end
  end

  local names_args = _secret_names({ args })
  local names_result = result_failed and {} or _secret_names({ result_content })
  local info_args = _secret_info(args_str)
  local info_result = result_failed and { has = false, rules = {} } or _secret_info(result_content)
  local paths = _secret_paths(args, fn.name)
  local cmd_kind = args and type(args.command) == "string" and _command_secret_kind(args.command) or nil

  -- 获取：内核观测到密钥文件读取，或结果（模型上下文）含密钥值/token/具名规则命中的凭据。
  -- 结果中**仅出现敏感环境变量名**（如 read_file 读到 `DASHSCOPE_API_KEY`）不算「获取密钥」——
  -- 变量名只是引用，读取它不代表拿到了密钥内容；只有结果真正含密钥值/token 才告警。
  -- 使用：参数携带密钥值/token/环境变量名，或使用型命令（ssh/scp/curl/gpg…）引用密钥文件。
  -- 仅读取型命令引用密钥路径（如 read_file / cat 无密钥输出）不作为告警触发，避免误报。
  local got = #observed > 0 or info_result.has
  local used = info_args.has or #names_args > 0 or (#paths > 0 and cmd_kind == "use")
  if not (got or used) then return nil end

  local verb = (got and used) and "获取并使用了密钥" or (got and "获取了密钥" or "使用了密钥")
  local parts = { "⚠ 密钥：" .. (fn.name or "工具") }
  if args and type(args.command) == "string" and args.command ~= "" then
    parts[#parts + 1] = " 执行 `" .. stringx.truncate(args.command:gsub("%s+", " "), 80) .. "`"
  end
  parts[#parts + 1] = " " .. verb
  local rule_set = {}
  for r in pairs(info_args.rules) do rule_set[r] = true end
  for r in pairs(info_result.rules) do rule_set[r] = true end
  local rules = {}
  for r in pairs(rule_set) do rules[#rules + 1] = r end
  table.sort(rules)
  local names, name_seen = {}, {}
  for _, src in ipairs({ names_args, names_result }) do
    for _, n in ipairs(src) do
      if not name_seen[n] then name_seen[n] = true; names[#names + 1] = n end
    end
  end
  if #observed > 0 then
    parts[#parts + 1] = "（观测到密钥文件：" .. table.concat(observed, ", ") .. "）"
  elseif #paths > 0 then
    parts[#parts + 1] = "（密钥文件：" .. table.concat(paths, ", ") .. "）"
  elseif #rules > 0 then
    parts[#parts + 1] = "（密钥类型：" .. table.concat(rules, ", ") .. "）"
  elseif #names > 0 then
    parts[#parts + 1] = "（密钥环境变量：" .. table.concat(names, ", ") .. "）"
  else
    parts[#parts + 1] = "（模型上下文含密钥）"
  end
  return table.concat(parts)
end

--- 返回一行文本内的密钥高亮区间（0-based 字节列，左闭右开）。
--- 同时覆盖具名规则命中的原始密钥（`secret.detect_named`）与沙箱 token（`NEOKEY_*`）。
--- 仅走具名规则快路径（不做熵检测）：`has_secret` 判定本就不采信无规则的熵命中，
--- 而逐行熵检测会让含密钥的大结果渲染卡顿。
--- @param text string
--- @return table 区间数组 { { start, stop, group } }
local function _secret_spans(text)
  local out = {}
  if type(text) ~= "string" or text == "" then return out end
  local ok, secret = pcall(require, "NeoAI.sandbox.secret")
  if not ok or type(secret) ~= "table" then return out end
  if secret.enabled and not secret.enabled() then return out end
  if secret.detect_named then
    local ok2, hits = pcall(secret.detect_named, text)
    if ok2 and type(hits) == "table" then
      for _, hit in ipairs(hits) do
        if hit.start and hit.stop then
          out[#out + 1] = { hit.start - 1, hit.stop, SECRET_HL_GROUP }
        end
      end
    end
  end
  -- token 不参与具名规则（is_candidate 主动排除 NEOKEY_ 前缀），单独按位置补齐。
  for s, e in text:gmatch("()NEOKEY_%x+()") do
    out[#out + 1] = { s - 1, e - 1, SECRET_HL_GROUP }
  end
  return out
end

--- 一次扫描整块文本，把命中的密钥区间按行分配（避免逐行调用 detect 的 O(行数×规则) 开销）。
--- 跨行规则（如私钥块）也能整体命中，命中归属其起始行。
--- @param rows table 行数组（字符串或 { text, spans } 行对象）
--- @param enabled boolean
--- @return table rows（命中行被替换为携带 secret_spans 的行对象）
local function _with_secret_spans_bulk(rows, enabled)
  if not enabled or not rows or #rows == 0 then return rows end
  local texts, offsets = {}, {}
  local pos = 0
  for i = 1, #rows do
    local text = type(rows[i]) == "table" and rows[i].text or rows[i]
    text = text or ""
    texts[i] = text
    offsets[i] = pos
    pos = pos + #text + 1 -- +1 为连接用的 "\n"
  end
  local joined = table.concat(texts, "\n")
  local hits = {}
  local ok, secret = pcall(require, "NeoAI.sandbox.secret")
  if ok and type(secret) == "table" and not (secret.enabled and not secret.enabled()) then
    if secret.detect_named then
      local ok2, dh = pcall(secret.detect_named, joined)
      if ok2 and type(dh) == "table" then
        for _, h in ipairs(dh) do
          if h.start and h.stop then hits[#hits + 1] = { start = h.start, stop = h.stop } end
        end
      end
    end
    for s, e in joined:gmatch("()NEOKEY_%x+()") do
      hits[#hits + 1] = { start = s, stop = e - 1 }
    end
  end
  if #hits == 0 then return rows end
  table.sort(hits, function(a, b) return a.start < b.start end)
  local idx = 1
  for i = 1, #rows do
    local row_start = offsets[i] + 1 -- 1-based
    local row_end = offsets[i] + #texts[i]
    -- 命中只归属其起始行：跳过已在前面行分配过的命中（含跨行规则的续行）。
    while idx <= #hits and hits[idx].start < row_start do idx = idx + 1 end
    local j = idx
    local spans = nil
    while j <= #hits and hits[j].start <= row_end do
      local h = hits[j]
      local s = h.start - row_start
      local e = math.min(h.stop - row_start + 1, #texts[i]) -- 跨行命中截断到本行行尾
      if s < 0 then s = 0 end
      if e > s then
        spans = spans or {}
        spans[#spans + 1] = { s, e, SECRET_HL_GROUP }
      end
      j = j + 1
    end
    if spans then
      local row = rows[i]
      if type(row) == "table" then
        row.secret_spans = spans
      else
        rows[i] = { text = row, secret_spans = spans }
      end
    end
  end
  return rows
end

--- 对 buffer 应用密钥警告高亮。
--- 支持两类标记：`secret`（整行警告行）与 `secret_spans`（行内密钥值区间）。
--- range_from/range_to 语义与 `_apply_table_hl` 一致（增量重贴差异区间）。
--- 注意：即使本次无任何 secret 标记，也要清理区间内的旧高亮，避免内容变化后残留。
--- @param buf number
--- @param marks table|nil
--- @param start_line number|nil
--- @param range_from number|nil
--- @param range_to number|nil
local function _apply_secret_hl(buf, marks, start_line, range_from, range_to)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  start_line = start_line or 1
  local incremental = range_from and range_to and range_to >= range_from
  if incremental then
    pcall(vim.api.nvim_buf_clear_namespace, buf, SECRET_HL_NS, range_from - 1, range_to)
  else
    pcall(vim.api.nvim_buf_clear_namespace, buf, SECRET_HL_NS, 0, -1)
  end
  -- marks 与行并行且存在空洞（无密钥的行标记为 nil），不能用 #marks / ipairs 遍历。
  local mfrom, mto = 1, math.huge
  if incremental then
    mfrom = math.max(1, range_from - start_line + 1)
    mto = range_to - start_line + 1
  end
  local has = false
  for ln, m in pairs(marks or {}) do
    if type(ln) == "number" and m and (m.secret or m.secret_spans) and ln >= mfrom and ln <= mto then
      if not has then
        _ensure_secret_hl()
        has = true
      end
      local row = start_line - 1 + (ln - 1)
      if m.secret then
        _set_line_hl(buf, SECRET_HL_NS, SECRET_HL_GROUP, row)
      end
      for _, sp in ipairs(m.secret_spans or {}) do
        pcall(vim.api.nvim_buf_add_highlight, buf, SECRET_HL_NS, sp[3] or SECRET_HL_GROUP, row, sp[1], sp[2])
      end
    end
  end
end

--- 对 buffer 应用命令输出的 ANSI 颜色高亮（仅处理带 `ansi` 区间的行）。
--- 区间为 0-based 字节列（左闭右开），由 utils.ansi 解析并已含缩进偏移。
--- range_from/range_to 语义与 `_apply_table_hl` 一致（增量重贴差异区间）。
--- @param buf number
--- @param marks table|nil
--- @param start_line number|nil
--- @param range_from number|nil
--- @param range_to number|nil
local function _apply_ansi_hl(buf, marks, start_line, range_from, range_to)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  start_line = start_line or 1
  local incremental = range_from and range_to and range_to >= range_from
  if incremental then
    pcall(vim.api.nvim_buf_clear_namespace, buf, ANSI_HL_NS, range_from - 1, range_to)
  else
    pcall(vim.api.nvim_buf_clear_namespace, buf, ANSI_HL_NS, 0, -1)
  end
  local mfrom, mto = 1, math.huge
  if incremental then
    mfrom = math.max(1, range_from - start_line + 1)
    mto = range_to - start_line + 1
  end
  for ln, m in pairs(marks or {}) do
    if type(ln) == "number" and m and m.ansi and ln >= mfrom and ln <= mto then
      local row = start_line - 1 + (ln - 1)
      for _, sp in ipairs(m.ansi) do
        pcall(vim.api.nvim_buf_add_highlight, buf, ANSI_HL_NS, sp[3], row, sp[1], sp[2])
      end
    end
  end
end

--- 追加一行渲染输出，并记录与该行并行的元数据（marks，供斑马纹高亮）。
--- 注意：marks 与 lines 严格按下标对齐。必须用 lines 的长度做下标——
--- 不能写 `marks[#marks + 1] = mark`：mark 为 nil（角色头/空行）时不会推进长度，
--- 后续非 nil 标记会被挤到靠前的下标，导致高亮错行。
--- @param lines table 文本行数组
--- @param marks table 与 lines 并行的元数据数组（nil 或 { tbl = "border"|"odd"|"even" }）
--- @param text string
--- @param mark table|nil
local function _push(lines, marks, text, mark)
  lines[#lines + 1] = text
  marks[#lines] = mark
end

--- 追加一个可折叠块（推理 / 单个工具块）。所有行缩进 2 格，由聊天窗口的
--- expr 折叠（components.fold.foldexpr）把每块独立成折叠，块与块之间无需分隔行。
--- 空行保留为空白分隔（expr 折叠会把紧邻缩进内容的空行并入折叠）。
--- @param lines table
--- @param rows table 块内文本行（单行纯文本，不含换行）
--- @param kind string|nil 折叠类型（"reasoning"/"tool"），登记到首行元数据供 foldtext 判定
--- @param header_mark table|nil 首行额外元数据（如工具块登记 tool_call_id）
local function _append_fold_block(lines, marks, rows, kind, header_mark)
  if not rows or #rows == 0 then return end
  for idx, row in ipairs(rows) do
    local text, spans, secret_spans
    if type(row) == "table" then
      text, spans, secret_spans = row.text, row.spans, row.secret_spans
    else
      text = row
    end
    text = text or ""
    -- 防御：内容行不得含换行。`nvim_buf_set_lines` 收到含 `\n` 的行会报错并使 buffer
    -- 半写（后续行未写入），表现为折叠被拆成两段。按行拆开；首行保留块元数据，
    -- 其余行作为普通内容行（跨行 span 丢弃，属极少数场景）。
    if text:find("\n", 1, true) then
      for si, sub in ipairs(_split_lines(text)) do
        local m = nil
        if si == 1 and idx == 1 and kind then m = header_mark or { fold_kind = kind } end
        local p = (sub == "") and "" or "  "
        _push(lines, marks, p .. sub, m)
      end
    else
      local mark = nil
      if idx == 1 and kind then
        mark = header_mark or { fold_kind = kind }
      end
      local prefix = (text == "") and "" or "  "
      local off = #prefix
      if spans and #spans > 0 then
        mark = mark or {}
        local adj = {}
        for _, sp in ipairs(spans) do adj[#adj + 1] = { sp[1] + off, sp[2] + off, sp[3] } end
        mark.ansi = adj
      end
      if secret_spans and #secret_spans > 0 then
        mark = mark or {}
        local adj = {}
        for _, sp in ipairs(secret_spans) do adj[#adj + 1] = { sp[1] + off, sp[2] + off, sp[3] } end
        mark.secret_spans = adj
      end
      _push(lines, marks, prefix .. text, mark)
    end
  end
end

--- 把推理块起始行登记到 fold 组件，供 foldtext 区分「思考过程」与其它折叠。
--- @param buf number
--- @param marks table 与 lines 并行的元数据数组
local function _sync_fold_kinds(buf, marks)
  local set = {}
  -- 用 pairs 而非 `#marks`：marks 与 lines 并行但多数元素为 nil（角色头/空行），
  -- `#` 会在首个空洞处截断，漏掉靠后的推理/工具元数据。
  for i, m in pairs(marks or {}) do
    if m and m.fold_kind == "reasoning" then set[i] = true end
  end
  fold.set_reasoning_lines(buf, set)
end

--- 判断消息是否为轮次边界（其后应绘制分割线）。
--- 一轮 = 从用户消息开始，到下一个用户消息（或消息列表末尾）结束。
--- 轮内（推理/工具调用/工具结果与正文之间）一律不画分割线，只保留轮间分割。
--- @param messages table
--- @param i number 当前消息下标
--- @return boolean
local function _is_turn_end(messages, i)
  local msg = messages[i]
  -- 运行时上下文快照不算用户轮次（它是注入历史的易变状态，不产生用户回合）
  if msg.runtime_context then
    return false
  end
  if msg.role == "user" then
    return true -- 用户消息始终后接分割线（与 AI 回复的视觉分隔）
  end
  if msg.role ~= "assistant" then
    return false -- 工具结果不带分割线（与所属 AI 轮保持连续）
  end
  -- assistant：仅当它是本轮的可见最后一条（后面是下一条用户消息或列表末尾）时画分割线
  for j = i + 1, #messages do
    if not messages[j].runtime_context and messages[j].role ~= "system" then
      return messages[j].role == "user"
    end
  end
  return true
end

--- 追加角色头（非工具消息）
--- @param lines table
--- @param marks table 与 lines 并行的元数据数组
--- @param message table
local function _append_role_header(lines, marks, message)
  local label = ROLE_LABELS[message.role] or message.role
  _push(lines, marks, label, nil)
end

--- 追加推理折叠块（缩进 2 格，由聊天窗口 expr 折叠自动收起）
--- @param lines table
--- @param marks table 与 lines 并行的元数据数组
--- @param message table
--- @param opts table|nil 渲染选项（流式表格）
local function _append_reasoning(lines, marks, message, opts)
  local has_reasoning = message.reasoning ~= nil and message.reasoning ~= "" and state.show_reasoning
  if not has_reasoning then return end
  local rl = markdown_view.render(message.reasoning, opts)
  local rows = {}
  for _, l in ipairs(rl) do
    rows[#rows + 1] = l.text
  end
  _append_fold_block(lines, marks, rows, "reasoning")
end

--- 追加正文内容（markdown 渲染）——工具消息除外
--- @param lines table
--- @param marks table 与 lines 并行的元数据数组
--- @param message table
--- @param opts table|nil 渲染选项（流式表格）
local function _append_content(lines, marks, message, opts)
  if message.role == "tool" or not message.content or message.content == "" then return end
  local rendered = markdown_view.render(message.content, opts)
  for _, l in ipairs(rendered) do
    if l.text ~= "" then
      -- 去掉行首空白：正文（含 Markdown 代码/缩进段落）不应因缩进被误判为推理或工具折叠块。
      -- 只有推理/工具块由 _append_fold_block 统一添加缩进，才是 ex 折叠的目标；正文顶格不折叠。
      local mark = l.tbl and { tbl = l.tbl } or nil
      _push(lines, marks, l.text:gsub("^%s+", ""), mark)
    end
  end
end

--- 工具结果是否为失败（错误 JSON 对象含 error 字段）
--- 工具结果可能是任意 JSON（布尔/字符串/数字/数组），只有对象含 error 字段才算失败，
--- 非对象（如 is_named_node 返回的 true/false）一律视为成功。
--- @param content string|nil
--- @return boolean
local function _tool_result_failed(content)
  if not content or content == "" then return false end
  local json = require("NeoAI.utils.json")
  local decoded = json.decode_or_nil(content)
  if type(decoded) ~= "table" then return false end
  return decoded.error ~= nil
end

--- 提取工具调用的目的说明（description 参数）
--- @param fn table tool_call["function"]
--- @return string|nil
local function _tool_description(fn)
  if not fn or type(fn.arguments) ~= "string" or fn.arguments == "" then return nil end
  local json = require("NeoAI.utils.json")
  local decoded = json.decode_or_nil(fn.arguments)
  if type(decoded) ~= "table" then return nil end
  local desc = decoded.description
  if type(desc) ~= "string" or desc == "" then return nil end
  -- 折叠文本单行展示：折行/换行压缩为空格
  desc = desc:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if desc == "" then return nil end
  return desc
end

--- 递归将 JSON 值格式化为带缩进的多行文本（数组/对象均结构化展示）。
--- @param value any
--- @param indent number
--- @return string
local function _pretty_json(value, indent)
  indent = indent or 0
  local pad = string.rep("  ", indent)
  if type(value) ~= "table" then
    return json.encode(value)
  end
  if not next(value) then return "{}" end
  -- 数组判断：键为 1..n 的连续整数序列（#value > 0 才可能是数组，避免把字符串键对象误判）
  local is_array = #value > 0
  if is_array then
    for i = 1, #value do
      if value[i] == nil then is_array = false break end
    end
  end
  if is_array then
    local parts = {}
    for i = 1, #value do
      parts[i] = pad .. "  " .. _pretty_json(value[i], indent + 1)
    end
    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "]"
  end
  local parts = {}
  local n = 0
  for k, v in pairs(value) do
    n = n + 1
    parts[n] = pad .. "  " .. json.encode(k) .. ": " .. _pretty_json(v, indent + 1)
  end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
end

--- 工具调用参数的结构化展示行（解析 JSON，剔除 description 样板字段后缩进展示）。
--- @param fn table tool_call["function"]
--- @param opts table|nil { full?: boolean } full=true 时不截断（含密钥的工具调用完整展示）
--- @return table|nil 行数组（无参数时 nil）
local function _tool_arguments_lines(fn, opts)
  if not fn or type(fn.arguments) ~= "string" or fn.arguments == "" then return nil end
  local decoded = json.decode_or_nil(fn.arguments)
  -- JSON 解析失败（流式未完成 / 非法）：原样展示，但必须按行拆开——参数里可能含真实换行，
  -- 单行含 `\n` 传给 `nvim_buf_set_lines` 会报错并使 buffer 半写、折叠被拆断。
  if decoded == nil then return _split_lines(fn.arguments) end
  if type(decoded) == "table" then
    local filtered = {}
    for k, v in pairs(decoded) do
      if k ~= "description" then filtered[k] = v end
    end
    if not next(filtered) then return nil end
    local pretty = _pretty_json(filtered)
    if not (opts and opts.full) then pretty = stringx.truncate(pretty, 500) end
    return _split_lines(pretty)
  end
  return { json.encode(decoded) }
end

--- 把纯文本按行包装为带 ANSI 高亮区间的行对象数组。
--- @param text string
--- @return table
local function _styled_lines(text)
  local out = {}
  for _, l in ipairs(ansi.parse(text)) do out[#out + 1] = l end
  return out
end

--- 工具结果的结构化展示行（JSON 内容解析后多行缩进展示，非 JSON 原样截断展示）。
--- 结果含 read_image 的图像引用时先行渲染一条图像摘要行。
--- 返回行对象数组 { text, spans }（spans 为 ANSI 高亮区间，非 ANSI 内容为空）。
--- @param content string|nil
--- @param opts table|nil { full?: boolean } full=true 时不截断（含密钥的工具调用完整展示）
--- @return table 行对象数组
local function _result_lines(content, opts)
  if not content or content == "" then return { { text = "(空)", spans = {} } } end
  local full = opts and opts.full
  local decoded = json.decode_or_nil(content)
  if type(decoded) == "table" then
    local img = decoded.image
    if type(img) == "table" and img.attachmentId then
      local dims = img.width and img.height and (string.format(" %dx%dpx", img.width, img.height)) or ""
      local lines = {
        { text = string.format("🖼️ 图像%s（%s, %d 字节）", dims, img.mediaType or img.media_type or "image", img.bytes or 0), spans = {} },
      }
      local pretty = _pretty_json(decoded)
      if not full then pretty = stringx.truncate(pretty, 500) end
      for _, l in ipairs(_split_lines(pretty)) do
        lines[#lines + 1] = { text = l, spans = {} }
      end
      return lines
    end
    local out = {}
    local pretty = _pretty_json(decoded)
    if not full then pretty = stringx.truncate(pretty, 500) end
    for _, l in ipairs(_split_lines(pretty)) do
      out[#out + 1] = { text = l, spans = {} }
    end
    return out
  end
  if full then return _styled_lines(content) end
  return _styled_lines(stringx.truncate(content, 500))
end

--- 追加单个工具块（调用 + 结果合并成一个折叠块）。
--- 块首行即状态标记：执行中显示 ⏳（无结果），结果到达后更新为 ✅（成功）或 ❌（失败），
--- 折叠文本（foldtext）按首行 emoji 自动切换图标。结果未到达时只显示首行（仍可折叠）。
--- 首行在工具名后展示目的说明（" · 修改配置"），随后追加耗时（" · 1.2s"）：
--- 执行中显示已执行时长，完成后显示总时长（由 fold 计时提供）。
--- @param lines table
--- @param marks table 与 lines 并行的元数据数组
--- @param tool_call table
--- @param result_msg table|nil 对应的工具结果消息
--- 工具块首行文本（不含缩进）：状态 emoji + 工具名 + 目的 + 耗时。
--- 供整块构建与「执行中耗时」轻量刷新共用（避免为更新时间重建整块）。
--- @param tool_call table
--- @param result_msg table|nil
--- @return string|nil
local function _tool_header_text(tool_call, result_msg)
  local fn = tool_call and tool_call["function"]
  if not fn then return nil end
  local name = fn.name or ""
  local desc = _tool_description(fn)
  local desc_str = desc and (" · " .. desc) or ""
  -- 已完成工具优先用结果消息里持久化的总时长；执行中/无持久化时回退 fold 计时
  local duration = (result_msg and result_msg.duration_ms) or fold.get_duration(tool_call.id)
  local time_str = duration and (" · " .. fold.format_ms(duration)) or ""
  if result_msg then
    local failed = _tool_result_failed(result_msg.content)
    return string.format("%s 工具: %s%s%s", failed and "❌" or "✅", name, desc_str, time_str)
  end
  -- 结果消息未到达时按各自执行状态渲染（fold 计时记录了每个工具的开始/结束状态）：
  -- 已完成的工具立即显示 ✅/❌ 并锁定总耗时，仍在执行的显示 ⏳ + 实时耗时。
  local status = fold.get_status(tool_call.id)
  if status == "success" then
    return string.format("✅ 工具: %s%s%s", name, desc_str, time_str)
  elseif status == "failure" then
    return string.format("❌ 工具: %s%s%s", name, desc_str, time_str)
  end
  return string.format("⏳ 调用工具: %s%s%s", name, desc_str, time_str)
end

local function _append_tool_block(lines, marks, tool_call, result_msg)
  local fn = tool_call["function"]
  -- 密钥防护：命令参数或结果（模型上下文）含密钥时，在该工具折叠块**外**单独追加
  -- 一行高亮警告（非缩进 → 不并入折叠），折叠标题保持干净。
  -- 警告行指明「哪个命令/工具获取或使用了哪个密钥文件」（见 _secret_warning_line）。
  local secret_line = _secret_warning_line(fn, result_msg)
  -- 含密钥的工具调用：完整展示参数/结果（不截断），并在行内高亮密钥值。
  local has_secret = secret_line ~= nil
  local rows = {}
  local header_text = _tool_header_text(tool_call, result_msg)
  if header_text then rows[#rows + 1] = header_text end
  -- 结构化调用参数：无论工具最终成功/失败，展开折叠都能看到本次调用传了哪些参数
  local arg_lines = _tool_arguments_lines(fn, { full = has_secret })
  if arg_lines then
    rows[#rows + 1] = "参数:"
    for _, l in ipairs(arg_lines) do
      rows[#rows + 1] = l
    end
  end
  -- 结构化执行结果：成功/失败都有对应的结果内容（失败时通常为 error 对象）
  if result_msg then
    rows[#rows + 1] = "结果:"
    for _, l in ipairs(_result_lines(result_msg.content, { full = has_secret })) do
      rows[#rows + 1] = l
    end
  end
  -- 含密钥：整块一次性扫描并分配行内高亮（避免逐行检测拖慢大结果）
  if has_secret then _with_secret_spans_bulk(rows, true) end
  -- 首行登记工具调用 id：供「执行中耗时」轻量刷新与 foldtext 实时耗时读取，
  -- 避免每秒为更新时间重建整块（大消息时占主线程）与折叠闪烁。
  _append_fold_block(lines, marks, rows, "tool",
    { fold_kind = "tool", tool_header = { id = tool_call.id, tc = tool_call, res = result_msg } })
  -- 密钥警告：折叠块外单独一行（非缩进 → 不并入折叠），施加高亮。
  if secret_line then
    _push(lines, marks, secret_line, { secret = true })
  end
  -- 工具结果 UI 附加提示（如沙箱降级）：仅用户可见，不进入模型上下文；折叠块外单独一行。
  if result_msg and result_msg.notice and result_msg.notice ~= "" then
    for _, l in ipairs(vim.split(tostring(result_msg.notice), "\n", { plain = true })) do
      _push(lines, marks, l, { notice = true })
    end
  end
end

--- 追加轮次分割线（仅在轮次边界出现）
--- @param lines table
--- @param marks table 与 lines 并行的元数据数组
local function _append_turn_sep(lines, marks)
  _push(lines, marks, "", nil)
  _push(lines, marks, "────────────────────", nil)
  _push(lines, marks, "", nil)
end

--- 格式化一条不含工具调用/结果的消息为文本行数组
--- @param lines table 填充目标（文本行）
--- @param marks table 填充目标（与 lines 并行的元数据数组）
--- @param message table
--- @param is_turn_end boolean
--- @param opts table|nil 渲染选项（流式表格）
local function _format_message(lines, marks, message, is_turn_end, opts)
  _append_role_header(lines, marks, message)
  _append_reasoning(lines, marks, message, opts)
  _append_content(lines, marks, message, opts)
  if is_turn_end then
    _append_turn_sep(lines, marks)
  end
end

-- ========== 公开 API ==========

--- 渲染消息列表到 buffer（按当前激活的显示模式插件分派）
--- 未激活任何显示模式插件时回退到默认对话渲染（render_chat）。
--- 工具调用与其结果按「每个工具一个折叠块」分组：assistant 消息里的每个
--- tool_call 与紧随其后的 tool 结果消息配对渲染进同一个折叠块。
--- @param buf number
--- @param messages table 数组
--- @param opts table|nil { streaming? boolean } 流式生成中时不对表格填充
--- @return table|nil 增量写入结果 { changed, start, removed, inserted, full }
function M.render(buf, messages, opts)
  local diff
  local plugin = display_modes.get_current()
  if plugin and plugin.render then
    diff = plugin.render(buf, messages, opts)
  else
    diff = M.render_chat(buf, messages, opts)
  end
  -- 聊天消息 buffer 是纯 UI 暂存（非用户文件）：清除 modified，避免 :q/退出时
  -- 触发 E37/E162 "No write since last change"（尤其 acwrite 命名的聊天 buffer）。
  if vim.api.nvim_buf_is_valid(buf) then
    vim.bo[buf].modified = false
  end
  return diff
end

--- 文本指纹（见 incremental.fingerprint）
--- @param s string|nil
--- @return string
local function _fingerprint(s)
  return incremental.fingerprint(s)
end

--- 按「流式末尾消息 / 表格宽度」生成单条消息的渲染选项
--- @param is_stream boolean
--- @param opts table|nil
--- @return table|nil
local function _msg_opts(is_stream, opts)
  local tw = opts and opts.table_width
  if not is_stream and not tw then return nil end
  local o = {}
  if is_stream then o.streaming = true end
  if tw then o.table_width = tw end
  return o
end

--- 拼接块渲染签名（任何影响渲染结果的输入都必须纳入，否则会命中陈旧缓存）
--- @param opts table|nil
--- @param turn_end boolean
--- @param extra table|nil
--- @return string
local function _sig(opts, turn_end, extra)
  local p = {
    state.show_reasoning and "R" or "-",
    (opts and opts.streaming) and "S" or "-",
    (opts and opts.table_width) or "-",
    turn_end and "T" or "-",
  }
  for _, e in ipairs(extra or {}) do
    p[#p + 1] = e
  end
  return table.concat(p, "\1")
end

--- 把消息序列切分为可缓存的渲染块。每个块 = 一条消息；带工具调用的 assistant
--- 消息与其配对的工具结果消息合并为一个块（工具结果消息不再单独成块）。
--- 运行时上下文快照与 system 消息不渲染（不产生块）。
--- @param msgs table
--- @param opts table|nil
--- @return table 块数组 { { key, sig, build } }
local function _blocks(msgs, opts)
  local blocks = {}
  local i = 1
  while i <= #msgs do
    local idx = i
    local msg = msgs[idx]
    if msg.runtime_context then
      i = i + 1
    elseif msg.role == "system" then
      i = i + 1
    elseif msg.role == "assistant" and msg.tool_calls and #msg.tool_calls > 0 then
      -- 工具结果消息按调用顺序紧随其后；仅在当前位置确实是工具结果时才推进
      -- （否则工具未返回结果时会把下一条非工具消息当作结果位置消费掉）。
      local snap = msg
      local paired = {}
      local ridx = idx + 1
      for _, tc in ipairs(snap.tool_calls) do
        local res = nil
        if msgs[ridx] and msgs[ridx].role == "tool" then
          res = msgs[ridx]
          ridx = ridx + 1
        end
        paired[#paired + 1] = { tc = tc, res = res }
      end
      local consumed_until = ridx - 1
      local turn_end = _is_turn_end(msgs, idx)
      local extra = { "assistant", _fingerprint(snap.content), _fingerprint(snap.reasoning) }
      for _, pp in ipairs(paired) do
        local fn = pp.tc["function"] or {}
        extra[#extra + 1] = "tc"
        extra[#extra + 1] = tostring(pp.tc.id)
        extra[#extra + 1] = tostring(fn.name)
        extra[#extra + 1] = _fingerprint(fn.arguments)
        extra[#extra + 1] = tostring(fold.get_status(pp.tc.id))
        -- 实时耗时不计入签名：执行中每秒变化会命中缓存失效→重建整块（大消息时占主线程）。
        -- 时间由 `refresh_tool_times` 就地改写首行；状态变化（running→success）仍触发重建。
        extra[#extra + 1] = pp.res and "res" or "nil"
        if pp.res then
          extra[#extra + 1] = _fingerprint(pp.res.content)
          extra[#extra + 1] = tostring(pp.res.duration_ms)
        end
      end
      local is_stream = opts and opts.streaming and idx == #msgs
      local eopts = _msg_opts(is_stream, opts)
      local sig = _sig(eopts, turn_end, extra)
      blocks[#blocks + 1] = {
        key = "c:" .. idx,
        sig = sig,
        build = function()
          local lines, marks = {}, {}
          _append_role_header(lines, marks, snap)
          _append_reasoning(lines, marks, snap, eopts)
          _append_content(lines, marks, snap, eopts)
          for _, pp in ipairs(paired) do
            _append_tool_block(lines, marks, pp.tc, pp.res)
          end
          if turn_end then
            _append_turn_sep(lines, marks)
          end
          return { lines = lines, marks = marks }
        end,
      }
      i = consumed_until + 1
    else
      local snap = msg
      local turn_end = _is_turn_end(msgs, idx)
      local is_stream = opts and opts.streaming and idx == #msgs
      local eopts = _msg_opts(is_stream, opts)
      local sig = _sig(eopts, turn_end, { snap.role or "", _fingerprint(snap.content), _fingerprint(snap.reasoning) })
      blocks[#blocks + 1] = {
        key = "c:" .. idx,
        sig = sig,
        build = function()
          local lines, marks = {}, {}
          _format_message(lines, marks, snap, turn_end, eopts)
          return { lines = lines, marks = marks }
        end,
      }
      i = i + 1
    end
  end
  return blocks
end

--- 是否开启增量刷新（ui.chat.incremental，默认 true）
--- @return boolean
local function _incremental_enabled()
  return config_store.get("ui.chat.incremental") ~= false
end

--- 降级路径：整 buffer 全量重写（ui.chat.incremental = false 时使用）
--- @param buf number
--- @param msgs table
--- @param opts table|nil
--- @return table
local function _render_chat_full(buf, msgs, opts)
  local lines, marks = {}, {}
  for _, b in ipairs(_blocks(msgs, opts)) do
    local built = b.build() or {}
    local bl = built.lines or {}
    local bm = built.marks or {}
    for i = 1, #bl do
      lines[#lines + 1] = bl[i]
      marks[#lines] = bm[i]
    end
  end
  if #lines == 0 then
    lines = { "NeoAI 聊天", "", "输入消息开始对话。", "" }
    marks = { nil, nil, nil, nil }
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  _apply_table_hl(buf, marks)
  _apply_secret_hl(buf, marks)
  _apply_ansi_hl(buf, marks)
  _sync_fold_kinds(buf, marks)
  -- 已直接重写全书：块缓存与内容镜像过期
  incremental.invalidate(buf)
  return { changed = true, start = 1, removed = -1, inserted = #lines, full = true }
end

--- 就地刷新执行中工具块首行的耗时（不重建整块）。
--- 工具耗时每秒变化，若计入块签名会导致整块缓存失效并重建（大消息时占主线程、且 buffer
--- 重写引发折叠闪烁）；改为仅改写首行文本，块其余内容复用缓存。
--- @param lines table 行数组（BlockCache 的 new_lines）
--- @param marks table 与 lines 并行的元数据
--- @return boolean changed
function M.refresh_tool_times(lines, marks)
  local changed = false
  -- 以 lines 长度为准遍历：marks 与 lines 并行但多数元素为 nil，`#marks` 会在首个
  -- nil 处截断（角色头/空行），导致工具首行元数据被跳过。
  for i = 1, #(lines or {}) do
    local th = marks[i] and marks[i].tool_header
    -- 仅刷新「尚无结果消息且未结束」的工具：有结果/已结束的首行由整块构建锁定状态与总耗时。
    if th and th.tc and not th.res then
      local status = fold.get_status(th.id)
      if status ~= "success" and status ~= "failure" then
        local text = _tool_header_text(th.tc, nil)
        if text then
          local newline = "  " .. text
          if lines[i] ~= newline then
            lines[i] = newline
            changed = true
          end
        end
      end
    end
  end
  return changed
end

--- 渲染消息列表到 buffer（默认对话模式，增量：块缓存 + 差分写入）
--- @param buf number
--- @param messages table 数组
--- @param opts table|nil { streaming? boolean; table_width? number }
---   streaming 流式生成中时不对表格填充；table_width 限制表格总显示宽度（随窗口自适应）
--- @return table 增量写入结果 { changed, start, removed, inserted, full }
function M.render_chat(buf, messages, opts)
  local msgs = messages or {}
  if not _incremental_enabled() then
    return _render_chat_full(buf, msgs, opts)
  end
  local cache = _cache_for(buf)
  local lines, marks = cache:render(_blocks(msgs, opts))
  if #lines == 0 then
    -- 空对话占位（与旧行为一致）
    lines = { "NeoAI 聊天", "", "输入消息开始对话。", "" }
    marks = { nil, nil, nil, nil }
  end
  -- 执行中工具的首行耗时就地刷新（块缓存命中时也能更新，且不重建整块）。
  M.refresh_tool_times(lines, marks)
  cache.new_lines = lines
  cache.new_marks = marks
  local diff = cache:write(buf)
  if diff.changed then
    local from, to = incremental.written_range(diff)
    _apply_table_hl(buf, marks, 1, diff.full and nil or from, diff.full and nil or to)
    _apply_secret_hl(buf, marks, 1, diff.full and nil or from, diff.full and nil or to)
    _apply_ansi_hl(buf, marks, 1, diff.full and nil or from, diff.full and nil or to)
    _sync_fold_kinds(buf, marks)
  end
  return diff
end

--- 使指定 buffer 的块缓存失效（下次渲染走全量替换）
--- 会话切换 / 上下文压缩重排 / 显示模式切换 / 表格宽度变化时调用。
--- @param buf number|nil
function M.invalidate(buf)
  incremental.invalidate(buf)
end

--- 追加消息到 buffer（增量渲染）
--- @param buf number
--- @param message table
function M.append(buf, message)
  local lines = {}
  local marks = {}
  _format_message(lines, marks, message, true)
  local line_count = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_buf_set_lines(buf, line_count - 1, -1, false, lines)
  _apply_table_hl(buf, marks, line_count)
  _apply_secret_hl(buf, marks, line_count, line_count, line_count + #lines - 1)
  _apply_ansi_hl(buf, marks, line_count, line_count, line_count + #lines - 1)
  -- 直接写入后块缓存的内容镜像过期：置无效，下次渲染走全量替换。
  M.invalidate(buf)
end

--- 切换推理显示
--- @return boolean 新状态
function M.toggle_reasoning()
  state.show_reasoning = not state.show_reasoning
  return state.show_reasoning
end

--- 当前是否显示推理（显示模式插件渲染时读取）
--- @return boolean
function M.is_show_reasoning()
  return state.show_reasoning
end

--- 设置推理显示
--- @param show boolean
function M.set_show_reasoning(show)
  state.show_reasoning = show
end

-- ========== 显示模式插件共享工具 ==========

--- 供显示模式插件复用的渲染工具
--- @type table
M.helpers = {
  append_tool_block = _append_tool_block,
  apply_table_hl = _apply_table_hl,
  pretty_json = _pretty_json,
  split_lines = _split_lines,
  truncate = function(s, n) return stringx.truncate(s, n) end,
  tool_arguments_lines = _tool_arguments_lines,
  result_lines = function(content, opts)
    local out = {}
    for _, l in ipairs(_result_lines(content, opts)) do
      out[#out + 1] = type(l) == "table" and l.text or l
    end
    return out
  end,
  tool_result_failed = _tool_result_failed,
  contains_secret = _contains_secret,
  secret_warning_line = _secret_warning_line,
  secret_spans = _secret_spans,
  attach_secret_spans = _with_secret_spans_bulk,
  apply_secret_hl = _apply_secret_hl,
}

--- 重置（测试用）
function M.reset()
  state.show_reasoning = true
  incremental.reset()
end

return M
