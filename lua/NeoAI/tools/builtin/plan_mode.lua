--- 计划模式
--- @module NeoAI.tools.builtin.plan_mode
--- 计划模式作为 per-agent 状态（logged），激活时：
--- 1. 注入 plan-policy 系统提示段（要求输出清晰、格式化的修改计划）；
--- 2. 工具上下文只保留「只读/信息查询工具 + ask_user（向用户提问）」，不暴露任何修改类工具；
--- 3. 执行期门禁同步收紧：计划模式下调用可见集之外的任何工具都会被驳回（纵深防御）。
--- 计划经用户确认（chat_service.approve_plan）后直接转入 CHAT 模式，
--- 并把计划解析为任务清单（todo）供执行阶段使用。
--- 状态持久化在 session.metadata.plan（chat_service 同步），恢复会话时还原。

local config_store = require("NeoAI.kernel.config_store")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")
local helpers = require("NeoAI.tools.builtin.tool_helpers")
local stringx = require("NeoAI.utils.stringx")

local M = {}

-- ========== 私有常量 ==========

--- 计划模式策略段（注入系统提示，order=100 工具指引区）
local PLAN_POLICY_TEXT = table.concat({
  "## 计划模式（PLAN MODE）",
  "当前处于计划模式。你的工具上下文只包含只读/信息查询类工具、run_command 与 ask_user（向用户提问），",
  "没有任何修改类工具（编辑/删除/创建文件、git 回滚、重命名/格式化等均不可用）。",
  "run_command 仅可用于**只读调研**（如 ls/cat/rg/git log/查看版本与依赖等），不得用于执行会修改",
  "文件或系统状态的写命令（沙箱会把改动冻结为待审候选，但仍应避免）。",
  "任务流程：",
  "1. 充分调研：读取相关文件、搜索、查看 git 状态 / diff / 诊断信息，必要时用 run_command 执行只读命令，理解现状；",
  "2. 若有歧义或缺少关键信息，用 ask_user 向用户澄清；",
  "3. 最终输出一份清晰、格式化的修改计划，必须包含：",
  "   - 目标与背景（为什么改）",
  "   - 改动清单（涉及的文件 + 每处改动的内容/操作）",
  "   - 实施步骤（先后顺序）",
  "   - 验证方式与回滚方案",
  "4. 输出计划后即结束本轮：不要尝试切换模式或开始执行修改。是否按计划执行由用户决定，",
  "   用户确认（:NeoAIApprovePlan 或手动切换模式）后系统会把计划转为任务清单（todo）并转入执行。",
}, "\n")

--- 计划模式下可见的只读/信息查询工具白名单
--- （修改类、系统命令、子 Agent 调度、待办写入等均不在此列）
local PLAN_SAFE_TOOLS = {
  -- 文件读取 / 搜索
  "read_file", "list_files", "search_files", "file_exists",
  "read_image",
  -- 网页抓取（只读、信息获取）
  "web_fetch",
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
}

--- 计划模式下附加可见工具（非只读类，需显式加入）
--- 注意：不提供任何「切换模式」工具（如 exit_plan_mode）。计划完成后由用户手动确认执行，
--- 避免 AI 自行调用工具退出计划模式并立即开始改动。
local PLAN_EXTRA_TOOLS = {
  "ask_user", -- 向用户提问
  -- 外部命令：用于只读调研（查看版本/依赖/构建配置/git 等）。写命令的改动仍会被沙箱冻结为
  -- 待审候选，但计划模式策略要求仅执行只读命令。
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
--- @param agent table
--- @param active boolean
local function _apply_section(agent, active)
  -- no-op：系统提示段已废弃，改用运行时上下文快照
end

--- 计划模式策略段文本（供运行时上下文快照复用）
--- @return string
function M.policy_text()
  return PLAN_POLICY_TEXT
end

-- ========== 公开 API ==========

--- 是否处于计划模式
--- @param agent table
--- @return boolean
function M.is_active(agent)
  return agent and agent.plan_mode == true
end

--- 进入计划模式
--- @param agent table
--- @return boolean 是否成功
function M.enter(agent)
  if not agent then return false end
  agent.plan_mode = true
  -- 记录进入计划模式时的消息数，供 plan_distill 切分「计划阶段调研窗口」。
  agent._plan_enter_index = #(agent.messages or {})
  -- 新一轮计划：重置「本次 plan 已蒸馏」标记，允许从 plan 切到其它模式时再次蒸馏。
  agent._plan_distilled = false
  _apply_section(agent, true)
  event_bus.emit(events.PLAN_MODE_CHANGED, { agent_id = agent.id, active = true })
  return true
end

--- 退出计划模式（转入 CHAT 模式）
--- @param agent table
--- @return boolean
function M.exit(agent)
  if not agent then return false end
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
    agent.plan_mode = true
    _apply_section(agent, true)
  end
end

--- 计划模式下可见的工具名集合（含配置扩展）
--- @param agent table
--- @return table|nil 可见工具名集合（非计划模式返回 nil = 不限制）
function M.visible_names(agent)
  if not M.is_active(agent) then return nil end
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
  if not M.is_active(agent) then return true end
  if not M.is_visible(agent, tool_name) then
    return false, ("[计划模式] 工具 '%s' 不在计划模式可用工具集内（只允许只读/信息查询工具、run_command 与 ask_user）。请输出格式化修改计划并等待用户确认执行。"):format(tool_name)
  end
  return true
end

--- 清理 agent 级状态（销毁时）
--- @param agent table
function M.cleanup(agent)
  if agent and agent._plan_section then
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
      content = content:gsub("^%s+", ""):gsub("%s+$", "")
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
        h = h:gsub("^%s+", ""):gsub("%s+$", "")
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
    if #flat > 200 then flat = stringx.safe_truncate(flat, 200, "…") end
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
  "进入计划模式：工具集立即切换为只读/信息查询 + ask_user（无法修改任何文件），用于调研并制定格式化修改计划。多步骤/涉及改动的任务应先调用本工具。",
  {
    type = "object",
    properties = {},
    required = {},
  },
  function(args, on_success, on_error, ctx)
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
-- （:NeoAIApprovePlan 或手动切换模式），避免 AI 自行退出计划模式并立即开始改动。

-- ========== 测试辅助 ==========

--- 重置（测试用）
function M.reset()
  -- 无模块级状态；状态挂在 agent 上
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
