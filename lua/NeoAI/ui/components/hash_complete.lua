--- 输入框 # 占位符补全与解析
--- @module 'NeoAI.ui.components.hash_complete'
--- 聊天输入框内以 `#` 触发的上下文占位符：`#{...}`。
---
--- 设计要点：
---   * 输入时只插入占位符文本（如 `#{buffers}`），并用 extmark 高亮标出；
---     **发送前**由 `resolve()` 统一替换为真实上下文，输入框内容保持可读可改。
---   * 补全走 `completefunc`（`<C-x><C-u>` 手动触发）与可选 nvim-cmp 源
---     （`#` / `:` 触发），不依赖任何第三方插件。
---   * 所有解析结果统一经 `utils.stringx.safe_truncate` 做 UTF-8 安全截断；
---     `#{message}` / `#{notify}` 额外按**字符数**上限截断（CJK 不会被切半）。
---   * 解析失败（未找到 buffer / 未知键）时原样保留占位符，绝不抛错中断发送。

local stringx = require("NeoAI.utils.stringx")

local M = {}

local HL_NS = vim.api.nvim_create_namespace("neoai_hash_placeholder")
local HL_GROUP = "NeoAIHashPlaceholder"

-- 输出兜底上限（字节）；单键可在解析时进一步收紧
local DEFAULT_MAX_BYTES = 20000
-- 消息类占位符的字符数上限（按「字符」而非字节，CJK 站点友好）
local DEFAULT_MAX_CHARS = 2000

--- 占位符规格表（order 即补全展示顺序）
--- arg 为 nil 表示标量键（`#{key}`）；否则为参数化键（`#{key:NAME}`）。
M.KEYS = {
  { name = "buffers", desc = "当前打开的全部 buffer 列表", info = "列出所有 buffer 的名称/编号/类型" },
  { name = "buffer", arg = "buffer", desc = "指定 buffer 的内容（按名称/路径匹配）", info = "#{buffer:NAME}" },
  { name = "lsp", desc = "当前文件的 LSP 诊断", info = "上下文 buffer 的诊断列表（文件:行:列 [级别] 消息）" },
  { name = "message", desc = "Neovim 消息历史（启动至今）", info = "等价 :messages 输出，上限 2000 字符" },
  { name = "notify", desc = "Neovim 消息历史（启动至今）", info = "等价 :messages 输出，上限 2000 字符" },
  { name = "tool", arg = "tool", desc = "工具清单 / 指定工具定义", info = "#{tool} 全部工具；#{tool:NAME} 单个工具定义" },
  { name = "skills", arg = "skills", desc = "技能清单 / 指定技能正文", info = "#{skills} 全部技能；#{skills:NAME} 技能正文" },
  { name = "mcp", arg = "mcp", desc = "MCP 工具清单 / 指定工具定义", info = "#{mcp} 全部 MCP 工具；#{mcp:NAME} 单个定义" },
}

--- name → 规格
--- @type table<string, table>
local KEY_BY_NAME = {}
for _, spec in ipairs(M.KEYS) do KEY_BY_NAME[spec.name] = spec end

-- ========== 私有函数 ==========

--- 取配置
--- @return table
local function _cfg()
  local ok, cfg = pcall(function()
    return require("NeoAI.kernel.config_store").get("ui.input_box.hash_completion")
  end)
  return (ok and type(cfg) == "table") and cfg or {}
end

--- 是否启用
--- @return boolean
local function _enabled()
  return _cfg().enabled ~= false
end

--- 按字符数截断（CJK/UTF-8 安全），超限时追加省略说明
--- @param s string
--- @param max_chars number
--- @return string
local function _truncate_chars(s, max_chars)
  if type(s) ~= "string" or s == "" then return s end
  max_chars = tonumber(max_chars) or DEFAULT_MAX_CHARS
  if max_chars <= 0 then return s end
  local ok, n = pcall(vim.fn.strchars, s)
  if not ok or type(n) ~= "number" or n <= max_chars then return s end
  local keep = vim.fn.strcharpart(s, 0, max_chars)
  return keep .. "\n…（已截断，超过 " .. tostring(max_chars) .. " 字符）"
end

--- 统一兜底截断（UTF-8 安全）
--- @param s string
--- @param max_bytes number|nil
--- @return string
local function _cap(s, max_bytes)
  if type(s) ~= "string" or s == "" then return s end
  local limit = tonumber(max_bytes) or tonumber(_cfg().max_bytes) or DEFAULT_MAX_BYTES
  return stringx.safe_truncate(s, limit, "\n…（输出已截断）") or s
end

--- 懒取服务（缺失返回 nil）
--- @param name string
--- @return any
local function _svc(name)
  local ok, value = pcall(function()
    return require("NeoAI.kernel.services").use(name)
  end)
  if ok then return value end
  return nil
end

--- 当前全部 buffer 的简要信息
--- @return table 数组 { bufnr, name, basename, loaded, buftype, filetype }
local function _buffers()
  local out = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      out[#out + 1] = {
        bufnr = buf,
        name = name,
        basename = name ~= "" and vim.fn.fnamemodify(name, ":t") or "",
        loaded = vim.api.nvim_buf_is_loaded(buf),
        buftype = vim.bo[buf].buftype,
        filetype = vim.bo[buf].filetype,
      }
    end
  end
  return out
end

--- 读取 buffer 内容（未加载时回退读文件）
--- @param buf number
--- @return string|nil
local function _read_buf(buf)
  if vim.api.nvim_buf_is_loaded(buf) then
    local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, -1, false)
    if ok and type(lines) == "table" then return table.concat(lines, "\n") end
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name ~= "" and vim.fn.filereadable(name) == 1 then
    local ok, lines = pcall(vim.fn.readfile, name)
    if ok and type(lines) == "table" then return table.concat(lines, "\n") end
  end
  return nil
end

--- 解析 `:messages` 历史（Neovim 启动至今）
--- @return string
local function _messages()
  local text
  if vim.api.nvim_exec2 then
    local ok, res = pcall(vim.api.nvim_exec2, "messages", { output = true })
    if ok and type(res) == "table" then text = res.output end
  end
  if not text then
    local ok, res = pcall(vim.fn.execute, "messages")
    if ok and type(res) == "string" then text = res end
  end
  text = (text or ""):gsub("^%s*\n", ""):gsub("%s+$", "")
  return _truncate_chars(text, tonumber(_cfg().max_chars) or DEFAULT_MAX_CHARS)
end

--- 参数化键的候选名列表
--- @param key string
--- @return table 字符串数组
local function _arg_names(key)
  if key == "tool" or key == "mcp" then
    if key == "tool" then
      local ok, registry = pcall(require, "NeoAI.tools.registry")
      if ok and registry then
        local names = {}
        for _, tool in ipairs(registry.list() or {}) do names[#names + 1] = tool.name end
        return names
      end
      return {}
    end
    local mcp = _svc("services.mcp")
    if mcp and type(mcp.list_tool_names) == "function" then
      local ok, names = pcall(mcp.list_tool_names)
      if ok and type(names) == "table" then return names end
    end
    return {}
  elseif key == "skills" then
    local skills = _svc("services.skills")
    if skills and type(skills.list) == "function" then
      local ok, list = pcall(skills.list)
      if ok and type(list) == "table" then
        local names = {}
        for _, s in ipairs(list) do names[#names + 1] = s.name end
        return names
      end
    end
    return {}
  elseif key == "buffer" then
    local names = {}
    for _, b in ipairs(_buffers()) do
      if b.name ~= "" then names[#names + 1] = b.basename ~= "" and b.basename or b.name end
    end
    return names
  end
  return {}
end

--- 生成键候选项（不含参数）
--- @param prefix string 已输入键前缀（小写）
--- @return table 数组 { word, menu, info, kind }
local function _key_items(prefix)
  prefix = (prefix or ""):lower()
  local out = {}
  for _, spec in ipairs(M.KEYS) do
    if prefix == "" or spec.name:sub(1, #prefix) == prefix then
      out[#out + 1] = {
        word = "#{" .. spec.name .. (spec.arg and ":" or "}"),
        menu = spec.desc,
        info = spec.info or ("#" .. "{" .. spec.name .. "}"),
        kind = spec.arg and "参数" or "上下文",
      }
    end
  end
  return out
end

--- 生成参数候选项
--- @param key string
--- @param prefix string 已输入参数前缀（小写）
--- @return table 数组 { word, menu, info, kind }
local function _arg_items(key, prefix)
  prefix = (prefix or ""):lower()
  local out = {}
  for _, name in ipairs(_arg_names(key)) do
    if prefix == "" or name:lower():sub(1, #prefix) == prefix then
      out[#out + 1] = {
        word = "#{" .. key .. ":" .. name .. "}",
        menu = "#{ " .. key .. " }",
        info = name,
        kind = "参数",
      }
    end
  end
  return out
end

-- ========== 补全 ==========

--- 定位当前 `#` 占位符 token 的起始列（1-based 字节下标）
--- 从行尾向前扫描：遇到空白或 `}` 即停止（说明光标不在占位符 token 内）。
--- @param line string 光标之前的行文本
--- @return number|nil start_col
--- @return string typed 从 `#` 到行尾的文本
function M.find_start(line)
  if type(line) ~= "string" then return nil end
  local i = #line
  while i >= 1 do
    local ch = line:sub(i, i)
    if ch == "#" then
      return i, line:sub(i)
    end
    if ch:match("%s") or ch == "}" then return nil end
    i = i - 1
  end
  return nil
end

--- 按已输入 token 生成补全候选
--- @param typed string `#` 起始的已输入文本
--- @return table 候选数组 { word, menu, info, kind }
function M.candidates(typed)
  if not _enabled() then return {} end
  if type(typed) ~= "string" or typed:sub(1, 1) ~= "#" then return {} end
  local body = typed:sub(2)
  if body == "" then return _key_items("") end
  if body:sub(1, 1) ~= "{" then return {} end
  if body:find("}", 1, true) then return {} end
  body = body:sub(2)
  local colon = body:find(":", 1, true)
  if not colon then
    return _key_items(body:lower())
  end
  local key = body:sub(1, colon - 1):lower()
  local argp = body:sub(colon + 1)
  if not KEY_BY_NAME[key] then return {} end
  return _arg_items(key, argp:lower())
end

--- 取光标前的行文本（兼容插入模式 / 普通模式的光标语义）。
--- `nvim_win_get_cursor` 返回 0-based 字节下标：插入模式下光标停在最后输入字符之后
--- （即 col 等于已输入文本长度），普通模式下停在字符上（col 指向该字符）。
--- completefunc 只在插入模式触发，但测试/直接调用可能处于普通模式，因此两种都尝试。
--- @param line string 当前行
--- @param col number 0-based 光标列
--- @return string before 光标前的文本
local function _before_cursor(line, col)
  local before = line:sub(1, math.max(0, col))
  if M.find_start(before) then return before end
  return line:sub(1, math.min(#line, col + 1))
end

--- completefunc 实现（completefunc=NeoAIHashComplete）
--- findstart 阶段返回起始列（0-based 字节）；否则返回候选 dict（word/menu/info/kind）。
--- @param findstart number 1=找起点，0=取候选
--- @param base string 已输入的前缀
--- @return number|table
function M.completefunc(findstart, base)
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local before = _before_cursor(line, col)
  if findstart == 1 then
    local start = M.find_start(before)
    if not start then return -3 end -- 不在占位符内：取消补全
    return start - 1
  end
  local _, typed = M.find_start(before)
  return M.candidates(typed or ("#" .. (base or "")))
end

--- 供 nvim-cmp 源使用的候选（is_available 判定在调用方）
--- @param before_cursor string 光标前的行文本
--- @return table 数组 { label, insertText, detail, documentation }
function M.cmp_items(before_cursor)
  if not _enabled() then return {} end
  local _, typed = M.find_start(before_cursor or "")
  if not typed then return {} end
  local out = {}
  for _, item in ipairs(M.candidates(typed)) do
    out[#out + 1] = {
      label = item.word,
      insertText = item.word,
      detail = item.menu,
      documentation = { kind = "markdown", value = item.info or "" },
    }
  end
  return out
end

-- ========== 解析 ==========

--- `#{buffers}` → buffer 列表
--- @return string
local function _resolve_buffers()
  local lines = {}
  for _, b in ipairs(_buffers()) do
    lines[#lines + 1] = ("%3d  %-8s %-12s %s"):format(
      b.bufnr,
      b.loaded and "loaded" or "unloaded",
      (b.filetype ~= "" and b.filetype or b.buftype ~= "" and b.buftype or "-"),
      b.name ~= "" and b.name or "[无名称]")
  end
  if #lines == 0 then return "（无 buffer）" end
  return "当前 buffer 列表（编号 / 状态 / 类型 / 路径）：\n" .. table.concat(lines, "\n")
end

--- `#{buffer:NAME}` → 该 buffer 内容（按名称 / 文件名 / 路径模糊匹配，多命中全部拼接）
--- @param name string
--- @return string|nil nil 表示未匹配（调用方原样保留占位符）
local function _resolve_buffer(name)
  if type(name) ~= "string" or name == "" then return nil end
  local needle = name:lower()
  local hits = {}
  for _, b in ipairs(_buffers()) do
    local full = b.name:lower()
    if full ~= "" and (full == needle or full:sub(-#needle) == needle or b.basename:lower() == needle) then
      hits[#hits + 1] = b
    end
  end
  if #hits == 0 then return nil end
  local parts = {}
  for _, b in ipairs(hits) do
    local content = _read_buf(b.bufnr)
    if content then
      parts[#parts + 1] = ("--- %s（buf %d）---\n%s"):format(b.name ~= "" and b.name or "[无名称]", b.bufnr, content)
    end
  end
  if #parts == 0 then return nil end
  return table.concat(parts, "\n\n")
end

--- `#{lsp}` → 上下文 buffer 的诊断
--- @param ctx table|nil { bufnr? }
--- @return string
local function _resolve_lsp(ctx)
  local buf = (ctx and tonumber(ctx.bufnr)) or vim.api.nvim_get_current_buf()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return "（无诊断）" end
  -- `vim.diagnostic` 在极简/裁剪构建（缺 vim.lsp）下取用即抛错，因此整个取用都要 pcall 包住。
  local ok, diags = pcall(function() return vim.diagnostic.get(buf) end)
  if not ok or type(diags) ~= "table" or #diags == 0 then return "（无诊断）" end
  local levels = { "ERROR", "WARN", "INFO", "HINT" }
  local name = vim.api.nvim_buf_get_name(buf)
  name = name ~= "" and vim.fn.fnamemodify(name, ":.") or "[无名称]"
  local lines = {}
  for _, d in ipairs(diags) do
    lines[#lines + 1] = ("%s:%d:%d [%s] %s"):format(
      name,
      (d.lnum or 0) + 1,
      (d.col or 0) + 1,
      levels[(d.severity or 1)] or "INFO",
      (d.message or ""):gsub("%s+", " "))
  end
  return "LSP 诊断：\n" .. table.concat(lines, "\n")
end

--- `#{tool}` → 工具清单
--- @return string
local function _resolve_tools()
  local ok, registry = pcall(require, "NeoAI.tools.registry")
  if not ok or not registry then return "（工具系统未就绪）" end
  local list = registry.list() or {}
  if #list == 0 then return "（无可用工具）" end
  local lines = {}
  for _, tool in ipairs(list) do
    local desc = (tool.description or ""):gsub("%s+", " ")
    lines[#lines + 1] = ("- %s：%s"):format(tool.name, stringx.truncate(desc, 160))
  end
  return "可用工具：\n" .. table.concat(lines, "\n")
end

--- `#{tool:NAME}` / `#{mcp:NAME}` → 单个工具定义
--- @param name string
--- @return string|nil
local function _resolve_tool(name)
  local ok, registry = pcall(require, "NeoAI.tools.registry")
  if not ok or not registry or type(name) ~= "string" or name == "" then return nil end
  local tool = registry.get(name)
  if not tool then return nil end
  local parts = {
    ("工具：%s"):format(tool.name),
    ("说明：%s"):format((tool.description or ""):gsub("%s+$", "")),
  }
  if tool.parameters then
    local okj, encoded = pcall(function() return require("NeoAI.utils.json").encode(tool.parameters) end)
    if okj and type(encoded) == "string" then
      parts[#parts + 1] = "参数 schema：" .. encoded
    end
  end
  return table.concat(parts, "\n")
end

--- `#{skills}` → 技能清单
--- @return string
local function _resolve_skills()
  local skills = _svc("services.skills")
  if not skills or type(skills.list) ~= "function" then return "（技能服务未就绪）" end
  local ok, list = pcall(skills.list)
  if not ok or type(list) ~= "table" or #list == 0 then return "（无可用技能）" end
  local lines = {}
  for _, s in ipairs(list) do
    lines[#lines + 1] = ("- %s：%s"):format(s.name, stringx.truncate((s.description or ""):gsub("%s+", " "), 160))
  end
  return "可用技能：\n" .. table.concat(lines, "\n")
end

--- `#{skills:NAME}` → 技能正文
--- @param name string
--- @return string|nil
local function _resolve_skill(name)
  local skills = _svc("services.skills")
  if not skills or type(skills.load) ~= "function" then return nil end
  local ok, skill = pcall(skills.load, name)
  if not ok or type(skill) ~= "table" or type(skill.content) ~= "string" then return nil end
  return ("技能 %s（%s）：\n%s"):format(skill.name or name, skill.path or "", skill.content)
end

--- `#{mcp}` → MCP 工具清单
--- @return string
local function _resolve_mcp()
  local mcp = _svc("services.mcp")
  if not mcp or type(mcp.list_tool_names) ~= "function" then return "（MCP 服务未就绪）" end
  local ok, names = pcall(mcp.list_tool_names)
  if not ok or type(names) ~= "table" or #names == 0 then return "（无 MCP 工具）" end
  local lines = { "MCP 工具：" }
  for _, name in ipairs(names) do lines[#lines + 1] = "- " .. name end
  return table.concat(lines, "\n")
end

--- 单个占位符求值
--- @param key string
--- @param arg string|nil
--- @param ctx table|nil
--- @return string|nil nil = 未知键或解析失败（保留原样）
local function _eval(key, arg, ctx)
  if key == "buffers" then return _cap(_resolve_buffers()) end
  if key == "buffer" then
    local body = _resolve_buffer(arg)
    return body and _cap(body) or nil
  end
  if key == "lsp" then return _cap(_resolve_lsp(ctx)) end
  if key == "message" or key == "notify" then return _cap(_messages()) end
  if key == "tool" then
    if arg and arg ~= "" then
      local body = _resolve_tool(arg)
      return body and _cap(body) or nil
    end
    return _cap(_resolve_tools())
  end
  if key == "mcp" then
    if arg and arg ~= "" then
      local body = _resolve_tool(arg)
      return body and _cap(body) or nil
    end
    return _cap(_resolve_mcp())
  end
  if key == "skills" then
    if arg and arg ~= "" then
      local body = _resolve_skill(arg)
      return body and _cap(body) or nil
    end
    return _cap(_resolve_skills())
  end
  return nil
end

--- 解析并替换文本中的全部占位符
--- 未知键/解析失败时**原样保留**占位符（不抛错、不产生空串），保证发送不中断。
--- @param content string 输入框原文
--- @param ctx table|nil { bufnr? = number 上下文 buffer（用于 #{lsp}） }
--- @return string resolved
--- @return number count 实际替换的占位符数量
function M.resolve(content, ctx)
  if type(content) ~= "string" or content == "" then return content, 0 end
  if not _enabled() then return content, 0 end
  if not content:find("#{", 1, true) then return content, 0 end
  local count = 0
  local out = content:gsub("#%{([^}%s]*)}", function(body)
    local key, arg = body:match("^([%w_%-]+):(.*)$")
    if not key then key, arg = body, nil end
    local ok, value = pcall(_eval, key, arg, ctx)
    if ok and type(value) == "string" and value ~= "" then
      count = count + 1
      return value
    end
    return "#{" .. body .. "}" -- 保持原样
  end)
  return out, count
end

--- 列出文本中的全部占位符（诊断/测试用）
--- @param content string
--- @return table 数组 { raw, key, arg }
function M.scan(content)
  local out = {}
  if type(content) ~= "string" then return out end
  for body in content:gmatch("#%{([^}%s]*)}") do
    local key, arg = body:match("^([%w_%-]+):(.*)$")
    out[#out + 1] = { raw = "#{" .. body .. "}", key = key or body, arg = arg }
  end
  return out
end

-- ========== 高亮 ==========

--- 定义高亮组（默认链接，可被用户配色覆盖）
function M.define_hl()
  pcall(vim.api.nvim_set_hl, 0, HL_GROUP, { link = "Special", default = true })
end

--- 在 buffer 中高亮全部 `#{...}` 占位符
--- @param buf number|nil buffer 号（缺省当前 buffer）
--- @return number 高亮数量
function M.highlight(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return 0 end
  M.define_hl()
  pcall(vim.api.nvim_buf_clear_namespace, buf, HL_NS, 0, -1)
  if not _enabled() then return 0 end
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, -1, false)
  if not ok or type(lines) ~= "table" then return 0 end
  local n = 0
  for row, line in ipairs(lines) do
    local init = 1
    while true do
      local s, e = line:find("#%{[^}%s]*}", init)
      if not s then break end
      local okm = pcall(vim.api.nvim_buf_set_extmark, buf, HL_NS, row - 1, s - 1, {
        end_col = e,
        hl_group = HL_GROUP,
      })
      if okm then n = n + 1 end
      init = e + 1
    end
  end
  return n
end

--- 清空高亮（reset/destroy 时调用）
--- @param buf number|nil
function M.clear(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  pcall(vim.api.nvim_buf_clear_namespace, buf, HL_NS, 0, -1)
end

--- 高亮命名空间（供输入框清理/测试断言）
M.HL_NS = HL_NS
--- 高亮组名
M.HL_GROUP = HL_GROUP
--- completefunc 使用的全局函数名（`completefunc` 选项只接受 Vim 函数名或 `v:lua.xxx`）
M.COMPLETEFUNC = "NeoAIHashComplete"

--- 安装 completefunc 需要的全局入口（幂等）
--- `'completefunc'` 只接受 Vim 函数名或 `v:lua.<name>` 形式，Lua 侧必须暴露一个全局入口。
--- 该全局仅是一个转发器，不做任何监听，随 `reset()` 一并清除。
--- @return string 供 `vim.bo.completefunc` 设置的值
function M.ensure_global()
  if type(_G[M.COMPLETEFUNC]) ~= "function" then
    _G[M.COMPLETEFUNC] = function(findstart, base)
      local ok, mod = pcall(require, "NeoAI.ui.components.hash_complete")
      if not ok then return findstart == 1 and -3 or {} end
      return mod.completefunc(findstart, base)
    end
  end
  return "v:lua." .. M.COMPLETEFUNC
end

-- ========== nvim-cmp 源 ==========

local CMP_SRC = "neoai_hash"
local cmp_registered = false

--- 注册 nvim-cmp 补全源（仅在用户已装 nvim-cmp 时；幂等）
--- @return boolean ok
function M.setup_cmp_source()
  if cmp_registered then return true end
  local ok, cmp = pcall(require, "cmp")
  if not ok or type(cmp) ~= "table" or type(cmp.register_source) ~= "function" then return false end
  local source = {}
  function source.get_trigger_characters() return { "#", ":" } end
  function source.is_available()
    if not _enabled() then return false end
    local ok_line, line = pcall(vim.api.nvim_get_current_line)
    if not ok_line then return false end
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local before = line:sub(1, col)
    local start = M.find_start(before)
    if not start then return false end
    -- 仅在 `#` 或未闭合的 `#{...` 内提供候选
    return before:sub(start):find("}", 1, true) == nil
  end
  function source.get_keyword_pattern()
    return [[\%([#{}:[:alnum:]_-]\)\+]]
  end
  function source.complete(_, params, callback)
    local line = (params and params.context and params.context.cursor_before_line) or ""
    callback({ items = M.cmp_items(line), isIncomplete = false })
  end
  local ok_reg = pcall(cmp.register_source, CMP_SRC, source)
  if ok_reg then cmp_registered = true end
  return ok_reg
end

--- 注销 nvim-cmp 补全源
function M.teardown_cmp_source()
  if not cmp_registered then return end
  cmp_registered = false
  pcall(function()
    local cmp = require("cmp")
    if type(cmp.unregister_source) == "function" then cmp.unregister_source(CMP_SRC) end
  end)
end

--- cmp 源名（供输入框/文档引用）
M.CMP_SOURCE = CMP_SRC

--- 重置（测试用）：清全局入口与 cmp 源
function M.reset()
  M.teardown_cmp_source()
  _G[M.COMPLETEFUNC] = nil
end

return M
