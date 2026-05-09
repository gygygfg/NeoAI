local M = {}

local logger = require("NeoAI.utils.logger")
local Events = require("NeoAI.core.events")
local state_manager = require("NeoAI.core.config.state")

local windows = {}
local window_counter = 0
local float_windows = {}

-- 子窗口关联表：chat/tree 窗口 ID -> { child_window_id1, child_window_id2, ... }
-- 当父窗口关闭时，自动关闭所有子窗口
local parent_child_map = {} -- { [parent_id] = { [child_id] = true } }
local child_parent_map = {} -- { [child_id] = parent_id }

-- 子窗口隐藏状态（隐藏时保存原始配置，用于恢复）
local child_window_hidden_states = {} -- { [window_id] = { saved_config = {...} } }

-- 延迟隐藏标志：当 BufLeave 调度 defer_fn 后，如果在执行前触发了 BufEnter，
-- 设置此标志阻止 defer_fn 中的 hide_float_window 执行
local _pending_hide_flags = {} -- { [buf] = true }

local state = {
  initialized = false,
  default_options = {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = "NeoAI",
    title_pos = "center",
    zindex = 50,
  },
  current_mode = "float",
  available_modes = { "float", "tab", "split" },
  -- 保存每个 chat 窗口打开前当前窗口的 wrap 状态
  saved_wrap_states = {},
}

-- ========== LSP 阻止 ==========

local _blocked_buffers = {}

function M.block_lsp_for_buffer(buf, label)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  -- 避免重复注册
  if _blocked_buffers[buf] then
    return
  end
  _blocked_buffers[buf] = true

  pcall(vim.api.nvim_buf_set_var, buf, "neoai_no_lsp", true)
  pcall(vim.diagnostic.disable, buf)
  -- 使用 pcall 保护，避免在 Neovim 退出过程中调用 LSP API 出错
  pcall(function()
    local clients = vim.lsp.get_clients({ bufnr = buf })
    for _, client in ipairs(clients) do
      pcall(vim.lsp.buf_detach_client, buf, client.id)
    end
  end)
  local augroup_name = "NeoAIBlockLSP_buf_" .. tostring(buf)
  pcall(vim.api.nvim_del_augroup_by_name, augroup_name)
  local group = vim.api.nvim_create_augroup(augroup_name, { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "FileType", "InsertEnter", "TextChanged" }, {
    group = group,
    buffer = buf,
    callback = function()
      -- 检查 Neovim 是否正在退出，避免在退出过程中调度 defer_fn 导致死循环
      local ok, tp = pcall(vim.api.nvim_get_current_tabpage)
      if not ok or not tp then
        return
      end

      pcall(vim.diagnostic.disable, buf)
      pcall(function()
        for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
          pcall(vim.lsp.buf_detach_client, buf, client.id)
        end
      end)
    end,
    desc = "阻止 LSP 附加" .. (label and ("到 " .. label) or ""),
  })
end

-- ========== 初始化 ==========

function M.initialize(config)
  if state.initialized then
    return
  end
  state.current_mode = (config and config.window_mode) or "float"
  state.initialized = true

  vim.api.nvim_create_autocmd("LspAttach", {
    group = vim.api.nvim_create_augroup("NeoAIBlockLSP", { clear = true }),
    callback = function(args)
      local buf = args.buf
      if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      local ok, neoai_no_lsp = pcall(vim.api.nvim_buf_get_var, buf, "neoai_no_lsp")
      if ok and neoai_no_lsp then
        local client_id = args.data and args.data.client_id
        if client_id then
          pcall(vim.lsp.buf_detach_client, buf, client_id)
        end
        pcall(vim.diagnostic.disable, buf)
      end
    end,
    desc = "阻止 LSP 附加到 NeoAI 的 buffer",
  })
end

-- ========== 窗口创建 ==========

local function setup_buf(buf, is_temp_float)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", is_temp_float and "delete" or "hide", { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_set_option_value("readonly", true, { buf = buf })
  vim.api.nvim_set_option_value("modified", false, { buf = buf })
  if not is_temp_float then
    vim.api.nvim_set_option_value("buflisted", true, { buf = buf })
  end
end

local function create_float_window(options)
  local opts = vim.tbl_extend("force", {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = "NeoAI",
    title_pos = "center",
    zindex = 50,
  }, options or {})

  opts.width = opts.width or math.floor(vim.o.columns * 0.8)
  opts.height = opts.height or math.floor(vim.o.lines * 0.8)
  opts.row = opts.row or math.floor((vim.o.lines - opts.height) / 2)
  opts.col = opts.col or math.floor((vim.o.columns - opts.width) / 2)

  local window_type = options and options._window_type or ""
  local is_temp = (window_type == "tool_display" or window_type == "reasoning" or window_type == "pty_terminal")
  local buf = vim.api.nvim_create_buf(false, is_temp)
  setup_buf(buf, is_temp)

  local valid_params = {
    "relative",
    "width",
    "height",
    "row",
    "col",
    "anchor",
    "win",
    "bufpos",
    "external",
    "focusable",
    "zindex",
    "style",
    "border",
    "title",
    "title_pos",
    "noautocmd",
  }
  local filtered = {}
  for _, p in ipairs(valid_params) do
    if opts[p] ~= nil then
      filtered[p] = opts[p]
    end
  end

  -- 所有非 chat 类型的悬浮窗打开时不获取焦点、不移动光标
  -- 只有虚拟输入框（由 virtual_input 组件管理）才控制光标行为
  local enter = false
  -- 确保 noautocmd 为 true，避免触发 BufEnter/WinEnter 等事件
  filtered.noautocmd = true
  -- 设置 focusable=false 防止用户通过键盘导航进入
  -- 注意：tool_display 和 reasoning 窗口需要可点击，所以保留 focusable
  if window_type == "pty_terminal" then
    filtered.focusable = true
  end

  local win = vim.api.nvim_open_win(buf, enter, filtered)
  vim.api.nvim_set_option_value("winhl", "Normal:Normal,FloatBorder:FloatBorder", { win = win })
  vim.api.nvim_set_option_value("winblend", opts.winblend or 0, { win = win })

  if not is_temp then
    vim.api.nvim_buf_set_name(buf, "neoai://float/temp")
  end

  return { buf = buf, win = win, id = "float_" .. tostring(buf) .. "_" .. tostring(win) }
end

local function create_tab_window(options)
  vim.cmd("tabnew")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  setup_buf(buf, false)
  vim.api.nvim_buf_set_name(buf, "neoai://tab/temp")
  if options and options.title then
    vim.api.nvim_set_option_value("titlestring", options.title, { scope = "global" })
  end
  return { buf = buf, win = win, id = "tab_" .. tostring(buf) .. "_" .. tostring(win) }
end

local function create_split_window(options)
  local buf = vim.api.nvim_create_buf(false, true)
  setup_buf(buf, false)

  local direction = (options and options.split_direction) or "right"
  local size = options and options.split_size
  if size and size > 0 and size < 1 then
    size = math.floor(vim.o.columns * size)
  end

  local cmd = "vsplit"
  if size then
    cmd = cmd .. " " .. tostring(size)
  end
  vim.cmd(cmd)

  local win = vim.api.nvim_get_current_win()
  if direction == "left" then
    vim.api.nvim_set_current_win(win)
    vim.cmd("wincmd H")
    win = vim.api.nvim_get_current_win()
  end

  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_buf_set_name(buf, "neoai://split/temp")
  return { buf = buf, win = win, id = "split_" .. tostring(buf) .. "_" .. tostring(win) }
end

local function create_window_by_mode(mode, options)
  local creators = {
    float = create_float_window,
    tab = create_tab_window,
    split = create_split_window,
  }
  local fn = creators[mode]
  if not fn then
    vim.notify("[NeoAI] 无效的窗口模式: " .. tostring(mode), vim.log.levels.ERROR)
    return nil
  end
  return fn(options)
end

local function close_window_by_mode(window_info)
  if not window_info then
    return
  end
  local id = window_info.id or ""

  if id:match("^float_") or id:match("^split_") then
    if vim.api.nvim_win_is_valid(window_info.win) then
      vim.api.nvim_win_close(window_info.win, true)
    end
    if vim.api.nvim_buf_is_valid(window_info.buf) then
      vim.api.nvim_buf_delete(window_info.buf, { force = true })
    end
  elseif id:match("^tab_") then
    if vim.api.nvim_win_is_valid(window_info.win) then
      -- 使用 pcall 保护 tabclose，避免在 Neovim 退出过程中执行失败
      pcall(function()
        local tabpage = vim.api.nvim_win_get_tabpage(window_info.win)
        local tabpages = vim.api.nvim_list_tabpages()
        if #tabpages > 1 then
          local tabpage_number = vim.api.nvim_tabpage_get_number(tabpage)
          if tabpage_number then
            vim.cmd("tabclose " .. tabpage_number)
          else
            for _, tp in ipairs(tabpages) do
              if tp ~= tabpage then
                vim.api.nvim_set_current_tabpage(tp)
                break
              end
            end
            vim.cmd("tabclose")
          end
        else
          -- 最后一个标签页，只删除 buffer 不关闭标签页
          -- 避免在 Neovim 退出时触发额外的标签页切换事件
        end
      end)
    end
    if vim.api.nvim_buf_is_valid(window_info.buf) then
      vim.api.nvim_buf_delete(window_info.buf, { force = true })
    end
  end
end

-- ========== 公共 API ==========

function M.create_window(window_type, options)
  if not state.initialized then
    error("Window manager not initialized")
  end

  window_counter = window_counter + 1
  local window_id = "win_" .. tostring(os.time()) .. "_" .. window_counter
  local core = require("NeoAI.core")
  local ok, full_config = pcall(core.get_config)
  full_config = ok and full_config or {}
  local merged = vim.tbl_extend("force", full_config, options or {})
  merged.title = merged.title or ("NeoAI - " .. window_type)

  local mode = merged.window_mode or state.current_mode
  if mode == "split" then
    local split_config = merged.split or {}
    merged.split_direction = merged.split_direction or split_config[window_type .. "_direction"] or "right"
    merged.split_size = merged.split_size or split_config.size
  end

  merged._window_type = window_type
  local window_info = create_window_by_mode(mode, merged)
  if not window_info then
    vim.notify("[NeoAI] 创建窗口失败", vim.log.levels.ERROR)
    return nil
  end

  -- 为 chat/tree 窗口创建协程上下文，协程内共享变量（如 session_id、window_id 等）
  -- 每次打开窗口时重新创建，确保上下文隔离
  local window_context = nil
  if vim.tbl_contains({ "chat", "tree" }, window_type) then
    window_context = state_manager.create_context({
      window_id = window_id,
      window_type = window_type,
      created_at = os.time(),
    })
  end

  windows[window_id] = {
    id = window_id,
    type = window_type,
    buf = window_info.buf,
    win = window_info.win,
    options = merged,
    created_at = os.time(),
    window_info = window_info,
    context = window_context,
  }

  -- 阻止 LSP
  if vim.tbl_contains({ "chat", "tree", "reasoning", "tool_display" }, window_type) then
    pcall(vim.api.nvim_buf_set_var, window_info.buf, "neoai_no_lsp", true)
  end

  local ft = window_type == "chat" and "neoai" or "neoai_" .. window_type
  vim.api.nvim_set_option_value("filetype", ft, { buf = window_info.buf })
  vim.api.nvim_set_option_value("modifiable", true, { buf = window_info.buf })
  vim.api.nvim_set_option_value("readonly", false, { buf = window_info.buf })

  if vim.tbl_contains({ "chat", "tree", "reasoning", "tool_display" }, window_type) then
    M.block_lsp_for_buffer(window_info.buf, window_type .. " 界面")
  end

  -- 为所有类型的窗口设置唯一 buf 名称，确保 buf 引用稳定
  -- 避免在 vim.schedule 延迟执行时 buf 被回收或复用
  vim.api.nvim_buf_set_name(window_info.buf, "neoai://" .. window_type .. "/" .. window_id)

  -- 如果是子窗口类型（tool_display、reasoning、pty_terminal），自动关联到 chat/tree 父窗口
  if vim.tbl_contains({ "tool_display", "reasoning", "pty_terminal" }, window_type) then
    local parent_id = M._find_parent_window_id()
    if parent_id then
      if not parent_child_map[parent_id] then
        parent_child_map[parent_id] = {}
      end
      parent_child_map[parent_id][window_id] = true
      child_parent_map[window_id] = parent_id
    end
  end

  -- 打开 chat 窗口时保存当前窗口的 wrap 状态并启用自动换行
  if window_type == "chat" then
    local cur_win = vim.api.nvim_get_current_win()
    if cur_win and vim.api.nvim_win_is_valid(cur_win) then
      local saved = vim.api.nvim_get_option_value("wrap", { win = cur_win })
      state.saved_wrap_states[window_id] = saved
      -- 为 chat 窗口启用自动换行
      vim.api.nvim_set_option_value("wrap", true, { win = window_info.win })
      vim.api.nvim_set_option_value("linebreak", true, { win = window_info.win })
    end
  end

  -- 注册 BufLeave/BufEnter 管理悬浮窗口
  if vim.tbl_contains({ "chat", "tree" }, window_type) then
    local buf = window_info.buf
    local augroup = "NeoAIFloatWindow_" .. window_id
    pcall(vim.api.nvim_del_augroup_by_name, augroup)
    local group = vim.api.nvim_create_augroup(augroup, { clear = true })

    vim.api.nvim_create_autocmd("BufLeave", {
      group = group,
      buffer = buf,
      callback = function()
        -- 注意：不在此处修改任何窗口的 wrap 选项。
        -- 离开 chat 窗口时修改 chat 窗口的 wrap 会导致 chat 窗口自动换行失效。
        -- chat 窗口的 wrap 由 BufEnter 回调统一保证。

        -- 设置延迟隐藏标志
        _pending_hide_flags[buf] = true

        vim.defer_fn(function()
          -- 检查 Neovim 是否正在退出，避免在退出过程中操作窗口导致死循环
          local ok, tp = pcall(vim.api.nvim_get_current_tabpage)
          if not ok or not tp then
            _pending_hide_flags[buf] = nil
            return
          end

          -- 检查标志：如果 BufEnter 已经触发（用户快速切回），跳过隐藏
          if not _pending_hide_flags[buf] then
            return
          end
          _pending_hide_flags[buf] = nil

          local current_buf = vim.api.nvim_get_current_buf()
          if current_buf and vim.api.nvim_buf_is_valid(current_buf) then
            local ok2, is_float = pcall(vim.api.nvim_buf_get_var, current_buf, "neoai_float_window")
            if ok2 and is_float then
              return
            end
          end
          M.hide_float_window(buf)
        end, 50)
      end,
      desc = "隐藏 " .. window_type .. " 悬浮窗口",
    })

    vim.api.nvim_create_autocmd("BufEnter", {
      group = group,
      buffer = buf,
      callback = function()
        -- 进入 chat 窗口时确保启用自动换行
        if window_type == "chat" then
          local win = window_info.win
          if win and vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_set_option_value("wrap", true, { win = win })
            vim.api.nvim_set_option_value("linebreak", true, { win = win })
          end
        end

        -- 清除延迟隐藏标志，阻止 BufLeave 中 defer_fn 的 hide_float_window 执行
        _pending_hide_flags[buf] = nil

        M.show_float_window(buf)
        if window_type == "tree" then
          local ok, tw = pcall(require, "NeoAI.ui.window.tree_window")
          if ok and tw and tw.update_float_window then
            tw.update_float_window()
          end
        end
      end,
      desc = "显示 " .. window_type .. " 悬浮窗口",
    })
  end

  return window_id
end

function M.close_window(window_id)
  local window = windows[window_id]
  if not window then
    return
  end

  -- 检查 Neovim 是否正在退出，避免在退出过程中操作窗口导致死循环
  local ok_tp, tp = pcall(vim.api.nvim_get_current_tabpage)
  if not ok_tp or not tp then
    -- Neovim 正在退出，直接清理内部状态，不操作窗口
    M._cleanup_window_associations(window_id)
    windows[window_id] = nil
    return
  end

  -- 先关闭所有子窗口（递归关闭，确保 tool_display/reasoning/pty_terminal 等先关闭）
  local children = parent_child_map[window_id]
  if children then
    for child_id, _ in pairs(children) do
      if child_id ~= window_id then
        M.close_window(child_id)
      end
    end
    parent_child_map[window_id] = nil
  end

  -- 清理子窗口关联（如果当前窗口是子窗口）
  M._cleanup_window_associations(window_id)

  if window.window_info then
    close_window_by_mode(window.window_info)
  end

  -- 关闭 chat 窗口后恢复之前保存的 wrap 状态
  if window.type == "chat" then
    local saved_wrap = state.saved_wrap_states[window_id]
    if saved_wrap ~= nil then
      -- 窗口关闭后，当前活跃窗口应该是之前所在的窗口，恢复其 wrap 状态
      local ok_cur, cur_win = pcall(vim.api.nvim_get_current_win)
      if ok_cur and cur_win and vim.api.nvim_win_is_valid(cur_win) then
        vim.api.nvim_set_option_value("wrap", saved_wrap, { win = cur_win })
      end
    end
    state.saved_wrap_states[window_id] = nil
  end

  local event_map = { chat = Events.CHAT_WINDOW_CLOSED, tree = Events.TREE_WINDOW_CLOSED }
  local event_name = event_map[window.type]
  if event_name then
    vim.api.nvim_exec_autocmds("User", {
      pattern = event_name,
      data = { window_id = window_id, window_type = window.type },
    })
  end

  -- 清理窗口的协程上下文
  window.context = nil

  windows[window_id] = nil
end

--- 查找当前 chat/tree 父窗口 ID
--- 用于子窗口（tool_display/reasoning/pty_terminal）自动关联
--- @return string|nil
function M._find_parent_window_id()
  for id, w in pairs(windows) do
    if (w.type == "chat" or w.type == "tree") and w.win and vim.api.nvim_win_is_valid(w.win) then
      return id
    end
  end
  return nil
end

--- 清理窗口的父子关联（从父窗口的子列表中移除，清理子窗口映射）
--- 在任何窗口关闭时（包括自动关闭、Neovim 退出）都应调用
--- @param window_id string 窗口 ID
function M._cleanup_window_associations(window_id)
  -- 如果当前窗口是子窗口，从父窗口的子列表中移除
  local parent_id = child_parent_map[window_id]
  if parent_id and parent_child_map[parent_id] then
    parent_child_map[parent_id][window_id] = nil
    -- 如果父窗口的子列表为空，清理空表
    if not next(parent_child_map[parent_id]) then
      parent_child_map[parent_id] = nil
    end
  end
  child_parent_map[window_id] = nil

  -- 清理当前窗口的子窗口列表
  parent_child_map[window_id] = nil

  -- 清理隐藏状态
  child_window_hidden_states[window_id] = nil
end

-- ========== 便捷函数 ==========

function M.create_chat_window(options)
  return M.create_window("chat", options)
end
function M.create_tree_window(options)
  return M.create_window("tree", options)
end

-- ========== 查询 ==========

function M.get_chat_window()
  for id, w in pairs(windows) do
    if w.type == "chat" then
      return M.get_window(id)
    end
  end
  return nil
end

function M.get_tree_window()
  for id, w in pairs(windows) do
    if w.type == "tree" then
      return M.get_window(id)
    end
  end
  return nil
end

function M.get_window(window_id)
  return vim.deepcopy(windows[window_id])
end

function M.list_windows()
  local result = {}
  for id, w in pairs(windows) do
    table.insert(
      result,
      { id = id, type = w.type, created_at = w.created_at, valid = vim.api.nvim_win_is_valid(w.win) }
    )
  end
  return result
end

function M.focus_window(window_id)
  local w = windows[window_id]
  if w and w.window_info then
    local wi = w.window_info
    if wi.win and vim.api.nvim_win_is_valid(wi.win) then
      vim.api.nvim_set_current_win(wi.win)
    end
  end
end

function M.close_all()
  -- 检查 Neovim 是否正在退出，如果是则直接清空状态不操作窗口
  local ok_tp, tp = pcall(vim.api.nvim_get_current_tabpage)
  if not ok_tp or not tp then
    windows = {}
    return
  end
  for id, _ in pairs(windows) do
    M.close_window(id)
  end
  windows = {}
end

function M.get_window_buf(window_id)
  return windows[window_id] and windows[window_id].buf or nil
end

function M.get_window_win(window_id)
  return windows[window_id] and windows[window_id].win or nil
end

function M.get_window_info(window_id)
  return windows[window_id]
end

function M.get_window_type(window_id)
  return windows[window_id] and windows[window_id].type or nil
end

--- 获取窗口的协程上下文
--- 每个 chat/tree 窗口在创建时都会生成一个新的协程上下文
--- 协程内共享变量（如 session_id、window_id 等）通过此上下文隔离
--- @param window_id string 窗口ID
--- @return table|nil 上下文对象，非 chat/tree 窗口返回 nil
function M.get_window_context(window_id)
  local w = windows[window_id]
  if not w then
    return nil
  end
  return w.context
end

function M.find_windows_by_type(window_type)
  local result = {}
  for id, w in pairs(windows) do
    if w.type == window_type then
      table.insert(result, id)
    end
  end
  return result
end

function M.is_window_open(window_id)
  local w = windows[window_id]
  return w and w.win and vim.api.nvim_win_is_valid(w.win) or false
end

-- ========== 内容设置 ==========

local function clean_content_table(content_table)
  if type(content_table) ~= "table" then
    return content_table
  end
  local cleaned = {}
  for _, line in ipairs(content_table) do
    if type(line) == "string" then
      for _, sub in ipairs(vim.split(line, "\n")) do
        table.insert(cleaned, sub)
      end
    else
      table.insert(cleaned, line)
    end
  end
  return cleaned
end

function M.set_window_content(window_id, content)
  local window = windows[window_id]
  if not window or not window.window_info then
    return
  end

  local wi = window.window_info
  local buf = wi.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_set_option_value("readonly", false, { buf = buf })

  pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, {})

  local lines = type(content) == "table" and clean_content_table(content) or vim.split(content or "", "\n")
  pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines)

  local ft = window.type == "chat" and "neoai" or "neoai_" .. window.type
  vim.api.nvim_set_option_value("filetype", ft, { buf = buf })

  if window.type == "chat" then
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_set_option_value("readonly", false, { buf = buf })
    vim.api.nvim_set_option_value("modified", false, { buf = buf })
    local win = wi.win
    if win and vim.api.nvim_win_is_valid(win) then
      -- 合并设置窗口选项，减少 API 调用次数
      local win_opts = {
        foldmethod = "marker",
        foldmarker = "{{{,}}}",
        foldlevel = 0,
        foldenable = true,
        wrap = true,
        linebreak = true,
      }
      for name, val in pairs(win_opts) do
        vim.api.nvim_set_option_value(name, val, { win = win })
      end
    end
  elseif window.type == "tree" or window.type == "reasoning" then
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
    vim.api.nvim_set_option_value("readonly", true, { buf = buf })
    vim.api.nvim_set_option_value("modified", false, { buf = buf })
  else
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_set_option_value("readonly", false, { buf = buf })
  end
  vim.api.nvim_set_option_value("modified", false, { buf = buf })
end

function M.append_window_content(window_id, content)
  local w = windows[window_id]
  if not w or not w.window_info then
    return
  end
  local buf = w.window_info.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local line_count = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, vim.split(content, "\n"))
end

function M.update_window_options(window_id, options)
  local w = windows[window_id]
  if not w or not vim.api.nvim_win_is_valid(w.win) then
    return
  end
  w.options = vim.tbl_extend("force", w.options, options or {})
  vim.api.nvim_win_set_config(w.win, w.options)
end

-- ========== 模式切换 ==========

function M.toggle_mode(mode)
  if not state.initialized then
    return
  end
  if mode then
    if vim.tbl_contains(state.available_modes, mode) then
      state.current_mode = mode
      vim.notify("[NeoAI] 窗口模式切换为: " .. mode, vim.log.levels.INFO)
    else
      vim.notify("[NeoAI] 无效的窗口模式: " .. mode, vim.log.levels.ERROR)
    end
  else
    local idx = 1
    for i, m in ipairs(state.available_modes) do
      if m == state.current_mode then
        idx = i
        break
      end
    end
    state.current_mode = state.available_modes[(idx % #state.available_modes) + 1]
    vim.notify("[NeoAI] 窗口模式切换为: " .. state.current_mode, vim.log.levels.INFO)
  end
end

function M.get_current_mode()
  return state.current_mode
end

function M.set_mode(mode)
  if not state.initialized then
    return
  end
  if vim.tbl_contains(state.available_modes, mode) then
    state.current_mode = mode
    vim.notify("[NeoAI] 窗口模式设置为: " .. mode, vim.log.levels.INFO)
  else
    vim.notify("[NeoAI] 无效的窗口模式: " .. mode, vim.log.levels.ERROR)
  end
end

--- 检查一个窗口是否是 NeoAI 管理的窗口
--- 遍历内部 windows 表，检查目标窗口句柄是否在其中
--- @param win number 窗口句柄
--- @return boolean
function M.is_neoai_window(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  -- 检查 window_manager 内部注册的窗口
  for _, w in pairs(windows) do
    if w.win == win then
      return true
    end
  end
  -- 检查 tool_approval 组件窗口
  local tool_approval_win = require("NeoAI.ui.components.tool_approval").get_win_id()
  if tool_approval_win and tool_approval_win == win then
    return true
  end
  return false
end

function M.is_window_valid(window_info)
  return window_info
    and window_info.win
    and vim.api.nvim_win_is_valid(window_info.win)
    and window_info.buf
    and vim.api.nvim_buf_is_valid(window_info.buf)
end

function M.update_config(new_config)
  if not state.initialized then
    return
  end
  -- 配置统一由 state_manager 管理，此处无需保存副本
end

-- ========== 悬浮窗口管理 ==========

function M.register_float_window(main_buf, float_win_id, float_buf_id)
  float_windows[main_buf] = { win_id = float_win_id, buf_id = float_buf_id, visible = true }
  if float_buf_id and vim.api.nvim_buf_is_valid(float_buf_id) then
    vim.api.nvim_buf_set_var(float_buf_id, "neoai_float_window", true)
  end
end

function M.show_float_window(main_buf)
  -- 显示注册的浮动窗口（如虚拟输入框）
  local fw = float_windows[main_buf]
  if fw and not fw.visible then
    if fw.win_id and vim.api.nvim_win_is_valid(fw.win_id) then
      if fw.saved_config then
        pcall(vim.api.nvim_win_set_config, fw.win_id, fw.saved_config)
      end
      fw.visible = true
    end
  end

  -- 恢复所有关联的子窗口
  local parent_id = M._find_window_id_by_buf(main_buf)
  if parent_id and parent_child_map[parent_id] then
    for child_id, _ in pairs(parent_child_map[parent_id]) do
      local hidden = child_window_hidden_states[child_id]
      if hidden then
        local child_win = M.get_window_win(child_id)
        if child_win and vim.api.nvim_win_is_valid(child_win) then
          if hidden.saved_config then
            pcall(vim.api.nvim_win_set_config, child_win, hidden.saved_config)
          end
        end
        child_window_hidden_states[child_id] = nil
      end
    end
  end

  -- 触发显示事件，通知各组件更新内部状态（如 is_visible）
  vim.api.nvim_exec_autocmds("User", {
    pattern = "NeoAI:float_windows_shown",
    data = { main_buf = main_buf, parent_id = parent_id },
  })
end

function M.hide_float_window(main_buf)
  -- 隐藏注册的浮动窗口（如虚拟输入框）
  local fw = float_windows[main_buf]
  if fw and fw.visible then
    if fw.win_id and vim.api.nvim_win_is_valid(fw.win_id) then
      fw.saved_config = vim.api.nvim_win_get_config(fw.win_id)
      vim.api.nvim_win_set_config(fw.win_id, { relative = "editor", row = -1000, col = -1000, width = 1, height = 1 })
      fw.visible = false
    end
  end

  -- 隐藏所有关联的子窗口
  local parent_id = M._find_window_id_by_buf(main_buf)
  if parent_id and parent_child_map[parent_id] then
    for child_id, _ in pairs(parent_child_map[parent_id]) do
      local child_win = M.get_window_win(child_id)
      if child_win and vim.api.nvim_win_is_valid(child_win) then
        if not child_window_hidden_states[child_id] then
          child_window_hidden_states[child_id] = {
            saved_config = vim.api.nvim_win_get_config(child_win),
          }
          vim.api.nvim_win_set_config(
            child_win,
            { relative = "editor", row = -1000, col = -1000, width = 1, height = 1 }
          )
        end
      end
    end
  end

  -- 触发隐藏事件，通知各组件更新内部状态（如 is_visible）
  vim.api.nvim_exec_autocmds("User", {
    pattern = "NeoAI:float_windows_hidden",
    data = { main_buf = main_buf, parent_id = parent_id },
  })
end

--- 通过 buffer 句柄查找窗口 ID
--- @param buf number buffer 句柄
--- @return string|nil
function M._find_window_id_by_buf(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  for id, w in pairs(windows) do
    if w.buf == buf then
      return id
    end
  end
  return nil
end

function M.unregister_float_window(main_buf)
  local fw = float_windows[main_buf]
  if not fw then
    return
  end
  if fw.win_id and vim.api.nvim_win_is_valid(fw.win_id) then
    vim.api.nvim_win_close(fw.win_id, true)
  end
  if fw.buf_id and vim.api.nvim_buf_is_valid(fw.buf_id) then
    vim.api.nvim_buf_delete(fw.buf_id, { force = true })
  end
  float_windows[main_buf] = nil
end

-- ========== 渲染树（通用） ==========

local function safe_truncate(str, max_len)
  if #str <= max_len then
    return str
  end
  local cleaned = str:gsub("[%c%z]", ""):gsub("%b<>", "")
  if #cleaned < #str then
    str = cleaned
  end
  if #str <= max_len then
    return str
  end
  local truncated = str:sub(1, max_len)
  local last_byte = truncated:sub(-1):byte()
  if last_byte and last_byte >= 0x80 then
    for i = max_len, 1, -1 do
      local b = truncated:sub(i, i):byte()
      if b and (b < 0x80 or b >= 0xC0) then
        if i < max_len then
          truncated = truncated:sub(1, i)
        end
        break
      end
    end
  end
  return truncated:gsub("%b<>", "")
end

function M.render_tree(tree_data, tree_state, load_data_func, window_width)
  if tree_data then
    tree_state.tree_data = tree_data
  end
  if #tree_state.tree_data == 0 and load_data_func then
    load_data_func(nil)
  end
  local content = { "=== NeoAI 会话树 ===", "" }
  if #tree_state.tree_data == 0 then
    table.insert(content, "暂无会话")
    table.insert(content, "按 N 创建新会话")
  else
    for i, root in ipairs(tree_state.tree_data) do
      M._render_tree_node(content, root, 0, i == #tree_state.tree_data, "", tree_state, window_width, true)
    end
  end
  table.insert(content, "")
  table.insert(content, "---")
  table.insert(content, "使用方向键导航，Enter 选择，n/N 新建节点，d 删除")
  return content
end

function M._render_tree_node(content, node, depth, is_last, parent_prefix, tree_state, window_width, is_root)
  if not node then
    return
  end
  local current_prefix = parent_prefix or ""
  local line

  if is_root then
    local prefix = is_last and "└──" or "├──"
    local icon = node.is_virtual and "📂 " or ""
    line = prefix .. icon .. (node.name or "未命名")
    if node.round_count and node.round_count > 0 then
      line = line .. "  (" .. node.round_count .. "轮)"
    end
  elseif node.is_virtual then
    line = current_prefix .. "📂 " .. (node.name or "分支")
    if node.round_count and node.round_count > 0 then
      line = line .. "  (" .. node.round_count .. "轮)"
    end
  else
    local prefix = is_last and "└───" or "├───"
    line = current_prefix .. prefix .. (node.name or "未命名")
  end

  line = line:gsub("%b<>", " "):gsub("[%c%z]", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if line == "" then
    line = "未命名"
  end

  if window_width and window_width > 0 and #line > window_width then
    local effective_prefix = node.is_virtual and current_prefix
      or (
        is_root and (is_last and "└──" or "├──")
        or current_prefix .. (is_last and "└───" or "├───")
      )
    local max_text_len = window_width - #effective_prefix - 3
    if max_text_len > 0 then
      line = effective_prefix .. safe_truncate(line:sub(#effective_prefix + 1), max_text_len) .. "..."
    end
  end

  table.insert(content, line)

  if tree_state.expanded_nodes and tree_state.expanded_nodes[node.id] and node.children and #node.children > 0 then
    local child_parent_prefix
    if is_root then
      child_parent_prefix = is_last and "    " or "│   "
    elseif node.is_virtual then
      child_parent_prefix = current_prefix .. (is_last and "    " or "│   ")
    else
      child_parent_prefix = current_prefix .. (is_last and "    " or "│   ")
    end
    for i, child in ipairs(node.children) do
      M._render_tree_node(
        content,
        child,
        depth + 1,
        i == #node.children,
        child_parent_prefix,
        tree_state,
        window_width,
        false
      )
    end
  end
end

-- ========== 工具调用悬浮窗管理 ==========

-- 每个 tool_display 窗口的私有状态（与 chat_window 的 state 隔离）
local tool_displays = {} -- { [window_id] = { auto_scroll = true, buffer = "", _last_buffer = "" } }

-- 工具显示滚动状态（供 tool_display 组件使用）
local tool_display_scroll_states = {} -- { [window_id] = true/false }

--- 打开 tool_display 悬浮窗
--- @param opts table 选项
---   title: string 窗口标题
---   content: string 初始内容
---   reasoning_display: table|nil reasoning_display 模块引用
--- @return string|nil 窗口 ID
function M.open_tool_display(opts)
  opts = opts or {}
  local title = opts.title or "🔧 工具调用"
  local content = opts.content or ""
  local content_lines = vim.split(content, "\n")

  local max_height = math.max(5, math.floor(vim.o.lines / 2))
  local dynamic_height = math.max(5, math.min(#content_lines + 2, max_height))

  -- 计算窗口位置：如果 reasoning_display 可见，在它下方堆叠
  local tool_row = 1
  local rd = opts.reasoning_display
  if rd and rd.is_visible and rd.is_visible() then
    local rwid = rd.get_window_id and rd.get_window_id()
    if rwid then
      local rwin = M.get_window_win(rwid)
      if rwin and pcall(vim.api.nvim_win_is_valid, rwin) then
        local rc = vim.api.nvim_win_get_config(rwin)
        tool_row = (rc.row or 1) + (rc.height or 5) + 1
      end
    end
  end

  local total_cols = vim.o.columns
  local tool_width = math.floor(total_cols * 0.8)
  tool_width = math.max(30, tool_width)
  local tool_col = math.floor((total_cols - tool_width) / 2)

  local tool_border = {
    { "╭", "FloatBorder" },
    { "─", "FloatBorder" },
    { "┬", "FloatBorder" },
    { "│", "FloatBorder" },
    { "┴", "FloatBorder" },
    { "─", "FloatBorder" },
    { "╰", "FloatBorder" },
    { "│", "FloatBorder" },
  }

  local win_id = M.create_window("tool_display", {
    title = title,
    width = tool_width,
    height = dynamic_height,
    border = tool_border,
    style = "minimal",
    relative = "editor",
    row = tool_row,
    col = tool_col,
    zindex = 100,
    window_mode = "float",
  })
  if not win_id then
    return nil
  end

  -- 初始化私有状态
  tool_displays[win_id] = {
    auto_scroll = true,
    buffer = content,
    _last_buffer = "",
  }

  -- 写入初始内容
  local nvim_win = M.get_window_win(win_id)
  local buf = M.get_window_buf(win_id)
  if buf and pcall(vim.api.nvim_buf_is_valid, buf) then
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, content_lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  end
  if nvim_win and pcall(vim.api.nvim_win_is_valid, nvim_win) then
    pcall(vim.api.nvim_set_option_value, "wrap", true, { win = nvim_win })
    if buf and pcall(vim.api.nvim_buf_is_valid, buf) then
      local line_count = vim.api.nvim_buf_line_count(buf)
      pcall(vim.api.nvim_win_set_cursor, nvim_win, { line_count, 0 })
    end
  end

  -- 注册 WinScrolled 监听：检测用户手动滚动
  local augroup_name = "NeoAI_tool_scroll_" .. win_id
  vim.api.nvim_create_augroup(augroup_name, { clear = true })
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = augroup_name,
    buffer = buf,
    callback = function()
      local td = tool_displays[win_id]
      if not td then
        return
      end
      local win_ok, win_valid = pcall(vim.api.nvim_win_is_valid, nvim_win)
      if not win_ok or not win_valid then
        return
      end
      local buf_ok, buf_valid = pcall(vim.api.nvim_buf_is_valid, buf)
      if not buf_ok or not buf_valid then
        return
      end
      local cur_line = vim.api.nvim_win_get_cursor(nvim_win)[1]
      local line_count = vim.api.nvim_buf_line_count(buf)
      td.auto_scroll = (cur_line >= line_count)
    end,
  })

  -- 触发事件通知右侧伪终端窗口调整布局
  vim.api.nvim_exec_autocmds("User", {
    pattern = "NeoAI:tool_display_resized",
    data = { window_id = win_id, height = dynamic_height, row = tool_row, width = tool_width, col = 1 },
  })

  return win_id
end

--- 更新 tool_display 悬浮窗内容
--- @param window_id string 窗口 ID
--- @param content string 新内容
function M.update_tool_display(window_id, content)
  local td = tool_displays[window_id]
  if not td then
    return
  end

  -- 内容没变则跳过
  if content == td._last_buffer then
    return
  end
  td._last_buffer = content
  td.buffer = content

  local buf = M.get_window_buf(window_id)
  if not buf or not pcall(vim.api.nvim_buf_is_valid, buf) then
    return
  end

  local lines = vim.split(content, "\n")
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  -- 自动滚动
  if td.auto_scroll then
    local nvim_win = M.get_window_win(window_id)
    if nvim_win and pcall(vim.api.nvim_win_is_valid, nvim_win) then
      local line_count = vim.api.nvim_buf_line_count(buf)
      pcall(vim.api.nvim_win_set_cursor, nvim_win, { line_count, 0 })
    end
  end
end

--- 增量追加 tool_display 悬浮窗内容（只追加新增的文本到末尾）
--- 先将 JSON 转义字符（\n、\t、\\ 等）渲染为可读格式，再按换行拆分插入
--- @param window_id string 窗口 ID
--- @param append_text string 要追加的文本
function M.append_tool_display(window_id, append_text)
  if not append_text or append_text == "" then
    return
  end
  local td = tool_displays[window_id]
  if not td then
    return
  end

  local buf = M.get_window_buf(window_id)
  if not buf or not pcall(vim.api.nvim_buf_is_valid, buf) then
    return
  end

  -- 先将 JSON 转义字符渲染为可读格式
  local display_text = append_text
  display_text = display_text:gsub("\\n", "\n")
  display_text = display_text:gsub("\\t", "\t")
  display_text = display_text:gsub("\\\\", "\\")
  display_text = display_text:gsub('\\"', '"')

  local line_count = vim.api.nvim_buf_line_count(buf)
  local last_line = vim.api.nvim_buf_get_lines(buf, line_count - 1, line_count, false)[1] or ""

  -- 按真正换行拆分为多行
  local parts = vim.split(display_text, "\n", { plain = true })

  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  -- 第一段追加到最后一行的末尾
  local new_last_line = last_line .. parts[1]
  vim.api.nvim_buf_set_lines(buf, line_count - 1, line_count, false, { new_last_line })
  -- 剩余部分作为新行插入
  for i = 2, #parts do
    vim.api.nvim_buf_set_lines(buf, line_count + i - 2, line_count + i - 2, false, { parts[i] })
  end
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  -- 更新缓存（存原始文本，用于去重判断）
  td.buffer = td.buffer .. append_text
  td._last_buffer = td.buffer

  -- 强制滚动到末尾（预览窗口不需要判断用户是否滚动过）
  local nvim_win = M.get_window_win(window_id)
  if nvim_win and pcall(vim.api.nvim_win_is_valid, nvim_win) then
    local final_line_count = vim.api.nvim_buf_line_count(buf)
    local final_last_line = vim.api.nvim_buf_get_lines(buf, final_line_count - 1, final_line_count, false)[1] or ""
    pcall(vim.api.nvim_win_set_cursor, nvim_win, { final_line_count, #final_last_line })
  end
end

--- 关闭 tool_display 悬浮窗
--- @param window_id string 窗口 ID
function M.close_tool_display(window_id)
  if not window_id then
    return
  end
  tool_displays[window_id] = nil
  local augroup_name = "NeoAI_tool_scroll_" .. window_id
  pcall(vim.api.nvim_del_augroup_by_name, augroup_name)
  M.close_window(window_id)
end

--- 重置 tool_display 窗口的 auto_scroll 为 true
--- @param window_id string 窗口 ID
function M.reset_tool_display_scroll(window_id)
  local td = tool_displays[window_id]
  if td then
    td.auto_scroll = true
  end
end

--- 设置 tool_display 窗口的滚动状态
--- @param window_id string 窗口 ID
--- @param auto_scroll boolean 是否自动滚动
function M.set_tool_display_scroll(window_id, auto_scroll)
  tool_display_scroll_states[window_id] = auto_scroll
end

--- 获取 tool_display 窗口的滚动状态
--- @param window_id string 窗口 ID
--- @return boolean
function M.get_tool_display_scroll(window_id)
  if tool_display_scroll_states[window_id] ~= nil then
    return tool_display_scroll_states[window_id]
  end
  return true -- 默认自动滚动
end

--- 清理 tool_display 窗口的滚动状态
--- @param window_id string 窗口 ID
function M.clear_tool_display_scroll(window_id)
  tool_display_scroll_states[window_id] = nil
end

return M
