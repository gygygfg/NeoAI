-- Neovim 模拟环境
-- 为非Neovim环境提供必要的Neovim API模拟

local M = {}

-- 模拟 vim 全局变量
if not vim then
    _G.vim = {}
end

-- 模拟 vim.api
if not vim.api then
    vim.api = {}
end

-- 模拟 vim.api.nvim_create_user_command
vim.api.nvim_create_user_command = function(name, command, opts)
    print(string.format("[模拟] 创建用户命令: %s", name))
    return 1 -- 返回命令ID
end

-- 模拟 vim.fn
if not vim.fn then
    vim.fn = {}
end

-- 模拟 vim.fn.stdpath
vim.fn.stdpath = function(what)
    local paths = {
        cache = "/tmp/neovim_cache",
        config = "/tmp/neovim_config",
        data = "/tmp/neovim_data",
        state = "/tmp/neovim_state"
    }
    return paths[what] or "/tmp"
end

-- 模拟 vim.fn.glob
vim.fn.glob = function(pattern, nosuf, list)
    -- 简单的模拟，返回空列表
    return {}
end

-- 模拟 vim.fn.isdirectory
vim.fn.isdirectory = function(path)
    -- 简单的模拟，总是返回false
    return 0
end

-- 模拟 vim.fn.filereadable
vim.fn.filereadable = function(path)
    -- 简单的模拟，总是返回false
    return 0
end

-- 模拟 vim.fn.fnamemodify
vim.fn.fnamemodify = function(filename, mods)
    -- 简单的模拟，处理常见的修改符
    if mods == ":t:r" then
        -- 返回不带路径和扩展名的文件名
        local name = filename:match("([^/]+)$") or filename
        return name:match("^(.+)%..+$") or name
    end
    return filename
end

-- 模拟 vim.split
vim.split = function(str, pattern, opts)
    local result = {}
    local plain = opts and opts.plain
    
    if plain then
        -- 简单分割
        local start = 1
        while true do
            local pos = str:find(pattern, start, true)
            if not pos then
                table.insert(result, str:sub(start))
                break
            end
            table.insert(result, str:sub(start, pos-1))
            start = pos + #pattern
        end
    else
        -- 使用模式匹配
        for part in str:gmatch("[^" .. pattern .. "]+") do
            table.insert(result, part)
        end
    end
    
    return result
end

-- 模拟 vim.fn.shellescape
vim.fn.shellescape = function(str)
    -- 简单的模拟，返回带引号的字符串
    return "'" .. str .. "'"
end

-- 模拟 vim.tbl_deep_extend
if not vim.tbl_deep_extend then
    vim.tbl_deep_extend = function(behavior, ...)
        local result = {}
        local tables = {...}
        
        for _, t in ipairs(tables) do
            if type(t) == "table" then
                for k, v in pairs(t) do
                    if behavior == "force" then
                        result[k] = v
                    elseif result[k] == nil then
                        result[k] = v
                    end
                end
            end
        end
        
        return result
    end
end

-- 模拟 vim.keymap.set
if not vim.keymap then
    vim.keymap = {}
end
vim.keymap.set = function(mode, lhs, rhs, opts)
    print(string.format("[模拟] 设置键位映射: %s -> %s", lhs, tostring(rhs)))
end

-- 初始化函数
function M.setup()
    print("🔧 设置Neovim模拟环境")
    
    -- 确保全局变量已设置
    if not _G.vim then
        _G.vim = vim
    end
    
    return true
end

-- 导出模块
return M