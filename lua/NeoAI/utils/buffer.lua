--- Neovim buffer 引用工具
--- @module 'NeoAI.utils.buffer'
--- 为 `#{buffer:...}` 上下文引用与 `nvim` 镜像工具提供统一的 buffer 模型：
---   * `find()`：按 bufnr / 绝对路径 / 路径后缀 / basename 定位（多命中全部返回）；
---   * `object()`：只取元数据（bufnr/name/filetype/modified/lines/changedtick/cursor），
---     **绝不返回内容**；
---   * `describe()`：把对象格式化成交给模型的稳定文本；
---   * `content()` / `read()`：实时读取（含未保存修改），供镜像工具注入使用。
---
--- 这里只做「普通编辑 buffer」：NeoAI 界面 buffer、后台加载 buffer、终端/提示符等特殊
--- buftype 一律排除，避免把 UI 文本或工具自身缓冲区泄露进上下文。

local fs = require("NeoAI.utils.fs")

local M = {}

-- ========== 私有函数 ==========

--- 是否为 NeoAI 自己的界面 buffer（标记或 filetype 前缀）。
--- @param buf number
--- @return boolean
local function _is_ui(buf)
  if vim.b[buf] and vim.b[buf].neoai_ui then return true end
  local ft = vim.bo[buf].filetype
  return type(ft) == "string" and ft:sub(1, 5) == "neoai"
end

--- 是否为普通编辑 buffer（排除 UI / 后台工具 buffer / 特殊 buftype）。
--- @param buf number
--- @return boolean
local function _is_normal(buf)
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return false end
  if _is_ui(buf) then return false end
  -- 后台加载（工具自身 buffer）不算用户 buffer；但用户把它显示到窗口后视为用户 buffer
  -- （用户可能开始编辑，未保存内容应进入 save-all 视图）。
  if vim.b[buf] and vim.b[buf].neoai_bg and vim.fn.bufwinid(buf) == -1 then return false end
  if vim.bo[buf].buftype ~= "" then return false end
  return true
end

--- buffer 对应的绝对路径（无名字返回 ""）。
--- @param buf number
--- @return string
local function _name(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if type(name) ~= "string" or name == "" then return "" end
  return vim.fn.fnamemodify(name, ":p")
end

--- 当前窗口中的光标位置（buffer 未显示时返回 nil）。
--- @param buf number
--- @return table|nil { row, col } 1-based
local function _cursor(buf)
  local win = vim.fn.bufwinid(buf)
  if type(win) ~= "number" or win <= 0 then return nil end
  local ok, pos = pcall(vim.api.nvim_win_get_cursor, win)
  if not ok or type(pos) ~= "table" then return nil end
  return { row = (pos[1] or 1), col = (pos[2] or 0) + 1 }
end

--- 是否为二进制 buffer（避免把 NUL/非法字节拼进文本）。
--- @param buf number
--- @return boolean
local function _is_binary(buf)
  if vim.bo[buf].binary then return true end
  local name = _name(buf)
  if name == "" or vim.fn.filereadable(name) ~= 1 then return false end
  local f = io.open(name, "rb")
  if not f then return false end
  local sample = f:read(8192) or ""
  f:close()
  return sample:find("\0", 1, true) ~= nil
end

-- ========== 公开 API ==========

--- 是否为 NeoAI 界面 buffer（供 UI/工具跳过）。
--- @param buf number
--- @return boolean
function M.is_ui(buf)
  return type(buf) == "number" and vim.api.nvim_buf_is_valid(buf) and _is_ui(buf)
end

--- 是否可作为「用户 buffer」引用/镜像（普通编辑 buffer）。
--- @param buf number
--- @return boolean
function M.is_normal(buf)
  return _is_normal(buf)
end

--- buffer 绝对路径（无名字返回 ""）。
--- @param buf number
--- @return string
function M.path(buf)
  if not _is_normal(buf) then return "" end
  return _name(buf)
end

--- 全部 buffer 的简要信息（供 `#{buffers}`；包含 UI/特殊 buffer，保持原有语义）。
--- @return table 数组 { bufnr, name, basename, loaded, buftype, filetype, modified }
function M.list()
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
        modified = vim.bo[buf].modified == true,
      }
    end
  end
  return out
end

--- 当前可供镜像/引用的普通 buffer（已加载优先；未加载的保留元数据）。
--- @return number[]
function M.normal_bufs()
  local out = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if _is_normal(buf) then out[#out + 1] = buf end
  end
  return out
end

--- 按名称/路径/bufnr 定位 buffer（多命中全部返回）。
--- 匹配规则（与历史 `#{buffer:NAME}` 一致）：完整路径（忽略大小写）、路径后缀、
--- basename 精确匹配；纯数字按 bufnr 解释。
--- @param arg string|nil
--- @return number[] 匹配到的 buffer 号数组
function M.find(arg)
  if type(arg) ~= "string" or arg == "" then return {} end
  local needle = arg:lower()
  if needle:match("^%d+$") then
    local buf = tonumber(needle)
    if buf and vim.api.nvim_buf_is_valid(buf) then return { buf } end
  end
  local hits, seen = {}, {}
  local abs_arg = fs.canonical(arg):lower()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if _is_normal(buf) then
      local full = vim.api.nvim_buf_get_name(buf):lower()
      if full ~= "" then
        local base = vim.fn.fnamemodify(full, ":t")
        local ok = full == needle or full:sub(-#needle) == needle or base == needle
        -- 也接受用户输入绝对路径（`~` 展开后比较）
        if not ok then
          ok = full == abs_arg or full:sub(-#abs_arg) == abs_arg
        end
        if ok and not seen[buf] then
          seen[buf] = true
          hits[#hits + 1] = buf
        end
      end
    end
  end
  return hits
end

--- 取 buffer 的对象元数据（不含内容）。
--- @param buf number
--- @return table|nil
function M.object(buf)
  if not _is_normal(buf) then return nil end
  local loaded = vim.api.nvim_buf_is_loaded(buf)
  local lines = 0
  if loaded then
    local ok, n = pcall(vim.api.nvim_buf_line_count, buf)
    if ok and type(n) == "number" then lines = n end
  end
  local ok, tick = pcall(vim.api.nvim_buf_get_changedtick, buf)
  return {
    bufnr = buf,
    name = _name(buf),
    filetype = vim.bo[buf].filetype,
    buftype = vim.bo[buf].buftype,
    loaded = loaded,
    modified = vim.bo[buf].modified == true,
    lines = lines,
    changedtick = ok and tick or 0,
    cursor = _cursor(buf),
  }
end

--- 把对象格式化为交给模型的文本（只含元数据，明确提示内容未内联）。
--- @param obj table
--- @return string
function M.describe(obj)
  if type(obj) ~= "table" then return "" end
  local name = obj.name ~= "" and obj.name or "[无名称]"
  local cursor = obj.cursor and ("%d:%d"):format(obj.cursor.row, obj.cursor.col) or "-"
  return table.concat({
    "【NeoAI buffer object】",
    ("id=%d name=%s filetype=%s buftype=%s"):format(
      obj.bufnr or 0, name, obj.filetype ~= "" and obj.filetype or "-",
      obj.buftype ~= "" and obj.buftype or "\"\""),
    ("loaded=%s modified=%s lines=%d changedtick=%d cursor=%s"):format(
      tostring(obj.loaded == true), tostring(obj.modified == true),
      obj.lines or 0, obj.changedtick or 0, cursor),
    ("（内容未内联；调用 nvim 工具时传 buffer_ids=[%d] 即可把这个对象加载进镜像）")
      :format(obj.bufnr or 0),
  }, "\n")
end

--- 读取实时 buffer 行（1-based，含两端；缺省全量）。未加载时返回 nil。
--- @param buf number
--- @param start_line number|nil
--- @param end_line number|nil
--- @return string[]|nil
function M.read(buf, start_line, end_line)
  if not _is_normal(buf) or not vim.api.nvim_buf_is_loaded(buf) then return nil end
  local total = vim.api.nvim_buf_line_count(buf)
  local s = math.max(1, tonumber(start_line) or 1)
  local e = math.min(total, tonumber(end_line) or total)
  if e < s then return {} end
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, s - 1, e, false)
  if not ok or type(lines) ~= "table" then return nil end
  return lines
end

--- 读取 buffer 全文（UTF-8 文本；保留 fileformat 的换行与末尾 eol）。
--- 未加载/二进制时返回 nil。
--- @param buf number
--- @return string|nil
function M.content(buf)
  if not _is_normal(buf) or not vim.api.nvim_buf_is_loaded(buf) then return nil end
  if _is_binary(buf) then return nil end
  local lines = M.read(buf, 1, vim.api.nvim_buf_line_count(buf))
  if not lines then return nil end
  if #lines == 1 and lines[1] == "" then return "" end
  local ff = vim.bo[buf].fileformat
  local sep = (ff == "dos") and "\r\n" or "\n"
  local text = table.concat(lines, sep)
  if vim.bo[buf].eol and text ~= "" then text = text .. sep end
  return text
end

--- 文本 SHA-256（十六进制；用于「是否与基线一致」判定）。
--- @param text string|nil
--- @return string|nil
function M.hash(text)
  if type(text) ~= "string" then return nil end
  local ok, hex = pcall(vim.fn.sha256, text)
  return ok and type(hex) == "string" and hex or nil
end

return M
