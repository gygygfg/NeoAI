--- 待办工具测试
--- @module NeoAI.tests.test_todo

local tests = require("NeoAI.tests")

local function find_tool(name)
  local todo = require("NeoAI.tools.builtin.todo")
  for _, tl in ipairs(todo.get_tools()) do
    if tl.name == name then return tl end
  end
  return nil
end

tests.suite("todo", function(_, it)
  it("todo_write 整表替换 + 校验", function(t)
    local todo = require("NeoAI.tools.builtin.todo")
    todo.reset()
    local agent = { id = "t1", session_id = "s1" }
    local tw = find_tool("todo_write")
    t.not_nil(tw)

    local out = {}
    tw.func(
      { todos = { { content = "任务A", status = "pending" }, { content = "任务B", status = "in_progress" } } },
      function(m) out.msg = m end,
      function(e) out.err = e end,
      { agent = agent })
    t.nil_(out.err)
    t.matches("2 项", out.msg or "")

    local items = todo.get("s1")
    t.eq(2, #items)
    t.eq("in_progress", items[2].status)
  end)

  it("多个 in_progress 被拒绝", function(t)
    local todo = require("NeoAI.tools.builtin.todo")
    todo.reset()
    local agent = { id = "t2", session_id = "s2" }
    local tw = find_tool("todo_write")
    local out = {}
    tw.func(
      { todos = { { content = "x", status = "in_progress" }, { content = "y", status = "in_progress" } } },
      function(m) out.msg = m end,
      function(e) out.err = e end,
      { agent = agent })
    t.matches("in_progress", out.err or "")
  end)

  it("空内容被忽略，重复内容被拒绝", function(t)
    local todo = require("NeoAI.tools.builtin.todo")
    todo.reset()
    local agent = { id = "t3", session_id = "s3" }
    local tw = find_tool("todo_write")

    local out = {}
    tw.func(
      { todos = { { content = "   " }, { content = "真实" } } },
      function(m) out.msg = m end,
      function(e) out.err = e end,
      { agent = agent })
    t.nil_(out.err)
    t.matches("1 项", out.msg or "")

    out = {}
    tw.func(
      { todos = { { content = "重复" }, { content = "重复" } } },
      function(m) out.msg = m end,
      function(e) out.err = e end,
      { agent = agent })
    t.matches("重复", out.err or "")
  end)

  it("todo_read / todo_clear / seed", function(t)
    local todo = require("NeoAI.tools.builtin.todo")
    todo.reset()
    local agent = { id = "t4", session_id = "s4" }
    find_tool("todo_write").func(
      { todos = { { content = "A" } } },
      function() end, function() end,
      { agent = agent })

    local tr = find_tool("todo_read")
    local out = {}
    tr.func({}, function(m) out.msg = m end, function(e) out.err = e end, { agent = agent })
    t.nil_(out.err)
    t.matches("A", out.msg or "")

    find_tool("todo_clear").func({}, function() end, function() end, { agent = agent })
    t.nil_(todo.get("s4"))

    todo.seed("s5", { { content = "恢复", status = "completed" } })
    local items = todo.get("s5")
    t.eq(1, #items)
    t.eq("completed", items[1].status)
    todo.reset()
  end)
end)
