--- 向用户提问工具
--- @module NeoAI.tools.builtin.ask_user
--- AI 在生成过程中暂停并向用户提问，等待用户回答后把答案作为工具结果回传。
--- 计划模式下该工具是少数被允许的工具之一（用于澄清需求）。
--- UI 经 M.set_ui 注入（ui/components/ask_user 在 UI 初始化时注册）；
--- 未注册 UI 时回退到 vim.ui.input，仍不可用则报错（不阻塞工具循环）。

local helpers = require("NeoAI.tools.builtin.tool_helpers")

local M = {}

-- ========== 私有状态 ==========

local ui = nil -- { show(config), hide() }
local pending = false -- 是否有未回答的提问（工具循环并行执行，避免双提问互相覆盖挂起）

-- ========== 工具定义 ==========

local ask_user_tools = {}

ask_user_tools.ask_user = helpers.define_tool(
  "ask_user",
  "向用户提问并等待回答。question 必填；可提供 options（选项数组）让用户快速选择。在需要澄清需求、确认意图或缺少关键信息时使用。",
  {
    type = "object",
    properties = {
      question = { type = "string", description = "要向用户提出的问题" },
      options = {
        type = "array",
        description = "可选：供用户快速选择的选项（字符串数组），用户可直接选序号或输入自由回答",
        items = { type = "string" },
      },
    },
    required = { "question" },
  },
  function(args, on_success, on_error, ctx)
    local question = type(args.question) == "string" and args.question:gsub("%s+$", "") or ""
    if question == "" then
      on_error("ask_user 缺少必填参数 question")
      return
    end
    local options = {}
    if type(args.options) == "table" then
      for _, o in ipairs(args.options) do
        if type(o) == "string" and o ~= "" then
          options[#options + 1] = o
        end
      end
    end

    local settled = false
    -- 等待用户回答的耗时不计入工具执行时间/超时：暂停可暂停计时器，回答/取消后恢复。
    local timer = ctx and ctx.timer
    local function finish_ok(answer)
      if settled then return end
      settled = true
      pending = false
      if timer and timer.resume then pcall(timer.resume, timer) end
      on_success(("用户回答: %s"):format(tostring(answer)))
    end
    local function finish_err(err)
      if settled then return end
      settled = true
      pending = false
      if timer and timer.resume then pcall(timer.resume, timer) end
      on_error(err)
    end

    -- 同一时刻只允许一个未回答的提问（工具循环并行执行时防止双弹窗互相覆盖挂起）
    if pending then
      finish_err({ kind = "busy", message = "已有未回答的提问，请先等待用户回答上一个问题" })
      return
    end
    pending = true
    -- 真正开始等待用户前暂停计时器：等待时间不累计活跃耗时、不消耗超时预算。
    if timer and timer.pause then pcall(timer.pause, timer) end

    -- Agent 取消时立即终止等待（关闭 UI + 拒绝）
    local unsub
    local signal = ctx and ctx.signal
    if signal and signal.subscribe then
      unsub = signal:subscribe(function(reason)
        if ui and ui.hide then pcall(ui.hide) end
        finish_err({ kind = "aborted", message = "提问被取消（" .. tostring(reason or "aborted") .. "）" })
      end)
    end

    local function cleanup()
      if unsub then pcall(unsub) end
    end

    local config = {
      question = question,
      options = options,
      on_answer = function(answer)
        cleanup()
        finish_ok(answer)
      end,
      on_cancel = function(reason)
        cleanup()
        finish_err({ kind = "cancelled", message = "用户取消了提问: " .. tostring(reason or "取消") })
      end,
    }

    if ui and ui.show then
      local ok, err = pcall(ui.show, config)
      if not ok then
        cleanup()
        finish_err({ kind = "ui", message = "提问界面打开失败: " .. tostring(err) })
      end
      return
    end

    -- 未注册 UI：回退到 vim.ui.input（原生输入行）；仍不可用则报错
    local ok, err = pcall(function()
      vim.ui.input({ prompt = question .. " " }, function(answer)
        cleanup()
        if answer == nil or answer == "" then
          finish_err({ kind = "cancelled", message = "用户未输入回答（已跳过提问）" })
        else
          finish_ok(answer)
        end
      end)
    end)
    if not ok then
      cleanup()
      finish_err({ kind = "ui", message = "无法向用户提问（未注册提问 UI 且 vim.ui.input 不可用）: " .. tostring(err) })
    end
  end,
  { category = "agent", approval = { auto_allow = true }, timeout = 300000 }
)

-- ========== 公开 API ==========

--- 注册提问 UI 实现
--- @param impl table { show(config), hide() }
---   show(config): { question, options, on_answer(answer), on_cancel(reason) }
function M.set_ui(impl)
  ui = impl
end

--- 获取当前提问 UI（测试用）
--- @return table|nil
function M.get_ui()
  return ui
end

--- 重置（测试用）
function M.reset()
  ui = nil
  pending = false
end

--- 获取工具列表
--- @return table 数组
function M.get_tools()
  local out = {}
  for _, tool in pairs(ask_user_tools) do
    out[#out + 1] = tool
  end
  return out
end

return M
