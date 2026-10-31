--- NeoAI 事件总线
--- @module 'NeoAI.kernel.event_bus'
--- 基于 Neovim 原生 User autocmd 的轻量发布/订阅。
--- - emit(event, payload)：触发事件，payload 放入 args.data
--- - on(event, cb)：订阅，返回取消函数
--- - 事件名规范化：强制 "domain:verb" 格式，统一加 "NeoAI:" 前缀避免冲突

local events = require("NeoAI.kernel.events")

local M = {}

-- ========== 私有状态 ==========

local state = {
  groups = {}, -- pattern -> augroup id（同一事件共享一个 augroup）
}

-- ========== 私有函数 ==========

--- 规范化事件名（自动加 NeoAI: 前缀）
--- @param event string
--- @return string
local function _normalize(event)
  if event:sub(1, 6) == "NeoAI:" then return event end
  return "NeoAI:" .. event
end

--- 深度上限：防御异常/自引用结构（正常载荷远小于此）。
local SANITIZE_MAX_DEPTH = 20

--- 生成「可转换为 Vimscript 值」的载荷副本：去掉函数/线程/userdata 与不可作键的值。
--- `nvim_exec_autocmds` 的 data 必须能转成 Vimscript 值；载荷里夹带 uv 句柄等 userdata
--- （实测报 `Invalid 'data': Cannot convert userdata`）时事件完全投递不到订阅者。
--- 仅在直接投递失败时作为兜底调用。
--- @param value any
--- @param seen table|nil 环检测
--- @param depth number|nil
--- @return any|nil 清理后的值（不可转换时为 nil）
local function _sanitize(value, seen, depth)
  local t = type(value)
  if t == "function" or t == "thread" or t == "userdata" or t == "cdata" then return nil end
  if t ~= "table" then return value end
  depth = depth or 0
  if depth >= SANITIZE_MAX_DEPTH then return nil end
  seen = seen or {}
  if seen[value] then return nil end
  seen[value] = true
  local out = {}
  for k, v in pairs(value) do
    local kt = type(k)
    if kt == "string" or kt == "number" or kt == "boolean" then
      local sv = _sanitize(v, seen, depth + 1)
      if sv ~= nil then out[k] = sv end
    end
  end
  seen[value] = nil
  return out
end

-- ========== 公开 API ==========

--- 触发事件
--- @param event string 常量名或 "domain:verb"
--- @param payload any|nil
function M.emit(event, payload)
  -- libuv 快速事件回调（如 host_proxy 连接回调、job 输出回调）中不得调用 nvim_exec_autocmds
  -- （E5560: must not be called in a fast event context）。此时调度到主循环再触发，避免事件丢失。
  if vim.in_fast_event and vim.in_fast_event() then
    vim.schedule(function() M.emit(event, payload) end)
    return
  end
  local pattern = _normalize(event)
  local ok, err = pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = pattern,
    data = payload,
  })
  if not ok then
    -- 载荷含函数/userdata（如 `tools.external` 的工具定义带 run 函数）时无法转成 Vimscript 值：
    -- 先尝试投递「去掉不可转换值」的副本，保证订阅者仍能收到事件；仍失败才告警。
    local ok2, err2 = pcall(vim.api.nvim_exec_autocmds, "User", {
      pattern = pattern,
      data = _sanitize(payload),
    })
    if not ok2 then
      local logger = require("NeoAI.kernel.logger")
      logger.warn("[event_bus] 触发事件失败 %s: %s", pattern, tostring(err2 or err))
    end
  end
end

--- 订阅事件
--- @param event string
--- @param cb function(args) 其中 args.data = payload
--- @return function 取消订阅函数
function M.on(event, cb)
  local pattern = _normalize(event)
  -- 同一事件共享一个 augroup；不要 clear=true，否则会清掉其他订阅者
  if not state.groups[pattern] then
    state.groups[pattern] = vim.api.nvim_create_augroup("NeoAIEventBus_" .. pattern, {})
  end
  local id = vim.api.nvim_create_autocmd("User", {
    pattern = pattern,
    group = state.groups[pattern],
    callback = function(args)
      local ok, err = pcall(cb, args.data, args)
      if not ok then
        local logger = require("NeoAI.kernel.logger")
        logger.warn("[event_bus] 事件处理异常 %s: %s", pattern, tostring(err))
      end
    end,
  })
  return function()
    pcall(vim.api.nvim_del_autocmd, id)
  end
end

--- 订阅一次（触发后自动取消）
--- @param event string
--- @param cb function
--- @return function 取消订阅函数
function M.once(event, cb)
  local unsub
  unsub = M.on(event, function(data, args)
    if unsub then unsub() end
    cb(data, args)
  end)
  return unsub
end

--- 清除所有事件订阅
function M.clear_all()
  for _, group in pairs(state.groups) do
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end
  state.groups = {}
end

--- 事件常量表引用（便捷）
--- @return table
function M.constants()
  return events
end

--- 获取已注册的事件组数量（调试用）
--- @return number
function M.count()
  local n = 0
  for _ in pairs(state.groups) do n = n + 1 end
  return n
end

return M
