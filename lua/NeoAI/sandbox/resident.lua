--- 会话级常驻沙箱实例（命令服务器）
--- @module NeoAI.sandbox.resident
--- 同一沙箱会话内，`run_command` 的进程命令不再各起一个 bwrap（命令结束即销毁 pid 命名空间、
--- cgroup.kill 回收整个进程树），而是共享一个**常驻 bwrap 实例**：它在一个持久的
--- mount+pid+net+ipc+uts+cgroup 命名空间内运行一个命令服务器（bash 从 stdin 读取请求），
--- 命令在服务器内执行。因此后台进程（`&`/nohup/setsid）跨工具调用存活，`ps`/`kill` 等在
--- 同一命名空间内可见，行为接近普通 bash。
---
--- 为何用命令服务器而非 nsenter：bwrap 以 chroot/pivot_root 改变的是**进程**根目录（fs_struct），
--- 不属于 mount 命名空间；外部 `nsenter -m` 只进入挂载表、拿不到该根，exec 会
--- `No such file or directory`。服务器在命名空间**内部**执行命令，天然拥有正确根视图。
---
--- 与一次性进程的关系：
---   * overlay upper/work 使用**独立**基目录（`<proc_dir>/resident`），不与一次性进程的
---     `<proc_dir>/<enc_root>` 竞争（同一 upper 不可并发挂载）；二者通过候选暂存层同步。
---   * 常驻实例在挂载前把工作区暂存物化进 upper（宿主侧写入，安全）；挂载后 AI 的新编辑
---     经 `materialize()` 在**命名空间内**写回（写入走 overlay 挂载，避免 overlayfs
---     「挂载期间宿主侧改 upper 未定义」的问题）。
---   * 命令结束后由门禁在宿主侧**只读**遍历 upper 捕获改动（读安全）。
---   * 资源域为会话级 cgroup：命令是服务器（已在资源域内）的子进程，继承资源域。
---     超时/取消按进程组精确终止当前命令（不波及常驻实例与其它后台进程）。
---
--- 关闭/会话轮换/热重载时 `stop()`：终止常驻实例（连同其后代）。

local async = require("NeoAI.utils.async")
local config_store = require("NeoAI.kernel.config_store")
local fs = require("NeoAI.utils.fs")
local runtime = require("NeoAI.sandbox.runtime")
local candidate = require("NeoAI.sandbox.candidate")
local cgroup = require("NeoAI.sandbox.cgroup")
local logger = require("NeoAI.kernel.logger")

local M = {}

local RS = "\30" -- 请求/响应帧起始（\x1e）
local US = "\31" -- 请求/响应帧结束（\x1f）

-- ========== 私有状态 ==========

local state = {
  instance = nil, -- 当前会话的常驻实例
}

-- ========== 私有函数 ==========

--- @return table
local function _cfg()
  return config_store.get("tools.sandbox.resident") or {}
end

--- shell 解释器绝对路径：服务器/载荷在沙箱环境（PATH 可能不含 /usr/bin）中 exec。
--- @return string
local function _shell_bin()
  if vim.fn.executable("bash") == 1 then
    local p = vim.fn.exepath("bash")
    if p ~= "" then return p end
    return "/bin/bash"
  end
  return "/bin/sh"
end

--- setsid 绝对路径（可选）：每条命令独立进程组，超时/取消可精确终止当前命令。
--- @return string|nil
local function _setsid_bin()
  if vim.fn.executable("setsid") ~= 1 then return nil end
  local p = vim.fn.exepath("setsid")
  return (p ~= "" and p) or nil
end

--- 常驻实例是否可用（配置 + 后端）。
--- @return boolean
--- @return string|nil reason
function M.available()
  if _cfg().enabled == false then return false, "RESIDENT_DISABLED" end
  if runtime.backend() ~= "bwrap" then return false, "RESIDENT_REQUIRES_BWRAP" end
  return true
end

--- 暂存条目的签名：内容/权限变化即视为需要重新物化。
--- @param entry table { real, staged, deleted }
--- @return string
local function _sig(entry)
  if entry.deleted then return "D" end
  local st = vim.uv.fs_stat(entry.staged)
  if not st then return "D" end
  if st.type == "directory" then return "dir" end
  local m = st.mtime or {}
  return table.concat({ tostring(st.size or 0), tostring(m.sec or 0), tostring(m.nsec or 0) }, ":")
end

--- 权限档位指纹：档位/能力/挂载变化需重建常驻实例（命名空间能力不可原地变更）。
--- @param priv table|nil
--- @return string
local function _priv_key(priv)
  if type(priv) ~= "table" then return "none" end
  local parts = {}
  for _, k in ipairs({ "userns", "network", "cap_add", "mounts", "unmask", "apt_sandbox_user" }) do
    local v = priv[k]
    if type(v) == "table" then
      local vs = {}
      for _, x in ipairs(v) do
        vs[#vs + 1] = type(x) == "table"
          and (tostring(x.src or "") .. ">" .. tostring(x.dst or "") .. ":" .. tostring(x.mode or ""))
          or tostring(x)
      end
      parts[#parts + 1] = k .. "=" .. table.concat(vs, ",")
    elseif v ~= nil then
      parts[#parts + 1] = k .. "=" .. tostring(v)
    end
  end
  return table.concat(parts, ";")
end

--- 命令服务器脚本：从 stdin 逐行读取请求（base64 字段，避免二进制/换行破坏帧）。
---   X\t<id>\t<base64(cmd)>  执行命令，输出以 BEGIN/PID/END 标记帧定界
---   M\t<id>\t<base64(payload)>  物化（payload 为 op\treal_b64\tcontent_b64 行）
--- @param boot string|nil 服务器进入读取循环前的引导片段（如启动 systemd --user）
--- @return string
local function _server_script(boot)
  local shell = _shell_bin()
  local setsid = _setsid_bin()
  local launch = setsid and (setsid .. " " .. shell .. " -c \"$__cmd\"")
    or (shell .. " -c \"$__cmd\"")
  local head = (type(boot) == "string" and boot ~= "") and (boot .. "\n") or ""
  return head .. table.concat({
    "set +e",
    "__p=/tmp/.neoai_res",
    "mkdir -p \"$__p\" 2>/dev/null",
    "while IFS= read -r __line; do",
    "  case \"$__line\" in",
    "    X*)",
    "      __rest=${__line#X$'\\t'}",
    "      __id=${__rest%%$'\\t'*}",
    "      __cb=${__rest#*$'\\t'}",
    "      __cmd=$(printf '%s' \"$__cb\" | base64 -d)",
    "      __of=\"$__p/out.$__id\"",
    -- 并发执行：每条命令后台运行（launch 内 setsid，进程组=会话，便于按组终止），
    -- 输出写独立文件；完成后以 flock 加锁**原子地**输出 BEGIN/内容/END 块，
    -- 使并发命令的输出块互不交错（客户端按 id 多路解复用）。PID 帧同样加锁，
    -- 避免插入到别的命令的输出块中。读取循环不阻塞等待命令，故同一实例内命令真正并行。
    "      ( " .. launch .. " </dev/null >\"$__of\" 2>&1 & __c=$!; "
      .. "printf '%s' \"$__c\" > \"$__p/pid.$__id\"; "
      .. "__id=\"$__id\" __c=\"$__c\" flock \"$__p/lock\" "
      .. "sh -c 'printf \"\\036PID %s %s\\037\" \"$__id\" \"$__c\"'; "
      .. "wait \"$__c\"; __rc=$?; "
      .. "__id=\"$__id\" __rc=\"$__rc\" __of=\"$__of\" flock \"$__p/lock\" "
      .. "sh -c 'printf \"\\036BEGIN %s\\037\" \"$__id\"; cat \"$__of\"; "
      .. "printf \"\\036END %s %s\\037\" \"$__id\" \"$__rc\"'; rm -f \"$__of\" \"$__p/pid.$__id\" ) &",
    "      ;;",
    -- 终止控制帧：宿主侧无法按 pid 杀沙箱命名空间内的进程，改由服务器在命名空间内
    -- 按命令进程组（会话）精确终止；被终止的命令仍会输出含部分输出的 BEGIN/END 块。
    "    K*)",
    "      __kid=${__line#K$'\\t'}",
    "      __kid=${__kid%%$'\\t'*}",
    "      __kpid=$(cat \"$__p/pid.$__kid\" 2>/dev/null)",
    "      [ -n \"$__kpid\" ] && kill -KILL -\"$__kpid\" 2>/dev/null",
    "      ;;",
    "    M*)",
    "      __rest=${__line#M$'\\t'}",
    "      __id=${__rest%%$'\\t'*}",
    "      __cb=${__rest#*$'\\t'}",
    "      printf '%s' \"$__cb\" | base64 -d > \"$__p/m\" 2>/dev/null",
    "      while IFS=$'\\t' read -r __op __a __b; do",
    "        [ -z \"$__op\" ] && continue",
    "        __pp=$(printf '%s' \"$__a\" | base64 -d)",
    "        case \"$__op\" in",
    "          d) rm -rf -- \"$__pp\" ;;",
    "          D) mkdir -p -- \"$__pp\" ;;",
    "          w) mkdir -p -- \"$(dirname -- \"$__pp\")\"; printf '%s' \"$__b\" | base64 -d > \"$__pp\" ;;",
    "        esac",
    "      done < \"$__p/m\"",
    "      printf '\\036MAT %s\\037' \"$__id\"",
    "      ;;",
    "  esac",
    "done",
  }, "\n")
end

--- 解析常驻实例 stdout 缓冲：按 id 多路解复用标记帧与输出块（支持并发命令）。
--- 输出块（BEGIN…END 之间）由服务器以 flock 原子写出，故整块归属同一 id；
--- 块外文本为服务器自身噪声，不归属任何命令。
--- @param inst table
local function _drain(inst)
  local buf = inst.buf
  while true do
    local s = buf:find(RS, 1, true)
    if not s then
      -- 无标记的纯输出：归属当前活动输出块；块外为服务器噪声。
      if #buf > 0 then
        if inst.block then
          inst.block.chunks[#inst.block.chunks + 1] = buf
        else
          inst.noise = (inst.noise or "") .. buf
        end
      end
      buf = ""
      break
    end
    if s > 1 then
      local txt = buf:sub(1, s - 1)
      if inst.block then
        inst.block.chunks[#inst.block.chunks + 1] = txt
      else
        inst.noise = (inst.noise or "") .. txt
      end
    end
    local e = buf:find(US, s + 1, true)
    if not e then
      buf = buf:sub(s)
      break
    end
    local marker = buf:sub(s + 1, e - 1)
    buf = buf:sub(e + 1)
    local kind, id = marker:match("^(%S+)%s+(%S+)")
    if kind == "BEGIN" then
      inst.block = { id = id, chunks = {} }
    elseif kind == "PID" then
      local p = inst.pendings[id]
      if p then p.cpid = tonumber(marker:match("^PID%s+%S+%s+(%d+)")) end
    elseif kind == "END" then
      local rc = tonumber(marker:match("^END%s+%S+%s+(%-?%d+)"))
      local p = inst.pendings[id]
      if inst.block and inst.block.id == id then
        if p then p.chunks = inst.block.chunks end
        inst.block = nil
      end
      if p then p.finish(rc or -1, false) end
    elseif kind == "MAT" then
      local p = inst.pendings[id]
      if p then p.finish(0, true) end
    end
  end
  inst.buf = buf
end

--- 发起一个请求（串行）：设置 pending，发送一行，处理超时/取消。
--- resolve 结果表：{ code, stdout, stderr, is_mat?, cpid?, timed_out?, aborted?, message? }
--- @param inst table
--- @param kind string "X" | "M"
--- @param b64 string base64 编码的载荷
--- @param opts table { timeout_ms?, signal? }
--- @return Deferred
local function _request(inst, kind, b64, opts)
  local d = async.Deferred.new()
  inst.seq = inst.seq + 1
  local id = tostring(inst.seq)
  local pending = { id = id, chunks = {} }
  local done = false
  local function settle(res)
    if done then return end
    done = true
    if inst.pendings[id] == pending then inst.pendings[id] = nil end
    d:resolve(res)
  end
  pending.finish = function(rc, is_mat)
    if is_mat then
      settle({ code = 0, stdout = table.concat(pending.chunks or {}), stderr = "", is_mat = true })
    else
      settle({
        code = rc, stdout = table.concat(pending.chunks or {}), stderr = "",
        cpid = pending.cpid, timed_out = pending.timed_out, aborted = pending.aborted,
        message = pending.abort_message,
      })
    end
  end
  inst.pendings[id] = pending

  local timeout_ms = opts.timeout_ms or 30000
  local cfg_rc = config_store.get("tools.run_command") or {}
  local max_wall = tonumber(cfg_rc.max_wall_ms) or 0
  if max_wall > 0 and (timeout_ms < 0 or timeout_ms > max_wall) then timeout_ms = max_wall end

  local function kill_group()
    -- 宿主侧 pid 与沙箱 pid 命名空间内的 pid 不同，无法直接 kill；改发控制帧由服务器在
    -- 命名空间内按命令进程组终止。
    pcall(vim.fn.chansend, inst.job, "K\t" .. id .. "\t\n")
  end

  if opts.signal then
    opts.signal:subscribe(function(reason)
      if done then return end
      pending.aborted = true
      pending.abort_message = reason
      kill_group()
      -- 命令被终止后服务器仍会输出 BEGIN/部分输出/END 块（含终止前已产生的输出）；
      -- 给短暂宽限等待该块，避免丢失部分输出。
      vim.defer_fn(function()
        if done then return end
        settle({ code = -1, stdout = table.concat(pending.chunks or {}), stderr = "", aborted = true, message = reason })
      end, 1500)
    end)
  end
  if timeout_ms > 0 then
    vim.defer_fn(function()
      if done then return end
      pending.timed_out = true
      kill_group()
      vim.defer_fn(function()
        if done then return end
        settle({ code = -1, stdout = table.concat(pending.chunks or {}), stderr = "", timed_out = true })
      end, 1500)
    end, timeout_ms)
  end

  local ok = pcall(vim.fn.chansend, inst.job, kind .. "\t" .. id .. "\t" .. b64 .. "\n")
  if not ok then
    settle({ code = -1, stdout = "", stderr = "", message = "常驻沙箱请求发送失败" })
  end
  return d
end

-- ========== 公开 API ==========

--- 启动（或复用）当前会话的常驻沙箱实例。
--- @param opts table {
---   specs table, cwd string, privileges table, session_dir? string,
---   session_tmp_dir? string, fallback_cwd? string, env? table }
--- @return table|nil inst
--- @return string|nil err
function M.ensure(opts)
  opts = opts or {}
  local session_id = candidate.session_id() or candidate.begin_session()
  local want_key = _priv_key(opts.privileges)
  local inst = state.instance
  if inst and inst.session_id == session_id and inst.alive and inst.job and inst.job > 0
    and inst.priv_key == want_key then
    return inst
  end
  if inst then M.stop() end

  local specs = opts.specs or {}
  -- 首次：挂载前把工作区暂存物化进 upper（宿主侧写入安全）。
  local conflicts = candidate.materialize_overlay(specs)
  if conflicts and #conflicts > 0 then
    return nil, "SANDBOX_MATERIALIZE_TYPE_CONFLICT: " .. tostring(conflicts[1] and conflicts[1].real)
  end

  -- 嵌套 systemd --user（可选）：委派一个可写 cgroup 子树 bind 到 /sys/fs/cgroup，
  -- 使沙箱内真实 user manager 能在本子树内管理服务，且不污染宿主其它 cgroup。
  local sduser_mod = nil
  local deleg = nil
  local priv = opts.privileges
  do
    local ok, mod = pcall(require, "NeoAI.sandbox.systemd_user")
    if ok and mod and mod.available() then
      local h, derr = cgroup.prepare_delegated("sd_" .. tostring(session_id), cgroup.resolve_limits())
      if h then
        deleg = h
        sduser_mod = mod
        local p2 = {}
        for k, v in pairs(priv or {}) do p2[k] = v end
        local mounts = {}
        for _, m in ipairs((priv and priv.mounts) or {}) do mounts[#mounts + 1] = m end
        mounts[#mounts + 1] = { src = h.path, dst = "/sys/fs/cgroup", mode = "rw" }
        p2.mounts = mounts
        priv = p2
      else
        logger.warn("[sandbox:systemd_user] 委派 cgroup 不可用，跳过：%s", tostring(derr))
      end
    end
  end

  local prefix, perr = runtime.process_prefix({
    cwd = opts.cwd, overlays = specs, fallback_cwd = opts.fallback_cwd,
    session_dir = opts.session_dir, session_tmp_dir = opts.session_tmp_dir,
    privileges = priv,
  })
  if not prefix then
    if deleg then pcall(cgroup.release_delegated, deleg) end
    return nil, perr
  end

  local cg_handle = nil
  if cgroup.limits_configured() then
    local h, cerr = cgroup.prepare("resident_" .. tostring(session_id), cgroup.resolve_limits())
    if h then cg_handle = h
    else logger.warn("[sandbox:resident] cgroup 不可用，跳过：%s", tostring(cerr)) end
  end

  local env = opts.env or runtime.sandbox_env(priv) or {}
  if sduser_mod then
    env.XDG_RUNTIME_DIR = sduser_mod.runtime_dir()
    env.DBUS_SESSION_BUS_ADDRESS = "unix:path=" .. sduser_mod.runtime_dir() .. "/bus"
  end

  local argv = {}
  if cg_handle then
    for _, v in ipairs(cgroup.join_prefix(cg_handle)) do argv[#argv + 1] = v end
  end
  for _, v in ipairs(prefix) do argv[#argv + 1] = v end
  argv[#argv + 1] = _shell_bin()
  argv[#argv + 1] = "-c"
  argv[#argv + 1] = _server_script(sduser_mod and sduser_mod.boot_snippet() or nil)

  inst = {
    session_id = session_id, specs = specs, cwd = opts.cwd, env = env,
    cg = cg_handle, deleg = deleg, alive = true, materialized = {}, seq = 0,
    buf = "", pendings = {}, block = nil, noise = nil, priv_key = want_key,
  }
  local job = vim.fn.jobstart(argv, {
    cwd = opts.cwd,
    env = env,
    stdin = "pipe",
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      if not data or #data == 0 then return end
      inst.buf = inst.buf .. table.concat(data, "\n")
      _drain(inst)
    end,
    on_stderr = function(_, data)
      if not data or #data == 0 then return end
      inst.buf = inst.buf .. table.concat(data, "\n")
      _drain(inst)
    end,
    on_exit = function()
      inst.alive = false
      local ps = {}
      for _, p in pairs(inst.pendings or {}) do ps[#ps + 1] = p end
      inst.pendings = {}
      for _, p in ipairs(ps) do p.finish(-1, false) end
    end,
  })
  if job <= 0 then
    if cg_handle then pcall(cgroup.release, cg_handle) end
    if deleg then pcall(cgroup.release_delegated, deleg) end
    return nil, "无法启动常驻沙箱实例"
  end
  inst.job = job
  inst.argv = argv
  -- 首次物化已在挂载前完成：登记当前暂存签名，避免重复下发。
  for _, o in ipairs(candidate.workspace_overrides()) do
    inst.materialized[o.real] = _sig(o)
  end
  state.instance = inst
  -- 健康检查：确认命令服务器可用；失败则停止并交回一次性执行（避免命令挂起）。
  -- systemd --user 引导在服务器进入读取循环前执行，可能耗时数秒（含就绪等待），故放宽。
  local health_ms = sduser_mod and 25000 or 3000
  local healthy = false
  _request(inst, "X", vim.base64.encode("true"), { timeout_ms = health_ms }):then_(
    function(res) healthy = res and res.code == 0 end, function() end)
  vim.wait(health_ms + 3000, function() return healthy or not inst.alive end, 20)
  if not healthy then
    M.stop({ timeout_ms = 2000 })
    return nil, "常驻沙箱命令服务器无响应"
  end
  return inst
end

--- 当前常驻实例（无则 nil）。
--- @return table|nil
function M.active()
  local inst = state.instance
  if inst and inst.alive and inst.job and inst.job > 0 then return inst end
  return nil
end

--- 把 AI 尚未物化的暂存编辑在命名空间内写回沙箱视图（写走 overlay 挂载）。
--- @return Deferred
function M.materialize()
  local inst = M.active()
  if not inst then return async.resolve() end
  local lines, changed = {}, false
  for _, o in ipairs(candidate.workspace_overrides()) do
    local sig = _sig(o)
    if inst.materialized[o.real] ~= sig then
      changed = true
      inst.materialized[o.real] = sig
      if o.deleted then
        lines[#lines + 1] = "d\t" .. vim.base64.encode(o.real)
      else
        local content = fs.read_file(o.staged)
        if content == nil then
          lines[#lines + 1] = "D\t" .. vim.base64.encode(o.real)
        else
          lines[#lines + 1] = "w\t" .. vim.base64.encode(o.real) .. "\t" .. vim.base64.encode(content)
        end
      end
    end
  end
  if not changed then return async.resolve() end
  local payload = table.concat(lines, "\n") .. "\n"
  local out = async.Deferred.new()
  _request(inst, "M", vim.base64.encode(payload), { timeout_ms = 120000 }):then_(
    function(res) out:resolve(res and res.is_mat == true) end, function(e) out:reject(e) end)
  return out
end

--- 在常驻沙箱内执行一条命令。
--- @param command string
--- @param opts table { cwd?, timeout_ms?, signal? }
--- @return Deferred
function M.exec(command, opts)
  local inst = M.active()
  if not inst then
    return async.reject({ kind = "sandbox", message = "常驻沙箱实例不可用" })
  end
  opts = opts or {}
  local out = async.Deferred.new()
  M.materialize():then_(function()
    return _request(inst, "X", vim.base64.encode(command), opts)
  end):then_(function(res)
    local cfg_rc = config_store.get("tools.run_command") or {}
    local max_out = tonumber(cfg_rc.max_output_bytes) or 0
    local stdout = res.stdout or ""
    local truncated = false
    if max_out > 0 and #stdout > max_out then
      stdout = stdout:sub(1, max_out)
      truncated = true
    end
    local oom = false
    if res.code == 137 and inst.cg and inst.cg.path then
      oom = cgroup.snapshot_oom(cgroup.events_snapshot(inst.cg.path))
    end
    out:resolve({
      code = res.code, stdout = stdout, stderr = "", truncated = truncated,
      oom = oom, timed_out = res.timed_out, aborted = res.aborted, message = res.message,
    })
  end, function(e) out:reject(e) end)
  return out
end

--- 终止当前正在执行的命令（超时/取消）；不影响常驻实例与其它后台进程。
--- 并发实例下可能有多个在途命令：逐一发送终止控制帧，由服务器在命名空间内按进程组终止。
function M.kill_current()
  local inst = state.instance
  if not inst or not inst.job or inst.job <= 0 then return end
  for id in pairs(inst.pendings or {}) do
    pcall(vim.fn.chansend, inst.job, "K\t" .. id .. "\t\n")
  end
end

--- 停止常驻实例（终止其命名空间内全部进程，含后台进程）并释放资源域。
--- @param opts table|nil { timeout_ms? }
function M.stop(opts)
  opts = opts or {}
  local inst = state.instance
  state.instance = nil
  if not inst then return end
  if inst.cg then pcall(cgroup.kill, inst.cg) end
  if inst.job and inst.job > 0 then
    pcall(vim.fn.jobstop, inst.job)
    pcall(vim.fn.jobwait, { inst.job }, math.max(0, tonumber(opts.timeout_ms) or 2000))
  end
  if inst.cg then pcall(cgroup.release, inst.cg) end
  -- 释放委派 cgroup（systemd --user 子域随命名空间销毁后清空）。
  if inst.deleg then pcall(cgroup.release_delegated, inst.deleg) end
end

--- 重置（测试用）
function M.reset()
  M.stop({ timeout_ms = 2000 })
  state.instance = nil
end

return M
