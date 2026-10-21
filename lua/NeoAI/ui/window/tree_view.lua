--- 会话树视图
--- @module 'NeoAI.ui.window.tree_view'
--- 会话树窗口：展示会话分支，支持选择/新建/删除/展开折叠。
--- 默认展开根节点，子节点用连接线缩进显示。
---
--- 多线程：树的展平计算（分组 / 排序 / 隐藏支标记 / 空会话判定 / 连接线 / 每行文案）
--- 全部在 `utils.work` 线程池内执行；主线程只把工作线程返回的「二维文本片段」拼接后写入
--- buffer，不含任何分组/排序/前缀/文案计算。
--- 删除为乐观语义：按键后立即从 buffer 移除该节点及其整支子树行，随后按防抖窗口把多次
--- 按键合并为一次批量异步落盘；落盘成功后用真实数据重建校正，失败则提示并让行回归。

local window_manager = require("NeoAI.ui.window.manager")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")
local chat_view = require("NeoAI.ui.window.chat_view")
local services = require("NeoAI.kernel.services")
local config_store = require("NeoAI.kernel.config_store")
local work = require("NeoAI.utils.work")

-- 会话存储经服务定位器解析（禁用/未就绪时为 nil）：ui 不直接 require core 模块。
-- 以代理保持既有 `session_store.xxx` 调用点不变，调用时惰性解析服务。
local session_store = setmetatable({}, {
  __index = function(_, k)
    local ss = services.use("services.session")
    return ss and ss[k]
  end,
})

--- 聊天服务经服务定位器动态解析（禁用时为 nil）
local function _chat_service()
  return services.use("services.chat_service")
end

local M = {}

-- ========== 私有常量 ==========

--- 两次构建之间的最小间隔基数（毫秒）：会话事件/按键密集时避免全量重建过密。
--- 实际生效值按资源压力放大（ok ×1 / warn ×2 / critical ×4）：全量重建是主线程开销，
--- 资源紧张时让出 CPU 给 nvim 主循环。只读压力层的 TTL 缓存，不在热路径读 /proc。
local RENDER_BASE_INTERVAL_MS = 50

--- 当前生效的构建最小间隔（按资源压力缩放）
--- @return number
local function _render_interval_ms()
  local ok, pressure = pcall(require, "NeoAI.kernel.pressure")
  if ok and type(pressure.scaled_ms) == "function" then
    return pressure.scaled_ms(RENDER_BASE_INTERVAL_MS)
  end
  return RENDER_BASE_INTERVAL_MS
end
--- 卸载阈值：会话数少于此值时直接在主线程构建（实测几十个会话 <2ms，
--- 而跨线程往返固定开销约数百毫秒，卸载反而更慢）；超过才交给线程池。
local OFFLOAD_MIN_SESSIONS = 80
--- 删除/裁剪落盘防抖窗口（毫秒）：同一窗口内的多次按键合并为一次批量异步提交。
local FLUSH_DEBOUNCE_MS = 150
--- 无会话时的占位行
local EMPTY_LINE = "（无会话，按 N 新建）"
--- 单次 flush 内「构建 → 落地清理候选 → 再构建」的最大轮数（防止极端情况下自激）
local FLUSH_MAX_ROUNDS = 3

-- ========== 私有状态 ==========

local state = {
  win_id = nil,
  buf = nil,
  meta = {}, -- 与行平行的行元数据（字符串，按需解析）
  depths = "", -- 每行 1 字节 depth+48（乐观删除按 depth 找子树范围）
  lines = {}, -- 每行文本（由工作线程的二维片段拼接而来）
  selected_idx = 1,
  expanded = {}, -- session_id / "group:<cwd>" -> true|false
  unsubs = {},
  cursor_augroup = nil,
  digest_cache = {}, -- session_id -> { key, rounds }：轮次摘要缓存（未变更不重扫消息）
  pending_ops = {}, -- 待落盘的删除/裁剪操作（debounce 合并后批量提交）
  deleting = {}, -- session_id -> true：乐观删除进行中（防重入）
  cleanup_skipped = {}, -- 本次窗口内清理失败/跳过的空会话（不重试，避免抖动循环）
  flush_in_flight = false,
  pending_select_key = nil, -- 构建前记录的选中项 key，用于构建后重定位光标
}

-- 构建调度（照 chat_view 的渲染合并模式：同 tick 合并 + 最小间隔 + 代次校验）
local build_scheduled = false
local build_in_flight = false
local build_dirty = false
local build_epoch = 0
local last_build_ms = 0
local flush_scheduled = false
-- 测试/回退开关：强制在主线程同步执行构建（与工作线程共用同一份源码）
local force_sync_build = false
-- 前向声明（实现见下文「调度」小节，被更早定义的落盘/应用函数引用）
local _schedule_build
local _schedule_flush
-- 前向声明：行元数据/深度解析（_current_item 等更早的定义会用到）
local _row_item
local _row_depth

-- ========== 私有函数：消息摘要与轮次 ==========

--- 按 Unicode 字符而非 UTF-8 字节截取消息摘要（上限 20 字符）。
--- 纯 Lua 按首字节宽度前进 20 个字符，比 `vim.fn.strchars/strcharpart` 与
--- `vim.str_byteindex`（实测 33µs/次）快两个数量级；树首帧要为全部历史消息生成摘要。
--- @param content string|nil
--- @return string|nil
local function _message_preview(content)
  if not content then return nil end
  content = vim.trim(content:gsub("%s+", " "))
  if content == "" then return nil end
  if #content <= 20 then return content end -- 字节数 ≤ 20 ⇒ 字符数 ≤ 20
  local len = #content
  local i, chars = 1, 0
  while i <= len and chars < 20 do
    local b = content:byte(i)
    i = i + (b < 0x80 and 1 or (b < 0xE0 and 2 or (b < 0xF0 and 3 or 4)))
    chars = chars + 1
  end
  -- 扫到末尾说明字符数不足 20（多字节文本的字节数可能 > 20）：原样返回
  if i > len then return content end
  return content:sub(1, i - 1) .. "..."
end

--- 是否为子 Agent 结果消息（标记或投递包装文本，兼容旧数据）
--- @param message table
--- @return boolean
local function _is_sub_agent_message(message)
  if not message then return false end
  if message.sub_agent then return true end
  if message.role ~= "user" then return false end
  return type(message.content) == "string" and message.content:match("^%s*【子 Agent") ~= nil
end

--- 将一次 Agent 执行聚合为一个节点。
--- user 开始、下一条 user 前的最后一条非空 assistant 结束；
--- @param session table
--- @return table 数组 { user?, assistant?, first, last }
local function _conversation_rounds(session)
  local rounds = {}
  local current = nil
  for index, message in ipairs(session.messages or {}) do
    if _is_sub_agent_message(message) then
      -- 子 Agent 结果不是用户轮次：折叠进当前轮，不新开节点
      if current and message.role == "assistant" and message.content and message.content ~= "" then
        current.assistant = _message_preview(message.content) or current.assistant
      end
    elseif message.role == "user" then
      if current then
        current.last = index - 1
        rounds[#rounds + 1] = current
      end
      current = {
        user = _message_preview(message.content),
        first = index,
      }
    elseif message.role == "assistant" then
      if not current then
        current = { first = index }
      end
      if message.content and message.content ~= "" then
        current.assistant = _message_preview(message.content)
      end
    end
  end
  if current then
    current.last = #(session.messages or {})
    rounds[#rounds + 1] = current
  end
  return rounds
end

--- 是否为子 Agent 会话（metadata.tags 含 sub_agent）
--- @param session table
--- @return boolean
local function _is_sub_agent_session(session)
  local tags = session and session.metadata and session.metadata.tags
  if type(tags) ~= "table" then return false end
  for _, t in ipairs(tags) do
    if t == "sub_agent" then return true end
  end
  return false
end

--- 会话绑定的工作目录（`metadata.cwd`）；无则返回空串（归入「未绑定工作目录」组）。
--- @param session table
--- @return string
local function _cwd_of(session)
  local cwd = session and session.metadata and session.metadata.cwd
  if type(cwd) == "string" then return cwd end
  return ""
end

--- 当前编辑器工作区目录（用于把对应分组置顶）；检测失败回退 cwd。
--- @return string
local function _editor_group_cwd()
  local ok, wr = pcall(require, "NeoAI.core.session.workspace_root")
  if ok and wr and type(wr.detect_from_context) == "function" then
    local ok2, root = pcall(wr.detect_from_context)
    if ok2 and type(root) == "string" and root ~= "" then return root end
  end
  return vim.fn.getcwd()
end

--- 会话的轮次摘要（带缓存：仅 updated_at / 消息数变化时重扫消息并重算摘要）。
--- @param session table
--- @return table 数组 { user?, assistant?, first, last }
local function _session_rounds(session)
  local key = tostring(session.updated_at or 0) .. ":" .. #(session.messages or {})
  local cached = state.digest_cache[session.id]
  if cached and cached.key == key then return cached.rounds end
  local rounds = _conversation_rounds(session)
  state.digest_cache[session.id] = { key = key, rounds = rounds }
  return rounds
end

-- ========== 私有常量：树构建源码（主线程与工作线程共用） ==========

--- 会话树构建源码。纯 Lua、自包含（无 require / 无 upvalue），可在 utils.work 线程内
--- `assert(load(src))()(input)` 执行，也可在主线程同步执行同一份实现。
---
--- 传输格式围绕「主线程与工作线程两侧都便宜」设计：
--- - **输入**用平铺标量数组（省自身份字段 + 定长轮次段）：mpack 编码约 32ms/300 会话，
---   工作线程按下标步进解析（无字符串切分）。嵌套小表或拼成字符串都更贵（实测
---   嵌套 143ms、字符串两侧合计 ~150ms）。
--- - **输出**用字符串行 + 元数据字符串数组：mpack 解码约 24ms；若回传「片段数组 + 数字数组」
---   则解码需 ~104ms（大数字数组在 C 侧逐元素建值）。
---
--- 入参：{
---   sessions = { ... }  -- 每会话 9 个标量后接 4*nrounds 个标量：
---                       --   id, parent_id(""=无), cwd, name, updated_at, created_at,
---                       --   is_sub(0/1), msg_count, nrounds, [user, assistant, first, last]*
---   expanded_true  = string  -- 显式展开的键，\n 分隔
---   expanded_false = string  -- 显式折叠的键，\n 分隔
---   editor_cwd = string
--- }
--- 出参：{
---   rows = string        -- 二维文本：行以 \n 分隔、每行片段以 \t 分隔（主线程切片 concat）
---   meta = { string }    -- 与行平行的行元数据（每行 \t 分隔 7 字段）：
---                        --   kind(0=group/1=session), session_id, cwd, round, is_open, has_children, depth
---   depths = string      -- 每行 1 字节 depth+48（乐观删除按 depth 找子树范围，O(1) 读取）
---   cleanup_ids = { string } -- 整支皆空的清理候选
--- }
local TREE_BUILD_SRC = [==[
return function(input)
  local editor_cwd = input.editor_cwd or ""
  local exp_true, exp_false = {}, {}
  for k in (input.expanded_true or ""):gmatch("[^\n]+") do exp_true[k] = true end
  for k in (input.expanded_false or ""):gmatch("[^\n]+") do exp_false[k] = true end

  -- 1) 解析平铺快照（stride = 9 + 4*nrounds，按下标步进，无字符串切分）
  local flat = input.sessions or {}
  local sessions, n = {}, 0
  local i = 1
  while i + 8 <= #flat do
    local pid = flat[i + 1]
    local nr = flat[i + 8] or 0
    local base = i + 9
    local rounds = {}
    for r = 0, nr - 1 do
      local o = base + r * 4
      local user, assistant = flat[o], flat[o + 1]
      rounds[r + 1] = {
        user = (user ~= "" and user) or nil,
        assistant = (assistant ~= "" and assistant) or nil,
        first = flat[o + 2], last = flat[o + 3],
      }
    end
    n = n + 1
    sessions[n] = {
      id = flat[i],
      parent_id = (pid ~= "" and pid) or nil,
      cwd = flat[i + 2] or "",
      name = flat[i + 3],
      updated_at = flat[i + 4] or 0,
      created_at = flat[i + 5] or 0,
      is_sub = flat[i + 6] == 1,
      msg_count = flat[i + 7] or 0,
      rounds = rounds,
    }
    i = base + nr * 4
  end

  local by_id, children, sub, empty = {}, {}, {}, {}
  for k = 1, n do
    local s = sessions[k]
    by_id[s.id] = s
    sub[s.id] = s.is_sub == true
    empty[s.id] = (s.msg_count or 0) == 0
  end
  -- 一次建子索引（父级缺失/自环不计入：这类会话在树中不可达，与既有语义一致）
  for k = 1, n do
    local s = sessions[k]
    local pid = s.parent_id
    if pid and pid ~= s.id and by_id[pid] then
      local arr = children[pid]
      if not arr then arr = {}; children[pid] = arr end
      arr[#arr + 1] = s
    end
  end
  -- 子会话顺序：created_at 升序、id 升序（与 session_store.get_children 一致）
  for _, arr in pairs(children) do
    table.sort(arr, function(a, b)
      local at, bt = a.created_at or 0, b.created_at or 0
      if at ~= bt then return at < bt end
      return tostring(a.id) < tostring(b.id)
    end)
  end

  -- 子 Agent 会话及其整支后代整体隐藏：它们是主会话的附属会话，渲染出来会与用户分支混排。
  -- 单遍向下传播标记（不逐会话回溯祖先链），复杂度 O(n)。
  local hidden, stack = {}, {}
  for k = 1, n do
    local s = sessions[k]
    if sub[s.id] then
      hidden[s.id] = true
      stack[#stack + 1] = s.id
    end
  end
  while #stack > 0 do
    local id = table.remove(stack)
    local arr = children[id]
    if arr then
      for k = 1, #arr do
        local c = arr[k]
        if not hidden[c.id] then
          hidden[c.id] = true
          stack[#stack + 1] = c.id
        end
      end
    end
  end

  -- 空会话清理候选：自身无消息且整支（含全部后代）都为空。
  -- 活跃会话（正在聊天界面等待首条消息）由主线程过滤，不在此判定。
  local branch_empty = {}
  local function branch_is_empty(s)
    local cached = branch_empty[s.id]
    if cached ~= nil then return cached end
    branch_empty[s.id] = false -- 环保护
    local ok = empty[s.id] and true or false
    if ok then
      local arr = children[s.id]
      if arr then
        for k = 1, #arr do
          if not branch_is_empty(arr[k]) then
            ok = false
            break
          end
        end
      end
    end
    branch_empty[s.id] = ok
    return ok
  end
  local cleanup_ids = {}
  for k = 1, n do
    local s = sessions[k]
    if empty[s.id] and branch_is_empty(s) then
      cleanup_ids[#cleanup_ids + 1] = s.id
    end
  end

  -- 组头文本：▾/▸ + 目录名 + 完整路径 + 会话数（无绑定目录时省略路径）
  local function basename(path)
    local p = path:gsub("/+$", "")
    local base = p:match("([^/]+)$")
    if base and base ~= "" then return base end
    return path
  end
  local function group_label(cwd, count, is_open)
    local caret = is_open and "▾" or "▸"
    if cwd == "" then
      return string.format("%s 📁 （未绑定工作目录）  · %d 个会话", caret, count)
    end
    return string.format("%s 📁 %s  %s  · %d 个会话", caret, basename(cwd), cwd, count)
  end

  -- 单轮/会话节点文本：子 Agent 会话不标「用户」（其首条消息是任务而非用户输入）。
  local function round_label(round, s, is_root)
    local parts = {}
    if sub[s.id] then
      if is_root then
        local name = s.name
        parts[#parts + 1] = "🤖 子 Agent" .. ((name and name ~= "") and ("：" .. name) or "")
      elseif round.user then
        parts[#parts + 1] = "📋 任务：" .. round.user
      end
      if round.assistant then parts[#parts + 1] = "🤖 " .. round.assistant end
      if #parts > 0 then return table.concat(parts, " | ") end
      return "子 Agent"
    end
    if round.user then parts[#parts + 1] = "👤 用户：" .. round.user end
    if round.assistant then parts[#parts + 1] = "🤖 AI：" .. round.assistant end
    if #parts > 0 then return table.concat(parts, " | ") end
    return "新会话"
  end

  -- 行文本与平行元数据：每行以 \t 分隔片段/字段，行间以 \n 分隔（主线程零结构解析）。
  -- 拼接走 `..` 快路径并避免逐行 gsub：预清洗在解析阶段对 cwd/name 各做一次即可
  -- （消息摘要已在主线程 _message_preview 折叠过全部空白）。
  local row_list, meta, depth_chars = {}, {}, {}
  local function push(prefix, label, kind, session_id, cwd, round, depth, is_open, has_children)
    local idx = #row_list + 1
    row_list[idx] = prefix .. "\t" .. label
    meta[idx] = kind .. "\t" .. (session_id or "") .. "\t" .. (cwd or "") .. "\t"
      .. (round or 0) .. "\t" .. (is_open and "1" or "0") .. "\t"
      .. (has_children and "1" or "0") .. "\t" .. (depth or 0)
    depth_chars[idx] = string.char(48 + math.min(99, depth or 0))
  end

  -- 按根会话绑定的工作目录分组（子 Agent 会话不参与分组与计数）
  local groups, order = {}, {}
  for k = 1, n do
    local s = sessions[k]
    if (s.parent_id == nil or s.parent_id == s.id) and not hidden[s.id] then
      local key = "group:" .. s.cwd
      local g = groups[key]
      if not g then
        g = { key = key, cwd = s.cwd, roots = {}, max_updated = s.updated_at or 0, count = 0 }
        groups[key] = g
        order[#order + 1] = g
      end
      g.roots[#g.roots + 1] = s
      if (s.updated_at or 0) > g.max_updated then g.max_updated = s.updated_at or 0 end
    end
  end
  -- 组内根会话：updated_at 倒序 + id 倒序决胜（与 session_store.get_roots 一致）
  for _, g in ipairs(order) do
    table.sort(g.roots, function(a, b)
      local at, bt = a.updated_at or 0, b.updated_at or 0
      if at ~= bt then return at > bt end
      return tostring(a.id) > tostring(b.id)
    end)
  end
  -- 会话数（含分支/多轮次所属会话）：按绑定 cwd 统计
  for k = 1, n do
    local s = sessions[k]
    if not hidden[s.id] then
      local g = groups["group:" .. s.cwd]
      if g then g.count = g.count + 1 end
    end
  end

  -- 组排序等级：0=精确实等编辑器工作区；1=路径边界匹配；2=其它。
  local function rank(cwd)
    if cwd == "" or editor_cwd == "" then return 2 end
    local a = cwd:gsub("/+$", "")
    local b = editor_cwd:gsub("/+$", "")
    if a == b then return 0 end
    if a ~= "" and b:sub(1, #a + 1) == a .. "/" then return 1 end
    if b ~= "" and a:sub(1, #b + 1) == b .. "/" then return 1 end
    return 2
  end
  table.sort(order, function(x, y)
    local rx, ry = rank(x.cwd), rank(y.cwd)
    if rx ~= ry then return rx < ry end
    if x.max_updated ~= y.max_updated then return x.max_updated > y.max_updated end
    return tostring(x.cwd) < tostring(y.cwd)
  end)

  -- 递归渲染：├─ / └─ / │ 连接线；空会话不渲染为节点，其子会话提升到当前层级。
  local function walk(s, depth, prefix, is_last)
    local visible = {}
    local arr = children[s.id]
    if arr then
      for k = 1, #arr do
        if not sub[arr[k].id] then visible[#visible + 1] = arr[k] end
      end
    end
    if empty[s.id] then
      for k = 1, #visible do
        walk(visible[k], depth, prefix, is_last and k == #visible)
      end
      return
    end
    local rounds = s.rounds or {}
    local is_open = exp_true[s.id] == true
    local has_children = #rounds > 1 or #visible > 0
    push(prefix .. (is_last and "└─ " or "├─ "), round_label(rounds[1] or {}, s, true),
      "1", s.id, s.cwd, nil, depth, is_open, has_children)
    if not is_open then return end
    local entry_count = #rounds - 1 + #visible
    local child_prefix = prefix .. (is_last and "   " or "│  ")
    local entry_idx = 0
    -- 首轮是会话节点本身；剩余轮次和分支会话作为其子节点连续展示。
    for ri = 2, #rounds do
      entry_idx = entry_idx + 1
      push(child_prefix .. (entry_idx == entry_count and "└─ " or "├─ "), round_label(rounds[ri], s, false),
        "1", s.id, s.cwd, ri, depth + 1, false, false)
    end
    for k = 1, #visible do
      entry_idx = entry_idx + 1
      walk(visible[k], depth + 1, child_prefix, entry_idx == entry_count)
    end
  end

  for gi = 1, #order do
    local g = order[gi]
    local is_last_group = gi == #order
    local is_open = not exp_false[g.key] -- 分组：nil=展开
    push(is_last_group and "└─ " or "├─ ", group_label(g.cwd, g.count, is_open),
      "0", nil, g.cwd, nil, 0, is_open, true)
    if is_open then
      local child_prefix = is_last_group and "   " or "│  "
      for ri = 1, #g.roots do
        walk(g.roots[ri], 1, child_prefix, ri == #g.roots)
      end
    end
  end

  return {
    rows = table.concat(row_list, "\n"),
    meta = meta,
    depths = table.concat(depth_chars),
    cleanup_ids = cleanup_ids,
  }
end
]==]

--- 主线程构建（工作线程不可用 / 测试强制同步时使用同一份源码）
--- @param input table
--- @return table
local function _build_sync(input)
  local fn = assert(load(TREE_BUILD_SRC))
  return fn()(input)
end

--- 工作线程执行器（自包含：源码经额外参数传入，不捕获 upvalue）
--- @param input any
--- @param src string
--- @return any
local function _build_runner(input, src)
  return assert(load(src))()(input)
end

-- ========== 私有函数：快照与结果应用 ==========

--- 组装构建快照（主线程只做 O(n) 拷贝 + 每会话 2 次 gsub，不做分组/排序/前缀/文案计算）。
--- @return table { sessions = array, expanded_true = string, expanded_false = string, editor_cwd = string }
local function _collect_snapshot()
  local flat = {}
  local all = session_store.get_all() or {}
  local live = {}
  local count = 0
  for id, s in pairs(all) do
    live[id] = true
    count = count + 1
    local rounds = _session_rounds(s)
    -- cwd / name 会进入行文本与元数据：在此一次性清洗制表符/换行（每会话 2 次）。
    -- 消息摘要已在 _message_preview 折叠过全部空白；id 与数值为生成值，无需清洗。
    flat[#flat + 1] = s.id
    flat[#flat + 1] = s.parent_id or ""
    flat[#flat + 1] = (_cwd_of(s):gsub("[\t\n\r]", " "))
    flat[#flat + 1] = (((s.metadata and s.metadata.name) or ""):gsub("[\t\n\r]", " "))
    flat[#flat + 1] = s.updated_at or 0
    flat[#flat + 1] = s.created_at or 0
    flat[#flat + 1] = _is_sub_agent_session(s) and 1 or 0
    flat[#flat + 1] = #(s.messages or {})
    flat[#flat + 1] = #rounds
    for i = 1, #rounds do
      local r = rounds[i]
      flat[#flat + 1] = r.user or ""
      flat[#flat + 1] = r.assistant or ""
      flat[#flat + 1] = r.first or 0
      flat[#flat + 1] = r.last or 0
    end
  end
  -- 回收已消失会话的摘要缓存
  for id in pairs(state.digest_cache) do
    if not live[id] then state.digest_cache[id] = nil end
  end
  -- 真正的根会话默认展开（被提升上来的子会话保持折叠，与既有语义一致）
  for id, s in pairs(all) do
    local is_root = s.parent_id == nil or s.parent_id == s.id
    if is_root and state.expanded[id] == nil then state.expanded[id] = true end
  end
  -- 展开态按真/假分两组（分组 nil=展开、会话 nil=折叠，语义不同，不能合并）
  local t, f = {}, {}
  for k, v in pairs(state.expanded) do
    if v == true then
      t[#t + 1] = k
    else
      f[#f + 1] = k
    end
  end
  return {
    sessions = flat,
    count = count,
    expanded_true = table.concat(t, "\n"),
    expanded_false = table.concat(f, "\n"),
    editor_cwd = _editor_group_cwd(),
  }
end

--- 行元数据 -> 稳定的选中项 key（构建后据此重定位光标）
--- @param item table|nil
--- @return string|nil
local function _item_key(item)
  if not item then return nil end
  if item.kind == "group" then return "group\t" .. tostring(item.key) end
  return "session\t" .. tostring(item.session_id) .. "\t" .. tostring(item.round or 0)
end

--- 当前光标所在项（以窗口实际光标行为准，避免鼠标点击后 selected_idx 失同步）
--- @return table|nil
local function _current_item()
  if not M.has_window() then return nil end
  local row = vim.api.nvim_win_get_cursor(state.win_id)[1]
  if row < 1 or row > #state.meta then return nil end
  local item = _row_item(row)
  if item then item._row = row end
  return item
end

--- 构建应用后恢复选中行。
--- 选中项在构建前后通常只发生小幅位移（删除/折叠），因此在原索引附近**有界**搜索同一项
--- （只解析少量行元数据），找不到则钳制到有效范围。
local function _restore_selection()
  local key = state.pending_select_key
  local idx = nil
  local total = #state.meta
  if key and total > 0 then
    local center = math.max(1, math.min(total, state.selected_idx))
    local function matches(row)
      local item = _row_item(row)
      return item ~= nil and _item_key(item) == key
    end
    if matches(center) then
      idx = center
    else
      for delta = 1, 50 do
        local up, down = center - delta, center + delta
        if down <= total and matches(down) then idx = down break end
        if up >= 1 and matches(up) then idx = up break end
      end
    end
  end
  if not idx and total > 0 then
    idx = math.max(1, math.min(total, state.selected_idx))
  end
  state.selected_idx = idx or 1
  if not M.has_window() then return end
  if idx then
    pcall(vim.api.nvim_win_set_cursor, state.win_id, { idx, 0 })
  end
end

--- 检查是否已有同 id（且同起始行）的待落盘操作（防重复入队）
--- @param op string
--- @param id string
--- @param first number|nil
--- @return boolean
local function _op_pending(op, id, first)
  for _, it in ipairs(state.pending_ops) do
    if it.op == op and it.id == id and (first == nil or it.first == first) then return true end
  end
  return false
end

--- 把操作投递给会话存储（不关心 UI 回调，用于关窗等收尾场景）
--- @param ops table
local function _dispatch_ops(ops)
  if #ops == 0 then return end
  pcall(function() return session_store.mutate_async(ops) end)
end

--- 同步落地待办操作（测试与首帧路径）：走与异步完全相同的**批量**入口——
--- 一次整文件重写覆盖整批操作（逐条同步 delete 会各重写一次整文件，代价随条数线性放大）。
local function _flush_ops_sync()
  if #state.pending_ops == 0 then return end
  local ops = state.pending_ops
  state.pending_ops = {}
  local err = nil
  local ok, d = pcall(function() return session_store.mutate_async(ops) end)
  if not ok or type(d) ~= "table" or type(d.then_) ~= "function" then
    err = ok and "批量落盘入口不可用" or d
  else
    local settled = false
    d:then_(function() settled = true end, function(e) err = e; settled = true end)
    vim.wait(120000, function() return settled end, 5)
    if not settled then err = "批量落盘超时" end
  end
  for _, op in ipairs(ops) do
    if op.id then state.deleting[op.id] = nil end
    if err and op.cleanup and op.id then state.cleanup_skipped[op.id] = true end
  end
  if err then
    local msg = type(err) == "table" and (err.message or err.kind) or err
    vim.notify("[NeoAI] 删除失败，数据未变: " .. tostring(msg), vim.log.levels.ERROR)
  end
end

--- 提交待办操作（异步批量；失败回滚渲染）
local function _flush_ops_async()
  if state.flush_in_flight then return end
  if #state.pending_ops == 0 then return end
  local ops = state.pending_ops
  state.pending_ops = {}
  state.flush_in_flight = true
  local epoch = build_epoch
  local ok, res = pcall(function() return session_store.mutate_async(ops) end)
  if not ok or type(res) ~= "table" or type(res.then_) ~= "function" then
    state.flush_in_flight = false
    for _, op in ipairs(ops) do
      if op.id then
        state.deleting[op.id] = nil
        if op.cleanup then state.cleanup_skipped[op.id] = true end
      end
    end
    vim.notify("[NeoAI] 删除失败，数据未变: " .. tostring(res), vim.log.levels.ERROR)
    _schedule_build()
    return
  end
  res:then_(function()
    state.flush_in_flight = false
    for _, op in ipairs(ops) do
      if op.id then state.deleting[op.id] = nil end
    end
    if epoch ~= build_epoch then return end
    -- 用真实数据校正渲染（乐观删行期间可能残留连接线/分组计数）
    _schedule_build()
    if #state.pending_ops > 0 then _schedule_flush() end
  end, function(err)
    state.flush_in_flight = false
    for _, op in ipairs(ops) do
      if op.id then
        state.deleting[op.id] = nil
        if op.cleanup then state.cleanup_skipped[op.id] = true end
      end
    end
    if epoch ~= build_epoch then return end
    -- 语义：数据未变——提示后重新构建，使被乐观移除的行回归。
    local msg = type(err) == "table" and (err.message or err.kind) or err
    vim.notify("[NeoAI] 删除失败，数据未变: " .. tostring(msg), vim.log.levels.ERROR)
    _schedule_build()
    if #state.pending_ops > 0 then _schedule_flush() end
  end)
end

--- 调度一次落盘（debounce：同一窗口内的多次按键合并为一次批量提交）
_schedule_flush = function()
  if flush_scheduled then return end
  flush_scheduled = true
  local epoch = build_epoch
  vim.defer_fn(function()
    flush_scheduled = false
    if epoch ~= build_epoch then return end
    _flush_ops_async()
  end, FLUSH_DEBOUNCE_MS)
end

--- 空会话清理候选入队（活跃会话由主线程过滤；失败项本次窗口内不重试）
--- @param ids table|nil
local function _queue_cleanup(ids)
  if type(ids) ~= "table" or #ids == 0 then return end
  local cs = _chat_service()
  local queued = 0
  for _, id in ipairs(ids) do
    if not state.cleanup_skipped[id] and not state.deleting[id] and not _op_pending("delete", id) then
      if not (cs and cs.is_session_active and cs.is_session_active(id)) then
        state.pending_ops[#state.pending_ops + 1] = {
          op = "delete",
          id = id,
          recursive = false,
          include_sub_agents = true,
          cleanup = true,
        }
        queued = queued + 1
      end
    end
  end
  if queued > 0 then _schedule_flush() end
end

--- 解析某行的元数据（懒解析：只在需要该行语义时调用，避免构建时全量 split）
--- @param row number 1-based
--- @return table|nil { kind, session_id?, key?, cwd, round?, depth, is_open, has_children }
_row_item = function(row)
  local raw = state.meta[row]
  if type(raw) ~= "string" then return nil end
  local f = {}
  for field in (raw .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = field end
  local cwd = f[3] or ""
  local kind = (f[1] == "0") and "group" or "session"
  local round = tonumber(f[4]) or 0
  return {
    kind = kind,
    session_id = (f[2] ~= "" and f[2]) or nil,
    key = (kind == "group") and ("group:" .. cwd) or nil,
    cwd = cwd,
    round = (round ~= 0) and round or nil,
    is_open = f[5] == "1",
    has_children = f[6] == "1",
    depth = tonumber(f[7]) or 0,
  }
end

--- 某行的 depth（O(1)：depths 是每行 1 字节的 depth+48 串）
--- @param row number 1-based
--- @return number
_row_depth = function(row)
  local byte = state.depths:byte(row)
  if not byte then return 0 end
  return byte - 48
end

--- 应用一次构建结果（主线程只做切片 + table.concat + nvim_buf_set_lines）
--- @param res table
--- @param epoch number|nil
local function _apply_build(res, epoch)
  if epoch and epoch ~= build_epoch then return end
  if not M.has_window() then return end
  local rows = (type(res) == "table" and res.rows) or ""
  -- 1) 二维片段 → 行文本（每行片段以 \t 分隔；常见 2 片段走快路径不建临时表）
  local lines = {}
  local row = 0
  for text in (rows .. "\n"):gmatch("([^\n]*)\n") do
    row = row + 1
    local tab = text:find("\t", 1, true)
    if not tab then
      lines[row] = text
    else
      local tail = text:find("\t", tab + 1, true)
      if not tail then
        lines[row] = text:sub(1, tab - 1) .. text:sub(tab + 1)
      else
        local parts, offset = {}, 1
        for frag in (text .. "\t"):gmatch("([^\t]*)\t") do
          parts[offset] = frag
          offset = offset + 1
        end
        lines[row] = table.concat(parts)
      end
    end
  end
  if #lines == 0 then lines = { EMPTY_LINE } end
  state.lines = lines
  state.meta = (type(res) == "table" and res.meta) or {}
  state.depths = (type(res) == "table" and res.depths) or ""
  local was_modifiable = vim.bo[state.buf].modifiable
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = was_modifiable
  _restore_selection()
  _queue_cleanup(type(res) == "table" and res.cleanup_ids or nil)
end

--- 真正发起一次构建。
--- 小规模树直接在主线程构建（比跨线程往返更快）；超过 `OFFLOAD_MIN_SESSIONS` 才交给
--- 线程池。两条路径共用同一份 `TREE_BUILD_SRC`，产出必然一致。
--- @param epoch number
local function _start_build(epoch)
  last_build_ms = vim.uv.hrtime() / 1e6
  local input = _collect_snapshot()
  state.pending_select_key = _item_key(_current_item())
  local offload = not force_sync_build and work.available()
    and (input.count or 0) >= OFFLOAD_MIN_SESSIONS
  if not offload then
    local ok, res = pcall(_build_sync, input)
    if ok then
      _apply_build(res, epoch)
    else
      vim.notify("[NeoAI] 会话树构建失败: " .. tostring(res), vim.log.levels.ERROR)
    end
    return
  end
  build_in_flight = true
  local ok, d = pcall(function()
    return work.run_codec(_build_runner, input, TREE_BUILD_SRC)
  end)
  if not ok or type(d) ~= "table" or type(d.then_) ~= "function" then
    build_in_flight = false
    local ok2, res = pcall(_build_sync, input)
    if ok2 then _apply_build(res, epoch) end
    return
  end
  d:then_(function(res)
    build_in_flight = false
    if epoch ~= build_epoch then return end
    _apply_build(res, epoch)
    if build_dirty then _schedule_build() end
  end, function(err)
    build_in_flight = false
    if epoch ~= build_epoch then return end
    -- 工作线程失败：回退到主线程同一份实现，保证界面始终有内容。
    local ok2, res = pcall(_build_sync, input)
    if ok2 then
      _apply_build(res, epoch)
    else
      local msg = type(err) == "table" and (err.message or err.kind) or err
      vim.notify("[NeoAI] 会话树构建失败: " .. tostring(msg), vim.log.levels.ERROR)
    end
  end)
end

--- 调度一次构建：同 tick 合并 + 最小间隔节流 + 在途合并 + 待落盘期间挂起
_schedule_build = function()
  if not M.has_window() then return end
  build_dirty = true
  if build_in_flight or build_scheduled then return end
  -- 有待落盘的删除/裁剪：挂起构建，避免旧快照把已乐观移除的行「复活」。
  if #state.pending_ops > 0 or state.flush_in_flight then return end
  build_scheduled = true
  local epoch = build_epoch
  local wait_ms = _render_interval_ms() - (vim.uv.hrtime() / 1e6 - last_build_ms)
  local function _run()
    if epoch ~= build_epoch then
      build_scheduled = false
      return
    end
    build_scheduled = false
    if not M.has_window() then return end
    if #state.pending_ops > 0 or state.flush_in_flight then return end
    if not build_dirty then return end
    build_dirty = false
    _start_build(epoch)
  end
  if wait_ms > 0 then
    vim.defer_fn(_run, math.ceil(wait_ms))
  else
    vim.schedule(_run)
  end
end

-- ========== 私有函数：行编辑（乐观删除） ==========

--- 即时移除一段连续行（乐观删除）：从 first 起按 depth 连续区间判定子树范围。
--- @param first number 起始行号（1-based）
--- @param depth number 该行 depth
--- @return number 移除的行数
local function _remove_rows(first, depth)
  local total = #state.meta
  if first < 1 or first > total then return 0 end
  local last = first
  while last < total do
    if _row_depth(last + 1) <= depth then break end
    last = last + 1
  end
  local new_meta, new_lines = {}, {}
  for i = 1, total do
    if i < first or i > last then
      new_meta[#new_meta + 1] = state.meta[i]
      new_lines[#new_lines + 1] = state.lines[i]
    end
  end
  state.meta = new_meta
  state.lines = new_lines
  if M.has_window() then
    local was_modifiable = vim.bo[state.buf].modifiable
    vim.bo[state.buf].modifiable = true
    vim.api.nvim_buf_set_lines(state.buf, first - 1, last, false, {})
    vim.bo[state.buf].modifiable = was_modifiable
    local target = math.max(1, math.min(#state.meta, first))
    state.selected_idx = target
    if #state.meta > 0 then
      pcall(vim.api.nvim_win_set_cursor, state.win_id, { target, 0 })
    end
  end
  return last - first + 1
end

--- 移动光标
--- @param delta number
local function _move(delta)
  if #state.meta == 0 then return end
  state.selected_idx = math.max(1, math.min(#state.meta, state.selected_idx + delta))
  if M.has_window() then
    pcall(vim.api.nvim_win_set_cursor, state.win_id, { state.selected_idx, 0 })
  end
end

--- 展开/折叠当前项（分组头或会话节点）。分组以「非显式 false」为展开态。
--- @param item table|nil
local function _toggle_expand(item)
  item = item or _current_item()
  if not item then return end
  if item.kind == "group" then
    state.expanded[item.key] = not (state.expanded[item.key] ~= false)
    _schedule_build()
    return
  end
  if not item.has_children then return end
  state.expanded[item.session_id] = not (state.expanded[item.session_id] == true)
  _schedule_build()
end

--- 显式展开（want=true）/折叠（want=false）当前项（供 o/O 使用）。
--- @param item table|nil
--- @param want boolean
local function _set_expand(item, want)
  item = item or _current_item()
  if not item then return end
  if item.kind == "group" then
    state.expanded[item.key] = want
    _schedule_build()
    return
  end
  if not item.has_children then return end
  state.expanded[item.session_id] = want
  _schedule_build()
end

--- 按 id 解析会话对象（树行不持有会话引用，避免删除后引用陈旧对象）
--- @param item table|nil
--- @return table|nil
local function _resolve_session(item)
  if not item or not item.session_id then return nil end
  return session_store.get(item.session_id)
end

--- 沿会话树向下的单子链取出末尾会话（叶）。
--- 子 Agent 会话不计入单子链（顺延时必须跳过），否则"主会话只有一个子 Agent 会话"时
--- 点主会话会误入子 Agent 会话。
--- @param session table
--- @return table 末尾会话
local function _downstream_leaf(session)
  local down = session_store.get_downstream(session.id, { skip_sub_agent = true })
  return down[#down] or session
end

--- 将给定会话打开到聊天界面（选择或新建共用）。
--- @param session table
--- @param round number|nil 选中的轮次；nil = 整个会话
local function _open_session_in_chat(session, round)
  if not session then return end
  -- 选择会话节点（未指定轮次）时顺延到单分支末尾；显式选中某轮次（回退改稿）不顺延。
  if not round then session = _downstream_leaf(session) end
  chat_view.open({ session_id = session.id, round = round })
  if config_store.get("ui.tree.auto_close_on_select", true) then M.close() end
end

--- 光标所在项所属分组的 cwd（分组头取自身；会话取绑定 cwd）；无则 nil。
--- @param item table|nil
--- @return string|nil
local function _item_cwd(item)
  if not item then return nil end
  local cwd = item.cwd
  if item.kind ~= "group" then
    local s = _resolve_session(item)
    if s then cwd = _cwd_of(s) end
  end
  if type(cwd) ~= "string" or cwd == "" then return nil end
  return cwd
end

--- 选择并打开聊天；作用于分组头时改为折叠/展开该组。
local function _select()
  local item = _current_item()
  if not item then return end
  if item.kind == "group" then
    _toggle_expand(item)
    return
  end
  _open_session_in_chat(_resolve_session(item), item.round)
end

--- 新建子分支：创建会话后直接切到聊天界面；作用于分组头或在组内时继承分组的 cwd。
local function _new_child()
  local item = _current_item()
  local session
  if not item then
    session = session_store.create()
  elseif item.kind == "group" then
    session = session_store.create({ cwd = _item_cwd(item) })
    state.expanded[item.key] = true
  else
    session = session_store.create({ parent_id = item.session_id })
    state.expanded[item.session_id] = true
  end
  _open_session_in_chat(session)
end

--- 新建根分支：创建会话后直接切到聊天界面；继承光标所在分组的 cwd。
local function _new_root()
  local item = _current_item()
  local session = session_store.create({ cwd = _item_cwd(item) })
  _open_session_in_chat(session)
end

--- 删除光标所在轮次（d）。乐观语义：
--- - 非首轮：即时移除该轮次行，随后入队异步裁剪；
--- - 首轮：该行同时承担会话节点身份（移除会让整支子树消失），不即时删行，
---   落盘后由重建校正为新的首轮摘要。
local function _delete_round()
  local item = _current_item()
  if not item then return end
  if item.kind == "group" then
    vim.notify("[NeoAI] 分组行不可删除", vim.log.levels.WARN)
    return
  end
  local session = _resolve_session(item)
  if not session then return end
  local rounds = _session_rounds(session)
  local round_idx = item.round or 1
  local round = rounds[round_idx]
  if not round or not round.first then return end
  if _op_pending("trim", session.id, round.first) then return end
  if round_idx > 1 then
    local row = vim.api.nvim_win_get_cursor(state.win_id)[1]
    _remove_rows(row, item.depth)
  end
  state.pending_ops[#state.pending_ops + 1] = {
    op = "trim",
    id = session.id,
    first = round.first,
    last = round.last or #(session.messages or {}),
    ts = os.time(),
  }
  _schedule_flush()
end

--- 删除该会话及全部后代分支（D）。乐观语义：即时移除该节点及整支子树行，随后异步落盘。
local function _delete_branch()
  local item = _current_item()
  if not item then return end
  if item.kind == "group" then
    vim.notify("[NeoAI] 分组行不可删除", vim.log.levels.WARN)
    return
  end
  local id = item.session_id
  if not id or state.deleting[id] then return end
  state.deleting[id] = true
  local row = vim.api.nvim_win_get_cursor(state.win_id)[1]
  _remove_rows(row, item.depth)
  state.pending_ops[#state.pending_ops + 1] = {
    op = "delete",
    id = id,
    recursive = true,
    include_sub_agents = true,
  }
  _schedule_flush()
end

--- 订阅会话变更（统一延迟到下一事件循环，让 chat 先绑定新建的空会话）
local function _subscribe()
  local function _on_change()
    vim.schedule(function()
      if M.has_window() then _schedule_build() end
    end)
  end
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.SESSION_CREATED, _on_change)
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.SESSION_DELETED, _on_change)
  state.unsubs[#state.unsubs + 1] = event_bus.on(events.SESSION_RENAMED, _on_change)
end

--- 设置键位
local function _set_keymaps()
  local keymap = require("NeoAI.ui.keymap")
  local actions = {
    quit = function() M.close() end,
    select = _select,
    new_child = _new_child,
    new_root = _new_root,
    delete_dialog = _delete_round,
    delete_branch = _delete_branch,
    expand = function() _set_expand(nil, true) end,
    collapse = function() _set_expand(nil, false) end,
  }
  vim.keymap.set("n", "j", function() _move(1) end, { buffer = state.buf, desc = "下移" })
  vim.keymap.set("n", "k", function() _move(-1) end, { buffer = state.buf, desc = "上移" })
  keymap.register_context("tree", actions, state.buf)

  -- 鼠标点击/滚动等移动光标时同步选中索引
  state.cursor_augroup = vim.api.nvim_create_augroup("NeoAITreeCursor", { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = state.cursor_augroup,
    buffer = state.buf,
    callback = function()
      if not M.has_window() then return end
      state.selected_idx = vim.api.nvim_win_get_cursor(state.win_id)[1]
    end,
  })
end

-- ========== 公开 API ==========

--- 打开会话树
--- @return table { win_id, buf }
function M.open()
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    vim.api.nvim_set_current_win(state.win_id)
    return { win_id = state.win_id, buf = state.buf }
  end
  session_store.init()
  local created = window_manager.create("tree", { title = "NeoAI Sessions" })
  state.win_id = created.win_id
  state.buf = created.buf
  vim.wo[state.win_id].cursorline = true
  vim.wo[state.win_id].wrap = false
  vim.bo[state.buf].modifiable = false
  _set_keymaps()
  _subscribe()
  -- 首帧同步构建：open() 返回即内容就绪（后续更新走异步节流构建）
  M.flush()
  return { win_id = state.win_id, buf = state.buf }
end

--- 关闭
function M.close()
  -- 递增代次：作废已排队/在途的构建回调（关窗后不得再写 buffer 或访问已注销服务）。
  build_epoch = build_epoch + 1
  build_scheduled = false
  build_dirty = false
  flush_scheduled = false
  state.pending_select_key = nil
  -- 未提交的用户删除不能丢：直接交给会话存储（其写盘链保证与其他写盘串行）。
  if #state.pending_ops > 0 then
    local ops = state.pending_ops
    state.pending_ops = {}
    _dispatch_ops(ops)
  end
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    window_manager.close(state.win_id)
  end
  -- 清理 buffer，避免重复打开后 :ls 出现多个同名残留
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  for _, unsub in ipairs(state.unsubs) do unsub() end
  state.unsubs = {}
  if state.cursor_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.cursor_augroup)
    state.cursor_augroup = nil
  end
  state.win_id = nil
  state.buf = nil
  state.selected_idx = 1
  state.expanded = {}
  state.meta = {}
  state.depths = ""
  state.lines = {}
  state.deleting = {}
  state.cleanup_skipped = {}
  state.digest_cache = {}
end

--- 是否有打开的窗口
--- @return boolean
function M.has_window()
  return state.win_id ~= nil and vim.api.nvim_win_is_valid(state.win_id)
end

--- 刷新（异步节流重建；立即需要内容时用 M.flush()）
function M.refresh()
  _schedule_build()
end

--- 同步完成所有待办：等待在途构建/落盘 → 落地待办操作 → 同步构建并应用。
--- 供 open() 首帧与测试使用，保证返回后 buffer 与磁盘状态都已稳定。
function M.flush()
  if build_in_flight or state.flush_in_flight then
    vim.wait(10000, function() return not build_in_flight and not state.flush_in_flight end, 5)
  end
  if not M.has_window() then
    _flush_ops_sync()
    return
  end
  for _ = 1, FLUSH_MAX_ROUNDS do
    if #state.pending_ops > 0 then _flush_ops_sync() end
    build_epoch = build_epoch + 1
    build_scheduled = false
    build_dirty = false
    state.pending_select_key = _item_key(_current_item())
    local ok, res = pcall(_build_sync, _collect_snapshot())
    if not ok then
      vim.notify("[NeoAI] 会话树构建失败: " .. tostring(res), vim.log.levels.ERROR)
      return
    end
    _apply_build(res, build_epoch)
    if #state.pending_ops == 0 then break end
  end
end

--- 重置（测试用）
function M.reset()
  M.close()
end

--- 测试辅助：强制主线程同步构建（与工作线程共用同一份源码，用于对比两条路径）
--- @param on boolean
function M._set_sync_build(on)
  force_sync_build = on == true
end

--- 测试辅助：跳过防抖窗口，立刻执行一次异步批量落盘（用于断言失败回滚等行为）。
--- @return boolean 是否真的发起了批次
function M._flush_async_now()
  flush_scheduled = false
  if #state.pending_ops == 0 or state.flush_in_flight then return false end
  _flush_ops_async()
  return state.flush_in_flight
end

--- 测试辅助：当前待落盘操作数
--- @return number
function M._pending_op_count()
  return #state.pending_ops
end

--- 测试辅助：组装构建快照
--- @return table
function M._collect_snapshot()
  return _collect_snapshot()
end

--- 测试辅助：主线程构建同一份快照
--- @param input table
--- @return table
function M._build_sync(input)
  return _build_sync(input)
end

--- 测试辅助：工作线程构建同一份快照
--- @param input table
--- @return Deferred
function M._build_worker(input)
  return work.run_codec(_build_runner, input, TREE_BUILD_SRC)
end

return M
