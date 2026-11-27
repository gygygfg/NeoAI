--- 沙箱待审改动 → buffer 行内 diff 回归
--- @module 'NeoAI.tests.test_pending_diff'
--- 覆盖：AI 增量绘制 extmark、纯 buffer 基线不误报、NeoAI UI buffer 跳过、完整 diff 打开。
local tests = require("NeoAI.tests")

local function with_cfg(fn)
  local config_store = require("NeoAI.kernel.config_store")
  local saved = config_store.get_all()
  local merged = vim.deepcopy(saved or {})
  merged.tools = merged.tools or {}
  merged.tools.sandbox = merged.tools.sandbox or {}
  merged.tools.sandbox.workspace_root = vim.fn.tempname() .. "/sb"
  merged.tools.sandbox.postprocess = "sync"
  merged.tools.sandbox.observe = { enabled = false }
  merged.tools.sandbox.single_view = true
  merged.ui = merged.ui or {}
  merged.ui.pending_diff = {
    enabled = true, max_bytes = 1024 * 1024, debounce_ms = 5, virtual_added_lines = 3, auto = true,
  }
  config_store.load(merged)
  local sandbox = require("NeoAI.sandbox")
  sandbox.reset()
  local ok, err = pcall(fn)
  sandbox.reset()
  config_store.load(saved)
  if not ok then error(err, 0) end
end

local function hash(s)
  return "sha256:" .. vim.fn.sha256(s)
end

tests.suite("pending_diff", function(_, it)
  it("AI 增量绘制行高亮/sign；纯 buffer 基线与 UI buffer 不绘制", function(t)
    local fs = require("NeoAI.utils.fs")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local pd = require("NeoAI.ui.components.pending_diff")
    local ns = vim.api.nvim_create_namespace("neoai_pending_diff")
    with_cfg(function()
      local dir = vim.fn.tempname()
      fs.ensure_dir(dir)
      local p = dir .. "/a.lua"
      fs.write_file(p, "a\nb\nc\n")
      vim.cmd("edit " .. vim.fn.fnameescape(p))
      local buf = vim.api.nvim_get_current_buf()
      local seed = "a\nB\nc\n"
      candidate.seed_buffer(p, seed, { tick = 1, bufnr = buf, disk_hash = hash("a\nb\nc\n") })
      -- 只有 save-all 基线：不显示
      t.false_(pd.refresh(buf), "无 AI 增量时不应绘制")
      t.eq(0, #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}))
      -- AI 改动：修改 + 新增
      local info = candidate.buffer_seed_info(p)
      fs.write_file(info.staged, "a\nB2\nc\nd\n")
      t.true_(pd.refresh(buf), "有 AI 增量时应绘制")
      local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
      t.true_(#marks >= 1, "应写入 diff extmark")
      local has_sign = false
      for _, m in ipairs(marks) do
        local d = m[4] or {}
        if d.sign_text or d.virt_lines then has_sign = true end
      end
      t.true_(has_sign, "extmark 应包含 sign 或 virt_lines")
      -- NeoAI UI buffer 跳过
      local ui = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(ui, 0, -1, false, { "ui" })
      vim.bo[ui].filetype = "neoai_input"
      t.false_(pd.refresh(ui), "NeoAI UI buffer 不应绘制")
      pcall(vim.api.nvim_buf_delete, ui, { force = true })
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end)
  end)

  it("完整 diff 打开只读分屏", function(t)
    local fs = require("NeoAI.utils.fs")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local pd = require("NeoAI.ui.components.pending_diff")
    with_cfg(function()
      local dir = vim.fn.tempname()
      fs.ensure_dir(dir)
      local p = dir .. "/b.lua"
      fs.write_file(p, "x\ny\n")
      vim.cmd("edit " .. vim.fn.fnameescape(p))
      local buf = vim.api.nvim_get_current_buf()
      candidate.seed_buffer(p, "x\nY\n", { tick = 1, bufnr = buf, disk_hash = hash("x\ny\n") })
      local info = candidate.buffer_seed_info(p)
      fs.write_file(info.staged, "x\nY\nz\n")
      local before = #vim.api.nvim_list_wins()
      pd.open(buf)
      t.true_(#vim.api.nvim_list_wins() > before, "应打开 diff 分屏")
      -- 关闭所有非当前窗口，避免影响后续测试
      vim.cmd("only")
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end)
  end)
end)
