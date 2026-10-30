--- 沙箱待审审批界面测试
--- @module 'NeoAI.tests.test_sandbox_review'
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
    local has_section = false
    for _, lv in pairs(fl) do
      t.true_(lv == 1 or lv == 2 or lv == 3, "已应用区折叠级别只允许 1/2/3")
      if lv == 3 then has_section = true end
    end
    t.true_(has_section, "条目内「调用参数 / 安全审查」应为三级折叠")
  end)

  it("build_lines 待审条目两级折叠：条目一级 / 参数与审查二级", function(t)
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
    t.eq(1, fl[head], "条目头行应为一层折叠起点")
    for ln = head + 1, last do
      t.true_(fl[ln] == 1 or fl[ln] == 2, "条目内各行应有折叠级别（1/2）")
    end
    -- 「调用参数」「安全审查」二级折叠
    local args_ln, sec_ln
    for i, l in ipairs(data.lines) do
      if l:find("调用参数", 1, true) then args_ln = i end
      if l:find("安全审查", 1, true) then sec_ln = i end
    end
    t.eq(2, fl[args_ln], "调用参数应为二级折叠")
    t.eq(2, fl[sec_ln], "安全审查应为二级折叠")
    local tail
    for i = #data.lines, head + 1, -1 do
      if data.lines[i] == "" then tail = i; break end
    end
    t.not_nil(tail, "条目后应有空行")
    t.eq(nil, fl[tail], "条目尾空行不应登记折叠级别（避免相邻条目合并）")
  end)

  it("build_lines 待审 git 原子组登记整组两级折叠", function(t)
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
    t.eq(1, fl[head], "git 组头行应为一层折叠起点")
    for ln = head + 1, last do
      t.true_(fl[ln] == 1 or fl[ln] == 2, "git 组内提示/文件行应有折叠级别（1/2）")
    end
    local tail
    for i = #data.lines, head + 1, -1 do
      if data.lines[i] == "" then tail = i; break end
    end
    t.not_nil(tail, "组后应有空行")
    t.eq(nil, fl[tail], "组尾空行不应登记折叠级别（避免相邻组合并）")
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
    t.eq(head, closed(head), "git 组头行（收起条目）应为折叠起点")
    t.eq(head, closed(head + 1), "头行之后（文件列表）默认应处于折叠中")
    vim.api.nvim_win_set_cursor(win, { head, 0 })
    vim.api.nvim_win_call(win, function() vim.cmd("normal! zo") end)
    t.eq(-1, closed(head), "zo 后条目应展开")
    t.eq(-1, closed(head + 1), "展开条目后文件列表应可见")
    sr.close()
    services.provide("services.sandbox", saved)
  end)

  it("build_lines 待审条目折叠摘要显示被修改的文件（不显示命令）", function(t)
    local sr = require("NeoAI.ui.components.sandbox_review")
    local cwd = vim.fn.getcwd()
    local data = sr.build_lines({ { change_set_id = "csCmd", tool = "run_command", risk_level = 1,
      command = "sed -i 's/a/b/' p.lua q.lua",
      files = { { path = cwd .. "/p.lua" }, { path = cwd .. "/q.lua" } } } }, {}, nil, {})
    local head
    for i, l in ipairs(data.lines) do
      if l:find("csCmd", 1, true) then head = i end
    end
    t.not_nil(head, "应有头行")
    local all = table.concat(data.lines, "\n")
    t.true_(all:find("sed -i", 1, true) ~= nil, "条目内仍应展示命令（调用参数区，仅供展开查看）")
    local title = (data.fold_titles or {})[head]
    t.not_nil(title, "条目头行应登记折叠摘要")
    t.true_(title:find("2 个文件", 1, true) ~= nil, "摘要应含修改文件数: " .. title)
    t.eq(nil, title:find("sed", 1, true), "摘要不应包含命令: " .. title)
  end)

  it("open 后待审条目折叠文本显示文件而不是命令", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    sr.reset()
    local saved = services.use("services.sandbox")
    local cwd = vim.fn.getcwd()
    _provide_sandbox({
      list_reviews = function()
        return { { change_set_id = "csCmdOpen", tool = "run_command", risk_level = 1,
          command = "sed -i 's/a/b/' mod.lua",
          files = { { path = cwd .. "/mod.lua" } } } }
      end,
      list_traces = function() return {} end,
      list_saved = function() return {} end,
      apply = function() return { ok = true } end,
      reject = function() end,
    })
    sr.open()
    local buf = assert(sr.get_buf(), "应创建审批 buffer")
    local win = vim.fn.bufwinid(buf)
    t.true_(win ~= -1, "审批 buffer 应在窗口中显示")
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local head
    for i, l in ipairs(lines) do
      if l:find("csCmdOpen", 1, true) then head = i end
    end
    t.not_nil(head, "应有头行")
    local closed = vim.api.nvim_win_call(win, function() return vim.fn.foldclosed(head) end)
    local text = vim.api.nvim_win_call(win, function() return vim.fn.foldtextresult(closed) end)
    t.eq(head, closed, "条目头行默认收起")
    t.true_(text:find("1 个文件", 1, true) ~= nil, "折叠文本应显示修改文件数: " .. text)
    t.eq(nil, text:find("sed", 1, true), "折叠文本不应显示命令: " .. text)
    sr.close()
    services.provide("services.sandbox", saved)
  end)

  it("build_lines 渲染调用参数区：大文本省略、保留关键参数", function(t)
    local sr = require("NeoAI.ui.components.sandbox_review")
    local cwd = vim.fn.getcwd()
    local data = sr.build_lines({ {
      change_set_id = "csArgs", tool = "write_file", risk_level = 1,
      args_preview = {
        fields = { { key = "path", value = "a.lua" }, { key = "mode", value = "overwrite" } },
        omitted = { { key = "content", bytes = 2048 } },
        truncated = false,
      },
      files = { { path = cwd .. "/a.lua", action = "modify" } },
    } }, {}, nil, {})
    local text = table.concat(data.lines, "\n")
    t.matches("调用参数 · write_file · 3 项", text)
    t.matches("path  a.lua", text)
    t.matches("content  <2048 字节，已省略>", text)
    t.eq(nil, text:find(string.rep("x", 100), 1, true), "不应渲染大文本内容")
  end)

  it("args_preview 对大文本省略并做密钥脱敏", function(t)
    local ap = require("NeoAI.sandbox.review.args_preview")
    local p = assert(ap.build({
      path = "a.lua",
      content = string.rep("x", 4096),
      token = "ghp_abcdefghijklmnopqrst",
      timeout_ms = 120000,
    }))
    local by_key = {}
    for _, f in ipairs(p.fields or {}) do by_key[f.key] = f.value end
    for _, o in ipairs(p.omitted or {}) do by_key[o.key] = o.bytes end
    t.eq("a.lua", by_key.path)
    t.eq(4096, by_key.content)
    t.eq("120000", by_key.timeout_ms)
    t.matches("%[REDACTED", by_key.token, "token 不应明文展示")
  end)

  it("收起条目按 <CR> 只展开，不应用；展开后 <CR> 才应用", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    sr.reset()
    local saved = services.use("services.sandbox")
    local cwd = vim.fn.getcwd()
    local applied = 0
    _provide_sandbox({
      list_reviews = function()
        return { { change_set_id = "csCR", tool = "edit_file", risk_level = 1,
          files = { { path = cwd .. "/cr.lua", action = "modify" } } } }
      end,
      list_traces = function() return {} end,
      list_saved = function() return {} end,
      apply = function() applied = applied + 1; return { ok = true } end,
      reject = function() end,
    })
    sr.open()
    local buf = assert(sr.get_buf())
    local win = vim.fn.bufwinid(buf)
    local head
    for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if l:find("csCR", 1, true) then head = i end
    end
    t.not_nil(head, "应有条目头行")
    vim.api.nvim_win_set_cursor(win, { head, 0 })
    local cr
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == "<CR>" then cr = m.callback end
    end
    t.not_nil(cr, "应有 <CR> 键位")
    cr()
    t.eq(0, applied, "收起条目按 <CR> 不应应用")
    t.eq(-1, vim.api.nvim_win_call(win, function() return vim.fn.foldclosed(head) end),
      "收起条目按 <CR> 应展开")
    cr()
    t.eq(1, applied, "展开后条目头行按 <CR> 应应用整单元")
    sr.close()
    services.provide("services.sandbox", saved)
  end)

  it("光标文件行高亮：普通条目单文件，整包高亮全部文件", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    local function _marks()
      local ns = vim.api.nvim_get_namespaces()["NeoAISandboxReviewTarget"]
      if not ns then return {} end
      return vim.api.nvim_buf_get_extmarks(sr.get_buf(), ns, 0, -1, {})
    end
    local function _open_with(item)
      sr.reset()
      local saved = services.use("services.sandbox")
      _provide_sandbox({
        list_reviews = function() return { item } end,
        list_traces = function() return {} end,
        list_saved = function() return {} end,
        apply = function() return { ok = true } end,
        reject = function() end,
      })
      sr.open()
      local buf = assert(sr.get_buf())
      local win = vim.fn.bufwinid(buf)
      vim.wo[win].foldlevel = 99
      local file_line
      for ln, tgt in pairs(sr.get_line_map()) do
        if tgt.path then file_line = ln end
      end
      t.not_nil(file_line, "应有文件行")
      vim.api.nvim_win_set_cursor(win, { file_line, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
      local n = #_marks()
      sr.close()
      services.provide("services.sandbox", saved)
      return n
    end
    local cwd = vim.fn.getcwd()
    t.eq(1, _open_with({ change_set_id = "csHi1", tool = "edit_file",
      files = { { path = cwd .. "/1.lua" }, { path = cwd .. "/2.lua" } } }),
      "普通条目只高亮当前文件行")
    t.eq(2, _open_with({ change_set_id = "csHi2", tool = "run_command", package = true,
      files = { { path = cwd .. "/p1.lua" }, { path = cwd .. "/p2.lua" } } }),
      "整包条目应高亮全部文件行")
  end)

  it("open 后两个二级分区是独立折叠（不会合并成一个）", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    sr.reset()
    local saved = services.use("services.sandbox")
    local cwd = vim.fn.getcwd()
    _provide_sandbox({
      list_reviews = function()
        return { { change_set_id = "csTwo", tool = "write_file", risk_level = 1,
          files = { { path = cwd .. "/two.lua" } } } }
      end,
      list_traces = function() return {} end,
      list_saved = function() return {} end,
      apply = function() return { ok = true } end,
      reject = function() end,
    })
    sr.open()
    local buf = assert(sr.get_buf())
    local win = vim.fn.bufwinid(buf)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local head, args_ln, sec_ln
    for i, l in ipairs(lines) do
      if l:find("csTwo", 1, true) then head = i end
      if l:find("▾ 调用参数", 1, true) then args_ln = i end
      if l:find("▾ 安全审查", 1, true) then sec_ln = i end
    end
    t.not_nil(head, "应有条目头")
    t.not_nil(args_ln, "应有调用参数区")
    t.not_nil(sec_ln, "应有安全审查区")
    local function closed(ln)
      return vim.api.nvim_win_call(win, function() return vim.fn.foldclosed(ln) end)
    end
    vim.api.nvim_win_set_cursor(win, { head, 0 })
    vim.api.nvim_win_call(win, function() vim.cmd("normal! zo") end)
    t.eq(args_ln, closed(args_ln), "调用参数应独立收起")
    t.eq(sec_ln, closed(sec_ln), "安全审查应独立收起")
    vim.api.nvim_win_set_cursor(win, { args_ln, 0 })
    vim.api.nvim_win_call(win, function() vim.cmd("normal! zo") end)
    t.eq(-1, closed(args_ln), "调用参数应可单独展开")
    t.eq(sec_ln, closed(sec_ln), "展开调用参数不应展开安全审查")
    sr.close()
    services.provide("services.sandbox", saved)
  end)

  it("刷新后保持用户展开的条目折叠状态", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    sr.reset()
    local saved = services.use("services.sandbox")
    local cwd = vim.fn.getcwd()
    _provide_sandbox({
      list_reviews = function()
        return { { change_set_id = "csKeep", tool = "write_file", risk_level = 1,
          files = { { path = cwd .. "/keep.lua" } } } }
      end,
      list_traces = function() return {} end,
      list_saved = function() return {} end,
      apply = function() return { ok = true } end,
      reject = function() end,
    })
    sr.open()
    local buf = assert(sr.get_buf())
    local win = vim.fn.bufwinid(buf)
    local function head_line()
      for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if l:find("csKeep", 1, true) then return i end
      end
    end
    local h1 = head_line()
    t.not_nil(h1, "应有条目头")
    vim.api.nvim_win_set_cursor(win, { h1, 0 })
    vim.api.nvim_win_call(win, function() vim.cmd("normal! zo") end)
    sr.refresh()
    local h2 = head_line()
    t.not_nil(h2, "刷新后仍应有条目头")
    t.eq(-1, vim.api.nvim_win_call(win, function() return vim.fn.foldclosed(h2) end),
      "刷新后应保持用户展开的条目")
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

  it("应用后 fold_all 使整个审批窗全部折叠（已应用区回到默认收起）", function(t)
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
            saved_files = { { path = "/root/a.txt" } } },
        }
      end,
      apply = function() return { ok = true } end,
      reject = function() end,
    })
    sr.open()
    local buf = sr.get_buf()
    local win = vim.fn.bufwinid(buf)
    t.true_(win ~= -1, "审批 buffer 应在窗口中显示")

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local title_ln
    for i, l in ipairs(lines) do
      if l:find("已应用", 1, true) and l:find("──", 1, true) then title_ln = i end
    end
    t.not_nil(title_ln, "应有已应用区标题")
    local function closed(ln)
      return vim.api.nvim_win_call(win, function() return vim.fn.foldclosed(ln) end)
    end
    -- 模拟用户/既往状态：把折叠级别抬到 2 并手动展开
    vim.wo[win].foldlevel = 2
    vim.api.nvim_win_set_cursor(win, { title_ln, 0 })
    vim.api.nvim_win_call(win, function() vim.cmd("normal! zo") end)
    t.eq(-1, closed(title_ln), "抬升 foldlevel + zo 后区标题应展开")

    sr.fold_all()
    t.eq(0, sr.get_foldlevel(), "fold_all 后折叠级别应回到 0（整体收起）")
    t.eq(title_ln, closed(title_ln), "fold_all 后已应用区标题应处于折叠状态")

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

  it("越界/异常页展示「临时写入留痕」（只读，不产生待审）", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    sr.reset()
    local saved = services.use("services.sandbox")
    _provide_sandbox({
      list_reviews = function() return {} end,
      list_traces = function() return {} end,
      list_ephemeral = function()
        return {
          { tool = "run_command", path = "/tmp/build/out.o",
            command = "cc -c a.c -o /tmp/build/out.o" },
        }
      end,
      apply = function() return { ok = true } end,
      reject = function() end,
    })
    sr.open()
    sr.open_page("anomaly")
    local buf = sr.get_buf()
    t.not_nil(buf, "应打开审批窗")
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = table.concat(lines, "\n")
    t.matches("临时写入留痕", text, "应展示临时写入留痕区")
    local line
    for i, l in ipairs(lines) do
      if l:find("/tmp/build/out.o", 1, true) then line = i end
    end
    t.not_nil(line, "应展示临时写入留痕行")
    t.eq(nil, sr.get_line_map()[line], "临时写入留痕行不应是审批目标")
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
      -- 只看文件行（恰好 8 空格缩进）；调用参数区里的 command 行（10 空格）也含路径，需排除。
      if ln and ln:sub(1, 8) == "        " and ln:sub(9, 9) ~= " " then
        if ln:find("src/a.lua", 1, true) then ws = m.level end
        if ln:find("/etc/hosts", 1, true) then sys = m.level end
      end
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

  it("L3 二进制文件 diff 显示占位而非乱码", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    local l3 = require("NeoAI.sandbox.review.l3_warning")
    sr.reset()
    l3.reset()
    l3.set_generator(function(_, _, on_done) on_done("警告") end)
    local saved = services.use("services.sandbox")
    local cwd = vim.fn.getcwd()
    local path = cwd .. "/l3bin.shada"
    local fs = require("NeoAI.utils.fs")
    fs.write_file(path, "abc\0\1\2old")
    _provide_sandbox({
      list_reviews = function()
        return {
          {
            change_set_id = "csL3bin", tool = "run_command", risk_level = 3,
            risk_name = "critical", risk_reasons = { "SECRET_OPERATION_OUTSIDE_WORKSPACE" },
            files = { { path = path, action = "modify", content = "xyz\0\3new" } },
          },
        }
      end,
      apply = function() return { ok = true } end,
      reject = function() end, reject_file = function() end,
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
    t.not_nil(dbuf, "L3 应打开 diff")
    local dtext = table.concat(vim.api.nvim_buf_get_lines(dbuf, 0, -1, false), "\n")
    t.matches("二进制文件", dtext, "二进制应显示占位而非文本 diff")
    t.eq(nil, dtext:find("\0", 1, true), "diff 不应含 NUL 乱码")
    sr.close()
    l3.reset()
    fs.delete_file(path)
    services.provide("services.sandbox", saved)
  end)

  it("L3 条目首次 <CR> 打开 AI 警告 diff，二次确认后才应用", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    local l3 = require("NeoAI.sandbox.review.l3_warning")
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
    local l3 = require("NeoAI.sandbox.review.l3_warning")
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
    local l3 = require("NeoAI.sandbox.review.l3_warning")
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
    local l3 = require("NeoAI.sandbox.review.l3_warning")
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
    local review = require("NeoAI.sandbox.review.review")
    ---@type table<string, any>
    local store = require("NeoAI.sandbox.state.store")
    ---@type table<string, any>
    local candidate = require("NeoAI.sandbox.execution.candidate")
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
    local item = assert(review.enqueue(make_cand(), { tool = "git_add" }))
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
    local item2 = assert(review.enqueue(make_cand(), { tool = "git_add" }))
    review.reject_file(item2.change_set_id, dir .. "/work.txt")
    local after = assert(review.get(item2.change_set_id))
    t.eq(review.REVIEW.REJECTED, after.review_state, "reject_file 应整组拒绝 git 原子组")
    review.reset()
  end)

  it("应用发布抛异常：结算为 FAILED 并回退待审（不卡 APPLYING，可重试）", function(t)
    local review = require("NeoAI.sandbox.review.review")
    local store = require("NeoAI.sandbox.state.store")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    review.reset()
    local dir = vim.fn.tempname()
    local function make_cand()
      return {
        candidate_digest = "sha256:gitthrow-" .. tostring(vim.uv.hrtime()),
        files = {
          { path = dir .. "/.git/objects/ab/cd", action = "create", content = "obj", after_hash = "h1" },
          { path = dir .. "/.git/index", action = "modify", content = "idx", after_hash = "h2" },
        },
      }
    end
    local item = assert(review.enqueue(make_cand(), { tool = "git_add" }))
    local orig_read, orig_pub = store.read_candidate, candidate.publish
    store.read_candidate = function() return make_cand() end
    candidate.publish = function() error("boom-publish") end
    local res = review.apply(item.change_set_id, { auto_approve = true })
    t.true_(not res.ok, "抛异常应结算为失败而不是冒出异常")
    t.eq("FAILED", res.state)
    t.matches("PUBLISH_ERROR", res.reason)
    local after = assert(review.get(item.change_set_id))
    t.eq(review.APPLY.FAILED, after.apply_state, "应置为 FAILED")
    t.eq(review.REVIEW.PENDING, after.review_state, "应回退待审（自动批准被撤销）")
    -- 恢复后重试应成功（证明未卡在 APPLYING）。
    candidate.publish = function()
      return { ok = true, state = "COMMITTED", receipt = { operation_id = "op_retry" } }
    end
    local res2 = review.apply(item.change_set_id, { auto_approve = true })
    t.true_(res2.ok, "重试应成功: " .. tostring(res2 and res2.reason))
    store.read_candidate, candidate.publish = orig_read, orig_pub
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
    local hub = require("NeoAI.sandbox.review.approval_hub")
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

  it("网络请求页三段式：本会话已允许可 d 撤销 + 历史只读", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    sr.reset()
    local saved = services.use("services.sandbox")
    local revoked
    _provide_sandbox({
      list_reviews = function() return {} end,
      list_traces = function() return {} end,
      list_saved = function() return {} end,
      apply = function() return { ok = true } end,
      reject = function() end,
      net_consent_allowances = function()
        return { { key = "127.0.0.1:5432@/usr/bin/postgres", host = "127.0.0.1", port = 5432,
          base = "127.0.0.1:5432", svc = "/usr/bin/postgres", comm = "postgres", pid = 7 } }
      end,
      net_consent_history = function()
        return { { host = "example.com", port = 443, decision = "allow_once", at_ms = 1700000000000 },
          { host = "bad.example", port = 80, decision = "deny" } }
      end,
      net_consent_revoke = function(key) revoked = key; return true end,
    })
    sr.open()
    sr.open_page("network")
    local buf = sr.get_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = table.concat(lines, "\n")
    t.matches("本会话已允许", text, "应展示本会话已允许段")
    t.matches("127.0.0.1:5432", text, "应展示允许条目")
    t.matches("postgres", text, "应展示服务身份")
    t.matches("历史", text, "应展示历史段")
    t.matches("已允许%(单次%)", text, "历史应展示单次允许")
    t.matches("已拒绝", text, "历史应展示拒绝")
    -- 定位允许行并 d 撤销
    local allow_line
    for i, l in ipairs(lines) do
      if l:find("127.0.0.1:5432", 1, true) then allow_line = i end
    end
    t.not_nil(allow_line, "应能定位允许行")
    vim.api.nvim_win_set_cursor(0, { allow_line, 0 })
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == "d" then m.callback() end
    end
    t.eq("127.0.0.1:5432@/usr/bin/postgres", revoked, "d 应撤销本会话允许")
    sr.close()
    services.provide("services.sandbox", saved)
  end)

  it("网络请求页：历史去重与超时拒绝行按 S 重新允许（含待批准去重计数）", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    local hub = require("NeoAI.sandbox.review.approval_hub")
    sr.reset()
    local saved = services.use("services.sandbox")
    local granted
    _provide_sandbox({
      list_reviews = function() return {} end,
      list_traces = function() return {} end,
      list_saved = function() return {} end,
      apply = function() return { ok = true } end,
      reject = function() end,
      net_consent_allowances = function() return {} end,
      net_consent_history = function()
        return {
          { key = "127.0.0.1:5432@/usr/bin/postgres", host = "127.0.0.1", port = 5432,
            comm = "postgres", decision = "deny", reason = "timeout",
            at_ms = 1700000000000, count = 3, timed_out = true },
          { key = "example.com:443", host = "example.com", port = 443,
            decision = "allow_once", at_ms = 1700000000000, count = 1 },
        }
      end,
      net_consent_revoke = function() return true end,
      net_consent_allow_history = function(key) granted = key; return true end,
    })
    -- 同一目标两个并发请求 → 审批中心合并为一条（×2）
    local decisions = {}
    for i = 1, 2 do
      hub.submit("network", {
        title = "127.0.0.1:9999（mockd pid 42）",
        dedupe_key = "127.0.0.1:9999@/usr/bin/mockd",
        on_decision = function(v) decisions[i] = v end,
      })
    end
    sr.open()
    sr.open_page("network")
    local buf = sr.get_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = table.concat(lines, "\n")
    t.matches("×2 个请求", text, "待批准条目应提示合并的请求数")
    t.matches("已拒绝%(超时%) ×3", text, "历史应展示超时拒绝与合并次数")
    t.matches("S 重新允许", text, "历史行应提示可重新允许")
    t.matches("已允许%(单次%)", text, "历史应展示单次允许")
    -- 定位历史超时行并 S 重新允许
    local hist_line
    for i, l in ipairs(lines) do
      if l:find("已拒绝(超时)", 1, true) then hist_line = i end
    end
    t.not_nil(hist_line, "应能定位超时拒绝历史行")
    vim.api.nvim_win_set_cursor(0, { hist_line, 0 })
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == "S" then m.callback() end
    end
    t.eq("127.0.0.1:5432@/usr/bin/postgres", granted, "S 应请求重新允许对应目标")
    -- d 在该行不支持（仅提示，不调撤销/决策）
    vim.api.nvim_win_set_cursor(0, { hist_line, 0 })
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == "d" then m.callback() end
    end
    t.eq(1, hub.pending_count("network"), "历史行 d 不应影响待批准条目")
    sr.close()
    hub.reset()
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

  it("资源访问页工作目录列表同步会话工作目录（不可删除）", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    local config_store = require("NeoAI.kernel.config_store")
    sr.reset()
    config_store.load({ tools = { approval = { allowed_directories = {} } } })
    local saved_sb = services.use("services.sandbox")
    local saved_chat = services.use("services.chat_service")
    _provide_sandbox({
      list_reviews = function() return {} end,
      list_traces = function() return {} end,
      list_saved = function() return {} end,
      apply = function() return { ok = true } end,
      reject = function() end,
    })
    services.provide("services.chat_service", {
      get_current_agent = function() return { cwd = "/tmp/session-ws" } end,
    })
    sr.open()
    sr.open_page("resource")
    local text = table.concat(vim.api.nvim_buf_get_lines(sr.get_buf(), 0, -1, false), "\n")
    t.matches("/tmp/session%-ws", text, "应展示会话工作目录")
    t.matches("会话工作目录", text, "应标注会话工作目录")
    local snap = sr.list_dirs()
    t.eq(0, #snap.workspace, "显式配置列表应为空（会话工作目录单独呈现）")
    t.eq("/tmp/session-ws", snap.session_cwd, "快照应含会话工作目录")
    sr.close()
    services.provide("services.sandbox", saved_sb)
    services.provide("services.chat_service", saved_chat)
    config_store.load({})
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

  it("工具行为页设备管理 API：增删改生效且去重", function(t)
    local sr = require("NeoAI.ui.components.sandbox_review")
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({})
    t.true_(sr.add_device("/dev/kvm"), "应能新增允许设备")
    t.false_(sr.add_device("/dev/kvm"), "重复设备应被去重拒绝")
    t.eq("/dev/kvm", config_store.get("tools.sandbox.devices.allowed")[1], "应写入配置")
    local snap = sr.list_devices()
    t.eq(1, #snap.allowed, "快照允许设备数应为 1")
    t.true_(#snap.paths > 0, "危险设备模式应有默认值")
    t.true_(sr.remove_device(1), "应能删除")
    t.eq(0, #sr.list_devices().allowed, "删除后应为空")
    t.false_(sr.remove_device(99), "越界应失败")
    config_store.load({})
  end)

  it("E 键在工具行为页打开设备编辑器", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    local config_store = require("NeoAI.kernel.config_store")
    sr.reset()
    config_store.load({ tools = { sandbox = { devices = { allowed = { "/dev/kvm" } } } } })
    local saved = services.use("services.sandbox")
    _provide_sandbox({
      list_reviews = function() return {} end,
      list_traces = function() return {} end,
      list_saved = function() return {} end,
      apply = function() return { ok = true } end,
      reject = function() end,
    })
    sr.open()
    sr.open_page("behavior")
    local buf = sr.get_buf()
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == "E" then m.callback() end
    end
    local ebuf = sr.get_devices_editor_buf()
    t.not_nil(ebuf, "E 应打开设备编辑器")
    local text = table.concat(vim.api.nvim_buf_get_lines(ebuf, 0, -1, false), "\n")
    t.matches("允许的设备组件", text, "编辑器应含允许设备区")
    t.matches("危险设备模式", text, "编辑器应含危险设备区")
    t.matches("/dev/kvm", text, "编辑器应展示预置允许设备")
    sr.close()
    t.eq(nil, sr.get_devices_editor_buf(), "关闭审批窗应同时关闭设备编辑器")
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
        for i, pend_item in ipairs(pending) do
          if pend_item.change_set_id == id then table.remove(pending, i); break end
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

  it("沙箱门面 tool_approval_list 与各 mutator（仅本会话内存态）", function(t)
    local sb = require("NeoAI.sandbox")
    local registry = require("NeoAI.tools.registry")
    local tool_service = require("NeoAI.services.tool_service")
    local config_store = require("NeoAI.kernel.config_store")
    registry.reset()
    tool_service.reset()
    local saved_cfg = config_store.get_all()
    config_store.load({ tools = { approval = {} } })
    registry.register({ name = "facade_tool", description = "门面测试", parameters = {}, category = "test",
      func = function(_, on_success) on_success("ok") end })
    -- 列表含所有工具且带生效/运行期字段
    local found
    for _, item in ipairs(sb.tool_approval_list()) do
      if item.name == "facade_tool" then found = item end
    end
    t.not_nil(found, "列表应含已注册工具")
    t.false_(found.session_allow, "初始非会话允许")
    t.true_(found.allowed_directories ~= nil and found.runtime_directories ~= nil, "应含目录字段")
    -- 会话允许
    t.true_(sb.tool_approval_set_session_allow("facade_tool", true), "设置会话允许应成功")
    t.true_(tool_service.get_allow_all("facade_tool"), "tool_service 应记录会话允许")
    t.true_(vim.tbl_contains(tool_service.list_allow_all(), "facade_tool"), "list_allow_all 应含该工具")
    -- 目录：会话新增可增可删
    t.true_(sb.tool_approval_add_directory("facade_tool", "/tmp/neoai_facade_dir"), "应能加会话目录")
    local rt = registry.get_runtime_approval("facade_tool")
    t.eq(1, #(rt and rt.allowed_directories or {}), "应写入运行期覆盖")
    t.true_(sb.tool_approval_remove_directory("facade_tool", "/tmp/neoai_facade_dir"), "应能删会话新增目录")
    -- 命令组：会话新增可增可删
    t.true_(sb.tool_approval_add_param_group("facade_tool", "facade-group"), "应能加会话命令组")
    t.true_(sb.tool_approval_remove_param_group("facade_tool", "facade-group"), "应能删会话新增命令组")
    registry.reset()
    tool_service.reset()
    config_store.load(saved_cfg)
  end)

  it("工具行为页 T 打开「工具审批条件」编辑器并支持 s/d", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    local config_store = require("NeoAI.kernel.config_store")
    sr.reset()
    config_store.load({ tools = { approval = {} } })
    local saved = services.use("services.sandbox")
    local calls = {}
    _provide_sandbox({
      list_reviews = function() return {} end,
      list_traces = function() return {} end,
      list_saved = function() return {} end,
      apply = function() return { ok = true } end,
      reject = function() end,
      tool_approval_list = function()
        return {
          { name = "srv_tool", category = "test",
            auto_allow = false, session_allow = false,
            allowed_directories = { "/tmp/neoai_cfg1" },
            runtime_directories = { "/tmp/neoai_rt1" },
            allowed_param_groups = { "cfg-g" },
            runtime_param_groups = { "rt-g" } },
        }
      end,
      tool_approval_set_session_allow = function(name, allow)
        calls.session = { name, allow }; return true
      end,
      tool_approval_remove_directory = function(name, dir)
        calls.dir = { name, dir }; return true
      end,
      tool_approval_remove_param_group = function(name, group)
        calls.group = { name, group }; return true
      end,
    })
    sr.open()
    sr.open_page("behavior")
    local buf = sr.get_buf()
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == "T" then m.callback() end
    end
    local ebuf = sr.get_tools_approval_editor_buf()
    t.not_nil(ebuf, "T 应打开「工具审批条件」编辑器")
    local text = table.concat(vim.api.nvim_buf_get_lines(ebuf, 0, -1, false), "\n")
    t.matches("工具审批条件", text, "编辑器应含标题")
    t.matches("srv_tool", text, "编辑器应含工具名")
    t.matches("/tmp/neoai_rt1", text, "编辑器应含本次会话新增目录")
    t.matches("/tmp/neoai_cfg1", text, "编辑器应含配置目录")
    t.matches("来自配置", text, "应标注来自配置的只读项")
    -- 行定位与按键派发
    local function find(pat)
      for i, l in ipairs(vim.api.nvim_buf_get_lines(ebuf, 0, -1, false)) do
        if l:find(pat, 1, true) then return i end
      end
    end
    local function press(key)
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(ebuf, "n")) do
        if m.lhs == key then m.callback(); return end
      end
    end
    local ewin = vim.fn.bufwinid(ebuf)
    -- s：切换光标所在工具的本次会话允许
    vim.api.nvim_win_set_cursor(ewin, { find("srv_tool"), 0 })
    press("s")
    t.not_nil(calls.session, "s 应触发会话允许切换")
    t.eq("srv_tool", calls.session[1])
    t.eq(true, calls.session[2])
    -- d：删除本次会话新增目录
    vim.api.nvim_win_set_cursor(ewin, { find("/tmp/neoai_rt1"), 0 })
    press("d")
    t.not_nil(calls.dir, "d 应删除本次会话新增目录")
    t.eq("/tmp/neoai_rt1", calls.dir[2])
    -- d：删除本次会话新增命令组
    vim.api.nvim_win_set_cursor(ewin, { find("rt-g"), 0 })
    press("d")
    t.not_nil(calls.group, "d 应删除本次会话新增命令组")
    t.eq("rt-g", calls.group[2])
    sr.close()
    t.eq(nil, sr.get_tools_approval_editor_buf(), "关闭审批窗应同时关闭工具审批条件编辑器")
    services.provide("services.sandbox", saved)
    config_store.load({})
  end)

  it("build_lines：执行中的条目显示「执行中…」并使用 busy 高亮", function(t)
    local sr = require("NeoAI.ui.components.sandbox_review")
    local cwd = vim.fn.getcwd()
    local data = sr.build_lines({
      {
        change_set_id = "cs_busy",
        tool = "edit_file",
        apply_state = "APPLYING",
        files = { { path = cwd .. "/busy.txt", action = "modify" } },
      },
    }, nil, nil, nil, nil, {
      cs_busy = { state = "running", kind = "apply" },
    })
    local found
    for _, m in ipairs(data.marks) do
      local text = data.lines[m.line]:sub(m.start_col + 1, m.end_col)
      if text == "执行中…" then found = m end
    end
    t.not_nil(found, "应有「执行中…」标签")
    t.eq("NeoAISandboxReviewBusy", found.level, "应使用 busy 高亮")
  end)
end)
