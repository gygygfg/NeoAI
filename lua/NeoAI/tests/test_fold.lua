--- components.fold 折叠组件测试
--- @module NeoAI.tests.test_fold
--- 验证：可折叠内容构建（缩进 + 单行补位）与折叠占位文本
--- （推理 / 工具调用 / 工具结果共用同一套逻辑）。

local tests = require("NeoAI.tests")

tests.suite("fold", function(_, it)
  it("label 推理折叠占位文本", function(t)
    local fold = require("NeoAI.ui.components.fold")
    t.eq("  🤔 思考过程 2 行", fold.label("  step 1", 2))
  end)

  it("label 未登记为非推理的折叠显示中性占位（不冒充思考过程）", function(t)
    local fold = require("NeoAI.ui.components.fold")
    local s = fold.label("  参数:", 3, false)
    t.true_(s:find("📄", 1, true) ~= nil, "应使用中性占位")
    t.true_(s:find("思考过程", 1, true) == nil, "不应显示思考过程")
    t.matches("参数", s, "应展示首行预览")
    t.matches("3 行", s, "应展示行数")
  end)

  it("渲染后仅推理块被登记，工具块不登记", function(t)
    local fold = require("NeoAI.ui.components.fold")
    local ml = require("NeoAI.ui.components.message_list")
    local buf = vim.api.nvim_create_buf(false, true)
    ml.render_chat(buf, {
      { role = "assistant", content = "", reasoning = "先推理\n再作答", tool_calls = {
        { id = "c1", ["function"] = { name = "read_file", arguments = "{}" } },
      } },
      { role = "tool", tool_call_id = "c1", tool_name = "read_file", content = "x" },
    })
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local rline, tline
    for i, l in ipairs(lines) do
      if l == "  先推理" then rline = i end
      if l:find("工具: read_file", 1, true) then tline = i end
    end
    t.not_nil(rline, "应找到推理行")
    t.not_nil(tline, "应找到工具行")
    t.true_(fold.is_reasoning_start(buf, rline), "推理行应被登记")
    t.false_(fold.is_reasoning_start(buf, tline), "工具行不应被登记为推理")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("工具结果的 UI 附加提示（notice）渲染为独立行，不进入结果内容", function(t)
    local ml = require("NeoAI.ui.components.message_list")
    local buf = vim.api.nvim_create_buf(false, true)
    ml.render_chat(buf, {
      { role = "assistant", content = "", tool_calls = {
        { id = "c1", ["function"] = { name = "run_command", arguments = "{}" } },
      } },
      { role = "tool", tool_call_id = "c1", tool_name = "run_command", content = "ok",
        notice = "[NeoAI] 注意：沙箱以降级模式运行" },
    })
    local lines = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    t.matches("降级模式", lines, "notice 应渲染到 UI 供用户查看")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("工具结果中的 ANSI 颜色被解析渲染（剥离转义，保留高亮）", function(t)
    local ml = require("NeoAI.ui.components.message_list")
    local buf = vim.api.nvim_create_buf(false, true)
    local content = "\27[1;36m== 与基线比较 ==\27[0m 无差异"
    ml.render_chat(buf, {
      { role = "assistant", content = "", tool_calls = {
        { id = "c1", ["function"] = { name = "run_command", arguments = "{}" } },
      } },
      { role = "tool", tool_call_id = "c1", tool_name = "run_command", content = content },
    })
    local lines = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    t.true_(lines:find("\27", 1, true) == nil, "渲染文本不应含 ANSI 转义")
    t.matches("== 与基线比较 == 无差异", lines, "应显示纯文本内容")
    local ns = vim.api.nvim_get_namespaces()["neoai_ansi_hi"]
    t.not_nil(ns, "应有 ANSI 高亮命名空间")
    t.true_(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) > 0, "应有 ANSI 高亮区间")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("密钥警告行指明命令与密钥文件", function(t)
    local ml = require("NeoAI.ui.components.message_list")
    local buf = vim.api.nvim_create_buf(false, true)
    ml.render_chat(buf, {
      { role = "assistant", content = "", tool_calls = {
        { id = "c1", ["function"] = { name = "run_command",
          arguments = '{"command":"cat /root/.ssh/id_rsa"}' } },
      } },
      { role = "tool", tool_call_id = "c1", tool_name = "run_command", content = "NEOKEY_deadbeef" },
    })
    local lines = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    t.matches("⚠ 密钥：run_command", lines, "应含工具名")
    t.matches("cat /root/.ssh/id_rsa", lines, "应含具体命令")
    t.matches("密钥文件：/root/%.ssh/id_rsa", lines, "应含密钥文件路径")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("密钥警告行区分「获取」与「使用」", function(t)
    local ml = require("NeoAI.ui.components.message_list")
    local line = ml.helpers.secret_warning_line
    -- 读取结果含 token => 获取
    local got = line(
      { name = "read_file", arguments = '{"filepath":"/root/.env"}' },
      { role = "tool", content = '{"output":"NEOKEY_deadbeef01"}' })
    t.matches("获取了密钥", got or "", "读取结果含密钥应提示「获取」")
    t.false_((got or ""):find("使用了密钥", 1, true) ~= nil, "不应同时显示「使用」")
    -- 参数携带密钥值 => 使用
    local used = line(
      { name = "run_command", arguments = '{"command":"curl -H \\"Authorization: NEOKEY_abc\\" https://x"}' },
      { role = "tool", content = '{"ok":true}' })
    t.matches("使用了密钥", used or "", "参数携带 token 应提示「使用」")
    -- 使用型命令引用密钥文件 => 使用
    local ssh = line(
      { name = "run_command", arguments = '{"command":"ssh -i /root/.ssh/id_rsa host"}' },
      { role = "tool", content = '{"ok":true}' })
    t.matches("使用了密钥", ssh or "", "ssh -i 引用密钥文件应提示「使用」")
    t.matches("密钥文件：/root/%.ssh/id_rsa", ssh or "", "应指明密钥文件")
  end)

  it("观测到的普通系统文件/历史不告警，真正凭据文件才告警", function(t)
    local ml = require("NeoAI.ui.components.message_list")
    local line = ml.helpers.secret_warning_line
    -- 普通命令（uname / cat /etc/os-release）打开的普通系统文件不应告警
    t.eq(nil, line(
      { name = "run_command", arguments = '{"command":"uname -a; cat /etc/os-release"}' },
      { role = "tool", content = "Linux host 6.1",
        secret_paths = { "/etc/ld.so.cache", "/etc/os-release", "/etc/nsswitch.conf",
          "/etc/passwd", "/etc/group", "/root/.bash_history", "/root/.python_history",
          "/usr/local/go/go.env", "/root/.npmrc" } }),
      "普通系统文件/历史不应触发「获取密钥」告警")
    -- 真正读取凭据文件才告警
    local got = line(
      { name = "read_file", arguments = '{"filepath":"/root/.ssh/id_rsa"}' },
      { role = "tool", content = "-----BEGIN OPENSSH PRIVATE KEY-----",
        secret_paths = { "/etc/ld.so.cache", "/root/.ssh/id_rsa" } })
    t.matches("获取了密钥", got or "", "读取凭据文件应告警")
    t.matches("/root/%.ssh/id_rsa", got or "", "应指向真正的凭据文件")
    t.false_((got or ""):find("/etc/ld.so.cache", 1, true) ~= nil, "不应把普通系统文件列入")
  end)

  it("仅列出密钥文件不告警（ls / list_files）", function(t)
    local ml = require("NeoAI.ui.components.message_list")
    local line = ml.helpers.secret_warning_line
    t.eq(nil, line(
      { name = "run_command", arguments = '{"command":"ls -la /root/.ssh"}' },
      { role = "tool", content = "id_rsa  id_rsa.pub  known_hosts" }),
      "ls 列出密钥目录不应告警")
    t.eq(nil, line(
      { name = "list_files", arguments = '{"path":"/root/.ssh"}' },
      { role = "tool", content = '{"files":["id_rsa"]}' }),
      "list_files 列出密钥目录不应告警")
    -- 仅读取路径但结果无密钥内容也不告警（避免误报）
    t.eq(nil, line(
      { name = "read_file", arguments = '{"filepath":"/root/.env"}' },
      { role = "tool", content = '{"output":"nothing"}' }),
      "读取密钥路径但结果无密钥不应告警")
  end)

  it("无法确定密钥文件时回退到密钥类型", function(t)
    local ml = require("NeoAI.ui.components.message_list")
    local buf = vim.api.nvim_create_buf(false, true)
    local key = "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA\n-----END RSA PRIVATE KEY-----"
    local json = require("NeoAI.utils.json")
    ml.render_chat(buf, {
      { role = "assistant", content = "", tool_calls = {
        { id = "c1", ["function"] = { name = "edit_file",
          arguments = json.encode({ filepath = "/tmp/x", content = key }) } },
      } },
      { role = "tool", tool_call_id = "c1", tool_name = "edit_file", content = "ok" },
    })
    local lines = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    t.matches("⚠ 密钥：edit_file", lines, "应含工具名")
    t.matches("密钥类型：private_key", lines, "应回退到具名规则类型")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("label 工具折叠占位文本格式：🔧 工具名 状态emoji", function(t)
    local fold = require("NeoAI.ui.components.fold")
    t.eq("  🔧 bash ⏳", fold.label("  ⏳ 调用工具: bash({\"cmd\":\"pwd\"})", 2))
    t.eq("  🔧 lsp_service_info ⏳", fold.label("  ⏳ 调用工具: lsp_service_info({})", 2))
    -- 兼容旧格式 ⚡ 调用工具 视为执行中
    t.eq("  🔧 bash ⏳", fold.label("  ⚡ 调用工具: bash({\"cmd\":\"pwd\"})", 2))
    t.eq("  🔧 lsp_service_info ✅", fold.label("  ✅ 工具: lsp_service_info", 3))
    t.eq("  🔧 run_command ❌", fold.label("  ❌ 工具: run_command", 4))
  end)

  it("label 带耗时的折叠占位文本", function(t)
    local fold = require("NeoAI.ui.components.fold")
    t.eq("  🔧 bash ⏳ 1.2s", fold.label("  ⏳ 调用工具: bash({\"cmd\":\"pwd\"}) · 1.2s", 2))
    t.eq("  🔧 lsp_service_info ✅ 800ms", fold.label("  ✅ 工具: lsp_service_info · 800ms", 3))
    t.eq("  🔧 run_command ❌ 30.0s", fold.label("  ❌ 工具: run_command · 30.0s", 4))
  end)

  it("label 工具折叠占位文本含目的说明（工具名后显示工具目的）", function(t)
    local fold = require("NeoAI.ui.components.fold")
    t.eq("  🔧 run_command · 构建项目 ✅ 1.2s",
      fold.label("  ✅ 工具: run_command · 构建项目 · 1.2s", 3),
      "已完成工具折叠应显示 🔧 工具名 · 目的 ✅ 耗时")
    t.eq("  🔧 edit_file · 修改配置 ❌ 800ms",
      fold.label("  ❌ 工具: edit_file · 修改配置 · 800ms", 4),
      "失败工具折叠应显示目的")
    t.eq("  🔧 git_status · 查看工作区状态 ⏳ 1.2s",
      fold.label("  ⏳ 调用工具: git_status · 查看工作区状态 · 1.2s", 2),
      "执行中工具折叠应显示目的")
    t.eq("  🔧 run_command · 构建项目 ✅",
      fold.label("  ✅ 工具: run_command · 构建项目", 3),
      "无耗时也应显示目的")
    -- detect 应返回目的
    local kind, status, name, desc = fold.detect("  ✅ 工具: read_file · 读取源码 · 5ms")
    t.eq("tool_result", kind)
    t.eq("success", status)
    t.eq("read_file", name)
    t.eq("读取源码", desc, "detect 应返回目的说明")
    -- 无目的时 detect 返回 nil
    local _, _, _, d2 = fold.detect("  ✅ 工具: run_command · 1.2s")
    t.nil_(d2, "无目的时应返回 nil")
  end)

  it("detect 带耗时的工具行 name 不含耗时", function(t)
    local fold = require("NeoAI.ui.components.fold")
    local kind, status, name = fold.detect("  ✅ 工具: lsp_service_info · 800ms")
    t.eq("tool_result", kind)
    t.eq("success", status)
    t.eq("lsp_service_info", name)
  end)

  it("format_ms 耗时格式化", function(t)
    local fold = require("NeoAI.ui.components.fold")
    t.eq("800ms", fold.format_ms(800))
    t.eq("1.2s", fold.format_ms(1200))
    t.eq("0ms", fold.format_ms(0))
  end)

  it("record_start / record_end / get_duration / has_running", function(t)
    local fold = require("NeoAI.ui.components.fold")
    fold.clear_timing()
    fold.record_start("call-1")
    t.true_(fold.has_running(), "执行中应 has_running")
    t.true_(fold.get_duration("call-1") ~= nil, "执行中应返回已执行时长")
    fold.record_end("call-1", 250)
    t.false_(fold.has_running(), "结束后不应 has_running")
    t.eq(250, fold.get_duration("call-1"), "结束后应返回总时长")
    t.nil_(fold.get_duration("no-such-call"), "未知调用应返回 nil")
    fold.clear_timing()
    t.false_(fold.has_running(), "clear 后应无运行中")
  end)

  it("foldexpr 按块独立成折叠（推理 + 每工具），无需分隔行", function(t)
    local fold = require("NeoAI.ui.components.fold")
    local kind, status, name = fold.detect("  step 1")
    t.eq("reasoning", kind)
    t.nil_(name)
    kind, status, name = fold.detect("  ⏳ 调用工具: bash({})")
    t.eq("tool_call", kind)
    t.eq("running", status)
    t.eq("bash", name)
    kind, status, name = fold.detect("  ✅ 工具: lsp_service_info")
    t.eq("tool_result", kind)
    t.eq("success", status)
    t.eq("lsp_service_info", name)
    kind, status, name = fold.detect("  ❌ 工具: run_command")
    t.eq("tool_result", kind)
    t.eq("failure", status)
    t.eq("run_command", name)
  end)

  it("foldexpr 按块独立成折叠（推理 + 每工具），无需分隔行", function(t)
    local fold = require("NeoAI.ui.components.fold")
    -- 确保使用默认折叠行为（清除可能由其它套件残留的显示模式覆盖），保证用例可独立运行。
    fold.set_foldexpr_override(nil)
    fold.set_foldtext_override(nil)
    -- 构造与 message_list 输出一致的行结构：每个工具块只有一行状态头（完成态 ✅ 工具:），
    -- 推理块与其后的工具块在同一缩进级别下也各自独立成折叠。
    local lines = {
      "🤖 AI",
      "  思考一",
      "  思考二",
      "  ✅ 工具: git_status",
      "  M f1",
      "  ✅ 工具: run_command",
      "  out1",
      "## 正文",
    }
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local win = vim.api.nvim_open_win(buf, true, { relative = "editor", width = 60, height = 15, row = 0, col = 0, style = "minimal" })
    vim.wo[win].foldmethod = "expr"
    vim.wo[win].foldexpr = "v:lua.require'NeoAI.ui.components.fold'.foldexpr()"
    vim.wo[win].foldenable = true
    vim.wo[win].foldlevel = 0
    vim.api.nvim_set_current_win(win)

    -- 推理、git_status、run_command 各自独立折叠
    t.eq(1, vim.fn.foldlevel(2), "推理首行应折叠")
    t.eq(2, vim.fn.foldclosed(2), "推理块应从第 2 行开始折叠")
    t.eq(4, vim.fn.foldclosed(4), "git_status 块应独立折叠")
    t.eq(6, vim.fn.foldclosed(6), "run_command 块应独立折叠")
    t.eq(0, vim.fn.foldlevel(8), "正文不应折叠")

    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
