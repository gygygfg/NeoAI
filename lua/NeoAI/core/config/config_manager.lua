local M = {}

local default_config = {
  -- AI配置
  ai = {
    base_url = "https://api.deepseek.com/chat/completions",
    api_key = os.getenv("DEEPSEEK_API_KEY") or "",
    model = "deepseek-reasoner",
    temperature = 0.7,
    max_tokens = 4096,
    stream = true,
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
      send = { key = "<C-s>", desc = "发送消息" },
      cancel = { key = "<Esc>", desc = "取消生成" },
      edit = { key = "e", desc = "编辑消息" },
      delete = { key = "dd", desc = "删除消息" },
      scroll_up = { key = "<C-u>", desc = "向上滚动" },
      scroll_down = { key = "<C-d>", desc = "向下滚动" },
      toggle_reasoning = { key = "r", desc = "切换思考过程显示" },
      newline = { key = "<C-CR>", desc = "新建行" },
      clear = { key = "<C-u>", desc = "清空输入" },
    },
    virtual_input = {
      normal_mode = { key = "<CR>", desc = "发送消息" },
      submit = { key = "<C-s>", desc = "发送消息(Ctrl+s)" },
      cancel = { key = "<Esc>", desc = "取消输入并关闭输入框" },
      clear = { key = "<C-u>", desc = "清空输入" },
    },
  },
  -- 会话配置
  session = {
    auto_save = true,
    save_path = vim.fn.stdpath("data") .. "/neoai_sessions",
    max_history = 100,
  },
  -- 工具配置
  tools = {
    enabled = true,
    builtin = true,
    external = {},
  },
  -- 测试配置
  test = {
    auto_test = false, -- 是否在启动后自动运行所有测试
    delay_ms = 500, -- 延迟毫秒数
  },
}

-- 当前配置
local current_config = {}

--- 初始化配置管理器
--- @param user_config table 用户配置
function M.initialize(user_config)
  -- 合并默认配置和用户配置
  current_config = vim.tbl_deep_extend("force", {}, default_config, user_config or {})
end

--- 获取配置值
--- @param key string 配置键（支持点号分隔，如 "ai.model"）
--- @return any 配置值
function M.get(key)
  if not key then
    return current_config
  end

  local keys = vim.split(key, ".", { plain = true })
  local value = current_config

  for _, k in ipairs(keys) do
    if type(value) == "table" then
      value = value[k]
    else
      return nil
    end
  end

  return value
end

--- 设置配置值
--- @param key string 配置键（支持点号分隔）
--- @param value any 配置值
function M.set(key, value)
  if not key then
    return
  end

  local keys = vim.split(key, ".", { plain = true })
  local target = current_config

  -- 遍历到倒数第二个键
  for i = 1, #keys - 1 do
    local k = keys[i]
    if not target[k] or type(target[k]) ~= "table" then
      target[k] = {}
    end
    target = target[k]
  end

  -- 设置最后一个键的值
  local last_key = keys[#keys]
  target[last_key] = value
end

--- 重置配置为默认值
function M.reset()
  current_config = vim.tbl_deep_extend("force", {}, default_config)
end

--- 获取所有配置
--- @return table 所有配置
function M.get_all()
  return vim.tbl_deep_extend("force", {}, current_config)
end

return M
