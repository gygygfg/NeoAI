--- NeoAI 界面 buffer 的 LSP 隔离专项测试
--- @module NeoAI.tests.test_lsp_guard
--- 覆盖：neoai* filetype 自动关闭 LSP/Copilot 标记、acwrite 不被改写、安装/卸载幂等。

local tests = require("NeoAI.tests")

tests.suite("lsp_guard", function(_, it)
  local guard = require("NeoAI.ui.lsp_guard")

  it("neoai* buffer 被标记并关闭 Copilot / 设为 nofile", function(t)
    guard.install()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "neoai_input" -- 触发 FileType 拦截
    t.eq(true, vim.b[buf].neoai_ui, "应标记 b:neoai_ui")
    t.eq(true, vim.b[buf].copilot_disabled, "应设置 copilot.vim 的 b:copilot_disabled")
    t.eq(true, vim.b[buf].copilot_disable, "应设置 copilot.lua 的 b:copilot_disable")
    t.eq(false, vim.b[buf].copilot_enabled, "应设置 b:copilot_enabled=false")
    t.eq("nofile", vim.bo[buf].buftype, "普通 buftype 应改为 nofile 阻断 native LSP")
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    guard.install() -- 确保仍安装（不影响后续套件）
  end)

  it("acwrite buffer 保留 buftype（轨迹模式 :w 保存依赖）", function(t)
    guard.install()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].filetype = "neoai" -- 触发 FileType 拦截
    t.eq("acwrite", vim.bo[buf].buftype, "acwrite 不应被改写为 nofile")
    t.eq(true, vim.b[buf].neoai_ui, "仍应打标记")
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    guard.install()
  end)

  it("install/uninstall 幂等且可清理 augroup", function(t)
    guard.install()
    t.true_(vim.fn.exists("#NeoAILspGuard#FileType") ~= 0, "安装后应有 FileType 拦截")
    guard.uninstall()
    t.eq(0, vim.fn.exists("#NeoAILspGuard#FileType"), "卸载后 augroup 应移除")
    guard.install() -- 恢复，避免影响后续套件
    t.true_(vim.fn.exists("#NeoAILspGuard#LspAttach") ~= 0, "恢复后应有 LspAttach 兜底")
  end)

  it("通过 g:copilot_filetypes 从源头禁用 Copilot 并可在卸载时恢复", function(t)
    guard.uninstall() -- 清掉 ui.init 已安装的状态，便于从干净基线验证
    vim.g.copilot_filetypes = { lua = true }
    guard.install()
    t.eq(false, vim.g.copilot_filetypes.neoai_input, "install 应禁用 neoai_input 的 Copilot")
    t.eq(false, vim.g.copilot_filetypes.neoai_reasoning, "install 应禁用 neoai_reasoning 的 Copilot")
    t.eq(true, vim.g.copilot_filetypes.lua, "不应覆盖用户既有条目")
    guard.uninstall()
    t.eq(true, vim.g.copilot_filetypes.lua, "卸载后用户条目应保留")
    t.eq(nil, vim.g.copilot_filetypes.neoai_input, "卸载后应移除注入的禁用项")
    guard.install() -- 恢复，避免影响后续套件
  end)
end)
