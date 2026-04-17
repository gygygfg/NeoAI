local M = {}

--- 读取文件
--- @param path string 文件路径
--- @return string|nil 文件内容，错误时返回nil和错误信息
function M.read_file(path)
    if not path then
        return nil, "路径不能为空"
    end

    local file, err = io.open(path, "r")
    if not file then
        -- 检查文件是否存在
        local exists = M.exists(path)
        if not exists then
            return nil, "文件不存在: " .. path
        else
            return nil, "无法打开文件: " .. (err or "未知错误")
        end
    end

    local content = file:read("*a")
    file:close()

    return content
end

--- 写入文件
--- @param path string 文件路径
--- @param content string 内容
--- @param append boolean 是否追加模式
--- @return boolean 是否成功，错误时返回false和错误信息
function M.write_file(path, content, append)
    if not path then
        return false, "路径不能为空"
    end

    if content == nil then
        content = ""
    end

    local mode = append and "a" or "w"
    local file, err = io.open(path, mode)
    if not file then
        return false, "无法打开文件: " .. (err or "未知错误")
    end

    local success, write_err = pcall(function()
        file:write(content)
        file:close()
    end)

    if not success then
        return false, "写入失败: " .. (write_err or "未知错误")
    end

    return true
end

--- 读取行
--- @param path string 文件路径
--- @return table|nil 行列表，错误时返回nil和错误信息
function M.read_lines(path)
    if not path then
        return nil, "路径不能为空"
    end

    local content, err = M.read_file(path)
    if not content then
        return nil, err
    end

    local lines = {}
    for line in content:gmatch("[^\n]+") do
        table.insert(lines, line)
    end

    -- 处理最后一行可能没有换行符的情况
    if content:sub(-1) ~= "\n" and content ~= "" then
        local last_line = content:match("[^\n]+$")
        if last_line then
            table.insert(lines, last_line)
        end
    end

    return lines
end

--- 写入行
--- @param path string 文件路径
--- @param lines table 行列表
--- @param append boolean 是否追加模式
--- @return boolean 是否成功，错误时返回false和错误信息
function M.write_lines(path, lines, append)
    if not path then
        return false, "路径不能为空"
    end

    if not lines or type(lines) ~= "table" then
        return false, "行列表无效"
    end

    local content = table.concat(lines, "\n")
    if #lines > 0 then
        content = content .. "\n"
    end

    return M.write_file(path, content, append)
end

--- 检查文件是否存在
--- @param path string 路径
--- @return boolean 是否存在
function M.exists(path)
    if not path then
        return false
    end

    local file, err = io.open(path, "r")
    if file then
        file:close()
        return true
    end

    return false
end

--- 检查目录是否存在
--- @param path string 目录路径
--- @return boolean 目录是否存在
function M.dir_exists(path)
    if not path then
        return false
    end

    local ok, stat = pcall(vim.loop.fs_stat, path)
    if ok and stat then
        return stat.type == "directory"
    end

    return false
end

--- 创建目录
--- @param dir string 目录路径
--- @return boolean 是否成功，错误时返回false和错误信息
function M.mkdir(dir)
    if not dir then
        return false, "目录路径不能为空"
    end

    -- 检查目录是否已存在
    if M.exists(dir) then
        return true
    end

    -- 创建目录
    local cmd = string.format('mkdir -p "%s"', dir)
    local result = os.execute(cmd)

    if result == 0 or result == true then
        return true
    else
        return false, "创建目录失败"
    end
end

--- 连接路径
--- @param ... string 路径部分
--- @return string 连接后的路径
function M.join_path(...)
    local parts = { ... }
    local result = ""

    for i, part in ipairs(parts) do
        if part and part ~= "" then
            if i > 1 and result:sub(-1) ~= "/" and part:sub(1, 1) ~= "/" then
                result = result .. "/" .. part
            else
                result = result .. part
            end
        end
    end

    -- 规范化路径
    result = result:gsub("/+", "/")
    result = result:gsub("/$", "")

    return result
end

--- 获取文件扩展名
--- @param path string 文件路径
--- @return string 扩展名
function M.get_extension(path)
    if not path then
        return ""
    end

    local filename = M.get_filename(path)
    local dot_index = filename:reverse():find("%.")

    if dot_index then
        return filename:sub(-dot_index + 1)
    end

    return ""
end

--- 获取文件名（不含路径）
--- @param path string 文件路径
--- @return string 文件名
function M.get_filename(path)
    if not path then
        return ""
    end

    local separator = package.config:sub(1, 1) -- 获取路径分隔符
    local parts = {}
    
    for part in path:gmatch("[^" .. separator .. "]+") do
        table.insert(parts, part)
    end

    if #parts > 0 then
        return parts[#parts]
    end

    return ""
end

--- 获取目录名
--- @param path string 文件路径
--- @return string 目录名
function M.get_dirname(path)
    if not path then
        return ""
    end

    local separator = package.config:sub(1, 1)
    local parts = {}
    
    for part in path:gmatch("[^" .. separator .. "]+") do
        table.insert(parts, part)
    end

    if #parts > 1 then
        table.remove(parts, #parts)
        return table.concat(parts, separator)
    elseif #parts == 1 then
        return "."
    end

    return ""
end

--- 获取文件大小
--- @param path string 文件路径
--- @return number|nil 文件大小（字节），错误时返回nil
function M.get_file_size(path)
    if not path then
        return nil
    end

    local file, err = io.open(path, "r")
    if not file then
        return nil
    end

    local size = file:seek("end")
    file:close()

    return size
end

--- 获取文件修改时间
--- @param path string 文件路径
--- @return number|nil 修改时间（Unix时间戳），错误时返回nil
function M.get_mtime(path)
    if not path then
        return nil
    end

    local ok, stat = pcall(vim.loop.fs_stat, path)
    if ok and stat then
        return stat.mtime.sec
    end

    return nil
end

--- 复制文件
--- @param src string 源文件路径
--- @param dst string 目标文件路径
--- @return boolean 是否成功，错误时返回false和错误信息
function M.copy_file(src, dst)
    if not src or not dst then
        return false, "源路径和目标路径不能为空"
    end

    local content, err = M.read_file(src)
    if not content then
        return false, "无法读取源文件: " .. err
    end

    return M.write_file(dst, content)
end

--- 移动文件
--- @param src string 源文件路径
--- @param dst string 目标文件路径
--- @return boolean 是否成功，错误时返回false和错误信息
function M.move_file(src, dst)
    if not src or not dst then
        return false, "源路径和目标路径不能为空"
    end

    -- 先复制
    local ok, err = M.copy_file(src, dst)
    if not ok then
        return false, "复制失败: " .. err
    end

    -- 然后删除源文件
    local del_ok, del_err = M.delete_file(src)
    if not del_ok then
        -- 如果删除失败，尝试删除目标文件
        M.delete_file(dst)
        return false, "移动失败（无法删除源文件）: " .. del_err
    end

    return true
end

--- 删除文件
--- @param path string 文件路径
--- @return boolean 是否成功，错误时返回false和错误信息
function M.delete_file(path)
    if not path then
        return false, "路径不能为空"
    end

    local ok, err = os.remove(path)
    if ok then
        return true
    else
        return false, "删除失败: " .. (err or "未知错误")
    end
end

--- 列出目录内容
--- @param dir string 目录路径
--- @param pattern string 文件模式
--- @return table|nil 文件列表，错误时返回nil和错误信息
function M.list_dir(dir, pattern)
    if not dir then
        return nil, "目录路径不能为空"
    end

    pattern = pattern or "*"

    local files = {}
    local handle = io.popen(string.format('ls -1 "%s" 2>/dev/null', dir))
    
    if handle then
        for line in handle:lines() do
            -- 简单的模式匹配
            if pattern == "*" or line:match(pattern) then
                table.insert(files, line)
            end
        end
        handle:close()
        return files
    else
        return nil, "无法列出目录"
    end
end

--- 递归列出目录内容
--- @param dir string 目录路径
--- @param pattern string 文件模式
--- @return table|nil 文件列表，错误时返回nil和错误信息
function M.list_dir_recursive(dir, pattern)
    if not dir then
        return nil, "目录路径不能为空"
    end

    pattern = pattern or "*"

    local files = {}
    local cmd = string.format('find "%s" -type f -name "%s" 2>/dev/null', dir, pattern)
    local handle = io.popen(cmd)
    
    if handle then
        for line in handle:lines() do
            table.insert(files, line)
        end
        handle:close()
        return files
    else
        return nil, "无法递归列出目录"
    end
end

--- 列出文件（list_files 是 list_dir_recursive 的别名）
--- @param dir string 目录路径
--- @param pattern string 文件模式
--- @return table|nil 文件列表，错误时返回nil和错误信息
function M.list_files(dir, pattern)
    return M.list_dir_recursive(dir, pattern)
end

--- 检查是否为目录
--- @param path string 路径
--- @return boolean 是否为目录
function M.is_directory(path)
    if not path then
        return false
    end

    local ok, stat = pcall(vim.loop.fs_stat, path)
    if ok and stat then
        return stat.type == "directory"
    end

    return false
end

--- 检查是否为文件
--- @param path string 路径
--- @return boolean 是否为文件
function M.is_file(path)
    if not path then
        return false
    end

    local ok, stat = pcall(vim.loop.fs_stat, path)
    if ok and stat then
        return stat.type == "file"
    end

    return false
end

--- 获取绝对路径
--- @param path string 路径
--- @return string 绝对路径
function M.abs_path(path)
    if not path then
        return ""
    end

    -- 如果是相对路径，转换为绝对路径
    if path:sub(1, 1) ~= "/" then
        local cwd = vim.fn.getcwd()
        path = M.join_path(cwd, path)
    end

    return path
end

--- 规范化路径
--- @param path string 路径
--- @return string 规范化后的路径
function M.normalize_path(path)
    if not path then
        return ""
    end

    -- 替换多个斜杠为单个斜杠
    path = path:gsub("/+", "/")
    
    -- 移除末尾斜杠
    path = path:gsub("/$", "")
    
    -- 处理相对路径
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then
            if #parts > 0 then
                table.remove(parts)
            end
        elseif part ~= "." then
            table.insert(parts, part)
        end
    end

    return "/" .. table.concat(parts, "/")
end

--- 确保目录存在（ensure_dir 是 mkdir 的别名）
--- @param dir string 目录路径
--- @return boolean 是否成功，错误时返回false和错误信息
function M.ensure_dir(dir)
    return M.mkdir(dir)
end

--- 搜索文件
--- @param dir string 目录路径
--- @param pattern string 搜索模式（支持通配符）
--- @param recursive boolean 是否递归搜索
--- @return table|nil 文件列表，错误时返回nil和错误信息
function M.search_files(dir, pattern, recursive)
    if not dir then
        return nil, "目录路径不能为空"
    end
    
    pattern = pattern or "*"
    recursive = recursive or false
    
    if recursive then
        return M.list_dir_recursive(dir, pattern)
    else
        return M.list_dir(dir, pattern)
    end
end

--- 检查文件是否存在（file_exists 是 exists 的别名）
--- @param path string 路径
--- @return boolean 是否存在
function M.file_exists(path)
    return M.exists(path)
end

--- 创建目录（create_directory 是 mkdir 的别名）
--- @param dir string 目录路径
--- @return boolean 是否成功，错误时返回false和错误信息
function M.create_directory(dir)
    return M.mkdir(dir)
end

return M