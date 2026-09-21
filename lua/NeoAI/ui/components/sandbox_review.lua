--- 沙箱待审审批界面
--- @module NeoAI.ui.components.sandbox_review
--- 列出待审变更单元，按文件路径级别高亮：
---   工作区文件=绿色 / 用户目录=黄色 / 系统路径=红色；「待审」状态标签按安全等级着色
---   （L0 灰 / L1 黄 / L2 橙 / L3 红）。
---   风险徽标配色：L0 灰 / L1·L2 黄 / L3 红（仅 L3 用红色危险高亮）。
--- 审批单位为单个文件：<CR> 仅应用光标所在文件 / d 仅拒绝该文件（其余文件保留待审）。
--- r 刷新 / q 关闭。
--- 经 kernel.services.use 获取 sandbox 服务，缺失时降级提示。

local services = require("NeoAI.kernel.services")
local fs = require("NeoAI.utils.fs")

local M = {}

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

local LEGEND = "级别：工作区(绿) 用户目录(黄) 系统(红)  风险：L0低危(灰)/L1中危(黄)/L2高危(黄)/L3严重(红)  ⚠密钥操作(红)   |   <CR> 头行=整包应用 / 文件行=应用该文件   A 一键同意全部工作区修改   d 拒绝该文件   i 预览修改diff/越界详情   u 撤销/重做保存   a AI审计   r 刷新   q 关闭"

-- L3 后果警告高亮组（diff 预览顶部）
local L3_WARN_HL = "NeoAISandboxReviewL3Warning"
-- 二次确认弹窗的按键提示高亮组
local HINT_HL = "NeoAISandboxReviewConfirmHint"

-- ========== 私有状态 ==========

local state = {
  win_id = nil,
  buf = nil,
  ns = nil,
  line_to_target = {}, -- 行号 -> { change_set_id, path? }
  line_to_trace = {}, -- 行号 -> 越界留痕路径（`i` 查看详情，非审批目标）
  last_cursor = nil, -- { line, col } 关闭时记录，重开时恢复
  last_target = nil, -- { change_set_id, path? } 关闭时光标所在条目（优先恢复）
  geom = nil, -- { col, row, width, height } 窗口几何，重开时恢复
  suspended = false, -- 是否因查看 diff 临时关闭（关闭 diff 后自动重开审批窗）
  diff = nil, -- { win, buf, ns, mode, warn_start, warn_end, diff_start, width } 当前 diff 预览窗口
  pending_l3 = nil, -- { change_set_id, path } L3 二次确认中待应用的条目
  l3_seq = 0, -- L3 警告生成序号：关闭/重开 diff 后作废过期结果
  audit = nil, -- { text?, pending?, error? } AI 审计结论（显示在窗口顶部）
  audit_seq = 0, -- AI 审计请求序号：关闭/重开审批窗后作废过期结果
  audit_sig = nil, -- 已完成审计对应的待审集合签名（集合变化时自动重审）
  applying_all = false, -- 一键同意批量应用进行中（防重入；逐项让出主循环）
}

-- 安全级别 -> 中文风险档（高危 / 中危 / 低危）
local RISK_LABEL = { [0] = "低危", [1] = "中危", [2] = "高危", [3] = "高危" }

--- 安全级别对应的风险档名称
--- @param level number|nil
--- @return string
local function _risk_label(level)
  return RISK_LABEL[tonumber(level) or 0] or "低危"
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
--- @return table { lines, marks, line_to_target, line_to_trace }
function M.build_lines(items, traces, audit, saved)
  local lines = {}
  local marks = {}
  local line_to_target = {}
  local line_to_trace = {} -- 行号 -> 越界留痕路径（`i` 查看详情；非审批目标）
  -- 本次渲染复用一次 cwd/home 规范形式，避免逐文件重复 fs.canonical。
  local lvl_ctx = { cwd = _canon_base(vim.fn.getcwd()), home = _canon_base(vim.fn.expand("~")) }
  lines[#lines + 1] = LEGEND
  lines[#lines + 1] = ""
  -- AI 审计状态（生成中 / 结论 / 失败 / 兜底说明）：结论先说安全/不安全；正式说明在各自文件行下方。
  if audit and (audit.pending or audit.notes
      or (audit.error and audit.error ~= "") or (audit.fallback and audit.fallback ~= "")) then
    local status, level = nil, "note"
    if audit.pending then
      status = "🤖 AI 审计生成中…"
    elseif audit.notes then
      local verdict = require("NeoAI.sandbox.ai_audit").verdict(audit.notes)
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
    s = tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
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
  local risk = require("NeoAI.sandbox.risk")
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
      risk_badge = string.format(" [%s]%s", risk.badge(item.risk_level), _risk_label(item.risk_level))
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
    local base = _one_line(string.format("[%s] %s%s%s（%s%d 个文件）  ", item.change_set_id, item.tool or "?", badge, risk_badge, pkg, #files))
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
    -- 安全分级原因（非空时展示，便于理解为何需要审批）
    if item.risk_reasons and #item.risk_reasons > 0 then
      local reason = "  风险: " .. _one_line(table.concat(item.risk_reasons, ", "))
      lines[#lines + 1] = reason
      marks[#marks + 1] = { line = #lines, start_col = 0, end_col = #reason, level = _risk_hl(item.risk_level) }
    end
    -- 头行 = 整单元审批；下方文件行为单文件审批（可选择性只应用某个文件）。

    for _, f in ipairs(files) do
      local path = _one_line(f.path or tostring(f))
      local suffix = f.action and ("  [" .. _one_line(f.action) .. "]") or ""
      local text = "  " .. path .. suffix
      local ln = #lines + 1
      lines[#lines + 1] = text
      marks[#marks + 1] = { line = ln, start_col = 2, end_col = 2 + #path, level = M.level_of(path, lvl_ctx) }
      line_to_target[ln] = { change_set_id = item.change_set_id, path = path }
      _append_note(path)
    end
    lines[#lines + 1] = ""
    end
  end
  -- 已保存 / 已撤销（含原文件快照）：展示已发布到真实工作区的变更，`u` 撤销/重做保存
  -- （把真实文件与保存时保留的原文件快照交换，可反复切换）。
  if saved and #saved > 0 then
    -- 标题按实际状态动态展示：撤销后条目仍在（供 u 重做），但不该再显示为「已保存」。
    local has_applied, has_reverted = false, false
    for _, item in ipairs(saved) do
      if item.apply_state == "REVERTED" then has_reverted = true else has_applied = true end
    end
    local title
    if has_applied and has_reverted then
      title = "已应用（已保存/已撤销，u 撤销/重做保存）"
    elseif has_reverted then
      title = "已应用（已撤销，u 撤销/重做保存）"
    else
      title = "已应用（已保存，u 撤销/重做保存）"
    end
    lines[#lines + 1] = "── " .. title .. "──"
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
      local base = _one_line(string.format("[%s] %s（%d 个文件）  ", item.change_set_id, item.tool or "?", #files))
      local hln = #lines + 1
      lines[#lines + 1] = base .. label
      marks[#marks + 1] = { line = hln, start_col = #base, end_col = #base + #label,
        level = reverted and "pending0" or "workspace" }
      line_to_target[hln] = { change_set_id = item.change_set_id, saved = true, whole = true }
      for _, f in ipairs(files) do
        local path = _one_line(f.path or tostring(f))
        local suffix = f.action and ("  [" .. _one_line(f.action) .. "]") or ""
        local text = "  " .. path .. suffix
        local ln = #lines + 1
        lines[#lines + 1] = text
        marks[#marks + 1] = { line = ln, start_col = 2, end_col = 2 + #path, level = M.level_of(path, lvl_ctx) }
        line_to_target[ln] = { change_set_id = item.change_set_id, path = path, saved = true }
      end
      lines[#lines + 1] = ""
    end
  end
  -- 越界访问留痕（read_all 下访问 cwd 之外用户工作目录；仅记录，非阻塞）。
  -- 按文件路径合并（同一路径的多工具访问合并）、路径升序排序后展示。
  if traces and #traces > 0 then
    local grouped = require("NeoAI.sandbox.trace").group(traces)
    if #grouped > 0 then
      local head = "── 越界访问留痕（工作区外，仅记录）──"
      lines[#lines + 1] = head
      for _, tr in ipairs(grouped) do
        local path = _one_line(tr.path or "")
        local tool = _one_line(table.concat(tr.tools or { tr.tool or "?" }, ", "))
        if tool == "" then tool = "?" end
        local text = string.format("  [%s] %s", tool, path)
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
  return { lines = lines, marks = marks, line_to_target = line_to_target, line_to_trace = line_to_trace }
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

-- ========== root 提权确认弹窗 ==========

local root_prompt = { win = nil, buf = nil }

local function _close_root_prompt()
  if root_prompt.win and vim.api.nvim_win_is_valid(root_prompt.win) then
    pcall(vim.api.nvim_win_close, root_prompt.win, true)
  end
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
  local width = math.min(72, vim.o.columns - 10)
  local height = #lines + 2
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = "⚠ 需要 root 权限",
    title_pos = "center",
  })
  root_prompt.win, root_prompt.buf = win, buf
  vim.wo[win].wrap = true
  pcall(vim.cmd, "stopinsert")
  local function close_then(fn)
    _close_root_prompt()
    if fn then fn() end
  end
  local function confirm()
    close_then(function()
      retry(retry_op(prefer_sudo))
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
    elseif res and res.state == "CANCELLED" then
      vim.notify("[NeoAI] 已取消（需要 root 权限）", vim.log.levels.WARN)
    else
      vim.notify(fail_msg(res), vim.log.levels.ERROR)
    end
    M.refresh()
  end
  local res = _do_apply(target)
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
      return
    end
    i = i + 1
    local job = jobs[i]
    local opts = { auto_approve = true, files = job.files }
    if batch then opts.batch = batch end
    -- 单项异常不能中断整批并永久锁住 applying_all（否则 `A` 之后无法再用）。
    local ok, res = pcall(sandbox.apply, job.id, opts)
    if not ok then res = nil end
    if res and res.ok then
      files_n = files_n + #job.files
      items_n = items_n + 1
    else
      failed_n = failed_n + 1
      if res and res.state == "NEEDS_ROOT" then root_n = root_n + 1 end
    end
    _set_review_title(("🗂 沙箱待审/已保存（应用中 %d/%d）"):format(i, #jobs))
    vim.defer_fn(step, 0)
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
    _apply_target(target,
      function() return ("[NeoAI] 已应用 %s（整包 %d 个文件）"):format(target.change_set_id, #(item and item.files or {})) end,
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
  local sandbox = services.use("services.sandbox")
  if not sandbox then return end
  if target.host_op then
    sandbox.reject(target.change_set_id)
    vim.notify(("[NeoAI] 已拒绝主机操作 %s"):format(target.change_set_id), vim.log.levels.INFO)
    M.refresh()
    return
  end
  if target.whole then
    sandbox.reject(target.change_set_id)
    vim.notify(("[NeoAI] 已拒绝 %s（整包）"):format(target.change_set_id), vim.log.levels.INFO)
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

--- 撤销/重做保存光标所在条目：把真实文件与保存时保留的原文件快照交换。
--- 已保存 → 撤销（回滚到保存前）；已撤销 → 重新保存。冲突（真实文件被外部改动）时拒绝。
local function _undo_current()
  local target = state.line_to_target[vim.api.nvim_win_get_cursor(0)[1]]
  if not target or not target.saved then
    vim.notify("[NeoAI] 请将光标移到「已保存/已撤销」条目行", vim.log.levels.WARN)
    return
  end
  local sandbox = services.use("services.sandbox")
  if not sandbox or not sandbox.undo then return end
  local function report(res)
    if res and res.ok then
      local label = res.state == "REVERTED" and "已撤销保存" or "已重新保存"
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
  local ai_audit = require("NeoAI.sandbox.ai_audit")
  local chat = services.use("services.chat_service")
  local source_agent = chat and chat.get_current_agent() or nil
  local user_msgs = ai_audit.user_messages(source_agent)
  local agent_config = source_agent and source_agent.config or nil

  state.audit_seq = state.audit_seq + 1
  local seq = state.audit_seq
  state.audit = { pending = true }
  state.audit_sig = _pending_sig(items)
  M.refresh()
  ai_audit.generate(items, user_msgs, { agent_config = agent_config }, function(result, err)
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
    for _, para in ipairs(vim.split(text, "\n", { plain = true })) do
      if para == "" then
        out[#out + 1] = ""
      else
        for _, l in ipairs(_wrap(para, width)) do out[#out + 1] = l end
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
  -- 预览给用户看：token 还原为真实密钥（best-effort）。
  pcall(function()
    local restored = require("NeoAI.sandbox.secret").detokenize(after)
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

  local width = math.min(120, vim.o.columns - 8)
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
  for _, l in ipairs(_diff_lines(before, after)) do lines[#lines + 1] = l end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "neoai_sandbox_diff"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local ns = vim.api.nvim_create_namespace("NeoAISandboxDiff")
  _paint_warning(buf, ns, warn_start, warn_end and (warn_end - (warn_start or 0)) or nil, lines)
  _paint_diff(buf, ns, lines, diff_start)
  -- 按键提示行高亮，使确认/取消操作更醒目。
  pcall(vim.api.nvim_buf_add_highlight, buf, ns, HINT_HL, 1, 0, -1)

  local height = math.min(30, vim.o.lines - 6)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = is_confirm and confirm_title or "🔍 修改预览",
    title_pos = "center",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
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
  local width = math.min(120, vim.o.columns - 8)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "neoai_sandbox_detail"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local ns = vim.api.nvim_create_namespace("NeoAISandboxDetail")
  local height = math.min(30, vim.o.lines - 6)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.keymap.set("n", "q", function() _close_diff() end, { buffer = buf })
  vim.keymap.set("n", "<Esc>", function() _close_diff() end, { buffer = buf })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf, once = true, callback = function() _close_diff() end,
  })
  state.diff = { win = win, buf = buf, ns = ns, mode = "detail", width = width }
end

--- 查看某条越界留痕的详情：列出每次访问的工具 / 类型 / 命令 / 时间。
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
  local lines = { "越界访问详情（工作区外，仅记录）", "q/Esc 返回审批", "" }
  lines[#lines + 1] = "路径: " .. _one_line(path)
  lines[#lines + 1] = ""
  for i, tr in ipairs(entries) do
    lines[#lines + 1] = string.format("#%d  工具: %s  类型: %s", i,
      _one_line(tr.tool or "?"), _one_line(tr.kind or "read"))
    if type(tr.command) == "string" and tr.command ~= "" then
      lines[#lines + 1] = "    命令: " .. _one_line(tr.command)
    end
    if tr.created_at then
      lines[#lines + 1] = "    时间: " .. os.date("%Y-%m-%d %H:%M:%S", tonumber(tr.created_at) or os.time())
    end
    lines[#lines + 1] = ""
  end
  _open_detail_float("🔎 越界访问详情", lines)
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
  local target = state.line_to_target[line]
  if not target then
    vim.notify("[NeoAI] 请将光标移到要预览的条目行", vim.log.levels.WARN)
    return
  end
  if target.saved then
    vim.notify("[NeoAI] 已保存条目暂不支持 diff 预览", vim.log.levels.WARN)
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
  -- 整单元（头行）无具体 path：取首个文件作预览（应用仍为整单元）。
  local path = target.path
  if not path and item.files and item.files[1] then path = item.files[1].path end
  _open_diff({ change_set_id = target.change_set_id, path = path, whole = target.whole, host_op = target.host_op },
    item, { mode = "preview" })
end

--- 二次确认后应用 L3 条目
local function _confirm_l3()
  local p = state.pending_l3
  if not p then return end
  state.pending_l3 = nil
  local res = _do_apply(p)
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
  -- 整单元（头行）无具体 path：取首个文件作预览；应用仍按 target.whole 整单元。
  local path = target.path
  if not path and item and item.files and item.files[1] then path = item.files[1].path end
  state.pending_l3 = { change_set_id = target.change_set_id, path = path, whole = target.whole }
  _open_diff({ change_set_id = target.change_set_id, path = path, whole = target.whole, host_op = target.host_op },
    item, { mode = "l3_confirm", on_confirm = _confirm_l3, pending = true })
  state.l3_seq = state.l3_seq + 1
  local seq = state.l3_seq
  local l3 = require("NeoAI.sandbox.l3_warning")
  l3.generate(item, target, function(text)
    if seq ~= state.l3_seq then return end
    local d = state.diff
    if not d or d.mode ~= "l3_confirm" then return end
    _set_diff_warning(text or l3.fallback(item, target))
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
  local traces = (sandbox.list_traces and sandbox.list_traces()) or {}
  local pending = sandbox.list_reviews({ review_state = "PENDING" })
  local saved = (sandbox.list_saved and sandbox.list_saved()) or {}
  if #pending == 0 and #traces == 0 and #saved == 0 then
    vim.notify("[NeoAI] 无待审修改", vim.log.levels.INFO)
    return
  end
  _ensure_hl()

  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].filetype = "neoai_sandbox_review"
  state.ns = vim.api.nvim_create_namespace("NeoAISandboxReview")
  local width = math.min(100, vim.o.columns - 10)
  local height = math.min(24, vim.o.lines - 8)
  -- 恢复上次窗口几何（若仍可用），否则居中。
  local col = math.floor((vim.o.columns - width) / 2)
  local row = math.floor((vim.o.lines - height) / 2)
  local g = state.geom
  if g and type(g.col) == "number" and type(g.row) == "number" then
    local max_col = math.max(0, vim.o.columns - (g.width or width))
    local max_row = math.max(0, vim.o.lines - (g.height or height) - 2)
    col = math.max(0, math.min(g.col, max_col))
    row = math.max(0, math.min(g.row, max_row))
    width = math.min(g.width or width, vim.o.columns - 4)
    height = math.min(g.height or height, vim.o.lines - 4)
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
  -- 自动换行：AI 审计结论 / diff 等长文本按窗口宽度折行显示（CJK 按字断行）。
  vim.wo[state.win_id].wrap = true
  vim.wo[state.win_id].linebreak = true

  vim.keymap.set("n", "q", function() M.close() end, { buffer = state.buf })
  vim.keymap.set("n", "<Esc>", function() M.close() end, { buffer = state.buf })
  vim.keymap.set("n", "<CR>", _apply_current, { buffer = state.buf })
  vim.keymap.set("n", "A", _apply_all_workspace, { buffer = state.buf, desc = "NeoAI 一键同意全部工作区修改" })
  vim.keymap.set("n", "d", _reject_current, { buffer = state.buf })
  vim.keymap.set("n", "i", _open_diff_current, { buffer = state.buf })
  vim.keymap.set("n", "u", _undo_current, { buffer = state.buf, desc = "NeoAI 撤销/重做保存" })
  vim.keymap.set("n", "r", function() M.refresh() end, { buffer = state.buf })
  -- AI 审计（可配置按键；默认 a）
  local ai_cfg = require("NeoAI.kernel.config_store").get("tools.sandbox.review.ai_audit") or {}
  if ai_cfg.enabled ~= false then
    vim.keymap.set("n", ai_cfg.key or "a", function() _ai_audit() end,
      { buffer = state.buf, desc = "NeoAI AI 审计待审变更" })
  end

  M.refresh()
  -- 自动 AI 审计（tools.sandbox.review.ai_audit.auto，默认关闭）：集合变化时自动重审。
  if ai_cfg.enabled ~= false and ai_cfg.auto == true then
    if state.audit_sig ~= _pending_sig(pending) then
      _ai_audit({ silent = true })
    end
  end
end

--- 重新拉取待审列表并重绘（无待审时自动关闭）
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
  local items = sandbox.list_reviews({ review_state = "PENDING" })
  local traces = (sandbox.list_traces and sandbox.list_traces()) or {}
  local saved = (sandbox.list_saved and sandbox.list_saved()) or {}
  if #items == 0 and #traces == 0 and #saved == 0 then
    vim.notify("[NeoAI] 无待审修改", vim.log.levels.INFO)
    M.close()
    return
  end
  -- 待审集合变化：作废已完成的审计（避免展示过期结论；自动模式下 open 会重审）。
  local sig = _pending_sig(items)
  if state.audit and not state.audit.pending and state.audit_sig and state.audit_sig ~= sig then
    state.audit = nil
    state.audit_sig = nil
  end
  -- 审批按安全级别分级：高风险优先展示。
  table.sort(items, function(a, b)
    local la, lb = tonumber(a.risk_level) or 0, tonumber(b.risk_level) or 0
    if la ~= lb then return la > lb end
    return (a.created_at or 0) < (b.created_at or 0)
  end)
  local data = M.build_lines(items, traces, state.audit, saved)
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, data.lines)
  state.line_to_target = data.line_to_target
  state.line_to_trace = data.line_to_trace or {}
  vim.api.nvim_buf_clear_namespace(state.buf, state.ns, 0, -1)
  for _, m in ipairs(data.marks) do
    vim.api.nvim_buf_add_highlight(state.buf, state.ns, LEVEL_HL[m.level], m.line - 1, m.start_col, m.end_col)
  end
  -- 恢复光标：优先回到原目标条目，否则回到原行号（越界则夹取）。
  local restore = nil
  if state.last_target then
    for ln, tgt in pairs(state.line_to_target) do
      if tgt.change_set_id == state.last_target.change_set_id
        and tgt.path == state.last_target.path
        and tgt.host_op == state.last_target.host_op then
        restore = ln
      end
    end
  end
  if not restore and state.last_cursor then
    restore = math.max(1, math.min(state.last_cursor.line, #data.lines))
  end
  if restore and state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    pcall(vim.api.nvim_win_set_cursor, state.win_id, {
      restore, (state.last_cursor and state.last_cursor.col) or 0,
    })
  end
end

--- 关闭界面
function M.close()
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
  state.win_id = nil
  state.buf = nil
  state.ns = nil
  state.line_to_target = {}
  state.line_to_trace = {}
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
  _close_root_prompt()
  _close_diff()
  M.close()
end

return M
