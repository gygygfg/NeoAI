--- NeoAI 默认配置
--- @module NeoAI.default_config
--- 纯数据，零逻辑。仅提供不可变默认配置，供 config_store 合并。

local M = {}

--- 默认配置
local DEFAULT_CONFIG = {
  ai = {
    default_provider = "deepseek",
    default_model = "auto", -- "auto" = 使用 registry 第一个可用模型
    providers = {
      deepseek = {
        api_type = "openai",
        base_url = "https://api.deepseek.com",
        api_key = os.getenv("DEEPSEEK_API_KEY") or "",
        fetch_models = true,
        models_override = nil,
      },
      openai = {
        api_type = "openai",
        base_url = "https://api.openai.com/v1",
        api_key = os.getenv("OPENAI_API_KEY") or "",
        fetch_models = true,
        models_override = nil,
      },
      anthropic = {
        api_type = "anthropic",
        base_url = "https://api.anthropic.com/v1",
        api_key = os.getenv("ANTHROPIC_API_KEY") or "",
        fetch_models = true,
        models_override = nil,
      },
      google = {
        api_type = "google",
        base_url = "https://generativelanguage.googleapis.com/v1beta",
        api_key = os.getenv("GEMINI_API_KEY") or "",
        fetch_models = true,
        models_override = nil,
      },
      groq = {
        api_type = "openai",
        base_url = "https://api.groq.com/openai/v1",
        api_key = os.getenv("GROQ_API_KEY") or "",
        fetch_models = true,
        models_override = nil,
      },
      together = {
        api_type = "openai",
        base_url = "https://api.together.xyz/v1",
        api_key = os.getenv("TOGETHER_API_KEY") or "",
        fetch_models = true,
        models_override = nil,
      },
      openrouter = {
        api_type = "openai",
        base_url = "https://openrouter.ai/api/v1",
        api_key = os.getenv("OPENROUTER_API_KEY") or "",
        fetch_models = true,
        models_override = nil,
      },
      siliconflow = {
        api_type = "openai",
        base_url = "https://api.siliconflow.cn/v1",
        api_key = os.getenv("SILICONFLOW_API_KEY") or "",
        fetch_models = true,
        models_override = nil,
      },
      moonshot = {
        api_type = "openai",
        base_url = "https://api.moonshot.cn/v1",
        api_key = os.getenv("MOONSHOT_API_KEY") or "",
        fetch_models = true,
        models_override = nil,
      },
      zhipu = {
        api_type = "openai",
        base_url = "https://open.bigmodel.cn/api/paas/v4",
        api_key = os.getenv("GLM_API_KEY") or "",
        fetch_models = true,
        models_override = nil,
      },
      baidu = {
        api_type = "openai",
        base_url = "https://aip.baidubce.com/rpc/2.0/ai_custom/v1/wenxinworkshop",
        api_key = os.getenv("BAIDU_API_KEY") or "",
        fetch_models = true,
        models_override = nil,
      },
      aliyun = {
        api_type = "openai",
        base_url = "https://dashscope.aliyuncs.com/compatible-mode/v1",
        api_key = os.getenv("DASHSCOPE_API_KEY") or "",
        fetch_models = true,
        models_override = nil,
      },
      stepfun = {
        api_type = "openai",
        base_url = "https://api.stepfun.com/v1",
        api_key = os.getenv("STEPFUN_API_KEY") or "",
        fetch_models = true,
        models_override = nil,
      },
    },
    model_refresh = {
      on_startup = true,
      interval_sec = 3600,
      timeout_ms = 10000,
    },
    -- 按三种会话模式（CHAT / PLAN / AUTO）分别配置提供商与模型参数。
    -- 进入某模式时应用该模式对应的 provider/model/temperature/stream，
    -- 系统提示等全局项仍由 ai.system_prompt 提供。缺省字段回退到 ai.default_provider / 默认值。
    -- max_tokens 缺省不配置：请求不发送该参数，由模型/厂商默认最大输出决定；仅在此显式配置时才下发。
    modes = {
      chat = { provider = "deepseek", model = "auto", temperature = 0.7, stream = true },
      plan = { provider = "deepseek", model = "auto", temperature = 0.3, stream = true },
      auto = { provider = "deepseek", model = "auto", temperature = 0.7, stream = true },
    },
    -- 输出被截断（finish_reason=length/max_tokens/MAX_TOKENS）且无工具调用时的处理：
    -- 自动附加续写提示重发（提示只进请求、不落库），直到获得正文/工具调用或达到次数上限；
    -- 仍被截断则写入一条可见提示，避免工具循环静默退出。
    truncation = {
      enabled = true,
      max_continues = 3, -- 单轮最多自动续写次数
      nudge = "请从中断处继续输出，不要重复已输出的内容。",
    },
    reasoning_enabled = true,
    system_prompt = "你是一个AI编程助手，帮助用户解决编程问题。",
    timeout_ms = 60000,
    max_retries = 3,
    -- ===== 多模态 / 附件 =====
    attachments = {
      enabled = true, -- 多模态图像注入总开关（read_image 工具 + 图像消息解析）
      path = vim.fn.stdpath("cache") .. "/NeoAI/attachments", -- 附件存储目录（内容寻址）
      -- 声明支持图像输入的模型（模型 id 或 provider:model；命中则注入图像，否则降级为文本）
      vision_models = {
        "deepseek-v4-flash-vision-exp",
        "deepseek-vl",
      },
      -- 启发式：模型 id 含这些子串即视为视觉模型（可配置，需时清空）
      vision_model_heuristics = { "vision", "-vl", "4o", "gemini" },
      media_types = { "image/png", "image/jpeg", "image/webp", "image/gif" },
      limits = {
        maxImageBytes = 20 * 1024 * 1024, -- 单图字节上限
        maxImagesPerMessage = 16, -- 每条消息图像数上限
        maxMessageImageBytes = 40 * 1024 * 1024, -- 每条消息图像累计字节
        maxImagePixels = 50000000, -- 解码后像素上限（无缩略工具时强拒）
        maxImageDimension = 8000, -- 长边上限
      },
      request_image = {
        maxPixels = 640000, -- 单请求图像像素预算（有 ImageMagick 时缩略到该预算）
        maxBytes = 1024 * 1024, -- 单请求图像编码字节上限
        maxImagesPerRequest = 8, -- 单请求最多保留图像数（超出丢最旧）
        maxRequestBytes = 20 * 1024 * 1024, -- 单请求图像累计字节上限（超出丢最旧）
        maxRequestImages = 600, -- 与 provider 上限对齐的深层兜底
      },
    },
    -- 按模型自动选择策略：能力表（上下文窗口/缓存机制/输出上限）+ 厂商方言（请求参数名/
    -- 推理形态/鉴权头）+ 显式缓存（Anthropic 断点 / OpenAI explicit / Gemini cachedContents）。
    -- 未知模型回退到协议族默认值，不影响既有行为。
    model_policy = {
      enabled = true, -- 总开关（关闭后仅保留三协议基础编解码，不做模型感知推导）
      explicit_cache = {
        enabled = true, -- 显式缓存总开关
        -- anthropic = true, -- 分机制开关（缺省跟随总开关；可单独关闭某一家）
        -- gemini = true,
        openai = false, -- OpenAI 显式断点默认关闭（隐式缓存已足够，避免误写缓存计费）
      },
      -- 模型/提供商级能力覆盖：key 为模型 id 或 provider 名
      -- overrides = {
      --   ["deepseek-v4-flash"] = { window = 131072, max_output = 8192 },
      --   ["my-provider"] = { cache_kind = "openai", chars_per_token = 2 },
      -- },
      -- 方言覆盖：key 为 provider 名或模型 id
      -- dialects = {
      --   ["my-provider"] = { max_tokens_field = "max_completion_tokens", reasoning_kind = "effort" },
      -- },
    },
    context_cache = {
      enabled = true, -- 启用前缀缓存身份一致性 + 自动上下文压缩
      context_window = 64000, -- 模型上下文窗口（token 估算）
      threshold_ratio = 0.8, -- 达到该比例触发压缩
      warn_ratio = 0.85, -- 达到该比例状态栏变色并提示（接近上限）
      retain_ratio = 0.16, -- 保留的最近历史比例（压缩后尾部）
      retain_min_tokens = 4096, -- 尾部保留的下限（token）
      compact_max_tokens = 8192, -- 压缩摘要输出的 token 上限
      min_shadow_messages = 2, -- 至少折叠多少条消息才值得压缩
      compaction_retries = 1, -- 摘要后仍高于阈值时的重试次数
      -- 模型无关的工具结果裁剪：摘要之前先把超长工具结果（read_file/run_command 等）
      -- 裁成「头部 + 省略标记 + 尾部」，多数情况下无需再调用摘要即可回到阈值内。
      prune_enabled = true, -- 裁剪总开关
      prune_threshold_chars = 8192, -- 文本码点超过该值的工具结果才裁剪
      prune_head_chars = 4096, -- 保留的头部码点数
      prune_tail_chars = 1024, -- 保留的尾部码点数
      include_identity = true, -- 系统提示是否包含固定身份段（-100 顺序位）
      identity = "你是一个由 NeoAI 驱动的 AI 编程助手。",
    },
  },

  ui = {
    default_view = "chat",
    window_mode = "tab",
    window = { width = 80, height = 24, border = "rounded" },
    split = { size = 80, direction = "right" },
    colors = {
      background = "Normal",
      border = "FloatBorder",
      user_message = "Comment",
      ai_message = "Normal",
      reasoning = "Type",
      title = "Title",
    },
    tree = {
      foldenable = false,
      foldmethod = "manual",
      foldcolumn = "0",
      foldlevel = 99,
      auto_close_on_select = true, -- 从树选择会话打开聊天后自动关闭树窗口
    },
    input_box = {
      idle_height = 1, -- 光标在主聊天区域时输入框高度
      min_height = 5, -- 光标在输入框内时的最小高度（起始）
      max_ratio = 0.8, -- 输入框随内容增长的上限（主窗口高度占比）
    },
    chat = {
      -- 鼠标滚轮滚到底部时，末行下方允许留出的最大空白行数（0 = 严格贴底不留白）
      mousescroll_max_blank = 3,
      -- 增量刷新：仅重渲染变化的消息块并只写入差异行（默认开启）。
      -- 设为 false 时降级回整 buffer 全量重写（用于排查渲染问题）。
      incremental = true,
    },
    trajectory = {
      log_dir = vim.fn.stdpath("cache") .. "/NeoAI/logs", -- 轨迹日志保存目录（可自定义；缺省 ~/.cache/nvim/NeoAI/logs）
    },
    statusline = {
      enabled = true, -- 是否让 lualine 状态栏组件输出内容（false → 组件返回空串）
      winbar = true, -- 是否在聊天主窗口顶部渲染第二行（模式/显示模式/模型/状态）；false 只保留一行
      parts = { "mode", "model", "usage", "cache", "capacity" }, -- component() 拼接的段顺序
      separator = " ", -- 段间分隔符
      colors = { -- 各段链接的 nvim 高亮组（避免默认灰暗配色）
        mode = "Title",
        display = "Keyword",
        model = "Type",
        usage = "Number",
        cache = "String",
        capacity = "Statement",
        capacity_warn = "WarningMsg",
        capacity_over = "ErrorMsg",
        state = "Function",
        brand = "Title",
        pending = "Warning",
      },
    },
  },

  keymaps = {
    global = {
      toggle_ui = { key = "<leader>aa", desc = "切换UI显示" },
      open_chat = { key = "<leader>ac", desc = "打开聊天界面" },
      open_tree = { key = "<leader>at", desc = "打开树界面" },
      close_all = { key = "<leader>aq", desc = "关闭所有窗口" },
    },
    tree = {
      quit = { key = "q", desc = "关闭会话树" },
      select = { key = "<CR>", desc = "选择节点/分支" },
      new_child = { key = "n", desc = "新建子分支并打开聊天" },
      new_root = { key = "N", desc = "新建根分支并打开聊天" },
      delete_dialog = { key = "d", desc = "删除对话" },
      delete_branch = { key = "D", desc = "删除分支" },
      expand = { key = "o", desc = "展开节点" },
      collapse = { key = "O", desc = "折叠节点" },
    },
    chat = {
      insert = { key = "i", desc = "进入插入模式" },
      quit = { key = "q", desc = "关闭聊天窗口" },
      send = { insert = { key = "<C-s>", desc = "发送消息" }, normal = { key = "<CR>", desc = "发送消息" } },
      cancel = { key = "<Esc>", desc = "取消生成" },
      toggle_reasoning = { key = "r", desc = "切换思考过程显示" },
      switch_model = { key = "M", desc = "切换模型" },
      cycle_mode = { key = "m", desc = "循环切换模式（CHAT/PLAN/AUTO）" },
      cycle_display = {
        insert = { key = "<C-t>", desc = "循环切换显示模式（对话/轨迹）" },
        normal = { key = "T", desc = "循环切换显示模式（对话/轨迹）" },
      },
      reload_display = { key = "<F5>", desc = "热重载当前显示模式插件" },
      tool_approval = { key = "<C-a>", desc = "工具审批" },
      approval = {
        confirm = { key = "<CR>", desc = "允许一次" },
        confirm_all = { key = "A", desc = "允许所有" },
        cancel = { key = "<Esc>", desc = "取消" },
        cancel_with_reason = { key = "C", desc = "取消并说明" },
      },
    },
  },

  session = {
    auto_save = true,
    auto_naming = true,
    save_path = vim.fn.stdpath("cache") .. "/NeoAI",
    max_history_per_session = 1000,
    file = "sessions.jsonl",
  },

  tools = {
    enabled = true,
    builtin = true,
    external = {},
    -- read_file 大文件保护：未指定 start_line/end_line 时，字符数超过
    -- outline_threshold_chars 的文件不再整篇回传，而返回语法树节点大纲
    -- （该文件类型无 tree-sitter parser 时回退为前 outline_preview_lines 行预览），
    -- 防止 AI 一次性意外读取超大文件耗尽上下文。
    read_file = {
      outline_threshold_chars = 500, -- 触发保护的字符数阈值
      outline_max_nodes = 200, -- 大纲最多输出的结构节点数
      outline_max_depth = 4, -- 大纲最大递归深度（相对根节点）
      outline_preview_lines = 50, -- 无 parser 时的预览行数
    },
    lsp = {
      timeout_ms = 10000, -- LSP 请求超时（ms）：服务器无响应时快速失败，避免工具循环挂到 executor 超时
    },
    guard = {
      repeat_tool = {
        enabled = true, -- 检测连续重复工具调用并注入提醒
        thresholds = { 3, 5, 8 }, -- 递增提醒阈值
        messages = {
          [3] = "⚠️ 你已连续多次调用同一个工具并使用相同的参数。如果上一次调用没有达到预期效果，请先读取文件/检查输出，改变参数或换一种做法，而不是原样重试。",
          [5] = "⚠️ 你仍在重复调用相同工具与相同参数（第 5 次）。继续这样执行不会产生新结果。请停下来分析原因：查看错误输出、读取相关文件，或向用户询问意图。",
          [8] = "⚠️ 已连续 8 次重复相同的工具调用。循环将不会自动终止，但建议立即改变策略：考虑用不同的工具、不同的参数，或结束本轮并让用户补充说明。",
        },
      },
    },
    todo = {
      enabled = true, -- 待办清单工具 + 系统提示注入
    },
    -- 网页抓取：把动态网页（React/Vue/SPA）在无头浏览器中渲染后转成 Markdown。
    --
    -- ⚠️ 依赖提示：启用本工具（enabled = true）会自动检查和安装 Node 依赖，
    --   需在系统中预先安装【node 与 npm】（>=18，需在 PATH 中）；随后工具会
    --   在缓存目录（stdpath('cache')/NeoAI/web_fetch）内自动执行：
    --     npm i playwright turndown @mozilla/readability
    --     npx playwright install chromium   （下载浏览器内核，首次较慢）
    --   即启用会安装 node 与 playwright 相关依赖，请确保网络通畅、磁盘充足。
    --   本工具默认【不启用】；不使用 Web 抓取时保持 enabled = false 即可。
    web_fetch = {
      enabled = false, -- 总开关（默认关闭；开启后才会注册工具、安装依赖、抓取）
      auto_install = true, -- 启用后在后台自动检查/安装依赖（关闭则首次调用时按需安装）；安装内容：playwright + turndown + @mozilla/readability + 浏览器内核
      engine = "chromium", -- 浏览器引擎：chromium | firefox | webkit
      format = "markdown", -- 默认输出格式：markdown | text | html
      timeout_ms = 45000, -- 单次抓取总超时（ms，含启动浏览器）；<=0 时用 nav_timeout_ms + 15s
      nav_timeout_ms = 30000, -- 页面导航/等待超时（ms）
      max_bytes = 2 * 1024 * 1024, -- 单次返回内容上限（字节，超出截断）
      install_timeout_ms = 600000, -- 依赖安装超时（ms，首次下载浏览器内核可能较久）
      node_path = "", -- 自定义 node 可执行文件路径（空则用 PATH 中的 node）
      install_os_deps = false, -- 安装浏览器时是否附带系统依赖（需要 root/sudo，一般无需开启）
      -- 注入脚本目录（可扩展/覆盖内置脚本；同名用户脚本优先）
      -- 内置脚本：clean（通用去噪）、readability（正文提取）
      scripts_dir = vim.fn.stdpath("config") .. "/NeoAI/web_fetch/scripts",
      cache = {
        enabled = true, -- 结果缓存开关
        ttl_sec = 3600, -- 缓存有效期（秒）；<=0 表示不过期
        max_entries = 200, -- 缓存条目数上限
        max_bytes = 500 * 1024 * 1024, -- 缓存总大小上限（字节，默认 500MB；超出按最旧优先淘汰）
      },
    },
    plan_mode = {
      enabled = true, -- 计划模式
      auto_execute_on_approve = true, -- 计划经用户确认后自动转入 CHAT 并按任务清单开始执行
      distill_on_execute = true, -- 计划完成、用户以任何非计划模式确认开始时，把计划阶段调研上下文蒸馏为 8 段检查点并替换压缩
      extra_safe_tools = {}, -- 计划模式白名单扩展（只读/信息查询类之外的工具需显式加入）
      mutating_tools = { -- 兼容保留（计划模式可见集已覆盖此语义）
        "edit_file",
        "delete_file",
        "create_directory",
        "ensure_dir",
        "delete_node",
        "lsp_rename",
        "lsp_format",
        "git_rollback",
        "confirm_file_change",
      },
    },
    approval = {
      mode = "prompt", -- prompt | auto_allow | strict
      default_auto_allow = false,
      timeout_ms = 60000, -- 审批弹窗超时（ms），防止弹窗丢失后工具循环永久挂起
      allowed_directories = {},
      allowed_param_groups = {},
      per_tool = {
        read_file = { auto_allow = true },
        edit_file = { auto_allow = false },
        list_files = { auto_allow = true },
        search_files = { auto_allow = true },
        file_exists = { auto_allow = true },
        create_directory = { auto_allow = false },
        ensure_dir = { auto_allow = false },
        delete_file = { auto_allow = false },
        run_command = {
          auto_allow = false,
          allowed_directories = { "./" },
          allowed_param_groups = { "ls", "wc", "find", "grep", "pwd" },
        },
        create_sub_agent = { auto_allow = false },
        get_sub_agent_status = { auto_allow = true },
        cancel_sub_agent = { auto_allow = true },
        git_diff = { auto_allow = true },
        git_log = { auto_allow = true },
        git_status = { auto_allow = true },
        git_commit_detail = { auto_allow = true },
        git_rollback = { auto_allow = false },
        git_file_history = { auto_allow = true },
        git_branch = { auto_allow = true },
        git_auto_commit_config = { auto_allow = true, auto_commit = false },
        log_message = { auto_allow = true },
        get_log_levels = { auto_allow = true },
        lsp_rename = { auto_allow = false },
        lsp_format = { auto_allow = false },
        delete_node = { auto_allow = false },
        web_fetch = { auto_allow = true },
      },
    },
  },

  -- ===== MCP（Model Context Protocol）=====
  mcp = {
    enabled = true, -- 是否启用 MCP 客户端
    timeout_ms = 60000, -- 单次 JSON-RPC 请求超时（ms）
    connect_timeout_ms = 20000, -- 连接/初始化握手超时（ms）
    reconnect = true, -- 连接失败/断开后是否重连
    cache_path = vim.fn.stdpath("cache") .. "/NeoAI/mcp_cache.json", -- 工具/资源/提示描述的本地缓存（预缓存）
    servers = {
      -- [name] = {
      --   transport = "stdio" | "http",
      --   -- stdio:
      --   command = "npx",
      --   args = { "-y", "@modelcontextprotocol/server-filesystem", vim.fn.getcwd() },
      --   env = {},
      --   -- http:
      --   url = "https://example.com/mcp",
      --   headers = { ["Authorization"] = "Bearer ..." },
      --   -- 通用：
      --   expose = { tools = true, resources = true, prompts = true },
      --   approval = { auto_allow = false },
      --   plan_safe = false,
      -- }
    },
    resources = {
      max_result_bytes = 100 * 1024, -- read_resource 单返回内容字节上限
    },
  },

  -- ===== Skills（技能目录 + SKILL.md）=====
  skills = {
    enabled = true, -- 是否启用技能系统
    paths = { -- 扫描目录（展开 ~ / stdpath / 项目相对路径），顺序越前优先级越高
      vim.fn.stdpath("config") .. "/skills",
      vim.fn.stdpath("data") .. "/neoai/skills",
      ".neoai/skills",
      ".claude/skills",
    },
    max_skills_in_prompt = 20, -- 系统提示里列出的技能数量上限
    max_skill_bytes = 64 * 1024, -- load_skill 单技能内容字节上限
    inject_mode = "list", -- list | full | none（系统提示列出方式；list=名称+描述，full=整篇正文）
    persist_loaded = false, -- load_skill 是否同时注册 agent 级提示段使其常驻上下文
    register_tools = true, -- 是否注册 list_skills / load_skill 工具
  },

  herder = {
    enabled = true, -- 是否启用 Herder 终端状态信号上报（还需 HERDR_ENV=1 才真正生效；非 Herder 环境为 no-op）
    source = "custom:neoai", -- 稳定且全局唯一的生命周期权威标识
    agent = "neoai", -- agent 名称（Herder 侧识别用）
  },

  log = {
    level = "WARN",
    path = vim.fn.stdpath("cache") .. "/NeoAI/neoai.log",
    max_size = 10485760,
    max_backups = 5,
    format = "[{time}] [{level}] {message}",
    verbose = false,
  },
}

--- 获取默认配置的深拷贝
--- @return table 默认配置副本
function M.get_default_config()
  return vim.deepcopy(DEFAULT_CONFIG)
end

return M
