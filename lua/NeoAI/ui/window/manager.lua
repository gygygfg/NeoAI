--- 窗口管理器
--- @module NeoAI.ui.window.manager
--- 管理 float/tab/split 三种模式的窗口创建/关闭/聚焦。

local config_store = require("NeoAI.kernel.config_store")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")
local geometry = require("NeoAI.ui.geometry")

local M = {}

-- ========== 私有状态 ==========

local state = {
  windows = {}, -- win_id -> { type, buf, win, mode }
  aux = {},     -- buf -> true：辅助 buffer（输入框等）登记，供会话恢复孤儿清理豁免
}

-- 各视图 buffer 的固定名称，便于 :ls 检索、:b 切换
local BUFFER_NAMES = {
  chat = "NeoAI Chat",
  tree = "NeoAI Sessions",
}

-- ========== 私有函数 ==========

--- 获取窗口配置
--- @return table
local function _window_config()
  return config_store.get("ui.window") or { w_ratio = 0.85, h_ratio = 0.85, border = "rounded" }
end

--- 统一配置 NeoAI 窗口（避免继承全局 number/signcolumn 等导致渲染杂乱）
--- @param win number
local function _configure_window(win)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].list = false
  vim.wo[win].colorcolumn = ""
  vim.wo[win].spell = false
end

--- 阻止 LSP 服务挂载到 NeoAI 界面 buffer（统一由 ui.lsp_guard 处理，覆盖所有 neoai* buffer）。
--- @param buf number
local function _disable_lsp(buf)
  require("NeoAI.ui.lsp_guard").disable(buf)
end

--- 创建浮动窗口
--- @param opts table { buf?, width?, height?, border?, title? }
--- @return number win_id, number buf_id
local function _open_float(opts)
  local cfg = _window_config()
  local border = opts.border or cfg.border or "rounded"
  local buf = opts.buf or vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = opts.filetype or "neoai"
  _disable_lsp(buf)
  -- 按屏幕比例计算尺寸（大屏更大、小屏更小），并受全局最小尺寸兜底；
  -- 用户若显式配置 ui.window.width/height，则作为比例尺寸的上限（向后兼容）。
  local geom_opts = {
    w_ratio = cfg.w_ratio or 0.85,
    h_ratio = cfg.h_ratio or 0.85,
    max_w = opts.width or cfg.width,
    max_h = opts.height or cfg.height,
    -- 主界面窗口（chat/tree）本身不套用窄屏留白规则：它是浮窗的基准，不是浮窗。
    narrow = false,
  }
  local geom = geometry.compute(geom_opts)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = geom.width,
    height = geom.height,
    col = geom.col,
    row = geom.row,
    style = "minimal",
    border = border,
    title = opts.title,
    title_pos = "center",
  })
  _configure_window(win)
  -- 登记：编辑器窗口 resize 时按比例重算跟随。
  geometry.track(win, geom_opts)
  return win, buf
end

--- 创建 tab 窗口
--- @param opts table { buf?, title? }
--- @return number win_id, number buf_id
local function _open_tab(opts)
  local buf = opts.buf or vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = opts.filetype or "neoai"
  _disable_lsp(buf)
  vim.cmd("tabnew")
  -- :tabnew 会额外创建空的 [No Name] buffer，切换后立即清理，避免污染 buffer 列表
  local temp_buf = vim.api.nvim_get_current_buf()
  if temp_buf ~= buf then
    vim.api.nvim_set_current_buf(buf)
    pcall(vim.api.nvim_buf_delete, temp_buf, { force = true })
  end
  local win = vim.api.nvim_get_current_win()
  _configure_window(win)
  return win, buf
end

--- 创建 split 窗口
--- @param opts table { buf?, direction?, size? }
--- @return number win_id, number buf_id
local function _open_split(opts)
  local split_cfg = config_store.get("ui.split") or {}
  local direction = opts.direction or split_cfg.direction or "right"
  local size = opts.size or split_cfg.size or 80
  local buf = opts.buf or vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = opts.filetype or "neoai"
  _disable_lsp(buf)
  local cmd = (direction == "left" and "topleft vsplit" or "botright vsplit")
  if direction == "top" then cmd = "topleft split" end
  if direction == "bottom" then cmd = "botright split" end
  vim.cmd(cmd)
  vim.api.nvim_win_set_width(vim.api.nvim_get_current_win(), size)
  vim.api.nvim_set_current_buf(buf)
  local win = vim.api.nvim_get_current_win()
  _configure_window(win)
  return win, buf
end

-- ========== 公开 API ==========

--- 创建窗口
--- @param window_type string "chat" | "tree"
--- @param opts table|nil { mode?, buf?, title? }
--- @return table { win_id, buf, mode }
function M.create(window_type, opts)
  opts = opts or {}
  local mode = opts.mode or config_store.get("ui.window_mode") or "tab"
  local win_id, buf
  if mode == "float" then
    win_id, buf = _open_float(opts)
  elseif mode == "split" then
    win_id, buf = _open_split(opts)
  else
    win_id, buf = _open_tab(opts)
  end
  -- 命名并列入 buffer 列表，使 :ls 可见、:b 可切换
  local buf_name = opts.title or BUFFER_NAMES[window_type]
  if buf_name then
    pcall(vim.api.nvim_buf_set_name, buf, buf_name)
    vim.bo[buf].buflisted = true
  end
  state.windows[win_id] = { type = window_type, buf = buf, win = win_id, mode = mode }
  event_bus.emit(events.WINDOW_OPENED, { win_id = win_id, type = window_type, mode = mode })
  return { win_id = win_id, buf = buf, mode = mode }
end

--- 关闭窗口
--- @param win_id number
function M.close(win_id)
  local info = state.windows[win_id]
  geometry.untrack(win_id)
  if not info then
    -- 可能是外部创建的窗口
    if vim.api.nvim_win_is_valid(win_id) then
      pcall(vim.api.nvim_win_close, win_id, true)
    end
    return
  end
  event_bus.emit(events.WINDOW_CLOSED, { win_id = win_id, type = info.type })
  pcall(vim.api.nvim_win_close, win_id, true)
  state.windows[win_id] = nil
end

--- 关闭所有窗口
function M.close_all()
  for win_id, info in pairs(state.windows) do
    event_bus.emit(events.WINDOW_CLOSED, { win_id = win_id, type = info.type })
    geometry.untrack(win_id)
    if vim.api.nvim_win_is_valid(win_id) then
      pcall(vim.api.nvim_win_close, win_id, true)
    end
  end
  state.windows = {}
  state.aux = {}
end

--- 登记辅助 buffer（如各实例的输入框）：会话恢复孤儿清理时豁免，即使其窗口已收起。
--- 由 chat_view 在创建输入框时调用、关闭实例时经 `unregister_aux` 注销。
--- @param buf number|nil
function M.register_aux(buf)
  if buf and buf ~= 0 and vim.api.nvim_buf_is_valid(buf) then
    state.aux[buf] = true
  end
end

--- 注销辅助 buffer 登记。
--- @param buf number|nil
function M.unregister_aux(buf)
  if buf then state.aux[buf] = nil end
end

--- 聚焦窗口
--- @param win_id number
function M.focus(win_id)
  if vim.api.nvim_win_is_valid(win_id) then
    vim.api.nvim_set_current_win(win_id)
  end
end

--- 获取窗口的 nvim win 句柄
--- @param win_id number
--- @return number
function M.get_win(win_id)
  return win_id
end

--- 获取窗口信息
--- @param win_id number
--- @return table|nil
function M.get_info(win_id)
  return state.windows[win_id]
end

--- 列出所有窗口
--- @return table 数组
function M.list()
  local out = {}
  for win_id, info in pairs(state.windows) do
    if vim.api.nvim_win_is_valid(win_id) then
      out[#out + 1] = { win_id = win_id, type = info.type, buf = info.buf, mode = info.mode }
    else
      state.windows[win_id] = nil
    end
  end
  return out
end

--- 是否有窗口
--- @return boolean
function M.has_windows()
  return next(state.windows) ~= nil
end

--- 判断某 buffer 是否为「NeoAI 界面孤儿」——即由 :mksession/:restart 恢复出来、
--- 但当前进程没有任何真实 NeoAI 窗口接管它的残留 buffer。
--- 识别依据（二者任一）：
---   1. filetype 恰为 `neoai`（聊天主消息 buffer）；
---   2. basename 命中固定界面名 `NeoAI Chat` / `NeoAI Sessions` / `NeoAI Input`（含编号变体）
---      或轨迹命名 `NeoAI-<数字>`。
--- 说明：:restart 恢复出的残留 buffer 往往 filetype 为空（按文件名无法触发文件类型检测），
--- 因此必须结合名字判断，不能只看 filetype。
--- 注意：**不可**用 `filetype` 前缀匹配 `neoai`——那会把浮窗（`neoai_reasoning` /
--- `neoai_tool_args` / `neoai_context_op` / `neoai_sandbox_review` 等）也当成孤儿删除，
--- 从而在多聊天实例并开时误关其它实例正在展示的浮窗。
--- @param buf number
--- @return boolean
local function _is_neoai_orphan(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return false end
  local ok, ft = pcall(function() return vim.bo[buf].filetype end)
  if ok and ft == "neoai" then return true end
  local name = ""
  pcall(function() name = vim.api.nvim_buf_get_name(buf) end)
  if not name or name == "" then return false end
  local base = vim.fn.fnamemodify(name, ":t")
  if base == "NeoAI Chat" or base == "NeoAI Sessions" or base == "NeoAI Input" then return true end
  -- 多实例：聊天 buffer 用编号区分（`NeoAI Chat 2` / `NeoAI Input 3`），一并识别。
  if base:match("^NeoAI Chat %d+$") or base:match("^NeoAI Input %d+$") then return true end
  if base:match("^NeoAI %d+$") or base:match("^NeoAI%-%d+$") then return true end
  return false
end

--- 为窗口挑一个「干净」的替代 buffer（非孤儿、已列入、非特殊 buftype）。
--- 找不到时返回 nil，由调用方创建新的空 buffer。
--- @param orphan_set table<number, boolean>
--- @return number|nil
local function _find_replacement_buf(orphan_set)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and not orphan_set[b] and vim.bo[b].buflisted then
      local bt = vim.bo[b].buftype
      if bt == "" then return b end
    end
  end
  return nil
end

--- 清理会话恢复残留的 NeoAI 界面 buffer/窗口（:restart / :mksession 恢复后调用）。
--- 目标：:restart 后不再出现「空的 NeoAI Chat buffer + 输入框 buffer」这类孤儿，
--- 聊天界面完全关闭，用户需显式 `:NeoAIChat` 重开（新会话）。
--- 做法（全程 pcall、幂等，不触碰非 NeoAI buffer）：
---   1. 关闭显示孤儿 buffer 的**非末窗口**（末窗口留待第 2 步替换，避免整标签页被关掉）；
---   2. 对仍显示孤儿 buffer 的末窗口，切换到干净 buffer（无则新建空 buffer）；
---   3. 删除全部孤儿 buffer。
--- @return number 删除的孤儿 buffer 数
function M.cleanup_session_orphans()
  local registered = {}
  for win_id, info in pairs(state.windows) do
    -- 只统计仍有效的窗口：state.windows 可能残留已失效（被外部关闭）的条目。
    if vim.api.nvim_win_is_valid(win_id) then
      if info.buf then registered[info.buf] = true end
    end
  end
  -- 辅助 buffer（各实例的输入框）：由实例显式登记，收起（窗口关闭、buffer 保留）后仍豁免清理，
  -- 从而无需再靠「有实时聊天窗口即整体豁免所有 NeoAI Input N」的粗粒度规则——
  -- 后者会连带放过会话恢复残留的 `NeoAI Input N`，占名导致新实例输入退化为无名 buffer。
  for buf in pairs(state.aux) do
    if vim.api.nvim_buf_is_valid(buf) then
      registered[buf] = true
    else
      state.aux[buf] = nil
    end
  end

  local orphans = {}
  local orphan_set = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if not registered[buf] and _is_neoai_orphan(buf) then
      orphans[#orphans + 1] = buf
      orphan_set[buf] = true
    end
  end
  if #orphans == 0 then return 0 end

  -- 1) 关闭显示孤儿 buffer 的窗口：窗口所在标签页还有别的窗口，或存在其它标签页时
  --    （后者关掉末窗口会连带关掉整个标签页），安全关闭；否则留待第 2 步替换 buffer。
  local n_tabs = vim.fn.tabpagenr("$")
  for _, buf in ipairs(orphans) do
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
        local tab = vim.api.nvim_win_get_tabpage(win)
        local multi_win = #vim.api.nvim_tabpage_list_wins(tab) > 1
        if multi_win or n_tabs > 1 then
          pcall(vim.api.nvim_win_close, win, true)
        end
      end
    end
  end

  -- 2) 末窗口仍显示孤儿 buffer：换成干净 buffer（避免关掉标签页/退出 nvim）
  for _, buf in ipairs(orphans) do
    if vim.api.nvim_buf_is_valid(buf) then
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
          if vim.fn.exists("&winfixbuf") == 1 then
            pcall(function() vim.wo[win].winfixbuf = false end)
          end
          local repl = _find_replacement_buf(orphan_set) or vim.api.nvim_create_buf(true, false)
          pcall(vim.api.nvim_win_set_buf, win, repl)
        end
      end
    end
  end

  -- 3) 删除孤儿 buffer
  local n = 0
  for _, buf in ipairs(orphans) do
    if vim.api.nvim_buf_is_valid(buf) then
      if pcall(vim.api.nvim_buf_delete, buf, { force = true }) then n = n + 1 end
    end
  end
  return n
end

--- 重置（测试用）
function M.reset()
  M.close_all()
end

return M
