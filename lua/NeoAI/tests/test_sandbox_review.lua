--- 沙箱待审审批界面测试
--- @module NeoAI.tests.test_sandbox_review
--- 覆盖：路径级别分类、按级别高亮标记、按安全等级着色的「待审」标签、渲染与行映射。

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

  it("build_lines：「待审」标签按安全等级着色", function(t)
    local sr = require("NeoAI.ui.components.sandbox_review")
    local cwd = vim.fn.getcwd()
    local function pending_level(risk_level)
      local data = sr.build_lines({ {
        change_set_id = "cs", tool = "edit_file", risk_level = risk_level,
        files = { { path = cwd .. "/a.lua", action = "modify" } },
      } })
      for _, m in ipairs(data.marks) do
        if data.lines[m.line]:sub(m.start_col + 1, m.end_col) == "待审" then return m.level end
      end
    end
    t.eq("pending0", pending_level(0), "L0 应为 pending0（灰）")
    t.eq("pending1", pending_level(1), "L1 应为 pending1（黄）")
    t.eq("pending2", pending_level(2), "L2 应为 pending2（橙）")
    t.eq("pending3", pending_level(3), "L3 应为 pending3（红）")
    -- 无安全等级信息时退回默认 pending
    local data = sr.build_lines({ {
      change_set_id = "cs", tool = "edit_file",
      files = { { path = cwd .. "/a.lua", action = "modify" } },
    } })
    local found
    for _, m in ipairs(data.marks) do
      if data.lines[m.line]:sub(m.start_col + 1, m.end_col) == "待审" then found = m.level end
    end
    t.eq("pending", found, "无安全等级时应退回 pending")
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

  it("build_lines 标注敏感包安装（改动软件源/密钥）", function(t)
    local sr = require("NeoAI.ui.components.sandbox_review")
    local cwd = vim.fn.getcwd()
    local data = sr.build_lines({
      {
        change_set_id = "cs_sens", tool = "run_command", package = true,
        package_manager = "apt", package_names = { "curl" }, package_sensitive = true,
        files = { { path = cwd .. "/x", action = "create" } },
      },
    })
    t.matches("⚠ 涉及软件源/密钥", table.concat(data.lines, "\n"), "敏感包安装应显式标注")
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

  it("build_lines 越界留痕按文件排序并合并工具", function(t)
    local sr = require("NeoAI.ui.components.sandbox_review")
    local data = sr.build_lines({}, {
      { tool = "list_files", path = "/root/z.txt" },
      { tool = "read_file", path = "/root/a.txt" },
      { tool = "list_files", path = "/root/a.txt" },
    })
    local text = table.concat(data.lines, "\n")
    local ia = text:find("/root/a.txt", 1, true)
    local iz = text:find("/root/z.txt", 1, true)
    t.true_(ia ~= nil and iz ~= nil and ia < iz, "应按文件路径升序排列")
    t.true_(text:find("%[read_file, list_files%] /root/a.txt", 1) ~= nil,
      "同一路径的多个工具应合并为一行，实际: " .. text)
  end)

  it("build_lines 展示已保存/已撤销区并映射撤销目标", function(t)
    local sr = require("NeoAI.ui.components.sandbox_review")
    local data = sr.build_lines({}, {}, nil, {
      { change_set_id = "csS", tool = "edit_file", apply_state = "APPLIED",
        saved_files = { { path = "/root/a.txt", action = "modify" } } },
      { change_set_id = "csR", tool = "edit_file", apply_state = "REVERTED",
        saved_files = { { path = "/root/b.txt", action = "create" } } },
    })
    local text = table.concat(data.lines, "\n")
    t.matches("已保存", text, "应展示已保存标题/标签")
    t.matches("已撤销", text, "应展示已撤销标签")
    local header_saved, file_saved = false, false
    for _, tgt in pairs(data.line_to_target) do
      if tgt.change_set_id == "csS" and tgt.saved and tgt.whole then header_saved = true end
      if tgt.change_set_id == "csS" and tgt.saved and tgt.path == "/root/a.txt" then file_saved = true end
    end
    t.true_(header_saved, "头行应映射为可撤销目标")
    t.true_(file_saved, "文件行应映射为可撤销目标")
  end)

  it("build_lines 已撤销条目不再显示「已保存」标题", function(t)
    local sr = require("NeoAI.ui.components.sandbox_review")
    local data = sr.build_lines({}, {}, nil, {
      { change_set_id = "csR2", tool = "edit_file", apply_state = "REVERTED",
        saved_files = { { path = "/root/c.txt", action = "modify" } } },
    })
    local text = table.concat(data.lines, "\n")
    t.matches("已撤销", text, "标题/标签应显示已撤销")
    t.true_(not text:find("已保存", 1, true), "撤销后不应再出现「已保存」，实际: " .. text)
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

  it("越界留痕行按 i 查看详情（工具/类型/命令/时间）", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    sr.reset()
    local saved = services.use("services.sandbox")
    services.provide("services.sandbox", {
      list_reviews = function() return {} end,
      list_traces = function()
        return {
          { tool = "read_file", kind = "read", path = "/root/other/x.txt",
            command = "cat /root/other/x.txt", created_at = 1700000000 },
          { tool = "run_command", kind = "read", path = "/root/other/x.txt",
            command = "grep token /root/other/x.txt", created_at = 1700000100 },
        }
      end,
      apply = function() return { ok = true } end,
      reject = function() end,
    })
    sr.open()
    local buf = sr.get_buf()
    t.not_nil(buf, "应打开审批窗")
    local trace_line
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for i, l in ipairs(lines) do
      if l:find("/root/other/x.txt", 1, true) then trace_line = i end
    end
    t.not_nil(trace_line, "应展示越界留痕行")
    t.eq(nil, sr.get_line_map()[trace_line], "留痕行不应是审批目标")
    vim.api.nvim_win_set_cursor(0, { trace_line, 0 })
    sr.preview_current()
    local dbuf = sr.get_diff_buf()
    t.not_nil(dbuf, "按 i 应打开详情浮窗")
    local dtext = table.concat(vim.api.nvim_buf_get_lines(dbuf, 0, -1, false), "\n")
    t.matches("/root/other/x.txt", dtext, "详情应含路径")
    t.matches("read_file", dtext, "详情应含工具名")
    t.matches("cat /root/other/x%.txt", dtext, "详情应含命令")
    t.matches("run_command", dtext, "详情应含第二次访问的工具")
    sr.close_diff()
    t.nil_(sr.get_diff_buf(), "详情应已关闭")
    t.not_nil(sr.get_buf(), "关闭详情后应恢复审批窗")
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

  it("L2 风险徽标用黄色高亮（仅 L3 红色）", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    sr.reset()
    local saved = services.use("services.sandbox")
    local cwd = vim.fn.getcwd()
    services.provide("services.sandbox", {
      list_reviews = function()
        return {
          { change_set_id = "csL2c", tool = "edit_file", risk_level = 2,
            files = { { path = cwd .. "/l2color.txt", action = "modify" } } },
        }
      end,
      list_traces = function() return {} end,
    })
    sr.open()
    sr.close()
    services.provide("services.sandbox", saved)
    local l1 = vim.api.nvim_get_hl_by_name("NeoAISandboxReviewRisk1", true)
    local l2 = vim.api.nvim_get_hl_by_name("NeoAISandboxReviewRisk2", true)
    local l3 = vim.api.nvim_get_hl_by_name("NeoAISandboxReviewRisk3", true)
    t.eq(l1.foreground, l2.foreground, "L2 应与 L1 同为黄色")
    t.true_(l2.foreground ~= l3.foreground, "L2 不应与 L3 红色相同")
  end)

  it("主机操作提案按 L3 高危标注", function(t)
    local sr = require("NeoAI.ui.components.sandbox_review")
    local data = sr.build_lines({
      { change_set_id = "csH", tool = "run_shell", kind = "host_op",
        privilege_tier = 2, risk_level = 3, risk_reasons = { "HOST_OPERATION" },
        write_set = { "systemctl restart nginx" } },
    })
    local text = table.concat(data.lines, "\n")
    t.matches("%[L3%]", text, "主机操作应显示 L3 徽标")
    t.matches("高危", text, "主机操作应标注高危")
    local l3mark
    for _, m in ipairs(data.marks) do
      if m.level == "risk3" then l3mark = m end
    end
    t.not_nil(l3mark, "主机操作风险徽标应用 risk3 高亮")
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

  it("应用需 root 时弹窗确认，确认后以 allow_root 重试", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    sr.reset()
    local saved = services.use("services.sandbox")
    local cwd = vim.fn.getcwd()
    local path = cwd .. "/needsroot.txt"
    local calls = {}
    services.provide("services.sandbox", {
      list_reviews = function()
        return {
          { change_set_id = "csNR", tool = "edit_file", risk_level = 1,
            files = { { path = path, action = "modify" } } },
        }
      end,
      list_traces = function() return {} end,
      apply = function(id, opts)
        calls[#calls + 1] = { id = id, opts = opts }
        if opts and opts.allow_root then return { ok = true, state = "APPLIED" } end
        return { ok = false, state = "NEEDS_ROOT", reason = "WRITE_REQUIRES_ROOT: " .. path }
      end,
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
    t.eq(1, #calls, "首次应用应尝试一次")
    t.true_(not calls[1].opts.allow_root, "首次不应提权")
    local pbuf = sr.get_root_prompt_buf()
    t.not_nil(pbuf, "需 root 时应弹出确认窗")
    local confirmed = false
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(pbuf, "n")) do
      if m.lhs == "<CR>" then m.callback(); confirmed = true end
    end
    t.true_(confirmed, "确认窗应绑定 <CR>")
    t.eq(2, #calls, "确认后应重试一次")
    t.true_(calls[2].opts.allow_root, "重试应带 allow_root")
    sr.close()
    services.provide("services.sandbox", saved)
  end)

  it("L2 包/敏感安装首次 <CR> 打开 AI 警告 diff，二次确认后才应用", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    local l3 = require("NeoAI.sandbox.l3_warning")
    sr.reset()
    l3.reset()
    l3.set_generator(function(_, _, on_done) on_done("安装后果警告") end)
    local saved = services.use("services.sandbox")
    local cwd = vim.fn.getcwd()
    local path = cwd .. "/pkg2.txt"
    local fs = require("NeoAI.utils.fs")
    fs.write_file(path, "old\n")
    local applied = {}
    services.provide("services.sandbox", {
      list_reviews = function()
        return {
          {
            change_set_id = "csP2", tool = "run_command", risk_level = 2,
            risk_name = "high", package = true, package_sensitive = true,
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
    t.eq(0, #applied, "L2 包安装首次 <CR> 不应直接应用")
    local dbuf = sr.get_diff_buf()
    t.not_nil(dbuf, "应自动打开 diff 预览")
    local dtext = table.concat(vim.api.nvim_buf_get_lines(dbuf, 0, -1, false), "\n")
    t.matches("L2 高危风险操作", dtext, "diff 顶部应展示 L2 警告标题")
    t.matches("安装后果警告", dtext, "应展示 AI 生成的警告文本")

    local dcr
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(dbuf, "n")) do
      if m.lhs == "<CR>" then dcr = m.callback end
    end
    t.not_nil(dcr, "diff 内应注册 <CR> 确认键")
    dcr()
    t.eq(1, #applied, "二次确认后应应用一次")
    t.eq("csP2", applied[1][1])

    sr.close()
    l3.reset()
    fs.delete_file(path)
    services.provide("services.sandbox", saved)
  end)

  it("package_confirm=false 时 L2 包安装直接应用（不二次确认）", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    sr.reset()
    local saved = services.use("services.sandbox")
    local prev = config_store.get("tools.sandbox.review.l3_warning.package_confirm")
    config_store.set("tools.sandbox.review.l3_warning.package_confirm", false)
    local cwd = vim.fn.getcwd()
    local path = cwd .. "/pkg2off.txt"
    local applied = 0
    services.provide("services.sandbox", {
      list_reviews = function()
        return {
          {
            change_set_id = "csP2off", tool = "run_command", risk_level = 2,
            package = true, package_sensitive = true,
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
    t.eq(1, applied, "关闭 package_confirm 后应直接应用")
    t.nil_(sr.get_diff_buf(), "不应打开二次确认 diff")
    sr.close()
    config_store.set("tools.sandbox.review.l3_warning.package_confirm", prev)
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
