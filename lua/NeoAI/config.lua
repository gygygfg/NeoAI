-- NeoAI 默认配置
local M = {}

M.defaults = {
  ui = {
    -- UI 配置 (界面相关设置)
    -- 默认打开模式，可选值:
    -- "float"  - 浮动窗口 (默认推荐)
    -- "split"  - 分割窗口
    -- "tab"    - 标签页
    default_mode = "float",

    -- 聊天窗口宽度 (字符数)，建议范围: 60-120
    width = 80,

    -- 聊天窗口高度 (行数)，建议范围: 10-40
    height = 20,

    -- 窗口边框样式，可选值:
    -- "rounded"   - 圆角边框 (默认推荐)
    -- "single"    - 单线边框
    -- "double"    - 双线边框
    -- "solid"     - 实线边框
    -- "shadow"    - 阴影效果
    -- "none"      - 无边框
    border = "rounded",

    -- 信息边框样式（用于消息块的边框），可选值:
    -- "rounded"   - 圆角边框
    -- "single"    - 单线边框
    -- "double"    - 双线边框
    -- "solid"     - 实线边框
    -- "none"      - 无边框 (默认推荐)
    info_border = "none",

    -- 输入框分割线样式（用于输入框上方的横线），可选值:
    -- "single"    - 单线 ─ (默认推荐)
    -- "double"    - 双线 ═
    -- "solid"     - 粗线 ━
    -- "dotted"    - 点线 ┈
    -- "dashed"    - 虚线 ┄
    input_separator = "single",

    -- 消息分割线样式（用于消息块内角色标题和内容的分割），可选值:
    -- "single"    - 单线 ─
    -- "double"    - 双线 ═
    -- "solid"     - 粗线 ━
    -- "dotted"    - 点线 ┈
    -- "dashed"    - 虚线 ┄
    message_separator = "single",

    -- 新消息到达时是否自动滚动到底部
    -- true  = 自动滚动，始终显示最新消息
    -- false = 手动滚动，保持在当前位置
    auto_scroll = true,

    -- 是否在消息前显示时间戳
    -- true  = 显示时间 (如 [14:30:25])
    -- false = 不显示时间
    show_timestamps = true,

    -- 是否在消息前显示角色图标
    -- true  = 显示图标 (👤 用户, 🤖 助手, ⚙️ 系统)
    -- false = 不显示图标
    show_role_icons = true,
  },

  keymaps = {
    -- 快捷键配置 (Keymaps)
    -- 打开聊天窗口，默认 <leader>cc (按 leader 键后按 c, c)
    open = "<leader>cc",

    -- 关闭聊天窗口，默认 q
    close = "q",

    -- 发送消息，默认 <leader>cs (按 leader 键后按 c, s)
    send = "<C-s>",

    -- 新建对话，默认 <leader>cn (按 leader 键后按 c, n)
    new = "<leader>cn",

    -- 在输入行按回车发送消息（正常模式下）
    normal_mode_send = "<CR>",

    -- 在输入行按 Ctrl+s 发送消息（插入模式下）
    insert_mode_send = "<C-s>",
  },

  role_icons = {
    -- 角色图标配置
    -- 用户消息图标
    user = "👤",

    -- AI助手消息图标
    assistant = "🤖",

    -- 系统消息图标
    system = "⚙️",
  },

  colors = {
    -- 颜色/高亮配置 (用于不同角色的消息背景色)
    -- 用户消息背景高亮组名称，可设为:
    -- "Normal"     - 默认背景
    -- "Visual"     - 选中背景
    -- 或自定义高亮组
    user_bg = "Normal",

    -- AI助手消息背景高亮组名称
    -- "Comment"    - 注释背景 (较暗)
    assistant_bg = "Comment",

    -- 系统消息背景高亮组名称
    -- "ErrorMsg"   - 错误提示背景 (较醒目)
    system_bg = "ErrorMsg",

    -- 边框颜色高亮组名称
    -- "FloatBorder" - 浮动窗口边框默认颜色
    border = "FloatBorder",
  },

  background = {
    -- 后端配置 (数据存储相关)

    -- 配置目录路径，默认使用 Neovim 的配置目录下的 NeoAI 文件夹
    -- 可通过 vim.fn.stdpath("config") 查看具体路径
    config_dir = vim.fn.stdpath("config") .. "/NeoAI",

    -- 会话数据文件路径，默认为 config_dir 下的 sessions.json
    -- 可自定义为其他路径或文件名
    config_file = nil, -- 将设置为 config_dir .. '/sessions.json'

    -- 会话最大历史消息数，超出后会自动删除最早的消息
    -- 0 = 不限制
    max_history = 100,
  },
}

--- 获取有效的配置文件路径
-- @param cfg 配置表
-- @return string 配置文件路径
function M.get_config_file(cfg)
  return cfg.config_file or (cfg.config_dir .. "/sessions.json")
end

return M
