local tests = require("NeoAI.tests")

-- ========== 工具：构造 buffer 与消息 ==========

local function _new_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].modifiable = true
  return buf
end

local function _lines_of(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function _joined(buf)
  return table.concat(_lines_of(buf), "\n")
end

--- 构造包含各类形态的消息序列（用户 / 推理 / 工具调用+结果 / 表格 / 多轮）
local function _sample_messages()
  return {
    { role = "system", content = "系统提示（不渲染）" },
    { role = "user", content = "第一个问题" },
    { role = "assistant", content = "思考中", reasoning = "先推理\n再作答" },
    { role = "assistant", content = "", tool_calls = {
      { id = "c1", ["function"] = { name = "read_file", arguments = '{"path":"a.lua"}' } },
      { id = "c2", ["function"] = { name = "read_file", arguments = '{"path":"b.lua"}' } },
    } },
    { role = "tool", tool_call_id = "c1", tool_name = "read_file", content = "文件 A 内容", duration_ms = 30 },
    { role = "tool", tool_call_id = "c2", tool_name = "read_file", content = "文件 B 内容\n第二行", duration_ms = 45 },
    { role = "assistant", content = "结论如下：\n\n| 项 | 值 |\n| --- | --- |\n| a | 1 |\n| b | 2 |\n" },
    { role = "user", content = "第二个问题" },
    { role = "assistant", content = "第二个答案" },
    { runtime_context = true, role = "user", content = "运行时快照（不渲染）" },
  }
end

tests.suite("incremental", function(_, it)
  it("diff_range：无差异 / 追加 / 头部替换 / 中部替换 / 清空", function(t)
    local inc = require("NeoAI.ui.components.incremental")

    local d = inc.diff_range({ "a", "b", "c" }, { "a", "b", "c" })
    t.false_(d.changed, "相同内容不应有差异")

    d = inc.diff_range({ "a", "b" }, { "a", "b", "c" })
    t.eq(3, d.start, "追加应从第 3 行开始")
    t.eq(0, d.removed, "追加不应删除")
    t.eq(1, d.inserted, "追加应插入 1 行")
    t.eq("c", d.lines[1], "追加内容应正确")

    d = inc.diff_range({ "a", "b", "c" }, { "x", "b", "c" })
    t.eq(1, d.start, "头部替换应从第 1 行开始")
    t.eq(1, d.removed, "头部替换删除 1 行")
    t.eq(1, d.inserted, "头部替换插入 1 行")

    d = inc.diff_range({ "a", "b", "c", "d" }, { "a", "X", "d" })
    t.eq(2, d.start, "中部替换应从第 2 行开始")
    t.eq(2, d.removed, "中部替换删除 2 行")
    t.eq(1, d.inserted, "中部替换插入 1 行")

    d = inc.diff_range({ "a" }, {})
    t.true_(d.changed, "清空应有差异")
    t.eq(1, d.start, "清空从第 1 行开始")
    t.eq(1, d.removed, "清空删除 1 行")
    t.eq(0, d.inserted, "清空不插入")
  end)

  it("apply：无差异不写 buffer；有差异只改差异区间", function(t)
    local inc = require("NeoAI.ui.components.incremental")
    local buf = _new_buf()

    -- 首次：old=nil 走全量
    local d = inc.apply(buf, nil, { "a", "b", "c" })
    t.true_(d.changed, "首次写入应视为变化")
    t.true_(d.full, "首次写入应走全量")
    t.eq("a,b,c", table.concat(_lines_of(buf), ","), "首次写入内容正确")

    -- 无差异：changedtick 不应变化
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    d = inc.apply(buf, { "a", "b", "c" }, { "a", "b", "c" })
    t.false_(d.changed, "相同内容不应产生写入")
    t.eq(tick, vim.api.nvim_buf_get_changedtick(buf), "无差异时 changedtick 应保持稳定")

    -- 追加尾部：只插入一行
    d = inc.apply(buf, { "a", "b", "c" }, { "a", "b", "c", "d" })
    t.true_(d.changed, "追加应有变化")
    t.eq(4, d.start, "追加位置应为第 4 行")
    t.eq(0, d.removed, "追加不删除")
    t.eq(1, d.inserted, "追加插入 1 行")
    t.eq("a,b,c,d", table.concat(_lines_of(buf), ","), "追加后 buffer 内容正确")

    -- 中部替换
    d = inc.apply(buf, { "a", "b", "c", "d" }, { "a", "B", "d" })
    t.eq(2, d.start, "中部替换起点")
    t.eq("a,B,d", table.concat(_lines_of(buf), ","), "中部替换后内容正确")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("块缓存：签名未变命中、签名变化重建、未出现块被清理", function(t)
    local inc = require("NeoAI.ui.components.incremental")
    local cache = inc.new_block_cache()
    local builds = 0

    local function blocks(sig_a, sig_b)
      return {
        { key = "a", sig = sig_a, build = function() builds = builds + 1 return { lines = { "A" .. sig_a } } end },
        { key = "b", sig = sig_b, build = function() builds = builds + 1 return { lines = { "B" .. sig_b } } end },
      }
    end

    local function store_size()
      local n = 0
      for _ in pairs(cache.store) do n = n + 1 end
      return n
    end

    cache:render(blocks("1", "1"))
    t.eq(2, builds, "首轮应构建全部块")
    t.eq(0, cache:last_stats().hits, "首轮命中 0")
    t.eq(2, cache:last_stats().misses, "首轮未命中 2")

    cache:render(blocks("1", "1"))
    t.eq(2, builds, "签名未变不应重新构建")
    t.eq(2, cache:last_stats().hits, "次轮应全部命中")
    t.eq(0, cache:last_stats().misses, "次轮未命中 0")

    cache:render(blocks("1", "2"))
    t.eq(3, builds, "签名变化应只重建该块")
    t.eq(1, cache:last_stats().hits, "应 1 命中")
    t.eq(1, cache:last_stats().misses, "应 1 未命中")

    -- 只渲染一个块：另一个块应被清理，缓存不残留
    cache:render({ { key = "a", sig = "1", build = function() builds = builds + 1 return { lines = { "A" } } end } })
    t.eq(3, builds, "残留块清理不影响构建计数")
    t.eq(1, store_size(), "未出现块应被清理")

    -- reset 清空并让下次写入回到全量
    cache:render(blocks("9", "9"))
    cache:reset()
    t.eq(0, store_size(), "reset 应清空块表")
    t.eq(nil, cache.lines, "reset 应清空内容镜像")
  end)

  it("按 buffer 共享缓存：cache_for 稳定；invalidate 丢弃镜像", function(t)
    local inc = require("NeoAI.ui.components.incremental")
    inc.reset()
    local buf = _new_buf()
    local c1 = inc.cache_for(buf)
    local c2 = inc.cache_for(buf)
    t.eq(c1, c2, "同一 buffer 应复用同一缓存")

    c1.lines = { "x" }
    inc.invalidate(buf)
    t.eq(nil, c1.lines, "invalidate 应清空内容镜像")

    inc.reset()
    t.ne(c1, inc.cache_for(buf), "reset 后应新建缓存")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("对话渲染：增量结果与全量重写逐行一致", function(t)
    local message_list = require("NeoAI.ui.components.message_list")
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    message_list.reset()
    chat_view.reset()
    chat_service.reset()

    local opened = chat_view.open()
    local agent = chat_service.get_current_agent()
    agent.messages = _sample_messages()

    -- 逐次增量渲染（模拟事件驱动的多次刷新）
    chat_view.refresh()
    local incremental_text = _joined(opened.buf)
    t.true_(incremental_text:find("👤 用户", 1, true) ~= nil, "应包含用户角色头")
    t.true_(incremental_text:find("🤖 AI", 1, true) ~= nil, "应包含助手角色头")
    t.true_(incremental_text:find("文件 A 内容", 1, true) ~= nil, "应包含工具结果")

    -- 追加一条新消息后再次增量渲染
    agent.messages[#agent.messages + 1] = { role = "assistant", content = "补充说明\n第二行" }
    chat_view.refresh()

    -- 与全量重写逐行比对
    local after_incremental = _joined(opened.buf)
    message_list.invalidate(opened.buf)
    chat_view.refresh()
    t.eq(after_incremental, _joined(opened.buf), "增量渲染与全量重写应完全一致")

    chat_view.reset()
    chat_service.reset()
  end)

  it("对话渲染：流式新增分片只改写末尾行，前缀保持不变", function(t)
    local message_list = require("NeoAI.ui.components.message_list")
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    message_list.reset()
    chat_view.reset()
    chat_service.reset()

    local opened = chat_view.open()
    local agent = chat_service.get_current_agent()
    agent.messages = {
      { role = "user", content = "问题" },
      { role = "assistant", content = "答" },
    }
    message_list.render(opened.buf, agent.messages, { table_width = 80 })
    local before = _lines_of(opened.buf)

    -- 模拟流式：末尾消息正文变长
    agent.messages[2].content = "答" .. string.rep("内容", 8)
    local diff = message_list.render(opened.buf, agent.messages, { streaming = true, table_width = 80 })
    local after = _lines_of(opened.buf)

    t.true_(diff.changed, "流式追加应被识别为变化")
    t.true_(diff.start > 1, "差异不应从首行开始（前缀未变）")
    for i = 1, diff.start - 1 do
      t.eq(before[i], after[i], "差异区间之前第 " .. i .. " 行应保持不变")
    end

    -- 无变化时再渲染：不触碰 buffer
    local tick = vim.api.nvim_buf_get_changedtick(opened.buf)
    diff = message_list.render(opened.buf, agent.messages, { streaming = true, table_width = 80 })
    t.false_(diff.changed, "内容未变时不应写入")
    t.eq(tick, vim.api.nvim_buf_get_changedtick(opened.buf), "无变化时应保持 changedtick 不变")

    chat_view.reset()
    chat_service.reset()
  end)

  it("对话渲染：历史 shrink/压缩重排后回退全量，不残留陈旧行", function(t)
    local message_list = require("NeoAI.ui.components.message_list")
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    message_list.reset()
    chat_view.reset()
    chat_service.reset()

    local opened = chat_view.open()
    local agent = chat_service.get_current_agent()
    agent.messages = _sample_messages()
    chat_view.refresh()
    t.true_(#_lines_of(opened.buf) > 5, "初次渲染应有内容")

    -- 模拟上下文压缩：历史被替换为一条检查点，尾部保留
    agent.messages = {
      { role = "system", content = "系统提示" },
      { role = "assistant", content = "【压缩摘要】之前的对话已压缩" },
      { role = "user", content = "第二个问题" },
      { role = "assistant", content = "第二个答案" },
    }
    chat_view.refresh()
    local text = _joined(opened.buf)
    t.true_(text:find("压缩摘要", 1, true) ~= nil, "应包含压缩摘要")
    t.false_(text:find("文件 A 内容", 1, true) ~= nil, "压缩后不应残留旧工具结果")

    chat_view.reset()
    chat_service.reset()
  end)

  it("轨迹渲染：增量与全量逐行一致，且工具状态更新生效", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    local display_modes = require("NeoAI.ui.components.display_modes")
    local trajectory = require("NeoAI.ui.components.display_modes.trajectory")
    local fold = require("NeoAI.ui.components.fold")
    chat_view.reset()
    chat_service.reset()
    display_modes.reset()

    local opened = chat_view.open()
    local agent = chat_service.get_current_agent()
    agent.messages = {
      { role = "system", content = "你是助手" },
      { role = "user", content = "查状态" },
      { role = "assistant", content = "", tool_calls = {
        { id = "c1", ["function"] = { name = "git_status", arguments = "{}" } },
      } },
      { role = "assistant", content = "有改动" },
      { role = "user", content = "再查" },
      { role = "assistant", content = "无改动" },
    }
    chat_view.set_display("trajectory")
    chat_view.refresh()
    local inc_text = _joined(opened.buf)
    t.true_(inc_text:find("⏷ Turn 1", 1, true) ~= nil, "轨迹模式应有 turn 头行")
    t.true_(inc_text:find("⏷ Turn 2", 1, true) ~= nil, "应有 Turn 2")

    -- 增量结果与全量重建（build_lines）逐行一致
    t.eq(table.concat(trajectory.build_lines(agent.messages), "\n"), inc_text,
      "轨迹增量渲染应与全量渲染逐行一致")

    -- 工具尚无结果时状态/耗时取自 fold 计时：完成后应被识别为变化并改变文本
    fold.clear_timing()
    trajectory.render(opened.buf, agent.messages)
    local before_text = _joined(opened.buf)
    t.true_(before_text:find("⏳", 1, true) ~= nil, "未完成工具应显示 ⏳")
    fold.record_end("c1", 1500, "success")
    local diff = trajectory.render(opened.buf, agent.messages)
    t.true_(diff.changed, "工具状态变化应被识别为变化")
    local after_text = _joined(opened.buf)
    t.true_(after_text ~= before_text, "工具状态更新应改变轨迹文本")
    t.true_(after_text:find("✅", 1, true) ~= nil, "完成后应显示 ✅")
    t.true_(after_text:find("1.5s", 1, true) ~= nil, "应显示耗时 1.5s")
    t.eq(table.concat(trajectory.build_lines(agent.messages), "\n"), after_text,
      "状态更新后轨迹增量仍应与全量一致")

    fold.clear_timing()
    chat_view.reset()
    chat_service.reset()
    display_modes.reset()
  end)

  it("对话渲染：表格高亮在增量写入后仍与全量一致", function(t)
    local message_list = require("NeoAI.ui.components.message_list")
    local inc = require("NeoAI.ui.components.incremental")
    message_list.reset()

    local buf = _new_buf()
    -- 首条含表格（触发斑马纹高亮），尾部再放一条消息，便于做「只改尾部」的增量。
    local msgs = {
      { role = "user", content = "看表" },
      { role = "assistant", content = "表如下：\n\n| 项 | 值 |\n| --- | --- |\n| a | 1 |\n| b | 2 |\n| c | 3 |\n" },
      { role = "assistant", content = "收尾" },
    }

    local function table_hl_rows()
      local rows = {}
      local ns = vim.api.nvim_get_namespaces()["neoai_table_hi"]
      if not ns then return rows end
      for _, e in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
        rows[#rows + 1] = e[2]
      end
      table.sort(rows)
      return rows
    end

    message_list.render(buf, msgs, { table_width = 80 })
    local full_rows = table.concat(table_hl_rows(), ",")
    t.true_(#full_rows > 0, "应存在表格高亮")

    -- 只改尾部消息，走增量；表格所在前缀不动，高亮应保持不变
    msgs[3].content = "收尾（已更新）"
    local diff = message_list.render(buf, msgs, { table_width = 80 })
    t.true_(diff.changed, "尾部变更应有写入")
    local inc_rows = table.concat(table_hl_rows(), ",")

    -- 与全量重建对比
    inc.invalidate(buf)
    message_list.render(buf, msgs, { table_width = 80 })
    t.eq(table.concat(table_hl_rows(), ","), inc_rows, "增量后表格高亮应与全量一致")
    t.eq(full_rows, inc_rows, "前缀表格高亮行号应保持不变")

    inc.invalidate(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("渲染开关：ui.chat.incremental=false 时降级全量仍与增量逐行一致", function(t)
    local message_list = require("NeoAI.ui.components.message_list")
    local config_store = require("NeoAI.kernel.config_store")
    local inc = require("NeoAI.ui.components.incremental")
    message_list.reset()

    local buf = _new_buf()
    local msgs = _sample_messages()

    local prev = config_store.get("ui.chat.incremental")
    config_store.set("ui.chat.incremental", true)
    message_list.render(buf, msgs, { table_width = 80 })
    local incremental_text = _joined(buf)

    config_store.set("ui.chat.incremental", false)
    local diff = message_list.render(buf, msgs, { table_width = 80 })
    t.true_(diff.full, "降级路径应走全量替换")
    t.eq(incremental_text, _joined(buf), "全量降级与增量结果应逐行一致")

    config_store.set("ui.chat.incremental", prev)
    inc.invalidate(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("chat_view：无变化重渲染不写 buffer，工具完成 tick 仍刷新折叠文本", function(t)
    local message_list = require("NeoAI.ui.components.message_list")
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    local fold = require("NeoAI.ui.components.fold")
    message_list.reset()
    chat_view.reset()
    chat_service.reset()

    local opened = chat_view.open()
    local agent = chat_service.get_current_agent()
    agent.messages = {
      { role = "user", content = "问题" },
      { role = "assistant", content = "", tool_calls = {
        { id = "c1", ["function"] = { name = "git_status", arguments = "{}" } },
      } },
    }
    chat_view.refresh()

    -- 消息与 fold 计时都没变：再次渲染不应触碰 buffer
    local tick = vim.api.nvim_buf_get_changedtick(opened.buf)
    message_list.render(opened.buf, agent.messages, { table_width = 80 })
    t.eq(tick, vim.api.nvim_buf_get_changedtick(opened.buf), "内容未变时不应重写 buffer")

    -- 工具完成（只改 fold 计时，不改消息）：应被识别为变化并刷新折叠文本
    fold.clear_timing()
    message_list.render(opened.buf, agent.messages, { table_width = 80 })
    local before_tick = vim.api.nvim_buf_get_changedtick(opened.buf)
    fold.record_end("c1", 1500, "success")
    local diff = message_list.render(opened.buf, agent.messages, { table_width = 80 })
    t.true_(diff.changed, "工具状态变化后应有写入")
    t.true_(vim.api.nvim_buf_get_changedtick(opened.buf) ~= before_tick, "应实际重写 buffer")
    t.matches("1%.5s", _joined(opened.buf), "折叠文本应显示耗时 1.5s")

    fold.clear_timing()
    chat_view.reset()
    chat_service.reset()
  end)
end)
