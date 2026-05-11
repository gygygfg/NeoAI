-- NeoAI Git 工具模块
-- 提供给大模型的 Git 操作工具（diff, log, status, rollback, file_history）
-- 基于 git_auto.lua 实现，支持真实 git 和伪 Git 两种模式

local M = {}

local define_tool = require("NeoAI.tools.builtin.tool_helpers").define_tool
local git_auto = require("NeoAI.tools.builtin.git_auto")

-- ============================================================================
-- 工具 git_diff
-- ============================================================================

local function _git_diff(args, on_success, on_error)
  local filepath = args and args.filepath

  -- 先确保 git_auto 已初始化
  if not git_auto.is_git_available() and not pcall(git_auto.get_status) then
    pcall(git_auto.initialize, {})
  end

  local result = git_auto.get_diff(filepath)
  if result then
    if on_success then
      on_success(result)
    end
  else
    if on_error then
      on_error("获取 diff 失败")
    end
  end
end

M.git_diff = define_tool({
  name = "git_diff",
  description = "查看工作区文件的差异（diff），可指定文件或查看所有变更",
  func = _git_diff,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = {
        type = "string",
        description = "文件路径（可选，不传则显示所有文件变更）",
      },
    },
  },
  returns = {
    type = "string",
    description = "文件差异内容",
  },
  category = "git",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 git_log
-- ============================================================================

local function _git_log(args, on_success, on_error)
  local max_count = args and args.max_count or 20

  pcall(git_auto.initialize, {})

  local result = git_auto.get_log(max_count)
  if result then
    if on_success then
      on_success(result)
    end
  else
    if on_error then
      on_error("获取提交日志失败")
    end
  end
end

M.git_log = define_tool({
  name = "git_log",
  description = "查看提交历史日志，显示最近的提交记录",
  func = _git_log,
  async = true,
  parameters = {
    type = "object",
    properties = {
      max_count = {
        type = "number",
        description = "最大显示条数，默认 20",
        default = 20,
      },
    },
  },
  returns = {
    type = "string",
    description = "提交历史日志",
  },
  category = "git",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 git_status
-- ============================================================================

local function _git_status(args, on_success, on_error)
  pcall(git_auto.initialize, {})

  local result = git_auto.get_status()
  if on_success then
    on_success(result)
  end
end

M.git_status = define_tool({
  name = "git_status",
  description = "查看工作区状态，显示已修改、新增、删除的文件",
  func = _git_status,
  async = true,
  parameters = {
    type = "object",
    properties = {},
  },
  returns = {
    type = "string",
    description = "工作区状态信息",
  },
  category = "git",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 git_commit_detail
-- ============================================================================

local function _git_commit_detail(args, on_success, on_error)
  if not args or not args.commit_hash then
    if on_error then
      on_error("需要 commit_hash 参数")
    end
    return
  end

  pcall(git_auto.initialize, {})

  local result = git_auto.get_commit_detail(args.commit_hash)
  if result then
    if on_success then
      on_success(result)
    end
  else
    if on_error then
      on_error(string.format("未找到提交: %s", args.commit_hash))
    end
  end
end

M.git_commit_detail = define_tool({
  name = "git_commit_detail",
  description = "查看指定提交的详细信息，包括变更文件列表",
  func = _git_commit_detail,
  async = true,
  parameters = {
    type = "object",
    properties = {
      commit_hash = {
        type = "string",
        description = "提交 hash（必填）",
      },
    },
    required = { "commit_hash" },
  },
  returns = {
    type = "string",
    description = "提交详情",
  },
  category = "git",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 git_rollback
-- ============================================================================

local function _git_rollback(args, on_success, on_error)
  if not args or not args.commit_hash then
    if on_error then
      on_error("需要 commit_hash 参数")
    end
    return
  end

  pcall(git_auto.initialize, {})

  local filepath = args.filepath
  local ok, err = git_auto.rollback(args.commit_hash, filepath)
  if ok then
    if on_success then
      on_success(string.format(
        "已成功回滚%s到提交 %s",
        filepath and ("文件 '" .. filepath .. "'") or "",
        args.commit_hash
      ))
    end
  else
    if on_error then
      on_error(string.format("回滚失败: %s", err or "未知错误"))
    end
  end
end

M.git_rollback = define_tool({
  name = "git_rollback",
  description = "回滚到指定提交，可指定回滚单个文件或整个工作区",
  func = _git_rollback,
  async = true,
  parameters = {
    type = "object",
    properties = {
      commit_hash = {
        type = "string",
        description = "目标提交 hash（必填）",
      },
      filepath = {
        type = "string",
        description = "文件路径（可选，仅回滚该文件到指定提交）",
      },
    },
    required = { "commit_hash" },
  },
  returns = {
    type = "string",
    description = "回滚结果信息",
  },
  category = "git",
  permissions = { write = true },
})

-- ============================================================================
-- 工具 git_file_history
-- ============================================================================

local function _git_file_history(args, on_success, on_error)
  if not args or not args.filepath then
    if on_error then
      on_error("需要 filepath 参数")
    end
    return
  end

  pcall(git_auto.initialize, {})

  local result = git_auto.get_file_history(args.filepath)
  if on_success then
    on_success(result)
  end
end

M.git_file_history = define_tool({
  name = "git_file_history",
  description = "查看指定文件的修改历史记录",
  func = _git_file_history,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = {
        type = "string",
        description = "文件路径（必填）",
      },
    },
    required = { "filepath" },
  },
  returns = {
    type = "string",
    description = "文件修改历史",
  },
  category = "git",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 git_branch（仅真实 git 模式可用）
-- ============================================================================

local function _git_branch(args, on_success, on_error)
  pcall(git_auto.initialize, {})

  if not git_auto.is_git_available() then
    if on_error then
      on_error("git 不可用，伪 Git 模式不支持分支操作")
    end
    return
  end

  local root = git_auto.get_git_root()
  if not root then
    if on_error then
      on_error("无法获取 git 根目录")
    end
    return
  end

  local cmd = string.format("git -C %s branch -a 2>/dev/null", root)
  local result = vim.fn.system(cmd)
  if vim.v.shell_error == 0 then
    if on_success then
      on_success(result)
    end
  else
    if on_error then
      on_error("获取分支列表失败")
    end
  end
end

M.git_branch = define_tool({
  name = "git_branch",
  description = "查看所有分支列表（仅真实 git 模式可用）",
  func = _git_branch,
  async = true,
  parameters = {
    type = "object",
    properties = {},
  },
  returns = {
    type = "string",
    description = "分支列表",
  },
  category = "git",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 git_auto_commit_config
-- ============================================================================

local function _git_auto_commit_config(args, on_success, on_error)
  if not args or args.enabled == nil then
    -- 查询当前状态
    if on_success then
      on_success(string.format(
        "自动提交状态: %s\nGit 模式: %s",
        git_auto.is_auto_commit_enabled() and "已启用" or "已禁用",
        git_auto.is_git_available() and "真实 Git" or "伪 Git"
      ))
    end
    return
  end

  git_auto.set_auto_commit(args.enabled)
  if on_success then
    on_success(string.format(
      "自动提交已%s",
      args.enabled and "启用" or "禁用"
    ))
  end
end

M.git_auto_commit_config = define_tool({
  name = "git_auto_commit_config",
  description = "查看或配置自动提交功能的状态",
  func = _git_auto_commit_config,
  async = true,
  parameters = {
    type = "object",
    properties = {
      enabled = {
        type = "boolean",
        description = "是否启用自动提交（不传则查询当前状态）",
      },
    },
  },
  returns = {
    type = "string",
    description = "配置结果",
  },
  category = "git",
  permissions = { read = true },
})

-- ============================================================================
-- get_tools()
-- ============================================================================

function M.get_tools()
  local tools = {}
  for _, v in pairs(M) do
    if type(v) == "table" and v.name and v.func then
      table.insert(tools, v)
    end
  end
  table.sort(tools, function(a, b)
    return a.name < b.name
  end)
  return tools
end

return M
