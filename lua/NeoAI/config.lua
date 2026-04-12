-- NeoAI 默认配置
local M = {}

M.defaults = {
    -- UI配置
    width = 80,
    height = 20,
    border = "rounded",
    auto_scroll = true,
    show_timestamps = true,
    show_role_icons = true,

    -- 后端配置
    config_dir = vim.fn.stdpath('config') .. '/NeoAI',
    config_file = nil,  -- 将设置为 config_dir .. '/sessions.json'

    -- 快捷键配置
    keymaps = {
        open = "<leader>cc",
        close = "<leader>cq",
        send = "<leader>cs",
        new = "<leader>cn"
    },

    -- 角色图标
    role_icons = {
        user = "👤",
        assistant = "🤖",
        system = "⚙️"
    },

    -- 颜色配置
    colors = {
        user_bg = "Normal",
        assistant_bg = "Comment",
        system_bg = "ErrorMsg",
        border = "FloatBorder"
    }
}

-- 获取有效的配置文件路径
function M.get_config_file(cfg)
    return cfg.config_file or (cfg.config_dir .. '/sessions.json')
end

return M
