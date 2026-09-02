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
    scenarios = {
      chat = { provider = "deepseek", preset = "balanced" },
      coding = { provider = "deepseek", preset = "precise" },
      reasoning = { provider = "deepseek", preset = "deep_think" },
      agent = { provider = "deepseek", preset = "balanced" },
    },
    presets = {
      fast = { model = "auto", temperature = 0.3, max_tokens = 1024, stream = true },
      balanced = { model = "auto", temperature = 0.7, max_tokens = 4096, stream = true },
      precise = { model = "auto", temperature = 0.2, max_tokens = 8192, stream = true },
      deep_think = { model = "auto", temperature = 0.7, max_tokens = 8192, stream = true },
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
    context_cache = {
      enabled = true, -- 启用前缀缓存身份一致性 + 自动上下文压缩
      context_window = 64000, -- 模型上下文窗口（token 估算）
      threshold_ratio = 0.8, -- 达到该比例触发压缩
      retain_ratio = 0.16, -- 保留的最近历史比例（压缩后尾部）
      retain_min_tokens = 4096, -- 尾部保留的下限（token）
      compact_max_tokens = 8192, -- 压缩摘要输出的 token 上限
      min_shadow_messages = 2, -- 至少折叠多少条消息才值得压缩
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
      approve_plan = { key = "P", desc = "确认计划并转入 CHAT 执行" },
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
    plan_mode = {
      enabled = true, -- 计划模式
      auto_execute_on_approve = true, -- 计划经用户确认后自动转入 CHAT 并按任务清单开始执行
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
      },
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
