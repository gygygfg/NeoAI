--- ANSI SGR 转义序列解析（供 UI 渲染带颜色的命令输出）
--- @module NeoAI.utils.ansi
--- 纯函数 + 惰性高亮组创建。把 `\27[1;36m...\27[0m` 解析为纯文本 + 每行的高亮区间，
--- 非 SGR 的 CSI/OSC 序列（光标移动、清屏、窗口标题等）一律剥离。
--- 支持 8/16 基础色、256 色（38;5;n / 48;5;n）与真彩色（38;2;r;g;b），
--- 以及 bold/italic/underline/reverse/strikethrough 属性。

local M = {}

-- xterm 16 基础色
local BASE = {
  [0] = "#000000", [1] = "#cd0000", [2] = "#00cd00", [3] = "#cdcd00",
  [4] = "#0000ee", [5] = "#cd00cd", [6] = "#00cdcd", [7] = "#e5e5e5",
  [8] = "#7f7f7f", [9] = "#ff0000", [10] = "#00ff00", [11] = "#ffff00",
  [12] = "#5c5cff", [13] = "#ff00ff", [14] = "#00ffff", [15] = "#ffffff",
}

--- 256 色索引 → 十六进制颜色
--- @param n number
--- @return string
local function _x256(n)
  if n < 16 then return BASE[n] end
  if n < 232 then
    n = n - 16
    local function c(v) return v == 0 and 0 or (55 + v * 40) end
    return string.format("#%02x%02x%02x", c(math.floor(n / 36)),
      c(math.floor((n % 36) / 6)), c(n % 6))
  end
  local v = 8 + (n - 232) * 10
  return string.format("#%02x%02x%02x", v, v, v)
end

local hl_cache = {}
local hl_count = 0

--- 由当前 SGR 状态构造（惰性创建）高亮组名；无任何属性时返回 nil（默认配色）。
--- @param st table
--- @return string|nil
local function _ensure_hl(st)
  if not st.fg and not st.bg and not st.bold and not st.italic and not st.underline
    and not st.reverse and not st.strike then
    return nil
  end
  local key = table.concat({
    st.fg or "-", st.bg or "-",
    st.bold and "b" or "-", st.italic and "i" or "-", st.underline and "u" or "-",
    st.reverse and "r" or "-", st.strike and "s" or "-",
  }, "|")
  local cached = hl_cache[key]
  if cached then return cached end
  hl_count = hl_count + 1
  local name = "NeoAIAnsi_" .. tostring(hl_count)
  local spec = { default = true }
  local fg, bg = st.fg, st.bg
  if st.reverse then fg, bg = bg or "#000000", fg end
  if fg then spec.fg = fg end
  if bg then spec.bg = bg end
  if st.bold then spec.bold = true end
  if st.italic then spec.italic = true end
  if st.underline then spec.underline = true end
  if st.strike then spec.strikethrough = true end
  pcall(vim.api.nvim_set_hl, 0, name, spec)
  hl_cache[key] = name
  return name
end

--- 在状态上应用一段 SGR 参数（如 "1;36" / "" / "38;5;208"）。
--- @param st table
--- @param params string
local function _apply_sgr(st, params)
  local codes = {}
  for p in params:gmatch("[^;:]+") do
    codes[#codes + 1] = tonumber(p)
  end
  if #codes == 0 then codes = { 0 } end
  local i = 1
  while i <= #codes do
    local c = codes[i]
    if c == 0 then
      st.fg, st.bg = nil, nil
      st.bold, st.italic, st.underline, st.reverse, st.strike = false, false, false, false, false
    elseif c == 1 then st.bold = true
    elseif c == 3 then st.italic = true
    elseif c == 4 then st.underline = true
    elseif c == 7 then st.reverse = true
    elseif c == 9 then st.strike = true
    elseif c == 22 then st.bold = false
    elseif c == 23 then st.italic = false
    elseif c == 24 then st.underline = false
    elseif c == 27 then st.reverse = false
    elseif c == 29 then st.strike = false
    elseif c == 39 then st.fg = nil
    elseif c == 49 then st.bg = nil
    elseif c and c >= 30 and c <= 37 then st.fg = BASE[c - 30]
    elseif c and c >= 40 and c <= 47 then st.bg = BASE[c - 40]
    elseif c and c >= 90 and c <= 97 then st.fg = BASE[c - 90 + 8]
    elseif c and c >= 100 and c <= 107 then st.bg = BASE[c - 100 + 8]
    elseif c == 38 or c == 48 then
      local target = (c == 38) and "fg" or "bg"
      local mode = codes[i + 1]
      if mode == 5 then
        st[target] = _x256(codes[i + 2] or 0)
        i = i + 2
      elseif mode == 2 then
        st[target] = string.format("#%02x%02x%02x",
          math.max(0, math.min(255, codes[i + 2] or 0)),
          math.max(0, math.min(255, codes[i + 3] or 0)),
          math.max(0, math.min(255, codes[i + 4] or 0)))
        i = i + 4
      end
    end
    i = i + 1
  end
end

--- 解析文本为「行」数组：每行 { text = 纯文本, spans = { {start_col, end_col, hl}, ... } }。
--- start_col/end_col 为 0-based 字节列（左闭右开）。含换行时按行切分。
--- @param text string
--- @return table 行数组
function M.parse(text)
  local lines = {}
  local cur = { text = "", spans = {} }
  local st = { fg = nil, bg = nil, bold = false, italic = false, underline = false, reverse = false, strike = false }
  local n = #text
  local i = 1
  while i <= n do
    local b = text:byte(i)
    if b == 27 then
      local nxt = text:sub(i + 1, i + 1)
      if nxt == "[" then
        local j = i + 2
        while j <= n and not text:sub(j, j):match("[%a]") do j = j + 1 end
        local final = text:sub(j, j)
        if final == "m" then _apply_sgr(st, text:sub(i + 2, j - 1)) end
        i = j + 1
      elseif nxt == "]" then
        local j = i + 2
        while j <= n do
          local ch = text:sub(j, j)
          if ch == "\7" then break end
          if ch == "\27" and text:sub(j + 1, j + 1) == "\\" then j = j + 1 break end
          j = j + 1
        end
        i = j + 1
      else
        i = i + 2
      end
    elseif b == 10 then
      lines[#lines + 1] = cur
      cur = { text = "", spans = {} }
      i = i + 1
    elseif b == 13 then
      i = i + 1
    else
      local j = i
      while j <= n do
        local c = text:byte(j)
        if c == 27 or c == 10 or c == 13 then break end
        j = j + 1
      end
      local run = text:sub(i, j - 1)
      local hl = _ensure_hl(st)
      if hl and #run > 0 then
        local s = #cur.text
        cur.text = cur.text .. run
        cur.spans[#cur.spans + 1] = { s, #cur.text, hl }
      else
        cur.text = cur.text .. run
      end
      i = j
    end
  end
  lines[#lines + 1] = cur
  return lines
end

--- 剥离全部 ANSI 转义序列，返回纯文本。
--- @param text string
--- @return string
function M.strip(text)
  local out = {}
  for _, l in ipairs(M.parse(text)) do out[#out + 1] = l.text end
  return table.concat(out, "\n")
end

--- 文本是否含 ANSI 转义序列
--- @param text string
--- @return boolean
function M.has_ansi(text)
  return type(text) == "string" and text:find("\27", 1, true) ~= nil
end

--- 重置高亮组缓存（测试用）
function M.reset()
  hl_cache = {}
  hl_count = 0
end

return M
