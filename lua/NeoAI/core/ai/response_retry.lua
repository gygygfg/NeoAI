-- 响应重试模块
-- 负责检测 AI 响应异常（内容重复/截断/空响应）并触发重试
-- 支持指数退避策略：1s, 2s, 4s, 8s, 16s
local M = {}

local logger = require("NeoAI.utils.logger")

-- ========== 配置 ==========

local config = {
  max_retries = 5,
  retry_delays = { 1000, 2000, 4000, 8000, 16000 }, -- 指数退避（毫秒）
}

-- ========== 异常检测 ==========

--- 检测响应文本中是否存在重复段落
--- 策略：将文本按换行分割，检查是否有相同的行/块重复出现
--- @param text string 响应文本
--- @return boolean 是否检测到重复
local function has_repeated_content(text)
  if not text or text == "" then
    return false
  end

  -- 按行分割
  local lines = vim.split(text, "\n")
  if #lines < 3 then
    return false -- 行数太少，无法判断重复
  end

  -- 检查是否有连续重复的行
  for i = 1, #lines - 1 do
    local line = vim.trim(lines[i])
    local next_line = vim.trim(lines[i + 1])
    if line ~= "" and line == next_line then
      logger.debug("[response_retry] 检测到连续重复行: " .. line:sub(1, 50))
      return true
    end
  end

  -- 检查是否有重复的段落（以 ## 开头的标题行重复）
  local headers = {}
  for _, line in ipairs(lines) do
    local trimmed = vim.trim(line)
    if trimmed:match("^##+%s+") then
      if headers[trimmed] then
        logger.debug("[response_retry] 检测到重复标题: " .. trimmed:sub(1, 50))
        return true
      end
      headers[trimmed] = true
    end
  end

  -- 检查是否有大段重复内容（超过 50 个字符的相同行）
  local seen_lines = {}
  for _, line in ipairs(lines) do
    local trimmed = vim.trim(line)
    if #trimmed > 50 then
      if seen_lines[trimmed] then
        logger.debug("[response_retry] 检测到长文本重复行: " .. trimmed:sub(1, 50) .. "...")
        return true
      end
      seen_lines[trimmed] = true
    end
  end

  return false
end

--- 检测响应是否被截断
--- 策略：检查文本是否以不完整的句子/代码块结束
--- @param text string 响应文本
--- @return boolean 是否检测到截断
local function has_truncated_content(text)
  if not text or text == "" then
    return false
  end

  -- 检查代码块是否未闭合
  local open_count = 0
  for match in text:gmatch("```") do
    open_count = open_count + 1
  end
  if open_count % 2 ~= 0 then
    logger.debug("[response_retry] 检测到未闭合的代码块")
    return true
  end

  -- 检查是否以不完整的句子结束（以逗号、连字符、冒号结尾）
  local last_char = text:sub(-1)
  local incomplete_endings = { [","] = true, ["-"] = true, [":"] = true, [";"] = true, ["|"] = true, ["/"] = true, ["\\"] = true }
  if incomplete_endings[last_char] then
    logger.debug("[response_retry] 检测到不完整结尾: '" .. last_char .. "'")
    return true
  end

  -- 检查是否以不完整的 Markdown 语法结束
  if text:match("%[.*$") or text:match("%(.*$") or text:match("!%[.*$") then
    logger.debug("[response_retry] 检测到不完整的 Markdown 语法")
    return true
  end

  return false
end

--- 检测工具调用是否异常
--- 策略：检查工具调用名称是否重复、参数是否为空等
--- @param tool_calls table 工具调用列表
--- @return boolean 是否检测到异常
local function has_abnormal_tool_calls(tool_calls)
  if not tool_calls or #tool_calls == 0 then
    return false
  end

  -- 检查是否有重复的工具调用名称
  local seen_names = {}
  for _, tc in ipairs(tool_calls) do
    local func = tc["function"] or tc.func
    if func and func.name then
      if seen_names[func.name] then
        logger.debug("[response_retry] 检测到重复的工具调用: " .. func.name)
        return true
      end
      seen_names[func.name] = true
    end
  end

  -- 检查是否有空参数的工具调用
  for _, tc in ipairs(tool_calls) do
    local func = tc["function"] or tc.func
    if func then
      local args = func.arguments or ""
      if args == "" or args == "{}" then
        logger.debug("[response_retry] 检测到空参数工具调用: " .. tostring(func.name))
        return true
      end
    end
  end

  return false
end

--- 综合检测响应是否异常
--- @param content string AI 响应文本
--- @param tool_calls table|nil 工具调用列表
--- @param opts table|nil 可选参数
---   - is_tool_loop boolean 是否在工具循环模式中
---   - is_final_round boolean 是否是最终轮次（总结轮次）
--- @return boolean 是否异常
--- @return string|nil 异常原因
function M.detect_abnormal_response(content, tool_calls, opts)
  opts = opts or {}

  -- 最终轮次（总结轮次）：AI 应返回文本总结，不检测空内容
  -- 但仍检测内容重复和截断
  if opts.is_final_round then
    if content and content ~= "" then
      if has_repeated_content(content) then
        return true, "内容重复：检测到重复段落或标题"
      end
      if has_truncated_content(content) then
        return true, "内容截断：检测到不完整的结尾"
      end
    end
    -- 总结轮次中空内容+无工具调用是异常
    if (not content or content == "") and (not tool_calls or #tool_calls == 0) then
      return true, "总结轮次空响应：AI 未返回任何内容"
    end
    return false, nil
  end

  -- 工具循环模式：AI 必须通过 stop_tool_loop 工具来结束对话
  if opts.is_tool_loop then
    -- 检查是否包含 stop_tool_loop 工具调用（正常结束对话的标志）
    local has_stop_tool = false
    if tool_calls and #tool_calls > 0 then
      for _, tc in ipairs(tool_calls) do
        local func = tc["function"] or tc.func
        if func and func.name == "stop_tool_loop" then
          has_stop_tool = true
          break
        end
      end
    end

    -- 包含 stop_tool_loop：正常结束对话，不重试
    if has_stop_tool then
      return false, nil
    end

    -- 空内容且无工具调用：模型可能卡住，需要重试
    if (not content or content == "") and (not tool_calls or #tool_calls == 0) then
      return true, "空响应：AI 未返回任何内容或工具调用"
    end

    -- 有内容但无工具调用：AI 未通过 stop_tool_loop 结束对话，视为异常
    if content and content ~= "" and (not tool_calls or #tool_calls == 0) then
      return true, "缺少 stop_tool_loop：AI 在工具循环中直接返回文本而未调用停止工具"
    end

    -- 有工具调用但不包含 stop_tool_loop：正常继续循环
    -- 但需检测工具调用本身是否异常
    if tool_calls and #tool_calls > 0 then
      if has_abnormal_tool_calls(tool_calls) then
        return true, "工具调用异常：检测到重复或空参数的工具调用"
      end
    end
  end

  -- 1. 空内容检测（非工具循环模式）
  -- 非工具循环模式下，空内容+无工具调用可能是正常的（如命名请求）
  -- 但如果有工具调用列表却为空，仍可能是异常
  if (not content or content == "") and (not tool_calls or #tool_calls == 0) then
    -- 非工具循环模式：不将空内容视为异常，让上层逻辑处理
    return false, nil
  end

  -- 2. 内容重复检测
  if content and content ~= "" then
    if has_repeated_content(content) then
      return true, "内容重复：检测到重复段落或标题"
    end
    if has_truncated_content(content) then
      return true, "内容截断：检测到不完整的结尾"
    end
  end

  -- 3. 工具调用异常检测
  if tool_calls and #tool_calls > 0 then
    if has_abnormal_tool_calls(tool_calls) then
      return true, "工具调用异常：检测到重复或空参数的工具调用"
    end
  end

  return false, nil
end

-- ========== 重试管理 ==========

--- 获取重试延迟
--- @param retry_count number 当前已重试次数（从 0 开始）
--- @return number 延迟毫秒数
function M.get_retry_delay(retry_count)
  if retry_count < 1 then
    return 0
  end
  local index = math.min(retry_count, #config.retry_delays)
  return config.retry_delays[index]
end

--- 检查是否可以继续重试
--- @param retry_count number 当前已重试次数
--- @return boolean
function M.can_retry(retry_count)
  return retry_count < config.max_retries
end

--- 获取最大重试次数
--- @return number
function M.get_max_retries()
  return config.max_retries
end

--- 设置重试配置
--- @param opts table { max_retries?, retry_delays? }
function M.set_config(opts)
  if opts.max_retries then
    config.max_retries = opts.max_retries
  end
  if opts.retry_delays then
    config.retry_delays = opts.retry_delays
  end
end

return M
