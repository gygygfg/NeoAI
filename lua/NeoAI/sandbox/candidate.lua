--- 沙箱候选服务：私有暂存、冻结、CAS 发布
--- @module NeoAI.sandbox.candidate
--- 隔离执行只写私有暂存副本（工作区映射）或 overlay upper；冻结后计算 candidate_digest；发布做 CAS。
--- 每次尝试使用独立可写层，不与其他命令共享（设计文档 §4.2/§4.3/§4.5）。

local fs = require("NeoAI.utils.fs")
local async = require("NeoAI.utils.async")

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
  pending_cleanup = {}, -- 轮换后待安全清理的旧会话目录（避免删除运行中命令 bind 挂载的源）
  -- upper/bind 基目录 -> { [real] = { dest, version, ... } }：本次 materialize 写入的路径。
  -- 记录写入时的暂存版本，使物化可跳过「自上次写入该 base 后未改动」的项，避免每条
  -- run_command 开始都对全部暂存文件 fs_stat/读/写（暂存上万文件时是命令启动阶段的主线程卡顿源）。
  -- 按 base 分别记录：LSP overlay 与进程 overlay 使用不同 upper，需各自物化。
  materialized = {},
  version = 0, -- 暂存版本计数器：每次新增/编辑/删除/合并暂存项时递增
  rotation = nil, -- 会话轮换的在途迁移（Deferred）；暂存访问前经 `_await_rotation` 等待完成
}

--- 递增暂存版本（每次暂存内容变化时调用）
--- @return number
local function _bump_version()
  state.version = (state.version or 0) + 1
  return state.version
end

-- ========== 私有函数 ==========

--- 取权限位（低 9 位）。st_mode 形如 0o100644；`% 512` 即 0o777 掩码。
--- @param mode number|nil
--- @return number|nil
local function _perm(mode)
  if type(mode) ~= "number" then return nil end
  return mode % 512
end

local function _sha(content)
  local ok, hex = pcall(vim.fn.sha256, content or "")
  return ok and ("sha256:" .. hex) or "sha256:?"
end

--- 规范化真实路径：展开 ~/$VAR、绝对化、解析符号链接并折叠 `..`。
--- 必须与内核打开文件时的解析一致，否则「风险分级/审批展示」与「实际写入」会分裂
--- （例如 `x/../../../etc/cron.d/pwn` 被显示为工作区内 L0，却写到工作区外）。
local function _abs(path)
  return fs.canonical(path)
end

-- 暂存路径键缓存：`_workspace_path` 在合并/轮换/暂存时对每个真实路径调用，
-- 每次 `vim.fn.sha256` + `fnamemodify` 是 2 次 Vimscript 往返；暂存上万文件时累积可观。
-- 键仅依赖路径字符串（与会话无关），跨会话复用安全；reset 时清空以界定内存。
local _path_key_cache = {}

local function _hash_key(path)
  local cached = _path_key_cache[path]
  if cached then return cached end
  local ok, hex = pcall(vim.fn.sha256, path)
  local key = ok and hex or path:gsub("[^%w]", "_")
  _path_key_cache[path] = key
  return key
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

--- 把沙箱可写目录 chown 到载荷非 root uid（仅 root 启动且载荷非 root 时需要）。
--- 否则非 root 载荷无法写入 overlay upper / 暂存目录（EROFS/EACCES）。
--- @param path string
local function _chown_payload(path)
  pcall(function()
    require("NeoAI.sandbox.runtime").chown_payload(path)
  end)
end

--- 工作线程内递归删除（纯 vim.uv），供旧会话目录的异步清理，避免主线程 rm -rf 卡顿。
--- @param path string
--- @return string
local function _rmrf_worker(path)
  local uv = vim.uv
  local function rm(p)
    local st = uv.fs_lstat(p)
    if not st then return end
    if st.type == "directory" then
      local req = uv.fs_scandir(p)
      if req then
        while true do
          local name = uv.fs_scandir_next(req)
          if not name then break end
          rm(p .. "/" .. name)
        end
      end
      uv.fs_rmdir(p)
    else
      uv.fs_unlink(p)
    end
  end
  rm(path)
  return "ok"
end

--- 线程内批量写暂存副本（纯 vim.uv，自包含）：把大量 `run_command` 改动写入工作区暂存层时，
--- 逐文件同步写盘（含 mkdir/chmod）此前在主线程完成，数千文件时冻结界面。
--- 输入编码：`<n>\n` + n 条 `<path_len>:<path><mode_len>:<mode><content_len>:<content>`。
--- 成功返回 `"\1" .. <m>\n<m 条 <path_len>:<path><sig_len>:<sig>>`（写后签名，供主线程登记
--- `fresh_ssig` 而无需再逐文件 stat）；失败返回 `"\0<err>"`。
--- @param encoded string
--- @return string
local function _stage_write_worker(encoded)
  local uv = vim.uv
  local nl = encoded:find("\n", 1, true)
  local n = nl and (tonumber(encoded:sub(1, nl - 1)) or 0) or 0
  local pos = (nl or 0) + 1
  local function field()
    local colon = encoded:find(":", pos, true)
    if not colon then return nil end
    local len = tonumber(encoded:sub(pos, colon - 1)) or 0
    local val = encoded:sub(colon + 1, colon + len)
    pos = colon + len + 1
    return val
  end
  local sigs = {}
  -- 目录去重缓存：同一批内多数文件共享父目录，避免逐文件对每个路径分量重复 `fs_mkdir`
  -- （1M 小文件时约 5 次/文件的 mkdir 是单线程写盘的主要固定开销之一）。
  local seen_dirs = {}
  local function mkdirp(p)
    if not p or p == "" then return end
    local acc = ""
    for seg in p:gmatch("[^/]+") do
      acc = acc .. "/" .. seg
      if not seen_dirs[acc] then
        seen_dirs[acc] = true
        uv.fs_mkdir(acc, 448)
      end
    end
  end
  local function enc(s)
    s = s or ""
    sigs[#sigs + 1] = tostring(#s) .. ":" .. s
  end
  for _ = 1, n do
    local path = field()
    local mode = tonumber(field())
    local content = field()
    if path then
      local dir = path:match("^(.*)/[^/]*$")
      mkdirp(dir)
      local fd, err = uv.fs_open(path, "w", mode or 420)
      if not fd then return "\0" .. tostring(err) end
      local off = 0
      local ok = true
      while off < #content do
        local w, werr = uv.fs_write(fd, content:sub(off + 1), off)
        if not w or w == 0 then ok = false; err = werr; break end
        off = off + w
      end
      uv.fs_close(fd)
      if not ok then return "\0" .. tostring(err) end
      if mode then pcall(uv.fs_chmod, path, mode) end
      -- 写后签名（与主线程 `_file_sig` 同格式）：回传后主线程无需再 fs_stat 每个文件。
      local st = uv.fs_stat(path)
      local sig = ""
      if st and st.type == "file" and st.mtime then
        sig = string.format("%s:%s:%s:%s",
          tostring(st.mtime.sec), tostring(st.mtime.nsec), tostring(st.size), tostring(st.mode))
      end
      enc(path); enc(sig)
    end
  end
  return "\1" .. tostring(#sigs / 2) .. "\n" .. table.concat(sigs)
end

--- 编码批量暂存写入供 `_stage_write_worker`。
--- @param writes table 数组 { { path, mode, content } }
--- @return string
local function _encode_stage_writes(writes)
  local out, n = {}, 0
  local function f(s)
    s = s or ""
    return tostring(#s) .. ":" .. s
  end
  for _, w in ipairs(writes) do
    out[#out + 1] = f(w.path) .. f(tostring(w.mode or 420)) .. f(w.content or "")
    n = n + 1
  end
  return tostring(n) .. "\n" .. table.concat(out)
end

--- 延迟清理旧会话目录：轮换会话时**不立即** `rm -rf`——若仍有在途命令（如子 Agent 并发、
--- 同 tick 内多工具并行）以该目录为 bind 挂载源，删除会让运行中的命令突然 ENOENT，
--- 表现为间歇性 `cd: can't cd to ...`（暂存文件系统的原子性/竞态问题）。
--- 改为记录待清理项，待无在途尝试时再在**线程池**里异步删除（也避免主线程 rm -rf 卡顿）。
--- @param dir string|nil
local function _defer_cleanup(dir)
  if type(dir) ~= "string" or dir == "" then return end
  state.pending_cleanup[#state.pending_cleanup + 1] = dir
end

--- 在无在途尝试时清理已排队的旧会话目录（幂等；有尝试则留待 cleanup 后再触发）。
local function _flush_pending_cleanup()
  if state.rotation then return end
  if next(state.attempts) ~= nil then return end
  if #state.pending_cleanup == 0 then return end
  local dirs = state.pending_cleanup
  state.pending_cleanup = {}
  local work = require("NeoAI.utils.work")
  for _, d in ipairs(dirs) do
    if work.available() then
      local d2 = work.run(_rmrf_worker, d)
      if d2 and d2.catch then d2:catch(function() end) end
    else
      vim.schedule(function() pcall(vim.fn.delete, d, "rf") end)
    end
  end
end

--- 线程内批量迁移会话暂存（纯 vim.uv，自包含）：轮换时把旧会话的暂存文件复制到新会话目录。
--- 逐文件 `fs_copyfile` 此前在主线程执行，长会话（未发布改动多）时每个 agentEnd 都卡顿。
--- 输入编码：`<n>\n` + n 条 `<src_len>:<src><dst_len>:<dst><kind_len>:<kind><mode_len>:<mode>`；
--- kind: "f"（文件）| "d"（目录）。返回 "\1"。
--- @param encoded string
--- @return string
local function _rotate_copy_worker(encoded)
  local uv = vim.uv
  local nl = encoded:find("\n", 1, true)
  local n = nl and (tonumber(encoded:sub(1, nl - 1)) or 0) or 0
  local pos = (nl or 0) + 1
  local function field()
    local colon = encoded:find(":", pos, true)
    if not colon then return nil end
    local len = tonumber(encoded:sub(pos, colon - 1)) or 0
    local val = encoded:sub(colon + 1, colon + len)
    pos = colon + len + 1
    return val
  end
  local function mkdirp(p)
    if not p or p == "" then return end
    local acc = ""
    for seg in p:gmatch("[^/]+") do
      acc = acc .. "/" .. seg
      uv.fs_mkdir(acc, 448)
    end
  end
  for _ = 1, n do
    local src = field()
    local dst = field()
    local kind = field()
    local mode = tonumber(field())
    if dst then
      if kind == "d" then
        mkdirp(dst)
        if mode then pcall(uv.fs_chmod, dst, mode) end
      else
        local dir = dst:match("^(.*)/[^/]*$")
        mkdirp(dir)
        if src and src ~= "" then
          pcall(uv.fs_copyfile, src, dst)
          if mode then pcall(uv.fs_chmod, dst, mode) end
        end
      end
    end
  end
  return "\1"
end

--- 编码轮换迁移任务供 `_rotate_copy_worker`。
--- @param jobs table 数组 { { src, dst, kind, mode } }
--- @return string
local function _encode_copy_jobs(jobs)
  local out, n = {}, 0
  local function f(s)
    s = s or ""
    return tostring(#s) .. ":" .. s
  end
  for _, j in ipairs(jobs) do
    out[#out + 1] = f(j.src) .. f(j.dst) .. f(j.kind) .. f(tostring(j.mode or 420))
    n = n + 1
  end
  return tostring(n) .. "\n" .. table.concat(out)
end

--- 暂存访问前等待在途的会话轮换迁移完成（幂等）。`vim.wait` 处理事件循环，
--- 迁移 worker 的回调可在等待期间执行；通常迁移已在线程池完成，等待耗时为 0。
--- @param timeout_ms number|nil 等待上限（默认 60s）；关闭/重置时传更短的值避免卡住退出。
local function _await_rotation(timeout_ms)
  if not state.rotation then return end
  pcall(vim.wait, timeout_ms or 60000, function() return state.rotation == nil end, 10)
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
  -- 复用上一次编辑的沙箱副本（含删除态），使多次编辑可叠加。目录副本不能用 fs.exists
  -- （filereadable，对目录恒为 false）判定，否则会误判为缺失并另建路径，破坏目录一致性。
  local ws_staged_file = ws and ws.staged and fs.exists(ws.staged)
  local ws_staged_dir = ws and ws.staged and vim.fn.isdirectory(ws.staged) == 1
  local reuse = ws and ws.base_hash == base_hash
    and (ws.deleted or ws_staged_file or (base_type == "directory" and ws_staged_dir))
  if reuse then
    staged = ws.staged -- 复用上一次编辑的沙箱副本（含删除态），使多次编辑可叠加
    -- 版本记在会话级 workspace（materialize 读取它）；复用后可能被写入，标记新版本。
    ws.version = _bump_version()
  else
    staged = _workspace_path(real)
    -- 无论新建还是复制，都必须先确保暂存副本的父目录存在：
    -- 新建文件（base 不存在）时若不建目录，写入会报 ENOENT。
    fs.ensure_dir(vim.fn.fnamemodify(staged, ":h"))
    _chown_payload(vim.fn.fnamemodify(staged, ":h"))
    if stat and stat.type == "file" then
      fs.copy_file(real, staged)
      -- 保留原权限位（copyfile 不保证权限；后续 materialize 会据此恢复可执行位）。
      if stat.mode then fs.chmod(staged, _perm(stat.mode)) end
    end
    state.workspace[real] = {
      staged = staged, base_hash = base_hash, mode = _perm(stat and stat.mode),
      version = _bump_version(),
    }
  end
  -- 进沙箱加密：暂存视图中的高熵密钥替换为随机 token（真实文件不被改动）。
  -- view_base_hash 记录 token 化后的基线，用于「是否发生改动」判定；
  -- base_hash 仍是真实文件基线，用于 commit 的 CAS 冲突检测。
  local view_base_hash
  if stat and stat.type == "file" and fs.exists(staged) then
    local c = _read(staged)
    if c ~= nil then
      local secret = require("NeoAI.sandbox.secret")
      -- 高熵扫描仅对疑似密钥文件启用，避免对普通文件全文做熵计算（具名规则仍始终生效）。
      local tok = secret.tokenize(c, { entropy = secret.is_secret_path(real) })
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
    mode = _perm(stat and stat.mode),
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
  _chown_payload(base .. "/sessions")
  _chown_payload(base .. "/workspace")
end

--- 当前沙箱会话目录（不存在时创建）
--- @return string
function M.session_dir()
  M.begin_session()
  fs.ensure_dir(_workspace_dir())
  _chown_payload(_workspace_dir())
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
  _chown_payload(dir)
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
  _chown_payload(_workspace_dir())
  return state.session_id
end

--- 轮换沙箱会话（agentEnd 时调用）：切换到新的暂存目录，但迁移当前暂存内容，
--- 使跨循环的文件修改保持一致（未发布的改动仍可读回/继续编辑）。
--- @return string session_id 新会话 id
function M.rotate_session()
  _await_rotation()
  local old_dir = state.session_id and _workspace_dir() or nil
  local old_proc = state.process_dir_cache
  local old = state.workspace
  state.session_seq = state.session_seq + 1
  state.session_id = string.format("s%d_%d", os.time(), state.session_seq)
  fs.ensure_dir(_workspace_dir())
  state.process_dir_cache = nil
  local migrated = {}
  local migrated_rev = {}
  local jobs = {}
  for real, entry in pairs(old) do
    local new_path = _workspace_path(real)
    -- 目录暂存（create_directory / run_command 新建目录）不能用 fs.exists 判定：
    -- fs.exists 基于 filereadable，对目录恒为 false，会把目录误判为「暂存副本缺失」而
    -- 标记删除，随后 materialize 生成 whiteout，把沙箱视图里的目录变成设备节点/文件
    -- （表现为 `ls dir/: Not a directory`）。目录用 isdirectory 判定并迁移。
    local is_dir = entry.staged and vim.fn.isdirectory(entry.staged) == 1
    local staged_exists = is_dir or (entry.staged and fs.exists(entry.staged))
    if entry.deleted then
      migrated[real] = { staged = new_path, base_hash = entry.base_hash, deleted = true, mode = entry.mode }
    elseif staged_exists then
      -- 复制任务移入线程池（长会话未发布改动多时，逐文件主线程复制是 agentEnd 卡顿源）。
      jobs[#jobs + 1] = {
        src = entry.staged, dst = new_path, kind = is_dir and "d" or "f", mode = entry.mode,
      }
      migrated[real] = { staged = new_path, base_hash = entry.base_hash, mode = entry.mode }
    else
      -- 暂存副本缺失（删除态未显式标记）：按删除态迁移，保持一致性。
      migrated[real] = { staged = new_path, base_hash = entry.base_hash, deleted = true, mode = entry.mode }
    end
    migrated_rev[new_path] = real
  end
  state.workspace = migrated
  state.staged_to_real = migrated_rev
  -- 新会话使用新的 overlay 私有层：清空物化记录并给迁移项新版本，下次物化全部重写。
  state.materialized = {}
  for _, e in pairs(migrated) do e.version = _bump_version() end
  -- 旧目录延后清理（见 _defer_cleanup 注释）：避免删除仍在被 bind 挂载引用的源目录。
  _defer_cleanup(old_dir)
  _defer_cleanup(old_proc)
  local work = require("NeoAI.utils.work")
  if #jobs == 0 or not work.available() then
    if #jobs > 0 then
      for _, j in ipairs(jobs) do
        if j.kind == "d" then
          fs.ensure_dir(j.dst)
          if j.mode then fs.chmod(j.dst, j.mode) end
        else
          fs.ensure_dir(vim.fn.fnamemodify(j.dst, ":h"))
          fs.copy_file(j.src, j.dst)
          if j.mode then fs.chmod(j.dst, j.mode) end
        end
      end
    end
    _flush_pending_cleanup()
    return state.session_id
  end
  -- 迁移在线程池完成；期间暂存访问经 `_await_rotation` 等待（通常已完成，等待为 0）。
  state.rotation = work.run(_rotate_copy_worker, _encode_copy_jobs(jobs)):then_(function()
    state.rotation = nil
    _flush_pending_cleanup()
  end, function()
    state.rotation = nil
    _flush_pending_cleanup()
  end)
  return state.session_id
end

--- 开始一次暂存尝试
--- @param attempt table control.new_attempt 返回
--- @param root string 沙箱根目录
--- @return table
function M.begin(attempt, root)
  _await_rotation()
  state.workspace_root = root
  M.begin_session()
  local dir = string.format("%s/attempts/%s", root, attempt.attempt_id)
  fs.ensure_dir(dir .. "/upper")
  _chown_payload(dir)
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
  _await_rotation()
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
  _await_rotation()
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

--- 沙箱视图/真实盘中该路径是否为目录（供文件写入工具拒绝目录目标，避免把目录覆盖成文件）。
--- @param real_path string
--- @return boolean
function M.view_is_dir(real_path)
  _await_rotation()
  local real = _abs(real_path)
  local st = vim.uv.fs_stat(real)
  if st and st.type == "directory" then return true end
  local ws = state.workspace[real]
  if ws and not ws.deleted and ws.staged and vim.fn.isdirectory(ws.staged) == 1 then return true end
  return false
end

--- 当前工作区暂存覆盖快照（供 list_files/search_files 等目录级只读工具做一致性视图）。
--- @return table 数组 { real, staged, deleted }
function M.workspace_overrides()
  _await_rotation()
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
    -- 整机根 overlay（root="/"）：所有绝对路径都归它；前缀判定需特判（"/" .. "/" == "//"）。
    local match
    if root == "/" then
      match = real:sub(1, 1) == "/"
    else
      match = real == root or real:sub(1, #root + 1) == root .. "/"
    end
    if match and (not best or #root > #best.root) then best = spec end
  end
  return best
end

--- 把工作区暂存内容物化进进程 overlay 的 upper，使 run_command 能看到 edit_file
--- 尚未发布的改动（双向互通）。删除的文件在 overlay 上以 whiteout（char 0:0）表示；
--- 无 mknod 权限时静默跳过（此时命令仍可能看到被删的真实文件，属已知限制）。
--- @param specs table 数组 { root, upper, work, mode }
--- @param opts table|nil { force?: boolean } force=true 时忽略版本检查全量重物化
---   （用于 overlay upper 被清空后重新填充，如 LSP overlay 刷新）。
function M.materialize_overlay(specs, opts)
  if not specs or #specs == 0 then return end
  local force = opts and opts.force == true
  for real, entry in pairs(state.workspace) do
    local spec = _match_root(real, specs)
    if spec then
      -- 整机根（root="/"）时去掉开头的 "/"；其余根去掉 "<root>/" 前缀。
      local rel = spec.root == "/" and real:sub(2) or real:sub(#spec.root + 2)
      local base = (spec.mode == "bind") and spec.bind or spec.upper
      if base then
        local mat0 = state.materialized[base]
        local rec0 = mat0 and mat0[real]
        -- 该 base 已按当前暂存版本物化过：跳过（不做 fs_stat/读/写）。未变项占绝大多数，
        -- 是「暂存上万文件后每条 run_command 启动卡顿」的主要消除点；编辑/合并会递增版本。
        -- 捕获记录（capture 签名缓存，无 version）不参与该判定：它们只用于跳过「未变的
        -- 已捕获文件」，对应 workspace 条目仍需物化。
        if (not force) and rec0 and rec0.version and rec0.version == entry.version then
          -- 已物化且未改动：无需处理
        else
        local dest = base .. "/" .. rel
        if entry.deleted then
          if spec.mode == "overlay" then
            pcall(vim.fn.delete, dest, "rf")
            fs.ensure_dir(vim.fn.fnamemodify(dest, ":h"))
            pcall(vim.fn.system, { "mknod", dest, "c", "0", "0" })
            -- 记录删除态：capture 时工作线程据此判定「whiteout 未被命令重建」= 未改动而跳过。
            local mat = state.materialized[base]
            if not mat then mat = {}; state.materialized[base] = mat end
            mat[real] = { dest = dest, deleted = true, version = entry.version }
          end
        elseif entry.staged and vim.fn.isdirectory(entry.staged) == 1 then
          -- 目录暂存（create_directory/ensure_dir）：在 overlay/bind 层建立同名目录，
          -- 使 run_command 能看到沙箱内新建的目录（含空目录）。
          fs.ensure_dir(dest)
          if entry.mode then fs.chmod(dest, entry.mode) end
        elseif entry.staged and fs.exists(entry.staged) then
          -- 类型冲突防御：真实盘/overlay 中该路径是目录时，文件物化会把目录替换成文件，
          -- 损坏沙箱视图一致性（后续 `ls dir/` 报 Not a directory）。显式跳过并告警，
          -- 且**绝不删除目录**（旧兜底的 `delete dest rf` 正是损坏来源）。
          if vim.fn.isdirectory(real) == 1 or vim.fn.isdirectory(dest) == 1 then
            pcall(function()
              require("NeoAI.kernel.logger").warn(
                "[sandbox] 跳过类型冲突物化（目标为目录，拒绝文件覆盖）：%s", tostring(real))
            end)
          else
            local mat = state.materialized[base]
            if not mat then mat = {}; state.materialized[base] = mat end
            local sstat = vim.uv.fs_stat(entry.staged)
            local dstat = vim.uv.fs_stat(dest)
            -- 命令刚把内容写入 overlay dest（capture 的来源即 dest），merge 已把其 token 化版本
            -- 写入暂存副本：dest 已是最新，无需再 detokenize + 回写。暂存副本若此后被编辑
            -- （签名变化）则失效该标记，走正常回写。这是暂存量大时的主要卡顿源。
            if entry.fresh then
              local cur_ssig = (sstat and sstat.mtime) and string.format("%s:%s:%s:%s",
                tostring(sstat.mtime.sec), tostring(sstat.mtime.nsec), tostring(sstat.size), tostring(sstat.mode)) or nil
              if entry.fresh_ssig and cur_ssig == entry.fresh_ssig and dstat and dstat.mtime then
                local old = mat[real]
                mat[real] = {
                  dest = dest,
                  hash = (old and old.hash) or "sha256:fresh",
                  ssig = cur_ssig,
                  dsig = string.format("%s:%s:%s",
                    tostring(dstat.mtime.sec), tostring(dstat.mtime.nsec), tostring(dstat.size)),
                  s_sec = sstat.mtime.sec, s_nsec = sstat.mtime.nsec, s_size = sstat.size,
                  d_sec = dstat.mtime.sec, d_nsec = dstat.mtime.nsec, d_size = dstat.size,
                  version = entry.version,
                }
              end
              entry.fresh = nil
              entry.fresh_ssig = nil
            end
            local rec = mat[real]
            -- 跳过未改动的物化：暂存副本与上一次写入的 overlay 目标（mtime/大小）都未变，
            -- 则无需再次读取+detokenize+写入。暂存堆积到数千时，避免每次 run_command
            -- 开始都把所有暂存文件重写一遍。未变路径用数值字段直接比较，不做字符串格式化。
            local unchanged = rec and rec.hash and sstat and sstat.mtime and dstat and dstat.mtime
              and rec.s_sec == sstat.mtime.sec and rec.s_nsec == sstat.mtime.nsec
              and rec.s_size == sstat.size
              and rec.d_sec == dstat.mtime.sec and rec.d_nsec == dstat.mtime.nsec
              and rec.d_size == dstat.size
            if not unchanged then
              -- 原子替换：同目录临时文件 + rename。原先「先 delete 再 copy」在并行运行的
              -- 命令读到该路径时会看到缺失/半写内容（暂存文件系统原子性）；rename 原子生效。
              local content = fs.read_file(entry.staged)
              if content ~= nil then
                -- 暂存视图对 AI 遮蔽了密钥（token 化），但命令执行层必须拿到**真实内容**：
                -- 物化进 overlay 前把 token 还原，否则程序（pip/build/python 等）读到
                -- NEOKEY_* 会失败（如 import 报错、构建 KeyError）。AI 侧仍读 token 视图。
                content = (require("NeoAI.sandbox.secret").detokenize(content))
                fs.ensure_dir(vim.fn.fnamemodify(dest, ":h"))
                local mode = entry.mode or 420 -- 0644：保留原权限位，新建文件用常规默认（不强制 0600）
                -- overlay 私有可写层是会话级临时草稿（agentEnd 轮换即清理），无需 fsync 落盘；
                -- 逐文件 fsync 在暂存量大时是主要卡顿源。
                local ok = fs.write_file_atomic(dest, content, { mode = mode, sync = false })
                if not ok and vim.fn.isdirectory(dest) == 0 then
                  -- 兜底（rename 不适用等）：退回直接写 + chmod；目标为目录时不删目录。
                  pcall(vim.fn.delete, dest, "rf")
                  fs.ensure_dir(vim.fn.fnamemodify(dest, ":h"))
                  fs.write_file(dest, content)
                  fs.chmod(dest, mode)
                end
                local ndstat = vim.uv.fs_stat(dest)
                -- 记录写入内容哈希与两侧签名：capture 时工作线程据此判断命令是否改动
                -- （签名未变即跳过读取/哈希）；下次物化据此跳过未变文件。
                mat[real] = {
                  dest = dest,
                  hash = "sha256:" .. vim.fn.sha256(content),
                  ssig = (sstat and sstat.mtime) and string.format("%s:%s:%s:%s",
                    tostring(sstat.mtime.sec), tostring(sstat.mtime.nsec), tostring(sstat.size), tostring(sstat.mode)) or nil,
                  dsig = (ndstat and ndstat.mtime) and string.format("%s:%s:%s",
                    tostring(ndstat.mtime.sec), tostring(ndstat.mtime.nsec), tostring(ndstat.size)) or nil,
                  s_sec = sstat and sstat.mtime and sstat.mtime.sec,
                  s_nsec = sstat and sstat.mtime and sstat.mtime.nsec,
                  s_size = sstat and sstat.size,
                  d_sec = ndstat and ndstat.mtime and ndstat.mtime.sec,
                  d_nsec = ndstat and ndstat.mtime and ndstat.mtime.nsec,
                  d_size = ndstat and ndstat.size,
                  version = entry.version,
                }
              end
            end
          end
        end
        end
      end
    end
  end
end

--- 文件签名（mtime.sec:mtime.nsec:size:mode），与物化记录的 `ssig` 格式一致。
--- @param path string
--- @return string|nil
local function _file_sig(path)
  local st = vim.uv.fs_stat(path)
  if not (st and st.type == "file" and st.mtime) then return nil end
  return string.format("%s:%s:%s:%s",
    tostring(st.mtime.sec), tostring(st.mtime.nsec), tostring(st.size), tostring(st.mode))
end

--- 每个工作任务的条目数：把大量文件的读取/哈希/写入切成多批并发投递到线程池（默认 4 线程），
--- 避免单个大 job 只用单核。可经 tools.sandbox.work_chunk_files 调整。
--- @return number
local function _work_chunk_files()
  local n = tonumber(require("NeoAI.kernel.config_store").get("tools.sandbox.work_chunk_files"))
  if not n or n <= 0 then return 128 end
  return n
end

--- 把数组按 size 切块（保留顺序）
--- @param list table
--- @param size number
--- @return table 块数组
local function _chunk_list(list, size)
  local chunks, cur = {}, {}
  for _, v in ipairs(list) do
    cur[#cur + 1] = v
    if #cur >= size then chunks[#chunks + 1] = cur; cur = {} end
  end
  if #cur > 0 then chunks[#chunks + 1] = cur end
  return chunks
end

--- 每批并发提交的 chunk 数上限（默认 4，与 libuv 线程池一致）：避免数百个 chunk job
--- 一次排满队列，饿死后续 UI 关键 job（脱敏/密钥 token 化/落盘）。
--- 可经 tools.sandbox.work_parallelism 调整。
--- @return number
local function _work_parallelism()
  local n = tonumber(require("NeoAI.kernel.config_store").get("tools.sandbox.work_parallelism"))
  if not n or n <= 0 then return 4 end
  return n
end

--- 把已冻结候选的改动合并进工作区暂存映射，使 read_file/edit_file 能看到
--- run_command 产生的改动（双向互通）。
--- @param cand table 冻结候选
--- @param opts table|nil { from_command?: boolean, package?: boolean 包/生成内容跳过 token 化 }
function M.merge_candidate(cand, opts)
  opts = opts or {}
  for _, f in ipairs(cand.files or {}) do
    local staged = _workspace_path(f.path)
    state.staged_to_real[staged] = f.path
    if f.action == "create" or f.action == "modify" then
      fs.ensure_dir(vim.fn.fnamemodify(staged, ":h"))
      -- 保持沙箱视图一致：命令产生的改动也以 token 形式进入暂存映射。
      -- 高熵扫描仅对疑似密钥文件启用（具名规则仍始终生效）。
      -- 包/生成内容（site-packages、node_modules 等）不做 token 化：与结算阶段跳过密钥
      -- 检测一致，避免对 venv/依赖树逐文件多次全文扫描（实测数十 MB 需数秒）。
      local content = f.content or ""
      if not opts.package then
        local secret = require("NeoAI.sandbox.secret")
        content = secret.tokenize(content, { entropy = secret.is_secret_path(f.path) })
      end
      fs.write_file(staged, content)
      if f.mode then fs.chmod(staged, f.mode) end
      state.workspace[f.path] = {
        staged = staged, base_hash = f.before_hash, deleted = false, mode = f.mode,
        fresh = opts.from_command == true,
        fresh_ssig = opts.from_command and _file_sig(staged) or nil,
        version = _bump_version(),
      }
    elseif f.action == "delete" or f.action == "rmdir" then
      pcall(vim.fn.delete, staged, "rf")
      state.workspace[f.path] = { staged = staged, base_hash = f.before_hash, deleted = true, version = _bump_version() }
    elseif f.action == "mkdir" then
      -- 新建目录：登记为目录暂存条目（否则后续 read/list 与轮换迁移会丢失该目录）。
      fs.ensure_dir(staged)
      if f.mode then fs.chmod(staged, f.mode) end
      state.workspace[f.path] = { staged = staged, base_hash = f.before_hash, deleted = false, mode = f.mode, version = _bump_version() }
    end
  end
end

--- 异步版：暂存内容的密钥 token 化经 `secret.tokenize_many_async`（线程池）执行，
--- 避免大量文件时全文扫描占满主线程；写入/映射登记仍在主线程。
--- @param cand table 冻结候选
--- @param opts table|nil { from_command?: boolean, package?: boolean }
--- @return Deferred resolve(cand)
function M.merge_candidate_async(cand, opts)
  opts = opts or {}
  local files = cand and cand.files or {}
  local texts, entropy_flags = {}, {}
  local secret = require("NeoAI.sandbox.secret")
  for _, f in ipairs(files) do
    if f.action == "create" or f.action == "modify" then
      texts[#texts + 1] = f.content or ""
      -- 仅疑似密钥文件做高熵扫描（具名规则始终生效）。
      entropy_flags[#entropy_flags + 1] = secret.is_secret_path(f.path)
    end
  end
  --- 写暂存副本：写入（含内容）经线程池批量完成，主线程只登记映射与 fresh 签名。
  --- 删除/建目录仍在主线程（数量少、无内容）。
  --- @param tokenized table|nil
  --- @return Deferred resolve(cand)
  local function apply_async(tokenized)
    local ti = 0
    local writes = {}
    for _, f in ipairs(files) do
      local staged = _workspace_path(f.path)
      state.staged_to_real[staged] = f.path
      if f.action == "create" or f.action == "modify" then
        ti = ti + 1
        writes[#writes + 1] = {
          path = staged, mode = f.mode, content = tokenized[ti] or (f.content or ""),
        }
        state.workspace[f.path] = {
          staged = staged, base_hash = f.before_hash, deleted = false, mode = f.mode,
          fresh = opts.from_command == true,
          version = _bump_version(),
        }
      elseif f.action == "delete" or f.action == "rmdir" then
        pcall(vim.fn.delete, staged, "rf")
        state.workspace[f.path] = { staged = staged, base_hash = f.before_hash, deleted = true, version = _bump_version() }
      elseif f.action == "mkdir" then
        fs.ensure_dir(staged)
        if f.mode then fs.chmod(staged, f.mode) end
        state.workspace[f.path] = { staged = staged, base_hash = f.before_hash, deleted = false, mode = f.mode, version = _bump_version() }
      end
    end
    local function mark_fresh(sigs)
      if not opts.from_command then return end
      for _, w in ipairs(writes) do
        local real = state.staged_to_real[w.path]
        local ws = real and state.workspace[real]
        -- 优先用工作线程写后回传的签名，避免主线程对每个暂存文件再 fs_stat。
        if ws then ws.fresh_ssig = (sigs and sigs[w.path]) or _file_sig(w.path) end
      end
    end
    --- 解析 `_stage_write_worker` 回传的 path->sig 记录。
    --- @param encoded string
    --- @return table
    local function parse_sigs(encoded)
      local sigs = {}
      if type(encoded) ~= "string" then return sigs end
      local nl = encoded:find("\n", 1, true)
      if not nl then return sigs end
      local cnt = tonumber(encoded:sub(1, nl - 1)) or 0
      local pos = nl + 1
      local function field()
        local colon = encoded:find(":", pos, true)
        if not colon then return nil end
        local len = tonumber(encoded:sub(pos, colon - 1)) or 0
        local val = encoded:sub(colon + 1, colon + len)
        pos = colon + len + 1
        return val
      end
      for _ = 1, cnt do
        local path, sig = field(), field()
        if path and sig and sig ~= "" then sigs[path] = sig end
      end
      return sigs
    end
    if #writes == 0 then return async.resolve(cand) end
    local work = require("NeoAI.utils.work")
    if not work.available() then
      for _, w in ipairs(writes) do
        fs.ensure_dir(vim.fn.fnamemodify(w.path, ":h"))
        fs.write_file(w.path, w.content)
        if w.mode then fs.chmod(w.path, w.mode) end
      end
      mark_fresh()
      return async.resolve(cand)
    end
    -- 大量暂存写入：按 `work_chunk_files` 分块并发投递线程池（写盘用满多核），每块的编码
    -- 在 `work.batched` 的 start 回调内**惰性**完成——该回调按组在主线程调用，编码与上一组
    -- worker 的写盘重叠，避免一次性编码全部条目（1M 文件时约 20+ s 主线程）后单线程写盘。
    local all_sigs = opts.from_command and {} or nil
    return work.batched(_chunk_list(writes, _work_chunk_files()), _work_parallelism(), function(chunk)
      return work.run(_stage_write_worker, _encode_stage_writes(chunk))
    end):then_(function(results)
      for _, res in ipairs(results) do
        if type(res) == "string" and res:sub(1, 1) == "\0" then
          return async.reject({ kind = "work", message = "暂存写入失败: " .. tostring(res:sub(2)) })
        end
        if all_sigs and type(res) == "string" and res:sub(1, 1) == "\1" then
          local part = parse_sigs(res:sub(2))
          for p, s in pairs(part) do all_sigs[p] = s end
        end
      end
      mark_fresh(all_sigs)
      return cand
    end)
  end
  if #texts == 0 then
    return apply_async({})
  end
  -- 包/生成内容跳过 token 化（与结算阶段跳过密钥检测一致）。
  if opts.package then
    return apply_async(texts)
  end
  return secret.tokenize_many_async(texts, { entropy_flags = entropy_flags }):then_(function(tokenized)
    return apply_async(tokenized)
  end)
end

--- 返回「存在暂存改动」的包可写根：供后续非包安装命令也把这些根加入可写层，
--- 使已安装的包（暂存于 overlay）在后续命令中可见（如 `python -m build` 看到刚装的 build）。
--- @return table 根路径数组
function M.staged_roots()
  local pkg = require("NeoAI.kernel.config_store").get("tools.sandbox.packages") or {}
  local roots = {}
  for _, r in ipairs(pkg.roots or {}) do
    if type(r) == "string" and r ~= "" and r ~= "/" then
      local p = vim.fn.expand(r):gsub("/+$", "")
      if p ~= "" and vim.fn.isdirectory(p) == 1 then roots[#roots + 1] = p end
    end
  end
  local out, seen = {}, {}
  for real in pairs(state.workspace) do
    for _, root in ipairs(roots) do
      if real == root or real:sub(1, #root + 1) == root .. "/" then
        if not seen[root] then seen[root] = true; out[#out + 1] = root end
        break
      end
    end
  end
  return out
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

--- 单文件纳入候选的大小上限（字节）：超过则不纳入候选，避免把 apt/pkgcache.bin、
--- 缓存归档、镜像层等超大文件嵌入候选 JSON 而阻塞主线程 / 撑爆磁盘。0 = 不限制。
--- @return number
local function _max_file_bytes()
  local n = tonumber(require("NeoAI.kernel.config_store").get("tools.sandbox.max_file_bytes"))
  if n == nil then return 8 * 1024 * 1024 end
  return n
end

--- 登记 overlay upper 中一条路径为候选条目（相对 real_root）
--- @param attempt table
--- @param real_root string
--- @param staged string upper 中的实际路径
--- @param child_rel string 相对 real_root 的路径
--- @param prefetch table|nil 工作线程预取结果 { base_exists, base_type, base_hash,
---   staged_is_file, staged_size }；nil 时在主线程 fs_stat/读取/哈希（同步路径）。
--- @param cap number|nil 单文件纳入上限（字节）；nil 时读取配置（逐条读取配置在暂存上万
---   文件时是结算主线程的固定开销，故由调用方一次性传入）。
local function _capture_entry(attempt, real_root, staged, child_rel, prefetch, cap)
  local real = real_root .. "/" .. child_rel
  -- 仅由 materialize_overlay 带入 overlay 的 AI 暂存编辑（命令本身未改动）不产生候选：
  -- 否则只读命令（ls/cat/git status 等）会把暂存编辑重复捕获为 run_command 候选并取代
  -- 原 edit 候选；一旦该命令被拒绝，还会 invalidate 掉这条暂存编辑，表现为「已允许的
  -- 修改被回滚」。内容与当前工作区暂存一致（或已标记删除）即视为未被命令改动。
  -- `prefetch.ws_checked`：异步路径已在线程内完成该判定（含内容读取），主线程不再读盘。
  if not (prefetch and prefetch.ws_checked) then
    local ws = state.workspace[real]
    if ws then
      if ws.deleted then
        -- 之前标记删除：仅当命令**重新创建**了普通文件时才视为改动（whiteout 设备节点仍跳过）。
        local sstat = vim.uv.fs_stat(staged)
        if not (sstat and sstat.type == "file") then return end
      elseif ws.staged and fs.exists(ws.staged) then
        local before = _read(ws.staged)
        local after = _read(staged)
        if before ~= nil and before == after then return end
      end
    end
  end
  local cap = cap or _max_file_bytes()
  local base_exists, base_type, base_hash, staged_is_file, staged_size, staged_mode
  if prefetch then
    base_exists, base_type, base_hash = prefetch.base_exists, prefetch.base_type, prefetch.base_hash
    staged_is_file, staged_size = prefetch.staged_is_file, prefetch.staged_size
    staged_mode = prefetch.staged_mode
  else
    local stat = vim.uv.fs_stat(real)
    base_exists = stat ~= nil
    base_type = stat and stat.type or nil
    base_hash = (stat and stat.type == "file") and _sha(_read(real)) or nil
    local staged_stat = vim.uv.fs_stat(staged)
    staged_is_file = staged_stat and staged_stat.type == "file"
    staged_size = staged_stat and staged_stat.size
    staged_mode = staged_stat and staged_stat.mode
  end
  -- 超大普通文件不纳入候选（写入仍在 overlay 私有层，不落真实盘；只是不进入待审/发布）。
  if cap > 0 and staged_is_file and (staged_size or 0) > cap then
    pcall(function()
      require("NeoAI.kernel.logger").warn(
        "[sandbox] 跳过超大候选文件（%d 字节 > 上限 %d）：%s", staged_size, cap, real)
    end)
    return
  end
  attempt.mapping[real] = {
    real = real,
    staged = staged,
    base_exists = base_exists,
    base_type = base_type,
    base_hash = (base_type == "file") and base_hash or nil,
    mode = staged_is_file and _perm(staged_mode) or nil,
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

--- capture 后对账：materialize 写入的「沙箱-only」文件若被命令删除，overlayfs 不会产生
--- whiteout（lower 无对应文件），capture 遍历 upper 看不到任何条目 → 删除静默丢失，
--- 下一次 materialize 会用旧暂存内容把它「复活」。这里显式检测：materialize 记录过 dest、
--- 现 upper 中已不存在、且真实文件也不存在 → 标记工作区删除并取消该路径的待审变更
--- （净效果为「无改动」，不产生针对不存在文件的 delete 候选）。
--- @param attempt table
--- @param real_root string
--- @param upper_root string
local function _reconcile_deleted(attempt, real_root, upper_root)
  local mat = state.materialized[upper_root]
  if not mat then return end
  local superseded = {}
  for real, rec in pairs(mat) do
    local dest = type(rec) == "table" and rec.dest or rec
    local ws = state.workspace[real]
    if dest and ws and not ws.deleted then
      if vim.uv.fs_stat(dest) == nil and vim.uv.fs_stat(real) == nil then
        ws.deleted = true
        pcall(vim.fn.delete, ws.staged, "rf")
        superseded[#superseded + 1] = real
      end
    end
  end
  if #superseded > 0 then
    pcall(function()
      require("NeoAI.sandbox.review").supersede_by_paths(superseded)
    end)
  end
end

--- 递归登记 overlay upper 中的文件改动为候选条目（相对 real_root）
--- 用于外部进程（run_command）在 overlay 私有可写层中产生的改动：
--- 新增/修改（普通文件）与删除（whiteout 设备节点）。
--- @param attempt_id string
--- @param real_root string 真实工作目录（overlay lower）
--- @param upper_root string overlay 私有可写层
function M.capture_overlay(attempt_id, real_root, upper_root)
  local attempt = state.attempts[attempt_id]
  if not attempt then
    return
  end
  real_root = _abs(real_root):gsub("/$", "")
  local cap = _max_file_bytes()
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
          _capture_entry(attempt, real_root, dir .. "/" .. name, child_rel, nil, cap)
        elseif t == "directory" then
          local child_rel = rel == "" and name or (rel .. "/" .. name)
          walk(dir .. "/" .. name, child_rel)
        elseif t == "file" then
          local child_rel = rel == "" and name or (rel .. "/" .. name)
          _capture_entry(attempt, real_root, dir .. "/" .. name, child_rel, nil, cap)
        end
      end
    end
  end
  walk(upper_root, "")
  _reconcile_deleted(attempt, real_root, upper_root)
end

-- ========== 工作线程：overlay 遍历/读取（主线程只做状态登记） ==========
-- 说明：工作函数经 string.dump 在独立线程执行，不携带 upvalue，故必须自包含
-- （仅用参数 + 纯 Lua 标准库 + vim.uv）。返回值为二进制安全的分段编码：
--   `<n>\n` + n 条记录，每条记录由若干 `<len>:<bytes>` 字段顺序拼接。

--- 线程内递归遍历 overlay upper，返回编码记录（base_hash 留空，由 `_base_hash_worker` 分块并行补算）。
--- 字段：child_rel, staged, kind, base_exists, base_type, base_hash,
---       staged_is_file, staged_size, staged_mode
--- kind: "file" | "whiteout" | "reconcile"（命令删除了沙箱-only 文件，供删除对账）
--- 未变快速判定：物化时记录的目标 mtime/size 签名（`dsig`）未变即视为命令未改动，**直接跳过**
--- （不读文件、不做纯 Lua SHA）。
--- @param upper_root string
--- @param real_root string
--- @param session_basename string 会话挂载点 basename（排除，不算命令改动）
--- @param expected_encoded string 物化期望表（real -> hash/"D" + dest + dsig）
--- @param ws_encoded string 工作区暂存映射（real -> staged / "D" 删除态），供线程内做一致性判定
--- @return string 编码记录
local function _capture_worker(upper_root, real_root, session_basename, expected_encoded, ws_encoded, cap)
  -- 解码物化期望表：real -> { hash = 内容哈希 | nil, deleted = bool, dest = 物化目标 }
  local expected = {}
  do
    local nl = type(expected_encoded) == "string" and expected_encoded:find("\n", 1, true)
    if nl then
      local n = tonumber(expected_encoded:sub(1, nl - 1)) or 0
      local pos = nl + 1
      local function field()
        local colon = expected_encoded:find(":", pos, true)
        if not colon then return nil end
        local len = tonumber(expected_encoded:sub(pos, colon - 1)) or 0
        local val = expected_encoded:sub(colon + 1, colon + len)
        pos = colon + len + 1
        return val
      end
      for _ = 1, n do
        local real = field()
        local h = field()
        local dest = field()
        local dsig = field()
        if real then
          expected[real] = {
            hash = (h ~= "" and h ~= "D") and h or nil,
            deleted = (h == "D"),
            dest = dest,
            dsig = (dsig ~= "" and dsig) or nil,
          }
        end
      end
    end
  end
  -- 解码工作区暂存映射：real -> { staged, deleted }，供线程内比对「命令改动是否只是暂存编辑的复现」。
  local wsm = {}
  do
    local nl = type(ws_encoded) == "string" and ws_encoded:find("\n", 1, true)
    if nl then
      local n = tonumber(ws_encoded:sub(1, nl - 1)) or 0
      local pos = nl + 1
      local function field()
        local colon = ws_encoded:find(":", pos, true)
        if not colon then return nil end
        local len = tonumber(ws_encoded:sub(pos, colon - 1)) or 0
        local val = ws_encoded:sub(colon + 1, colon + len)
        pos = colon + len + 1
        return val
      end
      for _ = 1, n do
        local real = field()
        local staged = field()
        if real then wsm[real] = { deleted = (staged == "D"), staged = staged } end
      end
    end
  end
  local function read_all(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local c = f:read("*a")
    f:close()
    return c
  end
  local out = {}
  local count = 0
  local function enc(s)
    s = s or ""
    out[#out + 1] = tostring(#s) .. ":" .. s
  end
  --- 目标文件的廉价签名（mtime.sec:mtime.nsec:size）：用于判断物化后是否被命令改动，
  --- 未变即可跳过内容读取与哈希。
  --- @param path string
  --- @return string|nil
  local function sig_of(path)
    local st = vim.uv.fs_stat(path)
    if not (st and st.type == "file" and st.mtime) then return nil end
    return string.format("%s:%s:%s",
      tostring(st.mtime.sec), tostring(st.mtime.nsec), tostring(st.size))
  end
  --- 由 stat 直接构造目标签名（避免再 stat 一次）
  local function dsig_of(st)
    if not (st and st.type == "file" and st.mtime) then return "" end
    return string.format("%s:%s:%s",
      tostring(st.mtime.sec), tostring(st.mtime.nsec), tostring(st.size))
  end
  local function walk(dir, rel)
    local handle = vim.uv.fs_scandir(dir)
    if not handle then return end
    while true do
      local name, t = vim.uv.fs_scandir_next(handle)
      if not name then break end
      if name ~= ".wh..wh..opq" and name ~= session_basename then
        local whiteout, real_name = false, name
        if name:sub(1, 4) == ".wh." then
          whiteout, real_name = true, name:sub(5)
        elseif t == "char" or t == "block" then
          whiteout = true
        end
        local child_rel = rel == "" and real_name or (rel .. "/" .. real_name)
        local real = real_root .. "/" .. child_rel
        local exp = expected[real]
        --- 线程内工作区一致性判定：命令改动是否只是 AI 暂存编辑的复现（或删除态）。
        --- 与 `_capture_entry` 的 ws 分支同口径，但内容读取移到工作线程，避免主线程逐文件读盘。
        --- @param dest string overlay 中实际路径
        --- @param sstat table|nil dest 的 stat
        --- @return boolean skip 是否跳过（不产生候选）
        local function ws_skip(dest, sstat)
          local w = wsm[real]
          if not w then return false end
          if w.deleted then
            -- 之前标记删除：仅当命令**重新创建**了普通文件时才视为改动（whiteout 设备节点仍跳过）。
            return not (sstat and sstat.type == "file")
          end
          if w.staged ~= "" then
            local before = read_all(w.staged)
            local after = read_all(dest)
            if before ~= nil and before == after then return true end
          end
          return false
        end
        if whiteout then
          if exp and exp.deleted then
            -- 期望即删除态且未被命令重建：未改动，跳过（不产生候选）。
          else
            local staged_path = dir .. "/" .. name
            local sstat = vim.uv.fs_stat(staged_path)
            if not ws_skip(staged_path, sstat) then
              local stat = vim.uv.fs_stat(real)
              -- whiteout 删除的是基线文件，base_hash 需与真实内容一致（CAS 冲突检测依赖）。
              enc(child_rel); enc(staged_path); enc("whiteout")
              enc(stat and "1" or "0"); enc(stat and stat.type or ""); enc("")
              enc("0"); enc("0"); enc("0"); enc("")
              count = count + 1
            end
          end
        elseif t == "directory" then
          walk(dir .. "/" .. name, child_rel)
        elseif t == "file" then
          local dest = dir .. "/" .. name
          -- 未变快速判定：物化时记录的目标签名（mtime/size）未变即视为命令未改动，
          -- 直接跳过——不读文件、不做纯 Lua SHA。暂存堆积到数千时，这是避免每条
          -- run_command 重读重算全部物化文件的关键（曾表现为 libuv-worker 单核打满）。
          local unchanged = false
          if exp and exp.hash and exp.dsig then
            local dsig = sig_of(dest)
            if dsig and dsig == exp.dsig then unchanged = true end
          end
          if not unchanged then
            local stat = vim.uv.fs_stat(real)
            local sstat = vim.uv.fs_stat(dest)
            if cap > 0 and sstat and sstat.type == "file" and (sstat.size or 0) > cap then
              -- 超大文件：不纳入候选，且 base_type 留空 → 不进入 `need`（避免主线程侧
              -- `_base_hash_worker` 读取/哈希数百 MB）。编码 skip 记录供主线程记日志。
              enc(child_rel); enc(dest); enc("skip")
              enc("0"); enc(""); enc("")
              enc("1"); enc(tostring(sstat.size or 0)); enc(tostring(sstat.mode or 0))
              enc(dsig_of(sstat))
              count = count + 1
            elseif not ws_skip(dest, sstat) then
              enc(child_rel); enc(dest); enc("file")
              enc(stat and "1" or "0"); enc(stat and stat.type or ""); enc("")
              enc((sstat and sstat.type == "file") and "1" or "0")
              enc(tostring(sstat and sstat.size or 0))
              enc(tostring(sstat and sstat.mode or 0))
              enc(dsig_of(sstat))
              count = count + 1
            end
          end
        end
      end
    end
  end
  walk(upper_root, "")
  -- 删除对账：期望物化的文件若 dest 与真实文件都不存在，说明命令删除了沙箱-only 文件
  -- （overlayfs 不会为 lower 不存在的文件生成 whiteout，遍历看不到任何条目）。
  for real, exp in pairs(expected) do
    if exp.hash and exp.dest then
      if not vim.uv.fs_lstat(exp.dest) and not vim.uv.fs_lstat(real) then
        enc(real); enc(""); enc("reconcile")
        enc("0"); enc(""); enc(""); enc("0"); enc("0"); enc("0"); enc("")
        count = count + 1
      end
    end
  end
  return tostring(count) .. "\n" .. table.concat(out)
end

--- 编码物化期望表（real -> hash/"D" + dest）供 `_capture_worker` 比对。
--- @param mat table|nil state.materialized[base]
--- @return string
local function _encode_expected(mat)
  local out = {}
  local n = 0
  local function f(s)
    s = s or ""
    return tostring(#s) .. ":" .. s
  end
  for real, rec in pairs(mat or {}) do
    if type(rec) == "table" then
      local h = rec.deleted and "D" or (rec.hash or "")
      out[#out + 1] = f(real) .. f(h) .. f(rec.dest or "") .. f(rec.dsig or "")
      n = n + 1
    end
  end
  return tostring(n) .. "\n" .. table.concat(out)
end

--- 编码工作区暂存映射（real -> staged / "D" 删除态）供 `_capture_worker` 做一致性判定。
--- `root` 非空时只编码该根子树内的条目：工作线程仅会查询本次捕获根下的路径，全量编码整个
--- 工作区（暂存上万文件）在主线程是固定大开销。
--- @param ws_map table state.workspace
--- @param root string|nil
--- @return string
local function _encode_ws(ws_map, root)
  local out, n = {}, 0
  local function f(s)
    s = s or ""
    return tostring(#s) .. ":" .. s
  end
  local prefix = root and (root .. "/") or nil
  for real, ws in pairs(ws_map or {}) do
    if not prefix or real == root or real:sub(1, #prefix) == prefix then
      local staged = ws.deleted and "D" or (ws.staged or "")
      out[#out + 1] = f(real) .. f(staged)
      n = n + 1
    end
  end
  return tostring(n) .. "\n" .. table.concat(out)
end

--- 异步捕获的删除对账：materialize 记录过、现 upper 与真实盘都不存在的路径 → 标记工作区删除。
--- @param reals table real 路径数组
local function _apply_reconcile(reals)
  if not reals or #reals == 0 then return end
  local superseded = {}
  for _, real in ipairs(reals) do
    local ws = state.workspace[real]
    if ws and not ws.deleted then
      ws.deleted = true
      pcall(vim.fn.delete, ws.staged, "rf")
      superseded[#superseded + 1] = real
    end
  end
  if #superseded > 0 then
    pcall(function()
      require("NeoAI.sandbox.review").supersede_by_paths(superseded)
    end)
  end
end

--- 解析编码记录为字段数组
--- @param encoded string
--- @param nfields number
--- @return table 记录数组（每条为字段数组）
local function _decode_records(encoded, nfields)
  local out = {}
  if type(encoded) ~= "string" then return out end
  local nl = encoded:find("\n", 1, true)
  if not nl then return out end
  local n = tonumber(encoded:sub(1, nl - 1)) or 0
  local pos = nl + 1
  local function field()
    local colon = encoded:find(":", pos, true)
    if not colon then return nil end
    local len = tonumber(encoded:sub(pos, colon - 1)) or 0
    local val = encoded:sub(colon + 1, colon + len)
    pos = colon + len + 1
    return val
  end
  for i = 1, n do
    local rec = {}
    for j = 1, nfields do rec[j] = field() end
    out[i] = rec
  end
  return out
end

--- 编码真实路径数组供工作线程计算 base 哈希（字段：real）
--- @param reals table 路径数组
--- @return string
local function _encode_paths(reals)
  local out = {}
  for _, p in ipairs(reals) do
    p = p or ""
    out[#out + 1] = tostring(#p) .. ":" .. p
  end
  return tostring(#reals) .. "\n" .. table.concat(out)
end

--- 线程内批量计算 base（真实盘）文件的内容哈希：命令改动的文件需与基线做 CAS 冲突检测，
--- 此哈希此前在 overlay 遍历的单个 job 内串行完成（大量改动时纯 Lua SHA 单核打满）。
--- 现由主线程按批并发投递到线程池。字段：base_hash（sha256:... 或空）。
--- @param input string 编码的真实路径数组
--- @param sha_src string 纯 Lua sha256 实现源码
--- @return string 编码的哈希数组
local function _base_hash_worker(input, sha_src, cap)
  local sha = assert(load(sha_src))()
  cap = tonumber(cap) or 0
  local nl = type(input) == "string" and input:find("\n", 1, true)
  local n = nl and (tonumber(input:sub(1, nl - 1)) or 0) or 0
  local pos = (nl or 0) + 1
  local out = {}
  local function field()
    local colon = input:find(":", pos, true)
    if not colon then return nil end
    local len = tonumber(input:sub(pos, colon - 1)) or 0
    local val = input:sub(colon + 1, colon + len)
    pos = colon + len + 1
    return val
  end
  local function enc(s)
    s = s or ""
    out[#out + 1] = tostring(#s) .. ":" .. s
  end
  for _ = 1, n do
    local real = field()
    local st = real and vim.uv.fs_stat(real)
    local h = ""
    -- 超大 base 文件不读取/哈希：候选本就因超过上限被跳过（见 `_capture_worker`），
    -- 在此哈希会白读数百 MB 并占用线程池（日志中同一批超大文件每条命令重复出现即此因）。
    if st and st.type == "file" and not (cap > 0 and (st.size or 0) > cap) then
      local content = ""
      local f = io.open(real, "rb")
      if f then content = f:read("*a") or ""; f:close() end
      h = "sha256:" .. sha(content)
    end
    enc(h)
  end
  return tostring(n) .. "\n" .. table.concat(out)
end

--- 异步登记 overlay 改动：遍历/读取/哈希 base 在 utils.work 线程池执行，
--- 主线程仅按预取结果登记 mapping（工作区跳过/上限判定仍与同步版一致）。
--- 遍历（scandir+stat）在单个 job；base 内容哈希按 `work_chunk_files` 分块并发补算（多核）。
--- @param attempt_id string
--- @param real_root string
--- @param upper_root string
--- @return Deferred
function M.capture_overlay_async(attempt_id, real_root, upper_root)
  local attempt = state.attempts[attempt_id]
  if not attempt then return async.resolve() end
  local work = require("NeoAI.utils.work")
  if not work.available() then
    M.capture_overlay(attempt_id, real_root, upper_root)
    return async.resolve()
  end
  local root = _abs(real_root):gsub("/$", "")
  local session_basename = require("NeoAI.sandbox.conceal").session_basename()
  local sha_src = require("NeoAI.utils.sha256").source
  local cap = _max_file_bytes()
  local expected_encoded = _encode_expected(state.materialized[upper_root])
  local ws_encoded = _encode_ws(state.workspace, root)
  return work.run(_capture_worker, upper_root, root, session_basename, expected_encoded, ws_encoded, cap):then_(function(encoded)
    local records = _decode_records(encoded, 10)
    -- 需要 base 内容哈希的记录（base 为文件）：由分块并行 job 补算。
    local need = {}
    for i, rec in ipairs(records) do
      if rec[5] == "file" then
        need[#need + 1] = { idx = i, real = root .. "/" .. rec[1] }
      end
    end
    local function apply_all()
      local recons = {}
      local mat = state.materialized[upper_root]
      --- 记录本次处理过的路径及其目标签名：下次捕获未变即在工作线程内跳过，
      --- 不再重复遍历/读/哈希/派发（「同一文件不重复处理」的核心）。
      local function remember(real, dest, dsig, deleted)
        if not mat then mat = {}; state.materialized[upper_root] = mat end
        if deleted then
          mat[real] = { dest = dest, deleted = true }
        elseif dsig and dsig ~= "" then
          mat[real] = { dest = dest, hash = "sha256:captured", dsig = dsig }
        end
      end
      for _, rec in ipairs(records) do
        local child_rel, staged, kind = rec[1], rec[2], rec[3]
        local real = root .. "/" .. child_rel
        if kind == "reconcile" then
          recons[#recons + 1] = child_rel
        elseif kind == "whiteout" then
          _capture_entry(attempt, root, staged, child_rel, {
            base_exists = rec[4] == "1",
            base_type = (rec[5] ~= "" and rec[5]) or nil,
            base_hash = (rec[6] ~= "" and rec[6]) or nil,
            staged_is_file = false,
            staged_size = 0,
            staged_mode = 0,
            ws_checked = true,
          }, cap)
          remember(real, staged, nil, true)
        elseif kind == "file" then
          _capture_entry(attempt, root, staged, child_rel, {
            base_exists = rec[4] == "1",
            base_type = (rec[5] ~= "" and rec[5]) or nil,
            base_hash = (rec[6] ~= "" and rec[6]) or nil,
            staged_is_file = rec[7] == "1",
            staged_size = tonumber(rec[8]) or 0,
            staged_mode = tonumber(rec[9]) or 0,
            ws_checked = true,
          }, cap)
          remember(real, staged, rec[10])
        elseif kind == "skip" then
          -- 超过单文件上限：不纳入候选，仅记录（与同步路径同一日志口径），并记目标签名，
          -- 下次捕获未变即跳过（不再重复日志/哈希）。
          remember(real, staged, rec[10])
          pcall(function()
            require("NeoAI.kernel.logger").warn(
              "[sandbox] 跳过超大候选文件（%d 字节 > 上限 %d）：%s",
              tonumber(rec[8]) or 0, cap, real)
          end)
        end
      end
      _apply_reconcile(recons)
    end
    if #need == 0 then
      apply_all()
      return
    end
    return work.batched(_chunk_list(need, _work_chunk_files()), _work_parallelism(), function(chunk)
      local reals = {}
      for _, item in ipairs(chunk) do reals[#reals + 1] = item.real end
      return work.run(_base_hash_worker, _encode_paths(reals), sha_src, cap):then_(function(henc)
        return _decode_records(henc, 1)
      end)
    end):then_(function(chunk_hashes)
      local k = 0
      for _, hashes in ipairs(chunk_hashes) do
        for _, h in ipairs(hashes) do
          k = k + 1
          records[need[k].idx][6] = h[1] or ""
        end
      end
      apply_all()
    end)
  end)
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
--- @param prefetch table|nil 工作线程预取结果：staged 路径 -> { exists, type, size, content }；
---   nil 时在主线程 fs_stat/读取（同步路径）。
--- @return table candidate
function M.finish(attempt_id, prefetch)
  local attempt = state.attempts[attempt_id]
  if not attempt then
    return nil
  end
  local files = {}
  local cap = _max_file_bytes()
  for real, entry in pairs(attempt.mapping) do
    local pf = prefetch and prefetch[entry.staged]
    local staged_stat
    if pf then
      staged_stat = pf.exists and { type = pf.type, size = pf.size } or nil
    else
      staged_stat = vim.uv.fs_stat(entry.staged)
    end
    -- 超大普通文件不纳入候选（避免读入内存 / 嵌入候选 JSON 阻塞主线程）。
    if cap > 0 and staged_stat and staged_stat.type == "file" and (staged_stat.size or 0) > cap then
      pcall(function()
        require("NeoAI.kernel.logger").warn(
          "[sandbox] 跳过超大候选文件（%d 字节 > 上限 %d）：%s", staged_stat.size, cap, real)
      end)
    else
      local action, after_hash, content
      if entry.base_type == "directory" then
        if staged_stat and staged_stat.type == "directory" then
          if not entry.base_exists then action = "mkdir" end
        else
          if entry.base_exists then action = "rmdir" end
        end
      else
        if staged_stat and staged_stat.type == "file" then
          content = pf and pf.content or _read(entry.staged)
          after_hash = pf and pf.after_hash or _sha(content)
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
          mode = (action == "create" or action == "modify") and entry.mode or nil,
          content = (action == "create" or action == "modify") and content or nil,
        }
      end
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

-- ========== 工作线程：候选文件读取（主线程只做判定/组装） ==========

--- 线程内读取各暂存文件内容（供 finish 判定改动与嵌入候选）。
--- 输入：`<n>\n` + n 条记录（字段：real, staged, base_exists, base_type, base_hash, view_base_hash）。
--- 输出：`<n>\n` + n 条记录（字段：staged, exists, type, size, content, after_hash）。
--- @param input string 编码的 mapping
--- @param cap number 单文件字节上限（>0 且超过时不读取内容，交由主线程跳过）
--- @param sha_src string 纯 Lua sha256 实现源码（线程内 load 得到 hex 函数）
--- @return string 编码的预取结果
local function _finish_worker(input, cap, sha_src)
  local sha = assert(load(sha_src))()
  local out = {}
  if type(input) ~= "string" then return "0\n" end
  local nl = input:find("\n", 1, true)
  local n = nl and (tonumber(input:sub(1, nl - 1)) or 0) or 0
  local pos = (nl or 0) + 1
  local function field()
    local colon = input:find(":", pos, true)
    if not colon then return nil end
    local len = tonumber(input:sub(pos, colon - 1)) or 0
    local val = input:sub(colon + 1, colon + len)
    pos = colon + len + 1
    return val
  end
  local function enc(s)
    s = s or ""
    out[#out + 1] = tostring(#s) .. ":" .. s
  end
  for _ = 1, n do
    field() -- real
    local staged = field()
    field(); field(); field(); field() -- base_exists/base_type/base_hash/view_base_hash
    local stat = vim.uv.fs_stat(staged)
    local content = ""
    local after_hash = ""
    if stat and stat.type == "file" then
      if cap <= 0 or (stat.size or 0) <= cap then
        local f = io.open(staged, "rb")
        if f then content = f:read("*a") or ""; f:close() end
      end
      after_hash = "sha256:" .. sha(content)
    end
    enc(staged); enc(stat and "1" or "0"); enc(stat and stat.type or "")
    enc(tostring(stat and stat.size or 0)); enc(content); enc(after_hash)
  end
  return tostring(n) .. "\n" .. table.concat(out)
end

--- 编码一组 mapping 条目供工作线程读取（字段：real, staged, base_exists, base_type, base_hash, view_base_hash）
--- @param entries table 条目数组
--- @return string
local function _encode_entries(entries)
  local out = {}
  local n = 0
  for _, entry in ipairs(entries) do
    local fields = {
      entry.real or "", entry.staged or "",
      entry.base_exists and "1" or "0", entry.base_type or "",
      entry.base_hash or "", entry.view_base_hash or "",
    }
    local parts = {}
    for _, s in ipairs(fields) do
      s = s or ""
      parts[#parts + 1] = tostring(#s) .. ":" .. s
    end
    out[#out + 1] = table.concat(parts)
    n = n + 1
  end
  return tostring(n) .. "\n" .. table.concat(out)
end

--- 异步冻结：暂存文件读取/哈希在 utils.work 线程池执行；主线程据预取结果组装候选。
--- 按 `work_chunk_files` 分块并发提交，使大量文件时用满线程池（多核）而非单核串行。
--- @param attempt_id string
--- @return Deferred resolve(candidate|nil)
function M.finish_async(attempt_id)
  local attempt = state.attempts[attempt_id]
  if not attempt then return async.resolve(M.finish(attempt_id)) end
  local work = require("NeoAI.utils.work")
  if not work.available() then return async.resolve(M.finish(attempt_id)) end
  local entries = {}
  for _, entry in pairs(attempt.mapping) do entries[#entries + 1] = entry end
  if #entries == 0 then return async.resolve(M.finish(attempt_id, {})) end
  local sha_src = require("NeoAI.utils.sha256").source
  local cap = _max_file_bytes()
  return work.batched(_chunk_list(entries, _work_chunk_files()), _work_parallelism(), function(chunk)
    return work.run(_finish_worker, _encode_entries(chunk), cap, sha_src)
  end):then_(function(results)
    local prefetch = {}
    for _, encoded in ipairs(results) do
      for _, rec in ipairs(_decode_records(encoded, 6)) do
        prefetch[rec[1]] = {
          exists = rec[2] == "1",
          type = (rec[3] ~= "" and rec[3]) or nil,
          size = tonumber(rec[4]) or 0,
          content = rec[5],
          after_hash = (rec[6] ~= "" and rec[6]) or nil,
        }
      end
    end
    return M.finish(attempt_id, prefetch)
  end)
end

--- CAS 发布候选到真实工作区
--- 仅当真实当前状态等于候选基线时应用；否则 CONFLICT（设计文档 §4.5）。
--- @param candidate table
--- @param opts table|nil { expected_base?: string }
--- @return table { ok, state, reason?, receipt? }
function M.publish(candidate, opts)
  opts = opts or {}
  -- 发布前校验（纵深防御）：候选路径可能来自落盘存储（本地可篡改）或旧版本记录。
  -- 逐文件重规范化：若解析结果与记录的路径不一致（`..`/符号链接被引入或替换），
  -- 或命中宿主敏感遮蔽路径，一律拒绝，绝不把内容写到未经验证的真实位置。
  local runtime = require("NeoAI.sandbox.runtime")
  for _, f in ipairs(candidate.files or {}) do
    if type(f.path) ~= "string" or f.path == "" then
      return { ok = false, state = "FAILED", reason = "INVALID_PATH" }
    end
    local canonical = _abs(f.path)
    if canonical ~= f.path then
      return { ok = false, state = "CONFLICT", reason = "PATH_CHANGED: " .. tostring(f.path) }
    end
    local masked = runtime.is_masked_path(canonical)
    if masked then
      return { ok = false, state = "FAILED", reason = "SANDBOX_MASKED_TARGET: " .. tostring(masked) }
    end
  end
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
  -- 应用：统一经 writer（先非 root，权限不足 → NEEDS_ROOT，待用户批准 root 写入）。
  local writer = require("NeoAI.sandbox.writer")
  for _, f in ipairs(candidate.files or {}) do
    local action, content
    if f.action == "create" or f.action == "modify" then
      action = "write"
      content = (secret.detokenize(f.content or ""))
    elseif f.action == "mkdir" then
      action = "mkdir"
    elseif f.action == "delete" then
      action = "delete"
    elseif f.action == "rmdir" then
      action = "rmdir"
    end
    if action then
      local res = writer.apply(action, f.path, content, {
        allow_root = opts.allow_root == true,
        prefer_sudo = opts.prefer_sudo == true,
        mode = f.mode,
      })
      if res.state == writer.STATE.NEEDS_ROOT then
        return { ok = false, state = "NEEDS_ROOT",
          reason = res.reason or ("WRITE_REQUIRES_ROOT: " .. f.path) }
      end
      if not res.ok then
        return { ok = false, state = "ROLLBACK_FAILED",
          reason = "WRITE_FAILED: " .. f.path .. " " .. tostring(res.err) }
      end
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
  -- 最后一个在途尝试结束：清理轮换时排队的旧会话目录。
  _flush_pending_cleanup()
end

--- 重置（测试用 / 关闭时）
--- @param timeout_ms number|nil 等待在途轮换迁移的上限（默认 60s；关闭时传短值避免卡住退出）
function M.reset(timeout_ms)
  _await_rotation(timeout_ms)
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
  _path_key_cache = {}
  state.session_id = nil
  state.session_seq = 0
  state.process_dir_cache = nil
  state.pending_cleanup = {}
  state.materialized = {}
  state.version = 0
  state.rotation = nil
end

return M
