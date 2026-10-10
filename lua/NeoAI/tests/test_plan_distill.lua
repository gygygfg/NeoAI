--- 计划提取测试
--- @module NeoAI.tests.test_plan_distill

local tests = require("NeoAI.tests")

tests.suite("plan_distill", function(_, it)
  --- 等待 Deferred 完成（async 基于 vim.schedule）
  local function await(d, timeout)
    local done, val = false, nil
    d:then_(function(v) done = true; val = v end, function(e) done = true; val = e end)
    vim.wait(timeout or 2000, function() return done end, 5)
    return val
  end

  it("_window 按进入计划模式的边界切分 front/window", function(t)
    local p = require("NeoAI.core.session.plan_distill")
    local msgs = {
      { role = "user", content = "a" },
      { role = "assistant", content = "b" },
      { role = "user", content = "c" },
      { role = "assistant", content = "d" },
    }
    local window, front = p._window({ messages = msgs, _plan_enter_index = 2 })
    t.eq(2, #front, "plan 入口之前的消息归入 front")
    t.eq(2, #window, "plan 入口之后的调研消息归入 window")
    t.eq("a", front[1].content)
    t.eq("c", window[1].content)
  end)

  it("_window 无 _plan_enter_index 时窗口为全部消息、front 为空", function(t)
    local p = require("NeoAI.core.session.plan_distill")
    local msgs = { { role = "user", content = "a" }, { role = "assistant", content = "b" } }
    local window, front = p._window({ messages = msgs })
    t.eq(0, #front)
    t.eq(2, #window)
  end)

  it("_parse 忽略标签大小写，step 按编号升序，缺失标签忽略", function(t)
    local p = require("NeoAI.core.session.plan_distill")
    local f = p._parse([[
<Target>完成改造</Target>
<Step2>第二步</Step2>
<step1>第一步</step1>
<STEP3>第三步</STEP3>
<Files>lua/a.lua
lua/b.lua</Files>
<Rollback>git revert</Rollback>
<Information>补充说明</Information>
]])
    t.eq("完成改造", f.target)
    t.eq(3, #f.steps)
    t.eq("第一步", f.steps[1])
    t.eq("第二步", f.steps[2])
    t.eq("第三步", f.steps[3])
    t.true_(f.files:find("lua/a.lua", 1, true) ~= nil)
    t.eq("git revert", f.rollback)
    t.eq("补充说明", f.information)
  end)

  it("_parse 无内容时返回空 steps 且无 target", function(t)
    local p = require("NeoAI.core.session.plan_distill")
    local f = p._parse("随便一段文字没有标签")
    t.nil_(f.target)
    t.eq(0, #f.steps)
    local need = p._needs_retry(f)
    t.true_(need, "缺少 target 与 stepN 应判为需要重试")
  end)

  it("_needs_retry 关键字段齐全时为 false", function(t)
    local p = require("NeoAI.core.session.plan_distill")
    local need = p._needs_retry({ target = "x", steps = { "s1" } })
    t.false_(need)
  end)

  it("_collect_file_tool_messages 原样取出命中的 assistant/tool 成对消息", function(t)
    local p = require("NeoAI.core.session.plan_distill")
    local window = {
      { role = "assistant", content = "", tool_calls = {
        { id = "c1", ["function"] = { name = "read_file", arguments = '{"file_path":"lua/a.lua"}' } } } },
      { role = "tool", tool_call_id = "c1", name = "read_file", content = "-- 内容 of lua/a.lua" },
      { role = "assistant", content = "无关的推理" },
    }
    local picked = p._collect_file_tool_messages(window, "lua/a.lua")
    t.eq(2, #picked)
    t.eq("assistant", picked[1].role)
    t.eq("tool", picked[2].role)
    t.eq(window[1], picked[1], "应为原始对象引用（逐字节原样）")
    t.eq(window[2], picked[2])
  end)

  it("_collect_file_tool_messages 无候选路径或未命中时返回空", function(t)
    local p = require("NeoAI.core.session.plan_distill")
    local window = {
      { role = "assistant", tool_calls = { { id = "c1", ["function"] = { name = "read_file", arguments = '{"file_path":"lua/a.lua"}' } } } },
    }
    t.eq(0, #p._collect_file_tool_messages(window, ""))
    t.eq(0, #p._collect_file_tool_messages(window, "lua/other.lua"))
  end)

  it("_build_context_message / _build_todo_items 由字段组装", function(t)
    local p = require("NeoAI.core.session.plan_distill")
    local f = { target = "目标", steps = { "步骤一", "步骤二" }, files = "lua/a.lua", context = "背景说明" }
    local msg = p._build_context_message(f)
    t.true_(msg:find("## 任务目标", 1, true) ~= nil)
    t.true_(msg:find("步骤一", 1, true) ~= nil)
    t.true_(msg:find("## 涉及文件", 1, true) ~= nil)
    t.true_(msg:find("## 背景", 1, true) ~= nil)
    local items = p._build_todo_items(f)
    t.eq(2, #items)
    t.eq("步骤一", items[1].content)
    t.eq("pending", items[1].status)
  end)

  it("_extract_and_parse 关键字段缺失时重试至上限（3 次）后忽略缺失", function(t)
    local p = require("NeoAI.core.session.plan_distill")
    local async = require("NeoAI.utils.async")
    local orig = p._send_extract
    local calls = 0
    p._send_extract = function()
      calls = calls + 1
      return async.resolve("<target>仅目标</target>")
    end
    local f = await(p._extract_and_parse({ id = "a1" }, {}, { compact_max_tokens = 64 }))
    p._send_extract = orig
    t.eq(3, calls, "缺失关键字段应共尝试 3 次")
    t.eq("仅目标", f.target)
    t.eq(0, #f.steps, "仍缺失则忽略缺失")
  end)

  it("_extract_and_parse 关键字段齐全时一次通过", function(t)
    local p = require("NeoAI.core.session.plan_distill")
    local async = require("NeoAI.utils.async")
    local orig = p._send_extract
    local calls = 0
    p._send_extract = function()
      calls = calls + 1
      return async.resolve("<target>T</target><step1>a</step1><step2>b</step2>")
    end
    local f = await(p._extract_and_parse({ id = "a1" }, {}, {}))
    p._send_extract = orig
    t.eq(1, calls)
    t.eq(2, #f.steps)
  end)

  it("plan_mode.enter 记录 _plan_enter_index 并重置 _plan_distilled", function(t)
    local pm = require("NeoAI.tools.builtin.plan_mode")
    local agent = { messages = { { role = "user", content = "a" }, { role = "assistant", content = "b" } } }
    agent._plan_distilled = true
    pm.enter(agent)
    t.eq(2, agent._plan_enter_index)
    t.false_(agent._plan_distilled, "进入计划模式应重置「已提取」标记")
  end)

  it("run: distill_on_execute=false 时 no-op，不改动历史", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ tools = { plan_mode = { distill_on_execute = false } } })
    local p = require("NeoAI.core.session.plan_distill")
    local agent = { messages = { { role = "user", content = "a" }, { role = "assistant", content = "p" } }, _plan_enter_index = 1 }
    local r = await(p.run(agent))
    t.false_(r, "提取关闭时应返回 false")
    t.eq(2, #agent.messages, "历史不被改动")
    t.nil_(agent.plan_extract)
  end)

  it("run: 写入请求覆盖层（front + 文件工具对 + 新上下文），不改动 agent.messages", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ tools = { plan_mode = { distill_on_execute = true } } })
    local p = require("NeoAI.core.session.plan_distill")
    local async = require("NeoAI.utils.async")
    local cb = require("NeoAI.core.session.context_builder")
    local orig = p._send_extract
    p._send_extract = function()
      return async.resolve("<target>目标</target><step1>步骤一</step1><files>lua/a.lua</files>")
    end

    local msgs = {
      { role = "user", content = "front" },
      { role = "assistant", content = "", tool_calls = {
        { id = "c1", ["function"] = { name = "read_file", arguments = '{"file_path":"lua/a.lua"}' } } } },
      { role = "tool", tool_call_id = "c1", name = "read_file", content = "-- 内容 of lua/a.lua" },
    }
    local agent = { id = "a1", config = {}, model = "m", messages = msgs, _plan_enter_index = 1 }
    local res = await(p.run(agent))
    p._send_extract = orig

    t.not_nil(res)
    t.eq("目标", res.fields.target)
    t.eq(1, #res.steps)
    t.not_nil(agent.plan_extract)
    t.eq(1, agent.plan_extract.front_count)
    t.eq(3, agent.plan_extract.window_end)
    t.eq(3, #agent.messages, "覆盖层不改动 agent.messages")

    local view = cb.request_view(agent)
    -- front(1) + 文件工具对(2) + 新上下文 user(1)
    t.eq(4, #view)
    t.eq(msgs[1], view[1])
    t.eq(msgs[2], view[2], "文件工具对原样保留")
    t.eq(msgs[3], view[3])
    t.eq("user", view[4].role)
    t.true_(view[4].content:find("步骤一", 1, true) ~= nil)
  end)
end)
