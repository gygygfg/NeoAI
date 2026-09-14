--- 折叠组件
--- @module NeoAI.ui.components.fold
--- 聊天窗口折叠的共享实现：
--- - expr 折叠（foldexpr）：推理 / 每个工具块（调用+结果）各自独立成折叠，块间无需分隔行
--- - 折叠占位文本（foldtext）：推理 / 工具块折叠的摘要标签，按折叠首行区分类型

local M = {}

-- ========== 显示模式覆盖钩子 ==========
-- 显示模式插件（NeoAI.ui.components.display_modes.*）通过这里的覆盖钩子安装/卸载
-- 各自的折叠行为：默认（块折叠）与轨迹模式（按 turn 折叠）使用同一套 expr 折叠，
-- 但 foldexpr/foldtext 的求值逻辑不同。覆盖为空时回退到本模块的默认实现。
-- 由 chat_view 在插件 load/unload 时写入。

local foldexpr_override = nil
local foldtext_override = nil

--- 安装/清除 foldexpr 覆盖回调（nil = 使用默认块折叠）
--- @param fn function|nil 回调读取 vim.v.lnum 返回折叠等级
function M.set_foldexpr_override(fn)
  foldexpr_override = fn
end

--- 安装/清除 foldtext 覆盖回调（nil = 使用默认折叠文本）
--- @param fn function|nil 回调读取 vim.v.foldstart/foldend 返回折叠文本
function M.set_foldtext_override(fn)
  foldtext_override = fn
end

--- 当前是否有 foldexpr 覆盖（测试/诊断用）
--- @return boolean
function M.has_foldexpr_override()
  return foldexpr_override ~= nil
end

--- 当前是否有 foldtext 覆盖（测试/诊断用）
--- @return boolean
function M.has_foldtext_override()
  return foldtext_override ~= nil
end

-- ========== 折叠占位文本 ==========

--- 工具状态对应的折叠 emoji（首行带此 emoji 决定折叠文本的状态图标）
local STATUS_EMOJI = {
  running = "⏳",
  success = "✅",
  failure = "❌",
}

-- ========== 工具执行计时 ==========
-- tool_call_id -> { start_ms?, duration_ms?, status? }
-- 执行中只记 start_ms，完成后记 duration_ms 与状态（success/failure）。
-- 由 chat_view 在 TOOL_EXECUTION_STARTED/COMPLETED/ERROR 事件中写入。

local timing = {}

-- ========== 推理折叠标记 ==========
-- 由渲染层（message_list）在写入 buffer 后登记「推理块起始行」。
-- 折叠占位文本据此判定某折叠是否为真正的推理块：只有被显式登记的行才显示
-- 「🤔 思考过程」，其余未识别折叠显示中性占位，避免「所有折叠都渲染成思考过程」。
-- 以 buffer 为单位保存（弱键），随每次渲染全量重建。

local reasoning_lines = setmetatable({}, { __mode = "k" })

--- 登记某 buffer 的推理块起始行集合
--- @param buf number
--- @param set table<number, boolean>
function M.set_reasoning_lines(buf, set)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    reasoning_lines[buf] = set or {}
  end
end

--- 清除某 buffer 的推理块标记
--- @param buf number
function M.clear_reasoning_lines(buf)
  reasoning_lines[buf] = nil
end

--- 某行是否为已登记的推理块起始行
--- @param buf number
--- @param line number
--- @return boolean
function M.is_reasoning_start(buf, line)
  local set = reasoning_lines[buf]
  return (set ~= nil) and (set[line] == true)
end

local function _now_ms()
  return vim.uv.hrtime() / 1e6
end

--- 记录工具开始执行
--- @param tool_call_id string
--- @param timer table|nil 可暂停计时器（tool_loop 注入）：执行中耗时取自其活跃时间，
---   等待用户审批/提问的暂停期间不累计；无 timer 时回退到墙钟。
---   事件经 nvim_exec_autocmds 传递 data 会深拷贝并丢失元表/方法，因此这里保存的 timer
---   只是（可用的）副本；执行中耗时优先取 set_live_timer 注册的原对象实时值。
function M.record_start(tool_call_id, timer)
  local prev = timing[tool_call_id]
  timing[tool_call_id] = {
    timer = timer or (prev and prev.timer) or nil,
    start_ms = _now_ms(),
    duration_ms = nil,
    status = "running",
  }
end

--- 注册工具的原对象计时器（tool_loop 直接调用）。
--- 事件总线经 nvim_exec_autocmds 传递 data 会深拷贝并丢失元表/方法，计时器的 elapsed
--- 等方法无法随事件传播；tool_loop 以原对象（含元表）注册到这里，get_duration 才可用它
--- 实时读取剔除用户交互等待的活跃耗时。已存在记录时仅更新 timer 字段。
--- @param tool_call_id string
--- @param timer table|nil
function M.set_live_timer(tool_call_id, timer)
  local rec = timing[tool_call_id]
  if rec then
    rec.timer = timer
  else
    timing[tool_call_id] = { timer = timer, start_ms = _now_ms(), duration_ms = nil, status = "running" }
  end
end

--- 记录工具执行结束
--- @param tool_call_id string
--- @param duration_ms number|nil
--- @param status string|nil "success" | "failure"（默认 success）
function M.record_end(tool_call_id, duration_ms, status)
  local rec = timing[tool_call_id]
  if rec then
    rec.duration_ms = duration_ms
    rec.status = status or "success"
  else
    timing[tool_call_id] = { start_ms = nil, duration_ms = duration_ms, status = status or "success" }
  end
end

--- 工具耗时：未完成返回已执行时长，已完成返回总时长
--- @param tool_call_id string|nil
--- @return number|nil ms
function M.get_duration(tool_call_id)
  if not tool_call_id then return nil end
  local rec = timing[tool_call_id]
  if not rec then return nil end
  if rec.duration_ms then return rec.duration_ms end
  -- 优先用可暂停计时器的活跃耗时：等待用户交互的暂停期间耗时保持不变。
  -- 计时器须是 set_live_timer 注册的原对象（含元表）；经事件总线深拷贝的副本无 elapsed，
  -- 会回退到墙钟。
  if rec.timer and rec.timer.elapsed then
    return rec.timer:elapsed()
  end
  if rec.start_ms then return _now_ms() - rec.start_ms end
  return nil
end

--- 工具状态：执行中 running / 成功 success / 失败 failure
--- 供渲染在工具结果消息到达前也能按各自状态更新折叠文本。
--- @param tool_call_id string|nil
--- @return string|nil
function M.get_status(tool_call_id)
  if not tool_call_id then return nil end
  local rec = timing[tool_call_id]
  if not rec then return nil end
  return rec.status or (rec.duration_ms and "success" or "running")
end

--- 是否仍有工具在执行（用于驱动折叠文本的定时刷新）
--- @return boolean
function M.has_running()
  for _, rec in pairs(timing) do
    if not rec.duration_ms then return true end
  end
  return false
end

--- 清空计时（窗口关闭/会话切换时调用）
function M.clear_timing()
  timing = {}
end

--- 格式化毫秒为可读文本：<1s 用 ms，否则用 s
--- @param ms number
--- @return string
function M.format_ms(ms)
  ms = math.max(0, ms or 0)
  if ms < 1000 then
    return string.format("%.0fms", ms)
  end
  return string.format("%.1fs", ms / 1000)
end

--- 从折叠首行提取工具状态
--- @param first string 折叠首行
--- @return string|nil "running"|"success"|"failure"（无状态 emoji 时 nil）
local function _tool_status(first)
  if first:find("⏳", 1, true) then return "running" end
  if first:find("✅", 1, true) then return "success" end
  if first:find("❌", 1, true) then return "failure" end
  return nil
end

--- 识别折叠类型、状态、名称与目的说明（按折叠首行）
--- 工具块首行格式：<状态 emoji> 调用工具: name [· 目的] [· 耗时]（执行中）或
--- <状态 emoji> 工具: name [· 目的] [· 耗时]（已完成），目的/耗时可选。
--- @param first string 折叠首行
--- @return string kind "reasoning" | "tool_call" | "tool_result"
--- @return string|nil status "running" | "success" | "failure"（工具类折叠）
--- @return string|nil name 工具名（工具类折叠）
--- @return string|nil desc 目的说明（工具类折叠，可无）
function M.detect(first)
  local status = _tool_status(first)
  -- 耗时形如 " · 1.2s" / " · 800ms"（纯数字+单位），先剥掉；剩余部分解析 name 与 desc，
  -- 避免 name/desc 里的 " · " 干扰耗时识别。非耗时结尾（如无耗时的中文描述）不剥。
  local time = first:match("%·%s*%d+%.?%d*%s*[msd]+%s*$")
  local body = first
  if time then
    body = first:gsub("%·%s*%d+%.?%d*%s*[msd]+%s*$", "")
  end
  local call_name = body:match("调用工具:%s*([^%s%(%·]+)")
  if call_name then
    local desc = body:match("调用工具:%s*[^%s%(%·]+%s*·%s*(.-)%s*$")
    return "tool_call", status or "running", call_name, desc
  end
  local tool_name = body:match("工具:%s*([^%s%(%·]+)")
  if tool_name then
    local desc = body:match("工具:%s*[^%s%(%·]+%s*·%s*(.-)%s*$")
    return "tool_result", status or "success", tool_name, desc
  end
  return "reasoning", nil, nil, nil
end

--- 提取首行末尾的耗时文本（形如 " · 1.2s" / " · 800ms" / " · 30.0s"）
--- @param first string
--- @return string|nil
local function _extract_time(first)
  return first:match("%·%s*(%d+%.?%d*%s*[msd]+)%s*$")
end

--- 生成折叠占位文本（纯函数，供 foldtext 与测试使用）
--- 工具折叠格式：工具 emoji + 工具名称 + 目的 + 状态 emoji + 耗时
--- （🔧 name · 目的 ✅ 1.2s）。推理折叠沿用思考过程摘要。
--- @param first string 折叠首行
--- @param count number 折叠行数
--- @param is_reasoning boolean|nil 是否为已登记的推理块（默认 true，保持旧语义）
--- @return string
function M.label(first, count, is_reasoning)
  local kind, status, name, desc = M.detect(first)
  if kind == "tool_call" or kind == "tool_result" then
    local status_emoji = STATUS_EMOJI[status] or "⏳"
    local desc_str = desc and (desc ~= "") and (" · " .. desc) or ""
    local time_str = _extract_time(first)
    if time_str then
      return string.format("  🔧 %s%s %s %s", name, desc_str, status_emoji, time_str)
    end
    return string.format("  🔧 %s%s %s", name, desc_str, status_emoji)
  end
  if is_reasoning == false then
    return M.generic_label(first, count)
  end
  return string.format("  🤔 思考过程 %d 行", count)
end

--- 未识别折叠的中性占位文本（不冒充思考过程）：优先显示首行预览，否则显示行数
--- @param first string 折叠首行
--- @param count number 折叠行数
--- @return string
function M.generic_label(first, count)
  local preview = (first or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
  if preview == "" then
    return string.format("  📄 折叠 %d 行", count)
  end
  if #preview > 40 then preview = preview:sub(1, 40) .. "…" end
  return string.format("  📄 %s  (%d 行)", preview, count)
end

--- 折叠占位文本（foldtext 回调：读取 vim.v.foldstart/foldend 与折叠首行）
--- 有显示模式覆盖时委托给当前插件的 foldtext。仅「已登记为推理块」的折叠显示
--- 思考过程；其余未识别折叠显示中性占位，避免所有折叠都渲染成思考过程。
--- @return string
function M.foldtext()
  if foldtext_override then
    return foldtext_override()
  end
  local start = vim.v.foldstart
  local count = vim.v.foldend - start + 1
  local first = vim.fn.getline(start) or ""
  local kind = M.detect(first)
  if kind == "tool_call" or kind == "tool_result" then
    return M.label(first, count, true)
  end
  local buf = vim.api.nvim_get_current_buf()
  return M.label(first, count, M.is_reasoning_start(buf, start))
end

-- ========== expr 折叠 ==========

--- 判断缩进行是否为工具块的首行（含状态 emoji + 调用工具:/工具: 标记）。
--- 兼容旧格式 ⚡ 调用工具:。
--- @param text string 当前行文本
--- @return boolean
local function _is_tool_block_start(text)
  local t = text:gsub("^%s+", "")
  for _, e in ipairs({ "⏳", "✅", "❌", "⚡" }) do
    if t:sub(1, #e) == e then
      local rest = t:sub(#e + 1):gsub("^%s+", "")
      return rest:find("调用工具:", 1, true) == 1 or rest:find("工具:", 1, true) == 1
    end
  end
  return false
end

--- 逐行计算折叠等级（foldmethod=expr 的 foldexpr 回调）。
--- 默认块折叠：推理、每个工具块（调用+结果）各自独立成折叠，且块与块之间不需要任何分隔行：
--- - 缩进 2 格的连续行构成一个折叠块；
--- - 每个工具块首行（含 ⏳/✅/❌ 状态 emoji + 调用工具:/工具:）通过返回 ">1"
---   强制结束上一个折叠并开启新折叠，从而在同一缩进级别下也能把相邻工具块拆成独立折叠；
--- - 空白行如果紧邻缩进内容则并入该折叠（推理/工具结果内的空行不会中断折叠）。
--- 有显示模式覆盖时委托给当前插件的 foldexpr。
--- @return string|number
function M.foldexpr()
  if foldexpr_override then
    return foldexpr_override()
  end
  local ln = vim.v.lnum
  local text = vim.fn.getline(ln)
  local prev = vim.fn.getline(ln - 1)
  local next = vim.fn.getline(ln + 1)

  -- 缩进内容行：属于某个折叠块
  if text:match("^  ") then
    if _is_tool_block_start(text) then
      return ">1"
    end
    return "1"
  end

  -- 空白行：紧邻缩进内容（上一行或下一行缩进）时并入折叠，否则为普通空行
  if text:match("^%s*$") then
    if prev:match("^  ") or next:match("^  ") then
      return "1"
    end
    return "0"
  end

  -- 非缩进内容（角色头 / 正文 / 分割线）
  return "0"
end

return M
