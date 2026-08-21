--- 循环护栏测试
--- @module NeoAI.tests.test_guard

local tests = require("NeoAI.tests")

tests.suite("guard", function(_, it)
  it("连续重复工具调用按阈值注入提醒", function(t)
    local guard = require("NeoAI.core.agent.guard")
    local agent = { id = "g1" }
    local call = function()
      return { { id = "1", ["function"] = { name = "read_file", arguments = '{"filepath":"a.txt"}' } } }
    end
    t.nil_(guard.check_round(agent, call(), nil))
    t.nil_(guard.check_round(agent, call(), nil))
    local reminder = guard.check_round(agent, call(), nil)
    t.not_nil(reminder)
    t.matches("连续", reminder or "")
    t.eq(3, agent.guard.repeats)
  end)

  it("参数变化或用户新消息重置计数", function(t)
    local guard = require("NeoAI.core.agent.guard")
    local agent = { id = "g2" }
    local callA = function()
      return { { id = "1", ["function"] = { name = "read_file", arguments = '{"filepath":"a.txt"}' } } }
    end
    local callB = function()
      return { { id = "1", ["function"] = { name = "read_file", arguments = '{"filepath":"b.txt"}' } } }
    end
    guard.check_round(agent, callA(), nil)
    guard.check_round(agent, callA(), nil)
    -- 参数变化重置
    guard.check_round(agent, callB(), nil)
    t.eq(1, agent.guard.repeats)
    -- 用户新消息重置
    guard.check_round(agent, callB(), nil)
    t.eq(2, agent.guard.repeats)
    guard.reset(agent)
    t.nil_(agent.guard)
  end)

  it("阈值与文案可配置，可整体禁用", function(t)
    local guard = require("NeoAI.core.agent.guard")
    local call = function()
      return { { ["function"] = { name = "run_command", arguments = '{"command":"ls"}' } } }
    end
    local agent = { id = "g3" }
    local cfg = { enabled = true, thresholds = { 2 }, messages = { [2] = "停止重复执行" } }
    t.nil_(guard.check_round(agent, call(), cfg))
    t.eq("停止重复执行", guard.check_round(agent, call(), cfg))

    local agent2 = { id = "g4" }
    local cfg2 = { enabled = false }
    t.nil_(guard.check_round(agent2, call(), cfg2))
    t.nil_(guard.check_round(agent2, call(), cfg2))
  end)

  it("并行多工具调用整轮签名匹配", function(t)
    local guard = require("NeoAI.core.agent.guard")
    local agent = { id = "g5" }
    local calls = function()
      return {
        { id = "1", ["function"] = { name = "read_file", arguments = '{"filepath":"a"}' } },
        { id = "2", ["function"] = { name = "search_files", arguments = '{"query":"x"}' } },
      }
    end
    t.nil_(guard.check_round(agent, calls(), nil))
    t.nil_(guard.check_round(agent, calls(), nil))
    t.not_nil(guard.check_round(agent, calls(), nil))
  end)
end)