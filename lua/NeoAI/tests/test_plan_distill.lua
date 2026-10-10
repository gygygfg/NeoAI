--- 计划提取测试
--- @module 'NeoAI.tests.test_plan_distill'

local tests = require("NeoAI.tests")

tests.suite("plan_distill", function(_, it)
  --- 等待 Deferred 完成（async 基于 vim.schedule）
  ---@return any
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

  -- ===== 并行提取编排（mock _send_extract，按通道路由；确定性，无网络） =====

  --- 从「最后一条消息」的指令文本识别通道（与各通道 instruction 的唯一短语对齐）。
  --- front 用压缩器的 8 段指令（含 "compaction engine"）。
  local function channel_of(text)
    if type(text) ~= "string" then return "?" end
    if text:find("compaction engine", 1, true) then return "front" end
    if text:find("允许的标签清单", 1, true) then return "?" end -- legacy 单请求指令
    if text:find("**任务目标**", 1, true) then return "target" end
    if text:find("**执行步骤**", 1, true) then return "steps" end
    if text:find("完成目标所涉及的文件", 1, true) then return "files" end
    if text:find("背景与范围", 1, true) then return "background" end
    if text:find("约束与技术信息", 1, true) then return "constraints" end
    if text:find("验证与风险", 1, true) then return "verify" end
    if text:find("回退与补充信息", 1, true) then return "fallback" end
    return "?"
  end

  --- 各通道默认应答文本。
  local CH_REPLY = {
    target = "<target>目标</target>",
    steps = "<step1>步骤一</step1><step2>步骤二</step2>",
    files = "<files>lua/a.lua</files>",
    background = "<Context>背景</Context>",
    constraints = "<Constraints>约束</Constraints>",
    verify = "<Verify>验证</Verify>",
    fallback = "<Rollback>回退</Rollback>",
    front = "front 摘要内容",
    ["?"] = "<target>T</target><step1>s</step1>",
  }

  --- 安装按通道路由的 mock（返回 (counts, restore)）。
  --- opts.overrides: 通道名 -> function(count) -> string|nil|Deferred（nil 表示按默认应答）。
  local function install_router(p, opts)
    opts = opts or {}
    local async = require("NeoAI.utils.async")
    local orig = p._send_extract
    local counts = {}
    p._send_extract = function(_, msgs, _, on_chunk)
      local last = msgs[#msgs]
      local text = type(last and last.content) == "string" and last.content or ""
      local ch = channel_of(text)
      counts[ch] = (counts[ch] or 0) + 1
      local ov = opts.overrides and opts.overrides[ch]
      local reply
      if ov then reply = ov(counts[ch]) end
      if reply == nil and not ov then reply = CH_REPLY[ch] or "" end
      if type(reply) == "table" and reply.then_ then return reply end
      if on_chunk and reply then on_chunk({ content = reply }) end
      return async.resolve(reply)
    end
    return counts, function() p._send_extract = orig end
  end

  local function sample_msgs()
    return {
      { role = "user", content = "front" },
      { role = "assistant", content = "", tool_calls = {
        { id = "c1", ["function"] = { name = "read_file", arguments = '{"file_path":"lua/a.lua"}' } } } },
      { role = "tool", tool_call_id = "c1", name = "read_file", content = "-- 内容 of lua/a.lua" },
    }
  end

  it("run(并行): 分路 R1=3 / R2=4 / front=1；回显使 R2 前缀含 R1；覆盖层 front_checkpoint 替换 front", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ tools = { plan_mode = { distill_on_execute = true, distill_parallel = true, distill_front = true } } })
    local p = require("NeoAI.core.session.plan_distill")
    local cb = require("NeoAI.core.session.context_builder")
    local counts, restore = install_router(p)

    local msgs = sample_msgs()
    local agent = { id = "a1", config = {}, model = "m", messages = msgs, _plan_enter_index = 1 }
    local res = await(p.run(agent))
    restore()

    t.not_nil(res)
    t.eq("目标", res.fields.target)
    t.eq(2, #res.steps)
    t.eq("lua/a.lua", res.fields.files)
    t.eq("背景", res.fields.context, "R2 应补全可选段")
    t.eq("回退", res.fields.rollback)
    t.eq(1, counts.target); t.eq(1, counts.steps); t.eq(1, counts.files)
    t.eq(1, counts.background); t.eq(1, counts.constraints)
    t.eq(1, counts.verify); t.eq(1, counts.fallback)
    t.eq(1, counts.front)
    t.eq(3, #agent.messages, "覆盖层不改动 agent.messages")

    local pe = agent.plan_extract
    t.not_nil(pe.front_checkpoint, "front 应被压缩为检查点")
    t.eq(1, pe.front_count)
    t.eq(3, pe.window_end)

    local view = cb.request_view(agent)
    -- front 检查点(1) + 文件工具对(2) + 新上下文 user(1)
    t.eq(4, #view)
    t.eq(pe.front_checkpoint, view[1], "front_checkpoint 应替换原 front")
    t.eq(msgs[2], view[2], "文件工具对原样保留")
    t.eq(msgs[3], view[3])
    t.eq("user", view[4].role)
    t.true_(view[4].content:find("步骤一", 1, true) ~= nil)
  end)

  it("run(并行): distill_front=false 时 front 原样保留、不发 front 请求", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ tools = { plan_mode = { distill_on_execute = true, distill_front = false } } })
    local p = require("NeoAI.core.session.plan_distill")
    local cb = require("NeoAI.core.session.context_builder")
    local counts, restore = install_router(p)

    local msgs = sample_msgs()
    local agent = { id = "a1", config = {}, model = "m", messages = msgs, _plan_enter_index = 1 }
    local res = await(p.run(agent))
    restore()

    t.not_nil(res)
    t.nil_(counts.front, "关闭 front 压缩时不应发 front 请求")
    t.nil_(agent.plan_extract.front_checkpoint)
    local view = cb.request_view(agent)
    t.eq(msgs[1], view[1], "front 原样保留")
  end)

  it("run(并行): distill_parallel=false 回退 legacy 单请求路径", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ tools = { plan_mode = { distill_on_execute = true, distill_parallel = false } } })
    local p = require("NeoAI.core.session.plan_distill")
    local counts, restore = install_router(p)

    local agent = { id = "a1", config = {}, model = "m", messages = sample_msgs(), _plan_enter_index = 1 }
    local res = await(p.run(agent))
    restore()

    t.not_nil(res)
    t.eq("T", res.fields.target)
    t.nil_(counts.front, "legacy 路径无 front 压缩")
    t.eq(1, counts["?"], "legacy 应只发一次请求")
    t.nil_(agent.plan_extract.front_checkpoint)
  end)

  it("run(并行): target 缺失仅重试该通道至 distill_max_attempts", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ tools = { plan_mode = { distill_on_execute = true, distill_max_attempts = 2 } } })
    local p = require("NeoAI.core.session.plan_distill")
    local counts, restore = install_router(p, {
      overrides = {
        target = function(n) if n == 1 then return "" else return "<target>补全目标</target>" end end,
      },
    })
    local agent = { id = "a1", config = {}, model = "m", messages = sample_msgs(), _plan_enter_index = 1 }
    local res = await(p.run(agent))
    restore()

    t.not_nil(res)
    t.eq("补全目标", res.fields.target)
    t.eq(2, counts.target, "target 应重试一次")
    t.eq(1, counts.steps, "steps 不应被连带重试")
  end)

  it("run(并行): R1 全失败（target+steps 均无输出）→ 整体 no-op", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ tools = { plan_mode = { distill_on_execute = true, distill_max_attempts = 1 } } })
    local p = require("NeoAI.core.session.plan_distill")
    local counts, restore = install_router(p, {
      overrides = {
        target = function() return "" end,
        steps = function() return "" end,
      },
    })
    local msgs = sample_msgs()
    local agent = { id = "a1", config = {}, model = "m", messages = msgs, _plan_enter_index = 1 }
    local res = await(p.run(agent))
    restore()

    t.false_(res, "R1 全失败应返回 false")
    t.nil_(agent.plan_extract)
    t.eq(3, #agent.messages, "历史不改动")
    t.eq(0, counts.background or 0, "R1 失败不应进入第 2 轮")
  end)

  it("run(并行): R2 全失败仍用 R1 结果成功", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ tools = { plan_mode = { distill_on_execute = true } } })
    local p = require("NeoAI.core.session.plan_distill")
    local async = require("NeoAI.utils.async")
    local counts, restore = install_router(p, {
      overrides = {
        background = function() return async.reject({ message = "boom" }) end,
        constraints = function() return async.reject({ message = "boom" }) end,
        verify = function() return async.reject({ message = "boom" }) end,
        fallback = function() return async.reject({ message = "boom" }) end,
      },
    })
    local agent = { id = "a1", config = {}, model = "m", messages = sample_msgs(), _plan_enter_index = 1 }
    local res = await(p.run(agent))
    restore()

    t.not_nil(res, "R2 全失败不应整体失败")
    t.eq("目标", res.fields.target)
    t.nil_(res.fields.context, "R2 失败则无可选段")
    t.true_(counts.background >= 1)
  end)

  it("run(并行): front 压缩失败退回原样 front", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ tools = { plan_mode = { distill_on_execute = true } } })
    local p = require("NeoAI.core.session.plan_distill")
    local async = require("NeoAI.utils.async")
    local cb = require("NeoAI.core.session.context_builder")
    local _, restore = install_router(p, {
      overrides = { front = function() return async.reject({ message = "boom" }) end },
    })
    local msgs = sample_msgs()
    local agent = { id = "a1", config = {}, model = "m", messages = msgs, _plan_enter_index = 1 }
    local res = await(p.run(agent))
    restore()

    t.not_nil(res)
    t.nil_(agent.plan_extract.front_checkpoint, "front 失败应回退原样")
    t.eq(msgs[1], cb.request_view(agent)[1])
  end)

  it("_merge_fields 不覆盖已有非空值", function(t)
    local p = require("NeoAI.core.session.plan_distill")
    local dst = { steps = {}, target = "A" }
    p._merge_fields(dst, { target = "B", steps = { "s1" }, context = "c" })
    t.eq("A", dst.target, "已有 target 不被覆盖")
    t.eq(1, #dst.steps)
    t.eq("c", dst.context)
  end)

  it("_echo_r1_message 稳定回显 target/steps/files", function(t)
    local p = require("NeoAI.core.session.plan_distill")
    local m = p._echo_r1_message({ target = "T", steps = { "a", "b" }, files = "x.lua" })
    t.eq("user", m.role)
    t.true_(m.content:find("<target>T</target>", 1, true) ~= nil)
    t.true_(m.content:find("<step2>b</step2>", 1, true) ~= nil)
    t.true_(m.content:find("<files>x.lua</files>", 1, true) ~= nil)
  end)

  -- ===== 解析器健壮性矩阵（确定性，无网络；固化 plan_extract 基准） =====

  it("_parse 大小写不敏感且 step 按编号升序归一", function(t)
    local p = require("NeoAI.core.session.plan_distill")
    local f = p._parse("<TARGET>T</TARGET>\n<sTeP3>c</sTeP3><STEP1>a</STEP1><Step2>b</Step2>")
    t.eq("T", f.target)
    t.eq(3, #f.steps)
    t.eq("a", f.steps[1]); t.eq("b", f.steps[2]); t.eq("c", f.steps[3])
  end)

  it("_parse 缺闭合标签视为缺失、重复标签取首个、空 step 跳过", function(t)
    local p = require("NeoAI.core.session.plan_distill")
    local f1 = p._parse("<target>没有闭合\n<step1>s</step1>")
    t.nil_(f1.target, "未闭合的 target 应视为缺失")
    local f2 = p._parse("<target>第一</target><target>第二</target><step1>s</step1>")
    t.eq("第一", f2.target, "重复标签应取首个")
    local f3 = p._parse("<target>T</target><step1>  </step1><step2>real</step2>")
    t.eq(1, #f3.steps)
    t.eq("real", f3.steps[1], "空值 step 应跳过")
  end)

  it("_parse 非连续/起始大于 1 的 stepN 保留并按编号升序", function(t)
    local p = require("NeoAI.core.session.plan_distill")
    local f = p._parse("<target>T</target><step2>b</step2><step5>e</step5>")
    t.eq(2, #f.steps)
    t.eq("b", f.steps[1]); t.eq("e", f.steps[2])
  end)

  it("_parse 解析全部可选节标签（多行/首尾空白裁剪）", function(t)
    local p = require("NeoAI.core.session.plan_distill")
    local f = p._parse(table.concat({
      "<target>\n  目标  \n</target><step1>\n 步骤\n</step1>",
      "<Context>c</Context><Scope>sc</Scope><OutOfScope>oos</OutOfScope>",
      "<Constraints>con</Constraints><Commands>cmd</Commands><Dependencies>dep</Dependencies>",
      "<Environment>env</Environment><Verify>ver</Verify><Risks>risk</Risks>",
      "<Questions>q</Questions><Information>info</Information><Rollback>rb</Rollback>",
    }, "\n"))
    t.eq("目标", f.target)
    t.eq("步骤", f.steps[1])
    for _, k in ipairs({ "context", "scope", "outofscope", "constraints", "commands", "dependencies", "environment", "verify", "risks", "questions", "information", "rollback" }) do
      t.not_nil(f[k], "应解析出 " .. k)
    end
  end)

  it("_parse 容忍 Markdown 围栏，且回显的示例标签不覆盖真实值", function(t)
    local p = require("NeoAI.core.session.plan_distill")
    local f1 = p._parse("```xml\n<target>T</target>\n<step1>s</step1>\n```")
    t.eq("T", f1.target)
    t.eq(1, #f1.steps)
    local f2 = p._parse("<target>真目标</target><step1>s1</step1>\n输出示例：<target>...</target>")
    t.eq("真目标", f2.target, "首个 target 应优先于回显示例")
  end)

  it("_file_candidates 过滤噪声 token，保留路径形态", function(t)
    local p = require("NeoAI.core.session.plan_distill")
    local c = p._file_candidates("lua/a.lua\n./src/b.lua\nab\n!!\ndir/c")
    local has_a, has_c, has_ab = false, false, false
    for _, x in ipairs(c) do
      if x == "lua/a.lua" then has_a = true end
      if x == "dir/c" then has_c = true end
      if x == "ab" then has_ab = true end
    end
    t.true_(has_a, "应保留 lua/a.lua")
    t.true_(has_c, "应保留 dir/c")
    t.false_(has_ab, "过短/无路径特征的 token 应被过滤")
  end)

  -- ===== 提取参数下发 =====

  it("_send_extract 下发 extract_max_tokens；默认（nil）不下发 max_tokens", function(t)
    local p = require("NeoAI.core.session.plan_distill")
    ---@type table<string, any>
    local request = require("NeoAI.core.agent.request")
    local async = require("NeoAI.utils.async")
    local orig = request.send_stream
    local captured = {}
    request.send_stream = function(_, opts)
      captured[#captured + 1] = opts
      return async.resolve({ content = "<target>T</target><step1>s</step1>" })
    end
    local ok, err = pcall(function()
      local agent = { id = "a", config = {}, model = "m", tools = {} }
      t.await(p._send_extract(agent, { { role = "user", content = "x" } }, { extract_max_tokens = 4096 }))
      t.await(p._send_extract(agent, { { role = "user", content = "x" } }, {}))
      t.eq(4096, captured[1].max_tokens, "显式 extract_max_tokens 应下发")
      t.nil_(captured[2].max_tokens, "默认 extract_max_tokens=nil 时不下发 max_tokens（避免截断）")
    end)
    request.send_stream = orig
    if not ok then error(err, 0) end
  end)

  -- ===== 端到端（mock SSE 服务器，离线） =====

  --- 按请求体「末条消息」识别通道，返回通道应答文本。
  local function route_body(request)
    local he = request:find("\r\n\r\n", 1, true)
    local raw = request:sub(he + 4)
    local ok, decoded = pcall(vim.json.decode, raw)
    local ch = "?"
    if ok and decoded and decoded.messages then
      local last = decoded.messages[#decoded.messages]
      ch = channel_of(last and last.content)
    end
    return raw, decoded, ch
  end

  it("run 端到端（mock SSE）：并行 8 路（R1=3/R2=4/front=1），前缀一致、默认不发 max_tokens", function(t)
    local hs = require("NeoAI.tests.http_server")
    local bodies = {}
    local function handler(client, request)
      local raw, decoded, ch = route_body(request)
      bodies[#bodies + 1] = { raw = raw, decoded = decoded, ch = ch }
      local content = CH_REPLY[ch] or ""
      local ev = function(o) return "data: " .. vim.json.encode(o) .. "\n\n" end
      local resp = ev({ choices = { { delta = { content = content } } } })
        .. ev({ choices = { { delta = {}, finish_reason = "stop" } }, usage = { prompt_tokens = 12, completion_tokens = 8 } })
        .. "data: [DONE]\n\n"
      hs.respond(client, resp)
    end
    hs.with_server(handler, function(base_url)
      local config_store = require("NeoAI.kernel.config_store")
      config_store.load({
        ai = {
          providers = { mockpe = { api_type = "openai", base_url = base_url, api_key = "test" } },
          model_refresh = { on_startup = false },
        },
        tools = { plan_mode = { distill_on_execute = true, distill_parallel = true, distill_front = true } },
      })
      local p = require("NeoAI.core.session.plan_distill")
      local msgs = {
        { role = "user", content = "给 lua/a.lua 加功能" },
        { role = "assistant", content = "", tool_calls = { { id = "c1", type = "function", ["function"] = { name = "read_file", arguments = '{"file_path":"lua/a.lua"}' } } } },
        { role = "tool", tool_call_id = "c1", name = "read_file", content = "content of lua/a.lua" },
      }
      local agent = {
        id = "mockpe", model = "test",
        config = { provider = "mockpe", model = "test", temperature = 0.3, system_prompt = "你是助手" },
        messages = msgs, tools = {}, _plan_enter_index = 1,
      }
      local res = t.await(p.run(agent), 8000)
      t.not_nil(res, "提取应成功")
      t.eq("目标", res.fields.target)
      t.eq(2, #res.fields.steps)
      t.eq("背景", res.fields.context)

      -- 分路计数：R1 3 路 + R2 4 路 + front 1 路 = 8 路并发
      local by = {}
      for _, b in ipairs(bodies) do by[b.ch] = (by[b.ch] or 0) + 1 end
      t.eq(8, #bodies, "应共发 8 路请求")
      for _, ch in ipairs({ "target", "steps", "files", "background", "constraints", "verify", "fallback", "front" }) do
        t.eq(1, by[ch] or 0, "通道 " .. ch .. " 应恰好 1 路")
      end

      -- 前缀缓存前提：所有请求 system 一致；R1/R2 的 system+历史前缀逐字节一致。
      local sys0
      local prefix0
      for _, b in ipairs(bodies) do
        local m = b.decoded.messages
        if sys0 == nil then sys0 = m[1].content end
        t.eq(sys0, m[1].content, "所有请求 system 应一致")
        t.nil_(b.decoded.max_tokens, "默认 extract_max_tokens=nil → 请求体不含 max_tokens")
        t.eq(true, b.decoded.stream, "提取请求应为流式")
        if b.ch ~= "front" then
          local head = {}
          for i = 1, 4 do head[i] = m[i] end -- system + 3 条历史
          if prefix0 == nil then
            prefix0 = head
          else
            t.eq(true, vim.deep_equal(prefix0, head), "R1/R2 的 system+历史前缀应逐字节一致")
          end
        end
      end

      local pe = agent.plan_extract
      t.not_nil(pe)
      t.not_nil(pe.front_checkpoint, "front 应被压缩为检查点")
      t.eq(1, pe.front_count)
      t.eq(3, #pe.inject, "覆盖层 = 文件工具对(2) + 新上下文(1)")
      t.eq(msgs[2], pe.inject[1], "文件工具对应原样引用")
      t.eq(msgs[3], pe.inject[2])
      t.eq(3, #agent.messages, "覆盖层不改动 agent.messages")
    end)
  end)

  it("run 端到端（mock SSE）：并行下 target 缺失仅重试该通道", function(t)
    local hs = require("NeoAI.tests.http_server")
    local n_target = 0
    local total = 0
    local function handler(client, request)
      local _, _, ch = route_body(request)
      total = total + 1
      local content
      if ch == "target" then
        n_target = n_target + 1
        content = (n_target == 1) and "" or "<target>补全后的目标</target>"
      else
        content = CH_REPLY[ch] or ""
      end
      local ev = function(o) return "data: " .. vim.json.encode(o) .. "\n\n" end
      local resp = ev({ choices = { { delta = { content = content } } } })
        .. ev({ choices = { { delta = {}, finish_reason = "stop" } }, usage = { prompt_tokens = 10, completion_tokens = 4 } })
        .. "data: [DONE]\n\n"
      hs.respond(client, resp)
    end
    hs.with_server(handler, function(base_url)
      local config_store = require("NeoAI.kernel.config_store")
      config_store.load({
        ai = {
          providers = { mockpe2 = { api_type = "openai", base_url = base_url, api_key = "test" } },
          model_refresh = { on_startup = false },
        },
        tools = { plan_mode = { distill_on_execute = true, distill_max_attempts = 2 } },
      })
      local p = require("NeoAI.core.session.plan_distill")
      local agent = {
        id = "mockpe2", model = "test",
        config = { provider = "mockpe2", model = "test", temperature = 0.3, system_prompt = "你是助手" },
        messages = {
          { role = "user", content = "调研后出计划" },
          { role = "assistant", content = "计划正文" },
        },
        tools = {}, _plan_enter_index = 0,
      }
      local res = t.await(p.run(agent), 8000)
      t.not_nil(res)
      t.eq("补全后的目标", res.fields.target)
      t.eq(2, #res.fields.steps)
      t.eq(2, n_target, "target 通道应重试一次")
      t.eq(8, total, "无 front（_plan_enter_index=0）：R1(3)+R2(4) 首跑 + target 重试 1 次 = 8")
    end)
  end)
end)
