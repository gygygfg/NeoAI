local M = {}

--- 去除字符串两端的空白字符
--- @param str string 输入字符串
--- @return string 去除空白后的字符串
function M.trim(str)
    if not str or type(str) ~= "string" then
        return ""
    end
    return str:match("^%s*(.-)%s*$") or ""
end

--- 分割字符串
--- @param str string 输入字符串
--- @param delimiter string 分隔符
--- @return table 分割后的字符串数组
function M.split(str, delimiter)
    if not str or type(str) ~= "string" then
        return {}
    end
    
    delimiter = delimiter or ","
    local result = {}
    local pattern = string.format("([^%s]+)", delimiter)
    
    for match in str:gmatch(pattern) do
        table.insert(result, match)
    end
    
    return result
end

--- 连接字符串数组
--- @param parts table 字符串数组
--- @param separator string 分隔符
--- @return string 连接后的字符串
function M.join(parts, separator)
    if not parts or type(parts) ~= "table" then
        return ""
    end
    
    separator = separator or ","
    local result = ""
    
    for i, part in ipairs(parts) do
        if i > 1 then
            result = result .. separator
        end
        result = result .. tostring(part)
    end
    
    return result
end

--- 检查字符串是否以指定前缀开头
--- @param str string 输入字符串
--- @param prefix string 前缀
--- @return boolean 是否以指定前缀开头
function M.starts_with(str, prefix)
    if not str or not prefix then
        return false
    end
    return str:sub(1, #prefix) == prefix
end

--- 检查字符串是否以指定后缀结尾
--- @param str string 输入字符串
--- @param suffix string 后缀
--- @return boolean 是否以指定后缀结尾
function M.ends_with(str, suffix)
    if not str or not suffix then
        return false
    end
    return str:sub(-#suffix) == suffix
end

--- 截断字符串
--- @param str string 输入字符串
--- @param max_length number 最大长度
--- @param ellipsis string 省略号（默认"..."）
--- @return string 截断后的字符串
function M.truncate(str, max_length, ellipsis)
    if not str or type(str) ~= "string" then
        return ""
    end
    
    max_length = max_length or 50
    ellipsis = ellipsis or "..."
    
    if #str <= max_length then
        return str
    end
    
    return str:sub(1, max_length - #ellipsis) .. ellipsis
end

--- 基本去重函数
--- @param text string 输入文本
--- @param min_length number 最小重复长度（默认3）
--- @return string 去重后的文本
function M.deduplicate(text, min_length)
    if not text or type(text) ~= "string" then
        return ""
    end
    
    min_length = min_length or 3
    
    -- 简单的去重逻辑：移除连续重复的字符序列
    local result = text
    
    -- 处理连续重复的字符（如 "aaaa"）
    for i = min_length, 10 do  -- 最多检查10个字符的重复
        local pattern = "([%w%p]{" .. i .. "})" .. "%1+"
        result = result:gsub(pattern, "%1")
    end
    
    return result
end

--- 智能去重：针对AI响应中的常见重复模式
--- @param text string AI响应文本
--- @return string 去重后的文本
function M.deduplicate_ai_response(text)
    if not text or type(text) ~= "string" then
        return ""
    end
    
    -- 首先应用基本去重
    local deduplicated = M.deduplicate(text, 3)
    
    -- 处理常见的AI重复模式
    -- 模式1: 重复的短语（如"常见的常见的常见的"）
    deduplicated = deduplicated:gsub("([%w%p]+)%s*%1%s*%1+", "%1")
    
    -- 模式2: 重复的标点（如"。。。"）
    deduplicated = deduplicated:gsub("([。，；：！？])%1%1+", "%1")
    
    -- 模式3: 重复的单词（如"正确正确正确"）
    deduplicated = deduplicated:gsub("([%a]+)%s+%1%s+%1+", "%1")
    
    -- 模式4: 重复的中文字符（简单版本）
    deduplicated = deduplicated:gsub("([^%s%p]+)%s*%1%s*%1+", "%1")
    
    -- 清理多余空格
    deduplicated = deduplicated:gsub("%s+", " ")
    deduplicated = deduplicated:gsub("^%s+", ""):gsub("%s+$", "")
    
  return deduplicated
end

--- 智能拼接：检查并移除重叠部分
--- @param existing_text string 已有文本
--- @param new_chunk string 新数据块
--- @param min_overlap number 最小重叠长度（默认3）
--- @return string 拼接后的文本
function M.smart_concat(existing_text, new_chunk, min_overlap)
  if not existing_text or existing_text == "" then
    return new_chunk or ""
  end
  
  if not new_chunk or new_chunk == "" then
    return existing_text
  end
  
  min_overlap = min_overlap or 3  -- 降低最小重叠长度
  
  -- 如果新chunk很短，直接拼接
  if #new_chunk < min_overlap then
    return existing_text .. new_chunk
  end
  
  -- 检查新chunk是否已经包含在现有文本中
  if existing_text:find(new_chunk, 1, true) then
    -- 新chunk完全重复，不添加
    return existing_text
  end
  
  -- 检查重叠部分
  local max_overlap = math.min(#existing_text, #new_chunk)
  
  -- 从最大可能重叠开始检查，直到最小重叠长度
  for overlap_len = max_overlap, min_overlap, -1 do
    local existing_end = existing_text:sub(-overlap_len)
    local new_start = new_chunk:sub(1, overlap_len)
    
    if existing_end == new_start then
      -- 找到重叠部分，移除重叠
      return existing_text .. new_chunk:sub(overlap_len + 1)
    end
  end
  
  -- 特殊处理：检查标点符号后的重叠
  -- 例如：现有文本以标点结尾，新chunk以相同标点开头
  local last_char = existing_text:sub(-1)
  local first_char = new_chunk:sub(1, 1)
  
  -- 中文标点符号
  local chinese_punctuation = "。，；：！？"
  
  if chinese_punctuation:find(last_char, 1, true) and last_char == first_char then
    -- 标点重复，移除新chunk的第一个字符
    return existing_text .. new_chunk:sub(2)
  end
  
  -- 检查部分重叠（模糊匹配）
  -- 对于中文文本，有时重叠可能不是完全相同的字符
  if #existing_text >= 2 and #new_chunk >= 2 then
    -- 检查最后2个字符和开头2个字符
    local existing_end2 = existing_text:sub(-2)
    local new_start2 = new_chunk:sub(1, 2)
    
    -- 如果相似度较高，认为是重叠
    if existing_end2 == new_start2 then
      return existing_text .. new_chunk:sub(3)
    end
  end
  
  -- 没有找到重叠，直接拼接
  return existing_text .. new_chunk
end

--- 检查并修复stream拼接中的重复内容
--- @param text string 输入文本
--- @return string 修复后的文本
function M.fix_stream_overlap(text)
  if not text or type(text) ~= "string" then
    return ""
  end
  
  -- 首先应用智能去重
  local deduplicated = M.deduplicate_ai_response(text)
  
  -- 处理常见的stream拼接问题
  -- 模式1：重复的短语开头（如"我将我将"）
  deduplicated = deduplicated:gsub("([^%s%p]+)%s*%1", "%1")
  
  -- 模式2：重复的标点开头（如"：："）
  deduplicated = deduplicated:gsub("([。，；：！？])%1", "%1")
  
  -- 模式3：重复的单词开头（如"首先首先"）
  deduplicated = deduplicated:gsub("([%a]+)%s+%1", "%1")
  
  -- 模式4：中文重复模式（如"用户用户"）
  -- 注意：Lua 5.1不支持\u转义序列，使用更通用的模式
  deduplicated = deduplicated:gsub("([^%s%a%p]+)%s*%1", "%1")
  
  -- 模式5：混合重复模式（如"响应：："）
  deduplicated = deduplicated:gsub("([^%s]+[。，；：！？]?)%s*%1", "%1")
  
  -- 模式6：标点后的重复（如"，用户用户"）
  deduplicated = deduplicated:gsub("([。，；：！？])([^%s]+)%s*%2", "%1%2")
  
  -- 模式7：引号内的重复（如"\"测试测试\""）
  -- 简化模式：匹配引号内的重复内容
  deduplicated = deduplicated:gsub("([\"'])(.-)%1%s*%1(.-)%1", "%1%2%3%1")
  
  -- 清理多余空格
  deduplicated = deduplicated:gsub("%s+", " ")
  deduplicated = deduplicated:gsub("^%s+", ""):gsub("%s+$", "")
  
  return deduplicated
end

return M