--- Git 操作工具
--- @module NeoAI.tools.builtin.git_ops
--- Git 只读操作（diff/log/status/branch）与 rollback/commit。

local async = require("NeoAI.utils.async")
local helpers = require("NeoAI.tools.builtin.tool_helpers")
local output_guard = require("NeoAI.tools.builtin.output_guard")

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

--- 解析工具参数 `repo`：目标 git 仓库目录（缺省/空 → nil，沿用会话仓库 cwd）。
--- 展开 `~`（vim.fn.expand）以支持用户主目录写法。
--- @param args table 工具参数
--- @return string|nil 目标仓库目录
local function _repo(args)
  local r = args and args.repo
  if type(r) ~= "string" or r == "" then return nil end
  return vim.fn.expand(r)
end

--- 在 git 子命令前注入 `-C <repo>`（在沙箱命名空间内同样有效，路径经 overlay 视图解析）。
--- @param repo string|nil 目标仓库目录
--- @param cmd table git 参数数组
--- @return table 可能带 `-C` 前缀的参数数组
local function _git_prefix(repo, cmd)
  if not repo then return cmd end
  local out = { "-C", repo }
  for _, v in ipairs(cmd) do out[#out + 1] = v end
  return out
end

--- 运行 git 命令（沙箱命名空间内；无前缀时回退宿主）
--- @param args table git 参数数组
--- @param ctx table|nil 工具上下文（含 sandbox_prefix/cwd/env）
--- @param repo string|nil 目标仓库目录（缺省=会话仓库）
--- @return Deferred resolve(输出)
local function _git(args, ctx, repo)
  local d = async.Deferred.new()
  local out = {}
  local env = {}
  if ctx and type(ctx.sandbox_env) == "table" then
    for k, v in pairs(ctx.sandbox_env) do env[k] = v end
  end
  -- 只读 git 命令不写 index（避免在 overlay upper 产生副作用）。
  env.GIT_OPTIONAL_LOCKS = "0"
  local job = vim.fn.jobstart(_sandboxed_argv({ "git", unpack(_git_prefix(repo, args)) }, ctx), {
    cwd = ctx and ctx.sandbox_cwd or nil,
    env = next(env) ~= nil and env or nil,
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
--- @param repo string|nil 目标仓库目录（缺省=会话仓库）
--- @return Deferred resolve({ code, output, stderr })
local function _git_write(args, ctx, repo)
  local d = async.Deferred.new()
  local out, errout = {}, {}
  local env = {}
  if ctx and type(ctx.sandbox_env) == "table" then
    for k, v in pairs(ctx.sandbox_env) do env[k] = v end
  end
  local job = vim.fn.jobstart(_sandboxed_argv({ "git", unpack(_git_prefix(repo, args)) }, ctx), {
    cwd = ctx and ctx.sandbox_cwd or nil,
    env = next(env) ~= nil and env or nil,
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

--- 计算 `<commit>` 相对 HEAD 落后的提交数（只读，走沙箱只读通道）。
--- 用于回退前的「多版本越界」守卫：数值越大表示目标越久远。
--- 解析失败（非法修订 / rev-list 报错）时返回 0，交由真正的 checkout 抛出可读错误。
--- @param commit string 目标修订
--- @param ctx table|nil 工具上下文
--- @param repo string|nil 目标仓库目录
--- @return Deferred resolve(number)
local function _commit_distance(commit, ctx, repo)
  if commit == "HEAD" then return async.resolve(0) end
  return _git({ "rev-list", "--count", commit .. "..HEAD" }, ctx, repo):then_(function(r)
    if r.code ~= 0 then return 0 end
    return tonumber((r.output or ""):match("%d+")) or 0
  end, function() return 0 end)
end

--- 回退前的「多版本越界」守卫：当 commit 比 HEAD 落后超过 1 个提交且未显式确认时拒绝。
--- 默认 HEAD（丢弃未提交改动）与 HEAD~1（回退恰好一个版本）始终放行；更久远的目标必须
--- 由调用方在用户明确点名版本后传入 confirm_multi=true，避免模型臆测旧提交而一次回退多个版本。
--- @param commit string 目标修订
--- @param confirm_multi boolean|nil 调用方是否已获用户明确确认
--- @param ctx table|nil
--- @param repo string|nil
--- @return Deferred resolve(true) 放行 / reject({kind,message}) 拒绝
local function _guard_multi_version(commit, confirm_multi, ctx, repo)
  if commit == "HEAD" or confirm_multi == true then return async.resolve(true) end
  return _commit_distance(commit, ctx, repo):then_(function(n)
    if n and n > 1 then
      return async.reject({
        kind = "multi_version",
        message = ("拒绝跨 %d 个版本回退：目标 `%s` 比 HEAD 落后 %d 个提交。"
          .. "除非用户已明确点名该版本，否则请改用默认 commit=HEAD（仅丢弃该文件未提交的改动）；"
          .. "确需回退到该历史版本时，先用 git_file_history/git_log 查出精确提交、"
          .. "向用户复述（哈希+信息）并确认，再用 confirm_multi=true 重试。"):format(n, commit, n),
      })
    end
    return true
  end)
end

-- ========== 工具定义 ==========

local git_tools = {}

git_tools.git_status = helpers.define_tool(
  "git_status",
  "查看 git 状态（--short）。repo 可选（目标仓库目录，缺省=当前会话仓库）。"
    .. "输出过长时截断为头+尾并把完整输出落盘到沙箱私有 /tmp（结果中给出路径，可用 read_file 回读）。",
  {
    type = "object",
    properties = {
      repo = { type = "string", description = "目标 git 仓库目录（缺省=当前会话仓库）" },
    },
    required = {},
  },
  function(args, on_success, on_error, ctx)
    _git({ "status", "--short" }, ctx, _repo(args)):then_(function(r)
      on_success(output_guard.cap(r.code == 0 and (r.output ~= "" and r.output or "工作区干净") or r.output, { tool = "git_status" }))
    end, function(e) on_error(e.message) end)
  end,
  { category = "git" }
)

git_tools.git_diff = helpers.define_tool(
  "git_diff",
  "查看未提交的改动（git diff）。file_path 可选；repo 可选（目标仓库目录，缺省=当前会话仓库）。"
    .. "输出过长时截断为头+尾并把完整输出落盘到沙箱私有 /tmp（结果中给出路径，可用 read_file 回读）。",
  {
    type = "object",
    properties = {
      file_path = { type = "string" },
      repo = { type = "string", description = "目标 git 仓库目录（缺省=当前会话仓库）" },
    },
    required = {},
  },
  function(args, on_success, on_error, ctx)
    local cmd = args.file_path and { "diff", "--", args.file_path } or { "diff" }
    _git(cmd, ctx, _repo(args)):then_(function(r)
      on_success(output_guard.cap(r.output ~= "" and r.output or "无改动", { tool = "git_diff" }))
    end, function(e) on_error(e.message) end)
  end,
  { category = "git" }
)

git_tools.git_log = helpers.define_tool(
  "git_log",
  "查看提交历史。max 可选（默认 20）；path 可选（pathspec 文件路径）；repo 可选（目标仓库目录，缺省=当前会话仓库）。"
    .. "输出过长时截断为头+尾并把完整输出落盘到沙箱私有 /tmp（结果中给出路径，可用 read_file 回读）。",
  {
    type = "object",
    properties = {
      max = { type = "integer" },
      path = { type = "string", description = "pathspec 文件路径（限定历史范围）" },
      repo = { type = "string", description = "目标 git 仓库目录（缺省=当前会话仓库）" },
    },
    required = {},
  },
  function(args, on_success, on_error, ctx)
    local cmd = { "log", "--oneline", "-n", tostring(args.max or 20) }
    if args.path then cmd[#cmd + 1] = "--"; cmd[#cmd + 1] = args.path end
    _git(cmd, ctx, _repo(args)):then_(function(r)
      on_success(output_guard.cap(r.output, { tool = "git_log" }))
    end, function(e) on_error(e.message) end)
  end,
  { category = "git" }
)

git_tools.git_commit_detail = helpers.define_tool(
  "git_commit_detail",
  "查看某次提交详情。ref 必填；repo 可选（目标仓库目录，缺省=当前会话仓库）。"
    .. "输出过长时截断为头+尾并把完整输出落盘到沙箱私有 /tmp（结果中给出路径，可用 read_file 回读）。",
  {
    type = "object",
    properties = {
      ref = { type = "string" },
      repo = { type = "string", description = "目标 git 仓库目录（缺省=当前会话仓库）" },
    },
    required = { "ref" },
  },
  function(args, on_success, on_error, ctx)
    _git({ "show", "--stat", args.ref }, ctx, _repo(args)):then_(function(r)
      on_success(output_guard.cap(r.output, { tool = "git_commit_detail" }))
    end, function(e) on_error(e.message) end)
  end,
  { category = "git" }
)

git_tools.git_branch = helpers.define_tool(
  "git_branch",
  "查看分支列表（-a）。repo 可选（目标仓库目录，缺省=当前会话仓库）。"
    .. "输出过长时截断为头+尾并把完整输出落盘到沙箱私有 /tmp（结果中给出路径，可用 read_file 回读）。",
  {
    type = "object",
    properties = {
      repo = { type = "string", description = "目标 git 仓库目录（缺省=当前会话仓库）" },
    },
    required = {},
  },
  function(args, on_success, on_error, ctx)
    _git({ "branch", "-a" }, ctx, _repo(args)):then_(function(r)
      on_success(output_guard.cap(r.output, { tool = "git_branch" }))
    end, function(e) on_error(e.message) end)
  end,
  { category = "git" }
)

git_tools.git_file_history = helpers.define_tool(
  "git_file_history",
  "查看文件历史。file_path 必填；max 可选；repo 可选（目标仓库目录，缺省=当前会话仓库）。"
    .. "输出过长时截断为头+尾并把完整输出落盘到沙箱私有 /tmp（结果中给出路径，可用 read_file 回读）。",
  {
    type = "object",
    properties = {
      file_path = { type = "string" },
      max = { type = "integer" },
      repo = { type = "string", description = "目标 git 仓库目录（缺省=当前会话仓库）" },
    },
    required = { "file_path" },
  },
  function(args, on_success, on_error, ctx)
    _git({ "log", "--oneline", "-n", tostring(args.max or 20), "--", args.file_path }, ctx, _repo(args)):then_(function(r)
      on_success(output_guard.cap(r.output, { tool = "git_file_history" }))
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
  "暂存文件（git add）。paths 可选（数组）；all=true 暂存全部改动；repo 可选（目标仓库目录，缺省=当前会话仓库）。改动进入审批待确认。",
  {
    type = "object",
    properties = {
      paths = { type = "array", items = { type = "string" } },
      all = { type = "boolean" },
      repo = { type = "string", description = "目标 git 仓库目录（缺省=当前会话仓库）" },
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
    local repo = _repo(args)
    _git_write(argv, ctx, repo):then_(function(r)
      if r.code == 0 then
        for _, p in ipairs(args.paths or {}) do
          -- 相对路径需拼到目标仓库目录，重载的才是该仓库的 buffer（缺省仓库行为不变）。
          local target = (repo and not p:match("^/")) and (repo .. "/" .. p) or p
          helpers.reload_buffers_for(target)
        end
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
  "提交已暂存改动（git commit）。message 必填；all=true 先暂存已跟踪文件（-a）；repo 可选（目标仓库目录，缺省=当前会话仓库）。改动进入审批待确认。",
  {
    type = "object",
    properties = {
      message = { type = "string" },
      all = { type = "boolean" },
      repo = { type = "string", description = "目标 git 仓库目录（缺省=当前会话仓库）" },
    },
    required = { "message" },
  },
  function(args, on_success, on_error, ctx)
    if type(args.message) ~= "string" or args.message == "" then
      on_error("git_commit 需要 message")
      return
    end
    local argv = { "commit", "-m", args.message }
    if args.all == true then argv[#argv + 1] = "-a" end
    _git_write(argv, ctx, _repo(args)):then_(function(r)
      if r.code == 0 then on_success(_git_text(r)) else on_error(_git_text(r)) end
    end, function(e) on_error(e.message) end)
  end,
  { category = "git", approval = { auto_allow = false } }
)

git_tools.git_stash = helpers.define_tool(
  "git_stash",
  "管理 stash（git stash）。action: push|pop|apply|drop|list；message/include_untracked 仅 push 用；repo 可选（目标仓库目录，缺省=当前会话仓库）。改动进入审批待确认。",
  {
    type = "object",
    properties = {
      action = { type = "string", enum = { "push", "pop", "apply", "drop", "list" } },
      message = { type = "string" },
      include_untracked = { type = "boolean" },
      repo = { type = "string", description = "目标 git 仓库目录（缺省=当前会话仓库）" },
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
    _git_write(argv, ctx, _repo(args)):then_(function(r)
      if r.code == 0 then on_success(_git_text(r)) else on_error(_git_text(r)) end
    end, function(e) on_error(e.message) end)
  end,
  { category = "git", approval = { auto_allow = false } }
)

git_tools.git_restore = helpers.define_tool(
  "git_restore",
  "将单个文件回滚/还原到指定提交（git checkout <commit> -- <file_path>）。"
    .. "file_path 必填；commit 可选（默认 HEAD）：必须是精确的 git 修订（提交哈希 / HEAD / HEAD~N / 标签 / 分支）。"
    .. "默认 HEAD 仅丢弃该文件在 HEAD 之后尚未提交的工作区改动，是最安全的默认值。"
    .. "除非用户明确指定目标版本，一律使用默认 HEAD；禁止臆测或用 HEAD~N、旧提交回退多个版本。"
    .. "若用户要求回退到某历史版本但未给哈希，先用 git_file_history / git_log 查出精确提交，"
    .. "向用户复述该提交（哈希+信息）并确认，再用 confirm_multi=true 重试。"
    .. "跨多个版本（落后 HEAD 超过 1 个提交）而未置 confirm_multi=true 会被拒绝。"
    .. "repo 可选（目标仓库目录，缺省=当前会话仓库）。改动进入审批待确认。",
  {
    type = "object",
    properties = {
      file_path = { type = "string", description = "要还原的文件路径（相对会话仓库或绝对路径）" },
      commit = { type = "string", description = "目标精确修订（默认 HEAD=仅丢弃未提交改动）；禁止臆测旧版本" },
      confirm_multi = { type = "boolean", description = "仅当用户已明确点名目标版本、确认跨多个版本回退时才置 true" },
      repo = { type = "string", description = "目标 git 仓库目录（缺省=当前会话仓库）" },
    },
    required = { "file_path" },
  },
  function(args, on_success, on_error, ctx)
    local commit = args.commit or "HEAD"
    local repo = _repo(args)
    _guard_multi_version(commit, args.confirm_multi, ctx, repo):then_(function()
      _git_write({ "checkout", commit, "--", args.file_path }, ctx, repo):then_(function(r)
        if r.code == 0 then
          local target = (repo and not args.file_path:match("^/")) and (repo .. "/" .. args.file_path) or args.file_path
          helpers.reload_buffers_for(target)
          on_success(_git_text(r))
        else
          on_error(_git_text(r))
        end
      end, function(e) on_error(e.message) end)
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
