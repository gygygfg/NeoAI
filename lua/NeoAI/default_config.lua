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
        api_key = os.getenv("QWEN_API_KEY") or "",
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
      send = { insert = { key = "<C-s>", desc = "发送消息" }, normal = { key = "<CR>", desc = "发送消息" } },
      cancel = { key = "<Esc>", desc = "取消生成" },
      toggle_reasoning = { key = "r", desc = "切换思考过程显示" },
      switch_model = { key = "m", desc = "切换模型" },
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
    approval = {
      mode = "prompt", -- prompt | auto_allow | strict
      default_auto_allow = false,
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
        run_command = { auto_allow = false, allowed_directories = { "./" }, allowed_param_groups = { "ls", "wc", "find", "grep", "pwd" } },
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
