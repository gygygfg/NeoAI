--- 文件系统操作
--- @module NeoAI.utils.fs
--- 纯工具函数，封装 vim.fn 与 io 的文件操作，含 JSONL 追加/撕裂行恢复。

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

return M
