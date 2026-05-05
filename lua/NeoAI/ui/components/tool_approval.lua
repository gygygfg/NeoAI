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
--   │ <CR> 允许一次                                   │
--   │ A 允许所有                                      │
--   │ <Esc> 取消                                      │
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
local MAX_HEIGHT = 24
local MIN_HEIGHT = 12

-- 布局常量
local HEADER_HEIGHT = 2     -- 标题行 + 空行
local SEPARATOR_HEIGHT = 1  -- 分隔线
local FOOTER_HEIGHT = 5     -- 4个操作各占一行 + 1个空行

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

  -- 计算窗口尺寸
  local content_height = M._calculate_content_height()
  local total_height = math.max(MIN_HEIGHT, math.min(content_height, MAX_HEIGHT))

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

  vim.api.nvim_set_option_value("cursorline", false, { win = state.win })
  vim.api.nvim_set_option_value("wrap", true, { win = state.win })

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

--- 计算内容高度
function M._calculate_content_height()
  local tool = state.tools[1]
  if not tool then
    return HEADER_HEIGHT + SEPARATOR_HEIGHT + FOOTER_HEIGHT
  end

  local info_lines = 2
  if tool.args and type(tool.args) == "table" then
    info_lines = info_lines + 1
    for k, v in pairs(tool.args) do
      if k ~= "_session_id" and k ~= "_tool_call_id" then
        local v_str = type(v) == "string" and v or vim.inspect(v)
        info_lines = info_lines + 1 + math.floor(#v_str / (WIDTH - 6))
      end
    end
  end

  if #state.tools > 1 then
    info_lines = info_lines + 1
  end

  return HEADER_HEIGHT + info_lines + SEPARATOR_HEIGHT + FOOTER_HEIGHT
end

--- 渲染内容
function M._render()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end

  local lines = {}
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

  -- 底部操作提示（从 ui.init 获取 keymaps 配置）
  local full_config = ui_init.get_full_config() or {}
  local approval_config = ((full_config.keymaps or {}).chat or {}).approval or {}
  local action_order = { "confirm", "confirm_all", "cancel", "cancel_with_reason" }
  for _, action in ipairs(action_order) do
    local cfg = approval_config[action]
    if cfg and cfg.key and cfg.key ~= "" then
      local label = cfg.desc or action
      table.insert(lines, string.format(" %s %s", cfg.key, label))
    end
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
    M.close()
    if not ok then
      vim.schedule(function()
        vim.notify("[NeoAI] 工具审批回调执行失败: " .. tostring(err), vim.log.levels.ERROR)
      end)
    end
  else
    M.close()
    if cancel_callback then
      pcall(cancel_callback)
    end
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
    M.close()
    if not ok then
      vim.schedule(function()
        vim.notify("[NeoAI] 工具审批回调执行失败: " .. tostring(err), vim.log.levels.ERROR)
      end)
    end
  else
    M.close()
    if cancel_callback then
      pcall(cancel_callback)
    end
  end
end

--- 取消并说明原因
function M._cancel_with_reason()
  if state._closing then
    return
  end
  vim.ui.input({ prompt = "取消原因: " }, function(reason)
    if not reason or reason == "" then
      reason = "用户未提供原因"
    end
    local callback = state.on_cancel
    M.close()
    if callback then
      local ok, err = pcall(callback, { reason = reason })
      if not ok then
        vim.schedule(function()
          vim.notify("[NeoAI] 工具审批取消回调执行失败: " .. tostring(err), vim.log.levels.ERROR)
        end)
      end
    end
  end)
end

--- 取消
function M._cancel()
  if state._closing then
    return
  end
  local callback = state.on_cancel
  M.close()
  if callback then
    local ok, err = pcall(callback)
    if not ok then
      vim.schedule(function()
        vim.notify("[NeoAI] 工具审批取消回调执行失败: " .. tostring(err), vim.log.levels.ERROR)
      end)
    end
  end
end

--- 设置按键映射
function M._setup_keymaps()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  local buf = state.buf

  -- 从 ui.init 获取 keymaps 配置
  local full_config = ui_init.get_full_config() or {}
  local approval_config = ((full_config.keymaps or {}).chat or {}).approval or {}

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
