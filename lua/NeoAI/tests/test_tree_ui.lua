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

    -- 先创建第二个根会话，再创建带分支的主根会话，并显式让主根 updated_at 更新，
    -- 保证 get_roots() 按 updated_at 倒序时主根排第一（渲染与断言确定，不受哈希遍历顺序影响）
    session_store.create({ messages = {
      { role = "user", content = "第二个根会话" },
    } })
    local session = session_store.create({
      messages = {
        { role = "user", content = "这是超过二十个中文文字的用户问题内容用于验证截断" },
        { role = "assistant", content = "", tool_calls = { { id = "call_1" } } },
        { role = "tool", content = "中间工具步骤不应显示" },
        { role = "assistant", content = "这是超过二十个中文文字的人工智能回答内容用于验证截断" },
        { role = "user", content = "第二轮用户消息" },
        { role = "assistant", content = "第二轮 AI 回复" },
      },
      updated_at = os.time() + 60,
    })
    session_store.create({ parent_id = session.id, messages = {
      { role = "user", content = "分支会话" },
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

  it("从树选择会话自动关闭树窗口并打开聊天", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    local fs = require("NeoAI.utils.fs")
    local session_store = require("NeoAI.core.session.session_store")
    local tree_view = require("NeoAI.ui.window.tree_view")
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    config_store.load({ session = { save_path = "/tmp/neoai_tree_select_test", file = "sessions.jsonl" } })
    tree_view.reset()
    chat_view.reset()
    chat_service.reset()
    session_store.reset()
    fs.delete_file("/tmp/neoai_tree_select_test/sessions.jsonl")
    session_store.init()

    local session = session_store.create({
      messages = {
        { role = "user", content = "从树打开的问题" },
        { role = "assistant", content = "从树打开的回复" },
      },
    })
    local opened = tree_view.open()
    t.true_(tree_view.has_window(), "树窗口应已打开")

    -- 模拟在树窗口按 <CR> 选择当前会话
    vim.api.nvim_set_current_win(opened.win_id)
    local mapping = vim.fn.maparg("<CR>", "n", false, true)
    t.not_nil(mapping.callback, "树窗口应注册回车选择映射")
    mapping.callback()

    t.false_(tree_view.has_window(), "选择会话后树窗口应自动关闭")
    t.true_(chat_view.has_window(), "聊天窗口应已打开")
    t.eq(session.id, chat_service.get_current_session_id(), "应加载被选中的会话")

    tree_view.reset()
    chat_view.reset()
    chat_service.reset()
    session_store.reset()
  end)

  it("关闭自动关闭配置时选择会话保留树窗口", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    local fs = require("NeoAI.utils.fs")
    local session_store = require("NeoAI.core.session.session_store")
    local tree_view = require("NeoAI.ui.window.tree_view")
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    config_store.load({
      session = { save_path = "/tmp/neoai_tree_select_test", file = "sessions.jsonl" },
      ui = { tree = { auto_close_on_select = false } },
    })
    tree_view.reset()
    chat_view.reset()
    chat_service.reset()
    session_store.reset()
    fs.delete_file("/tmp/neoai_tree_select_test/sessions.jsonl")
    session_store.init()

    local session = session_store.create({
      messages = { { role = "user", content = "保留树的问题" } },
    })
    local opened = tree_view.open()
    vim.api.nvim_set_current_win(opened.win_id)
    local mapping = vim.fn.maparg("<CR>", "n", false, true)
    t.not_nil(mapping.callback)
    mapping.callback()

    t.true_(tree_view.has_window(), "配置关闭时树窗口应保留")
    t.true_(chat_view.has_window(), "聊天窗口应已打开")
    t.eq(session.id, chat_service.get_current_session_id(), "应加载被选中的会话")

    tree_view.reset()
    chat_view.reset()
    chat_service.reset()
    session_store.reset()
  end)

  it("按 N 新建根会话并自动切到聊天界面", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    local fs = require("NeoAI.utils.fs")
    local session_store = require("NeoAI.core.session.session_store")
    local tree_view = require("NeoAI.ui.window.tree_view")
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    config_store.load({ session = { save_path = "/tmp/neoai_tree_new_test", file = "sessions.jsonl" } })
    tree_view.reset()
    chat_view.reset()
    chat_service.reset()
    session_store.reset()
    fs.delete_file("/tmp/neoai_tree_new_test/sessions.jsonl")
    session_store.init()

    local opened = tree_view.open()
    t.eq(0, session_store.count(), "初始应无会话")

    vim.api.nvim_set_current_win(opened.win_id)
    local map_n = vim.fn.maparg("N", "n", false, true)
    t.not_nil(map_n.callback, "树窗口应注册 N 键映射")
    map_n.callback()

    local session_id = chat_service.get_current_session_id()
    t.not_nil(session_id, "按 N 后应创建并加载新会话")
    local created = session_store.get(session_id)
    t.not_nil(created, "新建的空会话不应被清理掉（正在聊天中使用）")
    local session_mod = require("NeoAI.core.session.session")
    t.true_(session_mod.is_root(created), "N 应创建根会话")
    t.true_(chat_view.has_window(), "按 N 后聊天窗口应已打开")
    t.false_(tree_view.has_window(), "按 N 后树窗口应自动关闭")

    -- 等待延迟渲染（SESSION_CREATED 的 vim.schedule）跑完，会话仍应存活
    vim.wait(100)
    t.not_nil(session_store.get(session_id), "延迟重渲染后新会话仍应存在")
    t.eq(session_id, chat_service.get_current_session_id(), "聊天仍未切换会话")

    tree_view.reset()
    chat_view.reset()
    chat_service.reset()
    session_store.reset()
  end)

  it("按 n 新建子分支会话并自动切到聊天界面", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    local fs = require("NeoAI.utils.fs")
    local session_store = require("NeoAI.core.session.session_store")
    local tree_view = require("NeoAI.ui.window.tree_view")
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    config_store.load({ session = { save_path = "/tmp/neoai_tree_new_child_test", file = "sessions.jsonl" } })
    tree_view.reset()
    chat_view.reset()
    chat_service.reset()
    session_store.reset()
    fs.delete_file("/tmp/neoai_tree_new_child_test/sessions.jsonl")
    session_store.init()

    local parent = session_store.create({
      messages = { { role = "user", content = "父会话问题" }, { role = "assistant", content = "父会话回答" } },
    })
    local opened = tree_view.open()
    vim.api.nvim_set_current_win(opened.win_id)
    local map_n = vim.fn.maparg("n", "n", false, true)
    t.not_nil(map_n.callback, "树窗口应注册 n 键映射")
    map_n.callback()

    local session_id = chat_service.get_current_session_id()
    t.not_nil(session_id, "按 n 后应创建并加载新会话")
    t.ne(parent.id, session_id, "n 应新建子会话而非复用父会话")
    local child = session_store.get(session_id)
    t.not_nil(child, "新建的子会话不应被清理掉")
    t.eq(parent.id, child.parent_id, "子会话应挂在当前节点下")
    t.true_(chat_view.has_window(), "按 n 后聊天窗口应已打开")
    t.false_(tree_view.has_window(), "按 n 后树窗口应自动关闭")
    t.not_nil(session_store.get(parent.id), "父会话应保留")

    vim.wait(100)
    t.not_nil(session_store.get(session_id), "延迟重渲染后子会话仍应存在")

    tree_view.reset()
    chat_view.reset()
    chat_service.reset()
    session_store.reset()
  end)

  it("选择子会话打开完整链上下文（祖先+选中+下游）", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    local fs = require("NeoAI.utils.fs")
    local session_store = require("NeoAI.core.session.session_store")
    local tree_view = require("NeoAI.ui.window.tree_view")
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    config_store.load({ session = { save_path = "/tmp/neoai_tree_chain_test", file = "sessions.jsonl" } })
    tree_view.reset()
    chat_view.reset()
    chat_service.reset()
    session_store.reset()
    fs.delete_file("/tmp/neoai_tree_chain_test/sessions.jsonl")
    session_store.init()

    local root = session_store.create({
      messages = { { role = "user", content = "根问题" }, { role = "assistant", content = "根回答" } },
    })
    local child = session_store.create({ parent_id = root.id, messages = {
      { role = "user", content = "分支问题" }, { role = "assistant", content = "分支回答" },
    } })

    local opened = tree_view.open()
    -- 树展开后第二行是子会话节点（根节点下无更多轮次）
    vim.api.nvim_win_set_cursor(opened.win_id, { 2, 0 })
    local mapping = vim.fn.maparg("<CR>", "n", false, true)
    t.not_nil(mapping.callback)
    mapping.callback()

    t.true_(chat_view.has_window(), "聊天窗口应已打开")
    t.eq(child.id, chat_service.get_current_session_id(), "当前会话应为选中的子会话")
    local messages = chat_service.get_messages()
    t.eq(4, #messages, "应载入祖先链（根）+ 选中子会话的全部消息")
    t.eq("根问题", messages[1].content)
    t.eq("根回答", messages[2].content)
    t.eq("分支问题", messages[3].content)
    t.eq("分支回答", messages[4].content)

    tree_view.reset()
    chat_view.reset()
    chat_service.reset()
    session_store.reset()
  end)

  it("关闭自动关闭配置时按 N 保留树窗口且新会话不被清理", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    local fs = require("NeoAI.utils.fs")
    local session_store = require("NeoAI.core.session.session_store")
    local tree_view = require("NeoAI.ui.window.tree_view")
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    config_store.load({
      session = { save_path = "/tmp/neoai_tree_new_keep_test", file = "sessions.jsonl" },
      ui = { tree = { auto_close_on_select = false } },
    })
    tree_view.reset()
    chat_view.reset()
    chat_service.reset()
    session_store.reset()
    fs.delete_file("/tmp/neoai_tree_new_keep_test/sessions.jsonl")
    session_store.init()

    local opened = tree_view.open()
    vim.api.nvim_set_current_win(opened.win_id)
    local map_n = vim.fn.maparg("N", "n", false, true)
    t.not_nil(map_n.callback)
    map_n.callback()

    local session_id = chat_service.get_current_session_id()
    t.not_nil(session_id)
    t.true_(chat_view.has_window(), "聊天窗口应已打开")
    t.true_(tree_view.has_window(), "配置关闭时树窗口应保留")

    -- 树窗口仍打开：让延迟渲染与空会话清理跑完，活跃会话不应被删除
    vim.wait(150)
    t.not_nil(session_store.get(session_id), "树保留时新会话也不应被空会话清理删除")

    tree_view.reset()
    chat_view.reset()
    chat_service.reset()
    session_store.reset()
  end)
end)
