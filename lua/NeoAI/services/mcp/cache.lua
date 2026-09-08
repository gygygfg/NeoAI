--- MCP 工具描述本地缓存 + pending/stale 状态
--- @module NeoAI.services.mcp.cache
--- 预缓存：连接前从磁盘缓存注册工具/资源/提示定义，避免「连接慢导致工具不可见」。
--- 动态更新：某服务器工具调用因参数 schema 变化失败时标记 stale，下一轮刷新前按
--- stale 重拉 tools/list 并覆盖已注册定义与缓存。

local json = require("NeoAI.utils.json")
local logger = require("NeoAI.kernel.logger")

local M = {}

local state = {
  path = nil,
  data = nil, -- { servers = { [name] = { tools, resources, prompts, updated_at } }, pending = {}, stale = {} }
  loaded = false,
}

-- ========== 私有函数 ==========

--- 读取缓存文件到内存
--- @return table
local function _read()
  if not state.path or vim.fn.filereadable(state.path) ~= 1 then
    return { servers = {}, pending = {}, stale = {} }
  end
  local ok, data = pcall(function()
    local f = io.open(state.path, "rb")
    if not f then error("无法打开缓存文件") end
    local content = f:read("*a")
    f:close()
    return json.decode(content)
  end)
  if not ok or type(data) ~= "table" then
    logger.warn("[mcp.cache] 缓存读取失败，忽略: %s", tostring(data))
    return { servers = {}, pending = {}, stale = {} }
  end
  data.servers = data.servers or {}
  data.pending = data.pending or {}
  data.stale = data.stale or {}
  return data
end

--- 写回缓存文件
local function _write()
  if not state.path then return end
  local ok, err = pcall(vim.fn.mkdir, vim.fn.fnamemodify(state.path, ":h"), "p")
  if not ok then return end
  local ok_e, encoded = pcall(json.encode, state.data)
  if not ok_e then return end
  local f = io.open(state.path, "wb")
  if not f then return end
  f:write(encoded)
  f:close()
end

-- ========== 公开 API ==========

--- 初始化缓存（读取到内存）<br/>
--- @param path string|nil 缓存文件路径（缺省读 config.mcp.cache_path）
function M.init(path)
  state.path = path
  state.data = _read()
  state.loaded = true
end

--- 确保已初始化（懒回退到默认路径）
local function _ensure()
  if state.loaded then return end
  local config = require("NeoAI.kernel.config_store")
  M.init(config and config.get("mcp.cache_path"))
end

--- 获取某服务器的缓存项
--- @param server string
--- @return table|nil { tools, resources, prompts, updated_at }
function M.get(server)
  _ensure()
  return state.data.servers[server]
end

--- 是否存在缓存（工具/资源/提示任一项），供启动时预注册
--- @param server string
--- @return boolean
function M.has(server)
  _ensure()
  local s = state.data.servers[server]
  if not s then return false end
  return (s.tools and #s.tools > 0) or (s.resources and #s.resources > 0) or (s.prompts and #s.prompts > 0)
end

--- 用某服务器的最新 capabilities 快照更新缓存 <br/>
--- 传入空列表表示该能力为空（覆盖旧值）；updated_at 由调用方传或取当前时间。
--- @param server string
--- @param snap table { tools?, resources?, prompts?, updated_at? }
function M.set(server, snap)
  _ensure()
  local s = state.data.servers[server] or {}
  if snap.tools ~= nil then s.tools = snap.tools end
  if snap.resources ~= nil then s.resources = snap.resources end
  if snap.prompts ~= nil then s.prompts = snap.prompts end
  s.updated_at = snap.updated_at or os.time()
  state.data.servers[server] = s
  _write()
end

--- 覆盖全部能力快照（连接刷新时统一写入，兼做 pending→ready 清除）
--- @param server string
--- @param snap table { tools, resources, prompts }
function M.update_all(server, snap)
  _ensure()
  state.data.servers[server] = {
    tools = snap.tools or {},
    resources = snap.resources or {},
    prompts = snap.prompts or {},
    updated_at = os.time(),
  }
  state.data.pending[server] = nil
  state.data.stale[server] = nil
  _write()
end

-- ========== pending / stale 状态 ==========

--- 标记服务器待连接（未完成初始化）
--- @param server string
function M.mark_pending(server)
  _ensure()
  state.data.pending[server] = true
  _write()
end

--- 是否待连接
--- @param server string
--- @return boolean
function M.is_pending(server)
  _ensure()
  return state.data.pending[server] == true
end

--- 标记服务器工具描述过期（调用结果提示 schema 变化）
--- @param server string
function M.mark_stale(server)
  _ensure()
  state.data.stale[server] = true
  _write()
end

--- 是否有服务器处于 stale
--- @return boolean
function M.has_stale()
  _ensure()
  return next(state.data.stale) ~= nil
end

--- 列出 stale 服务器名
--- @return table 数组
function M.stale_servers()
  _ensure()
  local out = {}
  for name, v in pairs(state.data.stale) do
    if v then out[#out + 1] = name end
  end
  return out
end

--- 清除某服务器的 stale 标记
--- @param server string
function M.clear_stale(server)
  _ensure()
  state.data.stale[server] = nil
  _write()
end

--- 判断某服务器是否 stale
--- @param server string
--- @return boolean
function M.is_stale(server)
  _ensure()
  return state.data.stale[server] == true
end

--- 重置（测试用）
function M.reset()
  state.path = nil
  state.data = nil
  state.loaded = false
end

return M
