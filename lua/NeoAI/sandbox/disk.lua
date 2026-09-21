--- 沙箱磁盘用量与上限
--- @module NeoAI.sandbox.disk
--- 统计沙箱暂存总字节数（进程 overlay / 每会话私有 tmp 的暂存基目录 + 沙箱存储根：候选/待审/
--- 证据/服务 overlay 等），并按 `tools.sandbox.limits.disk_bytes`（默认 64 GiB，0 = 不限）
--- 做上限门禁：超限时拒绝新的外部进程/写类工具（`SANDBOX_DISK_LIMIT_EXCEEDED`），避免暂存
--- 撑满宿主磁盘。
---
--- 用量经工作线程异步递归统计并缓存（默认 5s TTL），门禁只读缓存、不在命令开始处做同步 du；
--- 尚无缓存时放行（best-effort，不因统计未就绪而阻断工具）。

local config_store = require("NeoAI.kernel.config_store")
local work = require("NeoAI.utils.work")

local M = {}

-- ========== 私有状态 ==========

local state = { bytes = nil, inflight = false }
local TTL_MS = 15000

-- ========== 私有函数 ==========

--- 配置的上限（字节）；<=0 表示不限。
--- @return number
local function _limit()
  local n = tonumber(config_store.get("tools.sandbox.limits.disk_bytes")) or 0
  return n
end

--- 递归统计目录占用（自包含，可在工作线程执行；仅用 vim.uv）。
--- @param path string
--- @return number
local function _size_worker(path)
  local uv = vim.uv
  local total = 0
  local stack = { path }
  while #stack > 0 do
    local p = table.remove(stack)
    local st = uv.fs_lstat(p)
    if st then
      if st.type == "directory" then
        local h = uv.fs_scandir(p)
        if h then
          while true do
            local name = uv.fs_scandir_next(h)
            if not name then break end
            stack[#stack + 1] = p .. "/" .. name
          end
        end
      elseif st.type == "file" then
        total = total + (tonumber(st.size) or 0)
      end
    end
  end
  return total
end

--- 需要统计的根：暂存基目录 + 沙箱存储基根（去重）。
--- @return table 字符串数组
local function _roots()
  local out, seen = {}, {}
  local function add(p)
    if type(p) == "string" and p ~= "" and not seen[p] then
      seen[p] = true
      out[#out + 1] = p
    end
  end
  pcall(function() add(require("NeoAI.sandbox.conceal").base_host()) end)
  pcall(function() add(require("NeoAI.sandbox").base_root()) end)
  return out
end

-- ========== 公开 API ==========

--- 触发一次异步用量统计（若已有在途任务或缓存未过期则跳过）。
--- @param force boolean|nil 忽略 TTL 强制刷新
function M.refresh(force)
  if state.inflight then return end
  if not force and state.bytes ~= nil and state.at and (vim.uv.hrtime() - state.at) < TTL_MS * 1e6 then
    return
  end
  state.inflight = true
  local roots = _roots()
  local function finish(total)
    state.inflight = false
    state.bytes = tonumber(total) or 0
    state.at = vim.uv.hrtime()
  end
  if #roots == 0 then
    finish(0)
    return
  end
  if not work.available() then
    local total = 0
    for _, r in ipairs(roots) do total = total + _size_worker(r) end
    finish(total)
    return
  end
  -- 工作函数自包含（会被 string.dump 到独立线程，不能引用模块级 upvalue）。
  work.run(function(encoded)
    local uv = vim.uv
    local function size(path)
      local total = 0
      local stack = { path }
      while #stack > 0 do
        local p = table.remove(stack)
        local st = uv.fs_lstat(p)
        if st then
          if st.type == "directory" then
            local h = uv.fs_scandir(p)
            if h then
              while true do
                local name = uv.fs_scandir_next(h)
                if not name then break end
                stack[#stack + 1] = p .. "/" .. name
              end
            end
          elseif st.type == "file" then
            total = total + (tonumber(st.size) or 0)
          end
        end
      end
      return total
    end
    local total = 0
    for r in encoded:gmatch("[^\n]+") do total = total + size(r) end
    return tostring(total)
  end, table.concat(roots, "\n")):then_(function(total) finish(total) end, function() finish(0) end)
end

--- 最近一次统计的用量（字节）；尚未统计时为 nil。
--- @return number|nil
function M.usage()
  return state.bytes
end

--- 配置的磁盘上限（字节）；<=0 = 不限。
--- @return number
function M.limit()
  return _limit()
end

--- 上限门禁：超限返回 false + 错误信息，否则 true。
--- 触发一次后台刷新，但只读缓存判定（不阻塞命令开始）。
--- @return boolean ok
--- @return string|nil err
function M.check()
  M.refresh()
  local limit = _limit()
  if limit <= 0 then return true end
  local used = state.bytes
  if used == nil then return true end
  if used >= limit then
    return false, string.format(
      "SANDBOX_DISK_LIMIT_EXCEEDED: 沙箱暂存已用 %.1f GiB ≥ 上限 %.1f GiB；"
      .. "请应用/拒绝待审候选（:NeoAISandboxReview）或清理过期候选（:NeoAISandboxPrune），"
      .. "也可调大 tools.sandbox.limits.disk_bytes",
      used / 1073741824, limit / 1073741824)
  end
  return true
end

--- 诊断信息快照。
--- @return table { used, limit, roots }
function M.info()
  return { used = state.bytes, limit = _limit(), roots = _roots() }
end

--- 重置（测试用）。
function M.reset()
  state.bytes = nil
  state.at = nil
  state.inflight = false
end

M._size_worker = _size_worker

return M
