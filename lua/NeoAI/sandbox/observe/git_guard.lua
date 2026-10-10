--- 沙箱 git 变更命令守卫
--- @module NeoAI.sandbox.observe.git_guard
--- `.git` 是「索引↔对象库↔refs」强耦合的数据库，必须原子化处理（见 `runtime.git_path_class`
--- 与 `candidate._apply_order`：对象先于指针），否则会「存了索引丢了对象」产生悬空引用。
--- 因此外部命令中的 git **变更**子命令在此识别并拒绝，改由专用 git 工具
--- （`git_add`/`git_commit`/`git_stash`/`git_restore`，沙箱内执行、改动原子暂存
--- 进审批悬浮窗）处理。只读 git 子命令（status/diff/log/show/...）不拦截；
--- 变更子命令中的**纯只读子动作**（如 `git stash list` / `git stash show`）亦放行。

local M = {}

--- git 变更子命令（denylist：命中即拒绝）。保守起见只列明确写仓库状态的子命令，
--- 未列出的子命令不拦截（`.git` 捕获排除仍保证不会损坏索引，仅可能被静默丢弃）。
local MUTATING = {
  add = true, commit = true, stash = true, checkout = true, reset = true, restore = true,
  merge = true, rebase = true, ["cherry-pick"] = true, revert = true, switch = true,
  rm = true, mv = true, apply = true, clean = true, pull = true, fetch = true, push = true,
  -- `clone`/`init` 不在拦截列表：它们**新建**仓库（不修改现有索引↔对象↔refs 耦合），
  -- 供 pyenv/nvm 等官方安装脚本使用；新建的 `.git` 由 candidate 按 git_path_class 原子
  -- 捕获/发布（对象先于指针）。其余变更子命令仍拦截，改走专用 git 工具。
  gc = true, prune = true, ["update-ref"] = true, am = true,
  worktree = true, submodule = true, ["symbolic-ref"] = true, ["commit-tree"] = true,
  ["write-tree"] = true, ["read-tree"] = true, ["hash-object"] = true, ["update-index"] = true,
  ["add--interactive"] = true, ["checkout-index"] = true, filter = true,
}

--- 需要跟一个独立取值的 git 全局选项（用于跳过其值，正确找到子命令）。
local VALUE_OPTS = {
  ["-C"] = true, ["-c"] = true, ["--git-dir"] = true, ["--work-tree"] = true,
  ["--namespace"] = true, ["--exec-path"] = true, ["--config-env"] = true,
}

--- 变更子命令中的**纯只读子动作**白名单：命中则放行（不写仓库）。
--- 例如 `git stash`（裸/`push`/`pop`/`apply`/`drop`/`clear`/`save`/`store`）写仓库，
--- 但 `git stash list` / `git stash show` 只读取、不改工作区与 refs/index。
local READONLY_SUBACTION = {
  stash = { list = true, show = true },
}

--- 判断变更子命令 `sub`（`tokens[k]`）之后的第一个**位置参数**是否为只读子动作。
--- 跳过其间的选项（`--x=y`、带值选项、`-x`）。
--- @param sub string 子命令名（如 "stash"）
--- @param tokens string[]
--- @param k integer 子命令在 tokens 中的下标
--- @return boolean
local function _readonly_subaction(sub, tokens, k)
  local allow = READONLY_SUBACTION[sub]
  if not allow then return false end
  local j = k + 1
  while j <= #tokens do
    local t = tokens[j]
    if t == "" or t:match("^[;|&()]") then return false end
    if t:match("^%-%-[%w%-]+=") then
      j = j + 1
    elseif VALUE_OPTS[t] then
      j = j + 2
    elseif t:match("^%-") then
      j = j + 1
    else
      return allow[t] == true
    end
  end
  return false
end

--- 粗略 shell 分词：按空白与 `;|&()` 切分，跳过单/双引号内容（降低误报）。
--- @param command string
--- @return string[]
local function _tokenize(command)
  local tokens, i, n = {}, 1, #command
  while i <= n do
    local c = command:sub(i, i)
    if c == "'" or c == '"' then
      local j = command:find(c, i + 1, true) or (n + 1)
      tokens[#tokens + 1] = command:sub(i + 1, j - 1)
      i = j + 1
    elseif c:match("[%s;|&()]") then
      if c:match("[;|&()]") then tokens[#tokens + 1] = c end
      i = i + 1
    else
      local j = i
      while j <= n and not command:sub(j, j):match("[%s;|&()'\"]") do j = j + 1 end
      tokens[#tokens + 1] = command:sub(i, j - 1)
      i = j
    end
  end
  return tokens
end

--- 命令中是否包含 git 变更子命令；命中则返回该子命令名。
--- @param command string
--- @return string|nil
function M.mutating(command)
  if type(command) ~= "string" or command == "" then return nil end
  local tokens = _tokenize(command)
  for idx = 1, #tokens do
    local t = tokens[idx]
    if t == "git" or t:match("/git$") then
      local k = idx + 1
      while k <= #tokens do
        local a = tokens[k]
        if a == "" or a:match("^[;|&()]") then break end
        if a:match("^%-%-[%w%-]+=") then
          k = k + 1
        elseif VALUE_OPTS[a] then
          k = k + 2
        elseif a:match("^%-") then
          k = k + 1
        else
          if MUTATING[a] then
            -- 只读子动作（如 `stash list`）放行：继续扫描后续命令中的 git 调用。
            if _readonly_subaction(a, tokens, k) then break end
            return a
          end
          break
        end
      end
    end
  end
  return nil
end

M.MUTATING = MUTATING

return M
