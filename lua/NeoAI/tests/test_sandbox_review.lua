--- 沙箱待审审批界面测试
--- @module NeoAI.tests.test_sandbox_review
--- 覆盖：路径级别分类、按级别高亮标记、按安全等级着色的「待审」标签、渲染与行映射。

local tests = require("NeoAI.tests")
-- 沙箱审批 UI 经 `services.sandbox` 门面访问沙箱能力；本套件的部分桩只覆盖数据/行为方法，
-- 渲染与查询辅助经共享辅助按真实实现补齐（等价于重构前 UI 直接 require 沙箱内部模块的行为）。
local _provide_sandbox = require("NeoAI.tests.sandbox_stub").provide

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

  it("build_lines 展示「已拒绝」区并映射恢复目标", function(t)
    local sr = require("NeoAI.ui.components.sandbox_review")
    local data = sr.build_lines({}, {}, nil, {}, {
      { change_set_id = "csREJ", tool = "edit_file", reject_reason = "USER_DENIED",
        files = { { path = "/root/x.txt", action = "modify" }, { path = "/root/y.txt", action = "create" } } },
    })
    local text = table.concat(data.lines, "\n")
    t.matches("已拒绝", text, "应展示已拒绝区标题")
    t.matches("csREJ", text, "应展示被拒条目")
    t.matches("USER_DENIED", text, "应展示拒绝原因")
    local header_rej, file_rej = false, false
    for _, tgt in pairs(data.line_to_target) do
      if tgt.change_set_id == "csREJ" and tgt.rejected and tgt.whole then header_rej = true end
      if tgt.change_set_id == "csREJ" and tgt.rejected and tgt.path == "/root/x.txt" then file_rej = true end
    end
    t.true_(header_rej, "已拒绝头行应映射为恢复目标")
    t.true_(file_rej, "已拒绝文件行应映射为恢复目标")
    -- 区标题（含「已拒绝」）应为一级折叠，条目头行二级
    local fl = data.fold_levels or {}
    local title_ln, header_ln
    for i, l in ipairs(data.lines) do
      if l:find("已拒绝", 1, true) and l:find("──", 1, true) then title_ln = i end
      if l:find("csREJ", 1, true) then header_ln = i end
    end
    t.eq(1, fl[title_ln], "已拒绝区标题应为一级折叠")
    t.eq(2, fl[header_ln], "已拒绝条目头行应为二级折叠")
  end)

  it("build_lines 为「已应用」区登记两级折叠级别", function(t)
    local sr = require("NeoAI.ui.components.sandbox_review")
    local data = sr.build_lines({}, {}, nil, {
      { change_set_id = "csF1", tool = "edit_file", apply_state = "APPLIED",
        saved_files = { { path = "/root/a.txt" }, { path = "/root/b.txt" } } },
      { change_set_id = "csF2", tool = "edit_file", apply_state = "APPLIED",
        saved_files = { { path = "/root/c.txt" } } },
    })
    local fl = data.fold_levels or {}
    local title_ln, h1, h2
    for i, l in ipairs(data.lines) do
      if l:find("已应用", 1, true) and l:find("──", 1, true) then title_ln = title_ln or i end
      if l:find("csF1", 1, true) then h1 = i end
      if l:find("csF2", 1, true) then h2 = i end
    end
    t.not_nil(title_ln, "应有已应用区标题")
    t.eq(1, fl[title_ln], "区标题应为一级折叠")
    t.eq(2, fl[h1], "条目头行应为二级折叠")
    t.eq(2, fl[h2], "第二条目头行应为二级折叠")
    t.eq(2, fl[h1 + 1], "文件行应并入二级折叠")
    t.eq(2, fl[h1 + 2], "第二个文件行应并入二级折叠")
    for _, lv in pairs(fl) do
      t.true_(lv == 1 or lv == 2, "仅已应用区登记折叠级别（1/2）")
    end
  end)

  it("build_lines 待审普通条目「头行显示、其余折叠」", function(t)
    local sr = require("NeoAI.ui.components.sandbox_review")
    local cwd = vim.fn.getcwd()
    local data = sr.build_lines({ { change_set_id = "csP", tool = "edit_file", risk_level = 1,
      risk_reasons = { "PACKAGE_INSTALL" },
      files = { { path = cwd .. "/p.lua" }, { path = cwd .. "/q.lua" } } } }, {}, nil, {})
    local fl = data.fold_levels or {}
    local head, last
    for i, l in ipairs(data.lines) do
      if l:find("csP", 1, true) then head = i end
      if l:find("q.lua", 1, true) then last = i end
    end
    t.not_nil(head, "应有头行")
    t.not_nil(last, "应有文件行")
    t.eq(nil, fl[head], "头行不折叠（保持正常显示与高亮）")
    for ln = head + 1, last do
      t.eq(1, fl[ln], "头行之后的风险原因/文件行都应登记一级折叠")
    end
    t.eq(nil, fl[last + 1], "条目尾空行不应登记折叠级别（避免相邻条目合并）")
  end)

  it("build_lines 待审 git 原子组登记整组折叠级别", function(t)
    local sr = require("NeoAI.ui.components.sandbox_review")
    local cwd = vim.fn.getcwd()
    local data = sr.build_lines({ { change_set_id = "csGF", tool = "git_add", atomic_group = "git",
      files = {
        { path = cwd .. "/.git/index" },
        { path = cwd .. "/.git/objects/ab/cd" },
        { path = cwd .. "/a.lua" },
      } } }, {}, nil, {})
    local fl = data.fold_levels or {}
    local head, last
    for i, l in ipairs(data.lines) do
      if l:find("csGF", 1, true) then head = i end
      if l:find("a.lua", 1, true) then last = i end
    end
    t.not_nil(head, "应有 git 组头行")
    t.not_nil(last, "应有 git 组文件行")
    t.eq(nil, fl[head], "头行不折叠（保持正常显示与高亮）")
    for ln = head + 1, last do
      t.eq(1, fl[ln], "头行之后的提示/风险/文件行都应登记一级折叠")
    end
    t.eq(nil, fl[last + 1], "组尾空行不应登记折叠级别（避免相邻组合并）")
  end)

  it("open 后待审 git 原子组默认收起且可展开", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    sr.reset()
    local saved = services.use("services.sandbox")
    local cwd = vim.fn.getcwd()
    _provide_sandbox({
      list_reviews = function()
        return { { change_set_id = "csGFO", tool = "git_add", atomic_group = "git", risk_level = 0,
          files = { { path = cwd .. "/.git/index" }, { path = cwd .. "/a.lua" } } } }
      end,
      list_traces = function() return {} end,
      list_saved = function() return {} end,
      apply = function() return { ok = true } end,
      reject = function() end,
    })
    sr.open()
    local buf = sr.get_buf()
    t.not_nil(buf, "应创建审批 buffer")
    local win = vim.fn.bufwinid(buf)
    t.true_(win ~= -1, "审批 buffer 应在窗口中显示")
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local head
    for i, l in ipairs(lines) do
      if l:find("csGFO", 1, true) then head = i end
    end
    t.not_nil(head, "应有 git 组头行")
    local function closed(ln)
      return vim.api.nvim_win_call(win, function() return vim.fn.foldclosed(ln) end)
    end
    t.eq(-1, closed(head), "git 组头行应保持显示（不折叠）")
    t.eq(head + 1, closed(head + 1), "头行之后（提示/文件）默认应处于折叠状态")
    vim.api.nvim_win_set_cursor(win, { head + 1, 0 })
    vim.api.nvim_win_call(win, function() vim.cmd("normal! zo") end)
    t.eq(-1, closed(head + 1), "zo 后 git 组其余行应展开")
    sr.close()
    services.provide("services.sandbox", saved)
  end)

  it("build_lines 合并重复风险原因并计数", function(t)
    local sr = require("NeoAI.ui.components.sandbox_review")
    local cwd = vim.fn.getcwd()
    local reasons = { "PACKAGE_INSTALL" }
    for _ = 1, 2797 do reasons[#reasons + 1] = "SYSTEM_PATH_WRITE" end
    local data = sr.build_lines({ { change_set_id = "csDup", tool = "run_command", risk_level = 1,
      risk_reasons = reasons, files = { { path = cwd .. "/p.lua" } } } }, {}, nil, {})
    local text = table.concat(data.lines, "\n")
    t.matches("SYSTEM_PATH_WRITE×2797", text, "重复原因应合并计数")
    local _, bare = text:gsub("SYSTEM_PATH_WRITE,", "")
    t.eq(0, bare, "SYSTEM_PATH_WRITE 不应再逐条重复列出")
  end)

  it("窗口打开时订阅沙箱广播事件并自动刷新", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    local event_bus = require("NeoAI.kernel.event_bus")
    local events = require("NeoAI.kernel.events")
    sr.reset()
    local saved = services.use("services.sandbox")
    local cwd = vim.fn.getcwd()
    local items = { { change_set_id = "csA", tool = "edit_file",
      files = { { path = cwd .. "/a.lua" } } } }
    _provide_sandbox({
      list_reviews = function() return vim.deepcopy(items) end,
      list_traces = function() return {} end,
      list_saved = function() return {} end,
      apply = function() return { ok = true } end,
      reject = function() end,
    })
    sr.open()
    local buf = sr.get_buf()
    t.not_nil(buf, "应打开审批窗")
    -- 广播新增待审：无需手动 refresh，事件驱动自动重绘。
    items = {
      { change_set_id = "csA", tool = "edit_file", files = { { path = cwd .. "/a.lua" } } },
      { change_set_id = "csB", tool = "edit_file", files = { { path = cwd .. "/b.lua" } } },
    }
    event_bus.emit(events.SANDBOX_REVIEW_ENQUEUED, { change_set_id = "csB" })
    local found = vim.wait(2000, function()
      if not (buf and vim.api.nvim_buf_is_valid(buf)) then return false end
      for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if l:find("csB", 1, true) then return true end
      end
      return false
    end, 10)
    t.true_(found, "广播事件后应自动刷新出 csB")
    sr.close()
    services.provide("services.sandbox", saved)
  end)

  it("open 后「已应用」区默认整体折叠且两级展开", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    sr.reset()
    local saved = services.use("services.sandbox")
    _provide_sandbox({
      list_reviews = function() return {} end,
      list_traces = function() return {} end,
      list_saved = function()
        return {
          { change_set_id = "csFA", tool = "edit_file", apply_state = "APPLIED",
            saved_files = { { path = "/root/a.txt" }, { path = "/root/b.txt" } } },
        }
      end,
      apply = function() return { ok = true } end,
      reject = function() end,
    })
    sr.open()
    local buf = sr.get_buf()
    t.not_nil(buf, "应创建审批 buffer")
    local win = vim.fn.bufwinid(buf)
    t.true_(win ~= -1, "审批 buffer 应在窗口中显示")
    t.eq("expr", vim.wo[win].foldmethod, "应为 expr 折叠")
    t.true_(vim.wo[win].foldenable == true, "应开启折叠")
    t.eq(0, vim.wo[win].foldlevel, "默认折叠级别应为 0（整体收起）")

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local title_ln, header_ln
    for i, l in ipairs(lines) do
      if l:find("已应用", 1, true) and l:find("──", 1, true) then title_ln = i end
      if l:find("csFA", 1, true) then header_ln = i end
    end
    t.not_nil(title_ln, "应有已应用区标题")
    t.not_nil(header_ln, "应有条目头行")

    local function closed(ln)
      return vim.api.nvim_win_call(win, function() return vim.fn.foldclosed(ln) end)
    end
    t.eq(title_ln, closed(title_ln), "已应用区标题默认应处于折叠状态")

    vim.api.nvim_win_set_cursor(win, { title_ln, 0 })
    vim.api.nvim_win_call(win, function() vim.cmd("normal! zo") end)
    t.eq(-1, closed(title_ln), "zo 后区标题应展开")
    t.eq(header_ln, closed(header_ln), "区展开后条目应仍收起")

    vim.api.nvim_win_set_cursor(win, { header_ln, 0 })
    vim.api.nvim_win_call(win, function() vim.cmd("normal! zo") end)
    t.eq(-1, closed(header_ln), "zo 后条目应展开")

    sr.close()
    services.provide("services.sandbox", saved)
  end)

  it("应用后 reveal_applied 展开「已应用」区使条目可见（不改变默认折叠）", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    sr.reset()
    local saved = services.use("services.sandbox")
    _provide_sandbox({
      list_reviews = function() return {} end,
      list_traces = function() return {} end,
      list_saved = function()
        return {
          { change_set_id = "csRA", tool = "edit_file", apply_state = "APPLIED",
            saved_files = { { path = "/root/a.txt" } } },
        }
      end,
      apply = function() return { ok = true } end,
      reject = function() end,
    })
    sr.open()
    t.eq(0, sr.get_foldlevel(), "默认仍整体折叠")
    sr.reveal_applied()
    t.eq(2, sr.get_foldlevel(), "reveal 后应展开到条目级（条目头行可见）")
    sr.close()
    services.provide("services.sandbox", saved)
  end)

  it("open 无待审/审批/留痕事项时也打开窗口（不提示、不自动关闭）", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    sr.reset()
    local saved = services.use("services.sandbox")
    _provide_sandbox({
      list_reviews = function() return {} end,
      list_traces = function() return {} end,
      list_saved = function() return {} end,
      apply = function() return { ok = true } end,
      reject = function() end,
    })
    local notified = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, ...)
      notified[#notified + 1] = tostring(msg)
      return orig_notify(msg, ...)
    end
    sr.open()
    vim.notify = orig_notify
    t.not_nil(sr.get_buf(), "无任何事项时也应打开审批窗（而非仅提示）")
    -- refresh 在空队列下不应自动关闭窗口。
    sr.refresh()
    t.not_nil(sr.get_buf(), "空队列刷新后仍应保持窗口打开")
    for _, m in ipairs(notified) do
      t.true_(not m:find("无待审", 1, true), "不应再弹「无待审」提示")
    end
    sr.close()
    services.provide("services.sandbox", saved)
  end)

  it("open 仅有越界留痕时也能打开审批窗", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    sr.reset()
    local saved = services.use("services.sandbox")
    _provide_sandbox({
      list_reviews = function() return {} end,
      list_traces = function() return { { tool = "read_file", path = "/root/other/x.txt" } } end,
      apply = function() return { ok = true } end,
      reject = function() end,
    })
    sr.open()
    sr.open_page("anomaly")
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
    _provide_sandbox({
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
    sr.open_page("anomaly")
    local buf = sr.get_buf()
    t.not_nil(buf, "应打开审批窗")
    local trace_line
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for i, l in ipairs(lines) do
      -- 文件段行为 "  [工具] 路径…"；命令段行为 "  $ 命令  → N 个文件"（不匹配此模式）。
      if l:find("  %[.-%] /root/other/x.txt", 1) then trace_line = i end
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

  it("越界/异常页展示「越界命令（命令 → 文件）」段", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    sr.reset()
    local saved = services.use("services.sandbox")
    _provide_sandbox({
      list_reviews = function() return {} end,
      list_traces = function()
        return {
          { tool = "run_command", kind = "read", path = "/root/a.txt",
            command = "cat /root/a.txt", commands = { "cat /root/a.txt" } },
          { tool = "read_file", kind = "read", path = "/root/b.txt" },
        }
      end,
      apply = function() return { ok = true } end,
      reject = function() end,
    })
    sr.open()
    sr.open_page("anomaly")
    local buf = sr.get_buf()
    t.not_nil(buf, "应打开审批窗")
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    t.matches("越界命令", text, "应展示越界命令段标题")
    t.matches("$ cat /root/a%.txt", text, "命令段应展示命令字符串")
    t.matches("→ 1 个文件", text, "命令段应展示涉及文件数")
    t.matches("（非命令工具访问）", text, "无命令访问应归入哨兵组展示")
    -- 命令段行不是审批目标
    local cmd_line
    for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if l:find("$ cat /root/a.txt", 1, true) then cmd_line = i end
    end
    t.not_nil(cmd_line, "应存在命令行")
    t.eq(nil, sr.get_line_map()[cmd_line], "命令行不应是审批目标")
    -- 按 i 查看该命令涉及的文件
    vim.api.nvim_win_set_cursor(0, { cmd_line, 0 })
    sr.preview_current()
    local dbuf = sr.get_diff_buf()
    t.not_nil(dbuf, "按 i 应打开命令详情浮窗")
    local dtext = table.concat(vim.api.nvim_buf_get_lines(dbuf, 0, -1, false), "\n")
    t.matches("越界命令详情", dtext, "命令详情标题")
    t.matches("/root/a%.txt", dtext, "命令详情应列出涉及文件")
    sr.close_diff()
    sr.close()
    services.provide("services.sandbox", saved)
  end)

  it("越界文件详情汇总「涉及命令」并逐条列出", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    sr.reset()
    local saved = services.use("services.sandbox")
    _provide_sandbox({
      list_reviews = function() return {} end,
      list_traces = function()
        return {
          { tool = "run_command", kind = "read", path = "/root/a.txt",
            command = "cat /root/a.txt", commands = { "cat /root/a.txt", "grep token /root/a.txt" } },
        }
      end,
      apply = function() return { ok = true } end,
      reject = function() end,
    })
    sr.open()
    sr.open_page("anomaly")
    local buf = sr.get_buf()
    local trace_line
    for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if l:find("[run_command]", 1, true) then trace_line = i end
    end
    t.not_nil(trace_line, "应展示越界文件行")
    vim.api.nvim_win_set_cursor(0, { trace_line, 0 })
    sr.preview_current()
    local dbuf = sr.get_diff_buf()
    t.not_nil(dbuf, "按 i 应打开文件详情浮窗")
    local dtext = table.concat(vim.api.nvim_buf_get_lines(dbuf, 0, -1, false), "\n")
    t.matches("涉及命令: 2 条", dtext, "文件详情应汇总涉及命令数")
    t.matches("grep token /root/a%.txt", dtext, "文件详情应列出累积的命令")
    sr.close_diff()
    sr.close()
    services.provide("services.sandbox", saved)
  end)

  it("open 渲染待审界面并应用高亮，apply 走文件级目标", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    sr.reset()
    local saved = services.use("services.sandbox")
    local cwd = vim.fn.getcwd()
    _provide_sandbox({
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
    _provide_sandbox({
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
    _provide_sandbox({
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

  it("主机操作头行也是有效审批目标（<CR> 应用 / i 预览命令）", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    sr.reset()
    local saved = services.use("services.sandbox")
    local applied = {}
    _provide_sandbox({
      list_reviews = function()
        return {
          { change_set_id = "csH", kind = "host_op", tool = "run_command",
            host_op_id = "ho1", risk_level = 3, privilege_tier = 2,
            write_set = { "systemctl restart nginx" }, files = {} },
        }
      end,
      list_traces = function() return {} end,
      list_saved = function() return {} end,
      apply = function(id, opts) applied[#applied + 1] = { id = id, opts = opts }; return { ok = true } end,
      reject = function() end,
      reject_file = function() end,
    })
    sr.open()
    sr.open_page("behavior")
    local buf = sr.get_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local header
    for i, l in ipairs(lines) do
      if l:find("csH", 1, true) then header = i break end
    end
    t.not_nil(header, "应有主机操作头行")
    local tgt = sr.get_line_map()[header]
    t.not_nil(tgt, "头行应参与审批")
    t.eq(true, tgt.host_op, "头行目标应为主机操作")
    -- 头行 <CR> 应直接应用（整条审批）
    vim.api.nvim_win_set_cursor(0, { header, 0 })
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == "<CR>" then m.callback() end
    end
    t.eq(1, #applied, "头行 <CR> 应应用主机操作")
    t.eq("csH", applied[1].id)
    -- 头行 i 应预览命令（而非误报 git 无 diff）
    vim.api.nvim_win_set_cursor(0, { header, 0 })
    sr.preview_current()
    local dbuf = sr.get_diff_buf()
    t.not_nil(dbuf, "主机操作头行 i 应打开预览")
    local dtext = table.concat(vim.api.nvim_buf_get_lines(dbuf, 0, -1, false), "\n")
    t.true_(dtext:find("systemctl restart nginx", 1, true) ~= nil, "预览应包含命令")
    sr.close_diff()
    sr.close()
    services.provide("services.sandbox", saved)
  end)

  it("命令型变更单元显示实际命令，受影响文件按级别高亮", function(t)
    local sr = require("NeoAI.ui.components.sandbox_review")
    local cwd = vim.fn.getcwd()
    local data = sr.build_lines({
      { change_set_id = "csC", tool = "run_command", risk_level = 1,
        command = "sed -i 's/a/b/' src/a.lua",
        files = { { path = cwd .. "/src/a.lua", action = "modify" },
                  { path = "/etc/hosts", action = "modify" } } },
    })
    local text = table.concat(data.lines, "\n")
    t.true_(text:find("sed -i", 1, true) ~= nil, "应显示实际命令")
    local ws, sys
    for _, m in ipairs(data.marks) do
      local ln = data.lines[m.line]
      if ln and ln:find("src/a.lua", 1, true) then ws = m.level end
      if ln and ln:find("/etc/hosts", 1, true) then sys = m.level end
    end
    t.eq("workspace", ws, "工作区文件应 workspace 高亮")
    t.eq("system", sys, "系统文件应 system 高亮")
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
    _provide_sandbox({
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
    _provide_sandbox({
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
    _provide_sandbox({
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
    _provide_sandbox({
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
    _provide_sandbox({
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
    _provide_sandbox({
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
    _provide_sandbox({
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

  it("build_lines 分区显示未应用与已应用", function(t)
    local sr = require("NeoAI.ui.components.sandbox_review")
    local cwd = vim.fn.getcwd()
    local data = sr.build_lines(
      { { change_set_id = "csU", tool = "edit_file",
          files = { { path = cwd .. "/a.lua", action = "modify" } } } },
      {}, nil,
      { { change_set_id = "csA", tool = "edit_file", apply_state = "APPLIED",
          saved_files = { { path = cwd .. "/b.lua", action = "modify" } } } })
    local text = table.concat(data.lines, "\n")
    t.matches("未应用", text, "应有未应用分区")
    t.matches("已应用", text, "应有已应用分区")
  end)

  it("A 键一键同意所有工作区内修改（跳过工作区外）", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    sr.reset()
    local saved = services.use("services.sandbox")
    local cwd = vim.fn.getcwd()
    local calls = {}
    _provide_sandbox({
      list_reviews = function()
        return {
          { change_set_id = "csW", tool = "edit_file", files = {
            { path = cwd .. "/a.lua", action = "modify" },
            { path = "/etc/nginx.conf", action = "modify" },
          } },
          { change_set_id = "csSys", tool = "edit_file", files = {
            { path = "/etc/hosts", action = "modify" } } },
        }
      end,
      apply = function(id, opts) calls[#calls + 1] = { id = id, opts = opts }; return { ok = true } end,
      reject = function() end,
    })
    sr.open()
    local buf = sr.get_buf()
    local cb
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == "A" then cb = m.callback end
    end
    t.not_nil(cb, "应注册 A 一键同意键")
    cb()
    -- 批量应用逐项让出主循环（异步），等待完成后再断言。
    t.true_(vim.wait(2000, function() return not sr.is_applying_all() end, 10), "批量应用应完成")
    t.eq(1, #calls, "仅对含工作区文件的变更单元调用一次")
    t.eq("csW", calls[1].id)
    t.eq(1, #calls[1].opts.files, "仅应用工作区文件")
    t.eq(cwd .. "/a.lua", calls[1].opts.files[1])
    sr.close()
    services.provide("services.sandbox", saved)
  end)

  it("A 键批量应用逐项让出主循环，且重入被拒绝", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    sr.reset()
    local saved = services.use("services.sandbox")
    local cwd = vim.fn.getcwd()
    local calls = {}
    _provide_sandbox({
      list_reviews = function()
        local items = {}
        for i = 1, 3 do
          items[i] = { change_set_id = "csY" .. i, tool = "edit_file",
            files = { { path = cwd .. "/y" .. i .. ".lua", action = "modify" } } }
        end
        return items
      end,
      apply = function(id, opts) calls[#calls + 1] = { id = id, opts = opts }; return { ok = true } end,
      reject = function() end,
    })
    sr.open()
    local buf = sr.get_buf()
    local cb
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == "A" then cb = m.callback end
    end
    cb()
    -- 首个 tick 后仍在应用中，此时重入不应重复触发。
    cb()
    t.true_(vim.wait(2000, function() return not sr.is_applying_all() end, 10), "批量应用应完成")
    t.eq(3, #calls, "重入不应重复应用")
    sr.close()
    services.provide("services.sandbox", saved)
  end)

  it("build_lines：git 原子组整组渲染，文件行映射到整组（不可逐文件）", function(t)
    local sr = require("NeoAI.ui.components.sandbox_review")
    local dir = vim.fn.tempname()
    local items = { {
      change_set_id = "csgit", tool = "git_add", atomic_group = "git",
      files = {
        { path = dir .. "/.git/objects/ab/cd", action = "create" },
        { path = dir .. "/.git/index", action = "modify" },
        { path = dir .. "/work.txt", action = "modify" },
      },
    } }
    local data = sr.build_lines(items)
    local head
    for i, l in ipairs(data.lines) do
      if l:find("git 操作", 1, true) then head = i break end
    end
    t.not_nil(head, "头行应标注 git 操作")
    local mapped = 0
    for _, tgt in pairs(data.line_to_target) do
      if tgt.change_set_id == "csgit" then
        mapped = mapped + 1
        t.true_(tgt.whole == true, "git 组的所有行都应映射到整组")
        t.nil_(tgt.path, "git 组不应有逐文件目标")
      end
    end
    t.true_(mapped >= 4, "应有头行 + 提示行 + 3 个文件行，实际 " .. tostring(mapped))
  end)

  it("git 原子组：enqueue 标记，apply 忽略文件子集整组应用，reject_file 整组拒绝", function(t)
    local review = require("NeoAI.sandbox.review")
    local store = require("NeoAI.sandbox.store")
    local candidate = require("NeoAI.sandbox.candidate")
    review.reset()
    local dir = vim.fn.tempname()
    local function make_cand()
      return {
        candidate_digest = "sha256:gittest-" .. tostring(vim.uv.hrtime()),
        files = {
          { path = dir .. "/.git/objects/ab/cd", action = "create", content = "obj", after_hash = "h1" },
          { path = dir .. "/.git/index", action = "modify", content = "idx", after_hash = "h2" },
          { path = dir .. "/work.txt", action = "modify", content = "w", after_hash = "h3" },
        },
      }
    end
    local item = review.enqueue(make_cand(), { tool = "git_add" })
    t.not_nil(item, "应入队")
    t.eq("git", item.atomic_group, "应标记为 git 原子组")
    -- apply 传单文件子集也应整组应用
    local orig_read, orig_pub = store.read_candidate, candidate.publish
    local published
    store.read_candidate = function() return make_cand() end
    candidate.publish = function(c)
      published = {}
      for _, f in ipairs(c.files) do published[#published + 1] = f.path end
      return { ok = true, state = "COMMITTED", receipt = { operation_id = "op_test" } }
    end
    local res = review.apply(item.change_set_id, { auto_approve = true, files = { dir .. "/work.txt" } })
    store.read_candidate, candidate.publish = orig_read, orig_pub
    t.true_(res.ok, "应用应成功: " .. tostring(res and res.reason))
    t.eq(3, #published, "git 原子组应忽略文件子集，整组应用")
    -- reject_file 应整组拒绝
    local item2 = review.enqueue(make_cand(), { tool = "git_add" })
    review.reject_file(item2.change_set_id, dir .. "/work.txt")
    local after = review.get(item2.change_set_id)
    t.eq(review.REVIEW.REJECTED, after.review_state, "reject_file 应整组拒绝 git 原子组")
    review.reset()
  end)

  it("多级页面：页头展示 5 个页面并可 h/l 切换", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    sr.reset()
    local saved = services.use("services.sandbox")
    _provide_sandbox({
      list_reviews = function() return {} end,
      list_traces = function() return { { tool = "read_file", path = "/root/x.txt" } } end,
      list_saved = function() return {} end,
      apply = function() return { ok = true } end,
      reject = function() end,
    })
    sr.open()
    local buf = sr.get_buf()
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    for _, label in ipairs({ "待修改", "工具行为", "资源访问", "网络请求", "越界/异常" }) do
      t.true_(text:find(label, 1, true) ~= nil, "页头应含 " .. label)
    end
    -- l 切到下一页，页头高亮段变化（越界/异常页应出现留痕区）
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == "l" then m.callback(); m.callback(); m.callback(); m.callback() end
    end
    local text2 = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    t.matches("越界访问留痕", text2, "切到第 5 页应显示留痕区")
    sr.close()
    services.provide("services.sandbox", saved)
  end)

  it("阻塞类页面渲染分流条目并按 <CR> 决策", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    local hub = require("NeoAI.sandbox.approval_hub")
    sr.reset()
    local saved = services.use("services.sandbox")
    _provide_sandbox({
      list_reviews = function() return {} end,
      list_traces = function() return {} end,
      list_saved = function() return {} end,
      apply = function() return { ok = true } end,
      reject = function() end,
    })
    local decided
    local id = hub.submit("network", {
      title = "127.0.0.1:9999（mockd pid 42）",
      detail = { "程序: /usr/bin/mockd" },
      on_decision = function(v) decided = v end,
    })
    sr.open()
    sr.open_page("network")
    local buf = sr.get_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local entry_line
    for i, l in ipairs(lines) do if l:find(id, 1, true) then entry_line = i end end
    t.not_nil(entry_line, "网络页应展示分流条目")
    t.true_(table.concat(lines, "\n"):find("mockd", 1, true) ~= nil, "应展示服务身份")
    vim.api.nvim_win_set_cursor(0, { entry_line, 0 })
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == "<CR>" then m.callback() end
    end
    t.eq("allow_once", decided, "<CR> 应决策为 allow_once")
    t.eq(0, hub.pending_count("network"), "决策后条目应移除")
    sr.close()
    services.provide("services.sandbox", saved)
  end)

  it("工具行为页并入主机操作提案", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    sr.reset()
    local saved = services.use("services.sandbox")
    _provide_sandbox({
      list_reviews = function()
        return { { change_set_id = "csHO", kind = "host_op", tool = "run_command",
          host_op_id = "ho1", risk_level = 3, privilege_tier = 2,
          write_set = { "systemctl restart nginx" }, files = {} } }
      end,
      list_traces = function() return {} end,
      list_saved = function() return {} end,
      apply = function() return { ok = true } end,
      reject = function() end,
    })
    sr.open()
    sr.open_page("behavior")
    local text = table.concat(vim.api.nvim_buf_get_lines(sr.get_buf(), 0, -1, false), "\n")
    t.matches("csHO", text, "工具行为页应展示主机操作提案")
    t.matches("systemctl restart nginx", text, "应展示主机操作命令")
    sr.close()
    services.provide("services.sandbox", saved)
  end)

  it("资源访问页展示目录设置区（工作目录/遮蔽目录）", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    local config_store = require("NeoAI.kernel.config_store")
    sr.reset()
    config_store.load({
      tools = {
        approval = { allowed_directories = { "/tmp/ws-a" } },
        sandbox = { mask_dirs = { "/etc/secret" } },
      },
    })
    local saved = services.use("services.sandbox")
    _provide_sandbox({
      list_reviews = function() return {} end,
      list_traces = function() return {} end,
      list_saved = function() return {} end,
      apply = function() return { ok = true } end,
      reject = function() end,
    })
    sr.open()
    sr.open_page("resource")
    local text = table.concat(vim.api.nvim_buf_get_lines(sr.get_buf(), 0, -1, false), "\n")
    t.matches("目录设置", text, "资源访问页应含目录设置区")
    t.matches("工作目录列表", text, "应含工作目录列表标题")
    t.matches("遮蔽目录列表", text, "应含遮蔽目录列表标题")
    t.matches("/tmp/ws%-a", text, "应展示预置工作目录")
    t.matches("/etc/secret", text, "应展示预置遮蔽目录")
    sr.close()
    services.provide("services.sandbox", saved)
  end)

  it("资源访问页目录管理 API：增删改生效且去重", function(t)
    local sr = require("NeoAI.ui.components.sandbox_review")
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({})
    -- 新增工作目录（规范化 + 去重）
    t.true_(sr.add_dir("workspace", "/tmp/ws-x/"), "应能新增工作目录")
    t.false_(sr.add_dir("workspace", "/tmp/ws-x"), "重复目录应被去重拒绝")
    t.eq("/tmp/ws-x", config_store.get("tools.approval.allowed_directories")[1], "工作目录应写入配置")
    -- 新增遮蔽目录（默认含 /home、/root，追加后应出现且去重）
    t.true_(sr.add_dir("mask", "/tmp/mask-y"), "应能新增遮蔽目录")
    t.false_(sr.add_dir("mask", "/tmp/mask-y/"), "重复遮蔽目录应被去重拒绝")
    local mask_list = config_store.get("tools.sandbox.mask_dirs")
    local found_mask = false
    for _, d in ipairs(mask_list) do if d == "/tmp/mask-y" then found_mask = true end end
    t.true_(found_mask, "遮蔽目录应写入配置")
    -- 快照
    local snap = sr.list_dirs()
    t.eq(1, #snap.workspace, "快照工作目录数应为 1")
    t.eq(#mask_list, #snap.mask, "快照遮蔽目录数应与配置一致")
    -- 删除（按序号）
    t.true_(sr.remove_dir("workspace", 1), "应能删除工作目录")
    t.eq(0, #config_store.get("tools.approval.allowed_directories"), "删除后工作目录应为空")
    t.false_(sr.remove_dir("mask", 99), "越界序号应失败")
    -- 切换遮蔽开关
    local before = config_store.get("tools.sandbox.mask_dirs_enabled")
    local now = sr.toggle_mask_dirs_enabled()
    t.eq(not before, now, "切换后开关应翻转")
    t.eq(not before, config_store.get("tools.sandbox.mask_dirs_enabled"), "配置应随之更新")
    config_store.load({})
  end)

  it("E 键打开目录编辑器并含两列表", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    local config_store = require("NeoAI.kernel.config_store")
    sr.reset()
    config_store.load({
      tools = { approval = { allowed_directories = { "/tmp/ws-b" } } },
    })
    local saved = services.use("services.sandbox")
    _provide_sandbox({
      list_reviews = function() return {} end,
      list_traces = function() return {} end,
      list_saved = function() return {} end,
      apply = function() return { ok = true } end,
      reject = function() end,
    })
    sr.open()
    sr.open_page("resource")
    local buf = sr.get_buf()
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == "E" then m.callback() end
    end
    local ebuf = sr.get_dirs_editor_buf()
    t.not_nil(ebuf, "E 应打开目录编辑器")
    local text = table.concat(vim.api.nvim_buf_get_lines(ebuf, 0, -1, false), "\n")
    t.matches("工作目录列表", text, "编辑器应含工作目录列表")
    t.matches("遮蔽目录列表", text, "编辑器应含遮蔽目录列表")
    t.matches("/tmp/ws%-b", text, "编辑器应展示预置工作目录")
    sr.close()
    t.eq(nil, sr.get_dirs_editor_buf(), "关闭审批窗应同时关闭目录编辑器")
    services.provide("services.sandbox", saved)
    config_store.load({})
  end)

  it("「已拒绝」区展示且 u 触发恢复为待审", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    sr.reset()
    local saved = services.use("services.sandbox")
    local restored = {}
    _provide_sandbox({
      list_reviews = function() return {} end,
      list_traces = function() return {} end,
      list_saved = function() return {} end,
      list_rejected = function()
        return {
          { change_set_id = "csRJ", tool = "edit_file", reject_reason = "USER_DENIED",
            files = { { path = "/root/x.txt" } } },
        }
      end,
      apply = function() return { ok = true } end,
      reject = function() end,
      restore = function(id) restored[#restored + 1] = id; return { ok = true, state = "PENDING" } end,
    })
    sr.open()
    local buf = sr.get_buf()
    t.not_nil(buf, "应打开审批窗")
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    t.matches("已拒绝", text, "应展示已拒绝区")
    t.matches("csRJ", text, "应展示被拒条目")
    t.matches("USER_DENIED", text, "应展示拒绝原因")
    local rej_line
    for ln, target in pairs(sr.get_line_map()) do
      if target.change_set_id == "csRJ" and target.rejected then rej_line = rej_line or ln end
    end
    t.not_nil(rej_line, "已拒绝条目应映射恢复目标")
    vim.api.nvim_win_set_cursor(0, { rej_line, 0 })
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == "u" then m.callback() end
    end
    t.eq(1, #restored, "u 应触发恢复")
    t.eq("csRJ", restored[1], "恢复目标应正确")
    sr.close()
    services.provide("services.sandbox", saved)
  end)

  it("应用后光标停在原行号（不随条目移入已应用区）", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    sr.reset()
    local saved = services.use("services.sandbox")
    local cwd = vim.fn.getcwd()
    local pending = {
      { change_set_id = "csA", tool = "edit_file", files = { { path = cwd .. "/a.lua" } } },
      { change_set_id = "csB", tool = "edit_file", files = { { path = cwd .. "/b.lua" } } },
    }
    local saved_items = {}
    _provide_sandbox({
      list_reviews = function() return vim.deepcopy(pending) end,
      list_traces = function() return {} end,
      list_saved = function() return vim.deepcopy(saved_items) end,
      list_rejected = function() return {} end,
      apply = function(id)
        for i, it in ipairs(pending) do
          if it.change_set_id == id then table.remove(pending, i); break end
        end
        saved_items[#saved_items + 1] = { change_set_id = id, tool = "edit_file",
          apply_state = "APPLIED", saved_files = { { path = cwd .. "/a.lua" } } }
        return { ok = true, state = "APPLIED" }
      end,
      reject = function() end,
      reject_file = function() end,
    })
    sr.open()
    local buf = sr.get_buf()
    local win = vim.fn.bufwinid(buf)
    local file_line
    for ln, target in pairs(sr.get_line_map()) do
      if target.change_set_id == "csA" and target.path then file_line = ln end
    end
    t.not_nil(file_line, "应定位 csA 文件行")
    vim.api.nvim_win_set_cursor(win, { file_line, 0 })
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == "<CR>" then m.callback() end
    end
    local after = vim.api.nvim_win_get_cursor(win)[1]
    t.eq(file_line, after, "应用后光标应停在原行号（不随条目移动）")
    sr.close()
    services.provide("services.sandbox", saved)
  end)

  it("切回 NeoAI 界面（焦点恢复）时审批窗自动刷新", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    local event_bus = require("NeoAI.kernel.event_bus")
    local events = require("NeoAI.kernel.events")
    sr.reset()
    local saved = services.use("services.sandbox")
    local cwd = vim.fn.getcwd()
    local items = { { change_set_id = "csFocus1", tool = "edit_file",
      files = { { path = cwd .. "/z.lua" } } } }
    _provide_sandbox({
      list_reviews = function() return vim.deepcopy(items) end,
      list_traces = function() return {} end,
      list_saved = function() return {} end,
      list_rejected = function() return {} end,
      apply = function() return { ok = true } end,
      reject = function() end,
    })
    sr.open()
    local buf = sr.get_buf()
    t.matches("csFocus1", table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"),
      "初始应展示待审条目")
    -- 切走期间产生新待审项（窗口未聚焦，事件刷新可能滞后/丢失）
    items[#items + 1] = { change_set_id = "csFocus2", tool = "edit_file",
      files = { { path = cwd .. "/y.lua" } } }
    -- 切回 NeoAI 界面：广播焦点恢复 → 审批窗强制刷新，展示新条目
    event_bus.emit(events.UI_FOCUS_CHANGED, { focused = true })
    local found = vim.wait(2000, function()
      if not (buf and vim.api.nvim_buf_is_valid(buf)) then return false end
      for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if l:find("csFocus2", 1, true) then return true end
      end
      return false
    end, 10)
    t.true_(found, "切回焦点后审批窗应刷新出新条目")
    sr.close()
    services.provide("services.sandbox", saved)
  end)
end)
