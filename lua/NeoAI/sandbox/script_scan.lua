--- 脚本间接执行的静态扫描
--- @module NeoAI.sandbox.script_scan
--- 命令把执行委托给脚本/解释器时（`bash deploy.sh`、`python setup.py`、`node x.js`、
--- `./run.sh`、`bash -c '…'`、`python -c '…'`），命令字符串本身看不到真正的危险操作。
--- 本模块在**执行前**读取被引用脚本的内容（优先读沙箱暂存副本，使 AI 新建/修改的脚本
--- 也能被扫描），提取：
---   * Shell 脚本正文（去注释）；
---   * 高级语言（Python/Node/Ruby/Perl/PHP）中调用 shell 的字符串字面量
---     （`os.system` / `subprocess.*` / `child_process.exec` / 反引号 / `%x{}` 等）；
---   * 递归引用的脚本（限深度/文件数/字节数，检测环）。
--- 结果折叠为一段 `effective` 文本，供 `risk.deny_reason`（硬拒绝）、
--- `privilege.classify`（权限档/包识别）与 `risk.classify`（安全级别）复用，
--- 使脚本内的破坏性命令、包安装、系统写入等不再被漏判。
---
--- 无法静态解析的间接执行（`eval`、`base64 -d | sh`、`python -m`、`-c "$VAR"`、
--- 读不到脚本内容等）标记为 `opaque`：调用方据此**提升级别并强制人工复核**，
--- 绝不自动应用。本模块只做静态分析，不做运行时追踪（见 docs/sandbox.md）。

local config_store = require("NeoAI.kernel.config_store")
local fs = require("NeoAI.utils.fs")

local M = {}

-- ========== 解释器/语言表 ==========

local SHELL = {
  sh = true, bash = true, dash = true, zsh = true, ksh = true, ksh93 = true,
  mksh = true, ash = true, busybox = true, fish = true,
}
local PYTHON = { python = true, python2 = true, python3 = true, pypy = true, pypy3 = true }
local NODE = { node = true, nodejs = true, bun = true, deno = true, qjs = true, tsx = true }
local RUBY = { ruby = true, jruby = true }
local PERL = { perl = true }
local PHP = { php = true, php8 = true, php7 = true }

--- 取解释器对应的语言名（未命中返回 nil）
--- @param base string
--- @return string|nil
local function _lang_of(base)
  if SHELL[base] then return "shell" end
  if PYTHON[base] then return "python" end
  if NODE[base] then return "node" end
  if RUBY[base] then return "ruby" end
  if PERL[base] then return "perl" end
  if PHP[base] then return "php" end
  return nil
end

-- `-c` / `-e` 等直接携带代码的选项（其后一个 token 即代码）
local CODE_FLAGS = {
  shell = { ["-c"] = true },
  python = { ["-c"] = true },
  node = { ["-e"] = true, ["--eval"] = true, ["-p"] = true, ["--print"] = true },
  ruby = { ["-e"] = true },
  perl = { ["-e"] = true, ["-E"] = true },
  php = { ["-r"] = true },
}

-- 取独立取值的选项（其后一个 token 是值而非脚本路径）
local VALUE_OPTS = {
  shell = { ["-o"] = true, ["-O"] = true, ["--rcfile"] = true, ["--init-file"] = true },
  python = { ["-X"] = true, ["-W"] = true, ["-Q"] = true, ["-M"] = true },
  node = { ["-r"] = true, ["--require"] = true, ["--loader"] = true, ["--experimental-loader"] = true },
  ruby = { ["-I"] = true, ["-r"] = true, ["-C"] = true, ["-E"] = true, ["-K"] = true, ["-T"] = true },
  perl = { ["-I"] = true, ["-M"] = true, ["-m"] = true },
  php = { ["-d"] = true, ["-c"] = true, ["-z"] = true },
}

-- 模块加载选项：内容不可静态解析 → 不透明
local MODULE_FLAGS = { python = { ["-m"] = true, ["--module"] = true } }

-- 各语言中会调用 shell 的 API（Lua pattern）。命中后提取同段内的字符串字面量。
local LANG_APIS = {
  python = {
    "os%.system%s*%(", "os%.popen%s*%(", "os%.spawn%w*%s*%(",
    "subprocess%.%w+%s*%(", "commands%.%w+%s*%(", "pty%.spawn%s*%(",
    "os%.exec%w*%s*%(", "shutil%.which%s*%(",
  },
  node = {
    "child_process%.exec", "child_process%.execSync", "child_process%.spawn",
    "child_process%.spawnSync", "child_process%.execFile",
    "%f[%w]execSync%s*%(", "%f[%w]spawnSync%s*%(", "%f[%w]exec%s*%(",
    "require%s*%(%s*['\"]child_process",
  },
  ruby = {
    "system%s*%(", "exec%s*%(", "IO%.popen%s*%(", "Open3%.%w+%s*%(", "%%x[%{%[]",
  },
  perl = {
    "system%s*%(", "exec%s*%(", "qx[%{%(/]",
  },
  php = {
    "shell_exec%s*%(", "%f[%w]exec%s*%(", "system%s*%(", "passthru%s*%(",
    "popen%s*%(", "proc_open%s*%(",
  },
}

-- 动态执行原语：出现即无法静态判定 → 不透明
local DYNAMIC_PATTERNS = {
  python = { "eval%s*%(", "exec%s*%(", "compile%s*%(", "__import__%s*%(" },
  node = { "eval%s*%(", "new%s+Function%s*%(", "%f[%w]Function%s*%(" },
  ruby = { "eval%s*%(", "instance_eval%s*%(" },
  perl = { "eval%s*[%{%(\"']" },
  php = { "eval%s*%(", "create_function%s*%(" },
}

-- ========== 私有函数 ==========

local function _cfg()
  return config_store.get("tools.sandbox.script_scan") or {}
end

--- 模块是否启用
--- @return boolean
function M.enabled()
  return _cfg().enabled ~= false
end

--- 去掉 token 两侧的引号/括号/分号等外壳字符
--- @param tok string
--- @return string
local function _clean(tok)
  return (tostring(tok or ""):gsub("^[%s%'\"`%(%[{]+", ""):gsub("[%s%'\"`%;%)%]}]+$", ""))
end

--- 按空白切分，但保留引号内的空白（返回的 token 含引号）
--- @param s string
--- @return table
local function _tokenize(s)
  local toks = {}
  local i, n = 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c:match("%s") then
      i = i + 1
    else
      local buf = {}
      while i <= n do
        local ch = s:sub(i, i)
        if ch:match("%s") then break end
        if ch == '"' or ch == "'" or ch == "`" then
          local q = ch
          buf[#buf + 1] = ch
          i = i + 1
          while i <= n and s:sub(i, i) ~= q do
            if s:sub(i, i) == "\\" and q ~= "'" then
              buf[#buf + 1] = s:sub(i, i + 1)
              i = i + 2
            else
              buf[#buf + 1] = s:sub(i, i)
              i = i + 1
            end
          end
          if i <= n then
            buf[#buf + 1] = q
            i = i + 1
          end
        else
          buf[#buf + 1] = ch
          i = i + 1
        end
      end
      toks[#toks + 1] = table.concat(buf)
    end
  end
  return toks
end

--- 提取一段文本中的字符串字面量（'…' / "…" / `…`），返回去掉定界符的内容
--- @param s string
--- @return table
local function _extract_strings(s)
  local out = {}
  local i, n = 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c == '"' or c == "'" or c == "`" then
      local q = c
      local buf = {}
      local j = i + 1
      while j <= n do
        local ch = s:sub(j, j)
        if ch == "\\" and q ~= "'" then
          buf[#buf + 1] = s:sub(j, j + 1)
          j = j + 2
        elseif ch == q then
          break
        else
          buf[#buf + 1] = ch
          j = j + 1
        end
      end
      out[#out + 1] = table.concat(buf)
      i = j + 1
    else
      i = i + 1
    end
  end
  return out
end

--- 迭代 API 模式匹配（返回所有命中，包括 `cp.exec(` 这类别名调用）
--- @param text string
--- @param pat string
--- @return function
local function _iter_api(text, pat)
  local init = 1
  return function()
    local s, e = text:find(pat, init)
    if not s then return nil end
    init = e + 1
    return s, e
  end
end

--- 去注释（保留字符串内的 `#`/`//`）；python 额外处理三引号字符串
--- @param text string
--- @param lang string
--- @return string
local function _strip_comments(text, lang)
  local out = {}
  local i, n = 1, #text
  local q = nil       -- 单字符引号状态
  local qt = nil      -- 三引号状态（python）
  local prev = nil    -- 上一个原始字符（shell `#` 注释判定：前导空白/分隔符/行首）
  while i <= n do
    local c = text:sub(i, i)
    local c2, c3 = text:sub(i + 1, i + 1), text:sub(i + 2, i + 2)
    if qt then
      if c == "\\" then
        out[#out + 1] = text:sub(i, i + 1)
        i = i + 2
      elseif c == qt and c2 == qt and c3 == qt then
        out[#out + 1] = qt .. qt .. qt
        qt = nil
        i = i + 3
      else
        out[#out + 1] = c
        i = i + 1
      end
    elseif q then
      out[#out + 1] = c
      if c == "\\" and q ~= "'" then
        out[#out + 1] = c2
        i = i + 2
      elseif c == q then
        q = nil
        i = i + 1
      else
        i = i + 1
      end
    elseif lang == "python" and (c == '"' or c == "'") and c2 == c and c3 == c then
      qt = c
      out[#out + 1] = c .. c .. c
      i = i + 3
    elseif c == '"' or c == "'" or c == "`" then
      q = c
      out[#out + 1] = c
      i = i + 1
    elseif lang == "js" and c == "/" and c2 == "/" then
      while i <= n and text:sub(i, i) ~= "\n" do i = i + 1 end
    elseif lang == "js" and c == "/" and c2 == "*" then
      i = i + 2
      while i <= n and not (text:sub(i, i) == "*" and text:sub(i + 1, i + 1) == "/") do i = i + 1 end
      i = i + 2
    elseif lang == "shell" and c == "#"
      and (prev == nil or prev:match("[%s;|&%(]")) then
      while i <= n and text:sub(i, i) ~= "\n" do i = i + 1 end
    elseif lang ~= "shell" and lang ~= "js" and c == "#" then
      while i <= n and text:sub(i, i) ~= "\n" do i = i + 1 end
    else
      out[#out + 1] = c
      i = i + 1
    end
    prev = c
  end
  return table.concat(out)
end

--- shebang 推断语言
--- @param content string
--- @return string|nil
local function _shebang_lang(content)
  local first = content:match("^#!([^\n]*)")
  if not first then return nil end
  local lower = first:lower()
  if lower:find("python") then return "python" end
  if lower:find("node") then return "node" end
  if lower:find("ruby") then return "ruby" end
  if lower:find("perl") then return "perl" end
  if lower:find("php") then return "php" end
  if lower:find("sh") or lower:find("bash") or lower:find("zsh") or lower:find("dash") then
    return "shell"
  end
  return nil
end

--- 解析某解释器调用（toks[i] 为解释器名），返回 { kind="script"|"code"|"opaque", ... }
--- @param toks table
--- @param i number
--- @param lang string
--- @return table|nil
local function _parse_invocation(toks, i, lang)
  local codes = CODE_FLAGS[lang] or {}
  local values = VALUE_OPTS[lang] or {}
  local modules = MODULE_FLAGS[lang] or {}
  local j = i + 1
  while j <= #toks do
    local raw = toks[j]
    local v = _clean(raw)
    if v == "" then
      j = j + 1
    elseif raw == "-" or v == "-" then
      return { kind = "opaque", reason = "STDIN" }
    elseif v:sub(1, 1) == "-" then
      local opt = v:match("^([^=]+)")
      if codes[opt] then
        local inline = v:match("^[^=]+=(.*)$")
        local raw_code = inline and toks[j] or (toks[j + 1] or "")
        -- 双引号内的 `$`/`$()` 由外层 shell 展开 → 代码内容动态，无法静态判定
        if raw_code:sub(1, 1) == '"' and raw_code:find("$", 1, true) then
          return { kind = "opaque", reason = "DYNAMIC_CODE" }
        end
        local code = inline or _clean(raw_code)
        if code == "" then return { kind = "opaque", reason = "DYNAMIC_CODE" } end
        return { kind = "code", code = code, lang = lang }
      end
      if modules[opt] then return { kind = "opaque", reason = "MODULE" } end
      if values[opt] and not v:find("=", 1, true) then j = j + 1 end
      j = j + 1
    else
      return { kind = "script", path = v, lang = lang }
    end
  end
  return nil
end

--- 读取文件头部 n 字节（用于 shebang 推断；不读取无界设备/FIFO）
--- @param path string
--- @param n number
--- @return string|nil
local function _read_head(path, n)
  local f = io.open(path, "rb")
  if not f then return nil end
  local c = f:read(n)
  f:close()
  return c
end

--- 是否为可作为脚本读取的**常规文件**。字符/块设备（/dev/urandom、/dev/zero）、FIFO、
--- socket 等 `filereadable()` 同样返回 1，但 `read("*a")` 会阻塞或产生无界内容（此前
--- `head -c … /dev/urandom | base64` 会读取该设备直至超时，单条命令卡 2.5s 且有 OOM 风险）。
--- @param path string
--- @return boolean
local function _is_regular_file(path)
  local st = vim.uv.fs_stat(path)
  return st ~= nil and st.type == "file"
end

--- 直接可执行脚本（`./x.sh`、`/path/manage.py`）：读取 shebang 判断语言
--- @param tok string
--- @param cwd string
--- @return string|nil path
--- @return string|nil lang
local function _direct_script(tok, cwd)
  local v = _clean(tok)
  if not v:find("/", 1, true) then return nil end
  local path = v
  if path:sub(1, 1) ~= "/" and path:sub(1, 1) ~= "~" then
    path = cwd .. "/" .. path
  end
  local canon = fs.canonical(path)
  if not _is_regular_file(canon) then return nil end
  -- 仅需首行 shebang：读取有界头部，避免整文件读入（大二进制/设备）。
  local content = _read_head(canon, 256)
  if not content then return nil end
  local lang = _shebang_lang(content)
  if not lang then return nil end
  return canon, lang
end

--- 读取脚本内容：优先沙箱暂存副本（AI 新建/修改的脚本），其次真实文件。
--- 仅读取**常规文件**：设备/FIFO/socket 直接视为不可读（调用方标记不透明），避免无界读取。
--- @param path string
--- @param state table
--- @return string|nil
local function _read_script(path, state)
  if state.read then
    local ok, c = pcall(state.read, path)
    if ok and type(c) == "string" then return c end
  end
  local ok, staged = pcall(function()
    return require("NeoAI.sandbox.candidate").read_path(path)
  end)
  if ok and type(staged) == "string" then
    if _is_regular_file(staged) then
      local c = fs.read_file(staged)
      if c ~= nil then return c end
    end
  end
  if not _is_regular_file(path) then return nil end
  return fs.read_file(path)
end

local _scan_text -- 前向声明
local _process_language -- 前向声明

--- 追加一段文本到 inner（供 effective 与危险识别）
--- @param state table
--- @param text string
local function _append(state, text)
  if type(text) ~= "string" or text == "" then return end
  state.inner[#state.inner + 1] = text
end

--- 处理解释器调用（脚本/代码/不透明）
--- @param inv table
--- @param state table
--- @param depth number
local function _process_invocation(inv, state, depth)
  if not inv then return end
  if inv.kind == "opaque" then
    state.opaque = true
    return
  end
  if inv.kind == "code" then
    state.indirect = true
    if inv.lang == "shell" then
      local body = _strip_comments(inv.code, "shell")
      _append(state, body)
      if body:find("eval%s", 1) or body:find("|%s*sh") or body:find("|%s*bash")
        or body:find("base64%s+%-%w*d") then
        state.opaque = true
      end
      _scan_text(body, state, depth + 1)
    else
      _process_language(inv.code, inv.lang, state, depth)
    end
    return
  end
  -- script
  if depth >= state.depth_limit then
    state.opaque = true
    return
  end
  local path = inv.path
  if path:sub(1, 1) ~= "/" and path:sub(1, 1) ~= "~" then
    path = state.cwd .. "/" .. path
  end
  local resolved = fs.canonical(path)
  if state.visited[resolved] then return end
  if state.files_read >= state.file_limit then
    state.truncated = true
    state.opaque = true
    return
  end
  -- 宿主敏感遮蔽路径：不读取内容（避免以密钥文件内容参与判定），标记不透明
  local ok_masked, masked = pcall(function()
    return require("NeoAI.sandbox.runtime").is_masked_path(resolved)
  end)
  if ok_masked and masked then
    state.opaque = true
    return
  end
  local content = _read_script(resolved, state)
  if content == nil then
    state.opaque = true
    return
  end
  state.visited[resolved] = true
  state.files_read = state.files_read + 1
  if #content > state.byte_limit then
    content = content:sub(1, state.byte_limit)
    state.truncated = true
  end
  state.indirect = true
  state.scripts[#state.scripts + 1] = resolved
  local lang = inv.lang
  if lang == "auto" then lang = _shebang_lang(content) or "shell" end
  if lang == "shell" then
    local body = _strip_comments(content, "shell")
    _append(state, body)
    if body:find("%f[%w]eval%s") or body:find("|%s*sh%f[%W]") or body:find("|%s*bash%f[%W]")
      or body:find("base64%s+%-%w*d") then
      state.opaque = true
    end
    _scan_text(body, state, depth + 1)
  else
    _process_language(content, lang, state, depth)
  end
end

--- 处理高级语言脚本：提取内嵌 shell 调用并递归
--- @param text string
--- @param lang string
--- @param state table
--- @param depth number
_process_language = function(text, lang, state, depth)
  local clean = _strip_comments(text, lang)
  local apis = LANG_APIS[lang] or {}
  for _, pat in ipairs(apis) do
    for s, e in _iter_api(clean, pat) do
      local window = clean:sub(e + 1, e + 600)
      local nl = window:find("\n")
      local seg = nl and window:sub(1, nl + 120) or window
      local strs = _extract_strings(seg)
      if #strs == 0 then
        -- API 存在但取不到字面量（变量/拼接）→ 无法静态判定
        state.opaque = true
      else
        for _, str in ipairs(strs) do
          if str ~= "" then _append(state, str) end
        end
        _scan_text(table.concat(strs, " "), state, depth + 1)
      end
      -- 插值/模板（`${}`、`#{}`）→ 动态
      if seg:find("%$%{") or seg:find("#{", 1, true) then state.opaque = true end
    end
  end
  for _, pat in ipairs(DYNAMIC_PATTERNS[lang] or {}) do
    if clean:find(pat) then state.opaque = true end
  end
end

--- 扫描一段（shell）文本：识别解释器调用与直接可执行脚本
--- @param text string
--- @param state table
--- @param depth number
function _scan_text(text, state, depth)
  local toks = _tokenize(text)
  local i = 1
  while i <= #toks do
    local v = _clean(toks[i])
    local base = v:match("[^/]+$") or v
    local lang = _lang_of(base)
    if v == "." or v == "source" then
      local nxt = _clean(toks[i + 1] or "")
      if nxt ~= "" and not nxt:find("^%-") then
        _process_invocation({ kind = "script", path = nxt, lang = "shell" }, state, depth)
      end
      i = i + 2
    elseif lang then
      local inv = _parse_invocation(toks, i, lang)
      if inv == nil then
        -- 解释器无脚本/代码参数（`curl … | sh`、`… | python`）：读 stdin，内容动态
        local prev = i > 1 and _clean(toks[i - 1]) or ""
        if prev == "|" then state.opaque = true end
      end
      _process_invocation(inv, state, depth)
      i = i + 1
    else
      local dpath, dlang = _direct_script(toks[i], state.cwd)
      if dpath then
        _process_invocation({ kind = "script", path = dpath, lang = dlang }, state, depth)
      end
      i = i + 1
    end
  end
end

-- ========== 公开 API ==========

--- 扫描命令中的脚本间接执行，返回折叠文本与标志。
--- @param command string
--- @param opts table|nil { cwd?, read?=function(path)->string|nil, max_depth?, max_files?, max_bytes? }
--- @return table {
---   enabled, indirect, opaque, truncated,
---   effective (outer+inner), inner, danger (inner 命中的最高危险级别),
---   scripts (已扫描脚本路径), }
function M.scan(command, opts)
  opts = opts or {}
  local cfg = _cfg()
  if type(command) ~= "string" or command == "" or cfg.enabled == false then
    return {
      enabled = cfg.enabled ~= false, indirect = false, opaque = false, truncated = false,
      effective = command or "", inner = "", danger = 0, scripts = {},
    }
  end
  local state = {
    cwd = opts.cwd or vim.fn.getcwd(),
    read = opts.read,
    depth_limit = tonumber(opts.max_depth) or tonumber(cfg.max_depth) or 3,
    file_limit = tonumber(opts.max_files) or tonumber(cfg.max_files) or 8,
    byte_limit = tonumber(opts.max_bytes) or tonumber(cfg.max_bytes) or 262144,
    inner = {},
    scripts = {},
    visited = {},
    files_read = 0,
    indirect = false,
    opaque = false,
    truncated = false,
  }
  _scan_text(command, state, 0)
  local inner = table.concat(state.inner, "\n")
  local danger = 0
  local ok, risk = pcall(require, "NeoAI.sandbox.risk")
  if ok and type(risk.dangerous_level) == "function" then
    danger = risk.dangerous_level(inner) or 0
  end
  return {
    enabled = true,
    indirect = state.indirect,
    opaque = state.opaque,
    truncated = state.truncated,
    effective = inner ~= "" and (command .. "\n" .. inner) or command,
    inner = inner,
    danger = danger,
    scripts = state.scripts,
  }
end

-- 供测试使用的内部函数
M._tokenize = _tokenize
M._extract_strings = _extract_strings
M._strip_comments = _strip_comments
M._shebang_lang = _shebang_lang

--- 重置（测试用）：无模块级状态
function M.reset() end

return M
