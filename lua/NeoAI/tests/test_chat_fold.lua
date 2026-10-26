--- 聊天折叠程度测试
--- @module 'NeoAI.tests.test_chat_fold'

local tests = require("NeoAI.tests")

local function _find_line(lines, needle)
  for i, l in ipairs(lines or {}) do
    if l:find(needle, 1, true) then return i end
  end
  return nil
end

local function _messages()
  local msgs = { { role = "user", content = "question" } }
  for i = 1, 6 do
    local tool_calls = nil
    if i < 6 then
      tool_calls = { { id = "c" .. i, ["function"] = {
        name = "git_status", arguments = '{"description":"d' .. i .. '"}',
      } } }
    end
    msgs[#msgs + 1] = {
      role = "assistant",
      content = i == 6 and "final answer" or "",
      reasoning = "think " .. i,
      usage = {
        prompt_tokens = 1000, completion_tokens = 100,
        prompt_cache_hit_tokens = 600,
      },
      tool_calls = tool_calls,
    }
    if i < 6 then
      msgs[#msgs + 1] = {
        role = "tool", tool_call_id = "c" .. i,
        content = (i % 2 == 0) and '{"error":"x"}' or "ok",
      }
    end
  end
  return msgs
end

tests.suite("chat_fold", function(_, it)
  it("process：旧 Step 收进过程折叠，折叠文本含轮次/工具成败/token/缓存", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    local config_store = require("NeoAI.kernel.config_store")
    chat_view.reset(); chat_service.reset()
    config_store.load({ ui = { chat = { fold = "process", process_keep_steps = 3 } } })
    local opened = chat_view.open()
    local agent = assert(chat_service.get_current_agent())
    agent.messages = _messages()
    chat_view.refresh()
    vim.api.nvim_set_current_win(opened.win_id)

    local lines = vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false)
    local proc = _find_line(lines, "🧩 过程")
    local step4 = _find_line(lines, "Step 4")
    local final = _find_line(lines, "最终回答")
    t.not_nil(proc, "应显示过程折叠首行")
    t.not_nil(step4, "最近 Step 4 应保持展开")
    t.not_nil(final, "最终回答应保留")
    t.true_(vim.fn.foldclosed(proc) > 0, "过程折叠应默认收起")
    local label = vim.fn.foldtextresult(vim.fn.foldclosed(proc))
    t.true_(label:find("3 轮", 1, true) ~= nil, "折叠文本应含折叠轮次: " .. label)
    t.true_(label:find("2✓/1✗", 1, true) ~= nil, "折叠文本应含工具成功/失败: " .. label)
    t.true_(label:find("3.0k", 1, true) ~= nil, "折叠文本应含 token 消耗: " .. label)
    t.true_(label:find("缓存 60%", 1, true) ~= nil, "折叠文本应含缓存命中率: " .. label)
    t.eq(-1, vim.fn.foldclosed(step4), "最近 3 步不应被过程折叠")
    t.eq(-1, vim.fn.foldclosed(final), "最终回答不应被过程折叠")

    config_store.load({ ui = { chat = { fold = "reasoning_tools", process_keep_steps = 3 } } })
    chat_view.reset(); chat_service.reset()
  end)

  it("none：关闭窗口折叠，思考与工具内容全部展开", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    local config_store = require("NeoAI.kernel.config_store")
    chat_view.reset(); chat_service.reset()
    config_store.load({ ui = { chat = { fold = "none", process_keep_steps = 3 } } })
    local opened = chat_view.open()
    local agent = assert(chat_service.get_current_agent())
    agent.messages = _messages()
    chat_view.refresh()
    vim.api.nvim_set_current_win(opened.win_id)

    t.eq(false, vim.wo[opened.win_id].foldenable, "none 模式应关闭 foldenable")
    local lines = vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false)
    local think = _find_line(lines, "think 1")
    t.not_nil(think, "思考内容应展示")
    t.eq(-1, vim.fn.foldclosed(think), "none 模式不应有闭合折叠")
    t.eq(nil, _find_line(lines, "🧩 过程"), "none 模式不应出现过程折叠")

    config_store.load({ ui = { chat = { fold = "reasoning_tools", process_keep_steps = 3 } } })
    chat_view.reset(); chat_service.reset()
  end)

  it("reasoning_tools（默认）：保持现状，不生成过程折叠", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    local config_store = require("NeoAI.kernel.config_store")
    chat_view.reset(); chat_service.reset()
    config_store.load({ ui = { chat = { fold = "reasoning_tools", process_keep_steps = 3 } } })
    local opened = chat_view.open()
    local agent = assert(chat_service.get_current_agent())
    agent.messages = _messages()
    chat_view.refresh()
    vim.api.nvim_set_current_win(opened.win_id)

    local lines = vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false)
    t.eq(nil, _find_line(lines, "🧩 过程"), "默认模式不应出现过程折叠")
    t.true_(vim.wo[opened.win_id].foldenable, "默认模式应启用折叠")

    chat_view.reset(); chat_service.reset()
  end)

  it("CONFIG_CHANGED：折叠程度热切换立即生效", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    local config_store = require("NeoAI.kernel.config_store")
    chat_view.reset(); chat_service.reset()
    config_store.load({ ui = { chat = { fold = "process", process_keep_steps = 3 } } })
    local opened = chat_view.open()
    local agent = assert(chat_service.get_current_agent())
    agent.messages = _messages()
    chat_view.refresh()
    vim.api.nvim_set_current_win(opened.win_id)
    t.true_(vim.wo[opened.win_id].foldenable, "process 应启用折叠")

    config_store.set("ui.chat.fold", "none")
    t.true_(vim.wait(2000, function()
      return vim.wo[opened.win_id].foldenable == false
    end, 20), "热切换 none 后应关闭折叠")

    config_store.load({ ui = { chat = { fold = "reasoning_tools", process_keep_steps = 3 } } })
    chat_view.reset(); chat_service.reset()
  end)
end)
