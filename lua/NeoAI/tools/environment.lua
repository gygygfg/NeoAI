--- 工具环境探测
--- @module NeoAI.tools.environment
--- 拼接工具上下文（tool definitions）前，检测当前会话可用的工作区 / git 环境；
--- 无法获取 workspace（cwd）或 git 目录时，禁用依赖对应环境的工具，
--- 避免向模型暴露必然失败的调用。

local M = {}

-- ========== 私有常量 ==========

-- 依赖 git 工作树的工具（git 目录不可获取时禁用）
local GIT_DEPENDENT_TOOLS = {
  "git_status",
  "git_diff",
  "git_log",
  "git_commit_detail",
  "git_branch",
  "git_file_history",
  "git_rollback",
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

--- 工作区（cwd）是否可用：非空且目录存在
--- @return boolean
function M.workspace_available()
  local cwd = vim.fn.getcwd()
  return cwd ~= "" and vim.fn.isdirectory(cwd) == 1
end

--- 是否处于 git 工作树内：从 cwd 向上查找 .git 目录或文件（覆盖 worktree 的 .git 文件）
--- @return boolean
function M.git_available()
  return vim.fn.finddir(".git", ".;") ~= "" or vim.fn.findfile(".git", ".;") ~= ""
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