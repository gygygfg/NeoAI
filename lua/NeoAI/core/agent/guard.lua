--- 工具循环护栏
--- @module NeoAI.core.agent.guard
--- 对齐 deepseek-harness guard/repeat-tool-reminder：检测 Agent 连续重复的
--- 工具调用（相同工具 + 相同参数），达到阈值时注入提醒 user 消息。
--- observe-and-enrich：只提醒不否决，用户新输入会重置计数链。

local M = {}

-- ========== 私有常量 ==========

local DEFAULT_THRESHOLDS = { 3, 5, 8 }

local DEFAULT_MESSAGES = {
  [3] = "⚠️ 你已连续多次调用同一个工具并使用相同的参数。如果上一次调用没有达到预期效果，请先读取文件/检查输出，改变参数或换一种做法，而不是原样重试。",
  [5] = "⚠️ 你仍在重复调用相同工具与相同参数（第 5 次）。继续这样执行不会产生新结果。请停下来分析原因：查看错误输出、读取相关文件，或向用户询问意图。",
  [8] = "⚠️ 已连续 8 次重复相同的工具调用。循环将不会自动终止，但建议立即改变策略：考虑用不同的工具、不同的参数，或结束本轮并让用户补充说明。",
}

-- ========== 私有函数 ==========

--- 从 tool_call 提取规范化签名（name + 参数指纹）
--- @param tool_call table
--- @return string
local function _call_signature(tool_call)
  local fn = tool_call and tool_call["function"]
  local name = fn and fn.name or "unknown"
  local prefix = require("NeoAI.core.agent.prefix")
  local json = require("NeoAI.utils.json")
  local args = {}
  if fn and fn.arguments then
    local ok, decoded = pcall(json.decode, fn.arguments)
    if ok and type(decoded) == "table" then args = decoded end
  end
  return name .. "::" .. prefix.canonical_json(args)
end

-- ========== 公开 API ==========

--- 重置护栏计数链（用户发送新消息时调用）
--- @param agent table
function M.reset(agent)
  if agent then agent.guard = nil end
end

--- 检查一轮工具调用，返回需要注入的提醒文本（无则 nil）
--- @param agent table
--- @param tool_calls table 本轮待执行的工具调用数组
--- @param cfg table|nil { enabled?, thresholds?, messages? }
--- @return string|nil
function M.check_round(agent, tool_calls, cfg)
  if not agent or not tool_calls or #tool_calls == 0 then return nil end
  cfg = cfg or {}
  if cfg.enabled == false then return nil end

  -- 整轮签名：所有调用按原始顺序拼接（tool_loop 已保证结果按原始顺序回写，
  -- 同一轮内顺序固定，签名确定）
  local sig_parts = {}
  for _, tc in ipairs(tool_calls) do
    sig_parts[#sig_parts + 1] = _call_signature(tc)
  end
  local sig = table.concat(sig_parts, "\n")

  local g = agent.guard or {}
  if g.sig == sig then
    g.repeats = (g.repeats or 1) + 1
  else
    g.sig = sig
    g.repeats = 1
  end
  agent.guard = g

  local thresholds = cfg.thresholds or DEFAULT_THRESHOLDS
  for _, t in ipairs(thresholds) do
    if g.repeats == t then
      local msgs = cfg.messages or DEFAULT_MESSAGES
      return msgs[t] or DEFAULT_MESSAGES[t]
    end
  end
  return nil
end

--- 重置（测试用）
function M.reset_all()
  -- 无模块级状态；guard 挂在 agent 上
end

return M