--- 临时根工作树退出清理
--- @module 'NeoAI.sandbox.observe.worktree_cleanup'
--- 当 `git_worktree` 的落点位于临时根（会话私有、`ephemeral_roots`）时，工作树目录会随
--- 会话丢弃，但 git 在仓库 `.git/worktrees/<name>` 留下的注册元数据仍会被候选管线发布，
--- 形成「半残、git 不认」的悬空条目。故在 nvim 退出（lifecycle 关闭钩子）时：
---   1. 删除临时根内的工作树目录；
---   2. 对相关仓库执行 `git worktree prune`，清除悬空注册。
--- 清理为 best-effort：任何失败仅记日志，绝不阻断退出。
---
--- 早期版本在此直接**拒绝**临时根落点（fail-closed）；改为「放行 + 退出清理」后，既能利用
--- 会话私有临时根做一次性工作树，又不会在主仓留下悬空注册。

local M = {}

-- ========== 私有状态 ==========

local entries = {} -- path -> { repo, path }
local unreg = nil -- lifecycle 取消注册句柄

-- ========== 私有函数 ==========

--- 惰性注册退出清理钩子（幂等）。
local function _ensure_hook()
  if unreg ~= nil then return end
  local ok, cancel = pcall(function()
    return require("NeoAI.kernel.lifecycle").on_shutdown(M.flush)
  end)
  if ok then unreg = cancel or false end
end

--- 在仓库执行 `git worktree prune`（best-effort）。
--- @param repo string
local function _prune(repo)
  if type(repo) ~= "string" or repo == "" then return end
  if vim.fn.executable("git") ~= 1 then return end
  pcall(function()
    vim.fn.system({ "git", "-C", repo, "worktree", "prune" })
  end)
end

-- ========== 公开 API ==========

--- 登记一个临时根工作树，供退出时清理（幂等：同一路径只记一次）。
--- @param repo string|nil 仓库目录（缺省=当前 cwd）
--- @param path string 工作树目录（绝对路径）
function M.register(repo, path)
  if type(path) ~= "string" or path == "" then return end
  if type(repo) ~= "string" or repo == "" then repo = vim.fn.getcwd() end
  entries[path] = { repo = repo, path = path }
  _ensure_hook()
end

--- 已登记数量（测试用）。
--- @return number
function M.count()
  local n = 0
  for _ in pairs(entries) do n = n + 1 end
  return n
end

--- 执行清理：删除临时根工作树目录并对相关仓库 prune。
function M.flush()
  if next(entries) == nil then return end
  local repos, list = {}, {}
  for _, e in pairs(entries) do
    list[#list + 1] = e
    repos[e.repo] = true
  end
  entries = {}
  for _, e in ipairs(list) do
    pcall(vim.fn.delete, e.path, "rf")
  end
  for repo in pairs(repos) do
    _prune(repo)
  end
end

--- 重置（测试用）：清空登记并取消退出钩子。
function M.reset()
  entries = {}
  if unreg and unreg ~= false then pcall(unreg) end
  unreg = nil
end

return M
