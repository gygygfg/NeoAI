--- 命令提示
--- @module 'NeoAI.ui.command_hint'
--- 为聚合命令 `:NeoAI <子命令>` 提供「子命令说明」提示。
---
--- 为什么不内嵌到补全菜单：Neovim 用户命令的 `complete=customlist` 只接受纯字符串候选，
--- 候选 dict 的 menu 字段会被忽略（见 :h :command-completion-customlist），因此 wildmenu
--- 每项无法原生附带说明。这里改为两层呈现：
---   1) 已装 nvim-cmp + cmp-cmdline 时：注册 `neoai_cmd` 补全源（提供 label/detail/
---      documentation），由 cmp 自己的 `:` 菜单展示说明。**不覆盖**用户已有 `:` 源，
---      仅提供可选项（用户可在自己的 cmp 配置里把 `{ name = "neoai_cmd" }` 加进
---      cmdline 段的 sources）。
---   2) 否则：用内置 `nvim_open_float` 展示「子命令 — 说明」，随输入高亮匹配项，
---      CmdlineLeave 关闭。
---
--- 约束：只用 Neovim 内置 API，不引入任何第三方依赖；安装返回清理函数（副作用可卸载）。

local M = {}

local HL_NS = vim.api.nvim_create_namespace("neoai_cmd_hint")
local SRC_NAME = "neoai_cmd"

-- ========== 私有状态 ==========

local state = {
  installed = false,
  aucmds = {},
  buf = nil,
  win = nil,
  mode = nil, -- "cmp" | "float" | nil
  cmp_source_registered = false,
}

-- ========== 私有函数 ==========

--- 惰性取命令插件（提供子命令表；避免重复维护名单）
--- @return table|nil
local function _commands()
  local ok, mod = pcall(require, "NeoAI.plugins.builtin.commands")
  if ok and type(mod) == "table" and type(mod.SUBCOMMANDS) == "table" then return mod end
  return nil
end

--- 按当前命令行取匹配的子命令（补全语义）
--- 支持两种输入形态：`NeoAI`（未输入空格，视为空前缀）与 `NeoAI <前缀>`。
--- @param cmdline string 完整命令行（不含前导 `:`）
--- @return table 数组 { name, desc, matched }
function M.matched(cmdline)
  local commands = _commands()
  if not commands then return {} end
  local line = tostring(cmdline or ""):gsub("^%s*:?", "")
  local arglead
  if line == "NeoAI" then
    arglead = ""
  else
    arglead = line:match("^NeoAI%s+(%S*)$")
  end
  if arglead == nil then return {} end
  arglead = arglead:lower()
  local out = {}
  for _, spec in ipairs(commands.SUBCOMMANDS) do
    local hit = arglead == "" or spec.name:lower():sub(1, #arglead) == arglead
    out[#out + 1] = { name = spec.name, desc = spec.desc, matched = hit }
  end
  return out
end

--- 浮窗展示用的文本行（按声明顺序，仅匹配项；测试可直接断言）
--- @param cmdline string
--- @return table 字符串数组
function M.hint_lines(cmdline)
  local lines = {}
  for _, it in ipairs(M.matched(cmdline)) do
    if it.matched then
      lines[#lines + 1] = ("%s — %s"):format(it.name, it.desc or "")
    end
  end
  return lines
end

--- 供 cmp 源使用的补全项（label/detail/documentation 三元组）
--- @param cmdline string
--- @return table 数组 { label, detail, documentation }
function M.completion_items(cmdline)
  local out = {}
  for _, it in ipairs(M.matched(cmdline)) do
    if it.matched then
      out[#out + 1] = {
        label = it.name,
        detail = it.desc or "",
        documentation = ("`:NeoAI %s` — %s"):format(it.name, it.desc or ""),
      }
    end
  end
  return out
end

--- 定义高亮组（默认链接，可被用户配色覆盖）
local function _define_hl()
  pcall(vim.api.nvim_set_hl, 0, "NeoAICommandHintMatch", { link = "Search", default = true })
  pcall(vim.api.nvim_set_hl, 0, "NeoAICommandHintName", { link = "Title", default = true })
  pcall(vim.api.nvim_set_hl, 0, "NeoAICommandHintDesc", { link = "Comment", default = true })
end

--- 关闭提示浮窗
local function _close_float()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  state.win = nil
  state.buf = nil
end

--- 确保浮窗 buffer 存在
--- @return number|nil
local function _ensure_buf()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then return state.buf end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "neoai_command_hint"
  state.buf = buf
  return buf
end

--- 渲染并显示/更新浮窗
--- @param items table M.matched 的结果
--- @param arglead string 当前前缀（用于高亮）
local function _render_float(items, arglead)
  local lines, meta = {}, {}
  for _, it in ipairs(items) do
    if it.matched then
      lines[#lines + 1] = ("%s — %s"):format(it.name, it.desc or "")
      meta[#meta + 1] = it
    end
  end
  if #lines == 0 then
    _close_float()
    return
  end
  local buf = _ensure_buf()
  if not buf then return end

  -- 宽度按显示宽度裁剪（CJK/宽字符不会算窄），并限制在屏幕内
  local width = 10
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 1, math.max(10, vim.o.columns - 4))
  local height = #lines

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(buf, HL_NS, 0, -1)
  local lead = (arglead or ""):lower()
  for i, it in ipairs(meta) do
    local row = i - 1
    -- 子命令名整体高亮；匹配到的前缀再叠加匹配高亮
    pcall(vim.api.nvim_buf_add_highlight, buf, HL_NS, "NeoAICommandHintName", row, 0, #it.name)
    if #lead > 0 and it.name:lower():sub(1, #lead) == lead then
      pcall(vim.api.nvim_buf_add_highlight, buf, HL_NS, "NeoAICommandHintMatch", row, 0, #lead)
    end
    local desc_start = #it.name + 3 -- " — "
    pcall(vim.api.nvim_buf_add_highlight, buf, HL_NS, "NeoAICommandHintDesc", row, desc_start, -1)
  end

  local geometry = {
    relative = "editor",
    anchor = "SW",
    row = math.max(0, vim.o.lines - vim.o.cmdheight - 1),
    col = math.max(0, vim.o.columns - width - 2),
    width = width,
    height = height,
  }

  if state.win and vim.api.nvim_win_is_valid(state.win) then
    -- 复用窗口：只调整尺寸/位置，避免每次输入都重建（减少闪烁）
    pcall(vim.api.nvim_win_set_config, state.win, geometry)
    return
  end

  local ok, win = pcall(vim.api.nvim_open_win, buf, false, vim.tbl_extend("force", geometry, {
    style = "minimal",
    border = "rounded",
    focusable = false,
    noautocmd = true,
    zindex = 300,
  }))
  if ok then
    state.win = win
  else
    _close_float()
  end
end

--- CmdlineChanged 处理：按当前命令行展示提示
local function _on_cmdline_changed()
  if state.mode ~= "float" then return end
  if vim.fn.getcmdtype() ~= ":" then
    _close_float()
    return
  end
  local line = vim.fn.getcmdline()
  local items = M.matched(line)
  local any = false
  for _, it in ipairs(items) do
    if it.matched then
      any = true
      break
    end
  end
  if not any then
    _close_float()
    return
  end
  local arglead = (line:gsub("^%s*:?", ""):match("^NeoAI%s+(%S*)$")) or ""
  _render_float(items, arglead)
end

--- CmdlineLeave / 尺寸变化处理：关闭浮窗
local function _on_cmdline_leave()
  _close_float()
end

--- 尝试注册 cmp 补全源（仅在用户已装 nvim-cmp + cmp-cmdline 时）
--- @return boolean ok
local function _register_cmp_source()
  local ok_cmp, cmp = pcall(require, "cmp")
  if not ok_cmp or type(cmp) ~= "table" or type(cmp.register_source) ~= "function" then
    return false
  end
  -- 仅在用户确实启用了 cmp-cmdline（命令行补全）时复用，避免无用的全局注册。
  local ok_cli = pcall(require, "cmp-cmdline")
  if not ok_cli and package.loaded["cmp-cmdline"] == nil then
    return false
  end
  local source = {}
  function source.get_trigger_characters()
    return {}
  end
  function source.is_available()
    return vim.fn.getcmdtype() == ":"
  end
  function source.get_keyword_pattern()
    return [[\%([A-Za-z]\)\@<=\w*]]
  end
  function source.complete(_, params, callback)
    local line = (params and params.context and params.context.cursor_before_line) or vim.fn.getcmdline()
    local items = {}
    for _, it in ipairs(M.completion_items(line)) do
      items[#items + 1] = {
        label = it.label,
        insertText = it.label,
        detail = it.detail,
        documentation = { kind = "markdown", value = it.documentation },
      }
    end
    callback({ items = items, isIncomplete = false })
  end
  local ok_reg = pcall(cmp.register_source, SRC_NAME, source)
  if not ok_reg then return false end
  state.cmp_source_registered = true
  return true
end

--- 注销 cmp 补全源
local function _unregister_cmp_source()
  if not state.cmp_source_registered then return end
  state.cmp_source_registered = false
  pcall(function()
    local cmp = require("cmp")
    if type(cmp.unregister_source) == "function" then
      cmp.unregister_source(SRC_NAME)
    end
  end)
end

-- ========== 公开 API ==========

--- 安装命令提示（幂等）。返回清理函数。
--- @return function cleanup
function M.install()
  if state.installed then
    return function() M.uninstall() end
  end
  local cfg = require("NeoAI.kernel.config_store").get("ui.command_hint") or {}
  if cfg.enabled == false then
    return function() end
  end
  state.installed = true
  _define_hl()

  -- 优先复用 cmp：注册源后不再叠加浮窗（避免双菜单互相遮挡）
  state.mode = _register_cmp_source() and "cmp" or "float"

  if state.mode == "float" then
    state.aucmds[#state.aucmds + 1] = vim.api.nvim_create_autocmd("CmdlineChanged", {
      callback = function() pcall(_on_cmdline_changed) end,
    })
    state.aucmds[#state.aucmds + 1] = vim.api.nvim_create_autocmd({ "CmdlineLeave", "VimResized" }, {
      callback = function() pcall(_on_cmdline_leave) end,
    })
    state.aucmds[#state.aucmds + 1] = vim.api.nvim_create_autocmd("ColorScheme", {
      callback = function() pcall(_define_hl) end,
    })
  end

  return function() M.uninstall() end
end

--- 卸载命令提示：删除自动命令、关闭浮窗、注销 cmp 源
function M.uninstall()
  for _, id in ipairs(state.aucmds) do
    pcall(vim.api.nvim_del_autocmd, id)
  end
  state.aucmds = {}
  _close_float()
  _unregister_cmp_source()
  state.installed = false
  state.mode = nil
end

--- 当前提示形态（"cmp" | "float" | nil），诊断/测试用
--- @return string|nil
function M.mode()
  return state.mode
end

--- 重置（测试用）
function M.reset()
  M.uninstall()
end

return M
