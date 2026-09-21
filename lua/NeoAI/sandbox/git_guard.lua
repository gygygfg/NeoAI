--- 沙箱 git 变更命令守卫
--- @module NeoAI.sandbox.git_guard
--- `.git` 是「索引↔对象库↔refs」强耦合的数据库，必须原子化处理（见 `runtime.git_path_class`
--- 与 `candidate._apply_order`：对象先于指针），否则会「存了索引丢了对象」产生悬空引用。
--- 因此外部命令中的 git **变更**子命令在此识别并拒绝，改由专用 git 工具
--- （`git_add`/`git_commit`/`git_stash`/`git_restore`/`git_rollback`，沙箱内执行、改动原子暂存
--- 进审批悬浮窗）处理。只读 git 子命令（status/diff/log/show/...）不拦截。

local M = {}

--- git 变更子命令（denylist：命中即拒绝）。保守起见只列明确写仓库状态的子命令，
--- 未列出的子命令不拦截（`.git` 捕获排除仍保证不会损坏索引，仅可能被静默丢弃）。
local MUTATING = {
  add = true, commit = true, stash = true, checkout = true, reset = true, restore = true,
  merge = true, rebase = true, ["cherry-pick"] = true, revert = true, switch = true,
  rm = true, mv = true, apply = true, clean = true, pull = true, fetch = true, push = true,
  init = true, clone = true, gc = true, prune = true, ["update-ref"] = true, am = true,
  worktree = true, submodule = true, ["symbolic-ref"] = true, ["commit-tree"] = true,
  ["write-tree"] = true, ["read-tree"] = true, ["hash-object"] = true, ["update-index"] = true,
  ["add--interactive"] = true, ["checkout-index"] = true, filter = true,
}

--- 需要跟一个独立取值的 git 全局选项（用于跳过其值，正确找到子命令）。
local VALUE_OPTS = {
  ["-C"] = true, ["-c"] = true, ["--git-dir"] = true, ["--work-tree"] = true,
  ["--namespace"] = true, ["--exec-path"] = true, ["--config-env"] = true,
}

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
          if MUTATING[a] then return a end
          break
        end
      end
    end
  end
  return nil
end

M.MUTATING = MUTATING

return M
