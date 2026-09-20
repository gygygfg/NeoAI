--- 沙箱执行门禁
--- @module NeoAI.sandbox.wrapper
--- 所有工具执行的唯一强制入口：预检 → 隔离执行 → 冻结候选 → 异步确认 → CAS 发布。
--- 由 tools/executor 在调用工具前调用；加载器负责为工具附加 __sandbox 规格。
---
--- 异步模型（设计文档 §15）：AI 的工具调用立即在沙箱内执行并冻结候选，不阻塞等待；
--- 真实工作区的修改进入待审队列，由用户异步确认后 CAS 应用。

local async = require("NeoAI.utils.async")
local config_store = require("NeoAI.kernel.config_store")
local tool_spec = require("NeoAI.sandbox.tool_spec")
local control = require("NeoAI.sandbox.control")
local policy = require("NeoAI.sandbox.policy")
local candidate = require("NeoAI.sandbox.candidate")
local runtime = require("NeoAI.sandbox.runtime")
local store = require("NeoAI.sandbox.store")
local impact = require("NeoAI.sandbox.impact")
local evidence = require("NeoAI.sandbox.evidence")
local grant = require("NeoAI.sandbox.grant")
local envelope = require("NeoAI.sandbox.envelope")
local replay = require("NeoAI.sandbox.replay")
local fs = require("NeoAI.utils.fs")

local M = {}

-- ========== 进程命令串行化 ==========

-- 沙箱的 overlay 物化/捕获、会话级可写层、暂存映射与捕获来源均基于「共享会话」，**非并发
-- 安全**。同一轮里模型并行发出的多个 `run_command`（并行 tool_calls）会互相污染：物化/捕获
-- 交错导致命令看到缺失的目录/文件、捕获互相覆盖，命令可能因此阻塞直到超时并被 `cgroup.kill`
-- 以 SIGKILL 终止（退出码 137，且无输出）。此处把 `effect == "process"` 的门禁按 FIFO
-- **串行**执行（一次一个），其余工具（read/fs_write/in_process/network）不受影响。
local process_mutex = { busy = false, queue = {} }

-- 后台后处理链（命令进程退出后的捕获/冻结/合并/落盘/结算）。`postprocess = "async"`（默认）
-- 时工具结果在进程退出后立即返回，此链在后台完成；`_serialize_process` 在释放 FIFO 槽位前
-- 等待它，保证下一进程命令看到一致的会话暂存。
local postprocess = { pending = nil, seq = 0 }

--- 登记后台后处理链（用于 FIFO 保持与测试/关闭时等待）。
--- @param def Deferred
local function _track_postprocess(def)
  postprocess.seq = postprocess.seq + 1
  local my = postprocess.seq
  postprocess.pending = def
  local function clear()
    if postprocess.seq == my and postprocess.pending == def then postprocess.pending = nil end
  end
  def:then_(clear, clear)
end

--- 串行执行一个返回 Deferred 的进程门禁任务（FIFO）。
--- @param fn function() -> Deferred
--- @return Deferred
local function _serialize_process(fn)
  local out = async.Deferred.new()
  local function run()
    local released = false
    local function release()
      if released then return end
      released = true
      local function advance()
        -- 移除当前运行项（table.remove 返回被移除的元素，不能当作「下一项」），再取队首。
        table.remove(process_mutex.queue, 1)
        local nxt = process_mutex.queue[1]
        if nxt then vim.schedule(nxt) else process_mutex.busy = false end
      end
      -- async 后处理：结果已返回，但 FIFO 槽位保持到后台链完成，避免下一命令与暂存合并竞争。
      local pending = postprocess.pending
      if pending then pending:then_(advance, advance) else advance() end
    end
    local ok, inner = pcall(fn)
    if not ok then release(); out:reject(inner); return end
    if type(inner) ~= "table" or type(inner.then_) ~= "function" then
      release(); out:resolve(inner); return
    end
    inner:then_(function(v) release(); out:resolve(v) end,
                function(e) release(); out:reject(e) end)
  end
  process_mutex.queue[#process_mutex.queue + 1] = run
  if not process_mutex.busy then
    process_mutex.busy = true
    vim.schedule(run)
  end
  return out
end

-- ========== 私有函数 ==========

--- 为工具附加沙箱规格（幂等）
--- @param tool table
--- @return table
function M.attach(tool)
  if type(tool) ~= "table" then return tool end
  if tool.__sandboxed and tool.__sandbox_spec then return tool end
  local spec = tool_spec.get(tool.name, tool.category)
  -- 长驻服务工具（service_*）：门禁仍完成预检/脚本扫描/硬拒绝，但不进入一次性进程的
  -- overlay 捕获/冻结流程；隔离与候选结算由 sandbox.service 自建。
  if tool.long_lived then spec.long_lived = true end
  tool.__sandboxed = true
  tool.__sandbox_spec = spec
  return tool
end

--- 是否为已附加规格的工具
--- @param tool table
--- @return boolean
function M.is_attached(tool)
  return type(tool) == "table" and tool.__sandboxed == true
end

--- 按「暂存路径 -> 真实路径」映射还原值中的路径（字符串/字符串字段）。
--- 工具被门禁重写到私有副本执行，其回传消息里会带暂存路径；对模型而言这些路径
--- 不应存在（会误导后续操作），统一还原成真实工作区路径，使沙箱对 AI 不可见。
--- @param rev table staged -> real
--- @param value any
--- @return any
local function _rewrite_value(rev, value)
  if not next(rev) then return value end
  -- 粗粒度前缀提示（暂存路径前两级目录，通常仅 1~3 个根）：结果字符串不含任一提示时
  -- 不可能包含暂存路径，直接跳过逐条 gsub。暂存上万文件时，此前每个输出字符串都要对
  -- 全部暂存路径各做一次全文扫描（O(字符串×N)）；加守卫后无暂存路径的常规输出为 O(1)。
  local hints = {}
  for staged in pairs(rev) do
    hints[staged:match("^(/[^/]+/[^/]+)") or staged] = true
  end
  local hint_list = {}
  for h in pairs(hints) do hint_list[#hint_list + 1] = h end
  local function maybe(s)
    for _, h in ipairs(hint_list) do
      if s:find(h, 1, true) then return true end
    end
    return false
  end
  local function rewrite_str(s)
    if not maybe(s) then return s end
    local out = s
    for staged, real in pairs(rev) do
      out = out:gsub(vim.pesc(staged), (real:gsub("%%", "%%%%")))
    end
    return out
  end
  if type(value) == "string" then return rewrite_str(value) end
  if type(value) == "table" then
    for k, v in pairs(value) do
      if type(v) == "string" then value[k] = rewrite_str(v) end
    end
    return value
  end
  return value
end

--- 把工具结果中的沙箱暂存路径还原为真实路径（基于 attempt 映射）。
--- @param mapping table real -> { staged, ... }
--- @param value any
--- @return any
local function _rewrite_result(mapping, value)
  local rev = {}
  for real, entry in pairs(mapping or {}) do
    if entry.staged and entry.staged ~= real then rev[entry.staged] = real end
  end
  return _rewrite_value(rev, value)
end

-- 供测试直接验证路径还原与「无暂存路径快速跳过」语义。
M._rewrite_value = _rewrite_value
M._rewrite_result = _rewrite_result

--- 可写根路径编码为 overlay 子目录名
--- @param root string
--- @return string
local function _enc_root(root)
  return (root:gsub("^/", ""):gsub("/", "_"))
end

--- 包安装命令的宿主状态目录（可写 overlay 暂存）。仅当命令被判定为包安装时加入可写根，
--- 使 apt/dpkg/pip/npm 等能写入索引/缓存/元数据；写入同样冻结为候选。支持 `~` 展开。
--- @return table 已存在目录数组
local function _package_roots()
  local pkg = config_store.get("tools.sandbox.packages") or {}
  local list = pkg.roots
  if type(list) ~= "table" then return {} end
  local out, seen = {}, {}
  for _, r in ipairs(list) do
    if type(r) == "string" and r ~= "" and r ~= "/" then
      local p = vim.fn.expand(r):gsub("/+$", "")
      if p ~= "" and not seen[p] and vim.fn.isdirectory(p) == 1 then
        seen[p] = true
        out[#out + 1] = p
      end
    end
  end
  return out
end

--- 沙箱内已是 root（完整能力）：剥掉 `sudo`/`doas`（及其选项），使 `sudo apt update`
--- 等价于 `apt update`。沙箱用独立 userns 时仅映射 uid 0，sudo 的 `setresuid(...,1,...)`
--- 会 EINVAL，且 `/etc/sudoers` 被遮蔽，故 sudo 无意义且必然失败（`PERM_SUDOERS`）。
--- 处理**每个命令段**（按未加引号的 `; & | && ||` 换行切分），故 `a && sudo b`、多行脚本、
--- `sudo -u user cmd`、`sudo -i` 等都不再报错；保留包装器（env/command/nohup/…）与其余原文
--- （不改动引号内空白）。
--- @param cmd string|nil
--- @return string|nil
local SUDO_VALUE_OPTS = {
  ["-u"] = true, ["-g"] = true, ["-p"] = true, ["-C"] = true, ["-h"] = true,
  ["-r"] = true, ["-t"] = true, ["-U"] = true,
  ["--user"] = true, ["--group"] = true, ["--prompt"] = true, ["--close-from"] = true,
  ["--host"] = true, ["--role"] = true, ["--type"] = true, ["--other-user"] = true,
}
local SUDO_PREFIX_WRAPPERS = {
  env = true, command = true, nohup = true, time = true, nice = true,
  ionice = true, stdbuf = true, xargs = true,
}

--- @param w string
--- @return boolean 是否为 sudo/doas 可执行名（含 `/usr/bin/sudo` 等绝对路径）
local function _is_sudo_bin(w)
  if type(w) ~= "string" or w == "" then return false end
  local b = vim.fn.fnamemodify(w, ":t")
  return b == "sudo" or b == "doas"
end

--- 消费 `sudo`/`doas` 之后的选项（含独立取值的 `-u user` 等），返回剩余命令原文。
--- @param s string
--- @return string
local function _consume_sudo_opts(s)
  while true do
    local _, opt, after = s:match("^(%s*)(%S+)(.*)$")
    if not opt then return "" end
    if opt == "--" then return after end
    if opt:sub(1, 1) ~= "-" then return s end
    if SUDO_VALUE_OPTS[opt] then
      local _, _, after2 = after:match("^(%s*)(%S+)(.*)$")
      if not after2 then return "" end
      s = after2
    else
      s = after
    end
  end
end

--- 剥离单个命令段的前导 `sudo`/`doas`（保留前导 env 赋值与包装器）。
--- @param seg string
--- @return string
local function _strip_sudo_segment(seg)
  local prefix, rest = "", seg
  while true do
    local ws, first, after = rest:match("^(%s*)(%S+)(.*)$")
    if not first then return seg end
    if first:match("^[%w_]+=") or SUDO_PREFIX_WRAPPERS[first] then
      prefix = prefix .. ws .. first
      rest = after
    elseif _is_sudo_bin(first) then
      local combined = prefix .. _consume_sudo_opts(after)
      if combined:match("^%s*$") then return "sh" end
      return combined
    else
      return seg
    end
  end
end

--- 按未加引号的 shell 分隔符切分命令并保留分隔符（引号/转义内的分隔符不切分）。
--- @param cmd string
--- @return table { text, sep }
local function _split_shell(cmd)
  local segs, cur = {}, {}
  local i, n, q = 1, #cmd, nil
  local function flush(sep)
    segs[#segs + 1] = { text = table.concat(cur), sep = sep }
    cur = {}
  end
  while i <= n do
    local c = cmd:sub(i, i)
    if q then
      cur[#cur + 1] = c
      if c == "\\" and q == '"' then
        local nx = cmd:sub(i + 1, i + 1)
        if nx ~= "" then cur[#cur + 1] = nx; i = i + 1 end
      elseif c == q then
        q = nil
      end
      i = i + 1
    elseif c == "'" or c == '"' then
      q = c; cur[#cur + 1] = c; i = i + 1
    elseif c == "\\" then
      cur[#cur + 1] = c
      local nx = cmd:sub(i + 1, i + 1)
      if nx ~= "" then cur[#cur + 1] = nx; i = i + 1 end
      i = i + 1
    elseif c == ";" or c == "\n" then
      flush(c); i = i + 1
    elseif c == "&" or c == "|" then
      if cmd:sub(i + 1, i + 1) == c then flush(c .. c); i = i + 2 else flush(c); i = i + 1 end
    else
      cur[#cur + 1] = c; i = i + 1
    end
  end
  segs[#segs + 1] = { text = table.concat(cur), sep = "" }
  return segs
end

--- @param cmd string|nil
--- @return string|nil
local function _strip_sudo(cmd)
  if type(cmd) ~= "string" or cmd == "" then return cmd end
  local out = {}
  for _, s in ipairs(_split_shell(cmd)) do
    out[#out + 1] = _strip_sudo_segment(s.text)
    out[#out + 1] = s.sep
  end
  return table.concat(out)
end

--- 构造进程 overlay 规格：配置的可写根（剔除不存在、包含 overlay 基目录的根）+ cwd
--- + 额外可写根（如工具自身缓存/安装/临时目录，供 exec 统一沙箱化时暂存其写入）。
--- overlay 的 upper 必须位于其 lower 之外，否则内核挂载返回 EINVAL。
--- 供外部进程（run_command）与 LSP 命名空间覆盖共用。
--- @param cwd string
--- @param base_dir string 进程 overlay 基目录（宿主路径）
--- @param extra_roots table|nil 额外可写根
--- @return table 数组 { root, upper, work }
function M.build_overlay_specs(cwd, base_dir, extra_roots)
  local cfg_roots = config_store.get("tools.sandbox.process_roots")
  if type(cfg_roots) ~= "table" then
    cfg_roots = {}
  end
  local base = base_dir:gsub("/+$", "")
  -- F2：每会话私有临时根（默认 /tmp、/var/tmp）绝不 overlay——否则会以宿主真实
  -- /tmp 为只读 lower，泄露宿主/上一会话残留。它们由 runtime 以会话私有目录绑定。
  local tmpfs_roots = runtime.tmpfs_roots()
  local function under(p, r)
    if type(p) ~= "string" or type(r) ~= "string" then return false end
    return p == r or p:sub(1, #r + 1) == r .. "/"
  end
  local function is_tmpfs_root(r)
    for _, x in ipairs(tmpfs_roots) do if r == x then return true end end
    return false
  end
  local function under_tmpfs(p)
    for _, x in ipairs(tmpfs_roots) do if under(p, x) then return true end end
    return false
  end
  local function make_spec(r)
    local d = base_dir .. "/" .. _enc_root(r)
    local upper, work, bind = d .. "/upper", d .. "/work", d .. "/bind"
    fs.ensure_dir(upper)
    fs.ensure_dir(work)
    fs.ensure_dir(bind)
    -- 载荷非 root 时，overlay upper/work 必须归载荷所有，否则内核拒绝可写挂载（EROFS）。
    runtime.chown_payload(d)
    return { root = r, upper = upper, work = work, bind = bind }
  end
  -- read_all（默认）整机根模式：用单一整机 overlay（lower=/，upper/work 会话私有）替换只读根，
  -- 使沙箱内根文件系统「原样可写」，所有写入进 upper 暂存、宿主盘不受影响；命令结束后从该
  -- upper 捕获全部改动为候选。overlay 不可写时退回旧的多根逻辑（process_prefix 以只读根运行，
  -- 是否允许降级由 overlay_fail_closed 决定）。
  if runtime.read_all() and cwd then
    local d = base .. "/root"
    local upper, work, bind = d .. "/upper", d .. "/work", d .. "/bind"
    fs.ensure_dir(upper)
    fs.ensure_dir(work)
    fs.ensure_dir(bind)
    runtime.chown_payload(d)
    if runtime.overlay_available() and runtime.overlay_writable("/", upper, work) then
      local specs = { { root = "/", upper = upper, work = work, bind = bind, mode = "overlay" } }
      -- 整机 overlay 看不到会话私有 tmpfs 根（/tmp、/var/tmp 被私有目录覆盖），cwd 位于其下时
      -- 仍需单独 overlay cwd，使命令能在工作目录运行（与旧多根逻辑一致）。
      if under_tmpfs(cwd) and vim.fn.isdirectory(cwd) == 1 and not under(base, cwd) then
        specs[#specs + 1] = make_spec(cwd)
      end
      return specs
    end
  end
  -- 无法 overlay 的 tmpfs 挂载根（overlay lower 为挂载点会 EINVAL）：这些根只能
  -- bind 空会话目录；若 cwd 在其下，bind 会让 cwd 消失，故跳过该根、改为单独 overlay cwd。
  local NON_OVERLAY = { "/dev/shm", "/run" }
  local function is_nonoverlay(r)
    for _, x in ipairs(NON_OVERLAY) do if r == x then return true end end
    return false
  end
  local roots = {}
  local function add(r)
    r = tostring(r or ""):gsub("/+$", "")
    if r == "" or r == "/" or vim.fn.isdirectory(r) ~= 1 then return end
    if under(base, r) then return end -- upper 在 lower 之下会 EINVAL
    for _, x in ipairs(roots) do if x == r then return end end
    roots[#roots + 1] = r
  end
  for _, r in ipairs(cfg_roots) do
    if not is_tmpfs_root(r) and not (is_nonoverlay(r) and under(cwd, r)) then add(r) end
  end
  for _, r in ipairs(extra_roots or {}) do
    if not is_tmpfs_root(r) and not (is_nonoverlay(r) and under(cwd, r)) then add(r) end
  end
  local covered = false
  for _, r in ipairs(roots) do if under(cwd, r) then covered = true break end end
  if not covered then add(cwd) end
  local specs = {}
  for _, r in ipairs(roots) do specs[#specs + 1] = make_spec(r) end
  return specs
end

--- 候选涉及的真实路径数组
--- @param cand table
--- @return table
local function _cand_paths(cand)
  local paths = {}
  for _, f in ipairs(cand.files or {}) do paths[#paths + 1] = f.path end
  return paths
end

--- 将候选加入异步待审队列（可配置关闭）
--- @param cand table
--- @param attempt table
--- @param cfg table
--- @param env table|nil
--- @param meta table|nil 安全分级元数据
--- @return table|nil item
local function _enqueue_review(cand, attempt, cfg, env, meta)
  local review_cfg = (cfg and cfg.review) or {}
  if review_cfg.enabled == false then return nil end
  local review = require("NeoAI.sandbox.review")
  return review.enqueue(cand, {
    tool = attempt.tool_name,
    command_id = attempt.command_id,
    attempt_id = attempt.attempt_id,
    base_version = attempt.request_hash,
    evidence = env and env.evidence or nil,
    stats = env and env.stats or nil,
    -- false 表示「已分析且无警告」：避免 review.enqueue 在主线程对候选做一次同步全文扫描。
    secret_warning = meta and meta.secret_warning,
    risk_level = meta and meta.risk_level or nil,
    risk_name = meta and meta.risk_name or nil,
    risk_reasons = meta and meta.risk_reasons or nil,
    package = meta and meta.package or nil,
    action = meta and meta.action or nil,
    -- 包安装：管理器/包名/合并键/命令，供「按安装命令」合并审批与界面标注。
    command = meta and meta.command or nil,
    package_manager = meta and meta.package_manager or nil,
    package_names = meta and meta.package_names or nil,
    package_key = meta and meta.package_key or nil,
    package_sensitive = meta and meta.package_sensitive or nil,
  })
end

--- 候选是否落在包管理器状态/安装目录（结果按 attempt 缓存）。
--- `package_path_manager` 对每个路径做数十个子串匹配，同一候选在结算链路上会被多个阶段
--- 询问；缓存后只对全部候选文件扫描一次，避免 3×N 次全量匹配。
--- @param cand table
--- @param attempt table|nil
--- @return string|nil manager
local function _package_manager_of(cand, attempt)
  if attempt and attempt.__pkg_manager ~= nil then return attempt.__pkg_manager or nil end
  local privilege = require("NeoAI.sandbox.privilege")
  local found = nil
  for _, f in ipairs(cand.files or {}) do
    found = privilege.package_path_manager(f.path)
    if found then break end
  end
  if attempt then attempt.__pkg_manager = found or false end
  return found
end

--- 异步预计算候选的密钥分析（NEOKEY 警告 + 生成高熵），在工作线程扫描，避免结算阶段
--- 主线程逐文件全文扫描。线程池不可用时返回 offloaded=false，由调用方回退同步。
--- @param cand table
--- @param attempt table
--- @return Deferred resolve({ offloaded, secret_warning, generated })
local function _analyze_secrets_async(cand, attempt)
  local secret = require("NeoAI.sandbox.secret")
  if not secret.enabled() then
    return async.resolve({ offloaded = true, secret_warning = nil, generated = {} })
  end
  -- 包安装（命令判定）或路径判定为包/生成内容（site-packages/node_modules 等）：
  -- 与结算阶段 `is_pkg` 一致跳过密钥分析，避免对 venv/依赖树逐文件全文熵扫描。
  if attempt.package or _package_manager_of(cand, attempt) then
    return async.resolve({ offloaded = true, secret_warning = nil, generated = {} })
  end
  return secret.analyze_files_async(cand.files, {}):then_(function(r)
    if r.offloaded == false then
      -- 线程池不可用：回退同步（小候选/无 worker 环境）。
      return {
        offloaded = true,
        secret_warning = secret.warn_for_files(cand.files),
        generated = secret.detect_generated(cand.files),
      }
    end
    return { offloaded = true, secret_warning = r.warning, generated = r.generated or {} }
  end)
end

--- 按模式/授权发布或入队；返回解析后的结果/错误
--- @param cand table
--- @param attempt table
--- @param ctx table
--- @param cfg table
--- @param spec table
--- @param result any
--- @param process_info table|nil
--- @param pre table|nil 预计算的密钥分析（{ secret_warning, generated }），由工作线程得出；
---   nil 时在此同步计算（小候选/线程池不可用）。
--- @return table { ok, value?, err? }
local function _settle_candidate(cand, attempt, ctx, cfg, spec, result, process_info, pre)
  -- 命名空间映射的临时根（/tmp、/var/tmp 等）：写入为会话私有、nvim 退出即丢弃，
  -- 不进入待审队列、不 CAS 发布、也不弹审批悬浮窗；暂存内容保留以供本次会话读取一致。
  -- 仅当路径**不在 cwd 子树内**时才视为临时根（cwd 位于 /tmp 时其工作区仍走正常审批）。
  -- 根列表见 `tools.sandbox.ephemeral_roots`（默认同 tmpfs_roots；`{}` 关闭）。
  do
    local roots = config_store.get("tools.sandbox.ephemeral_roots")
    if type(roots) ~= "table" then roots = require("NeoAI.sandbox.runtime").tmpfs_roots() end
    if #roots > 0 and #(cand.files or {}) > 0 then
      local cwd = (vim.fn.getcwd() or ""):gsub("/+$", "")
      local function under(p, r)
        return p == r or p:sub(1, #r + 1) == r .. "/"
      end
      local function ephemeral(p)
        if type(p) ~= "string" then return false end
        if cwd ~= "" and under(p, cwd) then return false end
        for _, r in ipairs(roots) do if under(p, r) then return true end end
        return false
      end
      local keep, dropped = {}, false
      for _, f in ipairs(cand.files) do
        if ephemeral(f.path) then dropped = true else keep[#keep + 1] = f end
      end
      if dropped then
        cand.files = keep
        if #keep == 0 then
          -- 全部落在临时根：不冻结候选/不入待审/不发布（退出即丢弃）。
          require("NeoAI.sandbox.store").discard_candidate(cand.candidate_digest)
          control.transition(attempt, "COMPLETED_READ_ONLY")
          return { ok = true, value = result }
        end
      end
    end
  end
  -- 影响与证据（fs/process），未知用 null 表达
  local impacts = impact.from_candidate(cand, { command_id = attempt.command_id, attempt_id = attempt.attempt_id })
  if process_info then impacts[#impacts + 1] = impact.process(process_info) end
  -- 证据只存影响清单（路径/动作/哈希，不含文件内容）：此前直接嵌入 cand.files 会把每个文件的
  -- 完整内容再 JSON 编码一遍（大候选时阻塞主线程，且证据本就无需内容）。
  local evidence_id = evidence.add("fs", { files = impacts }, {
    command_id = attempt.command_id, attempt_id = attempt.attempt_id, tool = attempt.tool_name,
  })
  local stats = impact.stats(impacts)

  -- 安全分级：按写路径/包安装/密钥/提权/网络/结果信号评估级别并给出建议动作。
  local risk = require("NeoAI.sandbox.risk")
  local review = require("NeoAI.sandbox.review")
  local paths = _cand_paths(cand)
  -- 专用包管理器识别：命令未命中包管理器名单，但改动落在包管理器状态/安装目录
  -- （node_modules、site-packages、/var/lib/apt、~/.cargo 等）时，同样按包安装处理（封顶 L2）。
  local pkg_by_path = _package_manager_of(cand, attempt)
  local is_pkg = attempt.package == true or pkg_by_path ~= nil
  local secret_warning = nil
  local generated = {}
  if not is_pkg then
    if pre then
      -- 工作线程已扫描：直接用结果，主线程不再逐文件全文扫描。
      secret_warning = pre.secret_warning
      generated = pre.generated or {}
    else
      local ok, s = pcall(require, "NeoAI.sandbox.secret")
      -- 包安装状态文件（apt lists/pkgcache、pip/npm 缓存等）常含高熵签名/哈希，并非用户密钥；
      -- 跳过密钥检测，避免误报「密钥操作」并误升到 L3。
      if ok and s.enabled() then
        secret_warning = s.warn_for_files(cand.files)
        -- AI 生成的高熵信息（密钥类）：候选内容含熵/具名候选（非宿主 token）时留痕、发事件、
        -- 审计，并给出「密钥操作」提示，强制进入待审（不终止 Agent）。
        generated = s.detect_generated(cand.files)
      end
    end
  end
  if #generated > 0 then
    pcall(function()
      require("NeoAI.sandbox.evidence").add("secret", {
        event = "generated_high_entropy", count = #generated, hits = generated,
        source = "observed", coverage = "partial",
      }, { tool = attempt.tool_name, command_id = attempt.command_id, attempt_id = attempt.attempt_id })
    end)
    pcall(function()
      require("NeoAI.kernel.event_bus").emit(
        require("NeoAI.kernel.events").SANDBOX_SECRET_DETECTED, {
          source = "generated", tool = attempt.tool_name, count = #generated,
          command_id = attempt.command_id,
        })
    end)
    pcall(function()
      require("NeoAI.sandbox.audit").observe({
        kind = "secret", tool = attempt.tool_name, level = 2,
        reasons = { "GENERATED_HIGH_ENTROPY" }, command_id = attempt.command_id,
      })
    end)
    if not secret_warning then
      secret_warning = { count = #generated, tokens = {}, generated = true,
        reason = "HIGH_ENTROPY_GENERATED" }
    end
  end
  -- 本次调用涉及加密 token 或敏感环境变量名（但候选文件不含 token）时，也给出密钥操作警告，
  -- 使待审悬浮窗展示 `⚠ 密钥操作`（软提示 + 审批，不终止 Agent）。
  if not secret_warning and ctx and ctx.secret_operation then
    secret_warning = { count = 1, tokens = {}, names = ctx.secret_names or {}, reason = "KEY_OPERATION" }
  end
  -- 脚本间接执行：折叠后的 effective 文本用于危险模式识别与包安装识别。
  local scan = attempt.script_scan
  local effective = scan and scan.enabled and scan.effective or nil
  -- 敏感安装（改动第三方软件源/密钥）：保留高危评级；安全安装封顶中危（放宽风险提示）。
  local pkg_sensitive = false
  if is_pkg then
    pcall(function()
      pkg_sensitive = require("NeoAI.sandbox.privilege").package_sensitive(effective or attempt.container_command
        or (process_info and process_info.command))
    end)
  end
  local rf = {
    effect = spec.effect,
    paths = paths,
    privilege_tier = attempt.privilege_tier,
    package = is_pkg,
    package_sensitive = pkg_sensitive,
    network = attempt.network == true,
    -- 密钥操作：候选文件含 token，或本次调用使用了 KEY 环境变量 token（提级强制待审）。
    secret = (secret_warning and (secret_warning.count or 0) > 0)
      or (ctx and ctx.secret_operation == true) or false,
    command = attempt.container_command or (process_info and process_info.command) or nil,
    command_effective = effective,
    script_opaque = (scan and scan.opaque) or false,
  }
  local r = risk.classify(rf)
  if attempt.result_risk and (attempt.result_risk.level or 0) > r.level then
    r.level = attempt.result_risk.level
    r.name = risk.level_name(r.level)
    r.badge = risk.badge(r.level)
    for _, x in ipairs(attempt.result_risk.reasons or {}) do r.reasons[#r.reasons + 1] = x end
  end
  -- 包安装降级：包安装的状态文件在工作区外、常含高熵签名，结果信号（如磁盘/网络）不应把
  -- 它推到 L3；仅当命令本身命中破坏性模式时才保留 L3。
  if rf.package and r.level >= 3 and (risk.dangerous_level(effective or rf.command) or 0) < 3 then
    r.level = 2
    r.name = risk.level_name(2)
    r.badge = risk.badge(2)
  end
  risk.record({
    tool = attempt.tool_name, command_id = attempt.command_id, attempt_id = attempt.attempt_id,
    level = r.level, reasons = r.reasons,
  })
  pcall(function()
    require("NeoAI.sandbox.audit").observe({
      kind = spec.effect, tool = attempt.tool_name, level = r.level,
      reasons = r.reasons, paths = paths, command_id = attempt.command_id,
    })
  end)

  -- 建议动作：block 直接拒绝；auto 立即发布；review 入待审队列（不阻塞 agent）。
  local action = risk.action(r.level, {
    session_auto = review.session_auto(),
    package = rf.package,
    package_sensitive = pkg_sensitive,
    secret = rf.secret,
  })
  if action == "block" then
    control.transition(attempt, "BLOCKED")
    return { ok = false, err = {
      kind = "sandbox",
      message = "安全策略拒绝（" .. tostring(r.name) .. "）: " .. table.concat(r.reasons, ","),
      reason_codes = r.reasons, command_id = attempt.command_id,
    } }
  end

  -- 任务授权匹配：覆盖时自动应用（TASK_POLICY_MATCH）；mode=commit / 自动审批亦立即发布
  local covering = grant.find_covering(spec.effect, cand)
  local mode = ctx.sandbox_mode or cfg.mode or "dry_run"
  local auto = covering ~= nil or review.auto_apply_enabled() or mode == "commit" or action == "auto"
  -- 包安装走额外规则：默认强制复核（不随自动审批放行），除非 packages.mode="allow"。
  if rf.package and ((cfg.packages or {}).mode or "review") ~= "allow" then auto = false end
  -- 密钥操作永不自动发布（需显式确认）。
  if rf.secret then auto = false end
  -- 脚本间接执行：脚本内命中危险命令、或内容无法静态解析（不透明）时强制复核，
  -- 不随 mode=commit / 会话自动审批放行（沙箱仍保证写入冻结，复核兜住误判）。
  local script_indirect_risk = scan and scan.enabled and (scan.opaque or (scan.danger or 0) > 0)
  if script_indirect_risk then auto = false end
  local severity = require("NeoAI.sandbox.privilege").severity(attempt.privilege_tier or 0)
  local env = envelope.build({
    command_id = attempt.command_id,
    attempt_id = attempt.attempt_id,
    state = auto and "READY_TO_PUBLISH" or "AWAITING_PUBLICATION_AUTH",
    decision = auto and "ALLOW" or "NEEDS_CONFIRMATION",
    severity = severity,
    candidate_digest = cand.candidate_digest,
    stats = stats,
    evidence = { evidence_id },
    next_action = auto and "applied" or "await_authorization",
  })

  if auto then
    control.transition(attempt, "READY_TO_PUBLISH")
    control.transition(attempt, "PUBLISHING")
    if require("NeoAI.sandbox.fault").hit("publish") then
      control.transition(attempt, "CONFLICT")
      return { ok = false, err = { kind = "sandbox", message = "注入的发布失败 (publish)", command_id = attempt.command_id } }
    end
    local pub = candidate.publish(cand, { expected_base = attempt.request_hash })
    if pub.ok then
      control.transition(attempt, "VERIFYING")
      control.transition(attempt, "COMMITTED")
      store.write_receipt(pub.receipt)
      if covering then grant.consume(covering.grant_id, #(cand.files or {})) end
      -- 直接发布后，同路径的旧待审项已被覆盖，标记 SUPERSEDED 避免重复版本
      require("NeoAI.sandbox.review").supersede_by_paths(_cand_paths(cand), nil)
      return { ok = true, value = result }
    end
    control.transition(attempt, "CONFLICT")
    return { ok = false, err = { kind = "sandbox", message = "发布冲突: " .. tostring(pub.reason), command_id = attempt.command_id } }
  end

  -- 结果原样返回给模型：不把「已暂存/待审」暴露给 AI，让它认为修改已完成；
  -- 待审状态仅通过 UI 徽标提示用户（见 services.status 的 sandbox 段）。
  -- 包安装：提取管理器与包名（用于按安装命令合并审批与界面标注）。
  local pinfo = nil
  if rf.package then
    pcall(function()
      pinfo = require("NeoAI.sandbox.privilege").package_info(effective or rf.command)
    end)
  end
  if not pinfo and pkg_by_path then
    pinfo = { manager = pkg_by_path, packages = {}, key = pkg_by_path .. ":*" }
  end
  local item = _enqueue_review(cand, attempt, cfg, env, {
    secret_warning = secret_warning or false,
    risk_level = r.level, risk_name = r.name, risk_reasons = r.reasons,
    package = rf.package, action = action,
    command = rf.command,
    package_manager = pinfo and pinfo.manager or nil,
    package_names = pinfo and pinfo.packages or nil,
    package_key = pinfo and pinfo.key or nil,
    package_sensitive = pkg_sensitive or nil,
  })
  if item then
    -- 同一文件被再次编辑：新候选取代同路径的旧待审项（队列只保留最新版本）
    require("NeoAI.sandbox.review").supersede_by_paths(_cand_paths(cand), item.change_set_id)
  end
  control.transition(attempt, "AWAITING_PUBLICATION_AUTH")
  return { ok = true, value = result }
end

--- 持久化候选（异步写）→ 密钥分析（工作线程）→ 结算。返回 Deferred resolve(settled)。
--- @param cand table
--- @param attempt table
--- @param ctx table
--- @param cfg table
--- @param spec table
--- @param result any
--- @param process_info table|nil
--- @return Deferred resolve({ ok, value?, err? })
local function _persist_and_settle(cand, attempt, ctx, cfg, spec, result, process_info)
  return store.write_candidate_async(cand):then_(function()
    return _analyze_secrets_async(cand, attempt)
  end):then_(function(pre)
    return _settle_candidate(cand, attempt, ctx, cfg, spec, result, process_info, pre)
  end)
end

--- 冻结工具子进程（exec，长驻场景）产生的候选并按模式入队/发布。
--- 供 MCP stdio server 等长驻进程在 on_exit 时调用；无改动则仅清理暂存。
--- @param attempt table
--- @param cand table|nil
--- @param ctx table
--- @param spec table
--- @param result any
--- @param process_info table|nil
--- @return table { ok, value?, err? }
function M.settle_exec_candidate(attempt, cand, ctx, spec, result, process_info)
  local cfg = config_store.get("tools.sandbox") or {}
  if cand and #cand.files > 0 then
    cand.command_id = attempt.command_id
    store.write_candidate_async(cand)
    candidate.merge_candidate(cand, { from_command = true })
    local settled = _settle_candidate(cand, attempt, ctx, cfg, spec, result, process_info)
    candidate.cleanup(attempt.attempt_id)
    return settled
  end
  candidate.cleanup(attempt.attempt_id)
  return { ok = true, value = result }
end

-- ========== 内核级行为观测（eBPF / strace / procfs） ==========

--- 观测事件 → 越界访问留痕 + 密钥文件访问归因（非阻塞，best-effort）。
--- 以实际 syscall 访问为准，替代/补充命令字符串解析启发式。
--- @param attempt table
--- @param ctx table
--- @param evt table { kind, op, pid, path?, host?, port? }
local function _on_observed(attempt, ctx, evt)
  if type(evt) ~= "table" then return end
  if evt.kind ~= "file" then return end
  local p = evt.path
  if type(p) ~= "string" or p == "" then return end
  -- 同一路径在一轮命令内会被重复 open（构建/测试反复读同一批文件，事件可达百万级）：
  -- 按路径去重，只处理首次，避免对每个事件都做路径规范化与密钥模式匹配（主线程热点）。
  -- 去重后仍能完整覆盖「访问了哪些路径」——留痕与密钥归因只需知道首次访问。
  -- 去重表设内存上限（超限后不再新增，仅复用已有项），避免极端工作负载下无界增长。
  local seen = ctx._observed_paths_seen
  if not seen then
    seen = {}
    ctx._observed_paths_seen = seen
    ctx._observed_paths_count = 0
  end
  if seen[p] then return end
  if ctx._observed_paths_count < 300000 then
    seen[p] = true
    ctx._observed_paths_count = ctx._observed_paths_count + 1
  end
  local runtime = require("NeoAI.sandbox.runtime")
  -- 每 attempt 缓存一次 read_all/cwd，避免逐事件读取配置与 getcwd。
  if ctx._observed_read_all == nil then ctx._observed_read_all = runtime.read_all() end
  if ctx._observed_read_all then
    if ctx._observed_cwd == nil then ctx._observed_cwd = vim.fn.getcwd() end
    local hit = runtime.outside_workspace(p, ctx._observed_cwd)
    if hit then
      pcall(function()
        require("NeoAI.sandbox.trace").record({
          path = hit, tool = attempt.tool_name, kind = "read", source = "observed",
        })
      end)
    end
  end
  local secret = require("NeoAI.sandbox.secret")
  if secret.enabled() and secret.is_secret_path(p) then
    ctx.observed_secret_paths = ctx.observed_secret_paths or {}
    ctx.observed_secret_paths[#ctx.observed_secret_paths + 1] = p
  end
end

-- ========== 观测预热（把 eBPF 探针挂载移出命令关键路径） ==========
-- eBPF 探针（bpftrace）挂载约需 0.5s：若在命令执行前同步等待，会给每条进程命令带来固定卡顿；
-- 若完全不等待，短命令可能在挂载完成前结束而漏观测。折中：在**上一条进程命令返回后**（AI 正在
-- 生成下一轮，主线程空闲）后台预创建下一个 attempt 的 cgroup 并挂载探针，使挂载与 AI 输出重叠；
-- 下一条进程命令到来时直接复用已挂载的 cgroup + 观测句柄（事件派发目标在复用时指向本次 attempt）。
-- 未在 TTL 内被复用则回收（停止探针、释放 cgroup）。
local prewarm = {
  cg = nil,       -- 预创建的 cgroup handle
  handle = nil,   -- 已启动的观测句柄（bpftrace）
  slot = nil,     -- { attempt, ctx }：事件派发目标（复用时填充）
  limits_key = nil,
  timer = nil,    -- TTL 定时器
  seq = 0,
}

--- cgroup 限制指纹（复用预热前必须一致，否则限制会不匹配）
--- @param limits table|nil
--- @return string
local function _limits_key(limits)
  limits = limits or {}
  return table.concat({
    tostring(limits.memory_bytes or 0), tostring(limits.pids or 0), tostring(limits.cpu_max or 0),
  }, ":")
end

--- 停止并回收预热 TTL 定时器。
--- `vim.defer_fn` 返回的是 libuv 定时器句柄（userdata），不能传给 `vim.fn.timer_stop`
--- （会抛 `E5101: Cannot convert given Lua type`）；对 userdata 用 uv 句柄的 stop/close。
local function _prewarm_stop_timer()
  local t = prewarm.timer
  if not t then return end
  prewarm.timer = nil
  if type(t) == "userdata" then
    pcall(function() t:stop() end)
    pcall(function() t:close() end)
  else
    pcall(vim.fn.timer_stop, t)
  end
end

--- 停止并回收预热观测（幂等）
local function _prewarm_clear()
  _prewarm_stop_timer()
  if prewarm.handle then pcall(prewarm.handle.stop) end
  if prewarm.cg then
    pcall(function() require("NeoAI.sandbox.cgroup").release(prewarm.cg) end)
  end
  prewarm.cg, prewarm.handle, prewarm.slot, prewarm.limits_key = nil, nil, nil, nil
end

--- 取出预热观测（若限制匹配）。不匹配或不存在时返回 nil（不匹配会顺带回收）。
--- @param limits_key string
--- @return table|nil { cg, handle, slot }
local function _take_prewarm(limits_key)
  if not prewarm.cg then return nil end
  if prewarm.limits_key ~= limits_key then _prewarm_clear(); return nil end
  local pre = { cg = prewarm.cg, handle = prewarm.handle, slot = prewarm.slot }
  _prewarm_stop_timer()
  prewarm.cg, prewarm.handle, prewarm.slot, prewarm.limits_key = nil, nil, nil, nil
  return pre
end

--- 后台预热下一个 attempt 的 cgroup + eBPF 观测（幂等；仅 ebpf 后端需要，strace/procfs 廉价）。
--- 应在进程命令返回后调用（主线程空闲、AI 正在生成），使探针挂载与 AI 输出重叠。
local function _prewarm_observer()
  local cfg = config_store.get("tools.sandbox.observe") or {}
  if cfg.enabled == false or cfg.prewarm == false then return end
  if prewarm.cg or prewarm.handle then return end
  local observer = require("NeoAI.sandbox.observer")
  if observer.backend() ~= "ebpf" then return end
  local cgroup = require("NeoAI.sandbox.cgroup")
  if not cgroup.limits_configured() then return end
  local limits = cgroup.resolve_limits()
  prewarm.seq = prewarm.seq + 1
  local id = "prewarm_" .. tostring(prewarm.seq)
  local h = cgroup.prepare(id, limits)
  if not h then return end
  local stat = vim.uv.fs_stat(h.path)
  if not stat then cgroup.release(h); return end
  local slot = {}
  local ok, handle = pcall(observer.start, {
    cgroup_id = stat.ino, cgroup_path = h.path, attempt_id = id,
    on_event = function(evt)
      if slot.attempt then pcall(_on_observed, slot.attempt, slot.ctx, evt) end
    end,
  })
  if not ok or not handle then cgroup.release(h); return end
  prewarm.cg, prewarm.handle, prewarm.slot, prewarm.limits_key = h, handle, slot, _limits_key(limits)
  local ttl = tonumber(cfg.prewarm_ttl_ms) or 90000
  if ttl > 0 then
    prewarm.timer = vim.defer_fn(function() _prewarm_clear() end, ttl)
  end
end

--- 清理预热观测（供 sandbox.reset / 测试）
function M.clear_prewarm()
  _prewarm_clear()
end

--- 预热状态快照（测试/诊断）
--- @return table { active, has_handle, ready, attempt_id }
function M.prewarm_info()
  return {
    active = prewarm.cg ~= nil,
    has_handle = prewarm.handle ~= nil,
    ready = prewarm.handle ~= nil and prewarm.handle.ready == true,
    attempt_id = prewarm.cg and prewarm.cg.attempt_id or nil,
  }
end

-- 测试钩子：手动触发一次后台预热（不依赖真实命令时序）。
M._prewarm_observer = _prewarm_observer

--- 启动带外（out-of-band）观测（ebpf/procfs）。strace 需命令前缀包裹，见 `_build_prefix`。
--- @param cg_handle table|nil
--- @param attempt table
--- @param ctx table
--- @param prewarmed table|nil 预热观测 { handle, slot }（复用同一 cgroup）
--- @return table|nil handle
local function _start_observe(cg_handle, attempt, ctx, prewarmed)
  local cfg = config_store.get("tools.sandbox.observe") or {}
  if cfg.enabled == false then return nil end
  -- 复用预热句柄：把事件派发目标指向本次 attempt/ctx，无需重新挂载。
  if prewarmed and prewarmed.handle then
    prewarmed.slot.attempt, prewarmed.slot.ctx = attempt, ctx
    return prewarmed.handle
  end
  local observer = require("NeoAI.sandbox.observer")
  if not observer.available() then return nil end
  if not cg_handle or type(cg_handle.path) ~= "string" then return nil end
  local stat = vim.uv.fs_stat(cg_handle.path)
  if not stat then return nil end
  local ok, handle = pcall(observer.start, {
    cgroup_id = stat.ino,
    cgroup_path = cg_handle.path,
    attempt_id = attempt.attempt_id,
    on_event = function(evt) pcall(_on_observed, attempt, ctx, evt) end,
    on_error = function(msg)
      require("NeoAI.kernel.logger").debug("[sandbox] 观测: %s", tostring(msg))
    end,
  })
  if ok and handle then return handle end
  return nil
end

-- ========== 公开 API ==========

--- 执行门禁（内部实现）
--- @param tool table 工具定义（含 __sandbox_spec）
--- @param args table
--- @param ctx table
--- @param call_original function() -> Deferred 真正执行原工具
--- @return Deferred
local function _gate_inner(tool, args, ctx, call_original)
  ctx = ctx or {}
  local cfg = config_store.get("tools.sandbox") or {}
  local root = store.root() or (vim.fn.stdpath("cache") .. "/NeoAI/sandbox")

  -- 沙箱关闭：按 fail_closed 决定
  if cfg.enabled == false then
    if cfg.fail_closed == false then
      return call_original()
    end
    return async.reject({ kind = "sandbox", message = "沙箱已禁用且 fail_closed=true，拒绝执行工具: " .. tostring(tool and tool.name) })
  end

  local spec = tool and tool.__sandbox_spec or tool_spec.get(tool and tool.name, tool and tool.category)
  local attempt = control.new_attempt(tool and tool.name or "unknown", args, ctx, spec)

  -- 幂等：同一 client_idempotency_key 携带不同请求必须拒绝
  local ok_idem, idem_reason = control.claim_idempotency(ctx.client_idempotency_key, attempt.request_hash)
  if not ok_idem then
    return async.reject({ kind = "sandbox", message = idem_reason, command_id = attempt.command_id })
  end

  -- 预检与策略
  local facts = {
    tool = attempt.tool_name,
    effect = spec.effect,
    args = args,
    cwd = vim.fn.getcwd(),
    mode = ctx.sandbox_mode or cfg.mode or "dry_run",
  }
  local verdict = policy.evaluate(facts)
  -- 记录效果类裁决为证据，供策略回放与审计（读/进程内不记录，避免噪声）
  if spec.effect ~= "read" and spec.effect ~= "in_process" or verdict.decision == "DENY" then
    pcall(replay.record, facts, verdict, {
      command_id = attempt.command_id, attempt_id = attempt.attempt_id, tool = attempt.tool_name,
    })
  end
  if verdict.decision == "DENY" then
    control.transition(attempt, "PARSED")
    control.transition(attempt, "BLOCKED")
    return async.reject({
      kind = "sandbox",
      message = "沙箱硬拒绝: " .. table.concat(verdict.reason_codes, ","),
      reason_codes = verdict.reason_codes,
      command_id = attempt.command_id,
    })
  end
  -- 脚本间接执行静态扫描：命令委托给脚本/解释器（bash x.sh、python x.py、./x.sh、
  -- bash -c '…'）时，读取脚本内容（含 AI 暂存副本）与高级语言内嵌 shell 调用，折叠为
  -- effective 文本，供硬拒绝/档位/分级复用；无法解析时标记不透明（强制复核）。
  if spec.effect == "process" and type(args.command) == "string" then
    local scan = require("NeoAI.sandbox.script_scan").scan(args.command, { cwd = vim.fn.getcwd() })
    attempt.script_scan = scan
  end
  -- 内核/破坏性命令硬拒绝（不执行）：普通命令（python/node/go/rust/apt/pip/npm 等）不受影响，
  -- 仍可在沙箱内执行并把写入冻结为候选。见 risk.deny_reason。
  if spec.effect == "process" and type(args.command) == "string" then
    local scan = attempt.script_scan
    local deny = require("NeoAI.sandbox.risk").deny_reason(
      (scan and scan.effective) or args.command)
    if deny then
      control.transition(attempt, "PARSED")
      control.transition(attempt, "BLOCKED")
      return async.reject({
        kind = "sandbox",
        message = "沙箱硬拒绝（内核/危险命令，不执行）: " .. deny,
        reason_codes = { deny },
        command_id = attempt.command_id,
      })
    end
  end
  control.transition(attempt, "PARSED")
  control.transition(attempt, "PREFLIGHTED")

  -- 长驻服务（service_*）：预检/脚本扫描/硬拒绝已完成；隔离与候选结算由 sandbox.service
  -- 自建（独立 overlay + cgroup），此处不进入一次性进程的捕获/冻结流程。
  if spec.long_lived then
    control.transition(attempt, "STAGING")
    local inner = call_original()
    if type(inner) ~= "table" or type(inner.then_) ~= "function" then
      control.transition(attempt, "COMPLETED_READ_ONLY")
      return async.resolve(inner)
    end
    local out = async.Deferred.new()
    inner:then_(function(v)
      control.transition(attempt, "COMPLETED_READ_ONLY")
      out:resolve(v)
    end, function(e)
      control.transition(attempt, "FAILED")
      out:reject(e)
    end)
    return out
  end

  -- 只读 / 进程内：直接执行并记录只读回执（无候选，无需审批）
  if spec.effect == "read" or spec.effect == "in_process" then
    pcall(function()
      require("NeoAI.sandbox.audit").observe({
        kind = spec.effect == "read" and "read" or "tool",
        tool = attempt.tool_name, level = 0, command_id = attempt.command_id,
      })
    end)
    control.transition(attempt, "STAGING")
    control.transition(attempt, "CANDIDATE_READY")
    control.transition(attempt, "COMPLETED_READ_ONLY")
    -- 只读工具命中沙箱暂存时读暂存副本，使 AI 看到自己尚未发布的修改（沙箱对 AI 不可见）。
    -- 对所有声明了路径参数的只读工具生效（read_file/file_exists/treesitter 等）；
    -- 暂存副本保留真实 basename（含扩展名），故依赖 filetype 的 treesitter 也能正确解析。
    -- 目录参数（list_files/search_files 的 path）由 candidate.read_path 返回 nil，原样保留，
    -- 其目录级一致性由工具自身叠加暂存视图实现。LSP 工具不重写：把无项目根的暂存路径
    -- 交给 LSP 会导致 root_dir/client 匹配错误，故仍读真实内容（已知边界）。
    local rev = {}
    local read_proc = false -- 读 /proc/* 时结果需经 conceal 脱敏（防沙箱指纹/宿主路径泄露）
    if spec.effect == "read" then
      for _, key in ipairs(spec.paths or {}) do
        local v = args[key]
        if type(v) == "string" then
          if v:match("^/proc/") then read_proc = true end
          local staged = candidate.read_path(v)
          if staged then
            rev[staged] = vim.fn.fnamemodify(fs.expand(v), ":p"):gsub("/+$", "")
            args[key] = staged
          end
        end
      end
    end
    -- LSP 工具：调用前刷新 LSP overlay（若启用），使运行中的 LSP server 看到最新暂存内容。
    if spec.effect == "read" and attempt.tool_name and attempt.tool_name:match("^lsp_") then
      pcall(function() require("NeoAI.sandbox.lsp").refresh() end)
    end
    local d = call_original()
    if next(rev) or read_proc then
      -- 成功与失败都还原暂存路径：读取暂存副本失败（如暂存已删除）时，错误信息
      -- 会带暂存路径，必须还原为真实路径，避免沙箱内部路径泄露给模型。
      -- read_proc：`read_file /proc/self/mountinfo` 等进程内直读不经 run_command，
      -- 不会被 shell 输出脱敏；此处对 /proc 读取结果补做 conceal 脱敏，避免 overlay
      -- lowerdir/upperdir 等沙箱指纹与宿主路径泄露给模型（此前为 conceal 旁路）。
      local out = async.Deferred.new()
      local function _sanitize(v)
        v = _rewrite_value(rev, v)
        if not read_proc then return v end
        local conceal = require("NeoAI.sandbox.conceal")
        if type(v) == "string" then return conceal.redact(v) end
        if type(v) == "table" then
          for k, val in pairs(v) do
            if type(val) == "string" then v[k] = conceal.redact(val) end
          end
        end
        return v
      end
      d:then_(function(res)
        out:resolve(_sanitize(res))
      end, function(err)
        out:reject(_sanitize(err))
      end)
      return out
    end
    return d
  end

  -- 网络：默认放行，仅记录审计（不拦截）；offline=true 或受控白名单在策略层已拒绝
  if spec.effect == "network" then
    pcall(function()
      require("NeoAI.sandbox.audit").observe({
        kind = "network", tool = attempt.tool_name, level = 1,
        reasons = { "NETWORK_ACCESS" }, command_id = attempt.command_id,
      })
    end)
    control.transition(attempt, "STAGING")
    control.transition(attempt, "CANDIDATE_READY")
    control.transition(attempt, "COMPLETED_READ_ONLY")
    local endpoint = args and (args.url or args.endpoint or args.filepath)
    local evidence_id = evidence.add("network", {
      endpoint = endpoint, allowed = true, denied = false, source = "observed",
    }, {
      command_id = attempt.command_id, attempt_id = attempt.attempt_id, tool = attempt.tool_name,
    })
    pcall(replay.record,
      { tool = attempt.tool_name, effect = "network", args = args, endpoint = endpoint },
      { decision = "ALLOW", reason_codes = { "NETWORK_RECORDED" } },
      { command_id = attempt.command_id, attempt_id = attempt.attempt_id, tool = attempt.tool_name })
    return call_original()
  end

  -- 外部进程：经运行时隔离执行；cwd 用 overlay 私有可写层，改动冻结为候选
  if spec.effect == "process" then
    local ok_rt, rt_err = runtime.check_available()
    if not ok_rt then
      control.transition(attempt, "FAILED")
      return async.reject({ kind = "sandbox", message = rt_err, command_id = attempt.command_id })
    end
    candidate.begin(attempt, root)
    -- 工具子进程（exec）可指定进程 cwd（通常取可写根公共父目录，避免遮蔽目录把 overlay 遮蔽）；
    -- 未指定时沿用当前工作目录。
    local real_cwd = ctx.sandbox_exec_cwd or vim.fn.getcwd()
    -- 会话级共享可写层：同一 agent 循环内所有命令共用（命令 N 看得到命令 N-1 的改动），
    -- agentEnd 轮换会话时随会话目录清理（改动已冻结为候选）。可写根（默认仅 cwd；
    -- /tmp、/var/tmp 属每会话私有 tmpfs，不作为 overlay lower）的写入进会话可写层。
    local proc_dir = candidate.process_dir()
    local staging = proc_dir .. "/fallback" -- overlay 不可用时的私有可写 cwd
    fs.ensure_dir(staging)
    -- 沙箱内已是 root：剥掉冗余的 sudo/doas（否则会误判为 T2/userns 并失败）。
    if type(args.command) == "string" then
      args.command = _strip_sudo(args.command)
    end
    -- 权限档位：分类命令（需在构建可写根之前，以便包安装命令加入其状态目录作为可写根）。
    local privilege = require("NeoAI.sandbox.privilege")
    local pcfg = config_store.get("tools.sandbox.privilege") or {}
    local req = privilege.classify(attempt.tool_name, args, spec, {
      effective_command = attempt.script_scan and attempt.script_scan.effective,
    })
    attempt.package = req.package == true
    attempt.network = req.network == true
    -- 可写根 = 工具声明（spec.writable_roots）+（包安装时）包管理器状态目录。
    -- 包安装写入的索引/缓存/元数据同样进入 overlay，冻结为候选（不直接落盘）。
    local extra_roots = {}
    for _, r in ipairs(spec.writable_roots or {}) do extra_roots[#extra_roots + 1] = r end
    if req.package then
      attempt.package_roots = _package_roots()
      for _, r in ipairs(attempt.package_roots) do extra_roots[#extra_roots + 1] = r end
    end
    -- 已暂存的包安装产物对后续命令可见：把「有暂存改动」的包可写根也加入本次可写根
    -- （非包安装命令默认只覆盖 cwd，否则后续 `python -m build` 看不到刚装的包）。
    for _, r in ipairs(require("NeoAI.sandbox.candidate").staged_roots()) do
      extra_roots[#extra_roots + 1] = r
    end
    local specs = M.build_overlay_specs(real_cwd, proc_dir, extra_roots)
    -- 选定每个可写根实际使用的层（overlay 或 bind），供物化/捕获/前缀构造一致使用
    for _, spec in ipairs(specs) do
      if runtime.overlay_available() and runtime.overlay_writable(spec.root, spec.upper, spec.work) then
        spec.mode = "overlay"
      else
        spec.mode = "bind"
        -- 记录降级原因，供 run_command 结果中说明（便于排查 overlay 为何不可用）
        spec.overlay_reason = runtime.overlay_reason(spec.root, spec.upper, spec.work)
      end
    end
    -- 双向互通：把工作区暂存内容物化进所选层，使命令看到 AI 尚未发布的编辑
    candidate.materialize_overlay(specs)
    -- 会话级 shell 状态（export/cd 跨命令保留）：仅 bwrap 后端支持（bind 会话目录）。
    local session_shell = (cfg.session_shell ~= false) and runtime.backend() == "bwrap"
    local session_dir = nil
    if session_shell then
      session_dir = proc_dir .. "/shell"
      fs.ensure_dir(session_dir)
      -- 会话 shell 状态目录（bind 到沙箱内）须归载荷所有，否则非 root 载荷无法写入
      -- cwd/env（`sh: cannot create .../cwd: Permission denied`）。
      runtime.chown_payload(session_dir)
    end
    control.transition(attempt, "STAGING")
    -- 资源域（cgroup v2）：默认按宿主资源动态设置 CPU/内存/PID 上限（见 cgroup.resolve_limits）。
    -- 显式配置 limits 时以静态值为准；cgroup 不可用时默认跳过（记录警告，不阻断），
    -- 仅当 limits.fail_closed=true 时明确拒绝（不静默降级）。
    local cgroup = require("NeoAI.sandbox.cgroup")
    local cg_handle = nil
    local prewarmed = nil
    if cgroup.limits_configured() then
      local lcfg = config_store.get("tools.sandbox.limits") or {}
      local limits = cgroup.resolve_limits()
      -- 复用上一条进程命令返回后后台预热的 cgroup + 已挂载探针：探针挂载已与 AI 生成
      -- 下一轮的时间重叠完成，本次命令无需等待挂载。
      local observe_cfg = config_store.get("tools.sandbox.observe") or {}
      if observe_cfg.enabled ~= false then
        prewarmed = _take_prewarm(_limits_key(limits))
      elseif prewarm.cg then
        _prewarm_clear()
      end
      if prewarmed then
        cg_handle = prewarmed.cg
        cgroup.adopt(cg_handle, attempt.attempt_id)
      else
        local h, cerr = cgroup.prepare(attempt.attempt_id, limits)
        if not h then
          if lcfg.fail_closed == true then
            candidate.cleanup(attempt.attempt_id)
            control.transition(attempt, "FAILED")
            return async.reject({ kind = "sandbox", message = cerr, command_id = attempt.command_id })
          end
          require("NeoAI.kernel.logger").warn("[sandbox] cgroup 资源限制不可用，跳过：%s", tostring(cerr))
        else
          cg_handle = h
        end
      end
    end

    -- 内核级行为观测（eBPF/strace/procfs）：优先复用后台预热好的探针；否则在命令前启动
    -- （不等待挂载完成，挂载异步进行，早期访问可能漏观测，由命令解析启发式兜底）。
    local observe_handle = _start_observe(cg_handle, attempt, ctx, prewarmed)

    -- 命令取消/超时/输出截断时真正终止整个进程树：bwrap 载荷在独立 pid 命名空间内，
    -- `jobstop` 只杀外层 bwrap，载荷可能继续存活；`cgroup.kill` 按资源域精确终止全部子进程。
    -- shell/exec 工具在 settle 前调用它（无 cgroup 时为 no-op，仍走 jobstop）。
    ctx.sandbox_kill = function()
      if cg_handle then pcall(cgroup.kill, cg_handle) end
    end

    -- 容器受控：docker/podman 等运行时尽量与沙箱同 namespace（podman 无守护进程可共享；
    -- docker 依赖外部 daemon，保持受控 socket 并记录原因）。重写命令以注入共享标志。
    pcall(function()
      local container = require("NeoAI.sandbox.container")
      local plan = container.plan(args and args.command)
      if plan then
        if plan.rewritten then args.command = plan.command end
        attempt.container_command = plan.command
        container.record(plan, {
          tool = attempt.tool_name, command_id = attempt.command_id, attempt_id = attempt.attempt_id,
        })
      end
    end)
    -- 实际用于执行/捕获的 overlay 规格：嵌套 userns（T2）下 overlay 会 EINVAL，
    -- 退化为「只读根 + 私有 cwd」，改动仅在 cwd 捕获（主机效果走提案）。
    local active_specs = specs

    --- 构造并注入进程前缀（含 cgroup 加入）；失败返回 nil, err
    local function _build_prefix(priv)
      local userns = (priv and priv.userns) == true
      active_specs = userns and {} or specs
      -- 视图降级判定：无任何可写根使用 overlay 时，命令只能看到会话私有视图（看不到真实磁盘
      -- 文件）。默认 fail-closed 直接拒绝，不静默降级；仅 `overlay_fail_closed=false` 才允许
      -- 以降级私有 cwd 运行（结果会附加降级提示）。T2 嵌套 userns 档位天然无 overlay，
      -- 其主机效果冻结为提案，属有意设计，不在此拒绝、也不算「降级」（见下方 sandbox_userns）。
      local degraded = true
      local degraded_reason
      for _, s in ipairs(active_specs) do
        if s.mode == "overlay" then degraded = false end
        if not degraded_reason and s.overlay_reason then degraded_reason = s.overlay_reason end
      end
      if degraded and not userns and cfg.overlay_fail_closed ~= false then
        local detail = degraded_reason and ("原因：" .. tostring(degraded_reason)) or "无可写根可用 overlay"
        return nil, "SANDBOX_OVERLAY_UNAVAILABLE: 无法为可写根挂载 overlay 可写层，拒绝以降级模式运行（"
          .. detail .. "）；请用 :NeoAISandboxCaps 排查，或在 tools.sandbox.overlay_fail_closed=false 显式允许降级"
      end
      -- 审批放行：把本次调用获批解除遮蔽的条目并入 unmask（与档位 unmask 合并）。
      -- 工具子进程可写根（spec.writable_roots）与包安装状态目录也一并 unmask，
      -- 避免其被遮蔽目录遮挡（overlay 在遮蔽之前挂载，遮蔽会将其覆盖）。
      local eff_priv = priv
      local approved = ctx.sandbox_unmask
      local extra_unmask = {}
      for _, p in ipairs(spec.writable_roots or {}) do extra_unmask[#extra_unmask + 1] = p end
      for _, p in ipairs(attempt.package_roots or {}) do extra_unmask[#extra_unmask + 1] = p end
      if (type(approved) == "table" and #approved > 0)
        or #extra_unmask > 0 then
        eff_priv = {}
        for k, v in pairs(priv or {}) do eff_priv[k] = v end
        local merged = {}
        for _, p in ipairs((priv and priv.unmask) or {}) do merged[#merged + 1] = p end
        for _, p in ipairs(approved or {}) do merged[#merged + 1] = p end
        for _, p in ipairs(extra_unmask or {}) do merged[#merged + 1] = p end
        eff_priv.unmask = merged
      end
      local prefix, perr, eff_cwd = runtime.process_prefix({
        cwd = real_cwd, overlays = active_specs, fallback_cwd = staging,
        session_dir = session_dir, session_tmp_dir = proc_dir, privileges = eff_priv,
      })
      if not prefix then return nil, perr end
      if cg_handle then
        local join = cgroup.join_prefix(cg_handle)
        local full = {}
        for _, v in ipairs(join) do full[#full + 1] = v end
        for _, v in ipairs(prefix) do full[#full + 1] = v end
        prefix = full
      end
      -- strace 后端：以命令前缀包裹（带外观测拿不到子进程 pid）；trace 文件由 handle 轮询。
      if require("NeoAI.sandbox.observer").backend() == "strace" then
        local sp, sh = require("NeoAI.sandbox.observer").strace_prefix({
          attempt_id = attempt.attempt_id,
          on_event = function(evt) pcall(_on_observed, attempt, ctx, evt) end,
        })
        if sp then
          local sfull = {}
          for _, v in ipairs(sp) do sfull[#sfull + 1] = v end
          for _, v in ipairs(prefix) do sfull[#sfull + 1] = v end
          prefix = sfull
          ctx._observe_handle = sh
        end
      end
      ctx.sandbox_prefix = prefix
      ctx.sandbox_cwd = eff_cwd
      ctx.sandbox_env = runtime.sandbox_env(eff_priv)
      -- 资源域路径（诊断/归因用）：shell 工具在命令退出（137）时读取 memory/pids 事件判定 OOM。
      ctx.sandbox_cgroup_path = cg_handle and cg_handle.path or nil
      -- token→真实密钥的还原仅限沙箱内部进程：把命令参数中的 NEOKEY_ 还原为真实值后执行，
      -- 而 `args.command`（UI/证据/日志）仍保留 token，AI 与审计面看不到真实密钥。
      if type(args.command) == "string" then
        ctx.sandbox_command = (require("NeoAI.sandbox.secret").detokenize(args.command))
      end
      -- 视图降级标记（degraded/degraded_reason 已在函数开头判定）：无 overlay（bind 私有层）
      -- 时命令看不到真实项目文件，只看到会话私有视图；供 run_command 结果提示。
      -- T2 嵌套 userns 档天然无 overlay，但属有意设计（主机效果冻结为提案），不视为降级，
      -- 单独以 sandbox_userns 标记，供 run_command 显示特权档专用提示。
      ctx.sandbox_userns = userns
      ctx.sandbox_degraded = degraded and not userns
      ctx.sandbox_degraded_reason = (degraded and not userns) and degraded_reason or nil
      ctx.sandbox_shell_state = session_dir and require("NeoAI.sandbox.conceal").session_mount() or nil
      return true
    end

    local function _fail(msg)
      if observe_handle then pcall(observe_handle.stop); observe_handle = nil end
      if cg_handle then cgroup.release(cg_handle) end
      candidate.cleanup(attempt.attempt_id)
      control.transition(attempt, "FAILED")
      return async.reject({ kind = "sandbox", message = msg, command_id = attempt.command_id })
    end

    -- 禁止访问本机 SSH 服务：命令级硬拒绝（ssh/scp/sftp/sshpass 或 ssh:// 指向回环/本机）。
    -- 与「agent socket 遮蔽 + SSH_AUTH_SOCK 环境清除」共同封死本机 ssh 服务访问。
    do
      local denied, target = require("NeoAI.sandbox.risk").ssh_local_target(args and args.command)
      if denied then
        pcall(function()
          require("NeoAI.sandbox.evidence").add("privilege", {
            tool = attempt.tool_name, command = args and args.command,
            reasons = { "SSH_LOCAL_SERVICE_DENIED:" .. tostring(target) },
            source = "observed", coverage = "full",
          }, { tool = attempt.tool_name, command_id = attempt.command_id, attempt_id = attempt.attempt_id })
        end)
        pcall(function()
          require("NeoAI.kernel.event_bus").emit(
            require("NeoAI.kernel.events").SANDBOX_PRIVILEGE_RECORDED, {
              tool = attempt.tool_name, reason = "SSH_LOCAL_SERVICE_DENIED",
              command_id = attempt.command_id,
            })
        end)
        return _fail("SSH_LOCAL_SERVICE_DENIED: 禁止访问本机 SSH 服务（" .. tostring(target) .. "）")
      end
    end

    local resolved = privilege.resolve(req.tier, req)
    if not resolved.ok then
      return _fail(resolved.reason)
    end
    attempt.privilege_tier = req.tier
    if pcfg.record ~= false and req.tier > 0 then
      privilege.record({
        tool = attempt.tool_name, command = args and args.command,
        from_tier = 0, to_tier = req.tier, reasons = req.reasons,
        command_id = attempt.command_id, attempt_id = attempt.attempt_id,
      })
    end
    local built, berr = _build_prefix(resolved.privileges)
    if not built then
      return _fail(berr)
    end

    local d = async.Deferred.new()
    -- 带外观测句柄（ebpf/procfs）已在 staging 前启动；进程退出后停止并冲刷事件。
    local function _stop_observe()
      if observe_handle then pcall(observe_handle.stop) end
      observe_handle = nil
      if ctx._observe_handle then pcall(ctx._observe_handle.stop) end
      ctx._observe_handle = nil
      -- 命令结束后（结果即将返回、AI 开始生成下一轮）在后台预热下一条进程命令的探针，
      -- 使 bpftrace 挂载与 AI 输出重叠；用 vim.schedule 确保结果先返回、不阻塞。
      vim.schedule(function() pcall(_prewarm_observer) end)
    end
    local function finish(res, err)
      _stop_observe()
      -- 诊断：命令结束时 dump 资源域事件（OOM / 进程终止归因），仅日志，不改变行为。
      local diag = config_store.get("tools.sandbox.diagnostics") or {}
      if diag.enabled and cg_handle then
        local snap = diag.dump_cgroup_events and cgroup.events_snapshot(cg_handle.path) or nil
        ctx.sandbox_cgroup_events = snap
        ctx.sandbox_oom = cgroup.snapshot_oom(snap)
        require("NeoAI.kernel.logger").warn(
          "[sandbox:diag] command end attempt=%s code=%s timed_out=%s aborted=%s truncated=%s oom=%s%s",
          tostring(attempt.attempt_id), tostring(res and res.code), tostring(res and res.timed_out),
          tostring(res and res.aborted), tostring(res and res.truncated), tostring(ctx.sandbox_oom),
          snap and (" events=" .. vim.inspect(snap)) or "")
      end
      if cg_handle then cgroup.release(cg_handle) end
      if err then
        local mapping = candidate.mapping(attempt.attempt_id)
        control.transition(attempt, "FAILED")
        candidate.cleanup(attempt.attempt_id)
        d:reject(_rewrite_result(mapping, err))
        return
      end
      -- 通过命令执行结果判断安全级别（权限不足/网络/包变更/破坏性输出等信号）。
      if ctx.sandbox_last_result then
        pcall(function()
          attempt.result_risk = require("NeoAI.sandbox.risk").from_result(ctx.sandbox_last_result, nil)
        end)
      end
      -- 只读进程工具（如 git_status/git_diff）：在沙箱命名空间内读取暂存视图，但不捕获候选。
      -- 命令运行在 overlay 上（真实内容为只读 lower，暂存已物化进 upper），故看到的是暂存内容；
      -- 不冻结候选、不入待审队列，避免只读命令把已暂存改动重复入队。
      if spec.read_only then
        if attempt.result_risk and (attempt.result_risk.level or 0) > 0 then
          pcall(function()
            require("NeoAI.sandbox.risk").record({
              tool = attempt.tool_name, command_id = attempt.command_id, attempt_id = attempt.attempt_id,
              level = attempt.result_risk.level, reasons = attempt.result_risk.reasons,
              signals = attempt.result_risk.signals, source = "result",
            })
            require("NeoAI.sandbox.audit").observe({
              kind = "process", tool = attempt.tool_name, level = attempt.result_risk.level,
              reasons = attempt.result_risk.reasons, command_id = attempt.command_id,
            })
          end)
        end
        control.transition(attempt, "COMPLETED_READ_ONLY")
        candidate.cleanup(attempt.attempt_id)
        d:resolve(res)
        return
      end
      -- 捕获各可写根 overlay 的改动；overlay 不可用（或 userns 档位）时捕获降级私有 cwd。
      -- 遍历/读取/哈希经 utils.work 线程池，避免大量文件/大文件时占满主线程。
      -- 返回 Deferred resolve(settled)：settled.ok/value/err（不直接 resolve `d`）。
      local function after_capture(cand)
        if require("NeoAI.sandbox.fault").hit("freeze") then cand = nil end
        control.transition(attempt, "CANDIDATE_READY")
        -- T2 特权档：命令已在嵌套 userns 内执行（够不到宿主），其主机效果冻结为提案，
        -- 异步审批后在主机上 replay（不阻塞工具调用）。
        if (attempt.privilege_tier or 0) >= 2 and (cfg.review or {}).enabled ~= false then
          pcall(function()
            require("NeoAI.sandbox.hostop").freeze(attempt, args,
              { tier = attempt.privilege_tier, network = true }, { reason = "PRIVILEGED_TIER" })
          end)
        end
        if cand and #cand.files > 0 then
          cand.command_id = attempt.command_id
          -- 包/生成内容判定（命令判定或路径判定）：跳过密钥 token 化与密钥分析，
          -- 避免对 venv/site-packages/node_modules 等逐文件全文扫描。
          local is_pkg = attempt.package == true or _package_manager_of(cand, attempt) ~= nil
          -- 双向互通：把命令改动合并进工作区暂存映射，使 read_file/edit_file 可见。
          -- 候选落盘与密钥分析均异步（线程池），避免大量文件时占满主线程。
          return candidate.merge_candidate_async(cand, { from_command = true, package = is_pkg }):then_(function()
            return _persist_and_settle(cand, attempt, ctx, cfg, spec, res, { command = args and args.command })
          end):then_(function(settled)
            candidate.cleanup(attempt.attempt_id)
            return settled
          end, function(cerr)
            candidate.cleanup(attempt.attempt_id)
            return { ok = false, err = cerr }
          end)
        elseif cand == nil then
          control.transition(attempt, "FAILED")
          candidate.cleanup(attempt.attempt_id)
          return { ok = false, err = { kind = "sandbox", message = "候选冻结失败", command_id = attempt.command_id } }
        else
          control.transition(attempt, "COMPLETED_READ_ONLY")
          candidate.cleanup(attempt.attempt_id)
          return { ok = true, value = res }
        end
      end
      local captures = {}
      if runtime.backend() == "bwrap" and #active_specs > 0 then
        for _, cap_spec in ipairs(active_specs) do
          captures[#captures + 1] = candidate.capture_overlay_async(attempt.attempt_id, cap_spec.root,
            cap_spec.mode == "bind" and cap_spec.bind or cap_spec.upper)
        end
      else
        captures[#captures + 1] = candidate.capture_overlay_async(attempt.attempt_id, real_cwd, staging)
      end
      local chain = async.all(captures):then_(function()
        return candidate.finish_async(attempt.attempt_id)
      end):then_(after_capture, function(cerr)
        control.transition(attempt, "FAILED")
        candidate.cleanup(attempt.attempt_id)
        return { ok = false, err = {
          kind = "sandbox",
          message = "候选冻结失败: " .. tostring(cerr and (cerr.message or cerr) or cerr),
          command_id = attempt.command_id,
        } }
      end)
      if (cfg.postprocess or "async") == "sync" then
        -- 同步模式（测试/确定性）：等待捕获→冻结→合并→落盘→结算完成后再返回结果。
        chain:then_(function(settled)
          if settled and settled.ok then
            d:resolve(settled.value)
          else
            d:reject(settled and settled.err or { kind = "sandbox", message = "结算失败" })
          end
        end, function(e) d:reject(e) end)
      else
        -- 异步模式（默认）：命令进程已退出 → 立即把结果交回主线程下一轮循环；捕获/冻结/合并/
        -- 落盘/结算在后台完成。FIFO 槽位由 `_serialize_process.release` 等待本链完成后再释放，
        -- 保证下一进程命令看到一致的会话暂存。
        _track_postprocess(chain)
        d:resolve(res)
        chain:then_(function(settled)
          if not (settled and settled.ok) then
            require("NeoAI.kernel.logger").warn("[sandbox] 后台结算失败: %s",
              tostring(settled and settled.err and (settled.err.message or settled.err) or "unknown"))
          end
        end, function(e)
          require("NeoAI.kernel.logger").warn("[sandbox] 后台后处理异常: %s",
            tostring(e and (e.message or e) or e))
        end)
      end
    end

    --- 执行一次；权限/网络失败时自动发起升级并在隔离内重跑（记录，不静默）。
    --- 全档位生效：T0 失败升 T1，T1 失败升 T2（直到 max_tier），每步写证据/事件/审计。
    local function run(priv, current_tier)
      call_original():then_(function(res)
        if pcfg.auto_escalate ~= false and not attempt.package and current_tier < (pcfg.max_tier or 2) then
          local raw = ctx.sandbox_last_result
          local esc = privilege.detect_escalation(raw)
          if esc and esc.tier > current_tier then
            local r2 = privilege.resolve(esc.tier, {
              tier = esc.tier, docker = req.docker, network = req.network, sysadmin = req.sysadmin,
            })
            if r2.ok then
              local built2 = _build_prefix(r2.privileges)
              if built2 then
                attempt.privilege_tier = esc.tier
                privilege.record({
                  tool = attempt.tool_name, command = args and args.command,
                  from_tier = current_tier, to_tier = esc.tier, reasons = { esc.reason },
                  command_id = attempt.command_id, attempt_id = attempt.attempt_id,
                })
                pcall(function()
                  require("NeoAI.kernel.event_bus").emit(
                    require("NeoAI.kernel.events").SANDBOX_PRIVILEGE_ESCALATION_REQUESTED, {
                      command_id = attempt.command_id, from_tier = current_tier,
                      to_tier = esc.tier, reason = esc.reason,
                    })
                end)
                -- 提权行为仅记录（写入保护已覆盖文件改动），供后续异常行为分析。
                pcall(function()
                  require("NeoAI.sandbox.audit").observe({
                    kind = "privilege", tool = attempt.tool_name, level = esc.tier >= 2 and 2 or 1,
                    reasons = { esc.reason or "ESCALATION" }, command_id = attempt.command_id,
                  })
                end)
                run(r2.privileges, esc.tier)
                return
              end
            end
          end
        end
        finish(res, nil)
      end, function(err)
        finish(nil, err)
      end)
    end

    -- eBPF 探针挂载为异步 best-effort：默认**不阻塞命令**（`observe.wait_ready_ms=0`），
    -- 避免每条命令固定等待 bpftrace 挂载（约 0.5s）造成可感知卡顿。挂载完成前发生的早期
    -- 访问可能漏观测（由命令解析启发式兜底）；需要更全观测时把 wait_ready_ms 设为正值（有界等待）。
    if observe_handle and observe_handle.wait_ready then
      local ocfg = cfg.observe or {}
      local wait_ms = tonumber(ocfg.wait_ready_ms) or 0
      if wait_ms > 0 then pcall(observe_handle.wait_ready, wait_ms) end
    end
    run(resolved.privileges, req.tier)
    return d
  end

  -- 文件系统写：暂存到工作区私有副本，冻结候选，按模式发布/入队
  local record = candidate.begin(attempt, root)
  local sandbox = require("NeoAI/sandbox")
  local previous_active = sandbox._set_active_attempt(attempt)
  -- 目录工具（创建/确保目录）合法地以目录为目标；其余 fs_write（edit_file 等）写文件，
  -- 若目标在真实盘或沙箱视图中是目录，必须拒绝——否则会把目录覆盖成文件，破坏沙箱视图
  -- 一致性（后续 `ls dir/` 报 Not a directory，属「文件缓存一致性损坏」）。
  local DIR_TOOLS = { create_directory = true, ensure_dir = true }
  if not DIR_TOOLS[attempt.tool_name] then
    for _, key in ipairs(spec.paths or {}) do
      if type(args[key]) == "string" and candidate.view_is_dir(args[key]) then
        sandbox._set_active_attempt(previous_active)
        candidate.cleanup(attempt.attempt_id)
        control.transition(attempt, "FAILED")
        return async.reject({
          kind = "sandbox",
          message = "SANDBOX_TARGET_IS_DIR: 目标路径是目录，不能用文件写入工具覆盖: " .. args[key],
          command_id = attempt.command_id,
        })
      end
    end
  end
  for _, key in ipairs(spec.paths or {}) do
    if type(args[key]) == "string" then
      local staged = candidate.stage_path(attempt.attempt_id, args[key])
      if staged then args[key] = staged end
    end
  end
  control.transition(attempt, "STAGING")

  local d = async.Deferred.new()
  call_original():then_(function(result)
    sandbox._set_active_attempt(previous_active)
    -- 单文件写路径（edit_file 等）保持同步冻结：文件数少，线程池往返反而增加延迟；
    -- 大量文件的 run_command 路径见上方 after_capture（capture/finish 经线程池）。
    local cand = candidate.finish(attempt.attempt_id)
    if require("NeoAI.sandbox.fault").hit("freeze") then cand = nil end
    control.transition(attempt, "CANDIDATE_READY")
    if cand and #cand.files > 0 then
      cand.command_id = attempt.command_id
      store.write_candidate(cand)
      local settled = _settle_candidate(cand, attempt, ctx, cfg, spec, result)
      local value = _rewrite_result(candidate.mapping(attempt.attempt_id), settled.value)
      candidate.cleanup(attempt.attempt_id)
      if settled.ok then d:resolve(value) else d:reject(settled.err) end
    elseif cand == nil then
      control.transition(attempt, "FAILED")
      candidate.cleanup(attempt.attempt_id)
      d:reject({ kind = "sandbox", message = "候选冻结失败", command_id = attempt.command_id })
    else
      -- 无实际文件改动（如写入内容与基线一致）：不产生候选、不入待审队列。
      control.transition(attempt, "COMPLETED_READ_ONLY")
      local value = _rewrite_result(candidate.mapping(attempt.attempt_id), result)
      candidate.cleanup(attempt.attempt_id)
      d:resolve(value)
    end
  end, function(err)
    local mapping = candidate.mapping(attempt.attempt_id)
    sandbox._set_active_attempt(previous_active)
    control.transition(attempt, "FAILED")
    candidate.cleanup(attempt.attempt_id)
    -- 错误信息同样还原暂存路径：否则工具报错会把沙箱内部路径暴露给模型。
    d:reject(_rewrite_result(mapping, err))
  end)
  return d
end

--- 执行门禁：所有工具执行的唯一强制入口。
--- `effect == "process"` 的命令按 FIFO **串行**执行（沙箱会话/overlay 非并发安全，见
--- `_serialize_process`）；沙箱关闭且允许降级时直接执行原工具（不串行）。其余 effect 不串行。
--- @param tool table 工具定义（含 __sandbox_spec）
--- @param args table
--- @param ctx table
--- @param call_original function() -> Deferred 真正执行原工具
--- @return Deferred
function M.gate(tool, args, ctx, call_original)
  local cfg = config_store.get("tools.sandbox") or {}
  if cfg.enabled == false and cfg.fail_closed == false then
    return call_original()
  end
  local spec = tool and tool.__sandbox_spec or tool_spec.get(tool and tool.name, tool and tool.category)
  if spec and spec.effect == "process" then
    return _serialize_process(function() return _gate_inner(tool, args, ctx, call_original) end)
  end
  -- 非进程工具（read/fs_write/in_process）：若上一条进程命令的后处理仍在途（异步模式），
  -- 先等待其完成——命令的 overlay 改动经后台合并进会话暂存后，读写工具才能看到一致视图
  -- （否则「命令刚创建的文件」读取会落空）。等待不改变 FIFO 语义。
  local pending = postprocess.pending
  if not pending then
    return _gate_inner(tool, args, ctx, call_original)
  end
  local out = async.Deferred.new()
  local function proceed()
    _gate_inner(tool, args, ctx, call_original):then_(
      function(v) out:resolve(v) end, function(e) out:reject(e) end)
  end
  pending:then_(proceed, proceed)
  return out
end

--- 是否有后台后处理链在途（异步模式下命令结果已返回、捕获/冻结/结算尚未完成）。
--- @return boolean
function M.postprocess_pending()
  return postprocess.pending ~= nil
end

--- 等待当前后台后处理链完成（测试/关闭/重置前调用，保证不丢冻结与待审入队）。
--- @param timeout_ms number|nil
--- @return boolean 是否已完成
function M.await_postprocess(timeout_ms)
  local deadline = vim.uv.hrtime() + (timeout_ms or 60000) * 1e6
  while postprocess.pending do
    if vim.uv.hrtime() > deadline then return false end
    local p = postprocess.pending
    local done = false
    p:then_(function() done = true end, function() done = true end)
    vim.wait(50, function() return done or postprocess.pending ~= p end)
  end
  return true
end

--- 重置后台后处理登记（测试用；不取消在途链）。
function M._reset_postprocess()
  postprocess.pending = nil
  postprocess.seq = 0
end

--- 登记一个后台后处理 Deferred（测试用；模拟卡住/在途的后处理链）。
--- @param def Deferred|nil
function M._set_postprocess_pending(def)
  postprocess.seq = postprocess.seq + 1
  postprocess.pending = def
end

return M
