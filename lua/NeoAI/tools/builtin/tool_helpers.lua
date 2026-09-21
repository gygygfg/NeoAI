--- 工具定义辅助函数
--- @module NeoAI.tools.builtin.tool_helpers
--- 提供 define_tool 便捷构造器，供各内置工具模块使用。

local M = {}

--- ensure_buffer 后台加载的 buffer 集合（bufnr -> true）
local bg_loaded = {}

--- 被写类工具**显式修改**过的后台 buffer 集合（bufnr -> true）。
--- 仅这些 buffer 允许 `persist_buffer` 回写：加载（bufload）/同步（sync_buffer_from_disk）
--- 等只读路径绝不触发保存，避免「nvim 读取后重新保存」把文件按文本重新编码而损坏。
local bg_edited = {}

--- Neovim >= 0.13 起由内置文件监听（autoread）自动把外部改动的文件重载进 buffer，
--- 无需手动同步；更早版本依赖 sync_buffer_from_disk / reload_buffers_for。
local use_autoread = vim.fn.has("nvim-0.13") == 1

--- 采样判定文件是否为二进制：含 NUL，或非打印控制字节占比过高（>10%）。
--- 二进制**绝不载入文本 buffer，也绝不回写**：nvim 的 buffer/`:write!` 会按文本重新编码，
--- 把非法字节替换为 U+FFFD（`EF BF BD`）而损坏文件（如 OpenPGP keyring 被破坏后无法解析）。
--- @param filepath string
--- @return boolean
local function _is_binary_file(filepath)
  if type(filepath) ~= "string" or filepath == "" then return false end
  local f = io.open(filepath, "rb")
  if not f then return false end
  local sample = f:read(8192) or ""
  f:close()
  if sample == "" then return false end
  if sample:find("\0", 1, true) then return true end
  local ctrl, n = 0, #sample
  for i = 1, n do
    local b = sample:byte(i)
    -- 允许 tab/LF/FF/CR/ESC；其余 C0/C1 控制字节与 DEL 计入
    if (b < 32 and b ~= 9 and b ~= 10 and b ~= 12 and b ~= 13 and b ~= 27) or b == 127 then
      ctrl = ctrl + 1
    end
  end
  return ctrl * 10 > n
end

--- 构造工具定义
--- @param name string
--- @param description string
--- @param params table|nil parameters schema
--- @param func function(args, on_success, on_error, ctx)
--- @param opts table|nil { category?, approval?, timeout? }
--- @return table 工具定义
function M.define_tool(name, description, params, func, opts)
  opts = opts or {}
  params = params or { type = "object", properties = {}, required = {} }
  -- 统一注入 description 参数：所有工具都要求模型说明本次调用目的（供审批与折叠展示）。
  -- 已存在则保持原样（如 edit_file 的强制描述），否则补充为必填字符串参数。
  params.properties = params.properties or {}
  params.required = params.required or {}
  if params.properties.description == nil then
    params.properties.description = { type = "string", description = "本次调用目的说明（必填，用于审批与折叠展示）" }
    local has = false
    for _, r in ipairs(params.required) do
      if r == "description" then has = true break end
    end
    if not has then
      params.required[#params.required + 1] = "description"
    end
  end
  return {
    name = name,
    description = description,
    parameters = params,
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
  -- 二进制文件不载入文本 buffer：避免 buffer/回写按文本重新编码而损坏内容。
  if _is_binary_file(filepath) then return nil end
  -- bufload 不能创建不存在的 buffer，须先 bufadd 注册再加载
  local add_ok = pcall(vim.fn.bufadd, filepath)
  if not add_ok then return nil end
  local load_ok = pcall(vim.fn.bufload, filepath)
  if not load_ok then return nil end
  local buf = vim.fn.bufnr(filepath)
  if buf < 0 then return nil end
  bg_loaded[buf] = true
  -- 后台加载不触发默认的 filetype 检测（-u NONE / 纯 headless 环境）
  -- treesitter / LSP 依赖 filetype 匹配语言或客户端，这里显式补齐。
  -- 部分 Neovim 版本对未知类型文件用 { buf = ... } 形式匹配会抛错
  -- （detect.lua: bad argument to 'find'），回退为仅按文件名匹配并忽略失败。
  if vim.bo[buf].filetype == nil or vim.bo[buf].filetype == "" then
    local ok_ft, ft = pcall(vim.filetype.match, { buf = buf, filename = filepath })
    if not ok_ft or ft == nil or ft == "" then
      local ok_name, ft2 = pcall(vim.filetype.match, { filename = filepath })
      ft = ok_name and ft2 or nil
    end
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

--- 标记某后台 buffer 已被写类工具**显式修改**，允许 `persist_buffer` 回写。
--- 只有显式编辑路径（delete_node/lsp_rename/lsp_format 等）才调用；加载/同步绝不调用，
--- 从而保证「只读不改盘」。
--- @param bufnr number
function M.mark_edited(bufnr)
  if type(bufnr) == "number" and bufnr > 0 then bg_edited[bufnr] = true end
end

--- 磁盘内容与内存不一致时从磁盘同步 buffer（仅当 buffer 无未保存改动）。
--- edit_file 等磁盘直写工具只改磁盘、不改已加载 buffer 的内容，导致后续
--- LSP / treesitter 操作基于过期内容（读错位置、lsp_rename 把旧内容写回磁盘等）。
--- 此函数把磁盘最新内容同步进 buffer，Neovim 的 LSP sync 随之向服务器发送
--- didChange，刷新其文档缓存，后续请求基于最新内容。
--- @param bufnr number
--- @return boolean
function M.sync_buffer_from_disk(bufnr)
  if use_autoread then return true end -- >=0.13: 由 autoread 自动重载
  if not vim.api.nvim_buf_is_loaded(bufnr) then return true end
  if vim.bo[bufnr].modified then return true end -- 有未保存改动，绝不覆盖
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" or vim.fn.filereadable(filepath) ~= 1 then return true end
  -- 二进制文件不同步：readfile 会按行拆分并丢失 NUL/非法字节，破坏内容。
  if _is_binary_file(filepath) then return true end
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

--- 用**沙箱暂存内容**同步 buffer（供 LSP 工具使用），使 LSP 客户端的 didOpen/didChange
--- 文本与沙箱命名空间内的磁盘视图（overlay 物化的暂存内容）一致。否则 server 会同时看到
--- 「buffer 文本=真实内容」与「磁盘=暂存内容」两份，诊断/补全基于真实内容，与文件工具
--- （读暂存）分裂——即「LSP 工具与文件共享同一命名空间视图」要消除的问题。
--- 仅作用于 `ensure_buffer` 后台加载、非用户打开的 buffer；用户已打开的 buffer 绝不覆盖
--- （避免把沙箱内未发布的改动泄露到用户编辑器视图）。
--- @param bufnr number
--- @param filepath string 真实路径（后台 buffer 名即真实路径）
--- @return boolean
function M.sync_buffer_from_sandbox(bufnr, filepath)
  if type(filepath) ~= "string" or filepath == "" then return true end
  if not vim.api.nvim_buf_is_loaded(bufnr) then return true end
  if vim.bo[bufnr].modified then return true end -- 有未保存改动，绝不覆盖
  if not bg_loaded[bufnr] then return true end -- 仅后台加载的 buffer
  local ok, cand = pcall(require, "NeoAI.sandbox.candidate")
  if not ok or not cand or type(cand.read_path) ~= "function" then return true end
  local staged = cand.read_path(filepath)
  if not staged then return true end
  local content = require("NeoAI.utils.fs").read_file(staged)
  if content == nil then return true end
  local has_eol = content:sub(-1) == "\n"
  local disk_lines = vim.split(content:gsub("\n$", ""), "\n", { plain = true })
  if content == "" then disk_lines = { "" } end
  local mem_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local same = #disk_lines == #mem_lines
  if same then
    for i = 1, #disk_lines do
      if disk_lines[i] ~= mem_lines[i] then same = false break end
    end
  end
  if same then
    pcall(vim.api.nvim_buf_set_option, bufnr, "eol", has_eol)
    return true
  end
  local ok1 = pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, disk_lines)
  local ok2 = pcall(vim.api.nvim_buf_set_option, bufnr, "eol", has_eol)
  pcall(vim.api.nvim_buf_set_option, bufnr, "modified", false)
  return ok1 and ok2
end

--- AI 工具直写磁盘后，同步所有已加载且指向该文件的 buffer（仅当无未保存改动）。
--- 解决 edit_file/write_file/append_file/git_rollback 改盘后，已打开 buffer 展示
--- 过期内容（看不见 AI 的修改、按旧行号操作读错位置）的问题。
--- @param filepath string
function M.reload_buffers_for(filepath)
  if use_autoread then return end -- >=0.13: 由 autoread 自动重载
  if not filepath or filepath == "" then return end
  local abs = vim.fn.fnamemodify(filepath, ":p")
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and vim.fn.fnamemodify(name, ":p") == abs then
        M.sync_buffer_from_disk(buf)
      end
    end
  end
end

--- 持久化后台加载的 buffer（写回磁盘）。
--- 仅对 ensure_buffer 在后台加载的 buffer 生效，绝不覆盖用户打开的 buffer，
--- 避免写掉用户未保存的改动。buffer 未被修改时跳过。
--- @param bufnr number
--- @return boolean, string|nil
function M.persist_buffer(bufnr)
  if not bg_loaded[bufnr] then return true end
  -- 仅显式编辑过的 buffer 允许回写：加载（bufload）/同步（sync_buffer_from_disk）等只读路径
  -- 绝不触发保存——否则 nvim 读取后重新保存会把文件按文本重新编码而损坏（二进制尤其严重）。
  if not bg_edited[bufnr] then return true end
  if not vim.api.nvim_buf_is_loaded(bufnr) or not vim.bo[bufnr].modifiable then return true end
  if not vim.bo[bufnr].modified then return true end
  -- 沙箱激活时把 buffer 写盘重定向到私有暂存层，不落真实工作区。
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  -- 二进制文件绝不回写：buffer 已按文本处理，写回会把非法字节替换为 U+FFFD 而损坏内容
  -- （如 OpenPGP keyring）。二进制只读、不保存。
  if filepath ~= "" and _is_binary_file(filepath) then return false, "BINARY_SKIP" end
  local target = nil
  if filepath ~= "" then
    local ok_sb, sandbox = pcall(require, "NeoAI.sandbox")
    if ok_sb and sandbox and sandbox.candidate then
      target = sandbox.candidate.persist_target(filepath)
    end
  end
  local write_cmd = "silent write!"
  if target then
    write_cmd = "silent write! " .. vim.fn.fnameescape(target)
  end
  local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
    vim.cmd(write_cmd)
  end)
  if not ok then return false, tostring(err) end
  bg_edited[bufnr] = nil -- 已保存：清除编辑标记，后续只读路径不再回写
  return true
end

return M
