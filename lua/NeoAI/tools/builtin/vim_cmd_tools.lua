-- Neovim vim.cmd 执行工具（回调模式）
-- 提供在当前 Neovim 实例中执行 vim.cmd 命令的工具
-- 工具函数签名：func(args, on_success, on_error)

local M = {}

local define_tool = require("NeoAI.tools.builtin.tool_helpers").define_tool

-- ============================================================================
-- 工具：execute_vim_cmd
-- ============================================================================
-- 在当前 Neovim 实例中执行 vim.cmd 命令，并将输出结果返回

M.execute_vim_cmd = define_tool({
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
  func = function(args, on_success, on_error)
    local cmd = args.cmd
    if not cmd or cmd == "" then
      on_error("参数 'cmd' 不能为空")
      return
    end

    -- 使用 pcall 和 redir 捕获命令输出
    local ok, result = pcall(function()
      -- 使用 execute 捕获输出
      local output = vim.fn.execute(cmd)
      return output
    end)

    if not ok then
      on_error("vim.cmd 执行失败: " .. tostring(result))
      return
    end

    -- 如果命令没有输出（如编辑操作），返回成功提示
    if not result or result == "" then
      on_success("命令执行成功: " .. cmd)
      return
    end

    on_success(result)
  end,
  parameters = {
    type = "object",
    properties = {
      cmd = {
        type = "string",
        description = "要执行的 vim.cmd Ex 命令（如 'e file.txt', 'w', 'bnext', 'set number' 等）",
      },
    },
    required = { "cmd" },
  },
  returns = {
    type = "string",
    description = "命令执行结果输出",
  },
  category = "neovim",
  async = true,
  timeout = 30000, -- 30 秒超时
})

return M
