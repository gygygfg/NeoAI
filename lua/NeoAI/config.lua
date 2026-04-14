-- NeoAI 默认配置
local M = {}

M.defaults = {
  ui = {
    -- UI 配置 (界面相关设置)
    -- 默认打开模式，可选值:
    -- "float"  - 浮动窗口 (默认推荐)
    -- "split"  - 分割窗口
    -- "tab"    - 标签页
    default_mode = "tab",

    -- 聊天窗口宽度 (字符数)，建议范围: 60-120
    width = 80,

    -- 聊天窗口高度 (行数)，建议范围: 10-40
    height = 25,

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
    -- 打开聊天窗口，默认 <leader>nc (按 leader 键后按 n, c)
    open = "<leader>nc",

    -- 关闭聊天窗口，默认 q
    close = "q",

    -- 发送消息，默认 <leader>cs (按 leader 键后按 c, s)
    send = "<C-s>",

    -- 新建对话，默认 <leader>cn (按 leader 键后按 n, n)
    new = "<leader>nn",

    -- 在输入行按回车发送消息（正常模式下）
    normal_mode_send = "<CR>",

    -- 在输入行按 Ctrl+s 发送消息（插入模式下）
    insert_mode_send = "<C-s>",
  },

  tree_keymaps = {
    -- 树视图快捷键配置
    -- 在当前光标位置新建对话分支（复制从根到当前轮次的路径）
    new_branch = "n",

    -- 新建空对话
    new_conversation = "N",

    -- 删除当前光标所在的这一轮对话
    delete_turn = "d",

    -- 删除当前整个分支（从根到叶子）
    delete_branch = "D",

    -- 打开配置文件
    open_config = "e",
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

    -- 配置目录路径，默认使用 Neovim 的缓存目录下的 NeoAI 文件夹
    -- 可通过 vim.fn.stdpath("cache") 查看具体路径
    config_dir = vim.fn.stdpath("cache") .. "/NeoAI",

    -- 会话数据文件路径，默认为 config_dir 下的 sessions.json
    -- 可自定义为其他路径或文件名
    config_file = nil, -- 将设置为 config_dir .. '/sessions.json'

    -- 会话最大历史消息数，超出后会自动删除最早的消息
    -- 0 = 不限制
    max_history = 100,
  },

  llm = {
    -- 大模型 API 配置（HTTPS 流式请求）

    -- API 端点 URL（支持 OpenAI 兼容的 API 格式）
    -- 示例: "https://api.openai.com/v1/chat/completions"
    -- 示例: "https://api.deepseek.com/chat/completions"
    api_url = "https://api.deepseek.com/chat/completions",

    -- API 密钥（Bearer Token）
    -- 建议通过环境变量或外部配置文件设置，避免硬编码
    -- 可使用: os.getenv("DEEPSEEK_API_KEY") 读取环境变量
    api_key = os.getenv("DEEPSEEK_API_KEY") or "",

    -- 模型名称
    -- 示例: "gpt-4", "gpt-3.5-turbo", "deepseek-chat", "qwen-plus"
    model = "deepseek-chat",

    -- 是否启用流式输出（SSE）
    -- true  = 流式输出，逐步显示 AI 回复
    -- false = 等待完整响应后一次性显示
    stream = true,

    -- 系统提示词（设定 AI 的角色和行为）
    system_prompt = "You are a helpful AI assistant integrated with Neovim. Provide concise, accurate, and helpful responses.",

    -- 请求参数
    temperature = 0.7, -- 创造性参数 (0-2)
    max_tokens = 2048, -- 最大生成 token 数
    top_p = 1.0, -- 核采样参数

    -- 流式输出更新间隔（毫秒）
    stream_update_interval = 100,

    -- 请求超时时间（秒）
    timeout = 120,
  },
}

--- 获取有效的配置文件路径
-- @param cfg 配置表
-- @return string 配置文件路径
function M.get_config_file(cfg)
  return cfg.config_file or (cfg.config_dir .. "/sessions.json")
end

return M
