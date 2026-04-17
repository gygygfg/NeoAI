local M = {}

-- 导入窗口模式管理器
local window_mode_manager = require("NeoAI.ui.window.window_mode_manager")

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
  }
}

--- 初始化窗口管理器
--- @param config table 配置
function M.initialize(config)
  if state.initialized then
    return
  end

  state.config = vim.tbl_extend("force", state.default_options, config or {})

  state.initialized = true
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
  local window_id = "win_" .. window_counter

  -- 合并选项
  local merged_options = vim.tbl_extend("force", state.config, options or {})

  -- 设置窗口标题
  if not merged_options.title then
    merged_options.title = "NeoAI - " .. window_type
  end

  -- 根据窗口模式创建窗口
  local window_mode = merged_options.window_mode or "float"
  local window_info = window_mode_manager.create_window_by_mode(window_mode, merged_options)

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
  vim.api.nvim_buf_set_option(window_info.buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(window_info.buf, "swapfile", false)
  vim.api.nvim_buf_set_option(window_info.buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(window_info.buf, "filetype", "neoai_" .. window_type)
  vim.api.nvim_buf_set_option(window_info.buf, "modifiable", true)
  vim.api.nvim_buf_set_option(window_info.buf, "readonly", false)

  -- 设置缓冲区名称，使其能在 :ls 命令中显示
  local buffer_name = "neoai://" .. window_type .. "/" .. window_id
  vim.api.nvim_buf_set_name(window_info.buf, buffer_name)

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
    window_mode_manager.close_window(window.window_info)
  else
    -- 向后兼容：旧方式关闭窗口
    if vim.api.nvim_win_is_valid(window.win) then
      vim.api.nvim_win_close(window.win, true)
    end

    if vim.api.nvim_buf_is_valid(window.buf) then
      vim.api.nvim_buf_delete(window.buf, { force = true })
    end
  end

  -- 从存储中移除
  windows[window_id] = nil
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
    window_mode_manager.focus_window(window.window_info)
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

--- 获取窗口句柄
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
    window_mode_manager.set_window_content(window.window_info, content, "neoai_" .. window.type)
  else
    -- 向后兼容：旧方式设置内容
    local buf = window.buf
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end

    -- 确保缓冲区可修改
    vim.api.nvim_buf_set_option(buf, "modifiable", true)
    vim.api.nvim_buf_set_option(buf, "readonly", false)

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

  if window_type == "tree" or window_type == "reasoning" then
    -- 树窗口和思考窗口设置为只读
    vim.api.nvim_buf_set_option(buf, "modifiable", false)
    vim.api.nvim_buf_set_option(buf, "readonly", true)
  else
    -- 其他窗口保持可修改
    vim.api.nvim_buf_set_option(buf, "modifiable", true)
    vim.api.nvim_buf_set_option(buf, "readonly", false)
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
    window_mode_manager.append_window_content(window.window_info, content)
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



return M

