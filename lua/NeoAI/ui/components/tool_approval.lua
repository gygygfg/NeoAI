--- 工具审批弹窗
--- @module NeoAI.ui.components.tool_approval
--- 工具执行审批 UI。注册到 tool_service。

local tool_service = require("NeoAI.services.tool_service")

local M = {}

-- ========== 私有状态 ==========

local state = {
  win_id = nil,
  buf = nil,
  on_confirm = nil,
  on_cancel = nil,
  on_confirm_all = nil,
}

-- ========== 私有函数 ==========

local function _close()
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    pcall(vim.api.nvim_win_close, state.win_id, true)
  end
  state.win_id = nil
  state.buf = nil
  state.on_confirm = nil
  state.on_cancel = nil
  state.on_confirm_all = nil
end

--- 按键显示名（<CR>/<Esc> 等转为可读文本）
--- @param key string
--- @return string
local function _key_label(key)
  key = key or ""
  key = key:gsub("<CR>", "回车"):gsub("<Esc>", "Esc"):gsub("<Leader>", "<leader>")
  return key
end

--- 生成按键提示行（与 _set_keymaps 使用同一套配置与默认值）
--- @return table 行数组
local function _hint_lines()
  local config = require("NeoAI.kernel.config_store")
  local cfg = (config.get("keymaps.chat.approval") or {})
  local defs = {
    { conf = cfg.confirm, key = "<CR>", desc = "允许一次" },
    { conf = cfg.confirm_all, key = "A", desc = "允许所有" },
    { conf = cfg.cancel, key = "<Esc>", desc = "取消" },
    { conf = cfg.cancel_with_reason, key = "C", desc = "取消并说明" },
  }
  local parts = {}
  for _, d in ipairs(defs) do
    local key = (d.conf and d.conf.key) or d.key
    local desc = (d.conf and d.conf.desc) or d.desc
    parts[#parts + 1] = string.format("[%s] %s", _key_label(key), desc)
  end
  if #parts == 0 then return {} end
  return { "", "快捷键: " .. table.concat(parts, "    ") }
end

--- 设置快捷键
--- 普通模式与插入模式都绑定：弹窗打开时若用户正在输入框打字（插入模式），
--- nvim_open_win(enter=true) 会把插入模式延续到新窗口，仅普通模式映射会全部失效，
--- 导致 <CR>/A/Esc 按键被当成文本输入，审批永不回调、界面卡住。
local function _set_keymaps()
  if not state.buf then return end
  local config = require("NeoAI.kernel.config_store")
  local approval_cfg = (config.get("keymaps.chat.approval") or {})
  local k_confirm = approval_cfg.confirm and approval_cfg.confirm.key or "<CR>"
  local k_confirm_all = approval_cfg.confirm_all and approval_cfg.confirm_all.key or "A"
  local k_cancel = approval_cfg.cancel and approval_cfg.cancel.key or "<Esc>"
  local k_cancel_reason = approval_cfg.cancel_with_reason and approval_cfg.cancel_with_reason.key or "C"

  local function bind(mode, key, fn)
    if not key or key == "" then return end
    vim.keymap.set(mode, key, fn, { buffer = state.buf })
  end

  -- 先捕获回调并关窗，再调用回调：回调（如 tool_service 的串行审批队列）可能同步
  -- 打开下一个审批弹窗并重写 state.win_id；若先调用再 _close()，会把新弹窗关掉，
  -- 导致下一个工具的 Deferred 永不 settle、工具循环卡死在第一轮。
  local function close_then(cb, ...)
    local args = { ... }
    local handler = cb
    _close()
    if handler then handler(unpack(args)) end
  end

  for _, mode in ipairs({ "n", "i" }) do
    bind(mode, k_confirm, function()
      close_then(state.on_confirm)
    end)
    bind(mode, k_confirm_all, function()
      close_then(state.on_confirm_all)
    end)
    bind(mode, k_cancel, function()
      close_then(state.on_cancel, "用户取消")
    end)
    bind(mode, k_cancel_reason, function()
      close_then(state.on_cancel, "用户拒绝")
    end)
  end
end

-- ========== 公开 API ==========

--- 展示审批弹窗
--- @param config table { text, tool_name, args, on_confirm, on_cancel, on_confirm_all }
function M.show(config)
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    _close()
  end
  state.on_confirm = config.on_confirm
  state.on_cancel = config.on_cancel
  state.on_confirm_all = config.on_confirm_all

  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].filetype = "neoai_approval"
  local lines = vim.split(config.text or "", "\n", { plain = true })
  -- 末尾追加按键提示，让用户知道如何允许/拒绝
  for _, l in ipairs(_hint_lines()) do
    lines[#lines + 1] = l
  end
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)

  local height = math.min(#lines + 4, 20)
  local width = math.min(70, vim.o.columns - 10)
  local ok, wid = pcall(vim.api.nvim_open_win, state.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = "🔒 工具审批: " .. (config.tool_name or ""),
    title_pos = "center",
  })
  if not ok then
    -- 浮窗创建失败（偶发：终端 resize、状态异常等）：先清理自身状态再抛出，
    -- 由 tool_service 的审批槽位保护捕获并降级为拒绝，避免槽位残留导致工具循环卡死。
    _close()
    error("无法打开审批弹窗: " .. tostring(wid))
  end
  state.win_id = wid
  vim.wo[state.win_id].wrap = true
  -- 强制退出插入模式：弹窗打开时若用户正在输入框打字（插入模式），模式会延续到新窗口，
  -- 导致快捷键失效；只读防止误编辑弹窗内容
  pcall(vim.cmd, "stopinsert")
  vim.bo[state.buf].modifiable = false
  _set_keymaps()
end

--- 隐藏弹窗
function M.hide()
  _close()
end

--- 注册到 tool_service
function M.init()
  tool_service.set_approval_ui({
    show = M.show,
    hide = M.hide,
  })
end

--- 重置（测试用）
function M.reset()
  _close()
end

return M
