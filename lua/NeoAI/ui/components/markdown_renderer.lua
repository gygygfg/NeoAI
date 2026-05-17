--- NeoAI Markdown 渲染器
--- 职责：将 markdown 文本格式化为可读的纯文本，并提供 extmark 语法高亮
--- 格式化规则：
---   - # 标题 → 去掉 #，用 === 下划线装饰
---   - **粗体** → 去掉 **
---   - *斜体* → 去掉 *
---   - `行内代码` → 保留内容
---   - ```代码块``` → 用 ┌─ └─ 边框包裹，添加语言标签
---   - > 引用 → 添加 │ 前缀
---   - - 列表 → 保留
---   - 数字列表 → 保留
---   - 链接 [text](url) → text [url]
---   - 分割线 --- → ──────────────

local M = {}

-- extmark 命名空间
local ns_id = nil

--- 初始化命名空间
function M.initialize()
  if ns_id then
    return
  end
  ns_id = vim.api.nvim_create_namespace("NeoAIMarkdown")
end

--- 将 markdown 文本格式化为可读的纯文本行列表
--- @param text string markdown 文本
--- @return table 格式化后的行列表
function M.format_text(text)
  if not text or text == "" then
    return { "" }
  end

  local lines = vim.split(text, "\n")
  local result = {}
  local in_code_block = false
  local code_block_lang = ""
  local code_block_lines = {}

  for _, raw_line in ipairs(lines) do
    -- 处理代码块
    if raw_line:match("^```") then
      if in_code_block then
        -- 结束代码块
        table.insert(result, "└─ " .. code_block_lang)
        table.insert(result, "")
        code_block_lines = {}
        in_code_block = false
        code_block_lang = ""
      else
        -- 开始代码块
        in_code_block = true
        code_block_lang = raw_line:match("^```(%S*)") or ""
        local lang_label = (code_block_lang ~= "" and code_block_lang) or "code"
        table.insert(result, "┌─ " .. lang_label .. " ─────────────────────")
      end
      goto continue
    end

    if in_code_block then
      table.insert(result, "│ " .. raw_line)
      goto continue
    end

    local formatted = M._format_inline(raw_line)
    table.insert(result, formatted)

    ::continue::
  end

  -- 如果代码块未闭合，补上结束标记
  if in_code_block then
    table.insert(result, "└─ " .. code_block_lang)
  end

  return result
end

--- 格式化单行（处理行内标记）
--- @param line string 原始行
--- @return string 格式化后的行
function M._format_inline(line)
  if not line or line == "" then
    return ""
  end

  local result = line

  -- 处理标题
  result = result:gsub("^#{1,6}%s+", "")

  -- 处理分割线
  if result:match("^[-*_]{3,}$") then
    return "────────────────────────────────"
  end

  -- 处理引用
  result = result:gsub("^>%s*", "│ ")

  -- 处理链接 [text](url) → text [url]
  result = result:gsub("%[([^%]]*)%]%(([^%)]*)%)", function(text, url)
    if url ~= "" then
      return text .. " [" .. url .. "]"
    end
    return text
  end)

  -- 处理图片 ![alt](url)
  result = result:gsub("!%[([^%]]*)%]%(([^%)]*)%)", function(alt, _)
    return "🖼 " .. alt
  end)

  -- 去掉 **粗体** 标记
  result = result:gsub("%*%*(.-)%*%*", function(t) return t end)

  -- 去掉 *斜体* 标记
  result = result:gsub("%*(.-)%*", function(t) return t end)

  -- 去掉 ~~删除线~~ 标记
  result = result:gsub("~~(.-)~~", function(t) return t end)

  -- 去掉 `行内代码` 标记
  result = result:gsub("`([^`]+)`", function(t) return t end)

  return result
end

--- 对 buffer 中的 markdown 内容应用 extmark 语法高亮
--- @param buf number buffer 句柄
--- @param start_line number 起始行（0-based），默认 0
--- @param end_line number|nil 结束行（0-based），默认 nil 表示到末尾
function M.apply_highlights(buf, start_line, end_line)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if not ns_id then
    M.initialize()
  end

  -- 清理旧的 extmark
  local clear_end = end_line or -1
  vim.api.nvim_buf_clear_namespace(buf, ns_id, start_line or 0, clear_end)

  local line_count = vim.api.nvim_buf_line_count(buf)
  local s_line = start_line or 0
  local e_line = end_line or (line_count - 1)

  local in_code_block = false

  for i = s_line, e_line do
    local line = vim.api.nvim_buf_get_lines(buf, i, i + 1, false)[1] or ""

    -- 代码块边框（┌─ └─ │）
    if line:match("^[┌└]─") then
      vim.api.nvim_buf_set_extmark(buf, ns_id, i, 0, {
        hl_group = "Special",
        hl_eol = true,
        end_line = i + 1,
      })
      if line:match("^┌─") then
        in_code_block = true
      elseif line:match("^└─") then
        in_code_block = false
      end
      goto continue
    end

    if in_code_block then
      -- 代码块内容
      vim.api.nvim_buf_set_extmark(buf, ns_id, i, 0, {
        hl_group = "String",
        hl_eol = true,
        end_line = i + 1,
      })
      goto continue
    end

    -- 标题行（以 # 开头或 === 下划线）
    if line:match("^#{1,6}%s") or line:match("^===+$") or line:match("^---+$") then
      vim.api.nvim_buf_set_extmark(buf, ns_id, i, 0, {
        hl_group = "Title",
        hl_eol = true,
        end_line = i + 1,
      })
      goto continue
    end

    -- 引用行（以 │ 开头）
    if line:match("^│ ") then
      vim.api.nvim_buf_set_extmark(buf, ns_id, i, 0, {
        hl_group = "Comment",
        hl_eol = true,
        end_line = i + 1,
      })
      goto continue
    end

    -- 列表项（以 - * 或数字开头）
    if line:match("^%s*[-*]%s") or line:match("^%s*%d+[%.%)]%s") then
      vim.api.nvim_buf_set_extmark(buf, ns_id, i, 0, {
        hl_group = "Special",
        hl_eol = true,
        end_line = i + 1,
      })
      goto continue
    end

    -- 分割线
    if line:match("^─+$") then
      vim.api.nvim_buf_set_extmark(buf, ns_id, i, 0, {
        hl_group = "NonText",
        hl_eol = true,
        end_line = i + 1,
      })
      goto continue
    end

    -- 行内代码（`code`）高亮
    for col_start, col_end in line:gmatch("()`[^`]+`()") do
      vim.api.nvim_buf_set_extmark(buf, ns_id, i, col_start - 1, {
        hl_group = "String",
        end_col = col_end - 1,
      })
    end

    -- 链接 [text](url) 高亮
    for col_start, col_end in line:gmatch("()%[[^%]]*%]%([^%)]*%)()") do
      vim.api.nvim_buf_set_extmark(buf, ns_id, i, col_start - 1, {
        hl_group = "Underlined",
        end_col = col_end - 1,
      })
    end

    ::continue::
  end
end

--- 清理 buffer 中的 markdown 高亮
--- @param buf number buffer 句柄
function M.clear_highlights(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if not ns_id then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
end

return M
