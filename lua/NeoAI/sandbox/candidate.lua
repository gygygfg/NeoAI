--- 沙箱候选服务：私有暂存、冻结、CAS 发布
--- @module NeoAI.sandbox.candidate
--- 隔离执行只写私有暂存副本（工作区映射）或 overlay upper；冻结后计算 candidate_digest；发布做 CAS。
--- 每次尝试使用独立可写层，不与其他命令共享（设计文档 §4.2/§4.3/§4.5）。

local fs = require("NeoAI.utils.fs")

local M = {}

-- ========== 私有状态 ==========

local state = {
  attempts = {}, -- attempt_id -> { dir, mapping = { [real] = entry }, config }
  -- 工作区暂存映射：real(绝对路径) -> { staged, base_hash }。
  -- 作用域为「沙箱会话」：同一 agent 循环（generation）内所有工具调用共享同一会话，
  -- 同一文件被多次编辑时始终基于最近一次沙箱内容（而非每次从真实文件重来）。
  -- 会话在 agentEnd 时轮换：新会话使用新的暂存目录，但会**迁移**当前暂存内容，
  -- 保证跨循环的文件修改一致（读回/继续编辑仍看到未发布的改动）。发布/拒绝后失效。
  workspace = {},
  staged_to_real = {}, -- staged(绝对路径) -> real（供 buffer 写盘 / 结果路径还原）
  workspace_root = nil,
  session_id = nil, -- 当前沙箱会话 id（nil 表示尚未开始，首次暂存时惰性创建）
  session_seq = 0,
  process_dir_cache = nil, -- 当前会话的进程 overlay 基目录（宿主路径）
}

-- ========== 私有函数 ==========

local function _sha(content)
  local ok, hex = pcall(vim.fn.sha256, content or "")
  return ok and ("sha256:" .. hex) or "sha256:?"
end

local function _abs(path)
  return vim.fn.fnamemodify(fs.expand(path), ":p")
end

local function _hash_key(path)
  local ok, hex = pcall(vim.fn.sha256, path)
  return ok and hex or path:gsub("[^%w]", "_")
end

local function _read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

--- 当前沙箱会话的暂存目录
--- @return string
local function _workspace_dir()
  local root = state.workspace_root or (vim.fn.stdpath("cache") .. "/NeoAI/sandbox")
  return root .. "/sessions/" .. (state.session_id or "default")
end

--- 工作区暂存文件路径（每个真实路径一个稳定副本）。
--- 目录名用真实路径 hash 保证唯一，文件名保留真实 basename（含扩展名），
--- 使 treesitter / LSP 等依赖 filetype 的工具能正确识别暂存副本。
--- @param real string
--- @return string
local function _workspace_path(real)
  local base = vim.fn.fnamemodify(real, ":t")
  return _workspace_dir() .. "/" .. _hash_key(real) .. "/" .. base
end

--- 记录路径基线（首次）并返回其沙箱暂存路径。
--- 优先复用工作区中已有的暂存副本（同一真实内容）；否则从真实文件复制一份。
--- @param attempt table
--- @param real string
--- @return table entry
local function _base_entry(attempt, real)
  local mapping = attempt.mapping
  local entry = mapping[real]
  if entry then return entry end
  local stat = vim.uv.fs_stat(real)
  local base_type = stat and stat.type or nil
  local base_hash = nil
  if stat and stat.type == "file" then
    local content = _read(real)
    base_hash = content and _sha(content) or nil
  end
  local ws = state.workspace[real]
  local staged
  if ws and (ws.deleted or fs.exists(ws.staged)) and ws.base_hash == base_hash then
    staged = ws.staged -- 复用上一次编辑的沙箱副本（含删除态），使多次编辑可叠加
  else
    staged = _workspace_path(real)
    -- 无论新建还是复制，都必须先确保暂存副本的父目录存在：
    -- 新建文件（base 不存在）时若不建目录，写入会报 ENOENT。
    fs.ensure_dir(vim.fn.fnamemodify(staged, ":h"))
    if stat and stat.type == "file" then
      fs.copy_file(real, staged)
    end
    state.workspace[real] = { staged = staged, base_hash = base_hash }
  end
  -- 进沙箱加密：暂存视图中的高熵密钥替换为随机 token（真实文件不被改动）。
  -- view_base_hash 记录 token 化后的基线，用于「是否发生改动」判定；
  -- base_hash 仍是真实文件基线，用于 commit 的 CAS 冲突检测。
  local view_base_hash
  if stat and stat.type == "file" and fs.exists(staged) then
    local c = _read(staged)
    if c ~= nil then
      local tok = require("NeoAI.sandbox.secret").tokenize(c)
      if tok ~= c then fs.write_file(staged, tok) end
      view_base_hash = _sha(tok)
    end
  end
  entry = {
    real = real,
    staged = staged,
    base_exists = stat ~= nil,
    base_type = base_type,
    base_hash = base_hash,
    view_base_hash = view_base_hash,
    base_mode = stat and stat.mode or nil,
  }
  state.staged_to_real[staged] = real
  mapping[real] = entry
  return entry
end

-- ========== 公开 API ==========

--- 当前沙箱会话 id（未开始时返回 nil）
--- @return string|nil
function M.session_id()
  return state.session_id
end

--- 预建沙箱暂存目录（初始化时调用，避免首次写入因目录缺失报 ENOENT）。
--- @param root string|nil 沙箱根目录（缺省用已记录的 workspace_root / stdpath cache）
function M.ensure_dirs(root)
  if root then state.workspace_root = root end
  local base = state.workspace_root or (vim.fn.stdpath("cache") .. "/NeoAI/sandbox")
  fs.ensure_dir(base .. "/sessions")
  fs.ensure_dir(base .. "/workspace") -- 兼容旧布局
end

--- 当前沙箱会话目录（不存在时创建）
--- @return string
function M.session_dir()
  M.begin_session()
  fs.ensure_dir(_workspace_dir())
  return _workspace_dir()
end

--- 进程 overlay 基目录的宿主根：优先 /dev/shm（须位于所有可写根之外，避免
--- overlay 的 upper 落在 lower 之下导致内核 EINVAL）；不可用时退回沙箱根目录。
--- 目录名由 conceal 统一生成（无特征命名，不暴露沙箱自身）。
--- @return string
local function _process_base_host()
  return require("NeoAI.sandbox.conceal").base_host()
end

--- 当前会话的进程 overlay 基目录（按可写根分片存放 upper/work），不存在时创建。
--- @return string
function M.process_dir()
  M.begin_session()
  local dir = _process_base_host() .. "/" .. state.session_id
  fs.ensure_dir(dir)
  state.process_dir_cache = dir
  return dir
end

--- 开始（或返回已有的）沙箱会话。同一 agent 循环内复用同一会话。
--- @return string session_id
function M.begin_session()
  if state.session_id then return state.session_id end
  state.session_seq = state.session_seq + 1
  state.session_id = string.format("s%d_%d", os.time(), state.session_seq)
  fs.ensure_dir(_workspace_dir())
  return state.session_id
end

--- 轮换沙箱会话（agentEnd 时调用）：切换到新的暂存目录，但迁移当前暂存内容，
--- 使跨循环的文件修改保持一致（未发布的改动仍可读回/继续编辑）。
--- @return string session_id 新会话 id
function M.rotate_session()
  local old_dir = state.session_id and _workspace_dir() or nil
  local old_proc = state.process_dir_cache
  local old = state.workspace
  state.session_seq = state.session_seq + 1
  state.session_id = string.format("s%d_%d", os.time(), state.session_seq)
  fs.ensure_dir(_workspace_dir())
  state.process_dir_cache = nil
  local migrated = {}
  local migrated_rev = {}
  for real, entry in pairs(old) do
    local new_path = _workspace_path(real)
    if entry.deleted then
      migrated[real] = { staged = new_path, base_hash = entry.base_hash, deleted = true }
    elseif entry.staged and fs.exists(entry.staged) then
      fs.ensure_dir(vim.fn.fnamemodify(new_path, ":h"))
      fs.copy_file(entry.staged, new_path)
      migrated[real] = { staged = new_path, base_hash = entry.base_hash }
    else
      -- 暂存副本缺失（删除态未显式标记）：按删除态迁移，保持一致性。
      migrated[real] = { staged = new_path, base_hash = entry.base_hash, deleted = true }
    end
    migrated_rev[new_path] = real
  end
  state.workspace = migrated
  state.staged_to_real = migrated_rev
  if old_dir then
    pcall(vim.fn.delete, old_dir, "rf")
  end
  if old_proc then
    pcall(vim.fn.delete, old_proc, "rf")
  end
  return state.session_id
end

--- 开始一次暂存尝试
--- @param attempt table control.new_attempt 返回
--- @param root string 沙箱根目录
--- @return table
function M.begin(attempt, root)
  state.workspace_root = root
  M.begin_session()
  local dir = string.format("%s/attempts/%s", root, attempt.attempt_id)
  fs.ensure_dir(dir .. "/upper")
  local record = { dir = dir, mapping = {}, attempt = attempt }
  state.attempts[attempt.attempt_id] = record
  return record
end

--- 获取（必要时建立）某真实路径的暂存副本路径
--- 已存在文件复制进 upper；不存在则返回 upper 内新路径（供创建）。
--- @param attempt_id string
--- @param real_path string
--- @return string|nil staged_path
function M.stage_path(attempt_id, real_path)
  local attempt = state.attempts[attempt_id]
  if not attempt then return nil end
  local real = _abs(real_path)
  local entry = _base_entry(attempt, real)
  return entry.staged
end

--- 某次尝试的路径映射（real -> entry），供门禁还原结果中的暂存路径。
--- @param attempt_id string
--- @return table
function M.mapping(attempt_id)
  local attempt = state.attempts[attempt_id]
  return (attempt and attempt.mapping) or {}
end

--- 沙箱暂存副本（供只读工具读取 AI 尚未发布的修改）。
--- 目录不映射（目录暂存只含新建内容，映射会丢失真实文件）。
--- @param real_path string
--- @return string|nil staged_path
function M.read_path(real_path)
  local real = _abs(real_path)
  local stat = vim.uv.fs_stat(real)
  if stat and stat.type == "directory" then return nil end
  local ws = state.workspace[real]
  if ws then
    -- 目录暂存（create_directory / run_command 新建目录）不映射：映射到暂存目录会把
    -- 沙箱内部路径暴露给只读工具（AI 可见），且目录级一致性由 list_files 叠加暂存视图负责。
    local sstat = vim.uv.fs_stat(ws.staged)
    if sstat and sstat.type == "directory" then return nil end
    return ws.staged
  end
  return nil
end

--- 当前工作区暂存覆盖快照（供 list_files/search_files 等目录级只读工具做一致性视图）。
--- @return table 数组 { real, staged, deleted }
function M.workspace_overrides()
  local out = {}
  for real, entry in pairs(state.workspace) do
    -- fs.exists 基于 filereadable，对目录恒为 false；目录暂存（create_directory/
    -- run_command 新建目录）必须用 isdirectory 判定，否则会被误判为删除态。
    local exists = fs.exists(entry.staged) or vim.fn.isdirectory(entry.staged) == 1
    out[#out + 1] = {
      real = real,
      staged = entry.staged,
      deleted = entry.deleted == true or not exists,
    }
  end
  return out
end

--- 在可写根列表中匹配 real 的最佳（最长前缀）根。
--- @param real string
--- @param specs table 数组 { root, upper, work }
--- @return table|nil
local function _match_root(real, specs)
  local best
  for _, spec in ipairs(specs or {}) do
    local root = spec.root
    if real == root or real:sub(1, #root + 1) == root .. "/" then
      if not best or #root > #best.root then best = spec end
    end
  end
  return best
end

--- 把工作区暂存内容物化进进程 overlay 的 upper，使 run_command 能看到 edit_file
--- 尚未发布的改动（双向互通）。删除的文件在 overlay 上以 whiteout（char 0:0）表示；
--- 无 mknod 权限时静默跳过（此时命令仍可能看到被删的真实文件，属已知限制）。
--- @param specs table 数组 { root, upper, work, mode }
function M.materialize_overlay(specs)
  if not specs or #specs == 0 then return end
  for real, entry in pairs(state.workspace) do
    local spec = _match_root(real, specs)
    if spec then
      local rel = real:sub(#spec.root + 2)
      local base = (spec.mode == "bind") and spec.bind or spec.upper
      if base then
        local dest = base .. "/" .. rel
        if entry.deleted then
          if spec.mode == "overlay" then
            pcall(vim.fn.delete, dest, "rf")
            fs.ensure_dir(vim.fn.fnamemodify(dest, ":h"))
            pcall(vim.fn.system, { "mknod", dest, "c", "0", "0" })
          end
        elseif entry.staged and fs.exists(entry.staged) then
          -- 先清除同路径旧内容（可能是上一次物化的文件或 whiteout），再写入最新暂存内容。
          pcall(vim.fn.delete, dest, "rf")
          fs.ensure_dir(vim.fn.fnamemodify(dest, ":h"))
          fs.copy_file(entry.staged, dest)
        end
      end
    end
  end
end

--- 把已冻结候选的改动合并进工作区暂存映射，使 read_file/edit_file 能看到
--- run_command 产生的改动（双向互通）。
--- @param cand table 冻结候选
function M.merge_candidate(cand)
  for _, f in ipairs(cand.files or {}) do
    local staged = _workspace_path(f.path)
    state.staged_to_real[staged] = f.path
    if f.action == "create" or f.action == "modify" then
      fs.ensure_dir(vim.fn.fnamemodify(staged, ":h"))
      -- 保持沙箱视图一致：命令产生的改动也以 token 形式进入暂存映射。
      fs.write_file(staged, require("NeoAI.sandbox.secret").tokenize(f.content or ""))
      state.workspace[f.path] = { staged = staged, base_hash = f.before_hash, deleted = false }
    elseif f.action == "delete" or f.action == "rmdir" then
      pcall(vim.fn.delete, staged, "rf")
      state.workspace[f.path] = { staged = staged, base_hash = f.before_hash, deleted = true }
    end
  end
end

--- 使某些真实路径的暂存副本失效（发布/拒绝后调用），下次编辑重新从真实文件复制。
--- @param paths string|table
function M.invalidate(paths)
  if type(paths) == "string" then paths = { paths } end
  for _, p in ipairs(paths or {}) do
    local real = _abs(p)
    local ws = state.workspace[real]
    if ws then
      pcall(vim.fn.delete, ws.staged, "rf")
      state.staged_to_real[ws.staged] = nil
      state.workspace[real] = nil
    end
  end
end

--- 登记 overlay upper 中一条路径为候选条目（相对 real_root）
--- @param attempt table
--- @param real_root string
--- @param staged string upper 中的实际路径
--- @param child_rel string 相对 real_root 的路径
local function _capture_entry(attempt, real_root, staged, child_rel)
  local real = real_root .. "/" .. child_rel
  local stat = vim.uv.fs_stat(real)
  attempt.mapping[real] = {
    real = real,
    staged = staged,
    base_exists = stat ~= nil,
    base_type = stat and stat.type or nil,
    base_hash = (stat and stat.type == "file") and _sha(_read(real)) or nil,
  }
end

--- 判断 upper 中的条目是否为 overlayfs 删除标记（whiteout）。
--- 内核 overlayfs 在 upper 中用「同名 char 设备 0:0」表示删除；
--- 在不支持设备节点的后端上则用 `.wh.<name>` 命名。两者都需识别为删除，
--- 否则删除会静默丢失（既不落盘也不进入待审队列）。
--- @param name string
--- @param t string|nil fs_scandir 返回的类型
--- @return boolean
--- @return string real_name 去掉 .wh. 前缀后的真实文件名
local function _is_whiteout(name, t)
  if name == ".wh..wh..opq" then return false, name end
  if name:sub(1, 4) == ".wh." then return true, name:sub(5) end
  if t == "char" or t == "block" then return true, name end
  return false, name
end

--- 递归登记 overlay upper 中的文件改动为候选条目（相对 real_root）
--- 用于外部进程（run_command）在 overlay 私有可写层中产生的改动：
--- 新增/修改（普通文件）与删除（whiteout 设备节点）。
--- @param attempt_id string
--- @param real_root string 真实工作目录（overlay lower）
--- @param upper_root string overlay 私有可写层
function M.capture_overlay(attempt_id, real_root, upper_root)
  local attempt = state.attempts[attempt_id]
  if not attempt then return end
  real_root = _abs(real_root):gsub("/$", "")
  local function walk(dir, rel)
    local handle = vim.uv.fs_scandir(dir)
    if not handle then return end
    while true do
      local name, t = vim.uv.fs_scandir_next(handle)
      if not name then break end
      -- 会话 shell 状态 bind 挂载点（无特征名）不视为命令的文件改动
      if name ~= ".wh..wh..opq" and name ~= require("NeoAI.sandbox.conceal").session_basename() then
        -- opaque 目录标记（.wh..wh..opq）仅表示上层目录内容被替换，跳过不产生候选
        local whiteout, real_name = _is_whiteout(name, t)
        if whiteout then
          local child_rel = rel == "" and real_name or (rel .. "/" .. real_name)
          _capture_entry(attempt, real_root, dir .. "/" .. name, child_rel)
        elseif t == "directory" then
          local child_rel = rel == "" and name or (rel .. "/" .. name)
          walk(dir .. "/" .. name, child_rel)
        elseif t == "file" then
          local child_rel = rel == "" and name or (rel .. "/" .. name)
          _capture_entry(attempt, real_root, dir .. "/" .. name, child_rel)
        end
      end
    end
  end
  walk(upper_root, "")
end

--- 供 persist_buffer 使用的暂存目标（buffer 写盘重定向）
--- 若传入的已是暂存路径（buffer 由 ensure_buffer 加载自暂存副本），
--- 映射回真实路径后复用同一暂存副本，避免二次暂存。
--- @param real_path string
--- @return string|nil staged_path
--- @return string|nil attempt_id
function M.persist_target(real_path)
  local active = require("NeoAI.sandbox").active_attempt()
  if not active then return nil end
  local abs = _abs(real_path)
  local real = state.staged_to_real[abs] or abs
  return M.stage_path(active.attempt_id, real), active.attempt_id
end

--- 冻结：生成候选（不修改真实工作区）
--- @param attempt_id string
--- @return table candidate
function M.finish(attempt_id)
  local attempt = state.attempts[attempt_id]
  if not attempt then return nil end
  local files = {}
  for real, entry in pairs(attempt.mapping) do
    local staged_stat = vim.uv.fs_stat(entry.staged)
    local action, after_hash, content
    if entry.base_type == "directory" then
      if staged_stat and staged_stat.type == "directory" then
        if not entry.base_exists then action = "mkdir" end
      else
        if entry.base_exists then action = "rmdir" end
      end
    else
      if staged_stat and staged_stat.type == "file" then
        content = _read(entry.staged)
        after_hash = _sha(content)
        if not entry.base_exists then
          action = "create"
        elseif (entry.view_base_hash or entry.base_hash) ~= after_hash then
          action = "modify"
        end
      else
        if entry.base_exists then action = "delete" end
      end
    end
    if action then
      -- 同步工作区暂存状态：删除态标记，使后续 read/list/search 一致地看不到该文件。
      local ws = state.workspace[real]
      if ws then ws.deleted = (action == "delete" or action == "rmdir") end
      files[#files + 1] = {
        path = real,
        action = action,
        before_hash = entry.base_hash,
        after_hash = after_hash,
        base_exists = entry.base_exists,
        base_type = entry.base_type,
        content = (action == "create" or action == "modify") and content or nil,
      }
    end
  end
  table.sort(files, function(a, b) return a.path < b.path end)
  local manifest = {}
  for _, f in ipairs(files) do
    manifest[#manifest + 1] = { path = f.path, action = f.action, after_hash = f.after_hash }
  end
  local candidate = {
    candidate_digest = _sha(require("NeoAI.utils.json").encode(manifest)),
    files = files,
    created_at = os.time(),
    command_id = attempt.attempt.command_id,
    attempt_id = attempt_id,
    effect = attempt.attempt.effect,
  }
  return candidate
end

--- CAS 发布候选到真实工作区
--- 仅当真实当前状态等于候选基线时应用；否则 CONFLICT（设计文档 §4.5）。
--- @param candidate table
--- @param opts table|nil { expected_base?: string }
--- @return table { ok, state, reason?, receipt? }
function M.publish(candidate, opts)
  opts = opts or {}
  -- 冲突预检：任一文件真实状态偏离基线则整体拒绝
  for _, f in ipairs(candidate.files or {}) do
    local stat = vim.uv.fs_stat(f.path)
    local exists = stat ~= nil
    if f.action == "create" or f.action == "mkdir" then
      if exists then
        return { ok = false, state = "CONFLICT", reason = "TARGET_ALREADY_EXISTS: " .. f.path }
      end
    else
      if not exists then
        return { ok = false, state = "CONFLICT", reason = "TARGET_MISSING: " .. f.path }
      end
      if stat.type == "file" then
        local cur = _read(f.path)
        if _sha(cur) ~= f.before_hash then
          return { ok = false, state = "CONFLICT", reason = "BASELINE_CHANGED: " .. f.path }
        end
      end
    end
  end
  -- 出沙箱解密预检：任何未解析的 token（映射缺失，如热重载后）都拒绝发布，
  -- 绝不把 token 当内容写进真实文件（fail-closed）。
  local secret = require("NeoAI.sandbox.secret")
  for _, f in ipairs(candidate.files or {}) do
    if f.action == "create" or f.action == "modify" then
      local _, unresolved = secret.detokenize(f.content or "")
      if unresolved > 0 then
        return { ok = false, state = "FAILED", reason = "SECRET_UNRESOLVED: " .. f.path }
      end
    end
  end
  -- 应用
  for _, f in ipairs(candidate.files or {}) do
    if f.action == "create" or f.action == "modify" then
      fs.ensure_dir(vim.fn.fnamemodify(f.path, ":h"))
      local content = (secret.detokenize(f.content or ""))
      local ok, err = fs.write_file_atomic(f.path, content)
      if not ok then
        return { ok = false, state = "ROLLBACK_FAILED", reason = "WRITE_FAILED: " .. f.path .. " " .. tostring(err) }
      end
    elseif f.action == "mkdir" then
      fs.ensure_dir(f.path)
    elseif f.action == "delete" then
      fs.delete_file(f.path)
    elseif f.action == "rmdir" then
      pcall(vim.fn.delete, f.path, "d")
    end
  end
  -- 已发布到真实工作区：丢弃对应暂存副本，后续编辑重新以真实文件为基线。
  for _, f in ipairs(candidate.files or {}) do
    M.invalidate(f.path)
  end
  local receipt = {
    operation_id = "op_" .. (candidate.candidate_digest or ""):gsub("[^%w]", ""),
    candidate_digest = candidate.candidate_digest,
    old_version = opts.expected_base,
    new_version = candidate.candidate_digest,
    target = "workspace",
    published_at = os.time(),
    file_count = #(candidate.files or {}),
  }
  return { ok = true, state = "COMMITTED", receipt = receipt }
end

--- 递归修复目录树权限，使后续递归删除可进入。
--- bwrap 的 overlay 会在 workdir 下以 0000 权限创建内部 `work` 子目录，
--- 直接 `delete(dir, "rf")` 会因无法读取而报 E484 并残留整个尝试目录；
--- 这些目录由当前用户创建，先 chmod 即可正常清理。
--- @param dir string
local function _make_removable(dir)
  pcall(vim.uv.fs_chmod, dir, 448) -- 0700
  local handle = vim.uv.fs_scandir(dir)
  if not handle then return end
  while true do
    local name, t = vim.uv.fs_scandir_next(handle)
    if not name then break end
    -- 只递归真实子目录，不跟随符号链接（避免越出尝试目录）
    if t == "directory" then
      _make_removable(dir .. "/" .. name)
    end
  end
end

--- 释放尝试的暂存目录
--- @param attempt_id string
function M.cleanup(attempt_id)
  local attempt = state.attempts[attempt_id]
  if not attempt then return end
  _make_removable(attempt.dir)
  pcall(vim.fn.delete, attempt.dir, "rf")
  state.attempts[attempt_id] = nil
end

--- 重置（测试用）
function M.reset()
  for _, attempt in pairs(state.attempts) do
    _make_removable(attempt.dir)
    pcall(vim.fn.delete, attempt.dir, "rf")
  end
  state.attempts = {}
  if state.workspace_root then
    -- 兼容旧布局 workspace/ 与新布局 sessions/
    pcall(vim.fn.delete, state.workspace_root .. "/workspace", "rf")
    pcall(vim.fn.delete, state.workspace_root .. "/sessions", "rf")
    pcall(vim.fn.delete, state.workspace_root .. "/process", "rf")
  end
  pcall(vim.fn.delete, require("NeoAI.sandbox.conceal").base_host(), "rf")
  state.workspace = {}
  state.staged_to_real = {}
  state.session_id = nil
  state.session_seq = 0
  state.process_dir_cache = nil
end

return M
