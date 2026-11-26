--- 可选安全依赖管理面板
--- @module 'NeoAI.ui.components.deps_panel'
---
--- `:NeoAI Deps` 打开：列出可选依赖状态，空格选择，a 安装，R 刷新，q 关闭。
--- 安装前展示精确 argv 并要求确认；实际安装经 `services.deps` 在终端 split 中执行。

local services = require("NeoAI.kernel.services")

local M = {}

local state = {
  win = nil,
  buf = nil,
  items = {},
  selected = {},
  lines = {},
}

local function _svc()
  return services.use("services.deps")
end

local function _close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  state.win = nil
  state.buf = nil
  state.items = {}
  state.selected = {}
  state.lines = {}
end

local function _render()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end
  local svc = _svc()
  local list = svc and svc.status() or {}
  state.items = list
  local lines = {
    "NeoAI 可选安全依赖（空格选择，a 安装，R 刷新，q 关闭）",
    "──────────────────────────────────────────────────────────────",
  }
  local group = nil
  for _, dep in ipairs(list) do
    if dep.group ~= group then
      group = dep.group
      lines[#lines + 1] = ""
      lines[#lines + 1] = "[" .. tostring(group) .. "]"
    end
    local mark = state.selected[dep.id] and "[x]" or "[ ]"
    local status = dep.installed and "ok" or ("missing: " .. table.concat(dep.missing_bins or {}, ","))
    if dep.manual then status = dep.installed and "ok（手动安装）" or "需按官方文档手动安装" end
    lines[#lines + 1] = string.format("%s %-28s %-30s %s", mark, dep.label, status, dep.tier_hint or "")
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "说明：安装来自发行版仓库；不会安装 docker，也不会自动 sudo（非 root 会在终端请求密码）。"
  state.lines = lines
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
end

local function _current_dep()
  local row = vim.api.nvim_win_get_cursor(state.win)[1]
  local line = state.lines[row] or ""
  local label = line:match("^%[[ x]%]%s+(.-)%s+ok") or line:match("^%[[ x]%]%s+(.-)%s+missing:")
    or line:match("^%[[ x]%]%s+(.-)%s+需按")
  if not label then return nil end
  for _, dep in ipairs(state.items) do
    if dep.label == label then return dep end
  end
  return nil
end

local function _install()
  local svc = _svc()
  if not svc then
    vim.notify("[NeoAI] 依赖服务不可用", vim.log.levels.ERROR)
    return
  end
  local ids = {}
  for id, on in pairs(state.selected) do
    if on then ids[#ids + 1] = id end
  end
  if #ids == 0 then
    vim.notify("[NeoAI] 请先选择依赖", vim.log.levels.WARN)
    return
  end
  table.sort(ids)
  local plan, err = svc.plan(ids)
  if not plan then
    vim.notify("[NeoAI] 无法生成安装计划：" .. tostring(err), vim.log.levels.ERROR)
    return
  end
  local msg = "即将执行：\n" .. svc.command_string(plan)
  if #plan.manual > 0 then
    msg = msg .. "\n\n以下依赖需手动安装：" .. table.concat(plan.manual, ", ")
  end
  if vim.fn.confirm(msg .. "\n\n继续？", "&Yes\n&No", 2) ~= 1 then return end
  _close()
  svc.run_terminal(plan, {
    on_done = function(ok, code)
      vim.schedule(function()
        if ok then
          vim.notify("[NeoAI] 依赖安装完成；重新探测能力中…", vim.log.levels.INFO)
        else
          vim.notify("[NeoAI] 依赖安装失败（exit " .. tostring(code) .. "）", vim.log.levels.ERROR)
        end
      end)
    end,
  })
end

-- ========== 公开 API ==========

--- 打开面板。
function M.open()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win)
    _render()
    return
  end
  local buf = vim.api.nvim_create_buf(false, true)
  local width = math.min(110, math.max(80, vim.o.columns - 10))
  local height = math.min(30, math.max(12, vim.o.lines - 6))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(1, math.floor((vim.o.lines - height) / 2)),
    col = math.max(1, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = " NeoAI Deps ",
  })
  state.buf = buf
  state.win = win
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "neoai_deps"

  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  map("q", _close)
  map("<Esc>", _close)
  map("R", _render)
  map("<Space>", function()
    local dep = _current_dep()
    if dep then
      state.selected[dep.id] = not state.selected[dep.id]
      _render()
    end
  end)
  map("a", _install)
  map("<CR>", function()
    local dep = _current_dep()
    if dep then
      state.selected[dep.id] = not state.selected[dep.id]
      _render()
    end
  end)

  _render()
end

--- 关闭（测试/卸载）。
function M.close()
  _close()
end

return M
