--- Git 操作工具
--- @module NeoAI.tools.builtin.git_ops
--- Git 只读操作（diff/log/status/branch）与 rollback/commit。

local async = require("NeoAI.utils.async")
local helpers = require("NeoAI.tools.builtin.tool_helpers")

local M = {}

-- ========== 私有函数 ==========

--- 为 argv 前置沙箱运行时前缀：git 在沙箱命名空间（与 run_command 同一 overlay）内执行，
--- 磁盘读取看到的是暂存视图而非真实工作区。
--- @param argv table
--- @param ctx table|nil
--- @return table
local function _sandboxed_argv(argv, ctx)
  local prefix = ctx and ctx.sandbox_prefix
  if not (prefix and #prefix > 0) then return argv end
  local full = {}
  for _, v in ipairs(prefix) do full[#full + 1] = v end
  for _, v in ipairs(argv) do full[#full + 1] = v end
  return full
end

--- 运行 git 命令（沙箱命名空间内；无前缀时回退宿主）
--- @param args table git 参数数组
--- @param ctx table|nil 工具上下文（含 sandbox_prefix/cwd/env）
--- @return Deferred resolve(输出)
local function _git(args, ctx)
  local d = async.Deferred.new()
  local out = {}
  local env = {}
  if ctx and type(ctx.sandbox_env) == "table" then
    for k, v in pairs(ctx.sandbox_env) do env[k] = v end
  end
  -- 只读 git 命令不写 index（避免在 overlay upper 产生副作用）。
  env.GIT_OPTIONAL_LOCKS = "0"
  local job = vim.fn.jobstart(_sandboxed_argv({ "git", unpack(args) }, ctx), {
    cwd = ctx and ctx.sandbox_cwd or nil,
    env = env,
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      for _, line in ipairs(data or {}) do
        if line ~= "" then out[#out + 1] = line end
      end
    end,
    on_exit = function(_, code)
      d:resolve({ code = code, output = table.concat(out, "\n") })
    end,
  })
  if job <= 0 then
    return async.reject({ kind = "git", message = "无法启动 git" })
  end
  return d
end

--- 运行 git **变更**命令（沙箱命名空间内；与 `_git` 同一 overlay，看到暂存工作区）。
--- 不设 `GIT_OPTIONAL_LOCKS`（允许写 index/objects）。`.git` 改动随后由候选管线**原子化**
--- 捕获（对象先于指针，见 `runtime.git_path_class`），进入审批悬浮窗，用户确认后原子应用。
--- @param args table git 参数数组
--- @param ctx table|nil 工具上下文（含 sandbox_prefix/cwd/env）
--- @return Deferred resolve({ code, output, stderr })
local function _git_write(args, ctx)
  local d = async.Deferred.new()
  local out, errout = {}, {}
  local env = {}
  if ctx and type(ctx.sandbox_env) == "table" then
    for k, v in pairs(ctx.sandbox_env) do env[k] = v end
  end
  local job = vim.fn.jobstart(_sandboxed_argv({ "git", unpack(args) }, ctx), {
    cwd = ctx and ctx.sandbox_cwd or nil,
    env = env,
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      for _, line in ipairs(data or {}) do
        if line ~= "" then out[#out + 1] = line end
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data or {}) do
        if line ~= "" then errout[#errout + 1] = line end
      end
    end,
    on_exit = function(_, code)
      d:resolve({ code = code, output = table.concat(out, "\n"), stderr = table.concat(errout, "\n") })
    end,
  })
  if job <= 0 then
    return async.reject({ kind = "git", message = "无法启动 git" })
  end
  return d
end

--- 组装 git 结果文本（成功/失败都带 stdout+stderr）
--- @param r table { code, output, stderr }
--- @return string
local function _git_text(r)
  local body = r.output or ""
  if r.stderr and r.stderr ~= "" then body = (body ~= "" and (body .. "\n") or "") .. r.stderr end
  if body == "" then body = "（无输出）" end
  if r.code == 0 then return body end
  return ("git 退出码 %d\n%s"):format(r.code, body)
end

-- ========== 工具定义 ==========

local git_tools = {}

git_tools.git_status = helpers.define_tool(
  "git_status",
  "查看 git 状态（--short）。path 可选。",
  {
    type = "object",
    properties = { path = { type = "string" } },
    required = {},
  },
  function(args, on_success, on_error, ctx)
    _git({ "status", "--short" }, ctx):then_(function(r)
      on_success(r.code == 0 and (r.output ~= "" and r.output or "工作区干净") or r.output)
    end, function(e) on_error(e.message) end)
  end,
  { category = "git" }
)

git_tools.git_diff = helpers.define_tool(
  "git_diff",
  "查看未提交的改动（git diff）。file_path 可选。",
  {
    type = "object",
    properties = { file_path = { type = "string" } },
    required = {},
  },
  function(args, on_success, on_error, ctx)
    local cmd = args.file_path and { "diff", "--", args.file_path } or { "diff" }
    _git(cmd, ctx):then_(function(r)
      on_success(r.output ~= "" and r.output or "无改动")
    end, function(e) on_error(e.message) end)
  end,
  { category = "git" }
)

git_tools.git_log = helpers.define_tool(
  "git_log",
  "查看提交历史。max 可选（默认 20）。",
  {
    type = "object",
    properties = { max = { type = "integer" }, path = { type = "string" } },
    required = {},
  },
  function(args, on_success, on_error, ctx)
    local cmd = { "log", "--oneline", "-n", tostring(args.max or 20) }
    if args.path then cmd[#cmd + 1] = "--"; cmd[#cmd + 1] = args.path end
    _git(cmd, ctx):then_(function(r)
      on_success(r.output)
    end, function(e) on_error(e.message) end)
  end,
  { category = "git" }
)

git_tools.git_commit_detail = helpers.define_tool(
  "git_commit_detail",
  "查看某次提交详情。ref 必填。",
  {
    type = "object",
    properties = { ref = { type = "string" } },
    required = { "ref" },
  },
  function(args, on_success, on_error, ctx)
    _git({ "show", "--stat", args.ref }, ctx):then_(function(r)
      on_success(r.output)
    end, function(e) on_error(e.message) end)
  end,
  { category = "git" }
)

git_tools.git_branch = helpers.define_tool(
  "git_branch",
  "查看分支列表（-a）。",
  {
    type = "object",
    properties = {},
    required = {},
  },
  function(args, on_success, on_error, ctx)
    _git({ "branch", "-a" }, ctx):then_(function(r)
      on_success(r.output)
    end, function(e) on_error(e.message) end)
  end,
  { category = "git" }
)

git_tools.git_file_history = helpers.define_tool(
  "git_file_history",
  "查看文件历史。file_path 必填；max 可选。",
  {
    type = "object",
    properties = { file_path = { type = "string" }, max = { type = "integer" } },
    required = { "file_path" },
  },
  function(args, on_success, on_error, ctx)
    _git({ "log", "--oneline", "-n", tostring(args.max or 20), "--", args.file_path }, ctx):then_(function(r)
      on_success(r.output)
    end, function(e) on_error(e.message) end)
  end,
  { category = "git" }
)

-- ========== git 变更（沙箱内执行，改动原子暂存并进入审批悬浮窗） ==========
-- `.git` 是索引↔对象库↔refs 强耦合数据库：这些工具在沙箱内运行（看到暂存工作区），
-- `.git` 改动由候选管线**原子化**捕获（对象先于指针，见 `runtime.git_path_class`），
-- 进入审批悬浮窗，用户确认后按原子顺序应用，保证不会产生悬空引用。
-- `run_command` 中的 git 变更子命令会被 `sandbox/git_guard` 拒绝，须改用这些专用工具。

git_tools.git_add = helpers.define_tool(
  "git_add",
  "暂存文件（git add）。paths 可选（数组）；all=true 暂存全部改动。改动进入审批待确认。",
  {
    type = "object",
    properties = {
      paths = { type = "array", items = { type = "string" } },
      all = { type = "boolean" },
    },
    required = {},
  },
  function(args, on_success, on_error, ctx)
    local argv = { "add" }
    if args.all == true then
      argv[#argv + 1] = "-A"
    elseif type(args.paths) == "table" and #args.paths > 0 then
      argv[#argv + 1] = "--"
      for _, p in ipairs(args.paths) do argv[#argv + 1] = p end
    else
      on_error("git_add 需要 paths（非空数组）或 all=true")
      return
    end
    _git_write(argv, ctx):then_(function(r)
      if r.code == 0 then
        for _, p in ipairs(args.paths or {}) do helpers.reload_buffers_for(p) end
        on_success(_git_text(r))
      else
        on_error(_git_text(r))
      end
    end, function(e) on_error(e.message) end)
  end,
  { category = "git", approval = { auto_allow = false } }
)

git_tools.git_commit = helpers.define_tool(
  "git_commit",
  "提交已暂存改动（git commit）。message 必填；all=true 先暂存已跟踪文件（-a）。改动进入审批待确认。",
  {
    type = "object",
    properties = { message = { type = "string" }, all = { type = "boolean" } },
    required = { "message" },
  },
  function(args, on_success, on_error, ctx)
    if type(args.message) ~= "string" or args.message == "" then
      on_error("git_commit 需要 message")
      return
    end
    local argv = { "commit", "-m", args.message }
    if args.all == true then argv[#argv + 1] = "-a" end
    _git_write(argv, ctx):then_(function(r)
      if r.code == 0 then on_success(_git_text(r)) else on_error(_git_text(r)) end
    end, function(e) on_error(e.message) end)
  end,
  { category = "git", approval = { auto_allow = false } }
)

git_tools.git_stash = helpers.define_tool(
  "git_stash",
  "管理 stash（git stash）。action: push|pop|apply|drop|list；message/include_untracked 仅 push 用。改动进入审批待确认。",
  {
    type = "object",
    properties = {
      action = { type = "string", enum = { "push", "pop", "apply", "drop", "list" } },
      message = { type = "string" },
      include_untracked = { type = "boolean" },
    },
    required = { "action" },
  },
  function(args, on_success, on_error, ctx)
    local action = args.action
    local argv
    if action == "push" then
      argv = { "stash", "push" }
      if args.include_untracked == true then argv[#argv + 1] = "-u" end
      if type(args.message) == "string" and args.message ~= "" then
        argv[#argv + 1] = "-m"; argv[#argv + 1] = args.message
      end
    elseif action == "pop" or action == "apply" or action == "drop" or action == "list" then
      argv = { "stash", action }
    else
      on_error("git_stash action 仅支持 push/pop/apply/drop/list")
      return
    end
    _git_write(argv, ctx):then_(function(r)
      if r.code == 0 then on_success(_git_text(r)) else on_error(_git_text(r)) end
    end, function(e) on_error(e.message) end)
  end,
  { category = "git", approval = { auto_allow = false } }
)

git_tools.git_restore = helpers.define_tool(
  "git_restore",
  "还原文件到指定提交（git checkout <commit> -- <file_path>）。file_path 必填；commit 可选（默认 HEAD）。改动进入审批待确认。",
  {
    type = "object",
    properties = { file_path = { type = "string" }, commit = { type = "string" } },
    required = { "file_path" },
  },
  function(args, on_success, on_error, ctx)
    local commit = args.commit or "HEAD"
    _git_write({ "checkout", commit, "--", args.file_path }, ctx):then_(function(r)
      if r.code == 0 then
        helpers.reload_buffers_for(args.file_path)
        on_success(_git_text(r))
      else
        on_error(_git_text(r))
      end
    end, function(e) on_error(e.message) end)
  end,
  { category = "git", approval = { auto_allow = false } }
)

git_tools.git_rollback = helpers.define_tool(
  "git_rollback",
  "回滚文件到指定提交。file_path 必填；commit 可选（默认 HEAD）。改动进入审批待确认。",
  {
    type = "object",
    properties = { file_path = { type = "string" }, commit = { type = "string" } },
    required = { "file_path" },
  },
  function(args, on_success, on_error, ctx)
    local commit = args.commit or "HEAD"
    _git_write({ "checkout", commit, "--", args.file_path }, ctx):then_(function(r)
      if r.code == 0 then
        helpers.reload_buffers_for(args.file_path)
        on_success(("已回滚 %s 到 %s"):format(args.file_path, commit))
      else
        on_error(_git_text(r))
      end
    end, function(e) on_error(e.message) end)
  end,
  { category = "git", approval = { auto_allow = false } }
)

git_tools.git_auto_commit_config = helpers.define_tool(
  "git_auto_commit_config",
  "查看/设置自动提交配置。auto_commit 可选。",
  {
    type = "object",
    properties = { auto_commit = { type = "boolean" } },
    required = {},
  },
  function(args, on_success)
    on_success("自动提交配置: " .. tostring(args.auto_commit == true))
  end,
  { category = "git" }
)

--- 获取工具列表
--- @return table 数组
function M.get_tools()
  local out = {}
  for _, tool in pairs(git_tools) do
    out[#out + 1] = tool
  end
  return out
end

return M
