--- 运行时上下文快照
--- @module 'NeoAI.core.session.runtime_context'
--- 对齐 deepseek-harness 的 PromptContext：
--- - 系统提示（identity/persona）必须逐字节稳定，才能复用 DeepSeek 前缀缓存；
---   任何易变运行态（当前任务清单 todo、计划模式等）不能放进系统提示，否则改动会让
---   从那个位置起的整段历史缓存失效（命中率骤降）。
--- - 因此把易变运行态渲染成一条「运行时上下文快照」消息追加进历史：
---   快照只在内容变化时才追加新的（newer supersedes older），旧快照永不改写 → 请求保持
---   严格追加扩展（append-extension），系统提示稳定，只有变化的快照尾部短暂失效。
--- - 端点明确支持 messages 中途 system（如部分代理）时才可经 `ai.system_in_history=true` 开启
---   system 角色；默认 user —— DeepSeek 官方模板会把最后一条 system 提到最前，从而替换顶层
---   系统提示并使前缀缓存全量失效。角色只影响单条消息，追加语义不变。

local M = {}

-- ========== 私有常量 ==========

local SNAPSHOT_PREFIX = "当前运行上下文。此快照取代更早的运行上下文快照。"
local CLEARED_TEXT = "当前运行上下文：无。更早的运行上下文快照不再适用。"

-- ========== 私有函数 ==========

--- 解析当前 Agent 的方言，判断快照能否使用 system 角色（默认 user，需显式开启）。
--- @param agent table
--- @return string "system" | "user"
local function _snapshot_role(agent)
  -- 默认 user，且必须显式开启 `ai.system_in_history=true`：DeepSeek 官方 chat template 会把
  -- 所有 system 消息收敛为「**最后一条** system 的内容放在最前」，历史中的 system 快照会整体
  -- 替换顶层系统提示，且每次快照变化都改写请求开头 → 前缀缓存全量失效（多轮命中率骤降）。
  -- user 角色是严格追加扩展：旧消息逐字节不变，快照只在尾部生效，缓存友好。
  local config_store = require("NeoAI.kernel.config_store")
  if config_store.get("ai.system_in_history") ~= true then return "user" end
  local ok, profiles = pcall(require, "NeoAI.core.model.profiles")
  if not ok or not profiles.resolve then return "user" end
  local ac = (agent and agent.config) or {}
  local provider_name = ac.provider or config_store.get("ai.default_provider")
  local provider = provider_name and config_store.get("ai.providers." .. provider_name) or {}
  local model = (agent and agent.model) or ac.model
  if (not model or model == "auto") and provider_name then
    local ok2, registry = pcall(require, "NeoAI.core.model.registry")
    if ok2 and registry.resolve_default then
      local ok3, resolved = pcall(registry.resolve_default, provider_name)
      if ok3 then model = resolved end
    end
  end
  local ok4, dialect = pcall(profiles.resolve, provider_name, provider, model)
  if ok4 and dialect and dialect.system_in_history == true then return "system" end
  return "user"
end

--- 渲染当前运行上下文（todos + 计划模式 + 已装载技能），空则返回 ""
--- @param agent table
--- @return string
local function _render(agent)
  local blocks = {}
  local todo = require("NeoAI.tools.builtin.todo")
  local session_id = (agent and agent.session_id) or (agent and agent.id)
  local todos_text = todo.render(session_id)
  if todos_text and todos_text ~= "" then
    blocks[#blocks + 1] = todos_text
  end
  local plan_mode = require("NeoAI.tools.builtin.plan_mode")
  if plan_mode.is_active(agent) then
    blocks[#blocks + 1] = plan_mode.policy_text()
  end
  -- 已装载技能（skills.persist_loaded）：以快照方式常驻而非改写系统提示——改写系统提示会让
  -- 整段前缀缓存失效（历史每轮全量重算）。按技能名排序保证确定性。
  local sk_cfg = require("NeoAI.kernel.config_store").get("skills") or {}
  if sk_cfg.persist_loaded and agent and agent._loaded_skills then
    local names = {}
    for name in pairs(agent._loaded_skills) do names[#names + 1] = name end
    if #names > 0 then
      table.sort(names)
      local parts = {}
      for _, name in ipairs(names) do
        local body = agent._loaded_skills[name]
        if body and body ~= "" then
          parts[#parts + 1] = ("### 技能 %s\n\n%s"):format(name, body)
        end
      end
      if #parts > 0 then
        blocks[#blocks + 1] = "已常驻技能（已装载，步骤指引随上下文常驻）：\n\n" .. table.concat(parts, "\n\n")
      end
    end
  end
  if #blocks == 0 then return "" end
  return SNAPSHOT_PREFIX .. "\n\n" .. table.concat(blocks, "\n\n")
end

--- 从 agent.messages 中找最后一条运行时上下文快照消息
--- @param agent table
--- @return table|nil
local function _last_snapshot(agent)
  local list = agent and agent.messages
  if not list then return nil end
  for i = #list, 1, -1 do
    if list[i] and list[i].runtime_context then
      return list[i]
    end
  end
  return nil
end

-- ========== 公开 API ==========

--- 渲染运行时上下文文本（供测试/复用）
--- @param agent table
--- @return string
function M.render(agent)
  return _render(agent)
end

--- 判断是否为运行时上下文快照消息
--- @param msg table
--- @return boolean
function M.is_snapshot(msg)
  return msg and msg.runtime_context == true
end

--- 确保快照最新：内容变化时在历史末尾追加一条快照（否则 no-op）。
--- 追加而非改写 → 保持请求为严格追加扩展，前缀缓存稳定。
--- @param agent table
--- @return table|nil 追加的快照消息（无变化返回 nil）
function M.ensure(agent)
  if not agent or not agent.messages then return nil end
  local text = M.render(agent)
  local last = _last_snapshot(agent)
  if text ~= "" then
    if last and last.content == text then return nil end
    local msg = {
      role = _snapshot_role(agent),
      content = text,
      ts = os.time(),
      runtime_context = true,
    }
    table.insert(agent.messages, msg)
    return msg
  end
  -- 无运行态：若历史里已有旧快照，追加一条清除标记（沿用 supersede 语义）
  if last then
    local msg = {
      role = _snapshot_role(agent),
      content = CLEARED_TEXT,
      ts = os.time(),
      runtime_context = true,
    }
    table.insert(agent.messages, msg)
    return msg
  end
  return nil
end

return M
