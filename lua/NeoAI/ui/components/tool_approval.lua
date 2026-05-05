-- 工具审批悬浮窗组件
-- 显示待审批的工具调用详情，用户通过快捷键操作
-- 所有快捷键和标签由调用方通过 opts.keymaps 传入，组件不维护任何默认值
-- 布局：
--   ╭─ Tool Approval ───────────────────────────────╮
--   │  工具: run_command                              │
--   │  描述: 执行 shell 命令并返回完整的执行结果       │
--   │  参数:                                         │
--   │    command: "ls -la"                            │
--   │────────────────────────────────────────────────│
--   │ ⏎ 允许一次                                     │
--   │ A 允许所有                                      │
--   │ ⎋ 取消                                          │
--   │ C 取消并说明                                    │
--   ╰────────────────────────────────────────────────╯

local M = {}

local ui_init = require("NeoAI.ui.init")

local state = {
  initialized = false,
  active = false,
  buf = nil,
  win = nil,
  tools = {},           -- 工具列表（仅用于回调）
  on_select = nil,      -- 选择回调
  on_cancel = nil,      -- 取消回调
  ns_id = nil,          -- 高亮命名空间
  autocmd_ids = {},     -- 自动命令 ID 列表，用于清理
  _closing = false,     -- 正在关闭中标志，防止重入
}

-- 窗口尺寸
local WIDTH = 66

-- 布局常量（均不含边框，边框由 nvim_open_win 的 border 选项额外占用 2 行）
local HEADER_HEIGHT = 1     -- 标题行
local SEPARATOR_HEIGHT = 1  -- 分隔线
local FOOTER_HEIGHT = 4     -- 4个操作各占一行

-- 默认审批快捷键配置（当 ui_init.get_full_config() 返回空时的后备）
local DEFAULT_APPROVAL_KEYMAPS = {
  confirm = { key = "<CR>", desc = "允许一次" },
  confirm_all = { key = "A", desc = "允许所有" },
  cancel = { key = "<Esc>", desc = "取消" },
  cancel_with_reason = { key = "C", desc = "取消并说明" },
}

--- 初始化
function M.initialize()
  if state.initialized then
    return
  end
  state.ns_id = vim.api.nvim_create_namespace("NeoAIToolApproval")
  state.initialized = true
end

--- 打开工具审批悬浮窗
--- @param tools table 工具列表，每项 { name, description, args, category, raw }
--- @param opts table 选项
---   keymaps: table 快捷键配置
---     { confirm = { keys = {"<CR>"}, label = "允许一次" }, ... }
---   on_select: function(tool, extra_opts) 选择回调
---   on_cancel: function(extra_opts) 取消回调
function M.open(tools, opts)
  if not state.initialized then
    M.initialize()
  end

  opts = opts or {}

  if state.active then
    M.close()
  end

  state._closing = false

  state.tools = tools or {}
  state.on_select = opts.on_select
  state.on_cancel = opts.on_cancel

  -- 创建 buffer
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("filetype", "neoai_tool_approval", { buf = state.buf })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = state.buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = state.buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = state.buf })
  vim.api.nvim_set_option_value("modified", false, { buf = state.buf })
  vim.api.nvim_set_option_value("modifiable", true, { buf = state.buf })

  -- 计算窗口尺寸（nvim_open_win 的 height 不包含边框）
  state.total_height = M._calculate_content_height()
  local total_height = state.total_height

  local screen_width = vim.o.columns
  local screen_height = vim.o.lines
  local win_width = math.min(WIDTH, screen_width - 4)
  local win_col = math.floor((screen_width - win_width) / 2)
  local win_row = math.floor(screen_height * 0.5)
  if win_row + total_height > screen_height - 2 then
    win_row = math.max(1, screen_height - total_height - 2)
  end

  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = "editor",
    width = win_width,
    height = total_height,
    row = win_row,
    col = win_col,
    style = "minimal",
    border = "rounded",
    title = " Tool Approval ",
    title_pos = "center",
  })

  -- 禁止滚动：内容刚好填满窗口，无多余行可滚动
  vim.api.nvim_set_option_value("cursorline", false, { win = state.win })
  vim.api.nvim_set_option_value("wrap", false, { win = state.win })
  vim.api.nvim_set_option_value("number", false, { win = state.win })
  vim.api.nvim_set_option_value("relativenumber", false, { win = state.win })
  vim.api.nvim_set_option_value("signcolumn", "no", { win = state.win })
  vim.api.nvim_set_option_value("foldcolumn", "0", { win = state.win })
  vim.api.nvim_set_option_value("scrolloff", 0, { win = state.win })
  vim.api.nvim_set_option_value("sidescrolloff", 0, { win = state.win })
  vim.api.nvim_set_option_value("statuscolumn", "", { win = state.win })
  -- 确保 buffer 内容刚好填满窗口，无多余空行
  vim.api.nvim_set_option_value("endofline", false, { buf = state.buf })
  vim.api.nvim_set_option_value("fixeol", false, { buf = state.buf })

  M._render()
  M._setup_keymaps()

  vim.schedule(function()
    if state.win and vim.api.nvim_win_is_valid(state.win) then
      vim.api.nvim_set_current_win(state.win)
      vim.cmd("stopinsert")
    end
  end)

  state.active = true
end

--- 关闭悬浮窗
function M.close()
  if not state.active then
    return
  end

  state._closing = true

  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  state.win = nil

  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  state.buf = nil

  for _, id in ipairs(state.autocmd_ids) do
    pcall(vim.api.nvim_del_autocmd, id)
  end
  state.autocmd_ids = {}

  state.active = false
  state.tools = {}
  state.on_select = nil
  state.on_cancel = nil
end

--- 计算窗口高度（nvim_open_win 的 height 参数，不包含边框）
--- 必须精确匹配 _render 实际写入的行数
function M._calculate_content_height()
  local tool = state.tools[1]
  if not tool then
    return HEADER_HEIGHT + SEPARATOR_HEIGHT + FOOTER_HEIGHT + 2
  end

  -- 逐行计数，与 _render 中的 table.insert 顺序保持一致
  local content_lines = 0

  -- 工具名
  content_lines = content_lines + 1
  -- 描述（如果有）
  if tool.description and tool.description ~= "" then
    content_lines = content_lines + 1
  end
  -- 参数（如果有）
  if tool.args and type(tool.args) == "table" then
    content_lines = content_lines + 1  -- "参数:" 标题
    for k, v in pairs(tool.args) do
      if k ~= "_session_id" and k ~= "_tool_call_id" then
        local v_str = type(v) == "string" and v or vim.inspect(v)
        for _ in v_str:gmatch("[^\n]+") do
          content_lines = content_lines + 1
        end
      end
    end
  end
  -- 队列提示（如果有）
  if #state.tools > 1 then
    content_lines = content_lines + 1
  end
  -- 分隔线
  content_lines = content_lines + 1
  -- 4 个操作提示
  content_lines = content_lines + 4

  -- 直接返回内容行数（nvim_open_win 的 height 不包含边框）
  return content_lines
end

--- 渲染内容
function M._render()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end

  local lines = {}
  local total_height = state.total_height or 10
  local win_width = WIDTH
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    win_width = vim.api.nvim_win_get_width(state.win)
  end

  local tool = state.tools[1]

  if tool then
    table.insert(lines, "  工具: " .. (tool.name or "未知"))
    local desc = tool.description or ""
    if desc ~= "" then
      table.insert(lines, "  描述: " .. desc)
    end
    if tool.args and type(tool.args) == "table" then
      table.insert(lines, "  参数:")
      for k, v in pairs(tool.args) do
        if k ~= "_session_id" and k ~= "_tool_call_id" then
          local v_str = type(v) == "string" and v or vim.inspect(v)
          for line in v_str:gmatch("[^\n]+") do
            table.insert(lines, "    " .. k .. ": " .. line)
          end
        end
      end
    end
    if #state.tools > 1 then
      table.insert(lines, string.format("  (队列中还有 %d 个待审批工具)", #state.tools - 1))
    end
  else
    table.insert(lines, "  工具: (无)")
  end

  -- 分隔线
  table.insert(lines, string.rep("─", win_width))

  -- 底部操作提示（从 ui.init 获取 keymaps 配置，无配置时使用默认值）
  local full_config = ui_init.get_full_config() or {}
  local approval_config = ((full_config.keymaps or {}).chat or {}).approval or DEFAULT_APPROVAL_KEYMAPS
  local action_order = { "confirm", "confirm_all", "cancel", "cancel_with_reason" }
  for _, action in ipairs(action_order) do
    local cfg = approval_config[action]
    if cfg and cfg.key and cfg.key ~= "" then
      local label = cfg.desc or action
      local display_key = M._format_key(cfg.key)
      table.insert(lines, string.format(" %s %s", display_key, label))
    end
  end

  -- 用空行填充至窗口大小，确保无多余行可滚动
  local content_lines = total_height
  while #lines < content_lines do
    table.insert(lines, "")
  end

  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  M._apply_highlights()
end

--- 应用高亮
function M._apply_highlights()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end

  vim.api.nvim_buf_clear_namespace(state.buf, state.ns_id, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
  for i, line in ipairs(lines) do
    if line:match("^%s+工具:") then
      vim.api.nvim_buf_set_extmark(state.buf, state.ns_id, i - 1, 0, {
        hl_group = "Title",
        hl_eol = true,
        priority = 100,
      })
      break
    end
  end

  for i, line in ipairs(lines) do
    if line:match("^─+$") then
      vim.api.nvim_buf_set_extmark(state.buf, state.ns_id, i - 1, 0, {
        hl_group = "Comment",
        hl_eol = true,
        priority = 100,
      })
      break
    end
  end
end

--- 将 Neovim 按键表示转换为用户可读的显示符号
--- @param key string Neovim 按键表示，如 "<CR>", "<Esc>", "A"
--- @return string 用户可读的按键符号
function M._format_key(key)
  local key_map = {
    ["<CR>"] = "⏎",
    ["<Esc>"] = "⎋",
    ["<Tab>"] = "⇥",
    ["<S-Tab>"] = "⇤",
    ["<BS>"] = "⌫",
    ["<Space>"] = "␣",
    ["<Up>"] = "↑",
    ["<Down>"] = "↓",
    ["<Left>"] = "←",
    ["<Right>"] = "→",
    ["<C-a>"] = "⌃A",
    ["<C-c>"] = "⌃C",
    ["<C-d>"] = "⌃D",
    ["<C-u>"] = "⌃U",
    ["<C-v>"] = "⌃V",
    ["<C-x>"] = "⌃X",
    ["<C-y>"] = "⌃Y",
    ["<C-z>"] = "⌃Z",
  }
  return key_map[key] or key
end

--- 确认选择（允许一次）
function M._confirm()
  if state._closing then
    return
  end
  local select_callback = state.on_select
  local cancel_callback = state.on_cancel

  local selected = state.tools[1]
  if selected and select_callback then
    local ok, err = pcall(select_callback, selected)
    if not ok then
      vim.schedule(function()
        vim.notify("[NeoAI] 工具审批回调执行失败: " .. tostring(err), vim.log.levels.ERROR)
      end)
    end
    M.close()
  else
    if cancel_callback then
      pcall(cancel_callback)
    end
    M.close()
  end
end

--- 允许所有
function M._confirm_all()
  if state._closing then
    return
  end
  local select_callback = state.on_select
  local cancel_callback = state.on_cancel

  local selected = state.tools[1]
  if selected and select_callback then
    local ok, err = pcall(select_callback, selected, { allow_all = true })
    if not ok then
      vim.schedule(function()
        vim.notify("[NeoAI] 工具审批取消回调执行失败: " .. tostring(err), vim.log.levels.ERROR)
      end)
    end
    M.close()
  else
    if cancel_callback then
      pcall(cancel_callback)
    end
    M.close()
  end
end

--- 取消并说明原因
function M._cancel_with_reason()
  if state._closing then
    return
  end
  vim.ui.input({ prompt = "取消说明: " }, function(reason)
    if not reason or reason == "" then
      reason = "用户未提供说明"
    end
    local callback = state.on_cancel
    -- 先调用回调，再关闭窗口，避免 WinClosed autocmd 抢先执行
    if callback then
      local ok, err = pcall(callback, { reason = reason })
      if not ok then
        vim.schedule(function()
          vim.notify("[NeoAI] 工具审批取消回调执行失败: " .. tostring(err), vim.log.levels.ERROR)
        end)
      end
    end
    M.close()
  end)
end

--- 取消
function M._cancel()
  if state._closing then
    return
  end
  local callback = state.on_cancel
  -- 先调用回调，再关闭窗口，避免 WinClosed autocmd 抢先执行
  if callback then
    local ok, err = pcall(callback, { reason = "用户取消" })
    if not ok then
      vim.schedule(function()
        vim.notify("[NeoAI] 工具审批取消回调执行失败: " .. tostring(err), vim.log.levels.ERROR)
      end)
    end
  end
  M.close()
end

--- 设置按键映射
function M._setup_keymaps()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  local buf = state.buf

  -- 从 ui.init 获取 keymaps 配置（无配置时使用默认值）
  local full_config = ui_init.get_full_config() or {}
  local approval_config = ((full_config.keymaps or {}).chat or {}).approval or DEFAULT_APPROVAL_KEYMAPS

  -- 动作映射表
  local actions = {
    confirm = M._confirm,
    confirm_all = M._confirm_all,
    cancel = M._cancel,
    cancel_with_reason = M._cancel_with_reason,
  }

  -- 为每个动作的每个快捷键注册 Normal 和 Insert 模式映射
  for action, fn in pairs(actions) do
    local cfg = approval_config[action]
    if cfg and cfg.key and cfg.key ~= "" then
      local desc = cfg.desc or action
      vim.keymap.set("n", cfg.key, fn, { buffer = buf, noremap = true, silent = true, desc = desc })
      vim.keymap.set("i", cfg.key, fn, { buffer = buf, noremap = true, silent = true, desc = desc })
    end
  end

  -- 插入模式额外支持 <C-c> 取消（如果 cancel 动作的快捷键中没有 <C-c>）
  local cancel_cfg = approval_config.cancel
  local has_ctrlc = false
  if cancel_cfg and cancel_cfg.key then
    if cancel_cfg.key == "<C-c>" then
      has_ctrlc = true
    end
  end
  if not has_ctrlc then
    vim.keymap.set("i", "<C-c>", M._cancel, { buffer = buf, noremap = true, silent = true, desc = "取消" })
  end
end

--- 检查是否激活
function M.is_active()
  return state.active
end

--- 获取审批窗口 ID
--- @return number|nil 窗口 ID，窗口无效时返回 nil
function M.get_win_id()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    return state.win
  end
  return nil
end

return M
