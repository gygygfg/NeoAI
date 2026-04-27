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

  -- 创建窗口（默认高度5，作为悬浮文本）
  -- 明确指定 window_mode = "float"，确保使用浮动窗口模式
  local window_id = window_manager.create_window("reasoning", {
    title = "NeoAI 思考过程",
    width = state.config.width or 60,
    height = state.config.height or 5,
    border = state.config.border or "rounded",
    style = "minimal",
    relative = "editor",
    row = state.position.y or 1,
    col = state.position.x or 1,
    zindex = 100,
    window_mode = "float",
  })

  if not window_id then
    print("⚠️ [reasoning_display] 创建思考过程悬浮窗口失败")
    state.is_visible = false
    return
  end

  state.current_window_id = window_id
  -- print("✓ [reasoning_display] 思考过程悬浮窗口已创建: " .. tostring(window_id))

  -- 获取窗口信息，确保缓冲区可修改
  local window_info = window_manager.get_window_info(window_id)
  if window_info and window_info.buf and vim.api.nvim_buf_is_valid(window_info.buf) then
    -- 确保缓冲区可修改
    vim.api.nvim_set_option_value("modifiable", true, { buf = window_info.buf })
    vim.api.nvim_set_option_value("readonly", false, { buf = window_info.buf })

    -- 设置文件类型为 markdown，启用语法高亮
    vim.api.nvim_set_option_value("filetype", "markdown", { buf = window_info.buf })

    -- 设置窗口选项
    if window_info.win and vim.api.nvim_win_is_valid(window_info.win) then
      vim.api.nvim_set_option_value("wrap", true, { win = window_info.win })
      vim.api.nvim_set_option_value("cursorline", true, { win = window_info.win })
    end
  end

  -- 设置窗口内容
  M._update_window_content()

  -- 设置按键映射
  M._setup_keymaps()

  return window_id
end

--- 追加思考内容（增量追加，避免全量重写）
--- @param content string 思考内容
function M.append(content)
  if not state.initialized then
    return
  end

  -- 确保 content 是字符串
  local content_str = tostring(content or "")

  if content_str == "" then
    return
  end

  if not state.is_visible or not state.current_window_id then
    -- 如果窗口不可见，先显示
    M.show(content_str)
    return
  end

  -- 更新内容缓冲区
  state.content_buffer = state.content_buffer .. content_str

  -- 增量追加到缓冲区末尾，避免全量重写
  local window_info = window_manager.get_window_info(state.current_window_id)
  if not window_info then
    return
  end

  local buf = window_info.buf
  local win = window_info.win

  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  -- 确保缓冲区可修改
  pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = buf })
  pcall(vim.api.nvim_set_option_value, "readonly", false, { buf = buf })

  -- 获取当前缓冲区行数
  local line_count = vim.api.nvim_buf_line_count(buf)

  -- 检查数据块是否包含换行符
  local has_newline = content_str:find("\n")

  if has_newline then
    -- 包含换行符：第一行追加到当前最后一行末尾，其余行作为新行插入
    local lines = vim.split(content_str, "\n", { plain = true })
    if #lines > 0 then
      local last_line = ""
      if line_count > 0 then
        local current_lines = vim.api.nvim_buf_get_lines(buf, line_count - 1, line_count, false)
        last_line = current_lines[1] or ""
      end

      local first_line = last_line .. (lines[1] or "")
      local new_lines = { first_line }
      for i = 2, #lines do
        table.insert(new_lines, lines[i] or "")
      end

      if line_count > 0 then
        pcall(vim.api.nvim_buf_set_lines, buf, line_count - 1, line_count, false, new_lines)
      else
        pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, new_lines)
      end
    end
  else
    -- 不包含换行符：直接追加到当前最后一行末尾
    if line_count > 0 then
      local current_lines = vim.api.nvim_buf_get_lines(buf, line_count - 1, line_count, false)
      local last_line = current_lines[1] or ""
      pcall(vim.api.nvim_buf_set_lines, buf, line_count - 1, line_count, false, { last_line .. content_str })
    else
      pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, { content_str })
    end
  end

  -- 恢复只读
  pcall(vim.api.nvim_set_option_value, "readonly", true, { buf = buf })
  pcall(vim.api.nvim_set_option_value, "modifiable", false, { buf = buf })
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = buf })

  -- 滚动到底部
  if win and vim.api.nvim_win_is_valid(win) then
    local new_line_count = vim.api.nvim_buf_line_count(buf)
    if new_line_count > 0 then
      pcall(vim.api.nvim_win_set_cursor, win, { new_line_count, 0 })
    end
  end
end

--- 关闭显示
function M.close()
  if not state.initialized then
    return
  end

  if state.current_window_id then
    -- 先尝试通过 window_manager 关闭
    window_manager.close_window(state.current_window_id)

    -- 强制检查窗口是否真的关闭了，如果没关闭则直接强制关闭
    local win_info = window_manager.get_window_info(state.current_window_id)
    if win_info then
      -- window_manager 可能没找到窗口（已从 windows 表移除但窗口还在）
      -- 尝试直接通过 win/buf 句柄关闭
      if win_info.win and vim.api.nvim_win_is_valid(win_info.win) then
        pcall(vim.api.nvim_win_close, win_info.win, true)
      end
      if win_info.buf and vim.api.nvim_buf_is_valid(win_info.buf) then
        pcall(vim.api.nvim_buf_delete, win_info.buf, { force = true })
      end
    end

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
--- 如果新内容以旧内容开头，则只追加差异部分，避免全量重写
--- @param content string 新的内容
function M.update(content)
  if not state.initialized then
    return
  end

  -- 确保 content 是字符串
  local content_str = tostring(content or "")

  if not state.is_visible or not state.current_window_id then
    M.show(content_str)
    return
  end

  -- 检查新内容是否以旧内容开头（追加模式）
  local old_content = state.content_buffer or ""
  if content_str:sub(1, #old_content) == old_content then
    -- 只追加差异部分
    local diff = content_str:sub(#old_content + 1)
    if diff ~= "" then
      state.content_buffer = content_str
      M.append(diff)
    end
  else
    -- 内容不连续，全量更新
    state.content_buffer = content_str
    M._update_window_content()
  end
end

--- 将思考内容转换为 Neovim 原生折叠文本
--- 使用 foldmethod=marker 和 foldmarker={{{,}}} 实现折叠
--- @param reasoning_text string 思考内容
--- @return string 折叠文本格式的字符串
function M._convert_to_folded_text(reasoning_text)
  -- 确保 reasoning_text 是字符串
  local reasoning_str = tostring(reasoning_text or "")

  if reasoning_str == "" then
    return ""
  end

  -- 创建 Neovim 原生折叠文本格式
  -- 折叠标记 {{{ 和 }}} 必须位于行首才能被 foldmethod=marker 识别
  -- {{{ 前面不能有任何字符（包括空格）
  local folded_text = ""
  folded_text = folded_text .. "{{{ 🤔 思考过程" .. "\n"

  -- 缩进思考内容
  for _, line in ipairs(vim.split(reasoning_str, "\n")) do
    folded_text = folded_text .. "  " .. line .. "\n"
  end

  folded_text = folded_text .. "}}}"

  return folded_text
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
  if not window_info then
    return
  end

  local buf = window_info.buf
  local win = window_info.win

  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  -- 确保缓冲区可修改
  local ok, _ = pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = buf })
  pcall(vim.api.nvim_set_option_value, "readonly", false, { buf = buf })

  -- 清空缓冲区
  pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, {})

  -- 设置缓冲区内容
  local lines = vim.split(state.content_buffer or "", "\n")
  pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines)

  -- 设置语法高亮
  pcall(vim.api.nvim_set_option_value, "filetype", "markdown", { buf = buf })

  -- 设置只读
  pcall(vim.api.nvim_set_option_value, "readonly", true, { buf = buf })
  pcall(vim.api.nvim_set_option_value, "modifiable", false, { buf = buf })
  -- 标记为未修改，避免保存警告
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = buf })

  -- 滚动到底部
  if win and vim.api.nvim_win_is_valid(win) then
    local line_count = vim.api.nvim_buf_line_count(buf)
    if line_count > 0 then
      pcall(vim.api.nvim_win_set_cursor, win, { line_count, 0 })
    end
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
  -- 使用直接关闭窗口的方式，避免 require 路径问题
  local function force_close()
    if state.current_window_id then
      local wm = require("NeoAI.ui.window.window_manager")
      wm.close_window(state.current_window_id)
      state.current_window_id = nil
      state.content_buffer = ""
      state.is_visible = false
    end
  end

  local keymaps = {
    { "q", force_close, desc = "关闭窗口" },
    { "<Esc>", force_close, desc = "关闭窗口" },
    { "<C-c>", force_close, desc = "关闭窗口" },
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
