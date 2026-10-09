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
    -- 某些后端/版本对过小的 columns/lines 直接报错（E593）而非 clamp，这里容错赋值，
    -- 失败时保留原值；用例内以运行时实际 vim.o.columns/lines 为准。
    pcall(function() vim.o.columns = cols end)
    pcall(function() vim.o.lines = lines end)
    local ok, err = pcall(body)
    pcall(function() vim.o.columns = old_cols end)
    pcall(function() vim.o.lines = old_lines end)
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

  it("全局最小尺寸兜底：比例算出的过小尺寸被抬到默认最小", function(t)
    on_screen(300, 100, function()
      -- w=floor(300*0.02)=6、h=floor(100*0.01)=1，均应被抬到默认最小（宽/高）。
      local g = geometry.compute({ w_ratio = 0.02, h_ratio = 0.01 })
      t.eq(geometry.MIN_WIDTH, g.width)
      t.eq(geometry.MIN_HEIGHT, g.height)
    end)
  end)

  it("显式 min 覆盖默认；传 0 可解除默认下限", function(t)
    on_screen(300, 100, function()
      local g = geometry.compute({ w_ratio = 0.02, h_ratio = 0.01, min_w = 10, min_h = 2 })
      t.eq(10, g.width)
      t.eq(2, g.height)

      local g0 = geometry.compute({ w_ratio = 0.02, h_ratio = 0.01, min_w = 0, min_h = 0 })
      t.eq(6, g0.width)
      t.eq(1, g0.height)
    end)
  end)

  it("track + refresh：窗口几何按新屏幕尺寸重算", function(t)
    on_screen(200, 50, function()
      local buf = vim.api.nvim_create_buf(false, true)
      local g = geometry.compute({ w_ratio = 0.5, h_ratio = 0.4 })
      local win = vim.api.nvim_open_win(buf, false, {
        relative = "editor", width = g.width, height = g.height, col = g.col, row = g.row, style = "minimal",
      })
      geometry.track(win, { w_ratio = 0.5, h_ratio = 0.4 })
      -- 屏幕变小：refresh 后窗口宽高应跟随重算。
      vim.o.columns, vim.o.lines = 100, 40
      geometry.refresh()
      local cfg = vim.api.nvim_win_get_config(win)
      local expect = geometry.compute({ w_ratio = 0.5, h_ratio = 0.4 })
      t.eq(expect.width, cfg.width)
      t.eq(expect.height, cfg.height)
      t.eq(expect.col, cfg.col)
      t.eq(expect.row, cfg.row)
      geometry.untrack(win)
      pcall(vim.api.nvim_win_close, win, true)
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end)
  end)

  it("untrack 后 refresh 不再更新窗口几何", function(t)
    on_screen(200, 50, function()
      local buf = vim.api.nvim_create_buf(false, true)
      local win = vim.api.nvim_open_win(buf, false, {
        relative = "editor", width = 40, height = 8, col = 0, row = 0, style = "minimal",
      })
      geometry.track(win, { w_ratio = 0.5, h_ratio = 0.4 })
      geometry.untrack(win)
      vim.o.columns, vim.o.lines = 120, 40
      geometry.refresh()
      local cfg = vim.api.nvim_win_get_config(win)
      t.eq(40, cfg.width)
      t.eq(8, cfg.height)
      pcall(vim.api.nvim_win_close, win, true)
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end)
    geometry.reset()
  end)
end)
