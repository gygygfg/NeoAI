--- 文件操作工具
--- @module NeoAI.tools.builtin.file_ops
--- 读/写/列/搜/删/建目录 + confirm_file_change（写入确认）。
--- 阻塞式文件 I/O（读大文件 / 递归搜索 / 写盘）经 utils.work 在线程池执行，
--- 不占用 nvim 主线程，避免工具调用时主界面卡住。

local fs = require("NeoAI.utils.fs")
local helpers = require("NeoAI.tools.builtin.tool_helpers")
local config_store = require("NeoAI.kernel.config_store")

local M = {}

-- ========== 私有常量 ==========

-- read_file 大文件保护的默认参数（可经 tools.read_file 覆盖）。
-- 未指定 start_line/end_line 时，超过字符阈值的文件不再整篇回传，
-- 改为返回语法树节点大纲（无 parser 时回退为截断预览），避免 AI
-- 一次性意外读取超大文件、瞬间耗尽上下文。
local DEFAULT_READ_GUARD = {
  outline_threshold_chars = 500, -- 超过该字符数即触发保护
  outline_max_nodes = 200, -- 大纲最多输出的结构节点数
  outline_max_depth = 4, -- 大纲最大递归深度（相对根节点）
  outline_preview_lines = 50, -- 无 parser 时的预览行数
}

-- ========== 私有函数 ==========

--- 读取 read_file 保护参数（配置缺省时用默认值兜底）
--- @return table
local function _read_guard_opts()
  local user = config_store.get("tools.read_file")
  local opts = {}
  for k, v in pairs(DEFAULT_READ_GUARD) do
    local uv = type(user) == "table" and user[k] or nil
    opts[k] = type(uv) == "number" and uv or v
  end
  return opts
end

--- 统计文本码点数（Blob / 异常时回退字节长度）
--- @param s string
--- @return number
local function _char_count(s)
  if type(s) ~= "string" then return 0 end
  local ok, n = pcall(vim.fn.strchars, s)
  if ok and type(n) == "number" then return n end
  return #s
end

--- 统计行数
--- @param s string
--- @return number
local function _line_count(s)
  if s == "" then return 0 end
  local n = 1
  for _ in s:gmatch("\n") do
    n = n + 1
  end
  return n
end

--- 按行范围从内容中切出某行文本（1-based，缺失返回 ""）
--- @param content string
--- @param row number 1-based 行号
--- @return string
local function _line_at(content, row)
  if row < 1 then return "" end
  local i = 0
  for line in (content .. "\n"):gmatch("(.-)\n") do
    i = i + 1
    if i == row then return line end
  end
  return ""
end

--- 把内容切成行数组（供 filetype.match 的内容探测用），最多取前 max 行
--- @param content string
--- @param max number
--- @return string[]
local function _lines_of(content, max)
  local out = {}
  for line in (content .. "\n"):gmatch("(.-)\n") do
    out[#out + 1] = line
    if #out >= max then break end
  end
  return out
end

--- 生成语法树节点大纲：递归输出「有命名子节点」的结构性节点。
--- 用 vim.treesitter.get_string_parser 直接从字符串解析，不创建/加载 buffer，
--- 避免污染 buffer 列表或触发 LSP 附着等副作用。
--- @param content string 文件内容
--- @param filepath string 文件路径（用于推断 filetype/语言）
--- @param opts table { max_nodes, max_depth }
--- @return string|nil outline, string|nil err
local function _build_outline(content, filepath, opts)
  -- contents 需为行数组（vim.filetype.match 的契约），可辅助无扩展名文件的探测
  local ft = vim.filetype.match({ filename = filepath, contents = _lines_of(content, 100) })
  if not ft or ft == "" then
    return nil, "无法识别文件类型"
  end
  local lang = vim.treesitter.language.get_lang(ft) or ft
  local ok_parser, parser = pcall(vim.treesitter.get_string_parser, content, lang)
  if not ok_parser or not parser then
    return nil, "无可用 tree-sitter parser"
  end
  local ok_parse, trees = pcall(function()
    return parser:parse()
  end)
  if not ok_parse or not trees or not trees[1] then
    return nil, "语法树解析失败"
  end
  local root = trees[1]:root()
  if not root then
    return nil, "语法树为空"
  end

  local max_nodes = opts.max_nodes or 200
  local max_depth = opts.max_depth or 4
  local lines = {}
  local count = 0
  local truncated = false

  local function render(node, depth)
    if count >= max_nodes then
      truncated = true
      return
    end
    if depth > max_depth then
      truncated = true
      return
    end
    local sr, _, er = node:range()
    local snippet = _line_at(content, sr + 1):gsub("^%s+", ""):gsub("%s+$", "")
    if #snippet > 80 then snippet = snippet:sub(1, 80) .. "…" end
    count = count + 1
    local seg = string.rep("  ", depth) .. node:type()
    if er + 1 > sr + 1 then seg = seg .. " [" .. (sr + 1) .. "-" .. (er + 1) .. "]" end
    if snippet ~= "" then seg = seg .. ": " .. snippet end
    lines[#lines + 1] = seg
    for i = 0, node:named_child_count() - 1 do
      if count >= max_nodes then
        truncated = true
        break
      end
      local child = node:named_child(i)
      -- 仅保留有命名子节点的结构性节点，折叠纯叶子（identifier/number 等），
      -- 否则大纲会被大量低信息量节点淹没。
      if child and child:named_child_count() > 0 then
        render(child, depth + 1)
      end
    end
  end

  -- 根节点自身不渲染，从顶层命名结构开始
  for i = 0, root:named_child_count() - 1 do
    if count >= max_nodes then
      truncated = true
      break
    end
    local child = root:named_child(i)
    if child and child:named_child_count() > 0 then
      render(child, 0)
    end
  end

  if count == 0 then
    return nil, "无可展示的结构节点"
  end
  if truncated then
    lines[#lines + 1] = string.format("  …（节点较多，已省略；可用 start_line/end_line 读取具体区间）")
  end
  return table.concat(lines, "\n")
end

--- 无 parser 时的截断预览：取前 n 行
--- @param content string
--- @param n number
--- @return string
local function _preview_lines(content, n)
  local out = {}
  local i = 0
  for line in (content .. "\n"):gmatch("(.-)\n") do
    i = i + 1
    if i > n then break end
    out[#out + 1] = line
  end
  return table.concat(out, "\n")
end

--- 大文件保护：阈值内返回全文；超阈值优先返回语法树大纲，
--- 无 parser 时回退为「提示 + 截断预览」。
--- @param content string
--- @param filepath string
--- @return string
local function _guarded_content(content, filepath)
  local opts = _read_guard_opts()
  local chars = _char_count(content)
  if chars <= opts.outline_threshold_chars then
    return content
  end
  local outline = _build_outline(content, filepath, {
    max_nodes = opts.outline_max_nodes,
    max_depth = opts.outline_max_depth,
  })
  local header = string.format(
    "[文件较大] %s 共 %d 字符 / %d 行，超过阈值 %d，未返回全文以避免一次性读取过大。\n"
      .. "请改用 start_line/end_line 读取所需行区间。",
    filepath,
    chars,
    _line_count(content),
    opts.outline_threshold_chars
  )
  if outline then
    return header .. "\n\n语法树节点大纲：\n" .. outline
  end
  return header
    .. string.format("\n（该文件无可用语法树解析器，以下为前 %d 行预览）：\n", opts.outline_preview_lines)
    .. _preview_lines(content, opts.outline_preview_lines)
end

--- 异步文件操作公共接线：resolve → on_success，reject → on_error
--- @param d Deferred
--- @param on_success function
--- @param on_error function
local function _pipe(d, on_success, on_error)
  d:then_(function(res)
    on_success(res)
  end, function(e)
    on_error(e.message or tostring(e))
  end)
end

-- ========== 工具定义 ==========

local file_tools = {}

-- 读取文件（线程池异步）
file_tools.read_file = helpers.define_tool(
  "read_file",
  "读取文件内容。filepath 必填；start_line/end_line 可选指定行范围（1-based，含两端）。"
    .. "未指定行范围且文件较大（默认超 500 字符）时不返回全文，"
    .. "而返回该文件的语法树节点大纲（无解析器时为截断预览），"
    .. "以避免一次性读取过大文件；此时请改用 start_line/end_line 读取所需区间。",
  {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      start_line = { type = "integer", description = "起始行号（可选）" },
      end_line = { type = "integer", description = "结束行号（可选）" },
    },
    required = { "filepath" },
  },
  function(args, on_success, on_error)
    local filepath = args.filepath
    if args.start_line or args.end_line then
      -- 指定行范围：精确读取，不受大文件保护影响
      _pipe(fs.read_file_lines_async(filepath, args.start_line or 0, args.end_line or 0), on_success, on_error)
      return
    end
    -- 无行范围：小文件返回全文；大文件返回语法树大纲（无 parser 时预览）
    _pipe(fs.read_file_async(filepath), function(content)
      on_success(_guarded_content(content, filepath))
    end, on_error)
  end,
  { category = "file" }
)

-- 编辑文件（线程池异步读写）
file_tools.edit_file = helpers.define_tool(
  "edit_file",
  "编辑文件。filepath 必填；description 必填（描述本次修改目的）；mode='write' 整体覆写，mode='append' 追加；或提供 edits 数组做结构化替换。",
  {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      description = { type = "string", description = "修改目的说明（必填，供审批与记录）" },
      mode = { type = "string", description = "'write' | 'append' | 'edit'" },
      content = { type = "string", description = "写入内容（write/append 模式）" },
      edits = {
        type = "array",
        description = "结构化编辑 { old_text, new_text } 数组",
        items = { type = "object", properties = { old_text = { type = "string" }, new_text = { type = "string" } } },
      },
    },
    required = { "filepath", "description" },
  },
  function(args, on_success, on_error)
    local filepath = args.filepath
    local description = args.description
    local mode = args.mode or "edit"

    if mode == "write" then
      _pipe(fs.write_file_async(filepath, args.content or ""), function()
        helpers.reload_buffers_for(filepath)
        on_success(("文件已写入: %s (%d 字节)"):format(filepath, #(args.content or "")))
      end, on_error)
      return
    end
    if mode == "append" then
      _pipe(fs.append_file_async(filepath, args.content or ""), function()
        helpers.reload_buffers_for(filepath)
        on_success("已追加到: " .. filepath)
      end, on_error)
      return
    end

    -- edit 模式：结构化替换（读在子线程，替换与写盘也在子线程）
    local edits = args.edits or {}
    if #edits == 0 then
      on_error("edit 模式需要提供 edits 数组")
      return
    end
    -- 序列化传给子线程（仅原始类型）：分隔符约定
    --   \1 = old/new 之间   \2 = 编辑条目之间   \3 = filepath 与编辑序列之间
    local packed = {}
    for _, edit in ipairs(edits) do
      if edit.old_text and edit.new_text then
        packed[#packed + 1] = edit.old_text .. "\1" .. edit.new_text
      end
    end
    if #packed == 0 then
      on_error("edits 需要包含有效的 old_text/new_text")
      return
    end
    fs.read_file_async(filepath):then_(function()
      local work = require("NeoAI.utils.work")
      return work.run(function(payload)
        local path, edits_blob = payload:match("^(.-)\3(.*)$")
        if not path then error("编辑负载格式错误") end
        local f = io.open(path, "rb")
        if not f then error("无法读取文件: " .. path) end
        local text = f:read("*a")
        f:close()
        for entry in edits_blob:gmatch("[^\2]+") do
          local old, new = entry:match("^(.-)\1(.*)$")
          if old and new ~= nil then
            -- new 作为替换串会被 gsub 解析其中的 % 转义（如 %d/%s 被吞），
            -- 用函数替换使 new 按字面写入，避免破坏含 % 的内容。
            local escaped = old:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
            text = text:gsub(escaped, function() return new end)
          end
        end
        local w = io.open(path, "wb")
        if not w then error("无法写入文件: " .. path) end
        w:write(text)
        w:close()
        return "ok"
      end, filepath .. "\3" .. table.concat(packed, "\2"))
    end):then_(function()
      helpers.reload_buffers_for(filepath)
      on_success("文件已编辑: " .. filepath)
    end, function(e)
      on_error(e.message or tostring(e))
    end)
  end,
  { category = "file", approval = { auto_allow = false } }
)

-- 列出目录（线程池异步）
file_tools.list_files = helpers.define_tool(
  "list_files",
  "列出目录内容。path 可选，默认当前目录；recursive 可选。",
  {
    type = "object",
    properties = {
      path = { type = "string", description = "目录路径（默认当前目录）" },
      recursive = { type = "boolean", description = "是否递归（默认 false）" },
      max_results = { type = "integer", description = "最大返回数量" },
    },
    required = {},
  },
  function(args, on_success, on_error)
    local dir = args.path or "."
    local max = args.max_results or 0
    if not fs.is_dir(dir) then
      on_error("目录不存在: " .. dir)
      return
    end
    if args.recursive then
      _pipe(fs.list_dir_async(dir, max), on_success, on_error)
      return
    end
    -- 非递归：单层列出（join + is_dir 判断在主线程，量级很小；readdir 走子线程）
    local work = require("NeoAI.utils.work")
    _pipe(work.run(function(path)
      local handle = vim.uv.fs_scandir(path)
      if not handle then return "" end
      local out = {}
      while true do
        local name, t = vim.uv.fs_scandir_next(handle)
        if not name then break end
        out[#out + 1] = path .. "/" .. name .. (t == "directory" and "/" or "")
      end
      table.sort(out)
      return table.concat(out, "\n")
    end, dir), on_success, on_error)
  end,
  { category = "file" }
)

-- 搜索文件内容（线程池异步递归）
file_tools.search_files = helpers.define_tool(
  "search_files",
  "在目录中按模式搜索文件内容。query 必填；include 可选 glob。",
  {
    type = "object",
    properties = {
      query = { type = "string", description = "搜索关键字" },
      include = { type = "string", description = "文件 glob，如 '*.lua'" },
      path = { type = "string", description = "搜索目录（默认当前目录）" },
      max_results = { type = "integer", description = "最大返回条数（默认 50）" },
    },
    required = { "query" },
  },
  function(args, on_success, on_error)
    local dir = args.path or "."
    _pipe(fs.search_files_async(dir, args.query, {
      include = args.include,
      max_results = args.max_results or 50,
    }), on_success, on_error)
  end,
  { category = "file" }
)

-- 文件是否存在（同步，量级极小）
file_tools.file_exists = helpers.define_tool(
  "file_exists",
  "检查文件是否存在。filepath 必填。返回 'true'/'false'。",
  {
    type = "object",
    properties = { filepath = { type = "string" } },
    required = { "filepath" },
  },
  function(args, on_success)
    on_success(tostring(fs.exists(args.filepath)))
  end,
  { category = "file" }
)

-- 创建目录
file_tools.create_directory = helpers.define_tool(
  "create_directory",
  "创建目录（递归）。filepath 必填。",
  {
    type = "object",
    properties = { filepath = { type = "string" } },
    required = { "filepath" },
  },
  function(args, on_success, on_error)
    local ok, err = fs.ensure_dir(args.filepath)
    if not ok then on_error("创建目录失败: " .. tostring(err)) return end
    on_success("目录已创建: " .. args.filepath)
  end,
  { category = "file", approval = { auto_allow = false } }
)

-- 确保目录存在
file_tools.ensure_dir = helpers.define_tool(
  "ensure_dir",
  "确保目录存在（不存在则创建）。filepath 必填。",
  {
    type = "object",
    properties = { filepath = { type = "string" } },
    required = { "filepath" },
  },
  function(args, on_success, on_error)
    local ok, err = fs.ensure_dir(args.filepath)
    if not ok then on_error("创建目录失败: " .. tostring(err)) return end
    on_success("目录已就绪: " .. args.filepath)
  end,
  { category = "file", approval = { auto_allow = false } }
)

-- 删除文件（线程池异步）
file_tools.delete_file = helpers.define_tool(
  "delete_file",
  "删除文件。filepath 必填。",
  {
    type = "object",
    properties = { filepath = { type = "string" } },
    required = { "filepath" },
  },
  function(args, on_success, on_error)
    _pipe(fs.delete_file_async(args.filepath), function()
      helpers.reload_buffers_for(args.filepath)
      on_success("文件已删除: " .. args.filepath)
    end, on_error)
  end,
  { category = "file", approval = { auto_allow = false } }
)

-- 写入确认（与 edit_file 配合）
file_tools.confirm_file_change = helpers.define_tool(
  "confirm_file_change",
  "确认对文件的修改。action 必填：'confirm' 确认 / 'abandon' 放弃 / 'retry' 用修正参数重试。",
  {
    type = "object",
    properties = {
      action = { type = "string", enum = { "confirm", "abandon", "retry" }, description = "确认/放弃/重试" },
      reason = { type = "string", description = "说明" },
    },
    required = { "action" },
  },
  function(args, on_success)
    on_success(("文件修改%s确认"):format(args.action == "confirm" and "已" or (args.action == "abandon" and "已放弃" or "将重试")))
  end,
  { category = "file" }
)

--- 获取工具列表
--- @return table 数组
function M.get_tools()
  local out = {}
  for _, tool in pairs(file_tools) do
    out[#out + 1] = tool
  end
  return out
end

return M
