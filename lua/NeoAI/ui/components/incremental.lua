--- 增量渲染基础设施
--- @module NeoAI.ui.components.incremental
--- 聊天界面增量刷新的公共实现：
--- - 行差异计算（最长公共前缀 / 后缀）与局部写入（无差异时完全不触碰 buffer）；
--- - 块级渲染缓存：按「块 key + 签名」复用未变化块的渲染结果，避免整段重新渲染；
--- 供 message_list（对话模式）与 display_modes.trajectory（轨迹模式）共用。

local M = {}

-- ========== 行差异 ==========

--- 计算两个行数组的差异区间（最长公共前缀 + 最长公共后缀，二者不重叠）。
--- 返回的 start/removed/inserted 可直接用于 nvim_buf_set_lines 的局部替换：
---   nvim_buf_set_lines(buf, start - 1, start - 1 + removed, false, lines)
--- @param old_lines table|nil 旧行数组
--- @param new_lines table|nil 新行数组
--- @return table { changed, start, removed, inserted, lines }
---   changed 是否有差异；start 1-based 起始行；removed 需删除的旧行数；
---   inserted 新插入行数；lines 新插入的行（new_lines 的对应切片）
function M.diff_range(old_lines, new_lines)
  old_lines = old_lines or {}
  new_lines = new_lines or {}
  local no, nn = #old_lines, #new_lines

  -- 最长公共前缀
  local pre = 0
  local max_pre = math.min(no, nn)
  while pre < max_pre and old_lines[pre + 1] == new_lines[pre + 1] do
    pre = pre + 1
  end

  -- 最长公共后缀（不与前缀重叠）
  local suf = 0
  local max_suf = math.min(no, nn) - pre
  while suf < max_suf and old_lines[no - suf] == new_lines[nn - suf] do
    suf = suf + 1
  end

  local start = pre + 1
  local removed = no - pre - suf
  local inserted = nn - pre - suf
  local lines = {}
  for i = 1, inserted do
    lines[i] = new_lines[start + i - 1]
  end
  return {
    changed = removed > 0 or inserted > 0,
    start = start,
    removed = removed,
    inserted = inserted,
    lines = lines,
  }
end

--- 把新行增量写入 buffer：无差异时完全不写；有差异时只替换差异区间。
--- @param buf number
--- @param old_lines table|nil 当前 buffer 内容；nil = 内容未知（执行全量替换）
--- @param new_lines table|nil 目标内容
--- @return table { changed, start, removed, inserted, full }
---   full=true 表示走了全量替换（旧内容未知）；removed=-1 表示全量（删除至末尾）
function M.apply(buf, old_lines, new_lines)
  new_lines = new_lines or {}
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return { changed = false, start = 1, removed = 0, inserted = 0, full = false }
  end
  vim.bo[buf].modifiable = true
  if old_lines == nil then
    -- 内容未知（首次渲染 / 缓存失效 / 会话切换）：全量替换
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
    return { changed = true, start = 1, removed = -1, inserted = #new_lines, full = true }
  end
  local d = M.diff_range(old_lines, new_lines)
  if not d.changed then
    return { changed = false, start = d.start, removed = 0, inserted = 0, full = false }
  end
  vim.api.nvim_buf_set_lines(buf, d.start - 1, d.start - 1 + d.removed, false, d.lines)
  return { changed = true, start = d.start, removed = d.removed, inserted = d.inserted, full = false }
end

--- 由 apply 结果推导需要重贴高亮的行区间（1-based，含两端；0,0 表示空区间）。
--- 只有真正写入的行才需要重贴：前缀区域的内容与高亮都未变化，无需触碰。
--- @param d table apply 的返回值
--- @return number from 起始行（0 = 空）
--- @return number "to" 结束行
function M.written_range(d)
  if not d or not d.changed then return 0, 0 end
  if d.full then return 1, d.inserted end
  if d.inserted <= 0 then return 0, 0 end
  return d.start, d.start + d.inserted - 1
end

-- ========== 文本指纹 ==========

--- 文本指纹：长度 + 首/中/尾三段采样。用于块缓存签名——只判断「是否变化」而从不展示，
--- 字节级采样（可能切开多字节字符）不影响拼接出的签名字节序列的稳定性，且避免逐次遍历超长文本。
--- 只有长度与三段采样窗口全部相同才会碰撞，足以覆盖流式追加与压缩截断两类变化。
--- @param s string|nil
--- @return string
function M.fingerprint(s)
  s = s or ""
  local n = #s
  if n <= 192 then return n .. ":" .. s end
  local mid = math.floor(n / 2) - 32
  return table.concat({ n, s:sub(1, 64), s:sub(mid, mid + 63), s:sub(n - 63) }, ":")
end

-- ========== 块级渲染缓存 ==========

local BlockCache = {}
BlockCache.__index = BlockCache

--- 创建块级渲染缓存
--- @return table
function M.new_block_cache()
  return setmetatable({
    store = {}, -- key -> { sig, lines, marks }
    lines = nil, -- 已写入 buffer 的内容镜像（nil = 未知，下次写入走全量）
    marks = nil, -- 与 lines 并行的元数据镜像
    new_lines = nil,
    new_marks = nil,
    stats = { hits = 0, misses = 0 },
  }, BlockCache)
end

--- 丢弃块缓存与内容镜像（下次写入为全量替换）。
--- 会话切换 / 上下文压缩重排 / 显示模式切换 / 表格宽度变化时调用。
function BlockCache:reset()
  self.store = {}
  self.lines = nil
  self.marks = nil
  self.new_lines = nil
  self.new_marks = nil
  self.stats = { hits = 0, misses = 0 }
end

--- 渲染块列表：签名未变的块直接复用缓存结果，仅重新构建签名变化的块。
--- 本轮未出现的块键会被清理，保证缓存规模与当前内容一致。
--- @param blocks table 数组，每项 { key=string, sig=string, build=function() -> { lines, marks } }
--- @return table lines 拼接后的行数组
--- @return table marks 与 lines 并行的元数据数组
function BlockCache:render(blocks)
  local store = self.store
  local seen = {}
  local lines, marks = {}, {}
  local at, hits, misses = 0, 0, 0
  for _, b in ipairs(blocks) do
    local key = b.key
    seen[key] = true
    local e = store[key]
    if e and e.sig == b.sig then
      hits = hits + 1
    else
      local built = b.build() or {}
      e = { sig = b.sig, lines = built.lines or {}, marks = built.marks or {} }
      store[key] = e
      misses = misses + 1
    end
    local bl = e.lines
    local bm = e.marks
    for i = 1, #bl do
      at = at + 1
      lines[at] = bl[i]
      marks[at] = bm[i]
    end
  end
  for k in pairs(store) do
    if not seen[k] then store[k] = nil end
  end
  self.new_lines = lines
  self.new_marks = marks
  self.stats = { hits = hits, misses = misses }
  return lines, marks
end

--- 把最近一次 render 的结果增量写入 buffer，并更新内容/元数据镜像。
--- @param buf number
--- @return table { changed, start, removed, inserted, full }
function BlockCache:write(buf)
  local d = M.apply(buf, self.lines, self.new_lines or {})
  if d.changed then
    self.lines = self.new_lines
    self.marks = self.new_marks
  end
  return d
end

--- 最近一次渲染的命中统计（诊断 / 测试用）
--- @return table { hits, misses }
function BlockCache:last_stats()
  return self.stats or { hits = 0, misses = 0 }
end

-- ========== 按 buffer 共享的缓存 ==========

-- 每个聊天 buffer 一个 BlockCache，由当前显示模式共用：cache.lines 始终镜像 buffer
-- 的真实内容，因此切换显示模式 / 历史重排后差分写入仍基于正确基线（不同模式的块
-- 键前缀不同，不会互相命中）。
local caches = {}

--- 取（或新建）指定 buffer 的共享块缓存
--- @param buf number
--- @return table
function M.cache_for(buf)
  local c = caches[buf]
  if not c then
    c = M.new_block_cache()
    caches[buf] = c
  end
  return c
end

--- 使指定 buffer 的缓存失效（下次渲染走全量替换）
--- @param buf number|nil
function M.invalidate(buf)
  if buf and caches[buf] then caches[buf]:reset() end
end

--- 清空全部缓存（窗口关闭 / 测试重置）
function M.reset()
  caches = {}
end

return M
