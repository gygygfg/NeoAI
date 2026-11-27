--- 单视图模型（三视图）：真实盘 / 沙箱合并视图 / 候选
--- @module 'NeoAI.sandbox.execution.view'
---
--- 旧模型里「工作区暂存副本」与「overlay upper」是两份可写数据，每条命令前把暂存物化进
--- upper、命令后再把 upper 捕获拷回暂存（`materialize_overlay` / `capture_overlay_async` /
--- `merge_candidate`），指令轮次越多拷贝越多、upper 越滚越大，最终把编辑器内存/磁盘吃穿
--- （实测 nvim RSS 涨到 27.7GB 被内核 OOM 杀死）。
---
--- 单视图把**暂存目录本身**作为 overlay 的 upper：AI 编辑与命令写入落在同一个可写层，
--- 于是：
---   * 视图 1（真实盘）  只读 lower，发布的唯一落点；
---   * 视图 2（沙箱视图）= 暂存 = upper，命令/只读工具/LSP 共用同一份合并视图；
---   * 视图 3（候选）    只保存 delta 元数据（路径/动作/哈希/权限），内容按需从视图 2 读取。
---
--- 不变量：
---   1. 每个沙箱会话只存在一个视图根（本模块持有），不再为每条命令新建 overlay；
---   2. agentEnd 不迁移暂存（视图原地保留），轮次占用不叠加；
---   3. 发布/拒绝只清理 delta 台账，不整树回写。
---
--- 该模块只做「视图根登记 + 路径映射」，具体执行仍在 `candidate`/`wrapper`。

local M = {}

-- ========== 私有状态 ==========

local state = {
  base = nil, -- 视图基目录（稳定，不随会话轮换）
  roots = {}, -- { { root, upper, work, bind, mode } }：可写根 → 视图层
  mkdir_cache = {}, -- 已确保存在的目录（避免逐文件 mkdir）
  registered_at = 0, -- 最近一次登记版本（诊断用）
}

-- ========== 私有函数 ==========

local function _cfg_get(key)
  local ok, v = pcall(function()
    return require("NeoAI.kernel.config_store").get("tools.sandbox." .. key)
  end)
  if ok then return v end
  return nil
end

local function _mkdir(path)
  -- 不缓存「已创建」：目录可能被外部/测试删除（甚至被 reset 清掉），缓存会导致后续写入
  -- 落到不存在的目录（ENOENT/悬住）。`mkdir -p` 对已存在目录是幂等便宜操作。
  pcall(vim.fn.mkdir, path, "p")
end

--- 路径是否位于给定根之下（含根自身）
--- @param p string
--- @param root string
--- @return boolean
local function _under(p, root)
  if type(p) ~= "string" or type(root) ~= "string" then return false end
  -- 整机根 overlay（root="/"）：`root .. "/"` 会变成 "//"，前缀判定恒假，
  -- 使 root="/" 视图永远无法映射（所有路径都回退旧暂存副本）。根做特判。
  if root == "/" then return p:sub(1, 1) == "/" end
  return p == root or p:sub(1, #root + 1) == root .. "/"
end

--- 可写根内的相对路径（root="/" 时去掉开头斜杠）
--- @param real string
--- @param root string
--- @return string
local function _rel(real, root)
  if root == "/" then return real:sub(2) end
  return real:sub(#root + 2)
end

-- ========== 公开 API ==========

--- 是否启用单视图（默认开；`tools.sandbox.single_view=false` 回退旧的双份暂存模型）。
--- @return boolean
function M.enabled()
  -- 运维/测试逃生阀：`NEOAI_SINGLE_VIEW=0` 强制回退旧模型，无需改配置。
  if vim.env.NEOAI_SINGLE_VIEW == "0" then return false end
  return _cfg_get("single_view") ~= false
end

--- 视图基目录（稳定；不随 agentEnd 轮换）。位于沙箱隐藏暂存基目录之下，绝不在工作区内。
--- @return string
function M.base()
  if state.base then
    -- 基目录可能被 `candidate.reset()`/清理器删除：缓存路径前先校验，必要时重建并清空
    -- mkdir 缓存（否则 `path_for` 以为目录已建、写入报 ENOENT，工具调用悬住）。
    if vim.fn.isdirectory(state.base) == 1 then return state.base end
    state.mkdir_cache = {}
  end
  local host = require("NeoAI.sandbox.observe.conceal").base_host()
  local dir = (host:gsub("/+$", "")) .. "/view"
  _mkdir(dir)
  pcall(function()
    require("NeoAI.sandbox.execution.runtime").chown_payload(dir)
  end)
  state.base = dir
  return dir
end

--- 视图是否已经登记过可写根。
--- @return boolean
function M.ready()
  return #state.roots > 0
end

--- 登记本次构建的可写根（只接受属于本视图基目录的 overlay/bind 规格）。
--- 后登记的非空结果覆盖先前结果：同一次构建里 root 集合可能随阶段包根变化。
--- @param specs table|nil `wrapper.build_overlay_specs` 的返回值
function M.register(specs)
  if not M.enabled() or type(specs) ~= "table" then return end
  local base = M.base()
  local roots = {}
  for _, s in ipairs(specs) do
    if type(s) == "table" and s.upper and _under(s.upper, base) then
      -- 只登记**规范视图**（`<base>/<encoded-root>/upper`）。一次性 attempt 的临时 upper
      -- （`<base>/attempt_<id>/...`）不是暂存，不能被登记成「视图路径」——否则
      -- `is_native()` 会把一次性 upper 误判为视图，物化跳过删除 whiteout，命令就又能看到
      -- 被暂存删除的真实文件。
      if not s.upper:find("/attempt_", 1, true) then
        roots[#roots + 1] = {
          root = tostring(s.root or "/"),
          upper = s.upper,
          work = s.work,
          bind = s.bind,
          mode = s.mode or "overlay",
        }
      end
    end
  end
  if #roots > 0 then
    state.roots = roots
    state.registered_at = (state.registered_at or 0) + 1
  end
end

--- 当前已登记的可写根（拷贝，供只读诊断）。
--- @return table
function M.roots()
  local out = {}
  for i, s in ipairs(state.roots) do out[i] = { root = s.root, upper = s.upper, mode = s.mode } end
  return out
end

--- 命中给定真实路径的视图根（最长前缀优先）。
--- @param real string
--- @return table|nil spec
function M.match(real)
  if type(real) ~= "string" or real == "" then return nil end
  local best
  for _, s in ipairs(state.roots) do
    if _under(real, s.root) then
      if not best or #s.root > #best.root then best = s end
    end
  end
  if not best then return nil end
  -- 私有 tmpfs 根（/tmp、/var/tmp 等）在沙箱内由会话私有目录覆盖：**整机根 overlay** 下
  -- 这些路径与宿主不一致，绝不映射（保持「tmpfs 根回退旧暂存」不变量）。若 cwd 等根本身
  -- 位于 tmpfs 并为它建立了独立 overlay，则按更长的具体根映射（best 不是 "/"）。
  if best.root == "/" then
    local okr, runtime = pcall(require, "NeoAI.sandbox.execution.runtime")
    if okr and runtime and type(runtime.tmpfs_roots) == "function" then
      local ok, roots = pcall(runtime.tmpfs_roots)
      if ok and type(roots) == "table" then
        for _, r in ipairs(roots) do
          if _under(real, r) then return nil end
        end
      end
    end
  end
  return best
end

--- 真实路径在视图（overlay upper）中的宿主路径；不覆盖时返回 nil（调用方回退旧暂存）。
--- @param real string
--- @return string|nil path
--- @return table|nil spec
function M.path_for(real)
  if not M.enabled() then return nil end
  local s = M.match(real)
  if not s or not s.upper then return nil end
  if s.mode ~= "overlay" and s.mode ~= "fuse" then return nil end
  -- 视图 upper 之下的路径本身就是真实盘路径（如沙箱存储根）时无法再映射，交给旧路径。
  if _under(real, s.upper) or _under(real, s.work or "") then return nil end
  local p = s.upper .. "/" .. _rel(real, s.root)
  _mkdir(vim.fn.fnamemodify(p, ":h"))
  return p, s
end

--- 路径是否落在任一视图层内（upper/work）。用于跳过已合一的暂存拷贝与镜像。
--- @param path string|nil
--- @return boolean
function M.is_native(path)
  if type(path) ~= "string" or path == "" then return false end
  for _, s in ipairs(state.roots) do
    if _under(path, s.upper) then return true end
  end
  return false
end

--- 视图 upper 是否就是给定 upper（capture/freeze 判定用）。
--- @param upper string|nil
--- @return boolean
function M.owns_upper(upper)
  if type(upper) ~= "string" then return false end
  for _, s in ipairs(state.roots) do
    if s.upper == upper then return true end
  end
  return false
end

--- 重置（测试/卸载用）：只清内存登记，视图目录保留（未发布改动是同进程/跨重载的数据）。
function M.reset()
  state.roots = {}
  state.mkdir_cache = {}
  state.registered_at = 0
end

--- 彻底删除视图目录（测试/显式清理用）。
--- @return boolean
function M.destroy()
  local dir = state.base
  M.reset()
  state.base = nil
  if not dir then return true end
  local ok = pcall(vim.fn.delete, dir, "rf")
  return ok
end

--- 诊断信息（`:NeoAI SandboxDiag` / 测试）。
--- @return table
function M.info()
  return {
    enabled = M.enabled(),
    base = state.base,
    roots = M.roots(),
    registered_at = state.registered_at,
  }
end

return M
