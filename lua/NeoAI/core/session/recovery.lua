--- 崩溃自动恢复（宿主被 OOM 杀 / SIGKILL 后的补救）
--- @module 'NeoAI.core.session.recovery'
---
--- 背景：内核 OOM 选择进程时不会调用任何 Lua 回调——2026-11-27 实测 nvim 以 anon-rss
--- 27.2 GB 被 SIGKILL，交互面直接消失。会话已按轮落盘（`tool_loop` 轮末持久化），
--- 但重启后没有任何机制告诉用户「上一轮被中断了」，也没有回收死进程遗留的沙箱实例
--- （那次留下 7.6 GB 目录，直到手动 `:NeoAI SandboxGC`）。
---
--- 本模块负责三件事：
---   1. 干净退出标记：启动写 `<cache>/NeoAI/state/alive-<pid>.json`，正常退出删除；
---   2. 不干净退出检测：启动时扫描残留标记，`pid` 已死（或 boot_id 变化）即判定崩溃；
---   3. 恢复：回收死进程的沙箱存储 + 找出「被中断」的会话（尾部缺口），交给调用方重开。
---
--- 不注入任何消息到会话：上下文构建侧已为悬空 tool_calls 补稳定占位结果（`_balance_tools`），
--- 重开会话即可安全继续，不需要（也不应该）伪造历史。
---
--- 副作用可卸载：`M.start()` 返回 stop（删除自动命令/信号监听/标记）。

local M = {}

-- ========== 私有状态 ==========

local state = {
  started = false,
  marker_path = nil,
  leave_autocmd = nil,
  au_group = nil,
  signals = {}, -- name -> uv_signal handle
  dir = nil, -- 测试注入的标记目录
  session_source = nil, -- 测试注入的会话来源（默认 session_store.get_all）
  flushed = false,
}

-- ========== 私有函数 ==========

local function _cache_dir()
  return (vim.fn.stdpath("cache") .. "/NeoAI")
end

--- 标记目录（`<cache>/NeoAI/state`）
--- @return string
local function _state_dir()
  if state.dir then return state.dir end
  return _cache_dir() .. "/state"
end

local function _now()
  return os.time()
end

--- 读取内核 boot id（容器/受限环境可能不可读 → nil）
--- @return string|nil
local function _boot_id()
  local f = io.open("/proc/sys/kernel/random/boot_id", "r")
  if not f then return nil end
  local v = f:read("*l")
  f:close()
  return v
end

--- 进程是否存活（保守：无法判定时视为存活，绝不误判崩溃）
--- @param pid number
--- @return boolean
local function _alive(pid)
  if type(pid) ~= "number" or pid <= 0 then return false end
  local ok, res = pcall(vim.uv.kill, pid, 0)
  if not ok then return true end
  return res == true or res == 0
end

--- JSON 读/写（失败返回 nil，绝不抛错）
local function _read_json(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local raw = f:read("*a")
  f:close()
  local ok, dec = pcall(vim.json.decode, raw or "")
  if not ok or type(dec) ~= "table" then return nil end
  return dec
end

local function _write_json(path, obj)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local ok, enc = pcall(vim.json.encode, obj)
  if not ok then return false end
  local tmp = path .. ".tmp." .. tostring(vim.uv.hrtime())
  local f = io.open(tmp, "w")
  if not f then return false end
  local wok = f:write(enc)
  f:close()
  if not wok then pcall(vim.uv.fs_unlink, tmp); return false end
  local rok = vim.uv.fs_rename(tmp, path)
  if not rok then pcall(vim.uv.fs_unlink, tmp) end
  return rok ~= nil
end

--- 会话是否停在「未完成」状态（尾部缺口）
--- @param session table
--- @return string|nil kind "awaiting_reply"|"awaiting_tools"|nil
local function _tail_state(session)
  local msgs = (session and session.messages) or {}
  local last = msgs[#msgs]
  if not last then return nil end
  if last.role == "user" then return "awaiting_reply" end
  if last.role == "tool" then return "awaiting_reply" end
  if last.role == "assistant" then
    if type(last.tool_calls) == "table" and #last.tool_calls > 0 then
      return "awaiting_tools"
    end
    return nil -- assistant 正常收尾
  end
  return nil
end

--- 会话来源（默认 session_store；catalog 可能尚未启动服务，故用 require 但 pcall 包裹）
--- @return table 数组 { id, updated_at, kind, title }
local function _sessions()
  local src = state.session_source
  local all
  if type(src) == "function" then
    local ok, res = pcall(src)
    all = ok and res or nil
  else
    local ok, store = pcall(require, "NeoAI.core.session.session_store")
    if ok and type(store) == "table" and type(store.get_all) == "function" then
      local ok2, res = pcall(store.get_all)
      all = ok2 and res or nil
    end
  end
  if type(all) ~= "table" then return {} end
  local out = {}
  for id, s in pairs(all) do
    if type(s) == "table" then
      local kind = _tail_state(s)
      if kind then
        out[#out + 1] = {
          id = s.id or id,
          updated_at = tonumber(s.updated_at) or 0,
          kind = kind,
          title = type(s.title) == "string" and s.title or nil,
        }
      end
    end
  end
  table.sort(out, function(a, b) return (a.updated_at or 0) > (b.updated_at or 0) end)
  return out
end

--- 清理已回收标记（含损坏标记）
--- @param keep_pid number
local function _prune_markers(keep_pid)
  local dir = _state_dir()
  local h = vim.uv.fs_scandir(dir)
  if not h then return end
  while true do
    local name = vim.uv.fs_scandir_next(h)
    if not name then break end
    if name:match("^alive%-%d+%.json$") or name:match("^alive%-%d+%.json%.tmp") then
      local pid = tonumber(name:match("alive%-(%d+)"))
      if pid and pid ~= keep_pid then pcall(vim.uv.fs_unlink, dir .. "/" .. name) end
    end
  end
end

-- ========== 公开 API ==========

--- 启动标记（本进程）：表示「本 nvim 正在运行 NeoAI 且尚未干净退出」
--- @return boolean ok
function M.mark_started()
  local pid = vim.fn.getpid()
  state.marker_path = string.format("%s/alive-%d.json", _state_dir(), pid)
  local ok = _write_json(state.marker_path, {
    pid = pid,
    boot_id = _boot_id(),
    started_at = _now(),
    cwd = vim.fn.getcwd(),
  })
  if ok then _prune_markers(pid) end
  return ok
end

--- 干净退出：删除本进程标记（幂等）
function M.mark_clean_exit()
  if state.marker_path then pcall(vim.uv.fs_unlink, state.marker_path) end
  state.marker_path = nil
end

--- 检测不干净退出（不修改任何状态）。
--- @return table { unclean = boolean, markers = { {pid, started_at, boot_id, cwd} ... } }
function M.detect()
  local out = { unclean = false, markers = {} }
  local dir = _state_dir()
  local h = vim.uv.fs_scandir(dir)
  if not h then return out end
  local self_pid = vim.fn.getpid()
  local boot = _boot_id()
  while true do
    local name = vim.uv.fs_scandir_next(h)
    if not name then break end
    local pid = tonumber(name:match("^alive%-(%d+)%.json$"))
    if pid then
      local data = _read_json(dir .. "/" .. name) or { pid = pid }
      local different_boot = (data.boot_id ~= nil and boot ~= nil and data.boot_id ~= boot)
      local dead = not _alive(pid)
      if pid ~= self_pid and (dead or different_boot) then
        out.unclean = true
        out.markers[#out.markers + 1] = {
          pid = pid,
          started_at = tonumber(data.started_at) or 0,
          boot_id = data.boot_id,
          cwd = data.cwd,
          dead = dead,
        }
      end
    end
  end
  table.sort(out.markers, function(a, b) return (a.started_at or 0) > (b.started_at or 0) end)
  return out
end

--- 列出「被中断」的会话（按最近更新降序）。
--- 判定依据：尾部缺口（最后一条是 user / tool / 带 tool_calls 的 assistant）。
--- `since` 限制为崩溃前那次 nvim 启动之后更新的会话（默认取最早崩溃标记的 started_at）。
--- @param markers table|nil `M.detect().markers`
--- @param opts table|nil { since?: number, limit?: number }
--- @return table 数组 { id, updated_at, kind, title }
function M.interrupted_sessions(markers, opts)
  opts = opts or {}
  local since = tonumber(opts.since)
  if since == nil and type(markers) == "table" and #markers > 0 then
    local earliest = math.huge
    for _, m in ipairs(markers) do
      local t = tonumber(m.started_at) or 0
      if t > 0 and t < earliest then earliest = t end
    end
    if earliest ~= math.huge then since = earliest - 60 end
  end
  local list = {}
  for _, s in ipairs(_sessions()) do
    if since == nil or (s.updated_at or 0) >= since then
      list[#list + 1] = s
    end
  end
  local limit = tonumber(opts.limit) or 0
  if limit > 0 and #list > limit then
    local cut = {}
    for i = 1, limit do cut[i] = list[i] end
    list = cut
  end
  return list
end

--- 恢复一次（幂等：同一进程只做一次实际恢复）。
--- 行为：检测 →（可选）回收死进程沙箱存储 → 列出被中断会话 → 发事件 + 提示。
--- **不**自动重开会话（由调用方按配置决定，便于测试与「只提示」模式）。
--- @param opts table|nil { reclaim?: boolean, notify?: boolean, auto_open?: number }
--- @return table { unclean, sessions, reclaimed, auto_open }
function M.recover(opts)
  opts = opts or {}
  local ok_cfg, cfg = pcall(function()
    return require("NeoAI.kernel.config_store").get("session.recovery") or {}
  end)
  if not ok_cfg or type(cfg) ~= "table" then cfg = {} end
  local result = { unclean = false, sessions = {}, reclaimed = false, auto_open = 0 }
  if cfg.enabled == false then return result end

  local det = M.detect()
  result.unclean = det.unclean
  result.markers = det.markers
  if not det.unclean then return result end

  local do_reclaim = (opts.reclaim ~= false) and (cfg.reclaim_sandbox ~= false)
  if do_reclaim then
    local ok_r, reclaim = pcall(require, "NeoAI.sandbox.execution.reclaim")
    if ok_r and type(reclaim) == "table" and type(reclaim.run) == "function" then
      pcall(reclaim.run, {})
      result.reclaimed = true
    end
  end

  result.sessions = M.interrupted_sessions(det.markers)
  result.auto_open = tonumber(opts.auto_open) or tonumber(cfg.auto_open) or 0

  pcall(function()
    require("NeoAI.kernel.event_bus").emit(
      require("NeoAI.kernel.events").SESSION_RECOVERED,
      {
        unclean = true,
        markers = det.markers,
        sessions = result.sessions,
        reclaimed = result.reclaimed,
      }
    )
  end)

  local notify = (opts.notify ~= false) and (cfg.notify ~= false)
  if notify then
    local prev = det.markers[1]
    local text = ("[NeoAI] 检测到上一次运行异常结束（%s），已恢复%s。"):format(
      prev and ("pid " .. tostring(prev.pid)) or "宿主进程消失",
      result.reclaimed and "并回收了残留的沙箱存储" or "会话索引")
    if #result.sessions > 0 then
      text = text .. ("\n被中断的会话 %d 个，最近一个：%s")
        :format(#result.sessions, tostring(result.sessions[1].title or result.sessions[1].id))
    end
    pcall(function()
      vim.schedule(function()
        pcall(vim.notify, text, vim.log.levels.WARN, { title = "NeoAI 崩溃恢复" })
      end)
    end)
  end
  pcall(function()
    require("NeoAI.kernel.logger").warn(
      "[recovery] 检测到不干净退出（pid=%s），中断会话 %d 个，回收沙箱=%s",
      tostring(det.markers[1] and det.markers[1].pid), #result.sessions, tostring(result.reclaimed))
  end)
  return result
end

--- 启动恢复服务（幂等）：写标记 + 安装退出/信号钩子 + 做一次恢复检测。
--- 返回 stop 函数（插件卸载时调用）。
--- @param opts table|nil { install_signals?: boolean }
--- @return table result `M.recover()` 的返回值（含 unclean/sessions/auto_open）
--- @return function stop
function M.start(opts)
  opts = opts or {}
  local ok_cfg, cfg = pcall(function()
    return require("NeoAI.kernel.config_store").get("session.recovery") or {}
  end)
  if ok_cfg and type(cfg) == "table" and cfg.enabled == false then
    return { unclean = false, sessions = {}, reclaimed = false, auto_open = 0 }, function() end
  end
  local result = { unclean = false, sessions = {}, reclaimed = false, auto_open = 0 }
  if state.started then
    return result, function() M.stop() end
  end
  state.started = true
  -- 先标记再检测：本进程标记不会命中自己（detect 跳过 self pid）
  M.mark_started()
  result = M.recover({ reclaim = true })

  -- 干净退出：删除标记（OOM/SIGKILL 不会执行到这里，故标记残留即「不干净退出」）
  local group = vim.api.nvim_create_augroup("NeoAIRecovery" .. vim.fn.getpid(), { clear = true })
  state.au_group = group
  state.leave_autocmd = vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function() M.mark_clean_exit() end,
    desc = "NeoAI: 崩溃恢复干净退出标记",
  })

  -- 可捕获信号：先落盘再退出，尽量减小 SIGTERM/SIGINT/SIGHUP 的损失
  if opts.install_signals ~= false then
    local function on_signal(sig_name)
      return function()
        vim.schedule(function()
          if state.flushed then return end
          state.flushed = true
          pcall(function()
            local store = require("NeoAI.core.session.session_store")
            if type(store.save_all) == "function" then store.save_all() end
          end)
          pcall(function()
            local chat = require("NeoAI.kernel.services").use("services.chat_service")
            if chat and type(chat.persist_active_sessions) == "function" then
              chat.persist_active_sessions()
            end
          end)
          M.mark_clean_exit()
          pcall(function()
            require("NeoAI.kernel.logger").warn("[recovery] 收到 %s，已落盘并干净退出", sig_name)
          end)
          pcall(vim.cmd, "qa!")
        end)
      end
    end
    for _, name in ipairs({ "sigterm", "sigint", "sighup" }) do
      local ok_sig, handle = pcall(vim.uv.new_signal)
      if ok_sig and handle then
        local ok_start = pcall(function() handle:start(name, on_signal(name)) end)
        if ok_start then state.signals[name] = handle else pcall(function() handle:close() end) end
      end
    end
  end
  return result, function() M.stop() end
end

--- 停止（幂等）：删除自动命令、关闭信号监听、删除标记
function M.stop()
  if state.leave_autocmd then
    pcall(vim.api.nvim_del_autocmd, state.leave_autocmd)
    state.leave_autocmd = nil
  end
  if state.au_group then
    pcall(vim.api.nvim_del_augroup_by_id, state.au_group)
    state.au_group = nil
  end
  for name, handle in pairs(state.signals) do
    pcall(function() handle:stop() end)
    pcall(function() handle:close() end)
    state.signals[name] = nil
    local _ = name
  end
  M.mark_clean_exit()
  state.started = false
  state.flushed = false
end

-- ========== 测试钩子 ==========

--- 注入标记目录（测试用；nil 恢复默认 `<cache>/NeoAI/state`）
--- @param dir string|nil
function M._set_dir(dir)
  state.dir = dir
end

--- 注入会话来源（测试用；nil 恢复 session_store）
--- @param fn function|nil -> table
function M._set_session_source(fn)
  state.session_source = fn
end

--- 清空模块状态（测试用）
function M.reset()
  pcall(M.stop)
  state.dir = nil
  state.session_source = nil
  state.marker_path = nil
  state.started = false
  state.flushed = false
end

return M
