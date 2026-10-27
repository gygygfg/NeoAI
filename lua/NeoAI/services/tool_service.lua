--- 工具服务
--- @module 'NeoAI.services.tool_service'
--- 审批 + 调度 + 执行。Agent 的工具循环通过此服务执行工具。
--- - execute(agent, name, args, tool_call_id, opts)：执行工具
--- - approve_and_execute(...)：审批通过后继续执行
--- - 子 Agent 边界审核 + 工具调用计数

local async = require("NeoAI.utils.async")
local executor = require("NeoAI.tools.executor")
local registry = require("NeoAI.tools.registry")
local config_store = require("NeoAI.kernel.config_store")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")

local M = {}

-- ========== 私有状态 ==========

local state = {
  approval_queue = {}, -- { tool_name, args, ctx, continue_fn, d } 等待审批的条目
  approval_showing = false, -- 串行审批槽位：true 表示当前正有一个弹窗在展示
  current_approval = nil, -- 当前正在审批的条目（已从队列弹出）
  allow_all = {}, -- tool_name -> true
}

-- ========== 私有函数 ==========

--- 当前生效的审批模式
--- @return string "prompt" | "auto_allow" | "strict"
local function _current_mode()
  return config_store.get("tools.approval.mode") or "prompt"
end

-- ========== 私有函数 ==========

--- 子 Agent 边界审核（通过子 Agent 管理器）
--- @param ctx table
--- @param tool_name string
--- @return boolean, string|nil
local function _review_sub_agent(ctx, tool_name)
  if not ctx.is_sub_agent then return true end
  local sub_agent_id = ctx.sub_agent_id
  if not sub_agent_id then return true end
  local bridge = require("NeoAI.kernel.core_bridge")
  local manager = bridge.sub_agent and bridge.sub_agent()
  if not manager then return true end
  local ok, reason = manager.review_tool_call(sub_agent_id, tool_name)
  if ok then
    manager.track_tool_call(sub_agent_id)
  end
  return ok, reason
end

--- 提取工具调用的首个路径参数（供「加入工作目录」定位所操作文件）。
--- 优先用工具沙箱规格声明的路径字段，回退到常见路径参数名。
--- @param tool_name string
--- @param args table
--- @return string|nil
local function _target_path(tool_name, args)
  if type(args) ~= "table" then return nil end
  local spec = require("NeoAI.sandbox.execution.tool_spec").get(tool_name)
  for _, field in ipairs(spec.paths or {}) do
    local p = args[field]
    if type(p) == "string" and p ~= "" then return p end
  end
  for _, field in ipairs({ "file_path", "filepath", "path", "file" }) do
    local p = args[field]
    if type(p) == "string" and p ~= "" then return p end
  end
  return nil
end

--- 构建审批 UI 内容
--- @param tool_name string
--- @param args table
--- @param ctx table|nil
--- @return string
local function _approval_text(tool_name, args, ctx)
  local tool = registry.get(tool_name)
  local desc = tool and tool.description or ""
  local json = require("NeoAI.utils.json")
  local args_str = json.encode(args)
  local text = string.format(
    "工具: %s\n描述: %s\n参数: %s",
    tool_name, desc, args_str
  )
  -- 跨挂载点兼容模式说明：工作区在独立挂载点时，命令沙箱默认视图无法投影其内容，
  -- 需用户批准以「整机只读 + 工作区单层 overlay」运行。
  local mount_root = ctx and ctx.sandbox_cross_mount_root
  if mount_root then
    text = text .. "\n\n[兼容模式] 工作区位于独立挂载点 " .. tostring(mount_root)
      .. "，整机根沙箱视图无法投影其内容。批准后本次命令将以"
      .. "「整机只读 + 工作区单层 overlay」运行；工作区写入仍冻结为待审改动。"
  end
  -- 越界访问留痕：把近期访问 cwd 之外用户工作目录的记录附在审批窗内（非阻塞、仅展示）。
  -- 按文件路径合并（同一路径的多工具访问合并）、路径升序排序后展示。
  local ok, trace = pcall(require, "NeoAI.sandbox.observe.trace")
  if ok and trace then
    local items = trace.list_grouped()
    if #items > 0 then
      local lines = { "", "越界访问（工作区外，仅记录）:" }
      local start = math.max(1, #items - 4)
      for i = start, #items do
        local it = items[i]
        local tool_label = table.concat(it.tools or { it.tool or "?" }, ", ")
        lines[#lines + 1] = string.format("  [%s] %s", tool_label, tostring(it.path or ""))
      end
      text = text .. "\n" .. table.concat(lines, "\n")
    end
  end
  return text
end

--- 结算一条待审批条目的**阻塞账目**：恰好一次发出 TOOL_APPROVED / TOOL_APPROVAL_CANCELLED，
--- 并清理审批中心镜像条目（`hub.clear` 幂等）。
--- 必须由**所有**退出路径调用（决策 / 超时兜底 / 弹窗展示失败 / 窗口关闭取消），否则
--- TOOL_APPROVAL_REQUESTED 得不到配对终局事件，Herder 侧的 blocked 计数永久 +1——表现为
--- pane 一直停留在「等待确认」，审批交互完成后也不回到「运行中」。
--- @param item table { tool_name, ctx, mirror_id?, blocking_settled? }
--- @param allowed boolean|nil 是否允许（假值 = 取消/拒绝）
--- @param reason string|nil 取消原因
local function _settle_blocking(item, allowed, reason)
  if type(item) ~= "table" or item.blocking_settled then return end
  item.blocking_settled = true
  local agent_id = item.ctx and item.ctx.agent and item.ctx.agent.id
  if allowed then
    event_bus.emit(events.TOOL_APPROVED, { tool_name = item.tool_name, agent_id = agent_id })
  else
    event_bus.emit(events.TOOL_APPROVAL_CANCELLED, {
      tool_name = item.tool_name, reason = reason, agent_id = agent_id,
    })
  end
  -- 镜像条目：无论走哪条退出路径都清掉，避免审批悬浮窗残留「待批准」（进而 pin 住 blocked）。
  if item.mirror_id then
    local mid = item.mirror_id
    item.mirror_id = nil
    pcall(function() require("NeoAI.sandbox.review.approval_hub").clear(mid) end)
  end
end

--- 结算一条待审批条目：resolve/reject 其 Deferred 并发相应事件（幂等）。
--- 供当前条目决策与会话允许批量放行复用：条目已决策（item.d == nil）时不重复 settle。
--- @param item table { tool_name, args, ctx, continue_fn, d }
--- @param allowed boolean 是否允许
--- @param reason string|nil 拒绝原因
local function _resolve_approval_item(item, allowed, reason)
  local d = item.d
  item.d = nil -- 已决策：审批超时不再作用于本条目（避免杀掉已批准的长耗时执行）
  if not (d and d:is_pending()) then return end
  _settle_blocking(item, allowed, reason)
  if allowed then
    item.continue_fn():then_(function(r) d:resolve(r) end, function(e) d:reject(e) end)
  else
    d:reject({ kind = "approval", message = reason or ("用户拒绝了工具调用: " .. item.tool_name) })
  end
end

--- 设置/清除某工具的「本次会话允许」（仅内存态）。
--- allow=true：写入 state.allow_all，并把审批队列中已排队的同名工具**立即放行**
--- （保持其余条目原顺序），避免同一工具继续逐个重复弹窗；随后发 SANDBOX_APPROVAL_CHANGED
--- 通知悬浮窗刷新「工具审批条件」摘要。
--- @param tool_name string
--- @param allow boolean
local function _set_allow_all(tool_name, allow)
  if type(tool_name) ~= "string" or tool_name == "" then return end
  if allow then
    state.allow_all[tool_name] = true
    -- 先重建队列（移出同名条目、保持其余原顺序），再对移出的条目放行，
    -- 使放行回调（continue_fn）内若再次入队不会被重复处理。
    local kept, granted = {}, {}
    for _, item in ipairs(state.approval_queue) do
      if item.tool_name == tool_name then
        granted[#granted + 1] = item
      else
        kept[#kept + 1] = item
      end
    end
    state.approval_queue = kept
    for _, item in ipairs(granted) do
      _resolve_approval_item(item, true)
    end
  else
    state.allow_all[tool_name] = nil
  end
  pcall(function()
    event_bus.emit(events.SANDBOX_APPROVAL_CHANGED, {
      page = "behavior",
      tool_name = tool_name,
      allow = allow and true or false,
    })
  end)
end

-- ========== 审批 UI（由 ui/components/tool_approval 注入） ==========

local approval_ui = nil

--- 注册审批 UI 实现
--- @param impl table { show(config), hide(), on_select(cb), on_cancel(cb) }
function M.set_approval_ui(impl)
  approval_ui = impl
end

--- 展示审批窗口
--- @param tool_name string
--- @param args table
--- @param decision_cb function(allowed=boolean, reason=string|nil)
--- @param ctx table
--- @param item table|nil 队列条目（用于回填审批中心镜像 id，供后续退出路径清理）
local function _show_approval(tool_name, args, decision_cb, ctx, item)
  local text = _approval_text(tool_name, args, ctx)
  local done = false
  local mirror_id = nil
  -- 归一决策值：allow_once | allow_session | deny（与 net_consent / device_consent 一致）。
  -- 幂等：done 标记保证先决策者生效，重复决策不重复 settle Deferred / 不重复发事件。
  -- 联动：先关自身弹窗（若还开着），再清除悬浮窗镜像条目（hub.resolve，幂等），最后回调。
  local function decide(value, reason)
    if done then return end
    done = true
    if value ~= "allow_once" and value ~= "allow_session" and value ~= "deny" then
      value = value and "allow_once" or "deny"
    end
    if approval_ui and approval_ui.hide then pcall(approval_ui.hide) end
    if mirror_id then
      pcall(require("NeoAI.sandbox.review.approval_hub").resolve, mirror_id, value)
      mirror_id = nil
      if type(item) == "table" then item.mirror_id = nil end
    end
    decision_cb(value ~= "deny", reason)
  end
  if approval_ui and approval_ui.show then
    approval_ui.show({
      text = text,
      tool_name = tool_name,
      args = args,
      on_confirm = function() decide("allow_once") end,
      on_cancel = function(reason) decide("deny", reason) end,
      on_confirm_all = function()
        _set_allow_all(tool_name, true)
        decide("allow_session")
      end,
      on_add_to_workspace = function()
        local path = _target_path(tool_name, args)
        if not path then
          vim.notify("[NeoAI] 该工具无文件路径，无法加入工作目录", vim.log.levels.WARN)
        else
          local dir = vim.fn.fnamemodify(vim.fn.expand(path), ":p:h")
          if registry.add_allowed_directory(tool_name, dir) then
            vim.notify("[NeoAI] 已加入工作目录: " .. dir, vim.log.levels.INFO)
          else
            vim.notify("[NeoAI] 目录已在工作目录中: " .. dir, vim.log.levels.INFO)
          end
        end
        decide("allow_once")
      end,
    })
  else
    -- 无 UI（headless/测试）：默认允许
    vim.notify("[NeoAI] 工具审批: " .. text, vim.log.levels.WARN)
    decide("allow_once")
  end
  -- 镜像到审批分流中心（多级页面审批悬浮窗可决策）：
  --   命中遮蔽目录（ctx.sandbox_unmask）→「资源访问」页；其余工具调用同意 →「工具行为」页。
  -- 独立弹窗仍为即时通道；先决策者生效（decide 幂等 + hub.resolve 幂等）。
  local okhub, hub = pcall(require, "NeoAI.sandbox.review.approval_hub")
  if okhub and hub.available() then
    local page = (type(ctx) == "table" and type(ctx.sandbox_unmask) == "table"
      and #ctx.sandbox_unmask > 0) and "resource" or "behavior"
    -- 统一运行时请求广播（同一事件 SANDBOX_CONSENT_REQUESTED，按 page 区分：
    -- 敏感隐私文件读取 → resource；危险命令/工具调用同意 → behavior）。
    pcall(function()
      require("NeoAI.sandbox.review.consent").emit(page, {
        tool = tool_name,
        masked = page == "resource" and type(ctx.sandbox_unmask) == "table"
          and ctx.sandbox_unmask[1] or nil,
      })
    end)
    local tool = registry.get(tool_name)
    local detail = {}
    if tool and tool.description then detail[#detail + 1] = "描述: " .. tostring(tool.description) end
    if type(args) == "table" then
      local okj, js = pcall(function() return require("NeoAI.utils.json").encode(args) end)
      if okj and type(js) == "string" then
        if #js > 200 then js = js:sub(1, 197) .. "…" end
        detail[#detail + 1] = "参数: " .. js
      end
    end
    -- 资源访问页：命中的遮蔽路径若属于凭据/密钥文件（~/.ssh/id_rsa、*.pem、.env 等），
    -- 在条目里直接标明「密钥」，让用户在批准资源访问前就知道这次读的是密钥材料
    -- （而不是只看到一条普通目录路径）。判定用密钥模块的严口径规则，避免误标。
    local secret_path
    if page == "resource" and type(ctx) == "table" and type(ctx.sandbox_unmask) == "table" then
      local oksec, secret = pcall(require, "NeoAI.sandbox.secret.secret")
      if oksec and secret then
        for _, p in ipairs(ctx.sandbox_unmask) do
          if type(p) == "string" and ((secret.is_sensitive_path and secret.is_sensitive_path(p))
            or (secret.is_secret_path and secret.is_secret_path(p))) then
            secret_path = p
            break
          end
        end
      end
      if secret_path then
        detail[#detail + 1] = "🔑 密钥: " .. tostring(secret_path) .. "（凭据/密钥文件）"
      end
    end
    mirror_id = hub.submit(page, {
      title = tool_name,
      detail = detail,
      on_decision = function(v)
        -- 悬浮窗决策：allow_session 时同步置会话允许并放行队列中同名工具。
        if v == "allow_session" then _set_allow_all(tool_name, true) end
        decide(v, v == "deny" and "用户拒绝（审批中心）" or nil)
      end,
      meta = { tool_name = tool_name,
        -- 资源访问页：记录命中的遮蔽路径，供审批悬浮窗「W」便捷加入工作目录。
        masked = page == "resource" and type(ctx.sandbox_unmask) == "table"
          and ctx.sandbox_unmask[1] or nil,
        -- 资源访问页：该条目命中的密钥路径（供悬浮窗标「🔑 密钥」标签）。
        secret_path = secret_path },
    })
    -- 回填到队列条目：超时 / 展示失败 / 窗口关闭取消等退出路径据此清理镜像条目
    -- （否则条目永久 pending → Herder pane 一直 blocked）。
    if type(item) == "table" then item.mirror_id = mirror_id end
    -- 弹窗在提交镜像前已同步决策（如 fake UI 在 show 内即回调）：清掉刚建的镜像条目，
    -- 避免悬浮窗残留「待批准」（此处用 hub.clear 不触发 on_decision，防重复决策）。
    if done and mirror_id then
      pcall(hub.clear, mirror_id)
      mirror_id = nil
      if type(item) == "table" then item.mirror_id = nil end
    end
  end
end

--- 串行审批队列：一次只展示一个审批弹窗（单槽位）。
--- 工具执行本身并行，但审批必须串行：并发弹窗会互相覆盖，
--- 前一个的 decision_cb 永不触发 → Deferred 永不 settle → 工具循环挂起。
local function _drain_approval_queue()
  if state.approval_showing then return end
  local item = table.remove(state.approval_queue, 1)
  if not item then return end
  state.approval_showing = true
  state.current_approval = item

  local function _settle()
    state.approval_showing = false
    state.current_approval = nil
  end

  -- 弹窗展示（如浮窗创建）失败时不能阻塞工具循环：释放串行槽位并拒绝该条目，
  -- 该工具以错误结果结束、循环继续执行其余工具。否则 approval_showing 残留 true，
  -- 后续审批只入队不弹窗、对应 Deferred 永不 settle，工具循环永久卡死（"完全无响应"）。
  -- 注意：必须是 pcall 包裹，异常不能向上传播中断 _execute_single 的循环。
  local show_ok, show_err = pcall(_show_approval, item.tool_name, item.args, function(allowed, reason)
    _resolve_approval_item(item, allowed, reason)
    _settle()
    -- 延后到下一个事件循环再弹下一个：审批 UI 的按键回调（如 tool_approval）在
    -- on_confirm() 返回后还会调用 _close()；若这里同步打开下一个弹窗，会被那个
    -- _close() 立即关掉，导致下一个工具的 Deferred 永不 settle，工具循环卡在第一轮。
    vim.schedule(_drain_approval_queue)
  end, item.ctx, item)
  if not show_ok then
    local d = item.d
    item.d = nil
    _settle_blocking(item, false, "审批弹窗展示失败: " .. tostring(show_err))
    if d and d:is_pending() then
      d:reject({ kind = "approval", message = "审批弹窗展示失败: " .. tostring(show_err) })
    end
    _settle()
    vim.schedule(_drain_approval_queue)
    return
  end

  -- 审批超时兜底：弹窗被覆盖/丢失或用户长时间不响应时，拒绝而不是永久挂起，
  -- 否则工具循环会无限等待（表现为"卡住"）。超时后由 _execute_single 转成工具错误结果。
  -- 条目一旦决策（item.d = nil），超时即失效，不干扰已批准工具的执行。
  -- 超时也必须结算阻塞账目并清掉审批中心镜像条目：否则 Herder 侧计数永久 +1、
  -- 悬浮窗残留「待批准」，pane 停在「等待确认」不回「运行中」。
  local timeout_ms = config_store.get("tools.approval.timeout_ms")
  if timeout_ms and timeout_ms > 0 then
    vim.defer_fn(function()
      if not item.d then return end -- 已决策，跳过
      if approval_ui and approval_ui.hide then
        pcall(approval_ui.hide)
      end
      local d = item.d
      item.d = nil
      _settle_blocking(item, false, "工具审批超时: " .. item.tool_name)
      if d and d:is_pending() then
        d:reject({ kind = "approval", message = "工具审批超时: " .. item.tool_name })
      end
      _settle()
      vim.schedule(_drain_approval_queue)
    end, timeout_ms)
  end
end

--- 审批 + 执行
--- @param tool_name string
--- @param args table
--- @param ctx table
--- @param continue_fn function() 返回 Deferred（审批通过后执行）
--- @return Deferred
function M.approve_and_execute(tool_name, args, ctx, continue_fn)
  local d = async.Deferred.new()
  -- 优先取调用方 ctx 指定的模式：无命名空间隔离后端时 executor 会强制 approval_mode="prompt"
  -- （禁用沙箱、退回事前阻塞审批），需覆盖配置里的 async/auto_allow。
  local mode = (ctx and ctx.approval_mode) or _current_mode()

  -- auto_allow 模式直接执行
  if mode == "auto_allow" then
    return continue_fn()
  end

  -- 该工具已 allow_all
  if state.allow_all[tool_name] then
    return continue_fn()
  end

  event_bus.emit(events.TOOL_APPROVAL_REQUESTED, { tool_name = tool_name, args = args, agent_id = ctx.agent and ctx.agent.id })

  -- 入队等待串行审批。工具执行本身并行（tool_loop 并发发起），这里只串行化
  -- "弹窗确认"这一环节：单槽位弹窗一次只展示一个，其余排队，互不覆盖。
  state.approval_queue[#state.approval_queue + 1] = {
    tool_name = tool_name,
    args = args,
    ctx = ctx,
    continue_fn = continue_fn,
    d = d,
  }
  _drain_approval_queue()

  return d
end

-- ========== 公开 API ==========

--- 执行工具（供 Agent tool_loop 调用）
--- @param agent table Agent
--- @param tool_name string
--- @param args table
--- @param tool_call_id string|nil
--- @param opts? table { is_sub_agent?, signal?, sub_agent_id? }
--- @return Deferred resolve(结果), reject(错误)
function M.execute(agent, tool_name, args, tool_call_id, opts)
  opts = opts or {}
  -- 子 Agent 边界审核
  local ok, reason = _review_sub_agent(opts, tool_name)
  if not ok then
    return async.reject({ kind = "boundary", message = "[调度 agent 驳回] 工具 '" .. tool_name .. "' 的调用被拒绝。原因: " .. tostring(reason) })
  end

  -- 计划模式门禁：修改类工具在计划模式下直接驳回
  local plan_mode = require("NeoAI.tools.builtin.plan_mode")
  local pallow, preason = plan_mode.check_tool(agent, tool_name)
  if not pallow then
    return async.reject({ kind = "plan_mode", message = preason })
  end

  -- 子 Agent 的审批申请路由目标：其父（主）Agent。用于非 async 模式下把审批
  -- 归属/事件展示到主 Agent；执行仍使用子 Agent 自身 ctx（cwd/沙箱域不变）。
  local approval_agent = nil
  if opts.is_sub_agent and opts.sub_agent_id then
    local bridge = require("NeoAI.kernel.core_bridge")
    local manager = bridge.sub_agent and bridge.sub_agent()
    local entry = manager and manager.get(opts.sub_agent_id)
    if entry and entry.parent_agent_id and bridge.agent_get then
      approval_agent = bridge.agent_get(entry.parent_agent_id)
    end
  end

  local ctx = {
    agent = agent,
    tool_call_id = tool_call_id,
    signal = opts.signal,
    is_sub_agent = opts.is_sub_agent,
    sub_agent_id = opts.sub_agent_id,
    approval_agent = approval_agent,
    tool_service = M,
    approval_mode = _current_mode(),
    timer = opts.timer, -- 可暂停计时器（tool_loop 注入，用于展示活跃耗时并排除等待时间）
    -- 会话绑定工作目录：工具/沙箱以该会话记录的工作区为基准（不跟随编辑器当前 cwd）。
    cwd = agent and agent.cwd or nil,
    sandbox_exec_cwd = agent and agent.cwd or nil,
  }

  -- UI-only 通知（如沙箱降级提示）：执行完成后经 opts 回传 tool_loop，作为工具结果的
  -- 附加元数据展示，**不进入模型上下文**。
  local d = executor.execute(tool_name, args, ctx)
  local out = async.Deferred.new()
  local function _settle(success, v)
    if opts.ui_notice == nil and ctx.ui_notice ~= nil then opts.ui_notice = ctx.ui_notice end
    -- 内核观测到的密钥文件访问（eBPF/strace/procfs）：仅 UI 展示，不进入模型上下文。
    if opts.observed_secret_paths == nil and ctx.observed_secret_paths ~= nil then
      opts.observed_secret_paths = ctx.observed_secret_paths
    end
    if success then out:resolve(v) else out:reject(v) end
  end
  d:then_(function(v) _settle(true, v) end, function(e) _settle(false, e) end)
  return out
end

--- 拒绝队列中所有待审批工具（窗口关闭/取消）。
--- 必须 reject 挂起的 Deferred 并释放串行槽位，否则工具循环会永久挂起；
--- 同时为每一条已发过 TOOL_APPROVAL_REQUESTED 的条目补发终局事件并清理审批中心镜像条目，
--- 否则 Herder 侧的 blocked 计数永久残留（pane 停在「等待确认」不回「运行中」）。
function M.clear_approval()
  if state.current_approval then
    local item = state.current_approval
    _settle_blocking(item, false, "审批已取消（窗口关闭）")
    if item.d and item.d:is_pending() then
      item.d:reject({ kind = "approval", message = "审批已取消（窗口关闭）" })
    end
    item.d = nil
  end
  for _, item in ipairs(state.approval_queue) do
    _settle_blocking(item, false, "审批已取消（窗口关闭）")
    if item.d and item.d:is_pending() then
      item.d:reject({ kind = "approval", message = "审批已取消（窗口关闭）" })
    end
    item.d = nil
  end
  state.approval_queue = {}
  state.current_approval = nil
  state.approval_showing = false
  if approval_ui and approval_ui.hide then
    pcall(approval_ui.hide)
  end
end

--- 是否有待审批
--- @return boolean
function M.has_pending_approval()
  return #state.approval_queue > 0 or state.approval_showing
end

--- 设置某个工具为始终允许（运行期，仅本会话内存态）。
--- 置 true 时会立即放行审批队列中已排队的同名工具（不再逐个弹窗）。
--- @param tool_name string
--- @param allow boolean
function M.set_allow_all(tool_name, allow)
  _set_allow_all(tool_name, allow)
end

--- 某工具是否已「本次会话允许」
--- @param tool_name string
--- @return boolean
function M.get_allow_all(tool_name)
  return state.allow_all[tool_name] == true
end

--- 列出本次会话允许的工具名（浅拷贝数组，按名称排序）
--- @return string[]
function M.list_allow_all()
  local out = {}
  for name in pairs(state.allow_all) do out[#out + 1] = name end
  table.sort(out)
  return out
end

--- 重置（测试用）
function M.reset()
  state.approval_queue = {}
  state.current_approval = nil
  state.approval_showing = false
  state.allow_all = {}
end

return M
