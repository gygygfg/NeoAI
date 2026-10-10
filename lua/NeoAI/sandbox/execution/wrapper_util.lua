--- 沙箱门禁纯助手
--- @module 'NeoAI.sandbox.execution.wrapper_util'
--- 从 wrapper.lua 抽出的无状态纯函数（不引用模块状态；内部相互调用保持原样）。

--- 按「暂存路径 -> 真实路径」映射还原值中的路径（字符串/字符串字段）。
--- 工具被门禁重写到私有副本执行，其回传消息里会带暂存路径；对模型而言这些路径
--- 不应存在（会误导后续操作），统一还原成真实工作区路径，使沙箱对 AI 不可见。
--- @param rev table staged -> real
--- @param value any
--- @return any
local function _rewrite_value(rev, value)
  if not next(rev) then return value end
  -- 粗粒度前缀提示（暂存路径前两级目录，通常仅 1~3 个根）：结果字符串不含任一提示时
  -- 不可能包含暂存路径，直接跳过逐条 gsub。暂存上万文件时，此前每个输出字符串都要对
  -- 全部暂存路径各做一次全文扫描（O(字符串×N)）；加守卫后无暂存路径的常规输出为 O(1)。
  local hints = {}
  for staged in pairs(rev) do
    hints[staged:match("^(/[^/]+/[^/]+)") or staged] = true
  end
  local hint_list = {}
  for h in pairs(hints) do hint_list[#hint_list + 1] = h end
  local function maybe(s)
    for _, h in ipairs(hint_list) do
      if s:find(h, 1, true) then return true end
    end
    return false
  end
  local function rewrite_str(s)
    if not maybe(s) then return s end
    local out = s
    for staged, real in pairs(rev) do
      out = out:gsub(vim.pesc(staged), (real:gsub("%%", "%%%%")))
    end
    return out
  end
  if type(value) == "string" then return rewrite_str(value) end
  if type(value) == "table" then
    for k, v in pairs(value) do
      if type(v) == "string" then value[k] = rewrite_str(v) end
    end
    return value
  end
  return value
end

--- 可写根路径编码为 overlay 子目录名。
--- 加 `r_` 前缀，避免根 `/root`（编码为 `r_root`）与整机根 overlay 目录 `base/root`
--- 共用同一 upper/work——两者 lower 语义不同（`/` vs `/root`），混用会让物化/捕获互相
--- 误读对方布局，表现为「文件写入后命令看不到、之后又消失」的视图分裂。
--- @param root string
--- @return string
local function _enc_root(root)
  return "r_" .. (root:gsub("^/", ""):gsub("/", "_"))
end

--- @param w string
--- @return boolean 是否为 sudo/doas 可执行名（含 `/usr/bin/sudo` 等绝对路径）
local function _is_sudo_bin(w)
  if type(w) ~= "string" or w == "" then return false end
  local b = vim.fn.fnamemodify(w, ":t")
  return b == "sudo" or b == "doas"
end

--- 按未加引号的 shell 分隔符切分命令并保留分隔符（引号/转义内的分隔符不切分）。
--- @param cmd string
--- @return table { text, sep }
local function _split_shell(cmd)
  local segs, cur = {}, {}
  local i, n, q = 1, #cmd, nil
  local function flush(sep)
    segs[#segs + 1] = { text = table.concat(cur), sep = sep }
    cur = {}
  end
  while i <= n do
    local c = cmd:sub(i, i)
    if q then
      cur[#cur + 1] = c
      if c == "\\" and q == '"' then
        local nx = cmd:sub(i + 1, i + 1)
        if nx ~= "" then cur[#cur + 1] = nx; i = i + 1 end
      elseif c == q then
        q = nil
      end
      i = i + 1
    elseif c == "'" or c == '"' then
      q = c; cur[#cur + 1] = c; i = i + 1
    elseif c == "\\" then
      cur[#cur + 1] = c
      local nx = cmd:sub(i + 1, i + 1)
      if nx ~= "" then cur[#cur + 1] = nx; i = i + 1 end
      i = i + 1
    elseif c == ";" or c == "\n" then
      flush(c); i = i + 1
    elseif c == "&" or c == "|" then
      if cmd:sub(i + 1, i + 1) == c then flush(c .. c); i = i + 2 else flush(c); i = i + 1 end
    else
      cur[#cur + 1] = c; i = i + 1
    end
  end
  segs[#segs + 1] = { text = table.concat(cur), sep = "" }
  return segs
end

--- 候选涉及的真实路径数组
--- @param cand table
--- @return table
local function _cand_paths(cand)
  local paths = {}
  for _, f in ipairs(cand.files or {}) do paths[#paths + 1] = f.path end
  return paths
end

--- 候选是否落在包管理器状态/安装目录（结果按 attempt 缓存）。
--- `package_path_manager` 对每个路径做数十个子串匹配，同一候选在结算链路上会被多个阶段
--- 询问；缓存后只对全部候选文件扫描一次，避免 3×N 次全量匹配。
--- @param cand table
--- @param attempt table|nil
--- @return string|nil manager
local function _package_manager_of(cand, attempt)
  if attempt and attempt.__pkg_manager ~= nil then return attempt.__pkg_manager or nil end
  local privilege = require("NeoAI.sandbox.execution.privilege")
  local found = nil
  for _, f in ipairs(cand.files or {}) do
    found = privilege.package_path_manager(f.path)
    if found then break end
  end
  if attempt then attempt.__pkg_manager = found or false end
  return found
end

--- cgroup 限制指纹（复用预热前必须一致，否则限制会不匹配）
--- @param limits table|nil
--- @return string
local function _limits_key(limits)
  limits = limits or {}
  return table.concat({
    tostring(limits.memory_bytes or 0), tostring(limits.pids or 0), tostring(limits.cpu_max or 0),
  }, ":")
end

return {
  rewrite_value = _rewrite_value,
  enc_root = _enc_root,
  is_sudo_bin = _is_sudo_bin,
  split_shell = _split_shell,
  cand_paths = _cand_paths,
  package_manager_of = _package_manager_of,
  limits_key = _limits_key,
}
