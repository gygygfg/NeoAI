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
