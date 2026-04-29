local M = {}

local logger = require("NeoAI.utils.logger")
local Events = require("NeoAI.core.events")

local windows = {}
local window_counter = 0
local float_windows = {}

local state = {
  initialized = false, config = nil,
  default_options = {
    relative = "editor", style = "minimal", border = "rounded",
    title = "NeoAI", title_pos = "center", zindex = 50,
  },
  current_mode = "float",
  available_modes = { "float", "tab", "split" },
}

-- ========== LSP 阻止 ==========

local _blocked_buffers = {}

function M.block_lsp_for_buffer(buf, label)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  -- 避免重复注册
  if _blocked_buffers[buf] then return end
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
    group = group, buffer = buf,
    callback = function()
      -- 检查 Neovim 是否正在退出，避免在退出过程中调度 defer_fn 导致死循环
      local ok, tp = pcall(vim.api.nvim_get_current_tabpage)
      if not ok or not tp then return end

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
  if state.initialized then return end
  state.config = vim.tbl_extend("force", state.default_options, config or {})
  state.current_mode = config and config.default_mode or "float"
  state.initialized = true

  vim.api.nvim_create_autocmd("LspAttach", {
    group = vim.api.nvim_create_augroup("NeoAIBlockLSP", { clear = true }),
    callback = function(args)
      local buf = args.buf
      if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
      local ok, neoai_no_lsp = pcall(vim.api.nvim_buf_get_var, buf, "neoai_no_lsp")
      if ok and neoai_no_lsp then
        local client_id = args.data and args.data.client_id
        if client_id then pcall(vim.lsp.buf_detach_client, buf, client_id) end
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
    relative = "editor", style = "minimal", border = "rounded",
    title = "NeoAI", title_pos = "center", zindex = 50,
  }, options or {})

  opts.width = opts.width or math.floor(vim.o.columns * 0.8)
  opts.height = opts.height or math.floor(vim.o.lines * 0.8)
  opts.row = opts.row or math.floor((vim.o.lines - opts.height) / 2)
  opts.col = opts.col or math.floor((vim.o.columns - opts.width) / 2)

  local window_type = options and options._window_type or ""
  local is_temp = (window_type == "tool_display" or window_type == "reasoning")
  local buf = vim.api.nvim_create_buf(false, is_temp)
  setup_buf(buf, is_temp)

  local valid_params = {
    "relative", "width", "height", "row", "col", "anchor", "win",
    "bufpos", "external", "focusable", "zindex", "style", "border",
    "title", "title_pos", "noautocmd",
  }
  local filtered = {}
  for _, p in ipairs(valid_params) do
    if opts[p] ~= nil then filtered[p] = opts[p] end
  end

  local win = vim.api.nvim_open_win(buf, not is_temp, filtered)
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
  if size then cmd = cmd .. " " .. tostring(size) end
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
  if not window_info then return end
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
              if tp ~= tabpage then vim.api.nvim_set_current_tabpage(tp); break end
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
  if not state.initialized then error("Window manager not initialized") end

  window_counter = window_counter + 1
  local window_id = "win_" .. tostring(os.time()) .. "_" .. window_counter
  local merged = vim.tbl_extend("force", state.config, options or {})
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

  windows[window_id] = {
    id = window_id, type = window_type, buf = window_info.buf,
    win = window_info.win, options = merged, created_at = os.time(), window_info = window_info,
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

  if not vim.tbl_contains({ "tool_display", "reasoning" }, window_type) then
    vim.api.nvim_buf_set_name(window_info.buf, "neoai://" .. window_type .. "/" .. window_id)
  end

  -- 注册 BufLeave/BufEnter 管理悬浮窗口
  if vim.tbl_contains({ "chat", "tree" }, window_type) then
    local buf = window_info.buf
    local augroup = "NeoAIFloatWindow_" .. window_id
    pcall(vim.api.nvim_del_augroup_by_name, augroup)
    local group = vim.api.nvim_create_augroup(augroup, { clear = true })

    vim.api.nvim_create_autocmd("BufLeave", {
      group = group, buffer = buf,
      callback = function()
        vim.defer_fn(function()
          -- 检查 Neovim 是否正在退出，避免在退出过程中操作窗口导致死循环
          local ok, tp = pcall(vim.api.nvim_get_current_tabpage)
          if not ok or not tp then return end

          local current_buf = vim.api.nvim_get_current_buf()
          if current_buf and vim.api.nvim_buf_is_valid(current_buf) then
            local ok2, is_float = pcall(vim.api.nvim_buf_get_var, current_buf, "neoai_float_window")
            if ok2 and is_float then return end
          end
          M.hide_float_window(buf)
        end, 50)
      end,
      desc = "隐藏 " .. window_type .. " 悬浮窗口",
    })

    vim.api.nvim_create_autocmd("BufEnter", {
      group = group, buffer = buf,
      callback = function()
        M.show_float_window(buf)
        if window_type == "tree" then
          local ok, tw = pcall(require, "NeoAI.ui.window.tree_window")
          if ok and tw and tw.update_float_window then tw.update_float_window() end
        end
      end,
      desc = "显示 " .. window_type .. " 悬浮窗口",
    })
  end

  return window_id
end

function M.close_window(window_id)
  local window = windows[window_id]
  if not window then return end

  -- 检查 Neovim 是否正在退出，避免在退出过程中操作窗口导致死循环
  local ok_tp, tp = pcall(vim.api.nvim_get_current_tabpage)
  if not ok_tp or not tp then
    -- Neovim 正在退出，直接清理内部状态，不操作窗口
    windows[window_id] = nil
    return
  end

  if window.window_info then close_window_by_mode(window.window_info) end

  local event_map = { chat = Events.CHAT_WINDOW_CLOSED, tree = Events.TREE_WINDOW_CLOSED }
  local event_name = event_map[window.type]
  if event_name then
    vim.api.nvim_exec_autocmds("User", {
      pattern = event_name,
      data = { window_id = window_id, window_type = window.type },
    })
  end

  windows[window_id] = nil
end

-- ========== 便捷函数 ==========

function M.create_chat_window(options) return M.create_window("chat", options) end
function M.create_tree_window(options) return M.create_window("tree", options) end

-- ========== 查询 ==========

function M.get_chat_window()
  for id, w in pairs(windows) do
    if w.type == "chat" then return M.get_window(id) end
  end
  return nil
end

function M.get_tree_window()
  for id, w in pairs(windows) do
    if w.type == "tree" then return M.get_window(id) end
  end
  return nil
end

function M.get_window(window_id) return vim.deepcopy(windows[window_id]) end

function M.list_windows()
  local result = {}
  for id, w in pairs(windows) do
    table.insert(result, { id = id, type = w.type, created_at = w.created_at, valid = vim.api.nvim_win_is_valid(w.win) })
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
  for id, _ in pairs(windows) do M.close_window(id) end
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

function M.find_windows_by_type(window_type)
  local result = {}
  for id, w in pairs(windows) do
    if w.type == window_type then table.insert(result, id) end
  end
  return result
end

function M.is_window_open(window_id)
  local w = windows[window_id]
  return w and w.win and vim.api.nvim_win_is_valid(w.win) or false
end

-- ========== 内容设置 ==========

local function clean_content_table(content_table)
  if type(content_table) ~= "table" then return content_table end
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
  if not window or not window.window_info then return end

  local wi = window.window_info
  local buf = wi.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end

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
        foldmethod = "marker", foldmarker = "{{{,}}}", foldlevel = 0,
        foldenable = true, wrap = true, linebreak = true,
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
  if not w or not w.window_info then return end
  local buf = w.window_info.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local line_count = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, vim.split(content, "\n"))
end

function M.update_window_options(window_id, options)
  local w = windows[window_id]
  if not w or not vim.api.nvim_win_is_valid(w.win) then return end
  w.options = vim.tbl_extend("force", w.options, options or {})
  vim.api.nvim_win_set_config(w.win, w.options)
end

-- ========== 模式切换 ==========

function M.toggle_mode(mode)
  if not state.initialized then return end
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
      if m == state.current_mode then idx = i; break end
    end
    state.current_mode = state.available_modes[(idx % #state.available_modes) + 1]
    vim.notify("[NeoAI] 窗口模式切换为: " .. state.current_mode, vim.log.levels.INFO)
  end
end

function M.get_current_mode() return state.current_mode end

function M.set_mode(mode)
  if not state.initialized then return end
  if vim.tbl_contains(state.available_modes, mode) then
    state.current_mode = mode
    vim.notify("[NeoAI] 窗口模式设置为: " .. mode, vim.log.levels.INFO)
  else
    vim.notify("[NeoAI] 无效的窗口模式: " .. mode, vim.log.levels.ERROR)
  end
end

function M.is_window_valid(window_info)
  return window_info and window_info.win and vim.api.nvim_win_is_valid(window_info.win)
    and window_info.buf and vim.api.nvim_buf_is_valid(window_info.buf)
end

function M.update_config(new_config)
  if not state.initialized then return end
  state.config = vim.tbl_extend("force", state.config, new_config or {})
end

-- ========== 悬浮窗口管理 ==========

function M.register_float_window(main_buf, float_win_id, float_buf_id)
  float_windows[main_buf] = { win_id = float_win_id, buf_id = float_buf_id, visible = true }
  if float_buf_id and vim.api.nvim_buf_is_valid(float_buf_id) then
    vim.api.nvim_buf_set_var(float_buf_id, "neoai_float_window", true)
  end
end

function M.show_float_window(main_buf)
  local fw = float_windows[main_buf]
  if not fw or fw.visible then return end
  if fw.win_id and vim.api.nvim_win_is_valid(fw.win_id) then
    if fw.saved_config then pcall(vim.api.nvim_win_set_config, fw.win_id, fw.saved_config) end
    fw.visible = true
  end
end

function M.hide_float_window(main_buf)
  local fw = float_windows[main_buf]
  if not fw or not fw.visible then return end
  if fw.win_id and vim.api.nvim_win_is_valid(fw.win_id) then
    fw.saved_config = vim.api.nvim_win_get_config(fw.win_id)
    vim.api.nvim_win_set_config(fw.win_id, { relative = "editor", row = -1000, col = -1000, width = 1, height = 1 })
    fw.visible = false
  end
end

function M.unregister_float_window(main_buf)
  local fw = float_windows[main_buf]
  if not fw then return end
  if fw.win_id and vim.api.nvim_win_is_valid(fw.win_id) then vim.api.nvim_win_close(fw.win_id, true) end
  if fw.buf_id and vim.api.nvim_buf_is_valid(fw.buf_id) then vim.api.nvim_buf_delete(fw.buf_id, { force = true }) end
  float_windows[main_buf] = nil
end

-- ========== 渲染树（通用） ==========

local function safe_truncate(str, max_len)
  if #str <= max_len then return str end
  local cleaned = str:gsub("[%c%z]", ""):gsub("%b<>", "")
  if #cleaned < #str then str = cleaned end
  if #str <= max_len then return str end
  local truncated = str:sub(1, max_len)
  local last_byte = truncated:sub(-1):byte()
  if last_byte and last_byte >= 0x80 then
    for i = max_len, 1, -1 do
      local b = truncated:sub(i, i):byte()
      if b and (b < 0x80 or b >= 0xC0) then
        if i < max_len then truncated = truncated:sub(1, i) end
        break
      end
    end
  end
  return truncated:gsub("%b<>", "")
end

function M.render_tree(tree_data, tree_state, load_data_func, window_width)
  if tree_data then tree_state.tree_data = tree_data end
  if #tree_state.tree_data == 0 and load_data_func then load_data_func(nil) end
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
  if not node then return end
  local current_prefix = parent_prefix or ""
  local line

  if is_root then
    local prefix = is_last and "└──" or "├──"
    local icon = node.is_virtual and "📂 " or ""
    line = prefix .. icon .. (node.name or "未命名")
    if node.round_count and node.round_count > 0 then line = line .. "  (" .. node.round_count .. "轮)" end
  elseif node.is_virtual then
    line = current_prefix .. "📂 " .. (node.name or "分支")
    if node.round_count and node.round_count > 0 then line = line .. "  (" .. node.round_count .. "轮)" end
  else
    local prefix = is_last and "└───" or "├───"
    line = current_prefix .. prefix .. (node.name or "未命名")
  end

  line = line:gsub("%b<>", " "):gsub("[%c%z]", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if line == "" then line = "未命名" end

  if window_width and window_width > 0 and #line > window_width then
    local effective_prefix = node.is_virtual and current_prefix
      or (is_root and (is_last and "└──" or "├──") or current_prefix .. (is_last and "└───" or "├───"))
    local max_text_len = window_width - #effective_prefix - 3
    if max_text_len > 0 then line = effective_prefix .. safe_truncate(line:sub(#effective_prefix + 1), max_text_len) .. "..." end
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
      M._render_tree_node(content, child, depth + 1, i == #node.children, child_parent_prefix, tree_state, window_width, false)
    end
  end
end

return M
