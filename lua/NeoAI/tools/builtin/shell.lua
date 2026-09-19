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
  local d = async.Deferred.new()
  local stdout_chunks = {}
  local stderr_chunks = {}
  local done = false
  local job
  local timeout_ms = opts.timeout_ms or 30000

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

  if opts.signal then
    unsub = opts.signal:subscribe(function(reason)
      if job then pcall(vim.fn.jobstop, job) end
      local out, errout = snapshot()
      settle({ code = -1, stdout = out, stderr = errout, aborted = true, message = reason })
    end)
  end

  if timeout_ms > 0 then
    vim.defer_fn(function()
      if done then return end
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
      if data and #data > 0 then
        stdout_chunks[#stdout_chunks + 1] = table.concat(data, "\n")
      end
    end,
    on_stderr = function(_, data)
      if data and #data > 0 then
        stderr_chunks[#stderr_chunks + 1] = table.concat(data, "\n")
      end
    end,
    on_exit = function(_, code)
      local out, errout = snapshot()
      settle({ code = code, stdout = out, stderr = errout })
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

-- ========== 工具定义 ==========

local shell_tools = {}

shell_tools.run_command = helpers.define_tool(
  "run_command",
  "执行 Shell 命令。command 必填。timeout_ms 可选（默认 30000，-1 为不限）。",
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
    }):then_(function(result)
      -- 供沙箱门禁做权限不足检测（自动提权）：保留原始 {code,stdout,stderr}。
      if ctx then ctx.sandbox_last_result = result end
      -- 输出脱敏：抹去 bwrap/overlay/沙箱自有路径等指纹，使 AI 的外部命令难以识别沙箱。
      -- 大输出（MB 级、十余次 gsub）在 utils.work 线程池执行，避免完成瞬间占满主线程。
      return conceal.redact_async(result.stdout or ""):then_(function(out)
        return conceal.redact_async(result.stderr or ""):then_(function(errout)
          local text
          if result.aborted then
            -- 取消/超时/非零退出都回传已产生的终端内容，模型仍能看到当前进度
            text = _with_status("命令已取消：" .. tostring(result.message or "cancelled"), out, errout)
          elseif result.timed_out then
            text = _with_status("命令执行超时", out, errout)
          elseif result.code == 0 then
            text = out ~= "" and out or "（无输出）"
          else
            text = _with_status(string.format("命令退出码 %d", result.code), out, errout)
          end
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
          if result.aborted or result.timed_out or (result.code ~= 0) then
            local reason
            if result.aborted then
              reason = "命令已取消：" .. tostring(result.message or "cancelled")
            elseif result.timed_out then
              reason = "命令执行超时"
            else
              reason = "命令退出码 " .. tostring(result.code)
            end
            on_success(require("NeoAI.utils.json").encode({ error = reason, output = text }))
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
