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

-- ========== 总结内容检测 ==========

--- 判断 AI 返回的内容是否为总结性质
--- 当内容包含总结类关键词时，视为正常结束，不触发重试也不触发额外总结轮次
--- @param content string AI 响应文本
--- @return boolean 是否为总结内容
function M.is_summary_content(content)
  if not content or content == "" then
    return false
  end

  -- 总结类关键词列表（不区分大小写）
  local summary_keywords = {
    "总结",
    "汇总",
    "概述",
    "小结",
    "综上所述",
    "总而言之",
    "任务完成",
    "已完成",
    "已完成的任务",
    "最终结果",
    "最终回复",
    "以上是",
    "以上就是",
    "summary",
    "summarize",
    "summarise",
    "in summary",
    "in conclusion",
    "to summarize",
    "to sum up",
    "all tasks completed",
    "task completed",
    "tasks completed",
    "here is the summary",
    "here's the summary",
    "here are the results",
    "here's the result",
    "final result",
    "final response",
    "that's all",
    "that is all",
  }

  local lower_content = content:lower()
  for _, keyword in ipairs(summary_keywords) do
    if lower_content:find(keyword, 1, true) then
      return true
    end
  end

  return false
end

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

  -- 检查是否以不完整的句子结束（以逗号、冒号、分号结尾）
  -- 注意：不检测 "-"（连字符），因为 Markdown 列表项、日期等正常文本可能以 "-" 结尾
  -- 同时不检测 "/" 和 "\\"，因为文件路径可能以这些字符结尾
  local last_char = text:sub(-1)
  local incomplete_endings = { [","] = true, [":"] = true, [";"] = true, ["|"] = true }
  if incomplete_endings[last_char] then
    logger.debug("[response_retry] 检测到不完整结尾: '" .. last_char .. "'")
    return true
  end

  -- 检查是否以不完整的 Markdown 语法结束（仅检测结尾处未闭合的语法）
  -- 注意：使用锚定到行尾的匹配，避免误判文本中正常出现的 "[" 或 "("
  if text:match("%[%s*$") or text:match("%(%s*$") or text:match("!%[%s*$") then
    logger.debug("[response_retry] 检测到不完整的 Markdown 语法")
    return true
  end

  return false
end

--- 检测工具调用是否异常
--- 策略：检查工具调用参数是否为空，以及是否存在完全相同的重复调用（同名+同参数）
--- 注意：同名但不同参数的多次工具调用（如多次 read_file 读取不同文件）是正常行为，不视为异常
--- @param tool_calls table 工具调用列表
--- @return boolean 是否检测到异常
local function has_abnormal_tool_calls(tool_calls)
  if not tool_calls or #tool_calls == 0 then
    return false
  end

  -- 检查是否有空参数的工具调用（仅检测真正为空的参数，不检测 JSON 空对象 "{}"）
  for i, tc in ipairs(tool_calls) do
    local func = tc["function"] or tc.func
    if func then
      local args = func.arguments
      local args_type = type(args)
      local args_str = tostring(args)
      -- 只检测真正为空的情况：nil、空字符串、或空 table
      -- 注意："{}"（JSON 空对象）是合法参数，表示一个空参数对象
      if args == nil then
        logger.debug(
          string.format(
            "[response_retry] 检测到空参数工具调用 #%d: name=%s, args=nil",
            i,
            tostring(func.name)
          )
        )
        return true
      end
      if args_type == "string" and args == "" then
        logger.debug(
          string.format(
            "[response_retry] 检测到空参数工具调用 #%d: name=%s, args='' (空字符串)",
            i,
            tostring(func.name)
          )
        )
        return true
      end
      if args_type == "table" and vim.tbl_isempty(args) then
        logger.debug(
          string.format(
            "[response_retry] 检测到空参数工具调用 #%d: name=%s, args={} (空 table)",
            i,
            tostring(func.name)
          )
        )
        return true
      end
    end
  end

  -- 检查是否有完全相同的重复调用（同名 + 同参数）
  -- 注意：仅同名但参数不同的多次调用（如多次 read_file 读取不同文件）是正常行为
  local seen_signatures = {}
  for i, tc in ipairs(tool_calls) do
    local func = tc["function"] or tc.func
    if func and func.name then
      local args = func.arguments
      local args_str
      if type(args) == "table" then
        args_str = vim.inspect(args)
      else
        args_str = tostring(args or "")
      end
      local signature = func.name .. ":" .. args_str
      if seen_signatures[signature] then
        logger.debug(
          string.format(
            "[response_retry] 检测到完全相同的重复工具调用 #%d: name=%s, signature=%s",
            i,
            func.name,
            signature
          )
        )
        return true
      end
      seen_signatures[signature] = true
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

  -- 工具循环模式：AI 本轮不调用工具就算自动停止循环
  -- 有内容但无工具调用：视为 AI 自动退出，不再重试
  -- AI 可能认为任务已完成，直接返回文本回复
  if opts.is_tool_loop then
    -- 空内容且无工具调用：模型可能卡住，需要重试
    if (not content or content == "") and (not tool_calls or #tool_calls == 0) then
      return true, "空响应：AI 未返回任何内容或工具调用"
    end

    -- 有内容但无工具调用：视为 AI 自动退出，不再重试
    -- AI 认为任务已完成，直接返回文本回复，停止循环
    if content and content ~= "" and (not tool_calls or #tool_calls == 0) then
      return false, nil
    end

    -- 有工具调用：正常继续循环，但需检测工具调用本身是否异常
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
