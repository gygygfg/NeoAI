--- Git 操作工具
--- @module 'NeoAI.tools.builtin.git_ops'
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
  -- 非交互：避免凭据/编辑器提示在沙箱内阻塞（fetch/pull 无 TTY 时会挂起）。
  env.GIT_TERMINAL_PROMPT = "0"
  env.GIT_EDITOR = "true"
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

--- git_add/git_commit 前置门禁：仓库存在未发布的沙箱文件修改时拒绝执行。
--- 提交作用在沙箱暂存视图上；若这些内容尚未落盘，提交后 HEAD 与真实工作区会不一致
--- （git status 又显示 modified）。要求先应用修改，保证提交的原子一致性。
--- @param ctx table|nil
--- @param repo string|nil 目标仓库目录
--- @param on_ok function
--- @param on_error function
local function _guard_unpublished(ctx, repo, on_ok, on_error)
  _git({ "rev-parse", "--show-toplevel" }, ctx, repo):then_(function(r)
    if r.code ~= 0 then
      -- 不是仓库/路径错误：交给真正的 git 写命令报错，保持原有错误信息。
      on_ok()
      return
    end
    local root = vim.trim(r.output or "")
    local ok, cand = pcall(require, "NeoAI.sandbox.execution.candidate")
    if not ok or not cand or type(cand.unpublished_under) ~= "function" then
      on_ok()
      return
    end
    local paths = cand.unpublished_under(root)
    if type(paths) ~= "table" or #paths == 0 then
      on_ok()
      return
    end
    local preview = {}
    for i = 1, math.min(5, #paths) do preview[#preview + 1] = paths[i] end
    on_error("SANDBOX_UNPUBLISHED_EDITS: 仓库存在 " .. tostring(#paths)
      .. " 个未应用的沙箱修改，请先在审批界面应用后再执行 git_add/git_commit: "
      .. table.concat(preview, ", ")
      .. (#paths > #preview and " …" or ""))
  end, function(e) on_error(e and e.message or tostring(e)) end)
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
  "查看 git 状态（--short）。同 opencode git status。",
  {
    type = "object",
    properties = {
      repo = { type = "string", description = "仓库目录（缺省=会话仓库）" },
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
  "查看未提交改动（git diff）。file_path 可选。",
  {
    type = "object",
    properties = {
      file_path = { type = "string" },
      repo = { type = "string", description = "仓库目录（缺省=会话仓库）" },
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
  "查看提交历史。max 可选（默认 20）；path 可选（pathspec 文件路径）。",
  {
    type = "object",
    properties = {
      max = { type = "integer" },
      path = { type = "string", description = "pathspec 文件路径（限定历史范围）" },
      repo = { type = "string", description = "仓库目录（缺省=会话仓库）" },
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
  "查看某次提交详情（git show --stat）。ref 必填。",
  {
    type = "object",
    properties = {
      ref = { type = "string" },
      repo = { type = "string", description = "仓库目录（缺省=会话仓库）" },
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
  "查看分支列表（-a）。",
  {
    type = "object",
    properties = {
      repo = { type = "string", description = "仓库目录（缺省=会话仓库）" },
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
  "查看文件历史。file_path 必填；max 可选（默认 20）。",
  {
    type = "object",
    properties = {
      file_path = { type = "string" },
      max = { type = "integer" },
      repo = { type = "string", description = "仓库目录（缺省=会话仓库）" },
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
  "暂存文件（git add）。paths 数组 或 all=true。改动进入审批。",
  {
    type = "object",
    properties = {
      paths = { type = "array", items = { type = "string" } },
      all = { type = "boolean" },
      repo = { type = "string", description = "仓库目录（缺省=会话仓库）" },
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
    _guard_unpublished(ctx, repo, function()
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
    end, on_error)
  end,
  { category = "git", approval = { auto_allow = false } }
)

git_tools.git_commit = helpers.define_tool(
  "git_commit",
  "提交已暂存改动（git commit）。message 必填；all=true 走 -a。改动进入审批。",
  {
    type = "object",
    properties = {
      message = { type = "string" },
      all = { type = "boolean" },
      repo = { type = "string", description = "仓库目录（缺省=会话仓库）" },
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
    local repo = _repo(args)
    _guard_unpublished(ctx, repo, function()
      _git_write(argv, ctx, repo):then_(function(r)
        if r.code == 0 then on_success(_git_text(r)) else on_error(_git_text(r)) end
      end, function(e) on_error(e.message) end)
    end, on_error)
  end,
  { category = "git", approval = { auto_allow = false } }
)

git_tools.git_stash = helpers.define_tool(
  "git_stash",
  "管理 stash（push|pop|apply|drop|list）。message/include_untracked 仅 push 用。改动进入审批。",
  {
    type = "object",
    properties = {
      action = { type = "string", enum = { "push", "pop", "apply", "drop", "list" } },
      message = { type = "string" },
      include_untracked = { type = "boolean" },
      repo = { type = "string", description = "仓库目录（缺省=会话仓库）" },
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
  "将单个文件回滚到指定提交（git checkout <commit> -- <file_path>）。"
    .. "file_path 必填；commit 默认 HEAD（仅丢弃该文件未提交的工作区改动，最安全）。"
    .. "除用户明确指定外一律用 HEAD；禁止臆测或用 HEAD~N/旧提交回退多个版本。"
    .. "若需回退到某历史版本，先用 git_file_history/git_log 查出精确提交、向用户复述确认，再置 confirm_multi=true。"
    .. "跨多个版本而未置 confirm_multi=true 会被拒绝。改动进入审批。",
  {
    type = "object",
    properties = {
      file_path = { type = "string", description = "要还原的文件路径（相对会话仓库或绝对路径）" },
      commit = { type = "string", description = "目标精确修订（默认 HEAD=仅丢弃未提交改动）；禁止臆测旧版本" },
      confirm_multi = { type = "boolean", description = "仅当用户已明确点名目标版本、确认跨多个版本回退时才置 true" },
      repo = { type = "string", description = "仓库目录（缺省=会话仓库）" },
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

git_tools.git_worktree = helpers.define_tool(
  "git_worktree",
  "管理 git 工作树（git worktree）。"
    .. "action: list（只读）/ add / remove / move / prune / lock / unlock / repair。"
    .. "add 需要 path（工作树目录，须位于可写根内且不可在 .git 内），可选 commit（默认 HEAD）/ detach / force；"
    .. "落点位于临时根（会话私有）时放行，并在退出时自动清理（删除目录 + 主仓 prune）；"
    .. "remove 需要 path（可选 force）；move 需要 path 与 new_path；"
    .. "lock 需要 path（可选 reason）；unlock 需要 path；repair 可选 path。"
    .. "变更在沙箱内执行并进入审批（.git 工作树元数据整组原子应用）。",
  {
    type = "object",
    properties = {
      action = {
        type = "string",
        enum = { "list", "add", "remove", "move", "prune", "lock", "unlock", "repair" },
      },
      path = { type = "string", description = "工作树目录（add/remove/move/lock/unlock/repair）" },
      new_path = { type = "string", description = "move 的目标目录" },
      commit = { type = "string", description = "add 的起点修订（默认 HEAD）；禁止臆测旧版本" },
      detach = { type = "boolean", description = "add 时分离 HEAD（不新建分支）" },
      force = { type = "boolean", description = "add/remove 时强制（谨慎）" },
      reason = { type = "string", description = "lock 的原因" },
      repo = { type = "string", description = "仓库目录（缺省=会话仓库）" },
    },
    required = { "action" },
  },
  function(args, on_success, on_error, ctx)
    local action = args.action
    local repo = _repo(args)
    local function _need_path()
      if type(args.path) ~= "string" or args.path == "" then
        on_error("git_worktree action=" .. tostring(action) .. " 需要 path")
        return nil
      end
      return args.path
    end

    if action == "list" then
      _git({ "worktree", "list" }, ctx, repo):then_(function(r)
        if r.code == 0 then
          on_success(output_guard.cap(r.output ~= "" and r.output or "（无附加工作树）", { tool = "git_worktree" }))
        else
          on_error(_git_text(r))
        end
      end, function(e) on_error(e.message) end)
      return
    end

    local argv
    if action == "add" then
      local p = _need_path(); if not p then return end
      argv = { "worktree", "add" }
      if args.force == true then argv[#argv + 1] = "--force" end
      if args.detach == true then argv[#argv + 1] = "--detach" end
      argv[#argv + 1] = p
      argv[#argv + 1] = args.commit or "HEAD"
    elseif action == "remove" then
      local p = _need_path(); if not p then return end
      argv = { "worktree", "remove" }
      if args.force == true then argv[#argv + 1] = "--force" end
      argv[#argv + 1] = p
    elseif action == "move" then
      local p = _need_path(); if not p then return end
      if type(args.new_path) ~= "string" or args.new_path == "" then
        on_error("git_worktree action=move 需要 new_path")
        return
      end
      argv = { "worktree", "move", p, args.new_path }
    elseif action == "prune" then
      argv = { "worktree", "prune" }
    elseif action == "lock" then
      local p = _need_path(); if not p then return end
      argv = { "worktree", "lock" }
      if type(args.reason) == "string" and args.reason ~= "" then
        argv[#argv + 1] = "--reason"; argv[#argv + 1] = args.reason
      end
      argv[#argv + 1] = p
    elseif action == "unlock" then
      local p = _need_path(); if not p then return end
      argv = { "worktree", "unlock", p }
    elseif action == "repair" then
      argv = { "worktree", "repair" }
      if type(args.path) == "string" and args.path ~= "" then argv[#argv + 1] = args.path end
    else
      on_error("git_worktree action 仅支持 list/add/remove/move/prune/lock/unlock/repair")
      return
    end

    _git_write(argv, ctx, repo):then_(function(r)
      if r.code == 0 then
        -- 新增/移动工作树后刷新相关 buffer（幂等；缺失路径无副作用）。
        if (action == "add" or action == "move") and type(args.path) == "string" then
          pcall(helpers.reload_buffers_for, args.path)
        end
        on_success(_git_text(r))
      else
        on_error(_git_text(r))
      end
    end, function(e) on_error(e.message) end)
  end,
  { category = "git", approval = { auto_allow = false } }
)

git_tools.git_fetch = helpers.define_tool(
  "git_fetch",
  "从远程拉取引用与对象（git fetch）。remote 可选（缺省=当前分支上游）；"
    .. "all=true 拉取全部远程；prune/tags 可选。改动（.git 对象/远程跟踪 refs）进入审批。",
  {
    type = "object",
    properties = {
      remote = { type = "string", description = "远程名（缺省=当前分支上游）" },
      all = { type = "boolean", description = "拉取全部远程（--all）" },
      prune = { type = "boolean", description = "清理远程已删除的跟踪分支（--prune）" },
      tags = { type = "boolean", description = "同时拉取标签（--tags）" },
      repo = { type = "string", description = "仓库目录（缺省=会话仓库）" },
    },
    required = {},
  },
  function(args, on_success, on_error, ctx)
    local argv = { "fetch" }
    if args.all == true then argv[#argv + 1] = "--all" end
    if args.prune == true then argv[#argv + 1] = "--prune" end
    if args.tags == true then argv[#argv + 1] = "--tags" end
    -- --all 与显式远程互斥：all 时忽略 remote。
    if args.all ~= true and type(args.remote) == "string" and args.remote ~= "" then
      argv[#argv + 1] = args.remote
    end
    _git_write(argv, ctx, _repo(args)):then_(function(r)
      if r.code == 0 then on_success(_git_text(r)) else on_error(_git_text(r)) end
    end, function(e) on_error(e.message) end)
  end,
  { category = "git", approval = { auto_allow = false } }
)

git_tools.git_pull = helpers.define_tool(
  "git_pull",
  "从远程拉取并合并到当前分支（git pull）。remote/branch 可选；rebase/ff_only 可选。"
    .. "默认 --no-edit 避免交互；改动（工作区 + .git）进入审批。",
  {
    type = "object",
    properties = {
      remote = { type = "string", description = "远程名（缺省=当前分支上游）" },
      branch = { type = "string", description = "分支名（缺省=上游分支）" },
      rebase = { type = "boolean", description = "用 rebase 代替 merge（--rebase）" },
      ff_only = { type = "boolean", description = "仅允许快进（--ff-only）" },
      repo = { type = "string", description = "仓库目录（缺省=会话仓库）" },
    },
    required = {},
  },
  function(args, on_success, on_error, ctx)
    local argv = { "pull", "--no-edit" }
    if args.rebase == true then argv[#argv + 1] = "--rebase" end
    if args.ff_only == true then argv[#argv + 1] = "--ff-only" end
    if type(args.remote) == "string" and args.remote ~= "" then argv[#argv + 1] = args.remote end
    if type(args.branch) == "string" and args.branch ~= "" then argv[#argv + 1] = args.branch end
    _git_write(argv, ctx, _repo(args)):then_(function(r)
      if r.code == 0 then on_success(_git_text(r)) else on_error(_git_text(r)) end
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
