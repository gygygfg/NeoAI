--- 沙箱落盘写入器（降权优先 + 按需提权）
--- @module NeoAI.sandbox.writer
--- 发布（CAS）阶段的真实写入统一经此：**先以非 root 载荷身份尝试**，失败（EACCES/EPERM/
--- EROFS）则标记 `NEEDS_ROOT`，由上层进入异步待审；用户批准后才以 root（或 `sudo`，继承 tty）
--- 写入。写入全暂存在沙箱内完成，本模块只负责「暂存 → 真实盘」的最后一步。
---
--- 语义：
---   * 非 root 启动 NeoAI：当前进程即载荷身份，直接写入（writer=nonroot）。
---   * root 启动 + run_as=0（显式放弃降权）：直接以 root 写入（writer=root）。
---   * root 启动 + run_as=U：先用 `setpriv` 降权到 U 尝试；失败且为权限错误 → NEEDS_ROOT。
---     `opts.allow_root=true`（用户已批准）时才以 root 写入。
---   * 非 root 启动且非 U：以 `sudo`（继承 tty）写入（需用户批准）。

local fs = require("NeoAI.utils.fs")

local M = {}

M.STATE = {
  WRITTEN = "WRITTEN",
  NEEDS_ROOT = "NEEDS_ROOT",
  FAILED = "FAILED",
}

--- 错误是否为权限类（可提权重试）
--- @param err string|nil
--- @return boolean
local function _perm_error(err)
  local s = tostring(err or ""):lower()
  return s:find("permission denied", 1, true) ~= nil
    or s:find("operation not permitted", 1, true) ~= nil
    or s:find("read-only file system", 1, true) ~= nil
    or s:find("eacces", 1, true) ~= nil
    or s:find("eperm", 1, true) ~= nil
    or s:find("erofs", 1, true) ~= nil
end

--- 以 root 身份执行文件操作（当前进程即 root 或已是载荷 uid 时使用）
--- @param action string "write"|"delete"|"mkdir"|"rmdir"
--- @param path string
--- @param content string|nil
--- @param mode number|nil 权限位（保留暂存候选的原权限）
--- @return boolean, string|nil
local function _root_op(action, path, content, mode)
  if action == "write" then
    fs.ensure_dir(vim.fn.fnamemodify(path, ":h"))
    return fs.write_file_atomic(path, content or "", { mode = mode })
  elseif action == "delete" then
    return fs.delete_file(path)
  elseif action == "mkdir" then
    fs.ensure_dir(path)
    if mode then fs.chmod(path, mode) end
    return true
  elseif action == "rmdir" then
    local r = vim.fn.delete(path, "d")
    return r == 0, r ~= 0 and ("rmdir 失败: " .. path) or nil
  end
  return false, "UNKNOWN_ACTION: " .. tostring(action)
end

--- 以非 root uid 执行文件操作的 shell 片段（内容经 stdin，路径经 argv，避免注入）。
--- @param action string
--- @return string
local function _nonroot_snippet(action)
  if action == "write" then
    -- 保留原权限位：mkstemp/cat 默认 0600 会剥离可执行位（venv/bin 脚本等）。
    return 'tmp="$1.tmp.$$"; umask 022; cat > "$tmp" && mv -f "$tmp" "$1" && { [ -n "$2" ] && chmod "$2" "$1" || true; }'
  elseif action == "delete" then
    return 'rm -f -- "$1"'
  elseif action == "mkdir" then
    return 'mkdir -p -- "$1" && { [ -n "$2" ] && chmod "$2" "$1" || true; }'
  elseif action == "rmdir" then
    return 'rmdir -- "$1"'
  end
  return "exit 2"
end

--- 以非 root 身份执行（经 setpriv 降权；仅 root 进程可调用）
--- @param action string
--- @param path string
--- @param content string|nil
--- @param uid number
--- @param gid number
--- @param mode number|nil
--- @return boolean, string|nil
local function _nonroot_op(action, path, content, uid, gid, mode)
  if vim.fn.executable("setpriv") ~= 1 then
    return false, "SETPRIV_UNAVAILABLE"
  end
  local argv = {
    "setpriv", "--reuid", tostring(uid), "--regid", tostring(gid), "--clear-groups",
    "sh", "-c", _nonroot_snippet(action), "sh", path, mode and string.format("%o", mode) or "",
  }
  local out = vim.fn.system(argv, action == "write" and (content or "") or nil)
  if vim.v.shell_error == 0 then return true end
  return false, tostring(out)
end

--- 以 sudo（继承 tty）执行文件操作；仅非 root 进程需要，且须用户已批准。
--- @param action string
--- @param path string
--- @param content string|nil
--- @param mode number|nil
--- @return boolean, string|nil
function M.sudo_op(action, path, content, mode)
  local argv = { "sudo", "sh", "-c", _nonroot_snippet(action), "sh", path, mode and string.format("%o", mode) or "" }
  local out = vim.fn.system(argv, action == "write" and (content or "") or nil)
  if vim.v.shell_error == 0 then return true end
  return false, tostring(out)
end

--- 统一落盘入口：先非 root，权限不足 → NEEDS_ROOT（或已批准时以 root/sudo 写入）。
--- @param action string "write"|"delete"|"mkdir"|"rmdir"
--- @param path string
--- @param content string|nil
--- @param opts table|nil { allow_root?: boolean, prefer_sudo?: boolean, mode?: number }
--- @return table { ok, state, writer?, escalated?, reason?, err? }
function M.apply(action, path, content, opts)
  opts = opts or {}
  local runtime = require("NeoAI.sandbox.runtime")
  local uid, gid = runtime.payload_ids()
  local cur = vim.uv.getuid()
  local mode = opts.mode
  -- 未记录权限时：保留目标已有权限；新建文件用常规 0644（避免 mkstemp 的 0600）。
  if mode == nil and action == "write" then
    local st = vim.uv.fs_stat(path)
    mode = st and (st.mode % 512) or 420
  end

  -- NeoAI 本身非 root：先以当前身份写入；权限不足 → NEEDS_ROOT，用户批准后经 sudo 写入。
  if cur ~= 0 then
    local ok, err = _root_op(action, path, content, mode)
    if ok then
      return { ok = true, state = M.STATE.WRITTEN, writer = "nonroot" }
    end
    if not _perm_error(err) then
      return { ok = false, state = M.STATE.FAILED, err = err }
    end
    if not opts.allow_root then
      return { ok = false, state = M.STATE.NEEDS_ROOT, reason = "WRITE_REQUIRES_ROOT: " .. tostring(path), err = err }
    end
    local sok, serr = M.sudo_op(action, path, content, mode)
    return { ok = sok, state = sok and M.STATE.WRITTEN or M.STATE.FAILED,
      writer = "sudo", escalated = true, err = serr }
  end

  local nonroot = uid ~= nil and uid > 0
  -- root 进程 + run_as=0（显式放弃降权）：直接以 root 写入。
  if not nonroot then
    local ok, err = _root_op(action, path, content, mode)
    return {
      ok = ok,
      state = ok and M.STATE.WRITTEN or M.STATE.FAILED,
      writer = "root",
      err = err,
    }
  end

  -- root 进程 + 专用非 root uid：先降权尝试。
  local ok, err = _nonroot_op(action, path, content, uid, gid, mode)
  if ok then
    return { ok = true, state = M.STATE.WRITTEN, writer = "nonroot" }
  end
  if not _perm_error(err) then
    return { ok = false, state = M.STATE.FAILED, err = err }
  end

  -- 权限不足：需 root。未获批准 → NEEDS_ROOT；已批准 → 以 root（或 sudo）写入。
  if not opts.allow_root then
    return { ok = false, state = M.STATE.NEEDS_ROOT, reason = "WRITE_REQUIRES_ROOT: " .. tostring(path), err = err }
  end
  if opts.prefer_sudo then
    local sok, serr = M.sudo_op(action, path, content, mode)
    return { ok = sok, state = sok and M.STATE.WRITTEN or M.STATE.FAILED,
      writer = "sudo", escalated = true, err = serr }
  end
  local rok, rerr = _root_op(action, path, content, mode)
  return { ok = rok, state = rok and M.STATE.WRITTEN or M.STATE.FAILED,
    writer = "root", escalated = true, err = rerr }
end

--- 重置（测试用）：无模块级状态
function M.reset() end

M._perm_error = _perm_error

return M
