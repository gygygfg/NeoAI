--- 删除搬出层（retire）：删除不是销毁
--- @module 'NeoAI.sandbox.execution.retired'
---
--- 取消「逐个文件删除目录树」：被删节点（文件/整棵目录）只做一次 **rename**，搬到同盘的隐藏目录
--- `<parent>/.neoai-retired/<change_set>/<name>`。撤销时再 rename 回原路径。三个视图因此只交换
--- 「节点」，互不展开：
---   * 宿主机：原路径消失，内容完整保留在搬出层（从不 unlink）；
---   * 沙箱：只在该节点留一个 whiteout（子树由内核遮蔽）；
---   * 审批：一条节点条目。
---
--- 同父目录保证 rename 同盘、原子、无遍历，因此没有「子先于父」排序依赖，也不会出现
--- `RMDIR_NOT_EMPTY`。搬出层内含内容为 `*` 的 `.gitignore` 与 `.neoai-owner` 标记，对 git
--- 完全不可见（也不会被误认成用户的同名目录）。

local fs = require("NeoAI.utils.fs")
local json = require("NeoAI.utils.json")

local M = {}

--- 搬出层目录名（冲突时追加 `-2`、`-3`…）。
M.DIRNAME = ".neoai-retired"

local OWNER_FILE = ".neoai-owner"
local GITIGNORE_FILE = ".gitignore"
local OWNER_MARK = "NeoAI retired layer\n"
local REGISTRY_FILE = "retired.json"
local MAX_CONTAINERS = 32

--- 路径父目录（绝对路径；`/a` → `/`）。
--- @param path string
--- @return string
local function _parent(path)
  local dir = path:match("^(.*)/[^/]*$")
  if dir == nil or dir == "" then return "/" end
  return dir
end

--- 路径是否为搬出层目录本身或位于其中。
--- @param path string|nil
--- @return boolean
function M.is_retired_path(path)
  if type(path) ~= "string" or path == "" then return false end
  for seg in path:gmatch("[^/]+") do
    if seg == M.DIRNAME or seg:match("^%.neoai%-retired%-%d+$") then return true end
  end
  return false
end

-- ========== 登记表（实例存储内） ==========

--- 登记文件路径（未初始化 store 时返回 nil）。
--- @return string|nil
local function _registry_path()
  local ok, store = pcall(require, "NeoAI.sandbox.state.store")
  if not ok or not store or type(store.root) ~= "function" then return nil end
  local root = store.root()
  if type(root) ~= "string" or root == "" then return nil end
  return (root:gsub("/+$", "")) .. "/" .. REGISTRY_FILE
end

--- @return table { [change_set_id] = { { node, retired, at }, ... } }
local function _read_registry()
  local path = _registry_path()
  if not path then return {} end
  local raw = fs.read_file(path)
  if type(raw) ~= "string" or raw == "" then return {} end
  local ok, data = pcall(json.decode, raw)
  if not ok or type(data) ~= "table" then
    -- 登记表损坏（外部篡改/半写）：忽略并告警。搬出内容仍在磁盘上（按目录名可人工恢复），
    -- 只是自动回收/撤销不再追踪它。
    pcall(function()
      require("NeoAI.kernel.logger").warn("[sandbox] 搬出登记表损坏，已忽略: %s", tostring(path))
    end)
    return {}
  end
  return data
end

--- @param data table
--- @return boolean
local function _write_registry(data)
  local path = _registry_path()
  if not path then return false end
  local ok, raw = pcall(json.encode_fast, data)
  if not ok or type(raw) ~= "string" then return false end
  local wok = fs.write_file_atomic(path, raw)
  return wok == true
end

--- 登记一次成功搬出，供幂等重试与生命周期回收。
--- @param change_set_id string|nil
--- @param node string 原路径
--- @param retired string 搬出后的路径
--- @return boolean
function M.record(change_set_id, node, retired)
  if type(node) ~= "string" or type(retired) ~= "string" then return false end
  local cs = (type(change_set_id) == "string" and change_set_id ~= "") and change_set_id or "default"
  local data = _read_registry()
  local list = data[cs]
  if type(list) ~= "table" then list = {}; data[cs] = list end
  for _, e in ipairs(list) do
    if type(e) == "table" and e.node == node then
      e.retired, e.at = retired, os.time()
      return _write_registry(data)
    end
  end
  list[#list + 1] = { node = node, retired = retired, at = os.time() }
  return _write_registry(data)
end

--- 查询某变更单元对某节点已记录的搬出路径（幂等重试用）。
--- 变更单元可能因「部分应用回队」换了 id：精确未命中时按节点全局回退（且搬出内容仍存在）。
--- @param change_set_id string|nil
--- @param node string
--- @return string|nil
function M.lookup(change_set_id, node)
  local cs = (type(change_set_id) == "string" and change_set_id ~= "") and change_set_id or "default"
  local data = _read_registry()
  local function _hit(list)
    for _, e in ipairs(list or {}) do
      if type(e) == "table" and e.node == node and type(e.retired) == "string"
        and vim.uv.fs_lstat(e.retired) ~= nil then
        return e.retired
      end
    end
    return nil
  end
  local found = _hit(data[cs])
  if found then return found end
  for _, list in pairs(data) do
    found = _hit(list)
    if found then return found end
  end
  return nil
end

--- 按搬出路径反查登记（撤销后清理登记）。
--- @param retired string
--- @return string|nil change_set_id
--- @return string|nil node
function M.find_by_retired(retired)
  if type(retired) ~= "string" then return nil end
  local data = _read_registry()
  for cs, list in pairs(data) do
    for _, e in ipairs(list or {}) do
      if type(e) == "table" and e.retired == retired then return cs, e.node end
    end
  end
  return nil
end

--- 最近一次搬出的时间（TTL 判定用）。
--- @param change_set_id string|nil
--- @return number|nil
function M.last_at(change_set_id)
  local cs = (type(change_set_id) == "string" and change_set_id ~= "") and change_set_id or "default"
  local data = _read_registry()
  local at
  for _, e in ipairs(data[cs] or {}) do
    local t = tonumber(type(e) == "table" and e.at or nil)
    if t and (not at or t > at) then at = t end
  end
  return at
end

--- 移除登记项（撤销搬回后调用）。
--- @param retired string 搬出路径
--- @return boolean
function M.forget_retired(retired)
  if type(retired) ~= "string" then return false end
  local data = _read_registry()
  local changed = false
  for cs, list in pairs(data) do
    local out = {}
    for _, e in ipairs(list or {}) do
      if type(e) == "table" and e.retired == retired then
        changed = true
      else
        out[#out + 1] = e
      end
    end
    data[cs] = (#out > 0) and out or nil
  end
  if not changed then return true end
  return _write_registry(data)
end

-- ========== 容器与规划 ==========

--- 容器是否由本模块创建（带 owner 标记）。
--- @param dir string
--- @return boolean
local function _is_ours(dir)
  local st = vim.uv.fs_lstat(dir)
  if not st or st.type ~= "directory" then return false end
  return fs.read_file(dir .. "/" .. OWNER_FILE) == OWNER_MARK
end

--- 选择/计算可用的搬出容器（不创建）。已存在的非本模块同名目录会顺延后缀。
--- @param parent string
--- @return string|nil
local function _choose_container(parent)
  for i = 1, MAX_CONTAINERS do
    local name = (i == 1) and M.DIRNAME or (M.DIRNAME .. "-" .. i)
    local dir = (parent == "/") and ("/" .. name) or (parent .. "/" .. name)
    local st = vim.uv.fs_lstat(dir)
    if not st then return dir end
    if st.type == "directory" and _is_ours(dir) then return dir end
  end
  return nil
end

--- 计算搬出计划（纯计算：不创建目录、不移动）。目标已存在时顺延 `~2`、`~3`。
--- @param node string 待搬出的绝对路径
--- @param change_set_id string|nil 变更单元 id（用作子目录，便于生命周期回收）
--- @return table|nil plan { node, container, dir, dest }
--- @return string|nil err
function M.plan(node, change_set_id)
  if type(node) ~= "string" or node == "" or node == "/" then
    return nil, "RETIRED_INVALID_NODE: " .. tostring(node)
  end
  local parent = _parent(node)
  local container = _choose_container(parent)
  if not container then return nil, "RETIRED_CONTAINER_UNAVAILABLE: " .. parent end
  local cs = tostring(change_set_id or "default"):gsub("[^%w%-%._]", "_")
  if cs == "" then cs = "default" end
  local dir = container .. "/" .. cs
  local base = node:match("[^/]+$") or "node"
  local dest = dir .. "/" .. base
  local n = 1
  while vim.uv.fs_lstat(dest) ~= nil do
    n = n + 1
    dest = dir .. "/" .. base .. "~" .. n
  end
  return { node = node, container = container, dir = dir, dest = dest }
end

--- 创建搬出容器（含 owner 标记与 `*` 的 .gitignore）与本次变更单元子目录。
--- @param plan table
--- @return boolean ok
--- @return string|nil err
function M.ensure(plan)
  if type(plan) ~= "table" or type(plan.container) ~= "string" then
    return false, "RETIRED_INVALID_PLAN"
  end
  local ok, err = fs.ensure_dir(plan.container)
  if not ok then return false, tostring(err) end
  pcall(vim.uv.fs_chmod, plan.container, 448) -- 0700
  if fs.read_file(plan.container .. "/" .. OWNER_FILE) ~= OWNER_MARK then
    local wok, werr = fs.write_file_atomic(plan.container .. "/" .. OWNER_FILE, OWNER_MARK, { mode = 384 })
    if not wok then return false, tostring(werr) end
  end
  local gi = plan.container .. "/" .. GITIGNORE_FILE
  if fs.read_file(gi) == nil then
    local gok, gerr = fs.write_file_atomic(gi, "*\n", { mode = 384 })
    if not gok then return false, tostring(gerr) end
  end
  local dok, derr = fs.ensure_dir(plan.dir)
  if not dok then return false, tostring(derr) end
  return true
end

--- 实际搬出：创建容器后 `rename`（同盘、原子）。
--- @param node string
--- @param plan table
--- @return string|nil retired 搬出路径
--- @return string|nil err
function M.move(node, plan)
  local ok, err = M.ensure(plan)
  if not ok then return nil, err end
  local nst, cst = vim.uv.fs_stat(node), vim.uv.fs_stat(plan.container)
  if nst and cst and nst.dev and cst.dev and nst.dev ~= cst.dev then
    return nil, "EXDEV: retired layer is on a different filesystem: " .. tostring(plan.container)
  end
  local rok, rerr = vim.uv.fs_rename(node, plan.dest)
  if not rok then return nil, tostring(rerr) end
  return plan.dest
end

--- 删除空的变更单元子目录/容器（只清理本模块自己的目录）。
--- @param retired string 刚被搬回的路径
local function _prune_empty_containers(retired)
  local dir = _parent(retired)
  local container = _parent(dir)
  local function _empty(p, ignore)
    local h = vim.uv.fs_scandir(p)
    if not h then return false end
    local has_content = false
    local saw_any = false
    while true do
      local name = vim.uv.fs_scandir_next(h)
      if not name then break end
      saw_any = true
      if not (ignore and ignore[name]) then has_content = true end
    end
    return saw_any and not has_content
  end
  pcall(function()
    if _empty(dir) then vim.uv.fs_rmdir(dir) end
  end)
  pcall(function()
    local base = container:match("[^/]+$") or ""
    if base ~= M.DIRNAME and not base:match("^%.neoai%-retired%-%d+$") then return end
    if _empty(container, { [OWNER_FILE] = true, [GITIGNORE_FILE] = true }) then
      vim.fn.delete(container, "rf")
    end
  end)
end

--- 搬回（撤销）：`rename` 回原路径。目标已存在 → 冲突；父目录缺失时补建。
--- @param retired string 搬出路径
--- @param original string 原路径
--- @return boolean ok
--- @return string|nil err
function M.restore(retired, original)
  if type(retired) ~= "string" or retired == "" then return false, "RETIRED_GONE" end
  if type(original) ~= "string" or original == "" then return false, "RETIRED_INVALID_NODE" end
  if vim.uv.fs_lstat(retired) == nil then return false, "RETIRED_GONE: " .. retired end
  if vim.uv.fs_lstat(original) ~= nil then return false, "TARGET_ALREADY_EXISTS: " .. original end
  local parent = _parent(original)
  if parent ~= "/" then
    local ok, err = fs.ensure_dir(parent)
    if not ok then return false, "MKDIR_FAILED: " .. tostring(err) end
  end
  local rok, rerr = vim.uv.fs_rename(retired, original)
  if not rok then return false, tostring(rerr) end
  M.forget_retired(retired)
  _prune_empty_containers(retired)
  return true
end

-- ========== 生命周期回收 ==========

--- 物理删除一条搬出记录（节点 + 空的容器目录）。
--- @param entry table { retired }
--- @return boolean
local function _purge_entry(entry)
  local retired = type(entry) == "table" and entry.retired or nil
  if type(retired) ~= "string" or retired == "" then return false end
  if M.is_retired_path(retired) == false then return false end -- 只清理搬出层内的路径
  pcall(vim.fn.delete, retired, "rf")
  _prune_empty_containers(retired)
  return true
end

--- 回收某变更单元的全部搬出内容（该单元离开待审/已应用列表时调用）。
--- @param change_set_id string
--- @return number purged
function M.purge_change_set(change_set_id)
  local cs = tostring(change_set_id or "")
  if cs == "" then return 0 end
  local data = _read_registry()
  local list = data[cs]
  if type(list) ~= "table" then return 0 end
  local n = 0
  for _, e in ipairs(list) do
    if _purge_entry(e) then n = n + 1 end
  end
  data[cs] = nil
  _write_registry(data)
  return n
end

--- 回收全部搬出内容（实例重置/退出清理）。
--- @return number purged
function M.purge_all()
  local data = _read_registry()
  local n = 0
  for _, list in pairs(data) do
    for _, e in ipairs(list or {}) do
      if _purge_entry(e) then n = n + 1 end
    end
  end
  _write_registry({})
  return n
end

--- 按「生命周期 + TTL」回收：
---   * `keep`（仍可撤销的 change_set_id 集合）之外的一律回收；
---   * 仍在 `keep` 内但超过 `ttl_days` 的也回收（磁盘兜底）。
--- `opts.keep == nil` 表示不按生命周期判定（只按 TTL），用于未知状态的安全清理。
--- @param opts table|nil { keep?: table<string, boolean>, ttl_days?: number }
--- @return number purged
function M.gc(opts)
  opts = opts or {}
  local keep = opts.keep
  local ttl = tonumber(opts.ttl_days)
  if ttl == nil or ttl <= 0 then ttl = 7 end
  local cutoff = os.time() - ttl * 86400
  local data = _read_registry()
  local purged = 0
  for cs, list in pairs(data) do
    local kept = (keep == nil) or (keep[cs] == true)
    local out = {}
    for _, e in ipairs(list or {}) do
      local at = tonumber(type(e) == "table" and e.at or nil) or 0
      local expired = at > 0 and at < cutoff
      if (not kept) or expired then
        if _purge_entry(e) then purged = purged + 1 end
      else
        out[#out + 1] = e
      end
    end
    data[cs] = (#out > 0) and out or nil
  end
  _write_registry(data)
  return purged
end

--- 重置（测试用）：模块无内存态；登记表与搬出内容由 `purge_all`/`gc` 管理。
function M.reset() end

return M
