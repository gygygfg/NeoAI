--- 工具子进程统一沙箱化执行
--- @module NeoAI.sandbox.exec
--- 为「进程内工具」内部 spawn 的子进程（curl / node / bash / git 等）构造沙箱前缀，
--- 使其在 bwrap 命名空间内创建（而非宿主），实现「所有工具创建的子进程统一经沙箱」。
---
--- 与 run_command 的门禁前缀不同：这里用于工具内部的辅助进程（下载 / 渲染 / 格式转换等），
--- 不做候选冻结（这些进程只写工具自身缓存 / 临时目录，不写工作区）。通过 `rw_binds`
--- 以可写方式暴露工具自身目录（宿主与沙箱同路径可见），其余读取面沿用最小只读白名单
--- 与宿主敏感路径遮蔽。
---
--- 后端不可用 / 沙箱关闭时按 `tools.sandbox.fail_closed` 决定：fail_closed=true 拒绝
--- （返回 nil + err），否则回退宿主 argv（不静默降级读取面）。

local config_store = require("NeoAI.kernel.config_store")
local async = require("NeoAI.utils.async")

local M = {}

--- 一组路径的公共父目录（用于让可写根落在进程 cwd 子树内，避免遮蔽目录把 overlay 遮挡）。
--- @param roots table
--- @return string|nil
local function _common_parent(roots)
  local dirs = {}
  for _, r in ipairs(roots or {}) do
    if type(r) == "string" and r ~= "" then dirs[#dirs + 1] = r:gsub("/+$", "") end
  end
  if #dirs == 0 then return nil end
  local prefix = dirs[1]
  for i = 2, #dirs do
    local p = dirs[i]
    while prefix ~= "" and prefix ~= "/" do
      if p == prefix or p:sub(1, #prefix + 1) == prefix .. "/" then break end
      prefix = vim.fn.fnamemodify(prefix, ":h"):gsub("/+$", "")
    end
  end
  return (prefix ~= "" and prefix ~= "") and prefix or nil
end

--- 启动一个（可能已带沙箱前缀的）子进程，缓冲输出，返回 Deferred。
--- @param argv table 完整 argv（已含前缀）
--- @param opts table { cwd?, env?, timeout_ms?, signal? }
--- @return Deferred
local function _spawn(argv, opts)
  opts = opts or {}
  local d = async.Deferred.new()
  local stdout_chunks, stderr_chunks = {}, {}
  local done = false
  local job
  local function settle(res)
    if done then return end
    done = true
    d:resolve(res)
  end
  if opts.signal then
    opts.signal:subscribe(function(reason)
      if opts.kill then pcall(opts.kill) end
      if job then pcall(vim.fn.jobstop, job) end
      settle({ code = -1, stdout = table.concat(stdout_chunks, "\n"), stderr = table.concat(stderr_chunks, "\n"), aborted = true, message = reason })
    end)
  end
  local timeout_ms = opts.timeout_ms or 30000
  if timeout_ms > 0 then
    vim.defer_fn(function()
      if done then return end
      if opts.kill then pcall(opts.kill) end
      if job then pcall(vim.fn.jobstop, job) end
      settle({ code = -1, stdout = table.concat(stdout_chunks, "\n"), stderr = table.concat(stderr_chunks, "\n"), timed_out = true })
    end, timeout_ms)
  end
  job = vim.fn.jobstart(argv, {
    cwd = opts.cwd,
    env = opts.env or require("NeoAI.sandbox.secret").sanitized_env(),
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      if data and #data > 0 then stdout_chunks[#stdout_chunks + 1] = table.concat(data, "\n") end
    end,
    on_stderr = function(_, data)
      if data and #data > 0 then stderr_chunks[#stderr_chunks + 1] = table.concat(data, "\n") end
    end,
    on_exit = function(_, code)
      settle({ code = code, stdout = table.concat(stdout_chunks, "\n"), stderr = table.concat(stderr_chunks, "\n") })
    end,
  })
  if job <= 0 then
    done = true
    return async.reject({ kind = "sandbox", message = "无法启动工具子进程" })
  end
  return d
end

--- 宿主与沙箱同路径可见的共享根（工具临时 / 下载目录；位于沙箱存储之外，避免泄露内部状态）。
--- @return string
function M.shared_root()
  return (vim.fn.stdpath("cache") .. "/NeoAI/shared"):gsub("/+$", "")
end

--- 确保共享根存在
--- @return string
function M.ensure_shared()
  local dir = M.shared_root()
  pcall(vim.fn.mkdir, dir, "p")
  return dir
end

--- 规范化并筛选存在的目录（去尾斜杠）
--- @param list table|nil
--- @param mkdir boolean 是否先创建
--- @return table
local function _norm_dirs(list, mkdir)
  local out, seen = {}, {}
  for _, p in ipairs(list or {}) do
    if type(p) == "string" and p ~= "" and p ~= "/" then
      p = p:gsub("/+$", "")
      if mkdir then pcall(vim.fn.mkdir, p, "p") end
      if p ~= "" and not seen[p] and vim.uv.fs_stat(p) then
        seen[p] = true
        out[#out + 1] = p
      end
    end
  end
  return out
end

--- 运行工具子进程：统一沙箱 + overlay 暂存可写根 → 冻结候选 → 异步审批。
--- 复用沙箱进程门禁流水线（候选/风险/待审/证据），使工具子进程的写入与 edit_file
--- 一样走暂存，不直接落盘。
--- @param argv table 原始命令 argv
--- @param opts table {
---   name? string, cwd? string, writable_roots? table, network? boolean,
---   timeout_ms? number, signal? table, command? string }
--- @return Deferred resolve({ code, stdout, stderr, timed_out?, aborted?, message? })
function M.run(argv, opts)
  opts = opts or {}
  local cfg = config_store.get("tools.sandbox") or {}
  local sandbox = require("NeoAI.kernel.services").use("services.sandbox")
  -- 确保可写根存在（overlay lower 需为目录）
  local roots = {}
  for _, r in ipairs(opts.writable_roots or {}) do
    if type(r) == "string" and r ~= "" then
      pcall(vim.fn.mkdir, r, "p")
      if vim.fn.isdirectory(r) == 1 then roots[#roots + 1] = (r:gsub("/+$", "")) end
    end
  end
  local ictx = {}
  ictx.sandbox_exec_cwd = opts.cwd or _common_parent(roots) or vim.fn.getcwd()
  if not sandbox then
    if cfg.enabled ~= false and cfg.fail_closed ~= false then
      return async.reject({ kind = "sandbox", message = "沙箱服务不可用且 fail_closed=true，拒绝执行工具子进程" })
    end
    return _spawn(argv, { cwd = opts.cwd, timeout_ms = opts.timeout_ms, signal = opts.signal })
  end
  local tool = {
    name = "exec_" .. tostring(opts.name or "tool"),
    __sandbox_spec = { effect = "process", paths = {}, writable_roots = roots },
  }
  local args = { command = opts.command or table.concat(argv, " ") }
  return sandbox.gate(tool, args, ictx, function()
    -- token→真实密钥的还原仅限沙箱内部进程：argv 中的 NEOKEY_ 还原后执行；
    -- 日志/证据用的 args.command 仍保留 token。
    local secret = require("NeoAI.sandbox.secret")
    local full = {}
    for _, v in ipairs(ictx.sandbox_prefix or {}) do full[#full + 1] = v end
    for _, v in ipairs(argv) do
      full[#full + 1] = (type(v) == "string") and (secret.detokenize(v)) or v
    end
    return _spawn(full, {
      cwd = ictx.sandbox_cwd or opts.cwd,
      env = ictx.sandbox_env,
      timeout_ms = opts.timeout_ms,
      signal = opts.signal,
      kill = ictx.sandbox_kill,
    })
  end)
end

--- 为长驻工具子进程（如 MCP stdio server）准备沙箱 argv 与结束回调。
--- 与 M.run 不同：长驻进程无法用一次性门禁 Deferred，故在此同步构造 overlay 前缀，
--- 由调用方在进程退出时调用 finish(result) 捕获改动 → 冻结候选 → 待审/发布。
--- @param argv table 原始命令 argv
--- @param opts table { name?, cwd?, writable_roots?, network?, ro_binds?, command? }
--- @return table|nil full_argv
--- @return function|nil finish
--- @return string|nil err
function M.open(argv, opts)
  opts = opts or {}
  local cfg = config_store.get("tools.sandbox") or {}
  if cfg.enabled == false then
    if cfg.fail_closed == false then return argv, function() end, nil end
    return nil, nil, "SANDBOX_DISABLED: 沙箱已禁用"
  end
  local runtime = require("NeoAI.sandbox.runtime")
  local ok, err = runtime.check_available()
  if not ok then
    if cfg.fail_closed ~= false then return nil, nil, err end
    return argv, function() end, nil
  end
  local roots = _norm_dirs(opts.writable_roots, true)
  local real_cwd = opts.cwd or _common_parent(roots) or vim.fn.getcwd()
  local wrapper = require("NeoAI.sandbox.wrapper")
  local control = require("NeoAI.sandbox.control")
  local candidate = require("NeoAI.sandbox.candidate")
  local store = require("NeoAI.sandbox.store")
  local root = store.root() or (vim.fn.stdpath("cache") .. "/NeoAI/sandbox")
  local spec = { effect = "process", paths = {}, writable_roots = roots }
  local ctx = {}
  local attempt = control.new_attempt("exec_" .. tostring(opts.name or "open"), { command = opts.command }, ctx, spec)
  candidate.begin(attempt, root)
  local proc_dir = candidate.process_dir()
  -- 覆盖所有已暂存路径：使工具子进程与只读工具看到同一暂存视图（否则工作区外的暂存编辑
  -- 不会被物化，子进程读到真实磁盘——不一致且可绕过暂存）。
  local extra = {}
  for _, r in ipairs(roots) do extra[#extra + 1] = r end
  local known = { real_cwd }
  for _, r in ipairs(roots) do known[#known + 1] = r end
  for _, r in ipairs(candidate.staged_overlay_roots(known)) do extra[#extra + 1] = r end
  local specs = wrapper.build_overlay_specs(real_cwd, proc_dir, extra)
  for _, s in ipairs(specs) do
    if runtime.overlay_available() and runtime.overlay_writable(s.root, s.upper, s.work) then
      s.mode = "overlay"
    else
      s.mode = "bind"
    end
  end
  local conflicts = candidate.materialize_overlay(specs)
  if conflicts and #conflicts > 0 then
    candidate.cleanup(attempt.attempt_id)
    return nil, nil, "SANDBOX_MATERIALIZE_TYPE_CONFLICT: " .. tostring(conflicts[1] and conflicts[1].real)
  end
  local priv = {
    network = (opts.network ~= false) and cfg.offline ~= true,
    cap_add = {}, mounts = {}, userns = false, unmask = roots,
  }
  local prefix, perr = runtime.process_prefix({
    cwd = real_cwd, overlays = specs, privileges = priv, ro_binds = opts.ro_binds,
  })
  if not prefix then
    candidate.cleanup(attempt.attempt_id)
    return nil, nil, perr
  end
  local full = {}
  for _, v in ipairs(prefix) do full[#full + 1] = v end
  for _, v in ipairs(argv) do full[#full + 1] = v end
  local finish = function(result)
    if runtime.backend() == "bwrap" and #specs > 0 then
      for _, s in ipairs(specs) do
        candidate.capture_overlay(attempt.attempt_id, s.root, s.mode == "bind" and s.bind or s.upper)
      end
    end
    local cand = candidate.finish(attempt.attempt_id)
    return wrapper.settle_exec_candidate(attempt, cand, ctx, spec, result, { command = opts.command })
  end
  return full, finish, nil
end

return M
