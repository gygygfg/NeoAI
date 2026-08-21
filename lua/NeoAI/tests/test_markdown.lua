--- markdown_view 渲染测试
--- @module NeoAI.tests.test_markdown
--- 验证：表格按列宽对齐、非表格行不误渲染、转义竖线、代码块内表格不被解析。

local tests = require("NeoAI.tests")

tests.suite("markdown", function(_, it)
  it("表格按列显示宽度对齐（CJK 占 2 列）", function(t)
    local mv = require("NeoAI.ui.components.markdown_view")
    local rendered = mv.render([[
| 工具类别 | 工具 | 状态 | 结果 |
|---------|------|------|------|
| 文件系统 | list_files | ✅ 正常 | 成功列出 /tmp 目录内容 |
| Shell 执行 | run_command | ✅ 正常 | pwd / ls -la 执行成功 |]])

    t.eq("table", rendered[1].style, "表头行应标记为 table")
    t.eq("table", rendered[3].style, "数据行应标记为 table")

    -- 逐列断言：同一列内容在各行中的起始列一致（按显示宽度）
    local function col_start(line, col_idx)
      -- 拆出单元格文本（保留左侧空格以推算起始位置）
      local cells = {}
      for c in line:gmatch("[^|]+") do
        cells[#cells + 1] = c
      end
      local pos = 1
      for ci = 1, col_idx - 1 do
        pos = pos + vim.fn.strwidth(cells[ci]) + 3
      end
      return pos
    end

    local rows = { rendered[1].text, rendered[3].text, rendered[4].text }
    for ci = 1, 4 do
      local starts = {}
      for _, l in ipairs(rows) do
        starts[#starts + 1] = col_start(l, ci)
      end
      for k = 2, #starts do
        t.eq(starts[1], starts[k], ("第 %d 列各行起始列应一致"):format(ci))
      end
    end

    -- 分隔行由 ─ 组成且不残留 ---
    t.matches("^| ─", rendered[2].text, "分隔行应以 ─ 开头")
    t.false_(rendered[2].text:find("%-%-%-", 1, true) ~= nil, "分隔行不应残留字面 ---")
  end)

  it("无分隔行的单行含 | 不当作表格渲染", function(t)
    local mv = require("NeoAI.ui.components.markdown_view")
    local rendered = mv.render("| 单行 | 不是表格 |")
    t.eq("normal", rendered[1].style, "缺少分隔行时不应对齐渲染")
    t.eq("| 单行 | 不是表格 |", rendered[1].text, "应保持原始行文本")
  end)

  it("转义竖线 \\| 不被当作列分隔符", function(t)
    local mv = require("NeoAI.ui.components.markdown_view")
    local rendered = mv.render([[| a \| b | c |
|---| --- |
| 1 | 2 |]])
    t.eq("table", rendered[1].style, "应识别为表格")
    t.matches("a | b", rendered[1].text, "转义竖线应保留在单元格内")
    t.matches("^%| a %| b ", rendered[1].text, "单元格 a | b 应作为第一列对齐渲染")
  end)

  it("代码块内的表格行不被解析", function(t)
    local mv = require("NeoAI.ui.components.markdown_view")
    local rendered = mv.render([[
```txt
| 原始 | 内容 |
|------|------|
| 1 | 2 |
```]])
    t.eq("code", rendered[2].style, "代码块内首行应保持 code 样式")
    t.eq("| 原始 | 内容 |", rendered[2].text, "代码块内表格行应原样保留（不解析）")
    t.eq("code", rendered[4].style, "代码块内数据行应保持 code 样式")
  end)

  it("表格渲染不打断标题/列表/普通段落", function(t)
    local mv = require("NeoAI.ui.components.markdown_view")
    local rendered = mv.render([[
# 标题

| A | B |
|---|----|
| 1 | 22 |

- 列表项

普通段落]])
    -- [[...]] 会跳过紧随其后的首个换行，实际内容从第 1 行开始
    t.eq("heading", rendered[1].style, "标题应正常渲染")
    t.eq("table", rendered[3].style, "表格应正常渲染")
    t.eq("list", rendered[7].style, "列表应正常渲染")
    t.eq("normal", rendered[9].style, "普通段落应正常渲染")
  end)

  it("to_plain 输出对齐后的表格文本", function(t)
    local mv = require("NeoAI.ui.components.markdown_view")
    local plain = mv.to_plain("| A | B |\n|---|----|\n| 1 | 22 |")
    local lines = vim.split(plain, "\n", { plain = true })
    t.eq(3, #lines, "应保留 3 行")
    t.matches("^%| A ", lines[1], "表头应以对齐后的 | 开头")
    t.matches("^%| %s*─", lines[2], "分隔行应渲染为 ─ 分隔")
  end)
end)