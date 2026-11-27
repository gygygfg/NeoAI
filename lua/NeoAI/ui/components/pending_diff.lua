--- 沙箱待审改动 → 打开文件 buffer 的行内 diff
--- @module 'NeoAI.ui.components.pending_diff'
---
--- 当用户打开的文件在沙箱视图里有 AI 待审改动时，在本 buffer 上做**只读装饰**：
---   * 行高亮（DiffChange / DiffDelete）+ 行首 sign（~ / -）；
---   * 纯新增行以 virt_lines 预览（默认最多 20 行，可配置）；
---   * AI 待审删除整文件时显示顶部提示。
--- 不修改 buffer 内容、不写盘、不产生候选；`:NeoAI diff` 打开完整对比。
---
--- 基线判定由 `candidate.pending_content()` 提供：只有「真实 AI/命令改动」才显示。
--- 用户自己未保存的输入（save-all 基线）不会误报成 diff。

local buffer_ref = require("NeoAI.utils.buffer")

local M = {}

-- ========== 私有状态 ==========

local NS = vim.api.nvim_create_namespace("neoai_pending_diff")
local GROUP = "NeoAIPendingDiff"

local state = {
  installed = false,
  cache = {}, -- bufnr -> { tick, hash }
  dirty = {},
  timer = nil,
  unsubs = {},
}

-- ========== 私有函数 ==========

--- @return table
local function _cfg()
  local ok, cfg = pcall(function()
    return require("NeoAI.kernel.config_store").get("ui.pending_diff")
  end)
  return (ok and type(cfg) == "table") and cfg or {}
end

--- @param text string|nil
--- @return string
local function _strip_one_nl(text)
  text = text or ""
  if text:sub(-1) == "\n" then return text:sub(1, -2) end
  return text
end

--- 定义默认高亮（可被用户配色覆盖）。
local function _define_hl()
  pcall(vim.api.nvim_set_hl, 0, "NeoAIPendingAdd", { link = "DiffAdd", default = true })
  pcall(vim.api.nvim_set_hl, 0, "NeoAIPendingChange", { link = "DiffChange", default = true })
  pcall(vim.api.nvim_set_hl, 0, "NeoAIPendingDelete", { link = "DiffDelete", default = true })
end

--- 清空某 buffer 的装饰与缓存。
--- @param buf number
local function _clear(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_clear_namespace, buf, NS, 0, -1)
  end
  state.cache[buf] = nil
end

--- 取某 buffer 的待审内容（无条目/无真实改动/不可处理时返回 nil）。
--- @param buf number
--- @return table|nil { content?, deleted?, diverged? }
local function _pending(buf)
  if not buffer_ref.is_normal(buf) then return nil end
  local path = buffer_ref.path(buf)
  if path == "" then return nil end
  local ok, candidate = pcall(require, "NeoAI.sandbox.execution.candidate")
  if not ok or not candidate or type(candidate.pending_content) ~= "function" then return nil end
  local ok2, info = pcall(candidate.pending_content, path)
  if not ok2 then return nil end
  return info
end

--- 画一行/一段行的 diff 装饰。
--- @param buf number
--- @param hunks table vim.diff(..., { result_type = "indices" }) 结果
--- @param pending_lines string[]
local function _paint(buf, hunks, pending_lines)
  local limit = tonumber(_cfg().virtual_added_lines) or 20
  pcall(vim.api.nvim_buf_clear_namespace, buf, NS, 0, -1)
  for _, h in ipairs(hunks or {}) do
    local a_start, a_count, b_start, b_count = h[1], h[2], h[3], h[4]
    if a_count > 0 then
      local row = math.max(0, a_start - 1)
      local end_row = row + a_count
      local hl = (b_count > 0) and "NeoAIPendingChange" or "NeoAIPendingDelete"
      local sign = (b_count > 0) and "~" or "-"
      pcall(vim.api.nvim_buf_set_extmark, buf, NS, row, 0, {
        end_row = end_row,
        end_col = 0,
        line_hl_group = hl,
        sign_text = sign,
        sign_hl_group = hl,
        priority = 100,
      })
      if b_count == 0 then
        pcall(vim.api.nvim_buf_set_extmark, buf, NS, row, 0, {
          virt_text = { { ("  AI 待审删除 %d 行"):format(a_count), "Comment" } },
          virt_text_pos = "eol",
          priority = 100,
        })
      end
    else
      -- 纯新增：start_a 之后插入 b_start..b_start+b_count-1
      local row = math.min(math.max(0, a_start), vim.api.nvim_buf_line_count(buf))
      local shown = math.min(b_count, limit)
      local vlines = {}
      for i = 0, shown - 1 do
        local l = pending_lines[b_start + i]
        vlines[i + 1] = { { l ~= nil and l or "", "NeoAIPendingAdd" } }
      end
      if b_count > shown then
        vlines[#vlines + 1] = { { ("  … 还有 %d 行（:NeoAI diff 查看）"):format(b_count - shown), "Comment" } }
      end
      pcall(vim.api.nvim_buf_set_extmark, buf, NS, row, 0, {
        virt_lines = vlines,
        virt_lines_above = true,
        sign_text = "+",
        sign_hl_group = "NeoAIPendingAdd",
        priority = 100,
      })
    end
  end
end

--- 计算并绘制某 buffer 的待审 diff。
--- @param buf number
--- @return boolean painted
function M.refresh(buf)
  if not _cfg().enabled then return false end
  buf = buf or vim.api.nvim_get_current_buf()
  if not (buf and vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)) then return false end
  if not buffer_ref.is_normal(buf) then _clear(buf); return false end
  local info = _pending(buf)
  if not info then _clear(buf); return false end
  if info.deleted then
    pcall(vim.api.nvim_buf_clear_namespace, buf, NS, 0, -1)
    pcall(vim.api.nvim_buf_set_extmark, buf, NS, 0, 0, {
      virt_lines = { { { "[NeoAI] 沙箱待审删除该文件（:NeoAI diff 查看）", "NeoAIPendingDelete" } } },
      virt_lines_above = true,
      sign_text = "-",
      sign_hl_group = "NeoAIPendingDelete",
      priority = 100,
    })
    return true
  end
  local path = buffer_ref.path(buf)
  local st = path ~= "" and vim.uv.fs_stat(path) or nil
  local max_bytes = tonumber(_cfg().max_bytes) or (1024 * 1024)
  if st and st.type == "file" and (st.size or 0) > max_bytes then
    _clear(buf)
    pcall(vim.api.nvim_buf_set_extmark, buf, NS, 0, 0, {
      virt_text = { { ("[NeoAI] 沙箱有该文件的待审修改（%d 字节，超过 diff 上限；:NeoAI diff 查看）")
        :format(st.size or 0), "Comment" } },
      virt_text_pos = "eol",
    })
    return true
  end
  local buffer_text = _strip_one_nl(table.concat(
    vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
  local pending_text = _strip_one_nl(info.content or "")
  local pending_lines = vim.split(pending_text, "\n", { plain = true })
  if pending_text == "" then pending_lines = { "" } end
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local sig = tostring(tick) .. "\0" .. (buffer_ref.hash(buffer_text .. "\0" .. pending_text) or "")
  local cached = state.cache[buf]
  if cached and cached.tick == tick and cached.sig == sig then return true end
  local ok, hunks = pcall(vim.diff, buffer_text, pending_text, {
    result_type = "indices",
    algorithm = "histogram",
    ctxlen = 0,
  })
  if not ok or type(hunks) ~= "table" then _clear(buf); return false end
  _paint(buf, hunks, pending_lines)
  state.cache[buf] = { tick = tick, sig = sig }
  return true
end

--- 调度一次刷新（合并高频 TextChanged）。
--- @param buf number|nil
local function _schedule(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  state.dirty[buf] = true
  if state.timer then return end
  local wait = tonumber(_cfg().debounce_ms) or 200
  if wait < 0 then wait = 0 end
  state.timer = vim.uv.new_timer()
  if not state.timer then return end
  if state.timer.unref then state.timer:unref() end
  state.timer:start(wait, 0, function()
    vim.schedule(function()
      if state.timer then
        pcall(function() state.timer:stop() end)
        pcall(function() state.timer:close() end)
        state.timer = nil
      end
      local dirty = state.dirty
      state.dirty = {}
      for b in pairs(dirty) do
        if vim.api.nvim_buf_is_valid(b) then pcall(M.refresh, b) end
      end
    end)
  end)
end

--- 打开当前 buffer 与沙箱待审内容的完整 diff（左右分屏 + diffthis）。
--- @param buf number|nil
function M.open(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  local info = _pending(buf)
  if not info then
    vim.notify("[NeoAI] 当前 buffer 没有沙箱待审修改", vim.log.levels.INFO)
    return
  end
  if info.deleted then
    vim.notify("[NeoAI] 该文件在沙箱中处于待审删除状态；可在 :NeoAI SandboxReview 中确认", vim.log.levels.INFO)
    return
  end
  local orig_win = vim.fn.bufwinid(buf)
  if orig_win == -1 then
    vim.cmd("buffer " .. buf)
    orig_win = vim.api.nvim_get_current_win()
  end
  local lines = vim.split(_strip_one_nl(info.content or ""), "\n", { plain = true })
  if (info.content or "") == "" then lines = { "" } end
  local sbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(sbuf, 0, -1, false, lines)
  vim.bo[sbuf].buftype = "nofile"
  vim.bo[sbuf].bufhidden = "wipe"
  vim.bo[sbuf].swapfile = false
  vim.bo[sbuf].modifiable = false
  vim.bo[sbuf].filetype = vim.bo[buf].filetype
  pcall(vim.api.nvim_buf_set_name, sbuf, "NeoAI Pending: " .. (buffer_ref.path(buf) or ""))
  vim.cmd("vsplit")
  vim.api.nvim_win_set_buf(0, sbuf)
  pcall(vim.api.nvim_set_current_win, orig_win)
  pcall(vim.cmd, "diffthis")
  local s_win = vim.fn.bufwinid(sbuf)
  if s_win ~= -1 then
    pcall(vim.api.nvim_set_current_win, s_win)
    pcall(vim.cmd, "diffthis")
  end
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = sbuf,
    once = true,
    callback = function()
      if vim.api.nvim_win_is_valid(orig_win) then
        pcall(vim.api.nvim_win_call, orig_win, function() pcall(vim.cmd, "diffoff!") end)
      end
    end,
  })
end

--- 安装 UI 注入（幂等；返回的清理由 uninstall 统一执行）。
function M.install()
  if state.installed then return end
  state.installed = true
  _define_hl()
  vim.api.nvim_create_augroup(GROUP, { clear = true })
  local group = GROUP
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufEnter", "BufWinEnter" }, {
    group = group,
    callback = function(args)
      if _cfg().auto == false then return end
      _schedule(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost" }, {
    group = group,
    callback = function(args) _schedule(args.buf) end,
  })
  vim.api.nvim_create_autocmd({ "BufUnload", "BufDelete", "BufWipeout" }, {
    group = group,
    callback = function(args) _clear(args.buf) end,
  })
  -- 沙箱工具/审批完成后刷新（事件可能在 fast context 中触发，统一 schedule）。
  local ok, event_bus = pcall(require, "NeoAI.kernel.event_bus")
  if ok and event_bus and type(event_bus.on) == "function" then
    local events = require("NeoAI.kernel.events")
    local names = {
      events.TOOL_EXECUTION_COMPLETED,
      events.SANDBOX_APPLIED,
      events.SANDBOX_COMMITTED,
      events.SANDBOX_DISCARDED,
      events.SANDBOX_REVERTED,
      events.SANDBOX_REVIEW_ENQUEUED,
      events.SANDBOX_REVIEW_APPROVED,
      events.SANDBOX_REVIEW_REJECTED,
      events.SANDBOX_REVIEW_SUPERSEDED,
    }
    for _, name in ipairs(names) do
      local unsub = event_bus.on(name, function()
        vim.schedule(function()
          for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(b) then _schedule(b) end
          end
        end)
      end)
      if type(unsub) == "function" then state.unsubs[#state.unsubs + 1] = unsub end
    end
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then _schedule(b) end
  end
end

--- 卸载 UI 注入（清理 augroup/订阅/定时器/装饰）。
function M.uninstall()
  if not state.installed then return end
  state.installed = false
  pcall(vim.api.nvim_del_augroup_by_name, GROUP)
  for _, unsub in ipairs(state.unsubs) do pcall(unsub) end
  state.unsubs = {}
  if state.timer then
    pcall(function() state.timer:stop() end)
    pcall(function() state.timer:close() end)
    state.timer = nil
  end
  for buf in pairs(state.cache) do _clear(buf) end
  state.cache = {}
  state.dirty = {}
end

--- 重置（测试用）
function M.reset()
  M.uninstall()
end

return M
