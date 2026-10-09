--- 浮窗几何计算测试
--- @module NeoAI.tests.test_geometry

local tests = require("NeoAI.tests")

tests.suite("geometry", function(_, it)
  local geometry = require("NeoAI.ui.geometry")

  --- 在指定的屏幕尺寸下运行 body（临时改 vim.o.columns/lines），结束后恢复。
  --- @param cols number
  --- @param lines number
  --- @param body function
  local function on_screen(cols, lines, body)
    local old_cols, old_lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = cols, lines
    local ok, err = pcall(body)
    vim.o.columns, vim.o.lines = old_cols, old_lines
    if not ok then error(err) end
  end

  it("按比例计算宽度与高度", function(t)
    on_screen(200, 50, function()
      local g = geometry.compute({ w_ratio = 0.5, h_ratio = 0.4 })
      t.eq(100, g.width)
      t.eq(20, g.height)
    end)
  end)

  it("col 恒居中、row 居中", function(t)
    on_screen(200, 50, function()
      local g = geometry.compute({ w_ratio = 0.5, h_ratio = 0.4 })
      t.eq(math.floor((200 - g.width) / 2), g.col)
      t.eq(math.floor((50 - g.height) / 2), g.row)
    end)
  end)

  it("fit_h 仅压不撑：内容小于比例高度时取内容高度", function(t)
    on_screen(200, 50, function()
      local g = geometry.compute({ w_ratio = 0.5, h_ratio = 0.6, fit_h = 7 })
      t.eq(7, g.height)
    end)
  end)

  it("fit_h 超过比例高度时不放大", function(t)
    on_screen(200, 50, function()
      local g = geometry.compute({ w_ratio = 0.5, h_ratio = 0.4, fit_h = 40 })
      t.eq(20, g.height)
    end)
  end)

  it("min/max 夹紧尺寸", function(t)
    on_screen(200, 50, function()
      local g = geometry.compute({ w_ratio = 0.01, h_ratio = 0.01, min_w = 30, max_w = 60, min_h = 5, max_h = 12 })
      t.eq(30, g.width)
      t.eq(5, g.height)

      local g2 = geometry.compute({ w_ratio = 0.9, h_ratio = 0.9, max_w = 60, max_h = 12 })
      t.eq(60, g2.width)
      t.eq(12, g2.height)
    end)
  end)

  it("margin 留白：宽高不超过可用区域", function(t)
    on_screen(40, 20, function()
      local g = geometry.compute({ w_ratio = 1.0, h_ratio = 1.0, margin = 2 })
      t.eq(40 - 2 * 2, g.width)
      t.eq(20 - 2 * 2, g.height)
    end)
  end)

  it("anchor=top/bottom 的行位置", function(t)
    on_screen(200, 50, function()
      local gtop = geometry.compute({ w_ratio = 0.5, h_ratio = 0.2, anchor = "top", margin = 2 })
      t.eq(2, gtop.row)
      local gbot = geometry.compute({ w_ratio = 0.5, h_ratio = 0.2, anchor = "bottom", margin = 2 })
      t.eq(50 - gbot.height - 2, gbot.row)
    end)
  end)

  it("显式 row 覆盖 anchor", function(t)
    on_screen(200, 50, function()
      local g = geometry.compute({ w_ratio = 0.5, h_ratio = 0.2, anchor = "bottom", row = 3 })
      t.eq(3, g.row)
    end)
  end)

  it("极端小屏不越界（宽高 >=1 且在屏内）", function(t)
    on_screen(3, 2, function()
      -- 不同后端/环境可能对 columns/lines 做最小化 clamp，故以运行时实际值为准。
      local cols, lines = vim.o.columns, vim.o.lines
      t.true_(cols >= 1 and lines >= 1, "屏幕尺寸至少为 1x1")
      local g = geometry.compute({ w_ratio = 0.9, h_ratio = 0.9 })
      t.true_(g.width >= 1 and g.width <= cols, "宽度应在 [1,cols]")
      t.true_(g.height >= 1 and g.height <= lines, "高度应在 [1,lines]")
      t.true_(g.col >= 0 and g.col + g.width <= cols, "col 应在屏内")
      t.true_(g.row >= 0 and g.row + g.height <= lines, "row 应在屏内")
    end)
  end)
end)
