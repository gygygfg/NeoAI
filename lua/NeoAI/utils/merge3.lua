--- 三方合并（diff3）
--- @module NeoAI.utils.merge3
--- 纯 Lua、无 `vim.fn`/`vim.api` 依赖，可在 libuv 工作线程（`utils.work`）内使用。
--- 用于发布阶段的「base / ours / theirs」行级三方合并：仅当真实文件被外部改动、
--- 且候选与外部改动都相对 base 发生变化时调用（见 `sandbox/execution/candidate`）。
---
--- 语义：
---   * 只有一方改动 → 取该方；
---   * 两方改动同一 base 区间且结果相同 → 去重取一次（不冲突）；
---   * 两方改动同一 base 区间且结果不同 → 冲突（调用方据此保持待审、交 AI 处理）；
---   * 两方改动的 base 区间不相邻/不重叠 → 各自应用（合并）。
--- 通过行 diff（Myers）+ 变更簇归并实现，非行数爆炸时退化为 CAS（`too_large`）。

local M = {}

-- 合并规模上限：超过即放弃合并（调用方回退 CAS），避免工作线程/主线程被大文件 diff 拖死。
M.MAX_LINES = 20000

-- ========== 私有函数 ==========

--- 按行切分，保留行尾换行：`join(splitlines(s)) == s`（空串 → {}）。
--- @param s string
--- @return table 行数组
local function _splitlines(s)
  local lines = {}
  if s == nil or s == "" then return lines end
  local start = 1
  while true do
    local nl = s:find("\n", start, true)
    if not nl then
      lines[#lines + 1] = s:sub(start)
      break
    end
    lines[#lines + 1] = s:sub(start, nl) -- 含换行
    start = nl + 1
  end
  return lines
end

--- Myers 差异：返回 base(a) 与 side(b) 的匹配对（1-based 行号）。
--- @param a table 行数组（base）
--- @param b table 行数组（side）
--- @return table 匹配对数组 { {i, j}, ... }（按 i 升序）
local function _myers_matches(a, b)
  local n, m = #a, #b
  if n == 0 or m == 0 then return {} end
  local max = n + m
  local v = { [1] = 0 }
  local trace = {}
  local found
  for d = 0, max do
    -- 记录进入本步（即上一步结束后）的 V 快照，供回溯判定 prev_k。
    local snap = {}
    for k = -d - 1, d + 1 do snap[k] = v[k] end
    trace[d + 1] = snap
    for k = -d, d, 2 do
      local x
      if k == -d or (k ~= d and (v[k - 1] or -1) < (v[k + 1] or -1)) then
        x = v[k + 1] or 0
      else
        x = (v[k - 1] or 0) + 1
      end
      local y = x - k
      while x < n and y < m and a[x + 1] == b[y + 1] do
        x = x + 1
        y = y + 1
      end
      v[k] = x
      if x >= n and y >= m then found = d; break end
    end
    if found then break end
  end
  if not found then return {} end
  -- 回溯：从 (n, m) 收集对角（匹配）上、从后往前的匹配对。
  local matches = {}
  local x, y = n, m
  local d = found
  while d > 0 do
    local snap = trace[d + 1]
    local k = x - y
    local prev_k
    if k == -d or (k ~= d and (snap[k - 1] or -1) < (snap[k + 1] or -1)) then
      prev_k = k + 1
    else
      prev_k = k - 1
    end
    local prev_x = snap[prev_k] or 0
    local prev_y = prev_x - prev_k
    while x > prev_x and y > prev_y do
      matches[#matches + 1] = { x, y }
      x = x - 1
      y = y - 1
    end
    x, y = prev_x, prev_y
    d = d - 1
  end
  while x > 0 and y > 0 do
    matches[#matches + 1] = { x, y }
    x = x - 1
    y = y - 1
  end
  -- 反转为从前到后（i 升序）。
  local out = {}
  for idx = #matches, 1, -1 do out[#out + 1] = matches[idx] end
  return out
end

--- 由 base/side 行数组计算变更块（相对 base）。
--- @param a table base 行数组
--- @param b table side 行数组
--- @return table 变更块数组 { { bs, es, lines }, ... }（bs/es 为 0-based 半开区间）
local function _changes(a, b)
  local matches = _myers_matches(a, b)
  local out = {}
  local pi, pj = 0, 0
  local function push(ai, alen, bj, blen)
    if alen == 0 and blen == 0 then return end
    local lines = {}
    for k = bj + 1, bj + blen do lines[#lines + 1] = b[k] end
    out[#out + 1] = { bs = ai, es = ai + alen, lines = lines }
  end
  for _, mt in ipairs(matches) do
    local i, j = mt[1], mt[2]
    push(pi, (i - 1) - pi, pj, (j - 1) - pj)
    pi, pj = i, j
  end
  push(pi, #a - pi, pj, #b - pj)
  return out
end

--- 变更块 h 与 base 区间 [cbs, ces) 是否重叠（空变更块视为点）。
--- @param h table { bs, es, lines }
--- @param cbs number
--- @param ces number
--- @return boolean
local function _overlaps_range(h, cbs, ces)
  local hbs, hes = h.bs, h.es
  if hbs == hes then
    return hbs > cbs and hbs < ces
  end
  return hbs < ces and hes > cbs
end

--- 两个变更块是否重叠（供扫描时判定是否合并为同一冲突簇）。
--- @param a table
--- @param b table
--- @return boolean
local function _overlaps(a, b)
  local a0, a1 = a.bs, a.es
  local b0, b1 = b.bs, b.es
  if a0 == a1 and b0 == b1 then return a0 == b0 end
  if a0 == a1 then return b0 < a0 and a0 < b1 end
  if b0 == b1 then return a0 < b0 and b0 < a1 end
  return a0 < b1 and b0 < a1
end

--- 把某一侧在 base 区间 [cbs, ces) 内的变更渲染为行数组（含未改动的 base 行）。
--- hunks 为该侧全部变更块（升序）；from/to 为落在簇内的索引闭区间。
--- @return table 行数组
local function _render(base, hunks, from_idx, to_idx, cbs, ces)
  local res = {}
  local pos = cbs
  for idx = from_idx, to_idx do
    local h = hunks[idx]
    for k = pos, h.bs - 1 do res[#res + 1] = base[k + 1] end
    for _, l in ipairs(h.lines) do res[#res + 1] = l end
    if h.es > pos then pos = h.es end
  end
  for k = pos, ces - 1 do res[#res + 1] = base[k + 1] end
  return res
end

--- 数组相等（逐元素比较）。
--- @param a table
--- @param b table
--- @return boolean
local function _eq(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

--- 三方合并两个变更块列表。返回合并后的行数组或 nil（冲突）。
--- @param base table base 行数组
--- @param ours table 我方变更块
--- @param theirs table 对方变更块
--- @return table|nil merged_lines
local function _merge_changes(base, ours, theirs)
  local out = {}
  local pos = 0
  local i, j = 1, 1
  local no, nt = #ours, #theirs

  -- 追加 base 的 [a, b) 行（0-based 半开）。
  local function emit_base(a, b)
    for k = a, b - 1 do out[#out + 1] = base[k + 1] end
  end

  while i <= no or j <= nt do
    local a = ours[i]
    local b = theirs[j]
    if a and b and _overlaps(a, b) then
      -- 合并重叠簇：不断吸收与当前 base 区间 [cbs, ces) 重叠的两侧变更块。
      local cbs = math.min(a.bs, b.bs)
      local ces = math.max(a.es, b.es)
      -- 簇至少包含触发重叠的 a、b 两个变更块，先消费它们，再吸收相邻重叠块。
      local ia, ib = i + 1, j + 1
      local changed = true
      while changed do
        changed = false
        while ia <= no and _overlaps_range(ours[ia], cbs, ces) do
          local h = ours[ia]
          if h.bs < cbs then cbs = h.bs; changed = true end
          if h.es > ces then ces = h.es; changed = true end
          ia = ia + 1
        end
        while ib <= nt and _overlaps_range(theirs[ib], cbs, ces) do
          local h = theirs[ib]
          if h.bs < cbs then cbs = h.bs; changed = true end
          if h.es > ces then ces = h.es; changed = true end
          ib = ib + 1
        end
      end
      emit_base(pos, cbs)
      local ro = _render(base, ours, i, ia - 1, cbs, ces)
      local rt = _render(base, theirs, j, ib - 1, cbs, ces)
      if _eq(ro, rt) then
        for _, l in ipairs(ro) do out[#out + 1] = l end
      else
        return nil -- 冲突
      end
      pos = ces
      i, j = ia, ib
    elseif a and (not b or a.bs < b.bs or (a.bs == b.bs and a.es <= b.es)) then
      emit_base(pos, a.bs)
      for _, l in ipairs(a.lines) do out[#out + 1] = l end
      if a.es > pos then pos = a.es end
      i = i + 1
    else
      emit_base(pos, b.bs)
      for _, l in ipairs(b.lines) do out[#out + 1] = l end
      if b.es > pos then pos = b.es end
      j = j + 1
    end
  end
  emit_base(pos, #base)
  return out
end

-- ========== 公开接口 ==========

--- 三方合并。
--- @param base string 基线内容（冻结时真实文件内容）
--- @param ours string 我方（候选）内容
--- @param theirs string 对方（当前真实文件）内容
--- @return table { ok=true, merged=string } |
---   { ok=false, conflict=true } | { ok=false, too_large=true }
function M.merge(base, ours, theirs)
  base = base or ""
  ours = ours or ""
  theirs = theirs or ""
  if ours == theirs then return { ok = true, merged = ours } end
  if theirs == base then return { ok = true, merged = ours } end
  if ours == base then return { ok = true, merged = theirs } end
  local b = _splitlines(base)
  local o = _splitlines(ours)
  local t = _splitlines(theirs)
  if #b > M.MAX_LINES or #o > M.MAX_LINES or #t > M.MAX_LINES then
    return { ok = false, too_large = true }
  end
  local ours_ch = _changes(b, o)
  local theirs_ch = _changes(b, t)
  local merged = _merge_changes(b, ours_ch, theirs_ch)
  if not merged then return { ok = false, conflict = true } end
  return { ok = true, merged = table.concat(merged) }
end

-- 暴露内部函数供测试。
M._splitlines = _splitlines
M._myers_matches = _myers_matches
M._changes = _changes

return M
