--- NeoAI 状态栏服务
--- @module NeoAI.services.status
--- 汇总当前 Agent 的大模型用量、缓存命中、上下文容量等信息，供 nvim-lualine 等
--- 状态栏组件消费。纯读取，无副作用；component() 返回字符串，事件驱动刷新。
--- 集成方式（二选一）：
---   1. lualine 扩展：config.lualine = { extensions = { 'neoai' } }，在 neoai 聊天 window 自动生效；
---   2. 手动组件：require('NeoAI.services.status').component() 塞进自己的 lualine sections。

local config_store = require("NeoAI.kernel.config_store")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")

local M = {}

-- ========== 私有状态 ==========

local state = {
  opts = nil, -- 格式化选项（来自 config_store 或 setup）
  watching = false, -- 是否已订阅事件
  lualine_injected = false, -- 是否已把 'neoai' 注入 lualine extensions
  unsubs = {}, -- 事件订阅句柄
}

-- 默认格式化选项：可展示的段与分隔符
local DEFAULTS = {
  parts = { "mode", "model", "usage", "cache", "capacity" },
  separator = " ",
  -- 各段在高亮时链接到的 nvim 高亮组（避免使用 lualine 默认的灰暗 c/b 段配色）。
  -- 均取自 Vim 内置鲜艳组，用户可按需在 config 覆盖。
  colors = {
    mode = "Title",
    display = "Keyword",
    model = "Type",
    usage = "Number",
    cache = "String",
    capacity = "Statement",
    capacity_warn = "WarningMsg",
    capacity_over = "ErrorMsg",
    state = "Function",
    brand = "Title",
    pending = "Warning",
  },
}

-- ========== 私有函数 ==========

--- 合并用户选项（config_store 优先，setup 覆盖）
--- @return table
local function _opts()
  local cfg = vim.deepcopy(config_store.get("ui.statusline") or {})
  if state.opts then
    for k, v in pairs(state.opts) do cfg[k] = v end
  end
  return vim.tbl_extend("keep", cfg, DEFAULTS)
end

--- 数字紧凑格式：>=1000 显示为 k
--- @param n number
--- @return string
local function _fmt_tokens(n)
  n = tonumber(n) or 0
  if n >= 1000 then
    local v = n / 1000
    if v >= 100 then return string.format("%.0fk", v) end
    return string.format("%.1fk", v)
  end
  return tostring(math.floor(n + 0.5))
end

--- 百分比（0..1 -> "82%"）
--- @param x number
--- @return string
local function _fmt_pct(x)
  x = tonumber(x) or 0
  return string.format("%d%%", math.floor(x * 100 + 0.5))
end

--- 转义 statusline 中的 %（lualine 对函数组件返回值不做转义，否则 % 会被当作
--- statusline 的格式项触发 E539）。只作用于文本段，不影响 lualine 注入的 %#/#/%z 等标记。
--- @param s string
--- @return string
local function _stl_escape(s)
  return (s or ""):gsub("%%", "%%%%")
end

--- 模型 id 短名（去掉该省略的 '...'，避免状态栏成片截断显得杂乱）
--- @param model string
--- @return string
local function _fmt_model(model)
  if not model or model == "" then return "auto" end
  -- 取最后一个 '/' 或 ':' 之后的短名
  return model:match("[^/:]+$") or model
end

--- 计算段字符串
--- @param info table get_info() 结果
--- @param part string
--- @return string|nil
local function _build_part(info, part)
  if part == "mode" then
    local label = info.mode == "auto" and "AUTO" or (info.mode == "plan" and "PLAN" or "CHAT")
    return "[" .. label .. "]"
  elseif part == "model" then
    return _fmt_model(info.model)
  elseif part == "usage" then
    if not info.usage then return nil end
    -- 优先展示最近一次请求的 API 真实用量（当前上下文规模），无则回退累计
    local p = info.usage.last_prompt or info.usage.prompt
    local c = info.usage.last_completion or info.usage.completion
    return "↑" .. _fmt_tokens(p) .. " ↓" .. _fmt_tokens(c)
  elseif part == "cache" then
    if not info.usage or (not info.usage.requests or info.usage.requests == 0) then return nil end
    -- 只显示命中率，简洁不堆 token 数
    return "缓存命中" .. _fmt_pct(info.usage.cache_ratio or 0)
  elseif part == "capacity" then
    if not info.capacity or not info.capacity.total or info.capacity.total <= 0 then return nil end
    if info.capacity.level == "over" then return "上下文超限" end
    -- 剩余容量 = 1 - 已用比例
    return "剩余容量" .. _fmt_pct(math.max(0, 1 - info.capacity.pct))
  elseif part == "state" then
    return info.state or "idle"
  elseif part == "pending" then
    -- agent 正忙时暂存/待发消息数：>0 才显示徽标（0 时返回 nil，不渲染）
    if not info.pending or info.pending <= 0 then return nil end
    return "待发" .. info.pending
  elseif part == "display" then
    return info.display and ("[" .. info.display .. "]") or nil
  end
  return nil
end

--- 触发状态栏刷新（lualine 每次渲染会重新调用 component）
local function _refresh()
  pcall(vim.cmd, "redrawstatus")
end

--- 是否启用状态栏输出（config ui.statusline.enabled，缺省启用）
--- @return boolean
local function _enabled()
  return config_store.get("ui.statusline.enabled") ~= false
end

--- 是否启用第二行（winbar）展示（仅主消息窗口生效）
--- @return boolean
local function _winbar_enabled()
  local winbar = config_store.get("ui.statusline.winbar")
  return winbar ~= false -- 缺省启用
end

-- ========== 公开 API ==========

--- 是否启用状态栏输出（config ui.statusline.enabled，缺省启用）
-- （_enabled 已在私有区定义）

--- 懒加载地把 'neoai' 注入到 nvim-lualine 的 extensions（幂等）。
--- lualine 在 setup() 时才解析扩展，因此这里用「当前已生效配置 + 追加扩展」重新 setup，
--- 实测安全（get_config() 返回深拷贝，不污染 lualine 内部状态）。
--- @return boolean 是否已注入
function M.ensure_lualine_extension()
  if state.lualine_injected then return true end
  local ok, lualine = pcall(require, "lualine")
  if not ok or not lualine or not lualine.get_config or not lualine.setup then return false end
  local cfg = lualine.get_config()
  if not cfg then return false end
  local exts = cfg.extensions or {}
  for _, x in ipairs(exts) do
    if x == "neoai" then
      state.lualine_injected = true
      return true
    end
  end
  table.insert(exts, "neoai")
  -- 若用户未配置 winbar 且启用第二行展示，塞一个空占位以激活 lualine 的 winbar 机制，
  -- 供扩展在聊天主窗口渲染第二行；对其它窗口其内容为空，不产生额外横条。
  if _winbar_enabled() and not (cfg.winbar and next(cfg.winbar) ~= nil) then
    cfg.winbar = { lualine_c = { function() return "" end } }
  end
  local ok2 = pcall(function() lualine.setup(cfg) end)
  if ok2 then state.lualine_injected = true end
  return ok2
end

--- 配置格式化选项（可选）
--- @param opts table|nil { parts?, separator? }
--- @return table 当前选项副本
function M.setup(opts)
  state.opts = opts or {}
  return _opts()
end

--- 计算某 Agent 的上下文容量信息。
--- used 优先取 API 最近一次请求回传的输入 token（真实上下文规模，含系统提示/工具/缓存命中），
--- 无 API 用量时回退本地完整请求估算；total 为有效窗口（用户显式配置 → 模型能力表 → 兜底）。
--- @param agent table
--- @return table|nil { used, total, pct, level, warn_ratio, source }
function M.capacity_for(agent)
  if not agent then return nil end
  local provider_name = (agent.config and agent.config.provider)
    or config_store.get("ai.default_provider")
  local capabilities = require("NeoAI.core.model.capabilities")
  local caps = capabilities.resolve(agent.model, provider_name)
  local used, source = 0, "estimate"
  local ok, u, s = pcall(function()
    return require("NeoAI.core.session.context_builder").used_tokens(agent, {
      chars_per_token = caps.chars_per_token,
    })
  end)
  if ok then used, source = tonumber(u) or 0, s or "estimate" end
  local total = capabilities.resolve_window(
    config_store.get("ai.context_cache.context_window"), agent.model, provider_name)
  local warn_ratio = tonumber(config_store.get("ai.context_cache.warn_ratio")) or 0.85
  local pct = total > 0 and (used / total) or 0
  local level = "ok"
  if pct >= 1 then
    level = "over"
  elseif pct >= warn_ratio then
    level = "warn"
  end
  return {
    used = used,
    total = total,
    pct = pct,
    level = level,
    warn_ratio = warn_ratio,
    source = source,
  }
end

--- 当前 Agent 的容量告警级别（供状态栏动态配色）
--- @return string "ok" | "warn" | "over"
function M.capacity_level()
  local chat_service = require("NeoAI.services.chat_service")
  local agent = chat_service.get_current_agent()
  local cap = agent and M.capacity_for(agent)
  return (cap and cap.level) or "ok"
end

--- 检查上下文压力并按级别提示一次（同一 Agent 同级别去重，回落到 ok 后重置）。
--- @param agent table
--- @return string|nil level
function M.check_pressure(agent)
  if not agent then return nil end
  local cap = M.capacity_for(agent)
  if not cap then return nil end
  local prev = agent._context_pressure
  agent._context_pressure = cap.level
  if cap.level == "ok" or cap.level == prev then return cap.level end
  local used, total = _fmt_tokens(cap.used), _fmt_tokens(cap.total)
  if cap.level == "over" then
    vim.notify(
      ("[NeoAI] 上下文已超限（%s / %s，%s）。下一轮将自动压缩；若仍不足请精简历史或改用更大窗口的模型。"):format(
        used, total, _fmt_pct(cap.pct)),
      vim.log.levels.ERROR)
  else
    vim.notify(
      ("[NeoAI] 上下文接近上限（%s / %s，%s）。"):format(used, total, _fmt_pct(cap.pct)),
      vim.log.levels.WARN)
  end
  return cap.level
end

--- 获取当前 Agent 的状态信息（不格式化，供自定义组件使用）
--- @return table { available, mode, display, model, state, usage, capacity }
function M.get_info()
  local chat_service = require("NeoAI.services.chat_service")
  local agent = chat_service.get_current_agent()
  local info = {
    available = agent ~= nil,
    mode = chat_service.get_mode() or "chat",
    display = nil,
    model = agent and agent.model or config_store.get("ai.default_model") or "auto",
    state = agent and agent.state or "idle",
    usage = nil,
    capacity = nil,
    pending = nil,
  }
  -- 当前 agent 正忙时暂存的待发消息数（无 agent 或队列为空则缺省，徽标不渲染）
  info.pending = chat_service.pending_count()
  if agent then
    local u = agent.usage or {}
    info.usage = {
      prompt = u.prompt or 0,
      completion = u.completion or 0,
      last_prompt = u.last_prompt,
      last_completion = u.last_completion,
      requests = u.requests or 0,
      cache_read = u.cache_read or 0,
      cache_write = u.cache_write or 0,
      cache_miss = u.cache_miss or 0,
      cache_ratio = u.cache_ratio or 0,
    }
    -- 上下文容量：优先 API 最近一次请求的真实输入 token，缺失回退完整请求估算
    info.capacity = M.capacity_for(agent)
  end
  local display_modes = require("NeoAI.ui.components.display_modes")
  local disp = display_modes.get_current()
  info.display = disp and (disp.label or disp.name) or nil
  return info
end

--- 生成 lualine 组件字符串
--- @return string
function M.component()
  if not _enabled() then return "" end
  local opts = _opts()
  local info = M.get_info()
  if not info.available and info.mode == "chat" then
    -- 无激活 Agent 时不给状态栏造成干扰，仅当模式非默认才显示模式徽标
    return ""
  end
  local parts = {}
  for _, part in ipairs(opts.parts or {}) do
    local text = _build_part(info, part)
    if text and text ~= "" then parts[#parts + 1] = text end
  end
  return _stl_escape(table.concat(parts, opts.separator or " "))
end

--- 单个段的字符串（供扩展按 section 布局）
--- @param part string mode|model|usage|cache|capacity
--- @return string
function M.segment(part)
  if not _enabled() then return "" end
  return _stl_escape(_build_part(M.get_info(), part) or "")
end

--- 是否存在某个点（供手动组件判断是否渲染）
--- @param part string
--- @return boolean
function M.has(part)
  return _build_part(M.get_info(), part) ~= nil
end

--- 各段对应的 nvim 高亮组（config ui.statusline.colors 可覆盖）
--- @return table part -> hl
function M.colors()
  local cfg = vim.deepcopy(DEFAULTS.colors or {})
  local overrides = config_store.get("ui.statusline.colors")
  if overrides then
    for k, v in pairs(overrides) do cfg[k] = v end
  end
  return cfg
end

--- 是否启用第二行（winbar）
--- @return boolean
function M.winbar_enabled()
  return _enabled() and _winbar_enabled()
end

--- 订阅事件，事件驱动状态栏刷新（幂等）
--- @return function 取消订阅
function M.watch()
  if state.watching then return end
  state.watching = true
  local subscribed = {
    events.GENERATION_STARTED, events.GENERATION_COMPLETED,
    events.GENERATION_ERROR, events.GENERATION_CANCELLED,
    events.STREAM_COMPLETED, events.AGENT_STATE_CHANGED,
    events.AGENT_ABORTED, events.MODEL_SWITCHED,
    events.SESSION_LOADED, events.MESSAGE_ADDED,
    events.MESSAGE_QUEUED, events.MESSAGE_SENT,
    events.AUTO_MODE_CHANGED, events.PLAN_MODE_CHANGED,
    events.DISPLAY_MODE_CHANGED, events.TODO_UPDATED,
  }
  for _, ev in ipairs(subscribed) do
    state.unsubs[#state.unsubs + 1] = event_bus.on(ev, _refresh)
  end
end

--- 刷新状态栏（供扩展 init / 手动调用）
function M.refresh()
  _refresh()
end

return M
