local M = {}

-- ============================================================================
-- 工具：execute_vim_cmd
-- ============================================================================
-- 在当前 Neovim 实例中执行 vim.cmd 命令，并将输出结果返回

local function _execute_vim_cmd(args, on_success, on_error)
  -- 支持 cmd 作为 command 的别名，与 run_command 一致
  if args.command == nil and args.cmd ~= nil then
    args.command = args.cmd
  end

  local command = args.command
  if not command or command == "" then
    if on_error then
      on_error("参数 'command' 不能为空")
    end
    return
  end

  -- 保存当前窗口和 buffer，执行命令后恢复焦点
  local current_win = pcall(vim.api.nvim_get_current_win) and vim.api.nvim_get_current_win() or 0
  local current_buf = pcall(vim.api.nvim_get_current_buf) and vim.api.nvim_get_current_buf() or 0

  -- 使用 nvim_exec2 执行命令并捕获输出（比 vim.fn.execute 更可靠，不会因 echo 等命令阻塞）
  local ok, exec_result = pcall(function()
    return vim.api.nvim_exec2(command, { output = true })
  end)

  -- 恢复焦点 buffer 和窗口（命令可能改变了窗口布局）
  if current_win > 0 then
    pcall(vim.api.nvim_set_current_win, current_win)
  end
  if current_buf > 0 and vim.api.nvim_buf_is_valid(current_buf) then
    local win_buf = vim.api.nvim_win_get_buf(current_win > 0 and current_win or 0)
    if win_buf ~= current_buf then
      pcall(vim.api.nvim_win_set_buf, current_win > 0 and current_win or 0, current_buf)
    end
  end

  if not ok then
    if on_error then
      on_error("vim.cmd 执行失败: " .. tostring(exec_result))
    end
    return
  end

  -- nvim_exec2 返回 { output = "..." }，提取输出文本
  local output = exec_result and exec_result.output or ""

  -- 如果命令没有输出（如编辑操作），返回成功提示
  if not output or output == "" then
    if on_success then
      on_success("命令执行成功: " .. command)
    end
    return
  end

  if on_success then
    on_success(output)
  end
end

M.execute_vim_cmd = {
  name = "execute_vim_cmd",
  description = [[在当前 Neovim 实例中执行 vim.cmd Ex 命令（如编辑、写入、跳转等），返回命令输出结果。

支持所有 vim.cmd 可执行的 Ex 命令，包括但不限于：
- 文件操作: e, w, q, wq, saveas, edit
- 缓冲区管理: bnext, bprev, bdelete, buffer
- 窗口管理: split, vsplit, close, only
- 标签页管理: tabnew, tabnext, tabclose
- 搜索替换: %s/pattern/replacement/g
- 设置选项: set, setlocal
- 其他: messages, echo, checkhealth, colorscheme, help

注意：
- 命令在当前 Neovim 实例中执行，会影响当前编辑状态
- 对于会阻塞或打开新窗口的命令（如 help），会自动处理
- 输出结果会捕获并返回
]],
  func = _execute_vim_cmd,
  async = true,
  parameters = {
    type = "object",
    properties = {
      command = {
        type = "string",
        description = "要执行的 vim.cmd Ex 命令（必填，如 'e file.txt', 'w', 'bnext', 'set number' 等）",
      },
      cmd = {
        type = "string",
        description = "command 的别名，与 command 等效",
      },
    },
    required = { "command" },
  },
  returns = {
    type = "string",
    description = "命令执行结果输出",
  },
  category = "neovim",
  timeout = 30000, -- 30 秒超时
}

return M

