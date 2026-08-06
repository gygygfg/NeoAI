--- 文件操作工具
--- @module NeoAI.tools.builtin.file_ops
--- 读/写/列/搜/删/建目录 + confirm_file_change（写入确认）。

local fs = require("NeoAI.utils.fs")
local stringx = require("NeoAI.utils.stringx")
local helpers = require("NeoAI.tools.builtin.tool_helpers")
local registry = require("NeoAI.tools.registry")

local M = {}

-- ========== 工具定义 ==========

local file_tools = {}

-- 读取文件
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
    local content, err = fs.read_file(filepath)
    if not content then
      on_error("无法读取文件: " .. filepath .. (err and (" (" .. err .. ")") or ""))
      return
    end
    if args.start_line or args.end_line then
      local lines = vim.split(content, "\n", { plain = true })
      local start = args.start_line or 1
      local finish = args.end_line or #lines
      start = math.max(1, start)
      finish = math.min(#lines, finish)
      local selected = {}
      for i = start, finish do selected[#selected + 1] = lines[i] end
      content = table.concat(selected, "\n")
    end
    on_success(content)
  end,
  { category = "file" }
)

-- 编辑文件
file_tools.edit_file = helpers.define_tool(
  "edit_file",
  "编辑文件。filepath 必填；mode='write' 整体覆写，mode='append' 追加；或提供 edits 数组做结构化替换。",
  {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      mode = { type = "string", description = "'write' | 'append' | 'edit'" },
      content = { type = "string", description = "写入内容（write/append 模式）" },
      edits = {
        type = "array",
        description = "结构化编辑 { old_text, new_text } 数组",
        items = { type = "object", properties = { old_text = { type = "string" }, new_text = { type = "string" } } },
      },
      explanation = { type = "string", description = "修改原因" },
    },
    required = { "filepath" },
  },
  function(args, on_success, on_error)
    local filepath = args.filepath
    local mode = args.mode or "edit"

    if mode == "write" then
      local ok, werr = fs.write_file(filepath, args.content or "")
      if not ok then on_error("写入失败: " .. tostring(werr)) return end
      on_success(("文件已写入: %s (%d 字节)"):format(filepath, #(args.content or "")))
      return
    end
    if mode == "append" then
      local ok, aerr = fs.append_file(filepath, args.content or "")
      if not ok then on_error("追加失败: " .. tostring(aerr)) return end
      on_success("已追加到: " .. filepath)
      return
    end

    -- edit 模式：结构化替换
    local content, err = fs.read_file(filepath)
    if not content then on_error("无法读取: " .. filepath) return end
    for _, edit in ipairs(args.edits or {}) do
      local old, new = edit.old_text, edit.new_text
      if old and new then
        content = stringx.replace(content, old, new)
      end
    end
    local ok, werr = fs.write_file(filepath, content)
    if not ok then on_error("写入失败: " .. tostring(werr)) return end
    on_success("文件已编辑: " .. filepath)
  end,
  { category = "file", approval = { auto_allow = false } }
)

-- 列出目录
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
    if not fs.is_dir(dir) then
      on_error("目录不存在: " .. dir)
      return
    end
    local entries = fs.list_dir(dir)
    local out = {}
    for _, e in ipairs(entries) do
      local full = fs.join(dir, e)
      out[#out + 1] = full .. (fs.is_dir(full) and "/" or "")
    end
    on_success(table.concat(out, "\n"))
  end,
  { category = "file" }
)

-- 搜索文件内容
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
    local query = args.query
    local max = args.max_results or 50
    local include = args.include
    local results = {}
    local count = 0
    local function walk(path)
      if count >= max then return end
      for _, e in ipairs(fs.list_dir(path)) do
        if count >= max then return end
        local full = fs.join(path, e)
        if fs.is_dir(full) then
          walk(full)
        else
          if not include or stringx.glob_match(include, e) then
            local content = fs.read_file(full)
            if content and content:find(query, 1, true) then
              count = count + 1
              results[#results + 1] = full .. ": " .. stringx.truncate(content:sub(content:find(query, 1, true), -1), 200)
            end
          end
        end
      end
    end
    walk(dir)
    on_success(#results > 0 and table.concat(results, "\n") or "未找到匹配内容")
  end,
  { category = "file" }
)

-- 文件是否存在
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

-- 删除文件
file_tools.delete_file = helpers.define_tool(
  "delete_file",
  "删除文件。filepath 必填。",
  {
    type = "object",
    properties = { filepath = { type = "string" } },
    required = { "filepath" },
  },
  function(args, on_success, on_error)
    local ok, err = fs.delete_file(args.filepath)
    if not ok then on_error("删除失败: " .. tostring(err)) return end
    on_success("文件已删除: " .. args.filepath)
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
