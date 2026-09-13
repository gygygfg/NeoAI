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

--- 结果附加候选/待审说明
--- @param result any
--- @param cand table
--- @param item table|nil 待审变更单元（异步模式）
--- @param env table|nil 裁决信封
--- @return any
local function _annotate(result, cand, item, env)
  local note
  if item then
    note = string.format(
      "\n\n[沙箱] 修改已冻结为候选 %s（%d 项），等待异步确认。"
        .. "用 :NeoAISandboxReview 查看，或 :NeoAISandboxApply %s 应用。",
      cand.candidate_digest, #(cand.files or {}), item.change_set_id
    )
  else
    note = string.format(
      "\n\n[沙箱] 修改已冻结为候选 %s（%d 项），未写入真实工作区。"
        .. "使用 :NeoAISandboxCommit %s 应用，或 :NeoAISandboxDiscard %s 丢弃。",
      cand.candidate_digest, #(cand.files or {}), cand.candidate_digest, cand.candidate_digest
    )
  end
  if env then note = note .. "\n" .. envelope.to_text(env) end
  if type(result) == "string" then
    return result .. note
  end
  if type(result) == "table" then
    result.sandbox = {
      candidate_digest = cand.candidate_digest,
      files = #(cand.files or {}),
      change_set_id = item and item.change_set_id or nil,
      state = env and env.state or "AWAITING_PUBLICATION_AUTH",
      decision = env and env.decision or "NEEDS_CONFIRMATION",
    }
    return result
  end
  return tostring(result) .. note
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
  local env = envelope.build({
    command_id = attempt.command_id,
    attempt_id = attempt.attempt_id,
    state = auto and "READY_TO_PUBLISH" or "AWAITING_PUBLICATION_AUTH",
    decision = auto and "ALLOW" or "NEEDS_CONFIRMATION",
    severity = "LOW",
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
      return { ok = true, value = result }
    end
    control.transition(attempt, "CONFLICT")
    return { ok = false, err = { kind = "sandbox", message = "发布冲突: " .. tostring(pub.reason), command_id = attempt.command_id } }
  end

  local item = _enqueue_review(cand, attempt, cfg, env)
  control.transition(attempt, "AWAITING_PUBLICATION_AUTH")
  return { ok = true, value = _annotate(result, cand, item, env) }
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
    return call_original()
  end

  -- 网络：默认离线拒绝（策略已在上方离线规则处理）
  if spec.effect == "network" then
    control.transition(attempt, "STAGING")
    control.transition(attempt, "FAILED")
    return async.reject({
      kind = "sandbox",
      message = "网络操作未获授权（默认离线），阶段一不支持受控网关",
      reason_codes = { "NETWORK_NOT_DECLARED" },
      command_id = attempt.command_id,
    })
  end

  -- 外部进程：经运行时隔离执行；cwd 用 overlay 私有可写层，改动冻结为候选
  if spec.effect == "process" then
    local ok_rt, rt_err = runtime.check_available()
    if not ok_rt then
      control.transition(attempt, "FAILED")
      return async.reject({ kind = "sandbox", message = rt_err, command_id = attempt.command_id })
    end
    local record = candidate.begin(attempt, root)
    local real_cwd = vim.fn.getcwd()
    local upper = record.dir .. "/overlay_upper"
    local work = record.dir .. "/overlay_work"
    fs.ensure_dir(upper)
    fs.ensure_dir(work)
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
    local prefix, perr, eff_cwd = runtime.process_prefix({
      cwd = real_cwd, upper = upper, work = work, fallback_cwd = record.dir .. "/upper",
    })
    if not prefix then
      if cg_handle then cgroup.release(cg_handle) end
      candidate.cleanup(attempt.attempt_id)
      control.transition(attempt, "FAILED")
      return async.reject({ kind = "sandbox", message = perr, command_id = attempt.command_id })
    end
    if cg_handle then
      local join = cgroup.join_prefix(cg_handle)
      local full = {}
      for _, v in ipairs(join) do full[#full + 1] = v end
      for _, v in ipairs(prefix) do full[#full + 1] = v end
      prefix = full
    end
    ctx.sandbox_prefix = prefix
    ctx.sandbox_cwd = eff_cwd
    local d = async.Deferred.new()
    call_original():then_(function(res)
      if cg_handle then cgroup.release(cg_handle) end
      candidate.capture_overlay(attempt.attempt_id, real_cwd, upper)
      local cand = candidate.finish(attempt.attempt_id)
      if require("NeoAI.sandbox.fault").hit("freeze") then cand = nil end
      control.transition(attempt, "CANDIDATE_READY")
      if cand and #cand.files > 0 then
        cand.command_id = attempt.command_id
        store.write_candidate(cand)
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
    end, function(err)
      if cg_handle then cgroup.release(cg_handle) end
      control.transition(attempt, "FAILED")
      candidate.cleanup(attempt.attempt_id)
      d:reject(err)
    end)
    return d
  end

  -- 文件系统写：暂存到私有 upper，冻结候选，按模式发布/入队
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
    if cand then
      cand.command_id = attempt.command_id
      store.write_candidate(cand)
      local settled = _settle_candidate(cand, attempt, ctx, cfg, spec, result)
      candidate.cleanup(attempt.attempt_id)
      if settled.ok then d:resolve(settled.value) else d:reject(settled.err) end
    else
      control.transition(attempt, "FAILED")
      candidate.cleanup(attempt.attempt_id)
      d:reject({ kind = "sandbox", message = "候选冻结失败", command_id = attempt.command_id })
    end
  end, function(err)
    sandbox._set_active_attempt(previous_active)
    control.transition(attempt, "FAILED")
    candidate.cleanup(attempt.attempt_id)
    d:reject(err)
  end)
  return d
end

return M
