--- 沙箱待审审批界面
--- @module 'NeoAI.ui.components.sandbox_review'
--- 列出待审变更单元，按文件路径级别高亮：
---   工作区文件=绿色 / 用户目录=黄色 / 系统路径=红色；「待审」状态标签按安全等级着色
---   （L0 灰 / L1 黄 / L2 橙 / L3 红）。
---   风险徽标配色：L0 灰 / L1·L2 黄 / L3 红（仅 L3 用红色危险高亮）。
--- 审批单位为单个文件：<CR> 仅应用光标所在文件 / d 仅拒绝该文件（其余文件保留待审）。
--- 「已应用」区默认整体折叠（区标题一级 / 条目头行二级，za/zo 逐级展开），
--- 刷新后重新收起；任何应用成功后**整个审批窗全部折叠**（fold_all），待审区与越界留痕区不折叠。
--- 沙箱广播事件驱动自动刷新（窗口打开期间订阅，关闭时退订）；q 关闭。
--- 经 kernel.services.use 获取 sandbox 服务，缺失时降级提示。

local services = require("NeoAI.kernel.services")
local fs = require("NeoAI.utils.fs")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")
local geometry = require("NeoAI.ui.geometry")
local stringx = require("NeoAI.utils.stringx")

local M = {}

-- ========== 沙箱服务门面访问器 ==========
-- ui/ 层唯一入口：全部沙箱能力经 `services.use("services.sandbox")` 获取，
-- 不直接 require 沙箱内部模块（保持依赖单向 ui → services）。

--- 取沙箱服务（未就绪返回 nil，调用方降级）
local function _sb() return services.use("services.sandbox") end

--- AI 审计结论判定；服务缺失返回 nil
local function _audit_verdict(notes)
  local sb = _sb()
  return sb and sb.audit_verdict(notes)
end

--- 风险徽标文本；服务缺失返回 ""
local function _risk_badge(level)
  local sb = _sb()
  return (sb and sb.risk_badge(level)) or ""
end

--- 按文件聚合留痕；服务缺失返回 {}
local function _group_traces(entries)
  local sb = _sb()
  return (sb and sb.group_traces(entries)) or {}
end

--- 按命令聚合留痕；服务缺失返回 {}
local function _group_traces_by_command(entries)
  local sb = _sb()
  return (sb and sb.group_traces_by_command(entries)) or {}
end

--- 审批中心页定义；服务缺失返回 {}
local function _hub_pages()
  local sb = _sb()
  return (sb and sb.hub_pages()) or {}
end

--- 审批中心某页待处理数量；服务缺失返回 0
local function _hub_pending(page)
  local sb = _sb()
  return (sb and sb.hub_pending_count(page)) or 0
end

--- 审批中心某页条目；服务缺失返回 {}
local function _hub_list(page)
  local sb = _sb()
  return (sb and sb.hub_list(page)) or {}
end

--- 裁决一个审批条目
local function _hub_resolve(id, value)
  local sb = _sb()
  return sb and sb.hub_resolve(id, value)
end

--- 读取一个审批条目
local function _hub_get(id)
  local sb = _sb()
  return sb and sb.hub_get(id)
end

-- 审批页标签缓存（沙箱服务就绪后惰性填充；见 _ensure_page_labels）
local PAGE_LABEL = {}
local _page_labels_ready = false
local function _ensure_page_labels()
  if _page_labels_ready then return end
  local sb = _sb()
  if not sb then return end
  local pages = sb.hub_pages() or {}
  if #pages == 0 then return end
  for _, p in ipairs(pages) do PAGE_LABEL[p.id] = p.label end
  _page_labels_ready = true
end

--- 审批页标签（惰性填充缓存）
local function _page_label(page)
  _ensure_page_labels()
  return PAGE_LABEL[page]
end

-- ========== 私有常量 ==========

-- 路径级别 -> 高亮组
local LEVEL_HL = {
  workspace = "NeoAISandboxReviewWorkspace",
  user = "NeoAISandboxReviewUser",
  system = "NeoAISandboxReviewSystem",
  pending = "NeoAISandboxReviewPending",
  pending0 = "NeoAISandboxReviewPending0",
  pending1 = "NeoAISandboxReviewPending1",
  pending2 = "NeoAISandboxReviewPending2",
  pending3 = "NeoAISandboxReviewPending3",
  secret = "NeoAISandboxReviewSecret",
  risk0 = "NeoAISandboxReviewRisk0",
  risk1 = "NeoAISandboxReviewRisk1",
  risk2 = "NeoAISandboxReviewRisk2",
  risk3 = "NeoAISandboxReviewRisk3",
  ai = "NeoAISandboxReviewAi",
  note = "NeoAISandboxReviewNote",
  verdict_safe = "NeoAISandboxReviewVerdictSafe",
  verdict_unsafe = "NeoAISandboxReviewVerdictUnsafe",
}

-- 图例行按级别分段着色（工作区绿 / 用户目录黄 / 系统红；风险徽标 L0 灰 / L1·L2 黄 / L3 红；
-- 密钥操作红），与下方条目高亮一致，不再用「(绿)」等纯文字说明。
local LEGEND_SEGMENTS = {
  { "级别：" },
  { "工作区", "workspace" },
  { " " },
  { "用户目录", "user" },
  { " " },
  { "系统", "system" },
  { "  风险：" },
  { "L0低危", "risk0" },
  { "/" },
  { "L1中危", "risk1" },
  { "/" },
  { "L2高危", "risk2" },
  { "/" },
  { "L3严重", "risk3" },
  { "  " },
  { "⚠密钥操作", "secret" },
  { "   |   <CR> 头行=整包应用 / 文件行=应用该文件   A 一键同意全部工作区修改   d 拒绝该文件   i 预览修改diff/越界详情   u 撤销/重做保存·恢复已拒绝   a AI审计   q 关闭" },
}

local LEGEND, LEGEND_MARKS = (function()
  local s, marks, col = "", {}, 0
  for _, seg in ipairs(LEGEND_SEGMENTS) do
    local text, level = seg[1], seg[2]
    if level then marks[#marks + 1] = { start_col = col, end_col = col + #text, level = level } end
    s, col = s .. text, col + #text
  end
  return s, marks
end)()

-- L3 后果警告高亮组（diff 预览顶部）
local L3_WARN_HL = "NeoAISandboxReviewL3Warning"
-- 二次确认弹窗的按键提示高亮组
local HINT_HL = "NeoAISandboxReviewConfirmHint"

-- ========== 私有状态 ==========

local state = {
  win_id = nil,
  buf = nil,
  ns = nil,
  page = "files", -- 当前页面（多级页面：files/behavior/resource/network/anomaly）
  line_to_target = {}, -- 行号 -> { change_set_id, path? }
  line_to_hub = {}, -- 行号 -> 审批分流中心条目 id（阻塞类页面）
  line_to_trace = {}, -- 行号 -> 越界留痕路径（`i` 查看详情，非审批目标）
  line_to_cmd = {}, -- 行号 -> { command = string|nil } 越界命令（`i` 查看该命令涉及的文件）
  fold_levels = {}, -- 行号 -> 折叠级别（仅「已应用」区 > 0）：区标题=1，条目及其文件行=2
  last_cursor = nil, -- { line, col } 关闭时记录，重开时恢复
  --- @type table<string, any>|nil 关闭时光标所在条目（优先恢复）
  last_target = nil,
  geom = nil, -- { col, row, width, height } 窗口几何，重开时恢复
  suspended = false, -- 是否因查看 diff 临时关闭（关闭 diff 后自动重开审批窗）
  diff = nil, -- { win, buf, ns, mode, warn_start, warn_end, diff_start, width } 当前 diff 预览窗口
  pending_l3 = nil, -- { change_set_id, path } L3 二次确认中待应用的条目
  l3_seq = 0, -- L3 警告生成序号：关闭/重开 diff 后作废过期结果
  audit = nil, -- { text?, pending?, error? } AI 审计结论（显示在窗口顶部）
  audit_seq = 0, -- AI 审计请求序号：关闭/重开审批窗后作废过期结果
  audit_sig = nil, -- 已完成审计对应的待审集合签名（集合变化时自动重审）
  applying_all = false, -- 一键同意批量应用进行中（防重入；逐项让出主循环）
  unsubs = {}, -- 窗口打开期间的沙箱事件订阅取消函数（关闭时清理）
  refresh_pending = false, -- 已排队一次自动刷新（同一 tick 内的事件合并）
  unwait = nil, -- services.wait 取消句柄（hub UI 延迟注册）
}

-- 广播自动刷新订阅的沙箱事件：待审/已应用/越界留痕/主机操作任一变化都会重绘审批窗。
local WATCH_EVENTS = {
  events.SANDBOX_REVIEW_ENQUEUED, events.SANDBOX_REVIEW_APPROVED,
  events.SANDBOX_REVIEW_REJECTED, events.SANDBOX_REVIEW_SUPERSEDED,
  events.SANDBOX_APPLIED, events.SANDBOX_COMMITTED,
  events.SANDBOX_DISCARDED, events.SANDBOX_REVERTED,
  events.SANDBOX_OUTSIDE_ACCESS,
  events.SANDBOX_HOST_OP_ENQUEUED, events.SANDBOX_HOST_OP_APPLIED,
  events.SANDBOX_HOST_OP_REJECTED,
  events.SANDBOX_APPROVAL_CHANGED,
}

-- 安全级别 -> 中文风险档（高危 / 中危 / 低危）
local RISK_LABEL = { [0] = "低危", [1] = "中危", [2] = "高危", [3] = "高危" }
--- 安全级别对应的风险档名称
--- @param level number|nil
--- @return string
local function _risk_label(level)
  return RISK_LABEL[tonumber(level) or 0] or "低危"
end

-- ========== 折叠回调（预览窗） ==========
-- 「已应用」区默认整体收起（区标题一级），展开后每条仍各自收起（条目头行二级）；
-- 待审区/留痕区不登记级别（=0）故不折叠。实例化为模块级全局函数而非
-- v:lua.require'...'：后者在带 UI 会话里求值可能失败（参见 chat_view 注释）。
local function _fold_expr()
  return tostring(state.fold_levels[vim.v.lnum] or 0)
end

local function _fold_text()
  local start = vim.v.foldstart
  local count = vim.v.foldend - start + 1
  local first = vim.fn.getline(start) or ""
  return string.format("  ▸ %s  (%d 行)", first, count)
end

-- ========== 私有函数 ==========

--- 定义高亮组（default=true，用户可覆盖）
local function _ensure_hl()
  vim.api.nvim_set_hl(0, LEVEL_HL.workspace, { default = true, fg = "#98c379", bold = true })
  vim.api.nvim_set_hl(0, LEVEL_HL.user, { default = true, fg = "#e5c07b", bold = true })
  vim.api.nvim_set_hl(0, LEVEL_HL.system, { default = true, fg = "#e06c75", bold = true })
  vim.api.nvim_set_hl(0, LEVEL_HL.pending, { default = true, fg = "#e5c07b", bold = true })
  -- 「待审」标签按安全等级着不同色（L0 灰 / L1 黄 / L2 橙 / L3 红）
  vim.api.nvim_set_hl(0, LEVEL_HL.pending0, { default = true, fg = "#7f8c8d", bold = true })
  vim.api.nvim_set_hl(0, LEVEL_HL.pending1, { default = true, fg = "#e5c07b", bold = true })
  vim.api.nvim_set_hl(0, LEVEL_HL.pending2, { default = true, fg = "#d19a66", bold = true })
  vim.api.nvim_set_hl(0, LEVEL_HL.pending3, { default = true, fg = "#ff5555", bold = true, underline = true })
  vim.api.nvim_set_hl(0, LEVEL_HL.secret, { default = true, fg = "#e06c75", bold = true, underline = true })
  vim.api.nvim_set_hl(0, LEVEL_HL.risk0, { default = true, fg = "#7f8c8d", bold = true })
  vim.api.nvim_set_hl(0, LEVEL_HL.risk1, { default = true, fg = "#e5c07b", bold = true })
  -- L2（高危）用黄色警示，而非红色；仅 L3（严重）保留红色危险高亮。
  vim.api.nvim_set_hl(0, LEVEL_HL.risk2, { default = true, fg = "#e5c07b", bold = true })
  vim.api.nvim_set_hl(0, LEVEL_HL.risk3, { default = true, fg = "#ff5555", bold = true, underline = true })
  vim.api.nvim_set_hl(0, LEVEL_HL.ai, { default = true, fg = "#56b6c2", bold = true })
  vim.api.nvim_set_hl(0, LEVEL_HL.note, { default = true, fg = "#7f8c8d" })
  vim.api.nvim_set_hl(0, LEVEL_HL.verdict_safe, { default = true, fg = "#98c379", bold = true })
  vim.api.nvim_set_hl(0, LEVEL_HL.verdict_unsafe, { default = true, fg = "#ff5555", bold = true })
  vim.api.nvim_set_hl(0, L3_WARN_HL, { default = true, fg = "#ff5555", bold = true })
  vim.api.nvim_set_hl(0, HINT_HL, { default = true, fg = "#56b6c2", bold = true })
end

--- 合并同一 tick 内的多次沙箱事件为一次重绘（批量应用时逐事件重绘会卡界面）。
local function _schedule_refresh()
  if state.refresh_pending then return end
  state.refresh_pending = true
  -- 防抖：捕获/冻结可在一瞬间产生大量沙箱事件；同一窗口内合并为一次重绘，
  -- 避免待审数千文件时每个事件都触发一次全量 build_lines + 写 buffer。
  local ms = tonumber(require("NeoAI.kernel.config_store").get(
    "tools.sandbox.review.refresh_debounce_ms")) or 80
  local function run()
    state.refresh_pending = false
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
      -- 一次重绘异常不应永久停止后续刷新（refresh_pending 已复位，下次事件可再排）。
      local ok, err = pcall(M.refresh)
      if not ok then
        require("NeoAI.kernel.logger").warn("[sandbox_review] 刷新失败: %s", tostring(err))
      end
    end
  end
  if ms > 0 then vim.defer_fn(run, ms) else vim.schedule(run) end
end

--- 窗口打开期间订阅沙箱广播事件（幂等）；事件驱动自动刷新，无需手动 `r`。
local function _watch()
  if #state.unsubs > 0 then return end
  for _, ev in ipairs(WATCH_EVENTS) do
    state.unsubs[#state.unsubs + 1] = event_bus.on(ev, _schedule_refresh)
  end
  -- 焦点切回 NeoAI 界面时强制刷新：保证窗口内容与队列同步，避免切走期间事件丢失/重绘异常
  -- 导致展示陈旧或部分状态（表现为「切回来只剩一条」）。
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.UI_FOCUS_CHANGED, function(payload)
    if payload and payload.focused == true then _schedule_refresh() end
  end)
end

--- 取消沙箱事件订阅（窗口关闭/重置时调用）。
local function _unwatch()
  for _, u in ipairs(state.unsubs) do
    if u then pcall(u) end
  end
  state.unsubs = {}
end

--- 安全级别 -> 高亮键
--- @param level number|nil
--- @return string
local function _risk_hl(level)
  level = tonumber(level) or 0
  if level >= 3 then return "risk3" end
  if level == 2 then return "risk2" end
  if level == 1 then return "risk1" end
  return "risk0"
end

--- 「待审」两字的高亮：按条目安全等级着色（L0 灰 / L1 黄 / L2 橙 / L3 红）；
--- 无安全等级信息时退回默认黄色 pending。
--- @param item table|nil
--- @return string
local function _pending_hl(item)
  local lv = item and tonumber(item.risk_level)
  if lv == nil then return "pending" end
  if lv >= 3 then return "pending3" end
  if lv == 2 then return "pending2" end
  if lv == 1 then return "pending1" end
  return "pending0"
end

--- 将任意值压成单行（nvim_buf_set_lines 不接受含换行的元素）
--- @param s any
--- @return string
local function _one_line(s)
  if s == nil then return "" end
  return (tostring(s):gsub("\r\n", "⏎"):gsub("[\r\n]", "⏎"))
end

--- 合并重复风险原因并计数：包安装等会对每个写入路径重复同一原因（如数千个
--- SYSTEM_PATH_WRITE），展示为 `SYSTEM_PATH_WRITE×2797`（保留首次出现顺序）。
--- @param list table|nil
--- @return table 形如 { "PACKAGE_INSTALL", "SYSTEM_PATH_WRITE×2797" }
local function _merge_reasons(list)
  local order, count = {}, {}
  for _, r in ipairs(list or {}) do
    local key = _one_line(r)
    if key ~= "" then
      if count[key] == nil then order[#order + 1] = key; count[key] = 0 end
      count[key] = count[key] + 1
    end
  end
  local out = {}
  for _, key in ipairs(order) do
    out[#out + 1] = count[key] > 1 and (key .. "×" .. count[key]) or key
  end
  return out
end

--- 规范化绝对路径（去尾部斜杠）
--- @param p string
--- @return string
local function _norm(p)
  return fs.canonical(p)
end

--- cwd/home 的规范形式缓存：build_lines 逐文件判级时，此前每次都对 cwd/home 各做一次
--- fs.canonical（含 fnamemodify+resolve 的 vim.fn 调用）；待审文件数千时是主线程热点。
--- 键为原始字符串，值随 cwd/$HOME 变化自然失效。
local _base_canon = {}
local function _canon_base(raw)
  local c = _base_canon[raw]
  if c then return c end
  c = fs.canonical(raw)
  _base_canon[raw] = c
  return c
end

--- path 是否位于 base 之下（含相等）
--- @param path string
--- @param base string
--- @return boolean
local function _under(path, base)
  if base == "" then return false end
  return path == base or path:sub(1, #base + 1) == base .. "/"
end

--- 判断文件路径级别
--- @param path string
--- @param ctx table|nil { cwd?, home? } 预计算的规范 cwd/home（build_lines 批量传入以复用）
--- @return string "workspace" | "user" | "system"
function M.level_of(path, ctx)
  if type(path) ~= "string" or path == "" then return "system" end
  local abs = _norm(path)
  local cwd = (ctx and ctx.cwd) or _canon_base(vim.fn.getcwd())
  if _under(abs, cwd) then return "workspace" end
  local home = (ctx and ctx.home) or _canon_base(vim.fn.expand("~"))
  if home ~= "" and _under(abs, home) then return "user" end
  return "system"
end

--- 构建展示行与高亮标记（纯函数，测试用）
--- @param items table list_reviews 结果数组
--- @param traces table|nil 越界访问留痕数组（sandbox.list_traces）
--- @param audit table|nil AI 审计 { pending?, error?, fallback?, notes? = { [路径或命令]=说明 } }
--- @param saved table|nil 已保存/已撤销（含快照）的变更单元数组（sandbox.list_saved）
--- @param rejected table|nil 可恢复的已拒绝变更单元数组（sandbox.list_rejected）
--- @return table { lines, marks, line_to_target, line_to_trace, fold_levels }
function M.build_lines(items, traces, audit, saved, rejected)
  local lines = {}
  local marks = {}
  local line_to_target = {}
  local line_to_trace = {} -- 行号 -> 越界留痕路径（`i` 查看详情；非审批目标）
  -- 折叠级别（稀疏表：仅「已应用」区 > 0）：区标题=1（整区收起），条目头行及其文件行=2
  -- （展开整区后条目仍各自收起）。待审区/留痕区不登记，保持不折叠。
  local fold_levels = {}
  -- 本次渲染复用一次 cwd/home 规范形式，避免逐文件重复 fs.canonical。
  local lvl_ctx = { cwd = _canon_base(vim.fn.getcwd()), home = _canon_base(vim.fn.expand("~")) }
  lines[#lines + 1] = LEGEND
  for _, m in ipairs(LEGEND_MARKS) do
    marks[#marks + 1] = { line = #lines, start_col = m.start_col, end_col = m.end_col, level = m.level }
  end
  lines[#lines + 1] = ""
  -- AI 审计状态（生成中 / 结论 / 失败 / 兜底说明）：结论先说安全/不安全；正式说明在各自文件行下方。
  if audit and (audit.pending or audit.notes
      or (audit.error and audit.error ~= "") or (audit.fallback and audit.fallback ~= "")) then
    local status, level = nil, "note"
    if audit.pending then
      status = "🤖 AI 审计生成中…"
    elseif audit.notes then
      local verdict = _audit_verdict(audit.notes)
      if verdict == "unsafe" then
        status, level = "🤖 AI 审计结论：⚠ 不安全 — 存在不安全变更，请逐条确认", "verdict_unsafe"
      elseif verdict == "safe" then
        status, level = "🤖 AI 审计结论：安全 — 未发现不安全变更", "verdict_safe"
      else
        status = "🤖 AI 审计结论：未给出明确安全/不安全结论"
      end
    elseif audit.error and audit.error ~= "" then
      status = "🤖 AI 审计失败：" .. _one_line(audit.error)
    else
      status = "🤖 AI 审计：" .. _one_line(audit.fallback)
    end
    lines[#lines + 1] = status
    marks[#marks + 1] = { line = #lines, start_col = 0, end_col = #status, level = level }
    lines[#lines + 1] = ""
  end
  -- 按路径/命令查审计说明（容忍模型省略前缀、带 [action] 前缀或命令 `$ ` 前缀）
  local function _norm_key(s)
    s = stringx.trim(tostring(s or ""))
    s = s:gsub("^%[.-%]%s*", "") -- 去掉 [action] 前缀
    s = s:gsub("^%$%s*", "") -- 去掉命令 `$ ` 前缀
    s = s:gsub("^主机操作命令%s*[:：]%s*", "")
    return s
  end
  -- 预计算索引：规范化键 -> 说明；以及各分隔处后缀 -> 说明（模型省略前缀时按后缀命中）。
  -- 此前每条文件/命令都遍历全部 notes，待审与说明各数千时退化为 O(n²) 卡主线程。
  local notes_norm, notes_suffix
  if audit and audit.notes then
    notes_norm, notes_suffix = {}, {}
    for k, v in pairs(audit.notes) do
      local kk = _norm_key(k)
      if kk ~= "" then
        if notes_norm[kk] == nil then notes_norm[kk] = v end
        local start = 1
        while true do
          local seg = kk:sub(start)
          if notes_suffix[seg] == nil then notes_suffix[seg] = v end
          local slash = kk:find("/", start, true)
          if not slash then break end
          start = slash + 1
        end
      end
    end
  end
  local function _note_for(key)
    local notes = audit and audit.notes
    if not notes or not key or key == "" then return nil end
    if notes[key] then return notes[key] end
    local nk = _norm_key(key)
    if nk == "" then return nil end
    if notes_norm and notes_norm[nk] then return notes_norm[nk] end
    -- note 键是 nk 的后缀（模型带前缀）
    if notes_suffix and notes_suffix[nk] then return notes_suffix[nk] end
    -- nk 是 note 键的后缀（模型省略前缀）：沿分隔符逐级尝试
    if notes_norm then
      local start = 1
      while true do
        local slash = nk:find("/", start, true)
        if not slash then break end
        local seg = nk:sub(slash + 1)
        if seg ~= "" and notes_norm[seg] then return notes_norm[seg] end
        start = slash + 1
      end
    end
    return nil
  end
  --- 在当前位置追加一条暗灰审计说明。AI 审计已完成但该条目缺说明时，标注「请人工确认」，
  --- 确保**每条都要审**：不漏任何文件 / 主机命令。
  local function _append_note(key)
    local note = _note_for(key)
    local missing = false
    if not note or note == "" then
      if audit and audit.notes then
        note = "（AI 未给出说明，请人工确认）"
        missing = true
      else
        return
      end
    end
    local text = "    " .. _one_line(note)
    local ln = #lines + 1
    lines[#lines + 1] = text
    marks[#marks + 1] = { line = ln, start_col = 4, end_col = 4 + #note, level = missing and "verdict_unsafe" or "note" }
  end
  -- 每单元最多渲染的文件行数（0 = 不限）：包安装/git 操作可达数千文件，逐行渲染（字符串 +
  -- 高亮 + 行→目标映射）在开窗/每次刷新时都很慢；超限折叠为一行汇总。
  local max_files = tonumber(require("NeoAI.kernel.config_store").get(
    "tools.sandbox.review.max_display_files"))
  if max_files == nil then max_files = 200 end
  --- 追加「其余 M 个文件」汇总行，映射到整单元审批目标（与头行一致）。
  local function _append_rest(rest, target, indent)
    local text = ("%s… 其余 %d 个文件（已折叠；<CR> 应用整单元 / d 拒绝整单元）"):format(
      indent or "  ", rest)
    local ln = #lines + 1
    lines[#lines + 1] = text
    marks[#marks + 1] = { line = ln, start_col = 0, end_col = #text, level = "system" }
    line_to_target[ln] = target
    return ln
  end
  -- 审批分区：未应用（待审）在前，已应用（含快照，可撤销）在后，边界醒目。
  if items and #items > 0 then
    local head = ("── 未应用（待审 %d 个变更单元）──"):format(#items)
    lines[#lines + 1] = head
    lines[#lines + 1] = ""
  end
  for _, item in ipairs(items or {}) do
    local tier = item.privilege_tier or 0
    local badge = tier > 0 and string.format(" [T%d]", tier) or ""
    local risk_badge = ""
    if item.risk_level ~= nil then
      risk_badge = string.format(" [%s]%s", _risk_badge(item.risk_level), _risk_label(item.risk_level))
    end
    -- 主机操作提案（T2）：展示命令，整条审批；审批后主机 replay。
    if item.kind == "host_op" then
      local cmd = _one_line((item.write_set and item.write_set[1]) or "?")
      local base = _one_line(string.format("[%s] %s%s%s（主机操作）  ", item.change_set_id, item.tool or "?", badge, risk_badge))
      local hln = #lines + 1
      lines[#lines + 1] = base .. "待审"
      marks[#marks + 1] = { line = hln, start_col = #base, end_col = #base + #"待审", level = _pending_hl(item) }
      if risk_badge ~= "" then
        local rb = base:find("%[L%d%]", 1)
        if rb then marks[#marks + 1] = { line = hln, start_col = rb - 1, end_col = rb + 2, level = _risk_hl(item.risk_level) } end
      end
      -- 头行同样作为整条审批入口（<CR> 应用 / d 拒绝 / i 预览命令），与命令行的目标一致。
      line_to_target[hln] = { change_set_id = item.change_set_id, host_op = true }
      local text = "  $ " .. cmd
      local ln = #lines + 1
      lines[#lines + 1] = text
      marks[#marks + 1] = { line = ln, start_col = 2, end_col = 2 + #cmd, level = "system" }
      line_to_target[ln] = { change_set_id = item.change_set_id, host_op = true }
      _append_note(cmd)
      lines[#lines + 1] = ""
    else
    -- files 缺失（旧持久化记录）时回退 write_set
    local files = item.files
    if not files or #files == 0 then
      files = {}
      for _, p in ipairs(item.write_set or {}) do files[#files + 1] = { path = p } end
    end
    -- 部分取代：被更新候选覆盖的路径归新单元所有，不再展示/审批（否则会显示已被取代的旧版本）。
    local sup = type(item.superseded_paths) == "table" and item.superseded_paths or nil
    if sup then
      local kept = {}
      for _, f in ipairs(files) do
        local p = type(f) == "table" and f.path or f
        if not sup[p] then kept[#kept + 1] = f end
      end
      files = kept
    end
    -- 包安装：标注管理器与包名（按安装命令合并为一个审批单元）。
    local pkg = ""
    if item.package then
      local mgr = item.package_manager
      local names = item.package_names
      if mgr and type(names) == "table" and #names > 0 then
        pkg = string.format("包安装 %s: %s，", mgr, _one_line(table.concat(names, ", ")))
      elseif mgr then
        pkg = string.format("包安装 %s，", mgr)
      else
        pkg = "包安装，"
      end
      if item.package_sensitive then
        pkg = pkg .. "⚠ 涉及软件源/密钥，"
      end
    end
    -- git 操作：一次涉及多个文件（工作区 + `.git` 对象/指针），必须整组通过/丢弃（原子）。
    local git_op = item.atomic_group == "git"
    local group_desc = git_op
      and string.format("（git 操作 · %d 个文件 · 原子整组）", #files)
      or string.format("（%s%d 个文件）", pkg, #files)
    local base = _one_line(string.format("[%s] %s%s%s%s  ", item.change_set_id, item.tool or "?", badge, risk_badge, group_desc))
    local hln = #lines + 1
    lines[#lines + 1] = base .. "待审"
    -- 「待审」标签按安全等级着色（L0 灰 / L1 黄 / L2 橙 / L3 红）
    marks[#marks + 1] = { line = hln, start_col = #base, end_col = #base + #"待审", level = _pending_hl(item) }
    -- 头行 = 整单元审批入口：<CR> 一次应用该变更单元的全部文件
    -- （包安装按安装命令合并，整包一次审批，无需逐文件确认）。
    line_to_target[hln] = { change_set_id = item.change_set_id, whole = true }
    -- 安全级徽标按级别着色
    if risk_badge ~= "" then
      local rb = base:find("%[L%d%]", 1)
      if rb then marks[#marks + 1] = { line = hln, start_col = rb - 1, end_col = rb + 2, level = _risk_hl(item.risk_level) } end
    end
    -- 三方合并冲突标记：应用时检测到外部改动且无法自动合并，未写入真实文件。
    if item.merge_conflict then
      local cp = "  ⚠ 合并冲突（外部改动，未写入真实文件）——按 R 交给 AI 基于最新内容重做"
      lines[#lines + 1] = cp
      marks[#marks + 1] = { line = #lines, start_col = 0, end_col = #cp, level = "system" }
    end
    -- 命令型变更单元（run_command / 包安装等）：展示实际命令，便于用户了解具体操作；
    -- 其后的文件行即该命令影响的文件，按工作区/用户/系统级别高亮。
    if type(item.command) == "string" and item.command ~= "" then
      local cmd_text = _one_line(item.command)
      local cmd_line = "  $ " .. cmd_text
      local cln = #lines + 1
      lines[#lines + 1] = cmd_line
      marks[#marks + 1] = { line = cln, start_col = 4, end_col = 4 + #cmd_text, level = "system" }
    end
    -- 密钥防护警告：该变更涉及被加密映射的密钥（token）或敏感环境变量名，红色醒目提示。
    if item.secret_warning and (item.secret_warning.count or 0) > 0 then
      local sw = item.secret_warning
      local detail = "内容含加密 token，应用时还原"
      local ntok = (sw.tokens and #sw.tokens or 0)
      local nname = (sw.names and #sw.names or 0)
      if ntok == 0 and nname > 0 then
        detail = "涉及密钥环境变量：" .. _one_line(table.concat(sw.names, ", "))
      end
      local warn = string.format("  ⚠ 密钥操作×%d（%s）", sw.count, detail)
      lines[#lines + 1] = warn
      marks[#marks + 1] = { line = #lines, start_col = 0, end_col = #warn, level = "secret" }
    end
    -- 不透明派生：命令/脚本可能加密/变换了密钥，输出无法逐字还原；应用前需人工确认。
    if item.derived_opaque then
      local warn = "  ⚠ 不透明派生密钥流（命令/脚本可能加密变换，无法逐字还原）——请人工确认后再应用"
      lines[#lines + 1] = warn
      marks[#marks + 1] = { line = #lines, start_col = 0, end_col = #warn, level = "secret" }
    end
    -- 安全分级原因（非空时展示，便于理解为何需要审批）
    if item.risk_reasons and #item.risk_reasons > 0 then
      local reason = "  风险: " .. table.concat(_merge_reasons(item.risk_reasons), ", ")
      lines[#lines + 1] = reason
      marks[#marks + 1] = { line = #lines, start_col = 0, end_col = #reason, level = _risk_hl(item.risk_level) }
    end
    -- 头行 = 整单元审批；普通条目下方文件行为单文件审批（可选择性只应用某个文件）。
    -- git 原子组：整组通过/丢弃，文件行同样映射到整组（不可逐文件）。
    if git_op then
      local hint = "  ⚙ 一次 git 操作：整组通过/丢弃（原子，不可逐文件）"
      local gln = #lines + 1
      lines[#lines + 1] = hint
      marks[#marks + 1] = { line = gln, start_col = 0, end_col = #hint, level = "system" }
      line_to_target[gln] = { change_set_id = item.change_set_id, whole = true }
    end

    local shown = 0
    for _, f in ipairs(files) do
      if max_files > 0 and shown >= max_files then break end
      shown = shown + 1
      local path = _one_line(f.path or tostring(f))
      local suffix = f.action and ("  [" .. _one_line(f.action) .. "]") or ""
      local text = "  " .. path .. suffix
      local ln = #lines + 1
      lines[#lines + 1] = text
      marks[#marks + 1] = { line = ln, start_col = 2, end_col = 2 + #path, level = M.level_of(path, lvl_ctx) }
      if git_op then
        line_to_target[ln] = { change_set_id = item.change_set_id, whole = true }
      else
        line_to_target[ln] = { change_set_id = item.change_set_id, path = path }
      end
      _append_note(path)
    end
    if max_files > 0 and #files > shown then
      _append_rest(#files - shown, { change_set_id = item.change_set_id, whole = true })
    end
    -- 头行保持正常显示（审批入口，保留工具/风险/文件数与高亮），其后的密钥警告/风险原因/
    -- git 提示/文件行统一登记为一级折叠，默认收起、`za`/`zo` 展开——即「第一行显示、其余折叠」。
    -- 包安装/git 操作可达上千文件，折叠避免刷屏；头行已含文件数，审批仍可整单元进行。
    for ln = hln + 1, #lines do fold_levels[ln] = 1 end
    lines[#lines + 1] = ""
    end
  end
  -- 已保存（含原文件快照）：展示已发布到真实工作区的变更，`u` 撤销保存（回滚真实文件并回到待审）。
  -- 历史遗留的「已撤销」记录仍展示，`u` 可重做保存。
  if saved and #saved > 0 then
    -- 标题按实际状态动态展示：撤销后条目仍在（供 u 重做），但不该再显示为「已保存」。
    local has_applied, has_reverted = false, false
    for _, item in ipairs(saved) do
      if item.apply_state == "REVERTED" then has_reverted = true else has_applied = true end
    end
    local title
    if has_applied and has_reverted then
      title = "已应用（已保存/已撤销，u 撤销保存）"
    elseif has_reverted then
      title = "已应用（已撤销，u 重做保存）"
    else
      title = "已应用（已保存，u 撤销保存）"
    end
    local title_ln = #lines + 1
    lines[#lines + 1] = "── " .. title .. "──（默认折叠，za/zo 展开）"
    -- 区标题 = 一级折叠（默认整体收起）
    fold_levels[title_ln] = 1
    for _, item in ipairs(saved) do
      local reverted = item.apply_state == "REVERTED"
      local label = reverted and "已撤销" or "已保存"
      local files = item.saved_files
      if not files or #files == 0 then
        files = item.files or {}
      end
      if #files == 0 then
        for _, p in ipairs(item.write_set or {}) do files[#files + 1] = { path = p } end
      end
      local git_op = item.atomic_group == "git"
      local group_desc = git_op
        and string.format("（git 操作 · %d 个文件 · 原子整组）", #files)
        or string.format("（%d 个文件）", #files)
      local base = _one_line(string.format("[%s] %s%s  ", item.change_set_id, item.tool or "?", group_desc))
      local hln = #lines + 1
      lines[#lines + 1] = base .. label
      -- 条目头行 = 二级折叠（展开整区后仍各自收起）
      fold_levels[hln] = 2
      marks[#marks + 1] = { line = hln, start_col = #base, end_col = #base + #label,
        level = reverted and "pending0" or "workspace" }
      line_to_target[hln] = { change_set_id = item.change_set_id, saved = true, whole = true }
      local shown = 0
      for _, f in ipairs(files) do
        if max_files > 0 and shown >= max_files then break end
        shown = shown + 1
        local path = _one_line(f.path or tostring(f))
        local suffix = f.action and ("  [" .. _one_line(f.action) .. "]") or ""
        local text = "  " .. path .. suffix
        local ln = #lines + 1
        lines[#lines + 1] = text
        -- 文件行并入所属条目的二级折叠
        fold_levels[ln] = 2
        marks[#marks + 1] = { line = ln, start_col = 2, end_col = 2 + #path, level = M.level_of(path, lvl_ctx) }
        -- git 原子组：整组撤销/重做，文件行同样映射到整组。
        line_to_target[ln] = git_op
          and { change_set_id = item.change_set_id, saved = true, whole = true }
          or { change_set_id = item.change_set_id, path = path, saved = true }
      end
      if max_files > 0 and #files > shown then
        local rln = _append_rest(#files - shown,
          { change_set_id = item.change_set_id, saved = true, whole = true })
        fold_levels[rln] = 2
      end
      -- 条目尾空行计入一级，保证区折叠连续闭合到末条（空行自身不可见）
      local blk = #lines + 1
      lines[#lines + 1] = ""
      fold_levels[blk] = 1
    end
  end
  -- 已拒绝（可恢复）：显式拒绝（`d`）时候选内容另存 /tmp 副本，条目在此仍可见，
  -- `u` 恢复为待审（重新进入「未应用」区）。与「已应用」区一致默认整体折叠。
  if rejected and #rejected > 0 then
    local title_ln = #lines + 1
    lines[#lines + 1] = ("── 已拒绝（%d 个变更单元，u 恢复为待审）──（默认折叠，za/zo 展开）"):format(#rejected)
    fold_levels[title_ln] = 1
    for _, item in ipairs(rejected) do
      local files = item.files
      if not files or #files == 0 then
        files = {}
        for _, p in ipairs(item.write_set or {}) do files[#files + 1] = { path = p } end
      end
      local git_op = item.atomic_group == "git"
      local group_desc = git_op
        and string.format("（git 操作 · %d 个文件 · 原子整组）", #files)
        or string.format("（%d 个文件）", #files)
      local reason = item.reject_reason and (" · " .. _one_line(item.reject_reason)) or ""
      local base = _one_line(string.format("[%s] %s%s%s  ",
        item.change_set_id, item.tool or "?", group_desc, reason))
      local hln = #lines + 1
      lines[#lines + 1] = base .. "已拒绝"
      fold_levels[hln] = 2
      marks[#marks + 1] = { line = hln, start_col = #base, end_col = #base + #"已拒绝", level = "system" }
      line_to_target[hln] = { change_set_id = item.change_set_id, rejected = true, whole = true }
      local shown = 0
      for _, f in ipairs(files) do
        if max_files > 0 and shown >= max_files then break end
        shown = shown + 1
        local path = _one_line(f.path or tostring(f))
        local suffix = f.action and ("  [" .. _one_line(f.action) .. "]") or ""
        local text = "  " .. path .. suffix
        local ln = #lines + 1
        lines[#lines + 1] = text
        fold_levels[ln] = 2
        marks[#marks + 1] = { line = ln, start_col = 2, end_col = 2 + #path, level = M.level_of(path, lvl_ctx) }
        line_to_target[ln] = git_op
          and { change_set_id = item.change_set_id, rejected = true, whole = true }
          or { change_set_id = item.change_set_id, path = path, rejected = true }
      end
      if max_files > 0 and #files > shown then
        local rln = _append_rest(#files - shown,
          { change_set_id = item.change_set_id, rejected = true, whole = true })
        fold_levels[rln] = 2
      end
      local blk = #lines + 1
      lines[#lines + 1] = ""
      fold_levels[blk] = 1
    end
  end
  -- 越界访问留痕（read_all 下访问 cwd 之外用户工作目录；仅记录，非阻塞）。
  -- 按文件路径合并（同一路径的多工具访问合并）、路径升序排序后展示。
  if traces and #traces > 0 then
    local grouped = _group_traces(traces)
    if #grouped > 0 then
      local head = "── 越界访问留痕（工作区外，仅记录）──"
      lines[#lines + 1] = head
      for _, tr in ipairs(grouped) do
        local path = _one_line(tr.path or "")
        local tool = _one_line(table.concat(tr.tools or { tr.tool or "?" }, ", "))
        if tool == "" then tool = "?" end
        local cmds = tr.commands or {}
        local suffix = ""
        if #cmds == 1 then
          suffix = "  ⟵ " .. _one_line(cmds[1])
        elseif #cmds > 1 then
          suffix = string.format("  ⟵ %d 条命令", #cmds)
        end
        local text = string.format("  [%s] %s%s", tool, path, suffix)
        local ln = #lines + 1
        lines[#lines + 1] = text
        local start_col = 2 + #tool + 3
        marks[#marks + 1] = { line = ln, start_col = start_col, end_col = start_col + #path, level = M.level_of(path, lvl_ctx) }
        -- 该行不参与审批，仅登记留痕路径：`i` 查看详情（工具/类型/命令/时间）。
        line_to_trace[ln] = path
      end
      lines[#lines + 1] = ""
    end
  end
  -- 防御：任何元素都必须是单行字符串，否则 nvim_buf_set_lines 会报 E5108。
  for i = 1, #lines do
    if type(lines[i]) ~= "string" then lines[i] = _one_line(lines[i]) end
    if lines[i]:find("[\r\n]") then lines[i] = _one_line(lines[i]) end
  end
  return { lines = lines, marks = marks, line_to_target = line_to_target, line_to_trace = line_to_trace, fold_levels = fold_levels }
end

-- 前向声明（定义见下方 diff 预览区）
local _find_item
local _open_l3_confirm

--- 执行一次文件级应用（不刷新界面）
--- @param target table { change_set_id, path, host_op? }
--- @param opts table|nil { allow_root?, prefer_sudo? }
--- @return table|nil sandbox.apply 结果
local function _do_apply(target, opts)
  local sandbox = services.use("services.sandbox")
  if not sandbox then return nil end
  opts = opts or {}
  local req = {
    auto_approve = true,
    allow_root = opts.allow_root == true,
    prefer_sudo = opts.prefer_sudo == true,
  }
  -- 主机操作 / 整单元（头行）：应用全部文件；文件行：仅应用该文件。
  if target.host_op or target.whole then
    return sandbox.apply(target.change_set_id, req)
  end
  req.files = { target.path }
  return sandbox.apply(target.change_set_id, req)
end

--- 执行一次应用（异步发布）：CAS + 写入在线程池执行，主线程不被大量文件阻塞。
--- 若沙箱服务未提供 `apply_async`（旧版/测试桩）则回落同步结果。
--- @param target table
--- @param opts table|nil
--- @return any Deferred|table
local function _do_apply_async(target, opts)
  local sandbox = services.use("services.sandbox")
  if not sandbox then return nil end
  opts = opts or {}
  local req = {
    auto_approve = true,
    allow_root = opts.allow_root == true,
    prefer_sudo = opts.prefer_sudo == true,
  }
  if not sandbox.apply_async then
    -- 测试桩/旧服务：回落同步 apply。
    if target.host_op or target.whole then return sandbox.apply(target.change_set_id, req) end
    req.files = { target.path }
    return sandbox.apply(target.change_set_id, req)
  end
  if target.host_op or target.whole then
    return sandbox.apply_async(target.change_set_id, req)
  end
  req.files = { target.path }
  return sandbox.apply_async(target.change_set_id, req)
end

--- @param v any
--- @return boolean
local function _is_deferred(v)
  return type(v) == "table" and type(v.then_) == "function"
end

-- ========== root 提权确认弹窗 ==========

local root_prompt = { win = nil, buf = nil }

local function _close_root_prompt()
  if root_prompt.win and vim.api.nvim_win_is_valid(root_prompt.win) then
    pcall(vim.api.nvim_win_close, root_prompt.win, true)
  end
  geometry.untrack(root_prompt.win)
  root_prompt.win, root_prompt.buf = nil, nil
end

--- 需要 root 时弹窗确认；确认后以 allow_root（非 root 进程经 sudo）重试。
--- @param res table 操作结果（state=NEEDS_ROOT）
--- @param target table
--- @param retry function(result) 重试结果回调
--- @param retry_op function|nil function(prefer_sudo):result 实际提权重试操作；缺省为应用当前条目
local function _show_root_prompt(res, target, retry, retry_op)
  _close_root_prompt()
  local prefer_sudo = vim.uv.getuid() ~= 0
  retry_op = retry_op or function(ps)
    return _do_apply(target, { allow_root = true, prefer_sudo = ps })
  end
  local lines = {
    "该变更需要写入 root 拥有的路径，当前权限不足：",
    "  " .. _one_line(res.reason or target.path or target.change_set_id or ""),
    "",
    prefer_sudo and "确认后将调用 sudo 写入真实系统（可能要求输入密码）。"
      or "确认后将以 root 写入真实系统。",
    "",
    "[<CR>] 确认提权    [<Esc>/q] 取消",
  }
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "neoai_root_prompt"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local geom_opts = { w_ratio = 0.60, h_ratio = 0.40, fit_h = #lines + 2 }
  local geom = geometry.compute(geom_opts)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = geom.width,
    height = geom.height,
    col = geom.col,
    row = geom.row,
    style = "minimal",
    border = "rounded",
    title = "⚠ 需要 root 权限",
    title_pos = "center",
  })
  root_prompt.win, root_prompt.buf = win, buf
  geometry.track(win, geom_opts)
  vim.wo[win].wrap = true
  pcall(vim.cmd, "stopinsert")
  local function close_then(fn)
    _close_root_prompt()
    if fn then fn() end
  end
  local function confirm()
    close_then(function()
      local r = retry_op(prefer_sudo)
      if _is_deferred(r) and r then
        r:then_(function(result) retry(result) end, function()
          retry({ ok = false, state = "FAILED", reason = "提权应用失败" })
        end)
      else
        retry(r)
      end
    end)
  end
  local function cancel()
    close_then(function() retry({ ok = false, state = "CANCELLED", reason = "用户取消" }) end)
  end
  for _, mode in ipairs({ "n", "i" }) do
    vim.keymap.set(mode, "<CR>", confirm, { buffer = buf })
    vim.keymap.set(mode, "<Esc>", cancel, { buffer = buf })
    vim.keymap.set(mode, "q", cancel, { buffer = buf })
  end
end

--- 应用并汇报：NEEDS_ROOT 时弹窗确认后用 root/sudo 重试。
--- @param target table
--- @param ok_msg function(result):string
--- @param fail_msg function(result):string
local function _apply_target(target, ok_msg, fail_msg)
  local function report(res)
    if res and res.ok then
      vim.notify(ok_msg(res), vim.log.levels.INFO)
    elseif res and res.state == "PARTIAL" then
      vim.notify(("[NeoAI] 部分应用：成功 %d 个文件，%d 个失败已回队待审（%s）")
        :format(#(res.applied or {}), #(res.failed or {}), tostring(res.reason or "")),
        vim.log.levels.WARN)
    elseif res and res.state == "CANCELLED" then
      vim.notify("[NeoAI] 已取消（需要 root 权限）", vim.log.levels.WARN)
    else
      vim.notify(fail_msg(res), vim.log.levels.ERROR)
    end
    M.refresh()
    if res and (res.ok or res.state == "PARTIAL") then M.fold_all() end
  end
  local res = _do_apply_async(target)
  if _is_deferred(res) then
    res:then_(function(r)
      if r and not r.ok and r.state == "NEEDS_ROOT" then
        _show_root_prompt(r, target, report, function(ps)
          return _do_apply_async(target, { allow_root = true, prefer_sudo = ps })
        end)
      else
        report(r)
      end
    end, function()
      report({ ok = false, state = "FAILED", reason = "应用失败" })
    end)
    return
  end
  if res and not res.ok and res.state == "NEEDS_ROOT" then
    _show_root_prompt(res, target, report)
  else
    report(res)
  end
end

--- 设置审批窗标题（用于展示批量应用进度）。
--- @param title string
local function _set_review_title(title)
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    pcall(function()
      local cfg = vim.api.nvim_win_get_config(state.win_id)
      cfg.title = title
      cfg.title_pos = "center"
      vim.api.nvim_win_set_config(state.win_id, cfg)
    end)
  end
end

--- 一键同意：应用所有「工作区内」的待审文件（按文件粒度）。
--- 工作区外的文件与主机操作提案保留待审，供用户逐条确认；同一变更单元中工作区外的
--- 文件同样保留（选择性应用），不影响已应用的工作区部分。
---
--- 大批量时**逐项应用并在每项之间让出主循环**（vim.defer_fn），且候选删除用批量会话
--- 统一对账，避免同步 for 循环 + 逐项 O(n) 全表扫描 + 逐文件落盘冻结界面（"一次同意太多卡死"）。
local function _apply_all_workspace()
  local sandbox = services.use("services.sandbox")
  if not sandbox then return end
  if state.applying_all then
    vim.notify("[NeoAI] 正在批量应用中，请稍候…", vim.log.levels.INFO)
    return
  end
  local pending = sandbox.list_reviews({ review_state = "PENDING" })
  local jobs = {}
  for _, item in ipairs(pending) do
    if item.kind ~= "host_op" then
      local files = {}
      for _, f in ipairs(item.files or {}) do
        if type(f.path) == "string" and M.level_of(f.path) == "workspace" then
          files[#files + 1] = f.path
        end
      end
      if #files > 0 then jobs[#jobs + 1] = { id = item.change_set_id, files = files } end
    end
  end
  if #jobs == 0 then
    vim.notify("[NeoAI] 工作区内没有待审修改", vim.log.levels.INFO)
    return
  end

  state.applying_all = true
  local batch = sandbox.begin_batch and sandbox.begin_batch() or nil
  local files_n, items_n, failed_n, root_n = 0, 0, 0, 0
  local i = 0
  local function step()
    if i >= #jobs then
      state.applying_all = false
      if batch and sandbox.end_batch then pcall(sandbox.end_batch, batch) end
      if failed_n == 0 then
        vim.notify(("[NeoAI] 已一键同意工作区内 %d 个变更单元（%d 个文件）"):format(items_n, files_n),
          vim.log.levels.INFO)
      else
        local extra = root_n > 0 and ("，其中 %d 个需要 root 权限（请逐条确认提权）"):format(root_n) or ""
        vim.notify(("[NeoAI] 已应用工作区内 %d 个文件，%d 个变更单元失败%s"):format(files_n, failed_n, extra),
          vim.log.levels.WARN)
      end
      _set_review_title("🗂 沙箱待审/已保存")
      M.refresh()
      if items_n > 0 then M.fold_all() end
      return
    end
    i = i + 1
    local job = jobs[i]
    local opts = { auto_approve = true, files = job.files }
    if batch then opts.batch = batch end
    local function finish(res)
      if res and res.ok then
        files_n = files_n + #job.files
        items_n = items_n + 1
      elseif res and res.state == "PARTIAL" then
        -- 部分应用：成功文件计入，失败文件回队，记为一次失败（但整批继续）。
        files_n = files_n + #(res.applied or {})
        items_n = items_n + 1
        if #(res.failed or {}) > 0 then failed_n = failed_n + 1 end
      else
        failed_n = failed_n + 1
        if res and res.state == "NEEDS_ROOT" then root_n = root_n + 1 end
      end
      _set_review_title(("🗂 沙箱待审/已保存（应用中 %d/%d）"):format(i, #jobs))
      vim.defer_fn(step, 0)
    end
    -- 异步发布（线程池）避免单个巨型变更单元阻塞主线程；单项异常不能中断整批。
    local ok, res
    if sandbox.apply_async then
      ok, res = pcall(sandbox.apply_async, job.id, opts)
    else
      ok, res = pcall(sandbox.apply, job.id, opts)
    end
    if not ok then res = nil end
    if _is_deferred(res) then
      res:then_(finish, function() finish(nil) end)
    else
      finish(res)
    end
  end
  _set_review_title(("🗂 沙箱待审/已保存（应用中 0/%d）"):format(#jobs))
  vim.defer_fn(step, 0)
end

--- 二次确认门禁是否开启
--- @return boolean
local function _l3_gate_enabled()
  local config_store = require("NeoAI.kernel.config_store")
  return config_store.get("tools.sandbox.review.l3_warning.enabled") ~= false
end

--- 该条目是否需要「AI 后果警告 + 二次确认」。
--- L3（critical）恒需；L2 的包安装/敏感安装由 `l3_warning.package_confirm` 控制（默认开）。
--- @param item table|nil
--- @return boolean
local function _needs_confirm(item)
  if not item or not _l3_gate_enabled() then return false end
  local level = tonumber(item.risk_level) or 0
  if level >= 3 then return true end
  if item.package and level >= 2 then
    local config_store = require("NeoAI.kernel.config_store")
    if config_store.get("tools.sandbox.review.l3_warning.package_confirm") == false then return false end
    return true
  end
  return false
end

--- 应用光标所在文件（审批单位为单个文件）。
--- 高危条目（L3 或 L2 包/敏感安装）首次 <CR> 不直接应用：由 AI 生成后果警告并自动打开 diff，
--- 用户在 diff 内再次确认后才真正应用（q/Esc 取消）。
local function _apply_current()
  local target = state.line_to_target[vim.api.nvim_win_get_cursor(0)[1]]
  if not target then
    vim.notify("[NeoAI] 请将光标移到要应用的条目行", vim.log.levels.WARN)
    return
  end
  if target.saved then
    vim.notify("[NeoAI] 该条目已保存，请用 u 撤销/重做保存", vim.log.levels.WARN)
    return
  end
  if target.rejected then
    vim.notify("[NeoAI] 该条目已拒绝，请用 u 恢复到待审后再应用", vim.log.levels.WARN)
    return
  end
  local sandbox = services.use("services.sandbox")
  if not sandbox then return end
  -- 主机操作提案：整条审批后在主机 replay（需 root 时弹窗经 sudo）
  if target.host_op then
    _apply_target(target,
      function() return ("[NeoAI] 已执行主机操作 %s"):format(target.change_set_id) end,
      function(res) return ("[NeoAI] 主机操作失败(%s): %s"):format(tostring(res and res.state), tostring(res and res.reason)) end)
    return
  end
  -- 整单元（头行）：一次应用该变更单元的全部文件（包安装按安装命令合并，整包一次审批）。
  local item = _find_item(target.change_set_id)
  if target.whole then
    if _needs_confirm(item) then
      _open_l3_confirm(target, item)
      return
    end
    local noun = (item and item.atomic_group == "git") and "整组" or "整包"
    _apply_target(target,
      function() return ("[NeoAI] 已应用 %s（%s %d 个文件）"):format(target.change_set_id, noun, #(item and item.files or {})) end,
      function(res) return ("[NeoAI] 应用失败(%s): %s"):format(tostring(res and res.state), tostring(res and res.reason)) end)
    return
  end
  if not target.path then
    vim.notify("[NeoAI] 请将光标移到要应用的文件行", vim.log.levels.WARN)
    return
  end
  -- 高危二次确认门禁
  if _needs_confirm(item) then
    _open_l3_confirm(target, item)
    return
  end
  _apply_target(target,
    function() return ("[NeoAI] 已应用 %s %s"):format(target.change_set_id, target.path) end,
    function(res) return ("[NeoAI] 应用失败(%s): %s"):format(tostring(res and res.state), tostring(res and res.reason)) end)
end

--- 拒绝光标所在文件（其余文件保留待审）
local function _reject_current()
  local target = state.line_to_target[vim.api.nvim_win_get_cursor(0)[1]]
  if not target then
    vim.notify("[NeoAI] 请将光标移到要拒绝的条目行", vim.log.levels.WARN)
    return
  end
  if target.saved then
    vim.notify("[NeoAI] 该条目已保存，请用 u 撤销/重做保存", vim.log.levels.WARN)
    return
  end
  if target.rejected then
    vim.notify("[NeoAI] 该条目已拒绝，请用 u 恢复到待审", vim.log.levels.WARN)
    return
  end
  local sandbox = services.use("services.sandbox")
  if not sandbox then return end
  if target.host_op then
    sandbox.reject(target.change_set_id)
    vim.notify(("[NeoAI] 已拒绝主机操作 %s"):format(target.change_set_id), vim.log.levels.INFO)
    M.refresh()
    return
  end
  if target.whole then
    local it = _find_item(target.change_set_id)
    sandbox.reject(target.change_set_id)
    local noun = (it and it.atomic_group == "git") and "整组" or "整包"
    vim.notify(("[NeoAI] 已拒绝 %s（%s）"):format(target.change_set_id, noun), vim.log.levels.INFO)
    M.refresh()
    return
  end
  if not target.path then
    vim.notify("[NeoAI] 请将光标移到要拒绝的文件行", vim.log.levels.WARN)
    return
  end
  if sandbox.reject_file then
    sandbox.reject_file(target.change_set_id, target.path)
  else
    sandbox.reject(target.change_set_id)
  end
  vim.notify(("[NeoAI] 已拒绝 %s %s"):format(target.change_set_id, target.path), vim.log.levels.INFO)
  M.refresh()
end

--- 把光标所在「合并冲突」条目交给 AI：基于当前真实内容重新应用修改（外部改动不被覆盖）。
local function _resolve_conflict_current()
  local target = state.line_to_target[vim.api.nvim_win_get_cursor(0)[1]]
  if not target or not target.change_set_id then
    vim.notify("[NeoAI] 请将光标移到冲突条目行", vim.log.levels.WARN)
    return
  end
  local sandbox = services.use("services.sandbox")
  if not sandbox or not sandbox.notify_conflict_ai then return end
  local id = target.change_set_id
  if sandbox.has_merge_conflict and not sandbox.has_merge_conflict(id) then
    vim.notify("[NeoAI] 该条目不是合并冲突", vim.log.levels.WARN)
    return
  end
  local ok, err = sandbox.notify_conflict_ai(id)
  if ok then
    vim.notify(("[NeoAI] 已把冲突交给 AI 重做 %s"):format(id), vim.log.levels.INFO)
  else
    vim.notify(("[NeoAI] 交给 AI 失败(%s)"):format(tostring(err)), vim.log.levels.ERROR)
  end
end

--- 撤销保存光标所在条目：把真实文件回滚到保存前，并把该变更单元移回待审队列。
--- 冲突（真实文件被外部改动）时拒绝。
local function _undo_current()
  local target = state.line_to_target[vim.api.nvim_win_get_cursor(0)[1]]
  if not target then
    vim.notify("[NeoAI] 请将光标移到「已保存」或「已拒绝」条目行", vim.log.levels.WARN)
    return
  end
  -- 已拒绝条目：`u` 恢复为待审（从 /tmp 副本重建候选；host_op 恢复提案）。
  if target.rejected then
    local sandbox = services.use("services.sandbox")
    if not sandbox or not sandbox.restore then return end
    local res = sandbox.restore(target.change_set_id)
    if res and res.ok then
      vim.notify(("[NeoAI] 已恢复到待审 %s"):format(target.change_set_id), vim.log.levels.INFO)
    else
      vim.notify(("[NeoAI] 恢复失败(%s): %s"):format(tostring(res and res.state), tostring(res and res.reason)),
        vim.log.levels.ERROR)
    end
    M.refresh()
    return
  end
  if not target.saved then
    vim.notify("[NeoAI] 请将光标移到「已保存」或「已拒绝」条目行", vim.log.levels.WARN)
    return
  end
  local sandbox = services.use("services.sandbox")
  if not sandbox or not sandbox.undo then return end
  local function report(res)
    if res and res.ok then
      local label
      if res.requeued or res.state == "PENDING" then
        label = "已撤销保存并回到待审"
      elseif res.state == "REVERTED" then
        label = "已撤销保存"
      else
        label = "已重新保存"
      end
      vim.notify(("[NeoAI] %s %s"):format(label, target.change_set_id), vim.log.levels.INFO)
    elseif res and res.state == "NEEDS_ROOT" then
      vim.notify("[NeoAI] 撤销保存需要 root 权限：" .. tostring(res.reason), vim.log.levels.WARN)
    else
      vim.notify(("[NeoAI] 撤销/重做失败(%s): %s"):format(tostring(res and res.state), tostring(res and res.reason)),
        vim.log.levels.ERROR)
    end
    M.refresh()
  end
  local res = sandbox.undo(target.change_set_id)
  if res and not res.ok and res.state == "NEEDS_ROOT" then
    -- 复用 root 提权确认：确认后以 allow_root 重试撤销。
    _show_root_prompt(res, target, report, function(prefer_sudo)
      return sandbox.undo(target.change_set_id, { allow_root = true, prefer_sudo = prefer_sudo })
    end)
  else
    report(res)
  end
end

-- ========== AI 审计 ==========

--- 待审集合签名：用于判断已完成的审计是否仍适用（集合变化则需重新审计）。
--- @param items table|nil
--- @return string
local function _pending_sig(items)
  local ids = {}
  for _, it in ipairs(items or {}) do ids[#ids + 1] = tostring(it.change_set_id or "?") end
  table.sort(ids)
  return table.concat(ids, ",")
end

--- 发起 AI 审计：把原会话的用户消息与分级的待审变更/修改内容的结构化文本交给模型，
--- 逐条判断是否允许应用；结论直接显示在审批悬浮窗顶部（不进入聊天界面）。
--- @param opts table|nil { silent?: boolean } 自动触发时不弹「无待审」提示
local function _ai_audit(opts)
  opts = opts or {}
  local sandbox = services.use("services.sandbox")
  if not sandbox then return end
  local items = sandbox.list_reviews({ review_state = "PENDING" })
  if #items == 0 then
    if not opts.silent then
      vim.notify("[NeoAI] 无待审修改，无法发起 AI 审计", vim.log.levels.INFO)
    end
    return
  end
  local chat = services.use("services.chat_service")
  local source_agent = chat and chat.get_current_agent() or nil
  local user_msgs = sandbox.audit_user_messages(source_agent)
  local agent_config = source_agent and source_agent.config or nil

  state.audit_seq = state.audit_seq + 1
  local seq = state.audit_seq
  state.audit = { pending = true }
  state.audit_sig = _pending_sig(items)
  M.refresh()
  sandbox.audit_generate(items, user_msgs, { agent_config = agent_config }, function(result, err)
    if seq ~= state.audit_seq then return end
    if err then
      state.audit = { error = err }
    else
      state.audit = {
        notes = (result and result.notes) or {},
        fallback = result and result.fallback or nil,
      }
    end
    M.refresh()
  end)
end

-- ========== 修改预览（diff） ==========

--- 读取文件内容（不存在返回 ""）
--- @param path string
--- @return string
local function _read_file(path)
  local f = io.open(path, "rb")
  if not f then return "" end
  local c = f:read("*a")
  f:close()
  return c or ""
end

--- 在待审队列中查找变更单元
--- @param change_set_id string
--- @return table|nil
_find_item = function(change_set_id)
  local sandbox = services.use("services.sandbox")
  if not sandbox then return nil end
  for _, it in ipairs(sandbox.list_reviews()) do
    if it.change_set_id == change_set_id then return it end
  end
  return nil
end

--- 查找变更单元中的文件条目
--- @param item table|nil
--- @param path string
--- @return table|nil
local function _find_file(item, path)
  for _, f in ipairs((item and item.files) or {}) do
    if f.path == path then return f end
  end
  return nil
end

--- 生成统一 diff 文本行
--- @param before string
--- @param after string
--- @return table 行数组
local function _diff_lines(before, after)
  local ok, diff = pcall(vim.diff, before or "", after or "", {
    result_type = "unified", ctxlen = 3, algorithm = "histogram",
  })
  if not ok or type(diff) ~= "string" or diff == "" then
    return { "（无差异）" }
  end
  return vim.split(diff, "\n", { plain = true })
end

--- 内容是否为二进制（含 NUL、非法 UTF-8、`NEOAI_BINARY:` 标记，或控制字节占比过高）：
--- 绝不喂给 `vim.diff`，否则界面显示乱码；二进制文件改为显示占位说明。
--- @param s string|nil
--- @return boolean
local function _looks_binary(s)
  if type(s) ~= "string" or s == "" then return false end
  if s:sub(1, 13) == "NEOAI_BINARY:" then return true end
  if s:find("\0", 1, true) then return true end
  local n = #s
  local limit = 65536
  if n <= limit then
    local ok, valid = pcall(require("NeoAI.utils.stringx").is_valid_utf8, s)
    if not ok or valid == false then return true end
  end
  -- 无 NUL 但控制字节占比过高（>10%）：同样视为二进制（大文件采样，避免逐字节全扫）。
  local ctrl, sampled = 0, 0
  local step = n > limit and math.max(1, math.floor(n / limit)) or 1
  for i = 1, n, step do
    local b = s:byte(i)
    if (b < 32 and b ~= 9 and b ~= 10 and b ~= 12 and b ~= 13 and b ~= 27) or b == 127 then
      ctrl = ctrl + 1
    end
    sampled = sampled + 1
  end
  return sampled > 0 and ctrl * 10 > sampled
end

--- 清洗 diff 行中的控制字符（保留制表），避免终端把 C0/C1 控制序列渲染为乱码。
--- @param s string
--- @return string
local function _sanitize_line(s)
  if type(s) ~= "string" or s == "" then return s end
  if not s:find("[%z\1-\8\11\12\14-\31\127]") then return s end
  return (s:gsub("[%z\1-\8\11\12\14-\31\127]", function(c)
    return string.format("\\x%02x", c:byte())
  end))
end

--- 为 diff 文本着色（+ 增 / - 删 / @@ 段）
--- @param buf number
--- @param ns number
--- @param lines table
--- @param start_idx number|nil 起始行（1-based，默认 1；警告区不计入）
local function _paint_diff(buf, ns, lines, start_idx)
  for i = start_idx or 1, #lines do
    local l = lines[i]
    local hl
    if l:sub(1, 1) == "+" and l:sub(1, 3) ~= "+++" then
      hl = "diffAdded"
    elseif l:sub(1, 1) == "-" and l:sub(1, 3) ~= "---" then
      hl = "diffRemoved"
    elseif l:sub(1, 2) == "@@" then
      hl = "diffLine"
    end
    if hl then pcall(vim.api.nvim_buf_add_highlight, buf, ns, hl, i - 1, 0, -1) end
  end
end

--- 关闭 diff 预览并在需要时重新打开审批窗
local function _close_diff()
  local d = state.diff
  local reopen = state.suspended
  state.diff = nil
  state.suspended = false
  state.pending_l3 = nil
  state.l3_seq = state.l3_seq + 1 -- 作废过期的 AI 警告结果
  if d then
    geometry.untrack(d.win)
    if d.win and vim.api.nvim_win_is_valid(d.win) then
      pcall(vim.api.nvim_win_close, d.win, true)
    end
    if d.buf and vim.api.nvim_buf_is_valid(d.buf) then
      pcall(vim.api.nvim_buf_delete, d.buf, { force = true })
    end
  end
  if reopen then
    M.open()
  end
end

--- 硬换行：按显示宽度切分单行文本（CJK 按 2 列计）
--- @param s string
--- @param width number
--- @return table 行数组
local function _wrap(s, width)
  width = math.max(10, width or 80)
  local out = {}
  local n = vim.fn.strchars(s)
  local i = 0
  while i < n do
    local part, w = "", 0
    while i < n and w < width do
      local ch = vim.fn.strcharpart(s, i, 1)
      local cw = vim.fn.strdisplaywidth(ch)
      if w + cw > width and w > 0 then break end
      part, w, i = part .. ch, w + cw, i + 1
    end
    out[#out + 1] = part
  end
  if #out == 0 then out[1] = "" end
  return out
end

--- 构造二次确认警告区行（含标题；pending 时显示占位）。
--- 标题按风险级别区分（L3 严重 / L2 高危）；若冻结时剔除了不可发布文件，追加说明行。
--- @param text string|nil
--- @param pending boolean
--- @param width number
--- @param meta table|nil { level?: number, dropped?: { masked?: number, volatile?: number } }
--- @return table
local function _warning_lines(text, pending, width, meta)
  meta = meta or {}
  local level = tonumber(meta.level) or 3
  local label = level >= 3 and "L3 严重" or "L2 高危"
  local out = { ("⚠ %s风险操作 — 后果警告"):format(label) }
  if pending then
    out[#out + 1] = "（正在生成后果警告…）"
    return out
  end
  if type(text) ~= "string" or text:gsub("%s", "") == "" then
    out[#out + 1] = "（无警告内容）"
  else
    -- 防御：模型/兜底文本若含非法 UTF-8 字节，先修复，避免 _wrap 逐字符切分产生乱码。
    local sm = require("NeoAI.utils.stringx")
    text = sm.sanitize_utf8(text) or text
    if text:find("\0", 1, true) then text = text:gsub("%z", "") end
    for _, para in ipairs(vim.split(text, "\n", { plain = true })) do
      if para == "" then
        out[#out + 1] = ""
      else
        for _, l in ipairs(_wrap(para, width)) do out[#out + 1] = _sanitize_line(l) end
      end
    end
  end
  local dropped = meta.dropped
  local n = 0
  if type(dropped) == "table" then n = (dropped.masked or 0) + (dropped.volatile or 0) end
  if n > 0 then
    out[#out + 1] = ""
    out[#out + 1] = ("ℹ 将跳过 %d 个遮蔽/缓存文件（不写入宿主）"):format(n)
  end
  return out
end

--- 为二次确认警告区着色：标题行用红色警示，跳过说明行用暗灰，其余正文保持默认。
--- @param buf number
--- @param ns number
--- @param start0 number|nil 0-based 起始行
--- @param count number|nil 行数
--- @param lines table|nil 完整缓冲区行（1-based），用于区分说明行
local function _paint_warning(buf, ns, start0, count, lines)
  if start0 == nil or count == nil then return end
  for i = 0, count - 1 do
    local hl = L3_WARN_HL
    local l = lines and lines[start0 + i + 1]
    if type(l) == "string" and l:sub(1, 3) == "ℹ" then hl = LEVEL_HL.note end
    pcall(vim.api.nvim_buf_add_highlight, buf, ns, hl, start0 + i, 0, -1)
  end
end

--- 更新已打开 diff 的警告区（AI 异步返回后调用）
--- @param text string
local function _set_diff_warning(text)
  local d = state.diff
  if not d or not d.buf or not vim.api.nvim_buf_is_valid(d.buf) then return end
  if d.mode ~= "l3_confirm" or d.warn_start == nil then return end
  local wl = _warning_lines(text, false, (d.width or 80) - 4, d.warn_meta)
  vim.bo[d.buf].modifiable = true
  vim.api.nvim_buf_set_lines(d.buf, d.warn_start, d.warn_end, false, wl)
  vim.bo[d.buf].modifiable = false
  d.warn_end = d.warn_start + #wl
  local lines = vim.api.nvim_buf_get_lines(d.buf, 0, -1, false)
  vim.api.nvim_buf_clear_namespace(d.buf, d.ns, 0, -1)
  _paint_warning(d.buf, d.ns, d.warn_start, #wl, lines)
  _paint_diff(d.buf, d.ns, lines, d.diff_start)
end

--- 构建预览内容：标题 / 修改前 / 修改后
--- @param target table
--- @param item table
--- @return string title
--- @return string before
--- @return string after
local function _preview_data(target, item)
  local level = item.risk_level
  if target.host_op then
    return "主机操作 · " .. _risk_label(level), "", (item.write_set and item.write_set[1]) or "?"
  end
  local f = _find_file(item, target.path)
  local action = f and f.action or "modify"
  local before = (action == "create" or action == "mkdir") and "" or _read_file(target.path)
  local after = (action == "delete" or action == "rmdir") and "" or ((f and f.content) or "")
  -- 内存 item 落盘后 content 已剥离：按候选摘要按需读取（小型 LRU）。
  if (action ~= "delete" and action ~= "rmdir") and after == "" and not (f and f.content) then
    local sb = _sb()
    local lazy = sb and sb.content_for(item.change_set_id, target.path)
    if lazy then after = lazy end
  end
  -- 预览给用户看：token 还原为真实密钥（best-effort）。
  pcall(function()
    local sb = _sb()
    local restored = sb and sb.detokenize(after)
    if restored ~= nil then after = restored end
  end)
  return string.format("%s · %s · %s", action, _risk_label(level), target.path), before, after
end

--- 打开 diff 预览窗口（可选二次确认模式）
--- @param target table
--- @param item table
--- @param opts table|nil { mode?, on_confirm?, warning?, pending? }
local function _open_diff(target, item, opts)
  opts = opts or {}
  local mode = opts.mode or "preview"
  local is_confirm = (mode == "l3_confirm")
  local title, before, after = _preview_data(target, item)
  local level = tonumber(item and item.risk_level) or 0
  local confirm_title = level >= 3 and "⚠ L3 严重 · 确认应用" or "⚠ L2 高危 · 确认应用"

  -- 暂时关闭审批窗（保留光标/几何，关闭 diff 后自动重开并恢复光标）
  state.suspended = true
  M.close()

  local diff_geom_opts = { w_ratio = 0.80, h_ratio = 0.75 }
  local diff_geom = geometry.compute(diff_geom_opts)
  local width = diff_geom.width
  local lines = {
    ("%s  %s"):format(is_confirm and "确认应用" or "修改预览", _one_line(title)),
  }
  if is_confirm then
    lines[#lines + 1] = "<CR> 确认应用    q / Esc 取消    （+ 新增  - 删除）"
  else
    lines[#lines + 1] = "q / Esc 返回审批    （+ 新增  - 删除）"
  end
  lines[#lines + 1] = ""

  local warn_start, warn_end, warn_meta
  if is_confirm then
    warn_meta = { level = level, dropped = item and item.dropped }
    warn_start = #lines -- 0-based 起始（当前已有行数）
    local wl = _warning_lines(opts.warning, opts.pending == true, width - 4, warn_meta)
    for _, l in ipairs(wl) do lines[#lines + 1] = l end
    warn_end = #lines
    lines[#lines + 1] = ""
  end
  local diff_start = #lines + 1
  local diff_lines
  if _looks_binary(before) or _looks_binary(after) then
    -- 二进制文件（keyring/shada/可执行文件等）：不做文本 diff，避免界面乱码。
    diff_lines = { ("（二进制文件：%d → %d 字节，不显示文本 diff）"):format(#before, #after) }
  else
    diff_lines = _diff_lines(before, after)
  end
  for _, l in ipairs(diff_lines) do lines[#lines + 1] = _sanitize_line(l) end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "neoai_sandbox_diff"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local ns = vim.api.nvim_create_namespace("NeoAISandboxDiff")
  _paint_warning(buf, ns, warn_start, warn_end and (warn_end - (warn_start or 0)) or nil, lines)
  _paint_diff(buf, ns, lines, diff_start)
  -- 按键提示行高亮，使确认/取消操作更醒目。
  pcall(vim.api.nvim_buf_add_highlight, buf, ns, HINT_HL, 1, 0, -1)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = diff_geom.width,
    height = diff_geom.height,
    col = diff_geom.col,
    row = diff_geom.row,
    style = "minimal",
    border = "rounded",
    title = is_confirm and confirm_title or "🔍 修改预览",
    title_pos = "center",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  geometry.track(win, diff_geom_opts)
  vim.keymap.set("n", "q", function() _close_diff() end, { buffer = buf })
  vim.keymap.set("n", "<Esc>", function() _close_diff() end, { buffer = buf })
  if is_confirm and opts.on_confirm then
    vim.keymap.set("n", "<CR>", function() opts.on_confirm() end, { buffer = buf })
  end
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf, once = true, callback = function() _close_diff() end,
  })
  state.diff = {
    win = win, buf = buf, ns = ns, mode = mode,
    warn_start = warn_start, warn_end = warn_end, diff_start = diff_start, width = width,
    warn_meta = warn_meta,
  }
end

--- 打开一个只读浮窗展示详情行（暂时关闭审批窗，关闭后自动返回）。
--- 复用 `state.diff` 的关闭/重开机制（mode="detail"）。
--- @param title string 浮窗标题
--- @param lines table 内容行
local function _open_detail_float(title, lines)
  state.suspended = true
  M.close()
  local detail_geom_opts = { w_ratio = 0.80, h_ratio = 0.75 }
  local detail_geom = geometry.compute(detail_geom_opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "neoai_sandbox_detail"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local ns = vim.api.nvim_create_namespace("NeoAISandboxDetail")
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = detail_geom.width,
    height = detail_geom.height,
    col = detail_geom.col,
    row = detail_geom.row,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  geometry.track(win, detail_geom_opts)
  vim.keymap.set("n", "q", function() _close_diff() end, { buffer = buf })
  vim.keymap.set("n", "<Esc>", function() _close_diff() end, { buffer = buf })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf, once = true, callback = function() _close_diff() end,
  })
  state.diff = { win = win, buf = buf, ns = ns, mode = "detail", width = detail_geom.width }
end

--- 查看某条越界留痕的详情：汇总涉及工具/命令/时间，并逐条列出工具 / 类型 / 命令 / 时间。
--- @param path string
local function _open_trace_detail(path)
  local sandbox = services.use("services.sandbox")
  local entries = {}
  if sandbox and sandbox.list_traces then
    for _, tr in ipairs(sandbox.list_traces() or {}) do
      if tostring(tr.path or "") == path then entries[#entries + 1] = tr end
    end
  end
  if #entries == 0 then
    vim.notify("[NeoAI] 越界留痕已不存在: " .. tostring(path), vim.log.levels.WARN)
    return
  end
  -- 聚合：涉及工具 / 涉及命令 / 来源 / 时间范围（去重有序）。
  local tools, cmds, sources = {}, {}, {}
  local first_at, last_at
  local function _add(list, v)
    if type(v) ~= "string" or v == "" then return end
    for _, p in ipairs(list) do if p == v then return end end
    list[#list + 1] = v
  end
  for _, tr in ipairs(entries) do
    _add(tools, tr.tool)
    local c = tr.commands
    if c and #c > 0 then
      for _, cmd in ipairs(c) do _add(cmds, cmd) end
    else
      _add(cmds, tr.command)
    end
    for _, s in ipairs(tr.sources or {}) do _add(sources, s) end
    local t0 = tonumber(tr.created_at)
    if t0 and (not first_at or t0 < first_at) then first_at = t0 end
    local t1 = tonumber(tr.last_at) or t0
    if t1 and (not last_at or t1 > last_at) then last_at = t1 end
  end
  local lines = { "越界访问详情（工作区外，仅记录）", "q/Esc 返回审批", "" }
  lines[#lines + 1] = "路径: " .. _one_line(path)
  lines[#lines + 1] = "涉及工具: " .. (#tools > 0 and table.concat(tools, ", ") or "?")
  if #sources > 0 then lines[#lines + 1] = "来源: " .. table.concat(sources, ", ") end
  lines[#lines + 1] = string.format("涉及命令: %d 条", #cmds)
  if #cmds > 0 then
    for _, cmd in ipairs(cmds) do lines[#lines + 1] = "  $ " .. _one_line(cmd) end
  else
    lines[#lines + 1] = "  （无命令记录：非命令工具访问）"
  end
  if first_at then
    local fmt = function(ts) return os.date("%Y-%m-%d %H:%M:%S", ts) end
    lines[#lines + 1] = "时间: " .. fmt(first_at)
      .. ((last_at and last_at ~= first_at) and (" ～ " .. fmt(last_at)) or "")
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = string.format("访问记录: %d 条", #entries)
  for i, tr in ipairs(entries) do
    lines[#lines + 1] = string.format("#%d  工具: %s  类型: %s", i,
      _one_line(tr.tool or "?"), _one_line(tr.kind or "read"))
    local ec = tr.commands
    if ec and #ec > 0 then
      for _, cmd in ipairs(ec) do lines[#lines + 1] = "    命令: " .. _one_line(cmd) end
    elseif type(tr.command) == "string" and tr.command ~= "" then
      lines[#lines + 1] = "    命令: " .. _one_line(tr.command)
    end
    if tr.created_at then
      lines[#lines + 1] = "    时间: " .. os.date("%Y-%m-%d %H:%M:%S", tonumber(tr.created_at) or os.time())
    end
    lines[#lines + 1] = ""
  end
  _open_detail_float("🔎 越界访问详情", lines)
end

--- 查看某条越界命令涉及的文件（命令 → 文件）。
--- @param command string|nil nil 表示「非命令工具访问」聚合组
local function _open_command_detail(command)
  local sandbox = services.use("services.sandbox")
  local matched = {}
  if sandbox and sandbox.list_traces then
    for _, tr in ipairs(sandbox.list_traces() or {}) do
      local match
      if command == nil then
        local has = (type(tr.command) == "string" and tr.command ~= "")
          or (tr.commands and #tr.commands > 0)
        match = not has
      else
        match = (tr.command == command)
        if not match and tr.commands then
          for _, c in ipairs(tr.commands) do if c == command then match = true break end end
        end
      end
      if match then matched[#matched + 1] = tr end
    end
  end
  if #matched == 0 then
    vim.notify("[NeoAI] 越界命令已不存在", vim.log.levels.WARN)
    return
  end
  local lvl_ctx = { cwd = _canon_base(vim.fn.getcwd()), home = _canon_base(vim.fn.expand("~")) }
  local grouped = _group_traces(matched)
  local lines = { "越界命令详情（工作区外，仅记录）", "q/Esc 返回审批", "" }
  lines[#lines + 1] = "命令: " .. (command and ("$ " .. _one_line(command)) or "（非命令工具访问）")
  lines[#lines + 1] = string.format("涉及文件: %d 个", #grouped)
  lines[#lines + 1] = ""
  for _, tr in ipairs(grouped) do
    local path = _one_line(tr.path or "")
    local tool = _one_line(table.concat(tr.tools or { tr.tool or "?" }, ", "))
    if tool == "" then tool = "?" end
    local level = M.level_of(path, lvl_ctx)
    local tag = level == "user" and "用户目录" or (level == "system" and "系统路径" or "工作区外")
    lines[#lines + 1] = string.format("  [%s] %s  (%s)", tool, path, tag)
  end
  _open_detail_float("🔎 越界命令详情", lines)
end

--- 选择用于 diff 预览的文件路径。
--- git 原子组优先预览工作区文件；仅含 `.git` 内部（二进制索引/对象）时返回 nil（不预览）。
--- @param item table|nil
--- @param target table
--- @return string|nil
local function _preview_path(item, target)
  if target.path then return target.path end
  if not (item and item.files) then return nil end
  local sb = _sb()
  local first
  for _, f in ipairs(item.files) do
    local gc = sb and sb.git_path_class(f.path)
    if not gc then return f.path end -- 普通工作区文件优先
    first = first or f.path
  end
  return first
end

--- 打开一个临时 buffer 预览光标所在条目的修改 diff（暂时关闭审批窗，关闭后自动返回）
local function _open_diff_current()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  -- 越界留痕行：`i` 查看详情（非审批目标，无 diff）。
  local trace_path = state.line_to_trace[line]
  if trace_path then
    _open_trace_detail(trace_path)
    return
  end
  -- 越界命令行：`i` 查看该命令涉及的文件（非审批目标，无 diff）。
  local cmd_target = state.line_to_cmd[line]
  if cmd_target then
    _open_command_detail(cmd_target.command)
    return
  end
  local target = state.line_to_target[line]
  if not target then
    vim.notify("[NeoAI] 请将光标移到要预览的条目行", vim.log.levels.WARN)
    return
  end
  if target.saved then
    vim.notify("[NeoAI] 已保存条目暂不支持 diff 预览", vim.log.levels.WARN)
    return
  end
  if target.rejected then
    vim.notify("[NeoAI] 该条目已拒绝，请先用 u 恢复到待审再预览 diff", vim.log.levels.WARN)
    return
  end
  local item = _find_item(target.change_set_id)
  if not item then
    vim.notify("[NeoAI] 变更单元已不存在: " .. tostring(target.change_set_id), vim.log.levels.WARN)
    return
  end
  if not target.host_op and not target.path and not target.whole then
    vim.notify("[NeoAI] 请将光标移到要预览的文件行", vim.log.levels.WARN)
    return
  end
  -- 主机操作无文件：直接预览其命令（_preview_data 按 host_op 展示命令），不走文件路径解析。
  if target.host_op then
    _open_diff({ change_set_id = target.change_set_id, host_op = true }, item, { mode = "preview" })
    return
  end
  -- 整单元（头行）无具体 path：取首个工作区文件作预览（应用仍为整单元）。
  local path = _preview_path(item, target)
  if not path then
    vim.notify("[NeoAI] 该 git 操作仅含 `.git` 内部变更，无 diff 预览（应用/丢弃仍作用于整组）",
      vim.log.levels.INFO)
    return
  end
  _open_diff({ change_set_id = target.change_set_id, path = path, whole = target.whole, host_op = target.host_op },
    item, { mode = "preview" })
end

--- 二次确认后应用 L3 条目
local function _confirm_l3()
  local p = state.pending_l3
  if not p then return end
  state.pending_l3 = nil
  local res = _do_apply_async(p)
  _close_diff()
  local function report(res2)
    if res2 and res2.ok then
      vim.notify(("[NeoAI] 已应用 %s %s"):format(p.change_set_id, p.path or ""), vim.log.levels.INFO)
    elseif res2 and res2.state == "CANCELLED" then
      vim.notify("[NeoAI] 已取消（需要 root 权限）", vim.log.levels.WARN)
    else
      vim.notify(("[NeoAI] 应用失败(%s): %s"):format(tostring(res2 and res2.state), tostring(res2 and res2.reason)),
        vim.log.levels.ERROR)
    end
    M.refresh()
    if res2 and res2.ok then M.fold_all() end
  end
  if _is_deferred(res) then
    res:then_(function(r)
      if r and not r.ok and r.state == "NEEDS_ROOT" then
        _show_root_prompt(r, p, report)
      else
        report(r)
      end
    end, function() report({ ok = false, state = "FAILED", reason = "应用失败" }) end)
    return
  end
  if res and not res.ok and res.state == "NEEDS_ROOT" then
    _show_root_prompt(res, p, report)
  else
    report(res)
  end
end

--- 打开 L3 二次确认 diff 并异步生成 AI 后果警告
--- @param target table
--- @param item table
_open_l3_confirm = function(target, item)
  -- 整单元（头行）无具体 path：取首个工作区文件作预览；应用仍按 target.whole 整单元。
  local path = _preview_path(item, target)
  if not path and item and item.files and item.files[1] then path = item.files[1].path end
  state.pending_l3 = { change_set_id = target.change_set_id, path = path, whole = target.whole }
  _open_diff({ change_set_id = target.change_set_id, path = path, whole = target.whole, host_op = target.host_op },
    item, { mode = "l3_confirm", on_confirm = _confirm_l3, pending = true })
  state.l3_seq = state.l3_seq + 1
  local seq = state.l3_seq
  local sb = _sb()
  if not sb then return end
  sb.l3_generate(item, target, function(text)
    if seq ~= state.l3_seq then return end
    local d = state.diff
    if not d or d.mode ~= "l3_confirm" then return end
    _set_diff_warning(text or sb.l3_fallback(item, target))
  end)
end

-- ========== 多级页面（审批分流） ==========
-- 页定义与标签经门面 `services.sandbox` 获取（见顶部辅助函数）。

-- ========== 目录设置（工作目录 / 遮蔽目录，仅本会话） ==========
-- 「资源访问」页可管理两类目录（仅当前会话生效：config_store.set 热更新，不写盘，
-- 重开 nvim 恢复默认）：
--   * 工作目录列表 = tools.approval.allowed_directories：命令审批时自动放行的目录（含子目录）。
--   * 遮蔽目录列表 = tools.sandbox.mask_dirs：命中即触发本页「资源访问」审批。
-- 注意：`read_all=true`（默认）时遮蔽目录不生效（改为只读放行 + 越界留痕）；
-- 遮蔽目录列表清空则回退到默认（/home、/root）。编辑器会给出相应提示。
local CFG_DIRS_WS = "tools.approval.allowed_directories"
local CFG_DIRS_MASK = "tools.sandbox.mask_dirs"
local CFG_MASK_ENABLED = "tools.sandbox.mask_dirs_enabled"
local DEFAULT_DIRS_MASK = { "/home", "/root" }

local dirs_editor = { win = nil, buf = nil, ns = nil, line_map = {} }

--- 规范化目录路径（展开 ~/$VAR → 绝对化 → 去尾部斜杠）
--- @param p string
--- @return string
local function _norm_dir(p)
  return fs.canonical(p)
end

--- 当前目录快照（只读）
--- @return table { workspace, mask, mask_enabled, read_all }
local function _dirs_snapshot()
  local cfg = require("NeoAI.kernel.config_store")
  local ws = cfg.get(CFG_DIRS_WS)
  local mask = cfg.get(CFG_DIRS_MASK)
  return {
    workspace = type(ws) == "table" and vim.deepcopy(ws) or {},
    mask = type(mask) == "table" and vim.deepcopy(mask) or {},
    mask_enabled = cfg.get(CFG_MASK_ENABLED) ~= false,
    read_all = cfg.get("tools.sandbox.read_all") ~= false,
  }
end

--- 遮蔽目录当前状态文本（生效中 / 已关闭 / 因 read_all 暂不生效）
--- @param snap table
--- @return string
local function _mask_state_text(snap)
  if not snap.mask_enabled then return "已关闭" end
  if snap.read_all then return "因 read_all=true 暂不生效" end
  return "生效中"
end

--- 构建「目录设置」区（资源访问页，纯只读展示；编辑请按 E 打开编辑器）
--- @return table lines
--- @return table marks
local function _build_dirs_section()
  local snap = _dirs_snapshot()
  local lines, marks = {}, {}
  local function add(text, level)
    lines[#lines + 1] = text
    if level then marks[#marks + 1] = { line = #lines, start_col = 0, end_col = #text, level = level } end
  end
  local lvl_ctx = { cwd = _canon_base(vim.fn.getcwd()), home = _canon_base(vim.fn.expand("~")) }
  add("── 目录设置（仅本会话，E 编辑）──", "note")
  add(string.format("工作目录列表（命令审批自动放行，共 %d）:", #snap.workspace))
  if #snap.workspace == 0 then
    add("  （空，E 编辑器内按 a 添加）")
  else
    for i, d in ipairs(snap.workspace) do
      add(string.format("  %d. %s", i, _one_line(d)), M.level_of(tostring(d), lvl_ctx))
    end
  end
  add(string.format("遮蔽目录列表（命中触发本页审批，共 %d，%s）:", #snap.mask, _mask_state_text(snap)))
  if #snap.mask == 0 then
    add("  （未显式设置 → 默认 " .. table.concat(DEFAULT_DIRS_MASK, "、") .. "，E 编辑器内按 A 添加）")
  else
    for i, d in ipairs(snap.mask) do
      add(string.format("  %d. %s", i, _one_line(d)), "system")
    end
  end
  add("")
  return lines, marks
end

--- 重绘目录编辑器
local function _refresh_dirs_editor()
  if not (dirs_editor.buf and vim.api.nvim_buf_is_valid(dirs_editor.buf)) then return end
  local snap = _dirs_snapshot()
  local lines, map = {}, {}
  local function add(text, entry)
    lines[#lines + 1] = text
    if entry then map[#lines] = entry end
  end
  add("⚙ 目录设置（仅本会话，重开 nvim 后恢复默认）")
  add("")
  add(string.format("─ 工作目录列表（命令审批自动放行，共 %d）─", #snap.workspace))
  if #snap.workspace == 0 then
    add("  （空，按 a 添加）")
  else
    for i, d in ipairs(snap.workspace) do add("  " .. _one_line(d), { kind = "workspace", index = i }) end
  end
  add("")
  add(string.format("─ 遮蔽目录列表（命中触发资源访问审批，共 %d，%s）─", #snap.mask, _mask_state_text(snap)))
  if #snap.mask == 0 then
    add("  （未显式设置 → 默认 " .. table.concat(DEFAULT_DIRS_MASK, "、") .. "，按 A 添加）")
  else
    for i, d in ipairs(snap.mask) do add("  " .. _one_line(d), { kind = "mask", index = i }) end
  end
  add("")
  add("按键: a 加工作目录    A 加遮蔽目录    d 删除光标处目录    t 切换遮蔽开关    q/Esc 关闭")
  dirs_editor.line_map = map
  vim.bo[dirs_editor.buf].modifiable = true
  vim.api.nvim_buf_set_lines(dirs_editor.buf, 0, -1, false, lines)
  if dirs_editor.ns then
    vim.api.nvim_buf_clear_namespace(dirs_editor.buf, dirs_editor.ns, 0, -1)
    for ln, e in pairs(map) do
      local lvl = e.kind == "workspace" and "workspace" or "system"
      vim.api.nvim_buf_add_highlight(dirs_editor.buf, dirs_editor.ns, LEVEL_HL[lvl], ln - 1, 2, -1)
    end
  end
  -- 内容行数变化时自适应窗口高度。
  if dirs_editor.win and vim.api.nvim_win_is_valid(dirs_editor.win) then
    pcall(function()
      local cfg = vim.api.nvim_win_get_config(dirs_editor.win)
      local h = math.max(6, math.min(#lines, vim.o.lines - 4))
      if cfg.height ~= h then
        cfg.height = h
        vim.api.nvim_win_set_config(dirs_editor.win, cfg)
      end
    end)
  end
end

--- 关闭目录编辑器
local function _close_dirs_editor()
  if dirs_editor.win and vim.api.nvim_win_is_valid(dirs_editor.win) then
    pcall(vim.api.nvim_win_close, dirs_editor.win, true)
  end
  geometry.untrack(dirs_editor.win)
  dirs_editor.win, dirs_editor.buf, dirs_editor.ns = nil, nil, nil
  dirs_editor.line_map = {}
end

--- 编辑器内新增目录：vim.ui.input 输入路径（静默同步回调，避免 E5560）
--- @param kind string "workspace" | "mask"
local function _edit_add_dir(kind)
  local label = kind == "workspace" and "工作目录" or "遮蔽目录"
  local function handle(input)
    if not input or input == "" then return end
    local ok, err = M.add_dir(kind, input)
    if ok then
      vim.notify(("[NeoAI] 已加入%s: %s"):format(label, _norm_dir(input)), vim.log.levels.INFO)
    else
      vim.notify(("[NeoAI] 添加失败: %s"):format(tostring(err or "无效路径")), vim.log.levels.WARN)
    end
    _refresh_dirs_editor()
  end
  local called = false
  local ok = pcall(vim.ui.input, { prompt = label .. "路径: " }, function(input)
    called = true
    handle(input)
  end)
  -- 少数实现同步触发回调/异常：兜底保证刷新与提示不丢。
  if not ok and not called then
    vim.notify("[NeoAI] 无法打开输入框", vim.log.levels.WARN)
  end
end

--- 编辑器内删除光标所在目录行
local function _edit_remove_dir()
  local ln = vim.api.nvim_win_get_cursor(0)[1]
  local entry = dirs_editor.line_map[ln]
  if not entry then
    vim.notify("[NeoAI] 请将光标移到目录行再按 d", vim.log.levels.WARN)
    return
  end
  local ok, err = M.remove_dir(entry.kind, entry.index)
  if ok then
    vim.notify("[NeoAI] 已移除目录", vim.log.levels.INFO)
  else
    vim.notify(("[NeoAI] 移除失败: %s"):format(tostring(err or "")), vim.log.levels.WARN)
  end
  _refresh_dirs_editor()
end

--- 打开目录编辑器（可增删工作目录/遮蔽目录、切换遮蔽开关）
local function _open_dirs_editor()
  if dirs_editor.win and vim.api.nvim_win_is_valid(dirs_editor.win) then
    _refresh_dirs_editor()
    return
  end
  _ensure_hl()
  dirs_editor.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[dirs_editor.buf].filetype = "neoai_sandbox_dirs"
  dirs_editor.ns = vim.api.nvim_create_namespace("NeoAISandboxDirs")
  local geom_opts = { w_ratio = 0.62, h_ratio = 0.5, fit_h = 20 }
  local geom = geometry.compute(geom_opts)
  dirs_editor.win = vim.api.nvim_open_win(dirs_editor.buf, true, {
    relative = "editor",
    width = geom.width,
    height = math.max(6, math.min(geom.height, vim.o.lines - 4)),
    col = geom.col,
    row = geom.row,
    style = "minimal",
    border = "rounded",
    title = "⚙ 目录设置（仅本会话）",
    title_pos = "center",
  })
  geometry.track(dirs_editor.win, geom_opts)
  vim.wo[dirs_editor.win].wrap = true
  vim.wo[dirs_editor.win].cursorline = true
  local function bind(mode, key, fn) vim.keymap.set(mode, key, fn, { buffer = dirs_editor.buf }) end
  for _, mode in ipairs({ "n", "i" }) do
    bind(mode, "q", function() _close_dirs_editor(); M.refresh() end)
    bind(mode, "<Esc>", function() _close_dirs_editor(); M.refresh() end)
    bind(mode, "a", function() _edit_add_dir("workspace") end)
    bind(mode, "A", function() _edit_add_dir("mask") end)
    bind(mode, "d", _edit_remove_dir)
    bind(mode, "t", function() M.toggle_mask_dirs_enabled() end)
  end
  _refresh_dirs_editor()
  pcall(vim.cmd, "stopinsert")
end

--- 逐页数据来源（阻塞类来自 approval_hub，观测类来自 provider/现取）
--- @return table ctx
local function _gather_ctx()
  local sandbox = services.use("services.sandbox")
  if not sandbox then return { items = {}, hostops = {}, traces = {}, saved = {}, rejected = {}, anomalies = {} } end
  local pending = sandbox.list_reviews({ review_state = "PENDING" })
  local items, hostops = {}, {}
  for _, it in ipairs(pending) do
    -- 按安全级别降序（高风险优先）
    if it.kind == "host_op" then hostops[#hostops + 1] = it else items[#items + 1] = it end
  end
  local function _by_risk(a, b)
    local la, lb = tonumber(a.risk_level) or 0, tonumber(b.risk_level) or 0
    if la ~= lb then return la > lb end
    return (a.created_at or 0) < (b.created_at or 0)
  end
  table.sort(items, _by_risk)
  table.sort(hostops, _by_risk)
  -- 各子读取单独 pcall：任一项异常（如某个快照元数据损坏）不应拖垮整次重绘，
  -- 否则审批窗会停在陈旧/部分状态（表现为「切回来只剩一条」）。
  local function _safe(fn, fallback)
    local ok, v = pcall(fn)
    if ok and v ~= nil then return v end
    return fallback
  end
  local traces = _safe(function() return sandbox.list_traces and sandbox.list_traces() end, {}) or {}
  local saved = _safe(function() return sandbox.list_saved and sandbox.list_saved() end, {}) or {}
  -- 可恢复的已拒绝项（显式拒绝时另存了 /tmp 副本）：供「已拒绝」区展示、u 恢复。
  local rejected = _safe(function() return sandbox.list_rejected and sandbox.list_rejected() end, {}) or {}
  -- 行为审计异常（level >= 2）：仅内存观测，供「越界/异常」页展示。
  local anomalies = _safe(function()
    return sandbox.audit_list({ min_level = 2, limit = 200 })
  end, {}) or {}
  return { items = items, hostops = hostops, traces = traces, saved = saved, rejected = rejected, anomalies = anomalies }
end

--- 各页展示计数
--- @param page string
--- @param ctx table
--- @return number
local function _page_count(page, ctx)
  if page == "files" then return #(ctx.items or {}) + #(ctx.saved or {}) + #(ctx.rejected or {}) end
  if page == "behavior" then return _hub_pending("behavior") + #(ctx.hostops or {}) end
  if page == "resource" then return _hub_pending("resource") end
  if page == "network" then return _hub_pending("network") end
  if page == "anomaly" then
    local n = 0
    for _ in ipairs(ctx.traces or {}) do n = n + 1 end
    return n + #(ctx.anomalies or {})
  end
  return 0
end

--- 构建页头（页面标签行 + 切换提示），当前页高亮。
--- @param page string
--- @param ctx table
--- @return table lines
--- @return table marks
local function _build_header(page, ctx)
  local lines, marks = { "" }, {}
  local col = 0
  local function seg(text, level)
    local start = col
    lines[1] = lines[1] .. text
    col = col + #text
    if level then marks[#marks + 1] = { line = 1, start_col = start, end_col = start + #text, level = level } end
  end
  seg("页面: ")
  local pages = _hub_pages()
  for i, p in ipairs(pages) do
    local n = _page_count(p.id, ctx)
    local text = string.format("[%d %s%s]", i, p.label, n > 0 and (" " .. n) or "")
    seg(text, p.id == page and "ai" or "note")
    if i < #pages then seg("  ") end
  end
  seg("      h/l 切换页面    q 关闭")
  lines[#lines + 1] = ""
  return lines, marks
end

--- 构建阻塞类页面（工具行为 / 资源访问 / 网络请求）。
--- @param page string
--- @param ctx table
--- @return table
local function _build_blocking_page(page, ctx)
  local lines, marks, line_to_hub, line_to_target = {}, {}, {}, {}
  local entries = _hub_list(page)
  local head = ("── %s（待批准 %d）──"):format(_page_label(page) or page, #entries)
  lines[#lines + 1] = head
  lines[#lines + 1] = "快捷键: <CR> 仅本次允许    S 本次会话允许    d 拒绝"
  lines[#lines + 1] = ""
  if #entries == 0 and not (page == "behavior" and #ctx.hostops > 0) then
    lines[#lines + 1] = "（无待批准项）"
    lines[#lines + 1] = ""
  end
  for _, e in ipairs(entries) do
    local text = string.format("[%s] %s", e.id, _one_line(e.title))
    local hln = #lines + 1
    lines[#lines + 1] = text
    line_to_hub[hln] = e.id
    marks[#marks + 1] = { line = hln, start_col = 0, end_col = #text, level = "pending1" }
    for _, d in ipairs(e.detail or {}) do
      lines[#lines + 1] = "    " .. _one_line(d)
    end
    lines[#lines + 1] = ""
  end
  -- 工具行为页并入主机操作提案（T2）：整条审批后主机 replay。
  if page == "behavior" then
    for _, item in ipairs(ctx.hostops or {}) do
      local tier = item.privilege_tier or 0
      local badge = tier > 0 and string.format(" [T%d]", tier) or ""
      local risk_badge = ""
      if item.risk_level ~= nil then
        risk_badge = string.format(" [%s]%s", _risk_badge(item.risk_level), _risk_label(item.risk_level))
      end
      local cmd = _one_line((item.write_set and item.write_set[1]) or "?")
      local base = _one_line(string.format("[%s] %s%s%s（主机操作）  ", item.change_set_id, item.tool or "?", badge, risk_badge))
      local hln = #lines + 1
      lines[#lines + 1] = base .. "待批准"
      line_to_target[hln] = { change_set_id = item.change_set_id, host_op = true }
      marks[#marks + 1] = { line = hln, start_col = #base, end_col = #base + #"待批准", level = _pending_hl(item) }
      local text = "  $ " .. cmd
      local ln = #lines + 1
      lines[#lines + 1] = text
      line_to_target[ln] = { change_set_id = item.change_set_id, host_op = true }
      marks[#marks + 1] = { line = ln, start_col = 2, end_col = 2 + #cmd, level = "system" }
      lines[#lines + 1] = ""
    end
  end
  -- 资源访问页追加「目录设置」区（工作目录 / 遮蔽目录，仅本会话；E 编辑）。
  if page == "resource" then
    local ds_lines, ds_marks = _build_dirs_section()
    for _, l in ipairs(ds_lines) do lines[#lines + 1] = l end
    local off = #lines - #ds_lines
    for _, m in ipairs(ds_marks) do
      marks[#marks + 1] = { line = m.line + off, start_col = m.start_col, end_col = m.end_col, level = m.level }
    end
  end
  return { lines = lines, marks = marks, line_to_hub = line_to_hub, line_to_target = line_to_target }
end

--- 构建「越界/异常」页：越界访问留痕（按文件，只读）+ 越界命令（命令 → 文件，只读）
--- + 行为审计异常（只读）。
--- @param ctx table
--- @return table
local function _build_anomaly_page(ctx)
  local lines, marks, line_to_trace, line_to_cmd = {}, {}, {}, {}
  local lvl_ctx = { cwd = _canon_base(vim.fn.getcwd()), home = _canon_base(vim.fn.expand("~")) }
  -- === 越界访问留痕（按文件路径合并）===
  lines[#lines + 1] = "── 越界访问留痕（工作区外，仅记录，i 查看文件涉及的命令）──"
  local grouped = _group_traces(ctx.traces or {})
  if #grouped == 0 then
    lines[#lines + 1] = "（无）"
  end
  for _, tr in ipairs(grouped) do
    local path = _one_line(tr.path or "")
    local tool = _one_line(table.concat(tr.tools or { tr.tool or "?" }, ", "))
    if tool == "" then tool = "?" end
    local cmds = tr.commands or {}
    local suffix = ""
    if #cmds == 1 then
      suffix = "  ⟵ " .. _one_line(cmds[1])
    elseif #cmds > 1 then
      suffix = string.format("  ⟵ %d 条命令", #cmds)
    end
    local text = string.format("  [%s] %s%s", tool, path, suffix)
    local ln = #lines + 1
    lines[#lines + 1] = text
    local start_col = 2 + #tool + 3
    marks[#marks + 1] = { line = ln, start_col = start_col, end_col = start_col + #path, level = M.level_of(path, lvl_ctx) }
    line_to_trace[ln] = path
  end
  lines[#lines + 1] = ""
  -- === 越界命令（命令 → 涉及文件）===
  lines[#lines + 1] = "── 越界命令（命令 → 涉及文件，i 查看该命令涉及的文件）──"
  local by_cmd = _group_traces_by_command(ctx.traces or {})
  if #by_cmd == 0 then
    lines[#lines + 1] = "（无）"
  end
  for _, g in ipairs(by_cmd) do
    local nfiles = #(g.files or {})
    local label = g.command and ("$ " .. _one_line(g.command)) or "（非命令工具访问）"
    local text = string.format("  %s  → %d 个文件", label, nfiles)
    local ln = #lines + 1
    lines[#lines + 1] = text
    marks[#marks + 1] = { line = ln, start_col = 0, end_col = #text, level = "pending" }
    line_to_cmd[ln] = { command = g.command }
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "── 行为审计异常（L2+，仅记录）──"
  local anom = ctx.anomalies or {}
  if #anom == 0 then
    lines[#lines + 1] = "（无）"
  end
  for _, e in ipairs(anom) do
    local reasons = _one_line(table.concat(_merge_reasons(e.reasons or {}), ", "))
    local text = string.format("  [L%d] %s %s%s", tonumber(e.level) or 0, _one_line(e.kind or "?"),
      _one_line(e.tool or ""), reasons ~= "" and ("  " .. reasons) or "")
    local ln = #lines + 1
    lines[#lines + 1] = text
    marks[#marks + 1] = { line = ln, start_col = 0, end_col = #text, level = _risk_hl(e.level) }
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "快捷键: i 查看越界详情    h/l 切换页面    q 关闭"
  return { lines = lines, marks = marks, line_to_trace = line_to_trace, line_to_cmd = line_to_cmd }
end

--- 当前页是否阻塞类
--- @param page string|nil
--- @return boolean
local function _is_blocking_page(page)
  return page == "behavior" or page == "resource" or page == "network"
end

--- 切换页面（delta=-1 上一页 / +1 下一页，环绕）。
--- @param delta number
local function _switch_page(delta)
  local pages = _hub_pages()
  local n = #pages
  if n == 0 then return end
  local cur = 1
  for i, p in ipairs(pages) do if p.id == state.page then cur = i end end
  cur = ((cur - 1 + delta) % n + n) % n + 1
  state.page = pages[cur].id
  state.last_target = nil
  state.last_cursor = nil
  M.refresh()
end

--- 阻塞类页面：对光标所在审批条目做决策（allow_once / allow_session / deny）。
--- 工具行为页可能同时含主机操作提案（line_to_target），一并处理。
--- @param value string
local function _blocking_decide(value)
  local ln = vim.api.nvim_win_get_cursor(0)[1]
  local id = state.line_to_hub and state.line_to_hub[ln]
  if id then
    if _hub_resolve(id, value) then
      vim.notify(("[NeoAI] 审批: %s"):format(value), vim.log.levels.INFO)
      _schedule_refresh()
    end
    return
  end
  local tgt = state.line_to_target and state.line_to_target[ln]
  if tgt and tgt.host_op then
    if value == "deny" then _reject_current() else _apply_current() end
    return
  end
  vim.notify("[NeoAI] 请将光标移到待批准的条目行", vim.log.levels.WARN)
end

--- 资源访问页便捷键：把光标所在条目命中的遮蔽路径加入工作目录列表。
local function _add_masked_to_workspace()
  local ln = vim.api.nvim_win_get_cursor(0)[1]
  local id = state.line_to_hub and state.line_to_hub[ln]
  local entry = id and _hub_get(id)
  local masked = entry and entry.meta and entry.meta.masked
  if not masked then
    vim.notify("[NeoAI] 光标所在条目没有可加入工作目录的遮蔽路径", vim.log.levels.WARN)
    return
  end
  local ok, err = M.add_dir("workspace", masked)
  if ok then
    vim.notify("[NeoAI] 已加入工作目录: " .. _norm_dir(masked), vim.log.levels.INFO)
    _schedule_refresh()
  else
    vim.notify("[NeoAI] 加入失败: " .. tostring(err or ""), vim.log.levels.WARN)
  end
end

-- ========== 目录管理公开 API（资源访问页，仅本会话） ==========

--- 当前目录快照（工作目录 / 遮蔽目录 / 遮蔽开关 / read_all）
--- @return table { workspace, mask, mask_enabled, read_all }
function M.list_dirs()
  return _dirs_snapshot()
end

--- 新增目录到工作目录或遮蔽目录列表（仅当前会话；自动规范化 + 去重）
--- @param kind string "workspace" | "mask"
--- @param path string
--- @return boolean, string|nil err
function M.add_dir(kind, path)
  if kind ~= "workspace" and kind ~= "mask" then return false, "未知目录类型" end
  if type(path) ~= "string" or path == "" then return false, "路径为空" end
  local abs = _norm_dir(path)
  if abs == "" then return false, "路径无效" end
  local cfg = require("NeoAI.kernel.config_store")
  local key = kind == "workspace" and CFG_DIRS_WS or CFG_DIRS_MASK
  local list = vim.deepcopy(cfg.get(key) or {})
  for _, d in ipairs(list) do
    if _norm_dir(d) == abs then return false, "目录已存在" end
  end
  list[#list + 1] = abs
  cfg.set(key, list)
  return true
end

--- 从工作目录或遮蔽目录列表移除一项（按 1-based 序号；仅当前会话）
--- @param kind string "workspace" | "mask"
--- @param index number
--- @return boolean, string|nil err
function M.remove_dir(kind, index)
  if kind ~= "workspace" and kind ~= "mask" then return false, "未知目录类型" end
  local key = kind == "workspace" and CFG_DIRS_WS or CFG_DIRS_MASK
  local cfg = require("NeoAI.kernel.config_store")
  local list = vim.deepcopy(cfg.get(key) or {})
  local i = tonumber(index)
  if not i or i < 1 or i > #list then return false, "序号越界" end
  table.remove(list, i)
  cfg.set(key, list)
  return true
end

--- 切换遮蔽目录总开关（仅当前会话）
--- @return boolean 新状态
function M.toggle_mask_dirs_enabled()
  local cfg = require("NeoAI.kernel.config_store")
  local new = not (cfg.get(CFG_MASK_ENABLED) ~= false)
  cfg.set(CFG_MASK_ENABLED, new)
  vim.notify("[NeoAI] 遮蔽目录已 " .. (new and "开启" or "关闭"), vim.log.levels.INFO)
  return new
end

--- 打开目录编辑器（公开，供键位/命令/测试调用）
function M.open_dirs_editor()
  _open_dirs_editor()
end

--- 获取目录编辑器 buffer（测试用）
--- @return number|nil
function M.get_dirs_editor_buf()
  return dirs_editor.buf
end

--- 由审批分流中心拉起/刷新窗口并切页。
--- @param page string|nil
function M.open_page(page)
  if page and _page_label(page) then state.page = page end
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    M.refresh()
  else
    M.open()
  end
end

--- 注册审批分流中心窗口（ui/init.lua 调用）。
--- 沙箱服务属 phase 2、UI 属 phase 1：UI 初始化时沙箱尚未就绪，直接 `_sb()` 会得到 nil。
--- 经 `services.wait` 延迟登记（就绪即回调），保证审批悬浮窗的事件订阅/刷新最终注册。
function M.setup()
  if state.unwait then state.unwait() end
  state.unwait = services.wait("services.sandbox", function(sb)
    if not sb or not sb.set_hub_ui then return end
    sb.set_hub_ui({
      refresh = function()
        if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then _schedule_refresh() end
      end,
      open_page = function(page)
        M.open_page(page)
      end,
    })
  end)
end

-- ========== 公开 API ==========

--- 打开待审审批界面
function M.open()
  local sandbox = services.use("services.sandbox")
  if not sandbox then
    vim.notify("[NeoAI] 沙箱服务未启用", vim.log.levels.WARN)
    return
  end
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    M.refresh()
    return
  end
  -- 无待审/审批/留痕事项时同样打开窗口（展示空界面并订阅事件，新事项到达时自动刷新），
  -- 不再提前返回、也不再弹「无事项」提示。
  local ctx = _gather_ctx()
  _ensure_hl()
  _watch()

  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].filetype = "neoai_sandbox_review"
  state.ns = vim.api.nvim_create_namespace("NeoAISandboxReview")
  local base_geom_opts = { w_ratio = 0.70, h_ratio = 0.65 }
  local base_geom = geometry.compute(base_geom_opts)
  local width = base_geom.width
  local height = base_geom.height
  -- 恢复上次窗口几何（若仍可用），否则居中。
  local col = base_geom.col
  local row = base_geom.row
  local g = state.geom
  if g and type(g.col) == "number" and type(g.row) == "number" then
    if geometry.narrow_active() then
      -- 窄屏留白：宽度/列由基准窗口（聊天主窗口）规则决定，不用旧几何覆盖，
      -- 否则会「还是原来的大小」；仅恢复纵向位置。
      row = math.max(0, math.min(g.row, math.max(0, vim.o.lines - height - 2)))
    else
      local max_col = math.max(0, vim.o.columns - (g.width or width))
      local max_row = math.max(0, vim.o.lines - (g.height or height) - 2)
      col = math.max(0, math.min(g.col, max_col))
      row = math.max(0, math.min(g.row, max_row))
      width = math.min(g.width or width, vim.o.columns - 4)
      height = math.min(g.height or height, vim.o.lines - 4)
    end
  end
  state.win_id = vim.api.nvim_open_win(state.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = col,
    row = row,
    style = "minimal",
    border = "rounded",
    title = "🗂 沙箱待审/已保存",
    title_pos = "center",
  })
  geometry.track(state.win_id, base_geom_opts)
  -- 自动换行：AI 审计结论 / diff 等长文本按窗口宽度折行显示（CJK 按字断行）。
  vim.wo[state.win_id].wrap = true
  vim.wo[state.win_id].linebreak = true
  -- 「已应用」区两级折叠：区标题一级 / 条目头行二级，foldlevel=0 使已应用区默认整体收起。
  -- 显式开启 foldenable，免受用户全局 foldenable=false 影响；foldexpr 用全局函数引用。
  _G.NeoAISandboxReviewFoldExpr = _fold_expr
  _G.NeoAISandboxReviewFoldText = _fold_text
  vim.wo[state.win_id].foldenable = true
  vim.wo[state.win_id].foldmethod = "expr"
  vim.wo[state.win_id].foldexpr = "v:lua.NeoAISandboxReviewFoldExpr()"
  vim.wo[state.win_id].foldtext = "v:lua.NeoAISandboxReviewFoldText()"
  vim.wo[state.win_id].foldlevel = 0
  vim.wo[state.win_id].foldminlines = 0

  vim.keymap.set("n", "q", function() M.close() end, { buffer = state.buf })
  vim.keymap.set("n", "<Esc>", function() M.close() end, { buffer = state.buf })
  -- 多级页面切换（左右 / hl）
  vim.keymap.set("n", "h", function() _switch_page(-1) end, { buffer = state.buf, desc = "NeoAI 上一审批页" })
  vim.keymap.set("n", "l", function() _switch_page(1) end, { buffer = state.buf, desc = "NeoAI 下一审批页" })
  vim.keymap.set("n", "<Left>", function() _switch_page(-1) end, { buffer = state.buf })
  vim.keymap.set("n", "<Right>", function() _switch_page(1) end, { buffer = state.buf })
  -- <CR>/d：阻塞类页面用于允许/拒绝该审批条目；「待修改」页用于应用/拒绝文件。
  vim.keymap.set("n", "<CR>", function()
    if _is_blocking_page(state.page) then return _blocking_decide("allow_once") end
    _apply_current()
  end, { buffer = state.buf })
  vim.keymap.set("n", "S", function()
    if _is_blocking_page(state.page) then return _blocking_decide("allow_session") end
  end, { buffer = state.buf, desc = "NeoAI 本次会话允许该审批" })
  vim.keymap.set("n", "A", _apply_all_workspace, { buffer = state.buf, desc = "NeoAI 一键同意全部工作区修改" })
  vim.keymap.set("n", "d", function()
    if _is_blocking_page(state.page) then return _blocking_decide("deny") end
    _reject_current()
  end, { buffer = state.buf })
  vim.keymap.set("n", "i", _open_diff_current, { buffer = state.buf })
  vim.keymap.set("n", "u", _undo_current, { buffer = state.buf, desc = "NeoAI 撤销保存/恢复已拒绝（回到待审）" })
  -- R：把合并冲突条目交给 AI（基于当前真实内容重做，不覆盖外部改动）。
  vim.keymap.set("n", "R", _resolve_conflict_current, { buffer = state.buf, desc = "NeoAI 合并冲突交给 AI 重做" })
  -- E：打开目录设置（工作目录 / 遮蔽目录，仅本会话）；W：资源访问页把光标条目的遮蔽路径加入工作目录。
  vim.keymap.set("n", "E", function() M.open_dirs_editor() end, { buffer = state.buf, desc = "NeoAI 目录设置" })
  vim.keymap.set("n", "W", function() _add_masked_to_workspace() end, { buffer = state.buf, desc = "NeoAI 遮蔽路径加入工作目录" })
  -- AI 审计（可配置按键；默认 a）
  local ai_cfg = require("NeoAI.kernel.config_store").get("tools.sandbox.review.ai_audit") or {}
  if ai_cfg.enabled ~= false then
    vim.keymap.set("n", ai_cfg.key or "a", function() _ai_audit() end,
      { buffer = state.buf, desc = "NeoAI AI 审计待审变更" })
  end

  M.refresh()
  -- 自动 AI 审计（tools.sandbox.review.ai_audit.auto，默认关闭）：集合变化时自动重审。
  if ai_cfg.enabled ~= false and ai_cfg.auto == true then
    if state.audit_sig ~= _pending_sig(ctx.items) then
      _ai_audit({ silent = true })
    end
  end
end

--- 重新拉取待审列表并重绘（无待审/审批/留痕事项时保持窗口、渲染空界面）
function M.refresh()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then return end
  local sandbox = services.use("services.sandbox")
  if not sandbox then return end
  -- 重绘前记录当前光标位置与目标（刷新/重开时尽量回到原处）。
  -- 仅在已有映射（非首次绘制）时记录，避免首次打开时用默认光标覆盖待恢复位置。
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) and next(state.line_to_target) then
    pcall(function()
      local pos = vim.api.nvim_win_get_cursor(state.win_id)
      state.last_cursor = { line = pos[1], col = pos[2] }
      state.last_target = state.line_to_target[pos[1]]
    end)
  end
  local ctx = _gather_ctx()
  -- 无待审/审批/留痕事项时不再提示、也不再自动关闭：保持窗口并渲染空界面，
  -- 新事项到达时仍由事件订阅自动刷新。
  -- 待审集合变化：作废已完成的审计（避免展示过期结论；自动模式下 open 会重审）。
  local sig = _pending_sig(ctx.items)
  if state.audit and not state.audit.pending and state.audit_sig and state.audit_sig ~= sig then
    state.audit = nil
    state.audit_sig = nil
  end
  local header_lines, header_marks = _build_header(state.page, ctx)
  local body
  if state.page == "anomaly" then
    body = _build_anomaly_page(ctx)
  elseif _is_blocking_page(state.page) then
    body = _build_blocking_page(state.page, ctx)
  else
    -- 「待修改」页：越界留痕/异常移入「越界/异常」页，故此处 traces 传 nil。
    body = M.build_lines(ctx.items, nil, state.audit, ctx.saved, ctx.rejected)
  end
  local lines = {}
  for _, l in ipairs(header_lines) do lines[#lines + 1] = l end
  local offset = #header_lines
  for _, l in ipairs(body.lines or {}) do lines[#lines + 1] = l end
  local marks = {}
  for _, m in ipairs(header_marks) do marks[#marks + 1] = m end
  for _, m in ipairs(body.marks or {}) do
    marks[#marks + 1] = { line = m.line + offset, start_col = m.start_col, end_col = m.end_col, level = m.level }
  end
  local function _shift(src)
    local out = {}
    for ln, v in pairs(src or {}) do out[ln + offset] = v end
    return out
  end
  -- 折叠级别必须在写 buffer 前更新：写行后 nvim 会立即按 foldexpr 求值。
  state.fold_levels = _shift(body.fold_levels)
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  state.line_to_target = _shift(body.line_to_target)
  state.line_to_trace = _shift(body.line_to_trace)
  state.line_to_cmd = _shift(body.line_to_cmd)
  state.line_to_hub = _shift(body.line_to_hub)
  vim.api.nvim_buf_clear_namespace(state.buf, state.ns, 0, -1)
  for _, m in ipairs(marks) do
    if LEVEL_HL[m.level] then
      vim.api.nvim_buf_add_highlight(state.buf, state.ns, LEVEL_HL[m.level], m.line - 1, m.start_col, m.end_col)
    end
  end
  _set_review_title(("🗂 沙箱审批 · %s"):format(_page_label(state.page) or ""))
  -- 恢复光标：仅「待修改」页按目标条目恢复；其余页回到顶部。
  local restore = nil
  local lt = state.last_target
  if state.page == "files" and lt then
    for ln, tgt in pairs(state.line_to_target) do
      -- 匹配需包含全部目标类型标志（whole/saved/rejected/host_op）：应用/拒绝后条目会移入
      -- 「已应用」/「已拒绝」区，目标类型随之变化，此处的严格匹配会失败（见下方回退）。
      if tgt.change_set_id == lt.change_set_id
        and tgt.path == lt.path
        and tgt.host_op == lt.host_op
        and tgt.whole == lt.whole
        and tgt.saved == lt.saved
        and tgt.rejected == lt.rejected then
        restore = ln
      end
    end
  end
  -- 未匹配（如刚应用/拒绝：条目已移区）时回退到此前记录的行号，使光标**原地不动**，
  -- 不再随条目跳到「已应用」/「已拒绝」区。
  if not restore and state.page == "files" and state.last_cursor then
    restore = math.max(1, math.min(state.last_cursor.line, #lines))
  end
  if restore and state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    pcall(vim.api.nvim_win_set_cursor, state.win_id, {
      restore, (state.last_cursor and state.last_cursor.col) or 0,
    })
  end
end

--- 关闭界面
function M.close()
  _unwatch()
  _close_dirs_editor()
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    -- 关闭前记录光标/目标/几何，供下次打开恢复。
    pcall(function()
      local pos = vim.api.nvim_win_get_cursor(state.win_id)
      state.last_cursor = { line = pos[1], col = pos[2] }
      state.last_target = state.line_to_target[pos[1]]
      local cfg = vim.api.nvim_win_get_config(state.win_id)
      state.geom = {
        col = cfg.col, row = cfg.row, width = cfg.width, height = cfg.height,
      }
    end)
    pcall(vim.api.nvim_win_close, state.win_id, true)
  end
  geometry.untrack(state.win_id)
  state.win_id = nil
  state.buf = nil
  state.ns = nil
  state.line_to_target = {}
  state.line_to_hub = {}
  state.line_to_trace = {}
  state.line_to_cmd = {}
  state.fold_levels = {}
  -- 作废在途 AI 审计结果；保留已完成结论（diff 预览返回/重开时复用，集合变化时由 refresh 清除）。
  state.audit_seq = state.audit_seq + 1
end

--- 获取当前 buffer（测试用）
--- @return number|nil
function M.get_buf()
  return state.buf
end

--- 获取行号到目标的映射（测试用）
--- @return table
function M.get_line_map()
  return state.line_to_target
end

--- 应用后折叠整个审批窗：任何应用操作成功后，把折叠级别复位到 0（整体收起）并关闭所有
--- 手动 za/zo 打开的折叠，使「已应用」区回到默认整体收起，避免自动展开把用户正在查看的
--- 位置顶走。「已应用」区两级折叠（区标题一级 / 条目头行二级），foldlevel=0 即整区收起；
--- 用户仍可随时 za/zo 再展开。
function M.fold_all()
  if not (state.win_id and vim.api.nvim_win_is_valid(state.win_id)) then return end
  vim.wo[state.win_id].foldlevel = 0
  pcall(vim.api.nvim_win_call, state.win_id, function()
    pcall(vim.cmd, "silent! normal! zM")
  end)
end

--- 获取当前审批窗折叠级别（测试用）
--- @return number|nil
function M.get_foldlevel()
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    return tonumber(vim.wo[state.win_id].foldlevel) or 0
  end
  return nil
end

--- 一键同意批量应用是否进行中（测试用）
--- @return boolean
function M.is_applying_all()
  return state.applying_all
end

--- 获取当前 diff 预览 buffer（测试用）
--- @return number|nil
function M.get_diff_buf()
  return state.diff and state.diff.buf or nil
end

--- 获取 root 提权确认弹窗 buffer（测试用）
--- @return number|nil
function M.get_root_prompt_buf()
  return root_prompt.buf
end

--- 预览光标所在条目的修改 diff（公开，供键位/测试调用）
function M.preview_current()
  _open_diff_current()
end

--- 关闭当前 diff 预览（测试用）
function M.close_diff()
  _close_diff()
end

--- 重置（测试用）
function M.reset()
  state.suspended = false
  state.audit = nil
  state.audit_sig = nil
  state.audit_seq = state.audit_seq + 1
  state.fold_levels = {}
  state.page = "files"
  state.line_to_hub = {}
  if state.unwait then
    pcall(state.unwait)
    state.unwait = nil
  end
  pcall(function() local sb = _sb(); if sb then sb.reset_approval_hub() end end)
  _close_root_prompt()
  _close_dirs_editor()
  _close_diff()
  M.close()
end

return M

