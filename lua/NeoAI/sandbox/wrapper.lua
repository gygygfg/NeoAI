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

-- ========== 私有函数 ==========

--- 为工具附加沙箱规格（幂等）
--- @param tool table
--- @return table
function M.attach(tool)
  if type(tool) ~= "table" then return tool end
  if tool.__sandboxed and tool.__sandbox_spec then return tool end
  local spec = tool_spec.get(tool.name, tool.category)
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
  local function rewrite_str(s)
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

--- 沙箱内已是 root（完整能力）：剥掉前导 `sudo`/`doas`（及其常见布尔 flag），使
--- `sudo apt update` 等价于 `apt update`。沙箱用独立 userns 时仅映射 uid 0，sudo 的
--- `setresuid(...,1,...)` 会 EINVAL，且 `/etc/sudoers` 被遮蔽，故 sudo 无意义且会失败。
--- 仅处理简单形式；含 `-u/-g/-i/-s/-p/-C` 等改变用户/登录的形式保持原样。
--- @param cmd string|nil
--- @return string|nil
local function _strip_root_prefix(cmd)
  if type(cmd) ~= "string" or cmd == "" then return cmd end
  local lead, after = cmd:match("^(%s*)sudo%s+(.*)$")
  if not after then lead, after = cmd:match("^(%s*)doas%s+(.*)$") end
  if not after then return cmd end
  -- 改变用户/组/登录的形式：不处理（避免语义变化）
  if after:match("^%-%-?[ugi]") or after:match("^%-%-login") or after:match("^%-%-user")
    or after:match("^%-%-group") then
    return cmd
  end
  after = after:gsub("^%-%-%s+", ""):gsub("^%-[EHnSbkAPv]%s+", "")
  if after == "" then return cmd end
  return lead .. after
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
  -- 无法 overlay 的 tmpfs 挂载根（overlay lower 为挂载点会 EINVAL）：这些根只能
  -- bind 空会话目录；若 cwd 在其下，bind 会让 cwd 消失，故跳过该根、改为单独 overlay cwd。
  local NON_OVERLAY = { "/dev/shm", "/run" }
  local function is_nonoverlay(r)
    for _, x in ipairs(NON_OVERLAY) do if r == x then return true end end
    return false
  end
  -- F2：每会话私有临时根（默认 /tmp、/var/tmp）绝不 overlay——否则会以宿主真实
  -- /tmp 为只读 lower，泄露宿主/上一会话残留。它们由 runtime 以会话私有目录绑定。
  local tmpfs_roots = runtime.tmpfs_roots()
  local function is_tmpfs_root(r)
    for _, x in ipairs(tmpfs_roots) do if r == x then return true end end
    return false
  end
  local roots = {}
  local function under(p, r)
    return p == r or p:sub(1, #r + 1) == r .. "/"
  end
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
  for _, r in ipairs(roots) do
    local d = base_dir .. "/" .. _enc_root(r)
    local upper, work, bind = d .. "/upper", d .. "/work", d .. "/bind"
    fs.ensure_dir(upper)
    fs.ensure_dir(work)
    fs.ensure_dir(bind)
    -- 载荷非 root 时，overlay upper/work 必须归载荷所有，否则内核拒绝可写挂载（EROFS）。
    runtime.chown_payload(d)
    specs[#specs + 1] = { root = r, upper = upper, work = work, bind = bind }
  end
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
    secret_warning = meta and meta.secret_warning or nil,
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
  })
end

--- 按模式/授权发布或入队；返回解析后的结果/错误
--- @param cand table
--- @param attempt table
--- @param ctx table
--- @param cfg table
--- @param spec table
--- @param result any
--- @param process_info table|nil
--- @return table { ok, value?, err? }
local function _settle_candidate(cand, attempt, ctx, cfg, spec, result, process_info)
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
  local evidence_id = evidence.add("fs", { files = cand.files, process = process_info }, {
    command_id = attempt.command_id, attempt_id = attempt.attempt_id, tool = attempt.tool_name,
  })
  local stats = impact.stats(impacts)

  -- 安全分级：按写路径/包安装/密钥/提权/网络/结果信号评估级别并给出建议动作。
  local risk = require("NeoAI.sandbox.risk")
  local review = require("NeoAI.sandbox.review")
  local paths = _cand_paths(cand)
  -- 专用包管理器识别：命令未命中包管理器名单，但改动落在包管理器状态/安装目录
  -- （node_modules、site-packages、/var/lib/apt、~/.cargo 等）时，同样按包安装处理（封顶 L2）。
  local pkg_by_path = nil
  do
    local privilege = require("NeoAI.sandbox.privilege")
    for _, p in ipairs(paths) do
      pkg_by_path = privilege.package_path_manager(p)
      if pkg_by_path then break end
    end
  end
  local is_pkg = attempt.package == true or pkg_by_path ~= nil
  local secret_warning = nil
  do
    local ok, s = pcall(require("NeoAI.sandbox.secret"))
    -- 包安装状态文件（apt lists/pkgcache、pip/npm 缓存等）常含高熵签名/哈希，并非用户密钥；
    -- 跳过密钥检测，避免误报「密钥操作」并误升到 L3。
    if ok and s.enabled() and not is_pkg then
      secret_warning = s.warn_for_files(cand.files)
    end
  end
  -- AI 生成的高熵信息（密钥类）：候选内容含熵/具名候选（非宿主 token）时留痕、发事件、审计，
  -- 并给出「密钥操作」提示，强制进入待审（不终止 Agent）。与宿主密钥 token 化互补。
  local generated = {}
  do
    local ok, s = pcall(require, "NeoAI.sandbox.secret")
    if ok and s.enabled() and not is_pkg then
      generated = s.detect_generated(cand.files)
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
    end
  end
  -- 本次调用涉及加密 token 或敏感环境变量名（但候选文件不含 token）时，也给出密钥操作警告，
  -- 使待审悬浮窗展示 `⚠ 密钥操作`（软提示 + 审批，不终止 Agent）。
  if not secret_warning and ctx and ctx.secret_operation then
    secret_warning = { count = 1, tokens = {}, names = ctx.secret_names or {}, reason = "KEY_OPERATION" }
  end
  local rf = {
    effect = spec.effect,
    paths = paths,
    privilege_tier = attempt.privilege_tier,
    package = is_pkg,
    network = attempt.network == true,
    -- 密钥操作：候选文件含 token，或本次调用使用了 KEY 环境变量 token（提级强制待审）。
    secret = (secret_warning and (secret_warning.count or 0) > 0)
      or (ctx and ctx.secret_operation == true) or false,
    command = attempt.container_command or (process_info and process_info.command) or nil,
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
  if rf.package and r.level >= 3 and (risk.dangerous_level(rf.command) or 0) < 3 then
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
    pcall(function() pinfo = require("NeoAI.sandbox.privilege").package_info(rf.command) end)
  end
  if not pinfo and pkg_by_path then
    pinfo = { manager = pkg_by_path, packages = {}, key = pkg_by_path .. ":*" }
  end
  local item = _enqueue_review(cand, attempt, cfg, env, {
    secret_warning = secret_warning,
    risk_level = r.level, risk_name = r.name, risk_reasons = r.reasons,
    package = rf.package, action = action,
    command = rf.command,
    package_manager = pinfo and pinfo.manager or nil,
    package_names = pinfo and pinfo.packages or nil,
    package_key = pinfo and pinfo.key or nil,
  })
  if item then
    -- 同一文件被再次编辑：新候选取代同路径的旧待审项（队列只保留最新版本）
    require("NeoAI.sandbox.review").supersede_by_paths(_cand_paths(cand), item.change_set_id)
  end
  control.transition(attempt, "AWAITING_PUBLICATION_AUTH")
  return { ok = true, value = result }
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
    store.write_candidate(cand)
    candidate.merge_candidate(cand)
    local settled = _settle_candidate(cand, attempt, ctx, cfg, spec, result, process_info)
    candidate.cleanup(attempt.attempt_id)
    return settled
  end
  candidate.cleanup(attempt.attempt_id)
  return { ok = true, value = result }
end

-- ========== 公开 API ==========

--- 执行门禁
--- @param tool table 工具定义（含 __sandbox_spec）
--- @param args table
--- @param ctx table
--- @param call_original function() -> Deferred 真正执行原工具
--- @return Deferred
function M.gate(tool, args, ctx, call_original)
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
  control.transition(attempt, "PARSED")
  control.transition(attempt, "PREFLIGHTED")

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
      args.command = _strip_root_prefix(args.command)
    end
    -- 权限档位：分类命令（需在构建可写根之前，以便包安装命令加入其状态目录作为可写根）。
    local privilege = require("NeoAI.sandbox.privilege")
    local pcfg = config_store.get("tools.sandbox.privilege") or {}
    local req = privilege.classify(attempt.tool_name, args, spec)
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
    if cgroup.limits_configured() then
      local lcfg = config_store.get("tools.sandbox.limits") or {}
      local limits = cgroup.resolve_limits()
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
      if priv and priv.userns then
        active_specs = {}
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
      ctx.sandbox_prefix = prefix
      ctx.sandbox_cwd = eff_cwd
      ctx.sandbox_env = runtime.sandbox_env(eff_priv)
      -- 视图降级标记：无 overlay（bind 私有层 / userns 档）时命令看不到真实项目文件，
      -- 只看到会话私有视图；供 run_command 在结果中提示，避免与真实磁盘视图混同。
      local degraded = true
      local degraded_reason
      for _, s in ipairs(active_specs) do
        if s.mode == "overlay" then degraded = false end
        if not degraded_reason and s.overlay_reason then degraded_reason = s.overlay_reason end
      end
      ctx.sandbox_degraded = degraded
      ctx.sandbox_degraded_reason = degraded_reason
      ctx.sandbox_shell_state = session_dir and require("NeoAI.sandbox.conceal").session_mount() or nil
      return true
    end

    local function _fail(msg)
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
    local function finish(res, err)
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
      -- 捕获各可写根 overlay 的改动；overlay 不可用（或 userns 档位）时捕获降级私有 cwd
      if runtime.backend() == "bwrap" and #active_specs > 0 then
        for _, spec in ipairs(active_specs) do
          candidate.capture_overlay(attempt.attempt_id, spec.root,
            spec.mode == "bind" and spec.bind or spec.upper)
        end
      else
        candidate.capture_overlay(attempt.attempt_id, real_cwd, staging)
      end
      local cand = candidate.finish(attempt.attempt_id)
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
        store.write_candidate(cand)
        -- 双向互通：把命令改动合并进工作区暂存映射，使 read_file/edit_file 可见
        candidate.merge_candidate(cand)
        local settled = _settle_candidate(cand, attempt, ctx, cfg, spec, res, { command = args and args.command })
        candidate.cleanup(attempt.attempt_id)
        if settled.ok then d:resolve(settled.value) else d:reject(settled.err) end
      else
        if cand == nil then
          control.transition(attempt, "FAILED")
          candidate.cleanup(attempt.attempt_id)
          d:reject({ kind = "sandbox", message = "候选冻结失败", command_id = attempt.command_id })
        else
          control.transition(attempt, "COMPLETED_READ_ONLY")
          candidate.cleanup(attempt.attempt_id)
          d:resolve(res)
        end
      end
    end

    --- 执行一次；权限/网络失败时自动发起升级并在隔离内重跑（记录，不静默）。
    --- 全档位生效：T0 失败升 T1，T1 失败升 T2（直到 max_tier），每步写证据/事件/审计。
    local function run(priv, current_tier)
      call_original():then_(function(res)
        if pcfg.auto_escalate ~= false and current_tier < (pcfg.max_tier or 2) then
          local raw = ctx.sandbox_last_result
          local esc = privilege.detect_escalation(raw)
          if esc and esc.tier > current_tier then
            local r2 = privilege.resolve(esc.tier, { tier = esc.tier, docker = req.docker, network = req.network })
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

    run(resolved.privileges, req.tier)
    return d
  end

  -- 文件系统写：暂存到工作区私有副本，冻结候选，按模式发布/入队
  local record = candidate.begin(attempt, root)
  local sandbox = require("NeoAI.sandbox")
  local previous_active = sandbox._set_active_attempt(attempt)
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

return M
