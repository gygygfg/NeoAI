local M = {}

--- 截断文本
--- @param text string 文本
--- @param length number 最大长度
--- @param ellipsis string 省略号
--- @return string 截断后的文本
function M.truncate(text, length, ellipsis)
    if not text or type(text) ~= "string" then
        return ""
    end

    length = length or 50
    ellipsis = ellipsis or "..."

    if #text <= length then
        return text
    end

    -- 尝试在单词边界截断
    local truncated = text:sub(1, length)
    local last_space = truncated:reverse():find(" ")
    
    if last_space then
        truncated = truncated:sub(1, length - last_space)
    end

    return truncated .. ellipsis
end

--- 文本换行
--- @param text string 文本
--- @param width number 行宽
--- @return table 换行后的行列表
function M.wrap(text, width)
    if not text or type(text) ~= "string" then
        return {}
    end

    width = width or 80
    local lines = {}
    local current_line = ""
    local words = {}

    -- 分割单词
    for word in text:gmatch("%S+") do
        table.insert(words, word)
    end

    -- 处理每个单词
    for _, word in ipairs(words) do
        if #current_line + #word + 1 <= width then
            if current_line == "" then
                current_line = word
            else
                current_line = current_line .. " " .. word
            end
        else
            if current_line ~= "" then
                table.insert(lines, current_line)
            end
            current_line = word
        end
    end

    -- 添加最后一行
    if current_line ~= "" then
        table.insert(lines, current_line)
    end

    return lines
end

--- 转义字符
--- @param text string 文本
--- @return string 转义后的文本
function M.escape(text)
    if not text then
        return ""
    end

    local escapes = {
        ["\\"] = "\\\\",
        ["\""] = "\\\"",
        ["\'"] = "\\\'",
        ["\n"] = "\\n",
        ["\r"] = "\\r",
        ["\t"] = "\\t",
    }

    return text:gsub("[\\\"\'\n\r\t]", escapes)
end

--- 反转义字符
--- @param text string 文本
--- @return string 反转义后的文本
function M.unescape(text)
    if not text then
        return ""
    end

    local unescapes = {
        ["\\\\"] = "\\",
        ["\\\""] = "\"",
        ["\\\'"] = "\'",
        ["\\n"] = "\n",
        ["\\r"] = "\r",
        ["\\t"] = "\t",
    }

    for pattern, replacement in pairs(unescapes) do
        text = text:gsub(pattern, replacement)
    end

    return text
end

--- 格式化JSON
--- @param data table JSON数据
--- @param indent number 缩进空格数
--- @return string 格式化后的JSON
function M.format_json(data, indent)
    indent = indent or 2
    
    local ok, json = pcall(vim.json.encode, data)
    if not ok then
        return "无效的JSON数据"
    end

    -- 简单美化（实际应该使用vim.json.encode的indent参数）
    -- 但Neovim的vim.json.encode不支持indent参数
    local result = json
    local spaces = string.rep(" ", indent)
    
    -- 简单的美化逻辑
    local depth = 0
    local in_string = false
    local escaped = false
    local formatted = ""
    
    for i = 1, #result do
        local char = result:sub(i, i)
        local prev_char = i > 1 and result:sub(i-1, i-1) or ""
        
        if not in_string then
            if char == "{" or char == "[" then
                formatted = formatted .. char .. "\n"
                depth = depth + 1
                formatted = formatted .. string.rep(spaces, depth)
            elseif char == "}" or char == "]" then
                formatted = formatted .. "\n"
                depth = depth - 1
                formatted = formatted .. string.rep(spaces, depth) .. char
            elseif char == "," then
                formatted = formatted .. char .. "\n" .. string.rep(spaces, depth)
            elseif char == ":" then
                formatted = formatted .. char .. " "
            else
                formatted = formatted .. char
            end
        else
            formatted = formatted .. char
        end
        
        -- 处理字符串状态
        if char == "\\" and not escaped then
            escaped = true
        elseif char == "\"" and not escaped then
            in_string = not in_string
            escaped = false
        else
            escaped = false
        end
    end
    
    return formatted
end

--- 计算文本行数
--- @param text string 文本
--- @return number 行数
function M.count_lines(text)
    if not text then
        return 0
    end

    local count = 1
    for _ in text:gmatch("\n") do
        count = count + 1
    end

    return count
end

--- 移除多余空白
--- @param text string 文本
--- @return string 清理后的文本
function M.trim(text)
    if not text then
        return ""
    end

    -- 移除首尾空白
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    
    -- 移除多余的空格
    text = text:gsub("%s+", " ")
    
    return text
end

--- 移除空行
--- @param text string 文本
--- @return string 清理后的文本
function M.remove_empty_lines(text)
    if not text then
        return ""
    end

    local lines = {}
    for line in text:gmatch("[^\n]+") do
        if line:match("%S") then -- 非空行
            table.insert(lines, line)
        end
    end

    return table.concat(lines, "\n")
end

--- 文本对齐
--- @param text string 文本
--- @param width number 宽度
--- @param alignment string 对齐方式 ('left', 'center', 'right')
--- @return string 对齐后的文本
function M.align(text, width, alignment)
    if not text then
        return ""
    end

    width = width or 80
    alignment = alignment or "left"

    local text_len = #text

    if text_len >= width then
        return text:sub(1, width)
    end

    local padding = width - text_len

    if alignment == "left" then
        return text .. string.rep(" ", padding)
    elseif alignment == "right" then
        return string.rep(" ", padding) .. text
    elseif alignment == "center" then
        local left_padding = math.floor(padding / 2)
        local right_padding = padding - left_padding
        return string.rep(" ", left_padding) .. text .. string.rep(" ", right_padding)
    end

    return text
end

--- 分割文本
--- @param text string 文本
--- @param delimiter string 分隔符
--- @return table 分割后的部分
function M.split(text, delimiter)
    if not text then
        return {}
    end

    delimiter = delimiter or "%s"
    local result = {}
    local pattern = string.format("([^%s]+)", delimiter)

    for part in text:gmatch(pattern) do
        table.insert(result, part)
    end

    return result
end

--- 连接文本
--- @param parts table 文本部分
--- @param delimiter string 分隔符
--- @return string 连接后的文本
function M.join(parts, delimiter)
    if not parts or type(parts) ~= "table" then
        return ""
    end

    delimiter = delimiter or " "
    return table.concat(parts, delimiter)
end

--- 文本包含
--- @param text string 文本
--- @param substring string 子字符串
--- @param case_sensitive boolean 是否区分大小写
--- @return boolean 是否包含
function M.contains(text, substring, case_sensitive)
    if not text or not substring then
        return false
    end

    if not case_sensitive then
        text = text:lower()
        substring = substring:lower()
    end

    return text:find(substring, 1, true) ~= nil
end

--- 文本替换
--- @param text string 文本
--- @param pattern string 模式
--- @param replacement string 替换文本
--- @param replace_all boolean 是否替换所有
--- @return string 替换后的文本
function M.replace(text, pattern, replacement, replace_all)
    if not text then
        return ""
    end

    if replace_all then
        return text:gsub(pattern, replacement)
    else
        return text:gsub(pattern, replacement, 1)
    end
end

--- 计算文本相似度（简单实现）
--- @param text1 string 文本1
--- @param text2 string 文本2
--- @return number 相似度（0-1）
function M.similarity(text1, text2)
    if not text1 or not text2 then
        return 0
    end

    if text1 == text2 then
        return 1
    end

    -- 简单实现：计算公共字符比例
    local common = 0
    local min_len = math.min(#text1, #text2)
    
    for i = 1, min_len do
        if text1:sub(i, i) == text2:sub(i, i) then
            common = common + 1
        end
    end

    return common / math.max(#text1, #text2)
end

--- 生成文本摘要
--- @param text string 文本
--- @param max_length number 最大长度
--- @return string 摘要
function M.summarize(text, max_length)
    if not text then
        return ""
    end

    max_length = max_length or 100

    if #text <= max_length then
        return text
    end

    -- 尝试在句子边界截断
    local truncated = text:sub(1, max_length)
    local last_sentence_end = math.max(
        truncated:reverse():find("%."),
        truncated:reverse():find("!"),
        truncated:reverse():find("?")
    )

    if last_sentence_end then
        truncated = truncated:sub(1, max_length - last_sentence_end + 1)
    end

    return truncated .. "..."
end

--- 检查文本是否以指定前缀开头
--- @param text string 文本
--- @param prefix string 前缀
--- @param case_sensitive boolean 是否区分大小写
--- @return boolean 是否以指定前缀开头
function M.starts_with(text, prefix, case_sensitive)
    if not text or not prefix then
        return false
    end

    if not case_sensitive then
        text = text:lower()
        prefix = prefix:lower()
    end

    return text:sub(1, #prefix) == prefix
end

--- 检查文本是否以指定后缀结尾
--- @param text string 文本
--- @param suffix string 后缀
--- @param case_sensitive boolean 是否区分大小写
--- @return boolean 是否以指定后缀结尾
function M.ends_with(text, suffix, case_sensitive)
    if not text or not suffix then
        return false
    end

    if not case_sensitive then
        text = text:lower()
        suffix = suffix:lower()
    end

    return text:sub(-#suffix) == suffix
end

return M