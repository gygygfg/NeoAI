--- 沙箱待审审批界面
--- @module NeoAI.ui.components.sandbox_review
--- 列出待审变更单元，按文件路径级别高亮：
---   工作区文件=绿色 / 用户目录=黄色 / 系统路径=红色；「待审」状态标签=黄色。
--- 审批单位为单个文件：<CR> 仅应用光标所在文件 / d 仅拒绝该文件（其余文件保留待审）。
--- r 刷新 / q 关闭。
--- 经 kernel.services.use 获取 sandbox 服务，缺失时降级提示。

local services = require("NeoAI.kernel.services")

local M = {}

-- ========== 私有常量 ==========

-- 路径级别 -> 高亮组
local LEVEL_HL = {
  workspace = "NeoAISandboxReviewWorkspace",
  user = "NeoAISandboxReviewUser",
  system = "NeoAISandboxReviewSystem",
  pending = "NeoAISandboxReviewPending",
  secret = "NeoAISandboxReviewSecret",
}

local LEGEND = "级别：工作区(绿) 用户目录(黄) 系统(红)  ⚠密钥操作(红)   |   <CR> 应用该文件   d 拒绝该文件   r 刷新   q 关闭"

-- ========== 私有状态 ==========

local state = {
  win_id = nil,
  buf = nil,
  ns = nil,
  line_to_target = {}, -- 行号 -> { change_set_id, path? }
}

-- ========== 私有函数 ==========

--- 定义高亮组（default=true，用户可覆盖）
local function _ensure_hl()
  vim.api.nvim_set_hl(0, LEVEL_HL.workspace, { default = true, fg = "#98c379", bold = true })
  vim.api.nvim_set_hl(0, LEVEL_HL.user, { default = true, fg = "#e5c07b", bold = true })
  vim.api.nvim_set_hl(0, LEVEL_HL.system, { default = true, fg = "#e06c75", bold = true })
  vim.api.nvim_set_hl(0, LEVEL_HL.pending, { default = true, fg = "#e5c07b", bold = true })
  vim.api.nvim_set_hl(0, LEVEL_HL.secret, { default = true, fg = "#e06c75", bold = true, underline = true })
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
  local abs = vim.fn.fnamemodify(vim.fn.expand(p), ":p")
  return (abs:gsub("/+$", ""))
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
--- @return table { lines, marks, line_to_target }
function M.build_lines(items)
  local lines = { LEGEND, "" }
  local marks = {}
  local line_to_target = {}
  for _, item in ipairs(items or {}) do
    local tier = item.privilege_tier or 0
    local badge = tier > 0 and string.format(" [T%d]", tier) or ""
    -- 主机操作提案（T2）：展示命令，整条审批；审批后主机 replay。
    if item.kind == "host_op" then
      local cmd = _one_line((item.write_set and item.write_set[1]) or "?")
      local base = _one_line(string.format("[%s] %s%s（主机操作）  ", item.change_set_id, item.tool or "?", badge))
      local hln = #lines + 1
      lines[#lines + 1] = base .. "待审"
      marks[#marks + 1] = { line = hln, start_col = #base, end_col = #base + #"待审", level = "pending" }
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
    local base = _one_line(string.format("[%s] %s%s（%d 个文件）  ", item.change_set_id, item.tool or "?", badge, #files))
    local hln = #lines + 1
    lines[#lines + 1] = base .. "待审"
    -- 「待审」标签黄色高亮
    marks[#marks + 1] = { line = hln, start_col = #base, end_col = #base + #"待审", level = "pending" }
    -- 密钥防护警告：该变更涉及被加密映射的密钥（token 操作），红色醒目提示。
    if item.secret_warning and (item.secret_warning.count or 0) > 0 then
      local warn = string.format("  ⚠ 密钥操作×%d（内容含加密 token，应用时还原）", item.secret_warning.count)
      lines[#lines + 1] = warn
      marks[#marks + 1] = { line = #lines, start_col = 0, end_col = #warn, level = "secret" }
    end
    -- 头行为信息行，不参与审批；审批单位为下方单个文件行。

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
  -- 防御：任何元素都必须是单行字符串，否则 nvim_buf_set_lines 会报 E5108。
  for i = 1, #lines do
    if type(lines[i]) ~= "string" then lines[i] = _one_line(lines[i]) end
    if lines[i]:find("[\r\n]") then lines[i] = _one_line(lines[i]) end
  end
  return { lines = lines, marks = marks, line_to_target = line_to_target }
end

--- 应用光标所在文件（审批单位为单个文件）
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
    local res = sandbox.apply(target.change_set_id, { auto_approve = true })
    if res and res.ok then
      vim.notify(("[NeoAI] 已执行主机操作 %s"):format(target.change_set_id), vim.log.levels.WARN)
    else
      vim.notify(("[NeoAI] 主机操作失败(%s): %s"):format(tostring(res and res.state), tostring(res and res.reason)),
        vim.log.levels.ERROR)
    end
    M.refresh()
    return
  end
  if not target.path then
    vim.notify("[NeoAI] 请将光标移到要应用的文件行", vim.log.levels.WARN)
    return
  end
  local res = sandbox.apply(target.change_set_id, { auto_approve = true, files = { target.path } })
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
  if #sandbox.list_reviews({ review_state = "PENDING" }) == 0 then
    vim.notify("[NeoAI] 无待审修改", vim.log.levels.INFO)
    return
  end
  _ensure_hl()

  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].filetype = "neoai_sandbox_review"
  state.ns = vim.api.nvim_create_namespace("NeoAISandboxReview")
  local width = math.min(100, vim.o.columns - 10)
  local height = math.min(24, vim.o.lines - 8)
  state.win_id = vim.api.nvim_open_win(state.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = "🗂 沙箱待审审批",
    title_pos = "center",
  })

  vim.keymap.set("n", "q", function() M.close() end, { buffer = state.buf })
  vim.keymap.set("n", "<Esc>", function() M.close() end, { buffer = state.buf })
  vim.keymap.set("n", "<CR>", _apply_current, { buffer = state.buf })
  vim.keymap.set("n", "d", _reject_current, { buffer = state.buf })
  vim.keymap.set("n", "r", function() M.refresh() end, { buffer = state.buf })

  M.refresh()
end

--- 重新拉取待审列表并重绘（无待审时自动关闭）
function M.refresh()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then return end
  local sandbox = services.use("services.sandbox")
  if not sandbox then return end
  local items = sandbox.list_reviews({ review_state = "PENDING" })
  if #items == 0 then
    vim.notify("[NeoAI] 无待审修改", vim.log.levels.INFO)
    M.close()
    return
  end
  local data = M.build_lines(items)
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, data.lines)
  state.line_to_target = data.line_to_target
  vim.api.nvim_buf_clear_namespace(state.buf, state.ns, 0, -1)
  for _, m in ipairs(data.marks) do
    vim.api.nvim_buf_add_highlight(state.buf, state.ns, LEVEL_HL[m.level], m.line - 1, m.start_col, m.end_col)
  end
end

--- 关闭界面
function M.close()
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
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

--- 重置（测试用）
function M.reset()
  M.close()
end

return M
