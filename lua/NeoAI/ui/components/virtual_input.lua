local M = {}

-- 辅助函数：设置虚拟文本占位符
local function set_virtual_placeholder(buf_id, placeholder, show)
  if not buf_id or not vim.api.nvim_buf_is_valid(buf_id) then
    return
  end

  -- 使用专门的命名空间用于虚拟文本
  local ns_id = vim.api.nvim_create_namespace("NeoAI_VirtualInput_Placeholder")

  -- 清除之前的虚拟文本
  vim.api.nvim_buf_clear_namespace(buf_id, ns_id, 0, -1)

  if show then
    -- 获取缓冲区内容
    local lines = vim.api.nvim_buf_get_lines(buf_id, 0, 1, false)
    local first_line = lines and lines[1] or ""

    -- 只在缓冲区为空时显示占位符
    if first_line == "" then
      -- 设置虚拟文本占位符
      vim.api.nvim_buf_set_extmark(buf_id, ns_id, 0, 0, {
        virt_text = { { placeholder, "Comment" } },
        virt_text_pos = "overlay",
        hl_mode = "combine",
        priority = 100, -- 高优先级，确保显示在最上层
      })
    end
  end
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
  resize_listener_id = nil, -- 窗口大小变化监听器ID
  _updating_buffer = false, -- 防抖标志，防止递归调用
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
  vim.bo[state.buffer_id].buftype = "nofile" -- 不关联文件
  vim.bo[state.buffer_id].bufhidden = "wipe"
  vim.bo[state.buffer_id].swapfile = false
  vim.bo[state.buffer_id].filetype = "markdown"
  vim.bo[state.buffer_id].buflisted = false -- 不在:ls中显示
  vim.bo[state.buffer_id].modified = false -- 标记为未修改

  -- 不再设置提示符，因为不使用 prompt 缓冲区
  -- if vim.fn.exists('*prompt_setprompt') == 1 then
  --   vim.fn.prompt_setprompt(state.buffer_id, "> ")
  -- end

  -- 设置缓冲区内容
  vim.api.nvim_buf_set_lines(state.buffer_id, 0, -1, false, { state.content })

  -- 根据内容是否为空来显示占位符
  if state.content == "" then
    set_virtual_placeholder(state.buffer_id, state.placeholder, true)
  else
    set_virtual_placeholder(state.buffer_id, state.placeholder, false)
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

  -- 创建窗口大小变化监听器
  M._setup_window_resize_listener(parent_window_id)

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

  -- 只允许force模式关闭输入框
  if mode ~= "force" then
    -- 对于submit和cancel模式，只执行回调但不关闭输入框
    if mode == "submit" then
      if state.on_submit and type(state.on_submit) == "function" then
        state.on_submit(state.content)
      end
    elseif mode == "cancel" then
      if state.on_cancel and type(state.on_cancel) == "function" then
        state.on_cancel()
      end
    end
    return
  end

  -- 保存内容
  if state.buffer_id and vim.api.nvim_buf_is_valid(state.buffer_id) then
    local lines = vim.api.nvim_buf_get_lines(state.buffer_id, 0, -1, false)
    if #lines > 0 then
      state.content = lines[1]
    end
  end

  -- 关闭窗口
  if state.window_id and vim.api.nvim_win_is_valid(state.window_id) then
    vim.api.nvim_win_close(state.window_id, true)
  end

  -- 删除缓冲区
  if state.buffer_id and vim.api.nvim_buf_is_valid(state.buffer_id) then
    vim.api.nvim_buf_delete(state.buffer_id, { force = true })
  end

  -- 清理窗口大小变化监听器
  M._cleanup_window_resize_listener()

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

--- 提交输入内容（不清空内容，不关闭输入框）
function M.submit()
  if not state.active then
    return
  end

  -- 使用 get_content() 获取当前内容（这会正确处理占位符）
  state.content = M.get_content()

  -- 调用提交回调
  if state.on_submit and type(state.on_submit) == "function" then
    state.on_submit(state.content)
  end

  -- 清空输入框内容
  M.set_content("")

  -- 保持输入框打开
  -- print("📝 消息已发送，输入框已清空")
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
    end
  end

  -- 退出插入模式，进入普通模式
  vim.cmd("stopinsert")

  -- 通知内容变化（如果有回调）
  if state.on_change and type(state.on_change) == "function" then
    state.on_change(state.content)
  end
end

--- 取消输入（不清空内容，不关闭输入框）
function M.cancel()
  if not state.active then
    return
  end

  -- 只调用取消回调，不关闭输入框
  if state.on_cancel and type(state.on_cancel) == "function" then
    state.on_cancel()
  end

  -- 不清空内容，保持输入框打开
  print("📝 输入框保持打开状态（按ESC退出插入模式）")
end

--- 获取当前内容
--- @return string 输入内容
function M.get_content()
  if state.active and state.buffer_id and vim.api.nvim_buf_is_valid(state.buffer_id) then
    -- 获取缓冲区内容
    local lines = vim.api.nvim_buf_get_lines(state.buffer_id, 0, -1, false)
    if #lines > 0 then
      -- 直接返回缓冲区内容，占位符不会出现在这里
      return lines[1]
    end
  end

  -- 返回状态中存储的内容
  return state.content or ""
end

--- 设置内容
--- @param content string 内容
function M.set_content(content)
  state.content = content or ""

  if state.active and state.buffer_id and vim.api.nvim_buf_is_valid(state.buffer_id) then
    -- 设置防抖标志
    state._updating_buffer = true

    -- 设置缓冲区内容
    vim.api.nvim_buf_set_lines(state.buffer_id, 0, -1, false, { state.content })

    -- 根据内容是否为空来显示或隐藏占位符
    if state.content == "" then
      set_virtual_placeholder(state.buffer_id, state.placeholder, true)
    else
      set_virtual_placeholder(state.buffer_id, state.placeholder, false)
    end

    -- 清除防抖标志
    vim.defer_fn(function()
      state._updating_buffer = false
    end, 10)
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
  if state.config and state.config.keymaps and state.config.keymaps.chat then
    local chat_keymaps = state.config.keymaps.chat
    local result = {}

    -- 从 chat 配置中获取发送按键
    if chat_keymaps.send then
      if chat_keymaps.send.insert then
        result.normal_mode = chat_keymaps.send.insert.key
      end
      if chat_keymaps.send.normal then
        result.submit = chat_keymaps.send.normal.key
      end
    end

    -- 获取其他按键
    if chat_keymaps.cancel then
      result.cancel = chat_keymaps.cancel.key
    end
    if chat_keymaps.clear then
      result.clear = chat_keymaps.clear.key
    end

    -- 确保所有键位都有值
    for internal_name, default_key in pairs(default_keymaps) do
      if not result[internal_name] then
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
      { noremap = true, silent = true, desc = "取消输入（不清空内容）" }
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
    on_lines = function(_, _, first_line, last_line, _, _, _)
      -- 使用防抖机制避免递归调用
      if state._updating_buffer then
        return
      end

      state._updating_buffer = true

      -- 获取当前缓冲区内容
      local lines = vim.api.nvim_buf_get_lines(state.buffer_id, 0, -1, false)
      if #lines > 0 then
        local current_content = lines[1]

        -- 更新 state.content
        state.content = current_content

        -- 根据内容是否为空来更新虚拟占位符
        if current_content == "" then
          set_virtual_placeholder(state.buffer_id, state.placeholder, true)
        else
          set_virtual_placeholder(state.buffer_id, state.placeholder, false)
        end
      end

      if state.on_change and type(state.on_change) == "function" then
        vim.defer_fn(function()
          state.on_change(state.content)
        end, 0)
      end

      state._updating_buffer = false
    end,
    on_detach = function()
      -- 清理回调
      state._attach_id = nil
    end,
  })

  -- 保存attach_id以便后续清理
  state._attach_id = attach_id
end

--- 设置窗口大小变化监听器（内部函数）
--- @param parent_window_id number 父窗口ID
function M._setup_window_resize_listener(parent_window_id)
  if not parent_window_id or not vim.api.nvim_win_is_valid(parent_window_id) then
    return
  end

  -- 清理现有的监听器
  if state.resize_listener_id then
    pcall(vim.api.nvim_del_autocmd, state.resize_listener_id)
    state.resize_listener_id = nil
  end

  -- 创建窗口大小变化监听器
  state.resize_listener_id = vim.api.nvim_create_autocmd("WinScrolled", {
    callback = function(args)
      -- 检查是否是父窗口的大小变化
      if args.win == parent_window_id then
        -- 延迟调整位置，避免频繁更新
        vim.defer_fn(function()
          M._adjust_position()
        end, 10)
      end
    end,
    pattern = "*",
  })

  -- 保存父窗口ID
  state.parent_window_id = parent_window_id
end

--- 调整虚拟输入框位置（内部函数）
function M._adjust_position()
  if not state.active then
    return
  end

  if not state.window_id or not vim.api.nvim_win_is_valid(state.window_id) then
    return
  end

  if not state.parent_window_id or not vim.api.nvim_win_is_valid(state.parent_window_id) then
    return
  end

  -- 获取父窗口当前尺寸
  local parent_height = vim.api.nvim_win_get_height(state.parent_window_id)
  local parent_width = vim.api.nvim_win_get_width(state.parent_window_id)

  -- 输入框高度和边框宽度
  local input_height = 3
  local border_width = 2

  -- 计算新位置（固定在父窗口底部）
  local win_width = math.max(20, parent_width - 4)
  local win_row = math.max(0, parent_height - input_height - 1)

  -- 获取当前窗口配置
  local win_config = vim.api.nvim_win_get_config(state.window_id)
  if not win_config then
    return
  end

  -- 只更新位置和尺寸（如果变化超过阈值）
  local current_width = win_config.width or win_width
  local current_row = win_config.row or win_row

  -- 如果位置或尺寸变化超过1个像素，则更新
  if math.abs(current_width - win_width) > 1 or math.abs(current_row - win_row) > 1 then
    win_config.width = win_width
    win_config.height = input_height
    win_config.row = win_row
    win_config.col = border_width

    -- 应用新的窗口配置
    vim.api.nvim_win_set_config(state.window_id, win_config)

    -- 调试信息（可选）
    -- print(string.format("📐 调整虚拟输入框位置: 宽度=%d, 行=%d", win_width, win_row))
  end
end

--- 清理窗口大小变化监听器（内部函数）
function M._cleanup_window_resize_listener()
  if state.resize_listener_id then
    pcall(vim.api.nvim_del_autocmd, state.resize_listener_id)
    state.resize_listener_id = nil
  end
end

return M
