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

    -- 输入框分隔线样式（用于输入框上方的横线），可选值:
    -- "single"    - 单线 ─ (默认推荐)
    -- "double"    - 双线 ═
    -- "solid"     - 粗线 ━
    -- "dotted"    - 点线 ┈
    -- "dashed"    - 虚线 ┄
    input_separator = "single",

    -- 消息分隔线样式（用于消息块内角色标题和内容的分割），可选值:
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
    -- 聊天界面快捷键配置
    chat = {
      -- 全局快捷键（在任何模式下都可用）
      global = {
        -- 打开聊天窗口，默认 <leader>nc (按 leader 键后按 n, c)
        open = { key = "<leader>nc", desc = "打开聊天" },

        -- 新建对话，默认 <leader>nn (按 leader 键后按 n, n)
        new = { key = "<leader>nn", desc = "新建会话" },
      },

      -- 普通模式快捷键（聊天窗口内）
      normal = {
        -- 编辑消息，默认 e
        edit_message = { key = "e", desc = "编辑消息" },

        -- 切换推理内容显示，默认 r
        -- 思考中：打开/关闭浮动窗口
        -- 思考完成后：展开/折叠文本
        toggle_reasoning = { key = "r", desc = "切换推理内容显示" },

        -- 导出当前会话，默认 s
        export_session = { key = "s", desc = "导出会话" },

        -- 关闭聊天窗口，默认 q
        close = { key = "q", desc = "关闭聊天" },

        -- 关闭聊天窗口，默认 <Esc>
        close_esc = { key = "<Esc>", desc = "关闭聊天" },

        -- 在输入行按回车发送消息（正常模式下）
        normal_mode_send = { key = "<CR>", desc = "发送消息或编辑" },
      },

      -- 插入模式快捷键（聊天窗口内）
      insert = {
        -- 发送消息，默认 <C-s>
        send = { key = "<C-s>", desc = "发送消息" },

        -- 关闭聊天窗口，默认 <C-c>
        close = { key = "<C-c>", desc = "关闭聊天" },

        -- 正常换行（不发送消息），默认 <CR>
        newline = { key = "<CR>", desc = "换行" },
      },
    },

    -- 树视图快捷键配置
    tree = {
      -- 普通模式快捷键（树视图窗口内）
      normal = {
        -- 选择会话或创建新会话，默认 <CR>
        select_or_create = { key = "<CR>", desc = "选择会话" },

        -- 在当前光标位置新建对话分支，默认 n
        new_branch = { key = "n", desc = "新建分支" },

        -- 新建空对话，默认 N
        new_conversation = { key = "N", desc = "新建空对话" },

        -- 删除当前光标这一轮对话，默认 d
        delete_turn = { key = "d", desc = "删除当前轮次" },

        -- 删除当前整个分支，默认 D
        delete_branch = { key = "D", desc = "删除当前分支" },

        -- 关闭树视图，默认 q
        close = { key = "q", desc = "关闭" },

        -- 关闭树视图，默认 <Esc>
        close_esc = { key = "<Esc>", desc = "关闭" },

        -- 刷新树视图，默认 r
        refresh = { key = "r", desc = "刷新树" },

        -- 打开配置文件，默认 e
        open_config = { key = "e", desc = "打开配置文件" },
      },
    },
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
    -- 思考模型: "deepseek-reasoner" (会输出 reasoning_content 思考过程)
    model = "deepseek-reasoner",

    -- 是否启用思考过程显示（仅对支持 reasoning_content 的模型有效，如 deepseek-reasoner）
    -- true  = 显示思考过程（虚拟文本形式，最后5行可见，其余折叠）
    -- false = 不显示思考过程
    show_reasoning = true,

    -- 是否启用流式输出（SSE）
    -- true  = 流式输出，逐步显示 AI 回复
    -- false = 等待完整响应后一次性显示
    stream = true,

    -- 系统提示词（设定 AI 的角色和行为）
    system_prompt = [[1. 角色与基础设定
    - 身份定义：你是一个交互式智能体，用于帮助用户处理软件工程任务。
    - 安全底线：注意不要引入安全漏洞，比如命令注入、XSS、SQL注入等OWASP十大漏洞。
    2. 核心系统规则
    - 输出风格：所有解释、注释以及与用户的交流都应使用用户指定的语言，技术术语和代码标识符保持原样。
    - 工具使用：不要在有专用工具时使用bash，使用专用工具可以提升可读性。
    - 执行任务：用户主要会让你执行软件工程任务，如修复bug、添加功能、重构代码等。
    3. 代码开发原则
    - 增量式开发：增量式进展优于"大爆炸"式开发
    - 实用主义：实用主义优于教条主义，适应项目现实
    - 代码简洁：清晰的意图优于巧妙的代码，保持代码的"无聊"和"显而易见"
    4. 安全与谨慎原则
    - 高风险操作确认：对于难以撤销、影响共享系统、有潜在风险的操作，必须先征求用户确认
    - 避免破坏性操作：遇到问题时不要用破坏性操作"绕过去"，而应找根本原因]],

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

--- 确保配置向后兼容
-- 将旧的配置结构转换为新的结构
-- @param config 用户配置
-- @return table 转换后的配置
function M.ensure_backward_compatibility(config)
  if not config then
    return {}
  end

  -- 如果用户提供了旧的 keymaps 结构，转换为新的结构
  if config.keymaps and type(config.keymaps) == "table" then
    -- 检查是否是旧的结构（没有 chat 和 tree 子表）
    if config.keymaps.open and not config.keymaps.chat then
      -- 创建新的结构
      local new_keymaps = {
        chat = {
          global = {},
          normal = {},
          insert = {},
        },
        tree = {
          normal = {},
        },
      }

      -- 转换全局快捷键
      if config.keymaps.open then
        new_keymaps.chat.global.open = { key = config.keymaps.open, desc = "打开聊天" }
      end
      if config.keymaps.new then
        new_keymaps.chat.global.new = { key = config.keymaps.new, desc = "新建会话" }
      end

      -- 转换普通模式快捷键
      if config.keymaps.close then
        new_keymaps.chat.normal.close = { key = config.keymaps.close, desc = "关闭聊天" }
        new_keymaps.chat.normal.close_esc = { key = "<Esc>", desc = "关闭聊天" }
      end
      if config.keymaps.normal_mode_send then
        new_keymaps.chat.normal.normal_mode_send =
          { key = config.keymaps.normal_mode_send, desc = "发送消息或编辑" }
      end

      -- 转换插入模式快捷键
      if config.keymaps.insert_mode_send then
        new_keymaps.chat.insert.send = { key = config.keymaps.insert_mode_send, desc = "发送消息" }
      end
      new_keymaps.chat.insert.newline = { key = "<CR>", desc = "换行" }
      new_keymaps.chat.insert.close = { key = "<C-c>", desc = "关闭聊天" }

      -- 设置默认的聊天界面快捷键
      new_keymaps.chat.normal.edit_message = { key = "e", desc = "编辑消息" }
      new_keymaps.chat.normal.toggle_reasoning = { key = "r", desc = "切换推理内容显示" }
      new_keymaps.chat.normal.export_session = { key = "s", desc = "导出会话" }

      -- 替换旧的 keymaps
      config.keymaps = new_keymaps
    end

    -- 如果用户提供了旧的 tree_keymaps 结构，转换为新的结构
    if config.tree_keymaps and not config.keymaps.tree then
      config.keymaps.tree = {
        normal = {},
      }

      if config.tree_keymaps.new_branch then
        config.keymaps.tree.normal.new_branch = { key = config.tree_keymaps.new_branch, desc = "新建分支" }
      end
      if config.tree_keymaps.new_conversation then
        config.keymaps.tree.normal.new_conversation =
          { key = config.tree_keymaps.new_conversation, desc = "新建空对话" }
      end
      if config.tree_keymaps.delete_turn then
        config.keymaps.tree.normal.delete_turn = { key = config.tree_keymaps.delete_turn, desc = "删除当前轮次" }
      end
      if config.tree_keymaps.delete_branch then
        config.keymaps.tree.normal.delete_branch =
          { key = config.tree_keymaps.delete_branch, desc = "删除当前分支" }
      end
      if config.tree_keymaps.open_config then
        config.keymaps.tree.normal.open_config = { key = config.tree_keymaps.open_config, desc = "打开配置文件" }
      end

      -- 设置默认的树视图快捷键
      config.keymaps.tree.normal.select_or_create = { key = "<CR>", desc = "选择会话" }
      config.keymaps.tree.normal.close = { key = "q", desc = "关闭" }
      config.keymaps.tree.normal.close_esc = { key = "<Esc>", desc = "关闭" }
      config.keymaps.tree.normal.refresh = { key = "r", desc = "刷新树" }

      -- 删除旧的 tree_keymaps
      config.tree_keymaps = nil
    end
  end

  return config
end

return M
