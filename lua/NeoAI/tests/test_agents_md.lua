--- AGENTS.md 自动加载（core.session.agents_md）专项测试
--- @module 'NeoAI.tests.test_agents_md'
--- 覆盖：向上查找、读取与截断、注入形态（assistant tool_calls + tool 结果一一对应）、
--- 幂等（不重复注入）、子 Agent 不注入、配置关闭时零副作用。
local tests = require("NeoAI.tests")

tests.suite("agents_md", function(_, it)
  local agents_md = require("NeoAI.core.session.agents_md")

  local function with_cfg(patch, fn)
    local config_store = require("NeoAI.kernel.config_store")
    local saved = vim.deepcopy(config_store.get_all() or {})
    local merged = vim.deepcopy(config_store.get("session.agents_md") or {})
    -- 测试框架默认关闭注入（保证其他套件与运行位置无关）；本套件显式开启。
    merged.enabled = true
    for k, v in pairs(patch or {}) do merged[k] = v end
    config_store.load(vim.deepcopy(saved))
    config_store.set("session.agents_md", merged)
    local ok, err = pcall(fn)
    config_store.load(saved)
    if not ok then error(err, 0) end
  end

  -- 注入相关用例需确保配置启用（测试默认为关闭）
  local function enable(fn)
    return with_cfg({}, fn)
  end

  local function mkdir_tree(root, rel)
    local dir = root .. "/" .. rel
    vim.fn.mkdir(dir, "p")
    return dir
  end

  it("find 从子目录向上查找到 AGENTS.md", function(t)
    local root = vim.fn.tempname()
    local sub = mkdir_tree(root, "a/b/c")
    local path = root .. "/AGENTS.md"
    vim.fn.writefile({ "# 约定", "- 测试" }, path)
    local found = agents_md.find(sub)
    t.not_nil(found, "应向上找到 AGENTS.md")
    t.eq(vim.fn.fnamemodify(path, ":p"), vim.fn.fnamemodify(found, ":p"))
    vim.fn.delete(root, "rf")
  end)

  it("find 未命中返回 nil；可用自定义文件名", function(t)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    t.nil_(agents_md.find(root), "无文件时应返回 nil")
    vim.fn.writefile({ "x" }, root .. "/MY_RULES.md")
    local found = agents_md.find(root, "MY_RULES.md")
    t.not_nil(found, "自定义文件名应可命中")
    vim.fn.delete(root, "rf")
  end)

  it("load 读取正文；超 max_bytes 截断并标注", function(t)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local path = root .. "/AGENTS.md"
    vim.fn.writefile({ string.rep("行内容", 200) }, path)
    local doc = agents_md.load(path)
    t.not_nil(doc)
    t.eq(1, doc.lines)
    t.false_(doc.truncated, "未超限时不应截断")

    with_cfg({ max_bytes = 64 }, function()
      local small = agents_md.load(path)
      t.not_nil(small)
      t.true_(small.truncated, "超过 max_bytes 应截断")
      t.true_(small.text:find("已截断", 1, true) ~= nil, "截断应带标注")
      t.nil_(small.text:find("\239\191\189", 1, true), "不得出现 UTF-8 替换字符")
    end)
    vim.fn.delete(root, "rf")
  end)

  it("load 对不存在路径返回 nil", function(t)
    t.nil_(agents_md.load("/nonexistent/AGENTS.md"))
    t.nil_(agents_md.load(""))
  end)

  it("inject 注入 assistant(tool_calls) + tool 结果，且 id 一一对应", function(t)
    enable(function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    vim.fn.writefile({ "# 约定", "- 保持测试通过" }, root .. "/AGENTS.md")
    local agent_mod = require("NeoAI.core.agent.agent")
    local agent = agent_mod.create({ config = {} })
    agent.cwd = root
    agent_mod.add_message(agent, "user", "实现功能")

    local ok = agents_md.inject(agent)
    t.true_(ok, "应注入成功")
    t.true_(agent._agents_md_injected == true)
    t.eq(3, #agent.messages, "用户消息 + assistant tool_calls + tool 结果")

    local call = agent.messages[2]
    t.eq("assistant", call.role)
    t.eq(1, #call.tool_calls)
    t.eq("read_file", call.tool_calls[1]["function"].name)
    t.true_(call.tool_calls[1]["function"].arguments:find("start_line", 1, true) ~= nil,
      "参数须显式带行范围（否则大文件只回大纲）")
    t.true_(call.meta and call.meta.agents_md == true, "assistant 消息应带 agents_md 标记")
    t.true_(type(call.reasoning) == "string" and call.reasoning ~= "",
      "虚构轮必须带占位 reasoning（DeepSeek thinking + tools 要求历史 assistant 回传 reasoning_content）")
    t.true_(agents_md.is_target(root .. "/AGENTS.md", root), "约定文件应识别为只读免审批目标")
    t.false_(agents_md.is_target(root .. "/OTHER.md", root), "其他文件不应命中免审批豁免")

    local res = agent.messages[3]
    t.eq("tool", res.role)
    t.eq(call.tool_calls[1].id, res.tool_call_id, "tool_call_id 必须与调用一致")
    t.true_(res.content:find("保持测试通过", 1, true) ~= nil, "结果应含文件正文")
    t.true_(res.content:find("审批", 1, true) ~= nil, "结果应说明写入需审批")
    t.true_(res.meta and res.meta.agents_md == true, "tool 消息应带 agents_md 标记")

    vim.fn.delete(root, "rf")
    end)
  end)

  it("backfill 为旧会话的虚构工具轮补齐占位 reasoning", function(t)
    local agent = {
      id = "old_agents_md",
      messages = {
        {
          role = "assistant", content = "", meta = { agents_md = true },
          tool_calls = { { id = "c1", type = "function", ["function"] = { name = "read_file", arguments = "{}" } } },
        },
        { role = "tool", tool_call_id = "c1", content = "old", meta = { agents_md = true } },
      },
    }
    t.true_(agents_md.backfill(agent), "无 reasoning 时应补齐")
    t.true_(type(agent.messages[1].reasoning) == "string" and agent.messages[1].reasoning ~= "")
    t.false_(agents_md.backfill(agent), "已补齐后应幂等")

    -- meta 不随会话持久化：旧会话靠调用 id 前缀识别
    local legacy = {
      id = "old_agents_md2",
      messages = {
        {
          role = "assistant", content = "",
          tool_calls = { { id = "neoai_agents_md_old", type = "function",
            ["function"] = { name = "read_file", arguments = "{}" } } },
        },
      },
    }
    t.true_(agents_md.backfill(legacy), "旧会话应按 id 前缀补齐")
    t.true_(type(legacy.messages[1].reasoning) == "string" and legacy.messages[1].reasoning ~= "")
  end)

  it("inject 幂等：第二次不再注入", function(t)
    enable(function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    vim.fn.writefile({ "x" }, root .. "/AGENTS.md")
    local agent_mod = require("NeoAI.core.agent.agent")
    local agent = agent_mod.create({ config = {} })
    agent.cwd = root
    agent_mod.add_message(agent, "user", "第一条")
    t.true_(agents_md.inject(agent))
    local n = #agent.messages
    t.false_(agents_md.inject(agent), "第二次不应再注入")
    t.eq(n, #agent.messages, "消息数不应增加")
    vim.fn.delete(root, "rf")
    end)
  end)

  it("无 AGENTS.md 时不注入，且不置幂等标记（后续仍可重试）", function(t)
    enable(function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local agent_mod = require("NeoAI.core.agent.agent")
    local agent = agent_mod.create({ config = {} })
    agent.cwd = root
    agent_mod.add_message(agent, "user", "hi")
    t.false_(agents_md.inject(agent))
    t.nil_(agent._agents_md_injected, "未注入不应置标记")
    t.eq(1, #agent.messages)
    vim.fn.delete(root, "rf")
    end)
  end)

  it("配置 enabled=false 时零副作用", function(t)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    vim.fn.writefile({ "x" }, root .. "/AGENTS.md")
    with_cfg({ enabled = false }, function()
      local agent_mod = require("NeoAI.core.agent.agent")
      local agent = agent_mod.create({ config = {} })
      agent.cwd = root
      agent_mod.add_message(agent, "user", "hi")
      t.false_(agents_md.should_inject(agent), "关闭时不应注入")
      t.false_(agents_md.inject(agent))
      t.eq(1, #agent.messages)
    end)
    vim.fn.delete(root, "rf")
  end)

  it("子 Agent 不注入", function(t)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    vim.fn.writefile({ "x" }, root .. "/AGENTS.md")
    local agent_mod = require("NeoAI.core.agent.agent")
    local agent = agent_mod.create({ config = {} })
    agent.cwd = root
    agent.parent = "parent-1"
    agent_mod.add_message(agent, "user", "hi")
    enable(function()
      t.false_(agents_md.should_inject(agent), "子 Agent 不应注入")
    end)
    vim.fn.delete(root, "rf")
  end)

  it("ensure 容错：异常路径不抛错", function(t)
    t.eq(false, agents_md.ensure(nil))
    t.eq(false, agents_md.ensure({}))
  end)
end)
