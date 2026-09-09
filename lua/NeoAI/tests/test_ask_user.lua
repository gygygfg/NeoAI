--- 向用户提问工具测试
--- @module NeoAI.tests.test_ask_user

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
    local tl = find_tool("ask_user")
    t.not_nil(tl)
    local out = {}
    tl.func(
      { question = "要 A 还是 B？", options = { "A", "B" } },
      function(m) out.msg = m end,
      function(e) out.err = e end,
      { agent = { id = "a1" }, signal = async.create_signal() })
    t.nil_(out.msg, "用户回答前不应有结果")
    t.not_nil(captured.config)
    t.eq("要 A 还是 B？", captured.config.question)
    t.eq(2, #captured.config.options)
    captured.config.on_answer("A")
    t.nil_(out.err)
    t.matches("A", out.msg or "")
    ask.reset()
  end)

  it("缺少 question 时报错", function(t)
    local ask = require("NeoAI.tools.builtin.ask_user")
    local async = require("NeoAI.utils.async")
    ask.reset()
    ask.set_ui({ show = function() end, hide = function() end })
    local tl = find_tool("ask_user")
    local out = {}
    tl.func(
      {},
      function(m) out.msg = m end,
      function(e) out.err = e end,
      { agent = { id = "a2" }, signal = async.create_signal() })
    t.nil_(out.msg)
    t.matches("question", out.err or "")
    ask.reset()
  end)

  it("用户取消提问时报错", function(t)
    local ask = require("NeoAI.tools.builtin.ask_user")
    local async = require("NeoAI.utils.async")
    ask.reset()
    local captured = {}
    ask.set_ui({
      show = function(config) captured.config = config end,
      hide = function() end,
    })
    local tl = find_tool("ask_user")
    local out = {}
    tl.func(
      { question = "继续吗？" },
      function(m) out.msg = m end,
      function(e) out.err = e end,
      { agent = { id = "a3" }, signal = async.create_signal() })
    captured.config.on_cancel("不想回答")
    t.nil_(out.msg)
    local err = out.err
    local err_msg = type(err) == "table" and (err.message or "") or tostring(err)
    t.matches("取消", err_msg)
    ask.reset()
  end)

  it("Agent 取消时提问立即终止", function(t)
    local ask = require("NeoAI.tools.builtin.ask_user")
    local async = require("NeoAI.utils.async")
    ask.reset()
    ask.set_ui({ show = function() end, hide = function() end })
    local tl = find_tool("ask_user")
    local sig = async.create_signal()
    local out = {}
    tl.func(
      { question = "会超时的问题" },
      function(m) out.msg = m end,
      function(e) out.err = e end,
      { agent = { id = "a4" }, signal = sig })
    sig:abort("user_cancelled")
    t.nil_(out.msg)
    local err = out.err
    local err_msg = type(err) == "table" and (err.message or "") or tostring(err)
    t.matches("取消", err_msg)
    ask.reset()
  end)

  it("并行第二次提问排队等待，回答后再展示（不失败）", function(t)
    local ask = require("NeoAI.tools.builtin.ask_user")
    local async = require("NeoAI.utils.async")
    ask.reset()
    local shown = {}
    ask.set_ui({
      show = function(config)
        shown[#shown + 1] = config
      end,
      hide = function() end,
    })
    local tl = find_tool("ask_user")
    local out1, out2 = {}, {}
    tl.func({ question = "第一个问题" },
      function(m) out1.msg = m end,
      function(e) out1.err = e end,
      { agent = { id = "a6" }, signal = async.create_signal() })
    tl.func({ question = "第二个问题" },
      function(m) out2.msg = m end,
      function(e) out2.err = e end,
      { agent = { id = "a7" }, signal = async.create_signal() })

    t.nil_(out1.err, "第一个提问等待回答")
    t.nil_(out2.err, "第二个提问不应被拒绝，而是排队等待")
    t.nil_(out2.msg, "第二个提问排队中，尚未展示")
    t.eq(1, #shown, "同一时刻只展示一个提问弹窗")
    t.eq("第一个问题", shown[1].question)

    shown[1].on_answer("完成")
    t.matches("完成", out1.msg or "")
    -- 第一个回答后展示第二个
    t.eq(2, #shown, "第一个回答后应紧接展示第二个提问")
    t.eq("第二个问题", shown[2].question)
    t.nil_(out2.msg, "第二个提问已展示，正等待用户回答")

    shown[2].on_answer("第二个答案")
    t.matches("第二个答案", out2.msg or "")
    ask.reset()
  end)

  it("对象选项归一化为 label + description，选序号返回 label", function(t)
    local ask = require("NeoAI.tools.builtin.ask_user")
    local async = require("NeoAI.utils.async")
    ask.reset()
    local shown = {}
    ask.set_ui({
      show = function(config) shown[#shown + 1] = config end,
      hide = function() end,
    })
    local tl = find_tool("ask_user")
    local out = {}
    tl.func(
      { question = "怎么生成？", options = {
        { label = "快速生成", description = "直接用当前上下文，不做计划" },
        "仅计划",
      } },
      function(m) out.msg = m end,
      function(e) out.err = e end,
      { agent = { id = "a8" }, signal = async.create_signal() })

    local cfg = shown[1]
    t.eq(2, #cfg.options, "字符串与对象选项都应保留")
    t.eq("快速生成", cfg.options[1].label)
    t.eq("直接用当前上下文，不做计划", cfg.options[1].description)
    t.eq("仅计划", cfg.options[2].label)
    t.eq("", cfg.options[2].description)

    cfg.on_answer("快速生成")
    t.matches("快速生成", out.msg or "")
    ask.reset()
  end)

  it("未注册 UI 时回退到 vim.ui.input", function(t)
    local ask = require("NeoAI.tools.builtin.ask_user")
    local async = require("NeoAI.utils.async")
    ask.reset()
    local orig = vim.ui.input
    vim.ui.input = function(opts, cb)
      t.matches("问题", opts.prompt or "")
      cb("自由回答内容")
    end
    local tl = find_tool("ask_user")
    local out = {}
    tl.func(
      { question = "自由输入问题" },
      function(m) out.msg = m end,
      function(e) out.err = e end,
      { agent = { id = "a5" }, signal = async.create_signal() })
    vim.ui.input = orig
    t.nil_(out.err)
    t.matches("自由回答内容", out.msg or "")
    ask.reset()
  end)
end)
