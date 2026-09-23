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
---   * overlay upper/work 使用**稳定**基目录（`<sandbox_root>/resident`，不随会话轮换），
---     不与一次性进程的 `<proc_dir>/<enc_root>` 竞争（同一 upper 不可并发挂载）；二者通过候选暂存层同步。
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

--- timeout 绝对路径（可选）：给 `head -c` 加读取上限。协议失步（帧头声明的长度与实际发送
--- 字节不符）时，`head -c` 会永久阻塞、读取循环停摆，后续所有请求排队后全部超时；加超时后
--- 服务器会退出，客户端据 on_exit 重建实例。缺失时仍由客户端探活兜底。
--- @return string|nil
local function _timeout_bin()
  if vim.fn.executable("timeout") ~= 1 then return nil end
  local p = vim.fn.exepath("timeout")
  return (p ~= "" and p) or nil
end

--- 常驻实例是否可用（配置 + 后端 + 命令服务器所需工具）。
--- @return boolean
--- @return string|nil reason
function M.available()
  if _cfg().enabled == false then return false, "RESIDENT_DISABLED" end
  if runtime.backend() ~= "bwrap" then return false, "RESIDENT_REQUIRES_BWRAP" end
  -- 命令服务器依赖这些工具做请求/输出帧编解码与并发输出串行化；`mktemp` 用于为每个服务器
  -- 实例创建**唯一**的请求/结果目录（避免并存/孤儿服务器共用固定目录而互相踩踏）。缺失会让
  -- 命令无输出地挂到超时（间歇性且难定位），故预先探测：缺失即回退一次性执行（不静默产生超时）。
  for _, b in ipairs({ "base64", "flock", "mktemp" }) do
    if vim.fn.executable(b) ~= 1 then return false, "RESIDENT_MISSING_BIN:" .. b end
  end
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
--- 重建复用同一 overlay upper（`<sandbox_root>/resident`，稳定），故属主/文件等跨命令状态不丢失；
--- 关键是让 sysadmin（chown 等）命令也走常驻实例（见 wrapper._resident_eligible），
--- 而非一次性路径（一次性路径 overlay 独立、命令后即丢弃，属主改动不持久）。
--- @param priv table|nil
--- @return string
local function _priv_key(priv)
  if type(priv) ~= "table" then return "none" end
  local parts = {}
  for _, k in ipairs({ "userns", "network", "cap_add", "mounts", "unmask", "apt_sandbox_user", "maintscript_stubs", "systemctl_shim" }) do
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

--- 命令服务器脚本：从 stdin 读取请求。帧头为一行（以换行结尾），载荷为定长二进制块
--- （由帧头中的字节长度界定），用 `head -c` 分块消费——bash `read` 逐字节读大载荷会打满 CPU。
---   X\t<id>\t<len>\n<cmd>              执行命令，输出以 BEGIN/PID/END 标记帧定界
---   M\t<id>\t<len>\n<payload>          物化（payload 为 op\treal_b64\tcontent_b64 行，原始文本）
---   K\t<id>\t\n                          终止当前命令进程组
--- 载荷为**原始字节**（长度界定，无需 base64）：省去客户端一次整帧 base64 编码（主线程）
--- 与服务器一次解码，减小主线程压力与帧体积。payload 内容本身仍以 base64 承载字段
--- （content_b64），以便用制表符/换行解析。
--- 命令输出块的内容以 base64 承载（客户端解码）：nvim 的 job 输出层会把 NUL 字节
--- 改写成换行，且命令输出可能包含与帧定界相同的控制字节（\x1e/\x1f），直接 `cat` 会
--- 破坏 BEGIN/END 帧定界导致输出丢失/串扰；base64 为纯 ASCII，帧定界安全。
--- @param boot string|nil 服务器进入读取循环前的引导片段（如启动 systemd --user）
--- @return string
local function _server_script(boot)
  local shell = _shell_bin()
  local setsid = _setsid_bin()
  local launch = setsid and (setsid .. " " .. shell .. " -c \"$__cmd\"")
    or (shell .. " -c \"$__cmd\"")
  local timeout = _timeout_bin()
  -- 定长载荷读取：`head -c "$__len"`。加 timeout 上限，避免协议失步时永久阻塞读取循环；
  -- 超时/出错即退出服务器（客户端 on_exit 后重建），而不是让后续所有请求排队超时。
  local function head_cmd(dst)
    local base = "head -c \"$__len\" > \"$__p/" .. dst .. "\" 2>/dev/null"
    if timeout then return timeout .. " 30 " .. base .. " || exit 1" end
    return base
  end
  local head = (type(boot) == "string" and boot ~= "") and (boot .. "\n") or ""
  return head .. table.concat({
    "set +e",
    -- 每服务器实例唯一的结果目录：并用固定路径 `/tmp/.neoai_res` 会让**并存**的服务器
    -- （并发 ensure、上个 nvim 会话残留的孤儿服务器）共用同一目录；它们各自从此实例的
    -- `inst.seq`（从 1 起）编号，out.<id>/pid.<id> 同名互相 rm/读取，一方 `base64 "$__of"`
    -- 读到已被另一方删除的文件，把 `base64: ... No such file or directory` 写进该命令的
    -- 输出块并顶替命令结果。`mktemp -d` 由内核保证名字唯一。注意**不能**改用 `$$`：常驻
    -- 实例以 `--as-pid-1` 运行在独立 PID 命名空间内，`$$` 恒为 1，无法区分并存实例。
    "__p=$(mktemp -d /tmp/.neoai_res.XXXXXX 2>/dev/null) || exit 1",
    "trap 'rm -rf \"$__p\"' EXIT",
    "trap 'rm -rf \"$__p\"; exit' TERM INT HUP",
    "while IFS= read -r __line; do",
    "  case \"$__line\" in",
    "    X*)",
    "      __rest=${__line#X$'\\t'}",
    "      __id=${__rest%%$'\\t'*}",
    "      __len=${__rest#*$'\\t'}",
    -- 定长载荷：帧头带字节长度，用 `head -c`（分块读）消费，避免 bash `read` 逐字节读取
    -- 大载荷（物化帧可达数十 MB，逐字节读会打满 CPU 数分钟）。
    "      " .. head_cmd("in"),
    "      __cmd=$(cat \"$__p/in\")",
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
      .. "sh -c 'printf \"\\036BEGIN %s\\037\" \"$__id\"; base64 \"$__of\"; "
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
    "      __len=${__rest#*$'\\t'}",
    "      " .. head_cmd("m"),
    "      while IFS=$'\\t' read -r __op __a __b; do",
    "        [ -z \"$__op\" ] && continue",
    "        __pp=$(printf '%s' \"$__a\" | base64 -d)",
    "        case \"$__op\" in",
    "          d) rm -rf -- \"$__pp\" ;;",
    "          D) mkdir -p -- \"$__pp\" ;;",
    -- 大文件物化：内容不内嵌于帧，改为从收件箱（会话目录 bind 进命名空间）按文件复制，
    -- 临时文件 + rename 原子替换，避免 bash 逐字节 read 读取数百 MB 内容撑爆 CPU。
    "          c) mkdir -p -- \"$(dirname -- \"$__pp\")\"; "
      .. "__src=$(printf '%s' \"$__b\" | base64 -d); "
      .. "cp -f -- \"$__src\" \"$__pp.neoai.tmp\" && mv -f -- \"$__pp.neoai.tmp\" \"$__pp\" ;;",
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

--- 解码命令输出块（服务器以 base64 承载，避免控制字节/NUL 破坏帧定界）。
--- 超时/取消时可能只有部分 base64，按 4 的倍数截断后尽力解码，失败则回退原文。
--- @param chunks table
--- @return string
local function _decode_chunks(chunks)
  local b64 = table.concat(chunks or {})
  if b64 == "" then return "" end
  b64 = b64:gsub("%s", "")
  local n = #b64 - (#b64 % 4)
  if n <= 0 then return "" end
  local ok, dec = pcall(vim.base64.decode, b64:sub(1, n))
  if ok and type(dec) == "string" then return dec end
  return b64
end

--- 发起一个请求（串行）：设置 pending，发送帧头 + 原始载荷，处理超时/取消。
--- resolve 结果表：{ code, stdout, stderr, is_mat?, cpid?, timed_out?, aborted?, message? }
--- @param inst table
--- @param kind string "X" | "M"
--- @param payload string 原始载荷（命令字符串 / 物化 payload），非 base64
--- @param opts table { timeout_ms?, signal? }
--- @return Deferred
local function _request(inst, kind, payload, opts)
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
        code = rc, stdout = _decode_chunks(pending.chunks), stderr = "",
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
        settle({ code = -1, stdout = _decode_chunks(pending.chunks), stderr = "", aborted = true, message = reason })
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
        settle({ code = -1, stdout = _decode_chunks(pending.chunks), stderr = "", timed_out = true })
      end, 1500)
    end, timeout_ms)
  end

  -- 帧头带载荷字节长度，随后紧跟**原始载荷**（无尾随换行）：服务器用 `head -c` 分块读取。
  -- 原始载荷（不 base64）省去客户端一次整帧编码（主线程）与服务器一次解码。
  local ok = pcall(vim.fn.chansend, inst.job, kind .. "\t" .. id .. "\t" .. tostring(#payload) .. "\n" .. payload)
  if not ok then
    settle({ code = -1, stdout = "", stderr = "", message = "常驻沙箱请求发送失败" })
  end
  return d
end

--- 健康探测：短超时 `X true`。命令在服务器内并发执行，读取循环始终空闲，故服务器健康时
--- 探针会立即返回（即便有命令在后台跑）；服务器卡死（协议失步/僵死）时探针同样超时。
--- @param inst table
--- @return Deferred resolve(boolean healthy)
local function _probe(inst)
  return _request(inst, "X", "true", { timeout_ms = 3000 }):then_(function(res)
    return res ~= nil and res.code == 0 and not res.timed_out and not res.aborted
  end, function()
    return false
  end)
end

--- 停止实例的进程与资源，但**保留 `state.instance`**（`alive=false` + `ensure_opts`），
--- 使下一次 `exec` 能据 `ensure_opts` 自动重建（与服务器意外退出同一恢复路径）。
--- @param inst table
--- @param timeout_ms number|nil jobwait 等待上限（默认 2000）
local function _kill_instance(inst, timeout_ms)
  if not inst then return end
  local wait_ms = math.max(0, tonumber(timeout_ms) or 2000)
  if inst.cg then pcall(cgroup.kill, inst.cg) end
  if inst.job and inst.job > 0 then
    pcall(vim.fn.jobstop, inst.job)
    pcall(vim.fn.jobwait, { inst.job }, wait_ms)
  end
  if inst.cg then pcall(cgroup.release, inst.cg) end
  if inst.deleg then pcall(cgroup.release_delegated, inst.deleg) end
  inst.job = nil
  inst.cg = nil
  inst.deleg = nil
  inst.alive = false
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
  if inst and inst.alive and inst.job and inst.job > 0
    and inst.priv_key == want_key then
    -- 跨轮次保活：会话轮换后仍复用同一实例（overlay/shell 目录为稳定路径），使后台进程
    -- 跨回合存活；仅权限档位变化、实例死亡或启动参数变化才重建。会话 id 仅用于记账。
    inst.session_id = session_id
    return inst
  end
  if inst then
    -- 有在途命令时不得重建：重建会 cgroup.kill 整个会话域，连带杀死在途编译/后台进程
    -- （表现为非 OOM 的 exit 137）。交回调用方回退一次性执行，保留在途命令与后台进程。
    if M.busy() then
      return nil, "RESIDENT_BUSY: 常驻实例有在途命令，暂不重建"
    end
    M.stop()
  end

  local specs = opts.specs or {}
  -- 首次：挂载前把工作区暂存物化进 upper（宿主侧写入安全）。
  local conflicts = candidate.materialize_overlay(specs)
  if conflicts and #conflicts > 0 then
    return nil, "SANDBOX_MATERIALIZE_TYPE_CONFLICT: " .. tostring(conflicts[1] and conflicts[1].real)
  end

  -- 委派一个可写 cgroup 子树 bind 到 /sys/fs/cgroup：
  --   * 嵌套 systemd --user 需要它来在沙箱内管理服务；
  --   * 普通命令也需要它，使 AI 能在沙箱内创建子 cgroup 并写 memory.max/cpu.max
  --     （cgroup v2 写隔离；否则 /sys/fs/cgroup 为只读）。
  -- 仅限委派子树，不污染宿主其它 cgroup；不可用时静默跳过（不阻断命令）。
  local sduser_mod = nil
  local deleg = nil
  local priv = opts.privileges
  do
    local ok, mod = pcall(require, "NeoAI.sandbox.systemd_user")
    local sd_ok = ok and mod and mod.available()
    -- 网关模式（ip netns exec）下委派 cgroup 的 bind 源不可解析，跳过（见 wrapper 同处说明）。
    local gateway_on = false
    do
      local okg, ng = pcall(require, "NeoAI.sandbox.net_gateway")
      gateway_on = okg and ng and ng.enabled()
    end
    if (sd_ok or cgroup.delegation_enabled()) and not gateway_on then
      local h, derr = cgroup.prepare_delegated("sess_" .. tostring(session_id), cgroup.resolve_limits())
      if h then
        deleg = h
        -- 仅**真实** systemd --user（needs_boot）需要注入 XDG/dbus 与引导片段；伪造解析器
        -- （systemd_user.fake）由门面处理 `systemctl --user`，不需要常驻用户实例。
        if sd_ok and mod.needs_boot and mod.needs_boot() then sduser_mod = mod end
        local p2 = {}
        for k, v in pairs(priv or {}) do p2[k] = v end
        local mounts = {}
        for _, m in ipairs((priv and priv.mounts) or {}) do mounts[#mounts + 1] = m end
        mounts[#mounts + 1] = { src = h.path, dst = "/sys/fs/cgroup", mode = "rw" }
        p2.mounts = mounts
        priv = p2
      else
        logger.warn("[sandbox:resident] 委派 cgroup 不可用，跳过：%s", tostring(derr))
      end
    end
  end

  local prefix, perr = runtime.process_prefix({
    cwd = opts.cwd, overlays = specs, fallback_cwd = opts.fallback_cwd,
    session_dir = opts.session_dir, session_tmp_dir = opts.session_tmp_dir,
    tmpfs_base = opts.tmpfs_base,
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

  -- 大文件物化收件箱：会话目录已 bind 进命名空间（沙箱内固定路径），宿主把大文件复制进
  -- 其 `.mat` 子目录后，只需向服务器发小帧令其在命名空间内复制，无需经 stdin 传输内容。
  local session_mount = nil
  if opts.session_dir then
    local okc, conceal = pcall(require, "NeoAI.sandbox.conceal")
    if okc and conceal and conceal.session_mount then session_mount = conceal.session_mount() end
  end
  inst = {
    session_id = session_id, specs = specs, cwd = opts.cwd, env = env,
    cg = cg_handle, deleg = deleg, alive = true, materialized = {}, seq = 0,
    buf = "", pendings = {}, block = nil, noise = nil, priv_key = want_key,
    session_dir = opts.session_dir, session_mount = session_mount,
    -- 保留启动参数：服务器意外退出（外层 OOM/被杀）时可据此自动重建并重试在途命令。
    ensure_opts = {
      specs = opts.specs, cwd = opts.cwd, privileges = opts.privileges,
      session_dir = opts.session_dir, session_tmp_dir = opts.session_tmp_dir,
      tmpfs_base = opts.tmpfs_base,
      fallback_cwd = opts.fallback_cwd,
    },
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
  _request(inst, "X", "true", { timeout_ms = health_ms }):then_(
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

--- 是否有在途命令（含物化请求）。重建/轮换前据此避免连带终止在途命令与后台进程。
--- @return boolean
function M.busy()
  local inst = state.instance
  if not (inst and inst.alive and inst.job and inst.job > 0) then return false end
  return next(inst.pendings or {}) ~= nil
end

--- 单文件内嵌上限（字节）：超过则改走收件箱按文件复制，避免超大帧经常驻 stdin
--- （bash `read` 逐字节读，数百 MB 内容会打满 CPU）。优先用常驻专属上限
--- `tools.sandbox.resident.max_embed_bytes`（默认 256KB，远低于候选冻结的 8MB），
--- 使更多大文件走复制、显著缩小每次物化帧；未配置时回退 `tools.sandbox.max_file_bytes`。
--- @return number
local function _max_embed_bytes()
  local n = tonumber(_cfg().max_embed_bytes)
  if n == nil then n = tonumber(config_store.get("tools.sandbox.max_file_bytes")) end
  if n == nil then return 8 * 1024 * 1024 end
  return n
end

--- 文件签名（mtime.sec:mtime.nsec:size:mode），与候选 `fresh_ssig` 格式一致。
--- @param path string
--- @return string|nil
local function _file_sig4(path)
  local st = vim.uv.fs_stat(path)
  if not (st and st.type == "file" and st.mtime) then return nil end
  return string.format("%s:%s:%s:%s",
    tostring(st.mtime.sec), tostring(st.mtime.nsec), tostring(st.size), tostring(st.mode))
end

--- 物化分块大小：每批最多条目数 / 载荷字节，批间 `vim.defer_fn` 让出主循环，
--- 避免一次性构建上百 MB 载荷长时间阻塞 nvim 主线程（UI 卡顿）。
local MAT_CHUNK_ENTRIES = 128
local MAT_CHUNK_BYTES = 1024 * 1024

--- 把 AI 尚未物化的暂存编辑在命名空间内写回沙箱视图（写走 overlay 挂载）。
--- 大文件（`large` 或超过内嵌上限）不内嵌内容：宿主侧复制进会话目录的收件箱
--- （已 bind 进命名空间），只发小帧令服务器在命名空间内 `cp`。分块构建/发送，批间让出主循环。
--- @return Deferred
function M.materialize()
  local inst = M.active()
  if not inst then return async.resolve() end
  local max_embed = _max_embed_bytes()
  local inbox_host = inst.session_dir and (inst.session_dir .. "/.mat") or nil
  local inbox_mount = inst.session_mount and (inst.session_mount .. "/.mat") or nil
  local token = tostring(vim.uv.hrtime())

  -- 主线程只做签名比较收集待物化条目；内容读取/base64 分块进行，批间让出。
  local pending = {}
  for _, o in ipairs(candidate.workspace_overrides()) do
    local sig = _sig(o)
    if inst.materialized[o.real] ~= sig then
      inst.materialized[o.real] = sig
      pending[#pending + 1] = o
    end
  end
  if #pending == 0 then return async.resolve() end

  local out = async.Deferred.new()

  --- 构建单条物化记录（追加到 lines；大文件复制进收件箱登记 created）。
  --- @return string|nil line 追加的行（nil 表示跳过）
  local function build_line(o, created)
    if o.deleted then
      return "d\t" .. vim.base64.encode(o.real)
    end
    if o.fresh_resident and o.fresh_ssig and _file_sig4(o.staged) == o.fresh_ssig then
      -- 命令在常驻 overlay 内执行（产物已在该 overlay），且暂存副本自命令后未再被编辑
      -- → 无需回写。避免每次命令后把上千个包产物重发一遍（实测可达近百 MB）。
      return nil
    end
    local st = vim.uv.fs_stat(o.staged)
    local is_file = st ~= nil and st.type == "file"
    local big = is_file
      and (o.large == true or (max_embed > 0 and (st.size or 0) > max_embed))
    if big then
      if not (inbox_host and inbox_mount) then
        logger.warn("[sandbox:resident] 无收件箱，跳过超大文件物化：%s", tostring(o.real))
        return nil
      end
      local name = token .. "_" .. tostring(#created) .. "_" .. vim.fn.sha256(o.real):sub(1, 16)
      local host_src = inbox_host .. "/" .. name
      fs.ensure_dir(inbox_host)
      if fs.copy_file(o.staged, host_src) then
        created[#created + 1] = host_src
        return "c\t" .. vim.base64.encode(o.real)
          .. "\t" .. vim.base64.encode(inbox_mount .. "/" .. name)
      end
      -- fail-closed：不内嵌超大内容（宁可该命令暂看不到此文件，也不撑爆 CPU）。
      logger.warn("[sandbox:resident] 大文件收件箱复制失败，跳过物化：%s", tostring(o.real))
      return nil
    elseif is_file then
      local content = fs.read_file(o.staged)
      if content == nil then
        return "D\t" .. vim.base64.encode(o.real)
      end
      return "w\t" .. vim.base64.encode(o.real) .. "\t" .. vim.base64.encode(content)
    end
    -- 目录（或非常规文件）：建目录。与原行为一致。
    return "D\t" .. vim.base64.encode(o.real)
  end

  local idx = 1
  local function step()
    if idx > #pending then out:resolve(true); return end
    local lines, created = {}, {}
    local bytes, n = 0, 0
    while idx <= #pending and n < MAT_CHUNK_ENTRIES and bytes < MAT_CHUNK_BYTES do
      local line = build_line(pending[idx], created)
      idx = idx + 1
      n = n + 1
      if line then
        lines[#lines + 1] = line
        bytes = bytes + #line
      end
    end
    if #lines == 0 then
      -- 本批无实际写入（全部跳过/失败）：让出后继续下一批。
      vim.defer_fn(step, 0)
      return
    end
    local payload = table.concat(lines, "\n") .. "\n"
    _request(inst, "M", payload, { timeout_ms = 120000 }):then_(function()
      for _, p in ipairs(created) do pcall(vim.uv.fs_unlink, p) end
      vim.defer_fn(step, 0) -- 批间让出主循环，避免长时间阻塞 UI
    end, function(e)
      for _, p in ipairs(created) do pcall(vim.uv.fs_unlink, p) end
      out:reject(e)
    end)
  end
  step()
  return out
end

--- 在常驻沙箱内执行一条命令。
--- @param command string
--- @param opts table { cwd?, timeout_ms?, signal? }
--- @return Deferred
function M.exec(command, opts)
  opts = opts or {}
  local inst = M.active()
  if not inst then
    -- 服务器已在上一轮意外退出（外层 OOM / 被信号杀死）：用保留的启动参数重建，避免把
    -- 服务器崩溃误报为「实例不可用」而交回一次性执行（后台进程/会话状态随之丢失）。
    local last = state.instance
    if last and last.ensure_opts then
      local restarted = M.ensure(last.ensure_opts)
      if restarted then inst = restarted end
    end
  end
  if not inst then
    return async.reject({ kind = "sandbox", message = "常驻沙箱实例不可用" })
  end
  local out = async.Deferred.new()

  local function _run_on(cur)
    -- 会话级资源域跨命令复用：记录命令开始时的 OOM 计数基线，结束后差分归因。
    local cg_baseline = nil
    if cur.cg and cur.cg.path and cgroup.oom_baseline then
      pcall(function() cg_baseline = cgroup.oom_baseline(cur.cg.path) end)
    end
    return M.materialize():then_(function()
      return _request(cur, "X", command, opts)
    end):then_(function(res)
      return { res = res, cur = cur, cg_baseline = cg_baseline }
    end)
  end

  local retried = false
  local function attempt(cur)
    return _run_on(cur):then_(function(ctx)
      local res, c = ctx.res, ctx.cur
      -- 服务器意外退出（非超时/取消，且实例已不存活）：重建并重试一次，避免把瞬时服务器
      -- 崩溃误报为命令失败（退出码 -1、无输出），与「重试即成功」的观测一致。
      if (not retried) and (not c.alive) and res.code == -1
        and not res.timed_out and not res.aborted and c.ensure_opts then
        retried = true
        local restarted = M.ensure(c.ensure_opts)
        if restarted then return attempt(restarted) end
      end
      return ctx
    end)
  end

  attempt(inst):then_(function(ctx)
    local res, c = ctx.res, ctx.cur
    local cfg_rc = config_store.get("tools.run_command") or {}
    local max_out = tonumber(cfg_rc.max_output_bytes) or 0
    local stdout = res.stdout or ""
    local truncated = false
    if max_out > 0 and #stdout > max_out then
      stdout = stdout:sub(1, max_out)
      truncated = true
    end
    local oom, oom_level = false, nil
    if c.cg and c.cg.path and (res.code == 137 or res.code == -1) then
      if cgroup.oom_attribution then
        local attr = cgroup.oom_attribution(c.cg.path, { baseline = ctx.cg_baseline })
        oom, oom_level = attr.oom, attr.level
      else
        oom = cgroup.snapshot_oom(cgroup.events_snapshot(c.cg.path))
      end
    end
    -- 命令超时后主动探活：服务器忙（命令仍在后台并发执行）时读取循环空闲，探针会立即返回，
    -- 从而**保留实例与后台进程**；仅当服务器卡死（协议失步/僵死）时探针也超时，才判定实例
    -- 不可用并停止，下一次 exec 重建——避免「一个卡死实例让后续所有命令永久超时」。
    if res.timed_out and state.instance == c then
      local healthy = false
      _probe(c):then_(function(ok) healthy = ok end, function() healthy = false end)
      vim.wait(5000, function() return healthy or not c.alive end, 20)
      if not healthy and state.instance == c then
        -- 保留 state.instance（alive=false + ensure_opts），下一次 exec 自动重建。
        _kill_instance(c)
      end
    end
    out:resolve({
      code = res.code, stdout = stdout, stderr = "", truncated = truncated,
      oom = oom, oom_level = oom_level,
      timed_out = res.timed_out, aborted = res.aborted, message = res.message,
    })
  end, function(e) out:reject(e) end)
  return out
end

--- 发布/拒绝后把真实盘内容同步进常驻 overlay（overlay lower 在挂载后变更不可靠可见，
--- 删除 upper 条目会回退到过期的 lower，故必须把真实内容写回 upper）。对文件写内容，
--- 目录建目录，不存在则删除 upper 条目。经命名空间内 `M` 帧执行。
--- @param paths table 规范化真实路径数组
function M.sync_real(paths)
  local inst = M.active()
  if not inst then return end
  local max_embed = _max_embed_bytes()
  local lines = {}
  for _, p in ipairs(paths or {}) do
    if type(p) == "string" and p ~= "" then
      inst.materialized[p] = nil
      local st = vim.uv.fs_lstat(p)
      if st == nil then
        lines[#lines + 1] = "d\t" .. vim.base64.encode(p)
      elseif st.type == "file" then
        local content = fs.read_file(p)
        if content ~= nil and (max_embed <= 0 or #content <= max_embed) then
          lines[#lines + 1] = "w\t" .. vim.base64.encode(p) .. "\t" .. vim.base64.encode(content)
        end
      elseif st.type == "directory" then
        lines[#lines + 1] = "D\t" .. vim.base64.encode(p)
      end
    end
  end
  if #lines == 0 then return end
  _request(inst, "M", table.concat(lines, "\n") .. "\n", { timeout_ms = 120000 })
end

--- 兼容别名（旧调用方）
function M.invalidate_paths(paths)
  return M.sync_real(paths)
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
  _kill_instance(inst, opts.timeout_ms)
end

--- 重置（测试用）
function M.reset()
  M.stop({ timeout_ms = 2000 })
  state.instance = nil
end

-- 测试钩子：暴露服务器脚本（不改变运行时行为）。
M._server_script = _server_script

return M
