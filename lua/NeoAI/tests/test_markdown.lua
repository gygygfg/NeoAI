--- markdown_view 渲染测试
--- @module NeoAI.tests.test_markdown
--- 验证：表格按列宽对齐（带上下边框/对齐标记）、非表格行不误渲染、转义竖线、
--- 代码块内表格不被解析、超长内容折行、流式期间原样输出结束后对齐。

local tests = require("NeoAI.tests")

tests.suite("markdown", function(_, it)
  it("表格按列显示宽度对齐并带上下边框（CJK 占 2 列）", function(t)
    local mv = require("NeoAI.ui.components.markdown_view")
    local rendered = mv.render([[
| 工具类别 | 工具 | 状态 | 结果 |
|---------|------|------|------|
| 文件系统 | list_files | ✅ 正常 | 成功列出 /tmp 目录内容 |
| Shell 执行 | run_command | ✅ 正常 | pwd / ls -la 执行成功 |]])

    -- 顶边 + 表头 + 分隔横线 + 2 数据行 + 底边 = 6 行
    t.eq(6, #rendered, ("应输出带上下边框的 6 行表格（实际 %d）"):format(#rendered))
    t.eq("table", rendered[1].style, "顶边应标记为 table")
    t.eq("table", rendered[2].style, "表头行应标记为 table")
    t.eq("table", rendered[4].style, "数据行应标记为 table")
    t.eq("table", rendered[6].style, "底边应标记为 table")

    -- 上下封顶/封底
    t.matches("^┌.+\n?$", rendered[1].text, "顶层应以 ┌…┐ 封顶")
    t.matches("┐$", rendered[1].text, "顶层应以 ┐ 结尾")
    t.matches("^└", rendered[6].text, "底层应以 └…┘ 封底")
    t.matches("┘$", rendered[6].text, "底层应以 ┘ 结尾")
    t.matches("^├", rendered[3].text, "表头/数据间应有分隔横线")
    t.matches("┼", rendered[3].text, "分隔横线应有 ┼ 列交点")
    t.false_(rendered[3].text:find("%-%-%-", 1, true) ~= nil, "分隔横线不应残留字面 ---")

    -- 逐列断言：列分隔符（│）在各行中的显示位置一致 → 列对齐
    local function pipe_cols(line)
      local cols = {}
      local w = 0
      local n = vim.fn.strchars(line)
      for i = 0, n - 1 do
        local ch = vim.fn.strcharpart(line, i, 1)
        if ch == "│" then
          cols[#cols + 1] = w
        else
          w = w + vim.fn.strwidth(ch)
        end
      end
      return cols
    end
    local rows = { rendered[2].text, rendered[4].text, rendered[5].text }
    local ref = pipe_cols(rows[1])
    for k = 2, #rows do
      local cur = pipe_cols(rows[k])
      t.eq(#ref, #cur, "各行列数应一致")
      for ci = 1, #ref do
        t.eq(ref[ci], cur[ci], ("第 %d 列分隔位置应一致"):format(ci))
      end
    end
  end)

  it("表格按对齐标记渲染（左/居中/右）", function(t)
    local mv = require("NeoAI.ui.components.markdown_view")
    local rendered = mv.render([[| 左对齐 | 居中对齐 | 右对齐 |
| :----- | :------: | ------: |
| a | b | c |
| 很长的内容 | 中等 | 1 |]])
    -- 左列左对齐、中列居中、右列右对齐（内容位置由列宽决定）
    t.eq("│ a          │    b     │      c │", rendered[4].text, "左对齐靠左、居中居中、右对齐靠右")
    t.eq("│ 很长的内容 │   中等   │      1 │", rendered[5].text, "超宽文本左对齐、右列数字右对齐")
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
    t.matches("a | b", rendered[2].text, "转义竖线应保留在单元格内")
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
    t.eq("list", rendered[9].style, "列表应正常渲染")
    t.eq("normal", rendered[11].style, "普通段落应正常渲染")
  end)

  it("to_plain 输出带上下边框的对齐表格文本", function(t)
    local mv = require("NeoAI.ui.components.markdown_view")
    local plain = mv.to_plain("| A | B |\n|---|----|\n| 1 | 22 |")
    local lines = vim.split(plain, "\n", { plain = true })
    t.eq(5, #lines, "应保留 5 行（顶边+表头+分隔+数据+底边）")
    t.matches("^┌", lines[1], "顶边应以 ┌ 开头")
    t.matches("^│ A ", lines[2], "表头应以对齐后的 │ 开头")
    t.matches("^├", lines[3], "分隔行应渲染为 ├─┼─┤ 分隔")
    t.matches("^└", lines[5], "底边应以 └ 开头")
  end)

  it("超长内容按列宽折行显示，整行等高且输出有界", function(t)
    local mv = require("NeoAI.ui.components.markdown_view")
    local long = string.rep("数据内容", 100) -- 400 字符，显示宽度 800，折行后远超 MAX_CELL_LINES
    local rendered = mv.render("| 列A | 列B |\n| --- | --- |\n| " .. long .. " | short |\n| b | c |")

    t.eq("table", rendered[1].style, "应识别为表格")
    -- 顶边(1) + 表头(1) + 分隔横线(1) + 超长行折行(MAX_CELL_LINES=8) + 短行(1) + 底边(1) = 13
    t.eq(13, #rendered, ("超长行应按 MAX_CELL_LINES 折行，总行数有界（实际 %d）"):format(#rendered))
    -- 每行长度受列宽上限约束（不能是几十万字节的巨长行），且不含完整超长单元格
    local has_ell = false
    for _, l in ipairs(rendered) do
      t.true_(#l.text < 1000, "单行长度应有界（实际 " .. #l.text .. " 字节）")
      t.false_(l.text:find(long, 1, true) ~= nil, "渲染行不应包含完整超长单元格")
      if l.text:find("…", 1, true) then has_ell = true end
    end
    t.true_(has_ell, "超长折行应以 … 截断")
    -- 分隔横线与后续短行仍正确渲染
    t.matches("^├", rendered[3].text, "分隔横线应正常渲染")
    t.matches("b", rendered[12].text, "短内容行应保留")
  end)

  it("表格输出带斑马纹标记（border/odd/even 交替）", function(t)
    local mv = require("NeoAI.ui.components.markdown_view")
    local rendered = mv.render("| A | B |\n|---|----|\n| 1 | 22 |\n| x | yy |")
    t.eq("border", rendered[1].tbl, "顶边标记为 border")
    t.eq("odd", rendered[2].tbl, "表头内容行标记为 odd")
    t.eq("border", rendered[3].tbl, "表头分隔横线标记为 border")
    t.eq("even", rendered[4].tbl, "数据行标记为 even")
    t.eq("odd", rendered[5].tbl, "第二数据行标记为 odd")
    t.eq("border", rendered[6].tbl, "底边标记为 border")
  end)

  it("超长折行截断末行不超出列宽，避免破坏对齐", function(t)
    local mv = require("NeoAI.ui.components.markdown_view")
    local long = string.rep("abcdefghij", 60) -- 600 显示宽度，远超 60*8 行上限
    local rendered = mv.render("| 列A | 列B |\n| --- | --- |\n| " .. long .. " | short |\n| b | c |")
    -- 顶边(1)+表头(1)+分隔(1)+超长行折行(8)+短行(1)+底边(1) = 13
    t.eq(13, #rendered, ("总行数应有界（实际 %d）"):format(#rendered))
    -- 每行显示宽度一致（截断末行含 … 也不得溢出破坏对齐）
    local topw = vim.fn.strwidth(rendered[1].text)
    for _, l in ipairs(rendered) do
      t.true_(vim.fn.strwidth(l.text) <= topw, ("单行宽度不得超表宽（实际 %d/%d）"):format(vim.fn.strwidth(l.text), topw))
    end
    t.matches("…", rendered[11].text, "折行末行应以 … 截断")
  end)

  it("表格宽度随 table_width 自适应，窄窗更多折行且不超上限", function(t)
    local mv = require("NeoAI.ui.components.markdown_view")
    local long = string.rep("无空格长文abcdefghijklmn", 3) -- 不触顶折行上限，能体现折行数差异
    local text = "| 字段 | 内容 |\n| --- | --- |\n| 极长字段 | " .. long .. " |\n| b | c |"
    local function stats(opts)
      local r = mv.render(text, opts)
      local m = 0
      for _, l in ipairs(r) do m = math.max(m, vim.fn.strwidth(l.text)) end
      return m, #r
    end
    local w40, n40 = stats({ table_width = 40 })
    local w80, n80 = stats({ table_width = 80 })
    t.true_(w40 <= 40, ("窄窗表宽应有界（实际 %d）"):format(w40))
    t.true_(w80 <= 80, ("宽窗表宽应有界（实际 %d）"):format(w80))
    t.true_(w40 < w80, "窗口越窄表格应越窄以放得下")
    t.true_(n40 > n80, "窗口越窄折行应更多（行数更多）")
  end)

  it("流式生成期间表格原样输出，结束才做对齐填充", function(t)
    local mv = require("NeoAI.ui.components.markdown_view")
    local raw = "| A | B |\n| --- | --- |\n| 1 | 22 |"

    local streamed = mv.render(raw, { streaming = true })
    t.eq("table", streamed[1].style, "流式期间仍应识别为表格")
    t.eq("| A | B |", streamed[1].text, "流式期间表头应原样（不填充空格）")
    t.eq("| --- | --- |", streamed[2].text, "流式期间分隔行应原样")
    t.eq("| 1 | 22 |", streamed[3].text, "流式期间数据行应原样")

    -- 生成结束后（非 streaming）才对齐填充，并带上下边框
    local lines = vim.split(mv.to_plain(raw), "\n", { plain = true })
    t.eq(5, #lines, "结束后应为带边框的 5 行")
    t.matches("^┌", lines[1], "结束后应先有顶边封顶")
    t.matches("^│ A ", lines[2], "结束后表头应对齐补空格")
    t.matches("^└", lines[5], "结束后应有底边封底")
  end)
end)
