-- NeoAI 工具函数
local M = {}

-- 确保目录存在，不存在则创建
function M.ensure_dir(dir)
    if dir == nil then return false end
    if vim.fn.isdirectory(dir) == 0 then
        vim.fn.mkdir(dir, 'p')
        return true
    end
    return false
end

-- 深度合并两个表
function M.deep_extend(defaults, overrides)
    local result = vim.deepcopy(defaults)
    for key, value in pairs(overrides) do
        if type(value) == "table" and type(result[key]) == "table" then
            result[key] = M.deep_extend(result[key], value)
        else
            result[key] = value
        end
    end
    return result
end

-- 格式化时间戳为可读字符串
function M.format_timestamp(timestamp)
    return os.date("%Y-%m-%d %H:%M:%S", timestamp)
end

-- 格式化时间戳为短时间
function M.format_time(timestamp)
    return os.date("%H:%M", timestamp)
end

-- 生成简单唯一ID
function M.generate_id()
    return os.time() .. math.random(1000, 9999)
end

-- 截断字符串到最大长度
function M.truncate(str, max_length)
    if #str <= max_length then return str end
    return str:sub(1, max_length - 3) .. "..."
end

-- 按换行符分割字符串
function M.split_lines(str)
    local lines = {}
    for line in str:gmatch("[^\r\n]+") do
        table.insert(lines, line)
    end
    return lines
end

-- 用换行符连接行
function M.join_lines(lines)
    return table.concat(lines, "\n")
end

-- 转义特殊字符用于显示
function M.escape_special_chars(str)
    return str:gsub("[\r\n\t]", {
        ["\r"] = "\\r",
        ["\n"] = "\\n",
        ["\t"] = "\\t"
    })
end

-- 检查是否在 Neovim 中运行
function M.is_neovim()
    return vim.fn.has("nvim") == 1
end

-- 获取配置路径
function M.get_config_path()
    return vim.fn.stdpath('config')
end

-- 获取数据路径
function M.get_data_path()
    return vim.fn.stdpath('data')
end

return M
