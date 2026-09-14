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

--- 构造进程 overlay 规格：配置的可写根（剔除不存在、包含 overlay 基目录的根）+ cwd。
--- overlay 的 upper 必须位于其 lower 之外，否则内核挂载返回 EINVAL。
--- 供外部进程（run_command）与 LSP 命名空间覆盖共用。
--- @param cwd string
--- @param base_dir string 进程 overlay 基目录（宿主路径）
--- @return table 数组 { root, upper, work }
function M.build_overlay_specs(cwd, base_dir)
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
--- @return table|nil item
local function _enqueue_review(cand, attempt, cfg, env)
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
  -- 影响与证据（fs/process），未知用 null 表达
  local impacts = impact.from_candidate(cand, { command_id = attempt.command_id, attempt_id = attempt.attempt_id })
  if process_info then impacts[#impacts + 1] = impact.process(process_info) end
  local evidence_id = evidence.add("fs", { files = cand.files, process = process_info }, {
    command_id = attempt.command_id, attempt_id = attempt.attempt_id, tool = attempt.tool_name,
  })
  local stats = impact.stats(impacts)

  -- 任务授权匹配：覆盖时自动应用（TASK_POLICY_MATCH）；mode=commit 亦立即发布
  local covering = grant.find_covering(spec.effect, cand)
  local mode = ctx.sandbox_mode or cfg.mode or "dry_run"
  local auto = covering ~= nil or ((cfg.review or {}).auto_apply == true) or mode == "commit"
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
  local item = _enqueue_review(cand, attempt, cfg, env)
  if item then
    -- 同一文件被再次编辑：新候选取代同路径的旧待审项（队列只保留最新版本）
    require("NeoAI.sandbox.review").supersede_by_paths(_cand_paths(cand), item.change_set_id)
  end
  control.transition(attempt, "AWAITING_PUBLICATION_AUTH")
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
    if spec.effect == "read" then
      for _, key in ipairs(spec.paths or {}) do
        local v = args[key]
        if type(v) == "string" then
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
    if next(rev) then
      -- 成功与失败都还原暂存路径：读取暂存副本失败（如暂存已删除）时，错误信息
      -- 会带暂存路径，必须还原为真实路径，避免沙箱内部路径泄露给模型。
      local out = async.Deferred.new()
      d:then_(function(res)
        out:resolve(_rewrite_value(rev, res))
      end, function(err)
        out:reject(_rewrite_value(rev, err))
      end)
      return out
    end
    return d
  end

  -- 网络：默认放行，仅记录审计（不拦截）；offline=true 或受控白名单在策略层已拒绝
  if spec.effect == "network" then
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
    local real_cwd = vim.fn.getcwd()
    -- 会话级共享可写层：同一 agent 循环内所有命令共用（命令 N 看得到命令 N-1 的改动），
    -- agentEnd 轮换会话时随会话目录清理（改动已冻结为候选）。可写根（默认仅 cwd；
    -- /tmp、/var/tmp 属每会话私有 tmpfs，不作为 overlay lower）的写入进会话可写层。
    local proc_dir = candidate.process_dir()
    local staging = proc_dir .. "/fallback" -- overlay 不可用时的私有可写 cwd
    fs.ensure_dir(staging)
    local specs = M.build_overlay_specs(real_cwd, proc_dir)
    -- 选定每个可写根实际使用的层（overlay 或 bind），供物化/捕获/前缀构造一致使用
    for _, spec in ipairs(specs) do
      if runtime.overlay_available() and runtime.overlay_mountable(spec.root, spec.upper, spec.work) then
        spec.mode = "overlay"
      else
        spec.mode = "bind"
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
    end
    control.transition(attempt, "STAGING")
    -- 资源域：配置了 limits 时必须成功创建，否则明确拒绝（不静默降级）
    local cgroup = require("NeoAI.sandbox.cgroup")
    local cg_handle = nil
    if cgroup.limits_configured() then
      local limits = config_store.get("tools.sandbox.limits") or {}
      local h, cerr = cgroup.prepare(attempt.attempt_id, limits)
      if not h then
        candidate.cleanup(attempt.attempt_id)
        control.transition(attempt, "FAILED")
        return async.reject({ kind = "sandbox", message = cerr, command_id = attempt.command_id })
      end
      cg_handle = h
    end

    -- 权限档位：分类命令所需权限并解析为隔离参数（T0 = 最小权限 + 默认隔离网络）。
    local privilege = require("NeoAI.sandbox.privilege")
    local pcfg = config_store.get("tools.sandbox.privilege") or {}
    local req = privilege.classify(attempt.tool_name, args, spec)
    -- 实际用于执行/捕获的 overlay 规格：嵌套 userns（T2）下 overlay 会 EINVAL，
    -- 退化为「只读根 + 私有 cwd」，改动仅在 cwd 捕获（主机效果走提案）。
    local active_specs = specs

    --- 构造并注入进程前缀（含 cgroup 加入）；失败返回 nil, err
    local function _build_prefix(priv)
      if priv and priv.userns then
        active_specs = {}
      end
      -- 审批放行：把本次调用获批解除遮蔽的条目并入 unmask（与档位 unmask 合并）。
      local eff_priv = priv
      local approved = ctx.sandbox_unmask
      if type(approved) == "table" and #approved > 0 then
        eff_priv = {}
        for k, v in pairs(priv or {}) do eff_priv[k] = v end
        local merged = {}
        for _, p in ipairs((priv and priv.unmask) or {}) do merged[#merged + 1] = p end
        for _, p in ipairs(approved) do merged[#merged + 1] = p end
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
      ctx.sandbox_shell_state = session_dir and require("NeoAI.sandbox.conceal").session_mount() or nil
      return true
    end

    local function _fail(msg)
      if cg_handle then cgroup.release(cg_handle) end
      candidate.cleanup(attempt.attempt_id)
      control.transition(attempt, "FAILED")
      return async.reject({ kind = "sandbox", message = msg, command_id = attempt.command_id })
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

    --- 执行一次；T0 因权限/网络失败时自动发起升级并在隔离内重跑（记录，不静默）。
    local function run(priv, current_tier)
      call_original():then_(function(res)
        if pcfg.auto_escalate ~= false and current_tier == 0 then
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
