--- 向用户提问工具
--- @module NeoAI.tools.builtin.ask_user
--- AI 在生成过程中暂停并向用户提问，等待用户回答后把答案作为工具结果回传。
--- 计划模式下该工具是少数被允许的工具之一（用于澄清需求）。
--- UI 经 M.set_ui 注入（ui/components/ask_user 在 UI 初始化时注册）；
--- 未注册 UI 时回退到 vim.ui.input，仍不可用则报错（不阻塞工具循环）。

local helpers = require("NeoAI.tools.builtin.tool_helpers")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")

local M = {}

-- ========== 私有状态 ==========

local ui = nil -- { show(config), hide() }
-- 并行提问排队：同一时刻只展示一个提问弹窗，其余按序等待；前一个回答/取消后再展示下一个，
-- 而不是直接失败。UI 是单窗口，串行展示避免双弹窗互相覆盖挂起。
local queue = {} -- 待展示的提问（FIFO）
local current = nil -- 当前展示中的提问（none 时才有队列可弹出）

-- ========== 私有辅助（排队调度） ==========

--- 前置声明：_settle 在结束时调用 _drain 弹出队首（_drain 于下方定义）
local _drain

--- 终结一个提问：收敛状态、恢复计时器、上报事件、回传给工具框架。
--- @param inv table 提问对象
--- @param ok boolean 是否成功
--- @param result any 成功时答案 / 失败时错误表
--- @param allow_next boolean 是否继续展示队首（用户回答/取消后 true；Agent 中止时不新开弹窗）
local function _settle(inv, ok, result, allow_next)
  if inv.settled then return end
  inv.settled = true
  if current == inv then current = nil end
  if not inv.waiting_started then
    for i = #queue, 1, -1 do
      if queue[i] == inv then
        table.remove(queue, i)
        break
      end
    end
  end
  if inv.waiting_started then
    event_bus.emit(events.ASK_USER_ANSWERED, { agent_id = inv.agent_id })
  end
  if inv.timer and inv.timer.resume then pcall(inv.timer.resume, inv.timer) end
  if inv.unsub then pcall(inv.unsub) end
  if ok then
    inv.on_success(result)
  else
    inv.on_error(result)
  end
  -- 用户回答/取消后继续展示队首；Agent 中止等场景不新开弹窗。
  if allow_next and not current then
    _drain()
  end
end

--- 展示一个提问（等待用户回答）
--- @param inv table
local function _activate(inv)
  if not inv or inv.settled or inv.waiting_started then return end
  inv.waiting_started = true
  event_bus.emit(events.ASK_USER_WAITING, { agent_id = inv.agent_id })
  -- 真正开始等待用户前暂停计时器：等待时间不累计活跃耗时、不消耗超时预算。
  if inv.timer and inv.timer.pause then pcall(inv.timer.pause, inv.timer) end

  local config = {
    question = inv.question,
    options = inv.options,
    on_answer = function(answer)
      _settle(inv, true, ("用户回答: %s"):format(tostring(answer)), true)
    end,
    on_cancel = function(reason)
      _settle(inv, false, { kind = "cancelled", message = "用户取消了提问: " .. tostring(reason or "取消") }, true)
    end,
  }

  if ui and ui.show then
    local ok, err = pcall(ui.show, config)
    if not ok then
      _settle(inv, false, { kind = "ui", message = "提问界面打开失败: " .. tostring(err) }, true)
    end
    return
  end

  -- 未注册 UI：回退到 vim.ui.input（原生输入行）；仍不可用则报错
  local ok, err = pcall(function()
    vim.ui.input({ prompt = inv.question .. " " }, function(answer)
      if answer == nil or answer == "" then
        _settle(inv, false, { kind = "cancelled", message = "用户未输入回答（已跳过提问）" }, true)
      else
        _settle(inv, true, ("用户回答: %s"):format(tostring(answer)), true)
      end
    end)
  end)
  if not ok then
    _settle(inv, false, { kind = "ui", message = "无法向用户提问（未注册提问 UI 且 vim.ui.input 不可用）: " .. tostring(err) }, true)
  end
end

--- 若当前无提问，弹出队首提问
_drain = function()
  if current then return end
  local inv = table.remove(queue, 1)
  if not inv then return end
  current = inv
  _activate(inv)
end

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
        description = "可选：供用户快速选择的选项。每个选项可以是字符串，或对象 { label（选项简介，简短标签）, description（选项描述，可选，更详细说明） }。用户可直接选序号或输入自由回答。",
        items = {
          oneOf = {
            { type = "string", description = "纯字符串选项，该字符串即选项简介" },
            {
              type = "object",
              description = "带简介与描述的选项",
              properties = {
                label = { type = "string", description = "选项简介（简短标签，展示给用户并作为选中的答案）" },
                description = { type = "string", description = "选项描述（可选，更详细说明该选项的意图/影响）" },
              },
              required = { "label" },
            },
          },
        },
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
        if type(o) == "string" then
          if o ~= "" then options[#options + 1] = { label = o, description = "" } end
        elseif type(o) == "table" then
          local label = type(o.label) == "string" and o.label:gsub("%s+$", "") or ""
          if label == "" and type(o.name) == "string" then label = o.name:gsub("%s+$", "") end
          if label ~= "" then
            local description = type(o.description) == "string" and o.description or ""
            if description == "" and type(o.desc) == "string" then description = o.desc end
            options[#options + 1] = { label = label, description = description }
          end
        end
      end
    end

    local inv = {
      question = question,
      options = options,
      agent_id = ctx and ctx.agent and ctx.agent.id,
      on_success = on_success,
      on_error = on_error,
      timer = ctx and ctx.timer,
      settled = false,
      waiting_started = false, -- 是否真正进入等待（用于对称上报 waiting/answered）
      unsub = nil,
    }

    -- Agent 中止时立即终止等待（关闭当前展示的 UI + 拒绝）；排队中的提问一并终结，
    -- 不再弹新的提问。
    local signal = ctx and ctx.signal
    if signal and signal.subscribe then
      inv.unsub = signal:subscribe(function(reason)
        if current == inv and ui and ui.hide then pcall(ui.hide) end
        _settle(inv, false, { kind = "aborted", message = "提问被取消（" .. tostring(reason or "aborted") .. "）" }, false)
      end)
    end

    -- 并行提问入队等待：同一时刻只展示一个，其余按序排在前一个回答/取消后再展示，不直接失败。
    queue[#queue + 1] = inv
    _drain()
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
  queue = {}
  current = nil
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
