local M = {}

-- 辅助函数：设置占位文本高亮
local function set_placeholder_highlight(buf_id)
  if not buf_id or not vim.api.nvim_buf_is_valid(buf_id) then
    return
  end

  -- 清除之前的高亮
  local ns_id = vim.api.nvim_create_namespace("NeoAI_VirtualInput")
  vim.api.nvim_buf_clear_namespace(buf_id, ns_id, 0, -1)

  -- 设置占位文本高亮
  vim.api.nvim_buf_set_extmark(buf_id, ns_id, 0, 0, {
    end_line = 0,
    end_col = -1,
    hl_group = "Comment",
    priority = 50,
  })
end

-- 模块状态
local state = {
  initialized = false,
  config = nil,
  active = false,
  buffer_id = nil,
  window_id = nil,
  parent_window_id = nil,
  content = "",
  placeholder = "输入消息...",
  cursor_position = 0,
  on_submit = nil,
  on_cancel = nil,
  on_change = nil,
}

--- 初始化虚拟输入组件
--- @param config table 配置
function M.initialize(config)
  if state.initialized then
    return
  end

  state.config = config or {}
  state.initialized = true
end

--- 打开虚拟输入框
--- @param parent_window_id number 父窗口ID
--- @param options table 选项
--- @return boolean 是否成功
function M.open(parent_window_id, options)
  if not state.initialized then
    vim.notify("虚拟输入组件未初始化，请先调用 initialize()", vim.log.levels.ERROR)
    return false
  end

  if state.active then
    M.close("force")
  end

  -- 检查父窗口是否有效
  if not parent_window_id then
    vim.notify("无效的父窗口ID: 参数为空", vim.log.levels.ERROR)
    return false
  end

  local parent_type = type(parent_window_id)
  if parent_type ~= "number" then
    vim.notify(
      string.format("无效的父窗口ID类型: 期望数字，实际为 %s", parent_type),
      vim.log.levels.ERROR
    )
    return false
  end

  local ok, win_exists = pcall(function()
    return vim.api.nvim_win_is_valid(parent_window_id)
  end)

  if not ok or not win_exists then
    vim.notify(string.format("父窗口不存在或已关闭 (窗口ID: %d)", parent_window_id), vim.log.levels.ERROR)
    return false
  end

  -- 保存状态
  state.parent_window_id = parent_window_id
  state.content = options.content or ""
  state.placeholder = options.placeholder or "输入消息..."
  state.on_submit = options.on_submit
  state.on_cancel = options.on_cancel
  state.on_change = options.on_change
  state.cursor_position = #state.content

  -- 创建虚拟输入缓冲区
  state.buffer_id = vim.api.nvim_create_buf(false, true)
  if not state.buffer_id or state.buffer_id == 0 then
    vim.notify("创建缓冲区失败", vim.log.levels.ERROR)
    return false
  end

  -- 设置缓冲区选项
  vim.bo[state.buffer_id].buftype = "prompt"
  vim.bo[state.buffer_id].bufhidden = "wipe"
  vim.bo[state.buffer_id].swapfile = false
  vim.bo[state.buffer_id].filetype = "markdown"

  -- 设置缓冲区内容
  if state.content == "" then
    vim.api.nvim_buf_set_lines(state.buffer_id, 0, -1, false, { state.placeholder })
    set_placeholder_highlight(state.buffer_id)
  else
    vim.api.nvim_buf_set_lines(state.buffer_id, 0, -1, false, { state.content })
  end

  -- 计算输入框位置（在父窗口底部）
  local parent_height = vim.api.nvim_win_get_height(parent_window_id)
  local parent_width = vim.api.nvim_win_get_width(parent_window_id)
  local input_height = 3
  local border_width = 2

  -- 确保窗口尺寸有效
  local win_width = math.max(20, parent_width - 4)
  local win_row = math.max(0, parent_height - input_height - 1)

  -- 创建输入窗口
  state.window_id = vim.api.nvim_open_win(state.buffer_id, false, {
    relative = "win",
    win = parent_window_id,
    width = win_width,
    height = input_height,
    row = win_row,
    col = border_width,
    style = "minimal",
    border = "rounded",
    focusable = true,
  })

  if not state.window_id or state.window_id == 0 then
    vim.api.nvim_buf_delete(state.buffer_id, { force = true })
    state.buffer_id = nil
    vim.notify("创建窗口失败", vim.log.levels.ERROR)
    return false
  end

  -- 设置窗口选项
  vim.wo[state.window_id].winhl = "Normal:NormalFloat"
  vim.wo[state.window_id].wrap = true

  -- 设置按键映射
  M._setup_keymaps()

  -- 设置光标位置
  if state.content == "" and state.placeholder ~= "" then
    vim.api.nvim_win_set_cursor(state.window_id, { 1, 0 })
  else
    vim.api.nvim_win_set_cursor(state.window_id, { 1, state.cursor_position })
  end

  -- 激活状态
  state.active = true

  -- 进入插入模式
  vim.api.nvim_set_current_win(state.window_id)
  vim.cmd("startinsert!")

  return true
end

--- 关闭虚拟输入框
--- @param mode string|nil 关闭模式："submit"（提交发送）、"cancel"（取消）、nil（普通关闭）
function M.close(mode)
  if not state.active then
    return
  end

  -- 保存内容
  if state.buffer_id and vim.api.nvim_buf_is_valid(state.buffer_id) then
    local lines = vim.api.nvim_buf_get_lines(state.buffer_id, 0, -1, false)
    if #lines > 0 then
      state.content = lines[1]
      if state.content == state.placeholder then
        state.content = ""
      end
    end
  end

  -- 根据关闭模式处理内容
  if mode == "submit" then
    if state.on_submit and type(state.on_submit) == "function" then
      state.on_submit(state.content)
    end
  elseif mode == "cancel" then
    if state.on_cancel and type(state.on_cancel) == "function" then
      state.on_cancel()
    end
  elseif mode == "force" then
    -- 强制关闭，不调用回调
  end

  -- 关闭窗口
  if state.window_id and vim.api.nvim_win_is_valid(state.window_id) then
    vim.api.nvim_win_close(state.window_id, true)
  end

  -- 删除缓冲区
  if state.buffer_id and vim.api.nvim_buf_is_valid(state.buffer_id) then
    vim.api.nvim_buf_delete(state.buffer_id, { force = true })
  end

  -- 重置状态
  state.active = false
  state.buffer_id = nil
  state.window_id = nil
  state.parent_window_id = nil

  -- 返回焦点到父窗口
  if state.parent_window_id and vim.api.nvim_win_is_valid(state.parent_window_id) then
    vim.api.nvim_set_current_win(state.parent_window_id)
  end
end

--- 提交输入内容
function M.submit()
  if not state.active then
    return
  end
  M.close("submit")
end

--- 回到正常模式（不关闭输入框）
function M.enter_normal_mode()
  if not state.active then
    return
  end

  -- 保存当前内容
  if state.buffer_id and vim.api.nvim_buf_is_valid(state.buffer_id) then
    local lines = vim.api.nvim_buf_get_lines(state.buffer_id, 0, -1, false)
    if #lines > 0 then
      state.content = lines[1]
      if state.content == state.placeholder then
        state.content = ""
      end
    end
  end

  -- 退出插入模式，进入普通模式
  vim.cmd("stopinsert")

  -- 通知内容变化（如果有回调）
  if state.on_change and type(state.on_change) == "function" then
    state.on_change(state.content)
  end
end

--- 取消输入
function M.cancel()
  if not state.active then
    return
  end
  M.close("cancel")
end

--- 获取当前内容
--- @return string 输入内容
function M.get_content()
  if state.active and state.buffer_id and vim.api.nvim_buf_is_valid(state.buffer_id) then
    local lines = vim.api.nvim_buf_get_lines(state.buffer_id, 0, -1, false)
    if #lines > 0 then
      local content = lines[1]
      if content == state.placeholder then
        return ""
      end
      return content
    end
  end
  return state.content
end

--- 设置内容
--- @param content string 内容
function M.set_content(content)
  state.content = content or ""

  if state.active and state.buffer_id and vim.api.nvim_buf_is_valid(state.buffer_id) then
    if state.content == "" then
      vim.api.nvim_buf_set_lines(state.buffer_id, 0, -1, false, { state.placeholder })
      set_placeholder_highlight(state.buffer_id)
    else
      vim.api.nvim_buf_set_lines(state.buffer_id, 0, -1, false, { state.content })
    end
  end
end

--- 设置占位文本
--- @param placeholder string 占位文本
function M.set_placeholder(placeholder)
  state.placeholder = placeholder or "输入消息..."
end

--- 是否激活
--- @return boolean 是否激活
function M.is_active()
  return state.active
end

--- 获取缓冲区ID
--- @return number|nil 缓冲区ID
function M.get_buffer_id()
  return state.buffer_id
end

--- 获取窗口ID
--- @return number|nil 窗口ID
function M.get_window_id()
  return state.window_id
end

--- 获取虚拟输入框键位配置
--- @return table 键位配置
function M._get_keymaps()
  local default_keymaps = {
    normal_mode = "<CR>", -- 发送消息（Enter键）
    submit = "<C-s>", -- 发送消息（Ctrl+s）
    cancel = "<Esc>", -- 取消输入并关闭输入框
    clear = "<C-u>", -- 清空输入
  }

  -- 从配置中获取键位
  if state.config and state.config.keymaps and state.config.keymaps.virtual_input then
    local config_keymaps = state.config.keymaps.virtual_input
    local result = {}

    -- 映射配置键位到内部键位名称
    for internal_name, default_key in pairs(default_keymaps) do
      if config_keymaps[internal_name] and config_keymaps[internal_name].key then
        result[internal_name] = config_keymaps[internal_name].key
      else
        result[internal_name] = default_key
      end
    end

    return result
  end

  return default_keymaps
end

--- 设置按键映射（内部使用）
function M._setup_keymaps()
  if not state.buffer_id or not vim.api.nvim_buf_is_valid(state.buffer_id) then
    return
  end

  -- 清除现有映射
  local existing_maps = vim.api.nvim_buf_get_keymap(state.buffer_id, "i")
  for _, map in ipairs(existing_maps) do
    vim.api.nvim_buf_del_keymap(state.buffer_id, "i", map.lhs)
  end

  local existing_nmaps = vim.api.nvim_buf_get_keymap(state.buffer_id, "n")
  for _, map in ipairs(existing_nmaps) do
    vim.api.nvim_buf_del_keymap(state.buffer_id, "n", map.lhs)
  end

  -- 获取键位配置
  local keymaps = M._get_keymaps()

  -- 尝试从键位配置管理器获取虚拟输入框的特定配置
  local ok, keymap_manager = pcall(require, "NeoAI.core.config.keymap_manager")
  if ok and keymap_manager then
    local virtual_input_keymaps = keymap_manager.get_context_keymaps("virtual_input")
    if virtual_input_keymaps then
      for internal_name, default_key in pairs(keymaps) do
        if virtual_input_keymaps[internal_name] and virtual_input_keymaps[internal_name].key then
          keymaps[internal_name] = virtual_input_keymaps[internal_name].key
        end
      end
    end
  end

  -- 发送消息（Enter键）
  if keymaps.normal_mode then
    vim.api.nvim_buf_set_keymap(
      state.buffer_id,
      "i",
      keymaps.normal_mode,
      "<Cmd>lua require('NeoAI.ui.components.virtual_input').submit()<CR>",
      { noremap = true, silent = true, desc = "发送消息" }
    )

    vim.api.nvim_buf_set_keymap(
      state.buffer_id,
      "n",
      keymaps.normal_mode,
      "<Cmd>lua require('NeoAI.ui.components.virtual_input').submit()<CR>",
      { noremap = true, silent = true, desc = "发送消息" }
    )
  end

  -- 发送消息（Ctrl+s）
  if keymaps.submit then
    vim.api.nvim_buf_set_keymap(
      state.buffer_id,
      "i",
      keymaps.submit,
      "<Cmd>lua require('NeoAI.ui.components.virtual_input').submit()<CR>",
      { noremap = true, silent = true, desc = "发送消息" }
    )
  end

  -- 退出插入模式（ESC键）- 只退出插入模式，不关闭输入框
  vim.api.nvim_buf_set_keymap(
    state.buffer_id,
    "i",
    "<Esc>",
    "<Cmd>lua require('NeoAI.ui.components.virtual_input').enter_normal_mode()<CR>",
    { noremap = true, silent = true, desc = "退出插入模式" }
  )

  vim.api.nvim_buf_set_keymap(
    state.buffer_id,
    "n",
    "<Esc>",
    "<Cmd>lua require('NeoAI.ui.components.virtual_input').enter_normal_mode()<CR>",
    { noremap = true, silent = true, desc = "退出插入模式" }
  )

  -- 取消输入（Ctrl+c）
  if keymaps.cancel and keymaps.cancel ~= "<Esc>" then
    vim.api.nvim_buf_set_keymap(
      state.buffer_id,
      "i",
      keymaps.cancel,
      "<Cmd>lua require('NeoAI.ui.components.virtual_input').cancel()<CR>",
      { noremap = true, silent = true, desc = "取消输入并关闭输入框" }
    )
  end

  -- 清空输入（Ctrl+u）
  if keymaps.clear then
    vim.api.nvim_buf_set_keymap(
      state.buffer_id,
      "i",
      keymaps.clear,
      "<Cmd>lua require('NeoAI.ui.components.virtual_input').set_content('')<CR>",
      { noremap = true, silent = true, desc = "清空输入" }
    )
  end

  -- 普通模式下重新进入插入模式
  vim.api.nvim_buf_set_keymap(
    state.buffer_id,
    "n",
    "i",
    "<Cmd>startinsert<CR>",
    { noremap = true, silent = true, desc = "进入插入模式" }
  )

  vim.api.nvim_buf_set_keymap(
    state.buffer_id,
    "n",
    "a",
    "<Cmd>startinsert<CR>",
    { noremap = true, silent = true, desc = "进入插入模式" }
  )

  -- 内容变化时触发回调
  local attach_id = vim.api.nvim_buf_attach(state.buffer_id, false, {
    on_lines = function(_, _, _, _, _, _, _)
      if state.on_change and type(state.on_change) == "function" then
        local content = M.get_content()
        vim.defer_fn(function()
          state.on_change(content)
        end, 0)
      end
    end,
    on_detach = function()
      -- 清理回调
      state._attach_id = nil
    end,
  })

  -- 保存attach_id以便后续清理
  state._attach_id = attach_id
end

return M
