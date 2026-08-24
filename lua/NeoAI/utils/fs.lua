--- 文件系统操作
--- @module NeoAI.utils.fs
--- 纯工具函数，封装 vim.fn 与 io 的文件操作，含 JSONL 追加/撕裂行恢复。
--- 同步版本供内部/测试使用；异步版本（*_async）把阻塞式 I/O 移出 nvim 主线程，
--- 经 utils.work 在线程池执行，避免大文件 / 递归搜索卡住主界面。

local work = require("NeoAI.utils.work")

local M = {}

-- ========== 基础 ==========

--- 判断文件是否存在
--- @param path string
--- @return boolean
function M.exists(path)
  return vim.fn.filereadable(path) == 1
end

--- 判断目录是否存在
--- @param path string
--- @return boolean
function M.is_dir(path)
  return vim.fn.isdirectory(path) == 1
end

--- 确保目录存在（递归创建）
--- @param path string
--- @return boolean, string|nil
function M.ensure_dir(path)
  if M.is_dir(path) then return true end
  local ok, err = pcall(vim.fn.mkdir, path, "p")
  if not ok then return false, err end
  return true
end

--- 读取整个文件
--- @param path string
--- @return string|nil, string|nil 内容, 错误
function M.read_file(path)
  local ok, data = pcall(function()
    local f = io.open(path, "rb")
    if not f then error("无法打开文件: " .. path) end
    local content = f:read("*a")
    f:close()
    return content
  end)
  if not ok then return nil, data end
  return data
end

--- 写入整个文件（覆盖）
--- @param path string
--- @param content string
--- @return boolean, string|nil
function M.write_file(path, content)
  local ok, err = pcall(function()
    local f = io.open(path, "wb")
    if not f then error("无法打开文件: " .. path) end
    f:write(content)
    f:close()
  end)
  if not ok then return false, err end
  return true
end

--- 追加内容到文件末尾
--- @param path string
--- @param content string
--- @return boolean, string|nil
function M.append_file(path, content)
  local ok, err = pcall(function()
    local f = io.open(path, "ab")
    if not f then error("无法打开文件: " .. path) end
    f:write(content)
    f:close()
  end)
  if not ok then return false, err end
  return true
end

--- 删除文件
--- @param path string
--- @return boolean, string|nil
function M.delete_file(path)
  local ok, err = pcall(vim.fn.delete, path)
  if not ok then return false, err end
  return true
end

-- ========== JSONL ==========

--- 读取 JSONL 文件，返回对象数组
--- @param path string
--- @return table 数组
function M.read_jsonl(path)
  local data = M.read_file(path)
  if not data then return {} end
  local json = require("NeoAI.utils.json")
  local out = {}
  for line in data:gmatch("[^\r\n]+") do
    local obj = json.decode_line(line)
    if obj then
      out[#out + 1] = obj
    end
  end
  return out
end

--- 追加一行 JSON 到 JSONL 文件
--- @param path string
--- @param obj table
--- @return boolean, string|nil
function M.append_jsonl(path, obj)
  local json = require("NeoAI.utils.json")
  return M.append_file(path, json.encode(obj) .. "\n")
end

--- 修复 JSONL 文件末尾可能撕裂的不完整行
--- 崩溃时最后一行可能不完整，截断即可
--- @param path string
--- @return boolean 是否有撕裂行被截断
function M.repair_jsonl(path)
  if not M.exists(path) then return false end
  local f = io.open(path, "rb")
  if not f then return false end
  local content = f:read("*a")
  f:close()
  if content:sub(-1) == "\n" then return false end
  local last_nl = content:find("[^\r\n]*$")
  local trailing = content:sub(last_nl)
  if trailing == "" then return false end
  local json = require("NeoAI.utils.json")
  local ok = json.decode_line(trailing) ~= nil
  if ok then return false end
  local cut = content:sub(1, last_nl - 1)
  M.write_file(path, cut)
  return true
end

-- ========== 其它 ==========

--- 复制文件（失败时尝试备份）
--- @param src string
--- @param dst string
--- @return boolean, string|nil
function M.copy_file(src, dst)
  local ok, err = pcall(vim.fn.copyfile, src, dst, true)
  if not ok then return false, err end
  return true
end

--- 列出目录内容
--- @param path string
--- @return table 数组
function M.list_dir(path)
  local entries = vim.fn.readdir(path) or {}
  table.sort(entries)
  return entries
end

--- 拼接路径
--- @param ... string
--- @return string
function M.join(...)
  local parts = { ... }
  local out = ""
  for i, p in ipairs(parts) do
    if p and p ~= "" then
      if i > 1 then
        if out:sub(-1) == "/" then
          out = out .. p
        else
          out = out .. "/" .. p
        end
      else
        out = p
      end
    end
  end
  return out
end

--- 获取文件扩展名
--- @param path string
--- @return string
function M.ext(path)
  return path:match("%.([^.\\/]+)$") or ""
end

--- 获取文件名
--- @param path string
--- @return string
function M.basename(path)
  return path:match("[^/\\]+$") or path
end

--- 获取目录部分
--- @param path string
--- @return string
function M.dirname(path)
  local dir = path:match("^(.*)[/\\][^/\\]+$")
  return dir or "."
end

-- ========== 异步（线程池） ==========

-- 线程内自包含工作函数：纯 Lua + vim.uv（fs_scandir），不能依赖外部模块/upvalue。
-- 每个工作函数接收原始类型参数，返回 string。

--- 线程内递归列出目录（含子目录）
--- @param dir string 起始目录
--- @param max number 最大条数（0 = 不限）
--- @return string 每行一条路径
local function _list_worker(dir, max)
  local out = {}
  local count = 0
  local limit = max and max > 0 and max or math.huge
  local function walk(path)
    if count >= limit then return end
    local handle = vim.uv.fs_scandir(path)
    if not handle then return end
    while true do
      local name, t = vim.uv.fs_scandir_next(handle)
      if not name then break end
      if count >= limit then return end
      local full = path .. "/" .. name
      if t == "directory" then
        out[#out + 1] = full .. "/"
        count = count + 1
        walk(full)
      else
        out[#out + 1] = full
        count = count + 1
      end
    end
  end
  walk(dir)
  return table.concat(out, "\n")
end

--- 线程内递归搜索文件内容
--- @param dir string 起始目录
--- @param query string 搜索关键字（plain 匹配）
--- @param include_pat string|"" 文件名匹配的 lua pattern（主线程用 stringx.glob_to_pattern 预编译；空则不过滤）
--- @param max number 最大条数
--- @return string 每行一条：路径 + 匹配片段
local function _search_worker(dir, query, include_pat, max)
  local out = {}
  local count = 0
  local limit = max and max > 0 and max or 50
  local inc_pat = include_pat or ""
  if inc_pat ~= "" then
    -- glob 已在主线程转成 anchored lua pattern；这里按文件名匹配
  end
  local function walk(path)
    if count >= limit then return end
    local handle = vim.uv.fs_scandir(path)
    if not handle then return end
    while true do
      local name, t = vim.uv.fs_scandir_next(handle)
      if not name then break end
      if count >= limit then return end
      local full = path .. "/" .. name
      if t == "directory" then
        walk(full)
      elseif t == "file" then
        if inc_pat == "" or name:match(inc_pat) then
          local f = io.open(full, "rb")
          if f then
            local content = f:read("*a")
            f:close()
            if content and content:find(query, 1, true) then
              local pos = content:find(query, 1, true)
              local snippet = content:sub(pos, pos + 200)
              snippet = snippet:gsub("[\n\r]+", " ")
              out[#out + 1] = full .. ": " .. snippet
              count = count + 1
            end
          end
        end
      end
    end
  end
  walk(dir)
  if #out == 0 then return "未找到匹配内容" end
  return table.concat(out, "\n")
end

--- 线程内读取文件（可指定行范围）
--- @param filepath string
--- @param start_line number|0 起始行（1-based；0 = 不限制）
--- @param end_line number|0 结束行（1-based；0 = 不限制）
--- @return string 文件内容（或选中行拼接）
local function _read_worker(filepath, start_line, end_line)
  local f = io.open(filepath, "rb")
  if not f then error("无法打开文件: " .. filepath) end
  local content = f:read("*a")
  f:close()
  if start_line and start_line > 0 then
    -- 与 vim.split(content, "\n", {plain=true}) 行为一致：保留空行、末尾换行产生空行
    local lines = {}
    for line in (content .. "\n"):gmatch("(.-)\n") do
      lines[#lines + 1] = line
    end
    local start = start_line
    local finish = end_line and end_line > 0 and end_line or #lines
    start = math.max(1, start)
    finish = math.min(#lines, finish)
    local selected = {}
    for i = start, finish do selected[#selected + 1] = lines[i] end
    content = table.concat(selected, "\n")
  end
  return content
end

--- 线程内写入文件
--- @param filepath string
--- @param content string
--- @return string "ok" 或抛错
local function _write_worker(filepath, content)
  local f = io.open(filepath, "wb")
  if not f then error("无法写入文件: " .. filepath) end
  f:write(content)
  f:close()
  return "ok"
end

--- 线程内追加文件
--- @param filepath string
--- @param content string
--- @return string "ok" 或抛错
local function _append_worker(filepath, content)
  local f = io.open(filepath, "ab")
  if not f then error("无法追加文件: " .. filepath) end
  f:write(content)
  f:close()
  return "ok"
end

--- 线程内删除文件
--- @param filepath string
--- @return string "ok" 或抛错
local function _delete_worker(filepath)
  local ok, err = vim.uv.fs_unlink(filepath)
  if not ok then error("无法删除文件: " .. filepath .. " (" .. tostring(err) .. ")") end
  return "ok"
end

--- 异步读取文件（线程池，不阻塞主线程）
--- @param filepath string
--- @return Deferred resolve(内容 string)
function M.read_file_async(filepath)
  return work.run(_read_worker, filepath, 0, 0)
end

--- 异步读取文件（带行范围）
--- @param filepath string
--- @param start_line number
--- @param end_line number
--- @return Deferred resolve(内容 string)
function M.read_file_lines_async(filepath, start_line, end_line)
  return work.run(_read_worker, filepath, start_line, end_line)
end

--- 异步写入文件
--- @param filepath string
--- @param content string
--- @return Deferred
function M.write_file_async(filepath, content)
  return work.run(_write_worker, filepath, content)
end

--- 异步追加文件
--- @param filepath string
--- @param content string
--- @return Deferred
function M.append_file_async(filepath, content)
  return work.run(_append_worker, filepath, content)
end

--- 异步删除文件
--- @param filepath string
--- @return Deferred
function M.delete_file_async(filepath)
  return work.run(_delete_worker, filepath)
end

--- 异步递归列出目录
--- @param dir string
--- @param max number|nil 最大条数（nil/0 = 不限）
--- @return Deferred resolve(每行一条路径 string)
function M.list_dir_async(dir, max)
  return work.run(_list_worker, dir, max or 0)
end

--- 异步递归搜索文件内容（线程池执行，避免递归遍历卡住主线程）
--- @param dir string 起始目录
--- @param query string 搜索关键字
--- @param opts table|nil { include?, max_results? }
--- @return Deferred resolve(每行一条 string)
function M.search_files_async(dir, query, opts)
  opts = opts or {}
  -- glob 在主线程预编译为 anchored lua pattern（stringx 支持 * ? {a,b}），
  -- 线程内只需 name:match(pattern)，避免在受限线程里重新实现 glob。
  local include_pat = ""
  local include = opts.include or ""
  include = include:gsub("^%s+", ""):gsub("%s+$", "")
  if include ~= "" then
    local stringx = require("NeoAI.utils.stringx")
    include_pat = stringx.glob_to_pattern(include)
  end
  return work.run(_search_worker, dir, query, include_pat, opts.max_results or 50)
end

return M
