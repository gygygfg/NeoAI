--- 沙箱内容寻址缓存
--- @module NeoAI.sandbox.cache
--- 依赖/产物按内容寻址缓存；写入方隔离，未验证内容不污染共享可信缓存（设计文档 §12）。
--- 键必须覆盖输入、运行时、规则与事实；授权与撤销状态不可通过旧缓存跳过。

local json = require("NeoAI.utils.json")
local fs = require("NeoAI.utils.fs")

local M = {}

-- ========== 私有状态 ==========

local state = { root = nil }

-- ========== 私有函数 ==========

local function _dir()
  return (state.root or (vim.fn.stdpath("cache") .. "/NeoAI/sandbox")) .. "/cache"
end

local function _canonical(value)
  if type(value) == "table" then
    if vim.islist(value) then
      local parts = {}
      for _, v in ipairs(value) do parts[#parts + 1] = _canonical(v) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(value) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = json.encode_fast(k) .. ":" .. _canonical(value[k]) end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  if type(value) == "string" then return json.encode_fast(value) end
  if value == nil then return "null" end
  return tostring(value)
end

local function _key_of(inputs)
  local ok, hex = pcall(vim.fn.sha256, _canonical(inputs))
  return ok and hex or "invalid"
end

local function _path(key)
  return _dir() .. "/" .. key
end

-- ========== 公开 API ==========

--- 初始化缓存根
--- @param root string
function M.init(root)
  state.root = root
  fs.ensure_dir(_dir())
end

--- 计算内容键（覆盖输入/运行时/规则/事实）
--- @param inputs table
--- @return string hex
function M.key(inputs)
  return _key_of(inputs)
end

--- 读取缓存
--- @param key string
--- @return string|nil content
function M.get(key)
  return fs.read_file(_path(key))
end

--- 判断缓存是否存在
--- @param key string
--- @return boolean
function M.has(key)
  return vim.fn.filereadable(_path(key)) == 1
end

--- 写入缓存（原子写；隔离写入方）
--- @param key string
--- @param content string
--- @return boolean ok
function M.put(key, content)
  fs.ensure_dir(_dir())
  return fs.write_file_atomic(_path(key), content)
end

--- 列出缓存条目
--- @return table 数组 { key, size }
function M.list()
  local out = {}
  local handle = vim.uv.fs_scandir(_dir())
  if not handle then return out end
  while true do
    local name = vim.uv.fs_scandir_next(handle)
    if not name then break end
    local stat = vim.uv.fs_stat(_path(name))
    out[#out + 1] = { key = name, size = stat and stat.size or 0 }
  end
  return out
end

--- 清理过期缓存
--- @param days number
--- @return number removed
function M.prune(days)
  local cutoff = os.time() - (days or 7) * 86400
  local removed = 0
  for _, entry in ipairs(M.list()) do
    local stat = vim.uv.fs_stat(_path(entry.key))
    if stat and stat.mtime and stat.mtime.sec < cutoff then
      if fs.delete_file(_path(entry.key)) then removed = removed + 1 end
    end
  end
  return removed
end

--- 重置（测试用）
function M.reset()
  if state.root then pcall(vim.fn.delete, _dir(), "rf") end
  state.root = nil
end

return M
