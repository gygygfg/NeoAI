--- Shell 命令工具
--- @module NeoAI.tools.builtin.shell
--- 执行 Shell 命令（异步，非交互）。交互式 PTY 见阶段8 ui/components。

local async = require("NeoAI.utils.async")
local helpers = require("NeoAI.tools.builtin.tool_helpers")
local conceal = require("NeoAI.sandbox.conceal")
local secret = require("NeoAI.sandbox.secret")

local M = {}

-- 降级视图提示：overlay 不可用时命令运行在会话私有 cwd，看不到真实项目文件（仅暂存改动），
-- 与真实磁盘视图不一致。**仅用户可见**：挂到 ctx.ui_notice，由 tool_loop 作为工具结果的 UI
-- 附加元数据展示，不写入模型可见的结果内容（避免把「看不到」误判为「文件不存在/改动未生效」，
-- 也不让模型感知沙箱状态）。
local DEGRADED_NOTE = "[NeoAI] 注意：沙箱以降级模式运行（overlay 不可用），命令工作目录为"
  .. "会话私有视图，可能不含真实磁盘上的其他文件；请用 read_file/search_files 核对。"

-- 特权档（T2，嵌套 userns）专用提示：该档天然无 overlay（属有意设计，主机效果冻结为提案），
-- 并非「overlay 不可用」的降级，故用专门文案，避免误导用户以为沙箱异常。仅用户可见
-- （挂 ctx.ui_notice，不写入模型可见结果）。
local PRIVILEGED_NOTE = "[NeoAI] 提示：本次命令以特权档（T2）在嵌套命名空间内执行，工作目录为"
  .. "会话私有视图，可能不含真实磁盘上的其他文件；其主机效果将冻结为提案待审。"

-- ========== 私有函数 ==========

--- 为 argv 前置沙箱运行时前缀（隔离执行）
--- @param argv table
--- @param opts table { prefix?: table }
--- @return table
local function _sandboxed_argv(argv, opts)
  if not (opts and opts.prefix and #opts.prefix > 0) then return argv end
  local full = {}
  for _, v in ipairs(opts.prefix) do full[#full + 1] = v end
  for _, v in ipairs(argv) do full[#full + 1] = v end
  return full
end

--- 选择 shell 解释器：优先 bash（支持 PIPESTATUS、[[ ]]、数组等 bash 语法），
--- 不可用时回退 POSIX sh。沙箱只读根暴露宿主 /，故宿主有 bash 时沙箱内亦可用。
--- @return string
local function _shell_bin()
  return vim.fn.executable("bash") == 1 and "bash" or "sh"
end

--- 执行 shell 命令（jobstart，实时累积 stdout/stderr）。
--- 采用非缓冲输出：命令超时/被取消时也能回传「此刻终端已产生的内容」，
--- 而不是只剩一句错误信息。始终 resolve 结果表（含 timed_out/aborted 标记），
--- 由调用方决定如何呈现；只有进程无法启动才 reject。
--- @param command string
--- @param opts table { timeout_ms?, signal? }
--- @return Deferred resolve({ code, stdout, stderr, timed_out?, aborted?, message? })
local function _run_command(command, opts)
  opts = opts or {}
  -- 出网密钥守卫：命令含密钥（真实值或将被还原的假密钥）且指向非白名单地址时弹窗阻止。
  if not opts._egress_checked then
    local guard = require("NeoAI.sandbox.secret_egress").guard_process(command, opts.env, { tool = "run_command" })
    if guard then
      local opts2 = vim.tbl_extend("force", {}, opts)
      opts2._egress_checked = true
      return guard:then_(function() return _run_command(command, opts2) end)
    end
  end
  -- 常驻沙箱：命令经 nsenter 进入会话级共享命名空间执行（后台进程跨调用存活）。
  if opts.resident then
    return require("NeoAI.sandbox.resident").exec(command, {
      timeout_ms = opts.timeout_ms, signal = opts.signal, cwd = opts.cwd,
    })
  end
  local d = async.Deferred.new()
  local stdout_chunks = {}
  local stderr_chunks = {}
  local done = false
  local job
  local cfg_rc = require("NeoAI.kernel.config_store").get("tools.run_command") or {}
  local timeout_ms = opts.timeout_ms or 30000
  -- 墙钟安全网：max_wall_ms>0 时约束所有命令（含 timeout_ms=-1 的「不限」），避免永久运行。
  local max_wall = tonumber(cfg_rc.max_wall_ms) or 0
  if max_wall > 0 and (timeout_ms < 0 or timeout_ms > max_wall) then timeout_ms = max_wall end
  -- 沙箱门禁提供的进程树终止回调（cgroup.kill）：bwrap 载荷在独立 pid 命名空间内，
  -- 仅 jobstop 外层 bwrap 可能杀不掉载荷；取消/超时/截断时优先按资源域精确终止。
  local kill = opts.kill
  -- 资源域路径（诊断/归因）：命令以 SIGKILL（137）结束时读取 cgroup 事件判定是否 OOM。
  local cgroup_path = opts.cgroup_path
  -- 命令开始时的祖先 OOM 计数基线：结束后差分，避免把命令前已存在的祖先 OOM 误判为本次。
  local cgroup_baseline = nil
  if cgroup_path then
    local ok_cg, cg = pcall(require, "NeoAI.sandbox.cgroup")
    if ok_cg and cg and cg.oom_baseline then
      pcall(function() cgroup_baseline = cg.oom_baseline(cgroup_path) end)
    end
  end
  local max_out = tonumber(cfg_rc.max_output_bytes) or 0
  local out_bytes, err_bytes = 0, 0
  local truncated = false

  local function snapshot()
    return table.concat(stdout_chunks), table.concat(stderr_chunks)
  end

  local unsub = function() end

  local function settle(result)
    if done then return end
    done = true
    unsub()
    d:resolve(result)
  end

  --- 追加一块输出；超过 max_out 时截断并终止命令（避免超大输出冻结主线程）。
  --- @param chunks table
  --- @param data table
  --- @param which string "out" | "err"
  local function append(chunks, data, which)
    if done or not data or #data == 0 then return end
    local s = table.concat(data, "\n")
    local used = (which == "out") and out_bytes or err_bytes
    if max_out > 0 and used + #s > max_out then
      s = s:sub(1, math.max(0, max_out - used))
      chunks[#chunks + 1] = s
      if which == "out" then out_bytes = max_out else err_bytes = max_out end
      if not truncated then
        truncated = true
        if kill then pcall(kill) end
        if job then pcall(vim.fn.jobstop, job) end
      end
      return
    end
    chunks[#chunks + 1] = s
    if which == "out" then out_bytes = used + #s else err_bytes = used + #s end
  end

  if opts.signal then
    unsub = opts.signal:subscribe(function(reason)
      if kill then pcall(kill) end
      if job then pcall(vim.fn.jobstop, job) end
      local out, errout = snapshot()
      settle({ code = -1, stdout = out, stderr = errout, aborted = true, message = reason })
    end)
  end

  if timeout_ms > 0 then
    vim.defer_fn(function()
      if done then return end
      if kill then pcall(kill) end
      if job then pcall(vim.fn.jobstop, job) end
      local out, errout = snapshot()
      settle({ code = -1, stdout = out, stderr = errout, timed_out = true })
    end, timeout_ms)
  end

  job = vim.fn.jobstart(_sandboxed_argv({ _shell_bin(), "-c", command }, opts), {
    cwd = opts.cwd,
    -- 环境变量脱敏 + 宿主运行时直通；优先使用门禁预构造的沙箱环境（含档位 env/PATH）。
    env = opts.env or secret.sanitized_env(),
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      append(stdout_chunks, data, "out")
    end,
    on_stderr = function(_, data)
      append(stderr_chunks, data, "err")
    end,
    on_exit = function(_, code)
      local out, errout = snapshot()
      local oom, oom_level = false, nil
      -- 137（SIGKILL）与裸 -1（无超时/取消标记、进程树被终止后无法回传退出码）都做 OOM 归因。
      if cgroup_path and (code == 137 or code == -1) then
        local ok, cgroup = pcall(require, "NeoAI.sandbox.cgroup")
        if ok and cgroup then
          if cgroup.oom_attribution then
            local attr = cgroup.oom_attribution(cgroup_path, { baseline = cgroup_baseline })
            oom, oom_level = attr.oom, attr.level
          else
            oom = cgroup.snapshot_oom(cgroup.events_snapshot(cgroup_path))
          end
        end
      end
      settle({ code = code, stdout = out, stderr = errout, truncated = truncated,
        oom = oom, oom_level = oom_level })
    end,
  })

  if job <= 0 then
    done = true
    return async.reject({ kind = "shell", message = "无法启动 shell 进程" })
  end
  return d
end

--- 会话级 shell 状态持久化包装。
--- 每个 run_command 是独立进程/独立 shell，export/cd 默认不保留；通过在命令前后
--- 载入/保存「cwd + 导出变量」到会话状态文件，使同一 agent 循环内状态跨命令保留。
--- @param command string
--- @param state_dir string 沙箱内会话状态目录（已 bind 到宿主会话目录）
--- @return string
local function _wrap_session_command(command, state_dir)
  return table.concat({
    "_sd='" .. state_dir .. "'",
    'if [ -f "$_sd/env" ]; then . "$_sd/env"; fi',
    'if [ -f "$_sd/cwd" ]; then cd "$(cat "$_sd/cwd")" 2>/dev/null || true; fi',
    command,
    "_rc=$?",
    'pwd > "$_sd/cwd" 2>/dev/null',
    'export -p > "$_sd/env" 2>/dev/null',
    "exit $_rc",
  }, "\n")
end

--- 组合「状态行 + 已产生的终端输出」，错误路径也保留输出内容
--- @param status string
--- @param out string
--- @param errout string
--- @return string
local function _with_status(status, out, errout)
  local parts = { status }
  if out and out ~= "" then parts[#parts + 1] = out end
  if errout and errout ~= "" then parts[#parts + 1] = errout end
  if #parts == 1 then parts[#parts + 1] = "（无输出）" end
  return table.concat(parts, "\n")
end

--- 环境不匹配提示：容器内无 systemd 时，命令尝试 systemctl/service 会失败。
--- 反应式注入（仅在输出命中相关特征时），不暴露沙箱实现。
--- 启用 systemd 门面时，独立的**及**复合/管道/脚本内的 `systemctl`/`journalctl` 都由沙箱门面
--- （`/usr/bin/systemctl` 极薄入口 → 宿主 Lua）处理，不会再命中真实二进制报「无法连接总线」；
--- 且门面把 `/proc/1` 呈现为 systemd。此时再附加「PID1 非 systemd」的提示会与沙箱内视图
--- 自相矛盾，故**不注入**该提示。仅门面禁用时才说明环境无 systemd。
--- @param text string
--- @return string
local function _env_hint(text)
  if type(text) ~= "string" or text == "" then return text end
  local hit = text:find("System has not been booted with systemd", 1, true)
    or text:find("Failed to connect to bus", 1, true)
    or text:find("systemctl: command not found", 1, true)
    or text:find("systemctl: not found", 1, true)
  if not hit then return text end
  local facade = false
  local ok_cfg, cfg = pcall(function()
    return require("NeoAI.kernel.config_store").get("tools.sandbox.systemd")
  end)
  if ok_cfg and type(cfg) == "table" and cfg.enabled ~= false then facade = true end
  if facade then return text end
  local msg = "[环境提示] 当前环境无 systemd（PID1 非 systemd）。"
    .. "请直接运行前台命令，或改用进程管理/容器方式。"
  return text .. "\n\n" .. msg
end

-- ========== 工具定义 ==========

local shell_tools = {}

shell_tools.run_command = helpers.define_tool(
  "run_command",
  "执行 Shell 命令（前台，单次调用内完成）。command 必填。timeout_ms 可选（默认 30000ms，-1 为不限）。"
  .. "长任务（安装依赖/编译/下载）请在**同一次调用**内显式传较大的 timeout_ms（如 600000），"
  .. "不要靠重试短命令规避超时。以 `&`/nohup/setsid 启动的后台进程，仅在会话使用常驻沙箱时"
  .. "跨工具调用**且跨轮次**持续运行（可用 ps/kill 管理）；否则命令结束即被回收，其输出建议重定向到文件。",
  {
    type = "object",
    properties = {
      command = { type = "string", description = "要执行的 shell 命令" },
      timeout_ms = { type = "integer", description = "超时毫秒数" },
    },
    required = { "command" },
  },
  function(args, on_success, on_error, ctx)
    -- 沙箱门禁已把命令参数中的 token 还原为真实密钥（仅沙箱内部进程可见）；
    -- 优先使用它，`args.command`（UI/证据）仍保留 token。
    local command = (ctx and ctx.sandbox_command) or args.command
    local signal = ctx and ctx.signal
    -- 后台意图提示：常驻实例可用时后台进程跨调用存活；否则命令在一次性 pid 命名空间 +
    -- 资源域内运行，命令结束即 `cgroup.kill` 回收整个进程树，后台进程不会存活。明确告知
    -- 用户（仅 UI，不写入模型可见结果），避免误以为后台任务仍在运行。
    if ctx and not ctx.sandbox_resident then
      local bg = require("NeoAI.sandbox.background").parse(command)
      if bg then
        ctx.ui_notice = "[NeoAI] 注意：本次命令请求后台执行（`&`/nohup/setsid），但当前会话未使用"
          .. "常驻沙箱（如 overlay 不可用或特权档），命令结束后后台进程会被回收，不会跨调用存活。"
          .. "请改用前台命令，或在同一次调用内完成长任务。"
      end
    end
    -- 代理策略：默认不把宿主代理（如不可达的 127.0.0.1:7890）传入沙箱，
    -- 避免 pip/npm 等按代理配置走网络时 Connection refused；仅 opencode 自身用代理。
    local unset_proxy = require("NeoAI.sandbox.runtime").proxy_unset_snippet()
    if unset_proxy then command = unset_proxy .. "\n" .. command end
    if ctx and ctx.sandbox_shell_state then
      command = _wrap_session_command(command, ctx.sandbox_shell_state)
    end
    -- 丢弃上一条命令遗留的网关探测记录，确保摘要只反映本次命令。
    local ok_gw0, gw0 = pcall(require, "NeoAI.sandbox.gateway")
    if ok_gw0 and gw0 then gw0.drain_probes() end
    _run_command(command, {
      timeout_ms = args.timeout_ms,
      signal = signal,
      prefix = ctx and ctx.sandbox_prefix,
      cwd = ctx and ctx.sandbox_cwd,
      env = ctx and ctx.sandbox_env,
      kill = ctx and ctx.sandbox_kill,
      cgroup_path = ctx and ctx.sandbox_cgroup_path,
      resident = ctx and ctx.sandbox_resident,
    }):then_(function(result)
      -- 供沙箱门禁做权限不足检测（自动提权）：保留原始 {code,stdout,stderr}。
      if ctx then ctx.sandbox_last_result = result end
      -- 输出脱敏：抹去 bwrap/overlay/沙箱自有路径等指纹，使 AI 的外部命令难以识别沙箱。
      -- 大输出（MB 级、十余次 gsub）在 utils.work 线程池执行，避免完成瞬间占满主线程。
      return conceal.redact_async(result.stdout or ""):then_(function(out)
        return conceal.redact_async(result.stderr or ""):then_(function(errout)
          local text
          if result.truncated then
            -- 输出超过上限：命令已被终止，已产生内容仍回传并标注截断。
            text = _with_status(
              string.format("输出超过 %d 字节上限，已截断并终止命令",
                tonumber(require("NeoAI.kernel.config_store").get("tools.run_command.max_output_bytes")) or 0),
              out, errout)
          elseif result.aborted then
            -- 取消/超时/非零退出都回传已产生的终端内容，模型仍能看到当前进度
            text = _with_status("命令已取消：" .. tostring(result.message or "cancelled"), out, errout)
          elseif result.timed_out then
            text = _with_status("命令执行超时", out, errout)
          elseif result.oom then
            -- 资源域 OOM：命令被 SIGKILL（137），memory.events 出现 oom_kill 增量。
            local where = (result.oom_level == "sandbox")
              and "沙箱资源域内存不足" or "容器/宿主内存不足（外层 cgroup OOM）"
            text = _with_status(
              "命令被终止（疑似内存超限 OOM）：" .. where .. "，命令进程被内核杀死。"
              .. "请减小并发/单次任务内存占用，或在 tools.sandbox.limits 调高 memory_bytes/memory_ratio"
              .. "（容器场景还受外层 cgroup 限制）后重试",
              out, errout)
          elseif result.code == 137 then
            -- 非超时/取消/截断的 137：SIGKILL 来源不明（资源域终止、宿主 OOM 或外部信号）。
            local diag = ""
            if cgroup_path then
              local ok_cg, cg = pcall(require, "NeoAI.sandbox.cgroup")
              if ok_cg and cg and cg.events_snapshot then
                local snap = cg.events_snapshot(cgroup_path) or {}
                local parts = {}
                if snap.memory_peak then parts[#parts + 1] = "memory.peak=" .. snap.memory_peak end
                if snap.memory_max then parts[#parts + 1] = "memory.max=" .. snap.memory_max end
                if snap.memory_events then parts[#parts + 1] = "memory.events={" .. snap.memory_events:gsub("%s+", ",") .. "}" end
                if snap.pids_events then parts[#parts + 1] = "pids.events={" .. snap.pids_events:gsub("%s+", ",") .. "}" end
                if #parts > 0 then diag = "\n资源域事件：" .. table.concat(parts, " ") end
              end
            end
            text = _with_status(
              "命令被强制终止（退出码 137 / SIGKILL）：非超时或取消所致，且未定位到资源域 OOM 事件。"
              .. "常见原因：宿主/容器内存不足触发 OOM、资源域被终止，或命令/其后台子进程被外部信号杀死。"
              .. "可开启 tools.sandbox.diagnostics.enabled 查看资源域事件" .. diag,
              out, errout)
          elseif result.code == 0 then
            text = out ~= "" and out or "（无输出）"
          elseif result.code == 127 then
            text = _with_status(
              "命令未找到（退出码 127）：可执行文件不在 PATH 中。若刚激活了虚拟环境，请确认其 "
              .. "bin 目录与解释器符号链接在沙箱内可达（tools.sandbox.read_all=true，或用 "
              .. "tools.sandbox.expose_paths 暴露解释器目录），也可用 `command -v <cmd>` 定位。",
              out, errout)
          else
            text = _with_status(string.format("命令退出码 %d", result.code), out, errout)
          end
          text = _env_hint(text)
          if ctx and ctx.sandbox_userns then
            -- 特权档（T2）：嵌套 userns 天然无 overlay，属有意设计，显示专用提示而非降级告警。
            ctx.ui_notice = PRIVILEGED_NOTE
          elseif ctx and ctx.sandbox_degraded then
            -- 降级提示仅面向用户：挂到 ctx.ui_notice，由 tool_loop 作为工具结果的 UI 附加
            -- 元数据展示，**不写入模型可见的结果文本**。
            local note = DEGRADED_NOTE
            if ctx.sandbox_degraded_reason and ctx.sandbox_degraded_reason ~= "" then
              note = note .. "（overlay 不可用原因：" .. tostring(ctx.sandbox_degraded_reason) .. "）"
            end
            ctx.ui_notice = note
          end
          -- 网络网关模式：把本次命令经网关探测到的宿主端口及拦截原因回传给 AI。
          local ok_gw, gw = pcall(require, "NeoAI.sandbox.gateway")
          if ok_gw and gw then
            local s = gw.summary()
            if s then text = text .. "\n\n" .. s end
          end
          -- 本机访问拦截代理：回传本次经代理放行/拦截的目标摘要（应用层）。
          local ok_hp, hp = pcall(require, "NeoAI.sandbox.host_proxy")
          if ok_hp and hp then
            local s = hp.summary()
            if s then text = text .. "\n\n" .. s end
          end
          -- 非零退出码 / 取消 / 超时视为失败：以结构化结果 resolve（含 error 字段）——
          -- UI 据此显示 ❌；同时仍 resolve（而非 reject）以保留沙箱门禁的权限升级检测与候选冻结。
          -- 输出截断导致的终止不算失败（命令本身可能已成功，只是输出过多）。
          if (not result.truncated) and (result.aborted or result.timed_out or (result.code ~= 0)) then
            local reason
            if result.aborted then
              reason = "命令已取消：" .. tostring(result.message or "cancelled")
            elseif result.timed_out then
              reason = "命令执行超时"
            elseif result.oom then
              reason = "命令被终止（疑似内存超限 OOM"
                .. (result.oom_level == "ancestor" and "，容器/宿主内存不足" or "") .. "）"
            elseif result.code == 137 then
              reason = "命令被强制终止（退出码 137 / SIGKILL）"
            else
              reason = "命令退出码 " .. tostring(result.code)
            end
            -- 显式机器可读的失败标记（ok=false + 退出码），避免下游把「无 rc 字段的伪 JSON」
            -- 当作 rc=0/成功（失败开放）。仍 resolve 以保留沙箱门禁的候选冻结与提权检测。
            on_success(require("NeoAI.utils.json").encode({
              error = reason,
              output = text,
              ok = false,
              exit_code = tonumber(result.code) or -1,
              timed_out = result.timed_out or false,
              aborted = result.aborted or false,
            }))
          else
            on_success(text)
          end
        end)
      end)
    end, function(err)
      on_error(conceal.redact(err.message or tostring(err)))
    end)
  end,
  { category = "system", approval = { auto_allow = false }, timeout = -1 }
)

--- 获取工具列表
--- @return table 数组
function M.get_tools()
  local out = {}
  for _, tool in pairs(shell_tools) do
    out[#out + 1] = tool
  end
  return out
end

return M
