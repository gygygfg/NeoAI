--- 工具定义辅助函数
--- @module NeoAI.tools.builtin.tool_helpers
--- 提供 define_tool 便捷构造器，供各内置工具模块使用。

local M = {}

--- ensure_buffer 后台加载的 buffer 集合（bufnr -> true）
local bg_loaded = {}

--- 构造工具定义
--- @param name string
--- @param description string
--- @param params table|nil parameters schema
--- @param func function(args, on_success, on_error, ctx)
--- @param opts table|nil { category?, approval?, timeout? }
--- @return table 工具定义
function M.define_tool(name, description, params, func, opts)
  opts = opts or {}
  return {
    name = name,
    description = description,
    parameters = params or {
      type = "object",
      properties = {},
      required = {},
    },
    func = func,
    category = opts.category or "other",
    approval = opts.approval or {},
    timeout = opts.timeout,
  }
end

--- 快捷：异步回调工具定义
--- @param name string
--- @param description string
--- @param params table|nil
--- @param handler function(args, on_success, on_error, ctx)
--- @param opts table|nil
--- @return table
function M.define_async_tool(name, description, params, handler, opts)
  return M.define_tool(name, description, params, handler, opts)
end

--- 工具结果包装（统一格式）
--- @param content string|table
--- @param opts table|nil { error? }
--- @return table
function M.ok(content, opts)
  opts = opts or {}
  if opts.error then
    return { success = false, error = tostring(content) }
  end
  return { success = true, result = content }
end

--- 错误结果包装
--- @param err string
--- @return table
function M.error(err)
  return { success = false, error = tostring(err) }
end

--- 校验必填字符串参数
--- @param args table
--- @param key string
--- @param tool_name string
--- @return string|nil, string|nil
function M.require_string(args, key, tool_name)
  local v = args and args[key]
  if type(v) ~= "string" or v == "" then
    return nil, string.format("%s 缺少必填字符串参数 %s", tool_name, key)
  end
  return v, nil
end

--- 获取文件的 buffer；若尚未加载则后台加载（不切换窗口、不改布局）。
--- LSP / treesitter 等依赖 buffer 的工具在文件未打开时用此函数自动加载。
--- @param filepath string|nil 空/缺省时返回当前 buffer
--- @return number|nil bufnr
function M.ensure_buffer(filepath)
  if not filepath or filepath == "" then
    return vim.api.nvim_get_current_buf()
  end
  local bufnr = vim.fn.bufnr(filepath)
  if bufnr >= 0 then return bufnr end
  if vim.fn.filereadable(filepath) ~= 1 then return nil end
  -- bufload 不能创建不存在的 buffer，须先 bufadd 注册再加载
  local add_ok = pcall(vim.fn.bufadd, filepath)
  if not add_ok then return nil end
  local load_ok = pcall(vim.fn.bufload, filepath)
  if not load_ok then return nil end
  local buf = vim.fn.bufnr(filepath)
  if buf < 0 then return nil end
  bg_loaded[buf] = true
  -- 后台加载不触发默认的 filetype 检测（-u NONE / 纯 headless 环境）
  -- treesitter / LSP 依赖 filetype 匹配语言或客户端，这里显式补齐
  if vim.bo[buf].filetype == nil or vim.bo[buf].filetype == "" then
    local ft = vim.filetype.match({ buf = buf, filename = filepath })
    if ft and ft ~= "" then
      pcall(vim.api.nvim_set_option_value, "filetype", ft, { buf = buf })
    end
  end
  return buf
end

--- 该 buffer 是否由 ensure_buffer 在后台加载（而非用户已打开的窗口 buffer）。
--- 写类工具据此决定修改后是否应落盘：后台加载的 buffer 不在任何窗口展示，
--- 若不保存，改动会随 buffer 卸载而丢失。
--- @param bufnr number
--- @return boolean
function M.is_background_loaded(bufnr)
  return bg_loaded[bufnr] == true
end

--- 磁盘内容与内存不一致时从磁盘同步 buffer（仅当 buffer 无未保存改动）。
--- edit_file 等磁盘直写工具只改磁盘、不改已加载 buffer 的内容，导致后续
--- LSP / treesitter 操作基于过期内容（读错位置、lsp_rename 把旧内容写回磁盘等）。
--- 此函数把磁盘最新内容同步进 buffer，Neovim 的 LSP sync 随之向服务器发送
--- didChange，刷新其文档缓存，后续请求基于最新内容。
--- @param bufnr number
--- @return boolean
function M.sync_buffer_from_disk(bufnr)
  if not vim.api.nvim_buf_is_loaded(bufnr) then return true end
  if vim.bo[bufnr].modified then return true end -- 有未保存改动，绝不覆盖
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" or vim.fn.filereadable(filepath) ~= 1 then return true end
  local disk_lines = vim.fn.readfile(filepath)
  local mem_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local same = #disk_lines == #mem_lines
  if same then
    for i = 1, #disk_lines do
      if disk_lines[i] ~= mem_lines[i] then same = false break end
    end
  end
  if same then return true end
  -- readfile 会丢弃末尾换行符；用 buffer 的 eol 选项补偿，保证写回时末行换行与磁盘一致
  local has_eol = true
  local f = io.open(filepath, "rb")
  if f then
    local data = f:read("*a")
    f:close()
    has_eol = data:sub(-1) == "\n"
  end
  local ok1 = pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, disk_lines)
  local ok2 = pcall(vim.api.nvim_buf_set_option, bufnr, "eol", has_eol)
  -- set_lines 会把 buffer 标记为 modified；磁盘一致时不视为未保存改动
  local ok3 = pcall(vim.api.nvim_buf_set_option, bufnr, "modified", false)
  return ok1 and ok2 and ok3
end

--- 持久化后台加载的 buffer（写回磁盘）。
--- 仅对 ensure_buffer 在后台加载的 buffer 生效，绝不覆盖用户打开的 buffer，
--- 避免写掉用户未保存的改动。buffer 未被修改时跳过。
--- @param bufnr number
--- @return boolean, string|nil
function M.persist_buffer(bufnr)
  if not bg_loaded[bufnr] then return true end
  if not vim.api.nvim_buf_is_loaded(bufnr) or not vim.bo[bufnr].modifiable then return true end
  if not vim.bo[bufnr].modified then return true end
  local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
    vim.cmd("silent write!")
  end)
  if not ok then return false, tostring(err) end
  return true
end

return M
