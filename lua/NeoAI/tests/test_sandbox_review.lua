--- 沙箱待审审批界面测试
--- @module NeoAI.tests.test_sandbox_review
--- 覆盖：路径级别分类、按级别高亮标记、黄色「待审」标签、渲染与行映射。

local tests = require("NeoAI.tests")

tests.suite("sandbox_review", function(_, it)
  it("level_of 按工作区/用户目录/系统分类", function(t)
    local sr = require("NeoAI.ui.components.sandbox_review")
    local cwd = vim.fn.getcwd()
    t.eq("workspace", sr.level_of(cwd .. "/src/a.lua"), "工作区文件应为 workspace")
    t.eq("user", sr.level_of(vim.fn.expand("~") .. "/notes/x.txt"), "用户目录文件应为 user")
    t.eq("system", sr.level_of("/etc/hosts"), "系统路径应为 system")
  end)

  it("build_lines 标记文件级别与黄色「待审」标签", function(t)
    local sr = require("NeoAI.ui.components.sandbox_review")
    local cwd = vim.fn.getcwd()
    local items = {
      {
        change_set_id = "cs1",
        tool = "edit_file",
        files = {
          { path = cwd .. "/src/a.lua", action = "modify" },
          { path = vim.fn.expand("~") .. "/.config/nvim/init.lua", action = "modify" },
          { path = "/etc/nginx/nginx.conf", action = "create" },
        },
      },
    }
    local data = sr.build_lines(items)
    t.true_(#data.lines > 0, "应产生展示行")

    local pending, ws, usr, sys
    for _, m in ipairs(data.marks) do
      if m.level == "pending" then pending = m end
      if m.level == "workspace" then ws = m end
      if m.level == "user" then usr = m end
      if m.level == "system" then sys = m end
    end
    t.not_nil(pending, "应有「待审」标签高亮")
    t.eq("待审", data.lines[pending.line]:sub(pending.start_col + 1, pending.end_col),
      "「待审」标签范围应精确")
    t.not_nil(ws, "工作区文件应有高亮标记")
    t.not_nil(usr, "用户目录文件应有高亮标记")
    t.not_nil(sys, "系统文件应有高亮标记")

    local file_line
    for ln, target in pairs(data.line_to_target) do
      if target.path == cwd .. "/src/a.lua" then file_line = ln end
    end
    t.not_nil(file_line, "文件行应映射到目标")
    t.eq("cs1", data.line_to_target[file_line].change_set_id)
  end)

  it("build_lines 将含换行的路径/命令压成单行（防 E5108）", function(t)
    local sr = require("NeoAI.ui.components.sandbox_review")
    local data = sr.build_lines({
      {
        change_set_id = "cs\n3",
        tool = "run_shell",
        kind = "host_op",
        write_set = { "echo a\necho b" },
      },
      {
        change_set_id = "cs4",
        tool = "edit_file",
        files = { { path = "/tmp/a\nb.lua", action = "mod\nify" } },
      },
    })
    for _, line in ipairs(data.lines) do
      t.eq(nil, line:find("[\r\n]"), "每行不得含换行符")
    end
  end)

  it("build_lines 头行=整单元审批，文件行=单文件审批", function(t)
    local sr = require("NeoAI.ui.components.sandbox_review")
    local cwd = vim.fn.getcwd()
    local data = sr.build_lines({
      {
        change_set_id = "cs2",
        tool = "edit_file",
        files = {
          { path = cwd .. "/a.lua", action = "modify" },
          { path = cwd .. "/b.lua", action = "modify" },
        },
      },
    })
    local header_line
    for ln, line in ipairs(data.lines) do
      if line:find("cs2", 1, true) then header_line = ln end
    end
    t.not_nil(header_line, "应有头行")
    t.not_nil(data.line_to_target[header_line], "头行应参与整单元审批")
    t.eq(true, data.line_to_target[header_line].whole, "头行应为整单元目标")
    local mapped = 0
    for _ in pairs(data.line_to_target) do mapped = mapped + 1 end
    t.eq(3, mapped, "头行 + 两个文件行")
  end)

  it("build_lines 包安装标注管理器与包名", function(t)
    local sr = require("NeoAI.ui.components.sandbox_review")
    local cwd = vim.fn.getcwd()
    local data = sr.build_lines({
      {
        change_set_id = "cs_pkg",
        tool = "run_command",
        package = true,
        package_manager = "npm",
        package_names = { "express", "lodash" },
        files = { { path = cwd .. "/node_modules/express/index.js", action = "create" } },
      },
    })
    local text = table.concat(data.lines, "\n")
    t.true_(text:find("包安装 npm: express, lodash", 1, true) ~= nil, "头行应标注管理器与包名，实际: " .. text)
  end)

  it("build_lines 展示越界访问留痕区（仅记录）", function(t)
    local sr = require("NeoAI.ui.components.sandbox_review")
    local data = sr.build_lines({}, {
      { trace_id = "t1", tool = "read_file", path = "/root/other/x.txt" },
      { trace_id = "t2", tool = "run_command", path = "/root/proj2/y.lua" },
    })
    local text = table.concat(data.lines, "\n")
    t.matches("越界访问留痕", text, "应展示留痕区标题")
    t.true_(text:find("/root/other/x.txt", 1, true) ~= nil, "应展示越界路径")
    t.true_(text:find("read_file", 1, true) ~= nil, "应展示工具名")
    -- 留痕行不参与审批（无行映射）
    for _, tgt in pairs(data.line_to_target) do
      t.true_(tgt.change_set_id ~= nil, "留痕行不应映射为审批目标")
    end
  end)

  it("open 仅有越界留痕时也能打开审批窗", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    sr.reset()
    local saved = services.use("services.sandbox")
    services.provide("services.sandbox", {
      list_reviews = function() return {} end,
      list_traces = function() return { { tool = "read_file", path = "/root/other/x.txt" } } end,
      apply = function() return { ok = true } end,
      reject = function() end,
    })
    sr.open()
    t.not_nil(sr.get_buf(), "仅有留痕也应打开审批窗")
    local text = table.concat(vim.api.nvim_buf_get_lines(sr.get_buf(), 0, -1, false), "\n")
    t.matches("越界访问留痕", text, "应展示留痕区")
    sr.close()
    services.provide("services.sandbox", saved)
  end)

  it("open 渲染待审界面并应用高亮，apply 走文件级目标", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    sr.reset()
    local saved = services.use("services.sandbox")
    local cwd = vim.fn.getcwd()
    services.provide("services.sandbox", {
      list_reviews = function()
        return {
          { change_set_id = "cs9", tool = "edit_file", files = { { path = cwd .. "/x.lua", action = "modify" } } },
        }
      end,
      apply = function() return { ok = true } end,
      reject = function() end,
    })

    sr.open()
    t.not_nil(sr.get_buf(), "应创建审批 buffer")
    local lines = vim.api.nvim_buf_get_lines(sr.get_buf(), 0, -1, false)
    t.true_(table.concat(lines, "\n"):find("待审", 1, true) ~= nil, "应显示待审标签")
    t.true_(table.concat(lines, "\n"):find(cwd .. "/x.lua", 1, true) ~= nil, "应列出文件路径")

    local map = sr.get_line_map()
    local has_file = false
    for _, target in pairs(map) do
      if target.path == cwd .. "/x.lua" then has_file = true end
    end
    t.true_(has_file, "文件行应映射到具体文件")

    sr.close()
    services.provide("services.sandbox", saved)
  end)

  it("拒绝按键按单个文件调用 reject_file", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    sr.reset()
    local saved = services.use("services.sandbox")
    local cwd = vim.fn.getcwd()
    local rejected = {}
    services.provide("services.sandbox", {
      list_reviews = function()
        return {
          { change_set_id = "cs10", tool = "edit_file", files = { { path = cwd .. "/y.lua", action = "modify" } } },
        }
      end,
      apply = function() return { ok = true } end,
      reject = function() end,
      reject_file = function(id, path) rejected[#rejected + 1] = { id, path } end,
    })

    sr.open()
    local buf = sr.get_buf()
    local file_line
    for ln, target in pairs(sr.get_line_map()) do
      if target.path == cwd .. "/y.lua" then file_line = ln end
    end
    t.not_nil(file_line, "应找到文件行")
    vim.api.nvim_win_set_cursor(0, { file_line, 0 })

    local cb
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == "d" then cb = m.callback end
    end
    t.not_nil(cb, "应注册 d 拒绝键")
    cb()
    t.eq(1, #rejected, "应调用一次 reject_file")
    t.eq("cs10", rejected[1][1])
    t.eq(cwd .. "/y.lua", rejected[1][2])

    sr.close()
    services.provide("services.sandbox", saved)
  end)

  it("build_lines 显示高危/中危/低危风险档", function(t)
    local sr = require("NeoAI.ui.components.sandbox_review")
    local cwd = vim.fn.getcwd()
    local data = sr.build_lines({
      { change_set_id = "r0", tool = "edit_file", risk_level = 0, risk_reasons = { "WORKSPACE" },
        files = { { path = cwd .. "/a.lua" } } },
      { change_set_id = "r1", tool = "run_command", risk_level = 1, risk_reasons = { "NETWORK_ACCESS" },
        files = { { path = cwd .. "/b.lua" } } },
      { change_set_id = "r2", tool = "run_command", risk_level = 2, risk_reasons = { "SYSTEM_PATH_WRITE" },
        files = { { path = "/etc/x.conf" } } },
    })
    local text = table.concat(data.lines, "\n")
    t.matches("低危", text, "应显示低危")
    t.matches("中危", text, "应显示中危")
    t.matches("高危", text, "应显示高危")
  end)

  it("按 i 临时关闭审批窗并打开修改 diff，关闭 diff 后恢复", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    sr.reset()
    local saved = services.use("services.sandbox")
    local cwd = vim.fn.getcwd()
    local path = cwd .. "/preview.txt"
    local fs = require("NeoAI.utils.fs")
    fs.write_file(path, "old line\nkeep\n")
    services.provide("services.sandbox", {
      list_reviews = function()
        return {
          {
            change_set_id = "csP", tool = "edit_file", risk_level = 2,
            files = { { path = path, action = "modify", content = "new line\nkeep\n" } },
          },
        }
      end,
      apply = function() return { ok = true } end,
      reject = function() end,
      reject_file = function() end,
    })

    sr.open()
    local buf = sr.get_buf()
    t.not_nil(buf, "应创建审批 buffer")
    local file_line
    for ln, target in pairs(sr.get_line_map()) do
      if target.path == path then file_line = ln end
    end
    t.not_nil(file_line, "应找到文件行")
    vim.api.nvim_win_set_cursor(0, { file_line, 0 })

    -- 存在 i 键位
    local has_i = false
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == "i" then has_i = true end
    end
    t.true_(has_i, "审批窗应注册 i 预览键")

    sr.preview_current()
    t.nil_(sr.get_buf(), "打开 diff 时审批窗应暂时关闭")
    local dbuf = sr.get_diff_buf()
    t.not_nil(dbuf, "应打开 diff buffer")
    local dtext = table.concat(vim.api.nvim_buf_get_lines(dbuf, 0, -1, false), "\n")
    t.matches("new line", dtext, "diff 应包含新增内容")
    t.matches("old line", dtext, "diff 应包含删除内容")

    sr.close_diff()
    t.nil_(sr.get_diff_buf(), "diff 应已关闭")
    t.not_nil(sr.get_buf(), "关闭 diff 后应恢复审批窗")
    t.eq(file_line, vim.api.nvim_win_get_cursor(0)[1], "应恢复光标到原条目行")

    sr.close()
    fs.delete_file(path)
    services.provide("services.sandbox", saved)
  end)

  it("L3 条目首次 <CR> 打开 AI 警告 diff，二次确认后才应用", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    local l3 = require("NeoAI.sandbox.l3_warning")
    sr.reset()
    l3.reset()
    l3.set_generator(function(_, _, on_done) on_done("这是 AI 生成的后果警告") end)
    local saved = services.use("services.sandbox")
    local cwd = vim.fn.getcwd()
    local path = cwd .. "/l3.txt"
    local fs = require("NeoAI.utils.fs")
    fs.write_file(path, "old\n")
    local applied = {}
    services.provide("services.sandbox", {
      list_reviews = function()
        return {
          {
            change_set_id = "csL3", tool = "edit_file", risk_level = 3,
            risk_name = "critical", risk_reasons = { "SYSTEM_PATH_WRITE" },
            files = { { path = path, action = "modify", content = "new\n" } },
          },
        }
      end,
      apply = function(id, opts) applied[#applied + 1] = { id, opts }; return { ok = true } end,
      reject = function() end,
      reject_file = function() end,
    })

    sr.open()
    local buf = sr.get_buf()
    local file_line
    for ln, target in pairs(sr.get_line_map()) do
      if target.path == path then file_line = ln end
    end
    vim.api.nvim_win_set_cursor(0, { file_line, 0 })

    local cr
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == "<CR>" then cr = m.callback end
    end
    t.not_nil(cr, "应注册 <CR> 应用键")
    cr()
    t.eq(0, #applied, "L3 首次 <CR> 不应直接应用")
    local dbuf = sr.get_diff_buf()
    t.not_nil(dbuf, "L3 应自动打开 diff 预览")
    local dtext = table.concat(vim.api.nvim_buf_get_lines(dbuf, 0, -1, false), "\n")
    t.matches("L3 严重风险操作", dtext, "diff 顶部应展示 L3 警告标题")
    t.matches("这是 AI 生成的后果警告", dtext, "应展示 AI 生成的警告文本")
    t.matches("确认应用", dtext, "应提示二次确认")

    local dcr
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(dbuf, "n")) do
      if m.lhs == "<CR>" then dcr = m.callback end
    end
    t.not_nil(dcr, "diff 内应注册 <CR> 确认键")
    dcr()
    t.eq(1, #applied, "二次确认后应应用一次")
    t.eq("csL3", applied[1][1])
    t.eq(path, applied[1][2].files[1])

    sr.close()
    l3.reset()
    fs.delete_file(path)
    services.provide("services.sandbox", saved)
  end)

  it("L3 警告 diff 内 q 取消不应用", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    local l3 = require("NeoAI.sandbox.l3_warning")
    sr.reset()
    l3.reset()
    l3.set_generator(function(_, _, on_done) on_done("警告") end)
    local saved = services.use("services.sandbox")
    local cwd = vim.fn.getcwd()
    local path = cwd .. "/l3cancel.txt"
    local fs = require("NeoAI.utils.fs")
    fs.write_file(path, "old\n")
    local applied = 0
    services.provide("services.sandbox", {
      list_reviews = function()
        return {
          {
            change_set_id = "csL3c", tool = "edit_file", risk_level = 3,
            files = { { path = path, action = "modify", content = "new\n" } },
          },
        }
      end,
      apply = function() applied = applied + 1; return { ok = true } end,
      reject = function() end,
      reject_file = function() end,
    })

    sr.open()
    local buf = sr.get_buf()
    local file_line
    for ln, target in pairs(sr.get_line_map()) do
      if target.path == path then file_line = ln end
    end
    vim.api.nvim_win_set_cursor(0, { file_line, 0 })
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == "<CR>" then m.callback() end
    end
    local dbuf = sr.get_diff_buf()
    t.not_nil(dbuf, "应打开 L3 diff")
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(dbuf, "n")) do
      if m.lhs == "q" then m.callback() end
    end
    t.eq(0, applied, "取消后不应应用")
    t.nil_(sr.get_diff_buf(), "diff 应已关闭")
    t.not_nil(sr.get_buf(), "应返回审批窗")

    sr.close()
    l3.reset()
    fs.delete_file(path)
    services.provide("services.sandbox", saved)
  end)

  it("非 L3 条目 <CR> 直接应用（不触发二次确认）", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    sr.reset()
    local saved = services.use("services.sandbox")
    local cwd = vim.fn.getcwd()
    local path = cwd .. "/l2.txt"
    local applied = 0
    services.provide("services.sandbox", {
      list_reviews = function()
        return {
          {
            change_set_id = "csL2", tool = "edit_file", risk_level = 2,
            files = { { path = path, action = "modify", content = "new\n" } },
          },
        }
      end,
      apply = function() applied = applied + 1; return { ok = true } end,
      reject = function() end,
      reject_file = function() end,
    })

    sr.open()
    local buf = sr.get_buf()
    local file_line
    for ln, target in pairs(sr.get_line_map()) do
      if target.path == path then file_line = ln end
    end
    vim.api.nvim_win_set_cursor(0, { file_line, 0 })
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == "<CR>" then m.callback() end
    end
    t.eq(1, applied, "非 L3 应直接应用")
    t.nil_(sr.get_diff_buf(), "非 L3 不应打开二次确认 diff")

    sr.close()
    services.provide("services.sandbox", saved)
  end)

  it("l3_warning.fallback 生成确定性警告", function(t)
    local l3 = require("NeoAI.sandbox.l3_warning")
    local w = l3.fallback(
      { risk_name = "critical", risk_reasons = { "SYSTEM_PATH_WRITE" }, write_set = { "/etc/nginx.conf" } },
      { path = "/etc/nginx.conf" })
    t.matches("L3", w)
    t.matches("/etc/nginx%.conf", w)
  end)
end)
