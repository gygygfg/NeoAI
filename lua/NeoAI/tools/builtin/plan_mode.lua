--- 计划模式
--- @module 'NeoAI.tools.builtin.plan_mode'
--- 计划模式作为 per-agent 状态（logged）：
--- 1. 异步沙箱草稿模式（默认）：只调研/查明原因、不修复；写类工具可用，但写入只进沙箱暂存、
---    不进审批、退出计划模式自动丢弃；同时按能力上限拒绝宿主级/未受信工具（见 filter_capabilities）。
--- 2. 无异步暂存（非 async / 无隔离后端）：工具上下文收敛为只读/信息查询 + run_command + ask_user，
---    执行期门禁同步收紧（visible_names/check_tool）。
--- 3. 策略文本经运行时上下文快照注入历史（系统提示保持稳定）。
--- 计划经用户确认（chat_service.approve_plan）后转入 CHAT 模式（草稿丢弃），
--- 并把计划解析为任务清单（todo）供执行阶段使用。状态持久化在 session.metadata.plan。

local config_store = require("NeoAI.kernel.config_store")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")
local helpers = require("NeoAI.tools.builtin.tool_helpers")
local stringx = require("NeoAI.utils.stringx")

local M = {}

-- ========== 私有常量 ==========

--- 计划模式策略段：异步沙箱草稿模式（写入暂存、退出丢弃）。
local PLAN_POLICY_STAGING = table.concat({
  "## 计划模式（诊断）",
  "用户要求：尽快查明原因/现状，**不要修复**。",
  "- 文件改动只会进入沙箱暂存：不会写入真实工作区、不会进入审批队列，退出计划模式时自动丢弃。",
  "- 计划模式不提供宿主级操作（SSH/主机提权/长驻服务）与未标记 plan-safe 的 MCP/外部工具。",
  "- 结束时用简洁正文给出结论、证据（文件:行）；如需后续修复，可附一份简短改动清单。",
}, "\n")

--- 计划模式策略段：无异步暂存时保持只读工具集（与真实能力一致）。
local PLAN_POLICY_READONLY = table.concat({
  "## 计划模式（只读）",
  "当前无异步沙箱暂存，工具集已收敛为只读/信息查询类（含 run_command 做只读调研）。",
  "用户要求：尽快查明原因/现状，**不要修复**。",
  "- 结束时用简洁正文给出结论、证据（文件:行）；如需后续修复，可附一份简短改动清单。",
}, "\n")

--- 草稿模式（异步沙箱）下的能力上限：显式拒绝「无法被沙箱暂存/丢弃」的宿主级工具。
local PLAN_STAGING_DENY = {
  ssh_run = true,
  ssh_tunnel = true,
  service_start = true,
  service_stop = true,
}

--- 草稿模式允许的工具类别（未知类别默认拒绝；外部/自定义工具需显式加入 extra_safe_tools）。
--- 注：`editor`（nvim 镜像控制）默认不放行——计划模式只做调研，不需要控制编辑器；
--- 确需时用 `tools.plan_mode.extra_safe_tools = { "nvim" }` 显式加入。
local PLAN_STAGING_CATEGORIES = {
  file = true,
  system = true, -- run_command / git_* 之外的 system 工具（ssh/service 已按名拒绝）
  git = true,
  treesitter = true,
  lsp = true,
  log = true,
  agent = true, -- ask_user / todo_* / 子 Agent 调度
  web = true,
  skill = true,
}

--- 计划模式下可见的只读/信息查询工具白名单
--- （无异步暂存时使用；修改类、系统命令、子 Agent 派生等均不在此列）
local PLAN_SAFE_TOOLS = {
  -- 文件读取 / 搜索
  "read_file", "list_files", "search_files", "file_exists",
  "read_image",
  -- 网页搜索/抓取（只读、信息获取；仅 DeepSeek provider 暴露）
  "web_search", "web_fetch",
  -- 语法树只读查询
  "parse_file", "query_tree", "get_node_at_position", "get_node_type",
  "get_node_range", "is_named_node", "get_parent_node", "get_child_nodes",
  "get_node_code",
  -- LSP 只读查询
  "lsp_hover", "lsp_definition", "lsp_references", "lsp_implementation",
  "lsp_declaration", "lsp_document_symbols", "lsp_workspace_symbols",
  "lsp_diagnostics", "lsp_client_info", "lsp_signature_help",
  "lsp_completion", "lsp_type_definition", "lsp_service_info",
  -- Git 只读查询
  "git_status", "git_diff", "git_log", "git_commit_detail",
  "git_branch", "git_file_history",
  -- 日志
  "log_message", "get_log_levels",
  -- 子 Agent 状态查询（只读）
  "get_sub_agent_status",
  -- 子 Agent 控制 / 对话（回答子 Agent 提问统一用 send_sub_agent_message）
  "cancel_sub_agent",
  "send_sub_agent_message",
}

--- 计划模式下附加可见工具（非只读类，需显式加入）
--- 注意：不提供任何「切换模式」工具（如 exit_plan_mode）。计划完成后由用户手动确认执行，
--- 避免 AI 自行调用工具退出计划模式并立即开始改动。
local PLAN_EXTRA_TOOLS = {
  "ask_user", -- 向用户提问
  -- 外部命令：用于只读调研（查看版本/依赖/构建配置/git 等）。写命令在草稿模式下只进暂存，
  -- 计划模式策略要求仅执行只读命令；只读模式（无异步暂存）下可见集之外的工具会被驳回。
  "run_command",
}

-- ========== 私有函数 ==========

--- 读取配置
--- @return table
local function _cfg()
  return config_store.get("tools.plan_mode") or {}
end

--- 计划模式状态已改由「运行时上下文快照」注入历史（见 core/session/runtime_context），
--- 不再注册系统提示段：系统提示必须逐字节稳定，否则计划模式切换会让前缀缓存失效。
--- 保留 _apply_section 仅为兼容旧调用（no-op）。
--- 保留签名 `(agent, active)`：旧调用方仍以此形式传入，函数本身 no-op。
local function _apply_section(_, _)
  -- no-op：系统提示段已废弃，改用运行时上下文快照
end

--- 测试钩子：强制草稿模式开关（nil = 按真实配置探测）。
local _staging_override = nil

--- 暂存探测缓存：`_staging_active` 会在每次请求/工具调用被查询，而 effective_approval_mode
--- 在无强制层时会写 WARN 日志；短 TTL 避免重复探测与刷屏（配置/环境变化在 1s 内生效）。
local _staging_cache = { at = 0, value = false }

--- 当前是否「异步沙箱暂存」生效：此时计划模式不再靠工具白名单做只读，
--- 写入只进暂存、退出丢弃。只要有一项不成立就退回只读白名单（绝不假装有暂存）。
--- @return boolean
local function _compute_staging_active()
  local cfg = config_store.get("tools.sandbox") or {}
  if cfg.enabled == false then return false end
  if (config_store.get("tools.approval.mode") or "async") ~= "async" then return false end
  local ok_svc, services = pcall(require, "NeoAI.kernel.services")
  if not ok_svc or not services or not services.use("services.sandbox") then return false end
  local ok_rt, rt = pcall(require, "NeoAI.sandbox.execution.runtime")
  if not ok_rt or not rt or type(rt.isolation_available) ~= "function" then return false end
  local ok_iso, iso = pcall(rt.isolation_available)
  if not ok_iso or not iso then return false end
  -- 无动态强制层 / 无后端时 executor 会把 async 强制退回 prompt：此时仍按只读处理。
  local ok_ex, executor = pcall(require, "NeoAI.tools.executor")
  if ok_ex and executor and type(executor.effective_approval_mode) == "function" then
    local ok_eff, eff = pcall(executor.effective_approval_mode, "async")
    if ok_eff and eff and eff.mode ~= "async" then return false end
  end
  return true
end

--- @return boolean
local function _staging_active()
  if _staging_override ~= nil then return _staging_override == true end
  local now = vim.uv.now()
  if now - _staging_cache.at < 1000 then return _staging_cache.value end
  local v = _compute_staging_active()
  _staging_cache.at = now
  _staging_cache.value = v
  return v
end

--- 计划模式策略段文本（供运行时上下文快照复用；随暂存是否生效变化）。
--- @return string
function M.policy_text()
  return _staging_active() and PLAN_POLICY_STAGING or PLAN_POLICY_READONLY
end

--- 是否处于「异步沙箱草稿」模式（供测试/诊断）。
--- @return boolean
function M.staging_active()
  return _staging_active()
end

--- 测试钩子：覆盖暂存探测（nil 恢复真实探测）。
--- @param v boolean|nil
function M._set_staging_active_for_test(v)
  _staging_override = v
end

-- ========== 公开 API ==========

--- 是否处于计划模式
--- @param agent table
--- @return boolean
function M.is_active(agent)
  return agent and agent.plan_mode == true
end

--- 计划模式草稿作用域 id（无暂存/未激活返回 nil）
--- @param agent table|nil
--- @return string|nil
function M.plan_scope(agent)
  return agent and agent._plan_scope_id or nil
end

--- 计划模式草稿的能力上限过滤（子 Agent 也复用：它们继承父 scope）。
--- 与只读白名单不同：这里**允许写类工具**（写入由沙箱暂存并在退出时丢弃），
--- 只拒绝无法被暂存/丢弃的宿主级能力与未受信工具。
--- @param tools table name -> def
--- @return table name -> def
function M.filter_capabilities(tools)
  local extra = {}
  for _, name in ipairs(_cfg().extra_safe_tools or {}) do
    if type(name) == "string" and name ~= "" then extra[name] = true end
  end
  local out = {}
  for name, tool in pairs(tools or {}) do
    local keep = false
    if extra[name] then
      keep = true
    elseif PLAN_STAGING_DENY[name] then
      keep = false
    elseif tool and tool.source == "mcp" then
      keep = tool.mcp_plan_safe == true
    elseif tool and PLAN_STAGING_CATEGORIES[tool.category or "other"] then
      keep = true
    end
    if keep then out[name] = tool end
  end
  return out
end

--- 在当前 scope 内开始记录草稿（仅暂存生效时）。
--- @param agent table
local function _begin_scope(agent)
  if not _staging_active() then return end
  local scope = "plan:" .. tostring(agent.id)
  agent._plan_scope_id = scope
  local ok_svc, services = pcall(require, "NeoAI.kernel.services")
  local sb = ok_svc and services and services.use("services.sandbox") or nil
  if sb and type(sb.plan_scope_begin) == "function" then
    pcall(sb.plan_scope_begin, scope, agent.id)
  end
  -- 进入计划模式前已存在的子 Agent 也纳入 scope：防止 send 指令驱动老 child 产生「正常待审」写入。
  pcall(function()
    local bridge = require("NeoAI.kernel.core_bridge")
    local mgr = bridge.sub_agent and bridge.sub_agent()
    if not (mgr and mgr.list_for and bridge.agent_get) then return end
    for _, entry in ipairs(mgr.list_for(agent.id) or {}) do
      local child = entry.agent_id and bridge.agent_get(entry.agent_id)
      if child then child._plan_scope_id = scope end
    end
  end)
end

--- 结束 scope 并丢弃草稿（仅 scope owner 生效）。
--- @param agent table
local function _end_scope(agent)
  local scope = agent and agent._plan_scope_id or nil
  if agent then agent._plan_scope_id = nil end
  if not scope then return end
  local ok_svc, services = pcall(require, "NeoAI.kernel.services")
  local sb = ok_svc and services and services.use("services.sandbox") or nil
  if not (sb and type(sb.plan_scope_discard) == "function") then return end
  local ok, stats = pcall(sb.plan_scope_discard, scope, "plan_exit")
  if ok and stats then
    local n = (stats.discarded or 0) + (stats.restored or 0)
    if n > 0 or (stats.skipped or 0) > 0 then
      pcall(vim.notify, ("[NeoAI] 计划模式暂存的 %d 处改动已丢弃%s"):format(
        n,
        (stats.skipped or 0) > 0 and ("（%d 处因已被其它操作改动而跳过）"):format(stats.skipped) or ""),
        vim.log.levels.INFO)
    end
  end
end

--- 确保活跃的计划草稿 scope 存在（懒启动/session 恢复时 sandbox 可能晚于 plan_mode 启动）。
--- @param agent table|nil
function M.ensure_scope(agent)
  if not agent or not M.is_active(agent) then return end
  if not _staging_active() then return end
  if agent._plan_scope_id and _scope_active(agent) then return end
  _begin_scope(agent)
end

--- 进入计划模式
--- @param agent table
--- @return boolean 是否成功
function M.enter(agent)
  if not agent then return false end
  -- 幂等：已在计划模式时不要重建 scope（会丢掉已登记的草稿且无法恢复旧待审内容）。
  if agent.plan_mode == true then
    M.ensure_scope(agent)
    return true
  end
  -- 互斥：进入计划模式时退出高权限模式（会触发 PRIVILEGED_MODE_CHANGED）。
  local privileged_mode = require("NeoAI.tools.builtin.privileged_mode")
  if privileged_mode.is_active(agent) then privileged_mode.exit(agent) end
  agent.plan_mode = true
  -- 记录进入计划模式时的消息数，供 plan_distill 切分「计划阶段调研窗口」。
  agent._plan_enter_index = #(agent.messages or {})
  -- 新一轮计划：重置「本次 plan 已蒸馏」标记，允许从 plan 切到其它模式时再次蒸馏。
  agent._plan_distilled = false
  _begin_scope(agent)
  _apply_section(agent, true)
  event_bus.emit(events.PLAN_MODE_CHANGED, { agent_id = agent.id, active = true })
  return true
end

--- 退出计划模式（转入 CHAT 模式；草稿自动丢弃）
--- @param agent table
--- @return boolean
function M.exit(agent)
  if not agent then return false end
  _end_scope(agent)
  agent.plan_mode = false
  _apply_section(agent, false)
  event_bus.emit(events.PLAN_MODE_CHANGED, { agent_id = agent.id, active = false })
  return true
end

--- 切换计划模式
--- @param agent table
--- @return boolean 切换后的状态
function M.toggle(agent)
  if M.is_active(agent) then
    M.exit(agent)
    return false
  end
  M.enter(agent)
  return true
end

--- 恢复计划模式状态（加载会话时）
--- @param agent table
--- @param state table|nil { active?, plan? }
function M.restore(agent, state)
  if not agent or not state then return end
  agent.plan = state.plan
  if state.active then
    -- 计划模式与高权限模式互斥：历史元数据若同时为 true，计划模式优先。
    local privileged_mode = require("NeoAI.tools.builtin.privileged_mode")
    if privileged_mode.is_active(agent) then privileged_mode.exit(agent) end
    agent.plan_mode = true
    M.ensure_scope(agent)
    _apply_section(agent, true)
  end
end

--- 该 Agent 是否处于某个**活跃**计划草稿作用域（本体在计划模式，或作为子 Agent 继承父 scope）。
--- @param agent table|nil
--- @return boolean
local function _scope_active(agent)
  local scope = agent and agent._plan_scope_id or nil
  if not scope then return false end
  local ok, services = pcall(require, "NeoAI.kernel.services")
  local sb = ok and services and services.use("services.sandbox") or nil
  if not (sb and type(sb.plan_scope_active) == "function") then return false end
  local ok_a, active = pcall(sb.plan_scope_active, scope)
  return ok_a and active == true
end

--- 计划模式下可见的工具名集合（含配置扩展）
--- @param agent table
--- @return table|nil 可见工具名集合（非计划模式返回 nil = 不限制）
function M.visible_names(agent)
  local in_scope = _scope_active(agent)
  if not M.is_active(agent) and not in_scope then return nil end
  -- 异步沙箱草稿：能力上限（允许写类工具，拒绝宿主级/未受信能力），不再强制只读。
  if _staging_active() and (M.is_active(agent) or in_scope) then
    local set = {}
    for name in pairs(M.filter_capabilities(require("NeoAI.tools.registry").list_as_map())) do
      set[name] = true
    end
    return set
  end
  local cfg = _cfg()
  local extra = cfg.extra_safe_tools or {}
  local set = {}
  for _, name in ipairs(PLAN_SAFE_TOOLS) do set[name] = true end
  for _, name in ipairs(PLAN_EXTRA_TOOLS) do set[name] = true end
  for _, name in ipairs(extra) do
    if type(name) == "string" and name ~= "" then set[name] = true end
  end
  -- MCP 服务器明确声明 plan_safe 的工具：在计划模式下也可用（只读调研场景）
  for name, tool in pairs(require("NeoAI.tools.registry").list_as_map()) do
    if tool.source == "mcp" and tool.mcp_plan_safe then
      set[name] = true
    end
  end
  return set
end

--- 应用计划模式工具过滤：非计划模式原样返回；计划模式只保留可见集
--- @param agent table
--- @param tools table name -> def
--- @return table name -> def
function M.apply_tool_filter(agent, tools)
  local visible = M.visible_names(agent)
  if not visible then return tools end
  local out = {}
  for name, tool in pairs(tools or {}) do
    if visible[name] then
      out[name] = tool
    end
  end
  return out
end

--- 指定工具在计划模式下是否可见
--- @param agent table
--- @param tool_name string
--- @return boolean
function M.is_visible(agent, tool_name)
  local visible = M.visible_names(agent)
  if not visible then return true end
  return visible[tool_name] == true
end

--- 指定工具是否属于修改类（兼容保留，旧配置 mutating_tools 仍生效）
--- @param tool_name string
--- @return boolean
function M.is_mutating(tool_name)
  local cfg = _cfg()
  local list = cfg.mutating_tools or {}
  for _, t in ipairs(list) do
    if t == tool_name then return true end
  end
  return false
end

--- 校验工具调用是否被计划模式阻止
--- 计划模式下只允许可见集（只读/信息查询 + ask_user）内的工具
--- @param agent table
--- @param tool_name string
--- @return boolean allowed, string|nil reason
function M.check_tool(agent, tool_name)
  if not M.is_active(agent) and not _scope_active(agent) then return true end
  if not M.is_visible(agent, tool_name) then
    local why = _staging_active()
      and "计划模式不提供该能力（宿主级操作/长驻服务/未受信 MCP 或外部工具）"
      or "计划模式当前为只读工具集"
    return false, ("[计划模式] 工具 '%s' 不可用：%s。请只做调研与诊断，必要时用 ask_user 澄清。"):format(
      tool_name, why)
  end
  return true
end

--- 清理 agent 级状态（销毁时；草稿由 scope owner 丢弃）
--- @param agent table
function M.cleanup(agent)
  if not agent then return end
  if agent.plan_mode == true and agent._plan_scope_id and agent._plan_scope_id == ("plan:" .. tostring(agent.id)) then
    _end_scope(agent)
  else
    agent._plan_scope_id = nil
  end
  if agent._plan_section then
    pcall(agent._plan_section)
    agent._plan_section = nil
  end
end

--- 把格式化计划文本解析为任务清单（todo 项数组）
--- 识别：任务清单项（- [ ]）、无序/有序列表项；失败时回退到 Markdown 标题；再失败则整段压缩为一项
--- @param plan_text string
--- @return table 数组 { content, status }
function M.plan_to_todos(plan_text)
  if type(plan_text) ~= "string" or plan_text == "" then return {} end
  local items = {}
  local seen = {}
  local in_fence = false
  local lines = vim.split(plan_text, "\n", { plain = true })
  for _, raw in ipairs(lines) do
    local line = raw:gsub("\r$", "")
    if line:match("^```") then in_fence = not in_fence end
    local content = nil
    if not in_fence then
      -- 注意：任务清单项模式有两个捕获组（勾选标记 + 内容），只取内容
      local _, checklist = line:match("^%s*%- %[([ xX]?)%]%s*(.+)$")
      if checklist then
        content = checklist
      else
        local bullet = line:match("^%s*[-*+]%s+(.+)$")
        if bullet then content = bullet end
        local numbered = line:match("^%s*%d+[%.)]%s+(.+)$")
        if numbered then content = numbered end
      end
    end
    if content then
      content = stringx.trim(content)
      if content ~= "" and not seen[content] then
        seen[content] = true
        items[#items + 1] = { content = content, status = "pending" }
      end
    end
  end
  if #items == 0 then
    -- 回退：按 Markdown 标题分段（Lua 5.1 模式不支持 {n,m} 量词，用 #+）
    local headers = {}
    for _, raw in ipairs(lines) do
      local h = raw:match("^%s*#+%s+(.+)$")
      if h then
        h = stringx.trim(h)
        if h ~= "" then headers[#headers + 1] = h end
      end
    end
    for _, h in ipairs(headers) do
      if not seen[h] then
        seen[h] = true
        items[#items + 1] = { content = h, status = "pending" }
      end
    end
  end
  if #items == 0 then
    -- 最终回退：整段压缩为一项
    local flat = plan_text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if #flat > 200 then flat = stringx.safe_truncate(flat, 200, "…") or flat end
    if flat ~= "" then
      items[#items + 1] = { content = flat, status = "pending" }
    end
  end
  return items
end

-- ========== 工具定义 ==========

local plan_mode_tools = {}

plan_mode_tools.enter_plan_mode = helpers.define_tool(
  "enter_plan_mode",
  "进入计划模式：只做调研/查明原因，不修复。异步沙箱下仍可用全部调研与写类工具，"
    .. "但改动只进沙箱暂存、不进审批、退出计划模式自动丢弃；无异步沙箱时工具集收敛为只读。",
  {
    type = "object",
    properties = {},
    required = {},
  },
  function(_, on_success, on_error, ctx)
    local agent = ctx and ctx.agent
    if not agent then
      on_error("缺少 agent 上下文")
      return
    end
    M.enter(agent)
    on_success("已进入计划模式：只读调研 + 提问，输出格式化计划，等待用户确认后执行。")
  end,
  { category = "agent", approval = { auto_allow = true } }
)

-- 说明：不再向 AI 暴露 exit_plan_mode 等模式切换工具。计划完成后由用户手动确认执行
-- （:NeoAI ApprovePlan 或手动切换模式），避免 AI 自行退出计划模式并立即开始改动。

-- ========== 测试辅助 ==========

--- 重置（测试用）
function M.reset()
  -- 状态挂在 agent 上；仅清测试钩子与探测缓存。
  _staging_override = nil
  _staging_cache = { at = 0, value = false }
end

--- 获取工具列表
--- @return table 数组
function M.get_tools()
  local out = {}
  for _, tool in pairs(plan_mode_tools) do
    out[#out + 1] = tool
  end
  return out
end

return M
