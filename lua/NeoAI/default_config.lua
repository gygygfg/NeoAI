local M = {}

-- 默认配置
local DEFAULT_CONFIG = {
  -- AI配置
  -- 支持多家AI提供商，按场景（窗口命名、聊天、思考、编码、工具执行、子agent）分配不同预设
  ai = {
    -- 默认使用的预设名称
    default = "balanced",

    -- 提供商定义
    providers = {
      deepseek = {
        api_type = "openai",
        base_url = "https://api.deepseek.com/chat/completions",
        api_key = os.getenv("DEEPSEEK_API_KEY") or "",
        models = { "deepseek-v4-flash", "deepseek-v4-pro" },
      },
      openai = {
        api_type = "openai",
        base_url = "https://api.openai.com/v1/chat/completions",
        api_key = os.getenv("OPENAI_API_KEY") or "",
        models = { "gpt-4o", "gpt-4o-mini", "gpt-4-turbo", "gpt-3.5-turbo" },
      },
      anthropic = {
        api_type = "anthropic",
        base_url = "https://api.anthropic.com/v1/messages",
        api_key = os.getenv("ANTHROPIC_API_KEY") or "",
        models = { "claude-sonnet-4-20250514", "claude-3-5-sonnet-20241022", "claude-3-5-haiku-20241022" },
      },
      google = {
        api_type = "google",
        base_url = "https://generativelanguage.googleapis.com/v1beta/models",
        api_key = os.getenv("GOOGLE_API_KEY") or "",
        models = { "gemini-2.0-flash", "gemini-2.0-flash-lite", "gemini-1.5-pro", "gemini-1.5-flash" },
      },
      groq = {
        api_type = "openai",
        base_url = "https://api.groq.com/openai/v1/chat/completions",
        api_key = os.getenv("GROQ_API_KEY") or "",
        models = { "llama-3.3-70b-versatile", "llama-3.1-8b-instant", "mixtral-8x7b-32768" },
      },
      together = {
        api_type = "openai",
        base_url = "https://api.together.xyz/v1/chat/completions",
        api_key = os.getenv("TOGETHER_API_KEY") or "",
        models = { "meta-llama/Llama-3.3-70B-Instruct-Turbo", "mistralai/Mixtral-8x22B-Instruct-v0.1" },
      },
      openrouter = {
        api_type = "openai",
        base_url = "https://openrouter.ai/api/v1/chat/completions",
        api_key = os.getenv("OPENROUTER_API_KEY") or "",
        models = { "openai/gpt-4o", "anthropic/claude-sonnet-4-20250514", "google/gemini-2.0-flash-001" },
      },
      siliconflow = {
        api_type = "openai",
        base_url = "https://api.siliconflow.cn/v1/chat/completions",
        api_key = os.getenv("SILICONFLOW_API_KEY") or "",
        models = { "deepseek-ai/DeepSeek-V3", "deepseek-ai/DeepSeek-R1", "Qwen/Qwen2.5-72B-Instruct" },
      },
      moonshot = {
        api_type = "openai",
        base_url = "https://api.moonshot.cn/v1/chat/completions",
        api_key = os.getenv("MOONSHOT_API_KEY") or "",
        models = { "moonshot-v1-8k", "moonshot-v1-32k", "moonshot-v1-128k" },
      },
      zhipu = {
        api_type = "openai",
        base_url = "https://open.bigmodel.cn/api/paas/v4/chat/completions",
        api_key = os.getenv("ZHIPU_API_KEY") or "",
        models = { "glm-4-plus", "glm-4-air", "glm-4-flash" },
      },
      baidu = {
        api_type = "openai",
        base_url = "https://aip.baidubce.com/rpc/2.0/ai_custom/v1/wenxinworkshop/chat/completions",
        api_key = os.getenv("BAIDU_API_KEY") or "",
        models = { "ernie-4.0-8k", "ernie-3.5-8k" },
      },
      aliyun = {
        api_type = "openai",
        base_url = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
        api_key = os.getenv("ALIYUN_API_KEY") or "",
        models = { "qwen-plus", "qwen-turbo", "qwen-max" },
      },
      stepfun = {
        api_type = "openai",
        base_url = "https://api.stepfun.com/v1/chat/completions",
        api_key = os.getenv("STEPFUN_API_KEY") or "",
        models = { "step-2-16k", "step-1-8k", "step-1-flash" },
      },
    },

    -- 场景配置：分为窗口命名用、聊天用、思考问题用、编写代码用、执行工具用、子agent用
    -- 每个场景可指定多个 AI 候选（数组），按顺序尝试；也可只传一个（单元素表）
    -- 每个候选为 key-value 表：{ provider = '', model_name = '', ... }
    scenarios = {
      -- 窗口命名用：快速低延迟，使用非推理模型避免 reasoning_content 占用 token
      naming = {
        {
          provider = "deepseek",
          model_name = "deepseek-v4-flash",
          temperature = 0.3,
          max_tokens = 50,
          stream = false,
        },
      },
      -- 聊天用：平衡速度与质量
      chat = {
        {
          provider = "deepseek",
          model_name = "deepseek-v4-flash",
          temperature = 0.7,
          max_tokens = 4096,
          stream = true,
        },
      },
      -- 思考问题用：深度推理
      reasoning = {
        {
          provider = "deepseek",
          model_name = "deepseek-v4-pro",
          temperature = 0.7,
          max_tokens = 8192,
          stream = true,
        },
      },
      -- 编写代码用：高质量代码生成
      coding = {
        {
          provider = "deepseek",
          model_name = "deepseek-v4-pro",
          temperature = 0.2,
          max_tokens = 8192,
          stream = true,
        },
      },
      -- 执行工具用：快速响应
      tools = {
        {
          provider = "deepseek",
          model_name = "deepseek-v4-flash",
          temperature = 0.3,
          max_tokens = 1024,
          stream = true,
        },
      },
      -- 子agent用
      agent = {
        {
          provider = "deepseek",
          model_name = "deepseek-v4-pro",
          temperature = 0.7,
          max_tokens = 4096,
          stream = true,
        },
      },
    },

    -- 全局默认值（当预设中未指定时使用）
    stream = true,
    -- 是否启用深度思考模式（如 DeepSeek 的 reasoning_content）
    -- 开启后 AI 会在回答前展示推理过程，适用于复杂问题
    reasoning_enabled = true,
    system_prompt = "你是一个AI编程助手，帮助用户解决编程问题。",
  },
  -- UI配置
  ui = {
    -- 默认打开的界面: 'tree' (树界面), 'chat' (聊天界面)
    default_ui = "tree",
    -- 窗口模式配置: 'float' (浮动窗口), 'tab' (新标签页), 'split' (分割窗口)
    window_mode = "tab",
    window = {
      width = 80,
      height = 20,
      border = "rounded",
    },
    colors = {
      background = "Normal",
      border = "FloatBorder",
      text = "Normal",
    },
    split = {
      -- 分割大小（列数或百分比）
      size = 80,
      -- chat 窗口分割方向: 'left' 在左侧, 'right' 在右侧
      chat_direction = "right",
      -- tree 窗口分割方向: 'left' 在左侧, 'right' 在右侧
      tree_direction = "right",
    },
    tree = {
      foldenable = false,
      foldmethod = "manual",
      foldcolumn = "0",
      foldlevel = 99,
    },
  },
  -- 键位配置
  keymaps = {
    global = {
      open_tree = { key = "<leader>at", desc = "打开树界面" },
      open_chat = { key = "<leader>ac", desc = "打开聊天界面" },
      close_all = { key = "<leader>aq", desc = "关闭所有窗口" },
      toggle_ui = { key = "<leader>aa", desc = "切换UI显示" },
    },
    tree = {
      select = { key = "<CR>", desc = "选择节点/分支" },
      new_child = { key = "n", desc = "新建子分支" },
      new_root = { key = "N", desc = "新建根分支" },
      delete_dialog = { key = "d", desc = "删除对话" },
      delete_branch = { key = "D", desc = "删除分支" },
      expand = { key = "o", desc = "展开节点" },
      collapse = { key = "O", desc = "折叠节点" },
    },
    chat = {
      insert = { key = "i", desc = "进入插入模式" },
      quit = { key = "q", desc = "关闭聊天窗口" },
      refresh = { key = "r", desc = "刷新聊天窗口" },
      send = {
        insert = { key = "<C-s>", desc = "发送消息" },
        normal = { key = "<CR>", desc = "发送消息" },
      },
      cancel = { key = "<Esc>", desc = "取消生成" },
      edit = { key = "e", desc = "编辑消息" },
      delete = { key = "dd", desc = "删除消息" },
      scroll_up = { key = "<C-u>", desc = "向上滚动" },
      scroll_down = { key = "<C-d>", desc = "向下滚动" },
      toggle_reasoning = { key = "r", desc = "切换思考过程显示" },
      switch_model = { key = "m", desc = "切换模型" },
      newline = { key = "<CR>", desc = "新建行" },
      clear = { key = "<C-u>", desc = "清空输入" },
      tool_approval = { key = "<C-a>", desc = "工具审批" },
      approval = {
        confirm = { key = "<CR>", desc = "允许一次" },
        confirm_all = { key = "A", desc = "允许所有" },
        cancel = { key = "<Esc>", desc = "取消" },
        cancel_with_reason = { key = "C", desc = "取消并说明" },
      },
    },
  },
  -- 会话配置
  session = {
    auto_save = true,
    auto_naming = true, -- 是否自动命名会话
    save_path = vim.fn.stdpath("cache") .. "/NeoAI",
    max_history_per_session = 1000,
  },
  -- 工具配置
  tools = {
    enabled = true,
    builtin = true,
    external = {},
  },
  -- 日志配置
  log = {
    -- 日志级别: 'DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL'
    -- level = "WARN",
    level = "DEBUG",
    -- 输出文件路径（可选，默认输出到文件，避免 print 阻塞消息区域）
    -- output_path = nill,
    output_path = "/root/NeoAI/pack/plugins/start/NeoAI/lua/NeoAI/neoai.log",
    -- 日志格式模板
    format = "[{time}] [{level}] {message}",
    -- 最大文件大小（字节），默认 10MB
    max_file_size = 10485760,
    -- 最大备份文件数量
    max_backups = 5,
    -- 是否启用详细输出（verbose 模式）
    verbose = false,
    -- 是否启用调试打印到控制台
    print_debug = false,
  },

  -- 测试配置
  test = {
    auto_test = false, -- 是否在启动后自动运行所有测试
    delay_ms = 1500, -- 延迟毫秒数（VimEnter后1500毫秒）
  },
}

--- 获取默认配置
--- @return table 默认配置
function M.get_default_config()
  return vim.deepcopy(DEFAULT_CONFIG)
end

return M
