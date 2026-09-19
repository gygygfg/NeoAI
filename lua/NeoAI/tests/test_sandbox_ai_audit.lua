--- 待审变更 AI 审计测试
--- @module NeoAI.tests.test_sandbox_ai_audit
--- 覆盖：结构化审计文本构造（分级/文件/diff/主机操作/截断）与用户消息提取。

local tests = require("NeoAI.tests")

tests.suite("sandbox_ai_audit", function(_, it)
  it("user_messages 仅保留真实用户消息（排除运行上下文与压缩检查点）", function(t)
    local ai = require("NeoAI.sandbox.ai_audit")
    local agent = {
      messages = {
        { role = "system", content = "sys" },
        { role = "user", content = "第一条" },
        { role = "assistant", content = "回复" },
        { role = "user", content = "运行上下文", runtime_context = true },
        { role = "user", content = "压缩检查点", checkpoint = true },
        { role = "tool", content = "结果" },
        { role = "user", content = { { text = "多模态文本" }, { image_url = "x" } } },
        { role = "user", content = "   " },
      },
    }
    local msgs = ai.user_messages(agent)
    t.eq(2, #msgs)
    t.eq("第一条", msgs[1])
    t.eq("多模态文本", msgs[2])
    t.eq(0, #ai.user_messages(nil))
  end)

  it("build_text 含分级、文件与修改 diff", function(t)
    local ai = require("NeoAI.sandbox.ai_audit")
    local path = vim.fn.tempname() .. ".txt"
    local fh = io.open(path, "w")
    fh:write("line1\nline2\n")
    fh:close()
    local items = {
      {
        change_set_id = "cs_1",
        tool = "edit_file",
        risk_level = 2,
        risk_name = "high",
        risk_reasons = { "写入系统路径" },
        privilege_tier = 1,
        secret_warning = { count = 1 },
        package = true,
        package_manager = "apt",
        package_names = { "curl" },
        files = {
          { path = path, action = "modify", content = "line1\nCHANGED\n" },
        },
      },
    }
    local text = ai.build_text(items, { max_diff_chars = 8000 })
    t.matches("cs_1", text)
    t.matches("edit_file", text)
    t.matches("高危%(L2%)", text)
    t.matches("写入系统路径", text)
    t.matches("T1", text)
    t.matches("敏感凭据", text)
    t.matches("apt: curl", text)
    t.matches("%[modify%] " .. path:gsub("%p", "%%%0"), text)
    t.matches("CHANGED", text)
    t.matches("@@", text)
    os.remove(path)
  end)

  it("build_text 对 create 无差异时回退为内容，delete 显示删除", function(t)
    local ai = require("NeoAI.sandbox.ai_audit")
    local items = {
      {
        change_set_id = "cs_create",
        tool = "edit_file",
        risk_level = 0,
        files = { { path = "/tmp/neoai_audit_new.txt", action = "create", content = "hello world" } },
      },
      {
        change_set_id = "cs_delete",
        tool = "delete_file",
        risk_level = 1,
        files = { { path = "/tmp/neoai_audit_del.txt", action = "delete" } },
      },
    }
    local text = ai.build_text(items)
    t.matches("hello world", text)
    t.matches("cs_delete", text)
    t.matches("%[delete%]", text)
  end)

  it("build_text 覆盖主机操作命令", function(t)
    local ai = require("NeoAI.sandbox.ai_audit")
    local items = {
      {
        change_set_id = "cs_host",
        tool = "run_shell",
        kind = "host_op",
        privilege_tier = 2,
        risk_level = 3,
        risk_reasons = { "特权操作" },
        write_set = { "systemctl restart nginx" },
      },
    }
    local text = ai.build_text(items)
    t.matches("主机操作命令", text)
    t.matches("systemctl restart nginx", text)
    t.matches("严重%(L3%)", text)
  end)

  it("build_text 按 max_total_chars 截断", function(t)
    local ai = require("NeoAI.sandbox.ai_audit")
    local items = {}
    for i = 1, 200 do
      items[i] = {
        change_set_id = "cs_" .. i,
        tool = "edit_file",
        risk_level = 0,
        files = { { path = "/tmp/x" .. i, action = "create", content = string.rep("A", 200) } },
      }
    end
    local text = ai.build_text(items, { max_total_chars = 500 })
    t.true_(#text < 2000, "总长应被截断")
    t.matches("已截断", text)
  end)

  it("build_messages 含系统提示、用户消息与结构化文本", function(t)
    local ai = require("NeoAI.sandbox.ai_audit")
    local items = {
      { change_set_id = "cs_m", tool = "edit_file", risk_level = 1,
        files = { { path = "/tmp/x", action = "create", content = "y" } } },
    }
    local msgs = ai.build_messages(items, { "用户消息一", "用户消息二" }, { max_user_chars = 100 })
    t.eq("system", msgs[1].role)
    t.matches("审计助手", msgs[1].content)
    t.eq("user", msgs[2].role)
    t.eq("用户消息一", msgs[2].content)
    t.eq("用户消息二", msgs[3].content)
    t.eq("user", msgs[4].role)
    t.matches("cs_m", msgs[4].content)
    t.eq(4, #msgs)
  end)

  it("parse_notes 解析并截断到 50 字", function(t)
    local ai = require("NeoAI.sandbox.ai_audit")
    local notes = ai.parse_notes("/a/b.lua => 允许应用，无风险\n[create] /x.txt => 需人工确认")
    t.eq("允许应用，无风险", notes["/a/b.lua"])
    t.eq("需人工确认", notes["/x.txt"])
    local long = string.rep("字", 80)
    local n2 = ai.parse_notes("/p => " .. long, 50)
    t.eq(50, vim.fn.strchars(n2["/p"]), "说明应截断到 50 字")
  end)

  it("build_text 高危变更优先排列且要求安全/不安全结论", function(t)
    local ai = require("NeoAI.sandbox.ai_audit")
    local text = ai.build_text({
      { change_set_id = "low", tool = "edit_file", risk_level = 0,
        files = { { path = "/tmp/low", action = "create", content = "a" } } },
      { change_set_id = "high", tool = "edit_file", risk_level = 3,
        files = { { path = "/tmp/high", action = "create", content = "b" } } },
      { change_set_id = "mid", tool = "edit_file", risk_level = 1,
        files = { { path = "/tmp/mid", action = "create", content = "c" } } },
    })
    t.true_(text:find("## 变更 1：high", 1, true) < text:find("## 变更 2：mid", 1, true), "高危应排第一")
    t.true_(text:find("## 变更 2：mid", 1, true) < text:find("## 变更 3：low", 1, true), "低危应排最后")
    t.matches("安全|不安全", text, "应要求以安全/不安全开头")
    t.matches("高危变更不得省略说明", text, "应强调高危变更不得省略")
  end)

  it("verdict 汇总安全/不安全结论", function(t)
    local ai = require("NeoAI.sandbox.ai_audit")
    t.eq("unsafe", ai.verdict({ ["/a"] = "不安全：写入系统路径" }), "含不安全应判 unsafe")
    t.eq("unsafe", ai.verdict({ ["/a"] = "安全：新增", ["/b"] = "不安全：越权" }), "任一不安全即 unsafe")
    t.eq("safe", ai.verdict({ ["/a"] = "安全：工作区内新增", ["/b"] = "安全：可回滚" }), "全安全判 safe")
    t.eq(nil, ai.verdict({ ["/a"] = "工作区文件，低风险" }), "未按格式给出结论返回 nil")
    t.eq(nil, ai.verdict({}), "无说明返回 nil")
    t.eq(nil, ai.verdict(nil), "nil 返回 nil")
  end)

  it("generate 通过注入生成器返回说明与错误", function(t)
    local ai = require("NeoAI.sandbox.ai_audit")
    ai.reset()
    local got, got_err
    ai.set_generator(function(_, _, on_done)
      on_done({ notes = { ["/a.lua"] = "低风险可应用" }, fallback = nil }, nil)
    end)
    ai.generate({ { change_set_id = "cs1" } }, {}, {}, function(result, err)
      got, got_err = result, err
    end)
    t.eq("低风险可应用", got and got.notes and got.notes["/a.lua"])
    t.eq(nil, got_err)

    ai.set_generator(function(_, _, on_done) on_done(nil, "模型不可用") end)
    local got2, err2
    ai.generate({}, {}, {}, function(result, err) got2, err2 = result, err end)
    t.eq(nil, got2)
    t.eq("模型不可用", err2)
    ai.reset()
  end)

  it("generate 全局并发上限（max_concurrent）", function(t)
    local ai = require("NeoAI.sandbox.ai_audit")
    ai.reset()
    local started = 0
    local pending = {}
    ai.set_generator(function(_, _, on_done)
      started = started + 1
      pending[#pending + 1] = on_done
    end)
    for i = 1, 5 do
      ai.generate({ { change_set_id = "cs" .. i } }, {}, { cfg = { max_concurrent = 2 } },
        function() end)
    end
    t.eq(2, started, "在途请求不应超过上限 2")
    -- 释放一个在途请求：队列中的下一个应补位
    table.remove(pending, 1)({ notes = {} }, nil)
    t.eq(3, started, "释放空位后应启动队列中的下一个")
    -- 依次释放，全部最终都应执行
    local guard = 0
    while #pending > 0 and guard < 20 do
      guard = guard + 1
      table.remove(pending, 1)({ notes = {} }, nil)
    end
    t.eq(5, started, "全部 5 个任务最终都应执行")
    ai.reset()
  end)

  it("build_lines 在文件行下方渲染暗灰审计说明", function(t)
    local sr = require("NeoAI.ui.components.sandbox_review")
    local cwd = vim.fn.getcwd()
    local path = cwd .. "/a.lua"
    local items = {
      { change_set_id = "cs1", tool = "edit_file", files = { { path = path, action = "modify" } } },
    }
    -- 生成中：顶部暗灰状态行
    local pending = sr.build_lines(items, nil, { pending = true })
    t.matches("AI 审计生成中", table.concat(pending.lines, "\n"))
    -- 完成后：说明在文件行正下方，且为 note 高亮
    local done = sr.build_lines(items, nil, { notes = { [path] = "工作区文件，低风险，可应用" } })
    local file_ln
    for ln, target in pairs(done.line_to_target) do
      if target.path == path then file_ln = ln end
    end
    t.not_nil(file_ln, "应有文件行")
    t.matches("工作区文件，低风险，可应用", done.lines[file_ln + 1], "说明应在文件行下方")
    local has_note
    for _, m in ipairs(done.marks) do
      if m.level == "note" and m.line == file_ln + 1 then has_note = true end
    end
    t.true_(has_note, "说明应有 note 高亮")
    -- 失败：状态行
    local failed = sr.build_lines(items, nil, { error = "请求失败" })
    t.matches("请求失败", table.concat(failed.lines, "\n"))
  end)

  it("build_lines 顶部先渲染安全/不安全结论", function(t)
    local sr = require("NeoAI.ui.components.sandbox_review")
    local path = vim.fn.getcwd() .. "/a.lua"
    local items = {
      { change_set_id = "cs1", tool = "edit_file", risk_level = 2,
        files = { { path = path, action = "modify" } } },
    }
    local unsafe = sr.build_lines(items, nil, { notes = { [path] = "不安全：写入系统路径" } })
    t.matches("不安全", unsafe.lines[3], "结论行应说明不安全")
    local has_unsafe
    for _, m in ipairs(unsafe.marks) do
      if m.level == "verdict_unsafe" then has_unsafe = true end
    end
    t.true_(has_unsafe, "不安全结论应使用 verdict_unsafe 高亮")

    local safe = sr.build_lines(items, nil, { notes = { [path] = "安全：工作区内可回滚" } })
    t.matches("安全", safe.lines[3], "结论行应说明安全")
    local has_safe
    for _, m in ipairs(safe.marks) do
      if m.level == "verdict_safe" then has_safe = true end
    end
    t.true_(has_safe, "安全结论应使用 verdict_safe 高亮")
  end)

  it("AI 审计覆盖每条：模型漏答的条目标注待人工确认", function(t)
    local sr = require("NeoAI.ui.components.sandbox_review")
    local cwd = vim.fn.getcwd()
    local items = {
      { change_set_id = "cs1", tool = "edit_file", files = { { path = cwd .. "/a.lua", action = "modify" } } },
      { change_set_id = "cs2", tool = "edit_file", files = { { path = cwd .. "/b.lua", action = "modify" } } },
    }
    local data = sr.build_lines(items, nil, { notes = { [cwd .. "/a.lua"] = "安全：可应用" } })
    local text = table.concat(data.lines, "\n")
    t.matches("安全：可应用", text)
    t.matches("AI 未给出说明", text, "漏答条目应标注待人工确认")
  end)

  it("auto=true 时打开审批窗自动发起 AI 审计", function(t)
    local services = require("NeoAI.kernel.services")
    local config_store = require("NeoAI.kernel.config_store")
    local sr = require("NeoAI.ui.components.sandbox_review")
    local ai = require("NeoAI.sandbox.ai_audit")
    sr.reset()
    ai.reset()
    local called = false
    ai.set_generator(function(_, _, on_done)
      called = true
      on_done({ notes = { ["/x"] = "安全：可应用" }, fallback = nil }, nil)
    end)
    local saved_sandbox = services.use("services.sandbox")
    local saved_cfg = config_store.get_all()
    local cwd = vim.fn.getcwd()
    services.provide("services.sandbox", {
      list_reviews = function()
        return { { change_set_id = "csAuto", tool = "edit_file",
          files = { { path = cwd .. "/a.lua", action = "modify" } } } }
      end,
      list_traces = function() return {} end,
    })
    config_store.load({ tools = { sandbox = { review = { ai_audit = { auto = true } } } } })
    local ok, err = pcall(function() sr.open() end)
    config_store.load(saved_cfg)
    services.provide("services.sandbox", saved_sandbox)
    sr.close()
    ai.reset()
    if not ok then error(err, 0) end
    t.true_(called, "auto=true 应在打开审批窗时自动发起 AI 审计")
  end)

  it("build_lines 主机操作说明可匹配带 $ 前缀的模型输出", function(t)
    local sr = require("NeoAI.ui.components.sandbox_review")
    local cmd = "systemctl restart nginx"
    local items = {
      { change_set_id = "csH", tool = "run_shell", kind = "host_op",
        privilege_tier = 2, risk_level = 3, write_set = { cmd } },
    }
    local data = sr.build_lines(items, nil, { notes = { ["$ " .. cmd] = "不安全：重启系统服务" } })
    local text = table.concat(data.lines, "\n")
    t.matches("不安全：重启系统服务", text, "带 $ 前缀的命令说明应渲染到命令行下方")
  end)

  it("待审审批界面按配置绑定 AI 审计按键", function(t)
    local services = require("NeoAI.kernel.services")
    local sr = require("NeoAI.ui.components.sandbox_review")
    sr.reset()
    local saved = services.use("services.sandbox")
    local cwd = vim.fn.getcwd()
    services.provide("services.sandbox", {
      list_reviews = function()
        return {
          { change_set_id = "csA", tool = "edit_file", files = { { path = cwd .. "/a.lua", action = "modify" } } },
        }
      end,
      list_traces = function() return {} end,
    })
    sr.open()
    local buf = sr.get_buf()
    t.eq(true, vim.wo.wrap, "审批窗应开启自动换行")
    t.eq(true, vim.wo.linebreak, "审批窗应开启 linebreak")
    local found
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == "a" then found = m end
    end
    t.not_nil(found, "应绑定 a 键（AI 审计）")
    t.matches("AI 审计", found.desc or "", "按键应有描述")
    sr.close()
    services.provide("services.sandbox", saved)
  end)
end)
