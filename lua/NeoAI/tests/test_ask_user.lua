--- 向用户提问工具测试
--- @module 'NeoAI.tests.test_ask_user'

local tests = require("NeoAI.tests")

local function find_tool(name)
  local ask = require("NeoAI.tools.builtin.ask_user")
  for _, tl in ipairs(ask.get_tools()) do
    if tl.name == name then return tl end
  end
  return nil
end

tests.suite("ask_user", function(_, it)
  it("注册 UI 后提问并回传用户回答", function(t)
    local ask = require("NeoAI.tools.builtin.ask_user")
    local async = require("NeoAI.utils.async")
    ask.reset()
    local captured = {}
    ask.set_ui({
      show = function(config) captured.config = config end,
      hide = function() end,
    })
    local tl = assert(find_tool("ask_user"))
    t.not_nil(tl)
    local out = {}
    tl.func(
      { question = "要 A 还是 B？", options = { "A", "B" } },
      function(m) out.msg = m end,
      function(e) out.err = e end,
      { agent = { id = "a1", _round_seq = 1 }, signal = async.create_signal() })
    t.nil_(out.msg, "用户回答前不应有结果")
    ask._flush()
    t.not_nil(captured.config, "去抖后应展示批次")
    t.eq(1, #captured.config.questions)
    t.eq("要 A 还是 B？", captured.config.questions[1].question)
    t.eq(2, #captured.config.questions[1].options)
    captured.config.on_submit({ "A" })
    t.nil_(out.err)
    t.matches("A", out.msg or "")
    ask.reset()
  end)

  it("同一轮多次 ask_user 合并为多 Tab，提交后各自回传答案", function(t)
    local ask = require("NeoAI.tools.builtin.ask_user")
    local async = require("NeoAI.utils.async")
    local event_bus = require("NeoAI.kernel.event_bus")
    local events = require("NeoAI.kernel.events")
    ask.reset()
    local shown, waiting, answered = 0, 0, 0
    local captured = {}
    ask.set_ui({
      show = function(config) shown = shown + 1; captured.config = config end,
      hide = function() end,
    })
    local unsub_w = event_bus.on(events.ASK_USER_WAITING, function() waiting = waiting + 1 end)
    local unsub_a = event_bus.on(events.ASK_USER_ANSWERED, function() answered = answered + 1 end)

    local tl = assert(find_tool("ask_user"))
    local agent = { id = "same", _round_seq = 7 }
    local out1, out2 = {}, {}
    local sig1, sig2 = async.create_signal(), async.create_signal()
    -- 同一轮并行派发的两次调用（同 agent.id 且同 _round_seq）
    tl.func({ question = "问题一" }, function(m) out1.msg = m end, function(e) out1.err = e end, { agent = agent, signal = sig1 })
    tl.func({ question = "问题二", options = { "X", "Y" } }, function(m) out2.msg = m end, function(e) out2.err = e end, { agent = agent, signal = sig2 })

    ask._flush()
    t.eq(1, shown, "同一轮应合并为单个批次（只展示一次）")
    t.not_nil(captured.config)
    t.eq(2, #captured.config.questions, "两题并入同一批次")
    t.eq("问题一", captured.config.questions[1].question)
    t.eq("问题二", captured.config.questions[2].question)
    t.eq(2, waiting, "展示批次时逐项上报 waiting 事件")

    captured.config.on_submit({ "答案一", "X" })
    t.nil_(out1.err)
    t.nil_(out2.err)
    t.matches("答案一", out1.msg or "")
    t.matches("X", out2.msg or "")
    t.eq(2, answered, "结算时逐项上报 answered 事件")

    unsub_w(); unsub_a()
    ask.reset()
  end)

  it("跨轮（_round_seq 不同）不合并，分别成批串行展示", function(t)
    local ask = require("NeoAI.tools.builtin.ask_user")
    local async = require("NeoAI.utils.async")
    ask.reset()
    local configs = {}
    ask.set_ui({
      show = function(config) configs[#configs + 1] = config end,
      hide = function() end,
    })
    local tl = assert(find_tool("ask_user"))
    local out1, out2 = {}, {}
    tl.func({ question = "第一轮问题" }, function(m) out1.msg = m end, function(e) out1.err = e end,
      { agent = { id = "b", _round_seq = 1 }, signal = async.create_signal() })
    tl.func({ question = "第二轮问题" }, function(m) out2.msg = m end, function(e) out2.err = e end,
      { agent = { id = "b", _round_seq = 2 }, signal = async.create_signal() })

    ask._flush()
    t.eq(1, #configs, "不同轮次不应合并，先展示第一批")
    t.eq("第一轮问题", configs[1].questions[1].question)
    configs[1].on_submit({ "答案一" })
    t.matches("答案一", out1.msg or "")
    t.eq(2, #configs, "第一批提交后应串行展示第二批")
    t.eq("第二轮问题", configs[2].questions[1].question)
    configs[2].on_submit({ "答案二" })
    t.matches("答案二", out2.msg or "")
    ask.reset()
  end)

  it("multi_select 透传给 UI，答案以 ', ' 连接", function(t)
    local ask = require("NeoAI.tools.builtin.ask_user")
    local async = require("NeoAI.utils.async")
    ask.reset()
    local captured = {}
    ask.set_ui({
      show = function(config) captured.config = config end,
      hide = function() end,
    })
    local tl = assert(find_tool("ask_user"))
    local out = {}
    tl.func(
      { question = "选择若干项", multi_select = true, options = { "A", "B", "C" } },
      function(m) out.msg = m end,
      function(e) out.err = e end,
      { agent = { id = "c", _round_seq = 1 }, signal = async.create_signal() })
    ask._flush()
    t.eq(true, captured.config.questions[1].multi_select, "multi_select 应透传到 config")
    captured.config.on_submit({ "A, C" })
    t.matches("A, C", out.msg or "")
    ask.reset()
  end)

  it("缺少 question 时报错", function(t)
    local ask = require("NeoAI.tools.builtin.ask_user")
    local async = require("NeoAI.utils.async")
    ask.reset()
    ask.set_ui({ show = function() end, hide = function() end })
    local tl = assert(find_tool("ask_user"))
    local out = {}
    tl.func(
      {},
      function(m) out.msg = m end,
      function(e) out.err = e end,
      { agent = { id = "a2", _round_seq = 1 }, signal = async.create_signal() })
    t.nil_(out.msg)
    t.matches("question", out.err or "")
    ask.reset()
  end)

  it("用户取消提问时整批报错", function(t)
    local ask = require("NeoAI.tools.builtin.ask_user")
    local async = require("NeoAI.utils.async")
    ask.reset()
    local captured = {}
    ask.set_ui({
      show = function(config) captured.config = config end,
      hide = function() end,
    })
    local tl = assert(find_tool("ask_user"))
    local out1, out2 = {}, {}
    local agent = { id = "a3", _round_seq = 1 }
    tl.func({ question = "继续吗？" }, function(m) out1.msg = m end, function(e) out1.err = e end,
      { agent = agent, signal = async.create_signal() })
    tl.func({ question = "再来一题？" }, function(m) out2.msg = m end, function(e) out2.err = e end,
      { agent = agent, signal = async.create_signal() })
    ask._flush()
    captured.config.on_cancel("不想回答")
    t.nil_(out1.msg)
    t.nil_(out2.msg)
    local function msg(e) return type(e) == "table" and (e.message or "") or tostring(e) end
    t.matches("取消", msg(out1.err))
    t.matches("取消", msg(out2.err))
    ask.reset()
  end)

  it("Agent 取消时整批立即终止", function(t)
    local ask = require("NeoAI.tools.builtin.ask_user")
    local async = require("NeoAI.utils.async")
    ask.reset()
    local hidden = false
    ask.set_ui({ show = function() end, hide = function() hidden = true end })
    local tl = assert(find_tool("ask_user"))
    local sig = async.create_signal()
    local out = {}
    tl.func(
      { question = "会超时的问题" },
      function(m) out.msg = m end,
      function(e) out.err = e end,
      { agent = { id = "a4", _round_seq = 1 }, signal = sig })
    ask._flush()
    sig:abort("user_cancelled")
    t.nil_(out.msg)
    local err = out.err
    local err_msg = type(err) == "table" and (err.message or "") or tostring(err)
    t.matches("取消", err_msg)
    t.true_(hidden, "中止时应关闭提问 UI")
    ask.reset()
  end)

  it("对象选项归一化为 label + description", function(t)
    local ask = require("NeoAI.tools.builtin.ask_user")
    local async = require("NeoAI.utils.async")
    ask.reset()
    local captured = {}
    ask.set_ui({ show = function(config) captured.config = config end, hide = function() end })
    local tl = assert(find_tool("ask_user"))
    tl.func(
      { question = "怎么生成？", options = {
        { label = "快速生成", description = "直接用当前上下文，不做计划" },
        "仅计划",
      } },
      function() end,
      function() end,
      { agent = { id = "a8", _round_seq = 1 }, signal = async.create_signal() })
    ask._flush()
    local cfg = captured.config.questions[1]
    t.eq(2, #cfg.options, "字符串与对象选项都应保留")
    t.eq("快速生成", cfg.options[1].label)
    t.eq("直接用当前上下文，不做计划", cfg.options[1].description)
    t.eq("仅计划", cfg.options[2].label)
    t.eq("", cfg.options[2].description)
    ask.reset()
  end)

  it("未注册 UI 时回退 vim.ui.input，多题按题顺序逐个询问", function(t)
    local ask = require("NeoAI.tools.builtin.ask_user")
    local async = require("NeoAI.utils.async")
    ask.reset()
    local prompts = {}
    local orig_ui = rawget(vim, "ui")
    vim.ui = {
      input = function(opts, cb)
        prompts[#prompts + 1] = opts.prompt or ""
        cb(prompts[#prompts] .. "→答")
      end,
    }
    local tl = assert(find_tool("ask_user"))
    local agent = { id = "a5", _round_seq = 1 }
    local out1, out2 = {}, {}
    tl.func({ question = "问题甲" }, function(m) out1.msg = m end, function(e) out1.err = e end,
      { agent = agent, signal = async.create_signal() })
    tl.func({ question = "问题乙" }, function(m) out2.msg = m end, function(e) out2.err = e end,
      { agent = agent, signal = async.create_signal() })
    ask._flush()
    -- 恢复：原始 vim.ui 缺失（精简 runtime）时留一个无害 stub，避免后续懒加载报错
    vim.ui = orig_ui or { input = function(_, cb) if cb then cb(nil) end end }
    t.eq(2, #prompts, "两题应各自询问一次")
    t.matches("问题甲", prompts[1])
    t.matches("问题乙", prompts[2])
    t.nil_(out1.err)
    t.nil_(out2.err)
    t.matches("答", out1.msg or "")
    t.matches("答", out2.msg or "")
    ask.reset()
  end)

  it("展示批次时逐项暂停计时器，结算后逐项恢复", function(t)
    local ask = require("NeoAI.tools.builtin.ask_user")
    local async = require("NeoAI.utils.async")
    ask.reset()
    local captured = {}
    ask.set_ui({ show = function(config) captured.config = config end, hide = function() end })
    local tl = assert(find_tool("ask_user"))
    local events = {}
    local function mk_timer(name)
      return {
        pause = function() events[#events + 1] = "pause:" .. name end,
        resume = function() events[#events + 1] = "resume:" .. name end,
      }
    end
    local agent = { id = "a9", _round_seq = 3 }
    tl.func({ question = "甲" }, function() end, function() end,
      { agent = agent, signal = async.create_signal(), timer = mk_timer("t1") })
    tl.func({ question = "乙" }, function() end, function() end,
      { agent = agent, signal = async.create_signal(), timer = mk_timer("t2") })
    ask._flush()
    t.deep_eq({ "pause:t1", "pause:t2" }, events, "展示时逐项暂停计时器")
    captured.config.on_submit({ "甲答", "乙答" })
    t.deep_eq({ "pause:t1", "pause:t2", "resume:t1", "resume:t2" }, events, "结算后逐项恢复计时器")
    ask.reset()
  end)
end)
