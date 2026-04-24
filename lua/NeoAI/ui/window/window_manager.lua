local M = {}

-- 窗口存储
local windows = {}
local window_counter = 0

-- 模块状态
local state = {
  initialized = false,
  config = nil,
  default_options = {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = "NeoAI",
    title_pos = "center",
    zindex = 50,
  },
  current_mode = "float", -- 默认模式
  available_modes = { "float", "tab", "split" },
}

--- 初始化窗口管理器
--- @param config table 配置
function M.initialize(config)
  if state.initialized then
    return
  end
  state.config = vim.tbl_extend("force", state.default_options, config or {})
  state.current_mode = config and config.default_mode or "float"
  state.initialized = true
end

--- 创建浮动窗口
--- @param options table 窗口选项
--- @return table|nil 窗口信息 {buf, win, id}
local function create_float_window(options)
  local merged_options = vim.tbl_extend("force", {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = "NeoAI",
    title_pos = "center",
    zindex = 50,
  }, options or {})

  -- 设置窗口大小和位置
  if not merged_options.width then
    merged_options.width = math.floor(vim.o.columns * 0.8)
  end

  if not merged_options.height then
    merged_options.height = math.floor(vim.o.lines * 0.8)
  end

  if not merged_options.row then
    merged_options.row = math.floor((vim.o.lines - merged_options.height) / 2)
  end

  if not merged_options.col then
    merged_options.col = math.floor((vim.o.columns - merged_options.width) / 2)
  end

  -- 创建缓冲区
  local buf = vim.api.nvim_create_buf(false, true)
  -- 将缓冲区加入缓冲区列表
  vim.api.nvim_set_option_value("buflisted", true, { buf = buf })

  -- 创建浮动窗口
  local win_options = vim.deepcopy(merged_options)

  -- nvim_open_win 支持的参数列表
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

  -- 过滤掉不支持的参数
  local filtered_options = {}
  for _, param in ipairs(valid_params) do
    if win_options[param] ~= nil then
      filtered_options[param] = win_options[param]
    end
  end

  local win = vim.api.nvim_open_win(buf, true, filtered_options)

  -- 设置窗口选项
  vim.api.nvim_set_option_value("winhl", "Normal:Normal,FloatBorder:FloatBorder", { win = win })
  vim.api.nvim_set_option_value("winblend", win_options.winblend or 0, { win = win })

  -- 设置缓冲区选项
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_set_option_value("readonly", true, { buf = buf })
  -- 标记为未修改，避免保存警告
  vim.api.nvim_set_option_value("modified", false, { buf = buf })

  -- 设置缓冲区名称（临时名称，后面会覆盖）
  vim.api.nvim_buf_set_name(buf, "neoai://float/temp")

  return {
    buf = buf,
    win = win,
    id = "float_" .. tostring(buf) .. "_" .. tostring(win),
  }
end

--- 创建标签页窗口
--- @param options table 窗口选项
--- @return table|nil 窗口信息 {buf, win, id}
local function create_tab_window(options)
  -- 创建新标签页
  vim.cmd("tabnew")

  -- 获取当前窗口和缓冲区
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()

  -- 设置缓冲区选项
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_set_option_value("readonly", true, { buf = buf })

  -- 设置缓冲区名称（临时名称，后面会覆盖）
  vim.api.nvim_buf_set_name(buf, "neoai://tab/temp")

  -- 设置窗口标题
  if options and options.title then
    vim.api.nvim_set_option_value("titlestring", options.title, { scope = "global" })
  end
  return {
    buf = buf,
    win = win,
    id = "tab_" .. tostring(buf) .. "_" .. tostring(win),
  }
end

--- 创建分割窗口
--- @param options table 窗口选项
--- @return table|nil 窗口信息 {buf, win, id}
local function create_split_window(options)
  local split_cmd = "vsplit"
  local split_size = nil

  -- 根据选项决定分割方向
  if options and options.split_direction then
    if options.split_direction == "horizontal" then
      split_cmd = "split"
    elseif options.split_direction == "vertical" then
      split_cmd = "vsplit"
    end
  end
  -- 设置分割大小
  if options and options.split_size then
    split_size = options.split_size
  end
  -- 执行分割命令
  if split_size then
    vim.cmd(split_cmd .. " " .. split_size)
  else
    vim.cmd(split_cmd)
  end
  -- 获取当前窗口和缓冲区
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()

  -- 设置缓冲区选项
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_set_option_value("readonly", true, { buf = buf })

  -- 设置缓冲区名称（临时名称，后面会覆盖）
  vim.api.nvim_buf_set_name(buf, "neoai://split/temp")

  return {
    buf = buf,
    win = win,
    id = "split_" .. tostring(buf) .. "_" .. tostring(win),
  }
end

--- 根据模式创建窗口
--- @param mode string 窗口模式 ('float', 'tab', 'split')
--- @param options table 窗口选项
--- @return table|nil 窗口信息 {buf, win, id}
local function create_window_by_mode(mode, options)
  if mode == "float" then
    return create_float_window(options)
  elseif mode == "tab" then
    return create_tab_window(options)
  elseif mode == "split" then
    return create_split_window(options)
  else
    vim.notify("[NeoAI] 无效的窗口模式: " .. tostring(mode), vim.log.levels.ERROR)
    return nil
  end
end

--- 关闭窗口
--- @param window_info table 窗口信息
local function close_window_by_mode(window_info)
  if not window_info then
    return
  end
  local id = window_info.id or ""

  -- 根据窗口类型关闭
  if id:match("^float_") then
    -- 浮动窗口：关闭窗口并删除缓冲区
    if vim.api.nvim_win_is_valid(window_info.win) then
      vim.api.nvim_win_close(window_info.win, true)
    end
    if vim.api.nvim_buf_is_valid(window_info.buf) then
      vim.api.nvim_buf_delete(window_info.buf, { force = true })
    end
  elseif id:match("^tab_") then
    -- 标签页窗口：关闭标签页
    if vim.api.nvim_win_is_valid(window_info.win) then
      -- 切换到其他标签页再关闭当前标签页
      local tabpage = vim.api.nvim_win_get_tabpage(window_info.win)
      local tabpages = vim.api.nvim_list_tabpages()

      if #tabpages > 1 then
        -- 获取标签页编号
        local tabpage_number = vim.api.nvim_tabpage_get_number(tabpage)

        if tabpage_number then
          -- 使用 tabclose 命令关闭指定标签页
          vim.cmd("tabclose " .. tabpage_number)
        else
          -- 如果找不到编号，切换到其他标签页再关闭当前标签页
          for _, tp in ipairs(tabpages) do
            if tp ~= tabpage then
              vim.api.nvim_set_current_tabpage(tp)
              break
            end
          end
          -- 现在当前标签页是其他标签页，可以安全关闭原标签页
          vim.cmd("tabclose")
        end
      else
        -- 只有一个标签页，不能关闭
        vim.notify("[NeoAI] 不能关闭最后一个标签页", vim.log.levels.WARN)
      end
      -- 删除缓冲区
      if vim.api.nvim_buf_is_valid(window_info.buf) then
        vim.api.nvim_buf_delete(window_info.buf, { force = true })
      end
    end
  elseif id:match("^split_") then
    -- 分割窗口：关闭窗口
    if vim.api.nvim_win_is_valid(window_info.win) then
      vim.api.nvim_win_close(window_info.win, true)
    end
    if vim.api.nvim_buf_is_valid(window_info.buf) then
      vim.api.nvim_buf_delete(window_info.buf, { force = true })
    end
  end
end

--- 清理内容表中的换行符
--- @param content_table table 内容表
--- @return table 清理后的内容表
local function clean_content_table(content_table)
  if type(content_table) ~= "table" then
    return content_table
  end

  local cleaned = {}
  for _, line in ipairs(content_table) do
    if type(line) == "string" then
      -- 分割包含换行符的行
      local sub_lines = vim.split(line, "\n")
      for _, sub_line in ipairs(sub_lines) do
        table.insert(cleaned, sub_line)
      end
    else
      table.insert(cleaned, line)
    end
  end

  return cleaned
end

--- @param filetype string 文件类型
--- @param window_type string|nil 窗口类型（可选，用于chat类型设置折叠）
local function set_window_content_by_mode(window_info, content, filetype, window_type)
  if not window_info or not window_info.buf then
    return
  end
  local buf = window_info.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  -- 确保缓冲区可修改
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_set_option_value("readonly", false, { buf = buf })

  -- 清空缓冲区
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})

  -- 设置内容
  if type(content) == "table" then
    -- 清理内容表中的换行符
    local cleaned_content = clean_content_table(content)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, cleaned_content)
  else
    local lines = vim.split(content, "\n")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end

  -- 设置文件类型
  if filetype then
    vim.api.nvim_set_option_value("filetype", filetype, { buf = buf })
  end

  -- chat类型窗口保持可修改（内联输入需要），并设置折叠选项
  if window_type == "chat" then
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_set_option_value("readonly", false, { buf = buf })
    vim.api.nvim_set_option_value("modified", false, { buf = buf })
    local win = window_info.win
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_option_value("foldmethod", "marker", { win = win })
      vim.api.nvim_set_option_value("foldmarker", "{{{,}}}", { win = win })
      vim.api.nvim_set_option_value("foldlevel", 0, { win = win })
      vim.api.nvim_set_option_value("foldenable", true, { win = win })
      -- 延迟刷新折叠，确保在 BufRead/BufNew 等自动命令之后执行
      vim.defer_fn(function()
        if vim.api.nvim_win_is_valid(win) then
          pcall(vim.api.nvim_win_call, win, function()
            -- 使用 setlocal 确保窗口本地设置覆盖全局设置
            vim.cmd("setlocal foldmethod=marker")
            vim.cmd("setlocal foldmarker={{{,}}}")
            vim.cmd("setlocal foldlevel=0")
            vim.cmd("setlocal foldenable")
            -- 刷新折叠
            vim.cmd("normal! zMzx")
          end)
        end
      end, 10)
    end
  else
    -- 恢复缓冲区为只读状态
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
    vim.api.nvim_set_option_value("readonly", true, { buf = buf })
  end
  -- 标记为未修改，避免保存警告
  vim.api.nvim_set_option_value("modified", false, { buf = buf })
end

--- 追加窗口内容
--- @param window_info table 窗口信息
--- @param content string 内容
local function append_window_content_by_mode(window_info, content)
  if not window_info or not window_info.buf then
    return
  end

  local buf = window_info.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local lines = vim.split(content, "\n")
  local line_count = vim.api.nvim_buf_line_count(buf)

  vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, lines)
end

--- 聚焦窗口
--- @param window_info table 窗口信息
local function focus_window_by_mode(window_info)
  if not window_info or not window_info.win then
    return
  end
  if vim.api.nvim_win_is_valid(window_info.win) then
    vim.api.nvim_set_current_win(window_info.win)
  end
end

--- 创建窗口
--- @param window_type string 窗口类型 ('chat', 'tree', 'reasoning', 'custom')
--- @param options table 窗口选项
--- @return string|nil 窗口ID
function M.create_window(window_type, options)
  if not state.initialized then
    error("Window manager not initialized")
  end

  window_counter = window_counter + 1
  -- 使用时间戳和计数器生成更唯一的ID，防止模块重载时ID重复
  local timestamp = tostring(os.time())
  local window_id = "win_" .. timestamp .. "_" .. window_counter

  -- 合并选项
  local merged_options = vim.tbl_extend("force", state.config, options or {})

  -- 设置窗口标题
  if not merged_options.title then
    merged_options.title = "NeoAI - " .. window_type
  end

  -- 根据窗口模式创建窗口
  local window_mode = merged_options.window_mode or state.current_mode
  local window_info = create_window_by_mode(window_mode, merged_options)

  if not window_info then
    vim.notify("[NeoAI] 创建窗口失败", vim.log.levels.ERROR)
    return nil
  end

  -- 存储窗口信息
  windows[window_id] = {
    id = window_id,
    type = window_type,
    buf = window_info.buf,
    win = window_info.win,
    options = merged_options,
    created_at = os.time(),
    window_info = window_info,
  }

  -- 设置缓冲区选项
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = window_info.buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = window_info.buf })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = window_info.buf })
  -- chat类型使用markdown filetype以支持原生折叠
  local ft = window_type == "chat" and "markdown" or "neoai_" .. window_type
  vim.api.nvim_set_option_value("filetype", ft, { buf = window_info.buf })
  vim.api.nvim_set_option_value("modifiable", true, { buf = window_info.buf })
  vim.api.nvim_set_option_value("readonly", false, { buf = window_info.buf })

  -- 设置缓冲区名称，使其能在 :ls 命令中显示
  local buffer_name = "neoai://" .. window_type .. "/" .. window_id
  vim.api.nvim_buf_set_name(window_info.buf, buffer_name)

  -- 触发窗口创建事件
  local event_name = "NeoAI:" .. window_type .. "_window_opened"
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_name,
    data = { window_id, window_type, merged_options },
  })

  return window_id
end

--- 关闭窗口
--- @param window_id string 窗口ID
function M.close_window(window_id)
  if not windows[window_id] then
    return
  end

  local window = windows[window_id]

  -- 使用窗口模式管理器关闭窗口
  if window.window_info then
    close_window_by_mode(window.window_info)
  else
    -- 向后兼容：旧方式关闭窗口
    if vim.api.nvim_win_is_valid(window.win) then
      vim.api.nvim_win_close(window.win, true)
    end

    if vim.api.nvim_buf_is_valid(window.buf) then
      vim.api.nvim_buf_delete(window.buf, { force = true })
    end
  end

  -- 触发窗口关闭事件
  local event_name = "NeoAI:" .. window.type .. "_window_closed"
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_name,
    data = { window_id, window.type },
  })

  -- 从存储中移除
  windows[window_id] = nil
end

--- 创建聊天窗口（便捷函数）
--- @param options table 窗口选项
--- @return string|nil 窗口ID
function M.create_chat_window(options)
  return M.create_window("chat", options)
end

--- 创建树窗口（便捷函数）
--- @param options table 窗口选项
--- @return string|nil 窗口ID
function M.create_tree_window(options)
  return M.create_window("tree", options)
end

--- 获取聊天窗口
--- @return table|nil 聊天窗口信息
function M.get_chat_window()
  for id, window in pairs(windows) do
    if window.type == "chat" then
      return M.get_window(id)
    end
  end

  return nil
end

--- 获取树窗口
--- @return table|nil 树窗口信息
function M.get_tree_window()
  for id, window in pairs(windows) do
    if window.type == "tree" then
      return M.get_window(id)
    end
  end

  return nil
end

--- 获取窗口
--- @param window_id string 窗口ID
--- @return table|nil 窗口信息
function M.get_window(window_id)
  return vim.deepcopy(windows[window_id])
end

--- 列出所有窗口
--- @return table 窗口列表
function M.list_windows()
  local result = {}
  for id, window in pairs(windows) do
    table.insert(result, {
      id = id,
      type = window.type,
      created_at = window.created_at,
      valid = vim.api.nvim_win_is_valid(window.win),
    })
  end

  return result
end

--- 聚焦窗口
--- @param window_id string 窗口ID
function M.focus_window(window_id)
  if not windows[window_id] then
    return
  end

  local window = windows[window_id]

  -- 使用窗口模式管理器聚焦窗口
  if window.window_info then
    focus_window_by_mode(window.window_info)
  else
    -- 向后兼容：旧方式聚焦窗口
    if vim.api.nvim_win_is_valid(window.win) then
      vim.api.nvim_set_current_win(window.win)
    end
  end
end

--- 关闭所有窗口
function M.close_all()
  for window_id, _ in pairs(windows) do
    M.close_window(window_id)
  end

  windows = {}
end

--- 获取窗口缓冲区
--- @param window_id string 窗口ID
--- @return number|nil 缓冲区句柄
function M.get_window_buf(window_id)
  if not windows[window_id] then
    return nil
  end

  return windows[window_id].buf
end

--- 获取窗口类型
--- @param window_id string 窗口ID
--- @return number|nil 窗口句柄
function M.get_window_win(window_id)
  if not windows[window_id] then
    return nil
  end

  return windows[window_id].win
end

--- 获取窗口信息
--- @param window_id string 窗口ID
--- @return table|nil 窗口信息
function M.get_window_info(window_id)
  if not windows[window_id] then
    return nil
  end

  return windows[window_id]
end

--- 设置窗口内容
--- @param window_id string 窗口ID
--- @param content string|table 内容
function M.set_window_content(window_id, content)
  if not windows[window_id] then
    return
  end

  local window = windows[window_id]

  -- 使用窗口模式管理器设置内容
  if window.window_info then
    local ft = window.type == "chat" and "markdown" or "neoai_" .. window.type
    set_window_content_by_mode(window.window_info, content, ft, window.type)
  else
    -- 向后兼容：旧方式设置内容
    local buf = window.buf
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    -- 确保缓冲区可修改
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_set_option_value("readonly", false, { buf = buf })

    -- 清空缓冲区
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})

    -- 设置内容
    if type(content) == "table" then
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
    else
      local lines = vim.split(content, "\n")
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    end
  end

  -- 根据窗口类型设置缓冲区选项
  local window_type = window.type
  local buf = window.window_info and window.window_info.buf or window.buf
  local win = window.window_info and window.window_info.win or window.win

  if window_type == "tree" or window_type == "reasoning" then
    -- 树窗口和思考窗口设置为只读
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
    vim.api.nvim_set_option_value("readonly", true, { buf = buf })
    -- 清除修改标志，避免退出时出现 "No write since last change" 错误
    vim.api.nvim_set_option_value("modified", false, { buf = buf })
  elseif window_type == "chat" then
    -- 聊天窗口保持可修改（内联输入需要）
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_set_option_value("readonly", false, { buf = buf })
    vim.api.nvim_set_option_value("modified", false, { buf = buf })
    -- 确保折叠选项在每次设置内容后都重新生效
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_option_value("foldmethod", "marker", { win = win })
      vim.api.nvim_set_option_value("foldmarker", "{{{,}}}", { win = win })
      vim.api.nvim_set_option_value("foldlevel", 0, { win = win })
      vim.api.nvim_set_option_value("foldenable", true, { win = win })
      -- 延迟刷新折叠，确保在 BufRead/BufNew 等自动命令之后执行
      vim.defer_fn(function()
        if vim.api.nvim_win_is_valid(win) then
          pcall(vim.api.nvim_win_call, win, function()
            vim.cmd("setlocal foldmethod=marker")
            vim.cmd("setlocal foldmarker={{{,}}}")
            vim.cmd("setlocal foldlevel=0")
            vim.cmd("setlocal foldenable")
            vim.cmd("normal! zMzx")
          end)
        end
      end, 10)
    end
  else
    -- 其他窗口保持可修改
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_set_option_value("readonly", false, { buf = buf })
  end
end

--- 追加窗口内容
--- @param window_id string 窗口ID
--- @param content string 内容
function M.append_window_content(window_id, content)
  if not windows[window_id] then
    return
  end

  local window = windows[window_id]

  -- 使用窗口模式管理器追加内容
  if window.window_info then
    append_window_content_by_mode(window.window_info, content)
  else
    -- 向后兼容：旧方式追加内容
    local buf = window.buf
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end

    local lines = vim.split(content, "\n")
    local line_count = vim.api.nvim_buf_line_count(buf)

    vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, lines)
  end
end

--- 更新窗口选项
--- @param window_id string 窗口ID
--- @param options table 新选项
function M.update_window_options(window_id, options)
  if not windows[window_id] then
    return
  end

  local window = windows[window_id]
  if not vim.api.nvim_win_is_valid(window.win) then
    return
  end

  -- 更新配置
  window.options = vim.tbl_extend("force", window.options, options or {})

  -- 应用新配置
  vim.api.nvim_win_set_config(window.win, window.options)
end

--- 获取窗口类型
--- @param window_id string 窗口ID
--- @return string|nil 窗口类型
function M.get_window_type(window_id)
  if not windows[window_id] then
    return nil
  end

  return windows[window_id].type
end

--- 查找特定类型的窗口
--- @param window_type string 窗口类型
--- @return table 窗口ID列表
function M.find_windows_by_type(window_type)
  local result = {}
  for id, window in pairs(windows) do
    if window.type == window_type then
      table.insert(result, id)
    end
  end

  return result
end

--- 更新配置
--- @param new_config table 新配置
function M.update_config(new_config)
  if not state.initialized then
    return
  end

  state.config = vim.tbl_extend("force", state.config, new_config or {})
end

--- 检查窗口是否打开
--- @param window_id string 窗口ID
--- @return boolean 窗口是否打开
function M.is_window_open(window_id)
  if not window_id then
    return false
  end

  local window = windows[window_id]
  if not window then
    return false
  end

  -- 检查窗口句柄是否有效
  if window.win and vim.api.nvim_win_is_valid(window.win) then
    return true
  end

  return false
end

--- 测试窗口创建
--- @return boolean 测试是否成功
function M.test_window_creation()
  if not state.initialized then
    return false
  end

  -- 尝试创建一个测试窗口
  local test_window_id = M.create_window("test", {
    title = "测试窗口",
    width = 40,
    height = 20,
    border = "rounded",
  })

  if test_window_id then
    -- 成功创建，关闭测试窗口
    M.close_window(test_window_id)
    return true
  end

  return false
end

--- 切换窗口模式
--- @param mode string|nil 目标模式（如果为nil则循环切换）
function M.toggle_mode(mode)
  if not state.initialized then
    return
  end
  if mode then
    -- 切换到指定模式
    if vim.tbl_contains(state.available_modes, mode) then
      state.current_mode = mode
      vim.notify("[NeoAI] 窗口模式切换为: " .. mode, vim.log.levels.INFO)
    else
      vim.notify("[NeoAI] 无效的窗口模式: " .. mode, vim.log.levels.ERROR)
    end
  else
    -- 循环切换模式
    local current_index = 1
    for i, available_mode in ipairs(state.available_modes) do
      if available_mode == state.current_mode then
        current_index = i
        break
      end
    end
    local next_index = (current_index % #state.available_modes) + 1
    state.current_mode = state.available_modes[next_index]
    vim.notify("[NeoAI] 窗口模式切换为: " .. state.current_mode, vim.log.levels.INFO)
  end
end

--- 获取当前窗口模式
--- @return string 当前模式
function M.get_current_mode()
  return state.current_mode
end

--- 设置窗口模式
--- @param mode string 窗口模式
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

--- 检查窗口是否有效
--- @param window_info table 窗口信息
--- @return boolean 是否有效
function M.is_window_valid(window_info)
  if not window_info then
    return false
  end
  local win_valid = window_info.win and vim.api.nvim_win_is_valid(window_info.win)
  local buf_valid = window_info.buf and vim.api.nvim_buf_is_valid(window_info.buf)
  return win_valid and buf_valid
end

--- 安全截断字符串，避免截断中文字符
--- @param str string 要截断的字符串
--- @param max_len number 最大长度
--- @return string 截断后的字符串
local function safe_truncate(str, max_len)
  if #str <= max_len then
    return str
  end
  
  -- 清理字符串中的控制字符和二进制数据
  local cleaned_str = str:gsub("[%c%z]", ""):gsub("%b<>", "")
  
  -- 如果清理后的字符串更短，使用清理后的版本
  if #cleaned_str < #str then
    str = cleaned_str
    if #str <= max_len then
      return str
    end
  end
  
  -- 尝试找到合适的截断点
  local truncated = str:sub(1, max_len)
  
  -- 检查最后一个字符是否是中文字符的一部分
  -- 中文字符在UTF-8中占用3个字节，如果截断位置在字符中间，会显示乱码
  local last_char = truncated:sub(-1)
  local byte = last_char:byte()
  
  -- 如果最后一个字节是UTF-8多字节字符的一部分（0x80以上），则向前调整到完整的字符边界
  if byte and byte >= 0x80 then
    -- 向前查找完整的字符边界
    for i = max_len, 1, -1 do
      local prev_byte = truncated:sub(i, i):byte()
      -- 检查是否是UTF-8字符的起始字节（0x00-0x7F 或 0xC0-0xFD）
      if prev_byte and (prev_byte < 0x80 or prev_byte >= 0xC0) then
        -- 找到字符边界，截断到这里
        if i < max_len then
          truncated = truncated:sub(1, i)
        end
        break
      end
    end
  end
  
  -- 移除可能残留的二进制标记
  truncated = truncated:gsub("%b<>", "")
  
  return truncated
end

--- 渲染树状图（通用函数）
--- @param tree_data table 树数据
--- @param tree_state table 树状态
--- @param load_data_func function 加载数据的函数
--- @param window_width number|nil 窗口宽度
--- @return table 渲染后的内容
function M.render_tree(tree_data, tree_state, load_data_func, window_width)
  if tree_data then
    tree_state.tree_data = tree_data
  end
  if #tree_state.tree_data == 0 and load_data_func then
    load_data_func(nil)
  end
  local content = {}
  table.insert(content, "=== NeoAI 会话树 ===")
  table.insert(content, "")
  if #tree_state.tree_data == 0 then
    table.insert(content, "暂无会话")
    table.insert(content, "按 N 创建新会话")
  else
    local root_count = #tree_state.tree_data
    for i, root_node in ipairs(tree_state.tree_data) do
      M._render_tree_node(content, root_node, 0, i == root_count, "", tree_state, window_width, true)
    end
  end
  table.insert(content, "")
  table.insert(content, "---")
  table.insert(content, "使用方向键导航，Enter 选择，n/N 新建节点，d 删除")
  return content
end

--- 渲染树节点（内部使用）
--- @param content table 内容表
--- @param node table 节点
--- @param depth number 深度
--- @param is_last boolean 是否是父节点的最后一个子节点
--- @param parent_prefix string 父节点的前缀
--- @param tree_state table 树状态
--- @param window_width number|nil 窗口宽度
--- @param is_root boolean 是否是根节点
function M._render_tree_node(content, node, depth, is_last, parent_prefix, tree_state, window_width, is_root)
  if not node then return end

  local current_prefix = parent_prefix or ""

  -- 构建当前行的前缀和内容
  local line
  if is_root then
    -- 根节点：使用 └──/├── 前缀
    local prefix = is_last and "└──" or "├──"
    local icon = node.is_virtual and "📂 " or ""
    line = prefix .. icon .. (node.name or "未命名")
    if node.round_count and node.round_count > 0 then
      line = line .. "  (" .. node.round_count .. "轮)"
    end
  elseif node.is_virtual then
    -- 虚拟节点（分支）：不显示连接线，直接以图标开头
    line = current_prefix .. "📂 " .. (node.name or "分支")
    if node.round_count and node.round_count > 0 then
      line = line .. "  (" .. node.round_count .. "轮)"
    end
  else
    -- 普通节点或轮次节点：使用 ├───/└─── 前缀
    local prefix = is_last and "└───" or "├───"
    line = current_prefix .. prefix .. (node.name or "未命名")
  end

  -- 清理显示文本
  line = line:gsub("%b<>", " "):gsub("[%c%z]", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if line == "" then line = "未命名" end

  if window_width and window_width > 0 and #line > window_width then
    local effective_prefix = node.is_virtual and current_prefix or (is_root and (is_last and "└──" or "├──") or current_prefix .. (is_last and "└───" or "├───"))
    local max_text_len = window_width - #effective_prefix - 3
    if max_text_len > 0 then
      line = effective_prefix .. safe_truncate(line:sub(#effective_prefix + 1), max_text_len) .. "..."
    end
  end

  table.insert(content, line)

  -- 渲染子节点
  if tree_state.expanded_nodes and tree_state.expanded_nodes[node.id] and node.children and #node.children > 0 then
    local child_count = #node.children

    -- 计算子节点的 parent_prefix
    local child_parent_prefix
    if is_root then
      -- 根节点的子节点：缩进一级
      child_parent_prefix = is_last and "    " or "│   "
    elseif node.is_virtual then
      -- 虚拟节点的子节点：在虚拟节点自身前缀基础上再缩进一级
      -- 虚拟节点不显示连接线，所以子节点需要额外缩进
      if is_last then
        child_parent_prefix = current_prefix .. "    "
      else
        child_parent_prefix = current_prefix .. "│   "
      end
    else
      -- 普通节点的子节点：在父节点前缀基础上再缩进一级
      if is_last then
        child_parent_prefix = current_prefix .. "    "
      else
        child_parent_prefix = current_prefix .. "│   "
      end
    end

    for i, child in ipairs(node.children) do
      local child_is_last = (i == child_count)
      M._render_tree_node(content, child, depth + 1, child_is_last, child_parent_prefix, tree_state, window_width, false)
    end
  end
end

--- 根据节点ID获取节点名称（内部使用）
--- @param node_id string 节点ID
--- @param tree_data table 树数据
--- @return string|nil 节点名称
function M._get_node_name_by_id(node_id, tree_data)
  if not node_id or not tree_data then
    return nil
  end

  local function search_node(nodes)
    for _, node in ipairs(nodes) do
      if node.id == node_id then
        return node.preview or node.name
      end

      -- 递归搜索子节点
      if node.children then
        local result = search_node(node.children)
        if result then
          return result
        end
      end
    end

    return nil
  end

  return search_node(tree_data)
end

return M
