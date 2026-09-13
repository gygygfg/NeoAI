--- 技能工具（list_skills / load_skill）
--- @module NeoAI.tools.builtin.skills
--- 把「技能目录 SKILL.md + load_skill 工具」模型落地：
--- 1. 注册系统提示段 deployment:skills（order=90，工具指引之前）列出可用技能；
--- 2. list_skills：列出技能；load_skill：装载某技能正文给模型（可选持久化为 agent 级段）。

local helpers = require("NeoAI.tools.builtin.tool_helpers")
local config_store = require("NeoAI.kernel.config_store")
local prefix = require("NeoAI.core.agent.prefix")
local services = require("NeoAI.kernel.services")

local M = {}

-- ========== 私有常量 ==========

local SECTION_ORDER = 90

-- ========== 私有状态 ==========

local section_registered = false
local section_unregister = nil

-- ========== 私有函数 ==========

--- 注册系统提示段（幂等；动态文本随索引变化重算；避免 reload 时重复注册抛错）
local function _ensure_section()
  if section_registered then return end
  section_registered = true
  local ok, unreg = pcall(prefix.register_section, "deployment:skills", SECTION_ORDER, function()
    local skills = services.use("services.skills")
    return skills and skills.summary_text() or ""
  end)
  if ok then section_unregister = unreg end
end

--- 持久化已装载技能为 agent 级提示段（config.skills.persist_loaded）
--- @param ctx table
--- @param skill table|nil
local function _persist_agent_section(ctx, skill)
  if not ctx or not ctx.agent or not skill then return end
  local cfg = config_store.get("skills") or {}
  if not cfg.persist_loaded then return end
  pcall(prefix.register_agent_section, ctx.agent, "agent:skill:" .. skill.name, 95, function()
    return ("## 已装载技能：%s\n\n%s"):format(skill.name, skill.content)
  end)
end

-- ========== 工具定义 ==========

local skill_tools = {}

skill_tools.list_skills = helpers.define_tool(
  "list_skills",
  "列出当前可用的技能（Skills）。当任务匹配某技能时应先调用 load_skill 装载其内容。",
  {
    type = "object",
    properties = {},
    required = {},
  },
  function(args, on_success, on_error)
    local skills = services.use("services.skills")
    if not skills then
      on_error("技能服务未启用")
      return
    end
    local list = skills.list()
    if #list == 0 then
      on_success("（当前没有已发现的可加载技能）")
      return
    end
    local lines = {}
    for _, s in ipairs(list) do
      local desc = (s.description and s.description ~= "") and s.description or "（无描述）"
      lines[#lines + 1] = string.format("- %s: %s", s.name, desc)
    end
    on_success(table.concat(lines, "\n"))
  end,
  { category = "skill", approval = { auto_allow = true } }
)

skill_tools.load_skill = helpers.define_tool(
  "load_skill",
  "装载一个技能（Skills）的完整内容（SKILL.md 正文），用于获取针对特定任务的步骤式指引。name 必填（来自 list_skills / 系统提示中的技能清单）。",
  {
    type = "object",
    properties = {
      name = { type = "string", description = "技能名称" },
    },
    required = { "name" },
  },
  function(args, on_success, on_error, ctx)
    local name = args.name
    if not name or name == "" then
      on_error("load_skill 缺少必填参数 name")
      return
    end
    local skills = services.use("services.skills")
    if not skills then
      on_error("技能服务未启用")
      return
    end
    local skill = skills.load(name)
    if not skill then
      on_error("未知技能: " .. tostring(name) .. "。请先用 list_skills 列出可用技能。")
      return
    end
    _persist_agent_section(ctx, skill)
    -- 正文标题化，便于模型识别装载了哪个技能
    on_success(("已装载技能 %s：\n\n%s"):format(skill.name, skill.content))
  end,
  { category = "skill", approval = { auto_allow = true }, timeout = 15000 }
)

-- ========== 公开 API ==========

--- 获取工具列表
--- @return table 数组
function M.get_tools()
  -- config.skills.register_tools=false 时不注册 list_skills/load_skill 工具
  local cfg = config_store.get("skills") or {}
  if cfg.register_tools == false then return {} end
  _ensure_section()
  local out = {}
  for _, tool in pairs(skill_tools) do
    out[#out + 1] = tool
  end
  return out
end

--- 重置（测试用）：注销提示段，允许重新注册
function M.reset()
  if section_unregister then
    pcall(section_unregister)
    section_unregister = nil
  end
  section_registered = false
end

return M
