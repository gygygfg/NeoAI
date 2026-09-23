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
  -- 无 overlay 播种视图：真实根 -> { dest, files = { [rel] = { mtime, size, mode } } }。
  -- 会话级增量：已播种且源未变的路径跳过，避免每条命令重复复制整个工作区。
  seeded = {},
  version = 0, -- 暂存版本计数器：每次新增/编辑/删除/合并暂存项时递增
  rotation = nil, -- 会话轮换的在途迁移（Deferred）；暂存访问前经 `_await_rotation` 等待完成
  volatile_cache = nil, -- { cfg = <配置引用>, fn = function } 易变包缓存匹配器缓存
}

--- 递增暂存版本（每次暂存内容变化时调用）
--- @return number
local function _bump_version()
  state.version = (state.version or 0) + 1
  return state.version
end

--- 诊断埋点：仅在 `tools.sandbox.diagnostics.enabled = true` 时写 NeoAI 日志（不改变行为）。
--- 用于排查暂存/捕获/物化的一致性问题（H1-H6）。
--- @param fmt string
--- @param ... any
local function _diag(fmt, ...)
  local ok, cfg = pcall(function()
    return require("NeoAI.kernel.config_store").get("tools.sandbox.diagnostics")
  end)
  if not (ok and type(cfg) == "table" and cfg.enabled == true) then return end
  local args = { ... }
  pcall(function()
    require("NeoAI.kernel.logger").info("[sandbox:candidate] " .. fmt, unpack(args))
  end)
end

-- ========== 私有函数 ==========

--- 取权限位（低 12 位，含 setuid/setgid/sticky）。st_mode 形如 0o104755；`% 4096` 即 0o7777 掩码。
--- 完整保留权限位：不因「安全默认」有意丢弃特殊位（权限以真实盘/暂存视图为准）。
--- @param mode number|nil
--- @return number|nil
local function _perm(mode)
  if type(mode) ~= "number" then return nil end
  return mode % 4096
end

local function _sha(content)
  local ok, hex = pcall(vim.fn.sha256, content or "")
  return ok and ("sha256:" .. hex) or "sha256:?"
end

--- 文件 stat 签名（`sig:<mtime.sec>:<mtime.nsec>:<size>`）：超大文件不读取内容做 CAS，
--- 改用此签名判定基线是否变化（与捕获阶段未变快速判定同口径，避免读取数百 MB）。
--- @param st table|nil vim.uv.fs_stat 结果
--- @return string|nil
local function _stat_sig(st)
  if not (st and st.type == "file" and st.mtime) then return nil end
  return string.format("sig:%s:%s:%s",
    tostring(st.mtime.sec), tostring(st.mtime.nsec), tostring(st.size))
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

--- 内容是否可安全当文本处理：合法 UTF-8 且不含 NUL。
--- 二进制（keyring/图片/可执行文件等）返回 false——绝不对其做密钥 token 化或 UTF-8 清洗，
--- 否则会把二进制当文本处理而损坏（如 OpenPGP keyring 被替换字符破坏）。
--- @param content string|nil
--- @return boolean
local function _is_text_content(content)
  if type(content) ~= "string" or content == "" then return true end
  if content:find("\0", 1, true) then return false end
  return require("NeoAI.utils.stringx").is_valid_utf8(content)
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
      -- 二进制内容（keyring 等）通常跳过文本 token 化；但**敏感二进制密钥文件**（.p12/.pfx/
      -- keystore/raw key 等）用同长度随机字节假化（整块映射），物化/发布时精确还原真实字节。
      local tok = c
      if _is_text_content(c) then
        tok = secret.tokenize(c, { entropy = secret.is_secret_path(real) })
        if tok ~= c then fs.write_file(staged, tok) end
      else
        local cfg = require("NeoAI.kernel.config_store").get("tools.sandbox.secrets") or {}
        if cfg.binary_fake ~= false and secret.is_sensitive_path(real) then
          local fake = secret.fake_binary(c)
          if fake ~= c then fs.write_file(staged, fake) end
          tok = fake
        end
      end
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
    base_mode = _perm(stat and stat.mode),
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

--- 进程 overlay 基目录的宿主根：由 `tools.sandbox.staging_backend` 决定（默认磁盘，
--- 见 conceal.base_host）；须位于所有可写根之外，避免 overlay 的 upper 落在 lower 之下
--- 导致内核 EINVAL。目录名由 conceal 统一生成（无特征命名，不暴露沙箱自身）。
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
  -- 轮换前等待在途后台后处理（捕获/冻结/合并）完成：`merge_candidate_async` 登记 `state.workspace`
  -- 条目后，暂存副本的写入是异步的。若此时轮换，尚未写出的副本会被下方 `staged_exists` 判定为
  -- 「缺失」而标记 `deleted=true`，随后物化为 whiteout（隐藏真实文件），表现为「命令产物在工具
  -- 调用之间回退」（安装报大量包、下一条命令又变回少量）。等待有上限（`shutdown_timeout_ms`），
  -- 避免后处理卡住时永久阻塞轮换。
  do
    local ok, wrapper = pcall(require, "NeoAI.sandbox.wrapper")
    if ok and type(wrapper.await_postprocess) == "function" then
      local timeout = tonumber(require("NeoAI.kernel.config_store").get("tools.sandbox.shutdown_timeout_ms"))
      if timeout == nil then timeout = 3000 end
      if timeout < 0 then timeout = 0 end
      pcall(wrapper.await_postprocess, timeout)
    end
  end
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
  state.seeded = {}
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

--- 登记一个「符号链接」候选（供 systemd enable/disable 等直接构造，不经 overlay 捕获）。
--- 暂存副本为符号链接本身；候选以目标字符串为「内容」发布（writer action="symlink"）。
--- @param attempt_id string
--- @param real_path string
--- @param target string 链接目标
--- @return table|nil entry
function M.stage_link(attempt_id, real_path, target)
  _await_rotation()
  local attempt = state.attempts[attempt_id]
  if not attempt then return nil end
  if type(target) ~= "string" or target == "" then return nil end
  local real = _abs(real_path)
  local staged = _workspace_path(real)
  fs.ensure_dir(vim.fn.fnamemodify(staged, ":h"))
  pcall(vim.uv.fs_unlink, staged)
  local lst = vim.uv.fs_lstat(real)
  local base_exists = lst ~= nil
  local base_hash = nil
  if base_exists and lst.type == "link" then
    base_hash = vim.uv.fs_readlink(real)
  end
  local ok = vim.uv.fs_symlink(target, staged)
  if not ok then return nil end
  local entry = {
    real = real, staged = staged, link = target,
    base_exists = base_exists, base_type = "link", base_hash = base_hash,
  }
  state.staged_to_real[staged] = real
  attempt.mapping[real] = entry
  state.workspace[real] = {
    staged = staged, link = target, base_hash = base_hash, deleted = false,
    version = _bump_version(),
  }
  return entry
end

--- 登记一个「删除」候选（供 systemd disable 等直接构造，不经 overlay 捕获）。
--- @param attempt_id string
--- @param real_path string
--- @return table|nil entry
function M.stage_delete(attempt_id, real_path)
  _await_rotation()
  local attempt = state.attempts[attempt_id]
  if not attempt then return nil end
  local real = _abs(real_path)
  local lst = vim.uv.fs_lstat(real)
  if not lst then return nil end
  local base_hash
  if lst.type == "link" then base_hash = vim.uv.fs_readlink(real)
  elseif lst.type == "file" then base_hash = _sha(_read(real)) end
  local entry = {
    real = real, staged = _workspace_path(real), deleted = true,
    base_exists = true, base_type = lst.type, base_hash = base_hash,
  }
  attempt.mapping[real] = entry
  state.workspace[real] = {
    staged = entry.staged, base_hash = base_hash, deleted = true, version = _bump_version(),
  }
  return entry
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
      -- 超大文件（内容以 blob 承载）：物化方据此后走「按文件复制」而非内嵌内容，
      -- 避免把数百 MB 内容经常驻命令服务器 stdin（bash 逐字节 read）传输。
      large = entry.large == true,
      -- 命令产物（run_command 捕获并合并）：常驻 overlay 已有其输出，暂存副本未再被编辑时
      -- 物化方可跳过回写（避免每次命令后把上千个包产物重发一遍）。
      fresh = entry.fresh == true,
      fresh_ssig = entry.fresh_ssig,
      -- 命令确在常驻 overlay 内执行：产物已存在于该 overlay，常驻物化可安全跳过。
      fresh_resident = entry.fresh_resident == true,
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

--- 路径本身（不跟随符号链接）是否为真实目录。
--- `vim.fn.isdirectory`/`fs.is_dir` 会跟随符号链接：`lib64 -> lib`（venv）这类链接会被
--- 误判为目录，从而把「暂存文件/链接覆盖链接目标为目录的路径」误报为类型冲突。此处用
--- lstat 只看路径自身类型：链接即链接，可在物化时安全 unlink 后重建。
--- @param path string
--- @return boolean
local function _is_real_dir(path)
  local st = vim.uv.fs_lstat(path)
  return st ~= nil and st.type == "directory"
end

--- 无 overlay 播种视图：把真实根内容复制进会话私有可写目录，使降级 bind 视图也能看到真实
--- 磁盘文件（写入仍落私有副本，真实盘只读；真实盘的后续外部改动在本会话内不反映）。
--- 会话级增量：已播种且源 mtime/size/mode 未变的路径跳过。返回统计；超过 max_bytes 时
--- `truncated=true`（调用方据此 fail-closed，不进入播种覆盖）。
--- @param src string 真实根
--- @param dst string 私有可写目录（bind 目标）
--- @param opts table|nil { max_bytes? number }
--- @return table { copied, skipped, bytes, truncated }
function M.seed_view(src, dst, opts)
  opts = opts or {}
  local max_bytes = tonumber(opts.max_bytes) or 0
  local rec = state.seeded[src]
  if not rec or rec.dest ~= dst then
    rec = { dest = dst, files = {} }
    state.seeded[src] = rec
  end
  local out = { copied = 0, skipped = 0, bytes = 0, truncated = false }
  local src_norm = tostring(src):gsub("/+$", "")
  local dst_norm = tostring(dst):gsub("/+$", "")
  local base_host = require("NeoAI.sandbox.conceal").base_host():gsub("/+$", "")
  local function _skip(p)
    if p == dst_norm or p:sub(1, #dst_norm + 1) == dst_norm .. "/" then return true end
    if p == base_host or p:sub(1, #base_host + 1) == base_host .. "/" then return true end
    return false
  end
  local function _dest(rel)
    return rel == "" and dst_norm or (dst_norm .. "/" .. rel)
  end
  local function walk(rel)
    if out.truncated then return end
    local abs = rel == "" and src_norm or (src_norm .. "/" .. rel)
    local handle = vim.uv.fs_scandir(abs)
    if not handle then return end
    while true do
      local name, typ = vim.uv.fs_scandir_next(handle)
      if not name then break end
      if out.truncated then break end
      local crel = rel == "" and name or (rel .. "/" .. name)
      local cabs = abs .. "/" .. name
      -- 已暂存删除的路径不播种（避免把命令删除的文件复活；删除由物化阶段保持）。
      local wse = state.workspace[src_norm .. "/" .. crel]
      if (not _skip(cabs)) and not (wse and wse.deleted) then
        local cdest = _dest(crel)
        if typ == "directory" then
          local existed = vim.fn.isdirectory(cdest) == 1
          fs.ensure_dir(cdest)
          local st = vim.uv.fs_stat(cabs)
          -- 不更改暂存视图中已存在目录的权限：仅新建时对齐真实盘。
          if (not existed) and st then pcall(fs.chmod, cdest, _perm(st.mode)) end
          walk(crel)
        elseif typ == "link" then
          local lst = vim.uv.fs_lstat(cabs)
          local target = vim.uv.fs_readlink(cabs)
          local sig = "L:" .. tostring(target) .. ":"
            .. tostring(lst and lst.mtime and lst.mtime.sec or "")
          local prev = rec.files[crel]
          if prev and prev.sig == sig then
            out.skipped = out.skipped + 1
          else
            pcall(vim.uv.fs_unlink, cdest)
            fs.ensure_dir(vim.fn.fnamemodify(cdest, ":h"))
            if pcall(vim.uv.fs_symlink, target, cdest) then rec.files[crel] = { sig = sig } end
            out.copied = out.copied + 1
          end
        elseif typ == "file" then
          local st = vim.uv.fs_stat(cabs)
          if st then
            local sig = string.format("F:%s:%s:%s", tostring(st.size),
              tostring(st.mtime and st.mtime.sec or ""), tostring(_perm(st.mode)))
            local prev = rec.files[crel]
            local existed = fs.exists(cdest)
            if prev and prev.sig == sig and existed then
              out.skipped = out.skipped + 1
            elseif max_bytes > 0 and (out.bytes + (st.size or 0)) > max_bytes then
              out.truncated = true
              break
            else
              fs.ensure_dir(vim.fn.fnamemodify(cdest, ":h"))
              if fs.copy_file(cabs, cdest) then
                -- 不更改暂存视图中已存在文件的权限：仅新建副本时对齐真实盘。
                if not existed then pcall(fs.chmod, cdest, _perm(st.mode)) end
                rec.files[crel] = { sig = sig }
                out.copied = out.copied + 1
                out.bytes = out.bytes + (st.size or 0)
              end
            end
          end
        end
        -- 其它类型（socket/device/fifo）跳过：不影响构建视图，复制可能失败/危险。
      end
    end
  end
  fs.ensure_dir(dst_norm)
  walk("")
  return out
end

--- 把工作区暂存内容物化进进程 overlay 的 upper，使 run_command 能看到 edit_file
--- 尚未发布的改动（双向互通）。删除的文件在 overlay 上以 whiteout（char 0:0）表示；
--- 无 mknod 权限时静默跳过（此时命令仍可能看到被删的真实文件，属已知限制）。
--- @param specs table 数组 { root, upper, work, mode }
--- @param opts table|nil { force?: boolean } force=true 时忽略版本检查全量重物化
---   （用于 overlay upper 被清空后重新填充，如 LSP overlay 刷新）。
function M.materialize_overlay(specs, opts)
  if not specs or #specs == 0 then return {} end
  local force = opts and opts.force == true
  -- 类型冲突（文件暂存物化到真实/overlay 中的目录，或反之）是视图损坏源：静默跳过会让
  -- 命令/只读工具看到真实目录、而暂存视图认为它是文件，二者分裂。此处收集并返回，
  -- 由调用方显式报错（H4）。
  local conflicts = {}
  for real, entry in pairs(state.workspace) do
    -- `.git` 内部也参与物化（对象先于指针的原子顺序在 apply 阶段保证；物化仅为沙箱视图）。
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
        elseif entry.link then
          -- 符号链接暂存：在 overlay/bind 层建立同名链接（覆盖既有文件/链接，不覆盖目录）。
          -- 目标本身是目录才冲突；指向目录的符号链接（如 venv `lib64 -> lib`）可安全替换。
          if _is_real_dir(dest) then
            conflicts[#conflicts + 1] = { real = real, dest = dest }
          else
            pcall(vim.uv.fs_unlink, dest)
            fs.ensure_dir(vim.fn.fnamemodify(dest, ":h"))
            vim.uv.fs_symlink(entry.link, dest)
            local mat = state.materialized[base]
            if not mat then mat = {}; state.materialized[base] = mat end
            mat[real] = { dest = dest, link = entry.link, version = entry.version }
          end
        elseif entry.staged and vim.fn.isdirectory(entry.staged) == 1 then
          -- 目录暂存（create_directory/ensure_dir）：在 overlay/bind 层建立同名目录，
          -- 使 run_command 能看到沙箱内新建的目录（含空目录）。
          fs.ensure_dir(dest)
          if entry.mode then fs.chmod(dest, entry.mode) end
        elseif entry.staged and fs.exists(entry.staged) then
          -- 类型冲突防御：真实盘/overlay 中该路径是目录时，文件物化会把目录替换成文件，
          -- 损坏沙箱视图一致性（后续 `ls dir/` 报 Not a directory）。此处收集冲突并返回，
          -- 由调用方显式报错（H4）——**绝不删除目录**（旧兜底的 `delete dest rf` 正是损坏来源）。
          -- 用 lstat 判定「本身是目录」：指向目录的符号链接（venv `lib64 -> lib`）不是目录，
          -- 可安全用文件/链接替换，不得误报冲突。
          if _is_real_dir(real) or _is_real_dir(dest) then
            conflicts[#conflicts + 1] = { real = real, dest = dest }
            pcall(function()
              require("NeoAI.kernel.logger").warn(
                "[sandbox] 类型冲突物化（目标为目录，拒绝文件覆盖）：%s", tostring(real))
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
                _diag("materialize fresh-skip（假定 dest 已最新，不重写）real=%s dest=%s", tostring(real), tostring(dest))
                local old = mat[real]
                mat[real] = {
                  dest = dest,
                  hash = (old and old.hash) or "sha256:fresh",
                  ssig = cur_ssig,
                  dsig = string.format("%s:%s:%s:%s",
                    tostring(dstat.mtime.sec), tostring(dstat.mtime.nsec), tostring(dstat.size),
                    tostring(dstat.mode % 4096)),
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
              -- 权限位变化（chmod，执行位等）也要重新物化：mtime/size 可能不变。
              and (dstat.mode % 4096) == (entry.mode or 420)
            if not unchanged then
              -- 原子替换：同目录临时文件 + rename。原先「先 delete 再 copy」在并行运行的
              -- 命令读到该路径时会看到缺失/半写内容（暂存文件系统原子性）；rename 原子生效。
              local is_large = entry.large == true
              local content
              if not is_large then
                content = fs.read_file(entry.staged)
                if content ~= nil then
                  -- 暂存视图对 AI 遮蔽了密钥（token 化），但命令执行层必须拿到**真实内容**：
                  -- 物化进 overlay 前把 token 还原，否则程序（pip/build/python 等）读到
                  -- NEOKEY_* 会失败（如 import 报错、构建 KeyError）。AI 侧仍读 token 视图。
                  content = (require("NeoAI.sandbox.secret").detokenize(content))
                end
              end
              if is_large or content ~= nil then
                fs.ensure_dir(vim.fn.fnamemodify(dest, ":h"))
                local mode = entry.mode or 420 -- 0644：保留原权限位，新建文件用常规默认（不强制 0600）
                local ok
                if is_large then
                  -- 大文件：直接文件复制（不读入 Lua 内存），临时文件 + rename 原子替换。
                  local tmp = dest .. ".neoai.tmp"
                  ok = fs.copy_file(entry.staged, tmp)
                  if ok then
                    pcall(vim.uv.fs_chmod, tmp, mode)
                    ok = vim.uv.fs_rename(tmp, dest)
                    if not ok then pcall(vim.uv.fs_unlink, tmp) end
                  end
                  if not ok and vim.fn.isdirectory(dest) == 0 then
                    pcall(vim.fn.delete, dest, "rf")
                    fs.copy_file(entry.staged, dest)
                    fs.chmod(dest, mode)
                  end
                else
                  -- overlay 私有可写层是会话级临时草稿（agentEnd 轮换即清理），无需 fsync 落盘；
                  -- 逐文件 fsync 在暂存量大时是主要卡顿源。
                  ok = fs.write_file_atomic(dest, content, { mode = mode, sync = false })
                  if not ok and vim.fn.isdirectory(dest) == 0 then
                    -- 兜底（rename 不适用等）：退回直接写 + chmod；目标为目录时不删目录。
                    pcall(vim.fn.delete, dest, "rf")
                    fs.ensure_dir(vim.fn.fnamemodify(dest, ":h"))
                    fs.write_file(dest, content)
                    fs.chmod(dest, mode)
                  end
                end
                local ndstat = vim.uv.fs_stat(dest)
                -- 记录写入内容哈希与两侧签名：capture 时工作线程据此判断命令是否改动
                -- （签名未变即跳过读取/哈希）；下次物化据此跳过未变文件。大文件用占位哈希
                -- （capture 未变判定只比较 dsig，不比较 hash 值）。
                mat[real] = {
                  dest = dest,
                  hash = is_large and "sha256:large" or ("sha256:" .. vim.fn.sha256(content)),
                  ssig = (sstat and sstat.mtime) and string.format("%s:%s:%s:%s",
                    tostring(sstat.mtime.sec), tostring(sstat.mtime.nsec), tostring(sstat.size), tostring(sstat.mode)) or nil,
                  dsig = (ndstat and ndstat.mtime) and string.format("%s:%s:%s:%s",
                    tostring(ndstat.mtime.sec), tostring(ndstat.mtime.nsec), tostring(ndstat.size),
                    tostring(ndstat.mode % 4096)) or nil,
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
  return conflicts
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
--- @param opts table|nil { from_command?: boolean, package?: boolean 包/生成内容跳过 token 化,
---   resident?: boolean 命令是否在常驻 overlay 内执行（产物已在该 overlay，常驻物化可跳过回写） }
--- 同步「视图同步条目」到工作区暂存（不产生发布候选）：命令还原暂存编辑后，暂存视图必须
--- 回到命令结果，并撤销该路径上已存在的待审候选（净效果为无改动）。
--- @param view_files table|nil
--- @param opts table|nil { package?: boolean }
local function _apply_view_files(view_files, opts)
  if not view_files or #view_files == 0 then return end
  opts = opts or {}
  local secret = require("NeoAI.sandbox.secret")
  local paths = {}
  for _, f in ipairs(view_files) do
    local ws = state.workspace[f.path]
    if ws and ws.staged and not ws.deleted then
      local content = f.content or ""
      if not opts.package and _is_text_content(content) then
        content = secret.tokenize(content, { entropy = secret.is_secret_path(f.path) })
      end
      fs.write_file(ws.staged, content)
      if f.mode then fs.chmod(ws.staged, f.mode) end
      ws.version = _bump_version()
      paths[#paths + 1] = f.path
    end
  end
  if #paths > 0 then
    pcall(function() require("NeoAI.sandbox.review").supersede_by_paths(paths) end)
  end
end

function M.merge_candidate(cand, opts)
  opts = opts or {}
  _apply_view_files(cand.view_files, opts)
  for _, f in ipairs(cand.files or {}) do
    local staged = _workspace_path(f.path)
    state.staged_to_real[staged] = f.path
    if f.link then
      -- 符号链接：暂存副本为链接本身；工作区登记 link 目标（read/materialize 据 link 处理）。
      fs.ensure_dir(vim.fn.fnamemodify(staged, ":h"))
      pcall(vim.uv.fs_unlink, staged)
      vim.uv.fs_symlink(f.link, staged)
      state.workspace[f.path] = {
        staged = staged, link = f.link, base_hash = f.before_hash,
        deleted = false, version = _bump_version(),
      }
    elseif f.action == "create" or f.action == "modify" then
      fs.ensure_dir(vim.fn.fnamemodify(staged, ":h"))
      if f.blob then
        -- 大文件：从 blob 复制到暂存副本（不读入内存），登记 large 供物化按文件复制。
        fs.copy_file(f.blob, staged)
        if f.mode then fs.chmod(staged, f.mode) end
        state.workspace[f.path] = {
          staged = staged, base_hash = f.before_hash, deleted = false, mode = f.mode,
          large = true, version = _bump_version(),
        }
      else
        -- 保持沙箱视图一致：命令产生的改动也以 token 形式进入暂存映射。
        -- 高熵扫描仅对疑似密钥文件启用（具名规则仍始终生效）。
        -- 包/生成内容（site-packages、node_modules 等）不做 token 化：与结算阶段跳过密钥
        -- 检测一致，避免对 venv/依赖树逐文件多次全文扫描（实测数十 MB 需数秒）。
        local content = f.content or ""
        if not opts.package and _is_text_content(content) then
          local secret = require("NeoAI.sandbox.secret")
          content = secret.tokenize(content, { entropy = secret.is_secret_path(f.path) })
        end
        fs.write_file(staged, content)
        if f.mode then fs.chmod(staged, f.mode) end
        state.workspace[f.path] = {
          staged = staged, base_hash = f.before_hash, deleted = false, mode = f.mode,
          fresh = opts.from_command == true,
          fresh_ssig = opts.from_command and _file_sig(staged) or nil,
          -- 仅当命令确实在常驻 overlay 内执行时，产物才已存在于该 overlay，常驻物化方可跳过回写。
          fresh_resident = opts.from_command == true and opts.resident == true,
          version = _bump_version(),
        }
      end
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
--- @param opts table|nil { from_command?: boolean, package?: boolean,
---   resident?: boolean 命令是否在常驻 overlay 内执行 }
--- @return Deferred resolve(cand)
function M.merge_candidate_async(cand, opts)
  opts = opts or {}
  local files = cand and cand.files or {}
  local texts, entropy_flags, text_files = {}, {}, {}
  local secret = require("NeoAI.sandbox.secret")
  for _, f in ipairs(files) do
    if (f.action == "create" or f.action == "modify") and not f.blob then
      -- 仅文本内容做 token 化；二进制（keyring 等）绝不当文本处理；大文件 blob 不做 token 化。
      if _is_text_content(f.content) then
        texts[#texts + 1] = f.content or ""
        -- 仅疑似密钥文件做高熵扫描（具名规则始终生效）。
        entropy_flags[#entropy_flags + 1] = secret.is_secret_path(f.path)
        text_files[#text_files + 1] = f
      end
    end
  end
  -- 视图同步条目同样需要 token 化后写入暂存（内容来自命令视图，可能含真实密钥）。
  for _, f in ipairs(cand.view_files or {}) do
    if _is_text_content(f.content) then
      texts[#texts + 1] = f.content or ""
      entropy_flags[#entropy_flags + 1] = secret.is_secret_path(f.path)
      text_files[#text_files + 1] = f
    end
  end
  --- 写暂存副本：写入（含内容）经线程池批量完成，主线程只登记映射与 fresh 签名。
  --- 删除/建目录仍在主线程（数量少、无内容）。
  --- @param tokenized table|nil 与 text_files 等长的 token 化结果；nil/空表示不做 token 化
  --- @return Deferred resolve(cand)
  local function apply_async(tokenized)
    local tok_of = {}
    if tokenized then
      for i, f in ipairs(text_files) do tok_of[f] = tokenized[i] end
    end
    local writes = {}
    local blob_jobs = {}
    for _, f in ipairs(files) do
      _diag("merge action=%s real=%s", tostring(f.action), tostring(f.path))
      local staged = _workspace_path(f.path)
      state.staged_to_real[staged] = f.path
      if f.link then
        -- 符号链接：暂存副本为链接本身；工作区登记 link 目标。
        fs.ensure_dir(vim.fn.fnamemodify(staged, ":h"))
        pcall(vim.uv.fs_unlink, staged)
        vim.uv.fs_symlink(f.link, staged)
        state.workspace[f.path] = {
          staged = staged, link = f.link, base_hash = f.before_hash,
          deleted = false, version = _bump_version(),
        }
      elseif f.action == "create" or f.action == "modify" then
        if f.blob then
          -- 大文件：从 blob 复制到暂存副本（不读入内存），登记 large 供物化按文件复制。
          blob_jobs[#blob_jobs + 1] = { src = f.blob, dst = staged, kind = "f", mode = f.mode }
          state.workspace[f.path] = {
            staged = staged, base_hash = f.before_hash, deleted = false, mode = f.mode,
            large = true, version = _bump_version(),
          }
        else
          writes[#writes + 1] = {
            path = staged, mode = f.mode, content = tok_of[f] or (f.content or ""),
          }
          state.workspace[f.path] = {
            staged = staged, base_hash = f.before_hash, deleted = false, mode = f.mode,
            fresh = opts.from_command == true,
            fresh_resident = opts.from_command == true and opts.resident == true,
            version = _bump_version(),
          }
        end
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
    -- 视图同步条目（命令还原暂存编辑）：写入暂存副本并撤销对应待审候选，不产生发布候选。
    do
      local view_paths = {}
      for _, f in ipairs(cand.view_files or {}) do
        local ws = state.workspace[f.path]
        if ws and ws.staged and not ws.deleted then
          local content = tok_of[f] or (f.content or "")
          fs.ensure_dir(vim.fn.fnamemodify(ws.staged, ":h"))
          fs.write_file(ws.staged, content)
          if f.mode then fs.chmod(ws.staged, f.mode) end
          ws.version = _bump_version()
          view_paths[#view_paths + 1] = f.path
        end
      end
      if #view_paths > 0 then
        pcall(function() require("NeoAI.sandbox.review").supersede_by_paths(view_paths) end)
      end
    end
    if #writes == 0 and #blob_jobs == 0 then return async.resolve(cand) end
    local work = require("NeoAI.utils.work")
    local function copy_blobs_sync()
      for _, j in ipairs(blob_jobs) do
        fs.ensure_dir(vim.fn.fnamemodify(j.dst, ":h"))
        fs.copy_file(j.src, j.dst)
        if j.mode then fs.chmod(j.dst, j.mode) end
      end
    end
    local function write_sync()
      for _, w in ipairs(writes) do
        fs.ensure_dir(vim.fn.fnamemodify(w.path, ":h"))
        fs.write_file(w.path, w.content)
        if w.mode then fs.chmod(w.path, w.mode) end
      end
    end
    if not work.available() then
      copy_blobs_sync()
      write_sync()
      mark_fresh()
      return async.resolve(cand)
    end
    -- 大量暂存写入：按 `work_chunk_files` 分块并发投递线程池（写盘用满多核），每块的编码
    -- 在 `work.batched` 的 start 回调内**惰性**完成——该回调按组在主线程调用，编码与上一组
    -- worker 的写盘重叠，避免一次性编码全部条目（1M 文件时约 20+ s 主线程）后单线程写盘。
    -- 大文件 blob 复制与文本写入并行提交（blob 复制是内核 copyfile，不占 Lua 主线程）。
    local all_sigs = opts.from_command and {} or nil
    local promises = {}
    if #blob_jobs > 0 then
      promises[#promises + 1] = work.run(_rotate_copy_worker, _encode_copy_jobs(blob_jobs))
    end
    if #writes > 0 then
      promises[#promises + 1] = work.batched(_chunk_list(writes, _work_chunk_files()), _work_parallelism(), function(chunk)
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
        return true
      end)
    end
    return async.all(promises):then_(function()
      mark_fresh(all_sigs)
      return cand
    end)
  end
  if #texts == 0 then
    return apply_async(nil)
  end
  -- 包/生成内容跳过 token 化（与结算阶段跳过密钥检测一致）。
  if opts.package then
    return apply_async(nil)
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

--- 单条暂存条目是否为「实质改动」（删除/新建/内容与基线不同/副本缺失）。
--- 目录条目本身不算实质改动：新建目录的可见性由其下文件条目承载，而空目录不应让
--- `has_staged()` 永为真、进而把无 overlay 的命令误判为视图分裂（SANDBOX_STAGING_UNCOVERED）。
--- @param entry table
--- @return boolean
local function _entry_is_staged(entry)
  if entry.deleted then return true end
  -- 目录暂存（create_directory / run_command 新建目录）不携带文件内容，跳过。
  if entry.link == nil and entry.staged and vim.fn.isdirectory(entry.staged) == 1 then
    return false
  end
  -- base_hash 为 nil 表示真实盘原不存在（新建文件/符号链接）。
  if entry.base_hash == nil then return true end
  if entry.staged and fs.exists(entry.staged) then
    local c = _read(entry.staged)
    if c == nil then return true end
    if _sha(c) ~= (entry.view_base_hash or entry.base_hash) then return true end
  else
    return true
  end
  return false
end

--- 覆盖所有已暂存路径所需的最小可写根（`known_roots` 之外的部分）。
--- 目的：让 `run_command` / 长驻服务 / 工具子进程的 overlay **始终**包含暂存文件所在目录，
--- 使命令视图与只读工具看到的暂存视图一致。否则工作区外的暂存编辑不会被物化，命令读到
--- 真实磁盘内容——既与 `read_file` 分裂（同一路径两种内容），也构成绕过暂存直接读写真实
--- 文件的旁路。
--- 返回「最近的存在祖先目录」（overlay lower 必须是存在的目录）；已被 `known_roots` 覆盖
--- 的路径不返回；返回的根之间互不嵌套（较浅的根覆盖较深者，避免嵌套 overlay）。
--- 根为 `/` 时无法安全收窄（会暴露整机），此处不返回，由调用方按「无 overlay 禁止降级」
--- fail-closed。
--- @param known_roots string[]|nil 已规划的可写根（cwd / process_roots / 工具可写根 / 包根）
--- @return string[] 需追加的可写根
function M.staged_overlay_roots(known_roots)
  _await_rotation()
  local function under(p, r)
    if r == "/" then return p:sub(1, 1) == "/" end
    return p == r or p:sub(1, #r + 1) == r .. "/"
  end
  local known = {}
  for _, r in ipairs(known_roots or {}) do
    if type(r) == "string" and r ~= "" then known[#known + 1] = fs.canonical(r) end
  end
  -- 最近存在祖先按「父目录」缓存：同一目录下的多个暂存文件（如缓存目录下成千上万文件）
  -- 只需解析一次，避免逐文件 `fnamemodify`/`isdirectory`——这是暂存量大后**每条命令**
  -- 重复支付的累计开销（冻结结果本身已由 `state.materialized` 增量跳过）。
  local resolved = {}
  local function resolve_dir(dir)
    local cached = resolved[dir]
    if cached ~= nil then return cached end
    local d = dir
    while d ~= "" and d ~= "/" and vim.fn.isdirectory(d) ~= 1 do
      local parent = d:match("^(.*)/[^/]+$")
      if parent == nil or parent == "" then parent = "/" end
      if parent == d then break end
      d = parent
    end
    local out = (d ~= "" and d ~= "/" and vim.fn.isdirectory(d) == 1) and d or false
    resolved[dir] = out
    return out
  end
  local candidates, seen = {}, {}
  for real, entry in pairs(state.workspace) do
    -- 只处理实质暂存改动：空操作/目录条目无需覆盖根，否则会多挂无用 overlay 并放大门禁开销。
    if _entry_is_staged(entry) then
      local covered = false
      for _, r in ipairs(known) do
        if under(real, r) then covered = true break end
      end
      if not covered then
        -- overlay lower 必须是存在的目录：向上找最近的存在祖先（按父目录去重解析）。
        local dir = real:match("^(.*)/[^/]+$")
        if dir == nil or dir == "" then dir = "/" end
        local d = resolve_dir(dir)
        if d and not seen[d] then seen[d] = true; candidates[#candidates + 1] = d end
      end
    end
  end
  -- 去重后按深度排序：浅根优先，跳过已被选中根覆盖者。
  local uniq = candidates
  table.sort(uniq, function(a, b)
    if #a ~= #b then return #a < #b end
    return a < b
  end)
  local out = {}
  for _, d in ipairs(uniq) do
    local covered = false
    for _, r in ipairs(out) do if under(d, r) then covered = true break end end
    if not covered then out[#out + 1] = d end
  end
  return out
end

--- 路径是否落在某个覆盖根之下（根为 "/" 表示全覆盖）。
--- @param path string
--- @param roots table
--- @return boolean
local function _under_any(path, roots)
  for _, r in ipairs(roots or {}) do
    if r == "/" then return true end
    r = tostring(r):gsub("/+$", "")
    if r ~= "" and (path == r or path:sub(1, #r + 1) == r .. "/") then return true end
  end
  return false
end

--- 是否存在**未发布的实质暂存改动**（与真实基线不同，或删除/新建）。
--- 供「无 overlay 时禁止降级」判定：若命令将运行在看不到 overlay 的降级 / 嵌套 userns
--- 模式下，命令会读到真实磁盘、与只读工具的暂存视图分裂，且可能绕过暂存直接读写真实文件，
--- 故必须 fail-closed。仅登记了暂存副本但内容与基线一致的（空操作）不计入。
--- @return boolean
function M.has_staged()
  _await_rotation()
  for _, entry in pairs(state.workspace) do
    if _entry_is_staged(entry) then return true end
  end
  return false
end

--- 是否存在**未被给定覆盖根覆盖**的未发布实质暂存改动。
--- 供「无 overlay / 播种视图」判定：只有落在已覆盖根（其真实内容将被物化/播种进私有视图）内的
--- 暂存改动才不构成视图分裂；覆盖根之外的暂存（命令看不到）仍必须 fail-closed。
--- @param covered_roots table|nil 覆盖根列表（含 "/" 表示全覆盖）
--- @return boolean
function M.has_staged_outside(covered_roots)
  _await_rotation()
  if not covered_roots or #covered_roots == 0 then return M.has_staged() end
  for real, entry in pairs(state.workspace) do
    if _entry_is_staged(entry) and not _under_any(real, covered_roots) then return true end
  end
  return false
end

--- 是否存在**落在给定根之下**的未发布实质暂存改动。
--- 供 T2（嵌套 userns，无 overlay，cwd 以会话私有 staging 呈现）判定：未播种时 cwd 内的暂存
--- 对命令不可见，属视图分裂；cwd 之外的暂存不在其工作集内，不阻塞命令（避免无关暂存把
--- systemctl/unshare 这类命令误拒）。
--- @param roots table 根列表
--- @return boolean
function M.has_staged_under(roots)
  _await_rotation()
  if not roots or #roots == 0 then return false end
  for real, entry in pairs(state.workspace) do
    if _entry_is_staged(entry) and _under_any(real, roots) then return true end
  end
  return false
end

--- 使某些真实路径的暂存副本失效（发布/拒绝后调用），下次编辑重新从真实文件复制。
--- 同时失效 overlay 视图中的同名物化条目：否则命令会继续读到发布/拒绝前的旧物化内容
--- （overlay upper 会话级持久、遮蔽 lower 的新真实内容），表现为「读到旧版本」。
--- 常驻实例已挂载时经其命名空间内删除（宿主侧改已挂载 upper 未定义）；否则宿主侧删除。
--- @param paths string|table
function M.invalidate(paths)
  if type(paths) == "string" then paths = { paths } end
  local reals = {}
  for _, p in ipairs(paths or {}) do
    local real = _abs(p)
    local ws = state.workspace[real]
    if ws then
      pcall(vim.fn.delete, ws.staged, "rf")
      state.staged_to_real[ws.staged] = nil
      state.workspace[real] = nil
    end
    reals[#reals + 1] = real
  end
  if #reals > 0 then
    local ok, resident = pcall(require, "NeoAI.sandbox.resident")
    if ok and resident and type(resident.invalidate_paths) == "function" and resident.active() then
      pcall(resident.invalidate_paths, reals)
    else
      M._invalidate_overlay_host(reals)
    end
  end
end

--- 宿主侧把真实盘内容同步进 overlay upper（无常驻实例时）。overlay lower 在挂载后变更不可靠
--- 可见，删除 upper 条目会回退到过期 lower，故写入真实内容：文件复制、目录建目录、不存在删除。
--- 仅在无常驻实例挂载时调用（发布/拒绝后命令已结束）。
--- @param reals table 规范化真实路径数组
function M._invalidate_overlay_host(reals)
  for _, real in ipairs(reals or {}) do
    for _, mat in pairs(state.materialized or {}) do
      local rec = mat[real]
      if rec and rec.dest then
        local st = vim.uv.fs_lstat(real)
        if st == nil then
          pcall(vim.fn.delete, rec.dest, "rf")
        elseif st.type == "file" then
          local dest = rec.dest
          pcall(vim.uv.fs_unlink, dest)
          fs.ensure_dir(vim.fn.fnamemodify(dest, ":h"))
          if fs.copy_file(real, dest) then
            pcall(vim.uv.fs_chmod, dest, st.mode % 4096)
          end
        elseif st.type == "directory" then
          fs.ensure_dir(rec.dest)
        end
        mat[real] = nil
      end
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
  -- 符号链接：命令创建/修改了链接（如 `systemctl enable` 的 .wants/*.service）。
  -- 以目标字符串登记（不读取/哈希链接目标内容）；发布时 writer action="symlink"。
  local link_target = prefetch and prefetch.link
  if not link_target then
    local lst = vim.uv.fs_lstat(staged)
    if lst and lst.type == "link" then link_target = vim.uv.fs_readlink(staged) end
  end
  if link_target then
    local stat = vim.uv.fs_lstat(real)
    local base_hash
    if stat and stat.type == "link" then base_hash = vim.uv.fs_readlink(real)
    elseif stat and stat.type == "file" then base_hash = _sha(_read(real)) end
    attempt.mapping[real] = {
      real = real, staged = staged, link = link_target,
      base_exists = stat ~= nil, base_type = (stat and stat.type) or nil,
      base_hash = base_hash,
    }
    return
  end
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
        if not (sstat and sstat.type == "file") then
          _diag("capture ws-skip（删除态未被重建）real=%s", tostring(real))
          return
        end
      elseif ws.staged and fs.exists(ws.staged) then
        local before = _read(ws.staged)
        local after = _read(staged)
        if before ~= nil and before == after then
          -- 内容与暂存一致；但命令可能仅改了权限（如 `chmod +x`）：此时不能跳过，
          -- 否则权限变化丢失（可执行位回归）。仅当权限位也一致时才视为未改动。
          local dst = vim.uv.fs_stat(staged)
          local dmode = dst and _perm(dst.mode)
          if not (ws.mode and dmode and ws.mode ~= dmode) then
            _diag("capture ws-skip（内容等于暂存，命令未改动）real=%s", tostring(real))
            return
          end
        end
      end
    end
  end
  local cap = cap or _max_file_bytes()
  local base_exists, base_type, base_hash, base_sig, staged_is_file, staged_size, staged_mode, base_mode, large
  if prefetch then
    base_exists, base_type, base_hash = prefetch.base_exists, prefetch.base_type, prefetch.base_hash
    base_sig = prefetch.base_sig
    staged_is_file, staged_size = prefetch.staged_is_file, prefetch.staged_size
    staged_mode = prefetch.staged_mode
    base_mode = prefetch.base_mode
    large = prefetch.large
  else
    local stat = vim.uv.fs_stat(real)
    base_exists = stat ~= nil
    base_type = stat and stat.type or nil
    base_mode = stat and stat.mode
    local staged_stat = vim.uv.fs_stat(staged)
    staged_is_file = staged_stat and staged_stat.type == "file"
    staged_size = staged_stat and staged_stat.size
    staged_mode = staged_stat and staged_stat.mode
    if cap > 0 and staged_is_file and (staged_size or 0) > cap then
      -- 超大文件：不做 base 内容哈希（避免读取数百 MB），改用 stat 签名做发布 CAS。
      large = true
      base_sig = (stat and stat.type == "file") and _stat_sig(stat) or nil
    else
      base_hash = (stat and stat.type == "file") and _sha(_read(real)) or nil
    end
  end
  attempt.mapping[real] = {
    real = real,
    staged = staged,
    base_exists = base_exists,
    base_type = base_type,
    base_hash = (base_type == "file") and base_hash or nil,
    base_sig = (base_type == "file") and base_sig or nil,
    large = large == true or nil,
    mode = staged_is_file and _perm(staged_mode) or nil,
    -- 基线（真实盘）权限位：内容未变但权限变化（如仅 `chmod +x`）时也需产生候选。
    base_mode = (base_type == "file") and _perm(base_mode) or nil,
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
      -- 会话 shell 状态 bind 挂载点（无特征名）不视为命令的文件改动。
      -- `.git` 内部**不在此排除**：改为在冻结阶段按 `git_path_class` 原子分类（对象先于指针）。
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
        elseif t == "link" then
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
--- @param paths_encoded string|nil 写日志「本轮写入/删除的绝对路径」集（nil=全量遍历；空=无改动）
--- @return string 编码记录
local function _capture_worker(upper_root, real_root, session_basename, expected_encoded, ws_encoded, cap, paths_encoded)
  --- 解码路径集（`<n>\n<len>:<path>...`），返回 set 或 nil。
  local function decode_set(encoded)
    if type(encoded) ~= "string" then return nil end
    local set = {}
    local nl = encoded:find("\n", 1, true)
    if not nl then return set end
    local n = tonumber(encoded:sub(1, nl - 1)) or 0
    local pos = nl + 1
    for _ = 1, n do
      local colon = encoded:find(":", pos, true)
      if not colon then break end
      local len = tonumber(encoded:sub(pos, colon - 1)) or 0
      set[encoded:sub(colon + 1, colon + len)] = true
      pos = colon + len + 1
    end
    return set
  end
  -- paths：非 nil 时按精确路径处理（写日志可信）；nil=全量遍历。
  local paths = decode_set(paths_encoded)
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
        local mode = field()
        if real then
          wsm[real] = { deleted = (staged == "D"), staged = staged, mode = tonumber(mode) or nil }
        end
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
  --- 由 stat 直接构造目标签名（避免再 stat 一次）。含权限位：仅 `chmod` 不改 mtime/size，
  --- 若签名不含 mode，物化后的目标被 chmod 会因签名未变而被「未改动」快速判定跳过，
  --- 导致权限变化丢失（可执行位回归缺陷）。
  local function dsig_of(st)
    if not (st and st.type == "file" and st.mtime) then return "" end
    return string.format("%s:%s:%s:%s",
      tostring(st.mtime.sec), tostring(st.mtime.nsec), tostring(st.size), tostring(st.mode % 4096))
  end
  --- 线程内工作区一致性判定：命令改动是否只是 AI 暂存编辑的复现（或删除态）。
  --- 与 `_capture_entry` 的 ws 分支同口径，但内容读取移到工作线程，避免主线程逐文件读盘。
  --- @param real string 真实路径
  --- @param dest string overlay 中实际路径
  --- @param sstat table|nil dest 的 stat
  --- @return boolean skip 是否跳过（不产生候选）
  local function ws_skip(real, dest, sstat)
    local w = wsm[real]
    if not w then return false end
    if w.deleted then
      -- 之前标记删除：仅当命令**重新创建**了普通文件时才视为改动（whiteout 设备节点仍跳过）。
      return not (sstat and sstat.type == "file")
    end
    if w.staged ~= "" then
      local before = read_all(w.staged)
      local after = read_all(dest)
      if before ~= nil and before == after then
        -- 内容一致；但命令可能仅改了权限（chmod）：权限位不同则不能跳过。
        local dmode = sstat and sstat.mode and (sstat.mode % 4096)
        if not (w.mode and dmode and w.mode ~= dmode) then return true end
      end
    end
    return false
  end

  --- 处理一条「文件」条目（walk 与写日志按路径驱动共用）。
  local function handle_file(child_rel, real, dest)
    -- 符号链接：以目标字符串登记（kind="link"），不跟随链接读取目标内容。
    local lst = vim.uv.fs_lstat(dest)
    if lst and lst.type == "link" then
      local target = vim.uv.fs_readlink(dest) or ""
      local rstat = vim.uv.fs_lstat(real)
      enc(child_rel); enc(dest); enc("link")
      enc(rstat and "1" or "0"); enc(rstat and rstat.type or ""); enc("")
      enc("0"); enc("0"); enc("0"); enc("")
      enc(target)
      enc(tostring(rstat and rstat.mode or 0))
      count = count + 1
      return
    end
    local exp = expected[real]
    -- 未变快速判定：物化时记录的目标签名（mtime/size/mode）未变即视为命令未改动，
    -- 直接跳过——不读文件、不做纯 Lua SHA。
    if exp and exp.hash and exp.dsig then
      local dsig = dsig_of(vim.uv.fs_stat(dest))
      if dsig ~= "" and dsig == exp.dsig then return end
    end
    local stat = vim.uv.fs_stat(real)
    local sstat = vim.uv.fs_stat(dest)
    if cap > 0 and sstat and sstat.type == "file" and (sstat.size or 0) > cap then
      -- 超大文件：仍登记为候选（kind="large"），内容在冻结阶段以 blob 落盘（不嵌入 JSON、
      -- 不做 base 内容哈希）。base_sig 供发布时以 stat 签名做 CAS（避免读取数百 MB）。
      enc(child_rel); enc(dest); enc("large")
      enc(stat and "1" or "0"); enc(stat and stat.type or ""); enc("")
      enc("1"); enc(tostring(sstat.size or 0)); enc(tostring(sstat.mode or 0))
      enc(dsig_of(sstat))
      enc((stat and stat.type == "file" and ("sig:" .. sig_of(real))) or "")
      enc(tostring(stat and stat.mode or 0))
      count = count + 1
    elseif not ws_skip(real, dest, sstat) then
      enc(child_rel); enc(dest); enc("file")
      enc(stat and "1" or "0"); enc(stat and stat.type or ""); enc("")
      enc((sstat and sstat.type == "file") and "1" or "0")
      enc(tostring(sstat and sstat.size or 0))
      enc(tostring(sstat and sstat.mode or 0))
      enc(dsig_of(sstat))
      enc("")
      enc(tostring(stat and stat.mode or 0))
      count = count + 1
    end
  end

  --- 处理 whiteout（命令删除 lower 中的文件）。
  local function handle_whiteout(child_rel, real, dest)
    local exp = expected[real]
    if exp and exp.deleted then return end -- 期望即删除态且未被命令重建：未改动，跳过
    local sstat = vim.uv.fs_stat(dest)
    if ws_skip(real, dest, sstat) then return end
    local stat = vim.uv.fs_stat(real)
    -- whiteout 删除的是基线文件，base_hash 需与真实内容一致（CAS 冲突检测依赖）。
    enc(child_rel); enc(dest); enc("whiteout")
    enc(stat and "1" or "0"); enc(stat and stat.type or ""); enc("")
    enc("0"); enc("0"); enc("0"); enc("")
    enc("")
    enc("")
    count = count + 1
  end

  --- 删除对账：期望物化的文件若 dest 与真实文件都不存在，说明命令删除了沙箱-only 文件
  --- （overlayfs 不会为 lower 不存在的文件生成 whiteout）。
  local function reconcile_one(real, exp)
    if exp and exp.hash and exp.dest then
      if not vim.uv.fs_lstat(exp.dest) and not vim.uv.fs_lstat(real) then
        enc(real); enc(""); enc("reconcile")
        enc("0"); enc(""); enc(""); enc("0"); enc("0"); enc("0"); enc("")
        enc("")
        enc("")
        count = count + 1
      end
    end
  end

  if paths ~= nil then
    -- 写日志按路径驱动：只处理本轮真正写入/删除的绝对路径（O(改动)），不再遍历累积 upper。
    for real in pairs(paths) do
      local rel = (real_root == "") and real:sub(2) or real:sub(#real_root + 2)
      if rel ~= "" then
        local dest = upper_root .. "/" .. rel
        local st = vim.uv.fs_lstat(dest)
        if st == nil then
          reconcile_one(real, expected[real])
        elseif st.type == "char" or st.type == "block" then
          handle_whiteout(rel, real, dest)
        elseif st.type ~= "directory" then
          handle_file(rel, real, dest)
        end
      end
    end
  else
    local function walk(dir, rel)
      local handle = vim.uv.fs_scandir(dir)
      if not handle then return end
      while true do
        local name, t = vim.uv.fs_scandir_next(handle)
        if not name then break end
        -- `.git` 内部不在此排除：冻结阶段按 `git_path_class` 原子分类（对象先于指针）。
        if name ~= ".wh..wh..opq" and name ~= session_basename then
          local whiteout, real_name = false, name
          if name:sub(1, 4) == ".wh." then
            whiteout, real_name = true, name:sub(5)
          elseif t == "char" or t == "block" then
            whiteout = true
          end
          local child_rel = rel == "" and real_name or (rel .. "/" .. real_name)
          local real = real_root .. "/" .. child_rel
          local dest = dir .. "/" .. name
          if whiteout then
            handle_whiteout(child_rel, real, dest)
          elseif t == "directory" then
            walk(dest, child_rel)
          elseif t == "file" then
            handle_file(child_rel, real, dest)
          elseif t == "link" then
            handle_file(child_rel, real, dest)
          end
        end
      end
    end
    walk(upper_root, "")
    for real, exp in pairs(expected) do reconcile_one(real, exp) end
  end
  return tostring(count) .. "\n" .. table.concat(out)
end

--- 编码物化期望表（real -> hash/"D" + dest）供 `_capture_worker` 比对。
--- @param mat table|nil state.materialized[base]
--- @param paths table|nil 写日志「本轮路径」集；非 nil 时只编码这些路径（增量，避免全量）
--- @return string
local function _encode_expected(mat, paths)
  local out = {}
  local n = 0
  local function f(s)
    s = s or ""
    return tostring(#s) .. ":" .. s
  end
  for real, rec in pairs(mat or {}) do
    if type(rec) == "table" and (paths == nil or paths[real] == true) then
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
--- @param paths table|nil 写日志「本轮路径」集；非 nil 时只编码这些路径（增量，避免全量）
--- @return string
local function _encode_ws(ws_map, root, paths)
  local out, n = {}, 0
  local function f(s)
    s = s or ""
    return tostring(#s) .. ":" .. s
  end
  local prefix = root and (root .. "/") or nil
  for real, ws in pairs(ws_map or {}) do
    if not prefix or real == root or real:sub(1, #prefix) == prefix then
      if paths == nil or paths[real] == true then
        local staged = ws.deleted and "D" or (ws.staged or "")
        out[#out + 1] = f(real) .. f(staged) .. f(tostring(ws.mode or ""))
        n = n + 1
      end
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
--- @param hint table|nil 写日志 { writes = {path=true}, deletes = {path=true} }（可信时）
--- @return Deferred
function M.capture_overlay_async(attempt_id, real_root, upper_root, hint)
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
  -- 写日志 → 本轮写入/删除的绝对路径集（仅本根子树）。hint 存在时 worker 按精确路径处理
  -- （O(本轮改动)）；hint 为 nil 时全量遍历（正确性优先）。
  local paths_encoded, paths_set
  if hint then
    local function under(p)
      if root == "" then return p:sub(1, 1) == "/" end
      return p == root or p:sub(1, #root + 1) == root .. "/"
    end
    local list = {}
    paths_set = {}
    for p in pairs(hint.writes or {}) do
      if under(p) and not paths_set[p] then paths_set[p] = true; list[#list + 1] = p end
    end
    for p in pairs(hint.deletes or {}) do
      if under(p) and not paths_set[p] then paths_set[p] = true; list[#list + 1] = p end
    end
    paths_encoded = _encode_paths(list)
  end
  local expected_encoded = _encode_expected(state.materialized[upper_root], paths_set)
  local ws_encoded = _encode_ws(state.workspace, root, paths_set)
  return work.run(_capture_worker, upper_root, root, session_basename, expected_encoded, ws_encoded, cap,
    paths_encoded):then_(function(encoded)
    local records = _decode_records(encoded, 12)
    -- 需要 base 内容哈希的记录（base 为文件，且非超大 blob 文件）：由分块并行 job 补算。
    local need = {}
    for i, rec in ipairs(records) do
      if rec[3] ~= "large" and rec[3] ~= "link" and rec[5] == "file" then
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
            base_mode = tonumber(rec[12]) or 0,
            ws_checked = true,
          }, cap)
          remember(real, staged, rec[10])
        elseif kind == "link" then
          _capture_entry(attempt, root, staged, child_rel, {
            base_exists = rec[4] == "1",
            base_type = (rec[5] ~= "" and rec[5]) or nil,
            base_hash = nil,
            link = rec[11],
            staged_is_file = false,
            staged_size = 0,
            staged_mode = 0,
            ws_checked = true,
          }, cap)
          remember(real, staged, nil, false)
        elseif kind == "large" then
          -- 超大文件：登记为候选（内容在冻结阶段以 blob 落盘），base_hash 留空、用 base_sig
          -- 做发布 CAS；不进入 `need`（避免主线程/线程池读取数百 MB 真实文件做内容哈希）。
          _capture_entry(attempt, root, staged, child_rel, {
            base_exists = rec[4] == "1",
            base_type = (rec[5] ~= "" and rec[5]) or nil,
            base_hash = nil,
            base_sig = (rec[11] ~= "" and rec[11]) or nil,
            staged_is_file = true,
            staged_size = tonumber(rec[8]) or 0,
            staged_mode = tonumber(rec[9]) or 0,
            base_mode = tonumber(rec[12]) or 0,
            ws_checked = true,
            large = true,
          }, cap)
          remember(real, staged, rec[10])
        elseif kind == "skip" then
          -- 兼容旧记录：超过单文件上限且未登记为候选（当前实现不再产生）。
          remember(real, staged, rec[10])
        end
      end
      do
        local counts = {}
        for _, rec in ipairs(records) do
          counts[rec[3]] = (counts[rec[3]] or 0) + 1
        end
        local parts = {}
        for k, v in pairs(counts) do parts[#parts + 1] = k .. "=" .. v end
        _diag("capture root=%s records=%d %s", tostring(root), #records, table.concat(parts, " "))
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

-- ========== 冻结前剔除「不可发布」文件 ==========
-- 目的：避免整单元因个别文件无法发布而失败——运行时被遮蔽的路径（发布硬拒绝）与
-- 包管理器易变索引/缓存（CAS 基线冲突）都不应阻塞其余文件的正常应用。

--- 易变包索引/缓存匹配器（配置 `tools.sandbox.packages.volatile_paths`，支持 `~` 与 glob）。
--- 结果按配置引用缓存；配置变更时自动重建。
--- @return function(path) -> boolean
local function _volatile_matcher()
  local cfg = require("NeoAI.kernel.config_store").get("tools.sandbox.packages") or {}
  local list = cfg.volatile_paths
  if state.volatile_cache and state.volatile_cache.cfg == list then return state.volatile_cache.fn end
  local roots = {}
  if type(list) == "table" then
    for _, p in ipairs(list) do
      if type(p) == "string" and p ~= "" and p ~= "/" then
        p = vim.fn.expand(p):gsub("/+$", "")
        if p ~= "" and p ~= "/" then
          if p:find("[*?[]") then
            local okg, matches = pcall(vim.fn.glob, p, false, true)
            if okg and type(matches) == "table" then
              for _, m in ipairs(matches) do
                m = m:gsub("/+$", "")
                if m ~= "" and m ~= "/" then roots[#roots + 1] = m end
              end
            end
          else
            roots[#roots + 1] = p
          end
        end
      end
    end
  end
  local function under(p, r) return p == r or p:sub(1, #r + 1) == r .. "/" end
  local fn = function(path)
    if type(path) ~= "string" or path == "" then return false end
    for _, r in ipairs(roots) do if under(path, r) then return true end end
    return false
  end
  state.volatile_cache = { cfg = list, fn = fn }
  return fn
end

--- 候选是否由包管理器产生（命令判定或路径特征），决定是否套用易变缓存过滤。
--- @param files table
--- @param attempt table|nil 控制层 attempt
--- @return boolean
local function _is_package_candidate(files, attempt)
  if attempt and attempt.package == true then return true end
  local ok, privilege = pcall(require, "NeoAI.sandbox.privilege")
  if not ok or type(privilege.package_path_manager) ~= "function" then return false end
  for _, f in ipairs(files or {}) do
    if privilege.package_path_manager(f.path) then return true end
  end
  return false
end

--- 剔除命中「有效遮蔽」与「易变包索引/缓存」的文件。
--- @param files table
--- @param attempt table|nil 控制层 attempt（含 effective_unmask / package）
--- @return table files 过滤后的文件
--- @return table dropped { masked=number, volatile=number, masked_paths=table, volatile_paths=table }
local function _filter_unpublishable(files, attempt)
  local runtime = require("NeoAI.sandbox.runtime")
  local unmask = attempt and attempt.effective_unmask or nil
  local is_pkg = _is_package_candidate(files, attempt)
  local volatile = is_pkg and _volatile_matcher() or nil
  local out = {}
  local dropped = { masked = 0, volatile = 0, git = 0, masked_paths = {}, volatile_paths = {}, git_paths = {} }
  for _, f in ipairs(files) do
    local gc = runtime.git_path_class(f.path)
    local is_obj_del = gc == "object" and (f.action == "delete" or f.action == "rmdir")
    if gc == "transient" or gc == "other" or is_obj_del then
      -- `.git` 瞬态（*.lock/gc.log）、配置类（config/hooks/info）与对象删除（gc/prune 的
      -- 剪枝）不纳入候选：对象删除绝不应用（保留多余对象无害，删除被引用的对象才会悬空）。
      dropped.git = dropped.git + 1
      if #dropped.git_paths < 20 then dropped.git_paths[#dropped.git_paths + 1] = f.path end
    elseif runtime.is_masked_path(f.path, unmask) then
      dropped.masked = dropped.masked + 1
      if #dropped.masked_paths < 20 then dropped.masked_paths[#dropped.masked_paths + 1] = f.path end
    elseif volatile and volatile(f.path) then
      dropped.volatile = dropped.volatile + 1
      if #dropped.volatile_paths < 20 then dropped.volatile_paths[#dropped.volatile_paths + 1] = f.path end
    else
      f.git_class = gc -- nil 表示普通文件；object/pointer 供原子排序与发布语义
      out[#out + 1] = f
    end
  end
  if dropped.masked > 0 or dropped.volatile > 0 or dropped.git > 0 then
    pcall(function()
      require("NeoAI.kernel.logger").warn(
        "[sandbox] 冻结时跳过不可发布文件：遮蔽 %d、易变缓存 %d、.git 内部 %d",
        dropped.masked, dropped.volatile, dropped.git)
    end)
  end
  return out, dropped
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
  -- 视图同步条目：命令结果等于真实基线（对真实盘无净改动），但**不等于当前工作区暂存**——
  -- 即命令把 AI 的暂存编辑还原了（如 `git checkout -- <file>`）。这类改动不产生发布候选，
  -- 但必须同步暂存视图，否则下次物化会用旧暂存内容覆盖命令结果（表现为「命令写入被回滚」）。
  local view_files = {}
  local cap = _max_file_bytes()
  for real, entry in pairs(attempt.mapping) do
    local pf = prefetch and prefetch[entry.staged]
    local staged_stat
    if pf then
      staged_stat = pf.exists and { type = pf.type, size = pf.size } or nil
    else
      staged_stat = vim.uv.fs_stat(entry.staged)
    end
    if entry.link then
      -- 符号链接候选（systemd enable/disable 等）：以目标字符串为「内容」发布/应用。
      local laction
      if not entry.base_exists then laction = "create"
      elseif entry.base_hash ~= entry.link then laction = "modify" end
      if laction then
        files[#files + 1] = {
          path = real, action = laction, link = entry.link,
          before_hash = entry.base_hash, base_exists = entry.base_exists, base_type = "link",
        }
      end
    else
    local is_large = entry.large == true
      or (cap > 0 and staged_stat and staged_stat.type == "file" and (staged_stat.size or 0) > cap)
    if is_large then
      -- 超大文件：内容以 blob 承载（不在候选 JSON 内嵌），发布/物化按文件复制。
      -- 改动判定用 stat 签名（after_hash），不读取内容。
      local action, after_hash, blob
      if staged_stat and staged_stat.type == "file" then
        if pf and pf.blob then
          after_hash = pf.after_hash
          blob = pf.blob
        else
          local full = vim.uv.fs_stat(entry.staged)
          after_hash = _stat_sig(full)
          blob = require("NeoAI.sandbox.store").copy_to_blob(entry.staged, entry.staged)
        end
        if not entry.base_exists then
          action = "create"
        elseif entry.base_type == "file" then
          if entry.base_sig ~= after_hash then action = "modify"
          elseif entry.mode and entry.base_mode and entry.mode ~= entry.base_mode then action = "modify" end
        else
          action = "modify"
        end
      else
        if entry.base_exists then action = "delete" end
      end
      if action then
        local ws = state.workspace[real]
        if ws then ws.deleted = (action == "delete" or action == "rmdir") end
        if action ~= "delete" and not blob then
          pcall(function()
            require("NeoAI.kernel.logger").warn(
              "[sandbox] 大文件 blob 复制失败，跳过候选：%s", real)
          end)
        else
          files[#files + 1] = {
            path = real,
            action = action,
            before_hash = entry.base_hash,
            before_sig = entry.base_sig,
            after_hash = after_hash,
            base_exists = entry.base_exists,
            base_type = entry.base_type,
            mode = (action == "create" or action == "modify") and entry.mode or nil,
            blob = (action == "create" or action == "modify") and blob or nil,
            large = true,
          }
        end
      end
    elseif cap > 0 and staged_stat and staged_stat.type == "file" and (staged_stat.size or 0) > cap then
      -- 未标记 large 但超限（旧 mapping / 兜底）：不纳入候选（避免读入内存 / 嵌入候选 JSON）。
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
          elseif entry.mode and entry.base_mode and entry.mode ~= entry.base_mode then
            -- 内容未变、仅权限变化（如 `chmod +x`）：仍需候选，否则可执行位丢失。
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
      elseif after_hash then
        -- 对真实盘无净改动；但若工作区暂存仍是旧内容，说明命令还原了暂存编辑，需同步视图。
        local ws = state.workspace[real]
        if ws and not ws.deleted and ws.staged and fs.exists(ws.staged) then
          local cur = _read(ws.staged)
          local cur_hash = cur and _sha(cur)
          if cur_hash and cur_hash ~= after_hash then
            view_files[#view_files + 1] = {
              path = real, action = "modify", content = content, mode = entry.mode,
            }
          end
        end
      end
    end
    end
  end
  table.sort(files, function(a, b) return a.path < b.path end)
  -- 剔除运行时遮蔽（发布硬拒绝）与易变包缓存（CAS 冲突）文件，避免整单元失败。
  local dropped
  files, dropped = _filter_unpublishable(files, attempt.attempt)
  local manifest = {}
  for _, f in ipairs(files) do
    manifest[#manifest + 1] = { path = f.path, action = f.action, after_hash = f.after_hash }
  end
  local candidate = {
    candidate_digest = _sha(require("NeoAI.utils.json").encode(manifest)),
    files = files,
    -- 仅用于同步工作区暂存视图（不发布、不入待审）；见 finish 中的说明。
    view_files = (#view_files > 0) and view_files or nil,
    created_at = os.time(),
    command_id = attempt.attempt.command_id,
    attempt_id = attempt_id,
    effect = attempt.attempt.effect,
    dropped = (dropped and (dropped.masked > 0 or dropped.volatile > 0 or dropped.git > 0)) and dropped or nil,
  }
  return candidate
end

-- ========== 工作线程：候选文件读取（主线程只做判定/组装） ==========

--- 线程内读取各暂存文件内容（供 finish 判定改动与嵌入候选）。
--- 输入：`<n>\n` + n 条记录（字段：real, staged, base_exists, base_type, base_hash, view_base_hash）。
--- 输出：`<n>\n` + n 条记录（字段：staged, exists, type, size, content, after_hash, blob）。
--- 超过 `cap` 的文件不读取内容，而是复制为 blob（`blob_dir/<sha(staged)>`），`after_hash` 用
--- stat 签名（避免读取/哈希数百 MB）；`content` 留空、`blob` 非空。
--- @param input string 编码的 mapping
--- @param cap number 单文件字节上限（>0 且超过时走 blob）
--- @param sha_src string 纯 Lua sha256 实现源码（线程内 load 得到 hex 函数）
--- @param blob_dir string blob 存储目录
--- @return string 编码的预取结果
local function _finish_worker(input, cap, sha_src, blob_dir)
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
    local blob = ""
    if stat and stat.type == "file" then
      if cap <= 0 or (stat.size or 0) <= cap then
        local f = io.open(staged, "rb")
        if f then content = f:read("*a") or ""; f:close() end
        after_hash = "sha256:" .. sha(content)
      else
        -- 超大文件：内容复制为 blob（不在候选 JSON 内嵌），哈希用 stat 签名。
        local target = blob_dir ~= "" and (blob_dir .. "/" .. sha(staged)) or ""
        if target ~= "" then
          local ok = pcall(vim.uv.fs_copyfile, staged, target)
          if ok then
            blob = target
            -- fs_copyfile 不保留权限位；显式 chmod，避免执行位在发布后丢失。
            if stat.mode then pcall(vim.uv.fs_chmod, target, stat.mode % 4096) end
          end
        end
        after_hash = (stat.mtime and string.format("sig:%s:%s:%s",
          tostring(stat.mtime.sec), tostring(stat.mtime.nsec), tostring(stat.size)))
          or ("sig:" .. tostring(stat.size or 0))
      end
    end
    enc(staged); enc(stat and "1" or "0"); enc(stat and stat.type or "")
    enc(tostring(stat and stat.size or 0)); enc(content); enc(after_hash); enc(blob)
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
  local blob_dir = require("NeoAI.sandbox.store").blobs_dir() or ""
  return work.batched(_chunk_list(entries, _work_chunk_files()), _work_parallelism(), function(chunk)
    return work.run(_finish_worker, _encode_entries(chunk), cap, sha_src, blob_dir)
  end):then_(function(results)
    local prefetch = {}
    for _, encoded in ipairs(results) do
      for _, rec in ipairs(_decode_records(encoded, 7)) do
        prefetch[rec[1]] = {
          exists = rec[2] == "1",
          type = (rec[3] ~= "" and rec[3]) or nil,
          size = tonumber(rec[4]) or 0,
          content = rec[5],
          after_hash = (rec[6] ~= "" and rec[6]) or nil,
          blob = (rec[7] ~= "" and rec[7]) or nil,
        }
      end
    end
    return M.finish(attempt_id, prefetch)
  end)
end

--- 发布应用顺序：删除/rmdir 先于写入，且同组内「子路径先于父路径」（删除）/
--- 「父路径先于子路径」（写入）。否则 `rm -rf <dir>` 产生的候选会按路径升序先对
--- 非空父目录 rmdir，导致整个变更单元 WRITE_FAILED。
--- @param files table
--- @return table 排序后的副本
local function _apply_order(files)
  local runtime = require("NeoAI.sandbox.runtime")
  local out = {}
  for i, f in ipairs(files) do out[i] = f end
  local function is_del(f) return f.action == "delete" or f.action == "rmdir" end
  local function is_ancestor(a, b) return #a < #b and b:sub(1, #a + 1) == a .. "/" end
  -- 原子顺序：git 对象库（不可变/可累加）→ 普通文件 → git 指针（index/refs/HEAD）。
  -- 对象先于指针，保证任何被写入的索引/refs 所引用的对象都已存在（绝不悬空）。
  local function rank(f)
    local gc = f.git_class or runtime.git_path_class(f.path)
    if gc == "object" then return 0 end
    if gc == "pointer" then return 2 end
    return 1
  end
  table.sort(out, function(a, b)
    local ra, rb = rank(a), rank(b)
    if ra ~= rb then return ra < rb end
    local da, db = is_del(a), is_del(b)
    if da ~= db then return da end
    if is_ancestor(a.path, b.path) then return not da end
    if is_ancestor(b.path, a.path) then return da end
    return a.path < b.path
  end)
  return out
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
    -- `.git` 瞬态/配置类绝不发布（对象/指针按原子顺序发布，见 _apply_order）。
    local gc = runtime.git_path_class(canonical)
    if gc == "transient" or gc == "other" then
      return { ok = false, state = "FAILED", reason = "SANDBOX_GIT_INTERNAL: " .. tostring(canonical) }
    end
  end
  -- 冲突预检：任一文件真实状态偏离基线则整体拒绝。
  -- 例外：git 对象库（内容寻址、不可变、可累加）不做 CAS——写前已存在即幂等满足。
  for _, f in ipairs(candidate.files or {}) do
    local gc = f.git_class or runtime.git_path_class(f.path)
    if gc ~= "object" then
      local lstat = vim.uv.fs_lstat(f.path)
      local stat = vim.uv.fs_stat(f.path)
      local exists = lstat ~= nil
      if f.link then
        -- 符号链接：以 lstat/readlink 做 CAS（fs_stat 会跟随链接）。
        if f.action == "create" then
          if exists then
            return { ok = false, state = "CONFLICT", reason = "TARGET_ALREADY_EXISTS: " .. f.path }
          end
        else
          if not exists then
            return { ok = false, state = "CONFLICT", reason = "TARGET_MISSING: " .. f.path }
          end
          if lstat.type ~= "link" or vim.uv.fs_readlink(f.path) ~= f.before_hash then
            return { ok = false, state = "CONFLICT", reason = "BASELINE_CHANGED: " .. f.path }
          end
        end
      elseif f.action == "create" or f.action == "mkdir" then
        if exists then
          return { ok = false, state = "CONFLICT", reason = "TARGET_ALREADY_EXISTS: " .. f.path }
        end
      else
        if not exists then
          return { ok = false, state = "CONFLICT", reason = "TARGET_MISSING: " .. f.path }
        end
        if f.base_type == "link" then
          -- 基线是符号链接（disable/替换）：用 lstat/readlink 做 CAS。
          if lstat.type ~= "link" or vim.uv.fs_readlink(f.path) ~= f.before_hash then
            return { ok = false, state = "CONFLICT", reason = "BASELINE_CHANGED: " .. f.path }
          end
        elseif stat and stat.type == "file" then
          if f.before_sig then
            -- 超大文件：用 stat 签名做 CAS（不读取数百 MB 内容）。
            if _stat_sig(stat) ~= f.before_sig then
              return { ok = false, state = "CONFLICT", reason = "BASELINE_CHANGED: " .. f.path }
            end
          else
            local cur = _read(f.path)
            if _sha(cur) ~= f.before_hash then
              return { ok = false, state = "CONFLICT", reason = "BASELINE_CHANGED: " .. f.path }
            end
          end
        end
      end
    end
  end
  -- 出沙箱解密预检：任何未解析的 token（映射缺失，如热重载后）都拒绝发布，
  -- 绝不把 token 当内容写进真实文件（fail-closed）。
  local secret = require("NeoAI.sandbox.secret")
  for _, f in ipairs(candidate.files or {}) do
    if (f.action == "create" or f.action == "modify") and not f.blob and not f.link then
      local _, unresolved = secret.detokenize(f.content or "")
      if unresolved > 0 then
        return { ok = false, state = "FAILED", reason = "SECRET_UNRESOLVED: " .. f.path }
      end
    end
  end
  -- 应用：统一经 writer（先非 root，权限不足 → NEEDS_ROOT，待用户批准 root 写入）。
  local writer = require("NeoAI.sandbox.writer")
  for _, f in ipairs(_apply_order(candidate.files or {})) do
    local action, content
    if f.link then
      action = "symlink"
      content = f.link
    elseif f.action == "create" or f.action == "modify" then
      action = "write"
      content = (secret.detokenize(f.content or ""))
      -- 数据流账本：记录假密钥在宿主落盘路径的汇聚点。
      pcall(function()
        require("NeoAI.sandbox.secret_flow").record("commit", { path = f.path })
      end)
    elseif f.action == "mkdir" then
      action = "mkdir"
    elseif f.action == "delete" then
      action = "delete"
    elseif f.action == "rmdir" then
      action = "rmdir"
    end
    local gc = f.git_class or runtime.git_path_class(f.path)
    -- git 对象库内容寻址：目标已存在即内容相同（幂等），跳过写入。
    if action == "write" and gc == "object" and vim.uv.fs_stat(f.path) then
      action = nil
    end
    if action then
      local res
      if action == "write" and f.blob then
        -- 大文件：直接按文件复制（不读入 Lua 内存）。
        res = writer.apply_file("write", f.path, f.blob, {
          allow_root = opts.allow_root == true,
          prefer_sudo = opts.prefer_sudo == true,
          mode = f.mode,
        })
      else
        res = writer.apply(action, f.path, content, {
          allow_root = opts.allow_root == true,
          prefer_sudo = opts.prefer_sudo == true,
          mode = f.mode,
        })
      end
      if res.state == writer.STATE.NEEDS_ROOT then
        return { ok = false, state = "NEEDS_ROOT",
          reason = res.reason or ("WRITE_REQUIRES_ROOT: " .. f.path) }
      end
      if not res.ok then
        return { ok = false, state = "FAILED",
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
  state.seeded = {}
  state.version = 0
  state.rotation = nil
end

return M
