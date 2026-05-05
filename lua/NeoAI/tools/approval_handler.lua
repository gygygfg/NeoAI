--- NeoAI 工具审批处理器
--- 职责：管理工具调用的审批队列、显示审批对话框、处理审批结果
--- 合并了 ui/components/tool_approval.lua 的 UI 渲染逻辑
---
--- 审批流程（三个条件平级，tool_validator.check_approval 中实现）：
---   1. 允许所有：用户已选择"允许所有"，覆盖一切检查
---   2. 路径安全 AND 参数安全：路径和参数都在安全范围内，无需弹窗
---   3. 路径或参数不安全：需要用户审批

local logger = require("NeoAI.utils.logger")
local event_constants = require("NeoAI.core.events")
local tool_registry = require("NeoAI.tools.tool_registry")
local ui_init = require("NeoAI.ui.init")

local M = {}

-- ========== 状态 ==========

local state = {
  approval_queue = {},
  approval_showing = false,
  -- 审批暂停机制
  approval_paused = false,
  pause_start_time = nil,
  total_paused_duration = 0,
  pause_callbacks = {},
  -- "允许所有"工具集合
}

-- ========== UI 状态（从 tool_approval.lua 合并） ==========

local ui_state = {
  initialized = false,
  active = false,
  buf = nil,
  win = nil,
  tools = {},
  on_select = nil,
  on_cancel = nil,
  ns_id = nil,
  autocmd_ids = {},
  _closing = false,
}

-- 窗口尺寸
local WIDTH = 66

-- 布局常量（均不含边框，边框由 nvim_open_win 的 border 选项额外占用 2 行）
local HEADER_HEIGHT = 1
local SEPARATOR_HEIGHT = 1
local FOOTER_HEIGHT = 4

-- 默认审批快捷键配置
local DEFAULT_APPROVAL_KEYMAPS = {
  confirm = { key = "<CR>", desc = "允许一次" },
  confirm_all = { key = "A", desc = "允许所有" },
  cancel = { key = "<Esc>", desc = "取消" },
  cancel_with_reason = { key = "C", desc = "取消并说明" },
}

-- ========== 审批队列管理 ==========

--- 将工具加入审批队列
--- @param item table { tool_name, resolved_args, raw_args, on_success, on_error, on_progress, start_time, pack_name, session_id }
function M.enqueue(item)
  table.insert(state.approval_queue, item)
end

--- 处理审批队列
--- 从队列头部取出一个待审批的工具，显示审批窗口
function M.process_queue()
  if state.approval_showing then
    return
  end
  if #state.approval_queue == 0 then
    return
  end

  state.approval_showing = true
  local item = table.remove(state.approval_queue, 1)

  if not item or not item.tool_name then
    state.approval_showing = false
    logger.warn("[approval_handler] 审批队列项无效，跳过")
    vim.schedule(function()
      M.process_queue()
    end)
    return
  end

  M._show_approval_dialog(item)
end

--- 清空审批队列
function M.clear_queue()
  state.approval_queue = {}
  if state.approval_paused then
    M.resume_timer()
  end
  if state.approval_showing then
    M._close_ui()
    state.approval_showing = false
  end
end

-- ========== "允许所有"管理（委托给 approval_state 共享变量） ==========

local approval_state = require("NeoAI.tools.approval_state")

--- 将工具标记为"允许所有"
--- @param tool_name string 工具名称
function M.set_allow_all(tool_name)
  local config = approval_state.get_tool_config(tool_name) or {}
  config.allow_all = true
  approval_state.set_tool_config(tool_name, config)
end

--- 检查工具是否已被用户"允许所有"
function M.is_allow_all(tool_name)
  local config = approval_state.get_tool_config(tool_name)
  return config and config.allow_all == true
end

--- 清空"允许所有"集合
function M.clear_allow_all()
  for _, config in pairs(approval_state.get_all_tool_configs()) do
    config.allow_all = nil
  end
end

-- ========== 暂停/恢复机制 ==========

--- 注册暂停/恢复回调
function M.register_pause_callback(callback)
  table.insert(state.pause_callbacks, callback)
  return function()
    for i, cb in ipairs(state.pause_callbacks) do
      if cb == callback then
        table.remove(state.pause_callbacks, i)
        break
      end
    end
  end
end

--- 清理所有暂停回调
function M.clear_pause_callbacks()
  state.pause_callbacks = {}
end

--- 暂停计时（审批窗口打开时调用）
function M.pause_timer()
  if state.approval_paused then
    return
  end
  state.approval_paused = true
  state.pause_start_time = os.time()
  logger.debug("[approval_handler] ⏸️ 审批暂停计时开始")

  for _, cb in ipairs(state.pause_callbacks) do
    local ok, err = pcall(cb, true)
    if not ok then
      logger.warn("[approval_handler] pause 回调执行失败: %s", tostring(err))
    end
  end
end

--- 恢复计时（审批窗口关闭时调用）
function M.resume_timer()
  if not state.approval_paused then
    return
  end

  local pause_duration = 0
  if state.pause_start_time then
    pause_duration = os.time() - state.pause_start_time
    state.total_paused_duration = state.total_paused_duration + pause_duration
  end

  state.approval_paused = false
  state.pause_start_time = nil
  logger.debug(
    "[approval_handler] ▶️ 审批恢复计时，本次暂停 %d 秒，累计暂停 %d 秒",
    pause_duration,
    state.total_paused_duration
  )

  for _, cb in ipairs(state.pause_callbacks) do
    local ok, err = pcall(cb, false)
    if not ok then
      logger.warn("[approval_handler] resume 回调执行失败: %s", tostring(err))
    end
  end
end

--- 获取累计暂停时长
function M.get_total_paused_duration()
  local total = state.total_paused_duration
  if state.approval_paused and state.pause_start_time then
    total = total + (os.time() - state.pause_start_time)
  end
  return total
end

--- 检查是否正在暂停
function M.is_paused()
  return state.approval_paused
end

--- 重置暂停状态
function M.reset_pause_state()
  state.approval_paused = false
  state.pause_start_time = nil
  state.total_paused_duration = 0
  state.pause_callbacks = {}
end

--- 获取队列长度
function M.queue_length()
  return #state.approval_queue
end

--- 检查是否正在显示审批
function M.is_showing()
  return state.approval_showing
end

-- ========== UI 初始化（从 tool_approval.lua 合并） ==========

--- 初始化 UI
function M._init_ui()
  if ui_state.initialized then
    return
  end
  ui_state.ns_id = vim.api.nvim_create_namespace("NeoAIToolApproval")
  ui_state.initialized = true
end

--- 打开审批 UI 悬浮窗
--- @param tools table 工具列表
--- @param opts table 选项
function M._open_ui(tools, opts)
  if not ui_state.initialized then
    M._init_ui()
  end

  opts = opts or {}

  if ui_state.active then
    M._close_ui()
  end

  ui_state._closing = false
  ui_state.tools = tools or {}
  ui_state.on_select = opts.on_select
  ui_state.on_cancel = opts.on_cancel

  -- 创建 buffer
  ui_state.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("filetype", "neoai_tool_approval", { buf = ui_state.buf })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = ui_state.buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = ui_state.buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = ui_state.buf })
  vim.api.nvim_set_option_value("modified", false, { buf = ui_state.buf })
  vim.api.nvim_set_option_value("modifiable", true, { buf = ui_state.buf })

  -- 计算窗口尺寸
  local total_height = M._calc_ui_height()
  local screen_width = vim.o.columns
  local screen_height = vim.o.lines
  local win_width = math.min(WIDTH, screen_width - 4)
  local win_col = math.floor((screen_width - win_width) / 2)
  local win_row = math.floor(screen_height * 0.5)
  if win_row + total_height > screen_height - 2 then
    win_row = math.max(1, screen_height - total_height - 2)
  end

  ui_state.active = true

  ui_state.win = vim.api.nvim_open_win(ui_state.buf, false, {
    relative = "editor",
    width = win_width,
    height = total_height,
    row = win_row,
    col = win_col,
    style = "minimal",
    border = "rounded",
    title = " Tool Approval ",
    title_pos = "center",
    noautocmd = true,
  })

  vim.api.nvim_set_option_value("cursorline", false, { win = ui_state.win })
  vim.api.nvim_set_option_value("wrap", false, { win = ui_state.win })
  vim.api.nvim_set_option_value("number", false, { win = ui_state.win })
  vim.api.nvim_set_option_value("relativenumber", false, { win = ui_state.win })
  vim.api.nvim_set_option_value("signcolumn", "no", { win = ui_state.win })
  vim.api.nvim_set_option_value("foldcolumn", "0", { win = ui_state.win })
  vim.api.nvim_set_option_value("scrolloff", 0, { win = ui_state.win })
  vim.api.nvim_set_option_value("sidescrolloff", 0, { win = ui_state.win })
  vim.api.nvim_set_option_value("statuscolumn", "", { win = ui_state.win })
  vim.api.nvim_set_option_value("endofline", false, { buf = ui_state.buf })
  vim.api.nvim_set_option_value("fixeol", false, { buf = ui_state.buf })

  M._render_ui()
  M._setup_ui_keymaps()

  vim.schedule(function()
    if ui_state.win and vim.api.nvim_win_is_valid(ui_state.win) then
      vim.api.nvim_set_current_win(ui_state.win)
      vim.cmd("stopinsert")
    end
  end)
end

--- 关闭审批 UI 悬浮窗
function M._close_ui()
  if not ui_state.active then
    return
  end

  ui_state._closing = true

  if ui_state.win and vim.api.nvim_win_is_valid(ui_state.win) then
    pcall(vim.api.nvim_win_close, ui_state.win, true)
  end
  ui_state.win = nil

  if ui_state.buf and vim.api.nvim_buf_is_valid(ui_state.buf) then
    pcall(vim.api.nvim_buf_delete, ui_state.buf, { force = true })
  end
  ui_state.buf = nil

  for _, id in ipairs(ui_state.autocmd_ids) do
    pcall(vim.api.nvim_del_autocmd, id)
  end
  ui_state.autocmd_ids = {}

  ui_state.active = false
  ui_state.tools = {}
  ui_state.on_select = nil
  ui_state.on_cancel = nil
end

--- 计算 UI 窗口高度
function M._calc_ui_height()
  local tool = ui_state.tools[1]
  if not tool then
    return HEADER_HEIGHT + SEPARATOR_HEIGHT + FOOTER_HEIGHT + 2
  end

  local content_lines = 0
  content_lines = content_lines + 1
  if tool.description and tool.description ~= "" then
    content_lines = content_lines + 1
  end
  if tool.args and type(tool.args) == "table" then
    content_lines = content_lines + 1
    for k, v in pairs(tool.args) do
      if k ~= "_session_id" and k ~= "_tool_call_id" then
        local v_str = type(v) == "string" and v or vim.inspect(v)
        for _ in v_str:gmatch("[^\n]+") do
          content_lines = content_lines + 1
        end
      end
    end
  end
  if #ui_state.tools > 1 then
    content_lines = content_lines + 1
  end
  content_lines = content_lines + 1
  content_lines = content_lines + 4
  return content_lines
end

--- 渲染 UI 内容
function M._render_ui()
  if not ui_state.buf or not vim.api.nvim_buf_is_valid(ui_state.buf) then
    return
  end

  local lines = {}
  local win_width = WIDTH
  if ui_state.win and vim.api.nvim_win_is_valid(ui_state.win) then
    win_width = vim.api.nvim_win_get_width(ui_state.win)
  end

  local tool = ui_state.tools[1]

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
    if #ui_state.tools > 1 then
      table.insert(lines, string.format("  (队列中还有 %d 个待审批工具)", #ui_state.tools - 1))
    end
  else
    table.insert(lines, "  工具: (无)")
  end

  table.insert(lines, string.rep("─", win_width))

  -- 底部操作提示
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

  local total_height = M._calc_ui_height()
  while #lines < total_height do
    table.insert(lines, "")
  end

  vim.api.nvim_buf_set_lines(ui_state.buf, 0, -1, false, lines)
  M._apply_ui_highlights()
end

--- 应用高亮
function M._apply_ui_highlights()
  if not ui_state.buf or not vim.api.nvim_buf_is_valid(ui_state.buf) then
    return
  end

  vim.api.nvim_buf_clear_namespace(ui_state.buf, ui_state.ns_id, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(ui_state.buf, 0, -1, false)
  for i, line in ipairs(lines) do
    if line:match("^%s+工具:") then
      vim.api.nvim_buf_set_extmark(ui_state.buf, ui_state.ns_id, i - 1, 0, {
        hl_group = "Title",
        hl_eol = true,
        priority = 100,
      })
      break
    end
  end

  for i, line in ipairs(lines) do
    if line:match("^─+$") then
      vim.api.nvim_buf_set_extmark(ui_state.buf, ui_state.ns_id, i - 1, 0, {
        hl_group = "Comment",
        hl_eol = true,
        priority = 100,
      })
      break
    end
  end
end

--- 格式化按键符号
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

-- ========== UI 按键回调 ==========

function M._ui_confirm()
  if ui_state._closing then
    return
  end
  local select_callback = ui_state.on_select
  local cancel_callback = ui_state.on_cancel

  local selected = ui_state.tools[1]
  if selected and select_callback then
    local ok, err = pcall(select_callback, selected)
    if not ok then
      vim.schedule(function()
        vim.notify("[NeoAI] 工具审批回调执行失败: " .. tostring(err), vim.log.levels.ERROR)
      end)
    end
    M._close_ui()
  else
    if cancel_callback then
      pcall(cancel_callback)
    end
    M._close_ui()
  end
end

function M._ui_confirm_all()
  if ui_state._closing then
    return
  end
  local select_callback = ui_state.on_select
  local cancel_callback = ui_state.on_cancel

  local selected = ui_state.tools[1]
  if selected and select_callback then
    local ok, err = pcall(select_callback, selected, { allow_all = true })
    if not ok then
      vim.schedule(function()
        vim.notify("[NeoAI] 工具审批回调执行失败: " .. tostring(err), vim.log.levels.ERROR)
      end)
    end
    M._close_ui()
  else
    if cancel_callback then
      pcall(cancel_callback)
    end
    M._close_ui()
  end
end

function M._ui_cancel_with_reason()
  if ui_state._closing then
    return
  end
  vim.ui.input({ prompt = "取消说明: " }, function(reason)
    if not reason or reason == "" then
      reason = "用户未提供说明"
    end
    local callback = ui_state.on_cancel
    if callback then
      local ok, err = pcall(callback, { reason = reason })
      if not ok then
        vim.schedule(function()
          vim.notify("[NeoAI] 工具审批取消回调执行失败: " .. tostring(err), vim.log.levels.ERROR)
        end)
      end
    end
    M._close_ui()
  end)
end

function M._ui_cancel()
  if ui_state._closing then
    return
  end
  local callback = ui_state.on_cancel
  if callback then
    local ok, err = pcall(callback, { reason = "用户取消" })
    if not ok then
      vim.schedule(function()
        vim.notify("[NeoAI] 工具审批取消回调执行失败: " .. tostring(err), vim.log.levels.ERROR)
      end)
    end
  end
  M._close_ui()
end

--- 设置 UI 按键映射
function M._setup_ui_keymaps()
  if not ui_state.buf or not vim.api.nvim_buf_is_valid(ui_state.buf) then
    return
  end
  local buf = ui_state.buf

  local full_config = ui_init.get_full_config() or {}
  local approval_config = ((full_config.keymaps or {}).chat or {}).approval or DEFAULT_APPROVAL_KEYMAPS

  local actions = {
    confirm = M._ui_confirm,
    confirm_all = M._ui_confirm_all,
    cancel = M._ui_cancel,
    cancel_with_reason = M._ui_cancel_with_reason,
  }

  for action, fn in pairs(actions) do
    local cfg = approval_config[action]
    if cfg and cfg.key and cfg.key ~= "" then
      local desc = cfg.desc or action
      vim.keymap.set("n", cfg.key, fn, { buffer = buf, noremap = true, silent = true, desc = desc })
      vim.keymap.set("i", cfg.key, fn, { buffer = buf, noremap = true, silent = true, desc = desc })
    end
  end

  local cancel_cfg = approval_config.cancel
  local has_ctrlc = false
  if cancel_cfg and cancel_cfg.key then
    if cancel_cfg.key == "<C-c>" then
      has_ctrlc = true
    end
  end
  if not has_ctrlc then
    vim.keymap.set("i", "<C-c>", M._ui_cancel, { buffer = buf, noremap = true, silent = true, desc = "取消" })
  end

  -- 同步 chat 窗口快捷键
  local ok, chat_window = pcall(require, "NeoAI.ui.window.chat_window")
  if ok and chat_window.sync_keymaps_to_buf then
    chat_window.sync_keymaps_to_buf(buf, { "cancel", "quit" })
  end
end

-- ========== 审批对话框（使用合并后的 UI） ==========

--- 显示审批对话框
--- @param item table 审批队列项
function M._show_approval_dialog(item)
  M._init_ui()

  local tool_info = tool_registry.get(item.tool_name)
  local tools_for_approval = {}
  if tool_info then
    table.insert(tools_for_approval, {
      name = tool_info.name,
      description = tool_info.description or "",
      category = tool_info.category or "uncategorized",
      raw = tool_info,
      args = item.resolved_args,
    })
  else
    table.insert(tools_for_approval, {
      name = item.tool_name,
      description = "",
      category = "unknown",
      raw = nil,
      args = item.resolved_args,
    })
  end

  if #state.approval_queue > 0 then
    local queue_count = #state.approval_queue
    if tools_for_approval[1] and tools_for_approval[1].description then
      tools_for_approval[1].description = tools_for_approval[1].description
        .. string.format(" (队列中还有 %d 个待审批工具)", queue_count)
    end
  end

  local approval_closed = false
  local win_closed_autocmd_id = nil

  -- ===== 暂停计时：审批窗口即将打开 =====
  M.pause_timer()

  local open_ok, open_err = pcall(M._open_ui, tools_for_approval, {
    on_select = function(selected, extra_opts)
      extra_opts = extra_opts or {}
      if approval_closed then
        return
      end
      approval_closed = true
      state.approval_showing = false
      if win_closed_autocmd_id then
        pcall(vim.api.nvim_del_autocmd, win_closed_autocmd_id)
        win_closed_autocmd_id = nil
      end

      -- ===== 恢复计时 =====
      M.resume_timer()

      if extra_opts and extra_opts.allow_all then
        approval_state.set_allow_all(item.tool_name)
        logger.debug(
          "[approval_handler] 允许所有：已将工具 '%s' 加入 approval_state 的 allow_all_tools 集合",
          item.tool_name
        )
      end

      -- 清理暂停回调（审批完成后不再需要暂停/恢复超时）
      M.clear_pause_callbacks()

      logger.debug("[approval_handler] 用户已审批工具: %s", selected.name)
      pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = event_constants.TOOL_APPROVED,
        data = {
          tool_name = selected.name,
          tool = selected.raw,
          args = item.raw_args,
          session_id = item.session_id,
        },
      })

      local tool_executor = require("NeoAI.tools.tool_executor")
      local wrapped_on_success = function(result)
        if item.on_success then
          local ok_call, err_call = pcall(item.on_success, result)
          if not ok_call then
            logger.warn("[approval_handler] on_success 回调执行失败: %s", tostring(err_call))
          end
        end
        M.process_queue()
      end
      local wrapped_on_error = function(err)
        if item.on_error then
          local ok_call, err_call = pcall(item.on_error, err)
          if not ok_call then
            logger.warn("[approval_handler] on_error 回调执行失败: %s", tostring(err_call))
          end
        end
        M.process_queue()
      end

      tool_executor._continue_execution(
        item.tool_name,
        item.resolved_args,
        item.raw_args,
        wrapped_on_success,
        wrapped_on_error,
        item.on_progress,
        item.start_time,
        item.pack_name
      )
    end,
    on_cancel = function(extra_opts)
      extra_opts = extra_opts or {}
      if approval_closed then
        return
      end
      approval_closed = true
      state.approval_showing = false
      if win_closed_autocmd_id then
        pcall(vim.api.nvim_del_autocmd, win_closed_autocmd_id)
        win_closed_autocmd_id = nil
      end

      -- ===== 恢复计时 =====
      M.resume_timer()

      -- 清理暂停回调（审批完成后不再需要暂停/恢复超时）
      M.clear_pause_callbacks()

      local cancel_reason = extra_opts.reason or "用户未提供说明"
      logger.debug("[approval_handler] 用户拒绝工具: %s，说明: %s", item.tool_name, cancel_reason)
      pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = event_constants.TOOL_APPROVAL_CANCELLED,
        data = {
          tool_name = item.tool_name,
          args = item.raw_args,
          session_id = item.session_id,
          reason = cancel_reason,
        },
      })

      local duration = os.time() - item.start_time
      local err_msg = "用户取消了工具执行: " .. item.tool_name .. "，说明: " .. cancel_reason
      local ok_fire, _ = pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = event_constants.TOOL_EXECUTION_ERROR,
        data = {
          tool_name = item.tool_name,
          pack_name = item.pack_name,
          args = item.raw_args,
          error_msg = err_msg,
          duration = duration,
          session_id = item.session_id,
        },
      })
      if not ok_fire then
        vim.schedule(function()
          pcall(vim.api.nvim_exec_autocmds, "User", {
            pattern = event_constants.TOOL_EXECUTION_ERROR,
            data = {
              tool_name = item.tool_name,
              pack_name = item.pack_name,
              args = item.raw_args,
              error_msg = err_msg,
              duration = duration,
              session_id = item.session_id,
            },
          })
        end)
      end
      if item.on_error then
        local ok_on_err, _ = pcall(item.on_error, err_msg)
        if not ok_on_err then
          vim.schedule(function()
            pcall(item.on_error, err_msg)
          end)
        end
      end
      M.process_queue()
    end,
  })

  if not open_ok then
    state.approval_showing = false
    logger.warn("[approval_handler] 打开审批窗口失败: %s", tostring(open_err))
    table.insert(state.approval_queue, 1, item)
    vim.schedule(function()
      M.process_queue()
    end)
    return
  end

  local approval_win_id = M.get_ui_win_id()
  if approval_win_id then
    win_closed_autocmd_id = vim.api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(approval_win_id),
      once = true,
      callback = function()
      if approval_closed then
        return
      end
      approval_closed = true
      state.approval_showing = false
      M.resume_timer()
      M.clear_pause_callbacks()
      logger.debug("[approval_handler] 审批窗口被外部关闭: %s", item.tool_name)
        local duration = os.time() - item.start_time
        local err_msg = "审批窗口被关闭，工具执行已取消: " .. item.tool_name
        pcall(vim.api.nvim_exec_autocmds, "User", {
          pattern = event_constants.TOOL_EXECUTION_ERROR,
          data = {
            tool_name = item.tool_name,
            pack_name = item.pack_name,
            args = item.raw_args,
            error_msg = err_msg,
            duration = duration,
            session_id = item.session_id,
          },
        })
        if item.on_error then
          local ok_on_err, _ = pcall(item.on_error, err_msg)
          if not ok_on_err then
            vim.schedule(function()
              pcall(item.on_error, err_msg)
            end)
          end
        end
        M.process_queue()
      end,
    })
  end
end

--- 获取审批 UI 窗口 ID
function M.get_ui_win_id()
  if ui_state.win and vim.api.nvim_win_is_valid(ui_state.win) then
    return ui_state.win
  end
  return nil
end

--- 检查审批 UI 是否激活
function M.is_ui_active()
  return ui_state.active
end

return M
