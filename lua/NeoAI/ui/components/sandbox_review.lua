--- 沙箱待审审批界面
--- @module NeoAI.ui.components.sandbox_review
--- 列出待审变更单元，按文件路径级别高亮：
---   工作区文件=绿色 / 用户目录=黄色 / 系统路径=红色；「待审」状态标签=黄色。
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
  secret = "NeoAISandboxReviewSecret",
  risk0 = "NeoAISandboxReviewRisk0",
  risk1 = "NeoAISandboxReviewRisk1",
  risk2 = "NeoAISandboxReviewRisk2",
  risk3 = "NeoAISandboxReviewRisk3",
}

local LEGEND = "级别：工作区(绿) 用户目录(黄) 系统(红)  风险：L0低危/L1中危/L2·L3高危  ⚠密钥操作(红)   |   <CR> 头行=整包应用 / 文件行=应用该文件   d 拒绝该文件   i 预览修改diff   r 刷新   q 关闭"

-- L3 后果警告高亮组（diff 预览顶部）
local L3_WARN_HL = "NeoAISandboxReviewL3Warning"

-- ========== 私有状态 ==========

local state = {
  win_id = nil,
  buf = nil,
  ns = nil,
  line_to_target = {}, -- 行号 -> { change_set_id, path? }
  last_cursor = nil, -- { line, col } 关闭时记录，重开时恢复
  last_target = nil, -- { change_set_id, path? } 关闭时光标所在条目（优先恢复）
  geom = nil, -- { col, row, width, height } 窗口几何，重开时恢复
  suspended = false, -- 是否因查看 diff 临时关闭（关闭 diff 后自动重开审批窗）
  diff = nil, -- { win, buf, ns, mode, warn_start, warn_end, diff_start, width } 当前 diff 预览窗口
  pending_l3 = nil, -- { change_set_id, path } L3 二次确认中待应用的条目
  l3_seq = 0, -- L3 警告生成序号：关闭/重开 diff 后作废过期结果
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
  vim.api.nvim_set_hl(0, LEVEL_HL.secret, { default = true, fg = "#e06c75", bold = true, underline = true })
  vim.api.nvim_set_hl(0, LEVEL_HL.risk0, { default = true, fg = "#7f8c8d", bold = true })
  vim.api.nvim_set_hl(0, LEVEL_HL.risk1, { default = true, fg = "#e5c07b", bold = true })
  vim.api.nvim_set_hl(0, LEVEL_HL.risk2, { default = true, fg = "#e06c75", bold = true })
  vim.api.nvim_set_hl(0, LEVEL_HL.risk3, { default = true, fg = "#ff5555", bold = true, underline = true })
  vim.api.nvim_set_hl(0, L3_WARN_HL, { default = true, fg = "#ff5555", bold = true })
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
--- @return string "workspace" | "user" | "system"
function M.level_of(path)
  if type(path) ~= "string" or path == "" then return "system" end
  local abs = _norm(path)
  local cwd = _norm(vim.fn.getcwd())
  if _under(abs, cwd) then return "workspace" end
  local home = _norm(vim.fn.expand("~"))
  if home ~= "" and _under(abs, home) then return "user" end
  return "system"
end

--- 构建展示行与高亮标记（纯函数，测试用）
--- @param items table list_reviews 结果数组
--- @param traces table|nil 越界访问留痕数组（sandbox.list_traces）
--- @return table { lines, marks, line_to_target }
function M.build_lines(items, traces)
  local lines = { LEGEND, "" }
  local marks = {}
  local line_to_target = {}
  local risk = require("NeoAI.sandbox.risk")
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
      marks[#marks + 1] = { line = hln, start_col = #base, end_col = #base + #"待审", level = "pending" }
      if risk_badge ~= "" then
        local rb = base:find("%[L%d%]", 1)
        if rb then marks[#marks + 1] = { line = hln, start_col = rb - 1, end_col = rb + 2, level = _risk_hl(item.risk_level) } end
      end
      local text = "  $ " .. cmd
      local ln = #lines + 1
      lines[#lines + 1] = text
      marks[#marks + 1] = { line = ln, start_col = 2, end_col = 2 + #cmd, level = "system" }
      line_to_target[ln] = { change_set_id = item.change_set_id, host_op = true }
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
    end
    local base = _one_line(string.format("[%s] %s%s%s（%s%d 个文件）  ", item.change_set_id, item.tool or "?", badge, risk_badge, pkg, #files))
    local hln = #lines + 1
    lines[#lines + 1] = base .. "待审"
    -- 「待审」标签黄色高亮
    marks[#marks + 1] = { line = hln, start_col = #base, end_col = #base + #"待审", level = "pending" }
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
      marks[#marks + 1] = { line = ln, start_col = 2, end_col = 2 + #path, level = M.level_of(path) }
      line_to_target[ln] = { change_set_id = item.change_set_id, path = path }
    end
    lines[#lines + 1] = ""
    end
  end
  -- 越界访问留痕（read_all 下访问 cwd 之外用户工作目录；仅记录，非阻塞）。
  if traces and #traces > 0 then
    local head = "── 越界访问留痕（工作区外，仅记录）──"
    lines[#lines + 1] = head
    for _, tr in ipairs(traces) do
      local path = _one_line(tr.path or "")
      local tool = _one_line(tr.tool or "?")
      local text = string.format("  [%s] %s", tool, path)
      local ln = #lines + 1
      lines[#lines + 1] = text
      local start_col = 2 + #tool + 3
      marks[#marks + 1] = { line = ln, start_col = start_col, end_col = start_col + #path, level = M.level_of(path) }
    end
    lines[#lines + 1] = ""
  end
  -- 防御：任何元素都必须是单行字符串，否则 nvim_buf_set_lines 会报 E5108。
  for i = 1, #lines do
    if type(lines[i]) ~= "string" then lines[i] = _one_line(lines[i]) end
    if lines[i]:find("[\r\n]") then lines[i] = _one_line(lines[i]) end
  end
  return { lines = lines, marks = marks, line_to_target = line_to_target }
end

-- 前向声明（定义见下方 diff 预览区）
local _find_item
local _open_l3_confirm

--- 执行一次文件级应用（不刷新界面）
--- @param target table { change_set_id, path, host_op? }
--- @return table|nil sandbox.apply 结果
local function _do_apply(target)
  local sandbox = services.use("services.sandbox")
  if not sandbox then return nil end
  -- 主机操作 / 整单元（头行）：应用全部文件；文件行：仅应用该文件。
  if target.host_op or target.whole then
    return sandbox.apply(target.change_set_id, { auto_approve = true })
  end
  return sandbox.apply(target.change_set_id, { auto_approve = true, files = { target.path } })
end

--- L3 二次确认门禁是否开启
--- @return boolean
local function _l3_gate_enabled()
  local config_store = require("NeoAI.kernel.config_store")
  return config_store.get("tools.sandbox.review.l3_warning.enabled") ~= false
end

--- 应用光标所在文件（审批单位为单个文件）。
--- L3（critical）条目首次 <CR> 不直接应用：由 AI 生成后果警告并自动打开 diff，
--- 用户在 diff 内再次确认后才真正应用（q/Esc 取消）。
local function _apply_current()
  local target = state.line_to_target[vim.api.nvim_win_get_cursor(0)[1]]
  if not target then
    vim.notify("[NeoAI] 请将光标移到要应用的条目行", vim.log.levels.WARN)
    return
  end
  local sandbox = services.use("services.sandbox")
  if not sandbox then return end
  -- 主机操作提案：整条审批后在主机 replay
  if target.host_op then
    local res = _do_apply(target)
    if res and res.ok then
      vim.notify(("[NeoAI] 已执行主机操作 %s"):format(target.change_set_id), vim.log.levels.WARN)
    else
      vim.notify(("[NeoAI] 主机操作失败(%s): %s"):format(tostring(res and res.state), tostring(res and res.reason)),
        vim.log.levels.ERROR)
    end
    M.refresh()
    return
  end
  -- 整单元（头行）：一次应用该变更单元的全部文件（包安装按安装命令合并，整包一次审批）。
  local item = _find_item(target.change_set_id)
  if target.whole then
    if _l3_gate_enabled() and item and (tonumber(item.risk_level) or 0) >= 3 then
      _open_l3_confirm(target, item)
      return
    end
    local res = _do_apply(target)
    if res and res.ok then
      vim.notify(("[NeoAI] 已应用 %s（整包 %d 个文件）"):format(target.change_set_id, #(item and item.files or {})),
        vim.log.levels.INFO)
    else
      vim.notify(("[NeoAI] 应用失败(%s): %s"):format(tostring(res and res.state), tostring(res and res.reason)),
        vim.log.levels.ERROR)
    end
    M.refresh()
    return
  end
  if not target.path then
    vim.notify("[NeoAI] 请将光标移到要应用的文件行", vim.log.levels.WARN)
    return
  end
  -- L3 二次确认门禁
  if _l3_gate_enabled() and item and (tonumber(item.risk_level) or 0) >= 3 then
    _open_l3_confirm(target, item)
    return
  end
  local res = _do_apply(target)
  if res and res.ok then
    vim.notify(("[NeoAI] 已应用 %s %s"):format(target.change_set_id, target.path), vim.log.levels.INFO)
  else
    vim.notify(("[NeoAI] 应用失败(%s): %s"):format(tostring(res and res.state), tostring(res and res.reason)),
      vim.log.levels.ERROR)
  end
  M.refresh()
end

--- 拒绝光标所在文件（其余文件保留待审）
local function _reject_current()
  local target = state.line_to_target[vim.api.nvim_win_get_cursor(0)[1]]
  if not target then
    vim.notify("[NeoAI] 请将光标移到要拒绝的条目行", vim.log.levels.WARN)
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
  for _, it in ipairs(sandbox.list_reviews({ review_state = "PENDING" })) do
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

--- 构造 L3 警告区行（含标题；pending 时显示占位）
--- @param text string|nil
--- @param pending boolean
--- @param width number
--- @return table
local function _warning_lines(text, pending, width)
  local out = { "⚠ L3 严重风险操作 — 后果警告" }
  if pending then
    out[#out + 1] = "（正在生成后果警告…）"
    return out
  end
  if type(text) ~= "string" or text:gsub("%s", "") == "" then
    out[#out + 1] = "（无警告内容）"
    return out
  end
  for _, para in ipairs(vim.split(text, "\n", { plain = true })) do
    if para == "" then
      out[#out + 1] = ""
    else
      for _, l in ipairs(_wrap(para, width)) do out[#out + 1] = l end
    end
  end
  return out
end

--- 为 L3 警告区着色
--- @param buf number
--- @param ns number
--- @param start0 number|nil 0-based 起始行
--- @param count number|nil 行数
local function _paint_warning(buf, ns, start0, count)
  if start0 == nil or count == nil then return end
  for i = 0, count - 1 do
    pcall(vim.api.nvim_buf_add_highlight, buf, ns, L3_WARN_HL, start0 + i, 0, -1)
  end
end

--- 更新已打开 diff 的警告区（AI 异步返回后调用）
--- @param text string
local function _set_diff_warning(text)
  local d = state.diff
  if not d or not d.buf or not vim.api.nvim_buf_is_valid(d.buf) then return end
  if d.mode ~= "l3_confirm" or d.warn_start == nil then return end
  local wl = _warning_lines(text, false, (d.width or 80) - 4)
  vim.bo[d.buf].modifiable = true
  vim.api.nvim_buf_set_lines(d.buf, d.warn_start, d.warn_end, false, wl)
  vim.bo[d.buf].modifiable = false
  d.warn_end = d.warn_start + #wl
  local lines = vim.api.nvim_buf_get_lines(d.buf, 0, -1, false)
  vim.api.nvim_buf_clear_namespace(d.buf, d.ns, 0, -1)
  _paint_warning(d.buf, d.ns, d.warn_start, #wl)
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

--- 打开 diff 预览窗口（可选 L3 二次确认模式）
--- @param target table
--- @param item table
--- @param opts table|nil { mode?, on_confirm?, warning?, pending? }
local function _open_diff(target, item, opts)
  opts = opts or {}
  local mode = opts.mode or "preview"
  local title, before, after = _preview_data(target, item)

  -- 暂时关闭审批窗（保留光标/几何，关闭 diff 后自动重开并恢复光标）
  state.suspended = true
  M.close()

  local width = math.min(120, vim.o.columns - 8)
  local lines = {
    ("%s  %s"):format(mode == "l3_confirm" and "确认应用" or "修改预览", _one_line(title)),
  }
  if mode == "l3_confirm" then
    lines[#lines + 1] = "<CR> 确认应用    q/Esc 取消    （+ 新增  - 删除）"
  else
    lines[#lines + 1] = "q/Esc 返回审批    （+ 新增  - 删除）"
  end
  lines[#lines + 1] = ""

  local warn_start, warn_end
  if mode == "l3_confirm" then
    warn_start = #lines -- 0-based 起始（当前已有行数）
    local wl = _warning_lines(opts.warning, opts.pending == true, width - 4)
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
  _paint_warning(buf, ns, warn_start, warn_end and (warn_end - (warn_start or 0)) or nil)
  _paint_diff(buf, ns, lines, diff_start)

  local height = math.min(30, vim.o.lines - 6)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = mode == "l3_confirm" and "⚠ L3 确认应用" or "🔍 修改预览",
    title_pos = "center",
  })
  vim.wo[win].wrap = true
  vim.keymap.set("n", "q", function() _close_diff() end, { buffer = buf })
  vim.keymap.set("n", "<Esc>", function() _close_diff() end, { buffer = buf })
  if mode == "l3_confirm" and opts.on_confirm then
    vim.keymap.set("n", "<CR>", function() opts.on_confirm() end, { buffer = buf })
  end
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf, once = true, callback = function() _close_diff() end,
  })
  state.diff = {
    win = win, buf = buf, ns = ns, mode = mode,
    warn_start = warn_start, warn_end = warn_end, diff_start = diff_start, width = width,
  }
end

--- 打开一个临时 buffer 预览光标所在条目的修改 diff（暂时关闭审批窗，关闭后自动返回）
local function _open_diff_current()
  local target = state.line_to_target[vim.api.nvim_win_get_cursor(0)[1]]
  if not target then
    vim.notify("[NeoAI] 请将光标移到要预览的条目行", vim.log.levels.WARN)
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
  if res and res.ok then
    vim.notify(("[NeoAI] 已应用 %s %s"):format(p.change_set_id, p.path or ""), vim.log.levels.INFO)
  else
    vim.notify(("[NeoAI] 应用失败(%s): %s"):format(tostring(res and res.state), tostring(res and res.reason)),
      vim.log.levels.ERROR)
  end
  _close_diff()
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
  if #sandbox.list_reviews({ review_state = "PENDING" }) == 0 and #traces == 0 then
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
    title = "🗂 沙箱待审审批",
    title_pos = "center",
  })

  vim.keymap.set("n", "q", function() M.close() end, { buffer = state.buf })
  vim.keymap.set("n", "<Esc>", function() M.close() end, { buffer = state.buf })
  vim.keymap.set("n", "<CR>", _apply_current, { buffer = state.buf })
  vim.keymap.set("n", "d", _reject_current, { buffer = state.buf })
  vim.keymap.set("n", "i", _open_diff_current, { buffer = state.buf })
  vim.keymap.set("n", "r", function() M.refresh() end, { buffer = state.buf })

  M.refresh()
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
  if #items == 0 and #traces == 0 then
    vim.notify("[NeoAI] 无待审修改", vim.log.levels.INFO)
    M.close()
    return
  end
  -- 审批按安全级别分级：高风险优先展示。
  table.sort(items, function(a, b)
    local la, lb = tonumber(a.risk_level) or 0, tonumber(b.risk_level) or 0
    if la ~= lb then return la > lb end
    return (a.created_at or 0) < (b.created_at or 0)
  end)
  local data = M.build_lines(items, traces)
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, data.lines)
  state.line_to_target = data.line_to_target
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

--- 获取当前 diff 预览 buffer（测试用）
--- @return number|nil
function M.get_diff_buf()
  return state.diff and state.diff.buf or nil
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
  _close_diff()
  M.close()
end

return M
