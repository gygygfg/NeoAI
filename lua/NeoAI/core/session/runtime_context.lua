--- 运行时上下文快照
--- @module NeoAI.core.session.runtime_context
--- 对齐 deepseek-harness 的 PromptContext：
--- - 系统提示（identity/persona）必须逐字节稳定，才能复用 DeepSeek 前缀缓存；
---   任何易变运行态（当前任务清单 todo、计划模式等）不能放进系统提示，否则改动会让
---   从那个位置起的整段历史缓存失效（命中率骤降）。
--- - 因此把易变运行态渲染成一条 user 角色「运行时上下文快照」消息追加进历史：
---   快照只在内容变化时才追加新的（newer supersedes older），旧快照永不改写 → 请求保持
---   严格追加扩展（append-extension），系统提示稳定，只有变化的快照尾部短暂失效。

local M = {}

-- ========== 私有常量 ==========

local SNAPSHOT_PREFIX = "当前运行上下文。此快照取代更早的运行上下文快照。"
local CLEARED_TEXT = "当前运行上下文：无。更早的运行上下文快照不再适用。"

-- ========== 私有函数 ==========

--- 渲染当前运行上下文（todos + 计划模式），空则返回 ""
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
M.render = _render

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
      role = "user",
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
      role = "user",
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
