--- 工具执行器
--- @module NeoAI.tools.executor
--- 参数规范化 + 校验 + 审批 + 执行（异步）+ 超时。
--- 执行结果统一转为字符串（供 Agent 回传）。

local async = require("NeoAI.utils.async")
local tool_timer = require("NeoAI.utils.timer")
local json = require("NeoAI.utils.json")
local registry = require("NeoAI.tools.registry")
local validator = require("NeoAI.tools.validator")
local config_store = require("NeoAI.kernel.config_store")
local fs = require("NeoAI.utils.fs")
local secret = require("NeoAI.sandbox.secret")
local tool_spec = require("NeoAI.sandbox.tool_spec")

local M = {}

-- ========== 私有函数 ==========

--- 工具参数命中的首个遮蔽目录条目（供弹窗审批与 fail-closed）。未命中/未开启返回 nil。
--- 覆盖显式路径参数（tool_spec.paths）与 run_command 命令串中的绝对路径。
--- 返回值第二项 `hard=true` 表示命中**宿主敏感遮蔽路径**（mask_paths/沙箱存储）：
--- 进程内 read/fs_write 不经 namespace，mount 遮蔽无效，必须硬拒绝（不可审批放行）。
--- @param tool_name string
--- @param args table
--- @return string|nil mask_entry
--- @return boolean hard
local function _masked_target(tool_name, args)
  local runtime = require("NeoAI.sandbox.runtime")
  local cwd = vim.fn.getcwd()
  local spec = tool_spec.get(tool_name)
  for _, field in ipairs(spec.paths or {}) do
    local p = args and args[field]
    if type(p) == "string" and p ~= "" then
      local abs = vim.fn.fnamemodify(p, ":p")
      -- 先判宿主敏感遮蔽路径（mask_paths/沙箱存储，硬拒绝），再判遮蔽目录（mask_dirs，可审批）。
      -- 二者可能重叠（如 /root/.ssh 既在 mask_paths 又位于遮蔽目录 /root 下）；若先判
      -- mask_dirs，软命中会遮蔽硬命中，使非进程内 fs 工具（如 read_image）在无审批界面时放行。
      local masked = runtime.is_masked_path(abs)
      if masked then return masked, true end
      local hit = runtime.mask_entry(abs, cwd)
      if hit then return hit end
    end
  end
  if not runtime.mask_dirs_enabled() then return nil end
  local cmd = args and args.command
  if type(cmd) == "string" and cmd ~= "" then
    for _, d in ipairs(runtime.mask_dirs()) do
      local init = 1
      while true do
        local s, e = cmd:find(d .. "/", init, true)
        if not s then break end
        local e2 = e
        while e2 < #cmd and cmd:sub(e2 + 1, e2 + 1):match("[%w%._%-/]") do e2 = e2 + 1 end
        local hit = runtime.mask_entry(cmd:sub(s, e2), cwd)
        if hit then return hit end
        init = e + 1
      end
    end
  end
  return nil
end

--- 越界访问留痕（非阻塞）：`read_all` 下记录访问 cwd 之外用户工作目录（home/root 等）的
--- 工具调用，写入证据 + 事件，供审批悬浮窗展示。系统路径（/usr、/etc 等）不计入。
--- @param tool_name string
--- @param args table
--- @param ctx table
local function _trace_outside_access(tool_name, args, ctx)
  local ok, runtime = pcall(require, "NeoAI.sandbox.runtime")
  if not ok or not runtime.read_all() then return end
  local ok2, trace = pcall(require, "NeoAI.sandbox.trace")
  if not ok2 then return end
  local cwd = vim.fn.getcwd()
  local spec = tool_spec.get(tool_name)
  local seen = {}
  local function consider(p, command)
    if type(p) ~= "string" or p == "" then return end
    local hit = runtime.outside_workspace(p, cwd)
    if hit and not seen[hit] then
      seen[hit] = true
      trace.record({
        path = hit, tool = tool_name, kind = "read", command = command,
        source = (ctx and ctx.is_sub_agent) and "sub_agent" or "observed",
      })
    end
  end
  for _, field in ipairs(spec.paths or {}) do consider(args and args[field]) end
  -- 进程命令：扫描命令串中的绝对路径 token（启发式，仍非阻塞放行）。
  local cmd = args and (args.command or args.cmd)
  if type(cmd) == "string" then
    for tok in cmd:gmatch("%S+") do
      local p = tok:gsub("^['\"]", ""):gsub("['\"]$", "")
      if p:sub(1, 1) == "/" then consider(p, cmd) end
    end
  end
end

--- 参数别名规范化
--- @param tool_name string
--- @param args table
--- @return table 规范化后的参数
local function _normalize_arguments(tool_name, args)
  if type(args) ~= "table" then
    -- 简单字符串参数：转成 filepath（针对 read_file 等）
    if tool_name == "read_file" or tool_name == "edit_file" or tool_name == "delete_file" then
      return { filepath = tostring(args) }
    end
    return {}
  end
  local normalized = vim.deepcopy(args)
  local aliases = {
    cmd = "command", file = "filepath", files = "filepath",
    start = "start_line", ["end"] = "end_line",
    dir = "dirs", dir_path = "dirs", dirs = "dirs",
    -- 注意：不要给 new_text/text 起 content 别名——那会把「局部替换」误判成「整文件覆写」，
    -- 曾导致 edit_file 静默覆写整文件（详见 file_ops.edit_file 的参数契约）。
  }
  for k, target in pairs(aliases) do
    if normalized[k] ~= nil and normalized[target] == nil then
      normalized[target] = normalized[k]
      normalized[k] = nil
    end
  end
  return normalized
end

-- 携带路径语义的参数名：进入工具前展开 ~ / $VAR（与内容/文本类参数区分开，
-- 避免把 description/content/query 等误当成路径）。
local PATH_KEYS = { "path", "filepath", "file_path", "dirs", "dir" }

--- 展开参数中路径型字段的 ~ 别名，使 ~/... 等相对主目录的路径可正常读写
--- @param args table
--- @return table
local function _expand_path_args(args)
  if type(args) ~= "table" then return args end
  for _, k in ipairs(PATH_KEYS) do
    if type(args[k]) == "string" then
      args[k] = fs.expand(args[k])
    end
  end
  return args
end

--- 统一执行工具函数
--- 支持三种形式：tool.func(...) / tool.execute(ctx) / 同步或异步回调
--- @param tool table
--- @param args table
--- @param ctx table { agent, tool_call_id, signal, is_sub_agent }
--- @return Deferred resolve(结果)
local function _call_tool(tool, args, ctx)
  local d = async.Deferred.new()
  local done = false
  local function finish(ok, value)
    if done then return end
    done = true
    if ok then
      d:resolve(value)
    else
      d:reject(value)
    end
  end

  local function on_success(result)
    finish(true, result)
  end
  local function on_error(err)
    finish(false, err)
  end

  local ok, err
  if tool.func then
    -- 回调风格：func(args, on_success, on_error)
    local arity = debug.getinfo(tool.func).nparams
    if arity >= 2 then
      ok, err = pcall(tool.func, args, on_success, on_error, ctx)
    else
      ok, err = pcall(tool.func, args, ctx)
      if ok then
        -- 若返回 Deferred
        if type(err) == "table" and err.then_ then
          err:then_(on_success, on_error)
        else
          finish(true, err)
        end
      else
        finish(false, err)
      end
    end
  elseif tool.execute then
    ok, err = pcall(tool.execute, { args = args, ctx = ctx, on_success = on_success, on_error = on_error })
  else
    finish(false, "工具没有可执行的 func")
  end

  if ok == false then
    finish(false, err)
  end

  return d
end

--- 执行工具并基于"活跃时间"做超时。
--- 用可暂停计时器（ctx.timer）替代固定墙钟超时：等待用户审批/提问的暂停期间
--- 不累计耗时、不消耗超时预算。无 ctx.timer 时（直接调用）自建一个。
--- @param tool table
--- @param args table
--- @param ctx table
--- @param timer table 可暂停计时器
--- @return Deferred
local function _execute_tool_raw(tool, args, ctx, timer)
  local timeout = ctx.timeout_ms or tool.timeout or config_store.get("tools.executor.timeout_ms") or 30000
  local wrapped = async.Deferred.new()
  local settled = false
  -- 先设置超时回调再 start：budget<=0 时 start 会同步触发超时，避免回调缺失。
  timer.on_timeout = function()
    if settled then return end
    settled = true
    wrapped:reject({ kind = "timeout", message = "工具执行超时 (" .. tostring(timeout) .. "ms)" })
  end
  timer:start(timeout)
  local d = _call_tool(tool, args, ctx)
  d:then_(function(v)
    if settled then return end
    settled = true
    timer:stop()
    wrapped:resolve(v)
  end, function(e)
    if settled then return end
    settled = true
    timer:stop()
    wrapped:reject(e)
  end)
  return wrapped
end

--- 沙箱门禁包装：所有工具执行必须经控制面。
--- 沙箱服务缺失且 fail_closed 时拒绝执行（不得静默降级，设计文档 §1.1 第 6/7 条）。
--- @param tool table
--- @param args table
--- @param ctx table
--- @param timer table
--- @return Deferred
local function _execute_tool(tool, args, ctx, timer)
  local cfg = config_store.get("tools.sandbox") or {}
  local sandbox = require("NeoAI.kernel.services").use("services.sandbox")
  if not sandbox then
    if cfg.enabled ~= false and cfg.fail_closed ~= false then
      return async.reject({
        kind = "sandbox",
        message = "沙箱服务不可用且 fail_closed=true，拒绝执行工具: " .. tostring(tool and tool.name),
      })
    end
    return _execute_tool_raw(tool, args, ctx, timer)
  end
  -- 兜底附加规格（覆盖动态注册/未走加载器的工具）
  require("NeoAI.sandbox.wrapper").attach(tool)
  local out = async.Deferred.new()
  sandbox.gate(tool, args, ctx, function()
    return _execute_tool_raw(tool, args, ctx, timer)
  end):then_(function(v) out:resolve(v) end, function(e) out:reject(e) end)
  return out
end

-- ========== 公开 API ==========

--- 工具调用是否触及疑似密钥文件（决定是否启用昂贵的高熵全文扫描）。
--- 命中来源：显式路径参数、run_command 命令串中的绝对路径、内核观测到的密钥文件访问。
--- @param tool_name string
--- @param args table
--- @param ctx table|nil
--- @return boolean
local function _touches_secret_path(tool_name, args, ctx)
  -- 内核观测到的路径用**严口径**：`dpkg -l`/`ss`/`python` 等普通命令会顺带打开
  -- `/etc/ld.so.cache`、`/etc/nsswitch.conf` 等宽口径命中项，若据此启用高熵扫描，
  -- 会把结果里的软件包名（如 `openjdk-21-jdk-headless`）误 token 化。
  if ctx and type(ctx.observed_secret_paths) == "table" then
    for _, p in ipairs(ctx.observed_secret_paths) do
      if secret.is_sensitive_path and secret.is_sensitive_path(p) then return true end
    end
  end
  local spec = tool_spec.get(tool_name)
  for _, field in ipairs(spec.paths or {}) do
    local p = args and args[field]
    if type(p) == "string" and secret.is_secret_path(p) then return true end
  end
  local cmd = args and (args.command or args.cmd)
  if type(cmd) == "string" then
    for tok in cmd:gmatch("%S+") do
      local p = tok:gsub("^['\"]", ""):gsub("['\"]$", "")
      if secret.is_secret_path(p) then return true end
    end
  end
  return false
end

--- 是否对本次工具内容启用高熵扫描：默认仅疑似密钥文件（`entropy_secret_paths_only=false`
--- 时退回旧的「所有内容都做熵检测」行为）。
--- @param tool_name string
--- @param args table
--- @param ctx table|nil
--- @return boolean
local function _entropy_enabled(tool_name, args, ctx)
  local cfg = config_store.get("tools.sandbox.secrets") or {}
  if cfg.entropy_secret_paths_only == false then return true end
  return _touches_secret_path(tool_name, args, ctx)
end

--- 出向密钥防护：扫描工具参数。
--- - 命中映射表中已知的**原始密钥**（未加密真实值）→ 硬拦截并终止整个 Agent（明确通知用户）；
--- - 命中 token（加密后的 key）或**敏感环境变量名** → 记录留痕并提级审批
---   （`ctx.secret_operation`），由待审悬浮窗展示 `⚠ 密钥操作`，**不终止**；
--- - fs_write 类工具的内容参数做 token 化，使写入只落 token，commit 时再还原。
--- 另：AI 可见上下文中的原始密钥由 `core/agent/recovery` 在请求前守卫并终止（沙箱上下文
--- 被突破）。
--- @param tool table
--- @param tool_name string
--- @param args table
--- @param ctx table
--- @return boolean ok
--- @return table|nil err
local function _secret_guard(tool, tool_name, args, ctx)
  if not secret.enabled() then return true end
  local scan = secret.scan(args)
  if scan.secret then
    secret.trace("blocked", { tool = tool_name })
    local agent = ctx and ctx.agent
    if agent then
      pcall(function() require("NeoAI.core.agent.runtime").abort(agent, "secret_exposure") end)
    end
    pcall(function()
      require("NeoAI.kernel.event_bus").emit(require("NeoAI.kernel.events").SANDBOX_SECRET_BLOCKED, {
        tool = tool_name, agent_id = agent and agent.id,
      })
    end)
    pcall(vim.notify,
      "[NeoAI] 检测到对原始密钥的操作，已拦截并终止 Agent（工具: " .. tostring(tool_name) .. "）",
      vim.log.levels.ERROR)
    return false, { kind = "secret", message = "SANDBOX_SECRET_BLOCKED: 工具参数包含原始密钥，已终止 Agent" }
  end
  -- 加密后的 key（token）与敏感环境变量名：软信号，只提级待审，不终止。
  local names = secret.scan_names and secret.scan_names(args) or {}
  if next(scan.tokens) or #names > 0 then
    if next(scan.tokens) then secret.trace("token_used", { tool = tool_name, tokens = scan.tokens }) end
    if #names > 0 then secret.trace("name_used", { tool = tool_name, names = names }) end
    -- KEY 环境变量操作：提级审批（wrapper 据此把候选判为密钥操作 L3，强制待审），不终止。
    if ctx then
      ctx.secret_operation = true
      ctx.secret_names = names
    end
    pcall(function()
      require("NeoAI.kernel.event_bus").emit(require("NeoAI.kernel.events").SANDBOX_SECRET_TRACED, {
        tool = tool_name,
        count = (function() local n = 0; for _ in pairs(scan.tokens) do n = n + 1 end; return n end)(),
        names = names,
      })
    end)
  end
  local spec = require("NeoAI.sandbox.tool_spec").get(tool_name, tool and tool.category)
  if spec and spec.effect == "fs_write" then
    secret.tokenize_args(args, { entropy = _entropy_enabled(tool_name, args, ctx) })
  end
  return true
end

--- 入向：把工具结果中的真实密钥替换为 token，再回传模型（AI 永远看不到原始密钥）。
--- 高熵扫描仅对疑似密钥文件启用（见 `_entropy_enabled`）；结果到达后判定，可纳入内核
--- 观测到的密钥文件访问。
--- @param d Deferred
--- @param ctx table|nil
--- @param tool_name string|nil
--- @param args table|nil
--- @return Deferred
local function _tokenize_out(d, ctx, tool_name, args)
  if not secret.enabled() then return d end
  local out = async.Deferred.new()
  d:then_(function(v)
    local entropy = _entropy_enabled(tool_name or "", args or {}, ctx)
    local function finish(result)
      -- 识别到 AI 读取到 KEY（结果含 token）时追加说明，澄清 token 语义与自动还原。
      if secret.contains_token(result) then
        local hint = secret.read_hint()
        if type(result) == "string" then
          result = result .. "\n\n" .. hint
        elseif type(result) == "table" then
          result = vim.deepcopy(result)
          result.neoai_secret_hint = hint
        end
      end
      out:resolve(result)
    end
    -- 字符串结果（run_command/read_file 等大输出）经线程池做全文 token 化，避免完成瞬间
    -- 占满主线程；线程池不可用时 tokenize_async 内部回退同步。表结果仍走同步（结构较小）。
    if type(v) == "string" then
      return secret.tokenize_async(v, { entropy = entropy }):then_(finish, function()
        finish(v)
      end)
    end
    local ok, tv = pcall(secret.tokenize_result, v, { entropy = entropy })
    finish(ok and tv or v)
  end, function(e)
    out:reject(e)
  end)
  return out
end

--- 执行工具
--- @param tool_name string
--- @param raw_args any
--- @param ctx table { agent?, tool_call_id?, signal?, is_sub_agent?, tool_service? }
--- @return Deferred resolve(结果), reject(错误)
function M.execute(tool_name, raw_args, ctx)
  ctx = ctx or {}
  local signal = ctx.signal
  if signal and signal:aborted() then
    return async.reject({ kind = "aborted", message = "工具执行前已取消" })
  end

  -- 名称解析（别名/模糊匹配）
  local resolved = registry.resolve_name(tool_name)
  if not resolved then
    return async.reject({ kind = "tool", message = "工具不存在: " .. tool_name })
  end
  local tool = registry.get(resolved)

  -- 参数规范化：MCP 工具跳过别名改写与路径展开。
  -- 远端工具的 schema 由服务器权威定义，本地 alias（file→filepath 等）会破坏参数名，
  -- 且服务器会校验 arguments 与 inputSchema（未知参数报错）。路径语义也归属服务器。
  local is_mcp = tool and tool.source == "mcp"
  local args = raw_args
  if not is_mcp then
    args = _normalize_arguments(resolved, raw_args)
    -- 展开路径字段的 ~ 别名（~/... ↔ 主目录）
    args = _expand_path_args(args)
  end

  -- schema 校验
  local valid, verr = validator.validate_parameters(tool.parameters, args)
  if not valid then
    return async.reject({ kind = "validation", message = verr })
  end

  -- 越界访问留痕（read_all 下）：记录 cwd 之外用户工作目录的访问，非阻塞。
  pcall(_trace_outside_access, resolved, args, ctx)

  -- 出向密钥防护（原始密钥硬拦截 + token 留痕 + 写入 token 化）
  local ok_secret, serr = _secret_guard(tool, resolved, args, ctx)
  if not ok_secret then
    return async.reject(serr)
  end

  -- 审批检查。async 模式（默认）不使用执行前阻塞审批：工具立即在沙箱内执行并冻结
  -- 候选，真实修改进入异步待审队列由用户确认后应用（设计文档 §15）。
  -- 例外：命中「遮蔽目录」的工具调用（即使 async）也走审批弹窗；批准后仅对该次调用
  -- 解除对应遮蔽条目（ctx.sandbox_unmask → 运行时 unmask），未批准则拒绝执行。
  local approval_config = registry.get_approval_config(resolved)
  local mode = ctx.approval_mode or config_store.get("tools.approval.mode") or "async"
  local spec = tool_spec.get(resolved)
  local masked_hit, masked_hard = _masked_target(resolved, args)
  local approval_on = config_store.get("tools.sandbox.mask_dirs_approval") ~= false
  -- 进程内读写（read/fs_write）不受 mount 遮蔽约束，必须显式拦截；外部进程（process/network）
  -- 由 mount 硬遮蔽。有审批界面且开启审批时弹窗放行，否则 fail-closed 拒绝。
  -- 命中宿主敏感遮蔽路径（mask_paths/沙箱存储）时不可审批放行，直接硬拒绝。
  local can_approve = (not ctx.is_sub_agent) and ctx.tool_service ~= nil
  local in_process_fs = spec.effect == "read" or spec.effect == "fs_write"
  local needs_approval = false
  if masked_hit then
    if masked_hard then
      return async.reject({ kind = "sandbox", message = "路径位于宿主敏感遮蔽路径: " .. masked_hit })
    end
    if approval_on and can_approve then
      ctx.sandbox_unmask = ctx.sandbox_unmask or {}
      ctx.sandbox_unmask[#ctx.sandbox_unmask + 1] = masked_hit
      needs_approval = true
    elseif in_process_fs then
      return async.reject({ kind = "sandbox", message = "路径位于遮蔽目录且不可审批: " .. masked_hit })
    end
  end
  if mode ~= "async" and validator.check_approval(resolved, args, approval_config, mode) then
    needs_approval = true
  end

  -- 可暂停计时器：tool_loop 在调用前已创建并注入 ctx.timer（用于展示活跃耗时）。
  -- 直接调用（无 tool_loop，如测试）时自建一个，仅用于超时。
  local timer = ctx.timer
  if not timer then
    timer = tool_timer.create()
    ctx.timer = timer
  end

  -- 入向 token 化：结果中的真实密钥替换为 token 后再回传模型。
  if needs_approval and not ctx.is_sub_agent and ctx.tool_service then
    -- 交由 tool_service 做审批 UI，审批通过后继续执行。
    -- 计时器只在审批通过后才 start，因此等待审批的时间不计入耗时、也不消耗超时预算。
    return _tokenize_out(ctx.tool_service.approve_and_execute(resolved, args, ctx, function()
      return _execute_tool(tool, args, ctx, timer)
    end), ctx, resolved, args)
  end

  -- 直接执行
  return _tokenize_out(_execute_tool(tool, args, ctx, timer), ctx, resolved, args)
end

--- 结果字符串化
--- @param result any
--- @return string
function M.stringify(result)
  if result == nil then return "" end
  if type(result) == "string" then return result end
  local ok, encoded = pcall(json.encode, result)
  if ok then return encoded end
  return tostring(result)
end

--- 重置（测试用）
function M.reset()
  -- registry 由 registry.reset 处理
end

return M
