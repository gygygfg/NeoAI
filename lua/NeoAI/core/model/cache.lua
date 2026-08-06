--- 模型列表本地缓存
--- @module NeoAI.core.model.cache
--- 将 API 获取的模型列表缓存到磁盘，网络失败时作为 fallback。
--- 纯文件操作 + 读取，无异步。

local fs = require("NeoAI.utils.fs")
local config_store = require("NeoAI.kernel.config_store")

local M = {}

-- ========== 私有函数 ==========

local function _cache_path(provider)
  local path = config_store.get("ai.model_refresh.cache_path")
    or (vim.fn.stdpath("cache") .. "/NeoAI/models")
  fs.ensure_dir(path)
  return fs.join(path, provider .. ".json")
end

-- ========== 公开 API ==========

--- 读取缓存
--- @param provider string
--- @return table|nil { updated_at, models = {...} }
function M.read(provider)
  local path = _cache_path(provider)
  if not fs.exists(path) then return nil end
  local data = fs.read_file(path)
  if not data then return nil end
  local json = require("NeoAI.utils.json")
  local obj, err = json.decode_or_nil(data)
  if err or not obj then return nil end
  return obj
end

--- 写入缓存
--- @param provider string
--- @param models table 模型 id 数组
--- @return boolean
function M.write(provider, models)
  local path = _cache_path(provider)
  local data = {
    updated_at = os.time(),
    provider = provider,
    models = models,
  }
  local json = require("NeoAI.utils.json")
  return fs.write_file(path, json.encode(data))
end

--- 清空缓存
--- @param provider string|nil
function M.clear(provider)
  if provider then
    fs.delete_file(_cache_path(provider))
    return
  end
  local path = config_store.get("ai.model_refresh.cache_path")
    or (vim.fn.stdpath("cache") .. "/NeoAI/models")
  if fs.is_dir(path) then
    for _, file in ipairs(fs.list_dir(path)) do
      fs.delete_file(fs.join(path, file))
    end
  end
end

--- 缓存是否新鲜（在 TTL 内）
--- @param provider string
--- @param ttl_sec number|nil 秒
--- @return boolean
function M.is_fresh(provider, ttl_sec)
  local data = M.read(provider)
  if not data or not data.updated_at then return false end
  ttl_sec = ttl_sec or 3600
  return (os.time() - data.updated_at) < ttl_sec
end

return M
