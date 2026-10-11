--- 沙箱 git worktree 落点门禁
--- @module 'NeoAI.sandbox.observe.worktree_guard'
--- `git worktree` 会新建/删除**工作树目录**并改写主仓 `.git/worktrees/**` 与工作树 `.git` 文件
--- （均为 pointer，由候选管线原子化捕获/发布，见 `runtime.git_path_class`）。为避免产生
--- 「半残、git 不认」的工作树，落点必须满足：
---   1. **不在 `.git` 内部**（不得经工作树路径污染仓库内部）；
---   2. **不在临时根**（`tools.sandbox.ephemeral_roots` / `tmpfs_roots`，cwd 子树除外）——
---      临时根写入会话私有、不发布，工作树会随会话丢失。放行但**登记退出清理**
---      （删除工作树目录 + 主仓 `git worktree prune`），避免主仓残留悬空注册；
---   3. **被可写 overlay 根覆盖**（`read_all=false` 时为 cwd + `process_roots` + 已暂存覆盖根；
---      `read_all=true` 时整机可写，直接放行）——未被覆盖时 **fail-closed** 拒绝，绝不静默降级。
--- 命中即返回可读原因（用于门禁拒绝），否则返回 nil。

local config_store = require("NeoAI.kernel.config_store")

local M = {}

--- 路径是否位于根 `r` 之下（含自身）。
--- @param p string
--- @param r string
--- @return boolean
local function _under(p, r)
  return p == r or p:sub(1, #r + 1) == r .. "/"
end

--- 规范化为绝对、折叠 `..`/`.`、去尾斜杠（不解析最终符号链接：目标可能尚不存在）。
--- @param p string
--- @param cwd string
--- @return string|nil
local function _abs(p, cwd)
  if type(p) ~= "string" or p == "" then return nil end
  local expanded = vim.fn.expand(p)
  if expanded:sub(1, 1) ~= "/" then
    expanded = (cwd ~= "" and cwd or vim.fn.getcwd()) .. "/" .. expanded
  end
  local abs = vim.fn.simplify(vim.fn.fnamemodify(expanded, ":p"))
  return (abs:gsub("/+$", ""))
end

--- 校验单个路径。
--- @param path string|nil
--- @param cwd string
--- @param runtime table
--- @param cfg table
--- @param repo string|nil 仓库目录（临时根落点登记清理用）
--- @return string|nil 拒绝原因
local function _check_one(path, cwd, runtime, cfg, repo)
  local abs = _abs(path, cwd)
  if not abs or abs == "" then return nil end

  if runtime.is_git_internal(abs) then
    return "SANDBOX_WORKTREE_IN_GIT: 工作树落点不可位于 `.git` 内部: " .. abs
  end

  local function _ephemeral()
    if cwd ~= "" and _under(abs, cwd) then return false end
    local roots = cfg.ephemeral_roots
    if type(roots) ~= "table" then roots = runtime.tmpfs_roots() end
    for _, r in ipairs(roots or {}) do
      local rr = (type(r) == "string" and r or ""):gsub("/+$", "")
      if rr ~= "" and _under(abs, rr) then return true end
    end
    return false
  end
  -- 临时根落点：放行，但登记退出清理（删除工作树目录 + 主仓 `git worktree prune`）。
  -- 会话私有临时根会随会话丢弃，若不清理则主仓 `.git/worktrees` 会残留悬空注册。
  if _ephemeral() then
    pcall(function()
      require("NeoAI.sandbox.observe.worktree_cleanup").register(repo or cwd, abs)
    end)
    return nil
  end

  -- read_all：整机只读 lower + 会话 upper，任意（非临时/非 .git）路径均可写并被捕获。
  if runtime.read_all() then return nil end

  local roots = { cwd }
  local pr = cfg.process_roots
  if type(pr) == "table" then
    for _, r in ipairs(pr) do roots[#roots + 1] = r end
  end
  pcall(function()
    for _, r in ipairs(require("NeoAI.sandbox.execution.candidate").staged_overlay_roots(roots)) do
      roots[#roots + 1] = r
    end
  end)
  for _, r in ipairs(roots) do
    local rr = (type(r) == "string" and r or ""):gsub("/+$", "")
    if rr ~= "" and _under(abs, rr) then return nil end
  end
  return "SANDBOX_WORKTREE_UNCOVERED: 工作树落点不在任何可写根内（read_all=false）: " .. abs
    .. "。请将该父目录加入 tools.sandbox.process_roots 或开启 tools.sandbox.read_all。"
end

--- 校验 git_worktree 调用的落点参数（`path` / `new_path`）。
--- `list` 只读、无落点；其路径参数一律忽略。
--- @param args table
--- @param ctx table|nil
--- @return string|nil 拒绝原因
function M.check(args, ctx)
  if type(args) ~= "table" then return nil end
  local action = args.action
  if action == "list" then return nil end
  local cfg = config_store.get("tools.sandbox") or {}
  local runtime = require("NeoAI.sandbox.execution.runtime")
  local cwd = ((ctx and (ctx.sandbox_exec_cwd or ctx.cwd)) or vim.fn.getcwd() or ""):gsub("/+$", "")
  local repo = (type(args.repo) == "string" and args.repo ~= "") and args.repo or cwd
  local reason = _check_one(args.path, cwd, runtime, cfg, repo)
  if reason then return reason end
  return _check_one(args.new_path, cwd, runtime, cfg, repo)
end

return M
