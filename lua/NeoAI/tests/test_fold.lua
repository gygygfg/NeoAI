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
    -- 构造与 message_list 输出一致的行结构（含空白分隔行）
    local lines = {
      "🤖 AI",
      "  思考一",
      "  思考二",
      "  ⏳ 调用工具: git_status({})",
      "  ✅ 工具: git_status",
      "  M f1",
      "  ⏳ 调用工具: run_command({})",
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
    t.eq(4, vim.fn.foldclosed(4), "git_status 调用块应独立折叠")
    t.eq(7, vim.fn.foldclosed(7), "run_command 调用块应独立折叠")
    t.eq(0, vim.fn.foldlevel(10), "正文不应折叠")

    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
