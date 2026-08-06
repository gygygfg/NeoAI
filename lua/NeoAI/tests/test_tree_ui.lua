local tests = require("NeoAI.tests")

tests.suite("tree_ui", function(_, it)
  it("会话树显示用户和 AI 摘要而非会话 ID", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    local fs = require("NeoAI.utils.fs")
    local session_store = require("NeoAI.core.session.session_store")
    local tree_view = require("NeoAI.ui.window.tree_view")
    config_store.load({ session = { save_path = "/tmp/neoai_tree_ui_test", file = "sessions.jsonl" } })
    tree_view.reset()
    session_store.reset()
    fs.delete_file("/tmp/neoai_tree_ui_test/sessions.jsonl")
    session_store.init()

    local session = session_store.create({ messages = {
      { role = "user", content = "这是超过二十个中文文字的用户问题内容用于验证截断" },
      { role = "assistant", content = "", tool_calls = { { id = "call_1" } } },
      { role = "tool", content = "中间工具步骤不应显示" },
      { role = "assistant", content = "这是超过二十个中文文字的人工智能回答内容用于验证截断" },
      { role = "user", content = "第二轮用户消息" },
      { role = "assistant", content = "第二轮 AI 回复" },
    } })
    session_store.create({ parent_id = session.id, messages = {
      { role = "user", content = "分支会话" },
    } })
    session_store.create({ messages = {
      { role = "user", content = "第二个根会话" },
    } })
    local opened = tree_view.open()
    local rendered = table.concat(vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false), "\n")

    t.true_(rendered:find("👤 用户：这是超过二十个中文文字的用户问题内容用于...", 1, true) ~= nil)
    t.true_(rendered:find("🤖 AI：这是超过二十个中文文字的人工智能回答内容...", 1, true) ~= nil)
    t.true_(rendered:find("👤 用户：第二轮用户消息 | 🤖 AI：第二轮 AI 回复", 1, true) ~= nil,
      "每次 Agent 执行应显示为单独节点")
    t.true_(rendered:find("中间工具步骤不应显示", 1, true) == nil, "工具步骤不应拆分为会话节点")
    t.true_(rendered:find(session.id, 1, true) == nil, "不应显示会话 ID")
    t.true_(rendered:find("├─", 1, true) ~= nil, "应使用 ├─ 连接兄弟节点")
    t.true_(rendered:find("└─", 1, true) ~= nil, "应使用 └─ 标记最后节点")
    t.true_(rendered:find("│", 1, true) ~= nil, "应使用 │ 延续祖先分支")
    t.true_(rendered:find("▾", 1, true) == nil, "不应显示展开图标")
    t.true_(rendered:find("•", 1, true) == nil, "不应显示节点图标")

    tree_view.reset()
    session_store.reset()
  end)
end)
