local M = {}

local window_manager = require("NeoAI.ui.window.window_manager")

-- 模块状态
local state = {
  initialized = false,
  config = nil,
  current_window_id = nil,
  content_buffer = "",
  is_visible = false,
  position = { x = 0, y = 0 },
}

--- 初始化思考过程显示组件
--- @param config table 配置
function M.initialize(config)
  if state.initialized then
    return
  end

  state.config = config or {}
  state.initialized = true

  -- 创建事件组
  local event_group = vim.api.nvim_create_augroup("NeoAIEvents", { clear = true })

  -- 监听思考事件
  vim.api.nvim_create_autocmd("User", {
    group = event_group,
    pattern = "show_reasoning_display",
    callback = function(args)
      local content = args.data and args.data[1] or ""
      M.show(content)
    end,
    desc = "显示思考过程",
  })

  vim.api.nvim_create_autocmd("User", {
    group = event_group,
    pattern = "reasoning_content",
    callback = function(args)
      local content = args.data and args.data[1] or ""
      M.append(content)
    end,
    desc = "添加思考内容",
  })

  vim.api.nvim_create_autocmd("User", {
    group = event_group,
    pattern = "reasoning_chunk",
    callback = function(args)
      local chunk = args.data and args.data[1] or ""
      M.append(chunk)
    end,
    desc = "添加思考块",
  })

  vim.api.nvim_create_autocmd("User", {
    group = event_group,
    pattern = "close_reasoning_display",
    callback = function(args)
      local reasoning_text = args.data and args.data[1] or ""
      -- 将思考内容转换为折叠文本
      M._convert_to_folded_text(reasoning_text)
      M.close()
    end,
    desc = "关闭思考显示",
  })
end

--- 显示思考过程
--- @param content string 思考内容
function M.show(content)
  if not state.initialized then
    return
  end

  -- 如果已有窗口，先关闭
  if state.current_window_id then
    M.close()
  end

  -- 确保 content 是字符串
  state.content_buffer = tostring(content or "")
  state.is_visible = true

  -- 创建窗口
  local window_id = window_manager.create_window("reasoning", {
    title = "NeoAI 思考过程",
    width = state.config.width or 60,
    height = state.config.height or 15,
    border = state.config.border or "rounded",
    style = "minimal",
    relative = "editor",
    row = state.position.y or 1,
    col = state.position.x or 1,
    zindex = 100,
  })

  if not window_id then
    return
  end

  state.current_window_id = window_id

  -- 设置窗口内容
  M._update_window_content()

  -- 设置按键映射
  M._setup_keymaps()

  return window_id
end

--- 追加思考内容
--- @param content string 思考内容
function M.append(content)
  if not state.initialized then
    return
  end

  -- 确保 content 是字符串
  local content_str = tostring(content or "")

  if not state.is_visible or not state.current_window_id then
    -- 如果窗口不可见，先显示
    M.show(content_str)
    return
  end

  state.content_buffer = state.content_buffer .. content_str
  M._update_window_content()
end

--- 关闭显示
function M.close()
  if not state.initialized then
    return
  end

  if state.current_window_id then
    window_manager.close_window(state.current_window_id)
    state.current_window_id = nil
  end

  state.content_buffer = ""
  state.is_visible = false
end

--- 是否可见
--- @return boolean 是否可见
function M.is_visible()
  return state.is_visible
end

--- 隐藏推理显示
function M.hide()
  if not state.initialized then
    return
  end

  if state.current_window_id then
    window_manager.close_window(state.current_window_id)
    state.current_window_id = nil
  end

  state.is_visible = false
end

--- 更新推理显示内容
--- @param content string 新的内容
function M.update(content)
  if not state.initialized then
    return
  end

  if not state.is_visible or not state.current_window_id then
    M.show(content)
    return
  end

  -- 确保 content 是字符串
  state.content_buffer = tostring(content or "")
  M._update_window_content()
end

--- 将思考内容转换为折叠文本
--- @param reasoning_text string 思考内容
function M._convert_to_folded_text(reasoning_text)
  -- 确保 reasoning_text 是字符串
  local reasoning_str = tostring(reasoning_text or "")

  if reasoning_str == "" then
    return
  end

  -- 创建折叠文本格式
  local folded_text = "\n<details>\n<summary>🤔 思考过程 (点击展开)</summary>\n\n"
  folded_text = folded_text .. reasoning_str
  folded_text = folded_text .. "\n\n</details>\n"

  -- 将折叠文本复制到剪贴板
  vim.fn.setreg("+", folded_text)
  vim.fn.setreg("*", folded_text)

  -- 通知用户
  vim.notify("思考过程已转换为折叠文本并复制到剪贴板", vim.log.levels.INFO)
end

--- 异步将思考内容转换为折叠文本
--- @param reasoning_text string 思考内容
--- @param callback function 回调函数
function M._convert_to_folded_text_async(reasoning_text, callback)
  -- 确保 reasoning_text 是字符串
  local reasoning_str = tostring(reasoning_text or "")

  if reasoning_str == "" then
    if callback then
      callback("", "思考内容为空")
    end
    return
  end

  -- 使用异步工作器
  local async_worker = require("NeoAI.utils.async_worker")

  async_worker.submit_task("convert_to_folded_text", function()
    -- 在后台线程中创建折叠文本格式
    local folded_text = "\n<details>\n<summary>🤔 思考过程 (点击展开)</summary>\n\n"
    folded_text = folded_text .. reasoning_str
    folded_text = folded_text .. "\n\n</details>\n"
    
    return folded_text
  end, function(success, folded_text, error_msg)
    if callback then
      if success then
        -- 在主线程中复制到剪贴板
        vim.schedule(function()
          vim.fn.setreg("+", folded_text)
          vim.fn.setreg("*", folded_text)
          vim.notify("思考过程已转换为折叠文本并复制到剪贴板", vim.log.levels.INFO)
        end)
        callback(folded_text, nil)
      else
        -- 如果异步失败，回退到同步版本
        vim.schedule(function()
          M._convert_to_folded_text(reasoning_str)
        end)
        callback("", error_msg or "异步转换失败")
      end
    end
  end)
end

--- 更新窗口内容（内部使用）
function M._update_window_content()
  if not state.current_window_id then
    return
  end

  -- 获取窗口信息
  local window_info = window_manager.get_window_info(state.current_window_id)
  if not window_info or not window_info.buf then
    return
  end

  -- 确保缓冲区可修改
  vim.api.nvim_buf_set_option(window_info.buf, "modifiable", true)
  vim.api.nvim_buf_set_option(window_info.buf, "readonly", false)

  -- 设置缓冲区内容
  vim.api.nvim_buf_set_lines(window_info.buf, 0, -1, false, vim.split(state.content_buffer, "\n"))

  -- 设置只读
  vim.api.nvim_buf_set_option(window_info.buf, "readonly", true)
  vim.api.nvim_buf_set_option(window_info.buf, "modifiable", false)

  -- 设置语法高亮
  vim.api.nvim_buf_set_option(window_info.buf, "filetype", "markdown")

  -- 滚动到底部
  local line_count = vim.api.nvim_buf_line_count(window_info.buf)
  if line_count > 0 then
    vim.api.nvim_win_set_cursor(window_info.win, { line_count, 0 })
  end
end

--- 设置按键映射（内部使用）
function M._setup_keymaps()
  if not state.current_window_id then
    return
  end

  -- 获取窗口信息
  local window_info = window_manager.get_window_info(state.current_window_id)
  if not window_info or not window_info.buf then
    return
  end

  -- 清除现有映射
  local existing_maps = vim.api.nvim_buf_get_keymap(window_info.buf, "n")
  for _, map in ipairs(existing_maps) do
    vim.api.nvim_buf_del_keymap(window_info.buf, "n", map.lhs)
  end

  -- 设置按键映射
  local keymaps = {
    { "q", "<Cmd>lua require('NeoAI.ui.components.reasoning_display').close()<CR>", desc = "关闭窗口" },
    { "<Esc>", "<Cmd>lua require('NeoAI.ui.components.reasoning_display').close()<CR>", desc = "关闭窗口" },
    { "<C-c>", "<Cmd>lua require('NeoAI.ui.components.reasoning_display').close()<CR>", desc = "关闭窗口" },
    {
      "yy",
      "<Cmd>lua require('NeoAI.ui.components.reasoning_display')._copy_to_clipboard()<CR>",
      desc = "复制内容到剪贴板",
    },
    {
      "<C-s>",
      "<Cmd>lua require('NeoAI.ui.components.reasoning_display')._save_to_file()<CR>",
      desc = "保存内容到文件",
    },
  }

  for _, map in ipairs(keymaps) do
    vim.keymap.set("n", map[1], map[2], {
      buffer = window_info.buf,
      desc = map.desc,
      silent = true,
      noremap = true,
    })
  end
end

--- 复制内容到剪贴板（内部使用）
function M._copy_to_clipboard()
  if state.content_buffer == "" then
    vim.notify("没有内容可复制", vim.log.levels.WARN)
    return
  end

  vim.fn.setreg("+", state.content_buffer)
  vim.fn.setreg("*", state.content_buffer)
  vim.notify("内容已复制到剪贴板", vim.log.levels.INFO)
end

--- 保存内容到文件（内部使用）
function M._save_to_file()
  if state.content_buffer == "" then
    vim.notify("没有内容可保存", vim.log.levels.WARN)
    return
  end

  -- 获取文件名
  local filename = vim.fn.input("保存文件为: ", "reasoning_" .. os.date("%Y%m%d_%H%M%S") .. ".md")
  if filename == "" then
    return
  end

  -- 写入文件
  local file = io.open(filename, "w")
  if file then
    file:write(state.content_buffer)
    file:close()
    vim.notify("内容已保存到: " .. filename, vim.log.levels.INFO)
  else
    vim.notify("无法保存文件: " .. filename, vim.log.levels.ERROR)
  end
end

--- 复制内容（内部使用）
function M._copy_content()
  if not state.initialized then
    return
  end

  -- 确保 content_buffer 是字符串
  local content_str = tostring(state.content_buffer or "")

  if content_str == "" then
    return
  end

  -- 复制到系统剪贴板
  vim.fn.setreg("+", content_str)
  vim.notify("思考内容已复制到剪贴板", vim.log.levels.INFO)
end

--- 获取窗口ID
--- @return string|nil 窗口ID
function M.get_window_id()
  return state.current_window_id
end

--- 调整大小
--- @param width number 宽度
--- @param height number 高度
function M.resize(width, height)
  if not state.initialized or not state.current_window_id then
    return
  end

  window_manager.update_window_options(state.current_window_id, {
    width = width,
    height = height,
  })
end

--- 设置窗口位置
--- @param x number X坐标
--- @param y number Y坐标
function M.set_position(x, y)
  if not state.initialized or not state.current_window_id then
    return
  end

  state.position.x = x or state.position.x
  state.position.y = y or state.position.y

  window_manager.update_window_options(state.current_window_id, {
    col = state.position.x,
    row = state.position.y,
  })
end

--- 移动窗口
--- @param direction string 方向 ('up', 'down', 'left', 'right')
--- @param amount number 移动量
function M.move(direction, amount)
  if not state.initialized or not state.current_window_id then
    return
  end

  amount = amount or 5
  local new_position = vim.deepcopy(state.position)

  if direction == "up" then
    new_position.y = math.max(1, new_position.y - amount)
  elseif direction == "down" then
    new_position.y = new_position.y + amount
  elseif direction == "left" then
    new_position.x = math.max(1, new_position.x - amount)
  elseif direction == "right" then
    new_position.x = new_position.x + amount
  end

  M.set_position(new_position.x, new_position.y)
end

--- 切换可见性
function M.toggle()
  if not state.initialized then
    return
  end

  if state.is_visible then
    M.close()
  else
    M.show(state.content_buffer)
  end
end

--- 更新配置
--- @param new_config table 新配置
function M.update_config(new_config)
  if not state.initialized then
    return
  end

  state.config = vim.tbl_extend("force", state.config, new_config or {})

  -- 如果窗口打开，重新设置按键映射
  if state.current_window_id then
    M._setup_keymaps()
    M._update_window_content()
  end
end

return M
