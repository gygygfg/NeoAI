--- 子 Agent 管理器
--- @module 'NeoAI.core.agent.sub_agent'
--- 子 Agent 的唯一事实来源：注册表 + 生命周期 + 结果回传。
--- - create(parent, opts)：创建独立子 Agent（独立持久化子会话、零继承、独立信号）
--- - get / list_for / count_for / cancel / send：查询、终止、发送消息
--- - 自然结束（无更多工具调用）后，把最终正文回传主 Agent（经 dispatch 钩子）。
--- 子 Agent 提示自动追加「最后总结你的工作」指令。
--- 完成/失败的状态流转由 GENERATION_COMPLETED / GENERATION_ERROR 事件驱动（对 create 与
--- send 续跑统一生效）。分层：core 模块不依赖 services；结果回传 / 落盘由组合根
--- （chat_service）经 set_dispatch / set_persist 注入，未注入时降级。

local runtime = require("NeoAI.core.agent.runtime")
local session_store = require("NeoAI.core.session.session_store")
local session_mod = require("NeoAI.core.session.session")
local config_store = require("NeoAI.kernel.config_store")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")

local M = {}

-- ========== 私有常量 ==========

--- 子 Agent 提示自动追加的收尾指令（要求最后总结工作）。
--- 可在 config tools.sub_agent.final_instruction 覆盖；设为 "" 可关闭。
local DEFAULT_FINAL_INSTRUCTION =
  "最后请总结你的工作：用简洁的正文汇总你做了什么、得到的关键结论与证据（文件:行），以及任何未完成或需要注意的点。"

-- 子 Agent 永不获得的「调度类」工具（避免无限递归派生 / 越权调度）
local AGENT_TOOLS = {
  create_sub_agent = true,
  get_sub_agent_status = true,
  cancel_sub_agent = true,
  send_sub_agent_message = true,
  wait_sub_agent = true,
}

-- ========== 私有状态 ==========

local state = {
  subs = {}, -- sub_id -> entry
  order = {}, -- 插入顺序的 sub_id
  by_agent = {}, -- agent_id -> sub_id（快速反查）
  dispatch = nil, -- fn(agent, content, fallback_session_id)：结果/消息投递（chat_service 注入）
  persist = nil, -- fn(agent)：把子 Agent 消息落盘到其子会话（chat_service 注入）
  inited = false,
  unsubs = {},
}

-- ========== 私有函数 ==========

local function _new_id()
  local t = os.time()
  local n = math.random(1, 2 ^ 31)
  return string.format("sub_%x_%x", t, n)
end

--- 由任务文本派生一个简短显示名（首行、截断）
--- @param task string
--- @return string
local function _derive_name(task)
  local first = tostring(task or ""):match("^%s*([^\n]*)") or "子任务"
  first = first:gsub("^%s+", ""):gsub("%s+$", "")
  if first == "" then first = "子任务" end
  if #first > 24 then first = first:sub(1, 23) .. "…" end
  return first
end

local function _final_instruction()
  local v = config_store.get("tools.sub_agent.final_instruction")
  if type(v) ~= "string" then return DEFAULT_FINAL_INSTRUCTION end
  return v
end

--- 构建子 Agent 可见工具子集（排除调度类工具）
--- @param tools table|nil name -> def
--- @return table name -> def
local function _sanitize_tools(tools)
  local out = {}
  for name, tool in pairs(tools or {}) do
    if not AGENT_TOOLS[name] then out[name] = tool end
  end
  return out
end

--- 子 Agent 完成/失败后回传主 Agent。
--- @param entry table
--- @param body string
local function _deliver(entry, body)
  local parent = entry.parent_agent_id and runtime.get(entry.parent_agent_id) or nil
  local label = entry.status == "completed" and "已完成"
    or (entry.status == "cancelled" and "已取消" or "失败")
  local text = ("【子 Agent \"%s\" %s】\n%s"):format(entry.name or entry.id, label, tostring(body or ""))
  local marker = { id = entry.id, name = entry.name, status = entry.status, task = entry.task }
  if state.dispatch then
    state.dispatch(parent, text, entry.parent_session_id, { sub_agent = marker })
  elseif parent then
    -- 未注入 dispatch（测试/未启动）：退化为直接驱动父 Agent 生成。
    pcall(function() runtime.run(parent, text, { message_extra = { sub_agent = marker } }) end)
  end
end

local function _persist_child(entry)
  if not state.persist then return end
  local child = entry.agent_id and runtime.get(entry.agent_id) or nil
  if child then pcall(state.persist, child) end
end

--- 从子 Agent 的最后一条 assistant 消息取最终正文
--- @param entry table
--- @return string
local function _final_text(entry)
  local child = entry.agent_id and runtime.get(entry.agent_id) or nil
  if not child or not child.messages then return "" end
  for i = #child.messages, 1, -1 do
    local m = child.messages[i]
    if m.role == "assistant" and m.content and m.content ~= "" then return m.content end
  end
  return ""
end

local function _settle(entry, status, body)
  if not entry or entry.status ~= "running" then return end
  entry.status = status
  entry.result_text = body or ""
  _persist_child(entry)
  if status == "completed" then
    event_bus.emit(events.SUB_AGENT_COMPLETED, { sub_agent_id = entry.id, name = entry.name, status = status })
  elseif status == "cancelled" then
    event_bus.emit(events.SUB_AGENT_UPDATED, { sub_agent_id = entry.id, status = status })
  else
    event_bus.emit(events.SUB_AGENT_ERROR, { sub_agent_id = entry.id, name = entry.name, error = entry.result_text })
  end
  event_bus.emit(events.SUB_AGENT_RESULT_READY, { sub_agent_id = entry.id })
  _deliver(entry, entry.result_text)
end

local function _entry_by_agent(agent_id)
  local id = agent_id and state.by_agent[agent_id]
  return id and state.subs[id] or nil
end

--- 父 Agent 销毁时，终止并销毁其子 Agent（避免孤儿与资源泄漏）
local function _on_parent_disposed(data)
  local pid = data and data.agent_id
  if not pid then return end
  local keep = {}
  for _, id in ipairs(state.order) do
    local entry = state.subs[id]
    if entry and entry.parent_agent_id == pid then
      -- 父已销毁：静默取消（不回传给已不存在的父，也不写回父会话存档）
      entry.parent_agent_id = nil
      entry.parent_session_id = nil
      if entry.status == "running" then M.cancel(id) end
      local child = entry.agent_id and runtime.get(entry.agent_id) or nil
      if child then pcall(runtime.dispose, child) end
      state.subs[id] = nil
      state.by_agent[entry.agent_id] = nil
    else
      keep[#keep + 1] = id
    end
  end
  state.order = keep
end

local function _init()
  if state.inited then return end
  state.inited = true
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.AGENT_DISPOSED, _on_parent_disposed)
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.GENERATION_COMPLETED, function(data)
    local entry = _entry_by_agent(data and data.agent_id)
    if entry then _settle(entry, "completed", _final_text(entry)) end
  end)
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.GENERATION_ERROR, function(data)
    local entry = _entry_by_agent(data and data.agent_id)
    if not entry then return end
    local err = data and data.error
    _settle(entry, "error", tostring((type(err) == "table" and err.message) or err or ""))
  end)
end

-- ========== 公开 API ==========

--- 注入投递钩子（chat_service 调用）。nil 清除。
--- @param fn function(agent, content, fallback_session_id)|nil
function M.set_dispatch(fn)
  state.dispatch = fn
end

--- 注入落盘钩子（chat_service 调用）。nil 清除。
--- @param fn function(agent)|nil
function M.set_persist(fn)
  state.persist = fn
end

--- 创建并启动一个子 Agent。
--- @param parent_agent table 主 Agent（须有 session_id 与 cwd）
--- @param opts table { task, name?, model?, boundaries?, tools? }
--- @return table|nil entry，失败返回 nil
--- @return string|nil err
function M.create(parent_agent, opts)
  opts = opts or {}
  if not parent_agent then return nil, "缺少主 Agent 上下文" end
  if type(opts.task) ~= "string" or opts.task == "" then return nil, "task 必填" end
  _init()

  local id = _new_id()
  local name = (type(opts.name) == "string" and opts.name ~= "") and opts.name or _derive_name(opts.task)
  local parent_session_id = parent_agent.session_id

  -- 独立持久化子会话（子节点挂在主会话下，可在会话树中查看）
  local session = session_store.create({
    parent_id = parent_session_id,
    name = name,
    metadata = { tags = { session_mod.SUB_AGENT_TAG }, name = name },
  })

  local child = runtime.spawn(parent_agent, {
    model = opts.model,
    session_id = session and session.id or nil,
    cwd = parent_agent.cwd,
    tools = {},
  })
  if not child then return nil, "子 Agent 创建失败" end
  child._sub_agent_id = id
  child._external_owner = "sub_agent"
  child.tools = _sanitize_tools(opts.tools)

  local entry = {
    id = id,
    name = name,
    task = opts.task,
    agent_id = child.id,
    session_id = session and session.id or nil,
    parent_agent_id = parent_agent.id,
    parent_session_id = parent_session_id,
    boundaries = opts.boundaries or {},
    status = "running",
    started_at = os.time(),
    result_text = nil,
    error = nil,
  }
  state.subs[id] = entry
  state.order[#state.order + 1] = id
  state.by_agent[child.id] = id

  event_bus.emit(events.SUB_AGENT_CREATED, {
    sub_agent_id = id, name = name, task = opts.task,
    agent_id = child.id, session_id = entry.session_id, parent_agent_id = parent_agent.id,
  })

  -- 提示自动追加收尾指令
  local instr = _final_instruction()
  local prompt = opts.task
  if instr ~= "" then prompt = prompt .. "\n\n" .. instr end

  -- 完成/失败的状态流转与回传由 GENERATION_COMPLETED/ERROR 事件驱动（见 _init）。
  local d = runtime.run(child, prompt)
  if d and type(d.catch) == "function" then
    pcall(function() d:catch(function() end) end)
  end

  return entry
end

--- 按 id 获取子 Agent 条目
--- @param id string
--- @return table|nil
function M.get(id)
  if not id then return nil end
  return state.subs[id]
end

--- 列出某主 Agent 派生（仍保留）的所有子 Agent（插入序）
--- @param parent_agent_id string
--- @return table 数组
function M.list_for(parent_agent_id)
  local out = {}
  if not parent_agent_id then return out end
  for _, id in ipairs(state.order) do
    local entry = state.subs[id]
    if entry and entry.parent_agent_id == parent_agent_id then
      out[#out + 1] = entry
    end
  end
  return out
end

--- 统计某主 Agent 的（运行中 / 总数）子 Agent
--- @param parent_agent_id string
--- @return number running, number total
function M.count_for(parent_agent_id)
  local running, total = 0, 0
  for _, entry in ipairs(M.list_for(parent_agent_id)) do
    total = total + 1
    if entry.status == "running" then running = running + 1 end
  end
  return running, total
end

--- 终止子 Agent
--- @param id string
--- @return boolean ok
--- @return string|nil err
function M.cancel(id)
  local entry = state.subs[id]
  if not entry then return false, "子 Agent 不存在: " .. tostring(id) end
  if entry.status ~= "running" then return true end
  local child = entry.agent_id and runtime.get(entry.agent_id) or nil
  if child then runtime.abort(child, "user_cancelled") end
  -- 立即置终态并回传（abort 的 GENERATION_ERROR 也可能随后触发，_settle 幂等）。
  _settle(entry, "cancelled", "")
  return true
end

--- 向子 Agent 发送消息（运行中注入下一轮；已完成则续跑一轮）
--- @param id string
--- @param content string
--- @return boolean ok
--- @return string|nil err
function M.send(id, content)
  local entry = state.subs[id]
  if not entry then return false, "子 Agent 不存在: " .. tostring(id) end
  if type(content) ~= "string" or content == "" then return false, "message 必填" end
  local child = entry.agent_id and runtime.get(entry.agent_id) or nil
  if not child then return false, "子 Agent 已销毁，无法发送消息" end
  -- 续跑：状态回到 running，便于状态栏/winbar 反映；完成由生成事件驱动。
  entry.status = "running"
  event_bus.emit(events.SUB_AGENT_UPDATED, { sub_agent_id = id, status = "running" })
  if state.dispatch then
    state.dispatch(child, content, nil)
  else
    local d = runtime.run(child, content)
    if d and type(d.catch) == "function" then
      pcall(function() d:catch(function() end) end)
    end
  end
  return true
end

--- 子 Agent 工具调用边界审核（供 tool_service）
--- @param sub_agent_id string
--- @param tool_name string
--- @return boolean, string|nil
function M.review_tool_call(sub_agent_id, tool_name)
  local entry = state.subs[sub_agent_id]
  if not entry then return true end
  if AGENT_TOOLS[tool_name] then
    return false, "[调度 agent 驳回] 子 Agent 不得调用调度类工具 '" .. tool_name .. "'"
  end
  local allowed = entry.boundaries and entry.boundaries.allowed_tools
  if allowed and #allowed > 0 then
    local hit = false
    for _, t in ipairs(allowed) do
      if t == tool_name then hit = true break end
    end
    if not hit then
      return false, "[调度 agent 驳回] 工具 '" .. tool_name .. "' 不在允许列表内"
    end
  end
  local max = entry.boundaries and entry.boundaries.max_tool_calls
  if max and (entry.tool_calls or 0) >= max then
    return false, "[调度 agent 驳回] 已达到最大工具调用次数"
  end
  return true
end

--- 记录子 Agent 工具调用数（供 tool_service）
--- @param sub_agent_id string
function M.track_tool_call(sub_agent_id)
  local entry = state.subs[sub_agent_id]
  if entry then entry.tool_calls = (entry.tool_calls or 0) + 1 end
end

--- 调度类工具名集合（供工具层排除）
--- @return table name -> true
function M.agent_tool_names()
  local out = {}
  for name in pairs(AGENT_TOOLS) do out[name] = true end
  return out
end

--- 测试辅助：直接构造子 Agent 条目
--- @param id string
--- @param opts table|nil { allowed_tools?, max_tool_calls?, name?, agent_id?, parent_agent_id?, session_id?, parent_session_id? }
function M._inject_for_test(id, opts)
  opts = opts or {}
  local agent_id = opts.agent_id or ("agent_" .. id)
  state.subs[id] = {
    id = id, name = opts.name or id, task = "test",
    agent_id = agent_id,
    session_id = opts.session_id, parent_agent_id = opts.parent_agent_id,
    parent_session_id = opts.parent_session_id,
    boundaries = { allowed_tools = opts.allowed_tools, max_tool_calls = opts.max_tool_calls or 10 },
    status = "running", tool_calls = 0,
  }
  state.order[#state.order + 1] = id
  state.by_agent[agent_id] = id
end

--- 复位（测试/插件卸载）
function M.reset()
  for _, u in ipairs(state.unsubs) do
    if u then pcall(u) end
  end
  state.unsubs = {}
  state.inited = false
  state.subs = {}
  state.order = {}
  state.by_agent = {}
  state.dispatch = nil
  state.persist = nil
end

--- 插件卸载入口
function M.shutdown()
  M.reset()
end

return M
