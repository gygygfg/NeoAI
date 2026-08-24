--- 文件操作工具
--- @module NeoAI.tools.builtin.file_ops
--- 读/写/列/搜/删/建目录 + confirm_file_change（写入确认）。
--- 阻塞式文件 I/O（读大文件 / 递归搜索 / 写盘）经 utils.work 在线程池执行，
--- 不占用 nvim 主线程，避免工具调用时主界面卡住。

local fs = require("NeoAI.utils.fs")
local helpers = require("NeoAI.tools.builtin.tool_helpers")

local M = {}

-- ========== 私有函数 ==========

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
  "读取文件内容。filepath 必填；start_line/end_line 可选指定行范围（1-based，含两端）。",
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
    local d
    if args.start_line or args.end_line then
      d = fs.read_file_lines_async(filepath, args.start_line or 0, args.end_line or 0)
    else
      d = fs.read_file_async(filepath)
    end
    _pipe(d, on_success, on_error)
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
        on_success(("文件已写入: %s (%d 字节)"):format(filepath, #(args.content or "")))
      end, on_error)
      return
    end
    if mode == "append" then
      _pipe(fs.append_file_async(filepath, args.content or ""), function()
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
            text = text:gsub(old:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"), new)
          end
        end
        local w = io.open(path, "wb")
        if not w then error("无法写入文件: " .. path) end
        w:write(text)
        w:close()
        return "ok"
      end, filepath .. "\3" .. table.concat(packed, "\2"))
    end):then_(function()
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
