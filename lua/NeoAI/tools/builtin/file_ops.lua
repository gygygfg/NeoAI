--- 文件操作工具
--- @module NeoAI.tools.builtin.file_ops
--- 读/写/列/搜/删/建目录 + confirm_file_change（写入确认）。
--- 阻塞式文件 I/O（读大文件 / 递归搜索 / 写盘）经 utils.work 在线程池执行，
--- 不占用 nvim 主线程，避免工具调用时主界面卡住。

local fs = require("NeoAI.utils.fs")
local helpers = require("NeoAI.tools.builtin.tool_helpers")
local config_store = require("NeoAI.kernel.config_store")
local stringx = require("NeoAI.utils.stringx")

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
  max_read_bytes = 5 * 1024 * 1024, -- 整读硬上限（字节），超过则拒绝整读避免 OOM
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
  -- contents 需为行数组（vim.filetype.match 的契约），可辅助无扩展名文件的探测。
  -- 某些 Neovim 版本对未知类型文件会抛错（detect.lua: bad argument to 'find'），
  -- 这里 pcall 兜底，无法识别时按无类型处理。
  local ok_ft, ft = pcall(vim.filetype.match, { filename = filepath, contents = _lines_of(content, 100) })
  if not ok_ft or not ft or ft == "" then
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
    -- UTF-8 安全截断：字节截断可能切断多字节字符（显示乱码），故按字符边界回退
    if #snippet > 80 then snippet = stringx.safe_truncate(snippet, 80, "…") end
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

--- 沙箱工作区暂存覆盖快照（沙箱未启用/无暂存时返回空数组）
--- @return table
local function _sandbox_overrides()
  local ok, cand = pcall(require, "NeoAI.sandbox.candidate")
  if not ok or not cand or type(cand.workspace_overrides) ~= "function" then return {} end
  local ok2, ov = pcall(cand.workspace_overrides)
  if not ok2 or type(ov) ~= "table" then return {} end
  return ov
end

--- 规范化绝对路径（去尾部斜杠）
--- @param p string
--- @return string
local function _abs_norm(p)
  return (vim.fn.fnamemodify(fs.expand(p), ":p"):gsub("/+$", ""))
end

--- 暂存条目是否为目录（create_directory 等会暂存目录本身）。
--- @param o table { staged }
--- @return boolean
local function _override_is_dir(o)
  local st = o.staged and vim.uv.fs_stat(o.staged)
  return st ~= nil and st.type == "directory"
end

--- 沙箱视图中该目录下是否存在内容（真实目录可能尚不存在）。
--- 用于 list_files：run_command/create_directory 可在沙箱里新建整棵目录树，
--- 而真实磁盘尚无该目录；只按真实 fs.is_dir 判断会把沙箱视图判为“目录不存在”。
--- @param dir string
--- @return boolean
local function _sandbox_dir_present(dir)
  local absdir = _abs_norm(dir)
  for _, o in ipairs(_sandbox_overrides()) do
    if not o.deleted then
      local abs = o.real
      if abs == absdir or abs:sub(1, #absdir + 1) == absdir .. "/" then return true end
    end
  end
  return false
end

--- 沙箱视图中路径是否存在；返回 nil 表示沙箱无覆盖，交由真实文件系统判断。
--- @param path string
--- @return boolean|nil
local function _sandbox_path_exists(path)
  local abs = _abs_norm(path)
  for _, o in ipairs(_sandbox_overrides()) do
    if o.real == abs then return not o.deleted end
    if not o.deleted and o.real:sub(1, #abs + 1) == abs .. "/" then return true end
  end
  return nil
end

--- 把沙箱暂存覆盖叠加到目录列举结果上：新增未发布的文件、移除已删除的文件，
--- 使 list_files 对 AI 呈现与真实编辑一致（沙箱不可见）。
--- @param base_text string 原始列举结果（每行一条）
--- @param dir string 起始目录
--- @param recursive boolean|nil
--- @param max number|nil
--- @return string
local function _merge_list(base_text, dir, recursive, max)
  local overrides = _sandbox_overrides()
  local absdir = _abs_norm(dir)
  local lines, seen, removed = {}, {}, {}
  for _, o in ipairs(overrides) do
    if o.deleted then removed[o.real] = true end
  end
  if base_text ~= "" and base_text ~= "(空目录)" then
    for line in (base_text .. "\n"):gmatch("(.-)\n") do
      if line ~= "" then
        local is_dir = line:sub(-1) == "/"
        local raw = is_dir and line:sub(1, -2) or line
        local abs = _abs_norm(raw)
        local drop = false
        for del in pairs(removed) do
          if abs == del or abs:sub(1, #del + 1) == del .. "/" then drop = true break end
        end
        if not drop then
          lines[#lines + 1] = line
          seen[abs] = true
        end
      end
    end
  end
  -- 把暂存路径补进列举结果：recursive 时补齐各级父目录条目，非 recursive 时只补直接子项。
  -- 目录条目以 "/" 结尾，与真实列举格式一致。
  local function add_entry(rel, is_dir)
    local abs = absdir .. "/" .. rel
    if seen[abs] then return end
    seen[abs] = true
    lines[#lines + 1] = dir .. "/" .. rel .. (is_dir and "/" or "")
  end
  for _, o in ipairs(overrides) do
    if not o.deleted then
      local abs = o.real
      local under = abs == absdir or abs:sub(1, #absdir + 1) == absdir .. "/"
      if under and abs ~= absdir then
        local rel = abs:sub(#absdir + 2)
        if recursive then
          local acc = ""
          for seg in rel:gmatch("[^/]+") do
            acc = acc == "" and seg or (acc .. "/" .. seg)
            if acc ~= rel then add_entry(acc, true) end
          end
          add_entry(rel, _override_is_dir(o))
        else
          local first = rel:match("^([^/]+)")
          if first then
            add_entry(first, rel:find("/", 1, true) ~= nil or _override_is_dir(o))
          end
        end
      end
    end
  end
  table.sort(lines)
  if max and max > 0 and #lines > max then
    local trimmed = {}
    for i = 1, max do trimmed[i] = lines[i] end
    lines = trimmed
  end
  if #lines == 0 then return "(空目录)" end
  return table.concat(lines, "\n")
end

--- 把沙箱暂存覆盖叠加到内容搜索结果上：替换被暂存覆盖的文件的真实结果，
--- 并搜索尚未发布的新建/修改内容。
--- @param base_text string 原始搜索结果
--- @param dir string 搜索目录
--- @param query string 关键字
--- @param include string|nil glob
--- @param max number|nil
--- @return string
local function _merge_search(base_text, dir, query, include, max)
  local overrides = _sandbox_overrides()
  if #overrides == 0 then return base_text end
  local absdir = _abs_norm(dir)
  local overridden = {}
  for _, o in ipairs(overrides) do overridden[o.real] = o.deleted end
  local out, count = {}, 0
  local limit = (max and max > 0) and max or 50
  if base_text ~= "" and base_text ~= "未找到匹配内容" then
    for line in (base_text .. "\n"):gmatch("(.-)\n") do
      if line ~= "" and count < limit then
        local p = line:match("^(.-): ")
        if p and overridden[_abs_norm(p)] == nil then
          out[#out + 1] = line
          count = count + 1
        end
      end
    end
  end
  local inc_pat = ""
  local inc = (include or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if inc ~= "" then
    inc_pat = require("NeoAI.utils.stringx").glob_to_pattern(inc)
  end
  for _, o in ipairs(overrides) do
    if count >= limit then break end
    if not o.deleted then
      local abs = o.real
      local under = abs == absdir or abs:sub(1, #absdir + 1) == absdir .. "/"
      if under and fs.exists(o.staged) then
        local name = vim.fn.fnamemodify(abs, ":t")
        if inc_pat == "" or name:match(inc_pat) then
          local content = fs.read_file(o.staged)
          if content and not content:find("\0", 1, true) then
            local pos = content:find(query, 1, true)
            if pos then
              local snippet = content:sub(pos, pos + 200):gsub("[\n\r]+", " "):gsub("%c", " ")
              out[#out + 1] = abs .. ": " .. snippet
              count = count + 1
            end
          end
        end
      end
    end
  end
  if #out == 0 then return "未找到匹配内容" end
  return table.concat(out, "\n")
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
    local guard = _read_guard_opts()
    local max_bytes = guard.max_read_bytes
    if args.start_line or args.end_line then
      -- 指定行范围：按块逐行读取，不整读大文件，不受大文件保护影响
      _pipe(fs.read_file_lines_async(filepath, args.start_line or 0, args.end_line or 0, max_bytes), on_success, on_error)
      return
    end
    -- 目录不是文件：明确报错，避免静默返回空内容。
    local stat = vim.uv.fs_stat(filepath)
    if stat and stat.type == "directory" then
      on_error("路径是目录，无法作为文件读取: " .. filepath)
      return
    end
    if stat and stat.size and stat.size > max_bytes then
      -- 超大文件：只读前若干行预览，绝不整读，避免 OOM。
      -- 预览仍设独立上限（不小于整读上限），防止单行超长再次撑爆内存。
      local preview_cap = math.max(max_bytes, 256 * 1024)
      local header = string.format(
        "[文件过大] %s 共 %d 字节，超过 %d 字节整读上限，未返回全文。\n"
          .. "请改用 start_line/end_line 读取所需行区间。",
        filepath, stat.size, max_bytes
      )
      _pipe(fs.read_file_lines_async(filepath, 1, guard.outline_preview_lines, preview_cap), function(preview)
        on_success(header .. string.format("\n\n以下为前 %d 行预览：\n%s", guard.outline_preview_lines, preview))
      end, function(err)
        -- 预览读取失败（如单行超长）也不应让整个读取失败，回传提示即可。
        on_success(header .. "\n（预览读取失败: " .. tostring(err) .. "）")
      end)
      return
    end
    -- 无行范围：小文件返回全文；大文件返回语法树大纲（无 parser 时预览）
    _pipe(fs.read_file_async(filepath, max_bytes), function(content)
      on_success(_guarded_content(content, filepath))
    end, on_error)
  end,
  { category = "file" }
)

-- 编辑文件（线程池异步读写）
file_tools.edit_file = helpers.define_tool(
  "edit_file",
  "编辑文件。filepath/description 必填。两种用法互斥："
    .. "(1) 局部替换——提供 edits 数组，或用顶层 old_text+new_text 简写单条替换，均不得传 mode；"
    .. "(2) 整文件覆写或追加——必须显式 mode='write'（覆写）/ mode='append'（追加），并提供 content。"
    .. "替换字段与 mode 同时出现、或提供 content 却省略 mode、或两者皆无，都会直接报错（不静默覆写）。",
  {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      description = { type = "string", description = "修改目的说明（必填，供审批与记录）" },
      mode = {
        type = "string",
        enum = { "write", "append" },
        description = "'write' 整体覆写 | 'append' 追加（与替换字段互斥，须显式提供）",
      },
      content = { type = "string", description = "写入内容（write/append 模式；必须显式指定 mode）" },
      edits = {
        type = "array",
        description = "结构化替换 { old_text, new_text } 数组（与 mode 互斥，不传 mode）",
        items = { type = "object", properties = { old_text = { type = "string" }, new_text = { type = "string" } } },
      },
      old_text = { type = "string", description = "单条替换：被替换文本（须与 new_text 成对，与 mode 互斥）" },
      new_text = { type = "string", description = "单条替换：替换为的文本（须与 old_text 成对，与 mode 互斥）" },
    },
    required = { "filepath", "description" },
  },
  function(args, on_success, on_error)
    local filepath = args.filepath
    local description = args.description
    -- 参数契约（严格互斥，误传即报错，绝不静默降级为覆写）：
    --   · 局部替换：提供 edits（或顶层 old_text/new_text 简写），且不得同时传 mode；
    --   · 整体覆写/追加：显式 mode='write'/'append'，且不得同时传替换字段。
    -- 规则：R1 替换字段与 mode 互斥 / R2 有 content 必须显式 mode / R3 顶层简写须成对 /
    --       R4 无 mode 且无替换字段报错 / R5 mode 仅接受 write/append / R6 content 与替换字段冲突。
    local has_edits = type(args.edits) == "table" and #args.edits > 0
    local has_top = args.old_text ~= nil or args.new_text ~= nil
    local has_content = args.content ~= nil
    local mode = args.mode
    if type(mode) == "string" then mode = mode:lower() end
    local has_mode = type(mode) == "string" and mode ~= ""

    -- R6：content 与替换字段语义冲突
    if has_content and (has_edits or has_top) then
      on_error(
        "edit_file：content（整文件写入内容）与 edits/old_text/new_text（局部替换）不能同时提供"
      )
      return
    end

    -- R1：替换字段与 mode 互斥
    if (has_edits or has_top) and has_mode then
      on_error(
        "edit_file：提供 edits/old_text/new_text（局部替换）时不能同时传 mode；"
          .. "整体覆写/追加请改用 mode='write'/'append' 且不要传替换字段"
      )
      return
    end

    -- R3：顶层 old_text/new_text 必须成对
    if has_top and not (args.old_text ~= nil and args.new_text ~= nil) then
      on_error("edit_file：顶层 old_text 与 new_text 必须成对提供")
      return
    end

    -- R5：mode 仅接受 write/append（消除 replace/edit 等同义词歧义）
    if has_mode and mode ~= "write" and mode ~= "append" then
      on_error(
        ("edit_file：mode 只支持 'write'（整体覆写）或 'append'（追加），收到 '%s'；"
          .. "如需局部替换请改用 edits 数组（或顶层 old_text/new_text）且不要传 mode"):format(tostring(args.mode))
      )
      return
    end

    -- R2：不传 mode 禁止覆写（content 必须显式 mode）
    if has_content and not has_mode then
      on_error(
        "edit_file：提供 content 时必须显式指定 mode='write'（整体覆写）或 mode='append'（追加），"
          .. "不允许省略 mode，以免误覆写整文件"
      )
      return
    end

    -- R4：无 mode 且无替换字段 → 无操作可执行，报错
    if not has_mode and not has_edits and not has_top then
      on_error(
        "edit_file：需要 mode（'write'/'append' 整写/追加）或替换字段（edits 数组 / 顶层 old_text+new_text）"
      )
      return
    end

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

    -- 替换分支：结构化替换（读在子线程，替换与写盘也在子线程）。
    -- 顶层 old_text/new_text 为单条替换简写，等价 edits = { { old_text, new_text } }。
    local edits
    if has_edits then
      edits = args.edits
    else
      edits = { { old_text = args.old_text, new_text = args.new_text } }
    end
    if #edits == 0 then
      on_error("替换需要提供非空 edits 数组（或顶层 old_text/new_text）")
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
    -- 安全默认：递归默认最多 2000 条、非递归单层最多 5000 条。否则对 home/ 等超大目录
    -- 会返回数万行（数 MB）并撑爆模型上下文；显式 max_results 可覆盖（仍受 worker 硬上限钳制）。
    local RECURSIVE_DEFAULT, FLAT_CAP = 2000, 5000
    if not fs.is_dir(dir) then
      -- 真实目录不存在：若沙箱暂存已在其下创建内容，按沙箱视图合成列举（沙箱对 AI 不可见）。
      if not _sandbox_dir_present(dir) then
        on_error("目录不存在: " .. dir)
        return
      end
      on_success(_merge_list("", dir, args.recursive, max))
      return
    end
    if args.recursive then
      local eff_max = (max and max > 0) and max or RECURSIVE_DEFAULT
      _pipe(fs.list_dir_async(dir, eff_max), function(out)
        local n = 0
        for _ in out:gmatch("[^\n]+") do n = n + 1 end
        local text = _merge_list(out, dir, true, eff_max)
        if n >= eff_max then
          text = text .. "\n（递归列举上限 " .. eff_max .. " 条，可用 max_results 调整）"
        end
        on_success(text)
      end, on_error)
      return
    end
    -- 非递归：单层列出。量级很小，直接在主线程用 uv.fs_scandir 完成，
    -- 不依赖工作线程（部分环境下线程内 vim.uv 不可用会静默返回空）。
    local handle = vim.uv.fs_scandir(dir)
    if not handle then
      on_error("无法读取目录: " .. dir)
      return
    end
    local out = {}
    local flat_cap = (max and max > 0) and math.min(max, FLAT_CAP) or FLAT_CAP
    local truncated = false
    while true do
      local name, t = vim.uv.fs_scandir_next(handle)
      if not name then break end
      if #out >= flat_cap then truncated = true break end
      out[#out + 1] = dir .. "/" .. name .. (t == "directory" and "/" or "")
    end
    table.sort(out)
    if max and max > 0 and #out > max then
      local trimmed = {}
      for i = 1, max do trimmed[i] = out[i] end
      out = trimmed
    end
    local text = _merge_list(table.concat(out, "\n"), dir, false, max)
    if truncated then text = text .. "\n（已截断，单层最多 " .. FLAT_CAP .. " 条；可用 max_results 调整）" end
    on_success(text)
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
    local search_cfg = config_store.get("tools.search_files") or {}
    local max_file_bytes = type(search_cfg.max_file_bytes) == "number" and search_cfg.max_file_bytes or nil
    local max_results = args.max_results or 50
    _pipe(fs.search_files_async(dir, args.query, {
      include = args.include,
      max_results = max_results,
      max_file_bytes = max_file_bytes,
    }), function(out)
      on_success(_merge_search(out, dir, args.query, args.include, max_results))
    end, on_error)
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
    local sv = _sandbox_path_exists(args.filepath)
    if sv ~= nil then
      on_success(tostring(sv))
      return
    end
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
    if not fs.exists(args.filepath) then
      on_error("文件不存在: " .. args.filepath)
      return
    end
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
