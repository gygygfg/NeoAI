--- 交互式 PTY 会话服务
--- @module NeoAI.services.pty
--- 用 Neovim 分配的 PTY 运行命令（jobstart pty=true），通过轮询 `/proc` 检测
--- “进程阻塞在读取 fd0（终端）= 正在等待输入”，再由判官子 agent 或用户手动输入注入。
---
--- 为什么不靠 SIGTTIN：bwrap 固定 `--new-session` 会让载荷失去控制终端，SIGTTIN 不触发；
--- 且前台读终端不会发 SIGTTIN，无法重复检测。轮询“阻塞读终端”是 OS 级判据（非文字匹配），
--- 可重复、无需中间人程序。
---
--- 重复判定：连续两次 read 的 `/proc/<pid>/syscall` 完全相同（同一缓冲区），故用
--- `/proc/<pid>/io` 的 `rchar` 增长判定“上一次输入已被消费，这是新一次等待”。
--- `rchar` 不可读（跨 uid）时退化为冷却时间兜底。

local async = require("NeoAI.utils.async")
local config_store = require("NeoAI.kernel.config_store")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")
local stringx = require("NeoAI.utils.stringx")

local M = {}

-- ========== 私有状态 ==========

local state = {
  sessions = {},   -- id -> session
  seq = 0,
  judge = nil,     -- 自定义判官（测试/替换）：function(session) -> Deferred|nil
  active_id = nil, -- 当前判官会话 id（供 terminal_* 工具定位）
  window = nil,    -- 惰性加载的悬浮终端组件
}

-- ========== 私有函数 ==========

--- 交互式配置
--- @return table
local function _cfg()
  return config_store.get("tools.run_command.interactive") or {}
end

--- 是否有可用 UI（headless 下不建窗口）
--- @return boolean
local function _has_ui()
  local ok, uis = pcall(vim.api.nvim_list_uis)
  return ok and type(uis) == "table" and #uis > 0
end

--- 悬浮终端组件（惰性）
--- @return table|nil
local function _window()
  if state.window then return state.window end
  local ok, mod = pcall(require, "NeoAI.ui.components.terminal_window")
  if ok and mod then state.window = mod end
  return state.window
end

--- 聊天窗口当前是否「跟随光标」。UI 未加载/无聊天窗口时默认允许弹出（不在缺失时永久抑制）。
--- @return boolean
local function _chat_following()
  local ok, chat = pcall(require, "NeoAI.ui.window.chat_view")
  if ok and chat and type(chat.is_following) == "function" then
    local ok2, v = pcall(chat.is_following)
    if ok2 then return v end
  end
  return true
end

--- 打开某会话的悬浮终端（幂等；有 UI 且组件可用时）
--- @param session table
--- @param title string|nil
local function _open_window(session, title)
  if session.window or not _has_ui() then return end
  local win = _window()
  if not win then return end
  pcall(function() session.window = win.open(session, title or session.title) end)
end

--- 是否应弹出悬浮终端。
--- 规则：`show_window` 决定触发时机（always=会话启动 | on_wait=检测到等待），二者都要求
--- **聊天光标跟随**；光标不跟随时（用户正在回看上方内容）一律不弹。
--- @param session table
--- @param on_wait boolean 本次是否为「检测到等待输入」触发（false=会话启动）
--- @return boolean
local function _should_show_window(session, on_wait)
  if session.window then return false end
  local sw = _cfg().show_window or "on_wait"
  if sw == "never" then return false end
  if on_wait then
    if sw ~= "on_wait" then return false end
  else
    if sw ~= "always" then return false end
  end
  return _chat_following()
end

--- 读取单行 /proc 文件；失败返回 nil
--- @param path string
--- @return string|nil
local function _read_line(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local line = f:read("*l")
  f:close()
  return line
end

--- 进程状态字符（/proc/<pid>/stat 第 3 字段），失败 nil
--- @param pid number
--- @return string|nil
local function _state(pid)
  local line = _read_line("/proc/" .. pid .. "/stat")
  if not line then return nil end
  return line:match("%)%s+(%S)")
end

--- 阻塞点内核符号（/proc/<pid>/wchan），无权限时为 "0"
--- @param pid number
--- @return string|nil
local function _wchan(pid)
  return _read_line("/proc/" .. pid .. "/wchan")
end

--- 已读字节计数（/proc/<pid>/io 的 rchar），不可读返回 nil
--- @param pid number
--- @return number|nil
local function _rchar(pid)
  local f = io.open("/proc/" .. pid .. "/io", "r")
  if not f then return nil end
  local val
  for line in f:lines() do
    local n = line:match("^rchar:%s*(%d+)")
    if n then val = tonumber(n) break end
  end
  f:close()
  return val
end

--- fd0 指向的终端设备（/dev/pts/N 等），非终端返回 nil
--- @param pid number
--- @return string|nil
local function _fd0(pid)
  local ok, link = pcall(vim.uv.fs_readlink, "/proc/" .. pid .. "/fd/0")
  if not ok or type(link) ~= "string" then return nil end
  if link:sub(1, 9) == "/dev/pts/" or link == "/dev/tty" or link == "/dev/console" then
    return link
  end
  return nil
end

--- pid 是否阻塞在读取终端（fd0）。返回 true 表示“等待输入”。
--- @param pid number
--- @return boolean
local function _blocked_on_tty(pid)
  if not _fd0(pid) then return false end
  local line = _read_line("/proc/" .. pid .. "/syscall")
  if line then
    local nr, a0 = line:match("^(%S+)%s+(%S+)")
    if (nr == "0" or nr == "0x0") and a0 == "0x0" then return true end
  end
  local wchan = _wchan(pid)
  if wchan == "n_tty_read" or wchan == "wait_woken" or wchan == "tty_read" then
    local st = _state(pid)
    return st == "S" or st == "D"
  end
  return false
end

--- 直接子进程 pid（/proc/<pid>/task/<pid>/children，O(子进程数)）
--- @param pid number
--- @return table
local function _children(pid)
  local out = {}
  local line = _read_line("/proc/" .. pid .. "/task/" .. pid .. "/children")
  if line then
    for n in line:gmatch("%d+") do out[#out + 1] = tonumber(n) end
  end
  return out
end

--- 进程的所有子孙 pid（沿 children 链遍历，避免每次轮询扫全部 /proc）
--- @param root number
--- @return table pid 数组
local function _descendants(root)
  local out, stack = {}, { root }
  while #stack > 0 do
    local cur = table.remove(stack)
    for _, k in ipairs(_children(cur)) do
      out[#out + 1] = k
      stack[#stack + 1] = k
    end
  end
  return out
end

--- 命令树的候选 pid：优先 cgroup.procs（沙箱内也能取到宿主 pid），否则子进程树。
--- @param session table
--- @return table pid 数组
local function _tree_pids(session)
  if session.cgroup_path then
    local f = io.open(session.cgroup_path .. "/cgroup.procs", "r")
    if f then
      local out = {}
      for line in f:lines() do
        local n = tonumber(line)
        if n then out[#out + 1] = n end
      end
      f:close()
      if #out > 0 then return out end
    end
  end
  local out = { session.pid }
  for _, p in ipairs(_descendants(session.pid)) do out[#out + 1] = p end
  return out
end

--- 找到正在等待输入的进程 pid
--- @param session table
--- @return number|nil
local function _reader(session)
  for _, pid in ipairs(_tree_pids(session)) do
    if _blocked_on_tty(pid) then return pid end
  end
  return nil
end

-- ========== 按键 → 字节 ==========

local KEYMAP = {
  ["<CR>"] = "\r", ["<Return>"] = "\r", ["enter"] = "\r", ["return"] = "\r",
  ["<Tab>"] = "\t", ["tab"] = "\t",
  ["<Space>"] = " ", ["space"] = " ",
  ["<Esc>"] = "\27", ["<Escape>"] = "\27", ["esc"] = "\27", ["escape"] = "\27",
  ["<BS>"] = "\127", ["<Backspace>"] = "\127", ["backspace"] = "\127", ["bs"] = "\127",
  ["<Del>"] = "\27[3~", ["<Delete>"] = "\27[3~", ["delete"] = "\27[3~", ["del"] = "\27[3~",
  ["<Up>"] = "\27[A", ["up"] = "\27[A",
  ["<Down>"] = "\27[B", ["down"] = "\27[B",
  ["<Right>"] = "\27[C", ["right"] = "\27[C",
  ["<Left>"] = "\27[D", ["left"] = "\27[D",
  ["<Home>"] = "\27[H", ["home"] = "\27[H",
  ["<End>"] = "\27[F", ["end"] = "\27[F",
  ["<PageUp>"] = "\27[5~", ["pageup"] = "\27[5~",
  ["<PageDown>"] = "\27[6~", ["pagedown"] = "\27[6~",
}
-- 控制键：C-a..C-z（除若干）→ 0x01..0x1a
local CTRL_ALIAS = {
  ["ctrl-c"] = "c", ["ctrl-d"] = "d", ["ctrl-z"] = "z", ["ctrl-l"] = "l",
  ["ctrl-u"] = "u", ["ctrl-a"] = "a", ["ctrl-e"] = "e", ["ctrl-w"] = "w",
  ["ctrl-r"] = "r", ["ctrl-k"] = "k", ["ctrl-y"] = "y", ["ctrl-o"] = "o",
  ["ctrl-\\"] = "\\", ["ctrl-]"] = "]",
}

-- 小写键名索引（含去掉尖括号的形式）
local KEYMAP_LC = {}
for k, v in pairs(KEYMAP) do KEYMAP_LC[k:lower()] = v end

--- 单个按键名 → 字节序列；无法识别返回 nil。
--- 支持 "a"、"Enter"、"<CR>"、"<C-c>"、"Ctrl-C"、"^C"、"Up" 等写法。
--- @param key string
--- @return string|nil
function M.key_bytes(key)
  if type(key) ~= "string" or key == "" then return nil end
  local lower = key:lower()
  local norm = lower
  if norm:sub(1, 1) == "<" and norm:sub(-1) == ">" then norm = norm:sub(2, -2) end
  if KEYMAP[key] then return KEYMAP[key] end
  if KEYMAP_LC[lower] then return KEYMAP_LC[lower] end
  if KEYMAP_LC[norm] then return KEYMAP_LC[norm] end
  -- Ctrl-C / C-c / Ctrl-C / ^C
  local c = norm:match("^c%-(.)$") or norm:match("^ctrl%-(.)$") or norm:match("^%^(.)$")
  if not c then c = CTRL_ALIAS[norm] end
  if c and #c == 1 then
    local b = c:byte()
    if b >= 97 and b <= 122 then return string.char(b - 96) end
    if c == "\\" then return string.char(28) end
    if c == "]" then return string.char(29) end
    if c == "[" then return string.char(27) end
  end
  -- 单字符原样
  if #key == 1 then return key end
  return nil
end

--- 按键数组 → 字节串
--- @param keys table|string
--- @return string
function M.keys_bytes(keys)
  if type(keys) == "string" then keys = { keys } end
  local out = {}
  for _, k in ipairs(keys or {}) do
    local b = M.key_bytes(k)
    if b then out[#out + 1] = b end
  end
  return table.concat(out)
end

-- ========== 判官（AI 决定输入） ==========

--- 终端近期输出（去 ANSI）尾部 N 行，供判官参考
--- @param session table
--- @return string
local function _tail(session)
  local n = tonumber(((_cfg().judge or {}).output_tail_lines)) or 80
  local ok, ansi = pcall(require, "NeoAI.utils.ansi")
  local text = session.output or ""
  if ok and ansi and ansi.strip then text = ansi.strip(text) end
  local lines = vim.split(text, "\n", { plain = true })
  if #lines > n then
    local out = {}
    for i = #lines - n + 1, #lines do out[#out + 1] = lines[i] end
    return table.concat(out, "\n")
  end
  return text
end

--- 通知用户手动输入（判官不可用时）
--- @param session table
local function _notify_manual(session)
  if session.manual_notified == session.wait_count then return end
  session.manual_notified = session.wait_count
  pcall(vim.notify,
    "[NeoAI] 命令正在等待输入，请在悬浮终端中手动输入（" .. tostring(session.id) .. "）",
    vim.log.levels.WARN)
end

--- 从模型返回文本中解析决策 JSON（容忍代码块标记与前后说明）
--- @param text string|nil
--- @return table|nil
local function _extract_decision(text)
  if type(text) ~= "string" or text == "" then return nil end
  local json = require("NeoAI.utils.json")
  local ok, obj = pcall(json.decode, text)
  if ok and type(obj) == "table" then return obj end
  local s = text:find("{")
  local e = text:find("}", s or 1)
  if s and e then
    local ok2, obj2 = pcall(json.decode, text:sub(s, e))
    if ok2 and type(obj2) == "table" then return obj2 end
  end
  return nil
end

--- 应用判官决策；返回是否已动作
--- @param session table
--- @param decision table|nil
--- @return boolean
local function _apply_decision(session, decision)
  if type(decision) ~= "table" then return false end
  local action = decision.action
  if action == "text" and type(decision.text) == "string" then
    return M.send_text(session.id, decision.text)
  elseif action == "keys" and type(decision.keys) == "table" then
    return M.send_keys(session.id, decision.keys)
  elseif action == "kill" then
    return M.kill(session.id, "judge_kill")
  end
  return false
end

--- 默认判官：每次检测到等待输入，发起**单轮大模型请求**并应用其返回的决策。
--- 不派生子 agent / 不跑工具循环，避免多步判官拖慢每一轮等待。
--- @param session table
--- @return Deferred
local function _default_judge(session)
  local runtime = require("NeoAI.core.agent.runtime")
  local cfg = _cfg().judge or {}
  local parent = session.parent_agent
  local agent = runtime.create({
    mode = "chat",
    model = cfg.model or (parent and parent.model),
    config = parent and parent.config or nil,
    tools = {},
  })
  local prompt = table.concat({
    "一个交互式 shell 命令正在等待输入（内核检测到它阻塞在读取终端）。",
    "请根据命令用途与近期输出，决定如何继续。",
    "",
    "命令用途（description）：" .. tostring(session.description or "（未提供）"),
    "命令：" .. tostring(session.command or ""),
    "近期终端输出（已去 ANSI）：",
    "-----",
    _tail(session),
    "-----",
    "",
    "只输出一个 JSON 对象（不要多余文字、不要代码块）：",
    '{"action":"text","text":"要输入的一行文本"}',
    '{"action":"keys","keys":["Enter"]}',
    '{"action":"kill"}',
    '{"action":"none"}',
    "text=输入一行并回车；keys=发送按键（Enter/Tab/Escape/Up/Down/Ctrl-C 等）；",
    "kill=命令已失败或无需继续；none=无法确定（留给用户手动输入）。",
  }, "\n")

  return runtime.run(agent, prompt):then_(function()
    local text
    local msgs = agent.messages or {}
    for i = #msgs, 1, -1 do
      local m = msgs[i]
      if m.role == "assistant" and type(m.content) == "string" and m.content ~= "" then
        text = m.content
        break
      end
    end
    local decision = _extract_decision(text)
    local acted = _apply_decision(session, decision)
    if not acted and decision == nil and type(text) == "string" and text:gsub("%s", "") ~= "" then
      -- 模型未按 JSON 返回：把纯文本当输入行兜底
      acted = M.send_text(session.id, (text:gsub("^%s+", ""):gsub("%s+$", "")))
    end
    if not acted then _notify_manual(session) end
    pcall(function() runtime.dispose(agent) end)
    return true
  end, function(err)
    pcall(function() runtime.dispose(agent) end)
    pcall(function()
      require("NeoAI.kernel.logger").warn("[pty] 判官请求异常: %s", tostring(err and err.message or err))
    end)
    _notify_manual(session)
  end)
end

-- ========== 会话管理 ==========

--- 触发一次判官决策
--- @param session table
local function _invoke_judge(session)
  if session.done or session.judging then return end
  local jcfg = _cfg().judge or {}
  if jcfg.enabled == false then
    _notify_manual(session)
    return
  end
  if session.judge_rounds >= (tonumber(jcfg.max_rounds) or 12) then
    _notify_manual(session)
    return
  end
  local judge = state.judge or _default_judge
  local d
  local ok, res = pcall(judge, session)
  if ok then d = res else d = nil end
  if type(d) ~= "table" or type(d.then_) ~= "function" then
    _notify_manual(session)
    return
  end
  session.judging = true
  session.judge_rounds = session.judge_rounds + 1
  d:then_(function()
    session.judging = false
  end, function(err)
    session.judging = false
    pcall(function()
      require("NeoAI.kernel.logger").warn("[pty] 判官异常: %s", tostring(err and err.message or err))
    end)
  end)
end

--- 轮询一次：检测等待并触发判官
--- @param session table
local function _poll(session)
  if session.done then return end
  local pid = _reader(session)
  if pid then
    local r = _rchar(pid)
    local prev = session.last_rchar
    local now = vim.uv.now()
    local fresh
    if prev == nil then
      fresh = true
    elseif r ~= nil then
      fresh = r > prev
    else
      fresh = (now - (session.last_inject_ms or 0)) > 300
    end
    -- 关键：仅在**真正派发**判官时才推进 last_rchar。若判官仍在运行（judging），保留上次基线，
    -- 使本轮等待在判官结束后仍被判定为「新等待」并再次触发，而不是被吞掉后永久挂起。
    if fresh and not session.judging then
      session.last_rchar = r
      session.last_inject_ms = now
      session.wait_count = (session.wait_count or 0) + 1
      session.waiting = true
      event_bus.emit(events.PTY_WAITING_INPUT, {
        id = session.id, pid = pid,
        description = session.description, command = session.command,
      })
      -- 悬浮终端：仅在「光标跟随」时弹出（不跟随时不打扰用户回看）。
      if _should_show_window(session, true) then
        _open_window(session)
      end
      _invoke_judge(session)
    end
  else
    session.waiting = false
  end
end

--- 结束会话（幂等）
--- @param session table
--- @param result table
local function _finish(session, result)
  if session.done then return end
  session.done = true
  session.status = "exited"
  if session.timer then
    pcall(function() session.timer:stop() end)
    pcall(function() session.timer:close() end)
    session.timer = nil
  end
  if session.unsub then pcall(session.unsub) session.unsub = nil end
  if state.active_id == session.id then state.active_id = nil end
  local win = _window()
  if win and session.window then pcall(function() win.close(session.id) end) end
  state.sessions[session.id] = nil
  event_bus.emit(events.PTY_EXITED, { id = session.id, code = result and result.code })
  session.d:resolve(result)
end

-- ========== 公开 API ==========

--- 交互式引擎是否可用
--- @return boolean
--- @return string|nil 原因
function M.available()
  local cfg = _cfg()
  if cfg.enabled == false then return false, "PTY_INTERACTIVE_DISABLED" end
  if cfg.engine == "off" then return false, "PTY_ENGINE_OFF" end
  if vim.fn.has("unix") ~= 1 then return false, "PTY_REQUIRES_UNIX" end
  if vim.fn.isdirectory("/proc") ~= 1 then return false, "PTY_REQUIRES_PROC" end
  if type(vim.uv) ~= "table" or type(vim.uv.new_timer) ~= "function" then
    return false, "PTY_REQUIRES_UV"
  end
  return true
end

--- 启动交互式会话
--- @param opts table {
---   argv table, cwd? string, env? table, cgroup_path? string, kill? function,
---   description? string, command? string, parent_agent? table, signal? table,
---   timeout_ms? number, max_output_bytes? number, title? string }
--- @return table|nil session, string|nil err
function M.open(opts)
  opts = opts or {}
  local cfg = _cfg()
  local ok, reason = M.available()
  if not ok then return nil, reason end

  local session = {
    id = stringx.uuid("pty"),
    output = "",
    status = "running",
    description = opts.description,
    command = opts.command,
    parent_agent = opts.parent_agent,
    cgroup_path = opts.cgroup_path,
    kill = opts.kill,
    last_rchar = nil,
    last_inject_ms = 0,
    wait_count = 0,
    judge_rounds = 0,
    judging = false,
    done = false,
    d = async.Deferred.new(),
  }

  local max_out = tonumber(opts.max_output_bytes) or
    tonumber(config_store.get("tools.run_command.max_output_bytes")) or 0

  local function append(data)
    if session.done or not data or #data == 0 then return end
    local s = table.concat(data, "\n")
    if max_out > 0 and #session.output + #s > max_out then
      s = s:sub(1, math.max(0, max_out - #session.output))
      session.truncated = true
      if session.kill then pcall(session.kill) end
      if session.job then pcall(vim.fn.jobstop, session.job) end
    end
    session.output = session.output .. s
    if session.window then
      local w = _window()
      if w then pcall(function() w.feed(session.id, s) end) end
    end
  end

  local timeout_ms = opts.timeout_ms or 30000
  local max_wall = tonumber((config_store.get("tools.run_command") or {}).max_wall_ms) or 0
  if max_wall > 0 and (timeout_ms < 0 or timeout_ms > max_wall) then timeout_ms = max_wall end

  local job = vim.fn.jobstart(opts.argv, {
    pty = true,
    cwd = opts.cwd,
    env = opts.env,
    on_stdout = function(_, data) append(data) end,
    on_stderr = function(_, data) append(data) end,
    on_exit = function(_, code)
      local result = {
        code = code,
        output = session.output,
        truncated = session.truncated,
        timed_out = session.timed_out,
        aborted = session.aborted,
        message = session.abort_message,
      }
      _finish(session, result)
    end,
  })
  if job <= 0 then
    return nil, "PTY_JOBSTART_FAILED"
  end
  session.job = job
  session.pid = vim.fn.jobpid(job)
  state.sessions[session.id] = session

  if opts.signal then
    session.unsub = opts.signal:subscribe(function(reason)
      if session.done then return end
      session.aborted = true
      session.abort_message = reason
      if session.kill then pcall(session.kill) end
      pcall(vim.fn.jobstop, job)
    end)
  end
  if timeout_ms > 0 then
    vim.defer_fn(function()
      if session.done then return end
      session.timed_out = true
      if session.kill then pcall(session.kill) end
      pcall(vim.fn.jobstop, job)
    end, timeout_ms)
  end

  -- 悬浮终端：always 立即弹出；on_wait 仅在检测到等待输入时弹出（见 _poll）。
  -- 两者都要求「光标跟随」，不跟随时不弹（用户正在回看上方内容）。
  session.title = opts.title
  if _should_show_window(session, false) then
    _open_window(session, opts.title)
  end

  -- 轮询检测
  local poll_ms = tonumber(cfg.poll_ms) or 80
  session.timer = vim.uv.new_timer()
  session.timer:start(poll_ms, poll_ms, vim.schedule_wrap(function()
    if not session.done then pcall(_poll, session) end
  end))

  event_bus.emit(events.PTY_STARTED, { id = session.id, pid = session.pid, command = opts.command })
  return session
end

--- 等待会话结束
--- @param session table
--- @return Deferred
function M.await(session)
  return session.d
end

--- 取会话
--- @param id string
--- @return table|nil
function M.get(id)
  return state.sessions[id]
end

--- 当前判官会话（terminal_* 工具用）
--- @return table|nil
function M.active()
  if state.active_id then return state.sessions[state.active_id] end
  -- 无判官上下文时，若仅有一个会话，则返回它（便于手动/单实例场景）
  local only
  for _, s in pairs(state.sessions) do
    if only then return nil end
    only = s
  end
  return only
end

--- 底层注入字节
--- @param id string
--- @param bytes string
--- @return boolean
function M.send_bytes(id, bytes)
  local session = state.sessions[id]
  if not session or session.done then return false end
  if type(bytes) ~= "string" or bytes == "" then return false end
  pcall(vim.fn.chansend, session.job, bytes)
  event_bus.emit(events.PTY_INPUT_SENT, { id = id, bytes = #bytes })
  return true
end

--- 注入一行文本（自动回车）
--- @param id string
--- @param text string
--- @return boolean
function M.send_text(id, text)
  return M.send_bytes(id, tostring(text or "") .. "\n")
end

--- 注入按键序列
--- @param id string
--- @param keys table|string
--- @return boolean
function M.send_keys(id, keys)
  local bytes = M.keys_bytes(keys)
  if bytes == "" then return false end
  return M.send_bytes(id, bytes)
end

--- 向会话进程组发送信号（如 SIGINT=2，补偿无控制终端时 Ctrl-C 不生效）
--- @param id string
--- @param sig number|string
--- @return boolean
function M.signal(id, sig)
  local session = state.sessions[id]
  if not session or session.done then return false end
  local n = tonumber(sig) or 2
  for _, pid in ipairs(_tree_pids(session)) do
    pcall(vim.uv.kill, pid, n)
  end
  return true
end

--- 结束会话
--- @param id string
--- @param reason? string
--- @return boolean
function M.kill(id, reason)
  local session = state.sessions[id]
  if not session or session.done then return false end
  if reason then session.abort_message = reason end
  if session.kill then pcall(session.kill) end
  -- 兜底：向进程树发 SIGTERM
  pcall(function() M.signal(id, 15) end)
  pcall(vim.fn.jobstop, session.job)
  return true
end

--- 设置自定义判官（测试/替换默认判官）
--- @param fn function|nil
function M.set_judge(fn)
  state.judge = fn
end

-- 测试钩子：判官决策解析（纯函数）
M._extract_decision = _extract_decision
-- 测试钩子：悬浮终端弹出判定（纯函数，受 chat follow 与 show_window 影响）
M._should_show_window = _should_show_window

--- 运行中的会话数量
--- @return number
function M.count()
  local n = 0
  for _ in pairs(state.sessions) do n = n + 1 end
  return n
end

--- 停止全部会话（插件卸载/热重载）
function M.stop_all()
  for id in pairs(state.sessions) do
    pcall(M.kill, id, "shutdown")
  end
  state.active_id = nil
end

--- 重置（测试用）
function M.reset()
  M.stop_all()
  state.sessions = {}
  state.judge = nil
  state.active_id = nil
  state.window = nil
end

return M
