--- L3 危险操作后果警告生成
--- @module NeoAI.sandbox.l3_warning
--- 待审界面确认 L3（critical）变更时，调用模型生成一条简洁的中文后果警告，
--- 展示在修改 diff 预览顶部，供用户二次确认。模型不可用/超时/未配置 provider 时，
--- 由调用方回退到 `M.fallback()` 的确定性规则警告，不阻断流程。
---
--- `M.set_generator(fn)` 可注入测试用生成器，避免离线环境发起真实请求。

local config_store = require("NeoAI.kernel.config_store")

local M = {}

-- ========== 私有状态 ==========

local state = {
  generator = nil, -- 测试注入：function(item, target, on_done)
}

local SYSTEM_PROMPT = table.concat({
  "你是代码变更安全审查助手。用户即将把一个高风险（L3 严重）的沙箱变更应用到真实文件系统。",
  "请用简体中文给出一条简洁的后果警告，2-4 句，直接说明该操作可能造成的不可逆后果与需要特别注意的风险点。",
  "不要客套、不要复述文件内容、不要使用 Markdown 标题或列表，只输出警告正文。",
}, "\n")

-- ========== 私有函数 ==========

--- 汇总变更涉及的真实路径
--- @param item table 待审条目
--- @return table 路径数组
local function _paths(item)
  local out = {}
  for _, p in ipairs((item and item.write_set) or {}) do out[#out + 1] = tostring(p) end
  if #out == 0 then
    for _, f in ipairs((item and item.files) or {}) do
      if f.path then out[#out + 1] = tostring(f.path) end
    end
  end
  return out
end

--- 构造供模型判断的描述文本（确定性、不含原始密钥）
--- @param item table
--- @param target table
--- @return string
local function _description(item, target)
  local lines = {}
  lines[#lines + 1] = "工具: " .. tostring(item.tool or "?")
  local reasons = table.concat(item.risk_reasons or {}, ", ")
  lines[#lines + 1] = string.format("风险级别: %s%s",
    tostring(item.risk_name or "critical"),
    reasons ~= "" and ("（" .. reasons .. "）") or "")
  local paths = _paths(item)
  if #paths > 0 then lines[#lines + 1] = "涉及路径: " .. table.concat(paths, ", ") end
  for _, f in ipairs(item.files or {}) do
    lines[#lines + 1] = string.format("- %s (%s)", tostring(f.path or "?"), tostring(f.action or "modify"))
  end
  if target and target.path then lines[#lines + 1] = "本次应用文件: " .. tostring(target.path) end
  if item.secret_warning and (item.secret_warning.count or 0) > 0 then
    lines[#lines + 1] = "注意: 该变更涉及密钥/敏感凭据"
  end
  return table.concat(lines, "\n")
end

-- ========== 公开 API ==========

--- 确定性规则兜底警告（模型不可用时使用）
--- @param item table
--- @param target table
--- @return string
function M.fallback(item, target)
  item = item or {}
  local reasons = table.concat(item.risk_reasons or {}, ", ")
  local paths = _paths(item)
  local parts = {}
  parts[#parts + 1] = string.format("该操作为 L3 严重风险（%s）。", reasons ~= "" and reasons or "critical")
  if #paths > 0 then
    parts[#parts + 1] = "影响路径: " .. table.concat(paths, ", ") .. "。"
  end
  if target and target.path then
    parts[#parts + 1] = "将写入: " .. tostring(target.path) .. "。"
  end
  parts[#parts + 1] = "应用后可能对系统或用户数据造成不可逆改动，请确认确有必要。"
  return table.concat(parts, "")
end

--- 构造请求消息（供测试/复用）
--- @param item table
--- @param target table
--- @return table messages
function M.build_messages(item, target)
  return {
    { role = "system", content = SYSTEM_PROMPT },
    { role = "user", content = _description(item, target) },
  }
end

--- 异步生成后果警告。成功时 on_done(text)；失败时 on_done(nil)，由调用方回退。
--- @param item table
--- @param target table
--- @param on_done function(text|nil)
function M.generate(item, target, on_done)
  on_done = on_done or function() end
  if type(state.generator) == "function" then
    local ok = pcall(state.generator, item, target, on_done)
    if not ok then on_done(nil) end
    return
  end
  local cfg = config_store.get("tools.sandbox.review.l3_warning") or {}
  local ok, d = pcall(function()
    local request = require("NeoAI.core.agent.request")
    return request.send(M.build_messages(item, target), {
      temperature = 0.2,
      max_tokens = cfg.max_tokens or 256,
      max_retries = 0,
      timeout_ms = cfg.timeout_ms or 15000,
    })
  end)
  if not ok or not d or type(d.then_) ~= "function" then
    on_done(nil)
    return
  end
  d:then_(function(resp)
    local content = resp and resp.content or nil
    if type(content) == "string" and content:gsub("%s", "") ~= "" then
      on_done(content)
    else
      on_done(nil)
    end
  end, function()
    on_done(nil)
  end)
end

--- 注入测试用生成器（nil 恢复默认）
--- @param fn function|nil
function M.set_generator(fn)
  state.generator = fn
end

--- 重置（测试用）
function M.reset()
  state.generator = nil
end

return M
