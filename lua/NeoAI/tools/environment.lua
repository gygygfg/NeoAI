--- 工具环境探测
--- @module 'NeoAI.tools.environment'
--- 拼接工具上下文（tool definitions）前，检测当前会话可用的工作区 / git 环境；
--- 无法获取 workspace（cwd）或 git 目录时，禁用依赖对应环境的工具，
--- 避免向模型暴露必然失败的调用。

local M = {}

-- ========== 私有状态 ==========

--- 探测结果缓存：按 cwd 记忆化。filter_tools 在**每次请求**构建工具定义时都会调用，
--- 而 git_available 会做 finddir 文件系统查找、workspace_available 会做 isdirectory
--- 系统调用——不应进入请求热路径。TTL + DirChanged 失效兼顾正确性（如中途 `git init`）。
local _probe = { cwd = nil, ws = false, git = false, at = 0 }
local _PROBE_TTL_MS = 1000
local _dir_watch = false

--- 安装 DirChanged 监听（一次性）：切换目录即失效缓存。
local function _ensure_dir_watch()
  if _dir_watch then return end
  _dir_watch = true
  pcall(vim.api.nvim_create_autocmd, "DirChanged", {
    group = vim.api.nvim_create_augroup("NeoAIEnvProbe", { clear = true }),
    callback = function() _probe.cwd = nil end,
  })
end

-- ========== 私有常量 ==========

-- 依赖 git 工作树的工具（git 目录不可获取时禁用）
local GIT_DEPENDENT_TOOLS = {
  "git_status",
  "git_diff",
  "git_log",
  "git_commit_detail",
  "git_branch",
  "git_file_history",
  "git_restore",
  "git_worktree",
}

-- 依赖工作区（cwd）的工具（workspace 不可获取时禁用）
local WORKSPACE_DEPENDENT_TOOLS = {
  "list_files",
  "search_files",
}

-- ========== 私有函数 ==========

local function _in_set(set, name)
  for _, n in ipairs(set) do
    if n == name then return true end
  end
  return false
end

-- ========== 公开 API ==========

--- 刷新探测缓存（cwd 变化或超过 TTL 时重算）
--- @param cwd string
local function _refresh(cwd)
  local now = vim.uv.now()
  if _probe.cwd == cwd and (now - _probe.at) < _PROBE_TTL_MS then
    return
  end
  local ws = vim.fn.isdirectory(cwd) == 1
  -- 用 cwd 作为搜索起点（cwd .. ";"），而非 ".;"：见 git_available 注释。
  local git = ws
    and (vim.fn.finddir(".git", cwd .. ";") ~= "" or vim.fn.findfile(".git", cwd .. ";") ~= "")
  _probe.cwd = cwd
  _probe.ws = ws
  _probe.git = git and true or false
  _probe.at = now
  _ensure_dir_watch()
end

--- 工作区（cwd）是否可用：非空且目录存在
--- @return boolean
function M.workspace_available()
  local cwd = vim.fn.getcwd()
  if cwd == "" or cwd == nil then return false end
  _refresh(cwd)
  return _probe.ws
end

--- 是否处于 git 工作树内：从 cwd 向上查找 .git 目录或文件（覆盖 worktree 的 .git 文件）
--- 注意：必须用 cwd 作为搜索起点（cwd .. ";"），而非 ".;"。
--- vim.fn.finddir/.findfile 的 ".;" 从「当前 buffer 所在目录」开始向上搜索，
--- 而不是从 cwd 开始。若 buffer 在项目内、cwd 在别处，会穿透到 buffer 目录的 .git，
--- 得到与真实工作目录不符合的结果。
--- @return boolean
function M.git_available()
  local cwd = vim.fn.getcwd()
  if cwd == "" or cwd == nil then return false end
  _refresh(cwd)
  return _probe.git
end

--- 重置探测缓存（测试用）
function M.reset()
  _probe.cwd = nil
  _probe.ws = false
  _probe.git = false
  _probe.at = 0
end

--- 过滤不可用环境的工具（保留可用的子集）
--- @param tools table name -> tool
--- @return table name -> tool
function M.filter_tools(tools)
  tools = tools or {}
  local ws = M.workspace_available()
  local git = M.git_available()
  local out = {}
  for name, tool in pairs(tools) do
    if _in_set(GIT_DEPENDENT_TOOLS, name) and not git then
      -- 无 git 工作树：禁用 git 工具
    elseif _in_set(WORKSPACE_DEPENDENT_TOOLS, name) and not ws then
      -- 无工作区：禁用 workspace 工具
    else
      out[name] = tool
    end
  end
  return out
end

return M