--- 聊天折叠程度测试
--- @module 'NeoAI.tests.test_chat_fold'

local tests = require("NeoAI.tests")

local function _find_line(lines, needle)
  for i, l in ipairs(lines or {}) do
    if l:find(needle, 1, true) then return i end
  end
  return nil
end

--- 按折叠文本查找处于**闭合折叠**内的行（Step 标记只出现在 foldtext 里，不在 buffer 文本中）。
--- 调用前需把聊天窗口设为当前窗口（foldclosed/foldtextresult 依赖窗口上下文）。
--- @param lines table
--- @param needle string
--- @return number|nil
local function _find_fold_line(lines, needle)
  for i in ipairs(lines or {}) do
    local closed = vim.fn.foldclosed(i)
    if closed > 0 and vim.fn.foldtextresult(closed):find(needle, 1, true) then return i end
  end
  return nil
end

--- 取某行所在折叠的折叠文本（未在折叠内时返回空串）。
--- @param line number
--- @return string
local function _fold_text_at(line)
  local closed = vim.fn.foldclosed(line)
  if closed <= 0 then return "" end
  return vim.fn.foldtextresult(closed)
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
  it("process：轮次完成后中间 Step 全部收进过程折叠，最终 Step 按序显示 Step N", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    local config_store = require("NeoAI.kernel.config_store")
    chat_view.reset(); chat_service.reset()
    config_store.load({ ui = { chat = { fold = "process", process_keep_steps = 3 } } })
    local opened = chat_view.open()
    local agent = assert(chat_service.get_current_agent())
    -- agent 空闲 = 本轮已结束：process_keep_steps 不再生效，中间 Step 全部收起
    agent.state = "idle"
    agent.messages = _messages()
    chat_view.refresh()
    vim.api.nvim_set_current_win(opened.win_id)

    local lines = vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false)
    local proc = _find_line(lines, "🧩 过程")
    t.not_nil(proc, "应显示过程折叠首行")
    t.true_(vim.fn.foldclosed(proc) > 0, "过程折叠应默认收起")
    local label = vim.fn.foldtextresult(vim.fn.foldclosed(proc))
    t.true_(label:find("Step 1-5", 1, true) ~= nil, "折叠文本应标明被折叠的 Step 范围: " .. label)
    t.true_(label:find("3✓/2✗", 1, true) ~= nil, "折叠文本应含工具成功/失败: " .. label)
    t.true_(label:find("5.0k", 1, true) ~= nil, "折叠文本应含 token 消耗: " .. label)
    t.true_(label:find("缓存 60%", 1, true) ~= nil, "折叠文本应含缓存命中率: " .. label)
    -- 角色头不再带 Step 标记（`🤖 AI` 顶多出现一次，且不含 Step）
    local ai_header
    for i, l in ipairs(lines) do
      if l:find("🤖 AI", 1, true) then
        ai_header = l
        t.true_(not l:find("Step", 1, true), "角色头不应再带 Step 标记，实际: " .. l)
        t.not_nil(i)
      end
    end
    t.eq("🤖 AI", ai_header, "应保留一个纯角色头")
    -- 被折叠的 Step 不再各自占一行：buffer 文本里不应再有 "Step" 字样
    t.eq(nil, _find_line(lines, "Step"), "buffer 文本不应再出现 Step 行（Step 标记只在折叠文本里）")
    -- 展开的最终 Step：其思考过程折叠文本带 `· Step 6`，且不被过程折叠收进去
    local final_think = assert(_find_line(lines, "think 6"), "最终 Step 的推理应保留")
    t.eq(vim.fn.foldlevel(final_think), 1, "最终 Step 的推理应为普通 level 1 折叠（不在过程折叠内）")
    t.true_(_fold_text_at(final_think):find("Step 6", 1, true) ~= nil,
      "最终 Step 的思考过程折叠文本应带 Step 6，实际: " .. _fold_text_at(final_think))
    local final_body = assert(_find_line(lines, "final answer"), "最终回答正文应展示")
    t.eq(-1, vim.fn.foldclosed(final_body), "最终回答正文不应被折叠")
    -- 折叠仅隐藏内容：推理/工具文本仍在 buffer 里，且处于闭合的过程折叠内
    local think4 = _find_line(lines, "think 4")
    t.not_nil(think4, "think 4 文本应仍保留在 buffer 中（折叠仅隐藏）")
    t.eq(vim.fn.foldclosed(proc), vim.fn.foldclosed(think4),
      "轮次完成后 think 4 应收进过程折叠（与过程折叠同一闭合折叠）")

    config_store.load({ ui = { chat = { fold = "reasoning_tools", process_keep_steps = 3 } } })
    chat_view.reset(); chat_service.reset()
  end)

  it("process：本轮进行中（agent 正忙）仍保留最近 process_keep_steps 步展开", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    local config_store = require("NeoAI.kernel.config_store")
    chat_view.reset(); chat_service.reset()
    config_store.load({ ui = { chat = { fold = "process", process_keep_steps = 3 } } })
    local opened = chat_view.open()
    local agent = assert(chat_service.get_current_agent())
    agent.state = "generating"
    agent.messages = _messages()
    chat_view.refresh()
    vim.api.nvim_set_current_win(opened.win_id)

    local lines = vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false)
    local proc = _find_line(lines, "🧩 过程")
    t.not_nil(proc, "应显示过程折叠首行")
    t.true_(vim.fn.foldclosed(proc) > 0, "过程折叠应默认收起")
    local label = vim.fn.foldtextresult(vim.fn.foldclosed(proc))
    t.true_(label:find("Step 1-3", 1, true) ~= nil, "进行中只折叠前面 3 步: " .. label)
    -- 未收起的 Step 4/5/6：位于过程折叠范围之外，且思考过程 / 工具调用折叠文本带各自 Step 标记
    local proc_end = vim.fn.foldclosedend(proc)
    for _, n in ipairs({ 4, 5, 6 }) do
      local think = assert(_find_line(lines, "think " .. n), "think " .. n .. " 应保留")
      t.true_(think > proc_end, "Step " .. n .. " 应在过程折叠之外（保持展开）")
      t.true_(_fold_text_at(think):find("Step " .. n, 1, true) ~= nil,
        "思考过程折叠文本应带 Step " .. n .. "，实际: " .. _fold_text_at(think))
      local tool = _find_line(lines, "git_status · d" .. n)
      if tool then
        t.true_(tool > proc_end, "工具 d" .. n .. " 应在过程折叠之外（保持展开）")
        t.true_(_fold_text_at(tool):find("Step " .. n, 1, true) ~= nil,
          "工具调用折叠文本应带 Step " .. n .. "，实际: " .. _fold_text_at(tool))
      else
        -- 第 6 步是最终回答（无工具调用）
        t.eq(6, n, "只有最终 Step 可以没有工具调用")
      end
    end
    -- 角色头不带 Step 标记；buffer 文本里不应再有 Step 字样
    t.eq(nil, _find_line(lines, "Step"), "buffer 文本不应出现 Step 行（Step 标记只在折叠文本里）")
    local think3 = _find_line(lines, "think 3")
    t.not_nil(think3, "think 3 文本应仍保留在 buffer 中")
    t.eq(vim.fn.foldclosed(proc), vim.fn.foldclosed(think3),
      "进行中仅最近 3 步展开，think 3 应收进过程折叠")

    -- 本轮结束（agent 回到 idle）后重渲染：最近 3 步也应一并收起
    agent.state = "idle"
    chat_view.refresh()
    vim.wait(200, function() return false end)
    lines = vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false)
    proc = _find_line(lines, "🧩 过程")
    t.not_nil(proc, "轮次结束后应仍有过程折叠")
    local label2 = vim.fn.foldtextresult(vim.fn.foldclosed(assert(proc)))
    t.true_(label2:find("Step 1-5", 1, true) ~= nil, "轮次结束后最近 3 步应一并收起: " .. label2)
    t.eq(vim.fn.foldclosed(proc), vim.fn.foldclosed(assert(_find_line(lines, "think 4"))),
      "轮次结束后 think 4 应收进过程折叠")
    -- 最终 Step 仍展开（在过程折叠之外），且其思考过程折叠文本带 Step 6
    local final_think = assert(_find_line(lines, "think 6"))
    t.true_(final_think > vim.fn.foldclosedend(proc), "最终 Step 应在过程折叠之外")
    t.true_(_fold_text_at(final_think):find("Step 6", 1, true) ~= nil,
      "最终 Step 折叠文本应带 Step 6，实际: " .. _fold_text_at(final_think))

    config_store.load({ ui = { chat = { fold = "reasoning_tools", process_keep_steps = 3 } } })
    chat_view.reset(); chat_service.reset()
  end)

  it("process：过程折叠为一级、内部推理/工具块为二级，展开过程折叠后各自仍收起", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    local config_store = require("NeoAI.kernel.config_store")
    chat_view.reset(); chat_service.reset()
    config_store.load({ ui = { chat = { fold = "process", process_keep_steps = 3 } } })
    local opened = chat_view.open()
    local agent = assert(chat_service.get_current_agent())
    agent.state = "idle"
    agent.messages = _messages()
    chat_view.refresh()
    vim.api.nvim_set_current_win(opened.win_id)

    local lines = vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false)
    local proc = assert(_find_line(lines, "🧩 过程"), "应显示过程折叠首行")
    t.eq(1, vim.fn.foldlevel(proc), "过程折叠应为 level 1")
    -- 过程折叠内的推理行/工具块首行应为 level 2（二级嵌套折叠），而不是与过程折叠同为 level 1
    local think1 = assert(_find_line(lines, "think 1"), "过程折叠内应有推理内容")
    t.eq(2, vim.fn.foldlevel(think1), "过程折叠内的推理行应为 level 2")
    -- 过程折叠内的角色头已取消：Step 范围只在过程折叠文本里标注
    t.eq(nil, _find_line(lines, "Step 1"), "过程折叠内不应再有 Step 角色头行")
    t.true_(vim.fn.foldtextresult(proc):find("Step 1-5", 1, true) ~= nil,
      "过程折叠文本应标明 Step 1-5")

    -- 展开过程折叠：内部推理/工具块应各自仍保持收起（二级折叠不被连带展开），
    -- 且各自的折叠文本带对应的 Step 标记
    vim.api.nvim_win_set_cursor(opened.win_id, { proc, 0 })
    vim.cmd("silent! normal! zo")
    t.eq(-1, vim.fn.foldclosed(proc), "展开后过程折叠应处于打开状态")
    local think1 = assert(_find_line(lines, "think 1"))
    t.true_(vim.fn.foldclosed(think1) > 0, "展开过程折叠后推理块应仍收起（二级折叠）")
    t.true_(_fold_text_at(think1):find("Step 1", 1, true) ~= nil,
      "过程折叠内的思考过程折叠文本应带 Step 1")
    t.true_(_fold_text_at(assert(_find_line(lines, "git_status · d1"))):find("Step 1", 1, true) ~= nil,
      "过程折叠内的工具调用折叠文本应带 Step 1")
    local tool1 = assert(_find_line(lines, "git_status · d1"), "过程折叠内应有工具块")
    t.true_(vim.fn.foldclosed(tool1) > 0, "展开过程折叠后工具块应仍收起（二级折叠）")

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
