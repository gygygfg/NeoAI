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
    render = {
      -- 把 CPU 密集计算（如工具结果裁剪的码点统计/切片）分配到 utils.work 线程池，
      -- 避免 MB 级工具结果在发送/压缩路径阻塞主线程。设为 false 或线程池不可用时
      -- 自动回退主线程同步计算（行为等价，仅慢）。
      threaded = true,
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
        sandbox = "NeoAISandboxPending",
        sandbox_danger = "NeoAISandboxDanger", -- 待审含 L3 高危时的红色危险高亮
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
      delete_dialog = { key = "d", desc = "删除当前轮次" },
      delete_branch = { key = "D", desc = "删除整个会话分支" },
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
      sandbox_review = { key = "<leader>ap", desc = "查看并应用待审的沙箱修改" },
      approval = {
        confirm = { key = "<CR>", desc = "允许一次" },
        confirm_all = { key = "A", desc = "允许所有" },
        add_to_workspace = { key = "D", desc = "允许并加入工作目录" },
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
    log_compaction = {
      enabled = true,
      max_redundant_records = 64, -- 旧快照达到此条数时原子合并
      min_bytes = 8 * 1024 * 1024, -- 超过此大小且日志至少为最新快照总量的两倍时合并
    },
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
      max_read_bytes = 5 * 1024 * 1024, -- 整读硬上限（字节）：超过则拒绝整读并提示用行范围，避免 OOM
    },
    search_files = {
      max_file_bytes = 8 * 1024 * 1024, -- 单文件扫描上限（字节）：超过则跳过，避免大文件 OOM；二进制文件跳过
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
      format = "markdown", -- 默认输出格式：markdown | text（只输出正文，不含原始 HTML）
      timeout_ms = 45000, -- 单次抓取总超时（ms，含启动浏览器）；<=0 时用 nav_timeout_ms + 15s
      nav_timeout_ms = 30000, -- 页面导航/等待超时（ms）
      max_bytes = 2 * 1024 * 1024, -- 单次返回内容上限（字节，超出截断）
      -- ↓ 图片处理：正文中的图片不写入 Markdown，而是转存到临时目录（mktemp -d，退出 nvim 时删除），
      --   正文原位保留 [image: 路径] 占位符，可按需用 read_image 查看。
      max_images = 50, -- 单次抓取最多转存图片数（超出直接丢弃）
      max_image_bytes = 5 * 1024 * 1024, -- 单张图片字节上限（超出则占位符回退为原始 URL）
      image_timeout_ms = 15000, -- 单张远程图片下载超时（ms）
      install_timeout_ms = 600000, -- 依赖安装超时（ms，首次下载浏览器内核可能较久）
      node_path = "", -- 自定义 node 可执行文件路径（空则用 PATH 中的 node）
      install_os_deps = false, -- 安装浏览器时是否附带系统依赖（需要 root/sudo，一般无需开启）
      -- ↓ 受限网络（国内镜像 / 代理异常）下的下载与代理控制；默认全空 = 完全沿用系统行为
      npm_registry = "", -- npm 源；空则用系统 npm 配置。国内可设 "https://registry.npmmirror.com/"
      playwright_download_host = "", -- 浏览器内核下载基址；空则用官方 CDN。国内可设 "https://registry.npmmirror.com/-/binary/playwright"
      http_proxy = "", -- 安装/渲染时显式设置的 HTTP 代理；空则不覆盖继承值
      https_proxy = "", -- 安装/渲染时显式设置的 HTTPS 代理；空则不覆盖继承值
      ignore_system_proxy = false, -- true = 安装/渲染时清空继承的代理变量（应对本机代理损坏/不可用）
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
      mode = "async", -- async（默认，异步审批：立即沙箱执行，事后确认应用）| prompt | auto_allow | strict
      default_auto_allow = false,
      timeout_ms = 60000, -- 审批弹窗超时（ms），防止弹窗丢失后工具循环永久挂起
      -- 全局工作区允许目录：对所有工具生效，且包含其全部子目录（配置后子目录无需逐个审批）。
      -- 工具自身与 per_tool 的 allowed_directories 与之并集（只追加，不覆盖全局工作区）。
      allowed_directories = {},
      -- 全局命令白名单：命令首词命中即视为参数安全（与工具自身/ per_tool 并集）。
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
    -- 工具执行沙箱（对齐《Agent 沙箱 dry-run 与 commit 架构设计 v2》）。
    -- 所有工具执行经控制面：预检 → 隔离执行 → 冻结候选 → 校验授权 → CAS 发布。
    -- 默认 dry_run：只产出候选，不写真实工作区；用 :NeoAISandboxCommit 显式应用。
    sandbox = {
      enabled = true, -- 总开关；关闭且 fail_closed=true 时拒绝所有工具执行
      fail_closed = true, -- 沙箱服务缺失/被禁用时是否拒绝执行（不得静默降级）
      mode = "dry_run", -- dry_run（默认，仅出候选）| commit（授权后立即 CAS 发布）
      backend = "auto", -- auto | bwrap | unshare（外部隔离后端）
      offline = false, -- 网络默认放行（仅记录审计，不拦截）；true 时硬拒绝网络类工具并隔离进程网络
      require_seccomp = true, -- true 时缺少 seccomp 能力则拒绝外部执行（默认开，fail-closed）
      -- 载荷 capability：默认**最小权限**（`{}` → `--cap-drop ALL`）。需要的能力按命令
      -- **窄范围**加回（包安装经 `packages.cap_add`，纯包安装命令才授予；混合命令不授予）。
      -- 宿主不可修改由
      -- **命名空间（mount/pid/uts/ipc/cgroup）+ 整机根 overlay（`read_all` 默认，根文件系统
      -- 原样可写、写入全部进 upper 暂存）+ 宿主敏感路径遮蔽 + `/proc/sys` 只读绑定 +
      -- seccomp（含 mknod/mknodat 设备节点屏障）**
      -- 保证：所有写入进入 overlay 私有层并冻结为候选，真实系统不受影响，危险 syscall 与设备
      -- 节点创建被拦。仅在明确需要完整能力时（不推荐）才设为 `{ "ALL" }`。
      cap_add = {},
      -- 载荷运行身份：默认以 **root** 运行（uid=0），使 AI 能在沙箱内使用宿主工具链
      -- （/root 下的 nvm/cargo/go 等，0700 目录非 root 不可遍历）与包管理（dpkg 硬检查
      -- euid==0）。**所有写入仍全部进入 overlay 暂存并冻结为候选，真实磁盘不受影响**；隔离由
      -- 命名空间 + 整机根 overlay + seccomp + 遮蔽保证，不依赖非 root。
      --   * 非 root 启动 NeoAI：用 user namespace 把当前用户映射为**沙箱内 guest root**
      --     （euid=0，仅命名空间内有效；宿主身份仍是当前非 root 用户）。本项被忽略。
      --   * root 启动 NeoAI：uid=0 表示不降权（默认）；设为专用非 root uid（如 nobody 65534）
      --     可加固——bwrap 仍以 root 完成挂载，仅载荷经 `setpriv` 降权（配置的窄能力以
      --     ambient 形式保留）。注意：非 root 载荷无法遍历 /root，且 dpkg 等会因 euid!=0 失败。
      run_as = {
        uid = 0, -- 默认 0：root 启动时不降权（工具链/包管理可用；写入仍全部暂存）
        gid = 0,
      },
      -- 主机全局能力收敛（默认）：即使 cap_add 含 ALL，也逐项丢弃「可修改宿主全局状态」的能力。
      -- 这些能力与开发/包管理工作流无关（node/python/apt 不需要），丢弃后 netlink 改宿主路由/
      -- 防火墙、改宿主时钟、加载内核模块、裸端口 I/O、重启、改 MAC/审计策略均被 EPERM 拦截。
      -- 显式在 cap_add 中列出的能力不会被丢弃；设 `{}` 可保留字面完整能力（不推荐）。
      cap_drop = {
        "CAP_NET_ADMIN",     -- 网络栈配置（netlink 改路由/防火墙/接口）
        "CAP_SYS_TIME",      -- 系统时钟
        "CAP_SYS_MODULE",    -- 内核模块加载/卸载
        "CAP_SYS_RAWIO",     -- 裸端口/设备 I/O（ioperm/iopl）
        "CAP_SYS_BOOT",      -- 重启/关机/kexec
        "CAP_MAC_ADMIN",     -- MAC（SELinux/AppArmor）策略
        "CAP_MAC_OVERRIDE",  -- MAC 策略绕过
        "CAP_AUDIT_CONTROL", -- 审计子系统配置
      },
      -- 单文件纳入候选的大小上限（字节）：超过则不纳入候选（写入仍在 overlay 私有层，不落真实盘），
      -- 避免把 apt/pkgcache.bin、缓存归档、镜像层等超大文件嵌入候选 JSON 而阻塞主线程 / 撑爆磁盘。
      -- 0 = 不限制。默认 8 MiB。
      max_file_bytes = 8 * 1024 * 1024,
      -- 每个工作线程任务的候选文件数：冻结/哈希按此分块并发提交到线程池（默认 4 线程），
      -- 使 npm/cargo 等产生大量文件的命令用满多核而非单核串行。0/缺省 = 128。
      work_chunk_files = 128,
      -- 在隔离环境内遮蔽的宿主敏感路径（安全默认）：目录以空 tmpfs 遮蔽，
      -- 文件/socket 以 /dev/null 覆盖。含 docker.sock（= 宿主 root）、容器数据、
      -- 编排器/面板/D-Bus 通道、宿主凭据目录，以及宿主身份/日志/命令历史等读取面泄露项。
      -- 空表表示退回 runtime 内置安全默认。
      -- 支持 `*` 通配（如 /root/.cache/keyring-*）。
      mask_paths = {
        "/run/docker.sock", "/var/run/docker.sock",
        "/run/containerd", "/run/containerd/containerd.sock",
        "/var/run/containerd", "/var/lib/docker", "/var/lib/containerd",
        "/run/podman", "/var/run/podman", "/var/lib/containers",
        "/root/.config/herdr", "/etc/1panel", "/run/1panel", "/var/run/1panel",
        "/run/dbus", "/run/systemd",
        "/root/.ssh", "/root/.aws", "/root/.gnupg", "/root/.kube",
        "/root/.docker/config.json", "/root/.netrc", "/root/.git-credentials",
        "/root/.cache/keyring-*", "/root/.cache/at-spi", "/root/.local/share/keyrings",
        -- Git / 版本控制凭据与签名密钥（SSH/GPG、credential store、netrc、gh token）：
        -- 覆盖 root 与非 root 用户 home（`/home/*`），避免 AI 经 run_command/read_file 读取后外传。
        "/root/.config/git/credentials", "/root/.git-credential-cache",
        "/root/.config/gh",
        "/home/*/.ssh", "/home/*/.gnupg", "/home/*/.netrc",
        "/home/*/.git-credentials", "/home/*/.config/git/credentials", "/home/*/.git-credential-cache",
        "/home/*/.config/gh", "/home/*/.aws", "/home/*/.kube", "/home/*/.docker/config.json",
        "/home/*/.cache/keyring-*", "/home/*/.local/share/keyrings",
        -- 本机 SSH 服务：sshd 运行目录 + ssh-agent / gpg-agent 套接字（禁止沙箱访问本机 ssh 服务）
        "/run/sshd", "/run/sshd.pid", "/run/ssh-agent.socket",
        "/run/user/*/keyring", "/run/user/*/keyring/ssh", "/run/user/*/ssh*",
        "/run/user/*/gnupg*", "/tmp/ssh-*", "/root/.ssh-agent",
        -- 宿主身份与凭据
        "/etc/shadow", "/etc/shadow-", "/etc/gshadow", "/etc/gshadow-",
        "/etc/sudoers", "/etc/sudoers.d", "/etc/machine-id", "/etc/hostid",
        "/etc/ssh", "/etc/ssl/private", "/etc/ipa", "/etc/krb5.keytab",
        -- 日志、计划任务与审计
        "/var/log", "/var/spool/cron", "/etc/crontab", "/etc/cron.d",
        "/etc/cron.daily", "/etc/cron.hourly", "/etc/cron.weekly", "/etc/cron.monthly",
        -- root 命令历史与残留（经 /root overlay 可达时）
        "/root/.bash_history", "/root/.zsh_history", "/root/.sh_history",
        "/root/.python_history", "/root/.mysql_history", "/root/.psql_history",
        "/root/.sqlite_history", "/root/.node_repl_history", "/root/.wget-hsts",
        "/root/.lesshst", "/root/.viminfo", "/root/.config/gh", "/root/.config/gcloud",
      },
      -- 读取面（默认开）：true 时整机根以**可写 overlay** 方式暴露——以 `/` 为只读 lower、
      -- 会话私有 upper/work 为可写层（原样挂载、根内任意路径可写），所有写入进 upper 暂存并
      -- 冻结为候选，宿主盘不受影响；仅遮蔽 `mask_paths` 中的重要配置文件/凭据（~/.ssh、
      -- ~/.aws、/etc/shadow、sudoers、docker.sock 等）与沙箱自身存储；`mask_dirs`
      -- （home/root 兄弟目录）不再挂载遮蔽，但访问 cwd 之外的用户目录会**留痕**并在审批悬浮窗
      -- 展示（见 trace）。overlay 不可用时退回只读根（`overlay_fail_closed` 决定是否降级）。
      -- false 时退回最小只读白名单（`readonly_roots`/`readonly_paths`）——更小读取面。
      read_all = true,
      -- 最小只读系统集（白名单）：仅这些宿主根/子树以只读方式暴露给外部命令；未列出的
      -- 路径在沙箱内不存在（不再 `--ro-bind / /`）。`/home`、`/var/log`、`/etc/shadow`、
      -- `/opt`、`/srv`、`/mnt`、`/media`、`/boot` 等默认不可达。
      -- 仍不整目录暴露 `/usr`（避免泄露 `/usr/local/go_workspace`、`/usr/src` 等），但把
      -- `/usr/share` 与 `/var/lib` 整目录只读暴露，使 run_command 能读取运行时共享数据
      -- （nodejs/dotnet/java/git-core/terminfo 等）与宿主包数据库（dpkg/apt/rpm 等）。
      -- 危险/敏感子路径由 `mask_paths` 遮蔽（如 /var/lib/docker、/var/lib/containerd）。
      -- `/lib*`、`/bin`、`/sbin` 为指向 `/usr/lib*`、`/usr/bin`、`/usr/sbin` 的符号链接，
      -- 必须保留（动态加载器），否则任何二进制无法启动。支持 `*` 通配；不存在的条目跳过。
      -- 仅在 `read_all=false` 时生效（见下）。
      readonly_roots = {
        -- 动态加载器与二进制符号链接根（必须）
        "/lib", "/lib32", "/lib64", "/libx32", "/bin", "/sbin",
        -- 运行时可执行文件、共享库与头文件
        "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/lib32", "/usr/lib64", "/usr/libx32",
        "/usr/libexec", "/usr/include",
        -- 运行时共享数据：整目录只读暴露（nodejs/dotnet/java/git-core/terminfo 等）
        "/usr/share",
        -- 本地安装工具与 Go 工具链（不含 /usr/local/go_workspace、/usr/local/src、/usr/local/man）
        "/usr/local/bin", "/usr/local/sbin", "/usr/local/lib", "/usr/local/libexec",
        "/usr/local/include", "/usr/local/go",
        -- 宿主系统状态/包数据库：整目录只读暴露（dpkg/apt/rpm 等）；危险子路径仍由 mask_paths 遮蔽
        "/var/lib",
      },
      -- 最小 /etc 必要文件（白名单）：命令运行所需，避免整目录暴露（含 shadow/machine-id/ssh）。
      -- 注意 `/etc/resolv.conf` 不在此列，见下方 `resolv_conf`。
      readonly_paths = {
        "/etc/ld.so.cache", "/etc/ld.so.conf", "/etc/ld.so.conf.d",
        "/etc/passwd", "/etc/group", "/etc/nsswitch.conf",
        "/etc/hosts", "/etc/hostname", "/etc/host.conf",
        "/etc/localtime", "/etc/timezone", "/etc/os-release", "/etc/debian_version",
        "/etc/ssl", "/etc/ca-certificates", "/etc/ca-certificates.conf",
        "/etc/alternatives", "/etc/terminfo", "/etc/mime.types", "/etc/shells",
        "/etc/environment", "/etc/profile", "/etc/profile.d", "/etc/bash.bashrc",
        "/etc/inputrc", "/etc/security", "/etc/pam.d", "/etc/xdg", "/etc/fonts",
        "/etc/gitconfig", "/etc/npmrc", "/etc/apt", "/etc/dpkg",
        "/etc/python3*",
      },
      -- 宿主运行时直通（opt-in）：这些宿主路径在遮蔽/临时根之后以只读方式暴露进沙箱，
      -- 并把这些目录前置到沙箱进程 PATH，使 `run_command` 能调用宿主工具链
      -- （如 nvim/lua/luajit/mason 二进制）。默认空（保持最小读取面）。
      -- 安全提示：仅暴露可信、只读的工具目录；不要放入凭据/密钥目录。
      expose_paths = {},
      -- 是否把 expose_paths 中的目录前置到沙箱 PATH（默认开）。关闭则仅挂载不改 PATH。
      expose_path_env = true,
      -- 自动直通宿主 PATH 中的工具目录（opt-in，默认关）：开启后把宿主 PATH 里存在、
      -- 且非凭据/系统目录的 bin 目录只读暴露并前置到沙箱 PATH，使 node/npm/fd/go 等
      -- 装在 $HOME 下的工具链在沙箱内可用。会扩大读取面，仅在需要时开启。
      expose_tool_paths = false,
      -- AppImage 支持（默认开）：沙箱内运行 AppImage 时自动注入
      -- APPIMAGE_EXTRACT_AND_RUN=1，让其解包到会话私有 /tmp 运行，而不是尝试 FUSE 挂载。
      -- 沙箱按设计拦截 mount/新挂载 API 且不暴露 /dev/fuse，故 FUSE 挂载不可用；解包运行
      -- 不扩大权限。非 AppImage 程序忽略该变量，无副作用；设为 false 可关闭。
      appimage_extract_and_run = true,
      -- /etc/resolv.conf 处理方式：sanitize（默认，仅保留 nameserver 行，剥离
      -- search/domain/options，避免泄露宿主内网/Tailscale 域）| hide（不暴露）|
      -- passthrough（原样暴露宿主文件）。
      resolv_conf = "sanitize",
      -- 每会话私有临时根：始终以会话私有目录（mode 1777，位于 /dev/shm 等 tmpfs）绑定，
      -- 绝不作为 overlay 的只读 lower 暴露宿主真实内容；退出/轮换会话即销毁，杜绝跨会话残留。
      tmpfs_roots = { "/tmp", "/var/tmp" },
      -- 临时候选根（默认同 tmpfs_roots）：这些根（cwd 子树除外）下的文件写入为**会话私有、
      -- nvim 退出即丢弃**，不进入待审队列、不 CAS 发布、也不弹审批悬浮窗（内容仅在暂存层，
      -- 供本次会话读取一致）。设为 `{}` 可关闭（/tmp 下也走正常待审/审批）。
      ephemeral_roots = { "/tmp", "/var/tmp" },
      -- 临时根私有目录位置：host（默认）= 建在宿主根之下的隐藏临时子目录
      -- （如 /tmp/.cache-<tag>/<session>），命名空间映射回该根，AI 只见自己的私有子目录
      -- （隔离 AI，宿主 /tmp 内容不可见）；session = 建在会话进程目录下（旧行为）。
      tmp_private_base = "host",
      -- 隐藏的 /proc 泄露项：procfs 全局可见（不随 pid namespace 隔离），会泄露宿主内核
      -- 命令行（root=UUID、crashkernel）与内核版本；以空文件只读覆盖，读取得到空内容。
      hide_proc_paths = { "/proc/cmdline", "/proc/version" },
      -- 遮蔽目录（默认开启）：这些目录下除 cwd 路径外的内容对外部命令不可见。
      -- cwd 位于某遮蔽目录下时，仅暴露并遮蔽「含 cwd 的用户 home」作用域
      -- （`/home` 取一级用户子目录，其他目录取自身）；沿 cwd 祖先链遮蔽兄弟条目
      -- （含隐藏文件/目录），cwd 子树自身豁免；cwd 即作用域时遮蔽其隐藏子条目。
      -- 工具命中遮蔽条目时弹窗审批（复用 tools.approval 弹窗），批准后对该次调用解除遮蔽。
      -- 注意：`read_all=true`（默认）时本组配置**不生效**（目录不再挂载遮蔽/审批），
      -- 改为只读放行 + 越界访问留痕（见 read_all 与 sandbox.trace）。
      mask_dirs_enabled = true, -- 总开关（默认开）
      mask_dirs = { "/home", "/root" }, -- 遮蔽目录列表（支持 * 通配）
      mask_dirs_approval = true, -- 命中遮蔽目录时是否弹窗审批（false = 直接硬遮蔽）
      -- 受控网络网关（阶段三）：offline=false 时按声明端点放行，并受字节预算约束。
      network = {
        enabled = false, -- 是否允许受控联网（默认关闭）
        allowed_endpoints = {}, -- 允许的主机/URL 模式，如 "api.example.com"、"*.example.com"
        budget_bytes = 0, -- 累计字节预算（0 = 不限制）
        -- 沙箱外部命令代理策略：
        --   "strip"（默认）= 不把宿主代理传入沙箱（如 mihomo 只代理 opencode 自身；
        --                    避免宿主 HTTPS_PROXY=127.0.0.1:7890 在沙箱内不可达导致 pip/npm 失败）；
        --   "passthrough"  = 沿用宿主代理；
        --   table { http, https, all, no_proxy } = 显式设置（未列出的代理变量清除）。
        proxy = "strip",
        -- 拦截向宿主本机（回环、宿主网卡 IP、链路本地、云元数据）的访问（默认开）：
        -- 沙箱外部命令注入 HTTP(S)_PROXY/ALL_PROXY 指向宿主侧 Lua 过滤代理（host_proxy），
        -- 代理拦截本机目标、放行外部并记录；网络整体仍为「放行 + 记录」。
        -- 边界：应用层过滤——不认代理的裸 TCP 可绕过（共享 netns 无法按目的地做内核过滤）。
        host_local_block = true,
        -- 宿主过滤代理监听端口（0 = 自动分配 loopback 随机端口）。
        host_local_proxy_port = 0,
        -- 独立 netns + 宿主网关（opt-in）：沙箱进程进入隔离网络命名空间，只能到达宿主网关；
        -- 网关对目标 host:port 先做 TCP connect 探针（可探测宿主哪些端口在监听），但不回传
        -- 真实服务数据，而是把拦截原因（JSON）返回给客户端。仅允许探测宿主本机地址。
        -- 需 root 与 ip（ip netns）；不可用时 fail-closed。启用后 curl/wget/git/nmap --proxies
        -- 等走代理的工具可探测端口；直接裸 TCP 不经代理无法到达宿主。
        gateway = {
          enabled = false, -- 总开关
          probe_timeout_ms = 1000, -- 单次端口探针超时
          max_probes = 4096, -- 探测记录上限（防滥用）
        },
      },
      -- 内核级行为观测（eBPF / strace / procfs）：以实际 syscall 判定「越界访问」与
      -- 「密钥文件访问」，替代/补充命令字符串解析启发式；事件按 attempt cgroup 精确归属。
      -- 后端优先级 auto：ebpf(bpftrace，需 root) → strace（命令前缀包裹）→ procfs(/proc/<pid>/fd)。
      -- 均不可用时自动回退命令解析启发式（tools/executor），不阻断工具执行。
      observe = {
        enabled = true, -- 总开关（关闭后直接使用命令解析启发式）
        backend = "auto", -- "auto" | "ebpf" | "strace" | "procfs" | "heuristic"
        poll_ms = 200, -- procfs/strace 轮询间隔（毫秒）
        notify = true, -- 启动时探测后端：eBPF/strace 不可用或发生回退时 vim.notify
        -- 探针挂载等待（毫秒）：0（默认）= 不阻塞命令，挂载异步完成（best-effort，早期访问
        -- 可能漏观测，由命令解析启发式兜底）；设为正值则在命令执行前有界等待，观测更全但
        -- 每条命令会固定增加该等待（bpftrace 挂载约 0.5s）。
        wait_ready_ms = 0,
        -- 观测预热（默认开）：进程命令返回后，在 AI 生成下一轮的间隙后台预创建下一个
        -- attempt 的 cgroup 并挂载 eBPF 探针，使约 0.5s 的挂载与 AI 输出重叠；下一条进程
        -- 命令直接复用已挂载探针，无需等待。仅 eBPF 后端生效（strace/procfs 启动廉价）。
        prewarm = true,
        -- 预热有效期（毫秒）：超时未被下一条进程命令复用则回收（停止探针、释放 cgroup）。
        prewarm_ttl_ms = 90000,
      },
      -- 异步审批（设计文档 §15）：AI 修改立即沙箱执行并冻结候选，      -- 用户异步确认允许哪些文件/配置修改后再 CAS 应用。
      review = {
        enabled = true, -- 效果类候选自动进入待审队列
        auto_apply = false, -- true 时任务授权内自动应用（默认关闭，需用户确认）
        -- AI 新会话自动审批（默认关闭）：开启后 L0/L1 风险自动应用，L2+ 与包/密钥仍待审。
        -- 目的：即便仅靠本地模型的智能水平，也能在写入保护下管理好 agent 行为。
        session_auto_approve = false,
        -- L3（critical）操作二次确认：首次 <CR> 时由 AI 生成后果警告并自动打开 diff，
        -- 需在 diff 内再次确认才真正应用；AI 不可用时回退规则警告，不阻断。
        l3_warning = {
          enabled = true,
          max_tokens = 256, -- 警告正文最大输出
          timeout_ms = 15000, -- 生成超时（ms），超时回退规则警告
        },
        -- AI 审计（待审界面按 `a`）：把原会话的用户消息与分级的待审变更/修改内容的结构化
        -- 文本交给模型**逐条**判断是否允许应用（每个文件/主机命令都要有说明；只出结论，不自动
        -- 应用；结论显示在审批窗顶部与各条目下方）。
        ai_audit = {
          enabled = true,
          auto = false, -- 打开待审审批界面时自动发起 AI 审计（默认关闭；也可按 `key` 手动触发）
          key = "a", -- 待审审批界面内触发 AI 审计的按键
          max_concurrent = 10, -- AI 审计全局并发上限（在途请求数；超出排队，FIFO）
          max_diff_chars = 8000, -- 单个文件 diff 注入上限（超出截断）
          max_user_chars = 4000, -- 单条用户消息注入上限（超出截断）
          max_total_chars = 60000, -- 结构化审计文本总长上限（超出提示截断）
          max_tokens = 2048, -- 审计结论最大输出（逐条说明，需覆盖全部待审项含高危变更）
          timeout_ms = 30000, -- 审计请求超时（ms）
        },
      },
      -- 审批按安全级别分级（见 sandbox/risk.lua）：级别 L0-L3，动作 auto/record/review/block。
      -- 默认 default="review"（全部进入异步待审，不阻塞 agent）；可覆盖单级动作。
      approval = {
        default = "review",
        levels = {}, -- 覆盖：{ [0]="auto", [1]="review", [2]="review", [3]="review" }
      },
      -- 脚本间接执行静态扫描（见 sandbox/script_scan.lua）：命令把执行委托给脚本/解释器
      -- （`bash deploy.sh`、`python setup.py`、`node x.js`、`./run.sh`、`bash -c '…'`）时，
      -- 执行前读取脚本内容（优先沙箱暂存副本）并提取 Shell 正文与高级语言内嵌 shell 调用，
      -- 折叠进危险识别/权限分类；脚本内破坏性命令硬拒绝，其余命中或不透明（eval、base64|sh、
      -- 动态 `-c "$VAR"`、读不到内容等）提升级别并强制复核（不自动应用）。
      script_scan = {
        enabled = true, -- 总开关
        max_depth = 3, -- 递归扫描被引用脚本的最大深度
        max_files = 8, -- 单次扫描最多读取的脚本文件数
        max_bytes = 262144, -- 单个脚本读取上限（字节），超出截断并标记不透明
      },
      -- 安装包（apt/pip/npm 等）额外规则：默认 review（不随自动审批放行，需显式确认）。
      --   review = 强制进入待审；allow = 允许自动应用；deny = 硬拒绝。
      --   managers 同时用于识别包管理器：包安装候选按「安装命令」合并为一个审批单元，
      --   头行标注「包安装 <管理器>: <包名>」，可整包一次应用（privilege.package_info）。
      packages = {
        mode = "review", -- review（安全安装仅需确认、风险封顶中危）| allow（全部放行）| deny（全部拒绝）
        -- 放宽风险与提示：普通安装（apt/pip/npm install …）不因写入 /usr /var /etc 升为高危，
        -- 也不触发密钥误报；仅当命令改动**第三方软件源**（add-apt-repository / sources.list /
        -- --add-repo / --index-url / npm --registry 等）或**密钥/信任链**（apt-key / trusted.gpg /
        -- keyring / gpg --import / rpm --import 等）时标为敏感安装并保留高危评级
        -- （见 privilege.package_sensitive）。包安装仍需用户确认后才写入宿主。
        managers = {
          -- 系统包管理
          "apt", "apt-get", "aptitude", "dnf", "yum", "rpm", "zypper", "pacman", "apk", "brew", "port",
          -- Python
          "pip", "pip3", "pipx", "uv", "uvx", "poetry", "conda", "mamba", "micromamba",
          -- Node
          "npm", "npx", "pnpm", "yarn", "bun", "deno", "corepack",
          -- 其它语言/生态
          "go", "cargo", "rustup", "gem", "bundler", "bundle", "composer",
          "nuget", "dotnet", "vcpkg", "conan", "stack", "mix", "pub",
        },
        -- 包安装按需加回的 capability（受控启动，仅整条命令均为包管理器时授予）：
        -- --cap-drop ALL 下 root 失去 CAP_DAC_OVERRIDE，连 `_apt` 拥有的 0700 目录都不可写；
        -- dpkg/apt/pip/npm 还需要 chown/setuid 等。**不含 CAP_MKNOD**：包管理器不需要
        -- 创建设备节点（Debian 政策禁止包内携带设备节点），且设备节点不经 overlayfs——
        -- 创建块/字符设备即可裸读磁盘、绕过暂存/遮蔽，故由 seccomp 基线硬拦
        -- （mknod/mknodat 的 CHR/BLK 模式返回 EPERM，FIFO/普通文件不受影响）。
        -- 可按需增减（如自建源）；进程仍在 mount/pid 命名空间 + 遮蔽 + overlay 暂存内。
        cap_add = {
          "CAP_DAC_OVERRIDE", "CAP_DAC_READ_SEARCH", "CAP_CHOWN", "CAP_FOWNER",
          "CAP_SETUID", "CAP_SETGID", "CAP_SETFCAP", "CAP_FSETID",
          "CAP_SYS_CHROOT", "CAP_KILL",
        },
        -- 包安装命令的宿主状态目录：命令判定为包安装时这些路径需可写。`read_all=true`
        -- （默认）下整机根已是可写 overlay，本列表仅用于包路径分类/审批合并；`read_all=false`
        -- 或整机 overlay 不可用时，作为额外可写根加入（overlay 暂存），使 apt/dpkg/pip/npm 等
        -- 能写入索引/缓存/元数据与安装目标，写入冻结为候选。支持 `~` 展开；不存在的目录跳过。
        roots = {
          -- 系统级安装目标（apt 安装到 /usr/bin、/usr/games 等；/usr 覆盖 /usr/local、
          -- /usr/lib/node_modules、/usr/share/nodejs 等子路径）与系统状态（/var 覆盖
          -- /var/lib/dpkg、/var/cache/apt、/var/cache/man、/var/log 等）。
          "/usr", "/var",
          -- /etc：dpkg postinst 常写入 /etc（如 libc-bin 刷新 /etc/ld.so.cache，
          -- update-alternatives 写 /etc/alternatives，服务包写 /etc/<svc> 配置）。只读根下
          -- 这些写入会以 "Read-only file system" 失败并让 dpkg 退出码非 0。覆盖为 overlay 后
          -- 写入进会话 upper 并冻结为待审候选；敏感条目（/etc/shadow、/etc/sudoers、/etc/ssh、
          -- /etc/cron* 等）仍由 mask_paths 遮蔽，不受影响。
          "/etc",
          -- 用户级安装/缓存目标
          "~/.cache", "~/.npm", "~/.nvm", "~/.cargo", "~/.rustup", "~/.gem", "~/.composer",
          "~/go", "~/.local",
        },
      },
      -- 容器受控运行：AI 调用 docker/podman 等时尽量与沙箱同 namespace（受控）。
      -- podman 等无守护进程运行时注入 --net/pid/ipc/uts=host 共享沙箱命名空间；
      -- docker 依赖外部 daemon，保持受控 socket 方案并记录原因。
      container = {
        enabled = true,
        share_namespace = true, -- 对无守护进程运行时注入命名空间共享标志
        prefer = "podman", -- 优先使用的无守护进程运行时（供提示/文档）
      },
      -- 存储基根。每进程实例隔离在 <workspace_root>/instances/<pid>_<启动时间>，
      -- 待审队列/候选/回执/证据不跨 nvim 会话共享（多个会话互不可见对方的审批）。
      workspace_root = vim.fn.stdpath("cache") .. "/NeoAI/sandbox",
      session_shell = true, -- run_command 会话内保留 shell 状态（export/cd 跨命令生效，仅 bwrap 后端）
      -- 额外可写根（仅 `read_all=false` 或整机 overlay 不可用时生效）：这些根以独立 overlay
      -- 覆盖（真实内容只读 lower，写入进会话 upper），使命令能修改这些根下的任意路径并冻结为
      -- 候选；cwd 未覆盖时自动补入。`read_all=true`（默认）时整机根已是可写 overlay，本项不再
      -- 需要。安全默认仅 cwd（自动补入）；不覆盖 `/tmp`、`/var/tmp`（属每会话私有 tmpfs，
      -- 见 `tmpfs_roots`）。需要任意路径写入时按需显式加回（注意同时收紧 mask_paths）。
      process_roots = {},
      -- overlay 不可用（无法为可写根挂载 overlay 可写层）时是否拒绝外部进程执行。
      -- 默认 true（fail-closed）：**不降级**为「私有可写 cwd」——那种视图看不到真实磁盘
      -- 文件，会把「看不到」误判为「文件不存在/改动未生效」。设为 false 才允许降级运行
      -- （命令在会话私有 cwd 执行，结果会附加降级提示）。
      overlay_fail_closed = true,
      retention = {
        candidate_days = 7, -- 未应用候选保留期（天）
        max_pending = 20, -- 每任务最多待审候选数
      },
      policy = {
        version = "1", -- 策略版本（用于审计回放；规则变更时应递增）
        deny_tools = {}, -- 硬拒绝的工具名（用户确认亦不可覆盖）
        rules = {}, -- 受限 Lua 规则（函数数组；返回 { decision, reason_codes }）
      },
      limits = {
        wall_ms = 60000, -- 外部进程墙钟超时（ms）
        -- 动态资源限制（默认开）：未显式设置时按宿主资源推导 CPU/内存/PID 上限，
        -- 防止沙箱内命令（apt、编译、构建等）吃满整机导致卡死。
        dynamic = true,
        memory_ratio = 0.5, -- 内存上限 = 宿主总量 * ratio
        memory_max_bytes = 0, -- 绝对内存上限（>0 时取 min；0 = 不额外限制）
        cpu_cores_max = 4, -- 单任务 CPU 配额上限（核）
        cpu_global_max = 0, -- 所有并发沙箱任务的 CPU 总预算（核；0 = max(1, 核数-1)，留 1 核给 nvim）
        pids_max = 2048, -- PID 上限
        -- 静态显式值（>0 时优先于动态推导）：
        memory_bytes = 0, -- cgroup 内存上限（0 = 用动态值）
        pids = 0, -- cgroup PID 上限（0 = 用动态值）
        cpu_max = 0, -- cgroup CPU 配额（微秒/100ms；0 = 用动态值，如 50000 = 0.5 CPU）
        -- CPU 亲和性：让沙箱进程在 **nvim 当前 CPU 之外**的核上运行，避免与 nvim 抢占同一核。
        --   "auto"（默认）= 绑定到除 nvim 当前 CPU 外的全部核（单核宿主自动跳过）；
        --   "off"/false = 不绑定；"2,3" / "2-3" = 显式 cpuset（需 `taskset`，缺失则跳过）。
        cpu_affinity = "auto",
        cgroup_base = "/sys/fs/cgroup", -- cgroup v2 挂载点
        fail_closed = false, -- cgroup 不可用时是否拒绝执行（默认 false：跳过限制，不阻断）
      },
      seccomp_filter_path = "", -- 可选：编译后 seccomp BPF 过滤器路径（供 bwrap --seccomp）
      -- seccomp 基线：默认开启；经 bwrap 在载荷上施加 denylist 过滤器（拦 mount/
      -- unshare/ptrace/init_module/bpf 等）。与 --cap-drop ALL 共同构成纵深防御。
      seccomp = {
        enabled = true, -- 是否施加 seccomp 基线（仅 bwrap 后端）
        filter_path = "", -- 自定义过滤器路径；空则使用内置 denylist 生成
      },
      -- 权限档位与自动提权（见 docs/sandbox.md §17）：命令默认以最小权限（T0）运行，
      -- 权限不足时自动「发起」升级请求（不静默执行）；T1 在隔离内自动执行并留痕，
      -- T2 在嵌套 userns 内自动执行、主机效果冻结为提案异步审批。
      privilege = {
        enabled = true, -- 总开关；关闭则所有进程固定 T0（不自动提权）
        auto_escalate = true, -- 权限/网络失败时自动发起升级（记录，不静默执行）
        max_tier = 2, -- 允许的最高档位（0 最小权限 | 1 提权 | 2 特权）；超过直接拒绝
        record = true, -- 每次档位裁决/升级写入证据与事件
        tiers = {
          -- T0 默认放行网络（仅记录）但经 host_proxy 拦截本机访问；offline=true 时仍硬隔离。
          -- 档位默认最小权限（--cap-drop ALL）；包安装窄能力由 packages.cap_add 按需加回。
          [0] = { name = "minimal", review = "auto", network = true, cap_add = {}, mounts = {}, unmask = {} },
          -- T1 提权不默认解除 docker.sock 遮蔽：socket 仅在命令被分类为 docker 时按需挂载并解除。
          [1] = {
            name = "elevated", review = "auto", network = true, cap_add = {}, mounts = {}, unmask = {},
          },
          -- T2 特权：嵌套 userns 内完整能力（caps 被 userns 作用域限制，够不到宿主）；
          -- 主机效果冻结为提案异步审批。seccomp 基线（mount/init_module 等）仍然生效。
          [2] = {
            name = "privileged", review = "approve", network = true, userns = true,
            cap_add = { "ALL" }, mounts = {}, unmask = {},
          },
        },
        -- 命令分类规则：命中即提升到对应档位（多条命中取最高档）。
        -- bins = 精确可执行名；bin+subs = 可执行名 + 子命令。
        classify = {
          { tier = 2, name = "privileged", bins = {
            "sudo", "doas", "mount", "umount", "modprobe", "insmod", "rmmod", "kmod",
            "iptables", "ip6tables", "nft", "systemctl", "reboot", "shutdown", "poweroff",
            "kexec", "sysctl", "swapon", "swapoff", "mknod", "chroot", "unshare", "nsenter",
            -- 本机 SSH 服务控制：启动/管理 sshd 或 agent 属特权操作（T2，主机效果需审批）
            "sshd", "ssh-agent", "ssh-add", "ssh-keysign", "gpg-agent",
          } },
          { tier = 1, name = "docker", bins = {
            "docker", "docker-compose", "nerdctl",
          } },
          { tier = 1, name = "container", bins = {
            "podman", "podman-compose", "buildah", "skopeo",
          } },
          { tier = 1, name = "network", bins = {
            "curl", "wget", "ssh", "scp", "sftp", "rsync", "ping", "nc", "ncat", "socat",
            "telnet", "dig", "nslookup", "host", "traceroute", "ftp",
          } },
          { tier = 1, name = "network", bin = "git", subs = {
            "push", "pull", "fetch", "clone", "remote", "ls-remote", "submodule",
          } },
          { tier = 1, name = "package", bin = "npm", subs = { "install", "i", "ci", "add", "update", "publish" } },
          { tier = 1, name = "package", bin = "pnpm", subs = { "install", "i", "add", "update", "publish" } },
          { tier = 1, name = "package", bin = "yarn", subs = { "install", "add", "upgrade", "publish" } },
          { tier = 1, name = "package", bin = "pip", subs = { "install", "download" } },
          { tier = 1, name = "package", bin = "pip3", subs = { "install", "download" } },
          { tier = 1, name = "package", bin = "go", subs = { "get", "install" } },
          { tier = 1, name = "package", bin = "cargo", subs = { "install", "add", "update", "publish" } },
          { tier = 1, name = "package", bin = "gem", subs = { "install", "update" } },
          { tier = 1, name = "package", bin = "composer", subs = { "install", "require", "update" } },
          { tier = 1, name = "package", bins = { "apt", "apt-get", "apt-key", "add-apt-repository", "dnf", "yum", "pacman", "apk", "brew" } },
        },
      },
      -- 受控 docker：不绑定宿主 /var/run/docker.sock。controlled 指向外部受控 socket
      -- （rootless dockerd / docker-socket-proxy / dind），仅提权档位挂载。
      docker = {
        mode = "controlled", -- off（禁用）| controlled（外部受控 socket）| host（宿主 socket，仅 T2）
        socket = "/run/neoai-docker/docker.sock", -- controlled 模式使用的受控 socket 路径
      },
      -- AI 专用沙箱 LSP：AI 的 lsp_* 工具按需克隆编辑器同名 server（名称加 @neoai-sandbox
      -- 后缀），把克隆体放进 bwrap + overlay（工作区根 lower=真实只读，upper=沙箱私有层），
      -- 使其磁盘读取看到 AI 尚未发布的暂存内容，与 run_command/git 读工具共享同一暂存视图。
      -- 编辑器自身的 LSP 不受影响（不全局 hook vim.lsp.rpc.start）。overlay 不可用（如 tmpfs
      -- 工作区）时自动跳过，AI 工具回退编辑器客户端。
      lsp_overlay = {
        enabled = true,
      },
      -- 密钥防护（常开）：基于熵检测高熵密钥，进沙箱替换为随机 token、仅在 commit 还原；
      -- 对 token（加密后的 key）或敏感环境变量名的出现留痕并提级强制待审（悬浮窗警告），
      -- 不终止 Agent；仅当**原始密钥**出现在工具参数或 AI 可见上下文中时硬拦截并终止 Agent
      -- （见 docs/sandbox.md §16）。
      secrets = {
        enabled = true, -- 总开关
        min_length = 20, -- 候选密钥最小长度
        max_length = 200, -- 候选密钥最大长度
        min_entropy = 3.5, -- 香农熵阈值（bits/char）
        min_distinct = 8, -- 最少不同字符数
        exclude_pure_hex = true, -- 排除纯小写十六进制（git SHA/sha256/md5 等哈希）
        -- 缩小密钥认定范围：裸高熵串须呈密钥形态（含 - / _ 分隔符）或处于敏感变量名赋值
        -- 上下文（KEY=/TOKEN:/PASSWORD= 等）才 token 化；纯字母数字/base64（SRI integrity、
        -- 内容哈希、构建产物摘要等）不再误伤 package-lock.json / python -m build。
        -- 设为 false 退回旧的「任意高熵串即密钥」行为。
        entropy_requires_context = true,
        -- 高熵全文扫描仅对疑似密钥文件（~/.ssh、~/.bashrc、/etc/* 等，见 secret.is_secret_path）
        -- 启用，避免对普通文件/工具输出做昂贵的熵计算；具名规则（AKIA/sk-/JWT 等）与敏感
        -- 变量名赋值仍对所有内容生效。设为 false 退回旧的「所有内容都做熵检测」行为。
        entropy_secret_paths_only = true,
        -- AI 生成高熵信息检测（detect_generated）的单次扫描预算：候选文件很多/很大时，
        -- 逐文件全文熵/规则检测会占满主线程。超过预算的文件不再扫描（其余仍扫描），
        -- 0 表示不限制。默认宽松，兼顾安全与卡顿。
        generated_scan_max_bytes = 2 * 1024 * 1024,
        generated_scan_max_files = 200,
        tokenize_env = true, -- 是否对沙箱进程环境变量 token 化（false = 原样注入，调试用）
        -- 具名敏感信息规则（Lua pattern）：命中即脱敏/token 化（无视熵阈值），覆盖
        -- 私钥块、带前缀 token（AKIA/ghp_/sk-…）、JWT、Bearer 等结构化凭据。
        -- 配置 rules 将替换内置规则；extra_rules 在内置/配置规则之外追加。
        extra_rules = {},
        allowlist = {}, -- 额外排除的 Lua pattern 数组（命中不视为密钥）
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

  -- ===== 插件系统（kernel/plugins.lua + plugins/catalog.lua）=====
  plugins = {
    builtin = true, -- 是否登记并启动内置插件（false = 完全自管，不加载默认组合）
    disabled = {}, -- 禁用的插件/服务 id 列表，如 { "ui", "services.mcp" }
    entries = {
      -- 按插件 id 覆盖：
      --   ["tool.shell"] = false,                     -- 禁用该插件
      --   ["services.model_service"] = { module = "my_model_provider" }, -- 替换实现
    },
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
