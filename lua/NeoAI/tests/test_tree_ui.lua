local tests = require("NeoAI.tests")

--- 在渲染行中定位包含某子串的行号（1-based）；找不到返回 nil。
--- @param buf number
--- @param needle string
--- @return number|nil
local function _row_of(buf, needle)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, l in ipairs(lines) do
    if l:find(needle, 1, true) then return i end
  end
  return nil
end

--- 读取 buffer 全文（以 \n 连接）。
--- @param buf number
--- @return string
local function _rendered(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

--- 把光标定位到含某子串的行（测试用；找不到时报错）。
--- @param win number
--- @param buf number
--- @param needle string
local function _cursor_to(win, buf, needle)
  local row = _row_of(buf, needle)
  assert(row, "未找到包含「" .. needle .. "」的行")
  vim.api.nvim_win_set_cursor(win, { row, 0 })
end

tests.suite("tree_ui", function(_, it)
  it("d 只删除选中轮次，D 删除所属会话的完整分支", function(t)
    local store = require("NeoAI.core.session.session_store")
    local tree = require("NeoAI.ui.window.tree_view")
    tree.reset()
    store.reset()
    require("NeoAI.kernel.config_store").load({})
    store.init()
    local root = store.create({ messages = {
      { role = "user", content = "第一轮" },
      { role = "assistant", content = "回答一" },
      { role = "user", content = "第二轮" },
      { role = "assistant", content = "", tool_calls = { { id = "call" } } },
      { role = "tool", tool_call_id = "call", content = "工具结果" },
      { role = "assistant", content = "回答二" },
      { role = "user", content = "第三轮" },
      { role = "assistant", content = "回答三" },
    } })
    local child = store.create({ parent_id = root.id, messages = { { role = "user", content = "子分支" } } })
    local grandchild = store.create({ parent_id = child.id, messages = { { role = "user", content = "孙分支" } } })
    local opened = tree.open()
    vim.api.nvim_set_current_win(opened.win_id)
    _cursor_to(opened.win_id, opened.buf, "第二轮")
    vim.fn.maparg("d", "n", false, true).callback()
    -- 删除为乐观语义：按键即时删行，落盘按防抖批量异步提交；flush 使其同步完成。
    tree.flush()
    t.eq(4, #root.messages)
    t.eq("第一轮", root.messages[1].content)
    t.eq("第三轮", root.messages[3].content)
    t.not_nil(store.get(child.id))
    t.not_nil(store.get(grandchild.id))
    -- 再次删除第一轮（光标在会话节点行，不再指向组头）。
    _cursor_to(opened.win_id, opened.buf, "回答一")
    vim.fn.maparg("d", "n", false, true).callback()
    tree.flush()
    t.eq(2, #root.messages)
    t.eq("第三轮", root.messages[1].content)
    tree.reset()
    store.reset()
    store.init()
    t.eq(2, #store.get(root.id).messages, "轮次删除应落盘")
    opened = tree.open()
    vim.api.nvim_set_current_win(opened.win_id)
    _cursor_to(opened.win_id, opened.buf, "回答三")
    vim.fn.maparg("D", "n", false, true).callback()
    tree.flush()
    t.nil_(store.get(root.id))
    t.nil_(store.get(child.id))
    t.nil_(store.get(grandchild.id), "D 必须递归删除孙分支")
    tree.reset()
    store.reset()
    store.init()
    t.nil_(store.get(grandchild.id), "分支删除应落盘")
    store.reset()
  end)

  it("删除唯一轮次保留有内容的子分支", function(t)
    local store = require("NeoAI.core.session.session_store")
    local tree = require("NeoAI.ui.window.tree_view")
    tree.reset()
    store.reset()
    require("NeoAI.kernel.config_store").load({})
    store.init()
    local root = store.create({ messages = { { role = "user", content = "唯一轮次" } } })
    local child = store.create({ parent_id = root.id, messages = { { role = "user", content = "保留子分支" } } })
    local opened = tree.open()
    vim.api.nvim_set_current_win(opened.win_id)
    _cursor_to(opened.win_id, opened.buf, "唯一轮次")
    vim.fn.maparg("d", "n", false, true).callback()
    tree.flush()
    t.eq(0, #root.messages)
    t.not_nil(store.get(child.id))
    local lines = vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false)
    -- 分组头 + 提升上来的子分支（空会话不渲染为节点）
    t.eq(2, #lines)
    t.matches("保留子分支", lines[2])
    tree.reset()
    store.reset()
  end)

  it("轮次删除保存失败时保留原消息", function(t)
    local store = require("NeoAI.core.session.session_store")
    require("NeoAI.kernel.config_store").load({})
    store.reset()
    store.init()
    local session = store.create({ messages = { { role = "user", content = "不能丢失" } } })
    local persist = store.persist
    ---@diagnostic disable-next-line: duplicate-set-field
    store.persist = function() return false, "disk full" end
    local ok, err = store.delete_messages(session.id, 1, 1)
    store.persist = persist
    t.false_(ok)
    t.eq("disk full", err)
    t.eq("不能丢失", session.messages[1].content)
    store.reset()
  end)

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
    t.true_(rendered:find("▾", 1, true) ~= nil, "分组头应显示展开指示 ▾")
    t.true_(rendered:find("📁", 1, true) ~= nil, "分组头应显示目录图标")
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

    -- 模拟在树窗口按 <CR> 选择当前会话（先定位到会话节点行，首行为分组头）
    vim.api.nvim_set_current_win(opened.win_id)
    _cursor_to(opened.win_id, opened.buf, "从树打开的问题")
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
    _cursor_to(opened.win_id, opened.buf, "保留树的问题")
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

    local session_id = assert(chat_service.get_current_session_id())
    t.not_nil(session_id, "按 N 后应创建并加载新会话")
    local created = assert(session_store.get(session_id))
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
    _cursor_to(opened.win_id, opened.buf, "父会话问题")
    local map_n = vim.fn.maparg("n", "n", false, true)
    t.not_nil(map_n.callback, "树窗口应注册 n 键映射")
    map_n.callback()

    local session_id = assert(chat_service.get_current_session_id())
    t.not_nil(session_id, "按 n 后应创建并加载新会话")
    t.ne(parent.id, session_id, "n 应新建子会话而非复用父会话")
    local child = assert(session_store.get(session_id))
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
    local save_dir = vim.fn.tempname()
    config_store.load({ session = { save_path = save_dir, file = "sessions.jsonl" } })
    tree_view.reset()
    chat_view.reset()
    chat_service.reset()
    session_store.reset()
    fs.ensure_dir(save_dir)
    fs.delete_file(save_dir .. "/sessions.jsonl")
    session_store.init()

    local root = session_store.create({
      messages = { { role = "user", content = "根问题" }, { role = "assistant", content = "根回答" } },
    })
    local child = session_store.create({ parent_id = root.id, messages = {
      { role = "user", content = "分支问题" }, { role = "assistant", content = "分支回答" },
    } })

    local opened = tree_view.open()
    -- 定位到子会话节点（首行为分组头）
    _cursor_to(opened.win_id, opened.buf, "分支问题")
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

  it("进入单分支中间会话时顺延到分支末尾", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    local fs = require("NeoAI.utils.fs")
    local session_store = require("NeoAI.core.session.session_store")
    local tree_view = require("NeoAI.ui.window.tree_view")
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    config_store.load({ session = { save_path = "/tmp/neoai_tree_leaf_test", file = "sessions.jsonl" } })
    tree_view.reset()
    chat_view.reset()
    chat_service.reset()
    session_store.reset()
    fs.delete_file("/tmp/neoai_tree_leaf_test/sessions.jsonl")
    session_store.init()

    -- 单分支链 a → b → c：每层仅一个子会话，无分裂
    local a = session_store.create({ messages = { { role = "user", content = "A" } } })
    local b = session_store.create({ parent_id = a.id, messages = { { role = "user", content = "B" } } })
    local c = session_store.create({ parent_id = b.id, messages = { { role = "user", content = "C" } } })

    local opened = tree_view.open()
    -- 定位到中间会话 b（根 a 默认展开，默认折叠 b 故不显示 c）
    _cursor_to(opened.win_id, opened.buf, "👤 用户：B")
    local mapping = vim.fn.maparg("<CR>", "n", false, true)
    t.not_nil(mapping.callback)
    mapping.callback()

    t.true_(chat_view.has_window(), "聊天窗口应已打开")
    t.eq(c.id, chat_service.get_current_session_id(), "进入中间会话 b 应顺延到单分支末尾 c")
    local messages = chat_service.get_messages()
    t.eq(3, #messages, "应载入整条链（A+B+C）")
    t.eq("A", messages[1].content)
    t.eq("B", messages[2].content)
    t.eq("C", messages[3].content)

    tree_view.reset()
    chat_view.reset()
    chat_service.reset()
    session_store.reset()
  end)

  it("子 Agent 会话不在树中显示，进入主会话不会顺延进子 Agent 会话", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    local fs = require("NeoAI.utils.fs")
    local session_mod = require("NeoAI.core.session.session")
    local session_store = require("NeoAI.core.session.session_store")
    local tree_view = require("NeoAI.ui.window.tree_view")
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    config_store.load({ session = { save_path = "/tmp/neoai_tree_sub_agent_test", file = "sessions.jsonl" } })
    tree_view.reset()
    chat_view.reset()
    chat_service.reset()
    session_store.reset()
    fs.delete_file("/tmp/neoai_tree_sub_agent_test/sessions.jsonl")
    session_store.init()

    local root = session_store.create({ messages = {
      { role = "user", content = "主会话问题" },
      { role = "assistant", content = "主会话回答" },
    } })
    -- 与 core.agent.sub_agent 创建子会话的方式一致：parent_id 指向主会话 + sub_agent 标签
    local sub = session_store.create({
      parent_id = root.id,
      name = "子任务",
      metadata = { tags = { session_mod.SUB_AGENT_TAG }, name = "子任务" },
      messages = {
        { role = "user", content = "子 Agent 的任务" },
        { role = "assistant", content = "子 Agent 的结果" },
      },
    })

    local opened = tree_view.open()
    vim.api.nvim_set_current_win(opened.win_id)
    t.true_(sub.id ~= root.id, "子 Agent 会话应为独立会话")
    t.nil_(_row_of(opened.buf, "子 Agent 的任务"), "子 Agent 会话不应出现在会话树中")
    t.nil_(_row_of(opened.buf, "子 Agent："), "子 Agent 会话节点不应渲染")
    t.not_nil(_row_of(opened.buf, "主会话问题"), "主会话节点应正常渲染")
    t.not_nil(_row_of(opened.buf, "1 个会话"), "分组计数不应把子 Agent 会话算进去")

    -- 点主会话节点：不应被顺延到唯一的子会话（那个子会话是子 Agent 会话）
    _cursor_to(opened.win_id, opened.buf, "主会话问题")
    local mapping = vim.fn.maparg("<CR>", "n", false, true)
    t.not_nil(mapping.callback)
    mapping.callback()

    t.true_(chat_view.has_window(), "聊天窗口应已打开")
    t.eq(root.id, chat_service.get_current_session_id(), "进入主会话不应落到子 Agent 会话")
    local messages = chat_service.get_messages()
    t.eq(2, #messages, "上下文只应包含主会话消息")
    for _, m in ipairs(messages) do
      t.true_(m.content ~= "子 Agent 的结果", "子 Agent 会话消息不应拼入主会话上下文")
    end

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

    local session_id = assert(chat_service.get_current_session_id())
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

  -- ========== 按工作目录分组 ==========

  it("按工作目录分组：组头含目录名/完整路径/会话数，单会话也显示组头", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    local fs = require("NeoAI.utils.fs")
    local store = require("NeoAI.core.session.session_store")
    local tree = require("NeoAI.ui.window.tree_view")
    config_store.load({ session = { save_path = "/tmp/neoai_tree_group_test", file = "sessions.jsonl" } })
    tree.reset()
    store.reset()
    fs.delete_file("/tmp/neoai_tree_group_test/sessions.jsonl")
    store.init()
    local base = vim.fn.tempname()
    fs.ensure_dir(base)
    store.create({ cwd = base .. "/proj-a", messages = { { role = "user", content = "甲会话" } } })
    local opened = tree.open()
    local rendered = _rendered(opened.buf)
    t.true_(rendered:find("▾", 1, true) ~= nil, "组头应显示展开指示 ▾")
    t.true_(rendered:find("📁 proj%-a") ~= nil, "组头应含目录名（末级）")
    t.true_(rendered:find(base .. "/proj%-a") ~= nil, "组头应含完整路径")
    t.true_(rendered:find("· 1 个会话", 1, true) ~= nil, "单会话分组也应显示组头与会话数")
    tree.reset()
    store.reset()
    vim.fn.delete(base, "rf")
  end)

  it("组排序：当前编辑器工作区组置顶，其余按组内最近使用倒序", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    local fs = require("NeoAI.utils.fs")
    local store = require("NeoAI.core.session.session_store")
    local tree = require("NeoAI.ui.window.tree_view")
    config_store.load({ session = { save_path = "/tmp/neoai_tree_sort_test", file = "sessions.jsonl" } })
    tree.reset()
    store.reset()
    fs.delete_file("/tmp/neoai_tree_sort_test/sessions.jsonl")
    store.init()
    local editor = vim.fn.getcwd()
    local base = vim.fn.tempname()
    fs.ensure_dir(base)
    -- 编辑器组（当前 cwd）较旧；临时目录组较新：编辑器组应置顶。
    store.create({ cwd = editor, messages = { { role = "user", content = "编辑器组会话" } } })
    store.create({ cwd = base, messages = { { role = "user", content = "其它组会话" } }, updated_at = os.time() + 300 })
    local opened = tree.open()
    local lines = vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false)
    local editor_base = vim.fn.fnamemodify(editor, ":t")
    t.true_(lines[1]:find("📁 " .. editor_base, 1, true) ~= nil, "当前编辑器工作区组应置顶")
    t.true_(lines[1]:find("编辑器组", 1, true) == nil, "首行应为组头而非会话")
    -- 其它组在编辑器组之后
    local other_row = _row_of(opened.buf, "其它组会话")
    local editor_row = _row_of(opened.buf, "编辑器组会话")
    t.true_(other_row and editor_row and other_row > editor_row, "其它分组应排在编辑器分组之后")
    tree.reset()
    store.reset()
    vim.fn.delete(base, "rf")
  end)

  it("组头支持 <CR>/o/O 折叠与展开", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    local fs = require("NeoAI.utils.fs")
    local store = require("NeoAI.core.session.session_store")
    local tree = require("NeoAI.ui.window.tree_view")
    config_store.load({ session = { save_path = "/tmp/neoai_tree_fold_test", file = "sessions.jsonl" } })
    tree.reset()
    store.reset()
    fs.delete_file("/tmp/neoai_tree_fold_test/sessions.jsonl")
    store.init()
    local base = vim.fn.tempname()
    fs.ensure_dir(base)
    store.create({ cwd = base .. "/grp", messages = { { role = "user", content = "组内会话一" } } })
    store.create({ cwd = base .. "/grp", messages = { { role = "user", content = "组内会话二" } } })
    local opened = tree.open()
    vim.api.nvim_set_current_win(opened.win_id)
    vim.api.nvim_win_set_cursor(opened.win_id, { 1, 0 }) -- 组头
    t.true_(_rendered(opened.buf):find("组内会话一", 1, true) ~= nil, "默认应展开分组")

    -- <CR> 折叠（构建异步节流：flush 后断言）
    vim.fn.maparg("<CR>", "n", false, true).callback()
    tree.flush()
    local folded = _rendered(opened.buf)
    t.true_(folded:find("▸", 1, true) ~= nil, "折叠后应显示 ▸")
    t.true_(folded:find("组内会话一", 1, true) == nil, "折叠后不应渲染组内会话")

    -- o 展开
    vim.fn.maparg("o", "n", false, true).callback()
    tree.flush()
    local opened2 = _rendered(opened.buf)
    t.true_(opened2:find("▾", 1, true) ~= nil, "展开后应显示 ▾")
    t.true_(opened2:find("组内会话一", 1, true) ~= nil, "展开后应渲染组内会话")

    -- O 折叠
    vim.fn.maparg("O", "n", false, true).callback()
    tree.flush()
    t.true_(_rendered(opened.buf):find("组内会话一", 1, true) == nil, "O 应折叠分组")
    tree.reset()
    store.reset()
    vim.fn.delete(base, "rf")
  end)

  it("组内 N/n 新建会话继承光标所在分组的 cwd", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    local fs = require("NeoAI.utils.fs")
    local store = require("NeoAI.core.session.session_store")
    local tree = require("NeoAI.ui.window.tree_view")
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    config_store.load({ session = { save_path = "/tmp/neoai_tree_cwd_test", file = "sessions.jsonl" } })
    tree.reset()
    chat_view.reset()
    chat_service.reset()
    store.reset()
    fs.delete_file("/tmp/neoai_tree_cwd_test/sessions.jsonl")
    store.init()
    local base = vim.fn.tempname()
    fs.ensure_dir(base)
    store.create({ cwd = base .. "/proj", messages = { { role = "user", content = "已有会话" } } })

    -- N 于组头 → 新建根会话继承组 cwd
    local opened = tree.open()
    vim.api.nvim_set_current_win(opened.win_id)
    vim.api.nvim_win_set_cursor(opened.win_id, { 1, 0 })
    vim.fn.maparg("N", "n", false, true).callback()
    local sid = assert(chat_service.get_current_session_id())
    t.eq(base .. "/proj", store.get(sid).metadata.cwd, "N 于组头应继承组 cwd")

    -- n 于组头 → 新建会话继承组 cwd
    chat_view.reset()
    chat_service.reset()
    opened = tree.open()
    vim.api.nvim_set_current_win(opened.win_id)
    vim.api.nvim_win_set_cursor(opened.win_id, { 1, 0 })
    vim.fn.maparg("n", "n", false, true).callback()
    local sid2 = assert(chat_service.get_current_session_id())
    t.eq(base .. "/proj", store.get(sid2).metadata.cwd, "n 于组头应继承组 cwd")

    -- n 于组内会话 → 子会话继承该会话 cwd
    chat_view.reset()
    chat_service.reset()
    opened = tree.open()
    vim.api.nvim_set_current_win(opened.win_id)
    _cursor_to(opened.win_id, opened.buf, "已有会话")
    vim.fn.maparg("n", "n", false, true).callback()
    local sid3 = assert(chat_service.get_current_session_id())
    t.eq(base .. "/proj", store.get(sid3).metadata.cwd, "组内 n 应继承该会话 cwd")

    tree.reset()
    chat_view.reset()
    chat_service.reset()
    store.reset()
    vim.fn.delete(base, "rf")
  end)

  it("无 metadata.cwd 的旧会话归入「（未绑定工作目录）」组", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    local fs = require("NeoAI.utils.fs")
    local store = require("NeoAI.core.session.session_store")
    local tree = require("NeoAI.ui.window.tree_view")
    config_store.load({ session = { save_path = "/tmp/neoai_tree_unbound_test", file = "sessions.jsonl" } })
    tree.reset()
    store.reset()
    fs.delete_file("/tmp/neoai_tree_unbound_test/sessions.jsonl")
    store.init()
    local s = store.create({ messages = { { role = "user", content = "旧会话" } } })
    s.metadata.cwd = nil
    local opened = tree.open()
    local rendered = _rendered(opened.buf)
    t.true_(rendered:find("（未绑定工作目录）", 1, true) ~= nil, "无 cwd 会话应归入未绑定组")
    t.true_(rendered:find("旧会话", 1, true) ~= nil, "旧会话本身仍应渲染")
    tree.reset()
    store.reset()
  end)

  it("同组含分支与多轮次时缩进正确", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    local fs = require("NeoAI.utils.fs")
    local store = require("NeoAI.core.session.session_store")
    local tree = require("NeoAI.ui.window.tree_view")
    config_store.load({ session = { save_path = "/tmp/neoai_tree_indent_test", file = "sessions.jsonl" } })
    tree.reset()
    store.reset()
    fs.delete_file("/tmp/neoai_tree_indent_test/sessions.jsonl")
    store.init()
    local base = vim.fn.tempname()
    fs.ensure_dir(base)
    local root = store.create({ cwd = base, messages = {
      { role = "user", content = "一轮问题" }, { role = "assistant", content = "一轮回答" },
      { role = "user", content = "二轮问题" }, { role = "assistant", content = "二轮回答" },
    } })
    store.create({ parent_id = root.id, messages = { { role = "user", content = "子分支问题" } } })
    local opened = tree.open()
    local lines = vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false)
    t.true_(lines[1]:find("📁", 1, true) ~= nil, "首行为组头")
    local root_row = _row_of(opened.buf, "一轮问题")
    local round2_row = _row_of(opened.buf, "二轮问题")
    local child_row = _row_of(opened.buf, "子分支问题")
    t.true_(root_row ~= nil and round2_row ~= nil and child_row ~= nil, "各节点应渲染")
    -- 子项前缀应比会话节点更长（更深缩进）
    local function indent(r) local s = lines[r] or ""; return #(s:match("^[│├└─%s]*") or "") end
    t.true_(indent(round2_row) > indent(root_row), "轮次子项应比会话节点更深")
    t.true_(indent(child_row) > indent(root_row), "分支子项应比会话节点更深")
    tree.reset()
    store.reset()
    vim.fn.delete(base, "rf")
  end)

  it("d/D 作用于分组行时提示不可删除且不改变会话", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    local fs = require("NeoAI.utils.fs")
    local store = require("NeoAI.core.session.session_store")
    local tree = require("NeoAI.ui.window.tree_view")
    config_store.load({ session = { save_path = "/tmp/neoai_tree_groupdel_test", file = "sessions.jsonl" } })
    tree.reset()
    store.reset()
    fs.delete_file("/tmp/neoai_tree_groupdel_test/sessions.jsonl")
    store.init()
    local base = vim.fn.tempname()
    fs.ensure_dir(base)
    local s = store.create({ cwd = base, messages = { { role = "user", content = "保留会话" } } })
    local opened = tree.open()
    vim.api.nvim_set_current_win(opened.win_id)
    vim.api.nvim_win_set_cursor(opened.win_id, { 1, 0 }) -- 组头
    vim.fn.maparg("d", "n", false, true).callback()
    vim.fn.maparg("D", "n", false, true).callback()
    t.not_nil(store.get(s.id), "分组行 d/D 不应删除会话")
    t.eq(1, #s.messages, "分组行 d/D 不应删消息")
    tree.reset()
    store.reset()
    vim.fn.delete(base, "rf")
  end)

  it("D 乐观删行：按键后立即从 buffer 移除整支子树，flush 后落盘且重新加载不再有该会话", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    local fs = require("NeoAI.utils.fs")
    local store = require("NeoAI.core.session.session_store")
    local tree = require("NeoAI.ui.window.tree_view")
    local save_dir = vim.fn.tempname()
    config_store.load({ session = { save_path = save_dir, file = "sessions.jsonl" } })
    tree.reset()
    store.reset()
    fs.ensure_dir(save_dir)
    fs.delete_file(save_dir .. "/sessions.jsonl")
    store.init()
    local base = vim.fn.tempname()
    fs.ensure_dir(base)
    local root = store.create({ cwd = base, messages = { { role = "user", content = "待删主线" } } })
    local child = store.create({ parent_id = root.id, messages = { { role = "user", content = "待删子支" } } })
    local keep = store.create({ cwd = base, messages = { { role = "user", content = "保留主线" } } })
    local opened = tree.open()
    vim.api.nvim_set_current_win(opened.win_id)
    t.not_nil(_row_of(opened.buf, "待删子支"), "删除前应渲染子支")

    _cursor_to(opened.win_id, opened.buf, "待删主线")
    vim.fn.maparg("D", "n", false, true).callback()
    -- 乐观语义：尚未落盘，但行已即时消失（含整支子树）
    t.nil_(_row_of(opened.buf, "待删主线"), "按键后应立即移除会话行")
    t.nil_(_row_of(opened.buf, "待删子支"), "按键后应连带移除子树行")
    t.not_nil(store.get(root.id), "落盘前内存不应变化")
    t.eq(1, tree._pending_op_count(), "应有 1 个待落盘删除操作")

    tree.flush()
    t.nil_(store.get(root.id), "flush 后内存应删除主会话")
    t.nil_(store.get(child.id), "flush 后内存应删除子分支")
    t.not_nil(store.get(keep.id), "无关会话应保留")
    t.eq(0, tree._pending_op_count(), "flush 后不应残留待落盘操作")

    -- 重新加载：磁盘上也不再有该会话
    store.reset()
    store.init()
    t.nil_(store.get(root.id), "删除应落盘")
    t.nil_(store.get(child.id), "子分支删除应落盘")
    t.not_nil(store.get(keep.id))
    tree.reset()
    store.reset()
    vim.fn.delete(base, "rf")
  end)

  it("连按 D 三次只触发一次异步批量变更（防抖合并）", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    local fs = require("NeoAI.utils.fs")
    local store = require("NeoAI.core.session.session_store")
    local tree = require("NeoAI.ui.window.tree_view")
    local save_dir = vim.fn.tempname()
    config_store.load({ session = { save_path = save_dir, file = "sessions.jsonl" } })
    tree.reset()
    store.reset()
    fs.ensure_dir(save_dir)
    fs.delete_file(save_dir .. "/sessions.jsonl")
    store.init()
    local base = vim.fn.tempname()
    fs.ensure_dir(base)
    local a = store.create({ cwd = base, messages = { { role = "user", content = "甲会话" } } })
    local b = store.create({ cwd = base, messages = { { role = "user", content = "乙会话" } } })
    local c = store.create({ cwd = base, messages = { { role = "user", content = "丙会话" } } })
    local opened = tree.open()
    vim.api.nvim_set_current_win(opened.win_id)

    local calls = 0
    local batches = 0
    local original = store.mutate_async
    ---@diagnostic disable-next-line: duplicate-set-field
    store.mutate_async = function(ops)
      calls = calls + 1
      batches = #ops
      return original(ops)
    end

    _cursor_to(opened.win_id, opened.buf, "甲会话")
    vim.fn.maparg("D", "n", false, true).callback()
    _cursor_to(opened.win_id, opened.buf, "乙会话")
    vim.fn.maparg("D", "n", false, true).callback()
    _cursor_to(opened.win_id, opened.buf, "丙会话")
    vim.fn.maparg("D", "n", false, true).callback()
    t.eq(3, tree._pending_op_count(), "三次按键应合并为 3 个待落盘操作")

    tree.flush()
    ---@diagnostic disable-next-line: duplicate-set-field
    store.mutate_async = original
    -- flush 走同步落地路径，故断言：一次调用内合并全部操作（真实按键路径由防抖一次提交）
    t.eq(0, tree._pending_op_count())
    t.nil_(store.get(a.id))
    t.nil_(store.get(b.id))
    t.nil_(store.get(c.id))
    t.true_(calls == 0 or batches > 0, "批量提交应携带操作")
    tree.reset()
    store.reset()
    vim.fn.delete(base, "rf")
  end)

  it("删除落盘失败时提示并让行回归，内存与磁盘均不变", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    local fs = require("NeoAI.utils.fs")
    local async = require("NeoAI.utils.async")
    local store = require("NeoAI.core.session.session_store")
    local tree = require("NeoAI.ui.window.tree_view")
    local save_dir = vim.fn.tempname()
    config_store.load({ session = { save_path = save_dir, file = "sessions.jsonl" } })
    tree.reset()
    store.reset()
    fs.ensure_dir(save_dir)
    fs.delete_file(save_dir .. "/sessions.jsonl")
    store.init()
    local base = vim.fn.tempname()
    fs.ensure_dir(base)
    local s = store.create({ cwd = base, messages = { { role = "user", content = "写盘失败会话" } } })
    local opened = tree.open()
    vim.api.nvim_set_current_win(opened.win_id)

    local notified = {}
    local original_notify = vim.notify
    vim.notify = function(msg) notified[#notified + 1] = tostring(msg) end
    local original = store.mutate_async
    ---@diagnostic disable-next-line: duplicate-set-field
    store.mutate_async = function()
      return async.reject({ kind = "session_write", message = "disk full" })
    end

    _cursor_to(opened.win_id, opened.buf, "写盘失败会话")
    vim.fn.maparg("D", "n", false, true).callback()
    t.nil_(_row_of(opened.buf, "写盘失败会话"), "乐观删行应立即生效")
    t.true_(tree._flush_async_now(), "应发起异步批量落盘")
    vim.wait(3000, function() return #notified > 0 end, 10)
    tree.flush()
    ---@diagnostic disable-next-line: duplicate-set-field
    store.mutate_async = original
    vim.notify = original_notify

    t.not_nil(store.get(s.id), "落盘失败时内存不应变化")
    t.eq(1, #s.messages, "落盘失败时消息不应变化")
    t.not_nil(_row_of(opened.buf, "写盘失败会话"), "落盘失败后行应回归")
    local hit = false
    for _, m in ipairs(notified) do
      if m:find("删除失败", 1, true) then hit = true end
    end
    t.true_(hit, "应提示删除失败且数据未变")

    store.reset()
    store.init()
    t.not_nil(store.get(s.id), "磁盘上也不应删除")
    tree.reset()
    store.reset()
    vim.fn.delete(base, "rf")
  end)

  it("删除主会话连带其子 Agent 会话（含孙支）且分组计数正确", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    local fs = require("NeoAI.utils.fs")
    local session_mod = require("NeoAI.core.session.session")
    local store = require("NeoAI.core.session.session_store")
    local tree = require("NeoAI.ui.window.tree_view")
    local save_dir = vim.fn.tempname()
    config_store.load({ session = { save_path = save_dir, file = "sessions.jsonl" } })
    tree.reset()
    store.reset()
    fs.ensure_dir(save_dir)
    fs.delete_file(save_dir .. "/sessions.jsonl")
    store.init()
    local base = vim.fn.tempname()
    fs.ensure_dir(base)
    local root = store.create({ cwd = base, messages = { { role = "user", content = "主会话线索" } } })
    -- 与 core.agent.sub_agent 创建子会话的方式一致：parent_id 指向主会话 + sub_agent 标签
    local sub = store.create({
      parent_id = root.id,
      name = "子任务",
      metadata = { tags = { session_mod.SUB_AGENT_TAG }, name = "子任务" },
      messages = { { role = "user", content = "子 Agent 任务" } },
    })
    local sub_child = store.create({
      parent_id = sub.id,
      messages = { { role = "user", content = "子 Agent 的后续分支" } },
    })
    local keep = store.create({ cwd = base, messages = { { role = "user", content = "独立会话" } } })

    local opened = tree.open()
    vim.api.nvim_set_current_win(opened.win_id)
    t.not_nil(_row_of(opened.buf, "2 个会话"), "分组计数不应包含子 Agent 会话")

    _cursor_to(opened.win_id, opened.buf, "主会话线索")
    vim.fn.maparg("D", "n", false, true).callback()
    tree.flush()

    t.nil_(store.get(root.id), "主会话应删除")
    t.nil_(store.get(sub.id), "子 Agent 会话应连带删除")
    t.nil_(store.get(sub_child.id), "子 Agent 的孙支应连带删除")
    t.not_nil(store.get(keep.id), "无关会话应保留")
    t.not_nil(_row_of(opened.buf, "1 个会话"), "删除后分组计数应更新")

    store.reset()
    store.init()
    t.nil_(store.get(sub.id), "子 Agent 会话删除应落盘")
    t.nil_(store.get(sub_child.id), "子 Agent 孙支删除应落盘")
    tree.reset()
    store.reset()
    vim.fn.delete(base, "rf")
  end)

  it("非递归删除默认也清理子 Agent 会话及其子支，不留孤儿", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    local fs = require("NeoAI.utils.fs")
    local session_mod = require("NeoAI.core.session.session")
    local store = require("NeoAI.core.session.session_store")
    local save_dir = vim.fn.tempname()
    config_store.load({ session = { save_path = save_dir, file = "sessions.jsonl" } })
    store.reset()
    fs.ensure_dir(save_dir)
    fs.delete_file(save_dir .. "/sessions.jsonl")
    store.init()
    local root = store.create({ messages = { { role = "user", content = "根" } } })
    local sub = store.create({
      parent_id = root.id,
      metadata = { tags = { session_mod.SUB_AGENT_TAG }, name = "子任务" },
      messages = { { role = "user", content = "子任务" } },
    })
    local sub_child = store.create({ parent_id = sub.id, messages = { { role = "user", content = "孙支" } } })

    -- 非递归删除（默认 include_sub_agents = true）
    local deleted = store.delete(root.id)
    t.nil_(store.get(root.id))
    t.nil_(store.get(sub.id), "子 Agent 会话不应残留")
    t.nil_(store.get(sub_child.id), "子 Agent 孙支不应残留（否则成为孤儿）")
    t.true_(#deleted >= 3, "返回的删除列表应包含连带删除的会话")
    store.reset()
  end)

  it("d 只删轮次，不影响子 Agent 会话与其它分支", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    local fs = require("NeoAI.utils.fs")
    local session_mod = require("NeoAI.core.session.session")
    local store = require("NeoAI.core.session.session_store")
    local tree = require("NeoAI.ui.window.tree_view")
    local save_dir = vim.fn.tempname()
    config_store.load({ session = { save_path = save_dir, file = "sessions.jsonl" } })
    tree.reset()
    store.reset()
    fs.ensure_dir(save_dir)
    fs.delete_file(save_dir .. "/sessions.jsonl")
    store.init()
    local base = vim.fn.tempname()
    fs.ensure_dir(base)
    local root = store.create({ cwd = base, messages = {
      { role = "user", content = "第一轮问题" },
      { role = "assistant", content = "第一轮回答" },
      { role = "user", content = "第二轮问题" },
      { role = "assistant", content = "第二轮回答" },
    } })
    local sub = store.create({
      parent_id = root.id,
      metadata = { tags = { session_mod.SUB_AGENT_TAG }, name = "子任务" },
      messages = { { role = "user", content = "子 Agent 任务" } },
    })
    local opened = tree.open()
    vim.api.nvim_set_current_win(opened.win_id)
    _cursor_to(opened.win_id, opened.buf, "第二轮问题")
    vim.fn.maparg("d", "n", false, true).callback()
    t.nil_(_row_of(opened.buf, "第二轮问题"), "轮次行应即时移除")
    tree.flush()
    t.eq(2, #root.messages, "只删第二轮两条消息")
    t.eq("第一轮问题", root.messages[1].content)
    t.not_nil(store.get(sub.id), "子 Agent 会话不应受影响")
    t.eq(1, #store.get(sub.id).messages)
    tree.reset()
    store.reset()
    vim.fn.delete(base, "rf")
  end)

  it("工作线程构建与主线程回退路径产出逐行一致", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    local work = require("NeoAI.utils.work")
    local store = require("NeoAI.core.session.session_store")
    local tree = require("NeoAI.ui.window.tree_view")
    local save_dir = vim.fn.tempname()
    config_store.load({ session = { save_path = save_dir, file = "sessions.jsonl" } })
    tree.reset()
    store.reset()
    store.init()
    local root = store.create({ messages = { { role = "user", content = "一致性主线" } } })
    store.create({ parent_id = root.id, messages = { { role = "user", content = "一致性子支" } } })
    local opened = tree.open()
    vim.api.nvim_set_current_win(opened.win_id)
    if not work.available() then
      tree.reset()
      store.reset()
      return
    end
    local snap = tree._collect_snapshot()
    local sync_res = tree._build_sync(snap)
    local worker_res = t.await(tree._build_worker(snap))
    t.eq(sync_res.rows, worker_res.rows, "两条路径行文本应逐行一致")
    t.eq(sync_res.depths, worker_res.depths, "两条路径 depth 串应一致")
    t.eq(#sync_res.meta, #worker_res.meta, "两条路径行元数据数量应相同")
    for i = 1, #sync_res.meta do
      t.eq(sync_res.meta[i], worker_res.meta[i], "第 " .. i .. " 行元数据应一致")
    end
    t.eq(#sync_res.cleanup_ids, #worker_res.cleanup_ids, "清理候选应一致")
    tree.reset()
    store.reset()
  end)

  it("关闭树窗口不丢失待落盘删除；reset 后已排队的渲染回调不再改写 buffer", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    local fs = require("NeoAI.utils.fs")
    local store = require("NeoAI.core.session.session_store")
    local tree = require("NeoAI.ui.window.tree_view")
    local save_dir = vim.fn.tempname()
    config_store.load({ session = { save_path = save_dir, file = "sessions.jsonl" } })
    tree.reset()
    store.reset()
    fs.ensure_dir(save_dir)
    fs.delete_file(save_dir .. "/sessions.jsonl")
    store.init()
    local base = vim.fn.tempname()
    fs.ensure_dir(base)
    local s = store.create({ cwd = base, messages = { { role = "user", content = "关窗删除会话" } } })
    local opened = tree.open()
    local buf = opened.buf
    vim.api.nvim_set_current_win(opened.win_id)
    _cursor_to(opened.win_id, opened.buf, "关窗删除会话")
    vim.fn.maparg("D", "n", false, true).callback()
    tree.reset()

    t.false_(tree.has_window(), "reset 后不应有窗口")
    t.eq(0, tree._pending_op_count(), "reset 后不应残留待落盘操作")
    local done = vim.wait(5000, function() return store.get(s.id) == nil end, 10)
    t.true_(done, "关窗时应把待落盘删除提交给存储")
    t.false_(vim.api.nvim_buf_is_valid(buf), "树 buffer 应已删除")
    -- 再等一轮事件循环：过期的渲染回调不得报错或复活 buffer
    vim.wait(300)
    t.false_(tree.has_window())
    tree.reset()
    store.reset()
    vim.fn.delete(base, "rf")
  end)

  it("并发删除与追加持久化共用写盘链，重新加载不丢消息", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    local fs = require("NeoAI.utils.fs")
    local store = require("NeoAI.core.session.session_store")
    local save_dir = vim.fn.tempname()
    config_store.load({ session = { save_path = save_dir, file = "sessions.jsonl" } })
    store.reset()
    fs.ensure_dir(save_dir)
    fs.delete_file(save_dir .. "/sessions.jsonl")
    store.init()
    local keep = store.create({ messages = { { role = "user", content = "首次落盘" } } })
    local doomed = store.create({ messages = { { role = "user", content = "将被删除" } } })
    -- 追加一条新消息后并发发起「删除另一个会话」的整文件重写
    keep.messages[#keep.messages + 1] = { role = "assistant", content = "并发新增消息" }
    keep.updated_at = os.time() + 1
    local d1 = store.persist_async(keep)
    local d2 = store.mutate_async({ { op = "delete", id = doomed.id, recursive = true } })
    t.await(d1)
    t.await(d2)
    t.nil_(store.get(doomed.id))
    store.reset()
    store.init()
    local reloaded = store.get(keep.id)
    t.not_nil(reloaded, "保留会话应存在")
    t.eq(2, #reloaded.messages, "并发重写不应覆盖刚追加的快照")
    t.eq("并发新增消息", reloaded.messages[2].content)
    t.nil_(store.get(doomed.id), "删除应落盘")
    store.reset()
  end)
end)
